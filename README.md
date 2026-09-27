# Pyking

A small, lexically-scoped, Python-like language, and a compiler for it.

Pyking borrows its syntax from Python — literals, arithmetic, functions,
`for`/`while`/`if`, indentation-based blocks — and departs from it where
Python's dynamism gets in the way: plain `=` is an *immutable binding*
rather than an assignment, mutable variables are declared with `var` and
updated with `:=`, and every block is a real scope, checked at compile
time. It adds a loop built for that: `loop x = 0:` carries an
accumulator from turn to turn and is worth whatever it breaks with, so
counting something up needs no mutable variable at all — and a function
that calls itself in tail position is compiled into exactly such a loop,
so it runs in constant space on every target.

A file is a module, exporting only what it marks `public`, and a program
is the acyclic graph of the modules its main file reaches — compiled to
one file per module on every target, and run in an order each module
sees a finished version of everything it imports.

Pyking is statically typed: every program is type-checked, whatever is
then done with it. A program can be compiled for any of twelve targets,
or run directly by the interpreter. `./pyk` — the compiled driver, built
by `make` — is the front end for all of it, and has three commands:

```sh
./pyk hello.pyk                # run it with the interpreter
./pyk repl                     # a prompt, with the same interpreter behind it
./pyk compile hello.pyk        # compile it (alias: ./pyk c)
```

`./pyk hello.pyk` runs the AST directly, with Pyking's own semantics —
32-bit integers, and runtime errors reported against Pyking source
positions. Where a backend disagrees with it, the interpreter is the
reference; see [docs/targets.md](docs/targets.md).

`compile` writes a file named after the source, unless `--output` (`-o`)
says otherwise:

```sh
./pyk c -t python  hello.pyk   # ./hello.py     (python14; the default)
./pyk c -t node    hello.pyk   # ./hello.js     (node24, an ES module)
./pyk c -t web     hello.pyk   # ./hello.html + the .js files it loads
./pyk c -t iweb    hello.pyk   # ./hello.html + pyking.js + hello.pyk
./pyk c -t c89     hello.pyk   # ./hello.c      (C89)
./pyk c -t c99     hello.pyk   # ./hello.c      (C99)
./pyk c -t c       hello.pyk   # ./hello.c      (C23; `c` is the alias)
./pyk c -t java8   hello.pyk   # ./Hello.java   (Java 8)
./pyk c -t java17  hello.pyk   # ./Hello.java   (Java 17)
./pyk c -t java    hello.pyk   # ./Hello.java   (Java 21; `java` is the alias)
./pyk c -t ocaml   hello.pyk   # ./hello.ml     (ocaml5.5)
./pyk c -t pyking  hello.pyk   # ./hello.pyk    (Pyking, as the front end has it)
```

Every target carries a **version**, and every family has an unversioned
**alias** naming its latest: `c` is `c23`, `java` is `java21`, `node` is
`node24`. A version says the oldest host the output is promised to run
on. `iweb` is the odd one — it compiles nothing, shipping the Pyking
source and the interpreter so a browser runs the *whole* language rather
than one backend's subset.

`--stdout` prints the generated code instead of writing it, and
`--tokens` the token stream. `--run` builds and runs what was compiled,
with the commands that target's host uses, each printed before it runs.

The `pyking` target compiles Pyking to Pyking: it prints the program the
front end worked out, carrying the types the checker inferred and the
loops the tail-call pass built. `--symbols` goes with it, labelling each
node with the unique number the `symbolize` pass gave it:

```sh
./pyk c -t pyking --stdout hello.pyk             # x: Int = 12 + 20
./pyk c -t pyking --symbols --stdout hello.pyk   # x@1: Int = (12@2 + 20@3)@4  @5
./pyk c -t node24 --run hello.pyk                # $ node hello.js
```

A program that imports something compiles to more than one file: each
module lands beside the program's own output under its own name, and the
generated import names it by that name. See
[docs/modules.md](docs/modules.md).

