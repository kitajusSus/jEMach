local M = {}

local backend_manager = require("jemach.backend.manager")
local picker_manager = require("jemach.picker")
local julia_payloads = require("jemach.julia_payloads")

-- Workspace state
local workspace_bufnr = nil
local workspace_win_id = nil
local workspace_tmp_file = vim.fn.stdpath("cache") .. "/jemach.log"
local inspect_tmp_file = vim.fn.stdpath("cache") .. "/jemach_inspect.log"
local history_file = vim.fn.stdpath("cache") .. "/julia_history.log"
local workspace_save_file = vim.fn.stdpath("cache") .. "/julia_workspace_save.jl"
local command_history = {}
local last_code_win = nil
local workflow_mode_active = false
local bootstrap_done = false

local workspace_cache = {
	last_update = 0,
	data = nil,
	debounce_timer = nil,
}

-- Config
M.config = {
	activate_project_on_start = true,
	auto_update_workspace = true,
	workspace_width = 50,
	max_history_size = 500,
	smart_block_detection = true,
	use_revise = true,
	workspace_style = "detailed",
	auto_save_workspace = false,
	save_on_exit = true,

	-- Modules
	picker = "auto",
	backend = "auto", -- auto, native, toggleterm, vim-slime, zellij

	-- Backend specific
	slime_target = "tmux", -- legacy support for vim-slime config
	slime_default_config = {
		socket_name = "default",
		target_pane = "{right-of}",
	},
	zellij = {
		direction = "right",
	},
	terminal = {
		direction = "horizontal", -- horizontal, vertical, float
		size = 15,
	},

	workspace_update_debounce = 300,
	use_cache = true,
	cache_ttl = 5000,
	tmux_isolation = "window", -- pane, window, session
	tmux_attach_workspace = false, -- Split the new tmux window to show workspace (Disabled by default per user request)
	tmux_workspace_layout = "vertical", -- vertical (sidebar) or horizontal (bottom)
	live_inspector = true, -- Auto-update inspector pane in tmux
	lsp = {
		enabled = false,
		auto_start = true,
		detect_imports = true,
		show_import_status = true,
		default_environment = "v#.#", -- "v#.#" or path
		julia_project = nil, -- nil (auto) or path
	},
	layout_mode = "vertical_split",
	lualine_integration = true,
	lualine_colors = nil,

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

	-- Initialize managers
	backend_manager.setup({
		backend = M.config.backend,
		zellij = M.config.zellij,
		slime = { target = M.config.slime_target, config = M.config.slime_default_config },
	})
	picker_manager.setup({ picker = M.config.picker })

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

-- Helpers
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

local function build_julia_cmd()
	local cmd_parts = { "julia" }
	if M.config.activate_project_on_start then
		local project_root = find_project_root()
		if project_root then
			table.insert(cmd_parts, string.format("--project=%s", vim.fn.shellescape(project_root)))
		else
			table.insert(cmd_parts, "--project=.")
		end
	end
	table.insert(cmd_parts, "-i")
	if M.config.use_revise then
		table.insert(cmd_parts, '-e "using Revise"')
	end
	return table.concat(cmd_parts, " ")
end

-- REPL Actions
function M.toggle_repl()
	local cmd = build_julia_cmd()
	local opts = {
		direction = M.config.terminal.direction,
		size = M.config.terminal.size,
		isolation = M.config.tmux_isolation,
		attach_workspace = M.config.tmux_attach_workspace, -- New Option
		workspace_layout = M.config.tmux_workspace_layout, -- New Option
		on_output = function()
			-- Trigger workspace update on output
			if M.config.auto_update_workspace then
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
		on_open = function()
			vim.notify("✅ Julia REPL started", vim.log.levels.INFO)
			if M.config.auto_save_workspace and vim.fn.filereadable(workspace_save_file) == 1 then
				M.restore_workspace()
			end
		end,
		on_close = function()
			if M.config.save_on_exit then
				M.save_workspace()
			end
			vim.notify("⚠️ Julia REPL closed", vim.log.levels.WARN)
		end,
	}

	if not backend_manager.is_running() then
		backend_manager.start(cmd, opts)
		if not backend_manager.get_window() then
			-- Some backends don't show immediately or manage their own windows (zellij/slime)
			-- But native/toggleterm do.
			backend_manager.show(M.config.terminal.direction)
		end
	else
		backend_manager.toggle(M.config.terminal.direction)
	end
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
	if not backend_manager.is_running() then
		vim.notify("🔄 Starting Julia REPL...", vim.log.levels.WARN)
		M.toggle_repl()
		vim.defer_fn(function()
			M.send_to_repl() -- retry once
		end, 1000)
		return
	end

	local code = get_code_to_send()
	if code == "" then
		return
	end
	add_to_history(code)
	backend_manager.send(code)
end

-- Workspace
function M.update_workspace_panel()
	if not backend_manager.is_running() then
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

	if not bootstrap_done then
		-- Use include() to load bootstrap code cleanly without dumping text to REPL
		local boot_file = vim.fn.stdpath("cache") .. "/jemach_bootstrap.jl"
		local f = io.open(boot_file, "w")
		if f then
			f:write(string.format(julia_payloads.bootstrap_code, workspace_tmp_file, inspect_tmp_file))
			f:close()

			-- Send include command (ending with ; nothing to suppress output)
			local cmd = 'include("' .. boot_file .. '"); nothing'
			if backend_manager.send(cmd) then
				bootstrap_done = true
				vim.notify("🚀 Initialized jEMach Julia helpers", vim.log.levels.INFO)
			else
				return
			end
		else
			vim.notify("❌ Failed to write bootstrap file", vim.log.levels.ERROR)
			return
		end
	end

	backend_manager.send("Jemach.update_workspace()")

	vim.defer_fn(function()
		local raw_lines = {}
		local file = io.open(workspace_tmp_file, "r")
		if file then
			for line in file:lines() do
				table.insert(raw_lines, line)
			end
			file:close()
		end

		local display_lines = {}
		local sep = "|:|"; -- matches julia_payloads.lua

		table.insert(display_lines, "╭─────────────────────────────────────────╮")
		table.insert(display_lines, "│  jEMach Workspace                         │")
		table.insert(display_lines, "╰─────────────────────────────────────────╯")
		table.insert(display_lines, "")

		if #raw_lines == 0 then
			table.insert(display_lines, "  No variables defined (or REPL busy)")
		else
			-- Parse structured data: name|:|type|:|summary|:|value
			table.insert(display_lines, string.format("  %-15s  %-15s  %s", "Name", "Type", "Summary"))
			table.insert(display_lines, string.format("  %s  %s  %s", string.rep("─", 15), string.rep("─", 15), string.rep("─", 15)))

			for _, line in ipairs(raw_lines) do
				local parts =vim.split(line, sep, {plain=true})
				if #parts >= 3 then
					local name = parts[1]
					local type_info = parts[2]
					local summary = parts[3]
					-- local value = parts[4] -- unused in list view for now

					-- Truncate if too long
					if #name > 15 then name = name:sub(1,14).."…" end
					if #type_info > 15 then type_info = type_info:sub(1,14).."…" end

					table.insert(display_lines, string.format("  %-15s  %-15s  %s", name, type_info, summary))
				end
			end
		end

		table.insert(display_lines, "")
		table.insert(display_lines, "╭─────────────────────────────────────────╮")
		table.insert(display_lines, "│  <CR> print │ i inspect │ d delete       │")
		table.insert(display_lines, "│  r refresh  │ q close                   │")
		table.insert(display_lines, "╰─────────────────────────────────────────╯")

		workspace_cache.data = display_lines
		workspace_cache.last_update = vim.loop.now()
		if vim.api.nvim_buf_is_valid(workspace_bufnr) then
			vim.bo[workspace_bufnr].modifiable = true
			vim.api.nvim_buf_set_lines(workspace_bufnr, 0, -1, false, display_lines)
			vim.bo[workspace_bufnr].modifiable = false
		end
	end, 500)
end

local function show_float_window(content)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
	vim.bo[buf].filetype = "julia"
	vim.bo[buf].modifiable = false

	local width = 80
	local height = math.min(#content + 2, 30)
	local opts = {
		relative = "editor",
		width = width,
		height = height,
		col = (vim.o.columns - width) / 2,
		row = (vim.o.lines - height) / 2,
		style = "minimal",
		border = "rounded",
		title = " jEMach Inspector ",
		title_pos = "center",
	}

	local win = vim.api.nvim_open_win(buf, true, opts)
	vim.api.nvim_win_set_option(win, "wrap", true)

	vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
	vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
end

local function perform_inspect(var)
	if not backend_manager.is_running() then return end

	if not bootstrap_done then
		-- Ensure bootstrap is loaded (reusing the clean include method)
		M.update_workspace_panel()
		-- update_workspace_panel handles bootstrap, so we just wait a bit or let it happen
		-- But to be safe and immediate:
		if not bootstrap_done then return end -- wait for next cycle
	end

	backend_manager.send(string.format("Jemach.inspect_to_file(%s)", var))

	-- If backend is tmux and live inspector is enabled, open/update the pane
	if M.config.backend == "tmux" or (M.config.backend == "auto" and backend_manager.detect_backend() == "tmux") then
		if M.config.live_inspector then
			local tmux = require("jemach.tmux")
			tmux.open_inspector_pane()
			-- Note: open_inspector_pane starts `tail -F` on the file we just wrote to.
			-- So it should update automatically.
			return -- Don't show float
		end
	end

	vim.notify("🔍 Inspecting: " .. var, vim.log.levels.INFO)

	vim.defer_fn(function()
		local file = io.open(inspect_tmp_file, "r")
		if file then
			local content = {}
			for line in file:lines() do
				table.insert(content, line)
			end
			file:close()
			if #content > 0 then
				show_float_window(content)
			else
				vim.notify("No inspection data returned", vim.log.levels.WARN)
			end
		end
	end, 500)
end

local function get_variable_under_cursor()
	local line = vim.api.nvim_get_current_line()
	-- Adjusted regex to handle the new format if needed, but the list format:
	-- "  Name             Type             Summary"
	-- "  varname          Int64            Number"
	local var = line:match("^%s+(%S+)")
	if var == "Name" or var == "No" then return nil end
	return var
end

local function setup_workspace_keymaps(bufnr)
	vim.keymap.set("n", "<CR>", function()
		local var = get_variable_under_cursor()
		if var and backend_manager.is_running() then
			backend_manager.send(string.format("println(%s)", var))
			vim.notify("📤 println(" .. var .. ")", vim.log.levels.INFO)
		end
	end, { buffer = bufnr, desc = "Print variable" })

	vim.keymap.set("n", "i", function()
		local var = get_variable_under_cursor()
		if var then
			perform_inspect(var)
		end
	end, { buffer = bufnr, desc = "Inspect variable (methods/docs)" })

	-- Live update on cursor hold/move if configured
	if M.config.live_inspector and (M.config.backend == "tmux" or M.config.backend == "auto") then
		local timer = vim.loop.new_timer()
		vim.api.nvim_create_autocmd("CursorMoved", {
			buffer = bufnr,
			callback = function()
				if timer then timer:stop() end
				timer:start(200, 0, vim.schedule_wrap(function()
					if vim.api.nvim_buf_is_valid(bufnr) then
						local var = get_variable_under_cursor()
						if var then
							perform_inspect(var)
						end
					end
				end))
			end
		})
	end

	vim.keymap.set("n", "d", function()
		local var = get_variable_under_cursor()
		if var and backend_manager.is_running() then
			local confirm = vim.fn.confirm(string.format("Delete '%s'?", var), "&Yes\n&No", 2)
			if confirm == 1 then
				backend_manager.send(string.format("%s = nothing", var))
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
			-- Also close inspector pane if it was opened
			if M.config.backend == "tmux" then
				require("jemach.tmux").close_inspector_pane()
			end
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

	if backend_manager.is_running() then
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
	if #command_history == 0 then
		vim.notify("📭 History is empty", vim.log.levels.INFO)
		return
	end

	picker_manager.show_history(command_history, function(cmd)
		if backend_manager.is_running() then
			backend_manager.send(cmd)
			vim.notify("📤 Sent from history", vim.log.levels.INFO)
		else
			vim.notify("⚠️ REPL not running", vim.log.levels.WARN)
		end
	end)
end

function M.set_terminal_direction(direction)
	local valid_directions = { "float", "horizontal", "vertical" }
	if not vim.tbl_contains(valid_directions, direction) then
		vim.notify("❌ Invalid direction. Use: float, horizontal, vertical", vim.log.levels.ERROR)
		return
	end
	M.config.terminal.direction = direction

	if backend_manager.is_running() then
		backend_manager.hide()
		vim.defer_fn(function()
			backend_manager.show(direction)
		end, 200)
	end

	vim.notify("📐 Terminal direction: " .. direction, vim.log.levels.INFO)
end

function M.cycle_terminal_direction()
	local directions = { "horizontal", "vertical", "float" }
	local current_idx = 1
	for i, dir in ipairs(directions) do
		if dir == M.config.terminal.direction then
			current_idx = i
			break
		end
	end
	local next_idx = (current_idx % #directions) + 1
	M.set_terminal_direction(directions[next_idx])
end

function M.save_workspace()
	if not backend_manager.is_running() then
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
        if !startswith(str_name, "#") && !startswith(str_name, "__nvim") && !(name in __nvim_excluded)
            try
                val = getfield(Main, name)
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
	backend_manager.send(save_code)
	vim.notify("💾 Saving workspace...", vim.log.levels.INFO)
end

function M.restore_workspace()
	if not backend_manager.is_running() then
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
                if name isa Symbol && !startswith(string(name), "#") && !(name in [:Main, :Core, :Base])
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
	backend_manager.send(restore_code)
	vim.notify("📂 Restoring workspace...", vim.log.levels.INFO)
	if M.config.auto_update_workspace then
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
	M.config.backend = backend
	backend_manager.setup({ backend = backend })

	if backend == "auto" then
		vim.notify("🔍 Auto-detected backend: " .. backend_manager.detect_backend(), vim.log.levels.INFO)
	else
		vim.notify("🔧 Backend set to: " .. backend, vim.log.levels.INFO)
	end
	workspace_cache.data = nil
end

function M.show_backend()
	local active = M.config.backend
	if active == "auto" then
		active = backend_manager.detect_backend() .. " (auto)"
	end

	local backend_info = {
		"Current REPL Backend: " .. active,
		"",
		"Available backends:",
		"  • native     - Built-in Neovim terminal",
		"  • toggleterm - Requires toggleterm.nvim",
		"  • vim-slime  - External REPL via tmux/screen",
		"  • zellij     - External REPL via Zellij",
		"  • auto       - Auto-detect",
	}
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

function M.focus_repl()
	if not backend_manager.is_running() then
		vim.notify("⚠️ Julia REPL not running. Starting...", vim.log.levels.WARN)
		M.toggle_repl()
		return
	end
	save_code_window()

	local win = backend_manager.get_window()
	if win then
		vim.api.nvim_set_current_win(win)
		vim.notify("🎯 REPL focused", vim.log.levels.INFO)
	else
		-- Backend managed (e.g., tmux/zellij or hidden toggleterm)
		backend_manager.show(M.config.terminal.direction)
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
	local repl_win = backend_manager.get_window()

	if current_win == repl_win then
		if workspace_win_id and vim.api.nvim_win_is_valid(workspace_win_id) then
			M.focus_workspace()
		else
			M.focus_code()
		end
	elseif current_win == workspace_win_id then
		M.focus_code()
	else
		if backend_manager.is_running() then
			M.focus_repl()
		elseif workspace_win_id and vim.api.nvim_win_is_valid(workspace_win_id) then
			M.focus_workspace()
		else
			vim.notify("⚠️ No Julia components active", vim.log.levels.WARN)
		end
	end
end

function M.toggle_workflow_mode()
	if workflow_mode_active then
		if workspace_win_id and vim.api.nvim_win_is_valid(workspace_win_id) then
			vim.api.nvim_win_close(workspace_win_id, true)
			workspace_win_id = nil
			workspace_bufnr = nil
		end
		if backend_manager.is_running() then
			if backend_manager.get_window() then
				backend_manager.hide()
			end
		end
		workflow_mode_active = false
		vim.notify("📴 Workflow mode deactivated", vim.log.levels.INFO)
	else
		workflow_mode_active = true
		vim.notify("📡 Activating Julia Workflow...", vim.log.levels.INFO)
		save_code_window()

		-- Ensure REPL is running (but don't show it yet if native)
		if not backend_manager.is_running() then
			-- Start it but don't let it take focus or split yet if possible, or let it default
			-- For native backend, we can control where it goes later if we hide/show
			M.toggle_repl()
			-- Toggle repl usually shows it. We might need to wait a bit.
		end

		-- Wait for REPL to be ready
		vim.defer_fn(function()
			-- 1. Open Workspace Panel (Right Side)
			if not workspace_win_id then
				M.toggle_workspace_panel()
			end

			-- 2. Split Workspace Panel to put Terminal above it
			if workspace_win_id and vim.api.nvim_win_is_valid(workspace_win_id) then
				local current_backend = M.config.backend
				if current_backend == "auto" then
					current_backend = backend_manager.detect_backend()
				end

				if current_backend == "native" then
					-- We can fully control layout for native backend
					vim.api.nvim_set_current_win(workspace_win_id)
					vim.cmd("split") -- Horizontal split
					vim.cmd("wincmd k") -- Move to top window (assuming split puts new win above, or just check)
					-- Default split puts new window ABOVE current if 'splitbelow' is off.
					-- If 'splitbelow' is on, it puts it BELOW.
					-- Let's just use wincmd to be sure we are in the top one?
					-- Or just assume current win is the new one?
					-- `split` keeps focus in the new window.
					local top_win = vim.api.nvim_get_current_win()

					-- Move the terminal here
					backend_manager.show({ win = top_win })

					-- Adjust sizes (e.g. 50/50)
					-- Windows are already 50/50 by default split
				else
					-- For other backends (toggleterm, etc), just show them normally
					backend_manager.show(M.config.terminal.direction)
				end
			end

			M.focus_code()
			vim.notify("✅ Julia Workflow active!", vim.log.levels.INFO)
		end, 300)
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
	vim.keymap.set("t", kb.toggle_repl, M.toggle_repl, { desc = "Toggle Julia REPL", noremap = true, silent = true })
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
	local repl_win = backend_manager.get_window()
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

M._is_repl_running = backend_manager.is_running -- expose for testing

return M
