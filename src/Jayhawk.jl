module Jayhawk

using Reexport
using Serd, Serd.RDF, Serd.RDF.Prefixes
using Logging
using URIs
using Dates
using Random
using AutoHashEquals
# using InteractiveUtils: methodswith
# need to revise this list of exports 
export build_model, build_instance_classes, build_model_instances, process_rdf_data, 
qsparql, usparql
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

function build_model()
    # Set up our prefixes
    set_def_prefixes()
    
    build_classes()
    build_subclasses()
    build_obj_props()
    build_data_props()
    build_typed_props()
end



end # module Jayhawk
