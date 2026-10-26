# Quick fixes for the errors that say what was meant.
initialize
open fixes.pyk
idle
request textDocument/codeAction {"textDocument": {"uri": "$URI(fixes.pyk)"}, "range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 0}}, "context": {"diagnostics": []}}
change fixes.pyk
count = 3
print(cuont + 1)
.
idle
request textDocument/codeAction {"textDocument": {"uri": "$URI(fixes.pyk)"}, "range": {"start": {"line": 1, "character": 6}, "end": {"line": 1, "character": 6}}, "context": {"diagnostics": []}}
change fixes.pyk
size: Int = "big"
.
idle
request textDocument/codeAction {"textDocument": {"uri": "$URI(fixes.pyk)"}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 4}}, "context": {"diagnostics": []}}
change fixes.pyk
size = 1 ++ 2
.
idle
request textDocument/codeAction {"textDocument": {"uri": "$URI(fixes.pyk)"}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 4}}, "context": {"diagnostics": []}}
request textDocument/codeAction {"textDocument": {"uri": "$URI(fixes.pyk)"}, "range": {"start": {"line": 5, "character": 0}, "end": {"line": 5, "character": 4}}, "context": {"diagnostics": []}}
# a `var` in a module that has not turned mutation on: the `use` line
change fixes.pyk
# a counter
var count = 0
print(count)
.
idle
request textDocument/codeAction {"textDocument": {"uri": "$URI(fixes.pyk)"}, "range": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 3}}, "context": {"diagnostics": []}}
# an operator written where its look-alike belongs
change fixes.pyk
both = true & false
.
idle
request textDocument/codeAction {"textDocument": {"uri": "$URI(fixes.pyk)"}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 4}}, "context": {"diagnostics": []}}
change fixes.pyk
bits = 5 && 3
.
idle
request textDocument/codeAction {"textDocument": {"uri": "$URI(fixes.pyk)"}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 4}}, "context": {"diagnostics": []}}
change fixes.pyk
big = 2 ** 10
.
idle
request textDocument/codeAction {"textDocument": {"uri": "$URI(fixes.pyk)"}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 4}}, "context": {"diagnostics": []}}
shutdown
exit
