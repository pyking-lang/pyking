# The Pyking website

The website: a start page with a runnable example, Install, Getting
started, a reference for every library, and the playground. It is
[Astro](https://astro.build) with
[Starlight](https://starlight.astro.build).

```sh
make website        # build it into website/
make website-dev    # serve it with Astro's dev server (PORT=n for the port)
make website-release  # publish it at https://pyking-lang.github.io/
```

`website/` is a static site, served from the root of any web server:
`pyk serve website` is enough to look at it. Like the
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
  documentation/            Documentation: Editors (the language reference
                            is PYKING.md)
  404.md
lib/                        the libraries the reference is generated from
PYKING.md                   the language reference

tools/help/                 the help: the pages above, as Markdown, which
                            this site, the playground and pyk pykhelp share
  help.py                   writes them, with index.json
  libdoc.py                 lib/ -> one Markdown page per module

tools/site/
  site.py                   what make website runs: stage, install, build
  tinywebdoc.py             tinyweb for other languages: pages and downloads
  tinyweb/                  the example in each language those pages show
  astro.config.mjs          Starlight: title, components, highlighting
  src/sections.mjs          the five sections, for the header and the menu
  src/content.config.mjs    the pages come from build/content/
  src/content/i18n/en.json  Starlight's UI strings (it warns without them)
  src/remark-pyking-cells.mjs   ```pyking blocks -> cell placeholders, and
                                exercises and quizzes -> fragments
  src/components/Header.astro     the logo and the sections, the search
  src/components/HeaderNav.astro  the header's sections
  src/components/Sidebar.astro    the left menu: the section's pages
  src/assets/logo.svg       the logo, a python wearing a crown (also the
                            favicon, public/site/favicon.svg)
  src/pages/playground.astro      the playground page
  src/styles/site.css       the site's own styles
  public/site/cells.js      makes a page's cells runnable
  build/                    staged by site.py (gitignored)
```

`site.py build` does three things in order:

1. **Stages** into `build/`: `content/` is the help, written by
   `tools/help/help.py` -- `sitesrc/`, the language reference from
   PYKING.md and `libraries/` from `lib/` -- and
   `documentation/tinyweb/`, written by `tinywebdoc.py`: one page
   per language tinyweb is implemented in, for using it with no Pyking.
   Each has a zip in `public/tinyweb/<language>/` holding the library
   under that language's own name (`tinyweb.py`, `tinyweb.js`,
   `tinyweb.ml` and `tinyweb.mli`, `tinyweb.c` and `tinyweb.h`,
   `Tinyweb.java`), the example from `tinyweb/` and the samples, and one
   zip per tinyweb test, compiled with `./pyk` for that language. The
   functions' descriptions are one table in `tinywebdoc.py`; the `.h`
   and `.mli` are written from it. The tinyweb page ends with links to
   them. `tests/test_tinyweb.py` builds and
   runs each language's library and example. `sidebar.json` is each
   section's left menu -- its pages, each with its `##` headings, made
   from the help's `index.json` -- which `src/components/Sidebar.astro`
   shows for the section being read, the current page opened at its
   headings; there is no table of contents on the right. `public/` is
   `public/` plus `runtime/`, which holds what `pyk playground` serves
   (the shared web scripts, `vendor/`, the bundle and its manifest,
   `lib/` -- its Pyking sources, its browser scripts and the sounds a
   page plays -- the playground's assets and examples, the notebook's
   scripts and the help), each at the URL path the server gives it. `pyking.tmLanguage.json` is the grammar code blocks are
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
started by itself, in the left menu and in the playground's Help tab,
and one under `sitesrc/documentation/` in Documentation. Its `##`
headings are the menu's links into it.

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

`tools/help/libdoc.py` writes one page per directory of `lib/`, from the module's
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
  line exports, in sections: Parameters, Returns and Examples, each
  example with the output it prints (`tools/help/README.md`, "Documenting
  a library"). The line itself, without `public`, is shown as the
  signature in a box with the rest, so the types on the page are the
  ones the checker holds the library to.
- Values come before functions, each group alphabetical.

`python3 tools/help/libdoc.py` lists anything undocumented or documented
wrongly, and `tests/test_site.py` fails on it, and on an example that
does not print what its documentation says. That suite also checks that every name
a page lists is one the module exports, by compiling a program importing
them all.

## Configuration

| Variable | Default | |
|---|---|---|
| `PYKING_SITE_BASE` | `/` | the path the site is served under |
| `PYKING_SITE_URL` | unset | the site's address, for the sitemap |

`trailingSlash` is `"always"`, so a page is `/install/`, served from
`install/index.html`.

## Publishing

`make website-release` publishes the site at
<https://pyking-lang.github.io/>, with `publish.py` beside this file. That
address is GitHub Pages' site of the organisation, served from the root
of the public repository `pyking-lang/pyking-lang.github.io` with
GitHub's own certificate, so HTTPS needs no setup. The repository is
made once:

```sh
gh repo create pyking-lang/pyking-lang.github.io --public --description "The Pyking website"
```

and `gh` must be logged in (`gh auth login`) as someone who may push to
it and change its Pages settings.

- **It checks first**, before building: that `gh` is logged in, that git
  has a name and an email for the commit, that no tracked file has
  uncommitted changes and HEAD is already on GitHub in
  `pyking-lang/pyking` -- so the site is a commit anyone can see -- and
  that the Pages repository exists and is public. Any version may be
  published, so a fix to a page can go out between releases.
- **It builds** `website/` afresh from the working tree, with
  `PYKING_SITE_URL=https://pyking-lang.github.io/` (the sitemap's
  addresses) and the base `/`, says what it is about to push, and asks.
  `make website-release YES=1` does not ask.
- **It commits** the site to `main` of the Pages repository, on top of
  the last upload -- one commit per upload, "Pyking 0.2.0 website, from
  pyking-lang/pyking@<commit>" -- replacing every file but `.git`. Beside
  the site go `.nojekyll`, without which Pages leaves out every path
  starting with `_` (Astro's `_astro/`), and a README naming the commit.
  A site that has not changed is not committed again.
- **It configures Pages** to serve `main` at its root, creating the site
  the first time, and enforces HTTPS, which redirects `http://`.
- **It waits** -- up to ten minutes -- until Pages has built the upload
  and `https://pyking-lang.github.io/` serves it: the README with the
  commit, and the front page as it was built. It ends with one line,
  **SUCCEEDED** or **FAILED** with the reason.

To publish an older site again, check out its commit and run it there;
the Pages repository's history holds every upload, and Pages serves
whatever `main` is.
