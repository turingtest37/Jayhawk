using URIs
using HTTP
using JSON
using Dates
using UUIDs

import EzXML: XMLDocument, parsexml, findall, namespaces, namespace

# Defaults target Apache Jena Fuseki, which replaced GraphDB as this project's store.
# The two stores spell their endpoints differently, and only the query URL is shared:
#
#   Fuseki    query  http://host:3030/<dataset>          update  <base>/update
#   GraphDB   query  http://host:7200/repositories/<id>  update  <base>/statements
#
# Fuseki's query service really is the bare dataset path -- `<base>/sparql` returns 404
# under FusekiMainCmd, which is what bin/fuseki-test.sh launches.
#
# These two remain `const` because `test/sparql_integration.jl` asserts their shape, and
# because they are the *default* only. Anything that needs a different server at runtime
# passes a `SparqlEndpoint` instead of mutating them -- see `set_endpoint!`.

"String representation of the graph store's SPARQL query service URL."
const spqservice = get(ENV, "JAYHAWK_SPARQL_SERVICE", "http://localhost:3040/jayhawk")

"String representation of the graph store's SPARQL update service URL."
const spqupdservice = get(ENV, "JAYHAWK_UPDATE_SERVICE", spqservice * "/update")

"""
Where to reach a triplestore, and how long to wait.

The engine takes this as an argument rather than reading a module-level `const`, because a
long-running MCP server may talk to more than one store and cannot re-`using` the package
to change endpoint.

`gsp` is the SPARQL 1.1 Graph Store Protocol endpoint, used to POST a `.trig` file straight
into the store. That is how the engine loads patterns: Jena parses TriG, Julia does not.
"""
struct SparqlEndpoint
    query::String
    update::String
    gsp::String
    timeout::Int
end

"""
    SparqlEndpoint(base; timeout = 30)

Build the Fuseki-shaped triple of URLs from one dataset base URL:
`<base>` for query, `<base>/update` for update, `<base>/data` for the Graph Store Protocol.
"""
SparqlEndpoint(base::AbstractString; timeout::Integer = 30) =
    SparqlEndpoint(String(base), String(base) * "/update", String(base) * "/data", Int(timeout))

const _DEFAULT_ENDPOINT =
    Ref(SparqlEndpoint(spqservice, spqupdservice, spqservice * "/data", 30))

"The endpoint used when a call does not name one."
endpoint() = _DEFAULT_ENDPOINT[]

"Replace the default endpoint for this process. Returns the new endpoint."
set_endpoint!(e::SparqlEndpoint) = (_DEFAULT_ENDPOINT[] = e)
set_endpoint!(base::AbstractString; timeout::Integer = 30) =
    set_endpoint!(SparqlEndpoint(base; timeout = timeout))

QHEADERS = Dict(
    "Content-Type" =>  "application/sparql-query",
    "Accept" => "application/sparql-results+json, */*;q=0.1"
)

# Headers for CONSTRUCT / DESCRIBE. No in-package caller since `qsparql` moved to
# RdfMaterializer at v0.4.0 -- this is kept because it is now the *replacement* for it:
#
#     runsparql(construct_query; qheaders = QHEADERSCONS)   -> N-Triples as a String
#
# N-Triples rather than Turtle or JSON because it is the one CONSTRUCT serialisation this
# package can hand back without parsing, and it carries `"0.0330"^^xsd:decimal` intact.
# `qsparql` asked for the wrong thing and then fed the result to a parser that dropped the
# datatype -- the exact loss this engine cannot afford.
QHEADERSCONS = Dict(
    "Content-Type" =>  "application/sparql-query",
    "Accept" => "application/n-triples, */*;q=0.1"
)

UPDHEADERS = Dict(
    "Content-Type" =>  "application/sparql-update",
    "Accept" => "application/sparql-results+json, */*;q=0.1"
)

spqparams() = Dict()
spqparams(d::Dict) = merge(spqparams(), d)

