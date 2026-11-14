---
title: Command line
description: Every pyk command and its flags, where pyk compile writes, the library search path and the exit codes.
sidebar:
  order: 4
  group: Tools
---

Everything Pyking does is one program, `pyk`. Given a file, it runs it
with the interpreter. Given a command word first, it does that instead:
compile, start the REPL, serve a notebook or the playground, and so on.

`pyk` on its own prints a short usage and exits with status 1.
`pyk --help` prints all of it: every flag, the targets and their
versions, the warnings, and a paragraph on each command. `pyk --version`
prints the version.

## The commands

| Command | What it does |
|---|---|
| `pyk prog.pyk [-- args]` | Run the program with the interpreter. |
| `pyk prog.pyk -t T [-- args]` | Compile it for target `T` and run it. |
| `pyk compile prog.pyk` | Compile it (default target: `python`). `pyk c` is the same. |
| `pyk repl` | Start the [REPL](/documentation/repl/). |
| `pyk notebook book.md` | Serve a [notebook](/documentation/notebook/) and open it in the browser. |
| `pyk playground` | Serve the [playground](/documentation/playground/) locally. |
| `pyk pykhelp` | Serve this documentation locally. |
| `pyk serve [dir or file]` | Serve a directory's files, such as a compiled web page. |
| `pyk example [name]` | List the bundled examples, or save one. |
| `pyk highlight file` | Colour Pyking code for slides: HTML, RTF or text. |
| `pyk lsp` | The language server, started by an [editor](/documentation/editors/). |
| `pyk dap` | The debug adapter, started by an editor. |
| `pyk plugins dir` | Build the interpreter's plugins for a directory of libraries. |

Pyking is statically typed: every program is type-checked before it
runs or compiles, and there is no flag to skip that.

## Running a program

```sh
pyk prog.pyk
```

runs the program with the interpreter. Nothing is written to disk. The
interpreter is the reference for what a program means: it reports a
runtime error as a Pyking error, with its position in the source and
the calls in progress.

Everything after `--` is given to the program, and `sys.args()`
answers with it:

```sh
pyk prog.pyk -- apples pears
```

```args
apples pears
```

```pyking
import sys

for name in sys.args():
    print("hello,", name)
```

With `-t`, the program runs on a compiled target instead of the
interpreter. It is compiled into `build/`, built and run from there, and
nothing is put beside `build/`:

```sh
pyk prog.pyk -t node
pyk prog.pyk -t c-gc -- apples pears
```

`--tinyweb-log` prints what a program sends its tinyweb page, and what
the page answers, on standard error while it runs. It applies to
`pyk prog.pyk` and `pyk repl`.

## `pyk compile`

```sh
pyk compile [options] prog.pyk
pyk c [options] prog.pyk
```

`pyk compile` translates the program for a target, builds it with that
target's own tools, and leaves an executable beside the source. The
target is `python` unless `-t` says otherwise:

```sh
pyk compile hello.pyk              # build/hello.py, and ./hello runs it
pyk compile -t c hello.pyk         # build/hello.c, and the binary ./hello
pyk compile -t java hello.pyk      # build/Hello.java, and ./hello runs it
```

[Compiler targets](/documentation/targets/) lists every target, what it
writes and what it needs to run.

| Flag | What it does |
|---|---|
| `-t T`, `--target T` | Compile for target `T`: a family (`python`, `node`, `web`, `iweb`, `c`, `c-gc`, `java`, `ocaml`, `pyking`) or a version (`python14`, `c89`, `java8`, ...). |
| `-o FILE`, `--output FILE` | Name the executable. `build/` goes beside it: `-o out/hi` writes `out/hi` and `out/build/`. |
| `--run` | Build and run what was compiled, printing each command first. |
| `--stdout` | Print the generated code for the program's own module, and write nothing. |
| `--no-build` | Write `build/` and its `Makefile`, and build nothing. |
| `--release` | Remove every call to `debug()`. `print()` is kept. |
| `-- args` | With `--run`: arguments for the program. |

