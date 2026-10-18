# src/jEMach.jl — Julia Background Watcher for jemach TUI
#
# Load in your Julia REPL:
#   using jEMach
#
# The watcher runs as a background task and writes the current workspace
# state to /tmp/jl_tui_state.json every UPDATE_INTERVAL seconds.

module jEMach

import Dates
import Pkg
import Sockets

export make_procedure, record, record_stop, run_procedure, list_procedures, get_recent_commands

const STATE_FILE = Ref{String}("/tmp/jl_tui_state.json")
const SOCKET_PATH = Ref{String}("/tmp/jemach.sock")
const UPDATE_INTERVAL = 2.0  # seconds between state refreshes

function _get_project_dir()::String
    proj_path = try Pkg.project().path catch; nothing end
    if !isnothing(proj_path) && isfile(proj_path) && !occursin(".julia/environments", proj_path)
        return dirname(proj_path)
    else
        return pwd()
    end
end

function _get_safe_name(proj_dir::String)::String
    return replace(proj_dir, r"[^a-zA-Z0-9]" => "_")
end

# ---------------------------------------------------------------------------
# Minimal JSON serialiser (no external dependencies)
# ---------------------------------------------------------------------------

function _write_json_str(buf::IO, s::AbstractString)
    write(buf, '"')
    for c in s
        if c == '"'
            write(buf, "\\\"")
        elseif c == '\\'
            write(buf, "\\\\")
        elseif c == '\n'
            write(buf, "\\n")
        elseif c == '\r'
            write(buf, "\\r")
        elseif c == '\t'
            write(buf, "\\t")
        elseif c == '\b'
            write(buf, "\\b")
        elseif c == '\f'
            write(buf, "\\f")
        elseif iscntrl(c)
            write(buf, "\\u$(lpad(string(Int(c), base = 16), 4, '0'))")
        else
            write(buf, c)
        end
    end
    write(buf, '"')
end

function _json_str(s::AbstractString)::String
    buf = IOBuffer()
    _write_json_str(buf, s)
    return String(take!(buf))
end

function _write_item_json(buf::IO, item::Dict{String, Any})
    write(buf, "{\"name\":")
    _write_json_str(buf, get(item, "name", ""))
    write(buf, ",\"kind\":")
    _write_json_str(buf, get(item, "kind", ""))
    write(buf, ",\"type\":")
    _write_json_str(buf, get(item, "type", ""))
    write(buf, ",\"value\":")
    _write_json_str(buf, get(item, "value", ""))
    write(buf, ",\"expr\":")
    _write_json_str(buf, get(item, "expr", ""))
    if haskey(item, "children")
        children = item["children"]::Vector{Dict{String, Any}}
        write(buf, ",\"children\":[")
        for (i, c) in enumerate(children)
            _write_item_json(buf, c)
            i < length(children) && write(buf, ',')
        end
        write(buf, ']')
    end
    write(buf, '}')
end

function _item_to_json(item::Dict{String, Any})::String
    buf = IOBuffer()
    _write_item_json(buf, item)
    return String(take!(buf))
end

# ---------------------------------------------------------------------------
# Data-Oriented Design (DoD) Columnar Workspace Representation
# ---------------------------------------------------------------------------

struct WorkspaceTable
    names::Vector{String}
    kinds::Vector{String}
    types::Vector{String}
    values::Vector{String}
    exprs::Vector{String}
    modules::Vector{String}
    depths::Vector{Int32}
    parent_indices::Vector{Int32}
    has_children::Vector{Bool}
end

function WorkspaceTable()
    return WorkspaceTable(
        String[],
        String[],
        String[],
        String[],
        String[],
        String[],
        Int32[],
        Int32[],
        Bool[]
    )
end

function Base.empty!(t::WorkspaceTable)
    empty!(t.names)
    empty!(t.kinds)
    empty!(t.types)
    empty!(t.values)
    empty!(t.exprs)
    empty!(t.modules)
    empty!(t.depths)
    empty!(t.parent_indices)
    empty!(t.has_children)
    return t
end

function _add_entry!(
    t::WorkspaceTable,
    name::String,
    kind::String,
    type_str::String,
    value_str::String,
    expr_str::String,
    mod_str::String,
    depth::Int,
    parent_idx::Int,
    has_children::Bool
)::Int
    push!(t.names, name)
    push!(t.kinds, kind)
    push!(t.types, type_str)
    push!(t.values, value_str)
    push!(t.exprs, expr_str)
    push!(t.modules, mod_str)
    push!(t.depths, Int32(depth))
    push!(t.parent_indices, Int32(parent_idx))
    push!(t.has_children, has_children)
    return length(t.names)
end

const _shared_workspace_table = Ref{WorkspaceTable}(WorkspaceTable())

