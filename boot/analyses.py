"""Static analyses over the Pyking AST (`boot/syntax.py`).

Currently one analysis: names. Pyking is lexically scoped -- every name
resolves in the innermost enclosing scope that binds it, decided purely
by where it is written, and a scope's bindings never escape it. That is
checked here, after parsing and before any backend runs, so a name error
is reported against the source position rather than surfacing as broken
generated code (or, worse, as a program that runs and quietly means
something else).

The analysis is a single recursive walk carrying a *name environment*: a
mapping from a name in scope to the kind of binding that introduced it.
The environment is rebuilt rather than mutated (`bind` returns a new
dict), so entering a nested scope is just "keep using the environment you
were handed" and leaving one is "go back to using the caller's" -- there
is no scope stack to pop, and no way for a nested binding to leak out by
accident. Statement sequences thread the environment: each statement is
analyzed in the environment left by the ones before it.

Two rules are enforced (see "Names and scoping" in PYKING.md):

  1. Every name used must be bound, in the lexical sense above -- an
     enclosing scope, not merely somewhere earlier in the file.
  2. A `var` (mutable variable) may not be shadowed. Every other kind of
     binding shadows freely: a parameter, `for` variable, pattern
     variable, `def`, or `=` binding may reuse any name that is not a
     mutable one, including reusing its own name in a nested scope.

Rule 2 is what keeps `:=` unambiguous. `name := expr` updates the
mutable variable that `name` denotes; if some inner scope could rebind
that name to something immutable, a reader of `x := 1` would have to
scan every enclosing scope to know whether it updates the variable, is
an error, or silently updates a *different* variable of the same name.
Forbidding the shadow means the answer is always the nearest `var`.
"""

from dataclasses import dataclass

from lexer import Info
from syntax import (
    EInt, EString, EVar,
    EAdd, ESub, EMul, EDiv, ENeg,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EList, ETuple,
    EIf, EListComp, CompFor, CompIf,
    PInt, PString, PWildcard, PCapture, PTuple, PList,
    SLet, SLetStmt, SVar, SMutate, SReturn, SExprStmt, SFor, SWhile, SIf,
    SFunctionDef, SMatch,
    TargetName, TargetTuple,
)


