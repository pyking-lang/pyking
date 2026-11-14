---
title: Pyking vs. other languages
description: Pyking compared with Python, JavaScript, C, Java and OCaml -- syntax, semantics, and what the compiler writes for each.
sidebar:
  order: 9
  group: Language
---

Pyking has Python's syntax and ML's semantics. Programs are indented,
use `def`, `if`, `for`, `while` and `match`, and look like Python.
But a name bound with `=` never changes, every block is a scope,
types are static and inferred, and data is built from datatypes and
taken apart with an exhaustive `match`. A `use` line at the top of a
module adds more: `use mutation` adds variables, arrays and mutable
structs, `use pointers` adds C-style pointers, and `use objects` adds
Java-style classes and interfaces.

This page is for readers who know one of the languages Pyking compiles
to. Each part says what carries over, what does not, and what the
compiler writes for that language. The full list of targets is on
[Compiler targets](/documentation/targets/), and the language itself
is in the [language reference](/documentation/language/).

## Across languages

| | Pyking | Python | JavaScript | C | Java | OCaml |
|---|---|---|---|---|---|---|
| Typing | static, inferred; annotations optional | dynamic; hints are not checked | dynamic | static, declared | static, declared (`var` for locals) | static, inferred |
| Bindings by default | immutable; `var` under `use mutation` | mutable | `const` or `let`, your choice | mutable | mutable (`final` to fix) | immutable; `ref` for a cell |
| Block scope | every block | function only | `let`/`const`: block | block | block | `let ... in` |
| Integer | `Int`, at least 32 bits; overflow undefined | arbitrary size | double, exact to 2^53 | `int`, 32 bits in practice; overflow undefined | `int`, 32 bits, wraps | `int`, 63 bits, wraps |
| `7 / 2` on integers | `3`, truncates toward zero | `3.5` (`//` floors) | `3.5` | `3`, truncates | `3`, truncates | `3`, truncates |
| No value | `Option`: `None`, `Some(x)` | `None` | `null`, `undefined` | `NULL` | `null` | `option` |
| Errors | `Option`, `Result`, `panic`; no exceptions | exceptions | exceptions | return codes | exceptions | exceptions, `result` |
| Sum types | `datatype` | classes by hand | objects by hand | tagged unions by hand | sealed interfaces and records | variants |
| Pattern matching | `match`, checked exhaustive | `match`, not checked | none (`switch` on values) | `switch` on integers | pattern `switch` (Java 21) | `match`, exhaustiveness warned |
| Closures | yes | yes | yes | no | lambdas (captures effectively final) | yes |
| Tail calls | self and mutual tail calls run in constant stack, on every target | no | not in node | up to the C compiler | no | yes |
| Objects | `use objects`: classes, interfaces, one parent | classes, many parents | prototypes and classes | none | classes, interfaces, one parent | objects and classes, structural |
| Generics | type variables, inferred | hints only | none | none | generics | type variables, inferred |
| Memory | managed | managed | managed | `malloc` and `free` | managed | managed |

## Seeing the generated code yourself

Every example on this page can be compiled for any target.

- In the [playground](/playground/), open the **Compiled code** tab,
  pick a target from the list and press **Compile**. The generated code
  appears above, and **Run** builds and runs it.
- On the command line, `pyk compile -t <target> --stdout prog.pyk`
  prints the generated code instead of writing it to `build/`, and
  `--run` builds and runs it with the target's own tools. See
  [Command line](/documentation/command-line/).

```sh
pyk compile -t java --stdout prog.pyk     # print the Java
pyk compile -t ocaml --run prog.pyk       # build with ocamlopt and run
pyk prog.pyk                              # run it with the interpreter
```

The generated-code excerpts below come from the compiler, and the site's
tests check that it still writes them.

## Compared to Python

Targets: `python12` (also called `python`, the default) and `python14`.

### Syntax

Much is the same as in Python: indentation, `def`, `if`, `for`,
`while`, `return`, list comprehensions, `match`/`case`, slicing
(`xs[1:3]`), `import m`, `import m as n`, `from m import a as b`, `#`
comments, and most operators, including `and`, `or` and `not`.

What differs:

| Pyking | Python |
|---|---|
| `true`, `false` | `True`, `False` |
| `else if n == 0:` | `elif n == 0:` |
| `2 ^ 10` | `2 ** 10` |
| `5 xor 3` | `5 ^ 3` |
| `lam x. x + 1` | `lambda x: x + 1` |
| `if n > 0 then "pos" else "neg"` | `"pos" if n > 0 else "neg"` |
| `'a'` is a Char; strings use `"..."` only | `'a'` and `"a"` are both strings |
| `var n = 0`, then `n := n + 1` or `n += 1` | `n = 0`, then `n = n + 1` or `n += 1` |
| `0 < x and x < 10` | `0 < x < 10` |
| `case [first, ..rest]:` | `case [first, *rest]:` |
| `"n = " + string(n)` | `f"n = {n}"` |
| `public def area(s: Shape) -> Float:` | every top-level name is exported |
| `datatype`, `struct`, `let`, `loop`, `use` | no counterpart |

