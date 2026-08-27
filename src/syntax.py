"""The Pyking AST: one frozen dataclass per node kind, plus a pretty
printer that prints it back out as Pyking source. Every stage after
parsing (analyses, type checker, backends) consumes exactly this. See
docs/source.md ("syntax.py") and docs/architecture.md.

Data structures: see the `datatype` comment block below, which lists
every group (Expr, Type, Pattern, CompClause, AssignTarget, Stmt) and
its variants.

Functions:
    pprint_program(stmts, symbols, tmap) -- the whole program as source;
        the only entry point callers use.
    pprint_expr(e) / pprint_stmt(s) / pprint_type(t) / pprint_pattern(p) /
        pprint_param(p) / pprint_target(t) -- print one node of that kind.
"""

from dataclasses import dataclass, fields, is_dataclass

from lexer import Info


# The AST, as algebraic data types: every node group in this file, its
# variants, and the fields each variant carries. Python's dataclasses
# can say the fields but not that a group *is* a closed set of
# alternatives, which is the thing every `match`/`case` over the AST
# relies on -- so this says it, and one block tells you what a `match`
# on that type has to cover.
#
# All of them are gathered here rather than each sitting above its own
# base class, so that the whole shape of the AST can be read in one
# place, and so that the types which refer to one another can be
# compared without scrolling between them.
#
# The notation is OCaml-ish rather than Python:
#
#     Int, String, Bool   Python's int/str/bool, spelled as Pyking spells
#                         its own types
#     [T]                 a list of T (the annotation only says `list`,
#                         so the element type is recorded here)
#     T?                  may be absent -- the field defaults to None
#
# The order here is the six alternatives-types first, then the three
# single-constructor ones (a one-variant datatype being exactly a
# record). It is not the order the classes are *declared* in below: a
# class has to wait for whatever it mentions -- `EListComp` holds
# `[CompClause]`, so it is declared after `CompClause` even though it is
# a variant of `Expr`.
#
# These blocks are documentation, not generated code -- keep them in step
# with the dataclasses by hand (see CLAUDE.md).


# datatype Expr:
#     EInt(info: Info, value: Int, sym: Int)
#     EString(info: Info, value: String, sym: Int)
#     EBool(info: Info, value: Bool, sym: Int)
#     EVar(info: Info, name: String, sym: Int)
#     EAdd(info: Info, left: Expr, right: Expr, sym: Int)
#     ESub(info: Info, left: Expr, right: Expr, sym: Int)
#     EMul(info: Info, left: Expr, right: Expr, sym: Int)
#     EDiv(info: Info, left: Expr, right: Expr, sym: Int)
#     ENeg(info: Info, operand: Expr, sym: Int)
#     EConcat(info: Info, left: Expr, right: Expr, sym: Int)
#     ELessThan(info: Info, left: Expr, right: Expr, sym: Int)
#     ELessThanEq(info: Info, left: Expr, right: Expr, sym: Int)
#     EGreatThan(info: Info, left: Expr, right: Expr, sym: Int)
#     EGreatThanEq(info: Info, left: Expr, right: Expr, sym: Int)
#     EEq(info: Info, left: Expr, right: Expr, sym: Int)
#     ECall(info: Info, func: Expr, args: [Expr], sym: Int)
#     EList(info: Info, elements: [Expr], sym: Int)
#     ETuple(info: Info, elements: [Expr], sym: Int)
#     EIf(info: Info, cond: Expr, then_expr: Expr, else_expr: Expr, sym: Int)
#     EListComp(info: Info, expr: Expr, clauses: [CompClause], sym: Int)
#
# datatype Type:
#     TInt(info: Info, sym: Int)
#     TString(info: Info, sym: Int)
#     TBool(info: Info, sym: Int)
#     TList(info: Info, element: Type, sym: Int)
#     TTuple(info: Info, elements: [Type], sym: Int)
#     TOr(info: Info, alternatives: [Type], sym: Int)
#     TUnknown(info: Info, sym: Int)
#     TNever(info: Info, sym: Int)
#     TBuiltin(info: Info, name: String, sym: Int)
#     TFunction(info: Info, params: [Type], result: Type, sym: Int,
#               tmsym: Int, definition: SFunctionDef?)
#     TVar(info: Info, name: String, sym: Int)
#     TForall(info: Info, vars: [String], body: Type, sym: Int)
#
# datatype Pattern:
#     PInt(info: Info, value: Int, sym: Int)
#     PString(info: Info, value: String, sym: Int)
#     PBool(info: Info, value: Bool, sym: Int)
#     PWildcard(info: Info, sym: Int)
#     PCapture(info: Info, name: String, sym: Int)
#     PTuple(info: Info, elements: [Pattern], sym: Int)
#     PList(info: Info, prefix: [Pattern], rest: ListRest?, suffix: [Pattern]?,
#           sym: Int)
#
# datatype CompClause:
#     CompFor(info: Info, pattern: Pattern, sequence: Expr, sym: Int)
#     CompIf(info: Info, condition: Expr, sym: Int)
#
# datatype AssignTarget:
#     TargetName(info: Info, name: String, sym: Int)
#     TargetTuple(info: Info, elements: [AssignTarget], sym: Int)
#
# datatype Stmt:
#     SLet(info: Info, target: AssignTarget, expr: Expr, type: Type?, sym: Int)
#     SLetStmt(info: Info, target: AssignTarget, stmt: Stmt, type: Type?,
#              sym: Int)
#     SVar(info: Info, name: String, expr: Expr, sym: Int)
#     SMutate(info: Info, name: String, expr: Expr, sym: Int)
#     SReturn(info: Info, expr: Expr, sym: Int)
#     SReturnStmt(info: Info, stmt: Stmt, sym: Int)
#     SExprStmt(info: Info, expr: Expr, sym: Int)
#     SFor(info: Info, name: String, iterable: Expr, body: [Stmt], sym: Int)
#     SWhile(info: Info, cond: Expr, body: [Stmt], sym: Int)
#     SLoop(info: Info, target: AssignTarget?, init: Expr?, type: Type?,
#           body: [Stmt], sym: Int)
#     SBreak(info: Info, expr: Expr?, sym: Int)
#     SContinue(info: Info, expr: Expr?, sym: Int)
#     SIf(info: Info, cond: Expr, then_body: [Stmt], else_body: [Stmt]?,
#         sym: Int)
#     SFunctionDef(info: Info, name: String, params: [Param],
#                  body: [Stmt], return_type: Type?, sym: Int)
#     SFunctionSig(info: Info, name: String, type: Type, sym: Int)
#     SMatch(info: Info, subject: Expr, cases: [MatchCase], sym: Int)
#
# datatype Param:
#     Param(info: Info, name: String, type: Type?, sym: Int)
#
# datatype ListRest:
#     ListRest(info: Info, name: String?, sym: Int)
#
# datatype MatchCase:
#     MatchCase(info: Info, pattern: Pattern, body: [Stmt], sym: Int)


