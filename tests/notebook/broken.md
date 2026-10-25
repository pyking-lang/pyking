# A notebook with every mistake test mode reports

``` rules max = 5 pass = 9
Points that do not add up.
```

``` rules
A second rules block.
```

```pyking solution
print("a solution with no task")
```

```pyking task attempts = 0 points = many
print("starting code")
```

```args
1 2
```

```stdin
an input with no output and no solution
```

```pyking practice
print("no solution and nothing to compare with")
```

```pyking practice
print("a solution that prints the wrong thing")
```

```pyking solution
print("right")
```

```stdout
wrong
```

```pyking practice
x := 1
```

```stdout
anything
```

```quiz
Some text that is not an alternative.
* one
[] two
```

```answer
-> first
-> second
- third
```

```quiz points = 1 one_point_correct = true
[] one
[] two
```

```answer
-> first
-> second
```

```quiz one_point_correct = true
* one
* two
```

```answer
-> first
- second
```

```quiz
* only one
```

Something between a quiz and its answer.

```answer
-> lost
```

```stdout
an output under nothing
```

```pyking attempts = 2
print("a cell that takes no attempts")
```

```stdin visible = maybe
input under a cell, with no output after it
```

Something after it.

```pyking error
print("meant to be refused, but it runs")
```

```pyking
print("prints this")
```

```stdout
prints something else
```

A task submitted some other way, a picture with no file to save it
as, and a stdin block that is not whole pieces.

```pyking practice method = svn
print("starting code")
```

```pyking solution save_canvas = "canvas"
print("draws nothing")
```

```stdin lines_per_multi_input = 2
1
2
3
```

A task with the old name for answering in the page and a name with
a space in it, a quiz named as another item is, and events under nothing.

```pyking practice method = code_box name = "two words"
print("starting code")
```

```stdout
starting code
```

```pyking practice name = "twice"
print("starting code")
```

```stdout
starting code
```

```quiz name = "twice"
* One.
```

```answer
-> Right.
```

```events
click "go"
```

The old name for a task, a practice that gives points, a block that is
both, a max_calls that is not (N,name), and a solution that uses a
function more often than its task's max_calls allows.

```pyking exercise
print("old")
```

```stdout
old
```

```pyking practice points = 2
print("points")
```

```stdout
points
```

```pyking task practice
print("both")
```

```stdout
both
```

```pyking task max_calls = (two,rect)
print("limit")
```

```stdout
limit
```

```pyking task max_calls = (1,print)
print("one")
```

```pyking solution
print("one")
print("two")
```
