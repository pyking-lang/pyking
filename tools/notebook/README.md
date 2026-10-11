# Pyking notebook

A Markdown document shown as a notebook: the prose is rendered, and every
Pyking code block is a **cell** the reader can edit and run in the browser
with the interpreter. The document itself is not edited here — the `.md`
file is the notebook, written in any editor, and it reads correctly in any
Markdown viewer too.

```sh
pyk notebook PYKING-TUTORIAL.md          # serve it and print a link
pyk notebook --port 9000 notes.md
pyk notebook --mode teacher exam.md      # every solution, test and answer shown
pyk notebook --mode test exam.md         # check it, and serve nothing
make notebook                            # at the repository root: the tutorial
```

A notebook may hold **exercises and quizzes**, checked in the page; see
"Exercises and quizzes" below.

As with the playground, **nothing executes on the server**. The page loads
the real compiler — `src/` compiled to JavaScript, `build/pyking.js` — into a
worker and runs each cell with its interpreter. The server only hands out
files, and needs Python 3.10 or later.

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
had run; either way test mode checks it (see "Test mode"). A
```` ```stdin ```` block between the cell and its stdout is the input
it is read from, and a ```` ```stderr ```` block what `debug` writes.

An `error` cell shows its refusal as the intended result, labelled so, and
warns if it unexpectedly runs. `{.pyking .norun}` is read the same as
`pyking norun`. A block in any other language is shown highlighted
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

The blocks after it are, in this order and each optional: one
```` ```pyking solution ````, then the tests. A test is a
```` ```stdin ```` block (its arguments in `args = "…"`, empty if not
given), a ```` ```stdout ```` or ```` ```stderr ```` block, or one of
each with the output after its input; an output with no input before it
runs on the exercise's own input. A solution with no exercise before it
is an error, and so is anything else between them. The next exercise
starts a new one.

**Submit** runs the student's code on every test. With a solution, the
solution runs on the same input, and the two must print the same and end
with the same status; what `debug` writes is compared too where the test
has a stderr block. The blocks' own text is then only checked by test
mode, against the solution. Without a solution, the student's output
must match the stdout and stderr blocks. Output matches when it is the
same apart from spaces at the end of a line and blank lines at the end.
Each run may take ten seconds. A failed Submit uses an attempt and, unless
`attempts = 1`, shows one failed test: its input, what was expected and
what the answer printed. Running the cell with **▶** is free.

**Show a solution** shows the solution under the exercise, at any time,
unless it says `available = false`; then it is never shown in student
mode. A solved exercise turns green, with a check mark.

### Quizzes

The question is the prose before a ```` ```quiz ```` block. Its
alternatives start with `*` where one is to be chosen (radio buttons) and
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

An ```` ```answer ```` block follows every quiz, with one entry per
alternative, in order: `->` for a right one and `-` for a wrong one,
then what explains it, which may be left empty. A `*` quiz has exactly
one `->`. `attempts`, `points` and `penalty` mean what they mean for an
exercise.

**Check** with a wrong answer uses an attempt and shows the explanation
of each wrong alternative chosen; for checkboxes it also says when a
right one was left unchecked. When the attempts are used up the quiz is
failed: with `available = true` the right answers are marked and every
explanation shown, and otherwise it only says it was failed. The default
is `false`.

### Who is reading

`--mode student`, the default, shows what is described above: a
solution only when asked for, a test only where it says `visible =
true`, and no answers. `--mode teacher` shows every solution, test and
answer, and grades the same way. Solutions and answers are in the page in
both modes -- the browser checks the answers -- so a student who reads
the page's source can find them.

Progress is kept in the browser's local storage, per document: each
exercise's code, what was chosen in each quiz, the attempts used and the
points. An item whose block is edited starts again.

### Test mode

`pyk notebook --mode test FILE.md` serves nothing. It reads the document
with the page's own renderer and runs every program with the page's own
compiler worker, under node (`check.js`), and prints `file:line: message`
for each problem, and exits with 1 if there was one:

- the blocks are in an order this section allows, with a valid header:
  a solution after its exercise, an answer after its quiz with as many
  entries, one `->` for a `*` quiz, numbers where numbers belong, one
  rules block whose `max` is the sum of the points and is not less than
  `pass`;
- every cell runs, and every `error` cell is refused; an exercise's
  starting code included;
- a solution prints, on each test's input, what any stdout or stderr
  block after it says, and so does an ordinary cell;
- an exercise with no solution has an output to compare an answer with.

`tests/notebook/broken.md` makes every one of these mistakes, and
`broken.out` is what test mode says about it.

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
pyking/     build/pyking.js, and a manifest.json naming it
```

`manifest.json` is `{"bundle": "pyking.js", "stamp": "<any string>"}`.
Other options: `baseURL` (where relative links and images resolve; beside
`url` by default), `documentLink(href)` (what a link to another `.md` file
becomes), and `fontSize` (the editors', in pixels). Styles are scoped under
`.pkn-notebook` and are custom properties (`--pkn-bg`, `--pkn-accent`, …), so
a theme is a few overrides. The mounted object has `cells`, `run(index)`,
`reset(index)`, `stop()`, `setTheme(choice)`, `results()` and `title`.

Three options are about exercises and quizzes: `mode` (`"student"`, the
default, or `"teacher"`), `storageKey` (where progress is kept; by default
from `url`, or from the text given as `markdown`), and `onChange(results)`,
called whenever an answer is checked. `results()` answers every exercise
and quiz -- `{id, kind, number, state, points, maxPoints, attemptsLeft}`,
`state` being `"open"`, `"solved"` or `"failed"` -- with the totals:
`solved`, `total`, `points`, `max`, `pass`, `passed` and `done`. The
host element also receives a `pkn-results` event, the same object in
`detail`.

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

`data-readonly` and `data-error` are the fence attributes of the same
names, and `data-stdin` and `data-args` fill in the cell's input as a
```` ```stdin ```` or ```` ```args ```` block does. The options and the
mounted object are the notebook's, without the page: no header, no
contents, no `title`.

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
  notebook.py        the server: `pyk notebook` runs this
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
    notebook.css     all styles, scoped under .pkn-notebook
```

| URL | From |
|---|---|
| `/` | `assets/index.html` |
| `/notebook.json` | the document the server was started with, and the mode |
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
exercises submitted, quizzes answered, a reload, and start over. The
editors' keys are not covered.
