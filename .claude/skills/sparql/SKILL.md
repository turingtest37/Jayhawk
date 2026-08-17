---
name: sparql
description: Run SPARQL queries and updates against this project's Apache Jena Fuseki triplestore, and manage the local test server. Use when you need to query loaded ontology data, run a SPARQL update, load Turtle into a named graph, start or stop the test server, or exercise Jayhawk's Julia SPARQL client against a real endpoint.
---

# SPARQL against Apache Jena Fuseki

## The test server

```sh
./bin/fuseki-test.sh start    # in-memory server, dataset /jayhawk, port 3040
./bin/fuseki-test.sh load     # gistAcct3.0.0.ttl into <urn:ontology>  (919 triples)
./bin/fuseki-test.sh status   # up/down + triple count; exit 1 when down
./bin/fuseki-test.sh reset    # DROP ALL, server stays up
./bin/fuseki-test.sh stop
./bin/fuseki-test.sh url      # prints the query endpoint
```

Everything is in memory and dies with the process — no TDB2 files, no state between
runs. Override with `FUSEKI_TEST_PORT` / `FUSEKI_TEST_DATASET`.

**Do not start the server with the shipped `fuseki-server` script.** It sets
`FUSEKI_BASE="${FUSEKI_BASE:-$PWD/run}"`, which either scatters a `run/` directory into
the working directory or — launched from the install dir — mounts the pre-existing 192MB
`FakeMoney` and `moneygraph` TDB2 datasets next to yours. The rig launches
`FusekiMainCmd` via `java -cp` instead, which touches no `run/` directory at all.

## Endpoints — verified, not assumed

With dataset `/jayhawk` on port 3040:

| purpose | URL |
|---|---|
| query | `http://localhost:3040/jayhawk` |
| update | `http://localhost:3040/jayhawk/update` |
| Graph Store read/write | `http://localhost:3040/jayhawk/data` |
| Graph Store read-only | `http://localhost:3040/jayhawk/get` |

**Query is the bare dataset path.** `/jayhawk/sparql` and `/jayhawk/query` both return
**404** under `FusekiMainCmd`, and so does `/$/ping` — the admin routes only exist under
the full `FusekiServerCmd`. The readiness probe is therefore an `ASK`, not a ping.

Fuseki differs from the GraphDB setup this project used previously, where query was
`/repositories/ebox` and update was `<base>/statements`.

## Three ways to query — pick deliberately

### curl + jq — fastest, no startup cost

```sh
B=http://localhost:3040/jayhawk
curl -s -G $B --data-urlencode 'query=SELECT ?c WHERE {
    GRAPH <urn:ontology> { ?c a <http://www.w3.org/2002/07/owl#Class> } } LIMIT 5' \
  -H 'Accept: application/sparql-results+json' | jq -r '.results.bindings[].c.value'
```

Use `--data-urlencode`, not `-d`; SPARQL is full of characters that must be escaped.
For CONSTRUCT, ask for `Accept: application/n-triples`.

Update (returns 204):

```sh
curl -s -X POST -H 'Content-Type: application/sparql-update' \
  --data-binary 'INSERT DATA { GRAPH <urn:demo> { <http://a/s> <http://a/p> "v" } }' \
  $B/update
```

Load a Turtle file into a named graph via the Graph Store Protocol:

```sh
curl -X POST -H 'Content-Type: text/turtle;charset=utf-8' \
  --data-binary @resource/gistAcct3.0.0.ttl \
  "$B/data?graph=urn%3Aontology"
```

### Jena's `rsparql` — formatted output for humans

```sh
/Users/doug/apache-jena-5.6.0/bin/rsparql \
  --service http://localhost:3040/jayhawk \
  'SELECT (COUNT(*) AS ?n) WHERE { GRAPH <urn:ontology> { ?s ?p ?o } }'
```

Prints an ASCII table. ~1s JVM startup. Use absolute paths — see the `ttl` skill for why
the PATH here cannot be trusted. `arq` is the same tool against local files rather than a
server.

### Julia — when the point is to exercise the library

```julia
Jayhawk.runsparql(query)                      # SELECT -> Vector of JSON bindings
Jayhawk.runsparql(query)                      # ASK    -> Bool
Jayhawk.qsparql(construct)                    # CONSTRUCT -> (statements, prefixes, base)
Jayhawk.usparql(update; dict = Dict())        # UPDATE, Mustache bindings via `dict`
```

Queries are Mustache templates: `runsparql(q; m = Dict("val" => "x"))` fills `{{val}}`.

## Configuration is frozen at module load

`spqservice` and `spqupdservice` in `src/sparqlclient.jl` are `const`, initialised from
`ENV` when the module loads. **The environment must be set before `using Jayhawk`** —
setting it afterwards has no effect and there is no runtime setter.

```sh
JAYHAWK_SPARQL_SERVICE=http://localhost:3031/other julia --project=. script.jl
```

Defaults are `http://localhost:3040/jayhawk` and `<base>/update`, matching the rig.

## The `urn:ontology` convention

Every query constant in `src/sparql.jl` hardcodes `GRAPH <urn:ontology>`, and
`fuseki-test.sh load` puts the fixtures there. Keep new queries consistent with it.

Those constants are **not usable as-is**: none are exported, and their only consumer,
`src/test.jl`, is never `include`d by `src/Jayhawk.jl` — it is dead code. Read them for
reference, then write the query inline rather than calling a name that will not resolve.
(`load_instance_defns` is also defined twice there, at lines 19 and 53; the second wins.)

## Integration tests

```sh
./bin/fuseki-test.sh start
JAYHAWK_TEST_SPARQL=1 julia --project=. test/runtests.jl
```

`test/sparql_integration.jl` is opt-in. Without `JAYHAWK_TEST_SPARQL` it is not loaded at
all, so the default suite stays hermetic and ~6 seconds. **Keep it that way** — never add
a network dependency to the default path.

Those tests build and drop their own `<urn:jayhawk:integration-test>` graph, so they do
not depend on `load` having run and do not disturb `<urn:ontology>`.

## Gotchas that have already cost time

- **`riot --count` writes to stderr**, so `$(... 2>/dev/null)` is empty. See `ttl`.
- **Blank nodes appear where you expect IRIs.** `?c a owl:Class` against the loaded
  fixtures returns `{"type":"bnode","value":"b0"}` as its first result — **52 of the
  classes in `<urn:ontology>` are blank nodes**. Add `FILTER(!isBlank(?c))` when you want
  only named classes.
- Three bugs in the Julia client were fixed only recently — `qsparql` sent the wrong
  Accept header and fed JSON to a Turtle parser, `usparql` passed an argument
  positionally and threw `MethodError` before ever reaching the server, and `runsparql`
  assumed every JSON response had a `results` key so all `ASK` queries threw `KeyError`.
  If something in that file misbehaves, suspect the client before the server.
