using Serd

function buildfrom(f = "resource/gistAcct3.0.0.ttl")
    stmts, pfxs, buri = read_rdf_file(f)
    for s in stmts
        extract_type(s)
        extract_func(s)
    end

    eval(quote
        Base.$op(a::MyNumber) = MyNumber($op(a.x))
    end)


end

extract_type(s) = nothing

function extract_type(t::Triple)
    s, p, o = t.subject, t.predicate, t.object
    p == expand("rdf:type") || return nothing
    o
end

