# `pyk.ml`: design

How `src/pyk.ml` — the command-line driver — is put together: why it
stays thin, how `options` and `targets` are built so they can't drift
from what the backends actually support, and how one front end feeds
three different commands. For the pipeline itself, see
[architecture.md](architecture.md), "Command line"; for a one-page
summary, see [source.md](source.md#pykml).

## What the driver does, and what it deliberately doesn't

`pyk.ml`'s job is narrow on purpose: parse `argv`, run the front-end
stages every command needs, dispatch to one of three command functions,
and format whatever error comes back. Running what was *compiled* is
`src/execution.ml`'s, by the same rule: which command builds a `.c` and
which runs the binary is that target's knowledge, not the driver's. Every backend owns its **own**
translation, packaging, and file naming — `command_compile` calls
`target_c.translate_program`, `target_java.default_class_name`,
`target_js_packaging.package`, and so on, but never reimplements what
any of them decide. That division matters for the same reason
`architecture.md` states it does: a backend added or changed doesn't
need the driver to change with it, because the driver never encodes
backend-specific knowledge — it only sequences calls into modules that
each know their own business.

## `Options`: one value, flags shared by every command

`options` is a single record carrying the command, the filename, and
every flag — `target`, `output`, `stdout`, `run`, `symbols`, `tokens`,
`tail_calls`, `release`, `typecheck`, `type_experiment` — regardless of which command was
actually invoked. That's a deliberate choice over, say, three different
per-command option types: it's what makes `--tokens` and `--symbols`
mean the *same thing* wherever they're written, since there's exactly
one code path (`front_end`, then `main`) that interprets them, rather
than three copies of that interpretation that could quietly drift apart.
`parse_args` builds one `options` from `argv` regardless of which
command word appeared (or was left out — a bare `pyk foo.pyk` defaults
to `"interpret"`, `default_command`, on the theory, stated in the
comment beside it, that someone holding a file almost always wants to
just run it).

## `targets`/`extensions`: assembled from the backends, not stated here

```ocaml
let targets =
  ([ "python" ] @ Target_js_packaging.targets @ Target_c.standards
 @ Target_java.versions
  @ [ Target_ocaml.target; pyking_target ])
```

Nothing in this module *lists* the compiling targets by name — it concatenates
each backend's own declaration of what it supports
(`Target_js_packaging.targets`, `Target_c.standards`, ...). That's what
makes the usage message, `--target`'s validation, and the default
output extension (`extensions`, built the same way) impossible to leave
stale when a target is added: a new C standard added to
`Target_c.standards` shows up in `pyk --help`'s target table
automatically, with no second place in this file to remember to update.
The playground goes one better: its page asks the *compiled* compiler
for the same list (`pykTargets`), so its dropdown cannot drift from it
either — see that tool's own documentation.

## `front_end`: the stages every command shares, with one branch

`front_end(options)` runs every stage before a backend, in the order
they run: loading the modules the program is made of, and then, once per
module, type checking, the mutability analysis, the overloading and
implicits pass, and the tail-call pass.
It answers with each module paired with the types worked out for it.
That the order lives here and nowhere else is deliberate — no stage reaches for
another one on its own, which is why `interpreter.check` no longer
exists and why `target_ocaml.translate_program` takes the table rather
than filling it. Every command needs this much; nothing past it is
shared, and there is no branch in it at all.

There used to be one. Type checking was a *mode*, and a `required` flag
decided whose refusal counted — `pyk run`'s, the `ocaml5.5` target's, and
`--typecheck`'s. Pyking is statically typed now, so the question is
gone: the checker runs, and a program it refuses is refused. What
follows from that is that the checker is also the **only** pass that
checks names. Its `Env` **is** a scope and derives every rule the old
`analyze_program` did, in the identical wording (`typesystem.ml` raises
`Analyses.Analysis_error` for an unbound name, imported rather than
reimplemented, specifically so `format_error` can't tell which pass
caught it from the message alone).

What is left in `src/analyses.ml` runs *after* the checker, and is one
rule: `:=` may only name a `var`, and nothing may shadow one. It goes
second precisely because by then every name is known to be bound, so a
name the mutability walk cannot find is never "unbound" — it is
"not a mutable variable", which is the message worth printing.

Between that walk and the tail-call pass, `src/elaborate.ml` removes
overloading and implicit arguments from the program, reading the second
table the checker answers with (`qmap`): a qualified name becomes a
plain one, a resolved call names the definition it reaches, and an
implicit parameter becomes an ordinary argument. It is the same bargain
the tail-call pass makes -- AST in, AST out, before anything else reads
the program -- so nothing the driver sequences after it, and no backend,
knows either feature exists. It hands out symbols for the nodes it
builds and extends `tmap` for them, since the checker does not run
again (see [implicits.md](implicits.md)).

Earlier still, `module.load` desugars each module: default parameters
and named arguments become ordinary defs and ordinary calls before
anything is symbolized, so nothing the driver sequences knows the sugar
exists (see [desugar_args.md](desugar_args.md)).

Symbolizing runs before either of them, because both `--symbols` output
and `tmap` need every node keyed by a stable symbol. It happens in
`module.load`, which is also what makes the numbering span the whole
program rather than restarting per module -- a single table for the
types and a single one for the interpreter's call-free expressions both
depend on that (see [modules.md](modules.md)).

**A program of several modules runs the middle of the pipeline once per
module.** `module.load` answers with them in dependency order, and the
loop that follows is the second and third of the three steps the module
system takes: check this module against the signatures of the ones it
imports, then take its own signature from the result for the next one.
The tail-call pass runs per module too, and the symbols it hands out
continue past the highest anywhere in the program, which is why
`optimize_module` takes and returns that number rather than asking each
module's own tree.

The tail-call pass (`src/opt_tailcall.ml`) sits between symbolizing and
type checking, and that position is the whole of its wiring: it rewrites
before *anything* reads the program, so `-t pyking` prints what it built,
the checker checks that, and `tmap` is keyed to it — which the OCaml
backend depends on, since it reads types back rather than inferring
them. `symbolize` runs a second time afterwards, for the nodes the pass
built; it keeps the symbols already handed out, so a statement the pass
moved carries its own identity through. `--no-tail-call-opt` is the one
flag that turns a stage *off* rather than asking for output, which is
why it is documented under `--help` rather than in the usage every
mistyped command prints.

`--release` is the one that removes something a program wrote: every
call to `debug`, by `release.ml` over each module after `elaborate.ml`
and before the tail-call pass. It changes what is *compiled*, so
`parse_args` refuses it for any command but `compile`, and for
`--no-typechecking`, since the pass reads the checker's table to tell
the builtin from a program's own `debug`. The C and Java targets are
handed what `Prune.program` leaves of the modules a program imports
(`compile_program`), since both compile a subset and a library's
function nobody calls must not decide whether a program compiles.

`--no-typechecking` is the second flag that turns a stage off, and it
turns off four: the module system, the checker, the mutability analysis
and the tail-call pass -- the last two because neither runs without what
the checker works out, and the module system because comparing this
front end against the OCaml one is the whole reason the flag exists, and
that one reads a single file. So it reads a single file too
(`module.read_file`), and nothing the program imports is opened at all.
`front_end` then returns after `symbolize` with no table at all,
and `parse_args` refuses the flag anywhere but `compile -t pyking` --
every other target reads the types, the Python backend to know what to
format and the OCaml one for every type it emits, and so does the
interpreter. What `-t pyking` prints under it is the program as
written, with the source's own annotations and its default parameters
and named arguments still in it: the parser's output with nothing
inferred on top of it and nothing rewritten away, which is what makes
it worth having when the question is what the front end built rather
than what the checker made of it. That view is the `pyking_nosugar`
test target, and the only place the sugar's own printed form is
pinned.

`compiling_natively(options)` is the other half of that wiring: a target
whose host eliminates tail calls itself gets the program as written,
since the pass would only be undone there. Which targets those are is
`native_tail_calls`, a plain list of names here rather than something
asked of each backend -- unlike `targets` and `extensions`, which each
backend really does own, this is the driver's own decision about which
stage to run.

## Two lengths of help

`_SYNOPSIS` is what someone who typed `pyk` by itself needs: the shape
of the command, and the flags that change what it *produces*.
`USAGE_FULL`, printed for `--help`, adds `_MORE_OPTIONS` — `--symbols`,
`--tokens`, `--no-tail-call-opt`, `--no-typechecking` — plus the target
table, the commands
`--run` uses for each target, and the paragraphs about what each command
does. The split is by *who is
asking*: the short form answers "how do I run this", and the three flags
in the long form are ones nobody needs to know about to use the
compiler at all. `usage_error` prints the short form, since a mistyped
command is not a request for a manual.

## One table, one function, six kinds of error

```ocaml
let format_error error =
  let line label i message = ... in
  match error with
  | Lexer.Lex_error (i, message) -> line "Lexing error" i message
  | Parser.Parse_error (i, message) -> line "Parsing error" i message
  | Module.Module_error (i, message) -> line "Module error" i message
  | Analyses.Analysis_error (i, message) -> line "Name error" i message
  | Typesystem.Type_error (i, message) -> line "Type error" i message
  | Type_experiment.Type_error (i, message) -> line "Type error" i message
  | Interpreter.Runtime_error (i, message) -> line "Runtime error" i message
  | _ -> None
```

Every stage that can refuse a program raises its own exception, and
every one of them carries an `info`. `format_error` doesn't need six
different formatting functions because of that uniformity — it's one
`match` with a line per stage, and the *only* thing that differs
between a lexical failure and a runtime one is which label gets
printed. It answers `string option` rather than raising on something it
does not recognize, which is what lets a caller with an exception that
is not a Pyking error re-raise it unchanged. This is the same function
`src/repl.ml` is handed (`start` takes `format_error` as a parameter
specifically so a mistake made at the REPL prompt is reported in the
exact words a file would get — see that module's own page), and it's why
adding a seventh kind of front-end error later would mean adding one
line here, not writing a new formatting function -- which is exactly
what `Module error` was. `Type_experiment.Type_error` is the seventh
line and says the same word as the sixth: `--type-experiment` swaps
which checker runs, not how its refusal reads.

`fail_unsupported` is kept separate from `format_error`'s match on
purpose: an `Unsupported` needs to name *which target* refused the
construct (`"Unsupported by target 'node24': ..."`), a piece of context
none of the front-end errors need, since they're refused by the front
end itself rather than by one particular backend's subset.

## `command_compile`: one function, one `write` closure reused everywhere

`command_compile` picks the output path if
`--output` wasn't given, asks `compile_program` for every file the whole
program becomes, and writes them -- or prints the one `--stdout` asks
for, which is the program's own module, since the modules it imports are
files and `--stdout` writes none.

`compile_program` is a loop over the program's modules: each one's file
goes beside the program's own output under its own name, and
`compile_unit` dispatches on `target` to the right backend's
translate/print calls for one module. Two targets do not fit that loop
and say so where they are: the JavaScript ones package a whole program
at once (a page holds every module; the other two share one runtime
module), and C and OCaml answer with a companion file -- a header, an
interface -- beside the module's own.

Two small closures capture the two safety rules every write has to obey,
defined once and reused across every target's branch rather than
repeated:

- **`write(path, contents)`** refuses to write over the *input* file
  (comparing absolute paths, so `hello.pyk` compiled to `-o hello.pyk`
  by mistake is caught even through a relative-path spelling
  difference) and refuses to write into a directory that doesn't exist —
  both as `usage_error`s, not stack traces, since both are mistakes a
  user made, not the compiler.
- **`write_manifest(path, contents)`** is the JavaScript targets' one
  special case: the
  target's own `package.json` is never blindly overwritten, because an
  existing one belongs to whatever project the output landed in (see
  `target_js_packaging.md`). It only writes a fresh manifest when none
  exists yet; when one does and doesn't already declare `"type":
  "module"`, it warns and leaves the file alone rather than silently
  changing (or silently *not* changing, without saying so) a file this
  driver didn't create.

The per-target branches in `compile_unit` are mostly symmetric —
translate, catch that backend's own `Unsupported` and hand it to
`fail_unsupported`, answer with the text — with two real asymmetries
worth noting: the C branch passes `target` itself as the `standard` parameter
(`target_c.ml` serves both `c89` and `c23` from one function, gated by
exactly that string — see that backend's internals page), and the Java
branch has to work out the class name *before* it can print anything,
since the class name has to match whatever file name was chosen (an
explicit `--output`'s own stem, or `target_java.default_class_name`'s
Java-cased default) — a dependency none of the other targets have,
because none of them require the file and the code inside it to agree
on a name.

Every backend that needs to know anything about the module *as part of a
program* -- its name, whether it is the program's own, what the modules
it imports export -- is handed one value for all of it,
`module.Context`, rather than a growing list of parameters. A program of
one module gets a `Context` saying so, which is what keeps a single-file
program's output byte-for-byte what it was before there were modules.

## `build/`: where `pyk compile` writes, and what it leaves beside it

`pyk compile foo.pyk -t ocaml` writes every file it generates into a
directory `build/`, and leaves one thing beside it: the executable,
`./foo` -- or the name `-o` gives, `-o out/hi` putting `out/hi` beside
`out/build/`. The generated files inside are named as they always were,
after the executable's name (`build/hi.ml`, `build/Hi.java`), and the
program's modules, runtimes and libraries' implementations and assets
sit beside them.

- `build/` is made afresh each time. One an earlier `pyk compile` made
  holds `.pyk-build` (`build_marker`), and is removed first
  (`remove_tree`, which never follows a link); any other `build/` is
  refused rather than removed, since it is somebody's own.
- `build/Makefile` (`Execution.makefile`) says the same commands `--run`
  uses: `make` builds, `make run` runs (`ARGS` passes arguments), `make
  clean` removes what `make` made. Each tool is a variable (`CC`,
  `OCAMLOPT`, `JAVAC`, `JAVA`, `PYTHON`, `NODE`, `PYK`).
- `pyk compile` then builds it with the target's own tools
  (`Execution.build`) and puts the executable in place
  (`place_executable`): the binary itself for C and OCaml; for Python,
  Node and Java a launcher, a shell script running what is in `build/`
  (`Execution.launcher`); nothing for a page, whose files are all in
  `build/`.
- `--run` then runs it, in the directory the executable is in, as
  before. `pyk <file> -t <target>` is the same with nothing put beside
  `build/`: built there, and run from there.
- `--no-build` writes `build/` and its Makefile and builds nothing --
  for the test harness and the website's examples, which build with
  their own flags.
- `--stdout` writes nothing, and `-t pyking` writes its one file where
  `-o` says, as it always did: the Pyking it prints is a view of the
  program rather than something to build.

A library's assets are copied into `build/`, so tinyweb's C and OCaml
implementations, which look beside where the program runs and beside the
executable, look in the `build/` there too.

## Running what was compiled: `--run` and `src/execution.ml`

`--run` compiles for the selected target and then builds and runs the
result the way a user would by hand. What each target needs to do that
is that target's own knowledge — `node prog.js`, but `cc -std=c89 -o
prog prog.c` *and then* `prog` — so it lives in `src/execution.ml`, not
here. The driver's part is three calls at the end of
`command_compile`: `Execution.makefile`, written into `build/`;
`Execution.build`, run there; and, for `--run`, `Execution.run`, in the
directory the executable is in.

`plan_for(target, path, modules)` answers with a `Plan`: the build
commands (each of which must succeed), the command that is the program
itself, and the directory to run them in. `modules` names the files the
program's other modules were compiled to, in dependency order --
which C, Java and OCaml need, since those three *link* a program rather
than importing at run time, and for OCaml that order is also the order
the modules' top levels run in. Everything in it is made absolute, since the
commands run in the *output file's* directory rather than the one `pyk`
was called from — which is what makes the generated `package.json`
and Java's `-cp` find what they expect. `shown` puts them back for the
announcement: relative to the directory the command runs in, with `./`
on the program being run, since a bare name would mean PATH.

Every command is printed before it runs, prefixed `$ `, on **stderr**:
the program's own output belongs on stdout, and mixing the two would
make `pyk c --run … > out.txt` capture the wrong thing. `$CC`, `$JAVAC`,
`$JAVA` and `$OCAMLOPT` name the tools where there is a choice — the
same variables `tests/test_script.py` reads, so a machine set up to run
the suite is set up to run this.

Two targets are runnable in a way the others are not, and both are the
table's business rather than a special case here. `web` and `iweb` are
pages, so running one means serving it: `pyk serve` handed the page
itself, which serves its directory and prints a link straight to the
page. `pyking`
compiles Pyking to Pyking, so running it means handing it back to this
compiler: this very executable, run on the generated source, which is
the interpreter.

`--run` with `--stdout` is refused in `parse_args` rather than here,
because it is a statement about the *arguments*: `--stdout` writes no
file, so there is nothing for `--run` to run.

## `pyk <file>`: the interpreter, and the plugins it loads first

A runtime error raised in a library's own code -- a file under one of
the library directories (`Module.in_library`) -- is reported where the
program called into the library, the trace going on from there
(`Interpreter.outside_libraries`); the REPL does the same with an
entry's error.

With `-t <target>`, `pyk <file>` runs the program on that target
instead: compiled into `build/`, built and run from there -- `pyk
compile --run` with nothing put beside `build/` (see "`build/`").

`command_interpret` loads the plugin of every module the program reaches
with a declaration half (`Plugin_host.load`, which refuses one with no
OCaml implementation, or whose plugin cannot be built or loaded, as a
`Module error`), sets `Sys.argv` to the program's own file and
arguments, and runs the modules with a host whose `externals` are those
plugins. Once the top level has ended it runs what a plugin asked
`Pyk_plugin.after_program` for -- tinyweb's events, from its events file
or from the page it serves -- and reports a runtime error a callback
raises like any other. A program using tinyweb is run here like any
other: it serves its own page once it calls `web_init`.
`pyk plugins <dir>` (`command_plugins`) builds plugins ahead of
time, beside each library's implementation, skipping one whose digest
says it is current; `make libs` runs it over `lib/`. See
[libraries.md](libraries.md), "How the interpreter reaches an OCaml
implementation".

A web program's `print` writes through the `io` library, so
`compile_program` ships that library's browser implementation with every
`web24` and `iweb24` program -- found the way an import of `io` would
find it (`Module.found_implementation`) -- where the program does not
import `io` itself.

## `pyk notebook`, `pyk playground` and `pyk serve`

The three web commands run no front end at all, and `main` dispatches
them before `front_end` is reached. All the driver does is
`command_web`: it calls `Web_tools.start`, which serves the page from
`tools/` with `src/web_server.ml` in this process until Ctrl+C, and
prints the reason only when it could not start. `pyk serve` takes a
directory, the current one by default, and serves its files as they
are; `--run` uses it for a `web24` or `iweb24` page. `--port` is theirs alone and refused elsewhere, as `--`
is refused for them, and `--mode` (student, teacher or test) is the
notebook's alone: it is handed on, and test mode refuses `--port`, since
it serves nothing. See [build.md](build.md), "The web tools".

## `pyk example`

`pyk example` lists the examples in `src/examples.toml` beside the
executable, one per line under the headings "File name" and
"Description", and `pyk example NAME` copies the one saved as
`NAME` into the current directory, refusing to overwrite a file already
there. It runs no front end. A package ships the list and the programs it
names at the same paths (`tools/packaging/packaging.py`,
`examples_shipped`), so it works the same in a checkout and an install,
and the playground offers the same list. See [source.md](source.md),
"examples.ml".

## `pyk lsp`: the language server's transport

`pyk lsp` runs no front end of its own either: `command_lsp` reads
JSON-RPC messages framed by `Content-Length` from standard input with
`Unix.read`, hands each to `Lsp.handle`, and writes what comes back.
When no message has arrived for 200 ms it calls `Lsp.idle`, which checks
the documents a change marked and publishes their diagnostics -- the
debounce, kept out of `lsp.ml` so the browser can time it its own way.
The library path is `pyk`'s own (`-L`, `$PYKING_LIB_PATH`, the built-in
`lib/`). `--log FILE` appends every message in (`-->`) and out (`<--`).
Standard input closing without `exit` ends it with status 1, as the
protocol says. See [../design/lsp.md](../design/lsp.md).

## Why `repl.ml` is handed `format_error`

```ocaml
if options.command = "repl" then Repl.start format_error
```

`repl.ml` is handed `format_error` itself, as a parameter, precisely so
its own error reporting matches the driver's exactly — and the parameter
is what keeps the dependency one-way. `pyk.ml` refers to `Repl`;
`repl.ml` refers to nothing in `pyk.ml`, so the two are ordered and the
module graph stays acyclic, which is a requirement here rather than a
preference: a cycle between two modules of one library does not link.
Passing the function rather than importing it back is the whole of how
that is arranged.

## `wrap`: every message reflows to 70 columns

`wrap(text)` runs every user-facing message — usage errors, front-end
errors formatted by `format_error`, the `Unsupported by target ...`
messages, even the stack-trace lines `command_interpret` prints — through
`textwrap.wrap` at a fixed width of 70 (not the more common 80),
continuation lines indented two spaces, never breaking a word or a
hyphen. The width is narrower than usual specifically so a message
still reads cleanly once something else has already eaten a few
columns — a `$ ` shell prompt, a quoting mail client, a fenced code
block in a doc page (like this one, and like PYKING.md's own error
examples, which are wrapped the same way for the same reason). It's a
small detail, applied completely uniformly — there's no message
anywhere in this module that bypasses `wrap` and prints raw — which is
what keeps every error the compiler produces, from a one-line lexical
mistake to a multi-clause type error, readable in the same narrow
terminal.
