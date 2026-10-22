# Pyking notebook

A Markdown document shown as a notebook: the prose is rendered, and every
Pyking code block is a **cell** the reader can edit and run in the browser
with the interpreter. The document itself is not edited here — the `.md`
file is the notebook, written in any editor, and it reads correctly in any
Markdown viewer too.

```sh
pyk notebook PYKING-TUTORIAL.md          # serve it and print a link
pyk notebook --port 9000 notes.md
pyk notebook --mode teacher exam.md      # every solution, test, answer and problem shown
pyk notebook --mode test exam.md         # check it, and serve nothing
make notebook                            # at the repository root: the tutorial
```

A notebook may hold **exercises and quizzes**, checked in the page; see
"Exercises and quizzes" below.

As with the playground, **nothing executes on the server**. The page loads
the real compiler — `src/` compiled to JavaScript, `share/pyking.js` — into a
worker and runs each cell with its interpreter. The server only hands out
files, and is `pyk` itself (`src/web_tools.ml`), so nothing else has to
be installed. Test mode alone needs node.

`pyk notebook` watches the file it serves: when it changes, the page
reloads, scrolled where it was. It fetches the file once a second and
compares it with what it shows. Progress is kept over the reload, except
for an item whose block was edited.

## Running cells

| | |
|---|---|
| **▶** beside a cell | runs it |
| `Shift`+`Enter` in a cell, or in its stdin or args field | runs it and moves to the next cell |
| `Ctrl`/`Cmd`+`Enter` | runs it and stays |
| `Esc` | leaves the editor, or the field |
| **■** while it runs | stops it — the worker is terminated and a fresh one boots |
| **reset** (shown once edited) | puts back the code the document has |

Every cell is **a whole program**, run on its own: a name defined in one cell
is not visible in the next. Cells run one at a time, in the order they were
asked for; `[n]` beside a cell counts runs across the page, as in Jupyter,
and `[*]` marks one queued or running. Output appears under the cell as it
is printed, so a program that prints and then loops still shows what it
printed. An error is shown under the cell and underlined in the code at the
span the compiler reported, in the words `pyk` would use. Edits are kept
until the page is reloaded; nothing is saved.

A cell may use the standard library. `print` and `io.write` write under
the cell, and a `debug` line is shown there too, marked apart. A cell
whose program reads standard input (`io.read_line`, `io.read`,
`io.is_eof`) shows a **stdin** field above its code, and one reading
`sys.args()` an **args** field -- only such a cell, asked of the
compiler as the cell is edited. What the program reads is that text, one
line at a time, and each line it reads is echoed under the cell; the
arguments are split at spaces, with quotes keeping a space inside one.
`sys.exit` ends the run, and a status other than 0 is shown.

A cell using `tinyweb` shows its page under the cell, above its standard
output: canvases, buttons, labels and sliders, drawn by the library's own
renderer (`../webrun/README.md`, "A program may show a page"). Such a
program goes on running after its last line -- a click calls back the
function it handed over, and output it prints then is added under the
cell -- until the cell is run again, another cell runs, or **■** is
pressed; the page then stays as it was, and stops answering.

## Writing a notebook

A notebook is an ordinary `.md` file. A fenced block whose language is
`pyking` (or `pyk`) is a cell; words after the language change it:

````markdown
```pyking
print("Hello", "world", 2026)       # a cell: editable, runnable
```

```pyking readonly
print(1 + 2)                        # runnable, but not editable
```

```pyking error
x = 1
x := 2                              # meant to be refused
```

```pyking norun
def f(x): ...                       # highlighted only: a fragment
```
````

A `stdin` or `args` block just before a cell fills in that cell's input,
and is not shown on its own:

````markdown
```stdin
Ada
```

```args
first "second argument"
```

```pyking
import io
import sys
print("hello", io.read_line("Name? "), sys.args())
```
````

Anything between the input block and the cell -- a paragraph, a heading
-- lets it go. The same input can be written on the cell's own header,
which is the shorter way, and works on a `readonly`, `error` or `norun`
cell too:

