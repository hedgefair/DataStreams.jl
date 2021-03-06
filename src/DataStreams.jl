__precompile__(true)
module DataStreams

export Data, DataFrame

module Data

if !isdefined(Core, :String)
    typealias String UTF8String
end

abstract Source

function reset! end
function isdone end
reference(x) = UInt8[]

abstract StreamType
immutable Field <: StreamType end
immutable Column <: StreamType end

"""
`Data.streamtype{T<:Data.Source, S<:Data.StreamType}(::Type{T}, ::Type{S})` => Bool

Indicates whether the source `T` supports streaming of type `S`. To be overloaded by individual sources according to supported `Data.StreamType`s
"""
function streamtype end

# generic fallback for all Sources
Data.streamtype{T<:StreamType}(source, ::Type{T}) = false

"""
`Data.streamtypes{T<:Data.Sink}(::Type{T})` => Vector{StreamType}

Returns a list of `Data.StreamType`s that the sink supports ingesting; the order of elements indicates the sink's streaming preference
"""
function streamtypes end

function getfield end
function getcolumn end

abstract Sink

function stream!
end

"""
A `Data.Schema` describes a tabular dataset (i.e. a set of optionally named, typed columns with records as rows)
`Data.Schema` allow `Data.Source` and `Data.Sink` to talk to each other and prepare to provide/receive data through streaming.
`Data.Schema` fields include:

 * `Data.header(schema)` to return the header/column names in a `Data.Schema`
 * `Data.types(schema)` to return the column types in a `Data.Schema`; `Nullable{T}` indicates columns that may contain missing data (null values)
 * `Data.size(schema)` to return the (# of rows, # of columns) in a `Data.Schema`

`Data.Source` and `Data.Sink` interfaces both require that `Data.schema(source_or_sink)` be defined to ensure
that other `Data.Source`/`Data.Sink` can work appropriately.
"""
type Schema
    header::Vector{String}       # column names
    types::Vector{DataType}      # Julia types of columns
    rows::Integer                # number of rows in the dataset
    cols::Int                    # number of columns in a dataset
    metadata::Dict{Any, Any}     # for any other metadata we'd like to keep around (not used for '==' operation)
    function Schema(header::Vector, types::Vector{DataType}, rows::Integer=0, metadata::Dict=Dict())
        cols = length(header)
        cols != length(types) && throw(ArgumentError("length(header): $(length(header)) must == length(types): $(length(types))"))
        header = String[string(x) for x in header]
        return new(header, types, rows, cols, metadata)
    end
end

Schema(header, types::Vector{DataType}, rows::Integer=0, meta::Dict=Dict()) = Schema(String[i for i in header], types, rows, meta)
Schema(types::Vector{DataType}, rows::Integer=0, meta::Dict=Dict()) = Schema(String["Column$i" for i = 1:length(types)], types, rows, meta)
const EMPTYSCHEMA = Schema(String[], DataType[], 0, Dict())
Schema() = EMPTYSCHEMA

header(sch::Schema) = sch.header
types(sch::Schema) = sch.types
Base.size(sch::Schema) = (sch.rows, sch.cols)
Base.size(sch::Schema, i::Int) = ifelse(i == 1, sch.rows, ifelse(i == 2, sch.cols, 0))

function Base.show(io::IO, schema::Schema)
    println(io, "Data.Schema:")
    println(io, "rows: $(schema.rows)\tcols: $(schema.cols)")
    if schema.cols <= 0
        println(io)
    else
        println(io, "Columns:")
        Base.print_matrix(io, hcat(schema.header, schema.types))
    end
end

"Returns the `Data.Schema` for `source_or_sink`"
schema(source_or_sink) = source_or_sink.schema # by default, we assume the `Source`/`Sink` stores the schema directly
"Returns the header/column names (if any) associated with a specific `Source` or `Sink`"
header(source_or_sink) = header(schema(source_or_sink))
"Returns the column types associated with a specific `Source` or `Sink`"
types(source_or_sink) = types(schema(source_or_sink))
"Returns the (# of rows,# of columns) associated with a specific `Source` or `Sink`"
Base.size(source_or_sink::Source) = size(schema(source_or_sink))
Base.size(source_or_sink::Source, i) = size(schema(source_or_sink),i)
setrows!(source, rows) = isdefined(source, :schema) ? (source.schema.rows = rows; nothing) : nothing
setcols!(source, cols) = isdefined(source, :schema) ? (source.schema.cols = cols; nothing) : nothing

