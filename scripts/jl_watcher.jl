# jl_watcher.jl — Julia Background Watcher for jemach TUI
#
# Load in your Julia REPL:
#   include("scripts/jl_watcher.jl")
#
# This file is a wrapper around the jEMach package.

if !(@isdefined jEMach)
    try
        using jEMach
    catch
        # Fallback to direct include
        include(joinpath(@__DIR__, "..", "src", "jEMach.jl"))
        if !jEMach._running[]
            jEMach.start(split = false)
        end
    end
end
