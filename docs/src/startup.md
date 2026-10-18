# REPL Auto-Hooking Setup

Manual configuration notes for auto-loading `jEMach` on Julia interactive sessions via `~/.julia/config/startup.jl`.

## Why Manual Hooking?

`jEMach` runs a background task using `Timer` or `@async`. To avoid overhead in non-interactive background scripts (e.g. batch jobs, CI test runners), `jEMach` should only load when `isinteractive()` is true.

## Adding to startup.jl

Location: `~/.julia/config/startup.jl` (create file if it does not exist).

#### Basic Setup (Installed Package)

If `jEMach` is added to your primary global Julia environment (`@v1.11` or default):

```julia
# ~/.julia/config/startup.jl

if isinteractive()
    try
        using jEMach
    catch e
        # Silently fail or log if jEMach is not available in the current environment
    end
end
```

#### Advanced Setup (Handling Local Project Environments)

When starting Julia with `--project=.`, global packages might not be in scope unless loaded explicitly from global specs:

```julia
# ~/.julia/config/startup.jl

if isinteractive()
    let
        # Auto-load Revise if present
        try
            using Revise
        catch
        end

        # Attempt loading jEMach from dev path or package manager
        try
            using jEMach
        catch
        end
    end
end
```

#### Behavior Verification

When configured correctly, launching `julia` in terminal starts the background watcher task. Output in `/tmp/jl_tui_state.json` will update automatically every ~2 seconds while REPL is active.
