# CLAUDE-about.md

Guidance for Claude Code when working in this repository. For *why* the project exists and
where it is going, see `CLAUDE.md`; this file describes what is actually here.

## Project overview

Jayhawk is two things that share a repository and very little code.

1. **The engine** (`term.jl`, `compile.jl`, `harness.jl`, `mcp.jl`) — compiles `gistp:`
   graph-rewrite patterns into SPARQL, runs them against a triplestore, records what it did,
   and exposes the result as MCP tools. This is the Function-Graph programme.
2. **The materialiser** (`analyze.jl`, `generate.jl`, `execute.jl`, `rdf*.jl`) — turns an
   OWL ontology into Julia structs and per-predicate functions. Useful as the extension
   surface for computations SPARQL cannot express; not the engine.

**SPARQL matches, Julia computes, RDF holds identity.**

## Commands

```bash
julia --project=. test/runtests.jl                       # hermetic, ~6s, no server
./resource/fuseki-test.sh start                          # local Fuseki on :3030/jayhawk
JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl # + integration tests

julia --project=bin -e 'using Pkg; Pkg.instantiate()'    # once
julia --project=bin bin/mcp_server.jl                    # MCP server over stdio
```

Skills in `.claude/skills/` cover the details: `jl-test`, `jl-probe`, `sparql`, `ttl`.

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
**identical SPARQL**; only the driver differs. `Rewrite` (`DELETE`/`INSERT`) is not compiled
yet — it needs the triple-level interface `I = L ∩ R`.

**I is authored by repetition**: whatever is preserved is written into both L and R.

### Two variable mechanisms

IRI-position variables are declared individuals resolved by RDF identity. Literal-position
variables (`"?idText"^^gistp:var`) are declared **nowhere** and matched across L and R by
string equality of the lexical form. `check_bound` rejects use-before-def, which is the only
thing standing between a typo and a rule that silently constructs nothing.

### Firings

Every application writes into a fresh `urn:jayhawk:firing:<uuid>` graph, pruned of facts the
working set already held, and recorded in `urn:jayhawk:provenance`. Undo is `DROP GRAPH` —
complete while every mode is additive. `max_iterations` is a hard stop because
`gistp:iriTemplate` minting turns fixpoint evaluation into the chase.

### Hard constraint

**The engine works in absolute IRIs; it never calls `makeqname` and never `Core.eval`s.**
That is what keeps it clear of the global-state hazards below. Treat it as a rule, not a
preference.

## The materialiser

`analyze` (pure) → `SchemaModel`; `generate` (pure) → `Expr`; `install!` evaluates — the only
eval in the pipeline. Compile once, execute many: a second run of the same RDF skips
generation entirely.

`run_data!` separates three outcomes: **unmapped** (no generated function — ordinary),
**unmatched** (dispatch found nothing — a local gap), **broken** (anything else — a defect,
rethrown unless `strict=false`). It used to catch all three into one counter, which is how an
`UndefVarError` masqueraded as "833 triples did not execute" for a release.

`makeqname` converts IRIs to identifiers (`owl:Class` → `owl_Class`) and needs
`add_prefix!`; unregistered prefixes throw `KeyError`. `build_model()` is not implemented and
raises saying so.

## Known hazards

Process-global state in the materialiser, one piece deliberately corrupt:

- Serd's `_prefixes_by_name` / `_prefixes_by_uri` are unsynchronised `const` globals with no
  removal. `src/Jayhawk.jl` **relies on them being out of sync** to resolve both `gist:`
  namespace spellings.
- Serd's `julia_datatype` does `get!` on a `const` map, inserting on every unknown datatype.
- Generated code lands in the single `Jayhawk` module; colliding sanitised names share a
  struct (there is a testset acknowledging this).
- **Serd discards literal datatypes.** `from_serd` maps the datatype IRI to a Julia type and
  builds `Literal(value)` without it, so `"42"^^ex:custom` is indistinguishable from `"42"`.
  This is why `src/term.jl` exists and why the engine reads SPARQL Results JSON instead.

## External dependencies

- **Serd** — Turtle parsing for the materialiser only. A local fork at `../Serd.jl`
  (`jayhawk-1`), so the project is not clonable without that sibling checkout.
- **Fuseki** — default `http://localhost:3030/jayhawk`, overridable via
  `JAYHAWK_SPARQL_SERVICE` / `JAYHAWK_UPDATE_SERVICE` before Julia starts, or at runtime with
  `set_endpoint!`.
- **ModelContextProtocol.jl** — `bin/Project.toml` only, never a Jayhawk dependency: it is
  heavy and it exports `register!`, which collides.

## Source layout

| File | Role |
|---|---|
| `Jayhawk.jl` | module, exports, `resource_dict`, `initialize`, `set_def_prefixes` |
| `term.jl` | `RDFTerm` / `IRIRef` / `BNode` / `RDFLiteral`; SPARQL Results JSON |
| `sparqlclient.jl` | `runsparql` plus the typed `select`/`ask`/`update!` and GSP loaders |
| `compile.jl` | `load_rule`, `compile_rule`, `insert_query`, `rule_catalogue` |
| `harness.jl` | `apply_rule`, `run_rule`, `dry_run`, `undo_firing!`, `firings` |
| `mcp.jl` | the five agent-facing tools |
| `analyze.jl` `generate.jl` `execute.jl` `build.jl` | the materialiser pipeline |
| `rdf.jl` `rdf_type.jl` `rdfs*.jl` `tracelog.jl` | bootstrap types, naming, TraceLog |
