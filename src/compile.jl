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
const P_HASSLOT      = GISTP_NS * "hasSlot"
const P_SLOTNAME     = GISTP_NS * "slotName"
const P_SLOTVALUE    = GISTP_NS * "slotValue"
const P_ONEOF        = GISTP_NS * "oneOf"
const P_NAC          = GISTP_NS * "hasNegativeCondition"
const P_INGRAPH      = GISTP_NS * "inGraph"

const RDF_FIRST = "http://www.w3.org/1999/02/22-rdf-syntax-ns#first"
const RDF_REST  = "http://www.w3.org/1999/02/22-rdf-syntax-ns#rest"
const P_STRATEGY     = GISTP_NS * "strategy"
const P_PRIORITY     = GISTP_NS * "priority"
const P_MAXITER      = GISTP_NS * "maxIterations"
const C_SPARQLVAR    = GISTP_NS * "SparqlVariable"
const C_RULE         = GISTP_NS * "Rule"

const MODE_CONSTRUCT = GISTP_NS * "Construct"
const MODE_ASSERT    = GISTP_NS * "Assert"
const MODE_REWRITE   = GISTP_NS * "Rewrite"

const STRATEGY_ONCE       = GISTP_NS * "Once"
const STRATEGY_TOFIXPOINT = GISTP_NS * "ToFixpoint"

strategy_symbol(s::AbstractString) =
    s == STRATEGY_ONCE       ? :Once :
    s == STRATEGY_TOFIXPOINT ? :ToFixpoint :
    throw(ArgumentError("unknown gistp:strategy <$s>"))

"One triple of a pattern, with terms still un-substituted."
struct PatternTriple
    subject::RDFTerm
    predicate::RDFTerm
    object::RDFTerm
end

"""
How one minted variable's IRI is constructed.

Carrying a `gistp:iriTemplate` is what makes a variable **minted** rather than matched, so
this is the role marker as well as the recipe. `slots` maps each `{name}` in the template to
the variable supplying its value -- by RDF identity, never by matching the template text
against a variable's name.
"""
struct MintSpec
    variable::String                # IRI of the minted SparqlVariable
    template::String                # RFC 6570 Level 1, expanding to an absolute IRI
    slots::Dict{String,RDFTerm}     # slotName => the term naming the supplying variable
end

"""
A negative application condition: a pattern that must **not** match for the rule to fire.

Its own named graph, like L and R, and compiled to its own `FILTER NOT EXISTS`.
"""
struct NacSpec
    graph::String
    triples::Vector{PatternTriple}
    # gistp:inGraph, if the condition is scoped: the IRI of a graph variable or of a constant
    # graph. A guard scoped to the same variable as L reads "no such thing in THIS graph".
    scope::Union{String,Nothing}
end

NacSpec(graph, triples) = NacSpec(graph, triples, nothing)

"""
Everything the compiler needs about one rule, already fetched.

`variables` maps a variable's IRI to its `gistp:variableText`. `mints` holds the minted
variables, keyed by the same IRI. Literal-position variables appear in neither -- they are
declared nowhere at all, and are identified only by their `^^gistp:var` datatype and matched
across L and R by string equality of the lexical form.
"""
struct RuleSpec
    iri::String
    mode::String
    match_graph::String
    construct_graph::String
    match::Vector{PatternTriple}
    construct::Vector{PatternTriple}
    variables::Dict{String,String}
    mints::Dict{String,MintSpec}
    # variable IRI => the values gistp:oneOf allows it to take. Compilation input, like
    # `mints`: it becomes a VALUES clause.
    enums::Dict{String,Vector{RDFTerm}}
    # Control. `nacs` affects compilation; the other three are execution policy the driver
    # reads, kept here because `load_rule` is the one place that talks to the store.
    nacs::Vector{NacSpec}
    strategy::Union{Symbol,Nothing}     # :Once, :ToFixpoint, or unstated
    priority::Int
    max_iterations::Union{Int,Nothing}  # unstated means the caller's default
    # gistp:inGraph on L and on R: the IRI of a graph variable or of a constant graph, or
    # `nothing` for the graph-blind reading every rule had before named graphs. Scope is a
    # property of the *pattern*, not of a triple -- TriG cannot nest a GRAPH inside a graph,
    # so a per-triple graph term would have to be reified inside the pattern.
    match_scope::Union{String,Nothing}
    construct_scope::Union{String,Nothing}
end

# Every call site written before the control layer stays valid: a rule with no negative
# conditions and no stated policy behaves exactly as it did.
RuleSpec(iri, mode, lg, cg, match, construct, variables, mints) =
    RuleSpec(iri, mode, lg, cg, match, construct, variables, mints,
             Dict{String,Vector{RDFTerm}}(), NacSpec[], nothing, 0, nothing, nothing, nothing)

RuleSpec(iri, mode, lg, cg, match, construct, variables, mints,
         nacs, strategy, priority, maxit) =
    RuleSpec(iri, mode, lg, cg, match, construct, variables, mints,
             Dict{String,Vector{RDFTerm}}(), nacs, strategy, priority, maxit, nothing, nothing)

RuleSpec(iri, mode, lg, cg, match, construct, variables, mints,
         enums, nacs, strategy, priority, maxit) =
    RuleSpec(iri, mode, lg, cg, match, construct, variables, mints,
             enums, nacs, strategy, priority, maxit, nothing, nothing)

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

    nacs = [NacSpec(g, load_pattern(g; ep = ep), load_in_graph(g; ep = ep))
            for g in load_nac_graphs(r; ep = ep)]
    # The negative conditions' graphs join the scoping set: a variable may appear ONLY
    # inside a condition -- that is the existentially-quantified case -- and without this it
    # would be loaded as no variable at all and emitted as a bare IRI.
    graphs = String[lg, cg, (n.graph for n in nacs)...]

    RuleSpec(r, mode, lg, cg,
             load_pattern(lg; ep = ep), load_pattern(cg; ep = ep),
             load_variables(graphs; ep = ep), load_mints(graphs; ep = ep),
             load_enums(graphs; ep = ep),
             nacs, load_strategy(r; ep = ep), load_priority(r; ep = ep),
             load_max_iterations(r; ep = ep),
             load_in_graph(lg; ep = ep), load_in_graph(cg; ep = ep))
end

"""
    load_enums(graphs; ep = endpoint()) -> Dict{String,Vector{RDFTerm}}

Every enumerated variable *occurring in `graphs`*, with the values `gistp:oneOf` allows it.

`gistp:oneOf` points at an `rdf:List`, walked here with a property path. The members come
back sorted rather than in list order: `VALUES` is a set of solutions, so authored order has
no semantics, and sorting is what keeps compiled output byte-stable.
"""
function load_enums(graphs::AbstractVector; ep::SparqlEndpoint = endpoint())
    rows = select("""
        SELECT DISTINCT ?v ?val WHERE {
          ?v a <$C_SPARQLVAR> ;
             <$P_ONEOF>/<$RDF_REST>*/<$RDF_FIRST> ?val .
          $(_occurs_in(graphs))
        }"""; ep = ep)
    # Declared enumerations are collected separately from their members, so an empty list
    # is distinguishable from no list at all. gistp:oneOf () is rdf:nil: the property path
    # below matches nothing, and without this the variable would come back merely
    # un-enumerated and be diagnosed later as an unbound variable -- pointing the author at
    # a typo rather than at the truncated list they actually wrote.
    declared = select("""
        SELECT DISTINCT ?v WHERE {
          ?v a <$C_SPARQLVAR> ; <$P_ONEOF> ?list .
          $(_occurs_in(graphs))
        }"""; ep = ep)
    out = Dict{String,Vector{RDFTerm}}(_iri(r["v"]) => RDFTerm[] for r in declared)
    for r in rows
        push!(get!(out, _iri(r["v"]), RDFTerm[]), r["val"])
    end
    for vs in values(out)
        sort!(vs; by = sparql_text)
        unique!(vs)
    end
    out
end

