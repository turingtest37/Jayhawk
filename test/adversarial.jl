# Adversarial test suite for the Function-Graph engine.
#
#   julia --project=. test/adversarial.jl                        # hermetic part only
#   JAYHAWK_TEST_SPARQL=1 julia --project=. test/adversarial.jl   # + store-backed part
#
# This file is deliberately RED. Every assertion here states what the engine *should* do;
# the ones that fail are bugs, not flaky tests. It is kept out of runtests.jl so the
# existing green suite stays green and this stays a to-do list you can watch shrink.
#
# Each testset opens with a severity tag and, where it was reproduced against a live
# Fuseki, the observed behaviour. Tags:
#
#   [PROVEN]  reproduced; the assertion below fails today
#   [PIN]     current behaviour is defensible but undocumented/unasserted -- pin it so a
#             change is a decision rather than a surprise
#
# The existing suite is strong on "does this rule compile to the bytes I expect".  It is
# thin on three things, which is where nearly everything below lives:
#
#   1. more than one rule in the store at a time,
#   2. hostile or merely sloppy *input* rather than hand-built well-formed RuleSpecs,
#   3. the harness's own semantics checked against an independent oracle rather than
#      against a hand-counted expectation.

using Test
using Jayhawk

const G    = "https://w3id.org/semanticarts/ns/ontology/gist/"
const HR   = "http://example.org/hr/"
const R    = "http://example.org/rules/"
const TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

iri(s) = IRIRef(s)
var(s) = RDFLiteral(s, Jayhawk.GISTP_VAR)

fixture(n) = joinpath(@__DIR__, "fixtures", n)
const TC     = "http://example.org/tc/"
const TCRULE = "http://example.org/tcrules/PartOfTransitive"
const DATA   = "urn:jayhawk:adv-data"

"Wipe the dataset. The store-backed tests own the dataset outright -- run them against\nbin/fuseki-test.sh, never against anything you care about."
reset_store!() = Jayhawk.update!("DROP ALL")

load_chain!(g, n) = Jayhawk.update!("INSERT DATA { GRAPH <$g> {" *
    join(("<$(TC)n$i> <$(TC)partOf> <$(TC)n$(i+1)> ." for i in 1:n-1), "\n") * "} }")

"A minimal well-formed spec, with hooks to corrupt one thing at a time."
function spec1(; match = nothing, construct = nothing, variables = nothing, mints = nothing,
                 mode = Jayhawk.MODE_CONSTRUCT)
    RuleSpec("$(R)T", mode, "$(R)T_L", "$(R)T_R",
        match     === nothing ? [PatternTriple(iri("$(R)_v"), iri(TYPE), iri("$(HR)In"))]  : match,
        construct === nothing ? [PatternTriple(iri("$(R)_v"), iri(TYPE), iri("$(HR)Out"))] : construct,
        variables === nothing ? Dict("$(R)_v" => "?v") : variables,
        mints     === nothing ? Dict{String,MintSpec}() : mints)
end

@testset "Jayhawk adversarial suite" begin

# ===========================================================================
# 1. Untrusted input reaching the emitted SPARQL
# ===========================================================================
#
# The engine's stated contract is that rules are *safer* than an UPDATE endpoint, because
# every rule is a named, validated, reversible rewrite. That contract only holds if the
# rule document itself cannot become arbitrary SPARQL. Today it can.

@testset "1. variableText is untrusted input" begin

    @testset "[PROVEN] a variableText that is not a SPARQL variable is refused" begin
        # var_of() returns spec.variables[iri] verbatim and term_sparql() splices it
        # straight into the query. Literal-position variables go through var_name(),
        # which validates against VARIABLE_RE; IRI-position variables are validated
        # nowhere. The two mechanisms must be equally strict.
        #
        # Observed: compiles to `person <...#type> <...Out> .` -- a SPARQL syntax error
        # that surfaces as an opaque HTTP 400 from the store at apply time.
        @test_throws Exception compile_rule(spec1(variables = Dict("$(R)_v" => "person")))
        @test_throws Exception compile_rule(spec1(variables = Dict("$(R)_v" => "")))
        @test_throws Exception compile_rule(spec1(variables = Dict("$(R)_v" => "?has space")))
        @test_throws Exception compile_rule(spec1(variables = Dict("$(R)_v" => "?a-b")))
    end

    @testset "[PROVEN] variableText cannot inject SPARQL" begin
        # Reproduced. A rule author (or an LLM authoring a rule, which is the stated use
        # case) writes:
        #
        #   :_v gistp:variableText "?v } INSERT { GRAPH <urn:pwned> { ... } } WHERE { ?v" .
        #
        # and compile_rule emits it verbatim into both the CONSTRUCT and the WHERE. Under
        # insert_query -- which apply_rule sends to the *update* endpoint -- that closes
        # the engine's INSERT and opens the author's. Provenance records a rule firing;
        # the store gets an unrelated write, in a graph no Firing names, that undo cannot
        # reverse.
        payload = "?v } INSERT { GRAPH <urn:pwned> { <urn:a> <urn:b> <urn:c> } } WHERE { ?v"
        s = spec1(variables = Dict("$(R)_v" => payload))
        @test_throws Exception compile_rule(s)
        @test_throws Exception insert_query(s; into = "urn:x")

        # Belt and braces: even if validation is added upstream, no emitted query should
        # ever contain a brace that did not come from the compiler's own template.
        q = try insert_query(s; into = "urn:x") catch; "" end
        @test !occursin("urn:pwned", q)
    end

    @testset "[PIN] the same validation as literal-position variables" begin
        # This already holds, and is the behaviour the IRI-position path should match.
        bad = spec1(match = [PatternTriple(iri("$(R)_v"), iri("$(HR)p"), var("not a var"))])
        @test_throws ArgumentError compile_rule(bad)
    end
end

