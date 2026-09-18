# Pyking architecture

How the compiler is put together: the stages a program passes through,
the backends it can come out of, and the boundary between a Pyking
program and the world it runs in. For the language itself — syntax,
semantics, scoping rules — see [PYKING.md](../PYKING.md); for what each
compiler target supports and how it compiles, see
[targets.md](targets.md).

The compiler is built to bootstrap. `src/` holds a throwaway
implementation written in a convenient host language (OCaml), and the
plan is to eventually rewrite the compiler in Pyking itself and compile
it with this one. Nothing in `src/` is meant to survive that
transition, so it favours being obvious over being clever — and it is
why the code is written in a style that ports easily: one variant per
AST node, `match` over them rather than method dispatch, and values
threaded through rather than state mutated in place.

## The pipeline

```
                          foo.pyk
                             │
                    ┌────────▼────────┐
                    │ src/module.ml  │   the modules foo.pyk reaches,
                    │      load       │   dependencies first (each of
                    └────────┬────────┘   them through the stages below)
                             │
                    ┌────────▼────────┐
                    │  src/lexer.ml  │   characters → tokens
                    └────────┬────────┘
                    ┌────────▼────────┐
                    │ src/parser.ml  │   tokens → AST
                    └────────┬────────┘
                    ┌────────▼────────┐
                    │src/desugar_args │   default parameters and named
                    │      .ml        │   arguments → ordinary defs and
                    └────────┬────────┘   ordinary calls
                    ┌────────▼────────┐
                    │src/analyses.ml │   one unique integer per node
                    │   symbolize     │
                    └────────┬────────┘
                    ┌────────▼────────┐
                    │src/typesystem.ml│   names and types, always: leaves
                    └────────┬────────┘   the AST alone and fills a
                             │            symbol→type tmap
                    ┌────────▼────────┐
                    │src/analyses.ml │   `:=` names a `var`, and nothing
                    │analyze_mutability│  shadows one: rejects, never
                    └────────┬────────┘   rewrites
                    ┌────────▼────────┐
                    │src/opt_tailcall │   tail calls → loops, for a program
                    │      .ml        │   the checker accepted; then
                    └────────┬────────┘   symbolize again for what it built
                             │
                   src/syntax.ml AST — the one
                   thing every backend shares
                             │
      ┌─────────────────┴──────────┬──────────────────┬──────────────────┬──────────────┬──────────────┐
      ▼                            ▼                  ▼                  ▼              ▼              ▼
┌──────────────┐   ┌────────────────────────┐  ┌──────────────┐  ┌───────────────┐ ┌──────────────┐ ┌──────────────┐
│target_python │   │    target_js_core.ml   │  │ target_c.ml  │  │target_java.ml │ │target_ocaml  │ │interpreter.ml│
│ Py AST + pr. │   │    JS AST + printer    │  │ C AST + pr.  │  │ Java AST + pr.│ │ O AST + pr.  │ │values+machine│
└──────┬───────┘   └───────────┬────────────┘  └──────┬───────┘  └───────┬───────┘ └──────┬───────┘ └──────┬───────┘
       │                       │ JsRuntimeCall(…)     │ standard=        │ version=       │ reads the     │ runs the
       │           ┌───────────▼────────────┐         │ c89 | c23        │ java8|17|21    │ checker's     │ checker,
       │           │ target_js_packaging.ml │         │                  │                │ tmap          │ then the
       │           └─┬─────────┬──────────┬─┘         │                  │                │               │ program
       ▼             ▼         ▼          ▼           ▼                  ▼                ▼               ▼
    foo.py        foo.js   foo.html    foo.js       foo.c            Foo.java          foo.ml        (no file:
                                     + foo.node.js                                                    it runs)
                                     + foo.html
                                     + package.json

        src/builtin.ml — the contract both sides reference: what a
        program may call unbound, and what it may be observed doing
```

A program of several modules runs the middle of that pipeline once per
module, in the order `src/module.ml` puts them in, each checked against
what the ones it imports export; then every module goes through the
backend, and a module the program imports is written beside the
program's own output. See [modules.md](modules.md).

Everything above the split is target-independent, and every backend —
and the interpreter — starts from the same checked AST. The `pyking`
target is that AST printed back out, which is why it is a target with
nothing under the split: it is the shared program itself.

The interpreter is on the same line as the backends because it is their
peer, not their supervisor: it consumes the AST every one of them
consumes. What it does with it differs — it *runs* the program rather
than writing a file — which is why it is a command (`pyk <file>`, `pyk
repl`) rather than a `--target`.

## Stages

