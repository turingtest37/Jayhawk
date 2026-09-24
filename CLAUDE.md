# Jayhawk — Graph Patterns as Graph-to-Graph Computation
The Jayhawk codebase is explained in the file `CLAUDE-about.md`. This file is *why* the
project exists and where it is going.

## What this project is

Turning RDF **graph patterns into functions that take a graph and produce a graph**, and
building that into a working computing architecture. The pattern language itself is defined
elsewhere — `gistPatterningDefinitions.ttl` in **`~/dev/gistPatterns`** (`gistp:`), and the
rule layer this engine executes — `jhp:Rule`, `RuleSet`, modes, strategies, conditions — in
`JayhawkPatterningDefinitions.ttl` in **`~/dev/JayhawkPatterningDefinitions`**
([github](https://github.com/turingtest37/jayhawkpatterning)). This project is about
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
DPO safety: add a NAC (`jhp:hasNegativeCondition`, implemented) or use
AlgebraicRewriting.jl, where the dangling condition is enforced for real.

## Where the work stands

The deterministic compiler that used to head this file as "primary next task" is **built,
tested and documented**. Every term the vocabulary declares is supported except
`gistp:instructionText`, which is an authoring hint the engine deliberately ignores.

Implemented: the three modes; both variable mechanisms (declared `SparqlVariable` individuals
and `"?x"^^gistp:var` literals); `iriTemplate` minting with RFC 6570 Level 1 slots;
`hasNegativeCondition` guards; `hasFilterCondition` comparisons; `strategy` / `maxIterations`;
`oneOf` → `VALUES`; `inGraph` scoping; firing graphs, provenance and exact undo; ordered rule
sets; seven MCP tools.

`hasFilterCondition` is the one term whose value is spliced into the emitted query, so it is
the one term with an argued threat model rather than an assumed one: `check_filters` bars
braces (and therefore `EXISTS`, which `hasNegativeCondition` already covers as a reviewable
pattern), comments and semicolons, requires balanced parentheses and closed string literals,
and refuses any variable L does not bind — because an unbound variable in a `FILTER` drops
solutions silently rather than erroring.

The checks scan a **skeleton** with string literals *and IRI references* blanked out, so a
`#` inside a quoted string or inside `<…owl#Thing>` stays data. Blanking `<…>` is a
conformance requirement, not a relaxation: the compiler emits no `PREFIX` anywhere and has
no prefix registry, so angle brackets are the only way a filter can name a resource or a
datatype. That is also why a prefixed name is refused outright — `xsd:integer` in a filter
would otherwise reach the store undeclared and return an opaque HTTP 400. Blanking is safe
because SPARQL's `IRIREF` is a token whose character set already excludes every brace and
quote the checks look for; a bracketed run that breaks that set is not an IRI, is not
blanked, and is refused. The two remaining conformance gaps are deliberate: a filter is not
parsed as an expression (`FILTER(!!!)` compiles and the store rejects it — contained, but
diagnosed late), and `jhp:filterText` is never checked for being *semantically* sensible.

The split between judgement and mechanism still holds, and is worth preserving:
- **LLM** for authoring: vague intent → the right `SparqlVariable` individuals and
  `iriTemplate` strings. Judgement-heavy, fine to keep fuzzy.
- **Deterministic code** for the mechanical step. No ambiguity, so it is real code — the
  difference between "usually compiles" and "provably compiles."

### Rule sets — built
`run_rules` applies an ordered set. A set is `jhp:RuleSet ⊑ gist:OrderedCollection`, with
membership reified as `gist:OrderedMember` carrying `gist:providesOrderFor` and
`gist:sequence`. **Not an `rdf:List`**, and the reason is decisive: SPARQL cannot recover a
position from a list — a property path yields membership as a *set*, which is right for
`gistp:oneOf` and wrong here — so order would need one round trip per member. A literal on
the membership node is one `ORDER BY`. Reifying it also puts the position on the
*membership* rather than the rule, so one rule can sit at different places in different
sets, and the set itself is a resource that can carry a label, a definition and its own
validity period. That last is the point: a revised guideline is a revised rule *set*.

Two levels of iteration, independent: each rule honours its own `jhp:strategy`, and the
set has one of its own governing how many times the whole ordered pass is made.
`jhp:priority` survives as the ordering for a bare list of rules with no set object, and
as the tiebreak between equal sequence numbers — note the directions disagree, priority
being higher-first and `gist:sequence` lower-first.

**Mixed modes are refused.** An additive rule's output is a new named graph that later rules
must read, but a `Rewrite` takes exactly one source graph which is its target — contradictory
the moment an additive rule has fired. A set is all-`Rewrite` or contains none. Lifting that
needs write-side `inGraph`, below, and is the natural next round.

### Transaction time — fixed
`_now_xsd` stamps milliseconds, and every firing carries `jayhawk:ordinal`, a monotonic
integer assigned by the same update that writes the record — read separately it could be
claimed twice, and an ordinal that is merely usually unique is not an order. `firings()`
sorts by timestamp, then ordinal, then iteration; the timestamp stays primary so a
provenance graph written by an older version still reads sensibly instead of collapsing
into one bucket.

What forced it was `run_rules`: a set applies several rules inside one second, all reporting
iteration 1, so the log had nothing left to order them by and reported them **in the wrong
order** — stably, which reads as reliable. `MAX`, not `COUNT`: undo retracts a record, and a
count-based ordinal would hand the next firing a number an existing record still holds.

### History — answerable
`retractions(; subject, predicate, object)` answers *what was once true*: every triple a
`Rewrite` removed, joined to the rule that removed it, the transaction time, the actor and
the graph it left. The facts were always kept — a rewrite writes `L∖I` to a tombstone — but
finding one meant already knowing a UUID nobody holds. Provenance is now the index, so only
graphs this engine wrote are searched. Exposed as the `retractions` MCP tool, which states
the one thing the query cannot distinguish: never-asserted and still-true both come back
empty.

**The record is carried by gist, not by PROV-O.** A firing is a `gist:Event` —
"something that occurs over a period of time, often characterized as an activity being
carried out by some person, organization, or software application", which is a rule firing
exactly. Its rule and each source graph are `gist:isBasedOn` ("gave rise to or justifies the
Subject"); the actor is a `gist:hasParticipant`; a tombstone is `gist:isProducedBy` the
firing that carved it out. The engine's own `jayhawk:` terms stay alongside, and are what the
driver actually reads.

Two things that choice buys. gist is already this project's upper ontology and already a
dependency of the pattern vocabulary, so the record speaks the same language as the data it
describes instead of a second one that has to be kept in step. And **being a historical event
is inferred rather than asserted**: `gist:HistoricalEvent` is an *equivalent* class —
`gist:Event` with exactly one `actualStartDateTime` and exactly one `actualEndDateTime` — so
the record states the two datetimes and a reasoner reaches the classification. That is the
difference between a machine-verifiable axiom and a label, and the suite asserts the class is
never stated outright.

`gist:hasParticipant` and not its subproperty `gist:comesFromAgent`, whose range is
`gist:Organization ∪ gist:Person`: most actors here are software, and asserting that "mcp" is
a person is a falsehood a reasoner would propagate. Start equals end because the engine does
not measure how long an application took — claiming an unobserved duration would be worse
than claiming none.

**PROV-O was considered and dropped.** It fit the shape well, but it meant a second
vocabulary to keep in step for no gain the record did not already have, and it is not
required by anything: the NIH challenge this work is aimed at says only that solutions
"should align with and leverage existing standards where possible", and names Biolink, not
PROV. gist is an existing standard. Any downstream alignment — PROV-O, Biolink, OWL-Time —
is a projection over this record and belongs to the project that needs it, not to the engine.

Retention is deliberately coupled to the firing: undo restores the claim *and* forgets the
retraction. A retraction outliving the firing that made it would assert a fact is no longer
held while the fact sits in the graph.

### Write-side `jhp:inGraph` — built
`jhp:inGraph` on the **construct** pattern declares where a rule's output goes. Crucially
the destination is *not* part of compilation: `insert_query` still projects `R` into a fresh
firing graph exactly as an unscoped rule does, and `promote_query` copies it into the
destination afterwards. That split is the whole design — the firing graph stays the unit of
attribution and of undo even when a rule writes into live data, because undo retracts from
the destination exactly what the firing graph holds rather than re-deriving it and hoping the
two agree.

Read and write scopes turned out to have opposite requirements, and conflating them is what
made every scoped rule look dangerous. `read_scopes` / `write_scope` separate them:

- A scoped **read** with no `source` is genuinely unsafe — with no dataset clause a graph
  variable ranges over every named graph in the store, provenance and firings included — and
  it still cannot iterate, because each round appends its firing graph to the working set.
- A scoped **write** reads nothing it was not already reading. It needs no `source`, and it
  **can** iterate: output is promoted into the destination rather than appended, so the
  dataset clause never changes and round two reads round one's results from the graph they
  went to. That is a genuine fixpoint over a named graph, and it was refused outright before.
  It does require the destination in `source`, else every round re-derives, finds its output
  already promoted, prunes to nothing and reports convergence after one pass — the right
  answer by accident.

This also narrowed the rule-set refusal from "no mixed modes" to "no *undirected* additive
rule alongside a `Rewrite`". Give the additive members a destination and a mixed set composes:
the working set never grows, so the `Rewrite` still has exactly one source, and it reads the
derived triples from the graph they were written to.

Still refused: a scope on R with `Rewrite` (a rewrite's destination *is* the graph it reads;
naming a second is a different operation), and a scope on R naming a `gistp:TabularDataSource`
(a SERVICE cannot be written to).

### `gistp:SourceMap` — built
A source map says "this variable comes from that column" and the compiler owes the rest: the
Facade-X predicate IRI, the row container, and the value pipeline. The match pattern no
longer names `xyz:` predicates, and for an extraction rule L is **empty** — the maps supply
all of it.

`mapFromString` carries "the source's own spelling", so `fx_predicate` owes the encoding, and
**the rule was measured against SPARQL Anything rather than read from its docs, which are
wrong**: both upstream and the local skill notes claim `dc.title[en]` becomes
`dc.title%5Ben%5D`. It does not, and a query naming the documented form matches nothing.

The encoded set is `<>"{}|^\` and backtick and everything ≤U+0020 — what SPARQL's `IRIREF`
production forbids — **plus `#`, `(` and `)`, which it permits**. Brackets, `%`, `&`, `+`,
`?` and `;` are left raw.

That correction is worth keeping, because the first version of this got it wrong in an
instructive way. The encoder's specification was stated as "make it pass `check_iri`,
changing nothing else", on the reasoning that both sets come from the same SPARQL production
— tidy, and false. `#` and the parentheses are legal in an `IRIREF` and are encoded anyway,
so a column named `Trade #` compiled to a predicate the service never emits, and the rule
**matched nothing rather than erroring** — the exact failure the whole feature exists to
prevent, reintroduced one level down. The specification is now the measurement: one header
per interesting character pushed through the service, predicates read back, asserted in the
suite. Passing `check_iri` stays necessary and is no longer sufficient.

The pipeline order is the vocabulary's, not a choice: `separator` splits (so must be first),
`stringBefore` truncates each value, then `valuePatternMatch` / `valuePatternExclude` are
decisions about a finished value and compile to `FILTER`s. `separator` is a literal string
while ARQ's `apf:strSplit` takes a regex, so `regex_quote` owes that escaping too — an author
who writes `"."` means a full stop. `stringBefore` compiles to
`IF(CONTAINS(…), STRBEFORE(…), …)` rather than a bare `STRBEFORE`, which returns the empty
string when the needle is absent and would silently blank every value not containing it.

A map with no pipeline compiles to exactly the one triple an author would have written by
hand. The feature is not a new mechanism; it is the author no longer owing an IRI.

Worth knowing before writing one: a mapped variable is a **required** join. A row whose
mapped cell is empty yields no solution at all, so the whole row vanishes — not just that
value. Ordinary SPARQL, and the opposite of what the maps read like.

### The bondfix demonstration — in progress
`examples/moneygraph/bondfix/` re-expresses moneygraph's `fix-missing-bond-data.rq` as an
ordered rule set held to the query's output quad for quad. **Round 1 is done**: fixture,
oracle (the committed query with its unjoined currency pattern fixed) and a frozen golden,
enforced by the integration suite. See that directory's README for the cases and for why the
live store cannot serve as the oracle.

Three engine gaps stand between it and a working rule set, taken in this order:
1. **Multi-pattern L — built (Round 2).** `jhp:hasMatchPattern` is one or more, each with
   its own `jhp:inGraph`; L is their conjunction. Needed because trades and holdings share
   predicates: on `test/fixtures/multi_match_rule.trig` the merged-source workaround derives
   6 pairs where 1 is true. Refused with `Rewrite` and with source maps; lifting either is
   backlog, as is `ToFixpoint` for a scoped read whose output is promoted to a destination
   (its working set never grows, so the refusal is stricter than the hazard).
2. **`jhp:hasBinding`**: `jhp:bindText` (one SPARQL expression, held to `check_filters`'
   threat model) → a declared `gistp:LiteralVariable`, topologically ordered, usable as a
   mint slot. It covers slugging, symbol normalisation and the MD5 discriminator the query
   mints from, and it closes chained minting for literals. A declarative pipeline was
   rejected because it cannot express the MD5.
3. **`rerun_rules!`**: undo a set's earlier firings, then run. This is the rule-set
   equivalent of the script's `DROP SILENT GRAPH`, and removes exactly what the set asserted.

The decomposition then needs no further engine work:
- OPTIONAL branches become separate rules.
- Two output graphs become one rule per destination.
- The heuristic trade↔holding join is materialised once, by the first rule, as a link fact
  in a working graph.

### Known next tasks
- **The list-valued source-map terms are unbuilt**: `gistp:mapFrom` (the vocabulary has no
  class for a source attribute, so there is nothing to read a column name off),
  `gistp:mapFirst` (COALESCE over one binding per member), `gistp:concat` (CONCAT likewise),
  and `gistp:mapEach` — the hardest, because it *multiplies* solutions and so is a UNION over
  the match rather than an expression over one binding. All four are refused by name.
- **A write destination must be a constant.** A graph *variable* on R would send different
  solutions to different graphs, and a firing graph is one flat set of triples with nowhere
  to record which triple went where — so undo could not reverse it. Refused. Per-solution
  destinations would need the firing graph to carry a destination per triple; minting the
  graph IRI with `gistp:iriTemplate` and running once per graph is the workaround.
- **Wiring the extension surface.** `RdfMaterializer` is the intended home for operators
  SPARQL cannot express — arithmetic beyond trivia, statistics, optimisation, the Julia
  numerical stack. It is a separate package and nothing here depends on it; connecting them
  is now an explicit dependency decision rather than an accident of packaging.
- **Trimming the export surface.** ~110 exported names, including compiler internals and
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
  rewriting; don't reimplement it in the compiler. Note that `jhp:_RewriteMode_assert` runs to a fixpoint
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
