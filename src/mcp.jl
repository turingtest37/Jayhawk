# The agent-facing surface of the engine.
#
# The design point that matters more than any of the code below: **rules are the tools, not
# SPARQL**. No enterprise is going to hand an agent an unrestricted UPDATE endpoint, and it
# would be right not to. What is defensible is a catalogue of named, SHACL-validated,
# provenance-stamped, reversible rewrites -- every one of which can be inspected before it
# runs and undone after.
#
# These functions take and return plain Julia values and depend on nothing but the engine,
# so they are testable without the MCP protocol package. bin/mcp_server.jl is the thin
# adapter that exposes them over JSON-RPC.

"""
    tool_list_rules(; ep = endpoint()) -> String

The catalogue: every rule, its mode, and what it is for.
"""
function tool_list_rules(; ep::SparqlEndpoint = endpoint())
    cat = rule_catalogue(; ep = ep)
    isempty(cat) && return "No rules are loaded in this store."
    io = IOBuffer()
    println(io, "$(length(cat)) rule(s):\n")
    for r in cat
        println(io, "- <", r.iri, ">")
        println(io, "    mode: ", r.mode,
                r.mode === :Construct    ? "  (pure: the result is f(G))" :
                r.mode === :Assert       ? "  (monotone: G union f(G), to a fixpoint)" :
                r.mode === :Rewrite      ? "  (in-place rewrite -- NOT YET SUPPORTED)" :
                "  <$(r.mode_iri)> is not a gistp:rewriteMode this engine knows -- " *
                "THIS RULE CANNOT BE RUN")
        isempty(r.label)      || println(io, "    label: ", r.label)
        isempty(r.definition) || println(io, "    ", r.definition)
    end
    String(take!(io))
end

"""
    tool_explain_rule(rule; source = String[], limit = 25, ep = endpoint()) -> String

Show what a rule does: the SPARQL it compiles to, and the facts it would actually produce
against the given working set.

The dry run is the point. A reviewer should be reading the triples a rule creates, not its
query text, and nothing is written or recorded -- the scratch graph is dropped on every path
out.
"""
function tool_explain_rule(rule::AbstractString; source::AbstractVector = String[],
                           limit::Integer = 25, ep::SparqlEndpoint = endpoint())
    spec = load_rule(rule; ep = ep)
    io = IOBuffer()
    println(io, "Rule <", spec.iri, ">")
    println(io, "  mode              : ", mode_symbol(spec))
    println(io, "  match pattern L   : <", spec.match_graph, "> (", length(spec.match), " triples)")
    println(io, "  construct pattern R: <", spec.construct_graph, "> (", length(spec.construct), " triples)")
    bound = sort(collect(vars_in(spec.match, spec)))
    println(io, "  variables bound by L: ", isempty(bound) ? "(none)" : join(bound, ", "))
    println(io, "\ncompiles to:\n")
    println(io, compile_rule(spec))

    d = dry_run(spec; source = source, limit = limit, ep = ep)
    println(io, "\ndry run against ",
            isempty(source) ? "the default graph" : join(("<$g>" for g in source), " + "),
            " would add ", d.count, " new triple(s)",
            d.count == 0 ? "." : ":")
    for r in d.sample
        println(io, "    ", sparql_text(r["s"]), " ", sparql_text(r["p"]), " ", sparql_text(r["o"]), " .")
    end
    d.count > length(d.sample) && println(io, "    ... and ", d.count - length(d.sample), " more")

    # Fan-in is reported, never refused: many-to-one minting is often exactly right, so
    # whether it is a bug depends on modelling intent the pattern cannot state.
    fanin = mint_fanin(spec; from = source, ep = ep)
    if !isempty(fanin)
        println(io, "\nWARNING -- some minted IRIs are built from more than one distinct ",
                "binding, so\none node will carry facts from several sources. Intended for a ",
                "shared node\n(a department per name); a merge bug for a per-person one.")
        for (iri, rows) in fanin
            println(io, "  ", spec.variables[iri], ":")
            for (minted, n) in rows
                println(io, "    <", minted, ">  from ", n, " distinct bindings")
            end
        end
    end

    println(io, "\nNothing was written. Use run_rule to apply it.")
    String(take!(io))