function _collect_children_dod!(
    t::WorkspaceTable,
    val,
    parent_expr::String,
    mod_name::String,
    depth::Int,
    parent_idx::Int
)
    depth > 5 && return
    T = typeof(val)
    try
        type_name_str = string(T)
        # 1. DataFrames / Tables.jl interface
        if occursin("DataFrame", type_name_str) || (hasmethod(names, Tuple{T}) && hasmethod(getindex, Tuple{T, Symbol}))
            try
                col_names = names(val)
                r_count = size(val, 1)
                for cname in col_names[1:min(length(col_names), 20)]
                    c_str = string(cname)
                    c_col = val[!, Symbol(cname)]
                    c_expr = parent_expr * "[!, :" * c_str * "]"
                    _add_entry!(
                        t,
                        ":" * c_str,
                        "variable",
                        string(typeof(c_col)) * " (" * string(r_count) * " rows)",
                        _value_preview(c_col),
                        c_expr,
                        mod_name,
                        depth,
                        parent_idx,
                        false
                    )
                end
            catch
            end
            return
        end

        # 2. Dictionaries
        if val isa AbstractDict
            count = 0
            for (k, v) in val
                count >= 20 && break
                k_str = string(k)
                k_expr = parent_expr * "[" * repr(k) * "]"
                _add_entry!(
                    t,
                    k_str,
                    "variable",
                    string(typeof(v)),
                    _value_preview(v),
                    k_expr,
                    mod_name,
                    depth,
                    parent_idx,
                    false
                )
                count += 1
            end
        # 3. 1D Arrays
        elseif val isa AbstractArray && ndims(val) == 1
            for i in 1:min(length(val), 20)
                _add_entry!(
                    t,
                    "[$i]",
                    "variable",
                    string(typeof(val[i])),
                    _value_preview(val[i]),
                    parent_expr * "[$i]",
                    mod_name,
                    depth,
                    parent_idx,
                    false
                )
            end
        # 4. 2D Matrices / Arrays
        elseif val isa AbstractArray && ndims(val) == 2
            rows, cols = size(val)
            for i in 1:min(rows, 5)
                for j in 1:min(cols, 5)
                    _add_entry!(
                        t,
                        "[$i, $j]",
                        "variable",
                        string(eltype(val)),
                        _value_preview(val[i, j]),
                        parent_expr * "[$i, $j]",
                        mod_name,
                        depth,
                        parent_idx,
                        false
                    )
                end
            end
        # 5. Multidimensional Arrays
        elseif val isa AbstractArray && ndims(val) > 2
            _add_entry!(
                t,
                "[dimensions]",
                "variable",
                "Tuple",
                string(size(val)),
                "size(" * parent_expr * ")",
                mod_name,
                depth,
                parent_idx,
                false
            )
        # 6. Tuples and NamedTuples
        elseif val isa NamedTuple
            for name in keys(val)
                v = val[name]
                name_str = string(name)
                _add_entry!(
                    t,
                    name_str,
                    "variable",
                    string(typeof(v)),
                    _value_preview(v),
                    parent_expr * "." * name_str,
                    mod_name,
                    depth,
                    parent_idx,
                    false
                )
            end
        elseif val isa Tuple
            for (i, v) in enumerate(val)
                i > 20 && break
                _add_entry!(
                    t,
                    "[$i]",
                    "variable",
                    string(typeof(v)),
                    _value_preview(v),
                    parent_expr * "[$i]",
                    mod_name,
                    depth,
                    parent_idx,
                    false
                )
            end
        # 7. Arbitrary composite structs
        elseif !isprimitivetype(T) && T !== Module && T !== Function && T !== DataType && T !== UnionAll
            fns = fieldnames(T)
            for f in fns
                f_str = string(f)
                f_val = try getfield(val, f) catch; continue end
                _add_entry!(
                    t,
                    f_str,
                    "variable",
                    string(typeof(f_val)),
                    _value_preview(f_val),
                    parent_expr * "." * f_str,
                    mod_name,
                    depth,
                    parent_idx,
                    false
                )
            end
        end
    catch
    end
end

# ---------------------------------------------------------------------------
# Procedure Engine & REPL History
# ---------------------------------------------------------------------------

mutable struct ProcedureInfo
    name::Symbol
    signature::String
    file::String
    doc::String
    code::String
    last_run_time_ms::Float64
    last_run_alloc_bytes::Int
    last_run_status::Symbol # :ok, :error, :never
    last_run_at::String
end

const _procedures = Dict{Symbol, ProcedureInfo}()
const _recording = Ref{Bool}(false)
const _record_name = Ref{Symbol}(:proc)
const _record_start_idx = Ref{Int}(0)
const HIST_START_POS = Ref{Int}(0)

function _is_valid_user_cmd(cmd::AbstractString)::Bool
    s = strip(cmd)
    isempty(s) && return false
    if occursin("jEMach.", s) || occursin("save_clean_session", s) ||
       occursin("inspect_var", s) || occursin("publish_state", s)
        return false
    end
    return true
end

function get_recent_commands(; limit::Int = 50, session_only::Bool = false)::Vector{String}
    hist_path = joinpath(homedir(), ".julia", "logs", "repl_history.jl")
    !isfile(hist_path) && return String[]

    sz = filesize(hist_path)
    pos = 0
    if session_only && HIST_START_POS[] > 0
        pos = min(HIST_START_POS[], sz)
    else
        read_len = min(sz, 131072)
        pos = sz - read_len
    end

    content = try
        open(hist_path, "r") do f
            seek(f, pos)
            pos > 0 && readline(f)
            read(f, String)
        end
    catch
        return String[]
    end

    commands = String[]
    current_block = String[]

    for line in split(content, '\n')
        if startswith(line, "# time:")
            if !isempty(current_block)
                cmd = join(current_block, "\n")
                _is_valid_user_cmd(cmd) && push!(commands, cmd)
                empty!(current_block)
            end
        elseif !startswith(line, "#")
            clean_line = startswith(line, '\t') ? line[2:end] : line
            push!(current_block, clean_line)
        end
    end
    if !isempty(current_block)
        cmd = join(current_block, "\n")
        _is_valid_user_cmd(cmd) && push!(commands, cmd)
    end

    if length(commands) > limit
        return commands[(end - limit + 1):end]
    else
        return commands
    end
end

function get_session_commands()::Vector{String}
    return get_recent_commands(session_only = true)
end

