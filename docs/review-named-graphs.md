# Adversarial review — `named-graphs` branch (`gistp:inGraph`, round 5a)

Second-pair review of the in-progress named-graph work.
Date: 2026-08-17. Base commit `c7ddada`.
Diff reviewed: `src/compile.jl`, `src/harness.jl`, `src/mcp.jl`, `test/runtests.jl`,
`test/sparql_integration.jl`, `test/fixtures/scoped_rule.trig` (untracked).

**Baseline measured before criticising anything:** `test/runtests.jl` 186/186 pure +
subsuites green; `JAYHAWK_TEST_SPARQL=1 test/sparql_integration.jl` 223/223 green against
Fuseki on `localhost:3040`. Nothing below is a failing test on the branch — every finding is
outside the envelope the new tests cover.

---

## 1. What the change does, and what it gets right

`gistp:inGraph` on a pattern (L, R, or a NAC) names the graph that pattern is evaluated in:
either a declared `gistp:SparqlVariable` (a *graph variable*) or a constant graph IRI.

- `load_in_graph/1` reads it from the **default** graph — it is a statement *about* the
  pattern, not part of it.
- `_occurs_in` grew a fourth alternative so a graph variable, which occupies no S/P/O position
  anywhere, is still discovered by `load_variables`.
- `where_body` wraps only `bgp_text(spec.match)` in `GRAPH ?g { … }`; VALUES/BIND/FILTER stay
  outside; each NAC wraps its own triples inside its own `FILTER NOT EXISTS`.
- `dataset_lines` emits `USING` **and** `USING NAMED` (or `FROM`/`FROM NAMED`) for a scoped
  rule; unscoped rules early-return to byte-identical old output.
- `check_scopes` refuses `construct_scope` and refuses `Rewrite` + scope.
- `run_rule` refuses scoped + empty `source`, and scoped + `:ToFixpoint`.

**The hard part is right.** Wrapping the triples rather than the finished group, and keeping
each NAC's `GRAPH` *outside* L's group, is the non-obvious call — nesting it would silently
re-quantify `?g` over every named graph and turn "not in THIS graph" into "not in ANY graph".
The integration test at `sparql_integration.jl:846` proves exactly the row that distinguishes
them (`ex:s2` declined in book A, allowed in book B). That is measured, not argued, and it is
the right thing to have measured.

Emitting both `USING` and `USING NAMED` is also correct and worth the paragraph it got — they
are disjoint namespaces and either alone silently empties half the query.

The findings below are all at the edges of that correct core. Most share one shape: **a guard
that exists in one code path and not in its siblings.**

---

## 2. Findings

Severity is about *silence*, not about blast radius: a wrong answer nobody can see is worse
than a crash.

### F1 — HIGH — `run_rule`'s empty-`source` guard is the only one, and it is not on the path most callers take

`run_rule` refuses a scoped rule with an empty `source`, with a good explanation. But the
guard is in the driver, while the hazard is in the query builder. `apply_rule`, `dry_run`,
`dry_run_rewrite`, `check_collisions` and `mint_fanin` are all public, all exported, and all
reach `dataset_lines(spec, [])` → `""` → no dataset clause → `GRAPH ?_Book` enumerating every
named graph in the store.

Measured, against the branch's own fixture:

```
run_rule(spec; source = []) → ArgumentError            (guard works)

dry_run(spec)               → count = 4
    <bk/s1>          heldIn <urn:jayhawk:test:bookA>
    <bk/s2>          heldIn <urn:jayhawk:test:bookB>
    <bk/s3>          heldIn <urn:jayhawk:test:bookB>
    <bkrules/_Sec>   heldIn <bkrules/PerBook_L>     ← the rule's own pattern graph, as data
```

The honest answer is 3. The fourth row matched inside `<…/PerBook_L>`, because the pattern
graph literally contains `:_Sec rdf:type ex:Security` — so a scoped rule with no dataset
clause reads *the rule catalogue itself* as business data. Provenance and every prior firing
and tombstone are in range too.

`apply_rule(spec)` is worse than `dry_run`, because it persists:

```
apply_rule(spec)  → firing <urn:jayhawk:firing:8787cca5-…>, count = 4
                    including <bkrules/_Sec> heldIn <bkrules/PerBook_L>
                    provenance rows 0 → 1, recorded as a legitimate firing
```

And it is reachable from the MCP review surface with no argument at all —
`tool_explain_rule(rule)` defaults `source` to `String[]` and prints
`dry run against the default graph would add 4 new triple(s)`. The reviewer's own
double-check is the thing showing them the fabricated row.

**Note the test that certifies the hole.** `test/runtests.jl:1732`:

```julia
@test dataset_lines(scoped, String[]) == ""      # nothing to name, nothing emitted
```

That assertion is currently pinning the bug in place. It should become `@test_throws`.

**Fix.** Move the guard to the choke point every builder already goes through:

```julia
function dataset_lines(spec::RuleSpec, from::AbstractVector; keyword::AbstractString = "USING")
    if isempty(from)
        is_scoped(spec) && error(
            "rule <$(spec.iri)>: gistp:inGraph needs an explicit graph set. With no dataset " *
            "clause a graph variable ranges over every named graph in the store -- " *
            "<$PROVENANCE_GRAPH>, every firing, every tombstone, and the rule's own pattern " *
            "graphs. An empty graph set is not 'the default graph' here, it is everything.")
        return ""
    end
    plain = join(("$keyword <$(check_iri(g))>" for g in from), "\n")
    is_scoped(spec) || return plain * "\n"
    plain * "\n" * join(("$keyword NAMED <$(check_iri(g))>" for g in from), "\n") * "\n"
end
```

One edit covers `insert_query`, `project_query`, `rewrite_query`, `collision_queries` and
`mint_fanin`, and therefore `dry_run`, `apply_rule`, `dry_run_rewrite`, `check_collisions`
and `tool_explain_rule`. Keep `run_rule`'s `ArgumentError` — it fires earlier and reads
better; it just stops being the only thing standing there.

### F2 — HIGH — `mint_fanin` and `collision_queries` build an *unscoped* match for a scoped rule

Both call `bgp_text(spec.match, spec)` directly instead of going through the scoping that
`where_body` applies. The rule that runs and the rule these two safety checks interrogate are
then different rules.

Measured on a scoped minting rule over the two books (guard removed so `ex:s2` appears in
both):

```
truth, from the rule as it actually runs:
    hold/…s1 heldIn bookA
    hold/…s2 heldIn bookA
    hold/…s2 heldIn bookB     ← one minted IRI, two book contexts: real fan-in
    hold/…s3 heldIn bookB

mint_fanin reports: NOTHING
```

Because the SELECT it builds is:

```sparql
SELECT ?_Hold (COUNT(DISTINCT ?__ctx) AS ?n)
FROM <…bookA>  FROM <…bookB>  FROM NAMED <…bookA>  FROM NAMED <…bookB>
WHERE {
  ?_Sec a <…/Security> .                                    ← no GRAPH ?_Book
  BIND(IRI(CONCAT("http://example.org/hold/", ENCODE_FOR_URI(STR(?_Sec)))) AS ?_Hold)
  BIND(CONCAT(ENCODE_FOR_URI(STR(?_Book))) AS ?__ctx)       ← ?_Book is UNBOUND
}
GROUP BY ?_Hold HAVING (COUNT(DISTINCT ?__ctx) > 1)
```

`?_Book` is never bound, so `CONCAT` yields unbound, `?__ctx` is unbound, the count is 0 and
`HAVING > 1` can never be true. The report is silently empty *by construction* for every
scoped rule whose R mentions its graph variable — which is the entire provenance use case the
feature exists for.

Two further consequences of the same divergence:

- `nacs_text(spec)` is spliced into both queries, so a **scoped NAC** lands in a query where
  its graph variable is unbound — the "in ANY graph" reading (see F4) — over-filtering the
  collision and fan-in checks even when the graph variable is otherwise irrelevant.
- `collision_queries` is vacuous today (`check_collisions` skips unless
  `ambiguous_separators` is non-empty), so this is latent there rather than live. It stops
  being latent the moment a lossy encoding lands — which is the exact scenario its docstring
  says it is kept alive for.

