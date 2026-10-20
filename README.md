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

`compile` writes everything it generates into `build/`, with a
`Makefile`, builds it with the target's own tools, and puts the
executable beside `build/` — `./hello`, or the name `--output` (`-o`)
gives:

```sh
./pyk c -t python  hello.pyk   # build/hello.py, and ./hello runs it   (python12; the default)
./pyk c -t node    hello.pyk   # build/hello.js, and ./hello runs it   (node22, an ES module)
./pyk c -t web     hello.pyk   # build/hello.html + the .js files it loads
./pyk c -t iweb    hello.pyk   # build/hello.html + pyking.js + hello.pyk
./pyk c -t c89     hello.pyk   # build/hello.c, and the binary ./hello (C89)
./pyk c -t c       hello.pyk   # build/hello.c, and the binary ./hello (C99; `c` is the alias)
./pyk c -t c23     hello.pyk   # build/hello.c, and the binary ./hello (C23)
./pyk c -t java8   hello.pyk   # build/Hello.java, and ./hello runs it (Java 8)
./pyk c -t java17  hello.pyk   # build/Hello.java, and ./hello runs it (Java 17)
./pyk c -t java    hello.pyk   # build/Hello.java, and ./hello runs it (Java 21; `java` is the alias)
./pyk c -t ocaml   hello.pyk   # build/hello.ml, and the binary ./hello (ocaml4.14)
./pyk c -t pyking  -o out.pyk hello.pyk   # out.pyk (Pyking, as the front end has it)
./pyk c -t ocaml   -o hi hello.pyk        # ./hi, and build/hi.ml
./pyk hello.pyk    -t ocaml               # build it in build/ and run it from there
```

`make` in `build/` builds the program again, `make run` runs it and
`make clean` removes what `make` made. A `build/` an earlier `pyk
compile` made is replaced; any other is left alone and the compile
refused.

