# Building the compiler

How `src/` becomes `./pyk`, how the same code becomes the JavaScript the
playground runs, and why the split between the two is where it is. For
what each module *holds*, see [source.md](source.md); for the pipeline
they form, see [architecture.md](architecture.md).

```
make                build the compiler into ./pyk, then make libs
make libs           build the interpreter's library plugins in lib/
make test           the test suite (make stest for one at a time)
make playground     serve the web playground (pyk playground)
make notebook       serve PYKING-TUTORIAL.md as a notebook (pyk notebook)
make vendor         download the browser libraries the two above need
make packaging      build the installable packages (on a Mac)
make clean          remove _build/, ./pyk, lib/'s plugins, __pycache__/
```

`make` builds three things: `./pyk`, the compiler,
`build/pyking.js`, the same compiler as JavaScript, and a plugin for
every library under `lib/` (`make libs`, below). The second is what
the `iweb` target ships beside a program and what the playground runs,
and it is built here so there is one copy of it — the playground and
the notebook serve this file rather than building their own.

Both are copied out of `_build/`, since nobody would think to run them
from there. The copy is `cp -f` because dune leaves what it
builds read-only, and so is the copy — a second `make` would otherwise
fail to overwrite it.

**`./pyk` is a build artifact.** It is not a script any more and is not
checked in; `make clean` removes it. That is the exception that shows
the rule about what `clean` may delete: `make` chose the name itself, so
it knows the file is its own, where a *compiled program* is written
wherever the caller asked, under a name indistinguishable from
hand-written source in every target language.

## One library, one executable

`src/dune` declares two things.

**The library `pyking`** is everything pure: the lexer, the parser, the
AST, the analyses, the type checker, the optimizer, the interpreter, and
every backend. It depends on nothing outside the OCaml standard library.
Nothing in it opens a file, starts a process, or reads a terminal.

