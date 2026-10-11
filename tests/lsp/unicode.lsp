# Positions are UTF-16 code units: é is one, 😀 is two. A change may
# also come as an edited range.
initialize
open unicode.pyk
idle
hover unicode.pyk 2:1
hover unicode.pyk 3:20
symbols unicode.pyk
edit unicode.pyk 3:20-3:21 "\"!\""
idle
edit unicode.pyk 1:10-1:11 "w"
hover unicode.pyk 1:3
shutdown
exit