"""
    render_query(content, bindings) -> String

Substitute `{{name}}` for each supplied binding, and touch nothing else.

Deliberately *not* Mustache, though the delimiters are its. `{{` is legal SPARQL -- a nested
group pattern -- and Mustache reads it as a section, so rendering
`SELECT ?s WHERE { GRAPH <g> {{ ?s ?p ?o }} }` against any non-empty binding set deleted the
whole group as an unresolved section and left `SELECT ?s WHERE { GRAPH <g>  }`. That happened
to produce an HTTP 400; had the eaten group been an OPTIONAL or a FILTER it would have
returned a confidently wrong answer instead.

Plain replacement cannot do that: a brace pair that is not a supplied key is not a key, and
is left exactly as written.

A binding that matches nothing warns rather than raising. It is usually a typo, which is
worth saying out loud -- but passing a shared dictionary across several queries is a
reasonable thing to do, and refusing a harmless extra key would make templating hazardous
in a different direction.
"""
function render_query(content::AbstractString, bindings::AbstractDict)
    out = String(content)
    for (k, v) in bindings
        token = "{{$k}}"
        if occursin(token, out)
            out = replace(out, token => string(v))
        else
            @warn "binding matches nothing in the query; check for a typo" key = String(k) token
        end
    end
    out
end

buildquerystr(content::String, m::Dict) = string("query=", URIs.escapeuri(render_query(content, m)))

buildpostbody(content::String, m::Dict) = render_query(content, m)


"Raise a legible error instead of letting HTTP.jl's StatusError escape with the body buried."
function _http_error(e, what::AbstractString, url::AbstractString)
    if e isa HTTP.StatusError
        body = try String(e.response.body) catch; "<unreadable body>" end
        error("$what failed: HTTP $(e.status) from $url\n$(first(body, 2000))")
    end
    rethrow(e)
end

"""
    runsparql(spq, update=false; m=Dict(), ep=endpoint(), qheaders=QHEADERS, updheaders=UPDHEADERS)

The primary interface to the graph server.

Returns raw parsed JSON for SELECT (a `Vector` of binding `Dict`s) and `Bool` for ASK, an
`XMLDocument` for RDF/XML, and a `String` for N-Triples. `nothing` for updates.

Prefer [`select`](@ref) / [`ask`](@ref) / [`update!`](@ref) in new code: they return typed
`RDFTerm`s instead of raw JSON. This one keeps its untyped contract because the SPARQL
regression suite asserts against it directly.
"""
function runsparql(spq::String, update=false; m::Dict = Dict(), ep::SparqlEndpoint = endpoint(),
                   qheaders=QHEADERS, updheaders=UPDHEADERS)
  resp = nothing
  if update
    try
      HTTP.post(ep.update, updheaders, buildpostbody(spq, m); readtimeout = ep.timeout)
    catch e
      _http_error(e, "SPARQL update", ep.update)
    end
    return nothing
  end

  resp = try
    HTTP.get(ep.query, qheaders; query=buildquerystr(spq, m), readtimeout = ep.timeout)
  catch e
    _http_error(e, "SPARQL query", ep.query)
  end

  h = Dict(resp.headers)
  ct = get(h, "Content-Type", "")
  if contains(ct, "sparql-results+json")
    r = JSON.parse(resp.body |> String)
    # ASK returns {"head":{}, "boolean":true} -- no "results" key at all, so the
    # unconditional r["results"]["bindings"] threw KeyError on every ASK query.
    resp = haskey(r, "boolean") ? r["boolean"] : r["results"]["bindings"]
  elseif contains(ct, "application/rdf+xml")
    resp = parsexml(resp.body |> String)
  elseif contains(ct, "n-triples")
    resp = resp.body |> String
  end
  @debug "resp" resp
  return resp
end

# ---------------------------------------------------------------------------
# Typed layer -- what the engine uses
# ---------------------------------------------------------------------------

"""
    select(q; ep=endpoint(), bindings=Dict()) -> Vector{Dict{String,RDFTerm}}

Run a SELECT and return each solution as a name => `RDFTerm` mapping.

This is the datatype-faithful path. SPARQL Results JSON carries
`{"type":"literal","datatype":…}` and [`term_from_json`](@ref) keeps it, where the old
`extract` destroyed it -- it called `parse(lookup[b["datatype"]], …)` against a `lookup`
table that was never defined anywhere in the package, so every typed literal raised
`UndefVarError`.

Unbound variables are simply absent from a solution's dictionary, as in the JSON.
"""
function select(q::AbstractString; ep::SparqlEndpoint = endpoint(), bindings::AbstractDict = Dict())
    rows = runsparql(String(q); m = Dict(bindings), ep = ep)
    rows isa Bool && throw(ArgumentError("select() got an ASK response; use ask() instead"))
    [Dict{String,RDFTerm}(k => term_from_json(v) for (k, v) in row) for row in rows]
