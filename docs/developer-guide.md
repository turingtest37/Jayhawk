# Jayhawk Developer Guide

How the engine is built, which invariants hold it together, and where the sharp edges are.

For *using* it, read `docs/user-guide.md` first — this assumes you know what a rule is.

---

## 1. Three layers, and why the split matters

| Layer | Owner | Files |
|---|---|---|
| **Store** | Fuseki / Jena | — |
| **Engine** | Jayhawk | `term.jl`, `sparqlclient.jl`, `compile.jl`, `harness.jl`, `mcp.jl` |
| **Extension** | Jayhawk | `analyze.jl`, `generate.jl`, `execute.jl`, `rdf*.jl`, `tracelog.jl` |

**SPARQL matches, Julia computes, RDF holds identity.**

The store is the system of record. It parses every byte of RDF, does all the matching and
joining, and provides the transaction boundary. Nothing in the engine reimplements any of
that, and the single most consequential decision in the project is that it compiles to
SPARQL rather than building a matching engine.

The **engine** is the Function-Graph compiler and driver. The **extension layer** is the
older ontology materialiser: it turns OWL declarations into Julia structs and per-predicate
functions. Nothing in the engine uses it. It is kept because it is the intended home for
operators SPARQL cannot express — arithmetic beyond trivia, statistics, optimisation, calls
into the Julia numerical stack — which is the one place Julia is uniquely justified here
rather than arbitrarily chosen. It is not yet wired to the engine, and the guide says so
rather than implying otherwise.

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
      │  load_rule            SELECT × 7    metadata, L, R, NACs, variables, mints, enums
      ▼
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
running — 164 of the suite's tests need no Fuseki.

### Why the compiler reads from the store

A rule's metadata lives in the default graph and its patterns live in named graphs, so the
compiler's input is inherently a **dataset query**. A flat `Vector{Statement}` cannot express
that. Serd also discards literal datatypes — `"?x"^^gistp:var` comes back indistinguishable
from `"?x"` — which is fatal when the variable marker *is* a datatype. SPARQL Results JSON
carries datatypes faithfully, so the engine reads that instead. `src/term.jl` exists for
exactly this reason.

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
end
```

`RDFTerm` is `IRIRef | BNode | RDFLiteral`, and `RDFLiteral` keeps lexical form, datatype IRI
and language as **separate** fields. Serd's `Literal` has one field for two exclusive
concepts, which is why the engine does not use it.

### Two variable mechanisms, and why

An **IRI-position** variable is a declared individual, resolved by RDF identity. A
**literal-position** variable is a bare `"?x"^^gistp:var` with no declaration anywhere,
matched across L and R by string equality of its lexical form.

This mirrors the node-versus-attribute split in attributed graph transformation, so the
theory is sound. But it has a real cost, and you should know it: a literal-position variable
has nowhere to hang metadata, so **`gistp:oneOf` and `gistp:iriTemplate` cannot attach to
one.** `check_bound`'s use-before-def check is a workaround for the typo risk, not a
resolution of the asymmetry. Giving literal variables declarations is the obvious next
change to the vocabulary.

---

## 4. Compilation

### `where_body` — one function, on purpose

```julia
where_body(spec) = bgp_text(match) * values_text(spec) * binds_text(spec) * nacs_text(spec)
```

The order is load-bearing:

1. **triple patterns** first;
2. **`VALUES`** next, because a `BIND` may mint from an enumerated value;
3. **`BIND`** next, because it sees only variables bound earlier in its group;
4. **`FILTER NOT EXISTS`** last, because a guard may mention a *minted* variable.

There are **seven** places that assemble a WHERE clause. They all route through this one
function, because a guard honoured by only some of them means the thing that executes is not
the thing that was reviewed.

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

### Minting

RFC 6570 Level 1 expansion is exactly `ENCODE_FOR_URI`, so there is no template engine:

```sparql
BIND(IRI(CONCAT("http://…/employee/", ENCODE_FOR_URI(STR(?idText)))) AS ?_Employee)
```

`CONCAT`, `ENCODE_FOR_URI` and `IRI` are pure, so re-applying mints byte-identical IRIs.
**That determinism is the termination argument** for an `Assert` fixpoint — a UUID-based
Skolem would break it. Level 2 (`{+slot}`) is refused rather than approximated.

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

1. **Define it** in `~/dev/gistPatterns/gistPatterningDefinitions.ttl`, with a `skos:definition`
   and a `skos:scopeNote` saying what it means *and what it deliberately cannot express*.
2. **Constrain it** in `gistPatternShapes.ttl`. Prefer `sh:in` for closed enumerations —
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
| `test/runtests.jl` | no | ~6s, hermetic. Pure compiler behaviour, golden SPARQL, every refusal. |
| `test/sparql_integration.jl` | yes | Live behaviour: what the store actually does. Opt-in via `JAYHAWK_TEST_SPARQL=1`. |
| `test/review_fixes.jl`, `review_round4.jl` | yes | Independent verification of specific fixes, written from the *claims* rather than the implementation. |
| `test/adversarial.jl` | yes | Deliberately hostile. Untracked; a running to-do list. |

```bash
julia --project=. test/runtests.jl                          # fast loop
./resource/fuseki-test.sh start
JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl    # everything
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

All of these are in the **extension layer**, and the engine's absolute-IRI rule avoids every
one. Do not try to repair them as a side quest.

- Serd's `_prefixes_by_name` / `_prefixes_by_uri` are unsynchronised `const` globals with no
  removal — and `src/Jayhawk.jl` **relies on them being out of sync** to resolve both `gist:`
  namespace spellings.
- `julia_datatype` does `get!` on a `const` map, inserting on every unknown datatype, growing
  process-wide forever.
- Generated code lands in the single `Jayhawk` module; colliding sanitised names share a
  struct. There is a testset acknowledging this.
- **Serd discards literal datatypes**, which is why `src/term.jl` exists.
- Serd is a private fork at `../Serd.jl`, so the project is not clonable without that sibling
  checkout.

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

**Rule sets and conflict analysis.** `gistp:priority` is loaded and unused, and `run_rule`
takes one rule. A process engine needs `run_rules(set)` — and, to be trustworthy, an answer
to "does order matter here?" There is a cheap conservative one: over predicates,

```
delta(A) = predicates in (L_A ∖ I_A) ∪ (R_A ∖ I_A)
A and B commute if  delta(A) ∩ predicates(L_B) = ∅  and  delta(B) ∩ predicates(L_A) = ∅
```

Sound but incomplete — it never claims independence falsely, which is the direction that
matters — and it is the same set arithmetic that made `interface` a six-line function.

**Declarations for literal-position variables** (§3), which is what currently blocks `oneOf`
on a literal.

**Slugging**, as an opt-in with a stated algorithm. `ENCODE_FOR_URI` gives `E%209902%2FA`.
The rule of thumb is already known: slug *controlled vocabulary terms*, never free-text data,
because slugging is lossy and a collision merges two things into one node.

**Legacy migration** — R2RML/Ontop virtualisation, view harvesting, rule mining, differential
testing against the running system. The enterprise adoption path, and the reason the engine
exists.

**Chained minting** and **RFC 6570 Level 2**, both deliberately deferred and both small.
