import keyword
from dataclasses import dataclass, fields, is_dataclass

import runtime_interface
from lexer import Info
from syntax import (
    EInt, EString, EBool, EVar,
    EAdd, ESub, EMul, EDiv, ENeg,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EList, ETuple,
    EIf, EListComp, CompFor, CompIf,
    PInt, PString, PBool, PWildcard, PCapture, PTuple, PList,
    SLet, SLetStmt, SVar, SMutate, SReturn, SReturnStmt, SExprStmt, SFor, SWhile, SIf,
    SFunctionDef, SMatch,
    TargetName, TargetTuple,
)


# --- Python target AST ---
#
# Structurally the same shape as syntax.py's E*/S* nodes, with one
# deliberate difference: Pyking's SLet/SVar/SMutate (immutable binding vs.
# mutable declaration vs. mutation) all collapse into a single PyAssign,
# since Python itself has no such distinction — every one of them is just
# `target = expr`. Only SLet's target can destructure a tuple in Pyking;
# SVar/SMutate keep a plain name, wrapped in `PyTargetName` here so all
# three still produce the same uniformly-shaped `PyAssign`.

class PyExpr:
    """Base class for the Python-target expression AST."""


@dataclass(frozen=True)
class PyInt(PyExpr):
    info: Info
    value: int


@dataclass(frozen=True)
class PyString(PyExpr):
    info: Info
    value: str


@dataclass(frozen=True)
class PyBool(PyExpr):       # True / False
    info: Info
    value: bool


@dataclass(frozen=True)
class PyVar(PyExpr):
    info: Info
    name: str


@dataclass(frozen=True)
class PyAdd(PyExpr):        # left + right
    info: Info
    left: PyExpr
    right: PyExpr


@dataclass(frozen=True)
class PySub(PyExpr):        # left - right
    info: Info
    left: PyExpr
    right: PyExpr


@dataclass(frozen=True)
class PyMul(PyExpr):        # left * right
    info: Info
    left: PyExpr
    right: PyExpr


@dataclass(frozen=True)
class PyDiv(PyExpr):        # left / right
    info: Info
    left: PyExpr
    right: PyExpr


@dataclass(frozen=True)
class PyNeg(PyExpr):        # -operand (unary minus)
    info: Info
    operand: PyExpr


@dataclass(frozen=True)
class PyLessThan(PyExpr):   # left < right
    info: Info
    left: PyExpr
    right: PyExpr


@dataclass(frozen=True)
class PyLessThanEq(PyExpr):  # left <= right
    info: Info
    left: PyExpr
    right: PyExpr


@dataclass(frozen=True)
class PyGreatThan(PyExpr):  # left > right
    info: Info
    left: PyExpr
    right: PyExpr


@dataclass(frozen=True)
class PyGreatThanEq(PyExpr):  # left >= right
    info: Info
    left: PyExpr
    right: PyExpr


@dataclass(frozen=True)
class PyEq(PyExpr):         # left == right
    info: Info
    left: PyExpr
    right: PyExpr


@dataclass(frozen=True)
class PyCall(PyExpr):       # func(args...)
    info: Info
    func: PyExpr
    args: list


@dataclass(frozen=True)
class PyList(PyExpr):       # [elements...]
    info: Info
    elements: list


@dataclass(frozen=True)
class PyTuple(PyExpr):      # (e1, e2, ...) / (e,) / ()
    info: Info
    elements: list


@dataclass(frozen=True)
class PyIfExp(PyExpr):      # then_expr if cond else else_expr
    info: Info              # (Python's conditional expression -- note the
    cond: PyExpr            # operand order differs from Pyking's `EIf`,
    then_expr: PyExpr       # which writes the condition first)
    else_expr: PyExpr


class PyPattern:
    """Base class for the Python-target match-case patterns."""


@dataclass(frozen=True)
class PyPInt(PyPattern):    # case 0:
    info: Info
    value: int


@dataclass(frozen=True)
class PyPString(PyPattern):  # case "foo":
    info: Info
    value: str


@dataclass(frozen=True)
class PyPBool(PyPattern):    # case True: / case False:
    info: Info
    value: bool


@dataclass(frozen=True)
class PyPWildcard(PyPattern):  # case _:
    info: Info


@dataclass(frozen=True)
class PyPCapture(PyPattern):  # case name:
    info: Info
    name: str


@dataclass(frozen=True)
class PyPTuple(PyPattern):  # case (p1, p2, ...):
    info: Info
    elements: list


@dataclass(frozen=True)
class PyListRest:           # the `*name` / `*_` star sub-pattern of a PyPList
    info: Info
    name: str = None        # None => `*_` (Python's syntax for discarding)


@dataclass(frozen=True)
class PyPList(PyPattern):   # case [p1, ..., *rest_or_wildcard, ..., pk]:
    info: Info
    prefix: list
    rest: PyListRest = None  # None => no star sub-pattern (exact-length list)
    suffix: list = None


@dataclass(frozen=True)
class PyMatchCase:          # case pattern: body
    info: Info
    pattern: PyPattern
    body: list


class PyTarget:
    """Base class for the Python-target assignment target AST."""


@dataclass(frozen=True)
class PyTargetName(PyTarget):   # name
    info: Info
    name: str


@dataclass(frozen=True)
class PyTargetTuple(PyTarget):  # (t1, t2, ...)
    info: Info
    elements: list


# --- list comprehension AST (depends on PyTarget, so defined after it) ---

class PyCompClause:
    """Base class for the Python-target list-comprehension clauses."""


@dataclass(frozen=True)
class PyCompFor(PyCompClause):  # for target in sequence
    info: Info
    target: PyTarget
    sequence: PyExpr


@dataclass(frozen=True)
class PyCompIf(PyCompClause):   # if condition
    info: Info
    condition: PyExpr


@dataclass(frozen=True)
class PyListComp(PyExpr):   # [expr for target in seq {for ... | if ...}]
    info: Info
    expr: PyExpr
    clauses: list             # list[PyCompClause]


class PyStmt:
    """Base class for the Python-target statement AST."""


@dataclass(frozen=True)
class PyAssign(PyStmt):     # target = expr
    info: Info
    target: PyTarget
    expr: PyExpr


@dataclass(frozen=True)
class PyReturn(PyStmt):     # return expr
    info: Info
    expr: PyExpr


@dataclass(frozen=True)
class PyExprStmt(PyStmt):   # expr used as a statement, e.g. print(x)
    info: Info
    expr: PyExpr


@dataclass(frozen=True)
class PyFor(PyStmt):        # for name in iterable: body
    info: Info
    name: str
    iterable: PyExpr
    body: list


@dataclass(frozen=True)
class PyWhile(PyStmt):      # while cond: body
    info: Info
    cond: PyExpr
    body: list


@dataclass(frozen=True)
class PyIf(PyStmt):         # if cond: then_body [else: else_body]
    info: Info
    cond: PyExpr
    then_body: list
    else_body: list = None


@dataclass(frozen=True)
class PyFunctionDef(PyStmt):  # def name(params...): body
    info: Info
    name: str
    params: list
    body: list


