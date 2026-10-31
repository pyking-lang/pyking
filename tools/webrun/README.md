# webrun: what the Pyking web tools share

The playground (`../playground/`) and the notebook (`../notebook/`) both run
the real compiler in a browser, highlight Pyking -- the playground with
Monaco, the notebook with Ace -- and are served by `pyk` itself (`src/web_server.ml`). What they have in common lives here,
once.

```
tools/webrun/
  server.py              `make vendor`, and the Site the website copies
  package.json           says the .js files are ES modules, for node
  assets/
    web.js               loading Ace, Monaco, KaTeX and the compiler (ES module)
    pyking-runtime.js    the compiler as an object: PykingRuntime, JsRunner
    pyking-worker.js     the compiler on a thread of its own
    pages.js             PageHost: where a library that needs a page shows it
    pyking-mode.js       the Ace mode for Pyking
    pyking-monaco.js     the Monaco language and themes for Pyking
  vendor/                Ace, KaTeX and Monaco, downloaded by `make vendor`
```

## The server

`pyk notebook` and `pyk playground` serve the pages with
`src/web_server.ml`, in the `pyk` process, and `src/web_tools.ml` says
what each serves: the layout below. Nothing here is shipped or run by
them. `server.py` holds the same layout for the tooling that runs in a
checkout -- the website build, which copies what the pages load
(`tools/site/site.py`), and `playground.py`'s `make check` -- and
`tests/test_notebook.py` checks that `pyk` serves every file it names.
It provides:

- **a `Site`** — URL prefixes mapped to directories, exact paths mapped to
  files, and exact paths answered by a function per request. Everything is
  served from where it sits in the source tree, so there is no build step
  and an edit shows on the next reload. A path with `..` or a hidden
  component is refused.
- **`common_site()`** — what both pages load: `/webrun/` (`assets/`),
  `/vendor/` (`vendor/`), `/lib/` (the standard library, `lib/` at the
  root), `/pyking/pyking.js` (`share/pyking.js` at the root) and
  `/pyking/manifest.json`, whose stamp is a hash of the bundle, which a
  page re-reads to notice a rebuild under an open tab.

`pyk` serves on `localhost`, prints a banner with a link, and takes the
port asked for with `--port`, else 8000 or the next free one. It finds
everything beside its own executable: `tools/webrun/` and
`share/pyking.js` under the same root. A distribution keeps the same
tree, so the same lookup works in a checkout and in an install (see
`docs/build.md`, "The web tools").

## The vendored libraries

```sh
make vendor                              # at the repository root
python3 tools/webrun/server.py vendor    # the same
```

downloads Ace 1.43.4 (the notebook's editor, the modes it uses, a light
and a dark theme) and KaTeX 0.16.22 (math in the notebook, with its woff2
fonts) from jsdelivr, and Monaco 0.57.0 (the playground's editor) as its npm
tarball, of which only the prebuilt `package/min/vs/` is kept, as
`vendor/monaco/vs/`: about 26 MB in all, once. A file already present is
not fetched again; Monaco is fetched again only when the marker naming its
version, `vendor/monaco/monaco-editor-<version>.json`, is missing. Both tools refuse to start without them and say how to
get them; `make distclean` removes them. The test suite sets
`PYKING_WEB_NO_VENDOR=1`, since it fetches pages without rendering them and
must run without a network.

## In the browser

`web.js` is what a page imports:

| | |
|---|---|
| `createRuntime({webrun, pyking, lib})` | a `PykingRuntime`, not yet booted |
| `splitArguments(text)` | a line of arguments as a program receives them, split at spaces with quotes keeping one together |
| `ensureEditor(runtime, {webrun, vendor}, onStatus)` | boots the compiler, loads Ace and the Pyking mode; answers the compiler's words |
| `ensureMonaco(runtime, {vendor}, onStatus)` | boots the compiler, loads Monaco with its own AMD loader and registers the Pyking language; answers `{words, monaco}` |
| `LANGUAGE`, `themeFor(name)` | the Pyking language's Monaco id, and the Monaco theme for `"dark"`, `"light"` or a theme's own name |
| `ensureKatex(vendor)` | loads KaTeX and its stylesheet |
| `loadScript`, `loadStyle`, `fetchJSON`, `fetchText` | the obvious, once per URL where it matters |
| `new PageHost(element, {libURL, send})` | shows what a program sends its page, with the library's own renderer |

Every URL defaults to one beside `web.js` itself (`../vendor/`,
`../pyking/`, `../lib/`), which is the layout the server serves.

**A program run in a page may import the standard library.** The worker
answers the bundle's `pykFetchSource` with a synchronous fetch of
`lib/<module>/<file>` the first time a module is named, and runs a
program in two steps: `analyze`, which asks the compiler which of its
modules are implemented in JavaScript and whether it reads standard
input or `sys.args()`, and `run`, which imports each of those modules'
browser implementation from `lib/` and runs the program. `io` and `sys`
are the worker's own: standard output is the page's output (`stdout`
messages), standard input and the arguments are what `run` was given,
each line the program reads is echoed (`stdin`), and `sys.exit` ends the
run with `{ok: true, exit}`. A `debug` line arrives as a `debug` message,
which a page shows apart from the output. The worker's `console.log`
writes to the output too, since that is where a browser implementation
says what it cannot do. A run needing no JavaScript module imported
answers synchronously, which is what lets the notebook's test suite
drive the worker under node.

**A program may show a page.** A library that needs one -- `tinyweb` --
posts `{type: "page", module, data}` from the worker itself; the runtime
hands it to the run's `onPage`, and a page shows it with a `PageHost`,
which mounts the library's renderer (`mountPage` from
`lib/<module>/<module>_page.js`) in an element the page chose. The
worker imports a library's `<module>_external_interpreter.js` where it
has one -- tinyweb's sends commands -- and its
`<module>_external_browser.js` otherwise. What the renderer reports goes back with
`runtime.sendEvent(module, event)` as an `event` message, which carries
no `id` and gets no reply: the worker hands it to the module's
`pykDeliver`. A run that sent its page anything is *live* after it
answers -- its `onOutput` and the rest stay attached -- until the next
run, `endLive()` or `stop()`, which call its `onEnd`. A callback that
fails arrives as `failure`, and a `sys.exit` in one as `exit`. Each run
imports fresh instances of the libraries, so one run's callbacks never
answer another's events. See `docs/libraries.md`, "A library that needs
a page".

