"""
    Jayhawk

Graph patterns as graph-to-graph computation: compile RDF patterns to SPARQL, run them
against a triplestore, record what happened, and undo it.

A rule is a pair of named graphs -- a match pattern **L** and a construct pattern **R** --
which `compile_rule` turns into a `CONSTRUCT` or a `DELETE…INSERT…WHERE`. A SPARQL Update of
that shape *is* a single-pushout graph rewrite, so matching, replacement and atomicity come
from the store rather than from a hand-built rewriting engine.

The engine works in absolute IRIs throughout. It never derives Julia types from an ontology
and never calls `Core.eval`.

**Split from the materialiser.** Everything that parsed RDF into live Julia types -- the
original Jayhawk: `analyze`/`generate`/`install!`, `TraceLog`, `expand_uris`, `makeqname`,
the global prefix registry -- now lives in `RdfMaterializer`. The two engines shared no code,
only a module, and keeping them together forced every consumer of this package to inherit the
materialiser's dependency on a private unpublished fork of Serd. **Jayhawk no longer depends
on Serd at all.** Terms come back as SPARQL Results JSON and are modelled by `src/term.jl`,
which keeps the literal datatypes that Serd's parser discards -- and a datatype is how this
engine marks a variable, so that distinction is load-bearing rather than cosmetic.
"""
module Jayhawk

using Logging
using URIs
using Dates
using AutoHashEquals

include("term.jl")
include("sparqlclient.jl")
include("compile.jl")
include("harness.jl")
include("mcp.jl")

end # module Jayhawk
