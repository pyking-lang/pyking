# Pyking architecture

How the compiler is put together: the stages a program passes through,
the backends it can come out of, and the boundary between a Pyking
program and the world it runs in. For the language itself — syntax,
semantics, scoping rules — see [PYKING.md](../PYKING.md); for what each
compiler target supports and how it compiles, see
[targets.md](targets.md).

The compiler is built to bootstrap. `src/` holds a throwaway
implementation written in a convenient host language (Python), and the
plan is to eventually rewrite the compiler in Pyking itself and compile
it with this one. Nothing in `src/` is meant to survive that
transition, so it favours being obvious over being clever — and it is
why the code is written in a style that ports easily: one dataclass per
AST variant, and `match`/`case` over them rather than method dispatch.

## The pipeline

```
                          foo.pyk
                             │
                    ┌────────▼────────┐
                    │  src/lexer.py  │   characters → tokens
                    └────────┬────────┘
                    ┌────────▼────────┐
                    │ src/parser.py  │   tokens → AST
                    └────────┬────────┘
                    ┌────────▼────────┐
                    │src/analyses.py │   names & scoping: rejects,
                    └────────┬────────┘   never rewrites
                             │
                   src/syntax.py AST — the one
                   thing every backend shares
                             │
      ┌─────────────────┴──────────┬──────────────────┬──────────────────┐
      ▼                            ▼                  ▼                  ▼
┌──────────────┐   ┌────────────────────────┐  ┌──────────────┐  ┌───────────────┐
│target_python │   │    target_js_core.py   │  │ target_c.py  │  │target_java.py │
│ Py AST + pr. │   │    JS AST + printer    │  │ C AST + pr.  │  │ Java AST + pr.│
└──────┬───────┘   └───────────┬────────────┘  └──────┬───────┘  └───────┬───────┘
       │                       │ JsRuntimeCall(…)     │ standard=        │ version=
       │           ┌───────────▼────────────┐         │ c89 | c23        │ java8 | 17 | 21
       │           │ target_js_packaging.py │         │                  │
       │           └─┬─────────┬──────────┬─┘         │                  │
       ▼             ▼         ▼          ▼           ▼                  ▼
    foo.py        foo.js   foo.html    foo.js       foo.c            Foo.java
                                     + foo.node.js
                                     + foo.html
                                     + package.json

        src/runtime_interface.py — the contract both sides
        reference: what a program may observe of the outside world
```

Everything above the split is target-independent, and every backend
starts from the same checked AST. `--ast` prints that AST and therefore
ignores `--target`.

## Stages

| module | role |
|---|---|
| `src/lexer.py` | Characters → tokens. `Info` (file, row/column span) is attached to every token and rides along on every later node, so any stage can report an error against the source. |
| `src/parser.py` | Recursive descent, tokens → the AST in `syntax.py`. Also enforces the few rules the grammar cannot state (duplicate pattern bindings, "every branch of a bound `if` yields a value"). |
| `src/syntax.py` | The AST itself — one dataclass per variant — plus a pretty printer that prints Pyking back out. |
| `src/analyses.py` | Static checks over the AST, currently names and scoping. Runs for every mode, `--ast` included; it only rejects, never rewrites. |
| `src/target_python.py` | Python backend: its own `Py*` AST, translation, printer. |
| `src/target_js_core.py` | JavaScript AST, translation, printer — with no knowledge of packaging. |
| `src/target_js_packaging.py` | Wraps that output into the files each JS target delivers, and supplies the JavaScript side of the runtime interface. |
| `src/target_c.py` | C AST, translation, printer, for both `c89` and `c23` — one backend with a `standard` parameter. Infers types, which C needs and Pyking does not have. |
| `src/target_java.py` | Java AST, translation, printer, for `java8`, `java17` and `java21` — one backend with a `version` parameter, the same shape as `target_c.py`. Infers types the same way; also checks that every function provably returns, since `javac` (unlike C) refuses one that doesn't. |
| `src/runtime_interface.py` | The host/IO boundary. Backend-agnostic. |
| `src/pykboot.py` | The driver: flags, stage sequencing, error reporting. |

## The runtime interface

A Pyking program on its own only computes. It cannot reach a console, a
file or a clock; everything observable crosses a boundary that
`src/runtime_interface.py` writes down. This is the split WebAssembly
draws — a core language with no access to the world, plus a separate
named set of operations a host agrees to provide — and it is drawn here
for the same reason: the language keeps one meaning, while *where the
output goes* becomes the host's decision instead of something baked into
the compiler.