@dataclass(frozen=True)
class PyMatch(PyStmt):      # match subject: case pattern: body ...
    info: Info
    subject: PyExpr
    cases: list


@dataclass(frozen=True)
class PyProgram:
    """The result of translating a whole Pyking program (`translate_program`'s
    return value, and `pprint_py_program`'s sole argument): the compiled
    statements, plus an optional `prelude` -- currently just the
    boolean-print-formatting helper (see `_bool_format_helper_name`),
    present only when the program actually printed something this
    backend could not prove, from its Pyking source form alone, was or
    wasn't a Bool (see `_bool_shape`). The prelude prints separately, in
    its own commented-off block, because it's boilerplate for the host
    Python interpreter, not a translation of anything the Pyking source
    wrote -- the same reason the JavaScript targets mark their own
    prelude off in `target_js_packaging.py`."""
    prelude: list        # PyStmt list, usually empty
    stmts: list          # PyStmt list: the translated program


# --- translation: Pyking AST (syntax.py) -> Python target AST ---
#
# List comprehensions need special handling: Pyking allows an arbitrary
# *pattern* in a comprehension's `for` clause, whereas Python only allows
# an irrefutable assignment target there. There are two cases (decided by
# `_is_irrefutable`), so that the common ones stay as readable as the
# Pyking source:
#
#  1. Irrefutable pattern (a name, `_`, or a tuple built from those) --
#     it always binds, never filters, so it compiles straight to the
#     equivalent native Python `for`-target with no helper at all:
#         [x + 1 for x in xs]            ->  [x + 1 for x in xs]
#         [x for (x, _) in pairs]        ->  [x for (x, _) in pairs]
#
#  2. Refutable pattern (a literal, or any list pattern -- possibly nested
#     inside a tuple) -- it may reject some values, which Python's own
#     `for`-target grammar can't express. Such a clause is desugared into
#     two Python comprehension clauses: iterate the raw items, then run
#     each through an auto-generated helper that attempts the match using
#     Python's own `match` statement (which _does_ support arbitrary
#     patterns, just not inside a comprehension) and returns either `[]`
#     (no match) or a one-element list holding a tuple of the bound names
#     (match). A single `for <names> in helper(item)` clause then does
#     double duty as both the filter -- iterating zero times drops the
#     element -- and the bind -- iterating once unpacks the names:
#         [a + b for [a, b] in rows]
#             ->  [a + b for item1 in rows for (a, b) in __pm1(item1)]
#     These helper functions are pattern-only (no references to anything
#     in the enclosing scope), so they're always safe to hoist to the top
#     of the generated file; `_pending_comp_helpers` collects them during
#     translation and `translate_program` (the sole external entry point,
#     see `_translate_stmts` below) drains and prepends them once, at the
#     very end, regardless of how deeply the comprehension was nested. The
#     `item*`/`__pm*` names are allocated by `_fresh_comp_names`, which
#     guarantees they never collide with any source identifier.

_comp_counter = 0
_pending_comp_helpers = []
# Every identifier that appears anywhere in the source program (see
# `_collect_identifiers`), so the synthesized comprehension names below can
# be guaranteed never to collide with -- or shadow -- a user name, whatever
# the program happens to call its variables.
_used_identifiers = set()

# A call to a runtime_interface operation (currently just `print`) needs
# each argument that might be a Bool passed through
# `_bool_format_helper_name()`'s helper first: Pyking spells its boolean
# values `true`/`false`, but they are represented as Python's own
# `True`/`False` throughout translation (see `PyBool` above), and
# Python's own `print` would write those back out capitalised. Most
# printed values need no such check at all -- see `_bool_shape` and
# `_wrap_print_argument`, which decide *per argument* whether Pyking's own
# grammar already proves it one way or the other -- and the ones that do
# are handled with an inline conditional, no helper involved. The helper
# below exists only for the residue: an argument (a variable, a function
# call, ...) genuinely could be a Bool at runtime and the translator
# cannot tell from its Pyking source form alone. It is synthesized once,
# lazily, the first time it's actually needed -- so a program that never
# hits that case never gets one at all -- the same way `_build_match_helper`
# builds a comprehension helper on first use, and named via the same
# collision-avoidance scheme as `_fresh_comp_names`, so it can never
# collide with a real Pyking identifier. It prints separately from
# ordinary generated code, in a commented-off prelude block (see
# `pprint_py_program`), because it's host boilerplate the Pyking source
# didn't write, not a translation of anything in it.
_bool_format_helper_name_value = None
_bool_format_helper_def = None


def _collect_identifiers(node, acc=None):
    """Every identifier used anywhere in the Pyking AST `node`, as a set.

    Relies on an invariant of `syntax.py`: every field literally named
    `name` holds an identifier (`EVar`, `PCapture`, `ListRest`, `Param`,
    `TargetName`, `SVar`, `SMutate`, `SFor`, `SFunctionDef`, ...), and
    nothing else does. So a generic walk that grabs each `name` field and
    recurses through all other fields collects exactly the identifiers,
    without a per-node-type case to keep in sync."""
    if acc is None:
        acc = set()
    if is_dataclass(node):
        for f in fields(node):
            value = getattr(node, f.name)
            if f.name == "name" and isinstance(value, str):
                acc.add(value)
            else:
                _collect_identifiers(value, acc)
    elif isinstance(node, (list, tuple)):
        for element in node:
            _collect_identifiers(element, acc)
    return acc


def _fresh_comp_names():
    """A fresh `(item_var, helper_name)` pair for one refutable
    comprehension clause -- e.g. `('item1', '__pm1')`. Both are checked
    against `_used_identifiers` and the counter is bumped until neither
    collides, so a generated name can never clash with (or shadow) any
    identifier in the source program, no matter what it's named."""
    global _comp_counter
    while True:
        _comp_counter += 1
        item = f"item{_comp_counter}"
        helper = f"__pm{_comp_counter}"
        if item not in _used_identifiers and helper not in _used_identifiers:
            return item, helper


def pattern_captured_names(pattern):
    """The names `pattern` would bind, in order, by walking its
    sub-patterns (mirrors `parser.py`'s `_pattern_captures`, but this
    copy works on top of `syntax.py` alone, with no parser dependency)."""
    match pattern:
        case PCapture(_, name):
            return [name]
        case PTuple(_, elements):
            return [n for e in elements for n in pattern_captured_names(e)]
        case PList(_, prefix, rest, suffix):
            names = [n for e in prefix for n in pattern_captured_names(e)]
            if rest is not None and rest.name is not None:
                names.append(rest.name)
            names += [n for e in (suffix or []) for n in pattern_captured_names(e)]
            return names
        case _:
            return []