**The compiler is loaded before the editors are made**, because the Ace
mode's and the Monaco language's word lists come from it: the worker's `words` request answers the
keywords, builtins and targets the compiler has, the JavaScript value
formatter the playground's generated code is run with, and the warnings
its checks can report. Nothing here keeps a
copy of any of them, so none can drift from the language.

**Warnings.** `runtime.setWarnings(flags)` says which warnings every
later check reports, as `pyk`'s -W flags (`["-Wall", "-Werror"]`),
applied to the defaults in order. The runtime sends them with every
request, so a worker started afresh -- after `stop()`, or the REPL's --
checks with them too, and the worker hands them to the bundle's
`pykSetWarnings` where they changed. What a check finds arrives as a
`warning` message, a line as `pyk` prints it on stderr: a run's,
`debugProgram`'s and a `compile`'s at their `onWarning`, a REPL entry's
in its answer's `warnings`. The language server's diagnostics follow
the same flags. A warning made an error refuses the program, in
`compile`'s shape with `stage` "Warning". The `words` request answers
every warning there is, `{name, on, description}`, which is what the
playground's settings list. See docs/warnings.md.

**Code for a slide.** `runtime.highlight(source, options = {})` colours
Pyking source as `pyk highlight` does (`src/highlight.ml`, through the
bundle's `pykHighlight` and the worker's `highlight` request) and
resolves to `{html, rtf, text}`: an HTML `<pre>` with every style
inline, a complete RTF document, and plain text, each with leading
spaces as non-breaking spaces by default so a slide exported to PDF
keeps its indentation when the code is copied out. A page puts all
three on the clipboard (`text/html`, `text/rtf`, `text/plain`) and a
slide program pastes the one it likes. It waits for the compiler to
load, and rejects with the reason where an option is refused. The
options and their defaults are the command's:

| Option | Values | Default |
|---|---|---|
| `theme` | `"light"`, `"dark"` -- the playground's `pyking-light` and `pyking-dark` colours | `"light"` |
| `font` | a font's name, in letters, digits, spaces, `-`, `_` and `.`; HTML falls back to `monospace` | `"Menlo"` |
| `size` | points, a whole number from 1 to 1000, or `null` for the application's | `null` |
| `background` | `"none"`, `"theme"` (the theme's), or `"#rrggbb"` | `"none"` |
| `spaces` | `"indent"` (leading spaces as U+00A0), `"all"` (every space but those inside a string literal), `"none"` | `"indent"` |

`pyking-runtime.js` and `pyking-worker.js` are described in
`../playground/README.md` ("How programs are executed", "Embedding it in
another page"): every compile and run happens on the worker, so a program
that never ends can be stopped by terminating it.
