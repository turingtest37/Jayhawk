"""
Starting point for all calls to rdf_type
"""
function rdf_type(s::Resource, o::Resource, tl::TraceLog)
    @debug "rdf_type($s, $o)"
    oobj = retrieve(tl, o, )
    # `_qname` rather than `makeqname`: the latter throws KeyError for any object in an
    # unregistered namespace, so a single such triple used to die here and be swallowed
    # as a failure by run_data!. `_qname` returns nothing instead.
    #
    # Since resource_dict became URI-keyed this lookup is no longer what rescues the
    # bootstrap owl types -- `retrieve` above now finds them on its own. It still earns
    # its place for a class that was compiled into the module but never `register!`ed
    # into this particular TraceLog.
    objs = _qname(o)
    if objs !== nothing && _defined(@__MODULE__, objs)
        # Was `@eval $objs`. A plain lookup does the same job without invoking the
        # compiler once per rdf:type triple.
        oobj = _lookup(@__MODULE__, objs)
    end
    # sobj = retrieve(tl, s)
    @debug "Calling rdf_type($s, $oobj)..."
    rdf_type(s, oobj, tl)
    if (s == Serd.RDF.Resource("http://www.w3.org/2002/07/owl#TransitiveProperty"))
        error("Can't handle transitive properties. Stopping here.")
    end
end

# The owl:Class / owl:ObjectProperty / owl:DatatypeProperty generators that used to live
# here now produce Exprs in generate.jl instead of calling eval themselves, and the
# schema triples that reached them are consumed by analyze.jl. See src/generate.jl.

# These all take RORB, not Resource.
#
# Every one of the bootstrap structs already declares `uri::RORB`, so a blank subject was
# always representable; only the method signatures excluded it. That did not show up
# while resource_dict was CURIE-keyed, because `retrieve` never resolved these types at
# all and every blank-node typing triple fell into the `o::Unknown` sink instead. Once
# resolution started working, `_:x a owl:Thing` reached dispatch and raised MethodError --
# trading a silent wrong answer for a silent dropped triple, since run_data! catches.
#
# owl:Ontology and owl:Restriction reach here as ordinary data because analyze consumes
# only the class and property declarations. Restrictions are almost always blank nodes:
# 118 of the 170 blank-subject rdf:type triples across the two fixtures.
function rdf_type(s::RORB, ::Type{owl_NamedIndividual}, tl::TraceLog)
    @debug "rdf_type $s Type{owl_NamedIndividual}"
    store_local!(tl, owl_NamedIndividual(s), s)
end

function rdf_type(s::RORB, ::Type{owl_Ontology}, tl::TraceLog)
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

function rdf_type(s::RORB, ::Type{owl_Thing}, tl::TraceLog)
    @debug "rdf_type $s ::owl_Thing"
    store_local!(tl, owl_Thing(s), s)
end

# Typed by a blank node, e.g. `ex:s a _:someAnonClass` -- and, with the RORB subject,
# `_:x a _:y` too, which previously matched no method at all.
function rdf_type(s::RORB, o::Blank, tl::TraceLog)
    @debug "rdf_type $s $o"
    store_local!(tl, o, s)
end

# `owl_Class` had only the Blank form -- which was itself dead while resource_dict was
# CURIE-keyed -- so `ex:s a owl:Class` raised MethodError. It is rare in practice only
# because analyze consumes class declarations before they reach run_data!; a file
# containing `owl:Class a owl:Class` (or any reference analyze does not treat as a
# declaration) reached this and was dropped.
function rdf_type(s::RORB, ::Type{owl_Class}, tl::TraceLog)
    @debug "rdf_type($s , ::owl_Class)"
    store_local!(tl, owl_Class(s), s)
end

function rdf_type(b::Blank, o::Resource, tl::TraceLog)
    @debug "rdf_type $b $o"
    oobj = retrieve(tl, o)
    rdf_type(b, oobj, tl)
end

function rdf_type(b::Blank, o::Unknown, tl::TraceLog)
    @debug "rdf_type $b $o"
    store_local!(tl, o, b)
end