"The negative-condition graph IRIs of one rule, sorted so compiled output is stable."
function load_nac_graphs(rule_iri::AbstractString; ep::SparqlEndpoint = endpoint())
    rows = select("""
        SELECT ?n WHERE { <$(check_iri(rule_iri))> <$P_NAC> ?n } ORDER BY ?n"""; ep = ep)
    sort!([_iri(r["n"]) for r in rows])
end

"A rule's declared application strategy, or `nothing` if it states none."
function load_strategy(rule_iri::AbstractString; ep::SparqlEndpoint = endpoint())
    rows = select("SELECT ?s WHERE { <$(check_iri(rule_iri))> <$P_STRATEGY> ?s }"; ep = ep)
    isempty(rows) && return nothing
    length(rows) == 1 || error(
        "<$rule_iri> declares $(length(rows)) gistp:strategy values; at most one is allowed.")
    strategy_symbol(_iri(rows[1]["s"]))
end

"A rule's ordering hint when several are applied as a set. Absent means 0."
function load_priority(rule_iri::AbstractString; ep::SparqlEndpoint = endpoint())
    rows = select("SELECT ?p WHERE { <$(check_iri(rule_iri))> <$P_PRIORITY> ?p }"; ep = ep)
    isempty(rows) ? 0 : parse(Int, (rows[1]["p"]::RDFLiteral).lexical)
end

"A rule's own fixpoint budget, or `nothing` to use the caller's."
function load_max_iterations(rule_iri::AbstractString; ep::SparqlEndpoint = endpoint())
    rows = select("SELECT ?m WHERE { <$(check_iri(rule_iri))> <$P_MAXITER> ?m }"; ep = ep)
    isempty(rows) && return nothing
    n = parse(Int, (rows[1]["m"]::RDFLiteral).lexical)
    n >= 1 || error(
        "<$rule_iri>: gistp:maxIterations is $n. A budget below 1 cannot be satisfied by " *
        "any run; gistPatternShapes.ttl RuleShape rejects it -- validate first.")
    n
end

"""
    load_in_graph(pattern_iri; ep = endpoint()) -> Union{String,Nothing}

The `gistp:inGraph` of one pattern: the IRI of a graph variable or of a constant graph.

Unlike a pattern's triples, this lives in the **default** graph -- it is a statement *about*
the pattern, not part of it -- which is why it needs its own query and why the variable it
names has to be fed to [`load_variables`](@ref) explicitly. See [`_occurs_in`](@ref).
"""
function load_in_graph(pattern_iri::AbstractString; ep::SparqlEndpoint = endpoint())
    rows = select(
        "SELECT ?g WHERE { <$(check_iri(pattern_iri))> <$P_INGRAPH> ?g }"; ep = ep)
    isempty(rows) && return nothing
    length(rows) == 1 || error(
        "pattern <$pattern_iri> declares $(length(rows)) gistp:inGraph values; at most one " *
        "is allowed. A pattern is evaluated in one graph. gistPatternShapes.ttl " *
        "SparqlPatternShape enforces this -- validate first.")
    g = rows[1]["g"]
    g isa IRIRef || error(
        "pattern <$pattern_iri>: gistp:inGraph is $(sparql_text(g)), which is not an IRI. " *
        "A graph name is an IRI -- either a declared gistp:SparqlVariable or a constant " *
        "graph. No literal can name a graph, so there is no \"?g\"^^gistp:var reading here " *
        "as there is for gistp:slotValue.")
    check_iri(g.value)
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

"""
    _occurs_in(graphs) -> String

A SPARQL group matching when `?v` occupies *any* position in *any* of `graphs`.

This is what scopes a rule's declarations to that rule. A variable is an ordinary IRI that
happens to be declared a `gistp:SparqlVariable`, so it can appear as subject, predicate or
object; all three have to be looked for, and the position variables are suffixed per graph
so two alternatives never accidentally share one.

**A fourth position, off to one side.** A *graph* variable occupies no position inside any
pattern graph: it is named by `<pattern> gistp:inGraph <var>` in the **default** graph. Left
to the three alternatives above it would never be discovered, `var_of` would return nothing,
and [`term_sparql`](@ref) would emit it as a bare IRI -- `GRAPH <…:_Book>`, a constant naming
a graph nobody created. The rule would compile, validate, run, and match nothing, with no
error anywhere. The last alternative below is what stops that.
"""
_occurs_in(graphs) = string(
    join(("{ GRAPH <$(check_iri(g))> { { ?v ?p$i ?o$i } UNION { ?s$i ?v ?o$i } " *
          "UNION { ?s$i ?p$i ?v } } }" for (i, g) in enumerate(graphs)),
         "\n          UNION "),
    isempty(graphs) ? "" :
    "\n          UNION { VALUES ?pat { " *
    join(("<$(check_iri(g))>" for g in graphs), " ") *
    " } ?pat <$P_INGRAPH> ?v }")

"""
    load_variables(graphs; ep = endpoint()) -> Dict{String,String}

Map each SparqlVariable IRI *occurring in `graphs`* to its `gistp:variableText`.

**Scoped to the rule, deliberately.** This used to select every `gistp:SparqlVariable` in
the dataset and staple the lot onto whichever `RuleSpec` was being built, which broke the
moment a store held more than one rule -- and a catalogue of rules is the entire point of
`mcp.jl`. Two rules were enough: [`check_mints`](@ref) would validate a *foreign* rule's
mint against this rule's match pattern and refuse to compile, or -- when the names happened
to line up -- [`binds_text`](@ref) would silently emit the other rule's `BIND` into this
rule's query, so the thing that executed was not the thing anyone reviewed.

A variable's declarations live in the default graph; its *occurrences* are what the two
pattern graphs record, and occurrence is what membership of a rule means.
"""
function load_variables(graphs::AbstractVector; ep::SparqlEndpoint = endpoint())
    rows = select("""
        SELECT DISTINCT ?v ?t WHERE {
          ?v a <$C_SPARQLVAR> ; <$P_VARIABLETEXT> ?t .
          $(_occurs_in(graphs))
        }"""; ep = ep)
    Dict{String,String}(_iri(r["v"]) => (r["t"]::RDFLiteral).lexical for r in rows)
end

"""
    load_mints(graphs; ep = endpoint()) -> Dict{String,MintSpec}

Every minted variable *occurring in `graphs`*: its template and its slot bindings.

One row per slot, grouped here by variable. Scoped exactly as [`load_variables`](@ref) is,
and for the same reason.

Occurrence in the rule's own graphs is sufficient: a minted variable has to appear in R --
that is what constructing it means -- and [`check_mints`](@ref) separately requires every
`gistp:slotValue` to be a variable the match pattern binds, so a slot's supplying variable
is always in L.

That used to end "nothing the compiler needs is reachable only from the default graph". A
*graph* variable is: `gistp:inGraph` is a statement about the pattern, so it sits in the
default graph and its object occupies no position inside any pattern. [`_occurs_in`](@ref)
carries a fourth alternative for exactly that case.
"""
function load_mints(graphs::AbstractVector; ep::SparqlEndpoint = endpoint())
    rows = select("""
        SELECT DISTINCT ?v ?tmpl ?name ?value WHERE {
          ?v a <$C_SPARQLVAR> ; <$P_IRITEMPLATE> ?tmpl .
          $(_occurs_in(graphs))
          OPTIONAL { ?v <$P_HASSLOT> ?slot .
                     ?slot <$P_SLOTNAME> ?name ; <$P_SLOTVALUE> ?value . }
        }"""; ep = ep)
    out = Dict{String,MintSpec}()
    for r in rows
        v = _iri(r["v"])
        m = get!(out, v) do
            MintSpec(v, (r["tmpl"]::RDFLiteral).lexical, Dict{String,RDFTerm}())
        end
        haskey(r, "name") && haskey(r, "value") &&
            (m.slots[(r["name"]::RDFLiteral).lexical] = r["value"])
    end
    out
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
function bgp_text(ts::Vector{PatternTriple}, spec::RuleSpec; indent::AbstractString = "  ")
    # Sorted HERE, not only in load_pattern. "Same spec, same bytes" has to hold for every
    # RuleSpec however it was built -- including one an MCP client hands in -- and a BGP is
    # a set, so the order it was written in carries no meaning to preserve.
    lines = ("$indent$(term_sparql(t.subject, spec)) $(term_sparql(t.predicate, spec)) " *
             "$(term_sparql(t.object, spec)) ." for t in ts)
    join(sort(collect(lines)), "\n")