def _is_irrefutable(pattern):
    """Whether `pattern` matches *every* value it could be given -- so, in
    a comprehension `for` clause, it only ever binds and never filters,
    and can compile straight to a native Python `for`-target (no match
    helper). This holds for names, `_`, and tuples built recursively from
    those.

    Notably it does *not* hold for a `PList`: a list pattern tests the
    runtime *length* of the value (that's the whole point of `[a, b]` vs.
    `[a, ..rest]`), so it genuinely rejects non-matching lengths and must
    keep the filtering match-helper. A `PTuple`, by contrast, corresponds
    to a fixed-arity tuple type `(T1, ..., Tn)`, so like Python's own
    unpacking it's treated as a total destructuring -- a wrong-arity value
    is a shape error surfaced by Python at runtime, not a silent filter.
    Literal patterns (`PInt`/`PString`/`PBool`) are refutable by value,
    which Python's `for`-target grammar can't express at all."""
    match pattern:
        case PCapture(_, _) | PWildcard(_):
            return True
        case PTuple(_, elements):
            return all(_is_irrefutable(e) for e in elements)
        case _:
            return False


def _pattern_to_target(pattern, scope):
    """Compiles an irrefutable `pattern` (see `_is_irrefutable`) directly
    to the equivalent Python assignment/`for` target -- e.g. `(x, _)`
    stays `(x, _)`, so the generated comprehension reads just like the
    Pyking source, with no helper indirection. Returns it with the scope
    its names extend, like `translate_target`."""
    match pattern:
        case PCapture(info, name):
            py_name, scope = _bind(name, scope)
            return PyTargetName(info, py_name), scope
        case PWildcard(info):
            return PyTargetName(info, "_"), scope
        case PTuple(info, elements):
            py_elements = []
            for element in elements:
                py_element, scope = _pattern_to_target(element, scope)
                py_elements.append(py_element)
            return PyTargetTuple(info, py_elements), scope
        case _:
            raise NotImplementedError(
                f"pattern {pattern!r} is refutable; has no direct Python target"
            )


# --- scopes and renaming ---
#
# Pyking makes every block a scope, so a binding inside an `if`/`for`/
# `while`/`case` body may shadow an outer name and disappear with the
# block. Python only scopes at function (and comprehension) boundaries,
# so translating both bindings to the same Python name would let the
# inner one overwrite the outer -- the shadowed name would come back
# changed after the block. The translation therefore carries a `Scope`
# mapping each Pyking name to the Python name standing in for it, and
# renames a binding when, and only when, Python would otherwise confuse
# it with a live one.
#
# "Only when necessary" is the point: a rename is emitted just for a
# binding that shadows another *within the same Python function scope*.
# Everything else keeps the name the programmer wrote --
#
#   - a `def` body, a comprehension: Python opens a real scope there, so
#     a parameter or comprehension variable may reuse any name freely;
#   - rebinding in the same block (`x = 1` then `x = 2`): the first is
#     unreachable afterwards in Pyking too, so one Python name serves
#     both;
#   - sibling blocks that each bind `t`: neither can see the other's, so
#     they share the name.
#
# A renamed name stays close to the original: `total` becomes `total2`,
# or `total3` if `total2` is itself taken here (see `_fresh_py_name`).


@dataclass(frozen=True)
class Scope:
    """The names in scope during translation.

    `local` is the current Python function scope: Pyking name -> the
    Python name it compiles to. `outer` is everything visible from
    enclosing Python function scopes, kept separate because a binding
    only has to dodge names in `local` -- Python's own scoping already
    keeps it apart from `outer` -- while reads must still find both.
    `block` is the set of names bound by the innermost Pyking block, the
    one thing that distinguishes rebinding a name (reuse) from shadowing
    it (rename)."""
    outer: dict
    local: dict
    block: frozenset


def _function_scope(scope):
    """The scope for a `def` body or a comprehension: Python opens a
    fresh scope there, so everything visible so far becomes closure state
    and nothing inside it can collide with anything outside."""
    return Scope({**scope.outer, **scope.local}, {}, frozenset())


def _block_scope(scope):
    """The scope for a nested Pyking block: the same Python function
    scope -- which is exactly why bindings inside it may need renaming --
    but its own set of block-local names, and its bindings are dropped
    when the caller keeps using its own scope."""
    return Scope(scope.outer, scope.local, frozenset())


def _lookup(name, scope):
    """The Python name a Pyking name reads as. A name bound nowhere is a
    builtin (`print`, `len`, ...) and passes through unchanged -- the
    name analysis has already rejected every other unbound name."""
    if name in scope.local:
        return scope.local[name]
    return scope.outer.get(name, name)


# Names that are legal Pyking identifiers but reserved words in Python,
# so a program with `def lambda(n):` would otherwise compile to code that
# will not parse. Taken from the `keyword` module rather than written out,
# so the set can never go stale against the Python this runs on;
# `softkwlist` (`match`, `case`, `type`, `_`) is included too -- most are
# already Pyking keywords and so unreachable here, and renaming the rest
# costs nothing.
RESERVED = frozenset(keyword.kwlist) | frozenset(keyword.softkwlist)


def _fresh_py_name(name, scope):
    """`name2`, or `name3`, ... -- the first that no name in scope is
    already using. Both sides of both maps are checked: a Python name in
    use (a value) would be overwritten, and a Pyking name in scope (a
    key) is one this same translation may yet have to emit as itself."""
    taken = (
        set(scope.local) | set(scope.local.values())
        | set(scope.outer) | set(scope.outer.values())
    )
    n = 2
    while f"{name}{n}" in taken or f"{name}{n}" in RESERVED:
        n += 1
    return f"{name}{n}"


def _bind(name, scope):
    """Binds a Pyking name, returning `(python_name, extended_scope)`.

    Renames only when this binding would land on a Python name that is
    still live in this function scope: either the same name bound by an
    enclosing *block* (`name in scope.local` without being block-local
    here), or a Python name some earlier rename already handed out
    (`name in scope.local.values()`)."""
    if name in scope.block:
        return scope.local[name], scope
    py_name = name
    if name in RESERVED or name in scope.local or name in scope.local.values():
        py_name = _fresh_py_name(name, scope)
    return py_name, Scope(
        scope.outer, {**scope.local, name: py_name}, scope.block | {name}
    )


def _build_match_helper(pattern, helper_name):
    """Synthesizes a closure-free `PyFunctionDef` named `helper_name` that
    tests a single value against `pattern`: returns `[(bound names...)]`
    if it matches, or `[]` if it doesn't. Registers it in
    `_pending_comp_helpers` and returns the captured names.

    The parameter is a fixed `v`, not a fresh name, because it needs
    no collision protection: it's only ever referenced as the `match`
    subject *before* `pattern` binds anything, so even a pattern that
    itself captures a name `v` (which would then shadow the
    parameter inside the `case` body) stays correct. For the same reason
    the helper needs no renaming: its body is a Python function scope of
    its own, holding nothing but this pattern's own names."""
    info = pattern.info
    v = PyVar(info, "v")
    names = pattern_captured_names(pattern)
    success = PyReturn(
        info, PyList(info, [PyTuple(info, [PyVar(info, n) for n in names])])
    )
    helper_scope = Scope({}, {}, frozenset())
    py_pattern, _ = translate_pattern(pattern, helper_scope)
    match_stmt = PyMatch(info, v, [PyMatchCase(info, py_pattern, [success])])
    failure = PyReturn(info, PyList(info, []))
    helper = PyFunctionDef(info, helper_name, ["v"], [match_stmt, failure])
    _pending_comp_helpers.append(helper)
    return names