Some Python features are not in Pyking at all:

| Python | In Pyking |
|---|---|
| `try`, `except`, `raise` | return an `Option` or a `Result`; `panic("...")` stops the program |
| `with` | none |
| decorators (`@cache`) | none; call the wrapping function yourself |
| `*args`, `**kwargs` | a list parameter; default parameters and named arguments exist |
| `yield`, generators | build a list, or use `loop` |
| `async`, `await` | none |
| `global`, `nonlocal` | a `var` can be written with `:=` from any `def` inside its scope |
| f-strings | `+` and `string(x)` |
| `{"a": 1}` dict literals | `map([("a", 1)])`, or `mutmap()` under `use mutation` |
| `{1, 2}` set literals, sets | none; a list or a map |
| `x in xs` | `list.contains(x, xs)` |
| `None` as "nothing" for any type | `None` is a value of `Option(a)` |

### Semantics

The same as Python: values and evaluation order (left to right), lists,
strings, closures and first-class functions, recursion, and, under
`use objects`, classes whose objects are shared by reference.

Different:

- **Types are static and inferred.** `"n = " + 5` and `1 + 2.0` are
  errors before the program runs, not at the line that reaches them.
  `if xs:` is an error too: a condition must be a `Bool`.
- **Every block is a scope.** A name bound inside an `if` is gone after
  it:

  ```pyking error
  n = 3
  if n > 0:
      sign = "positive"
  print(sign)
  ```

  Bind the `if` itself instead:

  ```pyking
  n = 3
  sign = if n > 0 then "positive" else "not positive"
  print(sign)
  ```

- **`=` never changes a variable.** It makes a new binding, and a
  function written before it keeps the old one:

  ```pyking
  x = 1
  def show(): x
  x = 2
  print(x, show())
  ```

  This prints `2 1`. Python would print `2 2`.
- **`Int` division truncates, and `Int` and `Float` never mix.** `-7 / 2`
  is `-3` and `-7 % 2` is `-1`, as in C. Python gives `-4` and `1`.
  `float(n)` and `int(x)` convert:

  ```pyking
  print(-7 / 2, -7 % 2, 7.0 / 2.0, float(7) / 2.0)
  ```

- **No exceptions and no `None` for every type.** A function that may
  have no answer returns an `Option`:

  ```pyking
  def find(xs: [Int], target: Int) -> Option(Int):
      loop i = 0 for x in xs:
          if x == target:
              return Some(i)
          i + 1
      None

  print(find([4, 5, 6], 5), find([4, 5, 6], 9))
  ```

- **`match` must cover every value.** A `match` that misses a case is
  refused, naming the value it misses. Python's `match` does nothing.
- **A negative index is an error.** `xs[-1]` stops the program in the
  interpreter. On the Python target it is Python's own behaviour, so
  it counts from the end there.
- **Nothing is exported without `public`**, and a public function
  annotates all its parameters and its result.
- **`Map` never changes**; a change returns a new map. `MutMap`, under
  `use mutation`, is the one that is written in place, like a `dict`.

### How Pyking compiles to it

| Pyking | Python |
|---|---|
| `=`, `var`, `:=` | plain assignment |
| a block binding that shadows an outer name | renamed: `x`, `x2`, `x3` |
| a `var` written from inside a `def` | `global x` or `nonlocal x` |
| `true`, `false` | `True`, `False`, printed as `true`, `false` by a helper |
| a Char `'z'` | `__PykChar('z')`, a one-character `str` subclass |
| `a / b` and `a % b` on Ints | `__pyk_div(a, b)` and `__pyk_mod(a, b)` |
| `lam x. x + 1` | `lambda x: x + 1` |
| `if c then a else b` | `a if c else b` |
| a datatype | a `@dataclass(frozen=True, slots=True)` per constructor, and a `type` alias for the union |
| `match` | Python's `match`, with class patterns |
| a function that calls itself in tail position | a `while True:` loop |
| `loop`, `break`, `continue` | `while True:`, `break`, `continue` |
| a value in tail position | `return` |
| a tuple, a list | a tuple, a list |
| `Some(3)`, `None` | `Some(3)`, `None_` from the compiled `option` module |

The same small program is compiled in every part of this page. It has
one datatype, one `match` and one `var`, which a function writes:

```pyking
use mutation

datatype Shape:
    Circle(r: Int)
    Rect(w: Int, h: Int)

def area(s: Shape) -> Int:
    match s:
        case Circle(r): 3 * r * r
        case Rect(w, h): w * h

var total = 0

def add(s: Shape):
    total := total + area(s)

for s in [Circle(1), Rect(2, 3)]:
    add(s)
print(total, total / 4)
```

```python excerpt target=python
from dataclasses import dataclass
# ...
def __pyk_div(a, b):
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q
# ...
@dataclass(frozen=True, slots=True)
class Circle:
    r: int

@dataclass(frozen=True, slots=True)
class Rect:
    w: int
    h: int

type Shape = Circle | Rect

def area(s):
    match s:
        case Circle(r):
            return 3 * r * r
        case Rect(w, h):
            return w * h

total = 0

def add(s):
    global total
    total = total + area(s)
    return ()

for s in [Circle(1), Rect(2, 3)]:
    add(s)
print(total, __pyk_div(total, 4))
```

### Targets and limits

- **What it takes:** everything. Python is the reference target.
- **Running it:** `python3 prog.py`. The output imports little:
  `dataclasses` where it declares a datatype, and the compiled modules
  of the Pyking libraries it uses.
- **3.12 or 3.14:** `type` aliases and class type parameters need 3.12.
  The two versions differ in one place: 3.12 quotes a field whose type
  is not declared yet, such as a datatype holding itself, and 3.14
  writes it bare.

  ```pyking
  datatype Tree(a):
      Leaf
      Node(left: Tree(a), value: a, right: Tree(a))

  def size(t):
      match t:
          case Leaf: 0
          case Node(l, _, r): size(l) + 1 + size(r)

  print(size(Node(Leaf, 7, Node(Leaf, 8, Leaf))))
  ```

  ```python excerpt target=python12
  @dataclass(frozen=True, slots=True)
  class Node[a]:
      left: 'Tree[a]'
      value: a
      right: 'Tree[a]'

  type Tree[a] = Leaf[a] | Node[a]
  ```

  ```python excerpt target=python14
  @dataclass(frozen=True, slots=True)
  class Node[a]:
      left: Tree[a]
      value: a
      right: Tree[a]
  ```

- **Where the output differs:** Python's integers never overflow, so
  `2147483647 + 1` is `2147483648`. Python's recursion limit is 1,000
  calls by default, so a deep recursion that is not a tail call can
  fail compiled and run in the interpreter. A negative index counts
  from the end.

## Compared to JavaScript

Targets: `node22` (also `node`) and `node24` write a script for node;
`web2020` (also `web`) and `web2024` write an HTML page and its
JavaScript; `iweb2020` (also `iweb`) and `iweb2024` write a page that
runs the Pyking interpreter in the browser.

### Syntax

| Pyking | JavaScript |
|---|---|
| blocks by indentation | blocks in `{ }` |
| `x = 5` | `const x = 5;` |
| `var n = 0`, then `n := n + 1` | `let n = 0;`, then `n = n + 1;` |
| `def add(a, b): a + b` | `function add(a, b) { return a + b; }` |
| `lam x. x + 1` | `x => x + 1` |
| `if n > 0 then "pos" else "neg"` | `n > 0 ? "pos" : "neg"` |
| `for x in xs:` | `for (const x of xs) { ... }` |
| `for i in range(10):` | `for (let i = 0; i < 10; i++) { ... }` |
| `match s:` with `case Circle(r):` | `switch` on a tag field |
| `a == b`, `a != b` (structural) | `a === b`, `a !== b` |
| `and`, `or`, `not`, or `&&`, `\|\|`, `!` | `&&`, `\|\|`, `!` |
| `"n = " + string(n)` | `` `n = ${n}` `` |
| `print(x)` | `console.log(x)` |
| `public def f(x: Int) -> Int:` | `export function f(x) { ... }` |
| `from m import f` | `import { f } from "./m.js";` |
| `# comment` | `// comment` |

### Semantics

The same as JavaScript: closures and first-class functions, objects
shared by reference (under `use objects`, and mutable structs), and a
single thread. A [tinyweb](/libraries/tinyweb/) program's callbacks run
one at a time, as on the event loop.

Different:

- **Types are static.** A misspelled field or a wrong argument is found
  before the program runs.
- **`Int` and `Float` are separate types**, and `/` on two Ints
  truncates. `Char` is a type of its own, not a string of length one.
- **Nothing converts implicitly.** `"n = " + 5` is an error; write
  `"n = " + string(5)`:

  ```pyking error
  print("n = " + 5)
  ```