function _load_procedures!()
    proc_dir = joinpath(_get_project_dir(), "procedures")
    !isdir(proc_dir) && return _procedures

    for file in readdir(proc_dir)
        !endswith(file, ".jl") && continue
        filepath = joinpath(proc_dir, file)
        content = try read(filepath, String) catch; continue end

        parsed = try Meta.parse("begin\n" * content * "\nend") catch; continue end
        doc_str = ""
        sig_str = ""
        func_name = Symbol(splitext(file)[1])

        for a in parsed.args
            if a isa Expr && a.head == :macrocall && length(a.args) >= 4 && a.args[1] == GlobalRef(Core, Symbol("@doc"))
                doc_str = string(a.args[3])
                fexpr = a.args[4]
                if fexpr isa Expr && fexpr.head == :function && !isempty(fexpr.args)
                    sig_str = string(fexpr.args[1])
                    fsym = fexpr.args[1]
                    if fsym isa Expr && fsym.head == :call
                        func_name = Symbol(fsym.args[1])
                    end
                end
            elseif a isa Expr && a.head == :function && !isempty(a.args)
                sig_str = string(a.args[1])
                fsym = a.args[1]
                if fsym isa Expr && fsym.head == :call
                    func_name = Symbol(fsym.args[1])
                end
            end
        end

        if isempty(sig_str)
            sig_str = string(func_name) * "()"
        end

        rel_path = relpath(filepath, _get_project_dir())
        if !haskey(_procedures, func_name)
            _procedures[func_name] = ProcedureInfo(
                func_name,
                sig_str,
                rel_path,
                strip(doc_str),
                content,
                0.0,
                0,
                :never,
                "-"
            )
        else
            p = _procedures[func_name]
            p.signature = sig_str
            p.doc = strip(doc_str)
            p.code = content
            p.file = rel_path
        end
    end
    return _procedures
end

function _is_global_or_type(sym::Symbol)::Bool
    for m in (Main, Base, Core)
        if isdefined(m, sym)
            try
                v = getfield(m, sym)
                if v isa Function || v isa DataType || v isa UnionAll || v isa Module
                    return true
                end
            catch
            end
        end
    end
    return false
end

function _collect_ast_symbols!(ex, assigned::Set{Symbol}, referenced::Set{Symbol})
    if ex isa Symbol
        push!(referenced, ex)
    elseif ex isa Expr
        if ex.head == :(=)
            lhs = ex.args[1]
            if lhs isa Symbol
                push!(assigned, lhs)
            elseif lhs isa Expr && lhs.head == :tuple
                for a in lhs.args
                    a isa Symbol && push!(assigned, a)
                end
            end
            if length(ex.args) >= 2
                _collect_ast_symbols!(ex.args[2], assigned, referenced)
            end
        elseif ex.head == :call
            for a in ex.args
                _collect_ast_symbols!(a, assigned, referenced)
            end
        elseif ex.head == :macrocall
            for i in 2:length(ex.args)
                _collect_ast_symbols!(ex.args[i], assigned, referenced)
            end
        elseif ex.head == :.
            _collect_ast_symbols!(ex.args[1], assigned, referenced)
        else
            for a in ex.args
                _collect_ast_symbols!(a, assigned, referenced)
            end
        end
    end
end

function _default_param_str(sym::Symbol)::Tuple{String, Bool}
    if isdefined(Main, sym)
        val = try getfield(Main, sym) catch; nothing end
        if !isnothing(val)
            try
                rep = repr(val)
                if length(rep) <= 80 && !occursin('\n', rep)
                    return (string(sym) * " = " * rep, true)
                else
                    return (string(sym) * " = Main." * string(sym), true)
                end
            catch
                return (string(sym) * " = Main." * string(sym), true)
            end
        end
    end
    return (string(sym), false)
end

function make_procedure(
    name::Union{Symbol, AbstractString};
    last::Int = 0,
    indices::Vector{Int} = Int[],
    commands::Vector{String} = String[],
    params::Vector{Symbol} = Symbol[],
    doc::String = "",
    save::Bool = true
)
    proc_name = Symbol(name)
    all_cmds = get_recent_commands(limit = 100)

    cmds = String[]
    if !isempty(commands)
        cmds = copy(commands)
    elseif !isempty(indices)
        sort!(indices)
        cmds = [all_cmds[i] for i in indices if 1 <= i <= length(all_cmds)]
    elseif last > 0
        cmds = all_cmds[max(1, end - last + 1):end]
    else
        cmds = all_cmds[max(1, end - 4):end]
    end

    cmds = filter(c -> !isempty(strip(c)) && !occursin("make_procedure", c), cmds)
    if isempty(cmds)
        @warn "No commands found to create procedure '$proc_name'"
        return nothing
    end

    assigned = Set{Symbol}()
    referenced = Set{Symbol}()
    parsed_exprs = Expr[]

    for cmd in cmds
        ex = try Meta.parse("begin\n" * cmd * "\nend") catch; nothing end
        if !isnothing(ex)
            push!(parsed_exprs, ex)
            _collect_ast_symbols!(ex, assigned, referenced)
        end
    end

    free_syms = setdiff(referenced, assigned)
    detected_params = filter(s -> !startswith(string(s), "@") && !_is_global_or_type(s), collect(free_syms))

    final_params = !isempty(params) ? params : sort(detected_params, by = string)

    required_params = String[]
    default_params = String[]
    for p in final_params
        (p_str, has_default) = _default_param_str(p)
        if has_default
            push!(default_params, p_str)
        else
            push!(required_params, p_str)
        end
    end
    sig_args = join(vcat(required_params, default_params), ", ")
    func_sig = "$(proc_name)($sig_args)"

    body_lines = String[]
    for (i, cmd) in enumerate(cmds)
        for line in split(cmd, '\n')
            push!(body_lines, "    " * line)
        end
    end

    last_ex = !isempty(parsed_exprs) ? parsed_exprs[end] : nothing
    if !isnothing(last_ex) && last_ex isa Expr && last_ex.head == :block
        sub_args = filter(a -> !(a isa LineNumberNode), last_ex.args)
        if !isempty(sub_args)
            leaf = sub_args[end]
            if leaf isa Expr && leaf.head == :(=) && leaf.args[1] isa Symbol
                push!(body_lines, "    return " * string(leaf.args[1]))
            end
        end
    end

    body_code = join(body_lines, "\n")
    timestamp = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
    doc_text = isempty(doc) ? "Automated procedure extracted from Julia REPL." : doc

    code = """
# Generated by jEMach on $timestamp
\"\"\"
    $func_sig

$doc_text
\"\"\"
function $func_sig
$body_code
end
"""

    if save
        proc_dir = joinpath(_get_project_dir(), "procedures")
        !isdir(proc_dir) && mkpath(proc_dir)
        filepath = joinpath(proc_dir, string(proc_name) * ".jl")
        write(filepath, code)

        try
            Base.include(Main, filepath)
        catch e
            @warn "Failed to evaluate generated procedure in Main" exception = e
        end

        rel_path = relpath(filepath, _get_project_dir())
        _procedures[proc_name] = ProcedureInfo(
            proc_name,
            func_sig,
            rel_path,
            doc_text,
            code,
            0.0,
            0,
            :never,
            "-"
        )
        publish_state()

        green = "\e[32m\e[1m"
        reset = "\e[0m"
        cyan = "\e[36m"
        println("\n" * green * "✓" * reset * " Procedure " * cyan * "$proc_name" * reset * " created in " * green * "$rel_path" * reset)
        println("  Callable in REPL: " * cyan * "$func_sig" * reset * "\n")
    end

    return code