**Fix.** Make the scoping decision once, the same way `graph_wrap` already centralises the
variable-vs-constant decision:

```julia
"L's triples, scoped by gistp:inGraph if it has one. The one place that decision is made."
match_text(spec::RuleSpec; indent::AbstractString = "  ") =
    spec.match_scope === nothing ?
        bgp_text(spec.match, spec; indent = indent) :
        graph_wrap(bgp_text(spec.match, spec; indent = indent * "  "),
                   spec.match_scope, spec; indent = indent)
```

Then `where_body`, `collision_queries` and `mint_fanin` all call `match_text(spec)`. Unscoped
output is byte-identical, so the golden snapshot holds. This removes the divergence by
construction rather than by remembering to keep three call sites in step.

### F3 — MEDIUM — a NAC's graph variable is never required to be bound by L

`check_scopes` accepts any NAC scope that is either a declared variable or a legal IRI. It
never checks that a NAC's *graph variable* is one L actually binds. An unbound one compiles
clean and silently means "in ANY graph" — the precise failure `where_body`'s docstring warns
about for the nesting case, reappearing one level up.

Measured — same fixture, NAC scoped to `?_Other` instead of `?_Book`:

```
compiles without complaint: true
  GRAPH ?_Book  { ?_Sec a ex:Security }
  FILTER NOT EXISTS { GRAPH ?_Other { ?_Sec a ex:Tagged } }     ← ?_Other unbound

result:  s1→bookA, s3→bookB
correct: s1→bookA, s2→bookB, s3→bookB
```

`ex:s2` is silently dropped — it is Tagged in book A, so "tagged in *any* graph" declines it
everywhere. That is the exact row the integration test was written to protect, lost through a
different door.

The asymmetry is worth stating in the code, because it is not obvious: a NAC's **triples**
may legitimately introduce fresh existential variables (that is what a guard is for), but a
NAC's **graph** may not, because an unbound graph re-quantifies the whole condition.

**Fix.** In `check_bound`, after `matched` is computed:

```julia
for n in spec.nacs
    n.scope === nothing && continue
    sv = scope_vars(n.scope, spec)
    isempty(sv) && continue                      # a constant graph is always fine
    issubset(sv, matched) || error(
        "rule <$(spec.iri)>: negative condition <$(n.graph)> is scoped to " *
        "$(first(sv)), which the match pattern does not bind. A condition's triples may " *
        "introduce fresh variables -- that is what a guard is -- but its *graph* may not: " *
        "an unbound graph variable re-quantifies the whole condition, turning 'no such " *
        "thing in THIS graph' into 'no such thing in ANY graph', which drops solutions " *
        "with no error. Scope it to the graph variable L binds, or name a constant graph.")
end
```

### F4 — MEDIUM — `compile_rule` emits no dataset clause, so the reviewed text is not the executed text

`compile_rule(spec)` on a scoped rule contains neither `FROM` nor `USING` (measured). It is
what `tool_explain_rule` prints under "compiles to:", so a reviewer approves a `CONSTRUCT`
whose `GRAPH ?_Book` is unbounded, while what runs is an `INSERT … USING … USING NAMED …`.
Copy that text into a query console and you get F1's answer, not the rule's.

`test/fixtures/scoped_rule.trig`'s own worked example shows the discrepancy from the other
side — it documents the output as:

```sparql
CONSTRUCT { ?_Sec ex:heldIn ?_Book . }
USING <urn:jayhawk:test:bookA>
```

which the compiler does not emit and which is not legal SPARQL in any case: `CONSTRUCT` takes
`FROM`, only Update takes `USING`. Since this file is a teaching artifact for the feature, the
error will be copied.

**Fix.** Thread an optional graph set through: `compile_rule(spec; from = String[])` splicing
`dataset_lines(spec, from; keyword = "FROM")` after the `CONSTRUCT` block. Unscoped + empty
`from` keeps today's bytes exactly; scoped + empty inherits F1's refusal. Then have
`tool_explain_rule` pass its `source` through, so the reviewer reads the query that will run.
And correct the fixture comment to `FROM` / `FROM NAMED`.

