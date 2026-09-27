# Jayhawk → enterprise product: implementation roadmap

**Handoff document.** Written 2026-09-27 for a future Claude session that has none of the
originating conversation's context. Everything needed to implement is in this file plus the
repo's own design records. Line references were verified against Jayhawk HEAD `62df92a`
(branch `gist-14.1`); re-verify any you lean on if the tree has moved.

## Read this first (cold-start orientation)

1. Read `/Users/doug/dev/Jayhawk/CLAUDE.md` and `CLAUDE-about.md` in full. They are the
   authoritative design record; this plan extends them and must not contradict them.
2. Repos involved: `~/dev/Jayhawk` (the engine — all Julia work),
   `~/dev/JayhawkPatterningDefinitions` (the `jhp:` vocabulary — Round 1 touches
   `ontologies/JayhawkPatterningDefinitions.ttl` and `ontologies/JayhawkPatternShapes.ttl`;
   note the `ontologies/` subdirectory, not repo root). The two repos move together: a
   vocabulary term and its compiler support land in the same round.
   **Never touch `~/dev/SyneticSemantics`** (shared corporate repo; holds a stale copy of the
   pattern definitions).
3. Skills to use: `jl-test` (run the suite), `jl-probe` (check a hypothesis against the loaded
   package), `sparql` (Fuseki test server), `ttl` (validate/diff Turtle), `julia` (style).
4. Hard engine constraints (CLAUDE-about.md §Hard constraint): absolute IRIs only; never call
   `makeqname`; never `Core.eval`. Literal datatypes are load-bearing (`^^gistp:var` marks a
   variable) — never introduce a Julia-side RDF parser on the read path.
