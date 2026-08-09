"""The Java code-generation backend, serving java8, java17 and java21 --
structured like target_c.py: one translation, and a printer whose shape
never changes across versions, gated by a small per-version feature
table (_FEATURES). Like target_c.py, Java is statically typed and
Pyking is not, so this backend infers a type (Int, String, or Bool) for
every binding, parameter and function. Unlike C, javac requires every
non-void method to provably return on every path and rejects
unreachable code, so this backend checks both. See docs/target_java.md
for the version differences, the inference rules, and how each
construct compiles.

Data structures:
    UnsupportedError -- a construct this backend cannot compile, with
        the source position.
    JExpr / JStmt -- base classes for the Java AST; every JExpr also
        carries its inferred jtype.

Functions:
    translate_program(stmts, version) -- translates a whole program to
        JProgram.
    default_class_name(stem) -- the Java class name for a source stem.
    pprint_j_program(program, version, class_name) -- JProgram to Java
        source text.
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

# What each version's printer may use (docs/target_java.md, "The three
# targets"). var_locals gates JEP 286 local-variable type inference;
# release is the --release value the compile-with comment suggests.
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


# What each unsupported construct is called in an error message. Its
# own copy of target_c.py's list, so this backend depends on syntax.py
# alone.
_CONSTRUCT_NAMES = {
    "EList": "list literals",
    "ETuple": "tuples",
    "EListComp": "list comprehensions",
    "SFor": "`for` loops",
    "SMatch": "`match` statements",
    "SLetStmt": "value-form `if`/`match` bindings",
}


def _unsupported(node, message):
    """Raises UnsupportedError at node, naming message (a construct or
    an AST class name) via _CONSTRUCT_NAMES. Expr|Stmt -> String -> ()"""
    raise UnsupportedError(node.info, _CONSTRUCT_NAMES.get(message, message))


# --- types ---
#
# The three kinds of value a Pyking program in this subset can hold.

INT = "Int"
BOOL = "Bool"
STRING = "String"

# Pyking's unit type (), spelled void in Java.
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
    """A translated program. Fields: functions, [JFunc]; main_body,
    [JStmt]."""
    functions: list
    main_body: list


# --- scope ---
#
# Java blocks are lexical scopes, as Pyking's are. Rebinding gets a fresh
# local, since Java cannot declare one name twice in a block and a
# rebinding may hold a different type.


@dataclass(frozen=True)
class Scope:
    """The names in scope during translation. Fields: outside, {String}
    (bound in the Pyking program but not reachable here -- this
    backend's methods have no closures); names, {String: (String,
    String)} (Pyking name -> (Java name, jtype)); block, {String} (names
    bound by the innermost block)."""
    outside: frozenset
    names: dict
    block: frozenset


def _block_scope(scope):
    """The scope for a nested block: sees outside and names; drops
    block. Scope -> Scope"""
    return Scope(scope.outside, scope.names, frozenset())


@dataclass(frozen=True)
class _At:
    """Carries an Info for _unsupported when the offending thing is a
    name rather than a node."""
    info: Info


def _lookup(name, scope, info):
    """The (Java name, jtype) a Pyking name reads as; raises
    UnsupportedError for a name out of this method's reach or with no
    Java representation. String -> Scope -> Info -> (String, String)"""
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


# Legal Pyking identifiers that are reserved in Java (keywords, literals,
# and the names generated code leans on). See docs/target_java.md,
# "Names that are keywords in Java".
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
    """name2, name3, ... -- the first not already used. String -> Scope
    -> String"""
    taken = set(scope.names) | {java_name for java_name, _ in scope.names.values()}
    n = 2
    while f"{name}{n}" in taken or f"{name}{n}" in RESERVED:
        n += 1
    return f"{name}{n}"


def _bind(name, jtype, scope):
    """Binds a Pyking name at jtype, returning (java_name,
    extended_scope). String -> String -> Scope -> (String, Scope)"""
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
    """Accumulates what the whole-program walk needs across functions:
    signatures, which have been defined. Fields: signatures, {String:
    (String, [String], String)} (Pyking name -> (Java name, param
    jtypes, return jtype)); declared, {String: String} (Pyking name ->
    Java name, from the declaration pass); defined, {String} (functions
    whose body has been translated); called_early, {String} (functions
    called before that)."""

    def __init__(self):
        self.signatures = {}
        self.declared = {}
        self.defined = set()
        self.called_early = set()

    # -- expressions --

    def is_function_value(self, name, scope):
        """Whether name here means a def itself rather than a value.
        String -> Scope -> Bool"""
        if name not in self.signatures:
            return False
        bound = scope.names.get(name)
        return bound is None or bound[0] == self.signatures[name][0]

    def expr(self, e, scope, allow_unit=False):
        """Translates one expression. allow_unit permits a call to a
        void method, meaningful only as an expression statement.
        Expr -> Scope -> Bool -> JExpr"""
        match e:
            case EInt(info, v):
                return JInt(info, v)
            case EString(info, s):
                return JStr(info, s)
            case EBool(info, v):
                return JBool(info, v)
            case EVar(info, name) if self.is_function_value(name, scope):
                # A def's own name used as a value (docs/target_java.md,
                # "A function used as a value").
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
                # docs/target_java.md, "/".
                _unsupported(
                    e,
                    "`/` is true division in Pyking and truncating integer "
                    "division in Java; matching it needs a floating-point "
                    "type this backend does not have yet",
                )
            case EAdd(info, l, r):
                left, right = self.expr(l, scope), self.expr(r, scope)
                if left.ctype == STRING and right.ctype == STRING:
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
                    self.called_early.add(name)
                java_name, param_types, ret = self.signatures[name]
                if len(args) != len(param_types):
                    _unsupported(e, f"`{name}` takes {len(param_types)} argument(s)")
                if ret == UNIT and not allow_unit:
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
        """Raises UnsupportedError if node's ctype is not ctype. JExpr ->
        String -> String -> ()"""
        if node.ctype != ctype:
            _unsupported(
                _At(node.info),
                f"{what} needs {ctype} operands here, not {node.ctype}",
            )

    # -- statements --

    def stmts(self, stmts, scope):
        """Translates a statement sequence, threading the scope through
        it; raises UnsupportedError for code after an unconditional
        return (docs/target_java.md, "Unreachable code after a
        return"). [Stmt] -> Scope -> ([JStmt], Scope)"""
        out = []
        for s in stmts:
            translated, scope = self.stmt(s, scope)
            out.append(translated)
        _check_reachable(out)
        return out, scope

    def tail_stmts(self, stmts, scope):
        """Translates a statement list whose last statement is in tail
        position (PYKING.md, "Tail position"). [Stmt] -> Scope ->
        [JStmt]"""
        if not stmts:
            return []
        body, tail_scope = self.stmts(stmts[:-1], scope)
        return body + self.tail_stmt(stmts[-1], tail_scope)

    def tail_stmt(self, s, scope):
        """The last statement of a body in tail position, as a list of
        Java statements. Stmt -> Scope -> [JStmt]"""
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
        """Translates a nested block; its bindings do not escape.
        [Stmt] -> Scope -> [JStmt]"""
        translated, _ = self.stmts(stmts, _block_scope(scope))
        return translated

    def stmt(self, s, scope):
        """Translates one statement, returning it with the scope it
        leaves behind. Stmt -> Scope -> (JStmt, Scope)"""
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
                return self.tail_stmt(stmt, scope)[0], scope

            case SReturn(info, expr):
                return JReturn(info, self.expr(expr, scope)), scope

            case SExprStmt(info, ECall(_, EVar(_, name), args)) if (
                runtime_interface.lookup(name)
            ):
                translated_args = [self.expr(a, scope) for a in args]
                return JPrint(info, _build_print_expr(translated_args)), scope

            case SExprStmt(info, expr):
                # docs/target_java.md, "An expression statement that is
                # not a call".
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
        """Registers every top-level def's signature (return type
        provisional: its annotation, or Int) before any body is
        translated, enabling forward references and mutual recursion
        (docs/target_java.md, "Forward references and mutual
        recursion"). [Stmt] -> Scope -> Scope"""
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
        """Translates a def; its signature is already registered
        (declare_functions). SFunctionDef -> Scope -> (JFunc, Scope)"""
        param_types = [_param_type(func, p) for p in func.params]
        if func.name in self.declared:
            java_name = self.declared[func.name]
        else:
            java_name, scope = _bind(func.name, INT, scope)
        provisional = _annotated_type(func.return_type) or INT
        self.signatures[func.name] = (java_name, param_types, provisional)

        # A function body starts from nothing but its own parameters; no
        # closures, so outside remembers what it cannot see (_lookup).
        body_scope = Scope(frozenset(scope.names), {}, frozenset())
        params = []
        for param, jtype in zip(func.params, param_types):
            java_param, body_scope = _bind(param.name, jtype, body_scope)
            params.append((jtype, java_param))

        if func.expr is not None:
            value = self.expr(func.expr, body_scope)
            body = [JReturn(value.info, value)]
        else:
            body = self.tail_stmts(func.body, body_scope)

        returned = _return_types(body)
        recursive = _calls(body, java_name)
        if len(returned) > 1 or (returned and returned != {provisional} and recursive):
            if recursive:
                _unsupported(
                    func,
                    f"`{func.name}` calls itself and does not return Int; a "
                    "recursive function's return type is assumed Int unless "
                    "annotated, so annotate it (`-> String`, `-> Bool`)",
                )
            _unsupported(func, "a function returning more than one type")
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
    """Whether e performs a call anywhere inside it. Expr -> Bool"""
    if isinstance(e, ECall):
        return True
    return any(
        _contains_call(child)
        for field in fields(e)
        for child in _children(getattr(e, field.name))
    )


def _children(value):
    """The Expr nodes directly in value (itself, or its list elements).
    Expr|[Expr]|Any -> [Expr]"""
    if isinstance(value, Expr):
        return [value]
    if isinstance(value, list):
        return [v for v in value if isinstance(v, Expr)]
    return []


def _param_type(func, param):
    """A parameter's type: its annotation when Java can represent it,
    else what the body's use of it suggests, else Int
    (docs/target_java.md, "How types are inferred"). SFunctionDef ->
    Param -> String"""
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
    """Every jtype returned anywhere in body. [JStmt] -> {String}"""
    return {n.expr.ctype for n in _walk_java(body) if isinstance(n, JReturn)}


def _calls(body, java_name):
    """Whether body calls the Java method named java_name. [JStmt] ->
    String -> Bool"""
    return any(
        isinstance(n, JCall) and n.name == java_name for n in _walk_java(body)
    )


# --- definite return / reachability ---
#
# Conservative by construction (docs/target_java.md, "A function that
# does not return on every path"): recognises an unconditional return,
# or an if/else whose both arms definitely return, a subset of what
# javac's own flow analysis accepts.

def _stmt_definitely_returns(s):
    """Whether s, as the last statement of a block, guarantees a return.
    Stmt -> Bool"""
    match s:
        case JReturn():
            return True
        case JIf(_, _, then_body, else_body) if else_body is not None:
            return _definitely_returns(then_body) and _definitely_returns(else_body)
        case _:
            return False


def _definitely_returns(stmts):
    """Whether stmts guarantees a return on every path. [JStmt] -> Bool"""
    return bool(stmts) and _stmt_definitely_returns(stmts[-1])


def _check_reachable(stmts):
    """Raises UnsupportedError at the first statement after one that
    definitely returns. [JStmt] -> ()"""
    for i, s in enumerate(stmts[:-1]):
        if _stmt_definitely_returns(s):
            _unsupported(
                _At(stmts[i + 1].info),
                "unreachable statement -- javac refuses code after a "
                "branch that always returns, where Python would simply "
                "never run it; remove it or restructure the function",
            )


def _build_print_expr(args):
    """One JExpr computing the line print(args...) writes, joined with
    single spaces via Java's own +; None for no arguments. [JExpr] ->
    JExpr?"""
    if not args:
        return None
    result = args[0]
    for part in args[1:]:
        result = JBinary(part.info, "+", result, JStr(part.info, " "), STRING)
        result = JBinary(part.info, "+", result, part, STRING)
    return result


def translate_program(stmts):
    """A whole Pyking program as a JProgram. [Stmt] -> JProgram"""
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
# Only the default name goes through this conversion; an explicit
# --output path is trusted as-is. See docs/target_java.md, "Naming the
# class".

_WORD_RE = re.compile(r"[A-Za-z0-9]+")


def default_class_name(stem):
    """The Java class (and file) name picked when nothing else says one,
    e.g. foo_bar -> FooBar. String -> String"""
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
    """s as a double-quoted Java string literal. String -> String"""
    return '"' + "".join(_ESCAPES.get(ch, ch) for ch in s) + '"'


def _wrap(prec, min_prec, text):
    """text, parenthesized if prec is below min_prec. Int -> Int ->
    String -> String"""
    return f"({text})" if prec < min_prec else text


def pprint_java_expr(e, version, min_prec=0):
    """e as Java source text. JExpr -> String -> Int -> String"""
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
    """The keyword a local declaration uses for its type: var from
    java17 on, else jtype's Java spelling. String -> String -> String"""
    if _FEATURES[version]["var_locals"]:
        return "var"
    return _JAVA_TYPES[jtype]


def pprint_java_stmt(s, version, level=1):
    """s as Java source text, indented to level. JStmt -> String -> Int
    -> String"""
    pad = "    " * level
    match s:
        case JDecl(_, jtype, name, init, is_final):
            prefix = "final " if is_final else ""
            keyword = _local_type(jtype, version)
            return f"{pad}{prefix}{keyword} {name} = {pprint_java_expr(init, version)};"
        case JAssign(_, name, expr):
            return f"{pad}{name} = {pprint_java_expr(expr, version)};"
        case JNoEffect(_, source):
            # docs/target_java.md, "An expression statement that is not
            # a call".
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
    """A block's statements, indented to level. [JStmt] -> String -> Int
    -> String"""
    return "\n".join(pprint_java_stmt(s, version, level) for s in stmts)


def _pprint_method(func, version, level=1):
    """func as a private static method. JFunc -> String -> Int ->
    String"""
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
    """main_body as the public static void main method. [JStmt] ->
    String -> Int -> String"""
    pad = "    " * level
    return "\n".join([
        f"{pad}public static void main(String[] args) {{",
        _emit_block(main_body, version, level + 1),
        f"{pad}}}",
    ])


def pprint_java_program(program, version, class_name, source="a Pyking program"):
    """The whole compilation unit: the class holding every function as a
    private static method, and main. JProgram -> String -> String ->
    String -> String"""
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
