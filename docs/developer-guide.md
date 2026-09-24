# Jayhawk Developer Guide

*Also published as a web page: [SPARQL Matches, Julia Computes](https://claude.ai/code/artifact/2ccf34ca-2b5e-4b39-bcb2-c983678008c6). This file is the source of truth.*

How the engine is built, which invariants hold it together, and where the sharp edges are.

For *using* it, read [`docs/user-guide.md`](https://claude.ai/code/artifact/387c189b-0e2a-4546-a6da-cc166369088d) first — this assumes you know what a rule is.

---

## 1. Three layers, and why the split matters

| Layer | Owner | Files |
|---|---|---|
| **Store** | Fuseki / Jena | — |
| **Engine** | Jayhawk | `term.jl`, `sparqlclient.jl`, `compile.jl`, `harness.jl`, `mcp.jl` |
| **Extension** | `RdfMaterializer` (separate package) | — |

**SPARQL matches, Julia computes, RDF holds identity.**

The store is the system of record. It parses every byte of RDF, does all the matching and
joining, and provides the transaction boundary. Nothing in the engine reimplements any of
that, and the single most consequential decision in the project is that it compiles to
SPARQL rather than building a matching engine.

The **engine** is the Function-Graph compiler and driver, and it is now the whole of this
package. The **extension layer** — the older ontology materialiser, which turns OWL
declarations into Julia structs and per-predicate functions — was split out into
[`RdfMaterializer`](../../RdfMaterializer) at v0.4.0. The two halves shared no code, only a
module, and keeping them together forced every consumer of the engine to inherit the
materialiser's dependency on a private, unpublished fork of Serd. **Jayhawk no longer depends
on Serd**, and neither package depends on the other.

The materialiser is still the intended home for operators SPARQL cannot express — arithmetic
beyond trivia, statistics, optimisation, calls into the Julia numerical stack — which is the
one place Julia is uniquely justified here rather than arbitrarily chosen. It is not yet
wired to the engine, and the guide says so rather than implying otherwise. Wiring it back up
is now an explicit dependency decision rather than an accident of packaging.

### The invariant that keeps them apart

> **The engine works in absolute IRIs. It never calls `makeqname` and never `Core.eval`s.**

That one rule sidesteps every global-state hazard in §7 at zero cost. Treat it as a
constraint, not a preference: the moment engine code reaches for the prefix registry, the
engine inherits a mutable process-global that two concurrent MCP sessions can corrupt.

---

## 2. The pipeline

```
  .trig file
      │  Graph Store Protocol POST          Jena parses. Julia never parses RDF.
      ▼
  triplestore
      │  load_rule           SELECT × 13    metadata, NAC graphs, L, R, L/R graph scopes,
      ▼                     (+2 per NAC)    variables, mints, enums × 2, strategy,
                                            priority, maxIterations
  RuleSpec                                  pure data
      │  compile_rule / insert_query / rewrite_query    PURE — no I/O, snapshot-testable
      ▼
  SPARQL text
      │  apply_rule                          checks, then one atomic update
      ▼
  firing graph  +  provenance  ( +  tombstone, for a Rewrite )
```

`load_rule` does the I/O and nothing else; everything downstream of `RuleSpec` is pure. That
split is what makes the interesting half testable against golden files with no server
running: the hermetic suite is 368 assertions (as of `20d8f79`), and the 271 in its
`compiler (pure)` testset cover the whole of compilation without a Fuseki anywhere.

### Why the compiler reads from the store

A rule's metadata lives in the default graph and its patterns live in named graphs, so the
compiler's input is inherently a **dataset query**. A flat `Vector{Statement}` cannot express
that. The obvious alternative — parse the Turtle in Julia with Serd — also discards literal
datatypes: `"?x"^^gistp:var` comes back indistinguishable from `"?x"`, which is fatal when the
variable marker *is* a datatype. SPARQL Results JSON carries datatypes faithfully, so the
engine reads that instead. `src/term.jl` exists for exactly this reason, and it is why the
engine has no RDF parser dependency at all.

---

## 3. The data model

```julia
struct RuleSpec
    iri, mode, match_graph, construct_graph      # identity
    match::Vector{PatternTriple}                 # L
    construct::Vector{PatternTriple}             # R
    variables::Dict{String,String}               # variable IRI  => variableText
    mints::Dict{String,MintSpec}                 # variable IRI  => template + slots
    enums::Dict{String,Vector{RDFTerm}}          # variable IRI  => gistp:oneOf values
    nacs::Vector{NacSpec}                        # negative conditions
    strategy, priority, max_iterations           # execution policy
    match_scope, construct_scope                 # jhp:inGraph, or nothing
end
```

`RDFTerm` is `IRIRef | BNode | RDFLiteral`, and `RDFLiteral` keeps lexical form, datatype IRI
and language as **separate** fields. Serd's `Literal` has one field for two exclusive
concepts, which is why the engine does not use it.

### Two variable mechanisms, and why

An **IRI-position** variable is a declared individual, resolved by RDF identity. A
**literal-position** variable is written inside a pattern as a bare `"?x"^^gistp:var` — an
IRI in the object of `gist:name` would stop the pattern being valid domain data — and is
matched across L and R by string equality of its lexical form.

This mirrors the node-versus-attribute split in attributed graph transformation, so the
theory is sound. It used to carry a real cost: a literal-position variable had nowhere to
hang metadata, so `gistp:oneOf` and a datatype could not attach to one. The vocabulary has
since closed that with **`gistp:LiteralVariable`** — an optional declaration carrying
`gistp:variableText`, bound to its uses by that lexical form. Declaration and use stay
deliberately distinct: the declaration is an IRI that something can *name*, the use inside a
pattern is still a literal.

The engine reads the declaration for one thing so far — resolving a `gistp:slotValue`, which
since the literal form was withdrawn always names a variable rather than repeating its
spelling. `gistp:requiresDatatype` is authoring metadata the compiler does not act on. See
`_occurs_in`, which had to grow a fifth alternative to find these declarations at all, and
whose note says which case is still out of reach.

---

## 4. Compilation

### `where_body` — one function, on purpose

```julia
where_body(spec) = match_text(spec) * pre_mint_text(spec) * binds_text(spec) *
                   nacs_text(spec) * filters_text(spec)
pre_mint_text(spec) = source_map_pipeline(spec) * values_text(spec) * bindings_text(spec)
```

The order is load-bearing:

1. **triple patterns** first, one `GRAPH` group per match pattern;
2. **the source-map pipeline**, because everything after reads the cleaned column;
3. **`VALUES`** next, because a binding or a mint may read an enumerated value;
4. **`jhp:hasBinding`** next, each `BIND((text) AS ?v)`, in dependency order
   (`ordered_bindings`, Kahn's algorithm, ties by name), because a mint slot may read one;
5. **mint `BIND`s** next, because a `BIND` sees only variables bound earlier in its group;
6. **`FILTER NOT EXISTS`**, because a guard may mention a *minted* variable;
7. **`FILTER`** last.

There are **seven** places that assemble a WHERE clause. They all route through this one
function, because a guard honoured by only some of them means the thing that executes is not
the thing that was reviewed. Two more re-evaluate a rule's mints to *check* them —
`collision_queries` and `mint_fanin` — and they embed `pre_mint_text` too. They used to embed
L and the mint alone, so a slot fed by `VALUES` or a source map was unbound in the check and
the fan-in report was empty by construction (measured: 0 fan-ins reported where there were 3).

### Bindings: the second place author text is spliced

`jhp:bindText` goes through `_expression_vars`, the same checks `jhp:filterText` does — no
braces, comment, semicolon or prefixed name outside strings and IRIs, balanced parentheses,
not a whole `BIND(` clause, no `AS ?x`. The two are deliberately one function: a threat model
applied to one of two splice points is not a threat model.

`check_bindings` adds what a filter does not need:
- **The target must be fresh.** SPARQL refuses to `BIND` a variable already in scope, so a
  target that L matches, VALUES enumerates, a source map fills, a template mints or a second
  binding assigns is refused before it becomes an opaque parse error at the store.
- **Every input must be bound before it**, by L, VALUES, a source map or an earlier
  binding. An unbound input does not raise an error in SPARQL. The expression does, the
  variable stays unbound, and every R triple mentioning it quietly disappears.
- **It may not read a minted variable.** Mints come after bindings.
- **No cycles.**

`pre_bound(spec)` defines "bound before any binding" once. Four checks used to list it by
hand, and the filter check's copy had left source-mapped variables out: a filter on a CSV
column was refused as unbound.

### `jhp:inGraph` reads three ways

The scope IRI is resolved in `graph_wrap`, and nowhere else:

| the scope names | emits |
|---|---|
| a `gistp:TabularDataSource` | `SERVICE <x-sparql-anything:> { fx:properties … ; … }` |
| a declared `gistp:SparqlVariable` | `GRAPH ?v { … }` |
| anything else | `GRAPH <iri> { … }` |

The third reading is settled by `load_services` from a **type assertion in the data**, not by
guessing at the IRI's scheme — so a typo is a validation failure rather than a graph nobody
created. A data source contributes **no dataset clause**: a `SERVICE` is evaluated outside the
query's dataset, so `is_scoped` counts only *graph* scopes (`graph_scopes`), and an extraction
rule can therefore run with an empty `source`, having no graph to name.

The `fx:` options are emitted verbatim, sorted by predicate for byte-stability. Nothing in the
engine interprets them: a `gistp:` vocabulary of SPARQL Anything's options would go stale the
moment that project added one.

> **The compiled query needs an engine that has the service.** Plain Fuseki does not, so a
> source-scoped rule compiles and validates against the test store but must be *executed*
> through SPARQL Anything (or a Fuseki with its jar loaded). The store-backed tests cover
> loading and compilation; execution was verified by hand:
> `sa.sh -q compiled.rq -f ttl`.

### `jhp:inGraph` scopes the triples, not the clause

Wrapping the finished WHERE in one `GRAPH ?g { … }` looks equivalent and is not. SPARQL
translates `GRAPH ?g { P }` to `Graph(?g, translate(P))`, so **`?g` is bound by the operator
around the group and is still unbound while `P` runs** — `BIND(BOUND(?g) AS ?seen)` inside it
yields `false` on every row. A guard nested in the same group gets a *fresh* `?g` over every
named graph, silently turning "not in **this** graph" into "not in **any** graph": fewer
solutions, no error, HTTP 200.

So only `bgp_text` is wrapped. `VALUES` and `BIND` stay outside the group, and each condition
wraps its own triples inside its own `FILTER NOT EXISTS`. `test/fixtures/scoped_rule.trig`
turns on the one row that separates the two readings.

The dataset clause is the other half, and `dataset_lines` is the only place that builds it —
`insert_query`, `project_query`, `rewrite_query`, `collision_queries` and `mint_fanin` all
call it, so a scoped rule cannot silently lose its collision gate. A scoped rule emits
**both** `USING <g>` and `USING NAMED <g>` for every graph: default and named are disjoint
namespaces, so `USING NAMED` alone leaves the default graph *empty* and `USING` alone leaves
`GRAPH <g>` invisible. An unscoped rule short-circuits to exactly the old bytes, which is
what keeps the golden snapshot meaningful.

> **`rewrite_query`'s pruning and promotion operations must never receive a dataset clause.**
> A graph absent from `USING`/`USING NAMED` is invisible even to a `GRAPH <constant>` in the
> WHERE, and the update then succeeds with 204 having matched nothing. Splice `using_lines`
> into those two and op 2 stops pruning while op 5 stops copying — after op 4 has already
> deleted from the target. Silent data loss. There is a test asserting the absence.

### Several match patterns: one L, many parts

`jhp:hasMatchPattern` is one or more, and L is the conjunction of the patterns. The
representation choice is worth knowing before touching anything that reads L:

- A rule with **one** match pattern carries `match_parts = MatchPart[]` and uses the scalar
  `match_graph` / `match` / `match_scope` exactly as before. So every single-pattern rule
  compiles to the bytes it always did, and the golden snapshots still mean something.
- A rule with **several** carries one `MatchPart(graph, triples, scope)` each. It also holds
  `match` as the *union* of their triples, so `interface`, `vars_in`, `check_bound`,
  `dangling_risks` and everything else that reasons about L's triples needed no change. Its
  `match_scope` is `nothing`, because a multi-pattern rule has no single scope.

That last point is the hazard. **Never read `spec.match_scope` directly.** Go through
`match_patterns(spec)`, `match_scopes(spec)` or `match_scope_vars(spec)`. A direct read
treats a multi-pattern rule as unscoped, which drops it from `read_scopes`, silently loses
the dataset-clause guard, and renders its parts as one merged BGP. The only place parts
become text is `match_text`: one `GRAPH` group per part.

`check_match_parts` refuses three things:
- **An empty part.** An empty conjunct is almost certainly a typo in a pattern graph's name.
- **`Rewrite`.** Deletion runs from the union of the parts into one target graph, so a match
  found in a second graph would be deleted from the wrong one.
- **Source maps.** No rule yet says which part's `SERVICE` owns the generated triples.

### The interface, I = L ∩ R

Plain set arithmetic:

```julia
interface(spec)        # triples in both L and R      -> preserved
match_only(spec)       # L ∖ I                        -> deleted by a Rewrite
construct_only(spec)   # R ∖ I                        -> added
```

This is cheap *because* variables are persistent typed individuals rather than SPARQL
name-strings: two pattern triples denote the same thing exactly when they are the same RDF
triple. No unification, no alpha-equivalence. It is the clearest payoff of the whole design.

The key is each term's SPARQL text, which is injective for IRIs and for literals — so an
IRI-position variable matches by RDF identity and a literal-position one by lexical form,
which is precisely the two-mechanism split of §3 showing through.

### Minting

RFC 6570 Level 1 expansion is exactly `ENCODE_FOR_URI`, so there is no template engine:

```sparql
BIND(IRI(CONCAT("http://…/employee/", ENCODE_FOR_URI(STR(?idText)))) AS ?_Employee)
```

`CONCAT`, `ENCODE_FOR_URI` and `IRI` are pure, so re-applying mints byte-identical IRIs.
**That determinism is the termination argument** for an `Assert` fixpoint — a UUID-based
Skolem would break it. Level 2 (`{+slot}`) is refused rather than approximated.

### Two spellings of a template

`load_mints` reads a variable's own `gistp:iriTemplate` *or* the `gistp:namespace` +
`gistp:localTemplate` of the `gistp:MintingFunction` it names with `gistp:isMintedBy`
(`minting_function_template`). It is the only place the two spellings differ. By the time a
`MintSpec` exists they are one template, and `MintSpec.minting_function` records the source
for `explain_rule` only. Nothing downstream branches on it, so a function-minted variable gets
the collision gate, the fan-in report and undo without a second code path. Refused at load:
both spellings on one variable, several of either, and a function whose namespace contains a
brace or whose parts are missing. Two `iriTemplate`s on one variable used to load silently
and mint from whichever the store returned first, which measured as the wrong one.

### Rewrite is five operations, not one

The obvious shape — a single DELETE/INSERT writing target, firing and tombstone together —
loses data. An `R ∖ I` triple the target *already held* would be recorded in the firing graph
as though the rule added it, and undo would then delete a triple that predated the rule.

So `rewrite_query` stages the candidates, prunes them against the still-untouched target,
projects the tombstone, deletes, and finally inserts from the *pruned* firing graph. One
request is one transaction, so a firing is never half-applied.

---

## 5. Adding a vocabulary term, end to end

Every term so far has taken the same seven steps. Follow them in order.

1. **Define it**, with a `skos:definition` and a `skos:scopeNote` saying what it means *and
   what it deliberately cannot express*. A term about *executing* rules (`jhp:` -- rules,
   modes, strategies, conditions, rule sets) goes in
   `~/dev/JayhawkPatterningDefinitions/ontologies/JayhawkPatterningDefinitions.ttl`; a term
   about the pattern language itself (`gistp:` -- variables, minting, source maps) goes in
   `~/dev/gistPatterns/ontologies/gistPatterningDefinitions.ttl`.
2. **Constrain it** in the matching shapes file, `JayhawkPatternShapes.ttl` or
   `gistPatternShapes.ttl`. Prefer `sh:in` for closed enumerations —
   it avoids forcing every validation run to load the vocabulary, and stops anyone inventing
   a value the compiler has no backend for.
3. **Add a negative case** to `example_rule_invalid.trig` and its needle to `verify.py`.
   A validation run that can only pass proves nothing.
4. **Write a worked example** as its own `example_*.trig`.
5. **Load it** in `src/compile.jl`: a constant, a `load_*` function, a `RuleSpec` field, and
   the field in `load_rule`. Scope the query to the rule's own graphs with `_occurs_in` —
   an unscoped `SELECT` breaks the moment a store holds two rules.
6. **Compile it**, via `where_body` if it affects the WHERE clause. Add a `check_*` that
   refuses every way it can be wrong, with a message that names the fix.
7. **Test it three ways**: pure compiler tests in `runtests.jl`, live behaviour in
   `sparql_integration.jl`, and the ontology in `verify.py`.

### Back-compatible struct growth

`RuleSpec` has grown five times. Each time, the old positional constructor is kept as a
short-arity method so existing call sites and tests stay valid:

```julia
RuleSpec(iri, mode, lg, cg, match, construct, variables, mints) =
    RuleSpec(iri, mode, lg, cg, match, construct, variables, mints,
             Dict{String,Vector{RDFTerm}}(), NacSpec[], nothing, 0, nothing)
```

---

## 6. Testing

Four suites, each with a different job.

| Suite | Needs a server | What it is for |
|---|---|---|
| `test/runtests.jl` | no | ~6s warm, hermetic, 368 assertions. Pure compiler behaviour, golden SPARQL, every refusal. |
| `test/sparql_integration.jl` | yes | 371 + 13 assertions. Live behaviour: what the store actually does. Opt-in via `JAYHAWK_TEST_SPARQL=1`. Includes the `moneygraph` testset that every figure in the user guide is measured from. |
| `test/review_fixes.jl` (39), `review_round4.jl` (17) | optional | Independent verification of specific fixes, written from the *claims* rather than the implementation. |
| `test/adversarial.jl` (36) | optional | Deliberately hostile, and not part of `runtests.jl` — run it on its own. It found the Rewrite data-loss bug. |

Counts are as of `20d8f79`. The standalone figures are their hermetic parts; with
`JAYHAWK_TEST_SPARQL=1` they add 68 (adversarial), 27 (review_fixes) and 13 (review_round4).

The last three are **standalone**: `julia --project=. test/<file>.jl` runs their hermetic
part with no server, and `JAYHAWK_TEST_SPARQL=1` adds the store-backed part. Because
`runtests.jl` does not include them, they are the ones most likely to rot unnoticed — run all
three before calling a change done.

```bash
julia --project=. test/runtests.jl                          # fast loop
./bin/fuseki-test.sh start
JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl    # everything
for f in adversarial review_fixes review_round4; do         # the standalone suites
  julia --project=. test/$f.jl
done
cd ~/dev/gistPatterns && python3 verify.py                  # the ontology
```

Three habits worth keeping, because they have each caught something real:

- **Show the failure before the fix.** Every serious bug in this codebase was first
  reproduced as a measurement.
- **Assert the negative.** `example_rule_invalid.trig` must be *rejected*, with each expected
  finding named. A validation that can only pass proves nothing.
- **Write tests from the claim, not the code.** `review_fixes.jl` found that a fix guarded
  one of two emit paths precisely because it was written from the docstring.

---

## 7. Known hazards

The process-global prefix-registry hazards — Serd's unsynchronised `_prefixes_by_name` /
`_prefixes_by_uri`, the ever-growing `julia_datatype` map, generated code colliding in one
module — **went with the materialiser** at v0.4.0. They are `RdfMaterializer`'s problem now,
and the engine's absolute-IRI rule means it never meets them. Do not import them back.

What remains here:

- **Literal datatypes are load-bearing.** A `^^gistp:var` datatype is how a variable is
  marked, which is why terms are read from SPARQL Results JSON via `src/term.jl` rather than
  through any parser that normalises datatypes away (§2). Anything that reintroduces such a
  parser on the read path reintroduces the bug.
- **SPARQL Update is single-pushout.** It performs no dangling check, so a `Rewrite` that
  strips a node of every triple the pattern knows about leaves outside references pointing at
  nothing. `dangling_risks` reports it; it does not refuse.
- **`USING` / `USING NAMED` replace the dataset.** A graph absent from the clause is invisible
  even to a `GRAPH <constant>` in the WHERE — which is why `rewrite_query`'s pruning and
  promotion operations deliberately carry no dataset clause.

The project is now clonable on its own: every dependency resolves from the General registry,
there is no `[sources]` stanza, and no sibling checkout is required.

---

## 8. Blank nodes and Skolemisation

Blank nodes are **refused in patterns** and **Skolemised in data**. The asymmetry is
deliberate, because a blank node means three incompatible things depending on where it sits.

In L it is a non-selectable variable; in R a *fresh* node per solution; across the two it
connects nothing, because SPARQL will not carry one from a WHERE clause into a CONSTRUCT
template. In a `DELETE` it is illegal outright.

Skolemising a pattern would fix the syntax and keep the bug: in L or a DELETE a Skolem IRI is
a **constant**, so the pattern would match one node that exists nowhere and the rule would
silently never fire. In R the answer already exists and is better — `iriTemplate` is
Skolemisation with the function stated, and stated is what makes it deterministic.

For **data**, `skolemize!` is unambiguously useful, and one SPARQL update rather than an
export-rewrite-reload because Jena's `STR()` is lenient on blank nodes:

```julia
skolemize!(graph = "urn:my:data")               # or across the whole dataset
load_graph!(content, "urn:my:data"; skolemize = true)
```

Two reasons specific to this engine. An agent **cannot refer to** a blank node — no IRI means
`run_rule` and `undo_firing` cannot be pointed at it. And blank node labels **do not survive
a serialisation round trip**: identity holds inside one store, but a dump and reload
renumbers them, so provenance recorded before an export stops resolving after the import.

Note the limit: these IRIs are stable going *forward*, not reproducible backward. The label
is the store's internal id, minted fresh per parse. Making them reproducible would mean
hashing each node's surroundings, which is graph isomorphism.

---

## 9. What is not built yet

In the order I would take them.

**Conflict analysis.** Rule sets themselves are **built** — `run_rules` applies a
`jhp:RuleSet`, a `gist:OrderedCollection` whose membership is reified so one `ORDER BY`
recovers the order, and `jhp:priority` orders a bare list and breaks `gist:sequence` ties.
What is still missing is the part that makes a set *trustworthy*: an answer to "does order
matter here?" There is a cheap conservative one: over predicates,

```
delta(A) = predicates in (L_A ∖ I_A) ∪ (R_A ∖ I_A)
A and B commute if  delta(A) ∩ predicates(L_B) = ∅  and  delta(B) ∩ predicates(L_A) = ∅
```

Sound but incomplete — it never claims independence falsely, which is the direction that
matters — and it is the same set arithmetic that made `interface` a two-line function.

**`gistp:oneOf` on a literal-position variable.** The declarations this used to wait on have
landed in the vocabulary as `gistp:LiteralVariable` (§3), and `gistp:slotValue` resolves them.
What is left is discovery: a literal variable that no slot names is reachable only by matching
`gistp:variableText` against the literals inside the pattern graphs, which `_occurs_in`
deliberately does not do — that would be a second string-matching mechanism, and it should be
added when something needs it rather than in advance.

**Slugging, as vocabulary.** It is already expressible: a `jhp:hasBinding` of
`REPLACE(LCASE(?x), "\\W+", "-")` slugs, and the bondfix rules mint from exactly such keys.
What remains is a declarative spelling of it, an opt-in with a stated algorithm, since
`ENCODE_FOR_URI` alone gives `E%209902%2FA`. The rule of thumb is already known: slug
*controlled vocabulary terms*, never free-text data, because slugging is lossy and a
collision merges two things into one node.

**Legacy migration** — R2RML/Ontop virtualisation, view harvesting, rule mining, differential
testing against the running system. The enterprise adoption path, and the reason the engine
exists.

**The list-valued source-map terms.** `gistp:mapFrom` (the vocabulary has no class for a
source attribute, so there is nothing to read a column name off), `gistp:mapFirst` (COALESCE
over one binding per member), `gistp:concat` (CONCAT likewise), and `gistp:mapEach` — the
hardest, because it *multiplies* solutions and so is a UNION over the match rather than an
expression over one binding. All four are refused by name rather than ignored.

**A write destination that is a variable.** Refused, and it needs more than a check to lift:
different solutions would go to different graphs and a firing graph is one flat set of triples
with nowhere to record which triple went where, so undo could not reverse it. Minting the
graph IRI with `gistp:iriTemplate` and running once per graph is the workaround.

**RFC 6570 Level 2**, deliberately deferred and small. **Chained minting** is half done:
a template may mint from a *binding*, and a binding may read another binding, which covers
every computed-key case met so far (the bondfix keys). Minting from a *minted IRI* is still
refused. It needs a binding that reads a mint, and so needs the two interleaved.
