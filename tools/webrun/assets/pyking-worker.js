// The Pyking compiler, and any Pyking it runs -- all on a thread of its own.
//
// This exists for one reason: a program that never terminates. The compiler
// on the main thread would freeze the whole tab, including the button you
// would use to stop it, and no amount of care in the UI can recover from
// that. On a worker the page stays responsive and `terminate()` reclaims
// everything immediately -- which is the only stop that works against a loop
// that is not checking for one.
//
// The compiler is one JavaScript file: src/ compiled by js_of_ocaml, which
// registers `pykCompile`, `pykRun` and friends on the global object (see
// src/web/pyking_web.ml). A program that imports the standard library has
// it fetched from lib/ the first time a module is named, and each module
// implemented in JavaScript is imported from its browser implementation --
// except `io` and `sys`, which this worker implements itself: standard
// output is the page's output pane, standard input and the arguments are
// what the page collected before the run, and `sys.exit` ends the run.
//
// Protocol. Every request carries an `id` and gets exactly one `result` or
// `error` in reply; `status`, `stdout`, `debug` and `stdin` may arrive in
// between, unsolicited -- the last is a line the program read, echoed so
// the transcript reads the way a terminal's would.
//
// A library that needs a page -- tinyweb -- posts {type: "page", module,
// data} itself, and the page answers with {type: "event", module, data},
// which carries no `id` and gets no reply: it is handed to that module's
// `pykDeliver`, which calls the functions the program gave it. So a run
// can go on after `run` has answered, until the next run or a stop.
// What a function called that way fails with arrives as `failure`, and a
// `sys.exit` in one as `exit` (docs/libraries.md, "A library that needs
// a page").
//
// `run` may carry `tinywebLog`, and {type: "tinywebLog", on} -- no `id`,
// no reply -- turns it on or off while a run goes on: tinyweb's log, each
// line as `debug`, which is what `pyk --tinyweb-log` prints on stderr.
//
// The language server (src/lsp.ml) lives here too: `lsp` hands it one
// JSON-RPC message and answers the messages it sends back, and `lsp-idle`
// answers what it sends once the client has stopped typing -- the
// diagnostics. Both answer null where the bundle has no `pykLsp`.
//
// So does the playground's REPL (src/repl_session.ml), on a worker of
// its own: `repl` with `action` "start" begins an empty session, "line"
// says whether text is a whole entry and how the next line is indented,
// and "submit" runs one entry, answering {errors, pending, bindings,
// exit?}. What the entry shows -- a value, a command's answer -- arrives
// as `show`, beside `stdout` and `debug`.

let loaded = false;
let libURL = null;
// How many runs there have been, which makes each run's modules fresh
// instances rather than the last run's (`importExternal`); and the
// modules the latest run imported, which a page's event is delivered to.
let runs = 0;
let live = {};

const reply = (id, value) => self.postMessage({ id, type: "result", value });
const fail = (id, message) => self.postMessage({ id, type: "error", message });
const status = (message) => self.postMessage({ type: "status", message });
const stdout = (text) => self.postMessage({ type: "stdout", text });
const debugOut = (text) => self.postMessage({ type: "debug", text });
const stdinEcho = (text) => self.postMessage({ type: "stdin", text });

// Where a running program's output goes: line by line as the program
// produces it, rather than gathered up and returned at the end -- so output
// made *before* a hang is still seen, which is exactly the case worth
// seeing. `debug` goes beside it, marked as what it is.
self.pykOnPrint = (text) => stdout(text);
self.pykOnDebug = (text) => debugOut(text);
self.pykOnShow = (text) => self.postMessage({ type: "show", text });
self.pykOnError = (text) => self.postMessage({ type: "failure", text });
self.pykOnExit = (code) => self.postMessage({ type: "exit", code });
// A browser implementation writes what it has to say to the console --
// that a function is not supported here, say -- and in this worker the
// console is the output pane.
console.log = (...parts) => stdout(parts.join(" ") + "\n");

// The standard library's files, fetched once each: what a program's
// imports read (`pykFetchSource`) and what a `web` compile ships beside the
// program (`pykLibraryFile`). A module named in a program is looked for
// under its own folder, so `io.pyk` and `io_external.pyk` are both
// lib/io/'s.
const library = new Map();

function libraryFile(path) {
  if (library.has(path)) return library.get(path);
  let text = null;
  if (libURL !== null) {
    try {
      text = fetchTextSync(libURL + path);
    } catch {
      text = null;
    }
  }
  library.set(path, text);
  return text;
}

self.pykLibraryFile = (path) => libraryFile(path);
self.pykFetchSource = (name) => {
  const found = /^([A-Za-z_][A-Za-z0-9_]*?)(_external)?\.pyk$/.exec(name);
  return found ? libraryFile(`${found[1]}/${name}`) : null;
};

