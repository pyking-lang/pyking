"""The interpreter: a resumable machine that runs a Pyking program
directly from the AST, rather than translating it to a host language.

Every other backend in `src/` answers the question "what would this
program look like in C, in Java, in Python?". This module answers a
different one -- "what does this program *do*?" -- and it answers it in
Pyking's own terms: its environments are Pyking scopes, its closures
capture Pyking bindings, and its errors carry Pyking source positions.
That is what makes it the reference for runtime semantics: where a
backend disagrees with it, the backend is wrong.

## Why a machine, and not a recursive walk

A recursive `eval` would be shorter. It would also be a dead end: a
debugger, a step-through in the playground and a DAP adapter all need
execution that can be *paused, inspected and resumed*, and a recursive
walk can only be paused by blocking a host thread. So execution here is
an explicit small-step machine --

    step(State) -> State

-- driven from a flat loop in `run`. Nothing about the machine's own
progress lives on the host's call stack: the pending work is a
continuation chain, and the Pyking call stack is a chain of `Frame`s, so
a paused `State` is an ordinary value that can be stored, inspected,
copied and resumed later. `run(state, steps=n)` stops after `n` steps
and hands the state back; that one signature is what a debugger, a REPL
`:step`, and a browser worker that must not block all need.

Three consequences worth stating, because they are properties of this
design rather than accidents of it (see design/plan-eval-lsp.md, §4.7):

  - **Depth costs heap, not host stack.** Recursion in the interpreted
    program grows `State.stack`, so it cannot overflow Python's own
    stack -- which is why an explicit `max_depth` exists and raises a
    proper Pyking error instead of letting a runaway recursion eat
    memory.
  - **A block does not grow the continuation chain.** Sequencing is an
    *index* into a statement list (`KSeq`), so re-entering a block
    replaces its continuation rather than stacking a new one.
  - **Errors are a machine state**, `CFailed`, not a host exception
    thrown through `step`. A debugger wants to stop *at* an error with
    the frames intact, and a machine that unwinds the host stack has
    already lost them.

## What it runs

Exactly the fragment `src/typesystem.py` accepts -- bindings, expression
statements, `if`, `return`, fully annotated `def`s, the arithmetic and
comparison operators, calls, and the four builtins. The gate is the
checker itself: callers run `type_check` first (see `check` below), the
same way `src/target_ocaml.py` does, so this module never has to decide
separately what "supported" means and the two cannot drift apart. A
construct that gets past the checker anyway is still refused here, with
its own source position, rather than silently doing something.

## Integers are 32 bits

A Pyking `Int` is a signed 32-bit integer here, and `+`, `-` and `*`
wrap on overflow, two's complement, exactly as they do in the C and Java
backends. The interpreter is the reference, so this is the language's
answer; the Python and OCaml backends are wider (see docs/targets.md),
which is a target difference to know about rather than something to
paper over by making every backend agree with its host.

## Values, environments and closures

Values are one frozen dataclass per variant, in the same style
`syntax.py` writes the AST in, with the `datatype` block below naming
the closed set. They hold no host objects and no host dictionaries: the
representation has to survive being rewritten in Pyking and, after that,
compiled to machine code.

An environment is a chain of frames, each frame a small map from name to
value, and it is *persistent*: binding a name builds a new head frame
rather than mutating anything. Pyking's scoping then needs no machinery
at all --

    a block entered      the block's statements run in a chain of their
                         own; the enclosing chain is what the block's
                         continuation resumes with, so nothing escapes
    `=`                  a new frame; a rebinding shadows, it never
                         updates
    a `def`              a `VClosure` holding *the chain it was created
                         in*, which is what lexical capture means

-- and everything `src/target_python.py` has to work for (renaming a
shadowed binding, a per-turn factory so a closure keeps its own turn's
values) is simply what this representation does.

One deliberate exception to "nothing is mutated", and it is exactly
Pyking's rule about `def`s. A block's function *names* are bound before
any of the block runs -- that is what makes recursion, mutual recursion
and a helper written at the bottom of the file work -- while what a body
*captures* is whatever is bound where the body is written. Those two
facts cannot both be true of an environment built strictly by extension,
so `declare` puts one write-once cell in the block's frame per `def`,
holding `VUndefined` until the `def` statement itself is reached and
fills it with the closure it makes *there*. Every closure in the block
holds that same frame, so each of them sees the others; a name used
before its `def` has run is still `VUndefined`, and says so ("its 'def'
has not run yet") rather than being silently missing. A cell is written
once and never again -- `analyses.block_functions`, which is also where
the list of a block's `def`s comes from, allows one `def` per name per
block and no other binding of that name there, so nothing else can
touch it.

## The host

A Pyking program cannot observe anything except through the operations
`src/runtime_interface.py` names, so the machine reaches the outside
world through a `Host` -- one method per operation, and three
implementations here for the three ways a caller wants output: to a
stream, into a buffer, or through a callback. `format_value` implements
that module's formatting rules, so what a program prints under the
interpreter is character-for-character what it prints under every
backend.
"""

from dataclasses import dataclass, field, fields, is_dataclass, replace
import sys

from analyses import BUILTINS, block_functions
from lexer import Info
import runtime_interface
import typesystem
from syntax import (
    Expr, Stmt,
    EInt, EString, EBool, EVar, EAdd, ESub, EMul, ECall,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq,
    SLet, SLetStmt, SExprStmt, SIf, SReturn, SReturnStmt, SFunctionDef,
    TargetName,
)


