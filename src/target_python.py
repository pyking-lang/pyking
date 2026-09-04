"""The Python code-generation backend: Pyking AST (syntax.py) to a
Python-shaped AST (Py*) to Python source text. See docs/target_python.md
for how each construct compiles and where the output is not optimal.

Data structures:
    PyExpr / PyPattern / PyTarget / PyCompClause / PyStmt -- base classes
        for the Python-target AST; see the trailing comment on each
        variant for its shape.
    PyProgram -- a translated program (see its own docstring).
    Scope -- Pyking name -> Python name, threaded through translation
        (see its own docstring).

Functions:
    translate_program(stmts) -- translates a whole program to PyProgram.
    translate_expr(e, scope) -- translates one expression.
    translate_stmt(s, scope) -- translates one statement; returns
        (PyStmt, Scope).
    translate_pattern(p, scope) / translate_target(t, scope, ...) --
        translate a match pattern / assignment target.
    pprint_py_program(program) -- PyProgram to Python source text.
    pprint_py_expr(e) / pprint_py_stmt(s) -- one node to source text.
"""

import keyword
from dataclasses import dataclass, field, fields, is_dataclass, replace

import runtime_interface
from lexer import Info
from analyses import walk
from syntax import (
    EInt, EString, EBool, EVar, EQualified,
    EAdd, EConcat, ESub, EMul, EDiv, ENeg,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EList, ETuple,
    EIf, EListComp, CompFor, CompIf,
    PInt, PString, PBool, PWildcard, PCapture, PTuple, PList, PText,
    SLet, SLetStmt, SVar, SMutate, SReturn, SReturnStmt, SExprStmt, SIf,
    ForIn, WhileTest,
    SLoop, SBreak, SContinue,
    SFunctionDef, SMatch, SImport,
    TInt, TString, TBool, TList, TTuple, TVar,
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
class PyFloorDiv(PyExpr):   # left // right
    info: Info               # Only the division helper builds one: Pyking's
    left: PyExpr             # `/` truncates and Python's `//` floors, so the
    right: PyExpr            # helper corrects the sign around this.


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
class PyAttr(PyExpr):       # target.name
    info: Info
    target: PyExpr
    name: str


@dataclass(frozen=True)
class PyAnd(PyExpr):        # left and right
    info: Info
    left: PyExpr
    right: PyExpr


@dataclass(frozen=True)
class PySlice(PyExpr):      # target[start:stop]; either end may be absent
    info: Info
    target: PyExpr
    start: PyExpr = None
    stop: PyExpr = None


@dataclass(frozen=True)
class PyIndex(PyExpr):      # target[index]
    info: Info
    target: PyExpr
    index: PyExpr


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
class PyPGuarded(PyPattern):  # case str() as name:  -- with a guard and
    info: Info                 # some bindings the arm opens with, both
    name: str                  # supplied by whoever built it.
    guard: object = None       # PyExpr
    bindings: tuple = ()       # [PyStmt]


@dataclass(frozen=True)
class PyPList(PyPattern):   # case [p1, ..., *rest_or_wildcard, ..., pk]:
    info: Info
    prefix: list
    rest: PyListRest = None  # None => no star sub-pattern (exact-length list)
    suffix: list = None


@dataclass(frozen=True)
class PyMatchCase:          # case pattern [if guard]: body
    info: Info
    pattern: PyPattern
    body: list
    guard: PyExpr = None     # Python has no string-splitting pattern, so
                             # `case "ab" ++ rest:` becomes a capture with
                             # a guard and one assignment at the top of
                             # the arm (see `translate_pattern`).


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
class PyImport(PyStmt):     # import module [as alias]
    info: Info
    module: str
    alias: str = None       # None where the module keeps its own name


@dataclass(frozen=True)
class PyFromImport(PyStmt):  # from module import name [as alias], ...
    info: Info
    module: str
    fields: list            # list[(str, str)] -- exported name, local name


@dataclass(frozen=True)
class PyGlobal(PyStmt):     # global a, b
    info: Info
    names: list


@dataclass(frozen=True)
class PyNonlocal(PyStmt):   # nonlocal a, b
    info: Info
    names: list


@dataclass(frozen=True)
class PyFor(PyStmt):        # for name in iterable: body [else: orelse]
    info: Info
    name: str
    iterable: PyExpr
    body: list
    orelse: list = None      # Python's loop `else`, which runs exactly
                             # when no `break` fired -- Pyking's `then:`.


@dataclass(frozen=True)
class PyWhile(PyStmt):      # while cond: body [else: orelse]
    info: Info
    cond: PyExpr
    body: list
    orelse: list = None      # as `PyFor.orelse`.


@dataclass(frozen=True)
class PyBreak(PyStmt):      # break
    info: Info


@dataclass(frozen=True)
class PyContinue(PyStmt):   # continue
    info: Info


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
    """A translated program. Fields: prelude, [PyStmt] (host boilerplate,
    e.g. the Bool-printing helper; usually empty), stmts, [PyStmt] (the
    translated program)."""
    prelude: list
    stmts: list


# --- translation: Pyking AST (syntax.py) -> Python target AST ---
#
# Refutable comprehension patterns compile to a generated __pm* helper;
# see docs/target_python.md, "List comprehensions with refutable
# patterns".

_comp_counter = 0
_pending_comp_helpers = []
# Every identifier used anywhere in the source, so generated names never
# collide with one.
_used_identifiers = set()

# The type checker's symbol -> type table, set by `translate_program`.
# What a `print` argument is worth knowing about is its type, and this
# is where that is read from.
_tmap = {}

# Lazily generated helper for printing a value that might hold a Bool
# at runtime but whose type does not say so; see
# docs/target_python.md, "Booleans".
_format_helper_name_value = None
_format_helper_def = None
_divide_helper_def = None


def _import_identifiers(stmts):
    """Every identifier an import puts in play that the generic walk
    below does not see: a module's own name, which is not held in a
    field named `name`, and the local names of a `from` line, which are
    the second half of a pair. [Stmt] -> {String}"""
    found = set()
    for statement in walk(stmts):
        match statement:
            case SImport(_, module_name, _, _, fields):
                found.add(module_name)
                found.update(local for _, local in fields or ())
            case EQualified(_, module_name, _):
                found.add(module_name)
    return found


def _collect_identifiers(node, acc=None):
    """Every identifier used anywhere in node, as a set. Relies on every
    field literally named name holding an identifier in syntax.py.
    Expr|Stmt|... -> {String}? -> {String}"""
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
    """A fresh (item_var, helper_name) pair for one refutable
    comprehension clause, e.g. ('item1', '__pm1'), guaranteed not to
    collide with any source identifier. () -> (String, String)"""
    global _comp_counter
    while True:
        _comp_counter += 1
        item = f"item{_comp_counter}"
        helper = f"__pm{_comp_counter}"
        if item not in _used_identifiers and helper not in _used_identifiers:
            return item, helper


_turn_counter = 0


def _fresh_turn_name():
    """A fresh name for a per-iteration factory (__pyk_turn1), guaranteed
    not to collide with any source identifier. () -> String"""
    global _turn_counter
    while True:
        _turn_counter += 1
        name = f"__pyk_turn{_turn_counter}"
        if name not in _used_identifiers:
            return name


def pattern_captured_names(pattern):
    """The names pattern would bind, in order. Pattern -> [String]"""
    match pattern:
        case PCapture(_, name):
            return [name]
        case PTuple(_, elements):
            return [n for e in elements for n in pattern_captured_names(e)]
        case PText(_, _, name, _, _):
            return [] if name is None else [name]
        case PList(_, prefix, rest, suffix):
            names = [n for e in prefix for n in pattern_captured_names(e)]
            if rest is not None and rest.name is not None:
                names.append(rest.name)
            names += [n for e in (suffix or []) for n in pattern_captured_names(e)]
            return names
        case _:
            return []


def _is_irrefutable(pattern):
    """Whether pattern matches every value it could be given -- names,
    `_`, and tuples built from those -- so it needs no match helper in a
    comprehension (docs/target_python.md, "List comprehensions with
    refutable patterns"). Pattern -> Bool"""
    match pattern:
        case PCapture(_, _) | PWildcard(_):
            return True
        case PTuple(_, elements):
            return all(_is_irrefutable(e) for e in elements)
        case _:
            return False


def _pattern_to_target(pattern, scope):
    """An irrefutable pattern compiled directly to a Python
    assignment/for target. Pattern -> Scope -> (PyTarget, Scope)"""
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
# Pyking blocks are scopes; Python's are not. A binding is renamed only
# when it would otherwise be confused with a live one in the same Python
# function scope. See docs/target_python.md, "Blocks are scopes;
# Python's are not".


@dataclass(frozen=True)
class Scope:
    """The names in scope during translation. Fields:
    outer: {String: String} (Pyking name -> Python name, from enclosing
        Python function scopes),
    local: {String: String} (same, for the current Python function scope),
    block: {String} (names bound by the innermost Pyking block),
    shadowed: {String} (outer names this Python scope reads; see
        _free_names),
    captured: {String} (names functions defined in this scope read from
        around them; see _captured_names),
    loop_names: {String}? (names the nearest enclosing loop rebinds each
        turn, or None outside a loop),
    depth: Int (how many Python function scopes deep this is; 0 is the
        module),
    mutables: {String: Int} (each `var` in scope, and the depth its
        declaration sits at -- what decides `global` from `nonlocal`),
    used: {String} (every Python name handed out by an enclosing block of
        this Python function scope; `local` keeps only the newest name
        per Pyking name, so this is what remembers the ones a shadow
        replaced -- see `_fresh_py_name`)."""
    outer: dict
    local: dict
    block: frozenset
    shadowed: frozenset = frozenset()
    captured: frozenset = frozenset()
    loop_names: frozenset = None
    depth: int = 0
    mutables: dict = field(default_factory=dict)
    used: frozenset = frozenset()


def _function_scope(scope, shadowed=frozenset(), captured=frozenset()):
    """The scope for a `def` body or a comprehension: Python opens a
    fresh scope there, so everything visible so far becomes closure state
    and nothing inside it can collide with anything outside.

    `shadowed` is what the body reads from *outside* itself (see
    `_free_names`), and so what it may not quietly rebind -- see `_bind`.
    `captured` is what the functions *inside* it read from around them."""
    # `loop_names` is deliberately dropped: a body's own bindings are per
    # *call*, and what it captures from a loop around it was settled where
    # the `def` was written.
    return Scope(
        {**scope.outer, **scope.local}, {}, frozenset(),
        frozenset(shadowed), frozenset(captured), None,
        scope.depth + 1, scope.mutables,
    )


# --- what a body reads from outside itself ---
#
# Any binding inside a Python function makes that name local to the
# whole function, so a block that shadows a name the rest of the
# function still reads cannot keep the plain name either. See
# docs/target_python.md, "Blocks are scopes; Python's are not".


def _captured_names(stmts, bound):
    """The names the functions defined anywhere in this Python function
    scope read from around them -- a rebinding of one of those names
    needs its own Python variable (docs/target_python.md, "A rebinding
    some function captured"). [Stmt] -> {String} -> {String}"""
    captured = set()
    _captured_in_block(stmts, set(bound), captured)
    return frozenset(captured)


def _captured_in_block(stmts, bound, captured):
    """Adds to captured every name a function defined in stmts (or a
    nested block) reads from around it. [Stmt] -> {String} -> {String}
    -> ()"""
    for s in stmts:
        if isinstance(s, SFunctionDef):
            bound.add(s.name)
    for s in stmts:
        match s:
            case SFunctionDef(_, name, params, body, _):
                inner = {name} | {p.name for p in params}
                captured.update(_free_names(body, inner))
                # A function nested inside this one is part of the same
                # question one level down, and is reached when that body
                # is translated.
            case SLoop(_, target, _, _, iterate, body):
                inner = set(bound)
                if target is not None:
                    inner |= set(_target_names(target))
                match iterate:
                    case ForIn(_, name, _, _):
                        _captured_in_block(body, inner | {name}, captured)
                    case _:
                        _captured_in_block(body, inner, captured)
            case SIf(_, _, then_body, else_body):
                _captured_in_block(then_body, set(bound), captured)
                if else_body is not None:
                    _captured_in_block(else_body, set(bound), captured)
            case SLetStmt(_, _, stmt) | SReturnStmt(_, stmt):
                _captured_in_block([stmt], set(bound), captured)
            case SMatch(_, _, cases):
                for c in cases:
                    if c.body is not None:
                        arm = bound | set(pattern_captured_names(c.pattern))
                        _captured_in_block(c.body, arm, captured)
            case _:
                pass


def _free_names(stmts, bound):
    """The names stmts reads from outside itself: every name used before
    stmts (or bound) has bound it. [Stmt] -> {String} -> {String}"""
    free = set()
    _free_in_block(stmts, set(bound), free)
    return frozenset(free)


def _free_in_block(stmts, bound, free):
    """Walks one block, adding to free and extending bound in place as
    the block's own bindings appear. [Stmt] -> {String} -> {String} ->
    ()"""
    # Every `def` in the block is in scope throughout it (see
    # `_declare_functions`), so they are bound before anything is walked.
    for s in stmts:
        if isinstance(s, SFunctionDef):
            bound.add(s.name)
    for s in stmts:
        _free_in_stmt(s, bound, free)


def _free_in_nested(stmts, bound, free):
    """A nested block: sees bound; what it binds does not escape.
    [Stmt] -> {String} -> {String} -> ()"""
    _free_in_block(stmts, set(bound), free)


def _free_in_stmt(s, bound, free):
    """Adds s's free names to free, extending bound in place. Stmt ->
    {String} -> {String} -> ()"""
    match s:
        case SLet(_, target, expr, _):
            _free_in_expr(expr, bound, free)
            bound.update(_target_names(target))
        case SLetStmt(_, target, stmt, _):
            _free_in_stmt(stmt, bound, free)
            bound.update(_target_names(target))
        case SVar(_, name, expr):
            _free_in_expr(expr, bound, free)
            bound.add(name)
        case SMutate(_, name, expr):
            # `:=` writes a `var` that is already in scope; it binds
            # nothing, so an enclosing one stays what the name means.
            if name not in bound:
                free.add(name)
            _free_in_expr(expr, bound, free)
        case SReturn(_, expr) | SExprStmt(_, expr):
            _free_in_expr(expr, bound, free)
        case SReturnStmt(_, stmt):
            _free_in_stmt(stmt, bound, free)
        case SLoop(_, target, init, _, iterate, body):
            # The initializer is read outside the loop; the accumulator
            # is bound in the body and nowhere else.
            inner = set(bound)
            if target is not None:
                _free_in_expr(init, bound, free)
                inner |= set(_target_names(target))
            match iterate:
                case ForIn(_, name, sequence, _):
                    _free_in_expr(sequence, bound, free)
                    _free_in_nested(body, inner | {name}, free)
                case WhileTest(_, condition, _):
                    _free_in_expr(condition, inner, free)
                    _free_in_nested(body, inner, free)
                case _:
                    _free_in_nested(body, inner, free)
        case SBreak() | SContinue():
            pass
        case SIf(_, cond, then_body, else_body):
            _free_in_expr(cond, bound, free)
            _free_in_nested(then_body, bound, free)
            if else_body is not None:
                _free_in_nested(else_body, bound, free)
        case SFunctionDef(_, name, params, body, _):
            bound.add(name)
            _free_in_nested(body, bound | {p.name for p in params}, free)
        case SMatch(_, subject, cases):
            _free_in_expr(subject, bound, free)
            for c in cases:
                arm_bound = bound | set(pattern_captured_names(c.pattern))
                _free_in_nested(c.body, arm_bound, free)
        case _:
            raise NotImplementedError(f"no free-name walk for statement {s!r}")


def _free_in_expr(e, bound, free):
    """Adds e's free names to free. Expr -> {String} -> {String} -> ()"""
    match e:
        case EVar(_, name):
            if name not in bound:
                free.add(name)
        case EQualified(_, module_name, _):
            # What the name reaches is another module's; what is free
            # here is the module itself, which the top level bound.
            if module_name not in bound:
                free.add(module_name)
        case EInt() | EString() | EBool():
            pass
        case ENeg(_, operand):
            _free_in_expr(operand, bound, free)
        case ECall(_, func, args):
            _free_in_expr(func, bound, free)
            for arg in args:
                _free_in_expr(arg, bound, free)
        case EList(_, elements) | ETuple(_, elements):
            for element in elements:
                _free_in_expr(element, bound, free)
        case EIf(_, cond, then_expr, else_expr):
            for part in (cond, then_expr, else_expr):
                _free_in_expr(part, bound, free)
        case EListComp(_, expr, clauses):
            # A comprehension is its own scope: each `for` binds for the
            # clauses after it and for the element expression.
            comp_bound = set(bound)
            for clause in clauses:
                match clause:
                    case CompFor(_, pattern, sequence):
                        _free_in_expr(sequence, comp_bound, free)
                        comp_bound.update(pattern_captured_names(pattern))
                    case CompIf(_, condition):
                        _free_in_expr(condition, comp_bound, free)
            _free_in_expr(expr, comp_bound, free)
        case _ if hasattr(e, "left") and hasattr(e, "right"):
            _free_in_expr(e.left, bound, free)
            _free_in_expr(e.right, bound, free)
        case _:
            raise NotImplementedError(f"no free-name walk for expression {e!r}")


def _target_names(target):
    """The names an assignment target binds. AssignTarget -> [String]"""
    match target:
        case TargetName(_, name):
            return [name]
        case TargetTuple(_, elements):
            return [n for t in elements for n in _target_names(t)]
    return []


# --- what a body writes to from outside itself ---
#
# Python makes any assigned name local to the whole function, so a `def`
# that writes a `var` bound outside it has to say so: `global` for one
# declared at the module level, `nonlocal` for one in an enclosing
# function. Every other backend needs nothing here -- JavaScript closes
# over the binding, OCaml over the `ref` -- and C and Java refuse such a
# function outright, having no closures at all. See
# docs/target_python.md, "A `var` written from inside a function".


def _mutated_names(stmts):
    """The names a body writes with `:=` and does not itself declare
    with `var`. The walk stops at a nested `def`: that body declares its
    own. [Stmt] -> {String}"""
    written, declared = set(), set()
    _mutated_in_block(stmts, written, declared)
    return frozenset(written - declared)


def _mutated_in_block(stmts, written, declared):
    """Adds to written and declared over one statement list.
    [Stmt] -> {String} -> {String} -> ()"""
    for s in stmts:
        match s:
            case SVar(_, name, _):
                declared.add(name)
            case SMutate(_, name, _):
                written.add(name)
            case SIf(_, _, then_body, else_body):
                _mutated_in_block(then_body, written, declared)
                if else_body is not None:
                    _mutated_in_block(else_body, written, declared)
            case SLoop(_, _, _, _, _, body):
                _mutated_in_block(body, written, declared)
            case SMatch(_, _, cases):
                for arm in cases:
                    _mutated_in_block(arm.body, written, declared)
            case SLetStmt(_, _, inner) | SReturnStmt(_, inner):
                _mutated_in_block([inner], written, declared)


def _scope_declarations(names, scope, info):
    """The `global`/`nonlocal` lines a function body needs for the
    names it writes: `global` for a `var` declared at the module level,
    `nonlocal` for one in an enclosing function. A name no `var` in
    scope owns gets neither -- `src/analyses.py` has already refused a
    `:=` that names anything else. {String} -> Scope -> Info -> [PyStmt]"""
    outer, enclosing = [], []
    for name in sorted(names):
        depth = scope.mutables.get(name)
        if depth is None:
            continue
        (outer if depth == 0 else enclosing).append(_lookup(name, scope))
    lines = []
    if outer:
        lines.append(PyGlobal(info, outer))
    if enclosing:
        lines.append(PyNonlocal(info, enclosing))
    return lines


def _block_scope(scope):
    """The scope for a nested Pyking block: the same Python function
    scope -- which is exactly why bindings inside it may need renaming --
    but its own set of block-local names, and its bindings are dropped
    when the caller keeps using its own scope."""
    return Scope(
        scope.outer, scope.local, frozenset(), scope.shadowed, scope.captured,
        scope.loop_names, scope.depth, scope.mutables,
        # `used` is inherited rather than reset: a name this block hands
        # out must miss every one an enclosing block is still using. It
        # deliberately does not travel back out, so two *sibling* blocks
        # may reuse a name -- nothing reads the first one once it ends.
        scope.used,
    )


def _loop_scope(scope):
    """The scope for a loop body: a block scope that also tracks names
    bound afresh each turn (docs/target_python.md, "A def inside a
    loop"). Scope -> Scope"""
    block = _block_scope(scope)
    return replace(block, loop_names=frozenset(scope.loop_names or ()))


def _is_bound(name, scope):
    """Whether the program itself binds name, rather than it being a
    builtin passed through untouched. String -> Scope -> Bool"""
    return name in scope.local or name in scope.outer


def _is_builtin_range(e, scope):
    """Whether e is a call to the builtin range (not a shadowed name).
    Expr -> Scope -> Bool"""
    match e:
        case ECall(_, EVar(_, "range"), _):
            return not _is_bound("range", scope)
    return False


def _lazy_range(call, scope):
    """range(n) as Python's own lazy range, for a for header. ECall ->
    Scope -> PyCall"""
    return PyCall(
        call.info,
        PyVar(call.info, "range"),
        [translate_expr(a, scope) for a in call.args],
    )


def _lookup(name, scope):
    """The Python name a Pyking name reads as; a name bound nowhere is a
    builtin and passes through unchanged. String -> Scope -> String"""
    if name in scope.local:
        return scope.local[name]
    return scope.outer.get(name, name)


# Legal Pyking identifiers that are reserved words in Python (see
# docs/target_python.md, "Names that are keywords in Python").
RESERVED = frozenset(keyword.kwlist) | frozenset(keyword.softkwlist)


def _fresh_py_name(name, scope):
    """name2, or name3, ... -- the first not already used, as a Python
    name or a Pyking one, anywhere in scope. String -> Scope -> String"""
    taken = (
        set(scope.local) | set(scope.local.values())
        | set(scope.outer) | set(scope.outer.values())
        # `local` holds one Python name per Pyking name, so a shadow
        # replaces the name the block outside it is still using; `used`
        # is what keeps that one from being handed out twice.
        | set(scope.used)
    )
    n = 2
    while f"{name}{n}" in taken or f"{name}{n}" in RESERVED:
        n += 1
    return f"{name}{n}"


def _bind(name, scope, rebinding=False, loop_carried=True, mutable=False):
    """Binds a Pyking name, renaming only where it would otherwise land
    on a Python name still live in this function scope
    (docs/target_python.md, "Blocks are scopes; Python's are not").
    rebinding marks a value binding (= or var) that may reuse this
    block's own prior binding of name, unless a function already
    captured it; mutable marks a `var`, whose declaring depth is what
    later decides `global` from `nonlocal`.
    String -> Scope -> Bool -> Bool -> Bool -> (String, Scope)"""
    if name in scope.block and not (rebinding and name in scope.captured):
        return scope.local[name], scope
    py_name = name
    if (
        name in RESERVED
        or name in scope.local
        or name in scope.local.values()
        or name in scope.used
        or name in scope.shadowed
    ):
        py_name = _fresh_py_name(name, scope)
    return py_name, Scope(
        scope.outer,
        {**scope.local, name: py_name},
        scope.block | {name},
        scope.shadowed,
        scope.captured,
        # Inside a loop, this name is bound afresh on every turn --
        # unless it is a `var`, which is one location whatever the loop
        # does with it (see the `SVar` case in `translate_stmt`).
        None
        if scope.loop_names is None
        else (scope.loop_names | {name} if loop_carried else scope.loop_names - {name}),
        scope.depth,
        # A `var` records where it was declared; anything else of that
        # name is no longer a cell, so it drops out.
        {**scope.mutables, name: scope.depth} if mutable
        else {k: v for k, v in scope.mutables.items() if k != name},
        scope.used | {py_name},
    )


def _build_match_helper(pattern, helper_name):
    """Synthesizes a closure-free PyFunctionDef named helper_name that
    tests one value against pattern -- [(bound names...)] on a match,
    [] otherwise -- registers it in _pending_comp_helpers, and returns
    the captured names. Pattern -> String -> [String]"""
    info = pattern.info
    v = PyVar(info, "v")
    names = pattern_captured_names(pattern)
    success = PyReturn(
        info, PyList(info, [PyTuple(info, [PyVar(info, n) for n in names])])
    )
    helper_scope = Scope({}, {}, frozenset())
    py_pattern, _ = translate_pattern(pattern, helper_scope)
    match_stmt = PyMatch(info, v, [_match_case(info, py_pattern, [success])])
    failure = PyReturn(info, PyList(info, []))
    helper = PyFunctionDef(info, helper_name, ["v"], [match_stmt, failure])
    _pending_comp_helpers.append(helper)
    return names


def _format_helper_name(info):
    """The name of the print-formatting helper for a value that might
    hold a Bool at runtime and can't be proven either way from its
    Pyking source form (docs/target_python.md, "Booleans"), building
    and registering it the first time this is called. Info -> String"""
    global _format_helper_name_value, _format_helper_def
    if _format_helper_name_value is None:
        candidate = "__pyk_str"
        n = 0
        while candidate in _used_identifiers:
            n += 1
            candidate = f"__pyk_str{n}"
        _format_helper_name_value = candidate
        _format_helper_def = _build_format_helper(info, candidate)
    return _format_helper_name_value


def _escaped(info, char):
    """One character of a quoted string, escaped as Pyking escapes it:
    a chain of conditionals rather than a table, since the helper is
    built as Python's own AST. Info -> PyExpr -> PyExpr"""
    escapes = [("\\", "\\\\"), ("'", "\\'"), ("\n", "\\n"), ("\t", "\\t"), ("\r", "\\r")]
    result = char
    for literal, escape in reversed(escapes):
        result = PyIfExp(
            info,
            PyEq(info, char, PyString(info, literal)),
            PyString(info, escape),
            result,
        )
    return result


_DIVIDE_HELPER = "__pyk_div"


def _build_divide_helper(info):
    """Synthesizes Pyking's `/`: integer division truncating toward
    zero. Python's `//` rounds down instead, so the two differ whenever
    exactly one operand is negative -- `-7 // 2` is -4 where every
    Pyking backend gives -3. Division by zero is left to Python, as it
    is left to each host (docs/targets.md). Info -> PyFunctionDef"""
    def var(n):
        return PyVar(info, n)

    size = PyFloorDiv(
        info,
        PyCall(info, var("abs"), [var("a")]),
        PyCall(info, var("abs"), [var("b")]),
    )
    same_sign = PyEq(
        info,
        PyLessThan(info, var("a"), PyInt(info, 0)),
        PyLessThan(info, var("b"), PyInt(info, 0)),
    )
    return PyFunctionDef(info, _DIVIDE_HELPER, ["a", "b"], [
        PyAssign(info, PyTargetName(info, "q"), size),
        PyReturn(info, PyIfExp(info, same_sign, var("q"),
                               PyNeg(info, var("q")))),
    ])


def _build_format_helper(info, name):
    """Synthesizes the closure-free formatter Pyking's print needs: a
    Bool spelled `true`/`false` wherever it sits, including inside a
    list or a tuple, which is why this walks a value instead of merely
    testing it. Everything else is left to Python's own spelling, which
    already agrees (runtime_interface.py's rules).
    Info -> String -> PyFunctionDef"""
    def var(n):
        return PyVar(info, n)

    def text(s):
        return PyString(info, s)

    def call(fn, args):
        return PyCall(info, var(fn), args)

    def isa(value, type_name):
        return call("isinstance", [value, var(type_name)])

    def joined(*parts):
        result = parts[0]
        for part in parts[1:]:
            result = PyAdd(info, result, part)
        return result

    v, top, out, element = var("v"), var("top"), var("out"), var("e")
    inner = PyCall(info, var(name), [element, PyBool(info, False)])
    # out = out + (', ' if out != '' else '') + <the element>
    step = PyAssign(
        info,
        PyTargetName(info, "out"),
        joined(
            out,
            PyIfExp(
                info,
                PyEq(info, out, text("")),
                text(""),
                text(", "),
            ),
            inner,
        ),
    )
    body = [
        # A Bool is the whole point of the helper.
        PyIf(
            info,
            isa(v, "bool"),
            [PyReturn(info, PyIfExp(info, v, text("true"), text("false")))],
        ),
        # A string prints bare on its own and quoted inside something --
        # quoted the way Pyking quotes, which is not always the way
        # Python's own repr does (`"it's"` against `'it\\'s'`).
        PyIf(
            info,
            isa(v, "str"),
            [
                PyIf(info, top, [PyReturn(info, v)]),
                PyAssign(info, PyTargetName(info, "out"), text("'")),
                PyFor(info, "c", v, [
                    PyAssign(
                        info,
                        PyTargetName(info, "out"),
                        PyAdd(info, out, _escaped(info, PyVar(info, "c"))),
                    )
                ]),
                PyReturn(info, PyAdd(info, out, text("'"))),
            ],
        ),
        PyIf(
            info,
            isa(v, "list"),
            [
                PyAssign(info, PyTargetName(info, "out"), text("")),
                PyFor(info, "e", v, [step]),
                PyReturn(info, joined(text("["), out, text("]"))),
            ],
        ),
        PyIf(
            info,
            isa(v, "tuple"),
            [
                PyAssign(info, PyTargetName(info, "out"), text("")),
                PyFor(info, "e", v, [step]),
                # The singleton keeps the comma that tells it from a
                # parenthesized value, exactly as Pyking writes it.
                PyIf(
                    info,
                    PyEq(info, call("len", [v]), PyInt(info, 1)),
                    [PyReturn(info, joined(text("("), out, text(",)")))],
                ),
                PyReturn(info, joined(text("("), out, text(")"))),
            ],
        ),
        PyReturn(info, call("str", [v])),
    ]
    return PyFunctionDef(info, name, ["v", "top"], body)


def _translate_comp_for(clause, scope):
    """Expands one Pyking CompFor into one or two Python comprehension
    clauses -- one for an irrefutable pattern, two (raw items, then a
    match helper) for a refutable one -- with the scope its pattern
    extends. CompFor -> Scope -> ([PyCompClause], Scope)"""
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


# Pyking has no type checker in an ordinary compile (see PYKING.md), so
# whether a given expression holds a Bool is, in general, not knowable
# at compile time -- but for plenty of expressions it plainly is,
# straight from the *type* the checker gave it -- `tmap`, keyed by
# symbol, which `translate_program` is handed. A `Bool` is spelled
# inline, anything with no `Bool` anywhere inside it is printed as
# Python already prints it, and only a value that really can hold one
# (a `[Bool]`, a `(Int, Bool)`, a type nothing has pinned down) needs
# the runtime walk. That is what keeps an ordinary program's output
# free of a prelude it has no use for.


def _bool_kind(type_):
    """'bool' for a Bool, 'not-bool' for a type with no Bool anywhere
    inside it, 'unknown' otherwise. Type? -> String"""
    match type_:
        case TBool():
            return "bool"
        case TInt() | TString() | TVar(_, _, _, False):
            # A variable nothing constrained is the element type of a
            # list with no elements, so no Bool is ever formatted
            # through it. A *rigid* one is a type the caller chose and
            # could be anything, which falls through to "unknown".
            return "not-bool"
        case TList(_, element, _):
            return "not-bool" if _bool_kind(element) == "not-bool" else "unknown"
        case TTuple(_, elements, _):
            # `()` is the zero-element tuple, and holds nothing at all.
            kinds = {_bool_kind(e) for e in elements}
            return "not-bool" if kinds <= {"not-bool"} else "unknown"
    return "unknown"


def _nests_a_string(type_, inside=False):
    """Whether a String sits anywhere *inside* a list or tuple of this
    type. Such a string is quoted when it is printed, and Python's own
    `repr` picks its quotes for itself -- writing `["it's"]` where every
    other target writes `['it\\'s']` -- so the helper has to spell it
    instead. A String on its own is not one of these: it prints bare,
    which Python already agrees with. Type? -> Bool -> Bool"""
    match type_:
        case TString():
            return inside
        case TList(_, element, _):
            return _nests_a_string(element, True)
        case TTuple(_, elements, _):
            return any(_nests_a_string(e, True) for e in elements)
    return False


def _wrap_print_argument(pyking_expr, translated, info):
    """One print argument, formatted for Pyking's true/false spelling
    and its own string quoting: inline where the checker's type settles
    it, a call through the generated helper otherwise
    (docs/target_python.md, "Booleans").
    Expr -> PyExpr -> Info -> PyExpr"""
    type_ = _tmap.get(pyking_expr.sym)
    kind = _bool_kind(type_)
    if kind == "bool":
        return PyIfExp(info, translated, PyString(info, "true"), PyString(info, "false"))
    if kind == "not-bool" and not _nests_a_string(type_):
        return translated
    helper = PyVar(info, _format_helper_name(info))
    return PyCall(info, helper, [translated, PyBool(info, True)])


def translate_expr(e, scope):
    """Translates one expression. Expr -> Scope -> PyExpr"""
    match e:
        case EInt(info, v):
            return PyInt(info, v)
        case EString(info, s):
            return PyString(info, s)
        case EBool(info, v):
            return PyBool(info, v)
        case EVar(info, name):
            return PyVar(info, _lookup(name, scope))
        case EQualified(info, module_name, name):
            # `m.f` is Python's own attribute access on the imported
            # module, which is what an `import m` above binds.
            return PyAttr(info, PyVar(info, _lookup(module_name, scope)), name)
        case EAdd(info, l, r):
            return PyAdd(info, translate_expr(l, scope), translate_expr(r, scope))
        case EConcat(info, l, r):
            # Python's `+` concatenates strings and lists as well as
            # adding, so both Pyking operators land on the same node.
            return PyAdd(info, translate_expr(l, scope), translate_expr(r, scope))
        case ESub(info, l, r):
            return PySub(info, translate_expr(l, scope), translate_expr(r, scope))
        case EMul(info, l, r):
            return PyMul(info, translate_expr(l, scope), translate_expr(r, scope))
        case EDiv(info, l, r):
            # Pyking's `/` truncates toward zero; Python's `//` rounds
            # down, so they part company on a negative operand. A helper
            # in the prelude does it, rather than the same conditional
            # inlined at every division.
            global _divide_helper_def
            if _divide_helper_def is None:
                _divide_helper_def = _build_divide_helper(info)
            return PyCall(
                info, PyVar(info, _DIVIDE_HELPER),
                [translate_expr(l, scope), translate_expr(r, scope)],
            )
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
            # Python's own `print` answers None, and Pyking's answers
            # unit -- which this backend spells `()`, as the `return ()`
            # on a unit-returning `def` does. In *value* position the two
            # have to be made to agree, so the call is followed by the
            # unit it is worth; a print written as a statement keeps the
            # bare call (see `_runtime_call_stmt`).
            return PyIndex(
                info,
                PyTuple(info, [_runtime_call(info, name, args, scope),
                               PyTuple(info, [])]),
                PyInt(info, 1),
            )
        case ECall(info, EVar(_, "str"), [argument]) if not _is_bound("str", scope):
            # str follows print's own Bool formatting rule.
            return PyCall(
                info,
                PyVar(info, "str"),
                [_wrap_print_argument(argument, translate_expr(argument, scope), info)],
            )
        case ECall(info, EVar(_, "range"), args) if not _is_bound("range", scope):
            # A range used as a value is materialised (docs/target_python.md,
            # "range"); the for header keeps Python's lazy form.
            return PyCall(
                info,
                PyVar(info, "list"),
                [
                    PyCall(
                        info,
                        PyVar(info, "range"),
                        [translate_expr(a, scope) for a in args],
                    )
                ],
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
    extend. Pattern -> Scope -> (PyPattern, Scope)"""
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
        case PText(info, prefix, name, suffix, _):
            # Python's `match` cannot split a string, so the arm captures
            # the whole and tests it: `case str() as t if t.startswith(...)`,
            # with the middle sliced out at the top of the body.
            held, scope = _bind("__text", scope)
            tests = [PyCall(
                info, PyAttr(info, PyVar(info, held), "startswith"),
                [PyString(info, prefix)],
            )] if prefix else []
            if suffix:
                tests.append(PyCall(
                    info, PyAttr(info, PyVar(info, held), "endswith"),
                    [PyString(info, suffix)],
                ))
            if prefix and suffix:
                # A prefix and a suffix that overlap would each match on
                # their own; the length is what keeps them apart.
                tests.append(PyGreatThanEq(
                    info,
                    PyCall(info, PyVar(info, "len"), [PyVar(info, held)]),
                    PyInt(info, len(prefix) + len(suffix)),
                ))
            guard = None
            for test in tests:
                guard = test if guard is None else PyAnd(info, guard, test)
            bindings = []
            if name is not None:
                py_name, scope = _bind(name, scope)
                bindings = [PyAssign(
                    info, PyTargetName(info, py_name),
                    _slice_middle(info, held, prefix, suffix),
                )]
            return PyPGuarded(info, held, guard, tuple(bindings)), scope
        case _:
            raise NotImplementedError(f"no Python translation for pattern {p!r}")


def _slice_middle(info, held, prefix, suffix):
    """`held[len(prefix):len(held) - len(suffix)]`, with either end left
    off where it is empty. Info -> String -> String -> String -> PyExpr"""
    start = PyInt(info, len(prefix)) if prefix else None
    stop = None
    if suffix:
        stop = PySub(
            info,
            PyCall(info, PyVar(info, "len"), [PyVar(info, held)]),
            PyInt(info, len(suffix)),
        )
    return PySlice(info, PyVar(info, held), start, stop)


def translate_target(t, scope, rebinding=False):
    """Translates an assignment target, returning it with the scope its
    names extend. AssignTarget -> Scope -> Bool -> (PyTarget, Scope)"""
    match t:
        case TargetName(info, name):
            py_name, scope = _bind(name, scope, rebinding)
            return PyTargetName(info, py_name), scope
        case TargetTuple(info, elements):
            py_elements = []
            for element in elements:
                py_element, scope = translate_target(element, scope, rebinding)
                py_elements.append(py_element)
            return PyTargetTuple(info, py_elements), scope
        case _:
            raise NotImplementedError(f"no Python translation for assignment target {t!r}")


def _match_case(info, py_pattern, body):
    """One arm, with every guarded pattern's parts put where they
    belong: the tests joined onto the `case`, and the bindings they need
    at the top of the body. A guarded pattern may sit anywhere inside
    the arm's pattern -- `case ("a" ++ x, [n] ++ _)` has one nested in a
    tuple -- and Python's guard covers the whole arm, which is what
    "every part matched" means.
    Info -> PyPattern -> [PyStmt] -> PyMatchCase"""
    guard, bindings = _guarded_parts(py_pattern)
    return PyMatchCase(info, py_pattern, bindings + body, guard)


def _guarded_parts(py_pattern):
    """Every guard and binding a pattern carries, in source order: the
    guards joined with `and`, the bindings concatenated.
    PyPattern -> (PyExpr?, [PyStmt])"""
    guard, bindings = None, []
    for found in _guarded_in(py_pattern):
        if found.guard is not None:
            guard = found.guard if guard is None else PyAnd(
                found.info, guard, found.guard
            )
        bindings += list(found.bindings)
    return guard, bindings


def _guarded_in(py_pattern):
    """The PyPGuarded nodes inside a pattern, outermost first.
    PyPattern -> [PyPGuarded]"""
    match py_pattern:
        case PyPGuarded():
            return [py_pattern]
        case PyPTuple(_, elements):
            return [g for e in elements for g in _guarded_in(e)]
        case PyPList(_, prefix, _, suffix):
            return [g for e in list(prefix) + list(suffix or [])
                    for g in _guarded_in(e)]
    return []


def translate_case(c, scope):
    """One case arm outside a binding. MatchCase -> Scope ->
    PyMatchCase"""
    py_pattern, arm_scope = translate_pattern(c.pattern, _block_scope(scope))
    body, _ = _translate_stmts(c.body, arm_scope)
    return _match_case(c.info, py_pattern, body)


def _runtime_call(info, name, args, scope):
    """One runtime_interface call (print), as the bare Python call.
    A call's arguments are formatted, not merely translated -- see
    _wrap_print_argument.
    Info -> String -> [Expr] -> Scope -> PyCall"""
    return PyCall(
        info,
        PyVar(info, name),
        [_wrap_print_argument(a, translate_expr(a, scope), info) for a in args],
    )


def _runtime_call_stmt(expr, scope):
    """A runtime_interface call written as a statement: the bare call,
    with none of the unit `translate_expr` adds for value position.
    Expr -> Scope -> PyExprStmt"""
    match expr:
        case ECall(info, EVar(_, name), args):
            return PyExprStmt(info, _runtime_call(info, name, args, scope))
    raise NotImplementedError(f"{expr!r} is not a runtime call")


def _yields_unit(expr):
    """Whether expr is a runtime_interface call (print), which needs no
    return emitted in tail position. Expr -> Bool"""
    match expr:
        case ECall(_, EVar(_, name), _):
            return runtime_interface.lookup(name) is not None
        case _:
            return False


def _translate_tail_block(stmts, scope):
    """Translates a statement list whose last statement is in tail
    position (PYKING.md, "Tail position"; docs/target_python.md, "Tail
    position"). [Stmt] -> Scope -> [PyStmt]"""
    if not stmts:
        return []
    # Over the whole block, including the last statement: a `def` in tail
    # position is still visible to everything above it.
    scope = _declare_functions(stmts, scope)
    body, tail_scope = _translate_stmts(stmts[:-1], scope)
    return body + _translate_tail_stmt(stmts[-1], tail_scope)


def _translate_tail_stmt(s, scope):
    """The last statement of a body in tail position, as a list of Python
    statements. Stmt -> Scope -> [PyStmt]"""
    match s:
        case SExprStmt(_, expr) if _yields_unit(expr):
            translated, _ = translate_stmt(s, scope)
            return [translated]
        case SExprStmt(info, expr):
            return [PyReturn(info, translate_expr(expr, scope))]
        case SIf(_, _, _, None):
            # An `if` with no `else` supplies unit whatever its one
            # branch ends in (PYKING.md, "Type checking"): a path runs no
            # branch at all, so there is no value the statement can be
            # counted on for. Translated as an ordinary statement, so the
            # function falls out of its end -- Python's own implicit
            # `None`, i.e. unit.
            translated, _ = translate_stmt(s, scope)
            return [translated]
        case SIf(info, cond, then_body, else_body):
            return [
                PyIf(
                    info,
                    translate_expr(cond, scope),
                    _translate_tail_block(then_body, _block_scope(scope)),
                    _translate_tail_block(else_body, _block_scope(scope)),
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
        case SLoop(info):
            # A function ending in a loop returns what the loop
            # produced: the accumulator it stopped with.
            py_stmts, value, _ = _translate_loop(s, scope)
            return py_stmts + [PyReturn(info, value)]
        case _:
            translated, _ = translate_stmt(s, scope)
            return _as_stmts(translated)


def _falls_through(py_body):
    """Whether control can reach the end of py_body without returning --
    if so, an explicit `return ()` is needed, since unit is the empty
    tuple and Python's implicit None is not it. [PyStmt] -> Bool"""
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
    """One case arm of a match in tail position. MatchCase -> Scope ->
    PyMatchCase"""
    py_pattern, arm_scope = translate_pattern(c.pattern, _block_scope(scope))
    return _match_case(
        c.info, py_pattern, _translate_tail_block(c.body, arm_scope)
    )


def _translate_value_stmt(s, py_target, scope):
    """Translates a value-form if/match (docs/target_python.md,
    "Value-form if/match"): the same PyIf/PyMatch the statement form
    produces, with each branch's tail assigned to py_target. Stmt ->
    PyTarget -> Scope -> PyStmt"""
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
    """Translates one branch of a value-form if/match. [Stmt] ->
    PyTarget -> Scope -> [PyStmt]"""
    branch_scope = _declare_functions(stmts, _block_scope(scope))
    body, branch_scope = _translate_stmts(stmts[:-1], branch_scope)
    match stmts[-1]:
        case SExprStmt(info, expr):
            body.append(PyAssign(info, py_target, translate_expr(expr, branch_scope)))
        case SIf() | SMatch() as nested:
            body.append(_translate_value_stmt(nested, py_target, branch_scope))
        case last:
            raise NotImplementedError(f"statement {last!r} yields no value")
    return body


def _translate_loop(s, scope):
    """Translates a loop into Python's own `while True`/`for` over a
    mutable accumulator variable (docs/target_python.md, "loop"): the
    initializer becomes the variable's first value and every tail of the
    body assigns the next one, so the variable holds what the loop is
    worth however it stops -- a `break` is Python's own, and leaves this
    turn's value where it is. Returns the statements, the expression
    holding the loop's value afterwards, and the scope -- which is the
    caller's, since the accumulator belongs to the body.
    SLoop -> Scope -> ([PyStmt], PyExpr, Scope)"""
    info = s.info
    setup = []
    body_scope = _loop_scope(scope)
    py_target = None
    value = PyTuple(info, [])
    if s.target is not None:
        # The initializer is translated before the accumulator binds, so
        # `loop x = x + 1:` reads the enclosing `x`, exactly as an `=`
        # binding does.
        py_init = translate_expr(s.init, scope)
        py_target, body_scope = translate_target(s.target, body_scope, rebinding=True)
        setup.append(PyAssign(info, py_target, py_init))
        value = _target_as_expr(py_target)
    # The iteration clause decides which Python loop this is. A `for`
    # binds its element in the body's scope, where Python's own `for`
    # target lives too, so it renames like anything else when it shadows.
    py_name = None
    py_sequence = None
    match s.iterate:
        case ForIn(_, name, sequence, _):
            # `for i in range(n)` iterates lazily, as Python's own does:
            # only a range used as a *value* is materialised into the
            # list its type says it is (see `translate_expr`).
            py_sequence = (
                _lazy_range(sequence, scope)
                if _is_builtin_range(sequence, scope)
                else translate_expr(sequence, scope)
            )
            py_name, body_scope = _bind(name, body_scope)

    py_body = _translate_loop_block(s.body, py_target, body_scope)

    match s.iterate:
        case ForIn():
            loop = PyFor(info, py_name, py_sequence, py_body, None)
        case WhileTest(_, condition, _):
            loop = PyWhile(info, translate_expr(condition, body_scope),
                           py_body, None)
        case _:
            loop = PyWhile(info, PyBool(info, True), py_body, None)
    return setup + [loop], value, scope


def _target_as_expr(target):
    """A target read back as an expression: what a loop's accumulator
    holds once the loop has stopped. PyTarget -> PyExpr"""
    match target:
        case PyTargetName(info, name):
            return PyVar(info, name)
        case PyTargetTuple(info, elements):
            return PyTuple(info, [_target_as_expr(e) for e in elements])


def _translate_loop_block(stmts, py_target, scope):
    """Translates a loop body: whatever a path ends in is the next
    turn's accumulator, so every tail becomes an assignment to
    py_target -- except a `break`/`continue`, which has already said
    what happens next. py_target is None for a loop carrying nothing,
    where the body's value is simply discarded.
    [Stmt] -> PyTarget? -> Scope -> [PyStmt]"""
    scope = _declare_functions(stmts, scope)
    if not stmts:
        return []
    body, scope = _translate_stmts(stmts[:-1], scope)
    return body + _translate_loop_tail(stmts[-1], py_target, scope)


def _translate_loop_tail(s, py_target, scope):
    """The last statement of a loop body, or of one branch of one.
    Stmt -> PyTarget? -> Scope -> [PyStmt]"""
    if py_target is None:
        return _as_stmts(translate_stmt(s, scope)[0])
    match s:
        case SExprStmt(info, expr):
            return [PyAssign(info, py_target, translate_expr(expr, scope))]
        case SIf(info, cond, then_body, else_body):
            then_scope = _block_scope(scope)
            py_then = _translate_loop_block(then_body, py_target, then_scope)
            if else_body is None:
                # A path that runs no branch produces nothing, and
                # nothing is unit -- what PYKING.md's tail-position
                # table says of every statement that yields no value,
                # and what src/interpreter.py does with one.
                py_else = [PyAssign(info, py_target, PyTuple(info, []))]
            else:
                py_else = _translate_loop_block(
                    else_body, py_target, _block_scope(scope)
                )
            return [PyIf(info, translate_expr(cond, scope), py_then, py_else)]
        case SMatch(info, subject, cases):
            return [PyMatch(
                info,
                translate_expr(subject, scope),
                [_translate_loop_case(c, py_target, scope) for c in cases],
            )]
        case SBreak() | SContinue() | SReturn() | SReturnStmt():
            # Each of these says by itself what happens next: two leave
            # the loop, one leaves the whole function.
            return _as_stmts(translate_stmt(s, scope)[0])
        case _:
            # Anything else supplies unit, so that is the accumulator
            # the next turn gets.
            return _as_stmts(translate_stmt(s, scope)[0]) + [
                PyAssign(s.info, py_target, PyTuple(s.info, []))
            ]


def _translate_loop_case(c, py_target, scope):
    """One case arm of a match at the tail of a loop body.
    MatchCase -> PyTarget -> Scope -> PyMatchCase"""
    py_pattern, arm_scope = translate_pattern(c.pattern, _block_scope(scope))
    return _match_case(
        c.info, py_pattern, _translate_loop_block(c.body, py_target, arm_scope)
    )


def _as_stmts(translated):
    """One translation's statements: a statement translator may answer
    with several (a loop is a setup plus a `while`).
    (PyStmt | [PyStmt]) -> [PyStmt]"""
    return list(translated) if isinstance(translated, list) else [translated]


def _translate_value_case(c, py_target, scope):
    """One case arm of a value-form match. MatchCase -> PyTarget -> Scope
    -> PyMatchCase"""
    py_pattern, arm_scope = translate_pattern(c.pattern, _block_scope(scope))
    body = _translate_value_block(c.body, py_target, arm_scope)
    return _match_case(c.info, py_pattern, body)


def translate_stmt(s, scope):
    """Translates one statement, returning it with the scope it leaves
    behind. A loop answers with several statements, so the result may
    be a list (see `_as_stmts`).
    Stmt -> Scope -> (PyStmt | [PyStmt], Scope)"""
    match s:
        case SLet(info, target, expr):
            # The right-hand side is translated *before* the target binds,
            # so `x = x + 1` reads the outer `x` -- if that binding is a
            # shadowing one, the read still resolves to the old name.
            py_expr = translate_expr(expr, scope)
            py_target, scope = translate_target(target, scope, rebinding=True)
            return PyAssign(info, py_target, py_expr), scope

        case SLetStmt(info, target, SLoop() as loop):
            # `x = loop ...` -- the loop's value is the accumulator it
            # stopped with, so the binding is one assignment after it.
            py_target, scope = translate_target(target, scope, rebinding=True)
            py_stmts, value, scope = _translate_loop(loop, scope)
            return py_stmts + [PyAssign(info, py_target, value)], scope

        case SLetStmt(_, target, stmt):
            # The target binds in *this* scope (the branches are blocks of
            # their own) and is bound first, so a branch that shadows a
            # name cannot be handed the Python name the target is using.
            py_target, scope = translate_target(target, scope, rebinding=True)
            return _translate_value_stmt(stmt, py_target, scope), scope

        case SImport(info, module_name, local, selected, fields):
            # Python's own import is Pyking's, name for name: a module
            # is a file, and a public name is a name the module binds.
            # There is no privacy to express -- Python has none -- so the
            # `public` marks leave no trace in the output. The names were
            # bound by `_declare_functions`; where one had to be renamed,
            # Python's own `as` says so.
            if selected:
                return PyFromImport(info, module_name, [
                    (exported, _lookup(local_name, scope))
                    for exported, local_name in fields
                ]), scope
            py_name = _lookup(local, scope)
            alias = None if py_name == module_name else py_name
            return PyImport(info, module_name, alias), scope

        case SVar(info, name, expr):
            py_expr = translate_expr(expr, scope)
            # A `var` is a mutable location: `:=` updates the one
            # binding, and a function reading it is meant to see that
            # (PYKING.md, "Names and scoping"). So it is *not* carried
            # per turn of a loop -- a copy handed to a factory would
            # freeze at the value it had when the turn's functions were
            # built, which is the opposite of what `var` means.
            py_name, scope = _bind(
                name, scope, rebinding=True, loop_carried=False, mutable=True
            )
            return PyAssign(info, PyTargetName(info, py_name), py_expr), scope

        case SMutate(info, name, expr):
            # An update, not a binding: it reuses the variable's name,
            # whatever renaming that variable got when it was declared.
            py_expr = translate_expr(expr, scope)
            py_name = _lookup(name, scope)
            return PyAssign(info, PyTargetName(info, py_name), py_expr), scope

        case SReturn(info, expr):
            return PyReturn(info, translate_expr(expr, scope)), scope

        case SExprStmt(_, expr) if _yields_unit(expr):
            # Nothing reads what a statement is worth, so `print(x)` is
            # written as itself rather than as the value form.
            return _runtime_call_stmt(expr, scope), scope

        case SExprStmt(info, expr):
            return PyExprStmt(info, translate_expr(expr, scope)), scope

        case SLoop():
            py_stmts, _, scope = _translate_loop(s, scope)
            return py_stmts, scope

        case SBreak(info):
            # Python's own: the accumulator variable is left holding
            # what this turn started with, which is what the loop is
            # worth.
            return PyBreak(info), scope

        case SContinue(info):
            return PyContinue(info), scope

        case SIf(info, cond, then_body, else_body):
            py_then, _ = _translate_stmts(then_body, _block_scope(scope))
            py_else = None
            if else_body is not None:
                py_else, _ = _translate_stmts(else_body, _block_scope(scope))
            return PyIf(info, translate_expr(cond, scope), py_then, py_else), scope

        case SFunctionDef(info, name, params, body, _return_type):
            py_name, scope = _bind(name, scope)
            body_stmts = body
            body_bound = {name} | {p.name for p in params}
            body_scope = _function_scope(
                scope,
                _free_names(body_stmts, body_bound),
                _captured_names(body_stmts, body_bound),
            )
            param_names = []
            for param in params:
                py_param, body_scope = _bind(param.name, body_scope)
                param_names.append(py_param)
            # Before anything in the body is translated, since the
            # declarations name the variables as they are known *outside*
            # it -- which is what `body_scope` still holds here.
            declarations = _scope_declarations(
                _mutated_names(body), body_scope, info
            )
            py_body = _translate_tail_block(body, body_scope)
            if _falls_through(py_body):
                py_body.append(PyReturn(info, PyTuple(info, [])))
            return (
                PyFunctionDef(info, py_name, param_names, declarations + py_body),
                scope,
            )

        case SReturnStmt(_, stmt):
            # `return if c: ...` -- the same push-down as a tail-position
            # if/match, written explicitly. A loop answers with several
            # statements (the accumulator, the loop, the return).
            return _translate_tail_stmt(stmt, scope), scope

        case SMatch(info, subject, cases):
            py_subject = translate_expr(subject, scope)
            return PyMatch(info, py_subject, [translate_case(c, scope) for c in cases]), scope

        case _:
            raise NotImplementedError(f"no Python translation for statement {s!r}")


def _declare_functions(stmts, scope):
    """Binds every def in this block, and everything an import brings
    into it, before any of it is translated (docs/target_python.md,
    "Functions used before they are written"). Both are visible
    throughout the block they are written in, so both are bound ahead of
    it. [Stmt] -> Scope -> Scope"""
    for s in stmts:
        if isinstance(s, SFunctionDef):
            _, scope = _bind(s.name, scope)
        elif isinstance(s, SImport):
            for name in _import_names(s):
                _, scope = _bind(name, scope)
    return scope


def _import_names(statement):
    """The names one import binds where it is written: each selected
    name under the name it is known by here, or the module's own local
    name. SImport -> [String]"""
    if statement.selected:
        return [local for _, local in statement.fields or ()]
    return [statement.name]


def _loop_captures(s, loop_names):
    """The loop-carried names a def reads, or an empty set for anything
    else or outside a loop. Stmt -> {String}? -> {String}"""
    if loop_names is None or not isinstance(s, SFunctionDef):
        return frozenset()
    return frozenset(_def_body_names(s) & loop_names)


def _loop_names_before(stmts, index, scope):
    """Everything a turn of the loop rebinds, as seen positionally from
    index in this block: what the loop already carries, plus what the
    block binds above that point (var excluded). [Stmt] -> Int -> Scope
    -> {String}?"""
    if scope.loop_names is None:
        return None
    names = set(scope.loop_names)
    for statement in stmts[:index]:
        if not isinstance(statement, SVar):
            names.update(_stmt_bound_names(statement))
    return frozenset(names)


def _def_body_names(s):
    """The names a def's body reads freely (own name and parameters
    excluded). SFunctionDef -> {String}"""
    bound = {s.name} | {p.name for p in s.params}
    return _free_names(s.body, bound)


def _turn_groups(stmts, scope):
    """Which defs of this loop body have to be built together, one turn
    at a time, keyed by the index each group starts at: the connected
    components of "names another def of this block" that capture
    something the loop rebinds (docs/gap.md). [Stmt] -> Scope -> {Int:
    ([Int], [Int], {String})}"""
    if scope.loop_names is None:
        return {}
    defs = {i: s for i, s in enumerate(stmts) if isinstance(s, SFunctionDef)}
    if not defs:
        return {}
    index_of = {s.name: i for i, s in defs.items()}

    # Union-find over "def i names def j", in either direction.
    parent = {i: i for i in defs}

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, s in defs.items():
        for name in _def_body_names(s) & set(index_of):
            a, b = root(i), root(index_of[name])
            if a != b:
                parent[a] = b

    components = {}
    for i in defs:
        components.setdefault(root(i), []).append(i)

    # Each `def` is asked what *it* can see, at its own place in the
    # block -- see `_loop_names_before`.
    captured_by = {
        i: _loop_captures(defs[i], _loop_names_before(stmts, i, scope))
        for i in defs
    }

    groups = {}
    for members in components.values():
        members.sort()
        captures = set().union(*(captured_by[i] for i in members))
        captures -= {defs[i].name for i in members}
        if not captures:
            # Nothing the loop rebinds reaches these, so Python's own
            # scoping is already right and they translate as they are.
            continue
        absorbed = _absorbed(stmts, defs, members, captures)
        groups[members[0]] = (
            members,
            absorbed,
            captures - {n for i in absorbed for n in _stmt_bound_names(stmts[i])},
        )
    return groups


def _absorbed(stmts, defs, members, captures):
    """The statement indices between a group's defs that have to travel
    with them into the factory (docs/gap.md). [Stmt] -> {Int:
    SFunctionDef} -> [Int] -> {String} -> [Int]"""
    needed = [
        j
        for j in range(members[0], members[-1])
        if j not in defs
        and isinstance(stmts[j], (SLet, SLetStmt))
        and captures & set(_stmt_bound_names(stmts[j]))
    ]
    if not needed:
        return []
    window = [j for j in range(members[0] + 1, needed[-1] + 1) if j not in defs]
    if all(_movable(stmts[j]) for j in window):
        return window
    return needed


def _movable(s, in_loop=False):
    """Whether a statement may be lifted into a factory: no return
    (would leave the factory, not the enclosing function), no := (would
    write the factory's own local), and no break/continue for a loop
    the factory is not inside -- in_loop says a loop moving with it is.
    A nested def's own returns don't count against it.
    Stmt -> Bool -> Bool"""
    match s:
        case SReturn() | SReturnStmt() | SMutate():
            return False
        case SBreak() | SContinue():
            return in_loop
        case SLetStmt(_, _, stmt):
            return _movable(stmt, in_loop)
        case SIf(_, _, then_body, else_body):
            return all(_movable(st, in_loop) for st in then_body) and (
                else_body is None
                or all(_movable(st, in_loop) for st in else_body)
            )
        case SLoop(_, _, _, _, _, body):
            # A loop takes its own break/continue with it, wherever it
            # is moved to.
            return all(_movable(st, True) for st in body)
        case SMatch(_, _, cases):
            return all(
                _movable(st, in_loop)
                for c in cases if c.body is not None for st in c.body
            )
        case _:
            return True


def _stmt_bound_names(s):
    """The names a statement binds in the block it is written in. Stmt ->
    [String]"""
    match s:
        case SLet(_, target, _) | SLetStmt(_, target, _):
            return _target_names(target)
        case SVar(_, name, _):
            return [name]
        case SFunctionDef(_, name, _, _, _):
            return [name]
        case _:
            return []


def _translate_turn_group(members, absorbed, captures, stmts, scope):
    """One group of defs inside a loop, built by a factory taking the
    captured names as parameters (docs/target_python.md, "A def inside a
    loop"; docs/gap.md). [Int] -> [Int] -> {String} -> [Stmt] -> Scope ->
    ([PyStmt], Scope)"""
    order = sorted(members + absorbed)
    py_captures = [_lookup(name, scope) for name in sorted(captures)]

    inner_scope = scope
    inner = []
    bound = []
    for i in order:
        py_stmt, inner_scope = translate_stmt(stmts[i], inner_scope)
        inner.extend(_as_stmts(py_stmt))
        for name in _stmt_bound_names(stmts[i]):
            bound.append(_lookup(name, inner_scope))

    info = stmts[order[0]].info
    factory = _fresh_turn_name()
    returned = (
        PyVar(info, bound[0]) if len(bound) == 1
        else PyTuple(info, [PyVar(info, n) for n in bound])
    )
    target = (
        PyTargetName(info, bound[0]) if len(bound) == 1
        else PyTargetTuple(info, [PyTargetName(info, n) for n in bound])
    )
    return [
        PyFunctionDef(info, factory, py_captures, inner + [PyReturn(info, returned)]),
        PyAssign(
            info,
            target,
            PyCall(info, PyVar(info, factory), [PyVar(info, p) for p in py_captures]),
        ),
    ], inner_scope


def _translate_stmts(stmts, scope):
    """Translates a statement sequence, threading the scope through it.
    A caller entering a block passes a _block_scope and discards the
    returned scope. [Stmt] -> Scope -> ([PyStmt], Scope)"""
    scope = _declare_functions(stmts, scope)
    groups = _turn_groups(stmts, scope)
    # Everything a group takes with it is emitted where the group starts,
    # so those statements are passed over when the walk reaches them.
    covered = {
        i
        for start, (members, absorbed, _) in groups.items()
        for i in members + absorbed
        if i != start
    }
    translated = []
    for index, statement in enumerate(stmts):
        if index in covered:
            continue
        if index in groups:
            members, absorbed, captures = groups[index]
            py_stmts, scope = _translate_turn_group(
                members, absorbed, captures, stmts, scope
            )
            translated.extend(py_stmts)
            continue
        py_stmt, scope = translate_stmt(statement, scope)
        translated.extend(_as_stmts(py_stmt))
    return translated, scope


def translate_program(stmts, tmap):
    """Translates a full program: comprehension and Bool-format helper
    state is reset first, and every helper synthesized along the way is
    prepended. `tmap` is the checker's symbol -> type table, which is
    what decides how a `print` argument is formatted.
    [Stmt] -> {Int: Type} -> PyProgram"""
    global _comp_counter, _pending_comp_helpers, _used_identifiers, _turn_counter
    global _format_helper_name_value, _format_helper_def
    global _divide_helper_def
    global _tmap
    _tmap = tmap
    _comp_counter = 0
    _turn_counter = 0
    _pending_comp_helpers = []
    _format_helper_name_value = None
    _format_helper_def = None
    _divide_helper_def = None
    _used_identifiers = _collect_identifiers(stmts) | _import_identifiers(stmts)
    translated, _ = _translate_stmts(
        stmts,
        Scope({}, {}, frozenset(), frozenset(), _captured_names(stmts, set())),
    )
    helpers = _pending_comp_helpers
    _pending_comp_helpers = []
    prelude = [d for d in (_divide_helper_def, _format_helper_def)
               if d is not None]
    return PyProgram(prelude, helpers + translated)


# --- pretty printer: Python target AST -> Python source text ---

# Two levels beside the arithmetic ones the printers below use (1 for a
# comparison, up to 5 for an atom): `and` is looser than all of them,
# and a call, an attribute or a slice binds tighter, so their target is
# asked for an atom.
_AND_PREC = 0
_CALL_PREC = 5


def _wrap(prec, min_prec, s):
    """s, parenthesized if prec is below min_prec. Int -> Int -> String
    -> String"""
    return f"({s})" if prec < min_prec else s


_PRINT_ESCAPES = {
    "\\": "\\\\",
    "'": "\\'",
    "\n": "\\n",
    "\t": "\\t",
    "\r": "\\r",
}


def _quote_string(s):
    """s as a single-quoted Python string literal, escapes applied.
    String -> String"""
    body = "".join(_PRINT_ESCAPES.get(ch, ch) for ch in s)
    return f"'{body}'"


def pprint_py_expr(e, min_prec=0):
    """e as Python source text, parenthesized if its precedence is below
    min_prec. PyExpr -> Int -> String"""
    match e:
        case PyInt(_, v):
            return str(v)
        case PyString(_, s):
            return _quote_string(s)
        case PyBool(_, v):
            return "True" if v else "False"
        case PyVar(_, name):
            return name
        case PyAttr(_, target, name):
            return f"{pprint_py_expr(target, _CALL_PREC)}.{name}"
        case PySlice(_, target, start, stop):
            first = "" if start is None else pprint_py_expr(start)
            last = "" if stop is None else pprint_py_expr(stop)
            return f"{pprint_py_expr(target, _CALL_PREC)}[{first}:{last}]"
        case PyIndex(_, target, index):
            return (f"{pprint_py_expr(target, _CALL_PREC)}"
                    f"[{pprint_py_expr(index)}]")
        case PyAnd(_, l, r):
            # `and` binds looser than everything built here, so it takes
            # the lowest level and its operands are parenthesized where
            # they need to be by the rule above.
            return _wrap(_AND_PREC, min_prec,
                         f"{pprint_py_expr(l, _AND_PREC)} and "
                         f"{pprint_py_expr(r, _AND_PREC + 1)}")
        case PyAdd(_, l, r):
            return _wrap(2, min_prec, f"{pprint_py_expr(l, 2)} + {pprint_py_expr(r, 3)}")
        case PySub(_, l, r):
            return _wrap(2, min_prec, f"{pprint_py_expr(l, 2)} - {pprint_py_expr(r, 3)}")
        case PyMul(_, l, r):
            return _wrap(3, min_prec, f"{pprint_py_expr(l, 3)} * {pprint_py_expr(r, 4)}")
        case PyDiv(_, l, r):
            return _wrap(3, min_prec, f"{pprint_py_expr(l, 3)} / {pprint_py_expr(r, 4)}")
        case PyFloorDiv(_, l, r):
            return _wrap(3, min_prec, f"{pprint_py_expr(l, 3)} // {pprint_py_expr(r, 4)}")
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
    """c as Python source text. PyCompClause -> String"""
    # min_prec 1 forces parens around a PyIfExp: Python's comprehension
    # grammar excludes a bare conditional expression after `in`/`if`.
    match c:
        case PyCompFor(_, target, sequence):
            return f"for {pprint_py_target(target)} in {pprint_py_expr(sequence, 1)}"
        case PyCompIf(_, condition):
            return f"if {pprint_py_expr(condition, 1)}"


def pprint_py_pattern(p):
    """p as Python source text. PyPattern -> String"""
    match p:
        case PyPInt(_, v):
            return str(v)
        case PyPString(_, s):
            return _quote_string(s)
        case PyPBool(_, v):
            # True/False are value patterns to Python's match (PEP 634).
            return "True" if v else "False"
        case PyPWildcard(_):
            return "_"
        case PyPCapture(_, name):
            return name
        case PyPGuarded(_, name, _, _):
            # `str() as name`: the class test is what makes the guard
            # below it safe to run on any subject.
            return f"str() as {name}"
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
    """t as Python source text. PyTarget -> String"""
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
    """Renders a statement list as source lines, with a blank line
    around each nested def (never at the block's own start or end).
    [PyStmt] -> Int -> [String]"""
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
    """s as Python source text, indented to level. PyStmt -> Int ->
    String"""
    pad = "    " * level
    match s:
        case PyAssign(_, target, expr):
            return f"{pad}{pprint_py_target(target)} = {pprint_py_expr(expr)}"
        case PyReturn(_, expr):
            return f"{pad}return {pprint_py_expr(expr)}"
        case PyExprStmt(_, expr):
            return f"{pad}{pprint_py_expr(expr)}"
        case PyImport(_, module, alias):
            return (f"{pad}import {module}" if alias is None
                    else f"{pad}import {module} as {alias}")
        case PyFromImport(_, module, fields):
            taken = ", ".join(
                name if name == local else f"{name} as {local}"
                for name, local in fields
            )
            return f"{pad}from {module} import {taken}"
        case PyGlobal(_, names):
            return f"{pad}global {', '.join(names)}"
        case PyNonlocal(_, names):
            return f"{pad}nonlocal {', '.join(names)}"
        case PyFor(_, name, iterable, body, orelse):
            lines = [f"{pad}for {name} in {pprint_py_expr(iterable)}:"]
            lines += _render_block(body, level + 1)
            if orelse:
                lines.append(f"{pad}else:")
                lines += _render_block(orelse, level + 1)
            return "\n".join(lines)
        case PyWhile(_, cond, body, orelse):
            lines = [f"{pad}while {pprint_py_expr(cond)}:"]
            lines += _render_block(body, level + 1)
            if orelse:
                lines.append(f"{pad}else:")
                lines += _render_block(orelse, level + 1)
            return "\n".join(lines)
        case PyBreak(_):
            return f"{pad}break"
        case PyContinue(_):
            return f"{pad}continue"
        case PyIf(_, cond, then_body, else_body):
            lines = [f"{pad}if {pprint_py_expr(cond)}:"]
            lines += _render_block(then_body, level + 1)
            # An else body of exactly one if prints as elif, flattening
            # an else-if ladder instead of nesting one indent per branch.
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
                guard = "" if c.guard is None else f" if {pprint_py_expr(c.guard)}"
                lines.append(
                    f"{pad}    case {pprint_py_pattern(c.pattern)}{guard}:"
                )
                lines += _render_block(c.body, level + 2)
            return "\n".join(lines)
        case _:
            raise NotImplementedError(f"no pretty printer for Python statement {s!r}")


# Markers around the prelude, separating host boilerplate from the
# translated source (docs/target_python.md, "Booleans").
_PRELUDE_BEGIN = "\n".join([
    "# --- prelude begins ---",
    "# Pyking prints a Bool as `true`/`false`, not Python's own capitalised",
    "# `True`/`False`, wherever it sits -- on its own, or inside a list or",
    "# a tuple. This helper exists because at least one value printed below",
    "# isn't provably free of Bools from its Pyking source form alone (a",
    "# variable, a call, or a container), so it is walked at runtime.",
])
_PRELUDE_END = "# --- prelude ends; the compiled program follows ---"


def pprint_py_program(program):
    """program as Python source text. PyProgram -> String"""
    body = "\n".join(_render_block(program.stmts, 0))
    if not program.prelude:
        return body
    prelude_body = "\n".join(_render_block(program.prelude, 0))
    return "\n".join([_PRELUDE_BEGIN, "", prelude_body, "", _PRELUDE_END, "", body])
