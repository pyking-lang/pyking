# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code
in this repository.

## Project overview

Pyking is an early-stage compiler for a small Python-like language. It is
built to bootstrap: a throwaway implementation is written first in a
convenient host language, with the intent of eventually rewriting the
compiler in Pyking itself and compiling it with the throwaway one.
Concretely:

- `src/` holds the bootstrap implementation, split into one plain script
  module per compiler stage (see "Architecture" below) — it is *not* a
  Python package (no `__init__.py`, no relative imports); modules import
  each other directly (e.g. `from lexer import ...`), relying on Python
  adding `src/` to `sys.path` when `src/pykboot.py` is run directly. The
  eventual self-hosted rewrite — the compiler written in Pyking itself —
  is meant to replace these modules in place, here, rather than live in a
  second, separate directory; there is no other reserved location for it.
- `tests/` contains sample Pyking source programs (`.pyk`, not a pytest
  suite), each with a sibling `.out` file holding its expected stdout,
  plus `tests/test_cases.toml` (which program runs on which target) and
  `tests/test_script.py` (see "Running" below for how it uses both).
- `docs/` holds design notes; `docs/architecture.md` is the compiler-side
  counterpart to PYKING.md.

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
accepts, and one page per family (`target_python.md`, `target_js.md`,
`target_c.md`, `target_java.md`) for how constructs are compiled and
where the output is weak. `README.md` is a short index pointing at all
of it.
When a change touches how something *compiles* rather than what it
*means*, PYKING.md is not the file to edit.

**Static semantics are language, not compiler**, and they are the one
place PYKING.md names a flag. Its "Type checking" section documents both
layers — the name and scope rules every compile applies, and the types
`--typecheck` checks — including what the checker refuses and why, since
"which programs are well-typed" is a property of Pyking rather than of
the pass that decides it. Extending `src/typesystem.py` therefore means
editing that section too; `docs/architecture.md` keeps only how the pass
is *built* (its signature, `tmap`, `same_type`), and points at PYKING.md
for the rules.

## Changing the language: always update all five places

A change to what `src/` accepts is not finished until **every** one of
these is updated in the same change — none of them is optional, and the
last ones are the ones that get forgotten:

1. **`src/`** — the stage(s) implementing it (lexer → parser → syntax →
   `analyses.py` → `typesystem.py` → each backend). A new or changed AST
   node also means updating its `datatype` comment in `syntax.py` — see
   that module's entry below; nothing catches it drifting. `symbolize` needs
   nothing: its walk is generic over dataclass fields, so a new node in
   `syntax.py` gets a symbol for free. `typesystem.py` does need a
   decision, but only a cheap one — either check the construct or let it
   fall through to `Construct is not supported`, which is what every
   construct it has not reached yet already does. A construct that binds or uses a *name*
   always reaches `analyses.py`: it has to bind through `bind` (so the
   no-shadowing-a-`var` rule covers it) or be walked so its names are
   checked, or it silently escapes the analysis. Every backend needs a
   decision, not just the Python one: either translate the construct in
   `target_js_core.py`, `target_c.py` and `target_java.py` too, or leave
   it to each of those modules' `_unsupported` so that target refuses it
   with a source position. `target_ocaml.py` is the exception, and the
   reason to keep `typesystem.py` honest: it compiles exactly what the
   checker accepts, so a construct the checker refuses needs nothing
   there, and one the checker *starts* accepting needs a translation
   there or an explicit `_unsupported`.
2. **`tests/`** — at least one `.pyk` file exercising the new construct,
   with its `.out` captured from an actual run, **and an entry in
   `tests/test_cases.toml`** listing the targets it works on. The harness
   warns about a `.pyk` missing from the manifest, but a wrong target list
   just silently under-tests. If most of an existing test would work on
   the JS targets but one section would not, split it in two rather than
   marking the whole file python-only.
3. **`PYKING.md`** — feature summary, EBNF grammar, the grammar notes for
   anything the EBNF can't express, and a worked example. Language only:
   no targets or generated code. Its "Type checking" section is the
   exception that proves it — static semantics *are* language, so a
   change to what `analyses.py` or `typesystem.py` accepts belongs there
   too, `--typecheck` and all.
