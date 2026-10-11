// The playground user interface: two editors, a target selector, an example
// selector, and a shared output pane. Served by
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

const STORAGE_KEY = "pyking-playground.settings";

/** What the settings dialog starts from, before anything saved is layered
 *  over it. The two output switches default on: a pane you cannot scroll
 *  loses what it cannot show, and output that accumulates across runs is
 *  hard to read the newest of. `autoRun` defaults off -- running on every
 *  edit is a preference, and it is the one setting that can start the
 *  multi-megabyte runtime download without an explicit button press. */
const DEFAULT_SETTINGS = {
  fontSize: 13,
  scrollOutput: true,
  clearOnRun: true,
  autoRun: false,
};

/** How long the source has to sit still before an automatic run. Long
 *  enough to finish a word -- half-written code is mostly code that does
 *  not compile, and re-running it per keystroke would say so per keystroke. */
const AUTO_RUN_DELAY = 600;

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
  theme: "dark",
  initialTarget: "node24",
  initialExample: "subset_control.pyk",
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
  }

  async init() {
    const { ui } = this;

    const { monaco } = this;
    // `automaticLayout` has Monaco watch its container, so a pane that
    // changes size -- by a drag, by the window resizing, by the host page
    // reflowing -- is laid out again without being told.
    const options = {
      theme: themeFor(this.cfg.theme), fontSize: 13,
      tabSize: 4, insertSpaces: true, detectIndentation: false,
      automaticLayout: true, minimap: { enabled: false },
      fixedOverflowWidgets: true,
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

    ui.target.addEventListener("change", () => this.onTargetChange());
    ui.example.addEventListener("change", () => this.loadExample(ui.example.value));
    ui.compile.addEventListener("click", () => {
      this.showView("code");
      this.compile();
    });
    ui.runLeft.addEventListener("click", () => this.runFromSource());
    ui.runRight.addEventListener("click", () => this.runGenerated());
    ui.stopLeft.addEventListener("click", () => this.stopRun());
    ui.stopRight.addEventListener("click", () => this.stopRun());
    ui.copy.addEventListener("click", () => this.copyRight());
    ui.viewCode.addEventListener("click", () => this.showView("code"));
    ui.viewPage.addEventListener("click", () => this.showView("page"));
    ui.clear.addEventListener("click", () => this.clearOutput());

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
    // Shift+Enter runs, and means the Run button of whichever pane has focus
    // -- the source pane runs the program itself, the generated pane runs
    // what is displayed. Overriding it costs nothing, since plain
    // Enter already inserts a newline and Shift+Enter merely duplicated it.
    const { KeyMod, KeyCode } = monaco;
    const bind = (editor, id, label, key, run) =>
      editor.addAction({ id, label, keybindings: [key], run: () => { run(); } });

    const COMPILE = KeyMod.CtrlCmd | KeyCode.Enter;
    const RUN = KeyMod.Shift | KeyCode.Enter;
    const RUN_ACCEL = KeyMod.CtrlCmd | KeyMod.Shift | KeyCode.Enter;

    bind(this.left, "pyk-compile", "Compile", COMPILE, () => this.compile());
    bind(this.right, "pyk-compile", "Compile", COMPILE, () => this.compile());
    bind(this.left, "pyk-run", "Run the program", RUN, () => this.runFromSource());
    bind(this.right, "pyk-run", "Run the generated code", RUN, () => this.runGenerated());
    bind(this.left, "pyk-run-accel", "Run the program", RUN_ACCEL,
         () => this.runFromSource());
    bind(this.right, "pyk-run-accel", "Run the generated code", RUN_ACCEL,
         () => this.runGenerated());

    // The same keys when focus is outside both editors -- on a dropdown, a
    // button, or the page itself. Monaco stops propagation for keys it
    // handled, but the check for an enclosing editor is explicit so that a
    // future Monaco that stops doing so cannot make this fire twice.
    ui.root.addEventListener("keydown", (event) => {
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
      if (accel && !event.shiftKey) this.compile();
      else this.runFromSource();
    });

    if (this.meta.examples.length) {
      await this.loadExample(this.cfg.initialExample, { silent: true });
    } else {
      // No tests/ beside the tools, as in a distribution: nothing to offer.
      ui.example.classList.add("pyk-hidden");
      this.setSource(FALLBACK_SOURCE);
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
    this.note("Press Compile to see the generated code, or Run to run the "
              + "program itself.");
  }

  // -- examples ---------------------------------------------------------

  async loadExample(file, { silent = false } = {}) {
    const entry = this.meta.examples.find((e) => e.file === file);
    if (!entry) return;
    const response = await fetch(this.cfg.examplesURL + file);
    this.setSource(await response.text());
    this.ui.example.value = file;
    this.clearError();
    this.refreshSupport();
    if (!silent) {
      this.note(entry.targets.length
        ? `Loaded ${file} — supported by: ${entry.targets.join(", ")}`
        : `Loaded ${file}`);
    }
  }

  /** Tell the user, before they press anything, whether the loaded example
   *  is expected to work on the selected target. A refusal is not a bug --
   *  the JS, C and Java backends implement a subset -- so this explains
   *  rather than hides it. */
  refreshSupport() {
    const entry = this.meta.examples.find((e) => e.file === this.ui.example.value);
    const target = this.ui.target.value;
    // An empty list means the manifest makes no code-generation claim about
    // this program (a type-checker fixture, say) -- which is not the same as
    // claiming it fails everywhere, so say nothing rather than something wrong.
    const known = entry && entry.targets.length > 0 && target !== "pyking"
                  && !entry.targets.includes(target);
    this.ui.support.textContent = known
      ? `${this.ui.example.value} is not supported by ${target}`
      : "";
    this.ui.support.className = known ? "pyk-label pyk-warned" : "pyk-label";
    this.ui.support.style.color = known ? "var(--pyk-warn)" : "";
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
    if (!(await this.ensureRuntime())) return;
    const target = this.ui.target.value;
    const result = await this.runtime.compile(
      this.left.getValue(), target, "playground.pyk");
    this.clearError();

    if (!result.ok) {
      this.showFiles({});
      this.error(result.text);
      if (result.info) this.markError(result.info, result.text);
      return;
    }
    this.showFiles(result.files, result.views);
    const names = Object.keys(result.files);
    // The `pyking` target compiles nothing *to* anything: the front end
    // ran and printed the program back, so saying "compiled to pyking"
    // would name a backend that does not exist.
    const what = target === "pyking"
      ? "Printed by the front end" : `Compiled to ${target}`;
    this.good(`${what} — ${names.length === 1
      ? names[0] : names.length + " files: " + names.join(", ")}`);
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
    this.refreshSupport();
    this.updateRunButtons();
  }

  updateRunButtons() {
    const target = this.ui.target.value;
    const how = this.meta.run[target];
    const haveCode = Object.keys(this.files).length > 0;
    const viewing = this.views?.has(this.current);
    this.ui.runRight.disabled = !how || !haveCode || viewing;
    this.ui.runRight.title = viewing
      ? `${this.current} is a view of the front end, not code to run`
      : !how ? whyNotRunnable(target)
      : !haveCode ? "Compile first, then run"
      : `Run the generated ${target} code (Shift+Enter)`;
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
   *  compile, which is exactly what "just run my program" should mean. */
  async runFromSource() {
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
      const input = await this.askForInput(source);
      if (input === null) return;
      await this.executeProgram(source, input);
    } finally {
      // A program that sent its page something goes on running there --
      // the page calls back what it was given -- so Stop stays armed.
      if (!(this.runtime.isLive && this.running)) this.endRun();
    }
  }

  /** Shows the compiled code or the program's page in the right-hand
   *  pane. "code" | "page" -> () */
  showView(view) {
    const { ui } = this;
    const page = view === "page";
    ui.viewCode.classList.toggle("active", !page);
    ui.viewPage.classList.toggle("active", page);
    ui.files.classList.toggle("pyk-hidden", page);
    ui.rightEditor.classList.toggle("pyk-hidden", page);
    ui.copy.classList.toggle("pyk-hidden", page);
    ui.page.classList.toggle("pyk-hidden", !page);
    if (!page) this.right.layout();
  }

  /** Removes the last run's page, if it had one. () -> () */
  closePage() {
    this.pageHost?.close();
    this.pageHost = null;
  }

  /** Shows what the running program sent its page, on the Page tab.
   *  String -> [Object] -> () */
  pageReceive(module, data) {
    if (!this.pageHost) {
      this.pageHost = new PageHost(this.ui.page, {
        libURL: this.runtime.libURL,
        send: (name, event) => this.runtime.sendEvent(name, event),
      });
      this.showView("page");
    }
    this.pageHost.receive(module, data);
  }

  /** The Run button in the generated pane: execute exactly what is shown. */
  async runGenerated() {
    const target = this.ui.target.value;
    const how = this.meta.run[target];
    if (!how) return;          // nothing runs, so nothing is cleared either
    this.beforeRun();
    const code = this.right.getValue();
    this.beginRun("right", "js");
    try {
      await this.executeJs(how, code, target);
    } finally {
      this.endRun();
    }
  }

  /** What the program reads and is passed, asked of the user before it
   *  runs -- and only where the program uses one: a program that never
   *  reads standard input is not interrupted by a box asking for it.
   *  Resolves to {stdin, args}, or to null if the dialog was cancelled.
   *  A program that does not check is not asked about: running it reports
   *  the refusal. String -> Promise<{stdin, args}?> */
  async askForInput(source) {
    let analysis;
    try {
      analysis = await this.runtime.analyze(source);
    } catch {
      return { stdin: "", args: [] };
    }
    if (!analysis.ok || !(analysis.stdin || analysis.args)) {
      return { stdin: "", args: [] };
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
      await this.jsRunner.run(code, {
        files: this.files,
        formatHelper: this.meta.formatHelper,
        main: this.current,
        onOutput: (text) => this.write(text),
        onDebug: (text) => this.debugLine(text),
      });
      this.good(`— ${target} finished —`);
    } catch (err) {
      if (!this.stopped) this.error(err.message);
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
    this.endRun();
    this.stopped = false;
    this.running = { origin, kind };
    const right = origin === "right";
    (right ? this.ui.runRight : this.ui.runLeft).classList.add("pyk-hidden");
    (right ? this.ui.stopRight : this.ui.stopLeft).classList.remove("pyk-hidden");
  }

  endRun() {
    this.running = null;
    this.ui.stopLeft.classList.add("pyk-hidden");
    this.ui.stopRight.classList.add("pyk-hidden");
    this.ui.runLeft.classList.remove("pyk-hidden");
    this.ui.runRight.classList.remove("pyk-hidden");
  }

  stopRun() {
    if (!this.running) return;
    const { kind } = this.running;
    this.stopped = true;
    // A program that has answered and is only waiting for its page's
    // events is let go rather than killed: nothing is running to stop.
    const waiting = kind === "pyking" && this.runtime.isLive
      && !this.runtime.pending.size;
    if (waiting) {
      this.runtime.endLive();
      this.endRun();
      this.error("— stopped —");
      return;
    }
    if (kind === "pyking") this.runtime.stop();
    else this.jsRunner.stop();
    this.endRun();
    this.error("— stopped —");
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
      await this.runFromSource();
    } finally {
      this.autoRunning = false;
    }
  }

  /** Clear the output pane when starting a run, if that is switched on.
   *  Compiling deliberately does not: the setting says "each time you press
   *  Run", and a compile error you wanted to keep beside the output would
   *  otherwise vanish. */
  beforeRun() {
    if (this.settings.clearOnRun) this.clearOutput();
  }

  write(text, cls) {
    const span = document.createElement("span");
    if (cls) span.className = cls;
    span.textContent = text;
    this.ui.output.appendChild(span);
    // Following the newest line is part of being scrollable. With scrolling
    // switched off the pane clips instead, and scrolling it programmatically
    // would push the start of the output out of sight with no way back.
    if (this.settings.scrollOutput) {
      this.ui.output.scrollTop = this.ui.output.scrollHeight;
    }
  }
  /** A `debug` line: in the pane, marked apart from what the program
   *  printed, and on the console, which is where a JavaScript program's
   *  `debug` goes. */
  debugLine(text) {
    this.write(text, "debug");
    console.log(text.replace(/\n$/, ""));
  }
  note(text) { this.write(text + "\n", "note"); }
  good(text) { this.write(text + "\n", "good"); }
  error(text) { this.write(text + "\n", "err"); }
  clearOutput() { this.ui.output.textContent = ""; }

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

  async copyRight() {
    try {
      await navigator.clipboard.writeText(this.right.getValue());
      this.note("Copied the generated code to the clipboard.");
    } catch {
      this.error("The browser refused clipboard access.");
    }
  }

  status(kind, text) {
    this.ui.dot.className = "pyk-dot " + kind;
    this.ui.statusText.textContent = text;
  }

  // -- resizable panes --------------------------------------------------

  installSplitters() {
    const { columns, gutterV, rightPane, gutterH } = this.ui;

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

    // Vertical drag: how much of the generated pane the output takes,
    // measured from the bottom because that is the edge it is anchored to.
    this.installDrag(gutterH, "h", (event) => {
      const box = rightPane.getBoundingClientRect();
      this.setSplit("--pyk-out-split", (box.bottom - event.clientY) / box.height);
    });
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
    this.ui.resetLayoutButton.addEventListener("click", () => this.resetLayout());
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
    this.ui.output.style.fontSize = px + "px";
    this.ui.fontValue.textContent = px + "px";
    this.ui.fontSize.value = String(px);
  }

  applyOutputScroll() {
    const on = this.settings.scrollOutput;
    this.ui.output.classList.toggle("pyk-no-scroll", !on);
    this.ui.scrollOutput.checked = on;
  }

  applySettings() {
    this.applyFontSize(this.settings.fontSize);
    this.applyOutputScroll();
    this.ui.clearOnRun.checked = this.settings.clearOnRun;
    this.ui.autoRun.checked = this.settings.autoRun;
    for (const [key, name] of [["colSplit", "--pyk-col-split"],
                               ["outSplit", "--pyk-out-split"]]) {
      if (this.settings[key]) this.ui.root.style.setProperty(name, this.settings[key]);
    }
  }

  saveSettings() {
    const style = this.ui.root.style;
    saveSettings({
      fontSize: this.settings.fontSize,
      scrollOutput: this.settings.scrollOutput,
      clearOnRun: this.settings.clearOnRun,
      autoRun: this.settings.autoRun,
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
        <small>the real compiler, running in your browser</small></div>
      <div class="pyk-status"><span class="pyk-dot"></span>
        <span data-r="statusText">idle</span></div>
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
          <span class="pyk-label">Source</span>
          <select data-r="example" title="Load an example program"></select>
          <span class="pyk-spacer"></span>
          <span class="pyk-label" data-r="support"></span>
          <button class="pyk-stop pyk-hidden" data-r="stopLeft"
                  title="Stop the running program">■ Stop</button>
          <button class="pyk-run" data-r="runLeft"
                  title="Run the program itself (Shift+Enter)">▶ Run</button>
          <button class="pyk-primary" data-r="compile"
                  title="Compile this source into the pane on the right (Ctrl+Enter)">
            Compile →</button>
        </div>
        <div class="pyk-editor" data-r="leftEditor"></div>
      </section>
      <div class="pyk-gutter pyk-gutter-v" data-r="gutterV" role="separator"
           aria-orientation="vertical" title="Drag to resize"></div>
      <section class="pyk-pane" data-r="rightPane">
        <div class="pyk-toolbar">
          <span class="pyk-label">Target</span>
          <select data-r="target"></select>
          <span class="pyk-spacer"></span>
          <button class="pyk-stop pyk-hidden" data-r="stopRight"
                  title="Stop the running program">■ Stop</button>
          <button class="pyk-run" data-r="runRight">▶ Run</button>
          <!-- No glyph: U+29C9 has no coverage in the usual UI fonts and
               rendered as an empty box. A word always renders. -->
          <button data-r="copy" title="Copy the generated code">Copy</button>
        </div>
        <div class="pyk-views" data-r="views" role="tablist">
          <button class="pyk-file pyk-view active" data-r="viewCode" role="tab"
                  title="The code the compiler wrote">Compiled code</button>
          <button class="pyk-file pyk-view" data-r="viewPage" role="tab"
                  title="What the program shows: a program using tinyweb draws here">Page</button>
        </div>
        <div class="pyk-files" data-r="files"></div>
        <div class="pyk-editor" data-r="rightEditor"></div>
        <div class="pyk-page pyk-hidden" data-r="page"></div>
        <div class="pyk-gutter pyk-gutter-h" data-r="gutterH" role="separator"
             aria-orientation="horizontal" title="Drag to resize"></div>
        <div class="pyk-output-wrap" data-r="outputWrap">
          <div class="pyk-output-head">
            <span class="pyk-label">Output</span>
            <span class="pyk-spacer"></span>
            <button data-r="clear">Clear</button>
          </div>
          <pre class="pyk-output" data-r="output"></pre>
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
      <div class="pyk-modal" role="dialog" aria-modal="true"
           aria-label="Playground settings">
        <div class="pyk-modal-head">
          <strong>Settings</strong>
          <span class="pyk-spacer"></span>
          <button class="pyk-icon" data-r="modalClose"
                  title="Close (Esc)" aria-label="Close">✕</button>
        </div>
        <div class="pyk-modal-body">
          <div class="pyk-field">
            <label>Editor font size</label>
            <div class="pyk-field-row">
              <input type="range" min="10" max="26" step="1" data-r="fontSize"
                     aria-label="Editor font size">
              <span class="pyk-value" data-r="fontValue">13px</span>
            </div>
            <p class="pyk-hint">Applies to both editors and the output pane.</p>
          </div>
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
          <div class="pyk-field">
            <label>Layout</label>
            <div class="pyk-field-row">
              <button data-r="resetLayoutButton">Reset pane sizes</button>
            </div>
            <p class="pyk-hint">Drag the bars between panes to resize them.
              Settings are remembered in this browser.</p>
          </div>
        </div>
      </div>
    </div>`;

  const ui = { root: host };
  for (const el of host.querySelectorAll("[data-r]")) ui[el.dataset.r] = el;
  ui.dot = host.querySelector(".pyk-dot");

  for (const target of meta.targets) {
    ui.target.add(new Option(`${target.label}  (${target.name})`, target.name));
  }
  ui.target.value = cfg.initialTarget;

  // Grouped, because "which targets accept this program" is a real property
  // of each example and worth seeing before you pick one. Run works on
  // every one of them either way: the interpreter is not a target.
  const groups = [
    ["Compiles for every target", meta.examples.filter((e) => e.universal)],
    ["Some targets only (uses lists, for, match, …)",
     meta.examples.filter((e) => !e.universal)],
  ];
  for (const [label, entries] of groups) {
    if (!entries.length) continue;
    const group = document.createElement("optgroup");
    group.label = `${label} — ${entries.length}`;
    for (const entry of entries) {
      group.appendChild(new Option(entry.name, entry.file));
    }
    ui.example.appendChild(group);
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
