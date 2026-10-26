# Hover where there are no types to show. Positions are line:column,
# both from 1, as an editor shows them.
initialize
open untyped.pyk
idle
# twice is never called: its name, a parameter, a name in its body
hover untyped.pyk 3:6
hover untyped.pyk 3:14
hover untyped.pyk 4:7
# add is called: its name and a parameter show types, and a blank line
# inside it shows nothing
hover untyped.pyk 6:6
hover untyped.pyk 8:5
hover untyped.pyk 7:1
# outside any definition: the call and its value, as before
hover untyped.pyk 10:8
hover untyped.pyk 10:16
# a type error: correct and wrong functions alike say why
open untyped_error.pyk
idle
hover untyped_error.pyk 2:6
hover untyped_error.pyk 3:5
hover untyped_error.pyk 5:6
hover untyped_error.pyk 6:5
hover untyped_error.pyk 8:16
shutdown
exit
