# Jayhawk User Guide

*Also published as a web page: [Rules You Can Draw](https://claude.ai/code/artifact/387c189b-0e2a-4546-a6da-cc166369088d). This file is the source of truth.*

Jayhawk turns **RDF graph patterns into functions that take a graph and produce a graph**.

A rule is two pictures: what must be true (**L**), and what becomes true (**R**). Both are
ordinary RDF, held in named graphs. Jayhawk compiles them to SPARQL, runs them against a
triplestore, records what happened, and can undo it.

You never write SPARQL. You draw the situation.

---

## 1. Setup

You need Julia 1.10+, a checkout of Jayhawk, and Apache Jena Fuseki.

```bash
cd ~/dev/Jayhawk
./bin/fuseki-test.sh start               # in-memory Fuseki on :3040/jayhawk
julia --project=. -e 'using Jayhawk'
```

The engine talks to `http://localhost:3040/jayhawk` by default. Point it elsewhere with
`JAYHAWK_SPARQL_SERVICE` before Julia starts, or at runtime:

```julia
set_endpoint!("http://my-store:3030/production")
```

**Jena parses your RDF, not Julia.** Files go into the store over the Graph Store Protocol
and come back as SPARQL results. That is why TriG, blank nodes, datatypes and namespaces all
behave the way your triplestore says they do.

---

## 2. Your first rule

A rule needs three graphs' worth of information: the rule declaration and its variables in
the **default graph**, the match pattern **L**, and the construct pattern **R**. Because L
and R are named graphs, rules are written in **TriG**, not Turtle.

Here is the whole of `examples/moneygraph/01-classify-bond.trig`, minus its prefixes:

```turtle
:ClassifyBond
    rdf:type gistp:Rule ;
    gistp:hasMatchPattern     :ClassifyBond_L ;
    gistp:hasConstructPattern :ClassifyBond_R ;
    gistp:rewriteMode         gistp:Assert .

:ClassifyBond_L rdf:type gistp:SparqlPattern .
:ClassifyBond_R rdf:type gistp:SparqlPattern .

:_Sec rdf:type gist:FinancialInstrument , gistp:SparqlVariable ;
      gistp:variableText "?_Sec" .

:ClassifyBond_L {
    :_Sec rdf:type gist:FinancialInstrument ;
          mg:couponRate   "?rate"^^gistp:var ;
          mg:maturityDate "?maturity"^^gistp:var .
}

:ClassifyBond_R {
    :_Sec rdf:type mg:Bond .
}
```

Three things are worth pausing on.

**A pattern *is* its graph.** `:ClassifyBond_L` names both the pattern and the graph holding
its triples. There is no membership property, and no need to separate payload from metadata:
everything inside the graph is pattern.

**There are two ways to write a variable.** `:_Sec` is a declared individual — an ordinary
IRI, typed both `gist:FinancialInstrument` *and* `gistp:SparqlVariable`. That double typing
is deliberate: the pattern is simultaneously a placeholder and valid instance data, so your
domain's own SHACL shapes can validate it. In *literal* position you write `"?rate"^^gistp:var`
instead, because a literal position must hold a literal.

**The mode is explicit.** `gistp:Assert` means "add these facts." It is never inferred.

### Load and run it

```julia
using Jayhawk
D = "urn:jayhawk:example:moneygraph"

load_file!("examples/moneygraph/data.trig")
load_file!("examples/moneygraph/01-classify-bond.trig")

fs = run_rule("https://w3id.org/moneygraph/ns/rules/ClassifyBond";
              source = [D], actor = "doug")
```

```
ClassifyBond -> 2 triple(s)
   mg3:T4875   a mg:Bond
   mg3:IBM2029 a mg:Bond
```

*Every output block in this guide is abridged the same way: the engine works in absolute
IRIs and prints them in full, so `mg3:T4875` stands for
`<https://w3id.org/moneygraph/ns/data/T4875>`. The triples themselves are the measured ones —
`test/sparql_integration.jl` asserts them.*

`mg3:AAPL` has no coupon rate, so L never reached it. That is the whole of the logic: a rule
does not need an `if`, because a pattern that does not match does not fire.

### Look before you leap

`explain_rule` shows the compiled SPARQL *and* a dry run of the facts the rule would create,
against your real data, writing nothing:

```julia
print(tool_explain_rule("…/ClassifyBond"; source = [D]))
```

```
Rule <…/ClassifyBond>
  mode              : Assert
  match pattern L   : <…/ClassifyBond_L> (3 triples)
  construct pattern R: <…/ClassifyBond_R> (1 triples)
  variables bound by L: ?_Sec, ?maturity, ?rate
  strategy          : ToFixpoint  (default for Assert)
  iteration budget  : 100  (default)
  guards            : none -- this rule fires on every match

compiles to:
  CONSTRUCT { ?_Sec a mg:Bond . }
  WHERE     { ?_Sec a gist:FinancialInstrument ;
                    mg:couponRate ?rate ; mg:maturityDate ?maturity . }

dry run against <urn:…:moneygraph> would add 2 new triple(s):
    mg3:IBM2029 a mg:Bond .
    mg3:T4875   a mg:Bond .

Nothing was written. Use run_rule to apply it.
```

**Read the dry run, not the SPARQL.** The facts a rule creates are reviewable by anyone who
understands the business; the query text is not.

---

## 3. The three modes

| Mode | Result | Use it for |
|---|---|---|
| `gistp:Construct` | `f(G)` — the construct pattern alone | reports, migrations, anything where the answer is separate from the input |
| `gistp:Assert` | `G ∪ f(G)`, iterated to a fixpoint | classification, derivation, transitive closure |
| `gistp:Rewrite` | `DELETE { L∖I } INSERT { R∖I }` | correcting, retiring, state transitions |

`Construct` and `Assert` compile to **identical SPARQL**. The difference is entirely in how
often it runs and what is done with the answer.

---

## 4. Creating nodes that did not exist

Classification only describes things that are already there. To *create* one, give a variable
a `gistp:iriTemplate`:

```turtle
:_Event rdf:type mg:CouponPaymentEvent , gistp:SparqlVariable ;
        gistp:variableText "?_Event" ;
        gistp:iriTemplate  "https://w3id.org/moneygraph/ns/data/coupon/{bond}" ;
        gistp:hasSlot [ rdf:type gistp:TemplateSlot ;
                        gistp:slotName  "bond" ;
                        gistp:slotValue "?ticker"^^gistp:var ] .
```

**Carrying a template is what makes a variable minted rather than matched**, so it must not
appear in L. It appears in R, which is what constructing it means.

Slots bind by RDF identity, never by the slot name happening to match a variable's name.
`{bond}` is bound to `?ticker` because `gistp:slotValue` says so.

The template must expand to an **absolute IRI**, and it uses RFC 6570 Level 1 — which is
exactly SPARQL's `ENCODE_FOR_URI`, so it compiles to:

```sparql
BIND(IRI(CONCAT("https://…/coupon/", ENCODE_FOR_URI(STR(?ticker)))) AS ?_Event)
```

> ### Mint from identifiers, never from free text
>
> An earlier draft of this example minted from `gist:name`. It produced
> `…/coupon/IBM%203.30%25%20of%202029` — correct, legal, and unreadable. `ENCODE_FOR_URI`
> percent-encodes; it does not tidy. Bind slots to tickers, codes and IDs.

Because the expansion is a pure function of the bindings, re-running mints **byte-identical
IRIs**. That is what lets an `Assert` rule converge instead of growing forever.

---

## 5. Guards: when a rule must *not* fire

A rule with no guard fires on every match, every time. `gistp:hasNegativeCondition` names a
pattern that must **not** match:

```turtle
:MintCouponEvent
    gistp:hasNegativeCondition :MintCouponEvent_NoEventYet .

:MintCouponEvent_NoEventYet rdf:type gistp:SparqlPattern .    # a guard is a pattern like any other

:MintCouponEvent_NoEventYet {
    :_Event rdf:type mg:CouponPaymentEvent .
}
```

Note what the guard is about: `:_Event`, the variable being **created**. That is legal
because the guard compiles to a `FILTER NOT EXISTS` emitted *after* the `BIND` that
constructs it. It reads as "only create this if it is not already there."

Running it on the example data:

```
MintCouponEvent -> 2 triple(s)
   mg3:coupon/T4875 a mg:CouponPaymentEvent
   mg3:coupon/T4875 gist:isAbout mg3:T4875
```

Only `T4875`. `IBM2029` already had an event, so the guard declined the whole match. Zero or
more guards are allowed, and all of them must fail for the rule to fire.

A guard is a Basic Graph Pattern like any other pattern: no `FILTER`, no `OPTIONAL`, no
`UNION`. So *"no **other** security refers to this"* — which needs an inequality — is not
expressible. *"No `mg:Exchange` refers to this"* is, because the distinguishing test is a
type assertion.

---

## 6. How often a rule runs

A guard says *whether* a rule fires. Three more properties say *how often*, and they are the
difference between a rule that stops because somebody decided it should and one that merely
happens to.

```turtle
:MintCouponEvent
    gistp:strategy      gistp:ToFixpoint ;
    gistp:maxIterations 5 ;
    gistp:priority      50 .
```

| Property | Values | Default |
|---|---|---|
| `gistp:strategy` | `gistp:Once`, `gistp:ToFixpoint` | `ToFixpoint` for `Assert`, `Once` for everything else |
| `gistp:maxIterations` | a positive integer | 100 |
| `gistp:priority` | an integer | 0 |

**`ToFixpoint` re-runs until a pass changes nothing.** Each round's output joins the working
set, so the next round sees it — that is how transitive closure works, and it is why a
fixpoint run needs an explicit `source`: SPARQL's `USING` cannot name the store's default
graph, so the working set has to be named graphs.

**The budget is a hard stop, not a hint.** Exceed it and the run *fails* rather than
returning a half-finished graph. If that happens, the usual cause is minting inside a
fixpoint: `gistp:iriTemplate` invents terms, which turns fixpoint evaluation into the chase,
and the chase need not terminate. A guard on the minted variable — §5 — is the fix, because
then the second round declines what the first created.

Strategy and budget are both overridable per call, which is the right place for a one-off:

```julia
run_rule(rule; source = [D], strategy = :Once)
run_rule(rule; source = [D], max_iterations = 1000)
```

One combination is refused outright: a **`Rewrite` run to a fixpoint with no guard and no
stated budget**. A deleting rule has nothing to tell it when it is done, so falling back to
100 destructive passes is not a decision the engine will make on your behalf.

`gistp:priority` is loaded, validated and shown by `explain_rule`, but nothing acts on it
yet — `run_rule` takes one rule at a time. It is there so rule sets can be ordered when
`run_rules` lands; record your intent now and it will be honoured later.

---

## 7. Enumerations: one clause, two readings

`gistp:oneOf` fixes a variable to a list of values:

```turtle
:_Exch rdf:type mg:Exchange , gistp:SparqlVariable ;
       gistp:variableText "?_Exch" ;
       gistp:oneOf ( mg3:NASDAQ mg3:NYSE ) .
```

It compiles to a SPARQL `VALUES` clause — and **which of two things it means is decided by
the rest of the rule, not by the vocabulary**:

- if L **also** binds the variable, the clause is a join, and it **constrains**;
- if the variable appears **only** in R, the clause multiplies solutions, and it
  **generates** — one copy of the template per value, a coproduct.

In `03-domestic-listing.trig`, `:_Exch` is bound by L, so it constrains:

```
DomesticListing -> 2 triple(s)
   mg3:AAPL mgx:isDomesticallyListed mg3:NASDAQ
   mg3:ENRN mgx:isDomesticallyListed mg3:NYSE
```

`mg3:NESN` is listed on `mg3:SIX`, which is not in the list, so it is excluded. Delete
`mg:isListedOn :_Exch` from L and the same rule would instead produce a row per exchange for
every security — parameterised graph generation, with no extra vocabulary.

---

## 8. Named graphs: which graph a fact lives in

Everything so far treats the working set as one pile of triples. `source` names graphs, but
they are merged before L ever runs, so a pattern cannot tell which graph anything came from.

`gistp:inGraph` scopes a **pattern** to a graph:

```turtle
:PerBook_L     rdf:type gistp:SparqlPattern ; gistp:inGraph :_Book .
:PerBook_NoTag rdf:type gistp:SparqlPattern ; gistp:inGraph :_Book .
:PerBook_R     rdf:type gistp:SparqlPattern .

:_Book rdf:type gistp:SparqlVariable ; gistp:variableText "?_Book" .

:PerBook_L     { :_Sec rdf:type ex:Security . }
:PerBook_R     { :_Sec ex:heldIn :_Book . }
:PerBook_NoTag { :_Sec rdf:type ex:Tagged . }
```

**The value reads two ways, and which one you get depends on what it is** — the same economy
as `oneOf`. A declared `gistp:SparqlVariable` is a *graph variable*: it binds whichever graph
each match came from, and R can then use it as an ordinary term. Any other IRI is a constant,
and restricts the pattern to that one graph.

Over two books that share a security:

```
<urn:book:A> { ex:s1 a ex:Security . ex:s2 a ex:Security , ex:Tagged . }
<urn:book:B> { ex:s2 a ex:Security .  ex:s3 a ex:Security . }
```

```
PerBook -> 3 triple(s)
   ex:s1 ex:heldIn <urn:book:A>
   ex:s2 ex:heldIn <urn:book:B>
   ex:s3 ex:heldIn <urn:book:B>
```

`ex:s2` is the row worth staring at. It is Tagged in book A and untagged in book B, so the
guard declines it in A and allows it in B. **A guard scoped to `?_Book` means "not in *this*
book", not "not in any book"** — which is the whole reason to scope a guard at all.

**A scope is a property of the pattern, not of a triple.** TriG cannot nest a `GRAPH` inside a
graph, so one pattern is all-scoped or all-unscoped. A rule needing both writes two patterns.

### What this round does not do

Four things are refused rather than approximated, each with a message naming the fix:

| Refused | Why |
|---|---|
| `inGraph` on **R** | Writing into a named graph needs undo to record which graph each triple went to. Until it does, an irreversible write is not something to get by default. |
| `inGraph` with **`gistp:Rewrite`** | A rewrite deletes from exactly one target; a scoped match can bind several, so target, tombstone and undo record would each have to become a set. |
| `inGraph` with **`ToFixpoint`** | Each round appends its firing graph to the working set, so round two would bind that firing as a graph to match in. |
| `inGraph` with an empty **`source`** | With no dataset clause a graph variable ranges over *every* named graph in the store — provenance and every tombstone included. That is not "the default graph", it is everything. |

So results still land in a firing graph, and you merge them where you want them. Per-graph
write-back is the next increment.

---

## 9. Rewriting: taking facts away

`gistp:Rewrite` is the only mode that deletes. What survives is **I**, the interface, and
**I is authored by repetition**: whatever you want preserved, you write into *both* graphs.

```turtle
:RetireListing_L {
    :_Sec rdf:type gist:FinancialInstrument ;
          mg:isListedOn  :_Exch ;
          mgx:delistedOn "?when"^^gistp:var .
}

:RetireListing_R {
    :_Sec rdf:type gist:FinancialInstrument ;      # repeated -> preserved
          mgx:delistedOn        "?when"^^gistp:var ;   # repeated -> preserved
          mgx:formerlyListedOn  :_Exch .               # new
}
```

```
    I     = { type, delistedOn }            preserved
    L ∖ I = { mg:isListedOn }               deleted
    R ∖ I = { mgx:formerlyListedOn }        added
```

Drop the repetition and the rule would strip the instrument of its type on the way past.
**That** is why the mode cannot be inferred from which triples happen to repeat: repetition
decides I, the mode decides what happens to `L ∖ I`.

Running it:

```
RetireListing -> 1 added, 1 removed
   REMOVED  mg3:ENRN mg:isListedOn         mg3:NYSE
   ADDED    mg3:ENRN mgx:formerlyListedOn  mg3:NYSE
   undo restores exactly: true
```

Three safeguards apply to rewrites and only to rewrites:

- **exactly one source graph**, because a deletion has to name what it deletes from;
- **`confirm = true`** over MCP, because a destructive default is the wrong one to hand a model;
- **a tombstone graph**, written in the same atomic update, so undo can put back what was removed.

### Dangling references

SPARQL Update performs no dangling check. If a rule deletes every triple the pattern knows
about for some node, and never mentions that node in R, anything *outside* the pattern still
pointing at it is left referring to nothing. Jayhawk reports this rather than refusing it —
stripping a node is sometimes the intent — and `explain_rule` shows the warning before you
run anything.

---

## 10. Provenance and undo

Every application writes into its **own named graph** and records a provenance entry.

```julia
firings()
```

```
(graph = "urn:jayhawk:firing:7871b9af-…", rule = "…/RetireListing",
 at = "2026-08-15T21:58:03Z", count = 1, actor = "doug", iteration = 1, removed = 1,
 tombstone = "urn:jayhawk:tombstone:…")
```

```julia
undo_firing!("urn:jayhawk:firing:7871b9af-…")
```

For an additive rule that is a `DROP GRAPH`. For a rewrite it also replays the tombstone, so
the result is an exact inverse — verified on the example above.

`undo_firing!` refuses any graph without a provenance record. It reverses firings, and
nothing else; it is not a general graph delete.

---

## 11. Driving it from an agent

```bash
julia --project=bin -e 'using Pkg; Pkg.instantiate()'
julia --project=bin bin/mcp_server.jl
```

Five tools: `list_rules`, `explain_rule`, `run_rule`, `undo_firing`, `list_firings`.

The design point that matters more than the code: **rules are the tools, not SPARQL.** No
enterprise will hand a model an unrestricted UPDATE endpoint, and it would be right not to.
A catalogue of named, validated, provenance-stamped, reversible rewrites is a different
proposition — every operation is one somebody wrote and reviewed.

---

## 12. When a rule is refused

Jayhawk would rather refuse a rule than compile it into something that quietly misbehaves.
Each message names the fix.

| Message | What happened |
|---|---|
| *uses `?x` which the match pattern never binds* | A typo, usually — literal-position variables are matched across L and R by string equality, so `?idtext` and `?idText` are different variables. |
| *contains N blank node(s)* | A blank node is an undeclared variable. It cannot carry `oneOf` or a template, does not connect L to R, and is illegal in a `DELETE`. The message prints the declarations to paste. |
| *iriTemplate … is relative* | Templates expand to absolute IRIs. A bare local part mints into whatever namespace the rule file's empty prefix happens to name. |
| *separates slots with `"_"`* | `ENCODE_FOR_URI` leaves `-._~` alone, so `"x_y"+"z"` and `"x"+"y_z"` both give `x_y_z` — two different things merged into one node. Use `/`. |
| *carries a template, which declares it minted, but the match pattern also binds it* | A variable is either constructed or matched. |
| *gistp:Rewrite needs exactly one source graph* | "Delete from the union of these three" is neither expressible nor reviewable. |
| *still changing the graph after N iterations* | A fixpoint did not converge. Usually IRI minting from a value the rule itself derives. |
| *running to a fixpoint needs an explicit `source`* | Each round has to see the previous round's output, and SPARQL's `USING` cannot name the store's default graph. Load the data into a named graph, or apply the rule `Once`. |
| *a gistp:Rewrite run to a fixpoint with no gistp:hasNegativeCondition must state a bound* | A deleting rule has nothing to say when it is done. Add a guard or a `gistp:maxIterations`. |
| *no rule found at `<…>`* | The IRI is wrong, or the rule's three declarations are not in the **default** graph. A rule that lives inside a named graph is invisible to `load_rule`. |
| *gistp:inGraph must name a graph by IRI* | A graph name is an IRI. There is no `"?g"^^gistp:var` reading as there is for `gistp:slotValue` — no literal can name a graph. |
| *a rule with gistp:inGraph must name its graphs in `source`* | A graph variable with no dataset clause ranges over every named graph in the store, provenance included. |

---

## Where to go next

- `examples/moneygraph/` — the four rules above, runnable, and exercised by the test suite
  so this guide cannot drift from the engine.
- `docs/developer-guide.md` — how the compiler works and how to extend it
  ([web version](https://claude.ai/code/artifact/2ccf34ca-2b5e-4b39-bcb2-c983678008c6)).
- `~/dev/gistPatterns` — the pattern vocabulary itself, its SHACL shapes, and `verify.py`.
