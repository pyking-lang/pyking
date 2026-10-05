# The standard library

What is under `lib/`, how `pyk` finds it, and why each library reaches
the targets it does. For the module system itself see
[modules.md](modules.md); for what may cross an external boundary see
that page's "What may cross the boundary".

## One folder per library

A library is a folder under `lib/` named after the module a program
imports. A module is up to two files and a library shows both shapes:

```
lib/fs/     fs_external.pyk        fs_external.{py,c,ml}  FsExternal.java
lib/io/     io.pyk  io_external.pyk     io_external.{py,c,ml}  IoExternal.java
lib/sys/    sys.pyk  sys_external.pyk   sys_external.{py,c,ml} SysExternal.java
lib/time/   time.pyk  time_external.pyk  time_external.{py,ml}
```

and every one of them `<name>_external_node.js` and
`<name>_external_browser.js`, the two JavaScript environments (see
"In the browser" below).

`fs` is entirely the host's: every name it offers is declared, and there
is no Pyking half because there would be nothing in it. `io`, `sys` and
`time` have both halves -- what the host provides, and what is written
in Pyking against it -- and a program importing one says `import sys`
and reaches everything under that one name. See
[modules.md](modules.md), "A module in two halves".

## What goes in which half

The rule is what the host has to answer and nothing more. A declaration
is a call into the target's own source, so it belongs there when only
the host can know the answer: the arguments the process was given, the
contents of a file, what the clock says. Everything a *reader* sees is
written in Pyking, so that every target agrees about it.

`time` is the clearest case. `now` is declared, because only the host
has a clock and a calendar; `format` is written in Pyking, so a date
prints the same characters whichever target compiled it. And the six
decomposers behind `of_instant` are declared **private** -- they are how
`of_instant` is written, not something a program should call:

```pyking
# time_external.pyk
public def now : () -> (Int, Int, Int, Int, Int, Int)

def year_of : (Int) -> Int
```

```pyking
# time.pyk -- `year_of` is in scope here and nowhere else
public def of_instant(t:Int) -> (Int, Int, Int, Int, Int, Int):
    return (year_of(t), month_of(t), day_of(t), hour_of(t), minute_of(t), second_of(t))
```

`sys` is the same shape the other way up: `args`, `env`, `prog_name`,
`prog_path` and `exit` are the host's and are declared directly, at the
types a caller wants -- a `[String]`, a `[(String, String)]`. `env_get`
and `env_has` are written in Pyking over `env()`, so every host answers
them the same way rather than each reimplementing the same scan.
`exit(code)` ends the program at once with that status, after writing
out what was printed; a program that ends without it ends with 0.

`io` is standard input and standard output. `write`, `write_line`,
`read` and `is_eof` are declared; `read_line(prompt = "")` is written in
Pyking over the private `prompt_line`, because a declaration cannot carry
a default. A line is read without its line ending, and at the end of the
input every read is `""` -- which an empty line also is, so `is_eof` is
what tells the two apart. Every read writes out what has been written so
far first, so a prompt is on screen before the program waits. `print`
writes to the same standard output, so the two interleave in the order
they ran.

`now` is one call, which is what makes a reading atomic: six separate
clock calls could straddle a second and report a date that never
happened.

Decomposition is **UTC** on every host. A local one would depend on the
host's own zone database, which the targets disagree about, and a
library that formatted differently per target would be no use.

