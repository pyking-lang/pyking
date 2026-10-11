# The Pyking website

The website: a start page with a runnable example, Install, Getting
started, a reference for every library, and the playground. It is
[Astro](https://astro.build) with
[Starlight](https://starlight.astro.build).

```sh
make website        # build it into website/
make website-dev    # serve it with Astro's dev server (PORT=n for the port)
```

`website/` is a static site, served from the root of any web server:
`python3 -m http.server -d website` is enough to look at it. Like the
playground, it runs everything in the browser: the compiler bundle runs
each example and the playground with the interpreter.

## What it needs

`make website` builds the compiler and `build/pyking.js` first, and
downloads Ace and KaTeX (`make vendor`). It needs **node 22.12 or later**
and npm. The first build runs `npm ci` here, which installs the pinned
Astro and Starlight into `node_modules/` (gitignored). It installs with
`--no-bin-links`, and Astro is run as `node node_modules/astro/bin/astro.mjs`, so
a filesystem without symbolic links (a network mount, for one) works.
`make distclean` removes `node_modules/`, and `make clean` removes
`website/` and `build/`.

## Where things are

```
sitesrc/                    the pages, by hand (at the repository root)
  index.md                  the start page
  install.md                Install
  getstarted/               Getting started: one page per file
  404.md
lib/                        the libraries the reference is generated from

tools/site/
  site.py                   what make website runs: stage, install, build
  libdoc.py                 lib/ -> one Markdown page per module
  tinywebdoc.py             tinyweb for other languages: pages and downloads
  tinyweb/                  the example in each language those pages show
  astro.config.mjs          Starlight: title, sidebar, header, highlighting
  src/sections.mjs          the four sections, for the header and sidebar
  src/content.config.mjs    the pages come from build/content/
  src/remark-pyking-cells.mjs   ```pyking blocks -> cell placeholders, and
                                exercises and quizzes -> fragments
  src/components/HeaderNav.astro  the header's menu
  src/pages/playground.astro      the playground page
  src/styles/site.css       the site's own styles
  public/site/cells.js      makes a page's cells runnable
  build/                    staged by site.py (gitignored)
```

`site.py build` does three things in order:

1. **Stages** into `build/`: `content/` is a copy of `sitesrc/` plus
   `libraries/`, written by `libdoc.py`, and
   `libraries/tinyweb-languages/`, written by `tinywebdoc.py`: one page
   per language tinyweb is implemented in, for using it with no Pyking.
   Each has a zip in `public/tinyweb/<language>/` holding the library
   under that language's own name (`tinyweb.py`, `tinyweb.js`,
   `tinyweb.ml` and `tinyweb.mli`, `tinyweb.c` and `tinyweb.h`,
   `Tinyweb.java`), the example from `tinyweb/` and the samples, and one
   zip per tinyweb test, compiled with `./pyk` for that language. The
   functions' descriptions are one table in `tinywebdoc.py`; the `.h`
   and `.mli` are written from it. The tinyweb page ends with links to
   them. `tests/test_tinyweb.py` builds and
   runs each language's library and example. `sidebar.json` lists the
   pages of Getting started and Libraries for `astro.config.mjs`, since
   Starlight's `autogenerate` finds pages only under
   `src/content/docs/`. `public/` is `public/` plus
   `runtime/`, which holds what `pyk playground` serves (the shared web
   scripts, `vendor/`, the bundle and its manifest, `lib/`, the playground's
   assets and examples) and the notebook's scripts, each at the URL path the
   server gives it. `pyking.tmLanguage.json` is the grammar code blocks are
   highlighted with, made from the compiler's own keyword and builtin lists
   (`pykKeywords`, `pykBuiltins`). Astro's cache is emptied.
2. **Installs** with `npm ci` if `node_modules/` is missing or older than
   `package-lock.json`.
3. **Builds** with Astro, into `website/`.

`site.py stage` does only the first step. `site.py dev` stages, then
starts Astro's dev server over `build/`. It stages once, so restart it
after editing `sitesrc/` or `lib/`.

## Writing a page

A page is Markdown with Starlight's front matter (`title`, `description`,
and `sidebar.order` for its place in its section, then `sidebar.label`
or `title`). A new file under `sitesrc/getstarted/` appears in Getting
started by itself, and a subdirectory of a section is a group labelled
by its `index.md`.

A ```` ```pyking ```` block is a **cell**: a whole program a reader can edit
and run. The fences are the notebook's (`tools/notebook/README.md`):

````markdown
```pyking
print("runs")
```

```pyking error
x = 1
x := 2          # meant to be refused
```

```pyking norun
def f(x): ...   # highlighted only
```

```stdin
Ada
```

```pyking
import io
print(io.read_line())   # reads "Ada"
```
````

`readonly` keeps a cell from being edited. A ```` ```stdin ```` or
```` ```args ```` block just before a cell fills in its input and is not
shown. Every runnable cell is run by `tests/test_site.py`, so an example
that stops working fails `make test`.

A page may hold the notebook's exercises and quizzes too
(`tools/notebook/README.md`, "Exercises and quizzes"), in student mode,
with progress kept per page. The remark plugin writes each run of
adjacent blocks that holds one -- or the rules, a stdout block, or input
on a cell's header -- back into one `.pkn-fragment` placeholder as
Markdown, which `mountCells` renders and makes work. `tests/test_site.py`
checks every page for the problems the notebook finds in them.

How a cell works: `remark-pyking-cells.mjs` turns the block into a
`.pkn-cell` placeholder inside a `.pkn-notebook` element, carrying its
attributes and input as data attributes. `public/site/cells.js` runs on
every page, and on a page that has a placeholder it loads
`runtime/notebook/notebook.js` and calls `mountCells`. The cells then
share one compiler worker and follow the site's light or dark theme.

## The library reference

`libdoc.py` writes one page per directory of `lib/`, from the module's
one or two files (`<name>.pyk`, `<name>_external.pyk`). Only `##`
comments are documentation. A plain `#` comment is a note for whoever
maintains the library and is never published:

```pyking norun
## Standard input and standard output.      <- opens the file: the module
##
## More about the module, in Markdown.
#
# A note for maintainers, not published.

## One line of standard input, without its line ending.
public def read_line(prompt: String = "") -> String:
    return prompt_line(prompt)
```

- A `##` block that **opens** a file describes the module. Write it in
  one of the two halves only. Its first sentence is the module's summary
  on the Libraries page.
- A `##` block **directly above** a `public` line describes what that
  line exports. The line itself, without `public`, is shown as the
  signature, so the types on the page are the ones the checker holds the
  library to.
- Values come before functions, each group alphabetical.

`python3 tools/site/libdoc.py` lists anything undocumented, and
`tests/test_site.py` fails on it. That suite also checks that every name
a page lists is one the module exports, by compiling a program importing
them all.

## Configuration

| Variable | Default | |
|---|---|---|
| `PYKING_SITE_BASE` | `/` | the path the site is served under |
| `PYKING_SITE_URL` | unset | the site's address, for the sitemap |

`trailingSlash` is `"always"`, so a page is `/install/`, served from
`install/index.html`.
