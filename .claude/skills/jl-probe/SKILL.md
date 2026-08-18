---
name: jl-probe
description: Evaluate a throwaway Julia expression against the loaded Jayhawk package to check a hypothesis about rule loading, SPARQL compilation, the execution harness, or firing/provenance state. Use when you need to answer "what SPARQL does this compile to / what type is this term / did this rule actually fire" rather than reading source and guessing.
---

# Probing Jayhawk from a scratch Julia process

For answering a factual question about runtime behaviour — what a rule compiles to, what
concrete type a term has, whether a rule fired — without adding a test or editing `src/`.

Jayhawk is **one** thing: the engine. It compiles `gistp:` patterns to SPARQL and runs them.
It has no RDF parser, no `Core.eval`, and no global prefix registry. If a probe you are
writing needs `analyze`/`generate`/`install!`, `TraceLog`, `makeqname` or `expand_uris`, you
want the `RdfMaterializer` package (`~/dev/RdfMaterializer`), not this one.

## Write a file, don't fight the shell

Multi-line probes inside `julia -e '...'` become unreadable fast, because TriG snippets are
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

There is no required initialisation. This is the whole of it:

```julia
using Jayhawk, Logging

global_logger(ConsoleLogger(stderr, Logging.Warn))  # silence the @debug firehose
```

The endpoint defaults to `http://localhost:3040/jayhawk`. It is **settable at runtime** —
`set_endpoint!("http://host:port/ds")` — so you do not have to relaunch Julia to point
somewhere else.

## Probing without a server

The compiler is pure, so the most useful probes need no Fuseki at all. Build a `RuleSpec` by
hand and compile it:

```julia
G    = "http://ex.org/"
TYPE = "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"   # not exported; define it yourself
iri(s) = IRIRef(s)                                          # term constructors
var(s) = RDFLiteral(s, Jayhawk.GISTP_VAR)                   # a literal-position variable

spec = RuleSpec(
    "$(G)R", MODE_ASSERT, "$(G)R_L", "$(G)R_R",             # IRIs here are plain Strings
    [PatternTriple(iri("$(G)_S"), iri(TYPE), iri("$(G)Thing"))],    # L
    [PatternTriple(iri("$(G)_S"), iri(TYPE), iri("$(G)Widget"))],   # R
    Dict("$(G)_S" => "?_S"),                                # variable IRI => variableText
    Dict{String,MintSpec}())                                # no mints

println(compile_rule(spec))
```

Two traps in that constructor, both of which cost a probe:

- **`RuleSpec`'s IRI fields are `String`, not `IRIRef`.** Only the terms *inside* a
  `PatternTriple` are `RDFTerm`s. Passing `IRIRef` where a `String` belongs gives a
  `MethodError` listing all five inner constructors, which reads as though the struct changed.
- **`mints` is a `Dict{String,MintSpec}`, not a vector**, keyed by the same variable IRI as
  `variables`.

`test/runtests.jl` is the reference for the current `RuleSpec` field order — copy a
constructor call from there rather than reconstructing it from memory, because the struct has
grown a field per round.

Useful pure entry points: `compile_rule`, `insert_query`, `rewrite_query`, `where_body`,
`bgp_text`, `values_text`, `nacs_text`, `dataset_lines`, `interface`, `match_only`,
`construct_only`, `dangling_risks`, and the `check_*` validators.

## Probing against a store

```bash
./bin/fuseki-test.sh start        # in-memory, port 3040, dies with the process
```

```julia
D = "urn:jayhawk:probe"
update!("DROP SILENT GRAPH <$D>")
load_file!("examples/moneygraph/data.trig")          # Jena parses it, not Julia
load_file!("examples/moneygraph/01-classify-bond.trig")

spec = load_rule("https://w3id.org/moneygraph/ns/rules/ClassifyBond")   # I/O, returns pure data
println(compile_rule(spec))                                            # pure, from here down

dry_run(spec; source = [D])                          # what it would add, writes nothing
run_rule(spec.iri; source = [D], actor = "probe")    # actually apply it
firings()                                            # provenance
```

`tool_explain_rule(iri; source=[D])` prints metadata, compiled SPARQL and a dry run in one
block, and is usually faster than assembling the same picture by hand.

## Reading terms

`select` is the datatype-faithful path and what the engine itself uses:

```julia
rows = select("SELECT ?s ?o WHERE { GRAPH <$D> { ?s ?p ?o } }")
typeof(rows[1]["s"])          # IRIRef | BNode | RDFLiteral
rows[1]["o"].datatype         # nothing for a plain literal
```

`runsparql` returns **raw JSON** rather than `RDFTerm`s. Use it only when the question is
about the wire format; prefer `select` / `ask` / `update!` otherwise.

## Gotchas that have already cost real time

**A datatype is how a variable is marked.** `RDFLiteral("?x", GISTP_VAR)` and
`RDFLiteral("?x")` are different terms, and any path that normalises datatypes away collapses
them. That is the entire reason `src/term.jl` exists. If a probe says a variable "isn't being
recognised", check `.datatype` before anything else.

**Literal-position variables are matched by string equality of the lexical form**, across L
and R, with no declaration anywhere. `?idtext` and `?idText` are different variables and
nothing will tell you but `check_bound`.

**A rule's declarations must be in the default graph.** `hasMatchPattern`,
`hasConstructPattern` and `rewriteMode` inside a named graph are invisible to `load_rule`,
which then reports *no rule found* for an IRI that is plainly in the store.

**`run_rule` returns `Firing[]` when nothing matched**, which looks identical to a rule that
is broken. Use `dry_run` or `tool_explain_rule` to tell "matched nothing" from "compiled
wrong" — and check that `source` names the graph the data actually landed in.

**Fixpoint runs need an explicit `source`.** SPARQL's `USING` cannot name the store's default
graph, so `strategy = :ToFixpoint` with no `source` is refused rather than silently running
once.

## Real fixtures

`examples/moneygraph/` holds four runnable rules — one per feature (classify, mint, enumerate,
rewrite) — plus `data.trig`, and the integration suite asserts against them, so they cannot
drift from the engine. `test/fixtures/` holds the deliberately-invalid rules used to check
that refusals fire. Use these rather than inventing TriG when the question is about real shape.

## Clean up

Delete scratch probe files when finished. Never write them into `src/` or `test/`.
