# Classes across modules: hover shows an imported class's method and
# constructor, completion after `r.` offers an imported object's fields
# and methods, and the outline shows a class extending one.
initialize
open classes/classes_main.pyk
idle
hover classes/classes_main.pyk 6:9
hover classes/classes_main.pyk 6:39
hover classes/classes_main.pyk 5:5
complete classes/classes_main.pyk 6:9
symbols classes/classes_main.pyk
shutdown
exit
