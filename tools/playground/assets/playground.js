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
import { Debugger } from "./debugger.js";
import {
  AREAS, COMMANDS, defaultKeys, isDefault, isKey, keysOf, migrateSettings, monacoKey,
  showKey, showKeys, specOf, withKeys,
} from "./keys.js";
import { linkTo, sourceFromHash } from "./share.js";
import { packFiles, zip } from "./download.js";

const STORAGE_KEY = "pyking-playground.settings";

/** Where the playground keeps what it is in the middle of -- the program,
 *  the example and target chosen, the tab showing, the output, the input
 *  a run was given and the REPL's history -- for the rest of the browser
 *  tab's life: in sessionStorage, so going to another page of the site
 *  and back, or reloading, finds it as it was, and a new tab starts
 *  afresh. */
const STATE_KEY = "pyking-playground.state";

/** How much of the output pane is kept with the state, in characters of
 *  its HTML; more than this is not kept at all. */
const STATE_OUTPUT_LIMIT = 200000;

/** How long the state waits after a change before it is saved, in
 *  milliseconds. Leaving the page saves it at once. */
const STATE_DELAY = 300;

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
  // The debugger: whether it stops at the first statement, and whether
  // it steps over the standard library's code.
  debugStopOnEntry: false,
  debugJustMyCode: true,
  // Every command's keys where the viewer changed them (keys.js); an
  // earlier version's `debugKeys` is moved in here (`migrateSettings`).
  keys: {},
  // Copy for slides: the colours (light or dark), the font, the size in
  // points (null keeps the size of what it is pasted into), the
  // background ("none", "theme" or "#rrggbb"), which spaces are
  // non-breaking ("indent", "all" or "none"), and whether the editor has
  // a button for it -- the right-click menu and the key always do.
  slidesTheme: "light",
  slidesFont: "Menlo",
  slidesSize: null,
  slidesBackground: "none",
  slidesSpaces: "indent",
  slidesButton: false,
  // The warnings (Warnings tab): each one the viewer changed, by its
  // flag's name, as {on, error}; and whether every warning is an error,
  // as -Werror makes it.
  warnings: {},
  warningsError: false,
};

/** What the settings' Copy for slides tab previews. */
const SLIDES_SAMPLE = `def greet(name: String) -> String:
    # Say hello
    return "Hello, " + name

print(greet("world"))
`;

/** The settings dialog's tabs, in order: [name, title]. It opens on the
 *  first, as the right-hand tabs open on Run output. */
const SETTINGS_TABS = [
  ["appearance", "Appearance"], ["running", "Running"], ["warnings", "Warnings"],
  ["debugger", "Debugger"], ["slides", "Copy for slides"], ["keys", "Keys"],
];

/** How long the source has to sit still before an automatic run. Long
 *  enough to finish a word -- half-written code is mostly code that does
 *  not compile, and re-running it per keystroke would say so per keystroke. */
const AUTO_RUN_DELAY = 600;

/** What the page's frame shows before a program has drawn anything. */
const PAGE_PLACEHOLDER =
  '<p class="pyk-page-empty">A program using tinyweb draws here when you press Run.</p>';