# ---------------------------------------------------------------------
# The datatypes
#
# Same notation as `syntax.py`'s AST block: `Int`/`String`/`Bool` are
# Python's `int`/`str`/`bool` spelled as Pyking spells its own types,
# `[T]` is a list of `T`, and `T?` a field that may be absent. These are
# hand-written; keep them in step with the classes below.
#
# datatype Value:
#     VInt(value: Int)                       always within 32 signed bits
#     VString(value: String)
#     VBool(value: Bool)
#     VUnit()
#     VList(elements: [Value])
#     VClosure(name: String, params: [String], body: [Stmt]?, expr: Expr?,
#              env: Env)
#     VBuiltin(name: String)
#     VUndefined(name: String)               a hoisted `def` not yet reached
#
# datatype Env:
#     Env(bindings: {String: Value}, parent: Env?)
#
# datatype Control:                          what the machine does next
#     CEval(expr: Expr)                      evaluate an expression
#     CStmt(stmt: Stmt)                      execute one statement
#     CApply(value: Value)                   hand a value to the continuation
#     CDone(value: Value)                    finished; nothing is pending
#     CFailed(error: RuntimeError_)          stopped on a runtime error
#
# datatype Kont:                             what to do with the value that
#     KSeq(stmts: [Stmt], index: Int,        is about to arrive. Every one
#          exit_env: Env, rest: Kont?)       of them carries the `rest` of
#     KBind(name: String, env: Env,          the chain; the ones that resume
#           rest: Kont?)                     an expression carry the `env`
#     KBinaryLeft(node: Expr, right: Expr,   that expression is written in,
#                 env: Env, rest: Kont?)     since only `KSeq` adopts the
#     KBinaryRight(node: Expr, left: Value,  environment it is handed.
#                  env: Env, rest: Kont?)
#     KCallee(call: ECall, env: Env, rest: Kont?)
#     KArgument(call: ECall, callee: Value, done: [Value], todo: [Expr],
#               env: Env, rest: Kont?)
#     KBranch(stmt: SIf, env: Env, rest: Kont?)
#     KDiscard(env: Env, rest: Kont?)
#     KReturnTo(frame: Frame)
#
# datatype Frame:                            one Pyking call
#     Frame(name: String, info: Info, kont: Kont?, env: Env, parent: Frame?,
#           depth: Int)
#
# datatype Runtime:                          what a run never changes
#     Runtime(host: Host, simple: {Int}, max_depth: Int)
#
# datatype State:
#     State(control: Control, env: Env, kont: Kont?, stack: Frame?,
#           runtime: Runtime)
#
#
# Signatures
#
#     val check          : [Stmt] -> TMap
#     val initial_state  : [Stmt] -> Host -> State
#     val step           : State -> State
#     val run            : State -> Int? -> State
#     val run_program    : [Stmt] -> Host -> State
#     val declare_entry  : State -> [Stmt] -> State
#     val eval_in        : State -> Stmt -> State
#     val eval_statement : State -> Stmt -> State
#     val format_value   : Value -> String
#     val display_value  : Value -> String
#
# Only those are meant to be called from outside. `step` is total: it
# answers every state with another state, including a failed one, which
# is what lets `run` be a bare `while` loop.
# ---------------------------------------------------------------------


class RuntimeError_(Exception):
    """A Pyking runtime error: a program that type-checked and still
    could not be run to the end -- a call deeper than `max_depth`, a
    construct outside the fragment, a value that turned out not to be
    what it was used as.

    Carries the source position, like `LexError`/`ParseError`/
    `AnalysisError`/`TypeError_` do for their own stages, so `src/pyk.py`
    reports it in the same `'file' row:col-row:col ...` form.

    It is an `Exception` so that an embedder may raise it (`unwrap`
    does), but the machine never *throws* it: a failing step produces a
    `CFailed` state holding one. Named with a trailing underscore for the
    same reason `typesystem.TypeError_` is -- so it cannot be confused
    with Python's own `RuntimeError`."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


UNSUPPORTED = "Construct is not supported"


def unsupported(node):
    """A refusal of a construct outside the fragment this machine runs,
    worded exactly as `typesystem.py` words it -- because it is the same
    fragment, and a caller has usually been told so already by the
    checker. Reaching this means a program got past the checker and into
    the machine anyway, so it says where rather than guessing."""
    return RuntimeError_(node.info, UNSUPPORTED)


# ---------------------------------------------------------------------
# Integers
# ---------------------------------------------------------------------

# A Pyking `Int` is a signed 32-bit integer, and arithmetic wraps. The
# width is a language decision (see PYKING.md, "Integers"), made here
# because the interpreter is what defines the runtime semantics; the
# backends whose host integers are wider are listed in docs/targets.md.
INT_BITS = 32
INT_MIN = -(1 << (INT_BITS - 1))
INT_MAX = (1 << (INT_BITS - 1)) - 1
_INT_MODULUS = 1 << INT_BITS


def wrap32(n):
    """`n` as a signed 32-bit integer: the value it would have in a
    register that wide, two's complement, wrapping rather than
    overflowing. Applied to every literal and to every `+`, `-` and `*`,
    so no value in the machine is ever outside the range."""
    return ((n - INT_MIN) % _INT_MODULUS) + INT_MIN


# ---------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------


class Value:
    """Base class for the runtime value ADT."""


@dataclass(frozen=True)
class VInt(Value):
    value: int


@dataclass(frozen=True)
class VString(Value):
    value: str


@dataclass(frozen=True)
class VBool(Value):
    value: bool


@dataclass(frozen=True)
class VUnit(Value):
    """`()`: what a statement, a `print` and a program produce."""


@dataclass(frozen=True)
class VList(Value):
    elements: tuple


@dataclass(frozen=True)
class VClosure(Value):
    """A function together with the environment it was written in.

    `body` and `expr` are the two forms a `def` takes (a block, or
    `= expr`), exactly as `SFunctionDef` holds them; one of the two is
    always `None`. `env` is what makes this a closure rather than a
    function pointer, and it is the environment at the definition -- not
    at the call -- which is the whole of Pyking's lexical capture."""
    name: str
    params: tuple
    body: tuple
    expr: Expr
    env: "Env"


