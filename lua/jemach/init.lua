local M = {}

local julia_terminal_id = nil
local julia_terminal_obj = nil
local workspace_bufnr = nil
local workspace_win_id = nil
local workspace_tmp_file = vim.fn.stdpath("cache") .. "/jemach.log"
local history_file = vim.fn.stdpath("cache") .. "/julia_history.log"
local workspace_save_file = vim.fn.stdpath("cache") .. "/julia_workspace_save.jl"
local command_history = {}
local last_code_win = nil
local workflow_mode_active = false
local terminal_bufnr = nil
local terminal_win_id = nil

local workspace_cache = {
	last_update = 0,
	data = nil,
	debounce_timer = nil,
}

local repl_monitor = {
	last_line_count = 0,
	autocmd_id = nil,
}

M.config = {
	activate_project_on_start = true,
	auto_update_workspace = true,
	workspace_width = 50,
	max_history_size = 500,
	smart_block_detection = true,
	use_revise = true,
	terminal_direction = "horizontal",
	terminal_size = 15,
	workspace_style = "detailed",
	auto_save_workspace = false,
	save_on_exit = true,
	backend = "auto",
	slime_target = "tmux",
	slime_default_config = {
		socket_name = "default",
		target_pane = "{right-of}",
	},
	workspace_update_debounce = 300,
	use_cache = true,
	cache_ttl = 5000,
	lsp = {
		enabled = false,
		auto_start = true,
		detect_imports = true,
		show_import_status = true,
	},
	layout_mode = "vertical_split",
	terminal_type = "native",
	lualine_integration = true,
	lualine_colors = nil, -- Custom colors for lualine component, nil = auto

	keybindings = {
		toggle_repl = "<C-\\>",
		focus_repl = "<A-1>",
		focus_workspace = "<A-2>",
		focus_code = "<A-3>",
		cycle_focus = "<A-Tab>",
		workflow_mode = "<leader>jw",
	},
}

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
	M.load_history()

	-- Auto-detect backend if set to "auto"
	if M.config.backend == "auto" then
		M.config.backend = M.detect_backend()
	end

	-- Setup LSP integration if enabled
	if M.config.lsp and M.config.lsp.enabled then
		local lsp = require("jemach.lsp")
		lsp.config = vim.tbl_deep_extend("force", lsp.config, M.config.lsp)

		if M.config.lsp.auto_start then
			vim.api.nvim_create_autocmd("FileType", {
				pattern = "julia",
				callback = function()
					lsp.setup_lsp(M.config.lsp.lsp_config or {})
				end,
			})
		end
	end

	-- Setup integrations
	M.setup_global_keybindings()

	if M.config.lualine_integration then
		vim.defer_fn(M.setup_lualine, 100)
	end
end
local function detect_backend()
	local slime_ok, has_slime = pcall(function()
		return vim.g.slime_target ~= nil or vim.fn.exists("*slime#send") == 1
	end)

	if slime_ok and has_slime then
		return "vim-slime"
	end

	local tt_ok = pcall(require, "toggleterm")
	if tt_ok then
		return "toggleterm"
	end

	return "toggleterm"
end

M.detect_backend = detect_backend

local function get_active_backend()
	return M.config.backend
end

local function is_native_terminal_running()
	return terminal_bufnr and vim.api.nvim_buf_is_valid(terminal_bufnr)
end

local function is_repl_running()
	if M.config.terminal_type == "native" then
		return is_native_terminal_running()
	end

	local backend = get_active_backend()

	if backend == "vim-slime" then
		return vim.g.slime_target ~= nil or M.config.slime_target ~= nil
	elseif backend == "toggleterm" then
		if not julia_terminal_obj then
			return false
		end

		if not julia_terminal_obj.job_id then
			return false
		end

		local job_status = vim.fn.jobwait({ julia_terminal_obj.job_id }, 0)[1]
		return job_status == -1
	end

	return false
end
local function send_to_backend(code)
	local backend = get_active_backend()

	if backend == "vim-slime" then
		if vim.fn.exists("*slime#send") == 1 then
			vim.fn["slime#send"](code .. "\n")
		else
			local target = M.config.slime_target
			if target == "tmux" then
				local config = M.config.slime_default_config
				local socket = config.socket_name or "default"
				local pane = config.target_pane or "{right-of}"

				local cmd = string.format(
					"tmux -L %s send-keys -t %s -l %s",
					vim.fn.shellescape(socket),
					vim.fn.shellescape(pane),
					vim.fn.shellescape(code)
				)
				vim.fn.system(cmd)
				local enter_cmd = string.format(
					"tmux -L %s send-keys -t %s Enter",
					vim.fn.shellescape(socket),
					vim.fn.shellescape(pane)
				)
				vim.fn.system(enter_cmd)
			elseif target == "screen" then
				vim.notify("⚠️ Screen support requires vim-slime plugin", vim.log.levels.WARN)
			end
		end
	elseif backend == "toggleterm" then
		if M.config.terminal_type == "native" then
			send_to_native_terminal(code)
		elseif julia_terminal_obj then
			julia_terminal_obj:send(code .. "\n")
		end
	end
end

local function find_project_root()
	local current_buf = vim.api.nvim_buf_get_name(0)
	if current_buf == "" then
		return nil
	end
	local current_dir = vim.fn.fnamemodify(current_buf, ":p:h")
	local project_files = { "Project.toml", "JuliaProject.toml" }
	local root_files = vim.fs.find(project_files, { path = current_dir, upward = true, type = "file" })

	if not root_files or #root_files == 0 then
		return nil
	end
	return vim.fn.fnamemodify(root_files[1], ":p:h")
