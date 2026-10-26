# FizzBuzz and friends

```rules max = 8 pass = 5
Solve the two tasks in the page: FizzBuzz is worth 5 points and the
countdown 3, and you pass with 5. Each failed Submit costs a point. The
multiplication table is handed in with git and graded there.
```

Pyking has no remainder operator, but `/` on two `Int`s truncates, so
the remainder of `a` divided by `b` is `a - (a / b) * b`:

```pyking readonly
def rem(a: Int, b: Int) -> Int:
    return a - (a / b) * b

print(rem(10, 3), rem(9, 3), rem(7, 5))
```

## FizzBuzz

Read a whole number `N` and print the numbers from 1 to `N`, one per
line, except that a multiple of 3 is printed as `Fizz`, a multiple of 5
as `Buzz`, and a multiple of both as `FizzBuzz`. You have three tries.

```pyking task name = "fizzbuzz" attempts = 3 points = 5 penalty = 1 stdin = "15"
import io
print("Add your code here")
```

```pyking solution available = true
import io

def rem(a: Int, b: Int) -> Int:
    return a - (a / b) * b

def word(i: Int) -> String:
    if rem(i, 15) == 0:
        return "FizzBuzz"
    if rem(i, 3) == 0:
        return "Fizz"
    if rem(i, 5) == 0:
        return "Buzz"
    return string(i)

n = int(io.read_line())
for i in range(n):
    print(word(i + 1))
```

```stdin visible = true
5
```

```stdout visible = true
1
2
Fizz
4
Buzz
```

```stdin
15
```

```stdin
1
```

```stdin
31
```

## Countdown

Read a whole number `N` and count down from it: print `N`, `N - 1`, ...
down to `1`, one per line, then `Liftoff!`. For `0` it prints only
`Liftoff!`. The solution is not shown, and you have two tries.

```pyking task name = "countdown" attempts = 2 points = 3 penalty = 1 stdin = "3"
import io
print("Add your code here")
```

```pyking solution available = false
use mutation

import io
var i = int(io.read_line())
while i > 0:
    print(i)
    i := i - 1
print("Liftoff!")
```

```stdin visible = true
3
```

```stdout visible = true
3
2
1
Liftoff!
```

```stdin
0
```

```stdout
Liftoff!
```

```stdin
10
```

## A multiplication table

Extend the program below, in your git repository, so that after its
first line it prints the table of `N` from 1 to 5, as `N x K = P`:

    table of 7
    7 x 1 = 7
    7 x 2 = 14
    ...
    7 x 5 = 35

```pyking practice name = "table" readonly method = git stdin = "7"
import io
n = int(io.read_line())
print("table of", n)
```

```pyking solution
import io
n = int(io.read_line())
print("table of", n)
for k in range(5):
    print(n, "x", k + 1, "=", n * (k + 1))
```

```stdin
7
```

```stdin
-2
```
