# Pyking playground

An editor in a web page with a compile button, showing the generated Python,
JavaScript, C, Java or OCaml beside it — and running the result. **Nothing
executes on the server.** The real compiler from `src/` runs inside the
browser: `src/` compiled to JavaScript by
[js_of_ocaml](https://ocsigen.org/js_of_ocaml/), so the page runs the same
front end, the same type checker, the same interpreter and the same backends
`pyk` does.

```sh
make          # vendor, build, check, serve — then open the printed link
```

The first `make` downloads ~1 MB of Ace into `vendor/` and caches it; later
builds are offline and instant.

## Why this design

There is **no Python runtime in the page**. The compiler is OCaml, and
`src/`'s pure half is a library that opens no file, starts no process and
reads no terminal — which is exactly what js_of_ocaml can compile. The page
therefore ships the compiler itself rather than an interpreter that runs it:
one 5 MB `pyking.js`, built by `dune build src/web/pyking_web.bc.js`. See
[../../docs/build.md](../../docs/build.md).

The one thing the library does not have is a browser entry point.
`src/web/pyking_web.ml` is that: it registers `pykCompile`, `pykRun`,
`pykTargets`, `pykFormatHelper`, `pykKeywords` and `pykBuiltins` on the
global object through the four `//Provides:` primitives in
`src/web/stub.js`. It is checked in beside the compiler, not generated here
— `generator.py` only builds it and asks it questions.

The three modules the library deliberately leaves out are the ones that talk
to the outside world: `pyk.ml` (the driver), `execution.ml` (`--run`) and
`repl.ml` (the prompt). None of them is needed to compile a string.

## What `make` does

| Target | |
|---|---|
| `make` | `vendor` → `build` → `check` → `serve` |
| `make build` | regenerate `build/` from `generator.py` |
| `make vendor` | download Ace into `vendor/` (cached; skipped if present) |
| `make check` | compile every example for every target it claims, headlessly |
| `make e2e` | browser tests — mounting, compiling, running, Stop (needs Playwright) |
| `make serve` | rebuild the compiler bundle if `src/` moved on, serve `build/`, print a clickable `http://localhost:8000/` |
| `make clean` | remove `build/` |
| `make distclean` | also remove `vendor/` |

Variables: `PORT=9000` (auto-advances if busy), `CDN=1` (see below),
`PYTHON=python3.12`.

`make check` is worth knowing about: it runs all 270 examples through the
same `pyking.js` the page loads, under `node` — over 1300 example/target
pairs — so a regressed backend fails the build without a browser being
involved.

### `CDN=1`

By default Ace is vendored, so the built directory is entirely
self-contained and works with no internet. `make CDN=1` skips the download and
points the page at jsdelivr instead: the build drops from 6.1 MB to 5.5 MB,
at the cost of needing internet on every page load. The compiler itself is
always local — it is not on any CDN — so this only moves the editor.

### It must be *served*

`file://` will not work — browsers block the module and WebAssembly loads the
page needs. This is the same constraint the compiler's own `web` target
documents (see `docs/target_js.md`), and the reason
`make` ends by starting a server rather than telling you to open a file. Any
static host will do; nothing runs server-side.

## What the page does

```
┌──────────────────────────────────────────────────────────────────┐
│ Pyking Playground                 ● compiler: ready  [≡ Settings]│
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
- **▶ Run** on the left runs the program with the **interpreter**, whatever
  target is selected — the "just run my program" button. The interpreter is
  the reference for what a program means (`docs/interpreter.md`), and it is
  compiled into the same bundle, so this needs no host at all.
- **▶ Run** on the right executes exactly what is displayed. Enabled for
  `node24` and `web24`, which the browser can genuinely execute.
  Disabled for `python`, `c89`/`c23`, `java*` and `ocaml5.5`, with a tooltip
  saying why: there is no Python interpreter, C compiler, JVM or OCaml
  runtime in a browser. That is a property of the target, not a shortcoming
  here.
- **Target** lists every target the compiler has, plus `ast` — the
  target-independent view of the parsed program, which is what every backend
  starts from.
- **Example** lists all 270 programs from `tests/`, grouped by whether they
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
    can never start the compiler loading while the dialog is still open.
  - **Scrollable** output — on by default. Off clips the pane instead, and
    also stops it auto-following the newest line: scrolling programmatically
    while clipped would push the start of the output out of reach.
  - **Clear it each time you press Run** — on by default. Only *Run* clears;
    compiling deliberately does not, so a compile error stays beside the
    output you were comparing it against.
  - **Reset pane sizes**.

  There is no type-checking switch: Pyking is statically typed, so every
  compile here checks, exactly as `pyk` does, and a program the checker
  refuses is refused whichever button you press. Seeing what it worked
  out is the **pyking** target in the dropdown — Pyking compiled back to
  Pyking, carrying the types the checker inferred. There is then no
  generated code, so the generated pane's ▶ Run is disabled: it runs
  *what is shown*, and that view is a program rather than code a host
  could run.

  Close it with `Esc`, the ✕, or a click on the backdrop. Every setting, and
  both split positions, are remembered in `localStorage`, so the layout you
  set is the one you come back to.
- **`Shift`+`Enter` runs** — the same as the **▶ Run** button of whichever
  pane has focus: in the source pane it runs the program with the
  interpreter, in the generated pane it runs what is displayed. With focus anywhere else it
  runs the source. `Ctrl`/`Cmd`+`Enter` compiles;
  `Ctrl`/`Cmd`+`Shift`+`Enter` also runs.

  Shift+Enter is registered as an Ace *command*, not as a key listener on the
  container: Ace handles keys on its own hidden textarea first, so a listener
  would only fire after Ace had already typed the newline. Overriding it
  loses nothing, since plain `Enter` inserts a newline anyway and Shift+Enter
  merely duplicated it.

The compiler loads lazily on the first compile or run, not on page load, so
the page appears immediately and the status pill reports progress.

### How long the first compile takes

Pressing **Compile** the first time fetches the compiler. The status pill
names the phase and counts seconds, so you can tell working from frozen:

| Pill | What is happening | Typical |
|---|---|---|
| `starting… 1s` | booting the worker | instant |
| `loading compiler… 1s` | fetching and evaluating the 5 MB `pyking.js` | well under a second served locally |
| `ready in 0.6s` | done — it stays warm for the session | — |

After that, compiling is **about a millisecond**, and running is as fast as
the generated code.

A reload does not repeat the fetch: the server marks `assets/vendor/`
cacheable for a day while everything `make` regenerates stays `no-store`, so
you can rebuild and reload without ever debugging a stale asset.

**The compiler cannot go stale under you either**, which needs more than
cache headers: `build/pyking/pyking.js` is a *copy* of what dune built, and
the page fetches it once, at boot. So there are two ways to end up with the
page running one compiler while `pyk` runs another, and each has its own
answer. `make serve` rebuilds the bundle from `src/` and re-copies it before
it serves, saying so when it moved on — so editing the compiler and
re-serving is enough, without the full rebuild that also re-copies the
vendored editor. And `manifest.json` carries a **stamp** of the bytes it
names, which the page re-reads before every compile: a tab left open across
a rebuild reloads its worker rather than going on answering with the
compiler it started with. Nothing else in `build/` is covered — a change to
the page itself, the examples or the Ace mode still needs `make build`.

> **If it seems to hang at `starting…`** on an old build: the dev server used
> to be single-threaded. Browsers open several connections at once and
> speculatively pre-connect ones they never use, and one idle pre-connect
> blocked the whole server — the page would wait indefinitely for files that
> were never sent. `make serve` now uses `ThreadingHTTPServer`; re-run
> `make build` (or just `make`) to pick it up. `python3 -m http.server` has
> the same flaw, so prefer `make serve` over serving `build/` by hand.

### How programs are executed, and how they are stopped

**Nothing runs on the main thread.** That is the whole design, and it exists
for one case: a program that never terminates. If the compiler's own
interpreter ran on the main thread an endless loop would freeze the tab —
including the button you would press to stop it — and no amount of care in
the UI could recover.

| What | Runs on | Stopped by |
|---|---|---|
| the source, via the interpreter | the compiler worker | `terminate()`, then a fresh worker boots |
| `node24`, `web24` | the JavaScript worker | `terminate()` |

A **sandboxed iframe is not good enough** for either of them, which is why
they moved. A same-process iframe shares the main thread, so a loop inside
one can still lock the page; browsers only isolate it when site isolation
happens to apply. A worker is *guaranteed* a separate thread and
`terminate()` is *guaranteed* to end it — measured at ~5 ms, against a loop
that was ignoring everything else.

Every target now runs on a worker: `web24` emits the same ES module
`node24` does and prints to the console, so nothing is left that needs a
frame of its own.

Two consequences worth knowing:

- **Output streams as it is produced.** `pykRun` posts each line across as
  the interpreter produces it, through the `pyk_emit` primitive, rather than
  the run returning everything at the end. So a program that prints and
  *then* hangs still shows what it printed — which is exactly the case you
  want to see.
- **Stopping costs the loaded compiler.** `terminate()` reclaims the thread
  whatever the interpreter was doing, which is the point, but the worker's
  copy of the compiler goes with it. A replacement starts immediately and is
  usually warm again before the next run is asked for.

Generated JavaScript is imported as a real module from a blob URL. A
compiled program is several files now — the module being looked at, the
modules it imports, and the shared `pyk-runtime.js` — so the worker gives
each a blob URL and rewrites the relative import specifiers to point at
them, because a module loaded from a blob has no base to resolve
`./x.js` against. Nothing else is touched: the text in the pane is what
runs, edits included. Its
`print` formats values with the JavaScript backend's **own** `pykFormat`,
lifted out of `src/target_js_packaging.ml` at build time rather than
hand-copied, so the playground cannot disagree with `node prog.js` about
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
costs: booting the worker, loading the compiler, compiling, then executing —
so the first Run of a session is interruptible too. Stopping during the boot
is reported as stopped rather than as a failure.

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
program. That works for the interpreter and for the JavaScript targets
alike.

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
    pyking-worker.js         the compiler bundle, on its own thread
    js-worker.js             generated JavaScript, on its own thread
    pyking-mode.js           Ace syntax mode for Pyking
    playground.css           all styles, scoped under .pyk-playground
    playground.json          targets, editor modes, examples — drives the UI
    vendor/ace/…             Ace + the modes the targets need
  pyking/
    pyking.js                the compiler, built from src/ by dune and
                             js_of_ocaml, copied here byte for byte
    manifest.json            what the runtime loads, and the stamp saying
                             which compiler that is
  examples/
    *.pyk                    copied from tests/
```

### The bundle is evaluated, not required

`generator.py` asks the compiled compiler for the target list, the word
lists and the formatter by running it under node — and it does that by
*reading* `build/pyking.js` and evaluating it, rather than `require`ing
it.

That looks roundabout and is not. The bundle is a classic script, but
node decides a `.js` file's module system from the nearest
`package.json`: one saying `"type": "module"` anywhere above the
repository makes it an ES module, and `require` of an ES module works on
some node versions and fails with `ERR_REQUIRE_ESM` on others. Reading
the text sidesteps the module system, so the generator behaves the same
wherever the repository sits and whichever node is installed. The one
thing evaluation needs supplying is `require` itself — a module-local in
CommonJS, which js_of_ocaml's runtime calls — so it is put on
`globalThis` first.

`check.cjs` does the same, and is named `.cjs` for the same reason.

### Four things read out of the repository

The playground cannot drift from the compiler, because it does not restate
anything the compiler already knows. Three of the four are *asked of the
built bundle*, with `node`, rather than parsed out of the source:

1. **The compiler** is `dune build src/web/pyking_web.bc.js`, copied into
   `build/pyking/pyking.js` byte for byte — never forked, and never edited
   here.
2. **The target list** comes from `pykTargets`, which is `pyk.ml`'s own
   `targets`, itself assembled from the backends. So a new target appears in
   the dropdown automatically. `generator.py` fails the build if a target
   turns up that has no editor mode assigned, rather than silently showing
   it unhighlighted.
3. **The keyword and builtin lists** in `pyking-mode.js` come from
   `pykKeywords` and `pykBuiltins` — `lexer.keywords` and
   `analyses.builtins` — and **the value formatter** in `js-worker.js` from
   `pykFormatHelper`, which is the JavaScript backend's own `pykFormat`.
   (`tools/emacs/` warns in its own commentary that a hand-copied keyword
   list goes stale silently; these cannot. The formatter was a hand-copy
   once, and it drifted the moment booleans stopped printing capitalised —
   hence the rule.)
4. **The examples and their target support** come from `tests/*.pyk` and
   `tests/test_cases.toml` — the same manifest `make test` runs from, so the
   page cannot claim support the test suite does not. A program of several
   modules is the one thing left out, along with the modules it imports:
   the page compiles one file and has no filesystem, so there is nothing
   for an `import` to reach (see `docs/modules.md`).

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
  pykingURL: "./pyking/",
  workerURL: "./assets/pyking-worker.js",
});
await rt.ready(status => console.log(status));   // the compiler is fetched here

