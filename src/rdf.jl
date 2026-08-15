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

  owl_Thing(uri::RORB) = new(uri, Dict())
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

struct owl_NamedIndividual <: RDFType
  uri::RORB
  in::Dict{RORB, RORB}

  owl_NamedIndividual(uri::RORB) = new(uri, Dict())
end

struct owl_Restriction <: RDFType
  uri::RORB
  in::Dict{RORB, RORB}

  owl_Restriction(uri::RORB) = new(uri, Dict())
end

struct owl_Ontology <: RDFType
  uri::RORB
  in::Dict{RORB, RORB}

  owl_Ontology(uri::RORB) = new(uri, Dict())
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
makeqname(prefix::String, name::String) = string(sanitize_name(prefix), "_", sanitize_name(name))

"""
    sanitize_name(s) -> String

Reduce a name fragment to characters legal in a Julia identifier.

Local names routinely contain `-` and `.` (`gist:is-categorized-by`), which produced
Symbols that `eval` happily accepts but that no Julia source file could name and no
caller could write. Since generated code is headed for a precompilable file, the names
have to be legal.
"""
sanitize_name(s::AbstractString) = replace(String(s), r"[^A-Za-z0-9_]" => "_")
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
"""
    bootstrap_uri(prefix, localname) -> ResourceURI

Expand a prefixed name to the full-IRI form every term takes after [`expand_uris`].

`resource_dict` must be keyed the way it will be *looked up*. Terms reaching `retrieve`
have been through `expand_uris`, which turns every `ResourceCURIE` into a `ResourceURI`;
a dictionary keyed by the CURIE form can therefore never be hit. See [`ExpandedTerm`].

The Julia type name is still derived from the prefixed form by the callers below, not
from this IRI: `makeqname(::ResourceURI)` would have to consult the prefix registry,
which makes package load order significant, whereas `makeqname(prefix, name)` is pure.
"""
bootstrap_uri(prefix::AbstractString, localname::AbstractString) =
    Resource(string(prefixforpfx(String(prefix)).uri, localname))

# Create a Julia type for each xsd type
for x in datatypes
  @debug "Creating datatype from uri" x
  pfx,nm = string.(split(x,":"))
  s = Symbol(makeqname(pfx,nm))
  key = bootstrap_uri(pfx, nm)
  @debug "Creating datatype" s key
  eval(
    quote
        @auto_hash_equals struct $s <: OwlDatatype
            v::String
        end
        export $s
        $resource_dict[$key] = $s
    end
  )
end

# Register the seven OWL types the bootstrap depends on, so that `retrieve` can resolve
# an incoming `rdf:type` object to the Julia type that implements it.
#
# This was a `broadcast` over `Resource("owl", "Class")` CURIEs whose value was recovered
# with `(eval ∘ Symbol ∘ makeqname)`. Naming the structs directly means the compiler
# checks them and no `eval` is involved.
for (localname, T) in (("Class",            owl_Class),
                       ("Thing",            owl_Thing),
                       ("ObjectProperty",   owl_ObjectProperty),
                       ("DatatypeProperty", owl_DatatypeProperty),
                       ("NamedIndividual",  owl_NamedIndividual),
                       ("Restriction",      owl_Restriction),
                       ("Ontology",         owl_Ontology))
    resource_dict[bootstrap_uri("owl", localname)] = T
end

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

# `parsent` was exported here but defined nowhere; its only caller was the `build`/
# `objfromdict` pair in sparqlclient.jl, which has been removed along with it.
export localname, ns, MaybeURI, MaybeString, xsdtype2j, @U_str, valueof
export makeqname, sanitize_name
