// The playground's Debug tab: the program in the editor run by the
// interpreter a step at a time (src/debug_session.ml, reached through
// PykingRuntime's `debugProgram`), with breakpoints in the editor's
// margin, the line it stopped at marked, and below the controls five
// panes -- Environment, Watch, Call stack, Breakpoints and the Console,
// which holds what the program writes and evaluates what is typed into
// it where the program stopped.
//
// Every control has keys, shown when the pointer rests on it and
// changed in the settings (`DEFAULT_KEYS`). Start's, Continue's and the
// steps' act anywhere in the playground -- Continue's starting debugging
// when nothing is debugged, the steps' doing nothing then -- and the
// others where the focus is in the editor or in this tab.
//
//   import { Debugger } from "./debugger.js";
//   const debug = new Debugger(playground);
//   debug.install(panelElement);

/** The file the playground's program is debugged as: its breakpoints
 *  are this file's. */
const FILE = "playground.pyk";

/** What each action is called, in the settings and in a tooltip. */
export const ACTIONS = [
  ["start", "Start debugging, or start again"],
  ["continue", "Continue"],
  ["next", "Step over"],
  ["in", "Step into"],
  ["out", "Step out"],
  ["stop", "Stop debugging"],
  ["breakpoint", "Set or remove a breakpoint on the cursor's line"],
];

/** The keys each action has until the settings say otherwise: an Alt
 *  key for each (Debug, Continue, Over, Into, ouT, Stop, Breakpoint) and
 *  a function key for continuing and each step. Alt is Option on a Mac,
 *  and `Mod` Cmd there and Ctrl elsewhere. */
export const DEFAULT_KEYS = {
  start: ["Alt+D"],
  continue: ["F8", "Alt+C"],
  next: ["F10", "Alt+O"],
  in: ["F11", "Alt+I"],
  out: ["Shift+F11", "Alt+T"],
  stop: ["Alt+S"],
  breakpoint: ["Alt+B"],
};

/** The actions that act only while a program is being debugged. */
const SESSION_ACTIONS = ["next", "in", "out", "stop"];

/** An action's keys as the settings hold them -- a list, or one spec
 *  as earlier settings saved it -- as a list. Any -> [String] */
export function keyList(held) {
  if (Array.isArray(held)) return held.filter((k) => typeof k === "string" && k !== "");
  return typeof held === "string" && held !== "" ? [held] : [];
}

/** Several key specs as this computer's keyboard writes them, "F10 or
 *  Option+O". [String] -> String */
export function showKeys(specs) {
  return specs.length === 0 ? "no key" : specs.map(showKey).join(" or ");
}

/** The physical key a written character stands for, so a key means the
 *  same with Shift held: `;` is Semicolon whether or not it types `:`. */
const CODES = {
  ";": "Semicolon", "'": "Quote", "\\": "Backslash", ",": "Comma", ".": "Period",
  "/": "Slash", "[": "BracketLeft", "]": "BracketRight", "-": "Minus", "=": "Equal",
  "`": "Backquote", Enter: "Enter", Space: "Space", Tab: "Tab", Backspace: "Backspace",
  Up: "ArrowUp", Down: "ArrowDown", Left: "ArrowLeft", Right: "ArrowRight",
};

/** Whether the page is on a Mac, where Mod is Cmd. () -> Bool */
function onMac() {
  const platform = globalThis.navigator?.userAgentData?.platform ?? globalThis.navigator?.platform ?? "";
  return /mac|iphone|ipad/i.test(platform);
}

/** A key spec, "Mod+Shift+;", as {mod, ctrl, alt, shift, code}.
 *  String -> Object? */
export function parseKey(spec) {
  if (typeof spec !== "string" || spec === "") return null;
  const parts = spec.split("+");
  // "Mod++" is the key `+` itself.
  let key = parts.pop();
  if (key === "" && parts.length > 0 && parts[parts.length - 1] === "") {
    parts.pop();
    key = "+";
  }
  const has = (name) => parts.includes(name);
  let code = CODES[key];
  if (!code && /^[A-Za-z]$/.test(key)) code = "Key" + key.toUpperCase();
  if (!code && /^[0-9]$/.test(key)) code = "Digit" + key;
  if (!code && /^F[0-9]{1,2}$/.test(key)) code = key;
  if (!code && key === "+") code = "Equal";
  if (!code) return null;
  return { mod: has("Mod"), ctrl: has("Ctrl"), alt: has("Alt"), shift: has("Shift"), code };
}

/** Whether a key event is the key a spec names. Object -> KeyboardEvent -> Bool */
export function matchesKey(parsed, event) {
  if (!parsed || event.code !== parsed.code) return false;
  const mac = onMac();
  const mod = mac ? event.metaKey : event.ctrlKey;
  const ctrl = mac ? event.ctrlKey : false;
  if (mac && !parsed.mod && event.metaKey) return false;
  if (!mac && !parsed.mod && event.metaKey) return false;
  return mod === parsed.mod && ctrl === parsed.ctrl && event.altKey === parsed.alt
    && event.shiftKey === parsed.shift;
}

