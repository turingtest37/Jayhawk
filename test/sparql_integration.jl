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
              "http://example.org/tcrules/PartOfTransitive_R",
              "$(RULES)PersonToEmployeeRecord_L", "$(RULES)PersonToEmployeeRecord_R",
              "$(RULES)FlattenIdentifier_L", "$(RULES)FlattenIdentifier_R")
        Jayhawk.update!("DROP SILENT GRAPH <$g>")
    end
    # the rules and their variable declarations live in the default graph
    Jayhawk.update!("""
        DELETE WHERE { ?s <$(Jayhawk.P_MATCH)> ?o } ;
        DELETE WHERE { ?s <$(Jayhawk.P_CONSTRUCT)> ?o } ;
        DELETE WHERE { ?s <$(Jayhawk.P_MODE)> ?o } ;
        DELETE WHERE { ?s <$(Jayhawk.P_VARIABLETEXT)> ?o } ;
        DELETE WHERE { ?s <$(Jayhawk.P_IRITEMPLATE)> ?o } ;
        DELETE WHERE { ?s <$(Jayhawk.P_HASSLOT)> ?o } ;
        DELETE WHERE { ?s <$(Jayhawk.P_SLOTNAME)> ?o } ;
        DELETE WHERE { ?s <$(Jayhawk.P_SLOTVALUE)> ?o } ;
        DELETE WHERE { ?s a <$(Jayhawk.GISTP_NS)TemplateSlot> } ;
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
        # :_Person_1 used to carry a dead ":_Employee_{person_id}". A template now declares
        # a variable minted, and a minted variable must not be matched -- so the plain rule
        # has none at all.
        @test isempty(spec.mints)

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


    @testset "minting: a rule that creates a node that did not exist" begin
        Jayhawk.load_file!(fixture("minting_rule.trig"))
        Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
        Jayhawk.update!("""
            INSERT DATA { GRAPH <$DATA_GRAPH> {
              <urn:p1> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:id1> .
              <urn:id1> a <$(GIST)ID> ; <$(GIST)containedText> "E-4471" .
              <urn:p2> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:id2> .
              <urn:id2> a <$(GIST)ID> ; <$(GIST)containedText> "E 9902/A" .
              <urn:p3> a <$(GIST)Person> .
            } }""")
        rule = "$(RULES)PersonToEmployeeRecord"

        @testset "the mint spec loads out of the store" begin
            spec = load_rule(rule)
            @test length(spec.mints) == 1
            m = spec.mints["$(RULES)_Employee_1"]
            @test m.template == "http://example.org/hr/employee/{id}"
            @test collect(keys(m.slots)) == ["id"]
            # the slot value is a literal-position variable, so its ^^gistp:var datatype had
            # to survive the round trip through the store
            @test is_var_literal(m.slots["id"])
            @test var_of(m.slots["id"], spec) == "?idText"
            # a minted variable appears in R only
            @test !("?_Employee_1" in vars_in(spec.match, spec))
            @test "?_Employee_1" in vars_in(spec.construct, spec)
        end

        @testset "it compiles to a BIND the store can evaluate" begin
            q = compile_from_store(rule)
            @test occursin("BIND(IRI(CONCAT(", q)
            @test occursin("ENCODE_FOR_URI(STR(?idText))", q)
            @test occursin("AS ?_Employee_1)", q)
        end

        local fs
        @testset "applying it mints the expected IRIs" begin
            fs = run_rule(rule; source = [DATA_GRAPH], actor = "integration")
            @test sum(f.count for f in fs) == 6      # two people, three triples each

            subjects = Set((r["s"]::IRIRef).value
                           for f in fs
                           for r in select("SELECT DISTINCT ?s WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }"))
            @test "http://example.org/hr/employee/E-4471" in subjects
            # ENCODE_FOR_URI is RFC 6570 Level 1 exactly: space -> %20, / -> %2F,
            # while '-' is unreserved and passes through untouched
            @test "http://example.org/hr/employee/E%209902%2FA" in subjects
            @test length(subjects) == 2              # p3 has no identifier, so no record

            # the minted node is linked back to the person it was minted for
            back = select("""SELECT ?p WHERE { GRAPH <$(fs[1].graph)> {
                       <http://example.org/hr/employee/E-4471> <$(HR)isRecordFor> ?p } }""")
            @test (back[1]["p"]::IRIRef).value == "urn:p1"
        end

        @testset "minting is deterministic, so the fixpoint converges" begin
            # This is the whole termination argument. CONCAT/ENCODE_FOR_URI/IRI are pure, so
            # re-applying mints byte-identical IRIs, prune_known! removes them all, and the
            # driver stops. A non-deterministic mint (a UUID) would never converge.
            @test length(fs) == 1                    # round 2 contributed nothing

            again = run_rule(rule; source = [DATA_GRAPH, fs[1].graph], actor = "integration")
            @test isempty(again) || all(f.count == 0 for f in again)
        end

        @testset "fan-in is reported when one IRI serves several bindings" begin
            # The hazard injectivity does NOT cover. Two different people carrying the same
            # identifier text mint one employee IRI: the slot values are identical, so no
            # collision check can see it, yet the node ends up carrying both people's facts.
            #
            # Reported, never refused -- many-to-one minting is often right (one department
            # node per name, shared by its staff), so whether it is a bug depends on
            # modelling intent the pattern cannot state.
            Jayhawk.update!("DROP SILENT GRAPH <urn:jayhawk:fanin-test>")
            Jayhawk.update!("""
                INSERT DATA { GRAPH <urn:jayhawk:fanin-test> {
                  <urn:pA> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:idA> .
                  <urn:idA> a <$(GIST)ID> ; <$(GIST)containedText> "E-4471" .
                  <urn:pB> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:idB> .
                  <urn:idB> a <$(GIST)ID> ; <$(GIST)containedText> "E-4471" .
                } }""")
            spec = load_rule(rule)
            fan = mint_fanin(spec; from = ["urn:jayhawk:fanin-test"])
            @test length(fan) == 1
            minted_iri, rows = fan[1]
            @test minted_iri == "$(RULES)_Employee_1"
            @test rows == [("http://example.org/hr/employee/E-4471", 2)]

            # and the review surface surfaces it before anything is written
            out = tool_explain_rule(rule; source = ["urn:jayhawk:fanin-test"])
            @test occursin("WARNING", out)
            @test occursin("from 2 distinct bindings", out)
            @test occursin("Nothing was written", out)

            # the same data with distinct identifiers produces no warning
            Jayhawk.update!("""
                DELETE DATA { GRAPH <urn:jayhawk:fanin-test> {
                  <urn:idB> <$(GIST)containedText> "E-4471" } } ;
                INSERT DATA { GRAPH <urn:jayhawk:fanin-test> {
                  <urn:idB> <$(GIST)containedText> "E-9902" } }""")
            @test isempty(mint_fanin(spec; from = ["urn:jayhawk:fanin-test"]))
            @test !occursin("WARNING", tool_explain_rule(rule; source = ["urn:jayhawk:fanin-test"]))

            Jayhawk.update!("DROP SILENT GRAPH <urn:jayhawk:fanin-test>")
        end

        @testset "undo removes the minted nodes and leaves the source alone" begin
            for f in fs
                undo_firing!(f.graph)
            end
            @test graph_size(DATA_GRAPH) == 9
            # Ask for the *minted* IRIs specifically. A blanket "no ex:Employee anywhere"
            # would also match the rule's own declarations: :_Employee_1 is typed
            # ex:Employee in the default graph, because a variable carries its domain type
            # -- that is what makes a pattern checkable as ordinary instance data.
            @test isempty(select("""
                SELECT ?s WHERE { GRAPH ?g { ?s ?p ?o }
                  FILTER(STRSTARTS(STR(?s), "http://example.org/hr/employee/")) }"""))
        end

        Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
    end

    @testset "Rewrite: the mode that takes facts away" begin
        Jayhawk.load_file!(fixture("rewrite_rule.trig"))
        rule = "$(RULES)FlattenIdentifier"
        Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
        Jayhawk.update!("""
            INSERT DATA { GRAPH <$DATA_GRAPH> {
              <urn:p1> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:id1> .
              <urn:id1> a <$(GIST)ID> ; <$(GIST)containedText> "E-4471" .
              <urn:p9> a <$(GIST)Person> .
            } }""")
        snapshot() = Set((sparql_text(r["s"]), sparql_text(r["p"]), sparql_text(r["o"]))
                         for r in select("SELECT ?s ?p ?o WHERE { GRAPH <$DATA_GRAPH> { ?s ?p ?o } }"))
        original = snapshot()
        @test length(original) == 5

        @testset "I is computed from the store, not assumed" begin
            spec = load_rule(rule)
            @test mode_symbol(spec) === :Rewrite
            @test length(interface(spec)) == 1        # :_P a gist:Person, repeated in R
            @test length(match_only(spec)) == 3
            @test length(construct_only(spec)) == 1
            @test dangling_risks(spec) == ["?_I"]     # the identifier node is stranded
        end

        @testset "dry_run previews both halves and changes nothing" begin
            d = dry_run(rule; source = [DATA_GRAPH])
            @test d.removed == 3
            @test d.count == 1
            @test snapshot() == original              # target untouched
        end

        local f
        @testset "applying it mutates in place and records a tombstone" begin
            f = run_rule(rule; source = [DATA_GRAPH], actor = "integration")[1]
            @test f.mode === :Rewrite
            @test f.count == 1 && f.removed == 3
            @test !isempty(f.tombstone)
            @test f.target == DATA_GRAPH

            now = snapshot()
            @test length(now) == 3
            # the preserved triple survived -- it is in I, because R repeats it
            @test ("<urn:p1>", "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>",
                   "<$(GIST)Person>") in now
            @test ("<urn:p1>", "<$(HR)employeeNumber>", "\"E-4471\"") in now
            @test !any(sub == "<urn:id1>" for (sub, _, _) in now)
            # p9 has no identifier, so L never matched it
            @test ("<urn:p9>", "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>",
                   "<$(GIST)Person>") in now

            tomb = Set((sparql_text(r["s"]), sparql_text(r["p"]), sparql_text(r["o"]))
                       for r in select("SELECT ?s ?p ?o WHERE { GRAPH <$(f.tombstone)> { ?s ?p ?o } }"))
            @test tomb == setdiff(original, now)
        end

        @testset "undo restores the graph exactly" begin
            # DROP alone cannot do this: a deletion has to be replayed from the tombstone.
            undo_firing!(f.graph)
            @test snapshot() == original
            @test graph_size(f.tombstone) == 0
            @test graph_size(f.graph) == 0
            @test isempty(firings(rule = rule))
        end

        @testset "the MCP tool refuses to delete without confirmation" begin
            out = tool_run_rule(rule; source = [DATA_GRAPH])
            @test occursin("Refused", out)
            @test occursin("DELETES", out)
            @test occursin("remove 3", out)
            @test snapshot() == original              # nothing happened

            out2 = tool_run_rule(rule; source = [DATA_GRAPH], confirm = true, actor = "agent")
            @test occursin("removed 3", out2)
            @test length(snapshot()) == 3
            for fr in firings(rule = rule); undo_firing!(fr.graph); end
            @test snapshot() == original
        end

        @testset "a rewrite needs exactly one target graph" begin
            # "delete from the union of these three" is neither expressible nor reviewable
            @test_throws ArgumentError run_rule(rule; source = String[])
            @test_throws ArgumentError run_rule(rule; source = [DATA_GRAPH, TC_GRAPH])
        end

        Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
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
            @test occursin("added 2 triple(s)", out)

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