@testset "2. terms that cannot legally occupy their position" begin

    @testset "[PROVEN] a literal in subject position of R is refused" begin
        # Emits `"I am a literal" <...> ?v .` inside CONSTRUCT: a syntax error the store
        # rejects with an HTTP 400 the compiler could have caught for free.
        s = spec1(construct = [PatternTriple(RDFLiteral("I am a literal"), iri(TYPE), iri("$(R)_v"))])
        @test_throws Exception compile_rule(s)
    end

    @testset "[PROVEN] a literal in predicate position is refused" begin
        s = spec1(match = [PatternTriple(iri("$(R)_v"), RDFLiteral("not a predicate"), iri("$(HR)In"))])
        @test_throws Exception compile_rule(s)
    end

    @testset "[PROVEN] blank nodes are not silently reinterpreted across L and R" begin
        # A blank node in L is an existential (a non-selectable variable); the *same
        # label* in R is a request to mint a fresh node per solution. So `_:b0` in both
        # does NOT mean "preserve the matched node" -- but "I is authored by repetition"
        # (CLAUDE-about.md) tells an author that repeating a term is exactly how you
        # preserve it. The compiler must not accept a reading it does not implement.
        #
        # Either refuse a shared bnode label, or refuse bnodes in R outright. Both are
        # defensible; silently emitting them is not.
        s = spec1(
            match = [PatternTriple(iri("$(R)_v"), iri("$(HR)p"), BNode("b0")),
                     PatternTriple(BNode("b0"), iri(TYPE), iri("$(HR)In"))],
            construct = [PatternTriple(BNode("b0"), iri(TYPE), iri("$(HR)Out"))])
        @test_throws Exception compile_rule(s)
    end

    @testset "[PROVEN] check_iri rejects the empty and relative IRI" begin
        # `IRIRef("")` emits `<>`, which SPARQL resolves against the request base -- a
        # different IRI on every store, and never the one the author meant. Likewise
        # `<../relative>`. check_iri's whole job is "an IRI that cannot be emitted safely",
        # and these cannot.
        @test_throws ArgumentError check_iri("")
        @test_throws ArgumentError check_iri("../relative")
        @test_throws ArgumentError check_iri("not-an-iri")
        @test check_iri("urn:ok") == "urn:ok"                 # must still pass
        @test check_iri("http://ex.org/ok") == "http://ex.org/ok"
    end
end

# ===========================================================================
# 3. The compiler's purity and stability claims
# ===========================================================================

@testset "3. compile_rule's stated contract" begin

    @testset "[PROVEN] a template with no slots: decide, then assert it" begin
        # load_mints' docstring says: "A variable with a template but no slots comes back
        # with an empty `slots`, which check_mints then rejects". It does not -- `wanted`
        # and `given` are both empty, every check passes, and it compiles to
        # `BIND(IRI(CONCAT("http://ex.org/fixed")) AS ?m)`: every match mints the SAME
        # node, so an Assert rule collapses every solution onto one IRI.
        #
        # That is a plausible thing to want (a singleton) and a very implausible thing to
        # write by accident. Pick one. This asserts the docstring.
        s = spec1(construct = [PatternTriple(iri("$(R)_m"), iri(TYPE), iri("$(HR)Out"))],
                  variables = Dict("$(R)_v" => "?v", "$(R)_m" => "?m"),
                  mints = Dict("$(R)_m" => MintSpec("$(R)_m", "http://ex.org/fixed",
                                                    Dict{String,RDFTerm}())))
        @test_throws Exception compile_rule(s)
    end

    @testset "[PROVEN] 'same spec, same bytes' is order-independent" begin
        # compile_rule's docstring: "Pure: same spec, same bytes". It is pure in the
        # Julia sense, but two RuleSpecs that are the same *set* of triples in a
        # different order compile to different bytes -- the sort lives in load_pattern,
        # not in the compiler. runtests.jl's golden test works around this by sorting the
        # spec by hand before comparing, which is the tell.
        #
        # Sorting belongs in compile_rule (or bgp_text), so the guarantee holds for every
        # RuleSpec however it was built -- including specs an MCP client hands in.
        ts = [PatternTriple(iri("$(R)_v"), iri(TYPE), iri("$(HR)In")),
              PatternTriple(iri("$(R)_v"), iri("$(HR)p"), iri("$(HR)q"))]
        @test compile_rule(spec1(match = ts)) == compile_rule(spec1(match = reverse(ts)))
    end

    @testset "[PIN] parse_template loses nothing" begin
        # Round-trip property: reassembling the parse must reproduce the input exactly.
        for t in ("http://ex.org/e/{id}", "http://ex.org/{a}/x/{b}", "http://ex.org/plain",
                  "urn:x:{a}{b}", "http://ex.org/{a}trailing")
            rebuilt = join(k === :lit ? v : "{$v}" for (k, v) in parse_template(t))
            @test rebuilt == t
        end
    end

    @testset "[PIN] template pieces are escaped into the CONCAT" begin
        # A template literal containing a quote or a backslash must not break out of the
        # SPARQL string. escape_literal handles it; assert it, because this string is the
        # one piece of author-supplied text that legitimately reaches the query.
        s = spec1(construct = [PatternTriple(iri("$(R)_m"), iri(TYPE), iri("$(HR)Out"))],
                  variables = Dict("$(R)_v" => "?v", "$(R)_m" => "?m"),
                  mints = Dict("$(R)_m" => MintSpec("$(R)_m", "http://ex.org/\"a\\b/{id}",
                                                    Dict{String,RDFTerm}("id" => iri("$(R)_v")))))
        q = compile_rule(s)
        # the literal piece is emitted as a complete, correctly escaped SPARQL string
        @test occursin("\"http://ex.org/\\\"a\\\\b/\"", q)
        # and it really is one well-formed STRING_LITERAL2, not two strings with the
        # author's text loose between them
        @test occursin(r"CONCAT\(\"(?:[^\"\\]|\\.)*\", ENCODE_FOR_URI", q)
    end

    @testset "[PIN] every variable used in CONSTRUCT appears in WHERE" begin
        # Metamorphic invariant over any spec that compiles at all. Cheap, and it catches
        # a whole class of future regressions in check_bound / binds_text.
        q = compile_rule(spec1())
        cons, where = split(q, "WHERE {")
        for v in [m.match for m in eachmatch(r"\?[A-Za-z_][A-Za-z0-9_]*", cons)]
            @test occursin(v, where)
        end
    end