/** The spec a key event writes, for the settings' key fields, or null
 *  for a modifier pressed on its own. KeyboardEvent -> String? */
export function specOf(event) {
  if (["Shift", "Control", "Alt", "Meta"].includes(event.key)) return null;
  const named = Object.entries(CODES).find(([, code]) => code === event.code)?.[0];
  let key = named;
  if (!key && /^Key[A-Z]$/.test(event.code)) key = event.code.slice(3);
  if (!key && /^Digit[0-9]$/.test(event.code)) key = event.code.slice(5);
  if (!key && /^F[0-9]{1,2}$/.test(event.code)) key = event.code;
  if (!key) return null;
  const mac = onMac();
  const parts = [];
  if (mac ? event.metaKey : event.ctrlKey) parts.push("Mod");
  if (mac && event.ctrlKey) parts.push("Ctrl");
  if (event.altKey) parts.push("Alt");
  if (event.shiftKey) parts.push("Shift");
  parts.push(key);
  return parts.join("+");
}

/** A key spec as this computer's keyboard writes it: Cmd on a Mac.
 *  String -> String */
export function showKey(spec) {
  if (!spec) return "no key";
  const mac = onMac();
  return spec.split("+").map((part) => part === "Mod" ? (mac ? "Cmd" : "Ctrl")
    : part === "Alt" && mac ? "Option" : part).join("+");
}

export class Debugger {
  /** The Debug tab of a playground: it uses the playground's editor,
   *  runtime, settings and run lifecycle. Playground -> () */
  constructor(app) {
    this.app = app;
    this.state = "off";        // off, starting, running, stopped, idle
    this.reason = null;        // why it stopped, as the session says
    this.frames = [];          // the calls in progress where it stopped
    this.frame = null;         // the one chosen, whose names are shown
    this.breakpoints = [];     // {line, enabled, condition, hit, log, verified, decoration}
    this.lineMarks = [];       // the editor's decorations for where it stopped
    this.watches = loadList("pyking-playground.watches");
    this.consoleHistory = [];
    this.consoleAt = 0;
    this.sourceChanged = false;
  }

  /** Builds the tab inside `panel`, and hooks the editor's margin, its
   *  keys and its hover. Element -> () */
  install(panel) {
    this.panel = panel;
    panel.tabIndex = -1;
    panel.innerHTML = `
      <div class="pyk-toolbar pyk-debug-bar" data-d="bar">
        <button class="pyk-run" data-d="start">▶ Debug</button>
        <button data-d="continue" disabled>⏵ Continue</button>
        <button data-d="pause" class="pyk-hidden" disabled>⏸ Pause</button>
        <button data-d="next" disabled>↷ Over</button>
        <button data-d="in" disabled>↓ Into</button>
        <button data-d="out" disabled>↑ Out</button>
        <button data-d="restart" disabled>⟲ Restart</button>
        <button class="pyk-stop" data-d="stop" disabled>■ Stop</button>
        <span class="pyk-spacer"></span>
      </div>
      <div class="pyk-debug-status" data-d="status">Not debugging. Click in the editor's margin to set a breakpoint, then press Debug.</div>
      <div class="pyk-debug-panes">
        <details class="pyk-debug-pane" open>
          <summary>Environment</summary>
          <div class="pyk-debug-tree" data-d="environment"></div>
        </details>
        <details class="pyk-debug-pane" open>
          <summary>Watch <button class="pyk-icon" data-d="addWatch" title="Add an expression to watch">+</button></summary>
          <div class="pyk-debug-watch" data-d="watch"></div>
        </details>
        <details class="pyk-debug-pane" open>
          <summary>Call stack</summary>
          <div class="pyk-debug-stack" data-d="stack"></div>
        </details>
        <details class="pyk-debug-pane" open>
          <summary>Breakpoints <button class="pyk-icon" data-d="clearBreakpoints" title="Remove every breakpoint">✕</button></summary>
          <div class="pyk-debug-breakpoints" data-d="breakpointList"></div>
        </details>
        <details class="pyk-debug-pane pyk-debug-console-pane" open>
          <summary>Console <button class="pyk-icon" data-d="clearConsole" title="Clear the console">⌫</button></summary>
          <pre class="pyk-output pyk-debug-console" data-d="console"></pre>
          <input class="pyk-debug-input" data-d="input" type="text" spellcheck="false"
                 autocomplete="off" placeholder="An expression, evaluated where the program stopped"
                 aria-label="Evaluate an expression">
        </details>
      </div>`;
    this.ui = {};
    for (const el of panel.querySelectorAll("[data-d]")) this.ui[el.dataset.d] = el;
    const { ui } = this;
    ui.start.addEventListener("click", () => this.start());
    ui.continue.addEventListener("click", () => this.command("continue"));
    ui.pause.addEventListener("click", () => this.command("pause"));
    ui.next.addEventListener("click", () => this.command("next"));
    ui.in.addEventListener("click", () => this.command("in"));
    ui.out.addEventListener("click", () => this.command("out"));
    ui.restart.addEventListener("click", () => this.start());
    ui.stop.addEventListener("click", () => this.stop());
    ui.addWatch.addEventListener("click", (event) => {
      event.preventDefault();
      this.editWatch(null);
    });
    ui.clearBreakpoints.addEventListener("click", (event) => {
      event.preventDefault();
      this.clearBreakpoints();
    });
    ui.clearConsole.addEventListener("click", (event) => {
      event.preventDefault();
      ui.console.textContent = "";
    });
    ui.input.addEventListener("keydown", (event) => this.consoleKey(event));
    this.installEditor();
    this.showKeys();
    this.renderWatches();
    this.renderBreakpoints();
    this.renderEnvironment([]);
    this.renderStack();
  }