- **`==` compares structure.** Two lists, tuples or datatype values are
  equal when their parts are. There is no `===`, and no reference
  equality except `same(a, b)` for mutable values.

  ```pyking
  print(7 / 2, -7 / 2, 7.0 / 2.0)
  print([1, 2] + [3], [1, 2] == [1, 2], (1, "a") == (1, "a"))
  print("n = " + string(5))
  ```

- **No `undefined` and no `null`.** A missing value is an `Option`. An
  unbound name is a compile-time error.
- **Every block is a scope, and nothing is hoisted.** A binding is
  visible from where it is written to the end of its block. Functions
  in a block can call each other in any order.

### How Pyking compiles to it

| Pyking | JavaScript |
|---|---|
| `x = 1` | `const x = 1;` |
| `var n = 0`, `n := n + k` | `let n = 0;`, `n = n + k;` |
| a block binding that shadows an outer name | `const x2` |
| a tuple `(1, "one")` | an array `[1, 'one']` |
| a list | an array marked by `pykList([...])` |
| a datatype value | `pykData('Circle', [v0], ['r'])`, an object with its tag and fields |
| `match` | an `if`/`else` chain on `pykTag` |
| `a / b` on Ints | `Math.trunc(a / b)` |
| a Char `'z'` | its code point, `122` |
| `==` on lists, tuples, datatypes | `pykEqual(a, b)` |
| `==` on numbers, strings, Bools | `===` |
| `+` on Strings or lists | `pykConcat(a, b)` |
| `lam x. x + 1` | `(x) => x + 1` |
| `if c then a else b` | `c ? a : b` |
| a function that calls itself in tail position | a `while (true)` loop |
| a list comprehension | `flatMap` |
| `print` | `print` from `pyk-runtime.js` |

The same program as in the Python part:

```pyking
use mutation

datatype Shape:
    Circle(r: Int)
    Rect(w: Int, h: Int)

def area(s: Shape) -> Int:
    match s:
        case Circle(r): 3 * r * r
        case Rect(w, h): w * h

var total = 0

def add(s: Shape):
    total := total + area(s)

for s in [Circle(1), Rect(2, 3)]:
    add(s)
print(total, total / 4)
```

```javascript excerpt target=node
import { print } from './pyk-runtime.js';
// ...
function Circle(v0) {
  return pykData('Circle', [v0], ['r']);
}

function Rect(v0, v1) {
  return pykData('Rect', [v0, v1], ['w', 'h']);
}

function area(s) {
  const __subject = s;
  if (__subject.pykTag === 'Circle') {
    const r = __subject.pykValues[0];
    return 3 * r * r;
  } else if (__subject.pykTag === 'Rect') {
    const w = __subject.pykValues[0];
    const h = __subject.pykValues[1];
    return w * h;
  }
}

let total = 0;

function add(s) {
  total = total + area(s);
}

for (const s of pykList([Circle(1), Rect(2, 3)])) {
  add(s);
}
print(total, Math.trunc(total / 4));
```

### Targets and limits

- **What it takes:** everything the type checker accepts, on all six
  targets.
- **node:** `foo.js`, the shared `pyk-runtime.js` and a `package.json`
  that marks the files as ES modules. Run with `node foo.js`.
- **web:** `foo.html` and the same `.js` files. `print` writes to the
  browser console. A page must be served over HTTP: `pyk compile -t web
  --run` starts `pyk serve` and prints the page's address. tinyweb
  programs draw on the page.
- **iweb:** the page ships the `.pyk` sources and the compiler built to
  JavaScript, and interprets the program in the browser. It compiles
  nothing.
- **ES2020 or ES2024:** `node22`, `web2020` and `iweb2020` write ES2020,
  and the others ES2024. A program's own modules are the same in both;
  only a page's loader differs.
- **Where the output differs:** a JavaScript number is a double, so an
  `Int` past the signed 32-bit range gets what double arithmetic gives:
  `2147483647 + 1` is `2147483648`, exact up to 2^53. An index outside
  a list is `undefined`, not an error, and `1 / 0` is `Infinity`.

## Compared to C

Targets: `c89`, `c99` (also `c`) and `c23` are plain C; `c23-gc` (also
`c-gc`) is C23 with the Boehm–Demers–Weiser garbage collector.

### Syntax

| Pyking | C |
|---|---|
| no braces, no semicolons | `{ }` and `;` |
| `x = 5` | `const int x = 5;` |
| `var n = 0`, then `n := n + 1` or `n += 1` | `int n = 0;`, then `n = n + 1;` or `n += 1;` |
| `def add(a: Int, b: Int) -> Int: a + b` | `int add(int a, int b) { return a + b; }` |
| `def add(a, b): a + b` (types inferred) | every type written out |
| `for i in range(10):` | `for (int i = 0; i < 10; i++) { ... }` |
| `p = &x`, `*p := 42` (`use mutation, pointers`) | `int *p = &x; *p = 42;` |
| `mutable struct Point(x: Int, y: Int)` | `struct Point { int x; int y; };` |
| `datatype Shape: Circle(r: Int), Rect(w: Int, h: Int)` | a `struct` with a tag and a `union` |
| `match s:` with `case Circle(r):` | `switch (s.tag)` |
| `"a" + b` | a buffer and `strcat` |
| `print(n)` | `printf("%d\n", n);` |
| `import math` | `#include <math.h>` |

