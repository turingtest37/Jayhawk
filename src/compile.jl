# Pattern -> SPARQL.
#
# The mechanical half of the pattern programme: walk a rule's two named graphs, substitute
# variables, assemble the query text. No judgement, no eval, no globals -- a rule IRI in,
# a string out.
#
# The split below matters. `load_rule` does the I/O and nothing else; `compile_rule` is
# pure, so the interesting half is snapshot-testable against golden files with no server
# running.
#
# Everything is read from the store rather than parsed in Julia. A rule's metadata lives in
# the default graph and its pattern triples live in named graphs, so the compiler's input is
# inherently a *dataset* query -- which a flat Vector{Statement} cannot express, and which
# Serd loses literal datatypes on anyway. Jena parses TriG; Julia reads SPARQL Results JSON.

const GISTP_NS = "https://w3id.org/semanticarts/ns/patterns/gist/"

const P_MATCH        = GISTP_NS * "hasMatchPattern"
const P_CONSTRUCT    = GISTP_NS * "hasConstructPattern"
const P_MODE         = GISTP_NS * "rewriteMode"
const P_VARIABLETEXT = GISTP_NS * "variableText"
const P_IRITEMPLATE  = GISTP_NS * "iriTemplate"
const C_SPARQLVAR    = GISTP_NS * "SparqlVariable"
const C_RULE         = GISTP_NS * "Rule"

const MODE_CONSTRUCT = GISTP_NS * "Construct"
const MODE_ASSERT    = GISTP_NS * "Assert"
const MODE_REWRITE   = GISTP_NS * "Rewrite"

"One triple of a pattern, with terms still un-substituted."
struct PatternTriple
    subject::RDFTerm
    predicate::RDFTerm
    object::RDFTerm
end

"""
Everything the compiler needs about one rule, already fetched.

`variables` maps a variable's IRI to its `gistp:variableText`; `templates` maps it to its
`gistp:iriTemplate` where one is declared. Literal-position variables appear in neither --
they are declared nowhere at all, and are identified only by their `^^gistp:var` datatype
and matched across L and R by string equality of the lexical form.
"""
struct RuleSpec
    iri::String
    mode::String
    match_graph::String
    construct_graph::String
    match::Vector{PatternTriple}
    construct::Vector{PatternTriple}
    variables::Dict{String,String}
    templates::Dict{String,String}
end

mode_symbol(m::AbstractString) =
    m == MODE_CONSTRUCT ? :Construct :
    m == MODE_ASSERT    ? :Assert    :
    m == MODE_REWRITE   ? :Rewrite   :
    throw(ArgumentError("unknown gistp:rewriteMode <$m>"))

mode_symbol(s::RuleSpec) = mode_symbol(s.mode)

# ---------------------------------------------------------------------------
# Reading a rule out of the store
# ---------------------------------------------------------------------------

_iri(t::RDFTerm) = t isa IRIRef ? t.value :
    throw(ArgumentError("expected an IRI, got $(sparql_text(t))"))

"""
    load_rule(rule_iri; ep = endpoint()) -> RuleSpec

Fetch one rule and both of its pattern graphs.

Reads `gistp:hasMatchPattern` / `hasConstructPattern` / `rewriteMode` from the default
graph, then the triples of each named graph. The pattern *is* its graph: a pattern's IRI is
also the IRI of the graph holding its triples, so there is no membership vocabulary and no
predicate blacklist separating payload from metadata.
"""
function load_rule(rule_iri::AbstractString; ep::SparqlEndpoint = endpoint())
    r = check_iri(rule_iri)
    rows = select("""
        SELECT ?mode ?l ?c WHERE {
          <$r> <$P_MATCH>     ?l ;
               <$P_CONSTRUCT> ?c ;
               <$P_MODE>      ?mode .
        }"""; ep = ep)

    isempty(rows) && error(
        "no rule found at <$r>: it must carry gistp:hasMatchPattern, " *
        "gistp:hasConstructPattern and gistp:rewriteMode in the default graph.")
    length(rows) == 1 || error(
        "<$r> has $(length(rows)) match/construct/mode combinations; exactly one is " *
        "required. gistPatternShapes.ttl RuleShape enforces this -- validate first.")

    row  = rows[1]
    mode = _iri(row["mode"])
    lg   = _iri(row["l"])
    cg   = _iri(row["c"])

    RuleSpec(r, mode, lg, cg,
             load_pattern(lg; ep = ep), load_pattern(cg; ep = ep),
             load_variables(; ep = ep), load_templates(; ep = ep))