end

"""
    ask(q; ep=endpoint(), bindings=Dict()) -> Bool
"""
function ask(q::AbstractString; ep::SparqlEndpoint = endpoint(), bindings::AbstractDict = Dict())
    r = runsparql(String(q); m = Dict(bindings), ep = ep)
    r isa Bool || throw(ArgumentError("ask() expected a boolean response, got $(typeof(r))"))
    r
end

"""
    update!(q; ep=endpoint(), bindings=Dict()) -> Nothing

Run a SPARQL Update (INSERT / DELETE / DROP / LOAD).
"""
update!(q::AbstractString; ep::SparqlEndpoint = endpoint(), bindings::AbstractDict = Dict()) =
    runsparql(String(q), true; m = Dict(bindings), ep = ep)

"""
    load_graph!(content, graph_iri; ep=endpoint(), syntax="text/turtle") -> Nothing

PUT `content` into a named graph over the Graph Store Protocol, replacing whatever was
there. This is how patterns get into the store: **Jena parses TriG, Julia does not.**

For a TriG payload -- which names its own graphs -- POST to the *dataset* rather than to a
single graph; see [`load_dataset!`](@ref).
"""
function load_graph!(content::AbstractString, graph_iri::AbstractString;
                     ep::SparqlEndpoint = endpoint(), syntax::AbstractString = "text/turtle",
                     skolemize::Bool = false)
    url = string(ep.gsp, "?graph=", URIs.escapeuri(graph_iri))
    try
        HTTP.put(url, Dict("Content-Type" => syntax), String(content); readtimeout = ep.timeout)
    catch e
        _http_error(e, "Graph Store PUT", url)
    end
    # This targets one named graph, so the scope of the rewrite is exactly what was just
    # loaded. A TriG payload spans graphs and has no such scope, which is why
    # `load_dataset!` has no equivalent flag: call `skolemize!` on the graphs you meant.
    skolemize && skolemize!(; graph = graph_iri, ep = ep)
    nothing
end

"Namespace for Skolem IRIs minted from incoming blank nodes."
const SKOLEM_BASE = "urn:jayhawk:genid:"

"""
    skolemize!(; graph = nothing, base = SKOLEM_BASE * <fresh uuid> * ":", ep = endpoint())
        -> Int

Replace every blank node in `graph` (or in the whole dataset) with a Skolem IRI, and return
how many triples were rewritten.

RDF 1.1 §3.5 blesses this: a blank node is an existential, and naming it makes it an ordinary
constant that can be referenced, transported and compared. Two things specific to this engine
make it worth doing on the way in:

  * **An agent cannot refer to a blank node.** It has no IRI, so `explain_rule` can display
    one but `run_rule` and `undo_firing` cannot be pointed at it and no rule can be written
    about it. For a surface whose whole premise is "named, attributable, reversible", a node
    with no name sits outside the contract.
  * **Blank node labels do not survive a serialisation round trip.** Identity holds inside
    one store -- a firing graph, a tombstone and an undo all agree -- but a dump and reload
    renumbers them, so provenance recorded before an export stops resolving after the
    import.

`base` chooses the namespace and nothing more. It defaults to a fresh one per call, which is
the correct default rather than a convenience: blank nodes in two documents denote different
things, so two loads must not be merged by naming them alike.

**Skolem IRIs are not reproducible.** The label comes from the store's internal identifier
for the node, which is minted afresh on every parse, so loading the same file twice yields
two disjoint sets of IRIs even under one `base`. That is semantically right -- the two loads
really are two documents -- but it means these IRIs are stable going *forward* (an export
now carries them, and provenance keeps resolving) and cannot be used to recognise the same
node across a re-ingest. Making them reproducible would mean hashing each node's
surroundings, which is graph isomorphism.

Not for patterns. In a match pattern a Skolem IRI is a *constant*, so the pattern would match
one node that exists nowhere and the rule would silently never fire; in a construct pattern
`gistp:iriTemplate` already does the job, deterministically. See `check_no_blanks`.
"""
function skolemize!(; graph::Union{AbstractString,Nothing} = nothing,
                    base::AbstractString = string(SKOLEM_BASE, UUIDs.uuid4(), ":"),
                    ep::SparqlEndpoint = endpoint())
    scope = graph === nothing ? "?g" : "<$(check_iri(graph))>"
    b = check_iri(base)
    # STR() on a blank node is a type error in the SPARQL spec and lenient in Jena, where it
    # yields "_:label". That leniency is what lets this be one update instead of an export,
    # a text rewrite and a reload -- there is no standard way to name a blank node from
    # inside a query. STRAFTER drops the "_:" so the Skolem IRI reads cleanly.
    skolem(v) = "IRI(CONCAT(\"$b\", ENCODE_FOR_URI(STRAFTER(STR($v), \"_:\"))))"
    before = _count_blank(scope; ep = ep)
    update!("""
        DELETE { GRAPH $scope { ?s ?p ?o } }
        INSERT { GRAPH $scope { ?s2 ?p ?o2 } }
        WHERE {
          GRAPH $scope { ?s ?p ?o }
          FILTER(isBlank(?s) || isBlank(?o))
          BIND(IF(isBlank(?s), $(skolem("?s")), ?s) AS ?s2)
          BIND(IF(isBlank(?o), $(skolem("?o")), ?o) AS ?o2)
        }"""; ep = ep)
    remaining = _count_blank(scope; ep = ep)
    remaining == 0 || @warn(
        "skolemize!: $remaining triple(s) still carry a blank node. STR() on a blank node " *
        "is non-standard, so a store stricter than Jena will not support this.",
        graph = graph, remaining = remaining)
    before - remaining
