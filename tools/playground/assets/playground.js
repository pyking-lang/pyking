// The playground user interface: the source editor with its example
// selector, and six tabs on the right -- the run's output, the compiled
// code with its target selector, the page a run draws, a REPL, the
// debugger (debugger.js) and the help. Served by
// tools/playground/playground.py.
//
// Embedding this in another page is one call:
//
//   import { mountPlayground } from "./assets/playground.js";
//   mountPlayground(document.getElementById("host"), { base: "./assets" });
//
// Everything it needs (Monaco, the Pyking language, the compiler, the examples)
// is fetched relative to the options below, so the whole build/
// directory can be moved or served from a sub-path unchanged.

import {
  JsRunner, LANGUAGE, PageHost, createRuntime, ensureMonaco, fetchJSON,
  splitArguments, themeFor,
} from "../webrun/web.js";
import { LspClient } from "./lsp-client.js";
import { ACTIONS, DEFAULT_KEYS, Debugger, keyList, showKey, showKeys, specOf } from "./debugger.js";
import { linkTo, sourceFromHash } from "./share.js";
import { packFiles, zip } from "./download.js";

const STORAGE_KEY = "pyking-playground.settings";

/** What the settings dialog starts from, before anything saved is layered
 *  over it. The two output switches default on: a pane you cannot scroll
 *  loses what it cannot show, and output that accumulates across runs is
 *  hard to read the newest of. `autoRun` defaults off -- running on every
 *  edit is a preference, and it is the one setting that can start the
 *  multi-megabyte runtime download without an explicit button press. */
const DEFAULT_SETTINGS = {
  theme: "system",
  fontSize: 13,
  scrollOutput: true,
  clearOnRun: true,
  autoRun: false,
  tinywebLog: false,
  // The debugger: whether it stops at the first statement, whether it
  // steps over the standard library's code, and each action's key where
  // the viewer changed it (debugger.js, DEFAULT_KEYS).
  debugStopOnEntry: false,
  debugJustMyCode: true,
  debugKeys: {},
};

/** How long the source has to sit still before an automatic run. Long
 *  enough to finish a word -- half-written code is mostly code that does
 *  not compile, and re-running it per keystroke would say so per keystroke. */
const AUTO_RUN_DELAY = 600;

/** What the page's frame shows before a program has drawn anything. */
const PAGE_PLACEHOLDER =
  '<p class="pyk-page-empty">A program using tinyweb draws here when you press Run.</p>';

/** What the editor starts with when there are no examples to load. */
const FALLBACK_SOURCE = `def greet(name: String) -> String:
    return "Hello, " ++ name

print(greet("world"))
`;

/** The source's document, as the language server knows it: the program's
 *  module is named after the file, `playground`, as Compile names it. */
const SOURCE_URI = "file:///playground.pyk";

/** The owner of the marker a refused Compile or Run puts under the
 *  source; the language server's diagnostics have an owner of their own. */
const COMPILE_MARKERS = "pyking-compile";

/** The Monaco language each Ace mode in the manifest stands for. Monaco
 *  has no OCaml, and F#, an ML of the same family, highlights it. */
const MONACO_LANGUAGES = {
  text: "plaintext",
  python: "python",
  javascript: "javascript",
  html: "html",
  c_cpp: "c",
  java: "java",
  ocaml: "fsharp",
};

const DEFAULTS = {
  base: "./assets",
  pykingURL: "./pyking/",
  examplesURL: "./examples/",
  webrunURL: "./webrun/",
  vendorURL: "./vendor/",
  notebookURL: "./notebook/",
  helpURL: "./help/",
  // "light" or "dark" where the embedding page decides the theme -- it then
  // calls `setTheme` as its own changes -- and null where the viewer does,
  // with the header's switch and the settings.
  theme: null,
  initialTarget: "node22",
  initialExample: null,               // the first example
  // Whether the page's own URL may hold a program, `#code=...`
  // (share.js), which then opens in the editor in place of an example.
  readLink: true,
};

export async function mountPlayground(host, options = {}) {
  const cfg = { ...DEFAULTS, ...options };
  const meta = await fetchJSON(cfg.base + "/playground.json");
  const runtime = createRuntime({ webrun: cfg.webrunURL, pyking: cfg.pykingURL });
  // The editor's highlighting reads the keywords out of the compiler, so
  // the compiler is loaded before the editors are made.
  const { words, monaco } = await ensureMonaco(runtime, { vendor: cfg.vendorURL });
  meta.formatHelper = words.formatHelper;
  quietLanguageWorkers(monaco);

  const ui = buildDom(host, meta, cfg);

  const app = new Playground(ui, meta, cfg, runtime, monaco);
  await app.init();
  return app;
}

// --------------------------------------------------------------- the app

class Playground {
  constructor(ui, meta, cfg, runtime, monaco) {
    this.ui = ui;
    this.meta = meta;
    this.cfg = cfg;
    this.runtime = runtime;
    this.monaco = monaco;
    this.files = {};          // last successful compile: {name: text}
    this.views = new Set();   // which of those are front-end views, not code
    this.current = null;      // which of those is shown on the right
    this.lsp = null;          // the language server client, once started
    this.lspStarted = null;   // its start: resolves to whether it runs
    this.autoRunTimer = null;  // pending "run while you type"
    this.autoRunning = false;
    this.programmaticEdit = false;
    this.jsRunner = new JsRunner(cfg.base + "/js-worker.js");
    this.running = null;       // {origin, kind} while something executes
    this.stopped = false;      // last run ended by the user, not by itself
    this.settings = { ...DEFAULT_SETTINGS, ...loadSettings() };
    // What the last run was given to read and as its arguments, offered
    // again the next time a program asks for them.
    this.input = { stdin: "", args: "" };
    this.tab = "run";            // which right-hand tab is showing
    this.switchTab = true;       // whether the latest run may change it
    // The REPL: a runtime of its own, started when the tab is first
    // opened, so stopping an entry ends the session and nothing else.
    this.replRuntime = null;
    this.replStarting = null;
    this.replBusy = false;
    this.replHistory = [];
    this.replAt = 0;            // where Up and Down are in the history
    this.replDraft = "";        // what was being typed before Up
    this.help = null;           // the Help tab's help, once it is opened
    this.helpStarting = null;
    this.debugger = null;       // the Debug tab (debugger.js)
  }

  async init() {
    const { ui } = this;

    const { monaco } = this;
    // `automaticLayout` has Monaco watch its container, so a pane that
    // changes size -- by a drag, by the window resizing, by the host page
    // reflowing -- is laid out again without being told.
    const options = {
      theme: themeFor(this.effectiveTheme()), fontSize: 13,
      tabSize: 4, insertSpaces: true, detectIndentation: false,
      automaticLayout: true, minimap: { enabled: false },
      fixedOverflowWidgets: true,
      // What the language server says of names (semantic tokens) shows
      // in the text.
      "semanticHighlighting.enabled": true,
      // A plain textarea for input: a key the debugger takes is then kept
      // out of the text on every platform.
      editContext: false,
    };
    const model = (text, language, uri) => {
      const made = monaco.editor.createModel(text, language, uri);
      made.updateOptions({ tabSize: 4, insertSpaces: true });
      return made;
    };
    this.left = monaco.editor.create(ui.leftEditor, {
      ...options, model: model("", LANGUAGE, monaco.Uri.parse(SOURCE_URI)),
    });
    this.right = monaco.editor.create(ui.rightEditor, {
      ...options, model: model("", "plaintext"),
    });
    this.left.onDidChangeModelContent(() => {
      this.clearError();
      // Only what the *user* typed schedules a run. Monaco fires the same
      // event for `setValue`, so loading an example -- which happens once
      // during startup -- would otherwise trigger a run, and with it the
      // runtime download, before anyone had touched the page.
      if (!this.programmaticEdit) this.scheduleAutoRun();
    });
    this.watchDeadKeys();

    ui.target.addEventListener("change", () => this.onTargetChange());
    ui.example.addEventListener("change", () => this.loadExample(ui.example.value));
    ui.compile.addEventListener("click", () => this.compile());
    // Pressing Run takes the focus from the editor before the click is
    // seen, so whether the editor had it is noted on the way down.
    ui.runLeft.addEventListener("mousedown", () => {
      this.focusAtRun = this.left.hasTextFocus() ? this.left.getSelection() : false;
    });
    ui.runLeft.addEventListener("click", () => this.runFromSource());
    ui.runRight.addEventListener("click", () => this.runGenerated());
    ui.stopLeft.addEventListener("click", () => this.stopRun());
    ui.stopRight.addEventListener("click", () => this.stopRun());
    ui.copy.addEventListener("click", () => this.copyRight());
    ui.download.addEventListener("click", () => this.download());
    ui.copyLink.addEventListener("click", () => this.copyLink());
    ui.refresh.addEventListener("click", () => this.refreshPage());
    // A press anywhere is the reader choosing where the focus goes: the
    // editor no longer keeps the focus a run gave it back.
    document.addEventListener("pointerdown", () => { this.keepEditorFocus = null; }, true);
    // A click on the window's bar gives the page in it the keyboard.
    ui.frameBar.addEventListener("click", (event) => {
      if (this.pageHost && !event.target.closest("button")) ui.page.focus({ preventScroll: true });
    });
    ui.clear.addEventListener("click", () => this.clearOutput());
    ui.clearCompiled.addEventListener("click", () => this.clearOutput(ui.compiledOutput));
    for (const tab of ui.tabs) {
      tab.addEventListener("click", () => this.showTab(tab.dataset.tab));
    }
    this.installRepl();
    this.debugger = new Debugger(this);
    this.debugger.install(ui.panelDebug);
    this.installTheme();

    this.installSplitters();
    this.installSettings();
    this.applySettings();

    // Keyboard shortcuts.
    //
    // Registered as Monaco actions rather than as one bubbling keydown
    // listener, because Monaco handles keys on its own hidden textarea
    // first: a listener on the container would not run until Monaco had
    // already inserted the newline that Shift+Enter would otherwise type.
    // An action's keys belong to its own editor, where a command's would
    // be shared by every editor on the page.
    //
    // Shift+Enter and Ctrl+Enter (Cmd+Enter too, on a Mac) run, and mean
    // the Run button of whichever pane has focus -- the source pane runs
    // the program itself, the generated pane runs what is displayed.
    // Overriding them costs nothing, since plain Enter already inserts a
    // newline. Compiling has no key. While a program runs, they stop it.
    const { KeyMod, KeyCode } = monaco;
    const RUN = [KeyMod.Shift | KeyCode.Enter, KeyMod.CtrlCmd | KeyCode.Enter,
                 KeyMod.WinCtrl | KeyCode.Enter];
    const bind = (editor, id, label, run) =>
      editor.addAction({ id, label, keybindings: RUN, run: () => { run(); } });

    bind(this.left, "pyk-run", "Run the program",
         () => (this.running ? this.stopRun() : this.runFromSource()));
    bind(this.right, "pyk-run", "Run the generated code",
         () => (this.running ? this.stopRun() : this.runGenerated()));

    // The debugger's keys, caught on the way down, before an editor sees
    // them: Start's, Continue's and the steps' anywhere in the
    // playground, or on the page itself where nothing has the focus; the
    // rest where the focus is in the editor or the Debug tab.
    const debugKey = (event) => {
      if (!ui.modal.classList.contains("pyk-hidden")) return;
      if (!ui.inputModal.classList.contains("pyk-hidden")) return;
      const near = ui.leftEditor.contains(event.target) || ui.panels.debug?.contains(event.target);
      this.debugger?.handleKey(event, near ? null : ["start", "continue", "next", "in", "out"]);
    };
    ui.root.addEventListener("keydown", debugKey, true);
    document.addEventListener("keydown", (event) => {
      if (event.target === document.body || event.target === document.documentElement) debugKey(event);
    });

    // The same keys when focus is outside both editors -- on a dropdown, a
    // button, or the page itself. Monaco stops propagation for keys it
    // handled, but the check for an enclosing editor is explicit so that a
    // future Monaco that stops doing so cannot make this fire twice.
    ui.root.addEventListener("keydown", (event) => {
      if (event.target === ui.replInput) return;
      if (event.key === "Escape" && !ui.modal.classList.contains("pyk-hidden")) {
        this.closeSettings();
        return;
      }
      if (event.key !== "Enter") return;
      if (!ui.modal.classList.contains("pyk-hidden")) return;
      if (!ui.inputModal.classList.contains("pyk-hidden")) return;
      if (event.target?.closest?.(".monaco-editor")) return;
      const accel = event.ctrlKey || event.metaKey;
      if (!accel && !event.shiftKey) return;
      event.preventDefault();
      if (this.running) this.stopRun();
      else this.runFromSource();
    });

    // No src/examples.toml beside the tools: nothing to offer.
    if (!this.meta.examples.length) ui.example.classList.add("pyk-hidden");
    const linked = this.cfg.readLink ? sourceFromHash(location.hash) : null;
    if (linked !== null) {
      this.openLinked(linked);
    } else if (this.meta.examples.length) {
      await this.loadExample(this.cfg.initialExample ?? this.meta.examples[0].file,
                             { silent: true });
    } else {
      this.setSource(FALLBACK_SOURCE);
    }
    if (this.cfg.readLink) {
      // A link to another program, opened in this tab, changes only the
      // fragment, and the page is not loaded again.
      window.addEventListener("hashchange", () => {
        const text = sourceFromHash(location.hash);
        if (text !== null) this.openLinked(text);
      });
    }
    this.onTargetChange();
    // Hover, definition, outline, completion and diagnostics, from the
    // language server in the compiler's worker -- where the bundle has one.
    this.lsp = new LspClient(monaco, this.runtime, this.left, {
      uri: SOURCE_URI,
      libURL: this.runtime.libURL,
      onOpenElsewhere: (file, where) => {
        const line = where?.startLineNumber ?? where?.lineNumber;
        this.note(`Defined in ${file}${line ? `, line ${line}` : ""}`
                  + " (Alt+F12 shows it here)");
      },
    });
    this.lspStarted = this.lsp.start().catch(() => false);
    // The compiler was loaded before the editors were made (mountPlayground).
    this.status("ready", "ready");
    this.note("Press Run to run the program. Compiled code compiles it for a "
              + "target, and the REPL runs Pyking an entry at a time.");
  }

