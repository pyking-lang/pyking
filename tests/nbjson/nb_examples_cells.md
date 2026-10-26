# Cells and their examples

This page is mostly cells to run, each shown with what it reads and what
it prints. Change a cell and run it again to see what changes.

## Input written before a cell

A `stdin` block just before a cell is the input it starts with:

```stdin
Ada Lovelace
1815
```

```pyking
import io
name = io.read_line()
year = int(io.read_line())
print(name, "was born in", year)
```

And an `args` block gives it arguments:

```args
--verbose "two words" 3
```

```pyking
import sys
for a in sys.args():
    print("argument:", a)
```

Both can come before one cell:

```stdin
hello
```

```args
x y
```

```pyking
import io
import sys
print(io.read_line(), len(sys.args()))
```

## Examples written after a cell

A cell can show what it prints, as if it had already run:

```pyking
for k in range(3):
    print(k, k * k)
```

```stdout visible = true
0 0
1 1
2 4
```

Or keep it hidden, for the page's own checking:

```pyking
print("checked, not shown")
```

```stdout
checked, not shown
```

Several examples, each with its input. The first shows its input, the
second does not:

```pyking
import io
n = int(io.read_line())
debug("read", n)
print(n * 10)
```

```stdin visible = true
4
```

```stdout visible = true
40
```

```stderr visible = true
read 4
```

```stdin
7
```

```stdout
70
```

```stderr
read 7
```

## A cell with events

A page that counts clicks, clicked twice once its top level has run:

```pyking
use mutation

import tinyweb as tw
tw.web_init(0)
var n = 0
def more():
    n := n + 1
    print("clicked", n)
tw.button("Click me", on_click = more)
```

```events visible = true
click "Click me"
click "Click me"
```

```stdout visible = true
clicked 1
clicked 2
```

## A cell for the playground

On the website this cell gets a link that opens it in the playground:

```pyking playground
def greet(name: String) -> String:
    "Hello, " + name + "!"
print(greet("playground"))
```

A cell can be fenced with tildes too:

~~~pyking
print("fenced with tildes")
~~~

## Other languages

The same loop in Python:

```python
for k in range(3):
    print(k, k * k)
```

and in C:

```c
#include <stdio.h>
int main(void) {
    for (int k = 0; k < 3; k++) printf("%d %d\n", k, k * k);
    return 0;
}
```

A plain block is shown as it is:

```
0 0
1 1
2 4
```

<div class="note"><b>Note:</b> a block of HTML is passed through as it
is.</div>

## Your turn

Read a number $n$ and print the first $n$ squares, one per line, as the
loop above does.

```pyking task points = 1
print("Add your code here")
```

```pyking solution available = true
import io
n = int(io.read_line())
for k in range(n):
    print(k, k * k)
```

```stdin visible = true
3
```

```stdout visible = true
0 0
1 1
2 4
```

```stdin
0
```

```stdin
6
```
