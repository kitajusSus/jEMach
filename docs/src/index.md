# Engineer's Notebook: jEMach.jl

Field notes and internal architecture log for `jEMach.jl` - Data-Oriented Julia runtime introspection engine and terminal workspace assistant (`jl-assist`).

## Core Overview

jEMach runs an asynchronous background task inside the active Julia REPL process.
It extracts active module symbols, types, evaluated values, and project dependencies, serializing them into a Data-Oriented Design (DoD) columnar format for consumption by terminal UIs (`jl-assist`) and Zig broker IPC.

#### Components

- **jEMach.jl**: Julia package exporting async background task watcher with Data-Oriented Design (DoD) tables.
- **jl-assist / jl_tui.lua**: LuaJIT tmux terminal UI inspector with interactive keyboard navigation.
- **zig/**: Native IPC broker with Struct-of-Arrays (SoA) data structures.

## Documentation Sections

- [REPL Auto-Hook (startup.jl)](startup.md): Manual setup instructions for loading `jEMach` automatically on Julia start.
- [IPC & Socket Architecture](ipc.md): UNIX domain socket server broadcasting and backup state persistence.
- [Type Introspection](types.md): Inspection rules for DataFrames, matrices, arrays, dicts, tuples, and structs.