  // -- examples ---------------------------------------------------------

  /** Puts the program a link held in the editor; it is not run. */
  openLinked(text) {
    this.setSource(text);
    this.debugger?.clearBreakpoints();
    this.ui.example.value = "";
    this.clearError();
    this.note("Opened the program in the link.");
  }

  /** Copy code as link: copies a link that opens the playground with the
   *  editor's program. */
  async copyLink() {
    try {
      await navigator.clipboard.writeText(linkTo(location.href, this.left.getValue()));
      this.note("Copied a link to this program: whoever opens it gets it in the editor.");
    } catch {
      this.error("The browser refused clipboard access.");
    }
  }

  async loadExample(file, { silent = false } = {}) {
    const entry = this.meta.examples.find((e) => e.file === file);
    if (!entry) return;
    const response = await fetch(this.cfg.examplesURL + file);
    this.setSource(await response.text());
    this.debugger?.clearBreakpoints();
    this.ui.example.value = file;
    this.clearError();
    if (!silent) this.note(`Loaded ${file} — ${entry.description}`);
  }

  // -- compiling --------------------------------------------------------

  async ensureRuntime() {
    if (this.runtime.isReady) return true;

    // The first boot is seconds long and has no progress events to hang a
    // bar off, so show the phase with a running seconds count. A number that
    // keeps moving is the difference between "working" and "frozen".
    const started = Date.now();
    let phase = "starting";
    const tick = setInterval(() => {
      const secs = Math.round((Date.now() - started) / 1000);
      this.status("busy", `${phase}… ${secs}s`);
    }, 500);
    this.status("busy", "starting…");
    this.note("Loading the compiler — once per session.");

    try {
      await this.runtime.ready((msg) => { phase = msg; this.status("busy", msg + "…"); });
      this.status("ready", `ready in ${((Date.now() - started) / 1000).toFixed(1)}s`);
      return true;
    } catch (err) {
      // Stopping during the boot rejects it on purpose; that is the user
      // getting what they asked for, not a failure to report.
      if (this.stopped) return false;
      this.status("error", "failed");
      this.error("Could not start the compiler: " + err.message);
      return false;
    } finally {
      clearInterval(tick);
    }
  }

  async compile() {
    this.showTab("compiled");
    if (!(await this.ensureRuntime())) return;
    const target = this.ui.target.value;
    const source = this.left.getValue();
    const result = await this.runtime.compile(source, target, "playground.pyk");
    this.clearError();
    const log = this.ui.compiledOutput;

    if (!result.ok) {
      this.showFiles({});
      this.error(result.text, log);
      if (result.info) this.markError(result.info, result.text);
      return;
    }
    this.compiled = { source, target };
    this.showFiles(result.files, result.views);
    const names = Object.keys(result.files);
    // The `pyking` target compiles nothing *to* anything: the front end
    // ran and printed the program back, so saying "compiled to pyking"
    // would name a backend that does not exist.
    const what = target === "pyking"
      ? "Printed by the front end" : `Compiled to ${target}`;
    this.good(`${what} — ${names.length === 1
      ? names[0] : names.length + " files: " + names.join(", ")}`, log);
    return result;
  }

  showFiles(files, views = []) {
    this.files = files;
    // Which of them are front-end views (a token dump, an AST) rather than
    // code: they share the pane with generated files, but running one would
    // be running the compiler's notes.
    this.views = new Set(views);
    const names = Object.keys(files);
    this.ui.files.innerHTML = "";
    if (names.length > 1) {
      for (const name of names) {
        const tab = document.createElement("button");
        tab.className = "pyk-file";
        tab.textContent = name;
        tab.addEventListener("click", () => this.showFile(name));
        this.ui.files.appendChild(tab);
      }
    }
    this.showFile(names[0] ?? null);
    this.updateRunButtons();
  }

  showFile(name) {
    this.current = name;
    this.right.setValue(name ? this.files[name] : "");
    for (const tab of this.ui.files.children) {
      tab.classList.toggle("active", tab.textContent === name);
    }
    // The Run button beside this pane runs *what is shown*, so switching
    // tabs can change whether there is anything runnable there.
    this.updateRunButtons();
  }

  onTargetChange() {
    const target = this.ui.target.value;
    this.monaco.editor.setModelLanguage(
      this.right.getModel(), languageFor(target, this.meta.modes[target]));
    // The generated code no longer matches the selected target, so drop it
    // rather than leave something stale-but-plausible on screen.
    this.showFiles({});
    this.updateRunButtons();
  }

  updateRunButtons() {
    const target = this.ui.target.value;
    const how = this.meta.run[target];
    const haveCode = Object.keys(this.files).length > 0;
    const viewing = this.views?.has(this.current);
    this.ui.runRight.disabled = !how || !haveCode || viewing;
    this.ui.download.disabled = !haveCode;
    this.ui.runRight.title = viewing
      ? `${this.current} is a view of the front end, not code to run`
      : !how ? whyNotRunnable(target)
      : !haveCode ? "Compile first, then run"
      : `Run the generated ${target} code (Shift+Enter or Ctrl+Enter)`;
  }

  // -- running ----------------------------------------------------------
  //
  // Every execution goes through beginRun/endRun, which own the Stop button
  // and the record of what is currently running. Three backends sit behind
  // that one lifecycle:
  //
  //   pyking   the compiler's worker     stop = terminate the worker
  //   js       the JavaScript worker     stop = terminate the worker
  //
  // Both run on workers precisely so that a program which never returns
  // can still be stopped -- a same-process iframe shares the main thread
  // and would take the page down with it. Nothing renders into a frame
  // any more: a compiled Pyking program prints, and `web` prints to the
  // console like `node` does.

  /** The Run button next to the source: run the program itself, with the
   *  interpreter, whatever target happens to be selected.
   *
   *  The interpreter is the reference for what a program *means*
   *  (docs/interpreter.md), and it runs every program the checker accepts
   *  -- so this button works for a program no target in the dropdown can
   *  compile, which is exactly what "just run my program" should mean.
   *  A run asked for (`asked`, not "run while you type") asks for the
   *  program's input and gives a page the keyboard. */
  async runFromSource({ switchTab = true, asked = true } = {}) {
    // Where the editor's cursor was, if it had the focus when Run was
    // pressed: by a key in it, or by the button (`focusAtRun`).
    const back = this.focusAtRun !== undefined ? this.focusAtRun
      : this.left.hasTextFocus() ? this.left.getSelection() : false;
    this.focusAtRun = undefined;
    const refocus = () => {
      if (!back) return;
      this.left.setSelection(back);
      this.left.focus();
    };
    this.keepEditorFocus = null;
    // Before starting the runtime, so the one-off "loading the compiler"
    // note survives rather than being wiped by the clear that follows it.
    this.beforeRun();
    // Armed here rather than around the execution alone, so it covers the
    // whole of what pressing Run costs: loading the compiler, checking the
    // program, then running it. Leaving any of that unstoppable is the one
    // case where the button is most obviously wanted.
    this.beginRun("left", "pyking");
    try {
      if (!(await this.ensureRuntime())) return;
      this.clearError();
      const source = this.left.getValue();
      const analysis = await this.analyze(source);
      // A program with a page is shown on the page's tab, and any other on
      // the output's -- unless the page's tab is showing already, where
      // Refresh and a program without a page leave it.
      const paged = analysis?.ok && analysis.externals.includes("tinyweb");
      this.switchTab = switchTab;
      if (switchTab && paged) this.showTab("web");
      else if (switchTab && this.tab !== "web") this.showTab("run");
      const input = await this.askForInput(analysis, asked);
      if (input === null) return;
      // The editor gets its focus back where it had it, and keeps it while
      // a page starts up and takes it -- until the reader presses the
      // page. Otherwise a page takes the keys, which its program may read.
      if (back) {
        refocus();
        if (paged) this.holdEditorFocus(back);
      } else if (asked && paged) {
        this.ui.page.focus({ preventScroll: true });
      }
      await this.executeProgram(source, input);
    } finally {
      // A program that sent its page something goes on running there --
      // the page calls back what it was given -- so Stop stays armed.
      if (!(this.runtime.isLive && this.running)) this.endRun();
      // Again once it has ended, unless the focus went somewhere since.
      const focused = document.activeElement;
      const paged = this.pageHost && this.ui.page.contains(focused);
      if (!paged && (!focused || focused === document.body
                     || focused === this.ui.runLeft || focused === this.ui.stopLeft)) {
        refocus();
      }
    }
  }

