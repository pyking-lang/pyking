"""The OCaml code-generation backend.

OCaml fits Pyking better than any other target here, and the generated
code shows it. Three things line up exactly:

  - **Scoping.** A Pyking block is a scope and a rebinding is a *new*
    binding; OCaml's `let ... in` is both. Nothing has to be renamed the
    way `target_python.py` renames, and nothing has to be hoisted.
  - **Spelling.** `true`, `false` and `()` are written the same way in
    both languages, so the value-formatting contract in
    `runtime_interface.py` needs no conversion for booleans or unit.
  - **Recursion.** Pyking makes every `def` in a block visible
    throughout it, which is what `let rec ... and ...` says in OCaml.
    Mutual recursion, a helper written below its use, and a plain
    recursive function are one construct there and one here.

**The subset is exactly what `src/typesystem.py` accepts.** Rather than
inferring types a second time, this backend *runs the checker* and reads
the types back out of its `tmap` (see `check_expr` there, which records
one for every expression). A program that does not type-check is refused
before translation begins, with the checker's own message. That is why
this is the only backend with no inference of its own -- and why its
list of unsupported constructs is short: the checker has already turned
most of them away.

Two things it refuses that the checker accepts, both because OCaml has
no way to say them:

  - a `return` that is not in tail position and is not a guard --
    OCaml expressions have no early exit;
  - a `def` that names another `def` written further down and *not*
    beside it, since `let rec ... and ...` binds a group that has to be
    written together.

And one thing the languages disagree about quietly rather than loudly:
Pyking evaluates an operator's operands, and a call's arguments, left to
right, and OCaml leaves the order unspecified. That is only observable
when two of them print, so `_Effects` works out which expressions can
and `in_order` pins those down with a `let`. A program whose functions
only compute pays nothing for it.

**The generated code carries no type annotations.** OCaml infers them,
and a program that says `let f (n : int) : int = ...` reads worse than
`let f n = ...` while proving nothing extra -- the types were already
checked before a line of this was emitted. The same instinct runs
through the rest of the output: `let rec` only where something recurses,
`and` only between functions that really do name each other, `_name`
for a binding nothing reads, and no parentheses that OCaml's own
precedence does not need. What the compiler would warn about, the
generator answers in advance -- `tests/test_script.py` builds every
OCaml case with `-w +a` so that a warning is a failing test.
"""

from dataclasses import dataclass

import runtime_interface
import typesystem
from analyses import AnalysisError
from syntax import (
    pprint_type,
    EInt, EString, EBool, EVar,
    EAdd, ESub, EMul, ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq,
    ECall, EIf,
    SLet, SLetStmt, SReturn, SReturnStmt, SExprStmt, SIf, SFunctionDef,
    TargetName, TInt, TString, TBool, TList, TTuple,
)

TARGET = "ocaml"
EXTENSION = ".ml"