  // -- the editor -------------------------------------------------------

  /** The editor's margin sets and removes breakpoints, its text follows
   *  them as lines move, and its hover shows a name's value where the
   *  program stopped. () -> () */
  installEditor() {
    const { app } = this;
    const editor = app.left;
    const monaco = app.monaco;
    editor.updateOptions({ glyphMargin: true });
    editor.onMouseDown((event) => {
      const kind = event.target.type;
      const T = monaco.editor.MouseTargetType;
      if (kind !== T.GUTTER_GLYPH_MARGIN && kind !== T.GUTTER_LINE_NUMBERS) return;
      if (kind === T.GUTTER_LINE_NUMBERS && !event.event.altKey) return;
      const line = event.target.position?.lineNumber;
      if (line) this.toggleBreakpoint(line);
    });
    editor.onDidChangeModelContent(() => {
      // The decorations move with the text; the lines are read back.
      let moved = false;
      for (const b of this.breakpoints) {
        const range = b.decoration?.getRange(0);
        if (range && range.startLineNumber !== b.line) {
          b.line = range.startLineNumber;
          moved = true;
        }
      }
      if (moved) this.renderBreakpoints();
      if (this.state !== "off" && !app.programmaticEdit) this.sourceChanged = true;
    });
    monaco.languages.registerHoverProvider(editor.getModel().getLanguageId(), {
      provideHover: async (model, position) => {
        if (this.state !== "stopped" || model !== editor.getModel()) return null;
        const word = model.getWordAtPosition(position);
        if (!word) return null;
        const answer = await this.evaluate(word.word);
        if (!answer?.ok) return null;
        return {
          range: new monaco.Range(position.lineNumber, word.startColumn,
                                  position.lineNumber, word.endColumn),
          contents: [{ value: "```pyking\n" + `${word.word} = ${answer.value} : ${answer.type}` + "\n```" }],
        };
      },
    });
  }

  /** The keys of every action, read afresh from the settings, and shown
   *  on the buttons. Answers the parsed keys. () -> Object */
  showKeys() {
    const keys = this.keys();
    const tip = (button, label, action) => {
      button.title = `${label} (${showKeys(keys[action])})`;
    };
    const { ui } = this;
    const startKeys = [...keys.start, ...keys.continue];
    ui.start.title = `Start debugging the program in the editor (${showKeys(startKeys)})`;
    tip(ui.restart, "Start debugging it again from the beginning", "start");
    tip(ui.continue, "Continue to the next breakpoint", "continue");
    tip(ui.pause, "Pause where the program is", "continue");
    tip(ui.next, "Step over: run the line, stopping at the next one here or above", "next");
    tip(ui.in, "Step into: stop at the next line run, inside a call too", "in");
    tip(ui.out, "Step out: run until the function returns", "out");
    tip(ui.stop, "Stop debugging", "stop");
    this.parsed = Object.fromEntries(Object.entries(keys)
      .map(([k, specs]) => [k, specs.map(parseKey).filter(Boolean)]));
    return this.parsed;
  }

  /** Every action's key specs: the settings' over the defaults.
   *  () -> {action: [String]} */
  keys() {
    const saved = this.app.settings.debugKeys ?? {};
    return Object.fromEntries(Object.entries(DEFAULT_KEYS).map(([action, specs]) =>
      [action, action in saved ? keyList(saved[action]) : specs]));
  }

