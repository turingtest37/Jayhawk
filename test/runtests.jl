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

    @testset "retrieve no default provided" begin
        tl = TraceLog(true)
        @test retrieve(tl, Resource("/bogus")) == Unknown(Resource("/bogus"))
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

    @testset "run_data! tolerates a triple with no generated function" begin
        # `run_data!` used to catch *everything* into one `failed` counter and only
        # `@debug` the exception. That is how an `UndefVarError` from an undefined
        # `retrieve!` masqueraded as "833 triples did not execute" for a whole release.
        # It now separates three outcomes; this covers the benign one.
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

        logs, _ = Test.collect_test_logs(min_level = Logging.Debug) do
            run_data!(m, tl)
        end
        # Unmapped is ordinary, not a failure: a document may reference predicates
        # outside the schema it declares. Reported at debug, and never fatal.
        @test any(r -> occursin("no generated function", r.message), logs)

        # the good triple still executed despite the bad one
        @test haskey(tl.ldict, Resource("http://fail.example.org/d/_a"))
    end

    @testset "run_data! raises on a broken call instead of swallowing it" begin
        # The regression that motivated the split. A generated function exists and
        # dispatch succeeds, but the body raises something that is not a MethodError
        # about that function -- a defect in Jayhawk, not in the data. Under the old
        # blanket catch this was indistinguishable from an unmapped predicate.
        Core.eval(Jayhawk, :(ex_boom(s, o, tl::TraceLog) = error("deliberate defect")))

        m = SchemaModel()
        push!(m.data, Triple(Resource("http://fail.example.org/d/_x"),
                             Resource("http://fail.example.org/o#boom"),
                             Resource("http://fail.example.org/d/_y")))
        tl = initialize()

        # strict (the default) surfaces it, and names the offending triple
        err = try
            run_data!(m, tl); nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("boom", sprint(showerror, err))
        @test occursin("deliberate defect", sprint(showerror, err))

        # strict = false keeps the old sweep-up behaviour for known-dirty data
        logs, _ = Test.collect_test_logs(min_level = Logging.Debug) do
            @test run_data!(m, tl; strict = false) === tl
        end
        @test any(r -> r.level == Logging.Warn &&
                       occursin("non-dispatch error", r.message), logs)
    end

    @testset "blank-node rdf:type resolves to the intended bootstrap type" begin
        # FIXED. This was a characterization test asserting the broken behaviour; the
        # assertions below are its inverse.
        #
        # `resource_dict` was populated with `Resource("owl","Restriction")` -- the
        # two-arg *CURIE* constructor, producing a `ResourceCURIE`. Everything that
        # survives `expand_uris` is a `ResourceURI`, and the two never compare equal
        # under `@auto_hash_equals` even though they denote the same IRI, so
        # `retrieve` missed all 38 bootstrap entries and returned `Unknown`.
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
        # Checks resolution at `retrieve` rather than the value finally left in ldict,
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
                          if Jayhawk.retrieve(tl, t.object) isa Unknown]
            @test isempty(unresolved)
        end
    end

    @testset "blank nodes as subjects of any bootstrap type" begin
        # Once retrieve started resolving these, blank subjects reached dispatch for
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

@testset "RDFTerm keeps what Serd throws away" begin
    # The whole reason src/term.jl exists. Serd's Literal has one `langordt` field for two
    # mutually exclusive concepts and its parser never puts a datatype there at all, so
    # after parsing `"42"^^ex:custom` is byte-identical to plain `"42"`. That is fatal for
    # a rule engine whose variable marker *is* a datatype.

    @testset "custom datatypes survive and stay distinct" begin
        typed  = RDFLiteral("42", "http://ex.org/custom")
        plain  = RDFLiteral("42")
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
        @test term_from_json(Dict("type" => "literal", "value" => "42",
                                  "datatype" => "http://ex.org/dt")) ==
              RDFLiteral("42", "http://ex.org/dt")
        @test term_from_json(Dict("type" => "literal", "value" => "hi",
                                  "xml:lang" => "en")) == RDFLiteral("hi", nothing, "en")
        # "typed-literal" is not in the JSON spec but some stores still emit it
        @test term_from_json(Dict("type" => "typed-literal", "value" => "1",
                                  "datatype" => "http://ex.org/dt")).datatype ==
              "http://ex.org/dt"
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
        @test_throws ArgumentError var_name(RDFLiteral("?1startsWithDigit", Jayhawk.GISTP_VAR))
    end
