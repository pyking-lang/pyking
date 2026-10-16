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
  `--run` and the terminal handling the REPL need, and `dynlink`, for
  the interpreter's plugins (`src/plugin_host.ml`, with the one module a
  plugin names in a library of its own, `src/plugin/`). `docs/build.md`
  is the long form. The eventual self-hosted rewrite — the compiler written
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
   `analyses.ml`'s `analyze_mutability` → `opt_tailcall.ml` → each
   backend). `module.ml` needs nothing for an ordinary construct: it
   reads statements only to find imports and `public`s.
   `opt_tailcall.ml` usually needs nothing: it rewrites tail calls and
   passes everything else through. A construct that can *hold* a tail
   position -- a new branching statement, say -- does need a case there,
   or a tail call written inside it is silently left as a call. A new AST
   node needs a case in `analyses.ml`'s `symbolize` and one in
   `walk.ml`'s `children`, and neither is caught by the compiler in a way
   you would notice: `symbolize` would leave the node at symbol `0`, and
   `children` would leave every whole-subtree question blind to it. Every
   *other* `match` over the AST the compiler does catch, which is the
   whole reason the AST is a variant type -- `release.ml`'s rewrite
   among them, which a construct holding an expression or a block needs
   a case in so a `debug` inside it is removed. `typesystem.ml` does need a
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
   group, the rest sharing its line by construction. A `def` header
   with no body that ends its line -- every parameter typed, none with a
   default, the result written -- is a signature line (`SFunctionSig`),
   its parameter names dropped: `def write(text: String) -> ()` is `def
   write : (String) -> ()`, which is how `lib/`'s declarations name their
   parameters. A qualified name
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
   only the stages after that need.

   **External modules** are here too, and **a module is up to two
   files**: `sys.pyk` and `sys_external.pyk` are one module `sys`, the
   first written in Pyking against what the second declares. Either may
   stand alone. `module_file` answers with whichever halves a level
   holds -- both always come from one place -- and `read_module` keeps
   them in separate fields, `stmts` and `declarations`, because
   `apply_signatures` deletes every signature it cannot fold onto a
   definition and would empty a declaration joined into one list.
   `is_external` now means "no Pyking half".

   `check_declaration` refuses anything but a signature, public or not:
   a **private** declaration is in scope in the module's own Pyking half
   and nowhere else, which is how a library keeps a host function it
   does not offer. `check_boundary_type` applies to every declaration,
   since what crosses the boundary is the call the Pyking half makes.
   `check_publics` runs over the union, so `public` means one thing
   across both files and a name in both halves is refused.
   `implementation_name` says what the implementation is called on each
   target -- always `<module>_external.<ext>`, because `sys.js` is the
   file generated from `sys.pyk` -- and `implementation_path` checks it
   exists. JavaScript runs in two environments, so a module has one
   implementation for each, **`<module>_external_node.js`** for `node24`
   and **`<module>_external_browser.js`** for `web24` and `iweb24` --
   except that `iweb24` takes **`<module>_external_interpreter.js`**
   where a library has one, as tinyweb does -- and each is copied out as
   `<module>_external.js`. A file named
   `<name>_external.pyk` is always a module's external half, so a name
   ending in `_external` cannot be imported (`refuse_external_half`).
   `found_implementation` finds a module's implementation the way an
   import would find the module, which is how a browser page ships `io`
   for `print` when the program imports nothing. `external_sigmap` is a
   declaration half's *public* names, and `module_sigmap` is both halves
   together. `Context.own_declared` is the module's own declarations with
   their types, private ones included, which C and Java need to call
   their own declaration half.

   **`reached_module` is the one place a backend asks which half
   provides a name**, so none of them decides for itself: `foo.g1`
   reaches `foo_external` where `g1` is declared and `foo` where it is
   written in Pyking, and the generated file imports the implementation
   too, which is what lets the Pyking half call a private declaration.
   C is the exception -- a name there is `<module>_<field>` whichever
   half provides it. C and Java both compile a module in two halves: the
   generated file declares (C) or reaches through the implementation's
   class (Java) the names its own declaration half provides. `pyk.ml`
   copies the implementation beside the program's output for any module
   with a declaration half, skipping a copy onto itself, and a module
   contributes *two* files to every file list, implementation first. See
   `docs/modules.md`, "External modules". The playground's Compile
   compiles a file with no program around it: it runs `check_publics`
   (it needs only the file) and lets `typesystem.available` refuse an
   import (it needs the program), and offers neither a program that
   imports nor a module it imports as an example. The REPL and the
   browser's Run are programs: **`load_imports`** reads the modules an
   entry at the prompt newly reaches, prepared the way `load` prepares a
   program's (both through `prepare`), and the browser reads the
   standard library through the page. See `docs/modules.md`.
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
   anything. The builtins are
   `builtin.ml`'s rather than this module's: `Builtin.names` seeds the
   starting environment here, as it does in `typesystem.ml` and
   `interpreter.ml` — add a builtin to that table.
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
   plus the folds built on it (`fold`, `exists`, `fold_stmts`,
   `exists_stmts`, `name_field`). Every pass that asks a question of a whole subtree —
   `effects` here, the interpreter's call-free table, the C and Java
   backends' "is this name used as a string" — goes through it rather
   than writing its own descent. **A node added to `syntax.ml` needs a
   case in `children`**, and nothing but a pass that would have looked
   inside it will notice if it is missed.
6. **`src/opt_tailcall.ml`** — tail calls into loops, one pass from the
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
   `NATIVE_TAIL_CALLS` list (today just `ocaml5.5`), and that target is
   then compiled from the program *as written* -- because a `loop`
   becomes a local recursive function on that backend, so the pass and
   the backend would otherwise undo each other and leave a
   tag-dispatched worker where `let rec ... and ...` belonged. The one thing it cannot always make
   work is a merged group whose functions disagree about their parameter
   *types*, which only the checker can see; `docs/optimization.md` is
   the long form, including that case and the `fail_tco_*` tests that
   pin it.

   Two more passes of the same kind sit beside it. **`src/release.ml`**
   is `--release`: every call to the builtin `debug` removed, arguments
   and all, after `elaborate.ml` and before this pass, for every module
   -- one in value position becomes `()`, and one written as a statement
   is dropped wherever that leaves its block's value as it was, and is
   otherwise the statement `()`, which every backend compiles to nothing
   (C and Java emit no statement for it). The builtin is told from a
   program's own `debug` by `tmap`: the checker records a type for a
   callee it resolved to a definition and none for a builtin. See
   `docs/release.md`. **`src/prune.ml`** is what a program uses of the
   modules it imports, run by `pyk.ml` for the C and Java targets only:
   every module but the program's own loses the definitions nothing
   reaches, and every import is narrowed to the names used -- so a
   library's function nobody calls, `sys.env_get` walking a list, does
   not keep `sys.exit` out of C. See `docs/modules.md`, "What a program
   uses". The browser bundle's `pykAnalyze` reads the same narrowed
   imports.
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
   direction is `check_exports`, run at the end: an exported name
   carries its complete type in the source -- a public `def` annotates
   every parameter and its return type or has a signature line of its
   own, and a public `=` binding annotates its name -- and anything
   less is **refused**, since a call in the module settles what this
   module needs rather than promising anything to another one. See
   PYKING.md, "What a module may export". `interpreter.ml` defines its coverage as
   "whatever this accepts", so widening the checker widens it, and it
   needs the corresponding `case` or an explicit refusal.
   `target_ocaml.ml` used to say the same and no longer can: it accepts
   nearly all of the checker's fragment and keeps a short list of
   refusals of its own, for shapes OCaml cannot be given (see
   `docs/target_ocaml.md`, "What is not supported").

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
   shadowing, a `def`'s name in its own body, and `Builtin.names`
   (read, not re-listed) in scope from the start. An unbound name
   raises `Analyses.Analysis_error`, in its words, so the message does not
   depend on which pass ran. **The value type is `Type`, with no option
   and no second inhabitant**: a name is in the map with a type, or it is
   not in scope, and there is no third state to ask about. A builtin is
   in it like anything else, at a type of its own: `env` maps every
   builtin to a `TBuiltin`, checked at the call by
   `check_builtin_call` and refused as a value, because none of them
   fits a `TFunction` (a variadic `print` is not a `(T) -> ()`) and
   `builtin.ml` records them as builtins rather than functions. A
   new builtin needs a case in `check_builtin_call` as well as an entry
   in `builtin.ml`'s table. **The operator table** (`operator_of`) is
   the other thing to know here: each operator is a list of
   `(operand kind, result kind)` rows, and `operator_result` decides
   between them in three cases -- a settled operand, several rows
   agreeing on the result (`==` and the orderings, which leave the
   operand open), and several rows disagreeing, where the **first row
   wins** and an undecided `+ - * /` is therefore Int arithmetic. See
   `docs/type_inference.md`, "Two numeric types, no type classes".
   **`var` and `:=` are checked here**, and only
   for *types*: a `var` is `Int`, `Float` or `Bool` (`check_mutable`), and a `:=`
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
     *failure* is how the overloaded names are handled at all. The
     builtins `string`, `len`, `int`, `float` and `bool` and the
     operators `==` and `++` each accept several types and no one type,
     so
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