end

"Every distinct SPARQL variable appearing anywhere in a pattern."
function vars_in(ts::Vector{PatternTriple}, spec::RuleSpec)
    s = Set{String}()
    for t in ts, pos in (t.subject, t.predicate, t.object)
        v = var_of(pos, spec)
        v === nothing || push!(s, v)
    end
    s
end

# ---------------------------------------------------------------------------
# RFC 6570 Level 1 templates
# ---------------------------------------------------------------------------

"""
    parse_template(t) -> Vector{Tuple{Symbol,String}}

Split an RFC 6570 Level 1 template into `(:lit, text)` and `(:slot, name)` pieces.

Level 1 only. Level 2 reserved expansion (`{+name}`) and every higher-level operator
(`{#}`, `{.}`, `{/}`, `{;}`, `{?}`, `{&}`) are refused rather than approximated: SPARQL's
`STR()` alone is *more* permissive than Level 2 actually specifies -- it leaves spaces and
angle brackets unencoded -- and shipping that under the RFC's name would be worse than
implementing half of it and saying so.
"""
function parse_template(t::AbstractString)
    parts = Tuple{Symbol,String}[]
    buf = IOBuffer()
    i = firstindex(t)
    while i <= lastindex(t)
        c = t[i]
        if c == '{'
            close_at = findnext(==('}'), t, i)
            close_at === nothing && throw(ArgumentError(
                "unterminated '{' in iriTemplate $(repr(String(t)))"))
            name = t[nextind(t, i):prevind(t, close_at)]
            isempty(name) && throw(ArgumentError(
                "empty {} expression in iriTemplate $(repr(String(t)))"))
            if !occursin(r"^[a-zA-Z_][a-zA-Z0-9_]*$", name)
                op = first(name)
                op in ('+', '#', '.', '/', ';', '?', '&') && throw(ArgumentError(
                    "iriTemplate $(repr(String(t))) uses the RFC 6570 operator '$op' in " *
                    "{$name}. Only Level 1 ({name}) is supported: Level 2 reserved " *
                    "expansion would need an encoding SPARQL cannot express exactly."))
                throw(ArgumentError(
                    "{$name} is not a legal RFC 6570 Level 1 expression in iriTemplate " *
                    "$(repr(String(t)))"))
            end
            lit = String(take!(buf))
            isempty(lit) || push!(parts, (:lit, lit))
            push!(parts, (:slot, name))
            i = nextind(t, close_at)
        elseif c == '}'
            throw(ArgumentError("unmatched '}' in iriTemplate $(repr(String(t)))"))
        else
            write(buf, c)
            i = nextind(t, i)
        end
    end
    lit = String(take!(buf))
    isempty(lit) || push!(parts, (:lit, lit))
    parts
end

"Slot names appearing in a template, in order of first occurrence."
template_slots(t::AbstractString) = [n for (k, n) in parse_template(t) if k === :slot]

# ENCODE_FOR_URI escapes everything outside RFC 3986's unreserved set, and leaves these
# alone. A template separator built only from these characters is therefore
# indistinguishable from the same characters appearing inside a slot value.
const UNRESERVED_ONLY = r"^[A-Za-z0-9\-._~]*$"

"""
    ambiguous_separators(t) -> Vector{String}

The literal separators between consecutive slots that cannot be told apart from slot content.

Two distinct binding tuples must never expand to one IRI: in RDF an IRI *is* the identity, so
a collision silently merges two things into one node. `ENCODE_FOR_URI` is injective, so a
single-slot template is always safe -- but a multi-slot template is only safe if each
separator contains at least one character the encoder escapes:

    {a}_{b}   "x_y" + "z"  ->  x_y_z        <- and so does "x" + "y_z"
    {a}/{b}   "x/y" + "z"  ->  x%2Fy/z      <- distinct from x/y%2Fz

An empty separator (two adjacent slots) is always ambiguous, so it is reported too. Only
*inter-slot* text matters: a fixed prefix or suffix is the same for every binding and cannot
create a collision.
"""
function ambiguous_separators(t::AbstractString)
    parts = parse_template(t)
    bad = String[]
    for i in 1:length(parts)-1
        parts[i][1] === :slot || continue
        if parts[i+1][1] === :slot
            push!(bad, "")                                  # {a}{b}
        elseif i + 2 <= length(parts) && parts[i+2][1] === :slot
            sep = parts[i+1][2]
            occursin(UNRESERVED_ONLY, sep) && push!(bad, sep)
        end
    end
    bad
end

"""
    check_mints(spec)

Validate every minted variable against its template, its slots, and the match pattern.

Five ways a mint can be wrong, each with its own message:

  * the template is relative, so the minting namespace is implicit — this is what made
    `":_Employee_{person_id}"` mint into the *rules* namespace;
  * a `{slot}` in the template has no binding, so it cannot be expanded;
  * a binding names a slot the template does not contain, usually a rename that got half
    applied;
  * a slot's value is a variable the match pattern never binds;
  * the minted variable itself appears in L. Carrying a template *declares* a variable
    constructed, so being matched as well is a contradiction — and it is the exact shape of
    the dead template that used to sit on `:_Person_1`.
"""
function check_mints(spec::RuleSpec)
    # Enumerated variables count as bound: VALUES precedes the BINDs, so a template may mint
    # from an enumerated value. That is generation of minted nodes -- one per value.
    bound = union(vars_in(spec.match, spec), enum_vars(spec))
    for (iri, m) in spec.mints
        text = get(spec.variables, iri, nothing)
        text === nothing && error(
            "rule <$(spec.iri)>: minted variable <$iri> has a gistp:iriTemplate but no " *
            "gistp:variableText, so there is no SPARQL variable to bind it to.")

        occursin(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", m.template) || error(
            "rule <$(spec.iri)>: iriTemplate $(repr(m.template)) on <$iri> is relative. A " *
            "template expands to an absolute IRI; a bare local part leaves the minting " *
            "namespace implicit, which silently mints into whichever namespace the rule " *
            "document's empty prefix happens to name.")

        wanted_now = template_slots(m.template)
        isempty(wanted_now) && error(
            "rule <$(spec.iri)>: iriTemplate $(repr(m.template)) on <$iri> has no {slot}, " *
            "so it expands to the same IRI for every match and collapses every solution " *
            "onto one node. If a single fixed node is what you want, write that IRI " *
            "directly in the construct pattern -- a template with nothing to substitute " *
            "buys nothing and reads as a mistake.")

        amb = ambiguous_separators(m.template)
        isempty(amb) || error(
            "rule <$(spec.iri)>: iriTemplate $(repr(m.template)) on <$iri> separates slots " *
            "with $(join((isempty(s) ? "nothing at all" : repr(s) for s in amb), ", ")). " *
            "ENCODE_FOR_URI leaves the unreserved characters -._~ and alphanumerics alone, " *
            "so such a separator cannot be told apart from the same characters inside a " *
            "value: \"x_y\"+\"z\" and \"x\"+\"y_z\" both expand to x_y_z, silently merging " *
            "two different things into one node. Separate slots with a character the " *
            "encoder escapes, such as '/'.")

        wanted = Set(template_slots(m.template))
        given  = Set(keys(m.slots))
        missing_slots = setdiff(wanted, given)
        isempty(missing_slots) || error(
            "rule <$(spec.iri)>: iriTemplate $(repr(m.template)) on <$iri> has no binding " *
            "for $(join(("{$s}" for s in sort(collect(missing_slots))), ", ")). Add a " *
            "gistp:hasSlot with that gistp:slotName.")
        extra = setdiff(given, wanted)
        isempty(extra) || error(
            "rule <$(spec.iri)>: <$iri> binds slot(s) $(join(sort(collect(extra)), ", ")) " *
            "that iriTemplate $(repr(m.template)) does not contain.")

        for name in sort(collect(wanted))
            v = var_of(m.slots[name], spec)
            v === nothing && error(
                "rule <$(spec.iri)>: slot {$name} of <$iri> is bound to " *
                "$(sparql_text(m.slots[name])), which is not a variable. A gistp:slotValue " *
                "must be a declared gistp:SparqlVariable or a literal typed gistp:var.")
            v in bound || error(
                "rule <$(spec.iri)>: slot {$name} of <$iri> is bound to $v, which the match " *
                "pattern never binds. Minting from another minted variable is not supported.")
        end

        text in bound && error(
            "rule <$(spec.iri)>: <$iri> carries a gistp:iriTemplate, which declares it " *
            "minted, but the match pattern also binds $text. A variable is either " *
            "constructed or matched, not both -- if L already binds it, R reuses the " *
            "matched IRI and the template is dead. Remove one.")
    end
    spec