@dataclass(frozen=True)
class VBuiltin(Value):
    """One of `analyses.BUILTINS`, in scope in every program. A builtin is
    callable and is not a value the language can otherwise use -- the type
    checker refuses it as one -- but it is a value *here*, because making
    a call evaluate its callee like any other expression is simpler than
    special-casing the name."""
    name: str


@dataclass(frozen=True)
class VUndefined(Value):
    """What a hoisted `def` name holds until its `def` is reached.

    A function's name is in scope throughout the block it is written in,
    but the function itself does not exist until the definition runs --
    so a *body* may name it (bodies run later) while a statement above it
    may not call it yet. This value is the difference between those two,
    and using one is an error that can say which of them happened."""
    name: str


UNIT = VUnit()
TRUE = VBool(True)
FALSE = VBool(False)


def boolean(b):
    return TRUE if b else FALSE


# ---------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------


def format_value(value):
    """A value as `print` writes it, following the rules
    `src/runtime_interface.py` pins down for every host: a string as-is
    with no quoting, an integer in base 10, unit as `()`, and a boolean
    as `true`/`false` -- Pyking's own spelling, not the host language's.

    A list is written the way the backends' hosts write one, with its
    *elements* quoted, since a list is a value being displayed rather
    than text being emitted. It is formatted iteratively, with an
    explicit stack: a value can nest arbitrarily deep, and a recursive
    printer would overflow the host stack on one that nests deeper than
    the host allows (see design/plan-eval-lsp.md, §4.7)."""
    match value:
        case VString(text):
            return text
        case _:
            return display_value(value)


def display_value(value):
    """A value as it appears *inside* a larger one, and as something
    showing a value rather than emitting it wants to write it: like
    `format_value`, except that a string is quoted.

    `print` uses `format_value`, because a program printing a string is
    emitting text. A REPL, a debugger's variable view and the elements of
    a printed list use this, because there the string is a *value* being
    displayed, and `hi` would be indistinguishable from the name `hi`."""
    out = []
    # Each item is either a value still to be written or a literal piece
    # of text; the stack is walked to exhaustion, so nesting costs heap
    # here and nothing on the host's own stack.
    stack = [value]
    while stack:
        item = stack.pop()
        if isinstance(item, str):
            out.append(item)
            continue
        match item:
            case VInt(n):
                out.append(str(n))
            case VString(text):
                out.append(_quote(text))
            case VBool(b):
                out.append("true" if b else "false")
            case VUnit():
                out.append("()")
            case VList(elements):
                stack.append("]")
                for index in range(len(elements) - 1, -1, -1):
                    stack.append(elements[index])
                    if index:
                        stack.append(", ")
                out.append("[")
            case VClosure(name, _, _, _, _):
                out.append(f"<function {name}>")
            case VBuiltin(name):
                out.append(f"<builtin {name}>")
    return "".join(out)


_ESCAPES = {"\\": "\\\\", "'": "\\'", "\n": "\\n", "\t": "\\t", "\r": "\\r"}


def _quote(text):
    return "'" + "".join(_ESCAPES.get(c, c) for c in text) + "'"


# ---------------------------------------------------------------------
# Hosts
# ---------------------------------------------------------------------


class Host:
    """What a Pyking program may observe: one method per operation in
    `runtime_interface.OPERATIONS`.

    That module names the operations and pins their meaning and holds no
    host code at all; this is the code side of the same boundary, and the
    three implementations below are the three ways an embedder wants
    output -- straight to a stream (`pyk run`), collected (a test, a
    transcript), or handed to a callback (a debugger, the playground)."""

    def print(self, text):
        raise NotImplementedError


@dataclass
class ConsoleHost(Host):
    """Writes to a stream, `sys.stdout` unless told otherwise."""
    stream: object = None

    def print(self, text):
        stream = sys.stdout if self.stream is None else self.stream
        stream.write(text + "\n")


@dataclass
class BufferHost(Host):
    """Collects what the program printed, one entry per line."""
    lines: list = field(default_factory=list)

    def print(self, text):
        self.lines.append(text)

    @property
    def output(self):
        return "".join(line + "\n" for line in self.lines)


@dataclass
class CallbackHost(Host):
    """Hands each line to a function -- the shape a debugger or a browser
    worker wants, since it turns output into an event."""
    write_line: object

    def print(self, text):
        self.write_line(text)


# ---------------------------------------------------------------------
# Environments
# ---------------------------------------------------------------------


@dataclass(frozen=True)
class Env:
    """A chain of frames: `bindings` are the names this frame introduces,
    `parent` is the scope around it, `None` at the top.

    Persistent by construction -- `extend` builds a new head rather than
    writing into an existing frame -- which is what lets a closure hold
    "the environment as it was where I was written" without copying it.
    The one place a frame is written to is `declare`, and only before
    anyone can see it."""
    bindings: dict
    parent: "Env" = None


def extend(env, name, value):
    """`env` with `name` bound to `value`: a new frame in front of it. A
    rebinding shadows; nothing is updated in place, which is what makes
    `=` a binding rather than an assignment."""
    return Env({name: value}, env)


def extend_all(env, bindings):
    """`env` with a whole group of names bound at once -- a call's
    parameters, which all come into scope together."""
    return Env(dict(bindings), env)


def lookup(env, name):
    """The value `name` denotes here, or `None` if it denotes nothing.
    Walks outwards, so the innermost binding wins -- lexical scoping,
    with the chain doing all of the work."""
    while env is not None:
        if name in env.bindings:
            return env.bindings[name]
        env = env.parent
    return None


