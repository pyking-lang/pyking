def add(a: int, b: int) -> int:
    return a + b


def sum_list(xs: list[int]) -> int:
    total = 0
    for x in xs:
        total = total + x
    return total


def scale(x, factor: int) -> int:
    return x * factor


print(add(2, 3))
print(sum_list([1, 2, 3, 4]))
print(scale(3, 4))