end

"The SPARQL variable names produced by minting."
minted_vars(spec::RuleSpec) =
    Set(spec.variables[iri] for iri in keys(spec.mints) if haskey(spec.variables, iri))

"""
    bind_text(m::MintSpec, spec) -> String

The `BIND` clause that mints one IRI.

RFC 6570 Level 1 expansion is exactly SPARQL's `ENCODE_FOR_URI`: percent-encode everything
outside RFC 3986's unreserved set. So there is no template engine here — the store expands
the template, and `CONCAT`/`ENCODE_FOR_URI`/`IRI` being pure is precisely what makes a
minting rule idempotent and an `Assert` fixpoint converge.
"""
function bind_text(m::MintSpec, spec::RuleSpec)
    pieces = String[]
    for (kind, val) in parse_template(m.template)
        if kind === :lit
            push!(pieces, "\"$(escape_literal(val))\"")
        else
            push!(pieces, "ENCODE_FOR_URI(STR($(var_of(m.slots[val], spec))))")
        end
    end
    "  BIND(IRI(CONCAT($(join(pieces, ", ")))) AS $(spec.variables[m.variable]))"
end

"Every BIND a rule needs, ordered by variable name so output stays byte-stable."
function binds_text(spec::RuleSpec)
    isempty(spec.mints) && return ""
    lines = [bind_text(spec.mints[iri], spec) for iri in sort(collect(keys(spec.mints)))]
    "\n" * join(lines, "\n")
end

"""
    nacs_text(spec) -> String

Every negative application condition, as its own `FILTER NOT EXISTS` block.

Several conditions are conjunctive: each must fail to match independently, which is what
separate filters give. An empty condition is skipped rather than emitted as
`FILTER NOT EXISTS { }` -- a filter that can never fail would silently disable the rule.
"""
function nacs_text(spec::RuleSpec)
    blocks = String[]
    for n in spec.nacs
        isempty(n.triples) && continue
        # A scoped condition wraps its own triples, *inside* its own filter. It must not be
        # nested in L's GRAPH group -- see `where_body`.
        body = n.scope === nothing ?
            bgp_text(n.triples, spec; indent = "    ") :
            graph_wrap(bgp_text(n.triples, spec; indent = "      "),
                       n.scope, spec; indent = "    ")
        push!(blocks, "  # NOT <$(n.graph)>\n  FILTER NOT EXISTS {\n" * body * "\n  }")
    end
    isempty(blocks) ? "" : "\n" * join(blocks, "\n")
end

"""
    is_scoped(spec) -> Bool

Whether any of a rule's patterns names a graph. Decides the shape of the dataset clause.
"""
is_scoped(spec::RuleSpec) =
    spec.match_scope !== nothing || spec.construct_scope !== nothing ||
    any(n.scope !== nothing for n in spec.nacs)

"""
    dataset_lines(spec, from; keyword = "USING") -> String

The dataset clause: `USING`/`USING NAMED` for an update, `FROM`/`FROM NAMED` for a select.

**An unscoped rule emits exactly what it always did**, which is what keeps the golden
snapshot and every substring assertion honest -- the early return is the guarantee, not a
coincidence of formatting.

A scoped rule emits **both** forms for every graph, and that is mandatory rather than
generous. Default and named are disjoint namespaces: `USING NAMED <g>` alone leaves the
query's default graph *empty*, so an unscoped pattern in the same rule would silently match
nothing, and `USING <g>` alone leaves `GRAPH <g>` invisible. Measured both ways against
Fuseki. Emitting both lets the unscoped half read the union while the scoped half addresses
graphs individually; verified to join correctly across the two.
"""
function dataset_lines(spec::RuleSpec, from::AbstractVector; keyword::AbstractString = "USING")
    isempty(from) && return ""
    plain = join(("$keyword <$(check_iri(g))>" for g in from), "\n")
    is_scoped(spec) || return plain * "\n"
    plain * "\n" * join(("$keyword NAMED <$(check_iri(g))>" for g in from), "\n") * "\n"
end

"""
    where_body(spec) -> String

The whole of a rule's WHERE clause: match triples, then VALUES, then BINDs, then negative
conditions.

The order is load-bearing and is the reason this is one function rather than five copies.
`VALUES` comes first among the additions because a `BIND` may mint from an enumerated value.
BIND sees only variables bound earlier in its group, so it must follow the triple patterns.
`FILTER NOT EXISTS` must follow the BINDs in turn, because a condition is allowed to mention
a *minted* variable -- "only create this if it does not already exist" -- and the filter can
only test what is bound by the time it runs.

**`gistp:inGraph` scopes the triples, not the clause.** Wrapping the finished string in one
`GRAPH ?g { … }` looks equivalent and is not. SPARQL translates `GRAPH ?g { P }` to
`Graph(?g, translate(P))`, so `?g` is bound by the operator *surrounding* the group and is
still unbound while `P` is evaluated: `BIND(BOUND(?g) AS ?seen)` inside the group yields
`false` on every row. A negative condition nested in the same group is worse than useless --
its `?g` is a fresh variable ranging over every named graph, which silently turns "no such
thing in THIS graph" into "no such thing in ANY graph", dropping solutions with no error.
Measured against Fuseki, not reasoned from the spec.

So only `bgp_text` is wrapped. VALUES and BIND stay outside the group, where `?g` is bound
and a template may mint from it; each condition wraps its own triples inside its own filter.
"""
where_body(spec::RuleSpec) =
    string(spec.match_scope === nothing ?
               bgp_text(spec.match, spec) :
               graph_wrap(bgp_text(spec.match, spec; indent = "    "),
                          spec.match_scope, spec),
           values_text(spec), binds_text(spec), nacs_text(spec))

"""
    graph_wrap(body, scope, spec; indent = "  ") -> String

Wrap already-rendered triple text in `GRAPH <g> { … }` or `GRAPH ?g { … }`.

`scope` is an IRI: a declared `gistp:SparqlVariable` renders as its variable, anything else
as the constant graph it names. That either/or is decided here and nowhere else, and it is
the same one [`term_sparql`](@ref) makes for a term -- so a graph variable goes through
[`check_variables`](@ref)'s validation like every other, which is what keeps `variableText`
from being splice-injected in graph position.
"""
function graph_wrap(body::AbstractString, scope::AbstractString, spec::RuleSpec;
                    indent::AbstractString = "  ")
    v = get(spec.variables, scope, nothing)
    g = v === nothing ? "<$(check_iri(scope))>" : v
    "$(indent)GRAPH $g {\n$body\n$indent}"
end

