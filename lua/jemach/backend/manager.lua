local M = {}

function M._load_backends()
    -- Force reload tmux to pick up fixes during development/updates
    if package.loaded["jemach.tmux"] then
        package.loaded["jemach.tmux"] = nil
    end

    return {
        native = require("jemach.backend.native"),
        toggleterm = require("jemach.backend.toggleterm"),
        slime = require("jemach.backend.slime"),
        zellij = require("jemach.backend.zellij"),
        tmux = require("jemach.tmux"),
    }
end

local backends = M._load_backends()

M.config = {
    backend = "auto", -- auto, native, toggleterm, vim-slime, zellij, tmux
    zellij = {
        direction = "right"
    },
    slime = {
        target = "tmux",
        config = {
            socket_name = "default",
            target_pane = "{right-of}",
        }
    }
}

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})

    -- Reload backends to ensure fresh state if setup is called again
    backends = M._load_backends()

    if M.config.backend == "auto" then
        M.config.backend = M.detect_backend()
    end
end

function M.detect_backend()
    if backends.zellij.is_available() then
        return "zellij"
    end

    if backends.tmux.is_available() then
        return "tmux"
    end

    if vim.g.slime_target ~= nil or vim.fn.exists("*slime#send") == 1 then
        return "vim-slime"
    end

    if backends.toggleterm.is_available() then
        return "toggleterm"
    end

    return "native"
end

function M.get_active_backend()
    local name = M.config.backend
    if name == "vim-slime" then name = "slime" end -- map config name to module name
    return backends[name] or backends.native
end

function M.is_running()
    return M.get_active_backend().is_running()
end

function M.start(cmd, opts)
    opts = opts or {}
    return M.get_active_backend().start(cmd, opts)
end

function M.send(text)
    local backend = M.get_active_backend()

    if M.config.backend == "zellij" then
        -- Special handling for zellij args if needed
        return backend.send_to_pane(text, M.config.zellij.direction)
    end

    return backend.send(text)
end

function M.show(direction_or_opts)
    return M.get_active_backend().show(direction_or_opts)
end

function M.hide()
    return M.get_active_backend().hide()
end

function M.toggle(direction)
    return M.get_active_backend().toggle(direction)
end

function M.get_window()
    return M.get_active_backend().get_window()
end

return M
