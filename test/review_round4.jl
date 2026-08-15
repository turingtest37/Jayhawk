# Independent review of Round 4 (gistp:oneOf).
#
#   julia --project=. test/review_round4.jl                       # hermetic
#   JAYHAWK_TEST_SPARQL=1 julia --project=. test/review_round4.jl  # + store-backed
#
# Written against the round's own claims -- "one VALUES clause, two readings", "which
# reading is decided by the rest of the rule", "check_enums refuses three shapes" -- and
# aimed at the gaps rather than the happy paths, which the round already covers.
#
# Findings are asserted where the behaviour is wrong and @info'd where it is merely
# unreachable or undecided, so the distinction survives into the output.

using Test
using Jayhawk

const G    = "https://w3id.org/semanticarts/ns/ontology/gist/"
const EX   = "http://example.org/rev4/"
const R    = "http://example.org/rules/"
const TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

iri(s)  = IRIRef(s)
gvar(s) = RDFLiteral(s, Jayhawk.GISTP_VAR)
failure(f) = try (f(); nothing) catch e; e end

"A Construct rule with one enumerated variable, every knob exposed."
function enum_spec(; values = RDFTerm[RDFLiteral("a"), RDFLiteral("b")],
                     variables = Dict("$(R)_p" => "?p", "$(R)_c" => "?c"),
                     match = [PatternTriple(iri("$(R)_p"), iri(TYPE), iri("$(G)Person"))],
                     construct = [PatternTriple(iri("$(R)_p"), iri("$(EX)tag"), iri("$(R)_c"))],
                     mints = Dict{String,MintSpec}(), nacs = NacSpec[])
    RuleSpec("$(R)Enum", Jayhawk.MODE_CONSTRUCT, "$(R)Enum_L", "$(R)Enum_R",
             match, construct, variables, mints,
             Dict{String,Vector{RDFTerm}}("$(R)_c" => values),
             nacs, nothing, 0, nothing)
end

@testset "REVIEW: Round 4 (gistp:oneOf)" begin

@testset "FINDING -- an enumerated IRI is emitted unvalidated" begin
    # values_text renders each member with `sparql_text`, which wraps an IRI in <> and
    # checks nothing. `term_sparql`, which every other IRI in the query goes through, calls
    # `check_iri` first. So one rendering path validates and the other does not.
    #
    # The threat model is the one this codebase already settled on: check_variables was
    # deliberately put in the pure layer "so that a hand-built RuleSpec is checked too, not
    # just one loaded from a store". By that standard this is the same hole in a new place.
    payload = "http://ex.org/a> } INSERT { <urn:pwned> <urn:p> <urn:o> } WHERE { VALUES ?c { <http://ex.org/b"
    s = enum_spec(values = RDFTerm[iri(payload)])
    q = failure(() -> compile_rule(s)) === nothing ? compile_rule(s) : ""
    @test_broken isempty(q)                       # ought to be refused
    if !isempty(q)
        @info "an enumerated IRI escapes its <> and opens a second clause" leaked =
            occursin("} INSERT {", q)
    end

    # a literal member IS safe, because sparql_text escapes literals
    quoted = enum_spec(values = RDFTerm[RDFLiteral("a\" } INSERT { <urn:x> <urn:y> <urn:z> } #")])
    qq = compile_rule(quoted)
    # The payload text is present but INERT: the quote is escaped, so the string literal
    # never terminates and the braces stay inside it. Absence of the substring would be the
    # wrong assertion -- escaping, not deletion, is what makes it safe.
    @test occursin("\\\" } INSERT {", qq)
    @test !occursin("\" } INSERT {", replace(qq, "\\\"" => ""))

    # and the same IRI in a *pattern* position is refused, which is the inconsistency
    @test failure(() -> compile_rule(enum_spec(
        match = [PatternTriple(iri(payload), iri(TYPE), iri("$(G)Person"))]))) !== nothing
end

@testset "the two readings differ only in the rest of the rule" begin
    # The headline claim. Same enums, same values_text; only whether L binds ?c changes.
    generating = enum_spec()
    constraining = enum_spec(
        match = [PatternTriple(iri("$(R)_p"), iri(TYPE), iri("$(G)Person")),
                 PatternTriple(iri("$(R)_p"), iri("$(EX)region"), iri("$(R)_c"))])

    @test values_text(generating) == values_text(constraining)   # identical clause
    @test !("?c" in vars_in(generating.match, generating))       # generate: only VALUES binds it
    @test "?c" in vars_in(constraining.match, constraining)      # constrain: L binds it too
    # both compile, and neither needs a flag to say which it is
    @test occursin("VALUES ?c { \"a\" \"b\" }", compile_rule(generating))
    @test occursin("VALUES ?c { \"a\" \"b\" }", compile_rule(constraining))
