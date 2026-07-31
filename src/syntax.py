from dataclasses import dataclass

from lexer import Info


# --- expression AST ---

class Expr:
    """Base class for the expression AST."""


@dataclass(frozen=True)
class EInt(Expr):
    info: Info
    value: int


@dataclass(frozen=True)
class EString(Expr):
    info: Info
    value: str


@dataclass(frozen=True)
class EBool(Expr):          # 'true' / 'false'
    info: Info
    value: bool


@dataclass(frozen=True)
class EVar(Expr):
    info: Info
    name: str


@dataclass(frozen=True)
class EAdd(Expr):           # left + right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class ESub(Expr):           # left - right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class EMul(Expr):           # left * right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class EDiv(Expr):           # left / right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class ENeg(Expr):           # -operand (unary minus)
    info: Info
    operand: Expr


@dataclass(frozen=True)
class ELessThan(Expr):      # left < right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class ELessThanEq(Expr):    # left <= right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class EGreatThan(Expr):     # left > right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class EGreatThanEq(Expr):   # left >= right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class EEq(Expr):            # left == right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class ECall(Expr):          # func(args...)
    info: Info
    func: Expr
    args: list


@dataclass(frozen=True)
class EList(Expr):          # [elements...]
    info: Info
    elements: list


@dataclass(frozen=True)
class ETuple(Expr):         # (e1, e2, ...); () is the empty/Unit tuple,
    info: Info              # (e,) is a singleton -- built from either a
    elements: list          # parenthesized or a bare comma-separated form


@dataclass(frozen=True)
class EIf(Expr):            # if cond then then_expr else else_expr
    info: Info              # (Pyking extension; `else` is mandatory, unlike
    cond: Expr              # the `if` *statement*, so that every `else`
    then_expr: Expr         # has exactly one possible owner -- see the
    else_expr: Expr         # "if expressions" notes in PYKING.md)


# --- type AST (for optional parameter/return type annotations) ---

class Type:
    """Base class for the type-annotation AST."""


@dataclass(frozen=True)
class TInt(Type):           # Int
    info: Info


@dataclass(frozen=True)
class TString(Type):        # String
    info: Info


@dataclass(frozen=True)
class TBool(Type):          # Bool
    info: Info


@dataclass(frozen=True)
class TList(Type):          # [element]
    info: Info
    element: Type


@dataclass(frozen=True)
class TTuple(Type):         # (e1, e2, ...); zero elements is the Unit type "()"
    info: Info
    elements: list


def pprint_type(t):
    match t:
        case TInt(_):
            return "Int"
        case TString(_):
            return "String"
        case TBool(_):
            return "Bool"
        case TList(_, element):
            return f"[{pprint_type(element)}]"
        case TTuple(_, elements):
            return f"({', '.join(pprint_type(e) for e in elements)})"


@dataclass(frozen=True)
class Param:                # name[:type]
    info: Info
    name: str
    type: Type = None


def pprint_param(p):
    if p.type is None:
        return p.name
    return f"{p.name}:{pprint_type(p.type)}"


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


def pprint_expr(e, min_prec=0):
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


@dataclass(frozen=True)
class PString(Pattern):     # case "foo":
    info: Info
    value: str


@dataclass(frozen=True)
class PBool(Pattern):       # case true: / case false:
    info: Info
    value: bool


@dataclass(frozen=True)
class PWildcard(Pattern):   # case _:
    info: Info


@dataclass(frozen=True)
class PCapture(Pattern):    # case name: (binds `name` to the matched value)
    info: Info
    name: str


@dataclass(frozen=True)
class PTuple(Pattern):      # case (p1, p2, ...): destructures a tuple value
    info: Info
    elements: list


@dataclass(frozen=True)
class ListRest:              # the `..` / `..name` rest marker inside a PList
    info: Info
    name: str = None         # None: `..` (matches and discards the rest);
                              # otherwise `..name` (matches and binds the rest)


@dataclass(frozen=True)
class PList(Pattern):        # case [p1, ..., pk]: destructures a list value;
    info: Info               # at most one `rest` marker, appearing anywhere
    prefix: list              # among the elements (prefix/suffix split around it)
    rest: ListRest = None    # None => exact-length list (no rest marker present)
    suffix: list = None      # elements after `rest`; empty/None if no rest marker


def pprint_pattern(p):
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


@dataclass(frozen=True)
class CompIf(CompClause):    # if condition
    info: Info
    condition: Expr


@dataclass(frozen=True)
class EListComp(Expr):       # [expr for pattern in seq {for ... | if ...}]
    info: Info
    expr: Expr
    clauses: list             # list[CompClause]; first is always a CompFor