class UnsupportedError(Exception):
    """Raised for a Pyking construct this backend cannot compile; carries
    the source position, like the other stages' errors."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


def _unsupported(node, message):
    raise UnsupportedError(node.info, message)


# --- the OCaml AST ---
#
# OCaml is an expression language, so this is much smaller than the C,
# Java or Python ASTs: a block of Pyking statements becomes *one*
# expression, and the only statement-shaped thing left is the top level.
#
# datatype OExpr:
#     OInt(value: Int)
#     OStr(value: String)
#     OBool(value: Bool)
#     OUnit()
#     OVar(name: String)                       a name, already mangled
#     OApp(func: OExpr, args: [OExpr])         f x y
#     OBin(op: String, left: OExpr, right: OExpr)
#     OIf(cond: OExpr, then_: OExpr, else_: OExpr?)
#     OLet(bindings: [OBinding], body: OExpr, recursive: Bool)
#                                              let a = x and b = y in body
#     OSeq(first: OExpr, rest: OExpr)          first; rest
#     OIgnore(expr: OExpr)                     ignore (expr)
#
# datatype OItem:                              one top-level definition
#     OItemLet(bindings: [OBinding], recursive: Bool)
#     OItemUnit(expr: OExpr)                   let () = expr
#
# datatype OBinding:
#     OBinding(name: String, params: [String], value: OExpr)


@dataclass(frozen=True)
class OExpr:
    """Base class for the OCaml expression AST."""


@dataclass(frozen=True)
class OInt(OExpr):
    value: int


@dataclass(frozen=True)
class OStr(OExpr):
    value: str


@dataclass(frozen=True)
class OBool(OExpr):
    value: bool


@dataclass(frozen=True)
class OUnit(OExpr):
    pass


@dataclass(frozen=True)
class OVar(OExpr):
    name: str


@dataclass(frozen=True)
class OApp(OExpr):
    func: OExpr
    args: list


@dataclass(frozen=True)
class OBin(OExpr):
    op: str
    left: OExpr
    right: OExpr


@dataclass(frozen=True)
class OIf(OExpr):
    cond: OExpr
    then_: OExpr
    else_: OExpr = None


@dataclass(frozen=True)
class OBinding:
    name: str
    params: list
    value: OExpr


@dataclass(frozen=True)
class OLet(OExpr):
    bindings: list
    body: OExpr
    recursive: bool = False


@dataclass(frozen=True)
class OSeq(OExpr):
    first: OExpr
    rest: OExpr


@dataclass(frozen=True)
class OIgnore(OExpr):
    expr: OExpr


@dataclass(frozen=True)
class OItemLet:
    bindings: list
    recursive: bool = False


@dataclass(frozen=True)
class OItemUnit:
    expr: OExpr


@dataclass(frozen=True)
class OProgram:
    items: list
    needs_list_printer: bool = False


# --- names ---
#
# An OCaml value name must start with a lowercase letter or an
# underscore -- one starting with a capital is a constructor -- and must
# not be a keyword. Both are fixed by mangling, and only when they have
# to be, so an ordinary Pyking name reaches the output unchanged.

RESERVED = frozenset("""
and as assert asr begin class constraint do done downto else end
exception external false for fun function functor if in include inherit
initializer land lazy let lor lsl lsr lxor match method mod module
mutable new nonrec object of open or private rec sig struct then to true
try type val virtual when while with
""".split())


def _mangle(name):
    """`name` as a legal OCaml value name."""
    if name in RESERVED:
        return name + "_"
    if name[:1].isupper():
        return "v_" + name
    return name


# --- what can print ---
#
# The one thing a Pyking expression can do besides produce a value is
# print, and the only reason this backend has to care is *order*: Pyking
# runs an operator's operands left to right, OCaml leaves the order
# unspecified. Two operands that both print are the only case where the
# difference is visible, so this is the analysis that says which
# expressions those are -- and it is deliberately cheap and
# conservative, because being wrong in the other direction would mean
# a program that prints in the wrong order.


class _Effects:
    """Which calls in a program can end up printing.

    `print` is the only host operation there is, so this is a walk of the
    call graph: a function prints if it calls `print`, or calls a
    function that does. Names are read across the whole program rather
    than per scope -- a shadowed name is rare and counting both meanings
    can only make the answer more cautious than it needs to be.

    A call whose target is not a `def` -- a parameter of function type, a
    binding holding a function -- could be anything, so it is treated as
    printing if *any* function in the program prints. In a program where
    none does, nothing needs ordering and every expression stays exactly
    where the source put it."""

    def __init__(self, stmts):
        self.functions = _all_functions(stmts)
        self.printing = set()
        # What an unknown callee has to be assumed to do. It starts as
        # "nothing" and turns on as soon as any function is found to
        # print, which can make more functions print in turn -- so the
        # two grow together until neither changes.
        self.unknown_prints = False
        changed = True
        while changed:
            changed = False
            for name, func in self.functions.items():
                if name not in self.printing and self._body_prints(func):
                    self.printing.add(name)
                    changed = True
            if self.printing and not self.unknown_prints:
                self.unknown_prints = True
                changed = True

    def _body_prints(self, func):
        for node in _walk(func):
            if isinstance(node, ECall) and self._call_prints(node):
                return True
        return False

    def _call_prints(self, call):
        match call.func:
            case EVar(_, name, _):
                if runtime_interface.lookup(name) is not None:
                    return True
                if name in _BUILTINS:
                    return False
                if name in self.functions:
                    return name in self.printing
        return self.unknown_prints

    def may_print(self, expr):
        """Whether evaluating `expr` can produce output."""
        return any(
            isinstance(node, ECall) and self._call_prints(node)
            for node in _walk(expr)
        )


def _all_functions(stmts):
    """Every `def` in the program, at any depth, by name."""
    functions = {}
    for node in _walk(stmts):
        if isinstance(node, SFunctionDef):
            functions[node.name] = node
    return functions


def _walk(node):
    """Every node in a tree, the tree itself included. Generic over
    dataclass fields, the way `analyses.symbolize` is, so a construct
    added to `syntax.py` is covered without touching this."""
    if isinstance(node, list):
        for item in node:
            yield from _walk(item)
    elif hasattr(node, "__dataclass_fields__"):
        yield node
        for field_name in node.__dataclass_fields__:
            yield from _walk(getattr(node, field_name))


def _unused_prefix(stmts):
    """A prefix no name in the program starts with, for the temporaries
    that fix evaluation order. Underscore-led, so OCaml never warns about
    one that ends up unread."""
    names = {
        getattr(node, "name")
        for node in _walk(stmts)
        if isinstance(getattr(node, "name", None), str)
    }
    prefix = "_pyk"
    while any(name.startswith(prefix) for name in names):
        prefix += "_"
    return prefix


# --- translation ---


def translate_program(stmts):
    """A whole Pyking program as an `OProgram`.

    The program is type-checked first: this backend compiles what the
    checker accepts and reads its types back, so a program it would
    refuse has no business reaching the translation below."""
    tmap = _checked_types(stmts)
    translator = _Translator(tmap, stmts)
    items = _polish_items(translator.items(stmts))
    return OProgram(items, translator.needs_list_printer)


def _checked_types(stmts):
    """The checker's `tmap` for this program, or a refusal that says the
    program has to type-check first.

    The checker's own message is kept -- it is more specific than
    anything this backend could say about a construct it never reached --
    and merely framed as this target's limitation, which is what it is."""
    try:
        return typesystem.type_check(stmts)
    except (typesystem.TypeError_, AnalysisError) as e:
        raise UnsupportedError(
            e.info,
            f"this target compiles only programs that type-check, and this "
            f"one does not: {e.message}",
        ) from None


