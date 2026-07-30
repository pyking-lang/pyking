"""The Java code-generation backend, serving `java8`, `java17` and
`java21`.

Structured exactly like `src/target_c.py`: one translation for every
version (a `J*` AST, built by `_Translator`), and a printer whose *shape*
never changes across versions -- only a handful of spellings do, gated by
a small per-version feature table (`_FEATURES`) rather than three copies
of the printer:

  version   local declarations         compile with
  -------   -------------------        --------------------------------
  java8     `final int x = 1;`         javac --release 8  <file>
  java17    `final var x = 1;`         javac --release 17 <file>
  java21    `final var x = 1;`         javac --release 21 <file>

`var` is local-variable type inference (JEP 286, Java 10); java8 predates
it and spells out the type, java17/java21 use it -- "more language
features in higher targets" here means exactly this one axis, because the
subset this backend accepts (see below) never reaches a construct newer
Java versions would translate differently. A `match` on real values, or
tuples as records, would give java21 something java17 lacks; neither is
implemented yet, so the two currently emit identical code beyond the
`--release` number.

Java is statically typed and Pyking is not, so -- exactly as in
`target_c.py` -- this backend *infers* a type for every binding, parameter
and function, from the same three rules: a binding takes its
initializer's type, a parameter takes its annotation when representable
else a guess from the body, and a function's return type is read back off
its translated body.

Two things Java gives this backend that C does not:

  - string concatenation is Java's own `+` (`"a" + "b"` needs no helper,
    unlike C's `pyk_concat`), so `EAdd` between two strings translates
    straight across;
  - string equality goes through `.equals()`, not `strcmp`, and needs no
    extra header either.

One thing Java is stricter about than C: a non-void method that falls off
its end without returning is a compile error (C merely warns), so this
backend requires every function body to *provably* return on every path
(`_definitely_returns`) and refuses one that does not -- the same spirit
as refusing `/`, just enforced by the target rather than chosen by this
backend. The same strictness makes code after an unconditional return
unreachable to `javac` (`_check_reachable`), where Python simply never
runs it, so that is refused too.

Nested `def` is refused, as in C: Java has no local functions with
Pyking's closure semantics, and a lambda would need a functional-interface
type this backend does not infer, plus mutable capture Java's lambdas do
not allow.

The generated file is named, and its class is named, in Java's own style:
`foo_bar.pyk` compiles by default to `FooBar.java`, holding
`public final class FooBar`, because Java requires the two to match
exactly (`default_class_name`; `src/pykboot.py` derives the class name
from an explicit `--output` instead, when one is given). Top-level Pyking
statements become the body of `public static void main`; `def`s become
`private static` methods.
"""

import re
from dataclasses import dataclass

from lexer import Info
import runtime_interface
from syntax import (
    EInt, EString, EVar,
    EAdd, ESub, EMul, EDiv, ENeg,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EIf,
    SLet, SVar, SMutate, SReturn, SExprStmt, SWhile, SIf, SFunctionDef,
    TargetName, TInt, TString, TBool,
)

VERSIONS = ("java8", "java17", "java21")

# What each version's printer may use. `var_locals` gates local-variable
# type inference (JEP 286, Java 10 -- absent from java8, present from
# java17 on); `release` is the `--release` value the compile-with comment
# suggests. The subset this backend accepts never exercises a feature
# that distinguishes java17 from java21 (see the module docstring), so
# the two rows agree beyond `release`.
_FEATURES = {
    "java8": {"release": "8", "var_locals": False},
    "java17": {"release": "17", "var_locals": True},
    "java21": {"release": "21", "var_locals": True},
}


