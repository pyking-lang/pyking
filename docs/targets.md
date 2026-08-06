# Compiler targets

Pyking has no interpreter: every program is compiled. This page lists the
targets, what each one produces, and how much of the language it takes.
For how the compiler is put together see
[architecture.md](architecture.md); for the language itself see
[../PYKING.md](../PYKING.md).

## All targets

| target | family | writes | run it with | language coverage |
|---|---|---|---|---|
| `python` | [Python](target_python.md) | `foo.py` | `python3 foo.py` | **everything** |
| `nodejs` | [JavaScript](target_js.md) | `foo.js` | `node foo.js` | subset |
| `html` | [JavaScript](target_js.md) | `foo.html` | open it in a browser | subset |
| `esm` | [JavaScript](target_js.md) | `foo.js`, `foo.node.js`, `foo.html`, `package.json` | `node foo.node.js`, or serve the page | subset |
| `c89` | [C](target_c.md) | `foo.c` | `cc -std=c89 foo.c && ./a.out` | subset, minus `/` |
| `c23` | [C](target_c.md) | `foo.c` | `cc -std=c23 foo.c && ./a.out` | subset, minus `/` |
| `java8` | [Java](target_java.md) | `Foo.java` | `javac --release 8 Foo.java && java Foo` | subset, minus `/` |
| `java17` | [Java](target_java.md) | `Foo.java` | `javac --release 17 Foo.java && java Foo` | subset, minus `/` |
| `java21` | [Java](target_java.md) | `Foo.java` | `javac --release 21 Foo.java && java Foo` | subset, minus `/` |
| `ocaml` | [OCaml](target_ocaml.md) | `foo.ml` | `ocamlfind ocamlopt foo.ml -o foo && ./foo` | whatever type-checks |

Select one with `--target <name>` or `-t <name>`; `python` is the default.
With no `--output`, the compiler names the file after the source, with the
target's extension, in the current directory:

```sh
pyk -t python  tests/hello.pyk   # ./hello.py
pyk -t nodejs  tests/hello.pyk   # ./hello.js
pyk -t c23     tests/hello.pyk   # ./hello.c
pyk -t ocaml   tests/hello.pyk   # ./hello.ml
```

(`-t python` is spelled out because it is the *default* target, not
because it has to be: `pyk tests/hello.pyk`, with no options at all,
compiles and runs the program instead of leaving a file behind.)

Java is the one exception: it requires its file and public class to
match exactly, so the default name is Java-cased rather than the
source's own spelling:

```sh
pyk -t java21  tests/hello.pyk   # ./Hello.java, class Hello
```

## Families

Targets are grouped by the backend they share, and targets in a group
always accept exactly the same programs:

- **[Python](target_python.md)** — `python`. The reference backend, and
  the only one that compiles the whole language. Everything else is
  measured against it.
- **[JavaScript](target_js.md)** — `nodejs`, `html`, `esm`. One
  translation (`src/target_js_core.py`), three packagings
  (`src/target_js_packaging.py`). They differ only in where `print` goes
  and what files come out.
- **[C](target_c.md)** — `c89`, `c23`. One backend (`src/target_c.py`)
  with a `standard` parameter. They differ only in how the same C is
  printed.
- **[Java](target_java.md)** — `java8`, `java17`, `java21`. One backend
  (`src/target_java.py`) with a `version` parameter, the same shape as
  the C family. They differ only in how the same Java is printed.
- **[OCaml](target_ocaml.md)** — `ocaml`. One backend
  (`src/target_ocaml.py`), and the only family with one member. Its
  subset is not a list of constructs but a *stage*: it compiles exactly
  what the type checker accepts, by running it and reading the types
  back.

## The shared subset

The Python target compiles all of Pyking. The others implement a common
subset, chosen so that the whole pipeline — translation, packaging,
testing — could be built end to end before the language surface grew:

| feature | python | javascript | c | java | ocaml |
|---|---|---|---|---|---|
| `print` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `def`, parameters, `return`, recursion | ✅ | ✅ | ✅ | ✅ | ✅ (annotations required) |
| forward references, mutual recursion | ✅ | ✅ | ✅ (prototypes emitted) | ✅ | ✅ (`let rec … and …`; the `def`s must be adjacent) |
| `def f(x) = expr` | ✅ | ✅ | ✅ | ✅ | ✅ |
| tail position (last statement is the value) | ✅ | ✅ | ✅ | ✅ | ✅ |
| `return if c:` / `return match e:` | ✅ | ✅ (`if` only) | ✅ (`if` only) | ✅ (`if` only) | ✅ (`if` only) |
| unit-returning functions (`void`) | ✅ | ✅ | ✅ | ✅ | ✅ |
| `if` / `else if` / `else`, `while` | ✅ | ✅ | ✅ | ✅ | ✅ (`if` only) |
| `=`, `var`, `:=` | ✅ | ✅ | ✅ | ✅ | ✅ (`=` only) |
| `if … then … else …` expressions | ✅ | ✅ | ✅ (branches must agree in type) | ✅ (branches must agree in type) | ✅ (same) |
| integers, strings, booleans | ✅ | ✅ | ✅ | ✅ | ✅ |
| `+ - *`, unary minus, comparisons | ✅ | ✅ | ✅ | ✅ | ✅ (no unary minus) |
| `/` | ✅ | ✅ (prints `6`, not `6.0`) | ❌ | ❌ | ❌ |
| type annotations | erased | erased | used, when they name `Int`/`String`/`Bool` | used, when they name `Int`/`String`/`Bool` | checked, then erased — the output has none |
| functions as values (passing a `def`, calling a parameter) | ✅ | ✅ | ❌ (refused: a function used as a value, or a call to an unknown one) | ❌ (same) | ✅ |
| a function reading a binding from around it (a closure) | ✅ | ✅ | ❌ (no closures) | ❌ (no closures) | ✅ |
| lists, tuples, destructuring | ✅ | ❌ | ❌ | ❌ | ❌ |
| `for`, `match`/`case`, patterns | ✅ | ❌ | ❌ | ❌ | ❌ |
| list comprehensions | ✅ | ❌ | ❌ | ❌ | ❌ |
| value-form `x = if c:` / `x = match e:` | ✅ | ❌ | ❌ | ❌ | ✅ (`if` only) |
| `str`, `len`, `range` | ✅ | ❌ (refused at compile time) | ❌ | ❌ | ✅ (`range` takes one argument) |
| nested `def` | ✅ | ✅ | ❌ | ❌ | ✅ |
| function must provably return on every path | n/a | n/a | n/a | ✅ (`javac` requires it; refused at compile time otherwise) | n/a |

The `ocaml` column is the type checker's coverage, not a list this
backend maintains: it compiles what `src/typesystem.py` accepts, so the
two move together. That is also why it is the one target whose subset
grows without touching the backend — and why a `def` there must be
annotated, which no other target requires.

A program outside a target's subset is refused at compile time, with a
source position, rather than emitted as code that will not build:

```
$ pyk -t nodejs tests/for_simple.pyk
'tests/for_simple.pyk' 2:0-3:22 Unsupported by target 'nodejs': `for`
  loops are not supported by the JavaScript backends yet
```

## Differences that survive the subset

Two programs that compile everywhere can still print different
characters, and both cases are documented rather than papered over:

- **Float display.** Pyking's `/` is true division, so `(4 + 8) / 2` is a
  float: Python prints `6.0`, JavaScript `6`. See
  [target_js.md](target_js.md#numbers).
- **Integer division.** C's and Java's `/` on integers truncates, which
  is a different *value*, not just a different rendering — so the C and
  Java targets refuse `/` outright. See
  [target_c.md](target_c.md#what-is-not-supported) and
  [target_java.md](target_java.md#what-is-not-supported).

Everything else is expected to agree exactly, and the test suite enforces
it: `tests/test_cases.toml` lists which targets each program supports, and
every one of them is compared against the *same* `.out` file.
