# Signature help, references and highlights, renaming, inlay hints,
# folding ranges and semantic tokens. Positions are line:column, both
# from 1, as an editor shows them.
initialize
open features.pyk
idle
# signature help: inside add's call, at its second argument; inside a
# library function's; a builtin's; a named argument; a constructor
request textDocument/signatureHelp {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 24, "character": 17}}
request textDocument/signatureHelp {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 24, "character": 24}}
request textDocument/signatureHelp {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 27, "character": 51}}
request textDocument/signatureHelp {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 27, "character": 6}}
request textDocument/signatureHelp {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 27, "character": 34}}
request textDocument/signatureHelp {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 25, "character": 24}}
# references: total from its binding, add from a use, double across the
# import and the module defining it
request textDocument/references {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 22, "character": 5}, "context": {"includeDeclaration": true}}
request textDocument/references {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 24, "character": 14}, "context": {"includeDeclaration": false}}
request textDocument/references {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 27, "character": 30}, "context": {"includeDeclaration": true}}
request textDocument/documentHighlight {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 23, "character": 4}}
# renaming: a local, a clash, a name no program may bind, a library's
request textDocument/prepareRename {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 26, "character": 2}}
request textDocument/rename {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 26, "character": 2}, "newName": "title"}
request textDocument/rename {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 26, "character": 2}, "newName": "total"}
request textDocument/rename {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 26, "character": 2}, "newName": "Title"}
request textDocument/rename {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 27, "character": 0}, "newName": "show"}
request textDocument/rename {"textDocument": {"uri": "$URI(features.pyk)"}, "position": {"line": 13, "character": 5}, "newName": "plus"}
# inlay hints, folding and semantic tokens
request textDocument/inlayHint {"textDocument": {"uri": "$URI(features.pyk)"}, "range": {"start": {"line": 0, "character": 0}, "end": {"line": 28, "character": 0}}}
request textDocument/foldingRange {"textDocument": {"uri": "$URI(features.pyk)"}}
request textDocument/semanticTokens/full {"textDocument": {"uri": "$URI(features.pyk)"}}
shutdown
exit