class UnsupportedError(Exception):
    """Raised for a Pyking construct this backend cannot compile; carries
    the source position, like the other stages' errors."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


# What each unsupported construct is called in an error message, so a
# message names what the programmer wrote rather than the node the parser
# built for it. Shared with `target_c.py`'s list; kept as its own copy so
# this backend depends on `syntax.py` alone, the way each backend does.
_CONSTRUCT_NAMES = {
    "EList": "list literals",
    "ETuple": "tuples",
    "EListComp": "list comprehensions",
    "SFor": "`for` loops",
    "SMatch": "`match` statements",
    "SLetStmt": "value-form `if`/`match` bindings",
}


def _unsupported(node, message):
    raise UnsupportedError(node.info, _CONSTRUCT_NAMES.get(message, message))


# --- types ---
#
# The three kinds of value a Pyking program in this subset can hold, kept
# as their own names (rather than the Java spelling) since a boolean's
# spelling never varies here the way it does in `target_c.py` -- Java has
# had `boolean`/`true`/`false` since 1.0.

INT = "Int"
BOOL = "Bool"
STRING = "String"

_JAVA_TYPES = {INT: "int", BOOL: "boolean", STRING: "String"}

_ANNOTATIONS = {TInt: INT, TString: STRING, TBool: BOOL}


def _annotated_type(annotation):
    """The type an annotation names, or `None` if it names one Java has no
    representation for here (a tuple or list). Nothing checks annotations,
    so an unrepresentable one is ignored in favour of inference rather
    than treated as an error -- `tests/types_tuples.pyk` annotates
    parameters as tuples and then passes integers."""
    return _ANNOTATIONS.get(type(annotation))


# --- Java AST ---
#
# Every expression node carries its type: the translator needs it to
# check operators and to pick `.equals()` over `==`, and the printer needs
# it to turn a printed boolean into Pyking's `True`/`False`.

class JExpr:
    """Base class for the Java expression AST."""


@dataclass(frozen=True)
class JInt(JExpr):
    info: Info
    value: int
    ctype: str = INT


@dataclass(frozen=True)
class JStr(JExpr):
    info: Info
    value: str
    ctype: str = STRING


@dataclass(frozen=True)
class JVar(JExpr):
    info: Info
    name: str
    ctype: str = INT


@dataclass(frozen=True)
class JUnary(JExpr):        # op operand
    info: Info
    op: str
    operand: JExpr
    ctype: str = INT


@dataclass(frozen=True)
class JBinary(JExpr):       # left op right
    info: Info
    op: str
    left: JExpr
    right: JExpr
    ctype: str = INT


@dataclass(frozen=True)
class JCall(JExpr):         # name(args...)
    info: Info
    name: str
    args: list
    ctype: str = INT


@dataclass(frozen=True)
class JCond(JExpr):         # cond ? then_expr : else_expr
    info: Info
    cond: JExpr
    then_expr: JExpr
    else_expr: JExpr
    ctype: str = INT


@dataclass(frozen=True)
class JEquals(JExpr):       # left.equals(right)
    info: Info
    left: JExpr
    right: JExpr
    ctype: str = BOOL


class JStmt:
    """Base class for the Java statement AST."""


@dataclass(frozen=True)
class JDecl(JStmt):         # [final] <type|var> name = init;
    info: Info
    jtype: str
    name: str
    init: JExpr
    is_final: bool = False


@dataclass(frozen=True)
class JAssign(JStmt):       # name = expr;
    info: Info
    name: str
    expr: JExpr


@dataclass(frozen=True)
class JExprStmt(JStmt):     # expr;
    info: Info
    expr: JExpr


@dataclass(frozen=True)
class JPrint(JStmt):        # System.out.println(...);
    info: Info
    expr: JExpr = None       # None: print() with no arguments


@dataclass(frozen=True)
class JIf(JStmt):
    info: Info
    cond: JExpr
    then_body: list
    else_body: list = None


@dataclass(frozen=True)
class JWhile(JStmt):
    info: Info
    cond: JExpr
    body: list


@dataclass(frozen=True)
class JReturn(JStmt):
    info: Info
    expr: JExpr


@dataclass(frozen=True)
class JFunc:                # <ret> name(params) { body }
    info: Info
    name: str
    params: list             # list of (jtype, name)
    body: list
    ret_type: str = INT


@dataclass(frozen=True)
class JProgram:
    """A translated program: the methods, and the statements that become
    the body of `main`. Unlike `target_c.py`'s `CProgram`, there is
    nothing to record about which runtime helpers were used -- string
    concatenation and equality are Java operators/methods, not generated
    helpers, and `System.out.println` needs no import."""
    functions: list
    main_body: list


# --- scope ---
#
# Java blocks are lexical scopes, as Pyking's are, so shadowing across
# blocks needs no help. Rebinding does: Java has no way to declare one
# local twice in a block, and Pyking's `x = 1` then `x = 2` is two
# bindings -- which is convenient here, because the second may hold a
# different *type*, and two Java locals is exactly what that needs.


@dataclass(frozen=True)
class Scope:
    names: dict              # Pyking name -> (Java name, type)
    block: frozenset


def _block_scope(scope):
    return Scope(scope.names, frozenset())


@dataclass(frozen=True)
class _At:
    """Carries an `Info` for `_unsupported` when the offending thing is a
    name rather than a node."""
    info: Info


def _lookup(name, scope, info):
    if name not in scope.names:
        _unsupported(
            _At(info), f"'{name}' is not a value this backend can compile"
        )
    return scope.names[name]


def _fresh_java_name(name, scope):
    taken = set(scope.names) | {java_name for java_name, _ in scope.names.values()}
    n = 2
    while f"{name}{n}" in taken:
        n += 1
    return f"{name}{n}"


def _bind(name, jtype, scope):
    java_name = name
    if name in scope.names or any(name == n for n, _ in scope.names.values()):
        java_name = _fresh_java_name(name, scope)
    return java_name, Scope(
        {**scope.names, name: (java_name, jtype)}, scope.block | {name}
    )


# --- translation ---

_BINARY_OPS = {
    ESub: "-", EMul: "*",
    ELessThan: "<", ELessThanEq: "<=", EGreatThan: ">", EGreatThanEq: ">=",
}


class _Translator:
    """Holds what the walk accumulates: every function's signature, so a
    later call (including a recursive one) can be checked and typed."""

    def __init__(self):
        self.signatures = {}    # Pyking name -> (Java name, [param types], return type)

    # -- expressions --

    def expr(self, e, scope):
        match e:
            case EInt(info, v):
                return JInt(info, v)
            case EString(info, s):
                return JStr(info, s)
            case EVar(info, name):
                java_name, jtype = _lookup(name, scope, info)
                return JVar(info, java_name, jtype)
            case ENeg(info, operand):
                inner = self.expr(operand, scope)
                self._require(inner, INT, "negation")
                return JUnary(info, "-", inner, INT)
            case EDiv(info, _, _):
                _unsupported(
                    e,
                    "`/` is true division in Pyking and truncating integer "
                    "division in Java; matching it needs a floating-point "
                    "type this backend does not have yet",
                )
            case EAdd(info, l, r):
                left, right = self.expr(l, scope), self.expr(r, scope)
                if left.ctype == STRING and right.ctype == STRING:
                    # Java's `+` already means concatenation once either
                    # side is a String -- no helper needed, unlike C.
                    return JBinary(info, "+", left, right, STRING)
                self._require(left, INT, "`+`")
                self._require(right, INT, "`+`")
                return JBinary(info, "+", left, right, INT)
            case EEq(info, l, r):
                left, right = self.expr(l, scope), self.expr(r, scope)
                if left.ctype == STRING and right.ctype == STRING:
                    return JEquals(info, left, right)
                if left.ctype != right.ctype:
                    _unsupported(e, "`==` between values of different types")
                return JBinary(info, "==", left, right, BOOL)
            case EIf(info, cond, then_expr, else_expr):
                c = self.expr(cond, scope)
                t = self.expr(then_expr, scope)
                f = self.expr(else_expr, scope)
                if t.ctype != f.ctype:
                    _unsupported(
                        e,
                        "the branches of an `if` expression must have the "
                        "same type in Java",
                    )
                return JCond(info, c, t, f, t.ctype)
            case ECall(info, EVar(_, name), args) if runtime_interface.lookup(name):
                _unsupported(
                    e, f"`{name}` may only be used as a statement, not as a value"
                )
            case ECall(info, EVar(_, name), args):
                if name not in self.signatures:
                    _unsupported(e, f"call to unknown function `{name}`")
                java_name, param_types, ret = self.signatures[name]
                if len(args) != len(param_types):
                    _unsupported(e, f"`{name}` takes {len(param_types)} argument(s)")
                return JCall(
                    info, java_name, [self.expr(a, scope) for a in args], ret
                )
            case ECall(info, _, _):
                _unsupported(e, "calling anything but a named function")
            case _ if type(e) in _BINARY_OPS:
                left, right = self.expr(e.left, scope), self.expr(e.right, scope)
                op = _BINARY_OPS[type(e)]
                self._require(left, INT, f"`{op}`")
                self._require(right, INT, f"`{op}`")
                ctype = INT if op == "-" or op == "*" else BOOL
                return JBinary(e.info, op, left, right, ctype)
            case _:
                _unsupported(e, type(e).__name__)

    def _require(self, node, ctype, what):
        if node.ctype != ctype:
            _unsupported(
                _At(node.info),
                f"{what} needs {ctype} operands here, not {node.ctype}",
            )

    # -- statements --

    def stmts(self, stmts, scope):
        out = []
        for s in stmts:
            translated, scope = self.stmt(s, scope)
            out.append(translated)
        _check_reachable(out)
        return out, scope

    def block(self, stmts, scope):
        translated, _ = self.stmts(stmts, _block_scope(scope))
        return translated

    def stmt(self, s, scope):
        match s:
            case SLet(info, TargetName(_, name), expr):
                value = self.expr(expr, scope)
                java_name, scope = _bind(name, value.ctype, scope)
                return JDecl(info, value.ctype, java_name, value, True), scope

            case SLet(info, _, _):
                _unsupported(s, "tuple destructuring targets")

            case SVar(info, name, expr):
                value = self.expr(expr, scope)
                java_name, scope = _bind(name, value.ctype, scope)
                return JDecl(info, value.ctype, java_name, value, False), scope

            case SMutate(info, name, expr):
                java_name, jtype = _lookup(name, scope, info)
                value = self.expr(expr, scope)
                if value.ctype != jtype:
                    _unsupported(
                        s,
                        f"`:=` cannot change the type of `{name}` from "
                        f"{jtype} to {value.ctype} in Java",
                    )
                return JAssign(info, java_name, value), scope

            case SReturn(info, expr):
                return JReturn(info, self.expr(expr, scope)), scope

            case SExprStmt(info, ECall(_, EVar(_, name), args)) if (
                runtime_interface.lookup(name)
            ):
                translated_args = [self.expr(a, scope) for a in args]
                return JPrint(info, _build_print_expr(translated_args)), scope

            case SExprStmt(info, expr):
                return JExprStmt(info, self.expr(expr, scope)), scope

            case SWhile(info, cond, body):
                return JWhile(info, self.expr(cond, scope), self.block(body, scope)), scope

            case SIf(info, cond, then_body, else_body):
                java_else = None if else_body is None else self.block(else_body, scope)
                return JIf(
                    info, self.expr(cond, scope), self.block(then_body, scope), java_else
                ), scope

            case SFunctionDef():
                _unsupported(
                    s,
                    "a nested function -- Java has no local functions with "
                    "Pyking's closure semantics; a lambda would need a "
                    "functional-interface type this backend does not infer, "
                    "and could not mutate a captured variable the way a "
                    "nested `def` may need to",
                )

            case _:
                _unsupported(s, type(s).__name__)

    # -- functions --

    def function(self, func, scope):
        """Translates a `def`, registering its signature first so the body
        may call it recursively."""
        param_types = [_param_type(func, p) for p in func.params]
        java_name, scope = _bind(func.name, INT, scope)
        provisional = _annotated_type(func.return_type) or INT
        self.signatures[func.name] = (java_name, param_types, provisional)

        body_scope = _block_scope(scope)
        params = []
        for param, jtype in zip(func.params, param_types):
            java_param, body_scope = _bind(param.name, jtype, body_scope)
            params.append((jtype, java_param))

        if func.expr is not None:
            value = self.expr(func.expr, body_scope)
            body = [JReturn(value.info, value)]
        else:
            body, _ = self.stmts(func.body, body_scope)

        returned = _return_types(body)
        recursive = _calls(body, java_name)
        if len(returned) > 1 or (returned and returned != {provisional} and recursive):
            # A recursive call was typed with the provisional return type
            # before the body could say otherwise, so disagreement here is
            # usually that assumption rather than a genuinely mixed
            # function -- say which, since the fix differs.
            if recursive:
                _unsupported(
                    func,
                    f"`{func.name}` calls itself and does not return Int; a "
                    "recursive function's return type is assumed Int unless "
                    "annotated, so annotate it (`-> String`, `-> Bool`)",
                )
            _unsupported(func, "a function returning more than one type")
        actual = returned.pop() if returned else provisional
        self.signatures[func.name] = (java_name, param_types, actual)

        if not _definitely_returns(body):
            _unsupported(
                func,
                f"`{func.name}` does not return a value on every path; "
                "unlike Python, javac refuses to compile a method that can "
                "fall off the end instead of returning, so make sure every "
                "branch ends in `return`",
            )

        return JFunc(func.info, java_name, params, body, actual), scope


def _param_type(func, param):
    """A parameter's type: its annotation when Java can represent it, else
    what the body's use of it suggests, else `Int`."""
    annotated = _annotated_type(param.type)
    if annotated is not None:
        return annotated
    body = [func.expr] if func.expr is not None else func.body
    return STRING if _used_as_string(param.name, body) else INT


