# bondfix: a moneygraph SPARQL update, re-expressed as a rule set

moneygraph's `bin/fix-missing-bond-data.sh` runs one ~200-line SPARQL update,
`queries/fix-missing-bond-data.rq`. It pairs each bond **trade** (parsed from trade-confirmation
text into `__trades-bonds__`) with the **holding and purchase activity** it corresponds to in
`__current__`. It then copies onto the holding the facts only the confirmation carries:
exchange, issuer, callable flag, coupon terms, first coupon, yield to maturity, days of
interest paid. The output goes to `__securities__extra` and `__activities__extra`.

This directory is where that update becomes an ordered `jhp:RuleSet` of small rules, held to
**the same output, quad for quad**. The plan and its reasoning are in the Jayhawk
CLAUDE.md backlog.

| File | What it is |
|---|---|
| `data.trig` | the fixture: `__trades-bonds__`, `__current__`, `__units__` |
| `oracle.rq` | the committed query with one bug fixed (below). The definition of "same effect" |
| `expected.nq` | what `oracle.rq` writes over `data.trig`, frozen, graphs renamed `urn:jayhawk:example:bondfix:expected:*` |

`test/sparql_integration.jl` ("bondfix: the oracle reproduces its golden") re-runs the oracle
and compares the result against `expected.nq` in both directions. The rule set will be held
to the same file by the same comparison.

## The cases

| | Trade | Holding | Expected |
|---|---|---|---|
| A1 | COGECO 2031, 2025-03-18 | `5DDZBS0` | match: coupon terms, first coupon, interest days, YTM |
| A2 | COGECO 2031 again, 2025-06-02 | `5DDZBS0` | match: a *second* first-coupon event, keyed by its own purchase |
| B | ONTARIO strip 2028 | `5CPNON8` | match: no coupon, no interest days, so only the unconditional facts |
| C | ENBRIDGE 2033 | `5CQRSE4` | **no match**: activity gross is 14031.01, the trade says 14031.0 |
| D | ROYAL BANK 2035 | `5DRBCF2` | **no match**: the description says "RBC", never the issuer's name |
| E | APPLE 2030, USD | `037833dx5.U` | match: USD currency key; symbol normalised to `037833DX5` |

A1 and C–D copy live trades. A1's discriminator, `a631446d…`, is byte-identical to the one
in the live trade's IRI, so the copied amounts hash as the real ones do.

## Why the oracle is not the committed query

The committed query contains `?__currency_uom gist:symbol ?__currency .`, and that pattern is
joined to nothing.
- **Live:** moneygraph's store has a union default graph, so this matches every `gist:symbol`
  in it: seven exchange codes. Every row is multiplied by seven, and each bond's first-coupon
  event is minted seven times, keyed by an exchange code instead of a currency.
- **On this fixture:** measured with the units also placed in the default graph, the
  committed query mints **6** first-coupon events for 3 purchases. Each purchase gets a CAD
  event and a USD event.

`oracle.rq` differs by three lines (`diff` it against the original). The unit comes from the
trade's own net-amount magnitude, and its code from `__units__`. The reference graph has to
exist because no currency in `uomReferenceData.ttl` or `currency.ttl` carries a `gist:symbol`.

## Why the live store cannot be the oracle

Run live, the committed query writes nothing:
- `reload-all.sh` runs it *before* `create-current-ng.sh`, when `__current__` is empty.
- Run after it, `pl_create-current-ng.rq` never copies purchase activities into
  `__current__`. The query's OPTIONAL purchase then leaves `?__purch_dt` unbound, and the
  match FILTER drops every row.

Nothing ∅ = ∅ proves is worth having, so this fixture includes the activities that
`__current__` is meant to hold.

## Other moneygraph findings, reported here, not fixed

- `conversion/trades-bonds.rq`: `REPLACE(…, "^.*([0-9]+).*$", "$1")` is greedy and keeps only
  the **last digit** of the account number. That is why every trade sits in
  `_InvestmentPortfolio_8`.
- `bin/load-since-last.sh:46`: `if "x$FILES_FOUND" != "x"` is missing `test`, so the bond fix
  is never reached from there.
- A first-coupon event is minted per *purchase*, not per bond, so a bond bought twice has
  two. That is faithful to the query, and reproduced here on purpose (A2).

## What the rule set still needs from Jayhawk

- **A match that reads several named graphs, each side kept apart.** Trades and holdings use
  the same predicates, so merging the graphs matches a trade against itself.
- **Computed literal bindings.** The symbol normalisation, the `\W+ → -` slug, the date
  prefix, and the MD5 discriminator the event IRI is minted from.
- **Re-running as replacement.** The script drops both output graphs before it runs; the
  rule-set equivalent undoes its own earlier firings.