self.onmessage = (event) => {
  const message = event.data;
  const answer = (work) => {
    try {
      const value = work();
      if (value && typeof value.then === "function") {
        value.then((v) => reply(message.id, v),
                   (err) => fail(message.id, describe(err)));
      } else {
        reply(message.id, value);
      }
    } catch (err) {
      fail(message.id, describe(err));
    }
  };
  switch (message.type) {
    case "init":
      return answer(() => boot(message));
    case "compile":
      // A JSON string, which crosses postMessage as-is.
      // The program is supplied as a run supplies it, so a program that
      // imports compiles against the modules it names.
      return answer(() => {
        supply(message);
        return JSON.parse(
          self.pykCompile(message.source, message.target, message.name));
      });
    case "words":
      // What a page reads out of the compiler rather than keeping a copy
      // of: the words its editor highlights, the targets it offers, and
      // the value formatter generated JavaScript is run with.
      return answer(() => ({
        keywords: JSON.parse(self.pykKeywords()),
        builtins: JSON.parse(self.pykBuiltins()),
        targets: JSON.parse(self.pykTargets()),
        formatHelper: self.pykFormatHelper(),
      }));
    case "analyze":
      return answer(() => analyze(message));
    case "lsp":
      return answer(() => (typeof self.pykLsp === "function"
        ? JSON.parse(self.pykLsp(message.message)) : null));
    case "lsp-idle":
      return answer(() => (typeof self.pykLspIdle === "function"
        ? JSON.parse(self.pykLspIdle()) : null));
    case "run":
      return answer(() => run(message));
    case "repl":
      return answer(() => repl(message));
    case "tinywebLog":
      tinywebLog(message.on);
      return undefined;
    case "event":
      try {
        live[message.module]?.pykDeliver?.(message.data);
      } catch (err) {
        self.pykOnError(describe(err));
      }
      return undefined;
    default:
      return fail(message.id, `unknown request '${message.type}'`);
  }
};

function describe(err) {
  return err && err.message ? err.message : String(err);
}

function boot({ pykingURL, libURL: lib }) {
  libURL = lib ?? new URL("../lib/", pykingURL).href;
  if (loaded) return { stamp: self.pykStamp ?? null };
  status("loading compiler");
  // The manifest is never taken from a cache, and the bundle's URL names
  // its stamp, so a cached copy of an older compiler is never loaded.
  const manifest = JSON.parse(
    fetchTextSync(pykingURL + "manifest.json?t=" + Date.now()));
  const stamp = manifest.stamp ?? null;
  self.importScripts(pykingURL + manifest.bundle +
                     (stamp === null ? "" : "?v=" + encodeURIComponent(stamp)));
  if (typeof self.pykCompile !== "function") {
    throw new Error("the compiler bundle did not register pykCompile");
  }
  loaded = true;
  self.pykStamp = stamp;
  status("ready");
  // Which compiler this worker is running, so the page can tell when the
  // one on disk has moved on (PykingRuntime, `_checkStamp`).
  return { stamp: self.pykStamp };
}

/** The program as the only source the page supplied: everything else it
 *  imports is the standard library, fetched as it is named. */
function supply({ source, name }) {
  self.pykSources = { [name]: source };
}

/** What a program needs before it runs: {ok, externals, stdin, args}, or
 *  a refusal in `compile`'s own shape. */
function analyze(message) {
  supply(message);
  return JSON.parse(self.pykAnalyze(message.name));
}

/** Runs a program with the interpreter. Answers {ok:true, exit?} or a
 *  refusal. Synchronous where the program needs no JavaScript module
 *  imported, so a caller that cannot wait -- the test suite -- need not. */
/** Shows the tinyweb log, or stops showing it: each line as a `debug`
 *  line, which is how the page shows what `pyk --tinyweb-log` prints on
 *  stderr (lib/tinyweb/tinyweb_external_interpreter.js). Bool -> () */
function tinywebLog(on) {
  self.pykTinywebLog = on ? (line) => debugOut(line + "\n") : null;
}

function run(message) {
  tinywebLog(Boolean(message.tinywebLog));
  const analysis = analyze(message);
  if (!analysis.ok) return analysis;
  const mine = own(message);
  const needed = analysis.externals.filter((name) => !(name in mine));
  runs += 1;
  live = {};
  const start = (imported) => {
    live = imported;
    self.pykExternals = { ...imported, ...pick(mine, analysis.externals) };
    supply(message);
    return JSON.parse(self.pykRunProgram(
      message.name + (message.release ? "\nrelease" : "")));
  };
  if (needed.length === 0) return start({});
  return Promise.all(needed.map((name) => importExternal(name)))
    .then((modules) => start(Object.fromEntries(
      needed.map((name, k) => [name, modules[k]]))));
}