# --- expression AST ---

class Expr:
    """Base class for the expression AST."""


@dataclass(frozen=True)
class EInt(Expr):
    info: Info
    value: int
    sym: int = 0


@dataclass(frozen=True)
class EString(Expr):
    info: Info
    value: str
    sym: int = 0


@dataclass(frozen=True)
class EBool(Expr):          # 'true' / 'false'
    info: Info
    value: bool
    sym: int = 0


@dataclass(frozen=True)
class EVar(Expr):
    info: Info
    name: str
    sym: int = 0


@dataclass(frozen=True)
class EAdd(Expr):           # left + right
    info: Info
    left: Expr
    right: Expr
    sym: int = 0


@dataclass(frozen=True)
class ESub(Expr):           # left - right
    info: Info
    left: Expr
    right: Expr
    sym: int = 0


@dataclass(frozen=True)
class EMul(Expr):           # left * right
    info: Info
    left: Expr
    right: Expr
    sym: int = 0


@dataclass(frozen=True)
class EDiv(Expr):           # left / right
    info: Info
    left: Expr
    right: Expr
    sym: int = 0


@dataclass(frozen=True)
class ENeg(Expr):           # -operand (unary minus)
    info: Info
    operand: Expr
    sym: int = 0


@dataclass(frozen=True)
class EConcat(Expr):        # left ++ right (string and list concatenation)
    info: Info
    left: Expr
    right: Expr
    sym: int = 0


@dataclass(frozen=True)
class ELessThan(Expr):      # left < right
    info: Info
    left: Expr
    right: Expr
    sym: int = 0


@dataclass(frozen=True)
class ELessThanEq(Expr):    # left <= right
    info: Info
    left: Expr
    right: Expr
    sym: int = 0


@dataclass(frozen=True)
class EGreatThan(Expr):     # left > right
    info: Info
    left: Expr
    right: Expr
    sym: int = 0


@dataclass(frozen=True)
class EGreatThanEq(Expr):   # left >= right
    info: Info
    left: Expr
    right: Expr
    sym: int = 0


@dataclass(frozen=True)
class EEq(Expr):            # left == right
    info: Info
    left: Expr
    right: Expr
    sym: int = 0


@dataclass(frozen=True)
class ECall(Expr):          # func(args...)
    info: Info
    func: Expr
    args: list
    sym: int = 0


@dataclass(frozen=True)
class EList(Expr):          # [elements...]
    info: Info
    elements: list
    sym: int = 0


@dataclass(frozen=True)
class ETuple(Expr):         # (e1, e2, ...); () is the empty/Unit tuple,
    info: Info              # (e,) is a singleton -- built from either a
    elements: list          # parenthesized or a bare comma-separated form
    sym: int = 0


@dataclass(frozen=True)
class EIf(Expr):            # if cond then then_expr else else_expr
    info: Info              # (Pyking extension; `else` is mandatory, unlike
    cond: Expr              # the `if` *statement*, so that every `else`
    then_expr: Expr         # has exactly one possible owner -- see the
    else_expr: Expr         # "if expressions" notes in PYKING.md)
    sym: int = 0


# --- type AST (for optional parameter/return type annotations) ---

class Type:
    """Base class for the type-annotation AST."""


@dataclass(frozen=True)
class TInt(Type):           # Int
    info: Info
    sym: int = 0


@dataclass(frozen=True)
class TString(Type):        # String
    info: Info
    sym: int = 0


@dataclass(frozen=True)
class TBool(Type):          # Bool
    info: Info
    sym: int = 0


@dataclass(frozen=True)
class TList(Type):          # [element]
    info: Info
    element: Type
    sym: int = 0


@dataclass(frozen=True)
class TTuple(Type):         # (e1, e2, ...); zero elements is the Unit type "()"
    info: Info
    elements: list
    sym: int = 0