The type checker runs for every program, whatever is then done with it —
see
[docs/architecture.md](docs/architecture.md#symbols-and-types); `./pyk
<file>` and `./pyk repl` run exactly the fragment it accepts, since it is
what decides what they can run. Running `./pyk` with no arguments prints
the usage, and `--help` prints it in full.

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

The compiler is OCaml in `src/`, built by dune, so `make` builds it:

```sh
make            # dune build src/pyk.exe, copied here as ./pyk
```

| command | what it does |
|---|---|
| `make` | build the compiler into `./pyk` |
| `make help` | the list below |
| `make test` | the compiler's own suite: every program in `tests/` on every target it supports, comparing each against one shared `.out` file — run in parallel, one job per usable CPU (`JOBS=n` to say how many) — then the REPL's own cases in `tests/repl/`, the library path's, the playground's and the notebook's |
| `make stest` | the same suite, one test at a time |
| `make playground` | serve the [web playground](tools/playground/) (`pyk playground`), then print a link to open |
| `make notebook` | serve `PYKING-TUTORIAL.md` as a [notebook](tools/notebook/) (`pyk notebook`), then print a link |
| `make vendor` | download Ace and KaTeX into `tools/webrun/vendor/`, once; the two above run it first |
| `make clean` | remove what has been generated: `_build/`, `./pyk`, `__pycache__/` directories |
| `make distclean` | that, plus the `tools/webrun/vendor/` download cache |

`./pyk` is a build artifact, not a checked-in script: `make` writes it
and `make clean` removes it. Everything else `make clean` leaves alone —
in particular *compiled programs*. `pyk` writes its output wherever you
point it, under names that are ordinary source names in the target
language (`hello.py`, `Hello.java`), so nothing can tell those apart
from files you wrote yourself; deleting them stays your call. `./pyk` is
the exception that shows the rule, since `make` chose that name itself.

See [docs/build.md](docs/build.md) for how the build is put together —
the library/executable split, and the js_of_ocaml bundle the playground
runs.

The playground and the notebook are started through the compiler —
`pyk playground`, `pyk notebook FILE.md`, `--port N` for either — and
need Python 3.14 or later. Neither is built: each is served from
`tools/` as it stands. The first `make vendor` downloads their editor
and math libraries and caches them, which is why the cache only goes on
`make distclean`. See [docs/build.md](docs/build.md), "The web tools".

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
- **[docs/libraries.md](docs/libraries.md)** — the standard library
  under `lib/`: what each library offers, how `pyk` finds one, and why
  each reaches the targets it does.
- **[docs/modules.md](docs/modules.md)** — the module system: how a file
  becomes a module and a program becomes a graph of them, what each one
  exports, in what order they are compiled and run, and what each target
  makes of that.
- **[docs/architecture.md](docs/architecture.md)** — the compiler itself:
  pipeline diagram, the stages, the interpreter's machine, the runtime
  interface that separates a program from the world it prints into, and
  how the tests work.
- **[docs/source.md](docs/source.md)** — every file in `src/`: what it
  is, its data structures, and its main functions, each linking to a
  dedicated page working through that module's own design in depth.
- **[docs/interfaces.md](docs/interfaces.md)** — the `.mli` files in
  `src/`: what each module exports and what it keeps to itself, which
  module may call which, and which types are opaque.
- **[docs/build.md](docs/build.md)** — how `src/` becomes `./pyk`: the
  dune layout, why the pure half is a library of its own, and how the
  same code becomes the JavaScript the playground runs.
- **[docs/desugar_args.md](docs/desugar_args.md)** — default parameters
  and named arguments: what they lower to, why a default is a generated
  `def` rather than a hoisted binding, and why named arguments are
  written in parameter order.
- **[docs/overloading.md](docs/overloading.md)** — `::` names: what may
  carry a qualifier, how a call is resolved to one definition by its
  arguments, and what the output holds instead.
- **[docs/implicits.md](docs/implicits.md)** — implicit parameters: the
  search that fills one, the lambda built where a candidate takes
  implicits of its own, why an obligation stops at a `def`, and why the
  checker does not have to run twice.
- **[docs/optimization.md](docs/optimization.md)** — tail calls, and the
  loops they become: what counts as one, what a mutually recursive group
  is merged into, what the pass deliberately leaves alone, and the one
  kind of group it cannot make work.
- **[docs/type_inference.md](docs/type_inference.md)** — how a function
  nobody annotated still gets a type: checked at the call rather than at
  the definition, why it is done that way, and what it deliberately
  does not do.
- **[CLAUDE.md](CLAUDE.md)** — repository conventions, for anyone (or
  anything) making changes here.

## Layout

| path | contents |
|---|---|
| `pyk` | the compiled command-line front end (built by `make`; see above) |
| `src/` | the compiler, one module per stage (see [docs/source.md](docs/source.md)) |
| `src/web/` | the browser entry point, compiled to JavaScript by js_of_ocaml |
| `tests/` | Pyking programs, their expected output, and the test runner |
| `docs/` | design and architecture notes |
| `tools/emacs/` | a major mode for editing `.pyk` files |
| `tools/playground/` | the browser playground: the compiler itself, compiled to JavaScript |
| `tools/notebook/` | the notebook: a Markdown file whose Pyking blocks run in the browser |
| `tools/webrun/` | what the playground and the notebook share |

Building the compiler needs OCaml and dune, and nothing else; the
playground's bundle additionally needs js_of_ocaml. The test harness is
Python 3.11+ (`match`/`case`, `tomllib`), and the web tools need Python
3.14+.

Running the generated code needs `node` for the JavaScript targets, a C
compiler for the C ones, a JDK (`javac`/`java`) for the Java ones and an
OCaml compiler for `ocaml5.5`; producing it needs none of them, and running
a program with `./pyk` needs nothing at all. The compiler itself has no
third-party dependencies.
