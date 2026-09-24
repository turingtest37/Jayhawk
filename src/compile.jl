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
# The rule layer -- Rule, RuleSet, modes, strategies -- lives in JayhawkPatterning, not gistPatterns.
const JHP_NS = "https://turingtest37.github.io/jayhawkpatterning/"

const P_MATCH = JHP_NS * "hasMatchPattern"
const P_CONSTRUCT = JHP_NS * "hasConstructPattern"
const P_MODE = JHP_NS * "rewriteMode"
const P_VARIABLETEXT = GISTP_NS * "variableText"
const P_IRITEMPLATE = GISTP_NS * "iriTemplate"
const P_ISMINTEDBY = GISTP_NS * "isMintedBy"
const P_NAMESPACE = GISTP_NS * "namespace"
const P_LOCALTEMPLATE = GISTP_NS * "localTemplate"
const P_HASSLOT = GISTP_NS * "hasSlot"
const P_SLOTNAME = GISTP_NS * "slotName"
const P_SLOTVALUE = GISTP_NS * "slotValue"
const P_ONEOF = GISTP_NS * "oneOf"
const P_NAC = JHP_NS * "hasNegativeCondition"
const P_FILTER = JHP_NS * "hasFilterCondition"
const P_FILTERTEXT = JHP_NS * "filterText"
const P_INGRAPH = JHP_NS * "inGraph"
const P_HASBINDING = JHP_NS * "hasBinding"
const P_BINDTEXT = JHP_NS * "bindText"
const P_BINDSVAR = JHP_NS * "bindsVariable"

const RDF_FIRST = "http://www.w3.org/1999/02/22-rdf-syntax-ns#first"
const RDF_REST = "http://www.w3.org/1999/02/22-rdf-syntax-ns#rest"
const P_STRATEGY = JHP_NS * "strategy"
const P_PRIORITY = JHP_NS * "priority"
const P_MAXITER = JHP_NS * "maxIterations"
const C_SPARQLVAR = GISTP_NS * "SparqlVariable"
# No C_FILTERCOND. `load_filters` reaches a condition through jhp:hasFilterCondition and
# never through its type, on purpose: joining on `?f a jhp:FilterCondition` would drop an
# untyped condition silently, and a dropped filter widens the rule. The property is the
# edge that matters; the class is the shapes file's business.
const C_TABULARSOURCE = GISTP_NS * "TabularDataSource"

# SPARQL Anything's Facade-X vocabulary. `fx:` properties on a gistp:TabularDataSource are
# emitted verbatim into the SERVICE body; `xyz:` predicates appear in the pattern itself and
# reach the compiler as ordinary absolute IRIs, so nothing here has to know about them.
const FX_NS = "http://sparql.xyz/facade-x/ns/"
const P_FX_LOCATION = FX_NS * "location"
const SA_SERVICE = "x-sparql-anything:"
const C_RULE = JHP_NS * "Rule"

const MODE_CONSTRUCT = JHP_NS * "_RewriteMode_construct"
const MODE_ASSERT = JHP_NS * "_RewriteMode_assert"
const MODE_REWRITE = JHP_NS * "_RewriteMode_rewrite"

const STRATEGY_ONCE = JHP_NS * "Once"
const STRATEGY_TOFIXPOINT = JHP_NS * "ToFixpoint"

strategy_symbol(s::AbstractString) =
    if s == STRATEGY_ONCE
        :Once
    elseif s == STRATEGY_TOFIXPOINT
        :ToFixpoint
    else
        throw(ArgumentError("unknown jhp:strategy <$s>"))
    end

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
    # The gistp:MintingFunction the template came from, or `nothing` when the variable
    # carries its own gistp:iriTemplate. Provenance for a reviewer only: by the time a
    # MintSpec exists the two spellings are one template, and nothing downstream branches.
    minting_function::Union{String,Nothing}
end

MintSpec(variable, template, slots) = MintSpec(variable, template, slots, nothing)

"""
A negative application condition: a pattern that must **not** match for the rule to fire.

Its own named graph, like L and R, and compiled to its own `FILTER NOT EXISTS`.
"""
struct NacSpec
    graph::String
    triples::Vector{PatternTriple}
    # jhp:inGraph, if the condition is scoped: the IRI of a graph variable or of a constant
    # graph. A guard scoped to the same variable as L reads "no such thing in THIS graph".
    scope::Union{String,Nothing}
end

NacSpec(graph, triples) = NacSpec(graph, triples, nothing)

"""
One of several match patterns: its own named graph, its triples, and its own `jhp:inGraph`.

A rule with a single match pattern has none of these -- it keeps the scalar `match_graph` /
`match` / `match_scope` it always had, and compiles to exactly the bytes it always did. A
rule with two or more carries one `MatchPart` each, and L is their **conjunction**: every
part must match, and a variable shared between parts joins them.

Why more than one: scope is a property of a *pattern*, and one pattern is evaluated in one
graph. A rule pairing an entity in one graph with an entity in another therefore needs two.
The workaround -- no scope, both graphs in `source` -- merges them into one default graph,
where a trade and the holding it belongs to use the same predicates and so cannot be told
apart: the rule pairs each entity with itself. Measured on `multi_match_rule.trig`: 6 pairs
where 1 is true.
"""
struct MatchPart
    graph::String
    triples::Vector{PatternTriple}
    scope::Union{String,Nothing}
end

"""
One `jhp:Binding`: a SPARQL expression, and the declared variable its value is bound to.

The rule-level counterpart of a filter. A filter *tests* values L has bound; a binding
*computes* one -- a slug, a normalised symbol, a date prefix, a hash -- and names it, so R,
a filter, a guard or a `gistp:iriTemplate` slot can use it. Compiles to
`BIND((text) AS ?v)`, placed after L and VALUES and before any mint, and ordered among the
other bindings so each reads only what is already bound.

Text rather than structure, for the reason `jhp:filterText` is text: an expression grammar
in RDF would be a second language to learn and to keep in step with SPARQL's own. The
bargain is the same too -- the text is spliced into the query, so it is held to exactly the
checks `check_filters` applies.
"""
struct BindingSpec
    iri::String
    variable::String     # the IRI of the declared gistp:SparqlVariable it binds
    text::String
end

"""
One `gistp:SourceMap`: a column, the literal variable it feeds, and the value pipeline.

`column` is the source's own spelling; [`fx_predicate`](@ref) turns it into an IRI. The four
pipeline fields are each `nothing` when unstated, and a map with none of them compiles to a
single triple pattern -- which is what keeps an ordinary extraction rule's output as simple
as it was when the author wrote the predicate by hand.
"""
struct SourceMapSpec
    iri::String
    variable::String                       # the gistp:variableText it binds, e.g. "?given"
    column::String
    separator::Union{String,Nothing}
    string_before::Union{String,Nothing}
    pattern_match::Union{String,Nothing}
    pattern_exclude::Union{String,Nothing}
end

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
    # jhp:inGraph on L and on R: the IRI of a graph variable or of a constant graph, or
    # `nothing` for the graph-blind reading every rule had before named graphs. Scope is a
    # property of the *pattern*, not of a triple -- TriG cannot nest a GRAPH inside a graph,
    # so a per-triple graph term would have to be reified inside the pattern.
    match_scope::Union{String,Nothing}
    construct_scope::Union{String,Nothing}
    # A scope IRI that names a gistp:TabularDataSource rather than a graph => the fx:
    # properties to emit inside a SERVICE, sorted by predicate so the text is byte-stable.
    # Empty for every rule that reads only the store, which is what keeps the golden
    # snapshots of those rules unchanged.
    services::Dict{String,Vector{Pair{String,String}}}
    # Every jhp:filterText the rule declares, sorted, each compiled to its own FILTER(...).
    # Text rather than structure: a SPARQL expression grammar in RDF would be a second
    # language to learn and to keep in step with SPARQL's own. The bargain is that the text
    # is spliced into the query, so `check_filters` has to earn that splice -- see it for
    # what is rejected and why.
    filters::Vector{String}
    # gistp:SourceMap: which column feeds which literal variable, and how the value is
    # cleaned on the way. Compilation input like `mints` and `enums` -- it becomes triple
    # patterns inside the SERVICE plus a pipeline after the match. Empty for every rule that
    # names its own Facade-X predicates, which is what keeps those rules' output unchanged.
    source_maps::Vector{SourceMapSpec}
    # Empty for a rule with one match pattern. With two or more: one MatchPart each, while
    # `match` holds the union of their triples (so interface, check_bound and every other
    # consumer that reasons about L's triples needs no change), `match_graph` the first
    # part's IRI, and `match_scope` nothing -- every scope is read through `match_patterns`,
    # never off the scalar field, because a multi-pattern rule has no single scope.
    match_parts::Vector{MatchPart}
    # jhp:hasBinding, in no particular order: `ordered_bindings` decides the order they are
    # emitted in. Empty for every rule written before bindings existed.
    bindings::Vector{BindingSpec}
end

# Every call site written before jhp:hasBinding.
function RuleSpec(
    iri,
    mode,
    lg,
    cg,
    match,
    construct,
    variables,
    mints,
    enums,
    nacs,
    strategy,
    priority,
    maxit,
    mscope,
    cscope,
    services,
    filters,
    source_maps,
    parts,
)
    return RuleSpec(
        iri,
        mode,
        lg,
        cg,
        match,
        construct,
        variables,
        mints,
        enums,
        nacs,
        strategy,
        priority,
        maxit,
        mscope,
        cscope,
        services,
        filters,
        source_maps,
        parts,
        BindingSpec[],
    )
end

# Every call site written before multi-pattern L: one match pattern, no parts.
function RuleSpec(
    iri,
    mode,
    lg,
    cg,
    match,
    construct,
    variables,
    mints,
    enums,
    nacs,
    strategy,
    priority,
    maxit,
    mscope,
    cscope,
    services,
    filters,
    source_maps,
)
    return RuleSpec(
        iri,
        mode,
        lg,
        cg,
        match,
        construct,
        variables,
        mints,
        enums,
        nacs,
        strategy,
        priority,
        maxit,
        mscope,
        cscope,
        services,
        filters,
        source_maps,
        MatchPart[],
    )
end

"""
    match_patterns(spec) -> Vector{MatchPart}

Every match pattern of a rule, as parts: the one pattern of an ordinary rule, or each part
of a multi-pattern one. The single place that knows the two representations exist.
"""
function match_patterns(spec::RuleSpec)
    isempty(spec.match_parts) || return spec.match_parts
    return [MatchPart(spec.match_graph, spec.match, spec.match_scope)]
end

"Every `jhp:inGraph` on a match pattern, in pattern order."
match_scopes(spec::RuleSpec) =
    String[p.scope for p in match_patterns(spec) if p.scope !== nothing]

"The variables L binds through `GRAPH ?g` rather than through any triple."
match_scope_vars(spec::RuleSpec) =
    reduce(union, (scope_vars(s, spec) for s in match_scopes(spec)); init=Set{String}())

# The full spec minus `source_maps`, which is the arity everything written before source maps
# existed uses. Same bargain as the constructors below: adding a field to the spec must not
# invalidate a call site that had nothing to say about it.
function RuleSpec(
    iri,
    mode,
    lg,
    cg,
    match,
    construct,
    variables,
    mints,
    enums,
    nacs,
    strategy,
    priority,
    maxit,
    mscope,
    cscope,
    services,
    filters,
)
    return RuleSpec(
        iri,
        mode,
        lg,
        cg,
        match,
        construct,
        variables,
        mints,
        enums,
        nacs,
        strategy,
        priority,
        maxit,
        mscope,
        cscope,
        services,
        filters,
        SourceMapSpec[],
    )
end

# Every call site written before the control layer stays valid: a rule with no negative
# conditions and no stated policy behaves exactly as it did.
function RuleSpec(iri, mode, lg, cg, match, construct, variables, mints)
    return RuleSpec(
        iri,
        mode,
        lg,
        cg,
        match,
        construct,
        variables,
        mints,
        Dict{String,Vector{RDFTerm}}(),
        NacSpec[],
        nothing,
        0,
        nothing,
        nothing,
        nothing,
        Dict{String,Vector{Pair{String,String}}}(),
        String[],
        SourceMapSpec[],
    )
end

function RuleSpec(
    iri, mode, lg, cg, match, construct, variables, mints, nacs, strategy, priority, maxit
)
    return RuleSpec(
        iri,
        mode,
        lg,
        cg,
        match,
        construct,
        variables,
        mints,
        Dict{String,Vector{RDFTerm}}(),
        nacs,
        strategy,
        priority,
        maxit,
        nothing,
        nothing,
        Dict{String,Vector{Pair{String,String}}}(),
        String[],
        SourceMapSpec[],
    )
end

function RuleSpec(
    iri,
    mode,
    lg,
    cg,
    match,
    construct,
    variables,
    mints,
    enums,
    nacs,
    strategy,
    priority,
    maxit,
)
    return RuleSpec(
        iri,
        mode,
        lg,
        cg,
        match,
        construct,
        variables,
        mints,
        enums,
        nacs,
        strategy,
        priority,
        maxit,
        nothing,
        nothing,
        Dict{String,Vector{Pair{String,String}}}(),
        String[],
        SourceMapSpec[],
    )
end

# The arity before `services`: every rule that reads only the store builds one, and it is by
# far the most-used constructor in the suite.
function RuleSpec(
    iri,
    mode,
    lg,
    cg,
    match,
    construct,
    variables,
    mints,
    enums,
    nacs,
    strategy,
    priority,
    maxit,
    mscope,
    cscope,
)
    return RuleSpec(
        iri,
        mode,
        lg,
        cg,
        match,
        construct,
        variables,
        mints,
        enums,
        nacs,
        strategy,
        priority,
        maxit,
        mscope,
        cscope,
        Dict{String,Vector{Pair{String,String}}}(),
        String[],
        SourceMapSpec[],
    )
end

# The arity before `filters`: every rule authored before filter conditions existed builds one.
function RuleSpec(
    iri,
    mode,
    lg,
    cg,
    match,
    construct,
    variables,
    mints,
    enums,
    nacs,
    strategy,
    priority,
    maxit,
    mscope,
    cscope,
    services,
)
    return RuleSpec(
        iri,
        mode,
        lg,
        cg,
        match,
        construct,
        variables,
        mints,
        enums,
        nacs,
        strategy,
        priority,
        maxit,
        mscope,
        cscope,
        services,
        String[],
    )
end

mode_symbol(m::AbstractString) =
    if m == MODE_CONSTRUCT
        :Construct
    elseif m == MODE_ASSERT
        :Assert
    elseif m == MODE_REWRITE
        :Rewrite
    else
        throw(ArgumentError("unknown jhp:rewriteMode <$m>"))
    end

mode_symbol(s::RuleSpec) = mode_symbol(s.mode)

# ---------------------------------------------------------------------------
# Reading a rule out of the store
# ---------------------------------------------------------------------------

function _iri(t::RDFTerm)
    return if t isa IRIRef
        t.value
    else
        throw(ArgumentError("expected an IRI, got $(sparql_text(t))"))
    end
end

