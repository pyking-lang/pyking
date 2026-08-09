"""Static analyses over the Pyking AST (`src/syntax.py`).

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

import itertools
from dataclasses import dataclass, fields, is_dataclass, replace

from lexer import Info
from syntax import (
    EInt, EString, EBool, EVar,
    EAdd, ESub, EMul, EDiv, ENeg,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EList, ETuple,
    EIf, EListComp, CompFor, CompIf,
    PInt, PString, PWildcard, PCapture, PTuple, PList,
    SLet, SLetStmt, SVar, SMutate, SReturn, SReturnStmt, SExprStmt, SFor, SWhile, SIf,
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
        case EInt(_, _) | EString(_, _) | EBool(_, _):
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


def bound_names(stmt):
    """The names a statement binds *in the block it is written in*, as
    `(name, info)` pairs.

    Only the binding forms whose names land in that block: a `for`
    variable, a pattern variable and a parameter all bind in a nested
    scope of their own, and a `def`'s own name is handled by
    `block_functions` itself."""
    match stmt:
        case SLet(_, target, _) | SLetStmt(_, target, _):
            return target_names(target)
        case SVar(info, name, _):
            return [(name, info)]
        case _:
            return []


def target_names(target):
    """The `(name, info)` pairs an assignment target binds."""
    match target:
        case TargetName(info, name):
            return [(name, info)]
        case TargetTuple(_, elements):
            return [pair for e in elements for pair in target_names(e)]
    return []


def block_functions(stmts):
    """
    This function returns a dictionary, mapping names to statments,
    for those statements that are function definintions (defs) inside
    a block. It also checks the rules that functin names need to be
    unique in the block, and that no other name binding in the block
    is allowed to have the same name as a function. If not, it raises
    analysis errors.

    A function name must mean exactly one thing in the block it is
    written in. That is what lets the *names* be visible throughout the
    block -- which is what recursion and mutual recursion need -- while
    every other binding stays positional: since the name cannot be
    rebound there, "the function visible at this line" and "the function
    visible anywhere in this block" are the same function, and a body
    that names it cannot mean two things (see PYKING.md, "Names and
    scoping")."""
    functions = {}
    for stmt in stmts:
        if not isinstance(stmt, SFunctionDef):
            continue
        earlier = functions.get(stmt.name)
        if earlier is not None:
            raise AnalysisError(
                stmt.info,
                f"'{stmt.name}' is already defined as a function in this "
                f"block{where_bound(Binding(FUNCTION, earlier.info))}; a "
                "function name may be defined once per block (a nested block "
                "may shadow it)",
            )
        functions[stmt.name] = stmt
    for stmt in stmts:
        for name, info in bound_names(stmt):
            check_no_function_clash(name, info, functions)
    return functions


def check_no_function_clash(name, info, functions):
    """Refuses a binding that would share its block with a `def` of the
    same name -- in either order, and whatever the binding form.

    This is the other half of what makes a function name unambiguous:
    with the name visible throughout the block, a second binding of it
    would leave a reader unable to say which one a use refers to, and no
    reading of it is more obviously right than another. So neither is
    chosen; the program is refused (see PYKING.md, "Names and
    scoping")."""
    clash = functions.get(name)
    if clash is not None:
        raise AnalysisError(
            info,
            f"cannot bind '{name}': a function '{name}' is defined in this "
            f"block{where_bound(Binding(FUNCTION, clash.info))}, and a "
            "function's name may not also be bound there (a nested block may "
            "shadow it)",
        )


def analyze_stmts(stmts, env):
    """Analyzes a statement sequence, threading the environment through
    it, and returns the environment at the end.

    Every `def` in the sequence is bound *first*, before any statement is
    walked. That is what makes a function usable before it is written --
    recursion, mutual recursion, a helper defined at the bottom of the
    file -- and it is the one departure from binding in source order (see
    PYKING.md, "Names and scoping"). It is not recursive: a `def` inside
    a branch belongs to that branch's block, and is declared when
    `analyze_scope` reaches it.

    Only the *names* are hoisted, and only functions'. What a body sees
    is still whatever is bound where the body is written, and an `=`
    binding is still sequential -- its value is an expression that may
    read anything above it, while a `def` needs nothing around it to say
    what its name means.

    `block_functions` and `check_no_function_clash` keep those names
    unambiguous: one `def` per name per block, and no other binding of
    that name in the same block."""
    for stmt in block_functions(stmts).values():
        env = bind(env, stmt.name, FUNCTION, stmt.info)
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

        case SReturnStmt(_, stmt):
            # `return if c:` / `return match e:` -- the branches are
            # ordinary nested scopes, exactly as in `SLetStmt`, and
            # nothing is bound in the enclosing one.
            analyze_value_stmt(stmt, env)
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


# --- symbolize ---
#
# A second pass over the checked AST, giving every node a unique integer
# `sym` (see `syntax.py`). Nothing in the compiler consumes these yet --
# `--symbols` prints them, and a later stage that needs to attach
# information to a node (a type, a storage location, a use-def edge) has
# a stable key to hang it on that does not depend on the node's identity
# or position.
#
# The walk is generic over dataclass fields rather than one case per node
# type, the same way `_collect_identifiers` in `target_python.py` is: a
# new node in `syntax.py` gets a symbol without anyone remembering to
# update this file. Nodes are frozen, so the tree is rebuilt with
# `replace` rather than mutated, and the pass returns the new one.


def _highest_sym(node):
    """The largest `sym` anywhere in `node`, or 0 if nothing is
    symbolized yet."""
    if is_dataclass(node) and hasattr(node, "sym"):
        return max(
            [node.sym]
            + [_highest_sym(getattr(node, f.name)) for f in fields(node)]
        )
    if isinstance(node, (list, tuple)):
        return max([0] + [_highest_sym(element) for element in node])
    return 0


def symbolize(stmts):
    """Every node in `stmts`, rebuilt so that all of them have a unique
    `sym`. Numbering is post-order and starts at 1, so 0 -- every node's
    default -- means "not symbolized yet" and can never collide with a
    real symbol.

    A node that *already* has a symbol keeps it, and fresh numbers
    continue past the highest one in the tree. That makes the pass safe
    to run a second time, which is what gives nodes synthesized after
    the first run -- the types the checker writes into bindings, say --
    symbols of their own without renumbering everything around them."""
    counter = itertools.count(_highest_sym(stmts) + 1)

    def walk(node):
        if is_dataclass(node) and hasattr(node, "sym"):
            updated = {
                f.name: walk(getattr(node, f.name))
                for f in fields(node)
                if f.name != "sym"
            }
            return replace(node, **updated, sym=node.sym or next(counter))
        if isinstance(node, list):
            return [walk(element) for element in node]
        if isinstance(node, tuple):
            return tuple(walk(element) for element in node)
        return node

    return [walk(s) for s in stmts]
