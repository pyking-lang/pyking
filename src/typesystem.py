"""The type checker: a pass that gives every expression a type and
records the type of every annotated construct in a symbol table.

Pyking has no type checker in the ordinary pipeline -- type annotations
are parsed, stored and erased (see PYKING.md, "Type annotations"), and
every backend infers whatever it needs for itself. This module is the
beginning of a real one, run only when `--typecheck` asks for it, after
`symbolize` and before anything is printed or compiled. What it means
for a *program* -- the rules, and what it refuses -- is PYKING.md's
"Type checking" section; this file is how those rules are applied.

The entry point is `type_check(stmts) -> tmap`: a whole program in, the
types it worked out back. Everything else is one function per AST
datatype -- `check_stmts` for a block, `check_stmt` for a statement,
`check_expr` for an expression, `check_param` for a parameter -- each
taking a node of exactly that type and returning exactly one kind of
answer. The signatures are written out in the "Signatures" block below
in the same OCaml-ish notation `syntax.py` uses for the AST itself,
because that is the shape this pass is really written in: no function
here dispatches on which *sort* of node it was handed, only on which
variant of its own datatype.

`tmap` is the pass's result: one mutable dict, mapping a node's *symbol*
(see `symbolize` in `analyses.py`) to the type worked out for it. The
AST is left exactly as it was parsed -- this checker rebuilds nothing
and writes into no node's `type` field -- so what a program *says* and
what the checker *inferred* stay separable, and a caller that wants the
latter asks `tmap` for it. `src/pykboot.py` hands the finished `tmap` to
`syntax.pprint_program`, which is what makes `pyk --typecheck --ast`
print inferred types rather than written ones.

Once checking is done, `tmap` holds an entry for every construct that
can carry a type annotation -- `SFunctionDef`, `Param`, `SLet` and
`SLetStmt` -- that the checker actually reached. A `SFunctionDef`'s entry
is its *function* type, not its return type: the type of a thing is the
type of the thing, and the syntax's `-> T` slot holds only part of it,
which is why `pprint_program` prints `TFunction.result` there.

`env` is the opposite kind of table: it maps a name to what that name
means *here*, and it is used immutably -- a binding produces an extended
copy rather than mutating the one it was handed, the same discipline
`analyses.py` follows and for the same reason. What a name means is
decided by where it is written, and a pass that mutates one shared table
cannot say that.

Types are the `T*` nodes from `syntax.py`, not a separate vocabulary, so
`pprint_type` already renders them and a checked binding prints as
`x: Int = 1` -- syntax the parser accepts, which is what keeps
`pyk --typecheck --ast` output re-parsable. The ones this pass builds
carry no symbols of their own. That includes `TFunction`, whose syntax
`(Int, Bool) -> Int` the parser reads as well as prints, so a name bound
to a function prints as `g: (Int) -> Int = f` and can be read back.

Types are compared with `same_type`, never with `==`: two `TInt` nodes
built at different places are different *nodes* (a dataclass compares
its `info` and `sym` too) and the same *type*.

## What this version covers

A program is a list of immutable bindings (`=`), expression statements,
`if` statements and fully annotated function definitions. A binding
takes its right-hand side's type, and an annotation it wrote is checked
against that rather than replaced by it (`check_annotation`).
Expressions are integer, string and boolean literals, names bound
earlier, calls of a function-typed name, and:

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

A body supplies that return type in either of the two ways PYKING.md's
"Tail position" describes, and they mix: a `return`, or a last statement
that is simply an expression of the right type, or some branches doing
one and some the other. One rule covers all of it, because every
statement is asked the same question -- *what value do you supply?* --
and `return e` answers "e's", exactly as the tail-position table says.
A body that supplies nothing, or the wrong thing, is refused: a function
that says `-> Int` and does neither has a type it does not honour.

One deliberate limit: the function's own name is in scope in its own
body but has no *type* there, so recursion is refused (with the same
`Construct is not supported` everything outside the fragment gets)
rather than assumed to check. Taking a declared type on faith to check
the body that justifies it is a different, if small, piece of reasoning,
and it is not written yet.

## Names and scoping

`--typecheck` runs *instead of* the name analysis, not after it (see
`src/pykboot.py`), so this pass is on its own about names -- and checks
them itself rather than leaving them unchecked. `env` is the scope: a
name is in it or it is not, and one that is not raises `analyses.py`'s
own `AnalysisError` with `analyses.py`'s own wording, so a program is
told the same thing about an unbound name whichever pass found it.

The scoping falls out of how `env` is threaded, and needs no separate
machinery: a block is a scope because `check_stmts` hands its extended
environment to nobody, a name is visible only after its own binding
because the thread runs forwards, and shadowing works because `bind`
replaces an entry in a *copy*. Parameters bind in the body, a `def`'s
name binds in the enclosing scope and in its own body, and the builtins
are in scope from the start.

A name may be in scope and still have no type here -- that is what a
`None` in `env` means, and a use of one is refused as unsupported rather
than as unbound. Today that is the builtins and a function's own name
inside its body.

One rule from `analyses.py` is deliberately *not* here yet: a `var` may
not be shadowed. This checker does not cover `var` at all -- a mutable
declaration is refused as unsupported -- so there is nothing for the
rule to protect, and it stays in `analyses.py` until there is. That, and
the constructs this checker refuses outright, are the whole difference
between the two passes' idea of names; when the rest arrives, the
analysis can go.

## What a statement's type is

A statement's type is the type of the value it *supplies* -- the
question PYKING.md's "Tail position" asks of a function body's last
statement, asked here of every statement, since only its position
decides whether the answer is wanted. Most statements supply nothing and
so have type unit, `()`, as does a whole program. Four supply something:

    an expression statement    its expression
    a `return`                 what it returns
    an `if`/`else`             what its branches agree on
    a block                    its last statement's

So a branch that ends in an expression supplies that expression's value,
and

    if c:
        1
    else:
        'x'

is an error -- `Int` against `String` -- while two branches that end in
ordinary statements both supply unit and agree. An `if` with no `else`
supplies unit whatever its one branch ends in, because there is a way
through it that runs no branch at all.
"""