end

# ===========================================================================
# 3b. gistp:Rewrite -- the pure half
# ===========================================================================
#
# Round 2 turned on the one mode that takes facts away. The set arithmetic behind it is
# right, and the reversibility design (tombstone written by the same atomic update) is the
# correct shape. These are the two places where the *pure* half of it can be wrong.

@testset "3b. Rewrite: what the compiler will emit" begin

    rewrite_spec(; match, construct, variables) = RuleSpec(
        "$(R)RW", Jayhawk.MODE_REWRITE, "$(R)RW_L", "$(R)RW_R",
        match, construct, variables, Dict{String,MintSpec}())

    @testset "[PROVEN] variableText must be unique within a rule" begin
        # `interface` is a set intersection over pattern triples keyed by `sparql_text`, so
        # two triples are "the same" when they are the same *RDF* triple -- variable
        # identity is IRI identity. The commit message makes this the load-bearing claim:
        # "two pattern triples denote the same thing exactly when they are the same RDF
        # triple. No unification, no alpha-equivalence."
        #
        # That holds only while the variable IRI -> variableText map is injective, and
        # nothing checks that it is. Give two distinct SparqlVariable individuals the same
        # variableText and the authored interface (by IRI) and the executed interface (by
        # SPARQL variable name) are different sets.
        #
        # Observed: I = 0 triples, so L\I deletes one triple and R\I adds one -- and the
        # emitted DELETE and INSERT templates are character-for-character identical. The
        # rule reports "removed 1, added 1" for what the store executes as a no-op. For the
        # additive modes the same duplication is merely redundant; here it corrupts the
        # interface, which is the whole basis of the mode.
        s = rewrite_spec(
            match     = [PatternTriple(iri("$(R)_a"), iri("urn:p"), iri("urn:o"))],
            construct = [PatternTriple(iri("$(R)_b"), iri("urn:p"), iri("urn:o"))],
            variables = Dict("$(R)_a" => "?x", "$(R)_b" => "?x"))
        @test_throws Exception compile_rule(s)

        # the same duplication is worth refusing on the additive path too, for the same
        # reason: two individuals that render as one variable are not two variables
        @test_throws Exception compile_rule(RuleSpec(
            "$(R)DupC", Jayhawk.MODE_CONSTRUCT, "$(R)L", "$(R)R",
            [PatternTriple(iri("$(R)_a"), iri("urn:p"), iri("urn:o"))],
            [PatternTriple(iri("$(R)_b"), iri("urn:p"), iri("urn:o"))],
            Dict("$(R)_a" => "?x", "$(R)_b" => "?x"), Dict{String,MintSpec}()))
    end

    @testset "[PROVEN] a blank node in L∖I cannot be emitted in a DELETE" begin
        # SPARQL 1.1 Update forbids blank nodes in a DELETE template outright. Fuseki:
        #   HTTP 400 ... Blank nodes not allowed in DELETE templates: _:b0
        #
        # This is the blank-node hole from testset 2 turning into a hard failure: on the
        # additive path a stray bnode is silently the wrong semantics, but under Rewrite it
        # is a query the store will not parse, discovered only at apply time.
        s = rewrite_spec(
            match     = [PatternTriple(iri("$(R)_p"), iri("urn:has"), BNode("b0")),
                         PatternTriple(BNode("b0"), iri(TYPE), iri("urn:Thing"))],
            construct = [PatternTriple(iri("$(R)_p"), iri(TYPE), iri("urn:Flat"))],
            variables = Dict("$(R)_p" => "?p"))
        @test_throws Exception compile_rule(s)
    end

    @testset "[PIN] the set arithmetic itself" begin
        # I / L∖I / R∖I are the whole mode. Pin them, including the literal-position
        # variable case -- "?t"^^gistp:var is one RDF term wherever it appears, so it
        # intersects correctly, and that is worth an assertion rather than a comment.
        keep = PatternTriple(iri("$(R)_p"), iri(TYPE), iri("urn:Person"))
        drop = PatternTriple(iri("$(R)_p"), iri("urn:idBy"), iri("$(R)_i"))
        add  = PatternTriple(iri("$(R)_p"), iri("urn:num"), var("?t"))
        shared_lit = PatternTriple(iri("$(R)_i"), iri("urn:text"), var("?t"))
        s = rewrite_spec(match = [keep, drop, shared_lit],
                         construct = [keep, add],
                         variables = Dict("$(R)_p" => "?p", "$(R)_i" => "?i"))
        @test length(interface(s)) == 1
        @test length(match_only(s)) == 2
        @test length(construct_only(s)) == 1
        # I ⊎ (L∖I) partitions L, and I ⊎ (R∖I) partitions R -- no triple is lost or doubled
        @test length(interface(s)) + length(match_only(s)) == length(s.match)
        @test length(interface(s)) + length(construct_only(s)) == length(s.construct)
        # ?i loses every triple the pattern knows about and R never mentions it
        @test "?i" in dangling_risks(s)
        @test !("?p" in dangling_risks(s))
    end
end

# ===========================================================================
# 4. Store-backed: everything below needs a live Fuseki
# ===========================================================================

if haskey(ENV, "JAYHAWK_TEST_SPARQL")

# --- 4a. The one that matters most -------------------------------------------------
#
# load_variables() and load_mints() take no rule argument. They SELECT every
# gistp:SparqlVariable in the *whole store* and staple the lot onto whichever RuleSpec is
# being built. A catalogue of rules -- which is the entire premise of mcp.jl -- is exactly
# the configuration that breaks.