### What it writes

Everything generated goes into a directory `build/` beside the
executable: the program's file, one per module it imports, the
target's runtime files, and a `Makefile`. Then `pyk compile` builds it
and puts the executable in place:

- for C and OCaml, the binary itself;
- for Python, node and Java, a short shell script that runs what is in
  `build/`;
- for `web` and `iweb`, nothing: the page and its files are all in
  `build/`.

```sh
$ pyk compile hello.pyk
$ ls
build  hello  hello.pyk
$ ls build
Makefile  hello.py
$ ./hello
Hello, world!
```

`build/` is made afresh on every compile. A `build/` that an earlier
`pyk compile` made is replaced. Any other `build/` is left alone and the
compile is refused, so `pyk` never removes a directory of yours; move it
or compile elsewhere with `-o`.

`build/Makefile` holds the same commands `--run` uses: `make` builds,
`make run` runs (`make run ARGS='a b'` passes arguments), and
`make clean` removes what `make` made. Each tool is a variable, such as
`CC`, `JAVAC` or `PYTHON`.

The Java targets name the file and its class in Java's style:
`foo_bar.pyk` becomes `build/FooBar.java`. The `pyking` target writes
its one `.pyk` file where `-o` says, and builds nothing.

### `--run`

`--run` builds what was compiled and runs it with the target's own
commands. Each command is printed on standard error, after `$ `, so the
program's own output on standard output stays clean:

```sh
$ pyk compile -t c --run hello.pyk
$ cc -std=c99 -o hello hello.c -lm
$ ./build/hello
Hello, world!
```

A `web` or `iweb` page is run by serving it: `--run` starts
`pyk serve` and prints a link to the page.

`$PYTHON`, `$NODE`, `$CC`, `$JAVAC`, `$JAVA` and `$OCAMLOPT` choose the
tool to use where there is a choice.

`--run` cannot be combined with `--stdout`, since there is no file to
run. `pyk compile` without `--run` runs nothing, so it refuses
arguments after `--`.

### `--stdout`

```sh
pyk compile -t node --stdout hello.pyk
```

prints the generated code and writes nothing. It shows the program's
own module only; the modules it imports are files of their own. This is
a quick way to see what Pyking compiles to; the playground's Compiled
code tab shows the same.

### `--release`

`--release` removes every call to `debug()` before the program is
compiled, so a release build writes nothing to standard error through
`debug`. It applies to `pyk compile` only: the interpreter always runs
a program as written.

## `pyk repl`

```sh
pyk repl [--use FEATURE]... [-L DIR]... [-W...] [--tinyweb-log]
```

Starts the REPL. `--use mutation` turns a feature on from the start, as
a `use` line typed at the prompt would; the features are `mutation`,
`pointers` and `objects`. `pyk repl` takes no file. See
[REPL](/documentation/repl/).

## `pyk notebook`

```sh
pyk notebook [--port N] [--mode student|teacher|test] book.md
```

Serves a Markdown notebook, whose Pyking code blocks can be edited and
run in the browser, and prints a link to open it. The page reloads when
the file changes.

| Flag | What it does |
|---|---|
| `--port N` | Serve on port `N`. |
| `--mode student` | The default: a task's solution and tests stay hidden until the reader asks for them. |
| `--mode teacher` | Show every block, and what test mode finds under each. |
| `--mode test` | Serve nothing: run every cell, task and solution, check each against the expected output after it, print `file:line: message` for each problem, and exit with 1 if there is one. |
| `--to-json` | Write the notebook's Markdown as JSON: `book.md` to `book.json`. |
| `--to-markdown` | Write a notebook's JSON back as Markdown. |
| `--json-schema` | With no file: write the JSON Schema of every notebook's JSON, `notebook.schema.json`. |
| `-o FILE` | With the three above, name the file written; `-o -` prints it. |
| `-W...` | The warnings the page shows under a block. |

The three conversions never write over an existing file of the default
name. See [Notebook](/documentation/notebook/).

## `pyk playground` and `pyk pykhelp`

