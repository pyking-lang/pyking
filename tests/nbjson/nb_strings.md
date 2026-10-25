# Working with text

The `text` library holds what a program needs to take strings apart and
put them together: `text.length`, `text.upper`, `text.words`,
`text.join`, `text.replace` and more.

```pyking readonly
import text
s = "Hello, Pyking"
print(text.length(s), text.upper(s), text.words(s))
print(text.join(["a", "b", "c"], "-"), text.replace(s, "Hello", "Bye"))
```

## Shouting

Write a program that reads one line and prints it in capital letters.
Then, with `debug`, it writes `length N`, the number of characters in
the line, for whoever is checking.

```pyking practice name = "shout" stdin = "hello"
import io
import text
print("Add your code here")
```

```stdin visible = true
hello world
```

```stdout visible = true
HELLO WORLD
```

```stderr visible = true
length 11
```

```stdin
Pyking 2026!
```

```stdout
PYKING 2026!
```

```stderr
length 12
```

## Word statistics

Write a program that reads one line of words separated by spaces and
prints three lines: how many words there are, their average length, and
the longest word (the first one, if several are equally long). The
average is rounded to two decimals; an answer within 0.01 of it is
accepted.

    words: 3
    average length: 3.67
    longest: dogs

is what it prints for `dogs and cats`. `float(n)` makes an `Int` a
`Float`, and `math.round` rounds a `Float` to the nearest `Int`.

```pyking practice name = "stats" stdin = "dogs and cats"
import io
import text
print("Add your code here")
```

```pyking solution available = true
import io
import math
import text

words = text.words(io.read_line())
total = loop acc = 0 for w in words:
    acc + text.length(w)
average = float(total) / float(len(words))
longest = loop best = "" for w in words:
    if text.length(w) > text.length(best) then w else best
print("words:", len(words))
print("average length:", float(math.round(average * 100.0)) / 100.0)
print("longest:", longest)
```

```diff-allowed
average length: [+/-0.01]
```

```stdin visible = true
dogs and cats
```

```stdout visible = true
words: 3
average length: 3.67
longest: dogs
```

```stdin
the quick brown fox jumps
```

```stdin
I am here
```

```stdin
the cat sat on a mat
```

```stdout
words: 6
average length: 2.5
longest: the
```
