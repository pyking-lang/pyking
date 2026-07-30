def power(base, n):
    result = 1
    i = 0
    while i < n:
        result = result * base
        i = i + 1
    return result


print(power(2, 10), power(3, 3), power(5, 0))
