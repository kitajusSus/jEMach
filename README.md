# jemach

A comprehensive Neovim plugin for Julia development with an integrated REPL, workspace panel, and unified workflow mode for fast and efficient coding.


## Features

### 🚀 Core Features
- **Julia REPL Integration**: Native terminal or toggleterm.nvim support
- **Smart Code Sending**: Send current line, visual selection, or automatically detected code blocks
- **Workspace Panel**: Real-time view of variables, their types, and values (no text wrapping)
- **Command History**: Track and replay REPL commands using Telescope
- **Project Awareness**: Automatic project activation based on Project.toml files
- **Revise.jl Support**: Optional automatic loading of Revise for interactive development
- **Lualine Integration**: Shows current focus (Code/REPL/Workspace) in status line

### ✨ Layout Modes
The plugin supports multiple layout configurations:

1. **Vertical Split Mode** (default): Terminal on right, workspace underneath
2. **Unified Buffer Mode**: REPL and workspace in same vertical split
3. **Classic Mode**: Workspace on right, REPL at bottom (toggleterm)

Easy navigation between all three components with configurable keybindings!

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "kitajusSus/Harper-nvim-julia",
  dependencies = {
    "akinsho/toggleterm.nvim",  -- Optional, only if using toggleterm mode
    "nvim-telescope/telescope.nvim",  -- Optional, for command history
    "nvim-lualine/lualine.nvim",  -- Optional, for focus indicator
  },
  config = function()
    require("jemach").setup({
      -- Terminal settings
      terminal_type = "native",  -- "native" or "toggleterm"
      layout_mode = "vertical_split",  -- "vertical_split", "unified_buffer", or "toggleterm"

      -- Optional configuration
      activate_project_on_start = true,
      auto_update_workspace = true,
      workspace_width = 50,
      terminal_size = 15,
      use_revise = true,
      lualine_integration = true,

      -- Keybindings (defaults shown)
      keybindings = {
        toggle_repl = "<C-\\>",      -- Toggle REPL visibility
        focus_repl = "<A-1>",        -- Focus REPL window
        focus_workspace = "<A-2>",   -- Focus workspace panel
        focus_code = "<A-3>",        -- Focus code editor
        cycle_focus = "<A-Tab>",     -- Cycle between components
        workflow_mode = "<leader>jw", -- Toggle workflow mode
      },
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "kitajusSus/Harper-nvim-julia",
  requires = {
    "akinsho/toggleterm.nvim",
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    require("jemach").setup()
  end,
}
```

## Usage

### Commands

#### Main Commands
- `:JuliaToggleREPL` (`:Jr`) - Toggle Julia REPL terminal
- `:JuliaSendToREPL` (`:Js`) - Send current line/selection/block to REPL
- `:JuliaToggleWorkspace` (`:Jw`) - Toggle workspace panel
- `:JuliaHistory` (`:Jh`) - Show command history (requires Telescope)

#### Workflow Commands
- `:JuliaWorkflowMode` (`:Jfw`) - Toggle unified workflow mode
- `:JuliaFocusREPL` - Focus REPL window
- `:JuliaFocusWorkspace` - Focus workspace panel
- `:JuliaFocusCode` - Focus code editor
- `:JuliaCycleFocus` - Cycle focus between components

#### Terminal Direction
- `:JuliaSetTerminal [float|horizontal|vertical]` - Set terminal layout
- `:JuliaCycleTerminal` - Cycle through terminal layouts

### Default Keybindings

When configured with default settings:

| Mode | Key | Action |
|------|-----|--------|
| Normal | `<C-\>` | Toggle REPL visibility |
| Terminal | `<C-\>` | Toggle REPL visibility |
| Normal | `<A-1>` | Focus REPL window |
| Normal | `<A-2>` | Focus workspace panel |
| Normal | `<A-3>` | Focus code editor |
| Normal/Terminal | `<A-Tab>` | Cycle focus between components |
| Normal | `<leader>jw` | Toggle workflow mode |

### Workspace Panel Keybindings

When the workspace panel is focused:

| Key | Action |
|-----|--------|
| `<CR>` | Print variable value in REPL |
| `i` | Inspect variable (show type and size) |
| `d` | Delete variable (after confirmation) |
| `r` | Refresh workspace |
| `q` | Close workspace panel |

## Workflow Examples

### Quick Start Workflow

1. Open a Julia file
2. Press `<leader>jw` to activate workflow mode
3. Everything is automatically set up:
   - Workspace panel on the right
   - REPL at the bottom
   - Your code in the main window

4. Navigate quickly:
   - `<A-1>` to jump to REPL
   - `<A-2>` to check workspace
   - `<A-3>` to return to code
   - `<A-Tab>` to cycle through all

### Code Sending

```lua
-- In normal mode, cursor on line:
:Js  -- Sends current line

-- Visual selection:
-- Select code, then:
:Js  -- Sends selection

-- Smart block detection (when enabled):
-- Cursor inside a function, struct, loop, etc.
:Js  -- Automatically detects and sends the entire block
```

### Variable Inspection

1. Send code to REPL: `:Js`
2. Open workspace: `:Jw`
3. Navigate variables:
   - `<CR>` on a variable to print its value
   - `i` to inspect its type and size
   - `d` to delete it

## Configuration Options

```lua
require("jemach").setup({
  -- Terminal Settings
  terminal_type = "native",          -- "native" or "toggleterm"
  layout_mode = "vertical_split",    -- "vertical_split", "unified_buffer", or "toggleterm"
  terminal_size = 15,                -- Size for terminal splits

  -- Project Management
  activate_project_on_start = true,  -- Auto-activate Julia project
  use_revise = true,                 -- Auto-load Revise.jl

  -- Workspace Panel
  auto_update_workspace = true,      -- Auto-refresh after code execution
  workspace_width = 50,              -- Workspace panel width

  -- Code Execution
  smart_block_detection = true,      -- Auto-detect code blocks
  max_history_size = 500,            -- Max commands in history

  -- UI Integration
  lualine_integration = true,        -- Show focus in lualine

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

## Layout Modes

### Vertical Split Mode (default)
- Terminal on the right side
- Workspace panel underneath terminal
- Easy access with keyboard shortcuts

### Unified Buffer Mode
- REPL and workspace in same vertical split
- Compact layout for smaller screens
- Efficient screen usage

### Classic Toggleterm Mode
- Workspace panel on right
- REPL terminal at bottom
- Compatible with toggleterm.nvim features

## Smart Block Detection

The plugin can automatically detect and send entire code blocks:

- Functions (`function ... end`)
- Macros (`macro ... end`)
- Modules (`module ... end`)
- Structs (`struct ... end`, `mutable struct ... end`)
- Blocks (`begin ... end`, `quote ... end`, `let ... end`)
- Control flow (`for ... end`, `while ... end`, `if ... end`, `try ... end`)

When your cursor is inside any of these blocks, `:Js` will send the entire block.

## Requirements

- Neovim >= 0.8.0
- [toggleterm.nvim](https://github.com/akinsho/toggleterm.nvim) (optional, only if using toggleterm mode)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (optional, for history)
- [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) (optional, for focus indicator)
- Julia >= 1.6

## Tips & Tricks

1. **Fast Switching**: Use `<A-Tab>` to quickly cycle between REPL, workspace, and code
2. **Terminal Mode**: In terminal mode, use `<C-\>` to hide REPL without switching focus
3. **Project Root**: Place a `Project.toml` file in your project root for automatic activation
4. **Revise Workflow**: Enable `use_revise` for hot-reloading during development
5. **Custom Layouts**: Experiment with `terminal_direction` to find your preferred layout

## Troubleshooting

### REPL doesn't start
- Ensure toggleterm.nvim is installed
- Check that Julia is in your PATH: `julia --version`

### Workspace panel is empty
- Start the REPL first (`:Jr`)
- Execute some code to create variables (`:Js`)
- Manually refresh (press `r` in workspace panel)

### Keybindings don't work
- Make sure you called `setup()` in your config
- Check for conflicts with other plugins
- Customize keybindings in the setup options

## Contributing

Please feel free to submit a Pull Request with our idea


## Credits

- *My Dad and My Mum* 
- My future wife

## 
> readme is 99% created by vibes

