# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code
in this repository.

## Project overview

Pyking is an early-stage compiler for a small Python-like language. It is
built to bootstrap: a throwaway implementation is written first in a
convenient host language, with the intent of eventually rewriting the
compiler in Pyking itself and compiling it with the throwaway one.
Concretely:

- `src/` holds the bootstrap implementation, in **OCaml**, one module per
  compiler stage (see "Architecture" below). It is one dune library
  (`pyking`, unwrapped, so a module is `Parser` and not `Pyking.Parser`)
  plus a small executable that links it; `make` builds
  `src/pyk.exe` and copies it to `./pyk`. The library depends on nothing
  outside the standard library — no opam packages — which is what lets
  `src/web/` compile the same code to JavaScript with js_of_ocaml for the
  playground; only the executable links `unix`, for the process handling
  `--run` and the terminal handling the REPL need. `docs/build.md` is
  the long form. The eventual self-hosted rewrite — the compiler written
  in Pyking itself — is meant to replace these modules in place, here,
  rather than live in a second, separate directory; there is no other
  reserved location for it.
- **The code is functional.** No mutation, no objects: an environment, a
  scope, a store, a counter is a value threaded through and rebuilt where
  it changes, never a field written to. Algebraic data types and `match`
  everywhere, so the compiler catches a case nobody covered. Where a
  mutable cell would be the obvious thing, thread a value instead. The
  two deliberate exceptions are both in `interpreter.ml` and are Pyking's
  own semantics rather than convenience: the write-once cell a `def`
  binds, and the location a `var` names.
- `tests/` contains sample Pyking source programs (`.pyk`, not a pytest
  suite), each with a sibling `.out` file holding its expected stdout,
  plus `tests/test_cases.toml` (which program runs on which target) and
  `tests/test_script.py` (see "Running" below for how it uses both).
- `docs/` holds design notes; `docs/architecture.md` is the compiler-side
  counterpart to PYKING.md, `docs/build.md` covers the dune layout and the
  browser bundle, `docs/modules.md` covers the module system,
  and `docs/source.md` describes every module
  in `src/` — what it is, its data structures, its main functions. A new
  module in `src/`, or a change to what one of them holds, belongs there
  as well as in `architecture.md`'s stage table.
- `design/plan-eval-lsp.md` is the plan the interpreter, REPL, debugger,
  DAP and LSP work follows. The first two are built (see
  `src/interpreter.ml` and `src/repl.ml`); the rest is not.

## Pyking language reference

**`PYKING.md`** (repository root) is the language design reference: a
feature summary, a full EBNF grammar, and a worked example for every
supported construct (literals, operators, `var`/`:=` mutation vs. `=`
immutable binding, `for`/`while`/`if`, functions, indentation rules, error
message format, etc.). Read it before writing or editing any Pyking source
(e.g. the `.pyk` files under `tests/`) — it reflects exactly what the
current bootstrap parser accepts, which is not the same as full Python.
Keep it in sync whenever `src/`'s language support changes.

PYKING.md is **language-only**: nothing about targets, generated code,
or the test harness belongs there — not even "compiles to", where
"means" will do. That material lives under `docs/`: `architecture.md`
for the pipeline, `targets.md` for the target list and what each
accepts, `source.md` for what is in each module of `src/`, and one page
per family (`target_python.md`, `target_js.md`, `target_c.md`,
`target_java.md`) for how constructs are compiled and where the output
is weak. `README.md` is a short index pointing at all
of it.
When a change touches how something *compiles* rather than what it
*means*, PYKING.md is not the file to edit.

**Static semantics are language, not compiler.** Its "Type checking"
section documents all three layers — the shape rules the parser applies,
the names and types the checker settles, and the mutability rule
`analyses.ml` applies after it — including what the checker refuses and
why, since
"which programs are well-typed" is a property of Pyking rather than of
the pass that decides it. Extending `src/typesystem.ml` therefore means
editing that section too; `docs/architecture.md` keeps only how the pass
is *built* (its signature, `tmap`, `same_type`), and points at PYKING.md
for the rules.

## Changing the language: always update all five places

A change to what `src/` accepts is not finished until **every** one of
these is updated in the same change — none of them is optional, and the
last ones are the ones that get forgotten:

1. **`src/`** — the stage(s) implementing it (lexer → parser → syntax →
   `module.ml` → `analyses.ml`'s `symbolize` → `typesystem.ml` →
   `analyses.ml`'s `analyze_mutability` → `optimization.ml` → each
   backend). `module.ml` needs nothing for an ordinary construct: it
   reads statements only to find imports and `public`s.
   `optimization.ml` usually needs nothing: it rewrites tail calls and
   passes everything else through. A construct that can *hold* a tail
   position -- a new branching statement, say -- does need a case there,
   or a tail call written inside it is silently left as a call. A new AST
   node needs a case in `analyses.ml`'s `symbolize` and one in
   `walk.ml`'s `children`, and neither is caught by the compiler in a way
   you would notice: `symbolize` would leave the node at symbol `0`, and
   `children` would leave every whole-subtree question blind to it. Every
   *other* `match` over the AST the compiler does catch, which is the
   whole reason the AST is a variant type. `typesystem.ml` does need a
   decision, but only a cheap one — either check the construct or let it
   fall through to `Construct is not supported`, which is what every
   construct it has not reached yet already does. But it is not really
   optional any more: the checker runs for every program, so a construct
   it does not reach is a construct nothing can compile. A construct that
   *binds* a name also reaches `analyses.ml`: it has to bind through
   `bind`, so the no-shadowing-a-`var` rule covers it, and it has to be
   walked into so a `:=` written inside it is seen. Every backend needs a
   decision, not just the Python one: either translate the construct in
   `target_js_core.ml`, `target_c.ml` and `target_java.ml` too, or leave
   it to each of those modules' `unsupported` so that target refuses it
   with a source position. A target added rather than a construct also
   needs a row in `src/execution.ml`, which is what `--run` uses to build
   and run its output. `target_ocaml.ml` is the exception, and the
   reason to keep `typesystem.ml` honest: it compiles exactly what the
   checker accepts, so a construct the checker refuses needs nothing
   there, and one the checker *starts* accepting needs a translation
   there or an explicit `unsupported`. `interpreter.ml` is in the same
   position for the same reason — it runs what the checker accepts, so a
   construct the checker refuses needs nothing there, and one the checker
   *starts* accepting needs a `case` in `_step_eval`/`_step_stmt` or it
   is refused at run time by the same `Construct is not supported`. Its
   `datatype` comment block (values, control, continuations) is
   hand-written like `syntax.ml`'s and drifts just as silently.
2. **`tests/`** — at least one `.pyk` file exercising the new construct,
   with its `.out` captured from an actual run, **and an entry in
   `tests/test_cases.toml`** listing the targets it works on. The harness
   warns about a `.pyk` missing from the manifest, but a wrong target list
   just silently under-tests. A program that *imports* also lists the
   modules it imports under `modules`, in dependency order -- the
   compiler writes them beside the program's own output, and the C, Java
   and OCaml runners have to name them in that order to build the
   program at all. A module listed there is not a case of its own. If the checker accepts the construct, that
   list includes `interpret`: the interpreter is the reference for what
   the program *means*, and the harness warns about a `typecheck_*` case
   that leaves it out. If most of an existing test would work on
   the JS targets but one section would not, split it in two rather than
   marking the whole file python-only.
3. **`PYKING.md`** — feature summary, EBNF grammar, the grammar notes for
   anything the EBNF can't express, and a worked example. Language only:
   no targets or generated code. Its "Type checking" section is the
   exception that proves it — static semantics *are* language, so a
   change to what `analyses.ml` or `typesystem.ml` accepts belongs there
   too.
