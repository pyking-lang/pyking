# The Python implementation of the Pyking module declared in
# external_all_mod1.external.pyk. An Int is a Python int held to 32 bits
# by the implementation; a String is a str; a Bool is a bool.

def shout(s):
    return s + "!"

def twice(n):
    return (n * 2 + 2**31) % 2**32 - 2**31

def flip(b):
    return not b

origin = 0
greeting = "hello"
