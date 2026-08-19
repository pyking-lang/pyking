"""The JavaScript code-generation core: a JS AST, a translation from
syntax.py, and a printer. Knows nothing about packaging (node script, ES
module, or HTML page): that is src/target_js_packaging.py's job. See
docs/target_js.md for how each construct compiles and where the output
is not optimal.

Data structures:
    UnsupportedError -- a construct this backend cannot compile, with
        the source position.
    JsExpr / JsStmt -- base classes for the JavaScript AST; see the
        trailing comment on each variant for its shape.
    Scope -- Pyking name -> JavaScript name, threaded through
        translation.

Functions:
    translate_program(stmts) -- translates a whole program to [JsStmt].
    translate_expr(e, scope) -- translates one expression.
    translate_stmt(s, scope) -- translates one statement; returns
        (JsStmt, Scope).
    pprint_js_program(stmts, runtime) -- [JsStmt] to JavaScript source
        text; runtime maps each runtime operation to its call spelling.
"""

from dataclasses import dataclass

from lexer import Info
import runtime_interface
from syntax import (
    EInt, EString, EBool, EVar,
    EAdd, ESub, EMul, EDiv, ENeg,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EIf, ETuple,
    SLet, SLetStmt, SVar, SMutate, SReturn, SReturnStmt, SExprStmt, SWhile, SIf,
    SLoop, SBreak, SContinue, SFunctionDef,
    TargetName, TargetTuple,
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
class JsArray(JsExpr):      # [e1, e2, ...] -- a Pyking tuple
    info: Info
    elements: list


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


class JsTarget:
    """Base class for what a declaration or assignment binds: a name,
    or an array pattern taking a tuple apart."""


@dataclass(frozen=True)
class JsTargetName(JsTarget):   # name
    info: Info
    name: str


@dataclass(frozen=True)
class JsTargetArray(JsTarget):  # [t1, t2, ...]
    info: Info
    elements: list


class JsStmt:
    """Base class for the JavaScript statement AST."""


@dataclass(frozen=True)
class JsConst(JsStmt):      # const target = expr;   (Pyking `=`)
    info: Info
    target: JsTarget
    expr: JsExpr


@dataclass(frozen=True)
class JsLet(JsStmt):        # let target = expr;     (Pyking `var`)
    info: Info
    target: JsTarget
    expr: JsExpr


@dataclass(frozen=True)
class JsAssign(JsStmt):     # target = expr;         (Pyking `:=`)
    info: Info
    target: JsTarget
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
class JsBreak(JsStmt):      # break;
    info: Info


@dataclass(frozen=True)
class JsContinue(JsStmt):   # continue;
    info: Info


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
# Renames only where JavaScript's own const rules force it (redeclaration,
# the temporal dead zone); see docs/target_js.md, "Scope and renaming".


@dataclass(frozen=True)
class Scope:
    """Pyking name -> the JavaScript name standing in for it, plus the
    names the current block binds (a rename is needed for those too, and
    only the block itself can tell), plus every JavaScript name already
    spoken for here. The last of those is what `names` cannot say: it
    maps each Pyking name to its *current* JavaScript name, so a name
    rebound three times would otherwise offer the second one's spelling
    back to the fourth binding -- and JavaScript refuses a `const`
    declared twice."""
    names: dict
    block: frozenset
    taken: frozenset = frozenset()


def _block_scope(scope):
    """A scope for a nested block: it sees the enclosing names, and what
    it binds is dropped when the caller carries on with its own scope."""
    return Scope(scope.names, frozenset(), scope.taken)


def _lookup(name, scope):
    """The JavaScript name a Pyking name reads as. Names bound nowhere
    are runtime operations or builtins, and pass through unchanged."""
    return scope.names.get(name, name)


# Legal Pyking identifiers that are reserved words in JavaScript (see
# docs/target_js.md, "Names that are keywords in JavaScript").
RESERVED = frozenset("""
await break case catch class const continue debugger default delete do
else enum export extends false finally for function if implements import
in instanceof interface let new null package private protected public
return static super switch this throw true try typeof var void while
with yield arguments eval undefined NaN Infinity console String
""".split())


def _fresh_js_name(name, scope):
    """`name2`, `name3`, ... -- the first not already spoken for here."""
    taken = set(scope.names) | set(scope.names.values()) | set(scope.taken)
    n = 2
    while f"{name}{n}" in taken or f"{name}{n}" in RESERVED:
        n += 1
    return f"{name}{n}"


def _bind(name, scope):
    """Binds a Pyking name, returning `(js_name, extended_scope)`."""
    js_name = name
    if (
        name in RESERVED
        or name in scope.names
        or name in scope.names.values()
        or name in scope.taken
    ):
        js_name = _fresh_js_name(name, scope)
    return js_name, Scope(
        {**scope.names, name: js_name},
        scope.block | {name},
        scope.taken | {js_name},
    )


def _reserve(names, scope):
    """scope with these JavaScript names spoken for, but meaning
    nothing: what a loop does with its accumulator, which is declared
    in this block and in scope only in the loop's own body.
    [String] -> Scope -> Scope"""
    return Scope(scope.names, scope.block, scope.taken | set(names))


# The enclosing `loop`s, innermost last (see `_Loop`): what a
# `break`/`continue` with an operand assigns before it jumps.
_loop_accumulators = []


# Builtins this backend has no translation for yet (docs/target_js.md,
# "str, range and len").
UNSUPPORTED_BUILTINS = ("str", "range", "len")


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
    "EListComp": "list comprehensions",
    "SFor": "`for` loops",
    "SMatch": "`match` statements",
    "SLetStmt": "value-form `if`/`match` bindings",
}