end

local function detect_julia_block()
	local current_line = vim.api.nvim_win_get_cursor(0)[1]
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

	local block_patterns = {
		{ start = "^%s*function%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*macro%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*module%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*struct%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*mutable%s+struct%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*begin%s*$", end_pat = "^%s*end%s*$" },
		{ start = "^%s*quote%s*$", end_pat = "^%s*end%s*$" },
		{ start = "^%s*let%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*for%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*while%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*if%s+", end_pat = "^%s*end%s*$" },
		{ start = "^%s*try%s*$", end_pat = "^%s*end%s*$" },
	}

	for _, pattern in ipairs(block_patterns) do
		local start_line = nil
		local end_line = nil
		local depth = 0

		for i = current_line, 1, -1 do
			if lines[i]:match(pattern.start) then
				start_line = i
				break
			end
		end

		if start_line then
			depth = 1
			for i = start_line + 1, #lines do
				if lines[i]:match(pattern.start) then
					depth = depth + 1
				elseif lines[i]:match(pattern.end_pat) then
					depth = depth - 1
					if depth == 0 then
						end_line = i
						break
					end
				end
			end

			if end_line then
				return start_line, end_line
			end
		end
	end

	return nil, nil
end

local function get_code_to_send()
	local mode = vim.api.nvim_get_mode().mode

	if mode == "v" or mode == "V" then
		local _, start_row, start_col, _ = unpack(vim.fn.getpos("'<"))
		local _, end_row, end_col, _ = unpack(vim.fn.getpos("'>"))
		local lines = vim.api.nvim_buf_get_lines(0, start_row - 1, end_row, false)

		if #lines == 0 then
			return ""
		end

		if mode == "V" then
			return table.concat(lines, "\n")
		end

		if #lines == 1 then
			lines[1] = string.sub(lines[1], start_col, end_col)
		else
			lines[1] = string.sub(lines[1], start_col)
			lines[#lines] = string.sub(lines[#lines], 1, end_col)
		end
		return table.concat(lines, "\n")
	else
		if M.config.smart_block_detection then
			local start_line, end_line = detect_julia_block()
			if start_line and end_line then
				local block_lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
				vim.notify(string.format("📦 Block (lines %d-%d)", start_line, end_line), vim.log.levels.INFO)
				return table.concat(block_lines, "\n")
			end
		end
		return vim.api.nvim_get_current_line()
	end
end

local function setup_repl_monitor(bufnr)
	if not M.config.auto_update_workspace then
		return
	end

	-- Remove previous autocmd if exists
	if repl_monitor.autocmd_id then
		pcall(vim.api.nvim_del_autocmd, repl_monitor.autocmd_id)
		repl_monitor.autocmd_id = nil
	end

	-- Monitor buffer changes to detect when Julia prompt appears (command completed)
	repl_monitor.autocmd_id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = bufnr,
		callback = function()
			if not workspace_bufnr or not vim.api.nvim_buf_is_valid(workspace_bufnr) then
				return
			end

			local line_count = vim.api.nvim_buf_line_count(bufnr)

			-- Only proceed if buffer has new lines
			if line_count <= repl_monitor.last_line_count then
				repl_monitor.last_line_count = line_count
				return
			end

			repl_monitor.last_line_count = line_count

			-- Get the last few lines to check for Julia prompt
			local last_lines = vim.api.nvim_buf_get_lines(bufnr, math.max(0, line_count - 3), line_count, false)
			local last_text = table.concat(last_lines, "\n")

			-- Check if Julia prompt is present (julia> or prompt style markers)
			-- This indicates command execution is complete
			if last_text:match("julia>") or last_text:match("@v[%d%.]+%) pkg>") or last_text:match("shell>") then
				-- Debounce workspace updates
				if workspace_cache.debounce_timer then
					workspace_cache.debounce_timer:close()
					workspace_cache.debounce_timer = nil
				end

				workspace_cache.debounce_timer = vim.loop.new_timer()
				workspace_cache.debounce_timer:start(
					M.config.workspace_update_debounce,
					0,
					vim.schedule_wrap(function()
						M.update_workspace_panel()
						if workspace_cache.debounce_timer then
							workspace_cache.debounce_timer:close()
							workspace_cache.debounce_timer = nil
						end
					end)
				)
			end
		end,
	})
end

local function start_native_terminal()
	if terminal_bufnr and vim.api.nvim_buf_is_valid(terminal_bufnr) then
		return true
	end

	terminal_bufnr = vim.api.nvim_create_buf(false, true)

	local ok, _ = pcall(function()
		vim.bo[terminal_bufnr].bufhidden = "hide"
	end)
	if not ok then
		vim.notify("❌ Failed to configure terminal buffer", vim.log.levels.ERROR)
		return false
	end

	local cmd_parts = { "julia" }
	if M.config.activate_project_on_start then
		local project_root = find_project_root()
		if project_root then
			table.insert(cmd_parts, string.format("--project=%s", project_root))
		else
			table.insert(cmd_parts, "--project=.")
		end
	end
	table.insert(cmd_parts, "-i")
	if M.config.use_revise then
		table.insert(cmd_parts, '-e "using Revise"')
	end

	return terminal_bufnr, table.concat(cmd_parts, " ")
end