  /** Runs the action a key event names, if it names one of `only`'s
   *  (every action where none is given). Answers whether it did.
   *  KeyboardEvent -> [String]? -> Bool */
  handleKey(event, only = null) {
    const parsed = this.parsed ?? this.showKeys();
    const found = Object.entries(parsed)
      .find(([action, keys]) => (only === null || only.includes(action))
        && keys.some((key) => matchesKey(key, event)));
    if (!found) return false;
    const [action] = found;
    event.preventDefault();
    event.stopPropagation();
    if (event.key === "Dead") this.app.deadKeyTaken?.();
    if (SESSION_ACTIONS.includes(action) && this.state === "off") return true;
    if (action === "start") this.start();
    else if (action === "continue") {
      if (this.state === "off") this.start();
      else this.command(this.state === "running" ? "pause" : "continue");
    }
    else if (action === "stop") this.stop();
    else if (action === "breakpoint") {
      const line = this.app.left.getPosition()?.lineNumber;
      if (line) this.toggleBreakpoint(line);
    } else this.command(action);
    return true;
  }

  // -- breakpoints ------------------------------------------------------

  /** Sets a breakpoint on a line, or removes the one there. Int -> () */
  toggleBreakpoint(line) {
    const at = this.breakpoints.findIndex((b) => b.line === line);
    if (at >= 0) {
      this.breakpoints[at].decoration?.clear();
      this.breakpoints.splice(at, 1);
    } else {
      this.breakpoints.push({ line, enabled: true, condition: "", hit: "", log: "", verified: null });
    }
    this.breakpointsChanged();
  }

  /** Removes every breakpoint: the pane's ✕, and a new program in the
   *  editor. () -> () */
  clearBreakpoints() {
    for (const b of this.breakpoints) b.decoration?.clear();
    this.breakpoints = [];
    this.breakpointsChanged();
  }

  /** The breakpoints drawn again in the margin and the list, and sent to
   *  the program being debugged. () -> Promise<()> */
  async breakpointsChanged() {
    this.breakpoints.sort((a, b) => a.line - b.line);
    this.decorateBreakpoints();
    this.renderBreakpoints();
    if (this.state === "off" || this.state === "starting") return;
    try {
      const verified = await this.app.runtime.debug("breakpoints", {
        file: FILE, breakpoints: this.sent() });
      this.verify(verified);
    } catch { /* the program ended meanwhile */ }
  }

  /** The enabled breakpoints, as the session takes them. () -> [Object] */
  sent() {
    return this.breakpoints.filter((b) => b.enabled).map((b) => ({
      line: b.line,
      ...(b.condition.trim() ? { condition: b.condition } : {}),
      ...(b.hit.trim() ? { hit: b.hit } : {}),
      ...(b.log.trim() ? { log: b.log } : {}),
    }));
  }

  /** Marks which breakpoints stop somewhere, from what the session
   *  answered. [Object] -> () */
  verify(verified) {
    const enabled = this.breakpoints.filter((b) => b.enabled);
    enabled.forEach((b, k) => { b.verified = verified[k]?.verified ?? null; });
    this.decorateBreakpoints();
    this.renderBreakpoints();
  }

  /** Each breakpoint's dot in the margin: red, hollow where disabled or
   *  where no statement starts at or after it, a diamond for a logpoint
   *  and a dot with a bar for a condition. () -> () */
  decorateBreakpoints() {
    const { monaco, left } = this.app;
    for (const b of this.breakpoints) {
      const kind = !b.enabled ? "pyk-bp-off" : b.verified === false ? "pyk-bp-unverified"
        : b.log.trim() ? "pyk-bp-log" : (b.condition.trim() || b.hit.trim()) ? "pyk-bp-condition"
        : "pyk-bp";
      const hover = b.log.trim() ? `Logpoint: ${b.log}`
        : b.condition.trim() ? `Breakpoint if ${b.condition}` : "Breakpoint";
      const decoration = {
        range: new monaco.Range(b.line, 1, b.line, 1),
        options: {
          glyphMarginClassName: "pyk-bp-glyph " + kind,
          glyphMarginHoverMessage: { value: hover },
          stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges,
        },
      };
      if (b.decoration) b.decoration.set([decoration]);
      else b.decoration = left.createDecorationsCollection([decoration]);
    }
  }