end

function record(name::Union{Symbol, AbstractString} = :proc)
    _recording[] = true
    _record_name[] = Symbol(name)
    all_cmds = get_recent_commands(limit = 1000)
    _record_start_idx[] = length(all_cmds) + 1
    cyan = "\e[36m"
    bold = "\e[1m"
    reset = "\e[0m"
    println(bold * cyan * "⏺ [jEMach] Recording procedure '$(_record_name[])'..." * reset)
    println("  Execute your commands in the REPL. When done, call " * bold * "jEMach.record_stop()" * reset)
    return nothing
end

function record_stop(; save::Bool = true)
    if !_recording[]
        println("No procedure recording is in progress.")
        return nothing
    end
    _recording[] = false
    all_cmds = get_recent_commands(limit = 1000)
    start_i = min(_record_start_idx[], length(all_cmds))
    cmds = (start_i <= length(all_cmds)) ? all_cmds[start_i:end] : String[]
    cmds = filter(c -> !occursin("record_stop", c), cmds)
    return make_procedure(_record_name[]; commands = cmds, save = save)
end

function run_procedure(name::Union{Symbol, AbstractString}, args...; kwargs...)
    sym = Symbol(name)
    proc_file = joinpath(_get_project_dir(), "procedures", string(sym) * ".jl")
    if isfile(proc_file)
        try
            Base.include(Main, proc_file)
        catch e
            @warn "Failed to reload $proc_file" exception = e
        end
    end

    if !isdefined(Main, sym)
        error("Procedure '$sym' not found in Main or procedures/$sym.jl")
    end
    func = getfield(Main, sym)

    println("▶ Running procedure '$sym'...")
    t_res = @timed try
        Base.invokelatest(func, args...; kwargs...)
    catch e
        e
    end

    val = t_res.value
    is_err = val isa Exception
    status_sym = is_err ? :error : :ok
    time_ms = round(t_res.time * 1000, digits = 2)
    alloc_bytes = t_res.bytes
    now_str = Dates.format(Dates.now(), "HH:MM:SS")

    if haskey(_procedures, sym)
        p = _procedures[sym]
        p.last_run_time_ms = time_ms
        p.last_run_alloc_bytes = alloc_bytes
        p.last_run_status = status_sym
        p.last_run_at = now_str
    else
        _procedures[sym] = ProcedureInfo(
            sym,
            string(sym) * "()",
            isfile(proc_file) ? relpath(proc_file, _get_project_dir()) : "",
            "",
            "",
            time_ms,
            alloc_bytes,
            status_sym,
            now_str
        )
    end
    publish_state()

    green = "\e[32m\e[1m"
    red = "\e[31m\e[1m"
    reset = "\e[0m"
    if is_err
        println(red * "✗ Procedure '$sym' failed in $(time_ms)ms" * reset)
        throw(val)
    else
        println(green * "✓ Procedure '$sym' completed in $(time_ms)ms ($(Base.format_bytes(alloc_bytes)) allocated)" * reset)
        return val
    end
end

function list_procedures()
    _load_procedures!()
    if isempty(_procedures)
        println("No procedures defined. Create one with jEMach.make_procedure(:name, last=5)")
        return nothing
    end
    bold = "\e[1m"
    cyan = "\e[36m"
    green = "\e[32m"
    yellow = "\e[33m"
    red = "\e[31m"
    reset = "\e[0m"

    println(bold * "Available Procedures:" * reset)
    for p in sort(collect(values(_procedures)), by = p -> string(p.name))
        status_icon = (p.last_run_status == :ok) ? (green * "✓" * reset) :
                      (p.last_run_status == :error) ? (red * "✗" * reset) : "○"
        time_str = (p.last_run_status != :never) ? " ($(p.last_run_time_ms)ms, $(Base.format_bytes(p.last_run_alloc_bytes)))" : ""
        println("  $status_icon " * cyan * bold * string(p.name) * reset * " → " * p.signature * yellow * time_str * reset)
        println("    " * "\e[2m" * p.file * reset)
    end
    return nothing
end

