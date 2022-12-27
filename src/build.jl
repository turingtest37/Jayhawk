
struct owl_Class end
struct owl_Thing end
struct owl_ObjectProperty end
struct owl_DatatypeProperty end
struct owl_NamedIndividual end

# pfx_dict = Dict(
#     "http://www.semanticweb.org/doug/ontologies/ebox#" => "ebox:",
#     "http://www.semanticweb.org/doug/ontologies/jayhawk#" => "jayhawk:",
#     "https://ontologies.semanticarts.com/gist/" => "gist:",
#     "http://www.w3.org/1999/02/22-rdf-syntax-ns#" => "rdf:",
#     "http://www.w3.org/2002/07/owl#" => "owl:",
#     "http://www.w3.org/2001/XMLSchema#" => "xsd:",
#     "http://www.w3.org/2000/01/rdf-schema#" => "rdfs:",
#     "urn:" => "urn:"
# )
# rpfx_dict = Dict(values(pfx_dict) .=> keys(pfx_dict))


resource_dict = Dict{Union{ResourceURI,Blank},Any}()

# 1. Fetch subclasses, put each in a dictionary
# 2. Fetch classes. For each subject class, look up its URI in the subclass table
# 3. Build the type using eval, adding in the vector of subclasses for each subject
# subclasses = Dict{ResourceURI,Vector{ResourceURI}}()
superclasses = Dict{ResourceURI,Vector{ResourceURI}}()

# The Unknown Type is used when a statement is encountered for which
# we do not (yet) have the type of the object.
struct Unknown <: Node
    uri::String
    in::Dict{ResourceURI, Union{ResourceURI,Blank}}
    out::Dict{ResourceURI, Node}
    super::Vector{ResourceURI}
end
Unknown(uri::String) = Unknown(uri,Dict(),Dict(),ResourceURI[])
Unknown(u::ResourceURI) = Unknown(u.uri)

function qsparql(query::String)
    fnm = tempname()
    write(fnm, runsparql(query))
    read_rdf_file(fnm)
end

function usparql(upd::String; dict=Dict())
    runsparql(upd, true, dict)
end

# Create a Julia type from an owl:Class
function rdf_type(s::ResourceURI, ::Type{owl_Class}, d::T) where {T<:AbstractDict}
    nm = Symbol(makeqname(s))
    @debug "rdf_type($s owl_Class)"
    eval(
        quote
            struct $nm
                uri::String
                in::Dict{ResourceURI, Union{ResourceURI,Blank}}
                out::Dict{ResourceURI, Node}
                super::Vector{ResourceURI}
            end

            function $nm(uri::String, in::Dict, out::Dict)
                supclasses = get(resource_dict, ResourceURI(uri), ResourceURI[])
                $nm(uri,in,out,supclasses)
            end

            # convenience constructors
            $nm(uri::String) = $nm(uri,Dict(),Dict())
            $nm(u::ResourceURI) = $nm(u.uri)            
            # constructor to convert an Unknown into the new type
            $nm(u::Unknown) = $nm(u.uri, u.in, u.out, u.super)
        
            export $nm

            # store newly created class in dict
            $d[$s] = $nm

            # create function to instantiate the new type and store it.
            # If the subject was previously seen and stored as an Unknown,
            # convert into the new type.
            function rdf_type(r::ResourceURI, ::Type{$nm}, dict::T) where {T<:AbstractDict}
                @debug "rdf_type" r Type{$nm}
                # if we have already seen this URI, fetch it from the dictionary. It might be an Unknown
                _instance = get!(dict, r) do
                    # make a new instance and copy the Unknown stuff into it
                    # This also covers the case of a completely new, never seen before instance
                    $nm(r)
                end
                @debug "retrieved from dict:" _instance
                if typeof(_instance) == Jayhawk.Unknown
                    dict[r] = $nm(_instance)
                end
                @debug "new instance is " dict[r]
            end
        end
    ) 
end