def _unsupported(node, what):
    """Raises UnsupportedError naming what (a construct or an AST class
    name) at node. Expr|Stmt -> String -> ()"""
    name = _CONSTRUCT_NAMES.get(what, what)
    raise UnsupportedError(
        node.info, f"{name} are not supported by the JavaScript backends yet"
    )


def translate_expr(e, scope):
    """Translates one expression. Raises UnsupportedError for a
    construct outside this backend's subset. Expr -> Scope -> JsExpr"""
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
        case ETuple(info, elements):
            # A tuple is a JavaScript array: it is built, taken apart
            # and printed as one (docs/target_js.md, "Tuples").
            return JsArray(info, [translate_expr(el, scope) for el in elements])
        case ECall(info, EVar(_, name), args) if runtime_interface.lookup(name):
            # A call that leaves the program: see runtime_interface.py.
            return JsRuntimeCall(
                info, name, [translate_expr(a, scope) for a in args]
            )
        case ECall(info, EVar(_, name), _) if (
            name in UNSUPPORTED_BUILTINS and _lookup(name, scope) == name
        ):
            _unsupported(e, f"the builtin `{name}` is not supported yet")
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


def _yields_unit(expr):
    """Whether `expr` is a call across the runtime interface (`print`).
    Those yield unit, so a function whose tail is one needs no `return`:
    JavaScript's own implicit `undefined` already is it."""
    match expr:
        case ECall(_, EVar(_, name), _):
            return runtime_interface.lookup(name) is not None
        case _:
            return False


def translate_tail_stmts(stmts, scope):
    """Translates a statement list whose last statement is in tail
    position (PYKING.md, "Tail position"; docs/target_js.md, "Tail
    position"). [Stmt] -> Scope -> [JsStmt]"""
    if not stmts:
        return []
    # The whole block, last statement included: a `def` in tail position
    # is still visible to everything above it.
    scope = declare_functions(stmts, scope)
    body, tail_scope = translate_stmts(stmts[:-1], scope)
    return body + translate_tail_stmt(stmts[-1], tail_scope)


