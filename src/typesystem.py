"""

The type checker is is written in a functional style, and type checks
a program. It uses a call-based type inference approach (not
constraint-based as in Hindley-Milner).

Function `type_check(stmts:[Stmt]) -> TMap` is the main type checking
function that takes a list of statements as input.
If type checking fails, it raises an exception error, otherwise it returns
a type map, `TMap = {Int: Type}`, i.e., a mapping from symbols
(represented as integers) to types.


Key functions:
    type_check(stmts) -- checks a whole program; returns tmap.
    check_stmt(stmt, env, tmap, return_type, acc_type, store) -- checks
        one statement.
    check_expr(expr, env, tmap, store) -- checks one expression.
    same_type(a, b) / accepts(expected, actual) -- type comparison.



Data structures:

* `env : {String: Type}`, mapping a name in the environment to a
   option type.

    TypeError_ -- a type-check failure, with the source position.
    Instance / Use / Frame / Store -- inference's working state (see
        docs/type_inference.md).
    Inferring -- marks a return type being worked out.
    Exit -- one way out of the loop being checked: a break and its type.

See the Signatures block below for every function's type.
"""

from dataclasses import dataclass, replace

from analyses import AnalysisError, BUILTINS, block_functions
from lexer import Info
from syntax import (
    pprint_type, pprint_type_nested,
    EInt, EString, EBool, EVar, EAdd, EConcat, ESub, EMul, ECall, EIf, ETuple,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq,
    SLet, SLetStmt, SExprStmt, SIf, SReturn, SReturnStmt, SFunctionDef,
    SFunctionSig, SMatch,
    ENeg, EList, EListComp, CompFor, CompIf,
    PInt, PString, PBool, PWildcard, PCapture, PTuple, PList, ListRest,
    SLoop, SBreak, SContinue,
    Type, TInt, TString, TBool, TList, TTuple, TFunction, TOr, TUnknown, TNever,
    TBuiltin, TVar, TForall,
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
#     Env   = {String: Type}      the names in scope, and their types;
#                                 a name not in it is not in scope
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
# The `Type?` beside it (`acc_type`) is the same idea for the same
# reason: what the loop a `break`/`continue` written here belongs to
# carries, absent where there is no such loop. A bare `loop:` carries
# unit, so the two are not the same answer. A `def` inside a loop body
# passes `None` for it, since a `break` may not cross one
# (src/parser.py enforces that, so this is only saying the same thing
# again where it would matter).
#
#     val type_check         : [Stmt] -> TMap
#     val check_stmts        : [Stmt] -> Env -> TMap -> Type? -> Type?
#                              -> Store -> (Type, Store)
#     val check_stmt         : Stmt -> Env -> TMap -> Type? -> Type?
#                              -> Store -> (Type, Env, Store)
#     val check_expr         : Expr -> Env -> TMap -> Store -> (Type, Store)
#     val check_param        : Param -> TMap -> Store -> Type
#     val check_function     : SFunctionDef -> Env -> TMap -> Store
#                              -> (Type, Store)
#     val check_call         : ECall -> Env -> TMap -> Store -> (Type, Store)
#     val check_binary       : Expr -> Env -> TMap -> Store -> (Type, Store)
#     val alternative        : Expr -> Type -> Type -> String
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


# `env` maps a name to a Type, and to nothing else: a name it does not
# hold is a name that is not in scope. The four host operations are in
# it under TBuiltin, which is a type like any other here -- see
# check_builtin_call, which is what a call to one is checked by.

# The source position a TBuiltin carries, since a builtin is written in
# no file.
BUILTIN_INFO = Info("<builtin>", 1, 0, 1, 0)


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
class Exit:
    """One way out of the loop being checked. Fields: info: Info (where
    the `break` is written), type: Type (what it gives)."""
    info: Info
    type: Type


@dataclass(frozen=True)
class Frame:
    """What the current inference has gathered, and what the innermost
    loop has been broken with. Fields: uses: (Use,), returns: (Type,),
    breaks: (Exit,).
      TODO: explain better how Frame is used.
    """
    uses: tuple = ()
    returns: tuple = ()
    breaks: tuple = ()


@dataclass(frozen=True)
class Store:
    """
    The store is used as an immutable state that is threaded through
    the type checker.
    environments: {Int: Env}. Maps a symbol for a node to an environment.
       This is used during call-based inference. When checking the function
       during a call, the checker needs to look up the environment for
       the specific function.
    instances: {Int: (Instance,)} This is a cache that is important
       for handling mutal recursion, so it terminates. TODO: explain more.
    checking: {Int} A set of symbols that are being checked right now.
       Avoids goint into an infinite loop.
    frame: Frame. Contains information about the inner frame, including
      information about returns and breaks.
    signatures: {Int: Type}. A `def`'s type where the source wrote it on
      a line of its own (`def foo : (a) -> a`) instead of on the header.
      Keyed by the definition's symbol, filled by declare_functions from
      the block both statements are in. Unlike the rest of the store this
      is *given* rather than worked out, and it is here so that reaching
      it costs no new parameter on every function that might need it.
    """
    environments: dict
    instances: dict
    checking: frozenset
    frame: Frame
    signatures: dict


def empty_store():
    """The store a program starts checking in. () -> Store"""
    return Store({}, {}, frozenset(), Frame(), {})


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


def with_signature(store, sym, type_):
    """store recording the type a `def name : type` line gave the
    definition sym. Store -> Int -> Type -> Store"""
    return replace(store, signatures={**store.signatures, sym: type_})


def with_frame(store, frame):
    """store gathering into a different frame. Store -> Frame -> Store"""
    return replace(store, frame=frame)


def returning(store, type_):
    """store whose frame has seen a return of type_.
    Store -> Type -> Store"""
    return with_frame(store, replace(store.frame, returns=store.frame.returns + (type_,)))


def breaking(store, info, type_):
    """store whose frame has seen a `break` at info giving type_ -- what
    the loop being checked is worth, one way out at a time.
    Store -> Info -> Type -> Store"""
    return with_frame(
        store, replace(store.frame, breaks=store.frame.breaks + (Exit(info, type_),))
    )


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
    analyses.BUILTINS, at its TBuiltin type. Its own function so
    src/repl.py can reuse it when checking a session one entry at a
    time. () -> Env"""
    return {name: TBuiltin(BUILTIN_INFO, name) for name in BUILTINS}


# --- [Stmt] ----------------------------------------------------------


def signature_of(node, store):
    """The type a `def name : type` line gave this definition, already
    quantified, or None where the source wrote none.
    SFunctionDef -> Store -> Type?"""
    return store.signatures.get(node.sym)


def fully_annotated(node, store):
    """ Returns true if a function definition has the complete type
    annoted, either by a signature line of its own or by an annotation
    on every parameter and the return type.
    SFunctionDef -> Store -> Bool"""
    if signature_of(node, store) is not None:
        return True
    return node.return_type is not None and all(p.type is not None for p in node.params)


# --- type variables --------------------------------------------------
#
# A written annotation may name types it does not fix: `(a) -> a` is a
# function from anything to that same thing. Every variable a written
# type leaves free is bound by one `all` at its outermost level, so
# `(a) -> a` and `all a. (a) -> a` are one type and neither prints the
# quantifier. An `all` written *inside* a type is first-class
# polymorphism and stays where it was written.
#
# Nothing here solves constraints. A body is checked with its variables
# rigid -- a TVar is `same_type` only with itself, which is exactly what
# "the caller chose this, not you" means -- and a call matches the
# declared parameters against the arguments one way (`match_type`),
# binding each variable the first time it is met. See docs/typesystem.md.


def free_vars(type_, bound=frozenset()):
    """The variables type_ leaves free, in the order written and without
    repeats. Type -> {String} -> [String]"""
    found = []

    def walk(t, bound):
        match t:
            case TVar(_, name):
                if name not in bound and name not in found:
                    found.append(name)
            case TForall(_, vars, body):
                walk(body, bound | set(vars))
            case TList(_, element):
                walk(element, bound)
            case TTuple(_, elements) | TOr(_, elements):
                for element in elements:
                    walk(element, bound)
            case TFunction(_, params, result, _, _, _):
                for param in params:
                    walk(param, bound)
                walk(result, bound)

    walk(type_, bound)
    return found


def has_or(type_):
    """Whether a `|` appears anywhere in type_. Type -> Bool"""
    match type_:
        case TOr():
            return True
        case TForall(_, _, body):
            return has_or(body)
        case TList(_, element):
            return has_or(element)
        case TTuple(_, elements):
            return any(has_or(element) for element in elements)
        case TFunction(_, params, result, _, _, _):
            return any(has_or(param) for param in params) or has_or(result)
    return False


def generalize(type_, info):
    """A written type with its free variables quantified, or the type
    itself when it has none. Refuses a type that mixes variables with
    `|`: an alternative is what the checker *inferred* a name to be and
    a variable is what a caller gets to choose, and no rule here relates
    the two. Type -> Info -> Type"""
    variables = free_vars(type_)
    if not variables:
        return type_
    if has_or(type_):
        raise TypeError_(
            info,
            f"this type has both type variables ({', '.join(variables)}) and "
            f"a `|` alternative; a signature may use one or the other, since "
            f"an alternative says what a name was inferred to be and a "
            f"variable says the caller chooses",
        )
    return TForall(type_.info, variables, type_)


def instantiated(type_):
    """A type's quantified variables and its body, as ([String], Type);
    a type with no `all` on it answers ([], itself).
    Type -> ([String], Type)"""
    match type_:
        case TForall(_, vars, body):
            return list(vars), body
    return [], type_


def substitute(type_, mapping):
    """type_ with each variable `mapping` names replaced. A nested `all`
    shadows what it binds. Type -> {String: Type} -> Type"""
    match type_:
        case TVar(_, name):
            return mapping.get(name, type_)
        case TForall(info, vars, body, sym):
            inner = {k: v for k, v in mapping.items() if k not in vars}
            return TForall(info, vars, substitute(body, inner), sym)
        case TList(info, element, sym):
            return TList(info, substitute(element, mapping), sym)
        case TTuple(info, elements, sym):
            return TTuple(info, [substitute(e, mapping) for e in elements], sym)
        case TOr(info, alternatives, sym):
            return TOr(info, [substitute(a, mapping) for a in alternatives], sym)
        case TFunction(info, params, result, sym, tmsym, definition):
            return TFunction(
                info,
                [substitute(p, mapping) for p in params],
                substitute(result, mapping),
                sym, tmsym, definition,
            )
    return type_


def canonical(type_, vars):
    """type_ with the variables `vars` renamed to their positions, so
    that two types differing only in the names they bind compare equal.
    Type -> [String] -> Type"""
    info = type_.info
    return substitute(type_, {name: TVar(info, f"%{i}")
                              for i, name in enumerate(vars)})


def declared_type(node, store):
    """Returns the type a def function, either its annotated types or
    TUnknown for the missing parts. The reason for having option types form
    parameters, and not TUnknown directy is to separate

    SFunctionDef -> Store -> Type"""
    if fully_annotated(node, store):
        # Return the type, since it is fully annotated
        return function_type(node, store)
    return TFunction(
        # Add TUnknown for the missing parts
        node.info,
        [p.type if p.type is not None else TUnknown(p.info) for p in node.params],
        node.return_type if node.return_type is not None else TUnknown(node.info),
        tmsym=node.sym,
        definition=node,
    )

def declare_functions(stmts, env, store):
    """
    Goes from all declared functions within a list of statements.
     Not recursive: a def inside a branch
    is declared when that branch's block is checked.
    [Stmt] -> Env -> Store -> (Env, Store)"""
    # Returns a list of functinon definitions, SFunctionDef,
    # as a list of statments.
    defined = block_functions(stmts)
    store = declare_signatures(stmts, defined, store)
    functions = list(defined.values())
    for function in functions:
        # Add envinonment bindings for function definitions
        env = bind(env, function.name, declared_type(function, store))
    for function in functions:
        # For all the functions, store this environment inside the
        # store. Enables recursive lookup.
        if not fully_annotated(function, store):
            store = with_environment(store, function.sym, env)
    return env, store


def declare_signatures(stmts, defined, store):
    """Pairs each `def name : type` line of a block with the definition
    of that name in the same block, and records the type it gives it.
    Refuses a signature that names no definition here, a second one for
    one definition, and one whose definition also annotates itself --
    a `def` says its type in one place or the other, never both.
    [Stmt] -> {String: SFunctionDef} -> Store -> Store"""
    seen = {}
    for statement in stmts:
        if not isinstance(statement, SFunctionSig):
            continue
        node = defined.get(statement.name)
        if node is None:
            raise TypeError_(
                statement.info,
                f"there is no 'def {statement.name}' in this block for this "
                f"signature to describe",
            )
        if statement.name in seen:
            raise TypeError_(
                statement.info,
                f"'{statement.name}' already has a signature in this block",
            )
        seen[statement.name] = statement
        written = [p.name for p in node.params if p.type is not None]
        if written or node.return_type is not None:
            raise TypeError_(
                node.info,
                f"'{node.name}' has a signature of its own, so its "
                f"definition writes no annotations; remove the ones on "
                f"{', '.join(written) if written else 'its return type'}",
            )
        type_ = generalize(statement.type, statement.info)
        _, written_type = instantiated(type_)
        if not isinstance(written_type, TFunction):
            raise TypeError_(
                statement.info,
                f"the signature of '{statement.name}' is "
                f"{pprint_type(type_)}, which is not a function type",
            )
        if len(written_type.params) != len(node.params):
            raise TypeError_(
                statement.info,
                f"this signature gives '{statement.name}' "
                f"{len(written_type.params)} parameter"
                f"{'' if len(written_type.params) == 1 else 's'}, but its "
                f"definition takes {len(node.params)}",
            )
        store = with_signature(store, node.sym, type_)
    return store





def check_stmts(stmts, env, tmap, return_type, acc_type, store):
    """
    Function check_stmts checks a list of statements, either at the top
    level, or when checking a block.
       env: Mapping from strings to types
       tmap: mutable map from int symbols to types
       return_type: the type of the return function, None if not inside
         a function. Used when checking return statements.
       acc_type: the type of the accumulator in a loop statement. If
         not inside a loop, then None. Used when checking 'continue'
         statements.
       store:

    [Stmt] -> Env -> {Int: Type} -> Type? -> Type? -> Store
    -> (Type, Store)"""
    # update env with name to type bindings for all function definitions (def)
    # updates the store with new environments for functions. This
    # enables mutual recursion
    env, store = declare_functions(stmts, env, store)
    # res_type is the resulting type from the last statement
    # Starts with the unit type, if an empty statement list
    res_type = unit(stmts[0].info if stmts else Info("<empty>", 1, 0, 1, 0))
    for statement in stmts:
        res_type, env, store = check_stmt(
            statement, env, tmap, return_type, acc_type, store
        )
    return res_type, store


# --- Stmt ------------------------------------------------------------


def check_stmt(statement, env, tmap, return_type, acc_type, store):
    """ Type checking each statement. Returns the type of the statement,
    as well as the extended environment (if, e.g., a name binding =.
    Stmt -> Env -> {Int: Type} -> Type? -> Type? -> Store
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
            require_total(stmt, "bound to a name")
            bound_type, _, store = check_stmt(
                stmt, env, tmap, return_type, acc_type, store
            )
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
                then_body, env, tmap, return_type, acc_type, store
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
                else_body, env, tmap, return_type, acc_type, then_store
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
            both = agree(then_type, else_type)
            if both is None:
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
            return both, env, else_store

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
            require_total(stmt, "returned")
            actual, _, store = check_stmt(
                stmt, env, tmap, return_type, acc_type, store
            )
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
                body, body_env, tmap, return_type, accumulator,
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
            # A loop is worth what it breaks with, and its `break`s
            # have to agree on one type -- the same rule the two
            # branches of an `if` obey, and for the same reason: one
            # value leaves here, so there is one type for it. With no
            # `break` at all it cannot finish, so it is worth nothing
            # anything can be wrong about -- which is what lets a
            # function whose body is such a loop honour any return type.
            ways_out = store.frame.breaks
            store = with_frame(store, outer)
            return loop_value(ways_out, info), env, store

        case SBreak(info, expr, _):
            # A `break` says what the loop is *worth*, which is a
            # different question from what it carries: the operand is
            # collected rather than checked against the accumulator.
            # What the statement supplies is the accumulator all the
            # same -- it never falls through, so nothing can observe
            # that answer, and giving it the one its neighbours give is
            # what lets a branch that breaks sit beside one that ends in
            # the next accumulator.
            if acc_type is None:
                raise TypeError_(info, "'break' outside a loop")
            if expr is None:
                return acc_type, env, breaking(store, info, acc_type)
            actual, store = check_expr(expr, env, tmap, store)
            return acc_type, env, breaking(store, info, actual)

        case SContinue(info, expr, _):
            # `continue` is the other half: it says what the next turn
            # carries, so its operand *is* the accumulator. A bare one
            # goes round with the accumulator unchanged, which is that
            # type whatever it is and so needs no check.
            if acc_type is None:
                raise TypeError_(info, "'continue' outside a loop")
            if expr is None:
                return acc_type, env, store
            actual, store = check_expr(expr, env, tmap, store)
            if not accepts(acc_type, actual):
                raise TypeError_(expr.info, continue_error(acc_type, actual))
            return acc_type, env, store

        case SMatch(info, subject, cases, _):
            # Every arm is a branch, and they must agree on one type the
            # way an `if`'s two do -- one value leaves a `match` however
            # many ways in there are. Each arm is checked in the
            # environment its own pattern binds, and against what the
            # arms before it worked out (`then_store`'s rule, for the
            # same reason).
            subject_type, store = check_expr(subject, env, tmap, store)
            yielded, signalled = None, None
            for case_clause in cases:
                inner = check_pattern(
                    case_clause.pattern, subject_type, env, tmap
                )
                arm_type, arm_store, signal = try_branch(
                    case_clause.body, inner, tmap, return_type, acc_type, store
                )
                if signal is not None:
                    signalled = signal
                    continue
                store = arm_store
                if yielded is None:
                    yielded = arm_type
                else:
                    both = agree(yielded, arm_type)
                    if both is None:
                        raise TypeError_(
                            case_clause.info,
                            f"the arms of this 'match' have different types: "
                            f"{pprint_type(yielded)} and "
                            f"{pprint_type(arm_type)}",
                        )
                    check_not_conflated(yielded, arm_type, case_clause.info)
                    yielded = both
            if yielded is None:
                # Every arm met the recursion being worked out, or there
                # are no arms at all; the first is the `if` rule again.
                if signalled is not None:
                    raise signalled
                return unit(info), env, store
            # A `match` may match nothing at all (PYKING.md), so as a
            # statement it supplies no value of its own -- only the value
            # form, which `covers` has held to being total, does.
            record(tmap, statement.sym, yielded, store)
            return (yielded if covers([c.pattern for c in cases])
                    else unit(info)), env, store

        case SFunctionSig(info, _, _, _):
            # The signature was paired with its definition before this
            # block was checked (declare_signatures); on its own it says
            # nothing and produces nothing.
            return unit(info), env, store

        case SFunctionDef(info, name, _, _, _, sym):
            if fully_annotated(statement, store):
                # Checked against its annotations here; visible under its
                # own name only to the statements that follow.
                supplied, store = check_function(statement, env, tmap, store)
                return supplied, bind(env, name, function_type(statement, store)), store
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


def continue_error(acc_type, actual):
    """The message for a `continue` whose operand is not the
    accumulator. A loop carrying unit is one written with no
    accumulator, so the message says that rather than naming `()`.
    Type -> Type -> String"""
    if is_unit(acc_type):
        return "this loop carries no accumulator, so its 'continue' takes no value"
    return (f"this loop carries {pprint_type(acc_type)}, but this 'continue' "
            f"gives {pprint_type(actual)}")


def loop_value(ways_out, info):
    """What a loop is worth: what its `break`s give, which must all be
    the same type. A loop with no `break` never finishes, so it is worth
    TNever. (Exit,) -> Info -> Type"""
    match list(ways_out):
        case []:
            return TNever(info)
        case [first, *rest]:
            for other in rest:
                if not same_type(first.type, other.type):
                    raise TypeError_(
                        other.info,
                        f"this loop is worth {pprint_type(first.type)}, from "
                        f"an earlier 'break', but this 'break' gives "
                        f"{pprint_type(other.type)}",
                    )
                check_not_conflated(first.type, other.type, other.info)
            return first.type


def try_expr(expr, env, tmap, store):
    """Try to get the type of an expression. Either returns the type
    or it found a recursion and returns None
    Expr -> Env -> {Int: Type} -> Store -> (Type?, Store, _Recursive?)"""
    try:
        type_, store = check_expr(expr, env, tmap, store)
        return type_, store, None
    except _Recursive as signal:
        return None, store, signal


def try_branch(body, env, tmap, return_type, acc_type, store):
    """One branch of an if statement, as (type, store, signal). On a
    signal, store is the one the branch started from (its own work was
    provisional).
    [Stmt] -> Env -> {Int: Type} -> Type? -> Type? -> Store
    -> (Type?, Store, _Recursive?)"""
    try:
        type_, store = check_stmts(body, env, tmap, return_type, acc_type, store)
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
    """Get the type of one expression and  record it in tmap under its symbol
    Expr -> Env -> {Int: Type} -> Store -> (Type, Store)"""
    type_, store = expr_type(expr, env, tmap, store)
    record(tmap, expr.sym, type_, store)
    return type_, store


def expr_type(expr, env, tmap, store):
    """Type check expression, without recroding in tmap.
    Returns the type of the expression.
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
                case TBuiltin(_, builtin):
                    raise TypeError_(
                        info,
                        f"'{builtin}' is a builtin operation: it can be called, "
                        f"but not used as a value",
                    )
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
            # Try to type check the then an else branch.
            # A signal if the branch is recursive (does not return a concrete type)
            then_type, then_store, then_signal = try_expr(then_expr, env, tmap, store)
            else_type, else_store, else_signal = try_expr(else_expr, env, tmap, then_store)
            # If both branches are recursive, raise the signal to the next level
            # (Catched as an error if no futher if statements)
            if then_signal is not None and else_signal is not None:
                raise then_signal
            # We have one type in the then_branch. The else branch
            # will be revisited and checked again.
            if then_signal is not None:
                return else_type, else_store
            # We have one type on the else_branch. The then_branch
            # will be vistited and checked again.
            if else_signal is not None:
                return then_type, then_store
            # We have types on both branches. Check if the types matches,
            # raise an error otherwise.
            both = agree(then_type, else_type)
            if both is None:
                raise TypeError_(
                    info,
                    f"the branches of this 'if' have different types: "
                    f"{pprint_type(then_type)} and {pprint_type(else_type)}",
                )
            # Raises a type error if they both carry a function defintion
            # and they represent different functions.
            # TODO: investigate and explain why this is needed.
            check_not_conflated(then_type, else_type, info)
            return both, else_store

        case EAdd() | EConcat() | ESub() | EMul() | ELessThan() | ELessThanEq() \
                | EGreatThan() | EGreatThanEq() | EEq():
            # Check built-in binary operations
            return check_binary(expr, env, tmap, store)

        case ENeg(info, operand, _):
            operand_type, store = check_expr(operand, env, tmap, store)
            if not isinstance(operand_type, TInt):
                raise TypeError_(
                    info,
                    f"`-` cannot be applied to {pprint_type(operand_type)}; "
                    f"it negates an Int",
                )
            return TInt(info), store

        case EList(info, elements, _):
            # Every element is one of the same list, so they agree on one
            # type -- the rule the branches of an `if` obey, for the same
            # reason. An empty list has no element to say what it holds,
            # and is worth `[!]`: nothing arrives from it, so it fits
            # wherever any list is wanted (see `accepts`).
            types, store = check_each(elements, env, tmap, store)
            if not types:
                return TList(info, TNever(info)), store
            element = types[0]
            for other in types[1:]:
                both = agree(element, other)
                if both is None:
                    raise TypeError_(
                        info,
                        f"the elements of this list have different types: "
                        f"{pprint_type(element)} and {pprint_type(other)}",
                    )
                element = both
            return TList(info, element), store

        case EListComp(info, element, clauses, _):
            inner, store = check_clauses(clauses, env, tmap, store)
            element_type, store = check_expr(element, inner, tmap, store)
            return TList(info, element_type), store

        case ECall():
            # Check
            return check_call(expr, env, tmap, store)

        case _:
            unsupported(expr)


# --- Param -----------------------------------------------------------


def check_param(param, type_, tmap, store):
    """A parameter's declared type, recorded under its symbol. The type
    is passed in rather than read off the node, since a `def` with a
    signature line writes no annotation on the parameter itself.
    Param -> Type -> {Int: Type} -> Store -> Type"""
    record(tmap, param.sym, type_, store)
    return type_


# --- SFunctionDef ----------------------------------------------------


def function_type(node, store):
    """node's type, from the signature line that named it or from the
    annotations on its own header, quantified over the type variables it
    leaves free. Raises TypeError_ if neither says the whole type.
    SFunctionDef -> Store -> Type"""
    written = signature_of(node, store)
    if written is not None:
        return written
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
    return generalize(
        TFunction(node.info, [p.type for p in node.params], node.return_type),
        node.info,
    )


def check_function(node, env, tmap, store):
    """Checks a fully annotated def's body against its declared types.
    Always yields unit, whatever the function's own type is: a def is a
    statement. SFunctionDef -> Env -> {Int: Type} -> Store -> (Type, Store)"""
    ftype = function_type(node, store)
    # The body is checked at the *quantified* variables themselves, not
    # at anything they might be instantiated to: a TVar is `same_type`
    # only with itself, so a body that assumes `a` is an Int is refused
    # here rather than at some call. That is the whole of skolemization.
    _, written = instantiated(ftype)
    param_types, result_type = written.params, written.result
    for param, type_ in zip(node.params, param_types):
        check_param(param, type_, tmap, store)
    record(tmap, node.sym, ftype, store)

    # env already binds every def of this block (declare_functions); the
    # parameters shadow over that, as analyses.py binds them.
    body_env = env
    for param, type_ in zip(node.params, param_types):
        body_env = bind(body_env, param.name, type_)

    # The body's last statement is in tail position; check_stmt already
    # answers what it supplies, by return or by value (PYKING.md).
    supplied, store = check_stmts(
        node.body, body_env, tmap, result_type, None, store
    )
    if accepts(result_type, supplied):
        return unit(node.info), store
    if is_unit(supplied):
        raise TypeError_(
            node.info,
            f"'{node.name}' returns {pprint_type(result_type)}, so its "
            f"body must return on every path, or end in an expression of "
            f"that type",
        )
    raise TypeError_(
        node.body[-1].info,
        f"'{node.name}' returns {pprint_type(result_type)}, but its "
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
    """What a function body supplies: its last statement's value.
    SFunctionDef -> Env -> {Int: Type} -> Type? -> Store -> (Type, Store)"""
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
        case (TList(_, wanted, _), TList(_, given, _)):
            # A list is covariant in its element, which is sound because
            # a Pyking list is immutable -- nothing can be written into
            # one. This is what lets the empty list, `[!]`, be used
            # wherever a list of anything is wanted.
            return accepts(wanted, given)
        case (TTuple(_, wanted, _), TTuple(_, given, _)) if (
            len(wanted) == len(given)
        ):
            # And a tuple is covariant in each of its parts, for the same
            # reason and so that the rule above reaches inside one:
            # `([], 0)` has to fit `([Int], Int)`.
            return all(map(accepts, wanted, given))
    return same_type(expected, actual)


# --- ECall -----------------------------------------------------------


def check_call(call, env, tmap, store):
    """ Type check a function call.
    ECall -> Env -> {Int:Type} -> Store -> (Type, Store)"""
    match call.func:
        case EVar(_, name, _) if name in env:
            match env[name]:
                case TBuiltin(_, builtin):
                    return check_builtin_call(builtin, call, env, tmap, store)
    func_type, store = check_expr(call.func, env, tmap, store)
    quantified, func_type = instantiated(func_type)
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
    if quantified:
        return check_polymorphic_call(
            call, quantified, func_type, env, tmap, store
        )
    params, store = check_arguments(call.args, func_type.params, env, tmap, store)
    match func_type:
        case TFunction(_, _, result, _, _, None):
            # None in the function defition place (last parameter) states
            # that the result type is available. Return the result type.
            return result, store
        case TFunction():
            return infer_call(func_type, params, call, tmap, store)


def check_polymorphic_call(call, quantified, declared, env, tmap, store):
    """A call to a function whose type quantifies variables. Each
    argument decides what the variables it mentions are (`match_type`),
    and the call is worth what they make of the declared result. There
    is no solver: a variable is decided by the first argument that
    reaches it and must agree with every later one.
    ECall -> [String] -> TFunction -> Env -> {Int: Type} -> Store
    -> (Type, Store)"""
    chosen, quantified_set = {}, set(quantified)
    for position, (arg, expected) in enumerate(zip(call.args, declared.params), 1):
        actual, store = check_expr(arg, env, tmap, store)
        chosen = match_type(expected, actual, quantified_set, chosen, arg, position)
    undecided = [name for name in quantified if name not in chosen]
    if undecided:
        raise TypeError_(
            call.info,
            f"this call does not say what "
            f"{', '.join(repr(name) for name in undecided)} "
            f"{'is' if len(undecided) == 1 else 'are'}; no argument reaches "
            f"{'it' if len(undecided) == 1 else 'them'}, so there is nothing "
            f"to decide {'it' if len(undecided) == 1 else 'them'} from",
        )
    return substitute(declared.result, chosen), store


def match_type(expected, actual, quantified, chosen, arg, position):
    """Matches one declared parameter against an argument's type, one
    way: a quantified variable is decided the first time it is met and
    has to agree with every later meeting. Answers the mapping extended
    with what this match decided; raises TypeError_ on a mismatch.
    Type -> Type -> {String} -> {String: Type} -> Expr -> Int
    -> {String: Type}"""
    match (expected, actual):
        case (TVar(_, name), _) if name in quantified:
            earlier = chosen.get(name)
            if earlier is None:
                return {**chosen, name: actual}
            # A later argument may sharpen what an earlier one left
            # open: `head([], true)` says nothing about `a` with its
            # empty list and everything with its `true`.
            both = agree(earlier, actual)
            if both is None:
                raise TypeError_(
                    arg.info,
                    f"'{name}' is {pprint_type(earlier)} in this call, from "
                    f"an earlier argument, but argument {position} makes it "
                    f"{pprint_type(actual)}",
                )
            return {**chosen, name: both}
        case (TList(_, element), TList(_, other)):
            return match_type(element, other, quantified, chosen, arg, position)
        case (TTuple(_, mine), TTuple(_, theirs)) if len(mine) == len(theirs):
            for mine_one, their_one in zip(mine, theirs):
                chosen = match_type(
                    mine_one, their_one, quantified, chosen, arg, position
                )
            return chosen
        case (TFunction(_, mine, my_result, _, _, _),
              TFunction(_, theirs, their_result, _, _, _)) if len(mine) == len(theirs):
            for mine_one, their_one in zip(mine, theirs):
                chosen = match_type(
                    mine_one, their_one, quantified, chosen, arg, position
                )
            return match_type(
                my_result, their_result, quantified, chosen, arg, position
            )
    # Everything else, a nested `all` included, is compared as it stands:
    # a parameter declared polymorphic wants a value that is polymorphic
    # the same way, which `same_type` decides up to the names bound.
    settled = substitute(expected, chosen)
    if not accepts(settled, actual):
        raise argument_error(position, actual, settled, arg)
    return chosen


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
        f"argument {position} has type {pprint_type_nested(actual)}, but "
        f"{pprint_type_nested(expected)} was expected",
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
    EAdd: ("+", [(TInt, TInt)]),
    EConcat: ("++", [(TString, TString)]),
    ESub: ("-", [(TInt, TInt)]),
    EMul: ("*", [(TInt, TInt)]),
    ELessThan: ("<", [(TInt, TBool)]),
    ELessThanEq: ("<=", [(TInt, TBool)]),
    EGreatThan: (">", [(TInt, TBool)]),
    EGreatThanEq: (">=", [(TInt, TBool)]),
    EEq: ("==", [(TInt, TBool), (TString, TBool), (TBool, TBool)]),
}


# The two operators that are easy to write for one another: `+` adds
# and `++` joins, and neither accepts what the other does. Each names
# the other when a mismatch is exactly the swap -- and only then, so
# `1 + 'a'`, which no operator would take, is not offered a suggestion.
ALTERNATIVES = {
    EAdd: (EConcat, "`++`, the concatenation operator"),
    EConcat: (EAdd, "`+`"),
}


def alternative(expr, left_type, right_type):
    """The "did you mean" clause for an operator written where its
    look-alike belongs, or "" when there is nothing to suggest.
    Expr -> Type -> Type -> String"""
    match ALTERNATIVES.get(type(expr)):
        case (partner, description):
            _, signatures = OPERATORS[partner]
            for operand, _ in signatures:
                if isinstance(left_type, operand) and isinstance(right_type, operand):
                    return f". Did you mean {description}?"
    return ""


def agree(first, second):
    """The one type two branches both fit, or None where there is none.
    Either may be the answer, which is what makes a base case work: `[]`
    is `[!]` and fits any list, so an `if` or a `match` with `[]` on one
    side and `[1]` on the other is worth `[Int]`.
    Type -> Type -> Type?"""
    if accepts(first, second):
        return first
    if accepts(second, first):
        return second
    return None


def concat_lists(expr, left_type, right_type):
    """`++` over two lists, whose result type the signature table cannot
    state: it depends on the element type rather than being one of a
    fixed few. The empty list is `[!]` and agrees with either side, so
    `xs ++ []` is `xs`. None where this is not that.
    Expr -> Type -> Type -> Type?"""
    if not isinstance(expr, EConcat):
        return None
    match (left_type, right_type):
        case (TList(_, mine, _), TList(_, theirs, _)):
            if accepts(mine, theirs):
                return TList(expr.info, mine)
            if accepts(theirs, mine):
                return TList(expr.info, theirs)
    return None


def check_binary(expr, env, tmap, store):
    """The type of a binary operator application, from OPERATORS.
    Expr -> Env -> {Int: Type} -> Store -> (Type, Store)"""
    spelling, signatures = OPERATORS[type(expr)]
    left_type, store = check_expr(expr.left, env, tmap, store)
    right_type, store = check_expr(expr.right, env, tmap, store)
    for operand, result in signatures:
        if isinstance(left_type, operand) and isinstance(right_type, operand):
            # Operands match. Return the resulting type
            return result(expr.info), store
    joined = concat_lists(expr, left_type, right_type)
    if joined is not None:
        return joined, store
    # Raise type error, stating what is accepted
    accepted = " or ".join(
        f"{name} {spelling} {name}"
        for name in (pprint_type(operand(expr.info)) for operand, _ in signatures)
    )
    if isinstance(expr, EConcat):
        accepted += " or two lists of one type"
    raise TypeError_(
        expr.info,
        f"`{spelling}` cannot be applied to {pprint_type(left_type)} and "
        f"{pprint_type(right_type)}; it accepts {accepted}"
        + alternative(expr, left_type, right_type),
    )


# --- CompClause ------------------------------------------------------


def check_clauses(clauses, env, tmap, store):
    """The environment a comprehension's clauses leave for its element
    expression. Each `for` binds over the elements of its sequence and
    the ones after it see those bindings; each `if` is checked in
    whatever is in scope by then.
    [CompClause] -> Env -> {Int: Type} -> Store -> (Env, Store)"""
    for clause in clauses:
        match clause:
            case CompFor(info, pattern, sequence, _):
                sequence_type, store = check_expr(sequence, env, tmap, store)
                match sequence_type:
                    case TList(_, element, _):
                        env = check_pattern(pattern, element, env, tmap)
                    case _:
                        raise TypeError_(
                            info,
                            f"a comprehension walks a list, but this one is "
                            f"given {pprint_type(sequence_type)}",
                        )
            case CompIf(info, condition, _):
                condition_type, store = check_expr(condition, env, tmap, store)
                if not isinstance(condition_type, TBool):
                    raise TypeError_(
                        info,
                        f"the condition of a comprehension must be Bool, not "
                        f"{pprint_type(condition_type)}",
                    )
    return env, store


# --- Pattern ---------------------------------------------------------
#
# A pattern is checked *against* the type of what it matches, and what
# it answers is the environment its captures leave behind. Nothing in a
# pattern is evaluated, so there is no store to thread: a pattern can
# neither call a function nor fail in a way inference would care about.


def check_pattern(pattern, type_, env, tmap):
    """The environment a pattern binds, checked against the type of the
    value it matches. Raises TypeError_ for a pattern that could never
    match a value of that type.
    Pattern -> Type -> Env -> {Int: Type} -> Env"""
    record(tmap, pattern.sym, type_, empty_store())
    match pattern:
        case PWildcard():
            return env
        case PCapture(_, name, _):
            return bind(env, name, type_)
        case PInt(info, _, _):
            return pattern_literal(TInt(info), type_, info, env)
        case PString(info, _, _):
            return pattern_literal(TString(info), type_, info, env)
        case PBool(info, _, _):
            return pattern_literal(TBool(info), type_, info, env)
        case PTuple(info, elements, _):
            match type_:
                case TTuple(_, parts, _) if len(parts) == len(elements):
                    for element, part in zip(elements, parts):
                        env = check_pattern(element, part, env, tmap)
                    return env
            raise TypeError_(
                info,
                f"this pattern takes a tuple of {len(elements)} apart, but "
                f"it is matched against {pprint_type(type_)}",
            )
        case PList(info, prefix, rest, suffix, _):
            match type_:
                case TList(_, element, _):
                    pass
                case _:
                    raise TypeError_(
                        info,
                        f"this pattern matches a list, but it is matched "
                        f"against {pprint_type(type_)}",
                    )
            for one in list(prefix) + list(suffix or []):
                env = check_pattern(one, element, env, tmap)
            match rest:
                case ListRest(_, name, _) if name is not None:
                    # The rest of a list is a list of the same elements.
                    env = bind(env, name, type_)
            return env
    unsupported(pattern)


def pattern_literal(wanted, type_, info, env):
    """A literal pattern's environment -- unchanged, since it binds
    nothing -- once the type it matches is the one it could equal.
    Type -> Type -> Info -> Env -> Env"""
    if not accepts(type_, wanted):
        raise TypeError_(
            info,
            f"this pattern is {pprint_type(wanted)}, but it is matched "
            f"against {pprint_type(type_)}",
        )
    return env


def irrefutable(pattern):
    """Whether a pattern matches every value of its type. A tuple's
    shape is fixed by its type, so a tuple of irrefutable patterns is
    one too; a list's length is not, so no list pattern is.
    Pattern -> Bool"""
    match pattern:
        case PWildcard() | PCapture():
            return True
        case PTuple(_, elements, _):
            return all(irrefutable(element) for element in elements)
    return False


def covers(patterns):
    """Whether these patterns between them match every value they could
    be matched against. One irrefutable pattern is enough on its own.
    Two more ways: both of a Bool's values, and -- the one every
    recursion over a list is written with -- exact lengths 0 up to k-1
    plus one pattern with a rest marker that takes k or more. The
    question is
    about the patterns alone -- a list pattern matched against something
    that is not a list has already been refused by `check_pattern`.
    [Pattern] -> Bool"""
    if any(irrefutable(pattern) for pattern in patterns):
        return True
    # A Bool has two values, so naming both of them covers it. Int and
    # String cannot be enumerated, and are not tried.
    booleans = {p.value for p in patterns if isinstance(p, PBool)}
    if booleans == {True, False}:
        return True
    lists = [p for p in patterns if isinstance(p, PList)]
    exact = {
        len(p.prefix) for p in lists
        if p.rest is None and all(irrefutable(e) for e in p.prefix)
    }
    for p in lists:
        if p.rest is None:
            continue
        fixed = list(p.prefix) + list(p.suffix or [])
        if all(irrefutable(e) for e in fixed) \
                and all(n in exact for n in range(len(fixed))):
            return True
    return False


def require_total(stmt, what):
    """Refuses a value-form `match` whose cases do not cover every
    value. A `match` that matches nothing does nothing (PYKING.md), so
    one whose value is being taken has to be unable to match nothing --
    otherwise the type reported for the binding names a value that need
    never exist. Stmt -> String -> ()"""
    match stmt:
        case SMatch(info, _, cases, _):
            if not covers([c.pattern for c in cases]):
                raise TypeError_(
                    info,
                    f"this 'match' is {what}, so it must match every value: "
                    f"add a 'case _' or a case that binds a name, since a "
                    f"'match' that matches nothing yields nothing",
                )


# --- Type ------------------------------------------------------------


def check_annotation(annotation, actual):
    """Checks a binding's annotation, if any, against its right-hand
    side's actual type; raises TypeError_ at the annotation on a
    mismatch. The annotation is quantified first, since a written type
    is quantified wherever one is written -- without that, binding a
    polymorphic function to an annotated name would compare an `all`
    against a bare function type and refuse a program that is right.
    Type? -> Type -> ()"""
    if annotation is None:
        return
    annotation = generalize(annotation, annotation.info)
    if accepts(annotation, actual):
        return
    raise TypeError_(
        annotation.info,
        f"this binding is annotated {pprint_type_nested(annotation)}, but "
        f"its value has type {pprint_type_nested(actual)}",
    )


def same_type(a, b):
    """Whether two types are the same type, structurally -- never a == b,
    since Type nodes are dataclasses whose info and sym also differ.
    Type -> Type -> Bool"""
    match (a, b):
        case (TInt(), TInt()) | (TString(), TString()) | (TBool(), TBool()):
            return True
        case (TBuiltin(_, x), TBuiltin(_, y)):
            # Each host operation is its own type, and no two of them are
            # the same one.
            return x == y
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
        case (TVar(_, x), TVar(_, y)):
            # A variable is rigid: inside a body it stands for a type the
            # caller picked, so it is the same type as itself and nothing
            # else. That is the whole of what makes a polymorphic body
            # honest -- no substitution is needed to enforce it.
            return x == y
        case (TForall(_, mine, my_body), TForall(_, theirs, their_body)):
            # Two polytypes are one type when they differ only in the
            # names they bind, so both are renamed by position first.
            return (len(mine) == len(theirs)
                    and same_type(canonical(my_body, mine),
                                  canonical(their_body, theirs)))
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
    """env with name bound to type_. A fresh dict, so shadowing works by
    construction. Env -> String -> Type -> Env"""
    return {**env, name: type_}