### Semantics

The same as C: `Int` arithmetic that truncates on division, mutable
structs passed as references, arrays that know their length, and
pointers to variables, with `&` and `*` written as in C.

Different:

- **Memory is managed.** The program never frees anything, and nothing
  it holds is freed under it.
- **No undefined behaviour from memory.** In Pyking an index outside an
  array or a list is a runtime error with a message (plain C output
  does not check it; `c23-gc` does). There is no null pointer, and a
  pointer has no arithmetic.
- **Strings are values.** `+` joins two Strings into a new one, `s[i]`
  is a `Char` (a Unicode code point), and `len(s)` counts code points.
- **Functions are values, and closures exist.** A function can return a
  function that remembers its arguments, and a function without type
  annotations works on any type that fits:

  ```pyking
  def adder(n: Int) -> (Int) -> Int:
      lam x. x + n

  def first(pair):
      (a, _) = pair
      a

  add3 = adder(3)
  greeting = "Hello, " + "world"
  print(add3(4), first((1, "x")), first(("y", 2)))
  print(greeting, greeting[0], len(greeting))
  ```

- **Modules, not headers.** A file is a module; it exports what it
  marks `public`, and `import` reads it. There is no preprocessor.

### How Pyking compiles to it

| Pyking | C |
|---|---|
| `Int`, `Char`, `Float`, `Bool`, `String` | `int`, `int` (the code point), `double`, `bool` (`int` in C89), `const char *` |
| a tuple `(Int, String)` | a struct, `pyk_t_Tis_`, with fields `a0` and `a1` |
| a datatype | a struct with a `tag` and a union of the constructors' fields, passed by value |
| `match` | an `if`/`else` chain on the tag |
| a list `[Int]` (c23-gc) | `pyk_l_Li_ *`, a pointer to the first cons cell; `NULL` for `[]` |
| a function value `(Int) -> Int` | a struct `pyk_c_Fi_i_` of a function and an environment, called as `f.fn(f.env, x)` |
| a nested `def` or a lambda | a C function taking what it captures |
| a polymorphic function | one C function per type it is used at |
| a top-level binding | a `static` variable at file scope, set in `main` |
| `Array(Int)` | a struct of `len` and `items` |
| a `mutable struct` | a pointer to a struct |
| `&x`, `*p` | C's own `&x`, `*p` |
| `+` on Strings | `pyk_concat(a, b)`, which allocates |
| `print` | `printf` |
| a function that calls itself in tail position | a `while (1)` loop |
| several modules | one `.c` file and a header per module |

Plain C refuses the program the other parts compile, because it has a
list:

```pyking
use mutation

datatype Shape:
    Circle(r: Int)
    Rect(w: Int, h: Int)

def area(s: Shape) -> Int:
    match s:
        case Circle(r): 3 * r * r
        case Rect(w, h): w * h

var total = 0

def add(s: Shape):
    total := total + area(s)

for s in [Circle(1), Rect(2, 3)]:
    add(s)
print(total, total / 4)
```

```text
$ pyk compile -t c example.pyk
'example.pyk' 17:0-17:32 Unsupported by target 'c99': a `for` loop
  over a list, which needs a heap that is freed: plain C has none, and
  c23-gc compiles it
```

`c23-gc` compiles it. The list becomes cons cells from the collector:

```c excerpt target=c-gc
#include <gc.h>
// ...
typedef struct pyk_d_Dexample_Shape__ {
    int tag;
    union {
        struct {
            int f0;
        } Circle;
        struct {
            int f0;
            int f1;
        } Rect;
    } u;
} pyk_d_Dexample_Shape__;
// ...
static int total;
// ...
int area(pyk_d_Dexample_Shape__ s)
{
    pyk_d_Dexample_Shape__ pyk_s1 = s;
    if (pyk_s1.tag == 0) {
        {
            int r = pyk_s1.u.Circle.f0;
            return 3 * r * r;
        }
    } else {
        {
            int w = pyk_s1.u.Rect.f0;
            int h = pyk_s1.u.Rect.f1;
            return w * h;
        }
    }
}

void add(pyk_d_Dexample_Shape__ s)
{
    total = total + area(s);
}

int main(void)
{
    GC_INIT();
    // ...
            s = s_at->head;
            add(s);
        }
        printf("%d %d\n", total, total / 4);
    }
```