"""
    values_text(spec) -> String

The `VALUES` clauses for a rule's enumerated variables, one per variable, sorted by name.

**The same text serves both readings of `gistp:oneOf`, which is the point.** Whether a
`VALUES` clause *constrains* or *generates* is decided by the rest of the rule, not by the
compiler. If the match pattern also binds the variable, the clause is a join and narrows the
matches. If the variable appears only in the construct pattern, the clause multiplies the
solutions and the template is instantiated once per value -- a disjoint union, the coproduct
reading. Parameterised graph generation therefore falls out of the existing semantics with
no additional vocabulary and no second code path.
"""
function values_text(spec::RuleSpec)
    isempty(spec.enums) && return ""
    # Members are sorted HERE, not only in load_enums: a hand-built spec has whatever order
    # the author wrote, and the byte-stability guarantee has to hold however the spec arrived.
    # Members go through the same validation as every other IRI the compiler emits.
    # sparql_text alone wraps an IRI in <> and checks nothing, so a member containing '>'
    # would close the clause and open another -- the variableText hole, in a new place.
    member(t) = (t isa IRIRef && check_iri(t.value); sparql_text(t))
    lines = ("  VALUES $(spec.variables[iri]) " *
             "{ $(join(sort(member.(spec.enums[iri])), " ")) }"
             for iri in sort(collect(keys(spec.enums))))
    string("\n", join(lines, "\n"))
end

"The SPARQL variable names a `gistp:oneOf` enumeration binds."
enum_vars(spec::RuleSpec) =
    Set(spec.variables[iri] for iri in keys(spec.enums) if haskey(spec.variables, iri))

"""
    check_enums(spec)

Validate every enumerated variable. Three ways an enumeration can be wrong:

  * no `gistp:variableText`, so there is no SPARQL variable for `VALUES` to bind;
  * an empty list, which compiles to `VALUES ?v { }` -- legal SPARQL yielding no solutions,
    so the rule can never fire. A truncated list rather than an intent;
  * a `gistp:iriTemplate` on the same variable. Enumerating and constructing are
    contradictory instructions: `oneOf` says the value is one of these, the template says it
    is computed from other bindings.
"""
function check_enums(spec::RuleSpec)
    for iri in sort(collect(keys(spec.enums)))
        haskey(spec.variables, iri) || error(
            "rule <$(spec.iri)>: <$iri> has gistp:oneOf but no gistp:variableText, so there " *
            "is no SPARQL variable for its VALUES clause to bind.")
        isempty(spec.enums[iri]) && error(
            "rule <$(spec.iri)>: gistp:oneOf on <$iri> lists no values. That compiles to " *
            "VALUES $(spec.variables[iri]) { }, which yields no solutions, so the rule could " *
            "never fire.")
        haskey(spec.mints, iri) && error(
            "rule <$(spec.iri)>: <$iri> carries both gistp:oneOf and gistp:iriTemplate. " *
            "Enumerating and constructing are contradictory: oneOf says the value is one of " *
            "these, the template says it is computed from other bindings. Choose one.")
    end
    spec
end

"""
    check_no_blanks(spec)

Refuse a blank node anywhere in a pattern graph, and say what to write instead.

A blank node is an **undeclared variable**, which is the one thing this design rejects
everywhere else: variables are persistent typed individuals precisely so a pattern can be
validated, diffed, and given metadata. A blank node has none of that, and it means three
incompatible things depending on where it sits:

  * in the match pattern it behaves as a non-selectable variable -- "some thing";
  * in the construct pattern it is a *fresh* node per solution;
  * across the two it connects nothing, because SPARQL scoping will not carry a blank node
    from a WHERE clause into a CONSTRUCT template. The same label in L and R is two
    different nodes.

And in `DELETE { L ∖ I }` it is not merely ambiguous but illegal: SPARQL Update forbids
blank nodes in a DELETE template, so a `Rewrite` carrying one emits a query the store
rejects.

Skolemising them to IRIs would fix the syntax and keep the bug: in L or in a DELETE a Skolem
IRI is a *constant*, so the pattern would match exactly one node that exists nowhere and the
rule would silently never fire. In R the right answer already exists and is better --
`gistp:iriTemplate` is Skolemisation with the function stated, and stated is what makes it
deterministic, which is what makes an `Assert` fixpoint converge.
"""
function check_no_blanks(spec::RuleSpec)
    graphs = [("match pattern", spec.match_graph, spec.match),
              ("construct pattern", spec.construct_graph, spec.construct),
              (("negative condition", n.graph, n.triples) for n in spec.nacs)...]
    for (role, graph, triples) in graphs
        labels = String[]
        for t in triples, pos in (t.subject, t.predicate, t.object)
            pos isa BNode && !(pos.id in labels) && push!(labels, pos.id)
        end
        isempty(labels) && continue

        # A precise fix beats a diagnosis. Emit the declarations to paste, and name the
        # substitution to make, rather than leaving the author to work it out.
        decls = join(("    :_b$i a gistp:SparqlVariable ; gistp:variableText \"?_b$i\" ." *
                      "      # was _:$(labels[i+1])" for i in 0:length(labels)-1), "\n")
        subs = join(("_:$(labels[i+1]) -> :_b$i" for i in 0:length(labels)-1), ", ")
        error("""
              rule <$(spec.iri)>: $role <$graph> contains $(length(labels)) blank node(s). A \
              blank node is an undeclared variable -- it cannot be validated, cannot carry \
              gistp:oneOf or gistp:iriTemplate, does not connect L to R (SPARQL will not \
              carry it from WHERE into CONSTRUCT), and is illegal outright in the DELETE \
              template a gistp:Rewrite emits.

              Declare each one in the default graph:

              $decls

              then substitute in <$graph>: $subs""")
    end
    spec
end

"""
    check_positions(spec)

Refuse a term in a position RDF does not allow it to occupy.

A literal cannot be a subject and nothing but an IRI can be a predicate. Emitting one
produces SPARQL the store rejects, so the author learns about it as an opaque HTTP 400 from
Fuseki rather than as a statement about their rule. The pattern graphs themselves cannot
contain such a triple -- RDF forbids it too -- but a hand-built `RuleSpec` can, and an MCP
client hands specs in.
"""
function check_positions(spec::RuleSpec)
    graphs = [("match pattern", spec.match_graph, spec.match),
              ("construct pattern", spec.construct_graph, spec.construct),
              (("negative condition", n.graph, n.triples) for n in spec.nacs)...]
    for (role, graph, triples) in graphs, t in triples
        t.subject isa RDFLiteral && error(
            "rule <$(spec.iri)>: $role <$graph> has the literal $(sparql_text(t.subject)) " *
            "as a subject. RDF has no literal subjects, so this cannot be matched or " *
            "constructed.")
        t.predicate isa IRIRef || error(
            "rule <$(spec.iri)>: $role <$graph> has $(sparql_text(t.predicate)) as a " *
            "predicate. Only an IRI can be a predicate -- including a variable, which is " *
            "an IRI at pattern level.")
    end
    spec
end

"""
    check_variables(spec)

Reject a rule whose `gistp:variableText` is not a legal SPARQL variable.

The pattern language has two variable mechanisms and, until this existed, only one of them
was checked. A literal-position variable goes through [`var_name`](@ref), which validates
its lexical form against [`VARIABLE_RE`](@ref). An IRI-position variable's `variableText`
was returned by [`var_of`](@ref) verbatim and spliced into the query by
[`term_sparql`](@ref) -- validated nowhere at all.

So the text was untrusted input with a direct line into the emitted SPARQL, and
[`insert_query`](@ref) sends that SPARQL to the *update* endpoint. A `variableText` of

    "?v } INSERT { GRAPH <urn:pwned> { ... } } WHERE { ?v"

closes the engine's INSERT and opens the author's. Provenance then records a tidy rule
firing while the store takes an unrelated write, into a graph no `Firing` names and
[`undo_firing!`](@ref) cannot reverse. The dull version of the same hole is a `variableText`
of `"person"` -- a plausible typo that compiles to unparseable SPARQL and surfaces as an
opaque HTTP 400 from the store.

This lives in the pure layer rather than in [`load_variables`](@ref) so that a hand-built
`RuleSpec` is checked too, not just one loaded from a store.
"""
function check_variables(spec::RuleSpec)
    # Two declared variables sharing one variableText are two distinct RDF individuals that
    # compile to the same SPARQL variable, so the pattern silently means something narrower
    # than it reads: every occurrence of either is forced to the same binding.
    seen = Dict{String,String}()
    for iri in sort(collect(keys(spec.variables)))
        text = spec.variables[iri]
        haskey(seen, text) && error(
            "rule <$(spec.iri)>: <$iri> and <$(seen[text])> both declare " *
            "gistp:variableText $(repr(text)). They are distinct variables that would " *
            "compile to one, quietly forcing every occurrence of either to the same " *
            "binding. Give them different names.")
        seen[text] = iri
        occursin(VARIABLE_RE, text) || error(
            "rule <$(spec.iri)>: <$iri> has gistp:variableText $(repr(text)), which is not " *
            "a legal SPARQL variable (must match $(VARIABLE_RE.pattern)). The text is " *
            "substituted into the emitted query as-is, so it has to be a variable and " *
            "nothing else -- this is the same rule a literal-position \"?x\"^^gistp:var " *
            "already has to obey.")
    end
    spec
