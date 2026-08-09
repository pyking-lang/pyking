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
latter asks `tmap` for it. `src/pyk.py` hands the finished `tmap` to
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
`if` statements and function definitions. A binding takes its right-hand
side's type, and an annotation it wrote is checked against that rather
than replaced by it (`check_annotation`). Expressions are integer,
string and boolean literals, names bound earlier, calls of a
function-typed name, and:

    +          Int + Int -> Int,  String + String -> String  (overloaded)
    - *        Int -> Int
    < <= > >=  Int, Int -> Bool
    ==         Int, String or Bool, both sides alike -> Bool

Every other construct -- `var`, `for`, `while`, `match`, lists, tuples,
comprehensions, `/` -- is refused with `Construct is not supported`
against its own source position. That is a *deliberate* floor rather
than a gap to paper over: a checker that quietly accepted what it had
not reasoned about would be worse than one that says where it stops.

### Functions, and the two places one can be checked

A `def` that annotated *everything* -- every parameter and the return
type -- is checked where it is written. Its type is then
`(P1, P2, ...) -> R`, a `TFunction`, and that is what its name means to
the statements that follow it.

A body supplies that return type in either of the two ways PYKING.md's
"Tail position" describes, and they mix: a `return`, or a last statement
that is simply an expression of the right type, or some branches doing
one and some the other. One rule covers all of it, because every
statement is asked the same question -- *what value do you supply?* --
and `return e` answers "e's", exactly as the tail-position table says.
A body that supplies nothing, or the wrong thing, is refused: a function
that says `-> Int` and does neither has a type it does not honour.

Recursion needs nothing beyond the declaration pass: the function's own
type is in scope while its body is checked, so a recursive call is
checked against it argument by argument, like any other call.

A `def` that did **not** annotate everything is not checked where it is
written at all. It is declared with `TUnknown` in place of whatever it
did not say, and checked the first time something *calls* it, with its
parameters taken from that call -- the same functions, in the same
order, with the call supplying what the source did not. That is the
whole of the inference in this module: there is no second pass, no
constraint store and no unification, which is what keeps every error a
sentence about one place. `TOr` (`Int | String`) is how a function used
at two types is summarised, since there are no type variables.

The pieces are the **`Store`** (everything inference has worked out --
where each definition was written, what has been inferred about it, what
is being checked right now, and what the current inference has gone
through), `_Recursive` (the signal that a trace has reached the very
function it is working out), `infer_call`/`infer_body`/`trace` (the check
itself, and the second trace a recursion needs), and
`merge`/`accepts`/`resolved` (alternatives). `docs/type_inference.md`
explains why each of them is shaped the way it is, and what was rejected.

## Nothing here changes anything

One rule holds throughout this module, and it is worth stating because
the inference half looks at first like the kind of thing that needs
state: **no value is written to after it is built.** An environment, a
store, a type, an instance -- each is handed on, extended by being
rebuilt, and left alone by whoever passed it. A function that is given a
store returns one, because what it worked out is knowledge its caller
needs; a function that is given an environment does not, because a
block's bindings are its own.

The single exception is `tmap`, and it is deliberate: it is the pass's
*result*, a table filled in as the walk goes, and threading a second one
through every function to build it functionally would put machinery in
front of the rules for no gain. `record` is the only function that
writes.

That rule is what makes this pass explainable. Everything a call knows
came to it in its arguments; nothing arrives by having been left
somewhere earlier.

## Names and scoping

`--typecheck` runs *instead of* the name analysis, not after it (see
`src/pyk.py`), so this pass is on its own about names -- and checks
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
than as unbound. Nothing produces one today: a `def` that annotated
nothing gets an incomplete `TFunction` rather than no type at all, and
the builtins are `Builtin`s. It is kept as the floor for whatever the
checker reaches next.

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

from dataclasses import dataclass, replace

