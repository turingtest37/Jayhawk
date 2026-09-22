using Test

using Jayhawk
using URIs
using Logging

# Debug logging stays off unless it is asked for. This line used to read
# `ENV["JULIA_DEBUG"]=all`, where `all` is `Base.all` -- the function. It stringifies to
# "all", which is exactly the magic value JULIA_DEBUG wants, so it worked by accident
# and forced full @debug output on every run: ~63,000 lines burying the test summary.
#
# Julia reads JULIA_DEBUG from the environment on its own, so to turn it back on:
#     JULIA_DEBUG=Jayhawk julia --project=. test/runtests.jl
#
# The materialiser's tests -- RDF parsing, expand_uris, analyze/generate/install, TraceLog --
# moved to RdfMaterializer along with the code they exercise. Nothing here touches Serd.

@testset "RDFTerm keeps what Serd throws away" begin
    # The whole reason src/term.jl exists. Serd's Literal has one `langordt` field for two
    # mutually exclusive concepts and its parser never puts a datatype there at all, so
    # after parsing `"42"^^ex:custom` is byte-identical to plain `"42"`. That is fatal for
    # a rule engine whose variable marker *is* a datatype.

    @testset "custom datatypes survive and stay distinct" begin
        typed = RDFLiteral("42", "http://ex.org/custom")
        plain = RDFLiteral("42")
        @test typed.datatype == "http://ex.org/custom"
        @test plain.datatype === nothing
        @test typed != plain                      # the distinction Serd loses
        @test hash(typed) != hash(plain)
    end

    @testset "lexical form is never coerced" begin
        # "007"^^xsd:integer must not become 7: SPARQL matches on lexical form.
        l = RDFLiteral("007", "http://www.w3.org/2001/XMLSchema#integer")
        @test l.lexical == "007"
        @test sparql_text(l) == "\"007\"^^<http://www.w3.org/2001/XMLSchema#integer>"
    end

    @testset "RDF 1.1 normalisation" begin
        # a plain literal and one explicitly typed xsd:string are the same term
        @test RDFLiteral("a", Jayhawk.XSD_STRING) == RDFLiteral("a")
        # a language tag implies rdf:langString, so the datatype is dropped
        lang = RDFLiteral("hi", Jayhawk.RDF_LANGSTRING, "en")
        @test lang.language == "en"
        @test lang.datatype === nothing
        @test sparql_text(lang) == "\"hi\"@en"
    end

    @testset "term_from_json covers every binding shape" begin
        @test term_from_json(Dict("type" => "uri", "value" => "http://ex.org/s")) ==
            IRIRef("http://ex.org/s")
        @test term_from_json(Dict("type" => "bnode", "value" => "b0")) == BNode("b0")
        @test term_from_json(Dict("type" => "literal", "value" => "plain")) ==
            RDFLiteral("plain")
        @test term_from_json(
            Dict("type" => "literal", "value" => "42", "datatype" => "http://ex.org/dt")
        ) == RDFLiteral("42", "http://ex.org/dt")
        @test term_from_json(
            Dict("type" => "literal", "value" => "hi", "xml:lang" => "en")
        ) == RDFLiteral("hi", nothing, "en")
        # "typed-literal" is not in the JSON spec but some stores still emit it
        @test term_from_json(
            Dict(
                "type" => "typed-literal", "value" => "1", "datatype" => "http://ex.org/dt"
            ),
        ).datatype == "http://ex.org/dt"
        @test_throws ArgumentError term_from_json(Dict("type" => "wat", "value" => "x"))
        @test_throws ArgumentError term_from_json(Dict("type" => "uri"))
    end

    @testset "serialisation escapes and stays absolute" begin
        @test sparql_text(IRIRef("http://ex.org/s")) == "<http://ex.org/s>"
        @test sparql_text(BNode("b1")) == "_:b1"
        @test sparql_text(RDFLiteral("say \"hi\"\n")) == "\"say \\\"hi\\\"\\n\""
        @test sparql_text(RDFLiteral("back\\slash")) == "\"back\\\\slash\""
        # an IRI that cannot be written inside <> must be refused, not silently emitted
        @test_throws ArgumentError check_iri("http://ex.org/a b")
        @test_throws ArgumentError check_iri("http://ex.org/<x>")
        @test check_iri("http://ex.org/ok") == "http://ex.org/ok"
    end

    @testset "gistp:var literals are recognised" begin
        v = RDFLiteral("?idText", Jayhawk.GISTP_VAR)
        @test is_var_literal(v)
        @test var_name(v) == "?idText"
        @test !is_var_literal(RDFLiteral("?idText"))          # untyped: just a string
        @test !is_var_literal(IRIRef("http://ex.org/s"))
        @test_throws ArgumentError var_name(RDFLiteral("?x"))  # not typed gistp:var

        # The vocabulary's own XSD facet is `^[?$][a-zA-Z_]+`, which is wrong twice:
        # in XSD regex ^ and $ are literal characters, not anchors, and [a-zA-Z_]+
        # rejects the digit in ?_Person_1. gistPatternShapes.ttl has the correct form.
        @test var_name(RDFLiteral("?_Person_1", Jayhawk.GISTP_VAR)) == "?_Person_1"
        @test var_name(RDFLiteral("\$dollar", Jayhawk.GISTP_VAR)) == "\$dollar"
        @test_throws ArgumentError var_name(RDFLiteral("noSigil", Jayhawk.GISTP_VAR))
        @test_throws ArgumentError var_name(RDFLiteral("?has space", Jayhawk.GISTP_VAR))
        @test_throws ArgumentError var_name(
            RDFLiteral("?1startsWithDigit", Jayhawk.GISTP_VAR)
        )
    end
end

