# RDF terms for the Function-Graph engine.
#
# Deliberately independent of `Serd.RDF`. Serd's `Literal` has a single `langordt::String`
# field for two mutually exclusive concepts, and its parser never populates it with a
# datatype at all -- `from_serd` maps the datatype IRI to a Julia type and then builds
# `Literal(value)` without it. After parsing, `"42"^^ex:custom` is byte-identical to plain
# `"42"`. That is fine for loading an ontology whose literals are labels and comments; it is
# fatal for a rule engine whose variable marker *is* a datatype (`^^gistp:var`).
#
# The engine therefore never parses RDF. Fuseki parses TriG, and Julia reads SPARQL Results
# JSON, which carries the datatype faithfully. These types are the boundary.
#
# Nothing here calls `makeqname` or touches the global prefix registry: engine terms are
# absolute IRIs and strings, which is what keeps the engine safe to run concurrently.

"""
An RDF term: `IRIRef`, `BNode` or `RDFLiteral`.

Named to avoid collision with `Serd.RDF`'s `Resource`/`Blank`/`Literal`, which are in scope
throughout this package and mean something lossier.
"""
abstract type RDFTerm end

"An absolute IRI. No prefix resolution happens anywhere in the engine."
@auto_hash_equals struct IRIRef <: RDFTerm
    value::String
end

"A blank node, identified by its label within one result set."
@auto_hash_equals struct BNode <: RDFTerm
    id::String
end

const XSD_STRING = "http://www.w3.org/2001/XMLSchema#string"
const RDF_LANGSTRING = "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString"

"""
A literal, carrying lexical form, datatype IRI and language tag as *separate* fields.

Two RDF 1.1 normalisations are applied at construction so that equality means what it
should:

  * a plain literal and one explicitly typed `xsd:string` are the same term, so an
    `xsd:string` datatype is stored as `nothing`;
  * a language-tagged literal always has datatype `rdf:langString`, so the redundant
    datatype is dropped and the language kept.

The lexical form is kept verbatim and is never coerced to a Julia value. `"007"^^xsd:integer`
round-trips as `"007"`, not `7` -- lexical form is what SPARQL matches on.
"""
@auto_hash_equals struct RDFLiteral <: RDFTerm
    lexical::String
    datatype::Union{String,Nothing}
    language::Union{String,Nothing}

    function RDFLiteral(lexical::AbstractString,
                        datatype::Union{AbstractString,Nothing} = nothing,
                        language::Union{AbstractString,Nothing} = nothing)
        lex = String(lexical)
        if language !== nothing && !isempty(language)
            return new(lex, nothing, String(language))
        end
        dt = datatype === nothing || String(datatype) == XSD_STRING ? nothing : String(datatype)
        new(lex, dt, nothing)
    end
end

# ---------------------------------------------------------------------------
# SPARQL Results JSON
# ---------------------------------------------------------------------------

"""
    term_from_json(b::AbstractDict) -> RDFTerm

Build a term from one SPARQL Results JSON binding.

Shapes handled, per the W3C SPARQL 1.1 Query Results JSON Format:

    {"type":"uri",     "value":"http://..."}
    {"type":"bnode",   "value":"b0"}
    {"type":"literal", "value":"42", "datatype":"http://...#integer"}
    {"type":"literal", "value":"hi", "xml:lang":"en"}

`"typed-literal"` is accepted as a synonym for `"literal"`: it is not in the JSON spec, but
it is carried over from the XML results format and some stores still emit it.
"""
function term_from_json(b::AbstractDict)
    typ = get(b, "type", nothing)
    val = get(b, "value", nothing)
    val === nothing && throw(ArgumentError("SPARQL binding has no \"value\": $b"))
    if typ == "uri"
        IRIRef(val)
    elseif typ == "bnode"
        BNode(val)
    elseif typ == "literal" || typ == "typed-literal"
        RDFLiteral(val, get(b, "datatype", nothing), get(b, "xml:lang", nothing))
    else
        throw(ArgumentError("unknown SPARQL binding type $(repr(typ)) in $b"))
    end
end

# ---------------------------------------------------------------------------
# Serialisation back to SPARQL / Turtle surface syntax
# ---------------------------------------------------------------------------

