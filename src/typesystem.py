"""The type checker: a pass that gives every expression a type and
records the type of every binding in a symbol table.

Pyking has no type checker in the ordinary pipeline -- type annotations
are parsed, stored and erased (see PYKING.md, "Type annotations"), and
every backend infers whatever it needs for itself. This module is the
beginning of a real one, run only when `--typecheck` asks for it, after
`symbolize` and before anything is printed or compiled.

The single entry point is:

    type_check(node, env, tmap) -> type

`env` maps a name to its type. It is an ordinary dict used immutably: a
binding produces an *extended copy* rather than mutating the one it was
handed, the same discipline `analyses.py` follows and for the same
reason -- what a name means is decided by where it is written, and a
pass that mutates one shared table cannot say that.

`tmap` is the opposite kind of table, and deliberately so: one mutable
dict, shared by the whole run, mapping a node's *symbol* (see
`symbolize` in `analyses.py`) to the type the checker worked out for it.
It is the pass's only output apart from the returned type. The AST is
left exactly as it was parsed -- this checker rebuilds nothing and
writes into no node's `type` field -- so what a program *says* and what
the checker *inferred* stay separable, and a caller that wants the
latter asks `tmap` for it. `src/pykboot.py` hands the finished `tmap` to
`syntax.pprint_program`, which is what makes `pyk --typecheck --ast`
print inferred types rather than written ones.

Once checking is done, `tmap` holds an entry for every construct that
can carry a type annotation -- `SFunctionDef`, `Param`, `SLet` and
`SLetStmt` -- that the checker actually reached. A `SFunctionDef`'s entry
is its *function* type, not its return type: the type of a thing is the
type of the thing, and the syntax's `-> T` slot holds only part of it,
which is why `pprint_program` prints `TFunction.result` there.

Types are the `T*` nodes from `syntax.py`, not a separate vocabulary, so
`pprint_type` already renders them and a checked binding prints as
`x: Int = 1` -- syntax the parser accepts, which is what keeps
`pyk --typecheck --ast` output re-parsable. They are synthesized here
rather than taken from the AST, so they carry no symbols of their own.
The one exception is `TFunction`, which has no source syntax at all: a
name bound to a function prints as `g: (Int) -> Int = f`, which says
what is true but is not something the parser could read back.

Types are compared with `_same_type`, never with `==`: two `TInt` nodes
built at different places are different *nodes* (a dataclass compares its
`info` and `sym` too) and the same *type*.

## What this version covers

A program is a list of immutable bindings (`=`), expression statements,
`if` statements and fully annotated function definitions. Expressions
are integer, string and boolean literals, names bound earlier, calls of
a function-typed name, and:

    +          Int + Int -> Int,  String + String -> String  (overloaded)
    - *        Int -> Int
    < <= > >=  Int, Int -> Bool
    ==         Int, String or Bool, both sides alike -> Bool

Every other construct -- `var`, `for`, `while`, `match`, lists, tuples,
comprehensions, `/` -- is refused with `Construct is not supported`
against its own source position. That is a *deliberate* floor rather
than a gap to paper over: a checker that quietly accepted what it had
not reasoned about would be worse than one that says where it stops.

### Functions

A `def` is checked only when it is *fully* annotated -- every parameter
and the return type -- since this checker infers nothing about a
function it was not told. Its type is then `(P1, P2, ...) -> R`, a
`TFunction`, and that is what its name means to the statements that
follow it.

Two deliberate limits. The function's own name is *not* in scope in its
body, so recursion is refused rather than assumed to check: taking a
declared type on faith to check the body that justifies it is a
different (if small) piece of reasoning, and it is not written yet. And
a body must return on every path (`_definitely_returns`), because a
function that says `-> Int` and falls off the end has a type it does not
honour.

`--typecheck` runs *instead of* the name analysis, not after it (see
`src/pykboot.py`), so this pass is on its own about names: a name it
cannot find in `env` is refused here, whether it is genuinely unbound or
merely bound by a construct the checker does not cover.

## What a statement's type is

`type_check` returns a type for whatever it is given, and most statements
have type unit, `()` -- as does a whole program. Two do not, and they are
what makes `if` checkable: an *expression statement* has its
expression's type, and a *block* has the type of its last statement. So
a branch that ends in an expression yields that expression's value, and

    if c:
        1
    else:
        'x'

is an error -- `Int` against `String` -- while two branches that end in
ordinary statements are both unit and agree. An `if` with no `else` is
checked against unit, since that is what "the branch that did not run"
produces.
"""