end

@testset "compiler (pure)" begin
    # compile_rule is a pure function of a RuleSpec, so the whole of it is testable with
    # no server running. These specs are built by hand; loading one out of a store is
    # exercised in test/sparql_integration.jl.
    G    = "https://w3id.org/semanticarts/ns/ontology/gist/"
    HR   = "http://example.org/hr/"
    R    = "http://example.org/rules/"
    TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"

    iri(s) = IRIRef(s)
    var(s) = RDFLiteral(s, Jayhawk.GISTP_VAR)

    person_to_employee(; mode = Jayhawk.MODE_CONSTRUCT) = RuleSpec(
        "$(R)PersonToEmployee", mode, "$(R)PersonToEmployee_L", "$(R)PersonToEmployee_R",
        [PatternTriple(iri("$(R)_Person_1"), iri(TYPE),              iri("$(G)Person")),
         PatternTriple(iri("$(R)_Person_1"), iri("$(G)isIdentifiedBy"), iri("$(R)_ID_1")),
         PatternTriple(iri("$(R)_ID_1"),     iri(TYPE),              iri("$(G)ID")),
         PatternTriple(iri("$(R)_ID_1"),     iri("$(G)containedText"), var("?idText"))],
        [PatternTriple(iri("$(R)_Person_1"), iri(TYPE),                iri("$(HR)Employee")),
         PatternTriple(iri("$(R)_Person_1"), iri("$(HR)employeeNumber"), var("?idText"))],
        Dict("$(R)_Person_1" => "?_Person_1", "$(R)_ID_1" => "?_ID_1"),
        Dict{String,MintSpec}())

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
        sorted = RuleSpec(spec.iri, spec.mode, spec.match_graph, spec.construct_graph,
                          sort(spec.match; by = t -> (sparql_text(t.subject), sparql_text(t.predicate), sparql_text(t.object))),
                          sort(spec.construct; by = t -> (sparql_text(t.subject), sparql_text(t.predicate), sparql_text(t.object))),
                          spec.variables, spec.mints)
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
        @test body(person_to_employee(mode = Jayhawk.MODE_CONSTRUCT)) ==
              body(person_to_employee(mode = Jayhawk.MODE_ASSERT))
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
        withI = RuleSpec(spec.iri, spec.mode, spec.match_graph, spec.construct_graph,
                         spec.match, vcat(spec.construct, [shared]), spec.variables, spec.mints)
        @test length(interface(withI)) == 1
        @test length(match_only(withI)) == length(spec.match) - 1
        @test length(construct_only(withI)) == length(spec.construct)
        # I ∪ (L∖I) partitions L, with no overlap
        @test length(interface(withI)) + length(match_only(withI)) == length(withI.match)
    end

    @testset "Rewrite compiles to DELETE L∖I / INSERT R∖I" begin
        spec = person_to_employee(mode = Jayhawk.MODE_REWRITE)
        shared = spec.match[1]                     # ?_Person_1 a gist:Person
        rw = RuleSpec(spec.iri, spec.mode, spec.match_graph, spec.construct_graph,
                      spec.match, vcat(spec.construct, [shared]), spec.variables, spec.mints)
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
        spec = person_to_employee(mode = Jayhawk.MODE_REWRITE)
        identical = RuleSpec(spec.iri, spec.mode, spec.match_graph, spec.construct_graph,
                             spec.match, spec.match, spec.variables, spec.mints)
        @test isempty(match_only(identical)) && isempty(construct_only(identical))
        err = try rewrite_query(identical; target = "urn:t", firing = "urn:f",
                                tombstone = "urn:tomb") catch e; e end
        @test occursin("deletes nothing and adds nothing", sprint(showerror, err))
    end

    @testset "insert_query refuses a Rewrite, and rewrite_query refuses the others" begin
        rw = person_to_employee(mode = Jayhawk.MODE_REWRITE)
        @test occursin("rewrite_query", sprint(showerror,
            try insert_query(rw; into = "urn:g") catch e; e end))
        @test occursin("insert_query", sprint(showerror,
            try rewrite_query(person_to_employee(); target = "urn:t", firing = "urn:f",
                              tombstone = "urn:tomb") catch e; e end))
    end

    @testset "the dangling risk is detected, not silently deleted" begin
        # SPARQL Update is single-pushout: it deletes what it is told and never checks for
        # stranded referents. A variable whose every occurrence in L is removed, and which R
        # never mentions, is exactly the shape that leaves orphans.
        spec = person_to_employee(mode = Jayhawk.MODE_REWRITE)
        shared = spec.match[1]
        rw = RuleSpec(spec.iri, spec.mode, spec.match_graph, spec.construct_graph,
                      spec.match, vcat(spec.construct, [shared]), spec.variables, spec.mints)
        # ?_ID_1 loses both of its triples and appears nowhere in R
        @test "?_ID_1" in dangling_risks(rw)
        # ?_Person_1 survives -- one of its triples is preserved, and R uses it
        @test !("?_Person_1" in dangling_risks(rw))
        # a rule that preserves everything strands nothing
        @test isempty(dangling_risks(RuleSpec(spec.iri, spec.mode, spec.match_graph,
            spec.construct_graph, spec.match, spec.match, spec.variables, spec.mints)))
    end

    @testset "rewrite_query records what it removes" begin
        spec = person_to_employee(mode = Jayhawk.MODE_REWRITE)
        shared = spec.match[1]
        rw = RuleSpec(spec.iri, spec.mode, spec.match_graph, spec.construct_graph,
                      spec.match, vcat(spec.construct, [shared]), spec.variables, spec.mints)
        q = rewrite_query(rw; target = "urn:t", firing = "urn:f", tombstone = "urn:tomb",
                          from = ["urn:t"])
        @test occursin("DELETE {\n  GRAPH <urn:t>", q)
        @test occursin("GRAPH <urn:f>", q)         # what was added
        @test occursin("GRAPH <urn:tomb>", q)      # what was removed -- undo needs this
        @test occursin("USING <urn:t>", q)
        # the tombstone template is exactly L∖I
        @test occursin(bgp_text(match_only(rw), rw; indent = "    "), q)
    end

    @testset "unknown mode is refused" begin
        @test_throws ArgumentError compile_rule(person_to_employee(mode = "http://ex.org/Nope"))
    end

    @testset "use-before-def: a typo in a literal variable is caught" begin
        # The failure an LLM author hits most: literal-position variables are matched across
        # L and R by string equality of the lexical form, so ?idtext against ?idText is a
        # name error nowhere -- it just silently constructs nothing.
        spec = person_to_employee()
        typo = RuleSpec(spec.iri, spec.mode, spec.match_graph, spec.construct_graph,
                        spec.match,
                        [PatternTriple(iri("$(R)_Person_1"), iri("$(HR)employeeNumber"), var("?idtext"))],
                        spec.variables, spec.mints)
        err = try compile_rule(typo) catch e; e end
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
    minting_rule(; template = "http://example.org/hr/employee/{id}",
                   slots = Dict{String,RDFTerm}("id" => var("?idText")),
                   extra_match = PatternTriple[]) = RuleSpec(
        "$(R)PersonToEmployeeRecord", Jayhawk.MODE_ASSERT,
        "$(R)PersonToEmployeeRecord_L", "$(R)PersonToEmployeeRecord_R",
        vcat([PatternTriple(iri("$(R)_Person_1"), iri(TYPE),                 iri("$(G)Person")),
              PatternTriple(iri("$(R)_Person_1"), iri("$(G)isIdentifiedBy"), iri("$(R)_ID_1")),
              PatternTriple(iri("$(R)_ID_1"),     iri(TYPE),                 iri("$(G)ID")),
              PatternTriple(iri("$(R)_ID_1"),     iri("$(G)containedText"),  var("?idText"))],
             extra_match),
        [PatternTriple(iri("$(R)_Employee_1"), iri(TYPE),                     iri("$(HR)Employee")),
         PatternTriple(iri("$(R)_Employee_1"), iri("$(HR)employeeNumber"),    var("?idText")),
         PatternTriple(iri("$(R)_Employee_1"), iri("$(HR)isRecordFor"),       iri("$(R)_Person_1"))],
        Dict("$(R)_Person_1" => "?_Person_1", "$(R)_ID_1" => "?_ID_1",
             "$(R)_Employee_1" => "?_Employee_1"),
        Dict("$(R)_Employee_1" => MintSpec("$(R)_Employee_1", template, slots)))

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
            err = try parse_template("http://ex.org/{$(op)id}") catch e; e end
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
            "ENCODE_FOR_URI(STR(?idText)))) AS ?_Employee_1)", q)
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
        spec = minting_rule(extra_match = [
            PatternTriple(iri("$(R)_Employee_1"), iri(TYPE), iri("$(HR)Employee"))])
        err = try compile_rule(spec) catch e; e end
        msg = sprint(showerror, err)
        @test occursin("declares it minted", msg)
        @test occursin("?_Employee_1", msg)
    end

    @testset "a relative template is refused" begin
        # ":_Employee_{id}" would mint into whatever the rule document's empty prefix names
        # -- for a rules file, the rules namespace.
        err = try compile_rule(minting_rule(template = ":_Employee_{id}")) catch e; e end
        msg = sprint(showerror, err)
        @test occursin("relative", msg)
        @test occursin("absolute IRI", msg)
    end

    @testset "unbound and unknown slots are refused" begin
        # a {slot} the template has but nothing binds
        err = try
            compile_rule(minting_rule(template = "http://ex.org/e/{id}/{missing}"))
        catch e; e end
        @test occursin("{missing}", sprint(showerror, err))

        # a binding naming a slot the template does not contain -- a half-applied rename
        err = try
            compile_rule(minting_rule(slots = Dict{String,RDFTerm}(
                "id" => var("?idText"), "stale" => var("?idText"))))
        catch e; e end
        @test occursin("stale", sprint(showerror, err))

        # a template with no bindings at all
        err = try
            compile_rule(minting_rule(slots = Dict{String,RDFTerm}()))
        catch e; e end
        @test occursin("{id}", sprint(showerror, err))
    end

    @testset "a slot value must be bound by L" begin
        # minting from a variable L never binds -- including from another minted variable,
        # which would need the BINDs topologically ordered
        err = try
            compile_rule(minting_rule(slots = Dict{String,RDFTerm}("id" => var("?nowhere"))))
        catch e; e end
        msg = sprint(showerror, err)
        @test occursin("?nowhere", msg)
        @test occursin("never binds", msg)

        # and a slot bound to something that is not a variable at all
        err = try
            compile_rule(minting_rule(slots = Dict{String,RDFTerm}(
                "id" => RDFLiteral("just a string"))))
        catch e; e end
        @test occursin("not a variable", sprint(showerror, err))
    end

    @testset "ambiguous slot separators are refused" begin
        # In RDF an IRI *is* the identity, so two distinct binding tuples expanding to one
        # IRI silently merges two things into one node. ENCODE_FOR_URI leaves the unreserved
        # set alone, so a separator drawn from it cannot be told apart from the same
        # characters inside a value: "x_y"+"z" and "x"+"y_z" both give x_y_z.
        @test ambiguous_separators("http://ex.org/{a}_{b}") == ["_"]
        @test ambiguous_separators("http://ex.org/{a}{b}")  == [""]     # adjacent slots
        @test ambiguous_separators("http://ex.org/{a}-{b}.{c}") == ["-", "."]
        # a separator the encoder escapes is unambiguous: values containing it get %2F
        @test isempty(ambiguous_separators("http://ex.org/{a}/{b}"))
        # single-slot templates are always safe, and fixed prefixes/suffixes never collide
        # because they are identical for every binding
        @test isempty(ambiguous_separators("http://ex.org/one/{a}"))
        @test isempty(ambiguous_separators("http://ex.org/{a}_end"))

        two_slot(sep) = minting_rule(
            template = "http://example.org/hr/employee/{id}$(sep){b}",
            slots = Dict{String,RDFTerm}("id" => var("?idText"), "b" => var("?idText")))
        err = try compile_rule(two_slot("_")) catch e; e end
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
        qs = collision_queries(spec; from = ["urn:g"])
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

    @testset "slot values may be IRI-position variables too" begin
        # gistp:slotValue accepts either mechanism. Binding :_ID_1 mints from that node's
        # IRI rather than from its text -- a different rule, but a legal one.
        q = compile_rule(minting_rule(
            slots = Dict{String,RDFTerm}("id" => iri("$(R)_ID_1"))))
        @test occursin("ENCODE_FOR_URI(STR(?_ID_1))", q)
    end

    # ---------------------------------------------------------------------
    # gistp:oneOf -- one VALUES clause, two readings
    # ---------------------------------------------------------------------

    with_enums(spec, enums) = RuleSpec(
        spec.iri, spec.mode, spec.match_graph, spec.construct_graph,
        spec.match, spec.construct, spec.variables, spec.mints,
        enums, spec.nacs, spec.strategy, spec.priority, spec.max_iterations)

    @testset "oneOf emits VALUES, sorted and byte-stable" begin
        spec = with_enums(person_to_employee(),
            Dict("$(R)_ID_1" => RDFTerm[iri("$(G)c"), iri("$(G)a"), iri("$(G)b")]))
        q = compile_rule(spec)
        # sorted, not in authored order: VALUES is a set of solutions, so authored order
        # carries no meaning and sorting is what keeps output byte-stable
        @test occursin("VALUES ?_ID_1 { <$(G)a> <$(G)b> <$(G)c> }", q)
        @test q == compile_rule(spec)
    end

    @testset "the same clause constrains or generates, decided by the rest of the rule" begin
        # constrain: the variable is ALSO bound by L, so the clause is a join
        constrain = with_enums(person_to_employee(),
            Dict("$(R)_ID_1" => RDFTerm[iri("$(G)a")]))
        # generate: a variable that appears only in R, bound by nothing but its VALUES
        base = person_to_employee()
        gen = RuleSpec(base.iri, base.mode, base.match_graph, base.construct_graph,
            base.match,
            [PatternTriple(iri("$(R)_Person_1"), iri("$(HR)tag"), iri("$(R)_Tag"))],
            merge(base.variables, Dict("$(R)_Tag" => "?_Tag")), base.mints,
            Dict("$(R)_Tag" => RDFTerm[RDFLiteral("x"), RDFLiteral("y")]),
            base.nacs, base.strategy, base.priority, base.max_iterations)

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
        gen = RuleSpec(base.iri, base.mode, base.match_graph, base.construct_graph,
            base.match, base.construct,
            merge(base.variables, Dict("$(R)_Reg" => "?_Reg")),
            Dict("$(R)_Employee_1" => MintSpec("$(R)_Employee_1",
                 "http://example.org/hr/employee/{id}/{reg}",
                 Dict{String,RDFTerm}("id" => var("?idText"), "reg" => iri("$(R)_Reg")))),
            Dict("$(R)_Reg" => RDFTerm[RDFLiteral("EU"), RDFLiteral("US")]),
            base.nacs, base.strategy, base.priority, base.max_iterations)
        q = compile_rule(gen)
        @test occursin("ENCODE_FOR_URI(STR(?_Reg))", q)
        @test findfirst("VALUES ?_Reg", q).start < findfirst("BIND(", q).start
    end

    @testset "broken enumerations are refused" begin
        spec = person_to_employee()
        # an empty list yields no solutions, so the rule can never fire
        empty = with_enums(spec, Dict("$(R)_ID_1" => RDFTerm[]))
        @test occursin("never fire", sprint(showerror, try compile_rule(empty) catch e; e end))

        # enumerated AND constructed is contradictory
        both = with_enums(minting_rule(),
            Dict("$(R)_Employee_1" => RDFTerm[RDFLiteral("a")]))
        @test occursin("Choose one", sprint(showerror, try compile_rule(both) catch e; e end))

        # no variableText, so there is no SPARQL variable for VALUES to bind
        noname = with_enums(spec, Dict("$(R)_undeclared" => RDFTerm[RDFLiteral("a")]))
        @test occursin("no gistp:variableText",
                       sprint(showerror, try compile_rule(noname) catch e; e end))
    end


    @testset "empty patterns are refused" begin
        spec = person_to_employee()
        empty_l = RuleSpec(spec.iri, spec.mode, spec.match_graph, spec.construct_graph,
                           PatternTriple[], spec.construct, spec.variables, spec.mints)
        # an empty L binds nothing, so use-before-def fires first -- either way it is refused
        @test_throws Exception compile_rule(empty_l)
    end

    # ---------------------------------------------------------------------
    # Control layer: negative conditions, strategy, budget
    # ---------------------------------------------------------------------

    nac(triples...) = NacSpec("$(R)Probe_N", collect(PatternTriple, triples))

    with_control(; nacs = NacSpec[], strategy = nothing, priority = 0,
                   max_iterations = nothing, mode = Jayhawk.MODE_CONSTRUCT) =
        (s = person_to_employee(mode = mode);
         RuleSpec(s.iri, s.mode, s.match_graph, s.construct_graph, s.match, s.construct,
                  s.variables, s.mints, nacs, strategy, priority, max_iterations))

    @testset "a negative condition becomes FILTER NOT EXISTS" begin
        s = with_control(nacs = [nac(PatternTriple(iri("$(R)_Person_1"), iri(TYPE),
                                                   iri("$(HR)Employee")))])
        q = compile_rule(s)
        @test occursin("FILTER NOT EXISTS {", q)
        @test occursin("?_Person_1 <$(TYPE)> <$(HR)Employee> .", q)
        # the guard names the graph it came from, so a reader can find it
        @test occursin("# NOT <$(R)Probe_N>", q)
    end

    @testset "several conditions are conjunctive, not one big block" begin
        # Each must fail independently. One filter containing both triples would instead
        # mean "not (A and B)", which is a strictly weaker guard.
        a = NacSpec("$(R)N1", [PatternTriple(iri("$(R)_Person_1"), iri(TYPE), iri("$(HR)Employee"))])
        b = NacSpec("$(R)N2", [PatternTriple(iri("$(R)_ID_1"), iri(TYPE), iri("$(HR)Employee"))])
        q = compile_rule(with_control(nacs = [a, b]))
        @test length(collect(eachmatch(r"FILTER NOT EXISTS \{", q))) == 2
    end

    @testset "an empty condition is skipped, not emitted" begin
        # FILTER NOT EXISTS { } can never fail, so emitting one would silently disable the
        # rule -- the worst possible reading of "the author left this graph empty".
        q = compile_rule(with_control(nacs = [NacSpec("$(R)Empty", PatternTriple[])]))
        @test !occursin("FILTER NOT EXISTS", q)
    end

    @testset "the WHERE body orders match, then BIND, then filters" begin
        # Load-bearing: BIND sees only what precedes it, and a condition may mention a
        # MINTED variable -- which is how a rule says "only create this if it is not there".
        s = minting_rule()
        guarded = RuleSpec(s.iri, s.mode, s.match_graph, s.construct_graph, s.match,
                           s.construct, s.variables, s.mints,
                           [NacSpec("$(R)N", [PatternTriple(iri("$(R)_Employee_1"), iri(TYPE),
                                                            iri("$(HR)Employee"))])],
                           nothing, 0, nothing)
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
        guarded = RuleSpec(s.iri, s.mode, s.match_graph, s.construct_graph, s.match,
                           s.construct, s.variables, s.mints,
                           [NacSpec("$(R)N", [PatternTriple(iri("$(R)_Employee_1"), iri(TYPE),
                                                            iri("$(HR)Employee"))])],
                           nothing, 0, nothing)
        @test occursin("FILTER NOT EXISTS", compile_rule(guarded))
        @test occursin("FILTER NOT EXISTS", insert_query(guarded; into = "urn:g"))
        @test occursin("FILTER NOT EXISTS",
                       project_query(guarded; triples = guarded.construct, into = "urn:g"))
        @test all(occursin("FILTER NOT EXISTS", q) for (_, q) in collision_queries(guarded))
    end

    @testset "strategy resolves caller over rule over mode" begin
        @test effective_strategy(with_control()) === :Once                 # Construct
        @test effective_strategy(with_control(mode = Jayhawk.MODE_ASSERT)) === :ToFixpoint
        @test effective_strategy(with_control(mode = Jayhawk.MODE_REWRITE)) === :Once
        # the rule's own declaration beats the mode default
        @test effective_strategy(with_control(strategy = :ToFixpoint)) === :ToFixpoint
        # and the caller beats the rule -- the same rule may be applied once during review
        # and to a fixpoint in a batch
        @test effective_strategy(with_control(strategy = :ToFixpoint);
                                 strategy = :Once) === :Once
        @test_throws ArgumentError effective_strategy(with_control(); strategy = :Sideways)
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
        rw = with_control(mode = Jayhawk.MODE_REWRITE, strategy = :ToFixpoint)
        err = try run_rule(rw; source = ["urn:g"]) catch e; e end
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin("negative condition", msg) && occursin("maxIterations", msg)

        # stating either one satisfies it (both then fail later, on the empty match pattern
        # or the missing server -- what matters is that this check no longer fires)
        bounded = with_control(mode = Jayhawk.MODE_REWRITE, strategy = :ToFixpoint,
                               max_iterations = 3)
        @test !(try run_rule(bounded; source = ["urn:g"]) catch e; e end isa ArgumentError &&
                occursin("negative condition", sprint(showerror,
                    try run_rule(bounded; source = ["urn:g"]) catch e; e end)))
    end

    @testset "a blank node in a pattern is refused, with the fix spelled out" begin
        # A blank node is an undeclared variable: it cannot be validated, cannot carry
        # oneOf or iriTemplate, does not connect L to R (SPARQL will not carry one from
        # WHERE into CONSTRUCT), and is illegal outright in the DELETE a Rewrite emits.
        base = person_to_employee()
        withbn(field) = RuleSpec(base.iri, base.mode, base.match_graph, base.construct_graph,
            field === :L ? vcat(base.match,
                    [PatternTriple(BNode("x"), iri("$(G)isIdentifiedBy"), iri("$(R)_ID_1"))]) : base.match,
            field === :R ? vcat(base.construct,
                    [PatternTriple(iri("$(R)_Person_1"), iri("$(HR)worksAt"), BNode("y"))]) : base.construct,
            base.variables, base.mints)

        for (where, spec) in ((:L, withbn(:L)), (:R, withbn(:R)))
            err = try compile_rule(spec) catch e; e end
            msg = sprint(showerror, err)
            @test occursin("blank node", msg)
            # the message has to be actionable, not just correct
            @test occursin("gistp:SparqlVariable", msg)
            @test occursin("gistp:variableText", msg)
            @test occursin("->", msg)                 # the substitution to make
        end

        # a negative condition is checked too
        nacbn = RuleSpec(base.iri, base.mode, base.match_graph, base.construct_graph,
            base.match, base.construct, base.variables, base.mints,
            Dict{String,Vector{RDFTerm}}(),
            [NacSpec("$(R)N", [PatternTriple(BNode("z"), iri(TYPE), iri("$(HR)Employee"))])],
            nothing, 0, nothing)
        @test occursin("negative condition", sprint(showerror,
            try compile_rule(nacbn) catch e; e end))

        # and a rule with none still compiles
        @test compile_rule(base) isa String
    end

    @testset "an enumerated IRI is validated like every other" begin
        # values_text used sparql_text, which wraps an IRI in <> and checks nothing, while
        # every other IRI goes through term_sparql -> check_iri. A member containing '>'
        # closed the clause and opened another.
        payload = "http://ex.org/a> } INSERT { <urn:x> <urn:y> <urn:z> } WHERE { VALUES ?c { <http://ex.org/b"
        s = person_to_employee()
        bad = RuleSpec(s.iri, s.mode, s.match_graph, s.construct_graph, s.match, s.construct,
                       merge(s.variables, Dict("$(R)_c" => "?c")), s.mints,
                       Dict{String,Vector{RDFTerm}}("$(R)_c" => RDFTerm[iri(payload)]),
                       NacSpec[], nothing, 0, nothing)
        @test_throws ArgumentError compile_rule(bad)

        # a literal member stays safe by escaping, which is the correct mechanism -- the
        # payload text may appear, so long as it cannot terminate the literal
        ok = RuleSpec(s.iri, s.mode, s.match_graph, s.construct_graph, s.match, s.construct,
                      merge(s.variables, Dict("$(R)_c" => "?c")), s.mints,
                      Dict{String,Vector{RDFTerm}}("$(R)_c" =>
                          RDFTerm[RDFLiteral("a\" } INSERT { <urn:x> <urn:y> <urn:z> } #")]),
                      NacSpec[], nothing, 0, nothing)
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
        with(ts) = RuleSpec(base.iri, base.mode, base.match_graph, base.construct_graph,
                            ts, simpleR, base.variables, base.mints)
        @test occursin("literal subjects", sprint(showerror, try compile_rule(with(
            [PatternTriple(RDFLiteral("oops"), iri(TYPE), iri("$(G)Person"))])) catch e; e end))
        @test occursin("predicate", sprint(showerror, try compile_rule(with(
            [PatternTriple(iri("$(R)_Person_1"), RDFLiteral("oops"), iri("$(G)Person"))])) catch e; e end))
        # a variable in predicate position is legal: it is an IRI at pattern level
        @test compile_rule(with([PatternTriple(iri("$(R)_Person_1"), iri("$(R)_ID_1"),
                                               iri("$(G)Person"))])) isa String
    end

    @testset "a template with no slot mints one node for every match" begin
        # It expands to the same IRI whatever the binding, collapsing every solution onto
        # one node. A fixed node is a legitimate thing to want -- but it is written as a
        # constant in R, not as a template with nothing to substitute.
        s = minting_rule(template = "http://example.org/hr/employee/fixed",
                         slots = Dict{String,RDFTerm}())
        msg = sprint(showerror, try compile_rule(s) catch e; e end)
        @test occursin("no {slot}", msg)
        @test occursin("directly in the construct pattern", msg)
    end

    @testset "same spec, same bytes -- whatever order it was built in" begin
        # The sort lives in bgp_text, not only in load_pattern, so the guarantee holds for a
        # spec an MCP client hands in as much as for one read from the store. A BGP is a set.
        base = person_to_employee()
        shuffled = RuleSpec(base.iri, base.mode, base.match_graph, base.construct_graph,
                            reverse(base.match), reverse(base.construct),
                            base.variables, base.mints)
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
        @test_throws ArgumentError insert_query(person_to_employee(); into = "relative")
    end

    @testset "templating cannot eat a SPARQL group pattern" begin
        # `{{` is legal SPARQL -- a nested group -- and Mustache read it as a section, so
        # any non-empty binding set deleted the whole group. Plain substitution cannot:
        # a brace pair that is not a supplied key is left exactly as written.
        q = "SELECT ?s WHERE { GRAPH <urn:g> {{ ?s ?p ?o }} }"
        @test Jayhawk.render_query(q, Dict()) == q
        @test Jayhawk.render_query(q, Dict("unused" => "x")) == q
        @test Jayhawk.render_query("ASK { <urn:a> <urn:b> \"{{v}}\" }", Dict("v" => "hi")) ==
              "ASK { <urn:a> <urn:b> \"hi\" }"
    end

    @testset "insert_query wraps the same patterns with USING" begin
        spec = person_to_employee()
        q = insert_query(spec; into = "urn:firing:x", from = ["urn:a", "urn:b"])
        @test occursin("INSERT {", q)
        @test occursin("GRAPH <urn:firing:x>", q)
        @test occursin("USING <urn:a>", q)
        @test occursin("USING <urn:b>", q)
        # the match pattern is character-identical to the CONSTRUCT form's
        @test occursin(bgp_text(spec.match, spec), q)
        # no USING at all when the working set is the store's default graph
        @test !occursin("USING", insert_query(spec; into = "urn:firing:x"))
    end

    @testset "illegal IRIs are refused, not emitted" begin
        spec = person_to_employee()
        # keep L otherwise intact, so the binding check passes and emission is reached
        bad = RuleSpec(spec.iri, spec.mode, spec.match_graph, spec.construct_graph,
                       vcat(spec.match,
                            [PatternTriple(iri("http://ex.org/a b"), iri(TYPE), iri("$(G)ID"))]),
                       spec.construct, spec.variables, spec.mints)
        @test_throws ArgumentError compile_rule(bad)
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
