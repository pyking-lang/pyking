# Debugging output

`debug` is `print`'s twin: it writes the same way, but to standard
error rather than standard output. It is for messages meant for the
programmer, which is why they are kept apart from what the program
prints.

```pyking readonly
debug("starting")
print("the answer is", 42)
debug("done, answer was", 42)
```

```stdout
the answer is 42
```

```stderr visible = true
starting
done, answer was 42
```

## Tracing a running total

Write a program that reads whole numbers, one per line, until the end
of its input, and prints their total as `total: N`. While it works it
writes, with `debug`, one line `read X total so far Y` per number, so
whoever runs it can follow along. Both what it prints and what it
writes with `debug` are checked.

```pyking practice name = "trace" stdin = "1\n2\n3"
import io
print("Add your code here")
```

```pyking solution available = true
import io
var total = 0
while io.is_eof() == false:
    x = int(io.read_line())
    total := total + x
    debug("read", x, "total so far", total)
print("total:", total)
```

```stdin visible = true
1
2
3
```

```stdout visible = true
total: 6
```

```stderr visible = true
read 1 total so far 1
read 2 total so far 3
read 3 total so far 6
```

```stdin
10
-4
```

```stderr
read 10 total so far 10
read -4 total so far 6
```

```stdin
```

```stdout
total: 0
```

```stderr
```

## A warning on standard error

Write a program that prints `result: 7` and then writes the warning
`warning: this result is made up` with `debug`.

```pyking practice name = "warn"
print("Add your code here")
```

```stdout visible = true
result: 7
```

```stderr visible = true
warning: this result is made up
```