@testset "compiler (pure)" begin
    # compile_rule is a pure function of a RuleSpec, so the whole of it is testable with
    # no server running. These specs are built by hand; loading one out of a store is
    # exercised in test/sparql_integration.jl.
    G = "https://w3id.org/semanticarts/ns/ontology/gist/"
    HR = "http://example.org/hr/"
    R = "http://example.org/rules/"
    TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

    iri(s) = IRIRef(s)
    var(s) = RDFLiteral(s, Jayhawk.GISTP_VAR)

    person_to_employee(; mode=Jayhawk.MODE_CONSTRUCT) = RuleSpec(
        "$(R)PersonToEmployee",
        mode,
        "$(R)PersonToEmployee_L",
        "$(R)PersonToEmployee_R",
        [
            PatternTriple(iri("$(R)_Person_1"), iri(TYPE), iri("$(G)Person")),
            PatternTriple(
                iri("$(R)_Person_1"), iri("$(G)isIdentifiedBy"), iri("$(R)_ID_1")
            ),
            PatternTriple(iri("$(R)_ID_1"), iri(TYPE), iri("$(G)ID")),
            PatternTriple(iri("$(R)_ID_1"), iri("$(G)containedText"), var("?idText")),
        ],
        [
            PatternTriple(iri("$(R)_Person_1"), iri(TYPE), iri("$(HR)Employee")),
            PatternTriple(iri("$(R)_Person_1"), iri("$(HR)employeeNumber"), var("?idText")),
        ],
        Dict("$(R)_Person_1" => "?_Person_1", "$(R)_ID_1" => "?_ID_1"),
        Dict{String,MintSpec}(),
    )

    @testset "golden snapshot" begin
        # Byte-for-byte. Terms are emitted as absolute IRIs, so the output never depends on
        # a PREFIX declaration or on the global prefix registry.
        expected = """
        # Construct rule <http://example.org/rules/PersonToEmployee>
        CONSTRUCT {
          ?_Person_1 <http://example.org/hr/employeeNumber> ?idText .
          ?_Person_1 <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://example.org/hr/Employee> .
        }
        WHERE {
          ?_ID_1 <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <https://w3id.org/semanticarts/ns/ontology/gist/ID> .
          ?_ID_1 <https://w3id.org/semanticarts/ns/ontology/gist/containedText> ?idText .
          ?_Person_1 <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <https://w3id.org/semanticarts/ns/ontology/gist/Person> .
          ?_Person_1 <https://w3id.org/semanticarts/ns/ontology/gist/isIdentifiedBy> ?_ID_1 .
        }
        """
        # note: patterns are sorted on load, so build the spec in sorted order to compare
        spec = person_to_employee()
        sorted = RuleSpec(
            spec.iri,
            spec.mode,
            spec.match_graph,
            spec.construct_graph,
            sort(
                spec.match;
                by=t -> (
                    sparql_text(t.subject),
                    sparql_text(t.predicate),
                    sparql_text(t.object),
                ),
            ),
            sort(
                spec.construct;
                by=t -> (
                    sparql_text(t.subject),
                    sparql_text(t.predicate),
                    sparql_text(t.object),
                ),
            ),
            spec.variables,
            spec.mints,
        )
        @test compile_rule(sorted) == expected
    end

    @testset "both variable mechanisms resolve" begin
        spec = person_to_employee()
        # IRI position: a declared individual, resolved by RDF identity
        @test var_of(iri("$(R)_Person_1"), spec) == "?_Person_1"
        # literal position: no declaration anywhere, recognised only by ^^gistp:var
        @test var_of(var("?idText"), spec) == "?idText"
        # constants stay constants
        @test var_of(iri("$(G)Person"), spec) === nothing
        @test var_of(RDFLiteral("?idText"), spec) === nothing   # untyped: a plain string
        @test term_sparql(iri("$(G)Person"), spec) == "<$(G)Person>"
        @test term_sparql(RDFLiteral("plain"), spec) == "\"plain\""
    end

    @testset "Construct and Assert emit identical SPARQL" begin
        # The whole point of the mode split: one compiler, two drivers. Only the leading
        # comment differs, so compare the bodies.
        body(s) = join(filter(l -> !startswith(l, "#"), split(compile_rule(s), "\n")), "\n")
        @test body(person_to_employee(mode=Jayhawk.MODE_CONSTRUCT)) ==
            body(person_to_employee(mode=Jayhawk.MODE_ASSERT))
    end

    @testset "the interface I = L ∩ R is plain set arithmetic" begin
        # The payoff of persistent typed variables: two pattern triples denote the same
        # thing exactly when they are the same RDF triple. No unification, no
        # alpha-equivalence.
        spec = person_to_employee()
        # PersonToEmployee shares no *triple* between L and R -- only the node :_Person_1 --
        # so its triple-level interface is empty. That is why it is a Construct rule and
        # would be a bug as a Rewrite: everything in L would be deleted.
        @test isempty(interface(spec))
        @test length(match_only(spec)) == length(spec.match)
        @test length(construct_only(spec)) == length(spec.construct)

        # repeat one triple of L in R and it moves into I
        shared = spec.match[1]
        withI = RuleSpec(
            spec.iri,
            spec.mode,
            spec.match_graph,
            spec.construct_graph,
            spec.match,
            vcat(spec.construct, [shared]),
            spec.variables,
            spec.mints,
        )
        @test length(interface(withI)) == 1
        @test length(match_only(withI)) == length(spec.match) - 1
        @test length(construct_only(withI)) == length(spec.construct)
        # I ∪ (L∖I) partitions L, with no overlap
        @test length(interface(withI)) + length(match_only(withI)) == length(withI.match)
    end

    @testset "Rewrite compiles to DELETE L∖I / INSERT R∖I" begin
        spec = person_to_employee(mode=Jayhawk.MODE_REWRITE)
        shared = spec.match[1]                     # ?_Person_1 a gist:Person
        rw = RuleSpec(
            spec.iri,
            spec.mode,
            spec.match_graph,
            spec.construct_graph,
            spec.match,
            vcat(spec.construct, [shared]),
            spec.variables,
            spec.mints,
        )
        q = compile_rule(rw)
        @test occursin("DELETE {", q) && occursin("INSERT {", q)
        @test !occursin("CONSTRUCT", q)
        # the preserved triple appears in WHERE but in neither DELETE nor INSERT
        preserved = "?_Person_1 <$(TYPE)> <$(G)Person> ."
        delete_block = q[findfirst("DELETE {", q).start:findfirst("INSERT {", q).start]
        @test !occursin(preserved, delete_block)
        @test occursin(preserved, q)               # still matched
        @test q == compile_rule(rw)                # byte-stable
    end

    @testset "a rewrite that changes nothing is refused" begin
        spec = person_to_employee(mode=Jayhawk.MODE_REWRITE)
        identical = RuleSpec(
            spec.iri,
            spec.mode,
            spec.match_graph,
            spec.construct_graph,
            spec.match,
            spec.match,
            spec.variables,
            spec.mints,
        )
        @test isempty(match_only(identical)) && isempty(construct_only(identical))
        err = try
            rewrite_query(identical; target="urn:t", firing="urn:f", tombstone="urn:tomb")
        catch e
            e
        end
        @test occursin("deletes nothing and adds nothing", sprint(showerror, err))
    end

    @testset "insert_query refuses a Rewrite, and rewrite_query refuses the others" begin
        rw = person_to_employee(mode=Jayhawk.MODE_REWRITE)
        @test occursin(
            "rewrite_query", sprint(
                showerror,
                try
                    insert_query(rw; into="urn:g")
                catch e
                    e
                end,
            )
        )
        @test occursin(
            "insert_query",
            sprint(
                showerror,
                try
                    rewrite_query(
                        person_to_employee();
                        target="urn:t",
                        firing="urn:f",
                        tombstone="urn:tomb",
                    )
                catch e
                    e
                end,
            ),
        )
    end

    @testset "the dangling risk is detected, not silently deleted" begin
        # SPARQL Update is single-pushout: it deletes what it is told and never checks for
        # stranded referents. A variable whose every occurrence in L is removed, and which R
        # never mentions, is exactly the shape that leaves orphans.
        spec = person_to_employee(mode=Jayhawk.MODE_REWRITE)
        shared = spec.match[1]
        rw = RuleSpec(
            spec.iri,
            spec.mode,
            spec.match_graph,
            spec.construct_graph,
            spec.match,
            vcat(spec.construct, [shared]),
            spec.variables,
            spec.mints,
        )
        # ?_ID_1 loses both of its triples and appears nowhere in R
        @test "?_ID_1" in dangling_risks(rw)
        # ?_Person_1 survives -- one of its triples is preserved, and R uses it
        @test !("?_Person_1" in dangling_risks(rw))
        # a rule that preserves everything strands nothing
        @test isempty(
            dangling_risks(
                RuleSpec(
                    spec.iri,
                    spec.mode,
                    spec.match_graph,
                    spec.construct_graph,
                    spec.match,
                    spec.match,
                    spec.variables,
                    spec.mints,
                ),
            ),
        )
    end

    @testset "rewrite_query records what it removes" begin
        spec = person_to_employee(mode=Jayhawk.MODE_REWRITE)
        shared = spec.match[1]
        rw = RuleSpec(
            spec.iri,
            spec.mode,
            spec.match_graph,
            spec.construct_graph,
            spec.match,
            vcat(spec.construct, [shared]),
            spec.variables,
            spec.mints,
        )
        q = rewrite_query(
            rw; target="urn:t", firing="urn:f", tombstone="urn:tomb", from=["urn:t"]
        )
        @test occursin("DELETE {\n  GRAPH <urn:t>", q)
        @test occursin("GRAPH <urn:f>", q)         # what was added
        @test occursin("GRAPH <urn:tomb>", q)      # what was removed -- undo needs this
        @test occursin("USING <urn:t>", q)
        # the tombstone template is exactly L∖I
        @test occursin(bgp_text(match_only(rw), rw; indent="    "), q)
    end

    @testset "unknown mode is refused" begin
        @test_throws ArgumentError compile_rule(
            person_to_employee(mode="http://ex.org/Nope")
        )
    end

    @testset "use-before-def: a typo in a literal variable is caught" begin
        # The failure an LLM author hits most: literal-position variables are matched across
        # L and R by string equality of the lexical form, so ?idtext against ?idText is a
        # name error nowhere -- it just silently constructs nothing.
        spec = person_to_employee()
        typo = RuleSpec(
            spec.iri,
            spec.mode,
            spec.match_graph,
            spec.construct_graph,
            spec.match,
            [
                PatternTriple(
                    iri("$(R)_Person_1"), iri("$(HR)employeeNumber"), var("?idtext")
                ),
            ],
            spec.variables,
            spec.mints,
        )
        err = try
            compile_rule(typo)
        catch e
            e
        end
        msg = sprint(showerror, err)
        @test occursin("?idtext", msg)
        @test occursin("never binds", msg)
        @test occursin("typo", msg)
    end

    # ---------------------------------------------------------------------
    # Minting: gistp:iriTemplate + gistp:hasSlot
    # ---------------------------------------------------------------------

    # The rule from example_minting_rule.trig: a Person with an identifier gets a NEW
    # Employee record node, minted from the identifier text.
    minting_rule(;
        template="http://example.org/hr/employee/{id}",
        slots=Dict{String,RDFTerm}("id" => var("?idText")),
        extra_match=PatternTriple[],
    ) = RuleSpec(
        "$(R)PersonToEmployeeRecord",
        Jayhawk.MODE_ASSERT,
        "$(R)PersonToEmployeeRecord_L",
        "$(R)PersonToEmployeeRecord_R",
        vcat(
            [
                PatternTriple(iri("$(R)_Person_1"), iri(TYPE), iri("$(G)Person")),
                PatternTriple(
                    iri("$(R)_Person_1"), iri("$(G)isIdentifiedBy"), iri("$(R)_ID_1")
                ),
                PatternTriple(iri("$(R)_ID_1"), iri(TYPE), iri("$(G)ID")),
                PatternTriple(iri("$(R)_ID_1"), iri("$(G)containedText"), var("?idText")),
            ],
            extra_match,
        ),
        [
            PatternTriple(iri("$(R)_Employee_1"), iri(TYPE), iri("$(HR)Employee")),
            PatternTriple(
                iri("$(R)_Employee_1"), iri("$(HR)employeeNumber"), var("?idText")
            ),
            PatternTriple(
                iri("$(R)_Employee_1"), iri("$(HR)isRecordFor"), iri("$(R)_Person_1")
            ),
        ],
        Dict(
            "$(R)_Person_1" => "?_Person_1",
            "$(R)_ID_1" => "?_ID_1",
            "$(R)_Employee_1" => "?_Employee_1",
        ),
        Dict("$(R)_Employee_1" => MintSpec("$(R)_Employee_1", template, slots)),
    )

    @testset "template parsing is RFC 6570 Level 1" begin
        @test parse_template("http://ex.org/e/{id}") ==
            [(:lit, "http://ex.org/e/"), (:slot, "id")]
        @test parse_template("http://ex.org/{a}/x/{b}") ==
            [(:lit, "http://ex.org/"), (:slot, "a"), (:lit, "/x/"), (:slot, "b")]
        @test parse_template("http://ex.org/plain") == [(:lit, "http://ex.org/plain")]
        @test template_slots("http://ex.org/{a}/{b}") == ["a", "b"]

        # Level 2 and above are refused rather than approximated: STR() alone is *more*
        # permissive than Level 2 specifies, so shipping it under the RFC's name would lie.
        for op in ("+", "#", ".", "/", ";", "?", "&")
            err = try
                parse_template("http://ex.org/{$(op)id}")
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("Level 1", sprint(showerror, err))
        end
        @test_throws ArgumentError parse_template("http://ex.org/{unterminated")
        @test_throws ArgumentError parse_template("http://ex.org/unmatched}")
        @test_throws ArgumentError parse_template("http://ex.org/{}")
    end

    @testset "a minting rule compiles to BIND" begin
        q = compile_rule(minting_rule())
        @test occursin(
            "BIND(IRI(CONCAT(\"http://example.org/hr/employee/\", " *
            "ENCODE_FOR_URI(STR(?idText)))) AS ?_Employee_1)",
            q,
        )
        # the BIND comes after every triple pattern: BIND only sees variables bound
        # earlier in its group
        @test findfirst("BIND", q).start > findlast("?_Person_1 <", q).start
        # and ?_Employee_1 is used in the CONSTRUCT template
        @test occursin("?_Employee_1 <$(HR)employeeNumber> ?idText", q)
        # compiling twice is byte-identical
        @test q == compile_rule(minting_rule())
    end

    @testset "a minted variable is bound, so use-before-def does not fire" begin
        # ?_Employee_1 appears only in R. It is bound by the emitted BIND, not by a triple
        # pattern, so check_bound must count it as available.
        spec = minting_rule()
        @test "?_Employee_1" in minted_vars(spec)
        @test !("?_Employee_1" in vars_in(spec.match, spec))
        @test check_bound(spec) === spec
    end

    @testset "a minted variable must not also be matched" begin
        # Carrying a template declares a variable constructed. Being matched as well is a
        # contradiction -- and it is exactly the dead template that sat on :_Person_1.
        spec = minting_rule(
            extra_match=[
                PatternTriple(iri("$(R)_Employee_1"), iri(TYPE), iri("$(HR)Employee"))
            ],
        )
        err = try
            compile_rule(spec)
        catch e
            e
        end
        msg = sprint(showerror, err)
        @test occursin("declares it minted", msg)
        @test occursin("?_Employee_1", msg)
    end

    @testset "a relative template is refused" begin
        # ":_Employee_{id}" would mint into whatever the rule document's empty prefix names
        # -- for a rules file, the rules namespace.
        err = try
            compile_rule(minting_rule(template=":_Employee_{id}"))
        catch e
            e
        end
        msg = sprint(showerror, err)
        @test occursin("relative", msg)
        @test occursin("absolute IRI", msg)
    end

    @testset "unbound and unknown slots are refused" begin
        # a {slot} the template has but nothing binds
        err = try
            compile_rule(minting_rule(template="http://ex.org/e/{id}/{missing}"))
        catch e
            e
        end
        @test occursin("{missing}", sprint(showerror, err))

        # a binding naming a slot the template does not contain -- a half-applied rename
        err = try
            compile_rule(
                minting_rule(
                    slots=Dict{String,RDFTerm}(
                        "id" => var("?idText"), "stale" => var("?idText")
                    ),
                ),
            )
        catch e
            e
        end
        @test occursin("stale", sprint(showerror, err))

        # a template with no bindings at all
        err = try
            compile_rule(minting_rule(slots=Dict{String,RDFTerm}()))
        catch e
            e
        end
        @test occursin("{id}", sprint(showerror, err))
    end

    @testset "a slot value must be bound by L" begin
        # minting from a variable L never binds -- including from another minted variable,
        # which would need the BINDs topologically ordered
        err = try
            compile_rule(minting_rule(slots=Dict{String,RDFTerm}("id" => var("?nowhere"))))
        catch e
            e
        end
        msg = sprint(showerror, err)
        @test occursin("?nowhere", msg)
        @test occursin("never binds", msg)

        # and a slot bound to something that is not a variable at all
        err = try
            compile_rule(
                minting_rule(
                    slots=Dict{String,RDFTerm}("id" => RDFLiteral("just a string"))
                ),
            )
        catch e
            e
        end
        @test occursin("not a variable", sprint(showerror, err))
    end

    @testset "ambiguous slot separators are refused" begin
        # In RDF an IRI *is* the identity, so two distinct binding tuples expanding to one
        # IRI silently merges two things into one node. ENCODE_FOR_URI leaves the unreserved
        # set alone, so a separator drawn from it cannot be told apart from the same
        # characters inside a value: "x_y"+"z" and "x"+"y_z" both give x_y_z.
        @test ambiguous_separators("http://ex.org/{a}_{b}") == ["_"]
        @test ambiguous_separators("http://ex.org/{a}{b}") == [""]     # adjacent slots
        @test ambiguous_separators("http://ex.org/{a}-{b}.{c}") == ["-", "."]
        # a separator the encoder escapes is unambiguous: values containing it get %2F
        @test isempty(ambiguous_separators("http://ex.org/{a}/{b}"))
        # single-slot templates are always safe, and fixed prefixes/suffixes never collide
        # because they are identical for every binding
        @test isempty(ambiguous_separators("http://ex.org/one/{a}"))
        @test isempty(ambiguous_separators("http://ex.org/{a}_end"))

        two_slot(sep) = minting_rule(
            template="http://example.org/hr/employee/{id}$(sep){b}",
            slots=Dict{String,RDFTerm}("id" => var("?idText"), "b" => var("?idText")),
        )
        err = try
            compile_rule(two_slot("_"))
        catch e
            e
        end
        msg = sprint(showerror, err)
        @test occursin("x_y_z", msg)              # names the concrete failure
        @test occursin("'/'", msg)                # and the fix
        @test compile_rule(two_slot("/")) isa String
    end

    @testset "the collision query is built but provably vacuous for Level 1" begin
        # ENCODE_FOR_URI is injective and a reserved separator cannot appear raw in an
        # encoded value -- even a literal "%2F" double-encodes to "%252F" -- so with the
        # separator lint in place no two distinct slot tuples can produce one IRI. The query
        # is kept and wired in because it stops being vacuous the moment a lossy encoding
        # (slugging) exists.
        spec = minting_rule()
        qs = collision_queries(spec; from=["urn:g"])
        @test length(qs) == 1
        minted_iri, q = qs[1]
        @test minted_iri == "$(R)_Employee_1"
        @test occursin("GROUP BY ?_Employee_1", q)
        @test occursin("HAVING (COUNT(DISTINCT ?__key) > 1)", q)
        @test occursin("FROM <urn:g>", q)
        # the tuple key separates encoded values with a raw space, which cannot occur inside
        # one because ENCODE_FOR_URI turns a space into %20
        @test occursin("BIND(CONCAT(ENCODE_FOR_URI(STR(?idText))) AS ?__key)", q)
        # no mints, no query
        @test isempty(collision_queries(person_to_employee()))
    end

    @testset "a slot value may name an IRI-position variable" begin
        # A slot value always names a variable; what it mints FROM is chosen by naming a
        # different one. Naming :_ID_1 mints from that node's IRI rather than from an
        # identifier's text -- a different rule, but a legal one.
        q = compile_rule(minting_rule(slots=Dict{String,RDFTerm}("id" => iri("$(R)_ID_1"))))
        @test occursin("ENCODE_FOR_URI(STR(?_ID_1))", q)
    end

    # ---------------------------------------------------------------------
    # gistp:oneOf -- one VALUES clause, two readings
    # ---------------------------------------------------------------------

    with_enums(spec, enums) = RuleSpec(
        spec.iri,
        spec.mode,
        spec.match_graph,
        spec.construct_graph,
        spec.match,
        spec.construct,
        spec.variables,
        spec.mints,
        enums,
        spec.nacs,
        spec.strategy,
        spec.priority,
        spec.max_iterations,
    )

    @testset "oneOf emits VALUES, sorted and byte-stable" begin
        spec = with_enums(
            person_to_employee(),
            Dict("$(R)_ID_1" => RDFTerm[iri("$(G)c"), iri("$(G)a"), iri("$(G)b")]),
        )
        q = compile_rule(spec)
        # sorted, not in authored order: VALUES is a set of solutions, so authored order
        # carries no meaning and sorting is what keeps output byte-stable
        @test occursin("VALUES ?_ID_1 { <$(G)a> <$(G)b> <$(G)c> }", q)
        @test q == compile_rule(spec)
    end

    @testset "the same clause constrains or generates, decided by the rest of the rule" begin
        # constrain: the variable is ALSO bound by L, so the clause is a join
        constrain = with_enums(
            person_to_employee(), Dict("$(R)_ID_1" => RDFTerm[iri("$(G)a")])
        )
        # generate: a variable that appears only in R, bound by nothing but its VALUES
        base = person_to_employee()
        gen = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            [PatternTriple(iri("$(R)_Person_1"), iri("$(HR)tag"), iri("$(R)_Tag"))],
            merge(base.variables, Dict("$(R)_Tag" => "?_Tag")),
            base.mints,
            Dict("$(R)_Tag" => RDFTerm[RDFLiteral("x"), RDFLiteral("y")]),
            base.nacs,
            base.strategy,
            base.priority,
            base.max_iterations,
        )

        # one code path: both are a bare VALUES clause in the WHERE, nothing else
        @test occursin("VALUES ?_ID_1 {", compile_rule(constrain))
        @test occursin("VALUES ?_Tag { \"x\" \"y\" }", compile_rule(gen))
        # and the generating one compiles at all, which is the real assertion: ?_Tag is
        # bound by nothing in the match pattern, so without enum_vars in the bound set
        # check_bound would reject it as use-before-def
        @test "?_Tag" in enum_vars(gen)
        @test !("?_Tag" in vars_in(gen.match, gen))
        @test check_bound(gen) === gen
    end

    @testset "VALUES precedes the BIND that may consume it" begin
        # a template may mint from an enumerated value, so the ordering is load-bearing
        spec = minting_rule()
        withv = with_enums(spec, Dict("$(R)_ID_1" => RDFTerm[iri("$(G)a")]))
        q = compile_rule(withv)
        @test findfirst("VALUES", q).start < findfirst("BIND(", q).start
    end

    @testset "a mint may take its slot from an enumeration" begin
        base = minting_rule()
        gen = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            merge(base.variables, Dict("$(R)_Reg" => "?_Reg")),
            Dict(
                "$(R)_Employee_1" => MintSpec(
                    "$(R)_Employee_1",
                    "http://example.org/hr/employee/{id}/{reg}",
                    Dict{String,RDFTerm}("id" => var("?idText"), "reg" => iri("$(R)_Reg")),
                ),
            ),
            Dict("$(R)_Reg" => RDFTerm[RDFLiteral("EU"), RDFLiteral("US")]),
            base.nacs,
            base.strategy,
            base.priority,
            base.max_iterations,
        )
        q = compile_rule(gen)
        @test occursin("ENCODE_FOR_URI(STR(?_Reg))", q)
        @test findfirst("VALUES ?_Reg", q).start < findfirst("BIND(", q).start
    end

    @testset "broken enumerations are refused" begin
        spec = person_to_employee()
        # an empty list yields no solutions, so the rule can never fire
        empty = with_enums(spec, Dict("$(R)_ID_1" => RDFTerm[]))
        @test occursin("never fire", sprint(
            showerror,
            try
                compile_rule(empty)
            catch e
                e
            end,
        ))

        # enumerated AND constructed is contradictory
        both = with_enums(
            minting_rule(), Dict("$(R)_Employee_1" => RDFTerm[RDFLiteral("a")])
        )
        @test occursin("Choose one", sprint(
            showerror,
            try
                compile_rule(both)
            catch e
                e
            end,
        ))

        # no variableText, so there is no SPARQL variable for VALUES to bind
        noname = with_enums(spec, Dict("$(R)_undeclared" => RDFTerm[RDFLiteral("a")]))
        @test occursin("no gistp:variableText", sprint(
            showerror,
            try
                compile_rule(noname)
            catch e
                e
            end,
        ))
    end

    @testset "empty patterns are refused" begin
        spec = person_to_employee()
        empty_l = RuleSpec(
            spec.iri,
            spec.mode,
            spec.match_graph,
            spec.construct_graph,
            PatternTriple[],
            spec.construct,
            spec.variables,
            spec.mints,
        )
        # an empty L binds nothing, so use-before-def fires first -- either way it is refused
        @test_throws Exception compile_rule(empty_l)
    end

    # ---------------------------------------------------------------------
    # Control layer: negative conditions, strategy, budget
    # ---------------------------------------------------------------------

    nac(triples...) = NacSpec("$(R)Probe_N", collect(PatternTriple, triples))

    with_control(;
        nacs=NacSpec[],
        strategy=nothing,
        priority=0,
        max_iterations=nothing,
        mode=Jayhawk.MODE_CONSTRUCT,
    ) = (
        s=person_to_employee(mode=mode);
        RuleSpec(
            s.iri,
            s.mode,
            s.match_graph,
            s.construct_graph,
            s.match,
            s.construct,
            s.variables,
            s.mints,
            nacs,
            strategy,
            priority,
            max_iterations,
        )
    )

    @testset "a negative condition becomes FILTER NOT EXISTS" begin
        s = with_control(
            nacs=[nac(PatternTriple(iri("$(R)_Person_1"), iri(TYPE), iri("$(HR)Employee")))]
        )
        q = compile_rule(s)
        @test occursin("FILTER NOT EXISTS {", q)
        @test occursin("?_Person_1 <$(TYPE)> <$(HR)Employee> .", q)
        # the guard names the graph it came from, so a reader can find it
        @test occursin("# NOT <$(R)Probe_N>", q)
    end

    @testset "several conditions are conjunctive, not one big block" begin
        # Each must fail independently. One filter containing both triples would instead
        # mean "not (A and B)", which is a strictly weaker guard.
        a = NacSpec(
            "$(R)N1", [PatternTriple(iri("$(R)_Person_1"), iri(TYPE), iri("$(HR)Employee"))]
        )
        b = NacSpec(
            "$(R)N2", [PatternTriple(iri("$(R)_ID_1"), iri(TYPE), iri("$(HR)Employee"))]
        )
        q = compile_rule(with_control(nacs=[a, b]))
        @test length(collect(eachmatch(r"FILTER NOT EXISTS \{", q))) == 2
    end

    @testset "an empty condition is skipped, not emitted" begin
        # FILTER NOT EXISTS { } can never fail, so emitting one would silently disable the
        # rule -- the worst possible reading of "the author left this graph empty".
        q = compile_rule(with_control(nacs=[NacSpec("$(R)Empty", PatternTriple[])]))
        @test !occursin("FILTER NOT EXISTS", q)
    end

    @testset "the WHERE body orders match, then BIND, then filters" begin
        # Load-bearing: BIND sees only what precedes it, and a condition may mention a
        # MINTED variable -- which is how a rule says "only create this if it is not there".
        s = minting_rule()
        guarded = RuleSpec(
            s.iri,
            s.mode,
            s.match_graph,
            s.construct_graph,
            s.match,
            s.construct,
            s.variables,
            s.mints,
            [
                NacSpec(
                    "$(R)N",
                    [
                        PatternTriple(
                            iri("$(R)_Employee_1"), iri(TYPE), iri("$(HR)Employee")
                        ),
                    ],
                ),
            ],
            nothing,
            0,
            nothing,
        )
        body = where_body(guarded)
        @test findfirst("?_ID_1 <", body).start <
            findfirst("BIND(", body).start <
            findfirst("FILTER NOT EXISTS", body).start
        # and the guard really does reference the minted variable
        @test occursin("FILTER NOT EXISTS {\n    ?_Employee_1", body)
    end

    @testset "every query builder carries the conditions" begin
        # There are several places that assemble a WHERE. A guard honoured by only some of
        # them means the thing that executes is not the thing that was reviewed.
        s = minting_rule()
        guarded = RuleSpec(
            s.iri,
            s.mode,
            s.match_graph,
            s.construct_graph,
            s.match,
            s.construct,
            s.variables,
            s.mints,
            [
                NacSpec(
                    "$(R)N",
                    [
                        PatternTriple(
                            iri("$(R)_Employee_1"), iri(TYPE), iri("$(HR)Employee")
                        ),
                    ],
                ),
            ],
            nothing,
            0,
            nothing,
        )
        @test occursin("FILTER NOT EXISTS", compile_rule(guarded))
        @test occursin("FILTER NOT EXISTS", insert_query(guarded; into="urn:g"))
        @test occursin(
            "FILTER NOT EXISTS",
            project_query(guarded; triples=guarded.construct, into="urn:g"),
        )
        @test all(occursin("FILTER NOT EXISTS", q) for (_, q) in collision_queries(guarded))
    end

    # ---------------------------------------------------------------------
    # Filter conditions: the scalar tests a BGP cannot express
    # ---------------------------------------------------------------------

    with_filters(fs...; mode=Jayhawk.MODE_CONSTRUCT) = (
        s=person_to_employee(mode=mode);
        RuleSpec(
            s.iri,
            s.mode,
            s.match_graph,
            s.construct_graph,
            s.match,
            s.construct,
            s.variables,
            s.mints,
            Dict{String,Vector{RDFTerm}}(),
            NacSpec[],
            nothing,
            0,
            nothing,
            nothing,
            nothing,
            Dict{String,Vector{Pair{String,String}}}(),
            collect(String, fs),
        )
    )

    refusal(spec) = sprint(
        showerror,
        try
            compile_rule(spec)
        catch e
            e
        end,
    )

    @testset "a filter condition becomes FILTER(...)" begin
        q = compile_rule(with_filters("?_Person_1 != ?_ID_1"))
        @test occursin("FILTER(?_Person_1 != ?_ID_1)", q)
        # and not the guard form -- a comparison is not an absence
        @test !occursin("FILTER NOT EXISTS", q)
    end

    @testset "several filters are conjunctive, one FILTER each" begin
        # Same reasoning as the negative conditions: separate filters is what "all of
        # these must hold" means, and one failing expression stays readable in a log.
        q = compile_rule(with_filters("?_Person_1 != ?_ID_1", "STRLEN(?idText) > 3"))
        @test length(collect(eachmatch(r"FILTER\(", q))) == 2
    end

    @testset "filters are sorted, so compiled text is byte-stable" begin
        # Conditions may be authored as blank nodes, which have no stable identity. Sorting
        # on the text is what makes two loads of one file compile to the same bytes.
        @test compile_rule(with_filters("?_ID_1 != ?_Person_1", "STRLEN(?idText) > 3")) ==
            compile_rule(with_filters("STRLEN(?idText) > 3", "?_ID_1 != ?_Person_1"))
    end

    @testset "a filter may test a literal-position variable" begin
        # ?idText is declared nowhere: it is a "?x"^^gistp:var literal inside L, matched
        # across L and R by lexical form. A filter has to see it too.
        @test occursin(
            "FILTER(CONTAINS(?idText, \"42\"))",
            compile_rule(with_filters("CONTAINS(?idText, \"42\")")),
        )
    end

    @testset "a filter over an unbound variable is refused" begin
        # SPARQL does not error here -- the expression errors, the solution is dropped, and
        # the rule quietly matches nothing. A typo must not be able to turn a rule off.
        msg = refusal(with_filters("?_Persn_1 != ?_ID_1"))
        @test occursin("?_Persn_1", msg)
        @test occursin("never binds", msg)
    end

    @testset "a filter cannot smuggle syntax past the compiler" begin
        # The one place author-supplied text is spliced into a query. Each of these would
        # escape the FILTER the compiler wraps the expression in.
        @test occursin(
            "could open a group",
            refusal(with_filters("1=1) } INSERT { <urn:x> <urn:p> 1 } WHERE {")),
        )
        @test occursin("starts a comment", refusal(with_filters("1=1 #")))
        @test occursin("update request", refusal(with_filters("1=1 ; DROP ALL")))
        @test occursin("never opened", refusal(with_filters("1=1)")))
        @test occursin("parenthesis", refusal(with_filters("CONTAINS(?idText")))
        @test occursin("unterminated", refusal(with_filters("CONTAINS(?idText, \"x)")))
    end

    @testset "a character inside a string literal is data, not syntax" begin
        # The checks scan a skeleton with literals blanked out, so an honest expression
        # mentioning a brace or a hash is not refused for it.
        q = compile_rule(with_filters("CONTAINS(?idText, \"}#;\")"))
        @test occursin("FILTER(CONTAINS(?idText, \"}#;\"))", q)
    end

    @testset "an empty filter is refused rather than emitted" begin
        # FILTER() is a syntax error, and FILTER(true) would silently do nothing -- the
        # same trap `an empty condition is skipped` avoids on the guard side.
        @test occursin("empty gistp:filterText", refusal(with_filters("   ")))
    end

    @testset "filters follow the BINDs, and every builder carries them" begin
        # A filter may test a MINTED variable, so it has to come after the BIND that
        # constructs it -- and a filter honoured by only some query builders means the
        # thing that executes is not the thing that was reviewed.
        s = minting_rule()
        filtered = RuleSpec(
            s.iri,
            s.mode,
            s.match_graph,
            s.construct_graph,
            s.match,
            s.construct,
            s.variables,
            s.mints,
            Dict{String,Vector{RDFTerm}}(),
            NacSpec[],
            nothing,
            0,
            nothing,
            nothing,
            nothing,
            Dict{String,Vector{Pair{String,String}}}(),
            ["STRLEN(STR(?_Employee_1)) > 0"],
        )
        body = where_body(filtered)
        @test findfirst("BIND(", body).start < findfirst("FILTER(", body).start
        @test occursin("FILTER(", compile_rule(filtered))
        @test occursin("FILTER(", insert_query(filtered; into="urn:g"))
        @test occursin(
            "FILTER(", project_query(filtered; triples=filtered.construct, into="urn:g")
        )
    end

    @testset "a rule with no filters compiles exactly as before" begin
        # The whole control layer is additive: an existing rule's bytes must not move.
        @test compile_rule(with_filters()) == compile_rule(person_to_employee())
    end

    # ---------------------------------------------------------------------
    # Filter conditions, part two: does the emitted text conform to SPARQL 1.1?
    #
    # Every claim below was checked against Apache Jena ARQ before it was written down.
    # Where a case is marked "ARQ parses/rejects this", that is an observation of a real
    # SPARQL 1.1 engine, not an argument from the grammar.
    # ---------------------------------------------------------------------

    @testset "a full IRI is data, not syntax" begin
        # The engine emits no PREFIX anywhere, so <...> is the ONLY way a filter can name a
        # resource or a datatype -- and a hash namespace puts a '#' in nearly every one.
        # Screening the raw text for '#' therefore refused the ordinary case. ARQ parses
        # each of these.
        for expr in (
            "?_Person_1 != <http://www.w3.org/2002/07/owl#Thing>",
            "?idText > \"2020\"^^<http://www.w3.org/2001/XMLSchema#gYear>",
            "?_Person_1 != <http://ex.org/a;b>",      # ';' inside an IRI is a path
            "?_Person_1 != <http://ex.org/a(b>",
        )      # so is an unclosed paren
            @test occursin("FILTER($expr)", compile_rule(with_filters(expr)))
        end
    end

    @testset "an IRI cannot be a hiding place" begin
        # Blanking <...> is only safe because IRIREF is a token whose charset already
        # excludes every character the brace check is looking for. Content that breaks that
        # charset is not an IRI, so it is not blanked -- it is left raw and refused.
        @test occursin(
            "could close the FILTER",
            refusal(with_filters("?_Person_1 != <http://ex.org/a}b>")),
        )
        @test occursin(
            "could open a group", refusal(with_filters("?_Person_1 != <http://ex.org/a{b>"))
        )
    end

    @testset "a lone < is a comparison, not an open IRI" begin
        # The scanner must not swallow the rest of the expression at `?a < ?b`. If it did,
        # the unbound ?nope here would vanish from the bound check -- the silent failure the
        # check exists to prevent.
        @test occursin(
            "FILTER(?idText < ?_ID_1)", compile_rule(with_filters("?idText < ?_ID_1"))
        )
        @test occursin("?nope", refusal(with_filters("?idText < ?nope")))
    end

    @testset "a prefixed name is refused, not passed to the store" begin
        # ARQ answers `"2020"^^xsd:gYear` with HTTP 400 "Unresolved prefixed name", because
        # this compiler declares no prefixes -- it has no registry, on purpose. Catching it
        # here is the same trade check_variables makes: a message now, not a 400 later.
        msg = refusal(with_filters("?idText > \"2020\"^^xsd:gYear"))
        @test occursin("prefixed name", msg)
        @test occursin("angle brackets", msg)
        # and the empty prefix, which is the easiest one to write by accident
        @test occursin("prefixed name", refusal(with_filters("?_Person_1 != :Thing")))
        # but a ':' inside a string or an IRI is data
        @test occursin(
            "FILTER(CONTAINS(?idText, \"a:b\"))",
            compile_rule(with_filters("CONTAINS(?idText, \"a:b\")")),
        )
    end

    @testset "a filter that is itself a FILTER clause is refused" begin
        # Compiles to FILTER(FILTER(...)), which ARQ rejects. The user guide has to say
        # "write the expression, not the clause" in bold; the compiler can just say it.
        msg = refusal(with_filters("FILTER(?_Person_1 != ?_ID_1)"))
        @test occursin("whole FILTER clause", msg)
        # SPARQL keywords are case-insensitive, so the check has to be too
        @test occursin(
            "whole FILTER clause", refusal(with_filters("filter (?_Person_1 != ?_ID_1)"))
        )
        # ... and a function whose name merely starts with those letters is untouched
        @test occursin(
            "FILTER(?idText != \"x\")", compile_rule(with_filters("?idText != \"x\""))
        )
    end

    @testset "the bound check reads every name SPARQL calls a variable" begin
        # SPARQL's VARNAME admits a leading digit and the whole of PN_CHARS_BASE: ARQ
        # parses `?1` and `?naïve` happily. A pattern of [a-zA-Z_][a-zA-Z0-9_]* missed `?1`
        # altogether -- so the rule shipped, matched nothing, and said nothing -- and
        # truncated `?naïve` to `?na`, refusing the rule while naming a variable the author
        # never wrote.
        m1 = refusal(with_filters("?1 = ?_ID_1"))
        @test occursin("?1", m1) && occursin("never binds", m1)
        m2 = refusal(with_filters("?naïve = ?_ID_1"))
        @test occursin("?naïve", m2)
        @test !occursin("?na,", m2) && !occursin("tests ?na ", m2)
    end

    @testset "\$x and ?x are the same variable" begin
        # SPARQL says so, so the bound check compares bare names.
        @test occursin(
            "FILTER(\$_Person_1 != ?_ID_1)",
            compile_rule(with_filters("\$_Person_1 != ?_ID_1")),
        )
        @test occursin("?nope", refusal(with_filters("\$nope != ?_ID_1")))
    end

    @testset "containment holds through the added blanking" begin
        # The one property the whole design rests on: no expression can leave the FILTER(...)
        # the compiler wraps it in. Re-asserted after teaching the skeleton about IRIs,
        # because that is new text the checks no longer see.
        for attack in (
            "1=1) } INSERT { <urn:x> <urn:p> 1 } WHERE {",
            "1=1) FILTER(1=1",
            "1=1 ; DROP ALL",
            "1=1 # ",
            "1=1) UNION <http://ex.org/a> (1=1",
        )
            @test_throws ErrorException compile_rule(with_filters(attack))
        end
    end

    @testset "strategy resolves caller over rule over mode" begin
        @test effective_strategy(with_control()) === :Once                 # Construct
        @test effective_strategy(with_control(mode=Jayhawk.MODE_ASSERT)) === :ToFixpoint
        @test effective_strategy(with_control(mode=Jayhawk.MODE_REWRITE)) === :Once
        # the rule's own declaration beats the mode default
        @test effective_strategy(with_control(strategy=:ToFixpoint)) === :ToFixpoint
        # and the caller beats the rule -- the same rule may be applied once during review
        # and to a fixpoint in a batch
        @test effective_strategy(with_control(strategy=:ToFixpoint); strategy=:Once) ===
            :Once
        @test_throws ArgumentError effective_strategy(with_control(); strategy=:Sideways)
    end

    @testset "strategy IRIs map to symbols, and nothing else does" begin
        @test strategy_symbol(Jayhawk.STRATEGY_ONCE) === :Once
        @test strategy_symbol(Jayhawk.STRATEGY_TOFIXPOINT) === :ToFixpoint
        @test_throws ArgumentError strategy_symbol("http://example.org/NotAStrategy")
    end

    @testset "an unbounded destructive loop is refused" begin
        # A Rewrite has no natural stopping point of its own. Iterating one with neither a
        # negative condition nor a stated bound would fall back to the default -- a hundred
        # destructive passes -- which is not a decision to make on the author's behalf.
        rw = with_control(mode=Jayhawk.MODE_REWRITE, strategy=:ToFixpoint)
        err = try
            run_rule(rw; source=["urn:g"])
        catch e
            e
        end
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin("negative condition", msg) && occursin("maxIterations", msg)

        # stating either one satisfies it (both then fail later, on the empty match pattern
        # or the missing server -- what matters is that this check no longer fires)
        bounded = with_control(
            mode=Jayhawk.MODE_REWRITE, strategy=:ToFixpoint, max_iterations=3
        )
        @test !(
            try
                run_rule(bounded; source=["urn:g"])
            catch e
                e
            end isa ArgumentError && occursin(
                "negative condition",
                sprint(
                    showerror,
                    try
                        run_rule(bounded; source=["urn:g"])
                    catch e
                        e
                    end,
                ),
            )
        )
    end

    @testset "a blank node in a pattern is refused, with the fix spelled out" begin
        # A blank node is an undeclared variable: it cannot be validated, cannot carry
        # oneOf or iriTemplate, does not connect L to R (SPARQL will not carry one from
        # WHERE into CONSTRUCT), and is illegal outright in the DELETE a Rewrite emits.
        base = person_to_employee()
        withbn(field) = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            if field === :L
                vcat(
                base.match,
                [PatternTriple(BNode("x"), iri("$(G)isIdentifiedBy"), iri("$(R)_ID_1"))],
            )
            else
                base.match
            end,
            if field === :R
                vcat(
                base.construct,
                [PatternTriple(iri("$(R)_Person_1"), iri("$(HR)worksAt"), BNode("y"))],
            )
            else
                base.construct
            end,
            base.variables,
            base.mints,
        )

        for (where, spec) in ((:L, withbn(:L)), (:R, withbn(:R)))
            err = try
                compile_rule(spec)
            catch e
                e
            end
            msg = sprint(showerror, err)
            @test occursin("blank node", msg)
            # the message has to be actionable, not just correct
            @test occursin("gistp:SparqlVariable", msg)
            @test occursin("gistp:variableText", msg)
            @test occursin("->", msg)                 # the substitution to make
        end

        # a negative condition is checked too
        nacbn = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            base.variables,
            base.mints,
            Dict{String,Vector{RDFTerm}}(),
            [
                NacSpec(
                    "$(R)N", [PatternTriple(BNode("z"), iri(TYPE), iri("$(HR)Employee"))]
                ),
            ],
            nothing,
            0,
            nothing,
        )
        @test occursin("negative condition", sprint(
            showerror,
            try
                compile_rule(nacbn)
            catch e
                e
            end,
        ))

        # and a rule with none still compiles
        @test compile_rule(base) isa String
    end

    @testset "an enumerated IRI is validated like every other" begin
        # values_text used sparql_text, which wraps an IRI in <> and checks nothing, while
        # every other IRI goes through term_sparql -> check_iri. A member containing '>'
        # closed the clause and opened another.
        payload = "http://ex.org/a> } INSERT { <urn:x> <urn:y> <urn:z> } WHERE { VALUES ?c { <http://ex.org/b"
        s = person_to_employee()
        bad = RuleSpec(
            s.iri,
            s.mode,
            s.match_graph,
            s.construct_graph,
            s.match,
            s.construct,
            merge(s.variables, Dict("$(R)_c" => "?c")),
            s.mints,
            Dict{String,Vector{RDFTerm}}("$(R)_c" => RDFTerm[iri(payload)]),
            NacSpec[],
            nothing,
            0,
            nothing,
        )
        @test_throws ArgumentError compile_rule(bad)

        # a literal member stays safe by escaping, which is the correct mechanism -- the
        # payload text may appear, so long as it cannot terminate the literal
        ok = RuleSpec(
            s.iri,
            s.mode,
            s.match_graph,
            s.construct_graph,
            s.match,
            s.construct,
            merge(s.variables, Dict("$(R)_c" => "?c")),
            s.mints,
            Dict{String,Vector{RDFTerm}}(
                "$(R)_c" =>
                    RDFTerm[RDFLiteral("a\" } INSERT { <urn:x> <urn:y> <urn:z> } #")],
            ),
            NacSpec[],
            nothing,
            0,
            nothing,
        )
        q = compile_rule(ok)
        @test occursin("\\\" } INSERT {", q)
    end

    @testset "a term in a position RDF forbids is refused" begin
        # Emitting one produces SPARQL the store rejects, so without this the author meets
        # an opaque HTTP 400 from Fuseki rather than a statement about their rule.
        base = person_to_employee()
        # R is reduced too: replacing all of L would otherwise unbind ?idText and trip
        # use-before-def before the position check is reached.
        simpleR = [PatternTriple(iri("$(R)_Person_1"), iri(TYPE), iri("$(HR)Employee"))]
        with(ts) = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            ts,
            simpleR,
            base.variables,
            base.mints,
        )
        @test occursin(
            "literal subjects",
            sprint(
                showerror,
                try
                    compile_rule(
                        with([
                            PatternTriple(RDFLiteral("oops"), iri(TYPE), iri("$(G)Person"))
                        ]),
                    )
                catch e
                    e
                end,
            ),
        )
        @test occursin(
            "predicate",
            sprint(
                showerror,
                try
                    compile_rule(
                        with([
                            PatternTriple(
                                iri("$(R)_Person_1"), RDFLiteral("oops"), iri("$(G)Person")
                            ),
                        ]),
                    )
                catch e
                    e
                end,
            ),
        )
        # a variable in predicate position is legal: it is an IRI at pattern level
        @test compile_rule(
            with([PatternTriple(iri("$(R)_Person_1"), iri("$(R)_ID_1"), iri("$(G)Person"))])
        ) isa String
    end

    @testset "a template with no slot mints one node for every match" begin
        # It expands to the same IRI whatever the binding, collapsing every solution onto
        # one node. A fixed node is a legitimate thing to want -- but it is written as a
        # constant in R, not as a template with nothing to substitute.
        s = minting_rule(
            template="http://example.org/hr/employee/fixed", slots=Dict{String,RDFTerm}()
        )
        msg = sprint(
            showerror,
            try
                compile_rule(s)
            catch e
                e
            end,
        )
        @test occursin("no {slot}", msg)
        @test occursin("directly in the construct pattern", msg)
    end

    @testset "same spec, same bytes -- whatever order it was built in" begin
        # The sort lives in bgp_text, not only in load_pattern, so the guarantee holds for a
        # spec an MCP client hands in as much as for one read from the store. A BGP is a set.
        base = person_to_employee()
        shuffled = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            reverse(base.match),
            reverse(base.construct),
            base.variables,
            base.mints,
        )
        @test compile_rule(base) == compile_rule(shuffled)
    end

    @testset "check_iri demands an absolute IRI" begin
        for bad in ("", "../relative", "not-an-iri", "/absolute/path")
            @test_throws ArgumentError check_iri(bad)
        end
        for good in ("http://ex.org/x", "urn:jayhawk:firing:1", "https://a.b/c#d")
            @test check_iri(good) == good
        end
        # a relative graph IRI would resolve against whatever base the query carried
        @test_throws ArgumentError insert_query(person_to_employee(); into="relative")
    end

    @testset "templating cannot eat a SPARQL group pattern" begin
        # `{{` is legal SPARQL -- a nested group -- and Mustache read it as a section, so
        # any non-empty binding set deleted the whole group. Plain substitution cannot:
        # a brace pair that is not a supplied key is left exactly as written.
        q = "SELECT ?s WHERE { GRAPH <urn:g> {{ ?s ?p ?o }} }"
        @test Jayhawk.render_query(q, Dict()) == q
        @test Jayhawk.render_query(q, Dict("unused" => "x")) == q
        @test Jayhawk.render_query(
            "ASK { <urn:a> <urn:b> \"{{v}}\" }", Dict("v" => "hi")
        ) == "ASK { <urn:a> <urn:b> \"hi\" }"
    end

    @testset "insert_query wraps the same patterns with USING" begin
        spec = person_to_employee()
        q = insert_query(spec; into="urn:firing:x", from=["urn:a", "urn:b"])
        @test occursin("INSERT {", q)
        @test occursin("GRAPH <urn:firing:x>", q)
        @test occursin("USING <urn:a>", q)
        @test occursin("USING <urn:b>", q)
        # the match pattern is character-identical to the CONSTRUCT form's
        @test occursin(bgp_text(spec.match, spec), q)
        # no USING at all when the working set is the store's default graph
        @test !occursin("USING", insert_query(spec; into="urn:firing:x"))
    end

    @testset "gistp:inGraph scopes the triples, not the clause" begin
        # Build a scoped variant: L in ?_Book, a NAC in the same ?_Book, R using ?_Book as
        # an ordinary object term (which is the whole provenance use case).
        base = person_to_employee()
        BOOK = "$(R)_Book"
        vars = merge(base.variables, Dict(BOOK => "?_Book"))
        nac = NacSpec(
            "$(R)PersonToEmployee_N",
            [PatternTriple(iri("$(R)_Person_1"), iri(TYPE), iri("$(HR)Retired"))],
            BOOK,
        )
        scoped = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            vcat(
                base.construct,
                [PatternTriple(iri("$(R)_Person_1"), iri("$(HR)heldIn"), iri(BOOK))],
            ),
            vars,
            base.mints,
            base.enums,
            [nac],
            nothing,
            0,
            nothing,
            BOOK,
            nothing,
        )
        q = compile_rule(scoped; from=["urn:a"])

        # L's triples are inside the group; the guard is NOT.
        @test occursin("GRAPH ?_Book {", q)
        @test occursin("FILTER NOT EXISTS {\n    GRAPH ?_Book {", q)
        # The critical structural claim: the filter opens *after* L's group has closed.
        # Nested inside it, `?_Book` would be a fresh variable over every named graph and
        # the guard would silently mean "in ANY graph" -- measured against Fuseki.
        @test findfirst("  }\n  # NOT <", q) !== nothing

        # L's graph variable counts as bound, so R may use it. Without scope_vars this is
        # refused as use-before-def on the one variable L most certainly binds.
        @test occursin("?_Person_1 <$(HR)heldIn> ?_Book .", q)

        # A constant scope renders as the graph, not as a variable.
        konst = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            base.variables,
            base.mints,
            base.enums,
            NacSpec[],
            nothing,
            0,
            nothing,
            "urn:book:a",
            nothing,
        )
        @test occursin("GRAPH <urn:book:a> {", compile_rule(konst; from=["urn:a"]))
    end

    @testset "an unscoped rule emits exactly what it always did" begin
        # The guarantee that keeps the golden snapshot honest: dataset_lines must early-return
        # on the unscoped path rather than happen to produce the same bytes.
        spec = person_to_employee()
        @test !is_scoped(spec)
        @test dataset_lines(spec, ["urn:a", "urn:b"]) == "USING <urn:a>\nUSING <urn:b>\n"
        @test dataset_lines(spec, String[]) == ""
        @test !occursin("NAMED", insert_query(spec; into="urn:f", from=["urn:a"]))
    end

    @testset "a scoped rule emits USING and USING NAMED together" begin
        # Not generosity: default and named are disjoint namespaces. USING NAMED alone leaves
        # the default graph EMPTY, so an unscoped pattern in the same rule matches nothing;
        # USING alone leaves GRAPH <g> invisible. Both verified against Fuseki.
        base = person_to_employee()
        scoped = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            base.variables,
            base.mints,
            base.enums,
            NacSpec[],
            nothing,
            0,
            nothing,
            "urn:book:a",
            nothing,
        )
        @test is_scoped(scoped)
        d = dataset_lines(scoped, ["urn:a"])
        @test occursin("USING <urn:a>", d) && occursin("USING NAMED <urn:a>", d)
        # This used to assert `== ""` -- "nothing to name, nothing emitted" -- which is
        # exactly backwards: a scoped rule with no dataset clause does not read nothing, it
        # reads the whole store. The assertion was pinning the defect in place.
        @test_throws ErrorException dataset_lines(scoped, String[])
        f = dataset_lines(scoped, ["urn:a"]; keyword="FROM")
        @test occursin("FROM <urn:a>", f) && occursin("FROM NAMED <urn:a>", f)
    end

    @testset "the rewrite pruning and promotion ops carry no dataset clause" begin
        # An invariant, not a formatting accident. USING/USING NAMED *replace* the dataset,
        # so a graph absent from the clause is invisible even to GRAPH <constant> in the
        # WHERE -- the update then succeeds with 204 having matched nothing. Splice
        # using_lines into these two and op 2 stops pruning while op 5 stops copying, after
        # op 4 has already deleted from the target. Silent data loss.
        spec = person_to_employee(mode=Jayhawk.MODE_REWRITE)
        shared = spec.match[1]
        rw = RuleSpec(
            spec.iri,
            spec.mode,
            spec.match_graph,
            spec.construct_graph,
            spec.match,
            vcat(spec.construct, [shared]),
            spec.variables,
            spec.mints,
        )
        q = rewrite_query(
            rw; target="urn:t", firing="urn:f", tombstone="urn:tomb", from=["urn:t"]
        )
        for op in split(q, " ;\n")
            occursin("?__s ?__p ?__o", op) || continue
            @test !occursin("USING", op)
        end
    end

    @testset "every unimplemented use of inGraph is refused, not approximated" begin
        base = person_to_employee()
        respec(; scope=nothing, cscope=nothing, mode=base.mode, nacs=NacSpec[]) = RuleSpec(
            base.iri,
            mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            base.variables,
            base.mints,
            base.enums,
            nacs,
            nothing,
            0,
            nothing,
            scope,
            cscope,
        )

        # writing into a named graph, before undo can reverse it
        @test_throws ErrorException compile_rule(
            respec(scope="urn:b", cscope="urn:b"); from=["urn:a"]
        )
        # a rewrite whose match binds several graphs, against a single-target tombstone
        @test_throws ErrorException compile_rule(
            respec(scope="urn:b", mode=Jayhawk.MODE_REWRITE)
        )
        # a scope that is not a legal IRI must not reach the store
        @test_throws ArgumentError compile_rule(respec(scope="urn:b ad"); from=["urn:a"])
        # and the unscoped rule still compiles, which is what makes the above meaningful
        @test compile_rule(respec()) isa String
    end

    @testset "a graph variable is discovered and validated like any other" begin
        base = person_to_employee()
        BOOK = "$(R)_Book"
        # It resolves to its variableText...
        withvar = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            merge(base.variables, Dict(BOOK => "?_Book")),
            base.mints,
            base.enums,
            NacSpec[],
            nothing,
            0,
            nothing,
            BOOK,
            nothing,
        )
        @test scope_vars(BOOK, withvar) == Set(["?_Book"])
        @test occursin("GRAPH ?_Book {", compile_rule(withvar; from=["urn:a"]))
        # ...and a variableText that could close the group and open another is refused, the
        # same injection guard that covers every other position.
        evil = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            merge(base.variables, Dict(BOOK => "?b } } ; DROP ALL ; #")),
            base.mints,
            base.enums,
            NacSpec[],
            nothing,
            0,
            nothing,
            BOOK,
            nothing,
        )
        @test_throws ErrorException compile_rule(evil; from=["urn:a"])
    end

    # ---------------------------------------------------------------------------------
    # Round 5a review findings. Each of these was a *silent* wrong answer on the branch as
    # merged -- the rule compiled, validated, ran, and reported success. See
    # docs/review-named-graphs.md for the measured reproductions.
    # ---------------------------------------------------------------------------------

    @testset "F1: a scoped rule with no dataset clause is refused at the builder" begin
        # `run_rule` guarded this; nothing else did. `apply_rule`, `dry_run`,
        # `check_collisions` and `mint_fanin` are all public and all reach a builder direct,
        # so the guard belongs where the query is assembled. Measured before the fix:
        # dry_run on the scoped fixture returned 4 triples, the extra one asserting the
        # rule's own pattern graph as data, and apply_rule persisted it.
        base = person_to_employee()
        scoped = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            base.variables,
            base.mints,
            base.enums,
            NacSpec[],
            nothing,
            0,
            nothing,
            "urn:book:a",
            nothing,
        )
        @test_throws ErrorException insert_query(scoped; into="urn:f")
        @test_throws ErrorException project_query(
            scoped; triples=scoped.construct, into="urn:f"
        )
        @test_throws ErrorException compile_rule(scoped; from=String[])
        # naming the graphs is all it takes
        @test occursin(
            "USING NAMED <urn:a>", insert_query(scoped; into="urn:f", from=["urn:a"])
        )
        # and an unscoped rule is untouched: empty `from` still means the default graph
        @test insert_query(base; into="urn:f") isa String
    end

    @testset "F2: the mint-safety queries scope L exactly as the rule does" begin
        # collision_queries and mint_fanin used to build L with a bare bgp_text, so for a
        # scoped rule the query they asked the store was a different rule from the one that
        # runs: `?_Book` was never bound, CONCAT yielded unbound, and HAVING(... > 1) could
        # never fire. The fan-in report was empty by construction for precisely the rules
        # whose R mentions the graph they matched in.
        base = minting_rule()
        BOOK = "$(R)_Book"
        scoped = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            merge(base.variables, Dict(BOOK => "?_Book")),
            base.mints,
            base.enums,
            NacSpec[],
            nothing,
            0,
            nothing,
            BOOK,
            nothing,
        )
        for (_, q) in collision_queries(scoped; from=["urn:a"])
            @test occursin("GRAPH ?_Book {", q)
        end
        # one decision, one place: match_text is what where_body uses too
        @test occursin("GRAPH ?_Book {", where_body(scoped))
        # unscoped stays byte-identical, which is what keeps the golden snapshot honest
        @test match_text(base) == bgp_text(base.match, base)
    end

    @testset "F3: a guard may not be scoped to a variable L does not bind" begin
        # A condition's TRIPLES may introduce fresh existential variables -- that is what a
        # guard is. Its GRAPH may not: an unbound graph variable re-quantifies the whole
        # condition into "no such thing in ANY graph". Measured on the fixture, that silently
        # drops the ex:s2/bookB row -- the row the headline integration test exists to
        # protect -- with no error anywhere.
        base = person_to_employee()
        BOOK, OTHER = "$(R)_Book", "$(R)_Other"
        vars = merge(base.variables, Dict(BOOK => "?_Book", OTHER => "?_Other"))
        nac_t = [PatternTriple(iri("$(R)_Person_1"), iri(TYPE), iri("$(HR)Retired"))]

        loose = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            vars,
            base.mints,
            base.enums,
            [NacSpec("$(R)N", nac_t, OTHER)],
            nothing,
            0,
            nothing,
            BOOK,
            nothing,
        )
        @test_throws ErrorException compile_rule(loose; from=["urn:a"])

        # scoped to the variable L *does* bind: fine
        tight = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            vars,
            base.mints,
            base.enums,
            [NacSpec("$(R)N", nac_t, BOOK)],
            nothing,
            0,
            nothing,
            BOOK,
            nothing,
        )
        @test occursin(
            "FILTER NOT EXISTS {\n    GRAPH ?_Book {", compile_rule(tight; from=["urn:a"])
        )

        # a constant graph is always fine -- it binds nothing, so it re-quantifies nothing
        konst = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            vars,
            base.mints,
            base.enums,
            [NacSpec("$(R)N", nac_t, "urn:book:a")],
            nothing,
            0,
            nothing,
            BOOK,
            nothing,
        )
        @test occursin("GRAPH <urn:book:a> {", compile_rule(konst; from=["urn:a"]))
    end

    @testset "F4: the reviewed text is the executed text" begin
        # compile_rule emitted no dataset clause, so a reviewer approved an unbounded
        # `GRAPH ?g` while an INSERT ... USING ... USING NAMED ... is what ran.
        base = person_to_employee()
        scoped = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            base.variables,
            base.mints,
            base.enums,
            NacSpec[],
            nothing,
            0,
            nothing,
            "urn:book:a",
            nothing,
        )
        q = compile_rule(scoped; from=["urn:a", "urn:b"])
        # a CONSTRUCT takes FROM; only a SPARQL Update takes USING
        @test occursin("FROM <urn:a>", q) && occursin("FROM NAMED <urn:a>", q)
        @test !occursin("USING", q)
        # omitting `from` on an UNSCOPED rule keeps the historical bytes exactly
        @test compile_rule(base) == compile_rule(base; from=String[])
        @test !occursin("FROM", compile_rule(base))
    end

    @testset "F5: a template may mint from the graph L matched in" begin
        # "one node per book" is the obvious thing to want from gistp:inGraph. check_mints
        # computed `bound` without scope_vars, so it was refused -- and refused with a
        # message about minting from another minted variable, which ?_Book is not.
        BOOK = "$(R)_Book"
        base = minting_rule(slots=Dict{String,RDFTerm}("id" => iri(BOOK)))
        scoped = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            merge(base.variables, Dict(BOOK => "?_Book")),
            base.mints,
            base.enums,
            NacSpec[],
            nothing,
            0,
            nothing,
            BOOK,
            nothing,
        )
        q = compile_rule(scoped; from=["urn:a"])
        @test occursin("ENCODE_FOR_URI(STR(?_Book))", q)
        # and the same variable is still refused when L is NOT scoped to it -- the check is
        # "does L bind it", not "is it spelled like a graph"
        unscoped = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            merge(base.variables, Dict(BOOK => "?_Book")),
            base.mints,
            base.enums,
            NacSpec[],
            nothing,
            0,
            nothing,
            nothing,
            nothing,
        )
        @test_throws ErrorException compile_rule(unscoped)
    end

    # ---------------------------------------------------------------------
    # gistp:inGraph, third reading: a data source rather than a graph
    # ---------------------------------------------------------------------

    # A rule whose L is scoped to a gistp:TabularDataSource. Built here rather than loaded,
    # so this stays hermetic: `services` is exactly what load_services would have returned.
    function source_scoped()
        base = person_to_employee()
        SRC = "$(R)_People"
        FX = "http://sparql.xyz/facade-x/ns/"
        RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            base.variables,
            base.mints,
            base.enums,
            base.nacs,
            base.strategy,
            base.priority,
            base.max_iterations,
            SRC,
            nothing,
            Dict(
                SRC => ["$(FX)csv.headers" => "true", "$(FX)location" => "/tmp/people.csv"]
            ),
        )
    end

    @testset "a source-scoped pattern compiles to SERVICE, not GRAPH" begin
        q = compile_rule(source_scoped())
        @test occursin("SERVICE <x-sparql-anything:> {", q)
        @test !occursin("GRAPH", q)
        # fx:properties is the subject; the options are its predicates, absolute like
        # everything else this engine emits
        @test occursin("<http://sparql.xyz/facade-x/ns/properties>", q)
        @test occursin("<http://sparql.xyz/facade-x/ns/location> \"/tmp/people.csv\"", q)
        # sorted by predicate, so the text is byte-stable across stores and runs
        @test findfirst("csv.headers", q).start < findfirst("ns/location", q).start
    end

    @testset "a data source is not part of the dataset" begin
        spec = source_scoped()
        # It compiles to a SERVICE, which is evaluated outside the query's dataset. Naming
        # it in USING NAMED would be meaningless, and -- the part that matters -- demanding
        # a non-empty `source` for it would refuse a rule that has no graph to name.
        @test is_scoped(spec) == false
        @test all_scopes(spec) == ["$(R)_People"]
        @test isempty(graph_scopes(spec))
        @test dataset_lines(spec, String[]) == ""
        q = compile_rule(spec)
        @test !occursin("USING", q)
        # ... whereas a plain graph scope still produces USING NAMED, unchanged
        b = person_to_employee()
        gscoped = RuleSpec(
            b.iri,
            b.mode,
            b.match_graph,
            b.construct_graph,
            b.match,
            b.construct,
            b.variables,
            b.mints,
            b.enums,
            b.nacs,
            b.strategy,
            b.priority,
            b.max_iterations,
            "urn:book:A",
            nothing,
        )
        @test is_scoped(gscoped)
        @test occursin("USING NAMED <urn:a>", dataset_lines(gscoped, ["urn:a"]))
    end

    @testset "a data source on the construct pattern is refused" begin
        base = source_scoped()
        onR = RuleSpec(
            base.iri,
            base.mode,
            base.match_graph,
            base.construct_graph,
            base.match,
            base.construct,
            base.variables,
            base.mints,
            base.enums,
            base.nacs,
            base.strategy,
            base.priority,
            base.max_iterations,
            nothing,
            "$(R)_People",
            base.services,
        )
        err = try
            compile_rule(onR)
            ""
        catch e
            sprint(showerror, e)
        end
        @test occursin("gistp:TabularDataSource", err)
        @test occursin("cannot be written to", err)
    end

    @testset "illegal IRIs are refused, not emitted" begin
        spec = person_to_employee()
        # keep L otherwise intact, so the binding check passes and emission is reached
        bad = RuleSpec(
            spec.iri,
            spec.mode,
            spec.match_graph,
            spec.construct_graph,
            vcat(
                spec.match,
                [PatternTriple(iri("http://ex.org/a b"), iri(TYPE), iri("$(G)ID"))],
            ),
            spec.construct,
            spec.variables,
            spec.mints,
        )
        @test_throws ArgumentError compile_rule(bad)
    end
