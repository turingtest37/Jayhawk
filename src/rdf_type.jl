"""
Starting point for all calls to rdf_type
"""
function rdf_type(s::Resource, o::Resource, tl::TraceLog)
    @debug "rdf_type($s, $o)"
    oobj = retrieve!(tl, o, )
    objs = Symbol(makeqname(o))
    if _defined(@__MODULE__, objs)
        # Was `@eval $objs`. A plain lookup does the same job without invoking the
        # compiler once per rdf:type triple.
        oobj = _lookup(@__MODULE__, objs)
    end
    # sobj = retrieve!(tl, s)
    @debug "Calling rdf_type($s, $oobj)..."
    rdf_type(s, oobj, tl)
    if (s == Serd.RDF.Resource("http://www.w3.org/2002/07/owl#TransitiveProperty"))
        error("Can't handle transitive properties. Stopping here.")
    end
end

# The owl:Class / owl:ObjectProperty / owl:DatatypeProperty generators that used to live
# here now produce Exprs in generate.jl instead of calling eval themselves, and the
# schema triples that reached them are consumed by analyze.jl. See src/generate.jl.

function rdf_type(s::Resource, ::Type{owl_NamedIndividual}, tl::TraceLog)
    @debug "rdf_type $s Type{owl_NamedIndividual}"
    store_local!(tl, owl_NamedIndividual(s), s)
end

# owl:Ontology and owl:Restriction reach here as ordinary data -- analyze only consumes
# the class and property declarations -- so they need methods of their own. Without one,
# a single `<ontology> a owl:Ontology` triple threw and was silently counted as a
# failure. Restrictions are usually blank nodes.
function rdf_type(s::Resource, ::Type{owl_Ontology}, tl::TraceLog)
    @debug "rdf_type $s ::owl_Ontology"
    store_local!(tl, owl_Ontology(s), s)
end

function rdf_type(s::RORB, ::Type{owl_Restriction}, tl::TraceLog)
    @debug "rdf_type $s ::owl_Restriction"
    store_local!(tl, owl_Restriction(s), s)
end

# import Base.setindex!

function rdf_type(s::Resource, o::Unknown, tl::TraceLog)
    @debug "rdf_type" s o
    store_local!(tl, o, s)
    # @info "Added future for" rdf_type s o
end

function rdf_type(s::Unknown, o::Unknown, tl::TraceLog)
    @debug "rdf_type" s o
    store_local!(tl, o, s)
    # @info "Added future for" rdf_type s o
end

function rdf_type(s::Resource, ::Type{owl_Thing}, tl::TraceLog)
    @debug "rdf_type $s ::owl_Thing"
    store_local!(tl, owl_Thing(s), s)
end

function rdf_type(s::Resource, o::Blank, tl::TraceLog)
    @debug "rdf_type $s $o"
    store_local!(tl, o, s)
end

function rdf_type(b::Blank, ::Type{owl_Class}, tl::TraceLog)
    @debug "rdf_type($b , ::owl_Class)"
    store_local!(tl, owl_Class(b), b)
end

function rdf_type(b::Blank, o::Resource, tl::TraceLog)
    @debug "rdf_type $b $o"
    oobj = retrieve!(tl, o)
    rdf_type(b, oobj, tl)
end

function rdf_type(b::Blank, o::Unknown, tl::TraceLog)
    @debug "rdf_type $b $o"
    store_local!(tl, o, b)
end