@testset "4a. rules are isolated from one another" begin
    reset_store!()
    Jayhawk.load_file!(fixture("minting_rule.trig"))
    Jayhawk.load_file!(fixture("transitive_rule.trig"))
    Jayhawk.load_file!(fixture("person_to_employee.trig"))

    @testset "[PROVEN] a spec holds only its own rule's variables" begin
        # Observed: load_rule("...PersonToEmployee").variables has six entries -- its own
        # two, the minting rule's three, and all three of the transitive rule's.
        s = load_rule("$(R)PersonToEmployee")
        @test Set(keys(s.variables)) == Set(["$(R)_Person_1", "$(R)_ID_1"])
        @test isempty(s.mints)

        t = load_rule(TCRULE)
        @test Set(keys(t.variables)) ==
              Set(["http://example.org/tcrules/_a", "http://example.org/tcrules/_b",
                   "http://example.org/tcrules/_c"])
        @test isempty(t.mints)

        m = load_rule("$(R)PersonToEmployeeRecord")
        @test Set(keys(m.mints)) == Set(["$(R)_Employee_1"])
    end

    @testset "[PROVEN] a rule that mints nothing compiles next to one that does" begin
        # Observed:
        #   ERROR: rule <.../PartOfTransitive>: slot {id} of <.../_Employee_1> is bound to
        #   ?idText, which the match pattern never binds.
        #
        # check_mints walks spec.mints -- i.e. every mint in the store -- and validates it
        # against *this* rule's match pattern. One minting rule anywhere in the dataset
        # makes every non-minting rule uncompilable. The existing integration suite misses
        # it only because it loads the minting fixture last.
        q = try compile_from_store(TCRULE) catch e; sprint(showerror, e) end
        @test occursin("CONSTRUCT {", q)
        @test !occursin("_Employee_1", q)
        @test !occursin("BIND", q)          # this rule mints nothing
    end

    @testset "[PROVEN] no rule's query carries another rule's BIND" begin
        # PersonToEmployee's L happens to bind ?idText, so check_mints passes and the
        # foreign BIND is emitted silently instead of erroring. That is worse: the query
        # runs, the result looks right, and the rule is not the rule that was reviewed.
        q = compile_from_store("$(R)PersonToEmployee")
        @test !occursin("_Employee_1", q)
        @test !occursin("BIND", q)
    end

    @testset "[PROVEN] two minting rules coexist" begin
        # Neither may see the other's template, and two BINDs must never target the same
        # SPARQL variable (a store rejects `BIND(... AS ?x)` when ?x is already bound).
        Jayhawk.update!("""
            INSERT DATA {
              <urn:r2:Rule> a <$(Jayhawk.C_RULE)> ;
                  <$(Jayhawk.P_MATCH)> <urn:r2:L> ; <$(Jayhawk.P_CONSTRUCT)> <urn:r2:R> ;
                  <$(Jayhawk.P_MODE)> <$(Jayhawk.MODE_CONSTRUCT)> .
              <urn:r2:src>  a <$(Jayhawk.C_SPARQLVAR)> ; <$(Jayhawk.P_VARIABLETEXT)> "?src" .
              # deliberately the SAME variableText the other minting rule uses
              <urn:r2:mint> a <$(Jayhawk.C_SPARQLVAR)> ; <$(Jayhawk.P_VARIABLETEXT)> "?_Employee_1" ;
                  <$(Jayhawk.P_IRITEMPLATE)> "http://example.org/other/{k}" ;
                  <$(Jayhawk.P_HASSLOT)> [ <$(Jayhawk.P_SLOTNAME)> "k" ;
                                           <$(Jayhawk.P_SLOTVALUE)> <urn:r2:src> ] .
            } ;
            INSERT DATA {
              GRAPH <urn:r2:L> { <urn:r2:src> a <urn:r2:Thing> }
              GRAPH <urn:r2:R> { <urn:r2:mint> a <urn:r2:Made> }
            }""")

        q2 = try compile_from_store("urn:r2:Rule") catch e; sprint(showerror, e) end
        @test count("BIND", q2) == 1
        @test occursin("http://example.org/other/", q2)
        @test !occursin("http://example.org/hr/employee/", q2)

        qm = try compile_from_store("$(R)PersonToEmployeeRecord") catch e; sprint(showerror, e) end
        @test count("BIND", qm) == 1
        @test !occursin("http://example.org/other/", qm)
    end

    reset_store!()
end

# --- 4b. Fixpoint semantics, checked against an independent oracle ------------------