def translate_tail_stmt(s, scope):
    """The last statement of a body in tail position, as a list of JS
    statements. Stmt -> Scope -> [JsStmt]"""
    match s:
        case SExprStmt(_, expr) if _yields_unit(expr):
            translated, _ = translate_stmt(s, scope)
            return [translated]
        case SExprStmt(info, expr):
            return [JsReturn(info, translate_expr(expr, scope))]
        case SIf(info, cond, then_body, else_body):
            js_then = translate_tail_stmts(then_body, _block_scope(scope))
            js_else = (
                None
                if else_body is None
                else translate_tail_stmts(else_body, _block_scope(scope))
            )
            return [JsIf(info, translate_expr(cond, scope), js_then, js_else)]
        case SLoop(info):
            # A function ending in a loop returns what the loop
            # produced: the accumulator it stopped with.
            js_stmts, value, _ = _translate_loop(s, scope)
            return js_stmts + [JsReturn(info, value)]
        case _:
            translated, _ = translate_stmt(s, scope)
            return _as_stmts(translated)


def translate_stmt(s, scope):
    """Translates one statement, returning it with the scope it leaves
    behind. A loop answers with several statements, so the result may be
    a list (see `_as_stmts`).
    Stmt -> Scope -> (JsStmt | [JsStmt], Scope)"""
    match s:
        case SLet(info, target, expr):
            js_expr = translate_expr(expr, scope)
            js_target, scope = translate_target(target, scope)
            return JsConst(info, js_target, js_expr), scope

        case SLetStmt(info, target, SLoop() as loop):
            # `x = loop ...` -- the loop's value is the accumulator it
            # stopped with, so the binding is one assignment after it.
            js_stmts, value, scope = _translate_loop(loop, scope)
            js_target, scope = translate_target(target, scope)
            return js_stmts + [JsConst(info, js_target, value)], scope

        case SVar(info, name, expr):
            js_expr = translate_expr(expr, scope)
            js_name, scope = _bind(name, scope)
            return JsLet(info, JsTargetName(info, js_name), js_expr), scope

        case SMutate(info, name, expr):
            # An update, not a binding: it reuses whatever name the
            # variable was given when it was declared.
            return JsAssign(
                info,
                JsTargetName(info, _lookup(name, scope)),
                translate_expr(expr, scope),
            ), scope

        case SReturn(info, expr):
            return JsReturn(info, translate_expr(expr, scope)), scope

        case SReturnStmt(_, stmt):
            # `return if c:` -- the same push-down as a tail-position
            # `if`, written explicitly so it also works before the end of
            # the body. A loop answers with several statements.
            return translate_tail_stmt(stmt, scope), scope

        case SExprStmt(info, expr):
            return JsExprStmt(info, translate_expr(expr, scope)), scope

        case SWhile(info, cond, body):
            js_body, _ = translate_stmts(body, _block_scope(scope))
            return JsWhile(info, translate_expr(cond, scope), js_body), scope

        case SLoop():
            js_stmts, _, scope = _translate_loop(s, scope)
            return js_stmts, scope

        case SBreak(info, expr):
            loop = _loop_accumulators[-1] if _loop_accumulators else None
            if loop is not None and loop.result is not None:
                # The loop's value lives in a variable of its own; a
                # bare `break` leaves the accumulator there.
                answer = (
                    _target_as_expr(loop.accumulator) if expr is None
                    else translate_expr(expr, scope)
                )
                return [JsAssign(info, loop.result, answer), JsBreak(info)], scope
            if expr is None:
                return JsBreak(info), scope
            js_expr = translate_expr(expr, scope)
            if loop is None or loop.accumulator is None:
                # A loop carrying nothing has nowhere to put the operand
                # (the type checker refuses this outright); it is still
                # an expression, so it still runs.
                return [JsExprStmt(info, js_expr), JsBreak(info)], scope
            return [JsAssign(info, loop.accumulator, js_expr), JsBreak(info)], scope

        case SContinue(info, expr):
            if expr is None:
                return JsContinue(info), scope
            js_expr = translate_expr(expr, scope)
            loop = _loop_accumulators[-1] if _loop_accumulators else None
            if loop is None or loop.accumulator is None:
                return [JsExprStmt(info, js_expr), JsContinue(info)], scope
            return [JsAssign(info, loop.accumulator, js_expr), JsContinue(info)], scope

        case SIf(info, cond, then_body, else_body):
            js_then, _ = translate_stmts(then_body, _block_scope(scope))
            js_else = None
            if else_body is not None:
                js_else, _ = translate_stmts(else_body, _block_scope(scope))
            return JsIf(info, translate_expr(cond, scope), js_then, js_else), scope

        case SFunctionDef(info, name, params, body, _return_type):
            # The name was bound by declare_functions; read it back
            # rather than binding again, which would rename it twice.
            js_name = _lookup(name, scope)
            body_scope = _block_scope(scope)
            param_names = []
            for param in params:
                js_param, body_scope = _bind(param.name, body_scope)
                param_names.append(js_param)
            js_body = translate_tail_stmts(body, body_scope)
            return JsFunc(info, js_name, param_names, js_body), scope

        case _:
            _unsupported(s, type(s).__name__)


