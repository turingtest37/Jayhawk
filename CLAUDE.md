# Jayhawk — Graph Patterns as Graph-to-Graph Computation
The Jayhawk codebase is explained in the file `CLAUDE-about.MD`.

## What this project is

Turning RDF **graph patterns into functions that take a graph and produce a graph**, and
building that into a working computing architecture. The pattern language itself is defined
elsewhere — `gistPatterningDefinitions.ttl` in the `SyneticSemantics/ontologies` repo (see
its own `CLAUDE.md` / design notes for how patterns are expressed). This project is about
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
rewrite**. So the recommended core is a **compiler** from the RDF pattern definitions to
SPARQL Update text — not a hand-built rewriting engine. Matching, replacement, and atomicity
then come free from any triple store.

- **CONSTRUCT-only** (no delete) = pure function G→G', referentially transparent, composable
  (f∘g). Matches the monotone/fixpoint tradition.
- **DELETE/INSERT** = stateful in-place rewrite. Closer to true SPO/DPO.
- Make this **mode an explicit property of the rule**, not implied by which triples repeat
  between clauses.

### SPO vs DPO caveat
Plain SPARQL Update is SPO: it deletes what it's told and doesn't check for stranded
references (no dangling condition). RDF's open world mostly tolerates this, but a rule that
deletes a node's identity triples while other triples still reference it yields silent
orphans. If DPO safety is wanted: add a NAC ("no other triples reference this node") or an
explicit dangling check — or use AlgebraicRewriting.jl, where DPO's dangling condition is
enforced for real.

## Primary next task: the deterministic compiler

Split the pattern→SPARQL work into two jobs:
- **LLM** for authoring/interpretation: vague intent → the right `SparqlVariable` individuals
  + `iriTemplate` strings. Judgement-heavy, fine to keep fuzzy.
- **Deterministic code** for the mechanical step: walk the pattern graph, substitute
  `variableText` for `SparqlVariable`-typed terms and `^^gistp:var` literals, emit BGP
  triples, assemble the `CONSTRUCT` / `DELETE…INSERT…WHERE`. A few dozen lines, no ambiguity.

This is the difference between "usually compiles" and "provably compiles," and the mechanical
half needs no judgement — so it should be real code. Start here. Read the actual ttl on disk
(don't work from summaries) so every variable and template is seen first-hand.

## Alternatives considered (compile target)
- **SHACL-AF** (`sh:SPARQLRule` / `sh:TripleRule`) — inherit a W3C vocab + existing engines
  (TopBraid, pySHACL) instead of a bespoke compiler+interpreter.
- **N3 rules** (`{L} => {R}`, EYE/cwm) — standardized, monotone; best if framing as inference
  rather than rewriting.
- **Explicit span resources** — most theory-faithful; required if confluence or
  dangling-condition analysis is ever wanted (needs I, L→I, R→I as real objects).
- **Hybrid** — gist Patterning as the authorable source; two backends off the same RDF:
  SPARQL Update for in-store execution, Catlab `Rule` for DPO guarantees / Julia-side compute.

## Environment notes
- Julia RDF tooling is thin. `Serd.jl` (Patterson) for Turtle/N-Triples I/O. No mature Julia
  SPARQL engine or OWL reasoner — shell out to Python `rdflib` via `PythonCall.jl`, or to a
  real store (Jena, Oxigraph, Stardog, RDFox) for reasoning/materialization.
- For fixpoint/closure work (RDFS/OWL RL), use a real reasoner as a separate process and
  materialize its output — it's a different operation (monotone closure) from SPO/DPO
  rewriting; don't reimplement it in the compiler.
- AlgebraicJulia stack (Catlab.jl, ACSets.jl, AlgebraicRewriting.jl) is the route for the
  functorial-migration or true-DPO path. API not yet stable — check current docs.

## Cross-reference
Pattern-language mechanics and the ontology-level improvement backlog (add `gistp:Rule`,
constrain `instructionText`, etc.): see the design notes / `CLAUDE.md` in
`SyneticSemantics/ontologies`. If that repo is checked out at a known path, you can pull it in
here with a CLAUDE.md import, e.g.:
`@../SyneticSemantics/ontologies/CLAUDE.md` (adjust to the real relative path).