def bindings_in_scope(env):
    """Every name visible from `env`, as name -> value, innermost first.
    Not used by the machine; it is what a REPL's `:vals` and, later, a
    debugger's variable view ask for."""
    seen = {}
    while env is not None:
        for name, value in env.bindings.items():
            seen.setdefault(name, value)
        env = env.parent
    return seen


def top_level_env():
    """The environment a program starts in: the builtins, and nothing
    else. `analyses.BUILTINS` is the list, imported rather than repeated,
    so what a program may name cannot differ between the passes that
    check it and the machine that runs it."""
    return Env({name: VBuiltin(name) for name in BUILTINS})


def declare(stmts, env):
    """`env` with every `def` written at the top of this block already in
    scope -- as a name, not yet as a function.

    Pyking hoists function *names* to the top of their block, so that
    recursion, mutual recursion and a helper written further down all
    work, while what a body captures is still whatever is bound where the
    body is written (see PYKING.md, "Names and scoping"). Those two rules
    meet here: this puts one cell per `def` in a frame of its own, holding
    `VUndefined`, and `define` fills it when the definition is reached.
    Every closure the block makes holds this frame, so each of them can
    see the others however they are ordered.

    Which `def`s count, and the rules that keep a hoisted name
    unambiguous, come from `analyses.block_functions`: one `def` per name
    per block, and no other binding of that name in the same block --
    which is also what makes each cell written exactly once."""
    functions = block_functions(stmts)
    if not functions:
        return env
    return Env({name: VUndefined(name) for name in functions}, env)


def define(env, node):
    """Fill in the cell `declare` made for this `def`, with the closure it
    denotes *here*: capturing the environment at its own position, which
    is what lexical capture means.

    The write is the one mutation in this module. It is a cell that held
    `VUndefined` and now holds a function, in the nearest frame that has
    the name -- which is the block's own, since nothing between here and
    there may bind that name."""
    frame = env
    while frame is not None and node.name not in frame.bindings:
        frame = frame.parent
    value = closure(node, env)
    if frame is None:
        # A `def` whose name `declare` never saw: only reachable if a
        # caller ran a statement without declaring its block first.
        return extend(env, node.name, value)
    frame.bindings[node.name] = value
    return env


def closure(node, env):
    """The `VClosure` a `def` denotes, capturing `env`."""
    return VClosure(
        name=node.name,
        params=tuple(param.name for param in node.params),
        body=tuple(node.body) if node.body is not None else None,
        expr=node.expr,
        env=env,
    )


# ---------------------------------------------------------------------
# Control, continuations, frames, state
# ---------------------------------------------------------------------


class Control:
    """Base class for what the machine is in the middle of doing."""


@dataclass(frozen=True)
class CEval(Control):
    expr: Expr


@dataclass(frozen=True)
class CStmt(Control):
    stmt: Stmt


@dataclass(frozen=True)
class CApply(Control):
    value: Value


@dataclass(frozen=True)
class CDone(Control):
    value: Value


@dataclass(frozen=True)
class CFailed(Control):
    error: RuntimeError_


class Kont:
    """Base class for the continuations: one class per "what to do with
    the value I am about to get".

    Each holds `rest`, the continuation after it, so the chain is a
    linked list -- pushing and popping are one allocation and no copying,
    and two states can share a tail, which is what makes a paused state
    cheap to keep.

    Most of them also hold the `env` their remaining work runs in, and
    the machine restores it when the continuation is popped. That is the
    rule that keeps scopes straight: an expression is evaluated in the
    environment it is *written* in, whatever the value being delivered
    was computed in. `KSeq` is the single deliberate exception -- it
    adopts the environment it is handed, because that is exactly how a
    binding becomes visible to the statements after it."""


@dataclass(frozen=True)
class KSeq(Kont):
    """Run `stmts` from `index` onwards, then deliver the last one's
    value to `rest` with `exit_env` restored.

    The index is what keeps a block from growing the continuation chain:
    re-entering the block replaces this continuation rather than stacking
    another, so a hundred statements cost one continuation, not a
    hundred."""
    stmts: tuple
    index: int
    exit_env: Env
    rest: Kont


@dataclass(frozen=True)
class KBind(Kont):
    """Bind the incoming value to `name`, then carry on with the rest of
    the block. The statement itself supplies unit: a binding is a
    statement, whatever its right-hand side was."""
    name: str
    env: Env
    rest: Kont


@dataclass(frozen=True)
class KBinaryLeft(Kont):
    """The left operand has arrived; evaluate the right one."""
    node: Expr
    right: Expr
    env: Env
    rest: Kont


@dataclass(frozen=True)
class KBinaryRight(Kont):
    """Both operands are in; apply the operator."""
    node: Expr
    left: Value
    env: Env
    rest: Kont


@dataclass(frozen=True)
class KCallee(Kont):
    """The thing being called has arrived; start on the arguments."""
    call: ECall
    env: Env
    rest: Kont


@dataclass(frozen=True)
class KArgument(Kont):
    """One argument has arrived; take the next, or make the call.
    Arguments are evaluated strictly left to right -- the order Pyking
    promises (see PYKING.md, "Evaluation order")."""
    call: ECall
    callee: Value
    done: tuple
    todo: tuple
    env: Env
    rest: Kont


@dataclass(frozen=True)
class KBranch(Kont):
    """The condition of an `if` has arrived; enter the branch it
    chooses."""
    stmt: SIf
    env: Env
    rest: Kont


@dataclass(frozen=True)
class KDiscard(Kont):
    """Throw the incoming value away and deliver unit instead: what an
    `if` with no `else` supplies, since there is a way through it that
    runs no branch at all."""
    env: Env
    rest: Kont


@dataclass(frozen=True)
class KReturnTo(Kont):
    """Leave the current call: the incoming value is the function's
    result, and the frame says where to put it."""
    frame: "Frame"


