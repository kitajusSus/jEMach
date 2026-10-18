# jEMach

![zdjęcie](jemachpic.png)

A high-performance, Data-Oriented **Julia Workspace Assistant & REPL Monitor** with an interactive tmux TUI and native Zig IPC broker.

Inspect variables, dataframes, matrices, composite structs, and package dependencies in real time alongside your Julia REPL — completely standalone, with zero Neovim or external package requirements.

---

## Architecture Overview

`jEMach` is built around **Data-Oriented Design (DoD)** principles for minimum latency, zero GC pressure, and optimal cache locality:

- **Julia Engine (`src/jEMach.jl`)**: Asynchronous background introspection task organizing workspace symbols into a Struct-of-Arrays (SoA) columnar table (`WorkspaceTable`). Reusable buffers eliminate GC allocation overhead during periodic polling.
- **Interactive tmux TUI (`scripts/jl_tui.lua`)**: Standalone LuaJIT terminal UI connecting over UNIX domain sockets (`/tmp/jemach_<project>.sock`). Single-pass linear scan with dirty-rendering (0.0% CPU usage when idle).
- **Native Zig Broker (`zig/`)**: Ultra-fast fan-out IPC broker and SoA multi-array structures (`std.MultiArrayList`) for high-throughput zero-copy event streaming.

---

## Installation

### In Julia

```julia
julia .
]
# pkg>
add https://github.com/kitajusSus/jEMach

# or using Pkg API:
using Pkg
Pkg.add(url="https://github.com/kitajusSus/jEMach")
```

---

## Quick Start (tmux TUI)

### Option 1: Automatic Split (Recommended)

1. Start your Julia REPL inside a tmux session:
   ```bash
   julia -t auto --project=.
   ```
2. Load and start `jEMach`:
   ```julia
   using jEMach
   jEMach.start()   # Automatically opens the interactive TUI in a side pane
   ```
3. When finished:
   ```julia
   jEMach.stop()    # Stops the watcher and closes the side panel automatically
   ```

---

### Option 2: Manual Split via CLI

1. Split your current tmux window and launch the assistant:
   ```bash
   tmux split-window -h -l 60 "./scripts/jl-assist"
   ```
2. In the Julia REPL:
   ```julia
   using jEMach
   # or fallback via include:
   include("scripts/jl_watcher.jl")
   ```

---

### Auto-Hooking on Startup (Optional)

To automatically start `jEMach` whenever an interactive Julia REPL launches, add this to `~/.julia/config/startup.jl`:

```julia
if isinteractive()
    try
        using jEMach
    catch
    end
end
```

See [docs/src/startup.md](docs/src/startup.md) for advanced configuration.

---

## TUI Tabs & Navigation

The TUI provides 4 dedicated panels accessible via `1`, `2`, `3`, `4` or `Tab`:

- **`[1] Workspace`**: Real-time Data-Oriented tree view of variables, matrices, dataframes, structs, and modules.
- **`[2] History`**: REPL session command log with multi-select checkboxes (`Space`) to package commands into reusable procedures (`p`).
- **`[3] Procedures`**: Library of saved procedures with live split-view source code preview, run execution benchmarks (`Enter`), and REPL parameter editing (`e`).
- **`[4] Packages`**: Interactive project package manager (`a` add, `d` remove, `u` update).

---

## Reusable Procedures & REPL History

Turn your experimental REPL commands into parameterized, reproducible procedures with automatic AST variable analysis:

### 1. From the Interactive TUI (`jl-assist`)
1. Press `2` to switch to **History**.
2. Press `Space` to toggle `[x]` on the commands you want in your procedure.
3. Press `p` (**Make Procedure**): an inline modal dialog will prompt for the procedure name.
4. Hit `Enter`: `jEMach` extracts free variables, sets default values from your session, generates `procedures/<name>.jl`, and automatically loads it!
5. In **`[3] Procedures`**, hit `Enter` to run with profiling or `e` to edit arguments in the REPL.

