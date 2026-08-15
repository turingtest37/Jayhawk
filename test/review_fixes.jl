# Independent verification of the fixes for the adversarial findings.
#
#   julia --project=. test/review_fixes.jl                       # hermetic part
#   JAYHAWK_TEST_SPARQL=1 julia --project=. test/review_fixes.jl  # + store-backed part
#
# Written as a review, not as a re-run: these assertions were authored from the *claims*
# ("variableText is now validated", "undo only touches firings", "declarations are scoped to
# the rule") rather than from the fixing session's own test file, and they deliberately
# probe for ways around each fix rather than confirming the happy path.
#
# A fix is accepted only if the property holds on every route that reaches the store, not
# merely on the one route the bug was first reported through.

using Test
using Jayhawk

const G    = "https://w3id.org/semanticarts/ns/ontology/gist/"
const HR   = "http://example.org/hr/"
const R    = "http://example.org/rules/"
const TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

iri(s) = IRIRef(s)
gvar(s) = RDFLiteral(s, Jayhawk.GISTP_VAR)

"A minimal well-formed Construct rule, with one knob per thing a caller might poison."
function spec_with(; variables = Dict("$(R)_p" => "?p"),
                     mints = Dict{String,MintSpec}(),
                     match = [PatternTriple(iri("$(R)_p"), iri(TYPE), iri("$(G)Person"))],
                     construct = [PatternTriple(iri("$(R)_p"), iri(TYPE), iri("$(HR)Employee"))],
                     mode = Jayhawk.MODE_CONSTRUCT)
    RuleSpec("$(R)Probe", mode, "$(R)Probe_L", "$(R)Probe_R",
             match, construct, variables, mints)
end

failure(f) = try (f(); nothing) catch e; e end

@testset "REVIEW: fixes for the adversarial findings" begin

# =====================================================================
# Finding 1 -- variableText was spliced into emitted SPARQL unvalidated
# =====================================================================
@testset "1. variableText cannot inject SPARQL" begin

    # The original proof of concept: close the engine's clause and open your own.
    INJECTION = "?x } INSERT { <urn:pwned> <urn:p> <urn:o> } WHERE { ?x a <urn:X>"

    @testset "every text-emitting entry point refuses it" begin
        s = spec_with(variables = Dict("$(R)_p" => INJECTION))
        # compile_rule is where the bug was reported...
        @test failure(() -> compile_rule(s)) !== nothing
        # ...but insert_query is the one whose output reaches the *update* endpoint, and it
        # is a separate function with its own body. A fix in only one of them is not a fix.
        @test failure(() -> insert_query(s; into = "urn:t")) !== nothing
        for e in (failure(() -> compile_rule(s)), failure(() -> insert_query(s; into = "urn:t")))
            @test occursin("variableText", sprint(showerror, e))
        end
    end

    @testset "the refusal is by whitelist, not by blacklisting the exploit" begin
        # A fix that only rejected "}" or "INSERT" would pass the test above and still be
        # broken. Probe shapes that are harmless-looking but not SPARQL variables.
        for bad in ("person",              # a plausible typo -- no sigil at all
                    "?",                   # sigil only
                    "?1st",                # leading digit
                    "?a-b",                # hyphen is not a SPARQL varname char
                    "?a b",                # embedded space
                    "?a\n?b",              # newline
                    "??x",                 # doubled sigil
                    "\$",                  # bare dollar
                    "?x.",                 # trailing dot ends a triple
                    "",                    # empty
                    " ?x")                 # leading space
            @test failure(() -> compile_rule(spec_with(
                variables = Dict("$(R)_p" => bad)))) !== nothing
        end
        # and the legal shapes still compile
        for good in ("?x", "\$x", "?_Person_1", "?a9_Z")
            @test compile_rule(spec_with(variables = Dict("$(R)_p" => good))) isa String
        end
    end

    @testset "a poisoned template cannot escape its string literal" begin
        # The template is emitted inside a SPARQL string literal in the BIND. If it were
        # interpolated rather than escaped, a quote would close the literal.
        s = spec_with(
            variables = Dict("$(R)_p" => "?p", "$(R)_m" => "?m"),
            mints = Dict("$(R)_m" => MintSpec("$(R)_m",
                "http://ex.org/\")) } INSERT { <urn:pwned> <urn:p> <urn:o> } WHERE { BIND(IRI(CONCAT(\"x{id}",
                Dict{String,RDFTerm}("id" => gvar("?idText")))),
            match = [PatternTriple(iri("$(R)_p"), iri(TYPE), iri("$(G)Person")),
                     PatternTriple(iri("$(R)_p"), iri("$(G)containedText"), gvar("?idText"))],
            construct = [PatternTriple(iri("$(R)_m"), iri(TYPE), iri("$(HR)Employee"))])
        q = failure(() -> compile_rule(s)) === nothing ? compile_rule(s) : ""
        if !isempty(q)
            # if it compiles at all, the payload must be inert: escaped inside the literal,
            # never a second INSERT clause
            @test !occursin("} INSERT {", q)
            @test occursin("\\\"", q)     # the quote was escaped
        end
    end

    @testset "every function that builds SPARQL validates its own inputs" begin
        # R1 from the review. apply_rule calls check_collisions BEFORE insert_query, so
        # relying on insert_query's check_bound left check_collisions shipping unvalidated
        # text to the store -- it reached Fuseki and came back HTTP 400. Nothing was written,
        # but only because the query endpoint refuses updates: a property of the store's
        # endpoint separation rather than of this code.
        #
        # The template below has an ambiguous separator on purpose, so check_collisions does
        # not take its injective-mint short circuit and actually assembles a query.
        s = spec_with(
            variables = Dict("$(R)_p" => INJECTION, "$(R)_m" => "?m"),
            mints = Dict("$(R)_m" => MintSpec("$(R)_m", "http://ex.org/{a}_{b}",
                Dict{String,RDFTerm}("a" => gvar("?idText"), "b" => gvar("?idText")))),
            match = [PatternTriple(iri("$(R)_p"), iri(TYPE), iri("$(G)Person")),
                     PatternTriple(iri("$(R)_p"), iri("$(G)containedText"), gvar("?idText"))],
            construct = [PatternTriple(iri("$(R)_m"), iri(TYPE), iri("$(HR)Employee"))])

        for (name, f) in (("check_collisions", () -> check_collisions(s; from = ["urn:none"])),
                          ("mint_fanin",       () -> mint_fanin(s; from = ["urn:none"])))
            e = failure(f)
            @test e !== nothing
            # refused locally on variableText, NOT by the store rejecting our SPARQL
            @test occursin("variableText", sprint(showerror, e))
            @test !occursin("HTTP 400", sprint(showerror, e))
        end
    end