class _Translator:
    """Holds the checker's types, and whether the list printer was
    needed -- the one piece of prelude this backend can emit."""

    def __init__(self, tmap, stmts):
        self.tmap = tmap
        self.needs_list_printer = False
        self.printing = _Effects(stmts)
        # A name for a temporary the source cannot have written: no
        # Pyking name in the program starts with it.
        self.temporary_prefix = _unused_prefix(stmts)
        self.temporaries = 0

    # -- top level --

    def items(self, stmts):
        """The top level, as a list of OCaml items.

        A Pyking binding becomes a top-level `let`, which is sequential
        in OCaml exactly as it is in Pyking, so rebinding a name needs
        nothing special: the second `let` shadows the first. Runs of
        statements that are not bindings become one `let () = ...`.
        """
        items = []
        index = 0
        while index < len(stmts):
            statement = stmts[index]
            if isinstance(statement, SFunctionDef):
                run = _function_run(stmts, index)
                later = _later_functions(stmts[index + len(run):])
                items += [
                    OItemLet(bindings, recursive)
                    for bindings, recursive in self.groups(run, later)
                ]
                index += len(run)
                continue
            if isinstance(statement, (SLet, SLetStmt)):
                items.append(OItemLet([self.binding(statement)]))
                index += 1
                continue
            # A run of statements with nothing to bind: one `let () =`.
            run = []
            while index < len(stmts) and not isinstance(
                stmts[index], (SLet, SLetStmt, SFunctionDef)
            ):
                run.append(stmts[index])
                index += 1
            items.append(OItemUnit(self.effects(run)))
        return items

    def groups(self, run, later=frozenset()):
        """A run of consecutive `def`s, translated and split into the
        smallest groups that still see each other, each as
        `(bindings, recursive)` -- what both a top-level `let` and a
        `let ... in` need to be built from.

        Pyking makes every `def` in a block visible throughout it, and one
        `let rec ... and ...` over the whole run would say exactly that --
        but it would also say that two unrelated functions are mutually
        recursive, which reads badly and is not what the source meant. So
        a group is closed as soon as nothing in it names anything further
        down: two independent helpers become two plain `let`s, and only
        functions that really do refer to each other end up in one `and`
        chain.

        The splitting reads the *translated* bindings rather than the
        Pyking ones, because only there are the binders explicit: a body
        that shadows the function's own name with a local `let` mentions
        that name without recursing, and a free-variable walk sees the
        difference where a search for the name alone would not."""
        bindings = [self.function_binding(f) for f in run]
        free = [_free_in_binding(b) for b in bindings]
        _check_no_split_group(run, free, later)

        groups = []
        start = 0
        while start < len(bindings):
            end = start + 1
            while end < len(bindings):
                reaching = set().union(*free[start:end])
                if not reaching & {b.name for b in bindings[end:]}:
                    break
                end += 1
            names = {b.name for b in bindings[start:end]}
            groups.append(
                (
                    bindings[start:end],
                    bool(names & set().union(*free[start:end])),
                )
            )
            start = end
        return groups

    # -- statements --

    def binding(self, statement):
        """A `=` binding, as one OCaml binding."""
        match statement:
            case SLet(_, TargetName(_, name, _), expr, _, _):
                value = self.expr(expr)
            case SLetStmt(_, TargetName(_, name, _), stmt, _, _):
                value = self.value_stmt(stmt)
            case _:
                _unsupported(statement, "a binding that destructures a tuple")
        return OBinding(_mangle(name), [], value)

    def function_binding(self, func):
        params = [_mangle(p.name) for p in func.params]
        if func.expr is not None:
            return OBinding(_mangle(func.name), params, self.expr(func.expr))
        return OBinding(_mangle(func.name), params, self.body(func.body))

    def body(self, stmts):
        """A function body: a block whose last statement is its value."""
        return self.block(stmts, tail=True)

    def effects(self, stmts):
        """A block run only for what it does -- the top level's
        statements, or a branch that produces nothing."""
        return self.block(stmts, tail=False)

    def block(self, stmts, tail):
        """A statement sequence as one expression.

        `tail` says whether the last statement supplies a value (a
        function body) or the block is run for its effects (the top
        level, or a branch of a unit-valued `if`). Everything before the
        last statement becomes a `let ... in` or a `;` -- which is
        precisely the shape a Pyking block already has."""
        if not stmts:
            return OUnit()

        first, rest = stmts[0], stmts[1:]

        # A guard: `if c: return x` with statements after it is the one
        # early return OCaml can express -- as the `else` of the same
        # `if`. Without this, ordinary guard-style code would be refused.
        if rest and isinstance(first, SIf) and first.else_body is None:
            if _definitely_returns(first.then_body):
                return OIf(
                    self.expr(first.cond),
                    self.block(first.then_body, tail),
                    self.block(rest, tail),
                )

        if not rest:
            return self.last(first, tail)

        match first:
            case SLet() | SLetStmt():
                return OLet([self.binding(first)], self.block(rest, tail))
            case SFunctionDef():
                run = _function_run(stmts, 0)
                body = self.block(stmts[len(run):], tail)
                later = _later_functions(stmts[len(run):])
                # Innermost group last, so the `let`s nest in source order.
                for bindings, recursive in reversed(self.groups(run, later)):
                    body = OLet(bindings, body, recursive)
                return body
            case SReturn() | SReturnStmt():
                _unsupported(
                    first,
                    "a `return` with statements after it: OCaml has no early "
                    "exit, so only a `return` in tail position -- or one "
                    "guarding the rest of the body -- can be compiled",
                )
            case _:
                return OSeq(self.discard(first), self.block(rest, tail))

    def last(self, statement, tail):
        """The final statement of a block."""
        match statement:
            case SExprStmt(_, expr, _) if tail:
                return self.expr(expr)
            case SReturn(_, expr, _):
                return self.expr(expr)
            case SReturnStmt(_, stmt, _):
                return self.value_stmt(stmt)
            case SIf(_, cond, then_body, else_body, _):
                return OIf(
                    self.expr(cond),
                    self.block(then_body, tail),
                    None if else_body is None else self.block(else_body, tail),
                )
            case SLet() | SLetStmt():
                # A block ending in a binding supplies no value -- the
                # checker gives such a body the unit type -- and the
                # binding cannot be seen from outside the block, so `in
                # ()` is the whole of it.
                return OLet([self.binding(statement)], OUnit())
            case SFunctionDef():
                [(bindings, recursive)] = self.groups([statement])
                return OLet(bindings, OUnit(), recursive)
            case _ if tail:
                _unsupported(
                    statement,
                    f"{type(statement).__name__} as the value of a function",
                )
            case _:
                return self.discard(statement)

    def value_stmt(self, stmt):
        """An `if` in value form -- `x = if c: ...` or `return if c:`."""
        match stmt:
            case SIf(_, cond, then_body, else_body, _):
                if else_body is None:
                    _unsupported(stmt, "a value-form `if` with no `else`")
                return OIf(
                    self.expr(cond),
                    self.block(then_body, tail=True),
                    self.block(else_body, tail=True),
                )
        _unsupported(stmt, f"{type(stmt).__name__} in value position")

    def discard(self, statement):
        """A statement run for its effect, in a position where its value
        is thrown away."""
        match statement:
            case SExprStmt(_, expr, _):
                translated = self.expr(expr)
                if _is_unit(self.type_of(expr)):
                    return translated
                return OIgnore(translated)
            case SIf(_, cond, then_body, else_body, _):
                return OIf(
                    self.expr(cond),
                    self.effects(then_body),
                    None if else_body is None else self.effects(else_body),
                )
        _unsupported(statement, f"{type(statement).__name__} in this position")

    # -- expressions --

    def type_of(self, expr):
        """The type the checker gave this expression."""
        return self.tmap[expr.sym]

    def expr(self, e):
        match e:
            case EInt(_, value, _):
                return OInt(value)
            case EString(_, value, _):
                return OStr(value)
            case EBool(_, value, _):
                return OBool(value)
            case EVar(_, name, _):
                return OVar(_mangle(name))
            case EIf(_, cond, then_expr, else_expr, _):
                return OIf(self.expr(cond), self.expr(then_expr), self.expr(else_expr))
            case ECall(_, EVar(_, name, _), args, _) if (
                runtime_interface.lookup(name) is not None
            ):
                return self.print_call(e, args)
            case ECall(_, EVar(_, name, _), args, _) if name in _BUILTINS:
                return self.builtin_call(e, name, args)
            case ECall(_, func, args, _):
                pieces, sequence = self.in_order([func] + list(args))
                return sequence(OApp(pieces[0], pieces[1:]))
            case EAdd(_, left, right, _):
                # One Pyking operator, two OCaml ones: `+` adds and `^`
                # concatenates, and which is meant is a question about
                # types -- which the checker has already answered.
                return self.binary("^" if _is_string(self.type_of(e)) else "+",
                                   left, right)
            case ESub(_, left, right, _):
                return self.binary("-", left, right)
            case EMul(_, left, right, _):
                return self.binary("*", left, right)
            case ELessThan(_, left, right, _):
                return self.binary("<", left, right)
            case ELessThanEq(_, left, right, _):
                return self.binary("<=", left, right)
            case EGreatThan(_, left, right, _):
                return self.binary(">", left, right)
            case EGreatThanEq(_, left, right, _):
                return self.binary(">=", left, right)
            case EEq(_, left, right, _):
                # OCaml's `=` is structural equality, which is what
                # Pyking's `==` means for every type it compares.
                return self.binary("=", left, right)
        _unsupported(e, f"{type(e).__name__}")

    def binary(self, op, left, right):
        pieces, sequence = self.in_order([left, right])
        return sequence(OBin(op, pieces[0], pieces[1]))

    def in_order(self, exprs):
        """`exprs` translated, plus a wrapper that pins down the order
        they run in.

        Pyking evaluates left to right and OCaml leaves the order of an
        operator's operands, and of a call's arguments, unspecified -- in
        practice right to left. That is invisible unless two of them can
        *print*, so when two of them can, the earlier ones are pulled out
        into `let`s, which is the one construct that does fix the order.
        A program whose functions only compute -- almost every program --
        keeps operands where the source wrote them and pays nothing."""
        translated = [self.expr(e) for e in exprs]
        effectful = [i for i, e in enumerate(exprs) if self.printing.may_print(e)]
        if len(effectful) < 2:
            return translated, lambda result: result

        # The last one may stay where it is: nothing after it can be
        # pulled ahead of something that no longer has anything to say.
        bindings = []
        for index in effectful[:-1]:
            name = self.fresh_name()
            bindings.append(OBinding(name, [], translated[index]))
            translated[index] = OVar(name)

        def sequence(result):
            for binding in reversed(bindings):
                result = OLet([binding], result)
            return result

        return translated, sequence

    def fresh_name(self):
        self.temporaries += 1
        return f"{self.temporary_prefix}{self.temporaries}"

    # -- the host operations --

    def print_call(self, call, args):
        """`print(...)`: the arguments formatted per
        `runtime_interface.py` and written as one line.

        OCaml spells booleans and unit exactly as Pyking does, so the
        only conversion is to a string; a single string argument needs
        not even that."""
        if not args:
            return OApp(OVar("print_newline"), [OUnit()])
        ordered, sequence = self.in_order(args)
        pieces = [self.as_string(a, t) for a, t in zip(args, ordered)]
        separated = [pieces[0]]
        for piece in pieces[1:]:
            separated += [OStr(" "), piece]
        # `^` is right-associative, so a chain nested to the right prints
        # as `a ^ " " ^ b` with no parentheses at all.
        text = separated[-1]
        for piece in reversed(separated[:-1]):
            text = OBin("^", piece, text)
        return sequence(OApp(OVar("print_endline"), [text]))

    def as_string(self, arg, translated=None):
        """One printed argument, as an OCaml string expression.

        `translated` is the argument's OCaml form when the caller has
        already produced it -- `print_call` has, since fixing the order
        its arguments run in may have replaced one with a name."""
        type_ = self.type_of(arg)
        if translated is None:
            translated = self.expr(arg)
        if _is_string(type_):
            return translated
        if _is_int(type_):
            return OApp(OVar("string_of_int"), [translated])
        if _is_bool(type_):
            return OApp(OVar("string_of_bool"), [translated])
        if _is_unit(type_):
            # Unit prints as `()`, and the expression still has to run:
            # `(e; "()")` does both.
            if isinstance(translated, OUnit):
                return OStr("()")
            return OSeq(translated, OStr("()"))
        if _is_int_list(type_):
            self.needs_list_printer = True
            return OApp(OVar(_LIST_PRINTER), [translated])
        _unsupported(arg, f"printing a value of type {_name_of(type_)}")

    def builtin_call(self, call, name, args):
        match name, args:
            case "str", [value]:
                return self.as_string(value)
            case "len", [value]:
                type_ = self.type_of(value)
                if _is_string(type_):
                    return OApp(OVar("String.length"), [self.expr(value)])
                if _is_int_list(type_):
                    return OApp(OVar("List.length"), [self.expr(value)])
                _unsupported(call, f"`len` of a value of type {_name_of(type_)}")
            case "range", [count]:
                return OApp(
                    OVar("List.init"),
                    [self.expr(count), OVar("Fun.id")],
                )
            case "range", _:
                _unsupported(
                    call, "`range` with more than one argument is not supported yet"
                )
        _unsupported(call, f"the builtin `{name}` is not supported yet")


