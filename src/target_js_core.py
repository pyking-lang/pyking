"""The JavaScript code-generation core: a JS AST, a translation from
`src/syntax.py` into it, and a printer.

This module knows nothing about *packaging* -- whether the result ends up
as a node script, an ES module, or an HTML page is decided entirely by
`src/target_js_packaging.py`. What it does know is that some calls cross
the runtime interface (`src/runtime_interface.py`): those become
`JsRuntimeCall`, and the packager says what expression each one is
spelled as (`print`, or `runtime.print`, ...).

JavaScript is a closer fit for Pyking than Python is, and the translation
leans on that rather than working around it:

  - `const` is an immutable binding and `let` a mutable variable, so
    Pyking's `=` and `var` map straight onto them, and `:=` onto ordinary
    assignment -- a distinction the Python backend has to erase;
  - `{ }` blocks are scopes, exactly as Pyking's blocks are.

Only a subset of Pyking is supported so far (see docs/architecture.md);
anything outside it raises `UnsupportedError`, which carries a source
position so the driver can report it like any other compile error.
"""

from dataclasses import dataclass

from lexer import Info
import runtime_interface
from syntax import (
    EInt, EString, EBool, EVar,
    EAdd, ESub, EMul, EDiv, ENeg,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EIf,
    SLet, SVar, SMutate, SReturn, SExprStmt, SWhile, SIf, SFunctionDef,
    TargetName,
)


