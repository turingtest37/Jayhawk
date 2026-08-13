using Test

using Jayhawk
using URIs
using Serd, Serd.RDF, Serd.RDF.Prefixes
using Logging

# Debug logging stays off unless it is asked for. This line used to read
# `ENV["JULIA_DEBUG"]=all`, where `all` is `Base.all` -- the function. It stringifies to
# "all", which is exactly the magic value JULIA_DEBUG wants, so it worked by accident
# and forced full @debug output on every run: ~63,000 lines burying the test summary.
#
# Julia reads JULIA_DEBUG from the environment on its own, so to turn it back on:
#     JULIA_DEBUG=Jayhawk julia --project=. test/runtests.jl

Jayhawk.set_def_prefixes()

@testset "RDF functions" begin

    @testset "split URN simple" begin
        @test split(U"urn:data") == ("urn:","data")
    end

    @testset "split URN long" begin
        @test split(U"urn:thanks:yourewelcome") == ("urn:","thanks:yourewelcome")
    end

    @testset "ns for URN" begin
        uri = U"urn:blahblah"
        a = "urn:"
        @test ns(uri) == a
    end

    @testset "ns for HTTP /" begin
        uri = U"http://calinedebine.qc.ca/blahblah"
        a = "http://calinedebine.qc.ca/"
        @test ns(uri) == a
    end

    @testset "ns for HTTP fragment #" begin
        uri = U"http://calinedebine.qc.ca/def#blahblah"
        a = "http://calinedebine.qc.ca/def#"
        @test ns(uri) == a
    end

    @testset "makeqname - unregistered prefix throws KeyError" begin
        uri = "http://badidea.com/Class"
        @test_throws KeyError makeqname(uri)
    end

    @testset "makeqname - urn: simple namespace" begin
        uri = "urn:data"
        a = "urn_data"
        @test makeqname(uri) == a
    end

    @testset "makeqname - urn: long namespace" begin
        uri = "urn:thanks:yourewelcome"
        a = "urn_thanks_yourewelcome"
        @test makeqname(uri) == a
    end

    @testset "makeqname - gist:" begin
        uri = "https://ontologies.semanticarts.com/gist/Category"
        a = "gist_Category"
        @test makeqname(uri) == a
    end

    @testset "makeqname - jayhawk:" begin
        uri = "http://www.semanticweb.org/doug/ontologies/jayhawk#JuliaFunction"
        a = "jayhawk_JuliaFunction"
        @test makeqname(uri) == a
    end

end