from dataclasses import dataclass

from analyses import AnalysisError, BUILTINS, block_functions
from lexer import Info
from syntax import (
    pprint_type,
    EInt, EString, EBool, EVar, EAdd, ESub, EMul, ECall,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq,
    SLet, SLetStmt, SExprStmt, SIf, SReturn, SReturnStmt, SFunctionDef,
    Type, TInt, TString, TBool, TList, TTuple, TFunction,
    TargetName,
)


# ---------------------------------------------------------------------
# Signatures
#
# Written as they would be in a language that could state them, with
# `syntax.py`'s legend: `[T]` is a list of `T`, `T?` a value that may be
# absent, and `(A, B)` a pair. Two aliases carry the tables this pass
# threads through itself:
#
#     Env  = {String: Type?}      the names in scope, and their types
#                                 where this checker knows one
#     TMap = {Int: Type}          symbol -> inferred type; the result
#
# The `Type?` each statement function takes (`return_type`) is the
# declared return type of the function whose body is being checked,
# absent at the top level, where a `return` has nothing to return from.
# It is what a `return` is checked against, wherever in the body it is
# written -- which is why it is threaded down through nested blocks and
# not just looked at once when the body is done.
#
#     val type_check         : [Stmt] -> TMap
#     val check_stmts        : [Stmt] -> Env -> TMap -> Type? -> Type
#     val check_stmt         : Stmt -> Env -> TMap -> Type? -> (Type, Env)
#     val check_expr         : Expr -> Env -> TMap -> Type
#     val check_param        : Param -> TMap -> Type
#     val check_function     : SFunctionDef -> Env -> TMap -> Type
#     val check_call         : ECall -> Env -> TMap -> Type
#     val check_binary       : Expr -> Env -> TMap -> Type
#     val check_annotation   : Type? -> Type -> ()
#     val function_type      : SFunctionDef -> TFunction
#     val same_type          : Type -> Type -> Bool
#     val bind               : Env -> String -> Type -> Env
#     val unit               : Info -> Type
#
# Only `type_check` is meant to be called from outside; the rest are the
# structure of the pass, one function per datatype it walks.
# ---------------------------------------------------------------------


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