### Targets and limits

- **Plain C** (`c89`, `c99`, `c23`) allocates with `malloc` and never
  frees, and checks no index. It refuses what needs a heap that is
  freed: lists, a datatype holding itself, and a closure that outlives
  the function that made it. Each refusal names `c23-gc`. The three
  versions write the same program; they differ in comments, where
  declarations go and how Bools are spelled.
- **c23-gc** takes everything else, and checks every index. It needs
  bdwgc: `apt install libgc-dev` on Debian and Ubuntu, `dnf install
  gc-devel` on Fedora, `brew install bdw-gc` on macOS. `pyk compile -t
  c-gc --run` finds it.
- **No C target** compiles a polymorphic *parameter*
  (`all a. (a) -> a`): one C function cannot serve every type.
- **Running it:** `cc -std=c99 foo.c -lm && ./a.out` for plain C;
  `cc -std=c23 -DPYKING_GC foo.c -lgc -lm` for c23-gc.
- **Where the output differs:** `int` is 32 bits on every common C
  compiler, and overflow is undefined behaviour; in practice
  `2147483647 + 1` is `-2147483648`. Division by zero is undefined too.
  A file using `Float` turns off floating-point contraction, so `a * b +
  c` rounds as on the other targets.

## Compared to Java

Targets: `java8`, `java17` and `java21` (also `java`).

### Syntax

| Pyking | Java |
|---|---|
| statements at the top level | a class with `public static void main` |
| `x = 5` | `final int x = 5;` |
| `var n = 0`, then `n := n + 1` | `int n = 0;`, then `n = n + 1;` |
| `def add(a: Int, b: Int) -> Int: a + b` | `static int add(int a, int b) { return a + b; }` |
| `def first(xs: [a]) -> Option(a):` | `static <A> Optional<A> first(List<A> xs)` |
| `Rect(2.0, 3.0)` | `new Rect(2.0, 3.0)` |
| `class Rect(width: Float, height: Float) implements Shape:` | `class Rect implements Shape { ... }` with fields and a constructor |
| `def area(self) -> Float:` | `double area() { ... }` |
| `override def area(self) -> Float:` | `@Override double area() { ... }` |
| `self.width` (always written) | `this.width` or `width` |
| `lam x. x + 1` | `x -> x + 1` |
| `if n > 0 then "pos" else "neg"` | `n > 0 ? "pos" : "neg"` |
| `match s:` with `case Circle(r):` | `switch (s) { case Circle(var r) -> ... }` |
| `[1, 2, 3]`, `xs: [Int]` | `List.of(1, 2, 3)`, `List<Integer> xs` |
| `for x in xs:` | `for (int x : xs) { ... }` |

### Semantics

The same as Java, under `use objects`: objects shared by reference,
one parent class and any number of interfaces, dynamic dispatch,
abstract classes, `override`, and garbage collection. Type variables
work as generics do.

```pyking
use objects

class Animal(name: String):
    def speak(self) -> String:
        self.name + " makes a sound"

class Dog(dog_name: String) extends Animal(dog_name):
    override def speak(self) -> String:
        self.name + " barks"

pets: [Animal] = [Animal("Cat"), Dog("Rex")]
for p in pets:
    print(p.speak())
```

Different:

- **Functions and data live outside classes.** A program is a file of
  statements and `def`s; classes are only needed for objects.
- **Immutable by default.** `=` is like `final`; a variable needs `var`
  and `use mutation`.
- **Datatypes and an exhaustive `match`**, like a sealed interface of
  records with a pattern `switch`, but the compiler always checks that
  every case is covered.
- **No `null` and no exceptions.** A missing value is an `Option`, an
  error a `Result`, and `panic` stops the program.
- **`==` compares structure**, also on strings, lists and datatypes. On
  a class it calls the class's `eq` method, and is refused if there is
  none. `same(a, b)` asks whether two names hold one object.

  ```pyking
  struct Point(x: Int, y: Int)
  a = "ab" + "c"
  print(a == "abc", Point(1, 2) == Point(1, 2), [1, 2] == [1, 2])
  ```

### How Pyking compiles to it

| Pyking | Java |
|---|---|
| a program `foo_bar.pyk` | `public final class FooBar`, in `FooBar.java` |
| `Int`, `Float`, `Bool` | `int`, `double`, `boolean` (`Integer` and so on as type arguments) |
| `String`, `Char` | `String`, `PykRuntime.PykChar` |
| `[T]` | `java.util.List<T>`; a literal is `java.util.Arrays.asList(...)` |
| a tuple `(A, B)` | `PykRuntime.T2<A, B>` |
| `(A) -> R` | `java.util.function.Function<A, R>` |
| a type variable `a` | a type parameter `A` |
| a datatype | a sealed interface and a record per constructor (java17, java21); an abstract class and a final class per constructor (java8) |
| `match` | a pattern `switch` (java21); `instanceof` tests (java8, java17) |
| a top-level binding | a `private static` field, set in `main` |
| a nested `def` | a static method taking what it captures |
| a `var` a closure writes | a one-element array |
| `==` on lists, tuples, datatypes | `PykRuntime.equal(a, b)` |
| a function that calls itself in tail position | a `while (true)` loop |
| a class | a nested Java class |

