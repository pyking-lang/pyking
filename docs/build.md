# Building the compiler

How `src/` becomes `./pyk`, how the same code becomes the JavaScript the
playground runs, and why the split between the two is where it is. For
what each module *holds*, see [source.md](source.md); for the pipeline
they form, see [architecture.md](architecture.md).

```
make                build the compiler into ./pyk
make test           the test suite (make stest for one at a time)
make playground     build and serve the web playground
make clean          remove _build/, ./pyk, __pycache__/, the playground's build/
```

`make` builds two things: `./pyk`, the compiler, and
`build/pyking.js`, the same compiler as JavaScript. The second is what
the `iweb` target ships beside a program and what the playground runs,
and it is built here so there is one copy of it — `tools/playground`
reuses this rather than running a dune build of its own.

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

`tools/playground/generator.py` runs that build, then asks the resulting
bundle — with `node` — for the target list, the keyword and builtin
lists, and the JavaScript runtime's formatter, and writes them into the page's
assets. So the playground's target menu, its syntax highlighting and its
worker's value formatting all come from the compiler rather than from a
hand-kept copy. See `tools/playground/README.md`.

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

The test harness (`tests/test_script.py`) and the playground generator
(`tools/playground/generator.py`) are Python 3.11+. They are tooling
around the compiler, not part of it.
