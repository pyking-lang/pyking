---
title: Notebook
description: Write Pyking notebooks in Markdown, with runnable cells, tasks, quizzes and points, and check them from the command line.
sidebar:
  order: 3
  group: Tools
---

A Pyking notebook is a Markdown file. Its text is shown as a page, and
each ```` ```pyking ```` block in it is a **cell**: a program the
reader can edit and run in the browser. Other blocks turn the notebook
into an assignment, with tasks a student solves in the page, quizzes,
and points.

Notebooks are meant for teaching and for exploring. The file is the
notebook: you write it in any editor, keep it in git, and it still reads
well in any Markdown viewer.

As in the [playground](/documentation/playground/), the cells run in
the browser with the Pyking interpreter. **Nothing runs on a server**;
`pyk` only hands the browser the files.

## Running a notebook

| Command | What it does |
|---|---|
| `pyk notebook book.md` | serves the notebook and prints a link to open |
| `pyk notebook book.md --mode teacher` | shows every solution, test and answer, and the problems test mode finds |
| `pyk notebook book.md --mode test` | serves nothing: checks the notebook and prints each problem |
| `pyk notebook book.md --port 8100` | serves it on port 8100 |
| `pyk notebook book.json` | the same, for a notebook in its JSON form |

`--mode student` is the default.

`pyk notebook` watches the file. Save a change in your editor and the
page reloads, scrolled where it was. A student's progress is kept over
the reload, except for a task or quiz whose block you changed.

Links to other `.md` files beside the notebook open as notebooks too,
and images load from the notebook's own directory.

## Using a notebook

| | |
|---|---|
| **▶** beside a cell | runs it |
| Shift+Enter in a cell, or in its stdin or args field | runs it and moves to the next cell |
| Ctrl+Enter (Cmd+Enter on a Mac) | runs it and stays |
| Escape | leaves the cell |
| **■** while it runs | stops it |
| **reset**, shown once a cell is edited | puts back the code the notebook has |

Cells run one at a time. `[n]` beside a cell counts runs across the
page, as in Jupyter, and `[*]` marks a cell that is waiting or running.
What a cell prints appears under it as it is printed. An error is shown
under the cell, in the words `pyk` uses, and underlined in the code.

Edits to a cell last until the page is reloaded; the file is never
changed. Every cell, and every input and output box, has a **copy**
button in its top right corner, shown while the pointer is over it.

## Prose

Everything outside the notebook's blocks is Markdown, as on GitHub:
headings, emphasis, inline code, links, images, lists and task lists,
tables, quotes, footnotes, rules and HTML. A fenced block in another
language is shown highlighted. A front matter `title:` names the page;
without it, the first `#` heading does. The headings, down to `###`,
are listed in a contents sidebar.

Callouts and math are written like this:

````markdown
---
title: Week 1
---

# Squares

> [!NOTE]
> Each cell is a program of its own.

The square of $n$ is $n^2$, and

$$\sum_{k=1}^{n} k = \frac{n(n+1)}{2}$$

```math
(a + b)^2 = a^2 + 2ab + b^2
```
````

