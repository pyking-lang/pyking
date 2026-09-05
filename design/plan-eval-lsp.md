# Interpreter, REPL, debugging, LSP and DAP — a design

A plan, not an implementation. It covers what to build, how to split it,
what each piece may reuse, and which decisions have to be made
consciously rather than by accident.

> **Written when the compiler was Python.** It is now OCaml in `src/`,
> and two of this plan's premises have moved with it: "servers in
> Python" is now "servers reusing `src/`", and the browser reaches the
> compiler through js_of_ocaml rather than through Pyodide — the
> playground ships the compiler itself, so the "Pyodide disappears"
> line in the table below has already happened. Everything the plan
> says about *what to build* — the resumable machine, the two
> protocol-free cores, name resolution as one pass — is unaffected, and
> is what CLAUDE.md's "Where the project is going" tracks against.

The short version:

- **One evaluator**, written as a *resumable machine* over the existing
  AST, in `src/`. Everything else is a client of it.
- **Two protocol-agnostic cores** — a *debug session* and a *query
  service* — so that DAP and the playground debugger are two transports
  over one session, and LSP and the playground's editor help are two
  transports over one query service.
- **Servers in Python**, reusing `src/` directly; editor plugins are
  thin shims that launch them. The browser gets the same servers through
  Pyodide, which the playground already runs.
- **One new front-end pass** (name resolution), which serves the
  interpreter's speed, LSP's go-to-definition, and the debugger's
  variable views at once — folded into `analyses.py`, not a new module.
- **Four new files in `src/`**, not nine (§3).

---

## 1. What exists, and what shapes the design

The design is constrained by what is already here. These are facts about
the repository, not assumptions:

| | |
|---|---|
| Front end | `lexer.py` → `parser.py` → `syntax.py` (AST) → `analyses.py` (`analyze_program`, `symbolize`) → `typesystem.py` (`type_check` → `tmap`) |
| Every node carries `Info` | file, `row1`, `col1`, `row2`, `col2` — rows 1-based, columns 0-based |
| Every node carries `sym` | a unique integer from `symbolize`, already used as a key by `tmap` |
| Errors carry a position | `LexError`, `ParseError`, `AnalysisError`, `TypeError_`, `UnsupportedError` |
| Backends are peers | `target_python.py`, `target_js_core.py` + packaging, `target_c.py`, `target_java.py` — each translates the *shared* AST |
| The host boundary is written down | `runtime_interface.py`: the operations (`print`) and the exact formatting rules every host must obey |
| Builtins are a list | `analyses.BUILTINS` = `print`, `range`, `str`, `len` |
| The test harness runs programs | `tests/test_cases.toml` names targets per program; one `.out` is compared across all of them; `typecheck` is already a "target" that compiles nothing |
| The browser already runs the compiler | `tools/playground/` copies `src/` into Pyodide and drives it from a worker over `postMessage` |
| `src/` is flat and self-hosting-bound | plain script modules, one per stage, `match`/`case` over dataclasses, "obvious over clever", and eventually to be rewritten *in Pyking* |

Two of these matter more than the rest.

**The self-hosting constraint** rules out designs that lean on Python
features Pyking does not have. Generators-as-coroutines would make a
resumable evaluator almost free in Python, and would have to be thrown
away at the rewrite. An explicit machine ports to anything.

**The test harness** is the anti-duplication weapon. An interpreter is a
*second definition of the language's semantics*, and the way to keep it
honest is to make every existing program run under it and compare
against the same `.out` file — which the harness already does for nine
targets. This is worth more than any amount of care in review.

---

## 2. Layering

```
                     ┌────────────────────────────────────────────┐
   existing          │ lexer → parser → syntax → analyses          │
   front end         │        → resolve (new) → typesystem         │
                     └───────────────┬────────────────────────────┘
                        ┌────────────┴─────────────┐
                        ▼                          ▼
          ┌──────────────────────────┐   ┌──────────────────────────┐
          │ backends (existing)      │   │ evaluator (new)          │
          │ python js c java         │   │ values, environ, machine │
          └──────────────────────────┘   └────────────┬─────────────┘
                                        ┌─────────────┴──────────────┐
                                        ▼                            ▼
                            ┌────────────────────┐      ┌────────────────────┐
                            │ debug session core │      │ query service core │
                            │ (protocol-free)    │      │ (protocol-free)    │
                            └───┬────────────┬───┘      └───┬────────────┬───┘
                                ▼            ▼              ▼            ▼
                              DAP        playground        LSP       playground
                            (stdio)     (postMessage)    (stdio)   (postMessage)

                    CLI (`pyk run`) and REPL (`pyk repl`) sit directly
                    on the evaluator; `pyk build` keeps the backends.
```

The rule the diagram encodes: **nothing above the cores knows about a
protocol, and nothing below them knows a protocol exists.** DAP and the
playground debugger differ only in how requests arrive and how state
leaves; LSP and in-browser editor help likewise.

---

## 3. New modules

`src/` holds twelve modules today, 86 to 2069 lines each. Nine more would
nearly double the count and dilute the "one module per stage" story that
makes it readable. **Four is enough**, because two of the pieces belong
in modules that already exist.

### Recommended: four new modules

