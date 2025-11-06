-- Example configurations for Harper-nvim-julia with new features
-- Choose one of the configurations below based on your preference

-- ===== Configuration 1: Vertical Split (Default) =====
-- Terminal and workspace on the right side
return {
  "kitajusSus/Harper-nvim-julia",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "nvim-lualine/lualine.nvim",
  },
  config = function()
    require("jemach").setup({
      terminal_type = "native",           -- Use native Neovim terminal
      layout_mode = "vertical_split",     -- Terminal + workspace on right
      lualine_integration = true,         -- Show focus in statusline
      
      keybindings = {
        toggle_repl = "<C-\\>",
        focus_repl = "<A-1>",
        focus_workspace = "<A-2>",
        focus_code = "<A-3>",
        cycle_focus = "<A-Tab>",
        workflow_mode = "<leader>jw",
      },
    })
  end,
}

-- ===== Configuration 2: Unified Buffer =====
-- REPL and workspace in same vertical split
--[[
return {
  "kitajusSus/Harper-nvim-julia",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "nvim-lualine/lualine.nvim",
  },
  config = function()
    require("jemach").setup({
      terminal_type = "native",
      layout_mode = "unified_buffer",     -- Single split with REPL + workspace
      lualine_integration = true,
      
      keybindings = {
        toggle_repl = "<C-\\>",
        focus_repl = "<A-1>",
        focus_workspace = "<A-2>",
        focus_code = "<A-3>",
        cycle_focus = "<A-Tab>",
        workflow_mode = "<leader>jw",
      },
    })
  end,
}
]]

-- ===== Configuration 3: Classic with Toggleterm =====
-- Original layout with toggleterm.nvim
--[[
return {
  "kitajusSus/Harper-nvim-julia",
  dependencies = {
    "akinsho/toggleterm.nvim",
    "nvim-telescope/telescope.nvim",
    "nvim-lualine/lualine.nvim",
  },
  config = function()
    require("jemach").setup({
      terminal_type = "toggleterm",       -- Use toggleterm
      layout_mode = "toggleterm",         -- Classic layout
      terminal_direction = "horizontal",  -- REPL at bottom
      lualine_integration = true,
      
      keybindings = {
        toggle_repl = "<C-\\>",
        focus_repl = "<A-1>",
        focus_workspace = "<A-2>",
        focus_code = "<A-3>",
        cycle_focus = "<A-Tab>",
        workflow_mode = "<leader>jw",
      },
    })
  end,
}
]]

-- ===== Configuration 4: Minimal =====
-- Use all defaults
--[[
return {
  "kitajusSus/Harper-nvim-julia",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "nvim-lualine/lualine.nvim",
  },
  config = function()
    require("jemach").setup()
  end,
}
]]

-- ===== Configuration 5: Custom Lualine Colors =====
-- Match your colorscheme
--[[
return {
  "kitajusSus/Harper-nvim-julia",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "nvim-lualine/lualine.nvim",
  },
  config = function()
    require("jemach").setup({
      terminal_type = "native",
      layout_mode = "vertical_split",
      lualine_integration = true,
      lualine_colors = {
        fg = "#b4befe",  -- Catppuccin lavender
        bg = "#1e1e2e",  -- Catppuccin base
      },
      
      keybindings = {
        toggle_repl = "<C-\\>",
        focus_repl = "<A-1>",
        focus_workspace = "<A-2>",
        focus_code = "<A-3>",
        cycle_focus = "<A-Tab>",
        workflow_mode = "<leader>jw",
      },
    })
  end,
}
]]

-- ===== Configuration 6: Different Keybindings =====
-- For users with Alt key conflicts
--[[
return {
  "kitajusSus/Harper-nvim-julia",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "nvim-lualine/lualine.nvim",
  },
  config = function()
    require("jemach").setup({
      terminal_type = "native",
      layout_mode = "vertical_split",
      lualine_integration = true,
      
      keybindings = {
        toggle_repl = "<C-\\>",
        focus_repl = "<leader>j1",         -- Use leader instead
        focus_workspace = "<leader>j2",
        focus_code = "<leader>j3",
        cycle_focus = "<leader>jc",        -- Leader + c for cycle
        workflow_mode = "<leader>jw",
      },
    })
  end,
}
]]

-- ===== Notes =====
--[[

Layout Modes:
1. vertical_split - Terminal on right, workspace underneath (default)
2. unified_buffer - REPL and workspace in same split
3. toggleterm - Classic layout (requires toggleterm.nvim)

Terminal Types:
1. native - Native Neovim terminal (no dependencies)
2. toggleterm - Uses toggleterm.nvim plugin

Workflow Usage:
1. Open Julia file
2. Press <leader>jw to activate workflow
3. Use Alt+1/2/3 to switch focus
4. Use Alt+Tab to cycle through components
5. Press Ctrl+\ to toggle REPL visibility

Workspace Panel Format:
- Clean format: varname :: Type = value
- No text wrapping
- Scalable with window size

Lualine Integration:
- Shows: 󰨞 REPL,  Workspace, or  Code
- Only visible when workflow mode is active
- Configurable colors

]]