@testset "4b. Assert really computes the least fixpoint" begin
    reset_store!()
    Jayhawk.load_file!(fixture("transitive_rule.trig"))

    "Transitive closure via a SPARQL property path -- the oracle, independent of the engine."
    function oracle(graphs)
        froms = join(("FROM <$g>" for g in graphs), " ")
        rows = select("SELECT ?s ?o $froms WHERE { ?s <$(TC)partOf>+ ?o }")
        Set(((r["s"]::IRIRef).value, (r["o"]::IRIRef).value) for r in rows)
    end

    engine_result(fs, base) = union(
        Set(((r["s"]::IRIRef).value, (r["o"]::IRIRef).value)
            for f in fs for r in select("SELECT ?s ?o WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")),
        Set(((r["s"]::IRIRef).value, (r["o"]::IRIRef).value)
            for r in select("SELECT ?s ?o WHERE { GRAPH <$base> { ?s <$(TC)partOf> ?o } }")))

    @testset "[PIN] closure over an explicit source graph matches the oracle" begin
        load_chain!(DATA, 5)                       # n1 -> ... -> n5
        fs = run_rule(TCRULE; source = [DATA])
        @test engine_result(fs, DATA) == oracle([DATA])
        @test length(oracle([DATA])) == 10         # 4+3+2+1
        for f in fs; undo_firing!(f.graph); end
    end

    @testset "[FIXED] Assert refuses an empty source rather than under-computing" begin
        # WAS: run_rule seeds `working = copy(source)`. With source empty, iteration 1
        # emitted no USING and so read the store's default graph -- but then pushed the
        # firing graph onto `working`, so iteration 2 emitted `USING <firing1>` ONLY. The
        # base data fell out of the working set after the first round, and the driver
        # returned a strict subset of the least fixpoint while reporting convergence.
        # Reproduced on a 4-edge chain: source=[DATA] derived 6 edges, source=[] derived 4.
        #
        # NOW: refused. "The default graph plus the firings so far" is not expressible --
        # SPARQL's USING replaces the query's default graph and no IRI denotes the store's
        # own default graph -- so the working set has to be named graphs. Refusing is the
        # only honest option; a silently incomplete fixpoint is the worst answer available.
        reset_store!(); Jayhawk.load_file!(fixture("transitive_rule.trig"))
        Jayhawk.update!("INSERT DATA {" *
            join(("<$(TC)n$i> <$(TC)partOf> <$(TC)n$(i+1)> ." for i in 1:4), "\n") * "}")

        err = try run_rule(TCRULE); nothing catch e; e end
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin("needs an explicit `source`", msg)
        @test occursin("USING", msg)              # says *why*, not just "no"
        # nothing was written on the way out
        @test isempty(firings())
        @test isempty(select("""SELECT ?g WHERE { GRAPH ?g { ?s ?p ?o }
                                  FILTER(STRSTARTS(STR(?g), "urn:jayhawk:firing:")) }"""))

        # and the same rule against a named working set still computes the full closure
        load_chain!(DATA, 5)
        fs = run_rule(TCRULE; source = [DATA])
        @test engine_result(fs, DATA) == oracle([DATA])
        for f in fs; undo_firing!(f.graph); end
    end

    @testset "[FIXED] count is 'genuinely new facts' with no source" begin
        # prune_known! used to return immediately when `source` was empty, so a firing
        # restated facts the store already held and Firing.count over-reported. Unlike the
        # fixpoint bug above this one IS expressible: prune_known! issues its own update
        # with no USING, so a bare { ?s ?p ?o } alternative reads the default graph.
        #
        # Exercised on the Construct path, which is where an empty source stays legal.
        reset_store!(); Jayhawk.load_file!(fixture("person_to_employee.trig"))
        Jayhawk.update!("""INSERT DATA {
            <urn:p1> a <$(G)Person> ; <$(G)isIdentifiedBy> <urn:id1> .
            <urn:id1> a <$(G)ID> ; <$(G)containedText> "E-4471" .
            <urn:p1> a <$(HR)Employee> ; <$(HR)employeeNumber> "E-4471" . }""")

        # everything the rule would derive is already asserted in the default graph
        fs = run_rule("$(R)PersonToEmployee")
        @test sum(f.count for f in fs; init = 0) == 0
        @test all(f.count == 0 for f in fs)
        for f in fs; f.count > 0 && undo_firing!(f.graph); end
    end

    @testset "[PIN] the closure does not depend on how the data is split across graphs" begin
        # Confluence, cheaply. Same edges, two graphs instead of one, must give the same
        # answer -- this is what makes `source` a working *set* rather than an ordering.
        reset_store!(); Jayhawk.load_file!(fixture("transitive_rule.trig"))
        Jayhawk.update!("""INSERT DATA {
            GRAPH <urn:adv:g1> { <$(TC)n1> <$(TC)partOf> <$(TC)n2> .
                                 <$(TC)n3> <$(TC)partOf> <$(TC)n4> . }
            GRAPH <urn:adv:g2> { <$(TC)n2> <$(TC)partOf> <$(TC)n3> .
                                 <$(TC)n4> <$(TC)partOf> <$(TC)n5> . } }""")
        a = run_rule(TCRULE; source = ["urn:adv:g1", "urn:adv:g2"])
        got_a = Set(((r["s"]::IRIRef).value, (r["o"]::IRIRef).value)
                    for f in a for r in select("SELECT ?s ?o WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }"))
        for f in a; undo_firing!(f.graph); end
        b = run_rule(TCRULE; source = ["urn:adv:g2", "urn:adv:g1"])
        got_b = Set(((r["s"]::IRIRef).value, (r["o"]::IRIRef).value)
                    for f in b for r in select("SELECT ?s ?o WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }"))
        for f in b; undo_firing!(f.graph); end
        @test got_a == got_b
        @test length(got_a) == 6
    end

    reset_store!()
end

# --- 4c. Firings, provenance and undo ----------------------------------------------

