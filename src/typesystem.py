"""

The type checker is is written in a functional style, and type checks
a program. A function whose type was not written down is worked out the
first time something calls it, from its own body: its parameters go in
as metavariables and the body's demands solve them, which is
Hindley-Milner's rule reached without a constraint solver. See
docs/type_inference.md.

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
    unify(one, other, store) -- the store in which two types are one.



Data structures:

* `env : {String: Type}`, mapping a name in the environment to a
   option type.

    TypeError_ -- a type-check failure, with the source position.
    Instance / Given / Frame / Store -- inference's working state (see
        docs/type_inference.md).
    Inferring -- marks a return type being worked out.

See the Signatures block below for every function's type.
"""

from dataclasses import dataclass, replace

from analyses import AnalysisError, BUILTINS, block_functions
from analyses import walk as analyses_walk
from lexer import Info
from syntax import (
    pprint_type, pprint_type_nested,
    EInt, EString, EBool, EVar, EQualified, EAdd, EConcat, ESub, EMul, EDiv,
    ECall, EIf, ETuple,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq,
    SLet, SLetStmt, SVar, SMutate, SExprStmt, SIf, SReturn, SReturnStmt,
    SFunctionDef,
    SFunctionSig, SMatch, SImport,
    ENeg, EList, EListComp, CompFor, CompIf,
    PInt, PString, PBool, PWildcard, PCapture, PTuple, PList, PText, ListRest,
    SLoop, SBreak, SContinue, ForIn, WhileTest,
    Type, TInt, TString, TBool, TList, TTuple, TFunction, TUnknown,
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
#     SigMap = {String: Type}     what one module exports, and at what
#                                 type -- all of it another module sees
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
#     val type_check         : [Stmt] -> [(String, SigMap)] -> TMap
#     val check_stmts        : [Stmt] -> Env -> TMap -> Type? -> Type?
#                              -> Store -> (Type?, Store)
#     val check_stmt         : Stmt -> Env -> TMap -> Type? -> Type?
#                              -> Store -> (Type?, Env, Store)
#
# The `Type?` those two answer is `None` for a statement that does not
# fall through -- a `break`, a `continue`, or a loop with no `break` in
# it. Nothing arrives after one, so there is no value to give a type to.
# Only a statement can say it: `check_expr` always answers with a type.
#     val check_expr         : Expr -> Env -> TMap -> Store -> (Type, Store)
#     val check_param        : Param -> TMap -> Store -> Type
#     val check_function     : SFunctionDef -> Env -> TMap -> Store
#                              -> (Type, Store)
#     val check_call         : ECall -> Env -> TMap -> Store -> (Type, Store)
#     val check_binary       : Expr -> Env -> TMap -> Store -> (Type, Store)
#     val alternative        : Expr -> Type -> Type -> String
#     val check_annotation   : Type? -> Type -> Store -> Store
#     val check_target       : AssignTarget -> Type -> Env -> TMap -> Store
#                              -> (Env, Store)
#     val function_type      : SFunctionDef -> TFunction
#     val same_type          : Type -> Type -> Bool
#     val bind               : Env -> String -> Type -> Env
#     val import_env         : [Stmt] -> Env -> Store -> Env
#     val check_exports      : [Stmt] -> TMap -> ()
#     val unit               : Info -> Type
#
# and, for a function whose type was not written down (see "Functions,
# and the two places one can be checked" above):
#
#     val declare_functions  : [Stmt] -> Env -> Store -> (Env, Store)
#     val declared_type      : SFunctionDef -> TFunction
#     val infer_call         : TFunction -> ECall -> Env -> TMap -> Store
#                              -> (Type, Store)
#     val infer_definition   : TFunction -> TMap -> Store -> (Type, Store)
#     val inference_group    : SFunctionDef -> Store -> [SFunctionDef]
#     val body_result        : SFunctionDef -> Env -> TMap -> Store
#                              -> (Type?, Store)
#     val one_type           : [Given] -> String -> Store -> (Type, Store)
#     val called_at          : Type -> ECall -> [Expr] -> Env -> TMap
#                              -> Store -> (Type, Store)
#     val accepts            : Type? -> Type? -> Bool
#     val settled_type       : Type -> Store -> Type
#
# and, for the metavariables the body's own demands solve (see
# "metavariables" below, and docs/type_inference.md):
#
#     val fresh_meta         : Info -> Store -> (TVar, Store)
#     val instantiate        : Type -> Store -> (Type, Store)
#     val unify              : Type -> Type -> Store -> Store?
#     val prune              : Type -> Store -> Type
#     val zonk               : Type -> Store -> Type
#     val generalise         : SFunctionDef -> TFunction -> {String}
#                              -> Store -> Type
#     val verified           : SFunctionDef -> Type -> TMap -> Store
#                              -> TMap?
#
# A function that takes a `Store` returns one: what a check works out is
# knowledge, and knowledge that was not handed back would be lost. The
# one exception is `record`, which fills in `TMap`; see there for why
# that table alone is written to.
#
# Only `type_check` is meant to be called from outside -- with one
# deliberate exception: `src/repl.py` checks a session one entry at a
# time, and so calls `declare_functions`, `check_stmt`, `check_expr` and
# `zonk` itself, carrying the `Env` and the `Store` between entries.
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
    """What a deferred function was worked out to be, the once it was
    worked out. See docs/type_inference.md. Fields: type: TFunction (its
    parameters and result, each resolved)."""
    type: Type


@dataclass(frozen=True)
class Given:
    """One `return` in the body being inferred, or the value its body
    ends in. Fields: info: Info (where it is written), type: Type (what
    it gives)."""
    info: Info
    type: Type


@dataclass(frozen=True)
class Frame:
    """What the current inference has gathered. Fields: returns:
    (Given,).
      TODO: explain better how Frame is used.
    """
    returns: tuple = ()


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
      information about returns.
    signatures: {Int: Type}. A `def`'s type where the source wrote it on
      a line of its own (`def foo : (a) -> a`) instead of on the header.
      Keyed by the definition's symbol, filled by declare_functions from
      the block both statements are in. Unlike the rest of the store this
      is *given* rather than worked out, and it is here so that reaching
      it costs no new parameter on every function that might need it.
    solutions: {String: Type}. What each metavariable has been worked
      out to be, or nothing where it is still open. A metavariable is
      never re-solved, so this only grows; generalising a definition
      reads it and then leaves it alone.
    groups: {Int: [SFunctionDef]}. The `def`s of the block each
      definition was written in, keyed by its symbol. They may name each
      other, so they are worked out together and generalised together
      (see infer_call). Given rather than worked out, like signatures.
    modules: {String: {String: Type}}. The signature of every module
      this one imports: each module's name paired with what it exports
      and at what type (src/module.py's `sigmap`). Given rather than
      worked out, like signatures and groups, and the whole of what one
      module can see of another.
    captured: {String}. Metavariables a definition could not generalise
      because the scope it was written in already held them -- an
      enclosing function's parameter, reached from a `def` inside it.
      One left open at the end of the program is a type Pyking has no
      way to write down, so it is printed as none at all rather than as
      a variable that would read as more general than it is.
    """
    environments: dict
    instances: dict
    checking: frozenset
    frame: Frame
    signatures: dict
    fresh: int = 0
    solutions: dict = None
    groups: dict = None
    captured: frozenset = frozenset()
    modules: dict = None


def empty_store(sigmaps=()):
    """The store a program starts checking in, holding the signature of
    every module it imports. [(String, {String: Type})] -> Store"""
    return Store({}, {}, frozenset(), Frame(), {}, solutions={}, groups={},
                 modules=dict(sigmaps))


# The names a generalised variable is given, in order: a, b, ... z, a1, ...
_LETTERS = "abcdefghijklmnopqrstuvwxyz"


# --- metavariables ---------------------------------------------------
#
# A metavariable is a type the checker has not worked out yet, and is
# `TVar` with `rigid=False` -- the same node a written `a` uses, told
# apart by that one field. The two are exact opposites, which is why one
# class serves both: a rigid variable is a type the *caller* chose, so a
# body may assume nothing about it; a metavariable is a type *this*
# check is still choosing, so anything may still be assumed of it.
#
# Its name is `?n`, unwritable in source, and its solution lives in
# `store.solutions` rather than in the node -- so a type is a value like
# every other type here, and what has been worked out is one more thing
# the store carries. `zonk` is what reads a solution back.
#
# The empty list is where they were already needed and were faked: `[]`
# used to be `[a]` for a variable nothing could ever solve, accepted
# below everything by a special case in `accepts`. It is now `[?n]`, and
# `xs ++ [1]` solves it the ordinary way.


def fresh_meta(info, store):
    """A metavariable nothing has solved, and the store that handed it
    out. Info -> Store -> (TVar, Store)"""
    index = store.fresh
    return (TVar(info, f"?{index}", rigid=False),
            replace(store, fresh=index + 1))


def fresh_metas(count, info, store):
    """`count` metavariables, and the store that handed them out.
    Int -> Info -> Store -> ([TVar], Store)"""
    made = []
    for _ in range(count):
        one, store = fresh_meta(info, store)
        made.append(one)
    return made, store


def meta_age(name):
    """When a metavariable was handed out, from its name. Older is
    smaller. String -> Int"""
    return int(name[1:])


def is_meta(type_):
    """Whether this type is a metavariable -- something this check is
    still choosing, as against a rigid variable its caller chose.
    Type -> Bool"""
    return isinstance(type_, TVar) and not type_.rigid


def solving(store, name, type_):
    """store with the metavariable `name` solved to type_. Nothing is
    ever re-solved: `unify` looks through a solved variable rather than
    binding it again. Store -> String -> Type -> Store"""
    return replace(store, solutions={**store.solutions, name: type_})


def prune(type_, store):
    """type_ with its *outermost* constructor settled: a metavariable
    that has been solved is replaced by its solution, as far as that
    goes. Cheap, and enough for deciding which `case` a type is.
    Type -> Store -> Type"""
    seen = set()
    while isinstance(type_, TVar) and not type_.rigid:
        if type_.name in seen:
            return type_
        answer = store.solutions.get(type_.name)
        if answer is None:
            return type_
        seen.add(type_.name)
        type_ = answer
    return type_


def zonk(type_, store):
    """type_ with every metavariable in it replaced by what it was
    solved to, as deep as the solutions go. This is what turns a type
    the checker was still working on into one it can report.
    Type -> Store -> Type"""
    type_ = prune(type_, store)
    match type_:
        case TList(info, element, sym):
            return TList(info, zonk(element, store), sym)
        case TTuple(info, elements, sym):
            return TTuple(info, [zonk(e, store) for e in elements], sym)
        case TFunction(info, params, result, sym, tmsym, definition):
            return TFunction(info, [zonk(p, store) for p in params],
                             zonk(result, store), sym, tmsym, definition)
        case TForall(info, vars, body, sym):
            return TForall(info, vars, zonk(body, store), sym)
    return type_


def metas_in(type_, store):
    """Every metavariable name left unsolved in type_, in the order met
    and without repeats. Type -> Store -> [String]"""
    found = []

    def walk(t):
        t = prune(t, store)
        match t:
            case TVar(_, name, _, False):
                if name not in found:
                    found.append(name)
            case TList(_, element, _):
                walk(element)
            case TTuple(_, elements, _):
                for element in elements:
                    walk(element)
            case TFunction(_, params, result, _, _, _):
                for param in params:
                    walk(param)
                walk(result)
            case TForall(_, _, body, _):
                walk(body)

    walk(type_)
    return found


def occurs(name, type_, store):
    """Whether the metavariable `name` appears inside type_. Solving it
    to a type that mentions it would build an infinite type, which is
    what this refuses. String -> Type -> Store -> Bool"""
    return name in metas_in(type_, store)


def unify(one, other, store):
    """The store in which these two types are the same type, or None
    where no solution makes them so.

    First-order and eager: it is called at the places a type is demanded
    -- a call's arguments, an operator's operands, two branches -- and
    it answers there and then. Nothing is remembered for later, which is
    what keeps it local (docs/type_inference.md, "Unification, and how
    little of it there is").
    Type -> Type -> Store -> Store?"""
    one, other = prune(one, store), prune(other, store)
    match (one, other):
        case (TVar(_, mine, _, False), TVar(_, theirs, _, False)) if mine == theirs:
            return store
        case (TVar(_, mine, _, False), TVar(_, theirs, _, False)):
            # Two metavariables, one type: the *younger* is solved to
            # the older. Which way round matters, and only here. A
            # metavariable handed out earlier may belong to an
            # enclosing scope, and solving that one to a fresh inner
            # variable would lose exactly the fact that stops a nested
            # `def` generalising its enclosing function's parameter
            # (see `generalise`). Names count upwards, so the order
            # they were handed out in is the order of their names.
            if meta_age(mine) <= meta_age(theirs):
                return solving(store, theirs, one)
            return solving(store, mine, other)
        case (TVar(_, name, _, False), _):
            if occurs(name, other, store):
                return None
            return solving(store, name, other)
        case (_, TVar(_, name, _, False)):
            if occurs(name, one, store):
                return None
            return solving(store, name, one)
        case (TList(_, mine, _), TList(_, theirs, _)):
            return unify(mine, theirs, store)
        case (TTuple(_, mine, _), TTuple(_, theirs, _)) if len(mine) == len(theirs):
            for x, y in zip(mine, theirs):
                store = unify(x, y, store)
                if store is None:
                    return None
            return store
        case (TFunction(_, mine, my_result, _, _, _),
              TFunction(_, theirs, their_result, _, _, _)) if (
            len(mine) == len(theirs)
        ):
            for x, y in zip(mine, theirs):
                store = unify(x, y, store)
                if store is None:
                    return None
            return unify(my_result, their_result, store)
        case (TForall(_, mine, my_body, _), TForall(_, theirs, their_body, _)) if (
            len(mine) == len(theirs)
        ):
            return unify_under(mine, my_body, theirs, their_body, store)
    # Everything else -- two ground types, two rigid variables -- is
    # decided by `same_type`: there is nothing to solve, so either they
    # already are one type or no solution makes them one.
    return store if same_type(one, other) else None


def unify_under(mine, my_body, theirs, their_body, store):
    """The store in which two schemes are one scheme: both binders are
    renamed to the same fresh rigid variables and the bodies unified, so
    a metavariable inside either is solved rather than compared. None
    where no solution makes them one, or where one would let a bound
    variable escape (docs/type_inference.md, "Unifying under a
    quantifier").
    [String] -> Type -> [String] -> Type -> Store -> Store?"""
    free = set(metas_in(my_body, store)) | set(metas_in(their_body, store))
    info = my_body.info
    # `!` is unwritable in source, so these collide with no name a
    # program could have chosen.
    shared = [TVar(info, f"!{store.fresh + i}") for i in range(len(mine))]
    store = replace(store, fresh=store.fresh + len(mine))
    answer = unify(substitute(my_body, dict(zip(mine, shared))),
                   substitute(their_body, dict(zip(theirs, shared))),
                   store)
    if answer is None:
        return None
    # A metavariable free before the two met belongs to a scope where
    # these variables mean nothing, so one solved to a type naming them
    # would name a type nobody there can name.
    bound = {one.name for one in shared}
    for meta in free:
        loose = free_vars(zonk(TVar(info, meta, rigid=False), answer))
        if bound & set(loose):
            return None
    return answer


def demand(actual, wanted, info, what, store):
    """The store in which `actual` is `wanted`, or a TypeError_ saying
    what wanted it. This is how a construct asks for a type: `unify`
    where the answer is still open, an ordinary comparison where it is
    not, and one message either way.
    Type -> Type -> Info -> String -> Store -> Store"""
    answer = unify(wanted, actual, store)
    if answer is None:
        raise TypeError_(
            info, f"{what} must be {shown(wanted, store)}, not "
                  f"{shown(actual, store)}")
    return answer


def demand_list(actual, info, what, store):
    """The store in which `actual` is a list, and the type of its
    elements. Type -> Info -> String -> Store -> (Type, Store)"""
    element, store = fresh_meta(info, store)
    return element, demand(actual, TList(info, element), info, what, store)


def with_environment(store, tmsym, env):
    """store recording where the definition tmsym was written.
    Store -> Int -> Env -> Store"""
    return replace(store, environments={**store.environments, tmsym: env})


def environment_of(store, tmsym):
    """Where tmsym was written, or None. Store -> Int -> Env?"""
    return store.environments.get(tmsym)


def instance_of(store, tmsym):
    """What tmsym was worked out to be, or None if nothing has called it
    yet. A definition is worked out once, so there is at most one.
    Store -> Int -> Instance?"""
    return store.instances.get(tmsym)


def remembering(store, tmsym, instance):
    """store with tmsym's Instance recorded. Store -> Int -> Instance
    -> Store"""
    return replace(store, instances={**store.instances, tmsym: instance})


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


def returning(store, info, type_):
    """store whose frame has seen a `return` at info giving type_.
    Store -> Info -> Type -> Store"""
    return with_frame(
        store, replace(store.frame, returns=store.frame.returns + (Given(info, type_),))
    )


def learned(store, inner):
    """store with what an inner check found out (environments,
    instances, solutions) merged in; frame and checking stay store's
    own. A solution is knowledge like the other two: a metavariable is
    handed out once, so no two checks can disagree about one.
    Store -> Store -> Store"""
    return replace(store, environments=inner.environments,
                   instances=inner.instances, fresh=inner.fresh,
                   solutions=inner.solutions, groups=inner.groups,
                   captured=store.captured | inner.captured)


@dataclass(frozen=True)
class Inferring:
    """Stands in for a declared return type while one is being worked
    out; a return checked against it contributes to the frame instead
    of being compared."""


INFERRING = Inferring()


UNSUPPORTED = "Construct is not supported"


def unsupported(node):
    """Raises TypeError_ refusing node. Node -> ()"""
    raise TypeError_(node.info, UNSUPPORTED)


# --- the program -----------------------------------------------------


def type_check(stmts, sigmaps=()):
    """Type-checks one module -- or a whole one-file program, which is
    the same thing. `sigmaps` pairs the name of every module this one
    imports with what that module exports and at what type, which is all
    of it this check can see (src/module.py). Raises TypeError_ for the
    first thing that does not check out.
    [Stmt] -> [(String, {String: Type})] -> {Int: Type}"""
    tmap = {}
    store = empty_store(sigmaps)
    _, store = check_stmts(
        stmts, import_env(stmts, builtin_env(), store), tmap, None, None, store
    )
    check_exports(stmts, tmap)
    # Every type is read back once the whole program has been checked,
    # because a metavariable open where it was recorded may have been
    # solved by something written further down -- a definition worked
    # out before the call that says what it holds, most often. What is
    # still open then is open for good, and is shown as the variable it
    # is.
    return {sym: displayed(zonk(type_, store), store)
            for sym, type_ in tmap.items()}


def builtin_env():
    """The environment a program starts in: every name in
    analyses.BUILTINS, at its TBuiltin type. Its own function so
    src/repl.py can reuse it when checking a session one entry at a
    time. () -> Env"""
    return {name: TBuiltin(BUILTIN_INFO, name) for name in BUILTINS}


def check_exports(stmts, tmap):
    """Refuses a module that exports a definition it has no type for.

    A `def` that writes no annotations is worked out from a call
    (`infer_definition`), so one nothing in the module calls has no type
    -- and there is nothing to work it out *from*, since inference reads
    a definition off the uses its own module makes of it. A module says
    what it exports here, in the file that exports it, rather than
    leaving the module that imports it to find out.
    [Stmt] -> {Int: Type} -> ()"""
    for statement in stmts:
        match statement:
            case SFunctionDef(info, name) if (
                statement.public and statement.sym not in tmap
            ):
                raise TypeError_(
                    info,
                    f"'{name}' is exported, but this module never says what "
                    f"it is: a 'def' that writes no annotations is worked out "
                    f"from a call, and nothing here calls '{name}'. Annotate "
                    f"its parameters and return type, or call it in this "
                    f"module.",
                )


def available(module, info, store):
    """What a module exports, or a refusal saying it cannot be reached
    from here at all -- which is what a file checked on its own gets,
    since no module system ran to find it. String -> Info -> Store ->
    {String: Type}"""
    sigmap = (store.modules or {}).get(module)
    if sigmap is None:
        raise AnalysisError(
            info,
            f"module '{module}' cannot be imported here: an import needs "
            "the whole program, and this is one file on its own",
        )
    return sigmap


def import_env(stmts, env, store):
    """env extended with everything a module's imports bring into scope:
    a selected name under the name it is known by here, and a field of a
    plain import under `alias.field`, which is the spelling `EQualified`
    looks up. An import is a declaration of the module rather than a
    statement in its sequence -- like a `def`, all of them are in scope
    throughout it, which is what lets a definition written above an
    import still name what it brings in.
    [Stmt] -> Env -> Store -> Env"""
    for statement in stmts:
        match statement:
            case SImport(info, module, name, selected, fields, _):
                sigmap = available(module, info, store)
                for exported, local in fields or ():
                    bound = local if selected else f"{name}.{exported}"
                    env = bind(env, bound, sigmap[exported])
    return env


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
            case TTuple(_, elements):
                for element in elements:
                    walk(element, bound)
            case TFunction(_, params, result, _, _, _):
                for param in params:
                    walk(param, bound)
                walk(result, bound)

    walk(type_, bound)
    return found


def generalize(type_, info):
    """A written type with its free variables quantified, or the type
    itself when it has none. Type -> Info -> Type"""
    variables = free_vars(type_)
    if not variables:
        return type_
    return TForall(type_.info, variables, type_)


def instantiated(type_):
    """A type's quantified variables and its body, as ([String], Type);
    a type with no `all` on it answers ([], itself).
    Type -> ([String], Type)"""
    match type_:
        case TForall(_, vars, body):
            return list(vars), body
    return [], type_


def instantiate(type_, store):
    """One use of a polymorphic type: its outermost `all` stripped and
    every variable it bound replaced by a fresh metavariable. A type
    with no `all` on it is its own only use.

    This is where a definition serves two callers at two types, and it
    is also what stops inference ever producing a higher rank: an
    argument arrives here as its instances rather than as the `all`
    itself, so no `all` can be carried into a parameter type the checker
    is working out. A parameter *written* `(all a. ...)` is the
    exception, and being written is the whole of the difference (see
    PYKING.md, "Type variables"). Type -> Store -> (Type, Store)"""
    match type_:
        case TForall(info, vars, body, _):
            metas, store = fresh_metas(len(vars), info, store)
            return substitute(body, dict(zip(vars, metas))), store
    return type_, store


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
    deferred = [f for f in functions if not fully_annotated(f, store)]
    for function in deferred:
        # For all the functions, store this environment inside the
        # store. Enables recursive lookup.
        store = with_environment(store, function.sym, env)
        # And which definitions it is worked out *with*: the ones it may
        # name, which is every `def` of its own block. See infer_call.
        store = replace(store, groups={**store.groups, function.sym: deferred})
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
    left = False
    for statement in stmts:
        supplied, env, store = check_stmt(
            statement, env, tmap, return_type, acc_type, store
        )
        if left:
            # Everything from here on is unreachable: something above
            # said what happens next on every path through it. It is
            # still checked -- unreachable code is code -- but what the
            # block is worth was settled where the block was left.
            continue
        res_type = supplied
        left = ends_here(statement)
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
            store = check_annotation(annotation, expr_type_, store)
            expr_type_ = zonk(expr_type_, store)
            record(tmap, sym, expr_type_, store)
            env, store = check_target(target, expr_type_, env, tmap, store)
            return unit(info), env, store

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
            if bound_type is None:
                # Nothing ever arrives here -- a `loop:` with no `break`
                # is the only way to write it -- so the name stands for
                # a value of no particular type.
                bound_type, store = fresh_meta(info, store)
            store = check_annotation(annotation, bound_type, store)
            bound_type = zonk(bound_type, store)
            record(tmap, sym, bound_type, store)
            env, store = check_target(target, bound_type, env, tmap, store)
            return unit(info), env, store

        case SImport(info, module, _, _, _, _):
            # What an import brings in was settled before the first
            # statement was checked (see `import_env`), so there is
            # nothing left to do here and nothing it is worth. Asking
            # again is how a caller that checks statements one at a time
            # -- the REPL -- is told there is no module system running.
            available(module, info, store)
            return unit(info), env, store

        case SVar(info, name, expr, sym):
            # A mutable variable's type is its value's, with no mark of
            # mutability on it: a `var` Int is read as an ordinary Int
            # and stands wherever one does. Whether this name may be
            # bound here at all, and whether a `:=` may name it, is
            # analyses.py's rule rather than a type (see PYKING.md,
            # "Mutable variables").
            var_type, store = check_expr(expr, env, tmap, store)
            var_type = zonk(var_type, store)
            check_mutable(var_type, info, name)
            record(tmap, sym, var_type, store)
            return unit(info), bind(env, name, var_type), store

        case SMutate(info, name, expr, sym):
            # A mutation binds nothing and is worth nothing: the name
            # keeps the type it was declared with, and the value written
            # into it must fit that type.
            declared = env.get(name)
            if declared is None:
                raise AnalysisError(info, f"unbound name '{name}'")
            actual, store = check_expr(expr, env, tmap, store)
            answer = satisfies(declared, actual, store)
            if answer is None:
                raise TypeError_(
                    info,
                    f"'{name}' is {shown(declared, store)}, but "
                    f"this ':=' gives {shown(actual, store)}",
                )
            store = answer
            record(tmap, sym, declared, store)
            return unit(info), env, store

        case SExprStmt(_, expr, _):
            # An expression statement has its expression's type. That is
            # what lets a block yield a value, and so what makes the two
            # branches of an `if` comparable.
            type_, store = check_expr(expr, env, tmap, store)
            return type_, env, store

        case SIf(info, cond, then_body, else_body, _):
            cond_type, store = check_expr(cond, env, tmap, store)
            store = demand(cond_type, TBool(cond.info), cond.info,
                           "the condition of an 'if'", store)
            then_type, then_store = check_stmts(
                then_body, env, tmap, return_type, acc_type, store
            )
            if else_body is None:
                # With no `else` there is a way through this statement
                # that runs no branch at all, so the `if` supplies
                # nothing whatever the one branch it has ends in. A body
                # that needed that value is caught where the value was
                # needed -- `check_function` -- rather than here.
                return unit(info), env, then_store
            # The `else` is checked against what the `then` *found out*,
            # not against the store they both started from: only one of
            # them runs, but both were checked, and what either worked
            # out is true whichever way the program goes.
            else_type, else_store = check_stmts(
                else_body, env, tmap, return_type, acc_type, then_store
            )
            if then_type is None and else_type is None:
                # Neither way through this `if` falls out of it, so
                # neither does the `if`.
                return None, env, else_store
            # A branch that cannot finish -- a loop with no `break` in
            # it, or one ending in `break`/`continue` -- leaves the type
            # of the `if` to the other one, which is what `agree` does
            # with a `None` side.
            both, else_store = agree(then_type, else_type, else_store)
            if both is None:
                raise TypeError_(
                    info,
                    f"the branches of this 'if' have different types: "
                    f"{shown(then_type, else_store)} and "
                    f"{shown(else_type, else_store)}",
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

        case SLoop(info, target, init, annotation, iterate, body, sym):
            # The accumulator is what the initializer turned out to be,
            # and the loop carries exactly that from turn to turn -- and
            # is worth exactly that when it stops, however it stops. A
            # loop with none written carries unit and is worth unit.
            if target is None:
                accumulator = unit(info)
                body_env = env
            else:
                accumulator, store = check_expr(init, env, tmap, store)
                store = check_annotation(annotation, accumulator, store)
                accumulator = zonk(accumulator, store)
                body_env, store = check_target(
                    target, accumulator, env, tmap, store)
            record(tmap, sym, accumulator, store)
            turn_env, store = check_iteration(
                iterate, env, body_env, tmap, store
            )
            supplied, store = check_turn(
                body, turn_env, tmap, return_type, accumulator, store
            )
            # What the body ends in is what the next turn carries, so it
            # is held to the accumulator's type -- unless the body always
            # jumps, and then nothing arrives at the end of it to be held
            # to anything. A loop carrying nothing asks nothing of its
            # body: there is no next accumulator for it to give.
            # An accumulator that starts as `[]` starts as `[?e]`, and
            # what the body ends in is what solves it.
            if target is not None and supplied is not None:
                require_total(body[-1], "what the next turn carries")
                both, store = agree(accumulator, supplied, store)
                if both is None:
                    raise TypeError_(body[-1].info, carry_error(
                        zonk(accumulator, store), zonk(supplied, store), store))
            return zonk(accumulator, store), env, store

        case SBreak(info, _):
            # A `break` ends the loop, which is then worth the
            # accumulator this turn started with -- so there is nothing
            # to check. The statement supplies *nothing*: it never falls
            # through, so no value arrives after it. That is `None`
            # rather than a type, and it is what lets a branch that
            # breaks sit beside one that ends in the next accumulator:
            # `agree` keeps the other branch's answer.
            if acc_type is None:
                raise TypeError_(info, "'break' outside a loop")
            return None, env, store

        case SContinue(info, _):
            # `continue` starts the next turn with the accumulator
            # unchanged, which is that type whatever it is. Nothing
            # arrives after it either, so it supplies nothing too.
            if acc_type is None:
                raise TypeError_(info, "'continue' outside a loop")
            return None, env, store

        case SMatch(info, subject, cases, _):
            # Every arm is a branch, and they must agree on one type the
            # way an `if`'s two do -- one value leaves a `match` however
            # many ways in there are. Each arm is checked in the
            # environment its own pattern binds, and against what the
            # arms before it worked out (`then_store`'s rule, for the
            # same reason).
            subject_type, store = check_expr(subject, env, tmap, store)
            yielded, seen = None, False
            for case_clause in cases:
                inner, store = check_pattern(
                    case_clause.pattern, subject_type, env, tmap, store
                )
                arm_type, store = check_stmts(
                    case_clause.body, inner, tmap, return_type, acc_type, store
                )
                if not seen:
                    yielded, seen = arm_type, True
                elif yielded is None or arm_type is None:
                    # An arm that never falls through leaves what the
                    # `match` is worth to the arms that do.
                    yielded, store = agree(yielded, arm_type, store)
                else:
                    both, store = agree(yielded, arm_type, store)
                    if both is None:
                        raise TypeError_(
                            case_clause.info,
                            f"the arms of this 'match' have different types: "
                            f"{shown(yielded, store)} and "
                            f"{shown(arm_type, store)}",
                        )
                    check_not_conflated(yielded, arm_type, case_clause.info)
                    yielded = both
            if not seen:
                # No arms at all.
                return unit(info), env, store
            if yielded is None:
                # No arm falls through, so neither does the `match`.
                return None, env, store
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


def check_mutable(type_, info, name):
    """Refuses a `var` of a type mutation does not reach yet: Int and
    Bool are the whole of it so far. A type nothing has decided passes,
    since a `def` with no annotations is checked again at each call,
    where the type is known. Type -> Info -> String -> ()"""
    if isinstance(type_, (TInt, TBool, TUnknown)) or is_meta(type_):
        return
    raise TypeError_(
        info,
        f"a mutable variable must be Int or Bool, but '{name}' is "
        f"{pprint_type(type_)}",
    )


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


def carry_error(acc_type, actual, store):
    """The message for a loop body that does not end in the accumulator
    the next turn carries. Type -> Type -> Store -> String"""
    together = displayed(TTuple(BUILTIN_INFO, [acc_type, actual]), store)
    mine, theirs = together.elements
    return (f"this loop carries {pprint_type(mine)}, but its body ends in "
            f"{pprint_type(theirs)}")


def ends_every_path(stmts):
    """Whether every path through a loop body says what happens next --
    `continue`, `break` or `return`, or a branching statement whose every
    branch does. An `if` with no `else` has a path that runs neither, so
    it does not. [Stmt] -> Bool"""
    match list(stmts):
        case [*_, last]:
            return ends_here(last)
    return False


def ends_here(statement):
    """Whether one statement says what happens next on every path
    through it. Stmt -> Bool"""
    match statement:
        case SContinue() | SBreak() | SReturn() | SReturnStmt():
            return True
        case SIf(_, _, then_body, else_body, _):
            return (else_body is not None
                    and ends_every_path(then_body)
                    and ends_every_path(else_body))
        case SMatch(_, _, cases, _):
            return (covers([c.pattern for c in cases])
                    and all(ends_every_path(c.body) for c in cases))
    return False


def check_turn(body, turn_env, tmap, return_type, accumulator, store):
    """One pass over a loop body: what it supplies -- the accumulator the
    next turn carries -- and the store. A `return` written in the body
    leaves the enclosing *function*, so what it gives stays in the frame,
    exactly as one written outside the loop would.
    [Stmt] -> Env -> {Int: Type} -> Type? -> Type -> Store
    -> (Type?, Store)"""
    return check_stmts(
        body, turn_env, tmap, return_type, accumulator, store
    )


def check_iteration(iterate, env, body_env, tmap, store):
    """The environment a loop's body runs in, once its iteration clause
    is checked. A `for` walks a list and binds its element over the body;
    a `while` is a Bool test, asked where the accumulator is in scope.
    LoopIter? -> Env -> Env -> {Int: Type} -> Store -> (Env, Store)"""
    match iterate:
        case ForIn(info, name, sequence, _):
            sequence_type, store = check_expr(sequence, env, tmap, store)
            element, store = demand_list(
                sequence_type, info, "a 'for' loop walks a list, but this one",
                store)
            return bind(body_env, name, element), store
        case WhileTest(info, condition, _):
            condition_type, store = check_expr(condition, body_env, tmap, store)
            store = demand(condition_type, TBool(info), info,
                           "the condition of a 'while'", store)
    return body_env, store


def check_target(target, type_, env, tmap, store):
    """env with every name in an assignment target bound to its part of
    type_, recording each part under the target's own symbol, and the
    store that makes the value the right shape.

    A destructuring target is a *demand* for a tuple of that many parts,
    so a value nothing has decided yet is settled by it -- which is what
    lets `n, s = pair` say what `pair` is inside a body being worked
    out. AssignTarget -> Type -> Env -> {Int: Type} -> Store
    -> (Env, Store)"""
    match target:
        case TargetName(_, name, sym):
            record(tmap, sym, type_, store)
            return bind(env, name, type_), store
        case TargetTuple(info, elements, sym):
            parts, store = fresh_metas(len(elements), info, store)
            answer = unify(TTuple(info, parts), type_, store)
            if answer is None:
                raise TypeError_(
                    info,
                    f"this binding takes {len(elements)} values apart, but "
                    f"its value has type {shown(type_, store)}",
                )
            store = answer
            record(tmap, sym, zonk(type_, store), store)
            for element, part in zip(elements, parts):
                env, store = check_target(element, part, env, tmap, store)
            return env, store


def check_return(actual, return_type, info, store):
    """Checks a return's type against return_type, or -- if
    return_type is Inferring -- collects it into store's frame.
    Type? -> Type -> Info -> Store -> Store"""
    if actual is None:
        # `return loop: continue` -- the statement never falls through,
        # so no value is ever returned here.
        return store
    match return_type:
        case Inferring():
            return returning(store, info, actual)
    answer = unify(return_type, actual, store)
    if answer is None:
        raise TypeError_(
            info,
            f"this function returns {shown(return_type, store)}, "
            f"but this 'return' gives {shown(actual, store)}",
        )
    return answer


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
                    # A name standing for a definition something has
                    # already worked out means the scheme it turned out
                    # to be, not the promise it was declared as.
                    return settled_type(type_, store), store

        case EQualified(info, module, name, _):
            # A public name of an imported module. `import_env` put it
            # in the environment under this very spelling, so the lookup
            # is `EVar`'s -- and the type is the one the module's own
            # check worked out, read out of its sigmap.
            qualified = f"{module}.{name}"
            if qualified not in env:
                raise AnalysisError(info, unreachable_name(module, name, env))
            return settled_type(env[qualified], store), store

        case EIf(info, cond, then_expr, else_expr, _):
            # The `if` *expression*, whose `else` is mandatory -- so
            # unlike the statement it always yields a value, and its
            # branches must agree on what.
            cond_type, store = check_expr(cond, env, tmap, store)
            store = demand(cond_type, TBool(cond.info), cond.info,
                           "the condition of an 'if'", store)
            # Both branches yield the value this expression is worth, so
            # they are one type.
            then_type, then_store = check_expr(then_expr, env, tmap, store)
            else_type, else_store = check_expr(else_expr, env, tmap, then_store)
            both, else_store = agree(then_type, else_type, else_store)
            if both is None:
                raise TypeError_(
                    info,
                    f"the branches of this 'if' have different types: "
                    f"{shown(then_type, else_store)} and "
                    f"{shown(else_type, else_store)}",
                )
            # Raises a type error if they both carry a function defintion
            # and they represent different functions.
            # TODO: investigate and explain why this is needed.
            check_not_conflated(then_type, else_type, info)
            return both, else_store

        case EAdd() | EConcat() | ESub() | EMul() | EDiv() | ELessThan() \
                | ELessThanEq() | EGreatThan() | EGreatThanEq() | EEq():
            # Check built-in binary operations
            return check_binary(expr, env, tmap, store)

        case ENeg(info, operand, _):
            operand_type, store = check_expr(operand, env, tmap, store)
            answer = unify(TInt(info), operand_type, store)
            if answer is None:
                raise TypeError_(
                    info,
                    f"`-` cannot be applied to "
                    f"{shown(operand_type, store)}; "
                    f"it negates an Int",
                )
            return TInt(info), answer

        case EList(info, elements, _):
            # Every element is one of the same list, so they agree on one
            # type -- the rule the branches of an `if` obey, for the same
            # reason. An empty list has no element to say what it holds,
            # and is worth `[a]` for a variable nothing has constrained:
            # no element of it ever arrives, so it fits wherever any list
            # is wanted (see `accepts`).
            types, store = check_each(elements, env, tmap, store)
            if not types:
                element, store = fresh_meta(info, store)
                return TList(info, element), store
            element = types[0]
            for other in types[1:]:
                both, store = agree(element, other, store)
                if both is None:
                    raise TypeError_(
                        info,
                        f"the elements of this list have different types: "
                        f"{shown(element, store)} and "
                        f"{shown(other, store)}",
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
    answer = satisfies(result_type, supplied, store)
    if answer is not None:
        return unit(node.info), answer
    if is_unit(supplied):
        raise TypeError_(
            node.info,
            f"'{node.name}' returns {shown(result_type, store)}, so its "
            f"body must return on every path, or end in an expression of "
            f"that type",
        )
    raise TypeError_(
        node.body[-1].info,
        f"'{node.name}' returns {shown(result_type, store)}, but its "
        f"body ends in a value of type {shown(supplied, store)}",
    )


# --- inference -------------------------------------------------------
#
# An unannotated function is checked the first time something calls it,
# in the environment it was written in, with parameters taken from that
# call. See docs/type_inference.md.


def free_metas(env, store):
    """Every metavariable still open in the types an environment binds.
    These are the ones a definition written there may *not* generalise:
    they belong to something enclosing it, which has already been given
    them by its own caller. Env -> Store -> {String}"""
    found = set()
    for type_ in env.values():
        found.update(metas_in(type_, store))
    return found


def generalise(node, mono, outer, store):
    """The scheme a definition has: its worked-out type, with every
    metavariable the body left unsolved bound by one `all` at the top.

    Unsolved means the body never had to decide it, which is exactly
    what a type variable stands for -- so this is Hindley-Milner's
    generalisation step, and what it produces is the principal type.

    Except for `outer`, the metavariables the scope it was written in
    already holds. A `def` inside another `def` may not generalise the
    enclosing function's parameter: whoever called *that* chose it, and
    a scheme promising otherwise would be a promise the body cannot
    keep. This is Hindley-Milner's "not free in the environment" side
    condition, and it is the one place generalisation is unsound
    without a rule rather than merely imprecise.

    Only at the top: a metavariable is a type, never a scheme, so no
    `all` can appear inside one of these (docs/type_inference.md, "Rank
    one, and why that is the whole story").
    SFunctionDef -> TFunction -> {String} -> Store -> Type"""
    settled = zonk(mono, store)
    open_metas = [m for m in metas_in(settled, store) if m not in outer]
    if not open_metas:
        return settled

    taken, names, chosen = names_in(settled), [], {}
    for meta in open_metas:
        name = next_name(len(names), taken | set(names))
        names.append(name)
        chosen[meta] = TVar(node.info, name)
    return TForall(node.info, names, substitute(settled, chosen))


def names_in(type_):
    """Every type-variable name written anywhere in type_, bound or
    free. A name a new variable picks has to avoid all of them, not just
    the free ones: reusing one an inner `all` binds would shadow it, and
    the printed signature would read as saying something else.
    Type -> {String}"""
    match type_:
        case TVar(_, name, _, _):
            return {name}
        case TForall(_, vars, body, _):
            return set(vars) | names_in(body)
        case TList(_, element, _):
            return names_in(element)
        case TTuple(_, elements, _):
            return set().union(*(names_in(e) for e in elements)) if elements else set()
        case TFunction(_, params, result, _, _, _):
            return set().union(names_in(result), *(names_in(p) for p in params))
    return set()


def next_name(index, taken):
    """The index'th type-variable name that is not already spoken for.
    Int -> {String} -> String"""
    while True:
        name = _LETTERS[index % 26] + ("" if index < 26 else str(index // 26))
        if name not in taken:
            return name
        index += 1


def verified(node, scheme, tmap, store):
    """Whether a body really does have the scheme that was worked out
    for it, decided by checking it again with the variables **rigid** --
    which is the check an annotated polymorphic function gets, so what
    this accepts is exactly what the checker enforces. Answers the tmap
    that check filled, so the scheme is what the body's own nodes are
    reported as, or None where it does not hold.

    Unification is sound, so this should never refuse anything; it is
    kept because it costs one pass and it makes "a type this checker
    reports is one it enforces" true by construction rather than by
    argument (docs/type_inference.md, "Verification").
    SFunctionDef -> Type -> {Int: Type} -> Store -> {Int: Type}?"""
    _, written = instantiated(scheme)
    written_in = environment_of(store, node.sym)
    env = written_in if written_in is not None else builtin_env()
    # Its own name means the scheme while its body is checked, so a
    # recursive call is an ordinary call to a polymorphic function.
    env = bind(env, node.name, scheme)
    for param, type_ in zip(node.params, written.params):
        env = bind(env, param.name, type_)
    probe = {}
    try:
        supplied, after = supplied_type(node, env, probe, written.result, store)
    except (TypeError_, AnalysisError):
        return None
    if satisfies(written.result, supplied, after) is None:
        return None
    for param, type_ in zip(node.params, written.params):
        probe[param.sym] = type_
    probe[node.sym] = scheme
    return probe


def verifying(node, scheme, mono, tmap, store):
    """node's scheme, once checking its body against it has said so, or
    the scheme with its variables left as the metavariables they came
    from where the check does not hold.

    That fallback is not a failure but the one thing unification cannot
    express: a body whose demands are *ad-hoc* rather than parametric --
    `str(x)`, which accepts three types and no one type -- generalises
    to a promise it cannot keep, the re-check with `x` rigid says so,
    and the definition stays open for its first call to settle
    (docs/type_inference.md, "What is left of ad-hoc polymorphism").
    SFunctionDef -> Type -> TFunction -> {Int: Type} -> Store -> Type"""
    probe = verified(node, scheme, tmap, store)
    if probe is None:
        return zonk(mono, store)
    tmap.update(probe)
    return scheme


def infer_call(func_type, call, env, tmap, store):
    """The type this call is worth, working the definition out first.
    TFunction -> Expr -> Env -> {Int: Type} -> Store -> (Type, Store)"""
    _, store = infer_definition(func_type, tmap, store)
    return called_at(settled_type(func_type, store), call, call.args,
                     env, tmap, store)


def infer_definition(func_type, tmap, store):
    """The scheme an unannotated function has, worked out from its body
    the first time something calls it and remembered afterward.

    The body decides it, not this call: every parameter goes in as a
    metavariable and the body's own demands are what solve them
    (docs/type_inference.md, "Parameters start as questions"). So the
    answer is the definition's principal type, and this call is then
    checked against it like a call to anything else.
    TFunction -> {Int: Type} -> Store -> (Type, Store)"""
    match func_type:
        case TFunction(_, _, _, _, tmsym, SFunctionDef() as node):
            pass
        case _:
            return func_type, store

    # The environment the function was *written* in -- not this call's.
    # `declare_functions` always records it, and the `def` statement
    # sharpens it to the position; the fallback is for a caller that
    # somehow checked a call before the definition was declared, where
    # the builtins are at least in scope.
    written_in = environment_of(store, tmsym)
    body_env = written_in if written_in is not None else builtin_env()

    # Every `def` of the block this one is in is worked out together,
    # because they may name each other: each is bound to a *monotype*
    # while the group's bodies are checked, and generalised only once
    # all of them are done. That is the whole of recursion here -- a
    # recursive call is an ordinary call to a type already in scope --
    # and it is the rule Hindley-Milner applies to a `let rec` group.
    group = inference_group(node, store)
    monotypes, inner = monotypes_for(group, store)
    inner = with_frame(inner, Frame())
    for other, mono in zip(group, monotypes):
        inner = checking_now(inner, other.sym)

    for other, mono in zip(group, monotypes):
        # In the scope *it* was written in, never the group's or the
        # caller's: what a body captures is what was bound where it
        # stands (PYKING.md, "Names and scoping").
        written = environment_of(store, other.sym)
        group_env = written if written is not None else body_env
        for sibling, sibling_mono in zip(group, monotypes):
            group_env = bind(group_env, sibling.name, sibling_mono)
        for param, type_ in zip(other.params, mono.params):
            group_env = bind(group_env, param.name, type_)
        supplied, inner = body_result(other, group_env, tmap, inner)
        inner = required(inner, mono.result, supplied, other)

    store = learned(store, inner)

    # Generalise the whole group and remember every scheme *before*
    # verifying any of them: a body re-checked while a name it calls is
    # still unworked would work that one out all over again, which for
    # two functions that call each other never ends.
    schemes = []
    for other, mono in zip(group, monotypes):
        outer = free_metas(
            environment_of(store, other.sym) or body_env, store)
        # What this definition may not generalise, remembered so the
        # printed output does not claim it did.
        store = replace(store, captured=store.captured
                        | (outer & set(metas_in(mono, store))))
        schemes.append(generalise(other, zonk(mono, store), outer, store))
    for other, scheme in zip(group, schemes):
        store = remembering(store, other.sym, Instance(scheme))
    for other, scheme, mono in zip(group, schemes, monotypes):
        settled = verifying(other, scheme, mono, tmap, store)
        store = remembering(store, other.sym, Instance(settled))
        record(tmap, other.sym, settled, store)
        match instantiated(settled):
            case (_, TFunction(_, params, _, _, _, _)):
                for param, type_ in zip(other.params, params):
                    record(tmap, param.sym, type_, store)

    return settled_type(func_type, store), store


def work_out(func_type, tmap, store):
    """The store in which this definition has a scheme: `infer_call`
    without the call. What makes it happen is usually a call, but a
    definition handed somewhere a type is written down is worked out
    there instead -- the body receiving it will not reach it again, so
    that is the only place the two can be compared for real.
    Type -> {Int: Type} -> Store -> Store"""
    match func_type:
        case TFunction(_, _, _, _, tmsym, SFunctionDef()) if (
            instance_of(store, tmsym) is None and tmsym not in store.checking
        ):
            _, store = infer_definition(func_type, tmap, store)
            return store
    return store


def inference_group(node, store):
    """The definitions worked out together with node: the ones in its
    block that it and they mutually depend on -- its strongly connected
    component in the block's call graph.

    Only those. A sibling node merely *calls* is worked out and
    generalised first, on demand, so it is polymorphic by the time this
    body uses it; grouping it in here instead would hold it to one type
    for the whole group, which is the difference between `let`-bound and
    lambda-bound in Hindley-Milner and the reason `id` may serve two
    types inside one caller. SFunctionDef -> Store -> [SFunctionDef]"""
    siblings = [other for other in store.groups.get(node.sym, [node])
                if instance_of(store, other.sym) is None
                and other.sym not in store.checking]
    if node not in siblings:
        return [node]
    by_name = {other.name: other for other in siblings}
    calls = {other.sym: {by_name[name].sym
                         for name in names_used(other.body)
                         if name in by_name}
             for other in siblings}

    def reaches(start):
        seen, waiting = set(), [start]
        while waiting:
            one = waiting.pop()
            for next_one in calls.get(one, ()):
                if next_one not in seen:
                    seen.add(next_one)
                    waiting.append(next_one)
        return seen

    forward = reaches(node.sym) | {node.sym}
    return [other for other in siblings
            if other.sym in forward and node.sym in reaches(other.sym) | {other.sym}]


def names_used(body):
    """Every name a body reads. Used to find which definitions of a
    block name each other, so only those are worked out as one.
    [Stmt] -> {String}"""
    return {node.name for node in analyses_walk(body) if isinstance(node, EVar)}


def monotypes_for(group, store):
    """One `(?a, ?b, ...) -> ?r` per definition in the group, all of
    whose variables are fresh. These are what the group's names mean
    while its bodies are checked. [SFunctionDef] -> Store
    -> ([TFunction], Store)"""
    monotypes = []
    for node in group:
        metas, store = fresh_metas(len(node.params) + 1, node.info, store)
        monotypes.append(TFunction(node.info, metas[:-1], metas[-1]))
    return monotypes, store


def required(store, wanted, supplied, node):
    """store in which the body of node supplies `wanted`. Raises
    TypeError_ where nothing makes it so -- which, since `wanted` is
    this inference's own metavariable, means the body's own ways out
    disagreed. Store -> Type -> Type? -> SFunctionDef -> Store"""
    if supplied is None:
        # Nothing ever comes out of this body: every way through it is a
        # `break`, a `continue`, or a loop that never ends. Whatever the
        # caller wants of it is fine.
        return store
    answer = unify(wanted, supplied, store)
    if answer is None:
        raise TypeError_(
            node.info,
            f"'{node.name}' has to return {shown(wanted, store)}, "
            f"but its body ends in a value of type "
            f"{shown(supplied, store)}",
        )
    return answer


def body_result(node, env, tmap, store):
    """What a function's body supplies: every `return` in it and the
    value it ends in, which have to be one type.
    SFunctionDef -> Env -> {Int: Type} -> Store -> (Type?, Store)"""
    started = with_frame(store, replace(store.frame, returns=()))
    supplied, ended = supplied_type(node, env, tmap, INFERRING, started)
    collected = list(ended.frame.returns)
    if supplied is not None:
        # The body's tail position supplies a value too, and it answers
        # the same question a `return` does (PYKING.md, "Tail position").
        collected.append(Given(node.body[-1].info, supplied))
    restored = with_frame(ended, replace(ended.frame, returns=store.frame.returns))
    if not collected:
        return None, restored
    return one_type(collected, node.name, restored)


def supplied_type(node, env, tmap, return_type, store):
    """What a function body supplies: its last statement's value.
    SFunctionDef -> Env -> {Int: Type} -> Type? -> Store -> (Type, Store)"""
    # A body is checked with no enclosing loop: a `break` may not cross
    # a `def`, so one written here belongs to nothing.
    return check_stmts(node.body, env, tmap, return_type, None, store)


def one_type(given, name, store):
    """The single type every way out of a body gives, and the store that
    makes them one. Each is unified with the ones before it, so a base
    case returning `[]` settles against a branch returning `[Int]`; two
    that cannot be one type are refused at the later one. At least one
    is required. [Given] -> String -> Store -> (Type, Store)"""
    first, *rest = given
    worth = first.type
    for later in rest:
        both, store = agree(worth, later.type, store)
        if both is None:
            raise TypeError_(
                later.info,
                f"'{name}' gives {shown(worth, store)} on one "
                f"path, but {shown(later.type, store)} on this "
                f"one; a function has one return type",
            )
        worth = both
    return worth, store


def record(tmap, sym, type_, store):
    """Records a node's type in tmap, with every metavariable in it
    replaced by what it was solved to and any left over shown as the
    variables they are. Overwrites: a body checked twice -- once to work
    it out and once to verify -- reports the second answer.
    The one place in this module that mutates rather than returns a new
    value, since tmap is the pass's result.
    {Int: Type?} -> Int -> Type? -> Store -> ()"""
    if type_ is None:
        return
    tmap[sym] = zonk(type_, store)


def displayed(type_, store):
    """type_ with the metavariables nothing solved named `a`, `b`, ...
    A metavariable is not a type anyone can write, but one left open
    stands for a type nothing decided -- which is what a variable says,
    and which is what `[]` on its own is worth. Type -> Store -> Type"""
    open_metas = metas_in(type_, store)
    if not open_metas:
        return type_
    taken, names, chosen = names_in(type_), [], {}
    for meta in open_metas:
        if meta in store.captured:
            # An enclosing scope's, so not this type's to name: `?`,
            # which prints as no annotation at all rather than as a
            # variable claiming to be anyone's to choose.
            chosen[meta] = TUnknown(type_.info)
            continue
        name = next_name(len(names), taken | set(names))
        names.append(name)
        chosen[meta] = TVar(type_.info, name, rigid=False)
    return substitute(type_, chosen)


def satisfies(expected, actual, store):
    """The store in which `actual` supplies what `expected` wants, or
    None. `unify` first -- anything still open is settled by the demand
    -- and `accepts` after it, for the one thing unification does not
    do: use a scheme at an instance of itself.
    Type? -> Type? -> Store -> Store?"""
    if actual is None:
        # The statement supplying this never falls through, so no value
        # arrives and there is none to be wrong.
        return store
    answer = unify(expected, actual, store)
    if answer is not None:
        return answer
    return store if accepts(zonk(expected, store), zonk(actual, store)) else None


def shown(type_, store):
    """type_ as an error message should name it: solved as far as the
    store goes, with anything still open named `a`, `b`, ... A
    metavariable's own name is bookkeeping and must never reach a
    message. Type -> Store -> String"""
    return pprint_type(displayed(zonk(type_, store), store))


def shown_nested(type_, store):
    """`shown`, parenthesised where a bare function type would read
    wrongly beside other text. Type -> Store -> String"""
    return pprint_type_nested(displayed(zonk(type_, store), store))


def accepts(expected, actual):
    """Whether a value of type actual may be used where expected is
    wanted, deciding nothing: this is `same_type` plus the one place a
    scheme is used at an instance of itself.

    Where a type is still open, `unify` is what answers instead --
    `accepts` is for the two places nothing may be solved: an annotation
    the source wrote, and `verified`'s re-check with the variables
    rigid.
    Type? -> Type? -> Bool"""
    if actual is None:
        # The statement supplying this never falls through, so no value
        # arrives and there is none to be wrong.
        return True
    match (expected, actual):
        case (TForall(_, _, body), _) if not isinstance(actual, TForall):
            # The outermost `all` of a written annotation says the type
            # is polymorphic; whether a value is, is decided by the body
            # with its variables rigid.
            return accepts(body, actual)
        case (_, TForall(_, vars, body)) if not isinstance(expected, TForall):
            # The other way round: a polymorphic value stands wherever
            # one of its instances is wanted, since every instance of it
            # exists.
            return instance_for(body, expected, set(vars), {}) is not None
    return same_type(expected, actual)


def instance_for(general, wanted, quantified, chosen):
    """The bindings that make `general` -- the body of a polymorphic
    type -- into `wanted`, or None where no instantiation of it does.
    One way and with no solver, exactly as `match_type` decides a call:
    a variable is settled the first time it is met and has to agree with
    every later meeting. A `?` in `wanted` is a demand nothing has made
    yet, so it decides nothing and refuses nothing.
    Type -> Type -> {String} -> {String: Type} -> {String: Type}?"""
    if isinstance(wanted, TUnknown):
        return chosen
    match (general, wanted):
        case (TVar(_, name, _, _), _) if name in quantified:
            earlier = chosen.get(name)
            if earlier is None:
                return {**chosen, name: wanted}
            return chosen if same_type(earlier, wanted) else None
        case (TList(_, element, _), TList(_, other, _)):
            return instance_for(element, other, quantified, chosen)
        case (TTuple(_, mine, _), TTuple(_, theirs, _)) if len(mine) == len(theirs):
            for one, other in zip(mine, theirs):
                chosen = instance_for(one, other, quantified, chosen)
                if chosen is None:
                    return None
            return chosen
        case (TFunction(_, mine, my_result, _, _, _),
              TFunction(_, theirs, their_result, _, _, _)) if (
            len(mine) == len(theirs)
        ):
            for one, other in zip(mine, theirs):
                chosen = instance_for(one, other, quantified, chosen)
                if chosen is None:
                    return None
            return instance_for(my_result, their_result, quantified, chosen)
    return chosen if accepts(general, wanted) else None


def unreachable_name(module, name, env):
    """Why `module.name` names nothing: either no module is in scope
    under that name, or the one that is does not export it.
    String -> String -> Env -> String"""
    if not any(bound.startswith(f"{module}.") for bound in env):
        return (
            f"unbound name '{module}.{name}': no module is imported under "
            f"the name '{module}'"
        )
    return f"module '{module}' does not export '{name}'"


def check_call(call, env, tmap, store):
    """ Type check a function call.
    ECall -> Env -> {Int:Type} -> Store -> (Type, Store)"""
    match call.func:
        case EVar(_, name, _) if name in env:
            match env[name]:
                case TBuiltin(_, builtin):
                    return check_builtin_call(builtin, call, env, tmap, store)
    func_type, store = check_expr(call.func, env, tmap, store)
    match settled_type(func_type, store):
        case TFunction(_, _, _, _, _, SFunctionDef()) as deferred:
            # Nothing has worked this definition out yet, so this call is
            # what makes it happen. Its body decides its type, and this
            # call is then checked against that like any other.
            return infer_call(deferred, call, env, tmap, store)
        case settled:
            return called_at(settled, call, call.args, env, tmap, store)


def settled_type(func_type, store):
    """What a deferred function turned out to be, once something has
    worked it out. A definition is worked out once
    (docs/type_inference.md, "One answer per definition"), so from the
    second call on it is an ordinary scheme, read back through whatever
    has since been solved.

    The type is pruned first, so a definition reached through a
    metavariable that has since been solved to it -- a function put in a
    list and taken out again -- is seen for what it is rather than for
    the variable it arrived in. Type -> Store -> Type"""
    func_type = prune(func_type, store)
    match func_type:
        case TFunction(_, _, _, _, tmsym, SFunctionDef()):
            instance = instance_of(store, tmsym)
            if instance is not None:
                return zonk(instance.type, store)
    return func_type


def called_at(scheme, call, args, env, tmap, store):
    """One call to something of known type: the type it is worth, and
    the store in which the arguments fit its parameters.

    The scheme is *instantiated* first, so a polymorphic function is
    used at one of its instances and each call picks its own -- which is
    what lets one definition serve two callers at two types. Each
    argument is then unified with its parameter, left to right, so the
    first mistake is the one reported.
    Type -> ECall -> [Expr] -> Env -> {Int: Type} -> Store
    -> (Type, Store)"""
    used, store = instantiate(scheme, store)
    used = prune(used, store)
    if is_meta(used):
        # Calling something nothing has decided is what decides it: it
        # is a function of this many arguments, and the arguments and
        # the result say the rest. This is the one place a type is
        # *built* by a demand rather than compared against one.
        made, store = fresh_metas(len(args) + 1, call.info, store)
        used = TFunction(call.info, made[:-1], made[-1])
        store = unify(prune(scheme, store), used, store)
    if not isinstance(used, TFunction):
        raise TypeError_(
            call.info,
            f"this call applies something of type "
            f"{shown(used, store)}, which is not a function",
        )
    if len(args) != len(used.params):
        expected, given = len(used.params), len(args)
        raise TypeError_(
            call.info,
            f"this function takes {expected} argument{'' if expected == 1 else 's'}, "
            f"but {given} {'was' if given == 1 else 'were'} given",
        )
    store = check_arguments(args, used.params, env, tmap, store)
    return used.result, store


def check_arguments(args, declared, env, tmap, store, position=1):
    """Checks each argument against its parameter, left to right (so the
    first mistake is the one reported), and answers the store in which
    they fit. [Expr] -> [Type] -> Env -> {Int: Type} -> Store -> Int
    -> Store"""
    match (args, declared):
        case ([], _):
            return store
        case ([arg, *rest], [expected, *rest_declared]):
            actual, store = check_expr(arg, env, tmap, store)
            store = fitted(expected, actual, arg, position, tmap, store)
            return check_arguments(
                rest, rest_declared, env, tmap, store, position + 1
            )


def fitted(expected, actual, arg, position, tmap, store):
    """The store in which one argument fits one parameter, or a
    TypeError_ naming both.

    An argument that is itself polymorphic is *instantiated* wherever
    the parameter is not written polymorphic: every instance of it
    exists, so it stands where one of them is wanted, and it is the
    instance that has to fit. Where the parameter *is* written
    `(all a. ...)` the argument has to be that scheme whole, which is
    first-class polymorphism and the one place the two are compared as
    schemes. Type -> Type -> Expr -> Int -> Store -> Store"""
    settled = prune(expected, store)
    store = work_out(actual, tmap, store)
    actual = settled_type(actual, store)
    if not isinstance(settled, TForall):
        actual, store = instantiate(actual, store)
    answer = unify(settled, actual, store)
    if answer is None:
        raise argument_error(position, actual, settled, arg, store)
    return answer


def argument_error(position, actual, expected, arg, store):
    """The TypeError_ for an argument that does not match the declared
    parameter type. The two are named together, so a variable standing
    in both reads as the same letter in both.
    Int -> Type -> Type -> Expr -> Store -> TypeError_"""
    together = displayed(
        TTuple(arg.info, [zonk(actual, store), zonk(expected, store)]), store)
    return TypeError_(
        arg.info,
        f"argument {position} has type {pprint_type_nested(together.elements[0])}"
        f", but {pprint_type_nested(together.elements[1])} was expected",
    )


def check_builtin_call(name, call, env, tmap, store):
    """A call to print, str, len or range, checked by its own rule since
    none of them has a TFunction type (PYKING.md, "Builtins"). String ->
    ECall -> Env -> {Int: Type} -> Store -> (Type, Store)"""
    args, store = check_each(call.args, env, tmap, store)
    args = [zonk(arg, store) for arg in args]

    match (name, args):
        case ("print", _):
            return unit(call.info), store

        case ("str", [value]):
            check_builtin_arity(name, call, 1, 1)
            if not every(value, (TInt, TString, TBool, TList, TTuple)):
                raise builtin_argument_error(
                    name, call.args[0], value,
                    "Int, String, Bool, a list or a tuple",
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
    """Whether type_ is one of kinds. A flexible variable counts as any
    of them, since no value of it arrives. Type -> (type,) -> Bool"""
    return isinstance(type_, kinds) or is_meta(type_)


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
    EDiv: ("/", [(TInt, TInt)]),
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


def agree(first, second, store):
    """The one type two branches both have, and the store that makes it
    so, or (None, store) where nothing does.

    Two branches of one `if` yield one value, so they are the same type
    -- which `unify` decides, and which is also what settles a base case
    returning `[]` against a branch returning `[1]`: the empty list's
    element is a metavariable, and being one type with `Int` solves it.
    A branch that never falls through is written `None` and leaves the
    answer to the other one.
    Type? -> Type? -> Store -> (Type?, Store)"""
    if first is None:
        return second, store
    if second is None:
        return first, store
    answer = unify(first, second, store)
    if answer is None:
        return None, store
    return zonk(first, answer), answer


def fits(operand, type_):
    """Whether an operand of this type may stand where the signature
    wants `operand`. A metavariable fits every one of them -- nothing
    has decided it yet, and an operator is the kind of demand a body may
    make of a parameter it never annotated. `verified` is what stops
    that being generalised into a promise the body cannot keep
    (docs/type_inference.md, "What is left of ad-hoc polymorphism").
    type -> Type -> Bool"""
    return isinstance(type_, operand) or is_meta(type_)


def check_binary(expr, env, tmap, store):
    """The type of a binary operator application, from OPERATORS.

    **Every operator Pyking has takes two operands of one type**, so
    they are unified first and the table is then asked about that one
    type. Doing it the other way round -- trying each signature against
    each operand -- would pick the first row a still-open operand
    happened to fit, and pin two types that had said nothing to
    whichever row the table lists first.
    Expr -> Env -> {Int: Type} -> Store -> (Type, Store)"""
    spelling, signatures = OPERATORS[type(expr)]
    left_type, store = check_expr(expr.left, env, tmap, store)
    right_type, store = check_expr(expr.right, env, tmap, store)
    together = unify(left_type, right_type, store)
    if together is not None:
        common = prune(left_type, together)
        answer, after = operator_result(expr, common, signatures, together)
        if answer is not None:
            return answer, after
    raise operator_error(expr, spelling, signatures, left_type, right_type, store)


def operator_result(expr, common, signatures, store):
    """What an operator is worth over two operands of type `common`, and
    the store that says so -- (None, store) where the operator does not
    accept it.
    Expr -> Type -> [(type, type)] -> Store -> (Type?, Store)"""
    if isinstance(expr, EConcat):
        # `++` is the one whose result the table cannot state: String ++
        # String is String and [a] ++ [a] is [a], so either way it is
        # what both operands are -- which is also the answer while
        # nothing has decided which of the two this is.
        if isinstance(common, (TString, TList)) or is_meta(common):
            return zonk(common, store), store
        return None, store
    results = {result for _, result in signatures}
    if is_meta(common):
        if len(signatures) == 1:
            # One row, so the operands have to be what it says.
            operand, result = signatures[0]
            return result(expr.info), unify(operand(expr.info), common, store)
        if len(results) == 1:
            # Several rows agreeing on the result -- `==` -- so this is
            # worth that whichever row it turns out to be, and nothing
            # here has to decide which.
            return results.pop()(expr.info), store
        return None, store
    for operand, result in signatures:
        if isinstance(common, operand):
            return result(expr.info), store
    return None, store


def operator_error(expr, spelling, signatures, left_type, right_type, store):
    """The TypeError_ for an operator applied to what it does not
    accept, naming what it does.
    Expr -> String -> [(type, type)] -> Type -> Type -> Store
    -> TypeError_"""
    accepted = " or ".join(
        f"{name} {spelling} {name}"
        for name in (pprint_type(operand(expr.info)) for operand, _ in signatures)
    )
    if isinstance(expr, EConcat):
        accepted += " or two lists of one type"
    together = displayed(
        TTuple(expr.info, [zonk(left_type, store), zonk(right_type, store)]),
        store)
    mine, theirs = together.elements
    return TypeError_(
        expr.info,
        f"`{spelling}` cannot be applied to {pprint_type(mine)} and "
        f"{pprint_type(theirs)}; it accepts {accepted}"
        + alternative(expr, zonk(left_type, store), zonk(right_type, store)),
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
                element, store = demand_list(
                    sequence_type, info,
                    "a comprehension walks a list, but this one", store)
                env, store = check_pattern(pattern, element, env, tmap, store)
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


def check_pattern(pattern, type_, env, tmap, store):
    """The environment a pattern binds and the store in which the value
    it matches has the shape it looks at. A pattern is a *demand*: what
    it takes apart, the subject has to be, which `unify` decides -- so a
    pattern is also how the type of something still open is settled.
    Raises TypeError_ for a pattern that could never match.
    Pattern -> Type -> Env -> {Int: Type} -> Store -> (Env, Store)"""
    match pattern:
        case PWildcard():
            record(tmap, pattern.sym, type_, store)
            return env, store
        case PCapture(_, name, _):
            record(tmap, pattern.sym, type_, store)
            return bind(env, name, type_), store
        case PInt(info, _, _):
            store = pattern_shape(TInt(info), type_, info, store)
        case PString(info, _, _):
            store = pattern_shape(TString(info), type_, info, store)
        case PBool(info, _, _):
            store = pattern_shape(TBool(info), type_, info, store)
        case PTuple(info, elements, _):
            parts, store = fresh_metas(len(elements), info, store)
            store = pattern_shape(TTuple(info, parts), type_, info, store)
            record(tmap, pattern.sym, zonk(type_, store), store)
            for element, part in zip(elements, parts):
                env, store = check_pattern(element, part, env, tmap, store)
            return env, store
        case PText(info, _, name, _, _):
            # A string split around a fixed beginning and end. The middle
            # is a String like the whole, so there is one type here and
            # nothing to take apart.
            store = pattern_shape(TString(info), type_, info, store)
            record(tmap, pattern.sym, zonk(type_, store), store)
            if name is not None:
                env = bind(env, name, TString(info))
            return env, store
        case PList(info, prefix, rest, suffix, _):
            element, store = fresh_meta(info, store)
            store = pattern_shape(TList(info, element), type_, info, store)
            record(tmap, pattern.sym, zonk(type_, store), store)
            for one in list(prefix) + list(suffix or []):
                env, store = check_pattern(one, element, env, tmap, store)
            match rest:
                case ListRest(_, name, _) if name is not None:
                    # The rest of a list is a list of the same elements.
                    env = bind(env, name, zonk(type_, store))
            return env, store
        case _:
            unsupported(pattern)
    record(tmap, pattern.sym, zonk(type_, store), store)
    return env, store


def pattern_shape(wanted, type_, info, store):
    """The store in which what a pattern matches has the shape the
    pattern looks at. Type -> Type -> Info -> Store -> Store"""
    answer = unify(wanted, type_, store)
    if answer is None:
        raise TypeError_(
            info,
            f"this pattern matches {pprint_type(wanted)}, but it is matched "
            f"against {shown(type_, store)}",
        )
    return answer


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
    Three more ways: both of a Bool's values; -- the one every
    recursion over a list is written with -- exact lengths 0 up to k-1
    plus one pattern with a rest marker that takes k or more; and a
    column of tuples that covers while every other column matches
    anything (`covers_column`). The question is
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
    return covers_column(patterns)


def covers_column(patterns):
    """Whether a list of tuple patterns covers because *one* of its
    columns does, every other column matching anything in every pattern.

    A tuple's shape is fixed by its type, so `(a, true)` and `(a, false)`
    between them take every `(Int, Bool)` for exactly the reason `true`
    and `false` take every Bool -- and the first column, matching
    anything either way, cannot rule any value out. Restricting it to
    one refutable column is what keeps this sound without a full
    decision procedure: two columns that only cover *together*, such as
    `(true, true)`, `(true, false)` and `(false, _)`, are answered no,
    which asks for an arm that is not needed rather than accepting a
    `match` with a hole in it. [Pattern] -> Bool"""
    if not patterns or not all(isinstance(p, PTuple) for p in patterns):
        return False
    arity = len(patterns[0].elements)
    if any(len(p.elements) != arity for p in patterns):
        return False
    for column in range(arity):
        elsewhere = [i for i in range(arity) if i != column]
        if all(irrefutable(p.elements[i]) for p in patterns for i in elsewhere):
            if covers([p.elements[column] for p in patterns]):
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


def check_annotation(annotation, actual, store):
    """Checks a binding's annotation, if any, against its right-hand
    side's actual type, and answers the store that makes them one. An
    annotation is a *demand*, so a right-hand side still open is settled
    by it -- `xs: [Int] = []` says what the empty list holds. The
    annotation is quantified first, since a written type is quantified
    wherever one is written. Raises TypeError_ at the annotation on a
    mismatch. Type? -> Type -> Store -> Store"""
    if annotation is None:
        return store
    annotation = generalize(annotation, annotation.info)
    answer = unify(annotation, zonk(actual, store), store)
    if answer is not None:
        return answer
    if accepts(annotation, zonk(actual, store)):
        return store
    raise TypeError_(
        annotation.info,
        f"this binding is annotated {pprint_type_nested(annotation)}, but "
        f"its value has type {shown_nested(actual, store)}",
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
        case (TUnknown(), TUnknown()):
            # Two types nothing has decided are the same lack of a
            # decision -- which is what makes an incomplete function type
            # equal to itself, and so findable in `recall`'s cache.
            return True
        case (TList(_, x), TList(_, y)):
            return same_type(x, y)
        case (TTuple(_, xs), TTuple(_, ys)):
            return len(xs) == len(ys) and all(map(same_type, xs, ys))
        case (TFunction(_, ps, r), TFunction(_, qs, s)):
            # A function *is* its parameters and its result. The other
            # three fields -- the symbol, the definition it came from,
            # and the body still to be checked -- say where a type was
            # written and what is left to do about it, neither of which
            # is part of what it means (see src/syntax.py).
            return (len(ps) == len(qs) and all(map(same_type, ps, qs))
                    and same_type(r, s))
        case (TVar(_, x, _, True), TVar(_, y, _, True)):
            # A variable is rigid: inside a body it stands for a type the
            # caller picked, so it is the same type as itself and nothing
            # else. That is the whole of what makes a polymorphic body
            # honest -- no substitution is needed to enforce it.
            return x == y
        case (TVar(_, mine, _, False), TVar(_, theirs, _, False)):
            # A flexible one is not named by the source, so what tells
            # two apart is which handing-out made them -- which is what
            # its name records, since each is handed out once. A
            # flexible and a rigid variable are never the same type,
            # whatever they are called.
            return mine == theirs
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