def _bool_format_helper_name(info):
    """The name of the print-formatting helper for a value that genuinely
    might be a Bool at runtime and can't be proven either way from its
    Pyking source form (see `_bool_shape`) -- building and registering it
    the first time *that* happens, synthesized as:

        def __pyk_bool_str(v):
            if isinstance(v, bool):
                return 'true' if v else 'false'
            return v

    `isinstance` rather than `v is True`/`v is False`, because Python's
    `bool` is a subclass of `int` and `1 == True`, but never
    `isinstance(1, bool)` -- so a Pyking `Int` that happens to be `0` or
    `1` is never misidentified as a boolean this way. Only a call's
    *top-level* arguments are ever wrapped (see `_wrap_print_argument`),
    matching the granularity `runtime_interface.py`'s formatting contract
    already documents at (an integer nested inside a printed list is
    already however Python's own `repr` renders it, not specially handled
    either). Kept separate from `_pending_comp_helpers`: it's boilerplate
    for the host, not a translation of anything the source wrote, so it
    prints in its own commented-off prelude block -- see
    `pprint_py_program`."""
    global _bool_format_helper_name_value, _bool_format_helper_def
    if _bool_format_helper_name_value is None:
        candidate = "__pyk_bool_str"
        n = 0
        while candidate in _used_identifiers:
            n += 1
            candidate = f"__pyk_bool_str{n}"
        _bool_format_helper_name_value = candidate
        v = PyVar(info, "v")
        is_bool = PyCall(info, PyVar(info, "isinstance"), [v, PyVar(info, "bool")])
        as_text = PyIfExp(info, v, PyString(info, "true"), PyString(info, "false"))
        body = [PyIf(info, is_bool, [PyReturn(info, as_text)]), PyReturn(info, v)]
        _bool_format_helper_def = PyFunctionDef(info, candidate, ["v"], body)
    return _bool_format_helper_name_value


def _translate_comp_for(clause, scope):
    """Expands one Pyking `CompFor(pattern, sequence)` into Python
    comprehension clause(s), returning them with the scope its pattern
    extends (later clauses and the element expression see those names).

    An *irrefutable* pattern (see `_is_irrefutable`) needs no filtering,
    so it becomes a single, plain `for <target> in <seq>` -- the same
    shape Python itself would use, with the pattern compiled directly to
    a Python target. This covers plain names (`for x in seq`), wildcards,
    and tuple destructuring (`for (x, _) in seq`).

    A *refutable* pattern (a literal, or any list pattern -- possibly
    nested inside a tuple) may reject some values, which Python's own
    `for`-target grammar can't express, so it takes the two-clause
    match-helper path described in the module comment above: iterate the
    raw items, then `for <names> in helper(item)`, where the helper
    returns `[]` (filtered out) or `[(names...)]` (matched)."""
    info = clause.info
    sequence = translate_expr(clause.sequence, scope)
    if _is_irrefutable(clause.pattern):
        target, scope = _pattern_to_target(clause.pattern, scope)
        return [PyCompFor(info, target, sequence)], scope

    item_var, helper_name = _fresh_comp_names()
    names = _build_match_helper(clause.pattern, helper_name)
    # The unpacking target is always a tuple target, e.g. `()` if the
    # pattern captures nothing, `(n,)` for one name -- `PyTargetTuple`
    # already prints the right shape (including the singleton comma) in
    # every case, so there's no need to special-case any of them here.
    elements = []
    for name in names:
        py_name, scope = _bind(name, scope)
        elements.append(PyTargetName(info, py_name))
    target = PyTargetTuple(info, elements)
    return [
        PyCompFor(info, PyTargetName(info, item_var), sequence),
        PyCompFor(
            info, target, PyCall(info, PyVar(info, helper_name), [PyVar(info, item_var)])
        ),
    ], scope


# Pyking has no type checker (see PYKING.md), so whether a given
# expression produces a Bool is, in general, not knowable at compile
# time -- but for plenty of expressions it plainly is, straight from
# their Pyking AST *shape* alone, with no type system needed: a
# comparison or a boolean literal always does, an arithmetic expression
# or a list/tuple/string/int literal never does. `_bool_shape` answers
# that where it can and says "unknown" everywhere else, which
# `_wrap_print_argument` (the only caller) treats as the safe default: a
# runtime check via `_bool_format_helper_name`.
_PROVABLY_BOOL_EXPRS = (EEq, ELessThan, ELessThanEq, EGreatThan, EGreatThanEq)
_PROVABLY_NOT_BOOL_EXPRS = (EInt, EString, EAdd, ESub, EMul, EDiv, ENeg, EList, ETuple, EListComp)


def _bool_shape(e):
    """'bool', 'not-bool', or 'unknown' for whether `e` provably produces
    a Bool, provably doesn't, or can't be told without a type checker.
    Recurses into an `if` expression's branches -- if both agree, so does
    the whole expression -- since `if cond then true else false` and
    similar are common enough to be worth not falling back to a runtime
    check for. A variable or a function call is always 'unknown': its
    value could be anything, including a Bool, from where this backend is
    standing."""
    if isinstance(e, EBool) or isinstance(e, _PROVABLY_BOOL_EXPRS):
        return "bool"
    if isinstance(e, _PROVABLY_NOT_BOOL_EXPRS):
        return "not-bool"
    if isinstance(e, EIf):
        then_shape = _bool_shape(e.then_expr)
        return then_shape if then_shape == _bool_shape(e.else_expr) else "unknown"
    return "unknown"


def _wrap_print_argument(pyking_expr, translated, info):
    """One argument to a `print` call, formatted for Pyking's boolean
    spelling: an inline `'true' if <expr> else 'false'` when `_bool_shape`
    proves `pyking_expr` is always a Bool (no runtime check needed at
    all -- this is the common case, e.g. any comparison), the translated
    expression completely unwrapped when it proves the opposite (an Int,
    a String, a list, ...), and only otherwise -- genuinely unknown --
    a call through the `_bool_format_helper_name` helper, which is what
    actually brings that helper into existence in the first place."""
    shape = _bool_shape(pyking_expr)
    if shape == "bool":
        return PyIfExp(info, translated, PyString(info, "true"), PyString(info, "false"))
    if shape == "not-bool":
        return translated
    helper = PyVar(info, _bool_format_helper_name(info))
    return PyCall(info, helper, [translated])