end

function _count_blank(scope::AbstractString; ep::SparqlEndpoint = endpoint())
    rows = select("""
        SELECT (COUNT(*) AS ?n) WHERE {
          GRAPH $scope { ?s ?p ?o } FILTER(isBlank(?s) || isBlank(?o)) }"""; ep = ep)
    isempty(rows) ? 0 : parse(Int, (rows[1]["n"]::RDFLiteral).lexical)
end

"""
    load_dataset!(content; ep=endpoint(), syntax="application/trig") -> Nothing

POST a quad-bearing document (TriG, N-Quads) to the dataset endpoint, letting the payload
place its own triples into its own named graphs. Additive: existing graphs are merged with,
not replaced.
"""
function load_dataset!(content::AbstractString;
                       ep::SparqlEndpoint = endpoint(), syntax::AbstractString = "application/trig")
    try
        HTTP.post(ep.gsp, Dict("Content-Type" => syntax), String(content); readtimeout = ep.timeout)
    catch e
        _http_error(e, "Graph Store POST", ep.gsp)
    end
    nothing
end

"Read a file and load it as a dataset. Syntax is inferred from the extension."
function load_file!(path::AbstractString; ep::SparqlEndpoint = endpoint())
    syntax = endswith(path, ".trig")  ? "application/trig" :
             endswith(path, ".nq")    ? "application/n-quads" :
             endswith(path, ".nt")    ? "application/n-triples" : "text/turtle"
    load_dataset!(read(path, String); ep = ep, syntax = syntax)
end

# `qsparql` used to live here: a CONSTRUCT whose result was parsed by Serd. It moved to
# RdfMaterializer (src/sparql.jl) with the rest of the Serd-dependent half, because it was
# the single line in this file that made the engine need a private fork of Serd -- and it
# lost literal datatypes on every term it returned, which is exactly what this package
# cannot afford. Use `select` instead: it returns `RDFTerm`s with datatypes intact.

"""
    usparql(update; dict=Dict())

Run a SPARQL Update.

`dict` supplies {{name}} bindings, substituted by render_query. It has to go to the `m` *keyword* --
`runsparql(upd, true, dict)` passed it as a third positional argument to a function that
accepts two, so every call to `usparql` died with a `MethodError` before reaching the
server.
"""
function usparql(upd::String; dict=Dict(), ep::SparqlEndpoint = endpoint())
  runsparql(upd, true; m=dict, ep = ep)
end

export SparqlEndpoint, endpoint, set_endpoint!
export select, ask, update!, load_graph!, load_dataset!, load_file!, skolemize!
