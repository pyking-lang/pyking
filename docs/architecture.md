# Pyking architecture

How the compiler is put together: the stages a program passes through,
the backends it can come out of, and the boundary between a Pyking
program and the world it runs in. For the language itself — syntax,
semantics, scoping rules — see [PYKING.md](../PYKING.md).

The compiler is built to bootstrap. `boot/` holds a throwaway
implementation written in a convenient host language (Python), and the
plan is to eventually rewrite the compiler in Pyking itself and compile
it with this one. Nothing in `boot/` is meant to survive that
transition, so it favours being obvious over being clever — and it is
why the code is written in a style that ports easily: one dataclass per
AST variant, and `match`/`case` over them rather than method dispatch.

## The pipeline

```
                          foo.pyk
                             │
                    ┌────────▼────────┐
                    │  boot/lexer.py  │   characters → tokens
                    └────────┬────────┘
                    ┌────────▼────────┐
                    │ boot/parser.py  │   tokens → AST
                    └────────┬────────┘
                    ┌────────▼────────┐
                    │boot/analyses.py │   names & scoping: rejects,
                    └────────┬────────┘   never rewrites
                             │
                   boot/syntax.py AST — the one
                   thing every backend shares
                             │
            ┌────────────────┴─────────────────┐
            ▼                                  ▼
  ┌───────────────────┐            ┌────────────────────────┐
  │target_python.py   │            │  target_js_core.py     │
  │Py AST + printer   │            │  JS AST + printer      │
  └─────────┬─────────┘            └───────────┬────────────┘
            │                                  │ JsRuntimeCall("print", …)
            │                      ┌───────────▼────────────┐
            │                      │ target_js_packaging.py │
            │                      └─┬─────────┬──────────┬─┘
            ▼                        ▼         ▼          ▼
         foo.py                   foo.js   foo.html    foo.js
                                                     + foo.node.js
                                                     + foo.html
                                                     + package.json

        boot/runtime_interface.py — the contract both sides
        reference: what a program may observe of the outside world
```

Everything above the split is target-independent, and every backend
starts from the same checked AST. `--ast` prints that AST and therefore
ignores `--target`.

## Stages

| module | role |
|---|---|
| `boot/lexer.py` | Characters → tokens. `Info` (file, row/column span) is attached to every token and rides along on every later node, so any stage can report an error against the source. |
| `boot/parser.py` | Recursive descent, tokens → the AST in `syntax.py`. Also enforces the few rules the grammar cannot state (duplicate pattern bindings, "every branch of a bound `if` yields a value"). |
| `boot/syntax.py` | The AST itself — one dataclass per variant — plus a pretty printer that prints Pyking back out. |
| `boot/analyses.py` | Static checks over the AST, currently names and scoping. Runs for every mode, `--ast` included; it only rejects, never rewrites. |
| `boot/target_python.py` | Python backend: its own `Py*` AST, translation, printer. |
| `boot/target_js_core.py` | JavaScript AST, translation, printer — with no knowledge of packaging. |
| `boot/target_js_packaging.py` | Wraps that output into the files each JS target delivers, and supplies the JavaScript side of the runtime interface. |
| `boot/runtime_interface.py` | The host/IO boundary. Backend-agnostic. |
| `boot/pykboot.py` | The driver: flags, stage sequencing, error reporting. |

## The runtime interface

A Pyking program on its own only computes. It cannot reach a console, a
file or a clock; everything observable crosses a boundary that
`boot/runtime_interface.py` writes down. This is the split WebAssembly
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
string is written bare, an integer in base 10, and a boolean as `True` or
`False`. That last one is where a JavaScript host cannot simply hand the
value to `String()` — it must convert — and it is why every JS host in
`target_js_packaging.py` routes through one `pykFormat`.

`target_js_core.py` emits a `JsRuntimeCall` for each such operation and
never decides what it looks like. Packaging decides, and that is the only
real difference between the three JavaScript targets.

## Targets

Selected with `--target <name>` or `-t <name>`; `python` is the default.