| module | role |
|---|---|
| `src/lexer.ml` | Characters → tokens. `Info` (file, row/column span) is attached to every token and rides along on every later node, so any stage can report an error against the source. |
| `src/parser.ml` | Recursive descent, tokens → the AST in `syntax.ml`. Also enforces the few rules the grammar cannot state (duplicate pattern bindings, "every branch of a bound `if` yields a value", one statement per line, what a block written on its header's own line may hold, and where a `break`/`continue` may stand). |
| `src/syntax.ml` | The AST itself — one variant type per node group — plus a pretty printer that prints Pyking back out. |
| `src/module.ml` | The module system: which modules a program is made of, in what order, what each exports, and what each import means. Runs first — it is what reads the files at all — and again between checks, since a module is checked against the signature `make_sigmap` took from the last one. Also owns *external* modules: a `<name>.external.pyk` declares what a module implemented in the target's own language offers, and this is where that is resolved, checked and named. |
| `src/desugar_args.ml` | Default parameters and named arguments, removed before anything reasons about the program. A default becomes a generated zero-argument `def` in the block the definition is written in, and an omitted argument becomes a call to it; a named argument is put back in its parameter's position. AST in, AST out, inside `module.load` and before `symbolize`, so no later stage knows the sugar exists and every target supports it. See [desugar_args.md](desugar_args.md). |
| `src/analyses.ml` | Static passes over the AST. `symbolize` gives every node a unique integer `sym`, rebuilding the tree (nodes are frozen), and runs before anything reasons about the program. `analyze_mutability` runs *after* the checker and applies the one rule a type cannot state: `:=` may only name a `var`, and nothing may shadow one. It only rejects, never rewrites. `Effects` is a third pass the driver never runs: the C and OCaml backends ask it which expressions can print, since their host languages leave evaluation order unspecified. |
| `src/typesystem.ml` | The type checker, and the only pass that checks *names*: its environment is a scope, so an unbound name is refused here, as an `Analyses.Analysis_error`. It runs for every mode and every target, since Pyking is statically typed — there is no flag and no way round it. It covers only part of the language; it leaves the AST alone and reports what it inferred in `tmap`, a symbol → type table, which is what `-t pyking` then prints from. It is given the signature of every module this one imports, and all it sees of another module is that. |
| `src/execution.ml` | What `--run` runs: the commands each target's host uses to build and run what was compiled. One table, so the driver stays a sequencer. |
| `src/opt_tailcall.ml` | Tail calls into loops: a function that calls itself in tail position becomes a `loop` carrying its parameters, and a group that tail-calls each other becomes one loop they share. AST in, AST out, after the checker and only for a program it accepted — the types decide which groups can share a loop, and what a slot a narrower member does not fill is entered with. `--no-tail-call-opt` turns it off. |
| `src/target_python.ml` | Python backend: its own `Py*` AST, translation, printer. |
| `src/target_js_core.ml` | JavaScript AST, translation, printer — with no knowledge of packaging. Reads `tmap` for one thing only: a JavaScript number cannot say whether Pyking called it an Int or a Float, so the type decides how a printed value is written. |
| `src/target_js_packaging.ml` | Wraps that output into the files each JS target delivers, and supplies the JavaScript side of the runtime interface. |
| `src/target_c.ml` | C AST, translation, printer, for both `c89` and `c23` — one backend with a `standard` parameter. Infers types, which C needs and Pyking does not have. |
| `src/target_java.ml` | Java AST, translation, printer, for `java8`, `java17` and `java21` — one backend with a `version` parameter, the same shape as `target_c.ml`. Infers types the same way; also checks that every function provably returns, since `javac` (unlike C) refuses one that doesn't. |
| `src/target_ocaml.ml` | OCaml AST, translation, printer. The one backend that infers nothing: it *runs* `typesystem.ml` and reads the types back out of `tmap`, so a program that does not check is refused with the checker's own message. Its subset is nearly all of what the checker accepts, less a short list of shapes OCaml cannot be given (target_ocaml.md, "What is not supported"). Emits no type annotations. |
| `src/interpreter.ml` | The interpreter: runtime values, environments, and a resumable small-step machine over the AST. Runs the fragment the checker accepts, and is the reference for what a program *means* at run time. |
| `src/repl.ml` | `pyk repl`: a session as a program written one statement at a time — checked as one program, run one statement at a time. |
| `src/builtin.ml` | The builtins: each one's name, arity, and whether it crosses the host/IO boundary. Backend-agnostic. |
| `src/pyk.ml` | The driver: argv, stage sequencing, error reporting, and the three commands (`pyk <file>`, `repl`, `compile`). |

## The builtins and the host boundary

`print`, `range`, `str`, `len`, `float` and `int` are in scope in every
program and are
bound by nothing. `src/builtin.ml` is the one table that says so: each
one's name, how many arguments it takes, whether calling it can be
observed outside the program, and what it does. See
[builtin.md](builtin.md).

A Pyking program on its own only computes. It cannot reach a console, a
file or a clock; everything observable crosses a boundary that table
writes down, as the `crosses_host` field of the one builtin that has it.
Drawing it explicitly is what keeps the language to one meaning while
*where the output goes* stays the host's decision rather than something
baked into the compiler.

Today exactly one builtin crosses it:

```
print(values...)   write one line; values formatted individually and
                   joined with single spaces
```

`print` produces no value -- it yields unit, `()` -- so it is a
statement, not something to bind or return, and a function whose tail is
a `print` returns unit (`void` in C and Java; Python's implicit `None`
and JavaScript's `undefined` already are it).

Its formatting rules are part of the contract, not of any backend: a
string is written bare, an integer in base 10, unit as `()` (never the
host's own name for "no value" -- not Python's `None`, not JavaScript's
`undefined`), and a boolean as `true` or
`false` — Pyking's own spelling (see PYKING.md), not Python's capitalised
`True`/`False`. JavaScript and Java already spell booleans that way
natively and need no conversion; C spells booleans neither way in either
standard, so it always builds a conditional expression (see
`docs/target_c.md`). Python's own `print` capitalises, so its backend
has the most work: for a `print` argument its own AST shape already
proves is (or isn't) a `Bool` -- a comparison, a boolean literal, plain
arithmetic, ... -- it needs no runtime check at all, just an inline
conditional or none; only a value it can't classify that way (a
variable, a function call) falls back to a small generated helper,
appearing only when actually needed (see "Booleans" in
`docs/target_python.md`). Every JS host in `target_js_packaging.ml`
still routes through one `pykFormat`, kept as a single indirection point
for any future value type that does need converting, even though today
it is just `String()`.

`target_js_core.ml` emits a `JsRuntimeCall` for each such operation and
never decides what it looks like. Packaging decides, and that is the only
real difference between the three JavaScript targets.

## Symbols and types

Two passes sit between the parser and the backends.

**`symbolize`** (in `src/analyses.ml`) gives every AST node a unique
integer `sym`, numbering post-order from 1 — so `0`, every node's
default, means "not symbolized yet". It runs for every mode, and it is
one case per constructor: a node added to `syntax.ml` needs a case here
or it keeps symbol `0`. Nothing consumes symbols yet; they exist so that a later stage
wanting to attach information to a node has a stable key that does not
depend on the node's identity or its position in the tree. `--symbols`
prints them, as an `@n` suffix, alongside the `pyking` target:

```
$ pyk compile -t pyking --symbols --stdout prog.pyk
x@1: Int = (12@2 + 20@3)@4  @5
```

A node that already has a symbol keeps it and fresh numbers continue
past the highest in the tree, which makes the pass safe to run twice
should a later pass ever synthesize nodes into an already-symbolized
tree: those get symbols without anything else being renumbered.

**`type_check`** (in `src/typesystem.ml`) is the type checker, run for
every mode and every target, after symbolizing and before anything else
reads the program. What it means for a *program* — the rules it applies, what it
refuses and why — is [PYKING.md](../PYKING.md)'s "Type checking"
section, since that is language, not compiler; what follows is how the
pass is built. Its signature is

```
type_check(stmts) -> tmap
```

— a whole program in, the types it worked out back. Inside, there is one
function per AST datatype it walks, each taking a node of exactly that
type and returning exactly one kind of answer, in the shape the module
writes out as OCaml-style signatures:

```
type_check    : [Stmt] -> TMap
check_stmts   : [Stmt] -> Env -> TMap -> Type? -> Store -> (Type, Store)
check_stmt    : Stmt -> Env -> TMap -> Type? -> Store -> (Type, Env, Store)
check_expr    : Expr -> Env -> TMap -> Store -> (Type, Store)
check_param   : Param -> TMap -> Store -> Type
same_type     : Type -> Type -> Bool
```

`Env` maps a name to what it means here and is used immutably — a
binding hands what follows it an extended *copy*, the same discipline
`analyses.ml` follows, and for the same reason: what a name means is
decided by where it is written. It maps a name straight to its type;
there is nothing else a name can mean here.

The `Type?` each statement function takes is the enclosing function's
return type, absent at the top level — that is what a `return` is
checked against, and why `return` outside a function is an error rather
than a special case somewhere else.

`Store` is threaded the same way `Env` is: an immutable value handed
along and rebuilt where it changes, holding everything the deferred
half of the checker (below) has worked out about a function that did
not write its type down. See [type_inference.md](type_inference.md).

`tmap` is the other half of the answer: a map from a node's *symbol* to
the type worked out for it, built up as the pass runs and handed back as
its result. It rides in the `store`, which is threaded and returned
everywhere already, so it needs no mutation of its own. The AST is not touched — nothing is
rebuilt and no node's `type` field is written — so what the source
*wrote* and what the checker *inferred* stay separable, and the driver
hands the finished `tmap` to `pprint_program` (below) to print the
latter. When checking
finishes, `tmap` holds an entry for each annotatable construct the
checker reached: `SFunctionDef`, `Param`, `SLet` and `SLetStmt`. A
`SFunctionDef`'s entry is its *function* type, not its return type — the
type of a thing is the type of the thing, and `-> T` in the syntax is
only part of it, which is why the printer takes `TFunction.result` for
that slot. Symbols exist for exactly this: `tmap` needs a key for a node that does
not depend on the node's identity, which is why symbolizing runs first —
and, since no node is synthesized into the tree, it does not have to run
again afterwards.

Types are the `T*` nodes from `syntax.ml` rather than a vocabulary of
their own, so a checked binding prints as `x: Int = 1` — syntax the
parser accepts, which is what keeps `-t pyking` output
re-parsable. They are synthesized by the checker and so carry no symbols
of their own: under `--symbols` an inferred type prints bare, since `@0`
means "not symbolized yet" and that is not what a type from `tmap` is.
That includes `TFunction`, written `(Int, Bool) -> Int`: `parse_type`
reads a parenthesized list followed by `->` as a parameter list and one
without as a tuple, which is the whole of the rule and is why a
parameter that is itself a pair is written `((Int, Bool)) -> Int`. So a
name bound to a function prints as `g: (Int) -> Int = f`, and that
re-parses like anything else.

Being writable, a function type can also reach a *backend* — as an
annotation, since annotations are erased and no backend reads one it
cannot represent (`annotated_type` in `target_c.ml` and
`target_java.ml` returns `None` for it, exactly as for a list or tuple
type, leaving inference to decide). What C and Java refuse is the
*value*: a call through a parameter is `call to unknown function`,
which is a limit on functions as values rather than on their types.

Most statements, and every whole program, have type unit, `()`. Two do
not, and that is what makes `if` checkable: an *expression statement*
has its expression's type, and a *block* has its last statement's — so a
branch ending in an expression yields that expression's value, and the
two branches of an `if` are required to agree. An `if` with no `else` is
checked against unit.

Types are compared with `same_type` rather than `=`: every `T*`
constructor carries `info` and `sym`, so structural equality would
compare those too and find `Int` written in one place different from
`Int` inferred in another.

The checker does the old name analysis's job as well as its own, which
is why there is no separate name pass any more: `Env` **is** the scope. A name
must be bound where it is used, a block's bindings do not escape it
(`check_stmts` hands its extended environment to nobody), a name is
visible only after its own binding, an inner binding shadows an outer
one, a `def`'s name is in scope in its own body, and the builtins —
`builtin.ml`'s table, read rather than re-listed — are in scope from
the start. A name that is not found raises `analyses.ml`'s own
`Analysis_error`, with its wording, so the driver prints the same `Name
error` whichever pass caught it.

`Env` maps a name to a `Type` and to nothing else, so being in the map
*is* being in scope and there is no second question to ask about a name
the checker found.

The builtins are in it like anything else, at a type of their own.
Each of them is bound to a `TBuiltin`, because
none of them fits a `TFunction` — `print` takes any number of arguments
of any type — and because they are not values: `builtin.ml`
calls them builtins rather than functions, and the C and Java backends already refuse
`print` as one. `check_builtin_call` gives each its own rule at the call
site, and using one anywhere else is an error. `range` is typed `[Int]`,
which is why `target_python.ml` materialises a range used as a value
while leaving a `for` header lazy.

Every `def` in a block is declared before any of that block is checked
(`declare_functions`), which is the whole of recursion, mutual recursion
and forward references: a body is checked in an environment that already
holds its own name, its siblings', and every function of every enclosing
block. It is not recursive — a `def` in a branch belongs to that
branch's block — and it declares *only* functions, since an `=` binding's
type is whatever its right-hand side works out to, while a `def`'s is
written on the `def`. `analyses.ml` does the same thing with names, and
each backend does it with its own naming (see below), so all three agree
about what is in scope where.

The one rule left behind is the mutable one: a `var` may not be
shadowed. This checker refuses `var` outright, so there is nothing here
for that rule to protect, and it stays in `analyses.ml` until there is.
That is the last thing standing between the two passes — when the
checker covers the constructs the analysis walks, the analysis can go.

Both halves of it are pinned down by tests, distinguished by filename:
`tests/typecheck_*.pyk` must check, and its `.ast.out` is the printed
AST — while its `.out`, like every other program's, is what it prints
when it runs, on each backend it lists. `tests/fail_typecheck_*.pyk`
must not check, and its `.ast.out` is the error message; there is
nothing to run.

It currently covers immutable bindings, expression statements, `if`
statements (in both the ordinary and the value form), and fully
annotated function definitions, over `Int`, `String` and `Bool`: `+`,
`-` and `*` on `Int`, `++` on `String`, `<`/`<=`/`>`/`>=` on `Int`
giving `Bool`, `==` on two values of one type giving `Bool`, calls of a
function-typed name, calls of the four builtins, unary minus, list
literals, list comprehensions and `match` with the full pattern
grammar. An annotation may
also name **type variables** (`(a) -> a`), quantified at its outermost
level and written out with `all` where a nested quantifier is meant;
see PYKING.md, "Type variables".

A binding takes its right-hand side's type, and an annotation it wrote
is checked against that rather than replaced by it — `f: (Int, String)
-> Int = foo` is an error when `foo` is `(Int, Int) -> Int`, reported
against the annotation, since the value is a perfectly good value of its
own type.

A `def` that annotated *every* parameter and its return type is checked
where it is written, and then two rules apply: every `return` must give the declared type,
and the body must *produce* it, either by returning on every path or by
ending in a value of that type. Those are the two halves of PYKING.md's
"Tail position", and one check covers both, because every statement is
asked the same question — *what value do you supply?* — and `return e`
answers "e's", exactly as the tail-position table says of it. So a
branch that returns and a branch that ends in an expression are
comparable without either being a special case, and no separate
"does every path return?" pass is needed the way `target_java.ml` still
needs one for `javac`.

Recursion needs nothing beyond the declaration pass: the function's own
type is in scope while its body is checked, so a recursive call is
checked against it argument by argument, like a call to anything else.
Nothing is assumed — the declared type is what the body is checked
*against*, and a body that does not honour it is refused.

A `def` that did **not** write its type down is not checked where it is
written at all. It is put aside with `TUnknown` where its type should be
and worked out the first time something *calls* it — but not *from* that
call. Its parameters go in as **metavariables**, types nothing has
decided, and the body's own demands solve them: the same `check_stmt`
and `check_expr` in the same order, with `unify` answering wherever a
type is demanded. What the body left unsolved is generalised, and what
comes out is the **principal type** — so `map` written with no
annotations is `((a) -> b, [a]) -> [b]` whatever called it first, and
serves every later call.

That is Hindley-Milner, reached without a constraint solver:
unification is first-order, eager and local to the place a type is
demanded, so every error stays a statement about one place, in the words
the checker already uses. Recursion needs no special case — while a body
is checked its own name means a plain type, and functions that name each
other are worked out as one group. The signature is checked against the
body a second time with the variables rigid before it is adopted.

That is a mechanism with several decisions inside it, and it has a page
of its own: [type_inference.md](type_inference.md).

Anything else is refused with `Construct is not supported` against its
own source position — a deliberate floor, since a checker that quietly
accepted what it had not reasoned about would be worse than one that
says where it stops:

```
$ pyk compile prog.pyk
'prog.pyk' 1:4-1:16 Type error: `+` cannot be applied to Int and String;
  it accepts Int + Int
```

## The interpreter

`src/interpreter.ml` runs a program instead of translating it, and it is
where the language's *runtime* semantics are defined. Where a compiled
target disagrees with it, the target is wrong. `pyk <file>` and `pyk
repl` are its two front ends; `src/repl.ml` adds a prompt and nothing else to
the semantics.

It runs the fragment the type checker accepts, and the gate is the
checker itself: `src/pyk.ml` runs `typesystem.type_check` before handing
a program here, so there is no second list of supported constructs to
keep in step — the same arrangement `target_ocaml.ml` uses, and for the
same reason.

**It is a machine, not a walker.** Execution is `step(State) -> State`,
driven from a flat loop:

```
State = (control, env, kont, stack, runtime, loops)

control   CEval(expr) | CStmt(stmt) | CApply(value) | CDone(v) | CFailed(e)
kont      a linked chain of continuations: KSeq, KBind, KBinaryLeft,
          KBinaryRight, KCallee, KArgument, KElement, KBranch, KChoose,
          KDiscard, KStartLoop, KSequence, KTest, KIterate, KReturnTo
stack     Pyking's own call stack: Frame(name, info, kont, env, parent,
          depth, loops)
loops     the `loop`s in progress, which is to `break` what `stack` is to
          `return`: Loop(node, accumulator, env, kont, parent)
runtime   what a run never changes: the host, the call-free table, max_depth
```

A recursive `eval` would be shorter and a dead end. A debugger, a
step-through in the playground and a DAP adapter all need execution that
can be paused, inspected and resumed, and a recursive walker can only be
paused by blocking a host thread — so the pending work is data
(`kont`), a paused `State` is an ordinary value, and `run(state,
steps=n)` stops after *n* steps and hands it back. Three properties
follow:

- **Depth costs heap, not host stack**, so an interpreted recursion goes
  deeper than the compiled targets manage — and an explicit `max_depth`
  (10 000) turns a runaway one into a Pyking error with a stack trace
  rather than an out-of-memory kill.
- **A block does not grow the continuation chain**: sequencing is an
  *index* into a statement list, so re-entering a block replaces its
  continuation instead of stacking another.
- **An error is a machine state** (`CFailed`), never a host exception
  thrown through `step`, so nothing unwinds and a debugger could stop at
  the error with the frames intact.

**Environments are Pyking's own.** An `Env` is a persistent chain of
frames: a block runs in a chain of its own, `=` makes a new frame (a
rebinding shadows, it never updates), and a `def` captures the chain it
was created in. Everything `target_python.ml` needs machinery for —
renaming a shadowed binding, a per-turn factory so a closure keeps its
own turn's values — is simply what this representation does. The one
mutation is Pyking's `def` rule: `declare` puts a write-once cell per
`def` in the block's frame, and `define` fills it when the definition is
reached, which is how a function name can be visible throughout its block
while its body still captures what was bound where it is written.

**An `Int` holds at least 32 bits, and overflow is undefined** — so
nothing here narrows a result, and this reference is free to disagree
with a target past that range. What each host does, and why none is
forced to agree, is in
[targets.md](targets.md#integers-hold-32-bits-and-overflow-is-undefined).

`src/interpreter.ml`'s own docstring and [source.md](source.md) carry the
detail; `design/plan-eval-lsp.md` is where the debugger, DAP and LSP
built on top of it are planned.

## Targets

Selected with `pyk compile --target <name>`, or `-t <name>`; `python` is
the default.
Each family is documented in full in [targets.md](targets.md) and the
pages it links to; what follows is the shape of the mechanism.

| target | files written | `print` goes to |
|---|---|---|
| `python14` | `foo.py` | Python's own `print` |
| `node24` | `foo.js`, `pyk-runtime.js`, `package.json` | `console.log` — `node foo.js` |
| `web24` | those, plus `foo.html` | `console.log` — the browser's console, over HTTP |
| `iweb24` | `foo.html`, `pyking.js`, the `.pyk` sources | `console.log`, from the interpreter |
| `c89` | `foo.c` | `printf`, from a C89-conforming file |
| `c99` | `foo.c` | `printf`, from a C99 file |
| `c23` | `foo.c` | `printf`, from a C23 file |
| `java8` | `Foo.java` | `System.out.println`, `javac --release 8` |
| `java17` | `Foo.java` | `System.out.println`, `javac --release 17` |
| `java21` | `Foo.java` | `System.out.println`, `javac --release 21` |
| `ocaml5.5` | `foo.ml` | `print_endline`, `ocamlopt` |

`iweb24` is the odd one: it compiles nothing. The page ships the
program's Pyking source and the compiler built to JavaScript, and
interprets it — so it covers everything the checker accepts rather than
one backend's subset. See [target_js.md](target_js.md), "The interpreted
target".

`node24` and `web24` emit the *same* JavaScript: ES modules printing
with `console.log`, one `.js` per Pyking module. `web24` adds an HTML
file that loads the program, and nothing else.

### Naming the output

With no `--output`, the compiler names the file itself: the source file's
own name, the target's extension, in the directory the command was run
from. `pyk compile -t node tests/hello.pyk` writes `./hello.js`, and
`-t python` would have written `./hello.py`.

The Java targets are the one exception: Java requires the file holding a
`public` class to share that class's name exactly, so the source's own
spelling would not do. `pyk compile -t java tests/foo_bar.pyk` writes
`./FooBar.java`, holding `public final class FooBar` — see "Naming the
class" in [target_java.md](target_java.md#naming-the-class) for the exact
rule and what an explicit `--output` does instead.

`--output` overrides that, and the JavaScript targets write more than
the file it names: `pyk compile -t web -o out/prog.html` writes

```
out/prog.html       the page that loads the program
out/prog.js         the program
out/helper.js       one file per module it imports
out/pyk-runtime.js  `print`, and the value formatting every module shares
```

`node` writes one more, `package.json` (`{ "type": "module" }`), which
is what lets the others be plain `.js` there: node decides a file's
module system from its extension first and the nearest manifest second,
so without one it reads `.js` as CommonJS and the `import` lines fail.
`.mjs` would sidestep that, at the cost of an extension most projects
never write.

`web` writes no manifest, because a browser never reads one and a
manifest governs every `.js` beneath it — writing one into a directory
that was not asked to have it would change how node reads whatever else
is there.

An existing `package.json` is never overwritten: if it already declares
`"type": "module"` the compiler says nothing, and otherwise it warns and
leaves the file alone — it belongs to whatever project the output landed
in, and clobbering it would break more than this build.

`--stdout` prints the primary artifact only — the program's own module,
since the files beside it exist only as files.

A `web24` or `iweb24` page has to be **served**: a browser refuses a
module fetched over `file://`, and both load one. `--run` starts
`python3 -m http.server` in the output directory for that reason.

## Command line

```
pyk [options] <filename>          run it with the interpreter
pyk repl                          start the REPL
pyk compile [options] <filename>  compile it (alias: pyk c)
```

`pyk` at the repository root is the compiled driver itself: `make`
builds `src/pyk.exe` with dune and copies it there, so it is a build
artifact rather than a checked-in script (see [build.md](build.md)). Run
it with no arguments for the full option and target list, which the
driver builds from `targets`/`extensions` so it cannot drift from what
the backends actually support.

Two of the three commands *run* a program, and both run it the same way:

- **`pyk <file>`** runs the AST with `src/interpreter.ml`. Pyking's own
  semantics: 32-bit integers, and Pyking runtime errors with spans and a
  stack trace.
- **`pyk repl`** is the same interpreter with a prompt in front of it.

The third way to run one is `pyk compile --run`, which builds what was
compiled and runs it with that target's own commands — generated Python
under the host's `python3`, generated C under `cc` and then the binary,
and so on. That is how a *backend's* semantics are observed rather than
the interpreter's, and where the two disagree the backend is the bug.
The commands are `src/execution.ml`'s, and each is printed before it
runs.

The flags are shared by every command rather than being per-command, so
`--tokens` and `--symbols` mean the same thing wherever they are
written. `--target`/`-t`, `--output`/`-o`, `--stdout` and `--run` only
affect `pyk compile`, which with none of them writes a file the compiler
names (see "Naming the output" above).

`--no-typechecking` is the one flag only a single target accepts. It stops
the front end after `symbolize` — no checker, and so no mutability
analysis and no tail-call pass, neither of which runs without what the
checker works out — and is accepted only by `compile -t pyking`, since
every other target and the interpreter read the types. It also stops
*before* the module system: the file named is the only one read, and
nothing it imports is opened. What that prints is the program as
written, with the source's own annotations -- the parser's output with
nothing inferred on top of it, which is what makes the flag worth having
when the question is what the front end built rather than what the
checker made of it.

A file that fails to lex, parse, find or agree with a module it imports,
resolve its names, or type-check, that
uses a construct the chosen target does not support, or that fails while
being interpreted, reports

```
'file' row:col-row:col Lexing error: ...
'file' row:col-row:col Parsing error: ...
'file' row:col-row:col Module error: ...
'file' row:col-row:col Name error: ...
'file' row:col-row:col Type error: ...
'file' row:col-row:col Runtime error: ...
'file' row:col-row:col Unsupported by target 'node24': ...
```

to stderr and produces no output. The first six all come from one
function — `format_error` in `src/pyk.ml` — because every error type in
the front end carries an `Info` and differs only in its label; `pyk repl`
is handed that same function, so a mistake made at the prompt is
reported in exactly the words a file would get. A runtime error is
followed by the calls that were in progress under it, innermost first,
truncated after ten.

Every message the driver prints is reflowed to 70 columns first (`wrap`
in `src/pyk.ml`), with continuation lines indented two spaces, so a long
one stays readable in a narrow terminal instead of wrapping raggedly at
whatever width it happens to find.

## What each target supports

The Python backend compiles the whole language; the JavaScript, C, Java
and OCaml backends implement a subset, and refuse anything outside it at
compile time with a source position rather than emitting code that will
not build. The per-target detail — what is supported, how each
construct is compiled, and where the output is not optimal — lives in its
own page:

- **[targets.md](targets.md)** — every target at a glance, the shared
  subset as a table, and the differences that survive it — including
  what an `Int` is on each of them.
- **[modules.md](modules.md)** — the module system: the graph, the
  order, what each module exports, and what each target does with it.
- **[source.md](source.md)** — every module in `src/`, its data
  structures and its main functions.
- **[optimization.md](optimization.md)** — the tail-call pass every
  target benefits from, and why it is one AST rewrite rather than nine
  backend features.
- **[target_python.md](target_python.md)** — `python`.
- **[target_js.md](target_js.md)** — `node24`, `web24` and `iweb24`.
- **[target_c.md](target_c.md)** — `c89`, `c23`.
- **[target_ocaml.md](target_ocaml.md)** — `ocaml5.5`. Nearly the whole
  subset that type-checks, compiled with no annotations.
- **[target_java.md](target_java.md)** — `java8`, `java17`, `java21`.

Two differences are worth knowing before reading further, and neither is
a case of one Pyking program *meaning* two things:

- **Integer overflow is the host's.** An `Int` holds at least the signed
  32-bit range and past it the result is undefined (PYKING.md, "Integer
  and string literals"), so each host answers with whatever its own
  arithmetic gives — a JavaScript number is a double, and the
  interpreter under js_of_ocaml is 32 bits where the native one is 63.
  [targets.md](targets.md) has the table.
- **The Java targets refuse a function whose control can fall off the
  end** without returning, since `javac` — unlike Python, and unlike C
  — treats that as a compile error rather than implicitly returning
  `None`.

Division is not one of them. `/` is integer division truncating toward
zero, and every target implements it: the host's own `/` in C, Java and
OCaml, `//` with Python's floor corrected, and `Math.trunc` around the
quotient in JavaScript, whose `/` is float division. No target refuses
it, and all of them answer `-3` for `-7 / 2`.

The `ocaml5.5` target is the odd one out in a more interesting way: its
subset starts from the type checker's, run for real, rather than from a
list this backend maintains. A program it accepts is one
`typesystem.ml` accepted, which also means the subset grows when the
checker does, without the backend being touched — unless the new
construct is one of the few OCaml has no way to be given, which
[target_ocaml.md](target_ocaml.md) lists.

The interpreter (`pyk <file>`) shares that arrangement: it runs the checker
and then the program, so its coverage grows with the checker's too. It is
not in the target pages because it emits nothing to document — what it
supports is [typesystem.ml](../src/typesystem.ml)'s fragment, and what it
*means* is the language itself, which is the point of having it: it is
the reference the compiled targets are measured against rather than
another translation to check.

## Tests

`tests/test_cases.toml` lists every program and the targets it is
expected to work on:

```toml
[[cases]]
file = "while_simple.pyk"
targets = ["python14", "node24", "web24", "iweb24"]
```

A program that imports lists the modules it imports as well, in
dependency order — which the compiler writes beside the program's own
output, and which the C, Java and OCaml runners have to name in that
order to build the program at all:

```toml
[[cases]]
file = "module_chain.pyk"
modules = ["module_chain_mod1.pyk", "module_chain_mod2.pyk"]
targets = ["python", "node24", "interpret"]
```

A module listed there is not a case of its own — it is not a program,
and it is compiled and run only as part of the one that imports it — but
it is still accounted for, so the "not listed in the manifest" warning
stays honest.

`make test` runs `tests/test_all.py`, which sequences the four suites and
prints a combined summary at the end. The first of them,
`tests/test_script.py`, walks that manifest,
compiles and runs each program on each of its targets, and compares the
output against the sibling `.out` file — the same `.out` file serving
every target listed for a program, which is the property being tested.
It warns about any `.pyk` missing from the manifest, and finishes with a
per-target summary.

Nothing a run produces leaves the temporary directory it was given —
every backend is invoked with `--output` pointing into it, `javac`
writes its classes there with `-d`, `ocamlopt` builds there with `-I`,
and the two targets that compile nothing write nothing at all — so the
pairs are independent and `make test` runs them in a thread pool
(`--jobs`, defaulting to one per usable CPU; `make stest` is `--jobs
1`). Threads rather than processes because every runner spends its time
waiting on a subprocess. Results are buffered and reported in the order
the manifest lists them, so what the suite prints does not depend on how
the work was scheduled and a parallel transcript diffs cleanly against a
serial one.

Two of the names in a `targets` list compile nothing. `typecheck` checks
a program and compares the printed AST against its `.ast.out`;
`interpret` runs it with `src/interpreter.ml` and compares its stdout
against the same `.out` as every compiling target. That last comparison
is the whole reason the interpreter is cheap to trust: it is a second
definition of the language's semantics, and holding it to the files the
twelve targets are held to is worth more than any amount of care in
review.

Each target is executed the way a user would run it: `python3` on the
generated `.py`, `node` on the generated `.js`, `cc -std=… -pedantic` and
then the binary for `c89`/`c99`/`c23`, `javac --release <8|17|21>` and
then `java` for `java8`/`java17`/`java21`, `ocamlopt -w +a` and then
the binary for `ocaml5.5`. `web24` runs the module its page loads, under
node — the page is a loader and the program prints to the console, so
what runs is the same program either way — and `iweb24` runs its page's
own three lines of glue with node's filesystem in place of `fetch`,
which exercises the interpreter, the shipped sources and the external
modules. The JavaScript runners pass `--no-experimental-detect-module`, so node
does not guess whether a `.js` file is an ES module: what is tested is
what the compiler declares, a `package.json` or a `.mjs` name, rather
than what a recent node infers and an older one does not.
`-pedantic` matters for the C targets: the point of having a
`c89` target is that its output really is C89, and a compiler that
merely tolerated the difference would hide it. `-w +a` matters for the
same kind of reason: that target's promise is *clean* OCaml, so a
warning about generated code is a failing test rather than a note. The C
compiler comes from `$CC`, defaulting to `cc`; the Java tools come from
`$JAVAC`/`$JAVA`, defaulting to `javac`/`java`; the OCaml compiler comes
from `$OCAMLOPT`, defaulting to `ocamlopt`.

### Testing the HTML target

There is no browser in this repository's toolchain, so the harness
extracts the page's embedded module and runs it under node with a small
`document` stub whose `textContent` accumulates whatever the program
prints:

```js
globalThis.document = {
  getElementById: () => ({
    get textContent() { return __pykCaptured; },
    set textContent(value) { __pykCaptured = value; },
  }),
};
```

That executes the real generated program and the real `print` path — the
code that writes into the page — and compares what would have appeared
there against the same `.out` as every other target. What it does *not*
prove is that a browser parses the page or that the layout works; only a
real browser can show that. The alternatives, if that ever matters
enough: a headless browser driven by Playwright or `puppeteer`, which is
truest to reality but adds a large external dependency to an otherwise
stdlib-only repository, or `jsdom`, which is lighter but still an npm
dependency and still not a browser. The stub was chosen because the
generated page's only contact with the outside world is the element it
prints into, so stubbing that one thing covers everything the compiler is
responsible for.

### One suite, and what used to be two

There was a second suite once. The compiler was Python, `ocaml-src/`
held the front end translated into OCaml beside it, and `make
test-ocaml` pretty-printed every program in `tests/` with both and
diffed the two — standard output, standard error and the exit status, so
a program the parser *refuses* was compared too. That is what kept the
translation honest while it was a translation.

It is gone because the translation finished: `src/` **is** the OCaml
one, there is no second front end to disagree with, and `make test`
holds the only implementation to the same `.out` files it always did.