  /** Keeps the focus in the editor, at `selection`, for a short while
   *  after a page's program starts: focus the page takes, or loses to
   *  nothing, as it starts up is given back, until the reader presses
   *  anywhere. Selection -> () */
  holdEditorFocus(selection) {
    const hold = { until: Date.now() + 2000 };
    this.keepEditorFocus = hold;
    const check = () => {
      if (this.keepEditorFocus !== hold) return;
      if (Date.now() > hold.until) {
        this.keepEditorFocus = null;
        return;
      }
      const focused = document.activeElement;
      const taken = !this.left.hasTextFocus()
        && (!focused || focused === document.body || this.ui.page.contains(focused));
      if (taken) {
        this.left.setSelection(selection);
        this.left.focus();
      }
      setTimeout(check, 50);
    };
    setTimeout(check, 50);
  }

  /** Shows one of the right-hand tabs: "run", "compiled", "web" or
   *  "repl". The run's output is one log, shown by the Run output tab and
   *  below the page on the Web output tab, so it moves to whichever of
   *  the two is showing. String -> () */
  showTab(name) {
    const { ui } = this;
    if (!ui.panels[name]) return;
    this.tab = name;
    for (const tab of ui.tabs) {
      const on = tab.dataset.tab === name;
      tab.classList.toggle("active", on);
      tab.setAttribute("aria-selected", String(on));
    }
    for (const [key, panel] of Object.entries(ui.panels)) {
      panel.classList.toggle("pyk-hidden", key !== name);
    }
    if (name === "run") ui.panelRun.appendChild(ui.outputWrap);
    if (name === "web") ui.panelWeb.appendChild(ui.outputWrap);
    ui.tinywebLogBox.classList.toggle("pyk-hidden", name !== "web");
    if (name === "compiled") this.right.layout();
    if (name === "repl") this.openRepl();
    if (name === "help") this.openHelp();
  }

  /** Mounts the help in the Help tab, the first time it is opened: the
   *  pages tools/help/help.py generated, each example a cell that runs
   *  there, with a button putting it in the editor. () -> Promise<()> */
  openHelp() {
    this.helpStarting ??= (async () => {
      const at = (url) => new URL(url, document.baseURI).href;
      const { mountHelp } = await import(at(this.cfg.helpURL) + "help.js");
      this.help = await mountHelp(this.ui.helpHost, {
        pagesURL: at(this.cfg.helpURL) + "pages/",
        notebookURL: at(this.cfg.notebookURL),
        webrunURL: at(this.cfg.webrunURL),
        vendorURL: at(this.cfg.vendorURL),
        pykingURL: at(this.cfg.pykingURL),
        theme: this.effectiveTheme(),
        onCopy: (code) => {
          this.setSource(code);
          this.debugger?.clearBreakpoints();
          this.note("Copied an example from the help into the editor.");
        },
      });
    })().catch((err) => {
      this.helpStarting = null;
      this.ui.helpHost.textContent = "Could not load the help: " + err.message;
    });
    return this.helpStarting;
  }

  /** Removes the last run's page, if it had one, leaving the line that
   *  says what the frame is for. () -> () */
  closePage() {
    this.pageHost?.close();
    this.pageHost = null;
    this.ui.page.innerHTML = PAGE_PLACEHOLDER;
  }

  /** The Refresh button on the page's frame: stop whatever runs, and run
   *  the source in the editor again. () -> () */
  async refreshPage() {
    if (this.running) this.stopRun({ quiet: true });
    await this.runFromSource();
  }

  /** Shows what the running program sent its page, on the Web output tab.
   *  String -> [Object] -> () */
  pageReceive(module, data) {
    if (!this.pageHost) {
      this.ui.page.textContent = "";
      this.pageHost = new PageHost(this.ui.page, {
        libURL: this.runtime.libURL,
        send: (name, event) => this.runtime.sendEvent(name, event),
      });
      if (this.switchTab) this.showTab("web");
    }
    this.pageHost.receive(module, data);
  }

  /** The Run button in the generated pane: execute exactly what is shown. */
  async runGenerated() {
    const target = this.ui.target.value;
    const how = this.meta.run[target];
    if (!how) return;          // nothing runs, so nothing is cleared either
    this.beforeRun(this.ui.compiledOutput);
    const code = this.right.getValue();
    this.beginRun("right", "js");
    try {
      await this.executeJs(how, code, target);
    } finally {
      this.endRun();
    }
  }

  /** What the program needs before it runs (`PykingRuntime.analyze`), or
   *  null where asking failed. String -> Promise<Object?> */
  async analyze(source) {
    try {
      return await this.runtime.analyze(source);
    } catch {
      return null;
    }
  }

  /** What the program reads and is passed, asked of the user before it
   *  runs -- and only where the program uses one: a program that never
   *  reads standard input is not interrupted by a box asking for it.
   *  Resolves to {stdin, args}, or to null if the dialog was cancelled.
   *  A program that does not check is not asked about: running it reports
   *  the refusal. Without `ask` the last input given is used, unasked.
   *  Object? -> Bool -> Promise<{stdin, args}?> */
  async askForInput(analysis, ask = true) {
    if (!analysis?.ok || !(analysis.stdin || analysis.args)) {
      return { stdin: "", args: [] };
    }
    if (!ask) {
      return {
        stdin: analysis.stdin ? this.input.stdin : "",
        args: analysis.args ? splitArguments(this.input.args) : [],
      };
    }
    const { ui } = this;
    ui.inputStdinField.classList.toggle("pyk-hidden", !analysis.stdin);
    ui.inputArgsField.classList.toggle("pyk-hidden", !analysis.args);
    ui.inputStdin.value = this.input.stdin;
    ui.inputArgs.value = this.input.args;
    ui.inputModal.classList.remove("pyk-hidden");
    (analysis.stdin ? ui.inputStdin : ui.inputArgs).focus();
    const chosen = await new Promise((resolve) => {
      const done = (value) => {
        ui.inputRun.removeEventListener("click", onRun);
        ui.inputCancel.removeEventListener("click", onCancel);
        ui.inputModal.removeEventListener("keydown", onKey);
        ui.inputModal.classList.add("pyk-hidden");
        resolve(value);
      };
      const onRun = () => done(true);
      const onCancel = () => done(false);
      const onKey = (event) => {
        if (event.key === "Escape") done(false);
        else if (event.key === "Enter" && (event.ctrlKey || event.metaKey
                 || event.target === ui.inputArgs)) {
          event.preventDefault();
          done(true);
        }
      };
      ui.inputRun.addEventListener("click", onRun);
      ui.inputCancel.addEventListener("click", onCancel);
      ui.inputModal.addEventListener("keydown", onKey);
    });
    this.left.focus();
    if (!chosen) {
      this.note("— not run —");
      return null;
    }
    this.input = { stdin: ui.inputStdin.value, args: ui.inputArgs.value };
    return {
      stdin: analysis.stdin ? this.input.stdin : "",
      args: analysis.args ? splitArguments(this.input.args) : [],
    };
  }

  async executeProgram(source, input = { stdin: "", args: [] }) {
    try {
      this.closePage();
      this.ui.pageTitle.textContent = this.ui.example.value || "playground.pyk";
      const run = this.running;
      const result = await this.runtime.runProgram(source, {
        onOutput: (text) => this.write(text),
        onDebug: (text) => this.debugLine(text),
        onInput: (text) => this.write(text, "input"),
        onPage: (module, data) => this.pageReceive(module, data),
        onFailure: (text) => this.error(text.trimEnd()),
        onExit: (code) => {
          this.error(`— exited with status ${code} —`);
          this.runtime.endLive();
        },
        onEnd: () => {
          this.pageHost?.freeze();
          if (this.running === run) this.endRun();
        },
        stdin: input.stdin,
        args: input.args,
        tinywebLog: this.settings.tinywebLog,
      });
      if (result.ok && result.exit) {
        this.error(`— exited with status ${result.exit} —`);
      } else if (result.ok) {
        this.good("— finished —");
      } else {
        // A refusal and a runtime error arrive in the same shape; only a
        // refusal carries a span, and that is what underlines in place.
        this.error(result.text.trimEnd());
        if (result.info) this.markError(result.info, result.text.trimEnd());
      }
    } catch (err) {
      // `stop()` rejects everything in flight; that is not an error to report.
      if (!this.stopped) this.error("the compiler failed: " + err.message);
    }
  }

  async executeJs(how, code, target) {
    try {
      // The whole compiled program goes across, not just the pane: a
      // generated module imports the shared runtime and the modules it
      // uses, and a blob URL has no base to resolve those against.
      const log = this.ui.compiledOutput;
      await this.jsRunner.run(code, {
        files: this.files,
        formatHelper: this.meta.formatHelper,
        main: this.current,
        onOutput: (text) => this.write(text, "", log),
        onDebug: (text) => this.debugLine(text, log),
      });
      this.good(`— ${target} finished —`, log);
    } catch (err) {
      if (!this.stopped) this.error(err.message, this.ui.compiledOutput);
    }
  }

  // -- the Stop button --------------------------------------------------

  /** Record that something is running, and turn its Run button into Stop.
   *
   *  Stop takes Run's place rather than appearing next to it: while a
   *  program is executing, starting another one is not what that slot is
   *  for, and one control that changes meaning says so better than two
   *  competing for the same spot. The two are sized identically (see the
   *  stylesheet), and Stop is the immediately preceding sibling, so the
   *  swap moves nothing.
   *
   *  It happens the moment Run is pressed and covers the whole run --
   *  booting the runtime, compiling, executing -- because the programs
   *  this exists for are the ones that never reach the end on their own. */
  beginRun(origin, kind) {
    // A run started while a program is debugged ends the debugging.
    if (kind !== "debug" && this.debugger && this.debugger.state !== "off") {
      this.debugger.stop({ quiet: true });
    }
    this.endRun();
    this.stopped = false;
    this.running = { origin, kind };
    const right = origin === "right";
    (right ? this.ui.runRight : this.ui.runLeft).classList.add("pyk-hidden");
    (right ? this.ui.stopRight : this.ui.stopLeft).classList.remove("pyk-hidden");
  }