4. **`docs/`** — anything about *compiling*. `architecture.md` for the
   pipeline itself (a new stage or module, a change to how the driver
   works); `targets.md` for the target list and the shared-subset table;
   and the family page — `target_python.md`, `target_js.md`,
   `target_c.md`, `target_java.md`, `target_ocaml.md` — for what that
   family supports, how
   the construct is compiled, and where its output is not optimal. A
   construct a backend *refuses* belongs in its family page too, with the
   reason.
5. **`tools/emacs/pyking-mode.el`** — the editor mode claims in its own
   commentary to mirror `src/lexer.py` and `src/parser.py`, so it goes
   stale silently. Check each of these against the change:
   - `pyking-mode-keywords` / `pyking-mode-types` / `pyking-mode-constants`
     — together must still equal the `keywords` list in `src/lexer.py`
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

1. **`src/lexer.py`** — `Info` (a frozen dataclass carrying source location:
   `file`, `row1`, `col1`, `row2`, `col2`, attached to every token, used for
   error reporting), the Token ADT (each token kind is a frozen `@dataclass`
   subclassing the `Token` marker base class, e.g. `TokInt`, `TokIdent`,
   `TokAdd`, `TokDef` — this mirrors how the token type would be expressed
   as a variant type in a language that has them, which is what the
   self-hosted compiler will be written in; keep new token kinds in this
   same one-class-per-variant style rather than collapsing them into a
   single class with a `kind` field), `pprint_token`/`pprint_info`
   (pretty-printing via `match`/`case`, mirroring how the same code would
   pattern-match over that variant type), and the
   lexer itself: `lexing(file, chars)` consumes a list of characters
   (`list(str)`, not a string) via structural pattern matching (`match rest:
   case [x, *xs] ...`) and returns a list of tokens. Helpers:
   `string_until(pred, chars)` grabs the longest matching prefix,
   `scan_string` decodes a string literal's backslash escapes, `is_digit` /
   `is_letter` / `is_digit_letter` classify characters. Row/column tracking
   is done manually (`r, c`) as characters are consumed. Lexical errors
   raise `LexError(info, message)`.
