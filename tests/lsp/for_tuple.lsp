# A `for` that takes each element apart: its names hover where they are
# bound and where they are used, go to where they are bound, are renamed
# with every use and are coloured; a pattern that may not match is
# diagnosed at the `for`.
initialize
open for_tuple.pyk
idle
hover for_tuple.pyk 2:6
hover for_tuple.pyk 2:9
hover for_tuple.pyk 3:18
definition for_tuple.pyk 3:18
definition for_tuple.pyk 3:23
request textDocument/rename {"textDocument": {"uri": "$URI(for_tuple.pyk)"}, "position": {"line": 1, "character": 5}, "newName": "count"}
request textDocument/semanticTokens/full {"textDocument": {"uri": "$URI(for_tuple.pyk)"}}
change for_tuple.pyk
for Some(x) in [Some(1)]:
    print(x)
.
idle
change for_tuple.pyk
for (a, b) in [1, 2]:
    print(a)
.
idle
shutdown
exit
