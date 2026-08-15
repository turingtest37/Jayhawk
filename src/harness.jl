# Executing compiled rules against a store.
#
# `Construct` and `Assert` compile to identical SPARQL; the whole difference lives here.
# Construct takes f(G) as the answer. Assert unions f(G) back into the working set and
# applies the rule again, to a least fixpoint.
#
# Every application writes into a *fresh named graph* rather than into the data. That buys
# three things at once: the result is attributable (which rule, when, over what), it is
# reviewable before anyone merges it, and undo is `DROP GRAPH`. For an engine whose stated
# purpose is to let AI agents mutate enterprise data, reversibility is not a nice-to-have.
#
# Round 1 is additive only -- no rule deletes anything -- so DROP is a complete undo. When
# gistp:Rewrite lands, deletions must additionally be captured into a tombstone graph in the
# same atomic update, because DROP cannot restore what a rule removed.

using UUIDs

const PROV_NS = "http://www.w3.org/ns/prov#"
const JH_NS   = "http://www.semanticweb.org/doug/ontologies/jayhawk#"

"Named graph holding the record of every rule firing."
const PROVENANCE_GRAPH = "urn:jayhawk:provenance"

"""
The record of one rule application.

`graph` is the named graph holding exactly the triples this application contributed --
already stripped of anything the working set had, so `count` is genuinely new facts.
"""
struct Firing
    graph::String
    rule::String
    mode::Symbol
    iteration::Int
    count::Int
    source::Vector{String}
end

Base.show(io::IO, f::Firing) = print(io,
    "Firing(", f.rule, " [", f.mode, "] iter ", f.iteration, " -> ",
    f.count, " new triple", f.count == 1 ? "" : "s", " in <", f.graph, ">)")

new_firing_graph() = string("urn:jayhawk:firing:", UUIDs.uuid4())