  /** The Breakpoints pane: each breakpoint with its switch, its line, and
   *  fields for a condition, a hit count and a log message. () -> () */
  renderBreakpoints() {
    const list = this.ui.breakpointList;
    list.textContent = "";
    if (this.breakpoints.length === 0) {
      list.append(empty("No breakpoints. Click in the editor's margin, or press "
                        + showKeys(this.keys().breakpoint) + " on a line."));
      return;
    }
    for (const b of this.breakpoints) {
      const row = document.createElement("div");
      row.className = "pyk-debug-bp" + (b.verified === false ? " unverified" : "");
      const on = document.createElement("input");
      on.type = "checkbox";
      on.checked = b.enabled;
      on.title = "Stop here, or not";
      on.addEventListener("change", () => {
        b.enabled = on.checked;
        this.breakpointsChanged();
      });
      const label = document.createElement("button");
      label.className = "pyk-link";
      label.textContent = `line ${b.line}`;
      label.title = b.verified === false
        ? "No statement starts on or after this line, so it never stops"
        : "Show the line";
      label.addEventListener("click", () => this.reveal(b.line));
      const field = (key, placeholder, title) => {
        const input = document.createElement("input");
        input.type = "text";
        input.spellcheck = false;
        input.className = "pyk-debug-bp-field";
        input.placeholder = placeholder;
        input.title = title;
        input.value = b[key];
        input.addEventListener("change", () => {
          b[key] = input.value;
          this.breakpointsChanged();
        });
        return input;
      };
      const remove = document.createElement("button");
      remove.className = "pyk-icon";
      remove.textContent = "✕";
      remove.title = "Remove this breakpoint";
      remove.addEventListener("click", () => this.toggleBreakpoint(b.line));
      row.append(on, label,
        field("condition", "condition", "Stop only when this Bool expression is true"),
        field("hit", "hits", "Stop only on these hits: 3, >= 3, % 2"),
        field("log", "log message", "Print this instead of stopping; {expression} is replaced by its value"),
        remove);
      list.append(row);
    }
  }

  // -- running ----------------------------------------------------------

  /** Debugs the program in the editor from its start: what Debug and
   *  Restart do. With no enabled breakpoint it stops at the first
   *  statement. () -> Promise<()> */
  async start() {
    const { app } = this;
    if (this.state !== "off") await this.stop({ quiet: true });
    const atEntry = Boolean(app.settings.debugStopOnEntry) || this.sent().length === 0;
    app.cancelAutoRun?.();
    app.showTab("debug");
    if (!(await app.ensureRuntime())) return;
    app.clearError();
    const source = app.left.getValue();
    const analysis = await app.analyze(source);
    const paged = analysis?.ok && analysis.externals.includes("tinyweb");
    const input = await app.askForInput(analysis, true);
    if (input === null) return;
    app.beginRun("left", "debug");
    this.state = "starting";
    this.sourceChanged = false;
    this.ui.console.textContent = "";
    this.setStatus("Starting…");
    this.updateButtons();
    app.closePage();
    app.switchTab = false;
    app.ui.pageTitle.textContent = app.ui.example.value || FILE;
    let answer;
    try {
      answer = await app.runtime.debugProgram(source, {
        name: FILE,
        stdin: input.stdin,
        args: input.args,
        tinywebLog: app.settings.tinywebLog,
        stopOnEntry: atEntry,
        justMyCode: app.settings.debugJustMyCode !== false,
        breakpoints: [{ file: FILE, breakpoints: this.sent() }],
        onOutput: (text) => this.write(text),
        onDebug: (text) => this.write(text, "debug"),
        onInput: (text) => this.write(text, "input"),
        onPage: (module, data) => app.pageReceive(module, data),
        onFailure: (text) => this.write(text.trimEnd() + "\n", "err"),
        onExit: (code) => {
          this.write(`— exited with status ${code} —\n`, "err");
          this.finish();
        },
        onEnd: () => app.pageHost?.freeze(),
        onDebugger: (message) => this.changed(message),
      });
    } catch (err) {
      if (!app.stopped) this.write("the compiler failed: " + err.message + "\n", "err");
      this.finish();
      return;
    }
    if (!answer.ok) {
      this.write(answer.text.trimEnd() + "\n", "err");
      if (answer.info) app.markError(answer.info, answer.text.trimEnd());
      this.finish();
      return;
    }
    if (paged) this.write("The program's page is on the Web output tab.\n", "note");
    if (this.state === "starting") {
      this.state = "running";
      this.setStatus("Running…");
    }
    this.verify(answer.breakpoints?.[0]?.breakpoints ?? []);
    this.updateButtons();
  }

  /** Where the program is has changed: {state, events}, from the worker.
   *  Object -> Promise<()> */
  async changed({ state, events }) {
    for (const e of events) {
      if (e.kind === "log") this.write(e.text, "log");
      if (e.kind === "done" && e.failure) {
        this.write(e.failure.text.trimEnd() + "\n", "err");
      }
      if (e.kind === "done" && e.exit !== undefined) {
        this.write(`— exited with status ${e.exit} —\n`, "err");
      }
      if (e.kind === "callback" && e.failure) {
        this.write(e.failure.text.trimEnd() + "\n", "err");
      }
      if (e.kind === "stopped") this.reason = e;
    }
    if (state === "ended") {
      const failed = events.some((e) => (e.kind === "done" && (e.failure || e.exit !== undefined)));
      if (!failed) this.write("— finished —\n", "good");
      this.finish();
      return;
    }
    this.state = state;
    if (state === "running") {
      this.clearLine();
      this.setStatus("Running…");
    } else if (state === "idle") {
      this.clearLine();
      this.frames = [];
      this.renderStack();
      this.renderEnvironment([]);
      this.setStatus("The top level has ended; waiting for the page's events. "
                     + "A breakpoint in a callback stops there.");
    } else if (state === "stopped") {
      if (this.app.tab !== "debug") {
        this.app.showTab("debug");
        const focused = document.activeElement;
        if (!this.app.ui.leftEditor.contains(focused) && !this.panel.contains(focused)) {
          this.panel.focus();
        }
      }
      await this.showStop();
    }
    this.updateButtons();
  }