/** What the editor starts with when there are no examples to load. */
const FALLBACK_SOURCE = `def greet(name: String) -> String:
    return "Hello, " + name

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
  // Whether what the playground is in the middle of is kept for the rest
  // of the browser tab's life, and found again when the page is opened
  // again in it (STATE_KEY).
  keepState: true,
};

export async function mountPlayground(host, options = {}) {
  const cfg = { ...DEFAULTS, ...options };
  const meta = await fetchJSON(cfg.base + "/playground.json");
  const runtime = createRuntime({ webrun: cfg.webrunURL, pyking: cfg.pykingURL });
  // The editor's highlighting reads the keywords out of the compiler, so
  // the compiler is loaded before the editors are made.
  const { words, monaco } = await ensureMonaco(runtime, { vendor: cfg.vendorURL });
  meta.formatHelper = words.formatHelper;
  meta.warnings = words.warnings ?? [];
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
    const saved = loadSettings();
    this.settings = { ...DEFAULT_SETTINGS, ...migrateSettings(saved) };
    // Settings saved by an earlier version are saved again as this one
    // writes them.
    this.migrated = saved && typeof saved === "object" && "debugKeys" in saved;
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
    ui.copySlides.addEventListener("click", () => this.copyForSlides());
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

    // Keyboard shortcuts: Run's and Copy for slides', each editor's
    // actions (`installEditorKeys`), with the keys the settings give them.
    this.editorActions = [];
    this.installEditorKeys();

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

    // Run's keys when focus is outside both editors -- on a dropdown, a
    // button, or the page itself. Monaco stops propagation for keys it
    // handled, but the check for an enclosing editor is explicit so that a
    // future Monaco that stops doing so cannot make this fire twice.
    ui.root.addEventListener("keydown", (event) => {
      if (event.target === ui.replInput) return;
      if (event.key === "Escape" && !ui.modal.classList.contains("pyk-hidden")) {
        this.closeSettings();
        return;
      }
      if (!ui.modal.classList.contains("pyk-hidden")) return;
      if (!ui.inputModal.classList.contains("pyk-hidden")) return;
      if (event.target?.closest?.(".monaco-editor")) return;
      if (!isKey(this.settings, "run", event)) return;
      event.preventDefault();
      if (this.running) this.stopRun();
      else this.runFromSource();
    });

    // No src/examples.toml beside the tools: nothing to offer.
    if (!this.meta.examples.length) ui.example.classList.add("pyk-hidden");
    const linked = this.cfg.readLink ? sourceFromHash(location.hash) : null;
    // What the playground was in the middle of when this browser tab left
    // it -- for another page of the site, say -- unless a link brings a
    // program of its own.
    const kept = this.cfg.keepState && linked === null ? loadState() : null;
    if (linked !== null) {
      this.openLinked(linked);
    } else if (kept) {
      this.restoreState(kept);
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
    if (kept) this.restoreTab(kept);
    if (this.cfg.keepState) this.keepStateUpdated();
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
    if (!kept) {
      this.note("Press Run to run the program. Compiled code compiles it for a "
                + "target, and the REPL runs Pyking an entry at a time.");
    }
  }

  // -- the state kept while the browser tab lives -------------------------

  /** What the playground is in the middle of, as STATE_KEY keeps it.
   *  () -> {...} */
  captureState() {
    const { ui } = this;
    const output = ui.output.innerHTML;
    return {
      source: this.left.getValue(),
      example: ui.example.value,
      target: ui.target.value,
      tab: this.tab,
      view: this.left.saveViewState(),
      output: output.length <= STATE_OUTPUT_LIMIT ? output : "",
      input: this.input,
      replHistory: this.replHistory.slice(-200),
    };
  }

  /** Puts back what `captureState` kept: the program, where the editor
   *  was in it, the example and target chosen, the output, the input and
   *  the REPL's history. The tab is shown once the page is ready
   *  (`restoreTab`). {...} -> () */
  restoreState(kept) {
    const { ui } = this;
    this.setSource(typeof kept.source === "string" ? kept.source : "");
    if (kept.view) {
      try {
        this.left.restoreViewState(kept.view);
      } catch {
        /* a view of another Monaco: the start of the program will do */
      }
    }
    const offered = (select, value) => [...select.options].some((o) => o.value === value);
    ui.example.value = offered(ui.example, kept.example) ? kept.example : "";
    if (offered(ui.target, kept.target)) ui.target.value = kept.target;
    if (typeof kept.output === "string") ui.output.innerHTML = kept.output;
    if (kept.input && typeof kept.input.stdin === "string" && typeof kept.input.args === "string") {
      this.input = { stdin: kept.input.stdin, args: kept.input.args };
    }
    if (Array.isArray(kept.replHistory)) {
      this.replHistory = kept.replHistory.filter((entry) => typeof entry === "string");
      this.replAt = this.replHistory.length;
    }
  }

  /** Shows the tab that was showing, unless it showed something that
   *  ended with the page -- a program's page, a debugged program -- when
   *  the Run output tab stands for it. {...} -> () */
  restoreTab(kept) {
    const tab = ["compiled", "repl", "help"].includes(kept.tab) ? kept.tab : "run";
    if (tab !== this.tab) this.showTab(tab);
  }

  /** Saves the state whenever it changes, a moment later, and at once when
   *  the page is left or hidden. () -> () */
  keepStateUpdated() {
    const save = () => {
      clearTimeout(this.stateTimer);
      this.stateTimer = null;
      saveState(this.captureState());
    };
    this.saveStateSoon = () => {
      clearTimeout(this.stateTimer);
      this.stateTimer = setTimeout(save, STATE_DELAY);
    };
    this.left.onDidChangeModelContent(() => this.saveStateSoon());
    this.left.onDidChangeCursorPosition(() => this.saveStateSoon());
    this.ui.target.addEventListener("change", () => this.saveStateSoon());
    this.ui.example.addEventListener("change", () => this.saveStateSoon());
    new MutationObserver(() => this.saveStateSoon())
      .observe(this.ui.output, { childList: true, characterData: true, subtree: true });
    window.addEventListener("pagehide", save);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "hidden") save();
    });
    save();
  }

  // -- the editors' keys ------------------------------------------------

  /** Run's keys and Copy for slides', as each editor's actions, made
   *  again whenever the settings change them. An action rather than a
   *  key listener on the container, because Monaco handles keys on its
   *  own hidden textarea first: a listener would not run until Monaco
   *  had already typed the newline Shift+Enter would otherwise type. An
   *  action's keys belong to its own editor. Run means the Run button of
   *  whichever editor has the focus -- the source's runs the program, the
   *  generated code's what it shows -- and stops what runs; Copy for
   *  slides is the source's, in its right-click menu beside Copy.
   *  () -> () */
  installEditorKeys() {
    for (const action of this.editorActions) action.dispose();
    const keys = (id) => keysOf(this.settings, id)
      .map((spec) => monacoKey(this.monaco, spec)).filter((k) => k !== null);
    const run = keys("run");
    this.editorActions = [
      this.left.addAction({
        id: "pyk-run", label: "Run the program", keybindings: run,
        run: () => { this.running ? this.stopRun() : this.runFromSource(); },
      }),
      this.right.addAction({
        id: "pyk-run", label: "Run the generated code", keybindings: run,
        run: () => { this.running ? this.stopRun() : this.runGenerated(); },
      }),
      this.left.addAction({
        id: "pyk-copy-slides", label: "Copy for Slides", keybindings: keys("copySlides"),
        contextMenuGroupId: "9_cutcopypaste", contextMenuOrder: 2.5,
        run: () => { this.copyForSlides(); },
      }),
    ];
    this.showCommandKeys();
  }

  /** Each control's tooltip, naming its command's keys as they are now.
   *  () -> () */
  showCommandKeys() {
    const { ui } = this;
    ui.runLeft.title = `Run the program itself (${showKeys(keysOf(this.settings, "run"))})`;
    ui.copySlides.title = "Copy the selection, or the whole program, coloured for slides "
      + `(${showKeys(keysOf(this.settings, "copySlides"))})`;
    this.updateRunButtons();
    this.debugger?.showKeys();
  }

  // -- Copy for slides ---------------------------------------------------

  /** The options Copy for slides gives the highlighter, from the
   *  settings (`PykingRuntime.highlight`). () -> Object */
  slidesOptions() {
    const s = this.settings;
    const size = Number(s.slidesSize);
    return {
      theme: s.slidesTheme === "dark" ? "dark" : "light",
      font: (s.slidesFont ?? "").trim() || "Menlo",
      size: s.slidesSize === null || s.slidesSize === "" || !(size > 0) ? null : Math.round(size),
      background: s.slidesBackground || "none",
      spaces: ["indent", "all", "none"].includes(s.slidesSpaces) ? s.slidesSpaces : "indent",
    };
  }

  /** The source's selection, or the whole program where nothing is
   *  selected, highlighted: {html, rtf, text, what}. () -> Promise<Object> */
  async highlightForSlides(source, options) {
    if (!(await this.ensureRuntime())) throw new Error("the compiler did not start");
    if (typeof this.runtime.highlight !== "function") {
      throw new Error("this compiler has no highlighter");
    }
    return this.runtime.highlight(source, options);
  }

  /** Copy for slides: the editor's selection, or the whole program where
   *  nothing is selected, onto the clipboard twice over -- as HTML with
   *  the colours, the font and the size inline, which Keynote, PowerPoint
   *  and Google Slides paste as coloured text, and as plain text -- with
   *  the spaces the settings say made non-breaking, so the indentation
   *  survives a PDF reader's copy. The status line says what was copied.
   *  The clipboard is written at once, with the highlighting to follow,
   *  as Safari requires within the key press or click.
   *  () -> Promise<Bool> */
  async copyForSlides() {
    const model = this.left.getModel();
    const selection = this.left.getSelection();
    const marked = Boolean(selection && !selection.isEmpty());
    const source = marked ? model.getValueInRange(selection) : model.getValue();
    const lines = source.replace(/\n$/, "").split("\n").length;
    const what = `${marked ? "the selection" : "the program"} (${lines} line${lines === 1 ? "" : "s"})`;
    const made = this.highlightForSlides(source, this.slidesOptions());
    made.catch(() => {});
    const blob = (type, key) => {
      const promised = made.then((r) => new Blob([r[key]], { type }));
      promised.catch(() => {});   // reported below, from `made`
      return promised;
    };
    let copied = false;
    if (globalThis.ClipboardItem && navigator.clipboard?.write) {
      try {
        await navigator.clipboard.write([new ClipboardItem({
          "text/html": blob("text/html", "html"), "text/plain": blob("text/plain", "text"),
        })]);
        copied = true;
      } catch { /* a browser taking no promises, or refusing: below */ }
    }
    let result;
    try {
      result = await made;
    } catch (err) {
      this.status("error", "Copy for slides failed");
      this.error("Copy for slides: " + err.message);
      return false;
    }
    if (!copied && globalThis.ClipboardItem && navigator.clipboard?.write) {
      try {
        await navigator.clipboard.write([new ClipboardItem({
          "text/html": new Blob([result.html], { type: "text/html" }),
          "text/plain": new Blob([result.text], { type: "text/plain" }),
        })]);
        copied = true;
      } catch { /* below */ }
    }
    // Where there is no ClipboardItem: the copy a key press makes, with
    // both kinds of text put on it.
    if (!copied) copied = copyByEvent({ "text/html": result.html, "text/plain": result.text });
    if (!copied) {
      this.status("error", "the browser refused the clipboard");
      this.error("Copy for slides: the browser refused clipboard access.");
      return false;
    }
    this.status("ready", `copied ${what} for slides`);
    return true;
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
    const warned = [];
    const result = await this.runtime.compile(source, target, "playground.pyk", {
      onWarning: (text) => warned.push(text),
    });
    this.clearError();
    const log = this.ui.compiledOutput;
    for (const text of warned) this.write(text, "warn", log);

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
      : `Run the generated ${target} code (${showKeys(keysOf(this.settings, "run"))})`;
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
    this.saveStateSoon?.();
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
    this.saveStateSoon?.();
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
        onWarning: (text) => this.write(text, "warn"),
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
      if (!isKey(this.settings, "repl.complete", event) && event.key !== "Shift") {
        this.hideReplCompletions();
      }
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
        this.replRuntime.setWarnings(this.warningFlags());
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

  /** What a key does in the prompt: submit (Enter), a new line
   *  (Shift+Enter), complete (Tab: an indent at the start of a line, a
   *  completion after a word), the entries before and after (Up on the
   *  first line, Down on the last) -- each the keys the settings give it
   *  (keys.js) -- and Backspace in the indentation and Escape.
   *  KeyboardEvent -> () */
  replKey(event) {
    const input = this.ui.replInput;
    const { value, selectionStart: at, selectionEnd } = input;
    const before = value.slice(0, at);
    const onFirstLine = !before.includes("\n");
    const onLastLine = !value.slice(at).includes("\n");
    const is = (id) => isKey(this.settings, "repl." + id, event);
    if (is("submit")) {
      event.preventDefault();
      if (this.replBusy) return;
      this.replEnter();
    } else if (is("newline")) {
      event.preventDefault();
      if (this.replBusy) return;
      this.replNewline();
    } else if (is("complete")) {
      event.preventDefault();
      const line = before.slice(before.lastIndexOf("\n") + 1);
      if (line.trim() === "" || at !== selectionEnd) {
        input.setRangeText("    ", at, selectionEnd, "end");
        this.fitReplInput();
      } else {
        this.replTab();
      }
    } else if (is("previous") && onFirstLine && this.replAt > 0) {
      event.preventDefault();
      if (this.replAt === this.replHistory.length) this.replDraft = value;
      this.replAt -= 1;
      this.setReplInput(this.replHistory[this.replAt]);
    } else if (is("next") && onLastLine && this.replAt < this.replHistory.length) {
      event.preventDefault();
      this.replAt += 1;
      this.setReplInput(this.replAt === this.replHistory.length
        ? this.replDraft : this.replHistory[this.replAt]);
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
      this.saveStateSoon?.();
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
      for (const warning of answer.warnings ?? []) this.replWrite(warning + "\n", "warn");
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
    const { ui } = this;
    const { settingsButton, modal, modalClose, fontSize } = ui;
    settingsButton.addEventListener("click", () => this.openSettings());
    modalClose.addEventListener("click", () => this.closeSettings());
    // Only a click on the backdrop itself closes; one inside the dialog
    // bubbles to here too and must not.
    modal.addEventListener("click", (e) => {
      if (e.target === modal) this.closeSettings();
    });
    this.installSettingsTabs();
    fontSize.addEventListener("input", () => {
      this.applyFontSize(Number(fontSize.value));
      this.saveSettings();
    });
    ui.autoRun.addEventListener("change", () => {
      this.settings.autoRun = ui.autoRun.checked;
      // Switching it off must also drop an edit already waiting to run;
      // switching it on does not run anything until the next keystroke, so
      // ticking a box never starts a download on its own.
      if (!this.settings.autoRun) this.cancelAutoRun();
      this.saveSettings();
    });
    ui.scrollOutput.addEventListener("change", () => {
      this.settings.scrollOutput = ui.scrollOutput.checked;
      this.applyOutputScroll();
      this.saveSettings();
    });
    ui.clearOnRun.addEventListener("change", () => {
      this.settings.clearOnRun = ui.clearOnRun.checked;
      this.saveSettings();
    });
    // The tinyweb log has two switches, the Web output tab's and the
    // settings', which follow each other.
    for (const box of [ui.tinywebLog, ui.tinywebLogSetting]) {
      box.addEventListener("change", () => {
        this.settings.tinywebLog = box.checked;
        ui.tinywebLog.checked = ui.tinywebLogSetting.checked = box.checked;
        // A program already running starts or stops logging at once.
        this.runtime?.setTinywebLog?.(this.settings.tinywebLog);
        this.saveSettings();
      });
    }
    ui.resetLayoutButton.addEventListener("click", () => this.resetLayout());
    ui.debugStopOnEntry.addEventListener("change", () => {
      this.settings.debugStopOnEntry = ui.debugStopOnEntry.checked;
      this.saveSettings();
    });
    ui.debugJustMyCode.addEventListener("change", () => {
      this.settings.debugJustMyCode = ui.debugJustMyCode.checked;
      this.saveSettings();
    });
    this.installWarningSettings();
    this.installSlidesSettings();
    ui.keysReset.addEventListener("click", () => {
      this.settings.keys = {};
      this.keysChanged();
    });
    this.showKeySettings();
  }

  // -- warnings ---------------------------------------------------------

  /** Whether a warning is on, as the settings have it: what the viewer
   *  chose, or its default. {name, on} -> Bool */
  warningOn(kind) {
    return this.settings.warnings[kind.name]?.on ?? kind.on;
  }

  /** Whether a warning is an error, as the settings have it.
   *  {name} -> Bool */
  warningError(kind) {
    return this.settings.warningsError || Boolean(this.settings.warnings[kind.name]?.error);
  }

  /** The -W flags the settings stand for, as `pyk` takes them: each
   *  warning turned on or off against its default, then -Werror, or each
   *  warning made an error by itself. () -> [String] */
  warningFlags() {
    const kinds = this.meta.warnings ?? [];
    const flags = [];
    for (const kind of kinds) {
      const on = this.warningOn(kind);
      if (on !== kind.on) flags.push((on ? "-W" : "-Wno-") + kind.name);
    }
    if (this.settings.warningsError) flags.push("-Werror");
    else {
      for (const kind of kinds) {
        if (this.settings.warnings[kind.name]?.error) flags.push("-Werror=" + kind.name);
      }
    }
    return flags;
  }

  /** Hands the settings' warnings to every runtime -- the Run's, whose
   *  language server underlines them, and the REPL's -- and asks the
   *  server for the diagnostics again. () -> () */
  applyWarnings() {
    const flags = this.warningFlags();
    this.runtime.setWarnings(flags);
    this.replRuntime?.setWarnings(flags);
    this.lsp?.scheduleIdle();
    this.showWarningSettings();
  }

  /** One warning changed: saved, and in force at once.
   *  String -> {on?, error?} -> () */
  setWarning(name, change) {
    this.settings.warnings = {
      ...this.settings.warnings, [name]: { ...this.settings.warnings[name], ...change },
    };
    this.saveSettings();
    this.applyWarnings();
  }

  /** The Warnings tab's buttons and its -Werror box. () -> () */
  installWarningSettings() {
    const { ui } = this;
    const every = (on) => {
      this.settings.warnings = Object.fromEntries((this.meta.warnings ?? []).map(
        (kind) => [kind.name, { ...this.settings.warnings[kind.name], on }]));
      this.saveSettings();
      this.applyWarnings();
    };
    ui.warningsAll.addEventListener("click", () => every(true));
    ui.warningsNone.addEventListener("click", () => every(false));
    ui.warningsDefaults.addEventListener("click", () => {
      this.settings.warnings = {};
      this.settings.warningsError = false;
      this.saveSettings();
      this.applyWarnings();
    });
    ui.warningsError.addEventListener("change", () => {
      this.settings.warningsError = ui.warningsError.checked;
      this.saveSettings();
      this.applyWarnings();
    });
  }

  /** The Warnings tab as the settings have it: a row per warning, with
   *  whether it is on, its flag, whether it is an error, and what it
   *  reports; and the command line that says the same. () -> () */
  showWarningSettings() {
    const { ui } = this;
    if (!ui.warningList) return;
    ui.warningList.textContent = "";
    for (const kind of this.meta.warnings ?? []) {
      const row = document.createElement("div");
      row.className = "pyk-warning";
      const on = document.createElement("input");
      on.type = "checkbox";
      on.checked = this.warningOn(kind);
      on.id = `pyk-warning-${kind.name}`;
      on.addEventListener("change", () => this.setWarning(kind.name, { on: on.checked }));
      const label = document.createElement("label");
      label.htmlFor = on.id;
      label.className = "pyk-warning-flag";
      const flag = document.createElement("code");
      flag.textContent = "-W" + kind.name;
      label.append(flag, kind.on ? " on by default" : " off by default");
      const error = document.createElement("label");
      error.className = "pyk-check pyk-warning-error";
      const box = document.createElement("input");
      box.type = "checkbox";
      box.checked = this.warningError(kind);
      box.disabled = this.settings.warningsError;
      box.addEventListener("change", () => this.setWarning(kind.name, { error: box.checked }));
      const errorFlag = document.createElement("code");
      errorFlag.textContent = "-Werror=" + kind.name;
      error.append(box, " as an error ", errorFlag);
      const says = document.createElement("p");
      says.className = "pyk-hint";
      says.textContent = kind.description;
      row.append(on, label, error, says);
      ui.warningList.appendChild(row);
    }
    ui.warningsError.checked = this.settings.warningsError;
    const flags = this.warningFlags();
    ui.warningCommand.textContent = ["pyk", ...flags, "playground.pyk"].join(" ");
  }

  /** The settings' tabs: a click, or the arrow keys, Home and End on the
   *  tab that has the focus, shows another. () -> () */
  installSettingsTabs() {
    const { ui } = this;
    ui.settingsTabButtons = [...ui.settingsTabs.querySelectorAll("[role=tab]")];
    for (const tab of ui.settingsTabButtons) {
      tab.addEventListener("click", () => this.showSettingsTab(tab.dataset.settingsTab));
      tab.addEventListener("keydown", (event) => {
        const tabs = ui.settingsTabButtons.filter((t) => !t.classList.contains("pyk-hidden"));
        const at = tabs.indexOf(tab);
        const to = { ArrowRight: at + 1, ArrowLeft: at - 1, ArrowDown: at + 1, ArrowUp: at - 1,
                     Home: 0, End: tabs.length - 1 }[event.key];
        if (to === undefined) return;
        event.preventDefault();
        const next = tabs[(to + tabs.length) % tabs.length];
        this.showSettingsTab(next.dataset.settingsTab);
        next.focus();
      });
    }
    this.showSettingsTab("appearance");
  }

  /** Shows one of the settings' tabs. String -> () */
  showSettingsTab(name) {
    const { ui } = this;
    this.settingsTab = name;
    for (const tab of ui.settingsTabButtons) {
      const on = tab.dataset.settingsTab === name;
      tab.setAttribute("aria-selected", String(on));
      tab.tabIndex = on ? 0 : -1;
      tab.classList.toggle("active", on);
    }
    for (const panel of ui.modal.querySelectorAll("[data-settings-panel]")) {
      panel.classList.toggle("pyk-hidden", panel.dataset.settingsPanel !== name);
    }
    if (name === "slides") this.previewSlides();
  }

  /** The Copy for slides tab: each option saved as it changes, and the
   *  preview drawn again. () -> () */
  installSlidesSettings() {
    const { ui } = this;
    const changed = () => {
      this.saveSettings();
      this.previewSlides();
    };
    ui.slidesTheme.addEventListener("change", () => {
      this.settings.slidesTheme = ui.slidesTheme.value;
      changed();
    });
    ui.slidesFont.addEventListener("input", () => {
      this.settings.slidesFont = ui.slidesFont.value;
      changed();
    });
    ui.slidesSize.addEventListener("input", () => {
      const size = Number(ui.slidesSize.value);
      this.settings.slidesSize = ui.slidesSize.value.trim() === "" || !(size > 0) ? null : size;
      changed();
    });
    const background = () => {
      const kind = ui.slidesBackgroundKind.value;
      ui.slidesColor.classList.toggle("pyk-hidden", kind !== "custom");
      this.settings.slidesBackground = kind === "custom" ? ui.slidesColor.value : kind;
      changed();
    };
    ui.slidesBackgroundKind.addEventListener("change", background);
    ui.slidesColor.addEventListener("input", background);
    ui.slidesSpaces.addEventListener("change", () => {
      this.settings.slidesSpaces = ui.slidesSpaces.value;
      changed();
    });
    ui.slidesButton.addEventListener("change", () => {
      this.settings.slidesButton = ui.slidesButton.checked;
      this.applySlidesSettings();
      this.saveSettings();
    });
  }

  /** The Copy for slides tab and the editor's button as the settings
   *  have them. () -> () */
  applySlidesSettings() {
    const { ui, settings } = this;
    ui.slidesTheme.value = settings.slidesTheme === "dark" ? "dark" : "light";
    ui.slidesFont.value = settings.slidesFont ?? "";
    ui.slidesSize.value = settings.slidesSize === null || settings.slidesSize === undefined
      ? "" : String(settings.slidesSize);
    const background = settings.slidesBackground || "none";
    const custom = /^#[0-9a-f]{6}$/i.test(background);
    ui.slidesBackgroundKind.value = custom ? "custom" : background === "theme" ? "theme" : "none";
    if (custom) ui.slidesColor.value = background.toLowerCase();
    ui.slidesColor.classList.toggle("pyk-hidden", !custom);
    ui.slidesSpaces.value = ["indent", "all", "none"].includes(settings.slidesSpaces)
      ? settings.slidesSpaces : "indent";
    ui.slidesButton.checked = Boolean(settings.slidesButton);
    ui.copySlides.classList.toggle("pyk-hidden", !settings.slidesButton);
  }

  /** Draws the settings' preview of Copy for slides: the sample as it
   *  would be pasted, the latest options winning. () -> Promise<()> */
  async previewSlides() {
    const box = this.ui.slidesPreview;
    const asked = (this.previewAsked ?? 0) + 1;
    this.previewAsked = asked;
    try {
      const { html } = await this.highlightForSlides(SLIDES_SAMPLE, this.slidesOptions());
      if (this.previewAsked !== asked) return;
      box.innerHTML = html;
      box.classList.remove("pyk-slides-unavailable");
      box.classList.toggle("pyk-slides-dark", this.slidesOptions().theme === "dark");
    } catch (err) {
      if (this.previewAsked !== asked) return;
      box.textContent = "No preview: " + err.message + ".";
      box.classList.add("pyk-slides-unavailable");
    }
  }

  /** The keys changed: saved, and shown in the settings, the tooltips and
   *  the editors' actions. () -> () */
  keysChanged() {
    this.saveSettings();
    this.installEditorKeys();
    this.showKeySettings();
  }

  /** The settings' Keys tab: every command, by area, with a chip for each
   *  of its keys with ✕ to remove it, + to record one more (Escape leaves
   *  it), and reset for the command's defaults. () -> () */
  showKeySettings() {
    const { ui } = this;
    const list = ui.keyList;
    list.textContent = "";
    const save = (id, specs) => {
      this.settings = withKeys(this.settings, id, specs);
      this.keysChanged();
      // The focus stays on the row, for a keyboard user.
      list.querySelector(`.pyk-key-row[data-command="${id}"] .pyk-key-add`)?.focus();
    };
    const button = (text, title, onClick) => {
      const b = document.createElement("button");
      b.type = "button";
      b.textContent = text;
      b.title = title;
      b.setAttribute("aria-label", title);
      b.addEventListener("click", onClick);
      return b;
    };
    for (const area of AREAS) {
      const group = document.createElement("div");
      group.className = "pyk-key-group";
      group.setAttribute("role", "group");
      const heading = document.createElement("div");
      heading.className = "pyk-key-area";
      heading.id = `pyk-key-area-${area.toLowerCase()}`;
      heading.textContent = area;
      group.setAttribute("aria-labelledby", heading.id);
      group.append(heading);
      for (const { id, label } of COMMANDS.filter((c) => c.area === area)) {
        const specs = keysOf(this.settings, id);
        const row = document.createElement("div");
        row.className = "pyk-key-row";
        row.dataset.command = id;
        const name = document.createElement("span");
        name.className = "pyk-key-name";
        name.textContent = label;
        const chips = document.createElement("span");
        chips.className = "pyk-key-chips";
        for (const spec of specs) {
          const chip = document.createElement("span");
          chip.className = "pyk-key-chip";
          chip.dataset.spec = spec;
          chip.textContent = showKey(spec);
          chip.append(button("✕", `${label}: remove ${showKey(spec)}`,
            () => save(id, specs.filter((k) => k !== spec))));
          chips.append(chip);
        }
        const add = button("+", `${label}: add a key -- click, then press it`, () => {
          const field = document.createElement("input");
          field.type = "text";
          field.readOnly = true;
          field.className = "pyk-key-field";
          field.placeholder = "press a key";
          field.setAttribute("aria-label", `${label}: press the key to add`);
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
            save(id, specs.includes(spec) ? specs : [...specs, spec]);
          });
          field.addEventListener("blur", () => {
            if (field.isConnected) field.replaceWith(add);
          });
          add.replaceWith(field);
          field.focus();
        });
        add.className = "pyk-key-add";
        chips.append(add);
        const reset = button("reset", `${label}: its default keys, ${showKeys(defaultKeys(id))}`,
          () => save(id, defaultKeys(id)));
        reset.className = "pyk-key-reset";
        reset.disabled = isDefault(this.settings, id);
        row.append(name, chips, reset);
        group.append(row);
      }
      list.append(group);
    }
    ui.keysReset.disabled = Object.keys(this.settings.keys ?? {}).length === 0;
    ui.slidesKeyHint.textContent = showKeys(keysOf(this.settings, "copySlides"));
  }

  /** Opens the settings, on their first tab. () -> () */
  openSettings() {
    this.ui.modal.classList.remove("pyk-hidden");
    this.showSettingsTab("appearance");
    this.ui.settingsTabButtons[0].focus();
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
    this.ui.tinywebLogSetting.checked = this.settings.tinywebLog;
    this.ui.debugStopOnEntry.checked = Boolean(this.settings.debugStopOnEntry);
    this.ui.debugJustMyCode.checked = this.settings.debugJustMyCode !== false;
    this.applySlidesSettings();
    this.applyWarnings();
    for (const [key, name] of [["colSplit", "--pyk-col-split"],
                               ["outSplit", "--pyk-out-split"]]) {
      if (this.settings[key]) this.ui.root.style.setProperty(name, this.settings[key]);
    }
    if (this.migrated) this.saveSettings();
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
      keys: this.settings.keys,
      slidesTheme: this.settings.slidesTheme,
      slidesFont: this.settings.slidesFont,
      slidesSize: this.settings.slidesSize,
      slidesBackground: this.settings.slidesBackground,
      slidesSpaces: this.settings.slidesSpaces,
      slidesButton: this.settings.slidesButton,
      warnings: this.settings.warnings,
      warningsError: this.settings.warningsError,
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
          <button class="pyk-hidden" data-r="copySlides">Copy for slides</button>
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
      <div class="pyk-modal pyk-modal-wide pyk-settings-dialog" role="dialog" aria-modal="true"
           aria-labelledby="pyk-settings-title">
        <div class="pyk-modal-head">
          <strong id="pyk-settings-title">Settings</strong>
          <span class="pyk-spacer"></span>
          <button class="pyk-icon" data-r="modalClose"
                  title="Close (Esc)" aria-label="Close">✕</button>
        </div>
        <div class="pyk-settings-tabs" role="tablist" aria-label="Settings" data-r="settingsTabs">
          ${SETTINGS_TABS.map(([name, title]) => `
          <button type="button" role="tab" class="pyk-settings-tab" data-settings-tab="${name}"
                  id="pyk-settings-tab-${name}" aria-controls="pyk-settings-${name}"
                  aria-selected="false" tabindex="-1">${title}</button>`).join("")}
        </div>
        <div class="pyk-modal-body pyk-settings-body">
          <div class="pyk-settings-panel" role="tabpanel" data-settings-panel="appearance"
               id="pyk-settings-appearance" aria-labelledby="pyk-settings-tab-appearance">
            <div class="pyk-field" data-r="themeField">
              <label for="pyk-theme-choice">Theme</label>
              <select id="pyk-theme-choice" data-r="themeChoice">
                <option value="system">Same as the system</option>
                <option value="light">Light</option>
                <option value="dark">Dark</option>
              </select>
              <p class="pyk-hint">The ☀/☾ button in the header switches between
                light and dark too.</p>
            </div>
            <div class="pyk-field">
              <label for="pyk-font-size">Editor font size</label>
              <div class="pyk-field-row">
                <input type="range" min="10" max="26" step="1" data-r="fontSize"
                       id="pyk-font-size">
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
          <div class="pyk-settings-panel pyk-hidden" role="tabpanel" data-settings-panel="running"
               id="pyk-settings-running" aria-labelledby="pyk-settings-tab-running">
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
                <input type="checkbox" data-r="clearOnRun">
                Clear it each time you press Run
              </label>
              <label class="pyk-check">
                <input type="checkbox" data-r="scrollOutput">
                Scrollable
              </label>
            </div>
            <div class="pyk-field">
              <label>Web output</label>
              <label class="pyk-check">
                <input type="checkbox" data-r="tinywebLogSetting">
                tinyweb log
              </label>
              <p class="pyk-hint">Shows what a tinyweb program sends its page, and
                what the page answers, as pyk --tinyweb-log does. The Web output
                tab has the same switch.</p>
            </div>
          </div>
          <div class="pyk-settings-panel pyk-hidden pyk-warnings-panel" role="tabpanel"
               data-settings-panel="warnings"
               id="pyk-settings-warnings" aria-labelledby="pyk-settings-tab-warnings">
            <p class="pyk-hint pyk-wide">What the compiler reports about a program that
              checks but may still be wrong: a name bound and never used. A warning
              is shown in the output and under the source, and the program still
              runs; one made an error stops it, as <code>pyk -Werror</code> does. A
              name starting with <code>_</code> is never reported. Each flag is the
              one <code>pyk</code> takes.</p>
            <div class="pyk-warning-list pyk-wide" data-r="warningList"></div>
            <div class="pyk-field pyk-wide">
              <label class="pyk-check">
                <input type="checkbox" data-r="warningsError">
                Every warning that is on is an error <code>-Werror</code>
              </label>
              <div class="pyk-field-row">
                <button data-r="warningsAll">Turn them all on <code>-Wall</code></button>
                <button data-r="warningsNone">Turn them all off <code>-w</code></button>
                <button data-r="warningsDefaults">Back to the defaults</button>
              </div>
              <p class="pyk-hint">On the command line, the same is
                <code data-r="warningCommand"></code></p>
            </div>
          </div>
          <div class="pyk-settings-panel pyk-hidden" role="tabpanel" data-settings-panel="debugger"
               id="pyk-settings-debugger" aria-labelledby="pyk-settings-tab-debugger">
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
              <p class="pyk-hint">With no breakpoint set, Debug stops at the first
                statement anyway. The debugger's keys are on the Keys tab.</p>
            </div>
          </div>
          <div class="pyk-settings-panel pyk-hidden pyk-slides-panel" role="tabpanel"
               data-settings-panel="slides"
               id="pyk-settings-slides" aria-labelledby="pyk-settings-tab-slides">
            <p class="pyk-hint pyk-wide">Copy for slides copies the selection, or the whole
              program where nothing is selected, as coloured text to paste into
              Keynote, PowerPoint or Google Slides: from the editor's right-click
              menu, or with <span data-r="slidesKeyHint"></span>.</p>
            <div class="pyk-field">
              <label for="pyk-slides-theme">Colours</label>
              <select id="pyk-slides-theme" data-r="slidesTheme">
                <option value="light">Light: for a light slide</option>
                <option value="dark">Dark: for a dark slide</option>
              </select>
            </div>
            <div class="pyk-field">
              <label for="pyk-slides-font">Font</label>
              <input type="text" id="pyk-slides-font" class="pyk-input-line" data-r="slidesFont"
                     list="pyk-slides-fonts" spellcheck="false" placeholder="Menlo">
              <datalist id="pyk-slides-fonts">
                <option value="Menlo"></option><option value="Monaco"></option>
                <option value="SF Mono"></option><option value="Courier New"></option>
                <option value="Consolas"></option><option value="Fira Code"></option>
                <option value="JetBrains Mono"></option><option value="Source Code Pro"></option>
              </datalist>
            </div>
            <div class="pyk-field">
              <label for="pyk-slides-size">Size in points</label>
              <input type="number" id="pyk-slides-size" class="pyk-input-line" data-r="slidesSize"
                     min="4" max="200" step="1" placeholder="keep the slide's">
              <p class="pyk-hint">Blank keeps the size of the text it is pasted into.</p>
            </div>
            <div class="pyk-field">
              <label for="pyk-slides-background">Background</label>
              <div class="pyk-field-row">
                <select id="pyk-slides-background" data-r="slidesBackgroundKind">
                  <option value="none">None: the slide's own</option>
                  <option value="theme">The colours' background</option>
                  <option value="custom">A colour of my choice</option>
                </select>
                <input type="color" data-r="slidesColor" value="#ffffff"
                       aria-label="Background colour" class="pyk-hidden">
              </div>
            </div>
            <div class="pyk-field">
              <label for="pyk-slides-spaces">Spaces</label>
              <select id="pyk-slides-spaces" data-r="slidesSpaces">
                <option value="indent">Non-breaking for the indentation</option>
                <option value="all">Non-breaking everywhere</option>
                <option value="none">Plain spaces</option>
              </select>
              <p class="pyk-hint">A PDF reader drops the spaces that start a line
                when its text is copied; non-breaking ones are kept, so code copied
                out of an exported slide still runs.</p>
            </div>
            <div class="pyk-field">
              <label>Editor</label>
              <label class="pyk-check">
                <input type="checkbox" data-r="slidesButton">
                Show a Copy for slides button above the editor
              </label>
            </div>
            <div class="pyk-field pyk-wide">
              <label>Preview</label>
              <div class="pyk-slides-preview" data-r="slidesPreview" aria-live="polite"></div>
            </div>
          </div>
          <div class="pyk-settings-panel pyk-hidden" role="tabpanel" data-settings-panel="keys"
               id="pyk-settings-keys" aria-labelledby="pyk-settings-tab-keys">
            <div class="pyk-key-list" data-r="keyList"></div>
            <div class="pyk-field-row">
              <button data-r="keysReset">Reset all the keys</button>
            </div>
            <p class="pyk-hint">Click + to add a key and press it (Escape leaves it);
              ✕ removes one. Run and Copy for slides act in the editor, Run also
              outside both editors; the debugger's start, continue and step keys act
              anywhere in the playground, its others in the editor or the Debug tab;
              the REPL's in its prompt.</p>
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

/** Puts each kind of text on the clipboard by the copy a key press
 *  makes, for a browser without ClipboardItem. Answers whether the copy
 *  happened. {type: String} -> Bool */
function copyByEvent(data) {
  let done = false;
  const listener = (event) => {
    if (!event.clipboardData) return;
    for (const [type, text] of Object.entries(data)) event.clipboardData.setData(type, text);
    event.preventDefault();
    // Monaco's own copy, of the cursor's line, is not to replace it.
    event.stopImmediatePropagation();
    done = true;
  };
  document.addEventListener("copy", listener, true);
  try {
    document.execCommand("copy");
  } catch {
    /* refused: done stays false */
  } finally {
    document.removeEventListener("copy", listener, true);
  }
  return done;
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

/** What STATE_KEY holds for this browser tab, or null. () -> {...}? */
function loadState() {
  try {
    const kept = JSON.parse(sessionStorage.getItem(STATE_KEY));
    return kept && typeof kept === "object" && typeof kept.source === "string" ? kept : null;
  } catch {
    return null;
  }
}

/** Keeps the state for the rest of the browser tab's life. {...} -> () */
function saveState(state) {
  try {
    sessionStorage.setItem(STATE_KEY, JSON.stringify(state));
  } catch {
    /* not fatal: the playground simply starts afresh next time */
  }
}

function saveSettings(settings) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
  } catch {
    /* not fatal: the session simply does not outlive the tab */
  }
}
