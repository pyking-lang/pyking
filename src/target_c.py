"""The C code-generation backend, for both the `c89` and `c23` targets.

One translation serves both standards: they differ in what the *printer*
emits, not in what the program means, so the difference is a `standard`
parameter threaded through the printer rather than two backends. What it
changes:

  standard  comments   declarations        booleans        headers
  --------  --------   ------------        --------        -------
  c89       /* ... */  hoisted to the      `int`, 1/0      as needed
                       top of each block
  c23       // ...     where they appear   `bool`,         as needed
                                           true/false      (no stdbool)

C is statically typed and Pyking is not, so this backend has to *infer* a
type for every binding, parameter and function. The types are the three
Pyking has values of -- integers, strings and booleans -- and inference
is deliberately simple:

  - a binding takes the type of its initializer;
  - a parameter takes its annotation when that annotation names a type C
    can represent, and is otherwise inferred from how the body uses it,
    falling back to `int`;
  - a function's return type is read back off the body once translated.

That is enough for a language with no polymorphism and no containers.
Where it is not enough, the backend refuses with a source position rather
than emitting C that will not compile -- see `docs/architecture.md`,
"What the C backends support".

Strings are `const char *`. Concatenation allocates and never frees:
Pyking has no notion of ownership to compile into one, so a generated
program leaks whatever it concatenates. That is acceptable for the
programs this backend targets and would not be for real ones; it is the
main thing standing between this and a serious C backend.
"""

from dataclasses import dataclass