def translate_expr(e, scope):
    match e:
        case EInt(info, v):
            return PyInt(info, v)
        case EString(info, s):
            return PyString(info, s)
        case EBool(info, v):
            return PyBool(info, v)
        case EVar(info, name):
            return PyVar(info, _lookup(name, scope))
        case EAdd(info, l, r):
            return PyAdd(info, translate_expr(l, scope), translate_expr(r, scope))
        case ESub(info, l, r):
            return PySub(info, translate_expr(l, scope), translate_expr(r, scope))
        case EMul(info, l, r):
            return PyMul(info, translate_expr(l, scope), translate_expr(r, scope))
        case EDiv(info, l, r):
            return PyDiv(info, translate_expr(l, scope), translate_expr(r, scope))
        case ENeg(info, operand):
            return PyNeg(info, translate_expr(operand, scope))
        case ELessThan(info, l, r):
            return PyLessThan(info, translate_expr(l, scope), translate_expr(r, scope))
        case ELessThanEq(info, l, r):
            return PyLessThanEq(info, translate_expr(l, scope), translate_expr(r, scope))
        case EGreatThan(info, l, r):
            return PyGreatThan(info, translate_expr(l, scope), translate_expr(r, scope))
        case EGreatThanEq(info, l, r):
            return PyGreatThanEq(info, translate_expr(l, scope), translate_expr(r, scope))
        case EEq(info, l, r):
            return PyEq(info, translate_expr(l, scope), translate_expr(r, scope))
        case ECall(info, EVar(_, name), args) if runtime_interface.lookup(name) is not None:
            # A call to a runtime_interface operation (just `print` today):
            # its arguments are formatted, not merely printed, and Pyking's
            # own `true`/`false` spelling for a Bool is one place that
            # differs from Python's `True`/`False` -- see
            # `_wrap_print_argument`.
            return PyCall(
                info,
                PyVar(info, name),
                [_wrap_print_argument(a, translate_expr(a, scope), info) for a in args],
            )
        case ECall(info, f, args):
            return PyCall(
                info,
                translate_expr(f, scope),
                [translate_expr(a, scope) for a in args],
            )
        case EList(info, elements):
            return PyList(info, [translate_expr(el, scope) for el in elements])
        case ETuple(info, elements):
            return PyTuple(info, [translate_expr(el, scope) for el in elements])
        case EIf(info, cond, then_expr, else_expr):
            # Pyking's `if c then a else b` is exactly Python's conditional
            # expression `a if c else b` -- same semantics (both branches
            # lazy, `else` mandatory), only the operand order differs.
            return PyIfExp(
                info,
                translate_expr(cond, scope),
                translate_expr(then_expr, scope),
                translate_expr(else_expr, scope),
            )
        case EListComp(info, expr, clauses):
            # A Python comprehension has its own scope, exactly like a
            # Pyking one, so its variables never need renaming -- but they
            # must not leak into the enclosing scope either, hence the
            # `_function_scope`.
            comp_scope = _function_scope(scope)
            py_clauses = []
            for clause in clauses:
                match clause:
                    case CompFor():
                        clause_py, comp_scope = _translate_comp_for(clause, comp_scope)
                        py_clauses += clause_py
                    case CompIf(_, condition):
                        py_clauses.append(
                            PyCompIf(clause.info, translate_expr(condition, comp_scope))
                        )
            return PyListComp(info, translate_expr(expr, comp_scope), py_clauses)
        case _:
            raise NotImplementedError(f"no Python translation for expression {e!r}")


def translate_pattern(p, scope):
    """Translates a pattern, returning it with the scope its captures
    extend -- a `case` arm's pattern binds in the enclosing Python
    function scope (Python's `match` is not a scope), so those names go
    through `_bind` and may be renamed like any other binding."""
    match p:
        case PInt(info, v):
            return PyPInt(info, v), scope
        case PString(info, s):
            return PyPString(info, s), scope
        case PBool(info, v):
            return PyPBool(info, v), scope
        case PWildcard(info):
            return PyPWildcard(info), scope
        case PCapture(info, name):
            py_name, scope = _bind(name, scope)
            return PyPCapture(info, py_name), scope
        case PTuple(info, elements):
            py_elements = []
            for element in elements:
                py_element, scope = translate_pattern(element, scope)
                py_elements.append(py_element)
            return PyPTuple(info, py_elements), scope
        case PList(info, prefix, rest, suffix):
            py_prefix = []
            for element in prefix:
                py_element, scope = translate_pattern(element, scope)
                py_prefix.append(py_element)
            py_rest = None
            if rest is not None:
                if rest.name is None:
                    py_rest = PyListRest(rest.info, None)
                else:
                    py_name, scope = _bind(rest.name, scope)
                    py_rest = PyListRest(rest.info, py_name)
            py_suffix = []
            for element in (suffix or []):
                py_element, scope = translate_pattern(element, scope)
                py_suffix.append(py_element)
            return PyPList(info, py_prefix, py_rest, py_suffix), scope
        case _:
            raise NotImplementedError(f"no Python translation for pattern {p!r}")


def translate_target(t, scope):
    """Translates an assignment target, returning it with the scope its
    names extend."""
    match t:
        case TargetName(info, name):
            py_name, scope = _bind(name, scope)
            return PyTargetName(info, py_name), scope
        case TargetTuple(info, elements):
            py_elements = []
            for element in elements:
                py_element, scope = translate_target(element, scope)
                py_elements.append(py_element)
            return PyTargetTuple(info, py_elements), scope
        case _:
            raise NotImplementedError(f"no Python translation for assignment target {t!r}")


def translate_case(c, scope):
    # Pyking's single-expression `case pattern -> expr` has no Python
    # equivalent, so it desugars here into an ordinary case block whose
    # body is just `return expr` -- the Python target AST itself gains no
    # new node for this; PyMatchCase always just has a `body`.
    #
    # The arm is a block: its pattern binds into a scope of its own, and
    # neither the pattern's names nor the arm's bindings escape it.
    py_pattern, arm_scope = translate_pattern(c.pattern, _block_scope(scope))
    if c.expr is not None:
        translated_expr = translate_expr(c.expr, arm_scope)
        body = [PyReturn(translated_expr.info, translated_expr)]
    else:
        body, _ = _translate_stmts(c.body, arm_scope)
    return PyMatchCase(c.info, py_pattern, body)


def _yields_unit(expr):
    """Whether `expr` is a call across the runtime interface (`print`
    today). Those yield unit, and Python's own implicit `None` already
    *is* unit, so a function whose tail is one needs no `return` emitted
    at all -- writing `return print(x)` would say the same thing less
    clearly, and is the one form the C and Java backends cannot express
    (they refuse `print` as a value)."""
    match expr:
        case ECall(_, EVar(_, name), _):
            return runtime_interface.lookup(name) is not None
        case _:
            return False


def _translate_tail_block(stmts, scope):
    """Translates a statement list whose last statement is in **tail
    position** -- a function body, or a branch of one that is itself in
    tail position. Everything but the last statement translates
    normally; the last goes through `_translate_tail_stmt`.

    This is the same recursion `_translate_value_block` performs for a
    value-form binding, with `return` in place of the assignment, which
    is why an `if` nested in a `match` nested in an `if` needs no case of
    its own: each level hands its branch tails back to this function."""
    if not stmts:
        return []
    body, tail_scope = _translate_stmts(stmts[:-1], scope)
    return body + _translate_tail_stmt(stmts[-1], tail_scope)