end

"Fetch the triples of one pattern graph, sorted so output is reproducible."
function load_pattern(graph_iri::AbstractString; ep::SparqlEndpoint = endpoint())
    rows = select("""
        SELECT ?s ?p ?o WHERE { GRAPH <$(check_iri(graph_iri))> { ?s ?p ?o } }"""; ep = ep)
    ts = [PatternTriple(r["s"], r["p"], r["o"]) for r in rows]
    # SPARQL solution order is unspecified. Sorting here is what makes compiled output
    # byte-stable across stores and runs, which is what makes golden-file tests possible.
    sort!(ts; by = t -> (sparql_text(t.subject), sparql_text(t.predicate), sparql_text(t.object)))
end

"Map every declared SparqlVariable IRI to its variableText."
function load_variables(; ep::SparqlEndpoint = endpoint())
    rows = select("""
        SELECT ?v ?t WHERE { ?v a <$C_SPARQLVAR> ; <$P_VARIABLETEXT> ?t . }"""; ep = ep)
    Dict{String,String}(_iri(r["v"]) => (r["t"]::RDFLiteral).lexical for r in rows)
end

"Map every declared SparqlVariable IRI that has one to its iriTemplate."
function load_templates(; ep::SparqlEndpoint = endpoint())
    rows = select("""
        SELECT ?v ?t WHERE { ?v a <$C_SPARQLVAR> ; <$P_IRITEMPLATE> ?t . }"""; ep = ep)
    Dict{String,String}(_iri(r["v"]) => (r["t"]::RDFLiteral).lexical for r in rows)
end

# ---------------------------------------------------------------------------
# Pure: RuleSpec -> SPARQL
# ---------------------------------------------------------------------------

"""
    var_of(t, spec) -> String or nothing

The SPARQL variable a term denotes, or `nothing` if it is a constant.

Two disjoint mechanisms, because the pattern language has two. An IRI-position variable is a
declared individual and is resolved by RDF identity through `spec.variables`. A
literal-position variable has no declaration anywhere and is recognised only by its
`^^gistp:var` datatype. That mirrors the node-versus-attribute split in attributed graph
transformation, so it is sound theory -- but it does mean identity across L and R is IRI
identity in one case and string equality in the other.
"""
function var_of(t::RDFTerm, spec::RuleSpec)
    t isa IRIRef && haskey(spec.variables, t.value) && return spec.variables[t.value]
    t isa RDFLiteral && is_var_literal(t) && return var_name(t)
    nothing
end

"Render one term in a BGP: its variable name if it is one, else its constant syntax."
function term_sparql(t::RDFTerm, spec::RuleSpec)
    v = var_of(t, spec)
    v === nothing || return v
    t isa IRIRef && check_iri(t.value)
    sparql_text(t)
end

"Render a list of pattern triples as a Basic Graph Pattern."
bgp_text(ts::Vector{PatternTriple}, spec::RuleSpec; indent::AbstractString = "  ") =
    join(("$indent$(term_sparql(t.subject, spec)) $(term_sparql(t.predicate, spec)) " *
          "$(term_sparql(t.object, spec)) ." for t in ts), "\n")

"Every distinct SPARQL variable appearing anywhere in a pattern."
function vars_in(ts::Vector{PatternTriple}, spec::RuleSpec)
    s = Set{String}()
    for t in ts, pos in (t.subject, t.predicate, t.object)
        v = var_of(pos, spec)
        v === nothing || push!(s, v)
    end
    s
end