class AnalysisError(Exception):
    """Raised for a name/scoping error; carries the source position of the
    offending name, like `LexError`/`ParseError` do for their stages."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


# --- kinds of binding ---
#
# The environment records which kind introduced each name, for two
# reasons: `MUTABLE` is the one kind that may not be shadowed and the one
# `:=` accepts, and naming the kind makes an error message say what the
# name actually is rather than just that it is wrong. It records the
# binding's `Info` alongside, so an error about a name can also point at
# where the name it collides with came from -- with lexical scoping that
# other line is the whole explanation, and it can be far away or in an
# enclosing scope the reader isn't looking at.

MUTABLE = "mutable variable"      # var name = ...
BINDING = "binding"               # name = ...
PARAMETER = "parameter"           # def f(name)
LOOP_VAR = "loop variable"        # for name in ...
PATTERN_VAR = "pattern variable"  # case ...name...:
FUNCTION = "function"             # def name(...)
BUILTIN = "builtin"               # see `BUILTINS`

# Pyking's grammar has no notion of a builtin -- any identifier can be a
# call target (see PYKING.md) -- but the generated Python runs against
# Python's, and a program calling `print` has not bound it anywhere. They
# are seeded into the top-level environment so that rule 1 above can flag
# every *other* unbound name instead of having to give up on all of them.
# Extend this when a Pyking program starts using another one.
BUILTINS = ("print", "range", "str", "len")


@dataclass(frozen=True)
class Binding:
    """What the environment records for a name in scope: the kind of
    binding that introduced it, and where that was."""
    kind: str
    info: Info = None    # None for a builtin, which has no source position


def where_bound(binding):
    """`" (declared on line 7)"` for an error message to hang off the
    name it is complaining about -- under lexical scoping the other line
    *is* the explanation, and it can be far away, or in an enclosing
    scope the reader is not currently looking at. A builtin has no source
    position to report, so it contributes nothing."""
    if binding.info is None:
        return ""
    return f" (declared on line {binding.info.row1})"


def bind(env, name, kind, info):
    """The environment `env` extended with `name` bound as `kind`.

    Rejects shadowing a mutable variable (rule 2 above). Note it is the
    *existing* binding that decides: what the new binding happens to be
    -- parameter, pattern variable, another `var` -- never matters, which
    is why every binding form in the walk below funnels through here."""
    existing = env.get(name)
    if existing is not None and existing.kind == MUTABLE:
        raise AnalysisError(
            info,
            f"cannot bind '{name}': the mutable variable '{name}'"
            f"{where_bound(existing)} is in scope, and a mutable variable may not "
            "be shadowed (update it with ':=', or choose another name)",
        )
    return {**env, name: Binding(kind, info)}


def check_bound(name, env, info):
    """Rule 1: the name must be bound in the environment reaching here."""
    if name not in env:
        raise AnalysisError(info, f"unbound name '{name}'")


def pattern_bindings(pattern):
    """The names `pattern` binds, as `(name, info)` pairs, in source
    order. Mirrors `_pattern_captures` in `parser.py` and
    `pattern_captured_names` in `target_python.py`; kept as its own copy
    so this analysis depends on `syntax.py` alone, the same way each
    backend does."""
    match pattern:
        case PCapture(info, name):
            return [(name, info)]
        case PTuple(_, elements):
            return [b for e in elements for b in pattern_bindings(e)]
        case PList(_, prefix, rest, suffix):
            bindings = [b for e in prefix for b in pattern_bindings(e)]
            if rest is not None and rest.name is not None:
                bindings.append((rest.name, rest.info))
            bindings += [b for e in (suffix or []) for b in pattern_bindings(e)]
            return bindings
        case _:
            return []


def bind_pattern(env, pattern):
    """`env` extended with everything `pattern` binds."""
    for name, info in pattern_bindings(pattern):
        env = bind(env, name, PATTERN_VAR, info)
    return env


def bind_target(env, target, kind=BINDING):
    """`env` extended with every name in an assignment target, which may
    destructure a tuple (`a, b = ...`)."""
    match target:
        case TargetName(info, name):
            return bind(env, name, kind, info)
        case TargetTuple(_, elements):
            for element in elements:
                env = bind_target(env, element, kind)
            return env


# --- the walk ---
#
# `analyze_expr` only reads the environment; the `analyze_*` statement
# functions return the environment their statement leaves behind, which
# is how a sequence of statements accumulates bindings. A *nested* scope
# is entered simply by not using what it returns -- see `analyze_scope`.

def analyze_expr(e, env):
    match e:
        case EInt(_, _) | EString(_, _):
            pass
        case EVar(info, name):
            check_bound(name, env, info)
        case (EAdd(_, l, r) | ESub(_, l, r) | EMul(_, l, r) | EDiv(_, l, r)
              | ELessThan(_, l, r) | ELessThanEq(_, l, r) | EGreatThan(_, l, r)
              | EGreatThanEq(_, l, r) | EEq(_, l, r)):
            analyze_expr(l, env)
            analyze_expr(r, env)
        case ENeg(_, operand):
            analyze_expr(operand, env)
        case ECall(_, func, args):
            analyze_expr(func, env)
            for arg in args:
                analyze_expr(arg, env)
        case EList(_, elements) | ETuple(_, elements):
            for element in elements:
                analyze_expr(element, env)
        case EIf(_, cond, then_expr, else_expr):
            analyze_expr(cond, env)
            analyze_expr(then_expr, env)
            analyze_expr(else_expr, env)
        case EListComp(_, expr, clauses):
            # A comprehension is its own scope: its pattern variables are
            # visible to the element expression and to the clauses after
            # them (`[x + y for x in xs for y in f(x)]`), and nowhere else.
            comp_env = env
            for clause in clauses:
                match clause:
                    case CompFor(_, pattern, sequence):
                        analyze_expr(sequence, comp_env)
                        comp_env = bind_pattern(comp_env, pattern)
                    case CompIf(_, condition):
                        analyze_expr(condition, comp_env)
            analyze_expr(expr, comp_env)
        case _:
            raise NotImplementedError(f"no name analysis for expression {e!r}")


def analyze_scope(stmts, env):
    """Analyzes a nested block: it sees `env`, and whatever it binds is
    discarded on the way out -- that discarding is the whole of lexical
    scoping here."""
    analyze_stmts(stmts, env)


def analyze_stmts(stmts, env):
    """Analyzes a statement sequence, threading the environment through
    it, and returns the environment at the end."""
    for stmt in stmts:
        env = analyze_stmt(stmt, env)
    return env


def analyze_value_stmt(stmt, env):
    """A value-form `if`/`match` (the right-hand side of a binding, see
    `SLetStmt`): its branches are ordinary nested scopes. The bound
    target is *not* bound here -- it belongs to the enclosing scope, and
    `analyze_stmt` binds it after this returns."""
    match stmt:
        case SIf(_, cond, then_body, else_body):
            analyze_expr(cond, env)
            analyze_scope(then_body, env)
            analyze_scope(else_body, env)
        case SMatch(_, subject, cases):
            analyze_expr(subject, env)
            for case_clause in cases:
                analyze_case(case_clause, env)


def analyze_case(case_clause, env):
    """One `case` clause: the pattern's variables are bound in the arm's
    own scope, whether the arm is a block or a single `-> expr`."""
    case_env = bind_pattern(env, case_clause.pattern)
    if case_clause.expr is not None:
        analyze_expr(case_clause.expr, case_env)
    else:
        analyze_scope(case_clause.body, case_env)


def analyze_stmt(s, env):
    match s:
        case SLet(_, target, expr):
            # The right-hand side is analyzed *before* the target is
            # bound, so `x = x + 1` reads the enclosing `x` and binds a
            # new one -- a binding, never an update.
            analyze_expr(expr, env)
            return bind_target(env, target)

        case SLetStmt(_, target, stmt):
            analyze_value_stmt(stmt, env)
            return bind_target(env, target)

        case SVar(info, name, expr):
            analyze_expr(expr, env)
            return bind(env, name, MUTABLE, info)

        case SMutate(info, name, expr):
            analyze_expr(expr, env)
            match env.get(name):
                case None:
                    raise AnalysisError(info, f"unbound name '{name}'")
                case Binding(kind, _) as existing if kind != MUTABLE:
                    raise AnalysisError(
                        info,
                        f"cannot update '{name}' with ':=': it is a {kind}"
                        f"{where_bound(existing)}, not a mutable variable (declare "
                        "it with 'var' to make it one)",
                    )
                case _:
                    return env

        case SReturn(_, expr):
            analyze_expr(expr, env)
            return env

        case SExprStmt(_, expr):
            analyze_expr(expr, env)
            return env

        case SFor(info, name, iterable, body):
            analyze_expr(iterable, env)
            analyze_scope(body, bind(env, name, LOOP_VAR, info))
            return env

        case SWhile(_, cond, body):
            analyze_expr(cond, env)
            analyze_scope(body, env)
            return env

        case SIf(_, cond, then_body, else_body):
            analyze_expr(cond, env)
            analyze_scope(then_body, env)
            if else_body is not None:
                analyze_scope(else_body, env)
            return env

        case SMatch(_, subject, cases):
            analyze_expr(subject, env)
            for case_clause in cases:
                analyze_case(case_clause, env)
            return env

        case SFunctionDef(info, name, params, body, _return_type, expr):
            # The function's own name is bound before its body is walked,
            # so a function may call itself; the parameters then bind in
            # the body's scope, shadowing anything but a mutable variable.
            env = bind(env, name, FUNCTION, info)
            body_env = env
            for param in params:
                body_env = bind(body_env, param.name, PARAMETER, param.info)
            if expr is not None:
                analyze_expr(expr, body_env)
            else:
                analyze_scope(body, body_env)
            return env

        case _:
            raise NotImplementedError(f"no name analysis for statement {s!r}")


def analyze_program(stmts):
    """External entry point: checks a whole program's names, raising
    `AnalysisError` on the first problem. Returns nothing -- the analysis
    only rejects, it never rewrites the AST."""
    env = {name: Binding(BUILTIN) for name in BUILTINS}
    analyze_stmts(stmts, env)
