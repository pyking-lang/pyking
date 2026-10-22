---
title: Playing a tone
---

# Playing a tone

tinyweb can play a tone of any pitch with `sound.tone`. Its first
argument is the frequency in hertz -- 440.0 is the A above middle C --
and `at` and `duration` say when it starts and how long it lasts, in
seconds on the page's clock.

```pyking readonly
import tinyweb as tw
import tinyweb.sound as sound
tw.web_init(0)
sound.tone(440.0, duration = 0.25)
print("an A")
```

A note one octave higher has twice the frequency.

## Exercise: a tone and its octave

Write a program that reads a frequency (a `Float`) from standard input
and then

1. plays a sine tone at that frequency, starting now and lasting 0.25
   seconds;
2. plays a square-wave tone one octave higher, starting at 0.5 and
   lasting 0.25 seconds;
3. prints `played` followed by the frequency it read.

What the page is told to play is compared with the solution's.

```pyking exercise name = "octave" points = 2
print("Add your code here")
```

```pyking solution available = true
import io
import tinyweb as tw
import tinyweb.sound as sound
tw.web_init(0)
f = float(io.read_line())
sound.tone(f, duration = 0.25)
sound.tone(f * 2.0, at = 0.5, duration = 0.25, wave = "square")
print("played", f)
```

```stdin visible = true
440
```

```stdout visible = true
played 440.0
```

```stdin
261.5
```

```stdin
110.25
```
