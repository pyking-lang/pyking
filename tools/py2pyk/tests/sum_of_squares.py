def sum_of_squares(n):
    total = 0
    for i in range(1, n + 1):
        total = total + i * i
    return total


print(sum_of_squares(5), sum_of_squares(10))