5. Methodology (the user's standing preference): **prove each failure empirically before
   fixing it** — a behavioral defect gets a failing test first, committed with the fix; keep
   rounds narrow and write every deferral into the backlog with its reason.
6. Test commands: `julia --project=. test/runtests.jl` (hermetic, ~6 s);
   `./bin/fuseki-test.sh start` then `JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl`
   (integration). The MCP server env is separate: `bin/Project.toml`.

## Context: why this work, in this order

An architecture assessment (published at https://claude.ai/artifact/Sn4jmu5Pny8DHQCuCXXaoE;
the user has it) concluded Jayhawk is strong at *structural* enrichment — reshape, link, mint,
classify, with per-triple provenance and exact undo as the enterprise differentiator — but
cannot express *computational* enrichment: aggregation and arithmetic. A rule cannot say "sum
the line items," which is half the enterprise workload (accounting, sales, HR).

**RdfMaterializer was evaluated and rejected as the compute surface.** Do not wire it in. At
`~/dev/RdfMaterializer`: it requires the private Serd fork at module load
(`RdfMaterializer.jl:28`, `Project.toml [sources]`), routes through Serd's process-global
prefix registry and `Core.eval` (`execute.jl:23-26`) — the exact hazards Jayhawk's hard
constraint bans — drops literal datatypes (`sparql.jl:30-33`), and has no
SELECT→compute→write path. The only thing worth taking is its error-taxonomy *design*
(unmapped / unmatched / broken). The compute bridge is therefore built inside Jayhawk.

The user chose the ordering below (Round 0 hardening first, compute bridge as centerpiece;
undo guard, retention, and export trim deliberately to the backlog).

## Verified facts the plan builds on (spot-checked in source)

- `load_rule`'s opening SELECT **hard-requires** `jhp:hasConstructPattern`
  (compile.jl:596-607) — a construct-less rule errors before anything else runs.
- `JayhawkPatternShapes.ttl:39-43` demands exactly one `hasConstructPattern` per rule — the
  shapes file must change in the same round as the vocabulary.
- `dataset_lines(spec, from; keyword="USING")` already takes a `keyword` argument
  (compile.jl:1698-1699), so a SELECT builder gets `FROM` / `FROM NAMED` for free.
- `apply_rule` (harness.jl:327-388): checks at 340-341 (`check_collisions`,
  `check_target_empty`), Rewrite branch at 343, insert 353, `prune_known!` 357, promote
  363-365, `record_firing!` 385. The compute branch slots after 341.
- The `max_iterations` bug is in **two** handlers: `bin/mcp_server.jl:140` (run_rule) and
  `:208` (run_rules), both `get(a, "max_iterations", 100)`. Neither tool declares a
  `strategy` ToolParameter at all.
- `check_runnable`'s unbounded-ToFixpoint-Rewrite refusal triggers only on
  `max_iterations === nothing` (harness.jl:570-584), so the handler default of 100 defeats it.
- `tool_run_rules`' hand-rolled mixed-mode check is mcp.jl:448-459; the harness's correct,
  narrower check is `check_rule_sequence` (harness.jl:768-824) — allows write-scoped additive
  members beside a Rewrite. Known discrepancy, noted in CLAUDE.md.
- `firings(; rule, rule_set)` exists (harness.jl:1151) but `list_firings` (bin/mcp_server.jl
  ~266-280) doesn't expose `rule_set`.
- `undo_firing!` (harness.jl:1003-1077) is driven entirely by the firing record (target /
  tombstone optional) — an additive firing with neither needs zero undo changes.
- Stale text predating Rewrite: harness.jl:12-14 (header), harness.jl:990-991
  (`undo_firing!` docstring), mcp.jl:571-574 (`tool_undo_firing` docstring); server version
  string "0.3.0" at bin/mcp_server.jl:285 vs Project.toml 0.4.0.
- `RuleSpec` is compile.jl:185-234; back-compat positional constructors at 237, 283, 348,
  391, 414, 439, 478, 518 — adding a field means adding one more.
- `select(q; ep)` returns `Vector{Dict{String,RDFTerm}}` with typed literals preserved
  (sparqlclient.jl:242-249). `check_iri` is term.jl:165; `sparql_text` term.jl:142-149.
- `where_body` (compile.jl:1760-1771) is the single WHERE builder all seven query builders
  route through — guards, filters, VALUES, bindings, mint BINDs, source-map pipelines.
- Hermetic golden-test pattern: test/runtests.jl:166-211 (byte-for-byte `@test
  compile_rule(sorted) == expected`); error tests via try/catch + `occursin(…,
  sprint(showerror, e))`. Integration fixtures in test/fixtures/*.trig; `engine_cleanup()`
  at sparql_integration.jl:148-205.

---

## Round 0 — MCP parity and the iteration-budget bug

Files: `bin/mcp_server.jl`, `src/mcp.jl`, `src/harness.jl` (comments/docstrings only),
`test/sparql_integration.jl`, `test/runtests.jl`.

### 0.1 `max_iterations` silently overrides the rule and defeats the unbounded-Rewrite refusal

Fix: add a helper beside the existing `str`/`graphs` helpers in `bin/mcp_server.jl`:

```julia
int_or_nothing(args, key) =
    haskey(args, key) && args[key] !== nothing ? Int(args[key]) : nothing
```

and change both handlers (lines 140 and 208) to
`max_iterations=int_or_nothing(a, "max_iterations")`. `tool_run_rule`/`tool_run_rules`
already default to `nothing`, and `check_runnable`'s
`something(max_iterations, spec.max_iterations, DEFAULT_MAX_ITERATIONS)` then does the right
thing.

Proof tests first (integration; they must fail against the pre-fix behavior, reproduced by
calling the tool function exactly as the buggy handler did):
- A minting Assert rule declaring `jhp:maxIterations 2` that converges only at iteration 3:
  `tool_run_rule(rule; source=[g], max_iterations=100)` (old handler call) converges
  silently; `tool_run_rule(rule; source=[g])` (fixed passthrough) must return the "still
  changing the graph after 2 iterations" error text.
- A ToFixpoint Rewrite with no declared bound: with `max_iterations=100, confirm=true` it
  runs (documents the defeat); with the fixed passthrough the harness.jl:570-584 refusal
  text ("must state a bound") comes back.

Hermetic drift-check (the adapter can't be loaded in the package test env because
ModelContextProtocol lives only in `bin/Project.toml`; precedent: the bondfix-copy
drift-check): a testset that reads `bin/mcp_server.jl` as text and asserts
`!occursin("get(a, \"max_iterations\", 100)", src)` and the presence of `int_or_nothing`.

### 0.2 `tool_run_rules` stricter than the harness

Replace the hand-rolled check at src/mcp.jl:448-459 with delegation:

```julia
set_strategy = something(strategy, spec.strategy, :Once)
budget = something(max_iterations, spec.max_iterations, Jayhawk.DEFAULT_MAX_ITERATIONS)
try
    check_rule_sequence(specs, "<$set>", set_strategy, budget; source=source)
catch e
    return "Refused: rule set <$set> cannot run as given.\n\n$listing\n\n" *
           sprint(showerror, e)
end
```

Keep the confirm-gate for Rewrites and the `replace` gate exactly as they are. Result: the
MCP tool accepts a Rewrite mixed with *write-scoped* additive members, matching
harness.jl:795-812.

Proof test (integration): a set of one Rewrite + one write-scoped additive rule (compose from
the existing `write_scoped_rule.trig` / rewrite fixtures): assert harness `run_rules`
succeeds while `tool_run_rules(...; confirm=true)` refuses pre-fix; post-fix both run.
Negative control: an *undirected* additive + Rewrite set is still refused, now with
`check_rule_sequence`'s message.

### 0.3 `strategy` unreachable over MCP; `list_firings` missing `rule_set`

- Add a `strategy` ToolParameter (string, "Once" | "ToFixpoint") to `run_rule` and
  `run_rules`; marshal `(s = str(a, "strategy")) === nothing ? nothing : Symbol(s)`.
  The tool functions already validate via `effective_strategy`.
- Extend `tool_firings` (src/mcp.jl:671) with `rule_set=nothing`, forwarding to
  `firings(; rule, rule_set)`; print each firing's set when present. Add the ToolParameter.
- Integration test: run a set, then `tool_firings(rule_set=set_iri)` shows only its firings.
  Drift-check asserts the two new ToolParameters exist in the adapter text.

### 0.4 Stale text (doc-only, no tests)

- harness.jl:12-14 and 990-991, mcp.jl:571-574: state that Rewrite is built and that undo
  replays tombstones (harness.jl:1044-1057 is the proof).
- bin/mcp_server.jl:285: version → match Project.toml.
- Both "(default 100)" parameter descriptions → "defaults to the rule's own
  jhp:maxIterations, then 100".

**Done when:** both proof tests fail pre-fix and pass post-fix; hermetic + integration suites
green; CLAUDE.md's "Noticed, not fixed" paragraph about the MCP discrepancy is updated.

---

## Round 1 — The compute bridge

One sentence: a rule whose L compiles (via the existing `where_body`) to a SPARQL SELECT,
whose R is produced by a caller-registered Julia function over the typed result rows, and
whose output lands in a firing graph with provenance and undo identical to a compiled rule's.

### (a) Rule shape and vocabulary (lands with the compiler support, same round)

A compute rule declares `jhp:hasMatchPattern` (1..n), `jhp:rewriteMode
jhp:_RewriteMode_construct`, **no** `jhp:hasConstructPattern`, and exactly one
`jhp:isComputedBy` naming a `jhp:ComputeFunction` individual. No output-variable
declaration: the function returns concrete `RDFTerm` triples, so typing travels with the
values (an RDF-side output schema would be one the engine couldn't enforce anyway).

In `~/dev/JayhawkPatterningDefinitions/ontologies/JayhawkPatterningDefinitions.ttl`, add —
matching the file's existing label/definition/scopeNote conventions (read neighboring terms
first):

- `jhp:isComputedBy` — `owl:ObjectProperty`, domain `jhp:Rule`, range `jhp:ComputeFunction`.
  Scope notes must state: mutually exclusive with `hasConstructPattern` (a rule carries
  exactly one of the two); a construct pattern is a template instantiated once per solution,
  while a compute function receives EVERY solution at once — which is what lets it express a
  sum, a mean, an optimisation over the whole match — and returns concrete triples with no
  variables; L is unchanged (match pattern, NACs, filters, bindings, oneOf, minting, source
  maps all apply; only the wrapper differs — SELECT projecting every bound variable rather
  than CONSTRUCT); the function is identified by IRI alone, its implementation registered by
  the engine host as explicit data, never resolved by evaluating names found in the graph;
  an engine must refuse to run when no implementation is registered; engines should refuse
  `_RewriteMode_rewrite` (a function only ever adds) and ToFixpoint (iterating an opaque
  function is the chase); output carries the same provenance/undo as a compiled rule.
- `jhp:ComputeFunction` — class (suggested parent: `gist:SchemaMetaData`, mirroring how
  `gistp:MintingFunction` sits; check what that actually subclasses and follow suit). Its
  scope note: an IRI, label, definition, optionally a `gist:conformsTo` policy — recorded,
  not enforced, exactly as `gistp:MintingFunction`'s policy is; what the function actually
  does is whatever the host registered, which is why every firing records which function ran.

In `ontologies/JayhawkPatternShapes.ttl`: RuleShape's exactly-one `hasConstructPattern`
(lines 39-43) becomes an `sh:xone` of {exactly one `hasConstructPattern`, zero
`isComputedBy`} vs {zero `hasConstructPattern`, exactly one `isComputedBy`}. Add a
ComputeFunction node shape if the file has shapes for comparable classes.

Validate both files with the `ttl` skill; run the vocabulary repo's own checks if present.

### (b) SELECT compilation (`src/compile.jl`)

- `const P_COMPUTEDBY = JHP_NS * "isComputedBy"` beside the other `P_` constants.
- `RuleSpec` gains a trailing field `compute::Union{String,Nothing}` plus one more
  back-compat positional constructor defaulting it to `nothing` (the established pattern at
  compile.jl:237-280 — look at how `bindings` was added).
- `load_rule` (compile.jl:592-628): make `?c` OPTIONAL in the opening SELECT and add
  `OPTIONAL { <r> <P_COMPUTEDBY> ?fn }`. Validate exactly-one-of: both present → error
  "a rule is compiled or computed, not both"; neither → the existing "must carry …" error,
  reworded to name both options. For a compute rule: `construct_graph=""`,
  `construct=PatternTriple[]`, `construct_scope=nothing`.
- New builder beside `insert_query` (compile.jl:3231):

  ```julia
  """
      select_query(spec; from = String[]) -> String

  The compute-rule wrapper around `where_body`: one SELECT projecting every
  variable L binds, so each row is a full distinct solution.
  """
  function select_query(spec::RuleSpec; from::AbstractVector=String[])
      check_bound(spec)
      vars = projected_vars(spec)  # sort(union(pre_bound(spec), binding_vars(spec), minted_vars(spec)))
      return "SELECT $(join(vars, " "))\n" *
             dataset_lines(spec, from; keyword="FROM") *
             "WHERE {\n$(where_body(spec))\n}\n"
  end
  ```

  Reusing `where_body` is the whole point: guards, filters, VALUES, bindings, mint BINDs and
  source-map pipelines apply with zero new code; `dataset_lines(...; keyword="FROM")` gives
  scoped reads the FROM/FROM NAMED discipline. Projecting *every* bound variable (sorted,
  for byte-stable goldens) keeps rows as full distinct solutions — no duplicate-collapse
  that would corrupt a sum.
- `compile_rule` branches on `spec.compute !== nothing`: emit
  `# Compute rule <iri>, computed by <fn>` + the SELECT — so explain_rule's "compiles to:"
  shows what actually runs.
- New `check_compute(spec)` wired into the `check_bound` umbrella (compile.jl:2764-2774):
  refuse a compute spec with nonempty `construct`/`construct_scope`; refuse compute +
  `:Rewrite` ("a compute function only ever adds; Rewrite deletes"); refuse compute +
  `:Assert` (Assert's meaning *is* fixpoint union — declare Construct). NACs, filters,
  bindings, oneOf, mints and source maps are **allowed**: they constrain or enrich L, which
  is exactly what they mean, and refusing them would cost more code than allowing them.
  `check_collisions` still guards mints at apply time.

### (c) Function contract, registry, error taxonomy (`src/harness.jl`)

- Registry is explicit data: `registry::AbstractDict{String,<:Any}` keyed by absolute
  function IRI (validate keys with `check_iri`), passed as a keyword through
  `run_rule` / `run_rules` / `_run_rule_sequence` / `dry_run` (default
  `Dict{String,Function}()`). No module global, no eval — the hard constraint.
- Contract: `f(rows::Vector{Dict{String,RDFTerm}})` → iterable of 3-tuples of `RDFTerm`.
  The function sees ALL rows in one call, so aggregation (group, sum, whatever Julia can do)
  needs nothing from the engine.
- `validate_compute_triples(spec, out)` — pure, hermetic-testable: every element a 3-tuple
  of `RDFTerm`; subject and predicate `IRIRef` passing `check_iri` (BNodes refused, message
  pointing at skolemization: mint an IRI instead); object `IRIRef` (checked) or
  `RDFLiteral`; refuse any literal whose datatype is `GISTP_VAR` — a variable marker leaking
  into data is the one confusion this engine can never permit. Serialize with `sparql_text`.
- Exceptions (design copied from RdfMaterializer's taxonomy; that package stays
  un-depended-on):

  ```julia
  struct ComputeFunctionMissing <: Exception   # "unmapped"
      rule::String; fn::String; registered::Vector{String}
  end
  struct ComputeFailed <: Exception
      rule::String; fn::String; kind::Symbol; cause::Any   # :unmatched | :broken
  end
  ```

  with `showerror` methods. `:unmatched` = a `MethodError` whose `.f === fn` (the registered
  function's own dispatch rejected the rows); `:broken` = anything else thrown, carrying the
  cause. Both always rethrow — no `strict` flag; the MCP layer's `guarded` renders them as
  text.

### (d) Execution path (`src/harness.jl`)

```julia
const COMPUTE_INSERT_CHUNK = 5_000

compute_insert_updates(into, triples; chunk=COMPUTE_INSERT_CHUNK) -> Vector{String}
    # pure: INSERT DATA { GRAPH <into> { ... } } texts, ≤ chunk triples each

function apply_compute!(spec::RuleSpec; into, source, actor, iteration,
                        rule_set=nothing, registry, ep) -> Firing
```

Branch from `apply_rule` right after `check_collisions`/`check_target_empty`
(harness.jl:340-343): `spec.compute !== nothing && return apply_compute!(...)`.

Steps, in order: registry lookup **first** (throw `ComputeFunctionMissing` before touching
the store) → `rows = select(select_query(spec; from=source); ep)` →
`Base.invokelatest(fn, rows)` inside the classifying try/catch → `validate_compute_triples`
→ chunked `update!` of each INSERT DATA → `prune_known!(into, prune_set(spec, source); ep)`
(no destination in round 1, so "new" means new to the working set) →
`n = graph_size(into; ep)` → `n == 0 ? DROP SILENT GRAPH : record_firing!(f; actor,
rule_set, compute_function=spec.compute, ep)` → return
`Firing(into, spec.iri, :Construct, Int(iteration), n, String.(source))` (the 6-arg
constructor, harness.jl:76).

`record_firing!` (harness.jl:180) gains `compute_function=nothing`, emitting when present:

```
<firing> <jayhawk:computeFunction> <fn> ;
         <gist:isBasedOn>          <fn> .
```

(same pattern as the rule-set triples at harness.jl:224-229). The record has no target and
no tombstone, so **`undo_firing!` needs zero changes** — undo is DROP GRAPH + record
retraction, exactly as for a compiled additive rule. Verify that claim by reading
harness.jl:1003-1077 before relying on it.

Refusals in `check_runnable` (harness.jl:489) for compute specs: strategy resolving to
`:ToFixpoint` — error text: "iterating a compute function is the chase; nothing bounds an
opaque function" (backlog item). No write destination in round 1 (no construct pattern to
hang `jhp:inGraph` on; backlog).

### (e) MCP exposure (`src/mcp.jl`, `bin/mcp_server.jl`)

- `tool_run_rule` / `tool_run_rules` / `tool_explain_rule` gain `registry` kwargs (default
  empty).
- Server startup: if env `JAYHAWK_COMPUTE_FILE` names a Julia file, `include` it at top level
  (no world-age problem) and require it to return a `Dict{String,Function}` keyed by IRI;
  otherwise empty. Handlers close over it. This is the caller's explicit code — never names
  eval'd from RDF.
- `ComputeFunctionMissing`'s `showerror`: "rule <r> is computed by <fn>, and this process has
  no implementation registered under that IRI. Registered functions: (none | list). An MCP
  server registers them at startup via JAYHAWK_COMPUTE_FILE, a Julia file returning a
  Dict{String,Function} keyed by function IRI; from Julia, pass `registry` to run_rule."
- `rule_catalogue` (compile.jl:3289) gains `OPTIONAL { ?r <P_COMPUTEDBY> ?fn }`;
  `tool_list_rules` prints "computed by <fn> — needs a registered implementation to run".
- `tool_explain_rule` compute branch: mode, match parts as today, the function IRI and
  whether it is registered, the SELECT text (via `compile_rule`); registered → dry-run
  triple preview as today; unregistered → row count + a sample of SELECT rows (needs no
  function) and a note that the output can't be previewed here. A reviewer always sees what
  the rule *reads*.
- `dry_run` compute branch: same scratch-graph shape as the existing one
  (harness.jl:937-960): SELECT → function → validate → chunked insert into a scratch graph →
  `prune_known!` → count + sample → DROP on every path out. Requires the function; raises
  `ComputeFunctionMissing` otherwise.

### Round 1 tests

Hermetic (`test/runtests.jl`, golden pattern of lines 166-211):
1. Golden `select_query` for a hand-built compute spec carrying a filter, a binding, a NAC
   and a mint — proves the `where_body` reuse in one byte-for-byte snapshot.
2. `compile_rule` on a compute spec emits the comment + SELECT.
3. Refusals via try/catch + `occursin(…, sprint(showerror, e))`: compute+Rewrite;
   compute+Assert; compute spec with construct triples; ToFixpoint; `load_rule`-level
   both/neither (unit-testable if the validation is factored pure, else integration);
   validation failures (BNode subject, `^^gistp:var` object, IRI failing `check_iri`,
   non-triple return).
4. Error classification: missing-registry message lists registered IRIs; a function throwing
   `MethodError` on itself → `:unmatched`; throwing `ArgumentError` → `:broken` with the
   cause visible in `showerror`.
5. `compute_insert_updates` chunking: 5 triples, chunk=2 → 3 update texts, byte-asserted.

Integration (`test/sparql_integration.jl`):
6. New fixture `test/fixtures/compute_rule.trig`: orders with line-item amounts; the
   registered function groups rows by order and returns
   `(order, ex:orderTotal, RDFLiteral(string(sum), xsd:decimal))` — the aggregation the
   compiler cannot express, summed across ALL rows (assert a total that spans several rows,
   so a per-row bug fails).
7. `run_rule(spec; source=[g], registry=…)`: assert `f.count`, `graph_size`, `ask` for the
   exact typed total, provenance carries `jayhawk:computeFunction` + ordinal, `firings()`
   shows it, `undo_firing!` reverses, and a second run prunes to zero (count 0, no litter).
8. Unregistered run refused before any write (store and provenance byte-unchanged);
   `dry_run` count matches the real run; `tool_explain_rule` works without a registry.
9. `engine_cleanup()` (sparql_integration.jl:148-205) gains the new predicate and fixture
   graphs.

**Done when:** all the above pass; both `.ttl` files validate (ttl skill / riot) and the
vocabulary repo's checks pass; CLAUDE.md "Where the work stands" and
`docs/developer-guide.md` gain a compute-bridge section (the design record is load-bearing
in this repo — update it in the same commits); the two repos' changes are committed in the
same round.

---

## Rounds 2–4 (sketches — each becomes its own plan when reached)

**Round 2 — order-independence checker.** Implement the commutation criterion already
designed at `docs/developer-guide.md:488-499`: `delta(A)` = predicates of
`match_only(A) ∪ construct_only(A)` (compile.jl:2213-2234); A and B commute iff
`delta(A) ∩ predicates(L_B) = ∅` both ways. Needs new per-rule predicate extraction over
`match_patterns(spec)` triples, `spec.nacs` triples (a guard reads) and `spec.construct`.
Soundness conventions: a variable-position predicate is ⊤ (intersects everything); a compute
rule's delta is unknowable and conservatively ⊤ — sound-but-incomplete in the safe direction.
Surface as `order_independent(specs)` returning non-commuting pairs with witness predicates,
printed by `tool_run_rules` under the resolved order, plus a standalone `check_rule_set` MCP
tool. Hermetic tests over hand-built spec pairs. Files: `src/compile.jl`, `src/mcp.jl`,
`bin/mcp_server.jl`, `docs/developer-guide.md`.

**Round 3 — weak-acyclicity termination check.** Standard chase-termination dependency graph
over (predicate, position) nodes, from Round 2's extraction: ordinary edges where a variable
bound at an L position reaches an R position; *special* edges into any R position filled by a
minted variable (slots recovered from `MintSpec` via `parse_template`, compile.jl:1257). A
cycle through a special edge means fixpoint evaluation is the chase: `check_runnable`
(harness.jl:489) warns when `jhp:maxIterations` is stated (the bound already guards it) and
refuses ToFixpoint when it is not — tightening today's Rewrite-only refusal into a principled
one for minting Assert rules. Files: `src/compile.jl`, `src/harness.jl`; hermetic tests.

**Round 4 — semi-naïve fixpoint.** The Assert loop (harness.jl:649-664) re-evaluates the
whole growing working set every round and prunes afterwards; the previous round's
firing-graph delta is already materialised and pruned. Rewrite round i>1 as a UNION of
variants of L, each constraining one triple pattern (or one match part) to read only round
i−1's delta. New `insert_query_delta(spec; into, base, delta)` beside `insert_query`, built
on `match_text` (compile.jl:1852-1891) / `where_body` / `dataset_lines` — the delta is
addressed via `GRAPH <delta>` and needs `USING NAMED <delta>` (the unscoped path currently
early-returns plain USING at compile.jl:1725). NACs keep reading the full set;
`ordered_parts`' join order (compile.jl:1815-1834) must be preserved per variant; convergence
detection is unchanged (prune-then-count). Goldens assert the delta query bytes; integration
asserts identical fixpoints and fewer per-round matches on
`test/fixtures/transitive_rule.trig` (the "Assert iterates to a least fixpoint" block,
sparql_integration.jl:317-366, is the natural regression). Files: `src/harness.jl`,
`src/compile.jl`.

---

## Backlog (recorded, deliberately deferred — keep the reasons)

- **Undo safety / single-writer guard** — nothing stops two processes interleaving ordinals
  or undoing a graph a later firing read; needs an advisory lock or ordinal-CAS refusal.
- **Provenance retention** — `urn:jayhawk:provenance` and firing graphs grow without bound; a
  retention/archival policy must never orphan a still-undoable firing.
- **Export trim (0.5.0)** — ~110 exported names (`select`, `ask`, `endpoint`, `interface`
  collide on `using`); a deliberate breaking release, already anticipated in CLAUDE.md.
- **List-valued source-map terms** — `gistp:mapFrom`, `mapFirst`, `concat`, `mapEach` (the
  last multiplies solutions → UNION over the match); all four currently refused by name.
- **ToFixpoint for compute rules** — iterating an opaque function is the chase; needs Round
  3's machinery plus a convergence contract.
- **Write destination for compute rules** — no construct pattern to hang `jhp:inGraph` on;
  needs a vocabulary decision before promotion/undo-from-destination can apply.

## Verification (every round)

1. `julia --project=. test/runtests.jl` (hermetic) — or the `jl-test` skill.
2. `./bin/fuseki-test.sh start`, then
   `JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl`.
3. Behavioral fixes: confirm the proof test fails on pre-fix code before committing the fix.
4. Vocabulary edits: `ttl` skill validation on both files; semantic diff before committing
   (Protégé-style reordering makes raw diffs unreadable; the user requires reading every
   .ttl diff as a triple diff).
5. Keep CLAUDE.md and `docs/developer-guide.md` in step in the same commits.