The same program as in the other parts:

```pyking
use mutation

datatype Shape:
    Circle(r: Int)
    Rect(w: Int, h: Int)

def area(s: Shape) -> Int:
    match s:
        case Circle(r): 3 * r * r
        case Rect(w, h): w * h

var total = 0

def add(s: Shape):
    total := total + area(s)

for s in [Circle(1), Rect(2, 3)]:
    add(s)
print(total, total / 4)
```

java21 writes a sealed interface, records and a pattern `switch`:

```java excerpt target=java21
public final class Example {

    private sealed interface Shape extends PykRuntime.Data permits Circle, Rect {
    }

    private static Shape Circle(final int r) {
        return new Circle(r);
    }

    private record Circle(int r) implements Shape {
    // ...
    private static int total;

    private static int area(final Shape s) {
        final Shape s$1 = s;
        switch (s$1) {
            case Circle(var t$2) -> {
                final int r = t$2;
                return 3 * r * r;
            }
            case Rect(var t$3, var t$4) -> {
                final int w = t$3;
                final int h = t$4;
                return w * h;
            }
            // ...
        }
    }

    private static void add(final Shape s) {
        total = total + area(s);
    }

    public static void main(String[] args) {
        total = 0;
        for (final Shape s : java.util.Arrays.asList(Circle(1), Rect(2, 3))) {
            add(s);
        }
        System.out.println(String.valueOf(total) + " " + String.valueOf(total / 4));
    }
}
```

java17 tests with `instanceof` and reads the records' accessors:

```java excerpt target=java17
    private static int area(final Shape s) {
        final Shape s$1 = s;
        if (s$1 instanceof Circle t$2) {
            final int r = t$2.r();
            return 3 * r * r;
        } else {
            final int w = ((Rect) s$1).w();
            final int h = ((Rect) s$1).h();
            return w * h;
        }
    }
```

java8 has no records, so each constructor is a class of its own, and
`match` tests the class and casts:

```java excerpt target=java8
    private static abstract class Shape implements PykRuntime.Data {
    }
    // ...
    private static final class Circle extends Shape {
        public final int r;
    // ...
    private static int area(final Shape s) {
        final Shape s$1 = s;
        if (s$1 instanceof Circle) {
            final int r = ((Circle) s$1).r;
            return 3 * r * r;
        } else {
            final int w = ((Rect) s$1).w;
            final int h = ((Rect) s$1).h;
            return w * h;
        }
    }
```

### Targets and limits

- **What it takes:** everything the type checker accepts, on all three
  versions.
- **Running it:** `javac --release 21 Foo.java PykRuntime.java && java
  Foo`. `PykRuntime.java` is written beside every program: tuples,
  function interfaces past two parameters, and the printing helpers.
- **8, 17 or 21:** the same program in three shapes. java8 writes plain
  classes and casts, java17 records and `instanceof` patterns, java21
  records and a pattern `switch`.
- **Where the output differs:** `int` is 32 bits and wraps, so
  `2147483647 + 1` is `-2147483648`. Division by zero throws an
  `ArithmeticException`.

## Compared to OCaml

Targets: `ocaml4.14` (also `ocaml`) and `ocaml5.5`.

### Syntax

| Pyking | OCaml |
|---|---|
| `x = 5` on its own line, then the rest of the block | `let x = 5 in ...` |
| `let x = 5 in x + 1` | `let x = 5 in x + 1` |
| `def add(a, b): a + b` | `let add a b = a + b` |
| a `def` that calls itself | `let rec` |
| `lam x. x + 1` | `fun x -> x + 1` |
| `match o:`, `case Some(x): x`, `case None: 0` | `match o with Some x -> x \| None -> 0` |
| `datatype Shape: Circle(Int), Rect(Int, Int)` | `type shape = Circle of int \| Rect of int * int` |
| `Some(3)` | `Some 3` |
| `def ident(x: a) -> a: x` | `let ident (x : 'a) : 'a = x` |
| `var n = 0`, `n := n + 1`, `n` | `let n = ref 0`, `n := !n + 1`, `!n` |
| `[1, 2, 3]`, `case [x, ..rest]:` | `[1; 2; 3]`, `x :: rest` |
| `"a" + "b"`, `[1] + [2]` | `"a" ^ "b"`, `[1] @ [2]` |
| `x == y`, `x != y` | `x = y`, `x <> y` |
| `7 % 2` | `7 mod 2` |
| `1.5 + 2.0` | `1.5 +. 2.0` |
| `print(n)` | `print_endline (string_of_int n)` |

