---
title: Drawing tasks
---

# Drawing tasks

```rules max = 9 pass = 4
Two tasks are graded in the page; the third is submitted with git.
```

## A square

A program reads a size and draws a red square that big on a canvas of
100 × 100 pixels, then prints the size; the square may be up to two
pixels bigger or smaller, and so may the number. For 40 it looks like
this:

![A red square](square.png)

```pyking task points = 2
print("Add your code here")
```

```pyking solution stdin = "40" save_canvas = "canvas" file = "square.png"
import tinyweb as tw
import tinyweb.color as color
import io
size = int(io.read_line())
c = tw.canvas(100, 100)
tw.rect(c, 10, 10, size, size, color.red)
print(size)
```

```stdin lines_per_multi_input = 1
10
20
30
```

```diff-allowed
rect "canvas" 10 10 [+/-2] [+/-2] 0 "#ff0000" "" 1.000 1.000
[+/-2]
```

## Doubling

A program reads two numbers, one per line, and prints each doubled.

```pyking task points = 2
print("Add your code here")
```

```pyking solution
import io
a = int(io.read_line())
b = int(io.read_line())
print(a * 2, b * 2)
```

```stdin lines_per_multi_input = 2 visible = true
1
2
3
4
```

## Submitted elsewhere

Write the same program in any language you like.

```pyking task points = 5 method = git
```

```pyking solution
print("graded by hand")
```
