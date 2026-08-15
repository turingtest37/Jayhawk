#!/usr/bin/env julia
#
# Expose the Function-Graph engine over the Model Context Protocol.
#
#     julia --project=. bin/mcp_server.jl
#
# Configure the store with JAYHAWK_SPARQL_SERVICE (default http://localhost:3030/jayhawk),
# started by ./resource/fuseki-test.sh start.
#
# This adapter deliberately lives outside the package. ModelContextProtocol.jl pulls in
# JSON3, StructTypes, DataStructures, MacroTools and OrderedCollections, which is a lot of
# weight for a package whose core is a compiler -- and it exports `register!`, which
# collides with Jayhawk's own. Keeping the wiring in a script means the engine has no new
# dependency and every tool stays testable without the protocol.
#
# Install the protocol package into this project first:
#     julia --project=. -e 'using Pkg; Pkg.add(name="ModelContextProtocol", version="0.4.1")'

using Jayhawk
import ModelContextProtocol as MCP

# ---------------------------------------------------------------------------
# Every tool answers with text. Failures come back as text too, rather than
# escaping as a protocol-level error: an agent can read and act on "rule X uses
# ?idtext which L never binds", but a transport fault tells it nothing.
# ---------------------------------------------------------------------------

text(s::AbstractString) = MCP.TextContent(text = String(s))

function guarded(f)
    return args -> begin
        try
            [text(f(args))]
        catch e
            [text("ERROR: " * sprint(showerror, e))]
        end
    end
end

# `source` arrives as a JSON array of graph IRIs, or is absent for the default graph.
graphs(args, key = "source") =
    haskey(args, key) && args[key] !== nothing ? String.(collect(args[key])) : String[]

str(args, key, default = nothing) =
    haskey(args, key) && args[key] !== nothing ? String(args[key]) : default

TOOLS = [
    MCP.MCPTool(
        name = "list_rules",
        description = """
            List every graph-rewrite rule available in the store, with its mode and purpose.
            Construct rules are pure functions of the graph; Assert rules are monotone and
            run to a fixpoint. Start here to find out what can be applied.""",
        parameters = MCP.ToolParameter[],
        handler = guarded(_ -> tool_list_rules())),

    MCP.MCPTool(
        name = "explain_rule",
        description = """
            Show what a rule would do: the SPARQL it compiles to, and a dry run listing the
            actual triples it would add to the given graphs. Writes nothing. Use this before
            run_rule to review a change in terms of the facts it creates.""",
        parameters = [
            MCP.ToolParameter(name = "rule", type = "string", required = true,
                description = "IRI of the rule, as returned by list_rules."),
            MCP.ToolParameter(name = "source", type = "array", required = false,
                description = "Named graph IRIs to apply the rule to. Omit for the default graph."),
            MCP.ToolParameter(name = "limit", type = "integer", required = false,
                description = "How many sample triples to show (default 25)."),
        ],
        handler = guarded(a -> tool_explain_rule(str(a, "rule");
                                                 source = graphs(a),
                                                 limit = get(a, "limit", 25)))),

    MCP.MCPTool(
        name = "run_rule",
        description = """
            Apply a rule to the given graphs. The derived triples land in a fresh named
            graph rather than in the source data, so the change is attributable and can be
            reversed with undo_firing. Returns the firing graph IRIs.""",
        parameters = [
            MCP.ToolParameter(name = "rule", type = "string", required = true,
                description = "IRI of the rule to apply."),
            MCP.ToolParameter(name = "source", type = "array", required = false,
                description = "Named graph IRIs to apply the rule to. Omit for the default graph."),
            MCP.ToolParameter(name = "actor", type = "string", required = false,
                description = "Who to record as responsible, in the provenance graph."),
            MCP.ToolParameter(name = "max_iterations", type = "integer", required = false,
                description = "Hard stop for Assert rules run to a fixpoint (default 100)."),
        ],
        handler = guarded(a -> tool_run_rule(str(a, "rule");
                                             source = graphs(a),
                                             actor = str(a, "actor", "mcp"),
                                             max_iterations = get(a, "max_iterations", 100)))),

    MCP.MCPTool(
        name = "undo_firing",
        description = """
            Reverse one rule application: drop its graph and retract its provenance record.
            The source data is untouched, because rules in this engine only ever add.""",
        parameters = [
            MCP.ToolParameter(name = "graph", type = "string", required = true,
                description = "Firing graph IRI, as returned by run_rule or list_firings."),
        ],
        handler = guarded(a -> tool_undo_firing(str(a, "graph")))),

    MCP.MCPTool(
        name = "list_firings",
        description = """
            The provenance log: every rule application, newest first, with who ran it, when,
            how many triples it added, and which graph holds them.""",
        parameters = [
            MCP.ToolParameter(name = "rule", type = "string", required = false,
                description = "Restrict the log to one rule IRI."),
        ],
        handler = guarded(a -> tool_firings(rule = str(a, "rule")))),
]

server = MCP.mcp_server(
    name = "jayhawk-function-graph",
    version = "0.2.1",
    tools = TOOLS,
    description = """
        Graph-rewrite rules over an RDF triplestore. Rules are themselves RDF -- a match
        pattern and a construct pattern, each held in its own named graph -- and are
        compiled to SPARQL on demand. Every application is recorded and reversible.""")

@info "Jayhawk MCP server starting" endpoint = Jayhawk.endpoint().query
MCP.start!(server)
