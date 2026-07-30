# The same temporary name, used independently inside several sibling blocks
# and never read outside any of them.
#
# Neither language lets one of these blocks observe another's `t`: Python
# because each assignment happens before that block's own read, Pyking because
# a block is a scope. So a plain Pyking `=` in each block means exactly what
# the Python meant, and no `var` promotion is needed -- which is what makes
# this different from the accumulator in `accumulator_var.py`, where the value
# really does have to outlive the loop.

x = 7

if x > 5:
    t = x * 2
    print(t)

if x > 5:
    t = x * 3
    print(t)
else:
    t = 0
    print(t)

for i in range(2):
    t = i * 10
    print(t)

for j in range(2):
    t = j * 100
    print(t)

# Nested one level deeper: the binding is made in the loop body and read from
# an `if` inside it, so it is still visible where it is used.
for k in range(3):
    step = k + 1
    if step > 1:
        print(step)

# The same shape inside a function, which classifies independently of the
# module top level -- and alongside a nested `def`, since a closure in the
# same function must not disturb the analysis of an unrelated name.
def pick(c):
    def double(n):
        return n * 2

    if c > 0:
        chosen = 1
        result = double(chosen)
    else:
        chosen = 2
        result = double(chosen)
    return result


print(pick(1), pick(-1))