# ---------------------------------------------------------------------
# What a builtin is to the checker
#
# `print`, `range`, `str` and `len` are in scope in every program
# (`analyses.BUILTINS`), and not one of them has a type this checker can
# write down: `print` takes any number of arguments of any type, `str`
# and `len` accept more than one, and a `TFunction` is one fixed list of
# parameters and one result.
#
# They are not values either. `runtime_interface.py` calls `print` an
# *operation* rather than a function, the C and Java backends refuse it
# as a value, and nothing in the language passes a builtin around. So a
# builtin is checked where it is used -- at the call, by
# `check_builtin_call` -- and refused anywhere else. That keeps
# `TFunction` honest about what it can say, and it matches what the
# backends already do.
#
# `env` therefore maps a name to one of three things:
#
#     Type       an ordinary name, of that type
#     Builtin    one of the four operations; callable, never a value
#     None       in scope with no type here (a `def` missing annotations)


@dataclass(frozen=True)
class Builtin:
    """A name that denotes a host operation rather than a value."""
    name: str


UNSUPPORTED = "Construct is not supported"


def unsupported(node):
    """Refuses `node`, against its own source position. The floor of the
    fragment this checker covers -- see the module docstring."""
    raise TypeError_(node.info, UNSUPPORTED)


# --- the program -----------------------------------------------------


def type_check(stmts):
    """Type-checks a whole program: a list of top-level statements.

    Returns the `tmap` it built -- symbol -> type for every annotatable
    construct it reached. Raises `TypeError_` for the first thing that
    does not check out; there is no error recovery, and a program that
    returns is a program that type-checks.

    A program is a block, checked with no enclosing function, and its own
    type is discarded: nothing is waiting for a program's value the way a
    branch's caller waits for a branch's. Its environment starts with the
    builtins in scope -- `analyses.BUILTINS`, the same list, so the two
    passes cannot disagree about what a program may name -- each bound to
    a `Builtin`, which is checked at the call rather than given a type."""
    tmap = {}
    env = {name: Builtin(name) for name in BUILTINS}
    check_stmts(stmts, env, tmap, None)
    return tmap


# --- [Stmt] ----------------------------------------------------------


def declare_functions(stmts, env):
    """`env` with every `def` in this block already in scope, before any
    of its statements are checked.

    That one step is the whole of recursion, mutual recursion and
    forward references: a body is checked in an environment that already
    holds its own name, its siblings' names, and every function of every
    enclosing block. It is deliberately *not* recursive -- a `def` inside
    a branch belongs to that branch's block, and is declared when that
    block is checked.

    Only functions are declared ahead. An `=` binding stays strictly
    sequential (see PYKING.md, "Names and scoping"), because its value is
    an arbitrary expression that may read anything bound before it, while
    a `def`'s type is written on the `def` itself and needs nothing that
    surrounds it.

    A `def` that is not fully annotated is declared with no type rather
    than refused here: this pass is about *scope*, and refusing it here
    would report a `def` on the last line before a type error on the
    first. It is refused when its own statement is reached.

    `block_functions` is `analyses.py`'s, and applies the two rules that
    make a hoisted name unambiguous -- one `def` per name per block, and
    no other binding of that name in the same block. Sharing it is what
    keeps the two passes from drifting apart about which programs are
    legal, and it raises `AnalysisError`, so the same wording comes out
    whichever pass ran."""
    for function in block_functions(stmts).values():
        env = bind(env, function.name, declared_type(function))
    return env


def declared_type(node):
    """The function type a `def` declares, or `None` when it does not
    declare one -- an unannotated parameter or a missing return type. The
    refusal itself belongs to `check_function`, which reports it against
    the `def`."""
    if node.return_type is None or any(p.type is None for p in node.params):
        return None
    return function_type(node)


def check_stmts(stmts, env, tmap, return_type):
    """The type a block yields: its last statement's, or unit when it is
    empty.

    Only the *last* statement supplies a value, which is what PYKING.md's
    "Tail position" says: a statement in the middle is run for its
    effect, however interesting its type.

    `env` is threaded from one statement to the next, so a binding is
    visible to what follows it -- and the extended environment is
    returned to nobody, which is exactly what makes a block a scope:
    what it binds cannot escape it (`analyses.py` says the same thing
    with `analyze_scope`).

    `return_type` is carried through untouched, for whatever `return`
    turns up anywhere inside; see `check_stmt`."""
    env = declare_functions(stmts, env)
    yielded = unit(stmts[0].info if stmts else Info("<empty>", 1, 0, 1, 0))
    for statement in stmts:
        yielded, env = check_stmt(statement, env, tmap, return_type)
    return yielded


