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
"""
function prune_known!(firing_graph::AbstractString, source::AbstractVector;
                      ep::SparqlEndpoint = endpoint())
    isempty(source) && return nothing
    alternatives = join(("{ GRAPH <$(check_iri(g))> { ?s ?p ?o } }" for g in source), "\n      UNION ")
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
"""
function run_rule(spec::RuleSpec; source::AbstractVector = String[],
                  actor::AbstractString = "jayhawk", max_iterations::Integer = 100,
                  ep::SparqlEndpoint = endpoint())
    mode = mode_symbol(spec)
    mode === :Rewrite && error(
        "rule <$(spec.iri)>: gistp:Rewrite is not supported yet; see compile_rule.")

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
    undo_firing!(graph; ep = endpoint()) -> Nothing

Reverse one firing: drop its graph and retract its provenance record.

Complete for `Construct` and `Assert`, which only ever add. A `Rewrite` firing will also
need its tombstone graph replayed, which is why round 1 does not compile that mode.
"""
function undo_firing!(graph::AbstractString; ep::SparqlEndpoint = endpoint())
    g = check_iri(graph)
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

export Firing, apply_rule, run_rule, undo_firing!, firings, graph_size
export PROVENANCE_GRAPH, new_firing_graph