class UnsupportedError(Exception):
    """Raised for a Pyking construct this backend cannot compile yet;
    carries the source position, like `LexError`/`ParseError`/
    `AnalysisError` do for their stages."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


# --- JavaScript AST ---
#
# One class per statement form, as in `syntax.py`, but a single node for
# binary and unary operators carrying the JS operator as a string. The
# Python backend mirrors Pyking's one-class-per-operator shape because it
# translates each node to a matching one; here the operators are already
# a table (the printer needs one anyway, for precedence), and spelling
# out nine near-identical classes would say nothing the table doesn't.

class JsExpr:
    """Base class for the JavaScript expression AST."""


@dataclass(frozen=True)
class JsNum(JsExpr):
    info: Info
    value: int


@dataclass(frozen=True)
class JsStr(JsExpr):
    info: Info
    value: str


@dataclass(frozen=True)
class JsBool(JsExpr):
    info: Info
    value: bool


@dataclass(frozen=True)
class JsVar(JsExpr):
    info: Info
    name: str


@dataclass(frozen=True)
class JsUnary(JsExpr):      # op operand
    info: Info
    op: str
    operand: JsExpr


@dataclass(frozen=True)
class JsBinary(JsExpr):     # left op right
    info: Info
    op: str
    left: JsExpr
    right: JsExpr


@dataclass(frozen=True)
class JsCall(JsExpr):       # func(args...)
    info: Info
    func: JsExpr
    args: list


@dataclass(frozen=True)
class JsCond(JsExpr):       # cond ? then_expr : else_expr
    info: Info
    cond: JsExpr
    then_expr: JsExpr
    else_expr: JsExpr


@dataclass(frozen=True)
class JsRuntimeCall(JsExpr):
    """A call that crosses the runtime interface, e.g. `print`. The
    operation is named, not spelled: the packager decides whether it
    reads `print(...)` or `runtime.print(...)` in the emitted file."""
    info: Info
    operation: str
    args: list


class JsStmt:
    """Base class for the JavaScript statement AST."""


@dataclass(frozen=True)
class JsConst(JsStmt):      # const name = expr;   (Pyking `=`)
    info: Info
    name: str
    expr: JsExpr


@dataclass(frozen=True)
class JsLet(JsStmt):        # let name = expr;     (Pyking `var`)
    info: Info
    name: str
    expr: JsExpr


@dataclass(frozen=True)
class JsAssign(JsStmt):     # name = expr;         (Pyking `:=`)
    info: Info
    name: str
    expr: JsExpr


@dataclass(frozen=True)
class JsExprStmt(JsStmt):   # expr;
    info: Info
    expr: JsExpr


@dataclass(frozen=True)
class JsIf(JsStmt):         # if (cond) { ... } else { ... }
    info: Info
    cond: JsExpr
    then_body: list
    else_body: list = None


@dataclass(frozen=True)
class JsWhile(JsStmt):      # while (cond) { ... }
    info: Info
    cond: JsExpr
    body: list


@dataclass(frozen=True)
class JsFunc(JsStmt):       # function name(params) { ... }
    info: Info
    name: str
    params: list
    body: list


@dataclass(frozen=True)
class JsReturn(JsStmt):     # return expr;
    info: Info
    expr: JsExpr


# --- scope ---
#
# JavaScript's `{ }` blocks are lexical scopes, so Pyking's blocks map
# onto them directly and shadowing across blocks needs no help. Two
# JavaScript rules still force a rename, and both are about `const`:
# redeclaring one in the same block is a syntax error, and a `const`
# shadowing an outer name makes that name unreadable *anywhere earlier in
# the block* (the temporal dead zone), so `x = 1` then a block containing
# `print(x)` before its own `x = 2` would throw rather than read the outer
# one. Renaming whenever a name is already in scope keeps both away, and
# the new name stays close to the old: `total`, then `total2`, `total3`.


@dataclass(frozen=True)
class Scope:
    """Pyking name -> the JavaScript name standing in for it, plus the
    names the current block binds (a rename is needed for those too, and
    only the block itself can tell)."""
    names: dict
    block: frozenset


def _block_scope(scope):
    """A scope for a nested block: it sees the enclosing names, and what
    it binds is dropped when the caller carries on with its own scope."""
    return Scope(scope.names, frozenset())


def _lookup(name, scope):
    """The JavaScript name a Pyking name reads as. Names bound nowhere
    are runtime operations or builtins, and pass through unchanged."""
    return scope.names.get(name, name)


def _fresh_js_name(name, scope):
    """`name2`, `name3`, ... -- the first not already spoken for here."""
    taken = set(scope.names) | set(scope.names.values())
    n = 2
    while f"{name}{n}" in taken:
        n += 1
    return f"{name}{n}"


def _bind(name, scope):
    """Binds a Pyking name, returning `(js_name, extended_scope)`."""
    js_name = name
    if name in scope.names or name in scope.names.values():
        js_name = _fresh_js_name(name, scope)
    return js_name, Scope({**scope.names, name: js_name}, scope.block | {name})


# --- translation: Pyking AST (syntax.py) -> JavaScript AST ---

_BINARY_OPS = {
    EAdd: "+",
    ESub: "-",
    EMul: "*",
    EDiv: "/",
    ELessThan: "<",
    ELessThanEq: "<=",
    EGreatThan: ">",
    EGreatThanEq: ">=",
    # `===`, not `==`: Pyking compares integers, strings and booleans, and
    # JavaScript's loose equality would relate values across those types.
    EEq: "===",
}


# What each unsupported construct is called in an error message. Nothing
# here is load-bearing -- an entry missing just falls back to the AST
# class name -- but a message naming what the programmer wrote beats one
# naming the node the parser built for it.
_CONSTRUCT_NAMES = {
    "EList": "list literals",
    "ETuple": "tuples",
    "EListComp": "list comprehensions",
    "SFor": "`for` loops",
    "SMatch": "`match` statements",
    "SLetStmt": "value-form `if`/`match` bindings",
}


def _unsupported(node, what):
    name = _CONSTRUCT_NAMES.get(what, what)
    raise UnsupportedError(
        node.info, f"{name} are not supported by the JavaScript backends yet"
    )


def translate_expr(e, scope):
    match e:
        case EInt(info, v):
            return JsNum(info, v)
        case EString(info, s):
            return JsStr(info, s)
        case EBool(info, v):
            return JsBool(info, v)
        case EVar(info, name):
            return JsVar(info, _lookup(name, scope))
        case ENeg(info, operand):
            return JsUnary(info, "-", translate_expr(operand, scope))
        case EIf(info, cond, then_expr, else_expr):
            # Pyking's `if c then a else b` is JavaScript's conditional
            # expression, in the same operand order.
            return JsCond(
                info,
                translate_expr(cond, scope),
                translate_expr(then_expr, scope),
                translate_expr(else_expr, scope),
            )
        case ECall(info, EVar(_, name), args) if runtime_interface.lookup(name):
            # A call that leaves the program: see runtime_interface.py.
            return JsRuntimeCall(
                info, name, [translate_expr(a, scope) for a in args]
            )
        case ECall(info, func, args):
            return JsCall(
                info,
                translate_expr(func, scope),
                [translate_expr(a, scope) for a in args],
            )
        case _ if type(e) in _BINARY_OPS:
            return JsBinary(
                e.info,
                _BINARY_OPS[type(e)],
                translate_expr(e.left, scope),
                translate_expr(e.right, scope),
            )
        case _:
            _unsupported(e, type(e).__name__)


def translate_stmt(s, scope):
    """Translates one statement, returning it with the scope it leaves
    behind, so a sequence accumulates bindings and any rename is visible
    to what follows."""
    match s:
        case SLet(info, TargetName(_, name), expr):
            js_expr = translate_expr(expr, scope)
            js_name, scope = _bind(name, scope)
            return JsConst(info, js_name, js_expr), scope

        case SLet(info, _, _):
            _unsupported(s, "tuple destructuring targets")

        case SVar(info, name, expr):
            js_expr = translate_expr(expr, scope)
            js_name, scope = _bind(name, scope)
            return JsLet(info, js_name, js_expr), scope

        case SMutate(info, name, expr):
            # An update, not a binding: it reuses whatever name the
            # variable was given when it was declared.
            return JsAssign(info, _lookup(name, scope), translate_expr(expr, scope)), scope

        case SReturn(info, expr):
            return JsReturn(info, translate_expr(expr, scope)), scope

        case SExprStmt(info, expr):
            return JsExprStmt(info, translate_expr(expr, scope)), scope

        case SWhile(info, cond, body):
            js_body, _ = translate_stmts(body, _block_scope(scope))
            return JsWhile(info, translate_expr(cond, scope), js_body), scope

        case SIf(info, cond, then_body, else_body):
            js_then, _ = translate_stmts(then_body, _block_scope(scope))
            js_else = None
            if else_body is not None:
                js_else, _ = translate_stmts(else_body, _block_scope(scope))
            return JsIf(info, translate_expr(cond, scope), js_then, js_else), scope

        case SFunctionDef(info, name, params, body, _return_type, expr):
            # Type annotations are erased, as in the Python backend. The
            # single-expression form `def f(x) = e` becomes a body of one
            # `return`, the same desugaring both other backends use.
            js_name, scope = _bind(name, scope)
            body_scope = _block_scope(scope)
            param_names = []
            for param in params:
                js_param, body_scope = _bind(param.name, body_scope)
                param_names.append(js_param)
            if expr is not None:
                js_expr = translate_expr(expr, body_scope)
                js_body = [JsReturn(js_expr.info, js_expr)]
            else:
                js_body, _ = translate_stmts(body, body_scope)
            return JsFunc(info, js_name, param_names, js_body), scope

        case _:
            _unsupported(s, type(s).__name__)


def translate_stmts(stmts, scope):
    """Translates a statement sequence, threading the scope through it."""
    translated = []
    for s in stmts:
        js_stmt, scope = translate_stmt(s, scope)
        translated.append(js_stmt)
    return translated, scope


def translate_program(stmts):
    """External entry point: a whole Pyking program as JavaScript
    statements, ready for a packager to wrap."""
    translated, _ = translate_stmts(stmts, Scope({}, frozenset()))
    return translated


# --- printer: JavaScript AST -> JavaScript source text ---
#
# Precedences are JavaScript's own, spaced so that a child printed at
# `prec + 1` is parenthesized when it binds looser than its parent.

_PRECEDENCE = {
    "*": 12, "/": 12,
    "+": 11, "-": 11,
    "<": 9, "<=": 9, ">": 9, ">=": 9,
    "===": 8,
}
_UNARY_PRECEDENCE = 14
_CONDITIONAL_PRECEDENCE = 3
_CALL_PRECEDENCE = 17

_ESCAPES = {"\\": "\\\\", "'": "\\'", "\n": "\\n", "\t": "\\t", "\r": "\\r"}


def _quote(s):
    return "'" + "".join(_ESCAPES.get(ch, ch) for ch in s) + "'"


def _wrap(prec, min_prec, text):
    return f"({text})" if prec < min_prec else text


def pprint_js_expr(e, runtime, min_prec=0):
    """`runtime` maps each runtime operation to the JavaScript expression
    that performs it -- see `src/target_js_packaging.py`."""
    match e:
        case JsNum(_, v):
            return str(v)
        case JsStr(_, s):
            return _quote(s)
        case JsBool(_, v):
            return "true" if v else "false"
        case JsVar(_, name):
            return name
        case JsUnary(_, op, operand):
            text = f"{op}{pprint_js_expr(operand, runtime, _UNARY_PRECEDENCE + 1)}"
            return _wrap(_UNARY_PRECEDENCE, min_prec, text)
        case JsBinary(_, op, left, right):
            prec = _PRECEDENCE[op]
            # Left-associative: the right operand needs the tighter bound.
            text = (
                f"{pprint_js_expr(left, runtime, prec)} {op} "
                f"{pprint_js_expr(right, runtime, prec + 1)}"
            )
            return _wrap(prec, min_prec, text)
        case JsCond(_, cond, then_expr, else_expr):
            text = (
                f"{pprint_js_expr(cond, runtime, _CONDITIONAL_PRECEDENCE + 1)} ? "
                f"{pprint_js_expr(then_expr, runtime, _CONDITIONAL_PRECEDENCE)} : "
                f"{pprint_js_expr(else_expr, runtime, _CONDITIONAL_PRECEDENCE)}"
            )
            return _wrap(_CONDITIONAL_PRECEDENCE, min_prec, text)
        case JsCall(_, func, args):
            args_text = ", ".join(pprint_js_expr(a, runtime) for a in args)
            return f"{pprint_js_expr(func, runtime, _CALL_PRECEDENCE)}({args_text})"
        case JsRuntimeCall(_, operation, args):
            args_text = ", ".join(pprint_js_expr(a, runtime) for a in args)
            return f"{runtime[operation]}({args_text})"
        case _:
            raise NotImplementedError(f"no printer for JavaScript expression {e!r}")


def _join_stmts(stmts, runtime, level):
    """Joins a statement sequence, setting every function definition off
    with a blank line before and after it -- the spacing a JavaScript
    programmer would write, and the one thing a run of `const`s and calls
    does not need. Never at the start or end of a block, where a blank
    line would only pad the braces."""
    lines = []
    for index, stmt in enumerate(stmts):
        set_off = isinstance(stmt, JsFunc) or (
            index > 0 and isinstance(stmts[index - 1], JsFunc)
        )
        if lines and set_off:
            lines.append("")
        lines.append(pprint_js_stmt(stmt, runtime, level))
    return "\n".join(lines)


def pprint_js_stmt(s, runtime, level=0):
    pad = "  " * level
    match s:
        case JsConst(_, name, expr):
            return f"{pad}const {name} = {pprint_js_expr(expr, runtime)};"
        case JsLet(_, name, expr):
            return f"{pad}let {name} = {pprint_js_expr(expr, runtime)};"
        case JsAssign(_, name, expr):
            return f"{pad}{name} = {pprint_js_expr(expr, runtime)};"
        case JsExprStmt(_, expr):
            return f"{pad}{pprint_js_expr(expr, runtime)};"
        case JsReturn(_, expr):
            return f"{pad}return {pprint_js_expr(expr, runtime)};"
        case JsIf(_, cond, then_body, else_body):
            lines = [f"{pad}if ({pprint_js_expr(cond, runtime)}) {{"]
            lines.append(_join_stmts(then_body, runtime, level + 1))
            # An else body of exactly one `if` prints as `else if`, the
            # flat form Pyking's own `else if` ladder was written in.
            while True:
                match else_body:
                    case [JsIf(_, elif_cond, elif_body, else_body2)]:
                        lines.append(f"{pad}}} else if ({pprint_js_expr(elif_cond, runtime)}) {{")
                        lines.append(_join_stmts(elif_body, runtime, level + 1))
                        else_body = else_body2
                    case None:
                        break
                    case _:
                        lines.append(f"{pad}}} else {{")
                        lines.append(_join_stmts(else_body, runtime, level + 1))
                        break
            lines.append(f"{pad}}}")
            return "\n".join(lines)
        case JsWhile(_, cond, body):
            lines = [f"{pad}while ({pprint_js_expr(cond, runtime)}) {{"]
            lines.append(_join_stmts(body, runtime, level + 1))
            lines.append(f"{pad}}}")
            return "\n".join(lines)
        case JsFunc(_, name, params, body):
            lines = [f"{pad}function {name}({', '.join(params)}) {{"]
            lines.append(_join_stmts(body, runtime, level + 1))
            lines.append(f"{pad}}}")
            return "\n".join(lines)
        case _:
            raise NotImplementedError(f"no printer for JavaScript statement {s!r}")


def pprint_js_program(stmts, runtime, level=0):
    return _join_stmts(stmts, runtime, level)