@dataclass(frozen=True)
class TOr(Type):            # T1 | T2 | ...
    info: Info              # A value of this type is one of the alternatives.
    alternatives: list      # How an *inferred* name that means different
    sym: int = 0            # things in different places is described:
                            # `Int | String` (see docs/type_inference.md).
                            # Unrelated to `TVar`, which is a variable an
                            # annotation wrote and a caller chooses; the two
                            # may not be mixed in one signature.


@dataclass(frozen=True)
class TUnknown(Type):       # ?
    info: Info              # A type nothing has decided yet: an unannotated
    sym: int = 0            # parameter or return type, standing in until a
                            # call site says what it is. Never written in
                            # source, and never the final answer for anything
                            # the checker finished checking.


@dataclass(frozen=True)
class TNever(Type):         # !
    info: Info               # The type of something that never happens:
    sym: int = 0             # what a loop nothing breaks out of supplies,
                             # since it has no way to finish. Every type
                             # accepts it (there is no value to be wrong
                             # about), which is what lets a function whose
                             # body is such a loop honour any return type.
                             # Never written in source and never inferred
                             # for an expression.


@dataclass(frozen=True)
class TBuiltin(Type):       # builtin print
    info: Info               # The type of a name denoting a host operation:
    name: str                # print, range, str and len. They are callable and
    sym: int = 0             # nothing else, and none of them fits a TFunction
                             # (a variadic print is not a (T) -> ()), so the
                             # call is checked by its own rule rather than
                             # against a parameter list. Never written in
                             # source, never inferred for an expression, and
                             # never recorded in the type checker's tmap -- so
                             # it does not reach printed output either.


@dataclass(frozen=True)
class TFunction(Type):      # (T1, T2, ...) -> T
    info: Info               # The parameter list is always parenthesized, so a
    params: list             # function of one *tuple* is ((Int, Bool)) -> Int
    result: Type             # and a function of two is (Int, Bool) -> Int.
    sym: int = 0
    # Built two ways: written in the source, where `parse_type` reads a
    # parenthesized list followed by `->` as one (a list *not* followed by
    # `->` is a `TTuple`), and by the type checker, which puts a `def`'s
    # separately written parts (`p:Int`, `-> Int`) together into the
    # function's own type.
    #
    # The last two fields belong to a function whose type is not fully
    # written down, and are the type checker's alone -- nothing in the
    # source produces them, and no printer shows them. `definition` is
    # the `def` whose body is still to be checked, and its presence is
    # what says this type is a promise rather than an answer; `tmsym` is
    # that definition's symbol (`definition.sym`), which is how the
    # checker names it in the tables it keeps -- a symbol rather than an
    # object, so that two types built for one `def` at different moments
    # are the same function by value. Both are ignored when two function
    # types are compared: what a function *is* is its parameters and its
    # result (see `same_type` in src/typesystem.py, and
    # docs/type_inference.md).
    tmsym: int = 0
    definition: object = None


@dataclass(frozen=True)
class TVar(Type):           # a lowercase name: a type the caller chooses
    info: Info               # Bound by the `TForall` around it -- every free
    name: str                # variable of a written annotation is quantified
    sym: int = 0             # at its outermost level, so one never escapes
                             # (see PYKING.md, "Type variables").


@dataclass(frozen=True)
class TForall(Type):        # all a b. body
    info: Info               # The variables `body` may be instantiated at.
    vars: list               # list[str]. Written only where it is *not* the
    body: Type = None        # outermost quantifier: that one is implicit,
    sym: int = 0             # supplied by the parser and left unprinted, so
                             # `(a) -> a` and `all a. (a) -> a` are one type.
                             # A nested one is first-class polymorphism and
                             # is both written and printed.


# Whether `--symbols` asked for each node's symbol number to be shown
# (see `symbolize` in src/analyses.py). This is a module-level display
# setting rather than a parameter threaded through every printer:
# `pprint_program` is the only entry point any caller uses (see
# `src/pyk.py` and `tools/playground/generator.py`), it sets and
# restores this around its one call, and the printers are pure and
# single-threaded -- so nothing can observe the flag outside that call,
# and no recursive call site has to remember to pass it along.
_show_symbols = False

# The types the type checker inferred, as symbol -> `Type`, when
# `pprint_program` was given them (see `type_check` in
# `src/typesystem.py`); `None` when it was not, which is every mode but
# `--typecheck`. A display setting for the same reasons `_show_symbols`
# is one, set and restored by the same single entry point -- and needed
# because the checker no longer writes what it inferred into the AST,
# so a printer that only looked at the node would show what the *source*
# annotated instead.
_tmap = None

def _sym(node, text):
    """Appends the node's symbol number to text if --symbols was
    requested; returns text unchanged otherwise. a -> String -> String"""
    if not _show_symbols:
        return text
    body = text if isinstance(node, _SELF_DELIMITED) else f"({text})"
    return f"{body}@{node.sym}"


def pprint_type(t):
    """Formats one type. The outermost `all` is not printed: every free
    variable of a written annotation is quantified there, so the
    quantifier carries no information the type does not already show,
    and leaving it off is what keeps `(a) -> a` printing as it was
    written. A nested one *is* printed. Type -> String"""
    match t:
        case TForall(_, _, body):
            return _sym(t, _pprint_type(body))
    return _sym(t, _pprint_type(t))


