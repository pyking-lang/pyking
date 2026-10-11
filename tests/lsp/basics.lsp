# Hover, definition, outline and completion over a program importing a
# module of its own and the standard library. Positions are line:column,
# both from 1, the column in UTF-16 code units, as an editor shows them.
initialize
open main.pyk
idle
hover main.pyk 5:10
hover main.pyk 5:18
hover main.pyk 3:30
hover main.pyk 19:2
hover main.pyk 8:6
hover main.pyk 8:12
hover main.pyk 17:21
hover main.pyk 20:5
hover main.pyk 20:15
hover main.pyk 6:6
definition main.pyk 5:18
definition main.pyk 20:16
definition main.pyk 20:5
definition main.pyk 17:28
definition main.pyk 19:1
definition main.pyk 2:8
definition main.pyk 1:1
symbols main.pyk
complete main.pyk 5:16
complete main.pyk 20:4
complete main.pyk 17:20
shutdown
exit