const result = await rt.compile("print(1 + 2)\n", "java17");
// { ok: true, files: { "Playground.java": "…" } }

const failed = await rt.compile("print(nope)\n", "python");
// { ok: false, stage: "Name error", text: "'playground.pyk' 1:6-1:10 …",
//   info: { row1: 1, col1: 6, row2: 1, col2: 10 } }

// The front end's own view of the program, types and all -- the `pyking`
// target, which is what the dropdown's first entry selects:
const view = await rt.compile("x = 1 + 2\n", "pyking");
// { ok: true, files: { "playground.pyk": "x: Int = 1 + 2" },
//   views: ["playground.pyk"] }

// Run it with the interpreter -- no host, no generated code:
await rt.runProgram(source, { onOutput: text => process.stdout.write(text) });
rt.stop();     // ends a program that will not end itself, and re-boots
```

`compile` and `runProgram` are asynchronous because they cross a thread
boundary — everything happens on a worker (see above). Relative URLs are
resolved against the page before being handed over, so `"./assets/…"` means
what you expect: inside a worker a relative URL would otherwise resolve
against the *worker's* location, which is how `./pyking/` once became
`/assets/pyking/`. Generated JavaScript has its own runner with the same
shape:

```js
import { JsRunner } from "./assets/pyking-runtime.js";

