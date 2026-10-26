# Compiler targets

A Pyking program can be compiled for any of seventeen targets, or run directly
by the interpreter. This page lists them, what each one produces, and how
much of the language it takes. For how the compiler is put together see
[architecture.md](architecture.md); for the code itself see
[source.md](source.md); for the language see
[../PYKING.md](../PYKING.md).

## Versions and aliases

A target names a **family** and a **version**: `c23` is the C family at
C23, `java8` is Java at release 8. The version says the oldest host the
output is guaranteed to run on -- it sets the header comment and what a
backend may emit. What it counts depends on the family:

| family | targets | the version is |
|---|---|---|
| Python | `python12`, `python14` | the Python release, 3.12 or 3.14 |
| node | `node22`, `node24` | the node release; `node22` writes ES2020 and `node24` ES2024 |
| web | `web2020`, `web2024` | the ECMAScript edition the page's JavaScript is written in |
| iweb | `iweb2020`, `iweb2024` | the same, for the page running the interpreter |
| C | `c89`, `c99`, `c23` | the C standard |
| Java | `java8`, `java17`, `java21` | the Java release, as `javac --release` takes it |
| OCaml | `ocaml4.14`, `ocaml5.5` | the OCaml release |

Every family also has an **unversioned alias**, naming its default
version: `python` is `python12`, `node` `node22`, `web` `web2020`, `iweb`
`iweb2020`, `c` `c99`, `java` `java21`, `ocaml` `ocaml4.14`. The default
is the oldest version a program is likely to meet, except where an old
one costs the output something (C89, Java 8). `pyk` alone lists the
aliases; `pyk --help` lists every version.

Two versions of one family may emit identical text: the difference is
what the output is *promised* to run on, not always what it says. C and
Java differ in what they print; Python 3.14 leaves a forward reference
in a datatype's field unquoted; an ES2020 page wraps its loader in an
async function; OCaml 4.14 has no `List.take`. `--run` uses the family's
host command (`python3`, `node`, `ocamlopt`) whatever the version, since
a newer host runs older output.

The list itself is `src/targets.ml`, and nothing else in the compiler
names a target -- the backends, the driver, the module system and the
test harness all read it from there.

## All targets