_BUILTINS = ("str", "len", "range")

# The one prelude this backend has. A Pyking list prints the way Python
# prints it -- `[0, 1]` -- and OCaml's own list syntax uses `;`, so the
# separator is spelled out here rather than borrowed.
_LIST_PRINTER = "pyk_string_of_int_list"
_LIST_PRINTER_DEF = f"""let {_LIST_PRINTER} xs =
  "[" ^ String.concat ", " (List.map string_of_int xs) ^ "]\""""


# --- grouping `def`s ---


def _later_functions(stmts):
    """The names the `def`s in `stmts` bind, as OCaml spells them."""
    return frozenset(
        _mangle(s.name) for s in stmts if isinstance(s, SFunctionDef)
    )


def _function_run(stmts, start):
    """The run of consecutive `def`s beginning at `start`.

    A run is what a `let` group can be built from: OCaml binds mutually
    recursive functions with `let rec ... and ...`, which has to be
    written together, so a `def` separated from the one it names by
    anything that is not a `def` cannot be part of the same group. See
    `_check_no_split_group` for what happens when the source does that."""
    run = []
    index = start
    while index < len(stmts) and isinstance(stmts[index], SFunctionDef):
        run.append(stmts[index])
        index += 1
    return run


def _check_no_split_group(run, free, later):
    """Refuses a `def` that names one written further down in the same
    block, with something other than a `def` in between.

    Pyking makes such a reference legal -- every `def` in a block is
    visible throughout it. OCaml can express that only for functions
    written as one `let rec ... and ...` group, and a group has to be
    written together; moving it down past the statement in between would
    change which bindings its bodies see, which is the one thing this
    backend must not do quietly. Only a name the block binds further down
    can be the problem: anything else is a builtin or an enclosing
    binding, which OCaml resolves exactly as Pyking does."""
    names = {f.name for f in run}
    for func, used in zip(run, free):
        reached = sorted((used & later) - names)
        if reached:
            _unsupported(
                func,
                f"`{func.name}` names `{reached[0]}`, which is written further "
                "down with something in between: OCaml binds a group of "
                "mutually recursive functions with `let rec ... and ...`, "
                "which has to be written together",
            )