@dataclass(frozen=True)
class Frame:
    """One Pyking call in progress: the function's name, the source
    position of the call, and everything needed to get back -- the
    caller's continuation and environment.

    This is Pyking's call stack, held in the machine's own data rather
    than on the host's, which is what makes deep recursion a heap cost
    and a stack trace something the machine can simply read off."""
    name: str
    info: Info
    kont: Kont
    env: Env
    parent: "Frame"
    depth: int


# How deep Pyking recursion may go before the machine refuses to go
# further. The stack lives on the heap, so nothing else would stop a
# runaway recursion until the process ran out of memory -- an explicit
# limit turns that into an ordinary Pyking error with a position and a
# stack trace (see design/plan-eval-lsp.md, §4.7).
MAX_CALL_DEPTH = 10_000


@dataclass(frozen=True)
class Runtime:
    """The part of a run that never changes while it runs: the host it
    may speak to, the call-free table (see `_evaluate`), and how deep it
    may recurse.

    Kept apart from `State` for two reasons. It says which parts of a
    machine are *settings* and which are progress -- and it makes a step
    cheap, since building the next state then copies one reference
    instead of three."""
    host: Host
    simple: frozenset
    max_depth: int = MAX_CALL_DEPTH


@dataclass(frozen=True)
class State:
    """Everything the machine is: what it is doing, the environment it is
    doing it in, what is waiting for the answer, the calls in progress,
    and the settings all of that runs under.

    A `State` is a plain value. Keeping one is how a debugger pauses, and
    two states sharing a continuation tail is why that is cheap."""
    control: Control
    env: Env
    kont: Kont
    stack: Frame
    runtime: Runtime


_SAME = object()


def _go(state, control, env=_SAME, kont=_SAME, stack=_SAME):
    """The next state: `state`, with these parts of it different.

    Written out rather than reached through `dataclasses.replace`, which
    walks a class's field list on every call. `step` is the one function
    in this repository that runs millions of times, and this is the
    allocation it makes each time."""
    return State(
        control,
        state.env if env is _SAME else env,
        state.kont if kont is _SAME else kont,
        state.stack if stack is _SAME else stack,
        state.runtime,
    )


# ---------------------------------------------------------------------
# The call-free fast path
#
# An expression containing no call can neither suspend nor reach the
# host, so the machine has nothing to gain from taking it apart one
# continuation at a time: it can be evaluated in one go. Which
# expressions those are is worked out once, before the program runs, and
# carried in `Runtime.simple` -- the same job a `resolve` pass would do
# for name slots, done here for the one flag this module needs.
#
# The recursion in `_evaluate` is bounded by how deeply the *source*
# nests expressions, not by anything the program computes at run time, so
# it cannot be driven deep by a long-running program the way a recursive
# evaluator could.
# ---------------------------------------------------------------------


def call_free_symbols(node):
    """The symbols of every expression in `node` that contains no call.

    Generic over dataclass fields rather than one case per node type --
    the same walk `symbolize` in `analyses.py` uses, and for the same
    reason: a construct added to `syntax.py` is covered without anyone
    remembering this file exists."""
    found = set()

    def walk(item):
        """Whether `item` is free of calls, recording the expressions
        that are."""
        if isinstance(item, ECall):
            for f in fields(item):
                walk(getattr(item, f.name))
            return False
        if is_dataclass(item):
            free = all([walk(getattr(item, f.name)) for f in fields(item)])
            if free and isinstance(item, Expr):
                found.add(item.sym)
            return free
        if isinstance(item, (list, tuple)):
            return all([walk(element) for element in item])
        return True

    walk(node)
    return frozenset(found)


class _Trap(Exception):
    """How the helpers that compute a value report a failure to the step
    that called them -- `_evaluate`, `apply_binary`, `apply_builtin`.

    It never crosses `step`'s boundary: each of the three call sites
    catches it immediately and turns it into a `CFailed` state, so the
    machine's own rule -- errors are states, not exceptions -- still
    holds from outside."""

    def __init__(self, error):
        super().__init__(error.message)
        self.error = error


def _evaluate(expr, env):
    """A call-free expression's value, computed directly.

    Only ever called for an expression `call_free_symbols` vouched for,
    so there is no call to suspend at and no host to reach."""
    match expr:
        case EInt(_, value, _):
            return VInt(wrap32(value))
        case EString(_, value, _):
            return VString(value)
        case EBool(_, value, _):
            return boolean(value)
        case EVar(info, name, _):
            match lookup(env, name):
                case None:
                    raise _Trap(RuntimeError_(info, f"unbound name '{name}'"))
                case VUndefined(_):
                    # In scope -- its `def` is in this block -- but the
                    # definition has not run yet, which is a different
                    # mistake from naming something that does not exist,
                    # and worth saying so.
                    raise _Trap(RuntimeError_(
                        info,
                        f"'{name}' is in scope, but its 'def' has not run yet",
                    ))
                case value:
                    return value
        case EAdd() | ESub() | EMul() | ELessThan() | ELessThanEq() \
                | EGreatThan() | EGreatThanEq() | EEq():
            left = _evaluate(expr.left, env)
            right = _evaluate(expr.right, env)
            return apply_binary(expr, left, right)
        case _:
            raise _Trap(unsupported(expr))


# ---------------------------------------------------------------------
# Operators
# ---------------------------------------------------------------------

# What each operator does, as `node class -> (spelling, rule)`. The rule
# takes the two values and gives back a value, or `None` when the
# operator does not apply to them -- which, after type checking, only a
# program that reached the machine another way can manage. The table is
# deliberately shaped like `typesystem.OPERATORS`: the same operators,
# with what they *compute* here beside what they *accept* there.