def _translate_tail_stmt(s, scope):
    """The last statement of a body in tail position, as a list of Python
    statements. An expression becomes the function's return value; an
    `if`/`match` pushes the rule down into its branches (so each branch
    returns its own tail); anything else -- a loop, a binding, an
    explicit `return` -- translates exactly as it would anywhere else."""
    match s:
        case SExprStmt(_, expr) if _yields_unit(expr):
            translated, _ = translate_stmt(s, scope)
            return [translated]
        case SExprStmt(info, expr):
            return [PyReturn(info, translate_expr(expr, scope))]
        case SIf(info, cond, then_body, else_body):
            # An `if` with no `else` leaves that path with no value; it
            # simply falls out of the function, which is Python's own
            # implicit `None` -- i.e. unit.
            return [
                PyIf(
                    info,
                    translate_expr(cond, scope),
                    _translate_tail_block(then_body, _block_scope(scope)),
                    None
                    if else_body is None
                    else _translate_tail_block(else_body, _block_scope(scope)),
                )
            ]
        case SMatch(info, subject, cases):
            return [
                PyMatch(
                    info,
                    translate_expr(subject, scope),
                    [_translate_tail_case(c, scope) for c in cases],
                )
            ]
        case _:
            translated, _ = translate_stmt(s, scope)
            return [translated]


def _falls_through(py_body):
    """Whether control can reach the end of `py_body` without returning.

    Used to decide whether a function needs an explicit `return ()`:
    Pyking's unit is the empty tuple, and Python's own implicit `None` is
    *not* it -- printing one would write `None` where every other backend
    writes `()`. Emitting the return where control can fall out keeps
    unit a real value rather than a formatting special case, so no
    print-time conversion (and no prelude) is needed for it."""
    if not py_body:
        return True
    match py_body[-1]:
        case PyReturn():
            return False
        case PyIf(_, _, then_body, else_body) if else_body is not None:
            return _falls_through(then_body) or _falls_through(else_body)
        case PyMatch(_, _, cases) if any(
            isinstance(c.pattern, (PyPWildcard, PyPCapture)) for c in cases
        ):
            # Only a `match` with an irrefutable arm is guaranteed to run
            # one; otherwise an unmatched subject falls straight through.
            return any(_falls_through(c.body) for c in cases)
        case _:
            return True


def _translate_tail_case(c, scope):
    """One `case` arm of a `match` in tail position. `case p -> expr`
    already means `return expr`, so it is exactly `translate_case`'s job;
    a block arm hands its own tail back to `_translate_tail_block`."""
    if c.expr is not None:
        return translate_case(c, scope)
    py_pattern, arm_scope = translate_pattern(c.pattern, _block_scope(scope))
    return PyMatchCase(c.info, py_pattern, _translate_tail_block(c.body, arm_scope))


def _translate_value_stmt(s, py_target, scope):
    """Translates an if/match statement in *value form* -- one bound with
    '=' (see `SLetStmt` in syntax.py) -- into the very same PyIf/PyMatch
    the plain statement form produces, except that each branch's final
    expression becomes an assignment of that expression to `py_target`.

    Python has no statement that evaluates to a value, so the binding is
    pushed down into the branch tails instead of the whole construct
    being made an expression; that keeps everything else about a branch
    (bindings, mutations of an enclosing `var`, prints) working exactly
    as it does in the statement form, which wrapping the branches in a
    helper function would not."""
    match s:
        case SIf(info, cond, then_body, else_body):
            # The parser guarantees `else_body` is not None here.
            return PyIf(
                info,
                translate_expr(cond, scope),
                _translate_value_block(then_body, py_target, scope),
                _translate_value_block(else_body, py_target, scope),
            )
        case SMatch(info, subject, cases):
            return PyMatch(
                info,
                translate_expr(subject, scope),
                [_translate_value_case(c, py_target, scope) for c in cases],
            )
        case _:
            raise NotImplementedError(f"statement {s!r} has no value form")


def _translate_value_block(stmts, py_target, scope):
    """Translates one branch of a value-form if/match: every statement but
    the last is translated normally, and the last -- which the parser has
    checked yields a value (see `_check_value_block` there) -- either
    becomes the assignment to `py_target`, or, when it is itself an
    if/match, has the same treatment applied to *its* branch tails. The
    branch is a block, so it gets its own scope."""
    body, branch_scope = _translate_stmts(stmts[:-1], _block_scope(scope))
    match stmts[-1]:
        case SExprStmt(info, expr):
            body.append(PyAssign(info, py_target, translate_expr(expr, branch_scope)))
        case SIf() | SMatch() as nested:
            body.append(_translate_value_stmt(nested, py_target, branch_scope))
        case last:
            raise NotImplementedError(f"statement {last!r} yields no value")
    return body


def _translate_value_case(c, py_target, scope):
    # `case pattern -> expr` binds the expression directly; the block form
    # goes through `_translate_value_block` like an `if` branch. (Contrast
    # `translate_case`, which desugars `->` to a `return` instead -- that
    # is what a case arm means outside a binding.)
    py_pattern, arm_scope = translate_pattern(c.pattern, _block_scope(scope))
    if c.expr is not None:
        translated_expr = translate_expr(c.expr, arm_scope)
        body = [PyAssign(translated_expr.info, py_target, translated_expr)]
    else:
        body = _translate_value_block(c.body, py_target, arm_scope)
    return PyMatchCase(c.info, py_pattern, body)