# --- free variables of the generated OCaml ---
#
# Every question this backend asks about names -- is this group
# recursive, is this parameter used, does this function reach one written
# further down -- is a question about *free* variables, and the OCaml AST
# is where the binders are explicit enough to answer it. A body that
# shadows the function's own name with a local `let` mentions that name
# without recursing, and only a walk that knows `let` binds can tell the
# difference.


def _free(e):
    """Every name `e` reads from outside itself."""
    match e:
        case OInt() | OStr() | OBool() | OUnit():
            return frozenset()
        case OVar(name):
            return frozenset([name])
        case OIgnore(expr):
            return _free(expr)
        case OApp(func, args):
            return _free(func).union(*[_free(a) for a in args]) if args else _free(func)
        case OBin(_, left, right):
            return _free(left) | _free(right)
        case OIf(cond, then_, else_):
            found = _free(cond) | _free(then_)
            return found if else_ is None else found | _free(else_)
        case OSeq(first, rest):
            return _free(first) | _free(rest)
        case OLet(bindings, body, recursive):
            names = {b.name for b in bindings}
            values = frozenset().union(*[_free_in_binding(b) for b in bindings])
            if recursive:
                values -= names
            return values | (_free(body) - names)
    raise NotImplementedError(f"no free variables defined for {e!r}")


