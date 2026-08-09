"""The interface between pure Pyking code and the outside world: the
operations a host must provide, and their semantics. No target-specific
code. See docs/architecture.md, "The runtime interface".

Data structures:
    Operation -- one operation a host must provide (name, arity, semantics).

Functions:
    lookup(name) -- the Operation a name denotes, or None.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Operation:
    """One operation a host must provide. Fields: name: String,
    variadic: Bool, doc: String."""
    name: str
    variadic: bool
    doc: str


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
    """The Operation a name denotes, or None if it is an ordinary Pyking
    name. String -> Operation?"""
    for operation in OPERATIONS:
        if operation.name == name:
            return operation
    return None