def _arith(op):
    def rule(left, right):
        match (left, right):
            case (VInt(a), VInt(b)):
                return VInt(wrap32(op(a, b)))
        return None
    return rule


def _compare(op):
    def rule(left, right):
        match (left, right):
            case (VInt(a), VInt(b)):
                return boolean(op(a, b))
        return None
    return rule


def _add(left, right):
    match (left, right):
        case (VInt(a), VInt(b)):
            return VInt(wrap32(a + b))
        case (VString(a), VString(b)):
            return VString(a + b)
    return None


def _equals(left, right):
    match (left, right):
        case (VInt(a), VInt(b)) | (VString(a), VString(b)) | (VBool(a), VBool(b)):
            return boolean(a == b)
    return None


OPERATORS = {
    EAdd: ("+", _add),
    ESub: ("-", _arith(lambda a, b: a - b)),
    EMul: ("*", _arith(lambda a, b: a * b)),
    ELessThan: ("<", _compare(lambda a, b: a < b)),
    ELessThanEq: ("<=", _compare(lambda a, b: a <= b)),
    EGreatThan: (">", _compare(lambda a, b: a > b)),
    EGreatThanEq: (">=", _compare(lambda a, b: a >= b)),
    EEq: ("==", _equals),
}


def apply_binary(node, left, right):
    """The value of one binary operator application. Raises a `_Trap` for
    operands the operator does not accept -- a program the type checker
    would have refused."""
    spelling, rule = OPERATORS[type(node)]
    value = rule(left, right)
    if value is None:
        raise _Trap(RuntimeError_(
            node.info,
            f"`{spelling}` cannot be applied to {describe(left)} and "
            f"{describe(right)}",
        ))
    return value


def describe(value):
    """What a value is, for an error message: its type as Pyking spells
    it, which is what a reader of the error is thinking in."""
    match value:
        case VInt():
            return "Int"
        case VString():
            return "String"
        case VBool():
            return "Bool"
        case VUnit():
            return "()"
        case VList():
            return "a list"
        case VClosure() | VBuiltin():
            return "a function"
    return "a value"


# ---------------------------------------------------------------------
# Builtins
# ---------------------------------------------------------------------


def apply_builtin(name, args, call, host):
    """One of `analyses.BUILTINS`, applied.

    `print` is the one that crosses the runtime interface, so it goes
    through the host and through `format_value`, which is what makes the
    interpreter's output identical to every backend's. The other three
    are pure and are computed here. Their signatures are
    `typesystem.check_builtin_call`'s, and a call that got past the
    checker cannot disagree with them; the arity checks below are for
    calls that reached the machine another way.

    Which names are operations is `runtime_interface.py`'s to say, not
    this module's, so the one case that reaches the host is written
    against the operation itself rather than against the string
    `'print'` -- an operation added there will not be quietly answered
    here by a coincidence of spelling."""
    match (name, args):
        case (runtime_interface.PRINT.name, _):
            host.print(" ".join(format_value(argument) for argument in args))
            return UNIT
        case ("str", [value]):
            return VString(format_value(value))
        case ("len", [VString(text)]):
            return VInt(wrap32(len(text)))
        case ("len", [VList(elements)]):
            return VInt(wrap32(len(elements)))
        case ("range", [VInt(stop)]):
            return _range(0, stop, 1, call)
        case ("range", [VInt(start), VInt(stop)]):
            return _range(start, stop, 1, call)
        case ("range", [VInt(start), VInt(stop), VInt(step)]):
            return _range(start, stop, step, call)
    raise _Trap(RuntimeError_(
        call.info,
        f"'{name}' cannot be applied to "
        f"({', '.join(describe(argument) for argument in args)})",
    ))


def _range(start, stop, step, call):
    """`range` builds a *list*: Pyking has lists and no lazy-sequence
    type, and the checker says so (`check_builtin_call` gives it
    `[Int]`)."""
    if step == 0:
        raise _Trap(RuntimeError_(call.info, "'range' step must not be zero"))
    return VList(tuple(VInt(wrap32(n)) for n in range(start, stop, step)))


# ---------------------------------------------------------------------
# The machine
# ---------------------------------------------------------------------


def step(state):
    """One small step: a state in, the next state out.

    Total -- every state has a successor, including a finished or failed
    one, which is what lets `run` be a bare loop with one test in it.
    Nothing here touches the outside world except `apply_builtin`'s
    `print`, and nothing raises: a failure becomes a `CFailed` state."""
    match state.control:
        case CEval(expr):
            return _step_eval(state, expr)
        case CStmt(stmt):
            return _step_stmt(state, stmt)
        case CApply(value):
            return _step_apply(state, value)
        case CDone() | CFailed():
            return state


def _step_eval(state, expr):
    """Start on an expression. A call-free one is finished here and now;
    anything else is taken apart, one continuation per piece of work that
    has to wait."""
    if expr.sym in state.runtime.simple:
        try:
            return _go(state, control=CApply(_evaluate(expr, state.env)))
        except _Trap as trap:
            return failed(state, trap.error)
    match expr:
        case EAdd() | ESub() | EMul() | ELessThan() | ELessThanEq() \
                | EGreatThan() | EGreatThanEq() | EEq():
            return _go(
                state,
                control=CEval(expr.left),
                kont=KBinaryLeft(expr, expr.right, state.env, state.kont),
            )
        case ECall(_, func, _, _):
            return _go(
                state,
                control=CEval(func),
                kont=KCallee(expr, state.env, state.kont),
            )
        case _:
            # A literal or a name: call-free, so the fast path above has
            # already dealt with it. Anything else is outside the
            # fragment.
            return failed(state, unsupported(expr))


