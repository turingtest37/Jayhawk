loadclasses = """
PREFIX gist: <https://ontologies.semanticarts.com/gist/>
PREFIX ebox: <http://www.semanticweb.org/doug/ontologies/ebox#>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
PREFIX sh: <http://www.w3.org/ns/shacl#>

CONSTRUCT
{
	?s a owl:Class .
}
WHERE
{
    GRAPH <urn:ontology> { 
        ?s a owl:Class .
        FILTER(!ISBLANK(?s))
    }
}
"""


loadobjprops = """
PREFIX gist: <https://ontologies.semanticarts.com/gist/>
PREFIX ebox: <http://www.semanticweb.org/doug/ontologies/ebox#>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
PREFIX sh: <http://www.w3.org/ns/shacl#>

CONSTRUCT
{
	?s a owl:ObjectProperty .
}
WHERE
{
    GRAPH <urn:ontology> { 
        ?s a owl:ObjectProperty . 
    }
}
"""

loaddataprops = """
PREFIX gist: <https://ontologies.semanticarts.com/gist/>
PREFIX ebox: <http://www.semanticweb.org/doug/ontologies/ebox#>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
PREFIX sh: <http://www.w3.org/ns/shacl#>

CONSTRUCT
{
	?s a owl:DatatypeProperty .
}
WHERE
{
    GRAPH <urn:ontology> { 
        ?s a owl:DatatypeProperty . 
    }
}
"""

loadsubclasses = """
PREFIX gist: <https://ontologies.semanticarts.com/gist/>
PREFIX : <http://www.semanticweb.org/doug/ontologies/ebox#>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
PREFIX sh: <http://www.w3.org/ns/shacl#>

construct
{
	?s rdfs:subClassOf ?o .
}
where
{
    GRAPH <urn:ontology> { 
        ?s rdfs:subClassOf+ ?o 
        FILTER(?s != ?o)
        FILTER(!ISBLANK(?o))
        FILTER(!ISBLANK(?s))        
    }
}
"""

load_model_instances = """
PREFIX gist: <https://ontologies.semanticarts.com/gist/>
PREFIX ebox: <http://www.semanticweb.org/doug/ontologies/ebox#>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
PREFIX sh: <http://www.w3.org/ns/shacl#>
#PREFIX : <http://data.ebox.ca/id/>

CONSTRUCT
{
    ?s a ?class ;
      ?p ?o .
}
WHERE { 
    GRAPH <urn:ontology> {
       ?s a owl:NamedIndividual, ?class ;
      ?p ?o.
    }
    FILTER(!STRSTARTS(STR(?p),STR(rdfs:)))
    FILTER(!STRSTARTS(STR(?p),STR(skos:)))

    FILTER(!STRSTARTS(STR(?o),STR(owl:)))
    FILTER(!STRSTARTS(STR(?class),STR(owl:)))
} order by ?p
"""

blank_objects = """
PREFIX gist: <https://ontologies.semanticarts.com/gist/>
PREFIX : <http://www.semanticweb.org/doug/ontologies/ebox#>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
PREFIX sh: <http://www.w3.org/ns/shacl#>

construct
{
	?s rdfs:subClassOf ?o .
}
where
{
    GRAPH <urn:ontology> { 
        ?s rdfs:subClassOf+ ?o 
        FILTER(?s != ?o)
        FILTER(ISBLANK(?o))
        FILTER(!ISBLANK(?s))        
    }
}

ORDER BY ?s
"""

load_typed_obj_props = 
"""
CONSTRUCT { ?s ?prop ?o }
{ 
    GRAPH <urn:ontology> {
        ?s rdfs:subClassOf ?rest .
        ?rest a owl:Restriction ;
            owl:onProperty ?prop ;
        .
        {?rest owl:someValuesFrom ?o} UNION {?rest owl:allValuesFrom ?o}
        FILTER(!ISBLANK(?o))
    }
}
ORDER BY ?prop ?s
"""