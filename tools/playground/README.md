# Pyking playground

An editor in a web page with a compile button, showing the generated Python,
JavaScript, C, Java or OCaml beside it — and running the result. **Nothing
executes on the server.** The real compiler from `src/` runs inside the
browser: `src/` compiled to JavaScript by
[js_of_ocaml](https://ocsigen.org/js_of_ocaml/), so the page runs the same
front end, the same type checker, the same interpreter and the same backends
`pyk` does.

```sh
pyk playground   # serve it and print a link to open
make             # here: vendor, check, serve
```

**Nothing is built.** `pyk playground` serves `assets/`, the files the
playground shares with the notebook in `../webrun/`, the compiler bundle
`build/pyking.js` and the examples `src/examples.toml` lists from where they sit, so an
edit to any of them shows on the next reload. The first `make vendor` (at
the repository root or here) downloads ~26 MB of Ace, KaTeX and Monaco
into `../webrun/vendor/` and caches it; see `../webrun/README.md`.

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
— the page only loads it and asks it questions.

The three modules the library deliberately leaves out are the ones that talk
to the outside world: `pyk.ml` (the driver), `execution.ml` (`--run`) and
`repl.ml` (the prompt). None of them is needed to compile a string.

## What `make` does

| Target | |
|---|---|
| `make` | `vendor` → `check` → `serve` |
| `make vendor` | download Ace, KaTeX and Monaco into `../webrun/vendor/` (cached; skipped if present) |
| `make check` | check the targets and every example, headlessly |
| `make e2e` | browser tests — mounting, compiling, running, Stop (needs Playwright) |
| `make serve` | serve the page and print a clickable `http://localhost:8000/` |

Variables: `PORT=9000` (without it, 8000 or the next free port),
`PYK=path/to/pyk` (`make serve` runs `pyk playground`), and
`PYTHON=python3.12` for `make check`.

`make check` runs every example through the same `pyking.js` the page
loads, under `node`, checked the way the page's Run checks it, with the
standard library read from `lib/`.

### It must be *served*

`file://` will not work — browsers block the module and WebAssembly loads the
page needs. This is the same constraint the compiler's own `web` target
documents (see `docs/target_js.md`), and the reason
`make` ends by starting a server rather than telling you to open a file.
Nothing runs server-side, but the page's manifest (`assets/playground.json`)
is worked out per request from `tests/test_cases.toml`, so a static host
needs a copy of it saved once.

## What the page does

```
┌──────────────────────────────────────────────────────────────────┐
│ Pyking Playground  version 0.1.2  ● ready  [☀/☾]  [≡ Settings]   │
├────────────────────────────────╥─────────────────────────────────┤
│ Examples [▾] [Copy code as link] [▶ Run] ║ Run│Compiled code│Web│REPL│Help
│ ┌────────────────────────────┐ ║ ┌─────────────────────────────┐ │
│ │ Pyking, highlighted        │ ║ │ the tab showing:            │ │
│ │ errors underlined in place │ ║ │  Run output -- what Run     │ │
│ │                            │ ║ │   printed, the whole tab    │ │
│ │                            │ ║ │  Compiled code -- Target,   │ │
│ │                            │ ║ │   Compile, Run, Copy, the   │ │
│ │                            │ ║ │   code, and its output      │ │
│ │                            │ ║ │  Web output -- the page in  │ │
│ │                            │ ║ │   a frame, and the output   │ │
│ │                            │ ║ │  REPL -- a prompt, and the  │ │
│ │                            │ ║ │   environment below it      │ │
│ └────────────────────────────┘ ║ └─────────────────────────────┘ │
└────────────────────────────────╨─────────────────────────────────┘
                                 ↑ drag
```

The right-hand side is five tabs, and the page opens on **Run output**:

- **Run output** is what the left ▶ Run printed, over the whole tab.
- **Compiled code** holds the Target list, **Compile**, the right ▶ Run and
  Copy, with the generated code above and what compiling and running it
  said below.
- **Web output** shows the page a program using `tinyweb` draws, in a
  browser-window frame, above the same output Run output shows (see "The
  Web output tab").
- **REPL** is `pyk repl` in the page (see "The REPL").
- **Help** is the help `pyk pykhelp` serves -- getting started, the
  language reference and the libraries -- with a menu above the page
  (see "The Help tab").

### A link holding a program

A playground address may carry a program in its fragment,
`…/playground/#code=<text>`, the text being the program's UTF-8 bytes in
URL-safe base64 without padding (`assets/share.js`: `encodeSource`,
`decodeSource`, `sourceFromHash`, `linkTo`). The page then opens with that
program in the editor in place of the first example, and does not run it;
a link opened in the same tab later (only the fragment changing) replaces
the editor's program the same way. Being in the fragment, the program
never reaches the server. **Copy code as link**, beside Examples, copies such a
link to what is in the editor. The website's front page has one: its
"Try in playground" button, written when the site is built
(`tools/site/README.md`, "Writing a page"). An embedding page that does
not want its own address read passes `readLink: false`.

Run switches to Web output for a program that imports `tinyweb`, and to
Run output for any other -- unless Web output is showing, where it stays.
Compile, and `Ctrl`/`Cmd`+`Enter`, switch to Compiled code.

- **Compile**, on the Compiled code tab, compiles the source for the
  selected target into the code pane.
- **▶ Run** on the left runs the program with the **interpreter**, whatever
  target is selected — the "just run my program" button. The interpreter is
  the reference for what a program means (`docs/interpreter.md`), and it is
  compiled into the same bundle, so this needs no host at all.
- **▶ Run** on the Compiled code tab executes exactly what is displayed. Enabled for
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
- Compile errors are written to the Compiled code tab's output pane *and*
  underlined in the source editor at the exact span the compiler reported.
- **The panes resize.** Drag the bar between the two columns, or the one
  across a tab -- below the generated code, the page or the REPL -- to
  trade space between them; the three tabs share that one split. Each split is clamped to 12–85 % so a pane can be made small but
  never dragged out of existence — a zero-width editor is easy to reach and
  impossible to grab back.
- **The Settings button** (top right) opens an in-page dialog rather than a
  window:
  - **Appearance**: the same as the system (the default), light or dark.
    The ☀/☾ button in the header switches between the two as well; see
    "Light and dark".
  - **Font size**, 10–26 px, applied to both editors, the output panes and
    the REPL.
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
- **`Shift`+`Enter` and `Ctrl`+`Enter` run** (`Cmd`+`Enter` too, on a
  Mac) — the same as the **▶ Run** button of whichever
  pane has focus: in the source pane it runs the program with the
  interpreter, in the generated pane it runs what is displayed. With focus anywhere else it
  runs the source. While a program runs, the same keys stop it.
  Compiling has no key.

  The keys are registered as a Monaco *action* of each editor, not as a
  key listener on the container: Monaco handles keys on its own hidden
  textarea first, so a listener would only fire after Monaco had already
  typed the newline. Overriding them loses nothing, since plain `Enter`
  inserts a newline anyway.

### The editor and the language server

Both panes are [Monaco](https://microsoft.github.io/monaco-editor/), the
editor VS Code is built on, which highlights every target's output itself
(OCaml with its F# highlighting, Monaco having no OCaml). Pyking is a
Monarch tokenizer made when the page loads, from the compiler's own word
lists (`../webrun/assets/pyking-monaco.js`).

The source pane is a client of the Pyking language server (`src/lsp.ml`,
see `design/lsp.md`), which runs in the compiler's worker beside
everything else -- the same server `pyk lsp` is for an editor.
`assets/lsp-client.js` speaks LSP to it through the worker's `lsp`
request and gives the pane:

- **diagnostics** -- an error underlined where it is, about 200 ms after
  you stop typing, without pressing anything;
- **hover** -- the type of what is under the pointer;
- **go to definition** (F12, or Ctrl/Cmd+click) -- the cursor moves to
  where a name is bound, and Peek Definition (Alt+F12) shows one in the
  standard library;
- **the outline** (Ctrl/Cmd+Shift+O) -- the `def`s, bindings and imports;
- **completion** -- the names in scope, and after `m.` what module `m`
  exports.

The document is `file:///playground.pyk`, so the program is the module
`playground`, as Compile names it. Stopping a program replaces the
worker, and the server with it; the client opens the document again on
the next change. A bundle with no language server leaves the pane a
plain editor.

The compiler loads when the page does, because the editor's highlighting
reads the keyword list out of it (see "Four things read out of the
repository" below); the status pill reports progress.

### How long the first compile takes

Opening the page fetches the compiler. The status pill names the phase,
so you can tell working from frozen:

| Pill | What is happening | Typical |
|---|---|---|
| `starting… 1s` | booting the worker | instant |
| `loading compiler… 1s` | fetching and evaluating the 5 MB `pyking.js` | well under a second served locally |
| `ready in 0.6s` | done — it stays warm for the session | — |

After that, compiling is **about a millisecond**, and running is as fast as
the generated code.

The server marks `vendor/` cacheable for a day while everything else stays
`no-store`, since everything else is served straight from the source tree.

**The compiler cannot go stale under you either**, which needs more than
cache headers: the page fetches `build/pyking.js` once, at boot, so a tab
left open across a `make` would go on answering with the compiler it
started with. `manifest.json` carries a **stamp** of the bundle's bytes,
which the page re-reads before every compile: when it has moved on, the
worker reloads.

> **If it seems to hang at `starting…`**: a single-threaded server does
> that. Browsers open several connections at once and speculatively
> pre-connect ones they never use, and one idle pre-connect blocks the
> whole server. `pyk playground` waits on every connection at once
> (`src/web_server.ml`); `python3 -m http.server` has the flaw, so do not
> serve the page with it.

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

- **Output streams as it is produced.** The interpreter posts each line
  across as it produces it, through the `pyk_emit` primitive, rather than
  the run returning everything at the end. So a program that prints and
  *then* hangs still shows what it printed — which is exactly the case you
  want to see. A `debug` line comes through `pyk_debug` and is shown
  dimmed, and a line the program read from its input is echoed.
- **A program may import the standard library, and read its input.**
  Run asks the compiler first whether the program reads standard input
  or `sys.args()`, and where it does, a dialog asks for them before the
  program runs -- the last values offered again. A run while you type
  asks nothing and uses the last values given. `io` and `sys` are the
  worker's own, so standard output is this pane; see
  `../webrun/README.md`, "In the browser".
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
asked of the compiler (`pykFormatHelper`) when the page loads and handed to
the worker with each program rather than hand-copied, so the playground
cannot disagree with `node prog.js` about how a value prints.

### The Web output tab

A program using `tinyweb` draws on the Web output tab, which Run switches
to; its standard output is the output pane below the page -- the same
log Run output shows, moved to whichever of the two tabs is showing. The
page sits in a browser-window frame named after the example, and its
**↻ Refresh** stops the program and runs the source again. Such a
program goes on running after its last line, since the page calls back
the functions it handed over, so **Stop stays armed**: pressing it lets
the program go, and what the page shows stays. The page is mounted with
`PageHost` (`../webrun/README.md`, "A program may show a page"). The page
is light in both themes, so a canvas drawn in the default black reads as
it would on a page of its own.

The window has the keyboard while the page in it has the focus: its
frame is outlined then, and otherwise its three buttons are grey, as on
a Mac. A click anywhere in the window gives it the focus, a button on
the page included, and a click outside it, on the editor say, takes it
away. Running a tinyweb program with Run or its keys gives the window
the focus, and Stop gives it back to the editor; a run while you type
leaves it where it is.

A program that imports cannot be compiled in the page (it has no
program around it), so a tinyweb program is run with the interpreter,
the left Run button.

### The REPL

The REPL tab is a session of `pyk repl`: the session half of the REPL is
`src/repl_session.ml`, in the library, and the bundle registers it as
`pykReplStart`, `pykReplLine`, `pykReplImports` and `pykReplSubmit`
(`docs/repl.md`). An entry is checked against the entries before it and
run there, exactly as at a terminal prompt.

- The prompt is at the foot of the transcript. **Enter** submits a line
  the parser says is a whole entry, and otherwise opens the next line,
  indented one level after a `:`; a blank line ends a block. **Shift+Enter**
  always opens a line, **Tab** indents, **Backspace** in the indentation
  removes a level, **Escape** empties the prompt, and **Up** and **Down**
  go through the entries typed before.
- What an entry shows -- `value : Type`, a command's answer -- is in
  green, what it prints in the ordinary colour, and a refusal in red,
  in the words `pyk` uses. An entry refused for naming a function not
  written yet is put back in the prompt to finish.
- The commands are `:help`, `:ls`, `:type`, `:edit` (which puts a
  definition back in the prompt), `:ast`, `:tokens` and `:reset`. `:load`
  and `:quit` are the terminal's.
- **Copy from editor** puts the text marked in the editor into the prompt
  at its cursor, without the indentation its lines share; with nothing
  marked it says to mark something.
- An entry may import the standard library, read as Run reads it.
  `io.read_line` reads the end of input, and `sys.args()` is empty.
  `tinyweb` is refused: its page is Run's.
- **Stop** shows while an entry runs. It ends the REPL's worker, and the
  session with it, and a new session starts; **Reset** is `:reset`, and
  **Clear** empties the transcript and keeps the session.
- The **Environment** below is what `:ls` would list, as a table of
  name, value and type, read back after every entry.

The REPL runs on a `PykingRuntime` of its own, started the first time the
tab is opened, so stopping an entry ends nothing a Run started.

### The Help tab

The Help tab mounts the help (`../help/README.md`): a menu of pages, at
most 30% of the tab's height, the sections on the left and the page's
headings on the right, above the page
being read. The pages are the ones the website is built from, generated
into `build/help/` by `make`, and every example on them is a cell that
runs there, on a worker of the help's own, with a **Copy to editor**
button that puts it in the source editor. It is mounted the first time
the tab is opened, follows the playground's theme, and is found at
`helpURL` (the help's scripts, `/help/`) and `notebookURL` (the
notebook's, which run its cells), both options of `mountPlayground`.

### Light and dark

The playground has a light and a dark theme. Its colours are custom
properties on `.pyk-playground`, set for the dark theme and overridden
under `[data-theme="light"]`, and Monaco switches between `pyking-dark`
and `pyking-light` with them. The viewer chooses -- the header's ☀/☾
button, or Appearance in the settings, which starts from the system's
preference -- unless the embedding page passed `theme` (below).

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

```
tools/playground/
  Makefile
  playground.py      the example list and `check`; `pyk playground` serves
  e2e.mjs            browser tests (optional; see "Verifying" below)
  README.md
  assets/
    index.html       thin host page: mounts the component, nothing else
    playground.js    the UI (ES module, exports mountPlayground)
    lsp-client.js    the source pane as a language server client
    share.js         a program in a link (#code=...), read and written
    js-worker.js     generated JavaScript, on its own thread
    playground.css   all styles, scoped under .pyk-playground
```

What the page loads, and where the server finds it:

| URL | From |
|---|---|
| `/`, `/assets/…` | `assets/` |
| `/assets/playground.json` | worked out per request: the version, targets, editor modes, examples |
| `/webrun/…` | `../webrun/assets/`: the runtime, the compiler's worker, the Pyking language for Monaco |
| `/vendor/…` | `../webrun/vendor/`: Monaco (and Ace and KaTeX, the notebook's) |
| `/pyking/pyking.js` | `build/pyking.js`, built from `src/` by dune and js_of_ocaml |
| `/pyking/manifest.json` | worked out per request: the bundle's name and stamp |
| `/examples/*.pyk` | each example `src/examples.toml` lists, under the name `pyk example` saves it as |

### The bundle is evaluated, not required

`check` and `tests/test_playground.py` run the compiled compiler under
node — and they do that by *reading* `build/pyking.js` and evaluating it,
rather than `require`ing it.

That looks roundabout and is not. The bundle is a classic script, but
node decides a `.js` file's module system from the nearest
`package.json`: one saying `"type": "module"` anywhere above the
repository makes it an ES module, and `require` of an ES module works on
some node versions and fails with `ERR_REQUIRE_ESM` on others. Reading
the text sidesteps the module system, so the check behaves the same
wherever the repository sits and whichever node is installed. The one
thing evaluation needs supplying is `require` itself — a module-local in
CommonJS, which js_of_ocaml's runtime calls — so it is put on
`globalThis` first.

`check.cjs` does the same, and is named `.cjs` for the same reason.

### Four things read out of the repository

The playground cannot drift from the compiler, because it does not restate
anything the compiler already knows. Three of the four are *asked of the
bundle* when the page loads, through the worker's `words` request, rather
than parsed out of the source:

1. **The compiler** is `dune build src/web/pyking_web.bc.js`, served as
   `build/pyking.js` — never forked, and never edited here.
2. **The target list** comes from `pykTargets`, which is `pyk.ml`'s own
   `targets`, itself assembled from the backends. `make check` and
   `tests/test_playground.py` fail if a target turns up that has no entry in
   `playground.py`'s `TARGET_MODE`, rather than it silently going missing
   from the dropdown.
3. **The keyword and builtin lists** in `pyking-monaco.js` come from
   `pykKeywords` and `pykBuiltins` — `lexer.keywords` and
   `builtin.names` — and **the value formatter** in `js-worker.js` from
   `pykFormatHelper`, which is the JavaScript backend's own `pykFormat`.
   (`tools/emacs/` warns in its own commentary that a hand-copied keyword
   list goes stale silently; these cannot. The formatter was a hand-copy
   once, and it drifted the moment booleans stopped printing capitalised —
   hence the rule.)
4. **The examples** are `src/examples.toml`'s, the list `pyk example`
   reads, which a package ships. Each is a test case, so `make test`
   keeps it working. Compile refuses a program that imports, since it
   compiles one file; Run runs it with the standard library.

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
    base: "./assets",             // playground.json, js-worker.js
    webrunURL: "./webrun/",       // tools/webrun/assets
    vendorURL: "./vendor/",       // tools/webrun/vendor
    pykingURL: "./pyking/",       // pyking.js and manifest.json
    examplesURL: "./examples/",   // where the .pyk files live
    initialTarget: "c23",
    initialExample: "use_args.pyk", // the first example by default
    readLink: true,               // open a #code=... link's program (the default)
    theme: "light",               // omit to let the viewer choose
  });
</script>
```

Monaco and the Pyking language are loaded for you if they are not already
present. With `theme` given, the page owns the theme: the header's switch
and the setting are hidden, and the page calls `setTheme("light")` or
`setTheme("dark")` on what `mountPlayground` answers when its own changes,
as the website's playground does with Starlight's.
`playground.js` imports `../webrun/web.js`, so `assets/` and `webrun/` sit
side by side, as the server lays them out; everything else is an option. Styles are scoped under `.pyk-playground` and use CSS custom
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
import { PykingRuntime } from "./webrun/pyking-runtime.js";

const rt = new PykingRuntime({
  pykingURL: "./pyking/",
  workerURL: "./webrun/pyking-worker.js",
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

// The language server: one JSON-RPC message in, what it sends back out --
// null where the bundle has none. `lspIdle` is what it sends once typing
// has paused: the diagnostics.
await rt.lsp({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} });
// [ { jsonrpc: "2.0", id: 1, result: { capabilities: { … } } } ]
await rt.lspIdle();
rt.generation; // changes when a stop or a reload replaced the worker
```

`compile` and `runProgram` are asynchronous because they cross a thread
boundary — everything happens on a worker (see above). Relative URLs are
resolved against the page before being handed over, so `"./assets/…"` means
what you expect: inside a worker a relative URL would otherwise resolve
against the *worker's* location, which is how `./pyking/` once became
`/assets/pyking/`. Generated JavaScript has its own runner with the same
shape:

```js
import { JsRunner } from "./webrun/pyking-runtime.js";

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
exactly as `lexer.info` records them (Monaco counts both from 1, hence the
`col1 + 1` in `playground.js`).

## Verifying without a browser

Most of this is testable headlessly, and worth re-running after changing the
compiler:

```sh
make check                       # every example, through the shim
make e2e                         # the same page, in a real browser
```

The repository's own `make test` asks the first of those questions too,
as `tests/test_playground.py`: it drives `build/pyking.js` directly, so
it needs no vendored assets, and it reads the example list out of
`playground.py`'s `example_sources` so the two cannot disagree about
what the page offers. `tests/test_notebook.py` also starts
`pyk playground` and fetches the page's manifest and an example, and
checks that the manifest and every file `playground.py`'s `site()`
names are what `pyk playground` serves: `src/web_tools.ml` builds the
manifest the page loads, and `playground.py` the one `make check` and
the website use.

`make check` needs Python and `node`. What the examples print is
`tests/test_script.py`'s business; this only proves each checks through
the page's own entry point. `make e2e` needs Playwright — the one
dependency anywhere in this tool, which is why it is a separate target and
why the script prints an install line and exits cleanly when it is absent:

```sh
npm install playwright && npx playwright install chromium
```

It is worth having, because there is a class of defect nothing headless can
see: Monaco, the worker plumbing and the page's own wiring only exist in a
browser. `make e2e` starts `pyk playground` on a free port and drives
the page: that it mounts with every target in the dropdown and both
editors are Monaco, that Compile loads
the compiler and produces a file, that the `pyking` target prints the front
end's own output, that both Run buttons produce output, that Shift+Enter
and Ctrl+Enter run, that **every example
compiles for every target it claims** — the same pairs `make check` compiles,
but through the page's worker rather than under `node` — and that Stop ends a
program written never to end (`loop: continue`) with the page still
answering. Any error on the console fails the run.

The language server's side of the page is `tests/lsp/playground.mjs`'s,
which `tests/test_lsp.py` runs in a Chromium over the DevTools protocol:
an error underlined at its line, a hover showing a type, completion
offering a name, go to definition, the outline -- and that compiling and
running still work beside them.

## Limitations

- **Needs a static server** (above). No way around it for ES modules and
  workers.
- **About 11 MB on first load** — 5.1 MB of it the compiler, about 5 MB
  Monaco.
- **A non-terminating program no longer freezes the tab.** Execution happens
  on workers, so the page stays responsive and the Stop button ends it (see
  "How programs are executed" above). This is what makes "run while you type"
  safe to leave on: a loop that never ends can be stopped, and the edit that
  fixes it can still be typed.
- **C and Java output is display-only.** Copy it out and build it locally —
  the header comment in each generated file gives the exact command.
- **Compile takes one file.** A program that imports runs, since Run
  reads the standard library from `lib/`, but Compile refuses its import:
  it compiles the file on its own.

## What the page does not offer

`iweb24` is missing from the target list on purpose. That target packages
a program *with* the interpreter so a browser can run it — which is what
this page already is. It has nothing to add here, and could not build its
own page anyway without a copy of `pyking.js` to ship.
