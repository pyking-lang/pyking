"""The OCaml code-generation backend. Unlike the other backends, its
subset is exactly what typesystem.py accepts: rather than inferring
types again, this module runs the checker and reads translated
expressions' types back out of its tmap, so a program that does not
type-check is refused before translation begins. See docs/target_ocaml.md
for what the checker's subset still refuses, how the checker is reused,
and how each construct compiles.

Data structures: see the `datatype` comment block below (OExpr, OItem,
OBinding).

Functions:
    translate_program(stmts) -- type-checks and translates a whole
        program to [OItem].
    translate_expr(node, env, tmap) -- translates one Pyking expression
        block to one OExpr.
    pprint_program(items) -- [OItem] to OCaml source text.
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
    """Raises UnsupportedError at node with message. Expr|Stmt -> String
    -> ()"""
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
    """A translated program. Fields: items, [OItem]; needs_list_printer,
    Bool (whether the generated prelude's list-printing helper is
    used)."""
    items: list
    needs_list_printer: bool = False


# --- names ---
#
# An OCaml value name must start lowercase or underscore, and must not
# be a keyword; both are fixed by mangling, only when needed. See
# docs/target_ocaml.md, "Names".

RESERVED = frozenset("""
and as assert asr begin class constraint do done downto else end
exception external false for fun function functor if in include inherit
initializer land lazy let lor lsl lsr lxor match method mod module
mutable new nonrec object of open or private rec sig struct then to true
try type val virtual when while with
""".split())


def _mangle(name):
    """name as a legal OCaml value name. String -> String"""
    if name in RESERVED:
        return name + "_"
    if name[:1].isupper():
        return "v_" + name
    return name


# --- what can print ---
#
# Says which expressions can produce output, since that is the only
# thing OCaml's unspecified evaluation order can make observably
# different from Pyking's left-to-right (docs/target_ocaml.md,
# "Evaluation order"). Deliberately conservative.


class _Effects:
    """Which calls in a program can end up printing, by a fixed-point
    walk of the call graph. A call whose target is not a known def is
    treated as printing if any function in the program does."""

    def __init__(self, stmts):
        """Computes self.printing (function names that print) and
        self.unknown_prints (whether an unknown callee must be assumed
        to) by iterating to a fixed point. [Stmt] -> _Effects"""
        self.functions = _all_functions(stmts)
        self.printing = set()
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
        """Whether func's body contains a call that may print, given
        self.printing so far. SFunctionDef -> Bool"""
        for node in _walk(func):
            if isinstance(node, ECall) and self._call_prints(node):
                return True
        return False

    def _call_prints(self, call):
        """Whether call may print, given self.printing so far. ECall ->
        Bool"""
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
        """Whether evaluating expr can produce output. Expr -> Bool"""
        return any(
            isinstance(node, ECall) and self._call_prints(node)
            for node in _walk(expr)
        )


def _all_functions(stmts):
    """Every def in the program, at any depth, by name. [Stmt] ->
    {String: SFunctionDef}"""
    functions = {}
    for node in _walk(stmts):
        if isinstance(node, SFunctionDef):
            functions[node.name] = node
    return functions


def _walk(node):
    """Every node in a tree, the tree itself included; generic over
    dataclass fields. Expr|Stmt|[Stmt] -> (Expr|Stmt,)"""
    if isinstance(node, list):
        for item in node:
            yield from _walk(item)
    elif hasattr(node, "__dataclass_fields__"):
        yield node
        for field_name in node.__dataclass_fields__:
            yield from _walk(getattr(node, field_name))


def _unused_prefix(stmts):
    """A prefix no name in the program starts with, for the temporaries
    that fix evaluation order (docs/target_ocaml.md, "Evaluation
    order"). [Stmt] -> String"""
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
    """Type-checks stmts, then translates it to an OProgram; raises
    UnsupportedError if it does not type-check. [Stmt] -> OProgram"""
    tmap = _checked_types(stmts)
    translator = _Translator(tmap, stmts)
    items = _polish_items(translator.items(stmts))
    return OProgram(items, translator.needs_list_printer)


def _checked_types(stmts):
    """The checker's tmap for stmts; raises UnsupportedError, framing
    the checker's own message, if it does not type-check. [Stmt] ->
    {Int: Type}"""
    try:
        return typesystem.type_check(stmts)
    except (typesystem.TypeError_, AnalysisError) as e:
        raise UnsupportedError(
            e.info,
            f"this target compiles only programs that type-check, and this "
            f"one does not: {e.message}",
        ) from None


class _Translator:
    """Holds the checker's types and translation-wide state. Fields:
    tmap, {Int: Type}; needs_list_printer, Bool; printing, _Effects;
    temporary_prefix, String (see _unused_prefix); temporaries, Int
    (how many have been allocated)."""

    def __init__(self, tmap, stmts):
        self.tmap = tmap
        self.needs_list_printer = False
        self.printing = _Effects(stmts)
        self.temporary_prefix = _unused_prefix(stmts)
        self.temporaries = 0

    # -- top level --

    def items(self, stmts):
        """The top level, as a list of OCaml items: each Pyking binding
        becomes a top-level let, and each run of non-binding statements
        one `let () = ...`. [Stmt] -> [OItem]"""
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
        """A run of consecutive defs, translated and split into the
        smallest groups that still see each other, each as (bindings,
        recursive) (docs/target_ocaml.md, "A def naming one written
        further down, with something in between"). [SFunctionDef] ->
        {String} -> [([OBinding], Bool)]"""
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
        """A = binding, as one OCaml binding. SLet|SLetStmt -> OBinding"""
        match statement:
            case SLet(_, TargetName(_, name, _), expr, _, _):
                value = self.expr(expr)
            case SLetStmt(_, TargetName(_, name, _), stmt, _, _):
                value = self.value_stmt(stmt)
            case _:
                _unsupported(statement, "a binding that destructures a tuple")
        return OBinding(_mangle(name), [], value)

    def function_binding(self, func):
        """One def, as an OBinding. SFunctionDef -> OBinding"""
        params = [_mangle(p.name) for p in func.params]
        if func.expr is not None:
            return OBinding(_mangle(func.name), params, self.expr(func.expr))
        return OBinding(_mangle(func.name), params, self.body(func.body))

    def body(self, stmts):
        """A function body: a block whose last statement is its value.
        [Stmt] -> OExpr"""
        return self.block(stmts, tail=True)

    def effects(self, stmts):
        """A block run only for what it does -- the top level's
        statements, or a branch that produces nothing. [Stmt] -> OExpr"""
        return self.block(stmts, tail=False)

    def block(self, stmts, tail):
        """A statement sequence as one expression. tail says whether the
        last statement supplies a value or the block runs for effect.
        [Stmt] -> Bool -> OExpr"""
        if not stmts:
            return OUnit()

        first, rest = stmts[0], stmts[1:]

        # A guard (docs/target_ocaml.md, "A return that is neither in
        # tail position nor a guard"): `if c: return x` becomes the else
        # of the same if.
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
        """The final statement of a block. Stmt -> Bool -> OExpr"""
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
                # A block ending in a binding supplies unit; the binding
                # itself is unreachable from outside the block.
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
        """An if in value form: x = if c: ... or return if c: ....
        SIf -> OExpr"""
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
        """A statement run for its effect, its value thrown away.
        Stmt -> OExpr"""
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
        """The type the checker gave this expression. Expr -> Type"""
        return self.tmap[expr.sym]

    def expr(self, e):
        """Translates one expression. Expr -> OExpr"""
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
        """One binary operator application. String -> Expr -> Expr ->
        OExpr"""
        pieces, sequence = self.in_order([left, right])
        return sequence(OBin(op, pieces[0], pieces[1]))

    def in_order(self, exprs):
        """exprs translated, plus a wrapper pinning down their evaluation
        order where two or more can print (docs/target_ocaml.md,
        "Evaluation order"). [Expr] -> ([OExpr], OExpr -> OExpr)"""
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
        """A fresh evaluation-order temporary name. () -> String"""
        self.temporaries += 1
        return f"{self.temporary_prefix}{self.temporaries}"

    # -- the host operations --

    def print_call(self, call, args):
        """print(...): the arguments formatted per runtime_interface.py
        and written as one line. ECall -> [Expr] -> OExpr"""
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
        translated is arg's OCaml form when the caller already produced
        it. Expr -> OExpr? -> OExpr"""
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
        """Translates a call to str, len or range. ECall -> String ->
        [Expr] -> OExpr"""
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

# The one prelude this backend has (docs/target_ocaml.md, "Builtins").
_LIST_PRINTER = "pyk_string_of_int_list"
_LIST_PRINTER_DEF = f"""let {_LIST_PRINTER} xs =
  "[" ^ String.concat ", " (List.map string_of_int xs) ^ "]\""""


# --- grouping `def`s ---


def _later_functions(stmts):
    """The names the defs in stmts bind, as OCaml spells them. [Stmt] ->
    {String}"""
    return frozenset(
        _mangle(s.name) for s in stmts if isinstance(s, SFunctionDef)
    )


def _function_run(stmts, start):
    """The run of consecutive defs beginning at start. [Stmt] -> Int ->
    [SFunctionDef]"""
    run = []
    index = start
    while index < len(stmts) and isinstance(stmts[index], SFunctionDef):
        run.append(stmts[index])
        index += 1
    return run


def _check_no_split_group(run, free, later):
    """Raises UnsupportedError if a def in run names one in later with
    something other than a def in between (docs/target_ocaml.md, "A def
    naming one written further down, with something in between").
    [SFunctionDef] -> [{String}] -> {String} -> ()"""
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
# recursive, does this function reach one written further down -- is a
# question about free variables, answered on the OCaml AST since that is
# where the binders are explicit.


def _free(e):
    """Every name e reads from outside itself. OExpr -> {String}"""
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
    """A binding's free names: its value's, less its own parameters.
    OBinding -> {String}"""
    return _free(binding.value) - set(binding.params)


# --- unused names ---
#
# Renames every unread name to _name in advance, the way an OCaml
# programmer would, rather than leaving a warning a reader cannot act
# on. See docs/target_ocaml.md, "What the compiler would have said".


def _polish_items(items):
    """The top level, polished, read back to front since a binding's
    liveness depends only on what comes after it. [OItem] -> [OItem]"""
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
    """binding, renamed _name if no item in later reads it before one
    rebinds it. OBinding -> [OItem] -> OBinding"""
    binding = _polish_binding(binding)
    for item in later:
        if binding.name in _free_in_item(item):
            return binding
        if binding.name in _item_names(item):
            return OBinding("_" + binding.name, binding.params, binding.value)
    return binding


def _free_in_item(item):
    """Every name item reads from outside itself. OItem -> {String}"""
    match item:
        case OItemLet(bindings, recursive):
            free = frozenset().union(*[_free_in_binding(b) for b in bindings])
            return free - _item_names(item) if recursive else free
        case OItemUnit(expr):
            return _free(expr)
    raise NotImplementedError(f"no free variables defined for item {item!r}")


def _item_names(item):
    """The names item binds. OItem -> {String}"""
    match item:
        case OItemLet(bindings, _):
            return frozenset(b.name for b in bindings)
        case OItemUnit():
            return frozenset()
    raise NotImplementedError(f"no bound names defined for item {item!r}")


def _polish_binding(binding):
    """binding with its unread parameters renamed and its value polished.
    OBinding -> OBinding"""
    value = _polish(binding.value)
    used = _free(value)
    params = [p if p in used else "_" + p for p in binding.params]
    return OBinding(binding.name, params, value)


def _polish(e):
    """e with every unread let binding renamed _name. OExpr -> OExpr"""
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
    """Whether a block always leaves by a return. [Stmt] -> Bool"""
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
    """Type -> Bool"""
    return isinstance(t, TInt)


def _is_string(t):
    """Type -> Bool"""
    return isinstance(t, TString)


def _is_bool(t):
    """Type -> Bool"""
    return isinstance(t, TBool)


def _is_unit(t):
    """Type -> Bool"""
    return isinstance(t, TTuple) and not t.elements


def _is_int_list(t):
    """Type -> Bool"""
    return isinstance(t, TList) and isinstance(t.element, TInt)


def _name_of(t):
    """t as it would be written in source. Type -> String"""
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
    """The whole module: a header, the prelude if needed, and the
    top-level items. OProgram -> String -> String"""
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
    """item as OCaml source text. OItem -> String"""
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
    """"keyword name params =" with its value, indented to level.
    OBinding -> String -> Int -> String"""
    pad = "  " * level
    head = " ".join([keyword, binding.name] + binding.params) + " ="
    value = _pprint(binding.value, _SEQ, level + 1)
    if "\n" not in value and len(pad) + len(head) + 1 + len(value) <= 72:
        return f"{pad}{head} {value.lstrip()}"
    return f"{pad}{head}\n{_indent(value, level + 1)}"


def _indent(text, level):
    """text with level's worth of indent prefixed to each non-blank
    line. String -> Int -> String"""
    pad = "  " * level
    return "\n".join(pad + line if line else line for line in text.split("\n"))


def _pprint(e, need, level):
    """e as OCaml source text, parenthesized if it binds looser than
    need. OExpr -> Int -> Int -> String"""
    text, level_of = _pprint_bare(e, level)
    if level_of < need:
        if "\n" in text:
            return "(" + text + ")"
        return f"({text})"
    return text


def _pprint_bare(e, level):
    """(text, precedence) for e, unparenthesized. OExpr -> Int -> (String,
    Int)"""
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
    """if c then a else b, one line if it fits, else one arm per line as
    a flat else-if chain. Expr -> OExpr -> OExpr? -> Int -> String"""
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
    """One arm of an if: "head body" if it fits on a line, else body
    indented underneath. String -> String -> Int -> String"""
    if "\n" not in body and len(head) + 1 + len(body) + 2 * level <= 70:
        return f"{head} {body}"
    return f"{head}\n{_indent(body, 1)}"


_ESCAPES = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\t": "\\t", "\r": "\\r"}


def _quote(s):
    """s as a double-quoted OCaml string literal. String -> String"""
    return '"' + "".join(_ESCAPES.get(ch, ch) for ch in s) + '"'
