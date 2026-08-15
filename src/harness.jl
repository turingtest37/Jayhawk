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
    # Rewrite only. `tombstone` holds the triples the rewrite removed and `target` names the
    # graph it removed them from; both are empty for the additive modes. DROP GRAPH undoes
    # an addition but cannot restore a deletion, so a rewrite that recorded no tombstone
    # would be irreversible -- and reversibility is the whole argument for letting an agent
    # near this.
    tombstone::String
    target::String
    removed::Int
end

Firing(g, r, m, i, c, s) = Firing(g, r, m, i, c, s, "", "", 0)

Base.show(io::IO, f::Firing) = print(io,
    "Firing(", f.rule, " [", f.mode, "] iter ", f.iteration, " -> ",
    f.count, " added", f.removed > 0 ? ", $(f.removed) removed" : "", " in <", f.graph, ">)")

new_firing_graph() = string("urn:jayhawk:firing:", UUIDs.uuid4())
new_tombstone_graph() = string("urn:jayhawk:tombstone:", UUIDs.uuid4())

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
    # A rewrite is only reversible if undo can find what it removed and where from, so both
    # are part of the record rather than reconstructed later.
    rw = isempty(f.tombstone) ? "" : """
            <$(f.graph)> <$(JH_NS)tombstoneGraph> <$(f.tombstone)> ;
                <$(JH_NS)targetGraph> <$(f.target)> ;
                <$(JH_NS)removedCount> $(f.removed) .
    """
    update!("""
        INSERT DATA { GRAPH <$PROVENANCE_GRAPH> {
            <$(f.graph)> a <$(PROV_NS)Entity> , <$(JH_NS)Firing> ;
                <$(PROV_NS)generatedAtTime> "$(_now_xsd())"^^<http://www.w3.org/2001/XMLSchema#dateTime> ;
                <$(JH_NS)appliedRule> <$(f.rule)> ;
                <$(JH_NS)rewriteMode> <$mode_iri> ;
                <$(JH_NS)actor> "$(escape_literal(actor))" ;
                <$(JH_NS)iteration> $(f.iteration) ;
                <$(JH_NS)tripleCount> $(f.count) .
        $(srcs)$(rw)} }"""; ep = ep)
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

    mode_symbol(spec) === :Rewrite &&
        return apply_rewrite!(spec; into = into, source = source, actor = actor,
                              iteration = iteration, ep = ep)

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
    apply_rewrite!(spec; into, source, actor, iteration, ep) -> Firing

Apply a `gistp:Rewrite`: the one mode that changes the data rather than adding beside it.

**Exactly one source graph, and it is the target.** The other modes read a union and write
elsewhere, so any number of sources is meaningful. A deletion has to name the graph it
deletes from, and "delete from the union of these three" is not something SPARQL can
express or a person can review.