A declared type has to be one the target can carry. A list or a tuple is
refused on C and Java ([modules.md](modules.md), "What may cross the
boundary"), which is why `time` and most of `sys` reach neither -- the
shape a caller wants is worth more than two targets that could not carry
it. Those two compile only what a program uses of a library
([modules.md](modules.md), "What a program uses"), so `sys.exit` reaches
them while `sys.args` does not.

## Failure, where the language has none

Pyking has no exceptions, no option type and no result type, so a
library cannot report that something went wrong. Two rules follow:

- **Make the failure avoidable.** `fs.exists(name)` and
  `sys.env_has(name)` exist so a program can ask before it acts.
- **Everything else is undefined.** Reading a file that is not there, or
  writing where the host will not allow it, has no defined answer.
  Each implementation returns something harmless -- the empty string, or
  nothing at all -- but the *interpreter* would raise a clean Pyking
  runtime error where a compiled target dies host-style, so the two do
  not agree and neither is promised.

`sys.env_get` answers `""` for a variable that is not set, which is why
`env_has` is separate: it is the only way to tell an empty variable from
a missing one.

## The search path

A module name is looked for in four places, in this order, and the first
level that has it wins:

1. the importing file's own directory, flat — `<dir>/<name>_external.pyk`
   then `<dir>/<name>.pyk`
2. each `-L` / `--lib-path`, in the order written, as
   `<entry>/<name>/<name>_external.pyk` then `<entry>/<name>/<name>.pyk`
3. each entry of `PYKING_LIB_PATH`, same shape — separated by `:` on
   Linux and macOS and `;` on Windows, the platform's own
4. `lib/` beside the `pyk` executable

`-L` takes both shapes people type it in: `-Lpath`, `-L path`,
`--lib-path path` and `--lib-path=path`. It is repeated rather than
given a separated list, since the separator is the thing that differs
between platforms; the environment variable has no such choice and
takes the platform's.

Level 4 is what makes the standard library work with no flag set and no
variable exported, and being last means anything a caller says overrides
it. Level 1 is what makes a library's own internal imports work, and
what lets a program shadow a library with a file of its own.

A level holding *both* a `.pyk` and a `_external.pyk` for one name holds
one module in two halves, and both come from that level: a library
cannot be half shadowed. A name ending in `_external` cannot be imported
at all -- `io_external.pyk` is the external half of `io`, imported as
`io`.

A name no level has names every path it looked in, in order, with where
each came from — a search path that will not say where it looked is the
hardest kind to fix:

```
Module error: cannot read module 'mylib': looked for
  '/here/mylib_external.pyk' (local), '/here/mylib.pyk' (local),
  '/libs/mylib/mylib_external.pyk' (-L), '/libs/mylib/mylib.pyk' (-L),
  '/opt/pyk/lib/mylib/mylib_external.pyk' (built-in), … A module is
  beside the file that imports it, or in a library folder on the search
  path (-L, PYKING_LIB_PATH)
```

Reading `PYKING_LIB_PATH`, and asking where the executable is, are both
done in `src/pyk.ml`: `src/module.ml` is compiled into the browser build
too and may do neither, so the assembled list is handed to
`Module.load` as a parameter. See [build.md](build.md).

## Running one with the interpreter

An external module has no Pyking body, so the interpreter reaches it the
way the `ocaml5.5` target does: through its OCaml implementation,
`<name>_external.ml`. `pyk` loads it as a **plugin**, a `.cmxs` compiled
from that file with Dynlink, so every library -- and a program's own
external module -- runs under `pyk prog.pyk`, `pyk repl` and every
library test's `interpret` without `pyk` being rebuilt.

### How the interpreter reaches an OCaml implementation

A plugin is two files compiled together: the implementation, and a
registration file `src/plugin_host.ml` generates from the module's
declarations, which records each declared name in `Pyk_plugin` (the one
module of `pyk` a plugin names, `src/plugin/`) when Dynlink loads it. A
value crosses by its declared type, since nothing else says whether an
immediate OCaml value is an Int, a Bool or unit.

A plugin is found in one of two places, and is used only when it was
built from what it would be built from now -- the implementation, the
registration file, the OCaml and pyk versions and `pyk_plugin.cmi`,
recorded as one digest in `<name>_external.digest` beside it:

1. **Beside the implementation**, as `<name>_external.cmxs`. `make libs`
   (which plain `make` runs) writes the standard library's there with
   `pyk plugins lib`, and every package ships them, so the standard
   library needs no OCaml installed.
2. **In the cache**, `$XDG_CACHE_HOME/pyking/plugins/<digest>.cmxs`
   (`~/.cache/pyking/plugins/` by default), compiled on demand with
   `$OCAMLOPT` or `ocamlopt`. That compiler must be the version `pyk` was
   built by -- a plugin loads only into an executable its own compiler
   built -- and `pyk` refuses with the version it needs otherwise.

A plugin may use `Stdlib` and `unix`, since `pyk` links both whole
(`-linkall`); a library outside those is not there to be linked against.

`pyk` sets `Sys.argv` to the program's file and its own arguments before
it runs, so `sys_external.ml` reads the arguments where a compiled
program has them.

The REPL loads plugins the same way when an entry imports a module. Its
standard input is the session's own, so a program reading it at a piped
prompt reads the next entries' lines.

`plugin_host.ml` lives in the executable, not the library, because it
starts a process and loads code, and nothing in the library half may.

## In the browser

JavaScript runs in two environments, so every library has two
implementations: `<name>_external_node.js` for `node24` and
`<name>_external_browser.js` for `web24` and `iweb24`. A browser has a
console and nothing else, so each browser implementation writes standard
output to `console.log` a line at a time, and every function a page
cannot provide -- reading standard input, the filesystem, the arguments,
the environment -- says on the console that it is not supported and
answers as the empty or missing thing would. `sys.exit` stops the
program, and the page reports a status other than 0.

`print` writes through `io`'s browser implementation on both browser
targets, so the page ships `io_external.js` whether or not the program
imports `io` ([target_js.md](target_js.md), "Standard output in a
browser").

The playground and the notebook run programs with the interpreter in a
worker, and supply `io` and `sys` themselves: standard output is the
output pane, standard input and the arguments are what the page asked
for before the run -- only when the program reads them -- and
`sys.exit` ends the run. Every other library is its browser
implementation, fetched from `lib/` with the library's Pyking sources.
See tools/webrun/README.md.

## tinyweb

`lib/tinyweb` is graphics, widgets and sound on a web page, kept in time
by one clock. Its two halves are `tinyweb_external.pyk`, which declares
what the host does, and `tinyweb.pyk`, which wraps the declarations that
need a default argument. A program builds a page by calling it: a
canvas, button, label or slider goes below the ones before it, and every
one is named by the `Int` its function answers. A sample is an `Int` as
well, from `load_sample`.

**Commands and events.** Every function sends the page one *command*, a
plain object such as `{op: "circle", c, x, y, radius, color}`, and the
page answers with *events*, such as `{ev: "click", id}`, which call the
functions the program handed over. A program that handed over a
function keeps running after its top level ends, as long as the page
does. Each event carries the page's clock (`t`) and whether audio has
started, which is what `time()` answers from between events.

**One file, three transports.** `tinyweb_external_browser.js` holds the
program's side, the page's side (`mountPage`, the renderer) and the
choice between them:

| where the program runs | how a command reaches the page |
|---|---|
| on the page (`web24`, `iweb24`) | the renderer is mounted on `pykPageRoot`, or on the body, and called directly |
| in a worker (playground, notebook) | posted as `{type: "page", module: "tinyweb", data: [...]}`; events come back through `pykDeliver` |
| nowhere (node, the harness) | headless: one line per command in `$PYKING_PAGE_LOG` |

`tinyweb_external_node.js` is a copy of it, since under node there is no
page and the same code is headless; `tests/test_site.py` checks the two
are the same. `tinyweb_external.ml` is the interpreter's plugin, and is
headless too.

**Keeping sound and pictures in time.** The page's clock is the audio
clock once sound has started, and before that the seconds since the
page was mounted, joined so it never goes back. A frame callback is
given the time the frame is for, and `play(sample, at = t)` schedules a
sample on the audio clock, so a sound starts exactly when the picture
says it does whatever the delay between the worker and the page. A
browser starts audio only after a gesture, so every click and key press
on the page starts it. The page asks a worker for the next frame only
once the last one's commands have arrived (`frame_done`), so a slow
program drops frames rather than queueing them.

**Samples.** `load_sample(name)` fetches `name` beside the page, and
then from `tinyweb_assets/` beside the implementation, which holds four
CC0 samples from freesound.org. `pyk compile` copies a library's
`<name>_assets/` directory beside a `web24` or `iweb24` page, so the
same relative URL works from `lib/` and from a compiled page.

## A library that needs a page

A library whose directory holds `<name>.page` needs a page to be seen
on. `pyk program.pyk` then compiles the program for `iweb24` into a
directory of its own and serves it, as `pyk compile -t iweb24 --run`
does, rather than running it in the terminal; `--headless` runs it in
the terminal instead, showing nothing. The driver names no library: the
marker file is the whole of the rule.

The playground and the notebook show such a page with
`tools/webrun/assets/pages.js`'s `PageHost`: on the first `page` message
from the worker it imports `lib/<name>/<name>_external_browser.js`,
calls its `mountPage(element, send)`, and hands it each batch; `send`
posts an event back to the worker, which delivers it to the module's
`pykDeliver`. The worker imports a fresh instance of every library for
each run, so one program's callbacks never answer another's events. A
run that sent its page anything stays *live* after it answers, its
output still reaching the pane, until the next run or Stop
(`PykingRuntime.endLive`). The notebook shows the page under the cell,
above its standard output; the playground shows it on the Page tab
beside the compiled code.

## What each library reaches

| | python14 | node24 | web24 | iweb24 | c89/99/23 | java8/17/21 | ocaml5.5 | interpret |
|---|---|---|---|---|---|---|---|---|
| `fs` | yes | yes | not supported | not supported | yes | yes | yes | yes |
| `io` | yes | yes | output only | output only | yes | yes | yes | yes |
| `sys` | yes | yes | `exit` only | `exit` only | `exit` only | `exit` only | yes | yes |
| `time` | yes | yes | yes | yes | no | no | yes | yes |
| `tinyweb` | no | headless | yes | yes | no | no | no | headless |

"Not supported" and "output only" are the browser implementations above:
the import compiles and a function the page cannot provide says so.

`tinyweb` draws and plays on a page, so a host with no page runs it
*headless*: nothing is shown, and the commands it would send are what a
test compares (below, "Testing a page"). It hands the page callbacks,
which C and Java cannot carry, and has no Python or OCaml-target
implementation.

On C and Java, `sys` offers `exit` alone. `args` and `env` answer a list,
which neither target can carry, and `prog_name` and `prog_path` need the
program's own `argv`, which an implementation file cannot see -- so
`sys_external.c` and `SysExternal.java` define `exit` only, and a program
using another name does not link. `time` answers a tuple, and does not
reach either.

`io`, `sys` and `time` reach `ocaml5.5`, and `sys` and `time` need it
linked with `unix`: nothing in OCaml's `Stdlib` enumerates the
environment or reads the clock as a calendar, so `sys_external.ml` and
`time_external.ml` need it. See [target_ocaml.md](target_ocaml.md),
"Linking unix".

Two gaps that used to be here were compiler defects rather than
properties of the libraries, and both reproduced with an ordinary user
module and no library at all. Both are fixed:

- **A module named for a CPython builtin could never be imported on
  `python14`**, because `import time` resolves to the interpreter-frozen
  `time` before any sibling `time.py`. Such a module is now loaded by
  path, through a prelude helper emitted only where one is imported —
  see [target_python.md](target_python.md), "Module names Python has
  already taken". `io` is one of them: Python imports its own at
  startup.
- **A module exporting a JavaScript reserved word emitted invalid
  JavaScript**: `public def arguments()` became `export { arguments };`,
  a name nothing declared. The body already renamed it, so the export
  clause now says which — `export { arguments2 as arguments }` — see
  [target_js.md](target_js.md), "Names that are keywords in
  JavaScript".

## Testing a library

A case names the libraries it needs under `libs`. Each expands to the
files that library contributes, implementation first -- a module is up
to two files and the generated half calls into the other:

```toml
[[cases]]
file = "lib_fs_roundtrip.pyk"
libs = ["fs"]
targets = ["python14", "node24", "c89", "c99", "c23", "java8", "java17", "java21", "ocaml5.5", "interpret"]
```

`libs` is separate from `modules` because a library is not a file in
`tests/`: the compiler finds it on its own search path, and the
harness's "listed but does not exist" check would otherwise complain.
The libraries come first in the order the linking targets are given
their files, since a library never imports a module from `tests/`.

Three things make a library testable at all:

- **The runners run each program in its own workdir**, so a program that
  writes a file writes it there and not into the repository.
- **The harness sets `PYKING_TEST_ENV=hello`** for every run, so a case
  reading the environment has one variable pinned to compare against.
  The environment as a whole differs per machine and can never be an
  expected output.
- **Nothing host-specific is compared as a value.** `sys.prog_name()` and
  `sys.prog_path()` are what the host was asked to run and where it
  sits, so only that each says *something* is checked,
  and `time` is rendered from a fixed instant rather than from the
  clock.
- **A case may read standard input**, from a sibling `.in` file, and
  **end with a status**, which an `exit_code` key expects -- 0 where it
  says nothing. `tests/lib_io_read.pyk` and `tests/lib_sys_exit.pyk` are
  those cases.
- **A case may pass the program arguments**, with an `arguments` key,
  which is the only place a run's arguments can be written down. Each
  target gets them its own way -- after `--` for the interpreter, and
  through the host's own argv for a compiled one -- so one `.out` holds
  for all of them. `tests/lib_sys_arguments_passed.pyk` is that case,
  and one of its arguments holds a space, which is what checks the whole
  thing arrives as one argument rather than two. Without a key a case
  passes none, so `sys.args()` is `[]` -- the same answer on every
  host.

`tests/test_libpath.py` is a third suite, beside `test_script.py` and
`test_repl.py` (all four sequenced by `test_all.py`, which is what
`make test` calls), because the search path is a property of the
*invocation* rather than of a program: the order of `-L` flags, an
environment variable, a name resolving in two places at once, and the
wording of a failure are things no (program, target) pair can express.
Each case builds a throwaway tree of tiny libraries, each exporting a
`tag()` naming itself, and runs the program — so what is printed says
which library was actually found.

## Testing a page

A program using `tinyweb` is tested by what it sends its page, not by
pixels. Two files beside it say so:

- `<name>.events` -- what the page delivers once the top level has
  ended, one event per line: `click ID`, `slide ID VALUE`, `frame T`,
  `mouse CANVAS X Y` and `key NAME`.
- `<name>.page` -- every command the program sent, one per line, with
  each delivered event as a `> ` line where it happened:

```
canvas 3 400 800
circle 3 1 50 30 #ff0000
button 4 "Play kick"
> click 4
play 1 0.000 1.000 1.000
```

The harness copies the `.events` file into each run's workdir, points
`$PYKING_PAGE_EVENTS` and `$PYKING_PAGE_LOG` there, and compares the log
with the `.page` file on every target the case lists. Every headless
implementation writes the same lines -- strings as JSON, times to three
decimals -- so one `.page` file holds for `node24`, `web24`, `iweb24`
and the interpreter, which is run with `--headless`.
`tests/lib_tinyweb_*.pyk` are the cases. The renderer itself -- what is
drawn, a click reaching the program, frames -- is checked in a real
browser by `make -C tools/playground e2e`, which reads the canvas back
pixel by pixel.

## Adding a library

1. `lib/<name>/`, with `<name>_external.pyk` if the host provides it
   directly, or `<name>.pyk` plus `<name>_external.pyk` if anything
   list- or tuple-shaped is involved.
2. One implementation per target the library claims, named as
   [modules.md](modules.md) says (`<name>_external.py`,
   `<name>_external_node.js`, `<name>_external_browser.js`,
   `<name>_external.c`, `<Name>External.java`, `<name>_external.ml`).
   The OCaml one is what the interpreter loads, so it is not optional.
3. At least two cases in `tests/`, with `libs` naming its modules in
   dependency order, and `interpret` among the targets.
4. A row in the table above, with the reason for every target it does
   *not* claim.
5. `##` doc comments: one block opening one of its two files, saying what
   the module is for, and one directly above every `public` line. They
   are the library's page on the website (`tools/site/libdoc.py`), and
   `tests/test_site.py` fails on a public name without one. A plain `#`
   comment is for maintainers and is not published. See
   `tools/site/README.md`, "The library reference".
