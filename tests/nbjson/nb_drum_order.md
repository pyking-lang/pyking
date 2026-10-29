---
title: A drum beat, in any order
---

# A drum beat, in any order

Drums started in the same beat sound together, so the order a program
starts them in does not matter, and nor does a pause after the last
beat. The task says so with an `optional-last` block and an `any-order`
block, which loosen how an answer's tinyweb log is compared with the
solution's.

## Task: four beats

The first line of the input names the drums to play: any of `kick`,
`snare` and `hihat`. Play four beats a quarter of a second apart (with
`tw.sdelay(0.25)`): the hihat on every beat, the kick on beats 1 and 3,
and the snare on beats 2 and 4, each only where the input names it.

```pyking task name = "beat" points = 2
import tinyweb as tw
```

```pyking solution
import io
import text
import tinyweb as tw
line = io.read_line()
kick = tw.load_sample("kick1.wav")
snare = tw.load_sample("snare1.wav")
hihat = tw.load_sample("hihat1.wav")
for i in range(4):
    if i > 0:
        tw.sdelay(0.25)
    if text.contains(line, "kick") and i % 2 == 0:
        tw.play(kick)
    if text.contains(line, "snare") and i % 2 == 1:
        tw.play(snare)
    if text.contains(line, "hihat"):
        tw.play(hihat)
```

```stdin visible = true
kick hihat
```

```stdin
snare kick hihat
```

```stdin
snare
```

```optional-last
sdelay*
```

```any-order
BETWEEN: sdelay*
ANY: play "kick*
ANY: play "snare*
ANY: play "hihat*
```
