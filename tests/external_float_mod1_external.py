# The Python implementation of the Pyking module declared in
# external_float_mod1.external.pyk. A Pyking Float is a Python float:
# both are IEEE 754 binary64, so nothing is converted at the boundary.

def halve(x):
    return x / 2.0

def hypot_sq(a, b):
    return a * a + b * b

def widen(n):
    return float(n)

epsilon = 0.5
