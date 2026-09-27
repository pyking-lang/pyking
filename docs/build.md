# Building the compiler

How `src/` becomes `./pyk`, how the same code becomes the JavaScript the
playground runs, and why the split between the two is where it is. For
what each module *holds*, see [source.md](source.md); for the pipeline
they form, see [architecture.md](architecture.md).

```
make                build the compiler into ./pyk
make test           the test suite (make stest for one at a time)
make playground     serve the web playground (pyk playground)
make notebook       serve PYKING-TUTORIAL.md as a notebook (pyk notebook)
make vendor         download the browser libraries the two above need
make clean          remove _build/, ./pyk, __pycache__/
```

`make` builds two things: `./pyk`, the compiler, and
`build/pyking.js`, the same compiler as JavaScript. The second is what
the `iweb` target ships beside a program and what the playground runs,
and it is built here so there is one copy of it — the playground and
the notebook serve this file rather than building their own.

Both are copied out of `_build/`, since nobody would think to run them
from there. The copy is `cp -f` because dune leaves what it
builds read-only, and so is the copy — a second `make` would otherwise
fail to overwrite it.

**`./pyk` is a build artifact.** It is not a script any more and is not
checked in; `make clean` removes it. That is the exception that shows
the rule about what `clean` may delete: `make` chose the name itself, so
it knows the file is its own, where a *compiled program* is written
wherever the caller asked, under a name indistinguishable from
hand-written source in every target language.

## One library, one executable

`src/dune` declares two things.

**The library `pyking`** is everything pure: the lexer, the parser, the
AST, the analyses, the type checker, the optimizer, the interpreter, and
every backend. It depends on nothing outside the OCaml standard library.
Nothing in it opens a file, starts a process, or reads a terminal.

**The executable `pyk`** adds the three modules that do talk to the
outside world — `pyk.ml` (the driver, which reads the source file and
writes the output), `execution.ml` (`--run`, which starts processes) and
`repl.ml` (the prompt, which puts a terminal in raw mode) — and is the
only half that links `unix`.

The line between them is not tidiness. It is what makes the second build
possible: a library that cannot touch a process or a terminal is a
library js_of_ocaml can compile, and the browser then runs the same
type checker, the same interpreter and the same backends the terminal
does, rather than a second implementation that would drift.

The library is **unwrapped**, so its modules are reached by their own
names — `Parser.parse`, not `Pyking.Parser.parse` — and one module names
another directly. That also means the module graph has to be acyclic:
two modules of one library that refer to each other do not link. It is
why `repl.ml` is *handed* `pyk.ml`'s `format_error` as a parameter
instead of calling it (see [pyk.md](pyk.md)).

Every module has an **`.mli`** beside it, in both halves, holding what
another module may use and nothing else. See
[interfaces.md](interfaces.md) for the map of them and for what is
public where. The two entry points are the exception: `pyk.ml` and
`web/pyking_web.ml` are what a `let () = ...` runs rather than modules
anything calls, and dune gives an executable's main module an empty
interface of its own.

Warnings are on but not fatal (`-warn-error -a`), so a build fails on a
real error and not on an unused binding left behind mid-edit. With the
`.mli` files in place, an unused *private* value now warns too, which is
the compiler saying it is dead.

## The browser build

`src/web/dune` builds `pyking_web.bc.js`: the same library, plus one
entry-point module and one hand-written JavaScript stub.

- **`src/web/pyking_web.ml`** is the entry point. It registers
  `pykCompile`, `pykRun`, `pykTargets`, `pykFormatHelper`, `pykKeywords`
  and `pykBuiltins`, and does nothing a backend or the driver does not
  already do.
- **`src/web/stub.js`** is the boundary. It declares four primitives
  (`pyk_register0`, `pyk_register1`, `pyk_register3`, `pyk_emit`) with
  js_of_ocaml's `//Provides:` comments, which is all that is needed to
  put an OCaml function on the global object. No OCaml JS binding
  library is involved, which is what keeps the dependency list at
  js_of_ocaml alone, and only for this directory.

The pages ask the loaded bundle, through the worker's `words` request,
for the target list, the keyword and builtin lists, and the JavaScript
runtime's formatter. So the playground's target menu, both tools' syntax
highlighting and the playground's value formatting all come from the
compiler rather than from a hand-kept copy. See `tools/webrun/README.md`.

One thing about js_of_ocaml is load-bearing rather than incidental: its
`int` is 32 bits, where a native OCaml `int` is 63. Anything that
depends on the width has to say so.

A Pyking `Int` is one such thing, and the answer is deliberately *not*
to normalise it: an `Int` holds at least the signed 32-bit range and
overflow is undefined (PYKING.md), so the interpreter leaves results as
the host computes them. The consequence is that **the playground and the
terminal disagree past 2^31** — `2147483647 + 1` is `2147483648` under
`pyk` and `-2147483648` in the browser. Both conform, because the
language promises nothing there. What *is* the same on both is which
programs are accepted: `lexer.max_int_literal` fixes the largest literal
at 32 bits whatever the host, so the front end refuses the same source
wherever it runs.

## What is needed to build, and what is not

Building the compiler needs OCaml and dune, and nothing else. Building
the browser bundle additionally needs js_of_ocaml.

Running the *generated code* needs whatever that target's host needs —
`node` for the JavaScript targets, a C compiler for `c89`/`c23`, a JDK
for the Java ones, `ocamlopt` for `ocaml5.5` — but none of that is needed
to *produce* the code, and none at all to run a program with
`pyk <file>`, which is the interpreter.

The test harness (`tests/test_script.py`) is Python 3.11+. The web tools'
servers (`tools/webrun/server.py`) need Python 3.14+ and check for it.
Both are tooling around the compiler, not part of it.

## The web tools

`pyk playground` and `pyk notebook FILE.md` start a web page that runs
the compiler in the browser: the playground, and a Markdown document
whose Pyking code blocks are runnable cells. Neither is built. Each is a
directory of JavaScript, CSS and HTML under `tools/`, served from where
it sits by a small Python server:

```
tools/webrun/     what both share: server.py, the compiler's worker and
                  runtime, the Ace mode, and vendor/ (Ace, KaTeX)
tools/playground/ playground.py and its page
tools/notebook/   notebook.py and its page
build/pyking.js   the compiler, which both pages load
```

`pyk` itself does not serve anything. `src/web_tools.ml` finds
`tools/<tool>/<tool>.py` beside the running executable, runs `$PYTHON`
(else `python3`) to check it is 3.14 or later, and replaces its own
process with that script (`execvp`), passing `--port` and the document
on. `make playground` and `make notebook` go through `./pyk` the same
way, after `make vendor` has downloaded Ace and KaTeX once.

### What a distribution needs

The compiler is one native executable with no OCaml runtime to install:
`./pyk` needs nothing but the C library to compile or interpret a
program. OCaml, dune and js_of_ocaml are needed to *build* it, never to
use it.

The web tools add one dependency, and only for someone who uses them:
Python 3.14 or later, standard library only. A distribution is a subset
of this repository's tree, kept at the same relative paths so that one
lookup — beside the executable — works in a checkout and an install
alike:

```
pyk                   the compiler
lib/                  the standard library
build/pyking.js       the compiler as JavaScript, for the pages
tools/webrun/         including vendor/, downloaded before packaging
tools/notebook/
tools/playground/
```

The playground's examples come from `tests/`, which a distribution need
not ship; without it the page starts with a short program of its own
and offers no example menu.
