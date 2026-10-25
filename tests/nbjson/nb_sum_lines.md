# Numbers from standard input

`int(s)` turns a string into an `Int`; a string that is not a number
gives `0`.

```pyking readonly stdin = "41\n"
import io
n = int(io.read_line())
print(n + 1)
```

## Adding two numbers

Write a program that reads two whole numbers, one per line, and prints
`A + B = SUM`. For the input

    3
    4

it prints `3 + 4 = 7`. Each pair of lines below is a test of its own.

```pyking practice name = "sum" stdin = "3\n4"
import io
print("Add your code here")
```

```pyking solution
import io
a = int(io.read_line())
b = int(io.read_line())
print(a, "+", b, "=", a + b)
```

```stdin lines_per_multi_input = 2
3
4
10
-20
0
0
123456
654321
```

```stdin visible = true
5
6
```

```stdout visible = true
5 + 6 = 11
```

## Squares

Write a program that reads one whole number `N` and prints `N squared is
SQUARE`. A negative number squares to a positive one.

```pyking practice name = "square" stdin = "9"
import io
print("Add your code here")
```

```pyking solution available = true
import io
n = int(io.read_line())
print(n, "squared is", n * n)
```

```stdout
9 squared is 81
```

```stdin lines_per_multi_input = 1
0
1
-3
12
1000
```
