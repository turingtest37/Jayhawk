import Base.isequal, Base.hash, Base.show

# ==(u1::URI, u2::URI) = u1.uri == u2.uri
isequal(u1::URI, u2::URI) = u1.uri == u2.uri
hash(u::URI) = hash(u.uri)

abstract type OwlDatatype end
export OwlDatatype

MaybeURI = Union{URI,Nothing}
MaybeString = Union{String,Nothing}

# Transform a URI into a normalized name. 
# e.g. 'http://www.w3.org/2002/07/owl#Class' becomes 'owl_Class'.
function makeqname(s::String)
    namesp,lnm = split(URI(s))
    pfx = nothing
    try
        pfx = prefixforuri(namesp)
        @debug "prefix for uri" namesp pfx
    catch e
        nm = randstring('a':'z', 5)
        pfx = add_prefix!(nm, namesp)
        @warn "Creating prefix '$pfx' for unknown namespace '$namesp'" e
    end
    pfx.name * '_' * lnm
end
makeqname(u::URI) = makeqname(u.uri)
makeqname(u::ResourceURI) = makeqname(u.uri)

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

import Base.split
split(u::URI) = tuple(ns(u), localname(u))

macro U_str(s::String)
  URI(s)
end

valueof(x::URI) = x
valueof(v::Vector) = [valueof(x) for x in v]
valueof(x::Nothing) = nothing

cleanuri(s::AbstractString) = startswith(s,r"_:") ? BlankNode(s) : URI(strip(s, ['<','>',' ']))
cleanany(s::AbstractString) = startswith(s,r"<") ? cleanuri(s) : startswith(s,r"_:") ? BlankNode(s) : Literal(strip(s))

# s = [
# "owl:real",
# "owl:rational",
# "xsd:anyURI",
# "xsd:base64Binary",
# "xsd:boolean",
# "xsd:byte",
# "xsd:dateTime",
# "xsd:dateTimeStamp",
# "xsd:decimal",
# "xsd:double",
# "xsd:float",
# "xsd:hexBinary",
# "xsd:int",
# "xsd:integer",
# "xsd:language",
# "xsd:long",
# "xsd:Name",
# "xsd:NCName",
# "xsd:negativeInteger",
# "xsd:NMTOKEN",
# "xsd:nonNegativeInteger",
# "xsd:nonPositiveInteger",
# "xsd:normalizedString",
# "xsd:positiveInteger",
# "xsd:short",
# "xsd:string",
# "xsd:token",
# "xsd:unsignedByte",
# "xsd:unsignedInt",
# "xsd:unsignedLong",
# "xsd:unsignedShort"
# ]
# Create a Julia type for each xsd type
for uri in keys(rdf2julia_map)
  @debug "Creating datatype from uri" uri
  s = Symbol(makeqname(uri))
  @debug "Creating datatype" s
  eval(
    quote    
        struct $s <: OwlDatatype
            v::String
        end
        export $s
    end
  )
end


export localname, ns, parsent, MaybeURI, MaybeString, xsdtype2j, @U_str, valueof
export makeqname