| target | alias | family | writes | run it with | language coverage |
|---|---|---|---|---|---|
| `python12` | `python` | [Python](target_python.md) | `foo.py` | `python3 foo.py` | **everything** |
| `python14` | | [Python](target_python.md) | `foo.py` | `python3 foo.py` | **everything** |
| `node22` | `node` | [JavaScript](target_js.md) | `foo.js`, `pyk-runtime.js`, `package.json` | `node foo.js` | **everything the checker accepts** |
| `node24` | | [JavaScript](target_js.md) | the same | `node foo.js` | **everything the checker accepts** |
| `web2020` | `web` | [JavaScript](target_js.md) | `foo.html` and the same `.js` files | serve it: `--run` does, and prints the page's URL | **everything the checker accepts** |
| `web2024` | | [JavaScript](target_js.md) | the same | the same | **everything the checker accepts** |
| `iweb2020` | `iweb` | [the interpreter](target_js.md#the-interpreted-target) | `foo.html`, `pyking.js`, the `.pyk` sources | serve it: `--run` does, and prints the page's URL | **everything the checker accepts** |
| `iweb2024` | | [the interpreter](target_js.md#the-interpreted-target) | the same | the same | **everything the checker accepts** |
| `c89` | | [C](target_c.md) | `foo.c` | `cc -std=c89 foo.c && ./a.out` | everything but what needs a heap |
| `c99` | `c` | [C](target_c.md) | `foo.c` | `cc -std=c99 foo.c && ./a.out` | everything but what needs a heap |
| `c23` | | [C](target_c.md) | `foo.c` | `cc -std=c23 foo.c && ./a.out` | everything but what needs a heap |
| `java8` | | [Java](target_java.md) | `Foo.java`, `PykRuntime.java` | `javac --release 8 Foo.java PykRuntime.java && java Foo` | **everything the checker accepts** |
| `java17` | | [Java](target_java.md) | `Foo.java`, `PykRuntime.java` | `javac --release 17 Foo.java PykRuntime.java && java Foo` | **everything the checker accepts** |
| `java21` | `java` | [Java](target_java.md) | `Foo.java`, `PykRuntime.java` | `javac --release 21 Foo.java PykRuntime.java && java Foo` | **everything the checker accepts** |
| `ocaml4.14` | `ocaml` | [OCaml](target_ocaml.md) | `foo.ml` | `ocamlopt foo.ml -o foo && ./foo` | **everything the checker accepts** |
| `ocaml5.5` | | [OCaml](target_ocaml.md) | `foo.ml` | `ocamlopt foo.ml -o foo && ./foo` | **everything the checker accepts** |
| `pyking` | | *(the front end itself)* | `foo.pyk` | `pyk foo.pyk` | everything |
| *(none — `pyk foo.pyk`)* | | [the interpreter](source.md#interpreterml) | nothing | `pyk foo.pyk` | whatever type-checks |

`iweb` is the odd one and worth reading twice: it compiles nothing.
The page ships the Pyking source and the compiler built to JavaScript,
and interprets the program in the browser -- so it takes the whole
fragment the checker accepts rather than one backend's subset. See
[target_js.md](target_js.md), "The interpreted target".

Select one with `pyk compile --target <name>`, or `-t <name>`; `python`
is the default. The compiler writes what it generates into `build/` --
the program's file named after the source, with the target's extension,
beside a `Makefile` -- builds it, and puts the executable in the current
directory, or where `--output` says (see [pyk.md](pyk.md), "`build/`"):

```sh
pyk compile -t python  tests/hello.pyk   # build/hello.py, ./hello runs it   (python12)
pyk compile -t node    tests/hello.pyk   # build/hello.js, ./hello runs it   (node22)
pyk compile -t c99     tests/hello.pyk   # build/hello.c, the binary ./hello
pyk compile -t c       tests/hello.pyk   # the same: c is c99
pyk compile -t ocaml   tests/hello.pyk   # build/hello.ml, the binary ./hello (ocaml4.14)
```

(`-t python` is spelled out because it is the *default* target, not
because it has to be. `pyk tests/hello.pyk`, with no command at all,
does not compile at all: it runs the program with the interpreter.)

`--run` builds and runs what was compiled, with the commands in the
table's fourth column, each printed before it runs:

```sh
$ pyk compile -t c23 --run hello.pyk
$ cc -std=c23 -o hello hello.c -lm
$ ./build/hello
Hello, world!
```

`pyk hello.pyk -t c23` does the same and puts nothing beside `build/`.

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
`ocaml` target uses — so what the checker refuses is refused, with the
checker's own message. `pyk repl` is the same interpreter with a prompt
in front of it.

Java is the one exception: it requires its file and public class to
match exactly, so the default name is Java-cased rather than the
source's own spelling:

```sh
pyk compile -t java21  tests/hello.pyk   # build/Hello.java, class Hello; ./hello runs it
```

## Families

Targets are grouped by the backend they share, and targets in a group
always accept exactly the same programs:

- **[Python](target_python.md)** — `python`. The reference backend, and
  the only one that compiles the whole language. Everything else is
  measured against it.
- **[JavaScript](target_js.md)** — `node`, `web` and `iweb`. One
  translation (`src/target_js_core.ml`), three packagings
  (`src/target_js_packaging.ml`). They differ only in where `print` goes
  and what files come out.
- **[C](target_c.md)** — `c89`, `c99`, `c23`. One backend
  (`src/target_c.ml`) with a `standard` parameter. They differ only in
  how the same C is printed. C has no garbage collector, so the family
  takes everything that needs no heap and refuses the rest.
- **[Java](target_java.md)** — `java8`, `java17`, `java21`. One backend
  (`src/target_java.ml`) with a `version` parameter. All three take the
  whole checked language; they are three shapes of output: plain classes
  for java8, records and `instanceof` patterns for java17, records and
  pattern `switch` for java21.
- **[OCaml](target_ocaml.md)** — `ocaml`. One backend
  (`src/target_ocaml.ml`), and the only family with one member. It
  starts from a *stage* rather than a list of constructs — it runs the
  type checker and reads the types back — and takes away a short list
  of shapes OCaml cannot be given, which
  [target_ocaml.md](target_ocaml.md) keeps.
- **The interpreter** — `pyk <file>`, `pyk repl`. Not a family and not a
  backend: `src/interpreter.ml` runs the AST on a small-step machine
  instead of translating it. Like `ocaml`, its subset is the type
  checker's, run for real.

## The interpreter's column

The subset table below has no column for the interpreter, because it
would be the `ocaml` column with one difference: the interpreter has
closures and real `[Int]` lists, so `string`, `len` and `range` behave as
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
one loop they share (`src/opt_tailcall.ml`,
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

The `ocaml` target is the exception, and gets the guarantee without the
pass: OCaml eliminates tail calls itself, so that target is compiled
from the program as written and a tail-recursive function compiles to a
tail-recursive function. Running the pass first would only have the
backend undo it, since a `loop` becomes a local recursive function
there.

## Default parameters and named arguments, on every target

The same arrangement, one stage earlier. A default parameter becomes a
generated zero-argument `def` in the block the definition is written in,
and an omitted argument becomes a call to it; a named argument is put
back in its parameter's position. All of that happens in
`src/desugar_args.ml` ([desugar_args.md](desugar_args.md)) before the
program is symbolized, so every backend and the interpreter compile
ordinary defs and ordinary calls and none of them implements anything
for the feature.

What a target may still refuse is the **default expression**, by its own
rules: the generated def is a function like any other, so C refuses a
default that builds a list, as it refuses any other list.

`--no-typechecking -t pyking` is where the sugar can still be seen; it
is gone from every other output.

## The shared subset

Every target but C compiles everything the type checker accepts, and
`make test` runs every test program on every one of them. C has no
garbage collector, so the C family compiles everything that needs no
heap and refuses, with a source position and the reason, what does:

| feature | python | javascript | java | ocaml | c |
|---|---|---|---|---|---|
| scalars, strings, a `+` joining strings, every operator (`and`/`or`/`not` short-circuiting, `%`, `^`, `!=`, the bitwise ones) | ✅ | ✅ | ✅ | ✅ | ✅ (a string join allocates and is never freed) |
| `xs[i]` on a list | ✅ | ✅ | ✅ (`get`) | ✅ (`List.nth`) | ❌ lists need a heap |
| `def`, recursion, mutual recursion, nested `def` | ✅ | ✅ | ✅ (a nested `def` is a static method taking what it captures) | ✅ | ✅ (a nested `def` is a function taking what it captures) |
| `loop`, `while`, `break`, `continue`, value forms | ✅ | ✅ | ✅ | ✅ | ✅ |
| `for x in range(...)` | ✅ | ✅ | ✅ | ✅ | ✅ (a counting loop: no list is built) |
| `for x in` a list, lists, comprehensions, `len` of a list | ✅ | ✅ | ✅ (`java.util.List`) | ✅ | ❌ lists need a heap |
| tuples, destructuring | ✅ | ✅ (arrays) | ✅ (the runtime's `T2`, `T3`, ...) | ✅ | ✅ (a struct, by value) |
| datatypes, `x.field`, every pattern | ✅ | ✅ | ✅ (a class per constructor; a record alone for one) | ✅ | ✅ (a tagged union, by value; a plain struct for one constructor) |
| … a datatype holding itself (`Tree(a)`) | ✅ | ✅ | ✅ | ✅ | ❌ it needs a heap |
| type variables | ✅ | ✅ | ✅ (generics) | ✅ | ✅ (one function per type it is used at) |
| a polymorphic *parameter* (`all x. (x) -> x`) | ✅ | ✅ | ✅ (an interface with a generic method) | ✅ (a record with a polymorphic field) | ❌ it needs one function for every type |
| functions as values, lambdas | ✅ | ✅ | ✅ (`java.util.function`) | ✅ | ✅ (a function pointer and an environment on the stack) |
| … a function value that outlives what it captures | ✅ | ✅ | ✅ | ✅ | ❌ its environment would need a heap |
| a closure writing a `var` from around it | ✅ | ✅ | ✅ (a one-element array) | ✅ | ✅ (a cell its owner keeps) |
| modules, external modules | ✅ | ✅ | ✅ | ✅ | ✅ (a list or a closure at the boundary is refused) |
| operands evaluate left to right | ✅ | ✅ | ✅ | ✅ (`let` pins it down) | ✅ (temporaries and the comma operator pin it down) |

Every target supports modules, and every one of them compiles a module
to a file of its own beside the program's output.
[modules.md](modules.md) has the shape each of them uses; the family
pages have the generated code.

The JavaScript targets get Pyking's own rule for free: an ES module's
top level runs once, the first time something imports it, and imports
resolve before the importing file runs. There is nothing for the program
to arrange and no `init` to call.

Overloading and implicits are on every target for the same reason tail
calls are: `src/elaborate.ml` removes them from the AST, so what a
backend compiles is a program with plain names and ordinary arguments
(docs/overloading.md, docs/implicits.md).

The `ocaml` column starts from the type checker's coverage: the
backend runs `src/typesystem.ml` and reads the types back, so a program
the checker refuses is refused here first, in the checker's own words.
A construct the checker starts accepting reaches this target without
touching the backend, unless OCaml cannot be given its shape
([target_ocaml.md](target_ocaml.md), "What is not supported").

A program outside a target's subset is refused at compile time, with a
source position, rather than emitted as code that will not build:

```
$ pyk compile -t c23 tests/list_literals.pyk
'tests/list_literals.pyk' 1:8-1:10 Unsupported by target 'c23': a list,
  which needs a heap: C has no garbage collector to free one
```

The test manifest says the same thing per program: a case runs on every
target unless its `excluded` table names one with the reason, and the
test summary lists every reason (tests/test_cases.toml).

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
  trace like any other. Nothing guards the compiled output. An Int `%`
  by zero is the same case.
- **An index outside a list**, negative included. `xs[5]` on a list of
  two is an `IndexError` on Python, an `IndexOutOfBoundsException` on
  Java, `Failure "nth"` or `Invalid_argument` on OCaml and `undefined` on
  JavaScript; a negative index is the element counted from the end on
  Python. The interpreter reports a Pyking runtime error (`the index 5
  is outside a list of 2 elements`). C has no lists.
- **A power with a negative Int exponent, and a shift by a negative
  count or by 32 or more.** The language leaves both undefined (PYKING.md,
  "Remainder and power", "Bitwise operators"); the interpreter reports a
  runtime error for a negative exponent and a negative count, and
  shifts every bit out past its own width, and each host does its own
  arithmetic: Python answers a Float for `2 ^ -1` and raises for a
  negative shift, and JavaScript shifts by the count modulo 32.

### Standard error, `--release` and the exit status

`debug` writes where each host keeps diagnostic output: standard error
on Python, C, Java, OCaml and the interpreter, `console.error` on the
three JavaScript targets -- which under node is standard error, and in a
browser the console. `pyk compile --release` removes every call to
`debug` before any backend sees the program, so a release build writes
nothing there; the interpreter takes no `--release` and runs a program
as written, and `iweb`'s page is told to remove them before it runs.

A program that ends by itself ends with status 0 on every target. One
ending with `sys.exit(code)` ends with `code`, after what it printed is
written out; one ending with a runtime error ends with a status that is
not 0 -- 1 on most hosts, and whatever an uncaught OCaml exception gives
on `ocaml`. A page cannot end with a status, so it reports one that
is not 0.

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
| `node`, `web` | IEEE-754 doubles: exact to 2^53 | `2147483648` |
| `ocaml` | 63 | `2147483648` |

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

### A Float has no such caveat

`Float` is IEEE 754 binary64 on every target and in both builds of the
interpreter. Unlike `Int`, there is no width the language leaves open,
no host that carries more, and no row above to fill in: a double is a
double. So a Float program means one thing everywhere, including past
the range where an Int program stops meaning one.

Two things follow. There is no bound on a float *literal* the way there
is on an integer one — a literal past the range is an infinity, which is
IEEE's answer and the same everywhere. And a zero divisor is not
undefined: it answers `inf`, `-inf` or `nan`, where an Int zero divisor
still is (the row above).

What the targets *would* have disagreed about is how a double is
written, and every host writes one differently. Nothing is delegated:
each backend emits the same formatter, which is `docs/builtin.md`, "How
a Float is written". Two hosts needed more than that:

- **Python raises on a zero divisor** where IEEE answers, so a Float
  division goes through a helper there as an Int one already does.
- **JavaScript has one number type**, so no value can say whether Pyking
  called it an Int or a Float. That backend reads the checker's types at
  the print site instead — see [target_js.md](target_js.md), "Floats".

Everything else is expected to agree exactly, and the test suite enforces
it: `tests/test_cases.toml` lists which targets each program supports, and
every one of them is compared against the *same* `.out` file.
