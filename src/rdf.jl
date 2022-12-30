import Base.isequal, Base.hash, Base.show

# ==(u1::URI, u2::URI) = u1.uri == u2.uri
isequal(u1::URI, u2::URI) = u1.uri == u2.uri
hash(u::URI) = hash(u.uri)

import Base.split
split(u::URI) = tuple(ns(u), localname(u))

abstract type OwlDatatype end
export OwlDatatype

MaybeURI = Union{URI,Nothing}
MaybeString = Union{String,Nothing}

# Transform a URI into a normalized name. 
# e.g. 'http://www.w3.org/2002/07/owl#Class' becomes 'owl_Class'.
function makeqname(u::URI)
    namesp,lnm = split(u)
    pfx = nothing
    try
        pfx = prefixforuri(namesp)
        @debug "prefix for uri" namesp pfx
        curie = ResourceCURIE(pfx.name, lnm)
        makeqname(curie)
    catch e
        # nm = randstring('a':'z', 5)
        # pfx = add_prefix!(nm, namesp)
        @warn "No prefix found for namespace '$namesp'"
        s
    end
end
makeqname(uri::ResourceURI) = makeqname(URI(uri.uri))
makeqname(curie::ResourceCURIE) = makeqname(curie.prefix,curie.name)
makeqname(prefix::String, name::String) = prefix * "_" * name

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

cleanuri(s::AbstractString) = startswith(s,r"_:") ? BlankNode(s) : URI(strip(s, ['<','>',' ']))
cleanany(s::AbstractString) = startswith(s,r"<") ? cleanuri(s) : startswith(s,r"_:") ? BlankNode(s) : Literal(strip(s))

datatypes = [
"owl:real",
"owl:rational",
"xsd:anyURI",
"xsd:base64Binary",
"xsd:boolean",
"xsd:byte",
"xsd:dateTime",
"xsd:dateTimeStamp",
"xsd:decimal",
"xsd:double",
"xsd:float",
"xsd:hexBinary",
"xsd:int",
"xsd:integer",
"xsd:language",
"xsd:long",
"xsd:Name",
"xsd:NCName",
"xsd:negativeInteger",
"xsd:NMTOKEN",
"xsd:nonNegativeInteger",
"xsd:nonPositiveInteger",
"xsd:normalizedString",
"xsd:positiveInteger",
"xsd:short",
"xsd:string",
"xsd:token",
"xsd:unsignedByte",
"xsd:unsignedInt",
"xsd:unsignedLong",
"xsd:unsignedShort"
]
# Create a Julia type for each xsd type
for x in datatypes
  @debug "Creating datatype from uri" x
  pfx,nm = string.(split(x,":"))
  s = Symbol(makeqname(pfx,nm))
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