// The REPL's modules implemented in JavaScript: the worker's own `io`
// and `sys` -- with nothing to read and no arguments -- and each other
// one as an entry first imports it, kept for the rest of the session.
let replModules = null;

/** One request of the REPL: "start", "line", "complete" or "submit" (see above).
 *  An entry importing tinyweb is refused here: its page is the Run's. */
function repl({ action, text = "" }) {
  if (typeof self.pykReplStart !== "function") {
    throw new Error("this compiler bundle has no REPL: rebuild it with make");
  }
  if (action === "start") {
    replModules = own({ stdin: "", args: [] });
    return JSON.parse(self.pykReplStart());
  }
  if (action === "line") return JSON.parse(self.pykReplLine(text));
  if (action === "complete") return JSON.parse(self.pykReplComplete(text));
  if (replModules === null) replModules = own({ stdin: "", args: [] });
  const needed = JSON.parse(self.pykReplImports(text))
    .filter((name) => !(name in replModules));
  if (needed.includes("tinyweb")) {
    return {
      errors: ["tinyweb draws on a page of its own, so it cannot be imported "
               + "at the REPL: write the program in the editor and press Run."],
      pending: text,
      bindings: null,
    };
  }
  const submit = () => {
    self.pykExternals = replModules;
    return JSON.parse(self.pykReplSubmit(text));
  };
  if (needed.length === 0) return submit();
  return Promise.all(needed.map((name) => importExternal(name)))
    .then((modules) => {
      needed.forEach((name, k) => { replModules[name] = modules[k]; });
      return submit();
    });
}

function pick(table, names) {
  return Object.fromEntries(names.filter((n) => n in table).map((n) => [n, table[n]]));
}

/** A module's implementation for the interpreter, imported from lib/ --
 *  `<name>_external_interpreter.js` where the library has one, and its
 *  browser implementation otherwise; a fresh instance for each run,
 *  since a module keeps what a program gave it. */
function importExternal(name) {
  const at = (kind) => libURL + `${name}/${name}_external_${kind}.js`;
  const kind = existsSync(at("interpreter")) ? "interpreter" : "browser";
  return import(at(kind) + `?run=${runs}`);
}

/** The worker's own `io` and `sys`: the page's output pane for standard
 *  output, the text it collected for standard input, and the arguments it
 *  was given. The rest of `sys` answers as its browser implementation
 *  does -- not supported -- saying so in the pane. */
function own(message) {
  const input = { text: message.stdin ?? "", at: 0 };
  const atEnd = () => input.at >= input.text.length;
  const line = () => {
    if (atEnd()) return "";
    const end = input.text.indexOf("\n", input.at);
    const stop = end < 0 ? input.text.length : end;
    let taken = input.text.slice(input.at, stop);
    input.at = end < 0 ? input.text.length : end + 1;
    if (taken.endsWith("\r")) taken = taken.slice(0, -1);
    return taken;
  };
  const list = (items) => {
    const array = items.slice();
    array.pykList = true;
    return array;
  };
  const unsupported = (what) =>
    stdout(`sys.${what}: not supported in a browser\n`);
  return {
    io: {
      write: (text) => stdout(text),
      write_line: (text) => stdout(text + "\n"),
      prompt_line: (prompt) => {
        stdout(prompt);
        const read = line();
        stdinEcho(read + "\n");
        return read;
      },
      read: () => {
        const rest = input.text.slice(input.at);
        input.at = input.text.length;
        return rest;
      },
      is_eof: () => atEnd(),
    },
    sys: {
      args: () => list(message.args ?? []),
      env: () => { unsupported("env"); return list([]); },
      prog_name: () => { unsupported("prog_name"); return ""; },
      prog_path: () => { unsupported("prog_path"); return ""; },
      exit: (code) => {
        const stop = new Error(`exit ${code}`);
        stop.pykExit = code;
        throw stop;
      },
    },
  };
}

/** Whether the server has a file at url. String -> Bool */
function existsSync(url) {
  const request = new XMLHttpRequest();
  request.open("HEAD", url, false);
  try {
    request.send(null);
  } catch {
    return false;
  }
  return request.status === 200;
}

// Synchronous on purpose: `importScripts` is synchronous too, and neither
// the boot nor an import resolved in the middle of checking a program has
// anything to interleave with. A worker may block; the page may not.
function fetchTextSync(url) {
  const request = new XMLHttpRequest();
  request.open("GET", url, false);
  request.send(null);
  if (request.status !== 200 && request.status !== 0) {
    throw new Error(`cannot fetch ${url}: ${request.status}`);
  }
  return request.responseText;
}