Every target carries a **version**, and every family has an unversioned
**alias** naming its default: `python` is `python12`, `node` is
`node22`, `web` is `web2020`, `c` is `c99`, `java` is `java21`, `ocaml`
is `ocaml4.14`. A version says the oldest host the output is promised
to run on: the Python, node, Java or OCaml release, the C standard, and
for `web` and `iweb` the ECMAScript edition the page is written in
(`node22` writes ES2020 and `node24` ES2024). `pyk --help` lists them
all. `iweb` is the odd one — it compiles nothing, shipping the Pyking
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
./pyk c -t node24 --run hello.pyk                # $ node build/hello.js
```

A program that imports something compiles to more than one file: each
module lands beside the program's own output in `build/` under its own
name, and the generated import names it by that name. See
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

## Installing

On a Mac, with [Homebrew](https://brew.sh):

```sh
brew update
brew install pyking-lang/tap/pyking
```

On Linux and WSL, any distribution, into `~/.local` with no sudo:

```sh
curl -fsSL https://github.com/pyking-lang/pyking-releases/releases/latest/download/install.sh | sh
```

Either way `pyk` is one compiled binary needing nothing but the
system's C library: universal on macOS 11 or later (Apple Silicon and
Intel), and linked against glibc 2.28 or later on Linux (x86_64 and
aarch64), with the standard library's plugins beside it. Debian and Ubuntu users can install the release's
`.deb` instead. `pyk notebook` and `pyk playground` are served by
`pyk` itself, and running what a target compiled needs that target's
own tools. See [tools/packaging/](tools/packaging/)
for every option, and for how the packages are built and published.

## Make targets

The compiler is OCaml in `src/`, built by dune, so `make` builds it:

```sh
make            # dune build src/pyk.exe, copied here as ./pyk
```

| command | what it does |
|---|---|
| `make` | build the compiler into `./pyk` |
| `make help` | the list below |
| `make test` | a clean build (`make clean-build`, then `make`), then the compiler's own suite: every program in `tests/` on every target it supports, comparing each against one shared `.out` file — run in parallel, one job per usable CPU (`JOBS=n` to say how many) — then the REPL's own cases in `tests/repl/`, the library path's, the playground's, the notebook's, the packaged tree's and the website's |
| `make stest` | the same suite, one test at a time |
| `make quicktest` | a random sample of it: the latest version of each target family, node, web, C and Java on `PERCENT` of their cases (5 by default), the packaging, tinyweb and lsp suites on `PERCENT` of their checks; `SEED=n` repeats a run |
| `make playground` | serve the [web playground](tools/playground/) (`pyk playground`), then print a link to open |
| `make notebook` | serve `PYKING-TUTORIAL.md` as a [notebook](tools/notebook/) (`pyk notebook`), then print a link |
| `make pykhelp` | serve the [help](tools/help/) (`pyk pykhelp`): getting started, the language reference and the libraries, with runnable examples |
| `make vendor` | download Ace, KaTeX and Monaco into `tools/webrun/vendor/`, once; the two above run it first |
| `make website` | build the [website](tools/site/) into `website/`, from `sitesrc/` and `lib/` (`make website-dev` serves it with Astro's dev server) |
| `make packaging` | build the installable packages into `tools/packaging/build/` — for now the Homebrew one, on a Mac |
| `make packaging-setup` | once, on an Apple Silicon Mac: make the two OCaml toolchains `make packaging` builds with, and say whether it worked |
| `make release` | publish the built packages: one release of the public `pyking-lang/pyking-releases` with every platform, the formula in the tap `pyking-lang/homebrew-tap`, and (asked separately) the tag `release-<VERSION>` here |
| `make packaging-install` | install that build with Homebrew, to try it before publishing (`make packaging-uninstall` undoes it) |
| `make clean` | remove what has been generated: `_build/`, `./pyk`, `__pycache__/` directories, `tools/packaging/build/`, `website/`, `tools/site/build/` |
| `make distclean` | that, plus the `tools/webrun/vendor/` and `tools/site/node_modules/` download caches |

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
served by `pyk` itself. Neither is built: each is served from
`tools/` as it stands. The first `make vendor` downloads their editor
and math libraries and caches them, which is why the cache only goes on
`make distclean`. See [docs/build.md](docs/build.md), "The web tools".

## Editors

`pyk lsp` is a language server: errors as you type, the inferred type
on hover, go to definition, an outline, completion, signature help,
references, rename, inlay hints, folding, semantic highlighting and
quick fixes, in any editor that speaks the Language Server Protocol.
`pyk dap` is a debugger for any editor that speaks the Debug Adapter
Protocol: breakpoints, stepping, the calls in progress and their
variables ([docs/debugging.md](docs/debugging.md)); the playground has
the same debugger in its Debug tab. Both are part of `pyk`, so they
need nothing more. [tools/editors/vscode/](tools/editors/vscode/) is the
VS Code and Cursor extension, `tools/emacs/pyking-mode.el` registers it
with eglot, and the website's Editors page
([sitesrc/documentation/editors.md](sitesrc/documentation/editors.md)) sets
up the rest. [design/lsp.md](design/lsp.md) is the plan, in three steps.

## Building a release

The packages are built from this tree by `make packaging` and published
by `make release`, after setting `VERSION` and dating its section in
[CHANGELOG.md](CHANGELOG.md), which the GitHub release shows as what has
changed. Both need toolchains, which
`make packaging-setup` makes once and checks (`FORMATS=linux` on a Linux
machine):

- **macOS** (an Apple Silicon Mac): two opam switches named
  `pyking-release`, one arm64 and one x86_64 under Rosetta (in
  `~/.opam-x86_64`). Both are built for macOS 11 and must have the same
  OCaml, the `OCAML_VERSION` in `tools/packaging/packaging.py`.
- **Linux**: Docker, with one AlmaLinux 8 build image per architecture.

[tools/packaging/README.md](tools/packaging/README.md) is the long
form:
- [One-time setup](tools/packaging/README.md#one-time-setup), including
  [macOS: the release toolchains](tools/packaging/README.md#macos-the-release-toolchains)
  and [Linux: the build images](tools/packaging/README.md#linux-the-build-images);
- [Building a release](tools/packaging/README.md#building-a-release):
  what is built, checked and published;
- [Trying a build locally](tools/packaging/README.md#trying-a-build-locally).

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
  under `lib/`: what each library offers, how `pyk` finds one, why
  each reaches the targets it does, and how the interpreter and a
  browser reach one implemented in a target language.
- **[docs/debugging.md](docs/debugging.md)** — the debugger: one
  session core, two transports (`pyk dap` and the playground's Debug
  tab), and what stepping, breakpoints and evaluating mean.
- **[docs/release.md](docs/release.md)** — `pyk compile --release`: how
  every call to `debug` is removed before any backend sees the program.
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
| `tools/site/` | the website: Astro and Starlight, and the library reference generator |
| `sitesrc/` | the website's pages, in Markdown |
| `tools/packaging/` | builds the installable packages (Homebrew, so far) |

Building the compiler needs OCaml and dune, and nothing else; the
playground's bundle additionally needs js_of_ocaml. The test harness is
Python 3.11+ (`match`/`case`, `tomllib`), and so is `make vendor`.
The website alone needs node 22.12+ and npm, which installs Astro
and Starlight the first time `make website` runs.

Running the generated code needs `node` for the JavaScript targets, a C
compiler for the C ones, a JDK (`javac`/`java`) for the Java ones and an
OCaml compiler for the OCaml ones; producing it needs none of them, and running
a program with `./pyk` needs nothing at all. The compiler itself has no
third-party dependencies.