"""
    load_rule(rule_iri; ep = endpoint()) -> RuleSpec

Fetch one rule and both of its pattern graphs.

Reads `jhp:hasMatchPattern` / `hasConstructPattern` / `rewriteMode` from the default
graph, then the triples of each named graph. The pattern *is* its graph: a pattern's IRI is
also the IRI of the graph holding its triples, so there is no membership vocabulary and no
predicate blacklist separating payload from metadata.
"""
function load_rule(rule_iri::AbstractString; ep::SparqlEndpoint=endpoint())
    r = check_iri(rule_iri)
    rows = select(
        """
SELECT ?mode ?l ?c WHERE {
  <$r> <$P_MATCH>     ?l ;
       <$P_CONSTRUCT> ?c ;
       <$P_MODE>      ?mode .
}""";
        ep=ep,
    )

    isempty(rows) && error(
        "no rule found at <$r>: it must carry jhp:hasMatchPattern, " *
        "jhp:hasConstructPattern and jhp:rewriteMode in the default graph.",
    )
    # Several match patterns are one rule: L is their conjunction. Several construct
    # patterns or modes are not -- which R, under which mode, would be a guess.
    for (key, what) in (("c", "jhp:hasConstructPattern"), ("mode", "jhp:rewriteMode"))
        n = length(unique(_iri(row[key]) for row in rows))
        n == 1 || error(
            "<$r> declares $n $what values; exactly one is required. " *
            "JayhawkPatternShapes.ttl RuleShape enforces this -- validate first.",
        )
    end

    mode = _iri(rows[1]["mode"])
    cg = _iri(rows[1]["c"])
    # Sorted, so the first part -- which names the rule's L in messages -- and the order the
    # parts render in are both reproducible.
    lgs = sort!(unique(_iri(row["l"]) for row in rows))
    lg = first(lgs)
    parts = if length(lgs) == 1
        MatchPart[]
    else
        [MatchPart(g, load_pattern(g; ep=ep), load_in_graph(g; ep=ep)) for g in lgs]
    end

    nacs = [
        NacSpec(g, load_pattern(g; ep=ep), load_in_graph(g; ep=ep)) for
        g in load_nac_graphs(r; ep=ep)
    ]
    # The negative conditions' graphs join the scoping set: a variable may appear ONLY
    # inside a condition -- that is the existentially-quantified case -- and without this it
    # would be loaded as no variable at all and emitted as a bare IRI.
    graphs = String[lgs..., cg, (n.graph for n in nacs)...]

    # Bound rather than inlined because `load_source_maps` needs both: a source map is found
    # from the variables the rule uses, and a mint slot is one of the places a rule uses one.
    # A bound variable need not occur in any pattern graph, so load_variables may not see it;
    # the binding's own declaration is merged in instead.
    bindings, bvars = load_bindings(r; ep=ep)
    vars = merge(load_variables(graphs; ep=ep), bvars)
    mints = load_mints(graphs; ep=ep)

    # One pattern: its scope is the scalar field, exactly as before parts existed. Several:
    # the scalar is `nothing`, and each part carries its own.
    mscope = isempty(parts) ? load_in_graph(lg; ep=ep) : nothing
    match = if isempty(parts)
        load_pattern(lg; ep=ep)
    else
        # A triple two parts share is one triple of L -- as a set, the way `interface`
        # already treats it -- though each part still renders it in its own graph.
        sort!(
            unique(t -> _ptkey(t), reduce(vcat, (p.triples for p in parts)));
            by=t -> (sparql_text(t.subject), sparql_text(t.predicate), sparql_text(t.object)),
        )
    end
    mscopes = isempty(parts) ? [mscope] : [p.scope for p in parts]

    return RuleSpec(
        r,
        mode,
        lg,
        cg,
        match,
        load_pattern(cg; ep=ep),
        vars,
        mints,
        load_enums(graphs; ep=ep),
        nacs,
        load_strategy(r; ep=ep),
        load_priority(r; ep=ep),
        load_max_iterations(r; ep=ep),
        mscope,
        load_in_graph(cg; ep=ep),
        load_services(
            String[
                s for s in (mscopes..., load_in_graph(cg; ep=ep), (n.scope for n in nacs)...)
                if s !== nothing
            ];
            ep=ep,
        ),
        load_filters(r; ep=ep),
        load_source_maps(r, graphs; also=_slot_var_texts(vars, mints), ep=ep),
        parts,
        bindings,
    )
end

"""
    _slot_var_texts(variables, mints) -> Set{String}

The `gistp:variableText` of every variable an `gistp:iriTemplate` slot supplies.

Separate from the patterns because a slot value is a statement in the default graph, not a
triple in L or R: a minted IRI can read a variable that appears in neither.
"""
function _slot_var_texts(
    variables::AbstractDict{String,String}, mints::AbstractDict{String,MintSpec}
)
    out = Set{String}()
    for (_, m) in mints, (_, term) in m.slots
        term isa IRIRef || continue
        t = get(variables, term.value, nothing)
        t === nothing || push!(out, t)
    end
    return out
end

"""
    load_enums(graphs; ep = endpoint()) -> Dict{String,Vector{RDFTerm}}

Every enumerated variable *occurring in `graphs`*, with the values `gistp:oneOf` allows it.

`gistp:oneOf` points at an `rdf:List`, walked here with a property path. The members come
back sorted rather than in list order: `VALUES` is a set of solutions, so authored order has
no semantics, and sorting is what keeps compiled output byte-stable.
"""
function load_enums(graphs::AbstractVector; ep::SparqlEndpoint=endpoint())
    rows = select(
        """
SELECT DISTINCT ?v ?val WHERE {
  ?v a <$C_SPARQLVAR> ;
     <$P_ONEOF>/<$RDF_REST>*/<$RDF_FIRST> ?val .
  $(_occurs_in(graphs))
}""";
        ep=ep,
    )
    # Declared enumerations are collected separately from their members, so an empty list
    # is distinguishable from no list at all. gistp:oneOf () is rdf:nil: the property path
    # below matches nothing, and without this the variable would come back merely
    # un-enumerated and be diagnosed later as an unbound variable -- pointing the author at
    # a typo rather than at the truncated list they actually wrote.
    declared = select(
        """
SELECT DISTINCT ?v WHERE {
  ?v a <$C_SPARQLVAR> ; <$P_ONEOF> ?list .
  $(_occurs_in(graphs))
}""";
        ep=ep,
    )
    out = Dict{String,Vector{RDFTerm}}(_iri(r["v"]) => RDFTerm[] for r in declared)
    for r in rows
        push!(get!(out, _iri(r["v"]), RDFTerm[]), r["val"])
    end
    for vs in values(out)
        sort!(vs; by=sparql_text)
        unique!(vs)
    end
    return out
end

"The negative-condition graph IRIs of one rule, sorted so compiled output is stable."
function load_nac_graphs(rule_iri::AbstractString; ep::SparqlEndpoint=endpoint())
    rows = select(
        """
SELECT ?n WHERE { <$(check_iri(rule_iri))> <$P_NAC> ?n } ORDER BY ?n""";
        ep=ep,
    )
    return sort!([_iri(r["n"]) for r in rows])
end

"""
    load_filters(rule_iri; ep = endpoint()) -> Vector{String}

Every `jhp:filterText` the rule declares, deduplicated and sorted.

Sorted by the **text**, not by the condition's node, so a filter authored as a blank node
compiles to the same bytes on every run. A `jhp:FilterCondition` carries one expression;
several conditions are conjunctive, which is what separate `FILTER`s already mean.

The `jhp:filterText` is fetched through an `OPTIONAL` rather than joined, so that a
condition carrying none is *refused* rather than dropped. An inner join would silently
return one fewer row, and a missing filter does not narrow a rule -- it widens it. That is
the loudest possible bug arriving as the quietest possible symptom, and it is the mirror of
the empty guard, which is skipped precisely because an empty `FILTER NOT EXISTS` can never
fail.
"""
function load_filters(rule_iri::AbstractString; ep::SparqlEndpoint=endpoint())
    rows = select(
        """
SELECT ?f ?t WHERE {
  <$(check_iri(rule_iri))> <$P_FILTER> ?f .
  OPTIONAL { ?f <$P_FILTERTEXT> ?t }
}""";
        ep=ep,
    )
    out = String[]
    for r in rows
        haskey(r, "t") || error(
            "rule <$rule_iri>: jhp:hasFilterCondition names $(sparql_text(r["f"])), which " *
            "declares no jhp:filterText. A condition with no expression would compile to " *
            "no FILTER at all, so the rule would silently match MORE than it says, not " *
            "less. Give it a jhp:filterText or drop the jhp:hasFilterCondition.",
        )
        t = r["t"]
        t isa RDFLiteral || error(
            "rule <$rule_iri>: jhp:filterText is $(sparql_text(t)), which is not a " *
            "literal. A filter condition is a SPARQL expression written as a string.",
        )
        is_var_literal(t) && error(
            "rule <$rule_iri>: jhp:filterText is the variable $(repr(t.lexical)), which " *
            "nothing in a rule binds. A condition is fixed when the rule is authored.",
        )
        push!(out, t.lexical)
    end
    return sort!(unique!(out))
end

"""
    load_bindings(rule_iri; ep = endpoint()) -> (Vector{BindingSpec}, Dict{String,String})

Every `jhp:hasBinding` of a rule, and the `gistp:variableText` of each variable they bind.

The variables are returned separately because nothing else would find them: a bound
variable need not occur in any pattern graph -- it may feed only a mint slot, or only R as a
`"?x"^^gistp:var` literal -- so `load_variables` cannot be relied on to have seen it. The
caller merges them into the spec's variables, where `check_variables` validates them like
any other.

Each field is fetched with `OPTIONAL` and then checked, for the reason `load_filters` does:
a join would drop an incomplete binding silently, and a dropped binding leaves R using a
variable nothing binds -- which `check_bound` would then blame on the wrong thing.
"""
function load_bindings(rule_iri::AbstractString; ep::SparqlEndpoint=endpoint())
    rows = select(
        """
SELECT ?b ?t ?v ?vt WHERE {
  <$(check_iri(rule_iri))> <$P_HASBINDING> ?b .
  OPTIONAL { ?b <$P_BINDTEXT> ?t }
  OPTIONAL { ?b <$P_BINDSVAR> ?v . OPTIONAL { ?v <$P_VARIABLETEXT> ?vt } }
}""";
        ep=ep,
    )
    out = BindingSpec[]
    vars = Dict{String,String}()
    for (b, rs) in _group_by(r -> sparql_text(r["b"]), rows)
        texts = unique(r["t"] for r in rs if haskey(r, "t"))
        targets = unique(r["v"] for r in rs if haskey(r, "v"))
        length(texts) == 1 || error(
            "rule <$rule_iri>: binding $b declares $(length(texts)) jhp:bindText values; " *
            "exactly one is required. A binding with no expression binds nothing, and R " *
            "would use a variable no clause produces.",
        )
        length(targets) == 1 || error(
            "rule <$rule_iri>: binding $b names $(length(targets)) jhp:bindsVariable " *
            "values; exactly one is required -- a BIND assigns one variable.",
        )
        t, v = only(texts), only(targets)
        t isa RDFLiteral && !is_var_literal(t) || error(
            "rule <$rule_iri>: binding $b has jhp:bindText $(sparql_text(t)), which is not " *
            "an expression string. Write the SPARQL expression as a plain literal.",
        )
        v isa IRIRef || error(
            "rule <$rule_iri>: binding $b binds $(sparql_text(v)), which is not a declared " *
            "variable. Name a gistp:LiteralVariable individual, as gistp:slotValue does.",
        )
        vts = unique(r["vt"] for r in rs if haskey(r, "vt"))
        length(vts) == 1 || error(
            "rule <$rule_iri>: binding $b binds <$(v.value)>, which declares " *
            "$(length(vts)) gistp:variableText values. Declare it as a gistp:SparqlVariable " *
            "with exactly one.",
        )
        # Keyed by its SPARQL text: a binding is typically a blank node, as a filter
        # condition is, and has no other identity to give.
        push!(out, BindingSpec(b, v.value, t.lexical))
        vars[v.value] = (only(vts)::RDFLiteral).lexical
    end
    return sort!(out; by=b -> (b.variable, b.iri)), vars
end


"Group rows by a key, preserving first-seen order, as `key => rows` pairs."
function _group_by(f, rows)
    order = String[]
    groups = Dict{String,Vector{Any}}()
    for r in rows
        k = f(r)
        haskey(groups, k) || push!(order, k)
        push!(get!(groups, k, Any[]), r)
    end
    return [k => groups[k] for k in order]
end

"A rule's declared application strategy, or `nothing` if it states none."
function load_strategy(rule_iri::AbstractString; ep::SparqlEndpoint=endpoint())
    rows = select("SELECT ?s WHERE { <$(check_iri(rule_iri))> <$P_STRATEGY> ?s }"; ep=ep)
    isempty(rows) && return nothing
    length(rows) == 1 || error(
        "<$rule_iri> declares $(length(rows)) jhp:strategy values; at most one is allowed.",
    )
    return strategy_symbol(_iri(rows[1]["s"]))
end

"A rule's ordering hint when several are applied as a set. Absent means 0."
function load_priority(rule_iri::AbstractString; ep::SparqlEndpoint=endpoint())
    rows = select("SELECT ?p WHERE { <$(check_iri(rule_iri))> <$P_PRIORITY> ?p }"; ep=ep)
    return isempty(rows) ? 0 : parse(Int, (rows[1]["p"]::RDFLiteral).lexical)
end

"A rule's own fixpoint budget, or `nothing` to use the caller's."
function load_max_iterations(rule_iri::AbstractString; ep::SparqlEndpoint=endpoint())
    rows = select("SELECT ?m WHERE { <$(check_iri(rule_iri))> <$P_MAXITER> ?m }"; ep=ep)
    isempty(rows) && return nothing
    n = parse(Int, (rows[1]["m"]::RDFLiteral).lexical)
    n >= 1 || error(
        "<$rule_iri>: jhp:maxIterations is $n. A budget below 1 cannot be satisfied by " *
        "any run; JayhawkPatternShapes.ttl RuleShape rejects it -- validate first.",
    )
    return n
end

"""
    load_in_graph(pattern_iri; ep = endpoint()) -> Union{String,Nothing}

The `jhp:inGraph` of one pattern: the IRI of a graph variable or of a constant graph.

Unlike a pattern's triples, this lives in the **default** graph -- it is a statement *about*
the pattern, not part of it -- which is why it needs its own query and why the variable it
names has to be fed to [`load_variables`](@ref) explicitly. See [`_occurs_in`](@ref).
"""
function load_in_graph(pattern_iri::AbstractString; ep::SparqlEndpoint=endpoint())
    rows = select("SELECT ?g WHERE { <$(check_iri(pattern_iri))> <$P_INGRAPH> ?g }"; ep=ep)
    isempty(rows) && return nothing
    length(rows) == 1 || error(
        "pattern <$pattern_iri> declares $(length(rows)) jhp:inGraph values; at most one " *
        "is allowed. A pattern is evaluated in one graph. JayhawkPatternShapes.ttl " *
        "SparqlPatternShape enforces this -- validate first.",
    )
    g = rows[1]["g"]
    g isa IRIRef || error(
        "pattern <$pattern_iri>: jhp:inGraph is $(sparql_text(g)), which is not an IRI. " *
        "A graph name is an IRI -- either a declared gistp:SparqlVariable or a constant " *
        "graph. No literal can name a graph, so there is no \"?g\"^^gistp:var reading here " *
        "as there is for gistp:slotValue.",
    )
    return check_iri(g.value)
end

"Fetch the triples of one pattern graph, sorted so output is reproducible."
function load_pattern(graph_iri::AbstractString; ep::SparqlEndpoint=endpoint())
    rows = select(
        """
SELECT ?s ?p ?o WHERE { GRAPH <$(check_iri(graph_iri))> { ?s ?p ?o } }""";
        ep=ep,
    )
    ts = [PatternTriple(r["s"], r["p"], r["o"]) for r in rows]
    # SPARQL solution order is unspecified. Sorting here is what makes compiled output
    # byte-stable across stores and runs, which is what makes golden-file tests possible.
    return sort!(
        ts;
        by=t -> (sparql_text(t.subject), sparql_text(t.predicate), sparql_text(t.object)),
    )
end

"""
    _occurs_in(graphs) -> String

A SPARQL group matching when `?v` occupies *any* position in *any* of `graphs`.

This is what scopes a rule's declarations to that rule. A variable is an ordinary IRI that
happens to be declared a `gistp:SparqlVariable`, so it can appear as subject, predicate or
object; all three have to be looked for, and the position variables are suffixed per graph
so two alternatives never accidentally share one.

**A fourth position, off to one side.** A *graph* variable occupies no position inside any
pattern graph: it is named by `<pattern> jhp:inGraph <var>` in the **default** graph. Left
to the three alternatives above it would never be discovered, `var_of` would return nothing,
and [`term_sparql`](@ref) would emit it as a bare IRI -- `GRAPH <…:_Book>`, a constant naming
a graph nobody created. The rule would compile, validate, run, and match nothing, with no
error anywhere. The fourth alternative below is what stops that.

**And a fifth.** A `gistp:LiteralVariable` occupies no position either. Inside a pattern the
variable is still the literal `"?idText"^^gistp:var` -- an IRI there would stop the pattern
being valid domain data -- so the declaration is reachable only as the object of a
`gistp:slotValue` in the default graph. Without the fifth alternative `load_variables` never
sees it, `var_of` returns nothing, and [`check_mints`](@ref) refuses a slot that is in fact
correctly bound. That failure is loud rather than silent, which is the better half of the
bargain, but it refuses valid rules. The alternative is scoped through the *minted* variable
that owns the slot, because that one does occupy a position -- constructing it is what
putting it in R means.

**What is still not reachable.** A `gistp:LiteralVariable` used only in an ordinary object
position, and named by no slot, is bound to its use by lexical form alone. Finding it would
mean joining `gistp:variableText` against the literals inside the pattern graphs -- a
string match, and the one the language works to avoid elsewhere. Nothing needs it yet:
`gistp:requiresDatatype` is compiler-side metadata the engine does not read, and
`gistp:oneOf` on such a variable would need it. Add a sixth alternative then, not before.
"""
function _occurs_in(graphs)
    return string(
        join(
            (
                "{ GRAPH <$(check_iri(g))> { { ?v ?p$i ?o$i } UNION { ?s$i ?v ?o$i } " *
                "UNION { ?s$i ?p$i ?v } } }" for (i, g) in enumerate(graphs)
            ),
            "\n          UNION ",
        ),
        if isempty(graphs)
            ""
        else
            "\n          UNION { VALUES ?pat { " *
            join(("<$(check_iri(g))>" for g in graphs), " ") *
            " } ?pat <$P_INGRAPH> ?v }"
        end,
        if isempty(graphs)
            ""
        else
            "\n          UNION { VALUES ?spat { " *
            join(("<$(check_iri(g))>" for g in graphs), " ") *
            " } GRAPH ?spat { { ?mv ?mp ?mo } UNION { ?ms ?mv ?mo } UNION { ?ms ?mp ?mv } } " *
            "?mv <$P_HASSLOT> ?mslot . ?mslot <$P_SLOTVALUE> ?v }"
        end,
    )
