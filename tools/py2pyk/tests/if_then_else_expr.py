def sign(x):
    return "negative" if x < 0 else "zero" if x == 0 else "positive"


def clamp(x, lo, hi):
    y = lo if x < lo else x
    return hi if y > hi else y


print(sign(-5), sign(0), sign(7))
print(clamp(42, 1, 10))

print(100 if 1 < 2 else 200 + 1)
print((100 if 1 < 2 else 200) + 1)
print([x for x in [1, 2, 3, 4] if (1 == 1 if x < 3 else 1 == 2)])