def translate_target(target, scope):
    """Binds every name in an assignment target, giving the JavaScript
    target that stands for it -- a name, or the array pattern that takes
    a tuple apart. AssignTarget -> Scope -> (JsTarget, Scope)"""
    match target:
        case TargetName(info, name):
            js_name, scope = _bind(name, scope)
            return JsTargetName(info, js_name), scope
        case TargetTuple(info, elements):
            js_elements = []
            for element in elements:
                js_element, scope = translate_target(element, scope)
                js_elements.append(js_element)
            return JsTargetArray(info, js_elements), scope


@dataclass(frozen=True)
class _Loop:
    """One `loop` being translated. Fields: accumulator, JsTarget? (what
    the loop carries, absent for a `loop:` carrying nothing); result,
    JsTarget? (where the loop's value is left, present only when a
    `break` gives something the accumulator has no room for)."""
    accumulator: JsTarget
    result: JsTarget


def _fresh_result_name(scope):
    """A name for a loop-result variable that nothing here uses.
    Scope -> String"""
    n = 1
    while f"tmp{n}" in scope.taken or f"tmp{n}" in scope.names.values():
        n += 1
    return f"tmp{n}"


def _breaks_with_value(body):
    """Whether any `break` belonging to this body's own loop carries an
    operand -- a nested loop's breaks belong to that loop.
    [Stmt] -> Bool"""
    for s in body:
        match s:
            case SBreak(_, expr) if expr is not None:
                return True
            case SIf(_, _, then_body, else_body):
                if _breaks_with_value(then_body) or _breaks_with_value(
                    else_body or []
                ):
                    return True
            case _:
                pass
    return False


def _target_names(target):
    """Every JavaScript name a target declares. JsTarget -> [String]"""
    match target:
        case JsTargetName(_, name):
            return [name]
        case JsTargetArray(_, elements):
            return [name for e in elements for name in _target_names(e)]


def _target_as_expr(target):
    """A target read back as an expression: what a loop's accumulator
    holds once the loop has stopped. JsTarget -> JsExpr"""
    match target:
        case JsTargetName(info, name):
            return JsVar(info, name)
        case JsTargetArray(info, elements):
            return JsArray(info, [_target_as_expr(e) for e in elements])