end

# ---------------------------------------------------------------------------
# The interface I = L ∩ R
# ---------------------------------------------------------------------------

# Identity of a pattern triple, for set arithmetic. `sparql_text` renders the term as
# authored -- a variable's own IRI, not the SPARQL variable it will become -- which is
# exactly the identity the intersection is over.
_ptkey(t::PatternTriple) =
    (sparql_text(t.subject), sparql_text(t.predicate), sparql_text(t.object))

"""
    interface(spec) -> Vector{PatternTriple}

I, the part of the rewrite that is preserved: the triples appearing in **both** L and R.

Computable as plain set intersection, and that is the payoff of the whole design. Variables
are persistent typed individuals rather than SPARQL name-strings, so two pattern triples
denote the same thing exactly when they are the same RDF triple -- no unification, no
alpha-equivalence. Literal-position variables intersect correctly too, because
`"?idText"^^gistp:var` is one RDF term wherever it appears.

I is authored by repetition: whatever is to be preserved is written into both graphs.
"""
interface(spec::RuleSpec) =
    (ks = Set(_ptkey(t) for t in spec.construct); [t for t in spec.match if _ptkey(t) in ks])

"L ∖ I -- the triples a `Rewrite` deletes."
match_only(spec::RuleSpec) =
    (ks = Set(_ptkey(t) for t in spec.construct); [t for t in spec.match if !(_ptkey(t) in ks)])

"R ∖ I -- the triples a `Rewrite` adds."
construct_only(spec::RuleSpec) =
    (ks = Set(_ptkey(t) for t in spec.match); [t for t in spec.construct if !(_ptkey(t) in ks)])

"""
    dangling_risks(spec) -> Vector{String}

Variables whose every occurrence in L is deleted and which R never mentions.

SPARQL Update is single-pushout: it deletes what it is told and performs no dangling check.
So a rule that strips a node of all the triples the pattern knows about leaves anything
*outside* the pattern still pointing at it -- a referent with no content. Double-pushout
rewriting forbids exactly this.

Reported rather than refused. Stripping a node is sometimes the intent, and whether some
other triple elsewhere references it is a property of the data, not of the rule.
`example_rule.trig` is the textbook case: its triple-level I is empty, so run as a Rewrite
it would delete `:_ID_1`'s every triple while nothing in R mentions it.
"""
function dangling_risks(spec::RuleSpec)
    deleted = match_only(spec)
    kept    = Set(_ptkey(t) for t in interface(spec))
    inR     = vars_in(spec.construct, spec)
    risks   = String[]
    for v in sort(collect(vars_in(spec.match, spec)))
        v in inR && continue
        # every triple of L mentioning v is being deleted?
        mentions(t) = v in (var_of(t.subject, spec), var_of(t.predicate, spec), var_of(t.object, spec))
        any(mentions, deleted) || continue
        any(t -> mentions(t) && _ptkey(t) in kept, spec.match) && continue
        push!(risks, v)
    end
    risks
end

"""
    scope_vars(scope, spec) -> Set{String}

The SPARQL variable a `gistp:inGraph` names, or an empty set if it names a constant graph.

A one-element set rather than a `Union{String,Nothing}` so it composes with `vars_in`, which
is what every binding question in the compiler is phrased against.
"""
scope_vars(scope::Union{String,Nothing}, spec::RuleSpec) =
    scope === nothing || !haskey(spec.variables, scope) ?
        Set{String}() : Set([spec.variables[scope]])

"""
    check_scopes(spec)

Refuse every use of `gistp:inGraph` this round does not implement, and every one it cannot
make safe. Each of these is otherwise a *silent* wrong answer, which is why they are errors
rather than warnings.

Round 5a scopes the read side only. Writing into a named graph needs `undo_firing!` to record
which graph each triple went to before it can be reversed, and an unreversible write is not
something to ship by omission.
"""
function check_scopes(spec::RuleSpec)
    scoped = String[]
    spec.match_scope === nothing || push!(scoped, spec.match_scope)
    spec.construct_scope === nothing || push!(scoped, spec.construct_scope)
    for n in spec.nacs
        n.scope === nothing || push!(scoped, n.scope)
    end
    isempty(scoped) && return spec

    spec.construct_scope === nothing || error(
        "rule <$(spec.iri)>: gistp:inGraph on the construct pattern <$(spec.construct_graph)> " *
        "is not supported yet. A rule that writes into a named graph has to record which " *
        "graph each triple went to, or undo_firing! cannot reverse it -- and an " *
        "irreversible write is not something to get by default. Scope the match pattern to " *
        "read per graph; the results still land in a firing graph you can merge where you " *
        "want them.")

    mode_symbol(spec) === :Rewrite && error(
        "rule <$(spec.iri)>: gistp:inGraph with gistp:Rewrite is not supported yet. A " *
        "rewrite deletes from exactly one target graph, and a scoped match can bind several " *
        "-- so the target, the tombstone and the undo record would each have to become a " *
        "set. Use Construct or Assert, or drop the scope and name the graph in `source`.")

    # A graph variable is spliced into query text like any other variable. `check_variables`
    # validates every entry of spec.variables, so a scope that resolves there is already
    # safe; one that does not is a constant graph IRI and must survive check_iri.
    for s in scoped
        haskey(spec.variables, s) && continue
        check_iri(s)
    end
    spec
end

"""
    check_bound(spec)

Reject a rule whose construct pattern uses a variable the match pattern never binds.

This is use-before-def, and it is the failure an LLM author hits most often: literal-position
variables have no declaration and are matched across L and R by string equality, so `?idtext`
in R against `?idText` in L is not a name error anywhere -- it silently compiles to a
CONSTRUCT with an unbound term, which simply produces nothing.

A variable is available to R if the match pattern binds it, **or** if it is minted -- a
minted variable is bound by the `BIND` the compiler emits, not by a triple pattern.
"""
function check_bound(spec::RuleSpec)
    check_no_blanks(spec)
    check_positions(spec)
    check_variables(spec)
    check_enums(spec)
    check_mints(spec)
    check_scopes(spec)
    # L's graph variable is bound by the GRAPH clause, not by any triple, so `vars_in` -- which
    # walks subject, predicate and object -- cannot see it. Without this a rule that records
    # which graph a fact came from, the whole point of scoping the match, is refused as
    # use-before-def on the one variable L most definitely binds.
    matched = union(vars_in(spec.match, spec), scope_vars(spec.match_scope, spec))
    # An enumerated variable is bound by its VALUES clause and a minted one by its BIND;
    # neither has to appear in a match triple to be available to R.
    bound   = union(matched, minted_vars(spec), enum_vars(spec))
    used    = vars_in(spec.construct, spec)
    free    = setdiff(used, bound)
    isempty(free) && return spec

    error("""
          rule <$(spec.iri)>: construct pattern uses $(join(sort(collect(free)), ", ")) \
          which the match pattern never binds and nothing mints. Bound by L: \
          $(isempty(matched) ? "(none)" : join(sort(collect(matched)), ", ")). \
          A literal-position variable is matched across L and R by string equality of its \
          lexical form, so check for a typo; if the variable is meant to be created rather \
          than found, give it a gistp:iriTemplate and its slot bindings.""")
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

    isempty(spec.match) && error("rule <$(spec.iri)>: match pattern <$(spec.match_graph)> is empty.")
    isempty(spec.construct) && error("rule <$(spec.iri)>: construct pattern <$(spec.construct_graph)> is empty.")

    # BINDs go after every triple pattern: BIND sees only variables already bound earlier in
    # its group, and check_mints has guaranteed each slot value is bound by L.
    m === :Rewrite && return """
    # Rewrite rule <$(spec.iri)>  (I = L n R holds $(length(interface(spec))) triple(s))
    DELETE {
    $(bgp_text(match_only(spec), spec))
    }
    INSERT {
    $(bgp_text(construct_only(spec), spec))
    }
    WHERE {
    $(where_body(spec))
    }
    """

    """
    # $(m) rule <$(spec.iri)>
    CONSTRUCT {
    $(bgp_text(spec.construct, spec))
    }
    WHERE {
    $(where_body(spec))
    }
    """