from analyses import AnalysisError, BUILTINS, block_functions
from lexer import Info
from syntax import (
    pprint_type,
    EInt, EString, EBool, EVar, EAdd, ESub, EMul, ECall, EIf,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq,
    SLet, SLetStmt, SExprStmt, SIf, SReturn, SReturnStmt, SFunctionDef,
    Type, TInt, TString, TBool, TList, TTuple, TFunction, TOr, TUnknown,
    TargetName,
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
#     val type_check         : [Stmt] -> TMap
#     val check_stmts        : [Stmt] -> Env -> TMap -> Type? -> Store
#                              -> (Type, Store)
#     val check_stmt         : Stmt -> Env -> TMap -> Type? -> Store
#                              -> (Type, Env, Store)
#     val check_expr         : Expr -> Env -> TMap -> Store -> (Type, Store)
#     val check_param        : Param -> TMap -> Store -> Type
#     val check_function     : SFunctionDef -> Env -> TMap -> Store
#                              -> (Type, Store)
#     val check_call         : ECall -> Env -> TMap -> Store -> (Type, Store)
#     val check_binary       : Expr -> Env -> TMap -> Store -> (Type, Store)
#     val check_annotation   : Type? -> Type -> ()
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
    """Raised for a type error, or for a construct this checker does not
    cover. Carries the source position, like `LexError`/`ParseError`/
    `AnalysisError` do for their own stages, so `pyk.py` can report
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


@dataclass(frozen=True)
class Instance:
    """One shape a deferred function has already been checked at.

    Three things that look alike and are not, which is why they are named
    separately here rather than being one list of pairs:

        params    what was *passed* -- the cache key, compared with
                  `same_instance`, and kept exactly as it arrived so that
                  a later call passing the same things finds it
        result    what came back, also as it arrived: a caller may want
                  to call it in turn, which needs whatever definition it
                  carries
        reported  the same call with everything that has since been
                  worked out filled in -- what `resolved` shows for the
                  function, and what a reader sees
        uses      which instances of which other functions this call went
                  through, so that a *later* call that reuses this answer
                  inherits what it was based on

    `params` and `reported` differ exactly when an argument was itself a
    function nobody had worked out yet: the key remembers *which*
    function was passed, and the report remembers what it turned out to
    be at that call."""
    params: list
    result: Type
    reported: Type
    uses: tuple


@dataclass(frozen=True)
class Use:
    """One instance of one deferred function, gone through by an
    inference.

    A definition is named by `tmsym`, the symbol of its `def`, and an
    instance by where it sits in that definition's list -- two integers,
    so a use is a value that can be compared and put in a tuple without
    anything being asked about object identity."""
    tmsym: int
    index: int


@dataclass(frozen=True)
class Frame:
    """What the inference currently in progress has gathered: the
    instances it has gone through, and what its `return`s have supplied.

    One frame per inference, replaced when one starts and restored --
    simply by using the outer store again -- when it ends."""
    uses: tuple = ()
    returns: tuple = ()


@dataclass(frozen=True)
class Store:
    """Everything inference has worked out, as one value.

    It is threaded through this pass exactly as `env` is, and for exactly
    the same reason: what a function knows is decided by what it was
    handed, and a table that changed under its readers could not say
    that. Four fields, and each of them replaced a mutation that used to
    happen inside a record reachable from a type:

        environments  tmsym -> the environment that `def` was *written*
                      in, which is where its body is checked from
                      wherever it is called
        instances     tmsym -> what has been worked out about it, in the
                      order it was worked out; `Use.index` points into
                      this
        checking      the definitions whose bodies are being checked
                      right now, which is how a recursive call is
                      recognised as one
        frame         the innermost inference's `Frame`

    Nothing here is ever written to. An update builds a new `Store` with
    the one field replaced -- `{**old, key: value}` for the two tables,
    the same discipline `bind` uses for environments."""
    environments: dict
    instances: dict
    checking: frozenset
    frame: Frame


def empty_store():
    """The store a program starts checking in: nothing worked out, and
    nothing in progress."""
    return Store({}, {}, frozenset(), Frame())


def with_environment(store, tmsym, env):
    """`store` recording where a definition was written.

    Written twice for the same definition: once when its block declares
    it, with the environment at the block's start, and once when its own
    statement is reached, with the environment there -- which is the one
    the language says its body captures. The second replaces the first,
    and because the key is the definition's symbol rather than an object,
    every type that names that definition sees the newer answer without
    anything having been mutated under it."""
    return replace(store, environments={**store.environments, tmsym: env})


def environment_of(store, tmsym):
    """Where that definition was written, or `None` if nothing has said
    -- which only happens if a call is checked before the block that
    declares it."""
    return store.environments.get(tmsym)


def instances_of(store, tmsym):
    """What has been worked out about that definition, oldest first."""
    return store.instances.get(tmsym, ())


def remembering(store, tmsym, instance):
    """`store` with one more thing worked out about a definition."""
    return replace(
        store,
        instances={**store.instances, tmsym: instances_of(store, tmsym) + (instance,)},
    )


def instance_at(store, use):
    """The instance a use points at."""
    return instances_of(store, use.tmsym)[use.index]


def checking_now(store, tmsym):
    """`store` in which that definition's body is being checked. The
    caller keeps the store *without* it, which is how the mark comes off
    again -- there is nothing to undo."""
    return replace(store, checking=store.checking | {tmsym})


def with_frame(store, frame):
    """`store` gathering into a different frame -- a fresh one when an
    inference begins."""
    return replace(store, frame=frame)


def returning(store, type_):
    """`store` whose frame has seen a `return` of this type."""
    return with_frame(store, replace(store.frame, returns=store.frame.returns + (type_,)))


def noting(store, uses):
    """`store` whose frame records that the inference in progress went
    through these instances, in the order it first went through them and
    without repeating one.

    Order matters: it is the order the alternatives of an inferred type
    are printed in."""
    fresh = tuple(use for use in uses if use not in store.frame.uses)
    return with_frame(store, replace(store.frame, uses=store.frame.uses + fresh))


def learned(store, inner):
    """`store` with what an inner check found out, and nothing else.

    The two tables are *knowledge* -- true whoever asked -- so they come
    back out of a nested inference. The other two fields are *context*:
    which definitions the caller was in the middle of, and what the
    caller was gathering. Those revert by simply using the caller's
    store, which is the one line where this rewrite differs from the
    flags-and-`finally` it replaced."""
    return replace(store, environments=inner.environments, instances=inner.instances)


@dataclass(frozen=True)
class Inferring:
    """Stands in for a declared return type while one is being worked
    out. A `return` checked against this contributes its type to the
    store's frame instead of being compared with one, and what a function
    returns is then what its `return`s and its tail position between them
    supply."""


INFERRING = Inferring()


class _Recursive(Exception):
    """Internal signal: this trace has reached a call to a function that
    is already being checked, whose result is exactly what something is
    still trying to work out.

    Not an error -- the program may be perfectly good -- so it never
    reaches a user as one. It is caught by the nearest enclosing `if`,
    whose other branch may well say what the function returns; by a body
    where some `return` has already said it; and, failing both, by
    whichever inference is *waiting* on the function it names, since only
    that one can turn it into a sentence about the program. It carries
    the definition it is about for exactly that reason: in a cycle of
    three functions, the answer has to come from the one the cycle closes
    on, not from whichever one happened to notice.

    It carries the store as well, for a reason particular to a pass that
    threads its state: an exception unwinds past every `store` a caller
    was about to receive, and the one thing a trace needs from an
    abandoned attempt is what its `return`s had already supplied. See
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
    a `Builtin`, which is checked at the call rather than given a type.
    Its store starts empty: nothing has been worked out about anything
    yet, and the store it ends with is discarded too, since what a
    consumer wants is `tmap`."""
    tmap = {}
    check_stmts(stmts, builtin_env(), tmap, None, empty_store())
    return tmap


def builtin_env():
    """The environment a program starts in: every name in
    `analyses.BUILTINS`, each denoting an operation rather than a value.

    Its own function because `type_check` is not the only way in. A
    caller that checks a program a piece at a time -- `src/repl.py`
    checks one entry against the environment the last one left behind --
    needs the same starting point, and building it by hand somewhere else
    is how two ideas of what a program may name start to drift apart."""
    return {name: Builtin(name) for name in BUILTINS}


# --- [Stmt] ----------------------------------------------------------


def declare_functions(stmts, env, store):
    """`env` with every `def` in this block already in scope, before any
    of its statements are checked, and `store` recording where each of
    them was written.

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

    A `def` that is not fully annotated is declared too, with the type it
    has so far: the annotations it did write, `TUnknown` for the rest,
    and the definition itself for later. Nothing about it is checked here
    -- what an unannotated parameter is depends on what is passed to it,
    and that is a call site's business.

    Each deferred definition is recorded against the finished
    environment, so every body of the group sees the whole group; a
    definition's own statement records the environment at its own
    position over the top of it, which is the one the language says its
    body captures.

    `block_functions` is `analyses.py`'s, and applies the two rules that
    make a hoisted name unambiguous -- one `def` per name per block, and
    no other binding of that name in the same block. Sharing it is what
    keeps the two passes from drifting apart about which programs are
    legal, and it raises `AnalysisError`, so the same wording comes out
    whichever pass ran."""
    functions = list(block_functions(stmts).values())
    for function in functions:
        env = bind(env, function.name, declared_type(function))
    for function in functions:
        if not fully_annotated(function):
            store = with_environment(store, function.sym, env)
    return env, store


def fully_annotated(node):
    """Whether a `def` wrote down every parameter type and the return
    type -- the difference between a function this checker can check on
    sight and one it has to wait for a call to explain."""
    return node.return_type is not None and all(p.type is not None for p in node.params)


def declared_type(node):
    """The type a `def` has as far as anyone can tell from the `def`
    itself: its written type when it wrote one, and otherwise an
    incomplete one, with `TUnknown` standing in for what it did not
    say and the `def` node itself in the `definition` field, which is
    what says the type is still a promise."""
    if fully_annotated(node):
        return function_type(node)
    return TFunction(
        node.info,
        [p.type if p.type is not None else TUnknown(p.info) for p in node.params],
        node.return_type if node.return_type is not None else TUnknown(node.info),
        tmsym=node.sym,
        definition=node,
    )


def check_stmts(stmts, env, tmap, return_type, store):
    """The type a block yields: its last statement's, or unit when it is
    empty.

    Only the *last* statement supplies a value, which is what PYKING.md's
    "Tail position" says: a statement in the middle is run for its
    effect, however interesting its type.

    `env` is threaded from one statement to the next, so a binding is
    visible to what follows it -- and the extended environment is
    returned to nobody, which is exactly what makes a block a scope:
    what it binds cannot escape it (`analyses.py` says the same thing
    with `analyze_scope`). `store` is threaded the same way but *is*
    returned: what has been worked out about a function is true wherever
    it was worked out.

    `return_type` is carried through untouched, for whatever `return`
    turns up anywhere inside; see `check_stmt`."""
    env, store = declare_functions(stmts, env, store)
    yielded = unit(stmts[0].info if stmts else Info("<empty>", 1, 0, 1, 0))
    for statement in stmts:
        yielded, env, store = check_stmt(statement, env, tmap, return_type, store)
    return yielded, store


# --- Stmt ------------------------------------------------------------


def check_stmt(statement, env, tmap, return_type, store):
    """One statement: the type of the value it supplies, the environment
    the statements after it are checked in, and the store.

    "Supplies" is PYKING.md's "Tail position" question, asked of every
    statement: in the tail of a function body this is the function's
    value, and anywhere else it is simply ignored. Most statements supply
    nothing and so have type unit; an expression statement supplies its
    expression, an `if` supplies whatever its branches agree on, and a
    `return` supplies what it returns -- which is why nothing special is
    needed to let one branch `return` while the other ends in a value.

    `return_type` is the enclosing function's declared return type,
    `INFERRING` while one is being worked out, or `None` at the top
    level. It is what a `return` is checked against, and it is threaded
    down through every nested block rather than consulted once at the
    end, because only the *last* statement's value reaches
    `check_function`: a `return` written anywhere else -- inside an `if`
    with no `else`, before a later statement -- supplies nothing to the
    body and would otherwise never be checked at all. It is also what
    makes `return` outside a function an error rather than a silent
    nothing."""
    match statement:
        case SLet(info, TargetName(_, name, _), expr, annotation, sym):
            # The binding's symbol records what its right-hand side
            # turned out to be; the binding *itself* is a statement, so
            # it has unit type.
            expr_type_, store = check_expr(expr, env, tmap, store)
            check_annotation(annotation, expr_type_)
            record(tmap, sym, expr_type_, store)
            return unit(info), bind(env, name, expr_type_), store

        case SLetStmt(info, TargetName(_, name, _), stmt, annotation, sym):
            # `x = if c: ...` binds what the branch that runs yields, so
            # the bound statement's own type is the binding's type -- and
            # the branches having agreed on one is what the `SIf` case
            # below has already established.
            bound_type, _, store = check_stmt(stmt, env, tmap, return_type, store)
            check_annotation(annotation, bound_type)
            record(tmap, sym, bound_type, store)
            return unit(info), bind(env, name, bound_type), store

        case SLet() | SLetStmt():
            # A destructuring target (`a, b = ...`) needs tuple types.
            unsupported(statement)

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
                then_body, env, tmap, return_type, store
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
                else_body, env, tmap, return_type, then_store
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
            actual, _, store = check_stmt(stmt, env, tmap, return_type, store)
            return actual, env, check_return(actual, return_type, info, store)

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
    """Refuses an `if` that yields one of two *different* functions
    neither of which wrote its type down.

    They compare equal -- `(?) -> ?` against `(?) -> ?` -- because
    nothing has decided either of them, and taking one to stand for both
    would mean checking the wrong function's body at every later call.
    Since there are no type variables to say "whichever of the two this
    turns out to be", the honest answer is to say so and ask for an
    annotation. See docs/type_inference.md, "What this does not do"."""
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
    """One branch of an `if` *expression*, as `(type, store, signal)` --
    the same bargain `try_branch` makes for a block, and for the same
    reason.

    A recursive function written as an expression, `def fact(n) = if
    n <= 1 then 1 else fact(n - 1) * n`, has its recursion in a branch of
    an expression rather than of a statement; without this the trace
    would have nowhere to be abandoned and the type could not be worked
    out at all."""
    try:
        type_, store = check_expr(expr, env, tmap, store)
        return type_, store, None
    except _Recursive as signal:
        return None, store, signal


def try_branch(body, env, tmap, return_type, store):
    """One branch of an `if`, as `(type, store, signal)`.

    The signal is the `_Recursive` that stopped the branch, or `None` if
    nothing did. A branch that ran into a call it could not type is
    simply not evidence about anything, and its sibling is asked instead;
    the signal is kept rather than dropped so that, if the sibling cannot
    answer either, the question moves outwards unchanged. The store that
    comes back with a signal is the one the branch *started* from: what
    an abandoned trace worked out was provisional, and the trace that
    replaces it works it out again. Nothing else is caught here: a type
    error in a branch is still a type error."""
    try:
        type_, store = check_stmts(body, env, tmap, return_type, store)
        return type_, store, None
    except _Recursive as signal:
        return None, store, signal


def check_return(actual, return_type, info, store):
    """A `return`, against what the function it is in returns.

    Two cases, and the second is where inference lives: a function that
    *said* what it returns has this compared against that, and one that
    did not has it collected into the store's frame, because what such a
    function returns is whatever its `return`s and its tail position
    supply."""
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
    """The type of one expression, recorded in `tmap` under its symbol.

    Every expression is recorded, not just the annotatable constructs:
    the entry costs nothing to make and is what lets a consumer ask "what
    type is *this* subexpression" -- which `pprint_program` never needs,
    but a backend does. `src/target_ocaml.py` is the first: it compiles
    only what this checker accepts, so rather than inferring types a
    second time it reads them back from here."""
    type_, store = expr_type(expr, env, tmap, store)
    record(tmap, expr.sym, type_, store)
    return type_, store


def expr_type(expr, env, tmap, store):
    """`check_expr` without the recording -- the rules themselves."""
    match expr:
        case EInt(info, _, _):
            return TInt(info), store

        case EString(info, _, _):
            return TString(info), store

        case EBool(info, _, _):
            return TBool(info), store

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
    """A parameter's declared type, recorded under its symbol.

    Only ever called for a parameter that *has* an annotation:
    `function_type` refuses a `def` with any parameter missing one
    before this is reached, since a function whose type is written down
    is checked as a whole or not at all. A parameter with no annotation
    is recorded by `infer_call` instead, once a call has said what it
    is."""
    record(tmap, param.sym, param.type, store)
    return param.type


# --- SFunctionDef ----------------------------------------------------


def function_type(node):
    """ 'function_type' takes a node of form SFunctionDef and
    checks that it is completely annotated with types (both params
    and return type). If not, raises type error. If OK, the
    function returns the function type 'TFunction'"""
    unannotated = [p.name for p in node.params if p.type is None]
    # Comment: It seems unnessary to save all names in the list
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
    """Checks a `def` against its annotations, and returns unit: the
    definition is a statement, whatever the function's own type is."""
    ftype = function_type(node)
    for param in node.params:
        check_param(param, tmap, store)
    record(tmap, node.sym, ftype, store)

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
        actual, store = check_expr(node.expr, body_env, tmap, store)
        if not accepts(node.return_type, actual):
            raise TypeError_(
                node.expr.info,
                f"'{node.name}' returns {pprint_type(node.return_type)}, but "
                f"its body has type {pprint_type(actual)}",
            )
        return unit(node.info), store

    # The body's last statement is the one in tail position, and what it
    # supplies is the function's value -- whether it supplies it with a
    # `return` or by simply being an expression. One check covers both,
    # because `check_stmt` already answers that one question for every
    # kind of statement.
    supplied, store = check_stmts(node.body, body_env, tmap, node.return_type, store)
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
# A function that did not write its type down is checked when something
# calls it, in the environment it was written in, with its parameters
# taken from the call. Everything here is that one idea and what it
# costs: a cache so a function is not checked once per call, a recursion
# guard so a function does not wait for itself, and a second trace for
# the recursion the first one could not see through. See
# docs/type_inference.md.


def infer_call(func_type, params, call, tmap, store):
    """The result of calling a function whose type was not written down,
    with parameters `params` -- what this call is passing it.

    The answer comes from the body, and is remembered in the store, so a
    program that calls a function a hundred times with the same argument
    types checks it once."""
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
    """The use pointing at what was worked out last time this function
    was called with these parameter types, or `None` if it has not been.

    This is the cache the whole scheme leans on: without it a chain of
    calls would re-check the same body once per call, and a recursive one
    would not finish at all.

    The comparison is `same_instance`, *not* `same_type`, and that
    distinction is the whole correctness of the cache. Two functions
    nobody has worked out yet are both `(?) -> ?`, so `same_type` calls
    them equal -- which is right about types and wrong about *things*:
    handing this function `pack_int` and handing it `pack_string` are
    different calls with different answers. A cache keyed on the weaker
    relation returns the first answer for the second call (see
    docs/type_inference.md, "Two functions nobody has worked out yet are
    not the same argument")."""
    for index, instance in enumerate(instances_of(store, tmsym)):
        if len(instance.params) == len(params) and all(
            map(same_instance, instance.params, params)
        ):
            return Use(tmsym, index)
    return None


def same_instance(a, b):
    """Whether two types are the same *thing* to have been passed --
    `same_type`, except that a function still to be worked out is only
    ever the same as itself.

    `same_type` answers a question about the language: two function types
    are the same when their parameters and results are. That is the right
    answer for checking a program and the wrong one for keying a cache,
    because a `TUnknown` is the absence of an answer rather than an
    answer two things can share. Which function it is is said by its
    symbol, so this is a comparison of values throughout."""
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
    """What an argument turned out to be *at this call* -- which is not
    the same question as what it turned out to be overall.

    `id` passed to one function and used there at `Int`, and passed to
    another and used there at `String`, is `(Int) -> Int` in the first
    call and `(String) -> String` in the second; saying `((Int) -> Int) |
    ((String) -> String)` in both would claim each of them accepts what
    only the other does. And a function used *twice* in one body, at
    `Int` and at `Bool`, is both of those in that one call -- so what is
    reported is every instance this call went through, whether this call
    worked it out or found it already worked out.

    A function passed to a call whose body never calls it has taught this
    call nothing, and everything known about it is reported instead: it
    is the best answer available, and the alternative -- `?` -- would say
    less than is known rather than more."""
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
    """What a function's body supplies, when the `def` did not say.

    Three cases, in increasing order of how much work they are.

    A function whose *return* type was written needs no inference of the
    result at all: its own name means `(params) -> declared` while its
    body is checked, so a recursive call is checked like any other, and
    the body is checked against that type exactly as an annotated one is.

    A function with no return type is checked with its `return`s
    collected rather than compared (`INFERRING`). If it does not recurse,
    that one trace is the answer.

    If it does recurse, the first trace cannot type the recursive call --
    it is what is being worked out -- so `_Recursive` is raised there and
    caught at the nearest `if`, or by the trace itself if the `return`s
    already seen say enough. Either way the first trace ends with a
    candidate result, and a *second* trace then checks the whole body
    with the function's own name bound to `(params) -> candidate`. The
    second trace is the one that counts: it is the first one in which
    every path, including the recursive one, has a type."""
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
    """One pass over a body with its `return`s collected: what the
    function supplies, as far as this trace could see.

    A `_Recursive` that reaches here means the recursion was not inside
    an `if` -- a body that returns in one statement and recurses in the
    next, say. The `return`s already collected are then the evidence, and
    they are read off the store the signal carried out, since the
    exception unwound past every store this function was about to be
    handed. A body that collected none has told this trace nothing at
    all, and the question moves outwards."""
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
    """What a function body supplies -- its `= expr` form's expression,
    or what its last statement yields. The same question
    `check_function` asks of an annotated body, asked here of a body
    whose type is being worked out."""
    if node.expr is not None:
        return check_expr(node.expr, env, tmap, store)
    return check_stmts(node.body, env, tmap, return_type, store)


def merge(types):
    """One type covering all of `types`: that type when they agree, and
    an "or" type of the distinct ones when they do not.

    A function that returns an Int on one path and a String on another
    really does return `Int | String`, and saying so is more useful than
    refusing the program -- the mistake, if it is one, then shows up
    where the value is used, in terms of what it is. Nested alternatives
    are flattened, so `Int | (String | Bool)` and `Int | String | Bool`
    are one type written one way.

    Two *function* types are alternatives like anything else. A function
    called with two Ints and then with two Strings is

        ((Int, Int) -> Int) | ((String, String) -> String)

    and emphatically **not** `(Int | String, Int | String) -> Int | String`:
    the second says an Int and a String may be mixed in one call, which
    is a claim the checker does not make and would refuse. Whatever the
    parameters and the result of one call were, they belong together --
    see docs/type_inference.md, "The mistake that made this page
    necessary".

    At least one type is needed; every caller has one."""
    match distinct_types([one for type_ in types for one in alternatives_of(type_)]):
        case [only]:
            return only
        case alternatives:
            return TOr(alternatives[0].info, alternatives)


def alternatives_of(type_):
    """What a type offers as alternatives: an "or" type's, flattened, and
    any other type on its own."""
    match type_:
        case TOr(_, alternatives):
            return [one for alternative in alternatives for one in alternatives_of(alternative)]
    return [type_]


def distinct_types(types):
    """`types` with later duplicates dropped, in the order they were
    given -- which is the order the alternatives of an inferred type are
    printed in."""
    match types:
        case []:
            return []
        case [first, *rest]:
            return [first] + distinct_types(
                [type_ for type_ in rest if not same_type(first, type_)]
            )


def record(tmap, sym, type_, store):
    """Records what a node's type turned out to be. The one thing in this
    module that changes something rather than returning a new one:
    `tmap` is the pass's result, and building it functionally would mean
    threading a second table through everything for no gain.

    Merging rather than overwriting, because a deferred function checked
    at two different argument types has two answers for everything inside
    it, and both are true: what `--typecheck --ast` then shows for such a
    function is `Int | String`, which is what it is used as. A node
    reached once -- every node of an annotated function, and most of a
    program -- merges with nothing and simply records its type."""
    resolved_type = resolved(type_, store)
    existing = tmap.get(sym)
    tmap[sym] = resolved_type if existing is None else merge([existing, resolved_type])


def resolved(type_, store, seen=()):
    """A type as it finally turned out.

    The one thing that can still change after a type is first written
    down is a function that had not been called yet: its parameters were
    `TUnknown` when it was passed around, and are known once something
    called it. What is *recorded* should be what it turned out to be, so
    a program that passes an unannotated function to another one shows
    the types both of them ended up with rather than the question marks
    they started as -- inside a larger type as well as at the top of one,
    which is why this recurses.

    `seen` stops it recursing forever on a function whose own type
    mentions it, which two mutually recursive functions manage between
    them."""
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
    """Whether a value of type `actual` may be used where `expected` is
    wanted.

    The same question as `same_type` for everything except an "or" type,
    which is the point of having one: `Int` is acceptable where
    `Int | String` is wanted, and `Int | String` is not acceptable where
    `Int` is. There is no other subtyping in Pyking."""
    match (expected, actual):
        case (_, TOr(_, alternatives)):
            return all(accepts(expected, alternative) for alternative in alternatives)
        case (TOr(_, alternatives), _):
            return any(accepts(alternative, actual) for alternative in alternatives)
    return same_type(expected, actual)


# --- ECall -----------------------------------------------------------


def check_call(call, env, tmap, store):
    """The type of a call: its function's result, once the arguments have
    been checked against that function's parameters.

    Anything of function type may be called, so a parameter annotated
    `(Int) -> Int` is as callable as a `def`'s own name -- and so is a
    builtin, which is the one callable thing with no type of its own.

    A call is also where a function that did not write its type down
    gets one. Its parameters are whatever this call passes it, its body
    is checked in that light, and what the body supplies is the result
    (see `infer_call`). That is the whole of the deferral: a definition
    says what it can, and a use says the rest."""
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
    """The parameter types for this call, argument by argument, as
    `(params, store)`.

    Each argument is checked and then compared with what the `def` said
    about it before the next one is looked at, so a mistake in the first
    argument is reported before a mistake in the second -- the order a
    reader reads them in."""
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
    """What one parameter is, for this call: what the `def` said it was,
    or -- where it said nothing -- what is being passed to it.

    An annotation is still an annotation: where the `def` wrote one, the
    argument is checked against it and a mismatch is an error, exactly as
    before. Two function types meet in the middle: whatever *both* of
    them know is compared, and the argument's own type is what the body
    then sees, so a function passed to a function is inferred where it is
    finally called rather than guessed at here."""
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
    """What a call says when an argument is not what the `def` asked for.

    One sentence for every kind of mismatch, naming both whole types: a
    reader comparing `(Int) -> Bool` with `(Int) -> Int` can see which
    part differs, and a message that pointed only at the part would have
    hidden which argument and which function it was talking about. A `?`
    in it is a type nothing has decided yet (see
    docs/type_inference.md)."""
    return TypeError_(
        arg.info,
        f"argument {position} has type {pprint_type(actual)}, but "
        f"{pprint_type(expected)} was expected",
    )


def check_compatible(expected, actual, position, arg):
    """Checks that two function types agree about everything they both
    know, and raises if they do not.

    A `TUnknown` on either side agrees with anything, because it is not a
    claim about anything -- it is the absence of one. Everything else is
    compared as usual, so passing a `(String) -> Int` where a
    `(Int) -> Int` was written is still an error, and passing a function
    whose parameter nobody has annotated is still allowed."""
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
    """Whether anything has decided this type yet."""
    match type_:
        case TUnknown():
            return False
    return True


def check_builtin_call(name, call, env, tmap, store):
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
    """Every expression in a list, checked left to right, as their types
    and the store they leave behind.

    Left to right because that is the order Pyking evaluates in, and a
    checker that looked at them in another order could report the second
    mistake in a line before the first."""
    match exprs:
        case []:
            return [], store
        case [first, *rest]:
            type_, store = check_expr(first, env, tmap, store)
            types, store = check_each(rest, env, tmap, store)
            return [type_] + types, store


def every(type_, kinds):
    """Whether a type is one of `kinds` -- and, for an "or" type, whether
    *every* alternative is.

    `str` accepts an `Int` and it accepts a `String`, so it accepts an
    `Int | String`: a value of that type is one or the other, and either
    would do. Asking the question this way is what lets an inferred
    alternative type reach a builtin at all."""
    return all(isinstance(one, kinds) for one in alternatives_of(type_))


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


def check_binary(expr, env, tmap, store):
    """The type of a binary operator application, from `OPERATORS`."""
    spelling, signatures = OPERATORS[type(expr)]
    left_type, store = check_expr(expr.left, env, tmap, store)
    right_type, store = check_expr(expr.right, env, tmap, store)
    for operand, result in signatures:
        if isinstance(left_type, operand) and isinstance(right_type, operand):
            return result(expr.info), store
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
    if annotation is None or accepts(annotation, actual):
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
        case (TUnknown(), TUnknown()):
            # Two types nothing has decided are the same lack of a
            # decision -- which is what makes an incomplete function type
            # equal to itself, and so findable in `recall`'s cache.
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