local function open_terminal_in_window(bufnr, cmd)
	vim.api.nvim_win_set_buf(0, bufnr)

	local job_id = vim.fn.termopen(cmd, {
		on_exit = function()
			terminal_bufnr = nil
			terminal_win_id = nil
			if repl_monitor.autocmd_id then
				pcall(vim.api.nvim_del_autocmd, repl_monitor.autocmd_id)
				repl_monitor.autocmd_id = nil
			end
		end,
	})

	if job_id <= 0 then
		vim.notify("❌ Failed to start Julia terminal", vim.log.levels.ERROR)
		return false
	end

	-- Setup monitoring for workspace auto-update
	vim.defer_fn(function()
		setup_repl_monitor(bufnr)
	end, 1000)

	return true
end

function send_to_native_terminal(text)
	if not is_native_terminal_running() then
		return false
	end

	local ok, chan = pcall(function()
		return vim.bo[terminal_bufnr].channel
	end)
	if not ok or not chan or chan <= 0 then
		vim.notify("⚠️ Terminal channel not available", vim.log.levels.WARN)
		return false
	end

	local send_ok, _ = pcall(vim.api.nvim_chan_send, chan, text .. "\n")
	if not send_ok then
		vim.notify("❌ Failed to send to terminal", vim.log.levels.ERROR)
		return false
	end

	return true
end

function M.toggle_repl()
	if M.config.terminal_type == "native" then
		if terminal_win_id and vim.api.nvim_win_is_valid(terminal_win_id) then
			vim.api.nvim_win_close(terminal_win_id, false)
			terminal_win_id = nil
			return
		end

		local bufnr, cmd
		if not is_native_terminal_running() then
			bufnr, cmd = start_native_terminal()
			if not bufnr then
				return
			end
		else
			bufnr = terminal_bufnr
		end

		if M.config.layout_mode == "vertical_split" then
			vim.cmd("vsplit")
			terminal_win_id = vim.api.nvim_get_current_win()
			if cmd then
				open_terminal_in_window(bufnr, cmd)
			else
				vim.api.nvim_win_set_buf(terminal_win_id, bufnr)
				-- Setup monitor for existing terminal
				vim.defer_fn(function()
					setup_repl_monitor(bufnr)
				end, 100)
			end
			vim.cmd("wincmd L")
		else
			vim.cmd("split")
			terminal_win_id = vim.api.nvim_get_current_win()
			if cmd then
				open_terminal_in_window(bufnr, cmd)
			else
				vim.api.nvim_win_set_buf(terminal_win_id, bufnr)
				-- Setup monitor for existing terminal
				vim.defer_fn(function()
					setup_repl_monitor(bufnr)
				end, 100)
			end
		end
		return
	end

	local tt_ok, toggleterm = pcall(require, "toggleterm")
	if not tt_ok then
		vim.notify("❌ Toggleterm.nvim not installed", vim.log.levels.ERROR)
		return
	end

	local term_mod_ok, terminal_module = pcall(require, "toggleterm.terminal")
	if not term_mod_ok or not terminal_module.Terminal then
		vim.notify("❌ Error loading toggleterm.terminal", vim.log.levels.ERROR)
		return
	end

	if julia_terminal_obj and is_repl_running() then
		julia_terminal_obj:toggle()
		return
	end

	local cmd_parts = { "julia" }

	if M.config.activate_project_on_start then
		local project_root = find_project_root()
		if project_root then
			table.insert(cmd_parts, string.format("--project=%s", vim.fn.shellescape(project_root)))
			vim.notify("📂 Project: " .. project_root, vim.log.levels.INFO)
		else
			table.insert(cmd_parts, "--project=.")
		end
	end

	table.insert(cmd_parts, "-i")

	if M.config.use_revise then
		table.insert(cmd_parts, '-e "using Revise"')
	end

	local cmd = table.concat(cmd_parts, " ")

	local term_config = {
		cmd = cmd,
		direction = M.config.terminal_direction,
		on_open = function(t)
			julia_terminal_id = t.id
			vim.notify("✅ Julia REPL started", vim.log.levels.INFO)

			vim.keymap.set("t", "<C-\\>", function()
				if julia_terminal_obj then
					julia_terminal_obj:toggle()
				end
			end, { buffer = t.bufnr, desc = "Toggle Julia REPL" })

			-- Setup monitoring for workspace auto-update
			vim.defer_fn(function()
				setup_repl_monitor(t.bufnr)
			end, 1000)

			if M.config.auto_save_workspace then
				vim.defer_fn(function()
					if vim.fn.filereadable(workspace_save_file) == 1 then
						M.restore_workspace()
					end
				end, 1000)
			end
		end,
		on_close = function(_)
			-- Cleanup monitor
			if repl_monitor.autocmd_id then
				pcall(vim.api.nvim_del_autocmd, repl_monitor.autocmd_id)
				repl_monitor.autocmd_id = nil
			end

			if M.config.save_on_exit then
				M.save_workspace()
				vim.defer_fn(function()
					julia_terminal_id = nil
					julia_terminal_obj = nil
				end, 1000)
			else
				julia_terminal_id = nil
				julia_terminal_obj = nil
			end

			vim.notify("⚠️ Julia REPL closed", vim.log.levels.WARN)
		end,
		on_exit = function(_)
			-- Cleanup monitor
			if repl_monitor.autocmd_id then
				pcall(vim.api.nvim_del_autocmd, repl_monitor.autocmd_id)
				repl_monitor.autocmd_id = nil
			end

			julia_terminal_id = nil
			julia_terminal_obj = nil
		end,
	}

	if M.config.terminal_direction == "float" then
		term_config.float_opts = {
			border = "rounded",
			width = math.floor(vim.o.columns * 0.8),
			height = math.floor(vim.o.lines * 0.8),
		}
	elseif M.config.terminal_direction == "horizontal" then
		term_config.size = M.config.terminal_size
	elseif M.config.terminal_direction == "vertical" then
		term_config.size = math.floor(vim.o.columns * 0.4)
	end

	local Terminal = terminal_module.Terminal
	julia_terminal_obj = Terminal:new(term_config)
	julia_terminal_obj:open()
