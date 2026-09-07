# CLAUDE-about.md

Guidance for Claude Code when working in this repository. For *why* the project exists and
where it is going, see `CLAUDE.md`; this file describes what is actually here.

## Project overview

Jayhawk is **one** thing: the engine. `term.jl`, `compile.jl`, `harness.jl` and `mcp.jl`
compile `gistp:` graph-rewrite patterns into SPARQL, run them against a triplestore, record
what they did, and expose the result as MCP tools. This is the Function-Graph programme.

It used to be two. The materialiser — OWL ontology into Julia structs and per-predicate
functions — was split out into `RdfMaterializer` (`~/dev/RdfMaterializer`), because the two
halves shared no code and the materialiser's private Serd fork was being inherited by every
consumer of the engine. It is still the extension surface for computations SPARQL cannot
express; it is just a separate package now, and this one does not depend on it.

**SPARQL matches, Julia computes, RDF holds identity.**

## Commands

```bash
julia --project=. test/runtests.jl                       # hermetic, ~6s, 221 assertions
./bin/fuseki-test.sh start                               # local Fuseki on :3040/jayhawk
JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl # + integration tests

julia --project=bin -e 'using Pkg; Pkg.instantiate()'    # once
julia --project=bin bin/mcp_server.jl                    # MCP server over stdio
```

Skills in `.claude/skills/` cover the details: `jl-test`, `jl-probe`, `sparql`, `ttl`.

## Documentation