end

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
function load_variables(graphs::AbstractVector; ep::SparqlEndpoint=endpoint())
    rows = select(
        """
SELECT DISTINCT ?v ?t WHERE {
  ?v a <$C_SPARQLVAR> ; <$P_VARIABLETEXT> ?t .
  $(_occurs_in(graphs))
}""";
        ep=ep,
    )
    return Dict{String,String}(_iri(r["v"]) => (r["t"]::RDFLiteral).lexical for r in rows)
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
*graph* variable is: `jhp:inGraph` is a statement about the pattern, so it sits in the
default graph and its object occupies no position inside any pattern. [`_occurs_in`](@ref)
carries a fourth alternative for exactly that case.
"""
function load_mints(graphs::AbstractVector; ep::SparqlEndpoint=endpoint())
    # Two spellings of one thing. A variable carries its own gistp:iriTemplate, or it names a
    # gistp:MintingFunction with gistp:isMintedBy, whose gistp:namespace + gistp:localTemplate
    # IS the template. Both are read here and nowhere else, so every consumer downstream --
    # the BIND, the collision gate, the fan-in report, undo -- sees one MintSpec and needs no
    # second code path.
    rows = select(
        """
SELECT DISTINCT ?v ?tmpl ?fn ?ns ?local ?name ?value WHERE {
  ?v a <$C_SPARQLVAR> .
  { ?v <$P_IRITEMPLATE> ?tmpl }
  UNION
  { ?v <$P_ISMINTEDBY> ?fn .
    OPTIONAL { ?fn <$P_NAMESPACE> ?ns }
    OPTIONAL { ?fn <$P_LOCALTEMPLATE> ?local } }
  $(_occurs_in(graphs))
  OPTIONAL { ?v <$P_HASSLOT> ?slot .
             ?slot <$P_SLOTNAME> ?name ; <$P_SLOTVALUE> ?value . }
}""";
        ep=ep,
    )
    out = Dict{String,MintSpec}()
    for (v, rs) in _group_by(r -> _iri(r["v"]), rows)
        vals(k) = unique(r[k] for r in rs if haskey(r, k))
        tmpls, fns = vals("tmpl"), vals("fn")
        !isempty(tmpls) && !isempty(fns) && error(
            "<$v> both carries a gistp:iriTemplate and names a gistp:MintingFunction with " *
            "gistp:isMintedBy. They are two spellings of one template, so which IRI it mints " *
            "would be a guess. Keep one.",
        )
        template, fn = if !isempty(tmpls)
            length(tmpls) == 1 || error(
                "<$v> carries $(length(tmpls)) gistp:iriTemplate values; exactly one is " *
                "allowed. With several, which one it minted from would depend on the order " *
                "the store returned them in.",
            )
            (only(tmpls)::RDFLiteral).lexical, nothing
        else
            length(fns) == 1 || error(
                "<$v> names $(length(fns)) gistp:MintingFunction values with " *
                "gistp:isMintedBy; exactly one is allowed.",
            )
            f = only(fns)
            f isa IRIRef || error(
                "<$v>: gistp:isMintedBy is $(sparql_text(f)), which is not a " *
                "gistp:MintingFunction IRI.",
            )
            minting_function_template(f.value, vals("ns"), vals("local")), f.value
        end
        m = MintSpec(v, template, Dict{String,RDFTerm}(), fn)
        for r in rs
            haskey(r, "name") && haskey(r, "value") &&
                (m.slots[(r["name"]::RDFLiteral).lexical] = r["value"])
        end
        out[v] = m
    end
    return out
end

"""
    minting_function_template(fn, namespaces, locals) -> String

The RFC 6570 template a `gistp:MintingFunction` denotes: its `gistp:namespace` followed by
its `gistp:localTemplate`, verbatim.

Verbatim, and that is the whole contract. A namespace ending in neither `/` nor `#` is the
author's business -- `http://ex/data_` + `{id}` is a legitimate convention -- and the result
goes through every check an authored `iriTemplate` does, so an unusable one is refused there
with the same message. What only a function can get wrong is refused here:

  * **exactly one of each.** A function with two namespaces mints two different IRIs for one
    binding, depending on which the store returns first.
  * **a namespace with no slot.** The namespace is the fixed part; a `{` in it would make
    the split between constant and template meaningless, and a reader would take the slot
    for a typo in either half.
  * **a literal of either form.** `gistp:namespace` ranges over `xsd:anyURI` or `xsd:string`;
    a namespace given as an IRI rather than a literal is accepted too, as the obvious intent.
"""
function minting_function_template(fn::AbstractString, namespaces, locals)
    length(namespaces) == 1 || error(
        "gistp:MintingFunction <$fn> declares $(length(namespaces)) gistp:namespace values; " *
        "exactly one is required -- it is the fixed part of every IRI the function mints.",
    )
    length(locals) == 1 || error(
        "gistp:MintingFunction <$fn> declares $(length(locals)) gistp:localTemplate " *
        "values; exactly one is required -- it is the part of the IRI the slots fill.",
    )
    ns, local_ = only(namespaces), only(locals)
    nstext = ns isa IRIRef ? ns.value : (ns::RDFLiteral).lexical
    local_ isa RDFLiteral || error(
        "gistp:MintingFunction <$fn>: gistp:localTemplate is $(sparql_text(local_)), which " *
        "is not a string.",
    )
    (occursin('{', nstext) || occursin('}', nstext)) && error(
        "gistp:MintingFunction <$fn>: gistp:namespace $(repr(nstext)) contains a brace. The " *
        "namespace is the constant part of the IRI; slots belong in gistp:localTemplate.",
    )
    return nstext * local_.lexical
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
    return nothing
end

"Render one term in a BGP: its variable name if it is one, else its constant syntax."
function term_sparql(t::RDFTerm, spec::RuleSpec)
    v = var_of(t, spec)
    v === nothing || return v
    t isa IRIRef && check_iri(t.value)
    return sparql_text(t)
end

"Render a list of pattern triples as a Basic Graph Pattern."
function bgp_text(ts::Vector{PatternTriple}, spec::RuleSpec; indent::AbstractString="  ")
    # Sorted HERE, not only in load_pattern. "Same spec, same bytes" has to hold for every
    # RuleSpec however it was built -- including one an MCP client hands in -- and a BGP is
    # a set, so the order it was written in carries no meaning to preserve.
    lines = (
        "$indent$(term_sparql(t.subject, spec)) $(term_sparql(t.predicate, spec)) " *
        "$(term_sparql(t.object, spec)) ." for t in ts
    )
    return join(sort(collect(lines)), "\n")
end

"Every distinct SPARQL variable appearing anywhere in a pattern."
function vars_in(ts::Vector{PatternTriple}, spec::RuleSpec)
    s = Set{String}()
    for t in ts, pos in (t.subject, t.predicate, t.object)
        v = var_of(pos, spec)
        v === nothing || push!(s, v)
    end
    return s
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
            close_at === nothing &&
                throw(ArgumentError("unterminated '{' in iriTemplate $(repr(String(t)))"))
            name = t[nextind(t, i):prevind(t, close_at)]
            isempty(name) && throw(
                ArgumentError("empty {} expression in iriTemplate $(repr(String(t)))")
            )
            if !occursin(r"^[a-zA-Z_][a-zA-Z0-9_]*$", name)
                op = first(name)
                op in ('+', '#', '.', '/', ';', '?', '&') && throw(
                    ArgumentError(
                        "iriTemplate $(repr(String(t))) uses the RFC 6570 operator '$op' in " *
                        "{$name}. Only Level 1 ({name}) is supported: Level 2 reserved " *
                        "expansion would need an encoding SPARQL cannot express exactly.",
                    ),
                )
                throw(
                    ArgumentError(
                        "{$name} is not a legal RFC 6570 Level 1 expression in iriTemplate " *
                        "$(repr(String(t)))",
                    ),
                )
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
    return parts
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
    for i in 1:(length(parts) - 1)
        parts[i][1] === :slot || continue
        if parts[i + 1][1] === :slot
            push!(bad, "")                                  # {a}{b}
        elseif i + 2 <= length(parts) && parts[i + 2][1] === :slot
            sep = parts[i + 1][2]
            occursin(UNRESERVED_ONLY, sep) && push!(bad, sep)
        end
    end
    return bad
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
    #
    # L's *graph* variable counts too. It is bound by the GRAPH clause rather than by any
    # triple, so `vars_in` cannot see it, and without `scope_vars` a template minting one
    # node per graph -- the obvious thing to want from `jhp:inGraph` -- was refused with a
    # message about minting from another minted variable, which it is not. This is only safe
    # now that `match_text` scopes the collision and fan-in queries too: while those built an
    # unscoped L, a mint keyed on the graph variable would have been checked against a query
    # in which that variable was unbound.
    #
    # A source-mapped variable counts too, and this is the join the feature exists for: an
    # iriTemplate minting a node per row reads the id COLUMN, which the match pattern never
    # mentions. Without this, the obvious thing to want from a source map is refused with a
    # message about minting from another minted variable, which it is not.
    # A binding is emitted before the mints, so a slot may read one: that is how a template
    # mints from a slug, a normalised key or a hash rather than from a raw value.
    bound = union(pre_bound(spec), binding_vars(spec))
    for (iri, m) in spec.mints
        text = get(spec.variables, iri, nothing)
        text === nothing && error(
            "rule <$(spec.iri)>: minted variable <$iri> has a gistp:iriTemplate but no " *
            "gistp:variableText, so there is no SPARQL variable to bind it to.",
        )

        occursin(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", m.template) || error(
            "rule <$(spec.iri)>: iriTemplate $(repr(m.template)) on <$iri> is relative. A " *
            "template expands to an absolute IRI; a bare local part leaves the minting " *
            "namespace implicit, which silently mints into whichever namespace the rule " *
            "document's empty prefix happens to name.",
        )

        wanted_now = template_slots(m.template)
        isempty(wanted_now) && error(
            "rule <$(spec.iri)>: iriTemplate $(repr(m.template)) on <$iri> has no {slot}, " *
            "so it expands to the same IRI for every match and collapses every solution " *
            "onto one node. If a single fixed node is what you want, write that IRI " *
            "directly in the construct pattern -- a template with nothing to substitute " *
            "buys nothing and reads as a mistake.",
        )

        amb = ambiguous_separators(m.template)
        isempty(amb) || error(
            "rule <$(spec.iri)>: iriTemplate $(repr(m.template)) on <$iri> separates slots " *
            "with $(join((isempty(s) ? "nothing at all" : repr(s) for s in amb), ", ")). " *
            "ENCODE_FOR_URI leaves the unreserved characters -._~ and alphanumerics alone, " *
            "so such a separator cannot be told apart from the same characters inside a " *
            "value: \"x_y\"+\"z\" and \"x\"+\"y_z\" both expand to x_y_z, silently merging " *
            "two different things into one node. Separate slots with a character the " *
            "encoder escapes: ':' is the one that stays legal unescaped in a Turtle local " *
            "name, so the minted IRI still abbreviates; '/' also works but forces every " *
            "serialiser back to <angle brackets>.",
        )

        wanted = Set(template_slots(m.template))
        given = Set(keys(m.slots))
        missing_slots = setdiff(wanted, given)
        isempty(missing_slots) || error(
            "rule <$(spec.iri)>: iriTemplate $(repr(m.template)) on <$iri> has no binding " *
            "for $(join(("{$s}" for s in sort(collect(missing_slots))), ", ")). Add a " *
            "gistp:hasSlot with that gistp:slotName.",
        )
        extra = setdiff(given, wanted)
        isempty(extra) || error(
            "rule <$(spec.iri)>: <$iri> binds slot(s) $(join(sort(collect(extra)), ", ")) " *
            "that iriTemplate $(repr(m.template)) does not contain.",
        )

        for name in sort(collect(wanted))
            v = var_of(m.slots[name], spec)
            v === nothing && error(
                "rule <$(spec.iri)>: slot {$name} of <$iri> is bound to " *
                "$(sparql_text(m.slots[name])), which is not a variable. A gistp:slotValue " *
                "must be an IRI naming a declared gistp:SparqlVariable -- for a value read " *
                "from a literal position, a gistp:LiteralVariable. The literal form " *
                "\"?x\"^^gistp:var was withdrawn once literal-position variables could be " *
                "declared.",
            )
            v in bound || error(
                "rule <$(spec.iri)>: slot {$name} of <$iri> is bound to $v, which the match " *
                "pattern never binds and no jhp:hasBinding computes. Minting from another " *
                "minted variable is not supported; to mint from a computed value -- a slug, " *
                "a normalised key, a hash -- declare a jhp:hasBinding and name its variable.",
            )
        end

        # Only what L (with VALUES, scopes and source maps) binds. A BINDING that targets a
        # minted variable is a different mistake, and check_bindings names it as one.
        text in pre_bound(spec) && error(
            "rule <$(spec.iri)>: <$iri> carries a gistp:iriTemplate, which declares it " *
            "minted, but the match pattern also binds $text. A variable is either " *
            "constructed or matched, not both -- if L already binds it, R reuses the " *
            "matched IRI and the template is dead. Remove one.",
        )
    end
    return spec
end

"The SPARQL variable names produced by minting."
function minted_vars(spec::RuleSpec)
    return Set(
        spec.variables[iri] for iri in keys(spec.mints) if haskey(spec.variables, iri)
    )
end

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
    return "  BIND(IRI(CONCAT($(join(pieces, ", ")))) AS $(spec.variables[m.variable]))"
end

"Every BIND a rule needs, ordered by variable name so output stays byte-stable."
function binds_text(spec::RuleSpec)
    isempty(spec.mints) && return ""
    lines = [bind_text(spec.mints[iri], spec) for iri in sort(collect(keys(spec.mints)))]
    return "\n" * join(lines, "\n")
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
        body = if n.scope === nothing
            bgp_text(n.triples, spec; indent="    ")
        else
            graph_wrap(bgp_text(n.triples, spec; indent="      "), n.scope, spec; indent="    ")
        end
        push!(blocks, "  # NOT <$(n.graph)>\n  FILTER NOT EXISTS {\n" * body * "\n  }")
    end
    return isempty(blocks) ? "" : "\n" * join(blocks, "\n")
end

"""
    filters_text(spec) -> String

Every filter condition, as its own `FILTER(...)`.

Conjunctive, like the negative conditions above: separate filters is exactly what "all of
these must hold" means, and it keeps one failing expression readable in a query log instead
of buried in a chain of `&&`.

Sorted **here** rather than only in [`load_filters`](@ref). Byte-stability is a property of
compilation, not of one way of building a spec: conditions are typically authored as blank
nodes, which have no stable identity, so nothing upstream can be relied on to fix an order.
Filters are conjunctive, so sorting changes no result.
"""
function filters_text(spec::RuleSpec)
    isempty(spec.filters) && return ""
    return "\n" * join(("  FILTER($f)" for f in sort(spec.filters)), "\n")
end

"""
    load_services(scopes; ep = endpoint()) -> Dict{String,Vector{Pair{String,String}}}

Which of a rule's `jhp:inGraph` scopes name a **data source** rather than a graph, and the
`fx:` properties each carries.

`jhp:inGraph` already reads two ways, and which one you get is decided by what the value
IS rather than by separate vocabulary: a declared `gistp:SparqlVariable` is a graph variable,
any other IRI a constant graph. This is the third reading, decided the same way — an IRI
typed `gistp:TabularDataSource` names a *file*, and a pattern scoped to it compiles to
`SERVICE <x-sparql-anything:>` rather than `GRAPH`. The discriminator is a type assertion in
the data, not a guess at the IRI's scheme, so it is answerable by the same SHACL that
validates everything else and a typo cannot silently become a graph nobody created.