function _serialize_dod(t::WorkspaceTable, packages_data::Vector)::String
    buf = IOBuffer()
    write(buf, "{\"timestamp\":")
    write(buf, string(round(Int, time())))
    write(buf, ",\"columns\":{")

    write(buf, "\"names\":[")
    for (i, n) in enumerate(t.names)
        _write_json_str(buf, n)
        i < length(t.names) && write(buf, ',')
    end

    write(buf, "],\"kinds\":[")
    for (i, k) in enumerate(t.kinds)
        _write_json_str(buf, k)
        i < length(t.kinds) && write(buf, ',')
    end

    write(buf, "],\"types\":[")
    for (i, tp) in enumerate(t.types)
        _write_json_str(buf, tp)
        i < length(t.types) && write(buf, ',')
    end

    write(buf, "],\"values\":[")
    for (i, v) in enumerate(t.values)
        _write_json_str(buf, v)
        i < length(t.values) && write(buf, ',')
    end

    write(buf, "],\"exprs\":[")
    for (i, e) in enumerate(t.exprs)
        _write_json_str(buf, e)
        i < length(t.exprs) && write(buf, ',')
    end

    write(buf, "],\"modules\":[")
    for (i, m) in enumerate(t.modules)
        _write_json_str(buf, m)
        i < length(t.modules) && write(buf, ',')
    end

    write(buf, "],\"depths\":[")
    for (i, d) in enumerate(t.depths)
        write(buf, string(d))
        i < length(t.depths) && write(buf, ',')
    end

    write(buf, "],\"parent_indices\":[")
    for (i, p) in enumerate(t.parent_indices)
        write(buf, string(p))
        i < length(t.parent_indices) && write(buf, ',')
    end

    write(buf, "],\"has_children\":[")
    for (i, hc) in enumerate(t.has_children)
        write(buf, hc ? "true" : "false")
        i < length(t.has_children) && write(buf, ',')
    end

    write(buf, "]},\"packages\":[")
    for (i, pkg) in enumerate(packages_data)
        write(buf, "{\"name\":")
        _write_json_str(buf, get(pkg, "name", ""))
        write(buf, ",\"version\":")
        _write_json_str(buf, get(pkg, "version", ""))
        write(buf, '}')
        i < length(packages_data) && write(buf, ',')
    end

    write(buf, "],\"procedures\":[")
    proc_list = sort(collect(values(_procedures)), by = p -> string(p.name))
    for (i, p) in enumerate(proc_list)
        write(buf, "{\"name\":")
        _write_json_str(buf, string(p.name))
        write(buf, ",\"signature\":")
        _write_json_str(buf, p.signature)
        write(buf, ",\"file\":")
        _write_json_str(buf, p.file)
        write(buf, ",\"doc\":")
        _write_json_str(buf, p.doc)
        write(buf, ",\"code\":")
        _write_json_str(buf, p.code)
        write(buf, ",\"time_ms\":")
        write(buf, string(p.last_run_time_ms))
        write(buf, ",\"alloc_bytes\":")
        write(buf, string(p.last_run_alloc_bytes))
        write(buf, ",\"status\":")
        _write_json_str(buf, string(p.last_run_status))
        write(buf, ",\"last_run\":")
        _write_json_str(buf, p.last_run_at)
        write(buf, '}')
        i < length(proc_list) && write(buf, ',')
    end

    write(buf, "],\"history\":[")
    recent_cmds = get_recent_commands(limit = 60)
    for (i, cmd) in enumerate(recent_cmds)
        _write_json_str(buf, cmd)
        i < length(recent_cmds) && write(buf, ',')
    end
    write(buf, "]}")
    return String(take!(buf))
end

function _serialize(modules_data::Vector, packages_data::Vector)::String
    return _serialize_dod(_shared_workspace_table[], packages_data)
end

const _cached_pkgs = Ref{Vector{Dict{String, String}}}(Dict{String, String}[])
const _last_pkg_mtime = Ref{Float64}(0.0)

function _get_packages()::Vector{Dict{String, String}}
    proj_dir = _get_project_dir()
    proj_file = joinpath(proj_dir, "Project.toml")
    mtime_proj = isfile(proj_file) ? mtime(proj_file) : 0.0

    if !isempty(_cached_pkgs[]) && mtime_proj == _last_pkg_mtime[]
        return _cached_pkgs[]
    end

    pkgs = Dict{String, String}[]
    try
        for (name, uuid) in Pkg.project().dependencies
            ver = "unknown"
            try
                dep_info = Pkg.dependencies()[uuid]
                if dep_info.version !== nothing
                    ver = string(dep_info.version)
                end
            catch
            end
            push!(pkgs, Dict("name" => name, "version" => ver))
        end
        sort!(pkgs; by = x -> x["name"])
        _cached_pkgs[] = pkgs
        _last_pkg_mtime[] = mtime_proj
    catch e
    end
    return _cached_pkgs[]
end

# ---------------------------------------------------------------------------
# Workspace introspection
# ---------------------------------------------------------------------------

# Names that are always present in a fresh REPL and clutter the view
const _BUILTIN_NAMES = Set(
    [
        "ans", "err", "eval", "include",
        "Base", "Core", "Main", "InteractiveUtils",
    ]
)

const _SKIP_PREFIXES = ("#", "_REPL", "REPL", "IJulia")

function _skip_name(s::String)::Bool
    s in _BUILTIN_NAMES && return true
    for pfx in _SKIP_PREFIXES
        startswith(s, pfx) && return true
    end
    return false
end

function _value_preview(val)::String
    val isa Number && return string(val)
    val isa Bool && return string(val)
    val isa Symbol && return string(val)
    if val isa AbstractString
        return length(val) > 60 ? repr(val[1:min(end, 57)]) * "…" : repr(val)
    end
    return try
        s = sprint((io, x) -> Base.invokelatest(show, io, x), val; context = IOContext(devnull, :limit => true, :compact => true))
        s = replace(s, '\n' => ' ')
        length(s) > 60 ? s[1:60] * "…" : s
    catch
        "<?>"
    end
end