_now_xsd() = string(Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS"), "Z")

"How many triples are in a named graph."
function graph_size(g::AbstractString; ep::SparqlEndpoint = endpoint())
    rows = select("SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$(check_iri(g))> { ?s ?p ?o } }"; ep = ep)
    isempty(rows) ? 0 : parse(Int, (rows[1]["n"]::RDFLiteral).lexical)
end

"""
    prune_known!(firing_graph, source; ep)

Delete from `firing_graph` every triple the working set already contained.

Without this a firing graph re-states facts that were already true, `count` never reaches
zero, and an `Assert` fixpoint never converges. It also keeps each firing graph meaning
exactly one thing: the facts this application *added*.

An empty `source` means the working set is the store's *default* graph, so that is what the
firing is pruned against. This used to return early and prune nothing, which left `count`
reporting facts the store already held -- directly contradicting `Firing`'s own docstring.
The bare `{ ?s ?p ?o }` alternative below reads the default graph because this update
carries no `USING`.
"""
function prune_known!(firing_graph::AbstractString, source::AbstractVector;
                      ep::SparqlEndpoint = endpoint())
    alternatives = isempty(source) ? "{ ?s ?p ?o }" :
        join(("{ GRAPH <$(check_iri(g))> { ?s ?p ?o } }" for g in source), "\n      UNION ")
    update!("""
        DELETE { GRAPH <$(check_iri(firing_graph))> { ?s ?p ?o } }
        WHERE {
          GRAPH <$(check_iri(firing_graph))> { ?s ?p ?o }
          { $alternatives }
        }"""; ep = ep)
    nothing
end

"Write the provenance record for one firing."
function record_firing!(f::Firing; actor::AbstractString, ep::SparqlEndpoint = endpoint())
    srcs = isempty(f.source) ? "" :
        join(("    <$(f.graph)> <$(JH_NS)sourceGraph> <$(check_iri(g))> ." for g in f.source), "\n") * "\n"
    mode_iri = f.mode === :Construct ? MODE_CONSTRUCT :
               f.mode === :Assert    ? MODE_ASSERT    : MODE_REWRITE
    update!("""
        INSERT DATA { GRAPH <$PROVENANCE_GRAPH> {
            <$(f.graph)> a <$(PROV_NS)Entity> , <$(JH_NS)Firing> ;
                <$(PROV_NS)generatedAtTime> "$(_now_xsd())"^^<http://www.w3.org/2001/XMLSchema#dateTime> ;
                <$(JH_NS)appliedRule> <$(f.rule)> ;
                <$(JH_NS)rewriteMode> <$mode_iri> ;
                <$(JH_NS)actor> "$(escape_literal(actor))" ;
                <$(JH_NS)iteration> $(f.iteration) ;
                <$(JH_NS)tripleCount> $(f.count) .
        $(srcs)} }"""; ep = ep)
    nothing
end

"""
    apply_rule(rule; into = new_firing_graph(), source = String[], actor = "jayhawk",
               iteration = 1, ep = endpoint()) -> Firing

Apply a rule once. `rule` may be a rule IRI or an already-loaded [`RuleSpec`](@ref).

The result lands in `into`, is pruned of facts `source` already held, and is recorded in the
provenance graph. A firing that contributed nothing is dropped rather than left as an empty
graph.
"""
apply_rule(rule_iri::AbstractString; ep::SparqlEndpoint = endpoint(), kw...) =
    apply_rule(load_rule(rule_iri; ep = ep); ep = ep, kw...)

function apply_rule(spec::RuleSpec; into::AbstractString = new_firing_graph(),
                    source::AbstractVector = String[], actor::AbstractString = "jayhawk",
                    iteration::Integer = 1, ep::SparqlEndpoint = endpoint())
    # Before writing anything: would any minted IRI be reachable from more than one distinct
    # binding? An IRI is an identity claim, so a collision merges two things into one node
    # and nothing downstream ever notices. Static separator analysis happens in compile;
    # this catches what only the data can reveal.
    check_collisions(spec; from = source, ep = ep)
    update!(insert_query(spec; into = into, from = source); ep = ep)
    prune_known!(into, source; ep = ep)
    n = graph_size(into; ep = ep)

    f = Firing(into, spec.iri, mode_symbol(spec), Int(iteration), n, String.(source))
    if n == 0
        update!("DROP SILENT GRAPH <$into>"; ep = ep)   # contributed nothing; leave no litter
    else
        record_firing!(f; actor = actor, ep = ep)
    end
    f
end

"""
    run_rule(rule; source = String[], actor = "jayhawk", max_iterations = 100,
             ep = endpoint()) -> Vector{Firing}

Apply a rule according to its mode.

`Construct` applies once and returns the single firing: the result is `f(G)`, referentially
transparent and composable.

`Assert` iterates. Each round's output joins the working set for the next, so the rule sees
its own consequences, and iteration stops when a round contributes no new triples -- the
least fixpoint.

`max_iterations` is a hard stop, and it is **not** belt-and-braces. Monotone rules over a
fixed set of terms terminate on their own, but `gistp:iriTemplate` mints fresh IRIs, and a
minting rule run to a fixpoint is no longer plain Datalog -- it is the chase, which is not
guaranteed to terminate at all. Hitting the cap raises, naming the rule, rather than
silently returning a partial answer.

**`Assert` requires an explicit `source`.** Each round has to see the previous round's
output, so the working set grows by one named graph per iteration -- and SPARQL's `USING`
*replaces* the query's default graph rather than adding to it, with no IRI anywhere that
denotes the store's own default graph. "The default graph plus the firings so far" is
therefore not expressible, and the previous behaviour was to quietly evaluate round 2
onwards against the firing graphs *alone*: the base data fell out of the working set after
round 1 and the driver returned a strict subset of the least fixpoint while reporting
convergence. A silently incomplete fixpoint is the worst answer this function can give, so
it now refuses instead. `Construct` is unaffected -- it applies once, and an empty source
correctly means the default graph.
"""
function run_rule(spec::RuleSpec; source::AbstractVector = String[],
                  actor::AbstractString = "jayhawk", max_iterations::Integer = 100,
                  ep::SparqlEndpoint = endpoint())
    mode = mode_symbol(spec)
    mode === :Rewrite && error(
        "rule <$(spec.iri)>: gistp:Rewrite is not supported yet; see compile_rule.")
    max_iterations >= 1 || throw(ArgumentError(
        "max_iterations must be at least 1, got $max_iterations."))
    mode === :Assert && isempty(source) && throw(ArgumentError(
        "rule <$(spec.iri)>: gistp:Assert needs an explicit `source`. Each round must see " *
        "the previous round's output, and SPARQL's USING cannot name the store's default " *
        "graph -- so the working set has to be named graphs. Load the data into one and " *
        "pass it as source, or use gistp:Construct for a single application."))

    firings = Firing[]
    working = String[String.(source)...]

    if mode === :Construct
        push!(firings, apply_rule(spec; source = working, actor = actor, iteration = 1, ep = ep))
        return firings
    end

    for i in 1:max_iterations
        f = apply_rule(spec; source = working, actor = actor, iteration = i, ep = ep)
        f.count == 0 && return firings          # converged
        push!(firings, f)
        push!(working, f.graph)                 # the rule now sees its own output
    end

    error("""
          rule <$(spec.iri)>: still producing new triples after $max_iterations iterations. \
          Either raise max_iterations or check for IRI minting via gistp:iriTemplate, which \
          turns fixpoint evaluation into the chase and need not terminate.""")
end

run_rule(rule_iri::AbstractString; ep::SparqlEndpoint = endpoint(), kw...) =
    run_rule(load_rule(rule_iri; ep = ep); ep = ep, kw...)

"""
    dry_run(rule; source = String[], limit = 25, ep = endpoint())
        -> (count = Int, sample = Vector)

Compute what a rule *would* contribute, without keeping it or recording anything.

This is the review surface. A human approving a rule should be reading the facts it
produces, not its SPARQL, and an agent should be able to look before it leaps. The work
happens in a scratch graph that is dropped on every path out, including on error.

The count is of genuinely new triples -- facts the working set already held are pruned
first, exactly as in a real application.
"""
function dry_run(spec::RuleSpec; source::AbstractVector = String[], limit::Integer = 25,
                 ep::SparqlEndpoint = endpoint())
    g = new_firing_graph()
    try
        update!(insert_query(spec; into = g, from = source); ep = ep)
        prune_known!(g, source; ep = ep)
        n = graph_size(g; ep = ep)
        rows = select("""
            SELECT ?s ?p ?o WHERE { GRAPH <$g> { ?s ?p ?o } }
            ORDER BY ?s ?p ?o LIMIT $(Int(limit))"""; ep = ep)
        (count = n, sample = rows)
    finally
        update!("DROP SILENT GRAPH <$g>"; ep = ep)
    end
end

dry_run(rule_iri::AbstractString; ep::SparqlEndpoint = endpoint(), kw...) =
    dry_run(load_rule(rule_iri; ep = ep); ep = ep, kw...)

"""
    is_firing(graph; ep = endpoint()) -> Bool

Whether `graph` is a firing this engine recorded, i.e. whether the provenance graph carries
a `jayhawk:appliedRule` for it.

This is the authority on what [`undo_firing!`](@ref) is allowed to touch. Membership is
decided by the provenance record rather than by the `urn:jayhawk:firing:` IRI prefix,
because a prefix is a naming convention that anyone can imitate and a provenance record is
something only `record_firing!` writes.
"""
is_firing(graph::AbstractString; ep::SparqlEndpoint = endpoint()) =
    ask("""ASK { GRAPH <$PROVENANCE_GRAPH> {
             <$(check_iri(graph))> <$(JH_NS)appliedRule> ?r } }"""; ep = ep)

"""
    undo_firing!(graph; force = false, ep = endpoint()) -> Nothing

Reverse one firing: drop its graph and retract its provenance record.

Complete for `Construct` and `Assert`, which only ever add. A `Rewrite` firing will also
need its tombstone graph replayed, which is why round 1 does not compile that mode.

**This reverses firings, and only firings.** The graph must carry a provenance record or the
call is refused -- without that check the function is a `DROP GRAPH` that accepts any IRI,
and it is reachable from an MCP tool, so the IRI can come straight from a model. The whole
argument for a rule catalogue over an open UPDATE endpoint is that every operation is
named, attributable and reversible; a general-purpose graph delete wearing the name `undo`
gives that back.

`force = true` skips the check, for cleaning up a firing graph whose provenance write did
not land. It is deliberately *not* exposed through [`tool_undo_firing`](@ref).
"""
function undo_firing!(graph::AbstractString; force::Bool = false,
                      ep::SparqlEndpoint = endpoint())
    g = check_iri(graph)
    force || is_firing(g; ep = ep) || error(
        "<$g> is not a recorded firing: <$PROVENANCE_GRAPH> holds no jayhawk:appliedRule " *
        "for it. undo_firing! reverses graphs this engine created and nothing else -- it " *
        "is not a general DROP GRAPH. Use `firings()` to list what can be undone, or pass " *
        "force = true if you are cleaning up a firing whose provenance write failed.")
    update!("DROP SILENT GRAPH <$g>"; ep = ep)
    update!("""
        DELETE WHERE { GRAPH <$PROVENANCE_GRAPH> { <$g> ?p ?o } }"""; ep = ep)
    nothing
end

"""
    firings(; rule = nothing, ep = endpoint()) -> Vector{NamedTuple}

The provenance log, newest first. Optionally filtered to one rule.
"""
function firings(; rule::Union{AbstractString,Nothing} = nothing,
                 ep::SparqlEndpoint = endpoint())
    filt = rule === nothing ? "" : "FILTER(?rule = <$(check_iri(rule))>)"
    rows = select("""
        SELECT ?g ?rule ?at ?n ?actor ?iter WHERE {
          GRAPH <$PROVENANCE_GRAPH> {
            ?g <$(JH_NS)appliedRule>       ?rule ;
               <$(PROV_NS)generatedAtTime> ?at ;
               <$(JH_NS)tripleCount>       ?n ;
               <$(JH_NS)actor>             ?actor ;
               <$(JH_NS)iteration>         ?iter .
          } $filt
        } ORDER BY DESC(?at)"""; ep = ep)
    [(graph = (r["g"]::IRIRef).value,
      rule  = (r["rule"]::IRIRef).value,
      at    = (r["at"]::RDFLiteral).lexical,
      count = parse(Int, (r["n"]::RDFLiteral).lexical),
      actor = (r["actor"]::RDFLiteral).lexical,
      iteration = parse(Int, (r["iter"]::RDFLiteral).lexical)) for r in rows]
end

export Firing, apply_rule, run_rule, dry_run, undo_firing!, is_firing, firings, graph_size
export PROVENANCE_GRAPH, new_firing_graph
