module Jayhawk

include("sparqlclient.jl")
include("rdf.jl")
include("sparql.jl")

using Serd
using Serd.RDF
using .RDFSupport

# Jayhawk provides the framework for building applications that are graph-based and data-centric.

# Model-driven applet framework
# A model-driven applet provides API and web-based functionality to create, modify and delete a restricted Number
# of entities, usually centered around the needs of one or more business processes.
# A model-driven applet acts as a building block for a full enterprise-specific ERP or other complex application.
# A model-driven applet is composable with other applets and their results may be chained together to compose data workflows that parallel real-world business processes.
# 
# To build an applet you provide:
    # 1) A ontology on which Julia classes will be based, 
    # 2) a series of SPARQL queries that access and manipulate the required data.
    # 3) A set of workflows, exposed as Julia functions that take argument types from 1). Jayhawk provides reference code for 
    # functions that users override to provide custom functionality.
    # Workflows are expressed in RDF - is there a BPMN ontology? - mapped into Julia objects, and executed using 
# 
# Provide through some Julia Web API library a REST API with RDF/JSON-LD/others? data formats
# 
# The applet provides basic CRUD functions (select ?s where ?s a ?class) for each Class
# 
# User provides one or a list of sparql queries and a function name. 
# Jayhawk uses Jena to parse the sparql query(ies) and return its variables (I presume).
# Convert variable values (Jena objects, ie JClasses and JObjects from JavaCall.jl) into Serd RDF and into Julia classes.
# create function function_name(variables from sparql queries)
# 
# Upload a BPMN diagram/file in XML format and map it to the ontology.
# Convert XML to OWL and store in a named graph.
# Propose forms (wizard mode) to capture data needed to traverse the BPM steps, in order.
# 
# From uploaded BPMN file, suggest 1+ applets whose functionality covers the requested workflow.
# 
# IN jayhawk, define a macro to enable a variable to save its contents to the triplestore 
# 
# Build functions from predicates that are defined in the ontology.

# Predicates return literal or entity values for further exploration.
# Framework translates between Julia structs and rdf/owl classes in RDF - how to decide which??? - 

# Use Case: An Application to provide a user interface, functions and database support for Order capture.
# The order ontology may be supplemented by specialized domain ontologies for industry verticals, 
# e.g. Retail, Energy, Transportation, IT Services, etc.
# 
# Idea: Jayhawk generates the Application based on one or more ontologies and User input to choose/remove certain elements from scope.
# Jayhawk uses HTML thing
# The ontology is used as a template to create Julia Types and functions that manipulate them.


struct owl_Class end
struct owl_ObjectProperty end
struct owl_DatatypeProperty end

pfx_dict = Dict(
    "http://www.semanticweb.org/doug/ontologies/ebox#" => "ebox:",
    "https://ontologies.semanticarts.com/gist/" => "gist:",
    "http://www.w3.org/1999/02/22-rdf-syntax-ns#" => "rdf:",
    "http://www.w3.org/2002/07/owl#" => "owl:",
    "http://www.w3.org/2001/XMLSchema#" => "xsd:",
    "http://www.w3.org/2000/01/rdf-schema#" => "rdfs:"
)
rpfx_dict = Dict(values(pfx_dict) .=> keys(pfx_dict))

resource_dict = Dict{Union{ResourceURI,Blank},Any}()

# 1. Fetch subclasses, put each in a dictionary
# 2. Fetch classes. For each subject class, look up its URI in the subclass table
# 3. Build the type using eval, adding in the vector of subclasses for each subject
subclasses = Dict{ResourceURI,Vector{ResourceURI}}()

# The Unknown Type is used when a statement is encountered for which
# we do not have the type of the object.
struct Unknown <: Node
    uri::String
    in::Dict{ResourceURI, Union{ResourceURI,Blank}}
    out::Dict{ResourceURI, Node}
    super::Vector{ResourceURI}
end
Unknown(uri::String) = Unknown(uri,Dict(),Dict(),ResourceURI[])

function qsparql(query::String)
    fnm = tempname()
    write(fnm, runsparql(query))
    read_rdf_file(fnm)
end

# For now, assume no blank nodes will show up from our queries...
#
# struct BlankNode
#     name::String
#     out::Dict{ResourceURI,Node}
#     in::Dict{ResourceURI,Union{ResourceURI,Blank}}
# end
# BlankNode(name:String) = BlankNode(name,Dict(),Dict())

# Transform a URI into a normalized name. 
# e.g. 'http://www.w3.org/2002/07/owl#Class' becomes 'owl_Class'.
function makeqname(s::ResourceURI)
    namesp = ns(s.uri)
    pfx = replace(pfx_dict[namesp],':'=>'_')
    lnm = localname(s.uri)
    pfx*lnm
end

# Create a Julia type from an owl:Class
function rdf_type(s::ResourceURI, ::Type{owl_Class}, sc = ResourceURI[])
    nm = Symbol(makeqname(s))
    @debug "rdf_type $s owl_Class $sc"
    eval(
        quote
            struct $nm
            uri::String
            in::Dict{ResourceURI, Union{ResourceURI,Blank}}
            out::Dict{ResourceURI, Node}
            super::Vector{ResourceURI}
            end
            # constructor
            $nm(uri::String) = $nm(uri,Dict(),Dict(),$sc)
            # convert an Unknown into the new type
            $nm(u::Unknown) = $nm(u.uri, u.in, u.out, u.super)
        
            # store newly created class in dict
            $resource_dict[$s] = $nm

            # create function to instantiate the new type and store it.
            # If the subject was previously seen and stored as an Unknown,
            # convert into the new type.
            function rdf_type(r::ResourceURI, ::Type{$nm})
                @debug "rdf_type $r $nm"
                # if we have already seen this URI, fetch it from the dictionary. It might be an Unknown
                _u = get(resource_dict, r, Unknown(r.uri))
                if typeof(_u) == Unknown
                    # make a new instance and copy the Unknown stuff into it
                    # This also covers the case of a completely new, never seen before instance
                    _instance = $nm(_u)
                    resource_dict[r] = _instance
                else
                    # take the instance that was already created
                    _instance = _u
                end
                _instance
            end
        end
    ) 