@testset "Parsing complex" begin
    
    @testset "Full, explicit calls" begin
        
        t = """
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
        PREFIX owl: <http://www.w3.org/2002/07/owl#>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        PREFIX ex: <http://ontologies.example.org/doug#>
        PREFIX : <http://ontologies.example.org/doug#>
        PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
        PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
        
        BASE <http://id.example.org/doug/>

        ex:Quark rdf:type owl:Class ;
            rdfs:label "Quark" ;
            rdfs:comment "Murray Gel-Mann's thing" ;
        .

        ex:QuarkType rdf:type owl:Class ;
            rdfs:label "QuarkType" ;
            rdfs:comment "Murray Gel-Mann's thing" ;
            skos:definition "The kind of quark in question." ;
        .

        ex:is-categorized-by rdf:type owl:ObjectProperty ;
            skos:prefLabel "is categorized by" ;
            skos:definition "Subject is further defined by the object category item." ;
        .

        ex:s-factor rdf:type owl:DatatypeProperty ;
            skos:prefLabel "s-factor" ;
            skos:definition "The reknowned s factor in RDF." ;
            rdfs:range xsd:float ;
        .

        :_Quark_strange rdf:type ex:QuarkType ;
            rdfs:label "Strange flavor quark." ;
            skos:definition "The strange quark or s quark (from its symbol, s) is the third lightest of all quarks, a type of elementary particle. Strange quarks are found in subatomic particles called hadrons." ;
        .

        :_abcde ex:is-categorized-by :_Quark_strange .
        :_abcde ex:is-based-on :_something_difficult .
        :_abcde rdf:type ex:Quark ;
        .

        """
        tl = initialize()
        make_from_rdf(t,tl)
        @test in(Resource("http://id.example.org/doug/_Quark_strange"), keys(tl.ldict)) 

    end

    @testset "TraceLog local only" begin
        tl = TraceLog(true)
        s = ResourceURI("http://example.org/ok")
        o = "Marvelous!"
        store_local!(tl, o, s)

        @test o == tl.ldict[s]
    end

    @testset "TraceLog both" begin
        tl = TraceLog(true)
        s = ResourceURI("http://example.org/ok")
        o = "Marvelous!"
        store_local!(tl, o, s)

        @test o == tl.ldict[s]
        
        store_res!(tl, o, s)
        @test o == tl.rdict[s]
    end

    @testset "retrieve! no default provided" begin
        tl = TraceLog(true)
        @test retrieve!(tl, Resource("/bogus")) == Unknown(Resource("/bogus"))
    end

    @testset "Little snippets make_from_rdf" begin
    
        t = """
        BASE <http://id.example.org/doug/>

        :_a_thing :goes-to-washington-with :_another_thing .
        """
        tl = initialize()
        make_from_rdf(t,tl)
        @test in(Resource("http://id.example.org/doug/_a_thing"), keys(tl.ldict))
        
    end

    @testset "make_from_rdf" begin
        t = """
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
        PREFIX owl: <http://www.w3.org/2002/07/owl#>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        PREFIX ex: <http://ontologies.example.org/doug#>
        PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
        PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
        
        BASE <http://id.example.org/doug/>

        ex:Quark rdf:type owl:Class ;
            rdfs:label "Quark" ;
            rdfs:comment "Murray Gel-Mann's thing" ;
        .

        ex:QuarkType rdf:type owl:Class ;
            rdfs:label "QuarkType" ;
            rdfs:comment "The sort of Murray Gel-Mann's thing, e.g. up quark, strange quark" ;
            skos:definition "The kind of quark in question." ;
        .

        ex:is-categorized-by rdf:type owl:ObjectProperty ;
            skos:prefLabel "is categorized by" ;
            skos:definition "Subject is further defined by the object category item." ;
        .

        ex:s-factor rdf:type owl:DatatypeProperty ;
            skos:prefLabel "s-factor" ;
            skos:definition "The reknowned s factor in RDF." ;
            rdfs:range xsd:float ;
        .

        :_Quark_strange rdf:type ex:QuarkType ;
            rdfs:label "Strange flavor quark." ;
            skos:definition "The strange quark or s quark (from its symbol, s) is the third lightest of all quarks, a type of elementary particle. Strange quarks are found in subatomic particles called hadrons." ;
        .

        :_abcde ex:is-categorized-by :_Quark_strange .
        :_abcde ex:is-based-on :_something_difficult .
        :_abcde rdf:type ex:Quark ;
        .

        """
        tl = initialize()
        make_from_rdf(t, tl)
        @test in(Resource("http://id.example.org/doug/_Quark_strange"), keys(tl.ldict)) 
        
    end

end

@testset "expand_uris term handling" begin

    # Both of these were mangled by a `Resource(string(s))` catch-all: `string` on a
    # Serd term renders the constructor call, not the term. Only prefixed names were
    # ever exercised, so full IRIs and blank nodes went unnoticed.

    @testset "full IRIs keep their URI" begin
        t = """
        BASE <http://iri.example.org/d/>
        <http://iri.example.org/d/_s> <http://www.w3.org/2004/02/skos/core#altLabel> "x" .
        """
        stmts = Jayhawk.expand_uris(Serd.read_rdf_string(t)...)
        tr = only(filter(s -> s isa Triple, stmts))
        @test tr.predicate.uri == "http://www.w3.org/2004/02/skos/core#altLabel"
        @test !occursin("ResourceURI", tr.predicate.uri)
    end

    @testset "blank nodes stay blank" begin
        t = """
        PREFIX ex: <http://blank.example.org/o#>
        BASE <http://blank.example.org/d/>
        :_s ex:p [ ex:q "inner" ] .
        """
        stmts = Jayhawk.expand_uris(Serd.read_rdf_string(t)...)
        terms = vcat([[s.subject, s.object] for s in stmts if s isa Triple]...)
        @test any(x -> x isa Blank, terms)
        @test !any(x -> x isa Resource && occursin("Blank(", x.uri), terms)
    end
end

