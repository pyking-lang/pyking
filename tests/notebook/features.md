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
