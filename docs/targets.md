# Compiler targets

A Pyking program can be compiled for any of twelve targets, or run directly
by the interpreter. This page lists them, what each one produces, and how
much of the language it takes. For how the compiler is put together see
[architecture.md](architecture.md); for the code itself see
[source.md](source.md); for the language see
[../PYKING.md](../PYKING.md).

## Versions and aliases

A target names a **family** and a **version**: `c23` is the C family at
C23, `java8` is Java at release 8. The version says the oldest host the
output is guaranteed to run on -- it sets the header comment, the
command `--run` uses, and what a backend may emit.

Every family also has an **unversioned alias**, naming its latest
version. `-t c` is `-t c23`, `-t java` is `-t java21`. Write the alias
when you mean "current", the version when you mean that version.

Two versions of one family may emit identical text: the difference is
what the output is *promised* to run on, not always what it says. Only C
and Java differ today.

The list itself is `src/targets.ml`, and nothing else in the compiler
names a target -- the backends, the driver, the module system and the
test harness all read it from there.

## All targets

| target | alias | family | writes | run it with | language coverage |
|---|---|---|---|---|---|
| `python14` | `python` | [Python](target_python.md) | `foo.py` | `python3 foo.py` | **everything** |
| `node24` | `node` | [JavaScript](target_js.md) | `foo.js`, `pyk-runtime.js`, `package.json` | `node foo.js` | subset |
| `web24` | `web` | [JavaScript](target_js.md) | `foo.html` and the same `.js` files | serve it: `--run` does, and prints the page's URL | subset |
| `iweb24` | `iweb` | [the interpreter](target_js.md#the-interpreted-target) | `foo.html`, `pyking.js`, the `.pyk` sources | serve it: `--run` does, and prints the page's URL | **everything the checker accepts** |
| `c89` | | [C](target_c.md) | `foo.c` | `cc -std=c89 foo.c && ./a.out` | subset, minus `/` |
| `c99` | | [C](target_c.md) | `foo.c` | `cc -std=c99 foo.c && ./a.out` | subset, minus `/` |
| `c23` | `c` | [C](target_c.md) | `foo.c` | `cc -std=c23 foo.c && ./a.out` | subset, minus `/` |
| `java8` | | [Java](target_java.md) | `Foo.java` | `javac --release 8 Foo.java && java Foo` | subset, minus `/` |
| `java17` | | [Java](target_java.md) | `Foo.java` | `javac --release 17 Foo.java && java Foo` | subset, minus `/` |
| `java21` | `java` | [Java](target_java.md) | `Foo.java` | `javac --release 21 Foo.java && java Foo` | subset, minus `/` |
| `ocaml5.5` | `ocaml` | [OCaml](target_ocaml.md) | `foo.ml` | `ocamlopt foo.ml -o foo && ./foo` | whatever type-checks |
| `pyking` | | *(the front end itself)* | `foo.pyk` | `pyk foo.pyk` | everything |
| *(none — `pyk foo.pyk`)* | | [the interpreter](source.md#interpreterml) | nothing | `pyk foo.pyk` | whatever type-checks |

`iweb24` is the odd one and worth reading twice: it compiles nothing.
The page ships the Pyking source and the compiler built to JavaScript,
and interprets the program in the browser -- so it takes the whole
fragment the checker accepts rather than one backend's subset. See
[target_js.md](target_js.md), "The interpreted target".

Select one with `pyk compile --target <name>`, or `-t <name>`; `python`
is the default. With no `--output`, the compiler names the file after the
source, with the target's extension, in the current directory:

```sh
pyk compile -t python  tests/hello.pyk   # ./hello.py   (python14)
pyk compile -t node    tests/hello.pyk   # ./hello.js   (node24)
pyk compile -t c23     tests/hello.pyk   # ./hello.c
pyk compile -t c       tests/hello.pyk   # ./hello.c    (the same: c is c23)
pyk compile -t ocaml   tests/hello.pyk   # ./hello.ml   (ocaml5.5)
```

(`-t python` is spelled out because it is the *default* target, not
because it has to be. `pyk tests/hello.pyk`, with no command at all,
does not compile at all: it runs the program with the interpreter.)

`--run` builds and runs what was compiled, with the commands in the
table's fourth column, each printed before it runs:

```sh
$ pyk compile -t c23 --run hello.pyk
$ cc -std=c23 -o hello hello.c
$ ./hello
Hello, world!
```

`pyking` is the odd row: it compiles Pyking to Pyking, printing the
program the front end worked out — with the types the checker inferred
and the loops the tail-call pass built. It supports everything because it
*is* the shared AST rather than a translation of it, and running it means
handing it back to this compiler.

The interpreter is the one row in the table that is not a `--target`,
because it produces no file to name. It is a command of its own:

```sh
pyk tests/hello.pyk              # runs it; nothing is written anywhere
```

It runs the AST directly (`src/interpreter.ml`) rather than translating
it, which makes it the *reference* for what a Pyking program means at run
time: where a compiled target disagrees with it, the target is wrong. Its
coverage is the type checker's, run for real — the same arrangement the
`ocaml5.5` target uses — so a program with `var`, `for`, `while`, `match`,
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
- **[JavaScript](target_js.md)** — `node24`, `web24`, and `iweb24`. One
  translation (`src/target_js_core.ml`), three packagings
  (`src/target_js_packaging.ml`). They differ only in where `print` goes
  and what files come out.
- **[C](target_c.md)** — `c89`, `c23`. One backend (`src/target_c.ml`)
  with a `standard` parameter. They differ only in how the same C is
  printed.
- **[Java](target_java.md)** — `java8`, `java17`, `java21`. One backend
  (`src/target_java.ml`) with a `version` parameter, the same shape as
  the C family. They differ only in how the same Java is printed.
- **[OCaml](target_ocaml.md)** — `ocaml5.5`. One backend
  (`src/target_ocaml.ml`), and the only family with one member. Its
  subset is not a list of constructs but a *stage*: it compiles exactly
  what the type checker accepts, by running it and reading the types
  back.
- **The interpreter** — `pyk <file>`, `pyk repl`. Not a family and not a
  backend: `src/interpreter.ml` runs the AST on a small-step machine
  instead of translating it. Like `ocaml5.5`, its subset is the type
  checker's, run for real.

## The interpreter's column

The subset table below has no column for the interpreter, because it
would be the `ocaml5.5` column with one difference: the interpreter has
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
one loop they share (`src/optimization.ml`,
[optimization.md](optimization.md)). So the guarantee is the same
everywhere, including the interpreter, and no backend implements
anything for it: what each of them compiles is a program with a `loop`
in it, which they already knew how to do.

The pass runs over programs the **type checker accepts** — the types are
what decide whether a group can share one loop. Every program is
type-checked, so that is every program; what the pass can still decline
is a group whose members disagree about their parameter types, which is
left as the recursion it was.

`--no-tail-call-opt` turns the pass off. Two things then differ, and
only these two: how deep a tail recursion can go before the host gives
out, and what `-t pyking` prints.

The `ocaml5.5` target is the exception, and gets the guarantee without the
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
| a block on its header's own line (`def f(x): expr`) | ✅ | ✅ | ✅ | ✅ | ✅ |
| tail position (last statement is the value) | ✅ | ✅ | ✅ | ✅ | ✅ |
| `return if c:` / `return match e:` | ✅ | ✅ (`if` only) | ✅ (`if` only) | ✅ (`if` only) | ✅ (`if` only) |
| unit-returning functions (`void`) | ✅ | ✅ | ✅ | ✅ | ✅ |
| `if` / `else if` / `else`, `while` | ✅ | ✅ | ✅ | ✅ | ✅ (`if` only) |
| `loop`, `break`, `continue` | ✅ | ✅ | ✅ | ✅ | ✅ (a local `let rec`, applied at once) |
| `for x in e:` | ✅ | ✅ (`for…of`) | ❌ (needs lists) | ❌ (same) | ❌ (not built yet) |
| `while c:` | ✅ | ✅ | ✅ | ✅ | ❌ |
| … with an accumulator (`loop a = 0 while c:`) | ✅ | ✅ | ✅ | ✅ | ❌ |
| a loop whose *value* is taken and is `()` or a tuple | ✅ | ✅ | ❌ (no value for either) | ❌ (same) | ✅ (unit only) |
| tail calls run in constant space | ✅ | ✅ | ✅ | ✅ | ✅ (natively; the pass is skipped) |
| … for a program the type checker accepts | always: every program is checked | same | same | same | n/a |
| `=`, `var`, `:=` | ✅ | ✅ | ✅ | ✅ | ✅ (`var` is a `ref`) |
| … a `var` of any type but `Int`/`Bool` | ❌ (refused by the checker) | ❌ (same) | ❌ (same) | ❌ (same) | ❌ (same) |
| `if … then … else …` expressions | ✅ | ✅ | ✅ (branches must agree in type) | ✅ (branches must agree in type) | ✅ (same) |
| integers, strings, booleans | ✅ | ✅ | ✅ | ✅ | ✅ |
| `+ - *`, unary minus, comparisons | ✅ | ✅ | ✅ | ✅ | ✅ (no unary minus) |
| `++` (string concatenation) | ✅ | ✅ | ✅ (a generated `pyk_concat`) | ✅ (Java's own `+`) | ✅ (`^`) |
| type variables (`def id(x:a) -> a`) | ✅ | ✅ | ❌ (one concrete type per function) | ❌ (same) | ✅ (OCaml generalizes a `let` itself) |
| … a polymorphic *parameter* (`all x. (x) -> x`) | ✅ | ✅ | ❌ | ❌ | ❌ (needs an explicit `'a.`) |
| `def name : type` on a line of its own | ✅ | ✅ | ✅ | ✅ | ✅ |
| unary minus | ✅ | ✅ | ✅ | ✅ | ✅ |
| lists, list comprehensions | ✅ | ✅ | ❌ (no heap value model) | ❌ (same) | ✅ (OCaml's own lists) |
| `match` over scalars | ✅ | ✅ | ✅ (an if/else chain) | ✅ (same) | ✅ (OCaml's own `match`) |
| `match` over lists and tuples | ✅ | ✅ | ❌ | ❌ | ✅ |
| … a list pattern with elements after `..` | ✅ | ✅ | ❌ | ❌ | ❌ (`::` matches from the front) |
| operands and arguments evaluate left to right | ✅ (the host's own rule) | ✅ (same) | ✅ (unspecified in C: temporaries and the comma operator pin it down where two operands can print) | ✅ (the host's own rule) | ✅ (unspecified in OCaml: `let` pins it down, same rule) |
| `/` (integer division, truncating) | ✅ | ✅ | ✅ | ✅ | ✅ |
| type annotations | erased | erased | used, when they name `Int`/`String`/`Bool` | used, when they name `Int`/`String`/`Bool` | checked, then erased — the output has none |
| functions as values (passing a `def`, calling a parameter) | ✅ | ✅ | ❌ (refused: a function used as a value, or a call to an unknown one) | ❌ (same) | ✅ |
| a function reading a binding from around it (a closure) | ✅ | ✅ | ❌ (no closures) | ❌ (no closures) | ✅ |
| a function *writing* a `var` from around it | ✅ (`global`/`nonlocal`) | ✅ | ❌ (same) | ❌ (same) | ✅ (the `ref` it closes over) |
| a `def` inside a loop, keeping that turn's values | ✅ (a per-turn factory) | ✅ (a per-turn `const`) | ❌ | ❌ | ✅ |
| lists | ✅ | ❌ | ❌ | ❌ | ❌ |
| tuples, destructuring | ✅ | ✅ (arrays) | ❌ | ❌ | ✅ |
| `for`, `match`/`case`, patterns | ✅ | ❌ | ❌ | ❌ | ❌ |
| list comprehensions | ✅ | ❌ | ❌ | ❌ | ❌ |
| value-form `x = if c:` / `x = match e:` | ✅ | ❌ | ❌ | ❌ | ✅ (`if` only) |
| `str`, `len`, `range` | ✅ | ❌ (refused at compile time) | ❌ | ❌ | ✅ (`range` takes one argument) |
| nested `def` | ✅ | ✅ | ❌ | ❌ | ✅ |
| function must provably return on every path | n/a | n/a | n/a | ✅ (`javac` requires it; refused at compile time otherwise) | n/a |
| modules: `import`, `from`, `public` | ✅ (Python's own `import`) | ✅ (one ES module each, `node` and `web` alike) | ✅ (one translation unit and a header each) | ✅ (one class each) | ✅ (one module and a `.mli` each) |
| … privacy enforced in the output | ❌ (Python has none) | ❌ (a module exports what it exports) | ✅ (`static`) | ✅ (`private static`) | ✅ (the `.mli` is the export list) |
| … a module implemented in the target's own language | ✅ (`sys.py`) | ✅ (`sys.js`, an ES module) | ✅ (`sys.c`, declared inline) | ✅ (`Sys.java`) | ✅ (`sys.ml`) |
| … a module's top level runs before its importers' | ✅ (import does it) | ✅ (ES module order does it) | ✅ (a generated `<name>_init()`) | ✅ (a generated `Module.init()`) | ✅ (link order) |

Every target supports modules, and every one of them compiles a module
to a file of its own beside the program's output.
[modules.md](modules.md) has the shape each of them uses; the family
pages have the generated code.

The JavaScript targets get Pyking's own rule for free: an ES module's
top level runs once, the first time something imports it, and imports
resolve before the importing file runs. There is nothing for the program
to arrange and no `init` to call.

The `ocaml5.5` column is the type checker's coverage, not a list this
backend maintains: it compiles what `src/typesystem.ml` accepts, so the
two move together. That is also why it is the one target whose subset
grows without touching the backend — and why a `def` there must be
annotated, which no other target requires.

A program outside a target's subset is refused at compile time, with a
source position, rather than emitted as code that will not build:

```
$ pyk compile -t node24 tests/for_simple.pyk
'tests/for_simple.pyk' 2:0-3:22 Unsupported by target 'node24': `for`
  loops are not supported by the JavaScript backends yet
```

## Differences that survive the subset

Two programs that compile everywhere can still print different
characters, and both cases are documented rather than papered over —
followed by a third difference, which is about the values themselves:

- **Division by zero.** Pyking's `/` is integer division and every
  target divides natively, so `1 / 0` is whatever the host does: a
  `ZeroDivisionError` on Python, an `ArithmeticException` on Java,
  `Division_by_zero` on OCaml, `Infinity` on JavaScript, and undefined
  behaviour in C. The interpreter is the exception, and has to be: its
  `step` is total, so it reports a Pyking runtime error with a stack
  trace like any other. Nothing guards the compiled output.

### Integers hold 32 bits, and overflow is undefined

A Pyking `Int` holds **at least the signed 32-bit range**. Past it the
result is **undefined**: the language does not say what `2147483647 + 1`
is, and no two targets are required to agree (PYKING.md, "Integer and
string literals").

That is why the widths below are a description rather than a list of
deviations — each host is simply doing its own arithmetic:

| where | width | `2147483647 + 1` |
|---|---|---|
| the interpreter, `pyk <file>` / `pyk repl` | 63 (OCaml's `int` keeps one bit for the GC) | `2147483648` |
| the interpreter in the playground | 32 (js_of_ocaml's `int`) | `-2147483648` |
| `c89`, `c23` | whatever the C compiler's `int` is — 32 on every mainstream target | `-2147483648` (undefined behaviour, in practice this) |
| `java8`, `java17`, `java21` | 32, wrapping (the JVM defines it) | `-2147483648` |
| `python` | arbitrary precision | `2147483648` |
| `node24`, `web24` | IEEE-754 doubles: exact to 2^53 | `2147483648` |
| `ocaml5.5` | 63 | `2147483648` |

The interpreter appears twice on purpose: it is one implementation
compiled two ways, and past 2^31 the two disagree. Both conform, because
there is nothing there to conform to.

**Nothing is inserted into the generated code**, and nothing narrows a
result in the interpreter either. Masking every Python or OCaml
arithmetic result back down to 32 bits would slow those targets down,
make their output unreadable, and — more to the point — misrepresent the
host: a reader of the generated `.py` should see what Python will do
with it.

What *is* fixed everywhere is what a program may write down: an integer
literal outside the signed 32-bit range is a lexical error on every
target. A program that stays inside that range means the same thing
everywhere; one that leaves it is relying on a width the language does
not promise.

Everything else is expected to agree exactly, and the test suite enforces
it: `tests/test_cases.toml` lists which targets each program supports, and
every one of them is compared against the *same* `.out` file.
