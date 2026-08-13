abstract type RDFType end

# TODO Generate RDFTypes dynamically from a list of types
struct owl_Class <: RDFType
  uri::RORB
  in::Dict{RORB, RORB}

  owl_Class(uri::RORB) = new(uri, Dict())
end

struct owl_Thing <: RDFType
  uri::RORB
  in::Dict{RORB, RORB}
end

struct owl_ObjectProperty <: RDFType
  uri::Resource
  in::Dict{RORB, RORB}
  
  owl_ObjectProperty(uri::RORB) = new(uri, Dict())
end

struct owl_DatatypeProperty <: RDFType
  uri::Resource
  in::Dict{RORB, RORB}

  owl_DatatypeProperty(uri::RORB) = new(uri, Dict())
end

struct owl_AnnotationProperty <: RDFType
  uri::Resource
  in::Dict{RORB, RORB}

  owl_AnnotationProperty(uri::RORB) = new(uri, Dict())
end

struct owl_NamedIndividual
  uri::Resource
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
    @debug "prefix for uri" u namesp lnm
    pfx = nothing
    pfx = prefixforuri(namesp)
    # @debug "prefix for namespace uri" namesp pfx
    makeqname(pfx.prefix, replace(string(lnm),":"=>"_"))
end
makeqname(s::String) = makeqname(URI(s))
makeqname(uri::ResourceURI) = makeqname(URI(uri.uri))
makeqname(uri::Resource) = makeqname(URI(uri.uri))
makeqname(curie::ResourceCURIE) = makeqname(curie.prefix, curie.localname)
makeqname(prefix::String, name::String) = string(prefix,"_",name)
makeqname(b::Blank) = makeqname("Jayhawk", string(b.name))

# prefixforuri(namesp) = Serd.RDF.Prefixes.prefixforuri(namesp)
# export Serd.RDF.Prefixes.prefixforuri

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

# Need to explain this next line!
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

"""
Converts Serd Statements 
"""
function expand_uris(stmts,pfx,buri)
  @debug "expand_urising" size(stmts) size(pfx) buri
  add_prefix!.(pfx)
  if !isnothing(buri)
    add_prefix!("",buri.uri)
  end
  pdict = prefixes()
  @debug "pdict" pdict
  scoobies = Statement[]
  @debug "scoobies" scoobies

  norm(s::ResourceCURIE) = Resource(string(pdict[s.prefix].uri, s.localname))
  # `string(::ResourceURI)` renders the constructor call, not the URI, so this has to
  # read the field. Terms written as full IRIs <http://...> were being turned into the
  # literal text `ResourceURI("http://...")`.
  norm(s::ResourceURI) = Resource(s.uri)
  norm(s::Literal) = s
  # Blank nodes must stay blank; the catch-all below would render them as the literal
  # text `Blank("b1")` and wrap that in a Resource.
  norm(s::Blank) = s
  norm(s) = Resource(string(s))
  norm(s::Type) = Resource(URI(URIs.escapeuri(string(s))))
  norm(s::Function) = Resource(URI(URIs.escapeuri(string(s))))

  for s in stmts
    if isa(s,Triple)
      @debug "expanding Triple..." s.subject s.predicate s.object
      t = Triple(norm(s.subject), norm(s.predicate), norm(s.object))
      @debug "produced..." t
      push!(scoobies, t)
    else
      push!(scoobies, norm(s))
      # Experimental!
      # for s in stmts push!(scoobies, isa(s,Triple) ? Triple(norm.[s.subject, s.predicate, s.object]) : norm(s))
    end
  end
  # [push!(scoobies, (s a ResourceCURIE ? Resource(pdict[s.prefix] * s.name) : s)) for s in stmts]
  @debug "scoobies now" scoobies
  scoobies
end
export expand_uris

export localname, ns, parsent, MaybeURI, MaybeString, xsdtype2j, @U_str, valueof
export makeqname
