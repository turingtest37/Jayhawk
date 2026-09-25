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
| `rules.trig` | the eight rules, their minting functions and the `jhp:RuleSet` ordering them |

`test/sparql_integration.jl` holds both to `expected.nq`, comparing in both directions.
"bondfix: the oracle reproduces its golden" re-runs the oracle. "bondfix: the rule set
reproduces the oracle, quad for quad" runs the rules, then checks that a second run adds
nothing and that undo leaves the inputs untouched.

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

## The rule set

`rules.trig` holds eight rules and the `jhp:RuleSet` that orders them. Run over the fixture,
they write exactly `expected.nq`: 43 + 35 quads, none missing and none extra.

| # | Rule | Reads | Writes | Stands for, in the query |
|---|---|---|---|---|
| 1 | MatchTradeToHolding | trades, holdings, units | work | the join and its FILTERs |
| 2 | ListingAndIssuer | work, trades, holdings | securities | exchange, issuer, issuer's name |
| 3 | Callable | work, trades | securities | the callable flag |
| 4 | CouponTerms | work, holdings | securities | the OPTIONAL on the holding's coupon terms |
| 5 | CouponMonths | work, holdings, trades | securities | both coupon OPTIONALs together |
| 6 | FirstCouponEvent | work, holdings, trades, units | securities | the minted first-coupon event |
| 7 | InterestDaysPaid | work, trades | activities | the OPTIONAL on interest days |
| 8 | YieldToMaturity | work, trades | activities | the minted YTM magnitude |

```julia
using Jayhawk
for f in ("data.trig", "rules.trig"); Jayhawk.load_file!("examples/moneygraph/bondfix/$f"); end
MG3 = "https://w3id.org/moneygraph/ns/data/"
run_rules("https://w3id.org/moneygraph/ns/rules/bondfix/BondFix";
          source = ["$(MG3)__trades-bonds__", "$(MG3)__current__", "$(MG3)__units__",
                    "urn:jayhawk:example:bondfix:work"])
```

How the query's constructs become rules:

- **The join becomes a fact.** Rule 1 does the heuristic match once. It records the result as
  a `mgw:Match` node in the work graph, naming every entity the query's filters tie together:
  the activity, the trade, the account, the bond, the trade security, the issuer, and both
  repayment terms. The other rules read *which* pairing matched rather than re-deriving it.
  Each match can be inspected and undone like any other firing.
- **OPTIONAL becomes a rule of its own.** Such a rule fires only where the optional part
  matches, which is exactly where the query's template instantiated those triples. The coupon
  terms need two rules because the query's two coupon triples depend on different OPTIONALs.
- **Two output graphs become one destination per rule.**
- **Derived keys become `jhp:hasBinding`s**, with the query's expressions carried over
  verbatim: symbol normalisation, the `\W+` slug, the date prefix and the MD5 discriminator.
- **Minted IRIs come from one `gistp:MintingFunction` per kind of IRI**, shared by every rule
  that mints that kind.

**Assumed, and true of moneygraph's pipeline:** the attribute values the query reads off one
entity are single-valued, such as one label per issuer and one net amount per trade. Where
they are not, the query cross-multiplies inside a single solution, and a later rule re-reading
them could pair them differently. The entities the filters constrain are never re-derived.
The issuer's label is re-tested against the description in rule 2 for the same reason.

## What building this changed in Jayhawk

| Round | What | Why this query needed it |
|---|---|---|
| 2 | several match patterns per rule, each in its own graph | trades and holdings share predicates; merged, a trade matches itself |
| 3 | `jhp:hasBinding` | every minted IRI is built from a computed key |
| 3b | `gistp:isMintedBy` | one minting function per class, not the namespace repeated in every rule |
| 4 | write-scoped firings pruned against the destination only | the issuer's `gist:Organization` typing is already in the trades graph, and the query writes it anyway |
| 4 | match patterns joined hub first | FirstCouponEvent took 4.39 s with its parts in IRI order and 0.016 s hub first; the oracle takes 0.1 s |