def _free_in_binding(binding):
    """A binding's free names: its value's, less its own parameters."""
    return _free(binding.value) - set(binding.params)


# --- unused names ---
#
# OCaml warns about a bound name nothing reads, and a reader of generated
# code has no way to act on such a warning. So the generator answers it
# in advance, the way an OCaml programmer would: a name that is bound and
# not read is written `_name`, which says "deliberately discarded" and is
# exactly what these bindings are -- Pyking's `x = expr` is a statement,
# so a program may well write one purely to run the expression.
#
# A top-level binding is usually exempt: a module without an interface
# exports every name it binds, so nothing there is unread. The exception
# is a name a later `let` rebinds -- Pyking allows that and OCaml does
# too, but the earlier binding is then neither read nor exported, which is
# the one case OCaml complains about at the top level.


def _polish_items(items):
    """The top level, polished. Read back to front, because whether a
    binding is live depends only on what comes after it: a name is live
    if some later item reads it before another rebinds it, and one that
    survives to the end of the module is exported and so live too."""
    polished = []
    for index, item in enumerate(items):
        match item:
            case OItemLet(bindings, recursive):
                bindings = [
                    _rename_dead(b, items[index + 1:]) for b in bindings
                ]
                polished.append(OItemLet(bindings, recursive))
            case OItemUnit(expr):
                polished.append(OItemUnit(_polish(expr)))
            case _:
                raise NotImplementedError(f"no polishing defined for {item!r}")
    return polished


def _rename_dead(binding, later):
    """`binding`, renamed `_name` if no later item reads it before one
    rebinds it."""
    binding = _polish_binding(binding)
    for item in later:
        if binding.name in _free_in_item(item):
            return binding
        if binding.name in _item_names(item):
            return OBinding("_" + binding.name, binding.params, binding.value)
    return binding


def _free_in_item(item):
    match item:
        case OItemLet(bindings, recursive):
            free = frozenset().union(*[_free_in_binding(b) for b in bindings])
            return free - _item_names(item) if recursive else free
        case OItemUnit(expr):
            return _free(expr)
    raise NotImplementedError(f"no free variables defined for item {item!r}")


