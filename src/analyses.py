"""Static analyses over the Pyking AST (src/syntax.py): name and scope
checking, and symbolizing (giving every node a unique integer id). Runs
after parsing and before any backend, for every mode except
--typecheck, which does its own name checking. See PYKING.md, "Names
and scoping", and docs/architecture.md, docs/source.md ("analyses.py").

Data structures:
    AnalysisError -- a name/scoping failure, with the source position.
    Binding -- what the environment records for one name in scope.

Functions:
    analyze_program(stmts) -- checks a whole program's names.
    analyze_stmts(stmts, env) -- analyzes a statement sequence.
    analyze_stmt(s, env) -- analyzes one statement.
    analyze_expr(e, env) -- analyzes one expression.
    analyze_scope(stmts, env) -- analyzes a nested block.
    bind(env, name, kind, info) -- extends env with one binding.
    bind_target(env, target, kind) -- binds every name in an assign target.
    bind_pattern(env, pattern) -- binds every name a pattern captures.
    check_bound(name, env, info) -- checks that name is in scope.
    pattern_bindings(pattern) -- the (name, info) pairs a pattern binds.
    bound_names(stmt) -- the (name, info) pairs a statement binds in its block.
    target_names(target) -- the (name, info) pairs an assign target binds.
    block_functions(stmts) -- the defs at the top of a block, name -> node.
    check_no_function_clash(name, info, functions) -- checks no other
        binding in the block shares a def's name.
    symbolize(stmts) -- gives every node a unique integer sym.
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
    SLoop, SBreak, SContinue,
    SFunctionDef, SMatch,
    TargetName, TargetTuple,
)


class AnalysisError(Exception):
    """A name/scoping failure, with the source position of the offending
    name."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


# --- kinds of binding ---

MUTABLE = "mutable variable"      # var name = ...
BINDING = "binding"               # name = ...
PARAMETER = "parameter"           # def f(name)
LOOP_VAR = "loop variable"        # for name in ... / loop name = ...
PATTERN_VAR = "pattern variable"  # case ...name...:
FUNCTION = "function"             # def name(...)
BUILTIN = "builtin"               # see `BUILTINS`

# Names that are not bound in a Pyking program but that the generated
# Python calls directly. Extend when a program starts using another one.
BUILTINS = ("print", "range", "str", "len")


@dataclass(frozen=True)
class Binding:
    """What the environment records for one name in scope. Fields:
    kind: String (one of the constants above), info: Info? (None for a
    builtin, which has no source position)."""
    kind: str
    info: Info = None    # None for a builtin, which has no source position


def where_bound(binding):
    """Formats where a binding was declared, for an error message; empty
    for a builtin. Binding -> String"""
    if binding.info is None:
        return ""
    return f" (declared on line {binding.info.row1})"


def bind(env, name, kind, info):
    """Extends env with name bound as kind. Raises AnalysisError if name
    is already bound as a mutable variable.
    {String: Binding} -> String -> String -> Info -> {String: Binding}"""
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
    """Raises AnalysisError if name is not bound in env.
    String -> {String: Binding} -> Info -> ()"""
    if name not in env:
        raise AnalysisError(info, f"unbound name '{name}'")


def pattern_bindings(pattern):
    """The names a pattern binds, as (name, info) pairs, in source
    order. Pattern -> [(String, Info)]"""
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
    """Extends env with everything pattern binds.
    {String: Binding} -> Pattern -> {String: Binding}"""
    for name, info in pattern_bindings(pattern):
        env = bind(env, name, PATTERN_VAR, info)
    return env


def bind_target(env, target, kind=BINDING):
    """Extends env with every name in an assignment target (which may
    destructure a tuple, `a, b = ...`).
    {String: Binding} -> AssignTarget -> String -> {String: Binding}"""
    match target:
        case TargetName(info, name):
            return bind(env, name, kind, info)
        case TargetTuple(_, elements):
            for element in elements:
                env = bind_target(env, element, kind)
            return env


# --- the walk ---

def analyze_expr(e, env):
    """Checks that every name e uses is bound in env. Raises
    AnalysisError on the first unbound name.
    Expr -> {String: Binding} -> ()"""
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
    """Analyzes a nested block in env; whatever it binds is not visible
    outside it. [Stmt] -> {String: Binding} -> ()"""
    analyze_stmts(stmts, env)


