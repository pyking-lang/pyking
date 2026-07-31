# Pyking

A small, lexically-scoped, Python-like language, and a compiler for it.

Pyking borrows its syntax from Python — literals, arithmetic, functions,
`for`/`while`/`if`, indentation-based blocks — and departs from it where
Python's dynamism gets in the way: plain `=` is an *immutable binding*
rather than an assignment, mutable variables are declared with `var` and
updated with `:=`, and every block is a real scope, checked at compile
time.

Pyking has no interpreter. It compiles, and the same program can be
emitted for several targets. The `pyk` script at the repository root is
the front end for all of it:

```sh
./pyk hello.pyk                # compile and run it, leaving nothing behind
```

Given a filename and nothing else, `pyk` compiles to a temporary file,
runs it, and cleans up. Add any flag and it compiles to a file instead,
named after the source unless `--output` says otherwise:

```sh
./pyk -t python  hello.pyk     # ./hello.py     (python is the default)
./pyk -t nodejs  hello.pyk     # ./hello.js
./pyk -t html    hello.pyk     # ./hello.html
./pyk -t esm     hello.pyk     # ./hello.js + .node.js + .html + package.json
./pyk -t c89     hello.pyk     # ./hello.c      (C89)
./pyk -t c23     hello.pyk     # ./hello.c      (C23)
./pyk -t java8   hello.pyk     # ./Hello.java   (Java 8)
./pyk -t java17  hello.pyk     # ./Hello.java   (Java 17)
./pyk -t java21  hello.pyk     # ./Hello.java   (Java 21)
```

`--stdout` prints the generated code instead of writing it, `--ast` shows
the parsed program, and `--tokens` the token stream. Two flags go with
`--ast`: `--symbols` labels each node with the unique number the
`symbolize` pass gave it, and `--typecheck` runs the type checker first,
so the printed program carries the types it inferred:

```sh
./pyk --typecheck --ast hello.pyk    # x: Int = 12 + 20
./pyk --ast --symbols hello.pyk      # x@1 = (12@2 + 20@3)@4  @5
```

The type checker is opt-in because it covers only part of the language
so far — see [docs/architecture.md](docs/architecture.md#symbols-and-types).
Every flag is passed straight through to the compiler
(`src/pykboot.py`), so running `./pyk` with no arguments prints the full
usage.

## Make targets

A bare `make` deliberately does nothing — every useful thing has a name:

| command | what it does |
|---|---|
| `make test` | the compiler's own suite: every program in `tests/` on every target it supports, comparing each against one shared `.out` file |
| `make test-py2pyk` | the [py2pyk](tools/py2pyk/) suite: each `.py` translated to Pyking, compiled back to Python, and both run and diffed |
| `make playground` | build and serve the [web playground](tools/playground/), then print a link to open |

`make playground` delegates to `tools/playground/`, which has options of
its own (`PORT=`, `CDN=`, `make clean`, ...) — run `make -C
tools/playground help` for those. Everything it generates stays inside
that directory and is gitignored; the first run downloads ~12 MB and
caches it, later ones are offline.

## Documentation

- **[PYKING.md](PYKING.md)** — the language: feature summary, full EBNF
  grammar, scoping rules, and a worked example for every construct.
- **[docs/targets.md](docs/targets.md)** — the compiler targets: every
  one at a glance, which parts of the language each accepts, and links to
  a page per family ([Python](docs/target_python.md),
  [JavaScript](docs/target_js.md), [C](docs/target_c.md),
  [Java](docs/target_java.md)) documenting how each construct is compiled
  and where the output is not optimal.
- **[docs/architecture.md](docs/architecture.md)** — the compiler itself:
  pipeline diagram, the stages, the runtime interface that separates a
  program from the world it prints into, and how the tests work.
- **[CLAUDE.md](CLAUDE.md)** — repository conventions, for anyone (or
  anything) making changes here.

## Layout

| path | contents |
|---|---|
| `pyk` | the command-line front end (see above) |
| `src/` | the bootstrap compiler, one module per stage (see [CLAUDE.md](CLAUDE.md)) |
| `tests/` | Pyking programs, their expected output, and the test runner |
| `docs/` | design and architecture notes |
| `tools/emacs/` | a major mode for editing `.pyk` files |
| `tools/py2pyk/` | a standalone Python-to-Pyking translator, with its own tests |
| `tools/playground/` | the browser playground: the compiler running under Pyodide |

Requires Python 3.11+ (`match`/`case`, `tomllib`). Running the generated
code needs `node` for the JavaScript targets, a C compiler for the C
ones, and a JDK (`javac`/`java`) for the Java ones; producing it needs
none of them. No third-party dependencies.