def _used_as_string(name, node):
    """Whether `name` is added to, or compared with, a string literal
    anywhere in `node` -- the one piece of evidence worth chasing, since
    an unannotated parameter is otherwise an integer."""
    from dataclasses import fields, is_dataclass

    match node:
        case EAdd(_, EVar(_, n), EString()) | EAdd(_, EString(), EVar(_, n)):
            if n == name:
                return True
        case EEq(_, EVar(_, n), EString()) | EEq(_, EString(), EVar(_, n)):
            if n == name:
                return True
    if is_dataclass(node):
        return any(
            _used_as_string(name, getattr(node, f.name)) for f in fields(node)
        )
    if isinstance(node, (list, tuple)):
        return any(_used_as_string(name, element) for element in node)
    return False


def _walk_java(node):
    """Every Java AST node under `node`, itself included."""
    from dataclasses import fields, is_dataclass

    if is_dataclass(node):
        yield node
        for f in fields(node):
            yield from _walk_java(getattr(node, f.name))
    elif isinstance(node, (list, tuple)):
        for element in node:
            yield from _walk_java(element)


def _return_types(body):
    return {n.expr.ctype for n in _walk_java(body) if isinstance(n, JReturn)}


def _calls(body, java_name):
    return any(
        isinstance(n, JCall) and n.name == java_name for n in _walk_java(body)
    )