# generic definitions
function Data.stream!{T, TT}(source::T, ::Type{TT}, append::Bool, args...)
    typs = Data.streamtypes(TT)
    for typ in typs
        if Data.streamtype(T, typ)
            sink = TT(source, typ, append, args...)
            return Data.stream!(source, typ, sink, append)
        end
    end
    throw(ArgumentError("`source` doesn't support the supported streaming types of `sink`: $typs"))
end
# for backwards compatibility
Data.stream!{T, TT}(source::T, ::Type{TT}) = Data.stream!(source, TT, false, ())

function Data.stream!{T, TT}(source::T, sink::TT, append::Bool)
    typs = Data.streamtypes(TT)
    for typ in typs
        if Data.streamtype(T, typ)
            sink = TT(sink, source, typ, append)
            return Data.stream!(source, typ, sink, append)
        end
    end
    throw(ArgumentError("`source` doesn't support the supported streaming types of `sink`: $typs"))
end
Data.stream!{T, TT <: Data.Sink}(source::T, sink::TT) = Data.stream!(source, sink, false)

# DataFrames DataStreams definitions
using DataFrames, NullableArrays, CategoricalArrays, WeakRefStrings

# AbstractColumn definitions
nullcount(A::NullableVector) = sum(A.isnull)
nullcount(A::Vector) = 0
nullcount(A::NominalArray) = 0
nullcount(A::OrdinalArray) = 0
nullcount(A::NullableNominalArray) = sum(A.refs .== 0)
nullcount(A::NullableOrdinalArray) = sum(A.refs .== 0)

allocate{T}(::Type{T}, rows, ref) = Array{T}(rows)
function allocate{T}(::Type{Nullable{T}}, rows, ref)
    A = Array{T}(rows)
    return NullableArray{T, 1}(A, fill(true, rows), isempty(ref) ? UInt8[] : ref)
end
allocate{S,R}(::Type{NominalValue{S,R}}, rows, ref) = NominalArray{S,1,R}(rows)
allocate{S,R}(::Type{OrdinalValue{S,R}}, rows, ref) = OrdinalArray{S,1,R}(rows)
allocate{S,R}(::Type{Nullable{NominalValue{S,R}}}, rows, ref) = NullableNominalArray{S,1,R}(rows)
allocate{S,R}(::Type{Nullable{OrdinalValue{S,R}}}, rows, ref) = NullableOrdinalArray{S,1,R}(rows)

# DataFrames DataStreams implementation
function Data.schema(df::DataFrame)
    return Data.Schema(map(string, names(df)),
            DataType[eltype(A) for A in df.columns], size(df, 1))
end

# DataFrame as a Data.Source
function Data.isdone(source::DataFrame, row, col)
    rows, cols = size(source)
    return row > rows || col > cols
end

Data.streamtype(::Type{DataFrame}, ::Type{Data.Column}) = true
Data.streamtype(::Type{DataFrame}, ::Type{Data.Field}) = true

Data.getcolumn{T}(source::DataFrame, ::Type{T}, col) = (@inbounds A = source.columns[col]; return A)
Data.getfield{T}(source::DataFrame, ::Type{T}, row, col) = (@inbounds A = Data.getcolumn(source, T, col); return A[row])

# DataFrame as a Data.Sink
DataFrame{T<:Data.StreamType}(so, ::Type{T}, append::Bool, args...) = DataFrame(Data.schema(so), T, Data.reference(so))

function DataFrame{T<:Data.StreamType}(sch::Schema, ::Type{T}=Data.Field, ref::Vector{UInt8}=UInt8[])
    rows, cols = size(sch)
    rows = T === Data.Column || rows < 0 ? 0 : rows # don't pre-allocate for Column streaming
    columns = Vector{Any}(cols)
    types = Data.types(sch)
    for i = 1:cols
        columns[i] = allocate(types[i], rows, ref)
    end
    return DataFrame(columns, map(Symbol, Data.header(sch)))
