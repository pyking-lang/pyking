---
title: Circles in a loop
---

# Circles in a loop

```rules max = 6 pass = 4
Two drawing tasks. Each is compared with the teacher's drawing, so
draw the shapes in the order the text asks for.
```

`tw.circle(c, x, y, radius, fill)` fills a circle centred at (x, y). A
`for` loop over a list of colors draws one circle per color; a `var`
keeps the position, and `:=` moves it on.

```pyking
use mutation

import tinyweb as tw
import tinyweb.color as color
c = tw.canvas(200, 60)
var x = 30
for fill in [color.purple, color.teal]:
    tw.circle(c, x, 30, 20, fill)
    x := x + 50
```

## A row of colors

Read two numbers, one per line: the x of the first circle and the gap
between two centres. Draw five circles of radius 15 at y = 50 on a canvas
of 400 × 100, in the colors red, orange, yellow, green and blue, from
left to right. Then print `last at` and the x of the last one. A centre
may be one pixel off.

```pyking task name = "row" points = 4 penalty = 1 stdin = "20\n40"
print("Add your code here")
```

```pyking solution available = true
use mutation

import tinyweb as tw
import tinyweb.color as color
import io

start = int(io.read_line())
gap = int(io.read_line())
c = tw.canvas(400, 100)
var x = start
for fill in [color.red, color.orange, color.yellow, color.green, color.blue]:
    tw.circle(c, x, 50, 15, fill)
    x := x + gap
print("last at", x - gap)
```

```stdin visible = true
20
40
```

```stdout visible = true
last at 180
```

```stdin
50
70
```

```stdin
0
0
```

```diff-allowed
circle "canvas" [+/-1] 50 15 "#ff0000" "" 1.000 1.000
circle "canvas" [+/-1] 50 15 "#ffa500" "" 1.000 1.000
circle "canvas" [+/-1] 50 15 "#ffff00" "" 1.000 1.000
circle "canvas" [+/-1] 50 15 "#008000" "" 1.000 1.000
circle "canvas" [+/-1] 50 15 "#0000ff" "" 1.000 1.000
last at [+/-1]
```

## Rings

Read a number n and draw n navy rings, two pixels wide, around (100, 100)
on a canvas of 200 × 200: radii 10, 20, ... up to 10 × n, the biggest
first. A ring is a circle filled with `color.none` and drawn with
`stroke = color.navy, width = 2`.

```pyking task name = "rings" points = 2
print("Add your code here")
```

```pyking solution
import tinyweb as tw
import tinyweb.color as color
import io

n = int(io.read_line())
c = tw.canvas(200, 200)
for k in range(n):
    tw.circle(c, 100, 100, 10 * (n - k), color.none, stroke = color.navy, width = 2)
```

```stdin lines_per_multi_input = 1
1
3
6
```
