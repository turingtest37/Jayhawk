# SPARQL integration tests -- require a running Apache Jena Fuseki.
#
# NOT part of the default suite. `test/runtests.jl` stays hermetic and ~6 seconds; a
# developer with no server running must never see a failure from this file.
#
#     ./bin/fuseki-test.sh start
#     JAYHAWK_TEST_SPARQL=1 julia --project=. test/sparql_integration.jl
#
# Or, to run it together with everything else:
#     JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl
#
# The default endpoint is read from JAYHAWK_SPARQL_SERVICE when the package loads, so
# export it *before* julia starts if the rig is not on the default port. The default (http://localhost:3040/jayhawk) already matches
# bin/fuseki-test.sh.
#
# These tests build and drop their own named graph and never touch <urn:ontology>, so
# they neither depend on `fuseki-test.sh load` having run nor disturb it.

using Test
using Jayhawk

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

              Start one with:  ./bin/fuseki-test.sh start

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
            "SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$TEST_GRAPH> { ?s ?p ?o } }"
        )
        @test r[1]["n"]["value"] == "2"
    end

    @testset "runsparql handles ASK as well as SELECT" begin
        # Regression: runsparql did `r["results"]["bindings"]` unconditionally, but an
        # ASK response is {"head":{}, "boolean":…} with no "results" key -- so every
        # ASK query threw KeyError("results").
        @test Jayhawk.runsparql("ASK {}") === true
        @test Jayhawk.runsparql(
            "ASK { <http://it.example.org/nope> <http://it.example.org/p> ?o }"
        ) === false
    end

    @testset "runsparql SELECT returns parsed JSON bindings" begin
        r = Jayhawk.runsparql(
            "SELECT ?s ?o WHERE { GRAPH <$TEST_GRAPH> { ?s ?p ?o } } ORDER BY ?o"
        )
        @test length(r) == 2
        @test r[1]["o"]["value"] == "one"
        @test r[2]["s"]["value"] == "http://it.example.org/s2"
    end

    # The `qsparql CONSTRUCT parses into statements` testset moved to
    # RdfMaterializer/test/sparql_integration.jl with the function it covers.

    @testset "Mustache bindings reach the query" begin
        # runsparql renders the query as a Mustache template against `m`; usparql
        # forwards its `dict` there. This is the path the positional-argument bug broke.
        Jayhawk.usparql(
            "INSERT DATA { GRAPH <$TEST_GRAPH> { <http://it.example.org/s3> <http://it.example.org/p> \"{{val}}\" } }";
            dict=Dict("val" => "three"),
        )

        r = Jayhawk.runsparql(
            "SELECT ?o WHERE { GRAPH <$TEST_GRAPH> { <http://it.example.org/s3> ?p ?o } }"
        )
        @test r[1]["o"]["value"] == "three"
    end

    @testset "named-graph convention used by src/sparql.jl" begin
        # Every query constant in src/sparql.jl hardcodes GRAPH <urn:ontology>. This
        # only asserts the mechanism works; it does not require the fixtures to be
        # loaded, so the test is independent of `fuseki-test.sh load`.
        r = Jayhawk.runsparql(
            "SELECT (COUNT(*) AS ?n) WHERE { GRAPH <urn:ontology> { ?s ?p ?o } }"
        )
        @test haskey(r[1], "n")
        @test parse(Int, r[1]["n"]["value"]) >= 0
    end

    Jayhawk.usparql("DROP SILENT GRAPH <$TEST_GRAPH>")

    @testset "cleanup left nothing behind" begin
        r = Jayhawk.runsparql(
            "SELECT (COUNT(*) AS ?n) WHERE { GRAPH <$TEST_GRAPH> { ?s ?p ?o } }"
        )
        @test r[1]["n"]["value"] == "0"
    end
end

# ===========================================================================
# The Function-Graph engine: pattern -> SPARQL -> store.
# ===========================================================================

const GIST = "https://w3id.org/semanticarts/ns/ontology/gist/"
const HR = "http://example.org/hr/"
const RULES = "http://example.org/rules/"
const TC = "http://example.org/tc/"
const DATA_GRAPH = "urn:jayhawk:engine-test"
const TC_GRAPH = "urn:jayhawk:engine-test-tc"

fixture(name) = joinpath(@__DIR__, "fixtures", name)
example(name) = joinpath(@__DIR__, "..", "examples", "moneygraph", name)