end

"""
    project_query(spec; triples, into, from = String[]) -> String

Materialise an arbitrary sub-template of a rule into a graph, without touching anything else.

Used to preview a `Rewrite`: running `match_only` and `construct_only` through this shows
exactly what the rule *would* delete and add, computed from the live data, while the target
graph stays untouched. `rewrite_query` is the same solutions with the same BINDs; only the
templates differ.
"""
function project_query(spec::RuleSpec; triples::Vector{PatternTriple},
                       into::AbstractString, from::AbstractVector = String[])
    check_bound(spec)
    isempty(triples) && return ""
    using_lines = dataset_lines(spec, from)
    """
    INSERT {
      GRAPH <$(check_iri(into))> {
    $(bgp_text(triples, spec; indent = "    "))
      }
    }
    $(using_lines)WHERE {
    $(where_body(spec))
    }
    """
end

"""
    rewrite_query(spec; target, firing, tombstone, from = String[]) -> String

A `gistp:Rewrite` as one atomic SPARQL Update, recorded so it can be reversed.

Unlike `Construct` and `Assert`, a rewrite mutates the data. `target` is the graph it edits;
`firing` and `tombstone` capture what was added and what was removed, which is what makes
undo possible at all -- `DROP GRAPH` cannot restore a deletion.

All four templates instantiate from the same solutions, and SPARQL evaluates the WHERE
against the pre-update state with DELETE applied before INSERT, so the tombstone receives
the triples as they were before removal. One request is one transaction, so a firing is
never half-applied.
"""
function rewrite_query(spec::RuleSpec; target::AbstractString, firing::AbstractString,
                       tombstone::AbstractString, from::AbstractVector = String[])
    check_bound(spec)
    mode_symbol(spec) === :Rewrite || error(
        "rule <$(spec.iri)>: rewrite_query is only for gistp:Rewrite; this rule is " *
        "$(mode_symbol(spec)). Use insert_query.")

    gone  = match_only(spec)
    added = construct_only(spec)
    isempty(gone) && isempty(added) && error(
        "rule <$(spec.iri)>: L and R are identical, so the rewrite deletes nothing and " *
        "adds nothing. I = L = R.")

    t, f, tomb = check_iri(target), check_iri(firing), check_iri(tombstone)
    using_lines = dataset_lines(spec, from)
    ops = String[]

    # Five operations, one request, one transaction. The obvious shape -- a single
    # DELETE/INSERT writing the target, the firing and the tombstone at once -- is wrong,
    # and wrong in a way that loses data: an R \ I triple the target ALREADY held would be
    # recorded in the firing graph as though this rule had added it, and undo would then
    # delete a triple that predates the rule entirely.
    #
    # So the candidates are staged and pruned against the target FIRST, while the target is
    # still untouched, and only what survives is treated as this firing's contribution.
    if !isempty(added)
        push!(ops, """
        INSERT {
          GRAPH <$f> {
        $(bgp_text(added, spec; indent = "    "))
          }
        }
        $(using_lines)WHERE {
        $(where_body(spec))
        }""")
        # what the target already had is not something this rule added
        push!(ops, """
        DELETE { GRAPH <$f> { ?__s ?__p ?__o } }
        WHERE  { GRAPH <$f> { ?__s ?__p ?__o } GRAPH <$t> { ?__s ?__p ?__o } }""")
        # NO dataset clause here, and none in the promotion op below. This is an invariant,
        # not an oversight: USING/USING NAMED *replace* the dataset, so a graph absent from
        # the clause is invisible even to a GRAPH <constant> in the WHERE -- verified, it
        # returns nothing and the update succeeds with 204. Splice `using_lines` in here and
        # this op stops pruning, while the promotion op stops copying; op 4 has already run,
        # so the target loses its triples and never receives the replacements. Silent data
        # loss. `test/runtests.jl` asserts the absence.
    end

    if !isempty(gone)
        # The tombstone is projected before the delete, from the same solutions: L matched,
        # so every triple in it genuinely exists right now.
        push!(ops, """
        INSERT {
          GRAPH <$tomb> {
        $(bgp_text(gone, spec; indent = "    "))
          }
        }
        $(using_lines)WHERE {
        $(where_body(spec))
        }""")
        push!(ops, """
        DELETE {
          GRAPH <$t> {
        $(bgp_text(gone, spec; indent = "    "))
          }
        }
        $(using_lines)WHERE {
        $(where_body(spec))
        }""")
    end

    # Applied last, and from the pruned firing graph rather than from the template, so the
    # target receives exactly what the firing graph claims -- which is what makes undo an
    # exact inverse.
    isempty(added) || push!(ops, """
        INSERT { GRAPH <$t> { ?__s ?__p ?__o } }
        WHERE  { GRAPH <$f> { ?__s ?__p ?__o } }""")

    join(ops, " ;\n") * "\n"
end

"""
    collision_queries(spec; from = String[]) -> Vector{Tuple{String,String}}

One `(minted variable IRI, SELECT)` pair per minted variable, finding IRIs that more than one
distinct binding tuple would produce.

The backstop behind [`ambiguous_separators`](@ref). The static lint catches templates that
are ambiguous *by construction*; this catches the rest — anything the encoder cannot
distinguish on the actual data, and any future lossy encoding such as slugging, where two
different source values legitimately map to one string.

It needs no extra triples, because the rule's own match pattern already binds both the slot
values and the minted IRI: group by the IRI, count distinct binding tuples, and report any
group above one. The tuple is keyed with a literal space between percent-encoded values --
a space inside a value becomes `%20`, so a raw space unambiguously separates the parts.
"""
function collision_queries(spec::RuleSpec; from::AbstractVector = String[])
    out = Tuple{String,String}[]
    isempty(spec.mints) && return out
    froms = dataset_lines(spec, from; keyword = "FROM")

    for iri in sort(collect(keys(spec.mints)))
        m = spec.mints[iri]
        v = spec.variables[iri]
        key = join(("ENCODE_FOR_URI(STR($(var_of(m.slots[n], spec))))"
                    for n in sort(collect(keys(m.slots)))), ", \" \", ")
        push!(out, (iri, """
        SELECT $v (COUNT(DISTINCT ?__key) AS ?n)
        $(froms)WHERE {
        $(bgp_text(spec.match, spec))
        $(bind_text(m, spec))$(nacs_text(spec))
          BIND(CONCAT($key) AS ?__key)
        }
        GROUP BY $v
        HAVING (COUNT(DISTINCT ?__key) > 1)
        """))
    end
    out
end