| target | files written | `print` goes to |
|---|---|---|
| `python` | `foo.py` | Python's own `print` |
| `nodejs` | `foo.js` | `console.log`, called directly — self-contained, `node foo.js` |
| `html` | `foo.html` | a visible box on the page — self-contained, open it from disk |
| `esm` | `foo.js`, `foo.node.js`, `foo.html`, `package.json` | a function the embedder passes in |

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

`--output` overrides that. A single-file target writes exactly the path
given. `esm` reads it as a *stem*, because it produces several files and
their endings are not the caller's to choose: `--output out/prog`,
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
python3 boot/pykboot.py [--tokens] [--target|-t <target>] [--ast | --stdout | --output <file>] <filename>
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

## What the JavaScript backends support

The JS backends implement a subset of Pyking, chosen so the pipeline and
the three packagings could be built end to end before the language
surface grew:

**Supported** — `print`; `def` with parameters (type annotations erased),
including the single-expression `def f(x) = e` form; `if` / `else if` /
`else`; `while`; `return`; `var` and `:=`; immutable `=` bindings to a
single name; `if ... then ... else` expressions; integer, string and
boolean values; arithmetic (`+ - * /`, unary minus), comparisons, and
calls.

**Not yet** — lists, tuples and tuple destructuring; `for`; `match`/`case`
and patterns; comprehensions; value-form `if`/`match` bindings; the
builtins `str`, `len` and `range`.

Anything outside the subset is refused at compile time with a source
position, never emitted as broken JavaScript.

### JavaScript is a closer fit than Python

Two things the Python backend has to work around fall out for free here:

- `const` is an immutable binding and `let` a mutable variable, so
  Pyking's `=`, `var` and `:=` map straight onto them, where the Python
  backend must collapse all three into one assignment form.
- `{ }` blocks are scopes, exactly as Pyking's blocks are. The Python
  backend renames a binding that shadows an outer name, because Python
  has no block scope; the JS backend renames only where JavaScript's own
  rules force it — `const` cannot be redeclared in one block, and a
  `const` shadowing an outer name makes that name unreadable earlier in
  the same block (the temporal dead zone).

### Renaming in the Python backend

Pyking makes every block a scope; Python does not. A binding that shadows
an outer name inside an `if`/`for`/`while`/`case` body would land on the
same Python variable, and the outer name would come back changed. So
`target_python.py` renames such a binding, keeping the generated name
close to the source one — `total` becomes `total2`, or `total3` if
`total2` is itself in scope:

```
$ python3 boot/pykboot.py --stdout tests/shadowing_blocks.pyk
total = 1
if 1 < 2:
    total2 = 2       # the block's own `total`
    print(total2)
print(total)         # still the outer one
```

It renames only where needed, so generated code keeps the names actually
written wherever it can: not inside a `def` body or a comprehension
(Python already scopes those), and not when the shadowed binding is
unreachable anyway — rebinding within one block, or two sibling blocks
using the same name. `tests/shadowing_blocks.pyk` exercises all of it.

## Known differences between targets

The same program should print the same characters on every target, and
the test suite checks exactly that by comparing all of them against one
`.out` file. One difference remains, and it is why a couple of test
programs are python-only:

- **Float display.** Pyking's `/` is true division, so `(4 + 8) / 2` is a
  float and Python prints `6.0`. JavaScript has a single number type and
  prints `6`. Making the JS backends agree would mean carrying Python's
  int/float distinction into the generated code — ints as `BigInt`,
  division as `Number`, and a coercion helper around every arithmetic
  operator — which would cost the thing the backend is trying to keep:
  generated code that reads like the source. `arithmetic_division.pyk`
  and `short_function_values.pyk` hold the affected cases.

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
output against the sibling `.out` file — one `.out` for all four targets,
which is the property being tested. It warns about any `.pyk` missing
from the manifest, and finishes with a per-target summary.

Each target is executed the way a user would run it: `python3` on the
generated `.py`, `node` on the generated `.js`, and, for `esm`, `node` on
the *generated node driver* rather than the module — the wrapper is the
artifact a user runs, and exercising it also checks that `run(runtime)`
is wired up.

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
