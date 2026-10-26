# Notebooks

A Pyking notebook is a Markdown file whose fenced ```` ```pyking ````
blocks are cells a reader edits and runs in the browser. Other fenced
blocks make it an assignment: tasks with solutions and tests,
quizzes with answers, and the rules that say how many points pass. This
page lists everything a notebook can hold, with an example of each, and
the JSON form of a notebook (`--to-json`, `--to-markdown`,
`--json-schema`). `tools/notebook/README.md` covers the page itself:
embedding it, its layout and its keys. `tools/nbverify/README.md`
covers grading a notebook's tasks with the ID2202 autograder.

## Running a notebook

| Command | What it does |
|---|---|
| `pyk notebook book.md` | serves the notebook and prints a link; the page reloads when the file changes |
| `pyk notebook book.md --mode teacher` | every solution, test and answer shown, and what test mode finds under each element |
| `pyk notebook book.md --mode test` | serves nothing: runs every program under node and prints `file:line: message` for each problem; exits 1 if there is one |
| `pyk notebook book.md --port 8100` | a port of its own |
| `pyk notebook book.json` | the same, for a notebook's JSON |
| `pyk notebook book.md --to-json` | writes `book.json` beside it |
| `pyk notebook book.json --to-markdown` | writes `book.md` beside it |
| `pyk notebook --json-schema` | writes `notebook.schema.json` in the current directory |

`--mode student` is the default. `-o FILE` names the file the last three
write, and `-o -` prints it. A file of the default name that is there
already is not written over, but one `-o` names is. The three
conversion flags take no `--mode` or `--port`, and only `pyk --help`
lists them.

Every cell is a whole program, run with the interpreter in the page.
Nothing runs on the server. Being a program of its own, a cell that
writes `var` or `:=` starts with its own `use mutation` line (PYKING.md,
"Features turned on with `use`"), and so does a task's solution or an
answer that does; test mode reports a cell that forgets it.

## Prose

Everything outside the blocks below is Markdown: headings, emphasis,
code, links, images, lists and task lists, tables, quotes and callouts
(`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`),
footnotes, `$math$`, `$$display math$$` and ```` ```math ```` blocks,
rules, HTML, and front matter whose `title:` names the page.
`tools/notebook/README.md`, "What the Markdown renderer supports", has
the full table. A fenced block in another language is shown
highlighted.

## Cells

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

| Word after `pyking` | Means |
|---|---|
| (none) | editable and runnable |
| `readonly` | runnable, not editable |
| `error` | meant to be refused: the refusal is shown as the intended result |
| `norun` | highlighted only; a fragment |
| `playground` | the website's "Try in playground" link; the notebook ignores it |

`pyk` is read as `pyking`, and `{.pyking .norun}` as `pyking norun`.

### A cell's input

A cell reading standard input shows a stdin field, and one reading
`sys.args()` an args field. What they start with is written on the
header:

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
```

```pyking
import io
print("hello", io.read_line())
```
````

A value is a word or a quoted string, in which `\n` is a new line.
Arguments are split at blanks, with quotes keeping a blank inside one.

### What a cell prints

A ```` ```stdout ```` block after a cell is what it prints, a
```` ```stderr ```` block what `debug` writes, a ```` ```stdin ```` block
between them the input it is read from, and an ```` ```events ````
block the tinyweb events it is sent (below). They are hidden unless
they say `visible = true`, and test mode checks each.

````markdown
```pyking
import io
debug("to stderr")
print(io.read_line())
```

```stdin
echo me
```

```stdout
echo me
```

```stderr visible = true
to stderr
```
````

### tinyweb in a cell

A cell using `tinyweb` shows its page under the cell: canvases,
buttons, sliders, sound. The program goes on running after its last
line, so a click calls back the function it handed over, until the cell
runs again or **■** is pressed.

## Assignments

### The rules

````markdown
```rules max = 10 pass = 8
Solve all the tasks and quizzes. Each failed Submit costs a point.
```
````

At most one per notebook, shown at the top with `max` and `pass`.
`max` must be the sum of the `points` of every task and quiz, a
task with `method = git` included. A student passes with `pass`
points or more.

### Tasks and practices

The prose before a ```` ```pyking task ```` block states the task;
the block holds the code the student starts from, which must run. A
```` ```pyking practice ```` block is a task that gives no points:
everything below holds for it, but it takes no `points` or `penalty`,
and it is titled "Practice" rather than "Task". ```` ```pyking
exercise ````, the old name for both, is refused.

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

```stdin args = "ignored"
-3
```
````