def translate_stmt(s, scope):
    """Translates one statement, returning it with the scope it leaves
    behind -- that is how a sequence of statements accumulates bindings,
    and how a binding's rename becomes visible to what follows it."""
    match s:
        case SLet(info, target, expr):
            # The right-hand side is translated *before* the target binds,
            # so `x = x + 1` reads the outer `x` -- if that binding is a
            # shadowing one, the read still resolves to the old name.
            py_expr = translate_expr(expr, scope)
            py_target, scope = translate_target(target, scope)
            return PyAssign(info, py_target, py_expr), scope

        case SLetStmt(_, target, stmt):
            # The target binds in *this* scope (the branches are blocks of
            # their own) and is bound first, so a branch that shadows a
            # name cannot be handed the Python name the target is using.
            py_target, scope = translate_target(target, scope)
            return _translate_value_stmt(stmt, py_target, scope), scope

        case SVar(info, name, expr):
            py_expr = translate_expr(expr, scope)
            py_name, scope = _bind(name, scope)
            return PyAssign(info, PyTargetName(info, py_name), py_expr), scope

        case SMutate(info, name, expr):
            # An update, not a binding: it reuses the variable's name,
            # whatever renaming that variable got when it was declared.
            py_expr = translate_expr(expr, scope)
            py_name = _lookup(name, scope)
            return PyAssign(info, PyTargetName(info, py_name), py_expr), scope

        case SReturn(info, expr):
            return PyReturn(info, translate_expr(expr, scope)), scope

        case SExprStmt(info, expr):
            return PyExprStmt(info, translate_expr(expr, scope)), scope

        case SFor(info, name, iterable, body):
            py_iterable = translate_expr(iterable, scope)
            # The loop variable belongs to the body's scope, and Python's
            # `for` target is function-scoped, so it renames like anything
            # else when it shadows.
            py_name, body_scope = _bind(name, _block_scope(scope))
            py_body, _ = _translate_stmts(body, body_scope)
            return PyFor(info, py_name, py_iterable, py_body), scope

        case SWhile(info, cond, body):
            py_body, _ = _translate_stmts(body, _block_scope(scope))
            return PyWhile(info, translate_expr(cond, scope), py_body), scope

        case SIf(info, cond, then_body, else_body):
            py_then, _ = _translate_stmts(then_body, _block_scope(scope))
            py_else = None
            if else_body is not None:
                py_else, _ = _translate_stmts(else_body, _block_scope(scope))
            return PyIf(info, translate_expr(cond, scope), py_then, py_else), scope

        case SFunctionDef(info, name, params, body, _return_type, expr):
            # Pyking's single-expression `def name(...) = expr` has no
            # Python equivalent, so it desugars here into an ordinary
            # function body of just `return expr` -- mirrors
            # `translate_case`'s handling of `case pattern -> expr`.
            #
            # The function's own name binds in the enclosing scope (and so
            # may be renamed); its parameters and body open a fresh Python
            # scope, where nothing can collide with the outside and so
            # nothing is renamed.
            py_name, scope = _bind(name, scope)
            body_scope = _function_scope(scope)
            param_names = []
            for param in params:
                py_param, body_scope = _bind(param.name, body_scope)
                param_names.append(py_param)
            if expr is not None:
                translated_expr = translate_expr(expr, body_scope)
                py_body = [PyReturn(translated_expr.info, translated_expr)]
            else:
                # The body's last statement is in tail position: whatever
                # value it produces is the function's result. See
                # `_translate_tail_block`. A body that can fall out of
                # the end produces unit on that path, and unit is `()`,
                # not Python's implicit `None` -- see `_falls_through`.
                py_body = _translate_tail_block(body, body_scope)
                if _falls_through(py_body):
                    py_body.append(PyReturn(info, PyTuple(info, [])))
            return PyFunctionDef(info, py_name, param_names, py_body), scope

        case SReturnStmt(_, stmt):
            # `return if c:` / `return match e:` -- the same push-down as
            # a tail-position if/match, just written explicitly, so it
            # also works where the implicit rule cannot reach: before the
            # end of the body.
            return _translate_tail_stmt(stmt, scope)[0], scope

        case SMatch(info, subject, cases):
            py_subject = translate_expr(subject, scope)
            return PyMatch(info, py_subject, [translate_case(c, scope) for c in cases]), scope

        case _:
            raise NotImplementedError(f"no Python translation for statement {s!r}")


def _translate_stmts(stmts, scope):
    """Translates a statement sequence, threading the scope through it,
    and returns the statements with the scope they leave behind. A caller
    that is entering a *block* passes a `_block_scope` and ignores the
    returned scope -- that is what keeps a block's bindings from escaping
    into the code after it."""
    translated = []
    for s in stmts:
        py_stmt, scope = translate_stmt(s, scope)
        translated.append(py_stmt)
    return translated, scope


def translate_program(stmts):
    """External entry point: translates a full program, resetting the
    comprehension-helper and boolean-print-helper state first and
    prepending every comprehension helper synthesized along the way (see
    the module comment above) to the translated statements, returned
    together with any boolean-print-formatting prelude as a `PyProgram`
    for `pprint_py_program` to print."""
    global _comp_counter, _pending_comp_helpers, _used_identifiers
    global _bool_format_helper_name_value, _bool_format_helper_def
    _comp_counter = 0
    _pending_comp_helpers = []
    _bool_format_helper_name_value = None
    _bool_format_helper_def = None
    _used_identifiers = _collect_identifiers(stmts)
    translated, _ = _translate_stmts(stmts, Scope({}, {}, frozenset()))
    helpers = _pending_comp_helpers
    _pending_comp_helpers = []
    prelude = [_bool_format_helper_def] if _bool_format_helper_def is not None else []
    return PyProgram(prelude, helpers + translated)


# --- pretty printer: Python target AST -> Python source text ---

def _wrap(prec, min_prec, s):
    return f"({s})" if prec < min_prec else s


_PRINT_ESCAPES = {
    "\\": "\\\\",
    "'": "\\'",
    "\n": "\\n",
    "\t": "\\t",
    "\r": "\\r",
}


def _quote_string(s):
    body = "".join(_PRINT_ESCAPES.get(ch, ch) for ch in s)
    return f"'{body}'"


def pprint_py_expr(e, min_prec=0):
    match e:
        case PyInt(_, v):
            return str(v)
        case PyString(_, s):
            return _quote_string(s)
        case PyBool(_, v):
            return "True" if v else "False"
        case PyVar(_, name):
            return name
        case PyAdd(_, l, r):
            return _wrap(2, min_prec, f"{pprint_py_expr(l, 2)} + {pprint_py_expr(r, 3)}")
        case PySub(_, l, r):
            return _wrap(2, min_prec, f"{pprint_py_expr(l, 2)} - {pprint_py_expr(r, 3)}")
        case PyMul(_, l, r):
            return _wrap(3, min_prec, f"{pprint_py_expr(l, 3)} * {pprint_py_expr(r, 4)}")
        case PyDiv(_, l, r):
            return _wrap(3, min_prec, f"{pprint_py_expr(l, 3)} / {pprint_py_expr(r, 4)}")
        case PyNeg(_, operand):
            # Python's unary minus binds tighter than `*`/`/` too, so the
            # same precedences as Pyking's `ENeg` apply (see `pprint_expr`
            # in syntax.py): 4 for itself, 5 for its operand.
            return _wrap(4, min_prec, f"-{pprint_py_expr(operand, 5)}")
        case PyLessThan(_, l, r):
            return _wrap(1, min_prec, f"{pprint_py_expr(l, 2)} < {pprint_py_expr(r, 2)}")
        case PyLessThanEq(_, l, r):
            return _wrap(1, min_prec, f"{pprint_py_expr(l, 2)} <= {pprint_py_expr(r, 2)}")
        case PyGreatThan(_, l, r):
            return _wrap(1, min_prec, f"{pprint_py_expr(l, 2)} > {pprint_py_expr(r, 2)}")
        case PyGreatThanEq(_, l, r):
            return _wrap(1, min_prec, f"{pprint_py_expr(l, 2)} >= {pprint_py_expr(r, 2)}")
        case PyEq(_, l, r):
            return _wrap(1, min_prec, f"{pprint_py_expr(l, 2)} == {pprint_py_expr(r, 2)}")
        case PyCall(_, f, args):
            # The callee prints at 5 so a negated one keeps its parens:
            # `(-f)(x)` calls the negation, `-f(x)` negates the result.
            return f"{pprint_py_expr(f, 5)}({', '.join(pprint_py_expr(a) for a in args)})"
        case PyList(_, elements):
            return f"[{', '.join(pprint_py_expr(el) for el in elements)}]"
        case PyTuple(_, elements):
            match elements:
                case [single]:
                    return f"({pprint_py_expr(single)},)"
                case _:
                    return f"({', '.join(pprint_py_expr(el) for el in elements)})"
        case PyListComp(_, expr, clauses):
            clauses_str = " ".join(pprint_py_comp_clause(c) for c in clauses)
            return f"[{pprint_py_expr(expr)} {clauses_str}]"
        case PyIfExp(_, cond, then_expr, else_expr):
            # Python's conditional expression binds looser than every
            # operator here, so precedence 0 -- as an operand of anything it
            # gets parenthesized. `then_expr`/`cond` print at 1 so a nested
            # conditional there is parenthesized; the else branch prints at
            # 0, keeping a right-associative `else ... if ... else` chain
            # flat, exactly as Python itself associates it.
            return _wrap(0, min_prec, (
                f"{pprint_py_expr(then_expr, 1)} if {pprint_py_expr(cond, 1)} "
                f"else {pprint_py_expr(else_expr)}"
            ))
        case _:
            raise NotImplementedError(f"no pretty printer for Python expression {e!r}")


