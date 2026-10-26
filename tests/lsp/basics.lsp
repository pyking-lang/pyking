# Hover, definition, outline and completion over a program importing a
# module of its own and the standard library. Positions are line:column,
# both from 1, the column in UTF-16 code units, as an editor shows them.
initialize
open main.pyk
idle
hover main.pyk 7:10
hover main.pyk 7:18
hover main.pyk 5:30
hover main.pyk 21:2
hover main.pyk 10:6
hover main.pyk 10:12
hover main.pyk 19:21
hover main.pyk 22:5
hover main.pyk 22:15
hover main.pyk 8:6
definition main.pyk 7:18
definition main.pyk 22:16
definition main.pyk 22:5
definition main.pyk 19:28
definition main.pyk 21:1
definition main.pyk 4:8
definition main.pyk 3:1
symbols main.pyk
complete main.pyk 7:16
complete main.pyk 22:4
complete main.pyk 19:20
shutdown
exit
