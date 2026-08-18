"""The C code-generation backend, serving both the c89 and c23 targets --
one translation; standard is a printer parameter for where the two
differ (comments, declaration placement, booleans). C is statically
typed and Pyking is not, so this backend infers a type (Int, String, or
Bool) for every binding, parameter and function; where inference is not
enough it refuses with a source position. C also leaves the order of an
operator's operands and a call's arguments unspecified, so operands that
can print are pinned down with temporaries. See docs/target_c.md for the
inference rules, evaluation order, and how each construct compiles.

Data structures:
    UnsupportedError -- a construct this backend cannot compile, with
        the source position.
    CExpr / CStmt -- base classes for the C AST; every CExpr also
        carries its inferred ctype.

Functions:
    translate_program(stmts) -- translates a whole program to CProgram.
    translate_expr(e, env) -- translates one expression.
    translate_stmt(s, env) -- translates one statement.
    pprint_c_program(program, standard) -- CProgram to C source text.
"""

from dataclasses import dataclass

from analyses import Effects, walk
from lexer import Info
import runtime_interface
from syntax import (
    EInt, EString, EBool, EVar,
    EAdd, ESub, EMul, EDiv, ENeg,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EIf, ETuple,
    SLet, SLetStmt, SVar, SMutate, SReturn, SReturnStmt, SExprStmt, SWhile, SIf,
    SLoop, SBreak, SContinue, SFunctionDef,
    TargetName, TargetTuple, TInt, TString, TBool,
)

STANDARDS = ("c89", "c23")