# --- Stmt ------------------------------------------------------------


def check_stmt(statement, env, tmap, return_type):
    """One statement: the type of the value it supplies, and the
    environment the statements after it are checked in.

    "Supplies" is PYKING.md's "Tail position" question, asked of every
    statement: in the tail of a function body this is the function's
    value, and anywhere else it is simply ignored. Most statements supply
    nothing and so have type unit; an expression statement supplies its
    expression, an `if` supplies whatever its branches agree on, and a
    `return` supplies what it returns -- which is why nothing special is
    needed to let one branch `return` while the other ends in a value.

    `return_type` is the enclosing function's declared return type, or
    `None` at the top level. It is what a `return` is checked against,
    and it is threaded down through every nested block rather than
    consulted once at the end, because only the *last* statement's value
    reaches `check_function`: a `return` written anywhere else -- inside
    an `if` with no `else`, before a later statement -- supplies nothing
    to the body and would otherwise never be checked at all. It is also
    what makes `return` outside a function an error rather than a silent
    nothing."""
    match statement:
        case SLet(info, TargetName(_, name, _), expr, annotation, sym):
            # The binding's symbol records what its right-hand side
            # turned out to be; the binding *itself* is a statement, so
            # it has unit type.
            expr_type = check_expr(expr, env, tmap)
            check_annotation(annotation, expr_type)
            tmap[sym] = expr_type
            return unit(info), bind(env, name, expr_type)

        case SLetStmt(info, TargetName(_, name, _), stmt, annotation, sym):
            # `x = if c: ...` binds what the branch that runs yields, so
            # the bound statement's own type is the binding's type -- and
            # the branches having agreed on one is what the `SIf` case
            # below has already established.
            bound_type, _ = check_stmt(stmt, env, tmap, return_type)
            check_annotation(annotation, bound_type)
            tmap[sym] = bound_type
            return unit(info), bind(env, name, bound_type)

        case SLet() | SLetStmt():
            # A destructuring target (`a, b = ...`) needs tuple types.
            unsupported(statement)

        case SExprStmt(_, expr, _):
            # An expression statement has its expression's type. That is
            # what lets a block yield a value, and so what makes the two
            # branches of an `if` comparable.
            return check_expr(expr, env, tmap), env

        case SIf(info, cond, then_body, else_body, _):
            cond_type = check_expr(cond, env, tmap)
            if not isinstance(cond_type, TBool):
                raise TypeError_(
                    cond.info,
                    f"the condition of an 'if' must be Bool, not "
                    f"{pprint_type(cond_type)}",
                )
            then_type = check_stmts(then_body, env, tmap, return_type)
            if else_body is None:
                # With no `else` there is a way through this statement
                # that runs no branch at all, so the `if` supplies
                # nothing whatever the one branch it has ends in. A body
                # that needed that value is caught where the value was
                # needed -- `check_function` -- rather than here.
                return unit(info), env
            else_type = check_stmts(else_body, env, tmap, return_type)
            if not same_type(then_type, else_type):
                raise TypeError_(
                    info,
                    f"the branches of this 'if' have different types: "
                    f"{pprint_type(then_type)} and {pprint_type(else_type)}",
                )
            return then_type, env

        case SReturn(info, expr, _):
            # A `return` supplies the function's value explicitly, so
            # that value is what this statement supplies -- which is
            # exactly what PYKING.md's tail-position table says of it,
            # and what lets a branch that returns sit beside one that
            # ends in an expression without either being a special case.
            if return_type is None:
                raise TypeError_(info, "'return' outside a function")
            actual = check_expr(expr, env, tmap)
            if not same_type(actual, return_type):
                raise TypeError_(
                    expr.info,
                    f"this function returns {pprint_type(return_type)}, but this "
                    f"'return' gives {pprint_type(actual)}",
                )
            return actual, env

        case SReturnStmt(info, stmt, _):
            # `return if c: ...` -- the same rule, against whatever the
            # branch that runs yields.
            if return_type is None:
                raise TypeError_(info, "'return' outside a function")
            actual, _ = check_stmt(stmt, env, tmap, return_type)
            if not same_type(actual, return_type):
                raise TypeError_(
                    info,
                    f"this function returns {pprint_type(return_type)}, but this "
                    f"'return' gives {pprint_type(actual)}",
                )
            return actual, env

        case SFunctionDef(_, name, _, _, _, _, _):
            # Checked against its annotations here; visible under its own
            # name only to the statements that follow.
            return (check_function(statement, env, tmap),
                    bind(env, name, function_type(statement)))

        case _:
            unsupported(statement)


