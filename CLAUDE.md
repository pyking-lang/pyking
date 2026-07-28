# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code
in this repository.

## Project overview

Pyking is an early-stage compiler/interpreter project for a small Python-like
language. It follows the same "boot" bootstrapping pattern used by the Miking
project (KTH): a throwaway bootstrap implementation is written first in a
convenient host language, with the intent of eventually self-hosting the
compiler in the target/meta language itself. Concretely:

- `boot/` holds the bootstrap implementation, split into one plain script
  module per compiler stage (see "Architecture" below) — it is *not* a
  Python package (no `__init__.py`, no relative imports); modules import
  each other directly (e.g. `from lexer import ...`), relying on Python
  adding `boot/` to `sys.path` when `boot/pykboot.py` is run directly. An
  earlier version of the bootstrap was written in OCaml (`ast.ml`,
  `lexer.ml`, `pykboot.ml`); it was removed on 2026-07-16 in favor of the
  Python rewrite — don't reintroduce `.ml` files unless asked.
- `src/` is reserved for the eventual self-hosted implementation written in
  Miking (`.mc` files). It's currently empty of tracked content.
- `tests/` contains sample Pyking source programs (`.pyk`, not a pytest
  suite), each with a sibling `.out` file holding its expected stdout, plus
  `tests/test_script.py` (see "Running" below for how it uses these), and
  usable standalone via:
  ```
  python3 boot/pykboot.py tests/test1.pyk
  ```

## Pyking language reference

**`PYKING.md`** (repository root) is the language design reference: a
feature summary, a full EBNF grammar, and a worked example for every
supported construct (literals, operators, `var`/`:=` mutation vs. `=`
immutable binding, `for`/`while`/`if`, functions, indentation rules, error
message format, etc.). Read it before writing or editing any Pyking source
(e.g. the `.pyk` files under `tests/`) — it reflects exactly what the
current bootstrap parser accepts, which is not the same as full Python.
Keep it in sync whenever `boot/`'s language support changes.

## Changing the language: always update all four places

A change to what `boot/` accepts is not finished until **every** one of
these is updated in the same change — none of them is optional, and the
last two are the ones that get forgotten:

1. **`boot/`** — the stage(s) implementing it (lexer → parser → syntax →
   each `target_*.py` backend).
2. **`tests/`** — at least one `.pyk` file exercising the new construct,
   with its `.out` file captured from an actual run (`make test`).
3. **`PYKING.md`** — feature summary, EBNF grammar, the grammar notes for
   anything the EBNF can't express, and a worked example.
4. **`tools/emacs/pyking-mode.el`** — the editor mode claims in its own
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
   as an OCaml/Miking variant type; keep new token kinds in this same
   one-class-per-variant style rather than collapsing them into a single
   class with a `kind` field), `pprint_token`/`pprint_info` (pretty-printing
   via `match`/`case`, mirroring OCaml-style pattern matching), and the
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
4. **`boot/target_python.py`** — the Python code-generation backend: its
   own `Py*` AST (`PyInt`, `PyAssign`, `PyFor`, ... — structurally the same
   shape as `boot/syntax.py`'s `E*`/`S*`, except Pyking's `SLet`/`SVar`/
   `SMutate` all collapse into one `PyAssign`, since Python has no
   mutable-vs-immutable-binding distinction, and `SLetStmt` — an
   `if`/`match` statement bound with `=`, see PYKING.md — has no node of
   its own at all, since it compiles to the ordinary `PyIf`/`PyMatch`
   with a `PyAssign` pushed into each branch's tail), `translate_program`/
   `translate_stmt`/`translate_expr` (Pyking AST → `Py*` AST; each `match`
   ends in a `case _: raise NotImplementedError(...)` so a future Pyking
   construct without a translation fails loudly rather than silently
   returning `None`), and `pprint_py_expr`/`pprint_py_stmt`/
   `pprint_py_program` (Py* AST → Python source text). This is the first
   of what should eventually be multiple interchangeable backends — keep
   it independent of `syntax.py`'s pretty-printing internals so future
   backends (e.g. `target_ocaml.py`) can be added the same way, without
   entangling target-specific logic into the Pyking AST/pretty-printer.
5. **`boot/pykboot.py`** — the entry point: parses `--tokens`/`--ast`/
   `--stdout`/`--output <file>`/the filename from argv, calls
   `lexer.lexing` and `parser.parse`, catches `LexError`/`ParseError` to
   print a `'file' row:col-row:col ...` message to stderr. Exactly one of
   `--ast`, `--stdout`, or `--output <file>` must be given — there is no
   default action, and passing none of them is a usage error. With
   `--ast`, prints the pretty-printed *Pyking* AST via
   `syntax.pprint_program` (this used to be the only/default behavior).
   Otherwise it compiles: translates to the Python target AST and
   pretty-prints it, then either prints that to stdout (`--stdout`) or
   writes it to the path given by `--output` (refusing to run if that
   path would overwrite the input file itself).

When extending the lexer (new operators, keywords, string escapes, etc.),
follow the existing pattern: add a `case [...]:` arm in the `match rest:`
block inside `lexing`, add a corresponding `Tok*` dataclass, and add a
`case Tok*():` arm to `pprint_token`.

## Running

```
python3 boot/pykboot.py [--tokens] (--ast | --stdout | --output <file>) <filename>
```

`--tokens` prints the token stream first (in addition to whatever else
happens). Exactly one of the other three flags is required — there is no
default action:

- `--ast` stops after parsing and prints the pretty-printed *Pyking* AST
  instead of compiling.
- `--stdout` compiles (translating to the Python target AST via
  `boot/target_python.py`) and prints the generated Python source to
  stdout.
- `--output <file>` compiles the same way and writes the generated Python
  source to `<file>`, refusing to run if `<file>` would overwrite the
  input.

There's no `--target` flag yet — Python is the only backend, so a
target-selection flag would be speculative; add one if/when a second
backend is implemented.

The `pykboot` wrapper script at the repository root forwards flags as-is
(`./pykboot --ast <file>`, etc.), but adds one convenience: called with
*only* a filename and no flags, it compiles to a temp file, runs it with
`python3`, and removes the temp file afterward (even if compiling or
running fails) — i.e. `./pykboot <file>` is the "just run it" shorthand
that no longer exists as `boot/pykboot.py`'s own default.

`make test` runs `tests/test_script.py` (plain `make` with no target does
nothing — the `Makefile`'s first rule, `all`, is intentionally empty), which
compiles every `tests/*.pyk` file via
`--output <tempfile>` (a real temp file, from Python's `tempfile` module),
executes the result with `python3`, and compares its stdout against the
sibling `tests/*.out` file (captured once, ahead of time, as the expected
output) — then deletes the temp file again.

No dependencies beyond the Python standard library (`dataclasses`, `sys`).
Requires Python 3.10+ for `match`/`case` statements.

## Repository housekeeping

- Editor backup files ending in `~` (e.g. `tests/arithmetic.py~`,
  `.gitignore~`) and the `src/` directory are untracked/gitignored scratch
  content — don't treat them as authoritative source, and don't assume
  they should be committed.