A data source contributes **no dataset clause**. A SERVICE is evaluated outside the query's
dataset, so `USING`/`USING NAMED` must not name it and [`is_scoped`](@ref) must not count it
— which is also what lets an extraction rule run with an empty `source`, since there is no
graph to name.

The properties are emitted verbatim, sorted by predicate so the compiled text is byte-stable.
Nothing here interprets them: `fx:csv.headers`, `fx:null-string` and the rest are SPARQL
Anything's business, and a vocabulary of its options in `gistp:` would go stale the moment
that project added one.
"""
function load_services(scopes::AbstractVector; ep::SparqlEndpoint=endpoint())
    out = Dict{String,Vector{Pair{String,String}}}()
    for s in unique(scopes)
        rows = select(
            """
  SELECT ?p ?o WHERE {
    <$(check_iri(s))> a <$C_TABULARSOURCE> ; ?p ?o .
    FILTER(STRSTARTS(STR(?p), "$FX_NS"))
  }""";
            ep=ep,
        )
        isempty(rows) && continue
        props = Pair{String,String}[]
        for r in rows
            p, o = _iri(r["p"]), r["o"]
            o isa RDFLiteral || error(
                "data source <$s>: <$p> is $(sparql_text(o)), which is not a literal. " *
                "SPARQL Anything's fx: options take literal values.",
            )
            is_var_literal(o) && error(
                "data source <$s>: <$p> is the variable $(repr(o.lexical)), which nothing " *
                "in a rule binds. A location is fixed when the rule is authored; supplying " *
                "one at invocation is a parameter mechanism this engine does not have.",
            )
            push!(props, p => o.lexical)
        end
        sort!(props; by=first)
        any(((p, _),) -> p == P_FX_LOCATION, props) || error(
            "data source <$s> is a gistp:TabularDataSource with no fx:location, so there " *
            "is no file for the SERVICE to read.",
        )
        out[s] = props
    end
    return out
end

"""
    all_scopes(spec) -> Vector{String}
    graph_scopes(spec) -> Vector{String}

Every `jhp:inGraph` a rule declares, and the subset of those that name a graph rather than
a data source. The split matters because only the latter belong in a dataset clause.
"""
function all_scopes(spec::RuleSpec)
    return String[
        s for
        s in (match_scopes(spec)..., spec.construct_scope, (n.scope for n in spec.nacs)...) if
        s !== nothing
    ]
end

function graph_scopes(spec::RuleSpec)
    return String[s for s in all_scopes(spec) if !haskey(spec.services, s)]
end

"""
    read_scopes(spec) -> Vector{String}

The graph scopes a rule READS through: `jhp:inGraph` on the match pattern and on each
negative condition, minus any data source.

Separate from [`write_scope`](@ref) because the two have opposite requirements, and
conflating them is what made every scoped rule look dangerous. A scoped *read* with no
`source` is genuinely unsafe -- with no dataset clause a graph variable ranges over every
named graph in the store, provenance and firings included. A scoped *write* reads nothing it
was not already reading, so it needs no such guarantee.
"""
function read_scopes(spec::RuleSpec)
    return String[
        s for s in (match_scopes(spec)..., (n.scope for n in spec.nacs)...) if
        s !== nothing && !haskey(spec.services, s)
    ]
end

"""
    write_scope(spec) -> Union{String,Nothing}

The constant graph IRI a rule's construct pattern declares as its destination, or `nothing`.

The destination is **not** part of compilation: `insert_query` still projects `R` into a
fresh firing graph, exactly as an unscoped rule does, and the scope is consumed afterwards by
[`promote_query`](@ref). That split is what keeps the firing graph the unit of attribution and
undo even when a rule writes into live data.
"""
write_scope(spec::RuleSpec) = spec.construct_scope

"""
    promote_query(; firing, target) -> String

Copy a pruned firing graph into the graph its rule declared with `jhp:inGraph`.

Applied from the firing graph rather than from `R`'s template, so the destination receives
exactly what the firing graph claims -- which is what makes `undo_firing!` an exact inverse
rather than a re-derivation that might differ.

**No dataset clause, and that is an invariant rather than an omission.** `USING`/`USING NAMED`
*replace* the dataset, so a graph absent from the clause is invisible even to a
`GRAPH <constant>` in the `WHERE`: splice one in and this op silently copies nothing while
reporting success. `rewrite_query`'s promotion op carries the same warning for the same
reason, and both are asserted in the suite.
"""
function promote_query(; firing::AbstractString, target::AbstractString)
    return """
           INSERT { GRAPH <$(check_iri(target))> { ?__s ?__p ?__o } }
           WHERE  { GRAPH <$(check_iri(firing))> { ?__s ?__p ?__o } }
           """
end

"""
    is_scoped(spec) -> Bool

Whether any of a rule's patterns names a **graph**. Decides the shape of the dataset clause.

A scope naming a `gistp:TabularDataSource` does not count: it compiles to a SERVICE, which is
evaluated outside the dataset entirely, so naming it in `USING NAMED` would be meaningless and
demanding a non-empty `source` for it would be wrong.
"""
is_scoped(spec::RuleSpec) = !isempty(graph_scopes(spec))

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
function dataset_lines(
    spec::RuleSpec, from::AbstractVector; keyword::AbstractString="USING"
)
    if isempty(from)
        # `run_rule` refuses this too, and used to be the only thing that did -- but the
        # hazard lives in the query, not in the driver. `apply_rule`, `dry_run`,
        # `check_collisions` and `mint_fanin` are all public, all reach a builder directly,
        # and all skipped that guard. With no dataset clause a graph variable ranges over
        # every named graph in the store, so `dry_run` on the round-5a fixture returned four
        # triples instead of three, the extra one asserting the rule's OWN pattern graph as
        # data; `apply_rule` wrote it and recorded it as a legitimate firing. Measured.
        # READ scopes only. A write scope names a destination that never appears in the
        # query -- `promote_query` consumes it afterwards -- so it neither needs a dataset
        # clause nor enumerates anything. Keying this off every scope made a rule that only
        # declared where its output goes unrunnable against the default graph, for a hazard
        # it does not have.
        isempty(read_scopes(spec)) || error(
            "rule <$(spec.iri)>: a rule whose match pattern or negative condition carries " *
            "jhp:inGraph must name its graphs. With no " *
            "dataset clause a graph variable ranges over every named graph in the store -- " *
            "the provenance graph, every firing, every tombstone, and the rule catalogue's " *
            "own pattern graphs. An empty graph set is not 'the default graph' here, it is " *
            "everything. Pass `source`/`from` naming the graphs to read.",
        )
        return ""
    end
    plain = join(("$keyword <$(check_iri(g))>" for g in from), "\n")
    isempty(read_scopes(spec)) && return plain * "\n"
    return plain *
           "\n" *
           join(("$keyword NAMED <$(check_iri(g))>" for g in from), "\n") *
           "\n"
end

"""
    where_body(spec) -> String

The whole of a rule's WHERE clause: match triples, then VALUES, then BINDs, then negative
conditions, then filter conditions.

The order is load-bearing and is the reason this is one function rather than five copies.
`VALUES` comes first among the additions because a `BIND` may mint from an enumerated value.
BIND sees only variables bound earlier in its group, so it must follow the triple patterns.
`FILTER NOT EXISTS` must follow the BINDs in turn, because a condition is allowed to mention
a *minted* variable -- "only create this if it does not already exist" -- and the filter can
only test what is bound by the time it runs. A plain `FILTER` is last for the same reason,
and because a reader looking for why a rule declined wants the cheap scalar tests together.
Filter and `FILTER NOT EXISTS` are both conjunctive constraints on the same group, so their
relative order changes no result -- only which one a query log blames first.

**`jhp:inGraph` scopes the triples, not the clause.** Wrapping the finished string in one
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
function where_body(spec::RuleSpec)
    return string(
        match_text(spec),
        # Before VALUES and BIND, both of which may read a mapped value: a minted IRI built
        # from a column has to see the cleaned string, not the raw cell. And after the match,
        # because `apf:strSplit` joins over values the SERVICE has already produced.
        pre_mint_text(spec),
        binds_text(spec),
        nacs_text(spec),
        filters_text(spec),
    )
end

"""
    pre_mint_text(spec) -> String

Everything a rule evaluates between its match and its mints: the source-map pipeline, the
`VALUES` clauses, then the bindings -- in that order, because each may read the one before.

**One text, three callers.** `where_body` is what runs; [`collision_queries`](@ref) and
[`mint_fanin`](@ref) re-evaluate the mints to check them. Those two used to embed L and the
mint `BIND` and nothing between, so a template slot fed by a `gistp:oneOf` value or a source
map column was *unbound* in the check: its key yielded nothing, `COUNT(DISTINCT …)` was 0,
and the collision gate passed by construction. A slot fed by a binding would have joined
them. Built once, here, so the checks evaluate the rule that runs.
"""
function pre_mint_text(spec::RuleSpec)
    return string(source_map_pipeline(spec), values_text(spec), bindings_text(spec))
end

"""
    match_text(spec; indent = "  ") -> String

L's triples, wrapped in `GRAPH …` if the match pattern carries `jhp:inGraph`.

**One decision, one place.** `where_body` is not the only function that embeds L: so do
[`collision_queries`](@ref) and [`mint_fanin`](@ref), and both used to call `bgp_text`
directly. For a scoped rule that made the query those two ask the store a *different rule*
from the one that runs -- their `?g` was never bound, so `ENCODE_FOR_URI(STR(?g))` yielded
unbound, `COUNT(DISTINCT ?__ctx)` was 0, and `HAVING (… > 1)` could never fire. The fan-in
report was silently empty by construction for exactly the rules that most need it: the ones
whose R mentions the graph they matched in. Measured against Fuseki before and after.

An unscoped rule renders byte-identically to the old `bgp_text` call, which is what keeps
the golden snapshot honest.
"""
function match_text(spec::RuleSpec; indent::AbstractString="  ")
    # Several match patterns: each renders in its own graph and the groups simply follow one
    # another, which in SPARQL is a join -- the conjunction L means. A part with no scope
    # renders bare and so reads the default graph, which a scoped rule's dataset clause makes
    # the merge of every source graph. Source maps are refused on this path by
    # `check_match_parts`, so there is nothing generated to place.
    isempty(spec.match_parts) || return join(
        (
            if p.scope === nothing
                bgp_text(p.triples, spec; indent=indent)
            else
                graph_wrap(
                    bgp_text(p.triples, spec; indent=indent * "  "), p.scope, spec; indent=indent
                )
            end for p in spec.match_parts
        ),
        "\n",
    )
    return if spec.match_scope === nothing
        bgp_text(spec.match, spec; indent=indent)
    else
        # Source maps go INSIDE the wrapper, because the row container only exists there.
        # They are appended rather than prepended so an authored pattern renders exactly as
        # it did before any source map existed.
        # bgp_text does not end in a newline and source_map_bgp does, so the two need a
        # separator between them and none after -- graph_wrap adds its own. Getting this
        # wrong ran the last authored triple and the first generated one onto a single line,
        # which SPARQL accepts and a reader does not.
        authored = bgp_text(spec.match, spec; indent=indent * "  ")
        generated = source_map_bgp(spec; indent=indent * "  ")
        inner = if isempty(authored)
            chomp(generated)
        elseif isempty(generated)
            authored
        else
            authored * "\n" * chomp(generated)
        end
        graph_wrap(inner, spec.match_scope, spec; indent=indent)
    end
end

"""
    graph_wrap(body, scope, spec; indent = "  ") -> String

Wrap already-rendered triple text in `GRAPH <g> { … }` or `GRAPH ?g { … }`.

`scope` is an IRI, and it reads three ways -- decided here and nowhere else:

  a `gistp:TabularDataSource`    `SERVICE <x-sparql-anything:> { fx:properties … ; … }`
  a declared `SparqlVariable`    `GRAPH ?v { … }`
  anything else                  `GRAPH <iri> { … }`

The second and third are the same either/or [`term_sparql`](@ref) makes for a term, so a
graph variable goes through [`check_variables`](@ref)'s validation like every other, which is
what keeps `variableText` from being splice-injected in graph position. The first is settled
by [`load_services`](@ref) from a type assertion in the data.

The service form emits absolute IRIs throughout, including for `fx:properties` itself. That
is the engine's standing rule rather than an aesthetic choice: it never calls `makeqname`, so
there is no prefix registry for a concurrent session to corrupt.
"""
function graph_wrap(
    body::AbstractString, scope::AbstractString, spec::RuleSpec; indent::AbstractString="  "
)
    props = get(spec.services, scope, nothing)
    if props !== nothing
        opts = join(
            ("$(indent)      <$k> \"$(escape_literal(v))\"" for (k, v) in props), " ;\n"
        )
        return "$(indent)SERVICE <$SA_SERVICE> {\n" *
               "$(indent)  <$(FX_NS)properties>\n$opts .\n" *
               "$body\n$indent}"
    end
    v = get(spec.variables, scope, nothing)
    g = v === nothing ? "<$(check_iri(scope))>" : v
    return "$(indent)GRAPH $g {\n$body\n$indent}"
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
    lines = (
        "  VALUES $(spec.variables[iri]) " *
        "{ $(join(sort(member.(spec.enums[iri])), " ")) }" for
        iri in sort(collect(keys(spec.enums)))
    )
    return string("\n", join(lines, "\n"))
end

"The SPARQL variable names a `gistp:oneOf` enumeration binds."
function enum_vars(spec::RuleSpec)
    return Set(
        spec.variables[iri] for iri in keys(spec.enums) if haskey(spec.variables, iri)
    )
end

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
            "is no SPARQL variable for its VALUES clause to bind.",
        )
        isempty(spec.enums[iri]) && error(
            "rule <$(spec.iri)>: gistp:oneOf on <$iri> lists no values. That compiles to " *
            "VALUES $(spec.variables[iri]) { }, which yields no solutions, so the rule could " *
            "never fire.",
        )
        haskey(spec.mints, iri) && error(
            "rule <$(spec.iri)>: <$iri> carries both gistp:oneOf and gistp:iriTemplate. " *
            "Enumerating and constructing are contradictory: oneOf says the value is one of " *
            "these, the template says it is computed from other bindings. Choose one.",
        )
    end
    return spec
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
    graphs = [
        (("match pattern", p.graph, p.triples) for p in match_patterns(spec))...,
        ("construct pattern", spec.construct_graph, spec.construct),
        (("negative condition", n.graph, n.triples) for n in spec.nacs)...,
    ]
    for (role, graph, triples) in graphs
        labels = String[]
        for t in triples, pos in (t.subject, t.predicate, t.object)
            pos isa BNode && !(pos.id in labels) && push!(labels, pos.id)
        end
        isempty(labels) && continue

        # A precise fix beats a diagnosis. Emit the declarations to paste, and name the
        # substitution to make, rather than leaving the author to work it out.
        decls = join(
            (
                "    :_b$i a gistp:SparqlVariable ; gistp:variableText \"?_b$i\" ." *
                "      # was _:$(labels[i+1])" for i in 0:(length(labels) - 1)
            ),
            "\n",
        )
        subs = join(("_:$(labels[i+1]) -> :_b$i" for i in 0:(length(labels) - 1)), ", ")
        error(
            """
            rule <$(spec.iri)>: $role <$graph> contains $(length(labels)) blank node(s). A \
            blank node is an undeclared variable -- it cannot be validated, cannot carry \
            gistp:oneOf or gistp:iriTemplate, does not connect L to R (SPARQL will not \
            carry it from WHERE into CONSTRUCT), and is illegal outright in the DELETE \
            template a jhp:_RewriteMode_rewrite emits.

            Declare each one in the default graph:

            $decls

            then substitute in <$graph>: $subs"""
        )
    end
    return spec
end

