local jemach = require("jemach")

print("Testing jemach setup...")

-- Mock vim.fn/vim.api if running in pure luajit, but we are likely running in nvim
-- If running via `nvim -l smoke_test.lua`, we have vim global.

if not vim then
    print("Error: This script must be run with `nvim -l`")
    os.exit(1)
end

local ok, err = pcall(function()
    jemach.setup({
        backend = "native",
        picker = "auto"
    })
end)

if not ok then
    print("Setup failed: " .. tostring(err))
    os.exit(1)
end

print("Setup successful.")

-- Test backend detection
print("Backend: " .. jemach.config.backend)

-- Test picker loading
local picker = require("jemach.picker")
print("Picker module loaded.")

-- Test backend manager
local backend_manager = require("jemach.backend.manager")
print("Backend manager loaded.")

-- Test native backend
local native = require("jemach.backend.native")
if native.is_available() then
    print("Native backend is available.")
else
    print("Native backend is NOT available.")
    os.exit(1)
end

-- Test zellij backend
local zellij = require("jemach.backend.zellij")
-- It might be available or not depending on env, just checking it loads
print("Zellij module loaded.")

print("All smoke tests passed.")