def pprint_comp_clause(c):
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
    # case pattern: body               (block form)
    # case pattern -> expr             (single-expression form; Pyking extension,
    #                                    not valid Python match syntax)
    # Exactly one of `body`/`expr` is set.
    info: Info
    pattern: Pattern
    body: list = None
    expr: Expr = None


# --- assignment target AST (the left-hand side of `=`, which may
# destructure a tuple) ---

class AssignTarget:
    """Base class for `=`-binding targets."""


@dataclass(frozen=True)
class TargetName(AssignTarget):   # name
    info: Info
    name: str


@dataclass(frozen=True)
class TargetTuple(AssignTarget):  # (t1, t2, ...) destructuring target
    info: Info
    elements: list


def pprint_target(t):
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
class SLet(Stmt):           # target = expr (immutable binding; target may
    info: Info               # destructure a tuple)
    target: AssignTarget
    expr: Expr


@dataclass(frozen=True)
class SLetStmt(Stmt):       # target = <if/match statement in value form>,
    info: Info               # e.g. `x = if c:` / `x = match e:` -- Pyking
    target: AssignTarget     # extension. `stmt` is the SIf/SMatch itself;
    stmt: Stmt               # the value bound is the last expression of
                             # whichever branch runs, so every branch must
                             # end in one (and an `if` must have its `else`)
                             # -- checked by the parser, since neither
                             # restriction is expressible in the grammar.


@dataclass(frozen=True)
class SVar(Stmt):           # var name = expr (mutable declaration)
    info: Info
    name: str
    expr: Expr


@dataclass(frozen=True)
class SMutate(Stmt):        # name := expr (mutation of a `var`)
    info: Info
    name: str
    expr: Expr


@dataclass(frozen=True)
class SReturn(Stmt):        # return expr
    info: Info
    expr: Expr


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


@dataclass(frozen=True)
class SExprStmt(Stmt):      # expr used as a statement, e.g. print(x)
    info: Info
    expr: Expr


@dataclass(frozen=True)
class SFor(Stmt):           # for name in iterable: body
    info: Info
    name: str
    iterable: Expr
    body: list


@dataclass(frozen=True)
class SWhile(Stmt):         # while cond: body
    info: Info
    cond: Expr
    body: list


@dataclass(frozen=True)
class SIf(Stmt):            # if cond: then_body [else: else_body]
    info: Info
    cond: Expr
    then_body: list
    else_body: list = None


@dataclass(frozen=True)
class SFunctionDef(Stmt):   # def name(params...) [-> return_type]: body
                             # def name(params...) [-> return_type] = expr
                             #   (single-expression form; Pyking extension,
                             #    not valid Python -- see MatchCase for the
                             #    analogous `case pattern -> expr`)
                             # Exactly one of `body`/`expr` is set.
    info: Info
    name: str
    params: list         # list[Param]
    body: list = None
    return_type: Type = None
    expr: Expr = None


@dataclass(frozen=True)
class SMatch(Stmt):         # match subject: case pattern: body ...
    info: Info
    subject: Expr
    cases: list


def pprint_stmt(s, level=0):
    pad = "    " * level
    match s:
        case SLet(_, target, expr):
            return f"{pad}{pprint_target(target)} = {pprint_expr(expr)}"
        case SLetStmt(_, target, stmt):
            # The bound statement prints exactly as it would on its own;
            # only its header line gains the `target = ` prefix.
            head, *rest = pprint_stmt(stmt, level).split("\n")
            return "\n".join([f"{pad}{pprint_target(target)} = {head.strip()}"] + rest)
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
        case SFunctionDef(_, name, params, body, return_type, expr):
            header = f"{pad}def {name}({', '.join(pprint_param(p) for p in params)})"
            if return_type is not None:
                header += f" -> {pprint_type(return_type)}"
            if expr is not None:
                return f"{header} = {pprint_expr(expr)}"
            lines = [header + ":"]
            lines += [pprint_stmt(st, level + 1) for st in body]
            return "\n".join(lines)
        case SMatch(_, subject, cases):
            lines = [f"{pad}match {pprint_expr(subject)}:"]
            for c in cases:
                if c.expr is not None:
                    lines.append(
                        f"{pad}    case {pprint_pattern(c.pattern)} -> {pprint_expr(c.expr)}"
                    )
                else:
                    lines.append(f"{pad}    case {pprint_pattern(c.pattern)}:")
                    lines += [pprint_stmt(st, level + 2) for st in c.body]
            return "\n".join(lines)


def pprint_program(stmts):
    return "\n".join(pprint_stmt(s) for s in stmts)
