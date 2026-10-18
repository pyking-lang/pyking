// The Pyking compiler as a browser object, with no user interface.
//
// Import this on its own to compile or run Pyking from your own page; the
// playground's UI (playground.js) is one consumer of it, not a requirement.
//
//   const rt = new PykingRuntime({ pykingURL, workerURL });
//   await rt.ready(msg => console.log(msg));
//   const result = await rt.compile("print(1)\n", "nodejs");
//
// Everything runs on a worker, so nothing here can lock the page and
// `stop()` can always end a program that will not end itself. The cost is
// that `compile` and `run` are asynchronous -- they cross a thread boundary.
//
// `ready()` loads the compiler, so call it when the user asks for
// something rather than on page load.

export class PykingRuntime {
  constructor(options = {}) {
    // Resolved against the page before it is handed over, because a
    // relative URL inside a worker resolves against the *worker's* URL, not
    // the document's: "./pyking/" sent to a worker living in /assets/ asks
    // for /assets/pyking/. An absolute URL means the worker can sit
    // anywhere without the caller having to know.
    this.pykingURL = absoluteURL(options.pykingURL || "./pyking/");
    // The standard library a program imports from, served beside the
    // compiler bundle.
    this.libURL = absoluteURL(options.libURL || new URL("../lib/", this.pykingURL).href);
    this.workerURL = options.workerURL || "./assets/pyking-worker.js";
    this.worker = null;
    this.pending = new Map();      // request id -> {resolve, reject}
    this.nextId = 1;
    this.onOutput = null;          // set for the duration of a run
    this.onDebug = null;           // likewise, for `debug`
    this.onShow = null;            // what a REPL entry shows, while it runs
    this.onInput = null;           // likewise, for a line the program read
    this.onPage = null;            // likewise, for what a program sends its page
    this.onFailure = null;         // a failure after the run has answered
    this.onExit = null;            // likewise, for a `sys.exit`
    this.onEnd = null;             // called when a live run is let go
    // Whether the latest run sent its page anything, which keeps it live
    // -- its callbacks attached -- after it has answered.
    this._live = false;
    this.onStatus = () => {};
    this._starting = null;
    this._ready = false;
    // Which compiler the worker booted from, so a rebuild under an open
    // tab is noticed rather than silently disagreed with (`_checkStamp`).
    this.stamp = null;
    this._words = null;
    // How many workers have been started. The language server's state
    // lives in the worker, so a client that sees this change opens its
    // documents again.
    this._generation = 0;
  }

  get isReady() { return this._ready; }

  /** Which worker is answering: a number that changes whenever a stop or
   *  a reload replaced it. () -> Int */
  get generation() { return this._generation; }

  /** Boot the worker and load the compiler into it. Safe to call
   *  repeatedly: concurrent callers share one boot, a finished boot returns
   *  at once. */
  ready(onStatus = () => {}) {
    this.onStatus = onStatus;
    if (this._ready) return Promise.resolve(this);
    if (!this._starting) this._starting = this._boot();
    return this._starting;
  }

  async _boot() {
    this._spawn();
    const booted = await this._send("init", {
      pykingURL: this.pykingURL, libURL: this.libURL });
    this.stamp = booted?.stamp ?? null;
    this._ready = true;
    this._starting = null;
    return this;
  }

  _spawn() {
    this._generation += 1;
    this.worker = new Worker(this.workerURL);
    this.worker.onmessage = (event) => this._receive(event.data);
    this.worker.onerror = (event) => {
      const error = new Error(event.message || "worker failed");
      for (const { reject } of this.pending.values()) reject(error);
      this.pending.clear();
    };
  }

