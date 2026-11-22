# A tuple's part, `a[k]`: the tuple indexed hovers at its type, goes to
# where it is bound and is renamed with every use; an index outside the
# tuple and a variable one are diagnosed at the index.
initialize
open tuple_index.pyk
idle
hover tuple_index.pyk 2:13
definition tuple_index.pyk 2:10
request textDocument/rename {"textDocument": {"uri": "$URI(tuple_index.pyk)"}, "position": {"line": 0, "character": 2}, "newName": "row"}
change tuple_index.pyk
record = (7, "seven", true)
print(record[3])
.
idle
change tuple_index.pyk
record = (7, "seven", true)
i = 0
print(record[i])
.
idle
shutdown
exit
