# SPARQL integration tests -- require a running Apache Jena Fuseki.
#
# NOT part of the default suite. `test/runtests.jl` stays hermetic and ~6 seconds; a
# developer with no server running must never see a failure from this file.
#
#     ./resource/fuseki-test.sh start
#     JAYHAWK_TEST_SPARQL=1 julia --project=. test/sparql_integration.jl
#
# Or, to run it together with everything else:
#     JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl
#
# The endpoint is baked into `Jayhawk.spqservice` as a `const` at module load, so
# JAYHAWK_SPARQL_SERVICE must be exported *before* julia starts if the rig is not on
# the default port. The default (http://localhost:3030/jayhawk) already matches
# resource/fuseki-test.sh.
#
# These tests build and drop their own named graph and never touch <urn:ontology>, so
# they neither depend on `fuseki-test.sh load` having run nor disturb it.

using Test
using Jayhawk
using Serd, Serd.RDF

const TEST_GRAPH = "urn:jayhawk:integration-test"

server_reachable() =
    try
        Jayhawk.runsparql("ASK {}")
        true
    catch
        false
    end

@testset "SPARQL integration (Fuseki)" begin

    if !server_reachable()
        error("""
              No SPARQL server answering at $(Jayhawk.spqservice).

              Start one with:  ./resource/fuseki-test.sh start

              (This file is opt-in precisely so that the default suite never depends
              on a live server -- if you did not mean to run it, unset
              JAYHAWK_TEST_SPARQL.)
              """)
    end

    # Clean slate, in case an earlier aborted run left the graph behind.
    Jayhawk.usparql("DROP SILENT GRAPH <$TEST_GRAPH>")

    @testset "endpoints are Fuseki-shaped" begin
        # Fuseki serves query on the bare dataset path; `<base>/sparql` is a 404 under
        # FusekiMainCmd. The update URL is <base>/update, not GraphDB's <base>/statements.
        @test !endswith(Jayhawk.spqservice, "/sparql")
        @test Jayhawk.spqupdservice == Jayhawk.spqservice * "/update" ||
              haskey(ENV, "JAYHAWK_UPDATE_SERVICE")
        @test !endswith(Jayhawk.spqupdservice, "/statements")
    end

    @testset "usparql performs an update" begin
        # Regression: usparql passed its `dict` as a third positional argument to
        # runsparql, which takes two -- so every call died with a MethodError before
        # any request was sent. It never worked.
        Jayhawk.usparql("""
            INSERT DATA {
              GRAPH <$TEST_GRAPH> {
                <http://it.example.org/s1> <http://it.example.org/p> "one" .
                <http://it.example.org/s2> <http://it.example.org/p> "two" .
              }
            }
            """)

        r = Jayhawk.runsparql(
            "SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$TEST_GRAPH> { ?s ?p ?o } }")
        @test r[1]["n"]["value"] == "2"
    end

    @testset "runsparql handles ASK as well as SELECT" begin
        # Regression: runsparql did `r["results"]["bindings"]` unconditionally, but an
        # ASK response is {"head":{}, "boolean":…} with no "results" key -- so every
        # ASK query threw KeyError("results").
        @test Jayhawk.runsparql("ASK {}") === true
        @test Jayhawk.runsparql(
            "ASK { <http://it.example.org/nope> <http://it.example.org/p> ?o }") === false
    end

    @testset "runsparql SELECT returns parsed JSON bindings" begin
        r = Jayhawk.runsparql(
            "SELECT ?s ?o WHERE { GRAPH <$TEST_GRAPH> { ?s ?p ?o } } ORDER BY ?o")
        @test length(r) == 2
        @test r[1]["o"]["value"] == "one"
        @test r[2]["s"]["value"] == "http://it.example.org/s2"
    end

    @testset "qsparql CONSTRUCT parses into statements" begin
        # Regression: qsparql sent Accept: application/sparql-results+json (QHEADERS)
        # and then handed the JSON response to Serd as Turtle, throwing
        # SerdException(SERD_ERR_BAD_SYNTAX). It must ask for N-Triples (QHEADERSCONS).
        stmts, prefixes, base = Jayhawk.qsparql(
            "CONSTRUCT { ?s ?p ?o } WHERE { GRAPH <$TEST_GRAPH> { ?s ?p ?o } }")

        triples = filter(s -> s isa Triple, stmts)
        @test length(triples) == 2
        @test all(t -> t.predicate == Resource("http://it.example.org/p"), triples)
        @test Set(t.object.value for t in triples) == Set(["one", "two"])
    end

    @testset "Mustache bindings reach the query" begin
        # runsparql renders the query as a Mustache template against `m`; usparql
        # forwards its `dict` there. This is the path the positional-argument bug broke.
        Jayhawk.usparql(
            "INSERT DATA { GRAPH <$TEST_GRAPH> { <http://it.example.org/s3> <http://it.example.org/p> \"{{val}}\" } }";
            dict = Dict("val" => "three"))

        r = Jayhawk.runsparql(
            "SELECT ?o WHERE { GRAPH <$TEST_GRAPH> { <http://it.example.org/s3> ?p ?o } }")
        @test r[1]["o"]["value"] == "three"
    end

    @testset "named-graph convention used by src/sparql.jl" begin
        # Every query constant in src/sparql.jl hardcodes GRAPH <urn:ontology>. This
        # only asserts the mechanism works; it does not require the fixtures to be
        # loaded, so the test is independent of `fuseki-test.sh load`.
        r = Jayhawk.runsparql(
            "SELECT (COUNT(*) AS ?n) WHERE { GRAPH <urn:ontology> { ?s ?p ?o } }")
        @test haskey(r[1], "n")
        @test parse(Int, r[1]["n"]["value"]) >= 0
    end

    Jayhawk.usparql("DROP SILENT GRAPH <$TEST_GRAPH>")

    @testset "cleanup left nothing behind" begin
        r = Jayhawk.runsparql(
            "SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$TEST_GRAPH> { ?s ?p ?o } }")
        @test r[1]["n"]["value"] == "0"
    end
