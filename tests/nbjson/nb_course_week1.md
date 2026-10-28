---
title: "Week 1: input, output and arguments"
---

# Week 1: input, output and arguments

```rules max = 12 pass = 8
This week has three tasks and three quizzes, worth 12 points in
all. You pass the week with **8 points** or more.

- A task is checked against its tests when you press Submit.
- Running a cell with the play button is free; only Submit counts.
```

This week is about the three ways a program meets the world:

1. what it **prints**, with `print`;
2. what it **reads** from standard input, with `io.read_line`;
3. the **arguments** it was started with, with `sys.args()`.

## Printing

`print` takes any number of values and writes them on one line,
separated by single spaces[^print].

```pyking
print("The answer is", 6 * 7)
print([1, 2, 3], (true, "yes"))
```

[^print]: Strings are printed without their quotes, except inside a
    list or a tuple.

| Value | Printed as |
|:------|:-----------|
| `42` | `42` |
| `2.5` | `2.5` |
| `true` | `true` |
| `"hi"` | `hi` |
| `["hi"]` | `["hi"]` |

## Reading input

`io.read_line()` answers the next line of standard input, without its
line ending. `int` turns a line into a number:

```stdin
20
22
```

```pyking
import io
a = int(io.read_line())
b = int(io.read_line())
print(a + b)
```

The sum of the first $n$ numbers is $\frac{n(n+1)}{2}$, which the next
cell checks for $n = 100$:

```math
\sum_{k=1}^{100} k = \frac{100 \cdot 101}{2} = 5050
```

```pyking readonly
use mutation

var total = 0
for k in range(1, 101):
    total := total + k
print(total, 100 * 101 / 2)
```

```stdout visible = true
5050 5050
```

## Task 1: sum and largest

The first line of the input is a count $n \geq 1$, and the $n$ lines
after it hold one integer each. Print their sum and then the largest of
them, on one line.

```pyking task name = "sum_max" points = 3 attempts = 5
import io
print("Add your code here")
```

```pyking solution available = true
use mutation

import io
n = int(io.read_line())
first = int(io.read_line())
var total = first
var largest = first
for k in range(1, n):
    x = int(io.read_line())
    total := total + x
    if x > largest:
        largest := x
print(total, largest)
```

```stdin visible = true
3
4
9
2
```

```stdout visible = true
15 9
```

```stdin
1
-7
```

```stdin
5
-1
-2
-3
-4
-5
```

## Arguments

`sys.args()` is the list of the program's arguments, as strings.

```args
one "two words" three
```

```pyking
import sys
print(sys.args(), len(sys.args()))
```

## Task 2: greetings

Print `Hello, NAME!` for each argument, in order, and then a line
saying how many there were: `2 names`. Here there is no solution to
compare with, only the expected output.

```pyking task name = "greet" points = 2 args = "Ada"
print("Add your code here")
```

```stdout
Hello, Ada!
1 names
```

```stdin args = "Ada Grace"
```

```stdout visible = true
Hello, Ada!
Hello, Grace!
2 names
```

```stdin args = "\"Alan Turing\" Barbara Edsger"
```

```stdout
Hello, Alan Turing!
Hello, Barbara!
Hello, Edsger!
3 names
```

## Task 3: squares

Read one integer and print its square. Each line of the test below is a
test of its own.

```pyking task name = "square" points = 2
print("Add your code here")
```

```pyking solution
import io
n = int(io.read_line())
print(n * n)
```

```stdin lines_per_multi_input = 1 visible = true
3
-4
0
12
```

## Quizzes

Which function reads a line of standard input?

```quiz name = "reader" points = 1
* `print`

* `io.read_line`

* `sys.args`
```

```answer
- `print` writes, it does not read.
-> It answers the next line, without its line ending.
- That is the program's arguments.
```

```quiz name = "values" points = 2 attempts = 2 penalty = 1 available = true
Which of these print exactly `hi`?

[] `print("hi")`

[] `print(["hi"])`

[] `print("h" + "i")`

[] `print('hi')`
```

```answer
-> A string is printed without its quotes.
- A list shows its strings quoted: `["hi"]`.
-> `+` joins two strings.
- Pyking strings are written in double quotes.
```

```quiz name = "args" points = 2 one_point_correct = true
A program is started with the arguments `a "b c"`. Which are true?

[] `len(sys.args())` is 2.

[] `sys.args()` holds the program's own name first.

[] The second argument is `b c`.

[] `sys.args()` is a list of `Int`.
```

```answer
-> The quotes keep `b c` together.
- Only the arguments are there.
-> The quotes are not part of it.
- Arguments are strings.
```

That is all for this week. See you in week 2!