# Transform a ObjectProperty into a Julia function
function rdf_type(s::ResourceURI, ::Type{owl_ObjectProperty}, d::T) where {T<:AbstractDict}
    @debug "rdf_type($s Type{owl_ObjectProperty})"
    nm = Symbol(makeqname(s))
        eval(
        quote
            function $nm(subj::Union{ResourceURI,Blank}, obj::Union{ResourceURI,Blank}, dict::T) where {T<:AbstractDict}
                #fetch instantiated type from resource dictionary, else Unknown
                # @TODO the next lines will break on a blank node
                subj_type = get!(dict, subj) do 
                    Unknown(subj)
                end 
                obj_type = get!(dict, obj) do 
                    Unknown(obj) 
                end

                # link the subject and object by the property URI, in both directions
                subj_type.out[$s] = obj
                obj_type.in[$s] = subj

                try
                    $nm(subj_type, obj_type, dict)
                catch e
                    @error "Failed to call method." $nm subj_type obj_type e
                end
            end
            # register new function in resource dictionary``
            $d[$s] = $nm
            export $nm
        end
        )
end

# Transform a DatatypeProperty into a Julia function
function rdf_type(s::ResourceURI, ::Type{owl_DatatypeProperty}, d::T) where {T<:AbstractDict}
    @debug "rdf_type($s, Type{owl_DatatypeProperty})"
    nm = Symbol(makeqname(s))
    eval(
        quote
            function $nm(subj::ResourceURI, obj::Literal, dict::T) where {T<:AbstractDict}
                @debug $nm subj obj
                subj_type = get!(dict, subj) do 
                    Unknown(subj)
                end
                subj_type.out[$s] = obj

                try
                    $nm(subj_type, obj.value, dict)
                catch e
                    @warn "Failed to call method." $nm subj_type obj.value e
                end
             end
            # Store the new function in the resource dictionary and export it
            $d[$s] = $nm
            export $nm
        end
    ) 
end

function rdf_type(s::ResourceURI, ::Type{owl_NamedIndividual}, d::T) where {T<:AbstractDict}
end

"""
Here we are assuming:
1 s refers to an instance
2 o refers to a class for which there already exists a Julia type definition <= MAYBE THIS IS WRONG
"""
function rdf_type(s::ResourceURI, o::ResourceURI, d::T) where {T<:AbstractDict}
    @debug "rdf_type($s, $o)"
    objnm = Symbol(makeqname(o))
    oclass = @eval $objnm
    @debug "Calling rdf_type($s, $oclass) ..."
    rdf_type(s, oclass, d)
end

function rdf_type(s::ResourceURI, ::Type{owl_Thing}, d::T) where {T<:AbstractDict}
    @debug "rdf_type $s ::owl_Thing"
end

rdf_type(s::ResourceURI, ::Type{Blank}, d::T) where {T<:AbstractDict} = @debug "rdf_type $s ::Blank"
rdf_type(b::Blank, ::Type{owl_Class}, d::T) where {T<:AbstractDict} = @debug "rdf_type ::Blank ::owl_Class"
rdf_type(b::Blank, o::ResourceURI, d::T) where {T<:AbstractDict} = @debug "rdf_type $b $o"


# Unused for now...
function rdfs_subClassOf(s::ResourceURI, o::ResourceURI)
    @debug "rdfs_subClassOf($s, $o)"
    s_type = get(resource_dict, s, Unknown(s))
    o_type = get(resource_dict, o, Unknown(o))
    rdfs_subClassOf(s_type, o_type)
end

function owl_sameAs(s::ResourceURI, o::ResourceURI)
    s_type = get(resource_dict, s, Unknown(s))
    o_type = get(resource_dict, o, Unknown(o))

    
end

function make_type_or_instance(t::Triple, d::T) where {T<:AbstractDict}
    s, p, o = t.subject, t.predicate, t.object
    # (p == ResourceURI(prefixforname("rdf")*"type")) || error("Expected rdf:type for predicate.")
    rdf_type(s,o,d)
end

# The subject will become the function name; the object determines
# whether to create a Datatype or Object Property.
function make_obj_dt_prop(t::Triple, d::T) where {T<:AbstractDict}
    s, p, o = t.subject, t.predicate, t.object
    # (p == ResourceURI(rpfx_dict["rdf:"]*"type")) || error("Expected rdf:type for predicate.")
    typenm = Symbol(makeqname(o))
    try
        rdf_type(s, eval(typenm), d)
    catch e
        @warn "Failed to call rdf_type($s, $(eval(typenm)) dict" e
    end
end

