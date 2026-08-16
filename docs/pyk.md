# `pyk.py`: design

How `src/pyk.py` — the command-line driver — is put together: why it
stays thin, how `Options` and `TARGETS` are built so they can't drift
from what the backends actually support, and how one front end feeds
four different commands. For the pipeline itself, see
[architecture.md](architecture.md), "Command line"; for a one-page
summary, see [source.md](source.md#pykpy).

## What the driver does, and what it deliberately doesn't

`pyk.py`'s job is narrow on purpose: parse `argv`, run the front-end
stages every command needs, dispatch to one of four command functions,
and format whatever error comes back. Every backend owns its **own**
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
filename, and every flag — `target`, `output`, `stdout`, `ast`,
`symbols`, `typecheck`, `tokens`, `tail_calls` — regardless of which
command was
actually invoked. That's a deliberate choice over, say, four different
per-command option types: it's what makes `--ast` and `--typecheck`
mean the *same thing* wherever they're written, since there's exactly
one code path (`front_end`, then `main`'s check of `options.ast`) that
interprets them, rather than four copies of that interpretation that
could quietly drift apart. `parse_args` builds one `Options` from
`argv` regardless of which command word appeared (or was left out — a
bare `pyk foo.pyk` defaults to `"python"`, `DEFAULT_COMMAND`, on the
theory, stated in the comment beside it, that someone holding a file
almost always wants to just run it).

## `TARGETS`/`EXTENSIONS`: assembled from the backends, not stated here

```python
TARGETS = (
    ("python",)
    + target_js_packaging.TARGETS
    + target_c.STANDARDS
    + target_java.VERSIONS
    + (target_ocaml.TARGET,)
)
```

Nothing in this module *lists* the ten targets by name — it concatenates
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
they run: lexing, parsing, name analysis, symbolizing, type checking and
the tail-call pass, returning `(program, tmap)`. That the order lives
here and nowhere else is deliberate — no stage reaches for another one
on its own, which is why `interpreter.check` no longer exists and why
`target_ocaml.translate_program` takes the table rather than filling
it. Every command needs this much; nothing past it is
shared. The one real branch inside it is:

```python
required = (
    options.typecheck
    or options.command == "run"
    or (options.command == "compile" and options.target == target_ocaml.TARGET)
)
```

The checker itself runs for *every* mode: the tail-call pass needs what
it knows (see [optimization.md](optimization.md)), so a program it
accepts is optimized and one it refuses is compiled as written. What
`required` decides is narrower — whether a refusal is an *error*. `pyk
run` says yes because the interpreter's fragment is the checker's
fragment, the `ocaml` target because that backend reads the types back
rather than inferring them, and `--typecheck` because it was asked for.
When `required` is true, `analyze_program` is skipped
entirely and the type checker's own name checking stands in its place —
not *in addition to* the name analysis, because the checker's own `Env`
**is** a scope and re-derives every rule `analyze_program` would have
checked, in the identical wording (`typesystem.py` raises
`analyses.AnalysisError` for an unbound name, imported rather than
reimplemented, specifically so `format_error` can't tell which pass
caught it from the message alone). Symbolizing runs unconditionally,
after whichever naming pass ran, because both `--symbols` output and
`tmap` need every node keyed by a stable symbol regardless of which
path got there.

The tail-call pass (`src/optimization.py`) sits between symbolizing and
type checking, and that position is the whole of its wiring: it rewrites
before *anything* reads the program, so `--ast` prints what it built,
the checker checks that, and `tmap` is keyed to it — which the OCaml
backend depends on, since it reads types back rather than inferring
them. `symbolize` runs a second time afterwards, for the nodes the pass
built; it keeps the symbols already handed out, so a statement the pass
moved carries its own identity through. `--no-tail-call-opt` is the one
flag that turns a stage *off* rather than asking for output, which is
why it is documented under `--help` rather than in the usage every
mistyped command prints.

`compiling_natively(options)` is the other half of that wiring: a target
whose host eliminates tail calls itself gets the program as written,
since the pass would only be undone there. Which targets those are is
`NATIVE_TAIL_CALLS`, a plain list of names here rather than something
asked of each backend -- unlike `TARGETS` and `EXTENSIONS`, which each
backend really does own, this is the driver's own decision about which
stage to run. It asks for `--ast` being off as well as the target,
because `--ast` ignores `--target` and so must not depend on one.

## Two lengths of help

`_SYNOPSIS` is what someone who typed `pyk` by itself needs: the shape
of the command, and the flags that change what it *produces*.
`USAGE_FULL`, printed for `--help`, adds `_MORE_OPTIONS` — `--symbols`,
`--tokens`, `--no-tail-call-opt` — plus the target table and the
paragraphs about what each command does. The split is by *who is
asking*: the short form answers "how do I run this", and the three flags
in the long form are ones nobody needs to know about to use the
compiler at all. `usage_error` prints the short form, since a mistyped
command is not a request for a manual.

## One table, one function, five kinds of error

```python
ERROR_KINDS = (
    (LexError, "Lexing error"),
    (ParseError, "Parsing error"),
    (AnalysisError, "Name error"),
    (typesystem.TypeError_, "Type error"),
    (interpreter.RuntimeError_, "Runtime error"),
)
```

Every stage that can refuse a program raises its own exception type,
and every one of them carries an `Info`. `format_error` doesn't need
five different formatting functions because of that uniformity — it's
one loop over `ERROR_KINDS` checking `isinstance`, and the *only* thing
that differs between a lexical failure and a runtime one is which label
gets printed. This is the same table `src/repl.py` is handed (`start`
takes `format_error` as a parameter specifically so a mistake made at
the REPL prompt is reported in the exact words a file would get — see
that module's own page), and it's why adding a sixth kind of front-end
error later would mean adding one tuple here, not writing a new
formatting function.

`fail_unsupported` is kept separate from `format_error`'s table on
purpose: an `UnsupportedError` needs to name *which target* refused the
construct (`"Unsupported by target 'nodejs': ..."`), a piece of context
none of the five `ERROR_KINDS` need, since they're refused by the front
end itself rather than by one particular backend's subset.

## `command_compile`: one function, one `write` closure reused everywhere

`command_compile` is the longest function in the module, and it reads
long mostly because it's flat rather than because it's doing anything
elaborate: pick the output path (or paths, for `esm`) if `--output`
wasn't given, dispatch on `target` to the right backend's translate/print
calls, and write or print the result. Two small closures capture the
two safety rules every write has to obey, defined once and reused
across every target's branch rather than repeated:

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

The per-target branches themselves are mostly symmetric — translate,
catch that backend's own `UnsupportedError` and hand it to
`fail_unsupported`, print or write — with two real asymmetries worth
noting: the C branch passes `target` itself as the `standard` parameter
(`target_c.py` serves both `c89` and `c23` from one function, gated by
exactly that string — see that backend's internals page), and the Java
branch has to work out the class name *before* it can print anything,
since the class name has to match whatever file name was chosen (an
explicit `--output`'s own stem, or `target_java.default_class_name`'s
Java-cased default) — a dependency none of the other targets have,
because none of them require the file and the code inside it to agree
on a name.

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
messages, even the stack-trace lines `command_run` prints — through
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
