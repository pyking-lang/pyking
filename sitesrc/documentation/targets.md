---
title: Compiler targets
description: What each Pyking compiler target writes, what it needs to run, what it supports, and how to implement a module in a target's own language.
sidebar:
  order: 6
  group: Tools
---

One Pyking program can be run by the interpreter or compiled for any of
seventeen targets: Python, JavaScript for node or a web page, C, Java
and OCaml. This page says what each target writes, what you need to run
the result, and what each one supports. For how Pyking's constructs map
to each language, see
[Pyking vs. other languages](/documentation/vs-other-languages/).

```sh
pyk prog.pyk                     # run with the interpreter
pyk compile -t node prog.pyk     # compile for node; ./prog runs it
pyk compile -t c --run prog.pyk  # compile for C, build it and run it
pyk prog.pyk -t java             # compile for Java and run it
```

[Command line](/documentation/command-line/#pyk-compile) has every flag
of `pyk compile`. The playground's Compiled code tab compiles for every
target too, and shows the code.

## Families, versions and aliases

A target names a **family** and a **version**: `c23` is C at the C23
standard, `java8` is Java at release 8. The version is the oldest host
the output is promised to run on. Each family also has a name without a
version, which means its default version.

| Family | Name | Versions | Default | The version is |
|---|---|---|---|---|
| Python | `python` | `python12`, `python14` | `python12` | the Python release, 3.12 or 3.14 |
| node | `node` | `node22`, `node24` | `node22` | the node release; `node22` writes ES2020, `node24` ES2024 |
| Web page | `web` | `web2020`, `web2024` | `web2020` | the ECMAScript edition the page's JavaScript is written in |
| Interpreted web page | `iweb` | `iweb2020`, `iweb2024` | `iweb2020` | the same, for the page that runs the interpreter |
| C | `c` | `c89`, `c99`, `c23` | `c99` | the C standard, with no garbage collector |
| C with GC | `c-gc` | `c23-gc` | `c23-gc` | C23, with the bdwgc garbage collector |
| Java | `java` | `java8`, `java17`, `java21` | `java21` | the Java release, as `javac --release` takes it |
| OCaml | `ocaml` | `ocaml4.14`, `ocaml5.5` | `ocaml4.14` | the OCaml release |

`pyk compile` with no `-t` uses `python`. The targets of one family
accept exactly the same programs; they differ only in how the output is
written. `--run` uses the family's own command (`python3`, `node`,
`ocamlopt`) whatever the version, since a newer host runs older output.

There is one more target, `pyking`, which compiles Pyking to Pyking:
it writes the program as the compiler understood it, with the types it
inferred and the loops it made of tail calls. It is for looking inside the compiler, not for running.

## All targets

