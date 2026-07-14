# Complex Type Introspection

Technical breakdown of type introspection mechanics implemented in `jEMach._get_children`.

## Supported Types & Representations

`jEMach` introspects symbols in `Main` and imported modules, expanding data structures into hierarchical tree nodes with valid Julia evaluation expressions (`expr`).

#### DataFrames & Tables (`DataFrames.jl` / `Tables.jl`)

- **Detection**: Matches DataFrame structures via module names or table indexing signatures.
- **Node Breakdown**: Expands columns as children items (e.g. `:id`, `:name`, `:score`).
- **Expression**: Generates column selector expressions `df[!, :column_name]`.
- **Type Display**: Shows element vector type and row count (e.g. `Vector{Float64} (1000 rows)`).

#### Arrays & Matrices (`AbstractArray`)

- **1D Arrays**: Lists items `[1]` through `[20]` with expressions `arr[i]`.
- **2D Matrices (`ndims == 2`)**: Generates 2D coordinate elements `[1, 1]` through `[5, 5]` with matrix index expressions `mat[i, j]`.
- **Multidimensional Arrays (`ndims > 2`)**: Exposes dimension shape tuple node `[dimensions]` evaluating `size(arr)`.

#### Dictionaries (`AbstractDict`)

- **Elements**: Lists key-value pairs up to 20 items.
- **Expression**: Generates index expressions `dict[key]` using `repr(key)`.

#### Tuples & NamedTuples

- **NamedTuple**: Access via field selectors `nt.field_name`.
- **Tuple**: Indexed element access `tup[i]`.

#### Composite Structs (`struct` / `mutable struct`)

- **Field Resolution**: Uses `fieldnames(T)` and `getfield(val, field)`.
- **Expression**: Generates chained field access expressions `struct.field_name`.

## Interactivity & REPL Print Action

Each expanded node provides a clickable/selectable `expr` string. Pressing `l` or Enter in `jl-assist` or Neovim sends `println(expr)` directly to the connected Julia REPL pane for instant value evaluation.
