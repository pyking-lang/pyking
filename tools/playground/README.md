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
│ Pyking Playground                        ● Pyodide: ready    ⚙   │
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
- **The ⚙ icon opens settings**, as an in-page dialog rather than a window:
  editor **font size** (10–26 px, applied to both editors and the output
  pane) and a **Reset pane sizes** button. Close it with `Esc`, the ✕, or a
  click on the backdrop. Font size and both split positions are remembered
  in `localStorage`, so the layout you set is the one you come back to.
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

### Running the JavaScript targets

Generated JavaScript runs in a throwaway `<iframe sandbox="allow-scripts">`.
The sandbox is what makes it safe to offer at all: a runaway loop in generated
code cannot be interrupted, but the frame can be removed, which stops it —
there is a 5-second watchdog that does exactly that.

- `nodejs` output is a classic script that prints through `console.log`, so
  the frame shims `console.log` and posts each line back.
- `esm` output is a module exporting `run(runtime)`. It is inlined into a
  `<script type="module">` and driven with a `print` that implements the
  formatting rule from `src/runtime_interface.py` (booleans print `True` /
  `False`). That mirrors what the generated node driver does — formatting is
  the *host's* job, which is why each generated wrapper carries its own copy.
- `html` output is already a complete, self-contained page, so it is simply
  shown in the preview frame.

Python runs in Pyodide on the main thread, so a non-terminating Pyking
program will freeze the tab. All the bundled examples terminate.

## Layout

Checked in — note there is no `index.html` here; it is generated:

```
tools/playground/
  Makefile
  generator.py     the single source for every generated file
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
   `src/lexer.py` and `src/analyses.py` while generating it. (`tools/emacs/`
   warns in its own commentary that a hand-copied keyword list goes stale
   silently; this one cannot.)
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
});
await rt.ready(status => console.log(status));   // the big download happens here

const result = rt.compile("print(1 + 2)\n", "java17");
// { ok: true, files: { "Playground.java": "…" } }

const failed = rt.compile("print(nope)\n", "python");
// { ok: false, stage: "Name error", text: "'playground.pyk' 1:6-1:10 …",
//   info: { row1: 1, col1: 6, row2: 1, col2: 10 } }

rt.runPython(code);   // { ok, output, traceback? }
```

`compile()` never throws for a bad program — a refusal is data, with the same
wording `pykboot.py` prints and the raw span for highlighting. Rows count from
1 and columns from 0, exactly as `lexer.Info` records them (Ace counts both
from 0, hence the `row1 - 1` in `playground.js`).

## Verifying without a browser

Most of this is testable headlessly, and worth re-running after changing the
compiler:

```sh
make check                       # 244 example/target pairs through the shim
```

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
- **A non-terminating program freezes the tab** for the `python` target.
  The JavaScript targets are protected by the iframe watchdog; moving Pyodide
  into a web worker would fix the rest.
- **C and Java output is display-only.** Copy it out and build it locally —
  the header comment in each generated file gives the exact command.