### Semantics

Almost all of the core is the same as OCaml: type inference, immutable
bindings, variants and an exhaustive `match`, `Option` and `Result`,
closures, guaranteed tail calls, and `var`/`:=` as a `ref` cell.

Different:

- **Statements, not expressions everywhere.** A block is a sequence of
  statements, and its value is its last one. `if` and `match` give a
  value where one is bound or returned.
- **`return`, `break` and `continue`.** A function can stop early, and
  so can a loop:

  ```pyking
  def find(xs: [Int], target: Int) -> Option(Int):
      loop i = 0 for x in xs:
          if x == target:
              return Some(i)
          i + 1
      None

  print(find([4, 5, 6], 5), find([4, 5, 6], 9))
  ```

- **Overloading and implicits.** Two `def`s may share a name, told apart
  by their argument types. OCaml has neither.

  ```pyking
  def int::twice(x: Int) -> Int: x * 2
  def string::twice(x: String) -> String: x + x

  print(twice(21), twice("ab"))
  ```

- **One `+` for Ints, Floats, Strings and lists**, and one `==` and
  `print` for every type that has them. OCaml has `+.`, `^`, `@` and no
  generic printer.
- **Classes are Java-style**, with nominal types, single inheritance and
  explicit `override`. They are not OCaml's structural objects.
- **No functors.** Modules are files, with `public` names.

### How Pyking compiles to it

The OCaml target runs Pyking's type checker and reads the types back,
so the output has no type annotations: OCaml infers them again.

| Pyking | OCaml |
|---|---|
| a binding in a block | `let ... in`; nothing is renamed |
| a top-level binding | `let x = ...` |
| a `def` | `let`, `let rec` where it recurses, `and` between functions that call each other |
| a `def` with no parameters | a function taking `()` |
| `lam x. x + 1` | `fun x -> x + 1` |
| `var n = 0`, `n := e`, reading `n` | `let n = ref 0`, `n := e`, `!n` |
| a datatype | a variant type, its name lowercased |
| `Some`, `None`, `Ok`, `Error` of Pyking's library | `Some_`, `None_`, `Ok_`, `Error_` |
| `match` | `match` |
| a Char `'z'` | its code point, `122` |
| `==`, `%`, `+` on Strings | `=`, `mod`, `^` |
| a `for` over a list, a `loop` | a local recursive function |
| a list comprehension | `List.concat_map` |
| a tail call | a tail call; OCaml eliminates it |
| `print` | `print_endline`, with a printer per type |

The same program as in the other parts:

```pyking
use mutation

datatype Shape:
    Circle(r: Int)
    Rect(w: Int, h: Int)

def area(s: Shape) -> Int:
    match s:
        case Circle(r): 3 * r * r
        case Rect(w, h): w * h

var total = 0

def add(s: Shape):
    total := total + area(s)

for s in [Circle(1), Rect(2, 3)]:
    add(s)
print(total, total / 4)
```

```ocaml excerpt target=ocaml
type shape =
  | Circle of int
  | Rect of int * int
(* ... *)
let area s =
  match s with
      | Circle (r) -> 3 * r * r
      | Rect (w, h) -> w * h

let total = ref 0

let add s = total := !total + area s

let () =
  let rec tmp1 _tmp2 tmp4 =
    match tmp4 with
        | [] -> ()
        | s :: tmp3 -> (add s; tmp1 () tmp3) in
  tmp1 () [Circle 1; Rect (2, 3)];
  print_endline (string_of_int !total ^ " " ^ string_of_int (!total / 4))
```

### Targets and limits

- **What it takes:** everything the type checker accepts, except a few
  shapes OCaml cannot be given. The main ones: a `break` or `continue`
  that is neither the last thing in the loop body nor guarding the rest
  of it; printing a value whose type is a type variable; and a generic
  class whose method returns the class at other type arguments. Each is
  refused at compile time with a source position.
- **Running it:** `ocamlopt foo.ml -o foo && ./foo`. The output needs
  only the standard library, and builds with every warning on.
- **4.14 or 5.5:** the output is written for both. 4.14 lacks a few
  newer library functions, such as `List.take`, so the compiler does
  not use them there.
- **Where the output differs:** OCaml's `int` is 63 bits, so
  `2147483647 + 1` is `2147483648`, where Java and C give
  `-2147483648`. Division by zero raises `Division_by_zero`.