"""
    check_bound(spec)

Reject a rule whose construct pattern uses a variable the match pattern never binds.

This is use-before-def, and it is the failure an LLM author hits most often: literal-position
variables have no declaration and are matched across L and R by string equality, so `?idtext`
in R against `?idText` in L is not a name error anywhere -- it silently compiles to a
CONSTRUCT with an unbound term, which simply produces nothing.

A variable that appears only in R *and* carries a `gistp:iriTemplate` is the minting case.
That is a real construct, but nothing in the vocabulary says where a template's slots get
their values, so it is rejected explicitly rather than mis-compiled.
"""
function check_bound(spec::RuleSpec)
    bound = vars_in(spec.match, spec)
    used  = vars_in(spec.construct, spec)
    free  = setdiff(used, bound)
    isempty(free) && return spec

    # Was the offender a declared variable carrying a template? Then say so precisely.
    minting = String[]
    for (iri, text) in spec.variables
        text in free && haskey(spec.templates, iri) && push!(minting, "$text (<$iri>)")
    end
    if !isempty(minting)
        error("""
              rule <$(spec.iri)>: construct pattern mints $(join(sort(minting), ", ")) via \
              gistp:iriTemplate, but IRI minting is not supported yet -- the vocabulary does \
              not say where a template's slots get their values.""")
    end
    error("""
          rule <$(spec.iri)>: construct pattern uses $(join(sort(collect(free)), ", ")) \
          which the match pattern never binds. Bound by L: \
          $(isempty(bound) ? "(none)" : join(sort(collect(bound)), ", ")). \
          A literal-position variable is matched across L and R by string equality of its \
          lexical form, so check for a typo.""")
end

"""
    compile_rule(spec::RuleSpec) -> String

Emit the SPARQL for a rule. Pure: same spec, same bytes, no server involved.

`Construct` and `Assert` compile to **identical text**. The difference is entirely in the
harness -- whether the result is taken as the answer or unioned back into the source and the
rule applied again. One compiler, two drivers.
"""
function compile_rule(spec::RuleSpec)
    check_bound(spec)
    m = mode_symbol(spec)

    if m === :Rewrite
        error("""
              rule <$(spec.iri)>: gistp:Rewrite is not supported yet. It needs the \
              triple-level interface I = L ∩ R to split DELETE { L∖I } from INSERT { R∖I }, \
              and derived_interface.rq computes shared *variables* rather than shared \
              triples. Use gistp:Assert if the rule only adds facts.""")
    end

    isempty(spec.match) && error("rule <$(spec.iri)>: match pattern <$(spec.match_graph)> is empty.")
    isempty(spec.construct) && error("rule <$(spec.iri)>: construct pattern <$(spec.construct_graph)> is empty.")

    """
    # $(m) rule <$(spec.iri)>
    CONSTRUCT {
    $(bgp_text(spec.construct, spec))
    }
    WHERE {
    $(bgp_text(spec.match, spec))
    }
    """
end

"""
    insert_query(spec; into, from = String[]) -> String

The same rule as a SPARQL Update that writes its result into the named graph `into`.

`from` is the working set the match pattern is evaluated against. Each entry becomes a
`USING` clause, which merges those graphs into the query's default graph for the WHERE --
so a rule can be applied to the union of a base graph and every firing produced so far,
which is what `Assert` to a fixpoint needs. An empty `from` leaves the WHERE reading the
store's own default graph.

The construct and match patterns are the *identical* text `compile_rule` emits; only the
wrapper differs.
"""
function insert_query(spec::RuleSpec; into::AbstractString, from::AbstractVector = String[])
    check_bound(spec)
    mode_symbol(spec) === :Rewrite && error(
        "rule <$(spec.iri)>: gistp:Rewrite is not supported yet; see compile_rule.")
    using_lines = isempty(from) ? "" :
        join(("USING <$(check_iri(g))>" for g in from), "\n") * "\n"
    """
    INSERT {
      GRAPH <$(check_iri(into))> {
    $(bgp_text(spec.construct, spec; indent = "    "))
      }
    }
    $(using_lines)WHERE {
    $(bgp_text(spec.match, spec))
    }
    """
end

"""
    compile(rule_iri; ep = endpoint()) -> String

Fetch and compile in one step. See [`load_rule`](@ref) and [`compile_rule`](@ref).
"""
compile_from_store(rule_iri::AbstractString; ep::SparqlEndpoint = endpoint()) =
    compile_rule(load_rule(rule_iri; ep = ep))

"""
    list_rules(; ep = endpoint()) -> Vector{String}

Every `gistp:Rule` IRI in the store, sorted.
"""
function list_rules(; ep::SparqlEndpoint = endpoint())
    rows = select("SELECT ?r WHERE { ?r a <$C_RULE> } ORDER BY ?r"; ep = ep)
    sort!([_iri(r["r"]) for r in rows])
end

export PatternTriple, RuleSpec, load_rule, load_pattern, load_variables, load_templates
export compile_rule, compile_from_store, insert_query, list_rules, mode_symbol
export var_of, term_sparql, bgp_text, vars_in, check_bound
export GISTP_NS, MODE_CONSTRUCT, MODE_ASSERT, MODE_REWRITE