end

@testset "rule sets (pure)" begin
    # run_rules validates its set before it touches the store, so everything that can be
    # refused can be refused with no server running. Specs are built by hand; reading a set
    # out of a store is exercised in test/sparql_integration.jl.
    R = "http://example.org/rules/"
    TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
    iri(x) = IRIRef(x)

    trivial(name, mode; priority=0) = RuleSpec(
        "$(R)$name",
        mode,
        "$(R)$(name)_L",
        "$(R)$(name)_R",
        [PatternTriple(iri("$(R)_X"), iri(TYPE), iri("http://example.org/A"))],
        [PatternTriple(iri("$(R)_X"), iri(TYPE), iri("http://example.org/B"))],
        Dict("$(R)_X" => "?_X"),
        Dict{String,MintSpec}(),
        Dict{String,Vector{RDFTerm}}(),
        NacSpec[],
        nothing,
        priority,
        nothing,
        nothing,
        nothing,
        Dict{String,Vector{Pair{String,String}}}(),
        String[],
    )

    seq(specs, label, strat, budget; source=["urn:g"]) =
        Jayhawk._run_rule_sequence(specs, label, strat, budget; source=source, actor="test")

    @testset "RuleSetSpec holds the order it was given" begin
        set = RuleSetSpec("$(R)Set", "A set", ["$(R)First", "$(R)Second"], :Once, nothing)
        @test set.rules == ["$(R)First", "$(R)Second"]
        @test set.strategy === :Once
        @test set.max_iterations === nothing
    end

    @testset "an empty ad-hoc run is refused" begin
        # Not a no-op: a caller that computed an empty list of rules has a bug, and running
        # nothing successfully would hide it.
        @test_throws ArgumentError run_rules(String[])
    end

    @testset "mixing Rewrite with additive modes is refused" begin
        # The requirements are contradictory, not merely awkward: an additive rule's output
        # is a new named graph that must join the working set, and a Rewrite takes exactly
        # one source graph which is its target. After the first additive firing there is no
        # source the rewrite can accept.
        mixed = [
            trivial("Add", Jayhawk.MODE_CONSTRUCT), trivial("Del", Jayhawk.MODE_REWRITE)
        ]
        e = try
            seq(mixed, "<mixed>", :Once, 1)
        catch err
            err
        end
        @test e isa ArgumentError
        msg = sprint(showerror, e)
        @test occursin("mixes gistp:Rewrite with additive modes", msg)
        @test occursin("$(R)Del", msg)        # names the offender, not just the problem
        @test !occursin("$(R)Add", msg[1:findfirst("Rewrite rules:", msg).stop])
    end

    @testset "an all-Rewrite set is allowed through validation" begin
        # Every rule mutating one graph in place is coherent: the working set never grows,
        # so the single-source requirement holds for the whole pass. It fails later for
        # want of a server, which is the proof that validation let it past.
        allrw = [trivial("D1", Jayhawk.MODE_REWRITE), trivial("D2", Jayhawk.MODE_REWRITE)]
        e = try
            seq(allrw, "<rw>", :Once, 1)
        catch err
            err
        end
        @test !(
            e isa ArgumentError && occursin("mixes gistp:Rewrite", sprint(showerror, e))
        )
    end

    @testset "a set fixpoint needs an explicit source" begin
        # Same reason a rule fixpoint does: each pass must see the last one's output, and
        # SPARQL's USING cannot name the store's default graph.
        one = [trivial("Add", Jayhawk.MODE_CONSTRUCT)]
        e = try
            seq(one, "<fp>", :ToFixpoint, 5; source=String[])
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("needs an explicit `source`", sprint(showerror, e))
    end

    @testset "strategy and budget are checked before anything runs" begin
        one = [trivial("Add", Jayhawk.MODE_CONSTRUCT)]
        @test_throws ArgumentError seq(one, "<bad>", :Sideways, 1)
        @test_throws ArgumentError seq(one, "<bad>", :Once, 0)
    end
end

# Everything above is hermetic: no network, no server, ~6 seconds. Keep it that way.
#
# The SPARQL integration tests need a live Apache Jena Fuseki and are therefore opt-in.
# Without JAYHAWK_TEST_SPARQL set they are not even loaded, so a developer with no
# server running never sees a failure from them.
#
#     ./bin/fuseki-test.sh start
#     JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl
if haskey(ENV, "JAYHAWK_TEST_SPARQL")
    include("sparql_integration.jl")
end