def _step_stmt(state, stmt):
    """Start on a statement. What it *supplies* -- the question
    PYKING.md's "Tail position" asks, and the one `typesystem.py` answers
    for types -- is what it delivers to its continuation; what it *binds*
    travels with the environment, which only `KSeq` adopts."""
    match stmt:
        case SLet(_, TargetName(_, name, _), expr, _, _):
            return _go(
                state,
                control=CEval(expr),
                kont=KBind(name, state.env, state.kont),
            )

        case SLetStmt(_, TargetName(_, name, _), inner, _, _):
            # `x = if c: ...` binds whatever the branch that runs yields.
            return _go(
                state,
                control=CStmt(inner),
                kont=KBind(name, state.env, state.kont),
            )

        case SExprStmt(_, expr, _):
            # Supplies its expression's value, and binds nothing, so its
            # continuation is simply the one that was already there.
            return _go(state, control=CEval(expr))

        case SIf(_, cond, _, _, _):
            return _go(
                state,
                control=CEval(cond),
                kont=KBranch(stmt, state.env, state.kont),
            )

        case SReturn(info, expr, _):
            frame = state.stack
            if frame is None:
                return failed(state, RuntimeError_(info, "'return' outside a function"))
            return _go(state, control=CEval(expr), kont=KReturnTo(frame))

        case SReturnStmt(info, inner, _):
            frame = state.stack
            if frame is None:
                return failed(state, RuntimeError_(info, "'return' outside a function"))
            return _go(state, control=CStmt(inner), kont=KReturnTo(frame))

        case SFunctionDef():
            # The name has been in scope since the block began; this is
            # where it becomes a function, capturing what is bound here.
            # The statement itself supplies unit.
            return _go(state, control=CApply(UNIT), env=define(state.env, stmt))

        case _:
            return failed(state, unsupported(stmt))


def _step_apply(state, value):
    """Hand a value to whatever was waiting for it."""
    match state.kont:
        case None:
            return _go(state, control=CDone(value))

        case KSeq(stmts, index, exit_env, rest):
            # The one continuation that adopts the environment it is
            # handed: that is how a binding reaches the statements after
            # it. When the block is done, `exit_env` puts the enclosing
            # scope back, which is what keeps the block's bindings inside
            # it.
            if index < len(stmts):
                return _go(
                    state,
                    control=CStmt(stmts[index]),
                    kont=KSeq(stmts, index + 1, exit_env, rest),
                )
            return _go(state, control=CApply(value), env=exit_env, kont=rest)

        case KBind(name, env, rest):
            return _go(
                state,
                control=CApply(UNIT),
                env=extend(env, name, value),
                kont=rest,
            )

        case KBinaryLeft(node, right, env, rest):
            return _go(
                state,
                control=CEval(right),
                env=env,
                kont=KBinaryRight(node, value, env, rest),
            )

        case KBinaryRight(node, left, env, rest):
            try:
                return _go(
                    state,
                    control=CApply(apply_binary(node, left, value)),
                    env=env,
                    kont=rest,
                )
            except _Trap as trap:
                return failed(state, trap.error)

        case KCallee(call, env, rest):
            return _start_arguments(state, call, value, (), tuple(call.args), env, rest)

        case KArgument(call, callee, done, todo, env, rest):
            return _start_arguments(state, call, callee, done + (value,), todo, env, rest)

        case KBranch(stmt, env, rest):
            match value:
                case VBool(True):
                    body = stmt.then_body
                case VBool(False):
                    body = stmt.else_body
                case _:
                    return failed(state, RuntimeError_(
                        stmt.cond.info,
                        f"the condition of an 'if' must be Bool, not "
                        f"{describe(value)}",
                    ))
            if body is None:
                return _go(state, control=CApply(UNIT), env=env, kont=rest)
            # An `if` with no `else` supplies nothing, whatever the branch
            # it does have ends in -- so the branch's value is discarded.
            after = rest if stmt.else_body is not None else KDiscard(env, rest)
            return enter_block(state, body, env, after)

        case KDiscard(env, rest):
            return _go(state, control=CApply(UNIT), env=env, kont=rest)

        case KReturnTo(frame):
            return _go(
                state,
                control=CApply(value),
                env=frame.env,
                kont=frame.kont,
                stack=frame.parent,
            )


def _start_arguments(state, call, callee, done, todo, env, rest):
    """Evaluate the next argument, or -- when there are none left -- make
    the call."""
    if todo:
        return _go(
            state,
            control=CEval(todo[0]),
            env=env,
            kont=KArgument(call, callee, done, todo[1:], env, rest),
        )
    return _call(state, call, callee, done, env, rest)


def _call(state, call, callee, args, env, rest):
    """Apply a value to its arguments.

    A builtin is performed on the spot -- it is one operation, and
    `print` is the only one that reaches the world. A closure is entered:
    a frame records where to come back to, and the body runs in the
    environment the closure captured, extended with the parameters. The
    body is *not* a fresh nested scope on top of that: the parameters are
    the function's own scope, and `declare` then adds whatever `def`s the
    body opens with."""
    match callee:
        case VBuiltin(name):
            try:
                value = apply_builtin(name, list(args), call, state.runtime.host)
            except _Trap as trap:
                return failed(state, trap.error)
            return _go(state, control=CApply(value), env=env, kont=rest)

        case VClosure(name, params, body, expr, captured):
            if len(args) != len(params):
                return failed(state, RuntimeError_(
                    call.info,
                    f"'{name}' takes {len(params)} "
                    f"argument{'' if len(params) == 1 else 's'}, but "
                    f"{len(args)} {'was' if len(args) == 1 else 'were'} given",
                ))
            depth = (state.stack.depth if state.stack is not None else 0) + 1
            if depth > state.runtime.max_depth:
                return failed(state, RuntimeError_(
                    call.info,
                    f"maximum call depth of {state.runtime.max_depth} "
                    f"exceeded; this is what a recursion that never ends "
                    f"looks like",
                ))
            frame = Frame(name, call.info, rest, env, state.stack, depth)
            call_env = extend_all(captured, zip(params, args))
            # The frame is pushed here; `KReturnTo` is what pops it, and
            # what puts the caller's own environment and continuation
            # back when the call produces its value.
            entered = _go(state, control=CApply(UNIT), stack=frame)
            if expr is not None:
                return _go(
                    entered, control=CEval(expr), env=call_env, kont=KReturnTo(frame)
                )
            return enter_block(entered, body, call_env, KReturnTo(frame))

        case _:
            return failed(state, RuntimeError_(
                call.info,
                f"this call applies {describe(callee)}, which is not a function",
            ))


