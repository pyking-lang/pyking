"""The interface between pure Pyking code and the outside world.

A Pyking program on its own only computes: it has no way to reach a
console, a file, or a clock. Everything observable crosses this boundary,
and this module is where the boundary is written down. The split is the
one WebAssembly draws -- a core language that cannot touch the world at
all, plus a separate, named set of operations a host agrees to provide --
and it is drawn here for the same reason: the language keeps one meaning,
while *where the output goes* becomes the host's decision rather than
something baked into the compiler.

For now the interface has exactly one operation, `print`. What each
backend does with it differs, which is the whole point:

  - the Python backend calls Python's own `print`;
  - the `nodejs` target calls `console.log`;
  - the `html` target appends to an element on the page;
  - the `esm` target calls a function its embedder supplies, so the same
    module can print to a devtools console, a page, or a test harness.

This module names the operations and pins down their semantics. It holds
no target-specific code -- no Python, no JavaScript -- because every
backend has to agree on *what* `print` means before any of them can
decide *how* to do it. `src/target_js_core.py` emits a `JsRuntimeCall`
for each operation named here and leaves the binding to
`src/target_js_packaging.py`.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Operation:
    """One operation a host must provide for Pyking programs to observe
    anything. `variadic` operations take any number of arguments."""
    name: str
    variadic: bool
    doc: str


# The value formatting every host must implement, spelled out once here so
# that the same program prints the same characters whichever backend ran
# it. It follows Python's `print`, because that is the backend Pyking
# started with and the `.out` files in tests/ record it -- except for
# booleans, which are spelled Pyking's own way, not Python's:
#
#   - the arguments are formatted individually and joined with a single
#     space, and the result is followed by a newline;
#   - a string is written as-is, with no quoting;
#   - an integer is written in base 10;
#   - unit, `()`, is written `()` -- never the host language's own name
#     for "no value", so Python must not print `None` nor JavaScript
#     `undefined` where the C and Java hosts would print `()`;
#   - a boolean is written `true` or `false` -- lowercase, matching
#     Pyking's own `true`/`false` literals (see PYKING.md) rather than
#     Python's capitalised `True`/`False`. This is one value every host
#     has to convert *to*, not one it can hand off unchanged: it's a
#     no-op for JavaScript (already spelled that way) and Java (same),
#     but the Python backend has to override its own `print`'s default
#     capitalisation, and C has to spell out a conditional in both
#     standards, neither of which spells a boolean either way on its own.
PRINT = Operation(
    name="print",
    variadic=True,
    doc=(
        "Write the arguments, space-separated, as one line of output. "
        "Produces no value: it yields unit, `()`, so it is meaningful as "
        "a statement and not as something to bind or return. A function "
        "whose tail is a `print` therefore returns unit -- `void` in the "
        "C and Java backends, an implicit `None`/`undefined` in the "
        "Python and JavaScript ones."
    ),
)

OPERATIONS = (PRINT,)

NAMES = tuple(operation.name for operation in OPERATIONS)


def lookup(name):
    """The `Operation` a name denotes, or `None` if the name is an
    ordinary Pyking name rather than part of this interface."""
    for operation in OPERATIONS:
        if operation.name == name:
            return operation
    return None
