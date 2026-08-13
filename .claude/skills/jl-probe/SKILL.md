---
name: jl-probe
description: Evaluate a throwaway Julia expression against the loaded Jayhawk package to check a hypothesis about RDF parsing, the analyze/generate/install pipeline, generated code, or TraceLog contents. Use when you need to answer "what does this actually return / what type is this / did this triple execute" rather than reading source and guessing.
---

# Probing Jayhawk from a scratch Julia process

For answering a factual question about runtime behavior — what a function returns, what
concrete type a term has, whether a triple executed — without adding a test or editing `src/`.

## Write a file, don't fight the shell

Multi-line probes inside `julia -e '...'` become unreadable fast, because Turtle snippets are
full of `"` and `#` that collide with shell quoting. Write the probe to the scratchpad and run
it:

```bash
julia --project=. <scratchpad>/probe.jl
```

Reserve `julia --project=. -e '<one short line>'` for genuine one-liners.

Do not open the file with a `"""..."""` string — Julia reads a bare string literal before a
statement as a **docstring** and fails with `cannot document the following expression` on the
`using` line. Use `#` comments at the top of a script.

## The preamble

Every probe needs this. Both lines matter:

```julia
using Jayhawk, Serd, Serd.RDF, Serd.RDF.Prefixes, Logging, URIs

global_logger(ConsoleLogger(stderr, Logging.Warn))  # silence the @debug firehose
Jayhawk.set_def_prefixes()                          # or makeqname throws KeyError
```

Skipping `set_def_prefixes()` gives a confusing `KeyError` from deep inside `makeqname` —
it is the single most common way a probe fails for reasons unrelated to what you're testing.

`Prefix already defined. Overwriting with new value.` warnings come from Serd and are
harmless; ignore them or raise the logger to `Logging.Error`.

## Loading RDF

```julia
tl = initialize()              # a TraceLog with active=true
make_from_rdf(ttl_string, tl)  # analyze -> generate -> install! -> register! -> run_data!
```

To inspect the phases separately (this is the point of the three-phase split):

```julia
stmts = Jayhawk.expand_uris(Serd.read_rdf_string(ttl)...)
m     = analyze(stmts)          # pure: SchemaModel, no eval
e     = generate(m)             # pure: Expr, nothing installed
install!(e)                     # the ONLY eval in the pipeline
tl    = initialize()
register!(m, tl)                # populate TraceLog dictionaries
run_data!(m, tl)                # execute the A-Box
```

`compile(ttl)` does analyze + generate + install! without executing data.
`generate(m; skip_existing=false)` re-emits definitions that already exist — needed when
inspecting generated code for a schema loaded earlier in the same process.

## Reaching generated code

Use the package's own two helpers rather than `isdefined`/`getglobal`. Julia 1.12 tightened
world-age rules for *global bindings*, not just method tables; these wrap the lookup in
`invokelatest`, which is correct in every context:

```julia
Jayhawk._defined(Jayhawk, :gist_Category)     # NOT isdefined(...)
f = Jayhawk._lookup(Jayhawk, :gist_Category)  # NOT getglobal(...)
```

**Whether you need `Base.invokelatest` to *call* `f` depends on where you are** — this is
easy to get backwards:

- **Top level of a probe script: not needed.** Each top-level statement runs in a new world
  age, so `install!(e)` on one line and `f(s, o, tl)` on the next just works.
- **Inside a single function body: required.** Code installed and called within one dynamic
  extent hits the world-age barrier, and the direct call fails with a `MethodError` that
  reads as though the method doesn't exist.

The second case is why `run_data!` in `src/execute.jl` calls `Base.invokelatest`, and why the
old `futures` queue existed. When in doubt inside a helper function, use `invokelatest` — it
is never wrong, only marginally slower.

To see what was generated: `println(string(generate(m; skip_existing=false)))`, or
`methods(f)` for the installed methods of one property.

## Gotchas that have already cost real time

**`Resource` has two concrete subtypes that never compare equal.**

```julia
Resource("owl", "Restriction")                           # ResourceCURIE
Resource("http://www.w3.org/2002/07/owl#Restriction")    # ResourceURI
# these are NOT ==, despite denoting the same IRI
```

`@auto_hash_equals` equality does not cross the subtype boundary, so a dictionary keyed by one
form never hits with the other. This is a live bug: `resource_dict` is populated with the
CURIE form while everything out of `expand_uris` is the URI form. See the characterization
testset `blank-node rdf:type for bootstrap owl types silently degrades to Unknown`. When a
lookup mysteriously misses, check which form you have with `typeof`.

**A TraceLog only records when `active` is true.** `initialize()` sets it; `TraceLog()` does
not. `store_local!`/`store_res!`/`add_entry!` are all silent no-ops on an inactive log, so an
empty `tl.ldict` may mean "inactive", not "nothing executed".

**`run_data!` swallows per-triple failures.** It counts them and emits one `@info` at the end
rather than throwing. To see which triples failed and why, loop yourself:

```julia
for t in m.data
    nm = Jayhawk._qname(t.predicate)
    (nm === nothing || !Jayhawk._defined(Jayhawk, nm)) && (println("undefined: ", t); continue)
    try
        Base.invokelatest(Jayhawk._lookup(Jayhawk, nm), t.subject, t.object, tl)
    catch e
        println("threw: ", t, " => ", e)
    end
end
```

**`_qname` returns `nothing` for an unregistered prefix**, where `makeqname` throws. `analyze`
uses `_qname` so one unnameable IRI doesn't abort the file; those terms land in `m.unnamed`.

## Real fixtures

`resource/gistAcct3.0.0.ttl` (1235 lines) is the realistic load — bare IRIs, blank nodes, an
unprefixed ontology IRI. `resource/jayhawk.ttl` is the project's own ontology. Use these
rather than inventing Turtle when the question is about real-world shape.

## Clean up

Delete scratch probe files when finished. Never write them into `src/` or `test/`.