````markdown
```pyking stdin = "Ada" args = "first 'second argument'"
import io
print("hello", io.read_line())
```
````

A value is a word or a quoted string, in which `\n` is a new line. The
header's input is a default: what the page shows in the fields, which
the reader can change.

A ```` ```stdout ```` block after a cell is what the cell prints. It is
not shown unless it says `visible = true`, when it reads as if the cell
had run, and running the cell replaces it with what it did print; either
way test mode checks it (see "Test mode"). A
```` ```stdin ```` block between the cell and its stdout is the input
it is read from, and a ```` ```stderr ```` block what `debug` writes.

An `error` cell shows its refusal as the intended result, labelled so, and
warns if it unexpectedly runs. `{.pyking .norun}` is read the same as
`pyking norun`. `pyking playground` is the website's: there it puts a
link below the block that opens the playground with its code, and a
notebook accepts it and does nothing with it. A block in any other language is shown highlighted
(Python, JavaScript, C, C++, Java, OCaml, HTML, shell, JSON) or plain.

Links to other `.md` files beside the document open in the notebook too,
and relative images load from the document's own directory.

### What the Markdown renderer supports

`assets/markdown.js` is written for this page rather than taken from a
library, and supports what readers of GitHub and Jupyter notebooks expect:

| | Written as |
|---|---|
| Headings | `#` … `######`, or underlined with `===` / `---`; each gets an anchor |
| Emphasis | `*em*`, `**strong**`, `***both***`, `_em_`, `~~strike~~` |
| Code | `` `inline` ``, fenced with ```` ``` ```` or `~~~`, or indented four spaces |
| Links | `[text](url "title")`, `[text][ref]`, `[ref]`, `<https://…>`, bare `https://…` and `www.…` |
| Images | `![alt](src "title")` |
| Lists | `-`, `*`, `+`, `1.`, `1)`; nested; tight or loose; `- [ ]` / `- [x]` tasks |
| Tables | GitHub's pipes, with `:--`, `:-:`, `--:` alignment |
| Quotes | `>`, nested |
| Callouts | `> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]` |
| Footnotes | `text[^1]` and `[^1]: note`, collected at the end |
| Math | `$inline$`, `$$display$$`, and ```` ```math ```` blocks, typeset with KaTeX |
| Rules | `---`, `***`, `___` |
| HTML | block and inline HTML is passed through |
| Front matter | a leading `---` … `---` block; its `title:` names the page |
| Line breaks | two trailing spaces, or a trailing `\` |

`$5 and $6` stays text: an inline formula needs a non-space right after the
opening `$` and right before the closing one, and no digit after it. Links
whose URL could run script (`javascript:`) are rendered as `#`.

The page's title is the front matter's `title:`, or else the first
level-1 heading. The contents sidebar lists the headings down to level 3,
leaving out a lone level-1 heading, since that is the title.

## Exercises and quizzes

A notebook can be an assignment: exercises a student solves in the page,
quizzes they answer, and points that add up to a pass. Everything is
written as fenced blocks, so the file still reads correctly anywhere.
`tests/notebook/features.md` uses every one of them.

### The rules