  endRun() {
    this.running = null;
    // Nothing runs, so the Web output tab shows no page: a page is only
    // ever the running program's.
    this.closePage();
    this.ui.stopLeft.classList.add("pyk-hidden");
    this.ui.stopRight.classList.add("pyk-hidden");
    this.ui.runLeft.classList.remove("pyk-hidden");
    this.ui.runRight.classList.remove("pyk-hidden");
  }

  /** Stops what Run started, and gives its editor the keyboard back.
   *  `quiet` leaves the log and the focus as they are, for a stop that is
   *  the start of another run. {quiet}? -> () */
  stopRun({ quiet = false } = {}) {
    if (!this.running) return;
    const { kind } = this.running;
    if (kind === "debug") {
      this.debugger.stop({ quiet });
      return;
    }
    this.stopped = true;
    if (!quiet) (kind === "js" ? this.right : this.left).focus();
    const log = kind === "js" ? this.ui.compiledOutput : this.ui.output;
    // A program that has answered and is only waiting for its page's
    // events is let go rather than killed: nothing is running to stop.
    const waiting = kind === "pyking" && this.runtime.isLive
      && !this.runtime.pending.size;
    if (waiting) {
      this.runtime.endLive();
      this.endRun();
      if (!quiet) this.error("— stopped —", log);
      return;
    }
    if (kind === "pyking") this.runtime.stop();
    else this.jsRunner.stop();
    this.endRun();
    if (!quiet) this.error("— stopped —", log);
    if (kind === "pyking") {
      this.status("busy", "restarting the compiler");
      // stop() terminated the interpreter, so a fresh one is already coming
      // up in the background; say when it is usable again.
      this.runtime.ready((msg) => this.status("busy", msg))
        .then(() => this.status("ready", "ready"))
        .catch(() => this.status("error", "failed"));
    }
  }

  // -- output pane ------------------------------------------------------


  // -- run while you type -----------------------------------------------

  /** Replace the source without it counting as typing. Also the method to
   *  use from an embedding page, for the same reason. */
  /** A debugger key that is a dead key on the reader's keyboard (Option+I
   *  on a Mac starts a ˆ) cannot be kept from starting its accent. So a
   *  composition such a key started or ran into is ended at once, and
   *  what a run of them left -- each dead key ending the one before and
   *  starting the next -- is taken back out when the last one ends: in
   *  the editor once Monaco has written it, in a text field at once.
   *  () -> () */
  watchDeadKeys() {
    const { ui } = this;
    // A letter without its accent, and no accent on its own: the spacing
    // modifier letters (ˆ is one) and the modifier symbols (¨ ´ ˜ ^ `).
    const strip = (text) => text.normalize("NFD").replace(/[\u0300-\u036f]/g, "")
      .replace(/[\p{Sk}\u02b0-\u02ff]/gu, "").normalize("NFC");
    // The span `before` and `after` differ in: {from, to} in `after`.
    const changed = (before, after) => {
      let from = 0;
      while (from < before.length && from < after.length && before[from] === after[from]) from += 1;
      let end = 0;
      while (end < before.length - from && end < after.length - from
             && before[before.length - 1 - end] === after[after.length - 1 - end]) end += 1;
      return { from, to: after.length - end };
    };
    // A run of compositions in one place: what it began from, whether a
    // debugger key is in it, and whether one is open now.
    let run = null;
    let pending = false;
    // A dead key may run into a composition already open, and starts the
    // next one when the keyboard ends that.
    this.deadKeyTaken = () => {
      pending = true;
      if (run?.open) {
        run.ours = true;
        setTimeout(finish, 0);
      }
    };
    // Ends the open composition: a blur commits it.
    const finish = () => {
      if (!run?.open || !run.ours) return;
      const el = run.field ?? ui.leftEditor.querySelector("textarea");
      el?.blur();
      if (run?.field) run.field.focus();
      else this.left.focus();
    };
    const begin = (field, value) => {
      if (!run) run = { field, before: value, ours: false, open: false };
      run.open = true;
      if (pending) run.ours = true;
      pending = false;
      if (run.ours) setTimeout(finish, 0);
    };
    // Once no composition has followed the one that ended, the run is over.
    const end = () => {
      if (!run) return;
      run.open = false;
      setTimeout(() => {
        if (!run || run.open) return;
        const done = run;
        run = null;
        if (done.ours) clean(done);
      }, 0);
    };
    const clean = ({ field, before }) => {
      if (field) {
        const value = field.value;
        const { from, to } = changed(before, value);
        const kept = strip(value.slice(from, to));
        if (kept === value.slice(from, to)) return;
        field.value = value.slice(0, from) + kept + value.slice(to);
        field.setSelectionRange(from + kept.length, from + kept.length);
        return;
      }
      const model = this.left.getModel();
      const value = model.getValue();
      const { from, to } = changed(before, value);
      const kept = strip(value.slice(from, to));
      if (kept === value.slice(from, to)) return;
      const start = model.getPositionAt(from);
      const stop = model.getPositionAt(to);
      this.left.executeEdits("debugger-key", [{
        range: new this.monaco.Range(start.lineNumber, start.column, stop.lineNumber, stop.column),
        text: kept,
      }]);
    };
    // A key after a dead one that started no composition: none is coming.
    ui.root.addEventListener("keydown", (event) => {
      if (event.key !== "Dead" && !event.isComposing && !run) pending = false;
    }, true);

    this.left.onDidCompositionStart(() => begin(null, this.left.getValue()));
    this.left.onDidCompositionEnd(end);
    const isField = (el) => el && ["INPUT", "TEXTAREA"].includes(el.tagName)
      && !ui.leftEditor.contains(el);
    ui.root.addEventListener("compositionstart", (event) => {
      if (isField(event.target)) begin(event.target, event.target.value);
    }, true);
    ui.root.addEventListener("compositionend", (event) => {
      if (isField(event.target) && run?.field === event.target) end();
    }, true);
  }

  setSource(text) {
    // Monaco fires its change event synchronously from setValue, so a
    // plain flag is enough and no reset-on-a-timer is needed.
    this.programmaticEdit = true;
    try {
      this.left.setValue(text);
      this.left.setPosition({ lineNumber: 1, column: 1 });
    } finally {
      this.programmaticEdit = false;
    }
  }

  scheduleAutoRun() {
    if (!this.settings.autoRun) return;
    clearTimeout(this.autoRunTimer);
    this.autoRunTimer = setTimeout(() => this.autoRun(), AUTO_RUN_DELAY);
  }

  cancelAutoRun() {
    clearTimeout(this.autoRunTimer);
    this.autoRunTimer = null;
  }

  async autoRun() {
    // A run started from an earlier keystroke may still be in flight -- the
    // first one of the session waits on the whole runtime download. Rather
    // than overlap them, let this edit re-arm the timer and run once that
    // one has finished, so the code that eventually runs is the latest.
    if (this.autoRunning) {
      this.scheduleAutoRun();
      return;
    }
    this.autoRunning = true;
    try {
      // A run of its own accord leaves the tab as it is: typing in the
      // editor with the REPL showing keeps the REPL showing. Nor does it
      // ask for input or take the keyboard.
      await this.runFromSource({ switchTab: false, asked: false });
    } finally {
      this.autoRunning = false;
    }
  }

  /** Clear the output pane when starting a run, if that is switched on.
   *  Compiling deliberately does not: the setting says "each time you press
   *  Run", and a compile error you wanted to keep beside the output would
   *  otherwise vanish. */
  beforeRun(log = this.ui.output) {
    if (this.settings.clearOnRun) this.clearOutput(log);
  }

  /** Writes text to an output log: the run's, unless another is named --
   *  the compiled code's, which its own Run and Compile write to.
   *  String -> String? -> Element? -> () */
  write(text, cls, log = this.ui.output) {
    const span = document.createElement("span");
    if (cls) span.className = cls;
    span.textContent = text;
    log.appendChild(span);
    // Following the newest line is part of being scrollable. With scrolling
    // switched off the pane clips instead, and scrolling it programmatically
    // would push the start of the output out of sight with no way back.
    if (this.settings.scrollOutput) {
      log.scrollTop = log.scrollHeight;
    }
  }
  /** A `debug` line: in the pane, marked apart from what the program
   *  printed, and on the console, which is where a JavaScript program's
   *  `debug` goes. */
  debugLine(text, log) {
    this.write(text, "debug", log);
    console.log(text.replace(/\n$/, ""));
  }
  note(text, log) { this.write(text + "\n", "note", log); }
  good(text, log) { this.write(text + "\n", "good", log); }
  error(text, log) { this.write(text + "\n", "err", log); }
  clearOutput(log = this.ui.output) { log.textContent = ""; }

  // -- error marking ----------------------------------------------------

  /** Underline the span the compiler complained about, with its message.
   *  `lexer.Info` counts rows from 1 and columns from 0; Monaco counts
   *  both from 1. {row1, col1, row2, col2} -> String -> () */
  markError(info, message = "compile error") {
    const { monaco } = this;
    const range = {
      startLineNumber: info.row1, startColumn: info.col1 + 1,
      endLineNumber: info.row2, endColumn: Math.max(info.col2 + 1, info.col1 + 2),
    };
    monaco.editor.setModelMarkers(this.left.getModel(), COMPILE_MARKERS, [{
      ...range, severity: monaco.MarkerSeverity.Error, message,
    }]);
    this.left.revealLineInCenterIfOutsideViewport(info.row1);
  }

  clearError() {
    this.monaco.editor.setModelMarkers(this.left.getModel(), COMPILE_MARKERS, []);
  }

  // -- misc -------------------------------------------------------------

  /** Downloads the last compile as a .zip: its files, what `pyk compile`
   *  writes beside them, and a Makefile. () -> Promise<()> */
  async download() {
    const log = this.ui.compiledOutput;
    if (!this.compiled || Object.keys(this.files).length === 0) return;
    const { source, target } = this.compiled;
    try {
      const analysis = await this.runtime.analyze(source);
      const lib = this.runtime.libURL;
      const fetched = async (url) => {
        const response = await fetch(url);
        return response.ok ? new Uint8Array(await response.arrayBuffer()) : null;
      };
      const bundle = async () => {
        const manifest = await (await fetch(this.runtime.pykingURL + "manifest.json")).json();
        return fetched(this.runtime.pykingURL + manifest.bundle);
      };
      const entries = await packFiles({
        target, files: this.files, externals: analysis.ok ? analysis.externals : [],
        source, name: "playground.pyk", get: (path) => fetched(lib + path), bundle,
      });
      const folder = `playground-${target}`;
      const bytes = zip(entries.map((e) => ({ name: `${folder}/${e.name}`, data: e.data })));
      const link = document.createElement("a");
      link.href = URL.createObjectURL(new Blob([bytes], { type: "application/zip" }));
      link.download = folder + ".zip";
      document.body.appendChild(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(link.href), 10000);
      this.note(`Downloaded ${folder}.zip: ${entries.length} files. Unzip it and type `
        + "make to build, make run to run.", log);
    } catch (err) {
      this.error("Could not make the download: " + err.message, log);
    }
  }

