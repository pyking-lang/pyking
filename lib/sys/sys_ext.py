# The Python implementation of the Pyking module declared in
# sys_ext.external.pyk.
#
# The environment is read once, into a list, so that a name and its
# value always agree about which index they are: `environment_name(i)`
# and `environment_value(i)` are two calls, and nothing may change
# between them.

import os as _os
import sys as _sys

_variables = list(_os.environ.items())


def argument_count():
    return len(_sys.argv) - 1


def argument(i):
    return _sys.argv[i + 1]


def program():
    return _sys.argv[0]


def environment_count():
    return len(_variables)


def environment_name(i):
    return _variables[i][0]


def environment_value(i):
    return _variables[i][1]