def _grouped(t):
    """A type as it must be written where something follows it: an `all`
    reaches to the end of the type, so one used as an element or a
    parameter is parenthesized. Type -> String"""
    if isinstance(t, TForall):
        return f"({pprint_type_nested(t)})"
    return pprint_type(t)


def pprint_type_nested(t):
    """Formats one type with its outermost `all` shown -- what a type
    *inside* another is printed as. Type -> String"""
    return _sym(t, _pprint_type(t))


def pprint_param(p):
    """Formats one parameter. Param -> String"""
    return _sym(p, _pprint_param(p))


def pprint_expr(e, min_prec=0):
    """Formats one expression, parenthesized if needed for min_prec.
    Expr -> Int -> String"""
    return _sym(e, _pprint_expr(e, min_prec))


def pprint_pattern(p):
    """Formats one pattern. Pattern -> String"""
    return _sym(p, _pprint_pattern(p))


def pprint_comp_clause(c):
    """Formats one list-comprehension clause. CompClause -> String"""
    return _sym(c, _pprint_comp_clause(c))


def pprint_target(t):
    """Formats one assignment target. AssignTarget -> String"""
    return _sym(t, _pprint_target(t))


def pprint_stmt(s, level=0):
    """Formats one statement, indented to level. A multi-line
    statement's symbol (under --symbols) goes on its header line.
    Stmt -> Int -> String"""
    text = _pprint_stmt(s, level)
    if not _show_symbols:
        return text
    head, *rest = text.split("\n")
    return "\n".join([f"{head}  @{s.sym}"] + rest)


def _pprint_type(t):
    match t:
        case TInt(_):
            return "Int"
        case TString(_):
            return "String"
        case TBool(_):
            return "Bool"
        case TList(_, element):
            return f"[{_grouped(element)}]"
        case TTuple(_, elements):
            return f"({', '.join(_grouped(e) for e in elements)})"
        case TOr(_, alternatives):
            # `|` binds looser than anything else a type can be, so the
            # alternatives never need parentheses of their own -- except a
            # function type, whose `->` would otherwise swallow what
            # follows it.
            return " | ".join(
                f"({pprint_type_nested(a)})"
                if isinstance(a, (TFunction, TForall)) else pprint_type(a)
                for a in alternatives
            )
        case TUnknown(_):
            # Only ever printed for something the checker was asked about
            # before anything had decided it -- a parameter of a function
            # nothing calls. It is deliberately not spellable in source:
            # there is nothing a program could mean by it.
            return "?"
        case TNever(_):
            # A binding whose value never arrives, which only unreachable
            # code can have. Not spellable in source either.
            return "!"
        case TBuiltin(_, name):
            # A host operation, which is not a value and so is never the
            # type of anything printed. Here for the sake of covering the
            # datatype; not spellable in source.
            return f"builtin {name}"
        case TFunction(_, params, result):
            # The parentheses are the parameter *list*'s, not a tuple's, so
            # one parameter that happens to be a tuple keeps its own pair:
            # `((Int, Bool)) -> Int` takes one pair, `(Int, Bool) -> Int`
            # takes two.
            return (f"({', '.join(_grouped(p) for p in params)})"
                    f" -> {pprint_type(result)}")
        case TVar(_, name):
            return name
        case TForall(_, vars, body):
            return f"all {' '.join(vars)}. {pprint_type(body)}"


@dataclass(frozen=True)
class Param:                # name[:type]
    info: Info
    name: str
    type: Type = None
    sym: int = 0


def _pprint_param(p):
    type_ = _node_type(p, p.type)
    if type_ is None:
        return p.name
    return f"{p.name}:{_pprint_annotation_type(type_)}"


def _wrap(prec, min_prec, s):
    return f"({s})" if prec < min_prec else s


_PRINT_ESCAPES = {
    "\\": "\\\\",
    "'": "\\'",
    "\n": "\\n",
    "\t": "\\t",
    "\r": "\\r",
}


def _quote_string(s):
    # Always delimit with single quotes and escape whatever the lexer's
    # `scan_string` can decode back (backslash, the quote itself, and the
    # non-printable escapes), so the output round-trips through the lexer.
    body = "".join(_PRINT_ESCAPES.get(ch, ch) for ch in s)
    return f"'{body}'"


