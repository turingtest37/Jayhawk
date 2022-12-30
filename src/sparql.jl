loadclasses = """
PREFIX owl: <http://www.w3.org/2002/07/owl#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
CONSTRUCT
{
    ?s a ?class .
}
WHERE { 
    GRAPH <urn:ontology> {
    {
        ?s a owl:Class, ?class .
    } 
    FILTER(!ISBLANK(?s))
    }
} order by ?s
"""
load_instance_defns = """
CONSTRUCT
{
    ?s a ?class .
}
WHERE { 
    GRAPH <urn:ontology> {
    ?s a owl:NamedIndividual.
    ?s a ?class .
    FILTER(!STRSTARTS(STR(?class),STR(owl:)))
    FILTER(!STRSTARTS(STR(?class),STR(rdfs:)))
    }
}
"""

loadobjprops = """
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>

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
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>

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
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>

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
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>

CONSTRUCT
{
    ?s ?p ?o .
}
WHERE { 
    GRAPH <urn:ontology> {
       ?s a owl:NamedIndividual ;
       ?p ?o.
       MINUS {?s rdf:type ?o}
    }
    FILTER(!STRSTARTS(STR(?p),STR(rdfs:)))
    FILTER(!STRSTARTS(STR(?p),STR(skos:)))
    FILTER(!STRSTARTS(STR(?o),STR(owl:)))
} order by ?p
"""

blank_objects = """
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>

CONSTRUCT
{
    ?s ?p ?o .
}
WHERE { 
    GRAPH <urn:ontology> {
       ?s a owl:NamedIndividual ;
       ?p ?o.
    }
#    FILTER(!STRSTARTS(STR(?p),STR(rdf:)))
     FILTER(!STRSTARTS(STR(?p),STR(rdfs:)))
    FILTER(!STRSTARTS(STR(?p),STR(skos:)))
#
#    FILTER(!STRSTARTS(STR(?o),STR(owl:)))
#    FILTER(!STRSTARTS(STR(?class),STR(owl:)))
} order by ?p
"""

load_typed_properties = 
"""
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>

CONSTRUCT { ?classOfSubject ?predicate ?classOrDatatypeOfObject }
#select *

{ 
    GRAPH <urn:ontology> {
        
        ?classOfSubject rdfs:subClassOf* ?classWithRestriction .  # restrictions apply to all subclasses
        ?classWithRestriction (rdfs:subClassOf|owl:equivalentClass) ?classExpression .
        
        {
            ?classExpression owl:oneOf ?instanceList .
            ?instanceList (rdf:first|rdf:rest)+ ?instance .
            ?instance ?predicate ?oo .
            BIND(IF(ISLITERAL(?oo),datatype(?oo),?unbound) AS ?classOrDatatypeOfObject)
            OPTIONAL {?oo rdf:type ?classOrDatatypeOfObject }
            
        }
        UNION
        {
            ?classExpression (owl:intersectionOf|owl:unionOf|rdf:first|rdf:rest)* ?restriction .        
            ?restriction rdf:type owl:Restriction .
            ?restriction owl:onProperty ?predicate .    
        }
                    
                    
        { ?restriction owl:onClass ?classOrDatatypeOfObject }   
        UNION 
        { 
        ?restriction owl:allValuesFrom|owl:someValuesFrom ?o  .
        ?o (owl:intersectionOf|owl:unionOf|rdf:first|rdf:rest)* ?classOrDatatypeOfObject . 
        }
        UNION
        { 
        ?restriction owl:hasValue/rdf:type ?classOrDatatypeOfObject . 
        FILTER(?classOrDatatypeOfObject != owl:NamedIndividual)
        }
        UNION
        {
        ?restriction owl:onDataRange ?classOrDatatypeOfObject .
        }

        FILTER(isUri(?classOrDatatypeOfObject))        # remove intermediate blank nodes
        FILTER(?classOrDatatypeOfObject != rdf:nil)
    }
} ORDER BY ?classOfSubject ?predicate
"""

# DO NOT USE
load_typed_obj_props = 
"""
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>

CONSTRUCT { ?s ?prop ?o }

{ 
    GRAPH <urn:ontology> {
        {   ?s rdfs:subClassOf ?rest }
        UNION
        {
        ?s owl:equivalentClass ?eqc .
        ?eqc a owl:Class ;
             owl:intersectionOf ?list.       
        ?list (rdf:first | rdf:rest)+ ?rest .
        }
        UNION
         {
        [] owl:equivalentClass ?eqc .
        ?eqc a owl:Class ;
            owl:intersectionOf ?list.
        ?list rdf:first+ ?s .
        ?list (rdf:first | rdf:rest)* ?rest .
        FILTER(ISIRI(?s))
        }
        
        ?rest a owl:Restriction ;
            owl:onProperty ?prop ;
        .
        {?rest owl:someValuesFrom ?o} UNION {?rest owl:allValuesFrom ?o} UNION {?rest owl:onClass ?o}

        FILTER(ISIRI(?prop))
        FILTER(ISIRI(?o))
        FILTER(?rest != rdf:nil)
 
    }
}
ORDER BY ?prop ?s
"""
