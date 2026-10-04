# webrun: what the Pyking web tools share

The playground (`../playground/`) and the notebook (`../notebook/`) both run
the real compiler in a browser, highlight Pyking with Ace, and are served by
a small Python server. What they have in common lives here, once.

```
tools/webrun/
  server.py              the server both tools start, and `make vendor`
  package.json           says the .js files are ES modules, for node
  assets/
    web.js               loading Ace, KaTeX and the compiler (ES module)
    pyking-runtime.js    the compiler as an object: PykingRuntime, JsRunner
    pyking-worker.js     the compiler on a thread of its own
    pyking-mode.js       the Ace mode for Pyking
  vendor/                Ace and KaTeX, downloaded by `make vendor`
```

## The server

`server.py` is a module the two tools import, not a server of its own. It
provides:

- **the Python check** — `require_python` refuses anything older than 3.10
  with one line saying so. The file stays parseable by an old Python so
  that the check, not a syntax error, is what such a Python reports.
- **a `Site`** — URL prefixes mapped to directories, exact paths mapped to
  files, and exact paths answered by a function per request. Everything is
  served from where it sits in the source tree, so there is no build step
  and an edit shows on the next reload. A path with `..` or a hidden
  component is refused.
- **`common_site()`** — what both pages load: `/webrun/` (`assets/`),
  `/vendor/` (`vendor/`), `/lib/` (the standard library, `lib/` at the
  root), `/pyking/pyking.js` (`build/pyking.js` at the root) and
  `/pyking/manifest.json`, whose stamp is a hash of the bundle, which a
  page re-reads to notice a rebuild under an open tab.
- **`serve()`** — a threaded server on `localhost`, a banner with a link, and
  a port: the one asked for with `--port`, else 8000 or the next free one.

Everything is found relative to this file: `tools/webrun/` two levels below
the root that holds `build/pyking.js`. A distribution keeps the same tree, so
the same lookup works in a checkout and in an install (see `docs/build.md`,
"The web tools").

## The vendored libraries

```sh
make vendor                              # at the repository root
python3 tools/webrun/server.py vendor    # the same
```

downloads Ace 1.43.4 (the editor, the modes the pages use, a light and a
dark theme) and KaTeX 0.16.22 (math in the notebook, with its woff2 fonts)
from jsdelivr into `vendor/`, about 1.2 MB, once. A file already present is
not fetched again. Both tools refuse to start without them and say how to
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
| `ensureKatex(vendor)` | loads KaTeX and its stylesheet |
| `loadScript`, `loadStyle`, `fetchJSON`, `fetchText` | the obvious, once per URL where it matters |

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

**The compiler is loaded before the editors are made**, because the Ace
mode's word lists come from it: the worker's `words` request answers the
keywords, builtins and targets the compiler has, and the JavaScript value
formatter the playground's generated code is run with. Nothing here keeps a
copy of any of them, so none can drift from the language.

`pyking-runtime.js` and `pyking-worker.js` are described in
`../playground/README.md` ("How programs are executed", "Embedding it in
another page"): every compile and run happens on the worker, so a program
that never ends can be stopped by terminating it.
