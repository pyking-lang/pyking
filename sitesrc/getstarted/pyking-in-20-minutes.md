---
title: Pyking in 20 minutes
description: A fast tour of Pyking for someone who knows some Python, with examples you can run.
sidebar:
  order: 1
---

This page is a fast tour for someone who knows some Python. Every
example is a whole program: press **▶** to run it, or edit it first.
Each one runs on its own, so a name defined in one example is not
visible in the next.

## What Pyking is

- **A small, statically typed, Python-like language.** It has Python's
  syntax, but every block is a scope, and a name bound with `=` never
  changes.
- **Types are inferred.** Annotations are optional, and every program
  is type-checked before it runs.
- **One program, many targets.** `pyk prog.pyk` runs a program with the
  interpreter. `pyk compile` turns it into another language:

  | family | target | runs with |
  |---|---|---|
  | Python | `python` | `python3` |
  | JavaScript | `node`, `web`, `iweb` | `node`, or a browser |
  | C | `c`, and `c-gc` with a garbage collector | a C compiler |
  | Java | `java` | a JDK |
  | OCaml | `ocaml` | `ocamlopt` |

  See [Compiler targets](/documentation/targets/) for every version and
  what each one supports.
- **Tools.** A REPL, a [playground](/playground/) in the browser (the
  compiler runs in the page, nothing runs on a server), notebooks for
  teaching, and a language server and a debugger for the usual editors.
- **Libraries.** The [standard library](/libraries/) comes with Pyking,
  including [`tinyweb`](/libraries/tinyweb/) for graphics, sound, games
  and web pages.

**Where to try it.** Open the [playground](/playground/), or run
`pyk playground` after [installing Pyking](/install/) to serve it on
your own machine.

## Hello, world, and running a program

`print` writes its arguments separated by spaces. `+` joins two
strings, and `string(n)` turns a number into a string.

```pyking
name = "world"
n = 3
print("Hello,", name)
print("Hello, " + name + "! " + string(n) + " times.")
```

Save a program as `hello.pyk`, then run it with the interpreter, or
compile it to Python and run that:

```sh
pyk hello.pyk
pyk compile hello.pyk --target python --run
```

## Three modes, chosen with `use`

A module is functional and immutable unless its first lines say
otherwise. `use mutation` turns on mutable variables and collections,
and `use objects` turns on classes and interfaces. A construct from a
mode that is not turned on is a syntax error that names the `use` line
it needs:

```pyking error
var count = 0
count := count + 1
print(count)
```

This is refused with `'var' declares a mutable variable, which needs
'use mutation' at the top of this module`. A `use` line holds for its
own module only: importing a module that uses mutation does not turn
mutation on in the importer.

### Immutable: the default

With no `use` line, `=` binds a name to a value, functions recurse, and
`match` takes values apart.

```pyking
datatype Shape:
    Circle(radius: Float)
    Rect(width: Float, height: Float)

def area(s: Shape) -> Float:
    match s:
        case Circle(r): 3.14159 * r * r
        case Rect(w, h): w * h

def total(shapes: [Shape]) -> Float:
    match shapes:
        case []: 0.0
        case [s, ..rest]: area(s) + total(rest)

shapes = [Circle(1.0), Rect(2.0, 3.0), Rect(1.0, 1.0)]
print([area(s) for s in shapes if area(s) > 2.0])
print(total(shapes))
```

Writing `x = 2` after `x = 1` makes a new binding of `x`; it does not
change the old one. A binding made inside a block is gone after the
block, so the `x` after the `if` is the outer one:

```pyking
x = 1
x = x + 1
if x > 0:
    x = 10
    print("inside the block", x)
print("after it", x)
```

### Mutable: `use mutation`

`var` declares a variable that changes, and `:=` updates it. `+=` and
the other compound assignments work too. Arrays, DynArrays (arrays that
grow), MutMaps and `mutable struct`s are written in place.

```pyking
use mutation

var n = 27
var steps = 0
while n != 1:
    n := if n % 2 == 0 then n / 2 else 3 * n + 1
    steps += 1
print("27 reaches 1 in", steps, "steps")

squares = array(5, 0)
for i in range(5):
    squares[i] := i * i
print(squares)

evens: DynArray(Int) = dynarray()
for i in range(10):
    if i % 2 == 0:
        push(evens, i)
print(evens, len(evens))

counts: MutMap(String, Int) = mutmap()
for word in ["the", "cat", "and", "the", "hat"]:
    counts[word] := get(counts, word, 0) + 1
print(counts["the"], keys(counts))

mutable struct Counter(name: String, count: Int = 0)

c = Counter("clicks")
c.count += 1
c.count += 1
print(c)
```

