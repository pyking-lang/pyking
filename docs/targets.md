# Compiler targets

A Pyking program can be compiled for any of ten targets, or run directly
by the interpreter. This page lists them, what each one produces, and how
much of the language it takes. For how the compiler is put together see
[architecture.md](architecture.md); for the code itself see
[source.md](source.md); for the language see
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
| *(none — `pyk run`)* | [the interpreter](source.md#interpreterpy) | nothing | `pyk run foo.pyk` | whatever type-checks |

Select one with `pyk compile --target <name>`, or `-t <name>`; `python`
is the default. With no `--output`, the compiler names the file after the
source, with the target's extension, in the current directory:

```sh
pyk compile -t python  tests/hello.pyk   # ./hello.py
pyk compile -t nodejs  tests/hello.pyk   # ./hello.js
pyk compile -t c23     tests/hello.pyk   # ./hello.c
pyk compile -t ocaml   tests/hello.pyk   # ./hello.ml
```

(`-t python` is spelled out because it is the *default* target, not
because it has to be: `pyk tests/hello.pyk`, with no command at all,
compiles with the Python backend, runs the program, and leaves no file
behind.)

The interpreter is the one row in the table that is not a `--target`,
because it produces no file to name. It is a command of its own:

```sh
pyk run tests/hello.pyk          # runs it; nothing is written anywhere
```

It runs the AST directly (`src/interpreter.py`) rather than translating
it, which makes it the *reference* for what a Pyking program means at run
time: where a compiled target disagrees with it, the target is wrong. Its
coverage is the type checker's, run for real — the same arrangement the
`ocaml` target uses — so a program with `var`, `for`, `while`, `match`,
lists or an unannotated `def` is refused, with the checker's own
message. A `loop` and a tuple are both inside that fragment. `pyk repl` is the same interpreter with a prompt in front of
it.

Java is the one exception: it requires its file and public class to
match exactly, so the default name is Java-cased rather than the
source's own spelling:

```sh
pyk compile -t java21  tests/hello.pyk   # ./Hello.java, class Hello
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
- **The interpreter** — `pyk run`, `pyk repl`. Not a family and not a
  backend: `src/interpreter.py` runs the AST on a small-step machine
  instead of translating it. Like `ocaml`, its subset is the type
  checker's, run for real.

## The interpreter's column

The subset table below has no column for the interpreter, because it
would be the `ocaml` column with one difference: the interpreter has
closures and real `[Int]` lists, so `str`, `len` and `range` behave as
the checker types them, and a function value can be passed, returned and
printed. Everything the checker refuses, it refuses.

Two things it does that no compiling target does:

- **A runtime error is a Pyking error**, with a span and the calls that
  were in progress under it:

  ```
  'deep.pyk' 12:4-12:18 Runtime error: maximum call depth of 10000
    exceeded; this is what a recursion that never ends looks like
    in 'forever', called at 'deep.pyk' 12:4-12:18
    ... 9999 more calls
  ```

- **It recurses further than the compiled targets.** The Pyking call
  stack lives on the heap, so depth costs memory rather than host stack:
  a 9 000-deep recursion runs interpreted and dies compiled to Python
  (whose own recursion limit is 1 000 by default). The interpreter stops
  at 10 000 with the error above rather than exhausting memory.

## Tail calls, on every target

A function that calls itself in tail position is rewritten into a `loop`
before any backend sees it, and a group that tail-calls each other into
one loop they share (`src/optimization.py`,
[optimization.md](optimization.md)). So the guarantee is the same
everywhere, including the interpreter, and no backend implements
anything for it: what each of them compiles is a program with a `loop`
in it, which they already knew how to do.

The pass runs over programs the **type checker accepts** — the types are
what decide whether a group can share one loop. A program outside that
fragment (`var`, `for`, `while`, `match`, lists) is compiled as written
and recurses as it always did.

`--no-tail-call-opt` turns the pass off. Two things then differ, and
only these two: how deep a tail recursion can go before the host gives
out, and what `--ast` prints.

The `ocaml` target is the exception, and gets the guarantee without the
pass: OCaml eliminates tail calls itself, so that target is compiled
from the program as written and a tail-recursive function compiles to a
tail-recursive function. Running the pass first would only have the
backend undo it, since a `loop` becomes a local recursive function
there.

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
| `loop`, `break`, `continue` | ✅ | ✅ | ✅ (an accumulator is required) | ✅ (same) | ✅ (a local `let rec`, applied at once) |
| tail calls run in constant space | ✅ | ✅ | ✅ | ✅ | ✅ (natively; the pass is skipped) |
| … for a program the type checker accepts | required | required | required | required | n/a |
| `=`, `var`, `:=` | ✅ | ✅ | ✅ | ✅ | ✅ (`=` only) |
| `if … then … else …` expressions | ✅ | ✅ | ✅ (branches must agree in type) | ✅ (branches must agree in type) | ✅ (same) |
| integers, strings, booleans | ✅ | ✅ | ✅ | ✅ | ✅ |
| `+ - *`, unary minus, comparisons | ✅ | ✅ | ✅ | ✅ | ✅ (no unary minus) |
| `/` | ✅ | ✅ (prints `6`, not `6.0`) | ❌ | ❌ | ❌ |
| type annotations | erased | erased | used, when they name `Int`/`String`/`Bool` | used, when they name `Int`/`String`/`Bool` | checked, then erased — the output has none |
| functions as values (passing a `def`, calling a parameter) | ✅ | ✅ | ❌ (refused: a function used as a value, or a call to an unknown one) | ❌ (same) | ✅ |
| a function reading a binding from around it (a closure) | ✅ | ✅ | ❌ (no closures) | ❌ (no closures) | ✅ |
| lists | ✅ | ❌ | ❌ | ❌ | ❌ |
| tuples, destructuring | ✅ | ✅ (arrays) | ❌ | ❌ | ✅ |
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
$ pyk compile -t nodejs tests/for_simple.pyk
'tests/for_simple.pyk' 2:0-3:22 Unsupported by target 'nodejs': `for`
  loops are not supported by the JavaScript backends yet
```

## Differences that survive the subset

Two programs that compile everywhere can still print different
characters, and both cases are documented rather than papered over —
followed by a third difference, which is about the values themselves:

- **Float display.** Pyking's `/` is true division, so `(4 + 8) / 2` is a
  float: Python prints `6.0`, JavaScript `6`. See
  [target_js.md](target_js.md#numbers).
- **Integer division.** C's and Java's `/` on integers truncates, which
  is a different *value*, not just a different rendering — so the C and
  Java targets refuse `/` outright. See
  [target_c.md](target_c.md#what-is-not-supported) and
  [target_java.md](target_java.md#what-is-not-supported).

### Integers are 32 bit

A Pyking `Int` is a **signed 32-bit integer**, and `+`, `-` and `*` wrap
on overflow, two's complement. That is what the interpreter implements,
and the interpreter is the reference — so it is the language's answer,
not one host's.

The hosts do not all agree, and they are not forced to:

| where | width | `2147483647 + 1` |
|---|---|---|
| the interpreter (`pyk run`, `pyk repl`) | 32, wrapping | `-2147483648` |
| `c89`, `c23` | whatever the C compiler's `int` is — 32 on every mainstream target | `-2147483648` (undefined behaviour, in practice this) |
| `java8`, `java17`, `java21` | 32, wrapping (the JVM defines it) | `-2147483648` |
| `python` | arbitrary precision | `2147483648` |
| `nodejs`, `html`, `esm` | IEEE-754 doubles: exact to 2^53 | `2147483648` |
| `ocaml` | 63 on a 64-bit build (OCaml's `int` keeps one bit for the GC) | `2147483648` |

Nothing is inserted into the generated code to hide this. Masking every
Python or OCaml arithmetic result back down to 32 bits would slow those
targets down, make their output unreadable, and — more to the point —
misrepresent the host: a reader of the generated `.py` should see what
Python will do with it. A program that stays inside 32 bits means the
same thing everywhere, and one that does not is relying on a width the
language does not promise.

Everything else is expected to agree exactly, and the test suite enforces
it: `tests/test_cases.toml` lists which targets each program supports, and
every one of them is compared against the *same* `.out` file.
