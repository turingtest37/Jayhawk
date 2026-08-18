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

**Since v0.4.0, `riot` is authoritative.** Jayhawk has no RDF parser: files reach the store
over the Graph Store Protocol and **Jena parses every byte**. So if `riot --validate` accepts
a file, Fuseki will load it, and the two can no longer disagree.

```sh
$JENA/bin/riot --validate file.ttl && echo "Jayhawk will load this"
```

This used to be a real trap and is worth knowing if you meet older notes. Jayhawk parsed
through Serd, which resolves a datatype CURIE against a **process-global** prefix registry
rather than the document's own `@prefix` lines — so `"122.1"^^mine:myDecimal` in a file that
declares `mine:` locally would pass `riot --validate` and then throw `KeyError` in Julia. That
whole class of failure went away with the parser; it now lives in `RdfMaterializer`, which
still parses through Serd and still has it.

To confirm a file loads, load it — the store is the only opinion that counts:

```julia
using Jayhawk
load_file!("file.ttl")            # Turtle, TriG, N-Triples; syntax from the extension
```

A parse failure surfaces as an HTTP 400 from Fuseki with Jena's own message — line, column
and all — which is strictly better diagnostics than the old `SerdException`, which carried
only a status enum with no position.

**TriG, not Turtle, for rules.** A pattern *is* its named graph, so a rule instance cannot be
expressed in Turtle at all. `riot --validate` infers syntax from the extension; give rule
files a `.trig` extension or it will reject legal content.

## Other tools in the box

`$JENA/bin/` also has `shacl`, `arq` (local SPARQL over files), `rsparql` (remote),
`update`, `infer`, `schemagen`, and the `tdb2.*` loaders. For querying a running server
see the `sparql` skill.

Converting between syntaxes is `riot --output=FMT` where FMT is `ntriples`, `turtle`,
`nquads`, `trig`, `rdfxml`, `jsonld`. `--formatted=FMT` pretty-prints instead of
streaming (uses more memory).