| module | holds | rough size |
|---|---|---|
| `interp.py` | the runtime value ADT (`VInt` … `VClosure`) with `format_value`, environment records and `var` cells, the machine (`State`, `Frame`, continuations, `step`), runtime errors, the embedding API (`run`, `run_to_completion`, `eval_in`), and the concrete hosts | ~1000 lines — half of `target_python.py` |
| `debug.py` | the protocol-free session: breakpoints, stepping policy, the event stream, stack and variable views | ~350 |
| `queries.py` | the protocol-free language service: diagnostics, hover, definition, references, completion, symbols, semantic tokens, inlay hints | ~500 |
| `repl.py` | the terminal REPL and its meta-commands | ~250 |

Three things deliberately get **no file of their own**:

- **Name resolution goes into `analyses.py`.** It *is* an analysis, and
  CLAUDE.md already says to keep new ones there as separate `analyze_*`
  entry points. That module holds two passes already (`analyze_program`,
  `symbolize`); resolution is the third, and it shares its walk with the
  first rather than repeating it.
- **The `Host` protocol goes into `runtime_interface.py`.** That module
  already *names* the operations a host must provide and pins their
  semantics; a base class with one method per operation is the same fact
  in code rather than prose. The concrete hosts — console, buffering,
  callback — are an embedding concern and live in `interp.py`, so the
  module keeps its "no Python, no JavaScript" rule.
- **`Diagnostic` goes beside `Info` in `lexer.py`**, which is already
  where every module imports its source-position vocabulary from. If
  that reads oddly, a 40-line `diagnostics.py` is a fifth file and no
  great loss — but the precedent is there.

The two service modules have to be in `src/` rather than under `tools/`:
the playground ships `src/*.py` into Pyodide and nothing else, so
anything the browser debugger or in-browser editor help needs must live
there. The *servers* (`tools/lsp/`, `tools/dap/`) stay outside, being
pure transport.

### If `interp.py` grows too big: prefixed families, still flat

The repository already has an answer for "modules that belong together":
a shared prefix, not a directory — `target_js_core.py` and
`target_js_packaging.py` beside `target_c.py` and `target_java.py`. The
same idiom applies:

```
src/eval_values.py      values, environments, cells, formatting
src/eval_machine.py     State, continuations, step, run
src/ide_queries.py      language-service answers
src/ide_debug.py        session, breakpoints, stepping, events
src/repl.py             the terminal REPL
```

Five or six files instead of four, the grouping legible at a glance, and
nothing changes about how modules are imported, built or shipped. Worth
doing if `interp.py` passes roughly 1200 lines; not worth doing
pre-emptively.

### Why not subdirectories

`src/eval/`, `src/services/` would be the conventional answer in most
projects. Here it costs three specific things:

1. **`src/` is deliberately not a package** — no `__init__.py`, no
   relative imports; modules import each other flat because Python puts
   `src/` on the path when `pykboot.py` runs. Subdirectories need either
   per-directory `sys.path` surgery or real packages, and CLAUDE.md rules
   the second out explicitly.
2. **Pyking has no module system.** These files are to be replaced *in
   place* by Pyking sources at the self-hosted rewrite, and a directory
   hierarchy is not something the target language can express — it would
   have to be flattened again.
3. **The playground would need changing**: `compiler_modules()` is a flat
   `glob("*.py")`, and the worker loads what it copies as top-level
   modules inside Pyodide. Subdirectories mean touching the manifest, the
   copy step and the import path.

If Pyking ever grows modules, revisit — at that point the compiler's own
layout should follow the language's.

---

## 4. The evaluator

### 4.1 Values and environments

Values are the same style as the rest of the compiler: one frozen
dataclass per variant, with a `datatype` comment block naming the closed
set, exactly as `syntax.py` does for the AST.

Environments are where the interpreter gets to be *simpler* than the
Python backend. Pyking's own scoping is what the interpreter implements
directly:

- a block entered → a new environment record whose parent is the
  enclosing one;
- `=` → a new slot in the current record (rebinding shadows, it does not
  mutate);
- `var` → a slot holding a **cell**; `:=` writes the cell;
- a `def` → a `VClosure` capturing *the record it was created in*.

Everything the last few rounds of design work fought for in
`target_python.py` — lexical capture, a rebinding not reaching back into
an earlier closure, a loop turn keeping its own bindings — falls out of
this for free: each turn of a loop makes a new record, and a closure
holds the one it saw. No renaming, no factories. That is worth stating
in the docs, because it makes the interpreter the *reference* for these
semantics and the Python backend the thing that has to match it.

### 4.2 Why a machine, and which kind

The debugger, the playground and DAP all need the same thing: execution
that can be **paused, inspected and resumed**, without blocking a thread
and without a second implementation. Four candidates:

| approach | resumable | speed | ports to self-hosted Pyking | cost |
|---|---|---|---|---|
| recursive tree-walk + hooks | only by blocking a thread | fastest | yes | needs threads; unusable as-is in a browser worker without `SharedArrayBuffer` and COOP/COEP headers |
| generator coroutines | yes, cheaply | good | **no** (Pyking has no generators) | throwaway at the rewrite |
| **explicit machine over the AST** | yes | moderate | yes | an explicit continuation stack to write and maintain |
| bytecode VM | yes | best | yes | a whole second IR: codegen, instruction set, debug-info side tables, another doc page |

**Recommendation: the explicit machine over the AST.** It is the only
option that is resumable everywhere, portable, and keeps a single
description of the semantics in terms of the AST the rest of the
compiler already talks about — which is also what makes the debugger's
"where am I" answer trivial: the current node *is* the position, and
`node.info` is already the span to highlight.

The bytecode VM is the right answer if the interpreter ever becomes
performance-critical (running the self-hosted compiler, say). It should
not be built now, but the `interp.py` façade should be the only thing
the cores talk to, so that a bytecode tier can be slid underneath
without touching DAP, LSP, the REPL or the playground.

