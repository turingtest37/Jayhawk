# Phase 1 of three: analyze.
#
# Pure. Walks a parsed RDF statement list and produces a SchemaModel describing what
# needs to exist in Julia. No eval, no TraceLog, no code generation. Splitting this out
# is what lets a set of RDF be compiled once and then merely executed on later runs.

# Vocabulary used to classify statements.
const A_RDF_TYPE      = Resource("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
const A_RDFS_DOMAIN   = Resource("http://www.w3.org/2000/01/rdf-schema#domain")
const A_RDFS_RANGE    = Resource("http://www.w3.org/2000/01/rdf-schema#range")
const A_RDFS_SUBCLASS = Resource("http://www.w3.org/2000/01/rdf-schema#subClassOf")
const A_OWL_CLASS     = Resource("http://www.w3.org/2002/07/owl#Class")
const A_RDFS_CLASS    = Resource("http://www.w3.org/2000/01/rdf-schema#Class")
const A_OWL_OBJPROP   = Resource("http://www.w3.org/2002/07/owl#ObjectProperty")
const A_OWL_DATAPROP  = Resource("http://www.w3.org/2002/07/owl#DatatypeProperty")
const A_OWL_ANNPROP   = Resource("http://www.w3.org/2002/07/owl#AnnotationProperty")

"""
What a single RDF property needs to become in Julia.

`kind` is `:object`, `:datatype` or `:annotation` when there is an explicit rdf:type, and
`:inferred_obj` / `:inferred_data` when the property was only ever seen in use.
`domain`/`range` come from rdfs:domain / rdfs:range when declared.
"""
mutable struct PropertySpec
    uri::Resource
    name::Symbol
    kind::Symbol
    domain::Union{Resource,Nothing}
    range::Union{Resource,Nothing}
end
PropertySpec(uri::RORB, name::Symbol, kind::Symbol) = PropertySpec(uri, name, kind, nothing, nothing)

"""
What a single owl:Class / rdfs:Class needs to become in Julia.
"""
mutable struct ClassSpec
    uri::Resource
    name::Symbol
    supers::Vector{Resource}
end
ClassSpec(uri::RORB, name::Symbol) = ClassSpec(uri, name, Resource[])

"""
The complete result of analysis: the T-Box as data, plus the A-Box triples that should
be executed against the generated code.
"""
struct SchemaModel
    classes::Dict{Resource,ClassSpec}
    properties::Dict{Resource,PropertySpec}
    prefixes::Vector{Prefix}
    base::Union{BaseURI,Nothing}
    data::Vector{Triple}
    unnamed::Vector{Resource}   # terms with no registered prefix; skipped, not fatal
end
SchemaModel() = SchemaModel(Dict{Resource,ClassSpec}(), Dict{Resource,PropertySpec}(),
                            Prefix[], nothing, Triple[], Resource[])

"""
Name a term, or `nothing` when its namespace has no registered prefix.

`makeqname` throws for an unregistered prefix, and real ontologies routinely contain a
few bare IRIs (their own ontology IRI, owl:imports targets). One unnameable term must
not abort analysis of the whole file, so those terms are recorded and skipped.
"""
function _qname(x)
    try
        Symbol(makeqname(x))
    catch
        nothing
    end
end

function _ensure_class!(m::SchemaModel, uri::Resource)
    haskey(m.classes, uri) && return m.classes[uri]
    nm = _qname(uri)
    nm === nothing && (push!(m.unnamed, uri); return nothing)
    m.classes[uri] = ClassSpec(uri, nm)
end

function _ensure_prop!(m::SchemaModel, uri::Resource, kind::Symbol)
    spec = get(m.properties, uri, nothing)
    if spec === nothing
        nm = _qname(uri)
        nm === nothing && (push!(m.unnamed, uri); return nothing)
        spec = m.properties[uri] = PropertySpec(uri, nm, kind)
    end
    # An explicit rdf:type always beats a kind guessed from usage.
    if _is_inferred(spec.kind) && !_is_inferred(kind)
        spec.kind = kind
    end
    spec
end

_is_inferred(kind::Symbol) = kind === :inferred_obj || kind === :inferred_data

"""
    analyze(stmts) -> SchemaModel

Classify a parsed statement list into schema (classes, properties) and data.

Prefixes are registered in a first sweep so that `makeqname` resolves regardless of
where a prefix declaration appears relative to the triples that use it — the previous
per-triple walk depended on parse order.
"""
function analyze(stmts)
    all = collect(stmts)
    m = SchemaModel()
    base = nothing

    for s in all
        if s isa Prefix
            add_prefix!(s.name, s.uri)
            push!(m.prefixes, s)
        elseif s isa BaseURI
            add_prefix!("", s.uri)
            base = s
        end
    end

    for st in all
        st isa Triple || continue
        s, p, o = st.subject, st.predicate, st.object

        if p == A_RDF_TYPE && o isa Resource
            if (o == A_OWL_CLASS || o == A_RDFS_CLASS) && s isa Resource
                _ensure_class!(m, s)
                continue
            elseif o == A_OWL_OBJPROP && s isa Resource
                _ensure_prop!(m, s, :object); continue
            elseif o == A_OWL_DATAPROP && s isa Resource
                _ensure_prop!(m, s, :datatype); continue
            elseif o == A_OWL_ANNPROP && s isa Resource
                _ensure_prop!(m, s, :annotation); continue
            end
            # Any other rdf:type is instance typing -- that is data.
            push!(m.data, st)
            continue
        end

        # Schema facts that also stay in the data stream, so that the hand-written
        # rdfs_subClassOf / generic property paths keep behaving as they did before.
        if p == A_RDFS_SUBCLASS && s isa Resource && o isa Resource
            c = _ensure_class!(m, s)
            c === nothing || push!(c.supers, o)
        elseif p == A_RDFS_DOMAIN && s isa Resource && o isa Resource
            sp = _ensure_prop!(m, s, :inferred_obj)
            sp === nothing || (sp.domain = o)
        elseif p == A_RDFS_RANGE && s isa Resource && o isa Resource
            sp = _ensure_prop!(m, s, :inferred_obj)
            sp === nothing || (sp.range = o)
        end

        # Every remaining predicate is itself a property that needs a function, and the
        # triple is data to run through it.
        _ensure_prop!(m, p, o isa Literal ? :inferred_data : :inferred_obj)
        push!(m.data, st)
    end

    isempty(m.unnamed) ||
        @debug "analyze: $(length(unique(m.unnamed))) term(s) had no registered prefix and were skipped."

    SchemaModel(m.classes, m.properties, m.prefixes, base, m.data, m.unnamed)
end

export analyze, SchemaModel, ClassSpec, PropertySpec
