local M = {}

M.bootstrap_code = [[
module Jemach

using Serialization
using InteractiveUtils: methods

const WORKSPACE_FILE = raw"%s"
const INSPECT_FILE = raw"%s"
const MAX_VAR_STRING_LEN = 60
const SEP = "|:|"

function safe_repr(val)
    try
        s = repr(val, context=:compact=>true)
        s = replace(s, "\n" => " ")
        length(s) > MAX_VAR_STRING_LEN ? s[1:MAX_VAR_STRING_LEN-3]*"..." : s
    catch
        "?"
    end
end

function get_val_info(name, val)
    val_type = typeof(val)
    val_str = ""
    summary = ""

    # Precise Type Categorization with Value Preview
    if val_type <: AbstractArray
        dims = join(size(val), "×")
        # Summary: "10×10 Matrix{Int64}" or "5-element Vector{Float64}"
        # But succinct: "10×10 Array{Int64}"
        summary = "$dims Array{$(eltype(val))}"
        val_str = summary
    elseif val_type <: Number
        val_str = string(val)
        summary = val_str # Show value directly
    elseif val_type <: AbstractString
        v = string(val)
        val_str = length(v) > 30 ? "\"$(first(v, 27))...\"" : "\"$v\""
        summary = val_str # Show string content
    elseif val_type <: AbstractDict
        n = length(val)
        val_str = "$(keytype(val))=>$(valtype(val))"
        summary = "Dict($n) {$(keytype(val))=>$(valtype(val))}"
    elseif val_type <: Symbol
        val_str = string(val)
        summary = val_str
    elseif val_type <: Regex
        val_str = string(val)
        summary = val_str
    elseif val_type <: Pair
        val_str = safe_repr(val)
        summary = val_str
    elseif val_type <: Bool
        val_str = string(val)
        summary = val_str
    elseif val_type <: Set
        n = length(val)
        summary = "Set($n) $(eltype(val))"
        val_str = safe_repr(val)
    elseif val_type <: Tuple
        n = length(val)
        summary = "Tuple($n)"
        val_str = safe_repr(val)
    elseif val_type <: Function
        ms = methods(val)
        n_methods = length(ms)
        val_str = isempty(ms) ? "function" : "$n_methods methods"

        if n_methods > 0
            m1 = first(ms)
            args = m1.sig.parameters[2:end]
            arg_str = join([string(a) for a in args], ",")
            if n_methods > 1
                summary = "($arg_str) (+$(n_methods-1))"
            else
                summary = "($arg_str)"
            end
        else
            summary = "Function"
        end
    elseif val_type <: Module
        val_str = string(val)
        summary = "Module"
    else
        # Generic fallback
        val_str = safe_repr(val)
        # For generic structs, showing the value might be too long, but let's try safe_repr
        summary = val_str
        if length(summary) > 30
             n_fields = fieldcount(val_type)
             if n_fields > 0
                 summary = "$(nameof(val_type))"
             end
        end
    end

    return (name, val_type, summary, val_str)
end

function update_workspace()
    io = open(WORKSPACE_FILE, "w")
    try
        all_names = sort(collect(names(Main, all=true)))
        user_vars = filter(all_names) do name
            s = string(name)
            !startswith(s, "#") &&
            !startswith(s, "__nvim") &&
            name ∉ (:Main, :Core, :Base, :ans, :eval, :include, :Jemach)
        end

        for name in user_vars
            try
                val = getfield(Main, name)
                (n, t, s, v) = get_val_info(name, val)
                t_str = string(nameof(t))
                println(io, "$n$SEP$t_str$SEP$s$SEP$v")
            catch
            end
        end
    finally
        close(io)
    end
end

function inspect_function(f::Function)
    ms = methods(f)
    if isempty(ms)
        return "No methods found for $f"
    end

    out = IOBuffer()
    println(out, "Function: $f")
    println(out, "$(length(ms)) methods")
    println(out, "")
    println(out, "Signature -> Return Type")
    println(out, "------------------------")

    for m in ms
        sig = m.sig
        args = sig.parameters[2:end]
        arg_strings = [string(a) for a in args]
        input_sig = join(arg_strings, ", ")

        ret_type = try
            Core.Compiler.return_type(f, Tuple{args...})
        catch
            "?"
        end

        println(out, "($input_sig) -> $ret_type")
    end

    try
        d = string(Base.Docs.doc(f))
        if !startswith(d, "No documentation found")
            println(out, "")
            println(out, "--- Documentation ---")
            println(out, d)
        end
    catch
    end

    return String(take!(out))
end

function inspect(val)
    if val isa Function
        return inspect_function(val)
    else
        out = IOBuffer()
        println(out, "Value: $val")
        println(out, "Type: $(typeof(val))")
        if val isa AbstractArray
            println(out, "Size: $(size(val))")
            println(out, "Eltype: $(eltype(val))")
        end

        try
            d = string(Base.Docs.doc(val))
            if !startswith(d, "No documentation found")
                println(out, "")
                println(out, "--- Documentation ---")
                println(out, d)
            end
        catch
        end

        return String(take!(out))
    end
end

function inspect_to_file(val)
    str = inspect(val)
    open(INSPECT_FILE, "w") do io
        print(io, str)
    end
end

end # module
]]

return M