def enter_block(state, stmts, env, rest):
    """Begin a block: declare its `def`s, then run its statements in
    order, delivering the last one's value to `rest`.

    Entering is spelled as "deliver unit to a fresh `KSeq`", which is
    also exactly what happens between two statements -- so a block has
    one code path, whether it is a program, a branch or a function
    body."""
    return _go(
        state,
        control=CApply(UNIT),
        env=declare(stmts, env),
        kont=KSeq(tuple(stmts), 0, env, rest),
    )


def failed(state, error):
    """The state a runtime error leaves behind: everything as it was --
    the environment, the continuations, the frames -- with the error in
    the control position. Nothing is unwound, so a debugger stopping here
    can still show the stack the error happened on."""
    return _go(state, control=CFailed(error))


# ---------------------------------------------------------------------
# Driving the machine
# ---------------------------------------------------------------------


def check(stmts):
    """The gate: a program is runnable exactly when `typesystem.py`
    accepts it, so this runs the checker and hands back its `tmap`.

    The interpreter covers the checker's fragment, and this is how that
    stays true without a second list of supported constructs to keep in
    step -- the same arrangement `src/target_ocaml.py` uses. Raises
    `typesystem.TypeError_` or `analyses.AnalysisError`, which the driver
    already knows how to report."""
    return typesystem.type_check(stmts)


def initial_state(stmts, host, env=None, max_depth=MAX_CALL_DEPTH):
    """A machine about to run `stmts`, not yet having taken a step.

    `env` lets a caller continue an earlier session -- the REPL passes
    the environment its previous entries left behind -- and defaults to a
    fresh top level with the builtins in scope."""
    start = top_level_env() if env is None else env
    runtime = Runtime(host, call_free_symbols(stmts), max_depth)
    state = State(CApply(UNIT), start, None, None, runtime)
    return enter_block(state, stmts, start, None)


def finished(state):
    """Whether the machine has stopped, either way."""
    return isinstance(state.control, (CDone, CFailed))


def run(state, steps=None):
    """Step until the machine stops, or until `steps` steps have been
    taken -- whichever comes first.

    The bounded form is what makes this usable from somewhere that must
    not block: a debugger, a browser worker, a REPL that wants to stay
    interruptible. The state that comes back is a state like any other,
    so running it further is just calling this again."""
    taken = 0
    while not finished(state) and (steps is None or taken < steps):
        state = step(state)
        taken += 1
    return state


def result(state):
    """The value a finished machine produced, or `None` if it failed or
    has not finished."""
    match state.control:
        case CDone(value):
            return value
    return None


def failure(state):
    """The `RuntimeError_` a machine stopped on, or `None`."""
    match state.control:
        case CFailed(error):
            return error
    return None


def unwrap(state):
    """`state`, or its error raised -- for a caller that would rather
    handle a failure as an exception than as a state. The machine itself
    never does this."""
    error = failure(state)
    if error is not None:
        raise error
    return state


def run_program(stmts, host=None, max_depth=MAX_CALL_DEPTH):
    """Run a whole program to completion and return the final state.

    The program must already have been checked (`check`) and symbolized
    (`analyses.symbolize` -- the fast path is keyed by symbol). The state
    that comes back says how it ended: `failure(state)` for a runtime
    error, `result(state)` for the value the program's last statement
    supplied."""
    return run(initial_state(stmts, host or ConsoleHost(), max_depth=max_depth))


def declare_entry(state, stmts):
    """`state` with every `def` in `stmts` declared, as one group.

    What entering a block does, for a group of statements that is not
    one: a REPL entry, or a file read into a session. Its functions come
    into scope together, so two of them may call each other, exactly as
    they could inside a block -- while a *later* entry is a later group,
    which is why a function written now cannot be called by one written
    before it."""
    return _go(state, control=state.control, env=declare(stmts, state.env))


def eval_in(state, stmt):
    """Run one statement in `state`'s environment as it stands, and
    return the state it leaves behind -- `state.env` extended if it bound
    anything, `result(state)` the value it supplied.

    Nothing is declared first: the caller has already done that for the
    group this statement belongs to. A statement typed at a prompt is not
    a nested scope, so what it binds stays bound for whatever is typed
    next.

    It is run with a continuation chain of its own, so it cannot resume
    anything the machine was in the middle of -- an entry starts and
    finishes."""
    runtime = replace(
        state.runtime, simple=state.runtime.simple | call_free_symbols(stmt)
    )
    return run(State(CStmt(stmt), state.env, None, None, runtime))


def eval_statement(state, stmt):
    """One statement, declared and run: `eval_in` for the common case of
    a group of one. This is what a debugger's "evaluate this in the
    paused frame" request wants."""
    return eval_in(declare_entry(state, [stmt]), stmt)


def stack_trace(state):
    """The calls in progress, innermost first, as `(name, info)` pairs --
    what an error report or a debugger's stack view reads."""
    trace = []
    frame = state.stack
    while frame is not None:
        trace.append((frame.name, frame.info))
        frame = frame.parent
    return trace
