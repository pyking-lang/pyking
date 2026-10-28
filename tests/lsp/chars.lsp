# Chars in the editor: hover shows Char for a function's result, a
# binding and a loop variable, and `+` on a String and a Char is a
# diagnostic saying how to join them. Positions are line:column, both
# from 1, as an editor shows them.
initialize
open chars.pyk
idle
hover chars.pyk 1:6
hover chars.pyk 4:1
hover chars.pyk 5:23
open chars_error.pyk
idle
shutdown
exit
