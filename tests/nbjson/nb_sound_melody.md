---
title: A melody from note names
---

# A melody from note names

`sound.note` turns a note's name into its frequency: `"A4"` is 440 Hz,
`"C4"` is middle C, and `#` or `b` after the letter makes it sharp or
flat.

```pyking readonly
import tinyweb.sound as sound
print(sound.note("A4"), sound.note("A5"))
```

```stdout visible = true
440.0 880.0
```

`sound.tempo` sets the beats per minute of the page's beat. At a tempo
of `bpm`, one beat lasts $60 / bpm$ seconds, so the note number $k$
(counting from 0) of a melody of one-beat notes starts at $k \cdot 60 / bpm$.

## Exercise: play a melody

The first line of the input is the tempo, a `Float`, and the second the
melody: note names separated by spaces. Write a program that

1. sets the tempo with `sound.tempo`;
2. plays every note as a `"triangle"` tone one beat long, the first at
   time 0.0 and each next one a beat later;
3. prints how many notes it played and how long the melody is, in
   seconds, as `4 notes, 2.67 seconds`.

The times and the length may be off by a hundredth of a second, so they
may be rounded.

```pyking exercise name = "melody" points = 3 attempts = 4
print("Add your code here")
```

```pyking solution
import io
import text
import tinyweb as tw
import tinyweb.sound as sound
tw.web_init(0)
bpm = float(io.read_line())
notes = text.words(io.read_line())
beat = 60.0 / bpm
sound.tempo(bpm)
var k = 0
for name in notes:
    sound.tone(sound.note(name), at = float(k) * beat, duration = beat, wave = "triangle")
    k := k + 1
print(k, "notes,", float(k) * beat, "seconds")
```

```stdin visible = true
120
A4 B4 C5
```

```stdout visible = true
3 notes, 1.5 seconds
```

```stdin
90
C4 E4 G4 C5
```

```stdin
60
G3
```

```diff-allowed
tone "" "triangle" [+/-0.01] [+/-0.01] [+/-0.01] 0.5 0.0 0
[+/-0] notes, [+/-0.01] seconds
```