"""
    check_match_parts(spec)

Refuse what a multi-pattern L does not support yet, and a part that means nothing. A rule
with one match pattern passes untouched.

- **An empty part.** L is a conjunction, so an empty conjunct constrains nothing and is
  almost certainly a pattern whose triples were never loaded -- a typo in its graph name.
- **`Rewrite`.** Deletion is computed from `match_only(spec)`, the union of every part's
  triples, but a rewrite deletes from its one target graph. A triple matched in a *second*
  graph would be deleted from the target, where it may never have been. Making that correct
  needs a target per part, which is the same change as write-side scope on a Rewrite.
- **Source maps.** The pipeline is generated inside the one `SERVICE` a single scoped L
  opens; with several parts there is no rule yet for which part owns the generated triples.
  Scope a part to the data source and write the Facade-X predicates by hand, or split the
  rule.
"""
function check_match_parts(spec::RuleSpec)
    isempty(spec.match_parts) && return spec
    for p in spec.match_parts
        isempty(p.triples) && error(
            "rule <$(spec.iri)>: match pattern <$(p.graph)> is empty. A rule's match patterns " *
            "are a conjunction, so an empty one constrains nothing -- most likely its triples " *
            "are in a graph with a different name.",
        )
    end
    mode_symbol(spec) === :Rewrite && error(
        "rule <$(spec.iri)>: jhp:_RewriteMode_rewrite with $(length(spec.match_parts)) match " *
        "patterns is not supported yet. A rewrite deletes L∖I from its one target graph, and " *
        "a triple matched by a second pattern -- in a second graph -- would be deleted from " *
        "the target instead of from where it was found. Use Construct or Assert, or merge " *
        "the patterns into one.",
    )
    isempty(spec.source_maps) || error(
        "rule <$(spec.iri)>: gistp:SourceMap with several match patterns is not supported " *
        "yet: the generated column triples belong inside one SERVICE, and with several " *
        "patterns nothing says which. Scope one pattern to the gistp:TabularDataSource and " *
        "name its Facade-X predicates by hand, or split the rule.",
    )
    return spec
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
    graphs = [
        (("match pattern", p.graph, p.triples) for p in match_patterns(spec))...,
        ("construct pattern", spec.construct_graph, spec.construct),
        (("negative condition", n.graph, n.triples) for n in spec.nacs)...,
    ]
    for (role, graph, triples) in graphs, t in triples
        t.subject isa RDFLiteral && error(
            "rule <$(spec.iri)>: $role <$graph> has the literal $(sparql_text(t.subject)) " *
            "as a subject. RDF has no literal subjects, so this cannot be matched or " *
            "constructed.",
        )
        t.predicate isa IRIRef || error(
            "rule <$(spec.iri)>: $role <$graph> has $(sparql_text(t.predicate)) as a " *
            "predicate. Only an IRI can be a predicate -- including a variable, which is " *
            "an IRI at pattern level.",
        )
    end
    return spec
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
            "binding. Give them different names.",
        )
        seen[text] = iri
        occursin(VARIABLE_RE, text) || error(
            "rule <$(spec.iri)>: <$iri> has gistp:variableText $(repr(text)), which is not " *
            "a legal SPARQL variable (must match $(VARIABLE_RE.pattern)). The text is " *
            "substituted into the emitted query as-is, so it has to be a variable and " *
            "nothing else -- this is the same rule a literal-position \"?x\"^^gistp:var " *
            "already has to obey.",
        )
    end
    return spec
end

# ---------------------------------------------------------------------------
# The interface I = L ∩ R
# ---------------------------------------------------------------------------

# Identity of a pattern triple, for set arithmetic. `sparql_text` renders the term as
# authored -- a variable's own IRI, not the SPARQL variable it will become -- which is
# exactly the identity the intersection is over.
function _ptkey(t::PatternTriple)
    return (sparql_text(t.subject), sparql_text(t.predicate), sparql_text(t.object))
end

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
function interface(spec::RuleSpec)
    return (
        ks=Set(_ptkey(t) for t in spec.construct);
        [t for t in spec.match if _ptkey(t) in ks]
    )
end

"L ∖ I -- the triples a `Rewrite` deletes."
function match_only(spec::RuleSpec)
    return (
        ks=Set(_ptkey(t) for t in spec.construct);
        [t for t in spec.match if !(_ptkey(t) in ks)]
    )
end

"R ∖ I -- the triples a `Rewrite` adds."
function construct_only(spec::RuleSpec)
    return (
        ks=Set(_ptkey(t) for t in spec.match);
        [t for t in spec.construct if !(_ptkey(t) in ks)]
    )
end

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
    kept = Set(_ptkey(t) for t in interface(spec))
    inR = vars_in(spec.construct, spec)
    risks = String[]
    for v in sort(collect(vars_in(spec.match, spec)))
        v in inR && continue
        # every triple of L mentioning v is being deleted?
        mentions(t) = v in
        (var_of(t.subject, spec), var_of(t.predicate, spec), var_of(t.object, spec))
        any(mentions, deleted) || continue
        any(t -> mentions(t) && _ptkey(t) in kept, spec.match) && continue
        push!(risks, v)
    end
    return risks
end

"""
    scope_vars(scope, spec) -> Set{String}

The SPARQL variable a `jhp:inGraph` names, or an empty set if it names a constant graph.

A one-element set rather than a `Union{String,Nothing}` so it composes with `vars_in`, which
is what every binding question in the compiler is phrased against.
"""
function scope_vars(scope::Union{String,Nothing}, spec::RuleSpec)
    return if scope === nothing || !haskey(spec.variables, scope)
        Set{String}()
    else
        Set([spec.variables[scope]])
    end
end

"""
    check_scopes(spec)

Refuse every use of `jhp:inGraph` this round does not implement, and every one it cannot
make safe. Each of these is otherwise a *silent* wrong answer, which is why they are errors
rather than warnings.

Round 5a scopes the read side only. Writing into a named graph needs `undo_firing!` to record
which graph each triple went to before it can be reversed, and an unreversible write is not
something to ship by omission.
"""
function check_scopes(spec::RuleSpec)
    scoped = all_scopes(spec)
    isempty(scoped) && return spec

    # A data source is readable and nothing else. The generic refusal below would catch this
    # too, but it would explain it in terms of undo records and named graphs, which is not
    # why writing into a CSV is refused.
    spec.construct_scope === nothing ||
        !haskey(spec.services, spec.construct_scope) ||
        error(
            "rule <$(spec.iri)>: jhp:inGraph on the construct pattern <$(spec.construct_graph)> " *
            "names <$(spec.construct_scope)>, a gistp:TabularDataSource. A data source is a place " *
            "to read FROM: it compiles to a SERVICE, and a SERVICE cannot be written to. Scope " *
            "the match pattern to the source and let the results land in a firing graph.",
        )

    # A write destination must be a constant. A graph VARIABLE on the construct pattern would
    # send different solutions to different graphs, and the firing graph -- one flat set of
    # triples -- has nowhere to record which triple went where, so undo could not reverse it
    # without reifying every triple with its destination. A scoped READ may still bind a
    # variable: reading from many graphs needs no record of where anything went.
    spec.construct_scope === nothing ||
        !haskey(spec.variables, spec.construct_scope) ||
        error(
            "rule <$(spec.iri)>: jhp:inGraph on the construct pattern " *
            "<$(spec.construct_graph)> names the variable " *
            "$(spec.variables[spec.construct_scope]), and a write destination has to be a " *
            "constant graph IRI. Different solutions would go to different graphs, and a " *
            "firing graph is one flat set of triples with nowhere to record which triple " *
            "went where -- so undo_firing! could not reverse it. Name the graph outright, " *
            "or mint it with gistp:iriTemplate and run the rule once per graph.",
        )

    mode_symbol(spec) === :Rewrite && error(
        "rule <$(spec.iri)>: jhp:inGraph with jhp:_RewriteMode_rewrite is not supported yet. A " *
        "rewrite deletes from exactly one target graph, and a scoped match can bind several " *
        "-- so the target, the tombstone and the undo record would each have to become a " *
        "set. A Rewrite already has a destination, which is the graph it reads: naming a " *
        "second one is a different operation, not a scoped version of this one. Use " *
        "Construct or Assert, or drop the scope and name the graph in `source`.",
    )

    # A graph variable is spliced into query text like any other variable. `check_variables`
    # validates every entry of spec.variables, so a scope that resolves there is already
    # safe; one that does not is a constant graph IRI and must survive check_iri.
    for s in scoped
        haskey(spec.variables, s) && continue
        check_iri(s)
    end
    return spec
end

"""
    _filter_skeleton(expr) -> Union{String,Nothing}

`expr` with every string literal and every IRI reference replaced by a single inert
character, or `nothing` if a literal is left open.

Every structural check below scans this rather than the raw text, because a `}` or a `#`
*inside* a quoted string is ordinary data and rejecting it would refuse honest expressions
like `CONTAINS(?label, "#1")`. Handles SPARQL's four literal forms -- short and long, single-
and double-quoted -- and backslash escapes within them. An unterminated literal is the one
case that cannot be scanned at all: everything after the opening quote is the compiler's
guess about where the expression ends, so it is refused rather than interpreted.

**`<...>` is blanked for the same reason, and this is not a concession.** The engine emits no
`PREFIX` anywhere, so an angle-bracketed IRI is the *only* way a filter can name a resource
or a datatype -- and hash namespaces being what they are, `?t != <...owl#Thing>` and
`"5"^^<...XMLSchema#integer>` are the ordinary cases, not the exotic ones. Refusing them for
the `#` would leave the term unable to express its own worked examples.

Blanking is safe because [`IRIREF`](https://www.w3.org/TR/sparql11-query/#rIRIREF) is a
*token*: its charset already excludes `<`, `>`, `"`, `{`, `}`, `|`, `^`, `` ` ``, `\\` and
everything at or below U+0020. Nothing a brace-check would want to see can hide inside one.
So the skeleton blanks `<...>` only when the content obeys that charset exactly -- which is
precisely where a SPARQL tokenizer would also see one IRI -- and otherwise leaves the text
raw for the checks below to reject. A lone `<` (as in `?a < ?b`) matches nothing and is
copied through.
"""
function _filter_skeleton(expr::AbstractString)
    cs = collect(expr)
    n = length(cs)
    out = Char[]
    i = 1
    # The IRIREF charset, by exclusion, as SPARQL 1.1 grammar rule [139] states it.
    iri_char(c) = !(c in ('<', '>', '"', '{', '}', '|', '^', '`', '\\')) && c > ' '
    while i <= n
        c = cs[i]
        if c == '<'
            j = i + 1
            while j <= n && iri_char(cs[j])
                j += 1
            end
            if j <= n && cs[j] == '>'
                push!(out, '0')             # one closed IRI reduces to one inert token
                i = j + 1
                continue
            end
            # Not an IRIREF -- a comparison operator, or an IRI with something illegal in
            # it. Copy the `<` through and let the checks below see whatever follows.
        end
        if c != '"' && c != '\''
            push!(out, c)
            i += 1
            continue
        end
        long = i + 2 <= n && cs[i + 1] == c && cs[i + 2] == c
        width = long ? 3 : 1
        i += width
        closed = false
        while i <= n
            if cs[i] == '\\'
                i += 2
                continue
            elseif cs[i] == c && (!long || (i + 2 <= n && cs[i + 1] == c && cs[i + 2] == c))
                i += width
                closed = true
                break
            elseif !long && (cs[i] == '\n' || cs[i] == '\r')
                break                       # a short literal may not span a line
            end
            i += 1
        end
        closed || return nothing
        push!(out, '0')                     # a literal reduces to one inert token
    end
    return String(out)
end

# A variable mention inside a filter expression. `$x` and `?x` name the same variable in
# SPARQL, so the sigil is captured out and comparison is on the bare name.
#
# Deliberately wider than `VARIABLE_RE`, which governs the names this engine *emits*. This
# one has to recognise every name SPARQL would accept, because its job is to notice a name
# nothing binds -- and a name it fails to recognise is a name it fails to refuse. SPARQL's
# VARNAME [166] admits a leading digit (`?1` is a legal variable, verified against ARQ) and
# the whole of PN_CHARS_BASE, so `[a-zA-Z_][a-zA-Z0-9_]*` under-reads twice over: it misses
# `?1` entirely, and it truncates `?naïve` to `?na`, refusing a rule while naming a variable
# the author never wrote.
#
# Over-approximating is the safe direction. The skeleton has already removed strings and
# IRIs, and in what remains -- a SPARQL expression -- `?` and `$` introduce a variable and
# nothing else, so a wider charset can only catch more genuinely unbound names.
const _FILTER_VAR_RE = r"[?$]([\p{L}\p{N}_][\p{L}\p{N}_·̀-ͯ‿-⁀]*)"

_bare_var(v::AbstractString) = (startswith(v, '?') || startswith(v, '$')) ? v[2:end] : v

"""
    check_filters(spec)

Reject a filter condition that is not an expression, or that tests a variable nothing binds.

`jhp:filterText` is the one place this engine splices author-supplied text into a query, so
it is the one place that has to be argued rather than assumed. The bargain the rest of the
design makes -- "rules are the tools, not SPARQL", a catalogue of named rewrites instead of
an open UPDATE endpoint -- is only worth anything if a rule cannot *become* an open endpoint
by smuggling syntax through a filter. Hence:

  * **No `{` or `}`.** Braces are what a filter would need to close the compiler's own
    `FILTER(` and open something else -- a `SERVICE`, a subquery, a second `WHERE` group.
    Barring them also bars `EXISTS`, which is deliberate: `jhp:hasNegativeCondition` is the
    sanctioned way to say "no such thing", and it is a *pattern*, so it is reviewable as RDF
    rather than as text.
  * **No `#`.** A comment swallows the rest of the line, including the `)` this compiler
    emits, which turns a malformed filter into whatever happens to follow it.
  * **No `;`.** A semicolon separates operations in an update request.
  * **Balanced parentheses, never dipping below zero.** A leading `)` closes the emitted
    `FILTER(` early; a missing one swallows what comes after.
  * **No prefixed name.** Not a safety rule but a conformance one: this compiler emits no
    `PREFIX` line anywhere, by design -- there is no prefix registry, so every IRI it writes
    is absolute. `xsd:integer` in a filter therefore reaches the store undeclared and comes
    back as an opaque HTTP 400 at run time, which is the exact failure [`check_variables`](@ref)
    exists to turn into a message. Write `<http://www.w3.org/2001/XMLSchema#integer>`.
  * **Not itself a `FILTER` clause.** The engine supplies the keyword and the parentheses, so
    a text of `FILTER(?a != ?b)` compiles to `FILTER(FILTER(?a != ?b))`, which no store will
    parse. A near-universal first mistake, and cheap to name precisely.
  * **Every variable bound.** An unbound variable in a FILTER is not an error in SPARQL --
    the expression errors, the solution is dropped, and the rule quietly matches nothing. A
    typo therefore turns the rule off in silence. That is the failure [`check_bound`](@ref)
    exists to prevent on the construct side, and it earns the same refusal here.

None of this makes an arbitrary expression *safe to author carelessly*; it makes the class of
things a filter can do closed and small. Read what a rule declares before you run it.
"""
function check_filters(spec::RuleSpec)
    isempty(spec.filters) && return spec
    # A filter runs after every binding and every mint, so it may test any of them.
    bound = Set(
        _bare_var(v) for v in union(pre_bound(spec), binding_vars(spec), minted_vars(spec))
    )
    for f in spec.filters
        used = _expression_vars(spec, f, "filter", "FILTER")
        free = sort([string("?", v) for v in setdiff(used, bound)])
        isempty(free) || error(
            "rule <$(spec.iri)>: filter $(repr(f)) tests $(join(free, ", ")), which the " *
            "match pattern never binds and nothing mints. Bound by L: " *
            (
                if isempty(bound)
                    "(none)"
                else
                    join(sort([string("?", v) for v in bound]), ", ")
                end
            ) *
            ". SPARQL does not error " *
            "on an unbound variable in a FILTER -- the expression errors, the solution is " *
            "dropped, and the rule quietly matches nothing.",
        )
    end
    return spec
end