def _pprint_expr(e, min_prec=0):
    # min_prec is the precedence required by the surrounding context; a
    # sub-expression built from a lower-precedence operator is parenthesized
    # so re-parsing the printed form reproduces the same AST.
    match e:
        case EInt(_, v):
            return str(v)
        case EString(_, s):
            return _quote_string(s)
        case EBool(_, v):
            return "true" if v else "false"
        case EVar(_, name):
            return name
        case EAdd(_, l, r):
            return _wrap(2, min_prec, f"{pprint_expr(l, 2)} + {pprint_expr(r, 3)}")
        case ESub(_, l, r):
            return _wrap(2, min_prec, f"{pprint_expr(l, 2)} - {pprint_expr(r, 3)}")
        case EMul(_, l, r):
            return _wrap(3, min_prec, f"{pprint_expr(l, 3)} * {pprint_expr(r, 4)}")
        case EDiv(_, l, r):
            return _wrap(3, min_prec, f"{pprint_expr(l, 3)} / {pprint_expr(r, 4)}")
        case ENeg(_, operand):
            # Unary minus binds tighter than `*`/`/` (so `-x * y` needs no
            # parens and means `(-x) * y`), which is precedence 4 here. Its
            # operand prints at 5, one above everything with a precedence,
            # so any operator underneath is parenthesized -- `-(x * y)` --
            # while an atom or call stays bare: `-x`, `-f(x)`. Nested
            # negation is parenthesized too: `-(-5)` rather than `--5`,
            # which parses the same but reads like a typo.
            return _wrap(4, min_prec, f"-{pprint_expr(operand, 5)}")
        case EConcat(_, l, r):
            # Concatenation sits at the additive level and associates to
            # the left, like `+`; the two never mix, since one takes Ints
            # and the other does not.
            return _wrap(2, min_prec, f"{pprint_expr(l, 2)} ++ {pprint_expr(r, 3)}")
        case ELessThan(_, l, r):
            return _wrap(1, min_prec, f"{pprint_expr(l, 2)} < {pprint_expr(r, 2)}")
        case ELessThanEq(_, l, r):
            return _wrap(1, min_prec, f"{pprint_expr(l, 2)} <= {pprint_expr(r, 2)}")
        case EGreatThan(_, l, r):
            return _wrap(1, min_prec, f"{pprint_expr(l, 2)} > {pprint_expr(r, 2)}")
        case EGreatThanEq(_, l, r):
            return _wrap(1, min_prec, f"{pprint_expr(l, 2)} >= {pprint_expr(r, 2)}")
        case EEq(_, l, r):
            return _wrap(1, min_prec, f"{pprint_expr(l, 2)} == {pprint_expr(r, 2)}")
        case ECall(_, f, args):
            # The callee prints at 5 so a negated one keeps its parens:
            # `(-f)(x)` calls the negation, `-f(x)` negates the result.
            return f"{pprint_expr(f, 5)}({', '.join(pprint_expr(a) for a in args)})"
        case EList(_, elements):
            return f"[{', '.join(pprint_expr(e) for e in elements)}]"
        case EListComp(_, expr, clauses):
            clauses_str = " ".join(pprint_comp_clause(c) for c in clauses)
            return f"[{pprint_expr(expr)} {clauses_str}]"
        case ETuple(_, elements):
            # Canonical printed form is always fully parenthesized (with a
            # trailing comma for the singleton case), regardless of
            # whether the source used the bare or parenthesized form.
            match elements:
                case [single]:
                    return f"({pprint_expr(single)},)"
                case _:
                    return f"({', '.join(pprint_expr(e) for e in elements)})"
        case EIf(_, cond, then_expr, else_expr):
            # Precedence 0: lower than every operator, so an if expression
            # used as any operand gets parenthesized. `cond`/`then_expr`
            # print at 1 so a *nested* if expression there is parenthesized
            # too (it would still re-parse unambiguously without the
            # parens -- `else` being mandatory guarantees that -- but
            # `if if p then q else r then b else c` is unreadable). The
            # else branch prints at 0 so the common `else if ...` chain
            # stays flat, which is both readable and right-associative,
            # matching how it parses.
            return _wrap(0, min_prec, (
                f"if {pprint_expr(cond, 1)} then {pprint_expr(then_expr, 1)} "
                f"else {pprint_expr(else_expr)}"
            ))


# --- pattern AST (for `match`/`case`) ---

class Pattern:
    """Base class for match-case patterns."""


@dataclass(frozen=True)
class PInt(Pattern):        # case 0:
    info: Info
    value: int
    sym: int = 0


@dataclass(frozen=True)
class PString(Pattern):     # case "foo":
    info: Info
    value: str
    sym: int = 0


@dataclass(frozen=True)
class PBool(Pattern):       # case true: / case false:
    info: Info
    value: bool
    sym: int = 0


@dataclass(frozen=True)
class PWildcard(Pattern):   # case _:
    info: Info
    sym: int = 0


@dataclass(frozen=True)
class PCapture(Pattern):    # case name: (binds `name` to the matched value)
    info: Info
    name: str
    sym: int = 0


@dataclass(frozen=True)
class PTuple(Pattern):      # case (p1, p2, ...): destructures a tuple value
    info: Info
    elements: list
    sym: int = 0


@dataclass(frozen=True)
class ListRest:              # the `..` / `..name` rest marker inside a PList
    info: Info
    name: str = None         # None: `..` (matches and discards the rest);
                              # otherwise `..name` (matches and binds the rest)
    sym: int = 0


@dataclass(frozen=True)
class PList(Pattern):        # case [p1, ..., pk]: destructures a list value;
    info: Info               # at most one `rest` marker, appearing anywhere
    prefix: list              # among the elements (prefix/suffix split around it)
    rest: ListRest = None    # None => exact-length list (no rest marker present)
    suffix: list = None      # elements after `rest`; empty/None if no rest marker
    sym: int = 0


def _pprint_pattern(p):
    match p:
        case PInt(_, v):
            return str(v)
        case PString(_, s):
            return _quote_string(s)
        case PBool(_, v):
            return "true" if v else "false"
        case PWildcard(_):
            return "_"
        case PCapture(_, name):
            return name
        case PTuple(_, elements):
            match elements:
                case [single]:
                    return f"({pprint_pattern(single)},)"
                case _:
                    return f"({', '.join(pprint_pattern(e) for e in elements)})"
        case PList(_, prefix, rest, suffix):
            parts = [pprint_pattern(e) for e in prefix]
            if rest is not None:
                parts.append(f"..{rest.name}" if rest.name is not None else "..")
            parts += [pprint_pattern(e) for e in (suffix or [])]
            return f"[{', '.join(parts)}]"


