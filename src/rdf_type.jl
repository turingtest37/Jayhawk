"""
Starting point for all calls to rdf_type
"""
function rdf_type(s::Resource, o::Resource, tl::TraceLog)
    @debug "rdf_type($s, $o)"
    oobj = retrieve!(tl, o, )
    objs = Symbol(makeqname(o))
    if isdefined(@__MODULE__, objs)
        # the problem is always what do we do with this particular type of value returned?
        # 
        try
            oobj = @eval $objs
        catch e
            @warn objs e
        end 
    end
    # sobj = retrieve!(tl, s)
    @debug "Calling rdf_type($s, $oobj)..."
    rdf_type(s, oobj, tl)
    if (s == Serd.RDF.Resource("http://www.w3.org/2002/07/owl#TransitiveProperty"))
        error("Can't handle transitive properties. Stopping here.")
    end
end

rdf_type(u::Unknown, ::Type{owl_Class}, tl::TraceLog) = rdf_type(u.uri, owl_Class, tl)

# Create a Julia type from an owl:Class
function rdf_type(suri::Resource, ::Type{owl_Class}, tl::TraceLog)
    nm = Symbol(makeqname(suri))
    @debug "rdf_type($suri owl_Class)"
    eval(
        quote
            struct $nm
                uri::Resource
                in::Dict
                out::Dict
                types::Vector{Resource}
            end
            # Constructor for new type
            function $nm(uri::String, in::Dict, out::Dict)
                $nm(uri,in,out,Resource($suri))
            end

            # convenience constructors
            $nm(uri::String) = $nm(Resource(uri))
            $nm(u::Resource) = $nm(u,Dict(),Dict(),Resource[])            
            # constructor to convert an Unknown into the new type
            $nm(u::Unknown) = $nm(u.uri, u.in, u.out, u.super)
        
            export $nm

            # store newly created class in resource and local dicts
            store_res!($tl, $nm, $suri)
            store_local!($tl, owl_Class($suri), $suri)

            # create and store a new instance of Type{$nm}
            rdf_type(s::Unknown, ::Type{$nm}, tl::TraceLog = $tl) = store_local!(tl, $nm(s), s.uri)

            # TODO FIX This
            """
            Function to instantiate the new type and store it.
            If the subject was previously seen and stored as an Unknown, convert into the new type.
            """
            function rdf_type(r::Resource, ::Type{$nm}, tl::TraceLog = $tl)
                @debug "rdf_type" r Type{$nm}
                # if we have already seen this URI, fetch it from the dictionary. It might be an Unknown
                _instance = get!(tl.ldict, r) do
                    # if not already defined, make a new instance and copy the Unknown stuff into it
                    # This also covers the case of a completely new, never seen before instance
                    get(tl.rdict, r, $nm(r))
                end
                # Store whatever we get back for r
                @debug "retrieved from dict:" _instance
                store_local!(tl, typeof(_instance)==Jayhawk.Unknown ? $nm(_instance) : _instance, r)
                @debug "new instance is " tl.ldict[r]
            end
        end
    )
    @info "Created type $nm."
    @info "Created function rdf_type(r::Resource, ::Type{$nm})"
end

# Transform a ObjectProperty into a Julia function
function rdf_type(suri::Resource, ::Type{owl_ObjectProperty}, tl::TraceLog)
    @debug "rdf_type($suri Type{owl_ObjectProperty})"
    nm = Symbol(makeqname(suri))

        eval(
        quote

            # TODO Change bodies of $nm

            # Entry point for calls to $nm function
            function $nm(s::Resource, o::Resource, tl::TraceLog = $tl)
                #fetch instantiated type from resource dictionary, else Unknown
                subj = retrieve!(tl, s)
                obj = retrieve!(tl, o)

                # TODO DOES IT EVEN MAKE SENSE TO STORE LINKS ????
                # link the subject and object by the property URI, in both directions
                subj.out[s] = o
                obj.in[s] = o

                try
                    $nm(subj, obj, tl)
                catch e
                    @error "Failed to call method." $nm subj obj e
                end
            end

            $nm(s::Unknown, o, tl::TraceLog = $tl) = store_local!($tl, o, s.uri)
            $nm(s::Resource, o, tl::TraceLog = $tl) = store_local!($tl, o, s)

            # register new function in resource dictionary
            store_res!($tl, $nm, $suri) 
            store_local!($tl, owl_ObjectProperty($suri), $suri) 
            export $nm
        end
        )
    @info "Created function $nm(subj::Union{Resource,Blank}, obj::Union{Resource,Blank})"
end

# Transform a DatatypeProperty into a Julia function
function rdf_type(suri::Resource, ::Type{owl_DatatypeProperty}, tl::TraceLog{T}) where {T<:AbstractDict}
    @debug "rdf_type($suri, Type{owl_DatatypeProperty})"
    nm = Symbol(makeqname(suri))
    eval(
        quote
            function $nm(suri::Resource, obj::Literal, tl::TraceLog)
                @debug $nm suri obj
                store_local!(tl, suri, obj.value)
                subj = retrieve!(tl, suri)
                @debug "retrieved from $suri " subj
                # subj.out[suri] = obj.val
                
                try
                    $nm(subj, obj.value, tl)
                catch e
                    @warn "Failed to call method." $nm subj obj.value e
                end
             end
            # Store the new function in the resource dictionary and export it
            function $nm(subj::Unknown, obj::Literal, tl::TraceLog)
                @debug "Function called: " $nm subj obj
                subj.out[$nm] = obj.val
            end
            # store in the Resource Dicts
            store_res!($tl, $nm, $suri)
            store_local!($tl, owl_DatatypeProperty($suri), $suri)
            export $nm
        end
    )
    @info "Created function $nm(subj::Resource, obj::Literal)"
end


function rdf_type(s::Resource, ::Type{owl_NamedIndividual}, tl::TraceLog)
    @debug "rdf_type $s Type{owl_NamedIndividual}"
end

# import Base.setindex!

function rdf_type(s::Resource, o::Unknown, tl::TraceLog)
    @debug "rdf_type" s o
    store_local!(tl, o, s)
    # @info "Added future for" rdf_type s o
end

function rdf_type(s::Unknown, o::Unknown, tl::TraceLog)
    @debug "rdf_type" s o
    store_local!(tl, o, s)
    # @info "Added future for" rdf_type s o
end

function rdf_type(s::Resource, ::Type{owl_Thing}, tl::TraceLog)
    @debug "rdf_type $s ::owl_Thing"
    store_local!(tl, owl_Thing(s), s)
end

function rdf_type(s::Resource, o::Blank, tl::TraceLog)
    @debug "rdf_type $s $o"
    store_local!(tl, o, s)
end

function rdf_type(b::Blank, ::Type{owl_Class}, tl::TraceLog)
    @debug "rdf_type($b , ::owl_Class)"
    store_local!(tl, owl_Class(b), b)
end

function rdf_type(b::Blank, o::Resource, tl::TraceLog)
    @debug "rdf_type $b $o"
    oobj = retrieve!(tl, o)
    rdf_type(b, oobj, tl)
end

function rdf_type(b::Blank, o::Unknown, tl::TraceLog)
    @debug "rdf_type $b $o"
    store_local!(tl, o, b)
end