```` ```rules max = 10 pass = 8 ```` holds what the student is told about
the assignment, shown in a box of its own at the top with `max` and
`pass`. A notebook has at most one. `max` is the sum of every
exercise's and quiz's `points`, and test mode checks that it is. A
student passes with `pass` points or more; an exercise or quiz without
points is solved or not, and counts towards nothing.

A bar at the top and at the end says how many exercises and quizzes are
solved, with a green mark once all are, and the points and whether they
pass. Its **start over** forgets every answer.

### Exercises

The exercise is the prose before a cell marked `exercise`, and the cell
holds the code the student starts from:

````markdown
```pyking exercise attempts = 3 points = 5 penalty = 1 stdin = "123" args = "go"
print("Add your code here")
```

```pyking solution available = true
...
```

```stdin args = "my 123"
This is some input
```

```stdin args = "other 77" visible = true
Another example
```

```stdout visible = true
...
```
````

| Header | Means | Default |
|---|---|---|
| `attempts = N` | how many times **Submit** may fail; then the exercise is failed | no limit |
| `points = N` | what solving it gives | none: solved or not |
| `penalty = N` | taken off the points for each failed Submit, never below 0 | 0 |
| `stdin = "…"`, `args = "…"` | the input the cell starts with, and that a test without its own uses | empty |
| `name = "…"` | what the exercise is called: letters, digits, `_` and `-`, unique in the notebook; nbverify finds it by it | none |
| `method = inline` or `git` | where the answer is written: in the page, or elsewhere and pushed with git | `inline` |

The blocks after it are, in this order and each optional: one
```` ```pyking solution ````, then the tests. A test is a
```` ```stdin ```` block (its arguments in `args = "…"`, empty if not
given), an ```` ```events ```` block, a ```` ```stdout ```` or
```` ```stderr ```` block, or several of them with the outputs after the
input; an output or events with no input before it runs on the
exercise's own input. A solution with no exercise before it
is an error, and so is anything else between them. The next exercise
starts a new one.

**Submit** runs the student's code on every test. With a solution, the
solution runs on the same input, and the two must print the same, draw
the same with tinyweb -- its log, as `--tinyweb-log` writes it -- and end
with the same status; what `debug` writes is compared too where the test
has a stderr block. The blocks' own text is then only checked by test
mode, against the solution. Without a solution, the student's output
must match the stdout and stderr blocks. Output matches when it is the
same apart from spaces at the end of a line and blank lines at the end.
Each run may take ten seconds. A failed Submit uses an attempt and, unless
`attempts = 1`, shows one failed test: its input, what was expected and
what the answer printed. Running the cell with **▶** is free.

When a test fails, **See result diff** beside Submit shows the first
test whose outputs differed: its stdin and args, what each program drew
with tinyweb as two pictures, "Your submission" and "Possible solution",
and side by side what each printed and what each sent its page, a line
only the submission wrote in red and one only the solution wrote in
green.

**Show a solution** shows the solution under the exercise, at any time,
where it says `available = true`; without it the solution is never shown
in student mode. A solved exercise turns green, with a check mark.

An **```` ```events ````** block is what a tinyweb page is sent, one event a
line as an events file writes them (`click "Go"`, `slide "Speed" 7`,
`enter "Name" "Ada"`, `frame 0.5`; docs/libraries.md, "Testing a page"),
delivered once the program's top level has ended, the way
`PYKING_TINYWEB_EVENTS` delivers them. Submit sends them to the answer and
the solution alike; **▶** runs the page live. It takes `visible = true`
like an output, and a stdin block split into pieces gives each piece the
same events.

````markdown
```stdin
3
```

```events
click "More"
click "More"
```
````

A stdin block with **`lines_per_multi_input = N`** is a test for every
N lines of it, each run on its own with the block's arguments; every one
must pass. Its pieces are compared with the solution, so the exercise
needs one, and no stdout or stderr block follows it.

````markdown
```stdin lines_per_multi_input = 1
1
2
3
```
````

A **```` ```diff-allowed ````** block under an exercise loosens how an
answer is compared with its solution. Each line of it is a pattern: its
text must match a line exactly, except that each `[+/-N]` stands for a
number, and a line of the answer and the solution's line count as the
same when both match one pattern and each such number of the answer is
at most N from the solution's. N may be a decimal (`[+/-3.21]`), and a
line may have several. It applies to what is printed and to tinyweb's
log alike, and "See result diff" marks such a pair as an allowed
difference rather than a change. It is a teacher's to see.

````markdown
```diff-allowed
circle "canvas" 75 0 [+/-2] "#000000" "" 1.000 1.000
```
````

An exercise with **`method = git`** is answered somewhere else and
pushed with git: the page shows "Please submit via your git account"
in place of the code box and Submit, and grades nothing. Its points are
left out of the page's running totals, but count towards `max`.