2. **`src/syntax.py`** — the expression (`E*`) and statement (`S*`) AST
   dataclasses, one class per variant (same rationale as the Token ADT), and
   their pretty printers (`pprint_expr`, `pprint_stmt`, `pprint_program`).
   `pprint_program(stmts, symbols=False, tmap=None)` is the only entry
   point any caller uses; both of its options are module-level display
   flags it sets and restores around its one call, rather than
   parameters threaded through every printer. Given a `tmap` (the type
   checker's symbol → type table), every annotation printed comes from
   it and none from the AST — a node it does not know about prints no
   type at all, whatever the source wrote, since nothing has checked
   that annotation.
   Named `syntax.py`, not `ast.py`: `src/` is a flat set of script modules
   (not a package), so a module literally named `ast.py` would shadow the
   standard library `ast` module on `sys.path` — which breaks `dataclasses`
   itself (`dataclasses` → `inspect` → `annotationlib` needs the real `ast`
   at import time). Don't rename this back to `ast.py`.

   **The AST is documented as algebraic data types** in one block of
   `datatype` comments at the top of the file, listing every group's
   variants and their fields — `Expr`, `Type`, `Pattern`, `CompClause`,
   `AssignTarget`, `Stmt`, and the single-constructor `Param`,
   `ListRest` and `MatchCase`. They are gathered there, rather than each
   above its own base class, so the whole shape of the AST reads in one
   place and types that refer to each other can be compared without
   scrolling.

   Dataclasses can state a node's fields but not that the group is a
   *closed set of alternatives*, which is exactly what every
   `match`/`case` over the AST depends on, so the comments state it: one
   block tells you what a `match` on that type has to cover. The
   notation is OCaml-ish, with a legend beside it (`Int`/`String`/`Bool`
   for Python's `int`/`str`/`bool`, `[T]` for a list of `T`, `T?` for a
   field that may be `None`).

   **These are hand-written, so keep them in step with the code in the
   same change** — they are the one part of `syntax.py` nothing will
   catch when it drifts. Adding, removing or renaming a node, changing a
   field's name, type or optionality, or moving a node to a different
   base class all mean editing the `datatype` block too. Note `[T]`
   records something the annotation itself does not: a field is only
   annotated `list`, so the element type lives *only* in the comment and
   is worth getting right. The blocks are ordered alternatives-types
   first, then the single-constructor ones — deliberately *not* the
   order the classes are declared in, since a class has to wait for
   whatever it mentions (`EListComp` holds `[CompClause]`, so it is
   declared after `CompClause` despite being a variant of `Expr`). Put a
   new variant in the block for the type it belongs to, wherever the
   class itself has to sit.
3. **`src/parser.py`** — the recursive-descent parser (`parse_atom`,
   `parse_expr`, `parse_statement`, `parse`, ...) that consumes the token
   list and builds the AST from `src/syntax.py`. Each AST node's `info`
   spans from its first token's start to its last token's end, built via
   `combine_info(start, end)` — when adding a new grammar rule, combine
   infos the same way rather than reusing a single token's span. Parse
   errors raise `ParseError(info, message)`. A few restrictions that the
   grammar can't express are checked here too, so they fail at parse time
   with a source position rather than in a later stage: duplicate
   bindings in a pattern (`_check_no_duplicate_captures`) and the "every
   branch yields a value" rules of a value-form `if`/`match`
   (`_check_value_stmt`, on which `target_python.py` relies).
4. **`src/analyses.py`** — static analyses over the parsed AST, run
   between the parser and any backend (for every mode, `--ast` included);
   errors raise `AnalysisError(info, message)`. Currently one analysis,
   names: Pyking is lexically scoped, so `analyze_program` is a single
   recursive walk carrying a *name environment* (`dict` name → kind of
   binding) that is rebuilt rather than mutated — entering a nested scope
   is "keep using the environment you were handed", leaving one is "go
   back to the caller's", which is what makes a block's bindings unable
   to escape it. `analyze_stmt` returns the environment its statement
   leaves behind (that is how a statement sequence accumulates
   bindings); `analyze_scope` deliberately discards it. Everything that
   introduces a name funnels through `bind`, which is where the one
   shadowing rule lives (a `var` may not be shadowed by anything), so a
   new binding form only has to call it to be covered. `BUILTINS` seeds
   `print`/`range`/`str`/`len` so that every *other* unbound name can be
   an error — extend it when a program starts calling another builtin.
   Keep new analyses in this module as separate `analyze_*` entry points
   rather than folding more checking into the parser: the parser's job
   is shape, and only a scope-aware walk can judge names.
   `analyze_stmts` binds every `def` in a block *before* walking any of
   it, which is what makes functions usable ahead of their definition —
   recursion, mutual recursion, a helper at the bottom of the file — and
   is the one departure from binding in source order (see PYKING.md,
   "Names and scoping"). Only the *names*, and only functions': an `=`
   binding stays sequential, and what a body captures is whatever is
   bound where the body is written. **`block_functions`** is what makes
   hoisting a name safe — one `def` per name per block, and no other
   binding of that name there (`check_no_function_clash`), so a hoisted
   name has exactly one meaning in its block. `typesystem.py` imports
   both rather than restating them; keep it that way.

   Also here: **`symbolize`**, which gives every AST node a unique
   integer `sym` (post-order from 1; `0` means "not symbolized yet").
   Unlike `analyze_program` it *rewrites* — nodes are frozen, so it
   rebuilds the tree with `replace`. Its walk is generic over dataclass
   fields rather than one case per node type, so a node added to
   `syntax.py` is covered without touching it. A node that already has a
   symbol keeps it and new numbers continue past the highest in the
   tree, which is what makes it safe to run twice, should a pass ever
   synthesize nodes into an already-symbolized tree.
5. **`src/typesystem.py`** — the type checker, run only under
   `--typecheck`, after `symbolize` and before `--ast` prints anything;
   it runs *instead of* `analyze_program`, not after it (see
   `pykboot.py` below). One entry point, `type_check(stmts) -> tmap`: a
   whole program in, the types it worked out back.

   Inside, **one function per AST datatype** — `check_stmts` ([Stmt]),
   `check_stmt` (Stmt), `check_expr` (Expr), `check_param` (Param),
   `same_type` (Type) — each taking a node of exactly that type and
   returning exactly one kind of answer, with the signatures written out
   OCaml-style in a block near the top. Keep that shape when extending
   it: no function here dispatches on which *sort* of node it was handed,
   only on which variant of its own datatype. `Env` maps a name to its
   type and is used *immutably* — a binding hands what follows it an
   extended copy, the same discipline `analyses.py` follows.

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
   order. Mirror any change to it in `analyses.py` and in each backend's
   own declaration pass.

   **`Env` is also the scope**, and the checker does its own name
   checking with it: bound-before-use, block bindings that do not escape,
   shadowing, a `def`'s name in its own body, and `analyses.BUILTINS`
   (imported, not re-listed) in scope from the start. An unbound name
   raises `analyses.AnalysisError`, in its words, so the message does not
   depend on which pass ran. The value type is `Type?`: `None` means "in
   scope, no type here" — a `def` that is not fully annotated — and using
   one is `Construct is not supported`, not "unbound". A builtin is a
   third case: `env` maps `print`/`range`/`str`/`len` to a `Builtin`,
   checked at the call by `check_builtin_call` and refused as a value,
   because none of them fits a `TFunction` (a variadic `print` is not a
   `(T) -> ()`) and `runtime_interface.py` calls them operations rather
   than functions. A new builtin needs a case there as well as an entry
   in `analyses.BUILTINS`. The one rule still only
   in `analyses.py` is that a `var` may not be shadowed; this checker
   refuses `var` outright, so there is nothing here for it to protect
   yet. That is the last gap before the analysis can be deleted. `TMap` is
   the deliberate opposite: one mutable dict, mapping a node's *symbol*
   to the type inferred for it, built as the pass runs and returned as
   its result. **The checker does not
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
   `src/target_ocaml.py` does, and is the reason to keep making them: it
   compiles only what this checker accepts, so rather than inferring
   types a second time the way `target_c.py` and `target_java.py` each
   must, it reads them back from here. Types are `syntax.py`'s own
   `T*` nodes, not a separate vocabulary, so a checked binding prints as
   `x: Int = 1` — syntax the parser accepts, which keeps
   `--typecheck --ast` output re-parsable; they are synthesized here, so
   they carry no symbols. That includes `TFunction`, `(Int, Bool) -> Int`,
   which `parse_type` reads as well as prints, so `g: (Int) -> Int = f`
   round-trips like anything else. Compare types with `same_type`, never
   `==`: `T*` nodes are dataclasses, so `==` compares `info` and `sym`
   too.

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
   being a special case. Recursion is refused: the function's own name is
   left unbound while its body is checked — *removed* from the body's
   environment rather than merely not added, since a `def`'s name is in
   scope in its own body and an outer binding of it must not show
   through.

   Everything outside that fragment raises
   `TypeError_(info, "Construct is not supported")` — including a name
   it cannot find, since no name analysis has run ahead of it in this
   mode. Keep that floor explicit rather than silently accepting what it
   has not reasoned about.
6. **`src/runtime_interface.py`** — the boundary between pure Pyking code
   and the outside world, in the spirit of WebAssembly's split between a
   core language that cannot observe anything and a separate host spec.
   Backend-agnostic by construction: it holds no Python and no JavaScript,
   only the named operations (today just `print`) and their semantics,
   *including* the value-formatting rules, since every backend has to
   agree on those for one program to print the same characters
   everywhere. Add an operation here first; the backends then bind it.
7. **`src/target_js_core.py`** — the JavaScript backend's language half:
   a `Js*` AST, translation from `syntax.py`, and a printer. Knows nothing
   about packaging. Calls that cross the runtime interface become
   `JsRuntimeCall`, whose spelling is supplied by the packager, so the
   same core output serves all three JS targets. JavaScript fits Pyking
   better than Python does — `const`/`let` are Pyking's `=`/`var`, and
   `{ }` blocks are scopes — so it renames only where JavaScript forces
   it (`const` redeclaration, and the temporal dead zone), not on every
   shadow the way `target_python.py` must. Constructs outside the
   supported subset raise `UnsupportedError`, which carries an `Info`.
8. **`src/target_js_packaging.py`** — the JavaScript backend's packaging
   half: wraps core output into `nodejs` (one self-contained script),
   `html` (one self-contained page printing into a visible box), and `esm`
   (a module exporting `run(runtime)`, plus a node driver and an HTML
   wrapper derived from the `--output` path). It owns the JavaScript side
   of the runtime interface — each host's `print` and the shared
   `pykFormat` — which is exactly what differs between the three.
9. **`src/target_c.py`** — the C backend, serving both the `c89` and
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
   `UnsupportedError` with the `Info` rather than emitting C that will
   not compile.
10. **`src/target_java.py`** — the Java backend, serving `java8`,
   `java17` and `java21`: a `J*` AST, translation, and a printer taking a
   `version` parameter, the same shape `target_c.py` uses for `standard`
   — one backend because the three versions disagree only in whether a
   local declaration writes `var` (Java 10's local-variable type
   inference, absent from java8) or spells its type out. Infers types the
   same way `target_c.py` does (`Int`/`String`/`Bool`, from initializers,
   annotations, and translated return bodies), and additionally checks
   that every function provably returns on every path
   (`_definitely_returns`) and that no statement follows one that always
   does (`_check_reachable`), since `javac` — unlike `cc` — refuses to
   compile either. Needs no runtime helper the way C's `pyk_concat` and
   `strcmp` are: string concatenation is Java's own `+`, and equality is
   `.equals()`. The output file and its class are named in Java's own
   style rather than the source's, since Java requires the two to match
   (`default_class_name`; see `pykboot.py` below for where the exception
   is applied).
11. **`src/target_ocaml.py`** — the OCaml backend, serving the `ocaml`
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
12. **`src/target_python.py`** — the Python code-generation backend: its
   own `Py*` AST (`PyInt`, `PyAssign`, `PyFor`, ... — structurally the same
   shape as `src/syntax.py`'s `E*`/`S*`, except Pyking's `SLet`/`SVar`/
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
   comprehension, where Python already scopes), `translate_program`/
   `translate_stmt`/`translate_expr` (Pyking AST → `Py*` AST; statement
   translators return `(node, scope)` so a sequence accumulates
   bindings, and a caller entering a block discards the returned scope;
   each `match`
   ends in a `case _: raise NotImplementedError(...)` so a future Pyking
   construct without a translation fails loudly rather than silently
   returning `None`), and `pprint_py_expr`/`pprint_py_stmt`/
   `pprint_py_program` (Py* AST → Python source text). It was the first
   backend and the JavaScript ones followed the same shape — keep it
   independent of `syntax.py`'s pretty-printing internals so the next one
   can too, without entangling target-specific logic into the Pyking
   AST/pretty-printer. `_declare_functions` binds every `def` in a block
   before translating it, mirroring the front end: Python resolves a
   forward reference by itself at call time, but a *renamed* function
   (`helper2`) has to be renamed before the call written above it is
   emitted. `target_js_core.py` does the same for the same reason; C and
   Java instead register signatures ahead (and C prints prototypes),
   since those two have to know a function exists before a call names
   it. Two analyses carry the scoping story the rest of the way, both in
   `target_python.py`: **`_free_names`** (a scope renames a binding that
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
13. **`src/pykboot.py`** — the entry point: parses `--tokens`/`--ast`/
   `--symbols`/`--typecheck`/`--stdout`/`--output <file>`/
   `--target|-t <target>`/the filename from argv, runs `lexer.lexing`,
   `parser.parse`, `analyses.analyze_program` and `analyses.symbolize`,
   optionally `typesystem.type_check`, then dispatches on the target.
   Catches `LexError`/`ParseError`/`AnalysisError`/`TypeError_`/
   `UnsupportedError` and prints a `'file' row:col-row:col ...` message
   to stderr (`Lexing error` / `Parsing error` / `Name error` /
   `Type error` / `Unsupported by target '<t>'`). Every message it
   prints goes through `wrap`, which reflows to 70 columns. The name
   analysis runs for every mode, `--ast` included — an AST whose names
   don't resolve is not worth printing or compiling — *except*
   `--typecheck`, which replaces it: the type checker's environment *is*
   a scope, so it checks names itself and raises the analysis's own
   `AnalysisError` for one it cannot find — which is why this driver
   catches that around `type_check` too, and prints the same `Name
   error` either way. `symbolize` still runs in every
   mode, since `tmap` is keyed by symbol; nothing needs symbolizing
   again afterwards, because the checker synthesizes nothing into the
   tree. The `tmap` it produces is handed to `pprint_program`, so a
   `--typecheck --ast` run prints inferred types rather than written
   ones. Every flag has a
   default: `--target` is `python`, and with no `--ast`/`--stdout`/
   `--output` the program is compiled to a file named from the source
   stem and the target's extension — except the Java targets, where the
   driver instead calls `target_java.default_class_name(stem)`, since
   Java requires the file and its public class to match and the source's
   own spelling usually isn't a legal, correctly-cased class name. `--ast`
   prints the *Pyking* AST via `syntax.pprint_program` and returns before
   any backend runs, since that AST is what every target shares. Keep the
   driver thin: it sequences stages and reports errors, and each backend
   owns its own translation, packaging, and file naming (`esm` writing
   three files is `target_js_packaging.package`'s business, not the
   driver's; deriving a Java class name from an explicit `--output` is
   `target_java.py`'s, by the same principle).

When extending the lexer (new operators, keywords, string escapes, etc.),
follow the existing pattern: add a `case [...]:` arm in the `match rest:`
block inside `lexing`, add a corresponding `Tok*` dataclass, and add a
`case Tok*():` arm to `pprint_token`.

## Running

```
pyk [--tokens] [--symbols] [--typecheck] [--target|-t <target>]
    [--ast | --stdout | --output <file>] <filename>
```

(`pyk` is the wrapper script at the repository root; it forwards every
flag to `src/pykboot.py` untouched. Run it with no arguments for the
usage message, which is generated from `TARGETS`/`EXTENSIONS` and
reflowed to 70 columns by `wrap`, along with every error the driver
prints.)

`--tokens` prints the token stream first (in addition to whatever else
happens). The other three select what to do, and none of them is
required:

- `--ast` stops after the front end and prints the pretty-printed *Pyking*
  AST. Target-independent, so it ignores `--target`. `--symbols` adds
  each node's symbol as an `@n` suffix; `--typecheck` runs the type
  checker first, so the printed AST carries the types it inferred.
- `--stdout` compiles and prints the generated source. For `esm`, whose
  wrappers only exist as files, this prints the module alone.
- `--output <file>` compiles and writes to `<file>`. A single-file target
  writes exactly that path; `esm` reads it as a *stem* and names its own
  files, so `--output out/prog`, `out/prog.js` and `out/prog.html` all
  produce `out/prog.js` (module), `out/prog.node.js` (driver),
  `out/prog.html`, and `out/package.json` (`{"type": "module"}`, which is
  what lets the first two be plain `.js`). An existing `package.json` is
  never overwritten — it belongs to the surrounding project.
- With none of them, the compiler names the file: the source's own stem
  plus the target's extension (`EXTENSIONS` in `pykboot.py`, fed by each
  backend), in the *current* directory — `-t nodejs tests/hello.pyk`
  writes `./hello.js`. Writing over the input, or into a directory that
  doesn't exist, is a usage error rather than a traceback, checked per
  file since `esm` writes three. The Java targets are the exception: the
  default name is Java-cased instead of the source's own stem, since Java
  requires the file and its public class to match exactly — `-t java21
  tests/foo_bar.pyk` writes `./FooBar.java`, not `./foo_bar.java`.

`--target`/`-t` selects the backend: `python` (the default), `nodejs`,
`html`, `esm`, `c89`, `c23`, `java8`, `java17`, `java21`, or `ocaml`.
Targets come in groups sharing a backend: the JavaScript three differ
only in `src/target_js_packaging.py`, the C two only in a `standard`
parameter to `src/target_c.py`'s printer, and the Java three only in a
`version` parameter to `src/target_java.py`'s printer; `ocaml` is a
family of one. All of them support a subset of the language, and
anything outside it is refused at compile time with a source position
rather than emitted as code that will not build. `ocaml` is the one
whose subset is not a list it maintains: it is whatever
`src/typesystem.py` accepts, checked by running it. See
`docs/architecture.md` for the subsets and the target table.

The `pyk` wrapper script at the repository root forwards flags as-is
(`./pyk --ast <file>`, `./pyk -t nodejs --stdout <file>`, ...), but adds
one convenience: called with *only* a filename and no flags, it compiles
to a temp file, runs it with `python3`, and removes the temp file
afterward (even if compiling or running fails) — i.e. `./pyk <file>` is
the "just run it" shorthand that no longer exists as `src/pykboot.py`'s
own default.

Plain `make` with no target prints the help: the `Makefile`'s first rule,
`all`, is `help`, since nothing here is built and someone typing `make`
is asking what they can run. That help list is hand-written, as is the
one in `tools/playground/Makefile` it is modelled on — add a target and
you have to add its line too. `make clean` removes `__pycache__`
directories and delegates the playground's `build/` to that directory's
own Makefile; `make distclean` also drops its `vendor/` download cache.
Neither touches *compiled programs*: `pyk` writes them wherever the
caller asked, under names indistinguishable from hand-written source in
every target language, so a clean rule that guessed at them would
eventually delete someone's own file. Keep it that way.

`make test` runs `tests/test_script.py`. It
reads `tests/test_cases.toml`, and for every (program, target) pair the
manifest declares, compiles the program to a temp directory, runs it the
way a user would — `python3` on the `.py`, `node` on the `.js`, `node` on
the *generated driver* for `esm`, `cc`/`javac`/`ocamlfind ocamlopt` and
then the binary for the C, Java and OCaml targets, and, for `html`, the
page's extracted module under a small `document` stub — and compares
stdout against the sibling `.out` file. One `.out` serves every target, which is the property
being tested. It warns about any `.pyk` missing from the manifest and
prints a per-target summary.

**Two kinds of expected output.** `<name>.out` is what the program
*prints*, and every backend is compared against that one file.
`<name>.ast.out` is what `pyk --typecheck --ast` prints for it — the
program with the types the checker inferred — and only the `typecheck`
target reads it. Keep the distinction: a `.out` is never an AST.

`typecheck` is a target in that list but not a backend: it compiles and
runs nothing. Two filename prefixes say what to expect:

- **`typecheck_*.pyk`** must type-check, and its `.ast.out` holds the
  *printed AST*, pinning the types inferred. It **also lists real
  backends**, so the program whose types are pinned is one that actually
  compiles and runs; its `.out` is that run's output, empty if it prints
  nothing. The harness warns if such a file lists no backend, because a
  type nobody executes is a type nobody has tested.
- **`fail_typecheck_*.pyk`** must **not** type-check, and its
  `.ast.out` holds the *error message*. It lists exactly
  `targets = ["typecheck"]`: a program written to be refused is not one
  to run.

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

No third-party dependencies. Requires Python 3.11+ (`match`/`case`, and
`tomllib` for the manifest). Running the generated code needs `node` for
the JavaScript targets, a C compiler (`$CC`, default `cc`) for the C
ones, a JDK (`$JAVAC`/`$JAVA`) for the Java ones and an OCaml compiler
(`$OCAMLOPT`, default `ocamlfind ocamlopt`) for `ocaml` — none of them
is needed to *produce* the code, so the compiler itself stays
Python-only. The OCaml cases are built with `-w +a`: that target's
promise is clean OCaml, so a warning about generated code fails the
test.

## Where the project is going

**`design/plan-eval-lsp.md`** is the plan for the next large piece of
work: an interpreter (`pyk <file>` runs rather than compiles), a REPL
(`pyk repl`), step debugging in the playground, and LSP and DAP servers
with editor integration. Read it before adding anything in that
direction — it settles several things by design rather than by accident:

- the evaluator is a **resumable machine over the AST** in `src/`, not a
  second compilation to Python and not (yet) a bytecode VM;
- **one debug session core and one query core, both protocol-free**, so
  DAP and the playground are two transports over one session, and LSP
  and in-browser editor help are two transports over one query service;
- the servers stay **Python reusing `src/`**, with thin per-editor shims,
  because the browser already runs the compiler under Pyodide;
- **four new modules in `src/`**, with name resolution folded into
  `analyses.py` and the `Host` protocol into `runtime_interface.py`;
- what the machine may assume about its host, so none of it blocks the
  eventual self-hosted, machine-code Pyking.

Two language questions it raises are still open and worth settling
before that work starts: what `Int` is (Python's arbitrary precision
against C's and Java's fixed width), and the maximum call depth.

## Repository housekeeping

- Editor backup files ending in `~` (e.g. `tests/arithmetic.py~`,
  `.gitignore~`) or in `#...#` (Emacs auto-save), and any `__pycache__`
  directory, are untracked scratch content, wherever they turn up (`src/`
  included) — don't treat them as authoritative source, and don't assume
  they should be committed.