4. **`docs/`** — anything about *compiling* or *running*.
   `architecture.md` for the pipeline itself (a new stage or module, a
   change to how the driver works, the interpreter's machine);
   `modules.md` for anything about the module system;
   `source.md` for what the module in question now holds;
   `type_inference.md` for anything about how a type is *worked out*
   rather than what the rules are; `analyses.md` for the mutability
   pass;
   `targets.md` for the target list, the shared-subset table, and the
   differences that survive it;
   and the family page — `target_python.md`, `target_js.md`,
   `target_c.md`, `target_java.md`, `target_ocaml.md` — for what that
   family supports, how
   the construct is compiled, and where its output is not optimal. A
   construct a backend *refuses* belongs in its family page too, with the
   reason.
5. **`tools/emacs/pyking-mode.el`** — the editor mode claims in its own
   commentary to mirror `src/lexer.ml` and `src/parser.ml`, so it goes
   stale silently. Check each of these against the change:
   - `pyking-mode-keywords` / `pyking-mode-types` / `pyking-mode-constants`
     — together must still equal the `keywords` list in `src/lexer.ml`
     (split three ways so each gets the right face: control-flow/
     declaration keywords, type annotation names, and literal values like
     `true`/`false` respectively);
   - `pyking-mode-builtins` — extend it when an example or test starts
     calling a new Python builtin;
   - `pyking-mode-font-lock-keywords` — new operator/marker syntax;
   - indentation — a new block-opening or block-closing form usually
     needs `pyking-calculate-indent` or the backward dedent scans taught
     about it (`pyking--if-block-opener-regexp` and its `match`
     counterpart exist because a block header stopped being a line whose
     *first* word is `if`/`match`).

   Verify it, don't eyeball it: `emacs --batch -Q -L tools/emacs -l
   pyking-mode --eval` can compute `(pyking-calculate-indent)` line by
   line over a correctly-indented `tests/*.pyk` file and report any line
   it disagrees with, and `-f batch-byte-compile` must stay
   warning-free.

## Architecture of `src/`

The bootstrap is split into one module per compiler stage:

1. **`src/lexer.ml`** — `info` (a record carrying source location:
   `file`, `row1`, `col1`, `row2`, `col2`, attached to every token, used for
   error reporting), the `token` type (one constructor per kind, e.g.
   `TokInt of info * int`, `TokIdent of info * string`, `TokAdd of info`,
   `TokDef of info`; keep new token kinds in this
   same one-constructor-per-variant style rather than collapsing them into a
   single record with a `kind` field), `pprint_token`/`pprint_info`
   (pretty-printing by `match` over that type), and the
   lexer itself: `lexing file chars` consumes a `char list`
   (not a string) by matching on it (`| x :: xs -> ...`) and returns a
   list of tokens. Helpers:
   `string_until pred chars` grabs the longest matching prefix,
   `scan_string` decodes a string literal's backslash escapes, `is_digit` /
   `is_letter` / `is_digit_letter` classify characters. Row, column, the
   indentation stack and the tokens so far are *parameters* of the
   recursion rather than mutable state. Lexical errors
   raise `Lex_error (info, message)`.
2. **`src/syntax.ml`** — the expression (`E*`) and statement (`S*`) AST,
   one variant type per node group with one constructor per alternative,
   and their pretty printers (`pprint_expr`, `pprint_stmt`,
   `pprint_program`).
   `pprint_program stmts symbols tmap` is the only entry
   point any caller uses; the display options travel as one `config`
   record the printers pass along rather than as state something sets
   and clears. Given a `tmap` (the type
   checker's symbol -> type table), every annotation printed comes from
   it and none from the AST — a node it does not know about prints no
   type at all, whatever the source wrote, since nothing has checked
   that annotation.
   Named `syntax.ml`, not `ast.ml`: nothing forbids the shorter name any
   more, but `open Syntax` at the top of a dozen modules and every doc
   already say `syntax`, and "syntax" is what the file holds. Don't
   rename it.

   The `typ` group is the one with fields that are not the source's:
   `TFunction` carries the definition's symbol and the definition itself
   for a function whose type was
   not written down (see `typesystem.ml` below), and `TUnknown` is a type
   nothing has decided yet. Neither is ever produced by the parser, and
   neither takes part in comparing two function types. Two variants
   are unwritable in source and are the checker's alone — `TUnknown`
   and `TBuiltin` (the type of a host operation, which is what
   keeps `typesystem.ml`'s `env` a map from a name to a *type*). Of the
   two only `TBuiltin` never reaches printed output, since nothing
   records one in `tmap`. A `TVar` the checker made rather than the
   source is *flexible* (the `rigid` flag false) — the element type of
   `[]`, which nothing has constrained; it is written in the same syntax
   a rigid one is.

   **The AST is one recursive `type ... and ...`** declaring every group
   at once — `expr`, `typ`, `pattern`, `comp_clause`, `assign_target`,
   `stmt`, and the single-constructor `param`, `list_rest`, `loop_iter`
   and `match_case`. Gathering them in one declaration means nothing has
   to be declared before it is mentioned, the whole shape of the AST
   reads in one place, and types that refer to each other can be
   compared without scrolling.

   The declaration *is* the datatype description: it says the group is a
   closed set of alternatives, and a `match` over it that misses a case
   is a compile error rather than something to catch in review. What the
   trailing comments still carry is what the type cannot — the source
   syntax each variant stands for. Keep them accurate when a variant's
   spelling changes; nothing checks those.
3. **`src/parser.ml`** — the recursive-descent parser (`parse_atom`,
   `parse_expr`, `parse_statement`, `parse`, ...) that consumes the token
   list and builds the AST from `src/syntax.ml`. Each AST node's `info`
   spans from its first token's start to its last token's end, built via
   `combine_info(start, end)` — when adding a new grammar rule, combine
   infos the same way rather than reusing a single token's span. Parse
   errors raise `Parse_error (info, message)`. A few restrictions that the
   grammar can't express are checked here too, so they fail at parse time
   with a source position rather than in a later stage: duplicate
   bindings in a pattern (`_check_no_duplicate_captures`), the "every
   branch yields a value" rules of a value-form `if`/`match`
   (`_check_value_stmt`, on which `target_python.ml` relies), and
   "a statement starts a line of its own" (`_check_own_line`) -- the rule
   that stops `print h` being read as a bare `print` followed by a bare
   `h`. That one is checked from the `Info` positions the tokens carry,
   since the lexer emits no token for the end of a line; adding one is
   the alternative, and a bigger change than the rule is worth. The same
   positions decide the *other* line rule, in `parse_block`: a block may
   be the one **expression** written on its header's own line
   (`_on_header_line`, the first token after the `:` starting on the row
   that `:` ends on), which is why every caller passes the `:` token
   rather than discarding it. Three checks say what that line may hold:
   `_check_inline_value` (an `SExprStmt` and nothing else -- a `return`,
   a binding or a nested header is refused, so nothing hides behind a
   `:`), `_check_ends_line` (an `else` may not share the line its block
   ended) and `_check_nothing_indented` (nor may an indented block
   follow). A second statement on the line is already `_check_own_line`'s.
   `parse_cases` has no inline form at all: a `match` opens a list of
   clauses, and a `case` is not an expression.
   The module system's two forms belong to the top level, and that is
   enforced by which function is reachable rather than by a check:
   `parse_top_statement` is the only thing that parses an import or a
   `public`, `parse` is the only thing that calls it, and
   `parse_statement` -- which every block goes through -- refuses their
   keywords outright. It is also the one function that answers with
   *several* statements, since `import a, b` is one line standing for
   two `SImport`s; `_check_own_line` is then applied to the first of the
   group, the rest sharing its line by construction. A qualified name
   (`m.f`) is read in `parse_atom` and requires the `.` to start on the
   row the module name ended on, for the reason `call_tail` requires it
   of a `(`. An inline block is
   otherwise nothing special -- it builds the same one-statement block
   the indented form does, so no later stage knows which was written. Two more
   belong to the `loop` construct and are here for the same reason --
   both are shape, neither needs to know what a name means, and being
   here they hold whatever else runs: `_check_loop_context` (a `break`/`continue` belongs to the
   innermost `loop`, and may not reach out of a `for`, a `while` or a
   `def` to find one) and `_check_reachable` (nothing may be written
   after one in the same block). Neither keyword takes an operand: a
   loop is worth the accumulator it stopped with, so there is nothing
   for either of them to say.
4. **`src/module.ml`** — the module system: one file is one module, and
   a program is the acyclic graph of the modules its main file reaches.
   `load(path)` reads and parses all of them (resolving each import
   **in the importing file's own directory** -- there is no search
   path), refuses a cycle, and answers with them in dependency order,
   symbolized with **one numbering across the whole program**
   (`analyses.symbolize(stmts, start)`), which is what lets a single
   `tmap` and a single call-free table span them. Errors raise
   `Module_error (info, message)`, reported as `Module error`.
   `check_publics` settles what a module exports and refuses a name
   exported twice or an exported name bound twice; `resolve_imports`
   fills in a plain import's `fields` from the imported module's public
   names, refuses a `from` line naming something not exported, and
   refuses a name that collides with anything the importing module
   already uses. `make_sigmap stmts tmap` turns a checked module into
   the `typ SMap.t` the next one is checked against -- made from the
   program the *checker* saw, before the tail-call pass, since that pass
   can change how a module computes what it exports and never what it
   exports. `Context` is what a backend is told about the module it is
   compiling beyond its statements (its name, whether it is the
   program's own, whether the program has more than one module at all,
   the modules to start first, every module's sigmap); a program of one
   module gets a `Context` saying so, which is what keeps a single-file
   program's output byte-for-byte what it was. `read_file` is the one
   entry that reads a single file and checks nothing, which is where
   `--no-typechecking` stops -- the flag halts the front end after
   `symbolize`, and reading a module the program imports is something
   only the stages after that need. The two front ends that
   compile a file with no program around it -- the REPL and the browser
   playground -- run `check_publics` (it needs only the file) and let
   `typesystem.available` refuse an import (it needs the program); the
   playground additionally offers neither a program that imports nor a
   module it imports as an example. See `docs/modules.md`.
5. **`src/analyses.ml`** — static analyses over the parsed AST, run
   between the parser and any backend; errors raise
   `Analysis_error (info, message)`. The one the driver runs is
   *mutability*, and it runs **after** `typesystem.ml`, which owns names
   now: `analyze_mutability` is a single
   recursive walk carrying a *binding-kind environment* (a map from a
   name to its kind of binding) that is rebuilt rather than mutated — entering a
   nested scope is "keep using the environment you were handed", leaving one is "go
   back to the caller's", which is what makes a block's bindings unable
   to escape it. `analyze_stmt` returns the environment its statement
   leaves behind (that is how a statement sequence accumulates
   bindings); `analyze_scope` deliberately discards it. Everything that
   introduces a name funnels through `bind`, which is where the one
   shadowing rule lives (a `var` may not be shadowed by anything), so a
   new binding form only has to call it to be covered. The other rule is
   `analyze_stmt`'s `SMutate` case: `:=` may only name a `var`. The walk
   never descends into an expression, because no expression mutates
   anything. `BUILTINS` seeds
   `print`/`range`/`str`/`len`, and `typesystem.ml` imports it — extend
   it when a program starts calling another builtin.
   Keep new analyses in this module as separate `analyze_*` entry points
   rather than folding more checking into the parser: the parser's job
   is shape, and only a scope-aware walk can judge how a name is bound.
   `analyze_stmts` binds every `def` in a block *before* walking any of
   it, which is what makes functions usable ahead of their definition —
   recursion, mutual recursion, a helper at the bottom of the file — and
   is the one departure from binding in source order (see PYKING.md,
   "Names and scoping"). Only the *names*, and only functions': an `=`
   binding stays sequential, and what a body captures is whatever is
   bound where the body is written. **`block_functions`** is what makes
   hoisting a name safe — one `def` per name per block, and no other
   binding of that name there (`check_no_function_clash`), so a hoisted
   name has exactly one meaning in its block. `typesystem.ml` imports
   both rather than restating them; keep it that way.

   Also here: **`symbolize`**, which gives every AST node a unique
   integer `sym` (post-order from `start`, which defaults to 0; `0`
   means "not symbolized yet"). `start` is what makes one numbering span
   a program of several modules -- `module.ml` hands each module the
   highest the one before it reached -- and that is what lets one `tmap`
   and one call-free table cover all of them.
   Unlike `analyze_mutability` it *rewrites* — nothing is mutated, so it
   rebuilds the tree, threading the counter through as a value. It is one
   case per constructor, in the order `syntax.ml` declares that node's
   fields, so a node added to `syntax.ml` needs a case here or it keeps
   symbol `0` — and only the `--symbols` half of the suite would catch
   it. A node that already has a
   symbol keeps it and new numbers continue past the highest in the
   tree, which is what makes it safe to run twice, should a pass ever
   synthesize nodes into an already-symbolized tree.

   And **`Effects`**, which the driver does not run at all: a
   fixed-point walk of the call graph saying which functions — and so
   which expressions (`may_print`) — can produce output. It is here
   rather than in a backend because it is an analysis of the Pyking AST,
   and because two backends need it: `target_ocaml.ml` and
   `target_c.ml`, whose host languages both leave the order of an
   operator's operands and a call's arguments unspecified, so each has
   to pin down the ones that can print (see PYKING.md, "Evaluation
   order", and each backend's page). It is deliberately conservative —
   overestimating who prints costs a temporary, underestimating prints
   in the wrong order — and a call to something that is not a `def` is
   assumed to print if anything in the program does. `all_functions` is
   here for it, and folds over `walk.ml`'s `children` like every other
   whole-subtree question in the compiler.

   A module of its own sits beside this one: **`src/walk.ml`**, one
   `node` variant covering every AST node and one `children` function
   giving a node's immediate children in `syntax.ml`'s own field order,
   plus the folds built on it (`fold`, `exists`, `exprs`, `stmts_in`,
   `name_field`). Every pass that asks a question of a whole subtree —
   `effects` here, the interpreter's call-free table, the C and Java
   backends' "is this name used as a string" — goes through it rather
   than writing its own descent. **A node added to `syntax.ml` needs a
   case in `children`**, and nothing but a pass that would have looked
   inside it will notice if it is missed.
6. **`src/optimization.ml`** — tail calls into loops, one pass from the
   Pyking AST to the Pyking AST, run *after* the type checker and only
   over a program it accepted, unless `--no-tail-call-opt` says
   otherwise. The types are what make it decidable, which is why it runs
   there: they say whether a group can share one loop, and what a slot a
   narrower member does not fill is entered with. The checker runs once
   and its result is not checked again -- sound because the rewrite
   preserves typing by construction, so read `docs/optimization.md`
   ("Why one check is enough") before changing what it builds. A
   function that calls itself in tail position becomes a `loop` carrying
   its own parameters *under their own names*; a group that tail-calls
   each other becomes one `tail_groupN` worker carrying a `state` tag,
   as wide as the group's widest member, with each original left as a
   one-line wrapper. It rewrites and never rejects: a group whose types
   do not fit one loop is left as the recursion it was, and so is a
   function holding a tail call it cannot say as another turn. Going
   round is *ending a block* in the next accumulator, since `continue`
   carries nothing, and stopping is a `return` -- the loop is the whole
   body of its function, so leaving the two is one act. A tail call
   that is not a block's last statement is restructured first
   (`_hoist`: a guard whose every path returns takes what follows it
   into its `else`), and declined where that cannot be done. Tail position is PYKING.md's own, and the walk stops at a
   nested `def` (whose tails are its own) and at a `for`/`while`/`loop`
   (where a block belongs to that loop instead). Because the
   output is ordinary Pyking, every backend and the interpreter get tail
   recursion without knowing this pass exists -- so *do not* add
   per-backend tail-call handling. The one exception runs the other way:
   a host that eliminates tail calls itself is named in `pyk.ml`'s
   `NATIVE_TAIL_CALLS` list (today just `ocaml`), and that target is
   then compiled from the program *as written* -- because a `loop`
   becomes a local recursive function on that backend, so the pass and
   the backend would otherwise undo each other and leave a
   tag-dispatched worker where `let rec ... and ...` belonged. The one thing it cannot always make
   work is a merged group whose functions disagree about their parameter
   *types*, which only the checker can see; `docs/optimization.md` is
   the long form, including that case and the `fail_tco_*` tests that
   pin it.
7. **`src/typesystem.ml`** — the type checker, run for every mode and
   every target, after `symbolize` and before anything else reads the
   program: Pyking is statically typed and there is no flag for it. It
   is also the only pass that checks *names* (see `pyk.ml` below).
   One entry point, `type_check(stmts, sigmaps) -> tmap`: one module in
   -- or a whole one-file program, which is the same thing -- and the
   types it worked out back. `sigmaps` pairs the name of every module
   this one imports with what that module exports and at what type
   (`module.make_sigmap`), and is all of another module this check can
   see; `import_env` puts what they bring in into the environment
   *before* the first statement is checked, since an import is a
   declaration of the module rather than a statement in its sequence --
   and it has to be that way round, because a deferred body is checked
   in the environment recorded where it was written. The other
   direction is `check_exports`, run at the end: a `def` that annotated
   nothing has no type until something calls it, and inference reads it
   off its *own* module's use of it -- so exporting one this module
   never calls is **refused**, not inferred from nothing. An exported
   `def` is fully annotated or called in its own module; see PYKING.md,
   "What a module may export". Two consumers now define their coverage as
   "whatever this accepts" — `target_ocaml.ml` and `interpreter.ml` — so
   widening the checker widens both, and each needs the corresponding
   `case` or an explicit refusal.

   Inside, **one function per AST datatype** — `check_stmts` ([Stmt]),
   `check_stmt` (Stmt), `check_expr` (Expr), `check_param` (Param),
   `same_type` (Type) — each taking a node of exactly that type and
   returning exactly one kind of answer, with the signatures written out
   OCaml-style in a block near the top. Keep that shape when extending
   it: no function here dispatches on which *sort* of node it was handed,
   only on which variant of its own datatype. `Env` maps a name to its
   type and is used *immutably* — a binding hands what follows it an
   extended copy, the same discipline `analyses.ml` follows.

   `check_stmts` calls **`declare_functions`** first, binding every `def`
   in the block before checking any of it — that one step is recursion,
   mutual recursion and forward references, since a body is then checked
   in an environment holding its own name, its siblings' and every
   enclosing block's. It goes through `analyses.block_functions`, so the
   two passes cannot disagree about which programs are legal. A body is
   otherwise checked in the environment at its *own position*, which is
   what the language says it captures — so what the checker proves is
   what runs (see `tests/lexical_capture.pyk`). A `def` that is not fully annotated is declared
   with no type rather than refused there, so errors stay in source
   order. Mirror any change to it in `analyses.ml` and in each backend's
   own declaration pass.

   **`Env` is also the scope**, and the checker does its own name
   checking with it: bound-before-use, block bindings that do not escape,
   shadowing, a `def`'s name in its own body, and `analyses.BUILTINS`
   (imported, not re-listed) in scope from the start. An unbound name
   raises `Analyses.Analysis_error`, in its words, so the message does not
   depend on which pass ran. **The value type is `Type`, with no option
   and no second inhabitant**: a name is in the map with a type, or it is
   not in scope, and there is no third state to ask about. A builtin is
   in it like anything else, at a type of its own: `env` maps
   `print`/`range`/`str`/`len` to a `TBuiltin`, checked at the call by
   `check_builtin_call` and refused as a value, because none of them
   fits a `TFunction` (a variadic `print` is not a `(T) -> ()`) and
   `runtime_interface.ml` calls them operations rather than functions. A
   new builtin needs a case there as well as an entry in
   `analyses.BUILTINS`. **`var` and `:=` are checked here**, and only
   for *types*: a `var` is `Int` or `Bool` (`check_mutable`), and a `:=`
   must give the type the declaration fixed. Which names may be written
   to is not a type question — the same `Int` is a `var` in one scope and
   an `=` binding in another — so `analyses.analyze_mutability` answers
   that one, in a walk of its own, after this pass. `tmap` is
   the other half of the answer: a map from a node's *symbol*
   to the type inferred for it, built as the pass runs and returned as
   its result. It is a field of the `store`, which is threaded and handed
   back everywhere already, so nothing has to be mutated to make it
   work. **The checker does not
   touch the AST** — it rebuilds nothing and writes into no node's
   `type` field — so what the source wrote and what the checker inferred
   stay separable; keep it that way. When checking finishes `tmap` holds
   an entry for every annotatable construct the checker reached
   (`SFunctionDef`, `Param`, `SLet`, `SLetStmt`) — a `SFunctionDef`'s
   being its *function* type, since the type of a thing is the type of
   the thing and `-> T` in the syntax is only part of it (the printer
   takes `TFunction.result` for that slot) — **and for every expression
   besides**, which is what the split between `check_expr` (record) and
   `expr_type` (the rules) is for. `pprint_program` never asks for those;
   `src/target_ocaml.ml` does, and is the reason to keep making them: it
   compiles only what this checker accepts, so rather than inferring
   types a second time the way `target_c.ml` and `target_java.ml` each
   must, it reads them back from here. Types are `syntax.ml`'s own
   `T*` nodes, not a separate vocabulary, so a checked binding prints as
   `x: Int = 1` — syntax the parser accepts, which keeps
   `-t pyking` output re-parsable; they are synthesized here, so
   they carry no symbols. That includes `TFunction`, `(Int, Bool) -> Int`,
   which `parse_type` reads as well as prints, so `g: (Int) -> Int = f`
   round-trips like anything else. Compare types with `same_type`, never
   `=`: every `T*` constructor carries `info` and `sym`, which structural
   equality would compare too.

   A loop has one type and it is the accumulator's: what the body ends
   in is the next turn's accumulator, held to that type by `agree`
   (`carry_error` is the refusal), and the loop is worth that same
   accumulator however it stops -- a `break`, or a `for`/`while`
   running out of turns. `check_turn` is where the body is checked, in
   a frame of the loop's own; it answers `None` for a body all of whose
   paths jump, and that asks nothing, which is what lets a branch that
   breaks sit beside one that ends in the next accumulator. A `loop:`
   carrying nothing carries and is worth unit, and asks nothing of its
   body at all. `break` and `continue` take no operand and supply
   nothing, so neither needs a rule of its own. A `return` written in a
   loop body belongs to the enclosing *function*, so `check_turn` hands
   the frame back as it came rather than restoring the one it was given
   -- that is what lets an unannotated function's return type be decided
   by a `return` inside a loop.

   Most statements and every program have type unit; an *expression
   statement* has its expression's type and a *block* its last
   statement's, which is what makes the two branches of an `if`
   comparable — they are required to agree, and an `if` with no `else`
   is checked against unit. A binding takes its right-hand side's type,
   and where it wrote an annotation that annotation is *checked* against
   it (`check_annotation`) rather than replaced — an annotation is a
   claim about the program, and verifying it is the difference between
   an annotation and a comment. A `def` is checked only when every parameter
   and the return type is annotated (it infers nothing about a function
   it was not told); then every `return` must give the declared type and
   the body must *produce* it — by returning on every path, or by ending
   in a value of that type (PYKING.md's "Tail position"), or by mixing
   the two. One check covers all three because every statement is asked
   one question — what value does it *supply*? — and `return e` answers
   "e's", which is what the tail-position table says of it; so a
   returning branch and a value-ending branch compare without either
   being a special case. Recursion needs nothing special: the name is
   already bound to the declared type by `declare_functions`, so a
   recursive call is an ordinary call.

   Both forms of `if` are covered -- the statement and the
   `if c then a else b` *expression* -- and both are checked the same
   way: the condition is demanded to be Bool, and the two branches are
   held to being one type by `agree`. The `else` is checked against the
   store the `then` *left*, since what either branch worked out is true
   whichever way the program goes. A construct the checker starts accepting
   needs the interpreter to run it as well, since the interpreter's
   subset *is* this fragment: the `if` expression needed `KChoose` and a
   case in the call-free fast path, and a construct added without them
   type-checks and then fails at run time.

   Everything outside that fragment raises
   `Type_error(info, "Construct is not supported")` — including a name
   it cannot find, since no name analysis has run ahead of it in this
   mode. Keep that floor explicit rather than silently accepting what it
   has not reasoned about.

   **Inference works a definition out from its body, not from the call.**
   A `def` that annotated everything is checked where it is written, as
   above. One that did not is *not checked there at all*: `declared_type`
   gives it a `TFunction` with `TUnknown` where the annotations are
   missing, `definition` holding the `def` itself and `tmsym` its symbol
   -- the name the checker's tables use for it -- and `infer_definition`
   works it out the first time something calls it. The call is a
   *trigger* and a *scope*, and nothing else: every parameter goes in as
   a metavariable and the body's own demands decide them, so what comes
   out is the definition's principal type, the same whatever called it
   and in whatever order. That is Hindley-Milner, and the call that
   triggered it is then checked against the result like any other call.
   Six things are easy to break and are why it works:
   - **A metavariable is `TVar` with `rigid=False`**, named `?n`, and a
     rigid one is its exact opposite: a metavariable is a type *this
     check* is still choosing, a rigid variable one the *caller* chose.
     One class serves both because that is the only difference. Its
     solution lives in `store.solutions`, never in the node, so a type
     stays a value like every other type here; `prune` looks through one
     solution, `zonk` reads a whole type back.
   - **`unify` is first-order, eager and local.** It is called where a
     type is *demanded* -- a call's arguments, an operator's operands,
     two branches, a pattern against its subject -- and answers there.
     There is no constraint store, no worklist and no solver pass, which
     is what keeps every error a sentence about one place in the words
     the checker already uses. Two details are load-bearing: the occurs
     check, and that when two metavariables meet the *younger* is solved
     to the older (`meta_age`) -- a variable handed out earlier may
     belong to an enclosing scope, and losing that is what would let a
     nested `def` generalise its enclosing function's parameter.
   - **Every *use* of a scheme is instantiated** (`instantiate`) with
     fresh metavariables. That is what lets one definition serve two
     callers at two types, and it is also why **inference never produces
     a higher rank**: a metavariable is a type, never a scheme, so no
     `all` can be carried into a parameter the checker is working out.
     A parameter *written* `(all a. ...)` is the exception, and being
     written down is the whole of the difference. Do not add rank-2
     inference: it is undecidable in general, and anything that guesses
     at it gives up the one guarantee this inference has -- the
     principal type, whatever called the definition and in whatever
     order.
   - **`generalise` binds what the body left unsolved** -- except what
     the scope the definition was written in already holds
     (`free_metas`). That side condition is Hindley-Milner's, and it is
     the one place generalising is *unsound* rather than merely
     imprecise. A variable it could not generalise goes in
     `store.captured` and prints as `?`, since Pyking cannot write "the
     type my enclosing function was called at" and a letter there would
     read as more general than the truth.
   - **`verified`** checks the body again against the scheme with the
     variables **rigid** -- the check an annotated polymorphic function
     already gets. Unification is sound, so it should never refuse
     anything, and it earns its keep twice over: it makes "a type this
     checker reports is one it enforces" true by construction, and its
     *failure* is how the four overloaded builtins are handled at all.
     `str`, `len`, `==` and `++` accept several types and no one type, so
     a body using one on a parameter generalises to a promise it cannot
     keep; the re-check says so, the definition keeps its monotype, and
     the first call settles it.
   - **The `Store`** is everything inference has worked out, threaded
     through the pass as a value: `environments` (where each `def` was
     written -- a deferred body is checked in *its own* scope, never the
     call site's), `instances` (one scheme per definition), `solutions`
     (what each metavariable turned out to be), `captured` (what a
     definition could *not* generalise), and `checking`, `frame` and
     `fresh` for the walk itself. Two are *given* rather than worked
     out: `signatures`, from a `def name : type` line, and `groups`, the
     block's `def`s, so a group that names itself is done together.
     Nothing in it is written to; `learned(store, inner)` is the one
     place the difference between knowledge and context is stated.

   **Recursion is not a special case.** While a body is checked its own
   name means the *monotype* its parameters were given, so a recursive
   call is an ordinary call. `inference_group` computes the strongly
   connected component of the definition in its block's call graph, and
   those are worked out and generalised together -- Hindley-Milner's
   `let rec` rule. Only the component: a sibling this body merely calls
   is worked out and generalised first, on demand, so it is polymorphic
   by the time this body uses it. That is the difference between
   `let`-bound and lambda-bound, and it is what lets one caller use
   `identity` at two types while a *parameter* used at two types is
   refused.

   `docs/type_inference.md` is the long form, including the decisions
   that could have gone the other way; keep it in step with this module.

   **Nothing in this module changes anything, except `tmap`.** An
   environment, a store, a type, an instance: each is handed on, extended
   by being rebuilt, and left alone by whoever passed it. A function
   given a store returns one, because what it worked out is knowledge its
   caller needs. `record` filling in `tmap` is the single exception, and
   it is the pass's *result*. Do not put state back into a record the
   types point at, however convenient. `record` also *overwrites* rather
   than accumulating -- a generalisable body is checked twice, and
   `verified`'s pass is the one that counts -- and `type_check` reads the
   whole table back through `zonk` at the end, since a metavariable open
   where it was recorded may have been solved by something written
   further down.

8. **`src/runtime_interface.ml`** — the boundary between pure Pyking code
   and the outside world, in the spirit of WebAssembly's split between a
   core language that cannot observe anything and a separate host spec.
   Backend-agnostic by construction: it holds no Python and no JavaScript,
   only the named operations (today just `print`) and their semantics,
   *including* the value-formatting rules, since every backend has to
   agree on those for one program to print the same characters
   everywhere. Add an operation here first; the backends then bind it.
9. **`src/target_js_core.ml`** — the JavaScript backend's language half:
   a `Js*` AST, translation from `syntax.ml`, and a printer. Knows nothing
   about packaging. Calls that cross the runtime interface become
   `JsRuntimeCall`, whose spelling is supplied by the packager, so the
   same core output serves all three JS targets. JavaScript fits Pyking
   better than Python does — `const`/`let` are Pyking's `=`/`var`, and
   `{ }` blocks are scopes — so it renames only where JavaScript forces
   it (`const` redeclaration, and the temporal dead zone), not on every
   shadow the way `target_python.ml` must. Constructs outside the
   supported subset raise `Unsupported`, which carries an `Info`.
   The one place a `let` is not enough is a `loop` whose body defines a
   function (`_defines_function`): the accumulator's `let` stands outside
   the loop and is therefore *one* binding, so every turn's function
   would close over the last turn's value. There the `let` becomes a
   carrier holding what the next turn starts with, and the accumulator
   becomes a `const` inside the body -- one binding per turn, which is
   what each function closes over. A loop with no function in its body
   keeps the plain `let`, so ordinary output stays ordinary. See
   `tests/loop_def_capture.pyk` and `docs/target_js.md`.
10. **`src/target_js_packaging.ml`** — the JavaScript backend's packaging
   half: wraps core output into `nodejs` (one self-contained script),
   `html` (one self-contained page printing into a visible box), and `esm`
   (a module exporting `run(runtime)`, plus a node driver and an HTML
   wrapper derived from the `--output` path). It owns the JavaScript side
   of the runtime interface — each host's `print` and the shared
   `pykFormat` — which is exactly what differs between the three.
11. **`src/target_c.ml`** — the C backend, serving both the `c89` and
   `c23` targets: a `C*` AST, translation, and a printer taking a
   `standard` parameter. One backend rather than two because the
   standards disagree about *printing*, not meaning — comments, whether
   declarations may follow statements, whether `bool` exists — so the
   `standard` reaches only `pprint_c_program` and its helpers. Its real
   work is the type inference C forces and Pyking never needed: every
   expression node carries an `Int`/`String`/`Bool` type, bindings take
   their initializer's, parameters their annotation (when C can represent
   it) or a guess from the body, and a function's return type is read off
   its translated body. When inference cannot answer, raise
   `Unsupported` with the `Info` rather than emitting C that will
   not compile. The other thing C forces is *order*: it leaves an
   operator's operands and a call's arguments unspecified, and real
   compilers differ by architecture (x86-64 evaluates arguments right to
   left, AArch64 left to right), so `in_order`/`sequenced` pull every
   operand `analyses.Effects` says can print into a temporary and put
   the assignments in front of the result with the comma operator — the
   one construct that fixes an order *inside* a C expression, which is
   what a `while` condition and an `if` expression's branches need.
   `target_ocaml.ml` does the same with `let` for the same reason; keep
   both reading `Effects` rather than deciding for themselves.
12. **`src/target_java.ml`** — the Java backend, serving `java8`,
   `java17` and `java21`: a `J*` AST, translation, and a printer taking a
   `version` parameter, the same shape `target_c.ml` uses for `standard`
   — one backend because the three versions disagree only in whether a
   local declaration writes `var` (Java 10's local-variable type
   inference, absent from java8) or spells its type out. Infers types the
   same way `target_c.ml` does (`Int`/`String`/`Bool`, from initializers,
   annotations, and translated return bodies), and additionally checks
   that every function provably returns on every path
   (`_definitely_returns`) and that no statement follows one that always
   does (`_check_reachable`), since `javac` — unlike `cc` — refuses to
   compile either. Needs no runtime helper the way C's `pyk_concat` and
   `strcmp` are: string concatenation is Java's own `+`, and equality is
   `.equals()`. The output file and its class are named in Java's own
   style rather than the source's, since Java requires the two to match
   (`default_class_name`; see `pyk.ml` below for where the exception
   is applied).
13. **`src/target_ocaml.ml`** — the OCaml backend, serving the `ocaml`
   target: an `O*` AST, translation, and a printer. The only backend
   that infers nothing — it *runs* `typesystem.type_check` and reads the
   types back out of `tmap` (which is why `check_expr` records an entry
   for every expression, not just annotatable ones), so its supported
   subset is exactly the checker's and a program that does not check is
   refused with the checker's own message. OCaml fits Pyking closely
   enough that most of the translation is direct — `let ... in` is a
   block scope, a rebinding is a new binding, `let rec ... and ...` is
   Pyking's rule that every `def` in a block is visible throughout it,
   and `true`/`false`/`()` are spelled identically — so the interesting
   work is in what it emits *around* that: no type annotations at all,
   `rec` only where something recurses, `_name` for a binding nothing
   reads, and a `let` inserted wherever two operands of one expression
   can both print, since Pyking evaluates left to right and OCaml does
   not promise to (`_Effects`, `in_order`). The test harness builds its
   output with `-w +a`, so a compiler warning about generated code is a
   failing test.
14. **`src/target_python.ml`** — the Python code-generation backend: its
   own `Py*` AST (`PyInt`, `PyAssign`, `PyFor`, ... — structurally the same
   shape as `src/syntax.ml`'s `E*`/`S*`, except Pyking's `SLet`/`SVar`/
   `SMutate` all collapse into one `PyAssign`, since Python has no
   mutable-vs-immutable-binding distinction, and `SLetStmt` — an
   `if`/`match` statement bound with `=`, see PYKING.md — has no node of
   its own at all, since it compiles to the ordinary `PyIf`/`PyMatch`
   with a `PyAssign` pushed into each branch's tail), a `Scope` threaded
   through the whole translation (Pyking name → the Python name standing
   in for it: Pyking blocks are scopes and Python's aren't, so a binding
   that shadows another *within one Python function scope* is renamed —
   `total` → `total2`, → `total3` if taken; `_bind`/`_lookup`/
   `_block_scope`/`_function_scope` are the whole mechanism, and it
   renames only when necessary, never inside a `def` body or
   comprehension, where Python already scopes, and which also carries
   `depth`/`mutables` for the rule below), `translate_program`/
   `translate_stmt`/`translate_expr` (Pyking AST → `Py*` AST; statement
   translators return `(node, scope)` so a sequence accumulates
   bindings, and a caller entering a block discards the returned scope;
   each `match`
   ends in a `case _: raise NotImplementedError(...)` so a future Pyking
   construct without a translation fails loudly rather than silently
   returning `None`), and `pprint_py_expr`/`pprint_py_stmt`/
   `pprint_py_program` (Py* AST → Python source text). It was the first
   backend and the JavaScript ones followed the same shape — keep it
   independent of `syntax.ml`'s pretty-printing internals so the next one
   can too, without entangling target-specific logic into the Pyking
   AST/pretty-printer. `_declare_functions` binds every `def` in a block
   before translating it, mirroring the front end: Python resolves a
   forward reference by itself at call time, but a *renamed* function
   (`helper2`) has to be renamed before the call written above it is
   emitted. `target_js_core.ml` does the same for the same reason; C and
   Java instead register signatures ahead (and C prints prototypes),
   since those two have to know a function exists before a call names
   it. Two analyses carry the scoping story the rest of the way, both in
   `target_python.ml`: **`_free_names`** (a scope renames a binding that
   shadows a name its body reads from *outside* itself, since any
   binding inside a Python function makes that name local to all of it)
   and **`_captured_names`** (a rebinding some function already captured
   gets its own Python variable, because in Pyking it is a *new*
   binding). A `def` inside a loop additionally goes through
   `_translate_capturing_defs`, which builds each turn's functions with
   a small factory so they keep that turn's values. See
   `tests/lexical_capture*.pyk`, `tests/shadowing_functions.pyk` and
   `docs/target_python.md`. A `def` inside a loop goes further: the
   `def`s of that block which *name each other* are built together by a
   per-turn factory (`_turn_groups`, `_absorbed`,
   `_translate_turn_group`), so each turn's functions find each turn's
   functions. Nothing but `def`s moves — keep it that way, since a
   `return` or `:=` carried into a factory would change what it means —
   and captures are read positionally, with `var`s excluded. See
   `docs/gap.md` and `tests/lexical_capture_group.pyk`. The test script
   additionally refuses a factory in any program with no `def` inside a
   loop, which is what keeps ordinary output ordinary. C and Java instead *refuse* a function that
   reads a binding from around it — they have no closures.

   Two more things this backend has to say out loud where no other one
   does. **A `def` that writes a `var` bound outside it opens with
   `global` or `nonlocal`** (`_mutated_names`, `_scope_declarations`),
   since assigning a name anywhere in a Python function makes it local to
   the whole function — without it the write would make a second variable,
   or raise `UnboundLocalError` where the body reads it too. `Scope.depth`
   (0 is the module) and `Scope.mutables` (each `var`, and the depth its
   declaration sits at) are what pick between the two. See
   `tests/typecheck_var_functions.pyk` and `tests/typecheck_var_nested.pyk`.
   And **`translate_program` takes `tmap`**: Pyking prints `true`/`false`
   where Python prints `True`/`False`, so a `print` argument is formatted
   by its *type* (`_bool_kind`) — inline for a `Bool`, bare for a type
   with no `Bool` anywhere inside it, and through the generated
   `__pyk_str` walker only for one that can hold one. That is what keeps
   an ordinary program's output free of a prelude it has no use for; do
   not go back to guessing from the AST's shape.
15. **`src/interpreter.ml`** — the interpreter: a *resumable machine*
   that runs the AST directly instead of translating it, and the
   reference for what a program means at run time (where a backend
   disagrees with it, the backend is wrong). It runs exactly the fragment
   `typesystem.ml` accepts, and the gate is the checker itself —
   `check(stmts)` *is* `type_check` — the same arrangement
   `target_ocaml.ml` uses, so there is no second list of supported
   constructs to keep in step.

   **Values** are one `value` type with one constructor per variant
   (`VInt`, `VString`, `VBool`, `VUnit`, `VList`, `VTuple`, `VClosure`,
   `VBuiltin`, `VUndefined`). They hold no host objects — no OCaml
   closure, no array standing in for a Pyking list: the representation
   has to survive the rewrite into Pyking.

   **`env`** is a persistent chain of frames — `extend` builds a new
   head, `lookup` walks outwards — so Pyking's scoping needs no
   machinery: a block runs in a chain of its own, `=` shadows rather than
   updates, and a closure holds the chain it was created in. The one
   mutation is Pyking's `def` rule, split in two: **`declare`** puts a
   write-once cell per `def` of the block in one frame (holding
   `VUndefined`), and **`define`** fills it when the definition is
   reached, with a closure capturing the environment *there*. That is how
   a function name is visible throughout its block while its body still
   captures what was bound where it is written, and why using one early
   says "its `def` has not run yet" rather than "unbound". Which `def`s a
   block has comes from `analyses.block_functions`, imported rather than
   restated, exactly as `typesystem.ml` imports it.

   **The machine** is `step(State) -> State`, driven from a flat loop in
   `run`, with `State(control, env, kont, stack, runtime, loops)` — `Runtime`
   holding what a run never changes (host, the call-free table,
   `max_depth`) so a step allocates one small object. `step` is *total*
   and never raises: an error becomes a `CFailed` state, with the
   environment, continuations and frames intact, because a debugger wants
   to stop *at* an error rather than after unwinding. Three invariants
   are the reason it is written this way and are easy to break by
   accident: sequencing is an **index** into a statement list (`KSeq`),
   so a block never grows the continuation chain; the Pyking call stack
   is `State.stack`, so depth costs heap and an explicit `max_depth`
   (10 000) turns runaway recursion into a Pyking error rather than an
   OOM; and every value walk (`format_value`) is iterative, since runtime
   data can nest deeper than the host stack allows. Keep all three.

   The embedding API is what the debugger, DAP and LSP will sit on, so
   keep it the only way in: `initial_state`, `step`, `run(state,
   steps=None)`, `run_program`, `declare_entry`/`eval_in`/
   `eval_statement` (running statements in an existing machine's
   environment — what a prompt does, and what a debugger's "evaluate in
   this frame" will do), `result`, `failure`, `stack_trace`,
   `format_value`/`display_value` (emitting a value and showing one —
   they differ over quoting a string), and the `Host` classes.
   `Host` has one method per `runtime_interface.OPERATIONS` entry; the
   formatting rules are that module's, implemented once here.

   Two things that are language decisions rather than implementation
   ones: an `Int` is **32-bit, wrapping** (`wrap32`, applied to every
   literal and every `+ - *`), which PYKING.md states and
   `docs/targets.md` measures the backends against; and `call_free_symbols`
   is the one optimisation — an expression with no call in it can neither
   suspend nor print, so `_evaluate` computes it in one go, off a set
   worked out once before the program runs.
16. **`src/repl.ml`** — `pyk repl`, and the editor it is typed into. A
   session is *a program written one entry at a time*, and the rule that
   settles everything is that **an entry is checked the way it is run**:
   each entry is a group whose `def`s are declared together
   (`typesystem.declare_functions` for the types,
   `interpreter.declare_entry` for the values) and checked against the
   environment the entries before it left behind, then run there with
   `interpreter.eval_in`. So a later entry is a later group -- redefining
   a name is ordinary shadowing rather than the "one `def` per name per
   block" error it would be inside one block, a function written earlier
   keeps whatever it captured, and a function written now is invisible to
   one written before it. Do not go back to checking the accumulated
   program as one block: that made the checker describe a program the
   machine was not running.
   An **import is refused at the prompt**, and by the checker rather
   than by anything here: an import needs the module system, and a
   session is one file on its own. `typesystem.available` is where that
   is said, so the REPL and the playground get the same words.
   `Session(seen, state, types, store, kinds, sources)` holds the two
   environments --
   the machine's and the checker's, extended in step -- plus every
   statement the session has seen (which exists only so `symbolize` keeps
   handing out fresh symbols; the machine's call-free table is keyed by
   them) and, per name, the *text* that defined it, sliced from the entry
   it arrived in by the statement's own span. That text is what `:edit
   <name>` puts back in the prompt, and it is text rather than a printed
   AST so a definition comes back with its comments and spacing.
   Values print as `value : Type`, with the value from the machine and
   the type from the checker; `:ls` lists the bindings the same way.
   An entry refused for naming something not defined yet is *not* thrown
   away: two mutually recursive functions have to arrive in one entry, so
   `undefined_message` offers the entry back to keep editing (Escape
   drops it). `submit` therefore returns a refusal rather than reporting
   it, and `accept` is for callers with nothing better to do with one.
   Whether an entry is finished is the *parser's* answer, not a guess
   from a trailing `:` — in two parts, both asked of the parse rather
   than of the text: `complete` (`INCOMPLETE`, "did the input run
   out?") and `continuable` ("could the next line extend this?", true of
   an `if` with no `else`, since a block written on its header's own
   line parses whole while still being open and its `else` must start
   the next line). A single line submits on Enter only when it is
   complete and not continuable.
   `start(format_error, ...)`
   takes the driver's own error formatting so a mistake at the prompt is
   reported in the words a file would get. Meta-commands are an
   association list of `(session, argument, report) -> outcome`; add one
   there rather than in the loop. An `outcome` carries the session and
   the text to put back in the prompt, which is empty for every command
   but `:edit`.

   **`Editor`** is a small multi-line editor over a terminal in raw mode,
   used when there is a terminal and skipped for piped input, which takes
   a plain line-reading path (`make_reader`). It exists because a
   line-at-a-time history makes recalling a five-line `def`
   is impossible with it: here the buffer is an immutable
   `buffer_ = { lines; row; col }` with pure operations over it, history holds
   whole *entries*, Up and Down move within the entry and then into
   history, Escape abandons what is being typed, Enter opens a new line
   -- already indented, one level in after a line ending in `:` -- until
   a blank line ends the block, and Backspace inside a line's indentation
   removes a whole level rather than one space. `read(initial)` is how
   text that was not typed there arrives: an entry handed back to be
   finished, or what `:edit` brought up. Keep the buffer operations pure
   and the terminal in the class: that split is what makes the editing
   testable without a tty.

17. **`src/execution.ml`** — what `--run` runs: one table saying which
   commands each target's host uses to build and run what `pyk compile`
   wrote (`node prog.js`; `cc -std=c89 -o prog prog.c` and then `prog`;
   `xdg-open` for `html`, which is a page; this compiler again for
   `pyking`, since what runs Pyking is the interpreter). `plan_for`
   answers with a `Plan` — build commands, the run command, and the
   directory they run in, all absolute — and `execute` runs them,
   printing each first on **stderr** so the program's own stdout stays
   its own. `$CC`/`$JAVAC`/`$JAVA`/`$OCAMLOPT` name the tools, the same
   variables the test harness reads. Adding a target means adding its
   row here as well as its extension in `pyk.ml`.

18. **`src/pyk.ml`** — the entry point (formerly `pykboot.py`): parses a
   command and the flags `--tokens`/`--symbols`/`--run`/
   `--stdout`/`--output|-o <file>`/`--target|-t <target>` from argv into
   an `Options` value, runs `lexer.lexing`, `parser.parse`,
   `analyses.symbolize`, `typesystem.type_check` and
   `analyses.analyze_mutability`, and then dispatches. A program of
   several modules runs the middle of that once per module, in the order
   `module.load` gives: check against the signatures of the ones it
   imports, then take its own signature for the next one. Three commands:
   `pyk <file>` interprets it; `pyk repl` starts the REPL; `pyk compile`
   (alias `pyk c`) compiles, which is what every flag above is for.
   Flags are shared by all three rather than per-command, so `--tokens`
   means the same thing wherever it is written.
   Errors: `ERROR_KINDS` pairs each front-end exception with its label,
   and `format_error` turns any of them into one
   `'file' row:col-row:col Kind: message` line (`Lexing error` /
   `Parsing error` / `Module error` / `Name error` / `Type error` /
   `Runtime error`);
   a backend's `Unsupported` is reported separately, since its
   message names the target that refused it. `repl.ml` is handed
   `format_error` itself, which is why `command_repl` imports it lazily —
   at the top it would be an import cycle. Every message goes through
   `wrap`, which reflows to 70 columns. There is one branch in
   `front_end`, and it is `--no-typechecking`'s: otherwise every module
   of the program is lexed, parsed, symbolized, type-checked and
   mutability-checked, and a refusal at any step is an error. The
   checker is the only pass that checks names — its environment *is* a
   scope, so it raises `Analyses.Analysis_error` for one it cannot find,
   and the driver prints `Name error` for it. `analyze_mutability` runs
   after it, which is what lets it say "not a mutable variable" rather
   than "unbound". `symbolize` runs before both, since `tmap` and the
   interpreter's call-free table are keyed by symbol; nothing
   needs symbolizing again afterwards, because the checker synthesizes
   nothing into the tree. The `tmap` is handed to `pprint_program`, so
   `-t pyking` prints inferred types rather than written
   ones. Every flag has a default: `--target` is `python`, and with no
   `--stdout`/`--output` the program is compiled to a file named
   from the source stem and the target's extension — except the Java
   targets, where the driver instead calls
   `target_java.default_class_name(stem)`, since Java requires the file
   and its public class to match and the source's own spelling usually
   isn't a legal, correctly-cased class name. A module the program
   imports is written *beside* the program's own output under its own
   name and the target's extension, by the same rule -- which is also
   the name the generated import in that output uses, so the two agree
   by construction. `-t pyking` prints the
   *Pyking* AST via `syntax.pprint_program`, before `apply_signatures`
   folds a `def name : type` line onto its header, since that AST is what
   every backend and the interpreter share. `--run` hands the compiled
   output to `src/execution.ml`, which owns each target's build and run
   commands, and the ordered list of the program's other files, which
   the targets that *link* a program need. Keep the driver thin: it
   sequences stages and reports errors, and each backend
   owns its own translation, packaging, and file naming (`esm` writing
   three files is `target_js_packaging`'s business, not the
   driver's; deriving a Java class name from an explicit `--output` is
   `target_java.ml`'s, by the same principle). What a backend needs to
   know about the module it is compiling *as part of a program* arrives
   as one `module.Context`, not as a growing list of parameters.

When extending the lexer (new operators, keywords, string escapes, etc.),
follow the existing pattern: add an arm to the `match rest with`
inside `lexing`, add a corresponding `Tok*` constructor, and add an arm
to `pprint_token` — and to `token_info`, which every arm has to cover.
The compiler catches the last two if you forget them. `TokArrow` (`->`, in a function
type) shows the three edits together, and is a reminder that a token
used only in *types* still needs all three, and that
`tools/emacs/pyking-mode.el` has to be checked even when the answer
turns out to be "nothing to do" (it highlights no operators, so `->`
needed none).

## The alternative type checker

`src/type_experiment.ml` is a second checker, a fragment of one, run
instead of `typesystem.ml` by `pyk --type-experiment`. It covers integer
literals, names, `+`, and the `x = e` and expression statements those
need. Everything else raises `Construct is not supported`, in
`typesystem.ml`'s own words, and an unbound name raises
`Analysis_error` so it is reported as a `Name error` exactly as there.

It is there to be grown, and the flag is how it is run. Its shape is
`typesystem.ml`'s and is the one to keep as it grows -- one function per
AST datatype, an `env` used immutably, and one symbol -> type table
returned as the pass's result. `pyk.ml`'s `format_error` has a line for
its `Type_error` saying the same word as the real checker's: the flag
swaps which checker runs, not how a refusal reads.

## The browser build

`src/web/` compiles the same library to JavaScript with js_of_ocaml, for
`tools/playground/`. Two files: `pyking_web.ml`, which registers
`pykCompile`, `pykRun`, `pykTargets`, `pykFormatHelper`, `pykKeywords`
and `pykBuiltins` on the global object, and `stub.js`, the four
`//Provides:` primitives that let it. Nothing in it is compiler logic —
every entry goes through the same functions `pyk.ml` calls, and reports
a refusal with the same `format_error`.

Two rules follow from it and are easy to break:

- **The library must stay dependency-free.** Nothing in `src/`'s library
  half may open a file, start a process, read a terminal or link `unix`;
  that is why `pyk.ml`, `execution.ml` and `repl.ml` are in the
  executable instead. A `Unix.` call added to a library module breaks
  the playground, not the compiler, so nothing local will tell you.
- **js_of_ocaml's `int` is 32 bits**, where a native one is 63. Anything
  that depends on the width has to say so explicitly:
  `interpreter.wrap32` goes through `Int32` for exactly that reason.

`docs/build.md` is the long form, and `tools/playground/README.md`
covers what the page does with the bundle.

## Running

```
pyk [options] <filename>          run it with the interpreter
pyk repl                          start the REPL
pyk compile [options] <filename>  compile it (alias: pyk c)

options: [--tokens] [--symbols] [--no-tail-call-opt]
         [--no-typechecking] [--type-experiment] [--run]
         [--target|-t <target>]
         [--stdout | --output|-o <file>]
```

`pyk --help` prints the long help: the short one that a bare `pyk`
prints stops at the flags that change what is *produced*, and
`--symbols`, `--tokens`, `--no-tail-call-opt`, `--no-typechecking` and
`--type-experiment` are documented only in the long form, since none of
them is needed to use the compiler. Keep that split when adding a flag.

(`./pyk` at the repository root is the compiled executable itself: `make`
runs `dune build src/pyk.exe` and copies it there. It is a build
artifact, not a checked-in script, and `make clean` removes it. Run it
with no arguments for the usage message, which is generated from
`targets`/`extensions` and reflowed to 70 columns by `wrap`, along with
every error the driver prints.)

`pyk <file>` and `pyk repl` both run a program with
`src/interpreter.ml`, on Pyking's own semantics (32-bit `Int`, Pyking
runtime errors with a stack trace). The third way to run one is
`pyk compile --run`, which builds what was compiled and runs it with
that target's own commands — and so shows a *backend's* semantics.
Where the two disagree, the interpreter is the reference and the
backend is the bug.

**Pyking is statically typed**: every program is type-checked, whatever
is then done with it, and there is no flag for it.

`--no-typechecking` is not one either, and is not for compiling with:
it is a debugging flag, for seeing what the front end built before
anything reasoned about it. It stops `front_end` after `symbolize`
-- no checker, and so no mutability analysis and no tail-call pass,
since neither runs without what the checker works out -- and `tmap` is
then `None`, so `-t pyking` prints the program as *written*, with the
source's own annotations. It stops *before* the module system too, and
for the same reason: the file named is the only one read
(`module.read_file`), so nothing it imports is opened and nothing about
what it exports is checked. `parse_args` refuses it anywhere but
`compile -t pyking`: every other target reads the types (the Python
backend to know what to format, the OCaml one for every type it emits)
and so does the interpreter, so allowing it there would produce nonsense
rather than a view of the parse.

`--type-experiment` is the other debugging flag: it runs
`src/type_experiment.ml` in place of `src/typesystem.ml`. That checker
is a fragment, so most programs are refused with
`Construct is not supported` — which is the point, since it exists to be
grown against real programs. See "The alternative type checker" above.

Flags are accepted by every command rather than being per-command, so
`--tokens` and `--symbols` mean the same thing wherever they are
written. `--tokens` prints the token stream first (in addition to
whatever else happens); `--symbols` adds each node's symbol as an `@n`
suffix to what `-t pyking` prints. The other three select what
`pyk compile` does, and none of them is required:

- `--run` builds and runs what was compiled, with the commands that
  target's host uses (`src/execution.ml`), each printed before it runs
  on stderr. Cannot be combined with `--stdout`, which writes no file.
- `--stdout` compiles and prints the generated source. For `esm`, whose
  wrappers only exist as files, this prints the module alone.
- `--output <file>` compiles and writes to `<file>`. A single-file target
  writes exactly that path; `esm` reads it as a *stem* and names its own
  files, so `--output out/prog`, `out/prog.js` and `out/prog.html` all
  produce `out/prog.js` (module), `out/prog.node.js` (driver),
  `out/prog.html`, and `out/package.json` (`{"type": "module"}`, which is
  what lets the first two be plain `.js`). An existing `package.json` is
  never overwritten — it belongs to the surrounding project.
- A module the program imports is written beside the program's own
  output, under its own name and the target's extension -- which is also
  what the generated import in that output names it by. C and OCaml
  write a companion beside each (`helper.h`, `helper.mli`); `html` is
  the exception and writes none, since a page is one file and every
  module becomes a block of it.
- With neither of the two above, the compiler names the file: the source's own stem
  plus the target's extension (`extensions` in `pyk.ml`, fed by each
  backend), in the *current* directory — `-t nodejs tests/hello.pyk`
  writes `./hello.js`. Writing over the input, or into a directory that
  doesn't exist, is a usage error rather than a traceback, checked per
  file since `esm` writes three. The Java targets are the exception: the
  default name is Java-cased instead of the source's own stem, since Java
  requires the file and its public class to match exactly — `-t java21
  tests/foo_bar.pyk` writes `./FooBar.java`, not `./foo_bar.java`.

`--target`/`-t` selects the backend: `python` (the default), `nodejs`,
`html`, `esm`, `c89`, `c23`, `java8`, `java17`, `java21`, `ocaml`, or
`pyking`. The last is the odd one: it compiles Pyking to Pyking, which
is to say it prints the program the front end worked out — with the
types the checker inferred and the loops the tail-call pass built — and
so supports everything, because it *is* the shared AST rather than a
translation of it. `--symbols` goes with it, and nothing else does.
The rest come in groups sharing a backend: the JavaScript three differ
only in `src/target_js_packaging.ml`, the C two only in a `standard`
parameter to `src/target_c.ml`'s printer, and the Java three only in a
`version` parameter to `src/target_java.ml`'s printer; `ocaml` is a
family of one. All of them support a subset of the language, and
anything outside it is refused at compile time with a source position
rather than emitted as code that will not build. `ocaml` is the one
whose subset is not a list it maintains: it is whatever
`src/typesystem.ml` accepts, checked by running it. See
`docs/architecture.md` for the subsets and the target table.

`pyk <file>` and `pyk repl` take no target: the interpreter emits
nothing to name. What they accept is `src/typesystem.ml`'s fragment,
checked by running it — the same arrangement `ocaml` uses, and the
reason a program with `for`, `while`, `match`, lists or an unannotated
`def` is refused there with the checker's own message. A `loop`, a
tuple, a `var` and a `:=` are all inside that fragment.

Plain `make` builds the compiler: the `Makefile`'s first rule, `all`, is
`build`, since that is what someone typing `make` in a compiler's
directory is asking for. It runs `dune build src/pyk.exe` and copies the
executable to `./pyk`. `make help` prints the list of targets, which is
hand-written, as is the one in `tools/playground/Makefile` it is
modelled on — add a target and you have to add its line too.

`make clean` removes `_build/`, `./pyk` and `__pycache__` directories,
and delegates the playground's `build/` to that directory's own
Makefile; `make distclean` also drops its `vendor/` download cache.
Neither touches *compiled programs*: `pyk` writes them wherever the
caller asked, under names indistinguishable from hand-written source in
every target language, so a clean rule that guessed at them would
eventually delete someone's own file. Keep it that way. `./pyk` is the
exception that shows the rule -- `make build` chose that name itself,
which is the whole of why removing it is safe.

`make test` runs `tests/test_script.py`. It
reads `tests/test_cases.toml`, and for every (program, target) pair the
manifest declares, compiles the program to a temp directory, runs it the
way a user would — `python3` on the `.py`, `node` on the `.js`, `node` on
the *generated driver* for `esm`, `cc`/`javac`/`ocamlopt` and
then the binary for the C, Java and OCaml targets, and, for `html`, the
page's extracted module under a small `document` stub — and compares
stdout against the sibling `.out` file. `interpret` is the one that
compiles nothing: it runs `pyk <program>` and compares that. One
`.out` serves every target, which is the property being tested — and the
reason the interpreter is cheap to trust, since it is a second definition
of the language's semantics held to the files the nine backends are held
to. It warns about any `.pyk` missing from the manifest and prints a
per-target summary.

A program that imports lists the modules it imports under `modules`, in
dependency order. The compiler writes them into the same temp directory,
beside the program's own output; the C, Java and OCaml runners then have
to name them in that order to build the program at all, which is what
the manifest's order is for. A module listed there is not a case of its
own -- it is not a program -- but it is still accounted for, so the
"not listed in the manifest" warning stays honest.

Those (program, target) pairs are independent — each compiles into a
temporary directory of its own, and nothing is written back into the
repository — so `make test` runs them in a thread pool, one job per
usable CPU (`os.sched_getaffinity`, so it sees what a VM actually has;
`make test JOBS=n` or `$PYK_TEST_JOBS` says otherwise). `make stest` is
the same suite with `--jobs 1`. **The two print the same transcript**:
results are held back and reported in the order the manifest lists them
whatever order they finished in, so a parallel run stays diffable
against a serial one. Keep it that way — a new runner belongs in
`RUNNERS` like the others, writing only into the `workdir` it is handed.

`tests/test_script.py` takes `--compiler CMD` if you need to run the
suite against something other than `./pyk`; it defaults to that, which
is what `make test` builds first.

**`tests/test_repl.py` is the second suite**, run by `make test` after
the first, and it covers what the first cannot reach: the `.pyk` suite
compiles *files*, so nothing in it enters the REPL. A case is
`tests/repl/<name>.repl` -- what is typed at the prompt -- with
`<name>.out` holding the session's output, stderr merged into stdout in
the order the two were written, since a refusal and a value are both
part of what a session said. Piped input takes `repl.ml`'s plain reader
rather than the terminal editor, so a case exercises the *session* --
how an entry is checked against the ones before it, what a value prints
as, what each meta-command answers -- and not the keystroke handling;
history, cursor movement and Escape are still untested. Add a case here
when changing anything about what the prompt prints. It takes
`--compiler CMD` like the other one.

**Four kinds of expected output**, two of them about the tail-call
pass. `<name>.notail.ast.out` is what `-t pyking --no-tail-call-opt`
prints -- the program as *written*, where `.ast.out`
shows what the pass built -- and `<name>.notail.out` is what it prints
when run with the pass off, which must equal `<name>.out` exactly: the
pass may change how much room a program needs and never what it means.
The targets that read them are `pyking_notail` and `python_notail`.
A program the pass *declines* to rewrite has the same text in both
`.ast.out` files, which is what being declined looks like from here.

`<name>.out` is what the program *prints*, and every backend is compared
against that one file. `<name>.ast.out` is what
`pyk compile -t pyking --stdout` prints for it — the program with the
types the checker inferred — and only the `pyking` target reads it. Keep
the distinction: a `.out` is never an AST.

`pyking` and `interpret` are targets in that list but not backends:
neither generates code for a host. `interpret` *runs* the program, so it
takes an ordinary `.out`, and **every program that runs at all lists
it**, since every program is type-checked; the harness warns about one
that does not. `pyking` runs nothing, and two filename prefixes say what
to expect of it:

- **`typecheck_*.pyk`** must type-check, and its `.ast.out` holds the
  *printed AST*, pinning the types inferred. It **also lists real
  backends, and `interpret`**, so the program whose types are pinned is
  one that actually compiles, runs, and means the same thing under the
  interpreter; its `.out` is that run's output, empty if it prints
  nothing. The harness warns if such a file lists no backend, because a
  type nobody executes is a type nobody has tested.
- **`fail_typecheck_*.pyk`** must **not** type-check, and its
  `.ast.out` holds the *error message* — a `Type error`, a `Name error`
  for the two mutability rules, or a `Module error` or `Parsing error`
  for the module system's own refusals. It lists exactly
  `targets = ["pyking"]`: a program written to be refused is not one
  to run.

Three families apply those two conventions to **inference**, and they
are the only tests where the printed AST differs from the source in the
interesting way — so regenerate them deliberately rather than by habit
when a message changes.

- **`typecheck_hm_*`** and **`fail_typecheck_hm_*`** are the direct
  test of `docs/type_inference.md`: programs whose *principal* types are
  pinned, one per property the inference guarantees (application,
  composition, `let`-polymorphism, what may not be generalised, mutual
  recursion, the order of callers not mattering, annotated rank-2), and
  four that pin what is refused — the occurs check both ways, a
  parameter used at two types, and an inferred type being enforced like
  a written one.
- **`typecheck_infer_*`** and **`fail_typecheck_infer_*`** are the
  older set covering the same ground more narrowly.
- **`typecheck_noann_*`** is each annotated `typecheck_*` program with
  every annotation taken off, sharing its `.out` unchanged — the
  standing check that an annotation says what a program means to a
  reader and to the checker, never what it does.

A fourth family covers the **module system**: `module_*` for what each
import form and each `public` does, one file per form plus the modules
it imports (`module_qualified.pyk` and `module_qualified_mod1.pyk`), and
`fail_typecheck_module_*` for what is refused — a cycle, a private name,
a collision, an import inside a block, a `public var`, a name exported
twice, and an unannotated export nothing in its module calls. `typecheck_module_public.pyk` is the one that pins the
printed AST, since it is the only place `import`, `from`, `as` and
`public` are printed back out at all.

Together they pin down both halves of the checker — what it infers, and
what it rejects and how it says so — while the backends keep the
programs honest. Adding a runnable target to a `typecheck_*` file is how
several backend bugs surfaced: a Java method name emitted as a value, a
Pyking expression statement emitted as a Java one, and calls to `str`,
`range` and `len` emitted as JavaScript that would not run.

**Every runner checks the exit status** (`executed` in the harness). A
program that prints and *then* dies leaves its prefix on stdout, so
comparing output alone would call a crash a pass whenever the surviving
prefix happened to match.

**No third-party dependencies.** Building the compiler needs OCaml and
dune; the playground's bundle additionally needs js_of_ocaml. The test
harness and the playground generator are Python 3.11+ (`match`/`case`,
and `tomllib` for the manifest) — tooling around the compiler, not part
of it.

Running the generated code needs `node` for
the JavaScript targets, a C compiler (`$CC`, default `cc`) for the C
ones, a JDK (`$JAVAC`/`$JAVA`) for the Java ones and an OCaml compiler
(`$OCAMLOPT`, default `ocamlopt`) for `ocaml` — none of them
is needed to *produce* the code, and none at all to run a program with
`pyk <file>`. The OCaml cases are built with `-w +a`: that target's
promise is clean OCaml, so a warning about generated code fails the
test. (That is the *generated* OCaml. The compiler's own build sets
`-warn-error -a`, so a warning there does not fail a build.)

## Where the project is going

**`design/plan-eval-lsp.md`** is the plan for an interpreter, a REPL,
step debugging in the playground, and LSP and DAP servers with editor
integration. **The first two are built** — `src/interpreter.ml` and
`src/repl.ml`, reached as `pyk <file>` and `pyk repl`, with `interpret` a
target in the test manifest — and the rest is not. Read it before adding
anything in that direction; it settles several things by design rather
than by accident:

- the evaluator is a **resumable machine over the AST** in `src/`, not a
  second compilation to a host language and not (yet) a bytecode VM;
- **one debug session core and one query core, both protocol-free**, so
  DAP and the playground are two transports over one session, and LSP
  and in-browser editor help are two transports over one query service;
- the servers **reuse `src/`**, with thin per-editor shims, since the
  browser already runs the same library compiled to JavaScript;
- **four new modules in `src/`**, with name resolution folded into
  `analyses.ml` and the `Host` interface into `runtime_interface.ml`;
- what the machine may assume about its host, so none of it blocks the
  eventual self-hosted, machine-code Pyking.

Where what was built differs from the plan, and why:

- The plan calls the module `interp`; it is **`interpreter.ml`**, and
  the REPL is **`repl.ml`** as planned.
- The plan's `resolve` module (name resolution producing slot indices)
  was **not** written. The interpreter's environments are chains of small
  frames rather than slot-indexed arrays, which is the same semantics and
  a slower lookup; the one thing it was to provide that is
  actually used — "does this subtree contain a call?" — is computed
  locally by `call_free_symbols`. Writing `resolve.ml` later is still the
  right move, for LSP as much as for speed, and the interpreter's
  environments are the thing it would change.
- The plan's `Host` interface was to live in `runtime_interface.ml`; it
  is in `interpreter.ml`, so that module keeps its rule of holding no host
  code at all. The *operations* and their formatting rules stay where
  they were.
- The plan assumes the browser reaches the compiler through Pyodide.
  It does not any more: `src/web/` compiles the library itself to
  JavaScript with js_of_ocaml, so there is no Python runtime in the
  page. The plan's own table called that the eventual state; it arrived
  with the translation instead.
- `Diagnostic` values and parser error recovery (§5b) are not built.
  Errors are still one exception per stage carrying an `info`, and
  `pyk.ml`'s `format_error` is the one place they are worded.

Two language questions it raises are settled: an **`Int` is 32-bit and
wraps** (PYKING.md, "Integer and string literals"; the backends that
differ are listed in `docs/targets.md`), and the **maximum call depth is
10 000** (`interpreter.max_call_depth`), raising a Pyking error rather
than exhausting memory.

## User-authored documentation

Existing comments and docstrings are considered protected user-authored text.

Allowed:

* Fix obvious typos.
* Fix grammatical errors that are clearly errors.
* Fix factual/terminological inconsistencies when the intended wording is unambiguous.
* Update a reference when the referenced code/API was changed and the correction is mechanical.
* If claude is creating a new function, add documentation as described below

Not allowed:

* Rephrase sentences for better style.
* Make documentation "clearer", "more concise", or "more professional".
* Change the author's terminology or voice.
* Add explanations that were not present.
* Remove information because it seems redundant.
* Rewrite a docstring merely because the implementation changed.


If a change requires interpretation or rewriting rather than a mechanical correction, leave the documentation unchanged and ask me.

## Documentation style

Applies to every `.ml` file under `src/`, every `.py` file under
`tools/`, and the `.md` files under `docs/`. Plain, direct, technical.
No jargon, no rhetorical flourishes, no filler words.

**Module docstring** (an `(** ... *)` at the top of the file): what the
file is for, in a few
sentences. No design rationale, no history of alternatives considered.
Link to the `docs/*.md` page(s) that cover the design. End with two short
lists: the data structures defined in the file, and the functions,
each as one line naming it and saying what it does. Example:

```ocaml
(** Recursive-descent parser: tokens (from lexer.ml) to the AST defined
    in syntax.ml. Also enforces the handful of grammar rules that cannot
    be expressed in EBNF (see docs/architecture.md).

    Data structures:
      Parse_error -- a parse failure, with the source position.

    Functions:
      parse tokens -- parses a full token stream into a list of statements.
      parse_expr eof tokens -- parses one expression.
      parse_block eof tokens colon -- parses one block. *)
```

**Function docstrings**: two parts, nothing else.

The following holds for new functions. I may have modified it in a 
different style, so do not change existing text, as described above.

1. One or two sentences: what the function does.
2. A type signature, written the way the AST's own comments write one,
   e.g. `[token] -> (expr, [token])` or `env -> String -> typ -> env`
   (`[T]` for a list, `T?` for an option, `(A, B)` for a pair). It is
   written out even though OCaml infers it, because the inferred one is
   not always the one worth reading.

```ocaml
(** Parses one expression. info -> [token] -> (expr, [token]) *)
let parse_expr eof tokens = ...
```

No worked examples, no "why" in a function docstring. If a function's
behavior needs more than the two parts above to explain, that is a sign
the explanation belongs in `docs/`, not that the docstring should be
longer.

**Data structures**: describe precisely, not narratively — the type
declaration at the top of `syntax.ml` is the model. The type says the
fields; a one-line trailing comment per variant, saying what it is
written as in source or what it stands for, is enough.

**Everything else — why a design was chosen, what alternatives were
rejected, how a bug happened, how pieces fit together — belongs in
`docs/*.md`, never in a docstring or inline comment.** A code comment may
state a non-obvious invariant in one line; it does not tell a story.

`docs/*.md` files keep their existing structure and content. When editing
them, tighten the prose to this same standard: state the fact, drop the
rest.

## Repository housekeeping

- **Never create a git branch.** Work on whatever branch is already
  checked out, and leave the changes in the working tree; branching and
  committing are mine to do. This holds however large the change is —
  a rewrite of a whole module is still a working-tree change.
- Editor backup files ending in `~` (e.g. `tests/arithmetic.py~`,
  `.gitignore~`) or in `#...#` (Emacs auto-save), and any `__pycache__`
  directory, are untracked scratch content, wherever they turn up (`src/`
  included) — don't treat them as authoritative source, and don't assume
  they should be committed.
