# The Jayhawk User Guide

*Rules you can draw, run, and take back.*

*Also published as a web page: [Rules You Can Draw](https://claude.ai/code/artifact/387c189b-0e2a-4546-a6da-cc166369088d).
**This file is the source of truth**; the page is generated from it with
`pandoc -f gfm -t html --no-highlight docs/user-guide.md` inside a styled wrapper.*

---

## 1. Why this exists

Every enterprise runs on rules. A security with a coupon rate and a maturity date is a bond.
A delisted security's listing becomes a former listing. An employee with a manager is in that
manager's org. Nobody disputes these. They are the ordinary sentences a business says about
itself.

Then look at where those sentences actually live. One is a `CASE` statement in a stored
procedure. One is a nightly ETL job. One is three hundred lines of Java in a service nobody
has opened since the person who wrote it left. One is in a spreadsheet. The *sentence* is
simple; the *implementation* is scattered across a dozen systems in a dozen languages, and no
two agree.

That is not a hard problem that got a hard solution. That is a simple problem that got
buried. The rule "a bond is an instrument with a coupon rate and a maturity date" is not
complicated. Everything around it is.

Jayhawk takes the position that the rule should be **data**, not code. You write down the
situation that must hold, and the situation that should follow. Both are ordinary RDF. The
engine turns that into SPARQL and runs it against your triplestore.

You do not write SPARQL. You draw the before and the after.

Three things follow from that, and they are the reason to bother:

**A rule is readable by the people who own it.** A business analyst can read the picture. They
cannot read the stored procedure. If the person who understands the rule cannot check the
rule, you do not really have a rule — you have a hope.

**A rule is one thing, in one place.** Not a copy in the warehouse and another in the API.
When the definition of "bond" changes, it changes once.

**A rule leaves a record.** Every application writes into its own graph with a provenance
entry saying which rule ran, when, on whose authority, and what it produced. You can list
what happened. You can undo it exactly. Try that with the nightly ETL.

The store does the heavy lifting. Matching, joining, and atomicity come from Jena — the
engine does not reimplement any of it. A SPARQL `DELETE {L∖I} INSERT {R∖I} WHERE {L}` is
already, structurally, a graph rewrite. We compile to it rather than build a rewriting engine,
because the triplestore has been optimising that operation for twenty years and we have not.

---

## 2. What a rule looks like

A rule is two pictures.

**L** — the match pattern. What must be true.
**R** — the construct pattern. What becomes true.

Both are named graphs full of ordinary triples. Here is the whole of
`examples/moneygraph/01-classify-bond.trig`, minus its prefixes:

The declaration, in the **default graph** — what the rule is, and what its variables are:

```turtle
:ClassifyBond
    rdf:type jhp:Rule ;
    skos:prefLabel "Classify bond" ;
    skos:definition "An instrument with a coupon rate and a maturity date is a mg:Bond." ;
    jhp:hasMatchPattern     :ClassifyBond_L ;
    jhp:hasConstructPattern :ClassifyBond_R ;
    jhp:rewriteMode         jhp:_RewriteMode_assert .

:ClassifyBond_L rdf:type gistp:SparqlPattern .
:ClassifyBond_R rdf:type gistp:SparqlPattern .

:_Sec rdf:type gist:FinancialInstrument , gistp:SparqlVariable ;
      gistp:variableText "?_Sec" .
```

Then the two pictures. **L** — what must be true:

```turtle
:ClassifyBond_L {
    :_Sec rdf:type gist:FinancialInstrument ;
          mg:couponRate   "?rate"^^gistp:var ;
          mg:maturityDate "?maturity"^^gistp:var .
}
```

**R** — what becomes true:

```turtle
:ClassifyBond_R {
    :_Sec rdf:type mg:Bond .
}
```

Read those two graphs and you have read the rule. Everything above them is bookkeeping.

Four things are worth slowing down for.

**A pattern *is* its graph.** `:ClassifyBond_L` names both the pattern and the graph holding
its triples. There is no membership property, no `hasTriple`, no separating payload from
metadata. Whatever is inside the graph is the pattern. This is why rules are written in
**TriG** rather than Turtle — Turtle has no named graphs, so it cannot express a rule at all.

**There are two ways to write a variable, because RDF has two kinds of position.** `:_Sec` is
a declared individual: an ordinary IRI, typed both `gist:FinancialInstrument` *and*
`gistp:SparqlVariable`. That double typing is deliberate — the pattern is simultaneously a
placeholder and valid instance data, so your own SHACL shapes can validate it. But a literal
position must hold a literal, so there you write `"?rate"^^gistp:var` instead. The datatype is
the marker.

**The mode is stated, never inferred.** `jhp:_RewriteMode_assert` means "add these facts." A reader
should not have to diff L against R to work out whether a rule deletes.

**`skos:prefLabel` and `skos:definition` are not decoration.** They are what `list_rules`
shows a human, and what an agent reads to decide whether a rule is the one it wants. A rule
without a definition is a rule nobody will trust.

### The three modes

| Mode | What you get | Reach for it when |
|---|---|---|
| `jhp:_RewriteMode_construct` | `f(G)` — the construct pattern alone, input untouched | Reports, extracts, migrations: the answer is separate from the input |
| `jhp:_RewriteMode_assert` | `G ∪ f(G)`, repeated to a fixpoint | Classification, derivation, transitive closure |
| `jhp:_RewriteMode_rewrite` | `DELETE { L∖I } INSERT { R∖I }` | Correcting, retiring, state transitions |

`Construct` and `Assert` compile to **identical SPARQL**. The difference is entirely in how
often the engine runs it and what it does with the answer. That is worth knowing, because it
means switching between them is not a rewrite of your rule.

`Rewrite` is the one that deletes, and it works off **I**, the interface — the triples that
appear in *both* L and R:

```
    I     = L ∩ R      preserved
    L ∖ I              deleted
    R ∖ I              added
```

**You author I by repetition.** If you want a triple kept, you write it in both patterns.
This sounds like a chore and is actually the safety feature: forgetting to repeat a triple is
visible in the picture, whereas a rule that silently strips a node's type is not.

---

## 3. Setting up

You need Julia 1.10 or later, a checkout of Jayhawk, and Apache Jena Fuseki.

```bash
cd ~/dev/Jayhawk
julia --project=. -e 'using Pkg; Pkg.instantiate()'   # once
./bin/fuseki-test.sh start                            # in-memory Fuseki on :3040/jayhawk
```

Everything resolves from the General registry. No sibling checkouts, no forks to pin.

The engine talks to `http://localhost:3040/jayhawk` by default. Point it somewhere else with
`JAYHAWK_SPARQL_SERVICE` before Julia starts, or at any time with `set_endpoint!`.

**Jena parses your RDF, not Julia.** Files go into the store over the Graph Store Protocol and
come back as SPARQL results. Jayhawk contains no RDF parser at all. That is why TriG, blank
nodes, datatypes and namespaces behave exactly the way your triplestore says they do, and why
`riot --validate` accepting a file means the engine will accept it too.

---

## 4. Your first rule, start to finish

```julia
using Jayhawk

D = "urn:jayhawk:example:moneygraph"

load_file!("examples/moneygraph/data.trig")
load_file!("examples/moneygraph/01-classify-bond.trig")
```

Before running anything, look at it. `tool_explain_rule` shows the metadata, the compiled
SPARQL, *and* a dry run against your real data — writing nothing:

```julia
print(tool_explain_rule("https://w3id.org/moneygraph/ns/rules/ClassifyBond"; source = [D]))
```

```
Rule <https://w3id.org/moneygraph/ns/rules/ClassifyBond>
  mode              : Assert
  match pattern L   : <…/ClassifyBond_L> (3 triples)
  construct pattern R: <…/ClassifyBond_R> (1 triples)
  variables bound by L: ?_Sec, ?maturity, ?rate
  strategy          : ToFixpoint  (default for Assert)
  iteration budget  : 100  (default)
  guards            : none -- this rule fires on every match

compiles to:

# Assert rule <…/ClassifyBond>
CONSTRUCT {
  ?_Sec <…22-rdf-syntax-ns#type> <…/ontology/Bond> .
}
WHERE {
  ?_Sec <…22-rdf-syntax-ns#type> <…/gist/FinancialInstrument> .
  ?_Sec <…/ontology/couponRate> ?rate .
  ?_Sec <…/ontology/maturityDate> ?maturity .
}

dry run against <urn:jayhawk:example:moneygraph> would add 2 new triple(s):
    <…/data/IBM2029> <…#type> <…/ontology/Bond> .
    <…/data/T4875>   <…#type> <…/ontology/Bond> .

Nothing was written. Use run_rule to apply it.
```

*Output in this guide is abridged in one way only: the engine works in absolute IRIs and
prints them in full, so `…` stands for the middle of a namespace. The triples themselves are
measured — `test/sparql_integration.jl` asserts every figure here, so this guide fails with
the code rather than quietly describing an engine that no longer exists.*

**Read the dry run, not the SPARQL.** The facts a rule would create are reviewable by anyone
who understands the business. The query text is not. The SPARQL is there for when you need it,
not because you are expected to check it.

Now run it:

```julia
fs = run_rule("https://w3id.org/moneygraph/ns/rules/ClassifyBond"; source = [D], actor = "doug")
```

```
1-element Vector{Firing}:
 Firing(…/ClassifyBond [Assert] iter 1 -> 2 added in <urn:jayhawk:firing:10a16717-…>)
```

Two instruments qualified. `mg3:AAPL` has no coupon rate, so L never reached it. That is the
whole of the logic: **a rule does not need an `if`, because a pattern that does not match does
not fire.**

Notice where the output went. Not into your data — into `urn:jayhawk:firing:10a16717-…`, a
fresh graph of its own, with a provenance record. Nothing you loaded was modified. We will
come back to what that buys you in §8.7.

---

## 5. A rule that changes data

Classification only describes things that are already there. Sooner or later you need to
correct something. Here is `04-retire-listing.trig` — a security has been delisted, so its
current listing should become a former listing:

```turtle
:RetireListing
    rdf:type jhp:Rule ;
    skos:prefLabel "Retire listing" ;
    jhp:hasMatchPattern     :RetireListing_L ;
    jhp:hasConstructPattern :RetireListing_R ;
    jhp:rewriteMode         jhp:_RewriteMode_rewrite ;
    jhp:strategy            jhp:Once .
```

**L** — a listed instrument that has been delisted:

```turtle
:RetireListing_L {
    :_Sec rdf:type gist:FinancialInstrument ;
          mg:isListedOn  :_Exch ;
          mgx:delistedOn "?when"^^gistp:var .
}
```

**R** — the same instrument, with the listing moved into the past:

```turtle
:RetireListing_R {
    :_Sec rdf:type gist:FinancialInstrument ;          # repeated -> preserved
          mgx:delistedOn        "?when"^^gistp:var ;   # repeated -> preserved
          mgx:formerlyListedOn  :_Exch .               # new
}
```

The engine will tell you exactly how it read that:

```julia
spec = load_rule("https://w3id.org/moneygraph/ns/rules/RetireListing")

length(interface(spec))        # 2  -- type and delisting date, preserved
length(match_only(spec))       # 1  -- mg:isListedOn, deleted
length(construct_only(spec))   # 1  -- mgx:formerlyListedOn, added
```

Drop the two repeated lines from R and the rule would strip the instrument of its type and
its delisting date on the way past. **That** is why the mode cannot be inferred from which
triples happen to repeat: repetition decides I, and the mode decides what happens to `L ∖ I`.
They are two different questions and they need two different answers.

Rewrites get a dry run of their own, because "what would this remove" is the question you
actually have:

```julia
dry_run_rewrite(spec; source = [D])
```

```
(count = 1, sample = [ENRN mgx:formerlyListedOn NYSE],
 removed = 1, removed_sample = [ENRN mg:isListedOn NYSE])
```

Then run it:

```julia
f = run_rule(spec; source = [D], actor = "doug")[1]
f.count      # 1 added
f.removed    # 1 removed
f.tombstone  # "urn:jayhawk:tombstone:…"  -- what was deleted, kept
```

Three safeguards apply to rewrites and only to rewrites:

- **exactly one source graph**, because a deletion has to name what it deletes from;
- **`confirm = true`** over the agent interface, because a destructive default is the wrong
  one to hand a model;
- **a tombstone graph**, written in the same atomic update, so undo can put back what went.

### Dangling references

SPARQL Update performs no dangling check. If a rule deletes every triple the pattern knows
about for some node, and never mentions that node in R, anything *outside* the pattern still
pointing at it is left referring to nothing.

```julia
dangling_risks(spec)     # String[] -- clean, because R still mentions ?_Exch
```

Jayhawk reports this rather than refusing it — stripping a node is sometimes exactly the
intent — and `explain_rule` shows the warning before you run anything.

---

## 6. Working at the REPL

The REPL is where you *find out* what a rule does. Nothing here is ceremony; every step
answers a question you actually have.

```julia
julia> using Jayhawk

julia> D = "urn:jayhawk:example:moneygraph"
"urn:jayhawk:example:moneygraph"

julia> load_file!("examples/moneygraph/data.trig")

julia> load_file!("examples/moneygraph/01-classify-bond.trig")

julia> list_rules()
1-element Vector{String}:
 "https://w3id.org/moneygraph/ns/rules/ClassifyBond"

julia> graph_size(D)
28

julia> spec = load_rule("https://w3id.org/moneygraph/ns/rules/ClassifyBond");

julia> effective_strategy(spec)
:ToFixpoint

julia> dry_run(spec; source=[D]).count
2

julia> fs = run_rule(spec; source=[D], actor="doug")
1-element Vector{Firing}:
 Firing(…/ClassifyBond [Assert] iter 1 -> 2 added in <urn:jayhawk:firing:10a16717-…>)

julia> firings()
1-element Vector{@NamedTuple{graph::String, rule::String, at::String, count::Int64, …}}:
 (graph = "urn:jayhawk:firing:10a16717-…", rule = "…/ClassifyBond",
  at = "2026-08-18T22:27:42Z", count = 2, actor = "doug", iteration = 1,
  removed = 0, tombstone = "")
```

Four habits that make the REPL pleasant rather than annoying:

**Bind `spec` with a semicolon.** `RuleSpec` has no custom display, so typing `spec` at the
prompt dumps every pattern triple, every variable and every control field as one enormous
line. Use `tool_explain_rule` when you want to *look* at a rule; keep `spec` for passing
around.

**Load the rule once, compile many times.** `load_rule` is the only part that talks to the
store. Everything downstream — `compile_rule`, `interface`, `dangling_risks`,
`effective_strategy` — is a pure function of the `RuleSpec`. Hold onto it and iterate.

**`dry_run` before `run_rule`, always.** It costs one query and it is the difference between
finding out now and finding out in the provenance log.

**Editing a rule file means reloading it.** Jayhawk reads rules from the store, not from
disk. Change the `.trig`, then `load_file!` it again, then `load_rule` again. If a change
seems to have had no effect, this is why nine times out of ten.

---

## 7. Working from a script

The REPL is for finding out. A script is for doing it the same way twice. The difference that
matters is not the file — it is that a script has to say what it assumes and check that it
held.

```julia
#!/usr/bin/env julia
# classify-and-mint.jl -- run the classification pipeline over the moneygraph data.

using Jayhawk

const D   = "urn:jayhawk:example:moneygraph"
const RNS = "https://w3id.org/moneygraph/ns/rules/"

set_endpoint!(get(ENV, "JAYHAWK_SPARQL_SERVICE", "http://localhost:3040/jayhawk"))

# 1. Load. Jena parses; syntax comes from the file extension.
load_file!("examples/moneygraph/data.trig")
for f in ("01-classify-bond", "02-mint-coupon-event")
    load_file!("examples/moneygraph/$f.trig")
end

# 2. Refuse to run against an empty graph. A rule that matches nothing looks exactly like
#    a rule that ran fine, so check the precondition rather than the result.
n = graph_size(D)
n == 0 && error("no data in <$D> -- did the load fail?")
@info "working set" graph=D triples=n

# 3. Look before leaping, and record what we expected.
for r in ("ClassifyBond", "MintCouponEvent")
    d = dry_run("$RNS$r"; source = [D])
    @info "dry run" rule=r would_add=d.count
end

# 4. Apply, in order. Each rule's output lands in its own firing graph.
applied = Firing[]
for r in ("ClassifyBond", "MintCouponEvent")
    fs = run_rule("$RNS$r"; source = [D], actor = "pipeline")
    append!(applied, fs)
    @info "applied" rule=r firings=length(fs) added=sum(f.count for f in fs; init=0)

    # 5. Promote into the working set, so the NEXT rule can see it.
    for f in fs
        update!("INSERT { GRAPH <$D> { ?s ?p ?o } } WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")
    end
end

@info "done" total_added=sum(f.count for f in applied; init=0) firings=length(applied)
```

### The one thing that catches everybody

Step 5 is not optional, and it is the single most common source of "my second rule did
nothing."

A firing writes into **its own graph**. It does not touch your working set. So this sequence
fails, silently and with no error:

```julia
run_rule("$(RNS)ClassifyBond";    source = [D])   # writes mg:Bond into a firing graph
run_rule("$(RNS)MintCouponEvent"; source = [D])   # looks for mg:Bond in D -- finds none
```

`MintCouponEvent` matches `?_Bond a mg:Bond`. Those triples exist, but they are in
`urn:jayhawk:firing:…`, not in `D`. You have two honest options:

```julia
# (a) promote the firing into the working set -- durable, and what a pipeline wants
update!("INSERT { GRAPH <$D> { ?s ?p ?o } } WHERE { GRAPH <$(f.graph)> { ?s ?p ?o } }")

# (b) widen the source -- non-destructive, and what an experiment wants
run_rule("$(RNS)MintCouponEvent"; source = [D, f.graph])
```

Use (a) when the derived facts are now part of the record. Use (b) when you are still deciding.
The point is that the engine will not guess which you meant — chaining is a decision, and it
is yours.

Note that this is a *separate* question from `jhp:ToFixpoint`. A fixpoint strategy iterates
**within one rule**: each round's output joins that rule's working set, which is how transitive
closure works. It does not carry one rule's output into the next.

---

## 8. The functions, and when to reach for them

Grouped by the question you are trying to answer.

### 8.1 Connecting

```julia
endpoint()
# SparqlEndpoint("http://localhost:3040/jayhawk", ".../update", ".../data", 30)

set_endpoint!("http://prod-store:3030/warehouse")
set_endpoint!(SparqlEndpoint("http://other:3030/ds"))       # or build one explicitly
```

**Why.** `endpoint()` answers "which store am I about to change?", which is worth asking out
loud before a rewrite. `set_endpoint!` changes it for the whole process without restarting
Julia — useful when you are comparing dev against staging in one session.

Every function that touches the store takes `ep = endpoint()`, so you can also aim a single
call somewhere else without disturbing the default:

```julia
select(q; ep = SparqlEndpoint("http://staging:3030/ds"))
```

### 8.2 Getting data in

```julia
load_file!("examples/moneygraph/data.trig")     # syntax inferred: .trig .nq .nt else Turtle
load_dataset!(trig_string)                      # same, from a string you already have
load_graph!(turtle_string, "urn:my:graph")      # put plain Turtle into ONE named graph
graph_size("urn:my:graph")                      # 28
```

**Why each.** `load_file!` is what you want almost always — a TriG file places its own triples
into its own named graphs, which is exactly how rule files and datasets are written.
`load_dataset!` is the same thing when the content came from somewhere other than disk.
`load_graph!` is the odd one out: it takes content with *no* graph structure and puts all of
it into a graph you name. Reach for it when you have Turtle from an upstream system and you
are deciding where it lands.

`graph_size` is the cheapest sanity check there is. A rule that matches nothing and a graph
that failed to load look identical from the outside; one number tells them apart.

```julia
skolemize!(graph = "urn:my:data")               # or omit `graph` for the whole dataset
```

**Why.** Blank nodes are fine in data and fatal in patterns, and they are not stable across
loads. `skolemize!` replaces them with real IRIs so they can be referenced, transported and
compared. This is a one-shot SPARQL update rather than an export-rewrite-reload, so it is
cheap enough to do on the way in.

### 8.3 Asking the store questions directly

```julia
rows = select("SELECT ?s ?r WHERE { GRAPH <$D> { ?s mg:couponRate ?r } }")
rows[1]["s"]        # IRIRef("https://…/data/IBM2029")
rows[1]["r"]        # RDFLiteral("0.0330", "http://www.w3.org/2001/XMLSchema#decimal", nothing)

ask("ASK { GRAPH <$D> { ?s a mg:Bond } }")      # false
update!("DROP SILENT GRAPH <urn:scratch>")
```

**Why.** `select` is the datatype-faithful path and the one the engine itself uses. It returns
`RDFTerm`s with the datatype intact, which matters more here than in most systems: a datatype
is how this engine marks a variable, so anything that normalises `"0.0330"^^xsd:decimal` down
to a string has thrown away information the compiler depends on.

`ask` is for preconditions — cheaper than counting when all you need is whether something
exists. `update!` is the escape hatch: when a rule is the wrong shape for what you are doing
(bulk cleanup, promoting a firing, dropping scratch), write the SPARQL and move on. Not
everything should be a rule.

All three take `bindings` for parameterisation:

```julia
select("SELECT ?s WHERE { GRAPH <{{g}}> { ?s ?p ?o } }"; bindings = Dict("g" => D))
```

### 8.4 Finding out what rules exist

```julia
list_rules()
# ["https://…/rules/ClassifyBond", "https://…/rules/DomesticListing", …]

rule_catalogue()
# (iri = "…/ClassifyBond", mode = :Assert, mode_iri = "…/Assert",
#  label = "Classify bond",
#  definition = "An instrument with a coupon rate and a maturity date is a mg:Bond.",
#  guards = 0)
```

**Why.** `list_rules` gives you IRIs — right for a loop, useless for a human. `rule_catalogue`
gives you the labels, definitions and guard counts, which is what you want when deciding
*which* rule to run. It is also the honest answer to "what can this system do?", and it is
generated from the store rather than maintained in a wiki that drifts.

```julia
list_rule_sets()                                  # iri, label, member count
spec = load_rule_set("https://…/sets/BondEnrichment")
spec.rules                                        # resolved into execution order
```

**Why.** A set's whole content is its *order*, so `load_rule_set` resolves membership into one
before you run anything — and every membership is fetched with `OPTIONAL` and then checked
rather than joined on, because a join would drop a member missing its `gist:sequence` and
silently run a **shorter** set. In a cascade that produces a plausible answer rather than an
error, which is worse than failing.

```julia
spec = load_rule("https://…/rules/ClassifyBond")
```

**Why.** `load_rule` is the **only** function here that does I/O for a rule. Everything below
is a pure function of the `RuleSpec` it returns. That split is deliberate: it means you can
load once and then inspect, compile and re-compile as much as you like with no server round
trips, and it means the interesting half of the engine is testable with no store at all.

A `RuleSpec` is plain data, and its fields are worth knowing because they are what every
inspection function reads:

| Field | Holds |
|---|---|
| `iri`, `mode` | the rule's IRI and its mode IRI — compare against `MODE_ASSERT` and friends |
| `match`, `construct` | L and R, as `Vector{PatternTriple}` — subject, predicate, object, each an `RDFTerm` |
| `variables` | variable IRI ⇒ its `variableText`, e.g. `"…/_Sec" => "?_Sec"` |
| `mints` | variable IRI ⇒ `MintSpec`, the template and its slots |
| `enums` | variable IRI ⇒ the values `oneOf` allows. **Check this first when a rule stops firing** — see §10 |
| `nacs` | a `NacSpec` per guard |
| `strategy`, `priority`, `max_iterations` | execution policy, or `nothing` where unstated |
| `match_scope`, `construct_scope` | `jhp:inGraph` — where the rule **reads** and where it **writes**, or `nothing` |
| `source_maps` | a `SourceMapSpec` per `gistp:SourceMap`: column, target variable, and pipeline |
| `services` | scopes that name a `gistp:TabularDataSource`, with their `fx:` properties |
| `filters` | the `jhp:filterText` of each `jhp:hasFilterCondition`, sorted |

```julia
spec.mode                      # "https://…/patterns/gist/Assert"
length(spec.match)             # 3
spec.variables                 # Dict("…/rules/_Sec" => "?_Sec")
spec.match[1].predicate        # IRIRef("…22-rdf-syntax-ns#type")
```

Bind it with a trailing semicolon at the REPL — `RuleSpec` has no custom display and prints
every field as one very long line.

### 8.5 Reading a rule before you run it

```julia
compile_rule(spec)                    # pure: RuleSpec -> SPARQL text
compile_from_store("…/ClassifyBond")  # load_rule + compile_rule in one step
```

**Why.** `compile_rule` is the whole compiler, and it touches nothing. Use it when you want to
see the query, diff two versions of a rule, or paste the SPARQL into a query console to
explain a plan. `compile_from_store` is the convenience form for when you have an IRI and no
reason to keep the spec.

```julia
interface(spec)         # I  = L ∩ R -- preserved
match_only(spec)        # L∖I        -- deleted by a Rewrite
construct_only(spec)    # R∖I        -- added
```

**Why.** These three are how you check that a rewrite means what you think. Counting them is
faster than reading the TriG, and it catches the failure that matters: a triple you *meant* to
preserve that is not actually repeated verbatim.

```julia
dangling_risks(spec)    # String[] when clean; otherwise the variables at risk
```

**Why.** Run this on any rewrite before it goes near production. It answers "will this leave
orphans?", which SPARQL will not answer for you.

```julia
effective_strategy(spec)                      # :ToFixpoint
effective_strategy(spec; strategy = :Once)    # :Once -- what an override would do
```

**Why.** Strategy has a default that depends on mode (`ToFixpoint` for `Assert`, `Once` for
everything else). When you are about to override it, this tells you what you are overriding
rather than making you remember the rule.

```julia
d = dry_run(spec; source = [D])            # additive rules
d.count                                    # 2
d.sample                                   # up to `limit` (default 25) actual triples

dry_run_rewrite(spec; source = [D])        # rewrites: adds AND removes
# (count = 1, sample = […], removed = 1, removed_sample = […])
```

**Why.** This is the function that makes the whole thing safe to use. It runs the real query
against your real data into a scratch graph, prunes facts you already had, shows you the
result, and drops the scratch graph. Nothing is written. Use `dry_run` habitually; use
`dry_run_rewrite` before every rewrite, because "what will disappear" is not a question to
answer from the picture alone.

```julia
insert_query(spec; into = "urn:scratch", from = [D])
rewrite_query(spec; target = D, firing = "urn:f", tombstone = "urn:t", from = [D])
project_query(spec; triples = spec.construct, into = "urn:scratch", from = [D])
```

**Why.** The exact SPARQL the harness will send. Most people never need these — reach for them
when a rule behaves in a way you cannot explain and you want to run the update by hand, or
when you are extending the engine and need to see what the builders produce. `project_query`
is the general form: give it any triple list and it builds the INSERT for just those.

### 8.6 Running

```julia
run_rule("…/ClassifyBond"; source = [D], actor = "doug")
run_rule(spec; source = [D], actor = "doug",
         strategy = :Once, max_iterations = 1000)
```

**Why.** `run_rule` is the one you want. It honours the rule's strategy, iterates a fixpoint
until nothing changes, enforces the iteration budget, records provenance and returns a
`Firing` per round. `strategy` and `max_iterations` override the rule for this call only,
which is the right place for a one-off — you are not editing a rule to run an experiment.

`actor` is not decoration. It lands in the provenance record. "Who ran this?" is a question
somebody will eventually ask.

```julia
run_rules("…/sets/BondEnrichment"; source = [D, DERIVED], actor = "doug")
run_rules(["…/RuleA", "…/RuleB"]; source = [D])        # a bare list, ordered by priority
run_rules(set; strategy = :ToFixpoint, max_iterations = 5)
```

**Why.** `run_rules` applies an ordered set, and the set's own strategy governs how many times
the whole pass is made — which is the only way to express "a later rule feeds an earlier one".
`set` may be a `RuleSetSpec`, the IRI of a `jhp:RuleSet`, or a bare vector of rule IRIs.
Returns every `Firing` in the order it ran, and members that contributed nothing yield none.
See §9's **Rule sets** for the vocabulary and for why mixed modes are refused.

```julia
apply_rule(spec; into = "urn:my:firing", source = [D], actor = "doug", iteration = 1)
apply_rewrite!(spec; source = [D], actor = "doug")
```

**Why.** One application, no iteration, no strategy. Reach for `apply_rule` when you are
building your own control loop and want the fixpoint logic to be yours — or when you want the
result in a graph you name. Note that `into` must be **empty**: the engine refuses a target
that already holds triples, because a firing graph's size is reported as this rule's
contribution and `undo_firing!` drops the whole graph.

`apply_rewrite!` is the destructive counterpart, and it is what `run_rule` calls for a
`Rewrite`. Use it directly only if you are certain; `run_rule` is the safer door.

### 8.7 Provenance and undo

```julia
firings()                                  # every firing, newest information first
firings(rule = "…/ClassifyBond")           # just this rule's
```

```
(graph = "urn:jayhawk:firing:10a16717-…", rule = "…/ClassifyBond",
 at = "2026-08-18T22:27:42Z", count = 2, actor = "doug",
 iteration = 1, removed = 0, tombstone = "")
```

**Why.** This is the audit log, and it is data in the store rather than a file somebody has to
remember to ship. It answers what ran, when, on whose authority, how much it changed, and —
for a rewrite — where the removed triples are being kept.

Ordering is a **total** order, not a timestamp. `_now_xsd` stamps milliseconds and every
firing also carries `jayhawk:ordinal`, a monotonic integer assigned by the *same update* that
writes the record — read separately it could be claimed twice, and an ordinal that is merely
usually unique is not an order. `firings()` sorts by timestamp, then ordinal, then iteration,
with the timestamp staying primary so a provenance graph written by an older version still
reads sensibly. What forced it was `run_rules`: a set applies several rules inside one second,
all reporting iteration 1, so the log had nothing left to order them by and reported them **in
the wrong order** — stably, which reads as reliable.

```julia
retractions()                                           # everything a Rewrite has removed
retractions(predicate = "…/hasPositionIn")              # or constrain s, p, o by IRI
```

```
(subject = "<…/_InvestmentAccount_51590610_7150450>",
 predicate = "<…/gist/hasPositionIn>",
 object = "<…/_MarketableSecurity_7150450>",
 rule = "…/RetireMaturedPosition", at = "2026-09-22T12:17:54.562Z",
 actor = "doug", target = "urn:…:positions", tombstone = "urn:jayhawk:tombstone:…", ordinal = 8)
```

*Also a real row from `~/dev/PatternTester`, not a fixture from this repo.*

**Why.** *What was once true.* A rewrite always wrote `L∖I` to a tombstone, so the deleted
triples always survived their own deletion — but finding one meant already knowing a UUID
nobody holds. Here the provenance record is the **index**: tombstones are reached through
`jayhawk:tombstoneGraph`, so only graphs this engine wrote are ever searched, and each match
arrives already joined to the rule that retracted it and the transaction time it happened at.

The two halves of the question then read symmetrically: **what is true now** is a query against
the data, and **what was once true** is this. One thing the query cannot distinguish, and it
matters: never-asserted and still-true both come back empty.

#### The record is carried by gist, not by PROV-O

A firing is a `gist:Event` — "something that occurs over a period of time, often characterized
as an activity being carried out by some person, organization, or software application", which
is a rule firing exactly. Its rule and each source graph are `gist:isBasedOn`; the actor is a
`gist:hasParticipant`; a tombstone is `gist:isProducedBy` the firing that carved it out. The
engine's own `jayhawk:` terms stay alongside and are what the driver actually reads.

Two things that choice buys. gist is already this project's upper ontology and already a
dependency of the pattern vocabulary, so the record speaks the same language as the data it
describes. And **being a historical event is inferred rather than asserted**:
`gist:HistoricalEvent` is an *equivalent* class — `gist:Event` with exactly one
`actualStartDateTime` and exactly one `actualEndDateTime` — so the record states the two
datetimes and a reasoner reaches the classification. The suite asserts the class is never
stated outright. That is the difference between a machine-verifiable axiom and a label.

`gist:hasParticipant` and not its subproperty `gist:comesFromAgent`, whose range is
`gist:Organization ∪ gist:Person`: most actors here are software, and asserting that "mcp" is a
person is a falsehood a reasoner would propagate. Start equals end because the engine does not
measure how long an application took — claiming an unobserved duration would be worse than
claiming none.

PROV-O was considered and dropped: it fit the shape well but meant a second vocabulary to keep
in step for no gain the record did not already have. Any downstream alignment — PROV-O,
Biolink, OWL-Time — is a projection over this record and belongs to the project that needs it.

```julia
is_firing("urn:jayhawk:firing:10a16717-…")    # true
is_firing(D)                                  # false
undo_firing!("urn:jayhawk:firing:10a16717-…")
```

**Why.** `undo_firing!` reverses one application. For an additive rule that is a `DROP GRAPH`.
For a rewrite it also replays the tombstone, so the result is an exact inverse — verified in
the test suite by snapshotting the graph before and after.

It **refuses any graph without a provenance record**, and `is_firing` is the authority it
consults. That check is deliberate and worth understanding: membership is decided by the
provenance record, not by the `urn:jayhawk:firing:` prefix, because a prefix is a naming
convention anyone can imitate and a provenance record is something only the engine writes.
`undo_firing!` reverses rule applications. It is not a way to delete a graph.

**Retention is deliberately coupled to the firing**: undo restores the claim *and* forgets the
retraction, so a graph that has been undone stops appearing in `retractions()`. A retraction
outliving the firing that made it would assert a fact is no longer held while the fact sits in
the graph.

A **write-scoped** rule undoes just as exactly. Undo retracts from the *destination* precisely
what the firing graph holds, rather than re-deriving the rule and hoping the two agree — which
is the whole reason the firing graph stays the unit of attribution even when a rule writes
into live data.

### 8.8 Terms

```julia
IRIRef("http://ex.org/a")                    # an IRI
RDFLiteral("hi")                             # a plain literal
RDFLiteral("?x", GISTP_VAR)                  # a literal-position variable
BNode("b0")                                  # a blank node

sparql_text(RDFLiteral("?x", GISTP_VAR))
# "\"?x\"^^<https://w3id.org/semanticarts/ns/patterns/gist/var>"

is_var_literal(t)     # true  -- is this the variable marker?
var_name(t)           # "?x"
term_from_json(Dict("type"=>"uri", "value"=>"http://ex.org/x"))   # IRIRef(...)
```

**Why.** `RDFTerm` — `IRIRef | BNode | RDFLiteral` — is how every value comes back from
`select`, and `RDFLiteral` keeps lexical form, datatype and language as **separate** fields.
That is the whole reason this type exists rather than reusing a parser's: a datatype is
load-bearing here, and most RDF libraries have one field doing two jobs.

`sparql_text` renders a term back into SPARQL syntax — useful for building a query from values
you just read, and for comparing terms as strings when you want set arithmetic over triples.
`is_var_literal` / `var_name` are how you check whether a literal in a pattern is a variable.
`term_from_json` is the SPARQL Results JSON reader, exposed for when you have called
`runsparql` directly and want typed terms back.

### 8.9 The agent-facing tools

```julia
print(tool_list_rules())
print(tool_explain_rule("…/ClassifyBond"; source = [D]))
tool_run_rule("…/RetireListing"; source = [D], actor = "doc")
print(tool_list_rule_sets())
tool_run_rules("…/sets/BondEnrichment"; source = [D], actor = "doc")
tool_firings()
tool_retractions(predicate = "…/hasPositionIn")
tool_undo_firing("urn:jayhawk:firing:…")
```

**Why.** These seven return **formatted prose rather than data structures**, which makes them
the right thing for an LLM and, it turns out, for a human at a REPL. `tool_explain_rule` in
particular is the single most useful function in this guide: metadata, compiled SPARQL and a
dry run in one block.

They also enforce the safety rails the plain functions leave to you. `tool_run_rule` refuses a
rewrite without `confirm = true`:

```
Refused: <…/RetireListing> is a jhp:_RewriteMode_rewrite, which DELETES from live data. Against
<urn:jayhawk:example:moneygraph> it would remove 1 triple(s) and add 1.

Run explain_rule first to see exactly which triples, then call run_rule again with
confirm = true. The removal is reversible with undo_firing -- the deleted triples are kept
in a tombstone graph -- but this is not a decision to take by default.
```

The design point matters more than the code: **rules are the tools, not SPARQL.** No
enterprise is going to hand a language model an unrestricted UPDATE endpoint, and it would be
right not to. A catalogue of named, labelled, validated, provenance-stamped, reversible
rewrites is a different proposition — every operation is one somebody wrote and reviewed.

To serve them over MCP:

```bash
julia --project=bin -e 'using Pkg; Pkg.instantiate()'
julia --project=bin bin/mcp_server.jl
```

### 8.10 Constants worth knowing

| | |
|---|---|
| `GISTP_NS`, `GISTP_VAR` | the pattern namespace, and the variable-marker datatype |
| `MODE_CONSTRUCT`, `MODE_ASSERT`, `MODE_REWRITE` | the mode IRIs `RuleSpec.mode` holds |
| `STRATEGY_ONCE`, `STRATEGY_TOFIXPOINT` | the strategy IRIs |
| `PROVENANCE_GRAPH` | `urn:jayhawk:provenance` |
| `XSD_STRING`, `ABSOLUTE_IRI_RE`, `VARIABLE_RE` | used by the validators |

### 8.11 The compiler's own parts

These are exported because the engine is meant to be extended and debugged, not because you
need them day to day. Reach for them when you are changing the compiler or explaining output
you did not expect.

| Group | Functions | What they are for |
|---|---|---|
| Emission | `where_body`, `bgp_text`, `bind_text`, `values_text`, `nacs_text`, `graph_wrap`, `dataset_lines`, `escape_literal`, `term_sparql` | Each fragment of the generated query. `where_body` is the one that matters — all seven query builders route through it, so a guard cannot be honoured by only some of them. |
| Variables | `vars_in`, `var_of`, `scope_vars`, `enum_vars`, `minted_vars`, `is_scoped` | Which variables a pattern binds, and how. |
| Minting | `parse_template`, `template_slots`, `mint_fanin`, `collision_queries`, `ambiguous_separators` | RFC 6570 template handling and the collision analysis that stops two bindings minting one IRI. |
| Source maps | `fx_predicate`, `regex_quote`, `source_map_bgp`, `source_map_pipeline`, `load_source_maps` | Column name to Facade-X predicate, and the split/truncate/keep/drop pipeline. `fx_predicate` is the one measured against the service rather than derived. |
| Rule sets | `load_rule_set`, `list_rule_sets` | Membership resolved into an execution order. |
| Validation | `check_bound`, `check_variables`, `check_mints`, `check_enums`, `check_no_blanks`, `check_positions`, `check_scopes`, `check_iri`, `check_collisions`, `check_target_empty` | Every refusal in §11. Each is callable on its own, which is how you find out *which* check rejected a rule. |
| Loading | `load_pattern`, `load_variables`, `load_mints`, `load_enums`, `load_nac_graphs`, `load_strategy`, `load_priority`, `load_max_iterations`, `load_in_graph` | The individual SELECTs `load_rule` assembles. Useful when one part of a rule loads wrong. |
| Plumbing | `mode_symbol`, `strategy_symbol`, `new_firing_graph`, `new_tombstone_graph` | Conversions and IRI minting for the harness. |

---

## 9. The rest of the language

Six features cover most of what real rules need beyond match-and-assert.

### Minting: creating something that did not exist

Classification describes things already present. To *create* one, give a variable a template:

```turtle
:_ticker rdf:type gistp:LiteralVariable , gistp:SparqlVariable ;
         gistp:variableText "?ticker" ;
         gistp:requiresDatatype xsd:string .

:_Event rdf:type mg:CouponPaymentEvent , gistp:SparqlVariable ;
        gistp:variableText "?_Event" ;
        gistp:iriTemplate  "https://w3id.org/moneygraph/ns/data/coupon/{bond}" ;
        gistp:hasSlot [ rdf:type gistp:TemplateSlot ;
                        gistp:slotName  "bond" ;
                        gistp:slotValue :_ticker ] .
```

**Carrying a template is what makes a variable minted rather than matched**, so it must not
appear in L. It appears in R, which is what constructing it means.

Slots bind by RDF identity on both halves, never by a name happening to match. `{bond}` is
filled by `:_ticker` because `gistp:slotName` and `gistp:slotValue` say so. Note that the
variable is *declared* once and *named* thereafter: inside the patterns it is still the
literal `"?ticker"^^gistp:var`, but a slot names the declaration, so a mistyped reference is
an IRI pointing at nothing rather than a string matching nothing. Templates are RFC 6570
Level 1, which is exactly SPARQL's `ENCODE_FOR_URI`, so it compiles to:

```sparql
BIND(IRI(CONCAT("https://…/coupon/", ENCODE_FOR_URI(STR(?ticker)))) AS ?_Event)
```

> **Mint from identifiers, never from free text.** An earlier draft of this example minted
> from `gist:name` and produced `…/coupon/IBM%203.30%25%20of%202029` — correct, legal, and
> unreadable. `ENCODE_FOR_URI` percent-encodes; it does not tidy. Bind slots to tickers, codes
> and IDs.

Because expansion is a pure function of the bindings, re-running mints **byte-identical
IRIs**. That is what lets an `Assert` rule converge instead of growing forever.

### Guards: when a rule must not fire

A rule with no guard fires on every match, every time. `jhp:hasNegativeCondition` names a
pattern that must **not** match:

```turtle
:MintCouponEvent jhp:hasNegativeCondition :MintCouponEvent_NoEventYet .

:MintCouponEvent_NoEventYet rdf:type gistp:SparqlPattern .
:MintCouponEvent_NoEventYet { :_Event rdf:type mg:CouponPaymentEvent . }
```

Note what the guard is about: `:_Event`, the variable being **created**. That is legal because
the guard compiles to a `FILTER NOT EXISTS` emitted *after* the `BIND` that constructs it. It
reads as "only create this if it is not already there," which is what makes a minting rule
terminate.

Zero or more guards are allowed and all must fail for the rule to fire. A guard is a Basic
Graph Pattern like any other pattern — no `FILTER`, no `OPTIONAL`, no `UNION`. *"No
`mg:Exchange` refers to this"* is expressible, because the distinguishing test is a type
assertion. *"No **other** security refers to this"* is not, because it needs an inequality —
a comparison between bound values, which is what `jhp:hasFilterCondition` below is for.

### Filters: when a rule must compare

A guard says *"no such thing exists"*, and absence is structural — a pattern expresses it.
Comparison is not. *"These two are different nodes"*, *"this string contains that one"*,
*"this date falls before that one"* are all tests on values L has already **bound**, and no
arrangement of triples says any of them.

`jhp:hasFilterCondition` names a condition carrying one SPARQL expression:

```turtle
:MergeBondDetails jhp:hasFilterCondition :IssuerNameMatches .

:IssuerNameMatches
    rdf:type jhp:FilterCondition ;
    skos:prefLabel "issuer name appears in the activity description" ;
    jhp:filterText "CONTAINS(STR(?_actDesc), STR(?_issuerName))" .
```

It compiles to exactly what it says:

```sparql
FILTER(CONTAINS(STR(?_actDesc), STR(?_issuerName)))
```

**Write the expression, not the clause.** The engine supplies `FILTER` and the parentheses:
`CONTAINS(?a, ?b)`, never `FILTER(CONTAINS(?a, ?b))`.

Zero or more, and conjunctive — each compiles to its own `FILTER`, so a query log blames one
expression rather than a chain of `&&`. They are emitted after the `BIND`s, which means a
filter may test a *minted* variable, and sorted by text, so a condition authored as a blank
node still compiles to stable bytes.

**Prefer a triple to a filter wherever a triple will do.** A BGP is matched by the store's
indexes and is reviewable as RDF. A filter is text, is applied after matching, and is the
one place this engine splices what you wrote into the query it runs. So it is checked before
it is spliced, and refused if it:

| | why |
|---|---|
| contains `{` or `}` | would open a group or close the compiler's own `FILTER`. This bars `EXISTS { … }` deliberately — `jhp:hasNegativeCondition` is the sanctioned way to say "no such thing", and it is a reviewable *pattern* |
| contains `#` | a comment swallows the closing parenthesis the compiler emits |
| contains `;` | separates operations in an update request |
| has unbalanced parentheses | either closes the `FILTER` early or swallows what follows |
| leaves a string literal open | where the expression ends becomes a guess |
| uses a prefixed name | the compiler emits no `PREFIX` line and has no prefix registry, so `xsd:integer` would reach the store undeclared and come back as an opaque HTTP 400 |
| is itself a `FILTER(…)` clause | the engine supplies the keyword, so this compiles to `FILTER(FILTER(…))`, which no store will parse |
| names a variable nothing binds | see below |

The characters are looked for in a *skeleton* with string literals **and IRI references**
blanked out, so `CONTAINS(?label, "#1")` is fine — the `#` is data — and so is
`?t != <http://www.w3.org/2002/07/owl#Thing>`. That second one matters more than it looks:
since no `PREFIX` is ever emitted, angle brackets are the *only* way a filter can name a
resource or a datatype, and hash namespaces put a `#` in nearly every one. Blanking `<…>` is
safe rather than convenient — SPARQL's `IRIREF` is a token whose own character set already
excludes `<`, `>`, `"`, `{`, `}`, `|`, `^`, `` ` `` and `\`, so nothing the brace check wants
to see can hide inside one. An angle-bracketed run that breaks that character set is not an
IRI, is not blanked, and is refused like any other text.

Write full IRIs, then:

```turtle
jhp:filterText "DATATYPE(?amount) = <http://www.w3.org/2001/XMLSchema#decimal>" .
```

That last row is the one that costs real time. SPARQL does **not** raise an error on an
unbound variable inside a `FILTER`: the expression errors, the solution is silently dropped,
and the rule matches nothing. A single typo turns a rule off with no diagnostic anywhere —
the same failure `check_bound` exists to prevent on the construct side, and it earns the same
refusal here.

### How often a rule runs

```turtle
:MintCouponEvent jhp:strategy      jhp:ToFixpoint ;
                 jhp:maxIterations 5 ;
                 jhp:priority      50 .
```

| Property | Values | Default |
|---|---|---|
| `jhp:strategy` | `jhp:Once`, `jhp:ToFixpoint` | `ToFixpoint` for `Assert`, `Once` otherwise |
| `jhp:maxIterations` | a positive integer | 100 |
| `jhp:priority` | an integer | 0 |

**`ToFixpoint` re-runs until a pass changes nothing.** Each round's output joins that rule's
working set, which is how transitive closure works — and why a fixpoint run needs an explicit
`source`: SPARQL's `USING` cannot name the store's default graph.

**The budget is a hard stop, not a hint.** Exceed it and the run *fails* rather than returning
a half-finished graph. The usual cause is minting inside a fixpoint: `iriTemplate` invents
terms, which turns fixpoint evaluation into the chase, and the chase need not terminate. A
guard on the minted variable is the fix.

One combination is refused outright: a **`Rewrite` run to a fixpoint with no guard and no
stated budget**. A deleting rule has nothing to tell it when it is done, and falling back to
100 destructive passes is not a decision the engine will make for you.

`jhp:priority` orders a bare list of rules handed to `run_rules`, higher first, and breaks
ties between equal `gist:sequence` numbers inside a `jhp:RuleSet`. Note that the two
directions disagree: priority is higher-first, `gist:sequence` is lower-first. See
**Rule sets** below.

### Enumerations

`gistp:oneOf` fixes a variable to a list of values and compiles to `VALUES`:

```turtle
:_Exch rdf:type mg:Exchange , gistp:SparqlVariable ;
       gistp:variableText "?_Exch" ;
       gistp:oneOf ( mg3:NASDAQ mg3:NYSE ) .
```

One clause, two readings, decided by the rest of the rule: it **constrains** when L also binds
the variable, and **generates** when nothing else does. You do not choose which; the engine
works it out and `explain_rule` shows the result.

### Graph scoping

`jhp:inGraph` scopes a *pattern*, and it reads three ways — decided by what the value **is**,
not by separate vocabulary:

| the value is | the pattern reads | |
|---|---|---|
| a declared `gistp:SparqlVariable` | many graphs, binding whichever matched | read side only |
| an IRI typed `gistp:TabularDataSource` | a *file*, via `SERVICE <x-sparql-anything:>` | read side only, see **Source maps** |
| any other IRI | one named graph | read **or** write |

**Read scope and write scope are not one property wearing one name**, and conflating them is
what made every scoped rule look dangerous. They have opposite requirements:

- A scoped **read** *requires* an explicit `source`. With no dataset clause a graph variable
  ranges over every named graph in the store — the provenance graph, every firing, every
  tombstone, the rule catalogue's own patterns. It also cannot iterate, because each round
  appends its firing graph to the working set.
- A scoped **write** must name a **constant**. Different solutions going to different graphs
  would leave the firing graph — one flat set of triples — with nowhere to record which triple
  went where, so `undo_firing!` could not reverse it. It needs no `source` of its own, and it
  **can** iterate: output is promoted into the destination rather than appended, so the dataset
  clause never changes and round two reads round one's results from the graph they went to.

Still refused: a scope on R with `Rewrite` (a rewrite's destination *is*
the graph it reads; naming a second is a different operation), and a scope on R naming a
`gistp:TabularDataSource` (a `SERVICE` cannot be written to).

### Rule sets: what runs, in what order, and how many times

`run_rule` takes one rule. A `jhp:RuleSet` takes several, in a stated order:

```turtle
set:BondEnrichment
    rdf:type jhp:RuleSet ;
    skos:prefLabel "Bond enrichment" ;
    jhp:strategy      jhp:ToFixpoint ;
    jhp:maxIterations 5 .

set:BondEnrichment_1
    rdf:type gist:OrderedMember ;
    gist:isMemberOf       set:BondEnrichment ;
    gist:isFirstMemberOf  set:BondEnrichment ;
    gist:providesOrderFor :TypeTradeBonds ;
    gist:sequence         1 .
```

```julia
run_rules("https://…/sets/BondEnrichment"; source = [D, DERIVED], actor = "doug")
run_rules(["…/RuleA", "…/RuleB"]; source = [D])      # a bare list: jhp:priority orders it
```

A set is a `gist:OrderedCollection` and membership is **reified** — a `gist:OrderedMember`
carries `gist:isMemberOf` back to the set, `gist:providesOrderFor` out to the rule, and
`gist:sequence` as its position. It is deliberately **not** an `rdf:List`, and the reason is
decisive: SPARQL can recover membership from a list as a *set* but not a position, so an
`rdf:List` would cost one round trip per member where this costs one `ORDER BY`. Putting the
position on the *membership* rather than on the rule is also what lets one rule sit at
different places in different sets, and what makes the set itself a resource that can carry a
label, a definition and a validity period. **A revised guideline is a revised rule set.**

**Two levels of iteration, and they are independent.** Each rule still honours its own
`jhp:strategy`, so an `Assert` member closes internally before the next member is reached.
The *set's* strategy governs how many times the whole ordered pass is made. You need the
second whenever a later rule feeds an earlier one, and no arrangement of per-rule strategies
expresses that — a rule's own fixpoint iterates that rule alone:

```
pass 1  :TypeTradeBonds    +7
pass 1  :MergeBondDetails  +12
pass 2  :TypeTradeBonds    +3     <- securities that were not bonds until pass 1 ran
pass 3  (both ran, added nothing -- converged)
```

*Those four lines are from `~/dev/PatternTester/demo_merge_bond.jl` rather than from this
repo's examples, so unlike the rest of this guide they are not asserted by
`test/sparql_integration.jl`. They are output of a run, not a fixture.*

A member that contributes nothing yields **no `Firing`**. `apply_rule` drops the empty graph
without recording provenance, so returning one would hand back a firing `undo_firing!` must
refuse.

**Mixed modes are refused**, with one escape. An additive rule's output is a new named graph
later rules must read, but a `jhp:_RewriteMode_rewrite` takes exactly one source graph which is also its
target — contradictory the moment an additive rule has fired. So a set is all-`Rewrite` or
contains none. Give the additive members a `jhp:inGraph` destination and the contradiction
goes away: the working set never grows, the rewrite still has exactly one source, and it reads
the derived triples from the graph they were written to.

### Source maps: naming a column instead of a predicate

A pattern scoped to a `gistp:TabularDataSource` compiles to `SERVICE <x-sparql-anything:>`, so
a rule could always read a CSV — but it had to name the Facade-X predicates itself, which meant
the author doing the percent-encoding and knowing the row-container idiom. A `gistp:SourceMap`
says *this variable comes from that column* and the compiler owes the rest:

```turtle
:_Confirmations rdf:type gistp:TabularDataSource ;
    fx:location    "data/econfirmation_2023.csv" ;
    fx:csv.headers "true" ;
    fx:null-string "" .

:TradeIdMap a gistp:SourceMap ;
    gistp:mapTo         :_tradeId ;
    gistp:mapFromString "Trade #" .          # the source's own spelling

:BondMaturityMap a gistp:SourceMap ;
    gistp:mapTo             :_bondMaturity ;
    gistp:mapFromString     "Description" ;
    gistp:separator         "," ;             # split the cell into clauses
    gistp:valuePatternMatch "^ *DUE " .       # keep the one stating maturity
```

**For an extraction rule L is EMPTY**, and that is the correct shape rather than a shortcut.
Every triple the `SERVICE` needs is generated from the maps. A pattern that *also* named a
mapped variable would join with the generated triple, quietly requiring the column and the
pattern to carry the same string — `check_source_maps` refuses it. And putting the data-source
declaration inside L "to be safe" is a silent disaster: the triple lands **inside** the
`SERVICE`, where the file contains no such statement, and the rule matches nothing while
looking perfectly reasonable.

The pipeline order is the vocabulary's, not a choice:

| | |
|---|---|
| `gistp:separator` | splits one cell into many values, so it must come **first** |
| `gistp:stringBefore` | truncates each value |
| `gistp:valuePatternMatch` / `gistp:valuePatternExclude` | decisions about a *finished* value, so they compile to `FILTER`s |

`separator` is a **literal**, though ARQ's `apf:strSplit` takes a regex — the compiler escapes
it, so an author who writes `"."` means a full stop. `stringBefore` compiles to
`IF(CONTAINS(…), STRBEFORE(…), …)` rather than a bare `STRBEFORE`, which returns the empty
string when the needle is absent and would silently blank every value not containing it.

Two things to know before writing one.

**A mapped variable is a REQUIRED JOIN.** With `fx:null-string ""` a blank cell yields no
triple, so a row whose mapped cell is empty produces no solution at all — the whole **row**
vanishes, not just that value. Ordinary SPARQL, and the opposite of what a list of columns
reads like. Anything that must survive a missing cell needs its own rule.

**`fx:location` is resolved by the store's process, and cannot be a variable.** A location is
fixed when the rule is authored; supplying one at invocation is a parameter mechanism this
engine deliberately does not have. A wrong path is not an error — the service yields no rows
and the rule reports adding nothing.

> **The encoding is measured, not derived, and the docs are wrong about it.** Upstream claims
> `dc.title[en]` becomes `dc.title%5Ben%5D`; it does not. SPARQL Anything escapes `<>"{}|^\`
> and backtick and everything ≤U+0020 — what SPARQL's `IRIREF` forbids — **plus `#`, `(` and
> `)`, which it permits**. Brackets, `%`, `&`, `+`, `?` and `;` are left raw. An earlier
> version of `fx_predicate` specified itself as "exactly what `check_iri` rejects", which was
> tidy and false, and broke every column with a `#` in its name. Getting this wrong produces a
> rule that **matches nothing rather than erroring**, so if a source-map rule returns zero,
> check the predicate against the service before anything else.

The list-valued terms — `gistp:mapFrom`, `gistp:mapFirst`, `gistp:mapEach` and `gistp:concat`
— are **not built**, and are refused by name rather than ignored.

---

## 10. Traps that have cost real time

### Variable declarations are global, and they leak between rules

This is the sharpest edge in the system, and it is in the shipped examples.

A `gistp:SparqlVariable` is an ordinary RDF individual living in the **default graph**. Its
properties — `variableText`, `oneOf`, `iriTemplate` — attach to its **IRI**. Two rules that
use the same variable IRI therefore share everything ever declared about it, no matter which
file said it.

`03-domestic-listing.trig` declares an enumeration on `:_Exch`:

```turtle
:_Exch gistp:oneOf ( mg3:NASDAQ mg3:NYSE ) .
```

`04-retire-listing.trig` also uses `:_Exch`, and declares no enumeration at all. Load the
rewrite rule on its own and it compiles clean. Load the unrelated file, and it does not:

```julia
load_file!("examples/moneygraph/04-retire-listing.trig")
compile_from_store("…/RetireListing")     # WHERE has three triples, no VALUES

load_file!("examples/moneygraph/03-domestic-listing.trig")
compile_from_store("…/RetireListing")     # ...now ends with:
#   VALUES ?_Exch { <…/data/NASDAQ> <…/data/NYSE> }
```

That is not cosmetic. Take a security delisted from an exchange outside the enumeration — say
`NESN` on `SIX` — and measure the same rule both ways:

```
04 alone    : RetireListing would change 1 added / 1 removed
03 loaded   : RetireListing would change 0 added / 0 removed
```

**Loading an unrelated rule file silently stopped a rewrite from firing.** No error, no
warning; the rule just quietly declines. This is the worst failure mode a rule engine has,
because it looks exactly like "there was nothing to do."

**Give every rule its own variable individuals.** Namespace them by rule:

```turtle
:RetireListing_Exch  rdf:type mg:Exchange , gistp:SparqlVariable ;
                     gistp:variableText "?_Exch" .
```

`variableText` may repeat freely — `?_Exch` in two rules is two different SPARQL variables in
two different queries. It is the **IRI** that must not be shared. Sharing is only safe when
the variable carries nothing but `variableText`, and that is a property of today's file that
tomorrow's edit can quietly remove.

If a rule fires alone and stops firing in company, this is the first thing to check:

```julia
load_rule("…/RetireListing").enums      # non-empty means something declared oneOf on your variable
```

### A firing does not change your data

Covered in §7, and worth repeating because it is the most common surprise: `run_rule` writes
into a new graph. Chain rules by promoting the firing or widening `source`.

### Editing a `.trig` does nothing until you reload it

Rules are read from the store. Change the file, `load_file!` it again, `load_rule` again.

### `load_file!` is additive

Loading a corrected rule file **merges** with what is already there; it does not replace it. A
renamed variable leaves the old declaration behind, still attached to the old IRI, still
loaded by any rule that references it. When a rule file changes shape rather than content,
drop its graphs first:

```julia
update!("DROP SILENT GRAPH <…/RetireListing_L>")
update!("DROP SILENT GRAPH <…/RetireListing_R>")
```

### A rule's declarations must be in the default graph

`hasMatchPattern`, `hasConstructPattern` and `rewriteMode` inside a named graph are invisible
to `load_rule`, which then reports *no rule found* for an IRI that is plainly in the store.

### `runsparql` is not `select`

`runsparql` returns raw JSON. Indexing `["value"]` by hand throws away the datatype, which is
how a `^^gistp:var` marker gets lost. Use `select` unless you specifically want the wire format.

---

## 11. When a rule is refused

Jayhawk would rather refuse a rule than compile it into something that quietly misbehaves.
Each message names the fix.

| Message | What happened |
|---|---|
| *uses `?x` which the match pattern never binds* | A typo, usually. Literal-position variables are matched across L and R by string equality, so `?idtext` and `?idText` are different variables. |
| *contains N blank node(s)* | A blank node is an undeclared variable. It cannot carry `oneOf` or a template, does not connect L to R, and is illegal in a `DELETE`. The message prints the declarations to paste. |
| *iriTemplate … is relative* | Templates expand to absolute IRIs. A bare local part mints into whatever namespace the rule file's empty prefix happens to name. |
| *separates slots with `"_"`* | `ENCODE_FOR_URI` leaves `-._~` alone, so `"x_y"+"z"` and `"x"+"y_z"` both give `x_y_z` — two different things merged into one node. Use `/`. |
| *carries a template, which declares it minted, but the match pattern also binds it* | A variable is either constructed or matched. |
| *jhp:_RewriteMode_rewrite needs exactly one source graph* | "Delete from the union of these three" is neither expressible nor reviewable. |
| *still changing the graph after N iterations* | A fixpoint did not converge. Usually IRI minting from a value the rule itself derives. |
| *running to a fixpoint needs an explicit `source`* | Each round has to see the previous round's output, and SPARQL's `USING` cannot name the default graph. Load into a named graph, or apply the rule `Once`. |
| *a jhp:_RewriteMode_rewrite run to a fixpoint with no jhp:hasNegativeCondition must state a bound* | A deleting rule has nothing to say when it is done. Add a guard or a `maxIterations`. |
| *no rule found at `<…>`* | The IRI is wrong, or the rule's three declarations are not in the **default** graph. |
| *target graph `<…>` already holds N triple(s)* | `apply_rule`'s `into` must start empty: its size is reported as this rule's contribution, and `undo_firing!` drops the whole graph. |
| *jhp:inGraph must name a graph by IRI* | A graph name is an IRI, and so is a slot value. Here there is not even a withdrawn spelling to point at: no literal can name a graph, and none ever could. |
| *a rule with jhp:inGraph must name its graphs in `source`* | A graph variable with no dataset clause ranges over every named graph in the store, provenance included. |

---

## Where to go next

- **`examples/moneygraph/`** — the rules in this guide, runnable, and exercised by the test
  suite so the guide cannot drift from the engine.
- **`docs/developer-guide.md`** — how the compiler works, which invariants hold it together,
  and how to extend it.
- **`~/dev/gistPatterns`** — the pattern vocabulary itself, its SHACL shapes, and `verify.py`.
