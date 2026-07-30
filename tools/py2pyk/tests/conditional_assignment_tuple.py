def minmax(a, b):
    if a < b:
        lo, hi = a, b
    else:
        lo, hi = b, a
    return lo, hi


print(minmax(3, 7), minmax(9, 2), minmax(5, 5))
