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
                    │  analyze_program│   never rewrites (not under
                    ├─────────────────┤   --typecheck, which replaces it)
                    │   symbolize     │   one unique integer per node
                    └────────┬────────┘
                    ┌────────▼────────┐
                    │src/typesystem.py│   --typecheck only; leaves the AST
                    └────────┬────────┘   alone, fills a symbol→type tmap
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
| `src/analyses.py` | Static passes over the AST. `analyze_program` checks names and scoping — it only rejects, never rewrites; it runs for every mode except `--typecheck`, which replaces it. `symbolize` then gives every node a unique integer `sym`, rebuilding the tree (nodes are frozen); it runs for every mode, `--ast` included. |
| `src/typesystem.py` | The type checker. Opt-in (`--typecheck`) while it covers only part of the language; it leaves the AST alone and reports what it inferred in `tmap`, a symbol → type table, which is what `--ast` then prints from. |
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

`print` produces no value -- it yields unit, `()` -- so it is a
statement, not something to bind or return, and a function whose tail is
a `print` returns unit (`void` in C and Java; Python's implicit `None`
and JavaScript's `undefined` already are it).

Its formatting rules are part of the contract, not of any backend: a
string is written bare, an integer in base 10, unit as `()` (never the
host's own name for "no value" -- not Python's `None`, not JavaScript's
`undefined`), and a boolean as `true` or
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

## Symbols and types

Two passes sit between the name analysis and the backends.

**`symbolize`** (in `src/analyses.py`) gives every AST node a unique
integer `sym`, numbering post-order from 1 — so `0`, every node's
default, means "not symbolized yet". It runs for every mode, and the
walk is generic over dataclass fields rather than one case per node
type, so a node added to `syntax.py` is covered without touching this
pass. Nothing consumes symbols yet; they exist so that a later stage
wanting to attach information to a node has a stable key that does not
depend on the node's identity or its position in the tree. `--symbols`
prints them, as an `@n` suffix, alongside `--ast`:

```
$ pyk --ast --symbols prog.pyk
x@1 = (12@2 + 20@3)@4  @5
```

A node that already has a symbol keeps it and fresh numbers continue
past the highest in the tree, which makes the pass safe to run twice
should a later pass ever synthesize nodes into an already-symbolized
tree: those get symbols without anything else being renumbered.

**`type_check`** (in `src/typesystem.py`) is the type checker, run only
under `--typecheck`, after symbolizing and before `--ast` prints
anything. What it means for a *program* — the rules it applies, what it
refuses and why — is [PYKING.md](../PYKING.md)'s "Type checking"
section, since that is language, not compiler; what follows is how the
pass is built. Its signature is

```
type_check(stmts) -> tmap
```

— a whole program in, the types it worked out back. Inside, there is one
function per AST datatype it walks, each taking a node of exactly that
type and returning exactly one kind of answer, in the shape the module
writes out as OCaml-style signatures:

```
type_check    : [Stmt] -> TMap
check_stmts   : [Stmt] -> Env -> TMap -> Type? -> Yield
check_stmt    : Stmt -> Env -> TMap -> Type? -> (Yield, Env)
check_expr    : Expr -> Env -> TMap -> Type
check_param   : Param -> TMap -> Type
same_type     : Type -> Type -> Bool
```

`Env` maps a name to what it means here and is used immutably — a
binding hands what follows it an extended *copy*, the same discipline
`analyses.py` follows, and for the same reason: what a name means is
decided by where it is written. It maps to a small `Binding` datatype
rather than straight to a type, because a name can mean something that
is not a value: `BSelf` is what a function's own name means inside its
own body, which is what lets the one place that reads a name back out
report recursion as recursion.

The `Type?` each statement function takes is the enclosing function's
return type, absent at the top level — that is what a `return` is
checked against, and why `return` outside a function is an error rather
than a special case somewhere else.

`TMap` is the deliberate opposite of `Env`: one mutable dict, mapping a
node's *symbol* to the type worked out for it, built up as the pass runs
and handed back as its result. The AST is not touched — nothing is
rebuilt and no node's `type` field is written — so what the source
*wrote* and what the checker *inferred* stay separable, and the driver
hands the finished `tmap` to `pprint_program` (below) to print the
latter. When checking
finishes, `tmap` holds an entry for each annotatable construct the
checker reached: `SFunctionDef`, `Param`, `SLet` and `SLetStmt`. A
`SFunctionDef`'s entry is its *function* type, not its return type — the
type of a thing is the type of the thing, and `-> T` in the syntax is
only part of it, which is why the printer takes `TFunction.result` for
that slot. Symbols exist for exactly this: `tmap` needs a key for a node that does
not depend on the node's identity, which is why symbolizing runs first —
and, since no node is synthesized into the tree, it does not have to run
again afterwards.

Types are the `T*` nodes from `syntax.py` rather than a vocabulary of
their own, so a checked binding prints as `x: Int = 1` — syntax the
parser accepts, which is what keeps `--typecheck --ast` output
re-parsable. They are synthesized by the checker and so carry no symbols
of their own: under `--symbols` an inferred type prints bare, since `@0`
means "not symbolized yet" and that is not what a type from `tmap` is.
That includes `TFunction`, written `(Int, Bool) -> Int`: `parse_type`
reads a parenthesized list followed by `->` as a parameter list and one
without as a tuple, which is the whole of the rule and is why a
parameter that is itself a pair is written `((Int, Bool)) -> Int`. So a
name bound to a function prints as `g: (Int) -> Int = f`, and that
re-parses like anything else.

Being writable, a function type can also reach a *backend* — as an
annotation, since annotations are erased and no backend reads one it
cannot represent (`_annotated_type` in `target_c.py` and
`target_java.py` returns `None` for it, exactly as for a list or tuple
type, leaving inference to decide). What C and Java refuse is the
*value*: a call through a parameter is `call to unknown function`,
which is a limit on functions as values rather than on their types.

Most statements, and every whole program, have type unit, `()`. Two do
not, and that is what makes `if` checkable: an *expression statement*
has its expression's type, and a *block* has its last statement's — so a
branch ending in an expression yields that expression's value, and the
two branches of an `if` are required to agree. An `if` with no `else` is
checked against unit.

Types are compared with `same_type` rather than `==`: `T*` nodes are
frozen dataclasses, so `==` would compare their `info` and `sym` too and
find `Int` written in one place different from `Int` inferred in
another.

`--typecheck` runs *instead of* `analyze_program`, not after it: the
checker carries a name environment of its own and refuses any name it
cannot find there, so running both would judge names twice, by two
passes covering different fragments of the language. The visible
consequence is that in this mode an unbound name is reported as
`Construct is not supported` by the checker rather than as a `Name
error`, and the rules only the analysis knows (a `var` may not be
shadowed) are not checked at all.

Both halves of it are pinned down by tests, distinguished by filename:
`tests/typecheck_*.pyk` must check, and its `.out` is the printed AST;
`tests/fail_typecheck_*.pyk` must not, and its `.out` is the error
message.

It currently covers immutable bindings, expression statements, `if`
statements (in both the ordinary and the value form), and fully
annotated function definitions, over `Int`, `String` and `Bool`: `+`
(overloaded: `Int + Int -> Int` and `String + String -> String`), `-`
and `*` on `Int`, `<`/`<=`/`>`/`>=` on `Int` giving `Bool`, `==` on two
values of one type giving `Bool`, and calls of a function-typed name.

A binding takes its right-hand side's type, and an annotation it wrote
is checked against that rather than replaced by it — `f: (Int, String)
-> Int = foo` is an error when `foo` is `(Int, Int) -> Int`, reported
against the annotation, since the value is a perfectly good value of its
own type.

A `def` is checked only when *every* parameter and the return type is
annotated — this checker infers nothing about a function it was not told
— and then two rules apply: every `return` must give the declared type,
and the body must *produce* it, either by returning on every path or by
ending in a value of that type. Those are the two halves of PYKING.md's
"Tail position", and one check covers both because a statement's answer
is a `Yield`: a type, or `Never` for a statement that does not complete.
A `return` yields `Never`, so a branch that returns has no value to
disagree with the branch beside it (one may return while the other
supplies the value), and a body in which nothing completes has no
trailing value left to check. That subsumes the `definitely_returns`
reasoning `target_java.py` still does for `javac` — here it falls out of
the types.

Recursion is refused rather than assumed: the function's own name is
bound in its body to `BSelf` rather than to its type, which is what lets
the error say so.

Anything else is refused with `Construct is not supported` against its
own source position — a deliberate floor, since a checker that quietly
accepted what it had not reasoned about would be worse than one that
says where it stops:

```
$ pyk --typecheck prog.pyk
'prog.pyk' 1:4-1:16 Type error: `+` cannot be applied to Int and String;
  it accepts Int + Int or String + String
```

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
pyk [options] <filename>
```

Run `pyk` with no arguments for the full option and target list, which
`src/pykboot.py` builds from `TARGETS`/`EXTENSIONS` so it cannot drift
from what the backends actually support.

With none of `--ast`, `--stdout` or `--output`, the program is compiled to
a file the compiler names (see "Naming the output" above). `--tokens`
additionally dumps the token stream first, `--symbols` makes `--ast` show
each node's symbol, and `--typecheck` runs the type checker (see
"Symbols and types" below).
A file that fails to lex, parse, resolve its names, or that uses a
construct the chosen target does not support, reports

```
'file' row:col-row:col Lexing error: ...
'file' row:col-row:col Parsing error: ...
'file' row:col-row:col Name error: ...
'file' row:col-row:col Unsupported by target 'nodejs': ...
```

to stderr and produces no output. Every message the driver prints is
reflowed to 70 columns first (`wrap` in `src/pykboot.py`), with
continuation lines indented two spaces, so a long one stays readable in
a narrow terminal instead of wrapping raggedly at whatever width it
happens to find.

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
