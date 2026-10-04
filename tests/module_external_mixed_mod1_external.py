# The Python implementation of what module_external_mixed_mod1_external.pyk
# declares. `g2` is private to that module, which is a Pyking rule: as
# far as this file is concerned both are ordinary functions.


def g1(x):
    return x + 100


def g2(x):
    return x + 1000
