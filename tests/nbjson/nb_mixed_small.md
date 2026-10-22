# Squares

Write a program that reads a whole number from its input and prints
its square.

```pyking exercise name = "square" points = 2 attempts = 3 stdin = "4"
print("Add your code here")
```

```pyking solution
import io
n = int(io.read_line())
print(n * n)
```

```stdin visible = true
5
```

```stdout visible = true
25
```

```stdin
-3
```

```stdin
0
```

What does your program print for the input `-3`?

```quiz name = "negative" points = 1
* 9

* -9

* Nothing: it fails on a negative number.
```

```answer
-> $(-3) \cdot (-3) = 9$.
- The product of two negative numbers is positive.
- `int` reads a minus sign too.
```
