# The Python implementation of the names declared in text_external.pyk.
#
# A Python str is a sequence of code points already, so a position here
# is one Pyking counts. `upper` and `lower` change the ASCII letters
# alone, which str.upper and str.lower do not.

_UPPER = {c: c - 32 for c in range(ord("a"), ord("z") + 1)}
_LOWER = {c: c + 32 for c in range(ord("A"), ord("Z") + 1)}


def host_length(s):
    return len(s)


def host_slice(s, start, stop):
    return s[start:stop]


def host_find(s, part, start):
    return s.find(part, start)


def host_code(s, k):
    return ord(s[k])


def host_replace(s, old, by):
    return s.replace(old, by)


def host_upper(s):
    return s.translate(_UPPER)


def host_lower(s):
    return s.translate(_LOWER)