class UnsupportedError(Exception):
    """Raised for a Pyking construct this backend cannot compile; carries
    the source position, like the other stages' errors."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


# What each unsupported construct is called in an error message, so a
# message names what the programmer wrote rather than the node the parser
# built for it.
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
# The three kinds of value a Pyking program in this subset can hold. They
# are kept as their own names rather than as C spellings because the C
# spelling of a boolean is one of the things the standards disagree about.

INT = "Int"
BOOL = "Bool"
STRING = "String"
# Pyking's unit type (), spelled void in C.
UNIT = "Unit"

_C_TYPES = {
    "c89": {INT: "int", BOOL: "int", STRING: "const char *", UNIT: "void"},
    "c23": {INT: "int", BOOL: "bool", STRING: "const char *", UNIT: "void"},
}

# printf conversion per type (docs/target_c.md, "Booleans"): a Bool
# argument becomes a conditional expression, since neither standard's
# spelling prints directly with %d/%s.
_FORMATS = {INT: "%d", BOOL: "%s", STRING: "%s"}

_ANNOTATIONS = {TInt: INT, TString: STRING, TBool: BOOL}


def _annotated_type(annotation):
    """The type an annotation names, or None for one C cannot represent
    (docs/target_c.md, "How types are inferred"). Type? -> String?"""
    return _ANNOTATIONS.get(type(annotation))


# --- C AST ---
#
# Every expression node carries its type: the printer needs it to choose
# a `printf` conversion, and the translator needs it to declare variables
# and to tell string `+` (concatenation) from integer `+`.

class CExpr:
    """Base class for the C expression AST."""


@dataclass(frozen=True)
class CInt(CExpr):
    info: Info
    value: int
    ctype: str = INT


@dataclass(frozen=True)
class CStr(CExpr):
    info: Info
    value: str
    ctype: str = STRING


@dataclass(frozen=True)
class CBool(CExpr):
    info: Info
    value: bool
    ctype: str = BOOL


@dataclass(frozen=True)
class CVar(CExpr):
    info: Info
    name: str
    ctype: str = INT


@dataclass(frozen=True)
class CUnary(CExpr):        # op operand
    info: Info
    op: str
    operand: CExpr
    ctype: str = INT


@dataclass(frozen=True)
class CBinary(CExpr):       # left op right
    info: Info
    op: str
    left: CExpr
    right: CExpr
    ctype: str = INT


@dataclass(frozen=True)
class CCall(CExpr):         # name(args...)
    info: Info
    name: str
    args: list
    ctype: str = INT


@dataclass(frozen=True)
class CCond(CExpr):         # cond ? then_expr : else_expr
    info: Info
    cond: CExpr
    then_expr: CExpr
    else_expr: CExpr
    ctype: str = INT


@dataclass(frozen=True)
class CConcat(CExpr):       # pyk_concat(left, right)
    info: Info
    left: CExpr
    right: CExpr
    ctype: str = STRING


@dataclass(frozen=True)
class CStrEq(CExpr):        # strcmp(left, right) == 0
    info: Info
    left: CExpr
    right: CExpr
    ctype: str = BOOL


@dataclass(frozen=True)
class CSeq(CExpr):          # (name = value, ..., result)
    """steps computed in the order they are written, then result, which
    is what the whole expression is worth. steps is [(String, CExpr)]:
    one temporary and the value to put in it. See docs/target_c.md,
    "Evaluation order"."""
    info: Info
    steps: list
    result: CExpr
    ctype: str = INT


class CStmt:
    """Base class for the C statement AST."""


@dataclass(frozen=True)
class CDecl(CStmt):         # <type> name = init;
    info: Info
    ctype: str
    name: str
    init: CExpr


@dataclass(frozen=True)
class CVarDecl(CStmt):      # <type> name;
    info: Info
    ctype: str
    name: str


@dataclass(frozen=True)
class CAssign(CStmt):       # name = expr;
    info: Info
    name: str
    expr: CExpr


@dataclass(frozen=True)
class CExprStmt(CStmt):     # expr;
    info: Info
    expr: CExpr


@dataclass(frozen=True)
class CPrint(CStmt):        # printf("...", ...);
    info: Info
    args: list


@dataclass(frozen=True)
class CIf(CStmt):
    info: Info
    cond: CExpr
    then_body: list
    else_body: list = None


@dataclass(frozen=True)
class CWhile(CStmt):
    info: Info
    cond: CExpr
    body: list


@dataclass(frozen=True)
class CLoop(CStmt):         # while (1) { body }
    info: Info
    body: list


@dataclass(frozen=True)
class CBreak(CStmt):        # break;
    info: Info


@dataclass(frozen=True)
class CContinue(CStmt):     # continue;
    info: Info


@dataclass(frozen=True)
class CReturn(CStmt):
    info: Info
    expr: CExpr


@dataclass(frozen=True)
class CFunc:                # <ret> name(params) { body }
    info: Info
    name: str
    params: list            # list of (ctype, name)
    body: list
    ret_type: str = INT


@dataclass(frozen=True)
class CProgram:
    """A translated program. Fields: functions, [CFunc]; main_body,
    [CStmt]; uses_print/uses_concat/uses_strcmp, Bool (which runtime
    helpers are used, and so which headers the file needs)."""
    functions: list
    main_body: list
    uses_print: bool = False
    uses_concat: bool = False
    uses_strcmp: bool = False


# --- scope ---
#
# C blocks are lexical scopes, as Pyking's are. Rebinding gets a fresh C
# variable, since C cannot declare one name twice in a block and a
# rebinding may hold a different type.


@dataclass(frozen=True)
class Scope:
    """The names in scope during translation. Fields: outside, {String}
    (bound in the Pyking program but not reachable here -- this
    backend's functions have no closures); names, {String: (String,
    String)} (Pyking name -> (C name, ctype)); block, {String} (names
    bound by the innermost block); taken, {String} (every C name already
    spoken for here, which `names` cannot say: it holds only each
    Pyking name's *current* C name, so a name rebound three times would
    otherwise offer the second one's spelling back to the fourth)."""
    outside: frozenset
    names: dict
    block: frozenset
    taken: frozenset = frozenset()


def _block_scope(scope):
    """The scope for a nested block: sees outside and names; drops
    block. Scope -> Scope"""
    return Scope(scope.outside, scope.names, frozenset(), scope.taken)


def _reserve(names, scope):
    """scope with these C names spoken for, but meaning nothing: what a
    loop does with its accumulator, which is declared in this block and
    in scope only in the loop's own body. [String] -> Scope -> Scope"""
    return Scope(scope.outside, scope.names, scope.block, scope.taken | set(names))


def _lookup(name, scope, info):
    """The (C name, ctype) a Pyking name reads as; raises
    UnsupportedError for a name out of this function's reach or with no
    C representation. String -> Scope -> Info -> (String, String)"""
    if name not in scope.names:
        if name in scope.outside:
            _unsupported(
                _At(info),
                f"'{name}' is bound outside this function -- "
                "C has no closures: a function here reads its parameters and calls other functions, nothing else",
            )
        _unsupported(
            _At(info), f"'{name}' is not a value this backend can compile"
        )
    return scope.names[name]


@dataclass(frozen=True)
class _At:
    """Carries an Info for _unsupported when the offending thing is a
    name rather than a node."""
    info: Info


# Legal Pyking identifiers that are reserved in C (both standards'
# keywords, plus main/printf/the generated helpers, so a shadowing
# def can't break the file). See docs/target_c.md, "Names that are
# keywords in C".
RESERVED = frozenset("""
auto break case char const continue default do double else enum extern
float for goto if inline int long register restrict return short signed
sizeof static struct switch typedef union unsigned void volatile while
alignas alignof bool constexpr false nullptr static_assert thread_local
true typeof _Alignas _Alignof _Atomic _Bool _Complex _Generic _Imaginary
_Noreturn _Static_assert _Thread_local
main printf strcmp strlen malloc size_t pyk_concat
""".split())


def _fresh_c_name(name, scope):
    """name2, name3, ... -- the first not already used. String -> Scope
    -> String"""
    taken = (
        set(scope.names)
        | {c_name for c_name, _ in scope.names.values()}
        | set(scope.taken)
    )
    n = 2
    while f"{name}{n}" in taken or f"{name}{n}" in RESERVED:
        n += 1
    return f"{name}{n}"


def _bind(name, ctype, scope):
    """Binds a Pyking name at ctype, returning (c_name, extended_scope).
    String -> String -> Scope -> (String, Scope)"""
    c_name = name
    if (
        name in RESERVED
        or name in scope.names
        or any(name == c for c, _ in scope.names.values())
        or name in scope.taken
    ):
        c_name = _fresh_c_name(name, scope)
    return c_name, Scope(
        scope.outside,
        {**scope.names, name: (c_name, ctype)},
        scope.block | {name},
        scope.taken | {c_name},
    )


# --- translation ---

_BINARY_OPS = {
    EAdd: "+", ESub: "-", EMul: "*",
    ELessThan: "<", ELessThanEq: "<=", EGreatThan: ">", EGreatThanEq: ">=",
}


def _unused_prefix(stmts):
    """A prefix no name in the program starts with, for the temporaries
    that pin evaluation order down (docs/target_c.md, "Evaluation
    order"). [Stmt] -> String"""
    names = {
        getattr(node, "name")
        for node in walk(stmts)
        if isinstance(getattr(node, "name", None), str)
    }
    prefix = "tmp"
    while any(name.startswith(prefix) for name in names):
        prefix += "_"
    return prefix


class _Translator:
    """Accumulates what the whole-program walk needs across functions:
    signatures, which have been defined, and which runtime helpers are
    used. Fields: signatures, {String: (String, [String], String)}
    (Pyking name -> (C name, param ctypes, return ctype)); declared,
    {String: String} (Pyking name -> C name, from the declaration pass);
    defined, {String} (functions whose body has been translated);
    called_early, {String} (functions called before that);
    uses_print/uses_concat/uses_strcmp, Bool; printing, Effects (which
    expressions can print); temporary_prefix, String (see
    _unused_prefix); temps, [(String, String, Info)] (the
    evaluation-order temporaries the function being translated needs, as
    ctype, C name and where they came from)."""

    def __init__(self, stmts):
        self.signatures = {}
        self.declared = {}
        self.defined = set()
        self.called_early = set()
        self.uses_print = False
        self.uses_concat = False
        self.uses_strcmp = False
        # The enclosing `loop`s, innermost last (see _Loop), and how
        # many temporaries have been named so far.
        self.loops = []
        self.temporaries = 0
        self.printing = Effects(stmts)
        self.temporary_prefix = _unused_prefix(stmts)
        self.temps = []

    def temporary(self):
        """A number no temporary has used yet. () -> Int"""
        self.temporaries += 1
        return self.temporaries

    # -- expressions --

    def fresh_temp(self, ctype, info):
        """A fresh evaluation-order temporary, declared at the top of
        the function being translated. String -> Info -> String"""
        name = f"{self.temporary_prefix}{self.temporary()}"
        self.temps.append((ctype, name, info))
        return name

    def in_order(self, exprs, scope):
        """The expressions translated, plus the assignments that pin
        their evaluation order down where two or more of them can print
        (docs/target_c.md, "Evaluation order"). [Expr] -> Scope ->
        ([CExpr], [(String, CExpr)])"""
        translated = [self.expr(e, scope) for e in exprs]
        effectful = [
            i for i, e in enumerate(exprs) if self.printing.may_print(e)
        ]
        if len(effectful) < 2:
            return translated, []

        # The last one may stay where it is: nothing after it can be
        # pulled ahead of something that no longer has anything to say.
        steps = []
        for index in effectful[:-1]:
            value = translated[index]
            name = self.fresh_temp(value.ctype, value.info)
            steps.append((name, value))
            translated[index] = CVar(value.info, name, value.ctype)
        return translated, steps

    def sequenced(self, steps, result):
        """result, with in_order's assignments computed first -- the
        comma operator, which is where C does fix the order.
        [(String, CExpr)] -> CExpr -> CExpr"""
        if not steps:
            return result
        return CSeq(result.info, steps, result, result.ctype)

    def declarations(self, from_index=0):
        """The temporaries allocated since from_index, as declarations,
        and forgotten. Int -> [CStmt]"""
        allocated = self.temps[from_index:]
        del self.temps[from_index:]
        return [CVarDecl(info, ctype, name) for ctype, name, info in allocated]

    def is_function_value(self, name, scope):
        """Whether name here means a def itself rather than a value.
        String -> Scope -> Bool"""
        if name not in self.signatures:
            return False
        bound = scope.names.get(name)
        return bound is None or bound[0] == self.signatures[name][0]

    def expr(self, e, scope, allow_unit=False):
        """Translates one expression. allow_unit permits a call to a
        void function, meaningful only as an expression statement.
        Expr -> Scope -> Bool -> CExpr"""
        match e:
            case EInt(info, v):
                return CInt(info, v)
            case EString(info, s):
                return CStr(info, s)
            case EBool(info, v):
                return CBool(info, v)
            case EVar(info, name) if self.is_function_value(name, scope):
                # A def's own name used as a value (docs/target_c.md,
                # "A function used as a value").
                _unsupported(
                    _At(info),
                    f"`{name}` is a function used as a value -- "
                    "C has no function values here: a `def` becomes a C function, and only a call can name one",
                )
            case EVar(info, name):
                c_name, ctype = _lookup(name, scope, info)
                return CVar(info, c_name, ctype)
            case ENeg(info, operand):
                inner = self.expr(operand, scope)
                self._require(inner, INT, "negation")
                return CUnary(info, "-", inner, INT)
            case EDiv(info, _, _):
                # docs/target_c.md, "/".
                _unsupported(
                    e,
                    "`/` is true division in Pyking and truncating integer "
                    "division in C; matching it needs a floating-point type "
                    "this backend does not have yet",
                )
            case EAdd(info, l, r):
                (left, right), steps = self.in_order([l, r], scope)
                if left.ctype == STRING and right.ctype == STRING:
                    self.uses_concat = True
                    return self.sequenced(steps, CConcat(info, left, right))
                self._require(left, INT, "`+`")
                self._require(right, INT, "`+`")
                return self.sequenced(
                    steps, CBinary(info, "+", left, right, INT)
                )
            case EEq(info, l, r):
                (left, right), steps = self.in_order([l, r], scope)
                if left.ctype == STRING and right.ctype == STRING:
                    self.uses_strcmp = True
                    return self.sequenced(steps, CStrEq(info, left, right))
                if left.ctype != right.ctype:
                    _unsupported(e, "`==` between values of different types")
                return self.sequenced(
                    steps, CBinary(info, "==", left, right, BOOL)
                )
            case EIf(info, cond, then_expr, else_expr):
                c = self.expr(cond, scope)
                t = self.expr(then_expr, scope)
                f = self.expr(else_expr, scope)
                if t.ctype != f.ctype:
                    _unsupported(
                        e,
                        "the branches of an `if` expression must have the same "
                        "type in C",
                    )
                return CCond(info, c, t, f, t.ctype)
            case ECall(info, EVar(_, name), args) if runtime_interface.lookup(name):
                _unsupported(
                    e, f"`{name}` may only be used as a statement, not as a value"
                )
            case ECall(info, EVar(_, name), args):
                if name not in self.signatures:
                    _unsupported(e, f"call to unknown function `{name}`")
                if name not in self.defined:
                    self.called_early.add(name)
                c_name, param_types, ret = self.signatures[name]
                if len(args) != len(param_types):
                    _unsupported(e, f"`{name}` takes {len(param_types)} argument(s)")
                if ret == UNIT and not allow_unit:
                    _unsupported(
                        e,
                        f"`{name}` produces no value (it returns unit), so it "
                        "cannot be used as one; call it as a statement of "
                        "its own",
                    )
                ordered, steps = self.in_order(list(args), scope)
                return self.sequenced(steps, CCall(info, c_name, ordered, ret))
            case ECall(info, _, _):
                _unsupported(e, "calling anything but a named function")
            case _ if type(e) in _BINARY_OPS:
                (left, right), steps = self.in_order([e.left, e.right], scope)
                op = _BINARY_OPS[type(e)]
                self._require(left, INT, f"`{op}`")
                self._require(right, INT, f"`{op}`")
                ctype = INT if op in ("+", "-", "*") else BOOL
                return self.sequenced(
                    steps, CBinary(e.info, op, left, right, ctype)
                )
            case _:
                _unsupported(e, type(e).__name__)

    def _require(self, node, ctype, what):
        """Raises UnsupportedError if node's ctype is not ctype. CExpr ->
        String -> String -> ()"""
        if node.ctype != ctype:
            _unsupported(
                _At(node.info),
                f"{what} needs {ctype} operands here, not {node.ctype}",
            )

    # -- statements --

    def stmts(self, stmts, scope):
        """Translates a statement sequence, threading the scope through
        it. [Stmt] -> Scope -> ([CStmt], Scope)"""
        out = []
        for s in stmts:
            translated, scope = self.stmt(s, scope)
            out.extend(_as_stmts(translated))
        return out, scope

    def tail_stmts(self, stmts, scope):
        """Translates a statement list whose last statement is in tail
        position (PYKING.md, "Tail position"). [Stmt] -> Scope ->
        [CStmt]"""
        if not stmts:
            return []
        body, tail_scope = self.stmts(stmts[:-1], scope)
        return body + self.tail_stmt(stmts[-1], tail_scope)

    def tail_stmt(self, s, scope):
        """The last statement of a body in tail position, as a list of C
        statements. Stmt -> Scope -> [CStmt]"""
        match s:
            case SExprStmt(_, ECall(_, EVar(_, name), _)) if (
                runtime_interface.lookup(name) is not None
            ):
                translated, _ = self.stmt(s, scope)
                return _as_stmts(translated)
            case SExprStmt(info, expr):
                return [CReturn(info, self.expr(expr, scope))]
            case SIf(info, cond, then_body, else_body):
                condition = self.expr(cond, scope)
                self._require(condition, BOOL, "an `if` condition")
                then_branch = self.tail_stmts(then_body, _block_scope(scope))
                else_branch = (
                    None
                    if else_body is None
                    else self.tail_stmts(else_body, _block_scope(scope))
                )
                return [CIf(info, condition, then_branch, else_branch)]
            case SLoop(info):
                # A function ending in a loop returns what the loop
                # produced: what it broke with.
                c_stmts, value, _ = self.loop(s, scope)
                if value is None:
                    _breakable(s)
                return c_stmts + [CReturn(info, value)]
            case _:
                translated, _ = self.stmt(s, scope)
                return _as_stmts(translated)

    def loop(self, s, scope):
        """Translates a loop into `while (1)` over one mutable variable
        per accumulator slot (docs/target_c.md, "loop"): the initializer
        declares them, every tail of the body assigns the next turn's
        values, and a `break`/`continue` with an operand assigns before
        it jumps. Returns the statements, the expression holding the
        loop's value afterwards, and the scope: the accumulators are in
        scope only in the loop's own body, but their declarations stand
        in the block around it, so those C names stay spoken for there.
        SLoop -> Scope -> ([CStmt], CExpr?, Scope)"""
        info = s.info
        if s.target is None:
            _unsupported(
                s,
                "a `loop` with no accumulator -- C has no value to give it, "
                "so write `loop x = 0:` and break with what you want",
            )
        names = _slot_names(s.target)
        if names is None:
            _unsupported(s, "a loop accumulator that is not one name per slot")
        values = [self.expr(e, scope) for e in _slot_values(s.init, len(names), s)]

        # One variable per slot, declared where the loop is written.
        body_scope = _block_scope(scope)
        slots = []
        for name, value in zip(names, values):
            c_name, body_scope = _bind(name, value.ctype, body_scope)
            slots.append((c_name, value.ctype))
        setup = [
            CDecl(info, value.ctype, c_name, value)
            for (c_name, _), value in zip(slots, values)
        ]

        # A loop is worth what it breaks with, which is not always what
        # it carries -- so a `break` with an operand needs a variable of
        # its own to leave the answer in.
        result = None
        first_value = _first_break_value(s.body)
        if len(slots) > 1 and _breaks_bare(s.body):
            # The answer would be the tuple of slots, which C has no
            # room for.
            _breakable(s)
        if first_value is not None:
            # Translated for its type alone, so anything it allocated is
            # forgotten again; the `break` itself translates it for real.
            probe = len(self.temps)
            result_type = self.expr(first_value, body_scope).ctype
            del self.temps[probe:]
            result_name, scope_after = _bind(
                _result_name(s.target), result_type, _block_scope(scope)
            )
            result = (result_name, result_type)
            setup.append(CDecl(info, result_type, result_name, _zero(info, result_type)))

        self.loops.append(_Loop(slots, result))
        try:
            body = self.loop_block(s.body, body_scope)
        finally:
            self.loops.pop()
        taken = [c_name for c_name, _ in slots] + ([result[0]] if result else [])
        value = (
            CVar(info, result[0], result[1]) if result
            else CVar(info, slots[0][0], slots[0][1])
        )
        if result is None and len(slots) > 1:
            # Nothing breaks out with a value, so nothing reads the
            # loop's own value either; `tail_stmt` and the binding case
            # both check that before using it.
            value = None
        return setup + [CLoop(info, body)], value, _reserve(taken, scope)

    def accumulate(self, expr, scope, node):
        """The statements that give the innermost loop its next values.
        With more than one slot they go through temporaries, so a slot
        that reads another sees the turn it is still on.
        Expr -> Scope -> Stmt -> [CStmt]"""
        loop = self.loops[-1]
        values = [
            self.expr(e, scope) for e in _slot_values(expr, len(loop.slots), node)
        ]
        for (c_name, ctype), value in zip(loop.slots, values):
            if value.ctype != ctype:
                _unsupported(
                    node,
                    f"this loop carries {ctype} in `{c_name}`, so it cannot "
                    f"go on with {value.ctype} in C",
                )
        if len(loop.slots) == 1:
            return [CAssign(node.info, loop.slots[0][0], values[0])]
        turn = self.temporary()
        temporaries = [
            (f"{c_name}_next{turn}", ctype) for c_name, ctype in loop.slots
        ]
        return [
            CDecl(node.info, ctype, name, value)
            for (name, ctype), value in zip(temporaries, values)
        ] + [
            CAssign(node.info, c_name, CVar(node.info, name, ctype))
            for (c_name, _), (name, ctype) in zip(loop.slots, temporaries)
        ]

    def leave(self, expr, scope, node):
        """The statements that give the innermost loop its value and
        leave it. Expr? -> Scope -> Stmt -> [CStmt]"""
        loop = self.loops[-1]
        if loop.result is None:
            # Nothing breaks with a value here, so the accumulator is
            # the answer and there is nothing to assign.
            return [CBreak(node.info)]
        name, ctype = loop.result
        value = (
            CVar(node.info, loop.slots[0][0], loop.slots[0][1]) if expr is None
            else self.expr(expr, scope)
        )
        if value.ctype != ctype:
            _unsupported(
                node,
                f"this loop leaves {ctype} one way and {value.ctype} "
                f"another; C needs one type for the answer",
            )
        return [CAssign(node.info, name, value), CBreak(node.info)]

    def loop_block(self, stmts, scope):
        """Translates a loop body: whatever a path ends in is the next
        turn's value, so every tail becomes an assignment to the
        accumulator -- except a `break`/`continue`, which has already
        said what happens next. [Stmt] -> Scope -> [CStmt]"""
        if not stmts:
            return []
        body, scope = self.stmts(stmts[:-1], scope)
        return body + self.loop_tail(stmts[-1], scope)

    def loop_tail(self, s, scope):
        """The last statement of a loop body, or of one branch of one.
        Stmt -> Scope -> [CStmt]"""
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
                        "value, and C has no unit to give it",
                    )
                return [CIf(
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
        [Stmt] -> Scope -> [CStmt]"""
        translated, _ = self.stmts(stmts, _block_scope(scope))
        return translated

    def stmt(self, s, scope):
        """Translates one statement, returning it with the scope it
        leaves behind; several C statements where one Pyking statement
        needs them (see _as_stmts).
        Stmt -> Scope -> ((CStmt | [CStmt]), Scope)"""
        match s:
            case SLet(info, TargetName(_, name), expr):
                value = self.expr(expr, scope)
                c_name, scope = _bind(name, value.ctype, scope)
                return CDecl(info, value.ctype, c_name, value), scope

            case SLet(info, _, _):
                _unsupported(s, "tuple destructuring targets")

            case SLetStmt(info, TargetName(_, name), SLoop() as loop):
                # `x = loop ...` -- the loop's value is the accumulator
                # it stopped with, so the binding is one declaration
                # after it.
                c_stmts, value, scope = self.loop(loop, scope)
                if value is None:
                    _breakable(loop)
                c_name, scope = _bind(name, value.ctype, scope)
                return c_stmts + [CDecl(info, value.ctype, c_name, value)], scope

            case SVar(info, name, expr):
                value = self.expr(expr, scope)
                c_name, scope = _bind(name, value.ctype, scope)
                return CDecl(info, value.ctype, c_name, value), scope

            case SMutate(info, name, expr):
                c_name, ctype = _lookup(name, scope, info)
                value = self.expr(expr, scope)
                if value.ctype != ctype:
                    _unsupported(
                        s,
                        f"`:=` cannot change the type of `{name}` from "
                        f"{ctype} to {value.ctype} in C",
                    )
                return CAssign(info, c_name, value), scope

            case SReturn(info, expr):
                return CReturn(info, self.expr(expr, scope)), scope

            case SReturnStmt(_, stmt):
                # A loop answers with several statements (the
                # accumulator, the loop, the return).
                return self.tail_stmt(stmt, scope), scope

            case SExprStmt(info, ECall(_, EVar(_, name), args)) if (
                runtime_interface.lookup(name)
            ):
                # `printf` is a call like any other, so its arguments are
                # ordered the same way -- but this is a statement, and a
                # statement can put them in front of itself rather than
                # in a comma expression.
                self.uses_print = True
                ordered, steps = self.in_order(list(args), scope)
                return [
                    CAssign(info, temp, value) for temp, value in steps
                ] + [CPrint(info, ordered)], scope

            case SExprStmt(info, expr):
                return CExprStmt(info, self.expr(expr, scope, allow_unit=True)), scope

            case SWhile(info, cond, body):
                return CWhile(info, self.expr(cond, scope), self.block(body, scope)), scope

            case SLoop():
                c_stmts, _, scope = self.loop(s, scope)
                return c_stmts, scope

            case SBreak(_, expr):
                if not self.loops:
                    _unsupported(s, "a `break` outside a loop")
                return self.leave(expr, scope, s), scope

            case SContinue(info, expr):
                if expr is None:
                    return CContinue(info), scope
                if not self.loops:
                    _unsupported(s, "a `continue` outside a loop")
                return self.accumulate(expr, scope, s) + [CContinue(info)], scope

            case SIf(info, cond, then_body, else_body):
                c_else = None if else_body is None else self.block(else_body, scope)
                return CIf(
                    info, self.expr(cond, scope), self.block(then_body, scope), c_else
                ), scope

            case SFunctionDef():
                _unsupported(
                    s,
                    "a nested function -- C has no nested functions, and one "
                    "reading its enclosing scope could not be hoisted to file "
                    "scope without closures",
                )

            case _:
                _unsupported(s, type(s).__name__)

    # -- functions --

    def declare_functions(self, stmts, scope):
        """Registers every top-level def's signature (return type
        provisional: its annotation, or Int) before any body is
        translated, enabling forward references and mutual recursion
        (docs/target_c.md, "Forward references and mutual recursion").
        [Stmt] -> Scope -> Scope"""
        for s in stmts:
            if isinstance(s, SFunctionDef):
                c_name, scope = _bind(s.name, INT, scope)
                self.signatures[s.name] = (
                    c_name,
                    [_param_type(s, p) for p in s.params],
                    _annotated_type(s.return_type) or INT,
                )
                self.declared[s.name] = c_name
        return scope

    def function(self, func, scope):
        """Translates a def; its signature is already registered
        (declare_functions). SFunctionDef -> Scope -> (CFunc, Scope)"""
        param_types = [_param_type(func, p) for p in func.params]
        if func.name in self.declared:
            c_name = self.declared[func.name]
        else:
            c_name, scope = _bind(func.name, INT, scope)
        provisional = _annotated_type(func.return_type) or INT
        self.signatures[func.name] = (c_name, param_types, provisional)

        # A function body starts from nothing but its own parameters; no
        # closures, so outside remembers what it cannot see (_lookup).
        body_scope = Scope(frozenset(scope.names), {}, frozenset())
        params = []
        for param, ctype in zip(func.params, param_types):
            c_param, body_scope = _bind(param.name, ctype, body_scope)
            params.append((ctype, c_param))

        # This function's evaluation-order temporaries are declared at
        # the top of it, so that one written in a `while` condition
        # stands outside the loop it is tested in.
        outer_temps = len(self.temps)
        if func.expr is not None:
            value = self.expr(func.expr, body_scope)
            body = [CReturn(value.info, value)]
        else:
            body = self.tail_stmts(func.body, body_scope)
        temporaries = self.declarations(outer_temps)

        returned = _return_types(body)
        recursive = _calls(body, c_name)
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
        self.signatures[func.name] = (c_name, param_types, actual)
        if func.name in self.called_early and actual != provisional:
            _unsupported(
                func,
                f"`{func.name}` is called before it is defined and does not "
                f"return {provisional}; a call written above a `def` is typed "
                "from the annotation, or Int without one, so annotate the "
                "return type (`-> String`, `-> Bool`)",
            )
        self.defined.add(func.name)

        if actual != UNIT and _falls_through(body):
            _unsupported(
                func,
                f"`{func.name}` produces a value on some paths and none on "
                "others; C has one return type per function, and falling off "
                "the end of a non-`void` one is undefined behaviour, so give "
                "every path a value (an `if` needs its `else`)",
            )

        return CFunc(
            func.info, c_name, params, temporaries + body, actual
        ), scope


def _param_type(func, param):
    """A parameter's type: its annotation when C can represent it, else
    what the body's use of it suggests, else Int (docs/target_c.md,
    "How types are inferred"). SFunctionDef -> Param -> String"""
    annotated = _annotated_type(param.type)
    if annotated is not None:
        return annotated
    body = [func.expr] if func.expr is not None else func.body
    return STRING if _used_as_string(param.name, body) else INT


def _used_as_string(name, node):
    """Whether name is added to, or compared with, a string literal
    anywhere in node. String -> Expr|Stmt|... -> Bool"""
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


def _walk_c(node):
    """Every C AST node under node, itself included. CExpr|CStmt|... ->
    (CExpr|CStmt|...,)"""
    from dataclasses import fields, is_dataclass

    if is_dataclass(node):
        yield node
        for f in fields(node):
            yield from _walk_c(getattr(node, f.name))
    elif isinstance(node, (list, tuple)):
        for element in node:
            yield from _walk_c(element)


@dataclass(frozen=True)
class _Loop:
    """One `loop` being translated. Fields: slots, [(String, String)]
    (one C variable and its type per accumulator slot); result,
    (String, String)? (the variable a `break` with an operand leaves the
    loop's value in, absent when no `break` carries one)."""
    slots: list
    result: tuple


def _slot_names(target):
    """One name per accumulator slot, or None if the target is nested
    deeper than C can take apart. AssignTarget -> [String]?"""
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
    elements for several. Refuses anything else, since C has no tuple to
    take apart at run time. Expr -> Int -> Stmt -> [Expr]"""
    if slots == 1:
        return [expr]
    match expr:
        case ETuple(_, elements) if len(elements) == slots:
            return elements
    _unsupported(
        node,
        f"this loop carries {slots} values, so every turn has to give "
        f"{slots} of them one by one -- C has no tuple to take apart here",
    )


def _breaks_bare(body):
    """Whether any `break` belonging to this body's own loop carries no
    operand -- in a loop of several slots, one whose answer would be the
    tuple of them. [Stmt] -> Bool"""
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


def _first_break_value(body):
    """The operand of the first `break` belonging to this body's own
    loop, or None. A nested loop's breaks belong to that loop.
    [Stmt] -> Expr?"""
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


def _breakable(node):
    """Refuses a loop whose value C has no room for: one carrying
    several slots that a bare `break` would answer with all of them.
    Stmt -> ()"""
    _unsupported(
        node,
        "a loop that carries several values and is worth all of them -- C "
        "has no tuple to hold that; `break` with the one value the loop "
        "is for",
    )


def _result_name(target):
    """The name to build the result variable's from: the first slot's,
    so the generated name reads as what it holds.
    AssignTarget -> String"""
    names = _slot_names(target)
    return f"{names[0]}_result" if names else "result"


def _zero(info, ctype):
    """A value of ctype to declare the result variable with, since C
    reads an uninitialised one. String -> CExpr"""
    if ctype == STRING:
        return CStr(info, "")
    if ctype == BOOL:
        return CBool(info, False)
    return CInt(info, 0)


def _as_stmts(translated):
    """One translation's statements: a statement translator may answer
    with several (a loop is a declaration plus a `while`).
    (CStmt | [CStmt]) -> [CStmt]"""
    return list(translated) if isinstance(translated, list) else [translated]


def _falls_through(body):
    """Whether control can reach the end of body without returning --
    undefined behavior for a non-void C function (docs/target_c.md,
    "A function that produces a value on some paths and none on
    others"). [CStmt] -> Bool"""
    if not body:
        return True
    match body[-1]:
        case CReturn():
            return False
        case CIf(_, _, then_body, else_body) if else_body is not None:
            return _falls_through(then_body) or _falls_through(else_body)
        case CLoop(_, loop_body):
            # `while (1)` ends only by breaking out of it; with no
            # `break` for this loop, nothing after it runs.
            return _breaks_out(loop_body)
        case _:
            return True


def _breaks_out(body):
    """Whether body contains a `break` belonging to the loop it is the
    body of -- one inside a nested loop belongs to that one instead.
    [CStmt] -> Bool"""
    for s in body:
        match s:
            case CBreak():
                return True
            case CIf(_, _, then_body, else_body):
                if _breaks_out(then_body) or _breaks_out(else_body or []):
                    return True
            case _:
                pass
    return False


def _return_types(body):
    """Every ctype returned anywhere in body. [CStmt] -> {String}"""
    return {n.expr.ctype for n in _walk_c(body) if isinstance(n, CReturn)}


def _calls(body, c_name):
    """Whether body calls the C function named c_name. [CStmt] ->
    String -> Bool"""
    return any(
        isinstance(n, CCall) and n.name == c_name for n in _walk_c(body)
    )


def translate_program(stmts):
    """A whole Pyking program as a CProgram. [Stmt] -> CProgram"""
    translator = _Translator(stmts)
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
    return CProgram(
        functions,
        translator.declarations() + main_body,
        translator.uses_print,
        translator.uses_concat,
        translator.uses_strcmp,
    )


# --- printer: C AST -> C source text ---

_PRECEDENCE = {
    "*": 13, "/": 13,
    "+": 12, "-": 12,
    "<": 10, "<=": 10, ">": 10, ">=": 10,
    "==": 9,
}
_UNARY_PRECEDENCE = 14
_CONDITIONAL_PRECEDENCE = 3
_ASSIGN_PRECEDENCE = 2
_CALL_PRECEDENCE = 16

_ESCAPES = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\t": "\\t", "\r": "\\r"}


def _quote(s):
    """s as a double-quoted C string literal. String -> String"""
    return '"' + "".join(_ESCAPES.get(ch, ch) for ch in s) + '"'


def _wrap(prec, min_prec, text):
    """text, parenthesized if prec is below min_prec. Int -> Int ->
    String -> String"""
    return f"({text})" if prec < min_prec else text


def _bool_literal(value, standard):
    """value as this standard's Bool literal. Bool -> String -> String"""
    if standard == "c23":
        return "true" if value else "false"
    return "1" if value else "0"


def pprint_c_expr(e, standard, min_prec=0):
    """e as C source text. CExpr -> String -> Int -> String"""
    match e:
        case CInt(_, v, _):
            return str(v)
        case CStr(_, s, _):
            return _quote(s)
        case CBool(_, v, _):
            return _bool_literal(v, standard)
        case CVar(_, name, _):
            return name
        case CUnary(_, op, operand, _):
            text = f"{op}{pprint_c_expr(operand, standard, _UNARY_PRECEDENCE + 1)}"
            return _wrap(_UNARY_PRECEDENCE, min_prec, text)
        case CBinary(_, op, left, right, _):
            prec = _PRECEDENCE[op]
            text = (
                f"{pprint_c_expr(left, standard, prec)} {op} "
                f"{pprint_c_expr(right, standard, prec + 1)}"
            )
            return _wrap(prec, min_prec, text)
        case CCond(_, cond, then_expr, else_expr, _):
            text = (
                f"{pprint_c_expr(cond, standard, _CONDITIONAL_PRECEDENCE + 1)} ? "
                f"{pprint_c_expr(then_expr, standard, _CONDITIONAL_PRECEDENCE)} : "
                f"{pprint_c_expr(else_expr, standard, _CONDITIONAL_PRECEDENCE)}"
            )
            return _wrap(_CONDITIONAL_PRECEDENCE, min_prec, text)
        case CCall(_, name, args, _):
            args_text = ", ".join(pprint_c_expr(a, standard) for a in args)
            return f"{name}({args_text})"
        case CConcat(_, left, right, _):
            return (
                f"pyk_concat({pprint_c_expr(left, standard)}, "
                f"{pprint_c_expr(right, standard)})"
            )
        case CStrEq(_, left, right, _):
            text = (
                f"strcmp({pprint_c_expr(left, standard)}, "
                f"{pprint_c_expr(right, standard)}) == 0"
            )
            return _wrap(_PRECEDENCE["=="], min_prec, text)
        case CSeq(_, steps, result, _):
            # Always parenthesized: the comma operator binds looser than
            # everything, and a bare comma in an argument list would
            # separate arguments instead of sequencing them.
            assignments = ", ".join(
                f"{name} = {pprint_c_expr(value, standard, _ASSIGN_PRECEDENCE)}"
                for name, value in steps
            )
            return (
                f"({assignments}, "
                f"{pprint_c_expr(result, standard, _ASSIGN_PRECEDENCE)})"
            )
        case _:
            raise NotImplementedError(f"no printer for C expression {e!r}")


def _print_argument(arg, standard):
    """One printf argument; a Bool becomes a conditional expression
    (docs/target_c.md, "Booleans"). CExpr -> String -> String"""
    text = pprint_c_expr(arg, standard, _CONDITIONAL_PRECEDENCE + 1)
    if arg.ctype == BOOL:
        return f'{text} ? "true" : "false"'
    return pprint_c_expr(arg, standard)


def pprint_c_stmt(s, standard, level=1):
    """s as C source text, indented to level. CStmt -> String -> Int ->
    String"""
    pad = "    " * level
    match s:
        case CDecl(_, ctype, name, init):
            # Only reached for c23; c89 splits declarations out (_emit_block).
            return (
                f"{pad}{_declaration(ctype, name, standard)} = "
                f"{pprint_c_expr(init, standard)};"
            )
        case CVarDecl(_, ctype, name):
            # Only reached for c23; c89 splits declarations out (_emit_block).
            return f"{pad}{_declaration(ctype, name, standard)};"
        case CAssign(_, name, expr):
            return f"{pad}{name} = {pprint_c_expr(expr, standard)};"
        case CExprStmt(_, expr):
            return f"{pad}{pprint_c_expr(expr, standard)};"
        case CReturn(_, expr):
            return f"{pad}return {pprint_c_expr(expr, standard)};"
        case CPrint(_, args):
            spec = " ".join(_FORMATS[a.ctype] for a in args)
            arguments = "".join(
                f", {_print_argument(a, standard)}" for a in args
            )
            return f'{pad}printf("{spec}\\n"{arguments});'
        case CIf(_, cond, then_body, else_body):
            lines = [f"{pad}if ({pprint_c_expr(cond, standard)}) {{"]
            lines.append(_emit_block(then_body, standard, level + 1))
            while True:
                match else_body:
                    case [CIf(_, elif_cond, elif_body, else_body2)]:
                        lines.append(
                            f"{pad}}} else if "
                            f"({pprint_c_expr(elif_cond, standard)}) {{"
                        )
                        lines.append(_emit_block(elif_body, standard, level + 1))
                        else_body = else_body2
                    case None:
                        break
                    case _:
                        lines.append(f"{pad}}} else {{")
                        lines.append(_emit_block(else_body, standard, level + 1))
                        break
            lines.append(f"{pad}}}")
            return "\n".join(lines)
        case CWhile(_, cond, body):
            return "\n".join([
                f"{pad}while ({pprint_c_expr(cond, standard)}) {{",
                _emit_block(body, standard, level + 1),
                f"{pad}}}",
            ])
        case CLoop(_, body):
            # `while (1)`, not `while (true)`: c89 has no `bool`, and
            # this is the spelling both standards read the same way.
            return "\n".join([
                f"{pad}while (1) {{",
                _emit_block(body, standard, level + 1),
                f"{pad}}}",
            ])
        case CBreak(_):
            return f"{pad}break;"
        case CContinue(_):
            return f"{pad}continue;"
        case _:
            raise NotImplementedError(f"no printer for C statement {s!r}")


def _declaration(ctype, name, standard):
    """A variable declaration, e.g. `int x` or `const char *s`.
    String -> String -> String -> String"""
    text = _C_TYPES[standard][ctype]
    return f"{text}{name}" if text.endswith("*") else f"{text} {name}"


def _emit_block(stmts, standard, level):
    """A block's statements, indented to level; under c89, declarations
    are hoisted to the top (docs/target_c.md, "Declaration hoisting").
    [CStmt] -> String -> Int -> String"""
    pad = "    " * level
    if standard != "c89":
        return "\n".join(pprint_c_stmt(s, standard, level) for s in stmts)

    declarations = [
        f"{pad}{_declaration(s.ctype, s.name, standard)};"
        for s in stmts
        if isinstance(s, (CDecl, CVarDecl))
    ]
    body = []
    for s in stmts:
        if isinstance(s, CVarDecl):
            continue
        if isinstance(s, CDecl):
            body.append(f"{pad}{s.name} = {pprint_c_expr(s.init, standard)};")
        else:
            body.append(pprint_c_stmt(s, standard, level))
    if declarations:
        return "\n".join(declarations + [""] + body)
    return "\n".join(body)


def _comment(text, standard):
    """text as a comment in this standard's own style. String -> String
    -> String"""
    return f"/* {text} */" if standard == "c89" else f"// {text}"


# Written in the subset both standards accept, so one copy serves both
# (docs/target_c.md, "Strings").
_CONCAT_HELPER = """static const char *pyk_concat(const char *a, const char *b)
{
    size_t la = strlen(a);
    size_t lb = strlen(b);
    char *result = malloc(la + lb + 1);
    memcpy(result, a, la);
    memcpy(result + la, b, lb + 1);
    return result;
}"""


def _headers(program, standard):
    """The #include lines the program actually needs. CProgram -> String
    -> [String]"""
    needed = []
    if program.uses_print:
        needed.append("stdio.h")
    if program.uses_concat:
        needed.append("stdlib.h")
    if program.uses_concat or program.uses_strcmp:
        needed.append("string.h")
    return [f"#include <{header}>" for header in dict.fromkeys(needed)]


def pprint_c_program(program, standard, source="a Pyking program"):
    """The whole translation unit: headers, the string helper if used,
    the functions, and main. CProgram -> String -> String -> String"""
    if standard not in STANDARDS:
        raise NotImplementedError(f"unknown C standard {standard!r}")

    parts = [
        _comment(f"Generated from {source} by the Pyking compiler. Do not edit.",
                 standard),
        _comment(f"Target: {standard}. Compile with:  "
                 f"cc -std={standard} <this file>", standard),
    ]
    headers = _headers(program, standard)
    if headers:
        parts += ["", *headers]

    if program.uses_concat:
        parts += [
            "",
            _comment(
                "Concatenation allocates and never frees: Pyking has no "
                "ownership to compile into a free.", standard),
            _CONCAT_HELPER,
        ]

    def signature(func):
        params = (
            ", ".join(_declaration(ctype, name, standard)
                      for ctype, name in func.params)
            or "void"
        )
        return f"{_declaration(func.ret_type, func.name, standard)}({params})"

    if program.functions:
        # Prototypes for all of them, ahead of every definition. Pyking
        # lets a function be used before it is written -- recursion,
        # mutual recursion, a helper at the bottom of the file (see
        # PYKING.md, "Names and scoping") -- and C has to be told a
        # function exists before a call can name it. Emitting one for
        # every function rather than only the ones that need it keeps
        # this independent of the order the definitions happen to be in,
        # which is what the language says does not matter.
        parts += [
            "",
            _comment("Declared ahead of their definitions: a Pyking function "
                     "may be called before it is written.", standard),
            *[f"{signature(func)};" for func in program.functions],
        ]

    for func in program.functions:
        parts += [
            "",
            signature(func),
            "{",
            _emit_block(func.body, standard, 1),
            "}",
        ]

    parts += [
        "",
        "int main(void)",
        "{",
        _emit_block(program.main_body, standard, 1),
    ]
    parts += ["", "    return 0;", "}", ""]
    return "\n".join(parts)