# --- Expr ------------------------------------------------------------


def check_expr(expr, env, tmap):
    """The type of one expression, recorded in `tmap` under its symbol.

    Every expression is recorded, not just the annotatable constructs:
    the entry costs nothing to make and is what lets a consumer ask "what
    type is *this* subexpression" -- which `pprint_program` never needs,
    but a backend does. `src/target_ocaml.py` is the first: it compiles
    only what this checker accepts, so rather than inferring types a
    second time it reads them back from here."""
    type_ = expr_type(expr, env, tmap)
    tmap[expr.sym] = type_
    return type_


def expr_type(expr, env, tmap):
    """`check_expr` without the recording -- the rules themselves."""
    match expr:
        case EInt(info, _, _):
            return TInt(info)

        case EString(info, _, _):
            return TString(info)

        case EBool(info, _, _):
            return TBool(info)

        case EVar(info, name, _):
            # Two different questions, asked in order. Is the name in
            # scope at all -- a question about *names*, answered the way
            # `analyses.py` answers it and reported the same way? And
            # then: does this checker know a type for it?
            if name not in env:
                raise AnalysisError(info, f"unbound name '{name}'")
            type_ = env[name]
            if isinstance(type_, Builtin):
                raise TypeError_(
                    info,
                    f"'{name}' is a builtin operation: it can be called, but "
                    f"not used as a value",
                )
            if type_ is None:
                # In scope, but with no type here: a builtin, or the
                # function whose own body this is (which is how recursion
                # is refused). Outside the fragment, like any other
                # construct this checker has not reached yet.
                unsupported(expr)
            return type_

        case EAdd() | ESub() | EMul() | ELessThan() | ELessThanEq() \
                | EGreatThan() | EGreatThanEq() | EEq():
            return check_binary(expr, env, tmap)

        case ECall():
            return check_call(expr, env, tmap)

        case _:
            unsupported(expr)


# --- Param -----------------------------------------------------------


def check_param(param, tmap):
    """A parameter's declared type, recorded under its symbol.

    Only ever called for a parameter that *has* an annotation:
    `function_type` refuses a `def` with any parameter missing one
    before this is reached, since a function is checked as a whole or
    not at all."""
    tmap[param.sym] = param.type
    return param.type


# --- SFunctionDef ----------------------------------------------------


def function_type(node):
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


def check_function(node, env, tmap):
    """Checks a `def` against its annotations, and returns unit: the
    definition is a statement, whatever the function's own type is."""
    ftype = function_type(node)
    for param in node.params:
        check_param(param, tmap)
    tmap[node.sym] = ftype

    # `env` already holds this function and every other `def` of the
    # block it is in (see `declare_functions`), which is what lets a body
    # call itself, its siblings, and functions written further down. The
    # parameters bind over that, shadowing whatever they share a name
    # with, exactly as `analyses.py` binds them.
    body_env = env
    for param in node.params:
        body_env = bind(body_env, param.name, param.type)

    if node.expr is not None:
        # `def f(x:Int) -> Int = expr`: the expression *is* the result.
        actual = check_expr(node.expr, body_env, tmap)
        if not same_type(actual, node.return_type):
            raise TypeError_(
                node.expr.info,
                f"'{node.name}' returns {pprint_type(node.return_type)}, but "
                f"its body has type {pprint_type(actual)}",
            )
        return unit(node.info)

    # The body's last statement is the one in tail position, and what it
    # supplies is the function's value -- whether it supplies it with a
    # `return` or by simply being an expression. One check covers both,
    # because `check_stmt` already answers that one question for every
    # kind of statement.
    supplied = check_stmts(node.body, body_env, tmap, node.return_type)
    if same_type(supplied, node.return_type):
        return unit(node.info)
    if is_unit(supplied):
        raise TypeError_(
            node.info,
            f"'{node.name}' returns {pprint_type(node.return_type)}, so its "
            f"body must return on every path, or end in an expression of "
            f"that type",
        )
    raise TypeError_(
        node.body[-1].info,
        f"'{node.name}' returns {pprint_type(node.return_type)}, but its "
        f"body ends in a value of type {pprint_type(supplied)}",
    )


