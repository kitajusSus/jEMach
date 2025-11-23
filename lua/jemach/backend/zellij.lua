local M = {}

function M.is_available()
    return vim.fn.executable("zellij") == 1 and vim.env.ZELLIJ ~= nil
end

function M.is_running()
    return M.is_available()
end

function M.start(cmd, opts)
    if not M.is_available() then return false end

    local z_cmd = string.format("zellij run --name 'Julia REPL' -- %s", cmd)
    vim.fn.system(z_cmd)
    return true
end

function M.send(text)
    -- Fallback if direction is not provided in arguments
    return M.send_to_pane(text, "right")
end

function M.send_to_pane(text, direction)
    if not M.is_available() then return false end

    local move_dir = direction or "right"
    local return_dir = ""

    if move_dir == "right" then return_dir = "left"
    elseif move_dir == "left" then return_dir = "right"
    elseif move_dir == "down" then return_dir = "up"
    elseif move_dir == "up" then return_dir = "down"
    else return_dir = "left" -- Default fallback
    end

    -- Strategy: Move focus -> Write -> Move focus back
    vim.fn.system("zellij action move-focus " .. move_dir)
    vim.fn.system("zellij action write-chars " .. vim.fn.shellescape(text .. "\n"))
    vim.fn.system("zellij action move-focus " .. return_dir)

    return true
end

function M.show(direction)
    return true
end

function M.hide()
    return true
end

function M.toggle(direction)
    return true
end

function M.get_window()
    return nil
end

return M