@testset "real ontology loads" begin
    # gistAcct uses bare IRIs, blank nodes and an unprefixed ontology IRI -- the
    # combination that broke every path above.
    ttl = read(joinpath(@__DIR__, "..", "resource", "gistAcct3.0.0.ttl"), String)
    m = analyze(Jayhawk.expand_uris(Serd.read_rdf_string(ttl)...))

    @test length(m.classes) > 20
    @test length(m.properties) > 20
    @test !isempty(m.data)

    tl = initialize()
    make_from_rdf(ttl, tl)
    @test length(tl.ldict) > 100
end

@testset "every gistAcct triple executes" begin
    # These 24 failures were invisible before: master could not load the file at all.
    ttl = read(joinpath(@__DIR__, "..", "resource", "gistAcct3.0.0.ttl"), String)
    m = analyze(Jayhawk.expand_uris(Serd.read_rdf_string(ttl)...))
    install!(generate(m))
    tl = initialize()
    register!(m, tl)

    failures = Tuple{Any,Any}[]
    for t in m.data
        nm = Jayhawk._qname(t.predicate)
        (nm === nothing || !Jayhawk._defined(Jayhawk, nm)) && (push!(failures, (t, :undefined)); continue)
        f = Jayhawk._lookup(Jayhawk, nm)
        try
            Base.invokelatest(f, t.subject, t.object, tl)
        catch e
            push!(failures, (t, e))
        end
    end
    @test isempty(failures)
end

@testset "generated names are legal Julia identifiers" begin
    # `gist:is-categorized-by` produced the Symbol `ex_is-categorized-by`: accepted by
    # eval, unwritable in a source file, and fatal once generate emits to disk.
    @test Base.isidentifier(makeqname("ex", "is-categorized-by"))
    @test makeqname("ex", "is-categorized-by") == "ex_is_categorized_by"
    @test Base.isidentifier(makeqname("ex", "has.dotted.name"))

    # the existing colon handling must survive
    @test makeqname("urn:thanks:yourewelcome") == "urn_thanks_yourewelcome"

    ttl = read(joinpath(@__DIR__, "..", "resource", "gistAcct3.0.0.ttl"), String)
    m = analyze(Jayhawk.expand_uris(Serd.read_rdf_string(ttl)...))
    bad = [string(s.name) for s in values(m.properties) if !Base.isidentifier(string(s.name))]
    append!(bad, [string(s.name) for s in values(m.classes) if !Base.isidentifier(string(s.name))])
    @test isempty(bad)
end

@testset "rdfs:subClassOf on a realised class" begin
    # DataType has a `super` field of its own, so the generic method used to resolve to
    # `push!(Any, o)`. A hasfield guard would not have caught it.
    @test hasfield(DataType, :super)

    t = """
    PREFIX owl: <http://www.w3.org/2002/07/owl#>
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    PREFIX sc: <http://sc.example.org/o#>
    sc:Parent rdf:type owl:Class .
    sc:Child  rdf:type owl:Class ; rdfs:subClassOf sc:Parent .
    """
    tl = initialize()
    make_from_rdf(t, tl)

    # the realised class arrives as a DataType; this is the call that used to throw
    Child = Jayhawk._lookup(Jayhawk, :sc_Child)
    @test Child isa Type
    @test rdfs_subClassOf(Child, Jayhawk._lookup(Jayhawk, :sc_Parent), tl) === nothing

    # an Unknown still accumulates supertypes as before
    u = Unknown(Resource("http://sc.example.org/d/_u"))
    rdfs_subClassOf(u, Resource("http://sc.example.org/o#Parent"), tl)
    @test length(u.super) == 1

    # the edge is still recorded -- in the model, which is where it belongs
    m = analyze(Jayhawk.expand_uris(Serd.read_rdf_string(t)...))
    @test Resource("http://sc.example.org/o#Parent") in
          m.classes[Resource("http://sc.example.org/o#Child")].supers
end

@testset "owl:Ontology, Restriction, Thing, NamedIndividual" begin
    # None of these had a working single-argument constructor; owl_Thing(s) was already
    # being called with one argument and would have thrown.
    r = Resource("http://ctor.example.org/x")
    @test Jayhawk.owl_Thing(r).uri == r
    @test Jayhawk.owl_Ontology(r).uri == r
    @test Jayhawk.owl_Restriction(r).uri == r
    @test Jayhawk.owl_NamedIndividual(r).uri == r

    t = """
    PREFIX owl: <http://www.w3.org/2002/07/owl#>
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
    PREFIX on: <http://on.example.org/o#>
    on:MyOnt rdf:type owl:Ontology .
    on:Bob   rdf:type owl:NamedIndividual , owl:Thing .
    """
    tl = initialize()
    make_from_rdf(t, tl)
    @test haskey(tl.ldict, Resource("http://on.example.org/o#MyOnt"))
    @test haskey(tl.ldict, Resource("http://on.example.org/o#Bob"))
