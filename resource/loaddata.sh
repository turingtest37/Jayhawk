#! /bin/sh

repositoryID="ebox"
file="/Users/doug/dev/Ebox/public/resource/ebox-d.ttl"

# Clear the default graph
# curl -v -X POST "http://localhost:7200/repositories/$repositoryID/statements?update=DROP%20DEFAULT"

# Insert into the default graph
# curl -v -H "Content-Type: text/turtle;charset=utf-8" --data-binary @"$file" "http://localhost:7200/repositories/$repositoryID/statements"

# Clear the urn:ontology named graph
curl -v -X POST "http://localhost:7200/repositories/ebox/statements?update=CLEAR%20GRAPH%20%3Curn%3Aapp%3Ainetsub%3E"

# Insert into named application graph
curl -v -X POST -H "Content-Type: text/turtle;charset=utf-8" --upload-file "{$file}" "http://localhost:7200/repositories/ebox/rdf-graphs/service?graph=urn%3Aapp%3Ainetsub"
