# Drawing a square

A tinyweb program draws on a *canvas*: `tw.canvas(w, h)` makes one and
answers its id, and `tw.rect(c, x, y, w, h, fill)` fills a rectangle on
it. Colors are in `tinyweb.color`.

```pyking readonly
import tinyweb as tw
import tinyweb.color as color
c = tw.canvas(60, 60)
tw.rect(c, 5, 5, 20, 30, color.blue)
```

## Task: a square of a given size

Read a size from standard input and draw a green square that big, with
its top left corner at (10, 10), on a canvas of 120 × 120 pixels. Then
print the size. The square may be up to two pixels bigger or smaller
than asked for, and so may the number printed. For 50 it looks like
this:

![A green square of side 50](square.png)

```pyking task name = "square" points = 3
print("Add your code here")
```

```pyking solution stdin = "50" save_canvas = "canvas" file = "square.png"
import tinyweb as tw
import tinyweb.color as color
import io
size = int(io.read_line())
c = tw.canvas(120, 120)
tw.rect(c, 10, 10, size, size, color.green)
print(size)
```

```stdin
50
```

```stdin visible = true
25
```

```stdin
100
```

```diff-allowed
rect "canvas" 10 10 [+/-2] [+/-2] 0 "#008000" "" 1.000 1.000
[+/-2]
```

## Quiz

```quiz name = "args" points = 1
What do the last two numbers before the color in `tw.rect(c, 10, 10, 30, 40, color.red)` mean?

* Where its top left corner is.

* Its bottom right corner.

* How wide and how high it is.
```

```answer
- Those are the first two: x and y.
- No, the rectangle is given by a corner and its size.
-> Yes: 30 wide and 40 high.
```