from dataclasses import dataclass

from lexer import Info
from syntax import (
    pprint_type,
    EInt, EString, EBool, EVar, EAdd, ESub, EMul, ECall,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq,
    Stmt, SLet, SLetStmt, SExprStmt, SIf, SReturn, SReturnStmt, SFunctionDef,
    TInt, TString, TBool, TList, TTuple, TFunction,
    TargetName,
)


class TypeError_(Exception):
    """Raised for a type error, or for a construct this checker does not
    cover. Carries the source position, like `LexError`/`ParseError`/
    `AnalysisError` do for their own stages, so `pykboot.py` can report
    it in the same `'file' row:col-row:col ...` form.

    Named with a trailing underscore so it cannot be confused with -- or
    accidentally shadow -- Python's own built-in `TypeError`, which this
    is not and which the driver must still be able to see."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


UNSUPPORTED = "Construct is not supported"


def _unsupported(node):
    raise TypeError_(node.info, UNSUPPORTED)


def unit(info):
    """The unit type, `()` -- an empty tuple type. What every statement
    and every program has."""
    return TTuple(info, [])


# The binary operators this checker knows, as
# `node class -> (spelling, [(operand type, result type), ...])`. Several
# are overloaded, which is why the table maps to a *list* of signatures
# rather than one: `12 + 20` is `Int`, `'hi' + 'there'` is `String`, and
# `13 + 'hello'` matches neither and is an error. Both operands must
# match the *same* signature, which is what makes `1 == 'x'` an error
# rather than a comparison that is merely always false.
_OPERATORS = {
    EAdd: ("+", [(TInt, TInt), (TString, TString)]),
    ESub: ("-", [(TInt, TInt)]),
    EMul: ("*", [(TInt, TInt)]),
    ELessThan: ("<", [(TInt, TBool)]),
    ELessThanEq: ("<=", [(TInt, TBool)]),
    EGreatThan: (">", [(TInt, TBool)]),
    EGreatThanEq: (">=", [(TInt, TBool)]),
    EEq: ("==", [(TInt, TBool), (TString, TBool), (TBool, TBool)]),
}


def _check_binary(e, env, tmap):
    spelling, signatures = _OPERATORS[type(e)]
    left_type = type_check(e.left, env, tmap)
    right_type = type_check(e.right, env, tmap)
    for operand, result in signatures:
        if isinstance(left_type, operand) and isinstance(right_type, operand):
            return result(e.info)
    # Every type in the message is spelled by `pprint_type`, the same
    # function that prints a type in source and in `--ast` output, so an
    # error can never name a type differently from the way the program
    # would have to write it. A signature's operand is a *class* here, so
    # it is instantiated to be printed -- only ever on this error path.
    accepted = " or ".join(
        f"{name} {spelling} {name}"
        for name in (pprint_type(operand(e.info)) for operand, _ in signatures)
    )
    raise TypeError_(
        e.info,
        f"`{spelling}` cannot be applied to {pprint_type(left_type)} and "
        f"{pprint_type(right_type)}; it accepts {accepted}",
    )


@dataclass(frozen=True)
class _SelfReference:
    """What a function's own name is bound to inside its own body.

    Not a type -- deliberately. Leaving the name out of the body's
    environment altogether would refuse recursion with `Construct is not
    supported` pointing at a perfectly ordinary use of a name, which
    describes neither what happened nor what to do about it. Binding it
    to *this* instead lets the one place that reads a name back out of
    the environment say what is really going on. Nothing else can
    encounter it: it is bound in exactly one place and read in exactly
    one."""

    name: str


def _same_type(a, b):
    """Whether two types *are* the same type.

    Not `a == b`: types are frozen dataclasses, so `==` compares their
    `info` and `sym` too, and `Int` written in one place would differ
    from `Int` inferred in another. What matters is the structure, so
    that is what is compared -- recursively, since a type can contain
    types."""
    match (a, b):
        case (TInt(), TInt()) | (TString(), TString()) | (TBool(), TBool()):
            return True
        case (TList(_, x), TList(_, y)):
            return _same_type(x, y)
        case (TTuple(_, xs), TTuple(_, ys)):
            return len(xs) == len(ys) and all(map(_same_type, xs, ys))
        case (TFunction(_, ps, r), TFunction(_, qs, s)):
            return (len(ps) == len(qs) and all(map(_same_type, ps, qs))
                    and _same_type(r, s))
        case _:
            return False


def _is_unit(t):
    return isinstance(t, TTuple) and not t.elements


def _check_block(stmts, env, tmap, ret):
    """Type-checks a sequence of statements, returning the type the
    sequence *yields*: its last statement's, or unit when it is empty.

    `env` is threaded from one statement to the next, so a binding is
    visible to what follows it -- and the extended environment is
    returned to nobody, which is exactly what makes a block a scope: what
    it binds cannot escape it (`analyses.py` says the same thing with
    `analyze_scope`).

    `ret` is the return type of the enclosing function, or `None` at the
    top level, where a `return` has nothing to return from."""
    yielded = unit(stmts[0].info if stmts else Info("<empty>", 1, 0, 1, 0))
    for statement in stmts:
        yielded, env = _check_stmt(statement, env, tmap, ret)
    return yielded


def _check_stmt(statement, env, tmap, ret):
    """One statement: its type, and the environment the statements after
    it are checked in."""
    match statement:
        case SLet(info, TargetName(_, name, _), expr, _, sym):
            expr_type = type_check(expr, env, tmap)
            # The binding's symbol records what its right-hand side
            # turned out to be; the binding *itself* is a statement, so
            # it has unit type. An annotation written in the source is
            # not consulted -- nothing verifies annotations yet (see
            # PYKING.md), so the inferred type is the truthful one, and
            # it is the one `--ast` prints.
            tmap[sym] = expr_type
            return unit(info), {**env, name: expr_type}

        case SLetStmt(info, TargetName(_, name, _), stmt, _, sym):
            # `x = if c: ...` binds what the branch that runs yields, so
            # the bound statement's own type is the binding's type -- and
            # the branches having agreed on one is what `SIf` below has
            # already established.
            bound_type, _ = _check_stmt(stmt, env, tmap, ret)
            tmap[sym] = bound_type
            return unit(info), {**env, name: bound_type}

        case SLet() | SLetStmt():
            # A destructuring target (`a, b = ...`) needs tuple types.
            _unsupported(statement)

        case SExprStmt(_, expr, _):
            # An expression statement has its expression's type. That is
            # what lets a block yield a value, and so what makes the two
            # branches of an `if` comparable.
            return type_check(expr, env, tmap), env

        case SIf(info, cond, then_body, else_body, _):
            cond_type = type_check(cond, env, tmap)
            if not isinstance(cond_type, TBool):
                raise TypeError_(
                    cond.info,
                    f"the condition of an 'if' must be Bool, not "
                    f"{pprint_type(cond_type)}",
                )
            then_type = _check_block(then_body, env, tmap, ret)
            if else_body is None:
                # There is no second branch to compare against, but there
                # is still a second *outcome*: the condition being false
                # produces nothing, so the branch that exists may not
                # produce anything either.
                if not _is_unit(then_type):
                    raise TypeError_(
                        info,
                        f"an 'if' with no 'else' cannot yield a value, but "
                        f"this one yields {pprint_type(then_type)}",
                    )
                return unit(info), env
            else_type = _check_block(else_body, env, tmap, ret)
            if not _same_type(then_type, else_type):
                raise TypeError_(
                    info,
                    f"the branches of this 'if' have different types: "
                    f"{pprint_type(then_type)} and {pprint_type(else_type)}",
                )
            return then_type, env

        case SReturn(info, expr, _):
            if ret is None:
                raise TypeError_(info, "'return' outside a function")
            actual = type_check(expr, env, tmap)
            if not _same_type(actual, ret):
                raise TypeError_(
                    expr.info,
                    f"this function returns {pprint_type(ret)}, but this "
                    f"'return' gives {pprint_type(actual)}",
                )
            return unit(info), env

        case SReturnStmt(info, stmt, _):
            # `return if c: ...` -- the same rule, against whatever the
            # branch that runs yields.
            if ret is None:
                raise TypeError_(info, "'return' outside a function")
            actual, _ = _check_stmt(stmt, env, tmap, ret)
            if not _same_type(actual, ret):
                raise TypeError_(
                    info,
                    f"this function returns {pprint_type(ret)}, but this "
                    f"'return' gives {pprint_type(actual)}",
                )
            return unit(info), env

        case SFunctionDef():
            # Checked against its annotations here; visible under its own
            # name only to the statements that follow.
            return (_check_function(statement, env, tmap),
                    _bind_function(statement, env, tmap))

        case _:
            _unsupported(statement)


def _function_type(node):
    """The `TFunction` a fully annotated `def` describes, or a refusal
    naming what is missing. Nothing here infers: a function this checker
    was not told about is one it declines to check, rather than one it
    guesses at."""
    unannotated = [p.name for p in node.params if p.type is None]
    if unannotated or node.return_type is None:
        missing = ", ".join(
            [f"parameter '{n}'" for n in unannotated]
            + ([] if node.return_type is not None else ["the return type"])
        )
        raise TypeError_(
            node.info,
            f"'{node.name}' can only be checked when every parameter and "
            f"the return type is annotated; {missing} is not",
        )
    return TFunction(node.info, [p.type for p in node.params], node.return_type)


def _bind_function(node, env, tmap):
    """`env` with the function's name bound to its type -- for the
    statements *after* the `def`, never for its own body."""
    return {**env, node.name: _function_type(node)}


def _check_function(node, env, tmap):
    """Checks a `def` against its annotations, and returns unit: the
    definition is a statement, whatever the function's own type is."""
    ftype = _function_type(node)
    for param in node.params:
        tmap[param.sym] = param.type
    tmap[node.sym] = ftype

    # The parameters, and the function's own name bound to a marker
    # rather than to its type: that is what refuses recursion (see
    # `_SelfReference` and the module docstring) instead of quietly
    # letting an outer binding of the same name stand in for it.
    body_env = {**env, node.name: _SelfReference(node.name),
                **{p.name: p.type for p in node.params}}

    if node.expr is not None:
        # `def f(x:Int) -> Int = expr`: the expression *is* the result.
        actual = type_check(node.expr, body_env, tmap)
        if not _same_type(actual, node.return_type):
            raise TypeError_(
                node.expr.info,
                f"'{node.name}' returns {pprint_type(node.return_type)}, but "
                f"its body has type {pprint_type(actual)}",
            )
        return unit(node.info)

    _check_block(node.body, body_env, tmap, node.return_type)
    if not _definitely_returns(node.body):
        raise TypeError_(
            node.info,
            f"'{node.name}' returns {pprint_type(node.return_type)}, so its "
            f"body must return on every path",
        )
    return unit(node.info)


