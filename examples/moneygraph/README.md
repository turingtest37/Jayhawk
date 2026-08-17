# Worked examples: an investment graph

Four rules over a small slice of [moneygraph](../../../moneygraph), one per feature, each
runnable and each exercised by `test/sparql_integration.jl` — so the figures quoted in
`docs/user-guide.md` are measured rather than claimed.

| File | Mode | Teaches |
|---|---|---|
| `data.trig` | — | the fixture: securities, exchanges, two bonds, one delisted stock |
| `01-classify-bond.trig` | `Assert` | the basic shape; literal-position variables |
| `02-mint-coupon-event.trig` | `Assert` | `iriTemplate` + slots, a guard on the minted variable, strategy |
| `03-domestic-listing.trig` | `Construct` | `oneOf` in its constraining reading |
| `04-retire-listing.trig` | `Rewrite` | I authored by repetition; tombstones and exact undo |

The vocabulary is real: `mg:` is the moneygraph ontology and `gist:` is gist Core. `mgx:`
holds the handful of predicates these examples add, kept in their own namespace so it is
obvious which terms are borrowed and which are invented here.

## Running them

```bash
./bin/fuseki-test.sh start

julia --project=. -e '
using Jayhawk
D = "urn:jayhawk:example:moneygraph"
for f in sort(readdir("examples/moneygraph"))
    endswith(f, ".trig") && load_file!("examples/moneygraph/$f")
end
print(tool_list_rules())
print(tool_explain_rule("https://w3id.org/moneygraph/ns/rules/ClassifyBond"; source = [D]))
'
```

`explain_rule` writes nothing. When you want to apply one:

```julia
fs = run_rule("https://w3id.org/moneygraph/ns/rules/ClassifyBond"; source = [D], actor = "me")
undo_firing!(fs[1].graph)
```

Note that `02-mint-coupon-event` matches `mg:Bond`, which nothing asserts until
`01-classify-bond` has run — so run them in order, merging the first rule's output into the
data graph. The integration test does exactly that, and is the place to look for the full
sequence.