  /** The program stopped: why, where, the calls in progress and the
   *  innermost one's names. () -> Promise<()> */
  async showStop() {
    const reason = this.reason ?? {};
    this.frames = await this.app.runtime.debug("frames");
    const top = this.frames[0];
    const where = top ? `${top.file}, line ${top.span.row1}` : "";
    const why = {
      entry: "Stopped at the first statement",
      step: "Stopped after a step",
      breakpoint: "Stopped at a breakpoint",
      pause: "Paused",
      exception: "Stopped on a runtime error",
    }[reason.reason] ?? "Stopped";
    this.setStatus(`${why}${where ? ` — ${where}` : ""}${this.sourceChanged
      ? ". The source has changed since: restart to debug what is in the editor." : ""}`,
      reason.reason === "exception");
    if (reason.reason === "exception" && reason.text) {
      this.write(`Runtime error: ${reason.text}\n`, "err");
    }
    await this.chooseFrame(top ?? null);
  }

  /** Shows a frame's names, evaluates the watches in it and marks its
   *  line. Object? -> Promise<()> */
  async chooseFrame(frame) {
    this.frame = frame;
    this.renderStack();
    this.markLine(frame);
    if (!frame) {
      this.renderEnvironment([]);
      this.renderWatches();
      return;
    }
    const scopes = await this.app.runtime.debug("scopes", { frame: frame.id });
    await this.renderEnvironment(scopes);
    await this.renderWatches();
  }

  /** Tells the program to go on, or to pause: "continue", "next", "in",
   *  "out" or "pause". String -> Promise<()> */
  async command(name) {
    if (name === "pause" ? this.state !== "running" : this.state !== "stopped") return;
    if (name !== "pause") {
      this.state = "running";
      this.clearLine();
      this.setStatus("Running…");
      this.updateButtons();
    }
    try {
      await this.app.runtime.debug("command", { command: name });
    } catch { /* the program ended meanwhile */ }
  }

  /** Stops debugging. {quiet}? -> Promise<()> */
  async stop({ quiet = false } = {}) {
    if (this.state === "off") return;
    this.app.runtime.debugStop();
    if (!quiet) this.write("— stopped —\n", "err");
    this.finish();
  }

  /** Debugging is over: the marks come off and the buttons go back.
   *  () -> () */
  finish() {
    if (this.state === "off") return;
    this.state = "off";
    this.frames = [];
    this.frame = null;
    this.clearLine();
    this.renderStack();
    this.renderEnvironment([]);
    this.renderWatches();
    this.setStatus("Not debugging.");
    this.updateButtons();
    if (this.app.running?.kind === "debug") this.app.endRun();
  }

  /** The buttons that make sense where the program is. () -> () */
  updateButtons() {
    const { ui } = this;
    const stopped = this.state === "stopped";
    const running = this.state === "running";
    const on = this.state !== "off";
    ui.start.classList.toggle("pyk-hidden", on);
    ui.restart.disabled = !on;
    ui.stop.disabled = !on;
    ui.continue.classList.toggle("pyk-hidden", running);
    ui.pause.classList.toggle("pyk-hidden", !running);
    ui.continue.disabled = !stopped;
    ui.pause.disabled = !running;
    for (const b of [ui.next, ui.in, ui.out]) b.disabled = !stopped;
    ui.input.disabled = !stopped;
  }

  setStatus(text, bad = false) {
    this.ui.status.textContent = text;
    this.ui.status.classList.toggle("bad", bad);
  }

  // -- where it stopped -------------------------------------------------

  /** Marks a frame's line in the editor, where the frame is in the
   *  program's own file. Object? -> () */
  markLine(frame) {
    const { monaco, left } = this.app;
    this.clearLine();
    if (!frame || frame.file !== FILE) return;
    const top = frame === this.frames[0];
    const line = frame.span.row1;
    const end = frame.span.row2 === line ? frame.span.col2 + 1 : left.getModel().getLineMaxColumn(line);
    this.lineMarks = left.createDecorationsCollection([
      {
        range: new monaco.Range(line, 1, line, 1),
        options: {
          isWholeLine: true,
          className: top ? "pyk-debug-line" : "pyk-debug-line-caller",
          glyphMarginClassName: top ? "pyk-debug-arrow" : "pyk-debug-arrow-caller",
        },
      },
      {
        range: new monaco.Range(line, frame.span.col1 + 1, line, end),
        options: { inlineClassName: top ? "pyk-debug-span" : "pyk-debug-span-caller" },
      },
    ]);
    left.revealLineInCenterIfOutsideViewport(line);
  }

