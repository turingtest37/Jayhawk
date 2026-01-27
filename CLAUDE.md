# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Jayhawk is a Julia library that bridges RDF/OWL ontologies with Julia's type system. It dynamically generates Julia types and functions from RDF data, enabling graph-based, data-centric applications using semantic web technologies.

## Commands

**Run tests:**
```bash
julia test/runtests.jl
```

**From Julia REPL:**
```julia
include("test/runtests.jl")
```

## Architecture

### Two-Pass Compilation Model

Jayhawk uses a two-pass approach to compile RDF into Julia:

1. **First Pass**: Parses RDF/Turtle data via `make_from_rdf()`, creating Julia types and functions. Properties referencing undefined types are queued as "futures."

2. **Second Pass**: `build_pass_two!()` processes all queued futures, resolving forward references after all types are defined.

### Core Data Structure: TraceLog

`TraceLog` is the central state manager with:
- `ldict`: Local dictionary mapping URIs to Julia functions/types
- `rdict`: Resource dictionary mapping URIs to RDF resource objects (owl_Class, owl_ObjectProperty, etc.)
- `entries`: Log of all created TLogEntry records
- `futures`: Queue of deferred function calls (tuples of predicate, subject, object)

### Key Entry Points

- `initialize()` → Creates a new TraceLog with the global resource_dict
- `make_from_rdf(turtle_string, tracelog)` → Main parsing entry point
- `build_model()` → Builds complete model from SPARQL endpoint
- `_make_anything(triple, tracelog)` → Dispatcher for individual RDF statements

### Type Hierarchy

- `RORB = Union{Resource, Blank}` — Used throughout for RDF subjects/objects
- `Unknown` — Placeholder for types not yet defined
- `owl_Class`, `owl_ObjectProperty`, `owl_DatatypeProperty` — RDF type wrappers

### URI to Symbol Mapping

`makeqname()` converts URIs to Julia identifiers:
- `owl:Class` → `owl_Class`
- `gist:Category` → `gist_Category`

Requires prefix registration via `add_prefix!()`. Unregistered prefixes throw `KeyError`.

### Dynamic Code Generation

Uses Julia's `eval()` extensively to create types and multi-dispatch functions at runtime based on RDF predicates and their argument types.

## External Dependencies

- **Serd**: RDF/Turtle parsing (from Serd.jl)
- **SPARQL endpoint**: Default at `http://127.0.0.1:7200/repositories/ebox`
  - Configure via `JAYHAWK_SPARQL_SERVICE` and `JAYHAWK_UPDATE_SERVICE` environment variables

## Source Structure

- `Jayhawk.jl` — Module definition, exports, `build_model()`
- `tracelog.jl` — TraceLog data structure
- `build.jl` — Core compilation logic (`make_from_rdf`, `_make_anything`, property generation)
- `rdf.jl` — RDF type definitions, URI utilities
- `rdf_type.jl` — Handler for `rdf:type` statements (creates Julia types from owl:Class)
- `rdfs_subClassOf.jl` — Handles inheritance relationships
- `sparql.jl` — SPARQL query templates
- `sparqlclient.jl` — HTTP client for SPARQL endpoints
