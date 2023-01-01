module Jayhawk

using Reexport
@reexport using Serd
@reexport using Serd.RDF
@reexport using Serd.RDF.Prefixes
using Logging
using URIs
using Dates
using Random
# using InteractiveUtils: methodswith

export build_model, build_instance_classes, build_model_instances, process_rdf_data, 
qsparql, usparql, superclasses
export makeqname
export rdf_type, rdfs_subClassOf
export Unknown

include("sparqlclient.jl")
include("rdf.jl")
include("sparql.jl")
include("build.jl")

# Jayhawk provides the framework for building applications that are graph-based and data-centric.

function build_model()
    # Set up our prefixes
    add_prefix!("urn","urn:")
    add_prefix!("gist", "https://ontologies.semanticarts.com/gist/")
    add_prefix!("jayhawk", "http://www.semanticweb.org/doug/ontologies/jayhawk#")

    build_classes()
    build_subclasses()
    build_obj_props()
    build_data_props()
    build_typed_props()
end


end # module Jayhawk
