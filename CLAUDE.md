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
- `tests/` contains sample source programs (not a pytest suite), exercised
  by `test.py`/`make test` (see "Running" below) and usable standalone via:
  ```
  python3 boot/pykboot.py tests/test1.py
  ```

## Pyking language reference

**`PYKING.md`** (repository root) is the language design reference: a
feature summary, a full EBNF grammar, and a worked example for every
supported construct (literals, operators, `var`/`:=` mutation vs. `=`
immutable binding, `for`/`while`/`if`, functions, indentation rules, error
message format, etc.). Read it before writing or editing any Pyking source
(`.pyk` or the Python-subset `.py` files under `tests/`) — it reflects
exactly what the current bootstrap parser accepts, which is not the same as
full Python. Keep it in sync whenever `boot/`'s language support changes.

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
   errors raise `ParseError(info, message)`.
4. **`boot/pykboot.py`** — the entry point: parses `--tokens`/the filename
   from argv, calls `lexer.lexing` and `parser.parse`, catches `LexError`/
   `ParseError` to print a `'file' row:col-row:col ...` message to stderr,
   and prints the pretty-printed AST via `syntax.pprint_program`.

When extending the lexer (new operators, keywords, string escapes, etc.),
follow the existing pattern: add a `case [...]:` arm in the `match rest:`
block inside `lexing`, add a corresponding `Tok*` dataclass, and add a
`case Tok*():` arm to `pprint_token`.

## Running

```
python3 boot/pykboot.py [--tokens] <filename>
```

or equivalently, via the `pykboot` wrapper script at the repository root:

```
./pykboot [--tokens] <filename>
```

`--tokens` additionally prints the token stream before the pretty-printed
AST; without it, only the AST is printed. `make test` runs `test.py`, which
lexes/parses/pretty-prints every `tests/*.py` file and checks that running
the original and the regenerated source with `python3` produces identical
stdout.

No dependencies beyond the Python standard library (`dataclasses`, `sys`).
Requires Python 3.10+ for `match`/`case` statements.

## Repository housekeeping

- Editor backup files ending in `~` (e.g. `boot/tests/variables.py~`,
  `.gitignore~`) and the `src/` directory are untracked/gitignored scratch
  content — don't treat them as authoritative source, and don't assume
  they should be committed.
