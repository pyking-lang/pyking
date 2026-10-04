---
title: Language overview
description: A short tour of Pyking, with examples you can run.
sidebar:
  order: 1
---

Pyking reads like Python. This page covers the main places where it
differs. Every example is a whole program: press **▶** to run it, or edit
it first. Each one runs on its own, so a name defined in one example is
not visible in the next.

## Bindings and variables

`=` binds a name to a value, and that binding never changes. A variable
that changes is declared with `var` and updated with `:=`.

```pyking
limit = 10
var total = 0
for i in range(1, limit + 1):
    total := total + i
print("The sum of 1 ..", limit, "is", total)
```

Updating a name that was bound with `=` is a compile-time error. This
example is meant to be refused:

```pyking error
count = 1
count := count + 1
```

## Functions and types

Annotations are optional. Where a function has none, the checker infers
its most general type, so `twice` below works with any function whose
argument and result have the same type.

```pyking
def twice(f, x): f(f(x))
def inc(n): n + 1
def shout(s): s ++ "!"

print(twice(inc, 5))
print(twice(shout, "hey"))
```

A function's value is its last expression, or what it `return`s. A body
of one expression can go on the header's line, as above.

## Control flow

`if` is a statement, and also an expression written
`if c then a else b`. `while` loops while its condition holds.

```pyking
var n = 27
var steps = 0
while n > 1:
    n := if n / 2 * 2 == n then n / 2 else 3 * n + 1
    steps := steps + 1
print("27 reaches 1 in", steps, "steps")
```

`loop` carries values from one turn to the next. Each turn ends with the
next values, and `break` stops the loop. The loop's value is what it
carried last.

```pyking
def factorial(n: Int) -> Int:
    (_, result) = loop k, acc = n, 1:
        if k == 0:
            break
        (k - 1, acc * k)
    return result

print(factorial(10))
```

## Lists, tuples and pattern matching

`match` takes values apart. A list pattern `[first] ++ rest` matches a
non-empty list, and a tuple is taken apart with `=`.

```pyking
def describe(n: Int) -> String:
    match n:
        case 0: "zero"
        case 1: "one"
        case _: "many"

def sum(xs: [Int]) -> Int:
    match xs:
        case []: 0
        case [first] ++ rest: first + sum(rest)

print(describe(0), describe(1), describe(7))
print(sum([1, 2, 3, 4]))

point = (3, 4)
(x, y) = point
print(x * x + y * y)
```

## Recursion

A call in tail position does not use up stack space, so a recursive
function can run for as long as a loop.

```pyking
def count_down(n: Int) -> Int:
    if n == 0:
        return 0
    return count_down(n - 1)

print(count_down(1000000))
```

## Modules and the standard library

A program uses a module with `import`. The [standard library](/libraries/)
comes with Pyking. This example reads one line of standard input, which is
filled in above the code:

```stdin
Ada
```

```pyking
import io

name = io.read_line("What is your name? ")
io.write_line("Nice to meet you, " ++ name ++ "!")
```

## Next steps

- Try your own programs in the [playground](/playground/).
- Browse the [libraries](/libraries/).
- `pyk repl` starts an interactive session in a terminal.
