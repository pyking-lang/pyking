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
    EAdd, EConcat, ESub, EMul, EDiv, ENeg,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EIf, ETuple,
    SLet, SLetStmt, SVar, SMutate, SReturn, SReturnStmt, SExprStmt, SWhile, SIf,
    SLoop, SBreak, SContinue, SFunctionDef, SMatch,
    PInt, PString, PBool, PWildcard, PCapture, PText,
    TargetName, TargetTuple, TInt, TString, TBool,
    TList, TTuple, TOr, TFunction, TVar, TForall,
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


def _reject_type_variables(node):
    """Refuses a def whose annotations name a type variable. Java
    infers one concrete type per function, so a type the caller chooses
    has nothing here to become -- and guessing `Int` would compile a
    call at any other type into code that is quietly wrong.
    SFunctionDef -> ()"""
    for annotation in [p.type for p in node.params] + [node.return_type]:
        if annotation is not None and _mentions_type_variable(annotation):
            _unsupported(
                _At(annotation.info),
                "a type variable -- Java needs one concrete type per "
                "function, and this backend infers no polymorphism",
            )


def _mentions_type_variable(annotation):
    """Whether a written type names a type variable anywhere inside it.
    Type -> Bool"""
    match annotation:
        case TVar() | TForall():
            return True
        case TList(_, element, _):
            return _mentions_type_variable(element)
        case TTuple(_, elements, _) | TOr(_, elements, _):
            return any(_mentions_type_variable(e) for e in elements)
        case TFunction(_, params, result, _, _, _):
            return (any(_mentions_type_variable(p) for p in params)
                    or _mentions_type_variable(result))
    return False


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
class JLoop(JStmt):         # while (true) { body }
    info: Info
    body: list


@dataclass(frozen=True)
class JBreak(JStmt):        # break;
    info: Info


