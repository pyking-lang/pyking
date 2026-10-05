# Pyking notebook

A Markdown document shown as a notebook: the prose is rendered, and every
Pyking code block is a **cell** the reader can edit and run in the browser
with the interpreter. The document itself is not edited here — the `.md`
file is the notebook, written in any editor, and it reads correctly in any
Markdown viewer too.

```sh
pyk notebook PYKING-TUTORIAL.md          # serve it and print a link
pyk notebook --port 9000 notes.md
make notebook                            # at the repository root: the tutorial
```

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
-- lets it go.

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
`reset(index)`, `stop()`, `setTheme(choice)` and `title`.

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

The renderer is usable on its own, with no page at all:

```js
import { renderMarkdown } from "./notebook/markdown.js";
const { html, cells, headings, title, math } = renderMarkdown(text);
```

## Layout

```
tools/notebook/
  notebook.py        the server: `pyk notebook` runs this
  package.json       says the .js files are ES modules, for node
  README.md
  assets/
    index.html       the page `/` serves: mounts the component
    notebook.js      the UI (ES module, exports mountNotebook)
    markdown.js      Markdown to HTML, pure (ES module)
    notebook.css     all styles, scoped under .pkn-notebook
```

| URL | From |
|---|---|
| `/` | `assets/index.html` |
| `/notebook.json` | the document the server was started with |
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
worker under node, and starts `pyk notebook` and `pyk playground` to fetch
what their pages load. None of it needs a browser; the editors and keys are
not covered.
