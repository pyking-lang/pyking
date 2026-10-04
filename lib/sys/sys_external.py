# The Python implementation of the names declared in sys_external.pyk.
#
# The environment is read once, into a list, so that the pairs a caller
# walks are one consistent picture of it.

import os as _os
import os.path as _path
import sys as _sys

_variables = list(_os.environ.items())


def args():
    return _sys.argv[1:]


def env():
    return _variables


def prog_name():
    return _path.basename(_sys.argv[0])


def prog_path():
    return _path.dirname(_path.abspath(_sys.argv[0]))


def exit(code):
    _sys.stdout.flush()
    _sys.exit(code)