"""
    _expression_vars(spec, text, what, clause) -> Set{String}

Hold one author-supplied SPARQL expression to the checks `check_filters` documents, and
return the (bare) names of the variables it mentions. `what` names the expression in
messages ("filter", "binding"); `clause` is the keyword the engine wraps it in, which the
author must therefore not write themselves.

Shared, not copied, because `jhp:filterText` and `jhp:bindText` are the two places author
text reaches a query, and a threat model applied to only one of them is not a threat model.
"""
function _expression_vars(
    spec::RuleSpec, f::AbstractString, what::AbstractString, clause::AbstractString
)
    isempty(strip(f)) && error(
        if what == "filter"
            "rule <$(spec.iri)>: a jhp:FilterCondition has empty jhp:filterText. An " *
            "expression that says nothing cannot constrain anything; drop the condition."
        else
            "rule <$(spec.iri)>: a jhp:Binding has empty jhp:bindText. An expression that " *
            "says nothing binds nothing; drop the binding."
        end,
    )

    skel = _filter_skeleton(f)
    skel === nothing && error(
        "rule <$(spec.iri)>: $what $(repr(f)) leaves a string literal unterminated, " *
        "so where the expression ends is a guess. Close the quote.",
    )

    for (ch, why) in (
        '{' =>
            "could open a group -- a SERVICE, a subquery, or a second " *
            "WHERE. For \"no such thing exists\" use " *
            "jhp:hasNegativeCondition, which is a reviewable " *
            "pattern rather than text",
        '}' =>
            "could close the $clause this compiler wraps the " *
            "expression in, leaving whatever follows outside it",
        '#' =>
            "starts a comment, which would swallow the closing " *
            "parenthesis this compiler emits",
        ';' => "separates operations in an update request",
    )
        occursin(ch, skel) && error(
            "rule <$(spec.iri)>: $what $(repr(f)) contains $(repr(ch)), which $why. " *
            "A jhp:$(what == "filter" ? "filterText" : "bindText") is one SPARQL " *
            "expression and nothing else. Inside a quoted string the character is fine -- " *
            "this one is not in one.",
        )
    end

    # After the skeleton, the only thing a `:` can be is a prefixed name: strings and
    # IRIs are gone, and a blank node label cannot appear in an expression.
    occursin(':', skel) && error(
        "rule <$(spec.iri)>: $what $(repr(f)) uses a prefixed name, but this compiler " *
        "emits no PREFIX line -- it has no prefix registry, and every IRI it writes is " *
        "absolute. The store would reject the query with an opaque \"Unresolved " *
        "prefixed name\". Write the full IRI in angle brackets instead, as in " *
        "\"?d > \\\"2020\\\"^^<http://www.w3.org/2001/XMLSchema#gYear>\".",
    )

    occursin(Regex("^\\s*$clause\\s*\\(", "i"), skel) && error(
        "rule <$(spec.iri)>: $what $(repr(f)) is a whole $clause clause. The engine " *
        "supplies the keyword and the parentheses, so this would compile to " *
        "$clause($clause(...)), which no store will parse. Declare the expression alone.",
    )
    # A binding names its variable with jhp:bindsVariable; `… AS ?x` inside the text would
    # compile to BIND((… AS ?x) AS ?v), which parses as nothing.
    clause == "BIND" && occursin(r"(?i)\bAS\s+[?$]", skel) && error(
        "rule <$(spec.iri)>: $what $(repr(f)) contains `AS ?…`. Name the variable with " *
        "jhp:bindsVariable; jhp:bindText is the expression alone.",
    )

    depth = 0
    for c in skel
        c == '(' && (depth += 1)
        c == ')' && (depth -= 1)
        depth < 0 && error(
            "rule <$(spec.iri)>: $what $(repr(f)) closes a parenthesis it never " *
            "opened, which would close the $clause this compiler wraps it in.",
        )
    end
    depth == 0 || error(
        "rule <$(spec.iri)>: $what $(repr(f)) leaves $depth parenthesis/es open, so " *
        "it would swallow whatever the compiler emits after it.",
    )

    return Set(m.captures[1] for m in eachmatch(_FILTER_VAR_RE, skel))
end

"""
    pre_bound(spec) -> Set{String}

Every variable bound before the first `jhp:hasBinding` is evaluated: by L's triples, by L's
graph scopes, by a source map's generated pattern, or by a `gistp:oneOf` VALUES clause.

One definition, because four checks need it and each used to list the sources by hand -- and
the filter check's list had quietly omitted source-mapped variables.
"""
function pre_bound(spec::RuleSpec)
    return union(
        vars_in(spec.match, spec),
        match_scope_vars(spec),
        Set(m.variable for m in spec.source_maps),
        enum_vars(spec),
    )
end

"The SPARQL variable names produced by `jhp:hasBinding`."
binding_vars(spec::RuleSpec) =
    Set(spec.variables[b.variable] for b in spec.bindings if haskey(spec.variables, b.variable))

"""
    ordered_bindings(spec) -> Vector{BindingSpec}

The rule's bindings in an order where each reads only what is already bound.

A `BIND` sees only variables bound earlier in its group, so a binding that reads another
binding has to come after it. Kahn's algorithm, with ties broken by variable name so that
the same rule compiles to the same bytes however its bindings arrived. Assumes
`check_bindings` has run: an input bound by nothing, or a cycle, is refused there with a
message; here it would only be an infinite loop or a silent drop.
"""
function ordered_bindings(spec::RuleSpec)
    isempty(spec.bindings) && return BindingSpec[]
    name(b) = _bare_var(spec.variables[b.variable])
    produced = Set(name(b) for b in spec.bindings)
    deps = Dict(
        b.variable =>
            intersect(Set(m.captures[1] for m in eachmatch(_FILTER_VAR_RE,
                something(_filter_skeleton(b.text), ""))), produced) for b in spec.bindings
    )
    done = Set{String}()
    out = BindingSpec[]
    remaining = sort(spec.bindings; by=name)
    while !isempty(remaining)
        i = findfirst(b -> issubset(deps[b.variable], done), remaining)
        i === nothing && error(
            "rule <$(spec.iri)>: the bindings of " *
            join(sort([spec.variables[b.variable] for b in remaining]), ", ") *
            " depend on one another in a cycle, so none of them can be evaluated first.",
        )
        b = popat!(remaining, i)
        push!(out, b)
        push!(done, name(b))
    end
    return out
end

"""
    check_bindings(spec)

Refuse a `jhp:hasBinding` that is not one safe expression, that binds a variable something
else already binds, or that reads a variable nothing has bound by the time it runs.

  * **The text** is held to every check `check_filters` applies, and for the same reason:
    it is spliced into the query.
  * **The target** must be fresh. SPARQL refuses to `BIND` a variable already in scope, so a
    target L also matches, a mint constructs, VALUES enumerates, a source map fills or a
    second binding also assigns would fail at the store with an opaque parse error.
  * **Every input** must be bound earlier: by L, VALUES, a source map, or another binding.
    An unbound input does not error in SPARQL -- the expression does, the variable is left
    unbound, and every R triple that mentions it is silently dropped. The same silent
    weakening `check_filters` exists to prevent.
  * **Not a minted variable.** Mints are emitted after bindings so a template slot can read
    one; reading a mint from a binding would need the two interleaved, and nothing needs
    it yet.
  * **No cycle** -- see [`ordered_bindings`](@ref).

What this cannot check is the expression's *meaning*. `STRBEFORE(?x, "T")` on a value with no
"T" yields "" and the rule proceeds; an ill-typed argument leaves the variable unbound at run
time. Both are ordinary SPARQL, and both are why `explain_rule` shows each binding.
"""
function check_bindings(spec::RuleSpec)
    isempty(spec.bindings) && return spec
    before = pre_bound(spec)
    minted = minted_vars(spec)
    seen = Dict{String,String}()
    for b in spec.bindings
        haskey(spec.variables, b.variable) || error(
            "rule <$(spec.iri)>: binding $(b.iri) binds <$(b.variable)>, which is not a " *
            "declared gistp:SparqlVariable with a gistp:variableText.",
        )
        v = spec.variables[b.variable]
        haskey(seen, v) && error(
            "rule <$(spec.iri)>: $v is bound by two bindings, $(seen[v]) and $(b.iri). " *
            "A variable has one value per solution; SPARQL refuses a second BIND of it.",
        )
        seen[v] = b.iri
        for (set, what) in (
            (vars_in(spec.match, spec), "the match pattern matches it"),
            (match_scope_vars(spec), "it names the graph a match pattern reads"),
            (Set(m.variable for m in spec.source_maps), "a gistp:SourceMap fills it"),
            (enum_vars(spec), "its gistp:oneOf enumerates it"),
            (minted, "a gistp:iriTemplate mints it"),
        )
            v in set && error(
                "rule <$(spec.iri)>: binding $(b.iri) binds $v, but $what. SPARQL cannot " *
                "BIND a variable already in scope; bind a new variable and use that.",
            )
        end
    end
    produced = Set(_bare_var(v) for v in keys(seen))
    available = Set(_bare_var(v) for v in before)
    for b in spec.bindings
        v = spec.variables[b.variable]
        used = _expression_vars(spec, b.text, "binding", "BIND")
        _bare_var(v) in used && error(
            "rule <$(spec.iri)>: binding $(b.iri) reads $v, the variable it binds.",
        )
        mint_in = sort([string("?", u) for u in intersect(used, Set(_bare_var(m) for m in minted))])
        isempty(mint_in) || error(
            "rule <$(spec.iri)>: binding $(b.iri) reads $(join(mint_in, ", ")), which a " *
            "gistp:iriTemplate mints. Mints are emitted after bindings, so that a template " *
            "slot can read a binding; the other direction is not supported.",
        )
        free = sort([string("?", u) for u in setdiff(used, available, produced)])
        isempty(free) || error(
            "rule <$(spec.iri)>: binding $(b.iri) reads $(join(free, ", ")), which nothing " *
            "binds before it: not the match pattern, VALUES, a source map, or another " *
            "binding. SPARQL does not error on that -- the expression does, $v is left " *
            "unbound, and every construct triple mentioning it is silently dropped.",
        )
    end
    ordered_bindings(spec)          # refuses a cycle
    return spec
end

"""
    bindings_text(spec) -> String

Every `jhp:hasBinding`, as `BIND((text) AS ?v)`, in dependency order.

The expression is parenthesised so that the text is one operand whatever its operators --
`?a || ?b AS ?v` is not what anyone means.
"""
function bindings_text(spec::RuleSpec)
    isempty(spec.bindings) && return ""
    return "\n" * join(
        ("  BIND(($(b.text)) AS $(spec.variables[b.variable]))" for b in ordered_bindings(spec)),
        "\n",
    )
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
    check_match_parts(spec)
    check_no_blanks(spec)
    check_positions(spec)
    check_variables(spec)
    check_enums(spec)
    check_mints(spec)
    check_scopes(spec)
    check_filters(spec)
    check_bindings(spec)
    check_source_maps(spec)
    # L's graph variable is bound by the GRAPH clause, not by any triple, so `vars_in` -- which
    # walks subject, predicate and object -- cannot see it. Without this a rule that records
    # which graph a fact came from, the whole point of scoping the match, is refused as
    # use-before-def on the one variable L most definitely binds.
    matched = union(
        vars_in(spec.match, spec),
        match_scope_vars(spec),
        # A source-mapped variable is bound by a triple pattern the COMPILER generates, so
        # `vars_in` -- which walks only the authored pattern -- cannot see it. Without this,
        # the whole point of a source map (letting R use a column the pattern never names) is
        # refused as use-before-def on the one variable that is most definitely bound.
        Set(m.variable for m in spec.source_maps),
    )

    # A negative condition's *graph* may not be a variable L does not bind, and the asymmetry
    # is worth stating because it is not obvious: a condition's TRIPLES may introduce fresh
    # existential variables -- that is what a guard is for -- but its GRAPH may not. An
    # unbound graph variable re-quantifies the whole condition, turning "no such thing in THIS
    # graph" into "no such thing in ANY graph". That is the same silent re-quantification
    # `where_body` avoids by keeping the filter out of L's GRAPH group; without this check it
    # simply reappears one level up, and it drops solutions with no error. Measured: on the
    # round-5a fixture, scoping the guard to an unbound variable silently loses the ex:s2/bookB
    # row -- the exact row the feature's headline integration test exists to protect.
    for n in spec.nacs
        n.scope === nothing && continue
        sv = scope_vars(n.scope, spec)
        isempty(sv) && continue                      # a constant graph is always fine
        issubset(sv, matched) || error(
            "rule <$(spec.iri)>: negative condition <$(n.graph)> is scoped to " *
            "$(first(sv)), which the match pattern does not bind. A condition's triples may " *
            "introduce fresh variables -- that is what a guard is -- but its *graph* may " *
            "not: an unbound graph variable re-quantifies the whole condition, turning 'no " *
            "such thing in THIS graph' into 'no such thing in ANY graph', which drops " *
            "solutions with no error. Scope it to the graph variable L binds, or name a " *
            "constant graph.",
        )
    end
    # An enumerated variable is bound by its VALUES clause and a minted one by its BIND;
    # neither has to appear in a match triple to be available to R.
    bound = union(matched, minted_vars(spec), enum_vars(spec), binding_vars(spec))
    used = vars_in(spec.construct, spec)
    free = setdiff(used, bound)
    isempty(free) && return spec

    return error(
        """
        rule <$(spec.iri)>: construct pattern uses $(join(sort(collect(free)), ", ")) \
        which the match pattern never binds and nothing mints. Bound by L: \
        $(isempty(matched) ? "(none)" : join(sort(collect(matched)), ", ")). \
        A literal-position variable is matched across L and R by string equality of its \
        lexical form, so check for a typo; if the variable is meant to be created rather \
        than found, give it a gistp:iriTemplate and its slot bindings."""
    )
end

