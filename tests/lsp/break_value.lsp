# `break x` and `continue x`: the names in the value hover, go to their
# definitions, are found as references and renamed with the rest, and
# are coloured; a value the loop cannot carry, and one given to a loop
# carrying nothing, are diagnosed where they are written.
initialize
open break_value.pyk
idle
hover break_value.pyk 5:19
hover break_value.pyk 5:23
hover break_value.pyk 6:18
hover break_value.pyk 11:19
definition break_value.pyk 5:19
definition break_value.pyk 6:18
definition break_value.pyk 11:16
request textDocument/references {"textDocument": {"uri": "$URI(break_value.pyk)"}, "position": {"line": 2, "character": 34}, "context": {"includeDeclaration": true}}
request textDocument/rename {"textDocument": {"uri": "$URI(break_value.pyk)"}, "position": {"line": 8, "character": 15}, "newName": "total"}
request textDocument/semanticTokens/full {"textDocument": {"uri": "$URI(break_value.pyk)"}}
change break_value.pyk
counted = loop x = 1:
    if x > 3:
        break "done"
    x + 1
.
idle
change break_value.pyk
for x in [1, 2]:
    continue x
.
idle
shutdown
exit
