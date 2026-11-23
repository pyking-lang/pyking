# Pyking for coding assistants

This is a short guide to writing correct Pyking, written for a
language model that already knows Python. Pyking *looks* like Python,
but it is statically typed, immutable by default, and differs in many
small ways. **Do not guess from Python: when this guide and Python
disagree, this guide is right.** The full reference is `PYKING.md`
(`pyk ai ref` searches it).

## How to work

1. Write the program in a `.pyk` file. A program is its top-level
   statements, run from top to bottom; there is no `main`.
2. Check it with `pyk check prog.pyk`, which runs nothing, and run it
   with `pyk prog.pyk`. Every program is type-checked before it runs,
   so most mistakes are reported with a file, a line and a message
   that usually says what to write instead. **Read the message and do
   what it says**, then check again.
3. Look things up instead of guessing:
   - `pyk ai lib` lists the libraries, `pyk ai lib NAME` lists what one
     exports (e.g. `pyk ai lib text`, `pyk ai lib tinyweb.color`), and
     `pyk ai lib NAME.ITEM` shows one function in full, with an example
     (e.g. `pyk ai lib tinyweb.circle`).
   - `pyk ai ref WORDS` prints the sections of the language reference
     whose titles contain the words (e.g. `pyk ai ref match`,
     `pyk ai ref dynarray`); `pyk ai ref` lists every section.
4. Write type annotations on every `def`'s parameters and result. They
   are optional, but they make the error messages much clearer.

## Python habits that are wrong in Pyking

| Python | Pyking |
|---|---|
| `True`, `False`, `None` (as null) | `true`, `false`; there is no null: use `Option` (`Some(x)` / `None`) |
| `x = x + 1` to update | `x = x + 1` makes a *new* binding. To update: `use mutation`, `var x = 0`, then `x := x + 1` or `x += 1` |
| `xs[i] = v`, `p.x = v` | `xs[i] := v`, `p.x := v` (needs `use mutation` and an Array/DynArray/mutable struct) |
| `xs.append(v)`, `s.upper()`, `s.split(",")` | no methods on built-in types: `push(v, x)`, `text.upper(s)`, `text.split(s, ",")` |
| `lambda x: x + 1` | `lam x. x + 1`, `lam (a, b). a + b`, `lam (). 5` |
| `a if c else b` | `if c then a else b` |
| `elif` | `else if` |
| `x ** 2`, `a ^ b` (xor) | `x ^ 2`; exclusive or is `xor` |
| `7 // 2` | `7 / 2` (Int division truncates toward zero: `-7 / 2` is `-3`) |
| `str(x)`, `f"{x}"`, `"%d" % x` | `string(x)`; interpolation needs no `f`: `"x is $x, next ${x + 1}"` |
| `'text'` | `"text"`; `'a'` is a `Char`, a different type |
| `1 + 2.0`, `"n=" + 5` | no implicit conversion: `float(1) + 2.0`, `"n=" + string(5)` |
| `"a" * 3`, `[0] * n` | `text.repeat("a", 3)`, `list(n, 0)` |
| `x in xs`, `k in d` | `list.contains(x, xs)`, `has(m, k)`, `text.contains(s, part)` |
| `a < b < c` | `a < b and b < c` (no chaining) |
| `s1 < s2` on Strings | not allowed; `<` is for Int, Float and Char. Sort Strings with `list.sort` |
| `xs[-1]` on a list | out of range at run time; use `xs[len(xs) - 1]` or `list.last(xs)` (an Option). A tuple may use `t[-1]` |
| `{"a": 1}`, `{1, 2}` | `map([("a", 1)])`, or `mutmap()` under `use mutation`; no set type |
| `len`, `range`, `print` | the same (`range` gives a list) |
| `sum`, `max`, `min`, `abs`, `sorted` | `list.sum(xs)`, `math.max(a, b)`, `math.abs(x)`, `list.sort(xs)`, after `import list` / `import math` |
| `input()` | `import io` then `io.read_line()` |
| `try`/`except`, `raise` | no exceptions: return a `Result` (`Ok(v)` / `Error(e)`); `panic("msg")` stops the program |
| `assert c` | `if not c: panic("...")` |
| `class` | needs `use objects` at the top; see "Objects" |
| `global`, `nonlocal` | not needed: an inner `def` sees and, with `var`, updates outer variables |
| `from m import *` | name every import: `from m import a, b` |
| constants `PI = 3.14` | names start lowercase: `pi = 3.14`. Uppercase is only for types and constructors |
| `x is y` | `same(x, y)` for shared mutable things; otherwise `==` |
| `pass` | no `pass`: an empty body is `()`, as in `def todo() -> (): ()` |

## Program shape and modes

A file is a module. Its first lines may turn on features with `use`:

| Line | Turns on |
|---|---|
| (nothing) | immutable, functional code: `=`, `def`, lists, tuples, Maps, datatypes, structs, `match`, `for`, `loop` |
| `use mutation` | `var`, `:=`, `+=`, Arrays, DynArrays, MutMaps, `mutable struct` |
| `use objects` | `class`, `interface`, `abstract class` |
| `use mutation, objects` | both (a class with `var` fields needs both) |

A `use` line comes first, then `import` lines, then the program. A
`use` holds for its own file only.

```pyking
use mutation

import list
from text import upper

var total = 0
for x in [3, 1, 2]:
    total += x
print(upper("total:"), total, list.sort([3, 1, 2]))
```

## Values and operators

- Types: `Int`, `Float`, `String`, `Char`, `Bool`, the unit `()`,
  lists `[T]`, tuples `(A, B)`, functions `(A, B) -> C`, `Option(T)`,
  `Result(T, E)`, `Map(K, V)`, `Array(T)`, `DynArray(T)`,
  `MutMap(K, V)`.
- Float literals need a digit on both sides of the point: `1.0`, `0.5`.
- `+` adds numbers and joins Strings or lists; both sides have one type.
- `/` on Ints is integer division; `%` is the remainder; `^` is power.
- `and`, `or`, `not` (also `&&`, `||`, `!`) take Bools only; there is
  no truthiness: write `len(xs) > 0`, not `xs`.
- Conversions: `string(x)`, `int(x)`, `float(x)`, `char(n)`, `bool(x)`.
  `int("12")` is 12, `int(3.9)` is 3, `int("x")` is 0.
- `s[i]` is a `Char`; `for c in s` walks a String's Chars;
  `s[1:3]` and `xs[1:3]` are slices; `len(s)` counts characters.

```pyking
n = 7
half = float(n) / 2.0
name = "Ada"
print(n / 2, n % 2, n ^ 2, half, name[0], len(name))
print("$name is ${n * 6}", "x" + string(n), int("42") + 1)
```

## Bindings and scope

- `x = 1` binds `x`. Binding `x` again makes a new `x`; nothing is
  updated. A tuple is taken apart with `(a, b) = pair`.
- Every block (an `if` branch, a loop body, a `case`) is a scope: a
  name bound inside is gone after it.
- `x: Int = 1` annotates a binding.
- `let y = e in body` is an expression binding one name.
- To change a value over time use `var` and `:=` (under
  `use mutation`), or a `loop` that carries the value (no mutation
  needed).

```pyking
x = 1
if x > 0:
    x = 10              # a new x, only inside this block
    print("inside", x)
print("after", x)       # 1
(who, age) = ("Ada", 36)
print(who, age, let sq = age * age in sq + 1)
```

## Functions

- The value of a function is its last expression; `return` also works.
  A body that is one expression may follow the `:` on the same line.
- Parameters may have defaults and be passed by name.
- Functions are values. Inner `def`s and lambdas capture outer names.
- A lambda's body is one expression: `lam x. x * 2`.

```pyking
def greet(name: String, greeting: String = "Hello") -> String:
    greeting + ", " + name + "!"

def square(x: Int) -> Int: x * x

def apply_twice(f: (Int) -> Int, x: Int) -> Int:
    f(f(x))

def sign(n: Int) -> String:
    if n < 0:
        return "negative"
    if n == 0 then "zero" else "positive"

print(greet("Ada"), greet("Bo", greeting = "Hi"))
print(square(5), apply_twice(lam x. x + 3, 1), sign(-4))
```

A function returning nothing has result type `()`; a bare `return`
returns `()`.

## Control flow

```pyking
def classify(n: Int) -> String:
    if n < 0:
        "negative"
    else if n == 0:
        "zero"
    else:
        "positive"

for i in range(3):
    print(i, classify(i - 1))

for (name, score) in [("ann", 3), ("bo", 5)]:
    print(name, score)

label = if 3 > 2 then "big" else "small"
size = match len(label):
    case 0: "empty"
    case _: "not empty"
print(label, size)
```

- `range(n)`, `range(a, b)` and `range(a, b, step)` give lists.
- `while cond:` loops need a `var` to change (under `use mutation`).
- `break` and `continue` work in `for` and `while`.
- A one-line block after a header may be an expression, `return`,
  `break`, `continue` or an update: `if x < 0: continue`. Not a binding.

**`loop` carries a value without mutation.** `loop acc = start for x in
xs:` runs the body for each `x`; the body's last value is the next
`acc`, and the loop is worth the final `acc`. `break v` stops with `v`.
It also works with `while cond:` or alone.

