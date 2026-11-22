# A bare `return`, and statements on a header's own line: the names in
# them hover and are coloured; a bare `return` in a function returning a
# value is diagnosed at the `return`.
initialize
open return_bare.pyk
idle
hover return_bare.pyk 4:8
hover return_bare.pyk 4:17
hover return_bare.pyk 11:12
hover return_bare.pyk 12:9
request textDocument/semanticTokens/full {"textDocument": {"uri": "$URI(return_bare.pyk)"}}
change return_bare.pyk
def half(n: Int) -> Int:
    if n < 0: return
    n / 2
.
idle
shutdown
exit
