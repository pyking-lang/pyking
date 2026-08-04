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
can carry a type annotation -- `SFunctionDef` (its return type), `Param`,
`SLet` and `SLetStmt` -- that the checker actually reached. Of those only
`SLet` is within the fragment covered so far; the rest are named here
because they are what a later version has to record, and because
`pprint_program` already reads all four.

Types are the `T*` nodes from `syntax.py`, not a separate vocabulary, so
`pprint_type` already renders them and a checked binding prints as
`x: Int = 1` -- syntax the parser accepts, which is what keeps
`pyk --typecheck --ast` output re-parsable. They are synthesized here
rather than taken from the AST, so they carry no symbols of their own.

## What this first version covers

A program is a top-level list of immutable bindings (`=`) and expression
statements. Expressions are integer and string literals, names bound
earlier, and:

    +   Int + Int -> Int,  String + String -> String   (overloaded)
    -   Int - Int -> Int
    *   Int * Int -> Int

Every other construct -- `var`, `if`, `def`, calls, lists, tuples,
booleans, comparisons, `/` -- is refused with `Construct is not
supported` against its own source position. That is a *deliberate* floor
rather than a gap to paper over: a checker that quietly accepted what it
had not reasoned about would be worse than one that says where it stops.

`--typecheck` runs *instead of* the name analysis, not after it (see
`src/pykboot.py`), so this pass is on its own about names: a name it
cannot find in `env` is refused here, whether it is genuinely unbound or
merely bound by a construct the checker does not cover.

## Statements have type unit

`type_check` returns a type for whatever it is given, and a statement is
not an expression: a binding and an expression statement both have type
unit, `()`, as does a whole program. A binding's *right-hand side* type
is not thrown away -- it is what goes into `tmap` under the binding's own
symbol, which is what `--ast` then shows.
"""

from lexer import Info
from syntax import (
    pprint_type,
    EInt, EString, EVar, EAdd, ESub, EMul,
    SLet, SExprStmt,
    TInt, TString, TTuple,
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
# `node class -> (spelling, [(operand type, result type), ...])`. `+` is
# overloaded, which is why the table maps to a *list* of signatures
# rather than one: `12 + 20` is `Int`, `'hi' + 'there'` is `String`, and
# `13 + 'hello'` matches neither and is an error.
_OPERATORS = {
    EAdd: ("+", [(TInt, TInt), (TString, TString)]),
    ESub: ("-", [(TInt, TInt)]),
    EMul: ("*", [(TInt, TInt)]),
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


def type_check(node, env, tmap):
    """Type-checks one AST node (or a whole program, as a list of
    statements) in `env`, returning its type and recording into `tmap`
    the type of every annotatable construct it passes.

    The node itself is left alone: nothing here rebuilds the AST or
    writes into it. `env` is not mutated either -- a binding hands the
    *rest of the program* an extended copy, which is why `type_check` on
    a list threads one along rather than sharing a single table.
    `tmap` is the one thing that is mutated, and it is the pass's
    result: it belongs to the whole run, not to a scope, since a symbol
    is unique across the program."""
    match node:
        # --- a program: a list of statements ---
        case list():
            for statement in node:
                type_check(statement, env, tmap)
                env = _extend(env, statement, tmap)
            return unit(_program_info(node))

        # --- statements ---
        case SLet(info, TargetName(), expr, _, sym):
            expr_type = type_check(expr, env, tmap)
            # The binding's symbol records what its right-hand side
            # turned out to be; the binding *itself* is a statement, so
            # it has unit type. An annotation written in the source is
            # not consulted -- nothing verifies annotations yet (see
            # PYKING.md), so the inferred type is the truthful one, and
            # it is the one `--ast` prints.
            tmap[sym] = expr_type
            return unit(info)

        case SLet():
            # A destructuring target (`a, b = ...`) needs tuple types.
            _unsupported(node)

        case SExprStmt(info, expr, _):
            type_check(expr, env, tmap)
            return unit(info)

        # --- expressions ---
        case EInt(info, _, _):
            return TInt(info)

        case EString(info, _, _):
            return TString(info)

        case EVar(_, name, _):
            if name not in env:
                # No name analysis has run ahead of this pass under
                # `--typecheck`, so a name missing here is either
                # genuinely unbound or bound by a construct this checker
                # does not cover yet (a `for` variable, a parameter, a
                # `var`). Either way it is refused, with a position.
                _unsupported(node)
            return env[name]

        case EAdd() | ESub() | EMul():
            return _check_binary(node, env, tmap)

        case _:
            _unsupported(node)


def _extend(env, statement, tmap):
    """`env` with whatever `statement` binds added -- a fresh dict, never
    a mutation of the one passed in. The type comes from `tmap`, where
    checking the statement just put it."""
    match statement:
        case SLet(_, TargetName(_, name, _), _, _, sym):
            return {**env, name: tmap[sym]}
        case _:
            return env


def _program_info(stmts):
    """An `Info` to blame for a whole program: its first statement's, or
    a synthetic one for the empty program, which has no source to point
    at but still has a type."""
    if stmts:
        return stmts[0].info
    return Info("<empty>", 1, 0, 1, 0)
