---
title: Final exam
---

# Final exam

```rules max = 23 pass = 15
The exam has six exercises and four quizzes, worth 23 points. You pass
with **15 points** or more.

Every item has a limited number of attempts, and each failed Submit
costs points. Read each task carefully before you submit.
```

You may use the standard library: `io`, `sys` and `text` below, and
`tinyweb` for the last exercise.

```pyking readonly
import text
print(text.length("exam"), text.char_at("exam", 0), text.words("a b  c"))
```

## Part A: strings and numbers

### A1. Reverse a line (3 points)

Read one line and print it reversed.

```pyking exercise name = "reverse" attempts = 3 points = 3 penalty = 1
import io
line = io.read_line()
print(line)
```

```pyking solution available = true
import io
import text
line = io.read_line()
var out = ""
for k in range(text.length(line)):
    out := text.char_at(line, k) ++ out
print(out)
```

```stdin visible = true
stressed
```

```stdout visible = true
desserts
```

```stdin
a
```

```stdin
Never odd or even
```

### A2. Fizz buzz (3 points)

Read $n$ and print the numbers from 1 to $n$, one per line, except that
a multiple of 3 is printed as `Fizz`, a multiple of 5 as `Buzz` and a
multiple of both as `FizzBuzz`. Pyking has no remainder operator:
`a - a / b * b` is the remainder of `a` by `b`.

```pyking exercise name = "fizz" attempts = 4 points = 3 penalty = 1
print("Add your code here")
```

```pyking solution
import io
def rem(a: Int, b: Int) -> Int:
    a - a / b * b
n = int(io.read_line())
for k in range(1, n + 1):
    if rem(k, 15) == 0:
        print("FizzBuzz")
    else if rem(k, 3) == 0:
        print("Fizz")
    else if rem(k, 5) == 0:
        print("Buzz")
    else:
        print(k)
```

```stdin lines_per_multi_input = 1
1
5
15
16
```

### A3. The longest argument (2 points)

Print how many arguments the program was given, and then the longest of
them (the first one if several are as long). There is always at least
one.

```pyking exercise name = "longest" attempts = 2 points = 2 penalty = 1 args = "a bbb cc"
import sys
print(sys.args())
```

```stdout visible = true
3
bbb
```

```stdin args = "one"
```

```stdout
1
one
```

```stdin args = "same size"
```

```stdout
2
same
```

## Part B: status and debugging

### B1. Refusing a negative number (3 points)

Read an integer. If it is negative, print `negative` and end the program
with exit status 2 (`sys.exit(2)`); otherwise print `ok` and the number.

```pyking exercise name = "status" attempts = 3 points = 3 penalty = 2
print("Add your code here")
```

```pyking solution available = true
import io
import sys
n = int(io.read_line())
if n < 0:
    print("negative")
    sys.exit(2)
print("ok", n)
```

```stdin visible = true
7
```

```stdout visible = true
ok 7
```

```stdin
-3
```

```stdout
negative
```

```stdin
0
```

### B2. A running total (2 points)

Read a line of integers separated by spaces and print their sum. After
adding each number, `debug` the total so far.

```pyking exercise name = "running" attempts = 3 points = 2 penalty = 1
print("Add your code here")
```

```pyking solution
import io
import text
var total = 0
for word in text.words(io.read_line()):
    total := total + int(word)
    debug(total)
print(total)
```

```stdin visible = true
1 2 3
```

```stdout visible = true
6
```

```stderr visible = true
1
3
6
```

```stdin
10
```

```stderr
10
```

## Part C: drawing

### C1. A staircase (3 points)

Read $n$ and draw a staircase of $n$ green steps on a 200 × 200 canvas:
step $k$ (from 0) is a rectangle at $(20k, 20k)$, 20 pixels high and
$200 - 20k$ wide. Print nothing.

```pyking exercise name = "stairs" attempts = 3 points = 3 penalty = 1
import tinyweb as tw
tw.web_init(0)
```

```pyking solution available = false
import io
import tinyweb as tw
import tinyweb.color as color
tw.web_init(0)
n = int(io.read_line())
c = tw.canvas(200, 200)
for k in range(n):
    tw.rect(c, 20 * k, 20 * k, 200 - 20 * k, 20, color.green)
```

```stdin visible = true
3
```

```stdin
1
```

```stdin
10
```

## Part D: quizzes

```quiz name = "binding" attempts = 1 points = 1
Which binding can be updated with `:=`?

* `x = 1`

* `var x = 1`

* `def x() -> Int: 1`
```

```answer
- An `=` binding never changes.
-> A `var` is a mutable variable.
- A function is not a variable.
```

```quiz name = "types" attempts = 2 points = 2 penalty = 1 available = true
Which of these programs are refused by the type checker?

[] `print(1 + 2.0)`

[] `print("a" ++ "b")`

[] `x: Int = "five"`

[] `print(len([1, 2]))`
```

```answer
-> `+` takes two numbers of one type.
- Two strings join with `++`.
-> The annotation says `Int`, the value is a `String`.
- `len` takes a list.
```

```quiz name = "true_of_pyking" points = 3 one_point_correct = true
Which are true of Pyking?

[] Every `match` must cover every case.

[] A program is type-checked before it runs.

[] A name bound with `=` can be updated with `:=`.

[] A function may be used before its `def` in the same block.

[] Every `Int` is 64 bits.
```

```answer
-> The checker refuses a match that misses a case.
-> There is no flag to turn it off.
- Only a `var` can be.
-> Every `def` of a block is visible in all of it.
- An `Int` holds at least 32 bits; past that, overflow is undefined.
```

```quiz name = "exit" attempts = 2 points = 1 penalty = 1
What is the exit status of a program that ends without calling
`sys.exit`?

* 0

* 1

* 2
```

```answer
-> A program that ends normally succeeds.
- That is what a runtime error ends with.
- Only if it says so.
```

Good luck!
