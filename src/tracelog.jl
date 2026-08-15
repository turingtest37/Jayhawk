
struct TLogEntry
    s::RORB
    p::Resource
    o::Node
    f::Function
end
TLogEntry(s::Type, p::Resource, o::Node, f::Function) = TLogEntry(Resource(URIs.escapeuri(string(s))),p,o,f)
TLogEntry(s::Type, p::Resource, o::Any, f::Function) = TLogEntry(Resource(URIs.escapeuri(string(s))),p,Resource(URIs.escapeuri(string(o))),f)
TLogEntry(s::Function, p::Resource, o::Union{<:AbstractString, <:Number, <:Dates.AbstractTime, <:Bool}, f::Function) = TLogEntry(Resource(URIs.escapeuri(string(s))),p,Literal(string(o)),f)
TLogEntry(s::Any, p::Resource, o::Node, f::Function) = TLogEntry(Resource(URIs.escapeuri(string(s))),p,o,f)

"""
The 
uri => Julia function 
uri => [::owl_ObjectProperty or ::owl_DatatypeProperty, ::owl_Class, ::owl_Thing?, ::rdfs_Class] # All types and supertypes of one resource 
"""
struct TraceLog{T<:AbstractDict}
    ldict::T
    rdict::T
    entries::Vector{TLogEntry}
    io::IO
    active::Bool
end
TraceLog{T}() where {T<:AbstractDict} = TraceLog(T(),T(),TLogEntry[],IOBuffer(),false)
TraceLog{T}(active::Bool) where {T<:AbstractDict} = TraceLog(T(),T(),TLogEntry[],IOBuffer(),active)
TraceLog(r_dict::T, io::IO) where {T<:AbstractDict} = TraceLog(T(),deepcopy(r_dict),TLogEntry[],io,false)
TraceLog(r_dict::T, io::IO, active::Bool) where {T<:AbstractDict} = TraceLog(T(),deepcopy(r_dict),TLogEntry[],io,active)
TraceLog(r_dict::T) where {T<:AbstractDict} = TraceLog(T(),deepcopy(r_dict),TLogEntry[],IOBuffer(),false)
TraceLog(r_dict::T, active::Bool) where {T<:AbstractDict} = TraceLog(T(),deepcopy(r_dict),TLogEntry[],IOBuffer(),active)
TraceLog() = TraceLog{Dict}()
TraceLog(active::Bool) = TraceLog{Dict}(active)


"""
Push a new entry into the TLog for the given subject, predicate, object and function name, 
but only if the TraceLog's 'active' field is set to true.
"""
function add_entry!(tl::TraceLog,s,p,o,f::Function)
    @debug "add_entry!" s p o f
    if tl.active
        @debug "adding TLogEntry" s p o f
        push!(tl.entries, TLogEntry(s,p,o,f))
        store_local!(tl, o, s)
    end
end

"""
Fetch a resource or blank node object locally or globally, updating the local dictionary with Unknown and returning that if not found.
"""
function retrieve(tl::TraceLog, x::RORB; default = Unknown(x))
    obj = get(tl.rdict, x, default)
    # = get(tl.ldict, x) do
    #     get(tl.rdict, x, default)
    # end
    @debug "retrieve! got for $x : " obj
    obj
end

"""
Push key => val pair to local dictionary only if the TL is active.
"""
function store_local!(tl::TraceLog, value, key::RORB)
    if tl.active
        push!(tl.ldict, key => value)
    end
end
# Handle non-RORB keys by converting to Resource
function store_local!(tl::TraceLog, value, key::Any)
    store_local!(tl, value, Resource(URIs.escapeuri(string(key))))
end

"""
Push key => val pair to resource dictionary only if the TL is active.
"""
function store_res!(tl::TraceLog, value, key::RORB)
    if tl.active
        push!(tl.rdict, key => value)
    end
end