def _definitely_returns(stmts):
    """Whether a block always leaves by a `return`.

    Only the last statement can decide it -- anything before it may fall
    through -- and only two kinds do: a `return`, and an `if` whose every
    branch does (which needs the `else` to exist, or the condition being
    false falls out of the block). `javac` reasons the same way about
    Java, and `target_java.py` has the same function for the same
    reason."""
    match stmts:
        case [*_, SReturn() | SReturnStmt()]:
            return True
        case [*_, SIf(_, _, then_body, else_body)]:
            return (else_body is not None
                    and _definitely_returns(then_body)
                    and _definitely_returns(else_body))
        case _:
            return False


def _check_call(e, env, tmap):
    func_type = type_check(e.func, env, tmap)
    if not isinstance(func_type, TFunction):
        raise TypeError_(
            e.info,
            f"this call applies something of type {pprint_type(func_type)}, "
            f"which is not a function",
        )
    if len(e.args) != len(func_type.params):
        expected, given = len(func_type.params), len(e.args)
        raise TypeError_(
            e.info,
            f"this function takes {expected} argument{'' if expected == 1 else 's'}, "
            f"but {given} {'was' if given == 1 else 'were'} given",
        )
    for position, (arg, expected) in enumerate(zip(e.args, func_type.params), 1):
        actual = type_check(arg, env, tmap)
        if not _same_type(actual, expected):
            raise TypeError_(
                arg.info,
                f"argument {position} has type {pprint_type(actual)}, but "
                f"{pprint_type(expected)} was expected",
            )
    return func_type.result


