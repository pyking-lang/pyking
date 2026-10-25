---
title: Waves, written loosely
---

# Waves, written loosely

```rules max=17 pass = 9
Two tasks and one quiz. 17 points; 9 to pass.
```

`math.sin` takes an angle in radians.

```{.pyking .readonly}
import math
print(math.sin(0.0), math.round(math.sin(1.5707963) * 100.0))
```

The short name of the language works too:

```pyk
print("written as pyk")
```


Two blank lines before this paragraph, and a block written with four
backticks, so it can hold a fence of three:

````markdown
```pyking
print("inside")
```
````

```stdin
5
```
```pyking
import io
print(int(io.read_line()) + 1)
```
```stdout
6
```

## Sampling a sine

Read $n$ and print, for $k$ from 0 to $n - 1$, the number $k$ and
$\sin(k / 2)$ rounded to two decimals. A last digit off by one is
fine.

```pyking task name="sine" points = 10 stdin="3" method=inline
print("Add your code here")
```
```pyking solution available=true
import io
import math
n = int(io.read_line())
for k in range(n):
    x = math.sin(float(k) / 2.0)
    print(k, float(math.round(x * 100.0)) / 100.0)
```


```stdin visible=true
3
```

```stdout visible = true
0 0.0
1 0.48
2 0.84
```

```stdin
8
```

```diff-allowed
[+/-0] [+/-0.01]
```

## Doubling

Read a number and print it doubled.

```pyking points = 2 task name='double' attempts=3
print("Add your code here")
```

```stdin visible = true
21
```

```stdout
42
```

```stdin
-4
```

```stdout
-8
```

## A quiz

```quiz points=5 name='period'
What is the period of `math.sin`?

* $\pi$

* $2\pi$

* $1$
```
```answer
- That is half of it.
-> sin(x + 2π) = sin(x).
- It is not measured in whole numbers.
```
