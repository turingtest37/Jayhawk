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
             load_variables(; ep = ep), load_mints(; ep = ep))
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

"""
    load_mints(; ep = endpoint()) -> Dict{String,MintSpec}

Every minted variable: its template and its slot bindings.

One row per slot, grouped here by variable. A variable with a template but no slots comes
back with an empty `slots`, which [`check_mints`](@ref) then rejects -- the shapes catch it
too, but the compiler must not depend on anyone having run them.
"""
function load_mints(; ep::SparqlEndpoint = endpoint())
    rows = select("""
        SELECT ?v ?tmpl ?name ?value WHERE {
          ?v a <$C_SPARQLVAR> ; <$P_IRITEMPLATE> ?tmpl .
          OPTIONAL { ?v <$P_HASSLOT> ?s .
                     ?s <$P_SLOTNAME> ?name ; <$P_SLOTVALUE> ?value . }
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
    bound = vars_in(spec.match, spec)
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
    check_mints(spec)
    matched = vars_in(spec.match, spec)
    bound   = union(matched, minted_vars(spec))
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

    if m === :Rewrite
        error("""
              rule <$(spec.iri)>: gistp:Rewrite is not supported yet. It needs the \
              triple-level interface I = L ∩ R to split DELETE { L∖I } from INSERT { R∖I }, \
              and derived_interface.rq computes shared *variables* rather than shared \
              triples. Use gistp:Assert if the rule only adds facts.""")
    end

    isempty(spec.match) && error("rule <$(spec.iri)>: match pattern <$(spec.match_graph)> is empty.")
    isempty(spec.construct) && error("rule <$(spec.iri)>: construct pattern <$(spec.construct_graph)> is empty.")

    # BINDs go after every triple pattern: BIND sees only variables already bound earlier in
    # its group, and check_mints has guaranteed each slot value is bound by L.
    """
    # $(m) rule <$(spec.iri)>
    CONSTRUCT {
    $(bgp_text(spec.construct, spec))
    }
    WHERE {
    $(bgp_text(spec.match, spec))$(binds_text(spec))
    }
    """
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
    froms = isempty(from) ? "" :
        join(("FROM <$(check_iri(g))>" for g in from), "\n") * "\n"

    for iri in sort(collect(keys(spec.mints)))
        m = spec.mints[iri]
        v = spec.variables[iri]
        key = join(("ENCODE_FOR_URI(STR($(var_of(m.slots[n], spec))))"
                    for n in sort(collect(keys(m.slots)))), ", \" \", ")
        push!(out, (iri, """
        SELECT $v (COUNT(DISTINCT ?__key) AS ?n)
        $(froms)WHERE {
        $(bgp_text(spec.match, spec))
        $(bind_text(m, spec))
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
    froms = isempty(from) ? "" : join(("FROM <$(check_iri(g))>" for g in from), "\n") * "\n"
    others = sort(collect(setdiff(vars_in(spec.construct, spec), minted_vars(spec))))
    isempty(others) && return out
    key = join(("ENCODE_FOR_URI(STR($o))" for o in others), ", \" \", ")

    for iri in sort(collect(keys(spec.mints)))
        v = spec.variables[iri]
        rows = select("""
            SELECT $v (COUNT(DISTINCT ?__ctx) AS ?n)
            $(froms)WHERE {
            $(bgp_text(spec.match, spec))
            $(bind_text(spec.mints[iri], spec))
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
    $(bgp_text(spec.match, spec))$(binds_text(spec))
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
"""
function rule_catalogue(; ep::SparqlEndpoint = endpoint())
    rows = select("""
        SELECT ?r ?mode ?label ?def WHERE {
          ?r a <$C_RULE> ; <$P_MODE> ?mode .
          OPTIONAL { ?r <$SKOS_LABEL> ?label }
          OPTIONAL { ?r <$SKOS_DEFINITION> ?def }
        } ORDER BY ?r"""; ep = ep)
    lex(r, k) = haskey(r, k) && r[k] isa RDFLiteral ? (r[k]::RDFLiteral).lexical : ""
    [(iri = _iri(r["r"]), mode = mode_symbol(_iri(r["mode"])),
      label = lex(r, "label"), definition = lex(r, "def")) for r in rows]
end

export PatternTriple, RuleSpec, MintSpec, load_rule, load_pattern, load_variables, load_mints
export rule_catalogue
export compile_rule, compile_from_store, insert_query, list_rules, mode_symbol
export var_of, term_sparql, bgp_text, vars_in, check_bound, check_mints
export parse_template, template_slots, bind_text, minted_vars
export ambiguous_separators, collision_queries, check_collisions, mint_fanin
export GISTP_NS, MODE_CONSTRUCT, MODE_ASSERT, MODE_REWRITE
