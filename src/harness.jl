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

const JH_NS = "http://www.semanticweb.org/doug/ontologies/jayhawk#"

# gist carries the provenance record, in place of PROV-O. Not a smaller choice than PROV, a
# differently-scoped one: gist is already this project's upper ontology and already a
# dependency of the pattern vocabulary, so the record is expressed in the same terms as the
# data it describes rather than in a second vocabulary that has to be kept in step.
#
# The terms fit without stretching. gist:Event is "something that occurs over a period of
# time, often characterized as an activity being carried out by some person, organization,
# or software application" -- which is a rule firing, exactly. gist:isBasedOn is "the Object
# is a foundation for, a starting point for, gave rise to or justifies the Subject", so a
# firing is based on its rule and on the graphs it read. gist:isProducedBy is "relates
# something to the thing that created, composed, or brought it into existence".
const GIST_ONT_NS = "https://w3id.org/semanticarts/ns/ontology/gist/"

"""
    agent_iri(actor) -> String

The resource for an actor name, so the record can be joined on rather than only read.

`gist:hasParticipant` needs a resource and actor names arrive from a caller or an MCP tool
call, so the name is percent-encoded rather than interpolated. The `jayhawk:actor` literal
stays alongside it: the IRI is for joining, the literal for reading.

`gist:hasParticipant` and not its subproperty `gist:comesFromAgent`, whose range is
`gist:Organization` union `gist:Person`. Most actors here are software -- "mcp", "jayhawk" --
and asserting that one of those is a person is a plain falsehood an OWL reasoner would then
propagate. The superproperty carries no such range and says all that is true: the actor took
part.
"""
agent_iri(actor::AbstractString) = string("urn:jayhawk:actor:", URIs.escapeuri(actor))

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

function Base.show(io::IO, f::Firing)
    return print(
        io,
        "Firing(",
        f.rule,
        " [",
        f.mode,
        "] iter ",
        f.iteration,
        " -> ",
        f.count,
        " added",
        f.removed > 0 ? ", $(f.removed) removed" : "",
        " in <",
        f.graph,
        ">)",
    )
end

new_firing_graph() = string("urn:jayhawk:firing:", UUIDs.uuid4())
new_tombstone_graph() = string("urn:jayhawk:tombstone:", UUIDs.uuid4())

