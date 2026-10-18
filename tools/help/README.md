# The help

Pyking's documentation as Markdown pages, generated once and read by
everything that shows it: the website (`tools/site/`), the playground's
Help tab (`tools/playground/`), and `pyk pykhelp`, which serves the help on
its own.

```sh
python3 tools/help/help.py [DIRECTORY]   # write the pages (default share/help/)
python3 tools/help/libdoc.py             # list what is undocumented in lib/
make pykhelp                             # serve it (pyk pykhelp) and print a link
```

`make` runs `help.py` after building the compiler, so `share/help/` is
always there beside `share/pyking.js`, and every package ships it.

## What is generated

`help.py` writes into one directory:

| | From |
|---|---|
| `index.md`, `404.md`, `install.md` | `sitesrc/`, as they are |
| `getstarted/*.md` | `sitesrc/getstarted/` |
| `documentation/language.md` | `PYKING.md`, its title made front matter and links into `docs/` kept as their text |
| `documentation/editors.md` | `sitesrc/documentation/` |
| `libraries/*.md` | `lib/`, by `libdoc.py`: an overview and one page per module |
| `index.json` | the sections, their pages in menu order, each page's `##` headings with their anchors, and which pages the Help tab shows |

The sections and their order are `SECTIONS` in `help.py`. The Help tab
shows Getting started, the language reference and the libraries. The
website adds tinyweb's pages for other languages under Documentation
(`tools/site/tinywebdoc.py`), since those need the compiler to build.

A page's ```` ```pyking ```` blocks are cells, as in the notebook: whole
programs that run in the page. A block that is not a whole program is
marked `norun`, and one meant to be refused `error`; `tests/test_site.py`
runs every other one and holds each `error` block to being refused.

## Documenting a library

A library is documented by its `##` comments, in either of its two files.
A `##` block opening a file describes the module. A `##` block directly
above a `public` line describes that export, and has this shape:

````
## One paragraph saying what it does, plainly.
##
## Further paragraphs, if it needs them.
##
## # Parameters
## - `name`: what the parameter is, in the order they are written.
## - `x`, `y`: several at once, where they go together.
##
## # Returns
## What it answers. Left out where it answers `()`.
##
## # Examples
## ```pyking
## import io
## io.write_line("hi")
## ```
## ```stdout
## hi
## ```
public def write_line(text: String) -> ()
````

`libdoc.py` refuses a block that misses any of it (`problems`): a
parameter left out or in another order, a missing or a stray `# Returns`,
no example, or an example with no ```` ```stdout ```` block after it. A
declaration in an `_external.pyk` file names its parameters, `def
write_line(text: String) -> ()`, so the page can show them; the unnamed
form `def write_line : (String) -> ()` is refused in `lib/`.

An example's fence may carry the notebook's words: `norun` for one the
browser cannot run (the filesystem), `stdin = "..."` and `args = "..."`
for its input. `tests/test_site.py` runs every example with `pyk`, `norun`
ones too, in a directory of its own and with tinyweb's log set, and
compares what it printed with the ```` ```stdout ```` block. On the page
the output is shown under the cell, and an empty one is left out.

Each item is a box on its module's page: its name as a `##` heading, its
signature with every parameter's name, type and default, then the text,
Parameters, Returns and the example. The boxes are HTML around Markdown
(`item_markdown`), which Starlight and the notebook's renderer both read;
`tools/site/src/styles/site.css` and `assets/help.css` style them.

## The page

`assets/help.js` exports `mountHelp(host, options)`: a menu of pages --
at most 30% of the height, the sections on the left and the current page's
headings on the right, both lined up with the text -- above the page
being read. A page is rendered by the
notebook's `mountCells` as one fragment, on one compiler worker shared by
every page; a link to another help page opens it there. `onCopy` adds a
"Copy to editor" button to each cell, which the playground uses, and
`setTheme("light" | "dark")` switches the theme. `onTheme` adds a
light/dark switch to the menu and is told the theme chosen there.
`assets/index.html` is the page `pyk pykhelp` serves, with that switch;
its choice is kept in the browser.

| Option | |
|---|---|
| `pagesURL` | where the generated pages are served; `pages/` beside `help.js` |
| `notebookURL`, `webrunURL`, `vendorURL`, `pykingURL` | the notebook, the shared scripts, the vendored editor and the compiler |
| `theme` | `"light"` or `"dark"` |
| `start` | the slug of the first page shown |
| `onCopy` | `(code) => ...`, where a cell's "Copy to editor" puts its code |
| `onTheme` | `(theme) => ...`, told when the menu's light/dark switch is used |

`pyk` serves the help's scripts at `/help/` and the generated pages at
`/help/pages/`, for `pyk pykhelp` and `pyk playground` alike
(`src/web_tools.ml`, `common_site`).