Even with `use mutation`, a name bound with `=` never changes. This
example is meant to be refused:

```pyking error
use mutation

count = 1
count := count + 1
```

`use mutation, pointers` adds C-style pointers, for teaching how
memory is addressed. See [Mutable state](/documentation/language/mutable-state/).

### Objects: `use objects`

Classes and interfaces follow Java's semantics in Python's spelling:
objects are shared, a method is chosen when the program runs, and
methods take an explicit `self`. A class's header lists its fields,
which are also its constructor's parameters.

```pyking
use objects

interface Shape:
    def area(self) -> Float
    def name(self) -> String

class Circle(radius: Float) implements Shape:
    override def area(self) -> Float:
        3.14159 * self.radius * self.radius
    override def name(self) -> String:
        "circle"

class Rect(width: Float, height: Float) implements Shape:
    override def area(self) -> Float:
        self.width * self.height
    override def name(self) -> String:
        "rectangle"

shapes: [Shape] = [Circle(1.0), Rect(2.0, 3.0)]
for s in shapes:
    print(s.name(), s.area())
```

## Language tour

### Values and types

The basic types are `Int`, `Float`, `String`, `Char` and `Bool`. A
`Char` is written in single quotes, a String in double quotes, and the
Bools are `true` and `false`. Nothing is converted implicitly:
`float(n)`, `int(x)` and `string(v)` convert.

```pyking
n = 7
half = float(n) / 2.0
name = "Ada"
first = name[0]
ok = n > 5 and first == 'A'
print(n, half, name, first, ok)
print("n is " + string(n), int("42") + 1, int(3.9))
```

`1 + 2.0` and `"n = " + 5` are type errors, with a message that says
which conversion to write.

### Functions

`def` defines a function. Its value is its last expression, or what it
`return`s, and a body of one expression can go on the header's line.
Parameters may have defaults and be passed by name. Where there are no
annotations, the checker infers the most general type, so `twice` works
for any function whose argument and result have the same type.

```pyking
def greet(name: String, greeting = "Hello") -> String:
    greeting + ", " + name + "!"

def area(width: Float, height: Float) -> Float: width * height

def twice(f, x): f(f(x))

print(greet("Ada"), greet("Bob", greeting = "Hi"))
print(area(height = 2.0, width = 3.0))
print(twice(lam n. n * 10, 3), twice(lam s. s + "!", "hey"))
```

### Lambdas, `if` expressions and `let`

A lambda is `lam x. x + 1`. `if c then a else b` is an expression, and
`let x = e in body` binds a name for one expression.

```pyking
inc = lam x. x + 1
add = lam (a, b). a + b
n = 7
parity = if n % 2 == 0 then "even" else "odd"
y = let sq = n * n in sq + 1
print(inc(1), add(2, 3), parity, y)
```

### Lists, tuples and comprehensions

Lists are written `[...]` and joined with `+`. A tuple is taken apart
with `=`. `fmap`, `filter` and `foldl` work on lists.

```pyking
xs = [3, 1, 4, 1, 5, 9]
pair = ("Ada", 36)
(who, age) = pair
print(xs[0], len(xs), xs + [2, 6], who, age)
print([x * x for x in xs if x > 2])
print(fmap(lam x. x * 10, xs))
print(filter(lam x. x % 2 == 1, xs))
print(foldl(lam (acc, x). acc + x, 0, xs))
```

### Datatypes, structs and `match`

A `datatype` lists its constructors. A `struct` is a datatype with one
constructor, and `Point(x = 10, ..p)` copies `p` with one field
changed. `match` patterns may be or-patterns (`|`), have guards
(`if`), and bind the whole value with `as`. A `match` that misses a
case is refused.

```pyking
struct Point(x: Int, y: Int = 0)

datatype Token:
    Number(value: Int)
    Plus
    Minus
    Word(text: String)

def describe(t: Token) -> String:
    match t:
        case Plus | Minus: "an operator"
        case Number(n) if n < 0: "a negative number"
        case Number(n): "the number " + string(n)
        case Word(_) as w: "a word: " + string(w)

p = Point(3, 4)
q = Point(x = 10, ..p)
print(p, q, p.x + q.y, Point(1))
print([describe(t) for t in [Number(5), Number(-2), Minus, Word("hi")]])
```

### `Option` and `Result`

Pyking has no null and no exceptions to catch. A value that may be
missing is an `Option`: `Some(v)` or `None`. A computation that
may fail gives a `Result`: `Ok(v)` or `Error(e)`.