# --- list comprehension AST (depends on Pattern, so defined after it) ---

class CompClause:
    """Base class for list-comprehension clauses."""


@dataclass(frozen=True)
class CompFor(CompClause):   # for pattern in sequence
    info: Info
    pattern: Pattern
    sequence: Expr
    sym: int = 0


@dataclass(frozen=True)
class CompIf(CompClause):    # if condition
    info: Info
    condition: Expr
    sym: int = 0


@dataclass(frozen=True)
class EListComp(Expr):       # [expr for pattern in seq {for ... | if ...}]
    info: Info
    expr: Expr
    clauses: list             # list[CompClause]; first is always a CompFor
    sym: int = 0


def _pprint_comp_clause(c):
    # Both sub-expressions print at min_prec 1 so that an `EIf` (precedence
    # 0) is parenthesized here. In a comprehension the surrounding grammar
    # already spells `for`/`in`/`if`, so an unparenthesized if expression
    # would run straight into it: `if if a then b else c` for a filter, and
    # `for x in if a then b else c` for a sequence. The Pyking parser
    # actually recovers from both, but the printed form is meant to be
    # readable and to match `target_python.py`, whose equivalent parens are
    # mandatory (Python's own comprehension grammar excludes conditional
    # expressions in exactly these two positions -- see the comment on
    # `pprint_py_comp_clause`).
    match c:
        case CompFor(_, pattern, sequence):
            return f"for {pprint_pattern(pattern)} in {pprint_expr(sequence, 1)}"
        case CompIf(_, condition):
            return f"if {pprint_expr(condition, 1)}"


@dataclass(frozen=True)
class MatchCase:
    # case pattern: body -- the body being the block written under the
    # clause, or the one statement written on its own line.
    info: Info
    pattern: Pattern
    body: list = None    # list[Stmt]
    sym: int = 0


# --- assignment target AST (the left-hand side of `=`, which may
# destructure a tuple) ---

class AssignTarget:
    """Base class for `=`-binding targets."""


@dataclass(frozen=True)
class TargetName(AssignTarget):   # name
    info: Info
    name: str
    sym: int = 0


@dataclass(frozen=True)
class TargetTuple(AssignTarget):  # (t1, t2, ...) destructuring target
    info: Info
    elements: list
    sym: int = 0


def _pprint_target(t):
    match t:
        case TargetName(_, name):
            return name
        case TargetTuple(_, elements):
            match elements:
                case [single]:
                    return f"({pprint_target(single)},)"
                case _:
                    return f"({', '.join(pprint_target(e) for e in elements)})"


# --- statement AST ---

class Stmt:
    """Base class for the statement AST."""


@dataclass(frozen=True)
class SLet(Stmt):           # target[: type] = expr (immutable binding;
    info: Info               # target may destructure a tuple)
    target: AssignTarget
    expr: Expr
    # The binding's type as the *source* wrote it, or `None` where the
    # annotation was left out -- nothing else fills this in. The type
    # checker (`src/typesystem.py`, run only under `--typecheck`) reads
    # it, to check it against what the right-hand side turned out to be,
    # but does not write it: it leaves the AST alone and records what it
    # inferred in its own symbol -> type table instead. `pprint_program`
    # prints from that table when given one, and from this field
    # otherwise.
    type: Type = None
    sym: int = 0


@dataclass(frozen=True)
class SLetStmt(Stmt):       # target = <if/match statement in value form>,
    info: Info               # e.g. `x = if c:` / `x = match e:` -- Pyking
    target: AssignTarget     # extension. `stmt` is the SIf/SMatch itself;
    stmt: Stmt               # the value bound is the last expression of
                             # whichever branch runs, so every branch must
                             # end in one (and an `if` must have its `else`)
                             # -- checked by the parser, since neither
                             # restriction is expressible in the grammar.
    type: Type = None        # as `SLet.type`; both come from the single
                             # `assignment` grammar rule.
    sym: int = 0


@dataclass(frozen=True)
class SVar(Stmt):           # var name = expr (mutable declaration)
    info: Info
    name: str
    expr: Expr
    sym: int = 0


@dataclass(frozen=True)
class SMutate(Stmt):        # name := expr (mutation of a `var`)
    info: Info
    name: str
    expr: Expr
    sym: int = 0


@dataclass(frozen=True)
class SReturn(Stmt):        # return expr
    info: Info
    expr: Expr
    sym: int = 0


@dataclass(frozen=True)
class SReturnStmt(Stmt):    # return <if/match statement in value form>,
    info: Info               # e.g. `return if c:` / `return match e:` --
    stmt: Stmt               # Pyking extension, the `return` counterpart of
                             # `SLetStmt`. `stmt` is the SIf/SMatch itself;
                             # the value returned is the last expression of
                             # whichever branch runs, so every branch must
                             # end in one (and an `if` must have its
                             # `else`) -- the same rules `SLetStmt` obeys,
                             # checked by the same parser code.
    sym: int = 0


@dataclass(frozen=True)
class SExprStmt(Stmt):      # expr used as a statement, e.g. print(x)
    info: Info
    expr: Expr
    sym: int = 0


@dataclass(frozen=True)
class SFor(Stmt):           # for name in iterable: body
    info: Info
    name: str
    iterable: Expr
    body: list
    sym: int = 0


@dataclass(frozen=True)
class SWhile(Stmt):         # while cond: body
    info: Info
    cond: Expr
    body: list
    sym: int = 0


