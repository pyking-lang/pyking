"""The interpreter: a resumable small-step machine that runs a Pyking
program directly from the AST, instead of translating it to a host
language. It runs the fragment src/typesystem.py accepts, and src/pyk.py
type-checks before handing a program here -- that is the whole of the
gate, so there is no second list of supported constructs to keep in
step. Values are 32-bit signed integers, wrapping on overflow. This is
the reference implementation of Pyking's runtime semantics. See
docs/architecture.md ("The interpreter") and docs/source.md
("interpreter.py").

Data structures: see the `datatype` comment block below (Value, Env,
Control, Kont, Frame, Runtime, State), and:
    RuntimeError_ -- a runtime failure, with the source position.
    Host / ConsoleHost / BufferHost / CallbackHost -- where print goes.

Functions:
    run_program(stmts, host) -- runs a whole program to completion.
    initial_state(stmts, host) -- a machine about to run stmts.
    step(state) -- one small step.
    run(state, steps) -- steps until the machine stops or steps run out.
    eval_statement(state, stmt) -- runs one statement in an existing
        machine's environment (for the REPL).
    format_value(value) / display_value(value) -- formats a value as
        print emits it / as a value is shown.
"""

from dataclasses import dataclass, field, fields, is_dataclass, replace
import sys

from analyses import BUILTINS, block_functions
from lexer import Info
import runtime_interface
import typesystem
from syntax import (
    Expr, Stmt,
    EInt, EString, EBool, EVar, EAdd, EConcat, ESub, EMul, EDiv, ECall, EIf,
    ETuple,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq,
    SLet, SLetStmt, SExprStmt, SIf, SReturn, SReturnStmt, SFunctionDef,
    SFunctionSig, SMatch,
    ENeg, EList, EListComp, CompFor, CompIf,
    PInt, PString, PBool, PWildcard, PCapture, PTuple, PList, PText, ListRest,
    SLoop, SBreak, SContinue, ForIn, WhileTest,
    TargetName, TargetTuple,
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
#     VTuple(elements: [Value])
#     VClosure(name: String, params: [String], body: [Stmt], env: Env)
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
#     KBind(target: AssignTarget, env: Env,  the chain; the ones that resume
#           rest: Kont?)                     an expression carry the `env`
#     KBinaryLeft(node: Expr, right: Expr,   that expression is written in,
#                 env: Env, rest: Kont?)     since only `KSeq` adopts the
#     KBinaryRight(node: Expr, left: Value,  environment it is handed.
#                  env: Env, rest: Kont?)
#     KCallee(call: ECall, env: Env, rest: Kont?)
#     KArgument(call: ECall, callee: Value, done: [Value], todo: [Expr],
#               env: Env, rest: Kont?)
#     KElement(node: ETuple, done: [Value], todo: [Expr], env: Env,
#              rest: Kont?)
#     KNegate(node: ENeg, env: Env, rest: Kont?)
#     KScrutinee(stmt: SMatch, env: Env, rest: Kont?)
#     KComprehend(node: EListComp, want: String, index: Int,
#                 frames: [(Int, [Value], Env)], done: [Value],
#                 env: Env, outer: Env, rest: Kont?)
#     KBranch(stmt: SIf, env: Env, rest: Kont?)
#     KChoose(expr: EIf, env: Env, rest: Kont?)
#     KDiscard(env: Env, rest: Kont?)
#     KStartLoop(loop: Loop)
#     KSequence(loop: Loop)                  a `for`'s sequence
#     KTest(loop: Loop)                      a `while`'s condition
#     KEnding(loop: Loop)                    the `then:` block's value
#     KIterate(loop: Loop)
#     KExit(loop: Loop, leaving: Bool)       break (leaving) / continue
#     KReturnTo(frame: Frame)
#
# datatype Frame:                            one Pyking call
#     Frame(name: String, info: Info, kont: Kont?, env: Env, parent: Frame?,
#           depth: Int, loops: Loop?)
#
# datatype Loop:                             one `loop` in progress
#     Loop(node: SLoop, accumulator: Value, env: Env, kont: Kont?,
#          parent: Loop?)
#
# datatype Runtime:                          what a run never changes
#     Runtime(host: Host, simple: {Int}, max_depth: Int)
#
# datatype State:
#     State(control: Control, env: Env, kont: Kont?, stack: Frame?,
#           runtime: Runtime, loops: Loop?)
#
#
# Signatures
#
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
    """A Pyking runtime error, with the source position. The machine
    never raises it directly -- a failing step produces a CFailed state
    holding one instead."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


UNSUPPORTED = "Construct is not supported"


def unsupported(node):
    """A RuntimeError_ refusing a construct outside the fragment this
    machine runs. Node -> RuntimeError_"""
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
    """n wrapped to a signed 32-bit integer, two's complement.
    Int -> Int"""
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
    """A function and the environment it was written in. Fields:
    name: String, params: [String], body: [Stmt], env: Env."""
    name: str
    params: tuple
    body: tuple
    env: "Env"


@dataclass(frozen=True)
class VTuple(Value):
    elements: tuple


@dataclass(frozen=True)
class VBuiltin(Value):
    """One of analyses.BUILTINS, callable as a value here even though
    the type checker refuses it as one. Field: name: String."""
    name: str


@dataclass(frozen=True)
class VUndefined(Value):
    """What a hoisted def name holds until its def statement runs.
    Field: name: String."""
    name: str


UNIT = VUnit()
TRUE = VBool(True)
FALSE = VBool(False)


def boolean(b):
    """VBool for b. Bool -> VBool"""
    return TRUE if b else FALSE


# ---------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------


def format_value(value):
    """Formats a value as print writes it (runtime_interface.py's
    rules): a string bare, everything else as display_value.
    Value -> String"""
    match value:
        case VString(text):
            return text
        case _:
            return display_value(value)


def display_value(value):
    """Formats a value as it appears inside a larger one, or as a
    prompt/debugger shows it: like format_value, but a string is
    quoted. Iterative, so nesting cannot overflow the host stack.
    Value -> String"""
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
            case VTuple(elements):
                # A singleton keeps the comma that tells it from a
                # parenthesized value, exactly as the source form does.
                stack.append(",)" if len(elements) == 1 else ")")
                for index in range(len(elements) - 1, -1, -1):
                    stack.append(elements[index])
                    if index:
                        stack.append(", ")
                out.append("(")
            case VClosure(name, _, _, _):
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
    runtime_interface.OPERATIONS."""

    def print(self, text):
        raise NotImplementedError


@dataclass
class ConsoleHost(Host):
    """Writes to a stream (sys.stdout by default). Field: stream: object?"""
    stream: object = None

    def print(self, text):
        stream = sys.stdout if self.stream is None else self.stream
        stream.write(text + "\n")


@dataclass
class BufferHost(Host):
    """Collects printed output, one entry per line. Field: lines: [String]"""
    lines: list = field(default_factory=list)

    def print(self, text):
        self.lines.append(text)

    @property
    def output(self):
        return "".join(line + "\n" for line in self.lines)


@dataclass
class CallbackHost(Host):
    """Hands each printed line to a function. Field: write_line: String -> ()"""
    write_line: object

    def print(self, text):
        self.write_line(text)


# ---------------------------------------------------------------------
# Environments
# ---------------------------------------------------------------------


@dataclass(frozen=True)
class Env:
    """A persistent chain of frames. Fields: bindings: {String: Value}
    (names this frame introduces), parent: Env? (None at the top)."""
    bindings: dict
    parent: "Env" = None


def extend(env, name, value):
    """env with name bound to value, as a new frame.
    Env -> String -> Value -> Env"""
    return Env({name: value}, env)


def extend_all(env, bindings):
    """env with a whole group of names bound at once, as a new frame.
    Env -> {String: Value} -> Env"""
    return Env(dict(bindings), env)


def lookup(env, name):
    """The value name denotes in env, or None. Walks outward, so the
    innermost binding wins. Env -> String -> Value?"""
    while env is not None:
        if name in env.bindings:
            return env.bindings[name]
        env = env.parent
    return None


def bindings_in_scope(env):
    """Every name visible from env, as name -> value, innermost first.
    Env -> {String: Value}"""
    seen = {}
    while env is not None:
        for name, value in env.bindings.items():
            seen.setdefault(name, value)
        env = env.parent
    return seen


def top_level_env():
    """The environment a program starts in: the builtins, nothing else.
    () -> Env"""
    return Env({name: VBuiltin(name) for name in BUILTINS})


def declare(stmts, env):
    """env with every def at the top of this block bound as a name
    (VUndefined, not yet a function; see PYKING.md, "Names and
    scoping"). [Stmt] -> Env -> Env"""
    functions = block_functions(stmts)
    if not functions:
        return env
    return Env({name: VUndefined(name) for name in functions}, env)


def define(env, node):
    """Fills in the cell declare() made for this def, with the closure
    it denotes here. The one mutation in this module.
    Env -> SFunctionDef -> Env"""
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
    """The VClosure a def denotes, capturing env.
    SFunctionDef -> Env -> VClosure"""
    return VClosure(
        name=node.name,
        params=tuple(param.name for param in node.params),
        body=tuple(node.body),
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
    """Runs stmts from index onwards, then delivers the last one's
    value to rest with exit_env restored. The index is what keeps a
    block from growing the continuation chain."""
    stmts: tuple
    index: int
    exit_env: Env
    rest: Kont


@dataclass(frozen=True)
class KBind(Kont):
    """Binds the incoming value to a target -- one name, or a tuple
    taken apart -- then supplies unit."""
    target: "AssignTarget"
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
    """One argument has arrived; takes the next, or makes the call.
    Arguments are evaluated left to right."""
    call: ECall
    callee: Value
    done: tuple
    todo: tuple
    env: Env
    rest: Kont


@dataclass(frozen=True)
class KElement(Kont):
    """One element of a tuple has arrived; takes the next, or builds
    the tuple. Elements are evaluated left to right."""
    node: ETuple
    done: tuple
    todo: tuple
    env: Env
    rest: Kont


@dataclass(frozen=True)
class KNegate(Kont):
    """The operand of a unary minus has arrived."""
    node: ENeg
    env: Env
    rest: Kont


@dataclass(frozen=True)
class KScrutinee(Kont):
    """The subject of a `match` has arrived; the arms are tried against
    it in order. Matching evaluates nothing, so it is done in one step."""
    stmt: SMatch
    env: Env
    rest: Kont


@dataclass(frozen=True)
class KComprehend(Kont):
    """One value of a comprehension has arrived -- an element, a
    sequence, or a condition, according to `want`. `frames` is the
    iteration in progress, innermost last; `done` is what has been
    collected so far."""
    node: EListComp
    want: str                   # "sequence" | "test" | "element"
    index: int                  # which clause the value belongs to
    frames: tuple               # ((clause_index, (Value,), Env), ...)
    done: tuple
    env: Env                    # where the value being awaited is evaluated
    outer: Env                  # where the whole comprehension was written
    rest: Kont


@dataclass(frozen=True)
class KBranch(Kont):
    """The condition of an `if` has arrived; enter the branch it
    chooses."""
    stmt: SIf
    env: Env
    rest: Kont


@dataclass(frozen=True)
class KChoose(Kont):
    """The condition of an `if` *expression* has arrived; evaluate the
    branch it chooses -- and only that one, since the other must not
    happen."""
    expr: EIf
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
class KStartLoop(Kont):
    """A loop's initializer has arrived: it is the accumulator the
    first turn runs with."""
    loop: "Loop"


@dataclass(frozen=True)
class KIterate(Kont):
    """A turn of the loop body has produced its value: that value is
    the accumulator for the next turn. This continuation replaces
    itself rather than stacking, which is what lets a loop run forever
    in constant memory."""
    loop: "Loop"


@dataclass(frozen=True)
class KSequence(Kont):
    """A `for` loop's sequence has arrived; the turns can start."""
    loop: Loop


@dataclass(frozen=True)
class KTest(Kont):
    """A `while` loop's condition has arrived: another turn, or the end."""
    loop: Loop


@dataclass(frozen=True)
class KEnding(Kont):
    """A loop's `then:` block has produced the loop's own value."""
    loop: Loop


@dataclass(frozen=True)
class KExit(Kont):
    """A `break`/`continue` operand has arrived: leaving means the
    loop ends with it, otherwise the next turn starts with it."""
    loop: "Loop"
    leaving: bool


@dataclass(frozen=True)
class KReturnTo(Kont):
    """Leave the current call: the incoming value is the function's
    result, and the frame says where to put it."""
    frame: "Frame"


@dataclass(frozen=True)
class Frame:
    """One Pyking call in progress. Pyking's call stack, held in the
    machine's own data rather than the host's. `loops` is the caller's
    loop stack: a call enters with none of its own, since a `break`
    may not cross a `def`."""
    name: str
    info: Info
    kont: Kont
    env: Env
    parent: "Frame"
    depth: int
    loops: "Loop" = None


@dataclass(frozen=True)
class Loop:
    """One `loop` in progress: what a `break`/`continue` in its body
    needs in order to leave it or go round again. `accumulator` is what
    the current turn started with (a bare `break` yields exactly that),
    `env` the environment the loop is written in -- where each turn
    binds the accumulator afresh -- and `kont` where the loop's own
    value goes when it ends."""
    node: SLoop
    accumulator: Value
    env: Env
    kont: Kont
    parent: "Loop" = None
    remaining: tuple = ()    # what a `for` has left to walk


# Maximum Pyking call depth before the machine raises a runtime error.
MAX_CALL_DEPTH = 10_000


@dataclass(frozen=True)
class Runtime:
    """The part of a State that never changes while it runs: the host,
    the call-free symbol table (see _evaluate), and the depth limit."""
    host: Host
    simple: frozenset
    max_depth: int = MAX_CALL_DEPTH


@dataclass(frozen=True)
class State:
    """A machine state: what it is doing, the environment, the pending
    continuation, the call stack, the run's settings, and the loops it
    is inside. A plain value; keeping one is how a debugger pauses."""
    control: Control
    env: Env
    kont: Kont
    stack: Frame
    runtime: Runtime
    loops: Loop = None


_SAME = object()


def _go(state, control, env=_SAME, kont=_SAME, stack=_SAME, loops=_SAME):
    """state with these fields replaced. Written out instead of using
    dataclasses.replace, which is the hot path in step().
    State -> Control -> Env? -> Kont? -> Frame? -> Loop? -> State"""
    return State(
        control,
        state.env if env is _SAME else env,
        state.kont if kont is _SAME else kont,
        state.stack if stack is _SAME else stack,
        state.runtime,
        state.loops if loops is _SAME else loops,
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
    """The symbols of every expression in node that contains no call.
    Generic over dataclass fields. a -> {Int}"""
    found = set()

    def walk(item):
        """Whether item is free of calls; records the expressions that
        are. a -> Bool"""
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
    """Internal: how _evaluate/apply_binary/apply_builtin report a
    failure to their caller. Caught before it crosses step()'s
    boundary and turned into a CFailed state."""

    def __init__(self, error):
        super().__init__(error.message)
        self.error = error


def _evaluate(expr, env):
    """A call-free expression's value, computed directly (only called
    for expr in call_free_symbols). Expr -> Env -> Value"""
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
        case ETuple(_, elements, _):
            return VTuple(tuple(_evaluate(element, env) for element in elements))
        case EList(_, elements, _):
            return VList(tuple(_evaluate(element, env) for element in elements))
        case EListComp(_, element, clauses, _):
            return VList(tuple(
                _evaluate(element, inner)
                for inner in _comprehension_envs(list(clauses), env)
            ))
        case ENeg(_, operand, _):
            return apply_unary(expr, _evaluate(operand, env))
        case EAdd() | EConcat() | ESub() | EMul() | EDiv() | ELessThan() \
                | ELessThanEq() | EGreatThan() | EGreatThanEq() | EEq():
            left = _evaluate(expr.left, env)
            right = _evaluate(expr.right, env)
            return apply_binary(expr, left, right)
        case EIf(_, cond, then_expr, else_expr, _):
            # Only the branch that is chosen is evaluated, here as in the
            # machine: an `if` expression chooses, it does not compute
            # both and pick.
            match _evaluate(cond, env):
                case VBool(True):
                    return _evaluate(then_expr, env)
                case VBool(False):
                    return _evaluate(else_expr, env)
                case other:
                    raise _Trap(RuntimeError_(
                        cond.info,
                        f"the condition of an 'if' must be Bool, not "
                        f"{describe(other)}",
                    ))
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


def _divide(left, right):
    """Integer division, truncating toward zero -- Python's `//` rounds
    down instead, so `-7 / 2` would be -4 rather than the -3 every
    backend gives. Division by zero is a Pyking error rather than a
    crash: `step` is total (docs/interpreter.md).
    Value -> Value -> Value?"""
    match (left, right):
        case (VInt(_), VInt(0)):
            raise _Trap(RuntimeError_(_DIVIDE_INFO, "division by zero"))
        case (VInt(a), VInt(b)):
            quotient = abs(a) // abs(b)
            return VInt(wrap32(quotient if (a < 0) == (b < 0) else -quotient))
    return None


def _concat(left, right):
    match (left, right):
        case (VString(a), VString(b)):
            return VString(a + b)
        case (VList(a), VList(b)):
            return VList(a + b)
    return None


def _equals(left, right):
    match (left, right):
        case (VInt(a), VInt(b)) | (VString(a), VString(b)) | (VBool(a), VBool(b)):
            return boolean(a == b)
    return None


OPERATORS = {
    EAdd: ("+", _arith(lambda a, b: a + b)),
    EConcat: ("++", _concat),
    ESub: ("-", _arith(lambda a, b: a - b)),
    EMul: ("*", _arith(lambda a, b: a * b)),
    EDiv: ("/", _divide),
    ELessThan: ("<", _compare(lambda a, b: a < b)),
    ELessThanEq: ("<=", _compare(lambda a, b: a <= b)),
    EGreatThan: (">", _compare(lambda a, b: a > b)),
    EGreatThanEq: (">=", _compare(lambda a, b: a >= b)),
    EEq: ("==", _equals),
}


def apply_unary(node, operand):
    """The value of a unary operator application. Raises _Trap for an
    operand the operator does not accept. Expr -> Value -> Value"""
    match (node, operand):
        case (ENeg(), VInt(a)):
            return VInt(wrap32(-a))
    raise _Trap(RuntimeError_(
        node.info,
        f"`-` cannot be applied to {describe(operand)}",
    ))


def _comprehension_envs(clauses, env):
    """Every environment a comprehension's clauses produce, in order.
    Used only where the whole comprehension is call-free, so nothing
    here can suspend or print. [CompClause] -> Env -> (Env,)"""
    if not clauses:
        yield env
        return
    match clauses[0]:
        case CompFor(_, pattern, sequence, _):
            match _evaluate(sequence, env):
                case VList(items):
                    pass
                case other:
                    raise _Trap(RuntimeError_(
                        clauses[0].info,
                        f"a comprehension walks a list, not {describe(other)}",
                    ))
            for item in items:
                inner = match_pattern(env, pattern, item)
                if inner is not None:
                    yield from _comprehension_envs(clauses[1:], inner)
        case CompIf(_, condition, _):
            match _evaluate(condition, env):
                case VBool(True):
                    yield from _comprehension_envs(clauses[1:], env)
                case VBool(False):
                    pass
                case other:
                    raise _Trap(RuntimeError_(
                        clauses[0].info,
                        f"the condition of a comprehension must be Bool, not "
                        f"{describe(other)}",
                    ))


# A `_divide` that fails has no node to hand, so it raises with this and
# `apply_binary` puts the real position in. Every other rule answers
# None and lets the operand message below do the reporting.
_DIVIDE_INFO = Info("<division>", 0, 0, 0, 0)


def apply_binary(node, left, right):
    """The value of one binary operator application. Raises _Trap for
    operands the operator does not accept.
    Expr -> Value -> Value -> Value"""
    spelling, rule = OPERATORS[type(node)]
    try:
        value = rule(left, right)
    except _Trap as trap:
        raise _Trap(RuntimeError_(node.info, trap.error.message)) from None
    if value is None:
        raise _Trap(RuntimeError_(
            node.info,
            f"`{spelling}` cannot be applied to {describe(left)} and "
            f"{describe(right)}",
        ))
    return value


def describe(value):
    """A value's type name, as Pyking spells it, for an error message.
    Value -> String"""
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
        case VTuple(elements):
            return f"a tuple of {len(elements)}"
        case VClosure() | VBuiltin():
            return "a function"
    return "a value"


# ---------------------------------------------------------------------
# Builtins
# ---------------------------------------------------------------------


def apply_builtin(name, args, call, host):
    """Applies one of analyses.BUILTINS. print crosses the runtime
    interface through host; the rest are pure.
    String -> [Value] -> ECall -> Host -> Value"""
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
    """One small step. Total: every state, including a finished or
    failed one, has a successor. State -> State"""
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
    """Starts on an expression: evaluates it directly if call-free,
    otherwise pushes the first continuation it needs.
    State -> Expr -> State"""
    if expr.sym in state.runtime.simple:
        try:
            return _go(state, control=CApply(_evaluate(expr, state.env)))
        except _Trap as trap:
            return failed(state, trap.error)
    match expr:
        case EAdd() | EConcat() | ESub() | EMul() | EDiv() | ELessThan() \
                | ELessThanEq() | EGreatThan() | EGreatThanEq() | EEq():
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
        case ETuple(_, elements, _) | EList(_, elements, _):
            return _start_elements(
                state, expr, (), tuple(elements), state.env, state.kont
            )
        case ENeg(_, operand, _):
            return _go(
                state,
                control=CEval(operand),
                kont=KNegate(expr, state.env, state.kont),
            )
        case EListComp(_, _, _, _):
            return _comprehend(
                state, expr, (), (), state.env, state.env, state.kont
            )
        case EIf(_, cond, _, _, _):
            return _go(
                state,
                control=CEval(cond),
                kont=KChoose(expr, state.env, state.kont),
            )
        case _:
            # A literal or a name: call-free, so the fast path above has
            # already dealt with it. Anything else is outside the
            # fragment.
            return failed(state, unsupported(expr))


def _step_stmt(state, stmt):
    """Starts on a statement: delivers what it supplies (PYKING.md,
    "Tail position") to its continuation. State -> Stmt -> State"""
    match stmt:
        case SLet(_, target, expr, _, _):
            return _go(
                state,
                control=CEval(expr),
                kont=KBind(target, state.env, state.kont),
            )

        case SLetStmt(_, target, inner, _, _):
            # `x = if c: ...` binds whatever the branch that runs
            # yields; `x = loop ...` the accumulator it stopped with.
            return _go(
                state,
                control=CStmt(inner),
                kont=KBind(target, state.env, state.kont),
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

        case SLoop(_, target, init, _, _, _, _, _):
            loop = Loop(stmt, UNIT, state.env, state.kont, state.loops)
            if target is None:
                # No accumulator to work out: go straight on to whatever
                # decides the first turn. Every turn carries unit.
                return _start(state, loop)
            return _go(state, control=CEval(init), kont=KStartLoop(loop))

        case SBreak(info, expr, _) | SContinue(info, expr, _):
            loop = state.loops
            if loop is None:
                keyword = "break" if isinstance(stmt, SBreak) else "continue"
                return failed(
                    state, RuntimeError_(info, f"'{keyword}' outside a loop")
                )
            leaving = isinstance(stmt, SBreak)
            if expr is None:
                # The accumulator this turn started with is what a bare
                # `break` yields and what a bare `continue` goes round
                # with -- the same value, put in two different places.
                return (_leave(state, loop, loop.accumulator) if leaving
                        else _turn(state, loop))
            return _go(state, control=CEval(expr), kont=KExit(loop, leaving))

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

        case SMatch(_, subject, _, _):
            return _go(
                state,
                control=CEval(subject),
                kont=KScrutinee(stmt, state.env, state.kont),
            )

        case SFunctionSig():
            # A signature says what a `def` in this block is. The checker
            # has read it; there is nothing to run, and it supplies unit.
            # `pyk.py` erases these before a program is run, so only the
            # REPL -- which checks and runs one entry as it stands -- gets
            # here.
            return _go(state, control=CApply(UNIT))

        case SFunctionDef():
            # The name has been in scope since the block began; this is
            # where it becomes a function, capturing what is bound here.
            # The statement itself supplies unit.
            return _go(state, control=CApply(UNIT), env=define(state.env, stmt))

        case _:
            return failed(state, unsupported(stmt))


def _step_apply(state, value):
    """Hands value to whatever was waiting for it (state.kont).
    State -> Value -> State"""
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

        case KBind(target, env, rest):
            try:
                bound = bind_target(env, target, value)
            except _Trap as trap:
                return failed(state, trap.error)
            return _go(state, control=CApply(UNIT), env=bound, kont=rest)

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

        case KElement(node, done, todo, env, rest):
            return _start_elements(state, node, done + (value,), todo, env, rest)

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

        case KChoose(node, env, rest):
            match value:
                case VBool(True):
                    chosen = node.then_expr
                case VBool(False):
                    chosen = node.else_expr
                case _:
                    return failed(state, RuntimeError_(
                        node.cond.info,
                        f"the condition of an 'if' must be Bool, not "
                        f"{describe(value)}",
                    ))
            return _go(state, control=CEval(chosen), env=env, kont=rest)

        case KDiscard(env, rest):
            return _go(state, control=CApply(UNIT), env=env, kont=rest)

        case KStartLoop(loop):
            return _start(state, replace(loop, accumulator=value))

        case KSequence(loop):
            match value:
                case VList(items):
                    return _begin(state, replace(loop, remaining=items))
            return failed(state, RuntimeError_(
                loop.node.iterate.info,
                f"a 'for' loop walks a list, not {describe(value)}",
            ))

        case KTest(loop):
            match value:
                case VBool(True):
                    return _turn(state, loop)
                case VBool(False):
                    return _finish(state, loop)
            return failed(state, RuntimeError_(
                loop.node.iterate.info,
                f"the condition of a 'while' must be Bool, not "
                f"{describe(value)}",
            ))

        case KEnding(loop):
            # The `then:` block's value is the loop's own.
            return _leave(state, loop, value)

        case KIterate(loop):
            # What the body produced is the next turn's accumulator --
            # unless the loop carries none, in which case it is thrown
            # away and every turn starts from unit again.
            if loop.node.target is None:
                return _begin(state, loop)
            return _begin(state, replace(loop, accumulator=value))

        case KExit(loop, leaving):
            if leaving:
                return _leave(state, loop, value)
            return _begin(state, replace(loop, accumulator=value))

        case KNegate(node, env, rest):
            try:
                return _go(state, control=CApply(apply_unary(node, value)),
                           env=env, kont=rest)
            except _Trap as trap:
                return failed(state, trap.error)

        case KScrutinee(stmt, env, rest):
            # Matching evaluates nothing, so every arm is tried here and
            # the first that fits has its body run. A `match` that fits
            # none does nothing and supplies unit (PYKING.md).
            for case_clause in stmt.cases:
                inner = match_pattern(env, case_clause.pattern, value)
                if inner is not None:
                    return _go(
                        state,
                        control=CApply(UNIT),
                        env=inner,
                        kont=KSeq(case_clause.body, 0, env, rest),
                    )
            return _go(state, control=CApply(UNIT), env=env, kont=rest)

        case KComprehend(node, want, index, frames, done, env, outer, rest):
            return _comprehended(
                state, node, want, index, frames, done, value, env, outer, rest
            )

        case KReturnTo(frame):
            return _go(
                state,
                control=CApply(value),
                env=frame.env,
                kont=frame.kont,
                stack=frame.parent,
                loops=frame.loops,
            )


# A comprehension is a nested loop that builds a list, and the machine
# runs it as one: `frames` is the loop stack, innermost last, each frame
# holding which clause it belongs to, the items it has left, and the
# environment that clause was entered in. `_comprehend` asks for the
# next thing to be evaluated; `_comprehended` receives it. Everything
# that can suspend -- a sequence, a condition, an element -- goes round
# that pair, which is what lets a comprehension calling a printing
# function interleave correctly.


def _comprehend(state, node, frames, done, env, outer, rest):
    """Drives a comprehension one step: enters the next clause, or takes
    the next item, or builds the list when nothing is left.
    State -> EListComp -> (Frame,) -> (Value,) -> Env -> Env -> Kont
    -> State"""
    index = len(frames)
    if index == len(node.clauses):
        # Every clause is entered: this environment yields one element.
        return _go(
            state,
            control=CEval(node.expr),
            env=env,
            kont=KComprehend(
                node, "element", index, frames, done, env, outer, rest
            ),
        )
    match node.clauses[index]:
        case CompFor(_, _, sequence, _):
            return _go(
                state,
                control=CEval(sequence),
                env=env,
                kont=KComprehend(
                    node, "sequence", index, frames, done, env, outer, rest
                ),
            )
        case CompIf(_, condition, _):
            return _go(
                state,
                control=CEval(condition),
                env=env,
                kont=KComprehend(
                    node, "test", index, frames, done, env, outer, rest
                ),
            )


def _comprehended(state, node, want, index, frames, done, value, env, outer,
                  rest):
    """One value a comprehension asked for has arrived. State -> ... ->
    State"""
    if want == "element":
        return _take(state, node, frames, done + (value,), outer, rest)
    if want == "test":
        match value:
            case VBool(True):
                return _comprehend(
                    state, node, frames + ((index, (), env),), done, env,
                    outer, rest
                )
            case VBool(False):
                return _take(state, node, frames, done, outer, rest)
        return failed(state, RuntimeError_(
            node.clauses[index].info,
            f"the condition of a comprehension must be Bool, not "
            f"{describe(value)}",
        ))
    match value:
        case VList(items):
            return _take(state, node, frames + ((index, items, env),), done,
                         outer, rest)
    return failed(state, RuntimeError_(
        node.clauses[index].info,
        f"a comprehension walks a list, not {describe(value)}",
    ))


def _take(state, node, frames, done, outer, rest):
    """Takes the next item of the innermost `for`, skipping items its
    pattern does not match, and unwinds a frame that has run out."""
    while frames:
        index, items, entered = frames[-1]
        match node.clauses[index]:
            case CompIf():
                # A test's frame holds no items; it is a marker that the
                # test passed, and unwinding it is all there is to do.
                frames = frames[:-1]
                continue
            case CompFor(_, pattern, _, _):
                pass
        if not items:
            frames = frames[:-1]
            continue
        inner = match_pattern(entered, pattern, items[0])
        frames = frames[:-1] + ((index, items[1:], entered),)
        if inner is None:
            continue                       # the pattern filters it out
        return _comprehend(state, node, frames, done, inner, outer, rest)
    return _go(state, control=CApply(VList(done)), env=outer, kont=rest)


def _start_arguments(state, call, callee, done, todo, env, rest):
    """Evaluates the next argument, or makes the call if todo is empty.
    State -> ECall -> Value -> (Value,) -> (Expr,) -> Env -> Kont -> State"""
    if todo:
        return _go(
            state,
            control=CEval(todo[0]),
            env=env,
            kont=KArgument(call, callee, done, todo[1:], env, rest),
        )
    return _call(state, call, callee, done, env, rest)


def _start_elements(state, node, done, todo, env, rest):
    """Evaluates the next element of a tuple or a list literal, or
    builds it if todo is empty. The two are one path because they differ
    only in what is built at the end.
    State -> ETuple|EList -> (Value,) -> (Expr,) -> Env -> Kont -> State"""
    if todo:
        return _go(
            state,
            control=CEval(todo[0]),
            env=env,
            kont=KElement(node, done, todo[1:], env, rest),
        )
    built = VList(done) if isinstance(node, EList) else VTuple(done)
    return _go(state, control=CApply(built), env=env, kont=rest)


def match_pattern(env, pattern, value):
    """The environment a pattern binds when it matches value, or None
    when it does not. Nothing here evaluates, so matching can neither
    suspend nor fail at run time -- a pattern that cannot match simply
    says so. Env -> Pattern -> Value -> Env?"""
    match (pattern, value):
        case (PWildcard(), _):
            return env
        case (PCapture(_, name, _), _):
            return extend(env, name, value)
        case (PInt(_, wanted, _), VInt(got)):
            return env if wanted == got else None
        case (PString(_, wanted, _), VString(got)):
            return env if wanted == got else None
        case (PBool(_, wanted, _), VBool(got)):
            return env if wanted == got else None
        case (PTuple(_, elements, _), VTuple(parts)) if len(elements) == len(parts):
            for element, part in zip(elements, parts):
                env = match_pattern(env, element, part)
                if env is None:
                    return None
            return env
        case (PText(_, prefix, name, suffix, _), VString(text)):
            if len(text) < len(prefix) + len(suffix) \
                    or not text.startswith(prefix) \
                    or not text.endswith(suffix):
                return None
            middle = text[len(prefix):len(text) - len(suffix)]
            return env if name is None else extend(env, name, VString(middle))
        case (PList(_, prefix, rest, suffix, _), VList(items)):
            return match_list(env, list(prefix), rest, list(suffix or []), items)
    return None


def match_list(env, prefix, rest, suffix, items):
    """A list pattern against a list's items: the prefix from the front,
    the suffix from the back, and the rest marker whatever is left over.
    Without a rest marker the length must be exact.
    Env -> [Pattern] -> ListRest? -> [Pattern] -> (Value,) -> Env?"""
    if rest is None:
        if len(items) != len(prefix):
            return None
        taken, middle = items, ()
    else:
        if len(items) < len(prefix) + len(suffix):
            return None
        taken = items[:len(prefix)] + items[len(items) - len(suffix):] \
            if suffix else items[:len(prefix)]
        middle = items[len(prefix):len(items) - len(suffix)] if suffix \
            else items[len(prefix):]
    for pattern, item in zip(prefix + suffix, taken):
        env = match_pattern(env, pattern, item)
        if env is None:
            return None
    match rest:
        case ListRest(_, name, _) if name is not None:
            env = extend(env, name, VList(middle))
    return env


def bind_target(env, target, value):
    """env with every name in an assignment target bound to its part of
    value. Raises _Trap if a destructuring target does not fit the value
    it was given. Env -> AssignTarget -> Value -> Env"""
    match target:
        case TargetName(_, name, _):
            return extend(env, name, value)
        case TargetTuple(info, elements, _):
            match value:
                case VTuple(parts) if len(parts) == len(elements):
                    for element, part in zip(elements, parts):
                        env = bind_target(env, element, part)
                    return env
            raise _Trap(RuntimeError_(
                info,
                f"this binding takes {len(elements)} values apart, but it "
                f"was given {describe(value)}",
            ))


def _begin(state, loop):
    """Decides whether the loop takes another turn, and starts it. A
    `for` takes the next item, a `while` asks its condition, and a bare
    `loop:` goes round unconditionally. State -> Loop -> State"""
    match loop.node.iterate:
        case ForIn():
            if not loop.remaining:
                return _finish(state, loop)
            return _turn(state, loop)
        case WhileTest(_, condition, _):
            # The condition can ask about the accumulator, so it is
            # evaluated where the accumulator is bound.
            env = loop.env
            if loop.node.target is not None:
                try:
                    env = bind_target(env, loop.node.target, loop.accumulator)
                except _Trap as trap:
                    return failed(state, trap.error)
            return _go(
                state, control=CEval(condition), env=env,
                kont=KTest(loop), loops=loop.parent,
            )
    return _turn(state, loop)


def _start(state, loop):
    """The first thing a loop needs: a `for`'s sequence, evaluated once
    before any turn. State -> Loop -> State"""
    match loop.node.iterate:
        case ForIn(_, _, sequence, _):
            return _go(
                state, control=CEval(sequence), env=loop.env,
                kont=KSequence(loop), loops=loop.parent,
            )
    return _begin(state, loop)


def _finish(state, loop):
    """The loop has run out of turns. Its `then:` block, if it has one,
    says what it is worth; otherwise it is worth the accumulator it
    stopped with. State -> Loop -> State"""
    if loop.node.after is None:
        return _leave(state, loop, loop.accumulator)
    env = loop.env
    if loop.node.target is not None:
        try:
            env = bind_target(env, loop.node.target, loop.accumulator)
        except _Trap as trap:
            return failed(state, trap.error)
    return enter_block(
        _go(state, control=state.control, loops=loop.parent),
        loop.node.after,
        env,
        KEnding(loop),
    )


def _turn(state, loop):
    """Starts a turn of loop's body, with the accumulator bound afresh.
    The body's value goes to KIterate, which comes back here -- so a
    turn costs no continuation chain, however many turns there are.
    State -> Loop -> State"""
    env = loop.env
    if loop.node.target is not None:
        try:
            env = bind_target(env, loop.node.target, loop.accumulator)
        except _Trap as trap:
            return failed(state, trap.error)
    match loop.node.iterate:
        case ForIn(_, name, _, _):
            # Each turn binds the element afresh, and the loop keeps
            # what is left for the next one.
            env = extend(env, name, loop.remaining[0])
            loop = replace(loop, remaining=loop.remaining[1:])
    return enter_block(
        _go(state, control=state.control, loops=loop),
        loop.node.body,
        env,
        KIterate(loop),
    )


def _leave(state, loop, value):
    """Ends loop with value: the loop's own value, delivered where the
    loop statement stood. State -> Loop -> Value -> State"""
    return _go(
        state,
        control=CApply(value),
        env=loop.env,
        kont=loop.kont,
        loops=loop.parent,
    )


def _call(state, call, callee, args, env, rest):
    """Applies callee (a builtin or closure) to args.
    State -> ECall -> Value -> (Value,) -> Env -> Kont -> State"""
    match callee:
        case VBuiltin(name):
            try:
                value = apply_builtin(name, list(args), call, state.runtime.host)
            except _Trap as trap:
                return failed(state, trap.error)
            return _go(state, control=CApply(value), env=env, kont=rest)

        case VClosure(name, params, body, captured):
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
            frame = Frame(name, call.info, rest, env, state.stack, depth, state.loops)
            call_env = extend_all(captured, zip(params, args))
            # The frame is pushed here; `KReturnTo` is what pops it, and
            # what puts the caller's own environment, continuation and
            # loops back when the call produces its value. The callee
            # runs inside none of the caller's loops, which is the same
            # thing src/parser.py says statically about a `break`.
            entered = _go(state, control=CApply(UNIT), stack=frame, loops=None)
            return enter_block(entered, body, call_env, KReturnTo(frame))

        case _:
            return failed(state, RuntimeError_(
                call.info,
                f"this call applies {describe(callee)}, which is not a function",
            ))


def enter_block(state, stmts, env, rest):
    """Enters a block: declares its defs, then runs its statements in
    order, delivering the last one's value to rest.
    State -> [Stmt] -> Env -> Kont -> State"""
    return _go(
        state,
        control=CApply(UNIT),
        env=declare(stmts, env),
        kont=KSeq(tuple(stmts), 0, env, rest),
    )


def failed(state, error):
    """state with error in the control position; nothing else changed
    or unwound. State -> RuntimeError_ -> State"""
    return _go(state, control=CFailed(error))


# ---------------------------------------------------------------------
# Driving the machine
# ---------------------------------------------------------------------


def initial_state(stmts, host, env=None, max_depth=MAX_CALL_DEPTH):
    """A machine about to run stmts, not yet stepped. env, if given,
    lets a caller continue an earlier session (default: a fresh top
    level). [Stmt] -> Host -> Env? -> Int -> State"""
    start = top_level_env() if env is None else env
    runtime = Runtime(host, call_free_symbols(stmts), max_depth)
    state = State(CApply(UNIT), start, None, None, runtime)
    return enter_block(state, stmts, start, None)


def finished(state):
    """Whether the machine has stopped (done or failed). State -> Bool"""
    return isinstance(state.control, (CDone, CFailed))


def run(state, steps=None):
    """Steps until the machine stops or steps steps have been taken,
    whichever comes first. State -> Int? -> State"""
    taken = 0
    while not finished(state) and (steps is None or taken < steps):
        state = step(state)
        taken += 1
    return state


def result(state):
    """The value a finished machine produced, or None if it failed or
    has not finished. State -> Value?"""
    match state.control:
        case CDone(value):
            return value
    return None


def failure(state):
    """The RuntimeError_ a machine stopped on, or None.
    State -> RuntimeError_?"""
    match state.control:
        case CFailed(error):
            return error
    return None


def unwrap(state):
    """state, or its error raised. State -> State"""
    error = failure(state)
    if error is not None:
        raise error
    return state


def run_program(stmts, host=None, max_depth=MAX_CALL_DEPTH):
    """Runs a whole (already checked and symbolized) program to
    completion. [Stmt] -> Host? -> Int -> State"""
    return run(initial_state(stmts, host or ConsoleHost(), max_depth=max_depth))


def declare_entry(state, stmts):
    """state with every def in stmts declared, as one group (their
    names come into scope together). State -> [Stmt] -> State"""
    return _go(state, control=state.control, env=declare(stmts, state.env))


def eval_in(state, stmt):
    """Runs one statement in state's environment as it stands (nothing
    is declared first), with a continuation chain of its own. Returns
    the state it leaves behind. State -> Stmt -> State"""
    runtime = replace(
        state.runtime, simple=state.runtime.simple | call_free_symbols(stmt)
    )
    return run(State(CStmt(stmt), state.env, None, None, runtime))


def eval_statement(state, stmt):
    """Declares and runs one statement: eval_in for a group of one.
    State -> Stmt -> State"""
    return eval_in(declare_entry(state, [stmt]), stmt)


def stack_trace(state):
    """The calls in progress, innermost first. State -> [(String, Info)]"""
    trace = []
    frame = state.stack
    while frame is not None:
        trace.append((frame.name, frame.info))
        frame = frame.parent
    return trace
