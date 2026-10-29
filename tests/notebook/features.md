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
use mutation

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

The same fragment with the other header form and fence:

~~~ {.pyking .norun}
def g(x): ...
~~~

Another language:

```python
print("not Pyking")
```

    an indented code block

## Tasks and quizzes

``` rules max = 12 pass = 9
Solve all tasks and quizzes. An **task** is checked against its
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
use mutation

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

And an ```` ```args ```` block right before the cell:

```args
one "two three"
```

```pyking
import sys
print(sys.args())
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

```pyking task name = "twice" attempts = 3 stdin = "123" args = "go for it" points = 5
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
args: ["other", "77"]
```

```stdout
123 / 123
args: ["go", "for", "it"]
```

A practice, worth no points, with no solution, checked against its
stdout only:

```pyking practice
print("Hello")
```

```stdout visible = true
Hello, world
```

A task whose solution cannot be shown, losing a point for each
failed try:

```pyking task attempts = 2 points = 1 penalty = 1
print(0)
```

```pyking solution available = false
print(6 * 7)
```

A page whose button counts its clicks, clicked twice once the program's
top level has ended:

```pyking practice name = "counter"
import tinyweb as tw
tw.web_init(0)
```

```pyking solution
use mutation

import tinyweb as tw
var count = 0
tw.web_init(0)
shown = tw.label("0")
def more():
    count := count + 1
    tw.set_text(shown, string(count))
    print(count)
tw.button("More", on_click = more)
```

```events visible = true
click "More"
click "More"
```

```stdout visible = true
1
2
```

A practice whose answer may name `print` at most twice, outside
comments and strings:

```pyking practice name = "twice_print" max_calls = (2,print)
# print what the solution prints, with at most two "print"
print(1)
```

```pyking solution
xs = [1, 2, 3]
for x in xs:
    print(x)
```

Which is true of Pyking?

```quiz name = "typed" points = 2
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

A practice whose stdin block is split into one test for every line,
each compared with what the solution prints on it:

```pyking practice name = "doubling"
print("Add your code here")
```

```pyking solution
import io
print(int(io.read_line()) * 2)
```

```stdin lines_per_multi_input = 1 visible = true
1
2
3
```

A practice that draws, whose solution's canvas is saved as a picture
and shown here:

![A blue dot](dot.png)

```pyking practice name = "dot"
print("Add your code here")
```

```pyking solution stdin = "8" args = "blue" save_canvas = "canvas" file = "dot.png"
import io
import tinyweb as tw
import tinyweb.color as color
r = int(io.read_line())
c = tw.canvas(40, 40)
tw.circle(c, 20, 20, r, color.blue)
```

```stdin
12
```

A practice compared loosely: the number may differ by 0.01, a last
`done` may be left out, `a` and `b` may come in either order, spaces
and commas do not matter on the `point` line, and what `debug` writes
is compared too:

```pyking practice name = "loose"
print("Add your code here")
```

```pyking solution
print("point 1, 2")
print("area =", 3.14159)
print("b")
print("a")
debug("checked")
print("done")
```

```stderr
checked
```

```diff-allowed
area = [+/-0.01]
```

```optional-last
done
```

```any-order
ANY: a
ANY: b
```

```ignore-chars chars = " ,"
point*
```

A task answered somewhere else and pushed with git, not graded here,
whose starting code cannot be edited:

```pyking task name = "elsewhere" method = git readonly
# Write this in any language you like.
```

```pyking solution
print("graded by hand")
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
