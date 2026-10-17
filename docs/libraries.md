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
lib/math/   math.pyk  math_external.pyk  math_external.{py,c,ml}  MathExternal.java
lib/sys/    sys.pyk  sys_external.pyk   sys_external.{py,c,ml} SysExternal.java
lib/time/   time.pyk  time_external.pyk  time_external.{py,ml}
lib/tinyweb/ tinyweb.pyk  tinyweb_external.pyk  tinyweb_external.{py,c,ml}  TinywebExternal.java
```

and every one of them `<name>_external_node.js` and
`<name>_external_browser.js`, the two JavaScript environments (see
"In the browser" below). tinyweb has more: its page
(`tinyweb_page.js` and `tinyweb_page.html`), its samples
(`tinyweb_assets/`), the implementation the interpreter uses in a
browser (`tinyweb_external_interpreter.js`) and the file joining its
OCaml implementation to the interpreter (`tinyweb_external_plugin.ml`).

`fs` is entirely the host's: every name it offers is declared, and there
is no Pyking half because there would be nothing in it. `io`, `math`,
`sys` and `time` have both halves -- what the host provides, and what is written
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
public def now() -> (Int, Int, Int, Int, Int, Int)

def year_of(seconds: Int) -> Int
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

`math` is numbers. Its declaration half is the host's floating-point
functions, all private and all in radians (`host_sin`, `host_floor`,
...); everything a program calls is written in `math.pyk` over them, so
every host answers alike:

- **Angles are in degrees**, and each trigonometric function has a
  `_rad` twin. The degree functions answer exactly at the angles a
  drawing uses -- `sin` and `cos` at every multiple of 30 degrees, `tan`
  at every multiple of 45, `inf` at 90 -- and the inverse ones answer a
  whole number of degrees where they are within 1e-9 of one.
- **`floor`, `ceil`, `trunc` and `round` answer an Int**, 0 where `int`
  would; `round` takes a tie away from zero, which no host's own
  rounding agrees on.
- **`abs`, `min`, `max`, `clamp`, `sign` and `mod` are overloaded** over
  Int and Float (`int::abs`, `float::abs`; [overloading.md](overloading.md)),
  which a declaration half cannot hold. `mod` is floored: its answer has
  the divisor's sign, and Pyking has no `%`.
- `cbrt` is exact for a perfect cube, which glibc's is not.

The rest is the host's own answer, which may differ between hosts in the
last bit; the tests print those to six decimals
(`tests/lib_math_approx.pyk`).

`now` is one call, which is what makes a reading atomic: six separate
clock calls could straddle a second and report a date that never
happened.

Decomposition is **UTC** on every host. A local one would depend on the
host's own zone database, which the targets disagree about, and a
library that formatted differently per target would be no use.

A declared type has to be one the target can carry. A list is refused
on C, which has no garbage collector to free one ([modules.md](modules.md),
"What may cross the boundary"), which is why most of `sys` does not
reach it -- the shape a caller wants is worth more than one target that
could not carry it. C and Java compile only what a program uses of a library
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

An implementation refuses a call by raising `Failure`: under the
interpreter that is a Pyking runtime error, reported at the call with
the implementation's own words, so the REPL's session goes on. A
compiled program has no such error to raise, so the implementation
decides how to stop there -- tinyweb's says why and exits with status 1.

**One more file, for the interpreter alone.** A library may put
`<name>_external_plugin.ml` beside its implementation. It is compiled
into the plugin after the implementation and may name `Pyk_plugin`,
which a compiled program does not have; the `ocaml5.5` target never
copies it. It is where the implementation is joined to the interpreter:

- `Pyk_plugin.after_program f` runs `f` once the top level has ended,
  where a runtime error in a callback is reported like any other;
- `Pyk_plugin.on_idle descriptors handle` hands the plugin the REPL's
  idle time: while the prompt waits for a key it also waits on the
  descriptors, and calls `handle` when one is ready;
- `Pyk_plugin.directory name` is the directory the module's
  implementation was found in, which is how a library finds files
  beside itself.

`tinyweb_external_plugin.ml` is the one there is. tinyweb's
implementation is otherwise one file for both: a compiled OCaml program
runs the same `after_program` from `at_exit`.

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
`<name>_external_browser.js` for `web24` and `iweb24`. A library may
have a third, `<name>_external_interpreter.js`, for wherever the
interpreter runs the program in a browser -- `iweb24`, the playground
and the notebook -- which then take it in place of the browser one;
tinyweb is the library that does. A browser has a
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

**Commands and events.** Every function but `web_init` sends the page
one *command*, a plain object such as `{op: "circle", c, x, y, radius,
color}`, and the page answers with *events*, such as `{ev: "click",
id}`, which call the functions the program handed over. A program that
handed over a function keeps running after its top level ends, as long
as the page does. Each event carries the page's clock (`t`) and whether
audio has started, which is what `time()` answers from between events.

**Where the page is.** A program starts with `web_init(port)`, and what
that does depends on where it runs:

| where the program runs | the page | `web_init(port)` |
|---|---|---|
| a `web24` page | the page itself, drawn on directly by `tinyweb_external_browser.js` | nothing |
| an `iweb24` page | the page itself, drawn on by `tinyweb_page.js`, which `tinyweb_external_interpreter.js` hands each command | nothing |
| the playground, a notebook | beside the program, drawn on by `tinyweb_page.js`; the interpreter runs on a worker, and the commands and events cross as messages | nothing |
| anything else: `pyk program.pyk`, the REPL, and `python14`, `node24`, `c89`-`c23`, `java8`-`java21`, `ocaml5.5` | served by the program itself | serves the page on `port` (0 picks a free one) and prints `tinyweb: http://127.0.0.1:N/` |

