---
title: Ignored characters
---

# Ignored characters

A point may be printed with or without spaces, commas and brackets
between its numbers. The task says so with two `ignore-chars` blocks,
whose characters are removed from the lines their patterns match, in
the answer's output and the solution's, before they are compared.

## Task: a point

Read two whole numbers, one a line, and print them as a point, then
their sum.

```pyking task name = "point" points = 1
print("Add your code here")
```

```pyking solution
import io
x = int(io.read_line())
y = int(io.read_line())
print("point (" + string(x) + ", " + string(y) + ")")
print("sum:", x + y)
```

```stdin visible = true
1
2
```

```stdin
-30
45
```

```ignore-chars chars = " ,"
point*
```

```ignore-chars chars = "()"
point*
```
