# `pyk.py`: design

How `src/pyk.py` — the command-line driver — is put together: why it
stays thin, how `Options` and `TARGETS` are built so they can't drift
from what the backends actually support, and how one front end feeds
three different commands. For the pipeline itself, see
[architecture.md](architecture.md), "Command line"; for a one-page
summary, see [source.md](source.md#pykpy).

## What the driver does, and what it deliberately doesn't

`pyk.py`'s job is narrow on purpose: parse `argv`, run the front-end
stages every command needs, dispatch to one of three command functions,
and format whatever error comes back. Running what was *compiled* is
`src/execution.py`'s, by the same rule: which command builds a `.c` and
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

`Options` is a single frozen dataclass carrying the command, the
filename, and every flag — `target`, `output`, `stdout`, `run`,
`symbols`, `tokens`, `tail_calls` — regardless of which command was
actually invoked. That's a deliberate choice over, say, three different
per-command option types: it's what makes `--tokens` and `--symbols`
mean the *same thing* wherever they're written, since there's exactly
one code path (`front_end`, then `main`) that interprets them, rather
than three copies of that interpretation that could quietly drift apart.
`parse_args` builds one `Options` from `argv` regardless of which
command word appeared (or was left out — a bare `pyk foo.pyk` defaults
to `"interpret"`, `DEFAULT_COMMAND`, on the theory, stated in the
comment beside it, that someone holding a file almost always wants to
just run it).

## `TARGETS`/`EXTENSIONS`: assembled from the backends, not stated here

```python
TARGETS = (
    ("python",)
    + target_js_packaging.TARGETS
    + target_c.STANDARDS
    + target_java.VERSIONS
    + (target_ocaml.TARGET, execution.PYKING_TARGET)
)
```

Nothing in this module *lists* the compiling targets by name — it concatenates
each backend's own declaration of what it supports
(`target_js_packaging.TARGETS`, `target_c.STANDARDS`, ...). That's what
makes the usage message, `--target`'s validation, and the default
output extension (`EXTENSIONS`, built the same way) impossible to leave
stale when a target is added: a new C standard added to
`target_c.STANDARDS` shows up in `pyk --help`'s target table
automatically, with no second place in this file to remember to update.
It's the same discipline `tools/playground/generator.py`'s
`target_order` follows for the exact same reason — see that tool's own
documentation.

## `front_end`: the stages every command shares, with one branch

`front_end(options)` runs every stage before a backend, in the order
they run: loading the modules the program is made of, and then, once per
module, type checking, the mutability analysis and the tail-call pass.
It answers with each module paired with the types worked out for it.
That the order lives here and nowhere else is deliberate — no stage reaches for
another one on its own, which is why `interpreter.check` no longer
exists and why `target_ocaml.translate_program` takes the table rather
than filling it. Every command needs this much; nothing past it is
shared, and there is no branch in it at all.

There used to be one. Type checking was a *mode*, and a `required` flag
decided whose refusal counted — `pyk run`'s, the `ocaml` target's, and
`--typecheck`'s. Pyking is statically typed now, so the question is
gone: the checker runs, and a program it refuses is refused. What
follows from that is that the checker is also the **only** pass that
checks names. Its `Env` **is** a scope and derives every rule the old
`analyze_program` did, in the identical wording (`typesystem.py` raises
`analyses.AnalysisError` for an unbound name, imported rather than
reimplemented, specifically so `format_error` can't tell which pass
caught it from the message alone).

What is left in `src/analyses.py` runs *after* the checker, and is one
rule: `:=` may only name a `var`, and nothing may shadow one. It goes
second precisely because by then every name is known to be bound, so a
name the mutability walk cannot find is never "unbound" — it is
"not a mutable variable", which is the message worth printing.

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

The tail-call pass (`src/optimization.py`) sits between symbolizing and
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
written, with the source's own annotations, which is what the OCaml
bootstrap in `ocaml-src/` prints and what `make test-ocaml` compares
(see [ocaml_bootstrap.md](ocaml_bootstrap.md)).

`compiling_natively(options)` is the other half of that wiring: a target
whose host eliminates tail calls itself gets the program as written,
since the pass would only be undone there. Which targets those are is
`NATIVE_TAIL_CALLS`, a plain list of names here rather than something
asked of each backend -- unlike `TARGETS` and `EXTENSIONS`, which each
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

```python
ERROR_KINDS = (
    (LexError, "Lexing error"),
    (ParseError, "Parsing error"),
    (module.ModuleError, "Module error"),
    (AnalysisError, "Name error"),
    (typesystem.TypeError_, "Type error"),
    (interpreter.RuntimeError_, "Runtime error"),
)
```

Every stage that can refuse a program raises its own exception type,
and every one of them carries an `Info`. `format_error` doesn't need
six different formatting functions because of that uniformity — it's
one loop over `ERROR_KINDS` checking `isinstance`, and the *only* thing
that differs between a lexical failure and a runtime one is which label
gets printed. This is the same table `src/repl.py` is handed (`start`
takes `format_error` as a parameter specifically so a mistake made at
the REPL prompt is reported in the exact words a file would get — see
that module's own page), and it's why adding a seventh kind of front-end
error later would mean adding one tuple here, not writing a new
formatting function -- which is exactly what `Module error` was.

`fail_unsupported` is kept separate from `format_error`'s table on
purpose: an `UnsupportedError` needs to name *which target* refused the
construct (`"Unsupported by target 'nodejs': ..."`), a piece of context
none of the six `ERROR_KINDS` need, since they're refused by the front
end itself rather than by one particular backend's subset.

## `command_compile`: one function, one `write` closure reused everywhere

`command_compile` picks the output path (or paths, for `esm`) if
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
- **`write_manifest(path, contents)`** is `esm`'s special case: the
  target's own `package.json` is never blindly overwritten, because an
  existing one belongs to whatever project the output landed in (see
  `target_js_packaging.md`). It only writes a fresh manifest when none
  exists yet; when one does and doesn't already declare `"type":
  "module"`, it warns and leaves the file alone rather than silently
  changing (or silently *not* changing, without saying so) a file this
  driver didn't create.

The per-target branches in `compile_unit` are mostly symmetric —
translate, catch that backend's own `UnsupportedError` and hand it to
`fail_unsupported`, answer with the text — with two real asymmetries
worth noting: the C branch passes `target` itself as the `standard` parameter
(`target_c.py` serves both `c89` and `c23` from one function, gated by
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

## Running what was compiled: `--run` and `src/execution.py`

`--run` compiles for the selected target and then builds and runs the
result the way a user would by hand. What each target needs to do that
is that target's own knowledge — `node prog.js`, but `cc -std=c89 -o
prog prog.c` *and then* `prog` — so it lives in `src/execution.py`, not
here. The driver's whole part is one line at the end of
`command_compile`:

```python
if options.run:
    return execution.execute(target, output_path, module_outputs)
```

`plan_for(target, path, modules)` answers with a `Plan`: the build
commands (each of which must succeed), the command that is the program
itself, and the directory to run them in. `modules` names the files the
program's other modules were compiled to, in dependency order --
which C, Java and OCaml need, since those three *link* a program rather
than importing at run time, and for OCaml that order is also the order
the modules' top levels run in. Everything in it is made absolute, since the
commands run in the *output file's* directory rather than the one `pyk`
was called from — which is what makes `esm`'s generated `package.json`
and Java's `-cp` find what they expect. `_shown` puts them back for the
announcement: relative to the directory the command runs in, with `./`
on the program being run, since a bare name would mean PATH.

Every command is printed before it runs, prefixed `$ `, on **stderr**:
the program's own output belongs on stdout, and mixing the two would
make `pyk c --run … > out.txt` capture the wrong thing. `$CC`, `$JAVAC`,
`$JAVA` and `$OCAMLOPT` name the tools where there is a choice — the
same variables `tests/test_script.py` reads, so a machine set up to run
the suite is set up to run this.

Two targets are runnable in a way the others are not, and both are the
table's business rather than a special case here. `html` is a page, so
running it means handing it to `xdg-open` (`open` on macOS). `pyking`
compiles Pyking to Pyking, so running it means handing it back to this
compiler: `python3 src/pyk.py prog.pyk`, the interpreter, on the
generated source.

`--run` with `--stdout` is refused in `parse_args` rather than here,
because it is a statement about the *arguments*: `--stdout` writes no
file, so there is nothing for `--run` to run.

## Why `command_repl` imports `repl` lazily

```python
def command_repl():
    import repl
    return repl.start(format_error)
```

`repl.py` is handed `format_error` itself, as a parameter, precisely so
its own error reporting matches the driver's exactly — but `repl.py`
doesn't import `pyk.py` back (that would be the cycle); instead,
`pyk.py` imports `repl` **inside** `command_repl`, at the point it's
actually needed, rather than at module load time alongside every other
import at the top of the file. If it were a top-level import instead,
loading `pyk.py` would require `repl.py` to already be importable, and
if `repl.py` ever needed anything from `pyk.py` at its own import time
(it doesn't today, but the point is architectural, not incidental)
loading either module first would fail. The lazy import breaks that
potential cycle by construction, at the one call site that actually
needs it, without constraining either module's own list of top-level
imports.

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
