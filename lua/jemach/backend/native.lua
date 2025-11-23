local M = {}

local terminal_bufnr = nil
local terminal_win_id = nil
local repl_monitor_autocmd_id = nil

function M.is_available()
	return true
end

function M.is_running()
	return terminal_bufnr and vim.api.nvim_buf_is_valid(terminal_bufnr)
end

local function setup_repl_monitor(bufnr, on_output)
	if not on_output then return end

	if repl_monitor_autocmd_id then
		pcall(vim.api.nvim_del_autocmd, repl_monitor_autocmd_id)
		repl_monitor_autocmd_id = nil
	end

	local last_line_count = 0

	repl_monitor_autocmd_id = vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = bufnr,
		callback = function()
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

	terminal_bufnr = vim.api.nvim_create_buf(false, true)
	local ok, _ = pcall(function()
		vim.bo[terminal_bufnr].bufhidden = "hide"
	end)

	if not ok then return false end

	-- We open a temporary window to start the job, then we can move it or hide it
    -- Actually `termopen` requires the buffer to be in a window to act like a normal terminal usually?
    -- No, `termopen` starts in the current buffer.

    local current_win = vim.api.nvim_get_current_win()
    local split_cmd = "split"
    if opts.direction == "vertical" then split_cmd = "vsplit" end

    vim.cmd(split_cmd)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, terminal_bufnr)

	local job_id = vim.fn.termopen(cmd, {
		on_exit = function()
			terminal_bufnr = nil
			terminal_win_id = nil
			if repl_monitor_autocmd_id then
				pcall(vim.api.nvim_del_autocmd, repl_monitor_autocmd_id)
				repl_monitor_autocmd_id = nil
			end
		end,
	})

	if job_id <= 0 then
        vim.api.nvim_win_close(win, true)
		return false
	end

    terminal_win_id = win

    -- If we just wanted to start it but not necessarily show it (though native term usually implies showing)
    -- If hide option is passed or if we want to toggle it immediately off (unlikely for start)

    if opts.on_output then
        setup_repl_monitor(terminal_bufnr, opts.on_output)
    end

    return true
end

function M.send(text)
	if not M.is_running() then return false end

	local ok, chan = pcall(function()
		return vim.bo[terminal_bufnr].channel
	end)

	if not ok or not chan or chan <= 0 then return false end

	pcall(vim.api.nvim_chan_send, chan, text .. "\n")
	return true
end

function M.show(opts)
    if not M.is_running() then return false end

    if terminal_win_id and vim.api.nvim_win_is_valid(terminal_win_id) then
        return true -- Already shown
    end

    local direction = "horizontal"
    local target_win = nil

    if type(opts) == "string" then
        direction = opts
    elseif type(opts) == "table" then
        direction = opts.direction or "horizontal"
        target_win = opts.win
    end

    if target_win and vim.api.nvim_win_is_valid(target_win) then
        terminal_win_id = target_win
        vim.api.nvim_set_current_win(terminal_win_id)
    else
        local split_cmd = "split"
        if direction == "vertical" then split_cmd = "vsplit" end
        vim.cmd(split_cmd)
        terminal_win_id = vim.api.nvim_get_current_win()
    end

    vim.api.nvim_win_set_buf(terminal_win_id, terminal_bufnr)
    vim.cmd("startinsert")
    return true
end

function M.hide()
    if terminal_win_id and vim.api.nvim_win_is_valid(terminal_win_id) then
        vim.api.nvim_win_close(terminal_win_id, false)
        terminal_win_id = nil
    end
    return true
end

function M.toggle(direction)
    if terminal_win_id and vim.api.nvim_win_is_valid(terminal_win_id) then
        return M.hide()
    else
        return M.show(direction)
    end
end

function M.get_window()
    if terminal_win_id and vim.api.nvim_win_is_valid(terminal_win_id) then
        return terminal_win_id
    end
    return nil
end

return M
