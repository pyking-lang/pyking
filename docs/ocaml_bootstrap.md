# The OCaml bootstrap

`ocaml-src/` holds the front end again, in OCaml. It is a translation of
the modules in `src/`, not a second design: the same stages, the same
functions, the same error messages, the same printed output. What it has
so far is the lexer, the AST and its pretty printer, `symbolize`, the
parser, and the beginning of a type checker.

The two implementations are held together by `make test-ocaml`, which
runs both over every program in `tests/` and compares what they print.
That comparison is the whole point of the exercise: a translation
nothing checks drifts, and a translation that must produce identical
bytes for 275 programs does not.

## Modules

| file | what it holds |
|---|---|
| `lexer.ml` | `info`, the `token` type, `lexing`, and the pretty printers for both. Translated from `src/lexer.py`. |
| `syntax.ml` | the AST — `expr`, `typ`, `pattern`, `comp_clause`, `assign_target`, `stmt`, and the four they are built from (`param`, `list_rest`, `loop_iter`, `match_case`) — and the pretty printer that prints it back as Pyking source. Translated from `src/syntax.py`. |
| `analyses.ml` | `symbolize`, and `highest_sym` under it. The rest of `src/analyses.py` — the mutability walk, `block_functions`, `Effects` — is not translated yet. |
| `parser.ml` | the recursive-descent parser, including every rule the grammar cannot state. Translated from `src/parser.py`. |
| `typesystem.ml` | the type checker, at its beginning: integer literals, variables and `+`. |
| `main.ml` | the driver: read a file, lex, parse, symbolize, optionally type-check, print. A fraction of `src/pyk.py`. |

## Building and running

```sh
make ocaml                                  # dune build, then a copy to ./main
./main [--typecheck] [--symbols] <file.pyk>
```

`make ocaml` is `dune build --root ocaml-src` and nothing more, except
that it copies `ocaml-src/_build/default/main.exe` out to `./main`,
where it can be run beside `./pyk`. `make clean` removes both the build
directory and that copy. Running the binary where dune leaves it works
just as well:

```sh
dune build --root ocaml-src
./ocaml-src/_build/default/main.exe [--typecheck] [--symbols] <file.pyk>
```

It prints the program back out as Pyking source and nothing else. There
are no targets, no output files and no commands: what it is for is the
front end.

`--symbols` labels each node with the number `symbolize` gave it, as
`pyk compile -t pyking --symbols` does. `--typecheck` runs
`typesystem.ml` as well, and then every annotation
printed comes from what the checker inferred rather than from the
source — the same thing `pyk compile -t pyking` does with its own
checker's table. On the fragment both accept, the two agree:

```sh
$ printf 'x = 1\ny = x + 2\n' > t.pyk
$ ./main --typecheck t.pyk
x: Int = 1
y: Int = x + 2
```

An error is reported exactly as `src/pyk.py` reports it — the same
label, the same span, the same wording, reflowed to the same 70 columns:

```
'tests/fail_typecheck_loop_outside.pyk' 3:0-3:5 Parsing error: 'break'
  may only appear in the body of a 'loop'
```

`main.ml` carries its own copy of `format_error` and `wrap` for that,
which is the one piece of `src/pyk.py` worth having here: it is what
lets `make test-ocaml` compare a refusal as well as an acceptance.

## `make test-ocaml`

```
python3 src/pyk.py compile -t pyking --stdout --no-typechecking <program>
ocaml-src/_build/default/main.exe <program>
```

for every `tests/*.pyk`, comparing standard output, standard error and
the exit status. Then again with `--symbols` on both sides, which is
what holds the two `symbolize` passes to handing out the same numbers —
`src/` walks the dataclasses generically and `ocaml-src/` has a case per
node, so nothing else would catch them disagreeing.
`tests/test_ocaml_script.py` is the runner; it builds the OCaml tree
first, runs the programs in a thread pool, and reports them in a fixed
order however they were scheduled.