The removed triples are captured into a tombstone graph by the same atomic update that
removes them, because `DROP GRAPH` can undo an addition but nothing can undo a deletion
that was never recorded.
"""
function apply_rewrite!(spec::RuleSpec; into::AbstractString, source::AbstractVector,
                        actor::AbstractString, iteration::Integer,
                        ep::SparqlEndpoint = endpoint())
    length(source) == 1 || throw(ArgumentError(
        "rule <$(spec.iri)>: gistp:Rewrite needs exactly one source graph, which is the " *
        "graph it edits; got $(length(source)). Construct and Assert read a union and " *
        "write elsewhere, but a deletion has to name what it deletes from."))
    target = String(source[1])
    tomb   = new_tombstone_graph()

    risks = dangling_risks(spec)
    isempty(risks) || @warn(
        "rule <$(spec.iri)> deletes every triple the pattern knows about for " *
        "$(join(risks, ", ")), and the construct pattern never mentions them. SPARQL " *
        "Update is single-pushout and performs no dangling check, so anything outside " *
        "the pattern still referring to those nodes will be left pointing at nothing.",
        rule = spec.iri, variables = risks)

    update!(rewrite_query(spec; target = target, firing = into, tombstone = tomb,
                          from = [target]); ep = ep)

    added   = graph_size(into; ep = ep)
    removed = graph_size(tomb; ep = ep)
    f = Firing(into, spec.iri, :Rewrite, Int(iteration), added, [target], tomb, target, removed)

    if added == 0 && removed == 0
        update!("DROP SILENT GRAPH <$into>"; ep = ep)
        update!("DROP SILENT GRAPH <$tomb>"; ep = ep)
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
    max_iterations >= 1 || throw(ArgumentError(
        "max_iterations must be at least 1, got $max_iterations."))
    mode === :Assert && isempty(source) && throw(ArgumentError(
        "rule <$(spec.iri)>: gistp:Assert needs an explicit `source`. Each round must see " *
        "the previous round's output, and SPARQL's USING cannot name the store's default " *
        "graph -- so the working set has to be named graphs. Load the data into one and " *
        "pass it as source, or use gistp:Construct for a single application."))

    firings = Firing[]
    working = String[String.(source)...]

    # Construct applies once by definition. Rewrite also applies once, deliberately:
    # iterating a rule that deletes needs a negative application condition to say when it
    # has already fired, and there is no NAC vocabulary yet. Usually a rewrite cannot
    # re-match anyway, because L \ I is exactly what it just removed -- but "usually" is
    # not a termination argument, and a loop that deletes is not one to guess at.
    if mode === :Construct || mode === :Rewrite
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
    dry_run_rewrite(spec; source, limit, ep) -> (count, sample, removed, removed_sample)

What a `Rewrite` would delete and add, computed from the live data without touching it.

Both halves are projected into scratch graphs from the *same* match solutions the real
rewrite would use, so this is a preview rather than an estimate. The target graph is only
ever read. Both scratch graphs are dropped on every path out, including on error.
"""
function dry_run_rewrite(spec::RuleSpec; source::AbstractVector, limit::Integer = 25,
                         ep::SparqlEndpoint = endpoint())
    length(source) == 1 || throw(ArgumentError(
        "rule <$(spec.iri)>: gistp:Rewrite needs exactly one source graph; got $(length(source))."))
    gadd, gdel = new_firing_graph(), new_firing_graph()
    peek(g) = select("""
        SELECT ?s ?p ?o WHERE { GRAPH <$g> { ?s ?p ?o } }
        ORDER BY ?s ?p ?o LIMIT $(Int(limit))"""; ep = ep)
    try
        for (g, ts) in ((gadd, construct_only(spec)), (gdel, match_only(spec)))
            q = project_query(spec; triples = ts, into = g, from = source)
            isempty(q) || update!(q; ep = ep)
        end
        (count = graph_size(gadd; ep = ep), sample = peek(gadd),
         removed = graph_size(gdel; ep = ep), removed_sample = peek(gdel))
    finally
        update!("DROP SILENT GRAPH <$gadd>"; ep = ep)
        update!("DROP SILENT GRAPH <$gdel>"; ep = ep)
    end
end

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
    mode_symbol(spec) === :Rewrite &&
        return dry_run_rewrite(spec; source = source, limit = limit, ep = ep)
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

    # A Rewrite changed the data in place, so reversing it is not a DROP. Retract what the
    # rule added and restore what it removed, in that order and in one request, reading both
    # halves out of the record the firing itself wrote.
    rw = select("""
        SELECT ?target ?tomb WHERE { GRAPH <$PROVENANCE_GRAPH> {
          <$g> <$(JH_NS)targetGraph> ?target ; <$(JH_NS)tombstoneGraph> ?tomb } }"""; ep = ep)
    if !isempty(rw)
        target = (rw[1]["target"]::IRIRef).value
        tomb   = (rw[1]["tomb"]::IRIRef).value
        update!("""
            DELETE { GRAPH <$target> { ?s ?p ?o } }
            WHERE  { GRAPH <$g> { ?s ?p ?o } } ;
            INSERT { GRAPH <$target> { ?s ?p ?o } }
            WHERE  { GRAPH <$tomb> { ?s ?p ?o } } ;
            DROP SILENT GRAPH <$tomb>"""; ep = ep)
    end

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

export Firing, apply_rule, apply_rewrite!, run_rule, dry_run, dry_run_rewrite, undo_firing!, is_firing, firings, graph_size
export PROVENANCE_GRAPH, new_firing_graph, new_tombstone_graph
