
# 1. Fetch subclasses, put each in a dictionary
# 2. Fetch classes. For each subject class, look up its URI in the subclass table
# 3. Build the type using eval, adding in the vector of subclasses for each subject
# subclasses = Dict{ResourceURI,Vector{ResourceURI}}()
# superclasses = Dict{Union{ResourceURI,ResourceCURIE},Vector{Union{ResourceURI,ResourceCURIE}}}()

function make_from_rdf(t::String, tl::TraceLog)
    triples = scoobify(read_rdf_string(t)...)
    Jayhawk.make_anything.(triples, Ref(tl))
end

function make_anything(p::Prefix, tl::TraceLog)
    @debug "make_anything" p

    # Is this needed???????
    add_prefix!(p.name, p.uri)
end

function make_anything(buri::BaseURI, tl::TraceLog)
    @debug "make_anything" buri
    # tl.rdict[buri] = addPrefix!(":",buri.uri)
end

# Starting point
function make_anything(t::Triple, tl::TraceLog)
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

"""
Create either a typed object property or typed datatype property depending on the triple's type.
"""
function make_property(t::Triple, tl::TraceLog)
    s, p, o = t.subject, t.predicate, t.object
    @debug "make_typed_instance_prop" s p o
    typeof(o) == Literal ? make_typed_data_prop(t, tl) : make_typed_object_prop(t, tl)
end

""" Generate a no-op method with appropriate types for the arguments
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
    @eval :(propnm)
end


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
    @eval :(propnm)
    end

# Select RDF and create a Julia Type for owl:Class
# Previously stored subclasses are added to the Type constructor
function build_classes()
    @info "Building classes..."
    stmts,pfx,buri = qsparql(loadclasses)   
    make_type_or_instance.(stmts,Ref(resource_dict))    
end

function build_pass_one!(tl::TraceLog = initialize())
    @info "Building model in one pass..."
    stmts,pfx,buri = qsparql(loadmodel)
    make_anything.(stmts, Ref(tl))
    tl
end

function build_pass_two!(tl::TraceLog)
    @info "tracelog has $(length(tl.futures)) expressions for future evaluation."
    while !isempty(tl.futures)
        f = Base.pop!(tl.futures)
        e = Expr(:call, f..., tl)
        @debug "evaluating..."  
        @eval $e
    end
    tl    
end
export build_pass_one!, build_pass_two!

function build_instance_classes()
    @info "Building instance classes..."
    stmts,pfx,buri = qsparql(load_instance_defns)
    make_type_or_instance.(stmts,Ref(resource_dict))
end

# Select RDF and create functions for each owl:ObjectProperty
function build_obj_props()
    @info "Building object properties..."
    stmts,pfx,buri = qsparql(loadobjprops)
    @debug "build_obj_props" stmts
    make_obj_dt_prop.(stmts, Ref(resource_dict))            
end

# Select RDF and create functions for each owl:DatatypeProperty
function build_data_props()
    @info "Building data properties..."
    stmts,pfx,buri = qsparql(loaddataprops)
    @debug "build_data_props" stmts
    make_obj_dt_prop.(stmts, Ref(resource_dict))            
end

function build_typed_props()
    @info "Building typed properties..."
    stmts,pfx,buri = qsparql(load_typed_properties)
    tl = TLog(resource_dict)
    make_property.(stmts, Ref(tl))
    @show tl
end

# Select RDF and create instances from the ontology
function build_model_instances()
    @info "Building model instances..."
    stmts,pfx,buri = qsparql(load_model_instances)
    process_rdf_data.(stmts)            
end

function process_rdf_data(t::Triple; d::T = resource_dict) where {T<:AbstractDict}
    @debug "process_rdf_data" t
    s, p, o = t.subject, t.predicate, t.object
    propnm = Symbol(makeqname(p))
    @debug "Calling $propnm($s, $o)..."
    @eval $propnm($s, $o, $d)
end
