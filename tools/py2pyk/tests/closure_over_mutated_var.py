# A nested `def` that reads a name the enclosing function mutates inside a
# loop. The closure can be *called* at any point after the `def`, so that read
# happens outside the loop: the mutation has to be visible there, which means
# the name must become a Pyking `var` updated with `:=` rather than a plain
# per-block `=` binding.
#
# This is the case that makes classification look at what a nested `def` reads
# from its enclosing scope, rather than skipping its body entirely.

def sum_then_read():
    total = 0

    def get():
        return total

    for v in [1, 2, 3]:
        total = total + v
    return get()


print(sum_then_read())


# The same thing with the `def` written after the loop instead of before it.
def sum_then_read_late():
    total = 0
    for v in [1, 2, 3]:
        total = total + v

    def get():
        return total

    return get()


print(sum_then_read_late())


# Read through two levels of nesting: `inner` closes over a name belonging to
# neither itself nor `mid`, but to the outermost function.
def doubly_nested():
    total = 0

    def mid():
        def inner():
            return total
        return inner()

    for v in [1, 2, 3]:
        total = total + v
    return mid()


print(doubly_nested())


# A closure whose free read sits inside a comprehension it builds.
def closure_with_comprehension():
    base = 0

    def offsets():
        return [base + k for k in [1, 2]]

    for v in [1, 2, 3]:
        base = base + v
    return offsets()


print(closure_with_comprehension())


# A parameter of the nested function shadows one outer name (so that name is
# *not* closed over, and stays a plain binding) while the body genuinely reads
# another (which therefore does become a `var`). Note the shadowed name has to
# be one that stays a plain binding: Pyking refuses to let anything shadow a
# `var`, so a parameter named after the mutated `total` would be rejected --
# see "Not supported" in the README.
def shadowed_by_param():
    offset = 100
    total = 0
    for v in [1, 2, 3]:
        total = total + v

    def use(offset):
        return offset + total

    return use(10) + offset


print(shadowed_by_param())


# The same at module level: a module-level closure over a module-level name
# that a module-level loop mutates.
running = 0


def running_total():
    return running


for step in [1, 2, 3]:
    running = running + step

print(running_total())