```pyking
import option

def find_age(name: String, people: [(String, Int)]) -> Option(Int):
    match people:
        case []: None
        case [(n, age), ..rest]: if n == name then Some(age) else find_age(name, rest)

def safe_div(a: Int, b: Int) -> Result(Int, String):
    if b == 0 then Error("division by zero") else Ok(a / b)

people = [("Ada", 36), ("Bob", 41)]
print(find_age("Bob", people), find_age("Cy", people))
print(option.unwrap_or(find_age("Cy", people), 0))
match safe_div(10, 0):
    case Ok(q): print("quotient", q)
    case Error(e): print("error:", e)
```

### The `loop` loop

`loop` carries values from one turn to the next, with no mutable
variable. Each turn ends with the next values, `break` stops it, and
the loop's value is what it carried last.

```pyking
total = loop sum = 0 for x in [1, 2, 3, 4]:
    sum + x

(a, b) = loop a, b = 0, 1:
    if a > 50:
        break
    (b, a + b)

print(total, a, b)
```

### Modules

A file is a module. Its names are private unless marked `public`.
`import m` reaches them as `m.name`, and `from m import name` brings
one in unqualified. Two files, `shapes.pyk` and `main.pyk`, beside each
other:

```pyking norun
# shapes.pyk
def times(a: Int, b: Int) -> Int: a * b     # private to shapes.pyk
public def square(x: Int) -> Int: times(x, x)
```

```pyking norun
# main.pyk
import shapes
from shapes import square

print(shapes.square(3), square(4))
```

The standard library is imported the same way:

```pyking
import list
import text
from text import upper, words

ws = words("the quick brown fox")
print(list.sort(ws), list.sum([1, 2, 3]))
print(upper(text.join(ws, "-")))
```

### Overloading and implicits (advanced)

Two functions may share a name if a qualifier tells them apart. A call
without the qualifier picks the one its arguments fit.

```pyking
def int::describe(x: Int) -> String: "the number " + string(x)
def string::describe(s: String) -> String: "the text " + s

print(describe(42))
print(describe("hi"))
```

A parameter marked `implicit` may be left out of a call. It is filled
in from an `implicit` binding of the same name and type in scope.

```pyking
def shout(text: String, implicit mark: String) -> String:
    text + mark

implicit mark = "!"
print(shout("hello"), shout("hi", mark = "?"))
```

## Input and output

The [`io`](/libraries/io/) library reads standard input.
`io.read_line()` reads one line, and `io.is_eof()` says whether the
input has ended. The input below is filled in above the code:

```stdin
3
4
5
```

```pyking
import io

total = loop sum = 0 while not io.is_eof():
    line = io.read_line()
    if line == "" then sum else sum + int(line)
io.write_line("The sum is " + string(total))
```

`sys.args()` from the [`sys`](/libraries/sys/) library gives the
program's command-line arguments, which follow `--`:

```args
one two
```

```pyking
import sys

args = sys.args()
print("I was given", len(args), "arguments:", args)
```

```sh
pyk args.pyk -- one two
```

### `print` and `debug`

`debug` takes the same arguments as `print`, but writes to standard
error, so tracing a program does not change its output. Compiling with
`--release` removes every `debug` call.

```pyking
def square(x: Int) -> Int:
    debug("square of", x)
    return x * x

print(square(7))
```

See [Debugging](/getstarted/debugging/) for more.

## A first tinyweb program

[`tinyweb`](/libraries/tinyweb/) draws on a page and reacts to the
mouse and the keyboard. This program draws a dot where you click, and
the keys r, g and b change the colour. In the playground the page shows
on the **Web output** tab; click it first so that it gets the keys.

```pyking
use mutation

import tinyweb as tw
import tinyweb.color as color

tw.web_init()

canvas = tw.canvas(400, 200)
shown = tw.label("Click the canvas. Press r, g or b to change the colour.")
var paint = color.red
var dots = 0

def clicked(x: Int, y: Int):
    tw.circle(canvas, x, y, 12, paint)
    dots += 1
    tw.set_text(shown, string(dots) + " dots")

def pressed(key: String):
    if key == "r":
        paint := color.red
    else if key == "g":
        paint := color.green
    else if key == "b":
        paint := color.blue

tw.on_click(canvas, clicked)
tw.on_key(pressed)
```

In a terminal, `pyk prog.pyk` serves the page and prints its address.
`pyk compile prog.pyk --target web --run` compiles it to a web page and
serves that.

## Where next

- [Setting up Pyking](/getstarted/setting-up/): installing it, and your
  editor.
- [Debugging](/getstarted/debugging/): `debug`, and the debugger in the
  playground and in editors.
- The [language reference](/documentation/language/), for every
  construct in full.
- The [libraries](/libraries/).
- The [playground](/playground/), to try your own programs.
