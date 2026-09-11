# The standard library

What is under `lib/`, how `pyk` finds it, and why each library reaches
the targets it does. For the module system itself see
[modules.md](modules.md); for what may cross an external boundary see
that page's "What may cross the boundary".

## One folder per library

A library is a folder under `lib/` named after the module a program
imports, holding that module and anything it needs:

```
lib/fs/     fs.external.pyk   fs.py  fs.js  fs.c  Fs.java  fs.ml
lib/sys/    sys.pyk  sys_ext.external.pyk   sys_ext.py  sys_ext.js
            sys_ext.ml
lib/time/   time.pyk  time_ext.external.pyk   time_ext.py  time_ext.js
```

`fs` is one module and nothing else: every type it names is a `String`
or a `Bool`, and those cross an external boundary on every target, so
there is nothing for a Pyking half to do. `sys` and `time` are two
modules each — a declaration that reaches the host, and a Pyking module
that is what a program imports. That split is the point, and the next
section is why.

A library's own imports are resolved *locally*: `time.pyk` says
`import time_ext` and finds it beside itself, because the importing
file's own directory is the first place a module is looked for.

## Keep the boundary scalar

`Int`, `String`, `Bool` and `()` cross an external boundary on every
target. A tuple or a list does not: C and Java have no representation
for either, and the declaration is refused there
([modules.md](modules.md)). A library whose *declaration* answers with a
list therefore reaches five targets instead of nine.

So the declarations name scalars only, and everything list- or
tuple-shaped is assembled on the Pyking side:

```pyking
# sys_ext.external.pyk -- what the host provides
public def argument_count : () -> Int
public def argument : (Int) -> String

# sys.pyk -- what a program imports
public def arguments() -> [String]:
    count = sys_ext.argument_count()
    (_, collected) = loop i, out = 0, []:
        if i >= count:
            break
        else:
            (i + 1, out ++ [sys_ext.argument(i)])
    return collected
```

The list is built by Pyking, so it never crosses the boundary at all.

What is in it comes from the invocation: everything after `--` on the
command line for an interpreted program (`pyk prog.pyk -- a b`), and the
host's own argv for a compiled one. The program's *name* is not among
them — argument 0 differs on every host, so it is `sys.program()`
instead, where a caller that wants it can ask.

The same reasoning fixes `time`'s shape. `time_ext.instant()` reads the
clock once and answers with an `Int`; six `*_of` functions decompose
one. Six separate clock readings could straddle a second and report a
date that never happened, and splitting the reading from the
decomposition makes that impossible — while also giving `time.format`
an arbitrary instant to render rather than only the present.

Decomposition is **UTC** on every host. A local one would depend on the
host's own zone database, which the five targets disagree about, and a
library that formatted differently per target would be no use.

## Failure, where the language has none

Pyking has no exceptions, no option type and no result type, so a
library cannot report that something went wrong. Two rules follow:

- **Make the failure avoidable.** `fs.exists(name)` and
  `sys.environment_has(name)` exist so a program can ask before it acts.
- **Everything else is undefined.** Reading a file that is not there, or
  writing where the host will not allow it, has no defined answer.
  Each implementation returns something harmless — the empty string, or
  nothing at all — but the *interpreter* would raise a clean Pyking
  runtime error where a compiled target dies host-style, so the two do
  not agree and neither is promised.

`sys.environment_get` answers `""` for a variable that is not set, which
is why `environment_has` is separate: it is the only way to tell an
empty variable from a missing one.

## The search path

A module name is looked for in four places, in this order, and the first
level that has it wins:

1. the importing file's own directory, flat — `<dir>/<name>.external.pyk`
   then `<dir>/<name>.pyk`
2. each `-L` / `--lib-path`, in the order written, as
   `<entry>/<name>/<name>.external.pyk` then `<entry>/<name>/<name>.pyk`
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

A level holding *both* a `.pyk` and a `.external.pyk` for one name is
refused: a module is either written in Pyking or implemented for a
target, and which was meant would be a guess.

A name no level has names every path it looked in, in order, with where
each came from — a search path that will not say where it looked is the
hardest kind to fix:

```
Module error: cannot read module 'mylib': looked for
  '/here/mylib.external.pyk' (local), '/here/mylib.pyk' (local),
  '/libs/mylib/mylib.external.pyk' (-L), '/libs/mylib/mylib.pyk' (-L),
  '/opt/pyk/lib/mylib/mylib.external.pyk' (built-in), … A module is
  beside the file that imports it, or in a library folder on the search
  path (-L, PYKING_LIB_PATH)
```

Reading `PYKING_LIB_PATH`, and asking where the executable is, are both
done in `src/pyk.ml`: `src/module.ml` is compiled into the browser build
too and may do neither, so the assembled list is handed to
`Module.load` as a parameter. See [build.md](build.md).

## Running one with the interpreter