@dataclass(frozen=True)
class SLoop(Stmt):          # loop [target[: type] = init]: body
    info: Info               # Pyking extension: a loop whose state is a
    target: AssignTarget      # binding rather than a mutable variable. The
    init: Expr                # body's value (tail position, as everywhere
                              # else) is the accumulator for the next turn,
                              # and the loop's own value is the accumulator
                              # it stopped with. `target`/`init` are both
                              # None for the bare `loop:`, whose accumulator
                              # is unit and whose body's value is discarded.
    type: Type = None         # as `SLet.type`: what the source annotated,
                              # never written back by the type checker.
    body: list = None
    sym: int = 0


@dataclass(frozen=True)
class SBreak(Stmt):         # break [expr]
    info: Info               # Ends the innermost enclosing `loop`. With no
    expr: Expr = None        # operand the loop yields the accumulator it
    sym: int = 0             # has; with one, that operand.


@dataclass(frozen=True)
class SContinue(Stmt):      # continue [expr]
    info: Info               # Starts the innermost enclosing loop's next
    expr: Expr = None        # turn, with the same accumulator or with the
    sym: int = 0             # operand as the new one.


@dataclass(frozen=True)
class SIf(Stmt):            # if cond: then_body [else: else_body]
    info: Info
    cond: Expr
    then_body: list
    else_body: list = None
    sym: int = 0


@dataclass(frozen=True)
class SFunctionDef(Stmt):   # def name(params...) [-> return_type]: body
    info: Info
    name: str
    params: list         # list[Param]
    body: list = None    # list[Stmt]
    return_type: Type = None
    sym: int = 0


@dataclass(frozen=True)
class SFunctionSig(Stmt):   # def name : type -- Pyking extension
    info: Info               # A `def`'s type written on a line of its own,
    name: str                # instead of a piece at a time on the header.
    type: Type = None        # It names a `def` in the same block, which then
    sym: int = 0             # writes no annotations of its own (see
                             # PYKING.md, "Type variables"). Carries no body:
                             # it says what a definition elsewhere is, and
                             # produces nothing by itself.


@dataclass(frozen=True)
class SMatch(Stmt):         # match subject: case pattern: body ...
    info: Info
    subject: Expr
    cases: list
    sym: int = 0


def _pprint_stmt(s, level=0):
    pad = "    " * level
    match s:
        case SLet(_, target, expr, type_):
            return (
                f"{pad}{pprint_target(target)}{_annotation(s, type_)} "
                f"= {pprint_expr(expr)}"
            )
        case SLetStmt(_, target, stmt, type_):
            # The bound statement prints exactly as it would on its own;
            # only its header line gains the `target = ` prefix.
            head, *rest = pprint_stmt(stmt, level).split("\n")
            prefix = f"{pad}{pprint_target(target)}{_annotation(s, type_)} = "
            return "\n".join([prefix + head.strip()] + rest)
        case SVar(_, name, expr):
            return f"{pad}var {name} = {pprint_expr(expr)}"
        case SMutate(_, name, expr):
            return f"{pad}{name} := {pprint_expr(expr)}"
        case SReturn(_, expr):
            return f"{pad}return {pprint_expr(expr)}"
        case SReturnStmt(_, stmt):
            # Same shape as `SLetStmt` above: the returned statement prints
            # exactly as it would on its own, and only its header line
            # gains the `return ` prefix.
            head, *rest = pprint_stmt(stmt, level).split("\n")
            return "\n".join([f"{pad}return {head.strip()}"] + rest)
        case SExprStmt(_, expr):
            return f"{pad}{pprint_expr(expr)}"
        case SFor(_, name, iterable, body):
            lines = [f"{pad}for {name} in {pprint_expr(iterable)}:"]
            lines += [pprint_stmt(st, level + 1) for st in body]
            return "\n".join(lines)
        case SWhile(_, cond, body):
            lines = [f"{pad}while {pprint_expr(cond)}:"]
            lines += [pprint_stmt(st, level + 1) for st in body]
            return "\n".join(lines)
        case SLoop(_, target, init, type_, body):
            # The accumulator prints like a binding, annotation and all,
            # so a `--typecheck --ast` run's header re-parses; a `loop:`
            # with no accumulator has nothing to annotate.
            if target is None:
                lines = [f"{pad}loop:"]
            else:
                lines = [
                    f"{pad}loop {pprint_target(target)}{_annotation(s, type_)}"
                    f" = {pprint_expr(init)}:"
                ]
            lines += [pprint_stmt(st, level + 1) for st in body]
            return "\n".join(lines)
        case SBreak(_, expr):
            return f"{pad}break" if expr is None else f"{pad}break {pprint_expr(expr)}"
        case SContinue(_, expr):
            return (f"{pad}continue" if expr is None
                    else f"{pad}continue {pprint_expr(expr)}")
        case SIf(_, cond, then_body, else_body):
            lines = [f"{pad}if {pprint_expr(cond)}:"]
            lines += [pprint_stmt(st, level + 1) for st in then_body]
            # An else body that is exactly one if statement prints flat, as
            # the `else if` ladder form -- which is precisely what the
            # parser desugars an `else if` into (see `parse_if_stmt_tail`),
            # so this re-parses to the same AST while keeping a long ladder
            # from marching one indent level right per branch.
            while True:
                match else_body:
                    case [SIf(_, elif_cond, elif_body, else_body2)]:
                        lines.append(f"{pad}else if {pprint_expr(elif_cond)}:")
                        lines += [pprint_stmt(st, level + 1) for st in elif_body]
                        else_body = else_body2
                    case None:
                        break
                    case _:
                        lines.append(f"{pad}else:")
                        lines += [pprint_stmt(st, level + 1) for st in else_body]
                        break
            return "\n".join(lines)
        case SFunctionSig(_, name, type_):
            return f"{pad}def {name} : {pprint_type_nested(type_)}"
        case SFunctionDef(_, name, params, body, return_type):
            header = _function_header(s, pad, name, params, return_type)
            lines = [header + ":"]
            lines += [pprint_stmt(st, level + 1) for st in body]
            return "\n".join(lines)
        case SMatch(_, subject, cases):
            lines = [f"{pad}match {pprint_expr(subject)}:"]
            for c in cases:
                lines.append(f"{pad}    case {pprint_pattern(c.pattern)}:")
                lines += [pprint_stmt(st, level + 2) for st in c.body]
            return "\n".join(lines)