A program on a target of the last row that calls anything before
`web_init` is told so on standard error and ends with status 1 -- unless
`PYKING_TINYWEB_LOG` is set, in which case there is no page at all and
`web_init` does nothing (below, "Testing a page"). Under the
interpreter that is a runtime error, so the REPL goes on.

**`tinyweb_page.js` is the one page.** It carries out commands and
reports events, and it is what every place that talks to its page in
commands mounts: the `iweb24` page, the playground and the notebook
(`tools/webrun/assets/pages.js`), and the page a program serves. That
page is `tinyweb_page.html`, which mounts `tinyweb_page.js`, reads the
commands from `GET /commands` -- server-sent events, each a batch as a
JSON array -- and posts each event to `POST /events` as JSON, one at a
time and in order. Every native implementation carries both files as
string literals, so a compiled program needs nothing beside itself to
show its page; `tools/tinyweb/embed_page.py` writes them in, and
`tests/test_tinyweb.py` fails when a copy is stale. The same script
copies the page's style block into `tinyweb_external_browser.js`.

**The server.** Every native implementation serves the same thing:

| request | answer |
|---|---|
| `GET /` | `tinyweb_page.html` |
| `GET /tinyweb_page.js` | `tinyweb_page.js` |
| `GET /commands` | the stream of command batches |
| `POST /events` | 204; the event is queued |
| `GET /<file>` | that file beside where the program runs, and a sample from `tinyweb_assets/` beside the library, else 404 |

It listens on 127.0.0.1 only. The events are delivered once the top
level has ended, in the order they came, each followed by an
`event_done` command once what it caused has been sent -- which is how
the test below knows an event is finished. A page that connects late,
or is reloaded, is sent everything so far first, less what it no longer
needs: sound a callback played, a canvas's drawing before the canvas was
cleared, and a label's text before it was set again. The top level's
sound is kept, since a page a program serves always connects after the
top level has run. How each host serves:

| implementation | server | where callbacks run |
|---|---|---|
| `tinyweb_external.py` | `http.server` on a thread | the main thread, from `atexit` |
| `tinyweb_external_node.js` | node's `http` | node's event loop |
| `tinyweb_external.ml` (`ocaml5.5`, the interpreter) | one `select` loop | from `at_exit`, or the interpreter after the top level; the REPL runs the loop while it waits for a key |
| `tinyweb_external.c` | one `select` loop, POSIX sockets | from `atexit` |
| `TinywebExternal.java` | the JDK's `com.sun.net.httpserver` | a thread that waits for `main` to return |

On the native targets `time()` is what the page last reported, which is
the frame's own time inside an `on_frame` callback. In a browser it is
the page's clock itself.

**Keeping sound and pictures in time.** The page's clock is the audio
clock once sound has started, and before that the seconds since the
page was mounted, joined so it never goes back. A frame callback is
given the time the frame is for, and `play(sample, at = t)` schedules a
sample on the audio clock, so a sound starts exactly when the picture
says it does whatever the delay between the program and the page. A
browser starts audio only after a gesture, so every click and key press
on the page starts it. The page asks for the next frame only once the
last one's commands have arrived (`frame_done`), so a slow program drops
frames rather than queueing them.