  clearLine() {
    if (this.lineMarks?.clear) this.lineMarks.clear();
    this.lineMarks = [];
  }

  /** Scrolls the editor to a line, and puts the cursor there. Int -> () */
  reveal(line) {
    this.app.left.revealLineInCenter(line);
    this.app.left.setPosition({ lineNumber: line, column: 1 });
    this.app.left.focus();
  }

  /** The Call stack pane: each call, innermost first, the chosen one
   *  marked; a library's are dimmed. () -> () */
  renderStack() {
    const list = this.ui.stack;
    list.textContent = "";
    if (this.frames.length === 0) {
      list.append(empty(this.state === "running" ? "Running…" : "Not stopped."));
      return;
    }
    for (const frame of this.frames) {
      const row = document.createElement("button");
      row.className = "pyk-debug-frame" + (frame === this.frame ? " active" : "")
        + (frame.library ? " library" : "");
      const name = document.createElement("span");
      name.className = "name";
      name.textContent = frame.name;
      const where = document.createElement("span");
      where.className = "where";
      where.textContent = `${frame.file}:${frame.span.row1}`;
      row.append(name, where);
      row.addEventListener("click", () => this.chooseFrame(frame));
      list.append(row);
    }
  }

  /** The Environment pane: every name the chosen frame sees, one list
   *  whose lists, tuples and datatype values open to show their parts.
   *  [{name, ref}] -> Promise<()> */
  async renderEnvironment(scopes) {
    const tree = this.ui.environment;
    const shown = (this.shownEnvironment ?? 0) + 1;
    this.shownEnvironment = shown;
    const names = [];
    for (const scope of scopes) {
      const vars = await this.app.runtime.debug("variables", { ref: scope.ref });
      for (const v of vars) names.push([v, scope.ref]);
    }
    if (this.shownEnvironment !== shown) return;
    tree.textContent = "";
    if (names.length === 0) {
      tree.append(empty(this.state === "stopped" ? "No names here." : "Not stopped."));
      return;
    }
    for (const [v, ref] of names) tree.append(this.treeNode(v, ref));
  }

  /** One row of a tree, with its children loaded when it is opened.
   *  `parent` is the reference of the scope holding it, which setting a
   *  `var` needs. Object -> Int -> Element */
  treeNode(v, parent) {
    const node = document.createElement("div");
    node.className = "pyk-debug-node";
    const row = document.createElement("div");
    row.className = "row";
    const twisty = document.createElement("span");
    twisty.className = "twisty";
    twisty.textContent = v.ref > 0 ? "▸" : "";
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = v.name;
    const value = document.createElement("span");
    value.className = "value";
    value.textContent = v.value;
    if (v.settable) {
      value.title = "Double-click to give this var a new value";
      value.addEventListener("dblclick", () => this.editVariable(v, parent, value));
    }
    const type = document.createElement("span");
    type.className = "type";
    type.textContent = v.type;
    row.append(twisty, name, value, type);
    node.append(row);
    const children = document.createElement("div");
    children.className = "children";
    node.append(children);
    let loaded = false;
    const load = async () => {
      if (loaded) return;
      loaded = true;
      const vars = await this.app.runtime.debug("variables", { ref: v.ref });
      if (vars.length === 0) children.append(empty("nothing"));
      for (const child of vars) {
        children.append(this.treeNode(child, parent));
      }
    };
    if (v.ref > 0) {
      row.classList.add("expandable");
      children.classList.add("pyk-hidden");
      row.addEventListener("click", () => {
        const opening = children.classList.contains("pyk-hidden");
        children.classList.toggle("pyk-hidden", !opening);
        twisty.textContent = opening ? "▾" : "▸";
        if (opening) load();
      });
    }
    return node;
  }