A solution may save what it draws as a picture, which the text can
show: **`save_canvas = "c"`** names a tinyweb canvas and **`file =
"name.png"`** the file beside the notebook it is saved as. The solution
runs first thing when the page opens, on its own `stdin` and `args`
where its header gives them, and the canvas is drawn on white at its
size; every image in the text naming that file shows it, and `pyk
notebook` also writes the file. A teacher is told when it could not be
made.

````markdown
![For 40](square.png)

```pyking exercise
print("Add your code here")
```

```pyking solution stdin = "40" save_canvas = "canvas" file = "square.png"
...
```
````

### Quizzes

The question is the prose before a ```` ```quiz ```` block, or the
text inside it before the first alternative, which is shown inside the
quiz's box. Its alternatives start with `*` where one is to be chosen (radio buttons) and
`[]` where any number may be (checkboxes); an alternative runs to the
next, and may hold inline Markdown.

````markdown
```quiz attempts = 2 points = 2 penalty = 1 available = true
[] `var` binds a name that can change.

[] `=` binds a name that can change.
```

```answer
-> Right: a var is updated with :=.
- A name bound with = never changes.
```
````

A quiz takes **`name = "…"`** as an exercise does.

An ```` ```answer ```` block follows every quiz, with one entry per
alternative, in order: `->` for a right one and `-` for a wrong one,
then what explains it, which may be left empty. A `*` quiz has exactly
one `->`. `attempts`, `points` and `penalty` mean what they mean for an
exercise.

**Submit** with a wrong answer uses an attempt and shows the explanation
of each alternative chosen, right or wrong; for checkboxes it also says
when a right one was left unchecked. When the attempts are used up the
quiz is failed: with `available = true` the right answers are marked and
every explanation shown, and otherwise only the explanations of the right
alternatives chosen are shown. The default
is `false`.

`one_point_correct = true` on a `[]` quiz gives one point for each right
alternative checked, and none when more are checked than there are right
answers; a wrong one checked within that number scores nothing. Its
`points` must be the number of `->` entries, which test mode checks, and
it has one attempt unless `attempts` says otherwise; the attempts left
are not shown. The quiz states this rule under its question. A quiz that ends with some of its points
is marked failed, with the points it gave.

````markdown
```quiz points = 2 one_point_correct = true
Why can static type checking be useful?

[] It enables duck typing in a general way.

[] It may rule out errors already at compile time.

[] It may make the execution performance better.
```

```answer
-  False, duck typing is used in dynamic typing.
-> True, it can avoid hard-to-detect runtime errors.
-> True, some runtime checks are no longer needed.
```
````

### Who is reading

`--mode student`, the default, shows what is described above: a
solution only when asked for, a test only where it says `visible =
true`, and no answers. `--mode teacher` shows every solution, test and
answer, and grades the same way. It also runs what test mode checks
(below), in the page's worker, and shows under each element -- the
rules, each exercise, each quiz and each cell -- that it has no problems,
in green, or its problems with their lines, in red. A block with a
problem that belongs to none of them shows it where it stands, and a
line at the top says how many problems the document has. Solutions and answers are in the page in
both modes -- the browser checks the answers -- so a student who reads
the page's source can find them.

Progress is kept in the browser's local storage, per document: each
exercise's code, what was chosen in each quiz, the attempts used and the
points. An item whose block is edited starts again.

### Test mode

`pyk notebook --mode test FILE.md` serves nothing. It reads the document
with the page's own renderer and runs every program with the page's own
compiler worker, under node (`check.js`, over `assets/checks.js`, which
teacher mode runs too), and prints `file:line: message`
for each problem, and exits with 1 if there was one:

- the blocks are in an order this section allows, with a valid header:
  a solution after its exercise, an answer after its quiz with as many
  entries, one `->` for a `*` quiz, as many points as `->` entries for
  a `one_point_correct` quiz, numbers where numbers belong, one
  rules block whose `max` is the sum of the points and is not less than
  `pass`;
