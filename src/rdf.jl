abstract type RDFType end

struct owl_Class <: RDFType
  uri::RORB
  in::Dict{RORB, RORB}
end
owl_Class(uri::RORB) = owl_Class(uri, Dict())

struct owl_Thing <: RDFType
  uri::RORB
  in::Dict{RORB, RORB}
end

struct owl_ObjectProperty <: RDFType
  uri::RORB
  in::Dict{RORB, RORB}
end
owl_ObjectProperty(uri::RORB) = owl_ObjectProperty(uri, Dict())

struct owl_DatatypeProperty <: RDFType
  uri::RORB
  in::Dict{RORB, RORB}
end
owl_DatatypeProperty(uri::RORB) = owl_DatatypeProperty(uri, Dict())

struct owl_NamedIndividual
  uri::RORB
  in::Dict{RORB, RORB}
end
struct owl_Restriction
  uri::RORB
  in::Dict{RORB, RORB}
end
struct owl_Ontology
  uri::RORB
  in::Dict{RORB, RORB}
end

# The Unknown Type is used when a statement is encountered for which
# we do not (yet) have the type of the object.
@auto_hash_equals struct Unknown <: Node
  uri::RORB
  in::Dict{RORB, RORB}
  out::Dict{Resource, Node}
  super::Vector{Resource}
end
Unknown(uri::Resource) = Unknown(uri,Dict(),Dict(),Resource[])
Unknown(b::Blank) = Unknown(b,Dict(),Dict(),Resource[])

abstract type OwlDatatype end
export OwlDatatype

import Base.split
split(u::URI) = tuple(ns(u), localname(u))

add_prefix!(pfx::String, uri::String) = Serd.RDF.Prefixes.add_prefix!(pfx,uri)
add_prefix!(p::Prefix) = Serd.RDF.Prefixes.add_prefix!(p)
export add_prefix!

""" makeqname
Transform a URI into a normalized name by looking up the registered prefix and replacing ':' with '_" in the local name part. 
e.g. 'http://www.w3.org/2002/07/owl#Class' becomes 'owl_Class'.

@see add_prefix!
"""
function makeqname(u::URI)
    namesp,lnm = split(u)
    # @debug "prefix for uri" u namesp lnm
    pfx = nothing
    pfx = prefixforuri(namesp)
    # @debug "prefix for namespace uri" namesp pfx
    makeqname(pfx.name, replace(string(lnm),":"=>"_"))
end
makeqname(s::String) = makeqname(URI(s))
makeqname(uri::ResourceURI) = makeqname(URI(uri.uri))
makeqname(curie::ResourceCURIE) = makeqname(curie.prefix, curie.name)
makeqname(prefix::String, name::String) = prefix * "_" * name
makeqname(b::Blank) = "Jayhawk_" * b.name

prefixforuri(namesp) = Serd.RDF.Prefixes.prefixforuri(namesp)
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
        @auto_hash_equals struct $s <: OwlDatatype
            v::String
        end
        export $s
        $resource_dict[Resource($pfx,$nm)] = $s 
    end
  )
end

broadcast((x)->setindex!(resource_dict, (eval ∘ Symbol ∘ makeqname)(x), x),
(
Resource("owl","Class"),
Resource("owl","Thing"),
Resource("owl","ObjectProperty"),
Resource("owl","DatatypeProperty"),
Resource("owl","NamedIndividual"),
Resource("owl","Restriction"),
Resource("owl","Ontology")
)
)

function scoobify(stmts,pfx,buri)
  @debug "scoobifying" size(stmts) size(pfx) buri
  pdict = Dict(p.name=>p.uri for p in pfx)
  pdict[""] = (!isnothing(buri) ? buri.uri : "")
  @debug "pdict" pdict
  scoobys = Statement[]
  @debug "scoobys" scoobys
  norm(s) = (isa(s,ResourceCURIE) ? Resource(pdict[s.prefix] * s.name) : s)
  for s in stmts
    if isa(s,Triple)
      push!(scoobys, Triple(norm(s.subject), norm(s.predicate), norm(s.object)))
    else
      push!(scoobys, norm(s))
    end
  end
  # [push!(scoobys, (s a ResourceCURIE ? Resource(pdict[s.prefix] * s.name) : s)) for s in stmts]
  @debug "scoobys now" scoobys
  scoobys
end
export scoobify

export localname, ns, parsent, MaybeURI, MaybeString, xsdtype2j, @U_str, valueof
export makeqname