8. **`src/builtin.ml`** — the builtins: the names a Pyking program may
   call without binding them (`print`, `debug`, `range`, `string`, `len`,
   `int`, `float`, `bool`), and what
   every stage has to agree about each one — its arity, whether calling
   it can be observed outside the program (`crosses_host`), and what it
   does. **`debug`** is `print`'s twin, writing to standard error where
   the host has one (`is_debug` says which of the two a call is), and
   the builtin `--release` removes; every backend checks that a call
   named `print` or `debug` reaches the builtin rather than a program's
   own definition of that name. The conversions **`string`**, **`int`**,
   **`float`** and **`bool`** answer a default where there is no right
   answer (0, NaN, false) -- a stand-in for the option type they will
   answer once Pyking has one -- and the rules for reading a String and
   truncating a Float are here (`parse_int`, `parse_float`,
   `truncate_float`, signed 32-bit), since no host's own parser reads
   the same strings: every backend checks the text itself, in a helper
   it emits only where one is used. One table, read by the checker, the interpreter and every
   backend, which is why it sits before `analyses.ml` in the module
   graph. Backend-agnostic by construction: it holds no Python and no
   JavaScript, and the value-formatting rules are stated here too, since
   every backend has to agree on those for one program to print the same
   characters everywhere. What is *not* here is which argument types a
   builtin accepts (`typesystem.ml`'s, since those are settled by
   unification rather than comparison) and what a builtin computes
   (`interpreter.ml`'s, which needs a `value`). Add a builtin here
   first; the checker, the interpreter and each backend then bind it.
9. **`src/target_js_core.ml`** — the JavaScript backend's language half:
   a `Js*` AST, translation from `syntax.ml`, and a printer. Knows nothing
   about packaging. Calls that cross the host boundary become
   `JsRuntimeCall`, whose spelling is supplied by the packager, so the
   same core output serves all three JS targets. It takes the checker's
   `tmap` for one reason: a JavaScript number is one type, so nothing at
   run time separates an `Int` from a `Float`, and only the type can say
   how a printed value is written (`printed_argument`; see
   `docs/target_js.md`, "Floats"). Nothing else in the translation reads
   it, and a program with no Float compiles to what it did before. JavaScript fits Pyking
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
   half: wraps core output into `node24` (one self-contained script),
   `web24` (the same modules plus an HTML file that loads them) and
   `iweb24` (which compiles nothing: the page ships the Pyking source
   and the interpreter). `node24` and `web24` emit *identical*
   JavaScript for a program's own modules, so the differences between
   them are the extra page and where `print` goes. It owns the
   JavaScript side of the runtime interface: `pyk-runtime.js`, holding
   `print`, `debug` and the shared `pykFormat` that every module of a
   program imports. `print` is `console.log` under node and, in a
   browser, `write_line` from the `io` library's browser implementation
   (`io_external.js`, shipped with every web program), so a page
   embedding the program replaces one file to own its standard output;
   `debug` is `console.error` everywhere. The web page is a loader that
   flushes what `io.write` left unfinished and reports a nonzero
   `sys.exit`; the `iweb24` page asks the bundle for
   `pykRunProgram('<main>\nrelease')` under `--release`.
11. **`src/target_c.ml`** — the C backend, serving both the `c89` and
   `c23` targets: a `C*` AST, translation, and a printer taking a
   `standard` parameter. One backend rather than two because the
   standards disagree about *printing*, not meaning — comments, whether
   declarations may follow statements, whether `bool` exists — so the
   `standard` reaches only `pprint_c_program` and its helpers. Its real
   work is the type inference C forces and Pyking never needed: every
   expression node carries an `Int`/`Float`/`String`/`Bool` type, bindings take
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
   both reading `Effects` rather than deciding for themselves. What the
   top level binds is a `static` file-scope variable (`statics`), which
   is what lets a function read it, and a top-level `def` is a value: a
   pointer to the C function, its type a `Func` ctype written through a
   guarded typedef named for its shape (`pyk_fn_ii_v`), which is also
   what an external module is handed for a callback. `library_names`
   reserves what the C library declares, since a file-scope name could
   collide with it. See `docs/target_c.md`, "The top level" and
   "Functions as values".
12. **`src/target_java.ml`** — the Java backend, serving `java8`,
   `java17` and `java21`: a `J*` AST, translation, and a printer taking a
   `version` parameter, the same shape `target_c.ml` uses for `standard`
   — one backend because the three versions disagree only in whether a
   local declaration writes `var` (Java 10's local-variable type
   inference, absent from java8) or spells its type out. Infers types the
   same way `target_c.ml` does (`Int`/`Float`/`String`/`Bool`, from initializers,
   annotations, and translated return bodies), and additionally checks
   that every function provably returns on every path
   (`_definitely_returns`) and that no statement follows one that always
   does (`_check_reachable`), since `javac` — unlike `cc` — refuses to
   compile either. Needs no runtime helper the way C's `pyk_concat` and
   `strcmp` are: string concatenation is Java's own `+`, and equality is
   `.equals()`. The output file and its class are named in Java's own
   style rather than the source's, since Java requires the two to match
   (`default_class_name`; see `pyk.ml` below for where the exception
   is applied). What the top level binds is a static field (`statics`),
   and a top-level `def` is a value: the `java.util.function` interface
   of its shape (`Runnable`, `Consumer`, `BiFunction`, ...; `java_type`,
   `apply_method`), written as a lambda over `p$1`, `p$2` -- `$` is in no
   Pyking name -- calling the method (`JLambda`). See
   `docs/target_java.md`, "The top level" and "Functions as values".
13. **`src/target_ocaml.ml`** — the OCaml backend, serving the `ocaml5.5`
   target: an `O*` AST, translation, and a printer. The only backend
   that infers nothing — it *runs* `typesystem.type_check` and reads the
   types back out of `tmap` (which is why `check_expr` records an entry
   for every expression, not just annotatable ones), so a program that
   does not check is refused with the checker's own message. Its subset
   is nearly all of what the checker accepts, and the few shapes it
   refuses are listed in `docs/target_ocaml.md` under "What is not
   supported"; each raises `Unsupported` with a source position. OCaml fits Pyking closely
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
   reads a binding from around it — they have no closures — except what
   the top level binds, which they make a file-scope variable and a
   static field.

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
   they differ over quoting a string), `load_modules`/`bind_imports`/
   `with_host` (modules run into a machine already running, an entry's
   imports bound, and another host -- what a REPL entry's imports need),
   and the hosts. A host has one field per host-crossing entry in
   `builtin.ml` -- `print_line`, and `debug_line`, standard error unless
   a host says otherwise -- and `externals`, how a module implemented in
   a target language is reached: `pyk`'s plugins (`plugin_host.ml`) in a
   terminal, the page's JavaScript in a browser. The formatting rules
   are `builtin.ml`'s, implemented once here.

   Two things that are language decisions rather than implementation
   ones: an `Int` holds **at least the signed 32-bit range, and
   overflow is undefined**, so nothing here narrows a result -- an Int
   is the host's own `int`, and the interpreter native and the
   interpreter under js_of_ocaml may therefore disagree past 2^31
   (PYKING.md states the rule, `docs/targets.md` has the table); and
   `call_free_symbols`
   is the one optimisation — an expression with no call in it can neither
   suspend nor print, so `_evaluate` computes it in one go, off a set
   worked out once before the program runs.
16. **`src/repl.ml`** — `pyk repl`, and the editor it is typed into. The
   session itself is **`src/repl_session.ml`** (item 25), in the library,
   which the playground's REPL tab runs too; `repl.ml` keeps the editor,
   the readers, `:load`, the loop and `terminal_host`. A
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
   An **entry may import**: `import_modules` hands its imports to
   `Module.load_imports`, checks each module they newly reach as a
   program's would be checked (`check_import`), loads its plugin if it
   is implemented in a target language, and runs its top level into the
   session (`Interpreter.load_modules`); the checker's `store.modules`
   and the machine's `exports` then hold what it exports, and
   `Typesystem.import_env`/`Interpreter.bind_imports` bring the entry's
   imported names into the two environments. A module is loaded once per
   session. The program's standard input is the session's own, so at a
   piped prompt `io.read_line()` reads the next line of the entries'
   input. `Session(seen, state, types, store, kinds, sources, arguments,
   libs, modules, sigmaps, exports, hosted, host)` holds the two
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
   `pyk serve` for `web` and `iweb`, whose pages must be
   served because a browser refuses a module over `file://`; this
   compiler again for
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
   (alias `pyk c`) compiles, which is what every flag above is for, and
   `--release` with it -- `release.ml` over every module, refused for any
   other command. `pyk <file>` loads each external module's plugin first
   (`Plugin_host.load`) and sets `Sys.argv` to the program's own, and
   `pyk compile` hands the C and Java backends `Prune.program`'s output.
   Flags are shared by all three rather than per-command, so `--tokens`
   means the same thing wherever it is written. `pyk plugins <dir>`
   builds the plugin of every library in a directory of libraries, which
   is what `make libs` runs over `lib/`. Four more, `pyk notebook
   FILE.md`, `pyk playground`, `pyk pykhelp` and `pyk serve [DIR]`, run no front end at
   all: `command_web` hands them to `web_tools.ml`, and `--port` is
   theirs alone. Nor does `pyk lsp`, the language server: `command_lsp`
   is its stdio transport over `lsp.ml`, and `--stdio` and `--log` are
   its alone. Nor does `pyk example [NAME]` (`command_example`, over
   `examples.ml`).
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
   owns its own translation, packaging, and file naming (a JavaScript
   program writing a runtime module and a manifest beside itself is
   `target_js_packaging`'s business, not the
   driver's; deriving a Java class name from an explicit `--output` is
   `target_java.ml`'s, by the same principle). What a backend needs to
   know about the module it is compiling *as part of a program* arrives
   as one `module.Context`, not as a growing list of parameters.

19. **`src/web_tools.ml`** — `pyk notebook`, `pyk playground` and `pyk
   serve`, in the executable since they listen on a socket. Each is a
   `Web_server.site` -- URL prefixes mapped to directories beside the
   running executable, URL paths to files, and answers worked out per
   request (`notebook.json`, the playground's manifest, whose examples
   are `src/examples.toml`'s, and the bundle's stamp) -- served by **`src/web_server.ml`**, a small HTTP/1.1 server
   on 127.0.0.1 waiting on every connection with `select`, in the `pyk`
   process: nothing else has to be installed. `pyk notebook --mode test`
   serves nothing and runs `tools/notebook/check.js` under node. See
   "The web tools" below.

20. **`src/install.ml`** — `root ()`, the directory the running
   executable is in *after resolving every symbolic link*. Everything
   that looks beside `pyk` -- the standard library, `build/pyking.js`
   for `iweb`, the web tools -- asks it, since a package manager's
   `bin/pyk` is a link and the tree is beside its target. Do not read
   `Sys.executable_name` for a directory anywhere else.
21. **`src/version.ml`** — generated, not checked in: a rule in
   `src/dune` writes `let version = "..."` from the `VERSION` file at
   the root. `pyk --version` prints it and `tools/packaging/` names
   packages by it. Bump `VERSION` for a release; nothing else holds the
   number.
22. **`src/plugin_host.ml`** — how the interpreter reaches a module
   implemented in a target language: its OCaml implementation,
   `<module>_external.ml` -- the file the `ocaml5.5` target links --
   compiled with a registration file generated from its declarations
   into a `.cmxs` and loaded with Dynlink, so `pyk` runs every external
   module without being rebuilt. The registration file records each
   declared name in **`src/plugin/pyk_plugin.ml`**, a one-module library
   of its own (unwrapped, linked only into the executable, its `.cmi`
   copied to `build/plugin/` by `make` so a plugin compiled elsewhere
   can name it), and a value crosses by its declared type. A plugin
   beside the implementation is used where the digest beside it
   (`<module>_external.digest`: the sources, the registration file, the
   OCaml and pyk versions, the interface) is what it would be built from
   now; otherwise one is compiled into `$XDG_CACHE_HOME/pyking/plugins/`
   with `$OCAMLOPT`, which must be the OCaml `pyk` was built by. The
   executable links `dynlink` and is `-linkall`, so a plugin may use any
   of Stdlib and `unix`. `set_arguments` makes `Sys.argv` the program's
   own through `caml_sys_modify_argv`. A library may add
   `<module>_external_plugin.ml` (`glue`), compiled into the plugin after
   the implementation: the one file that may name `Pyk_plugin`, which a
   compiled program does not have -- tinyweb's registers what runs after
   the top level and what the REPL waits on while it waits for a key
   (`Pyk_plugin.on_idle`), and `Pyk_plugin.directory` tells it where the
   library is. An implementation raising `Failure` is a runtime error at
   the call. See `docs/libraries.md`, "How the interpreter reaches an
   OCaml implementation".

23. **`src/lsp.ml`** — the language server, `pyk lsp`, in the library
   so the browser bundle has it too (`pykLsp`/`pykLspIdle` in
   `src/web/pyking_web.ml`, which the playground's Monaco talks to).
   A `state` and `handle state text -> (state, [text])`, one JSON-RPC
   message in and the messages to send back out; `idle` checks every
   document due and publishes its diagnostics, which is the debounce --
   a change only marks documents due. It opens no file: the caller
   hands in `Module.sources` and the library path, and an open
   document's text is laid over them. A document is checked as a
   program, exactly as `pyk.ml` checks one (`Module.load`, then
   `Typesystem.type_check` and `Analyses.analyze_mutability` per
   module), and hover, definition, outline and completion are read out
   of that: types from `tmap`, names by a scope walk of its own
   (`resolve_*`, which binds as `analyses.ml` does -- `def`s hoisted
   per block, imports before the first statement). Positions are
   converted in one place: `Lexer.info`'s rows from 1 and byte
   columns, LSP's lines from 0 and UTF-16 columns. The stdio transport
   (Content-Length framing, `--log`, the 200 ms quiet before `idle`) is
   `command_lsp` in `pyk.ml`, the only part needing `unix`.
   **`src/json.ml`** is JSON read and written, which the server needs.

24. **`src/examples.ml`** — the examples list: what `pyk example` lists
   (one per line) and saves into the current directory, and what the
   playground's Examples menu offers. It reads **`src/examples.toml`**,
   one `[[examples]]` table per example: `source` (a test program's
   path from the root), `name` (the file it is saved as) and
   `description` (one line). Each is a test case, so `make test` keeps
   it working, and `tests/test_playground.py` checks that every one is
   a case the interpreter runs and fits 80 columns. A package ships the
   list and each source at the same paths (`packaging.py`'s
   `examples_shipped`), so `pyk example` and the playground read it the
   same way in a checkout and an install. `pyk example NAME` refuses to
   overwrite a file. In the playground, Compile refuses an example that
   imports, as it does any such program; Run runs it.
   `design/lsp.md` is the plan, in three steps; step 1 is built.

25. **`src/repl_session.ml`** — a REPL session without the terminal: what
   `pyk repl` and the playground's REPL tab share. Everything above about
   checking an entry the way it is run, imports, `:edit` and the
   meta-commands is this module's; it opens no file and reads no
   terminal, because everything it shows goes through a `host` record
   (`write` a shown line, `machine` the interpreter's host, `connect` a
   module implemented in a target language, `from` where imported files
   are read). `repl.ml`'s `terminal_host` writes to stdout and loads
   plugins; `web/pyking_web.ml`'s `repl_host` writes to `pykOnShow` and
   reaches `pykExternals`. `run_meta ?extra` takes the terminal's
   `:load`, and `:help` lists `:load` and `:quit` only then. `bindings`
   is the data `:ls` formats and the page's environment table shows;
   `imported_modules` says what an entry would load, so the page's
   worker imports the JavaScript first. See `docs/repl.md`, "One
   session, two front ends".

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

## Module interfaces (`.mli` files)

Every module in `src/` has an `.mli` beside it, and that file is the
whole of what another module may use: what is not named there is
unreachable from outside, whatever the `.ml` defines.
`docs/interfaces.md` is the map of them — which module refers to which,
what crosses each boundary, and which types are opaque.

**A name belongs in an `.mli` only if something outside its own module
calls it.** A function or value used only inside the module that defines
it stays out of the interface, however much it reads like an API — and a
great deal does: each non-terminal of the parser, each `check_*` of the
type checker, each `translate_*` of a backend, the scope every backend
threads, every helper that formats a message. A type is named in an
`.mli` only because an exported signature mentions it, and it is
abstract unless a caller has to look inside it.

So adding a function does not mean adding it to the `.mli`. Leave it
private until a second module needs it; when one does, add the `val`
with the two-part docstring every function in `src/` gets.

A narrow interface is also what lets the compiler find dead code: with
an `.mli`, a private value nothing calls is warning 32, a private type
nothing mentions 34, and an unused constructor 37. Fix what they point
at — the name is dead — rather than re-exporting it to quiet them.

There are exactly two exceptions, and both are named here rather than
left to judgement. The first is the interpreter's embedding API
(`step`, `run`, `format_value`, `eval_statement`), which
`design/plan-eval-lsp.md` commits to as the surface the debugger, DAP
and LSP servers are to sit on. The second is `walk.ml`: `children` and
the folds built on it are the compiler's one shared traversal, and they
stay exported whether or not each has a caller today. Nothing else in
`src/` is exported without a caller, and a third exception belongs in
this list rather than in someone's judgement.

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
`pykCompile`, `pykRun`, `pykRunProgram`, `pykAnalyze`, `pykTargets`,
`pykFormatHelper`, `pykKeywords`, `pykBuiltins`, and the language server's
`pykLsp` and `pykLspIdle` (text crossing as UTF-8, so a column means what
it does natively), and the REPL tab's `pykReplStart`, `pykReplLine`,
`pykReplImports` and `pykReplSubmit` (`repl_session.ml`; a shown line
goes to `pykOnShow`) on the global object,
and `stub.js`, the `//Provides:` primitives that let it. Nothing in it is
compiler logic — every entry goes through the same functions `pyk.ml`
calls, and reports a refusal with the same `format_error`.
`pykRunProgram` reads a program of several modules from what the page
supplies (`pykSources`, and `pykFetchSource` for a name it did not,
which is how a page reads the standard library from `lib/`), reaches a
module implemented in JavaScript through `pykExternals`, sends a
`debug` line to `pykOnDebug`, and ends with `{"ok":true,"exit":N}` where
`sys.exit` ended it -- the JavaScript implementation throws an error
carrying `pykExit`, and `stub.js` answers it as data. `pykAnalyze` says
which of a program's modules are implemented in JavaScript and whether
it reads standard input or `sys.args()`, from `prune.ml`'s narrowed
imports.

Two rules follow from it and are easy to break:

- **The library must stay dependency-free.** Nothing in `src/`'s library
  half may open a file, start a process, read a terminal or link `unix`;
  that is why `pyk.ml`, `execution.ml`, `repl.ml` and `plugin_host.ml`
  are in the executable instead. A `Unix.` call added to a library module breaks
  the playground, not the compiler, so nothing local will tell you.
- **js_of_ocaml's `int` is 32 bits**, where a native one is 63. Anything
  that depends on the width has to say so explicitly. A Pyking `Int`
  deliberately does not: overflow is undefined, so the two builds may
  differ past 2^31 and both are right. What is pinned instead is the
  *literal* bound, `lexer.max_int_literal`, so the front end accepts the
  same programs on both.

`docs/build.md` is the long form, and `tools/playground/README.md`
covers what the page does with the bundle.

## The web tools

Two pages run that bundle: the **playground** (`tools/playground/`) and
the **notebook** (`tools/notebook/`), a Markdown file whose ```` ```pyking ````
blocks are cells a reader can edit and run with the interpreter. What
they share is in **`tools/webrun/`**: `server.py` (the
vendored-library download, and the `Site` the website build copies
from -- not shipped, and not what serves the pages), `assets/` (the compiler's worker and `PykingRuntime`, the Ace mode the
notebook uses, `pyking-monaco.js` for the playground's Monaco, and
`web.js`, which loads Ace or Monaco, KaTeX and the compiler), and
`vendor/` (Ace, Monaco and KaTeX, downloaded once by `make vendor`,
never checked in). The playground's editor is Monaco, an LSP client of
`src/lsp.ml` running in the worker (`tools/playground/assets/lsp-client.js`);
the notebook and the website's cells still use Ace. Put
anything both pages need there rather than copying it.

- **There is no build step**, with one exception. `pyk` serves each
  tool's files, the shared ones and `build/pyking.js` from where they
  sit, and works out what is not a file (the playground's example
  manifest, the bundle's stamp) per request. The exception is the help
  (`tools/help/`): `make` runs `tools/help/help.py`, which writes the
  help's pages into `build/help/` as `make` writes the bundle into
  `build/`, and packages ship it. Do not add another generated copy.
- **Nothing is baked into the pages.** The keyword list, the builtins,
  the targets and the JavaScript value formatter are asked of the loaded
  compiler through the worker's `words` request, so the compiler is
  loaded before any editor is made.
- **Both are started through `pyk`**: `pyk notebook FILE.md` and `pyk
  playground` (see `src/web_tools.ml`); `make notebook` opens
  `PYKING-TUTORIAL.md` and `make playground` the playground, both after
  `make vendor`. `pyk` serves them itself (`src/web_tools.ml`,
  `src/web_server.ml`); the pages are JavaScript. What it serves is
  also written in `server.py` and `playground.py` for the website
  build, and `tests/test_notebook.py` holds the two to the same files
  and the same manifest.
- **The notebook is read-only.** Edits to a cell live in the page until
  it is reloaded; each cell is a whole program, run on its own.
  `tools/notebook/assets/markdown.js` is a hand-written renderer, pure so
  node can test it; `tools/notebook/README.md` lists what Markdown it
  supports, the cell attributes (`norun`, `readonly`, `error`), and the
  ```` ```stdin ```` and ```` ```args ```` blocks that fill in the input
  of the cell right after them.
- **A notebook may be an assignment.** ```` ```rules ````, ```` ```pyking
  exercise ```` with its ```` ```pyking solution ```` and stdin/stdout/
  stderr tests, and ```` ```quiz ```` with its ```` ```answer ````:
  `tools/notebook/assets/exercises.js` (pure) says what the blocks mean,
  what is wrong with them and how an answer is graded, and
  `activities.js` puts them on the page. `pyk notebook --mode student`
  (the default) or `teacher` says who reads it, and `--mode test` serves
  nothing: `tools/notebook/check.js` runs every program under node with
  the page's own worker and prints `file:line: message`. Progress is kept
  in the browser; `results()` and `onChange` tell an embedding page.
  `tools/notebook/README.md`, "Exercises and quizzes", is the long form.
- **A program run in either page may use the standard library.** The
  server serves `lib/` (`common_site`), the worker fetches a module's
  sources and its browser implementation from there as the program names
  it, and supplies `io` and `sys` itself: standard output is the page's
  output, standard input and the arguments are what the page asked for
  -- a dialog in the playground, fields above the cell in the notebook,
  shown only when `pykAnalyze` says the program reads them -- and
  `sys.exit` ends the run. A `debug` line is shown apart from the output,
  and on the console.
- **The playground's right side is five tabs**: Run output (the left
  Run's output), Compiled code (Target, Compile, the right Run, the code
  and its own output), Web output (a tinyweb page in a browser-window
  frame with Refresh, above the same output Run output shows), REPL
  (a session of `repl_session.ml` on a `PykingRuntime` of its own, its
  environment as a table below) and Help (the help, below). It has a light and a dark theme: colour
  tokens on `.pyk-playground`, overridden under `[data-theme="light"]`,
  chosen by the header's switch or Appearance in the settings unless the
  embedding page passes `theme` and calls `setTheme`, as the website
  does with Starlight's. `tools/playground/README.md` is the long form.
- **The help** (`tools/help/`, `pyk pykhelp`, the playground's Help tab):
  Getting started, the language reference (PYKING.md) and the library
  reference, generated as Markdown into `build/help/` by
  `tools/help/help.py` -- the same pages the website is built from --
  and shown by `tools/help/assets/help.js` (`mountHelp`), a menu of
  pages above the page, rendered by the notebook's `mountCells` so every
  example is a cell, with a "Copy to editor" button in the playground.
  `pyk` serves its scripts at `/help/` and the pages at `/help/pages/`
  for every tool. `tools/help/README.md` is the long form.
- Both are libraries as well as pages: `mountNotebook(host, options)` and
  `mountPlayground(host, options)` embed them in another site. Keep the
  host `index.html` pages thin.

**Packaging and dependencies.** Pyking is meant to be distributed as a
binary: `./pyk` is a native executable, and using it -- compiling,
interpreting, the REPL -- needs no OCaml, dune or js_of_ocaml, which are
needed only to *build* it. **Nothing else is needed to use it**: the
notebook and the playground are served by `pyk` itself, and a
distribution ships no Python. The one exception is `pyk notebook --mode
test`, which runs the notebook's code under node. A distribution is a subset of this repository's tree at the
same relative paths -- `pyk`, `lib/` (with its plugins),
`build/pyking.js`, `build/plugin/`, `build/help/`, `tools/webrun/` (with
`vendor/`), `tools/notebook/`, `tools/playground/`, `tools/help/assets/`,
and `src/examples.toml` with
the programs it names -- so the one
rule "look beside the executable" finds everything in a checkout and an
install alike. Keep it that way: a web tool may not need anything outside
those directories, and the playground runs (with no example menu) when
`src/examples.toml` is absent. `docs/build.md`, "The web tools", is the long form.

## The website

`make website` builds the Pyking website into **`website/`** (gitignored)
with `tools/site/site.py`: Astro with Starlight, configured in
`tools/site/`, over pages that live elsewhere: **the help**
(`tools/help/help.py`, the same pages the playground's Help tab and `pyk
help` show). **`sitesrc/`** holds the hand-written Markdown (the start
page, `install.md`, `getstarted/` and `documentation/`, one page per
file); the help adds the language reference, made from **PYKING.md**,
and the Libraries section, **generated from `lib/`** by
`tools/help/libdoc.py`. `site.py` stages the help, tinyweb's pages and
the runtime the pages run in `tools/site/build/` (gitignored) and Astro
builds from there; nothing is generated into `sitesrc/` or `lib/`.

- **Five sections**, in the header beside the logo, with the search on
  the right (`src/components/Header.astro`, `src/sections.mjs`): Install,
  Getting started, Documentation (the language reference, Editors, and
  tinyweb without Pyking), Libraries and Playground. **The menu on the
  left is the section's own pages only**, the page being read opened at
  its `##` headings (`src/components/Sidebar.astro`, over the
  `sidebar.json` `site.py` writes from the help's `index.json`); there
  is no table of contents on the right. The playground page is the
  header and the playground, filling the window.

- **tinyweb has pages for using it without Pyking**, under
  Documentation, one per language
  it is implemented in, written by `tools/site/tinywebdoc.py` with the
  library renamed (`tinyweb.py`, `tinyweb.ml`/`.mli`, `tinyweb.c`/`.h`,
  ...), an example from `tools/site/tinyweb/`, and the tests compiled
  for that language.
- **A library is documented by its `##` comments.** A `##` block opening
  one of a module's two files describes the module; a `##` block directly
  above a `public` line describes that export, whose own line (without
  `public`) is the signature shown, boxed with every parameter's name and
  type. The block is a summary, then `# Parameters` (`- name: text`, in
  order), `# Returns` (unless it answers `()`) and `# Examples`, a
  ```` ```pyking ```` block followed by a ```` ```stdout ```` block of exactly what
  it prints. A declaration in `lib/` names its parameters (`def
  write(text: String) -> ()`). A plain `#` comment is for maintainers
  and is never published. `tests/test_site.py` refuses a public name
  documented any other way, and runs every example against its output;
  `tools/help/README.md` has the format.
- **A ```` ```pyking ```` block on a page is a runnable cell**, with the
  notebook's fences (`readonly`, `error`, `norun`, ```` ```stdin ````,
  ```` ```args ````). `tools/site/src/remark-pyking-cells.mjs` turns it into
  a placeholder and `public/site/cells.js` calls the notebook's
  `mountCells` on it -- the notebook's own cell, not a copy. Every one is
  run by `tests/test_site.py`. A run of blocks holding an exercise, a
  quiz, the rules or a stdout block becomes one `.pkn-fragment` instead,
  which `mountCells` renders and grades as the notebook does.
- **The playground page is `mountPlayground`** from
  `tools/playground/assets/`. Both it and the cells load from `runtime/`
  in the built site, which `site.py` writes from the same `Site` the
  playground's server serves -- so a change to what the playground
  serves reaches the website with no edit here. A file a page fetches
  from `lib/` must have a suffix in `site.py`'s `LIB_SUFFIXES` -- tinyweb's
  sound samples among them, which is why a sound played on the website.
- **`make website-release` publishes it** at
  <https://pyking-lang.github.io/> with `tools/site/publish.py`: it
  refuses uncommitted changes to tracked files and a HEAD not on GitHub,
  builds `website/` afresh with `PYKING_SITE_URL` set, asks (`YES=1`
  does not), commits it with `.nojekyll` and a README naming the commit
  on top of the last upload on `main` of
  `pyking-lang/pyking-lang.github.io`, has Pages serve that branch's
  root with HTTPS enforced, and waits until the site serves the upload.
  `tests/test_site.py` checks what it commits (`fill`).
- **The website is not shipped.** No package holds `tools/site/`,
  `sitesrc/` or `website/`, and `SHIPPED` must not grow them.

`tools/site/README.md` is the long form, and `docs/build.md`, "The
website", the short one.

## Packaging

`make packaging` builds the installable packages into
`tools/packaging/build/` (gitignored, removed by `make clean`), with
`tools/packaging/packaging.py`, and `make release` publishes them. A
format is one class in its `FORMATS` table -- `name`, `refusal()`,
`setup()`, `build(archs)`, `install_local()` / `uninstall_local()` --
and every format ships the tree `stage()` builds: the table `SHIPPED`,
filtered by file suffix so no backup or cache file can reach a package.
A file a web tool or `pyk` needs at run time has to be in `SHIPPED`, or
the installed copy will not have it. The two exceptions are built rather
than copied: `stage()` ships the `pyk_plugin.cmi` of the build that made
the binary (`interface`), and **`build_plugins()`** compiles the
standard library's plugins in the staged tree with that binary's own
toolchain -- a plugin loads only into an executable its own compiler
built, so a `.cmxs` is never copied from the checkout.
`release_assets(v)` is the one list of what a release holds; a format
that adds files adds them there. **`CHANGELOG.md`** (Keep a Changelog)
is shipped, and its section for `VERSION` is the release's notes
(`changelog_notes`): `make release` refuses a `-dev` version and a
section that is missing, empty or still `Unreleased`. Add to the
`Unreleased` section as changes are made.

- **Homebrew** (macOS): a universal `pyk` (arm64 + x86_64,
  `MACOSX_DEPLOYMENT_TARGET=11.0`), built on an Apple Silicon Mac by two
  opam switches called `pyking-release` whose OCaml was itself compiled
  for macOS 11 -- the x86_64 one under Rosetta -- reached by the command
  prefixes in `$PYK_ARM64` / `$PYK_X86_64`. Both are checked before
  anything is built (architecture, the OCaml version, dune, and a runtime
  no newer than the floor, read with `otool -l`), and so is that they are
  the same compiler: their `Stdlib` checksums must agree, since one
  `pyk_plugin.cmi` serves both halves, and `STDLIB_CHECKSUMS` says which
  switch is the odd one. Both switches are built without zstd
  (`SWITCH_PACKAGES`: `ocaml-option-no-compression`), since zstd changes
  every interface's checksum and only the arm64 build can find
  Homebrew's, since a runtime compiled for a newer
  macOS makes the floor a lie. The halves are joined with `lipo`, signed
  ad hoc, and refused if `otool -L` shows a library outside `/usr/lib`
  and `/System`. The plugins are built per architecture, each in a tree
  staged around that architecture's binary and by its own switch, and
  each plugin's slices are joined with `lipo` and signed, with the
  `.digest` beside it (without one `pyk` compiles the plugin, which
  needs OCaml); the tree's `pyk` must then run a program importing every
  library as each architecture with no OCaml (`check_plugins_load`). Beside the
  tarball go two formulas: `homebrew/pyking.rb`,
  naming the release, and `homebrew-local/pyking.rb`, naming the local
  file, which `make packaging-install` installs through the tap
  `pyking-lang/local`.
- **Linux** (every distribution, and WSL): `pyk` linked dynamically
  against glibc 2.28 -- dynamically because the interpreter loads
  plugins, which a static binary cannot -- in an AlmaLinux 8 container
  per architecture (`tools/packaging/linux/Dockerfile`; the image's tag
  hashes the Dockerfile and the OCaml version), the other architecture
  emulated. It is refused unless its ELF header (`elf_info`) says
  dynamically linked and the right architecture, and it asks for no
  glibc past `GLIBC_FLOOR` (`glibc_needed`); its plugins are then built
  in the same container, and the staged tree -- a program importing
  libraries included -- is run in current Debian and in Debian 10. Each
  architecture gives a tarball, which `tools/packaging/install.sh`
  installs (POSIX sh; `~/.local` by default, `--system`, `--version`,
  `--uninstall`, checksums checked against `SHA256SUMS`), and a `.deb`
  that `deb()` writes directly (an `ar` of two tarballs, so no `dpkg` is
  needed), with `Depends: libc6 (>= 2.28)`. Both
  also go out under fixed names (`pyking-linux-x86_64.tar.gz`,
  `pyking_amd64.deb`), which `latest` links and install.sh ask for.
  `make packaging-install` on Linux runs install.sh against `build/`
  (`PYKING_DOWNLOAD_BASE`).
- **Docker**: made from the Linux tarballs, so it follows `linux` in
  `FORMATS` and needs its tarballs; `tools/packaging/docker/Dockerfile`
  has two targets, `slim` (the tree on `debian:13-slim`) and `full` (on
  `python:3.14-slim-trixie`, with gcc, a JDK, node from nodejs.org
  checked against `NODE_SHA256`, and the Linux build image's own OCaml
  at its own path, so a program's external module compiles a plugin
  that loads). That OCaml's runtime is not PIE, so the image's
  `ocamlopt` is `docker/ocamlopt`, adding `-no-pie` to every link but
  `-shared`. Images are tagged locally as they are pushed,
  `ghcr.io/pyking-lang/pyking:<v>[-full]-<arch>`, and run before they
  are kept -- in `slim` the playground through a published port, which
  works because the image sets `PYKING_WEB_HOST=0.0.0.0` (`web_server.ml`
  listens on 127.0.0.1 otherwise); in `full` `--run` for every family.
- **Nix**: `build/nix/flake.nix` (`flake()`), each system's release
  tarball by URL and SRI hash, with `autoPatchelfHook` on Linux and no
  fixup on macOS, so the signed universal `pyk` is untouched. Nothing
  needs Nix: in a `nixos/nix` container (`NIX_IMAGE`) the flake is
  locked (`flake.lock`, pinning `NIXPKGS`), every system's derivation is
  instantiated, and the same flake with the local Linux tarball in place
  of the fetch is built and run per architecture.
- **VS Code** (and Cursor): `tools/editors/vscode/`, plain JavaScript
  over `vscode-languageclient`, packed by its own `make vsix` into
  `pyking-<version>.vsix` (`VSCode.build`; node 20+ and npm on the
  build machine). One file for every platform: it starts the `pyk lsp`
  the user installed. `tools/emacs/pyking-mode.el`, which registers the
  server with eglot, ships in every package's tree.

The code repository is private, so nothing a user downloads lives in it.
**Every release goes to the public `pyking-lang/pyking-releases`**
(`RELEASES_REPO`) -- the Mac tarball, both Linux tarballs and `.deb`s,
the `.vsix`, install.sh and `SHA256SUMS` in one release per version, marked latest --
and **the formula to `pyking-lang/homebrew-tap`** (`TAP_REPO`), whose
`homebrew-` name makes the tap `pyking-lang/tap`. After the tap, the
release commits the flake (and a regenerated README) to
`RELEASES_REPO` and runs it from there in a Nix container, then pushes
the images to `IMAGE_REPO` with the `gh` token (which needs
`write:packages`) and joins each variant's architectures with `docker
buildx imagetools create` under `<v>`/`latest` and `<v>-full`/`full`.
A new ghcr.io package is private until made public once by hand, and the
release says so when an anonymous pull is refused. So users run `brew
install pyking-lang/tap/pyking` (`BREW_INSTALL`), `curl -fsSL
https://github.com/pyking-lang/pyking-releases/releases/latest/download/install.sh
| sh` (`LINUX_INSTALL`), `nix run github:pyking-lang/pyking-releases`
(`NIX_RUN`) and `docker run ... ghcr.io/pyking-lang/pyking`
(`DOCKER_RUN`). `make release` (`release()`) needs every file of
the release for `VERSION`, so it is run where every format was built --
an Apple Silicon Mac with Docker. It checks everything before changing
anything -- including git's identity *outside* this repository, since
the tap commit comes after the release -- asks unless `YES=1`, never
replaces an existing release, downloads every file back (install.sh
once more through `latest`) and checks it against `SHA256SUMS` before
touching the tap, and ends in one SUCCEEDED/FAILED line. Last, asked
separately (`YES=1` answers it too), it tags the commit the release was
built from in the private code repository `CODE_REPO`,
`pyking-lang/pyking`, as `release-<VERSION>` (annotated, pushed to
`origin`). Whether that can be done is checked with everything else,
before anything is published (`code_tag_preflight`): no uncommitted
change to a tracked file, `origin` being `CODE_REPO`, HEAD already on
GitHub (asked through `gh api`, since the repository is private), and the
tag absent or already on HEAD.

`make packaging-setup` makes the toolchains (`setup()` on each format:
each step checked before it runs, then `preflight`, with one row per
format and architecture and one SUCCEEDED/FAILED line). The Mac's
commands are the `SETUP` table's, which the refusals print too, so keep
the two and the README's setup section in step. Every format is asked
for its `refusal()` before any is built, so a machine that cannot build
one says so at once; `FORMATS=` and `ARCHS=` build part of it, and
`make release` refuses what is not complete. Publishing is left to the
maintainer; see `tools/packaging/README.md`.

## Running

```
pyk [options] <filename> [-- args]   run it with the interpreter
pyk repl                             start the REPL
pyk compile [options] <filename>     compile it (alias: pyk c)
pyk notebook [--port N] <file.md>    serve a notebook, print a link
pyk playground [--port N]            serve the playground, print a link
pyk pykhelp [--port N]               serve the help, print a link
pyk serve [--port N] [<dir>]         serve a directory's files, print a link
pyk plugins <dir>                    build the interpreter's library plugins
pyk lsp [--stdio] [--log FILE]       the language server, for editors
pyk example [<name>]                 list the examples, or save one here
pyk --version                        print the version (from VERSION)

options: [--tokens] [--symbols] [--no-tail-call-opt]
         [--no-typechecking] [--type-experiment] [--run] [--release]
         [--target|-t <target>]
         [--lib-path|-L <dir>] (repeatable)
         [--stdout | --output|-o <file>]
         [-- <the program's own arguments>]
```

**Everything after `--` belongs to the program**, not to the compiler:
it is what `sys.args()` answers with, and it is why a program's own
`-t` or `--run` is not read as ours. It applies where a program is
*run* -- `pyk prog.pyk -- a b`, or `pyk compile --run` for a target
whose host takes arguments -- and is refused for `pyk repl`, for
`pyk compile` without `--run`, and for `--run` on a page target, whose
"run" starts a server rather than invoking a program. `src/execution.ml`
appends them to each target's run command, putting a `--` of its own
in front for the `pyking` target, whose host is this compiler.

**`-L`/`--lib-path` adds a directory of libraries**, repeated rather
than separated since the separator is what differs between platforms;
`$PYKING_LIB_PATH` takes the platform's own (`:` here, `;` on Windows).
A module is looked for beside the file that imports it, then in each
`-L`, then in each environment entry, then in the `lib/` beside the
executable -- which is how the standard library is found with no flag
at all. `src/pyk.ml` assembles that list and hands it to `Module.load`,
because `module.ml` is in the browser build and may read neither the
environment nor its own path. See `docs/libraries.md`.

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
`src/interpreter.ml`, on Pyking's own semantics (Pyking runtime errors
with a stack trace, and no narrowing of an `Int`). The third way to run one is
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

- `--release` compiles in release mode: every call to `debug` is
  removed (`src/release.ml`) and `print` is kept. `pyk compile` alone
  takes it.
- `--run` builds and runs what was compiled, with the commands that
  target's host uses (`src/execution.ml`), each printed before it runs
  on stderr. Cannot be combined with `--stdout`, which writes no file.
- `--stdout` compiles and prints the generated source: the program's own
  module, since what is written beside it exists only as files.
- `--output <file>` compiles and writes to `<file>`. A single-file target
  writes exactly that path. The JavaScript targets write more beside it:
  one `.js` per module, `pyk-runtime.js`, and `package.json`
  (`{"type": "module"}`, which is what lets them all be plain `.js`). An
  existing `package.json` is never overwritten — it belongs to the
  surrounding project.
- A module the program imports is written beside the program's own
  output, under its own name and the target's extension -- which is also
  what the generated import in that output names it by. C and OCaml
  write a companion beside each (`helper.h`, `helper.mli`).
- With neither of the two above, the compiler names the file: the source's own stem
  plus the target's extension (`extensions` in `pyk.ml`, fed by each
  backend), in the *current* directory — `-t node24 tests/hello.pyk`
  writes `./hello.js`. Writing over the input, or into a directory that
  doesn't exist, is a usage error rather than a traceback, checked per
  file since the JavaScript targets write several. The Java targets are the exception: the
  default name is Java-cased instead of the source's own stem, since Java
  requires the file and its public class to match exactly — `-t java21
  tests/foo_bar.pyk` writes `./FooBar.java`, not `./foo_bar.java`.

**Every target has a version, and every family an unversioned alias for
its latest.** `src/targets.ml` is the one place any of them is named --
the list, the aliases, the extensions and the families -- and `pyk.ml`,
`module.ml`, `execution.ml`, every backend and the test harness read it
from there. `-t c` is `-t c23`, `-t java` is `-t java21`; a version says
the oldest host the output is promised to run on, and two versions of a
family may emit identical text.

`--target`/`-t` selects the backend: `python14` (the default), `node24`,
`web24`, `iweb24`, `c89`, `c99`, `c23`, `java8`, `java17`, `java21`,
`ocaml5.5`, or
`pyking`. The last is the odd one: it compiles Pyking to Pyking, which
is to say it prints the program the front end worked out — with the
types the checker inferred and the loops the tail-call pass built — and
so supports everything, because it *is* the shared AST rather than a
translation of it. `--symbols` goes with it, and nothing else does.
The rest come in groups sharing a backend: the JavaScript three differ
only in `src/target_js_packaging.ml`, the C two only in a `standard`
parameter to `src/target_c.ml`'s printer, and the Java three only in a
`version` parameter to `src/target_java.ml`'s printer; `ocaml5.5` is a
family of one. All of them support a subset of the language, and
anything outside it is refused at compile time with a source position
rather than emitted as code that will not build. `ocaml5.5`'s subset is
the widest: it starts from whatever `src/typesystem.ml` accepts, checked
by running it, and takes away the handful of shapes OCaml cannot be
given, which `docs/target_ocaml.md` lists. See `docs/architecture.md`
for the subsets and the target table.

A program that imports an **external module** is interpreted through
the module's OCaml implementation, loaded as a plugin
(`src/plugin_host.ml`): the standard library's are built by `make libs`
and shipped, and a program's own is compiled on demand, which needs the
OCaml `pyk` was built by. Such a program lists `interpret` like any
other, and the harness warns where it does not.

`pyk <file>` and `pyk repl` take no target: the interpreter emits
nothing to name. What they accept is `src/typesystem.ml`'s fragment,
checked by running it — the same arrangement `ocaml5.5` uses, and the
reason a program with `for`, `while`, `match`, lists or an unannotated
`def` is refused there with the checker's own message. A `loop`, a
tuple, a `var` and a `:=` are all inside that fragment.

Plain `make` builds the compiler: the `Makefile`'s first rule, `all`, is
`build`, since that is what someone typing `make` in a compiler's
directory is asking for. It runs `dune build src/pyk.exe` and copies the
executable to `./pyk`, and writes the help into `build/help/`
(`tools/help/help.py`). `make help` prints the list of targets, which is
hand-written, as is the one in `tools/playground/Makefile` it is
modelled on — add a target and you have to add its line too.

`make clean` removes `_build/`, `./pyk`, the plugins `make libs` wrote
into `lib/` (`<name>_external.cmxs` and `.digest`), `__pycache__`
directories and `tools/packaging/build/` (delegated to that directory's
Makefile);
`make distclean` also drops `tools/webrun/vendor/`, the download cache
`make vendor` fills.
Neither touches *compiled programs*: `pyk` writes them wherever the
caller asked, under names indistinguishable from hand-written source in
every target language, so a clean rule that guessed at them would
eventually delete someone's own file. Keep it that way. `./pyk` is the
exception that shows the rule -- `make build` chose that name itself,
which is the whole of why removing it is safe.

`make test TARGET=c23` runs one target and `make test TARGET=c` every
version of that family; with no `TARGET` every target runs, which is
what `make test` means. The REPL suite runs only when no `TARGET` was
given, since it is not a target.
`make test SUITE=tinyweb` runs one suite and `SUITE=repl,lsp` several
(`--suite` to `tests/test_all.py`); a name there is none of is refused,
and so is a `TARGET` with a `SUITE` that leaves out `programs`.

**`make test` runs `tests/test_all.py`**, which sequences the nine
suites below rather than each being a line of the Makefile. Three things
follow, and all three are the point: every suite runs even when an
earlier one failed, so one broken case does not hide what the other
eight would have said; each suite's output is opened by a banner and
closed by one footer line of a fixed shape; and the run ends with a
combined summary over all nine. Their counts reach it through
`$PYK_TEST_TALLY`, a file each suite appends one line to
(`tests/suite.py`), so a suite run on its own prints exactly what it
prints here. Each remains a script of its own, with its own
`--compiler`.

The first of them is `tests/test_script.py`. It
reads `tests/test_cases.toml`, and for every (program, target) pair the
manifest declares, compiles the program to a temp directory, runs it the
way a user would — `python3` on the `.py`, `node` on the `.js`, `node` on
`cc`/`javac`/`ocamlopt` and
then the binary for the C, Java and OCaml targets, `node` on the module a
`web24` page loads, and, for `iweb24`, the page's own glue with node's
filesystem in place of `fetch` — and compares
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

Four more things a case may say, each where a run's input or a
program's other output is written down: a sibling **`<name>.in`** is its
standard input (every run is given one, empty without the file, so a
program never reads the harness's own); a sibling **`<name>.err`** is
what it must write to standard error on every target, `debug`'s lines
(without one, standard error is not compared); **`exit_code = N`** is
the status it must end with, 0 by default; and **`release = true`**
compiles it with `--release` and holds every compiled target to writing
nothing to standard error -- the interpreter takes no `--release` and
runs it as written. Each runner is handed these as one `Invocation`,
and `executed` answers an `Output` of both streams. The `web24` runner
runs the page's own loader, taken out of the page, and the `iweb24`
driver makes the request the page's script makes, with `print` writing
through the shipped `io` implementation.

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

**`tests/test_libpath.py` is the third suite** and
**`tests/test_playground.py` the fourth**, both run by `make test` after
the other two and both covering what a (program, target) pair cannot
express. `test_libpath.py` is about the *invocation*: the order of `-L`
flags, `$PYKING_LIB_PATH`, a name that resolves in two places at once,
and the wording of a failure. Each case builds a throwaway tree of tiny
libraries, each exporting a `tag()` naming itself, and runs the program
-- so what is printed says which library was found. See
`docs/libraries.md`.

`test_playground.py` drives `build/pyking.js`, the compiler bundle the
page loads: that its entry points are registered, that one small program
compiles for every target the page offers and runs under the
interpreter, that **every example the page offers checks** as the
page's Run checks it, with the standard library it imports, and that
the REPL tab's session answers (entries, what they show and print, the
environment, refusals, `:edit`, an import, `:reset`). That last
is `make -C tools/playground check` asked of the bundle directly; the
example list comes from `playground.py`'s own `example_sources`, so the
suite and the page cannot disagree about what is offered. It also holds
`src/examples.toml` to its rules (see `src/examples.ml` above). The page
itself, its worker and its iframe are `make -C tools/playground e2e`'s,
which needs Playwright and is not part of `make test`.

**`tests/test_notebook.py` is the fifth suite**. It renders
`tests/notebook/features.md` -- every Markdown feature the notebook
supports, and every exercise and quiz block -- against `features.html`,
checks short cases against CommonMark's own answers, checks what
`exercises.js` makes of `features.md` and its grading arithmetic, runs
every cell of `PYKING-TUTORIAL.md` through
`tools/webrun/assets/pyking-worker.js` under node (an `error` cell must
be refused, any other must run), and starts `pyk notebook`, `pyk
playground` and `pyk serve` on a free port to fetch what their pages
load -- the playground's manifest and every file `playground.py`'s
`site()` names compared with what `pyk` serves -- and to check the
refusals: a missing file, a file that is not Markdown, a mode there is
none of, a missing directory. It runs
`pyk notebook --mode test` on `features.md`, which must pass, and on
`tests/notebook/broken.md`, which must be reported exactly as
`broken.out` says. Where a Chromium is found (`tests/suite.py`,
`find_chromium`) and `make vendor` has run, `tests/notebook/page.mjs`
drives `features.md` in it in student and teacher mode -- submitting,
answering, reloading, starting over -- and that part is reported as
skipped otherwise. Every Chromium driver (this one, tinyweb's and the LSP suite's)
starts and reaches the browser through `tests/chromium.mjs`: Puppeteer's
flags, so a full Google Chrome (a Mac's) neither throttles the test's
tab nor waits on the keychain, and a 60 s limit on every call, so a hung
browser is reported by the call it hung on. Each driver says how far it has
got with `progress`, and the suite runs it with
`suite.run_with_progress`, which prints those lines as they arrive. It sets
`PYKING_WEB_NO_VENDOR=1`, so a checkout that never ran `make vendor`
still passes. After changing the
renderer, `--update` rewrites
`features.html` and `broken.out`; read the diffs before keeping them. It takes `--compiler
CMD` like the others.

**`tests/test_packaging.py` is the sixth suite**, and runs on every
system even though the Homebrew package is built only on a Mac: it
stages the shipped tree around *this* machine's `./pyk`, installs it into
a temporary prefix shaped like Homebrew's (`bin/pyk` a link to a link
into `Cellar/pyking/<version>/libexec`), and from outside the repository
checks `pyk --version`, a program, the standard library, `iweb24`, `pyk
example`, `pyk notebook`, `pyk playground` (offering the same examples),
`pyk pykhelp` and `pyk serve` with nothing on the `PATH`,
that the web tools ship no Python, the tree's contents, the tarball's
reproducibility and the formula's text (`ruby -c` where Ruby exists).
The same tree is then packed as a `.deb` (read back, and by `dpkg-deb`
where it exists, then unpacked and run) and installed by install.sh from
a release copied into a temporary directory, into a temporary home
(install, reinstall, a wrong checksum, macOS, an unknown option,
uninstall; parsed by `dash` and BusyBox). When `tools/packaging/build/`
holds packages, it also unpacks them, reads each `pyk`'s architecture
from its Mach-O or ELF header (and that a Linux one is static), and
checks `SHA256SUMS` and both formulas against the files. It never runs
`brew`, `dpkg -i` or a release; `make packaging-install` installs. It takes
`--compiler PYK` like the others, a file rather than a command, since it
is what gets packaged.

**`tests/test_site.py` is the seventh suite**, and needs no Astro: it
checks that `tools/help/libdoc.py` finds nothing undocumented or
documented wrongly in `lib/`, that every name a library page lists is
one the module exports (a program importing them all must compile),
that every library example prints its ```` ```stdout ```` block, that the remark
plugin turns a page's Pyking blocks into the placeholders `mountCells`
reads, that no page in `sitesrc/` has a problem the notebook finds in
its exercises and quizzes, that the help's index and the website's left
menus list every page, that the website's runtime has every sound a
page plays, and that every runnable ```` ```pyking ```` block of the help's
pages -- `sitesrc/`, the language reference and the library pages --
runs under `pyk`, or is refused where it is marked `error`. It takes `--compiler CMD` like the others.

**`tests/test_tinyweb.py` is the eighth suite**, and covers what a
tinyweb program's log cannot: that every native implementation carries
the page as it is in `lib/tinyweb/` (`tools/tinyweb/embed_page.py
--check`); that on each native target a program calling anything
before `web_init`, or asking for a port there is none of, ends with
status 1 and says why; that each `lib_tinyweb_*` program, run with no
log set, serves its page, and that what arrives on `/commands` with its
`.events` posted to `/events` is its `.page`; that compiling one with
no `--output` brings `tinyweb_assets/` along on every target; and that
the web24
implementation, which draws directly and has no log, draws what the
command one does through `tinyweb_page.js` -- under node against a
recording page (`tests/tinyweb/dom.mjs`), and, where a Chromium is found
(`$PYKING_CHROME`, the `PATH`, or Playwright's download), in a real one
driven over the DevTools protocol (`tests/tinyweb/chrome.mjs`), along
with the iweb24 page and the page a program serves itself. Without a
Chromium that part says it was skipped. See `docs/libraries.md`,
"Testing a page".

**`tests/test_lsp.py` is the ninth suite**, the language server's. Each
`tests/lsp/<name>.lsp` is a session script (open, change, hover at
LINE:COLUMN, idle, ...; the grammar is in the suite's docstring) run
against `pyk lsp` over stdio, and what the server sent is compared with
`<name>.out` -- one script per capability, one for the protocol's own
edges, one where UTF-16 positions matter. Then the transport (a message
split across writes, a lower-case header, `--log`, the exit status, the
refusals); then the same scripts through `pykLsp` in `build/pyking.js`
under node (`tests/lsp/browser.mjs`), which must answer the same; then,
where a Chromium is found and Monaco is vendored, the playground driven
by `tests/lsp/playground.mjs` -- its editor as a language server
client, then its tabs (the Help tab among them), its REPL (entries, the
environment, Copy from editor, Stop) and its themes; and the editors' configuration -- the VS
Code extension's manifest and grammar, the Emacs mode's eglot entry, and
every snippet on the website's Editors page. `--update` rewrites the
`.out` files; read the diffs before keeping them.

A fifth family covers **external modules**: `external_*` for a module
implemented in a target language -- `external_all` on every host, and
`external_shapes` on the four whose boundary can carry a tuple and a
list -- `module_external_mixed` for a module in two halves -- `f1` from the
Pyking half, public `g1` from the host's, and `f2` from the Pyking half
calling the host's *private* `g2` -- and `fail_typecheck_external_*` for
what is refused: a bodiless signature in a plain `.pyk`, a declaration
file that also holds a body, a declaration naming a function type, and
reaching a private declaration from another module --
and `fail_typecheck_module_external_half` for importing a module's
`_external` half by that name. `module_external_mixed` runs on C and
Java too, which compile a module in two halves.
A `_external.pyk` is listed under the importing program's `modules`
like any other, and every such program lists `interpret`: the
interpreter loads its OCaml implementation as a plugin. The one rule
the suite does *not* pin is a missing implementation file: that refusal
is per-target, and the `fail_typecheck_*` convention runs on
`-t pyking`, which needs no implementation.

A sixth covers **the standard library's input, output and exit** and
**`debug`**: `lib_io_write`, `lib_io_read` (reading its sibling
`lib_io_read.in`), `lib_sys_exit` (`exit_code = 3`), `debug_basic` and
`debug_values` (each with a sibling `.err`, what `debug` wrote to
standard error), and `typecheck_release*` (`release = true`: compiled
with `--release`, and held to writing nothing on standard error).

A seventh covers **tinyweb**: `lib_tinyweb_*`, each with an `.events`
file and a `.page` file, run headless on every target but web24 --
`PYKING_TINYWEB_LOG` and `PYKING_TINYWEB_EVENTS` are set for every run
-- and `external_callback_named`, the callbacks C and Java can carry.
web24 and the servers are `tests/test_tinyweb.py`'s.

**Four kinds of expected output**, two of them about the tail-call
pass. `<name>.notail.ast.out` is what `-t pyking --no-tail-call-opt`
prints -- the program as *written*, where `.ast.out`
shows what the pass built -- and `<name>.notail.out` is what it prints
when run with the pass off, which must equal `<name>.out` exactly: the
pass may change how much room a program needs and never what it means.
The targets that read them are `pyking_notail` and `python14_notail`.
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
twice, and the four ways an export can fail to write its type down (no
annotations, only some of them, an unannotated `def` its own module
calls, and a value with no type on its name). `typecheck_module_public.pyk` is the one that pins the
printed AST, since it is the only place `import`, `from`, `as` and
`public` are printed back out at all.

Together they pin down both halves of the checker — what it infers, and
what it rejects and how it says so — while the backends keep the
programs honest. Adding a runnable target to a `typecheck_*` file is how
several backend bugs surfaced: a Java method name emitted as a value, a
Pyking expression statement emitted as a Java one, and calls to `str`,
`range` and `len` emitted as JavaScript that would not run.

**Every JavaScript runner disables node's module detection**
(`--no-experimental-detect-module`, `NODE` in the harness). A recent
node guesses whether a `.js` file is an ES module and quietly makes
output work that an older node refuses; turning the guess off means the
suite tests what the compiler actually *declares* -- a `package.json`
beside the output, or a `.mjs` name -- rather than what one node version
is willing to infer. Two bugs reached a user this way before it was
turned off.

**Every runner checks the exit status** (`executed` in the harness). A
program that prints and *then* dies leaves its prefix on stdout, so
comparing output alone would call a crash a pass whenever the surviving
prefix happened to match.

**No third-party dependencies.** Building the compiler needs OCaml and
dune; the playground's bundle additionally needs js_of_ocaml. The test
harness is Python 3.11+ (`match`/`case`, and `tomllib` for the
manifest), as are `make vendor` and the website build — tooling around
the compiler, not part of it. The web pages vendor Ace, Monaco and KaTeX, downloaded
by `make vendor`; nothing is installed. The one exception is the
website (`make website`): Astro and Starlight, pinned in
`tools/site/package-lock.json` and installed by `npm ci` into
`tools/site/node_modules/` on its first build. Nothing else -- not the
compiler, not the tests, not a distribution -- needs them.

Running the generated code needs `node` for
the JavaScript targets, a C compiler (`$CC`, default `cc`) for the C
ones, a JDK (`$JAVAC`/`$JAVA`) for the Java ones and an OCaml compiler
(`$OCAMLOPT`, default `ocamlopt`) for `ocaml5.5` — none of them
is needed to *produce* the code, and none at all to run a program with
`pyk <file>`. The OCaml cases are built with `-w +a` and linked with
`-I +unix unix.cmxa` (an external implementation may need `unix`, and
`lib/sys/sys_external.ml` does; see `docs/target_ocaml.md`, "Linking unix"):
that target's
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
- The plan's `Host` interface was to live in `runtime_interface.ml`, a
  module that no longer exists. The `Host` is in `interpreter.ml`, and
  the operations and their formatting rules are `builtin.ml`'s, beside
  every other builtin.
- The plan assumes the browser reaches the compiler through Pyodide.
  It does not any more: `src/web/` compiles the library itself to
  JavaScript with js_of_ocaml, so there is no Python runtime in the
  page. The plan's own table called that the eventual state; it arrived
  with the translation instead.
- `Diagnostic` values and parser error recovery (§5b) are not built.
  Errors are still one exception per stage carrying an `info`, and
  `pyk.ml`'s `format_error` is the one place they are worded.

Two language questions it raises are settled: an **`Int` holds at least
the signed 32-bit range, and past it overflow is undefined** (PYKING.md,
"Integer and string literals"; what each host does is in
`docs/targets.md`), and the **maximum call depth is
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
