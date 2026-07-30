# A value-form `if` whose branches end in an *annotated* assignment
# (`r: int = ...`) rather than a plain one. Pyking erases annotations, so such
# a branch supplies a value exactly as `r = ...` would, and the same
# conditional-binding translation applies.

def classify(n):
    if n > 10:
        label: str = "big"
    elif n > 0:
        label: str = "small"
    else:
        label: str = "negative"
    return label


print(classify(20), classify(5), classify(-3))


# Mixing an annotated tail with a plain one across branches of the same `if`:
# both are assignments to the same name, so both work.
def size(n):
    if n > 0:
        kind: str = "positive"
    else:
        kind = "other"
    return kind


print(size(1), size(0))


# An annotated tail after other statements in the same branch.
def described(n):
    if n > 0:
        doubled = n * 2
        text: str = "pos:" + str(doubled)
    else:
        text: str = "non-pos"
    return text


print(described(3), described(-1))
