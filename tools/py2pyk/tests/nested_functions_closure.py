def make_adder(n):
    def add(x):
        return x + n

    return add(5)


print(make_adder(3), make_adder(10))