"Escape a lexical form for use inside a double-quoted SPARQL string literal."
function escape_literal(s::AbstractString)
    io = IOBuffer()
    for c in s
        if     c == '\\' ; write(io, "\\\\")
        elseif c == '"'  ; write(io, "\\\"")
        elseif c == '\n' ; write(io, "\\n")
        elseif c == '\r' ; write(io, "\\r")
        elseif c == '\t' ; write(io, "\\t")
        else             ; write(io, c)
        end
    end
    String(take!(io))
end

"""
    sparql_text(t::RDFTerm) -> String

Render a term as SPARQL surface syntax: `<iri>`, `_:label`, `"lex"`, `"lex"@en`,
`"lex"^^<datatype>`.

IRIs are emitted absolute and unabbreviated, so emitted queries never depend on a `PREFIX`
declaration or on the global prefix registry.
"""
sparql_text(t::IRIRef) = string('<', t.value, '>')
sparql_text(t::BNode)  = string("_:", t.id)
function sparql_text(t::RDFLiteral)
    s = string('"', escape_literal(t.lexical), '"')
    t.language !== nothing && return string(s, '@', t.language)
    t.datatype !== nothing && return string(s, "^^<", t.datatype, '>')
    s
end

"RFC 3986 §3.1: a scheme is a letter followed by letters, digits, `+`, `-` or `.`, then `:`."
const ABSOLUTE_IRI_RE = r"^[a-zA-Z][a-zA-Z0-9+.\-]*:"

"""
    check_iri(v) -> v

Reject an IRI the engine cannot emit safely, or one that is not absolute.

Two separate hazards. A character SPARQL forbids inside `<...>` lets a value close its own
brackets and start a new clause. And a *relative* IRI is legal to write but resolves against
whatever base the query happens to carry -- so `GRAPH <../data>` silently addresses a graph
nobody named. The engine works in absolute IRIs throughout, so the second is as much a
correctness problem as the first is a security one.
"""
function check_iri(v::AbstractString)
    bad = findfirst(c -> c in ('<', '>', '"', '{', '}', '|', '^', '`', '\\') || isspace(c), v)
    bad === nothing || throw(ArgumentError(
        "IRI contains a character illegal inside <>: $(repr(v[bad])) in $(repr(String(v)))"))
    occursin(ABSOLUTE_IRI_RE, v) || throw(ArgumentError(
        "$(repr(String(v))) is not an absolute IRI: it has no scheme. A relative reference " *
        "resolves against whatever base the query carries, so it would address something " *
        "nobody named. The engine works in absolute IRIs throughout."))
    v
end

# ---------------------------------------------------------------------------
# Pattern variables
# ---------------------------------------------------------------------------

"Datatype marking a literal-position SPARQL variable in a `gistp:` pattern."
const GISTP_VAR = "https://w3id.org/semanticarts/ns/patterns/gist/var"

# The vocabulary's own XSD facet reads `^[?$][a-zA-Z_]+`, which is wrong twice over: in XSD
# regular expressions `^` and `$` are literal characters rather than anchors (patterns are
# implicitly anchored whole-string), and `[a-zA-Z_]+` rejects the digit in `?_Person_1`.
# gistPatternShapes.ttl has the correct form, and this is it.
const VARIABLE_RE = r"^[?$][a-zA-Z_][a-zA-Z0-9_]*$"

"""
    is_var_literal(t::RDFTerm) -> Bool

True for a literal marked `^^gistp:var` -- a variable occupying a literal position.

Such variables are declared nowhere: they have no individual, no `gistp:variableText`, and
no SHACL shape targets them. Their identity across L and R is string equality of the lexical
form, which is why the compiler must check use-before-def.
"""
is_var_literal(t::RDFLiteral) = t.datatype == GISTP_VAR
is_var_literal(::RDFTerm) = false

"""
    var_name(t) -> String

The SPARQL variable text of a `^^gistp:var` literal, validated against `VARIABLE_RE`.
"""
function var_name(t::RDFLiteral)
    is_var_literal(t) || throw(ArgumentError("not a gistp:var literal: $(sparql_text(t))"))
    occursin(VARIABLE_RE, t.lexical) || throw(ArgumentError(
        "$(repr(t.lexical)) is typed gistp:var but is not a legal SPARQL variable " *
        "(must match $(VARIABLE_RE.pattern))"))
    t.lexical
end

export RDFTerm, IRIRef, BNode, RDFLiteral
export term_from_json, sparql_text, escape_literal, check_iri
export is_var_literal, var_name, GISTP_VAR, VARIABLE_RE, XSD_STRING, ABSOLUTE_IRI_RE