  async copyRight() {
    try {
      await navigator.clipboard.writeText(this.right.getValue());
      this.note("Copied the generated code to the clipboard.", this.ui.compiledOutput);
    } catch {
      this.error("The browser refused clipboard access.", this.ui.compiledOutput);
    }
  }

  status(kind, text) {
    this.ui.dot.className = "pyk-dot " + kind;
    this.ui.statusText.textContent = text;
  }

  // -- light and dark ---------------------------------------------------
  //
  // The theme is `data-theme` on the root, which the stylesheet's tokens
  // follow, and Monaco's own theme. Where the embedding page passed
  // `theme`, it decides -- calling `setTheme` -- and the switch and the
  // setting are hidden; otherwise the viewer does, starting from the
  // system's preference.

  installTheme() {
    const { ui } = this;
    const owned = this.cfg.theme !== null && this.cfg.theme !== undefined;
    ui.themeButton.classList.toggle("pyk-hidden", owned);
    ui.themeField.classList.toggle("pyk-hidden", owned);
    this.systemDark = globalThis.matchMedia?.("(prefers-color-scheme: dark)") ?? null;
    this.systemDark?.addEventListener?.("change", () => this.applyTheme());
    ui.themeButton.addEventListener("click", () => {
      this.settings.theme = this.effectiveTheme() === "dark" ? "light" : "dark";
      this.applyTheme();
      this.saveSettings();
    });
    ui.themeChoice.addEventListener("change", () => {
      this.settings.theme = ui.themeChoice.value;
      this.applyTheme();
      this.saveSettings();
    });
  }

  /** The theme showing: the embedding page's, or the viewer's choice,
   *  with "system" read from the browser. () -> "light" | "dark" */
  effectiveTheme() {
    const chosen = this.cfg.theme ?? this.settings.theme;
    if (chosen === "light" || chosen === "dark") return chosen;
    const dark = this.systemDark ?? globalThis.matchMedia?.("(prefers-color-scheme: dark)");
    return dark && !dark.matches ? "light" : "dark";
  }

  applyTheme() {
    const theme = this.effectiveTheme();
    this.ui.root.dataset.theme = theme;
    this.monaco.editor.setTheme(themeFor(theme));
    this.ui.themeChoice.value = this.settings.theme;
    this.help?.setTheme(theme);
    this.ui.themeButton.title = theme === "dark"
      ? "Switch to the light theme" : "Switch to the dark theme";
  }

  /** Shows the playground in "light" or "dark", for a page that decides
   *  the theme itself (the `theme` option). String -> () */
  setTheme(theme) {
    this.cfg.theme = theme === "light" ? "light" : "dark";
    this.applyTheme();
  }

  // -- the REPL ---------------------------------------------------------
  //
  // A session of `pyk repl` (src/repl_session.ml) on a runtime of its own.
  // The prompt is a text area at the foot of the transcript: Enter
  // submits an entry the parser says is whole, and otherwise opens the
  // next line indented, as the terminal's editor does; a blank line ends
  // a block. The environment below is what `:ls` would list, read back
  // after every entry.

  installRepl() {
    const { ui } = this;
    ui.replCopy.addEventListener("click", () => this.copyToRepl());
    ui.replStop.addEventListener("click", () => this.stopRepl());
    ui.replReset.addEventListener("click", () => this.submitRepl(":reset"));
    ui.replClear.addEventListener("click", () => {
      ui.replLog.textContent = "";
      ui.replInput.focus();
    });
    // A click anywhere in the transcript puts the cursor in the prompt,
    // unless it was selecting text to copy.
    ui.repl.addEventListener("mouseup", () => {
      if (!String(globalThis.getSelection?.() ?? "")) ui.replInput.focus();
    });
    ui.replInput.addEventListener("input", () => this.fitReplInput());
    ui.replInput.addEventListener("keydown", (event) => {
      if (event.key !== "Tab" && event.key !== "Shift") this.hideReplCompletions();
      this.replKey(event);
    });
    ui.replInput.addEventListener("blur", () => this.hideReplCompletions());
    this.showBindings([]);
  }

  /** Starts the REPL's runtime and an empty session, once. Answers whether
   *  it is ready. () -> Promise<Bool> */
  ensureRepl() {
    if (!this.replStarting) {
      this.replStarting = (async () => {
        this.replNote("Starting the REPL…");
        this.replRuntime = createRuntime({
          webrun: this.cfg.webrunURL, pyking: this.cfg.pykingURL,
        });
        await this.replRuntime.ready();
        const { bindings } = await this.replRuntime.replStart();
        this.showBindings(bindings);
        this.ui.replLog.lastChild?.remove();
        this.replNote("Pyking REPL. Type an entry and press Enter; :help lists "
                      + "the commands.");
        return true;
      })().catch((err) => {
        this.replStarting = null;
        this.replError("Could not start the REPL: " + err.message);
        return false;
      });
    }
    return this.replStarting;
  }

  async openRepl() {
    this.ui.replInput.focus();
    await this.ensureRepl();
  }

  /** Grows the prompt to the lines it holds. () -> () */
  fitReplInput() {
    const input = this.ui.replInput;
    input.rows = Math.max(1, input.value.split("\n").length);
    this.ui.repl.scrollTop = this.ui.repl.scrollHeight;
  }

  /** Sets what the prompt holds, the cursor at its end. String -> () */
  setReplInput(text) {
    const input = this.ui.replInput;
    input.value = text;
    input.setSelectionRange(text.length, text.length);
    this.fitReplInput();
  }

  /** What a key does in the prompt: Enter, Shift+Enter, Tab (an indent
   *  at the start of a line, a completion after a word), Backspace in the
   *  indentation, Escape, and Up and Down through the history.
   *  KeyboardEvent -> () */
  replKey(event) {
    const input = this.ui.replInput;
    const { value, selectionStart: at, selectionEnd } = input;
    const before = value.slice(0, at);
    const onFirstLine = !before.includes("\n");
    const onLastLine = !value.slice(at).includes("\n");
    if (event.key === "Enter" && !event.altKey && !event.ctrlKey && !event.metaKey) {
      event.preventDefault();
      if (this.replBusy) return;
      if (event.shiftKey) this.replNewline();
      else this.replEnter();
    } else if (event.key === "Tab" && !event.shiftKey) {
      event.preventDefault();
      const line = before.slice(before.lastIndexOf("\n") + 1);
      if (line.trim() === "" || at !== selectionEnd) {
        input.setRangeText("    ", at, selectionEnd, "end");
        this.fitReplInput();
      } else {
        this.replTab();
      }
    } else if (event.key === "Backspace" && at === selectionEnd && at > 0) {
      // Inside a line's indentation, Backspace removes a whole level.
      const line = before.slice(before.lastIndexOf("\n") + 1);
      if (line.length > 0 && /^ +$/.test(line)) {
        event.preventDefault();
        const width = line.length % 4 || 4;
        input.setRangeText("", at - width, at, "end");
        this.fitReplInput();
      }
    } else if (event.key === "Escape") {
      event.preventDefault();
      this.setReplInput("");
      this.replAt = this.replHistory.length;
    } else if (event.key === "ArrowUp" && onFirstLine && this.replAt > 0) {
      event.preventDefault();
      if (this.replAt === this.replHistory.length) this.replDraft = value;
      this.replAt -= 1;
      this.setReplInput(this.replHistory[this.replAt]);
    } else if (event.key === "ArrowDown" && onLastLine
               && this.replAt < this.replHistory.length) {
      event.preventDefault();
      this.replAt += 1;
      this.setReplInput(this.replAt === this.replHistory.length
        ? this.replDraft : this.replHistory[this.replAt]);
    }
  }

  /** Tab after a word: the word completed outright where one name fits,
   *  as far as every fitting name agrees where several do, and the names
   *  listed under the prompt, each with its type, where they agree no
   *  further; clicking one puts it in. () -> Promise<()> */
  async replTab() {
    if (!(await this.ensureRepl())) return;
    const input = this.ui.replInput;
    const at = input.selectionStart;
    const before = input.value.slice(0, at);
    const lineStart = before.lastIndexOf("\n") + 1;
    const line = input.value.slice(lineStart).split("\n")[0];
    const { start, items } = await this.replRuntime.replComplete(line, at - lineStart);
    this.hideReplCompletions();
    if (items.length === 0) return;
    const typed = at - lineStart - start;
    const names = items.map((item) => item.label);
    let shared = names[0];
    for (const name of names) {
      let n = 0;
      while (n < shared.length && n < name.length && shared[n] === name[n]) n += 1;
      shared = shared.slice(0, n);
    }
    if (shared.length > typed) {
      input.setRangeText(shared.slice(typed), at, at, "end");
      this.fitReplInput();
      return;
    }
    const list = this.ui.replComplete;
    list.textContent = "";
    for (const item of items.slice(0, 100)) {
      const row = document.createElement("div");
      row.className = "item";
      row.setAttribute("role", "option");
      const label = document.createElement("span");
      label.className = "label";
      label.textContent = item.label;
      row.append(label);
      if (item.detail) {
        const detail = document.createElement("span");
        detail.className = "detail";
        detail.textContent = item.detail;
        row.append(detail);
      }
      row.addEventListener("mousedown", (event) => {
        event.preventDefault();
        const now = input.selectionStart;
        input.setRangeText(item.label.slice(typed), now, now, "end");
        this.hideReplCompletions();
        this.fitReplInput();
        input.focus();
      });
      list.append(row);
    }
    list.classList.remove("pyk-hidden");
    list.scrollIntoView?.({ block: "nearest" });
  }

  /** Takes the list of completions away. () -> () */
  hideReplCompletions() {
    this.ui.replComplete?.classList.add("pyk-hidden");
  }

  /** Opens a new line at the cursor, indented where the parser says the
   *  line above leaves it. () -> Promise<()> */
  async replNewline() {
    const input = this.ui.replInput;
    const at = input.selectionStart;
    let indent = "";
    if (await this.ensureRepl()) {
      ({ indent } = await this.replRuntime.replLine(input.value.slice(0, at)));
    }
    input.setRangeText("\n" + indent, at, input.selectionEnd, "end");
    this.fitReplInput();
  }