@testset "4c. a firing means exactly one thing" begin
    reset_store!()
    Jayhawk.load_file!(fixture("transitive_rule.trig"))
    load_chain!(DATA, 4)

    @testset "[PROVEN] apply_rule refuses a non-empty target graph" begin
        # `into` is a public keyword. Point it at a graph that already holds data and
        # Firing.count reports that graph's whole size as "new facts this rule
        # contributed", and undo_firing! DROPs the caller's data along with the result.
        #
        # Observed: 1 edge derived into a graph holding 1 unrelated triple -> count == 2.
        Jayhawk.update!("INSERT DATA { GRAPH <urn:adv:occupied> { <urn:x> <urn:y> <urn:z> } }")
        @test_throws Exception apply_rule(TCRULE; into = "urn:adv:occupied", source = [DATA])
        @test graph_size("urn:adv:occupied") == 1        # caller's data untouched
        Jayhawk.update!("DROP SILENT GRAPH <urn:adv:occupied>")
    end

    @testset "[PROVEN] max_iterations must be a positive integer" begin
        # max_iterations = 0 skips the loop entirely and then reports "still producing new
        # triples after 0 iterations", which is a claim the code never checked.
        err = try run_rule(TCRULE; source = [DATA], max_iterations = 0) catch e; e end
        @test err isa ArgumentError
        @test !occursin("still producing", sprint(showerror, err))
    end

    @testset "[PIN] every firing graph in the store has a provenance record" begin
        # Store-wide invariant. apply_rule writes the result, prunes, counts, and only
        # then records provenance -- four separate HTTP round trips with no transaction
        # around them. If any one after the first fails, the store keeps a
        # urn:jayhawk:firing:* graph that `firings()` cannot see and no one can attribute.
        # Assert the invariant after a normal run; it is also the right assertion to reuse
        # in a fault-injection test against an endpoint that fails mid-sequence.
        fs = run_rule(TCRULE; source = [DATA])
        orphans = select("""
            SELECT DISTINCT ?g WHERE {
              GRAPH ?g { ?s ?p ?o }
              FILTER(STRSTARTS(STR(?g), "urn:jayhawk:firing:"))
              FILTER NOT EXISTS { GRAPH <$(Jayhawk.PROVENANCE_GRAPH)> {
                                    ?g <$(Jayhawk.JH_NS)appliedRule> ?r } } }""")
        @test isempty(orphans)
        for f in fs; undo_firing!(f.graph); end
    end

    @testset "[PROVEN] firings() is genuinely newest-first" begin
        # _now_xsd formats to whole seconds, and firings() orders by DESC(?at). Several
        # firings inside one second are a tie, and SPARQL leaves the order of tied
        # solutions unspecified, so "newest first" is whatever the store feels like.
        #
        # Observed: this assertion PASSED on one run of this file and FAILED on the next,
        # against the same Fuseki, with no change in between. A flaky audit trail is
        # worse than a consistently wrong one -- an `Assert` rule's iterations are the
        # exact case where several firings land inside one second, and the iteration
        # order is the only thing that explains how the fixpoint was reached.
        #
        # Fix: fractional seconds in _now_xsd (xsd:dateTime allows them), or order by
        # jayhawk:iteration as a tie-break, or both.
        reset_store!(); Jayhawk.load_file!(fixture("transitive_rule.trig"))
        load_chain!(DATA, 6)
        fs = run_rule(TCRULE; source = [DATA])
        @test length(fs) >= 3                     # several rounds, same wall-clock second
        log = firings()
        @test [l.graph for l in log] == [f.graph for f in reverse(fs)]
        for f in fs; undo_firing!(f.graph); end
    end

    reset_store!()
end

# --- 4d. The agent-facing surface --------------------------------------------------
#
# mcp.jl opens: "No enterprise is going to hand an agent an unrestricted UPDATE endpoint,
# and it would be right not to. What is defensible is a catalogue of named,
# SHACL-validated, provenance-stamped, reversible rewrites."
#
# Two of the five tools do not meet that bar.

@testset "4d. the MCP tools are as safe as they claim" begin
    reset_store!()
    Jayhawk.load_file!(fixture("transitive_rule.trig"))

    @testset "[PROVEN] undo_firing refuses a graph that is not a firing" begin
        # Reproduced verbatim:
        #
        #   before: <urn:precious:production-data> holds 1 triple(s)
        #   tool_undo_firing says: Undid <urn:precious:production-data>: 1 triple(s)
        #                          removed and the provenance record retracted.
        #   after : 0 triple(s)
        #   was it ever a firing? false
        #
        # undo_firing! does `DROP SILENT GRAPH <g>` on whatever IRI it is handed. Exposed
        # over MCP, that is an unrestricted DROP GRAPH primitive with a reassuring name --
        # precisely the thing mcp.jl says must not be handed to an agent. The graph IRI
        # comes straight from the model's tool call.
        #
        # Fix: require an ASK against <urn:jayhawk:provenance> that ?g is a jayhawk:Firing
        # before dropping anything.
        Jayhawk.update!("""INSERT DATA { GRAPH <urn:precious> {
            <urn:customer:1> <urn:owes> "1000000" } }""")

        @test_throws Exception undo_firing!("urn:precious")
        @test graph_size("urn:precious") == 1

        out = tool_undo_firing("urn:precious")
        @test graph_size("urn:precious") == 1          # still there
        @test occursin("not a firing", lowercase(out)) || occursin("refus", lowercase(out))

        # and the legitimate path still works
        load_chain!(DATA, 3)
        f = run_rule(TCRULE; source = [DATA])[1]
        @test occursin("removed", tool_undo_firing(f.graph))
        @test graph_size(f.graph) == 0
        Jayhawk.update!("DROP SILENT GRAPH <urn:precious>")
    end

    @testset "[PROVEN] one malformed rule does not take out the catalogue" begin
        # rule_catalogue maps mode_symbol over every row, and mode_symbol throws on an
        # unrecognised gistp:rewriteMode. One bad rule anywhere in the store and
        # tool_list_rules -- the agent's only way to discover *any* rule -- raises
        # ArgumentError instead of listing the good ones.
        #
        # Observed: ArgumentError: unknown gistp:rewriteMode <http://example.org/NotAMode>
        Jayhawk.update!("""INSERT DATA { <urn:r:Odd> a <$(Jayhawk.C_RULE)> ;
            <$(Jayhawk.P_MODE)> <http://example.org/NotAMode> . }""")
        out = try tool_list_rules() catch e; sprint(showerror, e) end
        @test occursin(TCRULE, out)                    # the good rule is still listed
        @test occursin("urn:r:Odd", out)               # and the bad one is flagged, not fatal
        Jayhawk.update!("DELETE WHERE { <urn:r:Odd> ?p ?o }")
    end

    @testset "[PIN] a rule with no gistp:Rule typing is still refused clearly" begin
        err = try tool_explain_rule("urn:does:not:exist") catch e; e end
        @test err !== nothing
        @test occursin("no rule found", sprint(showerror, err))
    end

    @testset "[PIN] a hostile source graph IRI is refused, not interpolated" begin
        # `source` is agent-supplied and lands in `USING <...>`. check_iri is the guard;
        # assert it, because this is the other place untrusted text meets the query.
        @test_throws ArgumentError tool_run_rule(TCRULE;
            source = ["urn:g> ; DROP ALL ; INSERT DATA { <urn:a> <urn:b> <urn:c> } #"])
        @test_throws ArgumentError tool_explain_rule(TCRULE; source = ["urn:a b"])
    end

    @testset "[PIN] dry_run leaves no scratch graph, on every path" begin
        before = length(select("SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o } }"))
        try tool_explain_rule(TCRULE; source = ["urn:adv:missing"]) catch; end
        try tool_explain_rule(TCRULE; source = [DATA]) catch; end
        @test length(select("SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o } }")) == before
    end

    reset_store!()