**The page's look.** tinyweb styles its own page, so it looks the same
in every host. Every styling function sends one command, `{op: "style",
id, kind, prop, value}`, through the one declaration `apply_style`:
`kind` is `theme` (`value` a theme's name), `page`, `button`, `label`,
`slider` or `canvas` (`prop` of every element of that kind), or
`element` (`prop` of the element `id`). `prop` is one of `background`,
`color`, `border`, `radius`, `font`, `size`, `padding`, `gap`, `accent`
and `width`, and `value` is CSS; the Pyking half turns a pixel count
into `"Npx"` and leaves out what the call did not name. The renderer
keeps a stylesheet of the page's own, scoped to the element the page is
mounted in by a `data-tinyweb-page` attribute written three times over,
so the host page's rules for a button or a body do not outweigh it: a
theme and a kind's style are rules of that stylesheet, and one
element's style is set on the element. The themes, and how each
property becomes CSS, are the block of `tinyweb_page.js` marked `BEGIN
tinyweb style`; `embed_page.py` copies that block into
`tinyweb_external_browser.js`, which draws without the page script.

**Samples.** `load_sample(name)` fetches `name` beside the page, and
then from `tinyweb_assets/` beside the implementation, which holds four
CC0 samples from freesound.org. `pyk compile` copies a library's
`<name>_assets/` directory beside the program on every target, so the
same relative URL works from `lib/`, from a compiled page and from the
page a compiled program serves.

**Using it from another language.** Each implementation is also a
library in its own right, for a program written in Python, JavaScript,
OCaml, C or Java with no Pyking at all: `make website` copies them, as
`tinyweb.py`, `tinyweb.js`, `tinyweb.ml` with `tinyweb.mli`, `tinyweb.c`
with `tinyweb.h` and `Tinyweb.java`, onto the site's tinyweb pages, with
an example in each language and the code Pyking generates for the
tests. See `tools/site/README.md`.

### The splash screen

A browser plays no sound before the reader has clicked or pressed a key
on the page. In the playground and a notebook the reader has: the
program was started with Run, or a key. A page opened from a link has
not -- the page a program serves, a `web24` or an `iweb24` page -- and
there tinyweb shows a *splash screen* before the first sound: the whole
window dimmed, and `Click to Start` in white in its middle. A click or
any key dismisses it, sound starts, and the page looks as it did.

**When it is shown.** Two commands, `{op: "splash"}` and `{op:
"splash_text", text}`, sent by `splash()` and `set_splash(message)`, and
one rule on the page: the splash screen is shown at most once, and only
where sound has not started, the page was not mounted `activated`, the
browser does not report the reader active
(`navigator.userActivation.hasBeenActive`) and the message is not empty.
Where that holds it is shown by a `splash` command, and by the first
`play` -- which is how a sound the top level plays waits for the click.
`tools/webrun/assets/pages.js` mounts every page `activated`, so the
playground and a notebook never show it.

**The compiler calls it.** A sound a callback plays comes after the
reader clicked something, but the callback may be a frame's, which no
click starts. So a program any of whose modules can call `play` or
`play_file` ends its own top level with `tinyweb.splash()`: `splash.ml`
adds the call, and an import of tinyweb where the program's own module
has none, inside `module.load`, so every target and the interpreter run
it. Where the top level played a sound the splash screen has already
been shown, and the call does nothing. The REPL has no end of a top
level and adds nothing; its first `play` still shows it. A program
written in another language calls `splash()` itself.

**While it is shown the page holds.** Every command after the one that
showed it waits, the page asks for no frame and reports no event, and
the clock stops; dismissing it starts audio inside the reader's gesture,
moves the clock's start on by the time it was shown, and carries out
what waited. A `play(sample, at = t)` the top level sent therefore
sounds `t` seconds into the page's clock as if the splash screen had
not been there. `tinyweb_external_browser.js` draws without commands,
and holds the same way: each function's effect on the page goes through
`act`, which runs it now or keeps it until the splash screen goes. The
splash screen itself, `splashScreen`, is in the page script's style
block, so the two draw the same one.

## What each library reaches

| | python14 | node24 | web24 | iweb24 | c89/99/23 | java8/17/21 | ocaml5.5 | interpret |
|---|---|---|---|---|---|---|---|---|
| `fs` | yes | yes | not supported | not supported | yes | yes | yes | yes |
| `io` | yes | yes | output only | output only | yes | yes | yes | yes |
| `math` | yes | yes | yes | yes | yes | yes | yes | yes |
| `sys` | yes | yes | `exit` only | `exit` only | `exit` only | yes | yes | yes |
| `time` | yes | yes | yes | yes | yes | yes | yes | yes |
| `tinyweb` | yes | yes | yes | yes | yes | yes | yes | yes |

"Not supported" and "output only" are the browser implementations above:
the import compiles and a function the page cannot provide says so.

`tinyweb` draws and plays on a page, which every target has one way or
another (above, "Where the page is"). It hands the page callbacks, which
C carries as function pointers and Java as java.util.function
interfaces ([target_c.md](target_c.md) and
[target_java.md](target_java.md), "Functions as values").

On C, `sys` offers `exit` alone. `args` and `env` answer a list, which
C cannot carry, and `prog_name` and `prog_path` need the program's own
`argv`, which an implementation file cannot see -- so `sys_external.c`
defines `exit` only. `SysExternal.java` defines all five: a Java
program's generated `main` leaves its arguments and its class in the
system properties `pyking.args` and `pyking.main`. `time` answers a
tuple, which C carries as the struct the compiler writes for it, so
`time_external.c` declares that struct the same way, and
`TimeExternal.java` answers the runtime's `PykRuntime.T6`.

`math` is named the way a host's own library is, which three targets
have to step around. Python loads it by path, as it loads `sys` and
`time` (below), and `math_external.py` finds the standard library's
`math` everywhere on the path but the program's own directory. Java
compiles it to a class `Math` in the program's package, so
`MathExternal.java` and the generated code write `java.lang.Math` in
full. C compiles it to a `math.h` of its own, which `math_external.c`
steps around by including the system's with angle brackets; a C program
is linked with `-lm`, after its files ([target_c.md](target_c.md)).

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
excluded = { web = "a browser page has no file system", iweb = "a browser page has no file system" }
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

Two environment variables, each a file path, are how: where
`PYKING_TINYWEB_LOG` is set, every implementation but the web24 one
shows no page, writes each command to that file as one line, and
delivers the events `PYKING_TINYWEB_EVENTS` lists once the top level has
ended; `web_init` then does nothing. The harness copies the `.events`
file into each run's workdir, points both variables there, and compares
the log with the `.page` file on every target the case lists. Every
implementation writes the same lines -- strings as JSON, times to three
decimals -- so one `.page` file holds for all of them.
`tests/lib_tinyweb_*.pyk` are the cases.

What the log cannot reach is `tests/test_tinyweb.py`'s, a suite of its
own:

- **refused**: on each native target, a program that calls anything
  before `web_init`, and one asking for port 70000, ends with status 1
  and says why.
- **served**: each case, run on each native target with no log set,
  serves its page; the suite reads `/`, `/tinyweb_page.js` and a
  sample, posts the `.events` one at a time to `/events`, waits for each
  `event_done`, and compares what arrived on `/commands` with the
  `.page` file -- the top level's part compacted the way a late page's
  is.
- **browser**: the web24 implementation draws directly and has no log,
  so each case is built for web24 twice -- once as it is, once with
  `tinyweb_external_interpreter.js` and `tinyweb_page.js` in its place
  -- and both are run under node against a small page,
  `tests/tinyweb/dom.mjs`, that records every drawing call, every sound
  started and the page's elements after each event. The two recordings
  must be the same. A splash screen the page shows is clicked away
  before the next event is delivered, as a reader would, and the record
  says what it said.
- **Chromium**: where a Chromium is found -- `$PYKING_CHROME`, one on
  the `PATH`, or one Playwright downloaded -- the same is done in a real
  browser, driven over the DevTools protocol (`tests/tinyweb/chrome.mjs`
  and `chrome_page.js`): the web24 page drawing directly, the web24 page
  through commands, and the iweb24 page, where the interpreter runs the
  program, must record the same; so must the page a program serves
  itself, opened beside the web24 one, for the two kinds of server
  (`python14`, a thread; the interpreter, a `select` loop). The clock,
  animation frames and sound are stood in for so that runs repeat;
  the DOM, the canvas, events and fetching the samples are the
  browser's. Without a Chromium these are reported as skipped.

`make -C tools/playground e2e` reads a page's canvas back pixel by pixel
in the playground itself.

## Adding a library

1. `lib/<name>/`, with `<name>_external.pyk` if the host provides it
   directly, or `<name>.pyk` plus `<name>_external.pyk` if anything
   list- or tuple-shaped is involved.
2. One implementation per target the library claims, named as
   [modules.md](modules.md) says (`<name>_external.py`,
   `<name>_external_node.js`, `<name>_external_browser.js` (and
   `<name>_external_interpreter.js` where the interpreter in a browser
   needs another; see "In the browser"),
   `<name>_external.c`, `<Name>External.java`, `<name>_external.ml`).
   The OCaml one is what the interpreter loads, so it is not optional.
3. At least two cases in `tests/`, with `libs` naming its modules in
   dependency order, and `interpret` among the targets.
4. A row in the table above, with the reason for every target it does
   *not* claim.
5. `##` doc comments: one block opening one of its two files, saying what
   the module is for, and one directly above every `public` line, with
   its parameters, what it returns, and an example with the output it
   prints. They are the library's page on the website and in the help
   (`tools/help/libdoc.py`), and `tests/test_site.py` fails on a public
   name documented otherwise, and on an example that prints anything
   else. A declaration in its `_external.pyk` names its parameters,
   `def write(text: String) -> ()`. A plain `#` comment is for
   maintainers and is not published. See `tools/help/README.md`,
   "Documenting a library".