- every cell runs, and every `error` cell is refused; an exercise's
  starting code included;
- a solution prints, on each test's input, what any stdout or stderr
  block after it says, and so does an ordinary cell;
- an exercise with no solution has an output to compare an answer with;
- an item's `name` is letters, digits, `_` and `-`, and no other item
  has it, and an events block is under a cell or an exercise;
- an exercise's `method` is inline or git, a solution's `save_canvas`
  has a `file`, a .png beside the notebook, and a stdin block split by
  `lines_per_multi_input` is whole pieces, with a solution and no output
  after it, and a diff-allowed block is under an exercise with a
  solution, each line holding a `[+/-N]`.

`tests/notebook/broken.md` makes every one of these mistakes, and
`broken.out` is what test mode says about it.

### A notebook as JSON

`pyk notebook FILE.md --to-json` writes the notebook as JSON (FILE.json),
`pyk notebook FILE.json --to-markdown` writes it back as the same
Markdown, and `pyk notebook --json-schema` writes the schema that JSON
follows (notebook.schema.json); `-o` names another file, and `-o -`
prints it. `pyk notebook FILE.json` serves and tests the notebook as it
does the Markdown, which it converts on every request. The format is
docs/notebook.md's, "JSON"; tools/nbverify/ grades a notebook's
exercises and quizzes from it for the ID2202 autograder.

## Embedding it in another page

```html
<div id="notebook"></div>
<script type="module">
  import { mountNotebook } from "./notebook/notebook.js";
  const app = await mountNotebook(document.getElementById("notebook"), {
    url: "./docs/tutorial.md",   // or markdown: "…text…"
    header: true,                // the title bar: status and theme toggle
    contents: true,              // the contents sidebar
    theme: "auto",               // "light", "dark", or remembered when unset
  });
  app.run(0);                    // runs the first cell
</script>
```

`notebook.js` loads its own stylesheet and imports `../webrun/web.js`, and
looks for `vendor/` and `pyking/` beside `notebook/` unless `webrunURL`,
`vendorURL` and `pykingURL` say otherwise. So a site that copies the four
directories side by side, as the server lays them out, needs no options but
the document:

```
notebook/   tools/notebook/assets
webrun/     tools/webrun/assets
vendor/     tools/webrun/vendor
pyking/     share/pyking.js, and a manifest.json naming it
```