end

@testset "byte-stability does not depend on how the spec was built" begin
    # values_text sorts rather than trusting the loader, so a hand-built spec in any order
    # gives the same bytes.
    a = enum_spec(values = RDFTerm[RDFLiteral("b"), RDFLiteral("a")])
    b = enum_spec(values = RDFTerm[RDFLiteral("a"), RDFLiteral("b")])
    @test compile_rule(a) == compile_rule(b)
    # mixed kinds sort deterministically too
    mixed = enum_spec(values = RDFTerm[iri("$(EX)z"), RDFLiteral("a"), iri("$(EX)b")])
    @test compile_rule(mixed) == compile_rule(enum_spec(
        values = RDFTerm[RDFLiteral("a"), iri("$(EX)b"), iri("$(EX)z")]))
end

@testset "an enumerated variable is available to R without appearing in L" begin
    # Exactly as a minted one is: bound by its VALUES rather than by a triple pattern.
    @test "?c" in enum_vars(enum_spec())
    @test check_bound(enum_spec()) isa RuleSpec
end

@testset "broken enumerations" begin
    # no variableText: nothing for VALUES to bind
    @test failure(() -> compile_rule(enum_spec(
        variables = Dict("$(R)_p" => "?p")))) !== nothing
    # oneOf and iriTemplate together are contradictory instructions
    both = enum_spec(mints = Dict("$(R)_c" => MintSpec("$(R)_c", "http://ex.org/{x}",
        Dict{String,RDFTerm}("x" => gvar("?p")))))
    @test occursin("contradictory", sprint(showerror, failure(() -> compile_rule(both))))
    # an empty list can never fire
    @test occursin("never fire",
        sprint(showerror, failure(() -> compile_rule(enum_spec(values = RDFTerm[])))))
end

@testset "an enumerated variable used only inside a NAC" begin
    # VALUES is emitted in the OUTER group, so binding it there changes what the guard
    # means: instead of "there is no X at all", the filter is evaluated once per value and
    # the rule fires unless EVERY value is present. Undecided in the vocabulary; recorded
    # so the semantics are a choice rather than an accident.
    s = enum_spec(construct = [PatternTriple(iri("$(R)_p"), iri("$(EX)tag"), iri("$(EX)fixed"))],
                  nacs = [NacSpec("$(R)N",
                      [PatternTriple(iri("$(R)_p"), iri("$(EX)region"), iri("$(R)_c"))])])
    q = compile_rule(s)
    outer = findfirst("VALUES ?c", q)
    guard = findfirst("FILTER NOT EXISTS", q)
    @info "oneOf on a NAC-only variable binds in the outer group" values_before_filter =
        (outer !== nothing && guard !== nothing && outer.start < guard.start)
    @test q isa String
end

end # hermetic

if haskey(ENV, "JAYHAWK_TEST_SPARQL")

reachable() = try (Jayhawk.runsparql("ASK {}"); true) catch; false end
reachable() || error("no Fuseki; ./resource/fuseki-test.sh start")

const RG = "urn:rev4:data"
scrub() = begin
    for f in firings(); undo_firing!(f.graph; force = true); end
    for g in (RG, Jayhawk.PROVENANCE_GRAPH, "$(R)E_L", "$(R)E_R")
        Jayhawk.update!("DROP SILENT GRAPH <$g>")
    end
    Jayhawk.update!("DELETE WHERE { ?s ?p ?o }")
end

