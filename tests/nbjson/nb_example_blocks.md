# Examples before a task

An example block shows what a task's solution does with some input,
before the task itself: its stdin, its arguments where it has any, and
what the solution printed, drew, or both.

```example task_name = greet
Ada
```

With arguments, and the output named:

```example task_name = greet args = "--loud twice" output = stdout
Grace
```

What the second task draws, and prints:

```example task_name = bars output = stdout,image
3
```

Only what it draws:

```example task_name = bars output = image
5
```

## Task: a greeting

Read a name and print a greeting; with `--loud` print it in capitals.
Print it once more for every argument after the first.

```pyking task name = "greet" points = 2
print("Add your code here")
```

```pyking solution
import io
import sys
import text
name = io.read_line()
args = sys.args()
greeting = "Hello, " + name + "!"
shown = if len(args) > 0 and args[0] == "--loud" then text.upper(greeting) else greeting
print(shown)
for _ in range(1, len(args)):
    print(shown)
```

```stdin
Linus
```

## Task: bars

Read a number n and draw n bars, then print how many were drawn.

```pyking task name = "bars" points = 2
print("Add your code here")
```

```pyking solution
import io
import tinyweb as tw
n = int(io.read_line())
c = tw.canvas(20 * n + 10, 60)
for i in range(n):
    tw.rect(c, 10 + 20 * i, 10, 10, 40)
print(n, "bars")
```

```stdin
4
```
