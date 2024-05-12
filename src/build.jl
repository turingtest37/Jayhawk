
# 1. Fetch subclasses, put each in a dictionary
# 2. Fetch classes. For each subject class, look up its URI in the subclass table
# 3. Build the type using eval, adding in the vector of subclasses for each subject
# subclasses = Dict{ResourceURI,Vector{ResourceURI}}()
# superclasses = Dict{Union{ResourceURI,ResourceCURIE},Vector{Union{ResourceURI,ResourceCURIE}}}()

# USED
function make_from_rdf(t::String, tl::TraceLog)
    triples = scoobify(read_rdf_string(t)...)
    Jayhawk._make_anything.(triples, Ref(tl))
    build_pass_two!(tl)
end

# USED
function _make_anything(p::Prefix, tl::TraceLog)
    @debug "make_anything" p

    # Is this needed???????
    add_prefix!(p.name, p.uri)
end

# USED
function _make_anything(buri::BaseURI, tl::TraceLog)
    @debug "make_anything" buri
    # tl.rdict[buri] = addPrefix!(":",buri.uri)
end

# USED
# Starting point
function _make_anything(t::Triple, tl::TraceLog)
    s, p, o = t.subject, t.predicate, t.object
    @debug "make_anything" s p o
    # (p == ResourceURI(prefixforname("rdf")*"type")) || error("Expected rdf:type for predicate.")\

    # resolve p as fname. if fnamed is defined, eval it, otherwise create it first and then eval it.
    pname = Symbol(makeqname(p))
    # iterate over subject and object names to create all method permutations on the URI-like and Unknown type arguments to fname.
    # the methods update a trace log, adding entries in either the global resource dictionary or a local dictionary that is 
    # initialized for a particular group of triples, such as the result of a SPARQL CONSTRUCT query against a triplestore, or from
    # locally defined triples via the Serd API. The local dictionary holds the contents of a given block of RDF Statements, usually the 
    # result of some iterator defined by the result of an HTTP query using the REST API to a SPARQL endpoint on some server, local or remote.
    # The statements are returned from the server as either N-Triples or Turtle. The Serd API reads the RDF text stream and creates an output stream of RDF objects: Statements, Triples, Prefixes, etc. and makes that stream available to a calling function.
    # Each of those Triples is passed into this make_anything function 

# The idea here is to implement ML-driven "stored procedures", i.e. 
construct some RDF containing data that is produced by ML, dynamically

construct
{
    
    :_MLAction_A1 a :MLAction ;
        :triggeredBy :has_12_mo_probability_of_death ;
        :input ?_age ;
        :input ?_sex ;
        :input ?_country ;
        :outputtype xsd:decimal ;
        :output <_p12d> ;
    .

    ?_person :has_12_mo_probability_of_death <_p12d> .

}
where
{

    VALUES ?ssn { 223432994 }
    ?:_Person_patient_123 a :Person ;
        :isIdentifiedBy [
            a gist:ID ;
            gist:uniqueText ?ssn ;
            .
        ]
        :hasAge ?_age ;
        :hasSex ?_sex ;
        :livesIn ?_country ;
    .

    # :has_12_mo_probability_of_death a owl_ObjectProperty ;
    #     :
    # .

    service <sparqlanything:content>
    {
        fsx:properties :datasource ?_json_data ;
        fsx:outputformat...
        .

        BIND( AS ?_json_data)
    }


}


    @debug "trying..." pname
    if isdefined(@__MODULE__, pname)
        # pobj = @eval pname
        @debug "Calling " pname s o
        @eval $pname($s,$o,$tl)
    else
        @debug "pname not found. Making typed property" pname
        pred = make_property(t, tl)

        # POSSIBLE ALTERNATIVE -  CREATE A SECOND PASS
        f = (pred, s, o)
        push!(tl.futures, f)
        @info "Queued future call : " pred s o
    end
end

# USED
"""
Create either a typed object property or typed datatype property depending on the triple's type.
"""
function make_property(t::Triple, tl::TraceLog)
    s, p, o = t.subject, t.predicate, t.object
    @debug "make_typed_instance_prop" s p o
    isa(o, Literal) ? make_typed_data_prop(t, tl) : make_typed_object_prop(t, tl)
end

