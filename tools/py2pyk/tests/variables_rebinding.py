x = 1
x = x + 1
print(x)

n = "outer"


def describe(n):
    return "param " + str(n)


print(describe(1), n)