The callouts are `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]` and
`[!CAUTION]`. Math is typeset with KaTeX: `$…$` inline, and `$$…$$` or
a ```` ```math ```` block for display. `$5 and $6` stays text.

## Cells

A ```` ```pyking ```` block (or ```` ```pyk ````) is a cell. A word after
`pyking` changes it:

````markdown
```pyking
print("Hello", "world", 2026)
```

```pyking readonly
print(1 + 2)
```

```pyking error
x = 1
x := 2
```

```pyking norun
def f(x): ...
```
````

| Word after `pyking` | The cell is |
|---|---|
| (none) | editable and runnable |
| `readonly` | runnable, but not editable |
| `error` | meant to be refused: the error is shown as the expected result |
| `norun` | highlighted code only, not run, for a fragment |
| `playground` | on this website, given a Try in playground button; a notebook ignores it |

Each cell is **a whole program**, run on its own. A name defined in one
cell is not seen in the next, and a cell that uses `var` or `:=` needs
its own `use mutation` line:

````markdown
```pyking
use mutation

var total = 0
for n in range(1, 11):
    total += n
print(total)
```
````

A cell may import the standard library.

### A cell's input

A cell whose program reads standard input (`io.read_line`, `io.read`,
`io.is_eof`) shows a **stdin** field above its code, and one that reads
`sys.args()` shows an **args** field. The reader types into them. The
notebook can fill them in, on the cell's header:

````markdown
```pyking stdin = "Ada" args = "first 'second argument'"
import io
import sys
print("hello", io.read_line(), sys.args())
```
````

or in a ```` ```stdin ```` or ```` ```args ```` block right before the
cell, which is not shown on its own:

````markdown
```stdin
Ada
Grace
```

```pyking
import io
print("hello", io.read_line())
print("hello", io.read_line())
```
````

A value on a header is a word or a quoted string, in which `\n` is a new
line. Arguments are split at spaces, with quotes keeping a space inside
one. What the notebook gives is only where the fields start: the reader
can change it.

### What a cell prints

A ```` ```stdout ```` block after a cell says what the cell prints, and
a ```` ```stderr ```` block what it writes with `debug`. Test mode
checks that the cell does print that. They are hidden unless they say
`visible = true`; a visible one reads as if the cell had already run,
until the reader runs it. A ```` ```stdin ```` block between the cell
and its output is the input the output was made from.

````markdown
```pyking
import io
debug("to stderr")
print(io.read_line())
```

```stdin
echo me
```

```stdout visible = true
echo me
```

```stderr
to stderr
```
````

A cell that checks but may be wrong shows its warnings, such as a name
never used, above what it prints. `pyk notebook -Wall book.md`, or any
other of `pyk`'s `-W` flags, says which warnings are shown.

### tinyweb in a cell

A cell that uses `tinyweb` shows its page under the cell: canvases,
buttons, sliders and sound. The program goes on running after its last
line, so a click calls back the function it was given, until the cell
runs again, another cell runs, or **■** is pressed.

````markdown
```pyking
import tinyweb as tw

tw.web_init(0)
tw.label("Hello from a page")
```
````

An ```` ```events ```` block after such a cell is what its page is sent
when test mode runs it: one event a line, as under
[Tests](#tests) below.

## Assignments

A notebook becomes an assignment with tasks the student solves in the
page, quizzes they answer, and points that add up to a pass. A bar at
the top and the end of the page says how many are solved, the points,
and whether they pass. Its **start over** forgets every answer.

A student's progress, their code, their choices, the attempts used and
the points, is kept in their browser, per notebook.

### The rules

````markdown
```rules max = 10 pass = 8
Solve all the tasks and quizzes. Each failed Submit costs a point.
```
````

The rules are shown in a box at the top, with `max` and `pass`. A
notebook has at most one rules block. `max` must be the sum of the
`points` of every task and quiz, and a student passes with `pass`
points or more.

### Tasks and practices

The prose before a ```` ```pyking task ```` block states the task. The
block holds the code the student starts from, which must run. After it
come an optional solution and the tests:

````markdown
Print the square of the number on standard input.

```pyking task name = "square" points = 2 attempts = 3 penalty = 1
print("Add your code here")
```

```pyking solution available = true
import io
n = int(io.read_line())
print(n * n)
```

```stdin visible = true
4
```

```stdout visible = true
16
```

```stdin
-3
```
````

That task has two tests: `4`, which the student can see with what it
should print, and `-3`, which is hidden.

**Submit**, under the task, runs the student's code on every test. Where
there is a solution, it runs too, on the same input, and the two must
print the same, draw the same with `tinyweb`, and end with the same exit
status. Without a solution, the student's output must match the stdout
and stderr blocks. Spaces at the end of a line and blank lines at the
end do not count. Each run may take ten seconds. Running the cell with
**▶** is free; only a failed Submit uses an attempt.

When a Submit fails, the red box says why, and **See result diff** shows
the first test that differed: its input, the two outputs side by side,
and, for a `tinyweb` program, what each one drew. A solved task turns
green.

| Task header | Means | Default |
|---|---|---|
| `name = "…"` | the task's name: letters, digits, `_` and `-`, unique in the notebook | none |
| `points = N` | what solving it gives | none: solved or not |
| `attempts = N` | how many times Submit may fail before the task is failed | no limit |
| `penalty = N` | points taken off for each failed Submit, never below 0 | 0 |
| `stdin = "…"`, `args = "…"` | the input the cell starts with, and that a test without its own uses | empty |
| `readonly` | the starting code cannot be edited | editable |
| `method = inline` or `git` | answered in the page, or elsewhere and pushed with git | `inline` |
| `max_calls = (N,name)` | the answer may write `name` at most N times; several as `(2,rect) (1,circle)` | no limit |

A ```` ```pyking practice ```` block is a task that gives no points. It
is titled "Practice", takes no `points` or `penalty`, and is otherwise
a task:

````markdown
Print `Hello, world!`.

```pyking practice name = "hello"
print("")
```

```stdout visible = true
Hello, world!
```
````

#### The solution

| Solution header | Means | Default |
|---|---|---|
| `available = true` | a student may press **Show a solution** to see it | `false`: never shown to a student |
| `run_on_submit = true` | Submit first runs the answer in its cell, so the student sees and hears it | `false`: Submit checks quietly |
| `readonly` | cannot be edited where shown | editable |
| `stdin = "…"`, `args = "…"` | its input when it runs on its own | the task's |
| `save_canvas = "c"`, `file = "x.png"` | the `tinyweb` canvas `c` it draws is saved as `x.png` beside the notebook, for the prose to show | none |

#### Tests

A test is a ```` ```stdin ```` block, an ```` ```events ```` block, a
```` ```stdout ```` block or a ```` ```stderr ```` block, or several of
them in that order. A test with no stdin block runs on the task's own
input. Each takes `visible = true` to be shown to the student.

| Block | Header |
|---|---|
| ```` ```stdin ```` | `args = "…"`: the test's arguments; `lines_per_multi_input = N`: a test for every N lines, each compared with the solution |
| ```` ```events ```` | events sent to a `tinyweb` page once the program's top level has ended |
| ```` ```stdout ```` | what the program prints |
| ```` ```stderr ```` | what the program writes with `debug`; compared only where a test has one |

````markdown
Add the two numbers on standard input.

```pyking task name = "add"
print(0)
```

```pyking solution
import io
a = int(io.read_line())
b = int(io.read_line())
print(a + b)
```

```stdin lines_per_multi_input = 2
1
2
10
20
```
````

Here every two lines of the stdin block are a test of their own, each
compared with what the solution prints.

An events block tests a `tinyweb` page:

````markdown
Make a button "More" that counts its clicks.

```pyking task name = "counter"
import tinyweb as tw
tw.web_init(0)
```

```pyking solution
use mutation
import tinyweb as tw

var count = 0
tw.web_init(0)
shown = tw.label("0")
def more():
    count := count + 1
    tw.set_text(shown, string(count))
    print(count)
tw.button("More", on_click = more)
```

```events visible = true
click "More"
click "More"
```

```stdout
1
2
```
````

| Event line | Is |
|---|---|
| `click "Id"` | a button clicked |
| `slide "Id" 12` | a slider moved to 12 |
| `check "Id" true` | a checkbox set |
| `pick "Id"` | a radio button picked |
| `choose "Id" 2` | a choice made |
| `enter "Id" "Ada"` | text entered in a field |
| `frame 0.5` | a frame at 0.5 seconds |
| `move "c" 20 30`, `press "c" 40 50`, `release "c" 90 62` | the mouse over canvas `c` |
| `key ArrowLeft`, `key_up ArrowLeft` | a key pressed, released |

A widget's id is what the function making it answers: for
`tw.button("More")`, its title.

#### Loosening the comparison

Four blocks under a task let an answer differ from what is expected in
ways that do not matter. Each applies to what is printed, what `debug`
writes, and the `tinyweb` log. Their lines are patterns; in the last
three, `*` stands for any text.

| Block | Lets an answer |
|---|---|
| ```` ```diff-allowed ```` | have numbers that differ by at most `[+/-N]` |
| ```` ```optional-last ```` | end with lines the other side does not have |
| ```` ```any-order ```` | write some lines in any order between given lines |
| ```` ```ignore-chars chars = "…" ```` | differ in the given characters on lines that match |

````markdown
```diff-allowed
area = [+/-0.01]
```

```optional-last
sdelay*
```

```any-order
BETWEEN: sdelay*
ANY: play "kick*
ANY: play "snare*
```

```ignore-chars chars = " ,"
point*
```
````

With these, `area = 12.57` matches `area = 12.56636`, a pause at the
end of a beat may be left out, drums played on the same beat may come
in any order, and `point 1,2` matches `point 1, 2`.

#### Comparing only the start

A program that plays a beat forever never ends, so it cannot be
compared whole. A ```` ```compare-until ```` block says how much is
compared: each run stops after `events` lines of the `tinyweb` log that
match its patterns.

````markdown
```compare-until events = 60
sdelay*
```
````

#### Answering with git

A task with `method = git` is answered outside the page. The page still
shows its code and its visible input, and ▶ runs the code, but in place
of Submit it says "Please submit via your git account". The answer is
graded from the notebook's tests with [nbverify](#grading-with-nbverify).

````markdown
```pyking task name = "project" points = 5 method = git
print("Write your program in your repository")
```

```stdout
done
```
````

#### Limiting calls

`max_calls` limits how often an answer may write a name: here `rect`
at most twice. Every place counts, outside comments and strings:
`rect(...)`, `tw.rect(...)` and `def rect`. The limit is shown as a
badge, and an answer that breaks it is refused before it runs.

````markdown
Draw two boxes.

```pyking task name = "boxes" max_calls = (2,rect)
import tinyweb as tw
tw.web_init(0)
c = tw.canvas(200, 100)
```

```pyking solution
import tinyweb as tw
tw.web_init(0)
c = tw.canvas(200, 100)
tw.rect(c, 10, 10, 80, 80)
tw.rect(c, 110, 10, 80, 80)
```
````

### Examples

An ```` ```example ```` block shows what a task's solution does with an
input, usually in the prose before the task, so the reader sees what is
asked before trying. Its text is the input. The page runs the solution
on it and shows the input and what the solution printed, drew, or both.
The solution's code is not shown.

````markdown
For example, for the task `square` above:

```example task_name = square output = stdout
7
```
````

| Example header | Means | Default |
|---|---|---|
| `task_name = name` | the task whose solution runs; it needs a `name` and a solution | required |
| `args = "…"` | the program's arguments | none |
| `output = stdout`, `image` or `stdout,image` | what it shows: what the solution printed, what it drew with `tinyweb`, or both | `stdout` |

### Quizzes

The question is the prose before a ```` ```quiz ```` block, or the text
inside it before the first alternative. An alternative starts a line
with `*` where the student picks one, or with `[]` where they may check
any number. An ```` ```answer ```` block follows, with one entry per
alternative, in order: `->` for right, `-` for wrong, then the
explanation, which may be empty.

````markdown
```quiz name = "binding" attempts = 2 points = 2 penalty = 1 available = true
Which are true?

[] `var` binds a name that can change.

[] `=` binds a name that can change.

[] `:=` updates a `var`.
```

```answer
-> A var is updated with :=.
- A name bound with = never changes.
->
```
````

A `*` quiz has exactly one right alternative:

````markdown
Which is a square?

```quiz name = "which" points = 1
* 9

* 10
```

```answer
-> 3 times 3.
- No whole number squared is 10.
```
````

| Quiz header | Means | Default |
|---|---|---|
| `name`, `attempts`, `points`, `penalty` | as for a task | none, no limit, none, 0 |
| `available = true` | once the attempts are used up, the right answers are marked and every explanation shown | `false`: only "failed" |
| `one_point_correct = true` | a `[]` quiz gives a point for each right alternative checked, and none when more are checked than there are right ones; its `points` is the number of `->` entries | `false` |

A wrong Submit shows the explanation of each wrong alternative chosen,
and for checkboxes says when a right one was left unchecked.

## Student and teacher

`--mode student`, the default, shows a solution only where it is
`available` and the student asks for it, a test only where it says
`visible = true`, and no quiz answers.

`--mode teacher` shows every solution, test and answer. It also runs
test mode's checks in the page, and shows under each task, quiz, cell
and the rules that they have no problems, in green, or what the
problems are, in red. Use it while you write a notebook.

The answers are checked in the browser, so in both modes the whole file
is sent to it. A student who reads the page's source can find the
solutions. For graded work, use [nbverify](#grading-with-nbverify).

## Test mode

```sh
pyk notebook book.md --mode test
```

Test mode serves nothing. It reads the notebook as the page does, runs
every program, and prints each problem as `file:line: message`. It
exits with status 1 if there is any problem, and 0 otherwise, so a
continuous integration job can run it on every notebook of a course. It
needs `node`.

It checks that:

- the blocks are where they belong, with valid headers: a solution
  after its task, an answer after its quiz with an entry per
  alternative, one `->` in a `*` quiz, numbers where numbers belong,
  names valid and unique;
- there is at most one rules block, and its `max` is the sum of the
  points and not less than `pass`;
- every cell runs, every `error` cell is refused, and every task's
  starting code runs;
- each cell and each solution prints what the stdout and stderr blocks
  after it say, on each test's input and events, and each solution
  keeps to its task's `max_calls`;
- a task without a solution has an output to compare an answer with;
- each example names a task with a solution, and the solution runs on
  the example's input.

A cell that uses `var` without its own `use mutation` line, for
example, is reported here.

## The JSON form

A notebook can also be written as JSON. Use it when a program, not a
person, writes or reads notebooks, for example to generate a notebook
from a question bank or to import one into another system.

| Command | What it does |
|---|---|
| `pyk notebook book.md --to-json` | writes `book.json` beside it |
| `pyk notebook book.json --to-markdown` | writes `book.md` beside it |
| `pyk notebook --json-schema` | writes `notebook.schema.json`, the JSON Schema every notebook's JSON follows |

`-o FILE` names the file written, and `-o -` prints it. A file of the
default name that is already there is not written over. `--to-markdown`
gives back the same Markdown, byte for byte. `pyk notebook book.json`
serves and tests the JSON as the Markdown it stands for.

The JSON is a list of blocks in order: Markdown text, the rules, cells,
tasks with their solution and tests, practices, examples and quizzes.
This notebook:

````markdown
Print the square of the number on standard input.

```pyking task name = "square" points = 2
print("Add your code here")
```

```stdin visible = true
4
```

```stdout visible = true
16
```
````

is this JSON:

```json
{
  "format": "pyking-notebook",
  "version": 1,
  "blocks": [
    { "type": "markdown",
      "text": "Print the square of the number on standard input.\n\n" },
    {
      "type": "task",
      "attributes": { "name": "square", "points": 2 },
      "code": "print(\"Add your code here\")\n",
      "tests": [
        {
          "stdin": { "attributes": { "visible": true }, "text": "4\n" },
          "stdout": { "attributes": { "visible": true }, "text": "16\n" }
        }
      ]
    }
  ]
}
```

## Grading with nbverify

The answers a student submits in the page are checked by their own
browser. For grades that count, `nbverify.py` grades a notebook's tasks
and quizzes on a server, for the
[ID2202 autograder](https://johnwikman.github.io/id2202-autograder/index.html).
It is one Python 3 file, in a Pyking installation under
`tools/nbverify/`, and needs `pyk` to make the tests.

Make a test file for each test of a task, from the notebook's JSON.
`nbverify.py` runs the solution with `pyk` to find what an answer must
print:

```sh
pyk notebook week1.md --to-json
python3 nbverify.py paramdata week1.json --name square --output-dir tests/square
```

The autograder runs a student's program with `nbverify.py run` and
hands the result to `nbverify.py`, which answers whether it is
accepted, and if not, why, in the same words Submit uses in the page.
To try an answer on one test without the autograder:

```sh
python3 nbverify.py paramdata week1.json --name square --case 1 \
  | python3 nbverify.py try mycode.pyk
```

A quiz is answered by a program that prints the numbers of the
alternatives chosen, counted from 1: `print([1, 3])`. Run
`python3 nbverify.py --help` for every command.

## Notebooks on this website

The pages of this website are notebooks too. Every ```` ```pyking ````
block on them is a cell you can edit and run, and a page may hold tasks
and quizzes, in student mode, with your progress kept per page. The
same pages are in the playground's Help tab.

This cell reads its input from a stdin block before it:

```stdin
Ada
```

```pyking
import io
name = io.read_line()
print("Hello, " + name + "!")
```

And this is a quiz:

```quiz name = "cells"
A name defined in one cell can be used in the next cell.

* True

* False
```

```answer
- Each cell is a whole program, run on its own.
-> Each cell is a whole program, run on its own.
```
