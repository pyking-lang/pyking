from dataclasses import dataclass

from lexer import Info
from syntax import (
    EInt, EString, EVar,
    EAdd, ESub, EMul, EDiv,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EList, ETuple,
    EListComp, CompFor, CompIf,
    PInt, PString, PWildcard, PCapture, PTuple, PList,
    SLet, SVar, SMutate, SReturn, SExprStmt, SFor, SWhile, SIf, SFunctionDef, SMatch,
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


# --- translation: Pyking AST (syntax.py) -> Python target AST ---
#
# List comprehensions need special handling: Pyking allows an arbitrary
# *pattern* in a comprehension's `for` clause (matching Python's own
# comprehension grammar otherwise), with the semantics that an element
# the pattern doesn't match is filtered out -- something Python's own
# comprehension `for` targets can't express (they're plain assignment
# targets, never "refutable"). Each Pyking `for pattern in seq` clause is
# desugared into two Python comprehension clauses: iterate the raw items,
# then run each one through an auto-generated helper function that
# attempts the pattern match using Python's own `match` statement (which
# _does_ support arbitrary patterns, just not inside a comprehension) and
# returns either `[]` (no match) or a one-element list holding a tuple of
# the bound names (match). A single Python `for <names> in helper(item)`
# clause then does double duty as both the filter -- iterating zero times
# drops the element -- and the bind -- iterating once unpacks the names --
# with no extra `if`/indexing machinery needed. These helper functions are
# pattern-only (no references to anything in the enclosing scope), so
# they're always safe to hoist to the top of the generated file;
# `_pending_comp_helpers` collects them during translation and
# `translate_program` (the sole external entry point, see
# `_translate_stmts` below) drains and prepends them once, at the very
# end, regardless of how deeply the originating comprehension was nested.

_comp_counter = 0
_pending_comp_helpers = []


def _fresh_comp_id():
    global _comp_counter
    _comp_counter += 1
    return _comp_counter


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


def _build_match_helper(pattern):
    """Synthesizes a closure-free `PyFunctionDef` that tests a single
    value against `pattern`: returns `[(bound names...)]` if it matches,
    or `[]` if it doesn't. Registers it in `_pending_comp_helpers` and
    returns `(helper_name, captured_names)`."""
    info = pattern.info
    helper_name = f"__pyk_match_{_fresh_comp_id()}"
    v = PyVar(info, "__pyk_v")
    names = pattern_captured_names(pattern)
    success = PyReturn(
        info, PyList(info, [PyTuple(info, [PyVar(info, n) for n in names])])
    )
    match_stmt = PyMatch(
        info, v, [PyMatchCase(info, translate_pattern(pattern), [success])]
    )
    failure = PyReturn(info, PyList(info, []))
    helper = PyFunctionDef(info, helper_name, ["__pyk_v"], [match_stmt, failure])
    _pending_comp_helpers.append(helper)
    return helper_name, names


def _translate_comp_for(clause):
    """Expands one Pyking `CompFor(pattern, sequence)` into the two
    Python comprehension clauses described above."""
    info = clause.info
    item_var = f"__pyk_item_{_fresh_comp_id()}"
    helper_name, names = _build_match_helper(clause.pattern)
    # The unpacking target is always a tuple target, e.g. `()` if the
    # pattern captures nothing, `(n,)` for one name -- `PyTargetTuple`
    # already prints the right shape (including the singleton comma) in
    # every case, so there's no need to special-case any of them here.
    target = PyTargetTuple(info, [PyTargetName(info, n) for n in names])
    return [
        PyCompFor(info, PyTargetName(info, item_var), translate_expr(clause.sequence)),
        PyCompFor(
            info, target, PyCall(info, PyVar(info, helper_name), [PyVar(info, item_var)])
        ),
    ]


def translate_expr(e):
    match e:
        case EInt(info, v):
            return PyInt(info, v)
        case EString(info, s):
            return PyString(info, s)
        case EVar(info, name):
            return PyVar(info, name)
        case EAdd(info, l, r):
            return PyAdd(info, translate_expr(l), translate_expr(r))
        case ESub(info, l, r):
            return PySub(info, translate_expr(l), translate_expr(r))
        case EMul(info, l, r):
            return PyMul(info, translate_expr(l), translate_expr(r))
        case EDiv(info, l, r):
            return PyDiv(info, translate_expr(l), translate_expr(r))
        case ELessThan(info, l, r):
            return PyLessThan(info, translate_expr(l), translate_expr(r))
        case ELessThanEq(info, l, r):
            return PyLessThanEq(info, translate_expr(l), translate_expr(r))
        case EGreatThan(info, l, r):
            return PyGreatThan(info, translate_expr(l), translate_expr(r))
        case EGreatThanEq(info, l, r):
            return PyGreatThanEq(info, translate_expr(l), translate_expr(r))
        case EEq(info, l, r):
            return PyEq(info, translate_expr(l), translate_expr(r))
        case ECall(info, f, args):
            return PyCall(info, translate_expr(f), [translate_expr(a) for a in args])
        case EList(info, elements):
            return PyList(info, [translate_expr(el) for el in elements])
        case ETuple(info, elements):
            return PyTuple(info, [translate_expr(el) for el in elements])
        case EListComp(info, expr, clauses):
            py_clauses = []
            for clause in clauses:
                match clause:
                    case CompFor():
                        py_clauses += _translate_comp_for(clause)
                    case CompIf(_, condition):
                        py_clauses.append(PyCompIf(clause.info, translate_expr(condition)))
            return PyListComp(info, translate_expr(expr), py_clauses)
        case _:
            raise NotImplementedError(f"no Python translation for expression {e!r}")


def translate_pattern(p):
    match p:
        case PInt(info, v):
            return PyPInt(info, v)
        case PString(info, s):
            return PyPString(info, s)
        case PWildcard(info):
            return PyPWildcard(info)
        case PCapture(info, name):
            return PyPCapture(info, name)
        case PTuple(info, elements):
            return PyPTuple(info, [translate_pattern(e) for e in elements])
        case PList(info, prefix, rest, suffix):
            py_rest = None if rest is None else PyListRest(rest.info, rest.name)
            return PyPList(
                info,
                [translate_pattern(e) for e in prefix],
                py_rest,
                [translate_pattern(e) for e in (suffix or [])],
            )
        case _:
            raise NotImplementedError(f"no Python translation for pattern {p!r}")


def translate_target(t):
    match t:
        case TargetName(info, name):
            return PyTargetName(info, name)
        case TargetTuple(info, elements):
            return PyTargetTuple(info, [translate_target(e) for e in elements])
        case _:
            raise NotImplementedError(f"no Python translation for assignment target {t!r}")


def translate_case(c):
    # Pyking's single-expression `case pattern -> expr` has no Python
    # equivalent, so it desugars here into an ordinary case block whose
    # body is just `return expr` -- the Python target AST itself gains no
    # new node for this; PyMatchCase always just has a `body`.
    if c.expr is not None:
        translated_expr = translate_expr(c.expr)
        body = [PyReturn(translated_expr.info, translated_expr)]
    else:
        body = _translate_stmts(c.body)
    return PyMatchCase(c.info, translate_pattern(c.pattern), body)


def translate_stmt(s):
    match s:
        case SLet(info, target, expr):
            return PyAssign(info, translate_target(target), translate_expr(expr))
        case SVar(info, name, expr):
            return PyAssign(info, PyTargetName(info, name), translate_expr(expr))
        case SMutate(info, name, expr):
            return PyAssign(info, PyTargetName(info, name), translate_expr(expr))
        case SReturn(info, expr):
            return PyReturn(info, translate_expr(expr))
        case SExprStmt(info, expr):
            return PyExprStmt(info, translate_expr(expr))
        case SFor(info, name, iterable, body):
            return PyFor(info, name, translate_expr(iterable), _translate_stmts(body))
        case SWhile(info, cond, body):
            return PyWhile(info, translate_expr(cond), _translate_stmts(body))
        case SIf(info, cond, then_body, else_body):
            translated_else = _translate_stmts(else_body) if else_body is not None else None
            return PyIf(info, translate_expr(cond), _translate_stmts(then_body), translated_else)
        case SFunctionDef(info, name, params, body, _return_type):
            param_names = [p.name for p in params]
            return PyFunctionDef(info, name, param_names, _translate_stmts(body))
        case SMatch(info, subject, cases):
            return PyMatch(info, translate_expr(subject), [translate_case(c) for c in cases])
        case _:
            raise NotImplementedError(f"no Python translation for statement {s!r}")


def _translate_stmts(stmts):
    """Translates a list of statements (a top-level program or any nested
    block) with no side effects of its own -- used both by the external
    entry point below and recursively for nested blocks, so that
    hoisting comprehension-match helpers (see above) happens exactly
    once, at the true top level, regardless of nesting."""
    return [translate_stmt(s) for s in stmts]


def translate_program(stmts):
    """External entry point: translates a full program, resetting the
    comprehension-helper state first and prepending every helper
    function synthesized along the way (see the module comment above)."""
    global _comp_counter, _pending_comp_helpers
    _comp_counter = 0
    _pending_comp_helpers = []
    translated = _translate_stmts(stmts)
    helpers = _pending_comp_helpers
    _pending_comp_helpers = []
    return helpers + translated


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
            return f"{pprint_py_expr(f, 4)}({', '.join(pprint_py_expr(a) for a in args)})"
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
        case _:
            raise NotImplementedError(f"no pretty printer for Python expression {e!r}")


def pprint_py_comp_clause(c):
    match c:
        case PyCompFor(_, target, sequence):
            return f"for {pprint_py_target(target)} in {pprint_py_expr(sequence)}"
        case PyCompIf(_, condition):
            return f"if {pprint_py_expr(condition)}"


def pprint_py_pattern(p):
    match p:
        case PyPInt(_, v):
            return str(v)
        case PyPString(_, s):
            return _quote_string(s)
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
            lines += [pprint_py_stmt(st, level + 1) for st in body]
            return "\n".join(lines)
        case PyWhile(_, cond, body):
            lines = [f"{pad}while {pprint_py_expr(cond)}:"]
            lines += [pprint_py_stmt(st, level + 1) for st in body]
            return "\n".join(lines)
        case PyIf(_, cond, then_body, else_body):
            lines = [f"{pad}if {pprint_py_expr(cond)}:"]
            lines += [pprint_py_stmt(st, level + 1) for st in then_body]
            if else_body is not None:
                lines.append(f"{pad}else:")
                lines += [pprint_py_stmt(st, level + 1) for st in else_body]
            return "\n".join(lines)
        case PyFunctionDef(_, name, params, body):
            lines = [f"{pad}def {name}({', '.join(params)}):"]
            lines += [pprint_py_stmt(st, level + 1) for st in body]
            return "\n".join(lines)
        case PyMatch(_, subject, cases):
            lines = [f"{pad}match {pprint_py_expr(subject)}:"]
            for c in cases:
                lines.append(f"{pad}    case {pprint_py_pattern(c.pattern)}:")
                lines += [pprint_py_stmt(st, level + 2) for st in c.body]
            return "\n".join(lines)
        case _:
            raise NotImplementedError(f"no pretty printer for Python statement {s!r}")


def pprint_py_program(stmts):
    return "\n".join(pprint_py_stmt(s) for s in stmts)