- `README.md` — the front door: what Jayhawk is, quick start, where everything else lives
- `docs/user-guide.md` — writing, running, reviewing and undoing rules ([web](https://claude.ai/code/artifact/387c189b-0e2a-4546-a6da-cc166369088d))
- `docs/developer-guide.md` — architecture, invariants, how to extend ([web](https://claude.ai/code/artifact/2ccf34ca-2b5e-4b39-bcb2-c983678008c6))
- `examples/moneygraph/` — four runnable rules, one per feature, exercised by the test suite

## The engine

### Three phases, one of them impure

`load_rule` does the I/O; `compile_rule` is pure and snapshot-testable with no server; the
harness executes. Everything is read from the store rather than parsed in Julia — a rule's
metadata is in the default graph and its pattern triples are in named graphs, so the input is
inherently a *dataset* query.

### Rules are RDF

A rule names a match pattern (L) and a construct pattern (R). **A pattern's IRI is also the
IRI of the named graph holding its triples** — the pattern *is* its graph, so there is no
membership vocabulary and no predicate blacklist. Instances are therefore TriG, and Turtle
cannot express them.

Three modes. `Construct` (`f(G)`, pure) and `Assert` (`G ∪ f(G)`, to a fixpoint) compile to
**identical SPARQL**; only the driver differs. `Rewrite` emits `DELETE { L∖I } INSERT { R∖I }`
off the triple-level interface `I = L ∩ R` (`interface` / `match_only` / `construct_only`), as
five staged operations in one transaction — see the developer guide.

**I is authored by repetition**: whatever is preserved is written into both L and R.

### The control layer

`gistp:hasNegativeCondition` (0..n) compiles each guard graph to its own `FILTER NOT EXISTS`,
emitted *after* the `BIND`s so a guard may name a minted variable. `gistp:strategy`
(`Once` / `ToFixpoint`, defaulting to `ToFixpoint` for `Assert`), `gistp:maxIterations` and
`gistp:priority` are loaded and validated; priority is displayed but not yet acted on.
`gistp:oneOf` compiles to `VALUES`, which constrains when L also binds the variable and
generates when it does not.

`gistp:inGraph` scopes a *pattern* to a named graph -- a declared variable binds whichever
graph matched, any other IRI is a constant -- or, third reading, to a
`gistp:TabularDataSource`, which compiles to `SERVICE <x-sparql-anything:>` and contributes no
dataset clause at all. A scoped rule emits **both** `USING` and
`USING NAMED`, because default and named graphs are disjoint namespaces and either alone
blinds half the rule. Only the triples are wrapped: inside `GRAPH ?g { ... }` the variable
`?g` is not yet bound, so a guard nested there would silently mean "in *any* graph". Round
5a is read-side only; scope on R, with `Rewrite`, with `ToFixpoint`, or with an empty
`source` is refused.

All seven WHERE-clause builders route through `where_body`, so a guard cannot be honoured by
only some of them.

### Two variable mechanisms

IRI-position variables are declared individuals resolved by RDF identity. Literal-position
variables (`"?idText"^^gistp:var`) are declared **nowhere** and matched across L and R by
string equality of the lexical form. `check_bound` rejects use-before-def, which is the only
thing standing between a typo and a rule that silently constructs nothing.

### Firings

Every application writes into a fresh `urn:jayhawk:firing:<uuid>` graph, pruned of facts the
working set already held, and recorded in `urn:jayhawk:provenance`. Undo drops that graph and,
for a `Rewrite`, replays the `urn:jayhawk:tombstone:<uuid>` graph written in the same atomic
update — so it is an exact inverse. `max_iterations` is a hard stop because `gistp:iriTemplate`
minting turns fixpoint evaluation into the chase.

### Hard constraint

**The engine works in absolute IRIs; it never calls `makeqname` and never `Core.eval`s.**
That is what keeps it clear of the global-state hazards below. Treat it as a rule, not a
preference.

## The materialiser — moved out

`analyze` / `generate` / `install!`, `TraceLog`, `expand_uris`, `makeqname`, `resource_dict`,
`set_def_prefixes`, `build_model` and `qsparql` now live in **`RdfMaterializer`**
(`~/dev/RdfMaterializer`), together with `rdf.jl`, `rdfs.jl`, `rdf_type.jl`,
`rdfs_subClassOf.jl`, `tracelog.jl`, `analyze.jl`, `generate.jl`, `execute.jl` and `build.jl`.

The two engines shared no code, only a module — verified before the split: every Serd mention
in `compile.jl` and `term.jl` was a *comment*, and the sole real coupling was one line inside
`qsparql`. The materialiser referenced nothing from the engine at all.

Keeping them together forced every Jayhawk consumer to inherit the materialiser's dependency
on a private, unpublished fork of Serd, so a project that only wanted to compile rules could
not resolve without pinning a Serd it never called. **Jayhawk no longer depends on Serd**, and
neither package depends on the other.

## Known hazards

The process-global prefix-registry hazards went with the materialiser. What remains here:

- **Literal datatypes are load-bearing.** A `^^gistp:var` datatype is how a variable is
  marked, which is why terms are read from SPARQL Results JSON via `src/term.jl` rather than
  through any parser that normalises datatypes away.
- **SPARQL Update is single-pushout.** It performs no dangling check, so a `Rewrite` that
  strips a node of every triple the pattern knows about leaves outside references pointing at
  nothing. `dangling_risks` reports it; it does not refuse.
- **`USING` / `USING NAMED` replace the dataset.** A graph absent from the clause is invisible
  even to a `GRAPH <constant>` in the WHERE — which is why `rewrite_query`'s pruning and
  promotion operations deliberately carry no dataset clause.

## External dependencies

- **Fuseki** — default `http://localhost:3040/jayhawk`, overridable via
  `JAYHAWK_SPARQL_SERVICE` / `JAYHAWK_UPDATE_SERVICE` before Julia starts, or at runtime with
  `set_endpoint!`.
- **ModelContextProtocol.jl** — `bin/Project.toml` only, never a Jayhawk dependency: it is
  heavy and it exports `register!`, which collides.
- Everything else resolves from the General registry. There is no `[sources]` stanza and no
  sibling checkout required to clone and instantiate this project.

## Source layout

| File | Role |
|---|---|
| `Jayhawk.jl` | module and includes; no state of its own |
| `term.jl` | `RDFTerm` / `IRIRef` / `BNode` / `RDFLiteral`; SPARQL Results JSON |
| `sparqlclient.jl` | `runsparql` plus the typed `select`/`ask`/`update!` and GSP loaders |
| `compile.jl` | `load_rule`, `compile_rule`, `insert_query`, `rewrite_query`, `where_body`, `dataset_lines`, `interface`, `rule_catalogue` |
| `harness.jl` | `apply_rule`, `run_rule`, `dry_run`, `undo_firing!`, `firings` |
| `mcp.jl` | the five agent-facing tools |

## Tests

| File | Scope |
|---|---|
| `test/runtests.jl` | hermetic: `term.jl` + the pure compiler (221 tests) |
| `test/adversarial.jl` `test/review_fixes.jl` `test/review_round4.jl` | standalone review suites (92 tests) |
| `test/sparql_integration.jl` | opt-in, needs Fuseki; `JAYHAWK_TEST_SPARQL=1` (236 tests) |