### F5 — LOW — `check_mints` refuses a graph variable as a slot value, and misdiagnoses it

`check_mints` computes `bound = union(vars_in(spec.match, spec), enum_vars(spec))` and was not
updated with `scope_vars`, so it disagrees with `check_bound`, which now counts L's graph
variable as bound. Minting one node per book — an obvious thing to want from this feature —
is refused, and refused with a wrong reason:

```
slot {bk} of <…/_Hold> is bound to ?_Book, which the match pattern never binds.
Minting from another minted variable is not supported.
```

`?_Book` is not another minted variable, and L does bind it. An author will go looking for a
problem that is not there.

**Fix.** Either add `scope_vars(spec.match_scope, spec)` to `bound` — but **only after F2**,
since allowing it while `collision_queries` is unscoped would have the collision check read an
unbound variable — or keep refusing and give the real reason. Do not leave the current
message.

### F6 — LOW — an `inGraph` object that fails to resolve degrades silently to a constant graph

Observed live, from stale store state during this review: with `spec.variables` empty,
`graph_wrap` emitted `GRAPH <http://example.org/bkrules/_Book>` — a constant naming a graph
nobody ever created — and `check_bound`, `compile_rule` and `dry_run` all reported success
with `count = 0`. This is the failure the `_occurs_in` docstring describes ("compile,
validate, run, and match nothing, with no error anywhere"); the new fourth alternative
prevents the *known* cause, but nothing detects the *symptom*, so any future cause is equally
silent.

**Fix (cheap, load-time, where a server is available).** In `load_rule`, after the spec is
built: for each scope that is not in `variables`, `ASK { <scope> a gistp:SparqlVariable }` — if
true, the variable was declared but not discovered, which is an internal inconsistency worth
erroring on rather than compiling around.

### F7 — INFO — guard-ordering nit

`is_scoped` is true when only `construct_scope` is set, so `run_rule(spec; source = [])` on
such a rule reports "must name its graphs in `source`" — when the real answer, which
`check_scopes` would have given a moment later, is that writing into a named graph is not
supported at all. Harmless, mildly misleading.

---

## 3. Things I tried to break and could not

Worth recording so the next reviewer does not re-spend the time:

- **`USING <g>` + `USING NAMED <g>` on the same graph.** Legal, and Fuseki handles it as the
  design note claims. No duplicate solutions; the scoped and unscoped halves of one rule do
  join correctly across the two.
- **Injection through a graph-position `variableText`.** `graph_wrap` routes through
  `spec.variables`, so `check_variables` covers graph position like every other. A constant
  scope goes through `check_iri`. Both are tested on the branch and both hold.
- **`Rewrite` + scope, and `construct_scope`.** Genuinely refused, on every path I could find
  including `dry_run_rewrite` → `project_query` → `check_bound`.
- **`:ToFixpoint` + scope.** Refused in `run_rule`, and `apply_rule` is not a loop driver on
  its own, so unlike F1 this guard is in the right place.
- **Fixture load determinism.** 5/5 clean wipe-and-load cycles produce both variables. The
  one anomaly I hit early was stale store state, not a loader bug.

---

## 4. Suggested order of work

1. **F1** — one function, biggest silence, and it closes the MCP-reachable path.
2. **F2** — `match_text` helper; fixes the live `mint_fanin` bug and the latent
   `collision_queries` one together.
3. **F3** — NAC scope binding check; same class of silent wrong answer the feature's
   headline test defends against.
4. **F4** — makes the reviewed text the executed text; fix the fixture comment with it.
5. **F5** after F2, **F6**, **F7** as tidying.

F1 and F2 are each a handful of lines and both are pure-layer, so they are cheap to land with
tests. The existing assertion at `test/runtests.jl:1732` has to flip to `@test_throws` as part
of F1 — it is currently asserting the defect.

---

## 5. Method

Everything above was reproduced against a live Fuseki (`localhost:3040/jayhawk`) using the
branch's own `test/fixtures/scoped_rule.trig`, not reasoned from the source. Scratch scripts
lived in the session scratchpad; the store was left as found (all firings undone, `bookA` /
`bookB` dropped).