  /** A `var`'s value replaced by an expression typed in its place.
   *  Object -> Int -> Element -> () */
  editVariable(v, scope, cell) {
    const input = document.createElement("input");
    input.className = "pyk-debug-edit";
    input.value = v.value;
    cell.replaceWith(input);
    input.focus();
    input.select();
    let done = false;
    const finish = async (keep) => {
      if (done) return;
      done = true;
      if (keep && input.value.trim() !== "") {
        const answer = await this.app.runtime.debug("set", { ref: scope, name: v.name, text: input.value });
        if (!answer.ok) this.write(`${v.name} := ${input.value}: ${answer.text}\n`, "err");
      }
      await this.chooseFrame(this.frame);
    };
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") finish(true);
      if (event.key === "Escape") finish(false);
    });
    input.addEventListener("blur", () => finish(true));
  }

  // -- watches and the console ------------------------------------------

  /** An expression's value in the chosen frame: {ok, value, type, ref} or
   *  {ok:false, text}. String -> Promise<Object?> */
  async evaluate(text) {
    if (this.state !== "stopped") return null;
    try {
      return await this.app.runtime.debug("evaluate", { frame: this.frame?.id, text });
    } catch {
      return null;
    }
  }

  /** The Watch pane: each expression with its value where the program
   *  stopped, or why it has none. () -> Promise<()> */
  async renderWatches() {
    const list = this.ui.watch;
    list.textContent = "";
    if (this.watches.length === 0) {
      list.append(empty("No expressions. Press + to add one."));
      return;
    }
    for (const [k, text] of this.watches.entries()) {
      const row = document.createElement("div");
      row.className = "pyk-debug-watch-row";
      const answer = await this.evaluate(text);
      if (answer?.ok) {
        const node = this.treeNode({ name: text, value: answer.value, type: answer.type,
                                     ref: answer.ref, settable: false }, 0);
        row.append(node);
      } else {
        const node = document.createElement("div");
        node.className = "pyk-debug-node";
        node.innerHTML = `<div class="row"><span class="twisty"></span><span class="name"></span><span class="value unavailable"></span></div>`;
        node.querySelector(".name").textContent = text;
        node.querySelector(".value").textContent = answer ? answer.text : "not stopped";
        row.append(node);
      }
      row.querySelector(".name").addEventListener("dblclick", () => this.editWatch(k));
      const remove = document.createElement("button");
      remove.className = "pyk-icon";
      remove.textContent = "✕";
      remove.title = "Stop watching this";
      remove.addEventListener("click", () => {
        this.watches.splice(k, 1);
        saveList("pyking-playground.watches", this.watches);
        this.renderWatches();
      });
      row.append(remove);
      list.append(row);
    }
  }

  /** A watch added (k null) or changed, typed in place. Int? -> () */
  editWatch(k) {
    const list = this.ui.watch;
    const input = document.createElement("input");
    input.className = "pyk-debug-edit";
    input.placeholder = "An expression to watch";
    input.value = k === null ? "" : this.watches[k];
    if (k === null) {
      list.querySelector(".pyk-empty")?.remove();
      list.append(input);
    } else list.children[k]?.replaceWith(input);
    input.focus();
    let done = false;
    const finish = (keep) => {
      if (done) return;
      done = true;
      const text = input.value.trim();
      if (keep && text !== "") {
        if (k === null) this.watches.push(text);
        else this.watches[k] = text;
      } else if (keep && k !== null) this.watches.splice(k, 1);
      saveList("pyking-playground.watches", this.watches);
      this.renderWatches();
    };
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") finish(true);
      if (event.key === "Escape") finish(false);
    });
    input.addEventListener("blur", () => finish(true));
  }

  /** Enter in the console evaluates what was typed where the program
   *  stopped; Up and Down go through what was typed before.
   *  KeyboardEvent -> Promise<()> */
  async consoleKey(event) {
    const input = this.ui.input;
    if (event.key === "ArrowUp" && this.consoleAt > 0) {
      event.preventDefault();
      this.consoleAt -= 1;
      input.value = this.consoleHistory[this.consoleAt];
      return;
    }
    if (event.key === "ArrowDown" && this.consoleAt < this.consoleHistory.length) {
      event.preventDefault();
      this.consoleAt += 1;
      input.value = this.consoleHistory[this.consoleAt] ?? "";
      return;
    }
    if (event.key !== "Enter") return;
    event.preventDefault();
    const text = input.value.trim();
    if (text === "") return;
    this.consoleHistory.push(text);
    this.consoleAt = this.consoleHistory.length;
    input.value = "";
    this.write(`> ${text}\n`, "echo");
    const answer = await this.evaluate(text);
    if (answer === null) this.write("The program is not stopped.\n", "err");
    else if (answer.ok) this.write(`${answer.value} : ${answer.type}\n`, "value");
    else this.write(answer.text + "\n", "err");
    // What it printed may have changed what the panes show.
    if (this.state === "stopped") await this.chooseFrame(this.frame);
  }

  /** Writes to the console. String -> String? -> () */
  write(text, cls) {
    const span = document.createElement("span");
    if (cls) span.className = cls;
    span.textContent = text;
    const log = this.ui.console;
    log.appendChild(span);
    log.scrollTop = log.scrollHeight;
  }
}

/** A line saying a pane has nothing to show. String -> Element */
function empty(text) {
  const line = document.createElement("div");
  line.className = "pyk-empty";
  line.textContent = text;
  return line;
}

/** A list of strings kept in this browser, or an empty one. String -> [String] */
function loadList(key) {
  try {
    const value = JSON.parse(localStorage.getItem(key));
    return Array.isArray(value) ? value.filter((x) => typeof x === "string") : [];
  } catch {
    return [];
  }
}

function saveList(key, list) {
  try {
    localStorage.setItem(key, JSON.stringify(list));
  } catch { /* not kept beyond the tab */ }
}
