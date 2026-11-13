# An array whose element type nothing decides is no error: hover shows
# `Array(a)`, as it does `[a]` for an empty list. `var count := 0` is a
# declaration like `var count = 0`. A method call on a DynArray is a
# diagnostic naming the call to write, where it stopped the server's
# check with Not_found.
initialize
open open_types.pyk
idle
hover open_types.pyk 3:1
hover open_types.pyk 5:5
open open_types_error.pyk
idle
shutdown
exit
