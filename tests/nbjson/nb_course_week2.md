---
title: "Week 2: drawing, events and debugging"
---

# Week 2: drawing, events and debugging

```rules max = 14 pass = 7
Five items are graded in the page, worth 10 points. The last task
is handed in with git and graded by the teachers, for 4 more.
```

## Drawing on a canvas

`tw.canvas(w, h)` makes a canvas and answers its id; the shapes take
that id first. `x` grows to the right and `y` downwards.

```pyking
import tinyweb as tw
import tinyweb.color as color
tw.web_init(0)
c = tw.canvas(120, 60)
tw.rect(c, 10, 10, 40, 40, color.blue)
tw.circle(c, 85, 30, 20, color.orange)
```

### Task: a row of beads

Read a number $n$ and draw $n$ red circles of radius 10 on a canvas of
300 × 40 pixels: the first centred at (20, 20) and each next one 30
pixels further right. Then print `n beads`.

```pyking task name = "beads" points = 2
import tinyweb as tw
tw.web_init(0)
```

```pyking solution available = true
import io
import tinyweb as tw
import tinyweb.color as color
tw.web_init(0)
n = int(io.read_line())
c = tw.canvas(300, 40)
for k in range(n):
    tw.circle(c, 20 + 30 * k, 20, 10, color.red)
print(n, "beads")
```

```stdin visible = true
3
```

```stdout visible = true
3 beads
```

```stdin
0
```

```stdin
9
```

### Task: a dot that moves

Draw a canvas of 100 × 100 pixels with a black dot of radius 5 at
(50, 50), and two buttons, **Left** and **Right**. Each click moves the
dot 10 pixels: clear the canvas to white, draw the dot where it now is
and print its `x`.

```pyking task name = "mover" points = 3 attempts = 3 penalty = 1
import tinyweb as tw
tw.web_init(0)
```

```pyking solution
import tinyweb as tw
import tinyweb.color as color
tw.web_init(0)
c = tw.canvas(100, 100)
var x = 50
def draw():
    tw.clear(c)
    tw.circle(c, x, 50, 5)
def left():
    x := x - 10
    draw()
    print(x)
def right():
    x := x + 10
    draw()
    print(x)
tw.circle(c, x, 50, 5)
tw.button("Left", on_click = left)
tw.button("Right", on_click = right)
```

```events visible = true
click "Right"
click "Right"
click "Left"
```

```stdout visible = true
60
70
60
```

```events
click "Left"
click "Left"
click "Left"
click "Left"
```

```events
```

## Debugging with `debug`

`debug` prints like `print`, but to standard error, so what a program
prints stays its own:

```pyking
debug("starting")
print(1 + 1)
debug("done")
```

```stdout
2
```

```stderr visible = true
starting
done
```

### Task: a traced factorial

Read $n$ and print $n!$, computed by a recursive function that calls
`debug("fact", k)` each time it is called with `k`. What `debug` writes
is checked too.

```pyking task name = "trace" points = 2
def fact(k: Int) -> Int:
    1
print(fact(3))
```

```pyking solution
import io
def fact(k: Int) -> Int:
    debug("fact", k)
    if k <= 1 then 1 else k * fact(k - 1)
print(fact(int(io.read_line())))
```

```stdin visible = true
3
```

```stdout visible = true
6
```

```stderr visible = true
fact 3
fact 2
fact 1
```

```stdin
1
```

```stderr
fact 1
```

```stdin
6
```

## Quizzes

```quiz name = "where" points = 1
Where does `debug` write?

* To standard output, like `print`.

* To standard error.

* Nowhere unless the program is run in a debugger.
```

```answer
- Then it could not be told from the program's own output.
-> So the program's output stays what it was.
- It always writes.
```

Which of these move the dot of the task above to the right?

```quiz name = "coords" points = 2 attempts = 2
[] Drawing it with a bigger `x`.

[] Drawing it with a bigger `y`.

[] Drawing it with a smaller `x`.

[] Clearing the canvas first and drawing it with a bigger `x`.
```

```answer
-> `x` grows to the right; the old dot stays where it was, too.
- `y` grows downwards.
- That moves it left.
-> And the old dot is gone.
```

## Handed in with git

Write a program that draws a chessboard of 8 × 8 squares in any
language, commit it and push it to your course repository.

```pyking task name = "chess" points = 4 method = git
```

```pyking solution
import tinyweb as tw
import tinyweb.color as color
tw.web_init(0)
c = tw.canvas(160, 160)
for row in range(8):
    for col in range(8):
        if (row + col) / 2 * 2 < row + col:
            tw.rect(c, col * 20, row * 20, 20, 20, color.black)
print("done")
```
