# Animation

`tw.on_frame(f)` asks the page to call `f(t)` before it draws each
frame, where `t` is the time in seconds, a `Float`, since the program
started. An animation draws its whole picture again on every frame, so
it starts by clearing the canvas with `tw.clear`.

```pyking readonly
import tinyweb as tw
import tinyweb.color as color
c = tw.canvas(200, 50)
tw.on_frame((t: Float) => tw.clear(c, if t < 1.0 then color.white else color.gray))
```

## A moving ball

On a canvas of 300 × 100, every frame clears it to black and draws a
white ball of radius 8 at y = 50 that moves 50 pixels a second to the
right from x = 20: at time t its x is 20 + 50 t, turned into an `Int`.
The x may be one pixel off, so rounding is fine too.

```pyking exercise name = "ball" points = 2
print("Add your code here")
```

```pyking solution
import tinyweb as tw
import tinyweb.color as color

c = tw.canvas(300, 100)

def draw(t: Float):
    tw.clear(c, color.black)
    tw.circle(c, 20 + int(t * 50.0), 50, 8, color.white)

tw.on_frame(draw)
```

```events visible = true
frame 0.0
frame 0.5
frame 1.25
```

```events
frame 0.01
frame 0.33
frame 2.99
frame 5.5
```

```diff-allowed
circle "canvas" [+/-1] 50 8 "#ffffff" "" 1.000 1.000
```

## Three frames

On a canvas of 100 × 20, the first three frames each print `frame`,
their number counting from 1, `at` and their time, and draw an orange
bar from (0, 0), 20 high and ten pixels wide for each frame so far.
Later frames do nothing at all.

```pyking exercise name = "three" points = 3
print("Add your code here")
```

```pyking solution
import tinyweb as tw
import tinyweb.color as color

c = tw.canvas(100, 20)
var count = 0

def draw(t: Float):
    if count < 3:
        count := count + 1
        print("frame", count, "at", t)
        tw.rect(c, 0, 0, 10 * count, 20, color.orange)

tw.on_frame(draw)
```

```events
frame 0.0
frame 0.25
```

```stdout
frame 1 at 0.0
frame 2 at 0.25
```

```events visible = true
frame 0.0
frame 0.5
frame 1.0
frame 1.5
frame 2.0
```

```stdout visible = true
frame 1 at 0.0
frame 2 at 0.5
frame 3 at 1.0
```
