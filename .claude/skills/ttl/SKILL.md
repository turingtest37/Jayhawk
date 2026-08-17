---
name: ttl
description: Validate, inspect, and semantically diff Turtle/RDF files using the Apache Jena command-line tools. Use when checking whether an ontology file is well-formed, when comparing two versions of a .ttl (especially after Protégé has resaved and reordered it), when a git diff of an ontology is unreadable noise, or when deciding whether a file that parses will actually load into Jayhawk.
---

# Working with Turtle files

## Where the tools are

```sh
JENA=/Users/doug/apache-jena-5.6.0
```

That is the **full Jena distribution**, in the home directory. It is *not*
`~/dev/apache-jena-fuseki-5.6.0`, which is the server-only distribution and contains no
command-line tools at all — just `fuseki-server` and one jar.

**Always use absolute paths**, never bare command names. The PATH here is booby-trapped:

- `~/.zshrc` exports `/Users/doug/dev/jena/bin`, which does not exist.
- `/Users/doug/bin/sparql` is an unrelated 5-line script pointing at a dead
  `budx4store:8000`. It shadows Jena's `sparql` if Jena's `bin` is ever added after
  `~/bin`.
- `/Users/doug/dev/jena/` is a source checkout with no built jars; its scripts fail with
  class-not-found.
- `/Users/doug/dev/datalake/apache-jena-3.1.0/` is a working but ancient (2016) install.

## Validate

```sh
$JENA/bin/riot --validate file.ttl
```

**Exit code 0 = clean, 1 = any problem — and warnings count as problems.** Measured on
this repo's fixtures:

| file | result |
|---|---|
| `resource/gistAcct3.0.0.ttl` | exit 0, silent |
| `resource/jayhawk.ttl` (deleted) | **exit 1** — `[line: 144, col: 1] Bad IRI: <urn:data> Code: 61/SCHEME_PATTERN_MATCH_FAILED` |

`<urn:data>` is a genuine defect: a URN needs `urn:NID:NSS` with a non-empty namespace
-specific string. It is a warning, not a parse failure, so the file still loads
everywhere — but `--validate` will keep returning 1 until it is fixed. Do not treat a
non-zero exit as "the file is broken"; read the message.

Diagnostics are real: `[line: N, col: N]` with an explanation.

## Count triples

```sh
$JENA/bin/riot --count file.ttl
```

**Writes its answer to stderr, not stdout.** `$(riot --count f.ttl 2>/dev/null)` returns
the empty string — a silent trap. Either keep stderr, or count N-Triples lines instead:

```sh
$JENA/bin/riot --output=ntriples file.ttl 2>/dev/null | wc -l
```

Reference count: `gistAcct3.0.0.ttl` = 919 (`jayhawk.ttl`, 457, was deleted).

## Compare two versions — use `rdfdiff`, never `sort | diff`

This is the main event. Protégé rewrites layout, prefix choice, and statement order on
every save, so `git diff` on a `.ttl` is mostly noise.

```sh
$JENA/bin/rdfdiff old.ttl new.ttl TTL TTL
```

Output is `models are equal` (exit 0) or `models are unequal` (exit 1) followed by `<`
lines (only in the first file) and `>` lines (only in the second). It compares **graphs**,
so reordering, reindenting, and renaming prefixes all correctly report as equal.

Against a git revision:

```sh
git show HEAD:resource/gistAcct3.0.0.ttl > /tmp/old.ttl
$JENA/bin/rdfdiff /tmp/old.ttl resource/gistAcct3.0.0.ttl TTL TTL
```

### Why not `riot --output=ntriples | sort | diff`

**Because blank-node labels are regenerated on every run.** Two invocations of `riot` on
the same unchanged file emit different `_:B…` identifiers, so a sorted textual diff
reports churn that isn't there.

This is not a corner case here: **557 of the 919 N-Triples lines in
`gistAcct3.0.0.ttl` mention a blank node** — every OWL restriction is one.

Demonstrated on two serializations of one identical graph (a `[ ]` restriction written
inline vs. as a named `_:restr`):

```
rdfdiff       -> models are equal          (correct)
sort | diff   -> all 3 triples differ      (false alarm)
```

Sorted N-Triples is still useful for *reading* what a file contains, or for diffing
files with no blank nodes. It is not a comparison tool for ontologies.

## Does it validate, or does it actually load?

**`riot` accepting a file does not mean Jayhawk can load it, and vice versa.** Jayhawk
parses through Serd, which disagrees with Jena in both directions. Verified:

| case | `riot --validate` | Serd / Jayhawk |
|---|---|---|
| `"122.1"^^mine:myDecimal` with `mine:` declared locally | exit 0, accepted | **throws `KeyError`** |
| `resource/jayhawk.ttl` (the `urn:data` warning) | **exit 1** | parsed fine, 457 statements |
| genuinely malformed Turtle | exit 1, `[line: 2, col: 12]` | throws `SerdException` |

The first row is the dangerous one. Serd resolves a datatype CURIE against a
**process-global** prefix registry, not against the document's own `@prefix` lines — so a
perfectly legal file fails to load because the prefix was never registered in the Julia
session. Register prefixes first (`Jayhawk.set_def_prefixes()`, or `add_prefix!` from the
`pfxs` that `read_rdf_string` returns) before parsing anything with custom datatypes.

So when the question is "will Jayhawk load this", check with Jayhawk — see the
`jl-probe` skill:

```julia
stmts, pfxs, base = Serd.read_rdf_string(read("file.ttl", String))
```

Serd has three distinct failure channels: `SerdException` (syntax), `ArgumentError` (bad
lexical form for a datatype), and `KeyError` (unregistered prefix). Catch all three.

Note also that `SerdException` carries **only a status enum** — no line, no column. The
underlying C library does print `(string):2:12: expected digit` to stderr, so you can
*see* the position when running interactively, but you cannot get it from the caught
exception. For diagnosing a bad file, run `riot` — that is what it is good at.

## Other tools in the box

`$JENA/bin/` also has `shacl`, `arq` (local SPARQL over files), `rsparql` (remote),
`update`, `infer`, `schemagen`, and the `tdb2.*` loaders. For querying a running server
see the `sparql` skill.

Converting between syntaxes is `riot --output=FMT` where FMT is `ntriples`, `turtle`,
`nquads`, `trig`, `rdfxml`, `jsonld`. `--formatted=FMT` pretty-prints instead of
streaming (uses more memory).
