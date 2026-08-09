# Pyking

A small, lexically-scoped, Python-like language, and a compiler for it.

Pyking borrows its syntax from Python — literals, arithmetic, functions,
`for`/`while`/`if`, indentation-based blocks — and departs from it where
Python's dynamism gets in the way: plain `=` is an *immutable binding*
rather than an assignment, mutable variables are declared with `var` and
updated with `:=`, and every block is a real scope, checked at compile
time.

A program can be compiled for any of ten targets, or run directly by the
interpreter. The `pyk` script at the repository root is the front end for
all of it, and has four commands:

```sh
./pyk hello.pyk                # compile with the python backend and run it
./pyk run hello.pyk            # run it with the interpreter
./pyk repl                     # a prompt, with the same interpreter behind it
./pyk compile hello.pyk        # compile it (alias: ./pyk c)
```

`./pyk hello.pyk` compiles to a temporary file, runs it, and cleans up;
it covers the whole language. `./pyk run` runs the AST directly, with
Pyking's own semantics — 32-bit integers, and runtime errors reported
against Pyking source positions — and covers the fragment the type
checker accepts. Where the two disagree, the interpreter is the
reference; see [docs/targets.md](docs/targets.md).

`compile` writes a file named after the source, unless `--output` (`-o`)
says otherwise:

```sh
./pyk c -t python  hello.pyk   # ./hello.py     (python is the default)
./pyk c -t nodejs  hello.pyk   # ./hello.js
./pyk c -t html    hello.pyk   # ./hello.html
./pyk c -t esm     hello.pyk   # ./hello.js + .node.js + .html + package.json
./pyk c -t c89     hello.pyk   # ./hello.c      (C89)
./pyk c -t c23     hello.pyk   # ./hello.c      (C23)
./pyk c -t java8   hello.pyk   # ./Hello.java   (Java 8)
./pyk c -t java17  hello.pyk   # ./Hello.java   (Java 17)
./pyk c -t java21  hello.pyk   # ./Hello.java   (Java 21)
./pyk c -t ocaml   hello.pyk   # ./hello.ml
```

`--stdout` prints the generated code instead of writing it, `--ast` shows
the parsed program, and `--tokens` the token stream. Two flags go with
`--ast`: `--symbols` labels each node with the unique number the
`symbolize` pass gave it, and `--typecheck` runs the type checker first,
so the printed program carries the types it inferred:

```sh
./pyk c --typecheck --ast hello.pyk    # x: Int = 12 + 20
./pyk c --ast --symbols hello.pyk      # x@1 = (12@2 + 20@3)@4  @5
```

The type checker is opt-in for compiling because it covers only part of
the language so far — see
[docs/architecture.md](docs/architecture.md#symbols-and-types); `./pyk
run` and `./pyk repl` always run it, since it is what decides what they
can run. Every flag is passed straight through to the compiler
(`src/pyk.py`), so running `./pyk` with no arguments prints the full
usage.

The REPL is a session read as a program written one entry at a time: each
entry is checked against what the entries before it left behind, and then
run there. A value comes back with its type, and a block indents itself
as you type it.

```
$ ./pyk repl
Pyking REPL.  :help for commands, :quit to leave.
> x = 21
> def double(n:Int) -> Int:
.     n * 2
.
> double(x)
42 : Int
> :ls
x      = 21 : Int
double = <function> : (Int) -> Int
```

The arrow keys move through the whole entry, not just its last line, and
Up at the top of one steps back through earlier entries — so a function
comes back whole, can be edited anywhere in it, and re-submitted.
`:edit <name>` does the same for anything the session defined, however
long ago. `:help` lists the rest.

## Make targets

There is nothing to build — the compiler is a set of Python scripts run
in place — so a bare `make` prints this list rather than building
anything:

| command | what it does |
|---|---|
| `make`, `make help` | the list below |
| `make test` | the compiler's own suite: every program in `tests/` on every target it supports, comparing each against one shared `.out` file |
| `make test-py2pyk` | the [py2pyk](tools/py2pyk/) suite: each `.py` translated to Pyking, compiled back to Python, and both run and diffed |
| `make playground` | build and serve the [web playground](tools/playground/), then print a link to open |
| `make clean` | remove what has been generated: `__pycache__/` directories and the playground's `build/` |
| `make distclean` | that, plus the playground's `vendor/` download cache |

`make clean` leaves *compiled programs* alone. `pyk` writes its output
wherever you point it, under names that are ordinary source names in the
target language (`hello.py`, `Hello.java`), so nothing can tell those
apart from files you wrote yourself — deleting them stays your call.

`make playground` delegates to `tools/playground/`, which has options of
its own (`PORT=`, `CDN=`, ...) — run `make -C tools/playground help` for
those. Everything it generates stays inside that directory and is
gitignored; the first run downloads ~12 MB and caches it, later ones are
offline. That cache is why the playground's build output goes on `make
clean` but the cache itself only goes on `make distclean`.

## Documentation

- **[PYKING.md](PYKING.md)** — the language: feature summary, full EBNF
  grammar, scoping rules, and a worked example for every construct.
- **[docs/targets.md](docs/targets.md)** — the compiler targets: every
  one at a glance, which parts of the language each accepts, and links to
  a page per family ([Python](docs/target_python.md),
  [JavaScript](docs/target_js.md), [C](docs/target_c.md),
  [Java](docs/target_java.md), [OCaml](docs/target_ocaml.md))
  documenting how each construct is compiled and where the output is not
  optimal.
- **[docs/defshadow.md](docs/defshadow.md)** — an open design question:
  what a function body sees when a name it uses is rebound, and what a
  `def` and an `=` sharing one name should mean. Options, consequences,
  and how ten other languages answer it.
- **[docs/gap.md](docs/gap.md)** — how a `def` written inside a loop
  keeps its own turn's bindings: the mechanism, the shape that used to
  defeat it, and what it still costs in generated code.
- **[docs/architecture.md](docs/architecture.md)** — the compiler itself:
  pipeline diagram, the stages, the interpreter's machine, the runtime
  interface that separates a program from the world it prints into, and
  how the tests work.
- **[docs/source.md](docs/source.md)** — every file in `src/`: what it
  is, its data structures, and its main functions.
- **[docs/type_inference.md](docs/type_inference.md)** — how a function
  nobody annotated still gets a type: checked at the call rather than at
  the definition, why it is done that way, and what it deliberately
  does not do.
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
ones, a JDK (`javac`/`java`) for the Java ones and an OCaml compiler for
`ocaml`; producing it needs none of them, and `./pyk run` needs nothing
at all. No third-party dependencies.
