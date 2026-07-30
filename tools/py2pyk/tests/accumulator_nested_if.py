def count_positive(xs):
    count = 0
    for x in xs:
        if x > 0:
            count = count + 1
    return count


def tally(items):
    count = 0
    for item in items:
        count = count + item
    return count


print(count_positive([1, -2, 3, -4, 5]))
print(tally([1, 2, 3]))
