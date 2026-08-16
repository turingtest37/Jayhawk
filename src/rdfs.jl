# rdfs:label and rdfs:comment reach the materialiser as ordinary data, so a method has to
# exist or `run_data!` counts every one of them as an unmatched triple. They deliberately do
# nothing: the label of a class is not something the generated Julia type needs to carry.
#
# Kept as stubs rather than deleted for exactly that reason -- deleting them does not remove
# the triples, it only makes them look like failures.

function rdfs_label(s, text, tl::TraceLog)
    @debug "rdfs_label $s $text"
    return nothing
end

function rdfs_comment(s, text, tl::TraceLog)
    @debug "rdfs_comment $s $text"
    return nothing
end
