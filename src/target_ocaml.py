"""The OCaml code-generation backend. Unlike the other backends, its
subset is exactly what typesystem.py accepts: rather than inferring
types, this module reads translated expressions' types out of the
checker's tmap, which src/pyk.py fills and hands it -- so a program
that does not type-check is refused before translation begins. It is also the one
target compiled from the program as *written*: OCaml eliminates tail
calls itself, so src/pyk.py skips src/optimization.py here rather than
have a rewrite this module would only undo. See docs/target_ocaml.md
for what the checker's subset still refuses, how the checker is reused,
and how each construct compiles.

Data structures: see the `datatype` comment block below (OExpr, OItem,
OBinding).

Functions:
    translate_program(stmts, tmap) -- translates a whole program to
        [OItem], reading types from the checker's table.
    translate_expr(node, env, tmap) -- translates one Pyking expression
        block to one OExpr.
    pprint_program(items) -- [OItem] to OCaml source text.
"""

from dataclasses import dataclass, fields, is_dataclass

from analyses import Effects, walk
import runtime_interface
import typesystem
from syntax import (
    pprint_type,
    EInt, EString, EBool, EVar,
    EAdd, EConcat, ESub, EMul, EDiv,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq,
    ECall, EIf, ETuple,
    SLet, SLetStmt, SVar, SMutate, SReturn, SReturnStmt, SExprStmt, SIf,
    SFunctionDef,
    SLoop, SBreak, SContinue, SMatch,
    ENeg, EList, EListComp, CompFor, CompIf,
    PInt, PString, PBool, PWildcard, PCapture, PTuple, PList, PText, ListRest,
    TargetName, TargetTuple, TInt, TString, TBool, TList, TTuple,
    TOr, TFunction, TForall,
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
#     OTuple(elements: [OExpr])                (a, b)
#     OBin(op: String, left: OExpr, right: OExpr)
#     OIf(cond: OExpr, then_: OExpr, else_: OExpr?)
#     OLet(bindings: [OBinding], body: OExpr, recursive: Bool)
#                                              let a = x and b = y in body
#     OSeq(first: OExpr, rest: OExpr)          first; rest
#     ORef(value: OExpr)                    ref e
#     ODeref(name: String)                  !x
#     OAssign(name: String, value: OExpr)   x := e
#     OIgnore(expr: OExpr)                     ignore (expr)
#
# datatype OItem:                              one top-level definition
#     OItemLet(bindings: [OBinding], recursive: Bool)
#     OItemUnit(expr: OExpr)                   let () = expr
#
# datatype OBinding:
#     OBinding(name: Pattern, params: [Pattern], value: OExpr)
#
# datatype Pattern:                            what a binding binds
#     String                                   a name
#     (Pattern, ...)                           a tuple taken apart


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
class OTuple(OExpr):
    elements: list


@dataclass(frozen=True)
class OList(OExpr):
    elements: list


@dataclass(frozen=True)
class ONeg(OExpr):
    operand: OExpr


@dataclass(frozen=True)
class OMatch(OExpr):
    subject: OExpr
    arms: list              # [(pattern text, OExpr)], in source order


@dataclass(frozen=True)
class OFun(OExpr):
    # OCaml's `function`: a lambda that matches its one argument.
    arms: list              # [(pattern text, OExpr)]


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
    # `name` and each entry of `params` is a *pattern*: a String for a
    # plain name, or a Python tuple of patterns for an OCaml tuple
    # pattern (`let (a, b) = ...`, `let rec f (a, b) = ...`). See
    # `_pattern_names` and friends.
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
class ORef(OExpr):          # ref e -- a mutable cell holding e
    value: OExpr


@dataclass(frozen=True)
class ODeref(OExpr):        # !x -- reading one
    name: str


@dataclass(frozen=True)
class OAssign(OExpr):       # x := e -- writing one
    name: str
    value: OExpr


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
    """A translated program. Fields: items, [OItem]; needs_list_printer
    / needs_quote, Bool (which of the generated prelude's printers the
    program uses)."""
    items: list
    needs_list_printer: bool = False
    needs_quote: bool = False


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
_
""".split())
# `_` is there because OCaml's is the wildcard pattern rather than a
# name: `let _ = 2` binds nothing and `_` is not an expression. It is an
# ordinary Pyking name, so it is mangled like any other word OCaml has
# taken.


# Pyking name -> OCaml name, for the program being translated. Built by
# `_plan_names` before anything is translated, because the context-free
# rules below are not injective on their own: `mod` and `mod_` both want
# `mod_`, and `Foo` and `v_Foo` both want `v_Foo`. Two Pyking names
# sharing one OCaml name is not a shadow but a silent substitution, so
# the map is what keeps them apart.
_names = {}


def _mangle_base(name):
    """name as a legal OCaml value name, before collisions are resolved.
    String -> String"""
    if name in RESERVED:
        return name + "_"
    if name[:1].isupper():
        return "v_" + name
    return name


def _plan_names(stmts):
    """Chooses one OCaml name per Pyking name in stmts, so that no two
    of them land on the same one. A name OCaml already accepts keeps its
    own spelling; the rest take the first free `base`, `base2`, ...
    [Stmt] -> {String: String}"""
    used = _collect_identifiers(stmts)
    plan = {}
    # A name that needs no change is settled first, so that the ones that
    # do are what move out of the way -- keeping generated OCaml as close
    # to the source's own spelling as it can be.
    unchanged = {n for n in used if _mangle_base(n) == n}
    taken = set(unchanged)
    for name in unchanged:
        plan[name] = name
    for name in sorted(used - unchanged):
        candidate = _mangle_base(name)
        suffix = 1
        while candidate in taken or candidate in RESERVED:
            suffix += 1
            candidate = f"{_mangle_base(name)}{suffix}"
        plan[name] = candidate
        taken.add(candidate)
    return plan


def _collect_identifiers(node, acc=None):
    """Every identifier used anywhere in node, as a set. Relies on every
    field literally named name holding an identifier in syntax.py.
    Stmt|Expr|... -> {String}? -> {String}"""
    if acc is None:
        acc = set()
    if is_dataclass(node):
        for f in fields(node):
            value = getattr(node, f.name)
            if f.name == "name" and isinstance(value, str):
                acc.add(value)
            else:
                _collect_identifiers(value, acc)
    elif isinstance(node, (list, tuple)):
        for element in node:
            _collect_identifiers(element, acc)
    return acc


def _mangle(name):
    """The OCaml name a Pyking name is translated to, as `_plan_names`
    settled it. String -> String"""
    return _names.get(name, _mangle_base(name))


def _unused_prefix(stmts):
    """A prefix no name in the program starts with, for the temporaries
    that fix evaluation order (docs/target_ocaml.md, "Evaluation
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


# --- translation ---


def translate_program(stmts, tmap):
    """Translates stmts to an OProgram, reading the types the checker
    worked out rather than inferring any. src/pyk.py runs the checker
    and hands the table here, so a program that does not check has been
    refused before this is called. [Stmt] -> {Int: Type} -> OProgram"""
    global _names
    _names = _plan_names(stmts)
    translator = _Translator(tmap, stmts)
    items = _polish_items(translator.items(stmts))
    return OProgram(items, translator.needs_list_printer, translator.needs_quote)


@dataclass(frozen=True)
class _Loop:
    """One `loop` being translated. Fields: name, String (the local
    function that is the loop); accumulator, OExpr (what a bare
    `break`/`continue` uses); carries, Bool (whether the loop was
    written with an accumulator at all)."""
    name: str
    accumulator: OExpr
    carries: bool
    returning: bool


# What a `break`/`continue` OCaml cannot place is refused with. The
# guard rewrite in `block` covers the common shapes; this is what is
# left (docs/target_ocaml.md, "A break that is neither in tail position
# nor a guard").
_NO_EARLY_EXIT = (
    "a `break`/`continue` with statements after it: OCaml has no early "
    "exit, so only one in tail position -- or one guarding the rest of "
    "the body -- can be compiled"
)


class _Translator:
    """Holds the checker's types and translation-wide state. Fields:
    tmap, {Int: Type}; needs_list_printer, Bool; printing, Effects;
    temporary_prefix, String (see _unused_prefix); temporaries, Int
    (how many have been allocated)."""

    def __init__(self, tmap, stmts):
        self.tmap = tmap
        self.needs_list_printer = False
        self.printing = Effects(stmts)
        self.temporary_prefix = _unused_prefix(stmts)
        self.temporaries = 0
        self.needs_quote = False
        # The `loop`s being translated, innermost last: each holds the
        # name of the local function that *is* the loop, and the
        # accumulator a bare `break`/`continue` uses.
        self.loops = []
        # The names currently declared `var`, which are OCaml `ref`s:
        # a read of one is `!x` rather than `x`. Pyking refuses to
        # shadow a `var`, so a name in here means the same cell
        # wherever it is read (src/analyses.py).
        self.refs = set()

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
            if isinstance(statement, SVar):
                # A top-level `var` is a top-level `ref`, in scope for
                # everything after it, which is what the items are.
                items.append(
                    OItemLet([
                        OBinding(
                            _mangle(statement.name), [],
                            ORef(self.expr(statement.expr)),
                        )
                    ])
                )
                self.refs.add(statement.name)
                index += 1
                continue
            if isinstance(statement, (SLet, SLetStmt)):
                items.append(OItemLet([self.binding(statement)]))
                index += 1
                continue
            # A run of statements with nothing to bind: one `let () =`.
            run = []
            while index < len(stmts) and not isinstance(
                stmts[index], (SLet, SLetStmt, SVar, SFunctionDef)
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
            case SLet(_, target, expr, _, _):
                value = self.expr(expr)
            case SLetStmt(_, target, stmt, _, _):
                value = self.value_stmt(stmt)
        return OBinding(_target_pattern(target), [], value)

    def function_binding(self, func):
        """One def, as an OBinding. SFunctionDef -> OBinding"""
        self._check_rank_one(func)
        # OCaml has no nullary function, so a `def f():` takes unit --
        # the empty tuple pattern, which prints as `()`. Without it the
        # binding would be a value, evaluated where it is written rather
        # than where it is called, and a body that never returns would
        # hang the program at start-up.
        params = [_mangle(p.name) for p in func.params] or [()]
        return OBinding(_mangle(func.name), params, self.body(func.body))

    def _check_rank_one(self, func):
        """Refuses a def with a polymorphic *parameter*. OCaml
        generalizes what a `let` binds, so a polymorphic definition
        needs nothing said about it here -- but a parameter used at two
        types inside one body is rank-2, and OCaml takes that only from
        an explicit `'a.` annotation, which this backend never writes
        (docs/target_ocaml.md, "Type variables"). SFunctionDef -> ()"""
        match self.tmap.get(func.sym):
            case TForall(_, _, TFunction(_, params, _, _, _, _)) | \
                 TFunction(_, params, _, _, _, _):
                pass
            case _:
                return
        for param, type_ in zip(func.params, params):
            if _has_forall(type_):
                _unsupported(
                    param,
                    "a polymorphic parameter -- OCaml generalizes a `let`, "
                    "not a parameter, and taking one needs an explicit "
                    "`'a.` annotation this backend does not write",
                )

    # -- patterns --

    def pattern(self, p, used=None):
        """One Pyking pattern as OCaml pattern text. OCaml's own
        patterns line up with Pyking's, so this is a spelling change
        rather than a translation: `..` is `_`, `..name` is `name`, and
        a list is written with `::` where a rest marker splits it.
        `used` is what the arm reads; a name it does not is written
        `_name`, the same convention an unread `let` binding follows,
        since this target is built warning-free.
        Pattern -> {String}? -> String"""
        match p:
            case PWildcard():
                return "_"
            case PCapture(_, name, _):
                return _unread(_mangle(name), used)
            case PInt(_, value, _):
                return str(value) if value >= 0 else f"({value})"
            case PString(_, value, _):
                return _quote(value)
            case PBool(_, value, _):
                return "true" if value else "false"
            case PTuple(_, elements, _):
                inside = ", ".join(self.pattern(e, used) for e in elements)
                return f"({inside})"
            case PText():
                _unsupported(
                    p,
                    "a `++` pattern over a string -- OCaml's patterns do not "
                    "split a string, and doing it with a guard would need a "
                    "`when` clause this backend does not build",
                )
            case PList(_, prefix, rest, suffix, _):
                if rest is None:
                    inside = "; ".join(self.pattern(e, used) for e in prefix)
                    return f"[{inside}]"
                if suffix:
                    _unsupported(
                        p,
                        "a list pattern with elements after `..` -- OCaml "
                        "matches a list from the front only",
                    )
                tail = "_" if rest.name is None else _unread(
                    _mangle(rest.name), used
                )
                heads = "".join(f"{self.pattern(e, used)} :: " for e in prefix)
                return f"({heads}{tail})" if heads else tail
        _unsupported(p, type(p).__name__)

    def arms(self, cases):
        """A match's clauses as (pattern, body) pairs. The body is
        translated first, so the pattern can tell which of the names it
        binds the arm actually reads. [MatchCase] -> [(String, OExpr)]"""
        built = []
        for case_clause in cases:
            body = self.body(case_clause.body)
            built.append((self.pattern(case_clause.pattern, _free(body)), body))
        return built

    def match_value(self, stmt):
        """A `match` whose value is taken. OCaml requires every value to
        exist, so the clauses must cover -- which typesystem.py has
        already required of a value-form match. SMatch -> OExpr"""
        return OMatch(self.expr(stmt.subject), self.arms(stmt.cases))

    def match_effects(self, stmt):
        """A `match` run for what it does. A Pyking `match` may match
        nothing and do nothing, so a catch-all arm is added unless the
        clauses already cover. SMatch -> OExpr"""
        arms = []
        for c in stmt.cases:
            body = self.effects(c.body)
            arms.append((self.pattern(c.pattern, _free(body)), body))
        if not typesystem.covers([c.pattern for c in stmt.cases]):
            arms.append(("_", OUnit()))
        return OMatch(self.expr(stmt.subject), arms)

    # -- comprehensions --

    def comprehension(self, e):
        """`[expr for p in seq if c ...]` as nested folds. Each `for`
        becomes a `List.concat_map` over its sequence, each `if` a
        guard, and a pattern that does not match filters the element out
        -- which is what Pyking's own comprehension does.
        EListComp -> OExpr"""
        return self.clauses(list(e.clauses), e.expr)

    def clauses(self, clauses, element):
        """The fold for the clauses that are left. [CompClause] -> Expr
        -> OExpr"""
        if not clauses:
            return OList([self.expr(element)])
        match clauses[0]:
            case CompFor(_, pattern, sequence, _):
                inner = self.clauses(clauses[1:], element)
                text = self.pattern(pattern, _free(inner))
                arms = [(text, inner)]
                if not typesystem.covers([pattern]):
                    arms.append(("_", OList([])))
                return OApp(
                    OVar("List.concat_map"),
                    [OFun(arms), self.expr(sequence)],
                )
            case CompIf(_, condition, _):
                return OIf(
                    self.expr(condition),
                    self.clauses(clauses[1:], element),
                    OList([]),
                )

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
        # tail position nor a guard"): an `if` a branch of which always
        # leaves -- by `return`, `break` or `continue` -- becomes an
        # `if` whose other branch is the rest of the block. Nothing is
        # duplicated, since a branch that leaves needs no continuation
        # and a branch that does not is the only one carrying it.
        if rest and isinstance(first, SIf):
            then_exits = _definitely_exits(first.then_body)
            else_exits = (
                first.else_body is not None and _definitely_exits(first.else_body)
            )
            if then_exits or else_exits:
                else_body = first.else_body or []
                return OIf(
                    self.expr(first.cond),
                    self.block(
                        first.then_body if then_exits
                        else list(first.then_body) + rest,
                        tail,
                    ),
                    self.block(
                        else_body if else_exits else list(else_body) + rest, tail
                    ),
                )

        if not rest:
            return self.last(first, tail)

        match first:
            case SVar(_, name, expr, _):
                # A `var` is a `ref`, and its scope is the rest of this
                # block -- which is exactly what `let ... in` gives it.
                value = self.expr(expr)
                self.refs.add(name)
                try:
                    body = self.block(rest, tail)
                finally:
                    self.refs.discard(name)
                return OLet([OBinding(_mangle(name), [], ORef(value))], body)
            case SMutate():
                return OSeq(self.discard(first), self.block(rest, tail))
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
            case SBreak() | SContinue():
                _unsupported(first, _NO_EARLY_EXIT)
            case _:
                return OSeq(self.discard(first), self.block(rest, tail))

    def last(self, statement, tail):
        """The final statement of a block. `tail` is True for a block
        whose value is a function's, False for one run only for what it
        does, and a `_Loop` for the body of a loop, whose value is the
        accumulator the next turn carries.
        Stmt -> (Bool | _Loop) -> OExpr"""
        if isinstance(tail, _Loop):
            return self.loop_last(statement, tail)
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
            case SMatch() if tail:
                return self.match_value(statement)
            case SMatch():
                return self.match_effects(statement)
            case SLoop() if tail:
                # A loop is an expression here, so a function ending in
                # one needs nothing said about it -- and a `return`
                # inside it returns from the function, since the loop's
                # value *is* the function's.
                return self.loop(statement, returning=True)
            case SVar(_, name, expr, _):
                # As for `=` below: the cell is unreachable from outside
                # the block, so the block supplies unit.
                return OLet(
                    [OBinding(_mangle(name), [], ORef(self.expr(expr)))], OUnit()
                )
            case SMutate():
                # A mutation is worth unit, which is what a block run for
                # what it does supplies anyway.
                return self.discard(statement)
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

    # -- loops --

    def loop(self, s, returning=False):
        """A loop, as a local recursive function applied at once
        (docs/target_ocaml.md, "loop"): the accumulator is the
        function's parameter, going round is a tail call, and breaking
        is the value the call returns. OCaml optimises the tail call,
        so this runs in constant space -- which is why this backend
        needs no imperative loop at all. SLoop -> OExpr"""
        if s.iterate is not None or s.result is not None:
            _unsupported(
                s,
                "a `for`/`while` clause or a `result` expression on a loop -- this "
                "backend compiles a loop to a local recursive function, and "
                "the recursion over the sequence is not built yet",
            )
        name = self.fresh_name()
        if s.target is None:
            # Nothing is carried, so the parameter is unit and the
            # accumulator every `break` yields is unit too.
            parameter = self.fresh_name()
            accumulator = OUnit()
            init = OUnit()
        else:
            parameter = _target_pattern(s.target)
            accumulator = _target_expr(s.target)
            init = self.expr(s.init)
        self.loops.append(
            _Loop(name, accumulator, s.target is not None, returning)
        )
        try:
            body = self.block(s.body, self.loops[-1])
        finally:
            self.loops.pop()
        binding = OBinding(name, [parameter], body)
        # `rec` only where the body actually goes round again: an
        # unnecessary one is a warning, and the harness builds with
        # warnings as errors.
        recursive = name in _free_in_binding(binding)
        return OLet([binding], OApp(OVar(name), [init]), recursive)

    def again(self, loop, value):
        """The tail call that starts loop's next turn.
        _Loop -> OExpr -> OExpr"""
        return OApp(OVar(loop.name), [value])

    def loop_last(self, statement, loop):
        """The last statement of a loop body: what it produces is the
        accumulator the next turn carries, so it ends in either a call
        going round or the value the loop stops with.
        Stmt -> _Loop -> OExpr"""
        match statement:
            case SReturn(_, expr, _) | SReturnStmt(_, expr, _) if loop.returning:
                # The loop is the function's value, so leaving the loop
                # with this and leaving the function with it are one
                # and the same.
                return (
                    self.value_stmt(expr) if isinstance(statement, SReturnStmt)
                    else self.expr(expr)
                )
            case SReturn() | SReturnStmt():
                _unsupported(
                    statement,
                    "a `return` inside a loop that is not the function's own "
                    "value: OCaml has no early exit, and this loop's value is "
                    "wanted where it stands, so returning from it cannot "
                    "leave the function too",
                )
            case SLoop():
                # A loop as the last statement of a loop body: its value
                # is what the turn outside goes round with.
                return self.again(loop, self.loop(statement))
            case SBreak(_, expr, _):
                # A bare `break` is `break ()` -- it leaves without
                # saying what the loop is worth (PYKING.md, "Leaving a
                # loop"), which is a different question from what the
                # loop carries.
                return OUnit() if expr is None else self.expr(expr)
            case SContinue(_, expr, _):
                return self.again(
                    loop, loop.accumulator if expr is None else self.expr(expr)
                )
            case SIf(_, cond, then_body, else_body, _):
                if else_body is not None:
                    return OIf(
                        self.expr(cond),
                        self.block(then_body, loop),
                        self.block(else_body, loop),
                    )
                if loop.carries:
                    _unsupported(
                        statement,
                        "an `if` with no `else` as the last statement of a "
                        "loop body: one way through it would say nothing "
                        "about what the next turn carries",
                    )
                # A loop carrying nothing: the branch runs for what it
                # does, and the loop goes round either way.
                return OSeq(
                    OIf(self.expr(cond), self.effects(then_body)),
                    self.again(loop, OUnit()),
                )
            case SExprStmt(_, expr, _) if loop.carries:
                return self.again(loop, self.expr(expr))
            case _ if not loop.carries:
                return OSeq(self.discard(statement), self.again(loop, OUnit()))
        _unsupported(
            statement,
            f"{type(statement).__name__} as the last statement of a loop body: "
            f"every turn has to say what the next one carries",
        )

    def value_stmt(self, stmt):
        """A statement in value form: x = if c: ..., return if c: ...,
        or a loop, whose value is the accumulator it stopped with.
        SIf|SLoop -> OExpr"""
        match stmt:
            case SLoop():
                return self.loop(stmt)
            case SIf(_, cond, then_body, else_body, _):
                if else_body is None:
                    _unsupported(stmt, "a value-form `if` with no `else`")
                return OIf(
                    self.expr(cond),
                    self.block(then_body, tail=True),
                    self.block(else_body, tail=True),
                )
            case SMatch():
                return self.match_value(stmt)
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
            case SMatch():
                return self.match_effects(statement)
            case SLoop():
                translated = self.loop(statement)
                if statement.target is None:
                    return translated
                return OIgnore(translated)
            case SMutate(_, name, expr, _):
                return OAssign(_mangle(name), self.expr(expr))
            case SBreak() | SContinue():
                _unsupported(statement, _NO_EARLY_EXIT)
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
                # A `var` is a cell, so reading it is a dereference.
                if name in self.refs:
                    return ODeref(_mangle(name))
                return OVar(_mangle(name))
            case EIf(_, cond, then_expr, else_expr, _):
                return OIf(self.expr(cond), self.expr(then_expr), self.expr(else_expr))
            case ETuple(_, [], _):
                # The empty tuple is unit, in Pyking as in OCaml.
                return OUnit()
            case ETuple(_, elements, _):
                pieces, sequence = self.in_order(elements)
                return sequence(OTuple(pieces))
            case ECall(_, EVar(_, name, _), args, _) if (
                runtime_interface.lookup(name) is not None
            ):
                return self.print_call(e, args)
            case ECall(_, EVar(_, name, _), args, _) if name in _BUILTINS:
                return self.builtin_call(e, name, args)
            case ECall(_, func, args, _):
                pieces, sequence = self.in_order([func] + list(args))
                # A call with no arguments passes unit, since that is
                # what `function_binding` gave the definition to take.
                return sequence(OApp(pieces[0], pieces[1:] or [OUnit()]))
            case EAdd(_, left, right, _):
                return self.binary("+", left, right)
            case EList(_, elements, _):
                pieces, sequence = self.in_order(list(elements))
                return sequence(OList(pieces))
            case ENeg(_, operand, _):
                return ONeg(self.expr(operand))
            case EListComp(_, _, _, _):
                return self.comprehension(e)
            case EConcat(_, left, right, _) if isinstance(
                self.type_of(e), TList
            ):
                # OCaml joins lists with `@` and strings with `^`; the
                # checker has already said which this is.
                return self.binary("@", left, right)
            case EConcat(_, left, right, _):
                # OCaml spells concatenation `^`, and Pyking's `++` says
                # which is meant without anything having to ask the type.
                return self.binary("^", left, right)
            case ESub(_, left, right, _):
                return self.binary("-", left, right)
            case EMul(_, left, right, _):
                return self.binary("*", left, right)
            case EDiv(_, left, right, _):
                # OCaml's `/` on ints truncates toward zero, which is
                # Pyking's own rule.
                return self.binary("/", left, right)
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
        if translated is None:
            translated = self.expr(arg)
        return self.string_of(self.type_of(arg), translated, arg, top=True)

    def string_of(self, type_, translated, node, top):
        """A value of this type as a string, per runtime_interface.py's
        rules. top says the value is being printed on its own rather
        than from inside a tuple, which is the one thing that changes:
        a string prints bare there and quoted here.
        Type -> OExpr -> Node -> Bool -> OExpr"""
        if _is_string(type_):
            if top:
                return translated
            self.needs_quote = True
            return OApp(OVar(_QUOTE), [translated])
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
        if isinstance(type_, TList):
            return self.list_string(type_, translated, node)
        if isinstance(type_, TTuple):
            return self.tuple_string(type_, translated, node)
        _unsupported(node, f"printing a value of type {_name_of(type_)}")

    def list_string(self, type_, translated, node):
        """A list as a string, in Pyking's own notation. The element
        formatter is built from the element's type the same way
        `tuple_string` builds a tuple's, so a list of anything printable
        prints -- including a list of lists.
        TList -> OExpr -> Node -> OExpr"""
        name = self.fresh_name()
        element = self.string_of(type_.element, OVar(name), node, top=False)
        mapped = OApp(
            OVar("List.map"), [OFun([(name, element)]), translated]
        )
        joined = OApp(
            OVar("String.concat"), [OStr(", "), mapped]
        )
        return OBin("^", OStr("["), OBin("^", joined, OStr("]")))

    def tuple_string(self, type_, translated, node):
        """A tuple as a string, in Pyking's own notation. OCaml has no
        printer of its own to reach for, so this takes the tuple apart
        and formats each element by its type -- which is what makes a
        nested one work as well. TTuple -> OExpr -> Node -> OExpr"""
        names = [self.fresh_name() for _ in type_.elements]
        pieces = [
            self.string_of(element, OVar(name), node, top=False)
            for element, name in zip(type_.elements, names)
        ]
        # A singleton keeps the comma that tells it from a parenthesized
        # value, exactly as the source form does.
        closing = ",)" if len(pieces) == 1 else ")"
        text = pieces[0]
        for piece in pieces[1:]:
            text = OBin("^", text, OBin("^", OStr(", "), piece))
        text = OBin("^", OStr("("), OBin("^", text, OStr(closing)))
        return OLet([OBinding(tuple(names), [], translated)], text)

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

# The prelude this backend has (docs/target_ocaml.md, "Builtins"): two
# printers for what OCaml has no printing of its own for.
_LIST_PRINTER = "pyk_string_of_int_list"
_LIST_PRINTER_DEF = f"""let {_LIST_PRINTER} xs =
  "[" ^ String.concat ", " (List.map string_of_int xs) ^ "]\""""

_QUOTE = "pyk_quote"
_QUOTE_DEF = f"""let {_QUOTE} text =
  let out = Buffer.create (String.length text + 2) in
  Buffer.add_char out '\\'';
  String.iter
    (fun c ->
      match c with
      | '\\\\' -> Buffer.add_string out "\\\\\\\\"
      | '\\'' -> Buffer.add_string out "\\\\'"
      | '\\n' -> Buffer.add_string out "\\\\n"
      | '\\t' -> Buffer.add_string out "\\\\t"
      | '\\r' -> Buffer.add_string out "\\\\r"
      | c -> Buffer.add_char out c)
    text;
  Buffer.add_char out '\\'';
  Buffer.contents out"""


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
        case OIgnore(expr) | ORef(expr):
            return _free(expr)
        case ODeref(name):
            return frozenset([name])
        case OAssign(name, value):
            return frozenset([name]) | _free(value)
        case OApp(func, args):
            return _free(func).union(*[_free(a) for a in args]) if args else _free(func)
        case OTuple(elements) | OList(elements):
            if not elements:
                return frozenset()
            return frozenset().union(*[_free(el) for el in elements])
        case ONeg(operand):
            return _free(operand)
        case OMatch(subject, arms):
            # An arm's own bindings are its pattern's, and a pattern is
            # printed text by the time it is here -- so what an arm reads
            # from outside is over-reported rather than under-reported,
            # which is the safe direction for `let rec` grouping.
            return frozenset().union(_free(subject), *[_free(b) for _, b in arms])
        case OFun(arms):
            return frozenset().union(frozenset(), *[_free(b) for _, b in arms])
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
    bound = {name for param in binding.params for name in _pattern_names(param)}
    return _free(binding.value) - bound


# --- binding patterns ---
#
# A binding or a parameter is either a name or a tuple taken apart, and
# the three things done to one -- reading its names, printing it, and
# underscoring what nothing reads -- are the same either way.


def _target_pattern(target):
    """A Pyking assignment target as an OCaml binding pattern.
    AssignTarget -> Pattern"""
    match target:
        case TargetName(_, name, _):
            return _mangle(name)
        case TargetTuple(_, elements, _):
            return tuple(_target_pattern(e) for e in elements)


def _target_expr(target):
    """A target read back as an expression: what a loop's accumulator
    holds on the turn it is bound. AssignTarget -> OExpr"""
    match target:
        case TargetName(_, name, _):
            return OVar(_mangle(name))
        case TargetTuple(_, elements, _):
            return OTuple([_target_expr(e) for e in elements])


def _pattern_names(pattern):
    """Every name a binding pattern binds. Pattern -> [String]"""
    if isinstance(pattern, tuple):
        return [name for part in pattern for name in _pattern_names(part)]
    return [pattern]


def _pattern_text(pattern):
    """A binding pattern as OCaml source text. Pattern -> String"""
    if isinstance(pattern, tuple):
        return f"({', '.join(_pattern_text(part) for part in pattern)})"
    return pattern


def _pattern_polished(pattern, used):
    """pattern with every name nothing in used reads renamed _name.
    Pattern -> {String} -> Pattern"""
    if isinstance(pattern, tuple):
        return tuple(_pattern_polished(part, used) for part in pattern)
    if pattern in used or pattern.startswith("_"):
        return pattern
    return "_" + pattern


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
    names = set(_pattern_names(binding.name))
    for item in later:
        if names & _free_in_item(item):
            return binding
        if names & _item_names(item):
            return OBinding(
                _pattern_polished(binding.name, frozenset()),
                binding.params,
                binding.value,
            )
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
            return frozenset(
                name for b in bindings for name in _pattern_names(b.name)
            )
        case OItemUnit():
            return frozenset()
    raise NotImplementedError(f"no bound names defined for item {item!r}")


def _polish_binding(binding):
    """binding with its unread parameters renamed and its value polished.
    OBinding -> OBinding"""
    value = _polish(binding.value)
    used = _free(value)
    params = [_pattern_polished(p, used) for p in binding.params]
    return OBinding(binding.name, params, value)


def _polish(e):
    """e with every unread let binding renamed _name. OExpr -> OExpr"""
    match e:
        case OInt() | OStr() | OBool() | OUnit() | OVar():
            return e
        case OIgnore(expr):
            return OIgnore(_polish(expr))
        case ORef(value):
            return ORef(_polish(value))
        case ODeref():
            return e
        case OAssign(name, value):
            return OAssign(name, _polish(value))
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
        case OTuple(elements):
            return OTuple([_polish(el) for el in elements])
        case OList(elements):
            return OList([_polish(el) for el in elements])
        case ONeg(operand):
            return ONeg(_polish(operand))
        case OMatch(subject, arms):
            return OMatch(_polish(subject), [(p, _polish(b)) for p, b in arms])
        case OFun(arms):
            return OFun([(p, _polish(b)) for p, b in arms])
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
                OBinding(_pattern_polished(b.name, used), b.params, b.value)
                for b in bindings
            ]
            return OLet(bindings, body, recursive)
    raise NotImplementedError(f"no polishing defined for {e!r}")


def _definitely_exits(stmts):
    """Whether a block always leaves what it is in -- a function by a
    `return`, a loop by a `break` or a `continue`. [Stmt] -> Bool"""
    match stmts:
        case [*_, SReturn() | SReturnStmt() | SBreak() | SContinue()]:
            return True
        case [*_, SIf(_, _, then_body, else_body)]:
            return (
                else_body is not None
                and _definitely_exits(then_body)
                and _definitely_exits(else_body)
            )
        case _:
            return False


# --- reading the checker's types ---


def _is_int(t):
    """Type -> Bool"""
    return isinstance(t, TInt)


def _unread(name, used):
    """A bound name as OCaml should spell it: `_name` where the body
    never reads it, so that a warning-free build stays warning-free.
    String -> {String}? -> String"""
    if used is None or name in used:
        return name
    return f"_{name}"


def _has_forall(type_):
    """Whether an `all` appears anywhere inside a type -- the mark of
    polymorphism OCaml will not infer for a parameter. Type -> Bool"""
    match type_:
        case TForall():
            return True
        case TList(_, element, _):
            return _has_forall(element)
        case TTuple(_, elements, _) | TOr(_, elements, _):
            return any(_has_forall(e) for e in elements)
        case TFunction(_, params, result, _, _, _):
            return any(_has_forall(p) for p in params) or _has_forall(result)
    return False


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
    # `@` joins lists and `^` joins strings; both associate to the right
    # at the same level in OCaml.
    "^": _CONCAT, "@": _CONCAT,
    "+": _ADD, "-": _ADD,
    "*": _MUL, "/": _MUL,
}


def pprint_ocaml_program(program, source="a Pyking program"):
    """The whole module: a header, the prelude if needed, and the
    top-level items. OProgram -> String -> String"""
    parts = [
        f"(* Generated from {source} by the Pyking compiler. Do not edit. *)",
        "(* Target: ocaml. Compile with:  ocamlopt <this file>",
        "   or run it directly with:      ocaml <this file> *)",
    ]
    if program.needs_list_printer:
        parts += ["", _LIST_PRINTER_DEF]
    if program.needs_quote:
        parts += ["", _QUOTE_DEF]
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
    head = " ".join(
        [keyword, _pattern_text(binding.name)]
        + [_pattern_text(p) for p in binding.params]
    ) + " ="
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
        case ODeref(name):
            # `!` is a prefix operator and binds tighter than anything
            # else, so a dereference is an atom wherever it stands.
            return (f"!{name}", _ATOM)
        case ORef(value):
            return (f"ref {_pprint(value, _ATOM, level)}", _APP)
        case OAssign(name, value):
            return (f"{name} := {_pprint(value, _LET + 1, level)}", _LET)
        case OTuple(elements):
            # Always parenthesized, so it is an atom wherever it stands.
            inside = ", ".join(_pprint(el, _SEQ + 1, level) for el in elements)
            return (f"({inside})", _ATOM)
        case OList(elements):
            # Always bracketed, so it is an atom wherever it stands.
            inside = "; ".join(_pprint(el, _SEQ + 1, level) for el in elements)
            return (f"[{inside}]", _ATOM)
        case ONeg(operand):
            # OCaml's unary minus on an application needs no parentheses
            # (`-f x` is `-(f x)`), but on anything looser it does.
            inner = _pprint(operand, _APP, level)
            # A `-` straight after this one would lex as the single
            # operator `--`, whatever the precedence says, so an operand
            # that starts with one is parenthesized to break them apart.
            if inner.startswith("-"):
                return (f"-({inner})", _APP)
            return (f"-{inner}", _APP)
        case OMatch(subject, arms):
            pad = "  " * level
            head = f"match {_pprint(subject, _SEQ + 1, level)} with"
            lines = [head] + [
                f"{pad}  | {pattern} -> {_pprint(body, _SEQ + 1, level + 1)}"
                for pattern, body in arms
            ]
            return ("\n".join(lines), _SEQ)
        case OFun(arms):
            inside = " ".join(
                f"| {pattern} -> {_pprint(body, _SEQ + 1, level)}"
                for pattern, body in arms
            )
            return (f"function {inside}", _SEQ)
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
