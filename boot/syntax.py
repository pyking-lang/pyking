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
            return f"{pprint_expr(f, 4)}({', '.join(pprint_expr(a) for a in args)})"
        case EList(_, elements):
            return f"[{', '.join(pprint_expr(e) for e in elements)}]"
        case ETuple(_, elements):
            # Canonical printed form is always fully parenthesized (with a
            # trailing comma for the singleton case), regardless of
            # whether the source used the bare or parenthesized form.
            match elements:
                case [single]:
                    return f"({pprint_expr(single)},)"
                case _:
                    return f"({', '.join(pprint_expr(e) for e in elements)})"


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


def pprint_pattern(p):
    match p:
        case PInt(_, v):
            return str(v)
        case PString(_, s):
            return _quote_string(s)
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
    info: Info
    name: str
    params: list         # list[Param]
    body: list
    return_type: Type = None


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
        case SVar(_, name, expr):
            return f"{pad}var {name} = {pprint_expr(expr)}"
        case SMutate(_, name, expr):
            return f"{pad}{name} := {pprint_expr(expr)}"
        case SReturn(_, expr):
            return f"{pad}return {pprint_expr(expr)}"
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
            if else_body is not None:
                lines.append(f"{pad}else:")
                lines += [pprint_stmt(st, level + 1) for st in else_body]
            return "\n".join(lines)
        case SFunctionDef(_, name, params, body, return_type):
            header = f"{pad}def {name}({', '.join(pprint_param(p) for p in params)})"
            if return_type is not None:
                header += f" -> {pprint_type(return_type)}"
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
