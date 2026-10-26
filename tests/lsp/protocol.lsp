# The protocol's own edges: a request before initialize, initialize
# twice, a method the server does not have, a notification it does not
# know, JSON that does not parse, a document never opened, and a request
# after shutdown.
hover main.pyk 3:1
notify textDocument/didOpen {}
initialize
initialize
request workspace/symbol {"query": ""}
request textDocument/formatting {"textDocument": {"uri": "$URI(main.pyk)"}}
notify $/cancelRequest {"id": 99}
notify pyking/unknown {}
raw {"jsonrpc": "2.0", "id": 
raw [1, 2]
hover never_opened.pyk 1:1
symbols never_opened.pyk
shutdown
hover main.pyk 3:1
exit