  /** Enter: submit the entry where it is finished -- one whole line that
   *  nothing could continue, a command, or a block ended by a blank line
   *  -- and open the next line otherwise. () -> Promise<()> */
  async replEnter() {
    const input = this.ui.replInput;
    const text = input.value;
    if (text.trim() === "") return;
    const lines = text.split("\n");
    if (lines.length > 1 && input.selectionStart < text.length) return this.replNewline();
    if (lines.length === 1) {
      if (text.trim().startsWith(":")) return this.submitRepl(text);
      if (!(await this.ensureRepl())) return;
      const { complete, continuable } = await this.replRuntime.replLine(text);
      if (complete && !continuable) return this.submitRepl(text);
      return this.replNewline();
    }
    if (lines[lines.length - 1].trim() === "") {
      return this.submitRepl(text.replace(/(\n[ \t]*)+$/, ""));
    }
    return this.replNewline();
  }

  /** Runs one entry in the session and shows what it printed, showed and
   *  was refused with, then the environment. String -> Promise<()> */
  async submitRepl(text) {
    if (this.replBusy) return;
    if (!(await this.ensureRepl())) return;
    const input = this.ui.replInput;
    this.replEcho(text);
    if (text.trim() !== "" && this.replHistory[this.replHistory.length - 1] !== text) {
      this.replHistory.push(text);
    }
    this.replAt = this.replHistory.length;
    this.replDraft = "";
    this.setReplInput("");
    this.replBusy = true;
    input.disabled = true;
    this.ui.replStop.classList.remove("pyk-hidden");
    try {
      const answer = await this.replRuntime.replSubmit(text, {
        onOutput: (out) => this.replWrite(out),
        onShow: (out) => this.replWrite(out, "shown"),
        onDebug: (out) => this.replWrite(out, "debug"),
      });
      for (const error of answer.errors) this.replError(error);
      if (answer.exit !== undefined) {
        this.replError(`sys.exit(${answer.exit}) ended the entry; the session goes on.`);
      }
      if (answer.bindings) this.showBindings(answer.bindings);
      if (answer.pending) this.setReplInput(answer.pending);
    } catch (err) {
      if (!this.replStopped) this.replError("the REPL failed: " + err.message);
    } finally {
      this.replStopped = false;
      this.replBusy = false;
      input.disabled = false;
      this.ui.replStop.classList.add("pyk-hidden");
      if (this.tab === "repl") input.focus();
    }
  }

  /** Stop: the entry's worker is ended, and the session with it; a new
   *  one starts at once. () -> Promise<()> */
  async stopRepl() {
    if (!this.replBusy || !this.replRuntime) return;
    this.replStopped = true;
    this.replRuntime.stop();
    this.replError("— stopped; the session starts again —");
    this.showBindings([]);
    // An entry made before the new session has started waits for it
    // (ensureRepl answers this promise).
    this.replStarting = (async () => {
      await this.replRuntime.ready();
      this.showBindings((await this.replRuntime.replStart()).bindings);
      return true;
    })().catch((err) => {
      this.replStarting = null;
      this.replError("Could not restart the REPL: " + err.message);
      return false;
    });
    await this.replStarting;
  }

  /** The text marked in the editor, into the prompt at its cursor, with
   *  the indentation its lines share removed -- or a message saying to
   *  mark some first. () -> () */
  copyToRepl() {
    const marked = this.left.getModel().getValueInRange(this.left.getSelection());
    if (marked.trim() === "") {
      this.replError("Nothing is marked in the editor: mark the text to copy, "
                     + "then press Copy from editor.");
      return;
    }
    const lines = marked.replace(/\s+$/, "").split("\n");
    const indents = lines.filter((l) => l.trim() !== "")
      .map((l) => l.match(/^ */)[0].length);
    const common = Math.min(...indents);
    const text = lines.map((l) => l.slice(Math.min(common, l.match(/^ */)[0].length)))
      .join("\n");
    const input = this.ui.replInput;
    input.focus();
    input.setRangeText(text, input.selectionStart, input.selectionEnd, "end");
    this.fitReplInput();
  }

  /** An entry, as it was typed, in the transcript. String -> () */
  replEcho(text) {
    const entry = document.createElement("div");
    entry.className = "entry";
    text.split("\n").forEach((line, k) => {
      const prompt = document.createElement("span");
      prompt.className = "prompt";
      prompt.textContent = k === 0 ? "> " : ". ";
      entry.append(prompt, line + "\n");
    });
    this.ui.replLog.appendChild(entry);
    this.ui.repl.scrollTop = this.ui.repl.scrollHeight;
  }

  replWrite(text, cls) {
    const span = document.createElement("span");
    if (cls) span.className = cls;
    span.textContent = text;
    this.ui.replLog.appendChild(span);
    this.ui.repl.scrollTop = this.ui.repl.scrollHeight;
  }
  replNote(text) { this.replWrite(text + "\n", "note"); }
  replError(text) { this.replWrite(text + "\n", "err"); }

  /** The environment table: one row per binding, as `:ls` lists them.
   *  [{name, value, type, implicit}] -> () */
  showBindings(bindings) {
    const { env } = this.ui;
    env.textContent = "";
    const table = document.createElement("table");
    const head = table.createTHead().insertRow();
    for (const title of ["Name", "Value", "Type"]) {
      const th = document.createElement("th");
      th.textContent = title;
      head.appendChild(th);
    }
    const body = table.createTBody();
    if (bindings.length === 0) {
      const cell = body.insertRow().insertCell();
      cell.colSpan = 3;
      cell.className = "empty";
      cell.textContent = "no bindings yet";
    }
    for (const binding of bindings) {
      const row = body.insertRow();
      const name = row.insertCell();
      name.className = "name";
      name.textContent = binding.name;
      if (binding.implicit) {
        const tag = document.createElement("span");
        tag.className = "tag";
        tag.textContent = "implicit";
        name.appendChild(tag);
      }
      const value = row.insertCell();
      value.className = "value";
      value.textContent = binding.value;
      const type = row.insertCell();
      type.className = "type";
      type.textContent = binding.type ?? "";
    }
    env.appendChild(table);
  }

  // -- resizable panes --------------------------------------------------

  installSplitters() {
    const { columns, gutterV } = this.ui;

    // Horizontal drag: the share of the columns box given to the source
    // pane. Under the narrow (stacked) layout the same grid property is a
    // row height, so the same handler serves both -- which axis it means is
    // decided by the media query, not here.
    this.installDrag(gutterV, "v", (event) => {
      const box = columns.getBoundingClientRect();
      // Which axis this handle splits is decided by the media query, so ask
      // the handle's own shape rather than duplicating the breakpoint here:
      // side by side it is tall and thin, stacked it is wide and short.
      const handle = gutterV.getBoundingClientRect();
      const fraction = handle.width > handle.height
        ? (event.clientY - box.top) / box.height
        : (event.clientX - box.left) / box.width;
      this.setSplit("--pyk-col-split", fraction);
    });

    // Vertical drag: how much of a tab the lower part takes -- the output
    // below the compiled code and below the page, the environment below
    // the REPL -- measured from the bottom because that is the edge it is
    // anchored to. One share for all three tabs.
    for (const [gutter, panel] of [[this.ui.gutterCompiled, this.ui.panelCompiled],
                                   [this.ui.gutterWeb, this.ui.panelWeb],
                                   [this.ui.gutterRepl, this.ui.panelRepl]]) {
      this.installDrag(gutter, "h", (event) => {
        const box = panel.getBoundingClientRect();
        this.setSplit("--pyk-out-split", (box.bottom - event.clientY) / box.height);
      });
    }
  }

  setSplit(name, fraction) {
    // Clamped so a pane can be made small but never dragged away entirely --
    // a zero-width editor is easy to reach and impossible to grab back.
    const percent = Math.min(85, Math.max(12, fraction * 100));
    this.ui.root.style.setProperty(name, percent.toFixed(2) + "%");
  }

