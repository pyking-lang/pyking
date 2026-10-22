---
title: A house and a sun
---

# A house and a sun

```rules max = 3 pass = 2
The sun and the quiz are graded here. The house is a larger program:
write it in your own repository and push it with git, where it is
graded; its 4 points do not count here.
```

Shapes are drawn in the order the program asks for them, each on top of
what is already there. `tw.polygon(c, points, fill)` fills the polygon
through a list of `tw.Point`s.

```pyking readonly
import tinyweb as tw
import tinyweb.color as color
c = tw.canvas(100, 100)
tw.polygon(c, [tw.Point(10, 90), tw.Point(90, 90), tw.Point(50, 10)], color.green)
```

## A sun

Draw a sun: on a canvas of 200 × 200 painted `color.cyan` (a rectangle
over all of it), a yellow circle of radius 30 centred at (150, 50).

```pyking exercise name = "sun" points = 2
print("Add your code here")
```

```pyking solution
import tinyweb as tw
import tinyweb.color as color

c = tw.canvas(200, 200)
tw.rect(c, 0, 0, 200, 200, color.cyan)
tw.circle(c, 150, 50, 30, color.yellow)
```

## A house

Read a width w and draw a house on a canvas of 300 × 300, in this
order:

1. a brown square w wide, standing on y = 250 with its left side at
   x = 50;
2. a red triangular roof on top of it, from its top left corner and its
   top right corner up to a point w / 2 above the middle of its top;
3. a black door 20 wide and 30 high in the middle of its bottom.

Then print `house of width` and w. The roof's top may be one pixel off.

```pyking exercise name = "house" points = 4 method = git
```

```pyking solution
import tinyweb as tw
import tinyweb.color as color
import io

w = int(io.read_line())
c = tw.canvas(300, 300)
top = 250 - w
tw.rect(c, 50, top, w, w, color.brown)
tw.polygon(c, [tw.Point(50, top), tw.Point(50 + w, top), tw.Point(50 + w / 2, top - w / 2)], color.red)
tw.rect(c, 50 + w / 2 - 10, 220, 20, 30, color.black)
print("house of width", w)
```

```stdin visible = true
100
```

```stdout visible = true
house of width 100
```

```stdin
60
```

```stdin
150
```

```diff-allowed
polygon "canvas" 50 [+/-0] [+/-0] [+/-0] [+/-1] [+/-1] "#ff0000" "" 1.000 1.000
```

## Quiz

```quiz name = "order" points = 1
The house's door is drawn before its walls. What happens?

* The walls cover the door.

* The door is drawn on top of the walls.

* The program is refused.
```

```answer
-> Right: what is drawn later is on top.
- The order the program draws in is the order on the canvas.
- It runs; it only draws something else.
```
