# Phase 3 of three: execute.
#
# `install!` is the single point where anything is evaluated. `register!` and `run_data!`
# contain no eval at all -- they look functions up and call them. That is the whole point
# of the split: compile a set of RDF once, then merely execute on every later run.
#
# Because `install!` defines methods that `run_data!` then calls within the same dynamic
# extent, the calls go through `Base.invokelatest` to cross the world-age boundary. That
# is what the `futures` queue used to work around by deferring calls to a second pass.

# Julia 1.12 tightened world-age rules for *global bindings*, not just method tables: a
# binding created by install! is invisible to the already-running function that wants to
# look it up. Reading it directly warns today and is documented to become an error, so
# every lookup of generated code goes through these two helpers.
_defined(mod::Module, nm::Symbol) = Base.invokelatest(isdefined, mod, nm)
_lookup(mod::Module, nm::Symbol) = Base.invokelatest(getglobal, mod, nm)

"""
    install!(e::Expr; mod = Jayhawk) -> Module

Evaluate a generated definition block. This is the only eval in the pipeline.
"""
function install!(e::Expr; mod::Module = @__MODULE__)
    isempty(e.args) || Core.eval(mod, e)
    mod
end

"""
    register!(m::SchemaModel, tl::TraceLog; mod = Jayhawk) -> TraceLog

Record the generated types and functions in the TraceLog's dictionaries. This used to
happen inside the generated code itself, against a TraceLog baked in at generation time;
taking the TraceLog as an argument is what lets one compiled schema serve many runs.
"""
function register!(m::SchemaModel, tl::TraceLog; mod::Module = @__MODULE__)
    for (uri, c) in m.classes
        _defined(mod, c.name) || continue
        store_res!(tl, _lookup(mod, c.name), uri)
        store_local!(tl, owl_Class(uri), uri)
    end

    for (uri, p) in m.properties
        _defined(mod, p.name) || continue
        store_res!(tl, _lookup(mod, p.name), uri)
        if p.kind === :object
            store_local!(tl, owl_ObjectProperty(uri), uri)
        elseif p.kind === :datatype
            store_local!(tl, owl_DatatypeProperty(uri), uri)
        elseif p.kind === :annotation
            store_local!(tl, owl_AnnotationProperty(uri), uri)
        end
    end
    tl
end

"""
    run_data!(m::SchemaModel, tl::TraceLog; mod = Jayhawk, strict = true) -> TraceLog

Execute the A-Box against the already-installed code. No eval, no code generation, one
dynamic dispatch per triple. Returns the TraceLog it was given.

Three outcomes are counted separately, because they mean entirely different things:

  * **unmapped** -- the predicate has no registered prefix, or no function was generated for
    it. Ordinary: a document may reference predicates outside the schema it declares.
  * **unmatched** -- the function exists but no method accepts this subject/object pair.
    A real gap in the generated dispatch, but a local one.
  * **broken** -- any other exception. That is a defect in the package, not in the data.

The old version caught all three into one `failed` counter and only `@debug`ged the
exception, which is how an `UndefVarError` from an undefined `retrieve!` masqueraded as
"833 triples did not execute" for an entire release. With `strict` (the default) a broken
call is rethrown with the offending triple attached; set `strict = false` to sweep up and
carry on when loading known-dirty data.
"""
function run_data!(m::SchemaModel, tl::TraceLog; mod::Module = @__MODULE__, strict::Bool = true)
    unmapped = unmatched = broken = 0
    for t in m.data
        nm = _qname(t.predicate)
        if nm === nothing || !_defined(mod, nm)
            unmapped += 1
            continue
        end
        f = _lookup(mod, nm)
        try
            Base.invokelatest(f, t.subject, t.object, tl)
        catch e
            # `e.f === f` distinguishes "nothing matched the call we just made" from a
            # MethodError raised somewhere deeper inside a method that did match.
            if e isa MethodError && e.f === f
                unmatched += 1
                @debug "No method for triple" nm t.subject t.object
            else
                broken += 1
                strict && rethrow(ErrorException(
                    "run_data!: executing <$(t.predicate)> on subject <$(t.subject)> " *
                    "raised $(sprint(showerror, e)). This is a defect in Jayhawk, not in " *
                    "the data; pass strict=false to skip it."))
                @warn "Broken execution" nm t.subject t.object e
            end
        end
    end
    total = length(m.data)
    unmapped > 0 && @debug "run_data!: $unmapped/$total triples had no generated function."
    unmatched > 0 && @info "run_data!: $unmatched/$total triples matched no method."
    broken > 0 && @warn "run_data!: $broken/$total triples raised a non-dispatch error."
    tl
end

export install!, register!, run_data!
