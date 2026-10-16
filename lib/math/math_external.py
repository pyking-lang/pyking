# The Python implementation of the names declared in math_external.pyk.
#
# Python's own `math` is the module these forward to, and it has the
# Pyking module's name: the program's directory holds the generated
# math.py, and where the standard library's `math` is not built into the
# interpreter, `import math` would find that file first. So the
# standard library's is looked for everywhere on the path but here.

import importlib.machinery as _machinery
import importlib.util as _util
import os.path as _path
import sys as _sys


def _standard_math():
    if "math" in _sys.builtin_module_names:
        import math

        return math
    here = _path.dirname(_path.abspath(__file__))
    elsewhere = [p for p in _sys.path if _path.abspath(p or ".") != here]
    spec = _machinery.PathFinder.find_spec("math", elsewhere)
    module = _util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_math = _standard_math()


def _guarded(f, x):
    # Python raises where IEEE answers NaN or an infinity.
    try:
        return f(x)
    except ValueError:
        return float("nan")
    except OverflowError:
        return float("inf")


def host_sin(x):
    return _guarded(_math.sin, x)


def host_cos(x):
    return _guarded(_math.cos, x)


def host_tan(x):
    return _guarded(_math.tan, x)


def host_asin(x):
    return _guarded(_math.asin, x)


def host_acos(x):
    return _guarded(_math.acos, x)


def host_atan(x):
    return _math.atan(x)


def host_atan2(y, x):
    return _math.atan2(y, x)


def host_sinh(x):
    try:
        return _math.sinh(x)
    except OverflowError:
        return _math.copysign(float("inf"), x)


def host_cosh(x):
    return _guarded(_math.cosh, x)


def host_tanh(x):
    return _math.tanh(x)


def host_exp(x):
    return _guarded(_math.exp, x)


def _logarithm(f, x):
    if x == 0.0:
        return float("-inf")
    return _guarded(f, x)


def host_log(x):
    return _logarithm(_math.log, x)


def host_log2(x):
    return _logarithm(_math.log2, x)


def host_log10(x):
    return _logarithm(_math.log10, x)


def host_sqrt(x):
    return _guarded(_math.sqrt, x)


def host_cbrt(x):
    return _math.cbrt(x)


def host_pow(x, y):
    try:
        return _math.pow(x, y)
    except ValueError:
        # 0.0 to a negative power, which IEEE answers with an infinity,
        # or a negative number to a fractional one, which is NaN.
        if x == 0.0:
            return _math.copysign(float("inf"), x) if y == int(y) and int(y) % 2 else float("inf")
        return float("nan")
    except OverflowError:
        return float("inf") if x > 0.0 or y == int(y) and int(y) % 2 == 0 else float("-inf")


def host_hypot(x, y):
    return _math.hypot(x, y)


def host_floor(x):
    return float(_math.floor(x)) if _math.isfinite(x) else x


def host_ceil(x):
    return float(_math.ceil(x)) if _math.isfinite(x) else x


def host_trunc(x):
    return float(_math.trunc(x)) if _math.isfinite(x) else x
