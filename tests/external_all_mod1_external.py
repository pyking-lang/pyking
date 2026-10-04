# The Python implementation of the Pyking module declared in
# external_all_mod1_external.pyk. An Int is a Python int, a String a
# str, a Bool a bool. Nothing here narrows a result: past the signed
# 32-bit range Pyking leaves the answer undefined, so an implementation
# returns whatever its host computes.

def shout(s):
    return s + "!"

def twice(n):
    return n * 2

def flip(b):
    return not b

origin = 0
greeting = "hello"