| Task header | Means | Default |
|---|---|---|
| `name = "…"` | the task's name: letters, digits, `_` and `-`, starting with a letter or a digit, unique among the notebook's tasks and quizzes | none |
| `attempts = N` | how many times Submit may fail before the task is failed | no limit |
| `points = N` | what solving it gives | none: solved or not |
| `penalty = N` | taken off the points for each failed Submit, never below 0 | 0 |
| `stdin = "…"`, `args = "…"` | the input the code box starts with, and what a test without its own input uses | empty |
| `readonly` | the starting code cannot be edited | editable |
| `method = inline` or `git` | answered in the page's code box, or elsewhere and pushed with git | `inline` |
| `max_calls = (N,name)` | the answer may write `name` at most N times; several limits as `(2,rect) (1,circle)` | no limit |

`method = code_box`, the old name for `inline`, is refused.

`max_calls` counts every place the answer writes the name outside its
comments and strings, as a whole name: `rect(...)`, `tw.rect(...)`,
`int::rect(...)` and `def rect` all count, `rect_w` and `rectangle` do
not. Test mode checks that the solution keeps to it.

After the task, with only blank lines between, come in order: an
optional solution, then the tests and diff-allowed blocks. The next
task, quiz, cell or any prose ends the group.

**The solution**, ```` ```pyking solution ````:

| Solution header | Means | Default |
|---|---|---|
| `available = true` | a student may ask to see it | `false` |
| `readonly` | cannot be edited where shown | editable |
| `stdin = "…"`, `args = "…"` | its input when it runs on its own | the task's |
| `save_canvas = "c"`, `file = "x.png"` | the tinyweb canvas `c` it draws is saved as `x.png` beside the notebook and shown wherever the prose names that image | none |

**A test** is a ```` ```stdin ```` block, an ```` ```events ```` block,
a ```` ```stdout ```` block or a ```` ```stderr ```` block, or several of
them, the input first. One with no stdin block runs on the task's
own input.

| Test block | Headers |
|---|---|
| ```` ```stdin ```` | `args = "…"` the test's arguments (empty, not the task's, where not given); `visible = true`; `lines_per_multi_input = N` makes a test of every N lines, each compared with the solution, so it needs a solution and no stdout or stderr after it |
| ```` ```events ```` | `visible = true`. One tinyweb event a line, delivered once the program's top level has ended |
| ```` ```stdout ```` | `visible = true`. What the program prints |
| ```` ```stderr ```` | `visible = true`. What `debug` writes; it is compared only where the test has one |

An events block uses the lines of an events file (docs/libraries.md,
"Testing a page"):

````markdown
```pyking task name = "counter"
import tinyweb as tw
tw.web_init(0)
```

```pyking solution
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

A widget's id is what the function making it answers: the title, for
`tw.button("More")`.

**A diff-allowed block** loosens how an answer is compared with the
solution. Each line is a pattern matched exactly, except that each
`[+/-N]` stands for a number that may differ from the solution's by at
most N (a decimal allowed, several on a line). It applies to what is
printed, what `debug` writes and tinyweb's log, and needs a solution.

````markdown
```diff-allowed
circle "canvas" [+/-2] [+/-2] 10 "#000000" "" 1.000 1.000
area = [+/-0.01]
```
````