Today the interface has exactly one operation:

```
print(values...)   write one line; values formatted individually and
                   joined with single spaces
```

Its formatting rules are part of the contract, not of any backend: a
string is written bare, an integer in base 10, and a boolean as `true` or
`false` — Pyking's own spelling (see PYKING.md), not Python's capitalised
`True`/`False`. JavaScript and Java already spell booleans that way
natively and need no conversion; C spells booleans neither way in either
standard, so it always builds a conditional expression (see
`docs/target_c.md`). Python's own `print` capitalises, so its backend
has the most work: for a `print` argument its own AST shape already
proves is (or isn't) a `Bool` -- a comparison, a boolean literal, plain
arithmetic, ... -- it needs no runtime check at all, just an inline
conditional or none; only a value it can't classify that way (a
variable, a function call) falls back to a small generated helper,
appearing only when actually needed (see "Booleans" in
`docs/target_python.md`). Every JS host in `target_js_packaging.py`
still routes through one `pykFormat`, kept as a single indirection point
for any future value type that does need converting, even though today
it is just `String()`.

`target_js_core.py` emits a `JsRuntimeCall` for each such operation and
never decides what it looks like. Packaging decides, and that is the only
real difference between the three JavaScript targets.

## Targets

Selected with `--target <name>` or `-t <name>`; `python` is the default.
Each family is documented in full in [targets.md](targets.md) and the
pages it links to; what follows is the shape of the mechanism.

| target | files written | `print` goes to |
|---|---|---|
| `python` | `foo.py` | Python's own `print` |
| `nodejs` | `foo.js` | `console.log`, called directly — self-contained, `node foo.js` |
| `html` | `foo.html` | a visible box on the page — self-contained, open it from disk |
| `esm` | `foo.js`, `foo.node.js`, `foo.html`, `package.json` | a function the embedder passes in |
| `c89` | `foo.c` | `printf`, from a C89-conforming file |
| `c23` | `foo.c` | `printf`, from a C23 file |
| `java8` | `Foo.java` | `System.out.println`, `javac --release 8` |
| `java17` | `Foo.java` | `System.out.println`, `javac --release 17` |
| `java21` | `Foo.java` | `System.out.println`, `javac --release 21` |

`esm` is the interesting one. The module exports `run(runtime)` and
prints through `runtime.print(...)`, so it reaches nothing by itself:

```js
export function run(runtime) {
  let i = 0;
  while (i < 5) {
    runtime.print(i);
    i = i + 1;
  }
}
```

The same module therefore prints to a terminal under the generated node
driver and onto the page under the generated HTML wrapper, with no
recompilation — and could just as well print into a debugger, a test
harness, or a text box in someone else's application. Running either
wrapper behaves exactly like the `nodejs` and `html` targets.

### Naming the output

With no `--output`, the compiler names the file itself: the source file's
own name, the target's extension, in the directory the command was run
from. `pykboot.py -t nodejs tests/hello.pyk` writes `./hello.js`, and
`-t python` would have written `./hello.py`.

The Java targets are the one exception: Java requires the file holding a
`public` class to share that class's name exactly, so the source's own
spelling would not do. `pykboot.py -t java21 tests/foo_bar.pyk` writes
`./FooBar.java`, holding `public final class FooBar` — see "Naming the
class" in [target_java.md](target_java.md#naming-the-class) for the exact
rule and what an explicit `--output` does instead.

`--output` overrides that. A single-file target writes exactly the path
given (for Java, its class is then named after that path instead of the
source). `esm` reads it as a *stem*, because it produces several files
and their endings are not the caller's to choose: `--output out/prog`,
`out/prog.js` and `out/prog.html` all write

```
out/prog.js         the module
out/prog.node.js    the node driver
out/prog.html       the browser wrapper
out/package.json    `{ "type": "module" }`
```

That last file is what lets the others be plain `.js`. Node decides a
file's module system from its extension first and the nearest
`package.json` second, so without a manifest it reads `.js` as CommonJS
and the driver's `import` fails — on any node old enough to lack ES
module detection, and on *every* node inside a project whose own
`package.json` says `"type": "commonjs"`. `.mjs` would sidestep all of
that, at the cost of an extension most projects never write.

An existing `package.json` is never overwritten: if it already declares
`"type": "module"` the compiler says nothing, and otherwise it warns and
leaves the file alone — it belongs to whatever project the output landed
in, and clobbering it would break more than this build.

`--stdout` prints the primary artifact only — for `esm` the module, since
the wrappers exist only as files.

