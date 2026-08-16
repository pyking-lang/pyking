"""The type checker: one function per AST datatype, giving every
expression a type and recording annotated constructs in a symbol
table (tmap). Run only under --typecheck, after symbolize. A def that
is fully annotated is checked where it is written; one that is not is
checked (inferred) the first time something calls it. See PYKING.md
("Type checking") and docs/type_inference.md for the rules and the
inference design.

Data structures:
    TypeError_ -- a type-check failure, with the source position.
    Builtin -- a name denoting a host operation, not a value.
    Instance / Use / Frame / Store -- inference's working state (see
        docs/type_inference.md).
    Inferring -- marks a return type being worked out.
    Loop -- the loop a break/continue in this statement belongs to.

Functions:
    type_check(stmts) -- checks a whole program; returns tmap.
    check_stmt(stmt, env, tmap, return_type, loop, store) -- checks one
        statement.
    check_expr(expr, env, tmap, store) -- checks one expression.
    same_type(a, b) / accepts(expected, actual) -- type comparison.

See the Signatures block below for every function's type.
"""

from dataclasses import dataclass, replace

from analyses import AnalysisError, BUILTINS, block_functions
from lexer import Info
from syntax import (
    pprint_type,
    EInt, EString, EBool, EVar, EAdd, ESub, EMul, ECall, EIf, ETuple,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq,
    SLet, SLetStmt, SExprStmt, SIf, SReturn, SReturnStmt, SFunctionDef,
    SLoop, SBreak, SContinue,
    Type, TInt, TString, TBool, TList, TTuple, TFunction, TOr, TUnknown, TNever,
    TargetName, TargetTuple,
)


# ---------------------------------------------------------------------
# Signatures
#
# Written as they would be in a language that could state them, with
# `syntax.py`'s legend: `[T]` is a list of `T`, `T?` a value that may be
# absent, and `(A, B)` a pair. Three values are threaded through the
# pass, and every one of them is *handed over* rather than written to:
#
#     Env   = {String: Type?}     the names in scope, and their types
#                                 where this checker knows one
#     Store                       everything inference has worked out --
#                                 see the class below
#     TMap  = {Int: Type}         symbol -> inferred type; the result,
#                                 and the one thing here that is filled
#                                 in rather than rebuilt
#
# The `Type?` each statement function takes (`return_type`) is the
# declared return type of the function whose body is being checked,
# `INFERRING` while one is being worked out, and absent at the top level,
# where a `return` has nothing to return from. It is what a `return` is
# checked against, wherever in the body it is written -- which is why it
# is threaded down through nested blocks and not just looked at once when
# the body is done.
#
# The `Loop?` beside it is the same idea for the same reason: the loop a
# `break`/`continue` written here belongs to, absent where there is
# none. A `def` inside a loop body passes `None` for it, since a
# `break` may not cross one (src/parser.py enforces that, so this is
# only saying the same thing again where it would matter).
#
#     val type_check         : [Stmt] -> TMap
#     val check_stmts        : [Stmt] -> Env -> TMap -> Type? -> Loop?
#                              -> Store -> (Type, Store)
#     val check_stmt         : Stmt -> Env -> TMap -> Type? -> Loop?
#                              -> Store -> (Type, Env, Store)
#     val check_expr         : Expr -> Env -> TMap -> Store -> (Type, Store)
#     val check_param        : Param -> TMap -> Store -> Type
#     val check_function     : SFunctionDef -> Env -> TMap -> Store
#                              -> (Type, Store)
#     val check_call         : ECall -> Env -> TMap -> Store -> (Type, Store)
#     val check_binary       : Expr -> Env -> TMap -> Store -> (Type, Store)
#     val check_annotation   : Type? -> Type -> ()
#     val check_target       : AssignTarget -> Type -> Env -> TMap -> Store
#                              -> Env
#     val function_type      : SFunctionDef -> TFunction
#     val same_type          : Type -> Type -> Bool
#     val bind               : Env -> String -> Type -> Env
#     val unit               : Info -> Type
#
# and, for a function whose type was not written down (see "Functions,
# and the two places one can be checked" above):
#
#     val declare_functions  : [Stmt] -> Env -> Store -> (Env, Store)
#     val declared_type      : SFunctionDef -> TFunction
#     val infer_call         : TFunction -> [Type] -> ECall -> TMap -> Store
#                              -> (Type, Store)
#     val infer_body         : SFunctionDef -> Env -> [Type] -> Type -> TMap
#                              -> Store -> (Type, Store)
#     val trace              : SFunctionDef -> Env -> TMap -> Store
#                              -> (Type, Store)
#     val recall             : Store -> Int -> [Type] -> Use?
#     val reported_type      : Type -> Store -> Type
#     val merge              : [Type] -> Type
#     val accepts            : Type -> Type -> Bool
#     val same_instance      : Type -> Type -> Bool
#     val resolved           : Type -> Store -> Type
#
# A function that takes a `Store` returns one: what a check works out is
# knowledge, and knowledge that was not handed back would be lost. The
# one exception is `record`, which fills in `TMap`; see there for why
# that table alone is written to.
#
# Only `type_check` is meant to be called from outside -- with one
# deliberate exception: `src/repl.py` checks a session one entry at a
# time, and so calls `declare_functions`, `check_stmt`, `check_expr` and
# `resolved` itself, carrying the `Env` and the `Store` between entries.
#
# ---------------------------------------------------------------------


