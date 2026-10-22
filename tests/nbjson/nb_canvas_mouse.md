# Drawing with the mouse

A canvas can call a function when the reader uses the mouse on it.
`tw.on_click(c, f)` calls `f(x, y)` with where it was clicked, measured
from the canvas's top left corner. `tw.on_press`, `tw.on_move` and
`tw.on_release` do the same for the button going down, the pointer
moving and the button coming up.

```pyking
import tinyweb as tw
import tinyweb.color as color
c = tw.canvas(150, 80)
tw.on_click(c, (x: Int, y: Int) => tw.circle(c, x, y, 3, color.black))
```

## Dots

Make a canvas of 200 × 200 and paint it light grey: a rectangle over
all of it, of `color.hex(0xeeeeee)`. Each click draws a red dot of
radius 5 where it was clicked and prints `dot at`, x and y.

```pyking exercise name = "dots" points = 2
print("Add your code here")
```

```pyking solution
import tinyweb as tw
import tinyweb.color as color

c = tw.canvas(200, 200)
tw.rect(c, 0, 0, 200, 200, color.hex(0xeeeeee))

def clicked(x: Int, y: Int):
    tw.circle(c, x, y, 5, color.red)
    print("dot at", x, y)

tw.on_click(c, clicked)
```

```events visible = true
mouse "canvas" 10 20
```

```stdout visible = true
dot at 10 20
```

```events
mouse "canvas" 100 100
mouse "canvas" 0 199
mouse "canvas" 150 30
```

## Lines

On a canvas of 300 × 200, a line is drawn by pressing the button,
moving and letting go: from where it was pressed to where it was
released, blue and three pixels wide. Print `line from`, the start and
`to`, the end, once the line is drawn. Moving the pointer draws nothing.
Before the first press, a line ends where the last one started from;
start with (0, 0).

```pyking exercise name = "lines" points = 3
print("Add your code here")
```

```pyking solution
import tinyweb as tw
import tinyweb.color as color

c = tw.canvas(300, 200)
var start = tw.Point(0, 0)

def pressed(x: Int, y: Int):
    start := tw.Point(x, y)

def released(x: Int, y: Int):
    tw.line(c, start.x, start.y, x, y, color.blue, width = 3)
    print("line from", start.x, start.y, "to", x, y)

tw.on_press(c, pressed)
tw.on_release(c, released)
```

```events
press "canvas" 10 20
move "canvas" 30 30
release "canvas" 50 60
```

```events visible = true
press "canvas" 0 0
release "canvas" 299 199
press "canvas" 100 10
move "canvas" 120 40
move "canvas" 140 70
release "canvas" 150 100
```

```events
release "canvas" 40 40
```