@dataclass(frozen=True)
class JContinue(JStmt):     # continue;
    info: Info


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
    bound by the innermost block); taken, {String} (every Java name
    already spoken for here, which `names` cannot say: it holds only
    each Pyking name's *current* Java name, so a name rebound three
    times would otherwise offer the second one's spelling back to the
    fourth, and javac refuses a local declared twice)."""
    outside: frozenset
    names: dict
    block: frozenset
    taken: frozenset = frozenset()


def _block_scope(scope):
    """The scope for a nested block: sees outside and names; drops
    block. Scope -> Scope"""
    return Scope(scope.outside, scope.names, frozenset(), scope.taken)


def _reserve(names, scope):
    """scope with these Java names spoken for, but meaning nothing:
    what a loop does with its accumulator, which is declared in this
    block and in scope only in the loop's own body.
    [String] -> Scope -> Scope"""
    return Scope(scope.outside, scope.names, scope.block, scope.taken | set(names))


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
    taken = (
        set(scope.names)
        | {java_name for java_name, _ in scope.names.values()}
        | set(scope.taken)
    )
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
        or name in scope.taken
    ):
        java_name = _fresh_java_name(name, scope)
    return java_name, Scope(
        scope.outside,
        {**scope.names, name: (java_name, jtype)},
        scope.block | {name},
        scope.taken | {java_name},
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
        # The enclosing `loop`s, innermost last (see _Loop), and how
        # many temporaries have been named so far.
        self.loops = []
        self.temporaries = 0

    def temporary(self):
        """A number no temporary has used yet. () -> Int"""
        self.temporaries += 1
        return self.temporaries

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
                self._require(left, INT, "`+`")
                self._require(right, INT, "`+`")
                return JBinary(info, "+", left, right, INT)
            case EConcat(info, l, r):
                # Java spells concatenation `+` too, so the two Pyking
                # operators differ here only in the type they demand.
                left, right = self.expr(l, scope), self.expr(r, scope)
                self._require(left, STRING, "`++`")
                self._require(right, STRING, "`++`")
                return JBinary(info, "+", left, right, STRING)
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
            out.extend(_as_stmts(translated))
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
            case SMatch():
                built, _ = self.match_chain(
                    s, scope, lambda body, inner: self.tail_stmts(body, inner)
                )
                return built
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
            case SLoop(info):
                # A function ending in a loop returns what the loop
                # produced: what it broke with. A loop nothing breaks
                # out of never gets there, and javac refuses a statement
                # that cannot be reached.
                java_stmts, value, _ = self.loop(s, scope)
                if not _breaks_out(java_stmts[-1].body):
                    return java_stmts
                if value is None:
                    _breakable(s)
                return java_stmts + [JReturn(info, value)]
            case _:
                translated, _ = self.stmt(s, scope)
                return _as_stmts(translated)

    def loop(self, s, scope):
        """Translates a loop into `while (true)` over one local per
        accumulator slot (docs/target_java.md, "loop"): the initializer
        declares them, every tail of the body assigns the next turn's
        values, and a `break`/`continue` with an operand assigns before
        it jumps. Returns the statements, the expression holding the
        loop's value afterwards, and the scope: the accumulators are in
        scope only in the loop's own body, but their declarations stand
        in the block around it, so those Java names stay spoken for
        there. SLoop -> Scope -> ([JStmt], JExpr?, Scope)"""
        info = s.info
        if s.target is None:
            _unsupported(
                s,
                "a `loop` with no accumulator -- Java has no value to give "
                "it, so write `loop x = 0:` and break with what you want",
            )
        names = _slot_names(s.target)
        if names is None:
            _unsupported(s, "a loop accumulator that is not one name per slot")
        values = [self.expr(e, scope) for e in _slot_values(s.init, len(names), s)]

        body_scope = _block_scope(scope)
        slots = []
        for name, value in zip(names, values):
            java_name, body_scope = _bind(name, value.ctype, body_scope)
            slots.append((java_name, value.ctype))
        setup = [
            JDecl(info, value.ctype, java_name, value, False)
            for (java_name, _), value in zip(slots, values)
        ]

        # A loop is worth what it breaks with, which is not always what
        # it carries -- so a `break` with an operand needs a local of
        # its own to leave the answer in.
        result = None
        first_value = _first_break_value(s.body)
        if len(slots) > 1 and _breaks_bare(s.body):
            _breakable(s)
        if first_value is not None:
            result_type = self.expr(first_value, body_scope).ctype
            result_name, _ = _bind(
                _result_name(s.target), result_type, _block_scope(scope)
            )
            result = (result_name, result_type)
            setup.append(
                JDecl(info, result_type, result_name, _zero(info, result_type), False)
            )

        self.loops.append(_Loop(slots, result))
        try:
            body = self.loop_block(s.body, body_scope)
        finally:
            self.loops.pop()
        taken = [java_name for java_name, _ in slots] + (
            [result[0]] if result else []
        )
        value = (
            JVar(info, result[0], result[1]) if result
            else JVar(info, slots[0][0], slots[0][1])
        )
        if result is None and len(slots) > 1:
            value = None
        return setup + [JLoop(info, body)], value, _reserve(taken, scope)

    def accumulate(self, expr, scope, node):
        """The statements that give the innermost loop its next values.
        With more than one slot they go through locals, so a slot that
        reads another sees the turn it is still on.
        Expr -> Scope -> Stmt -> [JStmt]"""
        loop = self.loops[-1]
        values = [
            self.expr(e, scope) for e in _slot_values(expr, len(loop.slots), node)
        ]
        for (java_name, jtype), value in zip(loop.slots, values):
            if value.ctype != jtype:
                _unsupported(
                    node,
                    f"this loop carries {jtype} in `{java_name}`, so it "
                    f"cannot go on with {value.ctype} in Java",
                )
        if len(loop.slots) == 1:
            return [JAssign(node.info, loop.slots[0][0], values[0])]
        turn = self.temporary()
        temporaries = [
            (f"{java_name}_next{turn}", jtype) for java_name, jtype in loop.slots
        ]
        return [
            JDecl(node.info, jtype, name, value, True)
            for (name, jtype), value in zip(temporaries, values)
        ] + [
            JAssign(node.info, java_name, JVar(node.info, name, jtype))
            for (java_name, _), (name, jtype) in zip(loop.slots, temporaries)
        ]

    def leave(self, expr, scope, node):
        """The statements that give the innermost loop its value and
        leave it. Expr? -> Scope -> Stmt -> [JStmt]"""
        loop = self.loops[-1]
        if loop.result is None:
            return [JBreak(node.info)]
        name, jtype = loop.result
        value = (
            JVar(node.info, loop.slots[0][0], loop.slots[0][1]) if expr is None
            else self.expr(expr, scope)
        )
        if value.ctype != jtype:
            _unsupported(
                node,
                f"this loop leaves {jtype} one way and {value.ctype} "
                f"another; Java needs one type for the answer",
            )
        return [JAssign(node.info, name, value), JBreak(node.info)]

    def loop_block(self, stmts, scope):
        """Translates a loop body: whatever a path ends in is the next
        turn's value, so every tail becomes an assignment to the
        accumulator -- except a `break`/`continue`, which has already
        said what happens next. [Stmt] -> Scope -> [JStmt]"""
        if not stmts:
            return []
        body, scope = self.stmts(stmts[:-1], scope)
        return body + self.loop_tail(stmts[-1], scope)

    def loop_tail(self, s, scope):
        """The last statement of a loop body, or of one branch of one.
        Stmt -> Scope -> [JStmt]"""
        match s:
            case SExprStmt(_, expr):
                return self.accumulate(expr, scope, s)
            case SIf(info, cond, then_body, else_body):
                condition = self.expr(cond, scope)
                self._require(condition, BOOL, "an `if` condition")
                if else_body is None:
                    _unsupported(
                        s,
                        "an `if` with no `else` as the last statement of a "
                        "loop body -- there would be a turn with no next "
                        "value, and Java has no unit to give it",
                    )
                return [JIf(
                    info,
                    condition,
                    self.loop_block(then_body, _block_scope(scope)),
                    self.loop_block(else_body, _block_scope(scope)),
                )]
            case SBreak() | SContinue() | SReturn() | SReturnStmt():
                # Each of these says by itself what happens next: two
                # leave the loop, one leaves the whole function.
                translated, _ = self.stmt(s, scope)
                return _as_stmts(translated)
            case _:
                _unsupported(
                    s,
                    "a loop body ending in something with no value -- every "
                    "turn has to say what the next one carries",
                )

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

            case SLetStmt(info, TargetName(_, name), SLoop() as loop):
                # `x = loop ...` -- the loop's value is the accumulator
                # it stopped with, so the binding is one declaration
                # after it.
                java_stmts, value, scope = self.loop(loop, scope)
                if value is None:
                    _breakable(loop)
                java_name, scope = _bind(name, value.ctype, scope)
                return java_stmts + [
                    JDecl(info, value.ctype, java_name, value, True)
                ], scope

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
                # A loop answers with several statements (the
                # accumulator, the loop, the return).
                return self.tail_stmt(stmt, scope), scope

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

            case SLoop():
                java_stmts, _, scope = self.loop(s, scope)
                return java_stmts, scope

            case SBreak(_, expr):
                if not self.loops:
                    _unsupported(s, "a `break` outside a loop")
                return self.leave(expr, scope, s), scope

            case SContinue(info, expr):
                if expr is None:
                    return JContinue(info), scope
                if not self.loops:
                    _unsupported(s, "a `continue` outside a loop")
                return self.accumulate(expr, scope, s) + [JContinue(info)], scope

            case SMatch():
                return self.match_chain(
                    s, scope, lambda body, inner: self.stmts(body, inner)[0]
                )

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

    def match_chain(self, s, scope, translate_body):
        """A `match` as an if/else chain over the subject, held in a
        name of its own so it is evaluated once. The subject is a scalar
        -- this backend has neither lists nor tuples -- so a pattern is
        a literal, a wildcard, or a name. An arm whose pattern always
        matches becomes the `else`, which is what lets
        `_definitely_returns` see that a total `match` returns.
        SMatch -> Scope -> ([Stmt] -> Scope -> [JStmt]) -> ([JStmt], Scope)"""
        subject = self.expr(s.subject, scope)
        held, scope = _bind("__subject", subject.ctype, scope)
        here = JVar(s.info, held, subject.ctype)
        chain = None
        for case_clause in reversed(s.cases):
            test, bindings, arm_scope = self.pattern_test(
                case_clause.pattern, here, _block_scope(scope)
            )
            body = bindings + translate_body(case_clause.body, arm_scope)
            chain = body if test is None else [
                JIf(case_clause.info, test, body, chain)
            ]
        opening = JDecl(s.info, subject.ctype, held, subject)
        return [opening] + (chain or []), scope

    def pattern_test(self, pattern, subject, scope):
        """(test, bindings, scope) for one pattern over a scalar
        subject. The test is None when the pattern always matches, and a
        capture becomes a declaration at the top of the arm.
        Pattern -> JExpr -> Scope -> (JExpr?, [JStmt], Scope)"""
        info = pattern.info
        match pattern:
            case PWildcard():
                return None, [], scope
            case PCapture(_, name, _):
                java_name, scope = _bind(name, subject.ctype, scope)
                return None, [
                    JDecl(info, subject.ctype, java_name, subject)
                ], scope
            case PInt(_, value, _):
                self._require(subject, INT, "an Int pattern")
                return JBinary(
                    info, "==", subject, JInt(info, value), BOOL
                ), [], scope
            case PBool(_, value, _):
                self._require(subject, BOOL, "a Bool pattern")
                return JBinary(
                    info, "==", subject, JBool(info, value), BOOL
                ), [], scope
            case PText():
                _unsupported(
                    pattern,
                    "a `++` pattern over a string -- taking the middle out "
                    "means allocating one, which this backend has no value "
                    "model for",
                )
            case PString(_, value, _):
                # Java's `==` on String compares references, so a string
                # pattern goes through `.equals` like `==` does.
                self._require(subject, STRING, "a String pattern")
                return JEquals(info, subject, JStr(info, value)), [], scope
        _unsupported(pattern, "this pattern")

    def declare_functions(self, stmts, scope):
        """Registers every top-level def's signature (return type
        provisional: its annotation, or Int) before any body is
        translated, enabling forward references and mutual recursion
        (docs/target_java.md, "Forward references and mutual
        recursion"). [Stmt] -> Scope -> Scope"""
        for s in stmts:
            if isinstance(s, SFunctionDef):
                _reject_type_variables(s)
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
    return STRING if _used_as_string(param.name, func.body) else INT


def _used_as_string(name, node):
    """Whether `name` is added to, or compared with, a string literal
    anywhere in `node` -- the one piece of evidence worth chasing, since
    an unannotated parameter is otherwise an integer."""
    from dataclasses import fields, is_dataclass

    match node:
        case EConcat(_, EVar(_, n), EString()) | EConcat(_, EString(), EVar(_, n)):
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
    """Whether s, as the last statement of a block, guarantees a return
    -- or, for a `while (true)` nothing breaks out of, never lets the
    block finish at all, which javac treats the same way (JLS 14.21:
    such a statement cannot complete normally). Stmt -> Bool"""
    match s:
        case JReturn():
            return True
        case JIf(_, _, then_body, else_body) if else_body is not None:
            return _definitely_returns(then_body) and _definitely_returns(else_body)
        case JLoop(_, body):
            return not _breaks_out(body)
        case _:
            return False


def _breaks_out(body):
    """Whether body contains a `break` belonging to the loop it is the
    body of -- one inside a nested loop belongs to that one instead.
    [JStmt] -> Bool"""
    for s in body:
        match s:
            case JBreak():
                return True
            case JIf(_, _, then_body, else_body):
                if _breaks_out(then_body) or _breaks_out(else_body or []):
                    return True
            case _:
                pass
    return False


@dataclass(frozen=True)
class _Loop:
    """One `loop` being translated. Fields: slots, [(String, String)]
    (one Java local and its type per accumulator slot); result,
    (String, String)? (the local a `break` with an operand leaves the
    loop's value in, absent when no `break` carries one)."""
    slots: list
    result: tuple


def _slot_names(target):
    """One name per accumulator slot, or None if the target is nested
    deeper than Java can take apart. AssignTarget -> [String]?"""
    match target:
        case TargetName(_, name):
            return [name]
        case TargetTuple(_, elements):
            names = []
            for element in elements:
                match element:
                    case TargetName(_, name):
                        names.append(name)
                    case _:
                        return None
            return names
    return None


def _slot_values(expr, slots, node):
    """The expressions filling each slot: expr itself for one slot, its
    elements for several. Expr -> Int -> Stmt -> [Expr]"""
    if slots == 1:
        return [expr]
    match expr:
        case ETuple(_, elements) if len(elements) == slots:
            return elements
    _unsupported(
        node,
        f"this loop carries {slots} values, so every turn has to give "
        f"{slots} of them one by one -- Java has no tuple to take apart here",
    )


def _first_break_value(body):
    """The operand of the first `break` belonging to this body's own
    loop, or None. [Stmt] -> Expr?"""
    for s in body:
        match s:
            case SBreak(_, expr) if expr is not None:
                return expr
            case SIf(_, _, then_body, else_body):
                found = _first_break_value(then_body) or _first_break_value(
                    else_body or []
                )
                if found is not None:
                    return found
            case _:
                pass
    return None


def _breaks_bare(body):
    """Whether any `break` belonging to this body's own loop carries no
    operand. [Stmt] -> Bool"""
    for s in body:
        match s:
            case SBreak(_, None):
                return True
            case SIf(_, _, then_body, else_body):
                if _breaks_bare(then_body) or _breaks_bare(else_body or []):
                    return True
            case _:
                pass
    return False


def _breakable(node):
    """Refuses a loop whose value Java has no room for: one carrying
    several slots that a bare `break` would answer with all of them.
    Stmt -> ()"""
    _unsupported(
        node,
        "a loop that carries several values and is worth all of them -- "
        "Java has no tuple to hold that; `break` with the one value the "
        "loop is for",
    )


def _result_name(target):
    """The name to build the result local's from: the first slot's.
    AssignTarget -> String"""
    names = _slot_names(target)
    return f"{names[0]}_result" if names else "result"


def _zero(info, jtype):
    """A value of jtype to declare the result local with, since javac
    refuses to read one that might be unassigned. String -> JExpr"""
    if jtype == STRING:
        return JStr(info, "")
    if jtype == BOOL:
        return JBool(info, False)
    return JInt(info, 0)


def _as_stmts(translated):
    """One translation's statements: a statement translator may answer
    with several (a loop is a declaration plus a `while`).
    (JStmt | [JStmt]) -> [JStmt]"""
    return list(translated) if isinstance(translated, list) else [translated]


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
            main_body.extend(_as_stmts(translated))
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
        case JLoop(_, body):
            return "\n".join([
                f"{pad}while (true) {{",
                _emit_block(body, version, level + 1),
                f"{pad}}}",
            ])
        case JBreak(_):
            return f"{pad}break;"
        case JContinue(_):
            return f"{pad}continue;"
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