  _receive(message) {
    if (message.type === "status") return this.onStatus(message.message);
    if (message.type === "stdout") return this.onOutput?.(message.text);
    if (message.type === "debug") return this.onDebug?.(message.text);
    if (message.type === "show") return this.onShow?.(message.text);
    if (message.type === "stdin") return this.onInput?.(message.text);
    if (message.type === "page") {
      this._live = true;
      return this.onPage?.(message.module, message.data);
    }
    if (message.type === "failure") return this.onFailure?.(message.text);
    if (message.type === "exit") return this.onExit?.(message.code);
    const waiting = this.pending.get(message.id);
    if (!waiting) return;
    this.pending.delete(message.id);
    if (message.type === "error") waiting.reject(new Error(message.message));
    else waiting.resolve(message.value);
  }

  _send(type, payload) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ id, type, ...payload });
    });
  }

  /** Compile Pyking source. Resolves to {ok:true, files:{name: text},
   *  views:[name]} or {ok:false, stage, message, text, info?} -- a refused
   *  program is data, not an exception. Rejects only if the worker itself
   *  failed.
   *
   *  Pyking is statically typed, so a program that does not check is
   *  refused here whatever target was asked for -- there is no flag. */
  async compile(source, target, name = "playground.pyk") {
    this._require();
    await this._checkStamp();
    return this._send("compile", { source, target, name });
  }

  /** The compiler's own word lists and targets, and the source of the
   *  JavaScript value formatter: {keywords, builtins, targets,
   *  formatHelper}. Asked once and remembered, since they cannot change
   *  without the compiler changing. */
  async words() {
    this._require();
    if (!this._words) this._words = await this._send("words", {});
    return this._words;
  }

  /** Hands the language server one JSON-RPC message, a request or a
   *  notification as LSP defines it (an object, or its JSON). Resolves to
   *  the messages the server sends back, responses and notifications --
   *  or to null where the compiler has no language server. Waits for the
   *  compiler rather than refusing before it is loaded.
   *  (Object | String) -> Promise<[Object]?> */
  async lsp(message) {
    await this.ready(this.onStatus);
    const text = typeof message === "string" ? message : JSON.stringify(message);
    return this._send("lsp", { message: text });
  }

  /** What the language server sends once the client is idle: the
   *  diagnostics of the documents a change marked as due. Resolves like
   *  `lsp`. () -> Promise<[Object]?> */
  async lspIdle() {
    await this.ready(this.onStatus);
    return this._send("lsp-idle", {});
  }

  /** Reboot the worker if the compiler on disk is no longer the one it
   *  loaded.
   *
   *  The compiler is fetched once, at boot, and stays in the worker from
   *  then on -- so a tab left open across a rebuild goes on compiling
   *  with the compiler it started with. That is invisible:
   *  the page still answers, and its answer is merely the *previous*
   *  front end's, which is the one kind of wrong output nobody thinks to
   *  doubt. So the manifest carries a stamp of the modules it lists, and
   *  it is re-read here rather than trusted.
   *
   *  Anything that goes wrong is ignored: a deployed build whose manifest
   *  cannot be re-read is not a reason to refuse to compile. */
  async _checkStamp() {
    if (this.stamp === null) return;   // nothing was stamped to compare
    let stamp = null;
    try {
      const response = await fetch(this.pykingURL + "manifest.json",
                                   { cache: "no-store" });
      if (!response.ok) return;
      ({ stamp = null } = await response.json());
    } catch {
      return;
    }
    if (stamp === null || stamp === this.stamp) return;
    this.onStatus("the compiler changed on disk — reloading it");
    await this._reload();
  }

  /** Throw away the worker and boot a fresh one, which re-fetches the
   *  compiler. Unlike `stop()` this is not an interruption: it waits for
   *  the replacement to be ready, so whatever asked for it can carry on. */
  async _reload() {
    if (this.worker) this.worker.terminate();
    this.worker = null;
    this._ready = false;
    this._starting = null;
    for (const { reject } of this.pending.values()) {
      reject(new Error("the compiler was reloaded"));
    }
    this.pending.clear();
    this.onOutput = null;
    await this.ready(this.onStatus);
  }

  /** What a program needs before it is run: {ok:true, externals, stdin,
   *  args} -- the modules it reaches that are implemented in JavaScript,
   *  and whether what it uses reads standard input or its arguments -- or
   *  a refusal in `compile`'s own shape. What a page asks to know whether
   *  to ask for either. */
  async analyze(source, name = "playground.pyk") {
    this._require();
    return this._send("analyze", { source, name });
  }

  /** Run Pyking source with the interpreter, which is what the language
   *  *means* (docs/interpreter.md): every program the checker accepts runs
   *  here, whatever a target can or cannot compile. `onOutput` is called
   *  with each piece of output as it is written, so output produced
   *  before a hang is not lost; `onDebug` with each `debug` line, and
   *  `onInput` with each line the program read. `stdin` is what the
   *  program reads, and `args` what `sys.args()` answers.
   *
   *  Resolves to {ok:true, exit?} -- `exit` being the status `sys.exit`
   *  ended the run with -- or to a refusal in `compile`'s own shape,
   *  {ok:false, text, info?}, since running compiles first and a program
   *  that does not check is refused the same way either way. */
  async runProgram(source, {
    onOutput, onDebug, onInput, onPage, onFailure, onExit, onEnd,
    name = "playground.pyk", stdin = "", args = [], release = false, tinywebLog = false,
  } = {}) {
    this._require();
    this.endLive();
    this.onOutput = onOutput || null;
    this.onDebug = onDebug || null;
    this.onInput = onInput || null;
    this.onPage = onPage || null;
    this.onFailure = onFailure || null;
    this.onExit = onExit || null;
    this._live = false;
    try {
      return await this._send("run", { source, name, stdin, args, release, tinywebLog });
    } finally {
      // A program that sent its page something goes on after answering
      // -- the page calls back the functions it gave it -- so it keeps
      // its callbacks until the next run, `endLive` or `stop`.
      if (this._live) this.onEnd = onEnd || null;
      else this._detach();
    }
  }

  /** The REPL (src/repl_session.ml), kept in this worker between calls.
   *  `replStart()` begins an empty session and resolves to {bindings};
   *  `replLine(text)` to {complete, continuable, indent}, which is how a
   *  page decides what Enter does; `replSubmit(text, handlers)` runs one
   *  entry -- Pyking or a `:` command -- calling `onOutput` with what it
   *  prints, `onShow` with what it shows and `onDebug` with its `debug`
   *  lines, and resolves to {errors, pending, bindings, exit?}, `pending`
   *  being text to put back in the prompt and `bindings` null where they
   *  did not change. A page gives the REPL a runtime of its own, so a
   *  stop ends the session and nothing else. */
  async replStart() {
    this._require();
    return this._send("repl", { action: "start" });
  }
  async replLine(text) {
    this._require();
    return this._send("repl", { action: "line", text });
  }
  /** What Tab offers at column `col` of `line`: {start, items}, each
   *  item {label, detail?} (Repl_session.completions). */
  async replComplete(line, col) {
    this._require();
    return this._send("repl", { action: "complete", text: `${col}\n${line}` });
  }
  async replSubmit(text, { onOutput, onShow, onDebug } = {}) {
    this._require();
    this.onOutput = onOutput || null;
    this.onShow = onShow || null;
    this.onDebug = onDebug || null;
    try {
      return await this._send("repl", { action: "submit", text });
    } finally {
      this._detach();
    }
  }

  /** Whether the latest run is still live: it sent its page something,
   *  and nothing has let it go since. () -> Bool */
  get isLive() { return this._live; }

  /** Hands an event to the live run's `module`, as its page reports one:
   *  {ev: "click", id} and the rest (docs/libraries.md, "A library that
   *  needs a page"). String -> Object -> () */
  sendEvent(module, data) {
    if (this._live && this.worker) this.worker.postMessage({ type: "event", module, data });
  }

  /** Whether the running program's tinyweb log is shown, as `debug`
   *  lines: what `pyk --tinyweb-log` prints on stderr. Bool -> () */
  setTinywebLog(on) {
    if (this.worker) this.worker.postMessage({ type: "tinywebLog", on });
  }

  /** Lets the live run go: its callbacks are detached and its `onEnd`
   *  called, so its page can stop asking for events. () -> () */
  endLive() {
    const onEnd = this.onEnd;
    const wasLive = this._live;
    this._detach();
    if (wasLive) onEnd?.();
  }

  _detach() {
    this._live = false;
    this.onOutput = null;
    this.onDebug = null;
    this.onShow = null;
    this.onInput = null;
    this.onPage = null;
    this.onFailure = null;
    this.onExit = null;
    this.onEnd = null;
  }

  /** End whatever is running, immediately.
   *
   *  `terminate()` rather than a cooperative interrupt, because the case
   *  that matters is a loop that is not cooperating: it reclaims the thread
   *  and its memory whatever the interpreter was doing. The cost is the
   *  loaded compiler, so a replacement is started straight away and is
   *  usually warm again before the next run is asked for.
   */
  stop() {
    this.endLive();
    if (!this.worker) return false;
    this.worker.terminate();
    this.worker = null;
    this._ready = false;
    this._starting = null;
    for (const { reject } of this.pending.values()) {
      reject(new Error("stopped"));
    }
    this.pending.clear();
    this.onOutput = null;
    // Re-boot in the background; failures surface on the next real request.
    this._starting = this._boot().catch(() => { this._starting = null; });
    return true;
  }

  _require() {
    if (!this._ready) throw new Error("PykingRuntime: call ready() first");
  }
}

