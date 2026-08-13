using URIs
using Mustache
using HTTP
using JSON
using Dates

import EzXML: XMLDocument, parsexml, findall, namespaces, namespace

# include("namespaces.jl")
# include("constants.jl")
# include("rdf.jl")
# These read the environment, not `ARGS`. They used to be written
# `("JAYHAWK_SPARQL_SERVICE" in ARGS) ? ARGS["JAYHAWK_SPARQL_SERVICE"] : default`, which
# never threw only because `in` over `ARGS` (a Vector{String}) is always false for a
# name=value lookup, so the ternary always took the default branch and the indexing --
# which would have thrown, ARGS not being indexable by String -- was never reached. The
# endpoint was therefore hardcoded no matter what the caller set.
#
# Both are `const`, evaluated when the module loads, so the variables must be set
# before `using Jayhawk`.

# Defaults target Apache Jena Fuseki, which replaced GraphDB as this project's store.
# The two stores spell their endpoints differently, and only the query URL is shared:
#
#   Fuseki    query  http://host:3030/<dataset>          update  <base>/update
#   GraphDB   query  http://host:7200/repositories/<id>  update  <base>/statements
#
# Fuseki's query service really is the bare dataset path -- `<base>/sparql` returns 404
# under FusekiMainCmd, which is what resource/fuseki-test.sh launches.
#
# For GraphDB, set both variables explicitly:
#   JAYHAWK_SPARQL_SERVICE=http://127.0.0.1:7200/repositories/ebox
#   JAYHAWK_UPDATE_SERVICE=http://127.0.0.1:7200/repositories/ebox/statements

"String representation of the graph store's SPARQL query service URL."
const spqservice = get(ENV, "JAYHAWK_SPARQL_SERVICE", "http://localhost:3030/jayhawk")

"String representation of the graph store's SPARQL update service URL."
const spqupdservice = get(ENV, "JAYHAWK_UPDATE_SERVICE", spqservice * "/update")


# const tTurtle           = "text/turtle;charset=utf-8"
# const tRDF              = "application/rdf+xml"
# const tText             = "text/plain"
# const tNTriples         = "application/n-triples"
# const tNQuads           = "application/n-quads"
# const tJSONLD           = "application/ld+json"
# const tTrig             = "application/trig"
# const tSparqlResultsX   = "application/sparql-results+xml"
# const tSparqlResultsJ   = "application/sparql-results+json"
# const tAppJSON          = "application/json"
# const tAppXML           = "application/xml"
# const tSparqlResultsTSV = "application/sparql-results+tsv"
# const tSparqlResultsCSV = "application/sparql-results+csv"
# const tSparqlUpdate     = "application/sparql-update"
# const tWWWForm          = "application/x-www-form-urlencoded"
# const tSparqlQuery      = "application/sparql-query"

QHEADERS = Dict(
    "Content-Type" =>  "application/sparql-query",
    "Accept" => "application/sparql-results+json, */*;q=0.1"
)

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

# Creates a URL-compatible query string for SPARQL requests.
# `http://host/path?query=uri_encoded_sparql` 
# 
# where the given content is interpreted as a Mustache template
# and rendered using the provided Dictionary 
# of key=value pairs, before being URI-encoded for transmission over the
# internets.
buildquerystr(content::String, m::Dict) = string("query=",URIs.escapeuri(Mustache.render(content, m)))

buildpostbody(content::String, m::Dict) = Mustache.render(content, m)

buildqueryfile(filename::String, m::Dict) = buildquerystr(Mustache.load(filename), m)

function extract(b::Dict{String,Any})
  haskey(b,"type") && b["type"] == "uri" && haskey(b,"value") && (return URIs.URI(b["value"]))
  haskey(b,"type") && b["type"] == "literal" && haskey(b,"value") && (return haskey(b, "datatype") ? parse(lookup[b["datatype"]], b["value"]) : b["value"])
  return nothing
end

"""Creates an extraction function for the given bindings dictionary b such that a call to xq(name) retrieves b[name])"""
xq(b::Dict) = (s)->extract(get(b,s,Dict{String,Any}()))
xq(bl::Vector) = xq.(bl)


"This is the primary interface to the graph server, "
function runsparql(spq::String, update=false; m::Dict = Dict(), qheaders=QHEADERS, updheaders=UPDHEADERS)
  # payload = buildquerystr(fetchalldsqpq, m)
  resp = nothing
  if update
    resp = HTTP.post(spqupdservice, updheaders, buildpostbody(spq, m))
    resp = nothing
  else
    resp = HTTP.get(spqservice, qheaders; query=buildquerystr(spq, m))
    h = Dict(resp.headers)
    ct = h["Content-Type"]
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
  end
  @debug "resp" resp
  return resp
end


function objfromdict(T::Type, r::Dict)
  res = T[]
  @debug "building for type T from dict " T r

  for k in keys(r)
      local uri = k
      # @debug "uri" uri
      local predd = r[k]
      # @debug "pred dict" predd
      local ext = predd
      # @debug "ext" ext
      local rid = haskey(ext, p_rid) ? ext[p_rid] : localname(uri)
      # @debug "rid" rid
      obj = @eval $(T)($uri,$rid,$ext)
      # @debug "obj" obj
      push!(res, obj)
  end
  res
end

build(T::Type, doc) = objfromdict(T, parsent(doc))
export build

"""
    qsparql(query) -> (statements, prefixes, baseuri)

Run a CONSTRUCT (or DESCRIBE) query and parse the resulting graph.

Must ask for N-Triples. This used to call `runsparql(query)`, which sends the default
`QHEADERS` -- `Accept: application/sparql-results+json` -- so the server returned a
SPARQL results document and Serd was handed JSON to parse as Turtle, failing with
`SERD_ERR_BAD_SYNTAX` ("bad verb" at line 1 col 5). `QHEADERSCONS` was defined for
exactly this purpose and never used.

Parses from the string rather than a temp file; the old `tempname()` was never removed.
"""
function qsparql(query::String)
  read_rdf_string(runsparql(query; qheaders=QHEADERSCONS))
end

"""
    usparql(update; dict=Dict())

Run a SPARQL Update.

`dict` supplies Mustache template bindings. It has to go to the `m` *keyword* --
`runsparql(upd, true, dict)` passed it as a third positional argument to a function that
accepts two, so every call to `usparql` died with a `MethodError` before reaching the
server.
"""
function usparql(upd::String; dict=Dict())
  runsparql(upd, true; m=dict)
end