end

@testset "unprefixed terms are skipped, not fatal" begin
    # makeqname throws for an unregistered prefix (asserted above); analyze must not
    # propagate that and abandon the rest of the file.
    @test Jayhawk._qname(Resource("http://nowhere.invalid/o/Thing")) === nothing
    @test Jayhawk._qname(Resource("urn:data")) === :urn_data
end

@testset "analyze (pure)" begin

    src = """
    PREFIX owl: <http://www.w3.org/2002/07/owl#>
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
    PREFIX an: <http://an.example.org/o#>
    BASE <http://an.example.org/d/>

    an:Widget  rdf:type owl:Class .
    an:Gadget  rdf:type owl:Class ; rdfs:subClassOf an:Widget .
    an:knows   rdf:type owl:ObjectProperty ; rdfs:domain an:Widget ; rdfs:range an:Gadget .
    an:weight  rdf:type owl:DatatypeProperty ; rdfs:range xsd:float .

    :_w1 rdf:type an:Widget .
    :_w1 an:knows :_g1 .
    :_w1 an:undeclared "some text" .
    """

    m = analyze(Jayhawk.expand_uris(Serd.read_rdf_string(src)...))

    W = Resource("http://an.example.org/o#Widget")
    G = Resource("http://an.example.org/o#Gadget")
    K = Resource("http://an.example.org/o#knows")
    U = Resource("http://an.example.org/o#undeclared")

    @testset "classes are found" begin
        @test haskey(m.classes, W)
        @test haskey(m.classes, G)
    end

    @testset "subClassOf recorded" begin
        @test W in m.classes[G].supers
    end

    @testset "property kinds from rdf:type" begin
        @test m.properties[K].kind === :object
        @test m.properties[Resource("http://an.example.org/o#weight")].kind === :datatype
    end

    @testset "undeclared property inferred from usage" begin
        @test m.properties[U].kind === :inferred_data
    end

    @testset "domain and range captured" begin
        @test m.properties[K].domain == W
        @test m.properties[K].range == G
        @test m.properties[Resource("http://an.example.org/o#weight")].range ==
              Resource("http://www.w3.org/2001/XMLSchema#float")
    end

    @testset "schema declarations are not data" begin
        # `an:Widget rdf:type owl:Class` is consumed as schema...
        @test !any(t -> t.subject == W && t.object == Resource("http://www.w3.org/2002/07/owl#Class"),
                   m.data)
        # ...while instance typing stays as data.
        @test any(t -> t.subject == Resource("http://an.example.org/d/_w1") && t.object == W,
                  m.data)
    end

    @testset "analyze does not define anything" begin
        # Purely a data structure -- nothing reaches the module.
        @test !Jayhawk._defined(Jayhawk, :an_neverUsedName)
        @test m isa SchemaModel
    end
end

@testset "generate (pure)" begin

    src = """
    PREFIX owl: <http://www.w3.org/2002/07/owl#>
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
    PREFIX gn: <http://gn.example.org/o#>
    gn:Thing rdf:type owl:Class .
    gn:links rdf:type owl:ObjectProperty .
    """
    m = analyze(Jayhawk.expand_uris(Serd.read_rdf_string(src)...))

    @testset "returns an Expr without evaluating it" begin
        e = generate(m; skip_existing = false)
        @test e isa Expr
        txt = string(e)
        @test occursin("gn_Thing", txt)
        @test occursin("gn_links", txt)
        # nothing was installed by generating
        @test !Jayhawk._defined(Jayhawk, :gn_Thing)
    end

    @testset "no TraceLog is baked into generated code" begin
        txt = string(generate(m; skip_existing = false))
        @test !occursin("TraceLog{", txt)   # no interpolated TraceLog instance
        @test occursin("tl::TraceLog", txt) # taken as a parameter instead
    end

    @testset "skip_existing makes recompilation a no-op" begin
        install!(generate(m))
        second = generate(m)                # everything now exists
        @test isempty(second.args)
    end
end