```pyking
total = loop acc = 0 for x in [1, 2, 3, 4]:
    acc + x

first_big = loop found = -1 for x in [4, 9, 12, 20]:
    if x > 10: break x
    found

(a, b) = loop a, b = 0, 1:
    if a > 50: break
    (b, a + b)

print(total, first_big, a, b)
```

## Collections

| Kind | Make | Read | Change (needs `use mutation`) |
|---|---|---|---|
| list `[T]`, immutable | `[1, 2]`, `list(n, v)`, `list_init(n, f)`, comprehension | `xs[i]`, `xs[i:j]`, `len`, `for` | none: build a new list, `xs + [x]` |
| tuple `(A, B)` | `(1, "a")` | `(a, b) = t`, `t[0]`, `t[-1]` (index written as a number) | none |
| `Map(K, V)`, immutable | `map([("a", 1)])`, `map()` | `m[k]`, `get(m, k, default)`, `has`, `keys`, `values`, `items` | none: `map.insert(m, k, v)` gives a new Map |
| `Array(T)`, fixed size | `array([1, 2])`, `array(n, v)` | `a[i]`, `len` | `a[i] := v` |
| `DynArray(T)`, grows | `dynarray()`, `dynarray([1])` | `v[i]`, `len` | `push(v, x)`, `pop(v)`, `insert(v, i, x)`, `remove(v, i)`, `v[i] := x` |
| `MutMap(K, V)` | `mutmap()`, `mutmap([("a", 1)])` | as Map | `d[k] := v`, `remove(d, k)` |

- Every collection works with `fmap(f, c)`, `filter(p, c)`,
  `foldl(f, init, c)`, `foldr`, `any(p, c)` and `all(p, c)`; the
  function comes **first**. `foldl`'s function takes `(acc, x)`.
- Comprehensions: `[x * x for x in xs if x > 2]`, with several `for`s.
- An empty collection needs its type from use or an annotation:
  `seen: DynArray(Int) = dynarray()`.
- Arrays, DynArrays, MutMaps and mutable structs are shared: `b = a` is
  the same one. `copy(a)` and `deepcopy(a)` copy.
- `import list` adds `list.sort`, `list.reverse`, `list.sum`,
  `list.contains`, `list.zip`, `list.enumerate`, `list.take`, `list.find`
  and more (`pyk ai lib list`).

```pyking
use mutation

import list

xs = [3, 1, 4, 1, 5]
print([x * 10 for x in xs if x > 2], fmap(lam x. x + 1, xs))
print(filter(lam x. x % 2 == 1, xs), foldl(lam (acc, x). acc + x, 0, xs))
print(list.sort(xs), list.sum(xs), list.contains(4, xs), list.last(xs))

ages = map([("ann", 31), ("bo", 5)])
print(ages["ann"], get(ages, "cy", 0), keys(ages))

counts: MutMap(String, Int) = mutmap()
for word in ["the", "cat", "the"]:
    counts[word] := get(counts, word, 0) + 1
for (word, n) in items(counts):
    print(word, n)

stack: DynArray(Int) = dynarray()
push(stack, 1)
push(stack, 2)
print(pop(stack), len(stack), stack)
```

## Datatypes, structs and `match`

- `datatype` declares a type with constructors (uppercase), with or
  without fields. `struct` is a datatype with one constructor; read a
  named field with `p.x`; `Point(x = 5, ..p)` copies `p` with `x`
  changed. Under `use mutation`, a `mutable struct`'s fields are
  written with `p.x := v`.
- `match` takes values apart. Patterns: literals, `_`, names, tuples
  `(a, b)`, lists `[]`, `[x, ..rest]`, constructors `Circle(r)`,
  alternatives `A | B`, guards `case n if n > 0:`, and `as`.
- Every `match` must cover every value, or the compiler refuses it.
- `Option(T)` is `Some(v)` or `None`; `Result(T, E)` is `Ok(v)` or
  `Error(e)`. `import option` / `import result` add helpers such as
  `option.unwrap_or(o, default)`.

```pyking
datatype Shape:
    Circle(radius: Float)
    Rect(width: Float, height: Float)

struct Point(x: Int, y: Int = 0)

def area(s: Shape) -> Float:
    match s:
        case Circle(r): 3.14159 * r * r
        case Rect(w, h): w * h

def total(xs: [Int]) -> Int:
    match xs:
        case []: 0
        case [x, ..rest]: x + total(rest)

def find(name: String, people: [(String, Int)]) -> Option(Int):
    match people:
        case []: None
        case [(n, age), ..rest]: if n == name then Some(age) else find(name, rest)

def safe_div(a: Int, b: Int) -> Result(Int, String):
    if b == 0 then Error("division by zero") else Ok(a / b)

p = Point(3, 4)
q = Point(x = 10, ..p)
print(area(Rect(2.0, 3.0)), total([1, 2, 3]), p, q.x, Point(1))
match find("bo", [("ann", 31), ("bo", 5)]):
    case Some(age): print("found", age)
    case None: print("missing")
match safe_div(1, 0):
    case Ok(v): print(v)
    case Error(e): print("error:", e)
```