An external module has no Pyking body, so `pyk prog.pyk` used to refuse
any program that imported one. `src/stdlib_host.ml` implements the
standard library's externals in OCaml, and `pyk.ml` hands them to the
interpreter, so a program using `fs`, `sys` or `time` runs under it as
well as under a backend — which is what lets every library test compare
`interpret` against the same `.out` the compiled targets are held to.

The list of modules it answers for is **closed** (`Stdlib_host.modules`),
and deliberately: were it open, a folder named `fs` on a `-L` path would
be answered by this executable's own OCaml rather than by the file that
actually resolved, and the interpreter would silently disagree with
every compiled target. Any other external module keeps the old refusal.

`stdlib_host.ml` lives in the executable, not the library, because it
reads files, the clock and the environment, and nothing in the library
half may.

## What each library reaches

| | python14 | node24 | web24 | iweb24 | c89/99/23 | java8/17/21 | ocaml5.5 | interpret |
|---|---|---|---|---|---|---|---|---|
| `fs` | yes | yes | no | no | yes | yes | yes | yes |
| `sys` | yes | yes | no | no | no | no | yes | yes |
| `time` | yes | yes | yes | yes | no | no | no | yes |

`fs` reaches everything that has a filesystem. It claims no
`web24`/`iweb24`: a browser has none, and an implementation that always
failed would be worse than an import that was never offered. `sys` is
the same for arguments and an environment.

`sys` and `time` do not reach C or Java because they answer with a list
and a tuple, which those targets cannot represent — not at the boundary,
where the declarations are scalar, but in the Pyking module itself.
`time` does not reach `ocaml5.5` because `format` parses its format
string with a text pattern, which that backend refuses. `sys` does
reach it, but only because every program on that target is linked with
`unix`: nothing in OCaml's `Stdlib` enumerates the environment, so
`sys_ext.ml` needs it. See [target_ocaml.md](target_ocaml.md),
"Linking unix".

Two gaps that used to be here were compiler defects rather than
properties of the libraries, and both reproduced with an ordinary user
module and no library at all. Both are fixed:

- **A module named for a CPython builtin could never be imported on
  `python14`**, because `import time` resolves to the interpreter-frozen
  `time` before any sibling `time.py`. Such a module is now loaded by
  path, through a prelude helper emitted only where one is imported —
  see [target_python.md](target_python.md), "Module names Python has
  already taken".
- **A module exporting a JavaScript reserved word emitted invalid
  JavaScript**: `public def arguments()` became `export { arguments };`,
  a name nothing declared. The body already renamed it, so the export
  clause now says which — `export { arguments2 as arguments }` — see
  [target_js.md](target_js.md), "Names that are keywords in
  JavaScript".

## Testing a library

A case names the library modules it needs under `libs`, in dependency
order:

```toml
[[cases]]
file = "lib_fs_roundtrip.pyk"
libs = ["fs"]
targets = ["python14", "node24", "c89", "c99", "c23", "java8", "java17", "java21", "ocaml5.5", "interpret"]
```

`libs` is separate from `modules` because a library module is not a file
in `tests/`: the compiler finds it on its own search path, and the
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
- **Nothing host-specific is compared as a value.** `sys.program()` is a
  path the host chooses, so only that it says *something* is checked,
  and `time` is rendered from a fixed instant rather than from the
  clock.
- **A case may pass the program arguments**, with an `arguments` key,
  which is the only place a run's arguments can be written down. Each
  target gets them its own way -- after `--` for the interpreter, and
  through the host's own argv for a compiled one -- so one `.out` holds
  for all of them. `tests/lib_sys_arguments_passed.pyk` is that case,
  and one of its arguments holds a space, which is what checks the whole
  thing arrives as one argument rather than two. Without a key a case
  passes none, so `sys.arguments()` is `[]` -- the same answer on every
  host.

`tests/test_libpath.py` is a third suite, beside `test_script.py` and
`test_repl.py`, because the search path is a property of the
*invocation* rather than of a program: the order of `-L` flags, an
environment variable, a name resolving in two places at once, and the
wording of a failure are things no (program, target) pair can express.
Each case builds a throwaway tree of tiny libraries, each exporting a
`tag()` naming itself, and runs the program — so what is printed says
which library was actually found.

## Adding a library

1. `lib/<name>/`, with `<name>.external.pyk` if the host provides it
   directly, or `<name>.pyk` plus `<name>_ext.external.pyk` if anything
   list- or tuple-shaped is involved.
2. One implementation per target the library claims, named as
   [modules.md](modules.md) says (`<name>.py`, `<name>.js`, `<name>.c`,
   `<Name>.java`, `<name>.ml`).
3. An entry in `Stdlib_host.modules` and a case per function in
   `stdlib_host.ml`, or the library cannot be interpreted.
4. At least two cases in `tests/`, with `libs` naming its modules in
   dependency order, and `interpret` among the targets.
5. A row in the table above, with the reason for every target it does
   *not* claim.
