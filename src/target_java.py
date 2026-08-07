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
exactly (`default_class_name`; `src/pyk.py` derives the class name
from an explicit `--output` instead, when one is given). Top-level Pyking
statements become the body of `public static void main`; `def`s become
`private static` methods.
"""

import re
from dataclasses import dataclass, fields

from lexer import Info
import runtime_interface
from syntax import (
    pprint_expr,
    Expr, EInt, EString, EBool, EVar,
    EAdd, ESub, EMul, EDiv, ENeg,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EIf,
    SLet, SVar, SMutate, SReturn, SReturnStmt, SExprStmt, SWhile, SIf, SFunctionDef,
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

# Pyking's unit type `()`. A function that produces no value has this as
# its return type -- `print` yields unit, and so does a body whose tail is
# a loop or a binding -- and Java spells that `void`. Without it such a
# function would be typed `int` and rejected by the definitely-returns
# check below, even though it is perfectly well-formed Pyking.
UNIT = "Unit"

_JAVA_TYPES = {INT: "int", BOOL: "boolean", STRING: "String", UNIT: "void"}

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
# check operators and to pick `.equals()` over `==`.

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
class JBool(JExpr):
    info: Info
    value: bool
    ctype: str = BOOL


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
class JNoEffect(JStmt):     # // a Pyking statement with nothing to run
    info: Info
    source: str


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
    # `outside` is what is in scope in the Pyking program but *not*
    # reachable from here -- the bindings around a function, which this
    # backend's functions cannot see. Kept so that reading one can say
    # why rather than claiming the name does not exist.
    outside: frozenset
    names: dict              # Pyking name -> (Java name, type)
    block: frozenset


def _block_scope(scope):
    return Scope(scope.outside, scope.names, frozenset())


@dataclass(frozen=True)
class _At:
    """Carries an `Info` for `_unsupported` when the offending thing is a
    name rather than a node."""
    info: Info


def _lookup(name, scope, info):
    if name not in scope.names:
        if name in scope.outside:
            _unsupported(
                _At(info),
                f"'{name}' is bound outside this function -- "
                "these are static methods, with no closure over the code around them: a method reads its parameters and calls other methods, nothing else",
            )
        _unsupported(
            _At(info), f"'{name}' is not a value this backend can compile"
        )
    return scope.names[name]


# Names that are legal Pyking identifiers but reserved words in Java, so
# a program with `def static(n):` would otherwise compile to code that
# will not parse. Covers the keywords (including the reserved-but-unused
# `const`/`goto`), the literals, and the few names generated code leans
# on -- `String`, `System`, `args` and `main` are not keywords, but a
# Pyking function shadowing one would break the file just as thoroughly.
RESERVED = frozenset("""
abstract assert boolean break byte case catch char class const continue
default do double else enum extends final finally float for goto if
implements import instanceof int interface long native new package
private protected public return short static strictfp super switch
synchronized this throw throws transient try void volatile while
true false null var record sealed permits yield
String System Object Integer Boolean Math args main
""".split())


def _fresh_java_name(name, scope):
    taken = set(scope.names) | {java_name for java_name, _ in scope.names.values()}
    n = 2
    while f"{name}{n}" in taken or f"{name}{n}" in RESERVED:
        n += 1
    return f"{name}{n}"


def _bind(name, jtype, scope):
    java_name = name
    if (
        name in RESERVED
        or name in scope.names
        or any(name == n for n, _ in scope.names.values())
    ):
        java_name = _fresh_java_name(name, scope)
    return java_name, Scope(
        scope.outside,
        {**scope.names, name: (java_name, jtype)},
        scope.block | {name},
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
        self.declared = {}      # Pyking name -> Java name, from the declaration pass
        self.defined = set()    # functions whose body has been translated
        self.called_early = set()   # ... and those called before that happened

    # -- expressions --

    def is_function_value(self, name, scope):
        """Whether `name` here means a `def` itself rather than a value.

        A function's name is bound in the scope as well as in
        `signatures`, so the two are compared: if what the name resolves
        to is the function's own generated name, this *is* the function;
        if a parameter or binding has shadowed it, it is not."""
        if name not in self.signatures:
            return False
        bound = scope.names.get(name)
        return bound is None or bound[0] == self.signatures[name][0]

    def expr(self, e, scope, allow_unit=False):
        """`allow_unit` permits a call to a unit-returning (`void`)
        method, which is meaningful only as an expression statement --
        everywhere else there is no value to use."""
        match e:
            case EInt(info, v):
                return JInt(info, v)
            case EString(info, s):
                return JStr(info, s)
            case EBool(info, v):
                return JBool(info, v)
            case EVar(info, name) if self.is_function_value(name, scope):
                # A `def`'s own name, used as a value rather than called.
                # Emitting it would produce something that does not
                # compile -- a bare method name in Java, a function
                # pointer assigned to an `int` in C -- so it is refused
                # here with a position, like every other construct this
                # backend cannot represent.
                _unsupported(
                    _At(info),
                    f"`{name}` is a function used as a value -- "
                    "these are static methods, not values: only a call can name one",
                )
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
                if name not in self.defined:
                    # Typed from the signature registered ahead of the
                    # body; `function` checks that guess when the body
                    # arrives.
                    self.called_early.add(name)
                java_name, param_types, ret = self.signatures[name]
                if len(args) != len(param_types):
                    _unsupported(e, f"`{name}` takes {len(param_types)} argument(s)")
                if ret == UNIT and not allow_unit:
                    # A `void` call has no value to use. Only an
                    # expression *statement* may call one, which is what
                    # `allow_unit` marks.
                    _unsupported(
                        e,
                        f"`{name}` produces no value (it returns unit), so it "
                        "cannot be used as one; call it as a statement of "
                        "its own",
                    )
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

    def tail_stmts(self, stmts, scope):
        """Translates a statement list whose last statement is in **tail
        position** -- a function body, or a branch of one that is itself
        in tail position -- so the value it produces becomes the
        method's return value. Mirrors `_translate_tail_block` in
        `target_python.py`; see PYKING.md's "Tail position"."""
        if not stmts:
            return []
        body, tail_scope = self.stmts(stmts[:-1], scope)
        return body + self.tail_stmt(stmts[-1], tail_scope)

    def tail_stmt(self, s, scope):
        """The last statement of a body in tail position, as a list of
        Java statements: an expression becomes the returned value, an
        `if` pushes the rule into its branches, and anything else -- a
        loop, a binding, a `print` (which yields unit) -- translates
        normally."""
        match s:
            case SExprStmt(_, ECall(_, EVar(_, name), _)) if (
                runtime_interface.lookup(name) is not None
            ):
                translated, _ = self.stmt(s, scope)
                return [translated]
            case SExprStmt(info, expr):
                return [JReturn(info, self.expr(expr, scope))]
            case SIf(info, cond, then_body, else_body):
                condition = self.expr(cond, scope)
                self._require(condition, BOOL, "an `if` condition")
                then_branch = self.tail_stmts(then_body, _block_scope(scope))
                else_branch = (
                    None
                    if else_body is None
                    else self.tail_stmts(else_body, _block_scope(scope))
                )
                return [JIf(info, condition, then_branch, else_branch)]
            case _:
                translated, _ = self.stmt(s, scope)
                return [translated]

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

            case SReturnStmt(_, stmt):
                # `return if c:` -- the same push-down as a tail-position
                # `if`, written explicitly so it also works before the
                # end of the body.
                return self.tail_stmt(stmt, scope)[0], scope

            case SReturn(info, expr):
                return JReturn(info, self.expr(expr, scope)), scope

            case SExprStmt(info, ECall(_, EVar(_, name), args)) if (
                runtime_interface.lookup(name)
            ):
                translated_args = [self.expr(a, scope) for a in args]
                return JPrint(info, _build_print_expr(translated_args)), scope

            case SExprStmt(info, expr):
                # Java is stricter than Pyking about what may stand as a
                # statement: a method call may, `i + 1;` may not ("not a
                # statement"). A Pyking expression statement discards its
                # value, so one that calls nothing has no effect at all
                # and is simply not emitted; one that *is* a call is a
                # legal Java statement; anything in between -- a call
                # buried in an expression, `f(1) + 2` -- has an effect
                # Java cannot express in statement position, and is
                # refused rather than dropped.
                match expr:
                    case ECall():
                        return (
                            JExprStmt(info, self.expr(expr, scope, allow_unit=True)),
                            scope,
                        )
                if _contains_call(expr):
                    _unsupported(
                        s,
                        "an expression statement that is not itself a call: Java "
                        "allows only a call, an assignment or an increment to "
                        "stand as a statement, and dropping this one would skip "
                        "the call inside it",
                    )
                return JNoEffect(info, pprint_expr(expr)), scope

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

    def declare_functions(self, stmts, scope):
        """Registers every top-level `def`'s signature before any body is
        translated, so a call may name a function written further down --
        forward references and mutual recursion (see PYKING.md, "Names
        and scoping"). Java itself does not care about order: these are
        static methods of one class, so nothing has to be emitted ahead
        of anything else, unlike C.

        The return type registered here is *provisional* -- the
        annotation, or `Int` for an unannotated function, since only its
        translated body can say otherwise. `function` checks that
        assumption once the body is in, which is why calls made before
        that point are remembered in `called_early`."""
        for s in stmts:
            if isinstance(s, SFunctionDef):
                java_name, scope = _bind(s.name, INT, scope)
                self.signatures[s.name] = (
                    java_name,
                    [_param_type(s, p) for p in s.params],
                    _annotated_type(s.return_type) or INT,
                )
                self.declared[s.name] = java_name
        return scope

    def function(self, func, scope):
        """Translates a `def`. Its signature is already registered (see
        `declare_functions`), which is what lets the body call itself,
        its siblings, and functions defined below it."""
        param_types = [_param_type(func, p) for p in func.params]
        if func.name in self.declared:
            java_name = self.declared[func.name]
        else:
            java_name, scope = _bind(func.name, INT, scope)
        provisional = _annotated_type(func.return_type) or INT
        self.signatures[func.name] = (java_name, param_types, provisional)

        # A function body starts from *nothing*: its parameters bind
        # into it below, and other functions are reached through
        # `self.signatures`. What it cannot see is the bindings around
        # it -- there are no closures here -- and `outside` remembers
        # those names so reading one says why (see `_lookup`).
        body_scope = Scope(frozenset(scope.names), {}, frozenset())
        params = []
        for param, jtype in zip(func.params, param_types):
            java_param, body_scope = _bind(param.name, jtype, body_scope)
            params.append((jtype, java_param))

        if func.expr is not None:
            value = self.expr(func.expr, body_scope)
            body = [JReturn(value.info, value)]
        else:
            # The body's last statement is in tail position: whatever
            # value it produces is the function's result.
            body = self.tail_stmts(func.body, body_scope)

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
        # No `return` anywhere means the function produces no value:
        # that is unit, i.e. `void`, not the provisional `Int`.
        actual = returned.pop() if returned else UNIT
        self.signatures[func.name] = (java_name, param_types, actual)
        if func.name in self.called_early and actual != provisional:
            _unsupported(
                func,
                f"`{func.name}` is called before it is defined and does not "
                f"return {provisional}; a call written above a `def` is typed "
                "from the annotation, or Int without one, so annotate the "
                "return type (`-> String`, `-> Bool`)",
            )
        self.defined.add(func.name)

        if actual != UNIT and not _definitely_returns(body):
            _unsupported(
                func,
                f"`{func.name}` does not return a value on every path; "
                "unlike Python, javac refuses to compile a method that can "
                "fall off the end instead of returning, so make sure every "
                "branch ends in `return`",
            )

        return JFunc(func.info, java_name, params, body, actual), scope


