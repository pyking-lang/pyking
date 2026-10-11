# Every stage's first error, where it is reported, and that fixing it
# clears it -- including an error in a module the document imports.
initialize
open broken.pyk
idle
change broken.pyk
import helper

def f(x: Int) -> Int:
    return x + 1

value = f(1)
print(missing)
.
idle
change broken.pyk
def f(x: Int) -> Int:
    return x +
.
idle
change broken.pyk
x = "unterminated
.
idle
change broken.pyk
import nowhere
.
idle
change broken.pyk
var n = 1
n := "two"
.
idle
change broken.pyk
value = 1
value := 2
.
idle
change broken.pyk
import helper
print(helper.double(2))
.
idle
open uses_broken.pyk
idle
open broken_module.pyk
idle
change broken_module.pyk
public answer: Int = 1 + 41
.
idle
close broken_module.pyk
shutdown
exit