# @todo make this call rdfs_subClassOf
function make_subclass(t::Triple)
    s, p, o = t.subject, t.predicate, t.object
    # (p == ResourceURI(rpfx_dict["rdfs:"]*"subClassOf")) || error("Expected rdfs:subClassOf for predicate.")
    supc = get(superclasses, s, ResourceURI[])
    push!(supc, o)
    superclasses[s] = supc
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
    @info "Building subclasses..."
    stmts = qsparql(loadsubclasses)
    make_subclass.(stmts)
end

""" Generate a no-op method with appropriate types for the arguments
"""
function make_typed_prop(t::Triple; d::T = resource_dict) where {T<:AbstractDict}
    @debug "make_typed_obj_prop" t
    s, p, o = t.subject, t.predicate, t.object
    subjnm = Symbol(makeqname(s))
    propnm = Symbol(makeqname(p))
    objnm = Symbol(makeqname(o))
    @debug "make_typed_obj_prop" subjnm propnm objnm

    # This forces datatype objects to be declared as Any instead of their XSD or OWL type
    try
        otype = @eval $objnm
        @debug "object type" otype

        if otype <: OwlDatatype
            return make_typed_data_prop(t; d=d)
        end
    catch e
        @warn "No type found for object name." objnm
    end

    eval(
        quote
            function $propnm(subj::$subjnm, obj::$objnm, dict::T = $d) where {T<:AbstractDict}
                @debug "Function called: " $propnm subj obj 
                nothing
            end
            export $propnm
        end
    )
    @info "Created function $propnm(::$subjnm,::$objnm)"
end

"""
Create either a typed object property or typed datatype property depending on the triple's type.
"""
function make_typed_instance_prop(t::Triple; d::T = resource_dict) where {T<:AbstractDict}
    s, p, o = t.subject, t.predicate, t.object
    @debug "make_typed_instance_prop" s p o
    typeof(o) == Literal ? make_typed_data_prop(t; d=d) : make_typed_prop(t; d=d)
end

""" Generate a no-op method with appropriate types for the arguments
"""
function make_typed_data_prop(t::Triple; d::T = resource_dict) where {T<:AbstractDict}
    s, p, o = t.subject, t.predicate, t.object
    @debug "make_typed_data_prop" s p o
    subjnm = Symbol(makeqname(s))
    propnm = Symbol(makeqname(p))
    @debug "make_typed_data_prop" subjnm propnm

    eval(
        quote
            function $propnm(subj::$subjnm, obj::Any, dict::T = $d) where {T<:AbstractDict}
                @debug "Function called: " $propnm subj obj 
                nothing
            end
            export $propnm
        end
    )    
end

# Select RDF and create a Julia Type for owl:Class
# Previously stored subclasses are added to the Type constructor
function build_classes()
    @info "Building classes..."
    stmts = qsparql(loadclasses)
    make_type_or_instance.(stmts,Ref(resource_dict))       
end

function build_instance_classes()
    @info "Building instance classes..."
    stmts = qsparql(load_instance_defns)
    make_type_or_instance.(stmts,Ref(resource_dict))
end

# Select RDF and create functions for each owl:ObjectProperty
function build_obj_props()
    @info "Building object properties..."
    stmts = qsparql(loadobjprops)
    @debug "build_obj_props" stmts
    make_obj_dt_prop.(stmts, Ref(resource_dict))            
end

# Select RDF and create functions for each owl:DatatypeProperty
function build_data_props()
    @info "Building data properties..."
    stmts = qsparql(loaddataprops)
    @debug "build_data_props" stmts
    make_obj_dt_prop.(stmts, Ref(resource_dict))            
end

function build_typed_props()
    @info "Building typed properties..."
    stmts = qsparql(load_typed_properties)
    make_typed_prop.(stmts)
end

# Select RDF and create instances from the ontology
function build_model_instances()
    @info "Building model instances..."
    stmts = qsparql(load_model_instances)
    process_rdf_data.(stmts)            
end

function process_rdf_data(t::Triple; d::T = resource_dict) where {T<:AbstractDict}
    @debug "process_rdf_data" t
    s, p, o = t.subject, t.predicate, t.object
    propnm = Symbol(makeqname(p))
    @debug "Calling $propnm($s, $o)..."
    @eval $propnm($s, $o, $d)
end
