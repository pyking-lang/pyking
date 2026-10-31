# Warnings are diagnostics of severity 2, each marked unnecessary and
# carrying its flag as its code; a name one says is unused has a quick
# fix that puts `_` in front of it. The `warnings` setting is -W flags,
# replacing what was set before: -Werror= makes one an error (severity
# 1), and -w turns them all off.
initialize
open warnings.pyk
idle
request textDocument/codeAction {"textDocument": {"uri": "$URI(warnings.pyk)"}, "range": {"start": {"line": 2, "character": 4}, "end": {"line": 2, "character": 4}}, "context": {"diagnostics": []}}
request textDocument/codeAction {"textDocument": {"uri": "$URI(warnings.pyk)"}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}, "context": {"diagnostics": []}}
config {"pyking": {"warnings": ["-Wall", "-Werror=unused-function"]}}
idle
config {"pyking": {"warnings": "-w"}}
idle
# an error stops the check, and with it the warnings
config {"warnings": []}
change warnings.pyk
unused = 1 + "x"
.
idle
shutdown
exit