**Submit** runs the answer on every test, and the solution on the same
input where there is one, with a limit of ten seconds a run. With a
solution the answer must print the same, draw the same (tinyweb's log),
end with the same status, and, where the test has a stderr block, write
the same with `debug`. Without one, the answer must print what the
stdout block says and write what the stderr block says. Output matches
when it is the same apart from spaces at the end of a line and blank
lines at the end. An answer that writes a name more often than
`max_calls` allows is refused before it is run. A failed Submit uses an
attempt, says why in one of these words:

- Your program uses *name* *N* times, and may use it at most *M* times.
- Your program did not run: *the error*
- The output is not what it should be.
- What it drew with tinyweb is not what it should be.
- What debug printed is not what it should be.
- Your program ended with status *N*, and should end with *M*.

and, unless `attempts = 1`, shows the test, what was expected and what
the answer printed. **See result diff** shows the first test that
differed side by side, pictures included. Running a cell with **▶** is
free.

**A task with `method = git`** shows "Please submit via your git
account" instead of a code box. Its tests and solution are still the
notebook's, and `nbverify` grades the answer from them.

### Quizzes

The question is the prose before a ```` ```quiz ```` block, or the text
inside it before the first alternative. An alternative starts a line
with `*` where one is chosen (radio buttons) or `[]` where any number
are (checkboxes), and runs to the next; it may hold inline Markdown.
An ```` ```answer ```` block follows, with an entry per alternative in
order: `->` right, `-` wrong, then what explains it, which may be
empty.

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

| Quiz header | Means | Default |
|---|---|---|
| `name = "…"` | as for a task | none |
| `attempts`, `points`, `penalty` | as for a task | no limit, none, 0 |
| `available = true` | once the attempts are used up, the right answers are marked and every explanation shown | `false`: only "failed" |
| `one_point_correct = true` | a `[]` quiz gives a point for each right alternative checked, none when more are checked than there are right ones; its `points` is the number of `->` entries, and it has one attempt unless `attempts` says otherwise | `false` |

A `*` quiz has exactly one `->`. A wrong Submit shows the explanation of
each wrong alternative chosen, and for checkboxes says when a right one
was left unchecked.

### Who is reading

`--mode student` shows a solution only when asked for and where it is
available, a test only where it says `visible = true`, and no answers.
`--mode teacher` shows everything and runs test mode in the page,
showing under each element that it has no problems or what they are.
Both modes send the whole file to the browser, which checks the answers,
so a student who reads the page's source can find them. Progress is kept
in the browser's local storage, per document.

### Test mode

`pyk notebook --mode test` checks, and reports each problem with its
line:

- the blocks are where this page puts them, with valid headers: a
  solution after its task, an answer after its quiz with an entry
  per alternative, one `->` in a `*` quiz, numbers and booleans where
  they belong, names valid and unique, `method` inline or git, an events
  block under a cell or a task, no ```` ```pyking exercise ````, no
  `points` or `penalty` on a practice, `max_calls` one or more
  `(N,name)`;
- one rules block at most, whose `max` is the sum of the points and is
  not less than `pass`;
- every cell runs, every `error` cell is refused, and every task's
  starting code runs;
- each solution and each cell prints, on each test's input and events,
  what any stdout or stderr block after it says, and each solution
  keeps to its task's `max_calls`;
- a task without a solution has an output to compare an answer
  with; `save_canvas` has a `file`, a `.png`; `lines_per_multi_input`
  splits into whole pieces, with a solution and no output after it; a
  diff-allowed block is under a task with a solution, and each line
  holds a `[+/-N]`.

## JSON

`pyk notebook book.md --to-json` writes the notebook as JSON, and
`--to-markdown` writes the JSON back as the same Markdown, byte for byte.
`pyk notebook book.json` serves and tests the JSON as the Markdown it
stands for. `pyk notebook --json-schema` writes the JSON Schema (Draft
2020-12) every notebook's JSON follows; it does not depend on any one
notebook. `src/notebook_format.ml` is the implementation.

### The format

```json
{
  "format": "pyking-notebook",
  "version": 1,
  "blocks": [ ... ],
  "final_newline": false
}
```

`final_newline` is there only where the file ends with a block's closing
line and no newline. `blocks` is the document in order, each one of:

| `type` | What it holds |
|---|---|
| `markdown` | `text`: the Markdown between notebook blocks, exactly as written |
| `rules` | `attributes` (`max`, `pass`), `text` |
| `cell` | a ```` ```pyking ```` cell: `attributes`, `code`, and `tests` written under it |
| `task` | `attributes`, `code` (the starting code), `solution` (`attributes`, `code`), `tests`, `diff_allowed` (each `text`) |
| `practice` | as `task`, for a ```` ```pyking practice ```` |
| `quiz` | `attributes`, `question`, `alternatives` (each `marker`, `*` or `[]`, and `text`), `answer` (`entries`, each `correct` and `text`) |
| `block` | any other notebook block where it stands, belonging to nothing: `language`, `attributes`, `text` (or `code` for pyking) |

A test is an object with up to four fields, `stdin`, `events`, `stdout`
and `stderr`, each with `attributes` and `text`. A stdin block split by
`lines_per_multi_input` is one test here, as it is one block.

Every `text` and `code` is the block's lines, each with its newline, so
`"16\n"` is a block holding the line `16`. `attributes` holds the
header's attributes in the order written, typed: `max`, `pass`,
`attempts`, `points`, `penalty` and `lines_per_multi_input` are numbers,
`available`, `visible` and `one_point_correct` booleans, a bare word
(`readonly`, `norun`, `error`, `playground`) is `true`, and every other
value a string, `max_calls` as written (`"(2,rect) (1,circle)"`). The
word `task`, `practice` or `solution` that says what a pyking block is
is not among them.

This notebook:

````markdown
# Squares

```rules max = 3 pass = 2
Solve both.
```

Print the square of the number on standard input.

```pyking task name = "square" points = 2 attempts = 3
print("Add your code here")
```

```pyking solution
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

is this JSON:

```json
{
  "format": "pyking-notebook",
  "version": 1,
  "blocks": [
    { "type": "markdown", "text": "# Squares\n\n" },
    { "type": "rules", "attributes": { "max": 3, "pass": 2 }, "text": "Solve both.\n" },
    { "type": "markdown", "text": "\nPrint the square of the number on standard input.\n\n" },
    {
      "type": "task",
      "attributes": { "name": "square", "points": 2, "attempts": 3 },
      "code": "print(\"Add your code here\")\n",
      "solution": { "code": "import io\nn = int(io.read_line())\nprint(n * n)\n" },
      "tests": [
        {
          "stdin": { "attributes": { "visible": true }, "text": "4\n" },
          "stdout": { "attributes": { "visible": true }, "text": "16\n" }
        }
      ]
    },
    { "type": "markdown", "text": "\nWhich is a square?\n\n" },
    {
      "type": "quiz",
      "attributes": { "name": "which", "points": 1 },
      "question": "",
      "alternatives": [ { "marker": "*", "text": "9" }, { "marker": "*", "text": "10" } ],
      "answer": {
        "entries": [
          { "correct": true, "text": "3 times 3." },
          { "correct": false, "text": "No whole number squared is 10." }
        ]
      }
    }
  ]
}
```

### Writing it back

A block is written back in one canonical layout: ```` ``` ```` (or a
longer fence where its text holds one), the language, the word
`task`, `practice` or `solution` where there is one, then `key =
value` for each attribute, strings in double quotes with `\"`, `\\`,
`\n` and `\t` escaped and `(...)` groups bare; the text; the closing fence; and one empty line between blocks
that follow one another. Where the source wrote a block another way,
the JSON keeps how, beside the fields:

| Field | Kept where |
|---|---|
| `info` | the header after the fence marker is not the canonical one: `points=10`, single quotes, `{.pyking}`, `pyk`, attributes in another order |
| `fence` | the opening fence is not ```` ``` ````: `~~~`, or more backticks than needed |
| `close` | the closing line is not the opening fence; `null` where the block runs to the end of the file |
| `gap` | the blank lines before a block that follows another are not one empty line |
| `body` | a quiz's or an answer's text is not the one its fields write |
| `order` | a task's or a cell's blocks are not in the order solution, each test's stdin, events, stdout and stderr, then the diff-allowed blocks: a list such as `["solution", "diff_allowed[0]", "tests[0].stdin"]` |

`info` and `body` are used only while they still say what the fields
do: change an attribute or an alternative in the JSON, and that block is
written the canonical way. So a JSON edited by hand or written by a
program needs none of these fields.

### What is a block

The blocks are found and grouped as the page finds and groups them:

- a notebook block is a fenced block at the left margin whose language
  is one of `pyking`, `pyk`, `stdin`, `args`, `stdout`, `stderr`,
  `events`, `quiz`, `answer`, `rules` and `diff-allowed`, outside
  another fenced block, an HTML block, display math and the front
  matter. Anything else, a block in a list item included, stays in a
  `markdown` block's text;
- blocks with only blank lines between them are a group, and inside a
  group a task or a practice takes the solution, tests and diff-allowed blocks
  after it, a quiz the answer right after it, and a cell the stdin,
  events, stdout and stderr blocks after it;
- a block that belongs to none of them is a `block` where it stands.
  In a notebook test mode accepts there is none of these but a stdin or
  args block before the cell it fills in.

## Grading with nbverify

`tools/nbverify/nbverify.py` grades the tasks and quizzes of a
notebook for the ID2202 autograder, which runs a student's program and
hands its output to a verifier. `nbverify.py paramdata book.json --name
square` makes each test's options from the notebook: the input, and
what the solution prints on it, which it runs with pyk to find out. The
verifier then needs nothing but those options and the answer's source,
which `nbverify.py run` hands it for `max_calls`, and gives the reasons
listed under "Tasks and practices" above. A quiz is answered by a program printing
the alternatives chosen, numbered from 1: `print([1, 3])`. See
`tools/nbverify/README.md`.

## Tests

`tests/notebook/` holds the page's fixtures (`features.md`, every
feature; `broken.md`, every mistake test mode reports), and the
`notebook` suite renders and drives them. `tests/nbjson/` holds the
notebooks the `nbjson` suite turns into JSON and back and runs test mode
on, and the `nbverify` suite grades the student solutions in
`tests/nbverify/` against them.
