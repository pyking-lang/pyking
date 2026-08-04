# Pyking playground

An editor in a web page with a compile button, showing the generated Python,
JavaScript, C or Java beside it — and running the result. **Nothing executes
on the server.** The real compiler from `src/` runs inside the browser, under
[Pyodide](https://pyodide.org) (CPython compiled to WebAssembly).

```sh
make          # vendor, build, check, serve — then open the printed link
```

The first `make` downloads ~12 MB of Ace and Pyodide into `vendor/` and
caches it; later builds are offline and instant.

## Why this design

`advice-pyking-on-web.md` at the repository root works through the options in
full. The short version is that the compiler is 51 KB of gzipped source but
leans on `dataclasses`, which drags in CPython's whole introspection stack
(`inspect`, `ast`, `dis`, `tokenize`, `annotationlib`) — 22 stdlib modules in
all. That rules out MicroPython, Transcrypt and the other lightweight
runtimes, and leaves a real CPython. Pyodide *is* real CPython, so the
compiler ships unmodified: `src/*.py` is copied into the build verbatim.

The one thing missing from `src/` is a callable entry point — `pykboot.py` is
a script that reads `argv`, opens files and calls `sys.exit`. The generator
emits a small `pyking_web.py` beside the copied modules that exposes the same
stage sequence as two functions returning values. Everything else in `src/`
is already pure: `os` and `sys` appear only in `pykboot.py`.

## What `make` does

| Target | |
|---|---|
| `make` | `vendor` → `build` → `check` → `serve` |
| `make build` | regenerate `build/` from `generator.py` |
| `make vendor` | download Ace + Pyodide into `vendor/` (cached; skipped if present) |
| `make check` | compile every example for every target it claims, headlessly |
| `make e2e` | browser tests — layout, workers, Stop (needs Playwright) |
| `make serve` | serve `build/`, print a clickable `http://localhost:8000/` |
| `make clean` | remove `build/` |
| `make distclean` | also remove `vendor/` |

Variables: `PORT=9000` (auto-advances if busy), `CDN=1` (see below),
`PYTHON=python3.12`.

`make check` is worth knowing about: it runs all 54 examples through the
generated `pyking_web.py` under your host CPython — 244 example/target pairs —
so a broken shim or a regressed backend fails the build without a browser
being involved.

### `CDN=1`

By default Ace and Pyodide are vendored, so the built directory is entirely
self-contained and works with no internet. `make CDN=1` skips the download and
points the page at jsdelivr instead: the build drops from 12.6 MB to 0.3 MB,
at the cost of needing internet on every page load. Useful for CI or a quick
look; the default is better for anything you intend to hand to someone.

### It must be *served*

`file://` will not work — browsers block the module and WebAssembly loads the
page needs. This is the same constraint the compiler's own `esm` target
documents for its HTML wrapper (see `docs/target_js.md`), and the reason
`make` ends by starting a server rather than telling you to open a file. Any
static host will do; nothing runs server-side.

## What the page does

```
┌──────────────────────────────────────────────────────────────────┐
│ Pyking Playground                  ● Pyodide: ready  [≡ Settings]│
├────────────────────────────────╥─────────────────────────────────┤
│ Source        [example ▾]      ║ Target [▾]                      │
│           [Compile →] [▶ Run]  ║              [▶ Run]  [⧉ Copy]  │
│ ┌────────────────────────────┐ ║ ┌─────────────────────────────┐ │
│ │ Pyking, highlighted        │ ║ │ generated code, highlighted │ │
│ │ errors underlined in place │ ║ │ for the selected target     │ │
│ │                            │ ║ └─────────────────────────────┘ │
│ │                            │ ║ ═══════════ drag ═══════════════│
│ │                            │ ║ Output                [Clear]   │
│ │                            │ ║ ┌─────────────────────────────┐ │
│ │                            │ ║ │ text, or a live page preview│ │
│ └────────────────────────────┘ ║ └─────────────────────────────┘ │
└────────────────────────────────╨─────────────────────────────────┘
                                 ↑ drag
```

- **Compile →** turns the left pane into the right pane. The arrow is there to
  make the direction obvious.
- **▶ Run** on the left compiles to Python and runs it, whatever target is
  selected — the "just run my program" button.
- **▶ Run** on the right executes exactly what is displayed. Enabled for
  `python` (via Pyodide) and for `nodejs`, `esm` and `html`, which the browser
  can genuinely execute. Disabled for `c89`/`c23`/`java*`, with a tooltip
  saying why: there is no C compiler or JVM in a browser. That is a property
  of the target, not a shortcoming here.
- **Target** lists every target the compiler has, plus `ast` — the
  target-independent view of the parsed program, which is what every backend
  starts from.
- **Example** lists all 54 programs from `tests/`, grouped by whether they
  work on every target or only on `python`. Picking a python-only example with
  a JavaScript target selected is *not* prevented: seeing the compiler refuse
  it, with a source position, is the point.
- Compile errors are written to the output pane *and* underlined in the
  source editor at the exact span the compiler reported.
- **The three panes resize.** Drag the bar between the two columns, or the
  one between the generated code and the output, to trade space between
  them. Each split is clamped to 12–85 % so a pane can be made small but
  never dragged out of existence — a zero-width editor is easy to reach and
  impossible to grab back.
- **The Settings button** (top right) opens an in-page dialog rather than a
  window:
  - **Font size**, 10–26 px, applied to both editors and the output pane.
  - **Run while you type** — **off** by default. On, the source runs about
    half a second after you stop typing, exactly as if you had pressed Run.
    Only typing in the *source* counts: loading an example, or the generated
    pane being rewritten by a compile, does not trigger it. Ticking the box
    does not run anything either — the next keystroke does — so enabling it
    can never start the runtime download while the dialog is still open.
  - **Scrollable** output — on by default. Off clips the pane instead, and
    also stops it auto-following the newest line: scrolling programmatically
    while clipped would push the start of the output out of reach.
  - **Clear it each time you press Run** — on by default. Only *Run* clears;
    compiling deliberately does not, so a compile error stays beside the
    output you were comparing it against.
  - **Enable typechecker** and **Print AST output** — the compiler's own
    `--typecheck` and `--ast`, both **off** by default. Each changes what
    compiling means, so nobody gets them without asking:
    - *Enable typechecker* runs `src/typesystem.py` and, exactly as `pyk`
      does, uses it *instead of* the name analysis. It covers only a
      fragment of the language so far and refuses the rest with `Construct
      is not supported`, so it will reject most examples — that floor is
      the point, not a bug. It applies to **Run** as well: a program the
      checker rejects is rejected whichever button you press.
    - *Print AST output* stops after the front end and shows the
      pretty-printed Pyking AST, whatever target is selected — the same
      view as the `ast` target, and with the type checker on it carries the
      types that were inferred. There is then no generated code, so the
      generated pane's ▶ Run is disabled: it runs *what is shown*, and an
      AST is a view of the program rather than code any host could run.
  - **Reset pane sizes**.

  Close it with `Esc`, the ✕, or a click on the backdrop. Every setting, and
  both split positions, are remembered in `localStorage`, so the layout you
  set is the one you come back to.
- **`Shift`+`Enter` runs** — the same as the **▶ Run** button of whichever
  pane has focus: in the source pane it compiles to Python and runs that, in
  the generated pane it runs what is displayed. With focus anywhere else it
  runs the source. `Ctrl`/`Cmd`+`Enter` compiles;
  `Ctrl`/`Cmd`+`Shift`+`Enter` also runs.

  Shift+Enter is registered as an Ace *command*, not as a key listener on the
  container: Ace handles keys on its own hidden textarea first, so a listener
  would only fire after Ace had already typed the newline. Overriding it
  loses nothing, since plain `Enter` inserts a newline anyway and Shift+Enter
  merely duplicated it.

Pyodide loads lazily on the first compile or run, not on page load, so the
page appears immediately and the status pill reports progress.

### How long the first compile takes

Pressing **Compile** the first time starts the Python runtime. The status pill
names the phase and counts seconds, so you can tell working from frozen:

| Pill | What is happening | Typical |
|---|---|---|
| `downloading Python (~12 MB, first load only)… 3s` | fetching Pyodide, then compiling an 8.25 MB WebAssembly binary | 1–5 s served locally |
| `loading compiler… 4s` | mounting the 11 compiler modules and importing them | ~0.15 s |
| `ready in 4.2s` | done — it stays warm for the session | — |

After that, compiling is **about a millisecond**, and running is as fast as
the generated code. Measured end to end from local disk, the runtime work is
~0.9 s; the rest is transfer and WebAssembly compilation.

A reload no longer repeats the download: the server marks `assets/vendor/`
cacheable for a day while everything `make` regenerates stays `no-store`, so
you can rebuild and reload without ever debugging a stale asset *and* without
re-fetching Pyodide.

> **If it seems to hang at `starting…`** on a build from before this was
> fixed: the dev server used to be single-threaded. Browsers open several
> connections at once and speculatively pre-connect ones they never use, and
> one idle pre-connect blocked the whole server — the page would wait
> indefinitely for files that were never sent. `make serve` now uses
> `ThreadingHTTPServer`; re-run `make build` (or just `make`) to pick it up.
> `python3 -m http.server` has the same flaw, so prefer `make serve` over
> serving `build/` by hand.

### How programs are executed, and how they are stopped

**Nothing runs on the main thread.** That is the whole design, and it exists
for one case: a program that never terminates. If Pyodide ran on the main
thread an endless loop would freeze the tab — including the button you would
press to stop it — and no amount of care in the UI could recover.

| Target | Runs on | Stopped by |
|---|---|---|
| `python` | the Pyodide worker | `terminate()`, then a fresh worker boots |
| `nodejs` (script) | the JavaScript worker | `terminate()` |
| `esm` (module) | the JavaScript worker | `terminate()` |
| `html` | an iframe preview | removing the frame |

A **sandboxed iframe is not good enough** for the first three, which is why
they moved. A same-process iframe shares the main thread, so a loop inside
one can still lock the page; browsers only isolate it when site isolation
happens to apply. A worker is *guaranteed* a separate thread and
`terminate()` is *guaranteed* to end it — measured at ~5 ms, against a
Python loop that was ignoring everything else.

Only `html` still uses a frame, because it **is** a page: it draws into its
own document rather than printing. Removing the frame stops it, which is what
Stop does.

Two consequences worth knowing:

- **Output streams as it is produced.** Pyodide's `setStdout` posts each line
  across as the program prints it, rather than the run returning everything
  at the end. So a program that prints and *then* hangs still shows what it
  printed — which is exactly the case you want to see.
- **Stopping Python costs the interpreter.** `terminate()` reclaims the
  thread whatever the interpreter was doing, which is the point, but the
  Pyodide instance goes with it. A replacement starts immediately and is
  usually warm again before the next run is asked for; the status pill says
  `restarting Python` until it is.

The `esm` module is imported as a real module from a blob URL and handed a
`print` — the source runs exactly as written, with no rewriting to make it
fit. That `print` formats values with the JavaScript backend's **own**
`pykFormat`, lifted out of `src/target_js_packaging.py` at build time rather
than hand-copied, so the playground cannot disagree with `node prog.js` about
how a value prints.

### The Stop button

**Run becomes Stop while a program is running**, and turns back into Run when
it ends — one control that changes meaning, rather than two competing for the
same corner. While something is executing, starting another one is not what
that slot is for.

The pair is sized as a single control (same `min-width`, padding and font,
set together in the stylesheet) and Stop is Run's immediately preceding
sibling, so only one is ever displayed and the swap cannot shift the toolbar
by a pixel. Both are a little larger than the other buttons, being the ones
you aim for.

The swap happens the instant Run is pressed and covers everything that press
costs: booting the runtime, compiling, then executing — so the first Run of a
session, which spends several seconds on the Pyodide download, is
interruptible too. Stopping during the boot is reported as stopped rather
than as a failure.

It was originally a separate button delayed by 0.6 s, on the reasoning that a
quick run should not make a control flash past. That was the wrong trade: the
button exists for programs that do not stop, and those are exactly the ones
where any moment without it is a moment stuck — and a delay makes "is it
working?" indistinguishable from "is it hung?".

For a fast run the swap happens and reverses within a few milliseconds, which
is just what a run that quick looks like. To watch it actually do its job,
paste a program that does not terminate and press Run:

```pyking
var i = 0
while i < 1:
    i := 0
```

The page stays responsive, Run has become Stop, and clicking it ends the
program. That works for the `python` target and for `nodejs` / `esm` alike.

## Layout

Checked in — note there is no `index.html` here; it is generated:

```
tools/playground/
  Makefile
  generator.py     the single source for every generated file
  e2e.mjs          browser tests (optional; see "Verifying" below)
  README.md
  .gitignore       build/, vendor/
```

Generated into `build/`:

```
build/
  index.html                 thin host page: mounts the component, nothing else
  assets/
    playground.js            the UI (ES module, exports mountPlayground)
    pyking-runtime.js        the compiler as an object — no UI at all
    pyking-worker.js         Pyodide + the compiler, on their own thread
    js-worker.js             generated JavaScript, on its own thread
    pyking-mode.js           Ace syntax mode for Pyking
    playground.css           all styles, scoped under .pyk-playground
    playground.json          targets, editor modes, examples — drives the UI
    vendor/ace/…             Ace + the modes the targets need
    vendor/pyodide/…         the 5 pyodide-core files
  pyking/
    lexer.py parser.py …     copied verbatim from src/ (10 modules)
    pyking_web.py            generated: compile_source() and run_python()
    manifest.json            what the runtime fetches into Pyodide's filesystem
  examples/
    *.pyk                    copied from tests/
```

### Three things read out of the repository

The playground cannot drift from the compiler, because it does not restate
anything the compiler already knows:

1. **The compiler modules** are copied from `src/` at build time — never
   forked. `pykboot.py` is excluded; it is the CLI.
2. **The keyword and builtin lists** in `pyking-mode.js` are lifted out of
   `src/lexer.py` and `src/analyses.py` while generating it, and **the value
   formatter** in `js-worker.js` out of `src/target_js_packaging.py`.
   (`tools/emacs/` warns in its own commentary that a hand-copied keyword
   list goes stale silently; these cannot. The formatter was a hand-copy
   once, and it drifted the moment booleans stopped printing capitalised —
   hence the rule.)
3. **The examples and their target support** come from `tests/*.pyk` and
   `tests/test_cases.toml` — the same manifest `make test` runs from, so the
   page cannot claim support the test suite does not.

The **target list itself** is imported from the backends
(`target_js_packaging.TARGETS`, `target_c.STANDARDS`,
`target_java.VERSIONS`), so a new target appears in the dropdown
automatically. `generator.py` fails the build if a target turns up that has no
editor mode assigned, rather than silently showing it unhighlighted.

## Embedding it in another page

The split between `pyking-runtime.js` (no UI) and `playground.js` (all UI) is
there so you can take either one.

**The whole component**, in a page of your own:

```html
<link rel="stylesheet" href="assets/playground.css">
<div id="host" style="height: 90vh"></div>
<script type="module">
  import { mountPlayground } from "./assets/playground.js";
  mountPlayground(document.getElementById("host"), {
    base: "./assets",             // where the assets/ folder lives
    pykingURL: "./pyking/",       // where the compiler was copied
    examplesURL: "./examples/",   // where the .pyk files live
    initialTarget: "c23",
    initialExample: "arithmetic.pyk",
  });
</script>
```

Ace and the Pyking mode are loaded for you if they are not already present.
All paths are relative, so the build directory can be served from any
sub-path. Styles are scoped under `.pyk-playground` and use CSS custom
properties (`--pyk-bg`, `--pyk-accent`, …), so re-theming is a few overrides.

Note that every button-variant rule is written as `.pyk-playground .pyk-run`
rather than `.pyk-run`. The base rule is `.pyk-playground button`, which is
*more* specific than a bare class, so an unscoped variant silently loses its
colour and padding to it — which is exactly what happened until it was
caught.

Two details that matter when embedding. The settings dialog is positioned
*inside* the component's own box, not over the viewport, so it cannot cover
your page's chrome. And the pane splits are custom properties on the root
element (`--pyk-col-split`, `--pyk-out-split`), so you can set a starting
layout from your own CSS:

```css
#host { --pyk-col-split: 40%; --pyk-out-split: 25%; }
```

**Just the compiler**, with your own interface:

```js
import { PykingRuntime } from "./assets/pyking-runtime.js";

const rt = new PykingRuntime({
  pyodideIndexURL: "./assets/vendor/pyodide/",
  pykingURL: "./pyking/",
  workerURL: "./assets/pyking-worker.js",
});
await rt.ready(status => console.log(status));   // the big download happens here

const result = await rt.compile("print(1 + 2)\n", "java17");
// { ok: true, files: { "Playground.java": "…" } }

const failed = await rt.compile("print(nope)\n", "python");
// { ok: false, stage: "Name error", text: "'playground.pyk' 1:6-1:10 …",
//   info: { row1: 1, col1: 6, row2: 1, col2: 10 } }

// pyk's front-end flags, both off unless asked for -- what the settings
// dialog's last two checkboxes switch on:
const checked = await rt.compile("x = 1 + 2\n", "python", "playground.pyk",
                                 { typecheck: true, ast: true });
// { ok: true, files: { "playground.ast": "x: Int = 1 + 2" },
//   views: ["playground.ast"] }

await rt.runPython(code, { onOutput: text => process.stdout.write(text) });
rt.stop();     // ends a program that will not end itself, and re-boots
```

`compile` and `runPython` are asynchronous because they cross a thread
boundary — everything happens on a worker (see above). Relative URLs are
resolved against the page before being handed over, so `"./assets/…"` means
what you expect: inside a worker a relative URL would otherwise resolve
against the *worker's* location, which is how `./assets/vendor/pyodide/`
once became `/assets/assets/vendor/pyodide/`. Generated JavaScript
has its own runner with the same shape:

```js
import { JsRunner } from "./assets/pyking-runtime.js";

const js = new JsRunner("./assets/js-worker.js");
await js.run("script", nodejsSource, { onOutput: line => console.log(line) });
js.stop();
```

A successful result also carries `views`: the names in `files` that are a
view of the front end (`--ast`) rather than code a host could run. The page
uses it to keep its Run button honest, and an embedder that runs generated
code should skip them the same way.

`compile()` never throws for a bad program — a refusal is data, with the same
wording `pykboot.py` prints and the raw span for highlighting. Rows count from
1 and columns from 0, exactly as `lexer.Info` records them (Ace counts both
from 0, hence the `row1 - 1` in `playground.js`).

## Verifying without a browser

Most of this is testable headlessly, and worth re-running after changing the
compiler:

```sh
make check                       # every example/target pair, through the shim
make e2e                         # the same page, in a real browser
```

`make check` needs nothing but Python. It also exercises the two front-end
flags, neither of which is reachable by selecting a target: every example is
compiled once more with `--ast` against a target that would otherwise
generate code, and the type-checker fixtures under `tests/` are held to the
rule their names state — `typecheck_*` must check, `fail_typecheck_*` must
not. What those programs *infer* is `tests/test_script.py`'s business; this
only proves the flags reach the checker through the shim. `make e2e` needs Playwright — the one
dependency anywhere in this tool, which is why it is a separate target and
why the script prints an install line and exits cleanly when it is absent:

```sh
npm install playwright && npx playwright install chromium
```

It is worth having, because there is a class of defect nothing headless can
see. jsdom has no layout engine, so it can prove two CSS rules resolve alike
but not that a control is the right size; and node can model a Worker but not
run WebAssembly inside one. Both gaps hid real bugs — a Stop button that was
never styled at all, and a doubled URL path that broke startup outright — and
both are now covered: `make e2e` starts its own server, measures the real
geometry of the toolbar, boots Pyodide in a real worker, runs a program that
never terminates, and checks the page stays responsive while Stop ends it.

The build was additionally validated by driving the real vendored Pyodide from
node — mounting the compiler, compiling all nine targets, and confirming the
Python output matches `tests/subset_control.out` byte for byte — and by
running the generated `nodejs` and `esm` output against their `.out` files
using the same drivers the iframe uses. If you change how code is generated,
those are the properties to re-check.

## Limitations

- **Needs a static server** (above). No way around it for WebAssembly.
- **~12 MB on first load**, cached by the browser afterwards. `CDN=1` moves
  the bytes rather than removing them. The long-term fix is not a smaller
  Python but no Python: see "self-hosting" in `advice-pyking-on-web.md`.
- **A non-terminating program no longer freezes the tab.** Execution happens
  on workers, so the page stays responsive and the Stop button ends it (see
  "How programs are executed" above). This is what makes "run while you type"
  safe to leave on: a loop that never ends can be stopped, and the edit that
  fixes it can still be typed. The remaining exception is the `html` target,
  which needs a real frame to draw into — removing the frame stops it, but a
  same-process frame can still make the page stutter first.
- **C and Java output is display-only.** Copy it out and build it locally —
  the header comment in each generated file gives the exact command.