# Milliseconds, not whole seconds. xsd:dateTime permits a fractional part, and without one
# every firing a rule SET produces lands on the same stamp: the rules all run inside one
# second and all report iteration 1, so `firings()` had nothing left to order them by and
# reported them in the wrong order -- stably, which is worse than flakily, because a
# consistently wrong audit log looks like a reliable one. Resolution alone is not a total
# order, so `jayhawk:ordinal` below is the guarantee; this just makes ties rare rather than
# routine.
_now_xsd() = string(Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS.sss"), "Z")

"How many triples are in a named graph."
function graph_size(g::AbstractString; ep::SparqlEndpoint=endpoint())
    rows = select(
        "SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$(check_iri(g))> { ?s ?p ?o } }"; ep=ep
    )
    return isempty(rows) ? 0 : parse(Int, (rows[1]["n"]::RDFLiteral).lexical)
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
function prune_known!(
    firing_graph::AbstractString, source::AbstractVector; ep::SparqlEndpoint=endpoint()
)
    alternatives = if isempty(source)
        "{ ?s ?p ?o }"
    else
        join(("{ GRAPH <$(check_iri(g))> { ?s ?p ?o } }" for g in source), "\n      UNION ")
    end
    update!(
        """
    DELETE { GRAPH <$(check_iri(firing_graph))> { ?s ?p ?o } }
    WHERE {
      GRAPH <$(check_iri(firing_graph))> { ?s ?p ?o }
      { $alternatives }
    }""";
        ep=ep,
    )
    return nothing
end

"Write the provenance record for one firing."
function record_firing!(f::Firing; actor::AbstractString, ep::SparqlEndpoint=endpoint())
    srcs = if isempty(f.source)
        ""
    else
        join(
            (
                "    <$(f.graph)> <$(JH_NS)sourceGraph> <$(check_iri(g))> ." for
                g in f.source
            ),
            "\n",
        ) * "\n"
    end
    # A tombstone graph is typed so it can be recognised on its own, without a join back
    # through the firing that made it. `retractions` reaches them through
    # jayhawk:tombstoneGraph anyway -- so that only graphs this engine wrote are ever
    # searched -- but a graph that can say what it is costs one triple.
    # One stamp, used for both ends. gist:HistoricalEvent is an EQUIVALENT class --
    # gist:Event with exactly one actualStartDateTime and exactly one actualEndDateTime -- so
    # asserting both makes a reasoner classify the firing as historical rather than being
    # told to. Start equals end because the engine does not measure how long an application
    # took; claiming a duration it never observed would be worse than claiming none, and it
    # is the same convention a point event uses everywhere else.
    stamp = _now_xsd()
    # gist:isBasedOn, once per graph the firing read: "the Object is a foundation for, a
    # starting point for, gave rise to or justifies the Subject". The jayhawk:sourceGraph
    # triples say the same thing in the engine's own terms and are what the driver reads;
    # this is what makes the record legible to anything that knows gist and nothing about
    # Jayhawk.
    based = join(
        (
            "    <$(f.graph)> <$(GIST_ONT_NS)isBasedOn> <$(check_iri(g))> .\n" for
            g in f.source
        ),
        "",
    )
    tomb_type = if isempty(f.tombstone)
        ""
    else
        """    <$(f.tombstone)> a <$(JH_NS)Tombstone> ;
        <$(GIST_ONT_NS)isProducedBy> <$(f.graph)> .
"""
    end
    mode_iri = if f.mode === :Construct
        MODE_CONSTRUCT
    elseif f.mode === :Assert
        MODE_ASSERT
    else
        MODE_REWRITE
    end
    # Any firing that touched a graph other than its own is reversible only if undo can find
    # WHICH graph, so the destination is recorded whenever there is one. Tying it to the
    # tombstone was a bug this had: a write-scoped Construct has a target and no tombstone,
    # so its destination went unrecorded, undo found nothing to retract, and the promoted
    # triples stayed in live data with the record already gone. The probe caught it; an inner
    # join would have hidden it.
    tgt = isempty(f.target) ? "" : """
            <$(f.graph)> <$(JH_NS)targetGraph> <$(f.target)> .
    """
    # Removal is the rewrite's half of that: what came out, and how much.
    rw = isempty(f.tombstone) ? "" : """
            <$(f.graph)> <$(JH_NS)tombstoneGraph> <$(f.tombstone)> ;
                <$(JH_NS)removedCount> $(f.removed) .
    """
    # INSERT/WHERE rather than INSERT DATA, so the ordinal is read and written by the same
    # update. Reading the maximum in a separate round trip would leave a window in which two
    # firings could claim the same one -- and an ordinal that is merely usually unique is not
    # a total order, which is the whole point of having it.
    #
    # An aggregate with no GROUP BY yields exactly one row even when its pattern matches
    # nothing, so the first firing into an empty provenance graph gets ordinal 1 rather than
    # no row and no record. That edge case is asserted in the suite, not assumed.
    update!(
        """
    INSERT {
      GRAPH <$PROVENANCE_GRAPH> {
        <$(f.graph)> a <$(JH_NS)Firing> , <$(GIST_ONT_NS)Event> ;
            <$(GIST_ONT_NS)actualStartDateTime> "$(stamp)"^^<http://www.w3.org/2001/XMLSchema#dateTime> ;
            <$(GIST_ONT_NS)actualEndDateTime> "$(stamp)"^^<http://www.w3.org/2001/XMLSchema#dateTime> ;
            <$(GIST_ONT_NS)isBasedOn> <$(f.rule)> ;
            <$(GIST_ONT_NS)hasParticipant> <$(agent_iri(actor))> ;
            <$(JH_NS)ordinal> ?ord ;
            <$(JH_NS)appliedRule> <$(f.rule)> ;
            <$(JH_NS)rewriteMode> <$mode_iri> ;
            <$(JH_NS)actor> "$(escape_literal(actor))" ;
            <$(JH_NS)iteration> $(f.iteration) ;
            <$(JH_NS)tripleCount> $(f.count) .
    $(srcs)$(tgt)$(rw)$(based)$(tomb_type)  }
    } WHERE {
      { SELECT (COALESCE(MAX(?o), 0) + 1 AS ?ord) WHERE {
          GRAPH <$PROVENANCE_GRAPH> { ?any <$(JH_NS)ordinal> ?o } } }
    }""";
        ep=ep,
    )
    return nothing
end

"""
    check_target_empty(into; ep)

Refuse to write a firing into a graph that already holds something.

`into` is a public keyword, and pointing it at occupied data makes two things wrong at once:
`Firing.count` reports that graph's whole size as facts this rule contributed, and
`undo_firing!` later DROPs the caller's data along with the result. The default is a fresh
UUID graph, so this only fires when somebody named one deliberately.
"""
function check_target_empty(into::AbstractString; ep::SparqlEndpoint=endpoint())
    n = graph_size(into; ep=ep)
    n == 0 || throw(
        ArgumentError(
            "target graph <$into> already holds $n triple(s). A firing graph must start empty: " *
            "its size is reported as the facts this rule contributed, and undo_firing! drops " *
            "the whole graph. Use a fresh graph, or omit `into` to get one.",
        ),
    )
    return nothing
end

"""
    apply_rule(rule; into = new_firing_graph(), source = String[], actor = "jayhawk",
               iteration = 1, ep = endpoint()) -> Firing

Apply a rule once. `rule` may be a rule IRI or an already-loaded [`RuleSpec`](@ref).

The result lands in `into`, is pruned of facts `source` already held, and is recorded in the
provenance graph. A firing that contributed nothing is dropped rather than left as an empty
graph.
"""
function apply_rule(rule_iri::AbstractString; ep::SparqlEndpoint=endpoint(), kw...)
    return apply_rule(load_rule(rule_iri; ep=ep); ep=ep, kw...)
end

function apply_rule(
    spec::RuleSpec;
    into::AbstractString=new_firing_graph(),
    source::AbstractVector=String[],
    actor::AbstractString="jayhawk",
    iteration::Integer=1,
    ep::SparqlEndpoint=endpoint(),
)
    # Before writing anything: would any minted IRI be reachable from more than one distinct
    # binding? An IRI is an identity claim, so a collision merges two things into one node
    # and nothing downstream ever notices. Static separator analysis happens in compile;
    # this catches what only the data can reveal.
    check_collisions(spec; from=source, ep=ep)
    check_target_empty(into; ep=ep)

    mode_symbol(spec) === :Rewrite && return apply_rewrite!(
        spec; into=into, source=source, actor=actor, iteration=iteration, ep=ep
    )

    update!(insert_query(spec; into=into, from=source); ep=ep)

    # A declared destination joins the set pruned against, so `count` means "facts new to
    # the place they are going" rather than "facts new to what the rule read". Those differ
    # the moment the destination is not itself a source -- and reporting the wrong one would
    # make a re-run of a converged rule look productive.
    dest = write_scope(spec)
    prune_known!(into, dest === nothing ? source : vcat(String.(source), dest); ep=ep)
    n = graph_size(into; ep=ep)

    # The firing graph stays the unit of attribution and of undo even when the rule writes
    # into live data: promotion copies FROM it, so the destination receives exactly what the
    # record claims. Nothing is promoted when nothing was derived.
    if dest !== nothing && n > 0
        update!(promote_query(; firing=into, target=dest); ep=ep)
    end

    f = if dest === nothing
        Firing(into, spec.iri, mode_symbol(spec), Int(iteration), n, String.(source))
    else
        Firing(
            into,
            spec.iri,
            mode_symbol(spec),
            Int(iteration),
            n,
            String.(source),
            "",
            dest,
            0,
        )
    end
    if n == 0
        update!("DROP SILENT GRAPH <$into>"; ep=ep)   # contributed nothing; leave no litter
    else
        record_firing!(f; actor=actor, ep=ep)
    end
    return f
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
function apply_rewrite!(
    spec::RuleSpec;
    into::AbstractString,
    source::AbstractVector,
    actor::AbstractString,
    iteration::Integer,
    ep::SparqlEndpoint=endpoint(),
)
    length(source) == 1 || throw(
        ArgumentError(
            "rule <$(spec.iri)>: gistp:Rewrite needs exactly one source graph, which is the " *
            "graph it edits; got $(length(source)). Construct and Assert read a union and " *
            "write elsewhere, but a deletion has to name what it deletes from.",
        ),
    )
    target = String(source[1])
    tomb = new_tombstone_graph()

    risks = dangling_risks(spec)
    isempty(risks) || @warn(
        "rule <$(spec.iri)> deletes every triple the pattern knows about for " *
            "$(join(risks, ", ")), and the construct pattern never mentions them. SPARQL " *
            "Update is single-pushout and performs no dangling check, so anything outside " *
            "the pattern still referring to those nodes will be left pointing at nothing.",
        rule = spec.iri,
        variables = risks
    )

    update!(
        rewrite_query(spec; target=target, firing=into, tombstone=tomb, from=[target]);
        ep=ep,
    )

    added = graph_size(into; ep=ep)
    removed = graph_size(tomb; ep=ep)
    f = Firing(
        into, spec.iri, :Rewrite, Int(iteration), added, [target], tomb, target, removed
    )

    if added == 0 && removed == 0
        update!("DROP SILENT GRAPH <$into>"; ep=ep)
        update!("DROP SILENT GRAPH <$tomb>"; ep=ep)
    else
        record_firing!(f; actor=actor, ep=ep)
    end
    return f
end

"Fixpoint bound used when neither the rule nor the caller states one."
const DEFAULT_MAX_ITERATIONS = 100

"""
    effective_strategy(spec; strategy = nothing) -> Symbol

Which application strategy actually governs this run.

Three sources, most specific first: what the caller asked for, what the rule declares with
`gistp:strategy`, and failing both the default for its mode. `Assert` defaults to
`ToFixpoint` because inflationary iteration is what the mode means; `Construct` is a pure
function and `Rewrite` deletes, so both default to `Once`.

The rule-level setting is a default rather than a mandate: the same rule can reasonably be
applied once during review and to a fixpoint in a batch.
"""
function effective_strategy(spec::RuleSpec; strategy::Union{Symbol,Nothing}=nothing)
    s = something(
        strategy, spec.strategy, mode_symbol(spec) === :Assert ? :ToFixpoint : :Once
    )
    s in (:Once, :ToFixpoint) || throw(
        ArgumentError("unknown application strategy :$s; expected :Once or :ToFixpoint."),
    )
    return s
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
function run_rule(
    spec::RuleSpec;
    source::AbstractVector=String[],
    actor::AbstractString="jayhawk",
    strategy::Union{Symbol,Nothing}=nothing,
    max_iterations::Union{Integer,Nothing}=nothing,
    ep::SparqlEndpoint=endpoint(),
)
    mode = mode_symbol(spec)
    strat = effective_strategy(spec; strategy=strategy)
    budget = something(max_iterations, spec.max_iterations, DEFAULT_MAX_ITERATIONS)

    budget >= 1 || throw(ArgumentError("max_iterations must be at least 1, got $budget."))

    # A scoped rule that names no graphs does not read "nothing"; it reads the whole store.
    # Without a dataset clause `GRAPH ?g` enumerates every named graph there is, which here
    # means <urn:jayhawk:provenance> and every firing and tombstone ever written. Refusing is
    # the only safe reading -- there is no sensible default set of graphs.
    !isempty(read_scopes(spec)) &&
        isempty(source) &&
        throw(
            ArgumentError(
                "rule <$(spec.iri)>: a rule whose match pattern or negative condition " *
                "carries gistp:inGraph must name its graphs in `source`. " *
                "With no dataset clause a graph variable ranges over every named graph in the " *
                "store, including <$PROVENANCE_GRAPH> and every firing and tombstone -- so an " *
                "empty `source` is not 'the default graph' here, it is everything.",
            ),
        )

    # A scoped READ still cannot iterate: each round appends its firing graph to the working
    # set, the working set becomes the dataset clause, and from round two the rule would
    # enumerate its own output as a graph to match in.
    #
    # A scoped WRITE can, and this is where it pays off. Its output is promoted into the
    # declared destination instead of being appended to the working set, so the dataset
    # clause never changes and round two reads round one's results from the graph they were
    # written to -- which is a genuine fixpoint over a named graph rather than over a growing
    # pile of firings. It does require the destination to be readable, hence the check below.
    !isempty(read_scopes(spec)) &&
        strat === :ToFixpoint &&
        throw(
            ArgumentError(
                "rule <$(spec.iri)>: gistp:inGraph on the match pattern with a ToFixpoint " *
                "strategy is not supported yet. Each iteration adds its firing graph to the " *
                "working set, so the next round would bind that firing as a graph to match " *
                "in. Declare gistp:strategy gistp:Once, or pass strategy = :Once. " *
                "(A scope on the CONSTRUCT pattern does iterate -- its output is promoted " *
                "into the destination rather than appended to the working set.)",
            ),
        )

    # A write-scoped fixpoint that cannot read its own destination is not a fixpoint: every
    # round would re-derive the same triples, find them already promoted, prune to nothing
    # and report convergence after one productive pass. Which is the right answer by
    # accident, and the wrong one as soon as a second round would have derived anything.
    let dest = write_scope(spec)
        dest === nothing ||
            strat !== :ToFixpoint ||
            dest in source ||
            throw(
                ArgumentError(
                    "rule <$(spec.iri)>: running to a fixpoint while writing into <$dest> " *
                    "needs that graph in `source` as well. Each round has to see what the " *
                    "last one promoted, and the destination is where that output now lives " *
                    "-- it is not appended to the working set the way an unscoped firing is.",
                ),
            )
    end
    strat === :ToFixpoint &&
        isempty(source) &&
        throw(
            ArgumentError(
                "rule <$(spec.iri)>: running to a fixpoint needs an explicit `source`. Each round " *
                "must see the previous round's output, and SPARQL's USING cannot name the store's " *
                "default graph -- so the working set has to be named graphs. Load the data into " *
                "one and pass it as source, or apply the rule once.",
            ),
        )

    # An unbounded destructive loop must never be the default. A Rewrite has no negative
    # condition to say when it is done, so iterating it is a guess unless somebody has
    # thought about how far it should go and said so.
    if strat === :ToFixpoint &&
        mode === :Rewrite &&
        isempty(spec.nacs) &&
        max_iterations === nothing &&
        spec.max_iterations === nothing
        throw(
            ArgumentError(
                "rule <$(spec.iri)>: a gistp:Rewrite run to a fixpoint with no " *
                "gistp:hasNegativeCondition must state a bound. Give the rule a negative " *
                "condition saying when it has already fired, or set gistp:maxIterations -- " *
                "falling back to a default of $DEFAULT_MAX_ITERATIONS destructive passes is " *
                "not a decision this should make for you.",
            ),
        )
    end

    firings = Firing[]
    working = String[String.(source)...]

    if strat === :Once
        push!(firings, apply_rule(spec; source=working, actor=actor, iteration=1, ep=ep))
        return firings
    end

    for i in 1:budget
        f = apply_rule(spec; source=working, actor=actor, iteration=i, ep=ep)
        # A Rewrite changes the target in place, so its working set never grows; it has
        # converged when a pass neither adds nor removes anything.
        f.count == 0 && f.removed == 0 && return firings
        push!(firings, f)
        # A Rewrite edits its target in place, and a write-scoped rule has just promoted its
        # output into the destination -- in both cases the working set already holds the
        # rule's own results and appending the firing graph would only duplicate them into
        # the dataset clause. Only an unscoped additive rule needs the append.
        if mode !== :Rewrite && write_scope(spec) === nothing
            push!(working, f.graph)   # the rule now sees its own output
        end
    end

    return error(
        """
        rule <$(spec.iri)>: still changing the graph after $budget iterations. Either \
        raise the bound, add a gistp:hasNegativeCondition saying when the rule has \
        already fired, or check for IRI minting via gistp:iriTemplate, which turns \
        fixpoint evaluation into the chase and need not terminate."""
    )
end

"""
    run_rules(set; source = String[], actor = "jayhawk", strategy = nothing,
              max_iterations = nothing, ep = endpoint()) -> Vector{Firing}

Apply an ordered rule set. `set` may be a `RuleSetSpec`, the IRI of a `gistp:RuleSet`, or a
bare vector of rule IRIs.

Two levels of iteration, and they are independent. Each rule still honours its **own**
`gistp:strategy`, so an `Assert` rule closes internally before the next rule is reached. The
**set's** strategy governs how many times the whole ordered pass is made: `Once` by default,
`ToFixpoint` to repeat until a complete pass neither adds nor removes anything. A cascade
where a later rule feeds an earlier one needs the second, and cannot be expressed by rule
strategies alone.

Given a bare vector, order is `gistp:priority` descending then IRI -- the case that keeps
`gistp:priority` useful now that `gist:sequence` carries set-relative order. Note the
directions disagree: priority is higher-first, `gist:sequence` is lower-first.

**Mixed modes are refused.** An additive rule's output is a new named graph that must join
the working set for later rules to see it, but a `gistp:Rewrite` needs exactly one source
graph, which is also its target. Those requirements are contradictory the moment an additive
rule has fired, so a set is either all-`Rewrite` -- mutating one graph in place, the working
set never growing -- or contains none at all. Refusing is the only honest option: the
alternative is handing the rewrite the original graph alone and quietly denying it everything
the set derived.

A rule that contributes nothing yields no `Firing`. `apply_rule` drops such a graph without
recording provenance, so returning it would hand back a firing that `undo_firing!` must
refuse -- and a caller undoing a whole run should not have to know which of its members
happened to be no-ops.
"""
function run_rules(
    set::RuleSetSpec;
    source::AbstractVector=String[],
    actor::AbstractString="jayhawk",
    strategy::Union{Symbol,Nothing}=nothing,
    max_iterations::Union{Integer,Nothing}=nothing,
    ep::SparqlEndpoint=endpoint(),
)
    specs = [load_rule(r; ep=ep) for r in set.rules]
    return _run_rule_sequence(
        specs,
        set.iri,
        something(strategy, set.strategy, :Once),
        something(max_iterations, set.max_iterations, DEFAULT_MAX_ITERATIONS);
        source=source,
        actor=actor,
        ep=ep,
    )
end

function run_rules(set_iri::AbstractString; ep::SparqlEndpoint=endpoint(), kw...)
    return run_rules(load_rule_set(set_iri; ep=ep); ep=ep, kw...)
end

function run_rules(
    rule_iris::AbstractVector;
    source::AbstractVector=String[],
    actor::AbstractString="jayhawk",
    strategy::Union{Symbol,Nothing}=nothing,
    max_iterations::Union{Integer,Nothing}=nothing,
    ep::SparqlEndpoint=endpoint(),
)
    isempty(rule_iris) && throw(
        ArgumentError(
            "run_rules was given no rules. An empty run is a caller bug, not a no-op."
        ),
    )
    specs = [load_rule(String(r); ep=ep) for r in rule_iris]
    # Higher priority first; IRI breaks genuine ties so two runs of the same set agree.
    order = sortperm(collect(zip((-s.priority for s in specs), (s.iri for s in specs))))
    return _run_rule_sequence(
        specs[order],
        "(ad-hoc rule list)",
        something(strategy, :Once),
        something(max_iterations, DEFAULT_MAX_ITERATIONS);
        source=source,
        actor=actor,
        ep=ep,
    )
end

"The shared driver behind every `run_rules` method. `label` only ever appears in errors."
function _run_rule_sequence(
    specs::AbstractVector{RuleSpec},
    label::AbstractString,
    set_strategy::Symbol,
    budget::Integer;
    source::AbstractVector,
    actor::AbstractString,
    ep::SparqlEndpoint=endpoint(),
)
    set_strategy in (:Once, :ToFixpoint) || throw(
        ArgumentError(
            "rule set $label: unknown strategy :$set_strategy; expected :Once or :ToFixpoint.",
        ),
    )
    budget >= 1 || throw(
        ArgumentError("rule set $label: max_iterations must be at least 1, got $budget."),
    )

    rewrites = [s.iri for s in specs if mode_symbol(s) === :Rewrite]
    # An additive rule with no declared destination is the one that cannot share a set with a
    # Rewrite. Its output goes to a fresh firing graph which has to JOIN THE WORKING SET for
    # later rules to read it -- and a Rewrite takes exactly one source graph, which is its
    # target, so after the first such firing there is no source it can accept.
    #
    # Give those rules a gistp:inGraph on their construct pattern and the contradiction goes
    # away: the output is promoted into the named destination instead, the working set never
    # grows, and a Rewrite later in the set reads the derived triples from the graph they were
    # written to. That is what write-side scoping bought beyond materialisation -- the mixed
    # set stopped being a design question and became a precondition somebody can satisfy.
    floating = [
        s.iri for s in specs if mode_symbol(s) !== :Rewrite && write_scope(s) === nothing
    ]
    if !isempty(rewrites) && !isempty(floating)
        throw(
            ArgumentError(
                "rule set $label mixes gistp:Rewrite with additive rules that do not say " *
                "where their output goes. Rewrite rules: $(join(rewrites, ", ")). Additive " *
                "rules with no destination: $(join(floating, ", ")). An undirected additive " *
                "rule writes into a fresh firing graph which must join the working set for " *
                "later rules to read it, but a Rewrite takes exactly one source graph and " *
                "that graph is its target -- so after the first such firing there is no " *
                "source it can accept. Give each of those rules gistp:inGraph on its " *
                "construct pattern naming the graph the Rewrite reads, and the set composes; " *
                "or split it in two and run them in sequence.",
            ),
        )
    end

    set_strategy === :ToFixpoint &&
        isempty(source) &&
        throw(
            ArgumentError(
                "rule set $label: running a set to a fixpoint needs an explicit `source`. Each " *
                "pass must see the previous pass's output, and SPARQL's USING cannot name the " *
                "store's default graph -- so the working set has to be named graphs.",
            ),
        )

    firings = Firing[]
    working = String[String.(source)...]

    for pass in 1:budget
        changed = false
        for spec in specs
            for f in run_rule(spec; source=working, actor=actor, ep=ep)
                # Nothing contributed: apply_rule already dropped the graph and wrote no
                # provenance, so this firing is not undoable and must not be handed back.
                (f.count == 0 && f.removed == 0) && continue
                push!(firings, f)
                changed = true
                # Only an UNDIRECTED additive firing is appended. A Rewrite edits its target
                # in place and a write-scoped rule has promoted its output into the declared
                # graph, so in both cases the working set already holds the rule's results and
                # appending would duplicate them into the dataset clause. Appending when it is
                # needed is what makes a set a cascade rather than a batch; not appending when
                # it is not is what lets a Rewrite share the set.
                if mode_symbol(spec) !== :Rewrite && write_scope(spec) === nothing
                    push!(working, f.graph)
                end
            end
        end
        set_strategy === :Once && return firings
        changed || return firings
    end

    return error(
        """
        rule set $label: still changing the graph after $budget passes. Either raise the \
        bound, or find the rule pair that keeps re-deriving -- a set that will not settle \
        usually has two rules whose outputs feed each other, which is a confluence \
        question the derived interface I cannot answer."""
    )
end

function run_rule(rule_iri::AbstractString; ep::SparqlEndpoint=endpoint(), kw...)
    return run_rule(load_rule(rule_iri; ep=ep); ep=ep, kw...)
end

"""
    dry_run_rewrite(spec; source, limit, ep) -> (count, sample, removed, removed_sample)

What a `Rewrite` would delete and add, computed from the live data without touching it.

Both halves are projected into scratch graphs from the *same* match solutions the real
rewrite would use, so this is a preview rather than an estimate. The target graph is only
ever read. Both scratch graphs are dropped on every path out, including on error.
"""
function dry_run_rewrite(
    spec::RuleSpec; source::AbstractVector, limit::Integer=25, ep::SparqlEndpoint=endpoint()
)
    length(source) == 1 || throw(
        ArgumentError(
            "rule <$(spec.iri)>: gistp:Rewrite needs exactly one source graph; got $(length(source)).",
        ),
    )
    gadd, gdel = new_firing_graph(), new_firing_graph()
    peek(g) = select(
        """
SELECT ?s ?p ?o WHERE { GRAPH <$g> { ?s ?p ?o } }
ORDER BY ?s ?p ?o LIMIT $(Int(limit))""";
        ep=ep,
    )
    try
        for (g, ts) in ((gadd, construct_only(spec)), (gdel, match_only(spec)))
            q = project_query(spec; triples=ts, into=g, from=source)
            isempty(q) || update!(q; ep=ep)
        end
        # The preview has to prune exactly as the run does, or explain_rule shows a reviewer
        # a number the application will not match: an R \ I triple the target already holds
        # is not something this rule adds.
        prune_known!(gadd, source; ep=ep)
        (
            count=graph_size(gadd; ep=ep),
            sample=peek(gadd),
            removed=graph_size(gdel; ep=ep),
            removed_sample=peek(gdel),
        )
    finally
        update!("DROP SILENT GRAPH <$gadd>"; ep=ep)
        update!("DROP SILENT GRAPH <$gdel>"; ep=ep)
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
function dry_run(
    spec::RuleSpec;
    source::AbstractVector=String[],
    limit::Integer=25,
    ep::SparqlEndpoint=endpoint(),
)
    mode_symbol(spec) === :Rewrite &&
        return dry_run_rewrite(spec; source=source, limit=limit, ep=ep)
    g = new_firing_graph()
    try
        update!(insert_query(spec; into=g, from=source); ep=ep)
        prune_known!(g, source; ep=ep)
        n = graph_size(g; ep=ep)
        rows = select(
            """
  SELECT ?s ?p ?o WHERE { GRAPH <$g> { ?s ?p ?o } }
  ORDER BY ?s ?p ?o LIMIT $(Int(limit))""";
            ep=ep,
        )
        (count=n, sample=rows)
    finally
        update!("DROP SILENT GRAPH <$g>"; ep=ep)
    end
end

function dry_run(rule_iri::AbstractString; ep::SparqlEndpoint=endpoint(), kw...)
    return dry_run(load_rule(rule_iri; ep=ep); ep=ep, kw...)
end

"""
    is_firing(graph; ep = endpoint()) -> Bool

Whether `graph` is a firing this engine recorded, i.e. whether the provenance graph carries
a `jayhawk:appliedRule` for it.

This is the authority on what [`undo_firing!`](@ref) is allowed to touch. Membership is
decided by the provenance record rather than by the `urn:jayhawk:firing:` IRI prefix,
because a prefix is a naming convention that anyone can imitate and a provenance record is
something only `record_firing!` writes.
"""
function is_firing(graph::AbstractString; ep::SparqlEndpoint=endpoint())
    return ask(
        """ASK { GRAPH <$PROVENANCE_GRAPH> {
             <$(check_iri(graph))> <$(JH_NS)appliedRule> ?r } }""";
        ep=ep,
    )
end

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
function undo_firing!(
    graph::AbstractString; force::Bool=false, ep::SparqlEndpoint=endpoint()
)
    g = check_iri(graph)
    force ||
        is_firing(g; ep=ep) ||
        error(
            "<$g> is not a recorded firing: <$PROVENANCE_GRAPH> holds no jayhawk:appliedRule " *
            "for it. undo_firing! reverses graphs this engine created and nothing else -- it " *
            "is not a general DROP GRAPH. Use `firings()` to list what can be undone, or pass " *
            "force = true if you are cleaning up a firing whose provenance write failed.",
        )

    # Whenever a firing touched a graph other than its own, reversing it is not a DROP.
    # There are two such cases and they differ only in whether anything was removed, so the
    # tombstone is OPTIONAL rather than required -- an inner join here would have silently
    # skipped the write-scoped case and left promoted triples behind in the destination,
    # with the firing record already gone and nothing left to say where they came from.
    #
    #   targetGraph, no tombstone   a write-scoped Construct or Assert. Its output was
    #                               promoted into the declared graph, so undo retracts from
    #                               there what the firing graph still holds.
    #   targetGraph and tombstone   a Rewrite. Retract what it added, restore what it
    #                               removed, in that order and in one request.
    rw = select(
        """
SELECT ?target ?tomb WHERE { GRAPH <$PROVENANCE_GRAPH> {
  <$g> <$(JH_NS)targetGraph> ?target .
  OPTIONAL { <$g> <$(JH_NS)tombstoneGraph> ?tomb } } }""";
        ep=ep,
    )
    tomb = if isempty(rw) || !haskey(rw[1], "tomb")
        nothing
    else
        (rw[1]["tomb"]::IRIRef).value
    end
    if !isempty(rw)
        target = (rw[1]["target"]::IRIRef).value
        # Reading the triples to retract out of the firing graph, never re-deriving them
        # from the rule, is what makes this an exact inverse: whatever the destination
        # received is precisely what goes back out.
        restore = if tomb === nothing
            ""
        else
            """ ;
        INSERT { GRAPH <$target> { ?s ?p ?o } }
        WHERE  { GRAPH <$tomb> { ?s ?p ?o } } ;
        DROP SILENT GRAPH <$tomb>"""
        end
        update!(
            """
        DELETE { GRAPH <$target> { ?s ?p ?o } }
        WHERE  { GRAPH <$g> { ?s ?p ?o } }$restore""";
            ep=ep,
        )
    end

    update!("DROP SILENT GRAPH <$g>"; ep=ep)
    # Both subjects the record uses: the firing's own triples and, for a rewrite, the
    # tombstone's type assertion. Everything else the record says hangs off the firing, which
    # is what keeps this a two-line retraction rather than a graph walk.
    tomb_clause = if tomb === nothing
        ""
    else
        """
    DELETE WHERE { GRAPH <$PROVENANCE_GRAPH> { <$tomb> ?tp ?to } } ;
"""
    end
    update!(
        """
    $(tomb_clause)DELETE WHERE { GRAPH <$PROVENANCE_GRAPH> { <$g> ?p ?o } }""";
        ep=ep,
    )
    return nothing
end

"""
    retractions(; subject = nothing, predicate = nothing, object = nothing,
                ep = endpoint()) -> Vector{NamedTuple}

What was once true: every triple a rewrite has removed, with when and by which rule.

This is the question the engine could always answer in principle and never in practice. A
`gistp:Rewrite` writes the triples it removes into a tombstone graph, so the facts survive
the deletion -- but finding them meant knowing a tombstone's IRI, which is a UUID nobody
holds. Here the provenance record is the index: tombstones are reached through
`jayhawk:tombstoneGraph`, so only graphs this engine actually wrote are searched, and each
match arrives already joined to the rule that retracted it and the transaction time it
happened at.

Any of `subject`, `predicate` and `object` may be an IRI to constrain the pattern; omitted
means unconstrained. Results are newest-first on the same total order `firings()` uses.

The two halves of the challenge's question then read symmetrically: what is true now is a
query against the data, and what was once true is this.
"""
function retractions(;
    subject::Union{AbstractString,Nothing}=nothing,
    predicate::Union{AbstractString,Nothing}=nothing,
    object::Union{AbstractString,Nothing}=nothing,
    ep::SparqlEndpoint=endpoint(),
)
    # Bound as a VALUES-free equality on a fresh variable rather than substituted into the
    # BGP, so that a caller-supplied IRI cannot change the query's shape. check_iri rejects
    # anything that is not one.
    filt = join(
        (
            "    FILTER(?$v = <$(check_iri(x))>)" for
            (v, x) in (("s", subject), ("p", predicate), ("o", object)) if x !== nothing
        ),
        "\n",
    )
    rows = select(
        """
SELECT ?s ?p ?o ?tomb ?target ?rule ?at ?ord ?actor WHERE {
  GRAPH <$PROVENANCE_GRAPH> {
    ?f <$(JH_NS)tombstoneGraph>     ?tomb ;
       <$(JH_NS)targetGraph>        ?target ;
       <$(JH_NS)appliedRule>        ?rule ;
       <$(JH_NS)actor>              ?actor ;
       <$(GIST_ONT_NS)actualStartDateTime> ?at .
    OPTIONAL { ?f <$(JH_NS)ordinal> ?ord }
  }
  GRAPH ?tomb { ?s ?p ?o }
$filt
} ORDER BY DESC(?at) DESC(COALESCE(?ord, 0))""";
        ep=ep,
    )
    return [
        (
            subject=sparql_text(r["s"]),
            predicate=sparql_text(r["p"]),
            object=sparql_text(r["o"]),
            rule=(r["rule"]::IRIRef).value,
            at=(r["at"]::RDFLiteral).lexical,
            actor=(r["actor"]::RDFLiteral).lexical,
            target=(r["target"]::IRIRef).value,
            tombstone=(r["tomb"]::IRIRef).value,
            ordinal=haskey(r, "ord") ? parse(Int, (r["ord"]::RDFLiteral).lexical) : 0,
        ) for r in rows
    ]
end

"""
    firings(; rule = nothing, ep = endpoint()) -> Vector{NamedTuple}

The provenance log, newest first. Optionally filtered to one rule.
"""
function firings(;
    rule::Union{AbstractString,Nothing}=nothing, ep::SparqlEndpoint=endpoint()
)
    filt = rule === nothing ? "" : "FILTER(?rule = <$(check_iri(rule))>)"
    rows = select(
        """
SELECT ?g ?rule ?at ?n ?actor ?iter ?rem ?tomb ?ord WHERE {
  GRAPH <$PROVENANCE_GRAPH> {
    ?g <$(JH_NS)appliedRule>       ?rule ;
       <$(GIST_ONT_NS)actualStartDateTime> ?at ;
       <$(JH_NS)tripleCount>       ?n ;
       <$(JH_NS)actor>             ?actor ;
       <$(JH_NS)iteration>         ?iter .
    OPTIONAL { ?g <$(JH_NS)removedCount>   ?rem }
    OPTIONAL { ?g <$(JH_NS)tombstoneGraph> ?tomb }
    OPTIONAL { ?g <$(JH_NS)ordinal>        ?ord }
  } $filt
} ORDER BY DESC(?at) DESC(COALESCE(?ord, 0)) DESC(?iter)""";
        ep=ep,
    )
    return [
        (
            graph=(r["g"]::IRIRef).value,
            rule=(r["rule"]::IRIRef).value,
            at=(r["at"]::RDFLiteral).lexical,
            count=parse(Int, (r["n"]::RDFLiteral).lexical),
            actor=(r["actor"]::RDFLiteral).lexical,
            iteration=parse(Int, (r["iter"]::RDFLiteral).lexical),
            # A Rewrite took facts away. An audit log that reports only what was added is
            # describing half the change.
            removed=haskey(r, "rem") ? parse(Int, (r["rem"]::RDFLiteral).lexical) : 0,
            tombstone=haskey(r, "tomb") ? (r["tomb"]::IRIRef).value : "",
            # 0 for a record written before ordinals existed. Timestamp stays the primary
            # sort key for exactly that reason: an old provenance graph must still read in a
            # sensible order rather than collapsing into one bucket.
            ordinal=haskey(r, "ord") ? parse(Int, (r["ord"]::RDFLiteral).lexical) : 0,
        ) for r in rows
    ]
end

export Firing,
    apply_rule,
    apply_rewrite!,
    check_target_empty,
    run_rule,
    effective_strategy,
    dry_run,
    dry_run_rewrite,
    undo_firing!,
    is_firing,
    firings,
    graph_size
export run_rules, retractions, agent_iri
export PROVENANCE_GRAPH, new_firing_graph, new_tombstone_graph