def _translate_loop(s, scope):
    """Translates a loop into `while (true)` over a `let` accumulator
    (docs/target_js.md, "loop"): the initializer is the accumulator's
    first value, every tail of the body assigns the next one, and a
    `break`/`continue` with an operand assigns it before it jumps.
    Returns the statements, the expression holding the loop's value
    afterwards, and the scope: the accumulator is in scope only in the
    loop's own body, but its `let` is declared in the block around it,
    so that name stays spoken for there -- a second loop reusing the
    Pyking name gets a fresh one rather than a duplicate declaration.
    SLoop -> Scope -> ([JsStmt], JsExpr, Scope)"""
    info = s.info
    setup = []
    js_target = None
    # A loop carrying nothing yields unit, which is the empty tuple.
    value = JsArray(info, [])
    body_scope = _block_scope(scope)
    if s.target is not None:
        # The initializer is translated before the accumulator binds, so
        # `loop x = x + 1:` reads the enclosing `x`.
        js_init = translate_expr(s.init, scope)
        js_target, body_scope = translate_target(s.target, body_scope)
        scope = _reserve(_target_names(js_target), scope)
        # `let`, not `const`: one JavaScript variable carries what
        # Pyking binds afresh on every turn.
        setup.append(JsLet(info, js_target, js_init))
        value = _target_as_expr(js_target)
    # A loop is worth what it breaks with, which need not be shaped like
    # what it carries: `break acc` in a loop carrying two values has
    # nowhere in the accumulator to go, so it gets a variable of its own.
    result = None
    if isinstance(js_target, JsTargetArray) and _breaks_with_value(s.body):
        result = JsTargetName(info, _fresh_result_name(scope))
        scope = _reserve([result.name], scope)
        setup.append(JsLet(info, result, JsArray(info, [])))
        value = JsVar(info, result.name)
    _loop_accumulators.append(_Loop(js_target, result))
    try:
        js_body = _translate_loop_block(s.body, js_target, body_scope)
    finally:
        _loop_accumulators.pop()
    return setup + [JsWhile(info, JsBool(info, True), js_body)], value, scope


def _translate_loop_block(stmts, js_target, scope):
    """Translates a loop body: whatever a path ends in is the next
    turn's accumulator, so every tail becomes an assignment to
    js_target -- except a `break`/`continue`, which has already said
    what happens next. js_target is None for a loop carrying nothing,
    where the body's value is discarded.
    [Stmt] -> JsTarget? -> Scope -> [JsStmt]"""
    if not stmts:
        return []
    scope = declare_functions(stmts, scope)
    body, scope = translate_stmts(stmts[:-1], scope)
    return body + _translate_loop_tail(stmts[-1], js_target, scope)


def _translate_loop_tail(s, js_target, scope):
    """The last statement of a loop body, or of one branch of one.
    Stmt -> JsTarget? -> Scope -> [JsStmt]"""
    if js_target is None:
        return _as_stmts(translate_stmt(s, scope)[0])
    match s:
        case SExprStmt(info, expr):
            return [JsAssign(info, js_target, translate_expr(expr, scope))]
        case SIf(info, cond, then_body, else_body):
            js_then = _translate_loop_block(then_body, js_target, _block_scope(scope))
            if else_body is None:
                # A path that runs no branch produces nothing, and
                # nothing is unit (PYKING.md, "Tail position").
                js_else = [JsAssign(info, js_target, JsArray(info, []))]
            else:
                js_else = _translate_loop_block(
                    else_body, js_target, _block_scope(scope)
                )
            return [JsIf(info, translate_expr(cond, scope), js_then, js_else)]
        case SBreak() | SContinue() | SReturn() | SReturnStmt():
            # Each of these says by itself what happens next: two leave
            # the loop, one leaves the whole function.
            return _as_stmts(translate_stmt(s, scope)[0])
        case _:
            return _as_stmts(translate_stmt(s, scope)[0]) + [
                JsAssign(s.info, js_target, JsArray(s.info, []))
            ]


def _as_stmts(translated):
    """One translation's statements: a statement translator may answer
    with several (a loop is a setup plus a `while`).
    (JsStmt | [JsStmt]) -> [JsStmt]"""
    return list(translated) if isinstance(translated, list) else [translated]


