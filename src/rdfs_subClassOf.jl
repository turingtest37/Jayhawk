function rdfs_subClassOf(s::RORB, o::RORB, tl::TraceLog)
    @debug "rdfs_subClassOf($s, $o)"
    sobj = retrieve!(tl, s)
    oobj = retrieve!(tl, o)
    f = rdfs_subClassOf(sobj, oobj, tl)
end

function rdfs_subClassOf(s::RORB, o, tl::TraceLog)
    @debug "rdfs_subClassOf($s, $o)"
    sobj = retrieve!(tl, s)
    rdfs_subClassOf(sobj, o, tl)
end

function rdfs_subClassOf(s, o::Unknown, tl::TraceLog)
    @debug "rdfs_subClassOf($s, $o)"
end

function rdfs_subClassOf(s, o::RORB, tl::TraceLog)
    @debug "rdfs_subClassOf($s, $o)"
    oobj = retrieve!(tl, o)
    rdfs_subClassOf(s, oobj, tl)
end

function rdfs_subClassOf(s::Unknown, o::Unknown, tl::TraceLog)
    @debug "rdfs_subClassOf($s, $o)"
end

function rdfs_subClassOf(s::Unknown, o, tl::TraceLog)
    @debug "rdfs_subClassOf($s, $o)"
    push!(s.super, o)
end

function rdfs_subClassOf(s, o, tl::TraceLog)
    @debug "rdfs_subClassOf($s, $o)"
    push!(s.super, o)
end

