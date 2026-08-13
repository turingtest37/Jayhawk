"""
    make_from_rdf(t::String, tl::TraceLog) -> TraceLog

Parse Turtle and run it through the three phases: analyze (pure), generate (pure),
then install / register / execute.

Compilation happens once per name. On a second call with the same schema, `generate`
emits nothing and this is pure execution against the TraceLog passed in.

The former two-pass design (`build_pass_one!` / `build_pass_two!` and the `futures`
queue) is gone. It existed because code was generated and called in the same dynamic
extent, so newly-defined methods were invisible to the running function -- a world-age
problem, not a forward-reference one. Generating everything before executing anything
removes the need to defer.
"""
function make_from_rdf(t::String, tl::TraceLog)
    stmts = expand_uris(read_rdf_string(t)...)
    m = analyze(stmts)
    install!(generate(m))
    register!(m, tl)
    run_data!(m, tl)
end

"""
    compile(t::String) -> SchemaModel

Analyze and install without executing any data. Useful for compiling a schema up front
so that later `make_from_rdf` calls are pure execution.
"""
function compile(t::String)
    m = analyze(expand_uris(read_rdf_string(t)...))
    install!(generate(m))
    m
end

export make_from_rdf, compile
