module RDFSupport


using URIs
using Logging
using Dates
import Base.isequal, Base.hash, Base.show

import Base.isequal, Base.hash

# ==(u1::URI, u2::URI) = u1.uri == u2.uri
isequal(u1::URI, u2::URI) = u1.uri == u2.uri
hash(u::URI) = hash(u.uri)


MaybeURI = Union{URI,Nothing}
MaybeString = Union{String,Nothing}

function localname(u::URI)
  u.scheme == "urn" && return u.path
  isempty(u.fragment) ? last(split(u.path, "/")) : u.fragment
end
  localname(s::String) = localname(URI(s))
function ns(u::URI)
  u.scheme == "urn" && return "urn:"
  isempty(u.fragment) ? u.uri[1:first(findlast("/",u.uri))] : u.uri[1:first(findlast("#",u.uri))]
end
ns(s::String) = ns(URI(s))

macro U_str(s::String)
  URI(s)
end

# struct URIRef
#   uri::URI
#   ns::URI
#   l::String
# end
# URIRef(uri::URI) = URIRef(uri, ns(uri), localnm(uri))

# struct Literal
#   v::String
#   dt::MaybeURI
#   lang::MaybeString

#   function Literal(v::T, dt::MaybeURI=nothing, lang::MaybeString=nothing) where {T<:AbstractString}
#       # @debug "v T" v typeof(v)
#       v = strip(String(v), '"')
#       if contains(v, "^^")
#         s = split(v, "^^")
#         v = strip(s[1],['"'])
#         dt = cleanuri(s[2])
#       end

#       if contains(v, "@")
#         v,lang = split(v, "@")
#       end
#       new(v,dt,lang)
#   end
# end

# # Literal(x::T) where {T<:AbstractString} = Literal(string(x), U"http://www.w3.org/2001/XMLSchema#string", nothing)
# Literal(x::String, lang::String) = Literal(x, U"http://www.w3.org/2001/XMLSchema#string", lang)
# Literal(x, dt::URI, lang::String) = Literal(string(x), dt, lang)
# Literal(x::T) where {T<:Integer} = Literal(string(x), U"http://www.w3.org/2001/XMLSchema#int", nothing)
# Literal(x::T where {T<:Number}) = Literal(string(x), U"http://www.w3.org/2001/XMLSchema#decimal", nothing)
# Literal(x::DateTime) = Literal(string(x), U"http://www.w3.org/2001/XMLSchema#dateTime", nothing)
# Literal(x::URI) = Literal(string("\"",x.uri,"\""), U"http://www.w3.org/2001/XMLSchema#AnyURI", nothing)

# # import Base.show

# isequals(v1::Literal, v2::Literal) = v1.v == v2.v
# hash(v::Literal) = hash(v.v)
# print(io::IO, v::Literal) = print(io, v.v, (isnothing(v.dt) ? "" : "^^$(v.dt)"), (isnothing(v.lang) ? "" : "@$(v.lang)"))
# show(io::IO, v::Literal) = print(io, v.v)

# function valueof(x::Literal)
#   # @show "x" x
#   r = nothing
#   if isnothing(x.dt)
#     r = x.v
#   else
#     typ = xsdtype2j(x.dt)
#     # @show "typ" typ
#     ans = convert(typ, x)
#     # @show "ans = convert(typ,x)" ans
#     r = ans
#   end
#   r
# end

valueof(x::URI) = x
valueof(v::Vector) = [valueof(x) for x in v]
valueof(x::Nothing) = nothing

# import Base.convert
# convert(T::Type{<:Number}, x::Literal) = parse(T,x.v)
# convert(T::Type{DateTime}, x::Literal) = T(x.v)
# convert(T::Type{<:AbstractString}, x::Literal) = String(x.v)

# struct BlankNode
#   v::String
# end
# isequals(b1::BlankNode, b2::BlankNode) = b1.v == b2.v
# hash(b::BlankNode) = hash(b.v)
# show(io::IO, v::BlankNode) = print(io, v.v)

cleanuri(s::AbstractString) = startswith(s,r"_:") ? BlankNode(s) : URI(strip(s, ['<','>',' ']))
cleanany(s::AbstractString) = startswith(s,r"<") ? cleanuri(s) : startswith(s,r"_:") ? BlankNode(s) : Literal(strip(s))


xsd_anyuri  = U"http://www.w3.org/2001/XMLSchema#AnyURI" 
xsd_integer = U"http://www.w3.org/2001/XMLSchema#integer"
xsd_int     = U"http://www.w3.org/2001/XMLSchema#int"
xsd_decimal = U"http://www.w3.org/2001/XMLSchema#decimal"
xsd_string  = U"http://www.w3.org/2001/XMLSchema#string"
xsd_datetime = U"http://www.w3.org/2001/XMLSchema#dateTime"
xsd_date    = U"http://www.w3.org/2001/XMLSchema#date"
xsd_time    = U"http://www.w3.org/2001/XMLSchema#time"
export xsd_anyuri, xsd_int, xsd_date, xsd_decimal, xsd_integer, xsd_string, xsd_time, xsd_datetime

lookup = Dict{URI,Type}(
  xsd_anyuri => URIs.URI,
  xsd_integer => Int,
  xsd_int => Int,
  xsd_decimal => Float32,
  xsd_string => String,
  xsd_datetime => DateTime,
  xsd_date => Date,
  xsd_time => Time
)
xsdtype2j(x::URI) = get(lookup,x,Any)
xsdtype2j(x::String) = xsdtype2j(URI(x))


const TRIPLE_PATT = r"^\s*<([^<>]*)>\s+<([^<>]*)>\s(.*)\s+\.\s*$"
function parsel(line)
  m = match(TRIPLE_PATT, line)
  isnothing(m) && return nothing
  e = m.captures
  s,p,o = cleanuri(e[1]), cleanuri(e[2]), cleanany(e[3])
  return s,p,o
end
export parsel

function parsent(doc::Union{IO,String})

    # subject may be URI or a blank node
    subjdict = Dict{Union{URI,BlankNode},Dict}()

    doc_in = doc isa IO ? doc : IOBuffer(doc)

    for line in eachline(doc_in)
      # @debug "line" line
        isnothing(line) && continue
        # e = split(line, delim; keepempty=false)
        # @debug "e = split line by d" e delim
        s,p,o = parsel(line)

        if haskey(subjdict,s)
            # @debug "adding to existing key s" s
            dp = subjdict[s] # dictionary of predicate => values
            # @debug "dict for dp = r[s]" s dp
            if haskey(dp,p)
                # @debug "adding to existing key p" p
                v = dp[p]
                # v could be a single instance or a vector
                # coerce it to a vector now
                v = (typeof(v) <: AbstractArray) ? v : Any[v]
                # @debug "v = dp[p]" v
                # @debug "push!(v, o)" o
                push!(v, o)
                # @debug "v is now" v
            else
                # @debug "creating value for predicate $(p) with starting object o" o
                dp[p] = o
            end
        else
            # predicates are always URIs, never blank nodes
            # @debug "creating new Dict for key s with p and o" s p o
            subjdict[s] = Dict{URI,Any}(p => o)
        end

        # @debug "dict r is now " subjdict
    end
    subjdict
end

# export localname, ns, Literal, BlankNode, parsent, MaybeURI, MaybeString, xsdtype2j, @U_str, valueof
export localname, ns, parsent, MaybeURI, MaybeString, xsdtype2j, @U_str, valueof

end