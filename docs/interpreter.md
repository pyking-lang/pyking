# `interpreter.ml`: design

How `src/interpreter.ml` runs a Pyking program directly from its AST,
and why it is built as a small-step machine rather than a recursive
evaluator. For the pipeline-level view (where the interpreter sits
relative to the backends, what "reference semantics" means), see
[architecture.md](architecture.md), "The interpreter"; for a one-page
summary of its data structures and functions, see
[source.md](source.md#interpreterml).

## Why not just write `eval`

The obvious way to run an AST is a recursive function: `eval(expr, env)`
calls itself on sub-expressions and returns a value, the host language's
own call stack doing all the bookkeeping. It would be shorter than what
this file has, and it would be a dead end, because of one requirement
none of this project's other backends have to satisfy: **execution has
to be pausable.** A debugger needs to stop after one statement and let
something inspect the environment; a step-through in the browser
playground needs to run a bounded number of steps and hand control back
to the page's own event loop rather than blocking it; a DAP adapter
needs the same thing over a wire protocol. A recursive `eval` offers
exactly one way to pause: block the host thread it's running on, which
is no pause at all from the point of view of anything else that needs
to run.

The fix is the classic one for exactly this problem: turn "what happens
next" into **data** instead of leaving it on the call stack. That's
what `Kont` is — a linked chain of small objects, each one saying "when
a value arrives, here's what to do with it, and here's what to do after
that" — and once "what happens next" is a value instead of a stack
frame, a *paused machine* is simply that value, sitting in a variable,
touched by nothing until something calls `step` on it again. `state` is
a plain record; keeping one *is* how a debugger pauses. There is no
other mechanism.

## Reading the machine: `Control`, `Kont`, and one step at a time

Every `State` bundles five things: `control` (what the machine is doing
right now), `env` (the environment that applies to it), `kont` (what to
do with the value once `control` produces one), `stack` (Pyking's own
call stack — see below), and `runtime` (settings that never change
during a run). `step(state) -> state` looks at `control` and decides
what to do:

- **`CEval(expr)`** — evaluate an expression. If it contains no call
  (see "The call-free fast path" below), do the whole thing in one go
  and jump straight to `CApply`. Otherwise, take the *first* piece of
  work that expression needs, push a continuation recording the rest,
  and switch `control` to evaluate that first piece.
- **`CStmt(stmt)`** — execute one statement, similarly.
- **`CApply(value)`** — a value has arrived; hand it to whatever
  `state.kont` says to do with it (`step_apply`).
- **`CDone(value)`** / **`CFailed(error)`** — the machine has stopped;
  `step` on either of these is the identity, which is what makes `run`
  a bare loop with no special-casing of "are we finished yet" beyond
  checking `control`'s type.
- **`CWaiting(n, info)`** — an external call is waiting for the host's
  answer (see "Waiting for the host" below); `step` is the identity
  here too, and `run` stops, until `resume` hands it the answer.

Walking through a concrete case makes the shape click. Take `double(21)
+ 1`, where `double` is an ordinary `def double(n): return n * 2`. This
expression is *not* call-free (it contains `double(21)`), so it goes
through the continuation machinery step by step rather than the fast
path:

1. `CEval(EAdd(double(21), 1))`. `step_eval` sees an `EAdd`, and pushes
   a `KBinaryLeft(node, right=1, env, rest=<whatever was there before>)`
   — "once the left operand's value arrives, evaluate the right one" —
   and switches to `CEval(double(21))`.
2. `CEval(ECall(double, [21]))`. Not call-free by definition. `step_eval`
   pushes `KCallee(call, env, rest=KBinaryLeft(...))` — "once the callee
   itself has a value, start on the arguments" — and switches to
   `CEval(EVar(double))`, which *is* call-free (looking up a name
   involves no call), so it resolves immediately to `CApply(VClosure(...))`.
3. `CApply(VClosure(...))`, with `kont = KCallee(...)`. `step_apply`'s
   `KCallee` case starts on the argument list via `start_arguments`,
   which — finding one argument left to evaluate — pushes
   `KArgument(call, callee, done=(), todo=(21,), env, rest=KBinaryLeft(...))`
   and evaluates `21`.
4. `21` is call-free; `CApply(VInt(21))` arrives with `kont =
   KArgument(...)`. `start_arguments` is called again, this time with
   `todo` empty, so `call` actually applies the closure: it checks
   arity, checks `max_depth`, builds a new `Frame` recording *this*
   point (`rest = KBinaryLeft(...)`, the caller's `env`, the caller's
   `stack`) and pushes it onto `state.stack`, then switches to
   evaluating `double`'s own body — `n * 2` — in a *fresh* environment
   built from the closure's captured `env` extended with `n = 21`, with
   `kont = KReturnTo(frame)`.
5. `n * 2` runs to `VInt(42)`, `CApply(42)` arrives with `kont =
   KReturnTo(frame)`. This is where the call actually ends: `env`,
   `kont`, and `stack` are all restored from `frame` — back to whatever
   they were in step 1, before the call was ever entered — and `control`
   becomes `CApply(42)` again, but now with `kont = KBinaryLeft(...)`
   waiting from step 1.
6. `KBinaryLeft` fires: the left operand (`42`) has arrived, so evaluate
   the right one (`1`, call-free, immediate), producing
   `KBinaryRight(node, left=42, env, rest)`.
7. `KBinaryRight` fires: both operands are in, `apply_binary` computes
   `43`, and `CApply(43)` is delivered to whatever `rest` was before any
   of this started.

Nothing here recursed on the host's own stack past one `step` call —
every intermediate "what happens next" was a `Kont` value sitting in
`state.kont`, which is exactly what makes it possible to call `run(state,
steps=1)` after step 3 above and get back a `State` that is just as
inspectable, just as resumable, and just as cheap to keep around as the
one `initial_state` produced. A debugger pausing here would see
`double`'s call in `state.stack`, `n = 21` in `state.env`, and could
step again, or not, on its own schedule.

## Three properties, and why each one is load-bearing

**Depth costs heap, not host stack.** Because a Pyking call pushes a
`frame` onto `state.stack` — an ordinary linked value — rather than a
host stack frame, a Pyking program can recurse far deeper than the host
language's own call stack would allow: `step` is called from a flat
loop, so nothing grows the OCaml stack per Pyking call.
`max_depth` (10,000) is an *explicit*, checked limit in `call`, raising
an ordinary Pyking
`Runtime_error` — with the calls in progress listed, via
`stack_trace` — rather than letting a runaway recursion exhaust memory
or crash the host process. That is a *language* decision (see
PYKING.md), made here because the interpreter is what defines runtime
semantics, rather than an accident of the implementation.

`Int` is the opposite case, and worth contrasting: it holds at least 32
bits and overflow is **undefined**, so nothing here narrows a result at
all. An `Int` is the host's own `int` — 63 bits natively, 32 under
js_of_ocaml — and the same program may print different things in the
terminal and in the playground once it passes 2^31. Both conform;
`docs/targets.md` has the table.

**A block never grows the continuation chain.** `KSeq(stmts, index,
exit_env, rest)` runs a whole statement list by *incrementing an index*
into it (`KSeq(stmts, index + 1, ...)`), not by nesting one continuation
per statement the way a naive "do this, then do the next thing"
translation would. A ten-thousand-statement block therefore costs one
`KSeq` frame throughout, not ten thousand — which matters because
`Kont` frames are exactly what a paused state has to carry, and exactly
what a long-running loop would otherwise pile up unboundedly. `KSeq` is
also the **one** continuation that adopts the environment it's handed
rather than restoring the one it captured when it was built — every
other `Kont` variant carries an `env` and puts it back when it fires,
because an expression is evaluated in the scope it was *written* in,
regardless of what environment happened to compute the value flowing
into it. `KSeq` deliberately breaks that rule, and that break *is* how
a binding becomes visible to the statements after it in the same block:
statement `i`'s value arrives, `KSeq` moves to statement `i+1` using
whatever environment statement `i` left behind (which, if statement `i`
was `SLet`, is an extended one), not the environment the block started
with.

**An error is a state, not an exception thrown through `step`.**
`step` is total — it is documented as answering *every* state,
including an already-`CFailed` one, with another state — which is what
lets `run` be an unconditional `while` loop with no `try`/`except`
wrapped around each iteration. Internally, `evaluate`, `apply_binary`
and `apply_builtin` *do* raise (a private `_Trap`, never
`Runtime_error` directly), but every one of those call sites catches it
immediately and turns it into `failed(state, error)` before `step`
returns — so from the outside, a runtime error never unwinds anything.
`state.env`, `state.kont`, and `state.stack` are all still exactly what
they were the instant the error happened; only `control` changes, to
`CFailed(error)`. That is deliberately different from how a host
exception would behave (which unwinds the very frames a debugger would
want to inspect) and it's the reason a future debugger can implement
"break on error" by simply *not* calling `step` again once `control`
becomes `CFailed`, with the whole state of the failing call sitting
right there to look at.

## Environments: what makes closures (and the Python backend's renaming) unnecessary here

`Env(bindings, parent)` is a **persistent** chain — `extend(env, name,
value)` builds a brand-new one-entry frame pointing at the old `env` as
`parent`; nothing already built is ever mutated (`define`, below, is
the sole, deliberate exception). `lookup` walks outward until it finds
the name or runs out of chain. This is the same "rebuild, don't mutate"
discipline `analyses.ml` and `typesystem.ml` both use for their own
environments — see those pages — applied here to actual runtime values
instead of types or binding-kinds.

The payoff is that Pyking's scoping rules fall out of this
representation for free, with no extra bookkeeping anywhere: a block
runs in a chain of its own (built by `enter_block`, discarded when the
block's `KSeq` finishes and restores `exit_env`), `=` always builds a
*new* frame rather than updating one in place (so a rebinding shadows
rather than mutates — `x = 1`, `def f(): x`, `x = 2` really does leave
`f`'s closure holding the *first* `x`, because that closure captured
the `Env` chain as it stood at the moment `f` was defined, and nothing
after that moment can reach backward and change what that chain's nodes
mean), and a closure — `VClosure`'s `env` field — simply *is* the chain
that was current when its `def` was reached, no different in kind from
any other value carrying a reference to something built earlier.

It's worth noticing what this buys against `target_python.ml`'s design
in particular: that backend has to detect exactly the situations where
Python's own function-scoped variables would behave differently from
Pyking's block-scoped ones, and *rename* to compensate (`total`,
`total2`, ...; a per-turn factory for a `def` inside a loop — see that
module's own page). None of that machinery exists here, because nothing
here is being translated into a host language with different scoping
rules. The interpreter doesn't approximate Pyking's scoping; it *is*
Pyking's scoping, directly, which is exactly what makes it the
reference implementation the compiled backends are checked against.

## A program of several modules: one machine, several top levels

`run_modules(units, host)` runs a program whose modules were put in
dependency order by `src/module.ml`. Each module runs in a top level of
its own, and what it exports is what the ones after it are given:
`module_env` builds a module's starting environment from the exports
collected so far — a selected name under the name it is known by here,
and a field of a plain import under `alias.field`, exactly the spelling
`typesystem.import_env` uses for the same statements — and
`exported_values` reads its public names back out of the environment it
left behind.

Two details are load-bearing.

**A module's top level is not a block.** The `runner` (`runner_step`)
runs its statements one at a time in the state's own environment, the
way the REPL runs an entry, rather than `enter_block`. A block puts the enclosing scope back
when it ends (that is what `KSeq`'s `exit_env` is for), and a module's
top level has no enclosing scope to go back to: what it bound *is* what
it exports, so it has to survive.

**There is one call-free table for the whole program**, not one per
module. A closure a module exports is called from the module that
imported it, and the table `step_eval` reads it against is the calling
machine's, so a per-module table would leave the callee's body outside
the fragment the fast path knows about. Symbols are unique across a
program (`analyses.symbolize` continues its numbering from module to
module), so the union of the modules' tables is exactly right.

An import itself is a no-op at run time -- its names were bound when the
module's environment was built -- and `EQualified` is one `lookup` of a
dotted name, so neither adds a value kind or a continuation.

`run_modules` is `load_modules` started from an empty machine, and
`load_modules` drives a `runner` to its end: the same sequence, one
step at a time, that a debugger steps (`start_modules`,
`runner_step`; see [debugging.md](debugging.md)).
`load_modules(state, units, exports)` runs modules into a machine that
is already running -- what a REPL entry's imports do -- adding their
call-free tables to its own and their exports to the ones it was given,
and `bind_imports(state, stmts, exports)` binds an entry's imported names
into the machine's environment, the way `module_env` does for a module's
top level.

## `declare`/`define`: the one mutation, and why it exists

Every other binding in this module is built by `extend`, immutably. `def`
needs something else, because of a rule stated in PYKING.md: every
`def` in a block is visible **throughout** that block, including above
where it's written (so two functions can call each other, or a helper
can sit below its only caller) — but a function's body still has to
capture the environment *as it stood where the `def` is written*, not
some later, more-filled-in version of it.

`declare(stmts, env)` (called once per block, by `enter_block`, via
`block_functions` — the very same helper `analyses.ml` and
`typesystem.ml` use to find "the `def`s of this block," so all three
modules agree about what's being hoisted) puts one `VUndefined(name)`
placeholder per `def` into a fresh frame, *before* any statement in the
block runs. That's what makes a name resolve — `lookup` finds it,
bound, in scope — even before its `def` statement has executed;
`evaluate`'s `EVar` case specifically distinguishes "not bound at all"
from "bound, but still `VUndefined`" so that calling a function too
early gets a message that says exactly that (`'name' is in scope, but
its 'def' has not run yet`) rather than the more confusing "unbound
name."

`define(env, node)` — the interpreter's one mutation — is what happens
when the block actually reaches that `def` statement: it walks
*outward* through the `Env` chain to find the frame `declare` already
created for this name (not a new frame — the same one, so every other
name already resolving to it keeps resolving to the same cell) and
overwrites that one entry with the real `VClosure`, built by capturing
`env` **as it is at that point** — which is what secures the second
half of the rule: a function's captured environment is where it's
*written*, not the block-entry environment `declare` used to make the
name resolvable ahead of time. Everything before the assignment is
immutable; this and `mutate` are the two exceptions, and this one exists
because nothing immutable could make one cell mean two different things
(in scope, then defined) at two different points without either widening
what a "binding" is or accepting this one controlled mutation instead.

`mutate(env, name, value)` is the other, and it is `var` and `:=`.
`KVarBind` declares a mutable variable in a **new** frame, which is what
makes the cell fresh each time the declaration runs — once per turn of a
loop it is written in — and `KMutate` walks outward exactly as `define`
does and overwrites that frame's entry. A closure holding the
environment therefore sees what is written afterwards, which is what a
`var` means: it is one cell, not a value copied at capture time (see
`tests/typecheck_var_scope.pyk`). Pyking refuses to shadow a `var`, so
the outward walk cannot find the wrong one.

## Loops: a stack beside the frames, and a continuation that replaces itself

A `break` has to find the loop it belongs to, exactly as a `return` has
to find the call it leaves. `return` has `Frame`, so `loop` has `Loop`:
a persistent stack in `State.loops`, each entry holding the accumulator
this turn started with, the environment the loop is written in, and the
continuation the loop's own value goes to. A `break` delivers that
accumulator there -- which is what the loop is worth, and what a
`for`/`while` running out of turns delivers too (`finish`); `continue`
starts the next turn with it instead.

The turn itself is where the shape matters. `turn` binds the
accumulator afresh in the loop's own environment and enters the body
with `KIterate` waiting for its value — and `KIterate` calls `turn`
again, *replacing* itself rather than pushing anything. So a loop of ten
million turns holds exactly as much as a loop of one, which is the same
property `KSeq`'s index gives a block, and the reason `loop:` with no
`break` is a program that runs rather than one that swallows memory.

Both jumps also *abandon* the continuation chain the body built up to
that point, which is precisely what leaving a block early means; nothing
has to unwind, because the chain is a value rather than a host stack.

A call entering from inside a loop takes the loop stack with it in its
`Frame` and starts with none of its own, so a `break` written in a
function called from a loop body cannot reach that loop. `src/parser.ml`
already refuses such a program, so this is the same rule said twice —
and the machine holding it means a `break` can never escape through a
call by accident.

## The call-free fast path

Most of an ordinary Pyking program computes without ever suspending —
arithmetic, comparisons, an `if` whose condition and chosen branch are
themselves calculations. Building a `Kont` for every sub-expression of
`(a + b) * (c - d)` would be correct but wasteful: none of those
sub-expressions can reach the host or need to hand control back to
anything, so there's nothing for the small-step discipline to buy in
exchange for the allocation.

`call_free_symbols(node)` is computed **once**, before a run starts
(`initial_state` stores the result in `Runtime.simple`, which never
changes afterward), by a generic walk — the same style `symbolize`
uses in `analyses.ml`, for the same reason: it doesn't need to know
what *kind* of expression it's looking at, only whether an `ECall`
appears anywhere underneath. Every expression node whose subtree
contains no call gets its symbol recorded; `step_eval` checks
`expr.sym in state.runtime.simple` before doing anything else, and if
it's there, hands the whole subexpression to `evaluate` — an ordinary
recursive function, no continuations involved — and jumps straight to
`CApply` with the answer.

This is safe specifically *because* it's call-free: `evaluate`'s own
recursion is bounded by how deeply the **source** nests expressions
(`(((1 + 2) + 3) + 4)` nests four deep in the parsed tree, and no
running program can make that number four grow), never by anything
the *program* computes at runtime — unlike a hypothetical recursive
`eval` over the whole language, which would grow without bound on a
deep Pyking recursion. A call, by construction, is the one place
control might need to suspend (to let a debugger stop, or because the
call itself might not return promptly), so a call-containing expression
always goes through the full step-by-step machinery, and only a
call-free one ever takes the shortcut.

**A lambda is call-free whatever its body holds.** Building a closure
calls nothing: the body runs when the lambda is applied, somewhere else
entirely. So the walk answers `true` at an `ELambda` without looking
inside it, while still recording the symbols in its body — those
expressions are stepped later, when the closure is called, and need
their own entries. A lambda whose body prints would otherwise be
treated as a suspending expression at the point it is *written*, which
is not where it prints.

`analyses.ml`'s `Effects` stops at a lambda for the same reason, which
is what keeps `target_ocaml.ml` and `target_c.ml` from pinning an
evaluation order around a closure that produces nothing.

## Values: no host objects

`Value`'s variants — `VInt`, `VFloat`, `VString`, `VChar` (a code
point), `VBool`, `VUnit`, `VList`,
`VTuple`, `VClosure`, `VBuiltin`, `VUndefined` — hold nothing from
outside this small vocabulary: a `VList`'s elements are more `Value`s, a
`VClosure`'s
captured environment is this module's own `env`, never an OCaml closure,
an OCaml array, or any other host-native object standing in for a Pyking
one. A **lambda** is a `VClosure` too, named `lambda` and holding the
one `SExprStmt` that supplies its body, so applying one goes through
exactly the machinery a `def` goes through and nothing here had to
learn a second way to call something. That restriction is about where this code is headed, not just about
today: CLAUDE.md's bootstrapping plan is to eventually rewrite this
compiler *in* Pyking, and a representation with host objects woven
through it wouldn't survive that translation — a `value` tree built only
from these nine shapes will.

## Hosts: where output actually goes

`Host` is a tiny protocol — `print_line` and `debug_line`, one per
`builtin.ml` host-crossing entry (see that module's own page for what
the interface itself specifies), and `externals`, how a module
implemented in a target language is reached — with two constructors
serving two different embeddings: `console_host` writes to the real
standard output and standard error; `callback_host` hands each line to a
function, which is the shape both a debugger's "output" pane and a
browser worker's message-passing need. `debug_line` defaults to standard
error there too. None of the machine itself — `step`, `call`,
`apply_builtin` — knows or cares which one is in play; `apply_builtin`'s
host-crossing case calls `host.print_line` or `host.debug_line`, and
*which* host that is was fixed in `Runtime` when the run began --
`with_host` gives a machine another one, which is how a REPL session
gains a module's implementation when an entry imports it.

`externals` is `pyk`'s plugins (`src/plugin_host.ml`) in a terminal and
the page's JavaScript (`pykExternals`) in a browser. A function a module
declares is a `VHostFun`, called through `externals.call`; a value it
declares is asked of `externals.field` when the module is loaded.
`sys.exit` never reaches the machine as a value: the OCaml
implementation ends the process, and in a browser the call raises an
exception the bundle catches where it started the run.

### Waiting for the host

A host whose answer is not ready yet -- a page, for tinyweb's `sdelay`
-- raises `Wait n` from `externals.call`, naming the answer by a number
of its own. The call does not fail: the machine keeps the call's
continuation and environment and stops with `CWaiting (n, info)`, so
`waiting state` is `Some n`, `run` stops there, and `finished` stays
false. `resume state value` puts `value` in the control position as if
the call had answered it, and `run` goes on from there. Nothing about
the program is lost, since a state is a plain value -- the same
property that lets a debugger pause.

A function the host calls back runs on a machine of its own (`callback`).
Where that one waits, `callback` raises `Suspended (n, machine)`, which a
host calling it on its own -- the browser bundle's `pykCallback` -- keeps
and resumes later. A function an external module calls back while that
external's own call is under way cannot wait, since the external is
waiting for its answer: the call that waits fails with a runtime error
saying so. A runner's machine can wait too (`runner_waiting`); the
bundle's `pykRunProgram` steps the runner itself rather than through
`run_modules`, so it can stop there. The native hosts never raise
`Wait`: their `sdelay` blocks inside the call instead.
