---
title: Highlighting a notebook
---

# Squares and greetings

Some *prose* with `inline code`, a [link](https://example.org) and a list:

- one
- two

```rules max = 2 pass = 1
One task.
```

A cell, with what it prints:

```pyking
def square(x: Int) -> Int:
    return x * x

print(square(4))
```

```stdout
16
```

A fragment that is not run:

```pyking norun
    if x > 0:
        print("positive")
```

A cell that is refused:

```pyk error
x: Int = "not a number"
```

A cell reading its input:

```stdin
Ada
```

```pyking readonly
import io
print("Hello, " + io.prompt_line(""))
```

**Task.** Write `double`.

```pyking task name = "double" points = 1
def double(n: Int) -> Int:
    return 0  # change this
```

```pyking solution
def double(n: Int) -> Int:
    return 2 * n
```

```quiz name = "q" points = 1
* yes

* no
```

```answer
-> Right.
- Wrong.
```

That is all.