def pprint_py_comp_clause(c):
    # Both sub-expressions print at min_prec 1, which parenthesizes a
    # PyIfExp (precedence 0). These parens are *required*, not cosmetic:
    # Python's comprehension grammar admits only an `or_test` after `in`
    # and after a filtering `if`, deliberately excluding the conditional
    # expression so its `if`/`else` can't be confused with the
    # comprehension's own. Without them, `[x for x in xs if b if a else c]`
    # and `[x for x in b if a else c]` are both Python syntax errors.
    match c:
        case PyCompFor(_, target, sequence):
            return f"for {pprint_py_target(target)} in {pprint_py_expr(sequence, 1)}"
        case PyCompIf(_, condition):
            return f"if {pprint_py_expr(condition, 1)}"


def pprint_py_pattern(p):
    match p:
        case PyPInt(_, v):
            return str(v)
        case PyPString(_, s):
            return _quote_string(s)
        case PyPBool(_, v):
            # `True`/`False` (capitalised) are two of the handful of names
            # Python's own `match` treats as a *value* pattern rather than
            # a capture, per PEP 634 -- exactly the literal-match behaviour
            # `PBool` needs, with no extra work here.
            return "True" if v else "False"
        case PyPWildcard(_):
            return "_"
        case PyPCapture(_, name):
            return name
        case PyPTuple(_, elements):
            match elements:
                case [single]:
                    return f"({pprint_py_pattern(single)},)"
                case _:
                    return f"({', '.join(pprint_py_pattern(e) for e in elements)})"
        case PyPList(_, prefix, rest, suffix):
            parts = [pprint_py_pattern(e) for e in prefix]
            if rest is not None:
                parts.append(f"*{rest.name}" if rest.name is not None else "*_")
            parts += [pprint_py_pattern(e) for e in (suffix or [])]
            return f"[{', '.join(parts)}]"
        case _:
            raise NotImplementedError(f"no pretty printer for Python pattern {p!r}")


def pprint_py_target(t):
    match t:
        case PyTargetName(_, name):
            return name
        case PyTargetTuple(_, elements):
            match elements:
                case [single]:
                    return f"({pprint_py_target(single)},)"
                case _:
                    return f"({', '.join(pprint_py_target(e) for e in elements)})"
        case _:
            raise NotImplementedError(f"no pretty printer for Python target {t!r}")


def _render_block(stmts, level):
    """Renders a same-scope statement list as a list of lines, one blank
    line before and after every nested `def` (but never at the very start
    or end of the block, where it would only leave a dangling blank line
    against the header or the dedent) -- ordinary Python style, and the
    same rule `pprint_py_program` applies at the top level below."""
    lines = []
    prev_was_def = False
    for i, st in enumerate(stmts):
        is_def = isinstance(st, PyFunctionDef)
        if i > 0 and (is_def or prev_was_def):
            lines.append("")
        lines.append(pprint_py_stmt(st, level))
        prev_was_def = is_def
    return lines


def pprint_py_stmt(s, level=0):
    pad = "    " * level
    match s:
        case PyAssign(_, target, expr):
            return f"{pad}{pprint_py_target(target)} = {pprint_py_expr(expr)}"
        case PyReturn(_, expr):
            return f"{pad}return {pprint_py_expr(expr)}"
        case PyExprStmt(_, expr):
            return f"{pad}{pprint_py_expr(expr)}"
        case PyFor(_, name, iterable, body):
            lines = [f"{pad}for {name} in {pprint_py_expr(iterable)}:"]
            lines += _render_block(body, level + 1)
            return "\n".join(lines)
        case PyWhile(_, cond, body):
            lines = [f"{pad}while {pprint_py_expr(cond)}:"]
            lines += _render_block(body, level + 1)
            return "\n".join(lines)
        case PyIf(_, cond, then_body, else_body):
            lines = [f"{pad}if {pprint_py_expr(cond)}:"]
            lines += _render_block(then_body, level + 1)
            # An else body of exactly one `if` prints as Python's `elif`,
            # which is defined as precisely that nesting -- same semantics,
            # but a Pyking `else if` ladder (which translates to nested
            # `PyIf`s, see `parse_if_stmt_tail` in parser.py) then comes out
            # as a flat `if`/`elif`/`else` chain in the generated source
            # instead of stepping one indent level right per branch.
            while True:
                match else_body:
                    case [PyIf(_, elif_cond, elif_body, else_body2)]:
                        lines.append(f"{pad}elif {pprint_py_expr(elif_cond)}:")
                        lines += _render_block(elif_body, level + 1)
                        else_body = else_body2
                    case None:
                        break
                    case _:
                        lines.append(f"{pad}else:")
                        lines += _render_block(else_body, level + 1)
                        break
            return "\n".join(lines)
        case PyFunctionDef(_, name, params, body):
            lines = [f"{pad}def {name}({', '.join(params)}):"]
            lines += _render_block(body, level + 1)
            return "\n".join(lines)
        case PyMatch(_, subject, cases):
            lines = [f"{pad}match {pprint_py_expr(subject)}:"]
            for c in cases:
                lines.append(f"{pad}    case {pprint_py_pattern(c.pattern)}:")
                lines += _render_block(c.body, level + 2)
            return "\n".join(lines)
        case _:
            raise NotImplementedError(f"no pretty printer for Python statement {s!r}")


# Markers around the prelude, matching the convention
# `target_js_packaging.py` uses for the same reason: so a reader can see
# at a glance which lines came from the `.pyk` source and which are host
# boilerplate around it. Only ever present when `_bool_format_helper_name`
# actually built the helper -- see `translate_program`/`PyProgram`.
_PRELUDE_BEGIN = "\n".join([
    "# --- prelude begins ---",
    "# Pyking prints a Bool as `true`/`false`, not Python's own capitalised",
    "# `True`/`False`; this helper exists because at least one value printed",
    "# below isn't provably a Bool from its Pyking source form alone (a",
    "# variable or a function call), so it has to be checked at runtime.",
])
_PRELUDE_END = "# --- prelude ends; the compiled program follows ---"


def pprint_py_program(program):
    body = "\n".join(_render_block(program.stmts, 0))
    if not program.prelude:
        return body
    prelude_body = "\n".join(_render_block(program.prelude, 0))
    return "\n".join([_PRELUDE_BEGIN, "", prelude_body, "", _PRELUDE_END, "", body])