  installDrag(handle, axis, onMove) {
    handle.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      // Capturing means the pointer keeps reporting to this handle even
      // once it has moved off it -- without that the drag stops the moment
      // the cursor crosses into an editor.
      handle.setPointerCapture?.(event.pointerId);
      handle.classList.add("dragging");
      this.ui.root.classList.add("pyk-dragging", "dragging-" + axis);

      const move = (e) => onMove(e);
      const stop = (e) => {
        handle.releasePointerCapture?.(e.pointerId);
        handle.classList.remove("dragging");
        this.ui.root.classList.remove("pyk-dragging", "dragging-" + axis);
        handle.removeEventListener("pointermove", move);
        handle.removeEventListener("pointerup", stop);
        handle.removeEventListener("pointercancel", stop);
        this.saveSettings();
      };
      handle.addEventListener("pointermove", move);
      handle.addEventListener("pointerup", stop);
      handle.addEventListener("pointercancel", stop);
    });
  }

  resetLayout() {
    this.ui.root.style.removeProperty("--pyk-col-split");
    this.ui.root.style.removeProperty("--pyk-out-split");
    this.saveSettings();
    this.note("Pane sizes reset.");
  }

  // -- settings ---------------------------------------------------------

  installSettings() {
    const { settingsButton, modal, modalClose, fontSize } = this.ui;
    settingsButton.addEventListener("click", () => this.openSettings());
    modalClose.addEventListener("click", () => this.closeSettings());
    // Only a click on the backdrop itself closes; one inside the dialog
    // bubbles to here too and must not.
    modal.addEventListener("click", (e) => {
      if (e.target === modal) this.closeSettings();
    });
    fontSize.addEventListener("input", () => {
      this.applyFontSize(Number(fontSize.value));
      this.saveSettings();
    });
    this.ui.autoRun.addEventListener("change", () => {
      this.settings.autoRun = this.ui.autoRun.checked;
      // Switching it off must also drop an edit already waiting to run;
      // switching it on does not run anything until the next keystroke, so
      // ticking a box never starts a download on its own.
      if (!this.settings.autoRun) this.cancelAutoRun();
      this.saveSettings();
    });
    this.ui.scrollOutput.addEventListener("change", () => {
      this.settings.scrollOutput = this.ui.scrollOutput.checked;
      this.applyOutputScroll();
      this.saveSettings();
    });
    this.ui.clearOnRun.addEventListener("change", () => {
      this.settings.clearOnRun = this.ui.clearOnRun.checked;
      this.saveSettings();
    });
    this.ui.tinywebLog.addEventListener("change", () => {
      this.settings.tinywebLog = this.ui.tinywebLog.checked;
      // A program already running starts or stops logging at once.
      this.runtime?.setTinywebLog?.(this.settings.tinywebLog);
      this.saveSettings();
    });
    this.ui.resetLayoutButton.addEventListener("click", () => this.resetLayout());
    this.ui.debugStopOnEntry.addEventListener("change", () => {
      this.settings.debugStopOnEntry = this.ui.debugStopOnEntry.checked;
      this.saveSettings();
    });
    this.ui.debugJustMyCode.addEventListener("change", () => {
      this.settings.debugJustMyCode = this.ui.debugJustMyCode.checked;
      this.saveSettings();
    });
    this.ui.debugKeysReset.addEventListener("click", () => {
      this.settings.debugKeys = {};
      this.saveSettings();
      this.showDebugKeys();
    });
    this.showDebugKeys();
  }

  /** The settings' debugger keys: per action, a chip for each key with
   *  ✕ to remove it, + to record one more (Escape leaves it), and Reset
   *  for the action's defaults. () -> () */
  showDebugKeys() {
    const list = this.ui.debugKeyList;
    list.textContent = "";
    const saved = this.settings.debugKeys ?? {};
    const keysOf = (action) => action in saved ? keyList(saved[action]) : DEFAULT_KEYS[action];
    const save = (action, specs) => {
      const rest = { ...(this.settings.debugKeys ?? {}) };
      if (specs.join("\n") === DEFAULT_KEYS[action].join("\n")) delete rest[action];
      else rest[action] = specs;
      this.settings.debugKeys = rest;
      this.saveSettings();
      this.showDebugKeys();
    };
    const button = (text, title, onClick) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = text;
      b.title = title;
      b.addEventListener("click", onClick);
      return b;
    };
    for (const [action, label] of ACTIONS) {
      const specs = keysOf(action);
      const row = document.createElement("div");
      row.className = "pyk-key-row";
      row.dataset.action = action;
      const name = document.createElement("span");
      name.className = "pyk-key-name";
      name.textContent = label;
      const chips = document.createElement("span");
      chips.className = "pyk-key-chips";
      for (const spec of specs) {
        const chip = document.createElement("span");
        chip.className = "pyk-key-chip";
        chip.textContent = showKey(spec);
        chip.append(button("✕", `Remove ${showKey(spec)}`,
          () => save(action, specs.filter((k) => k !== spec))));
        chips.append(chip);
      }
      const add = button("+", "Add a key: click, then press it", () => {
        const field = document.createElement("input");
        field.type = "text";
        field.readOnly = true;
        field.className = "pyk-key-field";
        field.placeholder = "press a key";
        field.addEventListener("keydown", (event) => {
          if (event.key === "Tab") return;
          event.preventDefault();
          event.stopPropagation();
          if (event.key === "Escape") {
            field.blur();
            return;
          }
          const spec = specOf(event);
          if (spec === null) return;
          save(action, specs.includes(spec) ? specs : [...specs, spec]);
        });
        field.addEventListener("blur", () => {
          if (field.isConnected) field.replaceWith(add);
        });
        add.replaceWith(field);
        field.focus();
      });
      add.className = "pyk-key-add";
      chips.append(add);
      const reset = button("reset", `${label}: its default keys, ${showKeys(DEFAULT_KEYS[action])}`,
        () => save(action, DEFAULT_KEYS[action]));
      reset.className = "pyk-key-reset";
      reset.disabled = !(action in saved);
      row.append(name, chips, reset);
      list.append(row);
    }
    this.debugger?.showKeys();
  }

  openSettings() {
    this.ui.modal.classList.remove("pyk-hidden");
    this.ui.fontSize.focus();
  }

  closeSettings() {
    this.ui.modal.classList.add("pyk-hidden");
    this.left.focus();
  }

  applyFontSize(px) {
    this.settings.fontSize = px;
    this.left.updateOptions({ fontSize: px });
    this.right.updateOptions({ fontSize: px });
    // The output pane is plain text, not an editor, so it needs telling
    // separately -- but it should scale with the code beside it.
    for (const element of [this.ui.output, this.ui.compiledOutput, this.ui.repl, this.ui.env,
                           this.ui.panelDebug]) {
      element.style.fontSize = px + "px";
    }
    this.ui.fontValue.textContent = px + "px";
    this.ui.fontSize.value = String(px);
  }

  applyOutputScroll() {
    const on = this.settings.scrollOutput;
    this.ui.output.classList.toggle("pyk-no-scroll", !on);
    this.ui.compiledOutput.classList.toggle("pyk-no-scroll", !on);
    this.ui.scrollOutput.checked = on;
  }

  applySettings() {
    this.applyTheme();
    this.applyFontSize(this.settings.fontSize);
    this.applyOutputScroll();
    this.ui.clearOnRun.checked = this.settings.clearOnRun;
    this.ui.autoRun.checked = this.settings.autoRun;
    this.ui.tinywebLog.checked = this.settings.tinywebLog;
    this.ui.debugStopOnEntry.checked = Boolean(this.settings.debugStopOnEntry);
    this.ui.debugJustMyCode.checked = this.settings.debugJustMyCode !== false;
    for (const [key, name] of [["colSplit", "--pyk-col-split"],
                               ["outSplit", "--pyk-out-split"]]) {
      if (this.settings[key]) this.ui.root.style.setProperty(name, this.settings[key]);
    }
  }

  saveSettings() {
    const style = this.ui.root.style;
    saveSettings({
      theme: this.settings.theme,
      fontSize: this.settings.fontSize,
      scrollOutput: this.settings.scrollOutput,
      clearOnRun: this.settings.clearOnRun,
      autoRun: this.settings.autoRun,
      tinywebLog: this.settings.tinywebLog,
      debugStopOnEntry: this.settings.debugStopOnEntry,
      debugJustMyCode: this.settings.debugJustMyCode,
      debugKeys: this.settings.debugKeys,
      colSplit: style.getPropertyValue("--pyk-col-split") || null,
      outSplit: style.getPropertyValue("--pyk-out-split") || null,
    });
  }
}

// ------------------------------------------------------------------ DOM