from lexer import Info
import runtime_interface
from syntax import (
    EInt, EString, EBool, EVar,
    EAdd, ESub, EMul, EDiv, ENeg,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EIf,
    SLet, SVar, SMutate, SReturn, SReturnStmt, SExprStmt, SWhile, SIf, SFunctionDef,
    TargetName, TInt, TString, TBool,
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
    raise UnsupportedError(node.info, _CONSTRUCT_NAMES.get(message, message))


# --- types ---
#
# The three kinds of value a Pyking program in this subset can hold. They
# are kept as their own names rather than as C spellings because the C
# spelling of a boolean is one of the things the standards disagree about.

INT = "Int"
BOOL = "Bool"
STRING = "String"
# Pyking's unit type `()`. A function that produces no value has this as
# its return type -- `print` yields unit, and so does a body whose tail
# is a loop or a binding -- and C spells that `void`. Without it such a
# function would be typed `int` and simply fall off its end, which is
# undefined behaviour rather than merely untidy.
UNIT = "Unit"

_C_TYPES = {
    "c89": {INT: "int", BOOL: "int", STRING: "const char *", UNIT: "void"},
    "c23": {INT: "int", BOOL: "bool", STRING: "const char *", UNIT: "void"},
}

# How each type is printed, per `runtime_interface.PRINT`: integers in
# base 10, strings bare, booleans as `true`/`false` -- which C spells
# neither way (c89 has `1`/`0`, c23's `bool` prints the same via `%d`),
# so a boolean argument becomes a conditional expression.
_FORMATS = {INT: "%d", BOOL: "%s", STRING: "%s"}

_ANNOTATIONS = {TInt: INT, TString: STRING, TBool: BOOL}


def _annotated_type(annotation):
    """The type an annotation names, or `None` if it names one C has no
    representation for (a tuple or list). Nothing checks annotations, so
    an unrepresentable one is ignored in favour of inference rather than
    treated as an error -- `tests/types_tuples.pyk` annotates parameters
    as tuples and then passes integers."""
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


class CStmt:
    """Base class for the C statement AST."""


@dataclass(frozen=True)
class CDecl(CStmt):         # <type> name = init;
    info: Info
    ctype: str
    name: str
    init: CExpr


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
    """A translated program: the functions, the statements that become
    `main`, and which runtime helpers were used -- the last decides which
    headers the file needs, so that a program printing one integer does
    not drag in `<string.h>`."""
    functions: list
    main_body: list
    uses_print: bool = False
    uses_concat: bool = False
    uses_strcmp: bool = False


# --- scope ---
#
# C blocks are lexical scopes, as Pyking's are, so shadowing across blocks
# needs no help. Rebinding does: C has no way to declare one name twice in
# a block, and Pyking's `x = 1` then `x = 2` is two bindings -- which is
# convenient here, because the second may hold a different *type*, and two
# C variables is exactly what that needs.


@dataclass(frozen=True)
class Scope:
    # `outside` is what is in scope in the Pyking program but *not*
    # reachable from here -- the bindings around a function, which this
    # backend's functions cannot see. Kept so that reading one can say
    # why rather than claiming the name does not exist.
    outside: frozenset
    names: dict             # Pyking name -> (C name, type)
    block: frozenset


def _block_scope(scope):
    return Scope(scope.outside, scope.names, frozenset())


def _lookup(name, scope, info):
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
    """Carries an `Info` for `_unsupported` when the offending thing is a
    name rather than a node."""
    info: Info


# Names that are legal Pyking identifiers but reserved words in C, so a
# program with `def double(n):` would otherwise compile to code that will
# not parse. Covers C89, the C99/C11 additions, and the C23 keywords --
# one list for both standards, since a name renamed under c23 and not
# under c89 would make the two targets disagree about the generated code
# for no good reason. `main`, `printf` and the generated helpers are in
# here too: those are not keywords, but a Pyking function shadowing one
# would break the file just as thoroughly.
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
    taken = set(scope.names) | {c_name for c_name, _ in scope.names.values()}
    n = 2
    while f"{name}{n}" in taken or f"{name}{n}" in RESERVED:
        n += 1
    return f"{name}{n}"


def _bind(name, ctype, scope):
    c_name = name
    if (
        name in RESERVED
        or name in scope.names
        or any(name == c for c, _ in scope.names.values())
    ):
        c_name = _fresh_c_name(name, scope)
    return c_name, Scope(
        scope.outside,
        {**scope.names, name: (c_name, ctype)},
        scope.block | {name},
    )


# --- translation ---

_BINARY_OPS = {
    EAdd: "+", ESub: "-", EMul: "*",
    ELessThan: "<", ELessThanEq: "<=", EGreatThan: ">", EGreatThanEq: ">=",
}


class _Translator:
    """Holds what the walk accumulates: function signatures, and which
    runtime helpers have been used."""

    def __init__(self):
        self.signatures = {}    # Pyking name -> (C name, [param types], return type)
        self.declared = {}      # Pyking name -> C name, from the declaration pass
        self.defined = set()    # functions whose body has been translated
        self.called_early = set()   # ... and those called before that happened
        self.uses_print = False
        self.uses_concat = False
        self.uses_strcmp = False

    # -- expressions --

    def expr(self, e, scope, allow_unit=False):
        """`allow_unit` permits a call to a unit-returning (`void`)
        function, which is meaningful only as an expression statement --
        everywhere else there is no value to use."""
        match e:
            case EInt(info, v):
                return CInt(info, v)
            case EString(info, s):
                return CStr(info, s)
            case EBool(info, v):
                return CBool(info, v)
            case EVar(info, name):
                c_name, ctype = _lookup(name, scope, info)
                return CVar(info, c_name, ctype)
            case ENeg(info, operand):
                inner = self.expr(operand, scope)
                self._require(inner, INT, "negation")
                return CUnary(info, "-", inner, INT)
            case EDiv(info, _, _):
                _unsupported(
                    e,
                    "`/` is true division in Pyking and truncating integer "
                    "division in C; matching it needs a floating-point type "
                    "this backend does not have yet",
                )
            case EAdd(info, l, r):
                left, right = self.expr(l, scope), self.expr(r, scope)
                if left.ctype == STRING and right.ctype == STRING:
                    self.uses_concat = True
                    return CConcat(info, left, right)
                self._require(left, INT, "`+`")
                self._require(right, INT, "`+`")
                return CBinary(info, "+", left, right, INT)
            case EEq(info, l, r):
                left, right = self.expr(l, scope), self.expr(r, scope)
                if left.ctype == STRING and right.ctype == STRING:
                    self.uses_strcmp = True
                    return CStrEq(info, left, right)
                if left.ctype != right.ctype:
                    _unsupported(e, "`==` between values of different types")
                return CBinary(info, "==", left, right, BOOL)
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
                    # Typed from the signature registered ahead of the
                    # body; `function` checks that guess when the body
                    # arrives.
                    self.called_early.add(name)
                c_name, param_types, ret = self.signatures[name]
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
                return CCall(
                    info, c_name, [self.expr(a, scope) for a in args], ret
                )
            case ECall(info, _, _):
                _unsupported(e, "calling anything but a named function")
            case _ if type(e) in _BINARY_OPS:
                left, right = self.expr(e.left, scope), self.expr(e.right, scope)
                op = _BINARY_OPS[type(e)]
                self._require(left, INT, f"`{op}`")
                self._require(right, INT, f"`{op}`")
                ctype = INT if op in ("+", "-", "*") else BOOL
                return CBinary(e.info, op, left, right, ctype)
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
        return out, scope

    def tail_stmts(self, stmts, scope):
        """Translates a statement list whose last statement is in **tail
        position** -- a function body, or a branch of one that is itself
        in tail position -- so the value it produces becomes the
        function's return value. Mirrors `_translate_tail_block` in
        `target_python.py`; see PYKING.md's "Tail position"."""
        if not stmts:
            return []
        body, tail_scope = self.stmts(stmts[:-1], scope)
        return body + self.tail_stmt(stmts[-1], tail_scope)

    def tail_stmt(self, s, scope):
        """The last statement of a body in tail position, as a list of C
        statements: an expression becomes the returned value, an `if`
        pushes the rule into its branches, and anything else -- a loop, a
        binding, a `print` (which yields unit) -- translates normally."""
        match s:
            case SExprStmt(_, ECall(_, EVar(_, name), _)) if (
                runtime_interface.lookup(name) is not None
            ):
                translated, _ = self.stmt(s, scope)
                return [translated]
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
                c_name, scope = _bind(name, value.ctype, scope)
                return CDecl(info, value.ctype, c_name, value), scope

            case SLet(info, _, _):
                _unsupported(s, "tuple destructuring targets")

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
                # `return if c:` -- the same push-down as a tail-position
                # `if`, written explicitly so it also works before the
                # end of the body.
                return self.tail_stmt(stmt, scope)[0], scope

            case SExprStmt(info, ECall(_, EVar(_, name), args)) if (
                runtime_interface.lookup(name)
            ):
                self.uses_print = True
                return CPrint(info, [self.expr(a, scope) for a in args]), scope

            case SExprStmt(info, expr):
                return CExprStmt(info, self.expr(expr, scope, allow_unit=True)), scope

            case SWhile(info, cond, body):
                return CWhile(info, self.expr(cond, scope), self.block(body, scope)), scope

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
        """Registers every top-level `def`'s signature before any body is
        translated, so a call may name a function written further down --
        forward references and mutual recursion (see PYKING.md, "Names
        and scoping").

        C, unlike Java, does care about order: a call must have seen a
        declaration. That is what the prototypes `pprint_c_program`
        emits ahead of the definitions are for, and this pass is what
        makes the call itself translatable in the first place.

        The return type registered here is *provisional* -- the
        annotation, or `Int` for an unannotated function, since only its
        translated body can say otherwise. `function` checks that
        assumption once the body is in, which is why calls made before
        that point are remembered in `called_early`."""
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
        """Translates a `def`. Its signature is already registered (see
        `declare_functions`), which is what lets the body call itself,
        its siblings, and functions defined below it."""
        param_types = [_param_type(func, p) for p in func.params]
        if func.name in self.declared:
            c_name = self.declared[func.name]
        else:
            c_name, scope = _bind(func.name, INT, scope)
        provisional = _annotated_type(func.return_type) or INT
        self.signatures[func.name] = (c_name, param_types, provisional)

        # A function body starts from *nothing*: its parameters bind
        # into it below, and other functions are reached through
        # `self.signatures`. What it cannot see is the bindings around
        # it -- there are no closures here -- and `outside` remembers
        # those names so reading one says why (see `_lookup`).
        body_scope = Scope(frozenset(scope.names), {}, frozenset())
        params = []
        for param, ctype in zip(func.params, param_types):
            c_param, body_scope = _bind(param.name, ctype, body_scope)
            params.append((ctype, c_param))

        if func.expr is not None:
            value = self.expr(func.expr, body_scope)
            body = [CReturn(value.info, value)]
        else:
            # The body's last statement is in tail position: whatever
            # value it produces is the function's result.
            body = self.tail_stmts(func.body, body_scope)

        returned = _return_types(body)
        recursive = _calls(body, c_name)
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
        # that is unit, i.e. `void`, not the provisional `Int` it was
        # registered with (which would fall off the end -- UB).
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

        return CFunc(func.info, c_name, params, body, actual), scope


def _param_type(func, param):
    """A parameter's type: its annotation when C can represent it, else
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


def _walk_c(node):
    """Every C AST node under `node`, itself included."""
    from dataclasses import fields, is_dataclass

    if is_dataclass(node):
        yield node
        for f in fields(node):
            yield from _walk_c(getattr(node, f.name))
    elif isinstance(node, (list, tuple)):
        for element in node:
            yield from _walk_c(element)


def _falls_through(body):
    """Whether control can reach the end of `body` without returning.
    Falling off the end of a non-`void` function is undefined behaviour
    in C, so a function that can do it is refused rather than emitted --
    the same rule `target_java.py` enforces because `javac` demands it,
    here because the C standard does not and the compiler would happily
    produce a program that returns whatever was in the return register."""
    if not body:
        return True
    match body[-1]:
        case CReturn():
            return False
        case CIf(_, _, then_body, else_body) if else_body is not None:
            return _falls_through(then_body) or _falls_through(else_body)
        case _:
            return True


def _return_types(body):
    return {n.expr.ctype for n in _walk_c(body) if isinstance(n, CReturn)}


def _calls(body, c_name):
    return any(
        isinstance(n, CCall) and n.name == c_name for n in _walk_c(body)
    )


def translate_program(stmts):
    """External entry point: a whole Pyking program as a `CProgram`."""
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
    return CProgram(
        functions,
        main_body,
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
_CALL_PRECEDENCE = 16

_ESCAPES = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\t": "\\t", "\r": "\\r"}


def _quote(s):
    return '"' + "".join(_ESCAPES.get(ch, ch) for ch in s) + '"'


def _wrap(prec, min_prec, text):
    return f"({text})" if prec < min_prec else text


def _bool_literal(value, standard):
    if standard == "c23":
        return "true" if value else "false"
    return "1" if value else "0"


def pprint_c_expr(e, standard, min_prec=0):
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
        case _:
            raise NotImplementedError(f"no printer for C expression {e!r}")


def _print_argument(arg, standard):
    """A `printf` argument. A boolean becomes a conditional expression,
    since c89 spells its booleans `1`/`0` (c23's `bool` at least prints
    with `%d` the same way) but Pyking prints them `true`/`false`."""
    text = pprint_c_expr(arg, standard, _CONDITIONAL_PRECEDENCE + 1)
    if arg.ctype == BOOL:
        return f'{text} ? "true" : "false"'
    return pprint_c_expr(arg, standard)


def pprint_c_stmt(s, standard, level=1):
    pad = "    " * level
    match s:
        case CDecl(_, ctype, name, init):
            # Only reached for c23; c89 splits declarations out (see
            # `_c89_declarations`).
            return (
                f"{pad}{_declaration(ctype, name, standard)} = "
                f"{pprint_c_expr(init, standard)};"
            )
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
        case _:
            raise NotImplementedError(f"no printer for C statement {s!r}")


def _declaration(ctype, name, standard):
    """`int x`, `const char *s` -- the pointer star binds to the name, so
    the type text cannot simply be prefixed."""
    text = _C_TYPES[standard][ctype]
    return f"{text}{name}" if text.endswith("*") else f"{text} {name}"


def _emit_block(stmts, standard, level):
    """A block's statements. Under c89 every declaration is hoisted to the
    top -- C89 allows them only at the start of a block -- and what is
    left behind is the assignment, which may run anywhere. Because each
    binding already has a name of its own, hoisting cannot capture the
    wrong variable."""
    pad = "    " * level
    if standard != "c89":
        return "\n".join(pprint_c_stmt(s, standard, level) for s in stmts)

    declarations = [
        f"{pad}{_declaration(s.ctype, s.name, standard)};"
        for s in stmts
        if isinstance(s, CDecl)
    ]
    body = []
    for s in stmts:
        if isinstance(s, CDecl):
            body.append(f"{pad}{s.name} = {pprint_c_expr(s.init, standard)};")
        else:
            body.append(pprint_c_stmt(s, standard, level))
    if declarations:
        return "\n".join(declarations + [""] + body)
    return "\n".join(body)


def _comment(text, standard):
    return f"/* {text} */" if standard == "c89" else f"// {text}"


# Written in the subset both standards accept -- declarations before
# statements, no `//` -- so one helper serves c89 and c23 alike. Anything
# the standards disagree about lives in the printer, not here.
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
    """Only what the program actually uses. C23 needs no `<stdbool.h>` --
    `bool` is a keyword there -- but it still needs `<stdio.h>` for
    `printf`: C23 removed the need for some headers, not for all of them."""
    needed = []
    if program.uses_print:
        needed.append("stdio.h")
    if program.uses_concat:
        needed.append("stdlib.h")
    if program.uses_concat or program.uses_strcmp:
        needed.append("string.h")
    return [f"#include <{header}>" for header in dict.fromkeys(needed)]


def pprint_c_program(program, standard, source="a Pyking program"):
    """The whole translation unit: headers, the string helper if used, the
    program's functions, and `main` holding its top-level statements."""
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
