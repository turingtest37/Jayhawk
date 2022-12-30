using URIs
using Mustache
using HTTP
using JSON
using Dates

import EzXML: XMLDocument, parsexml, findall, namespaces, namespace

# include("namespaces.jl")
# include("constants.jl")
# include("rdf.jl")
"String representation of the graph store's SPARQL query service URL."
const spqservice = ("JAYHAWK_SPARQL_SERVICE" in ARGS) ? ARGS["JAYHAWK_SPARQL_SERVICE"] : "http://127.0.0.1:7200/repositories/ebox"

"String representation of the graph store's SPARQL update service URL."
const spqupdservice = ("JAYHAWK_UPDATE_SERVICE" in ARGS) ? ARGS["JAYHAWK_UPDATE_SERVICE"] : spqservice * "/statements"


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
      resp = r["results"]["bindings"]
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
