local M = {}

local julia_terminal = nil
local repl_monitor_autocmd_id = nil

function M.is_available()
	local ok, _ = pcall(require, "toggleterm")
	return ok
end

function M.is_running()
	if not julia_terminal then
		return false
	end
	if not julia_terminal.job_id then
		return false
	end
	-- Check if job is still running
	local job_status = vim.fn.jobwait({ julia_terminal.job_id }, 0)[1]
	return job_status == -1
end

local function setup_repl_monitor(bufnr, on_output)
	if not on_output then
		return
	end

	if repl_monitor_autocmd_id then
		pcall(vim.api.nvim_del_autocmd, repl_monitor_autocmd_id)
		repl_monitor_autocmd_id = nil
	end

	local last_line_count = 0

	repl_monitor_autocmd_id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = bufnr,
		callback = function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			local line_count = vim.api.nvim_buf_line_count(bufnr)
			if line_count <= last_line_count then
				last_line_count = line_count
				return
			end

			last_line_count = line_count
			local last_lines = vim.api.nvim_buf_get_lines(bufnr, math.max(0, line_count - 3), line_count, false)
			local last_text = table.concat(last_lines, "\n")

			if last_text:match("julia>") or last_text:match("@v[%d%.]+%) pkg>") or last_text:match("shell>") then
				on_output()
			end
		end,
	})
end

function M.start(cmd, opts)
	opts = opts or {}

	if M.is_running() then
		return true
	end

	local ok, terminal = pcall(require, "toggleterm.terminal")
	if not ok then
		return false
	end

	local Terminal = terminal.Terminal
	local term_config = {
		cmd = cmd,
		direction = opts.direction or "horizontal",
		size = opts.size or 15,
		on_open = function(t)
			if opts.on_output then
				setup_repl_monitor(t.bufnr, opts.on_output)
			end
			if opts.on_open then
				opts.on_open()
			end
		end,
		on_close = function(_)
			if repl_monitor_autocmd_id then
				pcall(vim.api.nvim_del_autocmd, repl_monitor_autocmd_id)
				repl_monitor_autocmd_id = nil
			end
			if opts.on_close then
				opts.on_close()
			end
		end,
		on_exit = function(_)
			if repl_monitor_autocmd_id then
				pcall(vim.api.nvim_del_autocmd, repl_monitor_autocmd_id)
				repl_monitor_autocmd_id = nil
			end
		end,
	}

	if opts.direction == "float" then
		term_config.float_opts = {
			border = "rounded",
			width = math.floor(vim.o.columns * 0.8),
			height = math.floor(vim.o.lines * 0.8),
		}
	elseif opts.direction == "vertical" then
		term_config.size = math.floor(vim.o.columns * 0.4)
	end

	julia_terminal = Terminal:new(term_config)
	julia_terminal:open()
	return true
end

function M.send(text)
	if M.is_running() then
		julia_terminal:send(text .. "\n")
		return true
	end
	return false
end

function M.show(direction)
	if M.is_running() and not julia_terminal:is_open() then
		julia_terminal:open()
		return true
	end
	return false
end

function M.hide()
	if M.is_running() and julia_terminal:is_open() then
		julia_terminal:close()
		return true
	end
	return false
end

function M.toggle(direction)
	if M.is_running() then
		julia_terminal:toggle()
		return true
	end
	return false
end

function M.get_window()
	if M.is_running() and julia_terminal.window and vim.api.nvim_win_is_valid(julia_terminal.window) then
		return julia_terminal.window
	end
	return nil
end

return M
