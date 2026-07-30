# `x -= expr` becomes `x := x - expr` in Pyking, which puts the original
# right-hand side in the *right* operand position of a left-associative
# operator. It therefore has to keep the grouping Python gave it: `x -= a - b`
# means `x - (a - b)`, never `(x - a) - b`.
#
# `+` and `*` associate either way, so they cannot show the difference; `-`
# and `/` can, and both are exercised here alongside their harmless
# counterparts.

a = 2
b = 5

sub_compound = 100
for i in range(1):
    sub_compound -= a * b - 3
print(sub_compound)

sub_nested = 10
for i in range(1):
    sub_nested -= 3 - 1
print(sub_nested)

div_compound = 100
for i in range(1):
    div_compound /= 2 / 4
print(div_compound)

div_simple = 10
for i in range(1):
    div_simple /= 4
print(div_simple)

add_compound = 10
for i in range(1):
    add_compound += 3 - 1
print(add_compound)

mul_compound = 2
for i in range(1):
    mul_compound *= 3 * 4
print(mul_compound)

mul_sum = 5
for i in range(1):
    mul_sum *= 1 + 1
print(mul_sum)

# The right-hand side may be any expression, including a negation, a call and
# a conditional -- each still lands in that same operand position.
def two():
    return 2


neg_rhs = 10
for i in range(1):
    neg_rhs -= -3
print(neg_rhs)

call_rhs = 10
for i in range(1):
    call_rhs -= two()
print(call_rhs)

cond_rhs = 10
flag = 1
for i in range(1):
    cond_rhs -= 2 if flag > 0 else 5
print(cond_rhs)
