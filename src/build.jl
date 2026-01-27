
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
    pname = Symbol(makeqname(p))
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
    @debug "make_property" s p o
# Returns the function reference to the new property
    if o isa Literal # and the worst ones are!
        make_typed_data_prop(t, tl)
    else
        make_typed_object_prop(t, tl)
    end
end

# USED
""" Generate a method from the predicate IRI. This will create an object or data property without
an rdf:type declaration for the property.
How should this be stored?

** Definitions (first time use or RDFS/OWL type declarations)
Julia (a.k.a "local") dictionary
<IRI> => Function/Type::Unknown/Julia Datatype Type (not instance)


Resource dictionary
<IRI> => instance of rdf_Property/owl_ObjectProperty/rdfs_Class/owl_Class/xsd_Datatype

Cases:
<s> <ns_predicate> <o>
    define a Julia Function + methods
    store in Julia dictionary as <user_ns>_predicate => Function
    store in Resource dictionary as <user_ns>_predicate => rdfs_Property(ns:predicate)

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
    @debug "make_typed_object_prop rdf_subject julia_subject typeof(subject)" s sobj stype

    eval(
        quote

            # TODO Collapse these method definitions into a smaller list with Union{} type

            # Both subject and object as known Julia types
            function $propnm(subj::Union{$stype,Unknown}, obj::Union{$otype,Unknown}, tl = $tl)
                @debug "Function called:" $propnm subj obj
                add_entry!(tl, subj, $p, obj, $propnm)
            end
            # # Subject only as known Julia types
            # function $propnm(subj::$stype, obj::Unknown, tl = $tl)
            #     @debug "Function called:" $propnm subj obj
            #     add_entry!(tl, subj, $p, obj, $propnm)
            #     # add_entry!(tl, s, p, o, $propnm)
            # end
            # # Object only as known Julia type
            # function $propnm(subj::Unknown, obj::$otype, tl=$tl)
            #     @debug "Function called: " $propnm subj obj
            #     add_entry!(tl, subj, $p, obj, $propnm)
            #     # @info "Added future for" $propnm $s $o
            #     # add_entry!(tl, subj, $propnm, obj)
            # end
            # # Both subject and object as Unknown Julia types
            # function $propnm(subj::Unknown, obj::Unknown, tl=$tl)
            #     @debug "Function called: " $propnm subj obj
            #     add_entry!(tl, subj, $p, obj, $propnm)
            #     # @info "Added future for" $propnm $s $o
            # end

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

            function $propnm(subj, obj::Any, tl::TraceLog = $tl) #where {T <: RDFType}
                @debug "Data property function called: " $propnm subj obj
                add_entry!(tl, subj, $p, obj, $propnm)
                store_local!(tl, obj, subj.uri)
                subj.out[$p] = obj 
            end
            function $propnm(subj::Unknown, obj::Any, tl::TraceLog = $tl)
                @debug "Data property function called: " $propnm subj obj 
                add_entry!(tl, subj, $p, obj, $propnm)
                store_local!(tl, obj, subj.uri)
                subj.out[$p] = obj 
            end
            function $propnm(subj::$stype, obj::Literal, tl::TraceLog = $tl)
                @debug "Data property function called: " $propnm subj obj 
                $propnm(subj, obj.value, tl)
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
