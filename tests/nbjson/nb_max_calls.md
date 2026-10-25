# Loops instead of copies

A task may say how often an answer may name a function: `max_calls =
(1,rect)` lets the answer write `rect` once, outside comments and
strings, so three squares have to be drawn by a loop.

## Task: three squares

Draw three blue squares, 20 × 20 pixels, at (10, 10), (40, 10) and
(70, 10), on a canvas of 100 × 40 pixels.

```pyking task name = "squares" points = 2 max_calls = (1,rect)
import tinyweb as tw
import tinyweb.color as color
c = tw.canvas(100, 40)
```

```pyking solution
import tinyweb as tw
import tinyweb.color as color
c = tw.canvas(100, 40)
for k in range(3):
    tw.rect(c, 10 + 30 * k, 10, 20, 20, color.blue)
```

## Practice: counting

Print the numbers from 1 to the number read, each on its own line,
naming `print` at most twice and `string` at most once.

```pyking practice name = "count" max_calls = (2,print) (1,string)
import io
n = int(io.read_line())
```

```pyking solution
import io
n = int(io.read_line())
for k in range(1, n + 1):
    print(k)
```

```stdin visible = true
3
```

```stdin
1
```