One caveat about the `esm` HTML wrapper: it *imports* the module, and
browsers refuse module imports over `file://`, so it needs serving —
`python3 -m http.server` in the output directory. The standalone `html`
target embeds the program instead and works when opened straight from
disk, which is why it is a separate target rather than a wrapper.

## Command line

```
python3 src/pykboot.py [--tokens] [--target|-t <target>] [--ast | --stdout | --output <file>] <filename>
```

With none of `--ast`, `--stdout` or `--output`, the program is compiled to
a file the compiler names (see "Naming the output" above). `--tokens`
additionally dumps the token stream first.
A file that fails to lex, parse, resolve its names, or that uses a
construct the chosen target does not support, reports

```
'file' row:col-row:col Lexing error: ...
'file' row:col-row:col Parsing error: ...
'file' row:col-row:col Name error: ...
'file' row:col-row:col Unsupported by target 'nodejs': ...
```

to stderr and produces no output.

The `pyk` wrapper script at the repository root forwards flags as-is, and
adds one convenience: called with *only* a filename it compiles to a temp
file, runs it with `python3`, and cleans up afterwards.

## What each target supports

The Python backend compiles the whole language; the JavaScript, C and
Java backends implement a common subset, and refuse anything outside it
at compile time with a source position rather than emitting code that
will not build. The per-target detail — what is supported, how each
construct is compiled, and where the output is not optimal — lives in its
own page:

- **[targets.md](targets.md)** — every target at a glance, the shared
  subset as a table, and the differences that survive it.
- **[target_python.md](target_python.md)** — `python`.
- **[target_js.md](target_js.md)** — `nodejs`, `html`, `esm`.
- **[target_c.md](target_c.md)** — `c89`, `c23`.
- **[target_java.md](target_java.md)** — `java8`, `java17`, `java21`.

Three differences are worth knowing before reading further, because they
are the only cases where one Pyking program does not mean the same thing
everywhere: JavaScript prints an integral float as `6` where Python
prints `6.0`; the C and Java targets refuse `/` outright, since integer
division there would produce a different *value* rather than a different
rendering; and the Java targets additionally refuse a function whose
control can fall off the end without returning, since `javac` — unlike
Python, and unlike C — treats that as a compile error rather than
implicitly returning `None`.

## Tests

`tests/test_cases.toml` lists every program and the targets it is
expected to work on:

```toml
[[cases]]
file = "while_simple.pyk"
targets = ["python", "nodejs", "esm", "html"]
```

`make test` runs `tests/test_script.py`, which walks that manifest,
compiles and runs each program on each of its targets, and compares the
output against the sibling `.out` file — the same `.out` file serving
every target listed for a program, which is the property being tested.
It warns about any `.pyk` missing from the manifest, and finishes with a
per-target summary.

Each target is executed the way a user would run it: `python3` on the
generated `.py`, `node` on the generated `.js`, `cc -std=… -pedantic` and
then the binary for `c89`/`c23`, `javac --release <8|17|21>` and then
`java` for `java8`/`java17`/`java21`, and, for `esm`, `node` on the
*generated node driver* rather than the module — the wrapper is the
artifact a user runs, and exercising it also checks that `run(runtime)`
is wired up. `-pedantic` matters for the C targets: the point of having a
`c89` target is that its output really is C89, and a compiler that
merely tolerated the difference would hide it. The C compiler comes from
`$CC`, defaulting to `cc`; the Java tools come from `$JAVAC`/`$JAVA`,
defaulting to `javac`/`java`.

### Testing the HTML target

There is no browser in this repository's toolchain, so the harness
extracts the page's embedded module and runs it under node with a small
`document` stub whose `textContent` accumulates whatever the program
prints:

```js
globalThis.document = {
  getElementById: () => ({
    get textContent() { return __pykCaptured; },
    set textContent(value) { __pykCaptured = value; },
  }),
};
```

That executes the real generated program and the real `print` path — the
code that writes into the page — and compares what would have appeared
there against the same `.out` as every other target. What it does *not*
prove is that a browser parses the page or that the layout works; only a
real browser can show that. The alternatives, if that ever matters
enough: a headless browser driven by Playwright or `puppeteer`, which is
truest to reality but adds a large external dependency to an otherwise
stdlib-only repository, or `jsdom`, which is lighter but still an npm
dependency and still not a browser. The stub was chosen because the
generated page's only contact with the outside world is the element it
prints into, so stubbing that one thing covers everything the compiler is
responsible for.
