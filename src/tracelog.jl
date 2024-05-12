
struct TLogEntry
    s::RORB
    p::Resource
    o::Node
    f::Function
end

"""
The 
uri => Julia function 
uri => [::owl_ObjectProperty or ::owl_DatatypeProperty, ::owl_Class, ::owl_Thing?, ::rdfs_Class] # All types and supertypes of one resource 
"""
struct TraceLog{T<:AbstractDict}
    ldict::T
    rdict::T
    entries::Vector{TLogEntry}
    futures::Vector{Tuple}
    io::IO
end
TraceLog(r_dict::T, io::IO) where {T<:AbstractDict} = TraceLog(T(),deepcopy(r_dict),TLogEntry[],Tuple[],io)
TraceLog(r_dict::T) where {T<:AbstractDict} = TraceLog(T(),deepcopy(r_dict),TLogEntry[],Tuple[],IOBuffer())
TraceLog{T}() where {T<:AbstractDict} = TraceLog(T(),T(),TLogEntry[],Tuple[],IOBuffer())
TraceLog() = TraceLog{Dict}()

"""
Push a new entry into the TLog for the given subject, function name and object
"""
function add_entry!(tl::TraceLog,s,p,o,f::Function)
    @debug "adding TLogEntry" s p o f
    push!(tl.entries, TLogEntry(s,p,o,f))
end

"""
Fetch a resource object locally or globally, updating the local dictionary with Unknown and returning that if not found.
"""
function retrieve!(tl::TraceLog, x::RORB; default = Unknown(x))
    obj = get(tl.rdict, x, default)
    # = get(tl.ldict, x) do
    #     get(tl.rdict, x, default)
    # end
    @debug "retrieve! got for $x : " obj
    obj
end

"""
Pushed key => val pair to both local and resource dictionaries.
"""
# function store_all!(tl::TraceLog, value, key::RORB)
#     store_local!(tl,value,key)
#     store_res!(tl,value,key)
# end

"""
Push key => val pair to local dictionary only.
"""
store_local!(tl::TraceLog, value, key::RORB) = (tl.ldict[key] = value)

"""
Push key => val pair to resource dictionary only.
"""
store_res!(tl::TraceLog, value, key::RORB) = push!(tl.rdict, key => value)


# task = @async open("foo.txt", "w") do io
#     write(io, "Hello, World!")
# end;

# julia> wait(task)

# julia> readlines("foo.txt")
# 1-element Array{String,1}:
# "Hello, World!"

# ulia> using Sockets

# julia> @sync for hostname in ("google.com", "github.com", "julialang.org")
#            @async begin
#                conn = connect(hostname, 80)
#                write(conn, "GET / HTTP/1.1\r\nHost:$(hostname)\r\n\r\n")
#                readline(conn, keep=true)
#                println("Finished connection to $(hostname)")
#            end
#        end
# Finished connection to google.com
# Finished connection to julialang.org
# Finished connection to github.com