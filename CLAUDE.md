# Jayhawk — Graph Patterns as Graph-to-Graph Computation
The Jayhawk codebase is explained in the file `CLAUDE-about.md`. This file is *why* the
project exists and where it is going.

## What this project is

Turning RDF **graph patterns into functions that take a graph and produce a graph**, and
building that into a working computing architecture. The pattern language itself is defined
elsewhere — `gistPatterningDefinitions.ttl` in **`~/dev/gistPatterns`**. This project is about
**executing** those patterns: compiling, running, and reasoning over them.

Organizing idea: a pattern can play the role of **I, L, or R** in a graph-rewrite span
(L ← I → R); a rule pairs a match pattern (L) with a construct pattern (R).

Grounding fact: RDF entailment is *already* defined as graph homomorphism (Hayes, RDF
Semantics), so "does G entail G'" is literally the graph homomorphism problem. That is the
seed the whole idea grows from.

## Four theoretical traditions (keep distinct)

The "graph in → function → graph out" shape has (at least) four independent formalizations,
answering different questions with different tooling:

1. **Fixpoint rules** — Datalog / OWL RL / N3. "Apply rules to a fixpoint" = monotone closure
   over a lattice of graphs (Knaster–Tarski / van Emden–Kowalski). What a real reasoner does;
   don't reimplement by hand.
2. **Algebraic graph transformation** — DPO / SPO rewriting via pushouts in a category of
   graphs. The direct formalization of "pattern as I/L/R". Concerns: confluence, termination,
   dangling condition.
3. **Graph-native execution** — graph reduction, interaction nets, bigraphs. Locality and
   concurrency. Least relevant so far.
4. **Functorial data migration** — schema = category, instance = functor C→Set, migration via
   Δ / Σ / Π (pullback / left & right Kan extension). Cleanest categorical fit for RDF-shaped
   data. Implemented in Julia by AlgebraicJulia (Catlab.jl / ACSets.jl / AlgebraicRewriting.jl).

## Core architectural decision: compile patterns to SPARQL Update

A SPARQL `DELETE {L∖I} INSERT {R∖I} WHERE {L}` is structurally a **single-pushout (SPO) graph
rewrite**. So the core is a **compiler** from the RDF pattern definitions to SPARQL Update
text — not a hand-built rewriting engine. Matching, replacement, and atomicity come free from
any triple store.

**This decision is made and implemented.** It held up: the compiler is a pure function of a
`RuleSpec`, and the whole of compilation is testable against golden SPARQL with no server
running. Treat it as settled, not as an option still being weighed.

- **CONSTRUCT-only** (no delete) = pure function G→G', referentially transparent, composable
  (f∘g). Matches the monotone/fixpoint tradition.
- **DELETE/INSERT** = stateful in-place rewrite. Closer to true SPO/DPO.
- The mode is an **explicit property of the rule**, not implied by which triples repeat
  between clauses. Repetition decides **I**; the mode decides what happens to `L∖I`.

### SPO vs DPO caveat
Plain SPARQL Update is SPO: it deletes what it's told and doesn't check for stranded
references (no dangling condition). RDF's open world mostly tolerates this, but a rule that
deletes a node's identity triples while other triples still reference it yields silent
orphans. `dangling_risks` **reports** this at compile time and `explain_rule` shows it before
anything runs — it does not refuse, because stripping a node is sometimes the intent. For real
DPO safety: add a NAC (`gistp:hasNegativeCondition`, implemented) or use
AlgebraicRewriting.jl, where the dangling condition is enforced for real.

## Where the work stands

The deterministic compiler that used to head this file as "primary next task" is **built,
tested and documented**. Every term the vocabulary declares is supported except
`gistp:instructionText`, which is an authoring hint the engine deliberately ignores.

Implemented: the three modes; both variable mechanisms (declared `SparqlVariable` individuals
and `"?x"^^gistp:var` literals); `iriTemplate` minting with RFC 6570 Level 1 slots;
`hasNegativeCondition` guards; `strategy` / `maxIterations`; `oneOf` → `VALUES`; `inGraph`
scoping; firing graphs, provenance and exact undo; five MCP tools.

The split between judgement and mechanism still holds, and is worth preserving:
- **LLM** for authoring: vague intent → the right `SparqlVariable` individuals and
  `iriTemplate` strings. Judgement-heavy, fine to keep fuzzy.