# --- definite return / reachability ---
#
# C only warns when control can fall off the end of a non-void function;
# `javac` refuses to compile it, and refuses code after a statement that
# always returns too. Both checks are conservative by construction: they
# recognise exactly the shapes this backend emits (an unconditional
# `return`, or an `if`/`else` whose *both* arms definitely return), which
# is a subset of what `javac`'s own flow analysis accepts -- so anything
# this backend calls "definitely returns" really does, even though it
# will reject some programs `javac` could technically prove return too
# (a `while` loop that can never fall through, for instance -- unreachable
# here anyway, since Pyking has no boolean literal to spell `while true:`
# with).

def _stmt_definitely_returns(s):
    match s:
        case JReturn():
            return True
        case JIf(_, _, then_body, else_body) if else_body is not None:
            return _definitely_returns(then_body) and _definitely_returns(else_body)
        case _:
            return False


def _definitely_returns(stmts):
    return bool(stmts) and _stmt_definitely_returns(stmts[-1])


def _check_reachable(stmts):
    for i, s in enumerate(stmts[:-1]):
        if _stmt_definitely_returns(s):
            _unsupported(
                _At(stmts[i + 1].info),
                "unreachable statement -- javac refuses code after a "
                "branch that always returns, where Python would simply "
                "never run it; remove it or restructure the function",
            )