end

"""
    tool_run_rule(rule; source = String[], actor = "mcp", max_iterations = 100,
                  ep = endpoint()) -> String

Apply a rule and report the firings it produced.

Every firing lands in its own named graph, so the result is attributable and each one can be
reversed individually with `undo_firing`.
"""
function tool_run_rule(rule::AbstractString; source::AbstractVector = String[],
                       actor::AbstractString = "mcp", max_iterations::Integer = 100,
                       ep::SparqlEndpoint = endpoint())
    fs = run_rule(rule; source = source, actor = actor,
                  max_iterations = max_iterations, ep = ep)
    total = isempty(fs) ? 0 : sum(f.count for f in fs)
    total == 0 && return "Rule <$rule> applied and derived nothing new. No graph was created."

    io = IOBuffer()
    println(io, "Rule <", rule, "> added ", total, " new triple(s) in ",
            length(fs), " iteration(s).\n")
    for f in fs
        println(io, "  iteration ", f.iteration, ": ", f.count, " triple(s) -> <", f.graph, ">")
    end
    println(io, "\nUndo any of these with undo_firing on its graph IRI.")
    String(take!(io))
end

"""
    tool_undo_firing(graph; ep = endpoint()) -> String

Reverse one firing: drop its graph and retract its provenance record.

Complete for `Construct` and `Assert`, which only add. When `gistp:Rewrite` lands, a firing
will also carry a tombstone graph that has to be replayed.

Only firings. The graph IRI arrives from a model's tool call, so it is checked against the
provenance log before anything is dropped -- see [`undo_firing!`](@ref). The `force` escape
hatch is not plumbed through: nothing reachable over MCP may skip that check.

The order of the two checks is what keeps both properties. Undoing the same firing twice
stays harmless -- after the first undo the provenance record is gone, so the second call
would otherwise be refused rather than shrugged off -- while the case the guard exists for,
a graph that holds data and is *not* a firing, is still refused. An empty graph has nothing
a `DROP` could destroy.
"""
function tool_undo_firing(graph::AbstractString; ep::SparqlEndpoint = endpoint())
    n = graph_size(graph; ep = ep)
    if !is_firing(graph; ep = ep)
        n == 0 && return "Graph <$graph> holds no triples; nothing to undo."
        return(
            "Refused: <$graph> holds $n triple(s) and is not a recorded firing, so " *
            "undo_firing will not touch it. This tool reverses rule applications this " *
            "engine made; it is not a way to delete a graph. Use list_firings to see " *
            "what can be undone.")
    end
    undo_firing!(graph; ep = ep)
    n == 0 ? "Graph <$graph> was already empty; its provenance record was retracted." :
             "Undid <$graph>: $n triple(s) removed and the provenance record retracted."
end

"""
    tool_firings(; rule = nothing, ep = endpoint()) -> String

The provenance log, newest first.
"""
function tool_firings(; rule::Union{AbstractString,Nothing} = nothing,
                      ep::SparqlEndpoint = endpoint())
    log = firings(; rule = rule, ep = ep)
    isempty(log) && return "No firings recorded."
    io = IOBuffer()
    println(io, length(log), " firing(s), newest first:\n")
    for f in log
        println(io, "  ", f.at, "  ", f.count, " triple(s)  by ", f.actor)
        println(io, "      rule  <", f.rule, ">  (iteration ", f.iteration, ")")
        println(io, "      graph <", f.graph, ">")
    end
    String(take!(io))
end

export tool_list_rules, tool_explain_rule, tool_run_rule, tool_undo_firing, tool_firings