"Load a Construct rule whose enumerated variable ?c has the given rdf:List object."
function load_enum_rule(list_ttl; in_l::Bool)
    scrub()
    lpat = in_l ? "<$(R)_p> a <$(G)Person> ; <$(EX)region> <$(R)_c> ." :
                  "<$(R)_p> a <$(G)Person> ."
    Jayhawk.update!("""
        INSERT DATA {
          <$(R)E> a <$(Jayhawk.C_RULE)> ;
              <$(Jayhawk.P_MATCH)> <$(R)E_L> ; <$(Jayhawk.P_CONSTRUCT)> <$(R)E_R> ;
              <$(Jayhawk.P_MODE)> <$(Jayhawk.MODE_CONSTRUCT)> .
          <$(R)_p> a <$(Jayhawk.C_SPARQLVAR)> ; <$(Jayhawk.P_VARIABLETEXT)> "?p" .
          <$(R)_c> a <$(Jayhawk.C_SPARQLVAR)> ; <$(Jayhawk.P_VARIABLETEXT)> "?c" ;
              <$(Jayhawk.P_ONEOF)> $list_ttl .
        } ;
        INSERT DATA {
          GRAPH <$(R)E_L> { $lpat }
          GRAPH <$(R)E_R> { <$(R)_p> <$(EX)tag> <$(R)_c> . }
        }""")
    load_rule("$(R)E")
end

@testset "REVIEW: Round 4 (store-backed)" begin

@testset "the coproduct is real: one match becomes N results" begin
    spec = load_enum_rule("""( <$(EX)a> <$(EX)b> <$(EX)c> )"""; in_l = false)
    @test length(spec.enums["$(R)_c"]) == 3
    Jayhawk.update!("INSERT DATA { GRAPH <$RG> { <urn:p1> a <$(G)Person> } }")
    f = run_rule("$(R)E"; source = [RG])[1]
    @test f.count == 3                                  # one person x three values
    tags = Set((r["o"]::IRIRef).value
               for r in select("SELECT ?o WHERE { GRAPH <$(f.graph)> { ?s <$(EX)tag> ?o } }"))
    @test tags == Set(["$(EX)a", "$(EX)b", "$(EX)c"])
    undo_firing!(f.graph)
end

@testset "the other reading really constrains" begin
    # Same vocabulary, same VALUES clause; ?c is now bound by L as well, so the clause is a
    # join. Only the person whose region is in the enumeration should survive.
    spec = load_enum_rule("""( <$(EX)a> <$(EX)b> )"""; in_l = true)
    Jayhawk.update!("""INSERT DATA { GRAPH <$RG> {
        <urn:p1> a <$(G)Person> ; <$(EX)region> <$(EX)a> .
        <urn:p2> a <$(G)Person> ; <$(EX)region> <$(EX)zzz> . } }""")
    f = run_rule("$(R)E"; source = [RG])[1]
    subs = Set((r["s"]::IRIRef).value
               for r in select("SELECT ?s WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }"))
    @test subs == Set(["urn:p1"])                       # p2's region is not enumerated
    @test f.count == 1
    undo_firing!(f.graph)
end

@testset "FINDING -- an empty rdf:List is unreachable from the store" begin
    # check_enums refuses an empty enumeration, but load_enums only creates a dict entry
    # when the property path yields a value. gistp:oneOf () is rdf:nil, the path matches
    # nothing, and the variable comes back simply un-enumerated -- so the check cannot fire
    # on a rule that was loaded, only on one built in Julia.
    spec = load_enum_rule("()"; in_l = false)
    @test !haskey(spec.enums, "$(R)_c")                 # silently not an enumeration
    err = failure(() -> compile_rule(spec))
    @test err !== nothing                               # it still fails...
    msg = sprint(showerror, err)
    @info "gistp:oneOf () is diagnosed as" message = first(msg, 150)
    # ...but as use-before-def, which points the author at the wrong thing
    @test_broken occursin("never fire", msg)
end

@testset "duplicate members collapse" begin
    spec = load_enum_rule("""( <$(EX)a> <$(EX)a> <$(EX)b> )"""; in_l = false)
    @test length(spec.enums["$(R)_c"]) == 2             # VALUES is a set
    Jayhawk.update!("INSERT DATA { GRAPH <$RG> { <urn:p1> a <$(G)Person> } }")
    f = run_rule("$(R)E"; source = [RG])[1]
    @test f.count == 2
    undo_firing!(f.graph)
end

@testset "literal members survive the store round trip with their datatype" begin
    spec = load_enum_rule("""( "42"^^<http://www.w3.org/2001/XMLSchema#integer> "42" )""";
                          in_l = false)
    vals = spec.enums["$(R)_c"]
    @test length(vals) == 2                             # typed and plain are distinct terms
    @test any(v -> v isa RDFLiteral && v.datatype !== nothing, vals)
    @test any(v -> v isa RDFLiteral && v.datatype === nothing, vals)
end

scrub()
end
end
