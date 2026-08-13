module Jayhawk

using Reexport
using Serd, Serd.RDF, Serd.RDF.Prefixes
using Logging
using URIs
using Dates
using Random
using AutoHashEquals
# using InteractiveUtils: methodswith
export build_model, qsparql, usparql
export makeqname, set_def_prefixes
export rdf_type, rdfs_subClassOf
export Unknown
export TraceLog
export retrieve!, store_res!, store_local!, make_from_rdf
export initialize
export resource_dict
# three-phase pipeline: analyze (pure) -> generate (pure) -> install/register/run
export analyze, generate, install!, register!, run_data!, compile
export SchemaModel, ClassSpec, PropertySpec

const RORB = Union{Resource,Blank}
export RORB
# Main dictionary for bootstrapping types
resource_dict = Dict{RORB, Any}()

initialize() = TraceLog(resource_dict, true)

include("tracelog.jl")
include("sparqlclient.jl")
include("sparql.jl")
include("rdf.jl")
include("rdfs.jl")
include("rdf_type.jl")
include("rdfs_subClassOf.jl")
include("analyze.jl")
include("generate.jl")
include("execute.jl")
include("build.jl")

# Jayhawk provides the framework for building applications that are graph-based and data-centric.

function set_def_prefixes()
    add_prefix!("urn:","urn:")
    # gist moved namespaces at v12. Serd keeps a separate uri=>prefix map, so registering
    # both spellings lets makeqname resolve legacy and current data alike; the last one
    # registered is what gist: expands to.
    add_prefix!("gist:", "https://ontologies.semanticarts.com/gist/")
    add_prefix!("gist:", "https://w3id.org/semanticarts/ns/ontology/gist/")
    add_prefix!("sh:", "http://www.w3.org/ns/shacl#")
    add_prefix!("jayhawk:", "http://www.semanticweb.org/doug/ontologies/jayhawk#")
end

"""
    build_model()

Not implemented.

The SPARQL-endpoint helpers this was written against -- `build_classes`,
`build_subclasses`, `build_obj_props`, `build_data_props`, `build_typed_props` -- do not
exist anywhere in the package, so calling this has always thrown `UndefVarError` on the
first line of its body. It raises a useful error instead of pretending otherwise.

Use [`make_from_rdf`](@ref) to load Turtle, or [`compile`](@ref) to install a schema
without executing data.
"""
build_model() = error(
    "build_model is not implemented: the build_classes/build_subclasses/build_obj_props/" *
    "build_data_props/build_typed_props helpers it calls were never written. " *
    "Use make_from_rdf(turtle, tracelog) or compile(turtle).")



end # module Jayhawk
