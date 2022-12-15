#! /bin/sh

repositoryID="ebox"
file="/Users/doug/dev/Ebox/public/resource/ebox-d.ttl"

# Clear the default graph
curl -v -X POST "http://localhost:7200/repositories/$repositoryID/statements?update=DROP%20DEFAULT"

# Insert into the default graph
curl -v -H "Content-Type: text/turtle;charset=utf-8" --data-binary @"$file" "http://localhost:7200/repositories/$repositoryID/statements"