end

# --- 4e. The SPARQL client boundary -------------------------------------------------

@testset "4e. runsparql's transport assumptions" begin
    reset_store!()
    Jayhawk.load_file!(fixture("transitive_rule.trig"))

    @testset "[PIN] a large rule survives the query transport" begin
        # Queries go out as `HTTP.get(ep.query; query = "query=<escaped>")`. A realistic
        # enterprise pattern of a few hundred triples produces a URL in the tens of KB;
        # Jetty's default request-line limit will 414 long before the store objects. If
        # this fails, SELECT needs to POST as application/sparql-query.
        big = "INSERT DATA { GRAPH <urn:adv:big> {" *
              join(("<urn:s$i> <urn:p> <urn:o$i> ." for i in 1:2000), "\n") * "} }"
        Jayhawk.update!(big)
        q = "SELECT ?s WHERE { GRAPH <urn:adv:big> { ?s <urn:p> ?o } FILTER(?s IN (" *
            join(("<urn:s$i>" for i in 1:2000), ", ") * ")) }"
        @test length(select(q)) == 2000
        Jayhawk.update!("DROP SILENT GRAPH <urn:adv:big>")
    end

    @testset "[PROVEN] Mustache does not eat SPARQL group patterns" begin
        # `{{` is legal SPARQL (a nested group pattern) and is also Mustache's opening
        # delimiter. render_query guards on isempty(bindings), so the engine's own paths
        # are safe -- but the guard is the only thing protecting them, and `select`,
        # `ask` and `update!` all take a public `bindings` keyword.
        #
        # Reproduced:
        #   query    SELECT ?s WHERE { GRAPH <urn:adv:m> {{ ?s ?p ?o }} }
        #   rendered SELECT ?s WHERE { GRAPH <urn:adv:m>  }
        #
        # Mustache deleted the whole group as an unresolved section. Here that happened
        # to produce an HTTP 400; a query where the eaten group is an OPTIONAL or a
        # FILTER would have returned a confidently wrong answer instead.
        #
        # Templating and SPARQL should not share a syntax. Either change the Mustache
        # delimiters, or drop templating from this layer entirely -- the engine builds
        # every query by interpolation and never uses it.
        Jayhawk.update!("INSERT DATA { GRAPH <urn:adv:m> { <urn:a> <urn:b> <urn:c> } }")
        q = "SELECT ?s WHERE { GRAPH <urn:adv:m> {{ ?s ?p ?o }} }"
        @test length(select(q)) == 1                                    # guard holds
        n = try length(select(q; bindings = Dict("unused" => "x"))) catch; -1 end
        @test n == 1                                                    # must not corrupt
        Jayhawk.update!("DROP SILENT GRAPH <urn:adv:m>")
    end

    @testset "[PIN] an unbound variable is absent, not nothing" begin
        Jayhawk.update!("INSERT DATA { GRAPH <urn:adv:u> { <urn:a> <urn:b> <urn:c> } }")
        r = only(select("SELECT ?s ?missing WHERE { GRAPH <urn:adv:u> { ?s ?p ?o } }"))
        @test haskey(r, "s") && !haskey(r, "missing")
        Jayhawk.update!("DROP SILENT GRAPH <urn:adv:u>")
    end

    reset_store!()
end

# --- 4f. gistp:Rewrite against live data --------------------------------------------
#
# The destructive mode. Its whole licence to exist is that it is reversible: "the removed
# triples go to a tombstone in the same atomic update" is what makes it defensible to hand
# an agent. These tests are about whether the round trip is actually exact.

RWRULE = "http://example.org/rules/FlattenIdentifier"
TARGET = "urn:jayhawk:adv-target"

"Every triple of a graph, as comparable strings."
snapshot(g) = Set(string(sparql_text(r["s"]), ' ', sparql_text(r["p"]), ' ', sparql_text(r["o"]))
                  for r in select("SELECT ?s ?p ?o WHERE { GRAPH <$g> { ?s ?p ?o } }"))