def type_check(node, env, tmap):
    """Type-checks one AST node (or a whole program, as a list of
    statements) in `env`, returning its type and recording into `tmap`
    the type of every annotatable construct it passes.

    The node itself is left alone: nothing here rebuilds the AST or
    writes into it. `env` is not mutated either -- a binding hands the
    *rest of the program* an extended copy, which is why checking a block
    threads one along rather than sharing a single table. `tmap` is the
    one thing that is mutated, and it is the pass's result: it belongs to
    the whole run, not to a scope, since a symbol is unique across the
    program.

    Statements go through `_check_stmt`, which additionally says what
    environment follows them and what return type they sit under; this
    entry point is for a whole program, an expression, or a statement in
    neither of those positions."""
    match node:
        # --- a program: a list of statements ---
        case list():
            # A program is a block, but its *type* is unit whatever its
            # last statement yields: nothing is waiting for a program's
            # value the way a branch's caller waits for a branch's.
            _check_block(node, env, tmap, None)
            return unit(_program_info(node))

        # --- statements ---
        case Stmt():
            return _check_stmt(node, env, tmap, None)[0]

        # --- expressions ---
        case EInt(info, _, _):
            return TInt(info)

        case EString(info, _, _):
            return TString(info)

        case EBool(info, _, _):
            return TBool(info)

        case EVar(_, name, _):
            if name not in env:
                # No name analysis has run ahead of this pass under
                # `--typecheck`, so a name missing here is either
                # genuinely unbound or bound by a construct this checker
                # does not cover yet (a `for` variable, a `var`, a
                # function that is not fully annotated). Either way it is
                # refused, with a position.
                _unsupported(node)
            found = env[name]
            if isinstance(found, _SelfReference):
                raise TypeError_(
                    node.info,
                    f"'{name}' is used inside its own definition; recursive "
                    f"functions are not supported yet",
                )
            return found

        case EAdd() | ESub() | EMul() | ELessThan() | ELessThanEq() \
                | EGreatThan() | EGreatThanEq() | EEq():
            return _check_binary(node, env, tmap)

        case ECall():
            return _check_call(node, env, tmap)

        case _:
            _unsupported(node)


def _program_info(stmts):
    """An `Info` to blame for a whole program: its first statement's, or
    a synthetic one for the empty program, which has no source to point
    at but still has a type."""
    if stmts:
        return stmts[0].info
    return Info("<empty>", 1, 0, 1, 0)