def _item_names(item):
    match item:
        case OItemLet(bindings, _):
            return frozenset(b.name for b in bindings)
        case OItemUnit():
            return frozenset()
    raise NotImplementedError(f"no bound names defined for item {item!r}")


def _polish_binding(binding):
    """A binding with its unread parameters renamed and its value
    polished."""
    value = _polish(binding.value)
    used = _free(value)
    params = [p if p in used else "_" + p for p in binding.params]
    return OBinding(binding.name, params, value)


def _polish(e):
    match e:
        case OInt() | OStr() | OBool() | OUnit() | OVar():
            return e
        case OIgnore(expr):
            return OIgnore(_polish(expr))
        case OApp(func, args):
            return OApp(_polish(func), [_polish(a) for a in args])
        case OBin(op, left, right):
            return OBin(op, _polish(left), _polish(right))
        case OIf(cond, then_, else_):
            return OIf(
                _polish(cond),
                _polish(then_),
                None if else_ is None else _polish(else_),
            )
        case OSeq(first, rest):
            return OSeq(_polish(first), _polish(rest))
        case OLet(bindings, body, recursive):
            bindings = [_polish_binding(b) for b in bindings]
            body = _polish(body)
            # A binding a sibling reads is read, even if the body does
            # not -- which is how one half of a mutually recursive pair
            # earns its name.
            used = _free(body)
            if recursive:
                used = used.union(*[_free_in_binding(b) for b in bindings])
            bindings = [
                b if b.name in used else OBinding("_" + b.name, b.params, b.value)
                for b in bindings
            ]
            return OLet(bindings, body, recursive)
    raise NotImplementedError(f"no polishing defined for {e!r}")


def _definitely_returns(stmts):
    """Whether a block always leaves by a `return` -- the same reading
    `target_java.py` and the type checker take."""
    match stmts:
        case [*_, SReturn() | SReturnStmt()]:
            return True
        case [*_, SIf(_, _, then_body, else_body)]:
            return (
                else_body is not None
                and _definitely_returns(then_body)
                and _definitely_returns(else_body)
            )
        case _:
            return False


# --- reading the checker's types ---


def _is_int(t):
    return isinstance(t, TInt)


def _is_string(t):
    return isinstance(t, TString)


def _is_bool(t):
    return isinstance(t, TBool)


def _is_unit(t):
    return isinstance(t, TTuple) and not t.elements


def _is_int_list(t):
    return isinstance(t, TList) and isinstance(t.element, TInt)


def _name_of(t):
    return pprint_type(t)


# --- printer: OCaml AST -> OCaml source text ---
#
# Precedence, loosest to tightest. Only what this backend emits is
# listed; a child printed where a tighter level is required gets
# parentheses, which is the whole of the rule.

_SEQ, _LET, _IF, _CMP, _CONCAT, _ADD, _MUL, _APP, _ATOM = range(1, 10)

_OP_LEVEL = {
    "=": _CMP, "<": _CMP, "<=": _CMP, ">": _CMP, ">=": _CMP,
    "^": _CONCAT,
    "+": _ADD, "-": _ADD,
    "*": _MUL,
}


def pprint_ocaml_program(program, source="a Pyking program"):
    """The whole module: a header, the prelude if it was needed, and one
    blank line between top-level items."""
    parts = [
        f"(* Generated from {source} by the Pyking compiler. Do not edit. *)",
        "(* Target: ocaml. Compile with:  ocamlfind ocamlopt <this file>",
        "   or run it directly with:      ocaml <this file> *)",
    ]
    if program.needs_list_printer:
        parts += ["", _LIST_PRINTER_DEF]
    for item in program.items:
        parts += ["", _pprint_item(item)]
    return "\n".join(parts) + "\n"


def _pprint_item(item):
    match item:
        case OItemLet(bindings, recursive):
            keyword = "let rec" if recursive else "let"
            lines = []
            for index, binding in enumerate(bindings):
                lines.append(
                    _pprint_binding(binding, keyword if index == 0 else "and", 0)
                )
            return "\n".join(lines)
        case OItemUnit(expr):
            return _pprint_binding(OBinding("()", [], expr), "let", 0)
    raise NotImplementedError(f"no OCaml printing for item {item!r}")


def _pprint_binding(binding, keyword, level):
    """`let name params =` with its value, laid out the way OCaml is
    normally written: a short value on the same line, anything longer on
    its own indented line."""
    pad = "  " * level
    head = " ".join([keyword, binding.name] + binding.params) + " ="
    value = _pprint(binding.value, _SEQ, level + 1)
    if "\n" not in value and len(pad) + len(head) + 1 + len(value) <= 72:
        return f"{pad}{head} {value.lstrip()}"
    return f"{pad}{head}\n{_indent(value, level + 1)}"


def _indent(text, level):
    pad = "  " * level
    return "\n".join(pad + line if line else line for line in text.split("\n"))