def _build_print_expr(args):
    """One `JExpr` computing the line `print(args...)` writes: each
    argument formatted -- a boolean converted to Pyking's `True`/`False`
    through a conditional expression, since Java spells its own lowercase
    -- and joined with single spaces via Java's `+`, which already means
    string concatenation once either side is a `String`. `None` for no
    arguments at all."""
    if not args:
        return None
    parts = [
        JCond(a.info, a, JStr(a.info, "True"), JStr(a.info, "False"), STRING)
        if a.ctype == BOOL else a
        for a in args
    ]
    result = parts[0]
    for part in parts[1:]:
        result = JBinary(part.info, "+", result, JStr(part.info, " "), STRING)
        result = JBinary(part.info, "+", result, part, STRING)
    return result


def translate_program(stmts):
    """External entry point: a whole Pyking program as a `JProgram`."""
    translator = _Translator()
    scope = Scope({}, frozenset())
    functions = []
    main_body = []
    for s in stmts:
        if isinstance(s, SFunctionDef):
            func, scope = translator.function(s, scope)
            functions.append(func)
        else:
            translated, scope = translator.stmt(s, scope)
            main_body.append(translated)
    _check_reachable(main_body)
    return JProgram(functions, main_body)


# --- naming the class/file ---
#
# Java requires the public class in a file to share that file's name
# exactly, so the compiler cannot simply reuse the source's own stem the
# way the other targets do (see `src/pykboot.py`): `foo_bar.pyk` must
# become `FooBar.java`, class `FooBar`, not `foo_bar.java`. Only the
# *default* name goes through this conversion; an explicit `--output`
# path is trusted as-is, and its class name is just that file's stem.

