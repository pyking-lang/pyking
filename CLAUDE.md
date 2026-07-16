# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code
in this repository.

## Project overview

Pyking is an early-stage compiler/interpreter project for a small Python-like
language. It follows the same "boot" bootstrapping pattern used by the Miking
project (KTH): a throwaway bootstrap implementation is written first in a
convenient host language, with the intent of eventually self-hosting the
compiler in the target/meta language itself. Concretely:

- `boot/` holds the bootstrap implementation, currently written in Python
  (`boot/pykboot.py`). An earlier version of the bootstrap was written in
  OCaml (`ast.ml`, `lexer.ml`, `pykboot.ml`); it was removed on 2026-07-16 in
  favor of the Python rewrite — don't reintroduce `.ml` files unless asked.
- `src/` is reserved for the eventual self-hosted implementation written in
  Miking (`.mc` files). It's currently empty of tracked content.
- `boot/tests/` contains sample source programs (not a pytest suite) used to
  manually exercise the lexer, e.g.:
  ```
  python3 boot/pykboot.py boot/tests/test1.py
  ```
  This prints one line per token as `'<file>' <row1>:<col1>-<row2>:<col2> <TokKind>`.

There is no build system, package manifest, or automated test runner yet —
the project is at the "lexer only" stage.

## Architecture of `boot/pykboot.py`

The bootstrap is a single file structured in three parts:

1. **`Info`** — a frozen dataclass carrying source location (`file`, `row1`,
   `col1`, `row2`, `col2`) attached to every token, used for error reporting.
2. **Token ADT** — each token kind is a frozen `@dataclass` subclassing the
   `Token` marker base class (e.g. `TokInt`, `TokIdent`, `TokAdd`, `TokDef`).
   This mirrors how the token type would be expressed as an OCaml/Miking
   variant type — keep new token kinds in this same one-class-per-variant
   style rather than collapsing them into a single class with a `kind` field.
   `pprint_token` / `pprint_info` use `match`/`case` over these dataclasses
   for pretty-printing, again mirroring OCaml-style pattern matching.
3. **Lexer** — `lexing(file, chars)` consumes a list of characters
   (`list(str)`, not a string) via structural pattern matching (`match rest:
   case [x, *xs] ...`) and returns a list of `(Info, Token)` pairs. Helpers:
   `string_until(pred, chars)` grabs the longest matching prefix, `skip`
   drops one character (used to consume closing quotes), `is_digit` /
   `is_letter` / `is_digit_letter` classify characters. Row/column tracking
   is done manually (`r, c`) as characters are consumed — line comments and
   newlines reset column and bump row.

When extending the lexer (new operators, keywords, string escapes, etc.),
follow the existing pattern: add a `case [...]:` arm in the `match rest:`
block inside `lexing`, add a corresponding `Tok*` dataclass, and add a
`case Tok*():` arm to `pprint_token`.

## Running

```
python3 boot/pykboot.py <filename>
```

No dependencies beyond the Python standard library (`dataclasses`, `sys`).
Requires Python 3.10+ for `match`/`case` statements.

## Repository housekeeping

- Editor backup files ending in `~` (e.g. `boot/tests/variables.py~`,
  `.gitignore~`) and the `src/` directory are untracked/gitignored scratch
  content — don't treat them as authoritative source, and don't assume
  they should be committed.
