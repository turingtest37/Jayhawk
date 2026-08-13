# Record that one class is a subclass of another.
#
# This file used to carry seven overlapping two-argument methods, two combinations of
# which were ambiguous and threw rather than dispatching: `(Unknown, Resource)` matched
# both `(s, o::RORB)` and `(s::Unknown, o)`, and `(Resource, Unknown)` matched both
# `(s::RORB, o)` and `(s, o::Unknown)`. Nothing hit them in practice only because the
# RORB entry point resolved both terms before recursing.
#
# Only the subject needs resolving -- we need its `super` vector. The object is recorded
# as the URI it is, not as whatever it has been realised into: `super` is declared
# `Vector{Resource}`, so pushing a resolved class (a Julia DataType) into it could never
# have worked either.

rdfs_subClassOf(s::RORB, o, tl::TraceLog) = _record_subclass(retrieve!(tl, s), o, tl)
rdfs_subClassOf(s, o, tl::TraceLog) = _record_subclass(s, o, tl)

function _record_subclass(s, o, tl::TraceLog)
    @debug "rdfs_subClassOf" s o

    # A class that has already been realised arrives as a Julia DataType, and DataType
    # has a `super` field of its own -- so this used to resolve to `push!(Any, o)` and
    # throw. A concrete struct cannot gain a supertype after it is defined; analyze
    # records subclass edges in SchemaModel.classes[...].supers, which is where they
    # belong. (A `hasfield` guard would not catch this: DataType really does have the
    # field.)
    s isa Type && return nothing

    hasfield(typeof(s), :super) || return nothing
    o isa Resource && push!(s.super, o)
    nothing
end
