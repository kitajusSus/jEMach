# jemach
![jemachpic.png](jemachpic.png)


A comprehensive Neovim plugin for Julia development with an integrated REPL, workspace panel, and unified workflow mode for fast and efficient coding.

## Features

### 🚀 Core Features
- **Flexible REPL Backends**: Support for **Native Terminal**, **ToggleTerm**, **Tmux**, and **Zellij**
- **Modern Pickers**: Support for **Snacks.picker** and **Telescope**
- **Smart Code Sending**: Send current line, visual selection, or automatically detected code blocks
- **Workspace Panel**: Real-time view of variables, their types, and values (no text wrapping)
- **Command History**: Track and replay REPL commands
- **Workspace Persistence**: Save and restore session state across restarts
- **Project Awareness**: Automatic project activation based on Project.toml files
- **Revise.jl Support**: Optional automatic loading of Revise for interactive development
- **LSP Integration**: Full Language Server Protocol support for IDE features (optional)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "kitajusSus/jemach",
  dependencies = {
    "folke/snacks.nvim",             -- Recommended for pickers
    "akinsho/toggleterm.nvim",       -- Optional, for toggleterm backend
    "nvim-telescope/telescope.nvim", -- Optional, fallback picker
    "neovim/nvim-lspconfig",         -- Optional, for LSP features
  },
  config = function()
    require("jemach").setup({
      -- See Configuration Guide for all options
    })
  end,
}
```

## Configuration Guide

You can customize nearly every aspect of `jemach`. Here is the full list of options:

```lua
require("jemach").setup({
  -- Module Selection
  picker = "auto",  -- "auto", "snacks", "telescope"
  backend = "auto", -- "auto", "native", "toggleterm", "vim-slime", "tmux", "zellij"

  -- Terminal Configuration (for Native/ToggleTerm backends)
  terminal = {
      direction = "horizontal",  -- "horizontal", "vertical", "float"
      size = 15,                 -- Height/width of the split
  },

  -- Tmux Configuration (for "tmux" backend)
  -- Control how the REPL is created in Tmux
  tmux_isolation = "window",     -- "pane": split current window
                                 -- "window": create new window (tab) [Default]
                                 -- "session": create detached session (advanced)

  -- Automatically split the REPL window to show the Workspace log
  tmux_attach_workspace = false,  -- Set to true to enable a live workspace sidebar in Tmux
  tmux_workspace_layout = "vertical", -- "vertical" (sidebar) or "horizontal" (bottom)

  -- Live Inspector
  live_inspector = true,         -- Auto-update inspector pane/window on cursor move in Workspace

  -- Zellij Configuration
  zellij = {
      direction = "right"        -- "right", "down", "floating"
  },

  -- Workspace Behavior
  activate_project_on_start = true, -- Auto-activate Julia project
  auto_update_workspace = true,     -- Update workspace panel on every command
  workspace_width = 50,             -- Width of the workspace panel
  smart_block_detection = true,     -- Auto-select functions/blocks under cursor
  use_revise = true,                -- Load Revise.jl automatically
  auto_save_workspace = false,      -- Save workspace state on exit
  save_on_exit = true,

  -- LSP Configuration (Optional)
  lsp = {
      enabled = false,              -- Enable internal LSP setup
      auto_start = true,            -- Start LSP automatically for .jl files
      detect_imports = true,        -- Scan for missing imports
      show_import_status = true,
      default_environment = "v#.#", -- Fallback environment if no Project.toml
      julia_project = nil,          -- Force specific project path
  },

  -- Keybindings
  keybindings = {
    toggle_repl = "<C-\\>",
    focus_repl = "<A-1>",
    focus_workspace = "<A-2>",
    focus_code = "<A-3>",
    cycle_focus = "<A-Tab>",
    workflow_mode = "<leader>jw",
  },
})
```

## Backend Details

### Smart Tmux Backend (Recommended for Tmux users)
The `tmux` backend is highly optimized.
- **Window Mode (Default)**: Creates a new Tmux window (tab) for the REPL. This keeps your editor clean.
- **Pane Mode**: Splits your current editor window.
- **Live Inspector**: When browsing the Workspace panel in Neovim, a separate Tmux pane will update in real-time to show details of the variable under cursor (like `tail -f`).

### Native Terminal
Uses Neovim's built-in `:terminal`. Simple and effective.

## Usage

### Main Commands
- `:JuliaToggleREPL` (`:Jr`) - Open/Close REPL
- `:JuliaSendToREPL` (`:Js`) - Send code
- `:JuliaToggleWorkspace` (`:Jw`) - Open Workspace Panel
- `:JuliaWorkflowMode` (`:Jfw`) - Arrange windows (Code + REPL + Workspace)

### Workspace
The workspace panel shows a list of variables.
- **Summary**: Shows the value (for simple types) or dimensions/structure (for complex types).
- **Inspector**: Press `i` on a variable to see full details, documentation, and method signatures.

## License

MIT