### 4.3 Shape of the machine

```
State = (control, environment, continuations, call stack, host)
step(State) -> State          # one small step, total, no I/O except via host
```

- **Continuations** are frozen dataclasses too: `KBinOpRight(op, right, env)`,
  `KCallArgs(func, done, todo, env)`, `KLetBind(target, sym, env)`,
  `KBlock(remaining, env)`, `KReturn`, and so on. One class per "what to
  do with the value I am about to get", matched in `step`.
- **Frames** carry the function being run, its environment, and the
  continuation depth at entry — enough for a stack trace and for
  `stepOut`.
- **Errors** raise `RuntimeError_(info, message)`, following the existing
  convention (`TypeError_`), so `pykboot`-style reporting works
  unchanged: `'file' row:col-row:col Runtime error: ...`.

A runtime error is a chance to say something better than the host
languages do. Calling a function before its `def` has run is currently a
Python `NameError` in generated code; the interpreter can say *"`helper`
is in scope but its `def` has not run yet"* with the span.

### 4.4 Efficiency

Three things matter, in order:

1. **Slots, not dicts.** With `resolve.py` (§5), every name occurrence
   knows its `(depth, slot)`, so an environment record is a list and a
   lookup is two array indexings. This is the single largest win and it
   costs nothing at the machine level.
2. **Don't allocate what you don't need.** Literals, variable reads and
   fully-evaluated operands need no continuation object; only
   *incomplete* work pushes one. A per-node flag from `resolve.py` —
   "this subtree contains no call" — lets the machine evaluate call-free
   expressions in one recursive gulp, since nothing inside can suspend.
   That is an optimisation of the same code path, not a second evaluator.
3. **Debug checks off the hot path.** When no session is attached,
   `run_to_completion` is a bare `while` loop over `step`; breakpoint
   and step-policy checks live behind one flag test.

Target: fast enough that `make test`'s interpreter pass is not the
slowest thing in the suite. If the self-hosted compiler ever runs on the
interpreter, revisit with the bytecode tier.

### 4.5 What the machine may assume about its host

The interpreter is written in Python *today* for the same reason
`lexer.py` is: it is the throwaway bootstrap. It must not become
dependent on Python the way the generated code in `target_python.py` is,
because the destination is Pyking compiled to machine code. Two very
different dependencies, and only one is a problem:

| | status |
|---|---|
| Python as the **semantic runtime** — Pyking meaning "whatever the generated Python does" | what this plan ends |
| Python as the **implementation language** of the current interpreter | temporary, like every other module in `src/` |

The rules that keep the second from turning into the first:

- **Errors are a machine state, not a host exception.** `State` has an
  error variant; nothing unwinds a host stack. On bare metal there is no
  exception mechanism to borrow, and a debugger wants to *stop at* an
  error and inspect the frames, not lose them.
- **Values are a tagged union.** One frozen dataclass per variant now, a
  variant type in Pyking later, a tagged word in machine code after
  that. No host object identity, no host dictionaries inside a value.
- **Environments are arrays**, indexed by the slots `resolve.py`
  computes — not host hash maps.
- **No host control flow.** No generators, no `sys.settrace`, no
  exceptions used for `return`; the continuation stack carries all of
  it.
- **No host memory model.** Closures keep environment records alive, so
  a real garbage collector is eventually a runtime service to design,
  not something to inherit from Python by accident. Nothing in the value
  representation should assume one exists.

### 4.6 One semantic question the interpreter forces: what is `Int`?

Python's integers are arbitrary precision; C's and Java's `int` are not.
That divergence is already in the tree — the same arithmetic can overflow
under `-t c23` and not under `-t python` — but nothing exercises it, so
it has never had to be decided.

An interpreter cannot dodge it: whatever it does becomes the reference,
and a machine-code backend will need the answer in a form it can
implement. The choice (fixed 64-bit with defined overflow, or arbitrary
precision with a bignum runtime) belongs in PYKING.md before phase 2
starts, not in whichever module happens to be written first.

### 4.7 Stack, depth and long runs

Putting Pyking's call stack in the machine's own data structure rather
than on the host's is what makes long runs safe: `step` is driven from a
flat `while` loop, so host stack depth is constant however deep the
Pyking program goes. Two consequences worth stating outright.

**Long runs are not the risk; depth is.** A loop of ten million turns
pushes and pops the same continuation and accumulates nothing. Only
recursion costs anything, and it costs heap, not C stack.

**The interpreter can recurse deeper than the compiled targets.**
Compiling to Python makes a Pyking recursion consume Python's own
recursion limit (1000 by default); C and Java have their own stack
limits. A 50 000-deep recursion would therefore run interpreted and die
compiled — a target difference of the same kind as `Int` above, to be
written down rather than discovered.

Four ways a stack problem can still appear, and what each requires:

1. **Accidental host recursion inside the machine.** The loop is flat,
   but the helpers around it are tempting to write recursively. The
   call-free-expression fast path (§4.4) is safe, because its depth is
   bounded by *source* nesting; anything that walks **runtime data** is
   not. `var v = []` followed by `v := [v]` in a loop nests a list one
   deeper per turn, so a recursive `format_value`, structural equality,
   or the debugger's variable expansion would blow the host stack on it
   — CPython's own list `repr` fails the same way. Rule: every value
   walk is iterative or depth-capped.