end

# ===========================================================================
# The Function-Graph engine: pattern -> SPARQL -> store.
# ===========================================================================

const GIST  = "https://w3id.org/semanticarts/ns/ontology/gist/"
const HR    = "http://example.org/hr/"
const RULES = "http://example.org/rules/"
const TC    = "http://example.org/tc/"
const DATA_GRAPH = "urn:jayhawk:engine-test"
const TC_GRAPH   = "urn:jayhawk:engine-test-tc"

fixture(name) = joinpath(@__DIR__, "fixtures", name)

"Drop everything this file creates, including every firing it produced."
function engine_cleanup()
    for f in firings()
        undo_firing!(f.graph)
    end
    for g in (DATA_GRAPH, TC_GRAPH, Jayhawk.PROVENANCE_GRAPH,
              "$(RULES)PersonToEmployee_L", "$(RULES)PersonToEmployee_R",
              "http://example.org/tcrules/PartOfTransitive_L",
              "http://example.org/tcrules/PartOfTransitive_R")
        Jayhawk.update!("DROP SILENT GRAPH <$g>")
    end
    # the rules and their variable declarations live in the default graph
    Jayhawk.update!("""
        DELETE WHERE { ?s <$(Jayhawk.P_MATCH)> ?o } ;
        DELETE WHERE { ?s <$(Jayhawk.P_CONSTRUCT)> ?o } ;
        DELETE WHERE { ?s <$(Jayhawk.P_MODE)> ?o } ;
        DELETE WHERE { ?s <$(Jayhawk.P_VARIABLETEXT)> ?o } ;
        DELETE WHERE { ?s <$(Jayhawk.P_IRITEMPLATE)> ?o } ;
        DELETE WHERE { ?s a <$(Jayhawk.C_RULE)> } ;
        DELETE WHERE { ?s a <$(Jayhawk.C_SPARQLVAR)> } ;
        DELETE WHERE { ?s a <$(Jayhawk.GISTP_NS)SparqlPattern> }""")
end