@testset "4f. Rewrite is reversible, exactly" begin
    reset_store!()
    Jayhawk.load_file!(fixture("rewrite_rule.trig"))

    @testset "[PROVEN] undo restores the target byte for byte" begin
        # THE ONE THAT MATTERS. `apply_rewrite!` writes R∖I into the firing graph
        # unpruned, so the firing graph means "what R's template instantiated to", not
        # "what this rule added". `undo_firing!` then DELETEs all of it from the target --
        # including triples that were already there before the rewrite ran and that the
        # rewrite therefore never added.
        #
        # Reproduced. Target holds 5 triples, one of which is the ex:employeeNumber the
        # rule would add:
        #     before rewrite : 5
        #     after  rewrite : 2   (removed 3, "added" 1 that already existed)
        #     after  undo    : 4   <- <urn:p1> ex:employeeNumber "E-1" is GONE
        #
        # It is gone permanently: the tombstone only holds L∖I, so nothing anywhere
        # records that this triple existed. Silent, irreversible data loss on the code
        # path whose entire purpose is reversibility, in the only mode that deletes.
        #
        # The additive modes have prune_known! for exactly this reason; the rewrite path
        # does not call it. The fix has to compute the overlap R∖I ∩ target *before* the
        # update -- afterwards the information is gone -- and prune the firing graph with
        # it, mirroring what prune_known! does for Construct and Assert.
        Jayhawk.update!("""INSERT DATA { GRAPH <$TARGET> {
            <urn:p1> a <$(G)Person> ; <$(G)isIdentifiedBy> <urn:i1> ;
                     <$(HR)employeeNumber> "E-1" .
            <urn:i1> a <$(G)ID> ; <$(G)containedText> "E-1" .
        } }""")
        before = snapshot(TARGET)
        @test length(before) == 5

        f = run_rule(RWRULE; source = [TARGET])[1]
        @test f.removed == 3
        undo_firing!(f.graph)

        @test snapshot(TARGET) == before
        @test "<urn:p1> <$(HR)employeeNumber> \"E-1\"" in snapshot(TARGET)
        Jayhawk.update!("DROP SILENT GRAPH <$TARGET>")
    end

    @testset "[PIN] undo restores exactly when nothing overlapped" begin
        # The case the round-2 work did verify, kept as the control: with no pre-existing
        # overlap the round trip is already exact, which is what localises the bug above
        # to the unpruned firing graph rather than to the tombstone mechanism.
        Jayhawk.update!("""INSERT DATA { GRAPH <$TARGET> {
            <urn:p9> a <$(G)Person> ; <$(G)isIdentifiedBy> <urn:i9> .
            <urn:i9> a <$(G)ID> ; <$(G)containedText> "E-9" .
        } }""")
        before = snapshot(TARGET)
        f = run_rule(RWRULE; source = [TARGET])[1]
        @test snapshot(TARGET) != before          # it really did rewrite
        undo_firing!(f.graph)
        @test snapshot(TARGET) == before
        Jayhawk.update!("DROP SILENT GRAPH <$TARGET>")
    end

    @testset "[PROVEN] added/removed counts describe the actual change" begin
        # Same root cause, separate symptom: `Firing.count` is graph_size of the unpruned
        # firing graph, so it counts template instantiations rather than new facts --
        # contradicting `Firing`'s own docstring ("already stripped of anything the working
        # set had, so `count` is genuinely new facts"). dry_run inherits it, so
        # explain_rule shows a reviewer a number the run will not match.
        #
        # Observed: reported added 1, removed 3 -> net -2; the target actually went 5 -> 2,
        # a net change of -3.
        Jayhawk.update!("""INSERT DATA { GRAPH <$TARGET> {
            <urn:p1> a <$(G)Person> ; <$(G)isIdentifiedBy> <urn:i1> ;
                     <$(HR)employeeNumber> "E-1" .
            <urn:i1> a <$(G)ID> ; <$(G)containedText> "E-1" .
        } }""")
        d = dry_run(RWRULE; source = [TARGET])
        n_before = graph_size(TARGET)
        f = run_rule(RWRULE; source = [TARGET])[1]
        n_after = graph_size(TARGET)

        @test f.count - f.removed == n_after - n_before   # the firing describes the change
        @test d.count == f.count                          # and the preview matched the run
        @test d.removed == f.removed
        undo_firing!(f.graph)
        Jayhawk.update!("DROP SILENT GRAPH <$TARGET>")
    end

    @testset "[PROVEN] the audit log reports removals" begin
        # record_firing! writes jayhawk:removedCount and jayhawk:tombstoneGraph into the
        # provenance graph, but firings() never selects them, so tool_firings prints only
        # the added count. A rewrite that deleted 6 triples and added 2 appears in the
        # audit trail as "2 triple(s)".
        #
        # An audit trail that under-reports the destructive operation is the one place it
        # cannot afford to be lossy -- and the data is already being written, so this is a
        # projection that was never added rather than a design gap.
        Jayhawk.update!("""INSERT DATA { GRAPH <$TARGET> {
            <urn:p1> a <$(G)Person> ; <$(G)isIdentifiedBy> <urn:i1> .
            <urn:i1> a <$(G)ID> ; <$(G)containedText> "E-1" .
            <urn:p2> a <$(G)Person> ; <$(G)isIdentifiedBy> <urn:i2> .
            <urn:i2> a <$(G)ID> ; <$(G)containedText> "E-2" .
        } }""")
        f = run_rule(RWRULE; source = [TARGET], actor = "agent-9")[1]
        @test f.removed == 6

        log = only(firings(rule = RWRULE))
        @test hasproperty(log, :removed)
        @test (hasproperty(log, :removed) ? log.removed : 0) == 6
        @test occursin("6", tool_firings(rule = RWRULE))   # a reader can see the deletion

        undo_firing!(f.graph)
        Jayhawk.update!("DROP SILENT GRAPH <$TARGET>")
    end

    @testset "[PROVEN] MCP refuses a bad source arity instead of raising" begin
        # Every other refusal on the MCP surface comes back as a string the model can read
        # and act on -- "Refused: ... is a gistp:Rewrite, which DELETES from live data",
        # "Refused: ... is not a recorded firing". The source-arity check raises
        # ArgumentError out of apply_rewrite!/dry_run_rewrite instead, so the agent gets a
        # stack trace for the ordinary mistake of passing the wrong number of graphs.
        Jayhawk.update!("INSERT DATA { GRAPH <$TARGET> { <urn:a> <urn:b> <urn:c> } }")
        for src in (String[], [TARGET, "urn:adv:other"])
            out = try tool_run_rule(RWRULE; source = src) catch e; "RAISED" end
            @test out != "RAISED"
            @test occursin("exactly one", out) || occursin("one source", out)
        end
        Jayhawk.update!("DROP SILENT GRAPH <$TARGET>")
    end

    reset_store!()
end

end # JAYHAWK_TEST_SPARQL

end # Jayhawk adversarial suite
