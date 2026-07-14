# Engineer's Notebook: jEMach.jl

Field notes and internal architecture log for `jEMach.jl` - Julia runtime introspection watcher for Neovim and terminal UI (`jl-assist`).

## Core Overview

jEMach runs an asynchronous background task inside the active Julia REPL process.
It extracts active module symbols, types, evaluated values, and project dependencies, serializing them into JSON for consumption by terminal UIs (`jl-assist`) or Neovim buffers (`lua/jemach/workspace.lua`).

#### Components

- **jEMach.jl**: Julia package exporting async background task watcher.
- **jl-assist / jl_tui.lua**: LuaJIT tmux terminal UI inspector.
- **lua/jemach/**: Neovim Lua plugin providing keybindings, buffer splits, slime/toggleterm integration, and Tree-sitter selection tools.

## Documentation Sections

- [REPL Auto-Hook (startup.jl)](startup.md): Manual setup instructions for loading `jEMach` automatically on Julia start.
- [IPC & Socket Architecture](ipc.md): UNIX domain socket server broadcasting and backup state persistence.
- [Type Introspection](types.md): Inspection rules for DataFrames, matrices, arrays, dicts, tuples, and structs.