def declare_functions(stmts, scope):
    """Binds every def in this block before any of it is translated
    (docs/target_js.md, "Functions used before they are written").
    [Stmt] -> Scope -> Scope"""
    for s in stmts:
        if isinstance(s, SFunctionDef) and s.name not in scope.block:
            _, scope = _bind(s.name, scope)
    return scope


def translate_stmts(stmts, scope):
    """Translates a statement sequence, threading the scope through it."""
    scope = declare_functions(stmts, scope)
    translated = []
    for s in stmts:
        js_stmt, scope = translate_stmt(s, scope)
        translated.extend(_as_stmts(js_stmt))
    return translated, scope


def translate_program(stmts):
    """A whole Pyking program as JavaScript statements, ready for a
    packager to wrap. [Stmt] -> [JsStmt]"""
    global _loop_accumulators
    _loop_accumulators = []
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
    """s as a single-quoted JavaScript string literal. String -> String"""
    return "'" + "".join(_ESCAPES.get(ch, ch) for ch in s) + "'"


def _wrap(prec, min_prec, text):
    """text, parenthesized if prec is below min_prec. Int -> Int ->
    String -> String"""
    return f"({text})" if prec < min_prec else text


def pprint_js_expr(e, runtime, min_prec=0):
    """e as JavaScript source text. runtime maps each runtime operation
    to the JavaScript expression that performs it. JsExpr -> {String:
    String} -> Int -> String"""
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
        case JsArray(_, elements):
            return f"[{', '.join(pprint_js_expr(el, runtime) for el in elements)}]"
        case JsCall(_, func, args):
            args_text = ", ".join(pprint_js_expr(a, runtime) for a in args)
            return f"{pprint_js_expr(func, runtime, _CALL_PRECEDENCE)}({args_text})"
        case JsRuntimeCall(_, operation, args):
            args_text = ", ".join(pprint_js_expr(a, runtime) for a in args)
            return f"{runtime[operation]}({args_text})"
        case _:
            raise NotImplementedError(f"no printer for JavaScript expression {e!r}")


def pprint_js_target(target):
    """target as JavaScript source text: a name, or the array pattern
    that takes a tuple apart. JsTarget -> String"""
    match target:
        case JsTargetName(_, name):
            return name
        case JsTargetArray(_, elements):
            return f"[{', '.join(pprint_js_target(e) for e in elements)}]"


def _join_stmts(stmts, runtime, level):
    """Renders a statement list as one string, with a blank line around
    each function definition (never at the block's own start or end).
    [JsStmt] -> {String: String} -> Int -> String"""
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
    """s as JavaScript source text, indented to level. JsStmt -> {String:
    String} -> Int -> String"""
    pad = "  " * level
    match s:
        case JsConst(_, target, expr):
            return f"{pad}const {pprint_js_target(target)} = {pprint_js_expr(expr, runtime)};"
        case JsLet(_, target, expr):
            return f"{pad}let {pprint_js_target(target)} = {pprint_js_expr(expr, runtime)};"
        case JsAssign(_, target, expr):
            return f"{pad}{pprint_js_target(target)} = {pprint_js_expr(expr, runtime)};"
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
        case JsBreak(_):
            return f"{pad}break;"
        case JsContinue(_):
            return f"{pad}continue;"
        case JsFunc(_, name, params, body):
            lines = [f"{pad}function {name}({', '.join(params)}) {{"]
            lines.append(_join_stmts(body, runtime, level + 1))
            lines.append(f"{pad}}}")
            return "\n".join(lines)
        case _:
            raise NotImplementedError(f"no printer for JavaScript statement {s!r}")


def pprint_js_program(stmts, runtime, level=0):
    """stmts as JavaScript source text. [JsStmt] -> {String: String} ->
    Int -> String"""
    return _join_stmts(stmts, runtime, level)