# --- ECall -----------------------------------------------------------


def check_call(call, env, tmap):
    """The type of a call: its function's result, once the arguments
    have been checked against that function's parameters. Anything of
    function type may be called, so a parameter annotated `(Int) -> Int`
    is as callable as a `def`'s own name -- and so is a builtin, which is
    the one callable thing with no type of its own."""
    match call.func:
        case EVar(_, name, _) if isinstance(env.get(name), Builtin):
            return check_builtin_call(name, call, env, tmap)
    func_type = check_expr(call.func, env, tmap)
    if not isinstance(func_type, TFunction):
        raise TypeError_(
            call.info,
            f"this call applies something of type {pprint_type(func_type)}, "
            f"which is not a function",
        )
    if len(call.args) != len(func_type.params):
        expected, given = len(func_type.params), len(call.args)
        raise TypeError_(
            call.info,
            f"this function takes {expected} argument{'' if expected == 1 else 's'}, "
            f"but {given} {'was' if given == 1 else 'were'} given",
        )
    for position, (arg, expected) in enumerate(zip(call.args, func_type.params), 1):
        actual = check_expr(arg, env, tmap)
        if not same_type(actual, expected):
            raise TypeError_(
                arg.info,
                f"argument {position} has type {pprint_type(actual)}, but "
                f"{pprint_type(expected)} was expected",
            )
    return func_type.result


def check_builtin_call(name, call, env, tmap):
    """A call to one of the four host operations.

    Their signatures live here rather than in `env` because none of them
    fits a `TFunction` (see the note beside `Builtin`), and because that
    is the only position a builtin may appear in. Each argument is
    checked like any other expression first; what differs is what the
    operation accepts and what it gives back:

        print(...)   any number of arguments, of any type   -> ()
        str(x)       one Int, String or Bool                -> String
        len(x)       one [T] or String                      -> Int
        range(n)     one to three Ints                      -> [Int]

    `print` accepting anything is `runtime_interface.py`'s rule, not a
    shortcut: it pins how every type is formatted, unit included.
    `range`'s arity is the one thing here the language reference does
    not pin down -- the backends inherit Python's `range` -- so all
    three forms are accepted rather than guessed at."""
    args = [check_expr(argument, env, tmap) for argument in call.args]

    match name:
        case "print":
            return unit(call.info)

        case "str":
            check_builtin_arity(name, call, 1, 1)
            if not isinstance(args[0], (TInt, TString, TBool)):
                raise builtin_argument_error(
                    name, call.args[0], args[0], "Int, String or Bool"
                )
            return TString(call.info)

        case "len":
            check_builtin_arity(name, call, 1, 1)
            if not isinstance(args[0], (TList, TString)):
                raise builtin_argument_error(
                    name, call.args[0], args[0], "a list or a String"
                )
            return TInt(call.info)

        case "range":
            check_builtin_arity(name, call, 1, 3)
            for argument, actual in zip(call.args, args):
                if not isinstance(actual, TInt):
                    raise builtin_argument_error(name, argument, actual, "Int")
            return TList(call.info, TInt(call.info))

    # Unreachable while `BUILTINS` and the cases above agree; a new
    # builtin without a signature here should say so rather than be
    # quietly accepted.
    unsupported(call)


def check_builtin_arity(name, call, low, high):
    given = len(call.args)
    if low <= given <= high:
        return
    expected = f"{low}" if low == high else f"{low} to {high}"
    raise TypeError_(
        call.info,
        f"'{name}' takes {expected} argument{'' if high == 1 else 's'}, but "
        f"{given} {'was' if given == 1 else 'were'} given",
    )