`manifest.json` is `{"bundle": "pyking.js", "stamp": "<any string>"}`.
Other options: `baseURL` (where relative links and images resolve; beside
`url` by default), `documentLink(href)` (what a link to another `.md` file
becomes), and `fontSize` (the editors', in pixels). Styles are scoped under
`.pkn-notebook` and are custom properties (`--pkn-bg`, `--pkn-accent`, …), so
a theme is a few overrides. The mounted object has `cells`, `run(index)`,
`reset(index)`, `stop()`, `setTheme(choice)`, `results()` and `title`.

`watch: true` reloads the page when the document at `url` changes, as
`pyk notebook` does. Three options are about exercises and quizzes:
`mode` (`"student"`, the default, or `"teacher"`, which also runs test
mode's checks), `storageKey` (where progress is kept; by default
from `url`, or from the text given as `markdown`), and `onChange(results)`,
called whenever an answer is checked. `results()` answers every exercise
and quiz -- `{id, kind, number, state, points, maxPoints, attemptsLeft,
graded}`, `state` being `"open"`, `"solved"` or `"failed"`, and `graded`
false for an exercise submitted with git -- with the totals, which leave
those out: `solved`, `total`, `points`, `max`, `pass`, `passed` and
`done`. The host element also receives a `pkn-results` event, the same
object in `detail`.

`save: {url, root}` is where the pictures solutions make are saved: a
picture whose file is `root` + `path` is posted to `url` + `path`.
`pyk notebook` gives it as `save` in `notebook.json`, and the server
writes the file beside the document; without it a picture is only
shown.

### Cells without the notebook

A page that is not a notebook can still hold cells: the website
(`tools/site/`) puts examples on its own pages this way. Each cell is a
placeholder, a `.pkn-cell` inside a `.pkn-notebook`, holding its code as a
`<pre>`; `mountCells` makes them runnable with one worker and one run queue
between them.

```html
<div class="pkn-notebook">
  <div class="pkn-cell" data-stdin="Ada&#10;"><pre>import io
print(io.read_line())</pre></div>
</div>
<script type="module">
  import { mountCells } from "./notebook/notebook.js";
  const cells = await mountCells(document.querySelectorAll(".pkn-cell"),
                                 { theme: "dark" });
  cells.setTheme("light", false);  // false: not remembered in this browser
</script>
```

Two options are for a page that holds cells as part of something else:
`cellActions`, `[{label, title, run(code)}]`, adds a button to every cell
that hands its code to `run` -- the playground's Help tab copies an
example into its editor this way -- and `runtime`, a `PykingRuntime`
to run the cells on instead of one of their own, so cells mounted page
after page share one worker (`tools/help/assets/help.js`).

`data-readonly` and `data-error` are the fence attributes of the same
names, and `data-stdin` and `data-args` fill in the cell's input as a
```` ```stdin ```` or ```` ```args ```` block does. The options and the
mounted object are the notebook's, without the page: no header, no
contents, no `title`.

A cell's editor is made when the cell comes near the screen, or when it
is run, rather than all at once: a page of a hundred cells would hold the
browser for seconds. Until then the cell shows its code as text.

A placeholder may instead be a `.pkn-fragment` holding a piece of a
notebook as Markdown in `data-markdown` -- an exercise and its blocks,
a quiz and its answer -- which is rendered there and works as it does
in a notebook, in `mode`; the website's pages hold their exercises and
quizzes this way. The mounted Cells then also has `results()`.

The renderer is usable on its own, with no page at all:

```js
import { renderMarkdown } from "./notebook/markdown.js";
const { html, cells, notebook, headings, title, math } = renderMarkdown(text);
```

`notebook` is what `exercises.js` reads out of the blocks: the rules,
the exercises and quizzes, and `problems`, each `{line, message}`.

## Layout

```
tools/notebook/
  check.js           test mode, under node
  package.json       says the .js files are ES modules, for node
  README.md
  assets/
    index.html       the page `/` serves: mounts the component
    notebook.js      the UI (ES module, exports mountNotebook)
    activities.js    the exercises, quizzes and rules on the page
    markdown.js      Markdown to HTML, pure (ES module)
    exercises.js     what the exercise and quiz blocks mean, and the
                     grading; pure (ES module)
    checks.js        what test mode checks, given how to run a program
    notebook.css     all styles, scoped under .pkn-notebook
```

| URL | From |
|---|---|
| `/` | `assets/index.html` |
| `/notebook.json` | the document the server was started with, the mode, and `watch` |
| `/notebook/…` | `assets/` |
| `/doc/…` | the document's own directory; `?doc=other.md` opens another |
| `/webrun/…`, `/vendor/…`, `/pyking/…` | shared with the playground; see `../webrun/README.md` |

A path with `..` or a hidden component (`.git`) is refused, and the server
listens on `localhost` only.

## Testing

`tests/test_notebook.py`, part of `make test`, renders
`tests/notebook/features.md` — every feature above — against
`features.html`, checks a list of short cases against CommonMark's own
answers, runs every cell of `PYKING-TUTORIAL.md` through the compiler's
worker under node, checks what `exercises.js` makes of `features.md` and
its grading arithmetic, starts `pyk notebook` and `pyk playground` to fetch
what their pages load, and runs test mode on `features.md` and
`broken.md`. Where a Chromium is found and the editor is vendored,
`tests/notebook/page.mjs` drives `features.md` in it, in both modes:
exercises submitted, quizzes answered, a reload, and start over; and in
teacher mode the checks under each element, and the page reloading
when its file is edited. The
editors' keys are not covered.
