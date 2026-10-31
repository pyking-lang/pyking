# `warnings.ml`: design

How `src/warnings.ml` finds what a program that checks may still have
wrong, and how every tool that checks a program reports it. For what
the warnings *are*, as language, see PYKING.md, "Warnings"; for where
the pass sits in the pipeline, see [architecture.md](architecture.md).

## What it reports

Seven warnings, each named by its flag:

| flag | on by default | reports |
|---|---|---|
| `unused-binding` | yes | an `=` binding (or a `let`) nothing in its scope uses |
| `unused-function` | yes | a `def` that is never called or passed on, or only by itself |
| `unused-var` | yes | a `var` that is never read |
| `shadowed-update` | yes | an unused `=` in a block that shadows a name from outside it |
| `unused-pattern-var` | no | a name a `case` pattern binds that its arm never uses |
| `unused-parameter` | no | a parameter its function's or lambda's body never uses |
| `unused-loop-var` | no | a `for` variable, a loop's accumulator, a comprehension's name, never used |

A name starting with `_` is never reported, and neither is a top-level
name a module exports (`public`), since another module uses it, nor a
name the compiler made up (a default parameter's definition,
`Desugar_args.generated_name`).

`shadowed-update` is the one with something to *say*: `x = 10` in an `if`
inside a scope that already has an `x` is what an update written
without `var`/`:=` looks like, so the warning names both lines and says
how to make it a variable. It takes the unused binding's place: where
it is on, that binding is reported once, as this; where it is off, the
binding is still an `unused-binding`.

## One walk, after the checker

`check` walks a module's statements as the checker saw them — before
elaboration, so the names are the ones the source wrote — binding names
exactly as `analyses.ml` and `scopes.ml` do: every `def` of a block
before any of the block, everything else from where it is written on.
Each binding is a record with a mutable `read`, and each use of a name
sets it on the binding the name reaches in the walk's environment. A
binding nothing read is unused.

Three kinds of use are not written as the name:

- **An overloaded call.** `twice(21)` reaches `int::twice`, and the
  checker recorded which in the `qmap` it answers beside the types. A
  call's entry there is charged to the definition it names.
- **An implicit argument.** `show(5)` passes an implicit `fmt` the call
  never writes; the `qmap` lists each argument it resolved, and each is
  charged to the binding of that name where the call is.
- **An overloaded name used as a value.** Where the walk's environment
  has no binding of a name at all, the name is an unqualified overloaded
  one, and every `q::name` in scope is charged.

A `var` read anywhere counts as read, in its own update too
(`n := n + 1`); writing to it with `:=` does not.

### Functions: used means something that runs calls it

A function is charged differently: each use records the function and
the functions the use is written inside. A function is **live** if a
use of it is outside every function, or inside a live function other
than itself, or if it is exempt; `live_functions` works that out as a
fixed point. So a function that only calls itself is not live, and
neither is a group that only call one another.

Reporting every function that is not live would report too much: a
helper called only by an unused function is not live either, and saying
so twice sends the reader to the wrong one. So a function that is not
live is reported only if every function that uses it is itself, or is
in its own group — one it `reaches` by calls and nested definitions.
The unused caller outside the group is what is reported, and fixing it
fixes the helper's warning too.

## Flags, as GCC has them

`config` holds which kinds are on, `-Werror`'s answer for all of them,
and what an `-Werror=` or `-Wno-error=` said about one. `flag` applies
one flag; `of_flags` applies a list in order, so a later flag wins over
an earlier one. `-Werror=name` turns `name` on as well, as in GCC.
`to_flags` answers the shortest list that makes a config, which the
playground shows as the command line its settings stand for.

## Who calls it

Every front end that checks a program calls `check` after the
mutability analysis, with the `qmap` the checker answered:

- **pyk** (`check_module`, pyk.ml): every module of the program that is
  not in a library directory, the warnings printed to stderr before
  anything runs or is written. A `-Werror` one exits 1 after all of them
  are printed. `display` gives a submodule's member its dotted name back.
- **the REPL** (`entry_warnings`, repl_session.ml): each entry, with its
  top-level names exempt (`toplevel_used`), since a later entry may use
  them, and the session's names as `outer`, so an entry shadowing one in
  a block gets the hint. A `-Werror` one refuses the entry, as
  `Warnings.Refused`.
- **the language server** (`warnings_of`, lsp.ml): the document's own
  module, with the editor's `warnings` setting, as diagnostics of
  severity 2 (1 for an error) tagged unnecessary, with the flag as the
  code — and a quick fix putting `_` in front of the name.
- **the debugger** (`Debug_session.prepare`): the program's own modules,
  `pyk dap` sending them as stderr output events before the program
  runs, and the playground's Debug tab to `pykOnWarning`.
- **the browser bundle** (pyking_web.ml): a run, a compile, the REPL
  and the language server, all with the flags `pykSetWarnings` set; a
  run's and a compile's warnings go to `pykOnWarning`, a REPL entry's in
  its answer. The playground's Warnings settings tab sets them; the
  notebook takes `pyk notebook`'s flags from notebook.json.

## Testing

`tests/test_warnings.py` runs every `tests/warnings/*.pyk` with the
`pyk` arguments its first line names (`# pyk: -Wall`), and compares
what it wrote and its exit status with the `.out`. The REPL, the
language server, the debugger and the browser bundle each have cases of
their own in their suites: `tests/repl/warnings*.repl` (a `.flags` file
gives a session flags), `tests/lsp/warnings*.lsp`,
`tests/dap/warnings*.dap` (a `flags` line) and the warnings section of
`tests/test_playground.py`.