# USED
""" Generate a method from the predicate IRI. This will create an object or data property without
an rdf:type declaration for the property.
How should this be stored?

** Definitions (first time use or RDFS/OWL type declarations)
Julia dictionary
<IRI> => Function/Julia Datatype Type (not instance)/Unknown Type


Resource dictionary
<IRI> => instance of rdf_Property/owl_ObjectProperty/rdfs_Class/owl_Class/xsd_Datatype

Cases:
<s> <ns_predicate> <o>
    define a Julia Function + methods
    store in Julia dictionary as <user_ns>_predicate => Function
    store in Resource dictionary as <user_ns>_predicate => rdfs_Property(iri)

<s> rdf_type owl_ObjectProperty | <s> rdf_type owl_DatatypeProperty
    define a Julia Function + methods
    store in Julia dictionary as <user_ns>_predicate => Function
    store in Resource dictionary as <s> => owl_ObjectProperty(iri) | owl_DatatypeProperty(iri)

<s> rdf_type owl_Class | <s> rdf_type rdfs_Class
    if <s> is already in the Julia dictionary as a Julia Datatype Type
        store in Resource dictionary as <s> => owl_Class(s) | rdfs_Class(s)
    elseif <s> in Julia Dictionary as Unknown(s)
        # This would be the case if another triple has already created an 
        define a Julia Datatype
        store in Julia dictionary as <s> => Datatype(Unknown(s))
        store in Resource dictionary as <s> => owl_Class(s) | rdfs_Class(s)
    else # s is not in dictionary
        define a Julia Datatype
        store in Julia dictionary as <s> => Datatype
        store in Resource dictionary as <s> => owl_Class(iri) | rdfs_Class(iri)
    end

<s> rdf_type <o>
    if <o> in Resource Dictionary
        create instance of Datatype as <Datatype>(o)
        store in Julia dictionary as <o> => <Datatype>(o)
    else
        create instance of Unknown as Unknown(o)
        store in Julia dictionary as <o> => Unknown(o)
    end


Later, if an "?s rdf:type owl:ObjectProperty" statement is encountered with this subject IRI, we replace rdf:Property with:
<predIRI> => owl_ObjectProperty

** Usage (second time + use)
::Function(::Datatype, ::Datatype) => write(::IO, (:propnm,)) 
::Function(::Datatype, ::Any) 

"""
function make_typed_object_prop(t::Triple, tl::TraceLog)
    @debug "make_typed_obj_prop" t
    s, p, o = t.subject, t.predicate, t.object
    # stypenm = Symbol(makeqname(s))
    propnm = Symbol(makeqname(p))
    @debug "make_typed_object_prop predicate:" propnm

    # resolve o to a Julia type or Unknown
    oobj = retrieve!(tl, o) 
    otype = typeof(oobj)
    @debug "make_typed_object_prop object typeof(object)" oobj otype
    if otype <: OwlDatatype
        return make_typed_data_prop(t, tl)
    end

    # resolve s to a Julia type or Unknown
    sobj = retrieve!(tl, s)
    stype = typeof(sobj)
    @debug "make_typed_object_prop subject typeof(subject)" sobj stype

    eval(
        quote

            # TODO Collapse these method definitions into a smaller list with Union{} type

            # Both subject and object as known Julia types
            function $propnm(subj::$stype, obj::$otype, tl = $tl)
                @debug "Function called:" $propnm subj obj
                # add_entry!(tl, s, p, o, $propnm)
            end
            # Subject only as known Julia types
            function $propnm(subj::$stype, obj::Unknown, tl = $tl)
                @debug "Function called:" $propnm subj obj
                # add_entry!(tl, s, p, o, $propnm)
            end
            # Object only as known Julia type
            function $propnm(subj::Unknown, obj::$otype, tl=$tl)
                @debug "Function called: " $propnm subj obj
                # @info "Added future for" $propnm $s $o
                # add_entry!(tl, subj, $propnm, obj)
            end
            # Both subject and object as Unknown Julia types
            function $propnm(subj::Unknown, obj::Unknown, tl=$tl)
                @debug "Function called: " $propnm subj obj
                # @info "Added future for" $propnm $s $o
                # add_entry!(tl, subj, $propnm, obj)
            end

            # Both subject and object as Resources or Blanks
            # This will become the entry point for future calls to this predicate
            function $propnm(subj::RORB, obj::RORB, tl=$tl)
                @debug "Function called: " $propnm subj obj
                $propnm(retrieve!(tl, subj), retrieve!(tl, obj), tl)
                # add_entry!(tl, subj, $propnm, obj)
            end
            export $propnm

            add_entry!($tl, $s, $p, $o, $propnm)
        end
    )
    @info "Created object property function" propnm
    propnm
