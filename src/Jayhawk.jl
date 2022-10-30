module Jayhawk

using URIs
using Serd

include("sparqlclient.jl")
include("rdf.jl")
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

import Serd.Resource, Serd.Node

Resource(uri::URI) = ResourceURI(uri.uri)
Node(uri::URI) = Node(uri.uri)

ns2fn = Dict{String,Symbol}()
fn2ns = Dict{Symbol,String}()

    # function conforms-to(p::Project)
    #     getindex(p.d, ResourceURI("http://example.org/ontology#conforms-to"))
    # end

    # struct Predicate
    #     fname::String
    #     uri::String
    # end

uri2fname(uri) = split(lowercase(string(uri), r"[^a-z0-9-]"))[-1]


# create getter and setter
fn = Symbol($pred.fname)
s = Symbol("s")
stype = Symbol("")
eval(quote
        function $fn($s::$stype, $o::$otype)
            prop = ResourceURI($pred.uri)
            plist = get($s.out, prop, Node[])
            setindex!($s.out, push!(plist, $o.id.uri, prop))
            push!($o.in, prop)
        end
        $pred.fname($s::$stype) = getindex($s.out, ResourceURI($pred.uri))
    end
)

# end


# function deblankify(rdf::String; baseuri::String = "/")
#     stmts = Serd.read_rdf_string(rdf)
#     for s in stmts

#     end
# end
# 
# Maybe use 

# Use Case: An Application to provide a user interface, functions and database support for Order capture.
# The order ontology may be supplemented by specialized domain ontologies for industry verticals, 
# e.g. Retail, Energy, Transportation, IT Services, etc.
# 
# Idea: Jayhawk generates the Application based on one or more ontologies and User input to choose/remove certain elements from scope.
# Jayhawk uses HTML thing
# The ontology is used as a template to create Julia Types and functions that manipulate them.
# 





end # module Jayhawk