function buildDom(host, meta, cfg) {
  host.classList.add("pyk-playground");
  host.innerHTML = `
    <div class="pyk-header">
      <div class="pyk-title">Pyking Playground
        <small data-r="version"></small></div>
      <div class="pyk-status"><span class="pyk-dot"></span>
        <span data-r="statusText">idle</span></div>
      <button class="pyk-theme" data-r="themeButton" title="Switch to the light theme"
              aria-label="Switch between the light and dark themes">
        <svg class="sun" viewBox="0 0 16 16" width="15" height="15" fill="none"
             stroke="currentColor" stroke-width="1.5" stroke-linecap="round"
             aria-hidden="true">
          <circle cx="8" cy="8" r="3"/>
          <path d="M8 1v1.6M8 13.4V15M1 8h1.6M13.4 8H15M3.05 3.05l1.13 1.13M11.82 11.82l1.13 1.13M3.05 12.95l1.13-1.13M11.82 4.18l1.13-1.13"/>
        </svg>
        <svg class="moon" viewBox="0 0 16 16" width="15" height="15"
             fill="currentColor" aria-hidden="true">
          <path d="M13.5 10.2A6 6 0 0 1 5.8 2.5a6 6 0 1 0 7.7 7.7z"/>
        </svg></button>
      <button class="pyk-settings" data-r="settingsButton" title="Settings">
        <svg viewBox="0 0 16 16" width="14" height="14" fill="none"
             stroke="currentColor" stroke-width="1.6" stroke-linecap="round"
             aria-hidden="true">
          <path d="M2 4h5.5M11.5 4H14M2 8h2.5M8.5 8H14M2 12h6.5M12.5 12H14"/>
          <circle cx="9.5" cy="4" r="1.7" fill="currentColor" stroke="none"/>
          <circle cx="6.5" cy="8" r="1.7" fill="currentColor" stroke="none"/>
          <circle cx="10.5" cy="12" r="1.7" fill="currentColor" stroke="none"/>
        </svg><span>Settings</span></button>
    </div>
    <div class="pyk-columns" data-r="columns">
      <section class="pyk-pane">
        <div class="pyk-toolbar">
          <span class="pyk-label">Examples</span>
          <select data-r="example" title="Load an example program"></select>
          <button data-r="copyLink"
                  title="Copy a link that opens this program in the playground">Copy code as link</button>
          <span class="pyk-spacer"></span>
          <button class="pyk-stop pyk-hidden" data-r="stopLeft"
                  title="Stop the running program">■ Stop</button>
          <button class="pyk-run" data-r="runLeft"
                  title="Run the program itself (Shift+Enter or Ctrl+Enter)">▶ Run</button>
        </div>
        <div class="pyk-editor" data-r="leftEditor"></div>
      </section>
      <div class="pyk-gutter pyk-gutter-v" data-r="gutterV" role="separator"
           aria-orientation="vertical" title="Drag to resize"></div>
      <section class="pyk-pane" data-r="rightPane">
        <div class="pyk-tabs" role="tablist">
          <button class="pyk-tab active" data-r="tabRun" data-tab="run" role="tab"
                  title="What the program printed when you pressed Run">Run output</button>
          <button class="pyk-tab" data-r="tabCompiled" data-tab="compiled" role="tab"
                  title="Compile the program for a target, and run what it became">Compiled code</button>
          <button class="pyk-tab" data-r="tabWeb" data-tab="web" role="tab"
                  title="What the program shows: a program using tinyweb draws here">Web output</button>
          <button class="pyk-tab" data-r="tabRepl" data-tab="repl" role="tab"
                  title="Type Pyking an entry at a time">REPL</button>
          <button class="pyk-tab" data-r="tabDebug" data-tab="debug" role="tab"
                  title="Run the program a step at a time: breakpoints, variables and the calls in progress">Debug</button>
          <button class="pyk-tab" data-r="tabHelp" data-tab="help" role="tab"
                  title="Getting started, the language reference and the libraries">Help</button>
        </div>

        <div class="pyk-panel pyk-panel-run" data-r="panelRun" role="tabpanel">
          <div class="pyk-output-wrap" data-r="outputWrap">
            <div class="pyk-output-head">
              <span class="pyk-label">Output</span>
              <span class="pyk-spacer"></span>
              <label class="pyk-check pyk-hidden" data-r="tinywebLogBox"
                     title="Show what the program sends its page, and what the page answers, as pyk --tinyweb-log does">
                <input type="checkbox" data-r="tinywebLog">
                tinyweb log
              </label>
              <button data-r="clear">Clear</button>
            </div>
            <pre class="pyk-output" data-r="output"></pre>
          </div>
        </div>

        <div class="pyk-panel pyk-hidden" data-r="panelCompiled" role="tabpanel">
          <div class="pyk-toolbar">
            <span class="pyk-label">Target</span>
            <select data-r="target"></select>
            <button class="pyk-primary" data-r="compile"
                    title="Compile the source for this target">Compile</button>
            <span class="pyk-spacer"></span>
            <button class="pyk-stop pyk-hidden" data-r="stopRight"
                    title="Stop the running program">■ Stop</button>
            <button class="pyk-run" data-r="runRight">▶ Run</button>
            <!-- No glyph: U+29C9 has no coverage in the usual UI fonts and
                 rendered as an empty box. A word always renders. -->
            <button data-r="copy" title="Copy the generated code">Copy</button>
            <button data-r="download"
                    title="Download every compiled file, with a Makefile, as a .zip">Download</button>
          </div>
          <div class="pyk-files" data-r="files"></div>
          <div class="pyk-editor" data-r="rightEditor"></div>
          <div class="pyk-gutter pyk-gutter-h" data-r="gutterCompiled" role="separator"
               aria-orientation="horizontal" title="Drag to resize"></div>
          <div class="pyk-output-wrap">
            <div class="pyk-output-head">
              <span class="pyk-label">Output</span>
              <span class="pyk-spacer"></span>
              <button data-r="clearCompiled">Clear</button>
            </div>
            <pre class="pyk-output" data-r="compiledOutput"></pre>
          </div>
        </div>

        <div class="pyk-panel pyk-hidden" data-r="panelWeb" role="tabpanel">
          <div class="pyk-stage">
            <div class="pyk-frame">
              <div class="pyk-frame-bar" data-r="frameBar">
                <div class="pyk-frame-dots" aria-hidden="true"><span></span><span></span><span></span></div>
                <div class="pyk-frame-title" data-r="pageTitle">playground.pyk</div>
                <button data-r="refresh"
                        title="Stop the program and run the source again">↻ Refresh</button>
              </div>
              <div class="pyk-page" data-r="page" tabindex="0">${PAGE_PLACEHOLDER}</div>
            </div>
          </div>
          <div class="pyk-gutter pyk-gutter-h" data-r="gutterWeb" role="separator"
               aria-orientation="horizontal" title="Drag to resize"></div>
        </div>

        <div class="pyk-panel pyk-hidden pyk-panel-debug" data-r="panelDebug" role="tabpanel"></div>

        <div class="pyk-panel pyk-hidden" data-r="panelHelp" role="tabpanel">
          <div class="pyk-help-host" data-r="helpHost"></div>
        </div>

        <div class="pyk-panel pyk-hidden" data-r="panelRepl" role="tabpanel">
          <div class="pyk-toolbar">
            <span class="pyk-label">REPL</span>
            <button data-r="replCopy"
                    title="Put the text marked in the editor into the prompt">Copy from editor</button>
            <span class="pyk-spacer"></span>
            <button class="pyk-stop pyk-hidden" data-r="replStop"
                    title="Stop the entry; the session starts again">■ Stop</button>
            <button data-r="replReset" title="Forget everything and start again (:reset)">Reset</button>
            <button data-r="replClear" title="Clear the transcript; the session is kept">Clear</button>
          </div>
          <div class="pyk-repl" data-r="repl">
            <div class="pyk-repl-log" data-r="replLog"></div>
            <div class="pyk-repl-line">
              <span class="prompt" data-r="replPrompt">&gt; </span>
              <textarea class="pyk-repl-input" data-r="replInput" rows="1"
                        spellcheck="false" autocomplete="off" autocapitalize="off"
                        aria-label="REPL input"></textarea>
            </div>
            <div class="pyk-repl-complete pyk-hidden" data-r="replComplete" role="listbox"
                 aria-label="Completions"></div>
          </div>
          <div class="pyk-gutter pyk-gutter-h" data-r="gutterRepl" role="separator"
               aria-orientation="horizontal" title="Drag to resize"></div>
          <div class="pyk-env-wrap">
            <div class="pyk-output-head">
              <span class="pyk-label">Environment</span>
            </div>
            <div class="pyk-env" data-r="env"></div>
          </div>
        </div>
      </section>
    </div>
    <div class="pyk-modal-backdrop pyk-hidden" data-r="inputModal">
      <div class="pyk-modal" role="dialog" aria-modal="true"
           aria-label="What the program reads">
        <div class="pyk-modal-head">
          <strong>Before it runs</strong>
        </div>
        <div class="pyk-modal-body">
          <div class="pyk-field" data-r="inputStdinField">
            <label for="pyk-input-stdin">Standard input</label>
            <textarea id="pyk-input-stdin" class="pyk-input-text" rows="6"
                      spellcheck="false" data-r="inputStdin"></textarea>
            <p class="pyk-hint">What io.read_line, io.read and io.is_eof
              read, one line at a time.</p>
          </div>
          <div class="pyk-field" data-r="inputArgsField">
            <label for="pyk-input-args">Arguments</label>
            <input id="pyk-input-args" class="pyk-input-line" type="text"
                   spellcheck="false" data-r="inputArgs">
            <p class="pyk-hint">What sys.args() answers: separated by spaces,
              quoted to keep a space inside one.</p>
          </div>
          <div class="pyk-field-row pyk-input-buttons">
            <span class="pyk-spacer"></span>
            <button data-r="inputCancel">Cancel</button>
            <button class="pyk-primary" data-r="inputRun">▶ Run</button>
          </div>
        </div>
      </div>
    </div>
    <div class="pyk-modal-backdrop pyk-hidden" data-r="modal">
      <div class="pyk-modal pyk-modal-wide" role="dialog" aria-modal="true"
           aria-label="Playground settings">
        <div class="pyk-modal-head">
          <strong>Settings</strong>
          <span class="pyk-spacer"></span>
          <button class="pyk-icon" data-r="modalClose"
                  title="Close (Esc)" aria-label="Close">✕</button>
        </div>
        <div class="pyk-modal-body pyk-settings-body">
          <div class="pyk-settings-column">
            <div class="pyk-field" data-r="themeField">
              <label for="pyk-theme-choice">Appearance</label>
              <select id="pyk-theme-choice" data-r="themeChoice">
                <option value="system">Same as the system</option>
                <option value="light">Light</option>
                <option value="dark">Dark</option>
              </select>
            </div>
            <div class="pyk-field">
              <label>Editor font size</label>
              <div class="pyk-field-row">
                <input type="range" min="10" max="26" step="1" data-r="fontSize"
                       aria-label="Editor font size">
                <span class="pyk-value" data-r="fontValue">13px</span>
              </div>
              <p class="pyk-hint">Applies to both editors, the output panes and the REPL.</p>
            </div>
            <div class="pyk-field">
              <label>Layout</label>
              <div class="pyk-field-row">
                <button data-r="resetLayoutButton">Reset pane sizes</button>
              </div>
              <p class="pyk-hint">Drag the bars between panes to resize them.
                Settings are remembered in this browser.</p>
            </div>
          </div>
          <div class="pyk-settings-column">
            <div class="pyk-field">
              <label>Running</label>
              <label class="pyk-check">
                <input type="checkbox" data-r="autoRun">
                Run while you type
              </label>
              <p class="pyk-hint">Runs the source about half a second after you
                stop typing, as if you had pressed Run.</p>
            </div>
            <div class="pyk-field">
              <label>Output pane</label>
              <label class="pyk-check">
                <input type="checkbox" data-r="scrollOutput">
                Scrollable
              </label>
              <label class="pyk-check">
                <input type="checkbox" data-r="clearOnRun">
                Clear it each time you press Run
              </label>
            </div>
          </div>
          <div class="pyk-settings-column">
            <div class="pyk-field">
              <label>Debugger</label>
              <label class="pyk-check">
                <input type="checkbox" data-r="debugStopOnEntry">
                Stop at the first statement
              </label>
              <label class="pyk-check">
                <input type="checkbox" data-r="debugJustMyCode">
                Step over the standard library's code
              </label>
            </div>
          </div>
          <div class="pyk-field pyk-settings-wide">
            <label>Debugger keys</label>
            <div class="pyk-key-list" data-r="debugKeyList"></div>
            <div class="pyk-field-row">
              <button data-r="debugKeysReset">Reset all the keys</button>
            </div>
            <p class="pyk-hint">Click + to add a key and press it; ✕ removes
              one. The keys act where the focus is in the editor or the
              Debug tab, and stepping's only while a program is debugged.</p>
          </div>
        </div>
      </div>
    </div>`;

  const ui = { root: host };
  for (const el of host.querySelectorAll("[data-r]")) ui[el.dataset.r] = el;
  ui.dot = host.querySelector(".pyk-dot");
  // The version of the pyk serving the page, from its manifest.
  if (meta.version) ui.version.textContent = `version ${meta.version}`;
  ui.tabs = [...host.querySelectorAll(".pyk-tab")];
  ui.panels = {
    run: ui.panelRun, compiled: ui.panelCompiled, web: ui.panelWeb, repl: ui.panelRepl,
    debug: ui.panelDebug, help: ui.panelHelp,
  };

  for (const target of meta.targets) {
    ui.target.add(new Option(`${target.label}  (${target.name})`, target.name));
  }
  ui.target.value = cfg.initialTarget;

  // The examples `pyk example` lists, in its order, each with its one
  // line as the tooltip.
  for (const entry of meta.examples) {
    const option = new Option(entry.file, entry.file);
    option.title = entry.description;
    ui.example.appendChild(option);
  }
  return ui;
}

// --------------------------------------------------------------- helpers

/** The Monaco language a target's output is shown in: Pyking's own for
 *  the `pyking` view, and otherwise the one standing for the Ace mode the
 *  manifest names. String -> String -> String */
function languageFor(target, mode) {
  if (target === "pyking") return LANGUAGE;
  return MONACO_LANGUAGES[mode] ?? "plaintext";
}

/** Switches off the features Monaco's JavaScript and HTML support runs on
 *  a worker of its own: they would lint the *generated* code, and the
 *  JavaScript one is a 7 MB download. Highlighting is not one of them.
 *  Monaco -> () */
function quietLanguageWorkers(monaco) {
  const off = {
    completionItems: false, hovers: false, documentSymbols: false,
    definitions: false, references: false, documentHighlights: false,
    rename: false, diagnostics: false, documentFormattingEdits: false,
    documentRangeFormattingEdits: false, signatureHelp: false,
    onTypeFormattingEdits: false, codeActions: false, inlayHints: false,
    links: false, colors: false, foldingRanges: false, selectionRanges: false,
  };
  const languages = monaco.languages;
  for (const defaults of [languages.typescript?.javascriptDefaults,
                          languages.typescript?.typescriptDefaults,
                          languages.html?.htmlDefaults]) {
    defaults?.setModeConfiguration?.(off);
  }
}

/** Why the Run button beside the generated pane is disabled for a target:
 *  a property of the target, not a shortcoming of the page. The `pyking`
 *  view is not code at all; the rest need a host a browser does not have. */
function whyNotRunnable(target) {
  if (target === "pyking") {
    return "the Pyking view is what the front end saw, not code to run";
  }
  const missing =
    target.startsWith("python") ? "Python interpreter"
    : target.startsWith("java") ? "JVM"
    : target.startsWith("ocaml") ? "OCaml runtime"
    : "C compiler";
  return `${target} cannot run in a browser — there is no ${missing} here.`
    + " Use Run beside the source: that runs the program itself.";
}

/* Settings live in localStorage, which is not always there to be written:
   Safari's private mode throws on write, and a sandboxed iframe throws on
   the very first access. Neither is worth breaking the playground over, so
   both read and write degrade to "no saved settings". */
function loadSettings() {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY)) || {};
  } catch {
    return {};
  }
}

function saveSettings(settings) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
  } catch {
    /* not fatal: the session simply does not outlive the tab */
  }
}