@testset "Compile once, execute many" begin

    # A predicate is compiled the first time it is seen. Every subsequent run must
    # execute that existing code against the TraceLog it was handed -- and must not
    # write into the TraceLog that happened to trigger compilation.

    schema = """
    PREFIX owl: <http://www.w3.org/2002/07/owl#>
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
    PREFIX ex: <http://cox.example.org/o#>
    BASE <http://cox.example.org/d/>

    ex:Widget rdf:type owl:Class .
    ex:knows  rdf:type owl:ObjectProperty .

    :_a ex:knows :_b .
    """

    more = """
    PREFIX ex: <http://cox.example.org/o#>
    BASE <http://cox.example.org/d/>
    :_p ex:knows :_q .
    """

    _p = Resource("http://cox.example.org/d/_p")

    @testset "second run populates its own TraceLog" begin
        tl1 = initialize()
        make_from_rdf(schema, tl1)     # compiles ex_knows

        tl2 = initialize()
        make_from_rdf(more, tl2)       # must only execute

        @test haskey(tl2.ldict, _p)
    end

    @testset "second run does not write into the first TraceLog" begin
        tl1 = initialize()
        make_from_rdf(schema, tl1)

        tl2 = initialize()
        n1 = length(tl1.ldict)
        make_from_rdf(more, tl2)

        @test !haskey(tl1.ldict, _p)
        @test length(tl1.ldict) == n1
    end

    @testset "generated methods take no baked-in TraceLog default" begin
        tl = initialize()
        make_from_rdf(schema, tl)
        f = getfield(Jayhawk, :ex_knows)
        # A 2-argument form can only exist if `tl::TraceLog = <instance>` was compiled in.
        @test !any(m -> m.nargs - 1 == 2, methods(f))
    end

    @testset "repeated runs are deterministic" begin
        tlA = initialize(); make_from_rdf(schema, tlA)
        tlB = initialize(); make_from_rdf(schema, tlB)
        @test Set(keys(tlA.ldict)) == Set(keys(tlB.ldict))
    end

    @testset "the futures queue is gone" begin
        # Deferred calls existed only to dodge the world-age barrier created by
        # generating and calling code in the same dynamic extent.
        @test !hasfield(TraceLog, :futures)
        @test !isdefined(Jayhawk, :build_pass_two!)
    end
end