end


# USED
""" Generate a no-op method with appropriate types for the arguments
"""
function make_typed_data_prop(t::Triple, tl::TraceLog)
    s, p, o = t.subject, t.predicate, t.object
    @debug "make_typed_data_prop" s p o
    propnm = Symbol(makeqname(p))
    stype = typeof(retrieve!(tl,s))

    @debug "make_typed_data_prop subject typeof(subject)" s stype

    eval(
        quote

            function $propnm(s, obj::Any, tl::TraceLog = $tl) #where {T <: RDFType}
                @debug "Data property function called: " $propnm s obj
                # store_local!(tl, obj, subj.uri)
                # subj.out[$p] = obj 
                # add_enxtry!($tl, subj, $propnm, obj)
            end
            function $propnm(subj::Unknown, obj::Any, tl::TraceLog = $tl)
                @debug "Data property function called: " $propnm subj obj 
                # store_local!(tl, obj, subj.uri)
                # add_entry!($tl, subj, $propnm, obj)
            end
            function $propnm(subj::$stype, obj::Literal, tl::TraceLog = $tl)
                @debug "Data property function called: " $propnm subj obj 
                $propnm(subj, obj.value, tl)
                # add_entry!($tl, subj, $propnm, obj)
            end

            # The entry point for future calls to this function
            function $propnm(subj::RORB, obj::Literal, tl::TraceLog = $tl)
                @debug "Data property function called: " $propnm subj obj
                $propnm(retrieve!(tl,subj), obj.value, tl)
                # store_local!(tl, obj.value, subj)
                # add_entry!($tl, subj, $propnm, obj)
            end
            export $propnm

            # add_entry!($tl, $s, $p, $o, $propnm)
        end
    )    
    @info "Created datatype function" propnm
    propnm
    end


# Select RDF and create a Julia Type for owl:Class
# Previously stored subclasses are added to the Type constructor
# function build_classes()
#     @info "Building classes..."
#     stmts,pfx,buri = qsparql(loadclasses)   
#     make_type_or_instance.(stmts,Ref(resource_dict))    
# end

# function build_pass_one!(tl::TraceLog = initialize())
#     @info "Building model in one pass..."
#     stmts,pfx,buri = qsparql(loadmodel)
#     make_anything.(stmts, Ref(tl))
#     tl
# end

function build_pass_two!(tl::TraceLog)
    @info "tracelog has $(length(tl.futures)) expressions for future evaluation."
    while !isempty(tl.futures)
        f = Base.pop!(tl.futures)
        @debug "Creating expression from future " f
        e = Expr(:call, f..., tl)
        @debug "Evaluating..." e  
        @eval $e
    end
    tl    
end
export build_pass_one!, build_pass_two!

# function build_instance_classes()
#     @info "Building instance classes..."
#     stmts,pfx,buri = qsparql(load_instance_defns)
#     make_type_or_instance.(stmts,Ref(resource_dict))
# end

# Select RDF and create functions for each owl:ObjectProperty
# function build_obj_props()
#     @info "Building object properties..."
#     stmts,pfx,buri = qsparql(loadobjprops)
#     @debug "build_obj_props" stmts
#     make_obj_dt_prop.(stmts, Ref(resource_dict))            
# end

# Select RDF and create functions for each owl:DatatypeProperty
# function build_data_props()
#     @info "Building data properties..."
#     stmts,pfx,buri = qsparql(loaddataprops)
#     @debug "build_data_props" stmts
#     make_obj_dt_prop.(stmts, Ref(resource_dict))            
# end

# function build_typed_props()
#     @info "Building typed properties..."
#     stmts,pfx,buri = qsparql(load_typed_properties)
#     tl = TLog(resource_dict)
#     make_property.(stmts, Ref(tl))
#     @show tl
# end

# Select RDF and create instances from the ontology
# function build_model_instances()
#     @info "Building model instances..."
#     stmts,pfx,buri = qsparql(load_model_instances)
#     process_rdf_data.(stmts)            
# end

# function process_rdf_data(t::Triple; d::T = resource_dict) where {T<:AbstractDict}
#     @debug "process_rdf_data" t
#     s, p, o = t.subject, t.predicate, t.object
#     propnm = Symbol(makeqname(p))
#     @debug "Calling $propnm($s, $o)..."
#     @eval $propnm($s, $o, $d)
# end