const js = new JsRunner("./assets/js-worker.js");
await js.run("script", nodejsSource, { onOutput: line => console.log(line) });
js.stop();
```

A successful result also carries `views`: the names in `files` that are a
view of the front end (the `pyking` target) rather than code a host
could run. The page
uses it to keep its Run button honest, and an embedder that runs generated
code should skip them the same way.

`compile()` never throws for a bad program — a refusal is data, with the same
wording `pyk.ml` prints, because it *is* `pyk.ml`'s `format_error`. The raw
span comes with it, for highlighting: rows count from 1 and columns from 0,
exactly as `lexer.info` records them (Ace counts both from 0, hence the
`row1 - 1` in `playground.js`).

## Verifying without a browser

Most of this is testable headlessly, and worth re-running after changing the
compiler:

```sh
make check                       # every example/target pair, through the shim
make e2e                         # the same page, in a real browser
```

`make check` needs Python and `node`. Every example is compiled for the
`pyking` target as well as for every target it claims, and the
type-checker fixtures under `tests/` are held to the rule their names
state — `typecheck_*` must check, `fail_typecheck_*` must
not. That rule is why the entry point runs `Module.check_publics`: what a
module exports is a property of the one file, so a program the compiler
refuses for exporting one name twice has to be refused here too. A
`fail_typecheck_*` fixture is held to *only* that rule: some of them
are not valid programs at all (one names something unbound), so expecting
them to compile any other way would be expecting the front end to miss what
they exist to catch. What those programs *infer* is `tests/test_script.py`'s
business; this only proves the checker is reached through the page's own
entry point. `make e2e` needs Playwright — the one
dependency anywhere in this tool, which is why it is a separate target and
why the script prints an install line and exits cleanly when it is absent:

```sh
npm install playwright && npx playwright install chromium
```

It is worth having, because there is a class of defect nothing headless can
see: Ace, the worker plumbing and the page's own wiring only exist in a
browser. `make e2e` starts its own server on a free port and drives the built
page: that it mounts with every target in the dropdown, that Compile loads
the compiler and produces a file, that the `pyking` target prints the front
end's own output, that both Run buttons produce output, that **every example
compiles for every target it claims** — the same pairs `make check` compiles,
but through the page's worker rather than under `node` — and that Stop ends a
program written never to end (`loop: continue`) with the page still
answering. Any error on the console fails the run.

## Limitations

- **Needs a static server** (above). No way around it for ES modules and
  workers.
- **About 6 MB on first load**, cached by the browser afterwards — 5.1 MB
  of it the compiler. `CDN=1` moves the editor's share rather than the
  compiler's.
- **A non-terminating program no longer freezes the tab.** Execution happens
  on workers, so the page stays responsive and the Stop button ends it (see
  "How programs are executed" above). This is what makes "run while you type"
  safe to leave on: a loop that never ends can be stopped, and the edit that
  fixes it can still be typed.
- **C and Java output is display-only.** Copy it out and build it locally —
  the header comment in each generated file gives the exact command.

## What the page does not offer

`iweb24` is missing from the target list on purpose. That target packages
a program *with* the interpreter so a browser can run it — which is what
this page already is. It has nothing to add here, and could not build its
own page anyway without a copy of `pyking.js` to ship.