```sh
pyk playground [--port N]
pyk pykhelp [--port N]
```

`pyk playground` serves the [playground](/documentation/playground/)
and prints a link to it. `pyk pykhelp` serves this documentation, with
its runnable examples, the same pages the playground's Help tab shows.
Both run until Ctrl+C.

## `pyk serve`

```sh
pyk serve [--port N] [DIR | FILE]
```

Serves a directory's files as they are: the current directory by
default. Given a file, it serves the file's directory and prints a link
to the file. This is how to open a page compiled for `web` or `iweb`,
since a browser will not load its modules from a `file://` address:

```sh
pyk compile -t web game.pyk
pyk serve build/game.html
```

## Ports and addresses

`pyk notebook`, `pyk playground`, `pyk pykhelp` and `pyk serve` start at
port 8000 and take the first free port up to 8019, or any free port if
those are all taken. `--port N` asks for port `N`. They listen on
`127.0.0.1`, or on the address `$PYKING_WEB_HOST` names, for example
`0.0.0.0` for every interface, as in a container.

## `pyk example`

```sh
pyk example            # list the examples
pyk example hello.pyk  # save one in the current directory
```

`pyk example` lists the bundled example programs with a line on each.
`pyk example NAME` saves the one named in the current directory, and
refuses if a file of that name is already there. The playground's
Examples menu offers the same programs.

## `pyk highlight`

```sh
pyk highlight FILE [--html | --rtf | --text] [--theme light|dark] [-o OUT] ...
```

Writes Pyking code coloured as the playground colours it, for pasting
into slides: HTML with every style inline, RTF, or plain text. `FILE`
is a program or a notebook. `pyk highlight --help` lists its options;
[Code on slides](/documentation/slides/) explains them.

## `pyk lsp` and `pyk dap`

```sh
pyk lsp [--stdio] [-L DIR]... [--log FILE] [-W...]
pyk dap [--stdio] [-L DIR]... [--log FILE] [-W...]
```

An editor starts these; you do not run them yourself. `pyk lsp` is the
language server and `pyk dap` the debug adapter. Both talk over
standard input and output; `--stdio` is accepted and is the only
transport. `--log FILE` appends every message to `FILE`, which helps
when finding out what an editor sent. See
[Editors](/documentation/editors/) and
[Debugging](/getstarted/debugging/).

## `pyk plugins`

```sh
pyk plugins DIR
```