end

# =====================================================================
# Finding 2 -- undo_firing! was an unrestricted DROP GRAPH
# =====================================================================
@testset "2. undo_firing! is not a general graph delete" begin
    @test isdefined(Jayhawk, :is_firing)

    # The MCP tool must not expose the force escape hatch: an argument a model can set
    # defeats the guard entirely.
    @test !any(m -> :force in Base.kwarg_decl(m),
               methods(Jayhawk.tool_undo_firing))
    # while the internal function does have it
    @test any(m -> :force in Base.kwarg_decl(m), methods(undo_firing!))
end

# =====================================================================
# Finding 3 -- declarations were loaded from the whole store
# =====================================================================
@testset "3. loaders are scoped to the rule" begin
    # Signature change is the visible part of the fix; the behavioural check needs a store
    # and lives below.
    @test !hasmethod(load_variables, Tuple{})
    @test !hasmethod(load_mints, Tuple{})
    @test hasmethod(load_variables, Tuple{Vector{String}})
    @test hasmethod(load_mints, Tuple{Vector{String}})
end

# =====================================================================
# Fixes made alongside, which the review must also cover
# =====================================================================
@testset "4. run_rule argument validation" begin
    s = spec_with(mode = Jayhawk.MODE_ASSERT)
    @test failure(() -> run_rule(s; source = ["urn:g"], max_iterations = 0)) isa ArgumentError
    @test failure(() -> run_rule(s; source = ["urn:g"], max_iterations = -1)) isa ArgumentError
    # Assert without a named working set cannot see its own output after round 1, because
    # USING replaces the default graph rather than adding to it.
    @test failure(() -> run_rule(s; source = String[])) isa ArgumentError
    # Construct applies once, so an empty source is fine for it -- must NOT be refused
    e = failure(() -> run_rule(spec_with(); source = String[]))
    @test !(e isa ArgumentError)
end

@testset "5. rule_catalogue survives a rule it cannot compile" begin
    # mode_symbol throws on an unrecognised mode; the catalogue must not.
    @test mode_symbol(Jayhawk.MODE_ASSERT) === :Assert
    @test failure(() -> mode_symbol("http://example.org/NotAMode")) isa ArgumentError
end

# =====================================================================
# Findings NOT addressed -- verified still open, so the list stays honest
# =====================================================================
@testset "6. still open (recorded, not asserted as fixed)" begin
    @info "check_iri(\"\")" result = failure(() -> check_iri("")) === nothing ? "ACCEPTED" : "refused"
    @info "check_iri(\"not-a-uri\")" result = failure(() -> check_iri("not-a-uri")) === nothing ? "ACCEPTED" : "refused"
    # a literal in predicate position is not legal RDF, let alone legal SPARQL
    lit_pred = spec_with(match = [PatternTriple(iri("$(R)_p"), RDFLiteral("oops"), iri("$(G)Person"))])
    @info "literal in predicate position" result = failure(() -> compile_rule(lit_pred)) === nothing ? "ACCEPTED" : "refused"
    @test true