function _collect_module_items_dod!(t::WorkspaceTable, mod::Module, mod_name::String, all::Bool)
    syms = Base.invokelatest(names, mod; all = all, imported = false)
    candidates = Tuple{Symbol, String, Any, String}[]
    for sym in syms
        name = string(sym)
        _skip_name(name) && continue
        val = try
            Base.invokelatest(getfield, mod, sym)
        catch
            continue
        end
        kind = if isa(val, Function)
            "function"
        elseif isa(val, Module)
            "module"
        elseif isa(val, DataType) || isa(val, UnionAll)
            "type"
        else
            "variable"
        end
        kind == "module" && continue
        push!(candidates, (sym, name, val, kind))
    end

    sort!(candidates; by = x -> (x[4] == "variable" ? 0 : 1, x[2]))

    for (_, name, val, kind) in candidates
        type_str = string(typeof(val))
        value_str = ""
        if kind == "variable"
            if all || isa(val, Number) || isa(val, AbstractString) || isa(val, Symbol) || isa(val, Bool)
                value_str = _value_preview(val)
            end
        elseif kind == "function"
            try
                ms = methods(val)
                value_str = "($(length(ms)) method" * (length(ms) == 1 ? "" : "s") * ")"
            catch
                value_str = "(function)"
            end
        elseif kind == "type"
            value_str = "(type)"
        end

        item_expr = (mod == Main) ? name : (mod_name * "." * name)
        
        has_kids = (kind == "variable") && (
            val isa AbstractDict || 
            (val isa AbstractArray && length(val) > 0) || 
            val isa Tuple || 
            val isa NamedTuple || 
            (!isprimitivetype(typeof(val)) && typeof(val) !== Module && typeof(val) !== Function && typeof(val) !== DataType && typeof(val) !== UnionAll)
        )

        entry_idx = _add_entry!(t, name, kind, type_str, value_str, item_expr, mod_name, 0, -1, has_kids)
        if has_kids
            _collect_children_dod!(t, val, item_expr, mod_name, 1, entry_idx)
        end
    end
end

function _get_items(mod::Module, all::Bool)::Vector{Dict{String, Any}}
    return Dict{String, Any}[]
end

function inspect_var(mod::Module, expr_str::String)
    val = try
        expr = Meta.parse(expr_str)
        Base.invokelatest(Core.eval, mod, expr)
    catch
        println("Could not evaluate expression $expr_str in module $mod.")
        return nothing
    end

    # ANSI styles
    bold = "\e[1m"
    green = "\e[32m"
    reset = "\e[0m"

    println("\n" * green * bold * "━"^60 * reset)
    println(bold * "Variable:      " * reset * "$mod.$expr_str")
    println(bold * "Type:          " * reset * "$(typeof(val))")
    if hasmethod(size, Tuple{typeof(val)})
        try
            println(bold * "Size:          " * reset * "$(size(val))")
        catch
        end
    end

    # Methods & Return Types
    if isa(val, Function) || (hasmethod(methods, Tuple{typeof(val)}) && !isempty(methods(val)))
        try
            ms = methods(val)
            println(bold * "Methods & Return Types:" * reset)
            for m in first(ms, 15)
                temp = m.sig
                while temp isa UnionAll
                    temp = temp.body
                end
                params = temp.parameters
                sig_types = Tuple{params[2:end]...}
                rts = Base.return_types(val, sig_types)
                rt = isempty(rts) ? "Any" : rts[1]
                m_str = sprint(show, m)
                sig_part = split(m_str, " @ ")[1]
                println("  ", sig_part, " -> ", rt)
            end
            if length(ms) > 15
                println("  ... ($(length(ms) - 15) more methods)")
            end
            println()
        catch
        end
    end

    # Search REPL history for creation/assignment (read only last 64KB for speed)
    base_m = match(r"^[a-zA-Z_][a-zA-Z0-9_]*", expr_str)
    base_var_str = isnothing(base_m) ? expr_str : base_m.match
    sym = Symbol(base_var_str)

    hist_path = joinpath(homedir(), ".julia", "logs", "repl_history.jl")
    if isfile(hist_path)
        try
            sz = filesize(hist_path)
            read_len = min(sz, 65536)
            lines = open(hist_path, "r") do f
                seek(f, sz - read_len)
                read_len < sz && readline(f) # discard partial line
                readlines(f)
            end
            var_regex = Regex("\\b" * base_var_str * "\\b")
            found_cmd = ""
            current_block = String[]
            for line in reverse(lines)
                if startswith(line, "# time:")
                    block_str = join(reverse(current_block), "\n")
                    if occursin(var_regex, block_str) && occursin(r"=|function|macro|struct", block_str)
                        if !occursin("inspect_var", block_str) && !occursin("println", block_str) && !occursin("typeof", block_str) && !occursin("dump", block_str)
                            found_cmd = block_str
                            break
                        end
                    end
                    empty!(current_block)
                elseif !startswith(line, "#")
                    push!(current_block, line)
                end
            end
            if !isempty(found_cmd)
                println(bold * "Created/Modified by:" * reset)
                code_md = Base.Docs.Markdown.parse("```julia\n" * found_cmd * "\n```")
                show(IOContext(stdout, :color => true), MIME("text/plain"), code_md)
                println()
            end
        catch
        end
    end

    # Documentation
    try
        doc = Base.Docs.doc(Base.Docs.Binding(mod, sym))
        doc_str = string(doc)
        if !isempty(doc_str) && !occursin("No documentation found", doc_str)
            println(bold * "Documentation:" * reset)
            show(IOContext(stdout, :color => true), MIME("text/plain"), doc)
            println()
        end
    catch
    end
    println(green * bold * "━"^60 * reset)
    return nothing
end

function _collect_state_dod!(t::WorkspaceTable)::WorkspaceTable
    empty!(t)

    # 1. Main module — always first
    _collect_module_items_dod!(t, Main, "Main", true)

    # 2. Collect modules explicitly loaded/imported in Main
    user_loaded_modules = Set{Module}()
    for sym in Base.invokelatest(names, Main; all = true, imported = true)
        try
            val = Base.invokelatest(getfield, Main, sym)
            if isa(val, Module)
                push!(user_loaded_modules, val)
            end
        catch
        end
    end

    # 3. Other loaded packages (from Base.loaded_modules)
    seen = Set(["Main", "Base", "Core"])
    for (_, mod) in Base.loaded_modules
        name = string(mod)
        name in seen && continue
        if mod in user_loaded_modules
            push!(seen, name)
            _collect_module_items_dod!(t, mod, name, false)
        end
    end

    return t
end

function _collect_state()
    return _collect_state_dod!(_shared_workspace_table[])
end