`pyk compile prog.pyk` writes its files into `build/`, and puts the
executable beside it as `./prog`
([details](/documentation/command-line/#what-it-writes)).

| Target | Writes in `build/` | Run with | Supports |
|---|---|---|---|
| `python12`, `python14` | `prog.py` | `python3 prog.py` | everything |
| `node22`, `node24` | `prog.js`, `pyk-runtime.js`, `package.json` | `node prog.js` | everything |
| `web2020`, `web2024` | `prog.html`, `prog.js`, `pyk-runtime.js`, `io_external.js` | a browser, with the page served | everything |
| `iweb2020`, `iweb2024` | `prog.html`, `prog.pyk`, `pyking.js`, `io_external.js` | a browser, with the page served | everything |
| `c89`, `c99`, `c23` | `prog.c` | `cc -std=c99 -o prog prog.c -lm`, with the target's standard | no lists, recursive datatypes, escaping closures or polymorphic parameters |
| `c23-gc` | `prog.c` | `cc -std=c23 -DPYKING_GC -o prog prog.c -lgc -lm` | everything but polymorphic parameters |
| `java8`, `java17`, `java21` | `Prog.java`, `PykRuntime.java` | `javac --release 21 ...` (the target's release), then `java Prog` | everything |
| `ocaml4.14`, `ocaml5.5` | `prog.ml` | `ocamlopt -I +unix unix.cmxa -o prog prog.ml` | everything but a few shapes, [below](#ocaml) |
| `pyking` | `prog.pyk` | `pyk prog.pyk` | everything |
| the interpreter | nothing | `pyk prog.pyk` | everything |

"Everything" means every program the type checker accepts. Each module
the program imports becomes a file of its own beside the program's.

A program a target cannot compile is refused before any code is
written, with the position and the reason:

```sh
$ pyk compile -t c squares.pyk
'squares.pyk' 1:5-1:14 Unsupported by target 'c99': a list, which
  needs a heap that is freed: plain C has none, and c23-gc compiles it
```

## Choosing a target

- **To run a program while you write it**, use the interpreter,
  `pyk prog.pyk`. It needs nothing else, reports runtime errors with
  their place in the source, and is the reference for what a program
  means.
- **To hand someone a program they can run**, `python` or `node`: both
  take the whole language, and most machines have one of them.
- **To put a program on a web page**, `web`. Use `iweb` to run it in
  the browser with the interpreter instead of compiling it.
- **To see or teach how a program becomes C**, plain `c`: readable C
  with no runtime, for programs without lists. Use `c-gc` for the whole
  language in C.
- **For Java or OCaml**, `java` or `ocaml`: both take the whole
  language and their output is ordinary code in that language.

## Python

`python12` (alias `python`) and `python14`.

- **Writes** `prog.py`, and one `.py` per module. A module implemented
  in Python is copied beside it.
- **Needs** Python 3.12, or 3.14 for `python14`. The output imports
  nothing beyond Python's own standard library.
- **Supports** the whole language.
- **tinyweb**: the program serves its own page when it calls
  `web_init`, and prints its address.
- **Limits**: Python's own recursion limit, 1000 calls by default,
  applies to a recursion that is not a tail call.

## node

`node22` (alias `node`) and `node24`.

- **Writes** `prog.js` and `pyk-runtime.js`, which every module shares,
  and a `package.json` saying `"type": "module"`, which node needs to
  load the files as ES modules. A `package.json` that is already there
  is never written over.
- **Needs** node 22, or 24 for `node24`.
- **Supports** the whole language.
- **tinyweb**: the program serves its own page when it calls
  `web_init`, and prints its address.
- **Limits**: a JavaScript number is a double, so an `Int` is exact to
  2^53, not wrapped at 32 bits.

## Web page

`web2020` (alias `web`) and `web2024`.

- **Writes** `prog.html`, a page that loads the program, beside the same
  JavaScript files `node` writes, and `io_external.js`. It writes no
  `package.json`.
- **Needs** a browser, and the page must be served over HTTP: a browser
  will not load the program's modules from a `file://` address.
  `pyk compile -t web --run` and `pyk serve build/prog.html` both serve
  it and print the link.
- **Output**: what the program prints goes to the browser's console,
  and `debug` to the console as an error.
- **tinyweb**: the page itself is the tinyweb page. `web_init` does
  nothing.
- **Limits**: a page has no files, standard input, arguments or
  environment. The `fs` library is not supported, `io` writes but cannot
  read, and `sys` offers only `exit`; a function a page cannot provide
  says so on the console. A program that calls tinyweb's `sdelay`, which
  waits, is refused for `web`.

## Interpreted web page

`iweb2020` (alias `iweb`) and `iweb2024`.

`iweb` compiles nothing. The page ships the program's Pyking source and
the Pyking interpreter built to JavaScript, `pyking.js`, and runs the
program in the browser, the way the playground does.

- **Writes** `prog.html`, the program's `.pyk` files (an external
  module's declaration included), `pyking.js` and `io_external.js`.
- **Needs** a browser that supports ES2022, whichever edition the page
  was compiled for, and the page served over HTTP, as for `web`.
  `pyking.js` is about 5 MB.
- **Supports** whatever the interpreter does: the whole language.
- **tinyweb**: the page itself is the tinyweb page. `web_init` does
  nothing.
- **Limits**: as for `web`, the page has no files, standard input,
  arguments or environment. The program is interpreted, so it runs more
  slowly than compiled code.

## C

`c89`, `c99` (alias `c`) and `c23`.

Plain C is meant to be clean, readable C, for teaching: one `.c` file
per module, using only the C standard library, and no runtime of its
own. It allocates with `malloc` and never frees, and checks no array
index. The three standards differ only in how the same C is written:
comments, where declarations go, and how a `Bool` is spelled.

- **Writes** `prog.c`, and a `.c` and `.h` per module.
- **Needs** a C compiler that accepts the standard,
  `cc -std=c89`, `-std=c99` or `-std=c23`, and the maths library, `-lm`.
- **Refuses**, because each needs memory that is freed:
  - lists, list comprehensions, `for` over a list and list patterns
    (`for x in range(...)` is fine: it is a counting loop);
  - a datatype that holds itself, such as a tree;
  - a function value that captures, and is returned or stored.
- **Refuses**, on all four C targets: a polymorphic parameter, and a
  polymorphic function used as a value.
- **Libraries**: `list`, `map`, `mutmap` and `prelude` are not
  available, `sys` offers only `exit`, and functions that take or answer
  a list are left out of `array`, `dynarray`, `option`, `result`, `text`
  and `random`.
- **tinyweb**: the program serves its own page, as on Python. The
  drawing functions that take a list are not available.
- **Limits**: an `Int` is C's `int`, and an array index outside the
  array is not caught.

Each refusal on plain C says that `c-gc` compiles it.

## C with GC

`c23-gc` (alias `c-gc`).

`c23-gc` is C23 with the Boehm-Demers-Weiser garbage collector, bdwgc.
It frees memory nothing uses any more, and checks every index and array
size. It compiles what plain C refuses: lists, datatypes that hold
themselves and closures that outlive their function.

- **Writes** `prog.c`, as plain C does.
- **Needs** a C compiler that accepts `-std=c23`, and bdwgc:

  ```sh
  brew install bdw-gc          # macOS
  sudo apt install libgc-dev   # Debian, Ubuntu, WSL
  sudo dnf install gc-devel    # Fedora
  ```

  `--run` and the `Makefile` find it with `pkg-config bdw-gc`, or in
  the usual places. Where it is missing, `pyk` says so and how to
  install it. To build by hand:

  ```sh
  cc -std=c23 -DPYKING_GC -o prog prog.c $(pkg-config --cflags --libs bdw-gc) -lm
  ```

- **Supports** everything but a polymorphic parameter, and a
  polymorphic function used as a value.
- **Libraries**: all of them.
- **tinyweb**: the program serves its own page.

## Java

`java8`, `java17` and `java21` (alias `java`).

- **Writes** `Prog.java`, one class per module, and `PykRuntime.java`,
  the runtime every program shares. The file and its class are named in
  Java's style: `foo_bar.pyk` becomes `FooBar.java`, unless `-o` names
  it. Running `./prog` runs `java` on what is in `build/`.
- **Needs** a JDK: `javac --release 8`, `17` or `21`, and `java`. One
  JDK 21 builds all three.
- **Supports** the whole language. The three versions are three shapes
  of the same program: plain classes and casts for `java8`, records and
  `instanceof` patterns for `java17`, records and pattern `switch` for
  `java21`.
- **tinyweb**: the program serves its own page.
- **Limits**: an `Int` is Java's `int`, so it wraps at 32 bits.

## OCaml

`ocaml4.14` (alias `ocaml`) and `ocaml5.5`.

- **Writes** `prog.ml`, and an `.ml` and `.mli` per module. The code has
  no type annotations: OCaml infers them.
- **Needs** `ocamlopt`: OCaml 4.14 or later, or 5.5 or later for
  `ocaml5.5`. Every program is linked
  with OCaml's `unix` library, which comes with the compiler.
- **Supports** nearly every program the type checker accepts. It
  refuses a few shapes OCaml cannot be given, each with its position:
  - a `break` or `continue` inside an `if` that has statements after it
    in the loop's body;
  - a `def` that has to be moved to join the functions it calls, when a
    name it reads is bound again in between;
  - printing a value whose type is a type variable, in a function used
    at two types;
  - `|` around a `+` split of a String, or a list split from its end;
  - a literal or a nested list as an element after `..` in a list
    pattern.
- **tinyweb**: the program serves its own page.
- **Limits**: an `Int` is OCaml's 63-bit `int`.

## Where the targets differ

A program means the same on every target, except where Pyking leaves
the answer open:

- **Integer overflow.** An `Int` holds at least the signed 32-bit
  range; past it, the result is undefined and each target does its own
  arithmetic. Python never overflows, node is exact to 2^53, Java wraps
  at 32 bits, C's `int` overflows as C's does, and OCaml and the
  interpreter have 63 bits (the playground's interpreter has 32). An integer literal outside the
  32-bit range is an error everywhere.
- **Integer division or `%` by zero**, and **a list index out of
  range**: the interpreter reports a runtime error, and each compiled
  target does what its host does.
- **A `Float`** is a 64-bit IEEE double everywhere, and prints the same
  everywhere.
- **`debug`** writes to standard error, or the console on the web
  targets.
- **The exit status** is 0 when the program ends by itself, `code`
  after `sys.exit(code)`, and not 0 after a runtime error.

## Tail calls and `--release`

A function that calls itself in tail position is turned into a loop
before any target sees it, and so is a group of functions that
tail-call each other. Such a function runs in constant space on every
target and in the interpreter, however deep it goes:

```pyking
def count(n: Int, total: Int) -> Int:
    if n == 0:
        return total
    return count(n - 1, total + n)

print(count(100000, 0))
```

The OCaml target is compiled without this step, since OCaml eliminates
tail calls itself. A call that is not in tail position stays a call:
compiled to Python, `sum_to(n - 1) + n` stops after about 1000 calls,
Python's own limit, while the interpreter goes to 10,000 calls.
`--no-tail-call-opt` turns the step off.

`pyk compile --release` removes every call to `debug()` before the
program is compiled, on every target. On `iweb` the page removes them
before it runs the program. `print` is kept.

## External modules

A module can be written in a target's own language instead of in
Pyking: to reach something the standard library does not offer, or to
use existing code. The standard library does this itself, for `fs`,
`io`, `sys` and others.

Such a module has a declaration in Pyking, `NAME_external.pyk`, which
holds only signatures:

```pyking norun
# greet_external.pyk
public def shout(text: String) -> String
```

A program imports it like any other module:

```pyking norun
# main.pyk
import greet

print(greet.shout("hello"))
```

and each target finds its implementation beside the declaration, by a
name of its own:

| Target | Implementation | Example |
|---|---|---|
| `python` | `greet_external.py` | `def shout(text): ...` |
| `node` | `greet_external_node.js` | `export function shout(text) { ... }` |
| `web`, `iweb` | `greet_external_browser.js` | the same |
| `c`, `c-gc` | `greet_external.c` | `const char *greet_shout(const char *text) { ... }` |
| `java` | `GreetExternal.java` | `public static String shout(String text) { ... }` |
| `ocaml` | `greet_external.ml` | `let shout text = ...` |
| the interpreter | `greet_external.ml` | the same file as for `ocaml` |

```python
# greet_external.py
def shout(text):
    return text.upper() + "!"
```

```c
/* greet_external.c */
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

const char *greet_shout(const char *text) {
  size_t n = strlen(text);
  char *out = malloc(n + 2);
  for (size_t i = 0; i < n; i++) out[i] = (char) toupper((unsigned char) text[i]);
  out[n] = '!';
  out[n + 1] = '\0';
  return out;
}
```

The compiler reads the declaration and never the implementation: it
copies the right file into `build/` beside the program and lets the
target's own tools compile it. A target with no implementation file is
refused, naming the file it looked for:

```sh
$ pyk main.pyk -t node
'greet_external.pyk' 1:0-1:0 Module error: the external module 'greet'
  has no implementation for target 'node22': there is no file
  'greet_external_node.js'
```

A few things to know when writing one:

- **Names.** In C, a function is `MODULE_NAME`, here `greet_shout`. In
  Java the class is the module's name in Java's style, `GreetExternal`.
  In OCaml, write the standard library's modules in full, such as
  `Stdlib.String`, since a Pyking module of the same name would hide
  them.
- **What crosses.** `Int`, `Float`, `String`, `Char`, `Bool` and `()`
  cross on every target, each as the host's own type. Tuples and lists
  cross on some targets and not others; plain C takes no list.
- **The interpreter** runs the OCaml implementation, compiled to a
  plugin with `ocamlopt` the first time it is needed and kept in
  `~/.cache/pyking`. That needs the same OCaml version `pyk` was built
  with. `pyk plugins DIR` builds the plugins of a directory of libraries
  ahead of time; see
  [Command line](/documentation/command-line/#pyk-plugins).
- **A module in two halves.** `greet.pyk` beside `greet_external.pyk`
  is one module: the Pyking half can use what the declaration offers,
  and add functions of its own on top.

See [Modules](/documentation/language/modules/) for imports and what a
module exports.