For library authors. The interpreter runs a module implemented in
another language through its OCaml implementation,
`NAME_external.ml`, loaded as a plugin. Without a prebuilt plugin, `pyk`
compiles one on first use into `~/.cache/pyking`, which needs the same
`ocamlopt` that `pyk` was built with. `pyk plugins DIR` builds the
plugin of every library in a directory of libraries ahead of time,
beside its implementation, and skips any that are up to date. The
standard library's plugins ship with `pyk`. See
[Compiler targets](/documentation/targets/#external-modules).

## Warnings

A warning is printed on standard error and the program still runs or
compiles. The `-W` flags apply to `pyk prog.pyk`, `pyk compile`,
`pyk repl`, `pyk lsp`, `pyk dap` and `pyk notebook`, in the order
given.

| Flag | What it does |
|---|---|
| `-Wname` | Turn warning `name` on. |
| `-Wno-name` | Turn it off. |
| `-Wall` | Turn every warning on. |
| `-w` | Turn every warning off. |
| `-Werror` | Make every warning that is on an error, which stops the program before it runs. |
| `-Werror=name` | Make one warning an error, and turn it on. |
| `-Wno-error`, `-Wno-error=name` | Undo those. |

| Warning | On by default | Reports |
|---|---|---|
| `unused-binding` | yes | A name bound with `=` that nothing in its scope uses. |
| `unused-function` | yes | A `def` that is never called or passed on, or only calls itself. |
| `unused-var` | yes | A `var` that is never read. Writing it with `:=` does not count. |
| `shadowed-update` | yes | An `=` inside a block, never used, that shadows a name from outside: an update written as a new binding. |
| `shared-fill` | yes | `array(n, v)` where `v` is itself an array, so every element is the same one. |
| `unused-pattern-var` | no | A name a `case` pattern binds that its arm never uses. |
| `unused-parameter` | no | A parameter its function or lambda never uses. |
| `unused-loop-var` | no | A loop's accumulator, a `for` variable, or a name a comprehension binds, that the loop never uses. |

A name starting with `_`, a public name, and a name in a library's
module are never reported.

```sh
$ pyk -Werror prog.pyk
'prog.pyk' 2:4-2:5 Error: Unused binding 'y', bound on line 2: it is
  never used in its scope. [-Werror=unused-binding]
```

## The library search path

`import name` looks for the module in these places, in order, and the
first that has it wins:

1. the directory of the file that imports it: `name.pyk`, or
   `name_external.pyk` for a module implemented in another language;
2. each `-L` directory, in the order given;
3. each directory in `$PYKING_LIB_PATH`, separated by `:` (by `;` on
   Windows);
4. the `lib/` directory beside the `pyk` executable, which holds the
   standard library.

A `-L` directory holds one folder per library: `-L libs` finds
`libs/shapes/shapes.pyk` for `import shapes`. The flag can be written `-L DIR`,
`-LDIR`, `--lib-path DIR` or `--lib-path=DIR`, and repeated. When a
module is found nowhere, the error lists every path it looked in. See
[Modules](/documentation/language/modules/).

## Environment variables

| Variable | What it does |
|---|---|
| `PYKING_LIB_PATH` | More library directories to search; see above. |
| `PYKING_WEB_HOST` | The address the web commands listen on. |
| `PYTHON`, `NODE`, `CC`, `JAVAC`, `JAVA`, `OCAMLOPT` | The tools `--run`, the `Makefile` and plugin builds use. |
| `PYKING_TINYWEB_LOG=FILE` | Run a tinyweb program with no page: each command it sends is appended to `FILE`. |
| `PYKING_TINYWEB_EVENTS=FILE` | With the log: events to deliver once the top level has ended, one per line (`click ID`, `key NAME`, ...). |

## Errors and exit codes

Every error names the file, the span in it, and the kind of error, and
is wrapped to 70 columns:

```sh
$ pyk prog.pyk
'prog.pyk' 2:6-2:11 Runtime error: the index 5 is outside a list of 2
  elements
```

The kinds are `Lexing error`, `Parsing error`, `Module error`,
`Name error`, `Type error` and `Runtime error`. A construct a target
cannot compile is refused before any code is written, naming the
target:

```sh
$ pyk compile -t c squares.pyk
'squares.pyk' 1:5-1:14 Unsupported by target 'c99': a list, which
  needs a heap that is freed: plain C has none, and c23-gc compiles it
```

A command-line mistake prints `Usage error:` and the short usage.

| Status | When |
|---|---|
| 0 | The program ran to its end, or the command did what it was asked. |
| 1 | An error in the program (lexing, parsing, a module, a name, a type, a runtime error), a warning made an error by `-Werror`, a usage error, or a failed `--mode test`. |
| `code` | The program called `sys.exit(code)`. |
| the program's own | With `--run` or `-t`: the status of the compiled program, or of the build step that failed. 127 if a tool was not found. |
| 2 | A fault in `pyk` itself. The message says so; please report it. |

## Looking inside the compiler

These flags are for people curious about, or working on, the compiler.

| Flag | What it does |
|---|---|
| `--tokens` | Print the token stream first. |
| `-t pyking` | Compile Pyking to Pyking: the program as the front end understood it, with inferred types and the loops the tail-call pass built. |
| `--symbols` | With `-t pyking`, also print each node's symbol. |
| `--no-tail-call-opt` | Leave tail calls as calls, instead of turning them into loops. |
| `--no-typechecking` | Only with `pyk compile -t pyking`: print the program as parsed, with nothing inferred. |
| `--type-experiment` | Check the program with an experimental, partial type checker. |
