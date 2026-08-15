# Phase 2 of three: generate.
#
# Pure. SchemaModel -> Expr. Nothing is evaluated here, so the generated code can be
# inspected, diffed and tested without running it.
#
# The TraceLog is a *required argument* of every generated method. It used to be
# interpolated in as a default (`tl::TraceLog = $tl`) and, worse, referenced directly in
# some method bodies, which meant generated code wrote into whichever TraceLog happened
# to trigger compilation rather than the one it was handed.

"""
Struct, constructors and rdf_type methods for one owl:Class.
"""
function class_expr(suri::Resource)
    nm = Symbol(makeqname(suri))
    quote
        # `uri::RORB`, not `uri::Resource`: an instance of a user-defined class can be a
        # blank node. `[ a ex:Widget ]` is ordinary Turtle, and `_:x a ex:Widget` used to
        # throw MethodError and be swallowed by run_data!'s catch -- worse than the
        # bootstrap types' silent Unknown, because the triple was dropped outright.
        # Widening the method alone is not enough; construction would fail instead of
        # dispatch. The hand-written bootstrap structs in rdf.jl already use RORB.
        struct $nm
            uri::RORB
            in::Dict
            out::Dict
            types::Vector{Resource}
        end

        $nm(uri::String) = $nm(Resource(uri))
        $nm(u::RORB) = $nm(u, Dict(), Dict(), Resource[])
        # convert a previously-seen Unknown into this type
        $nm(u::Unknown) = $nm(u.uri, u.in, u.out, u.super)
        export $nm

        rdf_type(s::Unknown, ::Type{$nm}, tl::TraceLog) = store_local!(tl, $nm(s), s.uri)

        function rdf_type(r::RORB, ::Type{$nm}, tl::TraceLog)
            # if this URI was seen before, reuse it -- it may still be an Unknown
            _instance = get!(tl.ldict, r) do
                get(tl.rdict, r, $nm(r))
            end
            store_local!(tl, _instance isa Unknown ? $nm(_instance) : _instance, r)
        end
    end
end

"""
Methods for one owl:ObjectProperty.
"""
function objprop_expr(suri::Resource)
    nm = Symbol(makeqname(suri))
    quote
        function $nm(s::Resource, o::Resource, tl::TraceLog)
            subj = retrieve(tl, s)
            obj = retrieve(tl, o)
            # link subject and object by the property URI, in both directions
            hasfield(typeof(subj), :out) && (subj.out[s] = o)
            hasfield(typeof(obj), :in) && (obj.in[s] = o)
            $nm(subj, obj, tl)
        end

        $nm(s::Unknown, o, tl::TraceLog) = store_local!(tl, o, s.uri)
        $nm(s::Resource, o, tl::TraceLog) = store_local!(tl, o, s)
        # fallback for subjects already realised as a generated class instance
        $nm(s, o, tl::TraceLog) = store_local!(tl, o, hasproperty(s, :uri) ? s.uri : s)
        export $nm
    end
end

"""
Methods for one owl:DatatypeProperty.
"""
function dataprop_expr(suri::Resource)
    nm = Symbol(makeqname(suri))
    quote
        function $nm(s::Resource, obj::Literal, tl::TraceLog)
            store_local!(tl, s, obj.value)
            $nm(retrieve(tl, s), obj, tl)
        end

        function $nm(subj::Unknown, obj::Literal, tl::TraceLog)
            subj.out[$suri] = obj
        end

        function $nm(subj, obj::Literal, tl::TraceLog)
            hasfield(typeof(subj), :out) && (subj.out[$suri] = obj)
        end
        export $nm
    end
end

"""
Methods for a property that was only ever seen in use, with no rdf:type declaration.
Kept deliberately general: neither subject nor object type is known from the schema.
"""
function inferred_prop_expr(suri::Resource, literal_valued::Bool)
    nm = Symbol(makeqname(suri))
    if literal_valued
        quote
            function $nm(subj::RORB, obj::Literal, tl::TraceLog)
                resolved = retrieve(tl, subj)
                add_entry!(tl, subj, $suri, obj, $nm)
                store_local!(tl, obj.value, subj)
                hasfield(typeof(resolved), :out) && (resolved.out[$suri] = obj)
            end
            $nm(subj::RORB, obj, tl::TraceLog) = add_entry!(tl, subj, $suri, obj, $nm)
            export $nm
        end
    else
        quote
            $nm(subj::RORB, obj::RORB, tl::TraceLog) = add_entry!(tl, subj, $suri, obj, $nm)
            $nm(subj::RORB, obj, tl::TraceLog) = add_entry!(tl, subj, $suri, obj, $nm)
            export $nm
        end
    end
end

"""
    generate(m::SchemaModel; mod = Jayhawk, skip_existing = true) -> Expr

Build one block containing every definition the model needs.

With `skip_existing` (the default) anything already defined in `mod` is left alone --
that is what makes a second run of the same RDF pure execution rather than
recompilation. Hand-written functions such as `rdf_type` and `rdfs_subClassOf` are
protected by the same check.
"""
function generate(m::SchemaModel; mod::Module = @__MODULE__, skip_existing::Bool = true)
    block = Expr(:block)
    exists(nm) = skip_existing && _defined(mod, nm)

    for (uri, c) in m.classes
        exists(c.name) && continue
        push!(block.args, class_expr(uri))
    end

    for (uri, p) in m.properties
        exists(p.name) && continue
        e = p.kind === :object        ? objprop_expr(uri)               :
            p.kind === :datatype      ? dataprop_expr(uri)              :
            p.kind === :annotation    ? dataprop_expr(uri)              :
            p.kind === :inferred_data ? inferred_prop_expr(uri, true)   :
                                        inferred_prop_expr(uri, false)
        push!(block.args, e)
    end

    block
end

export generate, class_expr, objprop_expr, dataprop_expr, inferred_prop_expr