2. **Continuation growth per iteration** — the classic machine bug, and
   the easiest to write by accident. If a block of *n* statements pushes
   *n* continuations, or a `while` pushes a frame per turn that is only
   popped at loop exit, the problem has simply moved to the heap and
   memory grows with iteration count. Sequencing therefore uses an
   **index into the statement list** ("resume this block at statement
   4"), and a loop re-enters with the same continuation rather than
   stacking a new one.

3. **Runaway recursion becomes OOM instead of an error** — the one thing
   a heap stack makes *worse*. Under CPython, infinite recursion gives a
   quick `RecursionError`; on the heap it consumes memory until the
   machine swaps, the OOM killer fires, or a browser tab dies. So the
   machine carries an explicit **maximum call depth** (configurable,
   defaulting to something like 10 000) and raises a proper Pyking error
   with a span and a truncated stack trace when it is reached. In the
   playground this is not a nicety: an unbounded heap stack inside a
   worker takes the tab with it.

4. **The front end's own recursion is unchanged.** `parser.py` is
   recursive descent, and the analyses, the type checker and the
   backends all walk the AST recursively, so pathologically nested
   *source* already hits Python's limit today. The interpreter neither
   improves nor worsens that, and should not be assumed to.

**Tail calls: an option, deliberately not taken at first.** Pyking
already defines tail position as a language concept, so reusing a frame
for a tail call — constant-space tail recursion — is natural in a
machine. Two reasons to leave it out of the first version: it removes
frames from the stack trace, so DAP and error messages show a gap that
has to be marked explicitly; and it widens the interpreted-versus-
compiled divergence, since a program that only terminates *with* tail
calls would run interpreted and fail on every other target. With a heap
stack, tail calls are not needed for depth — only for constant space —
so this can be added later, behind the same API, once the language
decides whether it wants to promise it.

Two invariants to test in the same phase as the machine, because both
are silent until they are not:

```
loop of 100 000 turns   ->  continuation depth at turn 100 000 == at turn 1
recursion past the cap  ->  a Pyking error with a stack trace, never an OOM
```

---

## 5. The new front-end pass: `resolve.py`

Today `analyses.py` *checks* names and throws its environment away. Three
different consumers want that environment kept:

- the **interpreter**, for slot-indexed environments (§4.4);
- **LSP**, for go-to-definition, find-references, rename, and "what is in
  scope here" completion;
- the **debugger**, to show a frame's variables with their source names.

So: one pass, run after `analyze_program`, producing

```
Resolution = {
    uses:    {sym -> sym},          # a name occurrence -> its binding
    slots:   {sym -> (depth, slot)},# where that binding lives at run time
    scopes:  ScopeTree,             # spans -> names in scope, for position queries
    calls:   {sym -> bool},         # does this subtree contain a call?  (§4.4)
}
```

It reuses `analyses.py`'s walk rather than duplicating it: the cleanest
route is to make the existing walk *record* while it checks, and have
`analyze_program` return the resolution (ignored by callers who only
want the check). The rules it must follow are already settled and
documented — hoisted `def` names, positional `=`, one `def` per name per
block, `var` not shadowable — so this is bookkeeping, not new semantics.

This pass is also what makes rename safe: renaming is "rewrite every
occurrence whose resolution is this binding", which is exactly the
`uses` table inverted.

---

## 5b. Diagnostics as objects, and surviving a broken parse

Two gaps that only become visible once an editor is in the picture.

### Structured diagnostics

Every stage today raises an exception carrying an `Info` and a message
string, and `pykboot.py` formats it. That is right for a compiler and
thin for an editor. LSP wants severity, a stable **code** (so a quick fix
can target it and a user can look it up), and related positions ("the
mutable variable it collides with is declared here" — a message the
analysis already composes by hand).

Introduce one shape, used by every stage and every front end:

```
Diagnostic(code, severity, span, message, notes=[(span, message)], help=None)
```

The five existing error classes become carriers of one of these rather
than of a bare string, so the CLI, the REPL, the playground and LSP all
render the *same* diagnostic differently rather than composing their
own. Codes want a scheme fixed once (`PYK1xxx` lexical, `2xxx` syntax,
`3xxx` names, `4xxx` types, `5xxx` runtime) and a table in the docs.

### Parser error recovery

This is the one item that most affects how good the editor experience
feels, and neither the compiler nor my first draft addressed it: the
parser raises on the **first** error, so a file mid-keystroke yields one
diagnostic and *no AST* — which means no hover, no completion, no
symbols, no semantic tokens until the file parses again. Every serious
language server recovers instead.

The cheap, well-trodden version: on a parse error inside a statement,
record the diagnostic, skip tokens to the next statement boundary (a
`DEDENT` or a line start at the enclosing indent), and insert an
`SError` node holding the skipped span. The AST stays well-formed, later
passes treat `SError` as opaque, and the file keeps answering questions
around the broken part. `analyses.py` and `typesystem.py` each need one
case for it, and `--ast` prints it as a comment-like marker.

Worth doing *before* the LSP server rather than after, since every
capability degrades without it.

---

## 6. CLI and REPL

### 6.1 `pyk`

The wrapper gains subcommands while keeping today's flags working:

```
pyk <file>                     interpret it            (new default)
pyk run <file>                 the same, explicitly
pyk repl                       start the REPL
pyk build <file> [flags]       compile — today's --target/--output/--stdout/--ast/...
pyk check <file>               parse, analyse, type-check; diagnostics + exit code
pyk lsp [--stdio]              language server
pyk dap [--stdio|--port N]     debug adapter
pyk debug <file>               terminal stepper (thin; the editors are the real UI)
```

`pyk check` is worth having early: it is what CI runs, what an editor
without LSP can shell out to, and the smallest possible consumer of the
diagnostic objects above. `pyk fmt` is deliberately *not* in the list —
formatting cannot ship until the lexer keeps comments (§8.1), and a
formatter that deletes comments is worse than none.

Today `pyk <file>` compiles to a temp file and runs it with `python3`;
after this it interprets instead. That is a visible behaviour change and
belongs in the release notes: the *observable* output must be identical,
which the test suite enforces, but the mechanism differs (no Python is
generated, and runtime errors are reported in Pyking's own form).

`src/pykboot.py` keeps its current flag interface untouched, because
`tests/test_script.py` drives it directly.

### 6.2 The REPL

```
pyk repl
Pyking REPL.  :help for commands, :quit to leave.
> x = 21
> def double(n:Int) -> Int:
.     n * 2
.
> double(x)
42
> :type double
(Int) -> Int
> :vars
x       : Int      = 21
double  : (Int) -> Int
```

Mechanics:

- **Reading a statement.** Lex and parse the line; if the parse fails
  with an "unexpected end of input" error, keep reading (the prompt
  becomes `.`) until it parses or the user submits a blank line. This
  uses the parser's own answer rather than guessing from a trailing `:`.
- **State.** One machine `State` that outlives each entry: the top-level
  environment record, the analysis environment (so later lines see
  earlier names), and the `tmap` if type checking is on. `interp.py`
  exposes `eval_statement(state, stmt)` for exactly this, and DAP's
  `evaluate` request uses the same entry point against a paused frame.
- **Meta-commands**, all cheap because the pieces already exist:
  `:help`, `:quit`, `:vars`, `:type <expr>` (the checker), `:ast <stmt>`
  (`pprint_program`), `:tokens <line>` (the lexer), `:load <file>`,
  `:reset`, `:compile <target> <stmt>` (the backends — a genuinely
  useful teaching tool), `:step <stmt>` (drive the machine one step at a
  time, printing the control node and environment), `:break`/`:continue`
  for the same session core the debugger uses.
- **No third-party dependencies**: `readline` from the standard library
  gives history and editing — and, with a completer function fed from
  `resolve.scopes`, tab completion over the names actually in scope,
  which is the same answer LSP's completion gives from the same table.

---

## 7. Debugging

### 7.1 The session core (`src/debugsession.py`)

Protocol-free, and the only place stepping policy is written:

```
Session(program, host)
  .set_breakpoints(file, lines) -> [verified lines]
  .start(stop_on_entry)         -> Stopped | Terminated
  .cont() / .next() / .step_in() / .step_out() / .pause()
  .stack()      -> [Frame(name, span, id)]
  .scopes(frame_id)             -> [Scope(name, ref)]
  .variables(ref)               -> [Variable(name, value_repr, type, ref?)]
  .evaluate(frame_id, source)   -> Value | error     # via interp.eval_in
  .events                       -> output / stopped / terminated / error
```

- **Breakpoints** map a line to the first statement node whose `Info`
  starts on it — the same "verified line" answer DAP wants, and it comes
  from the AST rather than from text.
- **Stepping** is defined against the machine: `next` runs until the
  control node's statement changes at the same call depth, `step_in`
  until the depth increases, `step_out` until it decreases. All three are
  one predicate over `State`, which is why they are written once here and
  not twice in the two transports.
- **Variables** come from the environment records; a `VClosure` expands
  to its captured record, a `VList` to its elements. Values are rendered
  with `format_value`, so what the debugger shows and what `print`
  writes agree.
- **`setVariable` only works on a `var`.** An `=` binding is immutable
  by definition, so the capability is reported for cells and refused for
  bindings — a place where Pyking's own semantics decide a protocol
  answer, and worth getting right rather than pretending.

The session's output is an **event stream**, not just return values:

```
Started · LineReached(span) · BreakpointHit(id, span) · StepCompleted
FunctionEntered(name, span) · FunctionExited(name) · Errored(diagnostic)
OutputWritten(text) · Finished(status)
```

Events are what make the two transports thin: DAP maps them onto
`stopped`/`output`/`terminated`/`exited`, the playground pushes them to
the UI, and the REPL's `:step` prints them. A method-only core would
force each transport to reconstruct *why* execution stopped; an event
says so.

### 7.2 DAP (`tools/dap/`)

A translation layer, deliberately boring: JSON-RPC framing over stdio,
`initialize`/`launch`/`setBreakpoints`/`configurationDone`/`threads`/
`stackTrace`/`scopes`/`variables`/`evaluate`/`continue`/`next`/`stepIn`/
`stepOut`/`terminate`, plus `output` events fed by the host and
`stopped` events from the session. One thread, no attach-to-process
story, no async surprises — the session is synchronous and in-process.

Conditional breakpoints, logpoints and watch expressions are all
`Session.evaluate` with a Pyking expression, so they cost almost nothing
once `evaluate` exists. Exception breakpoints become "stop on any
runtime error", which the `Errored` event already provides.

`attach` is deliberately unimplemented: there is no long-running Pyking
process to attach *to*. If the playground ever wants an editor to drive
a browser session, that is the request to revisit.

### 7.3 In the playground

The worker already holds the compiler; it gains a `Session`. New
messages beside today's `compile`/`run`:

```
debug/start {source, breakpoints, stopOnEntry}
debug/step  {kind: next|in|out|continue}
debug/state {}            -> {status, span, stack, variables, output}
debug/stop  {}
```

State crosses `postMessage` as plain JSON — the same discipline the
existing shim uses (`compile_json` returns a string rather than a
PyProxy). The UI work is a gutter for breakpoints, a current-line
highlight in the Ace editor, and two panes (stack, variables) beside the
existing output pane; the Settings dialog gains a "Debugger" section.

Because both this and DAP sit on `Session`, "step over" means the same
thing in the browser and in VS Code by construction.

---

## 8. LSP

### 8.1 The query core (`src/queries.py`)

One document store, one pipeline per document version, and a set of
answers as plain Python data:

| capability | how it is answered | reuse |
|---|---|---|
| `publishDiagnostics` | run lex → parse → analyse → (optionally) typecheck; each error already carries a span | the five existing error types |
| `semanticTokens` | the token stream | `lexer.lexing` — the same source the playground's editor mode is generated from |
| `hover` | node at position → `sym` → `tmap` type, plus the binding's declaration line | `typesystem`, `resolve` |
| `inlayHint` | inferred types for unannotated bindings and parameters | `tmap` |
| `definition` / `references` / `documentHighlight` / `rename` | the `uses` table both ways | `resolve` |
| `completion` | names in scope at the position, keywords, builtins, type names, `case` patterns | `resolve.scopes`, `lexer` keyword list, `analyses.BUILTINS` |
| `documentSymbol` | `def`s and top-level bindings from the AST | `syntax` |
| `signatureHelp` | the callee's `TFunction` | `typesystem` |
| `formatting` | `pprint_program` — **but see the caveat below** | `syntax` |
| `codeAction` | quick fixes for the errors the checker already words well ("annotate the return type", "an `if` needs its `else`") | later |

**Two things to get right, both classic sources of bugs:**

1. **Positions.** `Info` is 1-based rows and 0-based *character* columns;
   LSP is 0-based lines and 0-based *UTF-16 code unit* columns. One
   conversion module, tested with non-ASCII input, used by both LSP and
   DAP. Do not scatter `± 1` through the servers.
2. **Formatting deletes comments.** `pprint_program` prints the AST, and
   the AST has no comments — the lexer drops them. Offering
   `textDocument/formatting` before that is fixed would silently eat a
   user's comments. Either defer formatting, or (better) have the lexer
   record comments as trivia with their `Info` and teach the printer to
   re-insert them. That is a small, self-contained project and it also
   improves `--ast` round-tripping.

### 8.2 The server (`tools/lsp/`)

Stdio JSON-RPC, full-document sync to begin with (these files are small;
incremental sync is an optimisation, not a correctness matter),
recompute-on-change with a per-version cache. Pyking has no imports, so a
"workspace" is a set of independent files — say so now, and note that
`workspace/symbol` and cross-file references become interesting only when
modules arrive.

Configuration: whether to run the type checker (it covers a fragment, so
its diagnostics should be opt-in per workspace), and inlay hints on/off.

---

## 9. Editors and packaging — "JavaScript, or something else?"

**Write the servers in Python. Do not write them in JavaScript.**

The reason is the requirement that comes above all the others here:
*avoid duplication*. LSP and DAP need the lexer, the parser, the
analysis, the type checker and the evaluator. Those exist, in Python. A
JavaScript server means a second implementation of all of it, drifting
from the first — the very failure this project keeps designing against.

The pull towards JavaScript is real but narrow: editors' *extension
hosts* are JS (VS Code), or Rust/WASM (Zed), or JVM (JetBrains). None of
that requires the **server** to be in their language — LSP and DAP exist
precisely so it need not be. What each editor needs is a *command to
run*, and a small shim to declare the language.

| editor | what you write | how the server is launched |
|---|---|---|
| VS Code | a thin TypeScript extension using `vscode-languageclient` and a `DebugAdapterExecutable`; a TextMate grammar for first-paint highlighting | `pyk lsp`, `pyk dap` |
| Emacs | nothing to write — configuration for `eglot` (built in since 29) and a DAP client | `pyk lsp` |
| Neovim | configuration for `nvim-lspconfig` and `nvim-dap` | `pyk lsp`, `pyk dap` |
| Vim | configuration for `vim-lsp` or `coc.nvim` | `pyk lsp` |
| Sublime | JSON settings for the `LSP` package, and the `Debugger` package for DAP | `pyk lsp`, `pyk dap` |
| Zed | a small extension (Rust compiled to WASM) that names the language and the server command | `pyk lsp` |
| PyCharm / IntelliJ | the platform's own LSP API is only in the paid IDEs; the practical route for Community is a third-party LSP/DAP client plugin (Red Hat's **LSP4IJ** is the usual choice) plus a configuration snippet, or a small Kotlin plugin that wraps it | `pyk lsp`, `pyk dap` |

*(The JetBrains and Zed rows are the two worth re-checking against
current releases before committing to them; the others are stable and
long-standing.)*

**Getting `pyk` onto a user's machine** is then the only real packaging
question, and there are three answers, in increasing order of effort:

1. **Require Python 3.11+** — what the project already requires, and
   what every contributor has. Perfect for the editors whose integration
   is configuration only.
2. **A zipapp** (`pyk.pyz`, built with `zipapp` from the standard
   library): one file, no dependencies to resolve, still needs a Python
   on the machine. Cheap to produce in CI and easy to document.
3. **A standalone binary per platform** (PyInstaller or similar) for the
   VS Code and Zed extensions, so a user who has never installed Python
   can still get diagnostics. This is the only place third-party build
   tooling enters, and it stays out of `src/`.

**And the browser gets the same servers.** The playground already runs
the real compiler under Pyodide; the query core and the session core run
there unchanged, spoken to over `postMessage` instead of stdio. That is
the decisive argument against a JavaScript rewrite: the one thing JS
would have bought — running in a browser — is already solved without it.

If some future tool genuinely cannot host Python, the integration
surface should be a documented **JSON-over-stdio** command
(`pyk query --json`), not a second implementation. LSP and DAP are that
interface; a third would only be needed for something they do not cover.

---

## 9b. Where this differs from the other design plan, and why

The second plan (written for the same question, without access to this
repository, and since merged away) converges
on the same fundamentals: one shared core, a session model, a debuggable
engine emitting events, thin JSON-RPC servers, editor plugins as
launchers, and the rule that language semantics must never be
reimplemented in JavaScript. Where two independent designs agree, the
answer is probably right.

Four places it points elsewhere, and what this plan does instead.

### The core in Rust or Go

Its headline recommendation is a compiled core (Rust/Go) with thin
servers. For a green field that is sound advice. Here it would mean a
**third** implementation of a language that already has one in Python and
is committed to a second in Pyking itself — the opposite of the reuse
requirement, and a permanent extra language in a project whose plan is to
end up self-hosted and native.

The real motive behind that advice is packaging: one binary, no runtime
to install. This plan gets the same end state without the third language
— zipapp and PyInstaller now (§9), native Pyking binaries once the
compiler emits machine code — because the editors only ever see *a
command to run*.

### A shared IR between compiler and interpreter

It recommends lowering the AST to an IR and interpreting that, partly
because "instruction-level stepping is easier and more precise". Here the
AST *is* the shared representation: five backends already consume it, and
every node carries the span a debugger needs. Adding an IR now means a
second thing to keep in step with `syntax.py` for a speed benefit nobody
has measured, and stepping over IR instructions is *less* precise for a
user than stepping over source nodes, not more — it needs a debug-info
table to get back to the span the AST hands over for free.

The disagreement is smaller than it looks: this plan keeps `interp.py` as
the only façade the cores use, precisely so a bytecode tier can be added
underneath if profiling ever demands it (§4.2).

### A monorepo of per-component directories

It proposes `core/lexer/`, `core/parser/`, `crates/`, `packages/`. This
repository is deliberately a flat `src/` of one script module per stage,
because that is what ports to a self-hosted rewrite, and CLAUDE.md says
so. The useful half of the suggestion — keeping *tools* out of the
language — is already the `src/` vs `tools/` split.

### A playground backend service

It suggests the playground run sessions on a server and keep the browser
thin. This playground runs the **whole compiler in the browser** under
Pyodide, with nothing server-side — a property its README makes a point
of. The session core running inside the existing worker keeps that;
a server would trade it away for nothing.

### Constructs Pyking does not have

Its runtime list includes `break`/`continue`/exceptions, module loading,
a dependency graph, lazy stdlib loading. Pyking has none of these yet, so
none of them should be built for. The corresponding entry in this plan is
"a workspace is a set of single files until Pyking has modules" — say so,
rather than half-build it.

### Four things taken from it

- **The event stream** as the session core's output (§7.1) — a better
  seam than method returns for three transports.
- **Structured diagnostics with stable codes** (§5b), which this plan
  had left as "the existing error types" without saying what an editor
  needs from them.
- **Parser error recovery** (§5b) — the omission that would have most
  hurt the editor experience.
- Smaller ones: `pyk check`, REPL tab completion, `setVariable`, watch
  expressions, exception breakpoints, golden debug traces.

---

## 9c. The road to a native Pyking

The protocol choices are what make the eventual self-hosted, machine-code
compiler invisible to everything above:

| | today | after self-hosting |
|---|---|---|
| `pyk`, `pyk lsp`, `pyk dap` | Python, run from a zipapp or a binary | Pyking, compiled to a native binary |
| editors | point at a command | *unchanged* |
| playground | Pyodide runs the Python compiler (~12 MB) | the Pyking compiler compiled to WASM; Pyodide disappears |
| session and query cores | Python modules in `src/` | Pyking modules in `src/`, same shape |
| semantics | defined by the interpreter | *unchanged* — which is the point of making it the reference |

Two things that rewrite will need which do not exist yet, and which
should not be discovered late: **JSON encoding/decoding in Pyking** (LSP
and DAP are JSON-RPC), and a **garbage collector** or equivalent, since
closures keep environment records alive. Both are runtime/stdlib items
to schedule, not architectural problems — but the value representation
(§4.5) has to stay free of host-GC assumptions for the second to be
possible at all.

---

## 10. Testing

| what | how |
|---|---|
| interpreter semantics | a new `interp` "target" in `tests/test_cases.toml`, run like `typecheck` is: no compilation, run the program under the interpreter, compare against the **same** `.out` as the other nine targets |
| interpreter errors | `fail_interp_*.pyk` fixtures whose `.out` is the runtime error message, mirroring the `fail_typecheck_*` convention |
| stack behaviour (§4.7) | a long loop asserting the continuation stack is the same depth at the end as at the start, and a runaway recursion asserting a clean depth-limit error rather than an OOM |
| REPL | transcript files (`tests/repl/*.txt`) of input lines and expected output, replayed by a small script — same style as the rest of the suite |
| debug session | scripted sessions: set breakpoints, step *n* times, assert on stack/variable snapshots, in plain Python data, with no protocol involved |
| DAP | a recorded JSON conversation driven over pipes; assert the responses |
| LSP | the same, per capability; positions are the thing to assert hardest |
| editors | a documented manual smoke matrix, plus one automated VS Code e2e if it earns its keep |

The first row is the one that matters: **every program in `tests/` must
mean the same thing interpreted as compiled**, and the harness makes
that a one-line change per program rather than a new test suite.

---

## 11. Phases

Each phase is independently useful and ends with the suite green.

| # | deliverable | new code | docs to update |
|---|---|---|---|
| 0 | decide `Int` (§4.6); introduce the `Diagnostic` object and codes across the five error types | small | `PYKING.md`, `docs/architecture.md` |
| 1 | `resolve.py`, wired into `analyze_program`, no behaviour change | small | `docs/architecture.md`, `CLAUDE.md` |
| 2 | values, environments, machine, `interp.py`, `pyk run`, `interp` test target, the depth cap and the two stack invariants (§4.7) | the bulk of the work | `docs/interpreter.md` (new), `PYKING.md` (runtime errors, recursion depth), `docs/targets.md`, `CLAUDE.md` |
| 3 | REPL and meta-commands | small | `docs/repl.md` (new), `README.md` |
| 4 | `debugsession.py` + playground debugger UI | medium | `docs/debugging.md` (new), `tools/playground/README.md` |
| 5 | DAP server + VS Code/Emacs/Neovim configs | medium | `docs/debugging.md`, `tools/editors/` |
| 5b | parser error recovery (`SError`), so a half-typed file still answers questions | small–medium | `docs/architecture.md`, `PYKING.md` (grammar note) |
| 6 | query core + LSP server + editor configs | medium | `docs/lsp.md` (new), `tools/editors/` |
| 7 | packaging: zipapp, binaries, VS Code and Zed extensions | small each | `README.md`, release notes |
| 8 | comment trivia in the lexer, then LSP formatting | small | `PYKING.md`, `docs/lsp.md` |

Phases 4–6 can run in parallel once phase 2 lands, because they meet only
at the two cores.

---

## 12. Risks, and what to do about them

| risk | mitigation |
|---|---|
| **The interpreter and the compilers disagree** — two definitions of one semantics | the `interp` target runs every existing program against the same `.out`; new semantic decisions get a test that runs on both |
| The machine is slow enough to be annoying | slots from `resolve.py`; no continuation objects for call-free subtrees; the bytecode tier behind the `interp.py` façade if it is ever needed |
| An explicit continuation stack is more code than a tree-walk | it is, and that is the price of resumability; keep one continuation class per "what next", matched in one `step`, and document them as a `datatype` block like the AST |
| LSP position bugs | one conversion module, tested with non-ASCII, used by both servers |
| Formatting eats comments | do not ship formatting until the lexer keeps trivia (phase 8) |
| Editor plugin rot | keep every plugin thin — a command line and a language id; anything smarter belongs in the server |
| `pyk <file>` changing meaning | release note; identical observable behaviour enforced by the suite; `pyk build` keeps the old path |
| Self-hosting drift | no generators, no metaclasses, no `sys.settrace`; one dataclass per variant and `match`, as everywhere else in `src/` |
| Python's runtime leaking into the semantics (arbitrary-precision `Int`, host GC, host exceptions) | §4.5's rules, and deciding `Int` before phase 2 |
| An editor experience that collapses on a syntax error | parser recovery in phase 5b, before the LSP server |
| A heap call stack turning runaway recursion into an OOM (a browser tab, worst case) | an explicit depth cap raising a Pyking error, tested (§4.7) |
| A construct that grows the continuation stack once per loop iteration | index-based sequencing, plus the long-loop invariant test (§4.7) |
| Deep recursion working interpreted and failing compiled | documented as a target difference alongside `Int`, next to the other rows in `docs/targets.md` |

---

## 13. Decisions worth recording

1. **The evaluator is an explicit resumable machine over the AST**, not a
   recursive walker, not generators, not (yet) bytecode. Resumability is
   a requirement from three directions at once, and it must survive the
   rewrite into Pyking.
2. **One debug session core and one query core, both protocol-free.**
   DAP, LSP and the playground are transports.
3. **The servers are Python and reuse `src/` directly.** Editor plugins
   are thin shims. The browser gets the same servers through Pyodide.
4. **Name resolution becomes a real pass** whose output three consumers
   share.
5. **The interpreter is the reference for runtime semantics**, because
   it implements Pyking's scoping directly rather than mapping it onto a
   host language's. Where a backend disagrees, the backend is wrong.
6. **`pyk <file>` interprets**; compiling moves under `pyk build`, with
   `src/pykboot.py`'s flags unchanged for the test harness.
7. **A workspace is a set of single files** until Pyking has modules.
   Say so rather than half-building cross-file features.
8. **The implementation language stays Python, then Pyking** — not Rust
   or Go. Packaging is solved with zipapps and binaries, not with a third
   implementation (§9b).
9. **Errors are machine states and structured diagnostics**, never host
   exceptions carrying strings (§4.5, §5b).
10. **The parser recovers** rather than stopping at the first error, so
    that an editor keeps working on a file being typed (§5b).
11. **`Int` is decided before the interpreter is written** (§4.6),
    because the interpreter becomes the reference for it.
12. **A depth cap raises a Pyking error; it never runs out of memory**
    (§4.7). Machine state lives on the heap, so the limit has to be
    explicit rather than inherited from the host.
13. **No tail-call elimination in the first version** (§4.7): it costs
    stack frames the debugger wants and widens the gap between
    interpreted and compiled behaviour. Addable later, unchanged API.