### 2. Directly in Julia REPL
```julia
using jEMach

# Option A: Extract last N commands into a parameterized procedure
jEMach.make_procedure(:check_sample, last=4)

# Option B: Record commands interactively
jEMach.record(:verify_matrix)
A = rand(10, 10)
A = A + A'
e = eigen(A)
all(e.values .> -1e-5)
jEMach.record_stop()

# Run procedure with profiling (time & memory metrics tracked in TUI)
jEMach.run_procedure(:check_sample)

# List all discovered procedures and benchmark status
jEMach.list_procedures()
```

---

## TUI Keybindings

| Key | Context | Action |
|:---|:---|:---|
| `1` / `2` / `3` / `4` | Global | Jump directly to Workspace / History / Procedures / Packages |
| `Tab` / `]` / `[` | Global | Cycle to next / previous tab |
| `j` / `k` (or `↓` / `↑`) | Global | Move cursor down / up |
| `Space` | History | Toggle selection `[x]` / `[ ]` on command |
| `a` | History | Toggle select all / clear all |
| `p` | History | **Make Procedure** from selected commands (opens modal prompt) |
| `↵` (Enter) | History | Send highlighted command to REPL |
| `↵` (Enter) | Procedures | Run highlighted procedure with benchmark profiling |
| `e` | Procedures | Paste `<proc_name>()` into REPL line to customize parameters |
| `d` | Procedures | Delete procedure file from disk (with confirmation) |
| `r` | Procedures | Reload procedure definitions from disk |
| `l` / `↵` (Enter) | Workspace | Expand node **or** evaluate `println(var)` in REPL |
| `h` (or `←`) | Workspace | Collapse node / jump to parent |
| `i` | Workspace | Inspect variable details, methods, and creation history |
| `e` | Workspace | Insert variable expression directly into REPL command line |
| `d` | Workspace | Hide item from view |
| `D` | Workspace | Restore all hidden items |
| `s` | Workspace | Save clean reproducible session script |
| `a` / `d` / `u` | Packages | Add / Remove / Update package |
| `c` | Global | Clear REPL screen (`Ctrl-L`) |
| `q` / `Ctrl-C` | Global | Quit assistant |

---

## Tree & Complex Type Introspection

`jEMach` includes specialized introspection extractors for:
- **DataFrames & Tables.jl**: Column names, row counts, and column types.
- **1D Arrays & 2D Matrices**: Dimensions, element types, and value slices.
- **Dictionaries & Sets**: Key-value pairs and entry expressions.
- **Tuples & NamedTuples**: Indexed and named member access.
- **Composite Structs**: Real-time field resolution via `fieldnames(T)` and chained accessors.

```
▼ Main
    df            DataFrame (100 rows)   100×2 DataFrame
    ├─ :colA      Vector{Int64} (100 rows) [1, 2, 3...]
    └─ :colB      Vector{Float64} (100 rows) [1.0, 2.0...]
    x             Int64                  42
    my_func       Function               (2 methods)
▶ LoadedPackage   Module                 [collapsed — press l to expand]
```

---

## CLI Options (`jl-assist`)

```
./scripts/jl-assist [-p PANE_ID] [-w WIDTH] [-f]

  -p PANE_ID   Target tmux pane running Julia (auto-detected by default)
  -w WIDTH     Width of the TUI pane in columns (default: 60)
  -f           Force a new TUI pane even if one is already open
```

---

## Native Zig Broker (`zig/`)

`jEMach` comes with a native IPC broker written in Zig for fan-out PUB/SUB communication:

```bash
cd zig
zig build test   # Runs Data-Oriented Design MultiArrayList unit tests
zig build        # Builds zig-out/bin/jemach-broker
```

---

## System Requirements

- **Julia** >= 1.10
- **tmux** >= 3.0
- **luajit** (`sudo pacman -S luajit` on Arch Linux, `sudo apt install luajit` on Ubuntu/Debian)