# Nodes whose printed form is already a single token or already
# bracketed, so appending `@n` to it cannot be misread. Everything else
# is parenthesized first: without that, `1 + 2` would print as
# `1@1 + 2@2@3`, where the last `@3` looks like it belongs to the `2`.
_SELF_DELIMITED = (
    EInt, EString, EBool, EVar, EList, ETuple, EListComp,
    TInt, TString, TBool, TList, TTuple,
    PInt, PString, PBool, PWildcard, PCapture, PTuple, PList,
    TargetName, TargetTuple,
)


def _node_type(node, annotation):
    """The type to print for a node: from tmap if one was given,
    otherwise the node's own annotation. Node -> Type? -> Type?"""
    if _tmap is None:
        return annotation
    return _tmap.get(node.sym)


def _pprint_annotation_type(t):
    """Formats a type in annotation position, without a symbol suffix
    when it came from tmap (a checker-built type has no symbol of its
    own). Type -> String"""
    if _tmap is None:
        return pprint_type(t)
    global _show_symbols
    saved = _show_symbols
    _show_symbols = False
    try:
        return pprint_type(t)
    finally:
        _show_symbols = saved


def _annotation(node, type_):
    """Formats `: Type` for a node whose type is known, "" otherwise.
    Node -> Type? -> String"""
    type_ = _node_type(node, type_)
    return "" if type_ is None else f": {_pprint_annotation_type(type_)}"


def _function_header(node, pad, name, params, return_type):
    """Formats `def name(params) -> result`, from tmap where given.
    A function with several inferred types (see docs/type_inference.md)
    prints as written, with no annotations, since the syntax has no way
    to keep each call's parameters and result together.
    SFunctionDef -> String -> String -> [Param] -> Type? -> String"""
    global _tmap
    saved = _tmap
    if isinstance(_tmap.get(node.sym) if _tmap is not None else None, TOr):
        _tmap = None
    if node.sym in _signed:
        # Its type is on a `def name : type` line of its own, and a
        # definition says its type in one place or the other -- printing
        # both would give a program this checker refuses.
        _tmap = None
    try:
        return (f"{pad}def {name}({', '.join(pprint_param(p) for p in params)})"
                + _return_annotation(node, return_type))
    finally:
        _tmap = saved


def _return_annotation(node, return_type):
    """Formats ` -> Type` for a function whose return type is known,
    "" otherwise. SFunctionDef -> Type? -> String"""
    if _tmap is not None:
        # tmap holds the function's whole type; only its result is
        # printed here (the parameters are printed one by one already).
        # An `all` around it binds the whole signature, so it is stepped
        # through rather than printed on the result alone.
        return_type = _tmap.get(node.sym)
        if isinstance(return_type, TForall):
            return_type = return_type.body
        if isinstance(return_type, TFunction):
            return_type = return_type.result
    return "" if return_type is None else f" -> {_pprint_annotation_type(return_type)}"


def pprint_program(stmts, symbols=False, tmap=None):
    """Formats a whole program as Pyking source. symbols=True appends
    each node's symbol as @n. tmap, if given, is the type checker's
    symbol -> Type table; every annotation then comes from it instead
    of from the source.
    [Stmt] -> Bool -> {Int: Type}? -> String"""
    global _show_symbols, _tmap, _signed
    _show_symbols = symbols
    _tmap = tmap
    _signed = _signed_defs(stmts)
    try:
        return "\n".join(pprint_stmt(s) for s in stmts)
    finally:
        _show_symbols = False
        _tmap = None
        _signed = frozenset()


# The definitions whose type is written on a `def name : type` line
# rather than on their own header. Those print no annotations, since
# writing both is a program the checker refuses. Computed once per
# program because a block is printed in eight different places here and
# a set threaded through all of them would be eight chances to forget.
_signed = frozenset()


def _signed_defs(node):
    """The symbols of definitions that a signature line in their own
    block describes. Node -> {Int}"""
    found = set()

    def walk(node):
        if isinstance(node, list):
            names = {s.name for s in node if isinstance(s, SFunctionSig)}
            found.update(s.sym for s in node
                         if isinstance(s, SFunctionDef) and s.name in names)
            for item in node:
                walk(item)
        elif is_dataclass(node):
            for f in fields(node):
                walk(getattr(node, f.name))

    walk(node)
    return frozenset(found)
