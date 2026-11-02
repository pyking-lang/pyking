# Pyking in Lean: a semantics, and proofs about it

A plan for proving things about Pyking, and later about its compiler,
in the Lean 4 proof assistant. Written before any code (1 November
2026). The decisions below were settled in an interview with the
designer. Where something is proposed rather than settled, it is
marked **Open** and listed at the end.

## Contents

1. [The idea, and what changed in it](#1-the-idea-and-what-changed-in-it)
2. [Decisions](#2-decisions)
3. [Core Pyking](#3-core-pyking)
4. [Semantics](#4-semantics)
5. [Type soundness](#5-type-soundness)
6. [Is the Lean semantics Pyking's? The comparison suite](#6-is-the-lean-semantics-pykings-the-comparison-suite)
7. [Ints and Floats](#7-ints-and-floats)
8. [The Lean project](#8-the-lean-project)
9. [Layers after the first: mutation and the passes](#9-layers-after-the-first-mutation-and-the-passes)
10. [After bootstrapping: `pyk -t lean`](#10-after-bootstrapping-pyk--t-lean)
11. [Why not Lean's extensible syntax](#11-why-not-leans-extensible-syntax)
12. [What it touches](#12-what-it-touches)
13. [Order of work](#13-order-of-work)
14. [Open questions](#14-open-questions)

## 1. The idea, and what changed in it

**The original idea.**
1. Bootstrap Pyking, so the compiler is written in Pyking rather than
   OCaml (design/plan-bootstrap.md).
2. Use Lean's extensible syntax so that Pyking source *is* a Lean
   program.
3. Prove properties of the compiler's semantics in Lean.

**What this plan does instead.** It keeps the goal and changes the
route, in two ways.

- **Proofs start now, not after bootstrapping.** Pyking's core language
  is written in Lean *as data*: a datatype of programs, typing rules,
  and an evaluation semantics. The first theorem is type soundness.
  None of this waits for the compiler to be written in Pyking, and all
  of it is what the later proofs about the compiler are stated against.
- **Pyking code reaches Lean through a backend, not through syntax
  macros.** Once the compiler is written in Pyking, `pyk -t lean`
  prints it as Lean definitions. The reasons are in section 11.

**What a proof can and cannot say.** A proof is about the Lean model.
It says something about Pyking only as far as the model is Pyking.
That gap is closed in two ways: by running the model on the whole
`tests/` directory against `pyk` (section 6), and later by proving the
Lean backend correct against the model (section 10).

**The five targets stay outside the proofs.** Python, JavaScript, Java,
OCaml and C have no complete formal semantics in Lean. The proofs cover
Pyking itself and the passes from source down to the core. The
backends keep being checked by tests, as today. CompCert draws the same
line: its proof ends at assembly and trusts the assembler.

## 2. Decisions

| # | Question | Decision |
|---|----------|----------|
| D1 | What the first proofs are about | **Type soundness** of core Pyking: a well-typed program never gets stuck. |
| D2 | How much of Pyking the core covers first | **The pure core.** `var`, `:=` and arrays come later as a second layer with a store (section 9). |
| D3 | Which typed language soundness is about | **An explicitly typed core.** Every binder carries its type, and every overloaded call names its member, as `tmap` and `qmap` already settle. Inference, overloading and implicits are proved separately, later. |
| D4 | How to know the model is Pyking's | **Run it on `tests/`.** The Lean semantics is executable, `pyk` exports the core form, and a new suite compares the Lean evaluator with `pyk`'s interpreter on every program. |
| D5 | Int overflow and out-of-range shifts | **An undefined outcome**, as PYKING.md says, with nothing promised past the signed 32-bit range. |
| D6 | Where the Lean project lives | **`lean/` in this repository**: a Lake project with a pinned toolchain and no Mathlib at first. It is built by `make lean`, and skipped when Lean is not installed. |
| D7 | How Pyking code gets into Lean after bootstrapping | **A backend, `pyk -t lean`**, not Lean syntax extensions. |
| D8 | Termination in the backend's output | **Fuel first, measures later.** Recursion and loops get a fuel argument. Later, a Pyking annotation lets the backend emit a real termination measure. |
| D9 | Float | **Opaque operations.** Floats run as Lean's IEEE `Float` but are abstract in proofs. |

## 3. Core Pyking

**Where it comes from.** The core is the program as the pipeline
leaves it after `elaborate.ml` and before `release.ml` and
`opt_tailcall.ml` (docs/architecture.md). By then:
- defaults, named arguments, tuple `:=` and compound assignment are
  desugared (`desugar_args.ml`);
- every name is resolved, and each node has a symbol (`symbolize`);
- overloads and implicits are gone: a qualified name is a plain one,
  and an implicit parameter is an ordinary argument (`elaborate.ml`);
- `tmap` gives every node its type.

So the core needs no overloading, no implicits and no named arguments.
It does keep what a Pyking program is made of: statements, blocks
with values, `return`, and loops that carry a value.

**Types:**
- `Int`, `Float`, `Bool`, `Char`, `String` and unit.
- Tuples, lists, functions, and datatypes with parameters.
- Type variables. A polymorphic definition is generalized at its
  `def` (Hindley–Milner), and each use records its instantiation, read
  from `tmap`.

**Expressions and statements:**
- Literals, variables, constructors, tuples, lists, and list
  comprehensions (or their desugared form; see Open O3).
- Calls, lambdas and `let`.
- Primitive operators.
- `if`, and `match` with every pattern kind: literals, names, `_`,
  tuples, lists with `..rest`, `++` prefixes, constructors, `|`, `as`
  and guards.
- Blocks: a statement sequence whose value is its last statement.
- `def` groups, which may be mutually recursive.
- `return`.
- `for`, `while` and `loop`, with `break` and `continue` carrying a
  value.

**Builtins.** Builtins such as `print`, `len`, `str` and `int` are
primitives with fixed types. `print` appends to an output trace, which
is part of a program's outcome.

**Modules.** A program and the modules it imports are flattened into
one core program, after `prune.ml`, so the core has no imports.
External modules (`io`, `fs`, `sys`, `time`, `tinyweb`, ...) are left
out at first. A program using one is excluded from the comparison
suite, as C excludes programs today, with the reason written in the
manifest.

**Left out of the first layer:** `use mutation` (`var`, `:=`, arrays)
and external modules.

## 4. Semantics

**A small-step machine, shaped like the interpreter.** `pyk`'s own
interpreter (`src/interpreter.ml`) is already a CPS small-step machine.
The Lean semantics follows the same shape: a state is an expression or
a value, together with an environment and a stack of continuation
frames. `return`, `break` and `continue` unwind the stack to the
frame of their function or loop.

```lean
inductive Outcome where
  | done      (v : Value) (out : List String)
  | trap      (where_ : Span) (out : List String) -- bad index, failed int("x"), ...
  | undefined (where_ : Span) (out : List String) -- Int past 32 bits (section 7)

inductive Step : State → State → Prop
-- one rule per continuation frame, as in interpreter.ml
```

**Two forms, proved to agree.**
- `Step`, the relation above, is what the proofs use.
- `step : State → Option State` is a function that computes one step.
  `run (fuel : Nat)` iterates it, and is what the comparison suite
  executes.
- A theorem states that `step s = some s'` exactly when `Step s s'`.
  The suite then tests the same semantics the proofs are about.

**A program that runs forever** has no outcome. In the machine it is
an infinite sequence of steps, and in `run` it is one that runs out of
fuel. The suite gives each program a fuel bound far above what any
test needs, and reports running out as a failure of its own.

## 5. Type soundness

**The theorem.** A program the core typing rules accept does one of
four things:
- finishes with a value of its type;
- traps at a defined point (an index out of range, a failed `int(s)`,
  a negative array size later);
- reaches an undefined outcome (section 7);
- runs forever.

It never gets stuck. Stated the usual way:
- **progress:** a well-typed state is final or can take a step;
- **preservation:** a step keeps it well typed.

```lean
theorem progress   : WellTyped s → Final s ∨ ∃ s', Step s s'
theorem preservation : WellTyped s → Step s s' → WellTyped s'
```

**What it covers, beyond the textbook.**
- `match` with Pyking's patterns. A `match` that runs out of cases
  would be stuck. The exhaustiveness pass (`exhaustive.ml`) promises
  that this never happens. That promise is taken as a premise in the
  first layer, and proved later in section 9.
- **The `if` rule from 1 November 2026.** The branches of an `if` whose
  value is unused need not agree on a type. The typing rule types such
  an `if` as unit, and the proof shows that the value it throws away is
  never read.
- `break` and `continue` with values, and `return`. Their frames carry
  the type the loop or the function expects.
- Polymorphic definitions and their instantiations.

**What it does not cover yet.** It does not prove that the OCaml
checker accepts only programs the core rules accept. Until that is
proved, the suite checks it on every test: the Lean side re-checks the
exported, explicitly typed core and must accept every program `pyk`
accepts (section 6).

## 6. Is the Lean semantics Pyking's? The comparison suite

**Exporting the core.** A new `pyk` option prints a checked program's
explicitly typed core as JSON: `pyk --core-json prog.pyk`. The JSON
holds the flattened program, every binder's type, and each polymorphic
use's instantiation. Lean reads it with its own `Lean.Json`. The
format is documented in `docs/core_json.md`, as `--to-json` is for
notebooks.

**A Lean executable, `pyk-lean`,** built by Lake. It:
1. reads the JSON;
2. re-checks the program against the core typing rules;
3. runs it with `run`;
4. prints the output trace, and exits as `pyk` does (status 1 on a
   trap).

**The suite, `tests/test_lean.py`.** It works like the other target
suites:
- It runs every program in `tests/test_cases.toml` through `pyk` and
  through `pyk-lean`, and compares standard output and exit status.
- A `fail_typecheck_*` case must be refused by `pyk`. The Lean
  re-check is not asked about it, since `pyk` exports only programs it
  accepts.
- A program the first layer does not cover (mutation, arrays, external
  modules) is excluded with a reason, as C's exclusions are today:
  "mutation is not in the Lean core yet".
- An undefined outcome on a test is a failure. No test may rely on
  overflow.
- It is skipped, as the C targets are without bdwgc, when `lake` is not
  installed. `tests/test_all.py` runs it with the rest.

**What the suite proves and what it does not.** It does not prove the
model faithful. It catches every difference the tests reach, and it
keeps catching them as the language changes. A new feature is not done
until the Lean core either covers it or excludes it with a reason,
which is the CLAUDE.md rule applied to one more part of the system.

## 7. Ints and Floats

**Int.**
- The model's Int is Lean's unbounded `Int`.
- Every arithmetic step checks its result against the signed 32-bit
  range. A result outside it steps to the undefined outcome, at that
  operator's span.
- The same applies to `^` with large results, and to `<<` and `>>` by
  a negative count or by 32 or more.
- Division and remainder follow PYKING.md: the rounding direction, and
  a trap on zero.

This promises exactly what PYKING.md promises. A theorem about a
program may assume it stays in range. It then holds on every target,
whatever each host does past that range.

**Float.**
- Float is an abstract type in the proofs: its operations are opaque
  constants with the right types.
- When the model runs, they are Lean's `Float`, which is IEEE binary64.
- Printing a Float follows Pyking's rules: shortest round trip, `inf`,
  `nan`, `-0.0`. The model calls a printing function that the suite
  tests against `pyk`.

Type soundness needs nothing more. Proofs about particular Float
results are out of scope until there is a bit-exact IEEE model in Lean
(Coq has Flocq; Lean has no equivalent yet).

## 8. The Lean project

```
lean/
  lean-toolchain        -- pinned Lean 4 version
  lakefile.lean         -- library Pyking, executable pyk-lean; Batteries only
  Pyking/Core/Syntax.lean      -- types, patterns, expressions, statements
  Pyking/Core/Typing.lean      -- the typing rules
  Pyking/Core/Semantics.lean   -- Step, Outcome, frames
  Pyking/Core/Eval.lean        -- step, run, and step ↔ Step
  Pyking/Core/Int32.lean       -- range checks, division, shifts
  Pyking/Core/Soundness.lean   -- progress, preservation
  Pyking/Core/Json.lean        -- reading --core-json
  Main.lean                    -- pyk-lean
```

- **No Mathlib at first.** Lean core and Batteries keep a clean build
  in minutes rather than hours. If a later proof needs Mathlib, adding
  it is one line in `lakefile.lean`.
- **`make lean`** runs `lake build`, which checks every proof and
  builds `pyk-lean`. `make test` includes the comparison suite when
  Lean is installed.
- **No `sorry` in a finished proof.** The build fails on one, since
  `lake build` is run with warnings as errors. An unproved lemma being
  worked on lives on a branch, not on `main`.
- **Installing Lean:** `elan`, Lean's version manager, reads
  `lean-toolchain`. Docker and Nix get it as an optional extra, and
  the Homebrew cask does not need it.

## 9. Layers after the first: mutation and the passes

Each layer is a separate step, with its own extension of the
comparison suite.

1. **Mutation.** `var`, `:=` and arrays get a store: a finite map from
   locations to values.
   - An array is a location, so two holders of one array see each
     other's writes, as FCR-B1 in mutation5.md decides.
   - `same(a, b)` compares locations.
   - Soundness extends with a store typing.
   - The first layer's proofs do not change, since a pure program
     never touches the store.
2. **Exhaustiveness.** Prove that a `match` the pass accepts always
   has a case for its value. This turns section 5's premise into a
   theorem. The algorithm is Maranget's, which is small enough to port
   and verify.
3. **Desugaring keeps meaning.** Extend the core with the sugar that
   `desugar_args.ml` removes: compound assignment, tuple `:=`, named
   arguments, defaults, `let` and structs. Then prove each rewrite
   keeps the outcome. These are short proofs, once the semantics
   exists.
4. **Tail calls.** Prove that `opt_tailcall.ml`'s rewrite of
   self- and mutually tail-calling groups into one `loop` keeps the
   outcome.
5. **Inference.** Prove that what Pyking's inference, overload
   resolution and implicits accept elaborates to a well-typed core
   program. This is the largest of the five. The re-check in section 6
   covers it in practice until then.

Until the compiler is written in Pyking, these proofs are about Lean
copies of each pass, checked against the OCaml passes by the suite.
After bootstrapping, the copies are replaced by the compiler's own
code, through `pyk -t lean`.

## 10. After bootstrapping: `pyk -t lean`

**A sixth backend.** It prints a checked Pyking program as Lean 4
definitions: datatypes as `inductive`, functions as `def`, and `match`
as `match`. It is close to the OCaml backend, which already maps
Pyking's datatypes and patterns onto a language with the same ones.

**What it gives.**
- The compiler, written in Pyking, becomes Lean functions.
- Theorems about those functions are theorems about the compiler: for
  example, that `desugar` keeps the meaning of every program.
- The model in sections 3–5 is what "meaning" refers to.

**Termination (D8).**
- **Fuel first.** Every recursive function and every loop gets an
  extra argument `fuel : Nat` and returns `Except OutOfFuel α`. Lean
  then accepts every definition as total, and every definition can be
  reasoned about. A theorem is stated for enough fuel.
- **Measures later.** A Pyking annotation on a function names what
  decreases on each call; its spelling is Open O5. Where one is given,
  the backend emits Lean's `termination_by` instead of fuel, and the
  definition reads as the programmer wrote it.

`partial def` is not used: Lean keeps a partial function opaque, so
nothing could be proved about it.

**Mutation in the backend's output.** A function using `use mutation`
is printed in Lean's `StateM` over the store from section 9.
`do`-notation with `let mut` covers the `var`s that never escape a
function. The compiler is expected to use mutation sparingly
(design/plan-bootstrap.md, item 16), so most of it stays pure.

**What is trusted, and how that shrinks.** At first the backend itself
is trusted: a proof about its output is a proof about the compiler
only if the backend prints the right Lean. Two ways to stop trusting
it:
- Prove the backend correct once against the core semantics: the
  printed Lean computes what the core program computes.
- Or have it emit a proof with each definition, as CakeML's
  proof-producing translator does.

The choice is Open O6.

## 11. Why not Lean's extensible syntax

Lean 4 lets a library declare new syntax and give it a meaning
(`declare_syntax_cat`, `macro_rules`, `elab`). It handles indentation,
as Lean's own `do` blocks do. Pyking source could therefore sit
directly in a `.lean` file. This was the original idea. Compared with
a backend:

**For syntax extensions:**
- Pyking text appears unchanged in the proofs, with no generated file
  in between.
- No new `pyk` target is needed.

**Against:**
- **Pyking's grammar would be written a second time**, as Lean macros.
  Every language change would then go into `parser.ml` and into the
  macros, and the two drift.
- **Pyking's checker would be bypassed.** Overload resolution,
  implicits, `use` gates, exhaustiveness and Pyking's own error
  messages live in `typesystem.ml`. The macros would either
  re-implement them or leave them out. A program Lean accepted could
  then be one `pyk` refuses.
- **Clashes with Lean's own syntax.** `def`, `:=`, `::`, `match`,
  `lam`, `|` and operator precedence all mean something else in Lean.
  Each needs a workaround.
- **The same trust gap.** The macros are a translator, as the backend
  is. They are no easier to prove correct, and harder to test.

A backend reuses the real parser and checker, and gives `pyk`'s
errors. It is one more translation in a system that already has five,
and it is tested like them.

## 12. What it touches

Following CLAUDE.md, each layer reaches the whole system.

- **`src/`:** `--core-json`, a pass over the elaborated program and
  `tmap`. Later, `target_lean.ml`.
- **`pyk`:** the new option, and later `-t lean`. Both appear in
  `pyk help` and docs/pyk.md.
- **Tests:**
  - `tests/test_lean.py` and its manifest exclusions.
  - `tests/test_all.py`.
  - A `--core-json` golden test for a few programs, so a format change
    is seen.
- **Docs:**
  - `docs/core_json.md` and `docs/lean.md`, for the model, the
    theorems and how to build them.
  - docs/architecture.md, for the new pass and suite.
  - PYKING.md: one paragraph saying that the core semantics is
    formalized, and where.
  - CHANGELOG.md.
- **Packaging:** none for users. Lean is a developer tool.
- **Editors, REPL, LSP, DAP, playground:** nothing in the first layer.

## 13. Order of work

1. **`--core-json`** and its format document, with golden tests.
   This is useful on its own as an exact dump of what the checker
   settled.
2. **`lean/` skeleton:** syntax, `Json.lean`, and a `pyk-lean` that
   reads a program and prints it back.
3. **Evaluation:** `Eval.lean` and `Int32.lean`, and the comparison
   suite running the pure tests. This is the point where the model is
   known to be Pyking's.
4. **Typing rules** and the Lean re-check of every exported program.
5. **`Step`**, and the proof that `step` and `Step` agree.
6. **Progress and preservation.** This is the first theorem (D1).
7. **Section 9's layers**, one at a time: mutation, exhaustiveness,
   desugaring, tail calls, inference.
8. **After bootstrapping:** `pyk -t lean` with fuel, then measures,
   then the backend's own correctness.

Steps 1–3 should take days to weeks. Steps 4–6 are the main proof
effort of the first layer.

## 14. Open questions

Settled in the interview: D1–D9. Still open, each with a proposal:

- **O1. The core's exchange format.**
  - **Proposal:** JSON, read by `Lean.Json`. It is simple to emit from
    OCaml, readable, and testable on its own.
  - **Alternative:** `pyk` prints Lean terms directly. That needs no
    reader, but each program then needs a Lean compilation before it
    can run, which is slow for 6000 test runs.
- **O2. Environments or substitution in the semantics.**
  - **Proposal:** environments and closures, like `interpreter.ml`.
    This keeps the model close to the code it is compared with.
  - **Alternative:** substitution, which is easier for some proofs but
    further from the interpreter.
- **O3. List comprehensions in the core.**
  - **Proposal:** keep them in the core as one construct with its own
    rule, since the interpreter treats them directly.
  - **Alternative:** desugar them to a fold before export, which makes
    a smaller core.
- **O4. Lean version.**
  - **Proposal:** the newest stable Lean 4 release at the time `lean/`
    is created, pinned, and moved forward deliberately.
- **O5. Spelling of a termination measure in Pyking** (section 10).
  For example `def f(n: Int) -> Int decreasing n:`. This is decided
  when the backend is written, and it needs its own design, since it
  is a language feature every target ignores.
- **O6. Trusting the Lean backend** (section 10).
  - **Proposal:** prove it correct once against the core.
  - **Alternative:** a proof with each translation, as CakeML does.
