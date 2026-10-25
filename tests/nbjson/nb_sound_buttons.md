---
title: A drum pad
---

# A drum pad

A sample is a short recording -- a drum hit, a clap, a note. tinyweb
ships a few: `kick1.wav`, `snare1.wav`, `hihat1.wav` and `piano_c1.wav`.
`tw.load_sample` loads one once, and `tw.play` plays it, as often as
you like:

```pyking readonly
import tinyweb as tw
tw.web_init(0)
hat = tw.load_sample("hihat1.wav")
tw.play(hat)
tw.play(hat, at = 0.25, volume = 0.5)
```

A button calls a function each time it is clicked. The button's id is
its title, so the test below clicks it by that name.

## Task: two pads

Write a page with two buttons:

- **Drum** plays `kick1.wav` and prints `boom` followed by how many
  times it has been clicked so far;
- **Clap** plays `snare1.wav` at half the volume and prints `clap`.

Load each sample once, before the buttons are made, kick first.

```pyking task name = "pads" points = 2 attempts = 3
import tinyweb as tw
tw.web_init(0)
```

```pyking solution available = true
import tinyweb as tw
tw.web_init(0)
kick = tw.load_sample("kick1.wav")
snare = tw.load_sample("snare1.wav")
var hits = 0
def drum():
    hits := hits + 1
    tw.play(kick)
    print("boom", hits)
def clap():
    tw.play(snare, volume = 0.5)
    print("clap")
tw.button("Drum", on_click = drum)
tw.button("Clap", on_click = clap)
```

```events visible = true
click "Drum"
click "Clap"
click "Drum"
```

```stdout visible = true
boom 1
clap
boom 2
```

```events
click "Clap"
click "Clap"
```

```events
click "Drum"
click "Drum"
click "Drum"
click "Clap"
```