"""
    check_collisions(spec; from = String[], ep = endpoint(), limit = 5) -> RuleSpec

Run [`collision_queries`](@ref) and refuse the rule if any minted IRI is reachable from more
than one distinct binding.

This raises rather than warns. A collision is not a cosmetic problem: an IRI is an identity
claim, so two people sharing a minted IRI *are* one person as far as every downstream query
is concerned, and nothing else in the stack will ever notice.
"""
function check_collisions(spec::RuleSpec; from::AbstractVector = String[],
                          ep::SparqlEndpoint = endpoint(), limit::Integer = 5)
    # Validate before assembling anything. `apply_rule` calls this *before* `insert_query`,
    # so relying on that function's own `check_bound` to sanitise `variableText` left this
    # one shipping unvalidated text to the store: a poisoned variableText reached Fuseki and
    # came back HTTP 400. Nothing was written, but only because the query endpoint refuses
    # updates -- a property of the store's endpoint separation, not of this code. Every
    # function that builds SPARQL validates its own inputs.
    check_variables(spec)
    for (iri, q) in collision_queries(spec; from = from)
        # RFC 6570 Level 1 with a non-ambiguous separator is *injective*: ENCODE_FOR_URI is
        # injective, and a reserved separator cannot appear raw inside an encoded value --
        # even a literal "%2F" double-encodes to "%252F". So distinct slot tuples cannot
        # produce one IRI, and this query provably returns nothing. `compile_rule` already
        # refuses ambiguous separators, so today the loop always skips and costs no query.
        #
        # It is kept, wired in and tested, because it stops being vacuous the moment a lossy
        # encoding exists: slugging deliberately maps many source values onto one string, and
        # that is exactly when two distinct bindings silently become one node.
        isempty(ambiguous_separators(spec.mints[iri].template)) && continue
        rows = select(q; ep = ep)
        isempty(rows) && continue
        v = spec.variables[iri]
        shown = [string("<", (r[v[2:end]]::IRIRef).value, "> from ",
                        (r["n"]::RDFLiteral).lexical, " distinct bindings")
                 for r in Iterators.take(rows, limit)]
        error("""
              rule <$(spec.iri)>: minting $v produces $(length(rows)) IRI(s) that more than \
              one distinct binding would create, which would silently merge distinct things \
              into one node:
                $(join(shown, "\n  "))$(length(rows) > limit ? "\n  ... and $(length(rows) - limit) more" : "")
              The template $(repr(spec.mints[iri].template)) does not discriminate its \
              inputs. Add a slot, or use a slot whose values are unique.""")
    end
    spec
end

"""
    mint_fanin(spec; from = String[], ep = endpoint(), limit = 5)
        -> Vector{Tuple{String,Vector{Tuple{String,Int}}}}

For each minted variable, the IRIs built from **more than one** distinct source binding,
worst first.

This is the hazard the injectivity argument does *not* cover. Two different people sharing an
identifier text mint one employee IRI: the slot values are identical, so
[`check_collisions`](@ref) sees nothing wrong, yet the minted node ends up carrying both
people's facts.

Deliberately a report, not a refusal. Many-to-one minting is often exactly right -- a
department minted from its name should be one node for all its staff -- so whether fan-in is
a bug depends on modelling intent, which the pattern cannot state. Surfacing it in the dry
run lets a human decide before anything is written.

The key covers every variable the construct pattern uses apart from the minted one: those are
the values that actually land on the minted node.
"""
function mint_fanin(spec::RuleSpec; from::AbstractVector = String[],
                    ep::SparqlEndpoint = endpoint(), limit::Integer = 5)
    out = Tuple{String,Vector{Tuple{String,Int}}}[]
    isempty(spec.mints) && return out
    check_variables(spec)          # this builds SPARQL too; see check_collisions
    froms = dataset_lines(spec, from; keyword = "FROM")
    others = sort(collect(setdiff(vars_in(spec.construct, spec), minted_vars(spec))))
    isempty(others) && return out
    key = join(("ENCODE_FOR_URI(STR($o))" for o in others), ", \" \", ")

    for iri in sort(collect(keys(spec.mints)))
        v = spec.variables[iri]
        rows = select("""
            SELECT $v (COUNT(DISTINCT ?__ctx) AS ?n)
            $(froms)WHERE {
            $(bgp_text(spec.match, spec))
            $(bind_text(spec.mints[iri], spec))$(nacs_text(spec))
              BIND(CONCAT($key) AS ?__ctx)
            }
            GROUP BY $v
            HAVING (COUNT(DISTINCT ?__ctx) > 1)
            ORDER BY DESC(?n) LIMIT $(Int(limit))"""; ep = ep)
        isempty(rows) || push!(out,
            (iri, [((r[v[2:end]]::IRIRef).value, parse(Int, (r["n"]::RDFLiteral).lexical))
                   for r in rows]))
    end
    out
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
        "rule <$(spec.iri)>: gistp:Rewrite mutates the data, so it cannot be run through " *
        "insert_query, which only ever adds to a firing graph. Use rewrite_query.")
    using_lines = dataset_lines(spec, from)
    """
    INSERT {
      GRAPH <$(check_iri(into))> {
    $(bgp_text(spec.construct, spec; indent = "    "))
      }
    }
    $(using_lines)WHERE {
    $(where_body(spec))
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

const SKOS_LABEL      = "http://www.w3.org/2004/02/skos/core#prefLabel"
const SKOS_DEFINITION = "http://www.w3.org/2004/02/skos/core#definition"

"""
    rule_catalogue(; ep = endpoint()) -> Vector{NamedTuple}

Every rule in the store with its mode, label and definition -- what a human or an agent
needs to choose one, without reading any SPARQL.

Each entry carries `mode` (a `Symbol`) and `mode_iri` (the raw `gistp:rewriteMode` value).
A rule whose mode is not one of the three recognised IRIs comes back as `:Unrecognised`
rather than raising: this is the *catalogue*, and it is the only route an agent has to
discovering any rule at all, so one malformed rule must not hide the rest of them. The rule
still fails, loudly, at [`load_rule`](@ref) the moment anyone tries to use it.
"""
function rule_catalogue(; ep::SparqlEndpoint = endpoint())
    rows = select("""
        SELECT ?r ?mode ?label ?def (COUNT(?n) AS ?guards) WHERE {
          ?r a <$C_RULE> ; <$P_MODE> ?mode .
          OPTIONAL { ?r <$SKOS_LABEL> ?label }
          OPTIONAL { ?r <$SKOS_DEFINITION> ?def }
          OPTIONAL { ?r <$P_NAC> ?n }
        } GROUP BY ?r ?mode ?label ?def ORDER BY ?r"""; ep = ep)
    lex(r, k) = haskey(r, k) && r[k] isa RDFLiteral ? (r[k]::RDFLiteral).lexical : ""
    mode_of(m) = try mode_symbol(m) catch; :Unrecognised end
    [(iri = _iri(r["r"]), mode = mode_of(_iri(r["mode"])), mode_iri = _iri(r["mode"]),
      label = lex(r, "label"), definition = lex(r, "def"),
      guards = parse(Int, (r["guards"]::RDFLiteral).lexical)) for r in rows]
end

export PatternTriple, RuleSpec, MintSpec, load_rule, load_pattern, load_variables, load_mints
export rule_catalogue
export compile_rule, compile_from_store, insert_query, rewrite_query, project_query
export list_rules, mode_symbol
export interface, match_only, construct_only, dangling_risks
export var_of, term_sparql, bgp_text, vars_in, check_bound, check_mints, check_variables
export NacSpec, nacs_text, where_body, strategy_symbol, check_no_blanks, check_positions
export load_enums, values_text, enum_vars, check_enums
export load_nac_graphs, load_strategy, load_priority, load_max_iterations
export STRATEGY_ONCE, STRATEGY_TOFIXPOINT
export parse_template, template_slots, bind_text, minted_vars
export ambiguous_separators, collision_queries, check_collisions, mint_fanin
export GISTP_NS, MODE_CONSTRUCT, MODE_ASSERT, MODE_REWRITE
export load_in_graph, is_scoped, dataset_lines, graph_wrap, check_scopes, scope_vars
