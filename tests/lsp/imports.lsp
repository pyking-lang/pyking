# Completion after `import` and `from` offers only modules: the
# standard library's and the files beside the document, never its own
# name, a keyword or a builtin. After `as` it is no module's place.
initialize
open imports/imports_main.pyk
idle
complete imports/imports_main.pyk 1:10
complete imports/imports_main.pyk 1:14
complete imports/imports_main.pyk 2:8
complete imports/imports_main.pyk 3:19
shutdown
exit
