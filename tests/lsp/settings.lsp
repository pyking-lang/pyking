# `"diagnostics": "save"` checks on open and save only; a library
# directory given as a setting is searched.
initialize {"diagnostics": "save", "libPath": ["libdir"]}
open broken.pyk
idle
change broken.pyk
import helper

value = helper.double(1)
.
idle
save broken.pyk
idle
change broken.pyk
import extra

value = extra.seven()
.
save broken.pyk
idle
hover broken.pyk 3:16
config {"pyking": {"diagnostics": "change"}}
change broken.pyk
value = 1 + "x"
.
idle
shutdown
exit
