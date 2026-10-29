# Non-breaking spaces (U+00A0) are spaces: a file indented with them
# has no diagnostics, folds its comment block, and counts one as one
# UTF-16 code unit in a position.
initialize
open nbsp.pyk
idle
hover nbsp.pyk 7:14
hover nbsp.pyk 2:6
request textDocument/foldingRange {"textDocument": {"uri": "$URI(nbsp.pyk)"}}
request textDocument/semanticTokens/full {"textDocument": {"uri": "$URI(nbsp.pyk)"}}
shutdown
exit