end

# Transform a ObjectProperty into a Julia function
function rdf_type(s::ResourceURI, ::Type{owl_ObjectProperty})
    @debug "rdf_type $s owl_ObjectProperty"
    nm = Symbol(makeqname(s))
    eval(
        quote
            function $nm(subj::Union{ResourceURI,Blank}, obj::Union{ResourceURI,Blank})
                @debug "$nm($subj, $obj)"
                #fetch instantiated type from resource dictionary, else Unknown
                # @TODO the next lines will break on a blank node
                s_obj = get(resource_dict, subj, Unknown(subj.uri))
                o_obj = get(resource_dict, obj, Unknown(obj.uri))

                # link the subject and object by the property URI, in both directions
                s_obj.out[$s] = obj
                o_obj.in[$s] = subj

                resource_dict[subj] = s_obj
                resource_dict[obj] = o_obj
            end
        end
    ) 
end

# Transform a DatatypeProperty into a Julia function
function rdf_type(s::ResourceURI, ::Type{owl_DatatypeProperty})
    nm = Symbol(makeqname(s))
    @show s nm
    eval(
        quote
            function $nm(subj::Union{ResourceURI,Blank}, obj::Literal)
                @show subj obj    
                s_obj = get(resource_dict, subj, Unknown(subj.uri))
                s_obj.out[$s] = obj
                resource_dict[subj] = s_obj
            end
        end
    ) 
end

function rdf_type(s::ResourceURI, o::ResourceURI)
    @show "rdf_type $s $o"
    onm = Symbol(makeqname(o))
    oclass = @eval $onm
    rdf_type(s, oclass)
end

rdf_type(s::ResourceURI, ::Type{Blank}) = @debug "rdf_type $s ::Blank"
rdf_type(b::Blank, ::Type{owl_Class}) = @debug "rdf_type ::Blank ::owl_Class"
rdf_type(b::Blank, ::Type{owl_Class}, ::Vector{ResourceURI}) = @debug "rdf_type ::Blank ::owl_Class []"

function rdfs_subClassOf(s::ResourceURI, o::ResourceURI)
    s_type = resource_dict[s]
    o_type = resource_dict[o]
    rdfs_subClassOf(s_type, o_type)
end

function make_type(t::Triple)
    s, p, o = t.subject, t.predicate, t.object
    (p == ResourceURI(rpfx_dict["rdf:"]*"type")) || error("Expected rdf:type for predicate.")
    cnm = Symbol(makeqname(o))
    objclass = @eval $cnm
    # fetch any previously created subclasses to add to the new type
    sc = get(subclasses, s, ResourceURI[])
    rdf_type(s, objclass, sc)
end

function make_any(t::Triple)
    s, p, o = t.subject, t.predicate, t.object
    typnm = Symbol(makeqname(o))
    fnm = Symbol(makeqname(p))
    # Do nothing if the function has already been defined.
    isempty(methodswith(Type{eval(typnm)}, eval(fnm))) || return
    @eval $fnm($s, $o)
end

function make_subclass(t::Triple)
    s, p, o = t.subject, t.predicate, t.object
    (p == ResourceURI(rpfx_dict["rdfs:"]*"subClassOf")) || error("Expected rdfs:subClassOf for predicate.")
    sc = get(subclasses, s, ResourceURI[])
    push!(sc, o)
    subclasses[s] = sc
end

# 
# function make_subclass_blank_o(t::Triple)
#     s, p, o = t.subject, t.predicate, t.object
#     (p == ResourceURI(rpfx_dict["rdfs:"]*"subClassOf")) || error("Expected rdfs:subClassOf for predicate.")
#     sc = get(subclasses, s, ResourceURI[])
    
# end

# Select RDF and create a vector of objects of rdfs:subClassOf statements
# These are not Types yet.
function build_subclasses()
    stmts, pfxs, buri = qsparql(loadsubclasses)
    make_subclass.(stmts)
end

# Select RDF and create a Julia Type for owl:Class
# Previously stored subclasses are added to the Type constructor
function build_classes()
    stmts, pfxs, buri = qsparql(loadclasses)
    make_type.(stmts)        
end

# Select RDF and create functions for each owl:ObjectProperty
function build_obj_props()
    stmts, pfxs, buri = qsparql(loadobjprops)
    make_any.(stmts)            
end

# Select RDF and create functions for each owl:DatatypeProperty
function build_data_props()
    stmts, pfxs, buri = qsparql(loaddataprops)
    make_any.(stmts)            
end

# Select RDF and create instances from the ontology
function build_model_instances()
    stmts, pfxs, buri = qsparql(load_model_instances)
    make_any.(stmts)            
end

# Don't think I need this just yet
# function build_subclass_blank_o()
#     fnm = tempname()
#     write(fnm, runsparql(blank_objects))
#     stmts, pfxs, buri = read_rdf_file(fnm)
# end


function process_rdf_data(t::Triple)
    s, p, o = t.subject, t.predicate, t.object
    propnm = Symbol(makeqname(p))
    @eval $propnm($s, $o)
end

export build_subclasses, build_classes, build_data_props, build_obj_props, build_model_instances, process_rdf_data

end # module Jayhawk
