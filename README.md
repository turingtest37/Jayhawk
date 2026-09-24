# Jayhawk

**Graph patterns as graph-to-graph computation.**

A rule is two pictures: what must be true (**L**), and what becomes true (**R**). Both are
ordinary RDF, held in named graphs. Jayhawk compiles them to SPARQL, runs them against a
triplestore, records what happened, and can undo it.

You never write SPARQL. You draw the situation.

```turtle
:ClassifyBond
    rdf:type jhp:Rule ;
    jhp:hasMatchPattern     :ClassifyBond_L ;
    jhp:hasConstructPattern :ClassifyBond_R ;
    jhp:rewriteMode         jhp:_RewriteMode_assert .

:ClassifyBond_L { :_Sec a gist:FinancialInstrument ;
                       mg:couponRate "?rate"^^gistp:var ;
                       mg:maturityDate "?maturity"^^gistp:var . }

:ClassifyBond_R { :_Sec a mg:Bond . }
```

A SPARQL `DELETE {L∖I} INSERT {R∖I} WHERE {L}` *is* a single-pushout graph rewrite, so
matching, replacement and atomicity come from the store rather than from a hand-built
rewriting engine.

## Quick start

Needs Julia 1.10+ and [Apache Jena Fuseki](https://jena.apache.org/download/).

```bash
git clone <this repo> && cd Jayhawk
julia --project=. -e 'using Pkg; Pkg.instantiate()'
./bin/fuseki-test.sh start                 # in-memory Fuseki on :3040/jayhawk
```

Everything resolves from the General registry — no sibling checkouts, no forks to pin.

```julia
using Jayhawk
D = "urn:jayhawk:example:moneygraph"

load_file!("examples/moneygraph/data.trig")
load_file!("examples/moneygraph/01-classify-bond.trig")

# look before you leap: compiled SPARQL + a dry run against real data, writing nothing
print(tool_explain_rule("https://w3id.org/moneygraph/ns/rules/ClassifyBond"; source = [D]))

run_rule("https://w3id.org/moneygraph/ns/rules/ClassifyBond"; source = [D], actor = "you")
```

```
dry run against <urn:jayhawk:example:moneygraph> would add 2 new triple(s):
    mg3:IBM2029 a mg:Bond .
    mg3:T4875   a mg:Bond .
```

Every application writes into its own `urn:jayhawk:firing:<uuid>` graph with a provenance
record, so `firings()` lists what ran and `undo_firing!(g)` reverses it exactly — including
replaying the tombstone for a destructive rewrite.

The record is carried by **gist**, not PROV-O: a firing is a `gist:Event`, its rule and sources
are `gist:isBasedOn`, its actor a `gist:hasParticipant`. Because it states both an
`actualStartDateTime` and an `actualEndDateTime`, a reasoner *derives* `gist:HistoricalEvent`
rather than being told it — the class is never asserted outright.

## Beyond one rule at a time

```julia
run_rules("…/sets/BondEnrichment"; source = [D, DERIVED], actor = "doug")
retractions(predicate = "…/gist/hasPositionIn")    # what was once true
```

| | |
|---|---|
| **Ordered rule sets** | A `jhp:RuleSet` is a `gist:OrderedCollection` with reified membership, so one `ORDER BY` recovers the order. Two independent levels of iteration: each rule's own `jhp:strategy`, and the set's, for when a later rule feeds an earlier one. |
| **Write destinations** | `jhp:inGraph` on the *construct* pattern says where output goes. The firing graph stays the unit of attribution and of undo, so a rule can write into live data and still be reversed exactly. |
| **History** | `retractions()` answers *what was once true*. A rewrite always kept what it deleted; the provenance record is now the index, so finding it no longer means knowing a UUID. |
| **Tabular sources** | `gistp:SourceMap` says "this variable comes from that column" and the compiler owes the Facade-X predicate, the row container and the value pipeline. For an extraction rule **L is empty**. |

## The three modes

| Mode | Result | Use it for |
|---|---|---|
| `jhp:_RewriteMode_construct` | `f(G)` — the construct pattern alone | reports, migrations |
| `jhp:_RewriteMode_assert` | `G ∪ f(G)`, iterated to a fixpoint | classification, derivation, closure |
| `jhp:_RewriteMode_rewrite` | `DELETE { L∖I } INSERT { R∖I }` | correcting, retiring, state transitions |

The mode is an explicit property of the rule, never inferred. `I = L ∩ R` is authored by
repetition: whatever is preserved is written into both patterns.

## Documentation

| | |
|---|---|
| [`docs/user-guide.md`](docs/user-guide.md) | Writing, running, reviewing and undoing rules. **Start here.** |
| [`docs/developer-guide.md`](docs/developer-guide.md) | Architecture, invariants, and where the sharp edges are. |
| [`examples/moneygraph/`](examples/moneygraph/) | Four runnable rules, one per feature, asserted by the test suite. |
| `~/dev/PatternTester` | Four larger worked examples over two years of a real portfolio: rule sets, rewrites and history, graph-scoped reads, and a CSV read through source maps. |
| `CLAUDE-about.md` | What is in the repo, for coding agents. |

## Driving it from an agent

```bash
julia --project=bin -e 'using Pkg; Pkg.instantiate()'
julia --project=bin bin/mcp_server.jl
```

Five MCP tools: `list_rules`, `explain_rule`, `run_rule`, `undo_firing`, `list_firings`.
**Rules are the tools, not SPARQL** — no enterprise will hand a model an unrestricted UPDATE
endpoint, and it would be right not to. A catalogue of named, validated, provenance-stamped,
reversible rewrites is a different proposition.

## Tests

```bash
julia --project=. test/runtests.jl                          # 221, hermetic, ~6s
./bin/fuseki-test.sh start
JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl    # + 236 against a live store

for f in adversarial review_fixes review_round4; do         # standalone review suites
  julia --project=. test/$f.jl
done
```

## Related

- **Rule vocabulary** — [`~/dev/JayhawkPatterningDefinitions`](../JayhawkPatterningDefinitions)
  ([github](https://github.com/turingtest37/JayhawkPatterning)): `jhp:Rule`, `RuleSet`, the
  rewrite modes and strategies, their SHACL shapes, worked example rules and `verify.py`.
  Moves in lockstep with this repo.
- **Pattern vocabulary** — [`~/dev/gistPatterns`](../gistPatterns): `gistPatterningDefinitions.ttl`
  (`gistp:` variables, IRI minting, source maps) and its SHACL shapes.
- **[`RdfMaterializer`](../RdfMaterializer)** — the ontology materialiser (OWL declarations
  into Julia structs and per-predicate functions), split out of Jayhawk at v0.4.0. Nothing
  here depends on it.