@testset "Function-Graph engine (Fuseki)" begin

    engine_cleanup()

    @testset "SELECT preserves literal datatypes" begin
        # The test that could not pass before src/term.jl existed. Serd's Literal has one
        # `langordt` field for two exclusive concepts and its parser never stores a
        # datatype, so `"42"^^ex:custom` came back byte-identical to plain `"42"`.
        # SPARQL Results JSON carries the datatype; term_from_json keeps it.
        Jayhawk.update!("""
            INSERT DATA { GRAPH <$DATA_GRAPH> {
              <urn:dt:s> <urn:dt:int>   "42"^^<http://www.w3.org/2001/XMLSchema#integer> ;
                         <urn:dt:var>   "?x"^^<$(Jayhawk.GISTP_VAR)> ;
                         <urn:dt:plain> "42" ;
                         <urn:dt:lang>  "hello"@en .
            } }""")
        rows = select("SELECT ?p ?o WHERE { GRAPH <$DATA_GRAPH> { <urn:dt:s> ?p ?o } }")
        by = Dict((r["p"]::IRIRef).value => r["o"] for r in rows)

        @test by["urn:dt:int"] == RDFLiteral("42", "http://www.w3.org/2001/XMLSchema#integer")
        @test by["urn:dt:var"] == RDFLiteral("?x", Jayhawk.GISTP_VAR)
        @test by["urn:dt:plain"] == RDFLiteral("42")
        @test by["urn:dt:lang"] == RDFLiteral("hello", nothing, "en")

        # the distinction that matters: a gistp:var literal is not a plain string
        @test by["urn:dt:var"] != RDFLiteral("?x")
        @test is_var_literal(by["urn:dt:var"])
        @test !is_var_literal(by["urn:dt:plain"])
        # and a typed integer is not the plain literal with the same lexical form
        @test by["urn:dt:int"] != by["urn:dt:plain"]

        Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
    end

    @testset "a rule loads out of the store" begin
        # Jena parses the TriG, over the Graph Store Protocol. Julia never parses RDF.
        Jayhawk.load_file!(fixture("person_to_employee.trig"))

        @test "$(RULES)PersonToEmployee" in list_rules()

        spec = load_rule("$(RULES)PersonToEmployee")
        @test mode_symbol(spec) === :Construct
        @test spec.match_graph == "$(RULES)PersonToEmployee_L"
        @test spec.construct_graph == "$(RULES)PersonToEmployee_R"
        @test length(spec.match) == 4       # the pattern IS its graph
        @test length(spec.construct) == 2
        @test spec.variables["$(RULES)_Person_1"] == "?_Person_1"
        @test spec.variables["$(RULES)_ID_1"] == "?_ID_1"
        @test spec.templates["$(RULES)_Person_1"] == ":_Employee_{person_id}"

        # the literal-position variable survived the round trip through the store
        @test any(is_var_literal(t.object) for t in spec.match)
    end

    @testset "compiled SPARQL is stable and runs" begin
        q = compile_from_store("$(RULES)PersonToEmployee")
        @test occursin("CONSTRUCT {", q)
        @test occursin("?_Person_1", q)      # IRI-position variable
        @test occursin("?idText", q)         # literal-position variable
        @test !occursin("gistp", q)          # the marker datatype is consumed, not emitted
        # sorted on load, so compiling twice gives byte-identical text
        @test q == compile_from_store("$(RULES)PersonToEmployee")
    end

    @testset "Construct: apply, attribute, undo" begin
        Jayhawk.update!("""
            INSERT DATA { GRAPH <$DATA_GRAPH> {
              <urn:p1> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:id1> .
              <urn:id1> a <$(GIST)ID> ; <$(GIST)containedText> "E-4471" .
              <urn:p2> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:id2> .
              <urn:id2> a <$(GIST)ID> ; <$(GIST)containedText> "E-9902" .
              <urn:p3> a <$(GIST)Person> .
            } }""")

        fs = run_rule("$(RULES)PersonToEmployee"; source = [DATA_GRAPH], actor = "integration")
        @test length(fs) == 1                     # Construct applies exactly once
        f = fs[1]
        @test f.mode === :Construct
        @test f.count == 4                        # two people, two triples each

        produced = Set((sparql_text(r["s"]), sparql_text(r["p"]), sparql_text(r["o"]))
                       for r in select("SELECT ?s ?p ?o WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }"))
        @test ("<urn:p1>", "<$(HR)employeeNumber>", "\"E-4471\"") in produced
        @test ("<urn:p2>", "<$(HR)employeeNumber>", "\"E-9902\"") in produced
        # p3 has no identifier, so the match pattern does not select it
        @test !any(s == "<urn:p3>" for (s, _, _) in produced)

        @testset "the firing is attributable" begin
            log = firings(rule = "$(RULES)PersonToEmployee")
            @test length(log) == 1
            @test log[1].graph == f.graph
            @test log[1].actor == "integration"
            @test log[1].count == 4
            @test log[1].iteration == 1
        end

        @testset "undo is complete" begin
            undo_firing!(f.graph)
            @test graph_size(f.graph) == 0
            @test isempty(firings(rule = "$(RULES)PersonToEmployee"))
            # the source data is untouched -- round 1 rules only ever add
            @test graph_size(DATA_GRAPH) == 9
        end
    end

    @testset "Assert iterates to a least fixpoint" begin
        Jayhawk.load_file!(fixture("transitive_rule.trig"))
        # a chain of four edges: a -> b -> c -> d -> e
        Jayhawk.update!("""
            INSERT DATA { GRAPH <$TC_GRAPH> {
              <$(TC)a> <$(TC)partOf> <$(TC)b> .
              <$(TC)b> <$(TC)partOf> <$(TC)c> .
              <$(TC)c> <$(TC)partOf> <$(TC)d> .
              <$(TC)d> <$(TC)partOf> <$(TC)e> .
            } }""")

        rule = "http://example.org/tcrules/PartOfTransitive"
        @test mode_symbol(load_rule(rule)) === :Assert

        fs = run_rule(rule; source = [TC_GRAPH], actor = "integration")
        # the transitive closure of a 4-edge chain has 4+3+2+1 = 10 pairs; 4 were given
        @test sum(f.count for f in fs) == 6
        @test all(f.mode === :Assert for f in fs)
        @test [f.iteration for f in fs] == collect(1:length(fs))
        # it converged: the driver stops when a round contributes nothing, and the empty
        # final round leaves no graph behind
        @test length(fs) >= 2

        @testset "every derived edge is a real path" begin
            derived = Set((sparql_text(r["s"]), sparql_text(r["o"]))
                          for f in fs
                          for r in select("SELECT ?s ?o WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }"))
            @test ("<$(TC)a>", "<$(TC)e>") in derived    # the longest shortcut
            @test ("<$(TC)a>", "<$(TC)c>") in derived
            @test !(("<$(TC)e>", "<$(TC)a>") in derived) # closure is not symmetric
        end

        @testset "no firing restates a fact the working set already held" begin
            # prune_known! is what makes the fixpoint terminate: without it a round
            # re-derives what it derived before, count never reaches zero, and the
            # driver spins until the iteration cap.
            for f in fs
                n = select("""SELECT (COUNT(*) AS ?n) WHERE {
                                GRAPH <$(f.graph)> { ?s ?p ?o }
                                GRAPH <$TC_GRAPH>  { ?s ?p ?o } }""")
                @test parse(Int, (n[1]["n"]::RDFLiteral).lexical) == 0
            end
        end

        for f in fs
            undo_firing!(f.graph)
        end
        @test graph_size(TC_GRAPH) == 4     # back to the four given edges
    end

    @testset "the iteration cap raises rather than returning a partial answer" begin
        rule = "http://example.org/tcrules/PartOfTransitive"
        err = try
            run_rule(rule; source = [TC_GRAPH], max_iterations = 1)
            nothing
        catch e
            e
        end
        @test err !== nothing
        msg = sprint(showerror, err)
        @test occursin("PartOfTransitive", msg)     # names the offending rule
        @test occursin("chase", msg)                # and says why a cap is needed at all
        for f in firings(); undo_firing!(f.graph); end
    end

    @testset "Rewrite mode is refused against a live store" begin
        # Deliberately not supported in round 1: DELETE { L∖I } needs the triple-level
        # interface, and derived_interface.rq computes shared *variables*.
        Jayhawk.update!("""
            INSERT DATA {
              <urn:r:Bad> a <$(Jayhawk.C_RULE)> ;
                  <$(Jayhawk.P_MATCH)> <urn:r:Bad_L> ;
                  <$(Jayhawk.P_CONSTRUCT)> <urn:r:Bad_R> ;
                  <$(Jayhawk.P_MODE)> <$(Jayhawk.MODE_REWRITE)> .
              <urn:r:v> a <$(Jayhawk.C_SPARQLVAR)> ; <$(Jayhawk.P_VARIABLETEXT)> "?v" .
            }
            ;
            INSERT DATA {
              GRAPH <urn:r:Bad_L> { <urn:r:v> a <urn:r:Thing> }
              GRAPH <urn:r:Bad_R> { <urn:r:v> a <urn:r:Other> }
            }""")
        err = try compile_from_store("urn:r:Bad") catch e; e end
        @test occursin("not supported yet", sprint(showerror, err))
        @test_throws Exception run_rule("urn:r:Bad")

        Jayhawk.update!("DROP SILENT GRAPH <urn:r:Bad_L>")
        Jayhawk.update!("DROP SILENT GRAPH <urn:r:Bad_R>")
    end

    @testset "the agent-facing tools" begin
        # These are the MCP surface, but they depend on nothing but the engine, so they are
        # exercised here rather than through the protocol. bin/mcp_server.jl is the adapter.
        Jayhawk.load_file!(fixture("person_to_employee.trig"))
        # start from a clean source graph: an earlier testset left 9 triples here, and
        # INSERT DATA of a triple that already exists is a silent no-op
        Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
        Jayhawk.update!("""
            INSERT DATA { GRAPH <$DATA_GRAPH> {
              <urn:p1> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:id1> .
              <urn:id1> a <$(GIST)ID> ; <$(GIST)containedText> "E-4471" .
            } }""")
        rule = "$(RULES)PersonToEmployee"

        @testset "list_rules is a catalogue, not a query language" begin
            out = tool_list_rules()
            @test occursin(rule, out)
            @test occursin("Person to Employee", out)          # skos:prefLabel
            @test occursin("Construct", out)
            @test occursin("pure", out)                        # says what the mode means
            @test !occursin("CONSTRUCT {", out)                # no SPARQL at this level
        end

        @testset "explain_rule shows facts, not just SPARQL" begin
            out = tool_explain_rule(rule; source = [DATA_GRAPH])
            @test occursin("CONSTRUCT {", out)                 # the query, for the curious
            @test occursin("would add 2 new triple(s)", out)   # and what it actually does
            @test occursin("\"E-4471\"", out)                  # the literal it would create
            @test occursin("Nothing was written", out)
        end

        @testset "explain_rule writes nothing" begin
            before = length(firings())
            tool_explain_rule(rule; source = [DATA_GRAPH])
            tool_explain_rule(rule; source = [DATA_GRAPH])
            @test length(firings()) == before
            @test graph_size(DATA_GRAPH) == 4                  # source untouched
        end

        @testset "run_rule then undo_firing round-trips" begin
            out = tool_run_rule(rule; source = [DATA_GRAPH], actor = "agent-7")
            @test occursin("added 2 new triple(s)", out)

            log = firings(rule = rule)
            @test length(log) == 1
            @test log[1].actor == "agent-7"

            @test occursin("agent-7", tool_firings(rule = rule))

            undone = tool_undo_firing(log[1].graph)
            @test occursin("2 triple(s) removed", undone)
            @test isempty(firings(rule = rule))
            @test graph_size(DATA_GRAPH) == 4                  # source still untouched

            # undoing twice is harmless, not an error
            @test occursin("nothing to undo", tool_undo_firing(log[1].graph))
        end

        @testset "a second identical run derives nothing new" begin
            # Construct against an unchanged source is idempotent once its output is in the
            # working set -- prune_known! is what makes that visible.
            f1 = run_rule(rule; source = [DATA_GRAPH])
            f2 = run_rule(rule; source = [DATA_GRAPH, f1[1].graph])
            @test f1[1].count == 2
            @test f2[1].count == 0
            @test graph_size(f2[1].graph) == 0    # contributed nothing, so left no graph
            undo_firing!(f1[1].graph)
        end

        Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
    end

    engine_cleanup()

    @testset "engine cleanup left nothing behind" begin
        @test isempty(list_rules())
        @test isempty(firings())
        @test graph_size(DATA_GRAPH) == 0
        @test graph_size(TC_GRAPH) == 0
    end
end
