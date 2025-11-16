local M = {}

function M.is_available()
	return vim.fn.executable("tmux") == 1 and vim.env.TMUX ~= nil
end
function M.get_session_id()
	if not M.is_available() then
		return nil
	end

	local handle = io.popen('tmux display-message -p "#{session_id}"')
	if not handle then
		return nil
	end

	local result = handle:read("*l")
	handle:close()
	return result
end
function M.list_panes()
	if not M.is_available() then
		return {}
	end

	local handle =
		io.popen('tmux list-panes -F "#{pane_id}:#{pane_index}:#{pane_active}:#{pane_current_command}:#{pane_title}"')
	if not handle then
		return {}
	end

	local panes = {}
	for line in handle:lines() do
		local id, index, active, command, title = line:match("([^:]+):([^:]+):([^:]+):([^:]+):(.+)")
		if id then
			table.insert(panes, {
				id = id,
				index = tonumber(index),
				active = active == "1",
				command = command,
				title = title,
			})
		end
	end
	handle:close()

	return panes
end
function M.find_julia_panes()
	local panes = M.list_panes()
	local julia_panes = {}

	for _, pane in ipairs(panes) do
		local cmd_lower = pane.command:lower()
		local title_lower = pane.title:lower()

		if cmd_lower:find("julia") or title_lower:find("julia") then
			table.insert(julia_panes, pane)
		end
	end

	return julia_panes
end
function M.get_or_create_julia_pane(opts)
	opts = opts or {}
	local prefer_existing = opts.prefer_existing ~= false

	if prefer_existing then
		local julia_panes = M.find_julia_panes()
		if #julia_panes > 0 then
			return julia_panes[1].id
		end
	end

	return M.create_julia_pane(opts)
end

function M.create_julia_pane(opts)
	if not M.is_available() then
		vim.notify("Not in a tmux session", vim.log.levels.ERROR)
		return nil
	end

	opts = opts or {}
	local direction = opts.direction or "horizontal"
	local size = opts.size or 15

	local split_flag = direction == "horizontal" and "-v" or "-h"
	local cmd = string.format("tmux split-window %s -l %d julia", split_flag, size)

	local success = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		vim.notify("Failed to create Julia pane: " .. success, vim.log.levels.ERROR)
		return nil
	end

	local handle = io.popen('tmux display-message -p "#{pane_id}"')
	if not handle then
		return nil
	end

	local pane_id = handle:read("*l")
	handle:close()

	return pane_id
end
function M.send_to_pane(pane_id, code)
	if not M.is_available() then
		return false
	end

	local escaped = code:gsub("'", "'\\''")

	local cmd = string.format("tmux send-keys -t %s '%s' Enter", pane_id, escaped)
	local result = vim.fn.system(cmd)

	return vim.v.shell_error == 0
end
function M.capture_pane(pane_id, lines)
	if not M.is_available() then
		return ""
	end

	lines = lines or 100
	local cmd = string.format("tmux capture-pane -t %s -p -S -%d", pane_id, lines)

	local handle = io.popen(cmd)
	if not handle then
		return ""
	end

	local content = handle:read("*a")
	handle:close()

	return content
end
function M.focus_pane(pane_id)
	if not M.is_available() then
		return false
	end

	local cmd = string.format("tmux select-pane -t %s", pane_id)
	local result = vim.fn.system(cmd)

	return vim.v.shell_error == 0
end
function M.setup_workspace(opts)
	if not M.is_available() then
		vim.notify("tmux is not available or not in a tmux session", vim.log.levels.ERROR)
		return false
	end

	opts = opts or {}
	local layout = opts.layout or "horizontal"

	if layout == "horizontal" then
		vim.fn.system("tmux split-window -v -p 30")
	elseif layout == "vertical" then
		vim.fn.system("tmux split-window -h -p 50")
	elseif layout == "grid" then
		vim.fn.system("tmux split-window -v -p 50")
		vim.fn.system("tmux split-window -h -p 50")
		vim.fn.system("tmux select-pane -t 0")
		vim.fn.system("tmux split-window -h -p 50")
	end

	if vim.v.shell_error == 0 then
		vim.notify("Julia workspace setup complete", vim.log.levels.INFO)
		return true
	else
		vim.notify("Failed to setup workspace", vim.log.levels.ERROR)
		return false
	end
end
function M.get_current_pane()
	if not M.is_available() then
		return nil
	end

	local handle = io.popen('tmux display-message -p "#{pane_id}:#{pane_index}:#{pane_current_command}"')
	if not handle then
		return nil
	end

	local line = handle:read("*l")
	handle:close()

	if not line then
		return nil
	end

	local id, index, command = line:match("([^:]+):([^:]+):(.+)")
	return {
		id = id,
		index = tonumber(index),
		command = command,
	}
end
function M.quick_send(code, opts)
	opts = opts or {}

	local pane_id = M.get_or_create_julia_pane(opts)
	if not pane_id then
		return false
	end

	return M.send_to_pane(pane_id, code)
end
function M.show_status()
	if not M.is_available() then
		vim.notify("tmux is not available", vim.log.levels.WARN)
		return
	end

	local session_id = M.get_session_id()
	local panes = M.list_panes()
	local julia_panes = M.find_julia_panes()

	local msg = string.format(
		"tmux Status:\n  Session: %s\n  Total panes: %d\n  Julia panes: %d",
		session_id or "N/A",
		#panes,
		#julia_panes
	)

	if #julia_panes > 0 then
		msg = msg .. "\n\nJulia panes:"
		for _, pane in ipairs(julia_panes) do
			msg = msg .. string.format("\n  - %s (%s)", pane.id, pane.command)
		end
	end

	vim.notify(msg, vim.log.levels.INFO)
end

return M