_WORD_RE = re.compile(r"[A-Za-z0-9]+")


def default_class_name(stem):
    """The Java class (and file) name picked when nothing else says one:
    words split on anything that is not a letter or digit, each
    capitalised and run together -- `foo_bar` -> `FooBar`, `test1` ->
    `Test1`. Falls back to `Program` if the stem has no such word, and
    prefixes an underscore if the result would start with a digit (not a
    legal Java identifier otherwise)."""
    words = _WORD_RE.findall(stem)
    name = "".join(word[:1].upper() + word[1:] for word in words)
    if not name:
        name = "Program"
    if name[0].isdigit():
        name = "_" + name
    return name


# --- printer: Java AST -> Java source text ---

_PRECEDENCE = {
    "*": 13,
    "+": 12, "-": 12,
    "<": 10, "<=": 10, ">": 10, ">=": 10,
    "==": 9,
}
_UNARY_PRECEDENCE = 14
_CONDITIONAL_PRECEDENCE = 3
_CALL_PRECEDENCE = 16

_ESCAPES = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\t": "\\t", "\r": "\\r"}


def _quote(s):
    return '"' + "".join(_ESCAPES.get(ch, ch) for ch in s) + '"'


def _wrap(prec, min_prec, text):
    return f"({text})" if prec < min_prec else text


def pprint_java_expr(e, version, min_prec=0):
    match e:
        case JInt(_, v, _):
            return str(v)
        case JStr(_, s, _):
            return _quote(s)
        case JVar(_, name, _):
            return name
        case JUnary(_, op, operand, _):
            text = f"{op}{pprint_java_expr(operand, version, _UNARY_PRECEDENCE + 1)}"
            return _wrap(_UNARY_PRECEDENCE, min_prec, text)
        case JBinary(_, op, left, right, _):
            prec = _PRECEDENCE[op]
            text = (
                f"{pprint_java_expr(left, version, prec)} {op} "
                f"{pprint_java_expr(right, version, prec + 1)}"
            )
            return _wrap(prec, min_prec, text)
        case JCond(_, cond, then_expr, else_expr, _):
            text = (
                f"{pprint_java_expr(cond, version, _CONDITIONAL_PRECEDENCE + 1)} ? "
                f"{pprint_java_expr(then_expr, version, _CONDITIONAL_PRECEDENCE)} : "
                f"{pprint_java_expr(else_expr, version, _CONDITIONAL_PRECEDENCE)}"
            )
            return _wrap(_CONDITIONAL_PRECEDENCE, min_prec, text)
        case JCall(_, name, args, _):
            args_text = ", ".join(pprint_java_expr(a, version) for a in args)
            return f"{name}({args_text})"
        case JEquals(_, left, right, _):
            text = (
                f"{pprint_java_expr(left, version, _CALL_PRECEDENCE)}"
                f".equals({pprint_java_expr(right, version)})"
            )
            return _wrap(_CALL_PRECEDENCE, min_prec, text)
        case _:
            raise NotImplementedError(f"no printer for Java expression {e!r}")