end

# given an existing DataFrame (`sink`), make any necessary changes for streaming `source`
# to it, given we know if we'll be `appending` or not
function DataFrame{T<:Data.StreamType}(sink, source, ::Type{T}, append)
    sch = Data.schema(source)
    rows, cols = size(sch)
    if T === Data.Column
        if !append
            for col in sink.columns
                empty!(col)
            end
        end
    else
        if rows > 0
            newlen = rows + (append ? size(sink, 1) : 0)
            for col in sink.columns
                resize!(col, newlen)
            end
        end
    end
    return sink
end

Data.streamtypes(::Type{DataFrame}) = [Data.Column, Data.Field]

function pushfield!{T}(source, ::Type{T}, dest, row, col)
    push!(dest, Data.getfield(source, T, row, col))
    return
end

function getfield!{T}(source, ::Type{T}, dest, row, col, sinkrow)
    @inbounds dest[sinkrow] = Data.getfield(source, T, row, col)
    return
end

function Data.stream!{T}(source::T, ::Type{Data.Field}, sink::DataFrame, append::Bool=true)
    Data.types(source) == Data.types(sink) || throw(ArgumentError("schema mismatch: \n$(Data.schema(source))\nvs.\n$(Data.schema(sink))"))
    rows, cols = size(source)
    Data.isdone(source, 1, 1) && return sink
    columns = sink.columns
    types = Data.types(source)
    if rows == -1
        sinkrows = size(sink, 1)
        row = 1
        while !Data.isdone(source, row, cols)
            for col = 1:cols
                Data.pushfield!(source, types[col], columns[col], row, col)
            end
            row += 1
        end
        Data.setrows!(source, sinkrows + row)
    else
        sinkrow = append ? size(sink, 1) - size(source, 1) + 1 : 1
        for row = 1:rows
            for col = 1:cols
                Data.getfield!(source, types[col], columns[col], row, col, sinkrow)
            end
            sinkrow += 1
        end
    end
    return sink
end

function appendcolumn!{T}(source, ::Type{T}, dest, col)
    column = Data.getcolumn(source, T, col)
    append!(dest, column)
    return length(dest)
end

function appendcolumn!{T}(source, ::Type{Nullable{WeakRefString{T}}}, dest, col)
    column = Data.getcolumn(source, Nullable{WeakRefString{T}}, col)
    offset = length(dest.values)
    parentoffset = length(dest.parent)
    append!(dest.isnull, column.isnull)
    append!(dest.parent, column.parent)
    # appending new data to `dest` would invalid all existing WeakRefString pointers
    resize!(dest.values, length(dest) + length(column))
    for i = 1:offset
        old = dest.values[i]
        dest.values[i] = WeakRefString{T}(pointer(dest.parent, old.ind), old.len, old.ind)
    end
    for i = 1:length(column)
        old = column.values[i]
        dest.values[offset + i] = WeakRefString{T}(pointer(dest.parent, parentoffset + old.ind), old.len, parentoffset + old.ind)
    end
    return length(dest)
end

function Data.stream!{T}(source::T, ::Type{Data.Column}, sink::DataFrame, append::Bool=true)
    Data.types(source) == Data.types(sink) || throw(ArgumentError("schema mismatch: \n$(Data.schema(source))\nvs.\n$(Data.schema(sink))"))
    rows, cols = size(source)
    Data.isdone(source, 1, 1) && return sink
    columns = sink.columns
    types = Data.types(source)
    sinkrows = size(sink, 1)
    row = 0
    for col = 1:cols
        columns[col] = Data.getcolumn(source, types[col], col)
    end
    row = length(columns[1])
    while !Data.isdone(source, row+1, cols)
        for col = 1:cols
            row = Data.appendcolumn!(source, types[col], columns[col], col)
        end
    end
    Data.setrows!(source, sinkrows + row)
    return sink
end

end # module Data

end # module DataStreams