class TypeError_(Exception):
    """A type-check failure, or a refusal of an unsupported construct,
    with the source position. Named with a trailing underscore to avoid
    shadowing Python's own TypeError."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


# `env` maps a name to a Type, a Builtin (one of the four operations,
# checked at the call by check_builtin_call), or None (in scope, no
# type yet -- an unannotated def).


@dataclass(frozen=True)
class Builtin:
    """A name denoting a host operation, not a value. Field: name: String."""
    name: str


@dataclass(frozen=True)
class Instance:
    """One shape a deferred function has been checked at. See
    docs/type_inference.md. Fields: params: [Type] (cache key, as
    passed), result: Type, reported: Type (params/result as they turned
    out, for display), uses: (Use,) (instances this call went through)."""
    params: list
    result: Type
    reported: Type
    uses: tuple


@dataclass(frozen=True)
class Use:
    """One instance of one deferred function. Fields: tmsym: Int (the
    definition), index: Int (its position in that definition's instances)."""
    tmsym: int
    index: int


@dataclass(frozen=True)
class Frame:
    """What the current inference has gathered, and what the innermost
    loop has been broken with. Fields: uses: (Use,), returns: (Type,),
    breaks: (Type,)."""
    uses: tuple = ()
    returns: tuple = ()
    breaks: tuple = ()


@dataclass(frozen=True)
class Store:
    """Everything inference has worked out, threaded through the pass
    like env (see docs/type_inference.md). Fields:
    environments: {Int: Env} (tmsym -> where that def was written),
    instances: {Int: (Instance,)} (tmsym -> what has been worked out),
    checking: {Int} (tmsyms whose bodies are being checked right now),
    frame: Frame (the innermost inference's)."""
    environments: dict
    instances: dict
    checking: frozenset
    frame: Frame


def empty_store():
    """The store a program starts checking in. () -> Store"""
    return Store({}, {}, frozenset(), Frame())


def with_environment(store, tmsym, env):
    """store recording where the definition tmsym was written.
    Store -> Int -> Env -> Store"""
    return replace(store, environments={**store.environments, tmsym: env})


def environment_of(store, tmsym):
    """Where tmsym was written, or None. Store -> Int -> Env?"""
    return store.environments.get(tmsym)


def instances_of(store, tmsym):
    """What has been worked out about tmsym, oldest first.
    Store -> Int -> (Instance,)"""
    return store.instances.get(tmsym, ())


def remembering(store, tmsym, instance):
    """store with one more Instance recorded for tmsym.
    Store -> Int -> Instance -> Store"""
    return replace(
        store,
        instances={**store.instances, tmsym: instances_of(store, tmsym) + (instance,)},
    )


def instance_at(store, use):
    """The Instance a Use points at. Store -> Use -> Instance"""
    return instances_of(store, use.tmsym)[use.index]


def checking_now(store, tmsym):
    """store with tmsym's body marked as being checked.
    Store -> Int -> Store"""
    return replace(store, checking=store.checking | {tmsym})


def with_frame(store, frame):
    """store gathering into a different frame. Store -> Frame -> Store"""
    return replace(store, frame=frame)


def returning(store, type_):
    """store whose frame has seen a return of type_.
    Store -> Type -> Store"""
    return with_frame(store, replace(store.frame, returns=store.frame.returns + (type_,)))


def breaking(store, type_):
    """store whose frame has seen a `break` giving type_ -- what the
    loop being checked is worth, one way out at a time.
    Store -> Type -> Store"""
    return with_frame(store, replace(store.frame, breaks=store.frame.breaks + (type_,)))


def noting(store, uses):
    """store whose frame records that the inference in progress went
    through these uses (in order, without repeats).
    Store -> (Use,) -> Store"""
    fresh = tuple(use for use in uses if use not in store.frame.uses)
    return with_frame(store, replace(store.frame, uses=store.frame.uses + fresh))


def learned(store, inner):
    """store with what an inner check found out (environments,
    instances) merged in; frame and checking stay store's own.
    Store -> Store -> Store"""
    return replace(store, environments=inner.environments, instances=inner.instances)


@dataclass(frozen=True)
class Inferring:
    """Stands in for a declared return type while one is being worked
    out; a return checked against it contributes to the frame instead
    of being compared."""


INFERRING = Inferring()


@dataclass(frozen=True)
class Loop:
    """The loop a `break`/`continue` in the statement being checked
    belongs to. Fields: accumulator: Type, the type the loop carries
    from turn to turn and yields when it stops; written: Bool, whether
    the loop wrote an accumulator down at all (a bare `loop:` carries
    unit, and its `break`/`continue` take no value)."""
    accumulator: Type
    written: bool


class _Recursive(Exception):
    """Internal signal: a trace reached a call to a function whose
    body is already being checked. Not an error -- caught by the
    nearest if, by a body with a return already seen, or by the
    inference waiting on the named definition. See
    docs/type_inference.md, "Recursion"."""

    def __init__(self, definition, info, store):
        super().__init__(definition.name)
        self.definition = definition
        self.info = info
        self.store = store

    @property
    def name(self):
        return self.definition.name


UNSUPPORTED = "Construct is not supported"


def unsupported(node):
    """Raises TypeError_ refusing node. Node -> ()"""
    raise TypeError_(node.info, UNSUPPORTED)


# --- the program -----------------------------------------------------


def type_check(stmts):
    """Type-checks a whole program. Raises TypeError_ for the first
    thing that does not check out. [Stmt] -> {Int: Type}"""
    tmap = {}
    check_stmts(stmts, builtin_env(), tmap, None, None, empty_store())
    return tmap


def builtin_env():
    """The environment a program starts in: every name in
    analyses.BUILTINS, as a Builtin. Its own function so src/repl.py
    can reuse it when checking a session one entry at a time.
    () -> Env"""
    return {name: Builtin(name) for name in BUILTINS}


# --- [Stmt] ----------------------------------------------------------


def declare_functions(stmts, env, store):
    """env with every def in this block bound (recursion, mutual
    recursion, forward references); store recording where each
    unannotated one was written. Not recursive: a def inside a branch
    is declared when that branch's block is checked.
    [Stmt] -> Env -> Store -> (Env, Store)"""
    functions = list(block_functions(stmts).values())
    for function in functions:
        env = bind(env, function.name, declared_type(function))
    for function in functions:
        if not fully_annotated(function):
            store = with_environment(store, function.sym, env)
    return env, store


def fully_annotated(node):
    """Whether a def wrote down every parameter type and the return
    type. SFunctionDef -> Bool"""
    return node.return_type is not None and all(p.type is not None for p in node.params)


def declared_type(node):
    """The type a def has from the def alone: its written type, or an
    incomplete TFunction with TUnknown for what it did not say.
    SFunctionDef -> TFunction"""
    if fully_annotated(node):
        return function_type(node)
    return TFunction(
        node.info,
        [p.type if p.type is not None else TUnknown(p.info) for p in node.params],
        node.return_type if node.return_type is not None else TUnknown(node.info),
        tmsym=node.sym,
        definition=node,
    )


def check_stmts(stmts, env, tmap, return_type, loop, store):
    """The type a block yields: its last statement's, or unit if
    empty. env is not returned (a block is a scope); store is.
    [Stmt] -> Env -> {Int: Type} -> Type? -> Loop? -> Store
    -> (Type, Store)"""
    env, store = declare_functions(stmts, env, store)
    yielded = unit(stmts[0].info if stmts else Info("<empty>", 1, 0, 1, 0))
    for statement in stmts:
        yielded, env, store = check_stmt(statement, env, tmap, return_type, loop, store)
    return yielded, store


# --- Stmt ------------------------------------------------------------


def check_stmt(statement, env, tmap, return_type, loop, store):
    """The type statement supplies (PYKING.md, "Tail position"), the
    environment for the statements after it, and the store.
    return_type is the enclosing function's declared return type,
    INFERRING while one is worked out, or None at the top level; loop
    is the loop a break/continue here belongs to, or None.
    Stmt -> Env -> {Int: Type} -> Type? -> Loop? -> Store
    -> (Type, Env, Store)"""
    match statement:
        case SLet(info, target, expr, annotation, sym):
            # The binding's symbol records what its right-hand side
            # turned out to be; the binding *itself* is a statement, so
            # it has unit type.
            expr_type_, store = check_expr(expr, env, tmap, store)
            check_annotation(annotation, expr_type_)
            record(tmap, sym, expr_type_, store)
            return unit(info), check_target(target, expr_type_, env, tmap, store), store

        case SLetStmt(info, target, stmt, annotation, sym):
            # `x = if c: ...` binds what the branch that runs yields, so
            # the bound statement's own type is the binding's type -- and
            # the branches having agreed on one is what the `SIf` case
            # below has already established. `x = loop ...` binds the
            # accumulator the loop stopped with, for the same reason.
            bound_type, _, store = check_stmt(stmt, env, tmap, return_type, loop, store)
            check_annotation(annotation, bound_type)
            record(tmap, sym, bound_type, store)
            return unit(info), check_target(target, bound_type, env, tmap, store), store

        case SExprStmt(_, expr, _):
            # An expression statement has its expression's type. That is
            # what lets a block yield a value, and so what makes the two
            # branches of an `if` comparable.
            type_, store = check_expr(expr, env, tmap, store)
            return type_, env, store

        case SIf(info, cond, then_body, else_body, _):
            cond_type, store = check_expr(cond, env, tmap, store)
            if not isinstance(cond_type, TBool):
                raise TypeError_(
                    cond.info,
                    f"the condition of an 'if' must be Bool, not "
                    f"{pprint_type(cond_type)}",
                )
            # Each branch is checked in a way that survives meeting a
            # recursive call it cannot type yet: this is the "backtrack
            # to the `if`" of docs/type_inference.md, and it is the only
            # place a trace is ever abandoned. Outside an inference it
            # never happens, since nothing raises `_Recursive` there.
            then_type, then_store, then_signal = try_branch(
                then_body, env, tmap, return_type, loop, store
            )
            if else_body is None:
                # With no `else` there is a way through this statement
                # that runs no branch at all, so the `if` supplies
                # nothing whatever the one branch it has ends in. A body
                # that needed that value is caught where the value was
                # needed -- `check_function` -- rather than here.
                return unit(info), env, store if then_signal else then_store
            # The `else` is checked against what the `then` *found out*,
            # not against the store they both started from: only one of
            # them runs, but both were checked, and what either worked
            # out about a function is true whichever way the program
            # goes. An abandoned branch found out nothing (see
            # `try_branch`), so its store is the one it began with.
            else_type, else_store, else_signal = try_branch(
                else_body, env, tmap, return_type, loop, then_store
            )
            if then_signal is not None and else_signal is not None:
                # Both ways through recurse: this `if` says nothing about
                # the type, and the question moves outwards, still about
                # the function it was always about.
                raise then_signal
            if then_signal is not None:
                return else_type, env, else_store
            if else_signal is not None:
                return then_type, env, then_store
            if isinstance(then_type, TNever):
                # A branch that cannot finish -- a loop with no `break`
                # in it -- leaves the type of the `if` to the other one.
                return else_type, env, else_store
            if isinstance(else_type, TNever):
                return then_type, env, else_store
            if not same_type(then_type, else_type):
                raise TypeError_(
                    info,
                    f"the branches of this 'if' have different types: "
                    f"{pprint_type(then_type)} and {pprint_type(else_type)}",
                )
            check_not_conflated(then_type, else_type, info)
            # Both branches were checked against the same store, and
            # either may have worked something out; the second one's
            # holds what the first found as well, since it was threaded
            # through it.
            return then_type, env, else_store

        case SReturn(info, expr, _):
            # A `return` supplies the function's value explicitly, so
            # that value is what this statement supplies -- which is
            # exactly what PYKING.md's tail-position table says of it,
            # and what lets a branch that returns sit beside one that
            # ends in an expression without either being a special case.
            if return_type is None:
                raise TypeError_(info, "'return' outside a function")
            actual, store = check_expr(expr, env, tmap, store)
            return actual, env, check_return(actual, return_type, expr.info, store)

        case SReturnStmt(info, stmt, _):
            # `return if c: ...` -- the same rule, against whatever the
            # branch that runs yields.
            if return_type is None:
                raise TypeError_(info, "'return' outside a function")
            actual, _, store = check_stmt(stmt, env, tmap, return_type, loop, store)
            return actual, env, check_return(actual, return_type, info, store)

        case SLoop(info, target, init, annotation, body, sym):
            # The accumulator is what the initializer turned out to be,
            # and the loop carries exactly that from turn to turn: the
            # body has to produce one, `break`/`continue` have to give
            # one, and the loop yields one. A bare `loop:` carries unit
            # and its body's value is thrown away, so there is nothing
            # for the body to get wrong.
            if target is None:
                accumulator = unit(info)
                body_env = env
            else:
                accumulator, store = check_expr(init, env, tmap, store)
                check_annotation(annotation, accumulator)
                body_env = check_target(target, accumulator, env, tmap, store)
            record(tmap, sym, accumulator, store)
            # The loop's own breaks are collected in a frame of its own,
            # so a nested loop's ways out are not mistaken for this
            # one's; the enclosing frame is put back afterwards.
            outer = store.frame
            supplied, store = check_stmts(
                body, body_env, tmap, return_type, Loop(accumulator, target is not None),
                with_frame(store, replace(outer, breaks=())),
            )
            if target is not None and not accepts(accumulator, supplied):
                raise TypeError_(
                    body[-1].info if body else info,
                    f"this loop carries {pprint_type(accumulator)}, so its "
                    f"body must end in a value of that type -- the "
                    f"accumulator for the next turn -- but it ends in "
                    f"{pprint_type(supplied)}",
                )
            # A loop is worth what it breaks with. With no `break` at
            # all it cannot finish, so it is worth nothing anything can
            # be wrong about -- which is what lets a function whose body
            # is such a loop honour any return type.
            ways_out = store.frame.breaks
            store = with_frame(store, outer)
            return (merge(list(ways_out)) if ways_out else TNever(info)), env, store

        case SBreak(info, expr, _):
            # A `break` says what the loop is *worth*, which is a
            # different question from what it carries: the operand is
            # collected rather than checked against the accumulator.
            # What the statement supplies is the accumulator all the
            # same -- it never falls through, so nothing can observe
            # that answer, and giving it the one its neighbours give is
            # what lets a branch that breaks sit beside one that ends in
            # the next accumulator.
            if loop is None:
                raise TypeError_(info, "'break' outside a loop")
            if expr is None:
                return loop.accumulator, env, breaking(store, loop.accumulator)
            actual, store = check_expr(expr, env, tmap, store)
            return loop.accumulator, env, breaking(store, actual)

        case SContinue(info, expr, _):
            # `continue` is the other half: it says what the next turn
            # carries, so its operand *is* the accumulator.
            if loop is None:
                raise TypeError_(info, "'continue' outside a loop")
            if expr is None:
                return loop.accumulator, env, store
            if not loop.written:
                raise TypeError_(
                    expr.info,
                    "this loop carries no accumulator, so its 'continue' "
                    "takes no value",
                )
            actual, store = check_expr(expr, env, tmap, store)
            if not accepts(loop.accumulator, actual):
                raise TypeError_(
                    expr.info,
                    f"this loop carries {pprint_type(loop.accumulator)}, but "
                    f"this 'continue' gives {pprint_type(actual)}",
                )
            return loop.accumulator, env, store

        case SFunctionDef(info, name, _, _, _, _, sym):
            if fully_annotated(statement):
                # Checked against its annotations here; visible under its
                # own name only to the statements that follow.
                supplied, store = check_function(statement, env, tmap, store)
                return supplied, bind(env, name, function_type(statement)), store
            # Not fully annotated: there is nothing to check yet, because
            # what an unannotated parameter is depends on what is passed
            # to it. All this statement does is fix *where* the function
            # was written, since that is the scope its body belongs to
            # however far away it is eventually called from. The name is
            # already bound, by `declare_functions`, and the binding
            # names the definition by symbol -- so recording the
            # environment here is what every holder of that name sees.
            return unit(info), env, with_environment(store, sym, env)

        case _:
            unsupported(statement)


def check_not_conflated(then_type, else_type, info):
    """Raises TypeError_ if an if yields one of two different
    unannotated functions (see docs/type_inference.md).
    Type -> Type -> Info -> ()"""
    match (then_type, else_type):
        case (TFunction(_, _, _, _, _, SFunctionDef() as mine),
              TFunction(_, _, _, _, _, SFunctionDef() as theirs)) if mine.sym != theirs.sym:
            raise TypeError_(
                info,
                f"this 'if' yields one of two functions -- "
                f"'{mine.name}' and '{theirs.name}' -- and neither says "
                f"what its type is, so there is no telling which one a "
                f"later call would be checking. Annotate them, or call "
                f"them where they are chosen",
            )


def try_expr(expr, env, tmap, store):
    """One branch of an if expression, as (type, store, signal): signal
    is the _Recursive that stopped it, or None.
    Expr -> Env -> {Int: Type} -> Store -> (Type?, Store, _Recursive?)"""
    try:
        type_, store = check_expr(expr, env, tmap, store)
        return type_, store, None
    except _Recursive as signal:
        return None, store, signal


def try_branch(body, env, tmap, return_type, loop, store):
    """One branch of an if statement, as (type, store, signal). On a
    signal, store is the one the branch started from (its own work was
    provisional).
    [Stmt] -> Env -> {Int: Type} -> Type? -> Loop? -> Store
    -> (Type?, Store, _Recursive?)"""
    try:
        type_, store = check_stmts(body, env, tmap, return_type, loop, store)
        return type_, store, None
    except _Recursive as signal:
        return None, store, signal


def check_target(target, type_, env, tmap, store):
    """env with every name in an assignment target bound to its part of
    type_, recording each part under the target's own symbol. A
    destructuring target requires a tuple type of the same length.
    AssignTarget -> Type -> Env -> {Int: Type} -> Store -> Env"""
    match target:
        case TargetName(_, name, sym):
            record(tmap, sym, type_, store)
            return bind(env, name, type_)
        case TargetTuple(info, elements, sym):
            match resolved(type_, store):
                case TTuple(_, parts) if len(parts) == len(elements):
                    record(tmap, sym, type_, store)
                    for element, part in zip(elements, parts):
                        env = check_target(element, part, env, tmap, store)
                    return env
            raise TypeError_(
                info,
                f"this binding takes {len(elements)} values apart, but its "
                f"value has type {pprint_type(type_)}",
            )


def check_return(actual, return_type, info, store):
    """Checks a return's type against return_type, or -- if
    return_type is Inferring -- collects it into store's frame.
    Type -> Type -> Info -> Store -> Store"""
    match return_type:
        case Inferring():
            return returning(store, actual)
    if not accepts(return_type, actual):
        raise TypeError_(
            info,
            f"this function returns {pprint_type(return_type)}, but this "
            f"'return' gives {pprint_type(actual)}",
        )
    return store


# --- Expr ------------------------------------------------------------


def check_expr(expr, env, tmap, store):
    """The type of one expression, recorded in tmap under its symbol
    (every expression, not just annotatable ones -- target_ocaml.py
    reads these back rather than inferring a second time).
    Expr -> Env -> {Int: Type} -> Store -> (Type, Store)"""
    type_, store = expr_type(expr, env, tmap, store)
    record(tmap, expr.sym, type_, store)
    return type_, store


def expr_type(expr, env, tmap, store):
    """check_expr without the recording -- the rules themselves.
    Expr -> Env -> {Int: Type} -> Store -> (Type, Store)"""
    match expr:
        case EInt(info, _, _):
            return TInt(info), store

        case EString(info, _, _):
            return TString(info), store

        case EBool(info, _, _):
            return TBool(info), store

        case ETuple(info, elements, _):
            # A tuple of the element types, in order -- and `()`, with no
            # elements, is the unit type, which is the same thing said of
            # nothing.
            types, store = check_each(elements, env, tmap, store)
            return TTuple(info, types), store

        case EVar(info, name, _):
            # Two different questions, asked in order. Is the name in
            # scope at all -- a question about *names*, answered the way
            # `analyses.py` answers it and reported the same way? And
            # then: does this checker know a type for it?
            if name not in env:
                raise AnalysisError(info, f"unbound name '{name}'")
            match env[name]:
                case Builtin(builtin):
                    raise TypeError_(
                        info,
                        f"'{builtin}' is a builtin operation: it can be called, "
                        f"but not used as a value",
                    )
                case None:
                    # In scope, but with no type here. Nothing produces
                    # one today -- a `def` that annotated nothing gets an
                    # incomplete type rather than none at all -- and it
                    # is kept as the floor for whatever comes next.
                    unsupported(expr)
                case type_:
                    return type_, store

        case EIf(info, cond, then_expr, else_expr, _):
            # The `if` *expression*, whose `else` is mandatory -- so
            # unlike the statement it always yields a value, and its
            # branches must agree on what.
            cond_type, store = check_expr(cond, env, tmap, store)
            if not isinstance(cond_type, TBool):
                raise TypeError_(
                    cond.info,
                    f"the condition of an 'if' must be Bool, not "
                    f"{pprint_type(cond_type)}",
                )
            then_type, then_store, then_signal = try_expr(then_expr, env, tmap, store)
            # As in the statement form: the second branch is checked
            # against what the first found out.
            else_type, else_store, else_signal = try_expr(
                else_expr, env, tmap, then_store
            )
            if then_signal is not None and else_signal is not None:
                raise then_signal
            if then_signal is not None:
                return else_type, else_store
            if else_signal is not None:
                return then_type, then_store
            if not same_type(then_type, else_type):
                raise TypeError_(
                    info,
                    f"the branches of this 'if' have different types: "
                    f"{pprint_type(then_type)} and {pprint_type(else_type)}",
                )
            check_not_conflated(then_type, else_type, info)
            return then_type, else_store

        case EAdd() | ESub() | EMul() | ELessThan() | ELessThanEq() \
                | EGreatThan() | EGreatThanEq() | EEq():
            return check_binary(expr, env, tmap, store)

        case ECall():
            return check_call(expr, env, tmap, store)

        case _:
            unsupported(expr)


# --- Param -----------------------------------------------------------


def check_param(param, tmap, store):
    """A parameter's declared type, recorded under its symbol. Only
    called for a parameter that has one (see infer_call for the rest).
    Param -> {Int: Type} -> Store -> Type"""
    record(tmap, param.sym, param.type, store)
    return param.type


# --- SFunctionDef ----------------------------------------------------


def function_type(node):
    """node's TFunction, if every parameter and the return type are
    annotated. Raises TypeError_ otherwise. SFunctionDef -> TFunction"""
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


def check_function(node, env, tmap, store):
    """Checks a fully annotated def's body against its declared types.
    Always yields unit, whatever the function's own type is: a def is a
    statement. SFunctionDef -> Env -> {Int: Type} -> Store -> (Type, Store)"""
    ftype = function_type(node)
    for param in node.params:
        check_param(param, tmap, store)
    record(tmap, node.sym, ftype, store)

    # env already binds every def of this block (declare_functions); the
    # parameters shadow over that, as analyses.py binds them.
    body_env = env
    for param in node.params:
        body_env = bind(body_env, param.name, param.type)

    if node.expr is not None:
        actual, store = check_expr(node.expr, body_env, tmap, store)
        if not accepts(node.return_type, actual):
            raise TypeError_(
                node.expr.info,
                f"'{node.name}' returns {pprint_type(node.return_type)}, but "
                f"its body has type {pprint_type(actual)}",
            )
        return unit(node.info), store

    # The body's last statement is in tail position; check_stmt already
    # answers what it supplies, by return or by value (PYKING.md).
    supplied, store = check_stmts(
        node.body, body_env, tmap, node.return_type, None, store
    )
    if accepts(node.return_type, supplied):
        return unit(node.info), store
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


# --- inference -------------------------------------------------------
#
# An unannotated function is checked the first time something calls it,
# in the environment it was written in, with parameters taken from that
# call. See docs/type_inference.md.


def infer_call(func_type, params, call, tmap, store):
    """The result type of calling an unannotated function with these
    argument types, checking its body the first time and remembering the
    result afterward. TFunction -> [Type] -> Expr -> {Int: Type} -> Store
    -> (Type, Store)"""
    match func_type:
        case TFunction(_, _, declared, _, tmsym, SFunctionDef() as node):
            pass
        case _:
            unsupported(call)

    match recall(store, tmsym, params):
        case Use() as use:
            # A call that reuses an answer went through everything that
            # answer was based on, so whatever inference is waiting on
            # this one learns it too.
            instance = instance_at(store, use)
            return instance.result, noting(store, (use,) + instance.uses)

    if tmsym in store.checking:
        # Its own body is what is being checked: the one thing that
        # cannot answer this question yet.
        raise _Recursive(node, call.info, store)

    # The environment the function was *written* in -- not this call's.
    # `declare_functions` always records it, and the `def` statement
    # sharpens it to the position; the fallback is for a caller that
    # somehow checked a call before the definition was declared, where
    # the builtins are at least in scope.
    written_in = environment_of(store, tmsym)
    body_env = written_in if written_in is not None else builtin_env()
    for param, type_ in zip(node.params, params):
        body_env = bind(body_env, param.name, type_)

    # The inner store is this store in a fresh frame, with this
    # definition marked as being checked. Everything the check goes
    # through is gathered in that frame, which is what lets this call say
    # afterwards what it made of a function it was given.
    inner = checking_now(with_frame(store, Frame()), tmsym)
    try:
        result, inner = infer_body(node, body_env, params, declared, tmap, inner)
    except _Recursive as signal:
        if signal.definition.sym != tmsym:
            # Some *other* function in the cycle is what nothing could
            # type. Only the inference waiting on that one can say
            # whether it is a problem -- in a cycle of three, the `if`
            # that rescues it may be two calls further out.
            raise
        raise TypeError_(
            node.info,
            f"cannot work out what '{node.name}' returns: every way through "
            f"its body calls it again. Annotate its return type, or return a "
            f"value on some path that does not recurse",
        ) from None

    # The instance is recorded twice over: the parameters as they were
    # passed, which is what a later call is matched against, and the same
    # call with what it made of them, which is what anyone reading the
    # function's type is shown. An argument that was itself a function
    # nobody had worked out yet is the case where the two differ -- and
    # reporting what *this* call went through is what keeps its report
    # about this call rather than about every use of that argument
    # anywhere.
    reported = [reported_type(type_, inner) for type_ in params]
    instance = Instance(
        params,
        result,
        TFunction(node.info, reported, resolved(result, inner)),
        inner.frame.uses,
    )
    # Keep what the inner check found out; go back to the caller's
    # context. Then remember this call, and note that the caller went
    # through it.
    store = learned(store, inner)
    use = Use(tmsym, len(instances_of(store, tmsym)))
    store = noting(remembering(store, tmsym, instance), (use,) + instance.uses)

    record(tmap, node.sym, TFunction(node.info, reported, result), store)
    for param, type_ in zip(node.params, reported):
        record(tmap, param.sym, type_, store)
    return result, store


def recall(store, tmsym, params):
    """The Use recording what was worked out last time this function was
    called with these parameter types, or None. Compares with
    same_instance, not same_type (docs/type_inference.md, section 9).
    Store -> Int -> [Type] -> Use?"""
    for index, instance in enumerate(instances_of(store, tmsym)):
        if len(instance.params) == len(params) and all(
            map(same_instance, instance.params, params)
        ):
            return Use(tmsym, index)
    return None


def same_instance(a, b):
    """Whether two types are the same thing to have been passed:
    same_type, except a function not yet worked out is only ever the
    same as itself (docs/type_inference.md, section 9). Type -> Type ->
    Bool"""
    match (a, b):
        case (TFunction(_, mine, my_result, _, my_sym, SFunctionDef()),
              TFunction(_, theirs, their_result, _, their_sym, SFunctionDef())):
            return (my_sym == their_sym
                    and len(mine) == len(theirs)
                    and all(map(same_instance, mine, theirs))
                    and same_instance(my_result, their_result))
        case (TFunction(_, _, _, _, _, SFunctionDef()), TFunction()) \
                | (TFunction(), TFunction(_, _, _, _, _, SFunctionDef())):
            # One is still a promise and the other is not: whatever their
            # shapes, they are not the same thing to have been passed.
            return False
        case (TOr(_, mine), TOr(_, theirs)):
            return (len(mine) == len(theirs)
                    and all(any(same_instance(x, y) for y in theirs) for x in mine))
    return same_type(a, b)


def reported_type(type_, store):
    """What an argument turned out to be at this call, not overall
    (docs/type_inference.md, section 9). Type -> Store -> Type"""
    match type_:
        case TFunction(_, _, _, _, tmsym, SFunctionDef()):
            gone_through = [
                instance_at(store, use)
                for use in store.frame.uses
                if use.tmsym == tmsym
            ]
            if gone_through:
                return merge([
                    resolved(instance.reported, store) for instance in gone_through
                ])
    return resolved(type_, store)


def infer_body(node, body_env, params, declared, tmap, store):
    """What a function's body supplies, when the def did not say. A
    recursive, unannotated one is checked twice, per
    docs/type_inference.md ("Recursion, and why there are two traces").
    SFunctionDef -> Env -> [Type] -> Type? -> {Int: Type} -> Store ->
    (Type, Store)"""
    if known(declared):
        env = bind(body_env, node.name, TFunction(node.info, params, declared))
        result, store = supplied_type(node, env, tmap, declared, store)
        if not accepts(declared, result):
            raise TypeError_(
                node.info,
                f"'{node.name}' returns {pprint_type(declared)}, but its body "
                f"has type {pprint_type(result)}",
            )
        return declared, store

    candidate, store = trace(node, body_env, tmap, store)
    known_type = TFunction(node.info, params, candidate)
    return trace(node, bind(body_env, node.name, known_type), tmap, store)


def trace(node, env, tmap, store):
    """One pass over a body with its returns collected: what the
    function supplies, as far as this trace could see (see
    docs/type_inference.md, "Recursion, and why there are two traces").
    SFunctionDef -> Env -> {Int: Type} -> Store -> (Type, Store)"""
    started = with_frame(store, replace(store.frame, returns=()))
    try:
        supplied, ended = supplied_type(node, env, tmap, INFERRING, started)
    except _Recursive as signal:
        match signal.store.frame.returns:
            case ():
                # This trace saw nothing but the recursion. Whether that
                # is a problem is not this function's to decide: an
                # inference further out may be about to rescue it (see
                # `infer_call`).
                raise
            case returns:
                return merge(list(returns)), with_frame(signal.store, store.frame)
    return (merge(list(ended.frame.returns) + [supplied]),
            with_frame(ended, replace(ended.frame, returns=store.frame.returns)))


def supplied_type(node, env, tmap, return_type, store):
    """What a function body supplies: its = expr form's expression, or
    its last statement's value. SFunctionDef -> Env -> {Int: Type} ->
    Type? -> Store -> (Type, Store)"""
    if node.expr is not None:
        return check_expr(node.expr, env, tmap, store)
    # A body is checked with no enclosing loop: a `break` may not cross
    # a `def`, so one written here belongs to nothing.
    return check_stmts(node.body, env, tmap, return_type, None, store)


def merge(types):
    """One type covering all of types: that type when they agree, a TOr
    of the distinct ones (flattened, function types kept as whole
    alternatives) when they do not. A TNever is dropped -- a way through
    that never arrives says nothing about what does -- unless that is
    all there is. See docs/type_inference.md, "The mistake that made
    this page necessary". At least one type is required.
    [Type] -> Type"""
    arriving = [type_ for type_ in types if not isinstance(type_, TNever)]
    if not arriving:
        return types[0]
    types = arriving
    match distinct_types([one for type_ in types for one in alternatives_of(type_)]):
        case [only]:
            return only
        case alternatives:
            return TOr(alternatives[0].info, alternatives)


def alternatives_of(type_):
    """A type's alternatives: a TOr's, flattened; any other type, alone.
    Type -> [Type]"""
    match type_:
        case TOr(_, alternatives):
            return [one for alternative in alternatives for one in alternatives_of(alternative)]
    return [type_]


def distinct_types(types):
    """types with later duplicates (by same_type) dropped, order
    preserved. [Type] -> [Type]"""
    match types:
        case []:
            return []
        case [first, *rest]:
            return [first] + distinct_types(
                [type_ for type_ in rest if not same_type(first, type_)]
            )


def record(tmap, sym, type_, store):
    """Records a node's type in tmap, merging with what is already there
    for a node checked more than once (an unannotated function checked
    at several argument types). The one place in this module that
    mutates rather than returns a new value, since tmap is the pass's
    result. {Int: Type} -> Int -> Type -> Store -> ()"""
    resolved_type = resolved(type_, store)
    existing = tmap.get(sym)
    tmap[sym] = resolved_type if existing is None else merge([existing, resolved_type])


def resolved(type_, store, seen=()):
    """type_ with every not-yet-called function inside it replaced by
    what it was worked out to be. seen guards against a function whose
    own type mentions it. Type -> Store -> (Int,) -> Type"""
    match type_:
        case TOr(_, alternatives):
            return merge([resolved(one, store, seen) for one in alternatives])
        case TFunction(_, _, _, _, tmsym, SFunctionDef()) if (
            tmsym not in seen and instances_of(store, tmsym)
        ):
            return merge([
                resolved(instance.reported, store, seen + (tmsym,))
                for instance in instances_of(store, tmsym)
            ])
        case TFunction(info, params, result, _, _, _):
            return TFunction(
                info,
                [resolved(param, store, seen) for param in params],
                resolved(result, store, seen),
            )
    return type_


def accepts(expected, actual):
    """Whether a value of type actual may be used where expected is
    wanted -- same_type, plus TOr on either side and TNever below
    everything. No other subtyping exists in Pyking.
    Type -> Type -> Bool"""
    match (expected, actual):
        case (_, TNever()):
            # No value ever arrives, so there is none to be wrong.
            return True
        case (_, TOr(_, alternatives)):
            return all(accepts(expected, alternative) for alternative in alternatives)
        case (TOr(_, alternatives), _):
            return any(accepts(alternative, actual) for alternative in alternatives)
    return same_type(expected, actual)


# --- ECall -----------------------------------------------------------


def check_call(call, env, tmap, store):
    """A call's type: its function's result, once the arguments are
    checked against its parameters. Also where an unannotated function
    is deferred and checked (see infer_call). ECall -> Env -> {Int:
    Type} -> Store -> (Type, Store)"""
    match call.func:
        case EVar(_, name, _) if isinstance(env.get(name), Builtin):
            return check_builtin_call(name, call, env, tmap, store)
    func_type, store = check_expr(call.func, env, tmap, store)
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
    params, store = check_arguments(call.args, func_type.params, env, tmap, store)
    match func_type:
        case TFunction(_, _, result, _, _, None):
            # A function whose type was written down: the call has its
            # declared result, as it always did.
            return result, store
        case TFunction():
            return infer_call(func_type, params, call, tmap, store)


def check_arguments(args, declared, env, tmap, store, position=1):
    """Checks each argument in turn (left to right, so the first mistake
    is the one reported) and returns the parameter types for this call.
    [Expr] -> [Type] -> Env -> {Int: Type} -> Store -> Int -> ([Type],
    Store)"""
    match (args, declared):
        case ([], _):
            return [], store
        case ([arg, *rest], [expected, *rest_declared]):
            actual, store = check_expr(arg, env, tmap, store)
            param = argument_type(expected, actual, arg, position)
            params, store = check_arguments(
                rest, rest_declared, env, tmap, store, position + 1
            )
            return [param] + params, store


def argument_type(expected, actual, arg, position):
    """What one parameter is for this call: expected where the def
    annotated it, actual otherwise. Raises TypeError_ on a mismatch.
    Type -> Type -> Expr -> Int -> Type"""
    match (expected, actual):
        case (TUnknown(), _):
            return actual
        case (TFunction(), TFunction()):
            check_compatible(expected, actual, position, arg)
            return actual
    if not accepts(expected, actual):
        raise argument_error(position, actual, expected, arg)
    return expected


def argument_error(position, actual, expected, arg):
    """The TypeError_ for an argument that does not match the declared
    parameter type. Int -> Type -> Type -> Expr -> TypeError_"""
    return TypeError_(
        arg.info,
        f"argument {position} has type {pprint_type(actual)}, but "
        f"{pprint_type(expected)} was expected",
    )


def check_compatible(expected, actual, position, arg):
    """Checks that two function types agree on everything both know
    (TUnknown agrees with anything); raises TypeError_ if not. Type ->
    Type -> Int -> Expr -> ()"""
    match (expected, actual):
        case (TFunction(_, mine, my_result, _, _, _),
              TFunction(_, theirs, their_result, _, _, _)):
            pass
    if len(mine) != len(theirs):
        raise TypeError_(
            arg.info,
            f"argument {position} is a function of {len(theirs)} "
            f"argument{'' if len(theirs) == 1 else 's'}, but one of "
            f"{len(mine)} was expected",
        )
    for my_param, their_param in zip(mine, theirs):
        if known(my_param) and known(their_param) \
                and not accepts(my_param, their_param) \
                and not accepts(their_param, my_param):
            raise argument_error(position, actual, expected, arg)
    if known(my_result) and known(their_result) \
            and not accepts(my_result, their_result):
        raise argument_error(position, actual, expected, arg)


def known(type_):
    """Whether anything has decided this type yet (not TUnknown). Type ->
    Bool"""
    match type_:
        case TUnknown():
            return False
    return True


def check_builtin_call(name, call, env, tmap, store):
    """A call to print, str, len or range, checked by its own rule since
    none of them has a TFunction type (PYKING.md, "Builtins"). String ->
    ECall -> Env -> {Int: Type} -> Store -> (Type, Store)"""
    args, store = check_each(call.args, env, tmap, store)

    match (name, args):
        case ("print", _):
            return unit(call.info), store

        case ("str", [value]):
            check_builtin_arity(name, call, 1, 1)
            if not every(value, (TInt, TString, TBool)):
                raise builtin_argument_error(
                    name, call.args[0], value, "Int, String or Bool"
                )
            return TString(call.info), store

        case ("len", [value]):
            check_builtin_arity(name, call, 1, 1)
            if not every(value, (TList, TString)):
                raise builtin_argument_error(
                    name, call.args[0], value, "a list or a String"
                )
            return TInt(call.info), store

        case ("range", _):
            check_builtin_arity(name, call, 1, 3)
            for argument, actual in zip(call.args, args):
                if not every(actual, (TInt,)):
                    raise builtin_argument_error(name, argument, actual, "Int")
            return TList(call.info, TInt(call.info)), store

    # A builtin with the wrong number of arguments reaches here for
    # `str` and `len`, whose cases ask for exactly one; the arity check
    # says which and how many.
    check_builtin_arity(name, call, 1, 1)
    unsupported(call)


def check_each(exprs, env, tmap, store):
    """Checks every expression left to right (Pyking's evaluation order)
    and returns their types. [Expr] -> Env -> {Int: Type} -> Store ->
    ([Type], Store)"""
    match exprs:
        case []:
            return [], store
        case [first, *rest]:
            type_, store = check_expr(first, env, tmap, store)
            types, store = check_each(rest, env, tmap, store)
            return [type_] + types, store


def every(type_, kinds):
    """Whether type_ is one of kinds, or (for a TOr) every alternative
    is. Type -> (type,) -> Bool"""
    return all(isinstance(one, kinds) for one in alternatives_of(type_))


def check_builtin_arity(name, call, low, high):
    """Raises TypeError_ if call does not pass between low and high
    arguments. String -> ECall -> Int -> Int -> ()"""
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
    """The TypeError_ for a builtin argument of the wrong type. String ->
    Expr -> Type -> String -> TypeError_"""
    return TypeError_(
        argument.info,
        f"'{name}' cannot be applied to {pprint_type(actual)}; it accepts "
        f"{accepted}",
    )


# --- operators -------------------------------------------------------

# node class -> (spelling, [(operand type, result type), ...]).
# PYKING.md, "Operators", is the table this implements.
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


def check_binary(expr, env, tmap, store):
    """The type of a binary operator application, from OPERATORS.
    Expr -> Env -> {Int: Type} -> Store -> (Type, Store)"""
    spelling, signatures = OPERATORS[type(expr)]
    left_type, store = check_expr(expr.left, env, tmap, store)
    right_type, store = check_expr(expr.right, env, tmap, store)
    for operand, result in signatures:
        if isinstance(left_type, operand) and isinstance(right_type, operand):
            return result(expr.info), store
    # A signature's operand is a class here; instantiate it to print it.
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
    """Checks a binding's annotation, if any, against its right-hand
    side's actual type; raises TypeError_ at the annotation on a
    mismatch. Type? -> Type -> ()"""
    if annotation is None or accepts(annotation, actual):
        return
    raise TypeError_(
        annotation.info,
        f"this binding is annotated {pprint_type(annotation)}, but its "
        f"value has type {pprint_type(actual)}",
    )


def same_type(a, b):
    """Whether two types are the same type, structurally -- never a == b,
    since Type nodes are dataclasses whose info and sym also differ.
    Type -> Type -> Bool"""
    match (a, b):
        case (TInt(), TInt()) | (TString(), TString()) | (TBool(), TBool()):
            return True
        case (TUnknown(), TUnknown()) | (TNever(), TNever()):
            # Two types nothing has decided are the same lack of a
            # decision -- which is what makes an incomplete function type
            # equal to itself, and so findable in `recall`'s cache. Two
            # `TNever`s are the same non-arrival for the same reason.
            return True
        case (TList(_, x), TList(_, y)):
            return same_type(x, y)
        case (TTuple(_, xs), TTuple(_, ys)):
            return len(xs) == len(ys) and all(map(same_type, xs, ys))
        case (TOr(_, xs), TOr(_, ys)):
            # Alternatives are a set, not a sequence: `Int | String` and
            # `String | Int` are one type.
            return (len(xs) == len(ys)
                    and all(any(same_type(x, y) for y in ys) for x in xs))
        case (TFunction(_, ps, r), TFunction(_, qs, s)):
            # A function *is* its parameters and its result. The other
            # three fields -- the symbol, the definition it came from,
            # and the body still to be checked -- say where a type was
            # written and what is left to do about it, neither of which
            # is part of what it means (see src/syntax.py).
            return (len(ps) == len(qs) and all(map(same_type, ps, qs))
                    and same_type(r, s))
        case _:
            return False


def unit(info):
    """The unit type, (), an empty tuple type. Info -> TTuple"""
    return TTuple(info, [])


def is_unit(t):
    """Whether t is the unit type. Type -> Bool"""
    return isinstance(t, TTuple) and not t.elements


# --- Env -------------------------------------------------------------


def bind(env, name, type_):
    """env with name bound to type_ (or to no known type, if None). A
    fresh dict, so shadowing works by construction. Env -> String ->
    Type? -> Env"""
    return {**env, name: type_}
