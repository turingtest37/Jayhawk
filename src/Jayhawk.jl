module Jayhawk

using Reexport
@reexport using Serd
@reexport using Serd.RDF
@reexport using Serd.Prefixes
using Logging
using URIs
using Dates
using Random
using InteractiveUtils: methodswith

export build_subclasses, build_classes, build_data_props, 
build_obj_props, build_model_instances, build_typed_props, build_all, process_rdf_data, 
build_instance_classes, build_typed_instance_props, qsparql, usparql, resource_dict, superclasses
export makeqname
export rdf_type, rdfs_subClassOf
export Unknown

include("sparqlclient.jl")
include("rdf.jl")
include("sparql.jl")
include("build.jl")


# Jayhawk provides the framework for building applications that are graph-based and data-centric.


function build_all()
    build_classes()
    build_instance_classes()
    build_subclasses()
    build_obj_props()
    build_data_props()
    build_typed_props()
    build_model_instances()
    build_typed_instance_props()
end


end # module Jayhawk
