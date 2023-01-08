
import Base.split
split(u::URI) = tuple(ns(u), localname(u))

abstract type OwlDatatype end
export OwlDatatype

""" makeqname
Transform a URI into a normalized name by looking up the registered prefix and replacing ':' with '_" in the local name part. 
e.g. 'http://www.w3.org/2002/07/owl#Class' becomes 'owl_Class'.

@see add_prefix!
"""
function makeqname(u::URI)
    namesp,lnm = split(u)
    @debug "prefix for uri" u namesp lnm
    pfx = nothing
    pfx = prefixforuri(namesp)
    @debug "prefix for namespace uri" namesp pfx
    makeqname(pfx.name, replace(string(lnm),":"=>"_"))
end
makeqname(s::String) = makeqname(URI(s))
makeqname(uri::ResourceURI) = makeqname(URI(uri.uri))
makeqname(curie::ResourceCURIE) = makeqname(curie.prefix,curie.name)
makeqname(prefix::String, name::String) = prefix * "_" * name

prefixforuri(namesp) = prefixforuri(namesp)
export prefixforuri

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