function save_clean_session()
    cmds = get_session_commands()
    if isempty(cmds)
        println("\nNo commands found in the current session.")
        return nothing
    end

    # Create a unique sandbox module to test evaluation
    sandbox_name = Symbol("Sandbox_", round(Int, time()))
    sandbox_mod = Module(sandbox_name)
    # Import Base and Core in sandbox so standard functions work
    Core.eval(sandbox_mod, :(using Base))

    successful_cmds = String[]

    for cmd in cmds
        # Skip TUI commands or watcher commands to avoid noise
        if occursin("jEMach", cmd) || occursin("inspect_var", cmd) || occursin("STATE_FILE", cmd) || occursin("save_clean_session", cmd)
            continue
        end

        # Parse the command
        expr = try
            Meta.parse(cmd)
        catch
            nothing
        end
        expr === nothing && continue

        # Try evaluating in the sandbox
        try
            Base.invokelatest(Core.eval, sandbox_mod, expr)
            push!(successful_cmds, cmd)
        catch e
            # Skip failed command
        end
    end

    if isempty(successful_cmds)
        println("\nNo successful commands to save.")
        return nothing
    end

    # Determine the project directory (workspace root)
    proj_dir = pwd()
    if !isfile(joinpath(proj_dir, "Project.toml"))
        proj_dir = dirname(dirname(@__FILE__))
    end

    jemach_dir = joinpath(proj_dir, "jemach")
    if !isdir(jemach_dir)
        mkpath(jemach_dir)
    end

    timestamp_str = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    filename = "repl_session_$(timestamp_str).jl"
    filepath = joinpath(jemach_dir, filename)

    open(filepath, "w") do f
        write(f, "# Clean Julia REPL session saved on $(Dates.now())\n")
        write(f, "# Generated by jEMach\n\n")
        for cmd in successful_cmds
            write(f, cmd)
            write(f, "\n\n")
        end
    end

    println("\n" * "✓"^60)
    println(" Clean REPL session saved successfully!")
    println(" File: $filepath")
    println(" " * "✓"^60)
    return nothing
end

function compile_sysimage(extra_pkgs::Vector{Symbol} = Symbol[])
    println("Starting jEMach system image compilation...")

    # 1. Ensure PackageCompiler is installed in the global environment
    current_project = Pkg.project().path

    println("Ensuring PackageCompiler.jl is available in global environment...")
    try
        Pkg.activate() # activate global environment
        Pkg.add("PackageCompiler")
    catch e
        println("Failed to install PackageCompiler: ", e)
        return
    end

    # Load PackageCompiler dynamically while global environment is active
    PackageCompiler = try
        Base.require(Base.PkgId(Base.UUID("9b87118b-4619-50d2-8e1e-99f35a4d4d9d"), "PackageCompiler"))
    catch e
        println("Could not load PackageCompiler.jl: ", e)
        Pkg.activate(current_project)
        return
    end

    # Reactivate original project
    Pkg.activate(current_project)

    # 2. Define the output path
    sysimage_dir = joinpath(homedir(), ".julia", "sysimages")
    if !isdir(sysimage_dir)
        mkpath(sysimage_dir)
    end
    sysimage_path = joinpath(sysimage_dir, "jemach_sysimage.so")

    pkgs_to_compile = unique(vcat([:jEMach, :Dates], extra_pkgs))
    println("Compiling sysimage for packages: ", pkgs_to_compile)
    println("Output path: ", sysimage_path)
    println("This process may take 2-5 minutes. Please be patient...")

    return try
        Base.invokelatest(
            PackageCompiler.create_sysimage,
            pkgs_to_compile,
            sysimage_path = sysimage_path,
            project = dirname(current_project)
        )
        println("\n" * "✓"^60)
        println(" System image compiled successfully!")
        println(" File: $sysimage_path")
        println(" To use it, run Julia with: julia -J $sysimage_path")
        println(" " * "✓"^60)
    catch e
        println("Error during sysimage compilation: ", e)
    end
end

# ---------------------------------------------------------------------------
# Background watcher task
# ---------------------------------------------------------------------------

const _task_ref = Ref{Union{Task, Nothing}}(nothing)
const _running = Ref{Bool}(false)
const _socket_clients = Set{Sockets.PipeEndpoint}()
const _server_ref = Ref{Union{Sockets.PipeServer, Nothing}}(nothing)
const _last_serialized_json = Ref{String}("")
const _tui_pane_ref = Ref{String}("")

function _start_socket_server()
    path = SOCKET_PATH[]
    if isfile(path) || isfifo(path)
        try rm(path; force = true) catch; end
    end
    try
        server = Sockets.listen(path)
        _server_ref[] = server
        @async begin
            while _running[] && isopen(server)
                try
                    client = Sockets.accept(server)
                    @async begin
                        try
                            if isopen(client)
                                line = readline(client)
                                if startswith(line, "SUB")
                                    push!(_socket_clients, client)
                                    if !isempty(_last_serialized_json[])
                                        write(client, _last_serialized_json[] * "\n")
                                        flush(client)
                                    end
                                end
                            end
                        catch
                        end
                    end
                catch
                    break
                end
            end
        end
    catch e
        @warn "jEMach Socket Server failed to listen on $path" exception = e
    end
end

function _stop_socket_server()
    # Notify all subscribers that jEMach has stopped and panels should close
    stop_msg = "{\"event\":\"stop\",\"action\":\"close\"}\n"
    for client in _socket_clients
        try
            if isopen(client)
                write(client, stop_msg)
                flush(client)
            end
        catch
        end
    end

    if !isnothing(_server_ref[])
        try close(_server_ref[]) catch; end
        _server_ref[] = nothing
    end
    for client in _socket_clients
        try close(client) catch; end
    end
    empty!(_socket_clients)
    if isfile(SOCKET_PATH[])
        try rm(SOCKET_PATH[]; force = true) catch; end
    end
end