def bound_names(stmt):
    """The names a statement binds in the block it is written in
    (excludes for/pattern/parameter names, and a def's own name), as
    (name, info) pairs. Stmt -> [(String, Info)]"""
    match stmt:
        case SLet(_, target, _) | SLetStmt(_, target, _):
            return target_names(target)
        case SVar(info, name, _):
            return [(name, info)]
        case _:
            return []


def target_names(target):
    """The (name, info) pairs an assignment target binds.
    AssignTarget -> [(String, Info)]"""
    match target:
        case TargetName(info, name):
            return [(name, info)]
        case TargetTuple(_, elements):
            return [pair for e in elements for pair in target_names(e)]
    return []


def block_functions(stmts):
    """The def statements at the top of a block, name -> node. Raises
    AnalysisError if two defs in the block share a name, or if any other
    binding in the block shares a def's name.
    [Stmt] -> {String: SFunctionDef}"""
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
    """Raises AnalysisError if name is one of functions' keys.
    String -> Info -> {String: SFunctionDef} -> ()"""
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
    """Analyzes a statement sequence in env, threading the environment
    from one statement to the next; every def in the sequence is bound
    first. Returns the environment left after the last statement.
    [Stmt] -> {String: Binding} -> {String: Binding}"""
    for stmt in block_functions(stmts).values():
        env = bind(env, stmt.name, FUNCTION, stmt.info)
    for stmt in stmts:
        env = analyze_stmt(stmt, env)
    return env


def analyze_value_stmt(stmt, env):
    """Analyzes a value-form if/match/loop (the right-hand side of a
    binding); does not bind the target itself.
    Stmt -> {String: Binding} -> ()"""
    match stmt:
        case SLoop():
            # A loop in value position is analyzed exactly as one written
            # on its own: it binds its accumulator in its own body and
            # nothing in the block around it.
            analyze_stmt(stmt, env)
        case SIf(_, cond, then_body, else_body):
            analyze_expr(cond, env)
            analyze_scope(then_body, env)
            analyze_scope(else_body, env)
        case SMatch(_, subject, cases):
            analyze_expr(subject, env)
            for case_clause in cases:
                analyze_case(case_clause, env)


def analyze_case(case_clause, env):
    """Analyzes one case clause; the pattern's variables are bound in
    the arm's own scope. MatchCase -> {String: Binding} -> ()"""
    case_env = bind_pattern(env, case_clause.pattern)
    if case_clause.expr is not None:
        analyze_expr(case_clause.expr, case_env)
    else:
        analyze_scope(case_clause.body, case_env)


def analyze_stmt(s, env):
    """Analyzes one statement in env. Returns the environment the
    statements after it should see. Stmt -> {String: Binding} -> {String: Binding}"""
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

        case SLoop(_, target, init, _, body):
            # The initializer is analyzed outside the loop, exactly as an
            # `=` binding's right-hand side is: `loop x = x + 1:` reads
            # the enclosing `x` and binds a new one for the body.
            if target is None:
                analyze_scope(body, env)
            else:
                analyze_expr(init, env)
                analyze_scope(body, bind_target(env, target, LOOP_VAR))
            return env

        case SBreak(_, expr) | SContinue(_, expr):
            # Where these may stand is the parser's rule (it is shape,
            # not scope); here there is only the operand to check.
            if expr is not None:
                analyze_expr(expr, env)
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
    """Checks a whole program's names, with the builtins in scope.
    Raises AnalysisError on the first problem; never rewrites the AST.
    [Stmt] -> ()"""
    env = {name: Binding(BUILTIN) for name in BUILTINS}
    analyze_stmts(stmts, env)


# --- symbolize ---


def _highest_sym(node):
    """The largest sym anywhere in node, or 0 if none is symbolized.
    a -> Int"""
    if is_dataclass(node) and hasattr(node, "sym"):
        return max(
            [node.sym]
            + [_highest_sym(getattr(node, f.name)) for f in fields(node)]
        )
    if isinstance(node, (list, tuple)):
        return max([0] + [_highest_sym(element) for element in node])
    return 0


def symbolize(stmts):
    """Rebuilds stmts so every node has a unique sym, numbered
    post-order starting at 1 (0 means "not symbolized"). A node that
    already has a symbol keeps it; safe to run more than once.
    [Stmt] -> [Stmt]"""
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
