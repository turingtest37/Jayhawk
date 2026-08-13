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