def _pprint(e, need, level):
    """One expression, parenthesized when the context needs it tighter
    than the expression binds."""
    text, level_of = _pprint_bare(e, level)
    if level_of < need:
        if "\n" in text:
            return "(" + text + ")"
        return f"({text})"
    return text


def _pprint_bare(e, level):
    """`(text, precedence)` for an expression, unparenthesized."""
    match e:
        case OInt(value):
            # A negative literal has to be parenthesized wherever it is
            # used, so it is given the loosest level and the rule above
            # does the rest.
            return (str(value), _ATOM if value >= 0 else _CMP)
        case OStr(value):
            return (_quote(value), _ATOM)
        case OBool(value):
            return ("true" if value else "false", _ATOM)
        case OUnit():
            return ("()", _ATOM)
        case OVar(name):
            return (name, _ATOM)
        case OIgnore(expr):
            return (f"ignore {_pprint(expr, _ATOM, level)}", _APP)
        case OApp(func, args):
            # Application associates to the left in OCaml, so a call of a
            # call needs no parentheses: `compose f g 5` *is*
            # `(compose f g) 5`, and that is how it is written.
            pieces = [_pprint(func, _APP, level)]
            pieces += [_pprint(a, _ATOM, level) for a in args]
            return (" ".join(pieces), _APP)
        case OBin(op, left, right):
            op_level = _OP_LEVEL[op]
            # Arithmetic and comparison associate to the left in OCaml,
            # so only the right side of one of those needs parentheses.
            # `^` needs neither: it associates to the right *and* joining
            # strings is associative, so a chain of them prints flat
            # however the translation happened to nest it.
            left_need = op_level
            right_need = op_level if op == "^" else op_level + 1
            return (
                f"{_pprint(left, left_need, level)} {op} "
                f"{_pprint(right, right_need, level)}",
                op_level,
            )
        case OIf(cond, then_, else_):
            return (_pprint_if(cond, then_, else_, level), _IF)
        case OLet(bindings, body, recursive):
            keyword = "let rec" if recursive else "let"
            lines = []
            for index, binding in enumerate(bindings):
                lines.append(
                    _pprint_binding(binding, keyword if index == 0 else "and", 0)
                )
            head = "\n".join(lines) + " in"
            body_text = _pprint(body, _SEQ, level)
            # A short binding of a plain value reads as one line -- `let x
            # = e in body` -- while a function definition keeps its body
            # underneath, which is where a reader looks for it.
            one_line = f"{head} {body_text}"
            if (
                len(bindings) == 1
                and not bindings[0].params
                and "\n" not in one_line
                and len(one_line) + 2 * level <= 66
            ):
                return (one_line, _LET)
            return (f"{head}\n{body_text}", _LET)
        case OSeq(first, rest):
            head = _pprint(first, _SEQ + 1, level)
            tail = _pprint(rest, _SEQ, level)
            one_line = f"{head}; {tail}"
            if "\n" not in one_line and len(one_line) + 2 * level <= 66:
                return (one_line, _SEQ)
            return (f"{head};\n{tail}", _SEQ)
    raise NotImplementedError(f"no OCaml printing for expression {e!r}")


def _pprint_if(cond, then_, else_, level):
    """`if c then a else b` on one line when it fits, and otherwise one
    arm per line -- the way OCaml is usually written.

    An `if` whose `else` is another `if` is one chain rather than a nest:
    Pyking's `else:` followed by an `if` reads as `else if` here, and
    indenting each one a level deeper would say something the program
    does not."""
    condition = _pprint(cond, _CMP, level)
    then_text = _pprint(then_, _IF + 1, level)
    if else_ is not None:
        else_text = _pprint(else_, _IF, level)
        one_line = f"if {condition} then {then_text} else {else_text}"
    else:
        one_line = f"if {condition} then {then_text}"
    if "\n" not in one_line and len(one_line) + 2 * level <= 70:
        return one_line

    # Too long for one line: flatten the `else if` chain and give each
    # arm a line of its own.
    arms = []
    while True:
        arms.append((cond, then_))
        if isinstance(else_, OIf):
            cond, then_, else_ = else_.cond, else_.then_, else_.else_
        else:
            break

    lines = []
    for index, (arm_cond, arm_then) in enumerate(arms):
        head = f"{'if' if index == 0 else 'else if'} {_pprint(arm_cond, _CMP, level)} then"
        lines.append(_pprint_arm(head, _pprint(arm_then, _IF + 1, level), level))
    if else_ is not None:
        lines.append(_pprint_arm("else", _pprint(else_, _IF, level), level))
    return "\n".join(lines)


def _pprint_arm(head, body, level):
    """One arm of an `if`: `head body` when that fits on a line, and the
    body indented underneath when it does not."""
    if "\n" not in body and len(head) + 1 + len(body) + 2 * level <= 70:
        return f"{head} {body}"
    return f"{head}\n{_indent(body, 1)}"


_ESCAPES = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\t": "\\t", "\r": "\\r"}


def _quote(s):
    return '"' + "".join(_ESCAPES.get(ch, ch) for ch in s) + '"'