Type checking is off on both sides, which is what `--no-typechecking`
exists for (see `docs/pyk.md`). The OCaml checker covers a fragment the
Python one long outgrew, so with checking *on* the two would disagree
about almost every program — not about the front end, but about the
types printed into it. With checking off, `-t pyking` prints the program
the parser built with the source's own annotations, which is exactly
what the OCaml side prints.

Thirteen of the `fail_typecheck_*` programs are refused by the *parser*
rather than the checker, so they are compared too: those are the cases
that pin the translated parser's error positions and wording, not just
that it said no.

What it does *not* cover is the half of the printer that reads a
checker's table: the annotations that come from inferred types, and the
`def name : type` rule that goes with them (`signed_defs`). Both are
translated, and neither can be compared until the OCaml checker reaches
the constructs those programs use.

## What is different, and why

The OCaml is functional throughout — no mutable state, no objects — so
four things that are module-level or in-place in Python are values here.

**The end-of-input position.** `src/parser.py` keeps `_eof_info` in a
module-level variable that `parse` assigns, and `_here` reads it when the
token list has run out. Here it is `eof`, the first parameter of every
parser function that can run out of tokens. That is the only reason the
signatures differ from the Python ones.

**What the printers show.** `src/syntax.py` keeps `_show_symbols`,
`_tmap` and `_signed` as module-level display flags, set and restored by
`pprint_program` around its one call. Here they are a `config` record
threaded through the printers. The two places the Python code
temporarily *changes* one — a checker-built type printed without a
symbol suffix, and a `def` whose type is on a signature line printing no
annotations — are a `{ cfg with ... }` passed down instead.

**The lexer's state.** The token list, the row and column, the
indentation stack and "nothing but spaces on this line yet" are the
arguments of one tail-recursive function. The indentation stack is a
list rebuilt rather than pushed and popped, and the tokens are
accumulated in reverse and turned round at the end.

**`symbolize`.** `src/analyses.py` walks the dataclasses generically:
one function covers every node, and a node added to `src/syntax.py` is
numbered without touching it. OCaml has no such walk, so `analyses.ml`
says what each node's children are, one case per constructor. The order
matters — the numbers must be the ones the Python pass hands out, which
means visiting a node's children in the order `src/syntax.py` declares
its fields, and numbering the node after them. A node added to
`syntax.ml` needs a case here; nothing catches it missing.

Two smaller ones. Each AST constructor carries its `info` first and its
`sym` last, in the order the Python dataclass writes its fields; where
`src/` uses `dataclasses.replace(node, info=...)` for a parenthesized
expression, this has `set_expr_info` and its three siblings. And a
list-pattern item is `(pattern, list_rest) Either.t` rather than a value
whose class the reader asks about.

One place they really do differ is an integer literal too large for an
OCaml `int`: `src/lexer.py` reads any run of digits, since Python's
integers have no width, and this refuses it as a lexical error. A Pyking
`Int` is 32 bits, so nothing a program could mean is lost.

The other is text: OCaml strings are
bytes, Python's are characters, so a source file with a non-ASCII
character inside a string literal would give the two different *columns*
for anything later on that line. Nothing in `tests/` does — the one
non-ASCII file has it in a comment — and it costs nothing to know.

## The type checker

`typesystem.ml` accepts integer literals, variables, `+`, and the two
statements that let those be written: `x = e` and an expression
statement. It refuses everything else with `Construct is not supported`,
which is the floor `src/typesystem.py` keeps for what it has not
reasoned about. An unbound name is an `Analysis_error` reported as a
`Name error`, in the same words and for the same reason: which pass
caught it is not something the message should turn on.

Its shape is the one to keep as it grows — one function per AST
datatype, an `env` mapping a name to its type used immutably, and one
table from a node's symbol to the type worked out for it, returned as
the pass's result. `docs/typesystem.md` and `docs/type_inference.md`
describe what the Python checker does with the rest of the language.