end

end # REVIEW

# =========================================================================
# Store-backed. These are the ones that actually prove the fixes.
# =========================================================================
if haskey(ENV, "JAYHAWK_TEST_SPARQL")

reachable() = try (Jayhawk.runsparql("ASK {}"); true) catch; false end
reachable() || error("no Fuseki at $(Jayhawk.spqservice); ./resource/fuseki-test.sh start")

const RG = "urn:review:data"

function scrub()
    for f in firings(); undo_firing!(f.graph; force = true); end
    for g in ("urn:review:data", "urn:review:precious", "urn:review:fake",
              Jayhawk.PROVENANCE_GRAPH,
              "$(R)A_L", "$(R)A_R", "$(R)B_L", "$(R)B_R")
        Jayhawk.update!("DROP SILENT GRAPH <$g>")
    end
    Jayhawk.update!("DELETE WHERE { ?s ?p ?o }")
end

@testset "REVIEW (store-backed)" begin
scrub()

@testset "2. undo_firing! refuses what it did not create" begin
    Jayhawk.update!("INSERT DATA { GRAPH <urn:review:precious> { <urn:a> <urn:b> <urn:c> } }")
    @test graph_size("urn:review:precious") == 1

    @test failure(() -> undo_firing!("urn:review:precious")) !== nothing
    @test graph_size("urn:review:precious") == 1        # the data is still there

    @testset "and imitating the firing IRI convention does not help" begin
        # Membership must be decided by the provenance record, not by the IRI prefix --
        # a prefix is a naming convention anyone can copy.
        fake = "urn:jayhawk:firing:11111111-1111-1111-1111-111111111111"
        Jayhawk.update!("INSERT DATA { GRAPH <$fake> { <urn:x> <urn:y> <urn:z> } }")
        @test failure(() -> undo_firing!(fake)) !== nothing
        @test graph_size(fake) == 1
        Jayhawk.update!("DROP SILENT GRAPH <$fake>")
    end

    @testset "the MCP tool refuses it too, and says so" begin
        out = tool_undo_firing("urn:review:precious")
        @test occursin("Refused", out)
        @test graph_size("urn:review:precious") == 1
    end

    @testset "force is the documented escape hatch and still works" begin
        undo_firing!("urn:review:precious"; force = true)
        @test graph_size("urn:review:precious") == 0
    end
end

@testset "1. injection is refused on the path that writes to the store" begin
    # The hermetic tests prove compile_rule and insert_query refuse. This proves nothing
    # reaches the update endpoint: if it did, <urn:review:pwned> would exist afterwards.
    Jayhawk.update!("DROP SILENT GRAPH <urn:review:pwned>")
    s = spec_with(variables = Dict("$(R)_p" =>
        "?x } INSERT { GRAPH <urn:review:pwned> { <urn:a> <urn:b> <urn:c> } } WHERE { ?x a <urn:X>"))
    @test failure(() -> apply_rule(s; source = [RG])) !== nothing
    @test failure(() -> dry_run(s; source = [RG])) !== nothing
    @test graph_size("urn:review:pwned") == 0
end