end

function M.save_history()
	local file = io.open(history_file, "w")
	if file then
		for _, cmd in ipairs(command_history) do
			file:write(cmd .. "\n")
		end
		file:close()
	end
end

function M.load_history()
	command_history = {}
	local file = io.open(history_file, "r")
	if file then
		for line in file:lines() do
			if line ~= "" then
				table.insert(command_history, line)
			end
		end
		file:close()
	end
end

local function add_to_history(code)
	if code == "" or code:match("^%s*$") then
		return
	end

	if command_history[#command_history] == code then
		return
	end

	table.insert(command_history, code)

	if #command_history > M.config.max_history_size then
		table.remove(command_history, 1)
	end

	M.save_history()
end

function M.send_to_repl()
	local backend = get_active_backend()

	if (backend == "toggleterm" or M.config.terminal_type == "native") and not is_repl_running() then
		vim.notify("🔄 Starting Julia REPL...", vim.log.levels.WARN)
		M.toggle_repl()

		vim.defer_fn(function()
			if is_repl_running() then
				M.send_to_repl()
			else
				vim.notify("❌ Failed to start REPL", vim.log.levels.ERROR)
			end
		end, 1000)
		return
	end

	local code = get_code_to_send()
	if code == "" then
		return
	end

	add_to_history(code)

	send_to_backend(code)

	if M.config.auto_update_workspace and workspace_bufnr and vim.api.nvim_buf_is_valid(workspace_bufnr) then
		if workspace_cache.debounce_timer then
			workspace_cache.debounce_timer:close()
			workspace_cache.debounce_timer = nil
		end
		workspace_cache.debounce_timer = vim.loop.new_timer()
		workspace_cache.debounce_timer:start(
			M.config.workspace_update_debounce,
			0,
			vim.schedule_wrap(function()
				M.update_workspace_panel()
				if workspace_cache.debounce_timer then
					workspace_cache.debounce_timer:close()
					workspace_cache.debounce_timer = nil
				end
			end)
		)
	end
end

function M.update_workspace_panel()
	if not is_repl_running() then
		vim.notify("⚠️ Julia REPL not running", vim.log.levels.WARN)
		return
	end

	if not workspace_bufnr or not vim.api.nvim_buf_is_valid(workspace_bufnr) then
		return
	end

	local now = vim.loop.now()
	if M.config.use_cache and workspace_cache.data and (now - workspace_cache.last_update) < M.config.cache_ttl then
		if vim.api.nvim_buf_is_valid(workspace_bufnr) then
			vim.bo[workspace_bufnr].modifiable = true
			vim.api.nvim_buf_set_lines(workspace_bufnr, 0, -1, false, workspace_cache.data)
			vim.bo[workspace_bufnr].modifiable = false
		end
		return
	end

	local julia_script = vim.fn.stdpath("cache") .. "/__nvim_workspace_update.jl"
	local julia_code = string.format(
		[[
const __nvim_ws_path = raw"%s"
let
    io = open(__nvim_ws_path, "w")
    try
        println(io, "╭─────────────────────────────────────────╮")
        println(io, "│  jEMach Workspace                         │")
        println(io, "╰─────────────────────────────────────────╯")
        println(io, "")

        all_names = sort(collect(names(Main, all=true)))
        user_vars = filter(all_names) do name
            str_name = string(name)
            !startswith(str_name, "#") &&
            !startswith(str_name, "__nvim") &&
            name != :Main &&
            name != :Core &&
            name != :Base
        end

        if isempty(user_vars)
            println(io, "  No variables defined")
        else
            var_info = []
            for name in user_vars
                try
                    val = getfield(Main, name)
                    val_type = typeof(val)

                    size_info = ""
                    if val_type <: AbstractArray
                        dims = size(val)
                        size_info = " [" * join(dims, "×") * "]"
                    end

                    val_str = try
                        if val_type <: AbstractArray
                            "$(eltype(val))$size_info"
                        elseif val_type <: Number
                            string(val)
                        elseif val_type <: String
                            v = string(val)
                            length(v) > 30 ? "\"$(first(v, 27))...\"" : "\"$v\""
                        elseif val_type <: Function
                            "function"
                        elseif val_type <: Type
                            "Type"
                        elseif val_type <: Module
                            "Module"
                        else
                            s = repr(val, context=:compact=>true)
                            length(s) > 35 ? s[1:32]*"..." : s
                        end
                    catch
                        "?"
                    end

                    push!(var_info, (name, val_type, val_str))
                catch
                end
            end

            if !isempty(var_info)
                println(io, "  Name              Type                Value")
                println(io, "  ────────────────  ──────────────────  ─────────────")
                for (name, vtype, vstr) in var_info
                    name_str = rpad(string(name), 16)
                    type_str = rpad(string(nameof(vtype)), 18)
                    println(io, "  $name_str  $type_str  $vstr")
                end
            end
        end

        println(io, "")
        println(io, "╭─────────────────────────────────────────╮")
        println(io, "│  <CR> print │ i inspect │ d delete       │")
        println(io, "│  r refresh  │ q close                   │")
        println(io, "╰─────────────────────────────────────────╯")
    finally
        close(io)
    end
end
nothing
]],
		workspace_tmp_file
	)

	-- Write Julia code to temp file
	local file = io.open(julia_script, "w")
	if file then
		file:write(julia_code)
		file:close()

		local cmd = string.format('include(raw"%s")', julia_script)
		send_to_backend(cmd)
	end

	vim.defer_fn(function()
		local file_content = {}
		local file = io.open(workspace_tmp_file, "r")
		if file then
			for line in file:lines() do
				table.insert(file_content, line)
			end
			file:close()
		end

		if #file_content == 0 then
			file_content = {
				"╭─────────────────────────────────────────╮",
				"│  jEMach Workspace                         │",
				"╰─────────────────────────────────────────╯",
				"",
				"  No variables defined",
			}
		end

		workspace_cache.data = file_content
		workspace_cache.last_update = vim.loop.now()

		if vim.api.nvim_buf_is_valid(workspace_bufnr) then
			vim.bo[workspace_bufnr].modifiable = true
			vim.api.nvim_buf_set_lines(workspace_bufnr, 0, -1, false, file_content)
			vim.bo[workspace_bufnr].modifiable = false
		end
	end, 500)
end

local function get_variable_under_cursor()
	local line = vim.api.nvim_get_current_line()
	local var = line:match("^%s+(%S+)%s+%S+%s*")
	return var
end

local function setup_workspace_keymaps(bufnr)
	vim.keymap.set("n", "<CR>", function()
		local var = get_variable_under_cursor()
		if var and is_repl_running() then
			send_to_backend(string.format("println(%s)", var))
			vim.notify("📤 println(" .. var .. ")", vim.log.levels.INFO)
		end
	end, { buffer = bufnr, desc = "Print variable" })

	vim.keymap.set("n", "i", function()
		local var = get_variable_under_cursor()
		if var and is_repl_running() then
			send_to_backend(string.format("@show typeof(%s); @show size(%s)", var, var))
			vim.notify("🔍 Inspecting: " .. var, vim.log.levels.INFO)
		end
	end, { buffer = bufnr, desc = "Inspect variable" })

	vim.keymap.set("n", "d", function()
		local var = get_variable_under_cursor()
		if var and is_repl_running() then
			local confirm = vim.fn.confirm(string.format("Delete '%s'?", var), "&Yes\n&No", 2)
			if confirm == 1 then
				send_to_backend(string.format("%s = nothing", var))
				vim.notify("🗑️ Deleted: " .. var, vim.log.levels.WARN)
				workspace_cache.data = nil
				vim.defer_fn(M.update_workspace_panel, 400)
			end
		end
	end, { buffer = bufnr, desc = "Delete variable" })

	vim.keymap.set("n", "r", function()
		workspace_cache.data = nil
		M.update_workspace_panel()
		vim.notify("🔄 Refreshed", vim.log.levels.INFO)
	end, { buffer = bufnr, desc = "Refresh" })

	vim.keymap.set("n", "q", function()
		if workspace_win_id and vim.api.nvim_win_is_valid(workspace_win_id) then
			vim.api.nvim_win_close(workspace_win_id, true)
			workspace_win_id = nil
			workspace_bufnr = nil
		end
	end, { buffer = bufnr, desc = "Close" })
end

function M.toggle_workspace_panel()
	if workspace_win_id and vim.api.nvim_win_is_valid(workspace_win_id) then
		vim.api.nvim_win_close(workspace_win_id, true)
		workspace_win_id = nil
		workspace_bufnr = nil
		return
	end

	workspace_bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[workspace_bufnr].buftype = "nofile"
	vim.bo[workspace_bufnr].bufhidden = "hide"
	vim.bo[workspace_bufnr].swapfile = false
	vim.bo[workspace_bufnr].filetype = "julia"
	vim.bo[workspace_bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(workspace_bufnr, 0, -1, false, { "Loading..." })
	vim.bo[workspace_bufnr].modifiable = false

	vim.cmd("set splitright")
	vim.cmd(string.format("vsplit | vertical resize %d", M.config.workspace_width))

	workspace_win_id = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(workspace_win_id, workspace_bufnr)
	vim.wo[workspace_win_id].foldenable = false
	vim.wo[workspace_win_id].spell = false
	vim.wo[workspace_win_id].number = false
	vim.wo[workspace_win_id].relativenumber = false
	vim.wo[workspace_win_id].wrap = false
	vim.wo[workspace_win_id].linebreak = false

	setup_workspace_keymaps(workspace_bufnr)

	if is_repl_running() then
		M.update_workspace_panel()
	else
		vim.bo[workspace_bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(workspace_bufnr, 0, -1, false, {
			"╭─────────────────────────────────────────╮",
			"│  jEMach Workspace                         │",
			"╰─────────────────────────────────────────╯",
			"",
			"  Start REPL first:",
			"    :Jr or <leader>jw",
			"",
			"╭─────────────────────────────────────────╮",
			"│  <CR> print │ i inspect │ d delete       │",
			"│  r refresh  │ q close                   │",
			"╰─────────────────────────────────────────╯",
		})
		vim.bo[workspace_bufnr].modifiable = false
	end
end

function M.open_term()
	vim.cmd("terminal julia -i")
	vim.cmd("startinsert")
end

function M.show_history()
	local has_telescope, telescope = pcall(require, "telescope")
	if not has_telescope then
		vim.notify("❌ Telescope.nvim not installed", vim.log.levels.ERROR)
		return
	end

	if #command_history == 0 then
		vim.notify("📭 History is empty", vim.log.levels.INFO)
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "📜 Julia REPL History",
			finder = finders.new_table({
				results = command_history,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry,
						ordinal = entry,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection and is_repl_running() then
						send_to_backend(selection.value)
						vim.notify("📤 Sent from history", vim.log.levels.INFO)
					elseif selection then
						vim.notify("⚠️ REPL not running", vim.log.levels.WARN)
					end
				end)
				return true
			end,
		})
		:find()
end

function M.set_terminal_direction(direction)
	local valid_directions = { "float", "horizontal", "vertical" }
	if not vim.tbl_contains(valid_directions, direction) then
		vim.notify("❌ Invalid direction. Use: float, horizontal, vertical", vim.log.levels.ERROR)
		return
	end

	M.config.terminal_direction = direction

	if julia_terminal_obj and is_repl_running() then
		julia_terminal_obj:close()
		vim.defer_fn(function()
			M.toggle_repl()
		end, 200)
	end

	vim.notify("📐 Terminal direction: " .. direction, vim.log.levels.INFO)
end

function M.cycle_terminal_direction()
	local directions = { "horizontal", "vertical", "float" }
	local current_idx = 1

	for i, dir in ipairs(directions) do
		if dir == M.config.terminal_direction then
			current_idx = i
			break
		end
	end

	local next_idx = (current_idx % #directions) + 1
	M.set_terminal_direction(directions[next_idx])
end

function M.save_workspace()
	if not is_repl_running() then
		vim.notify("⚠️ Julia REPL not running", vim.log.levels.WARN)
		return
	end

	local save_code = string.format(
		[[
using Serialization
const __nvim_save_path = raw"%s"
const __nvim_excluded = [:Main, :Core, :Base, :__nvim_save_path, :__nvim_excluded]

function __save_workspace()
    workspace_data = Dict{Symbol, Any}()

    all_names = names(Main, all=true)
    for name in all_names
        str_name = string(name)
        if !startswith(str_name, "#") &&
           !startswith(str_name, "__nvim") &&
           !(name in __nvim_excluded)
            try
                val = getfield(Main, name)
                # Only save serializable types (exclude Modules and Functions)
                if !(val isa Module) && !(val isa Function)
                    workspace_data[name] = val
                end
            catch e
                @warn "Could not save variable: $name" exception=e
            end
        end
    end

    try
        open(__nvim_save_path, "w") do io
            serialize(io, workspace_data)
        end
        println("✅ Workspace saved ($(length(workspace_data)) variables)")
        return true
    catch e
        @error "Failed to save workspace" exception=e
        return false
    end
end

__save_workspace()
]],
		workspace_save_file
	)

	send_to_backend(save_code)
	vim.notify("💾 Saving workspace...", vim.log.levels.INFO)
end

function M.restore_workspace()
	if not is_repl_running() then
		vim.notify("⚠️ Julia REPL not running", vim.log.levels.WARN)
		return
	end

	if vim.fn.filereadable(workspace_save_file) ~= 1 then
		vim.notify("📭 No saved workspace found", vim.log.levels.WARN)
		return
	end

	local restore_code = string.format(
		[[
using Serialization
const __nvim_restore_path = raw"%s"

function __restore_workspace()
    if !isfile(__nvim_restore_path)
        println("❌ No workspace file found")
        return false
    end

    try
        workspace_data = open(__nvim_restore_path, "r") do io
            deserialize(io)
        end

        count = 0
        for (name, val) in workspace_data
            try
                # Validate name is a valid Symbol and not trying to override Core/Base
                if name isa Symbol && !startswith(string(name), "#") &&
                   !(name in [:Main, :Core, :Base])
                    setfield!(Main, name, val)
                    count += 1
                end
            catch e
                @warn "Could not restore variable: $name" exception=e
            end
        end

        println("✅ Workspace restored ($count variables)")
        return true
    catch e
        @error "Failed to restore workspace" exception=e
        return false
    end
end

__restore_workspace()
]],
		workspace_save_file
	)

	send_to_backend(restore_code)
	vim.notify("📂 Restoring workspace...", vim.log.levels.INFO)

	if M.config.auto_update_workspace and workspace_bufnr and vim.api.nvim_buf_is_valid(workspace_bufnr) then
		vim.defer_fn(M.update_workspace_panel, 1000)
	end
end

function M.clear_saved_workspace()
	if vim.fn.filereadable(workspace_save_file) ~= 1 then
		vim.notify("📭 No saved workspace found", vim.log.levels.INFO)
		return
	end

	local confirm = vim.fn.confirm("Clear saved workspace?", "&Yes\n&No", 2)
	if confirm == 1 then
		os.remove(workspace_save_file)
		vim.notify("🗑️ Saved workspace cleared", vim.log.levels.INFO)
	end
end

function M.set_backend(backend)
	local valid_backends = { "toggleterm", "vim-slime", "auto" }
	if not vim.tbl_contains(valid_backends, backend) then
		vim.notify("❌ Invalid backend. Use: toggleterm, vim-slime, or auto", vim.log.levels.ERROR)
		return
	end

	if backend == "auto" then
		M.config.backend = detect_backend()
		vim.notify("🔍 Auto-detected backend: " .. M.config.backend, vim.log.levels.INFO)
	else
		M.config.backend = backend
		vim.notify("🔧 Backend set to: " .. backend, vim.log.levels.INFO)
	end

	-- Clear cache when switching backends
	workspace_cache.data = nil
end

function M.show_backend()
	local backend = get_active_backend()
	local backend_info = {
		"Current REPL Backend: " .. backend,
		"",
		"Available backends:",
		"  • toggleterm - Internal terminal (requires toggleterm.nvim)",
		"  • vim-slime  - External REPL via tmux/screen (requires vim-slime)",
		"  • auto       - Auto-detect based on installed plugins",
	}

	if backend == "vim-slime" then
		table.insert(backend_info, "")
		table.insert(backend_info, "vim-slime config:")
		table.insert(backend_info, "  target: " .. M.config.slime_target)
		if M.config.slime_target == "tmux" then
			table.insert(backend_info, "  socket: " .. (M.config.slime_default_config.socket_name or "default"))
			table.insert(backend_info, "  pane: " .. (M.config.slime_default_config.target_pane or "{right-of}"))
		end
	end

	vim.notify(table.concat(backend_info, "\n"), vim.log.levels.INFO)
end

local function save_code_window()
	local current_win = vim.api.nvim_get_current_win()
	local bufnr = vim.api.nvim_win_get_buf(current_win)
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })

	if buftype == "" then
		last_code_win = current_win
	end
end

local function get_repl_window()
	if M.config.terminal_type == "native" then
		if terminal_win_id and vim.api.nvim_win_is_valid(terminal_win_id) then
			return terminal_win_id
		end
		return nil
	end

	if not julia_terminal_obj or not julia_terminal_obj.window then
		return nil
	end

	if vim.api.nvim_win_is_valid(julia_terminal_obj.window) then
		return julia_terminal_obj.window
	end

	return nil
end

function M.focus_repl()
	if not is_repl_running() then
		vim.notify("⚠️ Julia REPL not running. Starting...", vim.log.levels.WARN)
		M.toggle_repl()
		return
	end

	save_code_window()

	local repl_win = get_repl_window()
	if repl_win then
		vim.api.nvim_set_current_win(repl_win)
		vim.notify("🎯 REPL focused", vim.log.levels.INFO)
	elseif M.config.terminal_type ~= "native" then -- Only toggleterm can be "hidden"
		julia_terminal_obj:toggle()
		vim.defer_fn(function()
			local new_repl_win = get_repl_window()
			if new_repl_win then
				vim.api.nvim_set_current_win(new_repl_win)
			end
		end, 100)
	end
end

function M.focus_workspace()
	if not workspace_win_id or not vim.api.nvim_win_is_valid(workspace_win_id) then
		vim.notify("⚠️ Workspace panel not open. Opening...", vim.log.levels.WARN)
		M.toggle_workspace_panel()
		return
	end

	save_code_window()
	vim.api.nvim_set_current_win(workspace_win_id)
	vim.notify("🎯 Workspace focused", vim.log.levels.INFO)
end

function M.focus_code()
	if last_code_win and vim.api.nvim_win_is_valid(last_code_win) then
		vim.api.nvim_set_current_win(last_code_win)
		vim.notify("🎯 Code editor focused", vim.log.levels.INFO)
	else
		-- Find a normal buffer window
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local bufnr = vim.api.nvim_win_get_buf(win)
			local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
			if buftype == "" then
				vim.api.nvim_set_current_win(win)
				last_code_win = win
				vim.notify("🎯 Code editor focused", vim.log.levels.INFO)
				return
			end
		end
		vim.notify("⚠️ No code buffer found", vim.log.levels.WARN)
	end
end

function M.cycle_focus()
	local current_win = vim.api.nvim_get_current_win()
	local repl_win = get_repl_window()

	-- Determine current location and move to next
	if current_win == repl_win then
		-- From REPL -> Workspace
		if workspace_win_id and vim.api.nvim_win_is_valid(workspace_win_id) then
			M.focus_workspace()
		else
			M.focus_code()
		end
	elseif current_win == workspace_win_id then
		-- From Workspace -> Code
		M.focus_code()
	else
		-- From Code -> REPL
		if is_repl_running() then
			M.focus_repl()
		elseif workspace_win_id and vim.api.nvim_win_is_valid(workspace_win_id) then
			M.focus_workspace()
		else
			vim.notify("⚠️ No Julia components active", vim.log.levels.WARN)
		end
	end
end

local function create_workspace_buffer()
	workspace_bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[workspace_bufnr].buftype = "nofile"
	vim.bo[workspace_bufnr].bufhidden = "hide"
	vim.bo[workspace_bufnr].swapfile = false
	vim.bo[workspace_bufnr].filetype = "julia"
end

function M.toggle_workflow_mode()
	if workflow_mode_active then
		if workspace_win_id and vim.api.nvim_win_is_valid(workspace_win_id) then
			vim.api.nvim_win_close(workspace_win_id, true)
			workspace_win_id = nil
			workspace_bufnr = nil
		end

		if terminal_win_id and vim.api.nvim_win_is_valid(terminal_win_id) then
			vim.api.nvim_win_close(terminal_win_id, false)
			terminal_win_id = nil
		end

		if julia_terminal_obj and is_repl_running() and M.config.terminal_type ~= "native" then
			julia_terminal_obj:close()
		end

		workflow_mode_active = false
		vim.notify("📴 Workflow mode deactivated", vim.log.levels.INFO)
	else
		workflow_mode_active = true
		vim.notify("📡 Activating Julia Workflow...", vim.log.levels.INFO)

		save_code_window()

		if M.config.layout_mode == "vertical_split" then
			local bufnr, cmd
			if not is_repl_running() then
				bufnr, cmd = start_native_terminal()
			else
				bufnr = terminal_bufnr
			end

			vim.cmd("vsplit")
			terminal_win_id = vim.api.nvim_get_current_win()
			if cmd then
				open_terminal_in_window(bufnr, cmd)
			else
				vim.api.nvim_win_set_buf(terminal_win_id, bufnr)
				-- Setup monitor for existing terminal
				vim.defer_fn(function()
					setup_repl_monitor(bufnr)
				end, 100)
			end
			vim.cmd("wincmd L")

			vim.defer_fn(function()
				if terminal_win_id and vim.api.nvim_win_is_valid(terminal_win_id) then
					vim.api.nvim_set_current_win(terminal_win_id)

					create_workspace_buffer()

					vim.cmd("split")
					workspace_win_id = vim.api.nvim_get_current_win()
					vim.api.nvim_win_set_buf(workspace_win_id, workspace_bufnr)
					vim.wo[workspace_win_id].wrap = false
					vim.wo[workspace_win_id].number = false

					setup_workspace_keymaps(workspace_bufnr)

					if is_repl_running() then
						M.update_workspace_panel()
					end

					M.focus_code()
					vim.notify(
						"✅ Julia Workflow active! Use " .. M.config.keybindings.cycle_focus .. " to cycle focus",
						vim.log.levels.INFO
					)
				end
			end, 200)
		elseif M.config.layout_mode == "unified_buffer" then
			local bufnr, cmd
			if not is_repl_running() then
				bufnr, cmd = start_native_terminal()
			else
				bufnr = terminal_bufnr
			end

			vim.cmd("vsplit")
			terminal_win_id = vim.api.nvim_get_current_win()
			if cmd then
				open_terminal_in_window(bufnr, cmd)
			else
				vim.api.nvim_win_set_buf(terminal_win_id, bufnr)
				-- Setup monitor for existing terminal
				vim.defer_fn(function()
					setup_repl_monitor(bufnr)
				end, 100)
			end
			vim.cmd("wincmd L")

			vim.defer_fn(function()
				if terminal_win_id and vim.api.nvim_win_is_valid(terminal_win_id) then
					vim.api.nvim_set_current_win(terminal_win_id)

					create_workspace_buffer()

					vim.cmd("split")
					workspace_win_id = vim.api.nvim_get_current_win()
					vim.api.nvim_win_set_buf(workspace_win_id, workspace_bufnr)
					vim.wo[workspace_win_id].wrap = false
					vim.wo[workspace_win_id].number = false

					setup_workspace_keymaps(workspace_bufnr)

					if is_repl_running() then
						M.update_workspace_panel()
					end

					M.focus_code()
					vim.notify(
						"✅ Julia Workflow active! Use " .. M.config.keybindings.cycle_focus .. " to cycle focus",
						vim.log.levels.INFO
					)
				end
			end, 200)
		else
			if not workspace_win_id or not vim.api.nvim_win_is_valid(workspace_win_id) then
				M.toggle_workspace_panel()
			end

			vim.defer_fn(function()
				if not is_repl_running() then
					local saved_direction = M.config.terminal_direction
					M.config.terminal_direction = "horizontal"
					M.toggle_repl()
					vim.defer_fn(function()
						M.config.terminal_direction = saved_direction
					end, 100)
				end

				vim.defer_fn(function()
					M.focus_code()
					vim.notify(
						"✅ Julia Workflow active! Use " .. M.config.keybindings.cycle_focus .. " to cycle focus",
						vim.log.levels.INFO
					)
				end, 400)
			end, 200)
		end
	end
end

function M.setup_global_keybindings()
	local kb = M.config.keybindings

	vim.keymap.set("n", kb.focus_repl, M.focus_repl, { desc = "Focus Julia REPL", noremap = true, silent = true })
	vim.keymap.set(
		"n",
		kb.focus_workspace,
		M.focus_workspace,
		{ desc = "Focus jEMach Workspace", noremap = true, silent = true }
	)
	vim.keymap.set("n", kb.focus_code, M.focus_code, { desc = "Focus Code Editor", noremap = true, silent = true })
	vim.keymap.set(
		"n",
		kb.cycle_focus,
		M.cycle_focus,
		{ desc = "Cycle Julia components", noremap = true, silent = true }
	)
	vim.keymap.set(
		"n",
		kb.workflow_mode,
		M.toggle_workflow_mode,
		{ desc = "Toggle Julia Workflow Mode", noremap = true, silent = true }
	)

	vim.keymap.set("n", kb.toggle_repl, M.toggle_repl, { desc = "Toggle Julia REPL", noremap = true, silent = true })

	vim.keymap.set("t", kb.toggle_repl, function()
		if M.config.terminal_type == "native" then
			M.toggle_repl()
		elseif julia_terminal_obj then
			julia_terminal_obj:toggle()
		end
	end, { desc = "Toggle Julia REPL", noremap = true, silent = true })

	vim.keymap.set("t", kb.cycle_focus, function()
		vim.cmd("stopinsert")
		vim.schedule(M.cycle_focus)
	end, { desc = "Cycle Julia components", noremap = true, silent = true })
end
function M.get_focus_component()
	if not workflow_mode_active then
		return ""
	end

	local current_win = vim.api.nvim_get_current_win()
	if not current_win or not vim.api.nvim_win_is_valid(current_win) then
		return ""
	end

	local repl_win = get_repl_window()

	if current_win == repl_win then
		return "󰨞 REPL"
	elseif current_win == workspace_win_id then
		return "workspace"
	else
		local ok, bufnr = pcall(vim.api.nvim_win_get_buf, current_win)
		if ok and bufnr then
			local buftype_ok, buftype = pcall(function()
				return vim.bo[bufnr].buftype
			end)
			if buftype_ok and buftype == "" then
				return "Code"
			end
		end
	end

	return ""
end

function M.setup_lualine()
	local ok, lualine = pcall(require, "lualine")
	if not ok then
		return
	end

	local config = lualine.get_config()
	if config.sections and config.sections.lualine_x then
		local colors = M.config.lualine_colors or {}
		table.insert(config.sections.lualine_x, 1, {
			M.get_focus_component,
			color = colors,
		})
		lualine.setup(config)
	end
end

M._is_repl_running = is_repl_running

return M
