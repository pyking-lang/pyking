# A list comprehension is its own scope in both languages, so the names its
# generators bind are not uses of anything in the enclosing block. A
# comprehension may therefore reuse the name of a `for` loop's variable, or of
# an ordinary binding, without that counting as the loop variable escaping its
# body (which Pyking would refuse) or as a read of the outer name.

for x in [1, 2]:
    print(x)

print([x for x in [3, 4]])

for v in [5, 6]:
    print(v)

print([v * 2 for v in [7, 8]])

# Two comprehensions reusing one target name, with nothing of that name
# outside either of them.
print([q for q in [1, 2]])
print([q + 10 for q in [3, 4]])

# A comprehension target shadowing an ordinary binding leaves that binding
# untouched, exactly as in Python 3.
n = 5
print([n for n in [1, 2]])
print(n)

# The first generator's iterable is evaluated in the enclosing scope, so it
# really does read the outer name; the element expression reads the
# comprehension's own.
source = [1, 2, 3]
print([source_item * 2 for source_item in source if source_item > 1])

# Inside a function, and closing over an enclosing name from within the
# comprehension's element expression.
def scaled(base):
    return [base + k for k in [1, 2]]


print(scaled(10))