def _contains_call(e):
    """Whether an expression performs a call anywhere inside it -- which
    is what decides whether dropping it would lose an effect."""
    if isinstance(e, ECall):
        return True
    return any(
        _contains_call(child)
        for field in fields(e)
        for child in _children(getattr(e, field.name))
    )


def _children(value):
    if isinstance(value, Expr):
        return [value]
    if isinstance(value, list):
        return [v for v in value if isinstance(v, Expr)]
    return []


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
    argument joined with single spaces via Java's `+`, which already means
    string concatenation once either side is a `String` -- and Java's own
    boolean-to-string conversion already spells `true`/`false`, exactly
    matching Pyking's, so a boolean argument needs no special handling
    (unlike `target_c.py`, where the two standards disagree with Pyking
    and with each other). `None` for no arguments at all."""
    if not args:
        return None
    result = args[0]
    for part in args[1:]:
        result = JBinary(part.info, "+", result, JStr(part.info, " "), STRING)
        result = JBinary(part.info, "+", result, part, STRING)
    return result


def translate_program(stmts):
    """External entry point: a whole Pyking program as a `JProgram`."""
    translator = _Translator()
    scope = Scope(frozenset(), {}, frozenset())
    scope = translator.declare_functions(stmts, scope)
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
# way the other targets do (see `src/pyk.py`): `foo_bar.pyk` must
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
        case JBool(_, v, _):
            return "true" if v else "false"
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
        case JNoEffect(_, source):
            # Pyking allows any expression to stand as a statement, and
            # discards its value; Java allows only a call, an assignment
            # or an increment. One that calls nothing has no effect to
            # keep, so it is left as a comment rather than emitted as
            # code javac would refuse.
            return f"{pad}// {source};   (no effect: value discarded)"
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
