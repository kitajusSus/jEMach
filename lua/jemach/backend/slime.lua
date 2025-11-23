local M = {}

function M.is_available()
	return vim.fn.exists("*slime#send") == 1 or vim.g.slime_target ~= nil
end
-- to do
function M.is_running()
	-- Difficult to check for slime, assume yes if configured
	return true
end

function M.start(cmd, opts)
	-- Slime doesn't start a process, it connects to one.
	return true
end

function M.send(text)
	if vim.fn.exists("*slime#send") == 1 then
		vim.fn["slime#send"](text .. "\n")
		return true
	end

	local target = vim.g.slime_target or "tmux"
	if target == "tmux" then
		local socket = vim.g.slime_default_socket or "default"
		local pane = vim.g.slime_default_target or "{right-of}"

		-- Attempt to find sane defaults if not set

		local cmd = string.format(
			"tmux -L %s send-keys -t %s -l %s",
			vim.fn.shellescape(socket),
			vim.fn.shellescape(pane),
			vim.fn.shellescape(text)
		)
		vim.fn.system(cmd)
		local enter_cmd =
			string.format("tmux -L %s send-keys -t %s Enter", vim.fn.shellescape(socket), vim.fn.shellescape(pane))
		vim.fn.system(enter_cmd)
		return true
	end

	return false
end
-- to do
function M.show(direction)
	return false
end

function M.hide()
	return false
end

function M.toggle(direction)
	return false
end

function M.get_window()
	return nil
end

return M
