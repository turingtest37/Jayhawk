#! /bin/sh
repositoryID="ebox"
ebox="/Users/doug/dev/Ebox/public/resource/ebox.ttl"
jayhawk="/Users/doug/dev/Ebox/public/resource/jayhawk.ttl"
gistSW="/Users/doug/dev/gistSW/gistSW0_1_0.ttl"
gistResource="/Users/doug/dev/gistSW/gistResource0_1_0.ttl"
gistMedia="/Users/doug/dev/gist11.1.0_webDownload/gistMediaTypes11.1.0.ttl"
gist="/Users/doug/dev/gist11.1.0_webDownload/gistCore11.1.0.ttl"

# graph="$2"
# file="$3"
# echo "$repositoryID" "$graph" "$file"
# curl -v -X DELETE "http://localhost:7200/repositories/$repositoryID/rdf-graphs/$graph"

# Clear the urn:ontology named graph
curl -v -X POST "http://localhost:7200/repositories/ebox/statements?update=CLEAR%20GRAPH%20%3Curn%3Aontology%3E"

# Insert into named graph
curl -v -X POST -H "Content-Type: text/turtle;charset=utf-8" --upload-file "{$jayhawk,$gistSW,$gistResource,$gistMedia,$gist}" "http://localhost:7200/repositories/ebox/rdf-graphs/service?graph=urn%3Aontology"