"""
    compile_rule(spec::RuleSpec; from = String[]) -> String

Emit the SPARQL for a rule. Pure: same spec, same bytes, no server involved.

`Construct` and `Assert` compile to **identical text**. The difference is entirely in the
harness -- whether the result is taken as the answer or unioned back into the source and the
rule applied again. One compiler, two drivers.

`from` names the graphs to read, and becomes a `FROM` / `FROM NAMED` dataset clause -- the
`CONSTRUCT` spelling of the `USING` clause [`insert_query`](@ref) emits. Omitting it keeps
the historical bytes exactly, so the golden snapshot and every substring assertion still
hold; it is required only for a scoped rule, where a query with no dataset clause would let
the graph variable range over the whole store.

**Pass it whenever you are showing the query to somebody.** This function is what
`explain_rule` prints under "compiles to:", and without `from` a scoped rule was reviewed as
an unbounded `GRAPH ?g` while what actually ran was an `INSERT … USING … USING NAMED …`. A
reviewer approving the text was approving a different query from the one the engine would
execute.
"""
function compile_rule(spec::RuleSpec; from::AbstractVector=String[])
    check_bound(spec)
    m = mode_symbol(spec)
    froms = dataset_lines(spec, from; keyword="FROM")

    # A rule with no L matches everything, so an empty match pattern is refused -- unless
    # source maps supply it. For an extraction rule they supply ALL of it: every triple the
    # SERVICE needs is generated from the columns, and an author with nothing else to say
    # about the row correctly has nothing to write here. Requiring a token triple would be
    # worse than permitting none, because the obvious token -- the data source's own type
    # assertion -- lands inside the SERVICE where the CSV contains no such statement, and the
    # rule would match nothing while looking entirely reasonable.
    isempty(spec.match) &&
        isempty(spec.source_maps) &&
        error(
            "rule <$(spec.iri)>: match pattern <$(spec.match_graph)> is empty and no " *
            "gistp:SourceMap supplies it, so the rule would match everything.",
        )
    isempty(spec.construct) &&
        error("rule <$(spec.iri)>: construct pattern <$(spec.construct_graph)> is empty.")

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
    $(froms)WHERE {
    $(where_body(spec))
    }
    """

    return """
           # $(m) rule <$(spec.iri)>
           CONSTRUCT {
           $(bgp_text(spec.construct, spec))
           }
           $(froms)WHERE {
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
function project_query(
    spec::RuleSpec;
    triples::Vector{PatternTriple},
    into::AbstractString,
    from::AbstractVector=String[],
)
    check_bound(spec)
    isempty(triples) && return ""
    using_lines = dataset_lines(spec, from)
    return """
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

A `jhp:_RewriteMode_rewrite` as one atomic SPARQL Update, recorded so it can be reversed.

Unlike `Construct` and `Assert`, a rewrite mutates the data. `target` is the graph it edits;
`firing` and `tombstone` capture what was added and what was removed, which is what makes
undo possible at all -- `DROP GRAPH` cannot restore a deletion.

All four templates instantiate from the same solutions, and SPARQL evaluates the WHERE
against the pre-update state with DELETE applied before INSERT, so the tombstone receives
the triples as they were before removal. One request is one transaction, so a firing is
never half-applied.
"""
function rewrite_query(
    spec::RuleSpec;
    target::AbstractString,
    firing::AbstractString,
    tombstone::AbstractString,
    from::AbstractVector=String[],
)
    check_bound(spec)
    mode_symbol(spec) === :Rewrite || error(
        "rule <$(spec.iri)>: rewrite_query is only for jhp:_RewriteMode_rewrite; this rule is " *
        "$(mode_symbol(spec)). Use insert_query.",
    )

    gone = match_only(spec)
    added = construct_only(spec)
    isempty(gone) &&
        isempty(added) &&
        error(
            "rule <$(spec.iri)>: L and R are identical, so the rewrite deletes nothing and " *
            "adds nothing. I = L = R.",
        )

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
        push!(
            ops,
            """
 INSERT {
   GRAPH <$f> {
 $(bgp_text(added, spec; indent = "    "))
   }
 }
 $(using_lines)WHERE {
 $(where_body(spec))
 }""",
        )
        # what the target already had is not something this rule added
        push!(
            ops,
            """
 DELETE { GRAPH <$f> { ?__s ?__p ?__o } }
 WHERE  { GRAPH <$f> { ?__s ?__p ?__o } GRAPH <$t> { ?__s ?__p ?__o } }""",
        )
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
        push!(
            ops,
            """
 INSERT {
   GRAPH <$tomb> {
 $(bgp_text(gone, spec; indent = "    "))
   }
 }
 $(using_lines)WHERE {
 $(where_body(spec))
 }""",
        )
        push!(
            ops,
            """
 DELETE {
   GRAPH <$t> {
 $(bgp_text(gone, spec; indent = "    "))
   }
 }
 $(using_lines)WHERE {
 $(where_body(spec))
 }""",
        )
    end

    # Applied last, and from the pruned firing graph rather than from the template, so the
    # target receives exactly what the firing graph claims -- which is what makes undo an
    # exact inverse.
    isempty(added) || push!(
        ops,
        """
INSERT { GRAPH <$t> { ?__s ?__p ?__o } }
WHERE  { GRAPH <$f> { ?__s ?__p ?__o } }""",
    )

    return join(ops, " ;\n") * "\n"
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
function collision_queries(spec::RuleSpec; from::AbstractVector=String[])
    out = Tuple{String,String}[]
    isempty(spec.mints) && return out
    froms = dataset_lines(spec, from; keyword="FROM")

    for iri in sort(collect(keys(spec.mints)))
        m = spec.mints[iri]
        v = spec.variables[iri]
        key = join(
            (
                "ENCODE_FOR_URI(STR($(var_of(m.slots[n], spec))))" for
                n in sort(collect(keys(m.slots)))
            ),
            ", \" \", ",
        )
        push!(out, (
            iri,
            """
SELECT $v (COUNT(DISTINCT ?__key) AS ?n)
$(froms)WHERE {
$(match_text(spec))$(pre_mint_text(spec))
$(bind_text(m, spec))$(nacs_text(spec))
  BIND(CONCAT($key) AS ?__key)
}
GROUP BY $v
HAVING (COUNT(DISTINCT ?__key) > 1)
""",
        ))
    end
    return out
end

"""
    check_collisions(spec; from = String[], ep = endpoint(), limit = 5) -> RuleSpec

Run [`collision_queries`](@ref) and refuse the rule if any minted IRI is reachable from more
than one distinct binding.

This raises rather than warns. A collision is not a cosmetic problem: an IRI is an identity
claim, so two people sharing a minted IRI *are* one person as far as every downstream query
is concerned, and nothing else in the stack will ever notice.
"""
function check_collisions(
    spec::RuleSpec;
    from::AbstractVector=String[],
    ep::SparqlEndpoint=endpoint(),
    limit::Integer=5,
)
    # Validate before assembling anything. `apply_rule` calls this *before* `insert_query`,
    # so relying on that function's own `check_bound` to sanitise `variableText` left this
    # one shipping unvalidated text to the store: a poisoned variableText reached Fuseki and
    # came back HTTP 400. Nothing was written, but only because the query endpoint refuses
    # updates -- a property of the store's endpoint separation, not of this code. Every
    # function that builds SPARQL validates its own inputs.
    check_variables(spec)
    for (iri, q) in collision_queries(spec; from=from)
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
        rows = select(q; ep=ep)
        isempty(rows) && continue
        v = spec.variables[iri]
        shown = [
            string(
                "<",
                (r[v[2:end]]::IRIRef).value,
                "> from ",
                (r["n"]::RDFLiteral).lexical,
                " distinct bindings",
            ) for r in Iterators.take(rows, limit)
        ]
        error(
            """
            rule <$(spec.iri)>: minting $v produces $(length(rows)) IRI(s) that more than \
            one distinct binding would create, which would silently merge distinct things \
            into one node:
              $(join(shown, "\n  "))$(length(rows) > limit ? "\n  ... and $(length(rows) - limit) more" : "")
            The template $(repr(spec.mints[iri].template)) does not discriminate its \
            inputs. Add a slot, or use a slot whose values are unique.""",
        )
    end
    return spec
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
function mint_fanin(
    spec::RuleSpec;
    from::AbstractVector=String[],
    ep::SparqlEndpoint=endpoint(),
    limit::Integer=5,
)
    out = Tuple{String,Vector{Tuple{String,Int}}}[]
    isempty(spec.mints) && return out
    check_variables(spec)          # this builds SPARQL too; see check_collisions
    froms = dataset_lines(spec, from; keyword="FROM")
    others = sort(collect(setdiff(vars_in(spec.construct, spec), minted_vars(spec))))
    isempty(others) && return out
    key = join(("ENCODE_FOR_URI(STR($o))" for o in others), ", \" \", ")

    for iri in sort(collect(keys(spec.mints)))
        v = spec.variables[iri]
        rows = select(
            """
  SELECT $v (COUNT(DISTINCT ?__ctx) AS ?n)
  $(froms)WHERE {
  $(match_text(spec))$(pre_mint_text(spec))
  $(bind_text(spec.mints[iri], spec))$(nacs_text(spec))
    BIND(CONCAT($key) AS ?__ctx)
  }
  GROUP BY $v
  HAVING (COUNT(DISTINCT ?__ctx) > 1)
  ORDER BY DESC(?n) LIMIT $(Int(limit))""";
            ep=ep,
        )
        isempty(rows) || push!(
            out,
            (
                iri,
                [
                    ((r[v[2:end]]::IRIRef).value, parse(Int, (r["n"]::RDFLiteral).lexical)) for r in rows
                ],
            ),
        )
    end
    return out
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
function insert_query(spec::RuleSpec; into::AbstractString, from::AbstractVector=String[])
    check_bound(spec)
    mode_symbol(spec) === :Rewrite && error(
        "rule <$(spec.iri)>: jhp:_RewriteMode_rewrite mutates the data, so it cannot be run through " *
        "insert_query, which only ever adds to a firing graph. Use rewrite_query.",
    )
    using_lines = dataset_lines(spec, from)
    return """
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
    compile_from_store(rule_iri; from = String[], ep = endpoint()) -> String

Fetch and compile in one step. See [`load_rule`](@ref) and [`compile_rule`](@ref).

`from` is forwarded to `compile_rule` and becomes the dataset clause. A scoped rule requires
it; an unscoped one is unaffected.
"""
function compile_from_store(
    rule_iri::AbstractString; from::AbstractVector=String[], ep::SparqlEndpoint=endpoint()
)
    return compile_rule(load_rule(rule_iri; ep=ep); from=from)
end

"""
    list_rules(; ep = endpoint()) -> Vector{String}

Every `jhp:Rule` IRI in the store, sorted.
"""
function list_rules(; ep::SparqlEndpoint=endpoint())
    rows = select("SELECT ?r WHERE { ?r a <$C_RULE> } ORDER BY ?r"; ep=ep)
    return sort!([_iri(r["r"]) for r in rows])
end

const SKOS_LABEL = "http://www.w3.org/2004/02/skos/core#prefLabel"
const SKOS_DEFINITION = "http://www.w3.org/2004/02/skos/core#definition"

"""
    rule_catalogue(; ep = endpoint()) -> Vector{NamedTuple}

Every rule in the store with its mode, label and definition -- what a human or an agent
needs to choose one, without reading any SPARQL.

Each entry carries `mode` (a `Symbol`) and `mode_iri` (the raw `jhp:rewriteMode` value).
A rule whose mode is not one of the three recognised IRIs comes back as `:Unrecognised`
rather than raising: this is the *catalogue*, and it is the only route an agent has to
discovering any rule at all, so one malformed rule must not hide the rest of them. The rule
still fails, loudly, at [`load_rule`](@ref) the moment anyone tries to use it.
"""
function rule_catalogue(; ep::SparqlEndpoint=endpoint())
    rows = select(
        """
SELECT ?r ?mode ?label ?def (COUNT(?n) AS ?guards) WHERE {
  ?r a <$C_RULE> ; <$P_MODE> ?mode .
  OPTIONAL { ?r <$SKOS_LABEL> ?label }
  OPTIONAL { ?r <$SKOS_DEFINITION> ?def }
  OPTIONAL { ?r <$P_NAC> ?n }
} GROUP BY ?r ?mode ?label ?def ORDER BY ?r""";
        ep=ep,
    )
    lex(r, k) = haskey(r, k) && r[k] isa RDFLiteral ? (r[k]::RDFLiteral).lexical : ""
    mode_of(m) =
        try
            mode_symbol(m)
        catch
            :Unrecognised
        end
    return [
        (
            iri=_iri(r["r"]),
            mode=mode_of(_iri(r["mode"])),
            mode_iri=_iri(r["mode"]),
            label=lex(r, "label"),
            definition=lex(r, "def"),
            guards=parse(Int, (r["guards"]::RDFLiteral).lexical),
        ) for r in rows
    ]
end

#################################################################
#    Source maps: naming a column instead of a Facade-X predicate
#################################################################
#
# A gistp:TabularDataSource already compiles to SERVICE <x-sparql-anything:>, so a rule could
# always read a CSV -- but it had to name the Facade-X predicates itself, which meant the
# author doing the percent-encoding and knowing the row-container idiom. A gistp:SourceMap
# says "this variable comes from that column" and the compiler owes the rest.

const XYZ_NS = "http://sparql.xyz/facade-x/data/"
const APF_STRSPLIT = "http://jena.apache.org/ARQ/property#strSplit"

# The row container, synthesised rather than authored. There is exactly one row per solution,
# so one variable suffices, and minting it here means the match pattern need not mention the
# Facade-X shape at all. Double underscore to stay out of any author's namespace.
const FX_ROW_VAR = "?__fxrow"

const C_SOURCEMAP = GISTP_NS * "SourceMap"
const C_LITERALVAR = GISTP_NS * "LiteralVariable"
const P_MAPTO = GISTP_NS * "mapTo"
const P_MAPFROMSTR = GISTP_NS * "mapFromString"
const P_MAPFROM = GISTP_NS * "mapFrom"
const P_MAPFIRST = GISTP_NS * "mapFirst"
const P_MAPEACH = GISTP_NS * "mapEach"
const P_CONCAT = GISTP_NS * "concat"
const P_SEPARATOR = GISTP_NS * "separator"
const P_STRBEFORE = GISTP_NS * "stringBefore"
const P_PATMATCH = GISTP_NS * "valuePatternMatch"
const P_PATEXCLUDE = GISTP_NS * "valuePatternExclude"

"""
    fx_predicate(column) -> String

The Facade-X predicate IRI for a source column name.

`gistp:mapFromString` carries "the source's own spelling -- 'dc.title[en]' rather than any
sanitized form", so turning that into an IRI is the compiler's job, and getting it wrong
produces a rule that matches nothing rather than an error.

**The rule was measured against SPARQL Anything, not read from its docs, which are wrong on
this.** Both the upstream reference and the local skill notes claim `dc.title[en]` becomes
`dc.title%5Ben%5D`; it does not, and a query naming that form matches nothing.

The encoded set was re-measured against 1.3.0-SNAPSHOT by putting one header of each
interesting character through the service and reading back the predicates it produced:

| raw | emitted | | raw | emitted |
|---|---|---|---|---|
| `a b` | `a%20b` | | `dc.title[en]` | unchanged |
| `Trade #` | `Trade%20%23` | | `pc%nt` | unchanged |
| `x (y)` | `x%20%28y%29` | | `am&p`, `pl+us`, `qu?ry`, `se;mi` | unchanged |

So the encoded set is `<>"{}|^\\` and backtick and everything at or below U+0020 -- the
characters SPARQL's `IRIREF` production forbids -- **plus `#`, `(` and `)`, which it permits**.
Brackets, `%`, `&`, `+`, `?` and `;` are left raw.

An earlier version of this function stated its specification as "make it pass
[`check_iri`](@ref), changing nothing else", on the reasoning that both sets come from the
same SPARQL production. That was a tidy theory and it was false: `#`, `(` and `)` are legal
in an `IRIREF` and are encoded anyway. The theory cost real time, because a column the
encoder and the service disagree about produces a rule that **matches nothing rather than
erroring** -- so the specification is now the measurement, and the table above is what the
test asserts. Passing `check_iri` remains necessary and is no longer sufficient.
"""
function fx_predicate(column::AbstractString)
    io = IOBuffer()
    print(io, XYZ_NS)
    for c in column
        # '#', '(' and ')' are legal in an IRIREF and encoded anyway -- measured, not
        # derived. See the table above; dropping them silently breaks any column with a
        # '#' in its name, which is every trade-identifier column anyone has ever shipped.
        if c in ('<', '>', '"', '{', '}', '|', '^', '`', '\\', '#', '(', ')') || c <= ' '
            for b in codeunits(string(c))
                print(io, '%', uppercase(string(b; base=16, pad=2)))
            end
        else
            print(io, c)
        end
    end
    return String(take!(io))
end

"""
    regex_quote(literal) -> String

A literal string as a regular expression matching exactly itself.

`gistp:separator` is "the character or string which separates usable values" -- a literal.
ARQ's `apf:strSplit` takes a **regex**. So `"||"` has to reach the store as `\\|\\|`, and an
author who writes `"."` means a full stop rather than any character. Escaping it here is the
difference between splitting a field and splitting between every character of it.
"""
function regex_quote(literal::AbstractString)
    io = IOBuffer()
    for c in literal
        c in ('\\', '.', '^', '$', '|', '?', '*', '+', '(', ')', '[', ']', '{', '}') &&
            print(io, '\\')
        print(io, c)
    end
    return String(take!(io))
end

"""
    load_source_maps(rule_iri, graphs; ep = endpoint()) -> Vector{SourceMapSpec}

Every `gistp:SourceMap` feeding a variable that occurs in `graphs`.

Reached through `gistp:mapTo`, which is the only link the vocabulary gives: a source map
names the variable it fills, and nothing names the source map. So the rule is found from its
variables rather than the other way round, and a map whose variable the rule never mentions
is simply not this rule's business.

Every field is fetched with `OPTIONAL` and then checked. The list-valued alternatives to
`mapFromString` are fetched too, for the sole purpose of refusing them by name: read through
an inner join they would come back as no source map at all, and the rule would compile to a
pattern with an unbound variable rather than to an error.

Sorted by column so compiled output is byte-stable.
"""
function load_source_maps(
    rule_iri::AbstractString,
    graphs::AbstractVector;
    also::AbstractSet{String}=Set{String}(),
    ep::SparqlEndpoint=endpoint(),
)
    rows = select(
        """
SELECT ?m ?var ?vartext ?col ?sep ?before ?match ?exclude ?from ?first ?each ?cat WHERE {
  ?m a <$C_SOURCEMAP> ; <$P_MAPTO> ?var .
  ?var <$P_VARIABLETEXT> ?vartext .
  OPTIONAL { ?m <$P_MAPFROMSTR> ?col }
  OPTIONAL { ?m <$P_SEPARATOR>  ?sep }
  OPTIONAL { ?m <$P_STRBEFORE>  ?before }
  OPTIONAL { ?m <$P_PATMATCH>   ?match }
  OPTIONAL { ?m <$P_PATEXCLUDE> ?exclude }
  OPTIONAL { ?m <$P_MAPFROM>    ?from }
  OPTIONAL { ?m <$P_MAPFIRST>   ?first }
  OPTIONAL { ?m <$P_MAPEACH>    ?each }
  OPTIONAL { ?m <$P_CONCAT>     ?cat }
}""";
        ep=ep,
    )
    isempty(rows) && return SourceMapSpec[]

    # Which literal variables does this rule actually use? A gistp:var literal is declared
    # nowhere -- it is identified only by its datatype and matched across patterns by lexical
    # form -- so the occurrence check is against the patterns' own text.
    #
    # `also` carries the variables a gistp:iriTemplate's slots reference, and it is a
    # requirement rather than a refinement: a rule that mints one node per row reads the id
    # column and need never mention it in a pattern. Judging relevance from the patterns
    # alone dropped exactly the source map such a rule most needs, and the failure surfaced
    # as "minting from another minted variable", which it is not.
    used = Set{String}(also)
    for g in graphs, t in load_pattern(g; ep=ep), pos in (t.subject, t.predicate, t.object)
        is_var_literal(pos) && push!(used, (pos::RDFLiteral).lexical)
    end

    lex(r, k) = haskey(r, k) ? (r[k]::RDFLiteral).lexical : nothing
    out = SourceMapSpec[]
    for r in rows
        vt = (r["vartext"]::RDFLiteral).lexical
        vt in used || continue
        m = _iri(r["m"])

        for (key, term, why) in (
            (
                "from",
                P_MAPFROM,
                "gistp:mapFrom names the source attribute as a resource, and this vocabulary " *
                "has no class for one yet -- there is nothing to read a column name off. Use " *
                "gistp:mapFromString, which carries the source's own spelling.",
            ),
            (
                "first",
                P_MAPFIRST,
                "gistp:mapFirst is a list of alternative columns, first populated one wins. " *
                "Not built: it compiles to COALESCE over one binding per member, which is a " *
                "different shape from the single triple pattern below.",
            ),
            (
                "each",
                P_MAPEACH,
                "gistp:mapEach is a list of additive columns, all values kept. Not built, and " *
                "it is the hardest of the three: it MULTIPLIES solutions, so it is a UNION " *
                "over the match rather than an expression over one binding.",
            ),
            (
                "cat",
                P_CONCAT,
                "gistp:concat is a list whose values are joined as strings. Not built: it " *
                "compiles to CONCAT over one binding per member.",
            ),
        )
            haskey(r, key) && error("rule <$rule_iri>: source map <$m> uses <$term>. $why")
        end

        col = lex(r, "col")
        col === nothing && error(
            "rule <$rule_iri>: source map <$m> feeds $vt but declares no " *
            "gistp:mapFromString, so there is no column to read it from. A map with no " *
            "source would leave $vt unbound, and an unbound variable in a pattern matches " *
            "anything rather than failing.",
        )
        isempty(col) && error(
            "rule <$rule_iri>: source map <$m> declares an empty gistp:mapFromString. No " *
            "column is named by the empty string.",
        )
        push!(
            out,
            SourceMapSpec(
                m,
                vt,
                col,
                lex(r, "sep"),
                lex(r, "before"),
                lex(r, "match"),
                lex(r, "exclude"),
            ),
        )
    end

    sort!(out; by=x -> (x.column, x.variable))
    dupes = [x.variable for x in out if count(y -> y.variable == x.variable, out) > 1]
    isempty(dupes) || error(
        "rule <$rule_iri>: $(join(unique(dupes), ", ")) is fed by more than one " *
        "gistp:SourceMap. One variable takes one value per solution; two maps would emit " *
        "two triple patterns for it, which silently becomes a JOIN requiring both columns " *
        "to hold the same string. gistp:mapFirst and gistp:mapEach are the vocabulary's " *
        "answers to several columns, and neither is built yet.",
    )
    return out
end

"""
    source_map_bgp(spec; indent = "  ") -> String

The Facade-X triple patterns a rule's source maps generate, one per mapped column.

Emitted **inside** the `SERVICE` block, because that is where the row container exists. The
subject is [`FX_ROW_VAR`](@ref), synthesised here rather than authored: Facade-X gives one
container per row, so a single variable binds each row in turn and the author never has to
mention `rdf:_1` or `fx:root`.

A map with a value pipeline binds a *raw* variable instead of its target, because SPARQL
cannot rebind: the pipeline in [`source_map_pipeline`](@ref) then produces the target from it.
A map with no pipeline binds the target directly, so the simple case compiles to exactly the
triple an author would have written by hand.
"""
function source_map_bgp(spec::RuleSpec; indent::AbstractString="  ")
    isempty(spec.source_maps) && return ""
    return join(
        (
            "$(indent)$FX_ROW_VAR <$(fx_predicate(m.column))> $(_sm_bound(m)) ." for
            m in spec.source_maps
        ),
        "\n",
    ) * "\n"
end

"Whether a source map transforms its value, and therefore needs a raw binding first."
_sm_piped(m::SourceMapSpec) = m.separator !== nothing || m.string_before !== nothing

"The variable a source map's column binds directly: its target, or a raw stand-in."
function _sm_bound(m::SourceMapSpec)
    return _sm_piped(m) ? "?__raw" * replace(m.variable, "?" => "") : m.variable
end

"""
    source_map_pipeline(spec; indent = "  ") -> String

The value pipeline: split, truncate, keep, drop -- in that order, and the order is the
vocabulary's rather than a choice.

`gistp:separator` splits one cell into many values, so it must come first or everything after
it would operate on the unsplit string. `gistp:stringBefore` then truncates each value.
`gistp:valuePatternMatch` and `gistp:valuePatternExclude` are decisions about a finished
value, so they come last, and they are `FILTER`s rather than transformations.

Emitted **outside** the `SERVICE` block. `apf:strSplit` is an ARQ property function, which
the Facade-X evaluator has no reason to understand, and the split is a join over values the
service has already produced.
"""
function source_map_pipeline(spec::RuleSpec; indent::AbstractString="  ")
    isempty(spec.source_maps) && return ""
    lines = String[]
    for m in spec.source_maps
        cur = _sm_bound(m)
        # The last transform must land on the target variable, so work out up front which
        # one that is. An intermediate gets its own name; nothing else may claim the target.
        last_is_split = m.separator !== nothing && m.string_before === nothing
        stem = replace(m.variable, "?" => "")
        if m.separator !== nothing
            dest = last_is_split ? m.variable : "?__sp$stem"
            push!(
                lines,
                "$(indent)$dest <$APF_STRSPLIT> ($cur \"$(escape_literal(regex_quote(m.separator)))\") .",
            )
            cur = dest
        end
        if m.string_before !== nothing
            sb = "\"$(escape_literal(m.string_before))\""
            # "If the object string does not match the incoming value, the incoming value
            # must be retained unchanged" -- so not a bare STRBEFORE, which returns the empty
            # string when the needle is absent and would silently blank every value that
            # happens not to contain it.
            push!(
                lines,
                "$(indent)BIND(IF(CONTAINS($cur, $sb), STRBEFORE($cur, $sb), $cur) AS $(m.variable))",
            )
            cur = m.variable
        end
        m.pattern_match === nothing || push!(
            lines,
            "$(indent)FILTER(REGEX($(m.variable), \"$(escape_literal(m.pattern_match))\"))",
        )
        m.pattern_exclude === nothing || push!(
            lines,
            "$(indent)FILTER(!REGEX($(m.variable), \"$(escape_literal(m.pattern_exclude))\"))",
        )
    end
    # A leading newline and none trailing, which is the convention every other section of
    # `where_body` follows: `graph_wrap` closes with "}" and no newline, so a section that
    # ended with one instead would put a blank line before whatever came next.
    return isempty(lines) ? "" : "\n" * join(lines, "\n")
end

"""
    check_source_maps(spec) -> spec

Refuse a rule whose source maps cannot be evaluated.

A source map reads a column, and the only thing that makes columns exist is a
`gistp:TabularDataSource` on the match pattern -- which is what compiles to the `SERVICE`
the generated triples go inside. Without one there is no row container and
[`FX_ROW_VAR`](@ref) would range over whatever the dataset clause happens to hold: not an
error, just a rule that matches the wrong thing or nothing at all.
"""
function check_source_maps(spec::RuleSpec)
    isempty(spec.source_maps) && return spec
    spec.match_scope !== nothing && haskey(spec.services, spec.match_scope) || error(
        "rule <$(spec.iri)>: $(length(spec.source_maps)) gistp:SourceMap(s) " *
        "($(join((m.variable for m in spec.source_maps), ", "))) but the match pattern " *
        "<$(spec.match_graph)> has no jhp:inGraph naming a gistp:TabularDataSource. A " *
        "source map reads a column, and only a data source makes columns exist -- " *
        "without one the generated row variable would range over whatever the dataset " *
        "clause holds, matching the wrong thing rather than failing.",
    )
    # A mapped variable must not also be bound by the authored pattern: the generated triple
    # and the authored one would join, quietly requiring the column and the pattern to agree.
    authored = Set{String}()
    for t in spec.match, pos in (t.subject, t.predicate, t.object)
        is_var_literal(pos) && push!(authored, (pos::RDFLiteral).lexical)
    end
    clash = sort!([m.variable for m in spec.source_maps if m.variable in authored])
    isempty(clash) || error(
        "rule <$(spec.iri)>: $(join(clash, ", ")) is both fed by a gistp:SourceMap and " *
        "bound by the match pattern <$(spec.match_graph)>. The generated triple and the " *
        "authored one would join, so the rule would quietly require the column and the " *
        "pattern to carry the same string. Let the source map bind it, and drop it from the " *
        "pattern.",
    )
    return spec
end
#################################################################
#    Rule sets
#################################################################
#
# A rule set is a gist:OrderedCollection, not an rdf:List. The reason is that SPARQL cannot
# recover a position from a list: a property path walks the spine and yields membership as a
# SET -- which is exactly right for gistp:oneOf, where authored order has no semantics, and
# exactly wrong here. gist:sequence is a literal on the membership node, so the whole order
# arrives from one ORDER BY rather than one round trip per member.
#
# The membership is reified, which also means the position belongs to the MEMBERSHIP rather
# than to the rule: one rule can sit at different places in different sets. jhp:priority
# cannot express that, being a property of a rule in isolation -- so it survives as the
# ordering of last resort rather than as the mechanism.

const GIST_NS = "https://w3id.org/semanticarts/ns/ontology/gist/"

const C_RULESET = JHP_NS * "RuleSet"
const P_ISMEMBEROF = GIST_NS * "isMemberOf"
const P_ISFIRSTMEMBEROF = GIST_NS * "isFirstMemberOf"
const P_PROVIDESORDERFOR = GIST_NS * "providesOrderFor"
const P_SEQUENCE = GIST_NS * "sequence"

"""
Everything the driver needs about one rule set, already fetched.

`rules` holds rule IRIs rather than loaded `RuleSpec`s, in the order they are to be applied.
Resolving a rule costs about a dozen round trips, and a caller that wants only to inspect a
set's membership should not pay for all of them.

`strategy` and `max_iterations` are the **set's own**, independent of its members'. Each rule
still iterates according to its own declaration; these govern how many times the whole
ordered pass is made.
"""
struct RuleSetSpec
    iri::String
    label::String
    rules::Vector{String}
    strategy::Union{Symbol,Nothing}     # :Once, :ToFixpoint, or unstated
    max_iterations::Union{Int,Nothing}
end

"""
    load_rule_set(set_iri; ep = endpoint()) -> RuleSetSpec

Read one `jhp:RuleSet` out of the store, resolving its membership into an execution order.

Order is `gist:sequence` ascending, then `jhp:priority` descending, then IRI. The second
key is not decoration: equal sequence numbers are legal and mean "rank unspecified between
these", and falling back on priority is the only interpretation that uses what the author
actually said. The third is there so that a set with genuine ties still compiles to the same
order twice running -- an engine whose output depends on the store's row order is not
reproducible, whatever the rules say.

Every membership is fetched with `OPTIONAL` and then checked, rather than joined on. A join
would drop a member missing its `gist:sequence` or its `gist:providesOrderFor` and silently
run a *shorter* set -- the same failure `load_filters` guards against, and worse here,
because a missing rule in a cascade produces a plausible answer rather than an error.
"""
function load_rule_set(set_iri::AbstractString; ep::SparqlEndpoint=endpoint())
    s = check_iri(set_iri)

    typed = select("SELECT ?t WHERE { <$s> a <$C_RULESET> BIND(1 AS ?t) }"; ep=ep)
    isempty(typed) && error(
        "no rule set found at <$s>: it must be typed jhp:RuleSet in the default graph.",
    )

    labels = select("SELECT ?label WHERE { <$s> <$SKOS_LABEL> ?label }"; ep=ep)
    label = if isempty(labels)
        ""
    else
        (
            if labels[1]["label"] isa RDFLiteral
                (labels[1]["label"]::RDFLiteral).lexical
            else
                ""
            end
        )
    end

    rows = select(
        """
SELECT ?m ?rule ?seq WHERE {
  ?m <$P_ISMEMBEROF> <$s> .
  OPTIONAL { ?m <$P_PROVIDESORDERFOR> ?rule }
  OPTIONAL { ?m <$P_SEQUENCE>         ?seq }
}""";
        ep=ep,
    )

    isempty(rows) && error(
        "rule set <$s> has no members. An empty set applies nothing, which is a typo " *
        "rather than an intent -- a set exists to say what runs and in what order.",
    )

    entries = Tuple{Int,Int,String}[]     # (sequence, -priority, rule IRI)
    for r in rows
        # A membership may be a blank node -- that is gist's own idiom -- and it is only
        # ever named back in an error, so render it instead of demanding an IRI. The RULE it
        # orders must still be an IRI: a rule without identity cannot be loaded or undone.
        member = sparql_text(r["m"])
        haskey(r, "rule") || error(
            "rule set <$s>: member $member has no gist:providesOrderFor, so it holds a " *
            "position for nothing. Point it at a jhp:Rule or remove it.",
        )
        haskey(r, "seq") || error(
            "rule set <$s>: member $member has no gist:sequence, so its position in the " *
            "set is unstated and the set cannot be ordered. gist:precedesDirectly is not " *
            "read here -- give the member an integer.",
        )
        rule = _iri(r["rule"])
        istyped = select("SELECT ?t WHERE { <$rule> a <$C_RULE> BIND(1 AS ?t) }"; ep=ep)
        isempty(istyped) && error(
            "rule set <$s>: member $member orders <$rule>, which is not typed " *
            "jhp:Rule. A set orders rules; ordering anything else would compile to " *
            "nothing and run silently.",
        )
        push!(
            entries,
            (parse(Int, (r["seq"]::RDFLiteral).lexical), -load_priority(rule; ep=ep), rule),
        )
    end

    sort!(entries)
    rules = [e[3] for e in entries]

    length(unique(rules)) == length(rules) || error(
        "rule set <$s> orders the same rule at more than one position: " *
        "$(join(sort(unique([r for r in rules if count(==(r), rules) > 1])), ", ")). " *
        "A rule applied twice in one pass is either a typo or a fixpoint written by hand -- " *
        "declare jhp:strategy jhp:ToFixpoint on the rule instead.",
    )

    # gist lets a collection name its first member outright. If that disagrees with the
    # sequence numbers the set states its own order two ways and they contradict, which is
    # worth failing on: whichever one the engine honoured, the other would be a lie.
    firsts = select(
        "SELECT ?m ?rule WHERE { ?m <$P_ISFIRSTMEMBEROF> <$s> ; <$P_PROVIDESORDERFOR> ?rule }";
        ep=ep,
    )
    for f in firsts
        declared = _iri(f["rule"])
        declared == rules[1] || error(
            "rule set <$s>: $(sparql_text(f["m"])) is gist:isFirstMemberOf the set and orders " *
            "<$declared>, but the lowest gist:sequence belongs to <$(rules[1])>. The set " *
            "states its order twice and the two disagree.",
        )
    end

    return RuleSetSpec(
        s, label, rules, load_strategy(s; ep=ep), load_max_iterations(s; ep=ep)
    )
end

"""
    list_rule_sets(; ep = endpoint()) -> Vector{NamedTuple}

Every `jhp:RuleSet` in the store, with its label and membership count, for a catalogue.
"""
function list_rule_sets(; ep::SparqlEndpoint=endpoint())
    rows = select(
        """
SELECT ?s ?label (COUNT(DISTINCT ?m) AS ?members) WHERE {
  ?s a <$C_RULESET> .
  OPTIONAL { ?s <$SKOS_LABEL> ?label }
  OPTIONAL { ?m <$P_ISMEMBEROF> ?s }
} GROUP BY ?s ?label ORDER BY ?s""";
        ep=ep,
    )
    lex(r, k) = haskey(r, k) && r[k] isa RDFLiteral ? (r[k]::RDFLiteral).lexical : ""
    return [
        (
            iri=_iri(r["s"]),
            label=lex(r, "label"),
            members=parse(Int, (r["members"]::RDFLiteral).lexical),
        ) for r in rows
    ]
end

export PatternTriple,
    RuleSpec, MintSpec, load_rule, load_pattern, load_variables, load_mints
export rule_catalogue
export compile_rule, compile_from_store, insert_query, rewrite_query, project_query
export list_rules, mode_symbol
export interface, match_only, construct_only, dangling_risks
export var_of, term_sparql, bgp_text, vars_in, check_bound, check_mints, check_variables
export NacSpec, nacs_text, where_body, strategy_symbol, check_no_blanks, check_positions
export load_filters, filters_text, check_filters
export load_enums, values_text, enum_vars, check_enums
export load_nac_graphs, load_strategy, load_priority, load_max_iterations
export RuleSetSpec, load_rule_set, list_rule_sets, C_RULESET, GIST_NS
export STRATEGY_ONCE, STRATEGY_TOFIXPOINT
export parse_template, template_slots, bind_text, minted_vars
export ambiguous_separators, collision_queries, check_collisions, mint_fanin
export GISTP_NS, JHP_NS, MODE_CONSTRUCT, MODE_ASSERT, MODE_REWRITE
export read_scopes, write_scope, promote_query
export SourceMapSpec, load_source_maps, source_map_bgp, source_map_pipeline
export check_source_maps, fx_predicate, regex_quote, XYZ_NS, FX_ROW_VAR
export load_in_graph,
    load_services,
    is_scoped,
    all_scopes,
    graph_scopes,
    dataset_lines,
    graph_wrap,
    check_scopes,
    scope_vars,
    match_text