A datatype may take type parameters: `datatype Tree(a): Leaf, Node(left:
Tree(a), value: a, right: Tree(a))`.

## Objects (`use objects`)

Java's semantics in Python's spelling. The class header lists the
fields, which are the constructor's parameters. Methods take `self`
explicitly and declare their types. `var` fields need `use mutation`
too. A method implementing an interface's or overriding a parent's is
marked `override`.

```pyking
use mutation, objects

interface Shape:
    def area(self) -> Float
    def name(self) -> String

class Circle(radius: Float) implements Shape:
    override def area(self) -> Float: 3.14159 * self.radius * self.radius
    override def name(self) -> String: "circle"

class Counter(start: Int):
    var count: Int = 0
    def bump(self) -> ():
        self.count := self.count + 1

shapes: [Shape] = [Circle(1.0), Circle(2.0)]
for s in shapes:
    print(s.name(), s.area())
c = Counter(0)
c.bump()
c.bump()
print(c.count)
```

## Modules and libraries

- Names are private to their file unless marked `public`:
  `public def square(x: Int) -> Int: x * x`.
- `import shapes` reaches `shapes.square`; `import tinyweb as tw`
  renames; `from text import upper, words` brings names in unqualified.
- A module is found beside the importing file (`shapes.pyk`), in `-L`
  directories, or in the standard library.
- The standard library: `list`, `text`, `math`, `io`, `fs`, `sys`,
  `random`, `time`, `option`, `result`, `map`, `mutmap`, `array`,
  `dynarray`, and `tinyweb` (graphics, widgets, sound and games on a
  web page; submodules `tinyweb.color`, `tinyweb.sound`, ...).
  **Before using a library, run `pyk ai lib NAME`** to see its exact
  function names and parameter order, and `pyk ai lib NAME.FUNCTION`
  for an example.

```pyking norun
# shapes.pyk
def times(a: Int, b: Int) -> Int: a * b      # private
public def square(x: Int) -> Int: times(x, x)
```

```pyking norun
# main.pyk
import shapes
from shapes import square
print(shapes.square(3), square(4))
```

## Input and output

- `print(a, b)` separates with spaces; `printsl` has no newline;
  `eprint` writes to standard error; `debug` is for tracing.
- `import io`: `io.read_line()` reads a line (without its newline),
  `io.is_eof()` says whether input has ended, `io.read()` reads all.
- `import sys`: `sys.args()` gives the arguments after `--`.
- `import fs`: `fs.read_text(path)`, `fs.write_text(path, text)`.

Given this input:

```stdin
3
4
5
```

```pyking
import io
import text

total = loop sum = 0 while not io.is_eof():
    line = text.trim(io.read_line())
    if line == "" then sum else sum + int(line)
print("sum:", total)
```

## A complete example

```pyking
use mutation

import list
import text

struct Entry(word: String, count: Int)

def count_words(lines: [String]) -> [Entry]:
    counts: MutMap(String, Int) = mutmap()
    for line in lines:
        for word in text.words(text.lower(line)):
            counts[word] := get(counts, word, 0) + 1
    [Entry(w, n) for (w, n) in items(counts)]

def busiest(entries: [Entry]) -> Option(Entry):
    list.maximum_by(lam (a, b). a.count < b.count, entries)

entries = count_words(["The cat", "the hat", "A cat and the dog"])
for e in entries:
    if e.count > 1: print(e.word, e.count)
match busiest(entries):
    case Some(e): print("most common:", e.word)
    case None: print("no words")
```

## When the compiler refuses a program

| Message says | Usually means |
|---|---|
| `needs 'use mutation'` / `needs 'use objects'` | add that `use` line at the top of the file |
| `cannot update 'x' with ':='`: it is a binding | declare it `var x = ...` (under `use mutation`) |
| `cannot be applied to Int and Float` | convert one side with `float(n)` or `int(x)` |
| `unbound name 'max'` (or `str`, `sum`, `sorted`, `input`) | not a builtin: see the "Python habits" table |
| `reads a field of a datatype, but this value is String` | Strings and lists have no methods; use `text.` or `list.` functions |
| `this 'match' does not match every value` | add a `case` for the value it names, or a final `case _:` |
| `nothing here says what datatype this value is` | annotate the parameter, e.g. `p: Point`; a tuple you index needs one too, e.g. `t: (Int, Int)` |
| `Warning: ... never used` | not an error; rename to `_x` or remove it |
