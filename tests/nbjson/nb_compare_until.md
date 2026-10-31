---
title: A drum loop that never ends
---

# A drum loop that never ends

A loop that plays forever never finishes, so it cannot be compared
whole. The task's `compare-until` block says how much of it is
compared: every run that checks the task stops once tinyweb's log has
had eight `sdelay` lines, and what came before them is compared.

## Task: the loop

The first line of the input names the drum to play: `kick` or `snare`.
Play it forever, two beats a second (with `tw.sdelay(0.5)`), printing
`beat` and the beat's number, from 1, before each.

```pyking task name = "loop" points = 1
import tinyweb as tw
```

```pyking solution
use mutation
import io
import tinyweb as tw
drum = tw.load_sample(io.read_line() + "1.wav")
var n = 0
while true:
    n := n + 1
    print("beat", n)
    tw.play(drum)
    tw.sdelay(0.5)
```

```stdin visible = true
kick
```

```stdin
snare
```

```compare-until events = 8
sdelay*
```
