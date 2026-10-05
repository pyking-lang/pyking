# A Pyking function is a Python function; `later` runs its callback at
# exit.

import atexit


def each(f, n):
    for i in range(n):
        f(i)


def with_float(f, x):
    f(x * 2)


def with_pair(f, n, s):
    f(n + 1, s + "!")


def later(f):
    atexit.register(f)
