vim.api.nvim_create_user_command("JuliaToggleREPL", function()
	require("jemach").toggle_repl()
end, {
	desc = "Toggle Julia REPL terminal",
})

vim.api.nvim_create_user_command("JuliaSendToREPL", function()
	require("jemach").send_to_repl()
end, {
	desc = "Send current line/selection/block to Julia REPL",
	range = true,
})

vim.api.nvim_create_user_command("JuliaToggleWorkspace", function()
	require("jemach").toggle_workspace_panel()
end, {
	desc = "Toggle Julia workspace panel",
})

vim.api.nvim_create_user_command("JuliaHistory", function()
	require("jemach").show_history()
end, {
	desc = "Show Julia REPL command history",
})

vim.api.nvim_create_user_command("JuliaRefreshWorkspace", function()
	require("jemach").update_workspace_panel()
end, {
	desc = "Refresh workspace panel",
})

vim.api.nvim_create_user_command("JuliaSetTerminal", function(opts)
	require("jemach").set_terminal_direction(opts.args)
end, {
	desc = "Set Julia terminal direction (float|horizontal|vertical)",
	nargs = 1,
	complete = function()
		return { "float", "horizontal", "vertical" }
	end,
})

vim.api.nvim_create_user_command("JuliaCycleTerminal", function()
	require("jemach").cycle_terminal_direction()
end, {
	desc = "Cycle Julia terminal direction",
})

-- Simple terminal command
vim.api.nvim_create_user_command("JuliaTerm", function()
	require("jemach").open_term()
end, {
	desc = "Open Julia in a terminal window",
})

-- Convenient aliases (optional)
vim.api.nvim_create_user_command("Jr", function()
	require("jemach").toggle_repl()
end, {
	desc = "Julia: Toggle REPL (alias)",
})

vim.api.nvim_create_user_command("Js", function()
	require("jemach").send_to_repl()
end, {
	desc = "Julia: Send to REPL (alias)",
	range = true,
})

vim.api.nvim_create_user_command("Jw", function()
	require("jemach").toggle_workspace_panel()
end, {
	desc = "Julia: Toggle Workspace (alias)",
})

vim.api.nvim_create_user_command("Jh", function()
	require("jemach").show_history()
end, {
	desc = "Julia: History (alias)",
})

-- Unified workflow commands
vim.api.nvim_create_user_command("JuliaWorkflowMode", function()
	require("jemach").toggle_workflow_mode()
end, {
	desc = "Toggle Julia unified workflow mode (Terminal+REPL+Workspace)",
})

vim.api.nvim_create_user_command("JuliaFocusREPL", function()
	require("jemach").focus_repl()
end, {
	desc = "Focus Julia REPL window",
})

vim.api.nvim_create_user_command("JuliaFocusWorkspace", function()
	require("jemach").focus_workspace()
end, {
	desc = "Focus Julia workspace panel",
})

vim.api.nvim_create_user_command("JuliaFocusCode", function()
	require("jemach").focus_code()
end, {
	desc = "Focus code editor window",
})

vim.api.nvim_create_user_command("JuliaCycleFocus", function()
	require("jemach").cycle_focus()
end, {
	desc = "Cycle focus between Julia components",
})

-- Short aliases for workflow
vim.api.nvim_create_user_command("Jfw", function()
	require("jemach").toggle_workflow_mode()
end, {
	desc = "Julia: Toggle Workflow Mode (alias)",
})