# QA pass over commit 3ca21e7 ("Fix the execution failures the split exposed"). That
# commit's own diagnosis and repair check out (0/833 gistAcct triples fail, 70/70 tests
# pass) -- these testsets are about coverage gaps found while reading the surrounding
# pipeline, not about the commit's own claims.
@testset "QA: gaps found while reviewing the execution-failure fix" begin

    @testset "colliding sanitized names merge two distinct properties" begin
        # KNOWN GAP, not fixed here. `sanitize_name` (src/rdf.jl) maps every
        # non-identifier character to `_`, so `ex:a-b` and `ex:a.b` -- two distinct RDF
        # properties -- both produce the Julia identifier `ex_a_b`. `generate` only
        # skips a name that is already *installed*; within one `generate` call both
        # properties still look "not yet defined" against the module, so both
        # contribute method definitions to the same generic function. This is
        # characterization, not approval: it should start FAILING the moment someone
        # makes colliding names distinct (or rejects the collision outright) -- that
        # failure is the signal to replace this test with one that checks the fix.
        t = """
        PREFIX owl: <http://www.w3.org/2002/07/owl#>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        PREFIX ex: <http://collide.example.org/o#>
        BASE <http://collide.example.org/d/>

        ex:a-b rdf:type owl:ObjectProperty .
        ex:a.b rdf:type owl:DatatypeProperty .

        :_s1 ex:a-b :_o1 .
        :_s2 ex:a.b "literal" .
        """
        m = analyze(Jayhawk.expand_uris(Serd.read_rdf_string(t)...))
        pA = Resource("http://collide.example.org/o#a-b")
        pB = Resource("http://collide.example.org/o#a.b")

        # Two distinct schema URIs really do map to the same generated identifier.
        @test m.properties[pA].name == :ex_a_b
        @test m.properties[pB].name == :ex_a_b
        @test m.properties[pA].kind == :object
        @test m.properties[pB].kind == :datatype

        install!(generate(m))
        f = Jayhawk._lookup(Jayhawk, :ex_a_b)
        # A lone ObjectProperty generator contributes 4 methods, a lone
        # DatatypeProperty generator 3. More than either alone would produce is
        # direct evidence both were installed under the one shared name.
        @test length(methods(f)) > 4

        tl = initialize()
        register!(m, tl)
        failures = 0
        for tr in m.data
            try
                Base.invokelatest(f, tr.subject, tr.object, tl)
            catch
                failures += 1
            end
        end
        # Both triples ran through the one merged function without erroring -- the
        # actual risk is silent wrong-property execution, not a crash. Exactly which
        # fields end up where depends on objprop_expr's/dataprop_expr's own storage
        # conventions (a separate, pre-existing quirk, not caused by this collision),
        # so this deliberately doesn't assert on ldict contents.
        @test failures == 0
    end

    @testset "run_data! survives an unexecutable triple without throwing" begin
        # `run_data!` only reports failures via `@info`, and the existing
        # "every gistAcct triple executes" test reimplements its loop rather than
        # calling it -- so nothing exercises run_data!'s own tolerance for a bad
        # triple through its real signature.
        t = """
        PREFIX owl: <http://www.w3.org/2002/07/owl#>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        PREFIX ex: <http://fail.example.org/o#>
        BASE <http://fail.example.org/d/>

        ex:good rdf:type owl:ObjectProperty .

        :_a ex:good :_b .
        """
        m = analyze(Jayhawk.expand_uris(Serd.read_rdf_string(t)...))
        # A predicate that was never declared or used: `_qname` resolves it fine (its
        # namespace prefix is registered), but no method was ever generated for it.
        bad = Triple(Resource("http://fail.example.org/d/_c"),
                     Resource("http://fail.example.org/o#neverDeclared"),
                     Resource("http://fail.example.org/d/_d"))
        push!(m.data, bad)

        tl = initialize()
        install!(generate(m))
        register!(m, tl)

        logs, _ = Test.collect_test_logs() do
            run_data!(m, tl)
        end
        @test any(r -> r.level == Logging.Info && occursin("did not execute", r.message),
                  logs)

        # the good triple still executed despite the bad one
        @test haskey(tl.ldict, Resource("http://fail.example.org/d/_a"))
    end

    @testset "blank-node rdf:type resolves to the intended bootstrap type" begin
        # FIXED. This was a characterization test asserting the broken behaviour; the
        # assertions below are its inverse.
        #
        # `resource_dict` was populated with `Resource("owl","Restriction")` -- the
        # two-arg *CURIE* constructor, producing a `ResourceCURIE`. Everything that
        # survives `expand_uris` is a `ResourceURI`, and the two never compare equal
        # under `@auto_hash_equals` even though they denote the same IRI, so
        # `retrieve!` missed all 38 bootstrap entries and returned `Unknown`.
        #
        # Named subjects escaped it only because `rdf_type(s::Resource, o::Resource)`
        # re-resolves the object against the module. The Blank entry point does not.
        #
        # The dict is now keyed by expanded IRI and typed `ExpandedTerm`
        # (= Union{ResourceURI,Blank}), so storing a CURIE key is a conversion error
        # rather than a silent miss.
        #
        # Correcting the record: the previous version of this comment claimed gistAcct
        # "has zero blank-node owl:Restriction triples". It has 62, plus 47 blank
        # owl:Class. "every gistAcct triple executes" passed throughout -- but only
        # because the Unknown path does not throw, so silent degradation counted as
        # success. That is precisely why the assertion below is about the *value*
        # stored, not about the absence of an exception.
        @test Resource("owl", "Restriction") isa ResourceCURIE
        @test Resource("http://www.w3.org/2002/07/owl#Restriction") isa ResourceURI
        @test Resource("owl", "Restriction") != Resource("http://www.w3.org/2002/07/owl#Restriction")
        @test haskey(Jayhawk.resource_dict, Resource("http://www.w3.org/2002/07/owl#Restriction"))
        @test all(k -> k isa ResourceURI, keys(Jayhawk.resource_dict))

        t = """
        PREFIX owl: <http://www.w3.org/2002/07/owl#>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>

        _:r1 rdf:type owl:Restriction .
        """
        tl = initialize()
        make_from_rdf(t, tl)
        blanks = [k for k in keys(tl.ldict) if k isa Blank]
        @test length(blanks) == 1
        @test tl.ldict[blanks[1]] isa Jayhawk.owl_Restriction
        @test tl.ldict[blanks[1]].uri == blanks[1]

        # the named subject keeps working
        t2 = """
        PREFIX owl: <http://www.w3.org/2002/07/owl#>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        PREFIX ex: <http://named.example.org/o#>
        ex:r1 rdf:type owl:Restriction .
        """
        tl2 = initialize()
        make_from_rdf(t2, tl2)
        @test tl2.ldict[Resource("http://named.example.org/o#r1")] isa Jayhawk.owl_Restriction
    end

    @testset "every blank-node rdf:type in the fixtures resolves" begin
        # The assertion that would have caught the original bug. "every gistAcct triple
        # executes" could not: it only checks that nothing throws, and the broken path
        # returned Unknown quietly.
        #
        # Checks resolution at `retrieve!` rather than the value finally left in ldict,
        # because ldict is last-write-wins: a restriction's own owl:onProperty /
        # owl:someValuesFrom triples overwrite its entry afterwards. That overwriting is
        # a separate, pre-existing trait of ldict and applies to named subjects
        # identically -- see the characterization testset below.
        RDFTYPE = Resource("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
        for f in ("jayhawk.ttl", "gistAcct3.0.0.ttl")
            ttl = read(joinpath(@__DIR__, "..", "resource", f), String)
            m = analyze(Jayhawk.expand_uris(Serd.read_rdf_string(ttl)...))
            install!(generate(m))
            tl = initialize()
            register!(m, tl)

            blank_typings = [t for t in m.data
                             if t.predicate == RDFTYPE && t.subject isa Blank]
            @test !isempty(blank_typings)

            unresolved = [t for t in blank_typings
                          if Jayhawk.retrieve!(tl, t.object) isa Unknown]
            @test isempty(unresolved)
        end
    end

    @testset "blank nodes as subjects of any bootstrap type" begin
        # Once retrieve! started resolving these, blank subjects reached dispatch for
        # real. owl_Thing / owl_Ontology / owl_NamedIndividual accepted only Resource
        # and raised MethodError -- trading a silent wrong answer for a silently
        # dropped triple, since run_data! catches. owl_Class had only a Blank method,
        # so the *named* case raised instead. `_:x a _:y` matched nothing at all.
        owl(l) = Resource("http://www.w3.org/2002/07/owl#" * l)
        s_named = Resource("http://any.example.org/s")
        b = Blank("x")

        for (localname, T) in (("Restriction",     Jayhawk.owl_Restriction),
                               ("Class",           Jayhawk.owl_Class),
                               ("Thing",           Jayhawk.owl_Thing),
                               ("Ontology",        Jayhawk.owl_Ontology),
                               ("NamedIndividual", Jayhawk.owl_NamedIndividual))
            tlb = initialize()
            rdf_type(b, owl(localname), tlb)
            @test tlb.ldict[b] isa T

            tln = initialize()
            rdf_type(s_named, owl(localname), tln)
            @test tln.ldict[s_named] isa T
        end

        # blank subject with a blank object, and vice versa: both stored, neither throws
        tl = initialize()
        rdf_type(b, Blank("y"), tl)
        @test tl.ldict[b] == Blank("y")
        rdf_type(s_named, Blank("y"), tl)
        @test tl.ldict[s_named] == Blank("y")

        # an object in an unregistered namespace used to throw KeyError out of
        # makeqname; the entry point now uses _qname, which returns nothing
        rdf_type(s_named, Resource("http://nowhere.invalid/o/T"), tl)
        @test tl.ldict[s_named] isa Unknown
    end

    @testset "blank nodes are valid instances of generated classes" begin
        # Second, independent bug. class_expr typed the generated struct field
        # `uri::Resource` and emitted rdf_type only for Resource and Unknown, so
        # `_:x a ex:Widget` -- ordinary Turtle, written `[ a ex:Widget ]` -- threw
        # MethodError and run_data! dropped the triple. Widening the method alone would
        # not have been enough: construction would have failed instead of dispatch.
        t = """
        PREFIX owl: <http://www.w3.org/2002/07/owl#>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        PREFIX ex: <http://bnclass.example.org/o#>
        ex:Widget rdf:type owl:Class .
        _:anon    rdf:type ex:Widget .
        ex:named  rdf:type ex:Widget .
        """
        tl = initialize()
        make_from_rdf(t, tl)

        W = Jayhawk._lookup(Jayhawk, :ex_Widget)
        @test fieldtype(W, :uri) == RORB

        b = only(k for k in keys(tl.ldict) if k isa Blank)
        @test tl.ldict[b] isa W
        @test tl.ldict[b].uri == b
        @test tl.ldict[Resource("http://bnclass.example.org/o#named")] isa W
    end

    @testset "the anonymous-restriction idiom executes cleanly" begin
        # `ex:C rdfs:subClassOf [ a owl:Restriction ; owl:onProperty ex:p ]` is how
        # essentially every OWL ontology is written, and it exercises blank subjects
        # for both rdf:type and ordinary properties.
        t = """
        PREFIX owl: <http://www.w3.org/2002/07/owl#>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
        PREFIX ex: <http://anon.example.org/o#>
        ex:C rdf:type owl:Class ;
             rdfs:subClassOf [ rdf:type owl:Restriction ; owl:onProperty ex:p ] .
        """
        m = analyze(Jayhawk.expand_uris(Serd.read_rdf_string(t)...))
        install!(generate(m))
        tl = initialize()
        register!(m, tl)

        failures = Any[]
        for tr in m.data
            nm = Jayhawk._qname(tr.predicate)
            (nm === nothing || !Jayhawk._defined(Jayhawk, nm)) &&
                (push!(failures, (tr, :undefined)); continue)
            try
                Base.invokelatest(Jayhawk._lookup(Jayhawk, nm), tr.subject, tr.object, tl)
            catch e
                push!(failures, (tr, e))
            end
        end
        @test isempty(failures)
    end

    @testset "KNOWN GAP: ldict is last-write-wins, and blank subClassOf edges are lost" begin
        # Neither of these is a blank-node bug, and neither is fixed here -- but both
        # were found while fixing one, and both would otherwise be mistaken for it.

        # (1) ldict holds ONE value per key, so a node's type is overwritten by its own
        # property triples. This hits named subjects identically, which is what shows it
        # is not about blank nodes.
        t = """
        PREFIX owl: <http://www.w3.org/2002/07/owl#>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        PREFIX ex: <http://clobber.example.org/o#>
        ex:r rdf:type owl:Restriction ; owl:onProperty ex:p .
        """
        tl = initialize()
        make_from_rdf(t, tl)
        # the owl_Restriction built by rdf_type has been replaced by owl:onProperty's object
        @test !(tl.ldict[Resource("http://clobber.example.org/o#r")] isa Jayhawk.owl_Restriction)

        # (2) analyze guards rdfs:subClassOf on `s isa Resource && o isa Resource`, so
        # the standard anonymous-superclass idiom records no edge. Representing
        # anonymous class expressions is a design question: ClassSpec.supers is a
        # Vector{Resource} and cannot hold a Blank.
        t2 = """
        PREFIX owl: <http://www.w3.org/2002/07/owl#>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
        PREFIX ex: <http://supers.example.org/o#>
        ex:C rdf:type owl:Class ;
             rdfs:subClassOf [ rdf:type owl:Restriction ] .
        """
        m2 = analyze(Jayhawk.expand_uris(Serd.read_rdf_string(t2)...))
        @test isempty(m2.classes[Resource("http://supers.example.org/o#C")].supers)
    end

    @testset "conflicting explicit property kinds: first explicit kind wins" begin
        # `_ensure_prop!` only upgrades :inferred_* -> explicit; there is no rule for
        # explicit -> different explicit (invalid OWL, but real files sometimes have
        # it). Not a bug fix here -- pinning down today's actual, undocumented
        # tie-break so a future change to `_ensure_prop!` shows up as a deliberate
        # decision rather than a silent behavior change.
        t = """
        PREFIX owl: <http://www.w3.org/2002/07/owl#>
        PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
        PREFIX ex: <http://conflict.example.org/o#>

        ex:p rdf:type owl:ObjectProperty .
        ex:p rdf:type owl:DatatypeProperty .
        """
        m = analyze(Jayhawk.expand_uris(Serd.read_rdf_string(t)...))
        @test m.properties[Resource("http://conflict.example.org/o#p")].kind == :object
    end
end

# Everything above is hermetic: no network, no server, ~6 seconds. Keep it that way.
#
# The SPARQL integration tests need a live Apache Jena Fuseki and are therefore opt-in.
# Without JAYHAWK_TEST_SPARQL set they are not even loaded, so a developer with no
# server running never sees a failure from them.
#
#     ./resource/fuseki-test.sh start
#     JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl
if haskey(ENV, "JAYHAWK_TEST_SPARQL")
    include("sparql_integration.jl")
end