function _close_tui_pane()
    # 1. Close directly tracked tmux pane if opened by jEMach.start()
    if !isempty(_tui_pane_ref[])
        try
            run(`tmux kill-pane -t $(_tui_pane_ref[])`)
        catch
        end
        _tui_pane_ref[] = ""
    end

    # 2. Fallback: Search current tmux window for any pane running jl-assist or jl_tui.lua
    if haskey(ENV, "TMUX")
        try
            out = read(`tmux list-panes -F "#{pane_id} #{pane_current_command}"`, String)
            for line in split(strip(out), '\n')
                parts = split(strip(line))
                if length(parts) >= 2
                    pid = parts[1]
                    cmd = parts[2]
                    if cmd == "luajit" || occursin("jl_tui", cmd) || occursin("jl-assist", cmd)
                        run(`tmux kill-pane -t $pid`)
                    end
                end
            end
        catch
        end
    end
end

function publish_state()
    return try
        state = _collect_state_dod!(_shared_workspace_table[])
        pkgs = _get_packages()
        json = _serialize_dod(state, pkgs)

        # Avoid redundant disk writes and network flooding if state has not changed
        if json == _last_serialized_json[]
            return
        end
        _last_serialized_json[] = json

        # Write to file (fallback / legacy) atomically
        temp_file = STATE_FILE[] * ".tmp"
        open(temp_file, "w") do f
            write(f, json)
        end
        mv(temp_file, STATE_FILE[]; force = true)

        # Broadcast to all UNIX domain socket subscribers
        msg = json * "\n"
        dead_clients = Sockets.PipeEndpoint[]
        for client in _socket_clients
            try
                if isopen(client)
                    write(client, msg)
                    flush(client)
                else
                    push!(dead_clients, client)
                end
            catch
                push!(dead_clients, client)
            end
        end
        for dc in dead_clients
            delete!(_socket_clients, dc)
        end
    catch e
        @warn "jEMach Watcher error" exception = e
    end
end

function start(; split::Bool = true)
    _load_procedures!()
    if _running[]
        @info "jEMach Watcher already running"
    else
        _running[] = true
        _start_socket_server()
        _task_ref[] = @async begin
            @info "jEMach Watcher started — writing state to $(STATE_FILE[]) and socket $(SOCKET_PATH[])"
            while _running[]
                publish_state()
                sleep(UPDATE_INTERVAL)
            end
            _stop_socket_server()
            @info "jEMach Watcher stopped"
        end
    end

    if split
        # Find the path of the jl-assist TUI script
        assist_path = normpath(joinpath(@__DIR__, "..", "scripts", "jl-assist"))

        try
            pane_id = strip(read(`tmux split-window -P -F "#{pane_id}" -h -l 80 $assist_path`, String))
            _tui_pane_ref[] = pane_id
            println("🚀 tmux TUI split opened ($pane_id)!")
        catch e
            @warn "Failed to open tmux TUI pane (are you inside tmux?)" exception = e
        end
    end
    return nothing
end

function stop()
    _running[] = false
    _stop_socket_server()
    _close_tui_pane()
    return @info "jEMach Watcher stopped and right panel closed."
end

# ---------------------------------------------------------------------------
# Zero-Overhead FFI Hot-Reloading via JuliaZigCompiler
# ---------------------------------------------------------------------------

function _hot_reload_callback(file_path::String, source::String)
    @info "[jEMach Hot-Reload] File changed: $file_path"
    try
        # Evaluate the changed file in the Main module or attempt to guess the module
        expr = Meta.parse("begin\n" * source * "\nend")
        Base.invokelatest(Core.eval, Main, expr)
        @info "[jEMach Hot-Reload] Successfully reloaded into Main."
    catch e
        @error "[jEMach Hot-Reload] Error evaluating $file_path" exception=(e, catch_backtrace())
    end
end

function enable_hot_reload(proj_dir::String = _get_project_dir())
    # Try to load JuliaZigCompiler
    CompilerModule = try
        # Try to find it in the current environment
        Base.require(Base.PkgId(Base.UUID("918df9c8-d8bb-4a5e-b2d9-183498845fc8"), "JuliaZigCompiler"))
    catch
        try
            # Fallback to direct include if running locally from the user's workspace
            compiler_path = joinpath(homedir(), "code", "julia-zig-jit", "julia_package", "JuliaZigCompiler", "src", "JuliaZigCompiler.jl")
            if isfile(compiler_path)
                include(compiler_path)
                Main.JuliaZigCompiler
            else
                nothing
            end
        catch
            nothing
        end
    end

    if isnothing(CompilerModule)
        @error "JuliaZigCompiler is not available. Cannot enable Zero-Overhead FFI Hot-Reloading."
        return
    end

    @info "Starting jEMach Zero-Overhead FFI Hot-Reloading for project: $proj_dir"

    # Recursively find all .jl files in the src/ directory of the project
    src_dir = joinpath(proj_dir, "src")
    if !isdir(src_dir)
        src_dir = proj_dir
    end

    watched_count = 0
    for (root, _, files) in walkdir(src_dir)
        for file in files
            if endswith(file, ".jl")
                path = joinpath(root, file)
                Base.invokelatest(CompilerModule.watch_file, path, _hot_reload_callback)
                watched_count += 1
            end
        end
    end
    
    @info "Registered $watched_count files for instantaneous FFI Hot-Reload."
end

function status()
    return if _running[]
        println("jEMach Watcher is RUNNING  →  $(STATE_FILE[])")
    else
        println("jEMach Watcher is STOPPED")
    end
end

function __init__()
    hist_path = joinpath(homedir(), ".julia", "logs", "repl_history.jl")
    if isfile(hist_path)
        HIST_START_POS[] = filesize(hist_path)
    else
        HIST_START_POS[] = 0
    end
    # Initialize unique session paths based on the project folder
    safe_name = _get_safe_name(_get_project_dir())
    STATE_FILE[] = "/tmp/jl_tui_state_" * safe_name * ".json"
    SOCKET_PATH[] = "/tmp/jemach_" * safe_name * ".sock"

    # Auto-start watcher silently (without split) when loaded as a package
    return start(split = false)
end

end  # module jEMach
