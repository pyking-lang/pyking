def max_of(xs):
    result = 0
    first = True
    for x in xs:
        if first:
            result = x
            first = False
        elif x > result:
            result = x
    return result


print(max_of([3, 7, 2, 9, 4]))
print(max_of([-5, -1, -9]))