def _local_type(jtype, version):
    """The keyword a local declaration uses for its type: `var` from
    java17 on, the spelled-out type in java8, which predates local-
    variable type inference."""
    if _FEATURES[version]["var_locals"]:
        return "var"
    return _JAVA_TYPES[jtype]


def pprint_java_stmt(s, version, level=1):
    pad = "    " * level
    match s:
        case JDecl(_, jtype, name, init, is_final):
            prefix = "final " if is_final else ""
            keyword = _local_type(jtype, version)
            return f"{pad}{prefix}{keyword} {name} = {pprint_java_expr(init, version)};"
        case JAssign(_, name, expr):
            return f"{pad}{name} = {pprint_java_expr(expr, version)};"
        case JExprStmt(_, expr):
            return f"{pad}{pprint_java_expr(expr, version)};"
        case JReturn(_, expr):
            return f"{pad}return {pprint_java_expr(expr, version)};"
        case JPrint(_, expr):
            if expr is None:
                return f"{pad}System.out.println();"
            return f"{pad}System.out.println({pprint_java_expr(expr, version)});"
        case JIf(_, cond, then_body, else_body):
            lines = [f"{pad}if ({pprint_java_expr(cond, version)}) {{"]
            lines.append(_emit_block(then_body, version, level + 1))
            while True:
                match else_body:
                    case [JIf(_, elif_cond, elif_body, else_body2)]:
                        lines.append(
                            f"{pad}}} else if "
                            f"({pprint_java_expr(elif_cond, version)}) {{"
                        )
                        lines.append(_emit_block(elif_body, version, level + 1))
                        else_body = else_body2
                    case None:
                        break
                    case _:
                        lines.append(f"{pad}}} else {{")
                        lines.append(_emit_block(else_body, version, level + 1))
                        break
            lines.append(f"{pad}}}")
            return "\n".join(lines)
        case JWhile(_, cond, body):
            return "\n".join([
                f"{pad}while ({pprint_java_expr(cond, version)}) {{",
                _emit_block(body, version, level + 1),
                f"{pad}}}",
            ])
        case _:
            raise NotImplementedError(f"no printer for Java statement {s!r}")


def _emit_block(stmts, version, level):
    return "\n".join(pprint_java_stmt(s, version, level) for s in stmts)


def _pprint_method(func, version, level=1):
    pad = "    " * level
    ret = _JAVA_TYPES[func.ret_type]
    params = ", ".join(
        f"final {_JAVA_TYPES[jtype]} {name}" for jtype, name in func.params
    )
    return "\n".join([
        f"{pad}private static {ret} {func.name}({params}) {{",
        _emit_block(func.body, version, level + 1),
        f"{pad}}}",
    ])


def _pprint_main(main_body, version, level=1):
    pad = "    " * level
    return "\n".join([
        f"{pad}public static void main(String[] args) {{",
        _emit_block(main_body, version, level + 1),
        f"{pad}}}",
    ])


def pprint_java_program(program, version, class_name, source="a Pyking program"):
    """The whole compilation unit: the header comment, the class holding
    every translated function as a `private static` method, and `main`
    holding the top-level statements."""
    if version not in VERSIONS:
        raise NotImplementedError(f"unknown Java version {version!r}")
    release = _FEATURES[version]["release"]

    parts = [
        f"// Generated from {source} by the Pyking compiler. Do not edit.",
        f"// Target: {version}. Compile with:  javac --release {release} "
        f"{class_name}.java",
        f"//         then run with:            java {class_name}",
        "",
        f"public final class {class_name} {{",
    ]
    for func in program.functions:
        parts += ["", _pprint_method(func, version)]
    parts += ["", _pprint_main(program.main_body, version)]
    parts += ["}", ""]
    return "\n".join(parts)
