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
// src/web/pyking_web.ml). Nothing else is loaded, and nothing is fetched
// while a program runs.
//
// Protocol. Every request carries an `id` and gets exactly one `result` or
// `error` in reply; `status` and `stdout` may arrive in between, unsolicited.

let loaded = false;

const reply = (id, value) => self.postMessage({ id, type: "result", value });
const fail = (id, message) => self.postMessage({ id, type: "error", message });
const status = (message) => self.postMessage({ type: "status", message });
const stdout = (text) => self.postMessage({ type: "stdout", text });

// Where a running program's output goes: line by line as the program
// produces it, rather than gathered up and returned at the end -- so output
// made *before* a hang is still seen, which is exactly the case worth
// seeing.
self.pykOnPrint = (text) => stdout(text);

self.onmessage = (event) => {
  const message = event.data;
  try {
    switch (message.type) {
      case "init":
        reply(message.id, boot(message));
        break;
      case "compile":
        // A JSON string, which crosses postMessage as-is.
        reply(message.id, JSON.parse(
          self.pykCompile(message.source, message.target, message.name)));
        break;
      case "run":
        // The name travels on the first line, ahead of the program: one
        // string in, so the boundary stays one primitive wide.
        reply(message.id, JSON.parse(
          self.pykRun(message.name + "\n" + message.source)));
        break;
      default:
        fail(message.id, `unknown request '${message.type}'`);
    }
  } catch (err) {
    fail(message.id, err && err.message ? err.message : String(err));
  }
};

function boot({ pykingURL }) {
  if (loaded) return { stamp: self.pykStamp ?? null };
  status("loading compiler");
  const manifest = fetchJSONSync(pykingURL + "manifest.json");
  self.importScripts(pykingURL + manifest.bundle);
  if (typeof self.pykCompile !== "function") {
    throw new Error("the compiler bundle did not register pykCompile");
  }
  loaded = true;
  self.pykStamp = manifest.stamp ?? null;
  status("ready");
  // Which compiler this worker is running, so the page can tell when the
  // one on disk has moved on (PykingRuntime, `_checkStamp`).
  return { stamp: self.pykStamp };
}

// Synchronous on purpose: `importScripts` is synchronous too, and the boot
// has nothing to interleave with. A worker may block; the page may not.
function fetchJSONSync(url) {
  const request = new XMLHttpRequest();
  request.open("GET", url, false);
  request.send(null);
  if (request.status !== 200 && request.status !== 0) {
    throw new Error(`cannot fetch ${url}: ${request.status}`);
  }
  return JSON.parse(request.responseText);
}
