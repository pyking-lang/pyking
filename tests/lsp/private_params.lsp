# A class's private constructor parameter (PYKING.md, "`private`"):
# signature help outside the class shows the constructor without it,
# and inside the class's own methods with it; hovering a construction
# whose private parameter takes its default names no generated def;
# completion after `g.` offers no private field.
initialize
open private_params/group_main.pyk
idle
request textDocument/signatureHelp {"textDocument": {"uri": "$URI(private_params/group_main.pyk)"}, "position": {"line": 2, "character": 10}}
request textDocument/signatureHelp {"textDocument": {"uri": "$URI(private_params/group_main.pyk)"}, "position": {"line": 3, "character": 22}}
hover private_params/group_main.pyk 3:5
complete private_params/group_main.pyk 4:9
open private_params/group_lib.pyk
idle
request textDocument/signatureHelp {"textDocument": {"uri": "$URI(private_params/group_lib.pyk)"}, "position": {"line": 4, "character": 14}}
shutdown
exit