**The executable `pyk`** adds the modules that do talk to the outside
world — `pyk.ml` (the driver, which reads the source file and writes the
output), `execution.ml` (`--run`, which starts processes), `repl.ml`
(the prompt, which puts a terminal in raw mode) and `plugin_host.ml`
(which compiles and loads an external module's OCaml implementation) —
and is the only half that links `unix` and `dynlink`. It is linked
`-linkall`, so every module of the standard library and of `unix` is in
it: a plugin may use one `pyk` never does itself.

**The library `pyk_plugin`** (`src/plugin/`) is one module, the registry
a plugin fills in when it is loaded. It is a library of its own,
unwrapped and linked only into the executable, because a plugin is
compiled outside this build and has to name it by a stable name --
`Pyk_plugin` -- and find its interface: `make` copies
`pyk_plugin.cmi` to `build/plugin/`, beside `build/pyking.js`, and a
package ships it there.

## The library plugins

`make libs` runs `./pyk plugins lib`, which compiles each
`lib/<name>/<name>_external.ml`, with a registration file generated from
its declarations, into `<name>_external.cmxs` beside it, and writes
`<name>_external.digest` -- what it was built from -- beside that. The
interpreter loads those to run the standard library, and uses one only
where its digest is what it would build now; a plugin that is already
is left alone, so a second `make` builds nothing. Both files are build
output, ignored by git and removed by `make clean`. See
[libraries.md](libraries.md), "How the interpreter reaches an OCaml
implementation".

The line between them is not tidiness. It is what makes the second build
possible: a library that cannot touch a process or a terminal is a
library js_of_ocaml can compile, and the browser then runs the same
type checker, the same interpreter and the same backends the terminal
does, rather than a second implementation that would drift.

The library is **unwrapped**, so its modules are reached by their own
names — `Parser.parse`, not `Pyking.Parser.parse` — and one module names
another directly. That also means the module graph has to be acyclic:
two modules of one library that refer to each other do not link. It is
why `repl.ml` is *handed* `pyk.ml`'s `format_error` as a parameter
instead of calling it (see [pyk.md](pyk.md)).

Every module has an **`.mli`** beside it, in both halves, holding what
another module may use and nothing else. See
[interfaces.md](interfaces.md) for the map of them and for what is
public where. The two entry points are the exception: `pyk.ml` and
`web/pyking_web.ml` are what a `let () = ...` runs rather than modules
anything calls, and dune gives an executable's main module an empty
interface of its own.

Warnings are on but not fatal (`-warn-error -a`), so a build fails on a
real error and not on an unused binding left behind mid-edit. With the
`.mli` files in place, an unused *private* value now warns too, which is
the compiler saying it is dead.

## The browser build

`src/web/dune` builds `pyking_web.bc.js`: the same library, plus one
entry-point module and one hand-written JavaScript stub.

- **`src/web/pyking_web.ml`** is the entry point. It registers
  `pykCompile`, `pykRun`, `pykTargets`, `pykFormatHelper`, `pykKeywords`
  and `pykBuiltins`, and does nothing a backend or the driver does not
  already do.
- **`src/web/stub.js`** is the boundary. It declares four primitives
  (`pyk_register0`, `pyk_register1`, `pyk_register3`, `pyk_emit`) with
  js_of_ocaml's `//Provides:` comments, which is all that is needed to
  put an OCaml function on the global object. No OCaml JS binding
  library is involved, which is what keeps the dependency list at
  js_of_ocaml alone, and only for this directory.

The pages ask the loaded bundle, through the worker's `words` request,
for the target list, the keyword and builtin lists, and the JavaScript
runtime's formatter. So the playground's target menu, both tools' syntax
highlighting and the playground's value formatting all come from the
compiler rather than from a hand-kept copy. See `tools/webrun/README.md`.

One thing about js_of_ocaml is load-bearing rather than incidental: its
`int` is 32 bits, where a native OCaml `int` is 63. Anything that
depends on the width has to say so.

A Pyking `Int` is one such thing, and the answer is deliberately *not*
to normalise it: an `Int` holds at least the signed 32-bit range and
overflow is undefined (PYKING.md), so the interpreter leaves results as
the host computes them. The consequence is that **the playground and the
terminal disagree past 2^31** — `2147483647 + 1` is `2147483648` under
`pyk` and `-2147483648` in the browser. Both conform, because the
language promises nothing there. What *is* the same on both is which
programs are accepted: `lexer.max_int_literal` fixes the largest literal
at 32 bits whatever the host, so the front end refuses the same source
wherever it runs.

## What is needed to build, and what is not

Building the compiler needs OCaml and dune, and nothing else. Building
the browser bundle additionally needs js_of_ocaml.

Running the *generated code* needs whatever that target's host needs —
`node` for the JavaScript targets, a C compiler for `c89`/`c23`, a JDK
for the Java ones, `ocamlopt` for `ocaml5.5` — but none of that is needed
to *produce* the code, and none at all to run a program with
`pyk <file>`, which is the interpreter. The one exception is a program
importing an external module of its own: the interpreter compiles that
module's plugin on demand, which needs the OCaml `pyk` was built by.

The test harness (`tests/test_script.py`) is Python 3.11+, and so are
`make vendor` and the website build. All are tooling around the
compiler, not part of it.

The website (`make website`) is the one part that needs packages from
npm: Astro and Starlight, pinned in `tools/site/package-lock.json` and
installed into `tools/site/node_modules/` the first time it is built.
It also needs node 22.12 or later. None of it is needed to build, test
or use the compiler, and nothing of it is shipped.

## The web tools

`pyk playground`, `pyk notebook FILE.md` and `pyk pykhelp` start a web
page that runs the compiler in the browser: the playground, a Markdown
document whose Pyking code blocks are runnable cells, and the help.
None of them is built. Each is a directory of JavaScript, CSS and HTML
under `tools/`, served from where it sits by `pyk` itself; the help's
pages are the one thing generated, by `tools/help/help.py` into
`build/help/` when `make` builds the compiler:

```
tools/webrun/     what both share: the compiler's worker and runtime,
                  the Ace mode, the Monaco language, and vendor/
                  (Ace, KaTeX, Monaco)
tools/playground/ its page
tools/notebook/   its page, and check.js for test mode
tools/help/       its page (assets/), and help.py, which writes build/help/
build/pyking.js   the compiler, which every page loads
build/help/       the help's pages, as Markdown, with index.json
```

`src/web_tools.ml` says what each page serves -- directories beside the
running executable, the notebook's document, and what is worked out per
request: `notebook.json`, the playground's manifest of targets and
examples, the bundle's stamp. Every tool serves the notebook's scripts
at `/notebook/` and the help at `/help/` (its pages at `/help/pages/`),
since the playground's Help tab is the help and its examples are the
notebook's cells -- and `src/web_server.ml` serves it on
127.0.0.1 in the `pyk` process, so nothing else has to be installed.
`$PYKING_WEB_HOST` names another address to listen on; the Docker
image sets it to `0.0.0.0`, since a container's own 127.0.0.1 cannot be
reached from outside it.
`pyk serve DIR` serves a directory's files the same way, which is what
`--run` does for a `web24` or `iweb24` page. `tools/webrun/server.py`
and `tools/playground/playground.py` say the same layout in Python, for
the website build and `make -C tools/playground check`, which run in a
checkout; `tests/test_notebook.py` checks that `pyk` serves every file
they name and the same manifest. `pyk notebook --mode test` serves
nothing: it runs `tools/notebook/check.js` under node, which checks the document's
exercises and quizzes and runs its programs, so test mode needs node. `make playground` and `make notebook` go through `./pyk` the same
way, after `make vendor` has downloaded Ace, KaTeX and Monaco once.

A program using a library that needs a page -- `tinyweb` -- is shown by
both pages with that library's own renderer, `lib/tinyweb/tinyweb_page.js`,
mounted by `tools/webrun/assets/pages.js` from `lib/`: the notebook
under the cell, the playground on its Web output tab. Everywhere else the
program serves its page itself, once it calls `tinyweb.web_init(port)`
-- `pyk program.pyk` and the REPL as much as a compiled program (see
[libraries.md](libraries.md), "tinyweb").

### What a distribution needs

The compiler is one native executable with no OCaml runtime to install:
`./pyk` needs nothing but the C library to compile or interpret a
program, the standard library included, since its plugins ship beside
it. OCaml, dune and js_of_ocaml are needed to *build* it, never to use
it -- save to interpret a program with an external module of its own.

The web tools add none: `pyk` serves them. Only `pyk notebook --mode
test` needs node. A distribution is a subset
of this repository's tree, kept at the same relative paths so that one
lookup — beside the executable — works in a checkout and an install
alike:

```
pyk                   the compiler
lib/                  the standard library, with its plugins
build/pyking.js       the compiler as JavaScript, for the pages
build/plugin/         what a plugin is compiled against
tools/webrun/         including vendor/, downloaded before packaging
tools/notebook/
tools/playground/
src/examples.toml     the examples, and each program it names
```

The playground's examples are the ones `pyk example` lists:
`src/examples.toml` and the programs it names, which a distribution
ships at the same paths. Without the list the page starts with a short
program of its own and offers no example menu.

`pyk` finds that tree through `src/install.ml`, which resolves every
symbolic link on the way to the running executable first: a package
manager's `bin/pyk` is a link into the directory the tree was installed
in, and the tree is beside the target, not beside the link.

## The website

`make website` builds the Pyking website into `website/` (gitignored): a
static site that any web server can serve from its root. It is Astro
with Starlight, driven by `tools/site/site.py`, and is made from the
help -- the pages `pyk pykhelp` and the playground's Help tab show -- and
the runtime:

```
sitesrc/          the pages, in Markdown: the start page, install,
                  getstarted/, documentation/ -- written by hand
PYKING.md         the language reference
lib/              the library pages, one per module, generated by
                  tools/help/libdoc.py from the `##` comments
tools/            the runtime the pages run: what `pyk playground`
                  serves, the notebook's scripts and the help among it
```

`tools/help/help.py` writes the first three as the help's pages; `site.py`
stages them, tinyweb's pages for other languages and the runtime in
`tools/site/build/` (gitignored) and runs Astro over the staged copy,
which writes `website/`. Nothing is generated into `sitesrc/` or `lib/`.
The header holds the five sections and the search; the menu on the
left is the section's pages, the one being read opened at its headings.

A ```` ```pyking ```` block on a page is a runnable cell. A remark plugin
(`tools/site/src/remark-pyking-cells.mjs`) turns it into the placeholder
`mountCells` in `tools/notebook/assets/notebook.js` makes runnable, so a
cell on the site is the notebook's own cell, and the fences mean what
they mean in a notebook. The playground page mounts `mountPlayground` from
`tools/playground/assets/`. Both load their scripts from `runtime/` in the
built site, which `site.py` writes with the same `Site` the playground's
server uses, so a page finds `webrun/`, `vendor/`, `pyking/` and `lib/`
where it would under `pyk playground`.

`make website-dev` serves the staged site with Astro's dev server. It
stages once on start; restart it to see an edit to `sitesrc/` or `lib/`.
`PYKING_SITE_BASE` builds for a sub-path instead of the root, and
`PYKING_SITE_URL` sets the site's address, which Astro needs for a
sitemap. `tests/test_site.py` checks the library documentation and runs
every example on the site with the interpreter, without Astro.
`make website-release` publishes it at <https://pyking.org/>
(`tools/site/publish.py`): built afresh from a committed, pushed HEAD,
committed with `gh` to the GitHub Pages repository
`pyking-lang/pyking-lang.github.io` -- one commit per upload, with
`.nojekyll` and a `CNAME` naming the domain -- and waited for until Pages
serves it there over HTTPS. The domain's DNS records are in
`tools/site/README.md`, "The domain".
`tools/site/README.md` is the long form.

## Packaging

`make packaging` builds that tree into installable packages, with
`tools/packaging/packaging.py`, writing them into `tools/packaging/build/`,
and `make release` publishes them. Two formats build a `pyk`, each holding one
that needs nothing but the system's C library, and the library plugins
compiled by the toolchain that built that `pyk`, since a plugin loads
only into an executable its own compiler built:

- **Homebrew**, for macOS 11 or later: a tarball holding a universal
  `pyk` (arm64 and x86_64) and a formula that installs it. It is built on
  an Apple Silicon Mac by two opam switches made for releases, whose
  OCaml was compiled for macOS 11 (the x86_64 one runs under Rosetta),
  and the halves are joined with `lipo`. An everyday switch is refused:
  its runtime was compiled for the macOS it was created on, and linking
  it would break the macOS 11 promise. A binary that links anything
  outside the system's own libraries is refused too. Each
  architecture's plugins are compiled by its own switch and joined with
  `lipo` like the binary.
- **Linux**, for every distribution and WSL: a `pyk` linked against
  glibc 2.28, built in an AlmaLinux 8 container per architecture (x86_64
  and aarch64, one of them emulated), shipped as a tarball -- which the
  one-line installer `install.sh` installs -- and as a `.deb`. It is
  dynamically linked because the interpreter loads plugins, which a
  static binary cannot; one asking for a glibc newer than the floor is
  refused, and the built tree is run, plugins and all, in current Debian
  and in Debian 10.

Two more are made from the Linux tarballs and build nothing:

- **Docker**: each architecture's tarball unpacked on Debian 13, as
  `ghcr.io/pyking-lang/pyking` (pyk alone) and `:full` (with Python,
  node, gcc, a JDK and the Linux build image's OCaml, so `--run` works
  for every target), from `tools/packaging/docker/Dockerfile`. The image
  sets `PYKING_WEB_HOST=0.0.0.0`, so a published port reaches the web
  tools. Both are run before they are kept, the playground fetched from
  outside the container.
- **Nix**: a flake installing each system's release tarball by its
  sha256, `autoPatchelfHook` fitting the Linux `pyk` to Nix's glibc. It
  is locked, evaluated and built from the local tarball in a `nixos/nix`
  container, so no machine needs Nix.

A partial build (`FORMATS=`, `ARCHS=`) is possible and cannot be
published. `make packaging-setup` makes the toolchains once. One release
of the public repository `pyking-lang/pyking-releases` holds every
platform's files, the formula goes to the tap
`pyking-lang/homebrew-tap`, the flake is committed to
`pyking-lang/pyking-releases` (so it is `github:pyking-lang/pyking-releases`),
and the images are pushed to `ghcr.io/pyking-lang/pyking`. `tools/packaging/README.md` has the one-time
setup, the release steps and the install instructions.

The version is the `VERSION` file at the root. `src/dune` turns it into
`version.ml` when the executable is built, so `pyk --version` and the
package built from the same tree cannot disagree.