@testset "3. two rules in one store stay separate" begin
    # Both mint, with DIFFERENT variable names, so a leaked BIND is visible in the text.
    Jayhawk.update!("""
        INSERT DATA {
          <$(R)A> a <$(Jayhawk.C_RULE)> ;
              <$(Jayhawk.P_MATCH)> <$(R)A_L> ; <$(Jayhawk.P_CONSTRUCT)> <$(R)A_R> ;
              <$(Jayhawk.P_MODE)> <$(Jayhawk.MODE_CONSTRUCT)> .
          <$(R)B> a <$(Jayhawk.C_RULE)> ;
              <$(Jayhawk.P_MATCH)> <$(R)B_L> ; <$(Jayhawk.P_CONSTRUCT)> <$(R)B_R> ;
              <$(Jayhawk.P_MODE)> <$(Jayhawk.MODE_CONSTRUCT)> .

          <$(R)_pA> a <$(Jayhawk.C_SPARQLVAR)> ; <$(Jayhawk.P_VARIABLETEXT)> "?pA" .
          <$(R)_mA> a <$(Jayhawk.C_SPARQLVAR)> ; <$(Jayhawk.P_VARIABLETEXT)> "?mA" ;
              <$(Jayhawk.P_IRITEMPLATE)> "http://ex.org/a/{id}" ;
              <$(Jayhawk.P_HASSLOT)> [ <$(Jayhawk.P_SLOTNAME)> "id" ;
                                       <$(Jayhawk.P_SLOTVALUE)> "?tA"^^<$(Jayhawk.GISTP_VAR)> ] .
          <$(R)_pB> a <$(Jayhawk.C_SPARQLVAR)> ; <$(Jayhawk.P_VARIABLETEXT)> "?pB" .
          <$(R)_mB> a <$(Jayhawk.C_SPARQLVAR)> ; <$(Jayhawk.P_VARIABLETEXT)> "?mB" ;
              <$(Jayhawk.P_IRITEMPLATE)> "http://ex.org/b/{id}" ;
              <$(Jayhawk.P_HASSLOT)> [ <$(Jayhawk.P_SLOTNAME)> "id" ;
                                       <$(Jayhawk.P_SLOTVALUE)> "?tB"^^<$(Jayhawk.GISTP_VAR)> ] .
        } ;
        INSERT DATA {
          GRAPH <$(R)A_L> { <$(R)_pA> a <$(G)Person> ; <$(G)containedText> "?tA"^^<$(Jayhawk.GISTP_VAR)> }
          GRAPH <$(R)A_R> { <$(R)_mA> a <$(HR)Employee> }
          GRAPH <$(R)B_L> { <$(R)_pB> a <$(G)Person> ; <$(G)containedText> "?tB"^^<$(Jayhawk.GISTP_VAR)> }
          GRAPH <$(R)B_R> { <$(R)_mB> a <$(HR)Employee> }
        }""")

    specA = load_rule("$(R)A")
    specB = load_rule("$(R)B")

    @testset "each spec holds only its own declarations" begin
        @test Set(values(specA.variables)) == Set(["?pA", "?mA"])
        @test Set(values(specB.variables)) == Set(["?pB", "?mB"])
        @test collect(keys(specA.mints)) == ["$(R)_mA"]
        @test collect(keys(specB.mints)) == ["$(R)_mB"]
    end

    @testset "neither query carries the other's BIND" begin
        qa, qb = compile_rule(specA), compile_rule(specB)
        @test occursin("AS ?mA)", qa) && !occursin("?mB", qa)
        @test occursin("AS ?mB)", qb) && !occursin("?mA", qb)
        @test occursin("http://ex.org/a/", qa) && !occursin("http://ex.org/b/", qa)
    end

    @testset "and they execute independently" begin
        Jayhawk.update!("""INSERT DATA { GRAPH <$RG> {
            <urn:s1> a <$(G)Person> ; <$(G)containedText> "one" . } }""")
        fa = run_rule("$(R)A"; source = [RG])
        fb = run_rule("$(R)B"; source = [RG])
        mints_a = Set((r["s"]::IRIRef).value for f in fa
                      for r in select("SELECT ?s WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }"))
        mints_b = Set((r["s"]::IRIRef).value for f in fb
                      for r in select("SELECT ?s WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }"))
        @test mints_a == Set(["http://ex.org/a/one"])
        @test mints_b == Set(["http://ex.org/b/one"])
        for f in vcat(fa, fb); undo_firing!(f.graph); end
    end

    @testset "an unrecognised mode does not hide the other rules" begin
        Jayhawk.update!("""INSERT DATA {
            <urn:r:Odd> a <$(Jayhawk.C_RULE)> ;
                <$(Jayhawk.P_MATCH)> <urn:r:Odd_L> ;
                <$(Jayhawk.P_CONSTRUCT)> <urn:r:Odd_R> ;
                <$(Jayhawk.P_MODE)> <http://example.org/NotAMode> . }""")
        out = tool_list_rules()
        @test occursin("$(R)A", out)          # the good rules are still listed
        @test occursin("$(R)B", out)
        @test occursin("urn:r:Odd", out)      # and the bad one is shown as unusable
        @test occursin("CANNOT BE RUN", out)
        # but using it still fails loudly
        @test failure(() -> compile_from_store("urn:r:Odd")) !== nothing
        Jayhawk.update!("DELETE WHERE { <urn:r:Odd> ?p ?o }")
    end
end

@testset "4b. prune_known! prunes against the default graph too" begin
    # count is documented as "genuinely new facts". With an empty source it used to prune
    # nothing, so a Construct rule over the default graph reported facts already present.
    scrub()
    Jayhawk.update!("""INSERT DATA {
        <urn:d1> a <$(G)Person> .
        <urn:d1> a <$(HR)Employee> . }""")     # the conclusion is ALREADY true
    s = spec_with(variables = Dict("$(R)_p" => "?p"))
    f = apply_rule(s; source = String[])
    @test f.count == 0
    @test graph_size(f.graph) == 0
end

scrub()
end # REVIEW (store-backed)
end