def builtin_argument_error(name, argument, actual, accepted):
    return TypeError_(
        argument.info,
        f"'{name}' cannot be applied to {pprint_type(actual)}; it accepts "
        f"{accepted}",
    )


# --- operators -------------------------------------------------------

# The binary operators this checker knows, as
# `node class -> (spelling, [(operand type, result type), ...])`. Several
# are overloaded, which is why the table maps to a *list* of signatures
# rather than one: `12 + 20` is `Int`, `'hi' + 'there'` is `String`, and
# `13 + 'hello'` matches neither and is an error. Both operands must
# match the *same* signature, which is what makes `1 == 'x'` an error
# rather than a comparison that is merely always false.
OPERATORS = {
    EAdd: ("+", [(TInt, TInt), (TString, TString)]),
    ESub: ("-", [(TInt, TInt)]),
    EMul: ("*", [(TInt, TInt)]),
    ELessThan: ("<", [(TInt, TBool)]),
    ELessThanEq: ("<=", [(TInt, TBool)]),
    EGreatThan: (">", [(TInt, TBool)]),
    EGreatThanEq: (">=", [(TInt, TBool)]),
    EEq: ("==", [(TInt, TBool), (TString, TBool), (TBool, TBool)]),
}


def check_binary(expr, env, tmap):
    """The type of a binary operator application, from `OPERATORS`."""
    spelling, signatures = OPERATORS[type(expr)]
    left_type = check_expr(expr.left, env, tmap)
    right_type = check_expr(expr.right, env, tmap)
    for operand, result in signatures:
        if isinstance(left_type, operand) and isinstance(right_type, operand):
            return result(expr.info)
    # Every type in the message is spelled by `pprint_type`, the same
    # function that prints a type in source and in `--ast` output, so an
    # error can never name a type differently from the way the program
    # would have to write it. A signature's operand is a *class* here, so
    # it is instantiated to be printed -- only ever on this error path.
    accepted = " or ".join(
        f"{name} {spelling} {name}"
        for name in (pprint_type(operand(expr.info)) for operand, _ in signatures)
    )
    raise TypeError_(
        expr.info,
        f"`{spelling}` cannot be applied to {pprint_type(left_type)} and "
        f"{pprint_type(right_type)}; it accepts {accepted}",
    )


# --- Type ------------------------------------------------------------


def check_annotation(annotation, actual):
    """Checks a binding's own annotation, if it wrote one, against what
    its right-hand side turned out to be.

    An annotation is a claim about the program, so where one exists it is
    checked rather than replaced -- which is the whole difference between
    an annotation and a comment. A binding that wrote none claims
    nothing, and takes whatever its value has.

    The error is reported against the *annotation*: the value is a
    perfectly good value of its own type, and the disagreement is
    something the program stated."""
    if annotation is None or same_type(annotation, actual):
        return
    raise TypeError_(
        annotation.info,
        f"this binding is annotated {pprint_type(annotation)}, but its "
        f"value has type {pprint_type(actual)}",
    )


def same_type(a, b):
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
            return same_type(x, y)
        case (TTuple(_, xs), TTuple(_, ys)):
            return len(xs) == len(ys) and all(map(same_type, xs, ys))
        case (TFunction(_, ps, r), TFunction(_, qs, s)):
            return (len(ps) == len(qs) and all(map(same_type, ps, qs))
                    and same_type(r, s))
        case _:
            return False


def unit(info):
    """The unit type, `()` -- an empty tuple type. What a statement, and
    a program, has."""
    return TTuple(info, [])


def is_unit(t):
    return isinstance(t, TTuple) and not t.elements


# --- Env -------------------------------------------------------------


def bind(env, name, type_):
    """`env` with `name` in scope, of `type_` -- or of no type this
    checker knows, when `type_` is `None`. A fresh dict, never a mutation
    of the one passed in: what a name means is decided by where it is
    written, and rebinding one here would change what it meant somewhere
    else.

    Every binding form goes through this, which is what makes shadowing
    work by construction -- an inner binding simply replaces the entry
    the outer one made, and the outer dict is untouched."""
    return {**env, name: type_}
