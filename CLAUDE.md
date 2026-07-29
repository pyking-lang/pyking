# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code
in this repository.

## Project overview

Pyking is an early-stage compiler for a small Python-like language. It is
built to bootstrap: a throwaway implementation is written first in a
convenient host language, with the intent of eventually rewriting the
compiler in Pyking itself and compiling it with the throwaway one.
Concretely:

- `boot/` holds the bootstrap implementation, split into one plain script
  module per compiler stage (see "Architecture" below) — it is *not* a
  Python package (no `__init__.py`, no relative imports); modules import
  each other directly (e.g. `from lexer import ...`), relying on Python
  adding `boot/` to `sys.path` when `boot/pykboot.py` is run directly.
- `src/` is reserved for the eventual self-hosted implementation — the
  compiler written in Pyking. It's currently empty of tracked content.
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
Keep it in sync whenever `boot/`'s language support changes.

PYKING.md is **language-only**: nothing about compiler flags, targets,
generated code, or the test harness belongs there. That material lives in
**`docs/architecture.md`** — the pipeline, the four backends, the runtime
interface, and how the tests work — and `README.md` is a short index
pointing at both. When a change touches how something *compiles* rather
than what it *means*, it is architecture.md that needs updating.

## Changing the language: always update all five places

A change to what `boot/` accepts is not finished until **every** one of
these is updated in the same change — none of them is optional, and the
last ones are the ones that get forgotten:

1. **`boot/`** — the stage(s) implementing it (lexer → parser → syntax →
   `analyses.py` → each backend). A construct that binds or uses a *name*
   always reaches `analyses.py`: it has to bind through `bind` (so the
   no-shadowing-a-`var` rule covers it) or be walked so its names are
   checked, or it silently escapes the analysis. Every backend needs a
   decision, not just the Python one: either translate the construct in
   `target_js_core.py` too, or leave it to that module's `_unsupported`
   so the JS targets refuse it with a source position.
2. **`tests/`** — at least one `.pyk` file exercising the new construct,
   with its `.out` captured from an actual run, **and an entry in
   `tests/test_cases.toml`** listing the targets it works on. The harness
   warns about a `.pyk` missing from the manifest, but a wrong target list
   just silently under-tests. If most of an existing test would work on
   the JS targets but one section would not, split it in two rather than
   marking the whole file python-only.
3. **`PYKING.md`** — feature summary, EBNF grammar, the grammar notes for
   anything the EBNF can't express, and a worked example. Language only:
   no flags, targets, or generated code.
4. **`docs/architecture.md`** — anything about *compiling*: a new stage or
   module in the pipeline diagram, a change to a target's output or file
   set, a widening of the JavaScript subset, a new difference between
   targets.
5. **`tools/emacs/pyking-mode.el`** — the editor mode claims in its own
   commentary to mirror `boot/lexer.py` and `boot/parser.py`, so it goes
   stale silently. Check each of these against the change:
   - `pyking-mode-keywords` / `pyking-mode-types` — must still equal the
     `keywords` list in `boot/lexer.py`;
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

## Architecture of `boot/`

The bootstrap is split into one module per compiler stage:

1. **`boot/lexer.py`** — `Info` (a frozen dataclass carrying source location:
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
2. **`boot/syntax.py`** — the expression (`E*`) and statement (`S*`) AST
   dataclasses, one class per variant (same rationale as the Token ADT), and
   their pretty printers (`pprint_expr`, `pprint_stmt`, `pprint_program`).
   Named `syntax.py`, not `ast.py`: `boot/` is a flat set of script modules
   (not a package), so a module literally named `ast.py` would shadow the
   standard library `ast` module on `sys.path` — which breaks `dataclasses`
   itself (`dataclasses` → `inspect` → `annotationlib` needs the real `ast`
   at import time). Don't rename this back to `ast.py`.
3. **`boot/parser.py`** — the recursive-descent parser (`parse_atom`,
   `parse_expr`, `parse_statement`, `parse`, ...) that consumes the token
   list and builds the AST from `boot/syntax.py`. Each AST node's `info`
   spans from its first token's start to its last token's end, built via
   `combine_info(start, end)` — when adding a new grammar rule, combine
   infos the same way rather than reusing a single token's span. Parse
   errors raise `ParseError(info, message)`. A few restrictions that the
   grammar can't express are checked here too, so they fail at parse time
   with a source position rather than in a later stage: duplicate
   bindings in a pattern (`_check_no_duplicate_captures`) and the "every
   branch yields a value" rules of a value-form `if`/`match`
   (`_check_value_stmt`, on which `target_python.py` relies).
4. **`boot/analyses.py`** — static analyses over the parsed AST, run
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
5. **`boot/runtime_interface.py`** — the boundary between pure Pyking code
   and the outside world, in the spirit of WebAssembly's split between a
   core language that cannot observe anything and a separate host spec.
   Backend-agnostic by construction: it holds no Python and no JavaScript,
   only the named operations (today just `print`) and their semantics,
   *including* the value-formatting rules, since every backend has to
   agree on those for one program to print the same characters
   everywhere. Add an operation here first; the backends then bind it.
6. **`boot/target_js_core.py`** — the JavaScript backend's language half:
   a `Js*` AST, translation from `syntax.py`, and a printer. Knows nothing
   about packaging. Calls that cross the runtime interface become
   `JsRuntimeCall`, whose spelling is supplied by the packager, so the
   same core output serves all three JS targets. JavaScript fits Pyking
   better than Python does — `const`/`let` are Pyking's `=`/`var`, and
   `{ }` blocks are scopes — so it renames only where JavaScript forces
   it (`const` redeclaration, and the temporal dead zone), not on every
   shadow the way `target_python.py` must. Constructs outside the
   supported subset raise `UnsupportedError`, which carries an `Info`.
7. **`boot/target_js_packaging.py`** — the JavaScript backend's packaging
   half: wraps core output into `nodejs` (one self-contained script),
   `html` (one self-contained page printing into a visible box), and `esm`
   (a module exporting `run(runtime)`, plus a node driver and an HTML
   wrapper derived from the `--output` path). It owns the JavaScript side
   of the runtime interface — each host's `print` and the shared
   `pykFormat` — which is exactly what differs between the three.
8. **`boot/target_python.py`** — the Python code-generation backend: its
   own `Py*` AST (`PyInt`, `PyAssign`, `PyFor`, ... — structurally the same
   shape as `boot/syntax.py`'s `E*`/`S*`, except Pyking's `SLet`/`SVar`/
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
   AST/pretty-printer.
9. **`boot/pykboot.py`** — the entry point: parses `--tokens`/`--ast`/
   `--stdout`/`--output <file>`/`--target|-t <target>`/the filename from
   argv, runs `lexer.lexing`, `parser.parse` and
   `analyses.analyze_program`, then dispatches on the target. Catches
   `LexError`/`ParseError`/`AnalysisError`/`UnsupportedError` and prints a
   `'file' row:col-row:col ...` message to stderr (`Lexing error` /
   `Parsing error` / `Name error` / `Unsupported by target '<t>'`). The
   analysis runs for every mode, `--ast` included — an AST whose names
   don't resolve is not worth printing or compiling. Every flag has a
   default: `--target` is `python`, and with no `--ast`/`--stdout`/
   `--output` the program is compiled to a file named from the source
   stem and the target's extension. `--ast`
   prints the *Pyking* AST via `syntax.pprint_program` and returns before
   any backend runs, since that AST is what every target shares. Keep the
   driver thin: it sequences stages and reports errors, and each backend
   owns its own translation, packaging, and file naming (`esm` writing
   three files is `target_js_packaging.package`'s business, not the
   driver's).

When extending the lexer (new operators, keywords, string escapes, etc.),
follow the existing pattern: add a `case [...]:` arm in the `match rest:`
block inside `lexing`, add a corresponding `Tok*` dataclass, and add a
`case Tok*():` arm to `pprint_token`.

## Running

```
python3 boot/pykboot.py [--tokens] [--target|-t <target>] [--ast | --stdout | --output <file>] <filename>
```

`--tokens` prints the token stream first (in addition to whatever else
happens). The other three select what to do, and none of them is
required:

- `--ast` stops after the front end and prints the pretty-printed *Pyking*
  AST. Target-independent, so it ignores `--target`.
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
  file since `esm` writes three.

`--target`/`-t` selects the backend: `python` (the default), `nodejs`,
`html`, or `esm`. The JavaScript targets share `boot/target_js_core.py`
and differ only in `boot/target_js_packaging.py`; they support a subset of
the language, and anything outside it is refused at compile time with a
source position rather than emitted as broken JavaScript. See
`docs/architecture.md` for the subset and the target table.

The `pyk` wrapper script at the repository root forwards flags as-is
(`./pyk --ast <file>`, `./pyk -t nodejs --stdout <file>`, ...), but adds
one convenience: called with *only* a filename and no flags, it compiles
to a temp file, runs it with `python3`, and removes the temp file
afterward (even if compiling or running fails) — i.e. `./pyk <file>` is
the "just run it" shorthand that no longer exists as `boot/pykboot.py`'s
own default.

`make test` runs `tests/test_script.py` (plain `make` with no target does
nothing — the `Makefile`'s first rule, `all`, is intentionally empty). It
reads `tests/test_cases.toml`, and for every (program, target) pair the
manifest declares, compiles the program to a temp directory, runs it the
way a user would — `python3` on the `.py`, `node` on the `.js`, `node` on
the *generated driver* for `esm`, and, for `html`, the page's extracted
module under a small `document` stub — and compares stdout against the
sibling `.out` file. One `.out` serves every target, which is the property
being tested. It warns about any `.pyk` missing from the manifest and
prints a per-target summary.

No third-party dependencies. Requires Python 3.11+ (`match`/`case`, and
`tomllib` for the manifest); the JavaScript targets need `node` to *run*
their output, but not to produce it.

## Repository housekeeping

- Editor backup files ending in `~` (e.g. `tests/arithmetic.py~`,
  `.gitignore~`) and the `src/` directory are untracked/gitignored scratch
  content — don't treat them as authoritative source, and don't assume
  they should be committed.
