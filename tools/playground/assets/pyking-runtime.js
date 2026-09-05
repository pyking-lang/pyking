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
    this.workerURL = options.workerURL || "./assets/pyking-worker.js";
    this.worker = null;
    this.pending = new Map();      // request id -> {resolve, reject}
    this.nextId = 1;
    this.onOutput = null;          // set for the duration of a run
    this.onStatus = () => {};
    this._starting = null;
    this._ready = false;
    // Which compiler the worker booted from, so a rebuild under an open
    // tab is noticed rather than silently disagreed with (`_checkStamp`).
    this.stamp = null;
  }

  get isReady() { return this._ready; }

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
    const booted = await this._send("init", { pykingURL: this.pykingURL });
    this.stamp = booted?.stamp ?? null;
    this._ready = true;
    this._starting = null;
    return this;
  }

  _spawn() {
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

  /** Run Pyking source with the interpreter, which is what the language
   *  *means* (docs/interpreter.md): every program the checker accepts runs
   *  here, whatever a target can or cannot compile. `onOutput` is called
   *  with each line as it is printed, so output produced before a hang is
   *  not lost.
   *
   *  Resolves to {ok:true}, or to a refusal in `compile`'s own shape --
   *  {ok:false, text, info?} -- since running compiles first and a program
   *  that does not check is refused the same way either way. */
  async runProgram(source, { onOutput, name = "playground.pyk" } = {}) {
    this._require();
    this.onOutput = onOutput || null;
    try {
      return await this._send("run", { source, name });
    } finally {
      this.onOutput = null;
    }
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

  /** Resolves when the program finishes; rejects if it threw. */
  run(how, code, { onOutput } = {}) {
    this.stop();
    return new Promise((resolve, reject) => {
      // A module worker: the esm target is imported as a real module, which
      // needs dynamic import, which classic workers do not have.
      const worker = new Worker(this.workerURL, { type: "module" });
      this.worker = worker;
      const finish = (fn, value) => {
        if (this.worker === worker) this.worker = null;
        worker.terminate();
        fn(value);
      };
      worker.onmessage = ({ data }) => {
        if (data.type === "stdout") onOutput?.(data.data);
        else if (data.type === "done") finish(resolve, undefined);
        else if (data.type === "failed") finish(reject, new Error(data.data));
      };
      worker.onerror = (event) =>
        finish(reject, new Error(event.message || "worker failed"));
      worker.postMessage({ how, code });
    });
  }

  stop() {
    if (!this.worker) return false;
    this.worker.terminate();
    this.worker = null;
    return true;
  }
}