- **Deterministic code** for the mechanical step. No ambiguity, so it is real code — the
  difference between "usually compiles" and "provably compiles."

### Known next tasks
- **`run_rules` (plural).** `gistp:priority` is loaded, validated and displayed, but nothing
  acts on it: `run_rule` takes one rule at a time. Ordering a rule *set* is the missing piece.
- **`gistp:inGraph` is read-side only.** Scope on R, with `Rewrite`, with `ToFixpoint`, or
  with an empty `source` is refused rather than half-supported. Write-side scoping is open.
  A scope naming a `gistp:TabularDataSource` now compiles to `SERVICE <x-sparql-anything:>`,
  so a rule can read a CSV directly — but only the *binding source* half is built. The
  `gistp:SourceMap` half (`mapFrom`/`mapFirst`/`mapEach` → a Facade-X BGP, plus the
  `separator` / `stringBefore` / `valuePattern*` pipeline) is not, so the pattern still
  names `xyz:` columns itself.
- **Wiring the extension surface.** `RdfMaterializer` is the intended home for operators
  SPARQL cannot express — arithmetic beyond trivia, statistics, optimisation, the Julia
  numerical stack. It is a separate package and nothing here depends on it; connecting them
  is now an explicit dependency decision rather than an accident of packaging.
- **Trimming the export surface.** ~105 exported names, including compiler internals and
  generic ones (`select`, `interface`, `ask`, `endpoint`) that collide on `using`. A breaking
  change, so it belongs to a deliberate 0.5.0.

## Alternatives considered (compile target)
Kept as the record of why the current design won, not as live options.
- **SHACL-AF** (`sh:SPARQLRule` / `sh:TripleRule`) — inherit a W3C vocab + existing engines
  (TopBraid, pySHACL) instead of a bespoke compiler+interpreter.
- **N3 rules** (`{L} => {R}`, EYE/cwm) — standardized, monotone; best if framing as inference
  rather than rewriting.
- **Explicit span resources** — most theory-faithful; required if confluence or
  dangling-condition analysis is ever wanted (needs I, L→I, R→I as real objects). The current
  design authors **I by repetition** instead, which is cheaper to write and cannot express a
  non-injective span.
- **Hybrid** — gist Patterning as the authorable source; two backends off the same RDF:
  SPARQL Update for in-store execution, Catlab `Rule` for DPO guarantees / Julia-side compute.

## Environment notes
- **Julia parses no RDF.** Since v0.4.0 files reach the store over the Graph Store Protocol
  and **Jena parses every byte**; terms come back as SPARQL Results JSON, modelled by
  `src/term.jl`. This is deliberate — a datatype is how this engine marks a variable, and
  most parsers normalise datatypes away. Do not reintroduce a Julia-side RDF parser on the
  read path.
- Julia RDF tooling is thin, and that no longer matters here. `Serd.jl` (Patterson) is still
  used by `RdfMaterializer`, which needs a private fork; **Jayhawk depends on neither**.
  There is no mature Julia SPARQL engine or OWL reasoner — shell out to a real store (Jena,
  Oxigraph, Stardog, RDFox) for reasoning/materialization.
- For fixpoint/closure work (RDFS/OWL RL), use a real reasoner as a separate process and
  materialize its output — it's a different operation (monotone closure) from SPO/DPO
  rewriting; don't reimplement it in the compiler. Note that `gistp:Assert` runs to a fixpoint
  *within one rule*; that is not the same thing as RDFS/OWL closure over a whole graph.
- AlgebraicJulia stack (Catlab.jl, ACSets.jl, AlgebraicRewriting.jl) is the route for the
  functorial-migration or true-DPO path. API not yet stable — check current docs.

## Cross-reference
Pattern-language mechanics, the SHACL shapes, the worked example rules and `verify.py` live in
**`~/dev/gistPatterns`**; its design notes are `pattern-system-CLAUDE.md`. That repo and this
one move together — a vocabulary term and its compiler support land in the same round.

> **`~/dev/SyneticSemantics` is a shared corporate repo — do not modify it.** It holds an
> older, much shorter copy of `gistPatterningDefinitions.ttl` (174 lines against 600). It is
> not the source of truth and must not be edited from here.