/** A URL made absolute against the current page.
 *
 *  Anything already absolute is returned unchanged, so this is safe to
 *  apply to every URL the runtime is given. */
function absoluteURL(url) {
  const base = (typeof document !== "undefined" && document.baseURI)
    || (typeof location !== "undefined" && location.href);
  return base ? new URL(url, base).href : url;
}

/** Runs generated JavaScript on its own worker.
 *
 *  Separate from the compiler's worker because it has nothing to do with
 *  Pyking, and separate from an iframe because an iframe is not reliably a
 *  separate thread -- a same-process frame shares the main one, so a loop
 *  inside it can still lock the page. Only the `html` target still needs a
 *  frame, and that is because it *is* a page.
 */
export class JsRunner {
  constructor(workerURL = "./assets/js-worker.js") {
    this.workerURL = workerURL;
    this.worker = null;
  }

  get isRunning() { return this.worker !== null; }

  /** Runs a compiled program. `code` is the module being looked at,
   *  `files` the whole program the compiler wrote and `main` which of
   *  them `code` is -- the worker wires them together and imports it.
   *  `formatHelper` is the compiler's value formatter (`words()`).
   *  Resolves when the program finishes; rejects if it threw. */
  run(code, { files = {}, main, onOutput, onDebug, formatHelper = "" } = {}) {
    this.stop();
    return new Promise((resolve, reject) => {
      // A module worker: generated code is imported as a real module,
      // which needs dynamic import, which classic workers do not have.
      const worker = new Worker(this.workerURL, { type: "module" });
      this.worker = worker;
      const finish = (fn, value) => {
        if (this.worker === worker) this.worker = null;
        worker.terminate();
        fn(value);
      };
      worker.onmessage = ({ data }) => {
        if (data.type === "stdout") onOutput?.(data.data);
        else if (data.type === "debug") (onDebug ?? onOutput)?.(data.data);
        else if (data.type === "done") finish(resolve, undefined);
        else if (data.type === "failed") finish(reject, new Error(data.data));
      };
      worker.onerror = (event) =>
        finish(reject, new Error(event.message || "worker failed"));
      worker.postMessage({ code, files, main, formatHelper });
    });
  }

  stop() {
    if (!this.worker) return false;
    this.worker.terminate();
    this.worker = null;
    return true;
  }
}