"Drop everything this file creates, including every firing it produced."
function engine_cleanup()
    for f in firings()
        undo_firing!(f.graph)
    end
    for g in (
        DATA_GRAPH,
        TC_GRAPH,
        Jayhawk.PROVENANCE_GRAPH,
        "$(RULES)PersonToEmployee_L",
        "$(RULES)PersonToEmployee_R",
        "http://example.org/tcrules/PartOfTransitive_L",
        "http://example.org/tcrules/PartOfTransitive_R",
        "$(RULES)PersonToEmployeeRecord_L",
        "$(RULES)PersonToEmployeeRecord_R",
        "$(RULES)FlattenIdentifier_L",
        "$(RULES)FlattenIdentifier_R",
        "$(RULES)AssignReview_L",
        "$(RULES)AssignReview_R",
        "$(RULES)AssignReview_NoTaskYet",
        "urn:jayhawk:ops-test",
        "$(RULES)ComplianceChecks_L",
        "$(RULES)ComplianceChecks_R",
        "$(RULES)ComplianceChecks_NotYet",
        "urn:jayhawk:oneof-test",
    )
        Jayhawk.update!("DROP SILENT GRAPH <$g>")
    end
    # the rules and their variable declarations live in the default graph
    return Jayhawk.update!("""
               DELETE WHERE { ?s <$(Jayhawk.P_MATCH)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_CONSTRUCT)> ?o } ;
               DELETE WHERE { ?r <$(Jayhawk.P_HASBINDING)> ?b . ?b ?p ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_HASBINDING)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_ISMINTEDBY)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_NAMESPACE)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_LOCALTEMPLATE)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_MODE)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_VARIABLETEXT)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_IRITEMPLATE)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_NAC)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_ONEOF)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_STRATEGY)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_PRIORITY)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_MAXITER)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_HASSLOT)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_SLOTNAME)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_SLOTVALUE)> ?o } ;
               DELETE WHERE { ?s a <$(Jayhawk.GISTP_NS)TemplateSlot> } ;
               DELETE WHERE { ?s a <$(Jayhawk.C_RULE)> } ;
               DELETE WHERE { ?s a <$(Jayhawk.C_SPARQLVAR)> } ;
               DELETE WHERE { ?s a <$(Jayhawk.GISTP_NS)SparqlPattern> } ;
               DELETE WHERE { ?s a <$(Jayhawk.C_RULESET)> } ;
               DELETE WHERE { ?s a <$(Jayhawk.GIST_NS)OrderedMember> } ;
               DELETE WHERE { ?s <$(Jayhawk.P_ISMEMBEROF)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_ISFIRSTMEMBEROF)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_PROVIDESORDERFOR)> ?o } ;
               DELETE WHERE { ?s <$(Jayhawk.P_SEQUENCE)> ?o }""")
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

        @test by["urn:dt:int"] ==
            RDFLiteral("42", "http://www.w3.org/2001/XMLSchema#integer")
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

        fs = run_rule("$(RULES)PersonToEmployee"; source=[DATA_GRAPH], actor="integration")
        @test length(fs) == 1                     # Construct applies exactly once
        f = fs[1]
        @test f.mode === :Construct
        @test f.count == 4                        # two people, two triples each

        produced = Set(
            (sparql_text(r["s"]), sparql_text(r["p"]), sparql_text(r["o"])) for
            r in select("SELECT ?s ?p ?o WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
        )
        @test ("<urn:p1>", "<$(HR)employeeNumber>", "\"E-4471\"") in produced
        @test ("<urn:p2>", "<$(HR)employeeNumber>", "\"E-9902\"") in produced
        # p3 has no identifier, so the match pattern does not select it
        @test !any(s == "<urn:p3>" for (s, _, _) in produced)

        @testset "the firing is attributable" begin
            log = firings(rule="$(RULES)PersonToEmployee")
            @test length(log) == 1
            @test log[1].graph == f.graph
            @test log[1].actor == "integration"
            @test log[1].count == 4
            @test log[1].iteration == 1
        end

        @testset "undo is complete" begin
            undo_firing!(f.graph)
            @test graph_size(f.graph) == 0
            @test isempty(firings(rule="$(RULES)PersonToEmployee"))
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

        fs = run_rule(rule; source=[TC_GRAPH], actor="integration")
        # the transitive closure of a 4-edge chain has 4+3+2+1 = 10 pairs; 4 were given
        @test sum(f.count for f in fs) == 6
        @test all(f.mode === :Assert for f in fs)
        @test [f.iteration for f in fs] == collect(1:length(fs))
        # it converged: the driver stops when a round contributes nothing, and the empty
        # final round leaves no graph behind
        @test length(fs) >= 2

        @testset "every derived edge is a real path" begin
            derived = Set(
                (sparql_text(r["s"]), sparql_text(r["o"])) for f in fs for
                r in select("SELECT ?s ?o WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
            )
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
            run_rule(rule; source=[TC_GRAPH], max_iterations=1)
            nothing
        catch e
            e
        end
        @test err !== nothing
        msg = sprint(showerror, err)
        @test occursin("PartOfTransitive", msg)     # names the offending rule
        @test occursin("chase", msg)                # and says why a cap is needed at all
        for f in firings()
            undo_firing!(f.graph)
        end
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
            # The slot value is an IRI naming a declared gistp:LiteralVariable, and it
            # resolves through that variable's gistp:variableText. The literal form
            # "?idText"^^gistp:var was withdrawn once such declarations existed.
            @test m.slots["id"] isa IRIRef
            @test var_of(m.slots["id"], spec) == "?idText"

            # And the declaration has to be FOUND. It occupies no position inside either
            # pattern graph -- inside a pattern the variable is still a literal -- so it is
            # reachable only as the object of a gistp:slotValue in the default graph. Without
            # the fifth alternative in _occurs_in it is never loaded, var_of returns nothing,
            # and check_mints refuses a slot that is correctly bound.
            @test haskey(spec.variables, "$(RULES)_idText")

            # The ^^gistp:var datatype still has to survive the round trip through the store:
            # it is how a literal in an ordinary object position is marked as a variable.
            @test any(is_var_literal(t.object) for t in spec.match)
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
            fs = run_rule(rule; source=[DATA_GRAPH], actor="integration")
            @test sum(f.count for f in fs) == 6      # two people, three triples each

            subjects = Set(
                (r["s"]::IRIRef).value for f in fs for
                r in select("SELECT DISTINCT ?s WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
            )
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

            again = run_rule(rule; source=[DATA_GRAPH, fs[1].graph], actor="integration")
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
            fan = mint_fanin(spec; from=["urn:jayhawk:fanin-test"])
            @test length(fan) == 1
            minted_iri, rows = fan[1]
            @test minted_iri == "$(RULES)_Employee_1"
            @test rows == [("http://example.org/hr/employee/E-4471", 2)]

            # and the review surface surfaces it before anything is written
            out = tool_explain_rule(rule; source=["urn:jayhawk:fanin-test"])
            @test occursin("WARNING", out)
            @test occursin("from 2 distinct bindings", out)
            @test occursin("Nothing was written", out)

            # the same data with distinct identifiers produces no warning
            Jayhawk.update!("""
                DELETE DATA { GRAPH <urn:jayhawk:fanin-test> {
                  <urn:idB> <$(GIST)containedText> "E-4471" } } ;
                INSERT DATA { GRAPH <urn:jayhawk:fanin-test> {
                  <urn:idB> <$(GIST)containedText> "E-9902" } }""")
            @test isempty(mint_fanin(spec; from=["urn:jayhawk:fanin-test"]))
            @test !occursin(
                "WARNING", tool_explain_rule(rule; source=["urn:jayhawk:fanin-test"])
            )

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
        snapshot() = Set(
            (sparql_text(r["s"]), sparql_text(r["p"]), sparql_text(r["o"])) for
            r in select("SELECT ?s ?p ?o WHERE { GRAPH <$DATA_GRAPH> { ?s ?p ?o } }")
        )
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
            d = dry_run(rule; source=[DATA_GRAPH])
            @test d.removed == 3
            @test d.count == 1
            @test snapshot() == original              # target untouched
        end

        local f
        @testset "applying it mutates in place and records a tombstone" begin
            f = run_rule(rule; source=[DATA_GRAPH], actor="integration")[1]
            @test f.mode === :Rewrite
            @test f.count == 1 && f.removed == 3
            @test !isempty(f.tombstone)
            @test f.target == DATA_GRAPH

            now = snapshot()
            @test length(now) == 3
            # the preserved triple survived -- it is in I, because R repeats it
            @test (
                "<urn:p1>",
                "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>",
                "<$(GIST)Person>",
            ) in now
            @test ("<urn:p1>", "<$(HR)employeeNumber>", "\"E-4471\"") in now
            @test !any(sub == "<urn:id1>" for (sub, _, _) in now)
            # p9 has no identifier, so L never matched it
            @test (
                "<urn:p9>",
                "<http://www.w3.org/1999/02/22-rdf-syntax-ns#type>",
                "<$(GIST)Person>",
            ) in now

            tomb = Set(
                (sparql_text(r["s"]), sparql_text(r["p"]), sparql_text(r["o"])) for
                r in select("SELECT ?s ?p ?o WHERE { GRAPH <$(f.tombstone)> { ?s ?p ?o } }")
            )
            @test tomb == setdiff(original, now)
        end

        @testset "undo restores the graph exactly" begin
            # DROP alone cannot do this: a deletion has to be replayed from the tombstone.
            undo_firing!(f.graph)
            @test snapshot() == original
            @test graph_size(f.tombstone) == 0
            @test graph_size(f.graph) == 0
            @test isempty(firings(rule=rule))
        end

        @testset "a triple the target already held is not claimed as added" begin
            # The obvious rewrite -- one DELETE/INSERT writing target, firing and tombstone
            # together -- loses data. An R \ I triple the target ALREADY holds gets recorded
            # in the firing graph as though this rule added it, and undo then deletes a
            # triple that predates the rule entirely.
            Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
            Jayhawk.update!("""
                INSERT DATA { GRAPH <$DATA_GRAPH> {
                  <urn:p1> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:id1> ;
                           <$(HR)employeeNumber> "E-4471" .
                  <urn:id1> a <$(GIST)ID> ; <$(GIST)containedText> "E-4471" .
                } }""")
            was = snapshot()
            n_before = length(was)

            preview = dry_run(rule; source=[DATA_GRAPH])
            g = run_rule(rule; source=[DATA_GRAPH], actor="integration")[1]
            n_after = length(snapshot())

            @test g.count == 0                       # nothing was actually added
            @test g.removed == 3
            # the firing describes the change it made, and the preview matched the run
            @test g.count - g.removed == n_after - n_before
            @test preview.count == g.count
            @test preview.removed == g.removed

            undo_firing!(g.graph)
            @test snapshot() == was
            @test ("<urn:p1>", "<$(HR)employeeNumber>", "\"E-4471\"") in snapshot()

            Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
            Jayhawk.update!("""
                INSERT DATA { GRAPH <$DATA_GRAPH> {
                  <urn:p1> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:id1> .
                  <urn:id1> a <$(GIST)ID> ; <$(GIST)containedText> "E-4471" .
                  <urn:p9> a <$(GIST)Person> .
                } }""")
        end

        @testset "the audit log reports what was removed, not just what was added" begin
            g = run_rule(rule; source=[DATA_GRAPH], actor="auditor")[1]
            log = firings(rule=rule)[1]
            @test log.removed == 3
            @test log.count == 1
            @test log.tombstone == g.tombstone
            undo_firing!(g.graph)
        end

        @testset "the MCP tool refuses to delete without confirmation" begin
            out = tool_run_rule(rule; source=[DATA_GRAPH])
            @test occursin("Refused", out)
            @test occursin("DELETES", out)
            @test occursin("remove 3", out)
            @test snapshot() == original              # nothing happened

            out2 = tool_run_rule(rule; source=[DATA_GRAPH], confirm=true, actor="agent")
            @test occursin("removed 3", out2)
            @test length(snapshot()) == 3
            for fr in firings(rule=rule)
                undo_firing!(fr.graph)
            end
            @test snapshot() == original
        end

        @testset "a rewrite needs exactly one target graph" begin
            # "delete from the union of these three" is neither expressible nor reviewable
            @test_throws ArgumentError run_rule(rule; source=String[])
            @test_throws ArgumentError run_rule(rule; source=[DATA_GRAPH, TC_GRAPH])
        end

        Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
    end

    @testset "the control layer: when a rule fires, and when it must not" begin
        Jayhawk.load_file!(fixture("nac_rule.trig"))
        rule = "$(RULES)AssignReview"
        OPS = "http://example.org/ops/"
        OG = "urn:jayhawk:ops-test"
        Jayhawk.update!("DROP SILENT GRAPH <$OG>")
        Jayhawk.update!(
            """
INSERT DATA { GRAPH <$OG> {
  <urn:o1> a <$(OPS)Order> ; <$(OPS)status> <$(OPS)Submitted> ; <$(OPS)orderNumber> "SO-1001" .
  <urn:o2> a <$(OPS)Order> ; <$(OPS)status> <$(OPS)Submitted> ; <$(OPS)orderNumber> "SO-1002" .
  <urn:o3> a <$(OPS)Order> ; <$(OPS)status> <$(OPS)Draft>     ; <$(OPS)orderNumber> "SO-1003" .
} }""",
        )

        @testset "control settings load off the rule" begin
            spec = load_rule(rule)
            @test length(spec.nacs) == 1
            @test spec.nacs[1].graph == "$(RULES)AssignReview_NoTaskYet"
            @test length(spec.nacs[1].triples) == 1
            @test spec.strategy === :ToFixpoint
            @test spec.priority == 100
            @test spec.max_iterations == 10
            @test effective_strategy(spec) === :ToFixpoint
            # the caller still overrides
            @test effective_strategy(spec; strategy=:Once) === :Once
        end

        @testset "the guard compiles after the BIND it guards" begin
            q = compile_from_store(rule)
            @test occursin("FILTER NOT EXISTS", q)
            @test findfirst("BIND(", q).start < findfirst("FILTER NOT EXISTS", q).start
            # the condition is about the MINTED variable, which is the interesting case
            @test occursin("FILTER NOT EXISTS {\n    ?_Task", q)
        end

        @testset "the condition blocks a match, distinguishably from pruning" begin
            # Pre-create o1's task only. prune_known! could NOT produce this outcome: the
            # ex:reviews triple would be genuinely new, so pruning would keep it. Only the
            # negative condition can make the rule decline the whole match.
            Jayhawk.update!("""INSERT DATA { GRAPH <$OG> {
                <$(OPS)review/SO-1001> a <$(OPS)ReviewTask> . } }""")

            fs = run_rule(rule; source=[OG], actor="integration")
            minted = Set(
                (r["s"]::IRIRef).value for f in fs for
                r in select("SELECT DISTINCT ?s WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
            )
            @test minted == Set(["$(OPS)review/SO-1002"])
            @test !any(occursin("SO-1001", m) for m in minted)   # guarded
            @test !any(occursin("SO-1003", m) for m in minted)   # Draft: L never matched it

            @testset "and it is what makes the fixpoint converge" begin
                # One productive round, then the guard refuses the second.
                @test length(fs) == 1
            end

            for f in fs
                undo_firing!(f.graph)
            end
            Jayhawk.update!("""DELETE DATA { GRAPH <$OG> {
                <$(OPS)review/SO-1001> a <$(OPS)ReviewTask> . } }""")
        end

        @testset "with no task anywhere, both submitted orders are served" begin
            fs = run_rule(rule; source=[OG], actor="integration")
            minted = Set(
                (r["s"]::IRIRef).value for f in fs for
                r in select("SELECT DISTINCT ?s WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
            )
            @test minted == Set(["$(OPS)review/SO-1001", "$(OPS)review/SO-1002"])
            for f in fs
                undo_firing!(f.graph)
            end
        end

        @testset "a rule with no stated strategy still follows its mode" begin
            # AssignReview declares ToFixpoint. Strip it and the Assert default applies.
            Jayhawk.update!("DELETE WHERE { <$rule> <$(Jayhawk.P_STRATEGY)> ?o }")
            spec = load_rule(rule)
            @test spec.strategy === nothing
            @test effective_strategy(spec) === :ToFixpoint       # from jhp:_RewriteMode_assert
            Jayhawk.update!("""INSERT DATA {
                <$rule> <$(Jayhawk.P_STRATEGY)> <$(Jayhawk.STRATEGY_TOFIXPOINT)> }""")
        end

        Jayhawk.update!("DROP SILENT GRAPH <$OG>")
    end

    @testset "oneOf: one VALUES clause, two readings" begin
        Jayhawk.load_file!(fixture("oneof_rule.trig"))
        rule = "$(RULES)ComplianceChecks"
        OF = "urn:jayhawk:oneof-test"
        Jayhawk.update!("DROP SILENT GRAPH <$OF>")
        Jayhawk.update!(
            """
INSERT DATA { GRAPH <$OF> {
  <urn:w1> a <http://example.org/ops/Widget> ; <http://example.org/ops/code> "W-1" .
  <urn:w2> a <http://example.org/ops/Widget> ; <http://example.org/ops/code> "W-2" .
  <urn:x9> a <http://example.org/ops/Gadget> ; <http://example.org/ops/code> "X-9" .
} }"""
        )

        @testset "the rdf:List is walked out of the store" begin
            spec = load_rule(rule)
            @test haskey(spec.enums, "$(RULES)_Reg")
            vals = [(t::RDFLiteral).lexical for t in spec.enums["$(RULES)_Reg"]]
            @test vals == ["EU", "JP", "US"]        # sorted, not authored order
            @test "?_Reg" in enum_vars(spec)
            # the generating reading: bound by nothing but its own VALUES
            @test !("?_Reg" in vars_in(spec.match, spec))
        end

        @testset "it compiles to VALUES before the BIND" begin
            q = compile_from_store(rule)
            @test occursin("VALUES ?_Reg { \"EU\" \"JP\" \"US\" }", q)
            @test findfirst("VALUES", q).start < findfirst("BIND(", q).start
            @test findfirst("BIND(", q).start < findfirst("FILTER NOT EXISTS", q).start
        end

        local fs
        @testset "one match becomes three results -- the coproduct" begin
            fs = run_rule(rule; source=[OF], actor="integration")
            # 2 widgets x 3 regulations x 3 triples each
            @test sum(f.count for f in fs) == 18
            checks = Set(
                (r["s"]::IRIRef).value for f in fs for
                r in select("SELECT DISTINCT ?s WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
            )
            @test length(checks) == 6
            @test "http://example.org/ops/check/W-1/EU" in checks
            @test "http://example.org/ops/check/W-2/JP" in checks
            # the Gadget is not a Widget, so L never matched it
            @test !any(occursin("X-9", c) for c in checks)
        end

        @testset "the guard makes a second run derive nothing" begin
            again = run_rule(
                rule; source=vcat([OF], [f.graph for f in fs]), actor="integration"
            )
            @test isempty(again) || all(f.count == 0 for f in again)
        end

        for f in fs
            undo_firing!(f.graph)
        end
        Jayhawk.update!("DROP SILENT GRAPH <$OF>")
    end

    @testset "Skolemising incoming blank nodes" begin
        SK = "urn:jayhawk:skolem-test"
        Jayhawk.update!("DROP SILENT GRAPH <$SK>")
        Jayhawk.load_graph!(
            """
@prefix ex: <http://example.org/sk/> .
ex:s ex:p [ ex:q "inner" ; ex:r [ ex:deep "nested" ] ] .
ex:s2 ex:p ex:plain .
""",
            SK,
        )

        blanks() = length(select("""
            SELECT ?s WHERE { GRAPH <$SK> { ?s ?p ?o }
                              FILTER(isBlank(?s) || isBlank(?o)) }"""))

        @testset "every blank node is named, and the structure survives" begin
            @test blanks() == 4                       # two bnodes, four incident triples
            n = skolemize!(graph=SK)
            @test n == 4
            @test blanks() == 0

            # the nested link must still point at the same node it did before: a rewrite
            # that renamed each occurrence independently would shred the graph
            rows = select("""
                SELECT ?deep WHERE { GRAPH <$SK> {
                  <http://example.org/sk/s> <http://example.org/sk/p> ?outer .
                  ?outer <http://example.org/sk/r> ?inner .
                  ?inner <http://example.org/sk/deep> ?deep } }""")
            @test length(rows) == 1
            @test (rows[1]["deep"]::RDFLiteral).lexical == "nested"

            # and the IRIs are in the documented namespace
            subs = select("SELECT DISTINCT ?s WHERE { GRAPH <$SK> { ?s ?p ?o } }")
            @test any(startswith((r["s"]::IRIRef).value, Jayhawk.SKOLEM_BASE) for r in subs)
            # untouched data stays untouched
            @test !isempty(select("""SELECT ?o WHERE { GRAPH <$SK> {
                <http://example.org/sk/s2> <http://example.org/sk/p> ?o } }"""))
        end

        @testset "two loads do not merge, because their blank nodes never denoted the same thing" begin
            # A fresh namespace per call is correctness, not convenience: blank nodes in two
            # documents are distinct by RDF semantics, so reusing a base would silently
            # identify them.
            doc = """@prefix ex: <http://example.org/sk/> . ex:a ex:p [ ex:q "v" ] ."""
            for g in ("urn:jayhawk:sk-a", "urn:jayhawk:sk-b")
                Jayhawk.update!("DROP SILENT GRAPH <$g>")
                Jayhawk.load_graph!(doc, g; skolemize=true)   # the flag on the exact scope
            end
            got(g) = Set(
                (r["s"]::IRIRef).value for r in select(
                    "SELECT DISTINCT ?s WHERE { GRAPH <$g> { ?s <http://example.org/sk/q> ?o } }",
                )
            )
            a, b = got("urn:jayhawk:sk-a"), got("urn:jayhawk:sk-b")
            @test length(a) == 1 && length(b) == 1
            @test isempty(intersect(a, b))            # distinct documents, distinct nodes
            for g in ("urn:jayhawk:sk-a", "urn:jayhawk:sk-b")
                Jayhawk.update!("DROP SILENT GRAPH <$g>")
            end
        end

        @testset "base chooses the namespace, and nothing more" begin
            # It does NOT make two loads share identity, and cannot: the label comes from
            # the store's internal id for the node, minted afresh on every parse. Two loads
            # of the same file are two documents, so disjoint names are the right answer --
            # but it means these IRIs are stable going forward, not reproducible backward.
            doc = """@prefix ex: <http://example.org/sk/> . ex:a ex:p [ ex:q "v" ] ."""
            for g in ("urn:jayhawk:sk-c", "urn:jayhawk:sk-d")
                Jayhawk.update!("DROP SILENT GRAPH <$g>")
                Jayhawk.load_graph!(doc, g)
                skolemize!(graph=g, base="urn:jayhawk:shared:")
            end
            got(g) = Set(
                (r["s"]::IRIRef).value for r in select(
                    "SELECT DISTINCT ?s WHERE { GRAPH <$g> { ?s <http://example.org/sk/q> ?o } }",
                )
            )
            c, d = got("urn:jayhawk:sk-c"), got("urn:jayhawk:sk-d")
            @test all(startswith(x, "urn:jayhawk:shared:") for x in union(c, d))
            @test c != d                              # not reproducible, and correctly so
            for g in ("urn:jayhawk:sk-c", "urn:jayhawk:sk-d")
                Jayhawk.update!("DROP SILENT GRAPH <$g>")
            end
        end

        @testset "skolemising a graph with no blank nodes is a no-op" begin
            @test skolemize!(graph=SK) == 0
        end

        Jayhawk.update!("DROP SILENT GRAPH <$SK>")
    end

    @testset "jhp:inGraph reads a data source, not only a graph" begin
        # Round 5b: the third reading of jhp:inGraph. The scope names a
        # gistp:TabularDataSource instead of a graph, and the pattern compiles to
        # SERVICE <x-sparql-anything:> rather than GRAPH.
        #
        # The location has to be absolute and is therefore environment-specific, so the
        # rule is generated here from the committed CSV rather than committed itself.
        CR = "http://example.org/csvrules/"
        csv = fixture("people.csv")
        FXN = "http://sparql.xyz/facade-x/ns/"

        function csv_rule(; location=csv, extra="")
            """
            @prefix rdf:   <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
            @prefix xsd:   <http://www.w3.org/2001/XMLSchema#> .
            @prefix gist:  <$(GIST)> .
            @prefix gistp: <https://w3id.org/semanticarts/ns/patterns/gist/> .
            @prefix jhp:   <https://turingtest37.github.io/jayhawkpatterning/> .
            @prefix fx:    <$(FXN)> .
            @prefix xyz:   <http://sparql.xyz/facade-x/data/> .
            @prefix :      <$(CR)> .
            :CsvToPerson a jhp:Rule ;
                jhp:hasMatchPattern :CsvToPerson_L ;
                jhp:hasConstructPattern :CsvToPerson_R ;
                jhp:rewriteMode jhp:_RewriteMode_construct ; jhp:strategy jhp:Once .
            :CsvToPerson_L a gistp:SparqlPattern ; jhp:inGraph :_People .
            :CsvToPerson_R a gistp:SparqlPattern .
            :_People a gistp:TabularDataSource ; fx:csv.headers "true" ; $(extra)
                     fx:location $(location) .
            :_Row a gistp:SparqlVariable ; gistp:variableText "?_Row" .
            :_id a gistp:LiteralVariable , gistp:SparqlVariable ;
                 gistp:variableText "?id" ; gistp:requiresDatatype xsd:string .
            :_Person a gist:Person , gistp:SparqlVariable ;
                gistp:variableText "?_Person" ;
                gistp:iriTemplate "http://example.org/hr/person/{id}" ;
                gistp:hasSlot [ a gistp:TemplateSlot ;
                                gistp:slotName "id" ; gistp:slotValue :_id ] .
            :CsvToPerson_L { :_Row xyz:id "?id"^^gistp:var ; xyz:given "?given"^^gistp:var . }
            :CsvToPerson_R { :_Person rdf:type gist:Person ; gist:name "?given"^^gistp:var . }
            """
        end

        engine_cleanup()
        trig = joinpath(mktempdir(), "csv_rule.trig")
        write(trig, csv_rule(location="\"$(csv)\""))
        Jayhawk.load_file!(trig)

        @testset "the data source is discovered and its fx: options loaded" begin
            spec = load_rule("$(CR)CsvToPerson")
            @test spec.match_scope == "$(CR)_People"
            # ... and it is NOT a graph scope, which is what keeps it out of the dataset
            # clause and lets an extraction rule run with an empty `source`.
            @test is_scoped(spec) == false
            @test haskey(spec.services, "$(CR)_People")
            props = spec.services["$(CR)_People"]
            @test first.(props) == ["$(FXN)csv.headers", "$(FXN)location"]
            @test last(props[2]) == csv

            q = compile_rule(spec)
            @test occursin("SERVICE <x-sparql-anything:> {", q)
            @test !occursin("GRAPH", q)
            @test !occursin("USING", q)
            # the mint still BINDs outside the group, exactly as it does outside a GRAPH
            @test occursin("ENCODE_FOR_URI(STR(?id))", q)
        end

        engine_cleanup()
    end

    @testset "jhp:hasFilterCondition: the comparison a BGP cannot make" begin
        # `check_filters` argues at length about what the emitted text may contain. Only a
        # real SPARQL engine can settle whether what it lets through actually parses and
        # actually narrows the match, so that is what this does.
        Jayhawk.load_file!(fixture("filter_rule.trig"))
        rule = "$(RULES)OrderPrecedence"
        OPS = "http://example.org/ops/"
        FG = "urn:jayhawk:filter-test"
        Jayhawk.update!("DROP SILENT GRAPH <$FG>")
        Jayhawk.update!("""
            INSERT DATA { GRAPH <$FG> {
              <urn:f1> a <$(OPS)Order> ; <$(OPS)orderNumber> "SO-1001" .
              <urn:f2> a <$(OPS)Order> ; <$(OPS)orderNumber> "SO-1002" .
              <urn:f3> a <$(OPS)Order> ; <$(OPS)orderNumber> "SO-1003" .
            } }""")

        @testset "the conditions load off the rule" begin
            spec = load_rule(rule)
            @test spec.filters == [
                "DATATYPE(?numA) = <http://www.w3.org/2001/XMLSchema#string>",
                "STR(?numA) < STR(?numB)",
            ]     # sorted by text
        end

        @testset "each becomes its own FILTER, after the match" begin
            q = compile_from_store(rule)
            @test occursin("FILTER(STR(?numA) < STR(?numB))", q)
            # the IRI reaches the store intact: no escaping, no prefix, '#' and all
            @test occursin(
                "FILTER(DATATYPE(?numA) = <http://www.w3.org/2001/XMLSchema#string>)", q
            )
            @test length(collect(eachmatch(r"FILTER\(", q))) == 2
            @test findfirst("?_OrderA <", q).start < findfirst("FILTER(", q).start
            @test q == compile_from_store(rule)        # still byte-stable
        end

        @testset "the store parses it and the filter does the narrowing" begin
            # Nine ordered pairs exist. Three survive. If the FILTER were dropped -- or
            # silently errored, which is what an unbound variable in one would do -- the
            # count would be 9 or 0, never 3.
            fs = run_rule(rule; source=[FG], actor="integration")
            @test length(fs) == 1
            @test fs[1].count == 3
            got = Set(
                (sparql_text(r["s"]), sparql_text(r["o"])) for r in select("""
                                                               SELECT ?s ?o WHERE {
                                                                 GRAPH <$(fs[1].graph)> { ?s <$(OPS)precedes> ?o } }""")
            )
            @test got == Set([
                ("<urn:f1>", "<urn:f2>"), ("<urn:f1>", "<urn:f3>"), ("<urn:f2>", "<urn:f3>")
            ])
            undo_firing!(fs[1].graph)
        end

        @testset "explain_rule itemises the filters before anything runs" begin
            # The argument for letting a filter be text at all is "read what the rule
            # declares before you run it". That has to be something this report makes
            # possible, the way it already itemises the guards.
            out = tool_explain_rule(rule; source=[FG])
            @test occursin("filters           : 2 condition(s)", out)
            @test occursin("FILTER(STR(?numA) < STR(?numB))", out)
        end

        @testset "a condition that declares no expression is refused" begin
            # It would compile to no FILTER at all, so the rule would quietly match MORE
            # than it says. An inner join on jhp:filterText could not tell the difference.
            e = try
                load_rule("$(RULES)OrderPrecedenceBroken")
            catch err
                err
            end
            @test e isa ErrorException
            @test occursin("declares no jhp:filterText", sprint(showerror, e))
        end

        Jayhawk.update!("DROP SILENT GRAPH <$FG>")
        Jayhawk.update!("DELETE WHERE { ?s <$(Jayhawk.P_FILTER)> ?o } ;
                         DELETE WHERE { ?s <$(Jayhawk.P_FILTERTEXT)> ?o } ;
                         DELETE WHERE { ?s a <$(Jayhawk.JHP_NS)FilterCondition> }")
        for g in ("$(RULES)OrderPrecedence_L", "$(RULES)OrderPrecedence_R")
            Jayhawk.update!("DROP SILENT GRAPH <$g>")
        end
        engine_cleanup()
    end

    @testset "jhp:inGraph reads per named graph" begin
        # Round 5a: the read side. L and its guard are scoped to a graph variable; R uses
        # that variable as an ordinary term, so "which graph did this come from" becomes a
        # fact the rule asserts.
        BKA, BKB = "urn:jayhawk:test:bookA", "urn:jayhawk:test:bookB"
        BK, BKR = "http://example.org/bk/", "http://example.org/bkrules/"

        engine_cleanup()
        Jayhawk.update!("DROP SILENT GRAPH <$BKA> ; DROP SILENT GRAPH <$BKB>")
        @testset "what was once true is answerable" begin
            # The challenge's own distinction: "what is true now" versus "what was once true".
            # The engine could always answer the second in principle -- a Rewrite keeps what it
            # removes in a tombstone -- and never in practice, because finding a tombstone meant
            # already knowing its UUID. Provenance is now the index over them.
            Jayhawk.load_file!(fixture("rewrite_rule.trig"))
            Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
            Jayhawk.update!("DROP SILENT GRAPH <$(Jayhawk.PROVENANCE_GRAPH)>")
            Jayhawk.update!("""
                INSERT DATA { GRAPH <$DATA_GRAPH> {
                  <urn:h:p1> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:h:i1> .
                  <urn:h:i1> a <$(GIST)ID> ; <$(GIST)containedText> "E-7" .
                } }""")
            f = run_rule(
                "$(RULES)FlattenIdentifier"; source=[DATA_GRAPH], actor="history-test"
            )[1]

            @testset "the retracted triples are found without knowing the tombstone" begin
                hs = retractions()
                @test !isempty(hs)
                @test all(h -> h.rule == "$(RULES)FlattenIdentifier", hs)
                @test all(h -> h.target == DATA_GRAPH, hs)
                @test all(h -> h.actor == "history-test", hs)
                @test all(h -> h.tombstone == f.tombstone, hs)
                # the identifier link is gone from the data and present in the history
                @test !Jayhawk.ask(
                    "ASK { GRAPH <$DATA_GRAPH> { <urn:h:p1> <$(GIST)isIdentifiedBy> <urn:h:i1> } }",
                )
                @test any(
                    h ->
                        h.subject == "<urn:h:p1>" &&
                        h.predicate == "<$(GIST)isIdentifiedBy>",
                    hs,
                )
            end

            @testset "the pattern narrows, and a non-IRI is refused" begin
                @test !isempty(retractions(; subject="urn:h:i1"))
                @test isempty(retractions(; subject="urn:h:nobody"))
                @test length(retractions(; subject="urn:h:p1")) < length(retractions())
                # A caller-supplied value reaches a FILTER, so it is checked rather than trusted.
                @test_throws ArgumentError retractions(; subject="not an iri")
            end

            @testset "the record is carried by gist, not by PROV" begin
                # No PROV anywhere. gist is already this project's upper ontology and already a
                # dependency of the pattern vocabulary, so the record speaks the same language as
                # the data it describes instead of a second one that has to be kept in step.
                P = Jayhawk.PROVENANCE_GRAPH
                G = Jayhawk.GIST_ONT_NS
                for (pred, obj) in (
                    # the rule and each source graph "gave rise to or justify" the firing
                    ("$(G)isBasedOn", "<$(RULES)FlattenIdentifier>"),
                    ("$(G)isBasedOn", "<$DATA_GRAPH>"),
                    # hasParticipant, NOT comesFromAgent -- whose range is Organization or
                    # Person, so it would entail that a piece of software is a person
                    ("$(G)hasParticipant", "<urn:jayhawk:actor:history-test>"),
                    ("$(Jayhawk.JH_NS)appliedRule", "<$(RULES)FlattenIdentifier>"),
                    ("$(Jayhawk.JH_NS)tombstoneGraph", "<$(f.tombstone)>"),
                )
                    @test Jayhawk.ask("ASK { GRAPH <$P> { <$(f.graph)> <$pred> $obj } }")
                end
                @test Jayhawk.ask(
                    "ASK { GRAPH <$P> { <$(f.graph)> a <$(Jayhawk.JH_NS)Firing> } }"
                )
                @test Jayhawk.ask("ASK { GRAPH <$P> { <$(f.graph)> a <$(G)Event> } }")
                # A tombstone is produced by the firing that carved it out, and says so itself.
                @test Jayhawk.ask("""ASK { GRAPH <$P> {
                    <$(f.tombstone)> a <$(Jayhawk.JH_NS)Tombstone> ;
                                     <$(G)isProducedBy> <$(f.graph)> } }""")
            end

            @testset "being a historical event is inferred, not asserted" begin
                # gist:HistoricalEvent is an EQUIVALENT class: gist:Event with exactly one
                # actualStartDateTime and exactly one actualEndDateTime. So the record asserts
                # the two datetimes and lets a reasoner reach the classification -- which is the
                # difference between a machine-verifiable axiom and a label.
                P = Jayhawk.PROVENANCE_GRAPH
                G = Jayhawk.GIST_ONT_NS
                DT = "<http://www.w3.org/2001/XMLSchema#dateTime>"
                for prop in ("actualStartDateTime", "actualEndDateTime")
                    @test Jayhawk.ask("""ASK { GRAPH <$P> { <$(f.graph)> <$(G)$prop> ?t
                        FILTER(DATATYPE(?t) = $DT) } }""")
                end
                # exactly one of each, which is what the cardinality restrictions require
                for prop in ("actualStartDateTime", "actualEndDateTime")
                    n = only(select("""SELECT (COUNT(?t) AS ?n) WHERE { GRAPH <$P> {
                        <$(f.graph)> <$(G)$prop> ?t } }"""))["n"]
                    @test (n::RDFLiteral).lexical == "1"
                end
                # the class itself is never asserted -- that would be claiming the inference
                @test !Jayhawk.ask("ASK { GRAPH <$P> { ?s a <$(G)HistoricalEvent> } }")
            end

            @testset "nothing in the record reaches for PROV" begin
                P = Jayhawk.PROVENANCE_GRAPH
                @test !Jayhawk.ask("""ASK { GRAPH <$P> { ?s ?p ?o
                    FILTER(STRSTARTS(STR(?p), "http://www.w3.org/ns/prov#")) } }""")
                @test !Jayhawk.ask("""ASK { GRAPH <$P> { ?s a ?t
                    FILTER(STRSTARTS(STR(?t), "http://www.w3.org/ns/prov#")) } }""")
            end

            @testset "undo retracts the whole record, leaving no orphan" begin
                # Three subjects have triples: the firing, its activity, and the tombstone.
                # Retracting only the firing would leave an activity behind still claiming a
                # rule ran -- a worse audit trail than none.
                undo_firing!(f.graph)
                @test isempty(retractions())
                @test Jayhawk.graph_size(Jayhawk.PROVENANCE_GRAPH) == 0
                # and the rewrite itself is undone: the identifier link is back
                @test Jayhawk.ask(
                    "ASK { GRAPH <$DATA_GRAPH> { <urn:h:p1> <$(GIST)isIdentifiedBy> <urn:h:i1> } }",
                )
            end

            @testset "the MCP tool distinguishes never-asserted from still-true" begin
                out = tool_retractions()
                @test occursin("Nothing has been retracted", out)
                out = tool_retractions(; subject="urn:h:p1")
                @test occursin("both look like this", out)   # the ambiguity is stated, not hidden
            end

            Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
            engine_cleanup()
        end

        @testset "source maps load off the store and generate the Facade-X shape" begin
            # Stock Fuseki has no x-sparql-anything: SERVICE, so what is asserted here is the
            # compiled text and the loading. The rule is run against real SPARQL Anything in
            # test/fixtures -- see the fixture's own notes and the commit that added it.
            SMR = "http://example.org/smrules/"
            STAFF = "http://example.org/staff/"
            Jayhawk.load_file!(fixture("source_map_rule.trig"))

            @testset "a map is found from the variable it feeds, including a mint slot's" begin
                spec = load_rule("$(SMR)StaffFromCsv")
                @test length(spec.source_maps) == 4
                byvar = Dict(m.variable => m for m in spec.source_maps)
                @test sort(collect(keys(byvar))) == ["?given", "?id", "?skill", "?title"]
                @test byvar["?given"].column == "given name"
                @test byvar["?title"].column == "dc.title[en]"
                @test byvar["?title"].string_before == " ("
                @test byvar["?skill"].separator == "||"
                @test byvar["?skill"].pattern_match == "^[a-z]+\$"
                # ?id appears in NO pattern -- only as an iriTemplate slot value. Judging
                # relevance from the patterns alone dropped exactly this map, and the failure
                # surfaced as "minting from another minted variable", which it is not.
                @test byvar["?id"].column == "id"
                @test !any(
                    t -> any(
                        x ->
                            x isa RDFLiteral && is_var_literal(x) && x.lexical == "?id",
                        (t.subject, t.predicate, t.object),
                    ),
                    vcat(spec.match, spec.construct),
                )
            end

            @testset "the generated triples sit inside the SERVICE, the pipeline outside" begin
                q = compile_from_store("$(SMR)StaffFromCsv")
                @test occursin("SERVICE <$(Jayhawk.SA_SERVICE)>", q)
                svc = q[findfirst("SERVICE", q).start:findfirst("\n  }", q).stop]
                # the row variable is synthesised, so the author never writes rdf:_1 or fx:root
                @test occursin("$(Jayhawk.FX_ROW_VAR) <$(Jayhawk.XYZ_NS)id> ?id .", svc)
                @test occursin(
                    "$(Jayhawk.FX_ROW_VAR) <$(Jayhawk.XYZ_NS)given%20name> ?given .", svc
                )
                @test occursin("$(Jayhawk.XYZ_NS)dc.title[en]", svc)     # NOT %5Ben%5D
                # apf:strSplit is an ARQ property function the Facade-X evaluator has no reason
                # to know, and the split joins over values the service already produced.
                @test !occursin("strSplit", svc)
                @test occursin("<$(Jayhawk.APF_STRSPLIT)> (?__rawskill", q)
                # the separator reached the store as a regex, not as a literal "||"
                @test occursin("\"\\\\|\\\\|\"", q)
                @test q == compile_from_store("$(SMR)StaffFromCsv")      # byte-stable
            end

            @testset "the mint reads a column the pattern never names" begin
                q = compile_from_store("$(SMR)StaffFromCsv")
                @test occursin("ENCODE_FOR_URI(STR(?id))", q)
                @test findfirst("<$(Jayhawk.XYZ_NS)id> ?id", q).start <
                    findfirst("AS ?_Person", q).start
            end

            @testset "every list-valued alternative is refused by name" begin
                # Fetched with OPTIONAL purely so they can be refused: read through an inner join
                # they would come back as no source map at all, and the rule would compile to a
                # pattern with an unbound variable rather than to an error.
                for (prop, fragment) in (
                    (Jayhawk.P_MAPFROM, "has no class for one yet"),
                    (Jayhawk.P_MAPFIRST, "COALESCE"),
                    (Jayhawk.P_MAPEACH, "MULTIPLIES solutions"),
                    (Jayhawk.P_CONCAT, "CONCAT"),
                )
                    Jayhawk.update!(
                        "INSERT DATA { <$(SMR)IdMap> <$prop> <urn:sm:whatever> }"
                    )
                    e = try
                        load_rule("$(SMR)StaffFromCsv")
                    catch err
                        err
                    end
                    @test e isa ErrorException
                    @test occursin(fragment, sprint(showerror, e))
                    Jayhawk.update!(
                        "DELETE DATA { <$(SMR)IdMap> <$prop> <urn:sm:whatever> }"
                    )
                end
                # and with them all gone it loads again, which is what makes the above meaningful
                @test length(load_rule("$(SMR)StaffFromCsv").source_maps) == 4
            end

            @testset "a map with no column, and two maps for one variable, are refused" begin
                Jayhawk.update!(
                    "DELETE DATA { <$(SMR)IdMap> <$(Jayhawk.P_MAPFROMSTR)> \"id\" }"
                )
                e = try
                    load_rule("$(SMR)StaffFromCsv")
                catch err
                    err
                end
                @test occursin("declares no gistp:mapFromString", sprint(showerror, e))
                Jayhawk.update!(
                    "INSERT DATA { <$(SMR)IdMap> <$(Jayhawk.P_MAPFROMSTR)> \"id\" }"
                )

                Jayhawk.update!("""INSERT DATA {
                    <$(SMR)IdMap2> a <$(Jayhawk.C_SOURCEMAP)> ;
                        <$(Jayhawk.P_MAPTO)> <$(SMR)_id> ;
                        <$(Jayhawk.P_MAPFROMSTR)> "identifier" }""")
                e = try
                    load_rule("$(SMR)StaffFromCsv")
                catch err
                    err
                end
                @test occursin(
                    "is fed by more than one gistp:SourceMap", sprint(showerror, e)
                )
                Jayhawk.update!("DELETE WHERE { <$(SMR)IdMap2> ?p ?o }")
                @test length(load_rule("$(SMR)StaffFromCsv").source_maps) == 4
            end

            Jayhawk.update!("DROP SILENT GRAPH <$(SMR)StaffFromCsv_L>")
            Jayhawk.update!("DROP SILENT GRAPH <$(SMR)StaffFromCsv_R>")
            Jayhawk.update!("""
                DELETE WHERE { ?s a <$(Jayhawk.C_SOURCEMAP)> } ;
                DELETE WHERE { ?s <$(Jayhawk.P_MAPTO)> ?o } ;
                DELETE WHERE { ?s <$(Jayhawk.P_MAPFROMSTR)> ?o } ;
                DELETE WHERE { ?s <$(Jayhawk.P_SEPARATOR)> ?o } ;
                DELETE WHERE { ?s <$(Jayhawk.P_STRBEFORE)> ?o } ;
                DELETE WHERE { ?s <$(Jayhawk.P_PATMATCH)> ?o } ;
                DELETE WHERE { ?s <$(Jayhawk.P_PATEXCLUDE)> ?o } ;
                DELETE WHERE { ?s a <$(Jayhawk.C_LITERALVAR)> } ;
                DELETE WHERE { ?s <$(Jayhawk.P_INGRAPH)> ?o } ;
                DELETE WHERE { ?s a <$(Jayhawk.C_TABULARSOURCE)> }""")
            engine_cleanup()
        end

        @testset "a rule can declare where its output goes" begin
            # Write-side jhp:inGraph. What does NOT change is the firing graph: a scoped rule
            # still projects R into a fresh one, which is then pruned and promoted. That is why
            # the write stays reversible -- undo retracts from the destination exactly what the
            # firing graph holds, rather than re-deriving it and hoping the two agree.
            WSR = "http://example.org/wsrules/"
            WS = "http://example.org/ws/"
            HR_G = "urn:jayhawk:ws-test:hr"
            ORG_G = "urn:jayhawk:ws-test:org"
            Jayhawk.load_file!(fixture("write_scoped_rule.trig"))
            for g in (DATA_GRAPH, HR_G, ORG_G)
                Jayhawk.update!("DROP SILENT GRAPH <$g>")
            end
            Jayhawk.update!("""
                INSERT DATA { GRAPH <$DATA_GRAPH> {
                  <urn:w:alice> a <$(GIST)Person> ; <$(GIST)name> "Alice" .
                  <urn:w:bob>   a <$(GIST)Person> ; <$(GIST)name> "Bob" .
                } }""")

            @testset "the output lands in the declared graph, not just a firing" begin
                f = run_rule("$(WSR)FileEmployee"; source=[DATA_GRAPH], actor="ws-test")[1]
                @test f.count == 4
                @test f.target == HR_G
                @test isempty(f.tombstone)          # nothing was removed; this is not a rewrite
                @test Jayhawk.graph_size(HR_G) == 4
                # the firing graph keeps its own copy: the audit record, and what undo reads
                @test Jayhawk.graph_size(f.graph) == 4
                @test Jayhawk.ask(
                    "ASK { GRAPH <$HR_G> { <urn:w:alice> a <$(WS)Employee> } }"
                )

                @testset "re-running is pruned against the DESTINATION" begin
                    # Not against what the rule read. Those differ the moment the destination is
                    # not itself a source, and reporting the wrong one would make a re-run of a
                    # converged rule look productive.
                    recorded = length(firings())
                    again = run_rule(
                        "$(WSR)FileEmployee"; source=[DATA_GRAPH], actor="ws-test"
                    )
                    @test isempty(again)                    # contributed nothing, so no firing
                    @test length(firings()) == recorded     # and no record
                end

                @testset "undo retracts from the destination" begin
                    undo_firing!(f.graph)
                    @test Jayhawk.graph_size(HR_G) == 0
                    @test !is_firing(f.graph)
                end
            end

            @testset "a write-scoped Assert reaches a fixpoint in place" begin
                # The case that was refused outright. An unscoped fixpoint appends each round's
                # firing graph to the working set, so a scoped rule would end up matching inside
                # its own output; a write-scoped one promotes instead, leaving the dataset clause
                # unchanged while round two reads round one's results from the destination.
                Jayhawk.update!("""
                    INSERT DATA { GRAPH <$ORG_G> {
                      <urn:w:a> <$(WS)reportsTo> <urn:w:b> .
                      <urn:w:b> <$(WS)reportsTo> <urn:w:c> .
                      <urn:w:c> <$(WS)reportsTo> <urn:w:d> .
                    } }""")
                fs = run_rule("$(WSR)CloseReportsTo"; source=[ORG_G], actor="ws-test")
                @test length(fs) == 2                    # two productive rounds, then quiescence
                @test [f.count for f in fs] == [2, 1]
                @test all(f -> f.target == ORG_G, fs)
                @test Jayhawk.graph_size(ORG_G) == 6     # 3 asserted + 3 derived, in place
                @test Jayhawk.ask(
                    "ASK { GRAPH <$ORG_G> { <urn:w:a> <$(WS)reportsTo> <urn:w:d> } }"
                )

                for f in reverse(fs)
                    undo_firing!(f.graph)
                end
                @test Jayhawk.graph_size(ORG_G) == 3     # an exact inverse, not an approximation
                @test !Jayhawk.ask(
                    "ASK { GRAPH <$ORG_G> { <urn:w:a> <$(WS)reportsTo> <urn:w:d> } }"
                )
            end

            @testset "new means new to the DESTINATION, even if a source already holds it" begin
                # The names are already true in the graph CopyName reads; the rule says they
                # belong in the HR graph too. Pruning against the sources dropped them: HEAD
                # promoted nothing, and dry_run agreed there was nothing to add. The oracle this
                # exists for is moneygraph's bond fix, which writes an issuer's gist:Organization
                # typing into __securities__extra although the trades graph already has it.
                Jayhawk.update!("DROP SILENT GRAPH <$HR_G>")
                pre = dry_run("$(WSR)CopyName"; source=[DATA_GRAPH])
                f = only(run_rule("$(WSR)CopyName"; source=[DATA_GRAPH], actor="ws-test"))
                @test pre.count == f.count == 2          # the preview prunes as the run does
                @test Jayhawk.graph_size(HR_G) == 2
                @test Jayhawk.ask("ASK { GRAPH <$HR_G> { <urn:w:alice> <$(GIST)name> \"Alice\" } }")
                undo_firing!(f.graph)
                @test Jayhawk.graph_size(HR_G) == 0      # undo retracts from the destination...
                @test Jayhawk.ask(                       # ...and leaves the source's copy alone
                    "ASK { GRAPH <$DATA_GRAPH> { <urn:w:alice> <$(GIST)name> \"Alice\" } }"
                )
            end

            @testset "a fixpoint that cannot read its destination is refused" begin
                # Every round would re-derive the same triples, find them already promoted, prune
                # to nothing and report convergence after one pass -- the right answer by
                # accident, and the wrong one as soon as a second round would have derived
                # anything.
                e = try
                    run_rule("$(WSR)CloseReportsTo"; source=[DATA_GRAPH], actor="ws-test")
                catch err
                    err
                end
                @test e isa ArgumentError
                @test occursin("needs that graph in `source` as well", sprint(showerror, e))
            end

            @testset "a write scope does not demand a source the way a read scope does" begin
                # The old refusal treated both alike. A scoped READ with no source is genuinely
                # unsafe -- a graph variable would enumerate every named graph in the store. A
                # scoped WRITE reads nothing it was not already reading.
                Jayhawk.update!(
                    """
        INSERT DATA { <urn:w:carol> a <$(GIST)Person> ; <$(GIST)name> "Carol" }"""
                )
                f = run_rule("$(WSR)FileEmployee"; actor="ws-test")[1]   # no source at all
                @test f.count == 2
                @test Jayhawk.ask(
                    "ASK { GRAPH <$HR_G> { <urn:w:carol> a <$(WS)Employee> } }"
                )
                undo_firing!(f.graph)
                Jayhawk.update!("DELETE WHERE { <urn:w:carol> ?p ?o }")
            end

            for g in (DATA_GRAPH, HR_G, ORG_G)
                Jayhawk.update!("DROP SILENT GRAPH <$g>")
            end
            for n in ("FileEmployee", "CloseReportsTo", "FileByVariable")
                Jayhawk.update!(
                    "DROP SILENT GRAPH <$(WSR)$(n)_L> ; DROP SILENT GRAPH <$(WSR)$(n)_R>"
                )
            end
            Jayhawk.update!("DELETE WHERE { ?s <$(Jayhawk.P_INGRAPH)> ?o }")
            engine_cleanup()
        end

        @testset "transaction time is totally ordered" begin
            # A rule set made this matter. Before ordinals, both of these firings carried the
            # same whole-second stamp and iteration 1, and firings() reported them in the wrong
            # order -- consistently, so it looked trustworthy.
            SETS = "http://example.org/sets/"
            Jayhawk.load_file!(fixture("person_to_employee.trig"))
            Jayhawk.load_file!(fixture("transitive_rule.trig"))
            Jayhawk.load_file!(fixture("rule_set.trig"))
            Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
            Jayhawk.update!("DROP SILENT GRAPH <$(Jayhawk.PROVENANCE_GRAPH)>")
            Jayhawk.update!("""
                INSERT DATA { GRAPH <$DATA_GRAPH> {
                  <urn:o:p1> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:o:i1> .
                  <urn:o:i1> a <$(GIST)ID> ; <$(GIST)containedText> "E-9" .
                  <urn:o:a> <$(TC)partOf> <urn:o:b> .
                  <urn:o:b> <$(TC)partOf> <urn:o:c> .
                } }""")

            fs = run_rules("$(SETS)HrThenParts"; source=[DATA_GRAPH], actor="ordinal-test")
            log = [l for l in firings() if l.actor == "ordinal-test"]

            @testset "the first firing into an empty provenance graph is ordinal 1" begin
                # The aggregate edge case, asserted rather than assumed -- an earlier attempt
                # left ?ord unbound here, and SPARQL silently drops a triple with an unbound
                # object, so the ordinal vanished with no error anywhere.
                @test minimum(l.ordinal for l in log) == 1
            end

            @testset "ordinals are distinct and the log is in application order" begin
                @test length(unique(l.ordinal for l in log)) == length(log)
                @test [l.graph for l in log] == reverse([f.graph for f in fs])
                # and the stamps themselves now differ, which second resolution made impossible
                @test all(occursin(".", l.at) for l in log)
            end

            @testset "an ordinal is never reused after an undo" begin
                # MAX, not COUNT. Undoing a firing retracts its record, so a count-based ordinal
                # would hand the next firing a number an existing record still holds -- and two
                # records sharing an ordinal is exactly the tie it exists to break.
                highest = maximum(l.ordinal for l in log)
                earliest = argmin(l -> l.ordinal, log)
                undo_firing!(earliest.graph)
                f = run_rule(
                    "$(RULES)PersonToEmployee"; source=[DATA_GRAPH], actor="ordinal-test"
                )[1]
                again = only(l for l in firings() if l.graph == f.graph)
                @test again.ordinal > highest
                undo_firing!(f.graph)
            end

            for f in reverse(fs)
                is_firing(f.graph) && undo_firing!(f.graph)
            end
            Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
            engine_cleanup()
        end

        @testset "a rule set loads and runs in order" begin
            SETS = "http://example.org/sets/"
            Jayhawk.load_file!(fixture("person_to_employee.trig"))
            Jayhawk.load_file!(fixture("transitive_rule.trig"))
            Jayhawk.load_file!(fixture("rule_set.trig"))
            Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
            Jayhawk.update!("""
                INSERT DATA { GRAPH <$DATA_GRAPH> {
                  <urn:s:p1> a <$(GIST)Person> ; <$(GIST)isIdentifiedBy> <urn:s:i1> .
                  <urn:s:i1> a <$(GIST)ID> ; <$(GIST)containedText> "E-1" .
                  <urn:s:a> <$(TC)partOf> <urn:s:b> .
                  <urn:s:b> <$(TC)partOf> <urn:s:c> .
                  <urn:s:c> <$(TC)partOf> <urn:s:d> .
                } }""")

            @testset "order comes from gist:sequence, not document order" begin
                # The fixture declares sequence 2 before sequence 1 on purpose: a fixture listed
                # in order cannot tell whether the loader read the order or just got lucky.
                set = load_rule_set("$(SETS)HrThenParts")
                @test set.label == "People, then parts"
                @test set.strategy === :Once
                @test set.rules ==
                      ["$(RULES)PersonToEmployee", "$(TC)rules/PartOfTransitive"] ||
                    set.rules == [
                    "$(RULES)PersonToEmployee",
                    "http://example.org/tcrules/PartOfTransitive",
                ]
            end

            @testset "each rule keeps its own strategy inside the set" begin
                # PersonToEmployee is Construct and fires once. PartOfTransitive is Assert, so
                # it closes to a fixpoint *within* the set's single pass -- three partOf links
                # give three more by transitivity, over two productive rounds. If the set had
                # flattened its members to one application each, this would be 1 + 1 = 2 firings.
                fs = run_rules(
                    "$(SETS)HrThenParts"; source=[DATA_GRAPH], actor="integration"
                )
                @test length(fs) > 2
                @test fs[1].rule == "$(RULES)PersonToEmployee"
                @test fs[1].mode === :Construct
                @test all(f -> f.mode === :Assert, fs[2:end])
                # every returned firing is undoable: none is a no-op with no provenance record
                @test all(f -> is_firing(f.graph), fs)
                for f in reverse(fs)
                    undo_firing!(f.graph)
                end
            end

            @testset "an ad-hoc list is ordered by priority, not by argument order" begin
                # What jhp:priority is still for, now that gist:sequence carries set-relative
                # order. AssignReview declares priority 100; PersonToEmployee declares none, so
                # 0. Passing them lowest-first must still run the higher priority first.
                Jayhawk.load_file!(fixture("nac_rule.trig"))
                Jayhawk.update!(
                    """
        INSERT DATA { GRAPH <$DATA_GRAPH> {
          <urn:s:o1> a <http://example.org/ops/Order> ;
            <http://example.org/ops/status> <http://example.org/ops/Submitted> ;
            <http://example.org/ops/orderNumber> "SO-9" .
        } }"""
                )
                fs = run_rules(
                    ["$(RULES)PersonToEmployee", "$(RULES)AssignReview"];
                    source=[DATA_GRAPH],
                    actor="integration",
                )
                @test fs[1].rule == "$(RULES)AssignReview"     # priority 100 beats 0
                for f in reverse(fs)
                    undo_firing!(f.graph)
                end
            end

            @testset "every way of writing a broken set is refused" begin
                # Each of these would otherwise run a set that is not the one the author wrote,
                # and a cascade that silently drops a rule returns a plausible answer.
                for (name, fragment) in (
                    ("NoMembers", "has no members"),
                    ("MissingSequence", "has no gist:sequence"),
                    ("MissingTarget", "has no gist:providesOrderFor"),
                    ("OrdersANonRule", "is not typed jhp:Rule"),
                    ("FirstDisagrees", "states its order twice"),
                    ("Duplicated", "more than one position"),
                )
                    e = try
                        load_rule_set("$(SETS)$name")
                    catch err
                        err
                    end
                    @test e isa ErrorException
                    @test occursin(fragment, sprint(showerror, e))
                end
                # and a set that was never declared at all
                e = try
                    load_rule_set("$(SETS)NoSuchSet")
                catch err
                    err
                end
                @test occursin("no rule set found", sprint(showerror, e))
            end

            @testset "the MCP surface reports the order before it runs" begin
                # A set's whole content is its order, so a reviewer who cannot see the resolved
                # order has not reviewed anything. That is why it is printed rather than logged.
                out = tool_run_rules(
                    "$(SETS)HrThenParts"; source=[DATA_GRAPH], actor="mcp-test"
                )
                @test occursin("order resolved from gist:sequence", out)
                @test findfirst("PersonToEmployee", out).start <
                    findfirst("PartOfTransitive", out).start
                @test occursin("[Construct]", out)
                @test occursin("[Assert]", out)
                @test occursin("Undo in reverse order", out)
                for f in reverse(firings(; rule=nothing))
                    is_firing(f.graph) && undo_firing!(f.graph)
                end

                # A broken set is answered as text, not raised: an agent can act on the reason.
                bad = tool_run_rules("$(SETS)MissingSequence")
                @test occursin("not a runnable rule set", bad)
                @test occursin("has no gist:sequence", bad)

                cat = tool_list_rule_sets()
                @test occursin("People, then parts", cat)
                @test occursin("cannot be run", cat)        # the empty set is flagged, not hidden
            end

            @testset "list_rule_sets catalogues them with their sizes" begin
                cat = Dict(c.iri => c for c in list_rule_sets())
                @test cat["$(SETS)HrThenParts"].members == 2
                @test cat["$(SETS)HrThenParts"].label == "People, then parts"
                @test cat["$(SETS)NoMembers"].members == 0   # listed, though it cannot be run
            end

            Jayhawk.update!("DROP SILENT GRAPH <$DATA_GRAPH>")
            engine_cleanup()
        end

        Jayhawk.load_file!(fixture("scoped_rule.trig"))
        spec = load_rule("$(BKR)PerBook")

        @testset "the graph variable is discovered from the default graph" begin
            # jhp:inGraph is a statement ABOUT the pattern, so it lives in the default
            # graph and its object occupies no position inside any pattern. Without the
            # scope branch in _occurs_in it is never found, and the compiler emits
            # GRAPH <...:_Book> -- a constant naming a graph nobody created. The rule then
            # runs, matches nothing, and reports success.
            @test spec.match_scope == "$(BKR)_Book"
            @test spec.nacs[1].scope == "$(BKR)_Book"
            @test get(spec.variables, spec.match_scope, nothing) == "?_Book"
            # `from` is not decoration here: a scoped rule with no dataset clause is now
            # refused outright, because a graph variable would otherwise range over every
            # named graph in the store. It is also what makes the printed query the query
            # that runs -- see compile_rule.
            q = compile_rule(spec; from=[BKA, BKB])
            @test occursin("GRAPH ?_Book {", q)
            @test !occursin("GRAPH <$(BKR)_Book>", q)
            @test occursin("FROM <$BKA>", q) && occursin("FROM NAMED <$BKA>", q)
            @test_throws ErrorException compile_rule(spec)
        end

        @testset "the guard is scoped to its own book, not to all of them" begin
            fs = run_rule(spec; source=[BKA, BKB], actor="docs", strategy=:Once)
            held = Set(
                (sparql_text(r["s"]), sparql_text(r["o"])) for f in fs for
                r in select("SELECT ?s ?o WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
            )
            # s2 is Tagged in bookA and untagged in bookB, so it must be declined in A and
            # allowed in B. Nesting the guard inside L's GRAPH group loses exactly this row:
            # its ?_Book would be a fresh variable over every graph, making the guard read
            # "not tagged in ANY book".
            @test ("<$(BK)s2>", "<$BKB>") in held
            @test !(("<$(BK)s2>", "<$BKA>") in held)
            @test held == Set([
                ("<$(BK)s1>", "<$BKA>"), ("<$(BK)s2>", "<$BKB>"), ("<$(BK)s3>", "<$BKB>")
            ])
            for f in fs
                undo_firing!(f.graph)
            end
        end

        @testset "a scoped rule refuses what it cannot do safely" begin
            # Each of these is otherwise a silent wrong answer rather than a failure.
            # No source: a graph variable would range over every named graph in the store,
            # provenance and every tombstone included.
            @test_throws ArgumentError run_rule(spec; source=String[], strategy=:Once)
            # ToFixpoint: each round appends its firing graph to the working set, so round
            # two would bind that firing as a book.
            @test_throws ArgumentError run_rule(spec; source=[BKA], strategy=:ToFixpoint)
        end

        Jayhawk.update!("DROP SILENT GRAPH <$BKA> ; DROP SILENT GRAPH <$BKB>")
        engine_cleanup()
    end

    @testset "multi-pattern L: a join across graphs that share predicates" begin
        # The red, kept as a test: one unscoped pattern over both graphs cannot tell a left
        # owner from a right one, and pairs every owner with itself. The rule this round
        # makes loadable pairs exactly the one true pair.
        MR = "http://example.org/mmrules/"
        MM = "http://example.org/mm/"
        LEFT, RIGHT = "urn:jayhawk:mm-test:left", "urn:jayhawk:mm-test:right"
        engine_cleanup()
        Jayhawk.update!("DROP SILENT GRAPH <$LEFT> ; DROP SILENT GRAPH <$RIGHT>")
        Jayhawk.load_file!(fixture("multi_match_rule.trig"))
        derived(f) = Set(
            (sparql_text(r["s"]), sparql_text(r["p"]), sparql_text(r["o"])) for
            r in select("SELECT ?s ?p ?o WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
        )
        t(s, p, o) = ("<$MM$s>", "<$MM$p>", o isa String ? "<$MM$o>" : "<$(o[1])>")

        @testset "the two patterns load as two parts of one L" begin
            spec = load_rule("$(MR)Pair")
            @test length(spec.match_parts) == 2
            @test [p.scope for p in spec.match_parts] == [LEFT, RIGHT]
            @test length(spec.match) == 2
        end

        @testset "merged into one default graph, the workaround pairs owners with themselves" begin
            f = only(run_rule("$(MR)PairMerged"; source=[LEFT, RIGHT], actor="test"))
            @test length(derived(f)) == 6
            @test t("a1", "sharesWith", "a1") in derived(f)
            undo_firing!(f.graph)
        end

        @testset "scoped per pattern, it pairs exactly the one true pair" begin
            f = only(run_rule("$(MR)Pair"; source=[LEFT, RIGHT], actor="test"))
            @test derived(f) == Set([t("a1", "sharesWith", "b1")])
            undo_firing!(f.graph)
            @test isempty(select("SELECT * WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }"))
        end

        @testset "a graph variable on one part ranges; the constant part stays pinned" begin
            f = only(run_rule("$(MR)PairByGraph"; source=[LEFT, RIGHT], actor="test"))
            @test derived(f) == Set([
                t("a1", "sharesWith", "b1"),
                t("a1", "sharesWith", "a1"),       # ?_g = left binds the left owner too
                t("a2", "sharesWith", "a2"),
                t("b1", "seenIn", (RIGHT,)),
                t("a1", "seenIn", (LEFT,)),
                t("a2", "seenIn", (LEFT,)),
            ])
            undo_firing!(f.graph)
        end

        @testset "explain_rule shows each part and the graph it reads" begin
            out = tool_explain_rule("$(MR)Pair"; source=[LEFT, RIGHT])
            @test occursin("Pair_Left> (1 triples)  in graph <$LEFT>", out)
            @test occursin("Pair_Right> (1 triples)  in graph <$RIGHT>", out)
            @test occursin("would add 1 new triple", out)
        end

        @testset "several construct patterns are still refused" begin
            Jayhawk.update!("""
                INSERT DATA { <$(MR)Pair> <$(Jayhawk.P_CONSTRUCT)> <$(MR)Pair_R2> }""")
            err = try
                load_rule("$(MR)Pair")
                ""
            catch e
                sprint(showerror, e)
            end
            @test occursin("2 jhp:hasConstructPattern values", err)
        end

        Jayhawk.update!("DROP SILENT GRAPH <$LEFT> ; DROP SILENT GRAPH <$RIGHT>")
        engine_cleanup()
    end

    @testset "jhp:hasBinding: minting from a computed value" begin
        BR = "http://example.org/bindrules/"
        BD = "urn:jayhawk:bind-test"
        HOLD = "http://example.org/bind/holding/"
        engine_cleanup()
        Jayhawk.update!("DROP SILENT GRAPH <$BD>")
        Jayhawk.load_file!(fixture("binding_rule.trig"))

        @testset "four bindings load, and the store evaluates them in order" begin
            spec = load_rule("$(BR)MintHolding")
            @test length(spec.bindings) == 4
            @test [spec.variables[b.variable] for b in Jayhawk.ordered_bindings(spec)] ==
                ["?disc", "?symNorm", "?symKey", "?key"]
        end

        @testset "the minted IRIs are byte-exact: normalised, slugged, hashed" begin
            # MD5s computed outside SPARQL (`printf 10.5 | md5`), so this checks the store
            # evaluated the expression the rule declares, not merely that it evaluated one.
            f = only(run_rule("$(BR)MintHolding"; source=[BD], actor="test"))
            got = Set(
                (sparql_text(r["h"]), sparql_text(r["k"])) for r in select(
                    "SELECT ?h ?k WHERE { GRAPH <$(f.graph)> " *
                    "{ ?h <http://example.org/bind/symbolKey> ?k } }",
                )
            )
            @test got == Set([
                ("<$(HOLD)ABC_10b3adf4529649ecb009c579e7713c8e>", "\"ABC\""),
                ("<$(HOLD)XYZ_8f14e45fceea167a5a36dedd4bea2543>", "\"XYZ\""),
                ("<$(HOLD)Q-R_dd7f542392a4b31946826638316847cb>", "\"Q-R\""),
            ])
            undo_firing!(f.graph)
        end

        @testset "explain_rule shows each binding, in the order it runs" begin
            out = tool_explain_rule("$(BR)MintHolding"; source=[BD])
            @test occursin("bindings          : 4 computed value(s)", out)
            @test findfirst("?disc = MD5", out).start < findfirst("?key = CONCAT", out).start
        end

        @testset "a binding with no expression is refused at load" begin
            Jayhawk.update!("""
                INSERT DATA { <$(BR)MintHolding> <$(Jayhawk.P_HASBINDING)> <$(BR)Empty> .
                              <$(BR)Empty> <$(Jayhawk.P_BINDSVAR)> <$(BR)_key> . }""")
            err = try
                load_rule("$(BR)MintHolding")
                ""
            catch e
                sprint(showerror, e)
            end
            @test occursin("declares 0 jhp:bindText values", err)
        end

        Jayhawk.update!("DROP SILENT GRAPH <$BD>")
        engine_cleanup()
    end

    @testset "gistp:isMintedBy: two rules minting through one MintingFunction" begin
        MR = "http://example.org/mfrules/"
        MD = "urn:jayhawk:mf-test"
        FN = "http://example.org/mf/data/_MintingFunction_holding"
        GP = Jayhawk.GISTP_NS
        engine_cleanup()
        Jayhawk.update!("DROP SILENT GRAPH <$MD>")
        Jayhawk.load_file!(fixture("minting_function_rule.trig"))
        objects(f) = Set(
            sparql_text(r["s"]) for
            r in select("SELECT DISTINCT ?s WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
        )

        @testset "the function's namespace + localTemplate is the template" begin
            m = only(values(load_rule("$(MR)MintHolding").mints))
            @test m.template == "http://example.org/mf/data/_Holding_{sym}"
            @test m.minting_function == FN
        end

        @testset "both rules reach the same IRI for the same symbol" begin
            want = Set(["<http://example.org/mf/data/_Holding_$k>" for k in ("ABC", "XYZ")])
            a = only(run_rule("$(MR)MintHolding"; source=[MD], actor="test"))
            b = only(run_rule("$(MR)LabelHolding"; source=[MD], actor="test"))
            @test objects(a) == want && objects(b) == want
            undo_firing!(a.graph)
            undo_firing!(b.graph)
        end

        @testset "explain_rule says which function a template came from" begin
            out = tool_explain_rule("$(MR)MintHolding"; source=[MD])
            @test occursin("?_H = http://example.org/mf/data/_Holding_{sym}   (by <$FN>)", out)
        end

        refusal(rule) =
            try
                load_rule(rule)
                ""
            catch e
                sprint(showerror, e)
            end
        H = "$(MR)_H"
        @testset "what a minting function refuses" begin
            # both spellings on one variable: which IRI would be a guess
            Jayhawk.update!("INSERT DATA { <$H> <$(GP)iriTemplate> \"http://x/{sym}\" }")
            @test occursin("both carries a gistp:iriTemplate", refusal("$(MR)MintHolding"))
            Jayhawk.update!("DELETE DATA { <$H> <$(GP)iriTemplate> \"http://x/{sym}\" }")
            # a function missing its local part
            Jayhawk.update!("DELETE DATA { <$FN> <$(GP)localTemplate> \"_Holding_{sym}\" }")
            @test occursin("0 gistp:localTemplate values", refusal("$(MR)MintHolding"))
            Jayhawk.update!("INSERT DATA { <$FN> <$(GP)localTemplate> \"_Holding_{sym}\" }")
            # two namespaces would mint two IRIs for one binding
            Jayhawk.update!("INSERT DATA { <$FN> <$(GP)namespace> \"http://other/\" }")
            @test occursin("2 gistp:namespace values", refusal("$(MR)MintHolding"))
            Jayhawk.update!("DELETE DATA { <$FN> <$(GP)namespace> \"http://other/\" }")
            @test refusal("$(MR)MintHolding") == ""
        end

        @testset "two iriTemplates on one variable are refused, not picked between" begin
            # HEAD loaded this silently and minted from whichever template the store
            # returned first -- measured: the added one, not the one the rule was written with.
            Jayhawk.load_file!(example("02-mint-coupon-event.trig"))
            ev = "https://w3id.org/moneygraph/ns/rules/_Event"
            Jayhawk.update!("INSERT DATA { <$ev> <$(GP)iriTemplate> \"http://x/other/{bond}\" }")
            @test occursin("2 gistp:iriTemplate values",
                refusal("https://w3id.org/moneygraph/ns/rules/MintCouponEvent"))
        end

        Jayhawk.update!("DROP SILENT GRAPH <$MD>")
        engine_cleanup()
    end

    @testset "the fan-in report sees a slot fed by gistp:oneOf" begin
        # mint_fanin and collision_queries used to embed L and the mint's BIND and nothing
        # between, so a slot fed by VALUES was unbound in the check and the report was empty
        # by construction. Minting the check from the regulation alone makes every IRI
        # reachable from both widgets -- three real fan-ins, which HEAD reported as none.
        engine_cleanup()
        Jayhawk.load_file!(fixture("oneof_rule.trig"))
        OF = "urn:jayhawk:oneof-fanin"
        Jayhawk.update!("DROP SILENT GRAPH <$OF>")
        Jayhawk.update!("""INSERT DATA { GRAPH <$OF> {
          <urn:w1> a <http://example.org/ops/Widget> ; <http://example.org/ops/code> "W-1" .
          <urn:w2> a <http://example.org/ops/Widget> ; <http://example.org/ops/code> "W-2" . } }""")
        spec = load_rule("$(RULES)ComplianceChecks")
        chk = only(keys(spec.mints))
        m = spec.mints[chk]
        args = Any[getfield(spec, f) for f in fieldnames(RuleSpec)]
        args[findfirst(==(:mints), fieldnames(RuleSpec))] = Dict(
            chk => MintSpec(chk, "http://example.org/ops/check/{reg}", Dict("reg" => m.slots["reg"])),
        )
        fan = mint_fanin(RuleSpec(args...); from=[OF])
        @test length(fan) == 1
        @test Set(last(only(fan))) == Set([
            ("http://example.org/ops/check/$r", 2) for r in ("EU", "JP", "US")
        ])
        Jayhawk.update!("DROP SILENT GRAPH <$OF>")
        engine_cleanup()
    end

    @testset "the moneygraph worked examples" begin
        # Every figure in docs/user-guide.md comes from here. The guide quotes measured
        # output, so if a rule changes behaviour the documentation fails with the code
        # rather than quietly describing an engine that no longer exists.
        MGD = "urn:jayhawk:example:moneygraph"
        MGR = "https://w3id.org/moneygraph/ns/rules/"
        MG = "https://w3id.org/moneygraph/ns/ontology/"
        MG3 = "https://w3id.org/moneygraph/ns/data/"
        MGX = "https://w3id.org/moneygraph/ns/example/"

        engine_cleanup()
        Jayhawk.update!("DROP SILENT GRAPH <$MGD>")
        for f in sort(readdir(joinpath(@__DIR__, "..", "examples", "moneygraph")))
            endswith(f, ".trig") && Jayhawk.load_file!(example(f))
        end

        @testset "all four rules load and compile" begin
            @test length(list_rules()) == 4
            for r in ("ClassifyBond", "MintCouponEvent", "DomesticListing", "RetireListing")
                @test compile_from_store("$MGR$r") isa String
            end
        end

        @testset "1. classify: two instruments qualify as bonds" begin
            fs = run_rule("$(MGR)ClassifyBond"; source=[MGD], actor="docs")
            @test sum(f.count for f in fs) == 2
            bonds = Set(
                (r["s"]::IRIRef).value for f in fs for
                r in select("SELECT ?s WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
            )
            @test bonds == Set(["$(MG3)T4875", "$(MG3)IBM2029"])
            # AAPL has no coupon rate, so L never reaches it
            @test !any(occursin("AAPL", b) for b in bonds)
            # merge, so the minting rule downstream has bonds to see
            for f in fs
                Jayhawk.update!(
                    "INSERT { GRAPH <$MGD> { ?s ?p ?o } } WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }",
                )
            end
        end

        @testset "2. mint: one event, because the guard declines the other" begin
            fs = run_rule("$(MGR)MintCouponEvent"; source=[MGD], actor="docs")
            @test sum(f.count for f in fs) == 2       # one event, two triples about it
            minted = Set(
                (r["s"]::IRIRef).value for f in fs for
                r in select("SELECT DISTINCT ?s WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
            )
            @test minted == Set(["$(MG3)coupon/T4875"])
            # IBM2029 already had an event, so the negative condition refused the match --
            # not the pruning: the gist:isAbout triple would have been genuinely new.
            @test !any(occursin("IBM2029", m) for m in minted)
            @test length(fs) == 1                     # and the guard converges it in one round
            for f in fs
                undo_firing!(f.graph)
            end
        end

        @testset "3. oneOf constrains: only the enumerated exchanges" begin
            fs = run_rule("$(MGR)DomesticListing"; source=[MGD], actor="docs")
            listed = Set(
                (r["s"]::IRIRef).value for f in fs for
                r in select("SELECT ?s WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
            )
            @test listed == Set(["$(MG3)AAPL", "$(MG3)ENRN"])
            # NESN is on SIX, which is not in the enumeration
            @test !any(occursin("NESN", l) for l in listed)
            @test occursin("VALUES ?_Exch", compile_from_store("$(MGR)DomesticListing"))
            for f in fs
                undo_firing!(f.graph)
            end
        end

        @testset "4. rewrite: one triple out, one in, undo exact" begin
            snap() = Set(
                (sparql_text(r["s"]), sparql_text(r["p"]), sparql_text(r["o"])) for
                r in select("SELECT ?s ?p ?o WHERE { GRAPH <$MGD> { ?s ?p ?o } }")
            )
            before = snap()
            spec = load_rule("$(MGR)RetireListing")
            @test length(interface(spec)) == 2        # type and delisting date preserved
            @test length(match_only(spec)) == 1
            @test length(construct_only(spec)) == 1
            @test isempty(dangling_risks(spec))       # R still mentions the exchange

            f = run_rule("$(MGR)RetireListing"; source=[MGD], actor="docs")[1]
            @test f.count == 1 && f.removed == 1
            now = snap()
            @test ("<$(MG3)ENRN>", "<$(MG)isListedOn>", "<$(MG3)NYSE>") in
                setdiff(before, now)
            @test ("<$(MG3)ENRN>", "<$(MGX)formerlyListedOn>", "<$(MG3)NYSE>") in
                setdiff(now, before)
            # the delisting date and the type survived, because R repeats them
            @test (
                "<$(MG3)ENRN>",
                "<$(MGX)delistedOn>",
                "\"2001-11-28\"^^<http://www.w3.org/2001/XMLSchema#date>",
            ) in now

            undo_firing!(f.graph)
            @test snap() == before
        end

        Jayhawk.update!("DROP SILENT GRAPH <$MGD>")
        engine_cleanup()
    end

    @testset "bondfix: the oracle reproduces its golden" begin
        # examples/moneygraph/bondfix/ re-expresses moneygraph's fix-missing-bond-data.rq as
        # a rule set. Before any rule exists, this pins down what "the same effect" means:
        # the oracle (the committed query with its currency cross-product fixed) run over
        # the fixture must write exactly expected.nq. The rule set will be held to the same
        # golden by the same comparison.
        MG3 = "https://w3id.org/moneygraph/ns/data/"
        SEC, ACT = "$(MG3)__securities__extra", "$(MG3)__activities__extra"
        XSEC = "urn:jayhawk:example:bondfix:expected:securities"
        XACT = "urn:jayhawk:example:bondfix:expected:activities"
        INPUTS = ["$(MG3)__trades-bonds__", "$(MG3)__current__", "$(MG3)__units__"]
        drop_all() = Jayhawk.update!(
            join(("DROP SILENT GRAPH <$g>" for g in [INPUTS; SEC; ACT; XSEC; XACT]), " ; "),
        )
        quads(g) = Set(
            (sparql_text(r["s"]), sparql_text(r["p"]), sparql_text(r["o"])) for
            r in select("SELECT ?s ?p ?o WHERE { GRAPH <$g> { ?s ?p ?o } }")
        )

        drop_all()
        Jayhawk.load_file!(example("bondfix/data.trig"))
        Jayhawk.load_file!(example("bondfix/expected.nq"))
        Jayhawk.update!(read(example("bondfix/oracle.rq"), String))

        # compared as two differences, so a failure names the offending triples only
        @test isempty(setdiff(quads(SEC), quads(XSEC)))     # nothing the golden lacks
        @test isempty(setdiff(quads(XSEC), quads(SEC)))     # nothing the golden has, missed
        @test isempty(setdiff(quads(ACT), quads(XACT)))
        @test isempty(setdiff(quads(XACT), quads(ACT)))
        # and the golden is not vacuous: both decoys are absent, every real match is present
        @test length(quads(XSEC)) == 43 && length(quads(XACT)) == 35
        subjects = join(first.(collect(quads(SEC))), " ")
        @test !occursin("5CQRSE4", subjects)    # C: gross off by a cent
        @test !occursin("5DRBCF2", subjects)    # D: description never names the issuer
        @test all(occursin(k, subjects) for k in ("5DDZBS0", "5CPNON8", "037833DX5"))

        drop_all()
    end

    @testset "bondfix: the rule set reproduces the oracle, quad for quad" begin
        # moneygraph's fix-missing-bond-data.rq as eight rules (examples/moneygraph/bondfix/
        # rules.trig), held to the same golden the oracle is held to above.
        MG3 = "https://w3id.org/moneygraph/ns/data/"
        BF = "https://w3id.org/moneygraph/ns/rules/bondfix/"
        T, C, U = "$(MG3)__trades-bonds__", "$(MG3)__current__", "$(MG3)__units__"
        W = "urn:jayhawk:example:bondfix:work"
        SEC, ACT = "$(MG3)__securities__extra", "$(MG3)__activities__extra"
        XSEC = "urn:jayhawk:example:bondfix:expected:securities"
        XACT = "urn:jayhawk:example:bondfix:expected:activities"
        drop_all() = Jayhawk.update!(
            join(("DROP SILENT GRAPH <$g>" for g in (T, C, U, W, SEC, ACT, XSEC, XACT)), " ; "),
        )
        quads(g) = Set(
            (sparql_text(r["s"]), sparql_text(r["p"]), sparql_text(r["o"])) for
            r in select("SELECT ?s ?p ?o WHERE { GRAPH <$g> { ?s ?p ?o } }")
        )
        engine_cleanup()
        drop_all()
        for f in ("data.trig", "expected.nq", "rules.trig")
            Jayhawk.load_file!(example("bondfix/$f"))
        end
        inputs = Dict(g => quads(g) for g in (T, C, U))
        source = [T, C, U, W]

        fs = run_rules("$(BF)BondFix"; source=source, actor="bondfix")

        @testset "eight rules, in the declared order, each to its own destination" begin
            @test [split(f.rule, "/")[end] for f in fs] == [
                "MatchTradeToHolding", "ListingAndIssuer", "Callable", "CouponTerms",
                "CouponMonths", "FirstCouponEvent", "InterestDaysPaid", "YieldToMaturity",
            ]
            @test fs[1].target == W && fs[1].count == 36      # four matches, nine facts each
            @test all(f.target == SEC for f in fs[2:6])
            @test all(f.target == ACT for f in fs[7:8])
        end

        @testset "the output is the oracle's" begin
            @test isempty(setdiff(quads(SEC), quads(XSEC)))
            @test isempty(setdiff(quads(XSEC), quads(SEC)))
            @test isempty(setdiff(quads(ACT), quads(XACT)))
            @test isempty(setdiff(quads(XACT), quads(ACT)))
        end

        @testset "a second run adds nothing" begin
            @test isempty(run_rules("$(BF)BondFix"; source=source, actor="bondfix"))
        end

        @testset "undo is exact: outputs gone, inputs untouched" begin
            for f in reverse(fs)
                undo_firing!(f.graph)
            end
            @test Jayhawk.graph_size(SEC) == 0
            @test Jayhawk.graph_size(ACT) == 0
            @test Jayhawk.graph_size(W) == 0
            @test all(quads(g) == inputs[g] for g in (T, C, U))
        end

        drop_all()
        engine_cleanup()
    end

    @testset "bondfix: rerun_rules! replaces the last run" begin
        # The rule-set counterpart of the shell script's DROP SILENT GRAPH. When an input
        # changes, running the set again only ADDS, so what the old input derived stays: the
        # red, measured -- A2's activity gross changed so it no longer matches, and a plain
        # second run left 15 stale triples the oracle (run on the changed data) does not write.
        MG3 = "https://w3id.org/moneygraph/ns/data/"
        BF = "https://w3id.org/moneygraph/ns/rules/bondfix/"
        GI = "https://w3id.org/semanticarts/ns/ontology/gist/"
        T, C, U = "$(MG3)__trades-bonds__", "$(MG3)__current__", "$(MG3)__units__"
        W = "urn:jayhawk:example:bondfix:work"
        SEC, ACT = "$(MG3)__securities__extra", "$(MG3)__activities__extra"
        OSEC, OACT = "urn:jayhawk:rerun-test:oracle:sec", "urn:jayhawk:rerun-test:oracle:act"
        SET = "$(BF)BondFix"
        drop_all() = Jayhawk.update!(
            join(("DROP SILENT GRAPH <$g>" for g in (T, C, U, W, SEC, ACT, OSEC, OACT)), " ; "),
        )
        quads(g) = Set(
            (sparql_text(r["s"]), sparql_text(r["p"]), sparql_text(r["o"])) for
            r in select("SELECT ?s ?p ?o WHERE { GRAPH <$g> { ?s ?p ?o } }")
        )
        engine_cleanup()
        drop_all()
        for f in ("data.trig", "rules.trig")
            Jayhawk.load_file!(example("bondfix/$f"))
        end
        source = [T, C, U, W]

        first = run_rules(SET; source=source, actor="rerun-test")

        @testset "a set's firings record the set; a member run alone does not" begin
            recorded = firings(; rule_set=SET)
            @test Set(f.graph for f in recorded) == Set(f.graph for f in first)
            @test all(f.rule_set == SET for f in recorded)
            # Callable, run on its own with the work graph already filled: a firing, but
            # not the set's -- so a rerun of the set must leave it alone. (Its fact is
            # already in __securities__extra, so point it at nothing new: undo the set's
            # Callable firing first, then run the rule alone.)
            undo_firing!(only(f for f in first if endswith(f.rule, "/Callable")).graph)
            alone = only(run_rule("$(BF)Callable"; source=source, actor="rerun-test"))
            @test only(f for f in firings() if f.graph == alone.graph).rule_set == ""
            undo_firing!(alone.graph)
        end

        # The input changes: A2's purchase no longer matches its trade.
        A2 = "$(MG3)_Event:51590610:5DDZBS0:buy:2025-06-02:CAD:-"
        GROSS = "$(MG3)_Magnitude:securityTradeGrossAmount:cad:4756"
        Jayhawk.update!("""
            DELETE DATA { GRAPH <$C> { <$A2> <$(GI)hasMagnitude> <$(GROSS).0> } } ;
            INSERT DATA { GRAPH <$C> { <$A2> <$(GI)hasMagnitude> <$(GROSS).5> .
              <$(GROSS).5> <$(GI)hasAspect> <https://w3id.org/moneygraph/ns/taxonomy/_Aspect_securityTradeGrossAmount> ;
                           <$(GI)numericValue> 4756.5 . } }""")

        # What the oracle writes over the CHANGED data, set aside in graphs of its own.
        held = (quads(SEC), quads(ACT))
        Jayhawk.update!("DROP SILENT GRAPH <$SEC> ; DROP SILENT GRAPH <$ACT>")
        Jayhawk.update!(read(example("bondfix/oracle.rq"), String))
        Jayhawk.update!("""
            INSERT { GRAPH <$OSEC> { ?s ?p ?o } } WHERE { GRAPH <$SEC> { ?s ?p ?o } } ;
            INSERT { GRAPH <$OACT> { ?s ?p ?o } } WHERE { GRAPH <$ACT> { ?s ?p ?o } } ;
            DROP GRAPH <$SEC> ; DROP GRAPH <$ACT>""")
        for (g, ts) in zip((SEC, ACT), held)          # and the rules' earlier output back
            Jayhawk.update!("INSERT DATA { GRAPH <$g> { " *
                            join(("$(t[1]) $(t[2]) $(t[3]) ." for t in ts), " ") * " } }")
        end

        @testset "refused before anything is undone" begin
            before = length(firings(; rule_set=SET))
            @test_throws ArgumentError rerun_rules!(SET; source=String[], actor="rerun-test")
            @test length(firings(; rule_set=SET)) == before     # nothing was undone
        end

        @testset "the MCP tool asks before replacing" begin
            out = tool_run_rules(SET; source=source, replace=true)
            @test occursin("Refused: replacing the last run", out)
            @test occursin("undoes the 7 firing(s)", out)     # Callable was undone above
        end

        r = rerun_rules!(SET; source=source, actor="rerun-test")

        @testset "the replacement reflects the changed input, nothing stale" begin
            @test length(r.undone) == 7
            @test isempty(setdiff(quads(SEC), quads(OSEC)))
            @test isempty(setdiff(quads(OSEC), quads(SEC)))
            @test isempty(setdiff(quads(ACT), quads(OACT)))
            @test isempty(setdiff(quads(OACT), quads(ACT)))
            @test !any(occursin("2025-09-22", t[1]) for t in quads(SEC))   # A2's event is gone
        end

        @testset "and the MCP tool does the same, once confirmed" begin
            out = tool_run_rules(SET; source=source, replace=true, confirm=true)
            @test occursin("Replaced the last run: undid 8 firing(s)", out)
            @test quads(SEC) == quads(OSEC) && quads(ACT) == quads(OACT)
        end

        drop_all()
        engine_cleanup()
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
            out = tool_explain_rule(rule; source=[DATA_GRAPH])
            @test occursin("CONSTRUCT {", out)                 # the query, for the curious
            @test occursin("would add 2 new triple(s)", out)   # and what it actually does
            @test occursin("\"E-4471\"", out)                  # the literal it would create
            @test occursin("Nothing was written", out)
        end

        @testset "explain_rule writes nothing" begin
            before = length(firings())
            tool_explain_rule(rule; source=[DATA_GRAPH])
            tool_explain_rule(rule; source=[DATA_GRAPH])
            @test length(firings()) == before
            @test graph_size(DATA_GRAPH) == 4                  # source untouched
        end

        @testset "run_rule then undo_firing round-trips" begin
            out = tool_run_rule(rule; source=[DATA_GRAPH], actor="agent-7")
            @test occursin("added 2 triple(s)", out)

            log = firings(rule=rule)
            @test length(log) == 1
            @test log[1].actor == "agent-7"

            @test occursin("agent-7", tool_firings(rule=rule))

            undone = tool_undo_firing(log[1].graph)
            @test occursin("2 triple(s) removed", undone)
            @test isempty(firings(rule=rule))
            @test graph_size(DATA_GRAPH) == 4                  # source still untouched

            # undoing twice is harmless, not an error
            @test occursin("nothing to undo", tool_undo_firing(log[1].graph))
        end

        @testset "a second identical run derives nothing new" begin
            # Construct against an unchanged source is idempotent once its output is in the
            # working set -- prune_known! is what makes that visible.
            f1 = run_rule(rule; source=[DATA_GRAPH])
            recorded = length(firings())
            f2 = run_rule(rule; source=[DATA_GRAPH, f1[1].graph])
            @test f1[1].count == 2
            @test all(is_firing(f.graph) for f in f1)   # every firing handed back is undoable
            # A Once rule that changes nothing used to hand back a firing whose graph it had
            # already dropped and never recorded, which undo_firing! then refused.
            @test isempty(f2)
            @test length(firings()) == recorded
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
