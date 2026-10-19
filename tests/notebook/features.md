---
title: Every notebook feature
author: The test suite
---

# Features

A paragraph with *emphasis*, **strong**, ***both***, _underscores_,
~~strikethrough~~, `inline code`, a [link](https://example.com "Example"),
a [reference link][ref], an image ![a dot](dot.png), a bare
https://example.org/path link, an <https://autolink.example> and an
escaped \*star\*. Snake_case_words stay whole.
A line ending in two spaces  
breaks, and so does a backslash\
like this.

[ref]: https://example.com/ref

## Code cells

A runnable cell:

```pyking
print("Hello", "world", 2026)
```

A cell that is meant to be refused:

``` pyking error
x = 1
x := 2
```

A read-only cell:

```pyking readonly
def sq(x: Int) -> Int: x * x
print(sq(7))
```

A fragment, highlighted but not runnable:

```pyking norun
def f(x): ...
```

Another language:

```python
print("not Pyking")
```

    an indented code block

## Exercises and quizzes

``` rules max = 12 pass = 9
Solve all exercises and quizzes. An **exercise** is checked against its
tests when it is submitted.
```

A cell's input can be written on its header:

```pyking stdin = "Ada" args = "first 'second one'"
import io
import sys
print("hello", io.read_line(), sys.args())
```

So can a read-only cell's, an error cell's and a fragment's:

```pyking readonly stdin = "7"
import io
print(int(io.read_line()) * 2)
```

```pyking error stdin = "1"
x = 1
x := 2
```

```pyking norun args = "a b"
def f(x): ...
```

The older way still works, a ```` ```stdin ```` block right before the
cell:

```stdin
Grace
```

```pyking
import io
print("hi", io.read_line())
```

An output shown as if the cell had run:

```pyking
print("my out")
```

```stdout visible = true
my out
```

Output checked in test mode but not shown, with the input it is read
from, and what `debug` writes:

```pyking
import io
debug("to stderr")
print(io.read_line())
```

```stdin
echo me
```

```stdout
echo me
```

```stderr visible = true
to stderr
```

Write a program that reads a line and prints it twice, then its
arguments.

```pyking exercise attempts = 3 stdin = "123" args = "go for it" points = 5
print("Add your code here")
```

```pyking solution available = true
import io
import sys
line = io.read_line()
print(line, "/", line)
print("args:", sys.args())
```

```stdin args = "my 123"
This is some input
with several lines
```

```stdin args = "other 77" visible = true
Another example
```

```stdout visible = true
Another example / Another example
args: ['other', '77']
```

```stdout
123 / 123
args: ['go', 'for', 'it']
```

An exercise with no solution, checked against its stdout only, and
worth no points:

```pyking exercise
print("Hello")
```

```stdout visible = true
Hello, world
```

An exercise whose solution cannot be shown, losing a point for each
failed try:

```pyking exercise attempts = 2 points = 1 penalty = 1
print(0)
```

```pyking solution available = false
print(6 * 7)
```

Which is true of Pyking?

```quiz points = 2
* It is statically typed.

* It has no types at all.
```

```answer
-> Every program is type-checked before it runs.
- The checker runs on every program.
```

Which are true of bindings?

```quiz attempts = 2 points = 2 penalty = 1 available = true
[] `var` binds a name that can change.

[] `=` binds a name that can change.

[] `:=` updates a `var`.
```

```answer
-> A `var` is updated with `:=`.
- A name bound with `=` never changes.
->
```

A quiz may hold its question, and give a point for each right answer:

```quiz points = 2 one_point_correct = true
Why can static type checking be useful?

[] It enables duck typing in a general way.

[] It may rule out errors already at compile time.

[] Because it implies that runtime errors occur more frequently.

[] It may make the execution performance better.

[] It guarantees always that runtime errors are avoided, e.g.,
   division by zero errors are always avoided statically in languages
   such as C, Java, and OCaml.
```

```answer
-  False, duck typing is used in dynamic typing
-> True, compile time checking can avoid hard-to-detect runtime errors.
-  False, ruling out errors statically can avoid runtime errors
-> True, some compilers can avoid expensive runtime checks after static checking
-  False, some errors are typically not detected statically, such as out-of-bound errors and division-by-zero errors.
```

## Lists

- one
- two
  - nested *a*
  - nested b
- three

1. first
2. second

3. third, after a blank line

7) seven
8) eight

- [ ] a task
- [x] a done task

## Tables

| Left | Center | Right |
|:-----|:------:|------:|
| a    | `b|c`  | 1     |
| **d** | e     | 22    |

## Quotes and callouts

> A quote
> over two lines.
>
> > And a nested one.

> [!NOTE]
> Notes render as callouts.

> [!WARNING]
> So do warnings, with **inline** markup.

## Math

Inline math $e^{i\pi} + 1 = 0$ and a price of $5 and $6 stay text.

$$
\sum_{k=1}^{n} k = \frac{n(n+1)}{2}
$$

```math
a^2 + b^2 = c^2
```

## Footnotes

A claim[^source] and another[^2].

[^source]: The source of the claim.
[^2]: A second note,
    over two lines.

Setext heading
--------------

Rules:

***

<div class="raw">Raw <b>HTML</b> passes through.</div>

## Features

The same heading twice gets a distinct anchor.
