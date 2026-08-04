#!/usr/bin/env python3
"""Builds the Pyking playground: a static web page that runs the real
compiler in the browser under Pyodide, with no server-side execution.

Nothing under `build/` is checked in. This file is the single source for
every generated artifact -- the page, the stylesheet, both JavaScript
modules, the Ace syntax mode for Pyking, the browser-side compiler shim,
and the copies of the compiler and the example programs. Run it through
`make`, or directly:

    python3 generator.py vendor     download Ace + Pyodide into vendor/
    python3 generator.py build      generate build/
    python3 generator.py check      compile every example, headless
    python3 generator.py serve      serve build/ and print the URL

Three things are read out of the repository rather than restated here, so
that the playground cannot drift from the compiler it ships:

  - the compiler modules themselves, copied from `src/` (minus
    `pykboot.py`, which is the CLI driver and the only module that touches
    the filesystem);
  - the keyword list in `src/lexer.py` and the builtin list in
    `src/analyses.py`, which become the Ace highlighting mode;
  - `tests/*.pyk` and `tests/test_cases.toml`, which become the example
    dropdown and the per-example record of which targets accept it.

The target list is likewise imported from the backends, so adding a target
to the compiler adds it to the playground.
"""

import argparse
import functools
import http.server
import json
import re
import shutil
import socket
import socketserver
import sys
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SRC_DIR = REPO / "src"
TESTS_DIR = REPO / "tests"
BUILD = HERE / "build"
VENDOR = HERE / "vendor"

sys.path.insert(0, str(SRC_DIR))
import target_c                                          # noqa: E402
import target_java                                       # noqa: E402
import target_js_packaging                               # noqa: E402

# --- what we vendor -------------------------------------------------------

ACE_VERSION = "1.43.4"
PYODIDE_VERSION = "0.28.3"
ACE_CDN = f"https://cdn.jsdelivr.net/npm/ace-builds@{ACE_VERSION}/src-min-noconflict"
PYODIDE_CDN = f"https://cdn.jsdelivr.net/pyodide/v{PYODIDE_VERSION}/full"

# Only the modes the target list actually needs, plus the search box. Ace
# loads modes lazily from its basePath, so these must sit beside ace.js.
ACE_FILES = [
    "ace.js",
    "ext-searchbox.js",
    "mode-python.js",
    "mode-javascript.js",
    "mode-c_cpp.js",
    "mode-java.js",
    "mode-html.js",
    "theme-tomorrow_night.js",
]

# The `pyodide-core` set: enough to start CPython and import the stdlib.
# No scientific packages -- the compiler needs `dataclasses` and `re`.
PYODIDE_FILES = [
    "pyodide.js",
    "pyodide.asm.js",
    "pyodide.asm.wasm",
    "python_stdlib.zip",
    "pyodide-lock.json",
]

# --- the compiler, and what each target means to the page -----------------

COMPILER_SKIP = {"pykboot.py"}

# Which Ace mode highlights each target's output, and how (or whether) the
# browser can execute it. `c89`/`c23`/`java*` are display-only: there is no
# C compiler or JVM in a browser, which is a property of the target, not a
# shortcoming of the playground.
TARGET_MODE = {
    "ast": "text",
    "python": "python",
    "nodejs": "javascript",
    "esm": "javascript",
    "html": "html",
    "c89": "c_cpp",
    "c23": "c_cpp",
    "java8": "java",
    "java17": "java",
    "java21": "java",
}
TARGET_RUN = {
    "python": "python",   # executed by Pyodide
    "nodejs": "script",   # inlined into a sandboxed iframe as a classic script
    "esm": "module",      # inlined as a module, then driven with a `runtime`
    "html": "page",       # already a whole page: rendered in the preview frame
}
TARGET_LABEL = {
    "ast": "AST (target-independent)",
    "python": "Python",
    "nodejs": "JavaScript - node",
    "esm": "JavaScript - ES module",
    "html": "JavaScript - HTML page",
    "c89": "C89",
    "c23": "C23",
    "java8": "Java 8",
    "java17": "Java 17",
    "java21": "Java 21",
}


def js_value_formatter():
    """The `pykFormat` the JavaScript backend generates for every host it
    packages, lifted straight out of the backend.

    The playground's JS worker drives the `esm` target's `run(runtime)` and
    so has to supply `print`, which means formatting values -- and how a
    value prints is fixed by `src/runtime_interface.py`, not chosen per host.
    Reading the backend's own copy is the only way to be sure the playground
    agrees with `node prog.js`; a hand-written copy silently disagreed the
    moment booleans stopped printing capitalised."""
    formatter = getattr(target_js_packaging, "_FORMAT_JS", None)
    if not formatter or "pykFormat" not in formatter:
        raise SystemExit(
            "generator.py: could not read `_FORMAT_JS` from "
            "src/target_js_packaging.py -- the JavaScript backend's value "
            "formatter has moved or been renamed. Point js_value_formatter() "
            "at it again rather than hand-copying the rule."
        )
    return formatter


def compiler_modules():
    return sorted(
        p.name for p in SRC_DIR.glob("*.py") if p.name not in COMPILER_SKIP
    )


def target_order():
    """Every target the compiler has, in the order the dropdown shows them,
    with `ast` first because it is the one view that is target-independent."""
    names = (
        ["ast", "python"]
        + list(target_js_packaging.TARGETS)
        + list(target_c.STANDARDS)
        + list(target_java.VERSIONS)
    )
    missing = [n for n in names if n not in TARGET_MODE]
    if missing:
        raise SystemExit(
            f"generator.py: target(s) {missing} exist in the compiler but have "
            "no entry in TARGET_MODE/TARGET_LABEL -- add them here."
        )
    return names


def read_list_literal(path, name):
    """The string entries of a simple `name = [...]` list literal in a source
    file. Used to lift the lexer's keywords and the analyses' builtins into
    the editor mode, so highlighting cannot fall out of step the way
    `tools/emacs/pyking-mode.el` warns its own keyword list can."""
    text = path.read_text()
    match = re.search(rf"^{name}\s*=\s*\((.*?)\)|^{name}\s*=\s*\[(.*?)\]",
                      text, re.S | re.M)
    if match is None:
        raise SystemExit(f"generator.py: no `{name} = [...]` found in {path}")
    body = match.group(1) or match.group(2)
    return re.findall(r'"([^"]+)"|\'([^\']+)\'', body) and [
        a or b for a, b in re.findall(r'"([^"]+)"|\'([^\']+)\'', body)
    ]


# ==========================================================================
# Generated artifact: the browser-side compiler API
# ==========================================================================

PYKING_WEB_PY = '''"""The browser-side entry point to the Pyking compiler.

`src/pykboot.py` is a script: it reads argv, opens files and calls
`sys.exit`, none of which a web page can use. This module is the same
sequence of stages exposed as two plain functions that take and return
values, so JavaScript (or a test) can call them directly.

Generated by tools/playground/generator.py -- do not edit here.
"""

import json
import traceback

from analyses import analyze_program, symbolize, AnalysisError
from lexer import lexing, pprint_info, LexError
from parser import parse, ParseError
from syntax import pprint_program
import target_c
import target_java
import target_js_core
import target_js_packaging
import typesystem
from target_python import translate_program, pprint_py_program


def _fail(exc, stage):
    """A compile error as data: the formatted line the CLI would print, plus
    the raw span so the editor can underline it. Rows are 1-based and columns
    0-based, exactly as `lexer.Info` records them."""
    info = getattr(exc, "info", None)
    out = {
        "ok": False,
        "stage": stage,
        "message": exc.message,
        "text": (f"{pprint_info(info)} {stage}: {exc.message}"
                 if info is not None else f"{stage}: {exc.message}"),
    }
    if info is not None:
        out["info"] = {
            "row1": info.row1, "col1": info.col1,
            "row2": info.row2, "col2": info.col2,
        }
    return out


def compile_source(text, target="python", name="playground.pyk",
                   typecheck=False, ast=False):
    """Compile Pyking `text` for `target`.

    Returns `{"ok": True, "files": {label: source}, "views": [label, ...]}`
    -- several files for `esm`, which really does emit four -- or
    `{"ok": False, ...}` as built by `_fail`. Never raises for a bad
    program, and never touches the filesystem.

    Both flags are `pyk`'s own, and mean what they mean there: `typecheck`
    runs `src/typesystem.py` (and, exactly as in `src/pykboot.py`,
    *replaces* the name analysis with it), and `ast` stops after the front
    end and yields the pretty-printed Pyking AST whatever `target` says.

    What the CLI prints to stdout becomes a file here, since the page shows
    generated files rather than a terminal. Such a file is listed in
    `views`: it is what the front end *saw*, not code any host could run,
    and the page uses that to keep its Run button honest.
    """
    try:
        program = parse(lexing(name, list(text)))
    except LexError as e:
        return _fail(e, "Lexing error")
    except ParseError as e:
        return _fail(e, "Parsing error")

    # `--typecheck` stands in for the name analysis rather than following
    # it: the checker carries a name environment of its own (see
    # src/typesystem.py), and src/pykboot.py makes the same choice.
    if not typecheck:
        try:
            analyze_program(program)
        except AnalysisError as e:
            return _fail(e, "Name error")

    program = symbolize(program)
    tmap = None
    if typecheck:
        try:
            tmap = typesystem.type_check(program)
        except typesystem.TypeError_ as e:
            return _fail(e, "Type error")

    stem = name.rsplit(".", 1)[0]

    def done(files, views=()):
        return {"ok": True, "files": files, "views": list(views)}

    try:
        if ast or target == "ast":
            # Target-independent: this is the AST every backend starts
            # from. Printed against `tmap` when there is one, so what it
            # shows is what the checker inferred (see pprint_program).
            out = stem + ".ast"
            return done({out: pprint_program(program, tmap=tmap)}, [out])

        if target == "python":
            source = pprint_py_program(translate_program(program))
            return done({stem + ".py": source + "\\n"})

        if target in target_js_packaging.TARGETS:
            js = target_js_core.translate_program(program)
            out = stem + target_js_packaging.PRIMARY_EXTENSIONS[target]
            return done(target_js_packaging.package(target, js, name, out))

        if target in target_c.STANDARDS:
            c = target_c.translate_program(program)
            return done({stem + ".c": target_c.pprint_c_program(c, target, name)})

        if target in target_java.VERSIONS:
            # Java requires the file and its public class to share a name.
            cls = target_java.default_class_name(stem)
            j = target_java.translate_program(program)
            return done({
                cls + ".java": target_java.pprint_java_program(j, target, cls, name)})

    except (target_js_core.UnsupportedError,
            target_c.UnsupportedError,
            target_java.UnsupportedError) as e:
        # Each backend raises its own UnsupportedError class; all three carry
        # an Info, so all three underline in the editor like any other error.
        return _fail(e, f"Unsupported by target '{target}'")

    return {"ok": False, "stage": "Usage error",
            "message": f"unknown target '{target}'",
            "text": f"Usage error: unknown target '{target}'"}


def compile_json(text, target="python", name="playground.pyk",
                 typecheck=False, ast=False):
    """`compile_source` as a JSON string.

    The worker that calls this crosses a `postMessage` boundary, and a string
    goes across it directly -- no `PyProxy` to convert and then remember to
    destroy on both the success and the failure path."""
    return json.dumps(compile_source(text, target, name, typecheck, ast))


def run_python(code):
    """Execute generated Python. Returns a JSON string: `{"ok": true}`, or
    the traceback if it raised.

    Deliberately does *not* capture stdout. The host installs its own (in the
    browser, Pyodide's `setStdout`), so output is delivered line by line as
    it is produced rather than all at once at the end -- which is what makes
    a program's output visible even when it then fails to terminate.
    """
    try:
        exec(compile(code, "<generated>", "exec"), {"__name__": "__main__"})
    except BaseException:
        return json.dumps({"ok": False, "traceback": traceback.format_exc()})
    return json.dumps({"ok": True})


TARGETS = (("ast", "python")
           + target_js_packaging.TARGETS
           + target_c.STANDARDS
           + target_java.VERSIONS)
'''


# ==========================================================================
# Generated artifact: the Ace mode for Pyking
# ==========================================================================

PYKING_MODE_JS = r'''// Ace syntax mode for Pyking.
//
// Generated by tools/playground/generator.py. The keyword and builtin lists
// below are lifted out of src/lexer.py and src/analyses.py at build time, so
// they cannot drift from the language the way a hand-maintained copy would.
//
// Indentation follows PYKING.md: exact 4-space steps, one level deeper after
// a line that opens a block -- a `:` header, or a binding whose value is
// missing from the line (`x =` / `def f(a) =`, the value form).

ace.define("ace/mode/pyking_highlight_rules", [], function (require, exports) {
  "use strict";
  var oop = require("../lib/oop");
  var TextHighlightRules =
    require("./text_highlight_rules").TextHighlightRules;

  var keywords = "%%KEYWORDS%%";
  var types = "%%TYPES%%";
  var builtins = "%%BUILTINS%%";

  var PykingHighlightRules = function () {
    var keywordMapper = this.createKeywordMapper({
      "keyword": keywords,
      "storage.type": types,
      "support.function": builtins
    }, "identifier");

    this.$rules = {
      start: [
        { token: "comment", regex: "#.*$" },
        // Strings: both quote forms, with the backslash escapes scan_string
        // decodes. An unterminated literal is marked invalid rather than
        // swallowing the rest of the file.
        { token: "string", regex: "'(?:[^'\\\\]|\\\\.)*'" },
        { token: "string", regex: '"(?:[^"\\\\]|\\\\.)*"' },
        { token: "string.invalid", regex: "['\"].*$" },
        { token: "constant.numeric", regex: "\\b\\d+\\b" },
        // `def name` -- colour the name being defined, not just the keyword.
        { token: ["keyword", "text", "entity.name.function"],
          regex: "(\\bdef\\b)(\\s+)([A-Za-z_][A-Za-z_0-9]*)" },
        // Mutation and the arrow forms first: ':=' must not lex as ':' + '='.
        { token: "keyword.operator", regex: ":=|->|\\.\\.|==|<=|>=|<|>|\\+|-|\\*|/|=" },
        { token: keywordMapper, regex: "\\b[A-Za-z_][A-Za-z_0-9]*\\b" },
        { token: "paren.lparen", regex: "[\\[({]" },
        { token: "paren.rparen", regex: "[\\])}]" },
        { token: "punctuation", regex: "[,:]" },
        { token: "text", regex: "\\s+" }
      ]
    };
    this.normalizeRules();
  };
  oop.inherits(PykingHighlightRules, TextHighlightRules);
  exports.PykingHighlightRules = PykingHighlightRules;
});

ace.define("ace/mode/pyking", [], function (require, exports) {
  "use strict";
  var oop = require("../lib/oop");
  var TextMode = require("./text").Mode;
  var PykingHighlightRules =
    require("./pyking_highlight_rules").PykingHighlightRules;

  // A line opens a block when it ends in ':' (a header) or in '=' with no
  // value after it (the value form, whose body sits on the following lines).
  var OPENS_BLOCK = /(:|=)\s*(#.*)?$/;
  // Lines that close one level as you type them.
  var OUTDENT = /^\s*(else|case)\b/;

  var Mode = function () {
    this.HighlightRules = PykingHighlightRules;
    this.lineCommentStart = "#";
    this.$id = "ace/mode/pyking";
  };
  oop.inherits(Mode, TextMode);

  (function () {
    this.getNextLineIndent = function (state, line, tab) {
      var indent = this.$getIndent(line);
      if (OPENS_BLOCK.test(line)) indent += tab;
      return indent;
    };

    this.checkOutdent = function (state, line, input) {
      return input === ":" && OUTDENT.test(line + input);
    };

    this.autoOutdent = function (state, session, row) {
      if (row === 0) return;
      var line = session.getLine(row);
      var indent = this.$getIndent(line);
      var tabSize = session.getTabSize();
      if (indent.length < tabSize) return;
      session.remove(new (require("../range").Range)(
        row, indent.length - tabSize, row, indent.length));
    };
  }).call(Mode.prototype);

  exports.Mode = Mode;
});
'''


# ==========================================================================
# Generated artifact: the worker the compiler and Python run inside
# ==========================================================================

PYKING_WORKER_JS = r'''// Pyodide, the Pyking compiler, and any Python they run -- all on a thread
// of their own. Generated by tools/playground/generator.py.
//
// This exists for one reason: a program that never terminates. Pyodide on the
// main thread would freeze the whole tab, including the button you would use
// to stop it, and no amount of care in the UI can recover from that. On a
// worker the page stays responsive and `terminate()` reclaims everything
// immediately -- which is the only stop that works against a loop that is
// not checking for one.
//
// Protocol. Every request carries an `id` and gets exactly one `result` or
// `error` in reply; `status` and `stdout` may arrive in between, unsolicited.

let pyodide = null;
let api = null;

const reply = (id, value) => self.postMessage({ id, type: "result", value });
const fail = (id, message) => self.postMessage({ id, type: "error", message });
const status = (message) => self.postMessage({ type: "status", message });
const stdout = (text) => self.postMessage({ type: "stdout", text });

self.onmessage = async (event) => {
  const message = event.data;
  try {
    switch (message.type) {
      case "init":
        await boot(message);
        reply(message.id, true);
        break;
      case "compile":
        // A JSON string, not a PyProxy: it crosses postMessage as-is. The
        // flags go over as plain booleans for the same reason -- an object
        // would arrive in Python as a PyProxy to convert and destroy.
        reply(message.id, JSON.parse(
          api.compile_json(message.source, message.target, message.name,
                           !!message.typecheck, !!message.ast)));
        break;
      case "run":
        reply(message.id, JSON.parse(api.run_python(message.code)));
        break;
      default:
        fail(message.id, `unknown request '${message.type}'`);
    }
  } catch (err) {
    fail(message.id, err && err.message ? err.message : String(err));
  }
};

async function boot({ pyodideIndexURL, pykingURL }) {
  status("downloading Python (~12 MB, first load only)");
  self.importScripts(pyodideIndexURL + "pyodide.js");
  pyodide = await self.loadPyodide({ indexURL: pyodideIndexURL });

  // Line by line as the program produces it, rather than gathered up and
  // returned at the end -- so output that happened *before* a hang is still
  // seen, which is exactly the case worth seeing.
  pyodide.setStdout({ batched: (line) => stdout(line + "\n") });
  pyodide.setStderr({ batched: (line) => stdout(line + "\n") });

  status("loading compiler");
  const manifest = await fetchJSON(pykingURL + "manifest.json");
  const sources = await Promise.all(manifest.modules.map(async (name) => {
    const response = await fetch(pykingURL + name);
    if (!response.ok) throw new Error(`cannot fetch ${name}: ${response.status}`);
    return [name, await response.text()];
  }));

  // `src/` is a flat set of script modules, not a package, so the compiler is
  // mounted on one directory and put on sys.path -- what running
  // `python3 src/pykboot.py` does natively.
  pyodide.FS.mkdirTree("/pyking");
  for (const [name, text] of sources) {
    pyodide.FS.writeFile("/pyking/" + name, text);
  }
  pyodide.runPython(`import sys; sys.path.insert(0, "/pyking")`);
  api = pyodide.pyimport("pyking_web");
  status("ready");
}

async function fetchJSON(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`cannot fetch ${url}: ${response.status}`);
  return response.json();
}
'''


# ==========================================================================
# Generated artifact: the worker generated JavaScript runs inside
# ==========================================================================

JS_WORKER_JS = r'''// Runs generated JavaScript on a thread of its own, for the same reason the
// Python one exists: so a program that never returns can be stopped.
// Generated by tools/playground/generator.py.
//
// A sandboxed iframe was the obvious alternative and is not good enough: a
// same-process frame shares the main thread, so an endless loop inside one
// can still lock the page. A worker is guaranteed to be a separate thread
// and `terminate()` is guaranteed to end it.
//
// Two shapes of generated code arrive here, and neither is modified on the
// way in:
//   "script" -- the `nodejs` target, a plain script that prints through
//               `console.log`, so `console.log` is what gets redirected;
//   "module" -- the `esm` target, which exports `run(runtime)` and is handed
//               a `print` implementing the runtime interface's formatting.

const send = (type, data) => self.postMessage({ type, data });

// The `esm` target hands its `print` to whoever drives it, so this worker
// has to do the formatting -- and formatting is fixed by the language, not
// chosen by the host (src/runtime_interface.py). The function below is not
// written here: it is lifted verbatim out of src/target_js_packaging.py at
// build time, so it cannot drift from what the compiler generates for every
// other JavaScript host. A hand-copy did drift, which is why it no longer
// is one.
%%PYK_FORMAT%%

self.onmessage = async (event) => {
  const { how, code } = event.data;
  console.log = (...args) => send("stdout", args.join(" ") + "\n");
  console.error = console.log;
  try {
    if (how === "module") {
      // Imported as a real module from a blob, so the source runs exactly as
      // written -- `export` and all -- with no rewriting to make it fit.
      const url = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
      try {
        const module = await import(url);
        if (typeof module.run !== "function") {
          throw new Error("the generated module does not export run(runtime)");
        }
        module.run({
          print: (...values) => send("stdout", values.map(pykFormat).join(" ") + "\n"),
        });
      } finally {
        URL.revokeObjectURL(url);
      }
    } else {
      // Indirect eval, so the generated declarations land in the global
      // scope the generated code expects.
      (0, eval)(code);
    }
    send("done");
  } catch (err) {
    send("failed", err && err.message ? err.message : String(err));
  }
};
'''


# ==========================================================================
# Generated artifact: the headless runtime (no UI)
# ==========================================================================

PYKING_RUNTIME_JS = r'''// The Pyking compiler as a browser object, with no user interface.
//
// Import this on its own to compile or run Pyking from your own page; the
// playground's UI (playground.js) is one consumer of it, not a requirement.
// Generated by tools/playground/generator.py.
//
//   const rt = new PykingRuntime({ pyodideIndexURL, pykingURL, workerURL });
//   await rt.ready(msg => console.log(msg));
//   const result = await rt.compile("print(1)\n", "nodejs");
//
// Everything runs on a worker, so nothing here can lock the page and
// `stop()` can always end a program that will not end itself. The cost is
// that `compile` and `run` are asynchronous -- they cross a thread boundary.
//
// `ready()` is where the multi-megabyte Pyodide download happens, so call it
// when the user asks for something, not on page load.

export class PykingRuntime {
  constructor(options = {}) {
    // Resolved against the page before they are handed over, because a
    // relative URL inside a worker resolves against the *worker's* URL, not
    // the document's: "./assets/vendor/pyodide/" sent to a worker living in
    // /assets/ asks for /assets/assets/vendor/pyodide/. Absolute URLs mean
    // the worker can sit anywhere without the caller having to know.
    this.pyodideIndexURL = absoluteURL(options.pyodideIndexURL);
    this.pykingURL = absoluteURL(options.pykingURL || "./pyking/");
    this.workerURL = options.workerURL || "./assets/pyking-worker.js";
    this.worker = null;
    this.pending = new Map();      // request id -> {resolve, reject}
    this.nextId = 1;
    this.onOutput = null;          // set for the duration of a run
    this.onStatus = () => {};
    this._starting = null;
    this._ready = false;
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
    await this._send("init", {
      pyodideIndexURL: this.pyodideIndexURL,
      pykingURL: this.pykingURL,
    });
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
   *  `options` are `pyk`'s own front-end flags -- {typecheck, ast}, both
   *  off unless asked for, so an embedder that ignores them gets exactly
   *  what it got before. */
  async compile(source, target, name = "playground.pyk", options = {}) {
    this._require();
    return this._send("compile", {
      source, target, name,
      typecheck: !!options.typecheck,
      ast: !!options.ast,
    });
  }

  /** Execute generated Python. `onOutput` is called with each line as it is
   *  printed, so output produced before a hang is not lost. */
  async runPython(code, { onOutput } = {}) {
    this._require();
    this.onOutput = onOutput || null;
    try {
      return await this._send("run", { code });
    } finally {
      this.onOutput = null;
    }
  }

  /** End whatever is running, immediately.
   *
   *  `terminate()` rather than a cooperative interrupt, because the case
   *  that matters is a loop that is not cooperating: it reclaims the thread
   *  and its memory whatever the interpreter was doing. The cost is the
   *  Pyodide instance, so a replacement is started straight away and is
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
 *  Anything already absolute (the CDN build's Pyodide, say) is returned
 *  unchanged, so this is safe to apply to every URL the runtime is given. */
function absoluteURL(url) {
  const base = (typeof document !== "undefined" && document.baseURI)
    || (typeof location !== "undefined" && location.href);
  return base ? new URL(url, base).href : url;
}

/** Runs generated JavaScript on its own worker.
 *
 *  Separate from the Pyodide worker because it has nothing to do with
 *  Python, and separate from an iframe because an iframe is not reliably a
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
'''


# ==========================================================================
# Generated artifact: the stylesheet
# ==========================================================================

PLAYGROUND_CSS = r'''/* Pyking playground. Generated by tools/playground/generator.py.
   Everything is scoped under .pyk-playground so the component can be
   dropped into a page that has styles of its own. */

.pyk-playground {
  --pyk-bg: #1d1f21;
  --pyk-panel: #25282c;
  --pyk-edge: #383c42;
  --pyk-text: #e6e6e6;
  --pyk-dim: #9aa0a6;
  --pyk-accent: #7aa2f7;
  --pyk-good: #9ece6a;
  --pyk-bad: #f7768e;
  --pyk-warn: #e0af68;
  --pyk-gutter: 6px;

  display: flex;
  flex-direction: column;
  position: relative;      /* the settings dialog anchors to this box */
  height: 100%;
  min-height: 0;
  box-sizing: border-box;
  background: var(--pyk-bg);
  color: var(--pyk-text);
  font: 14px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
}
.pyk-playground *, .pyk-playground *::before, .pyk-playground *::after {
  box-sizing: inherit;
}

/* --- header --- */
.pyk-header {
  display: flex; align-items: center; gap: .75rem;
  padding: .55rem .9rem;
  border-bottom: 1px solid var(--pyk-edge);
  background: var(--pyk-panel);
  flex: none;
}
.pyk-title { font-weight: 600; letter-spacing: .01em; }
.pyk-title small { color: var(--pyk-dim); font-weight: 400; margin-left: .5rem; }
.pyk-status {
  margin-left: auto; display: flex; align-items: center; gap: .45rem;
  color: var(--pyk-dim); font-size: .85rem;
}
.pyk-dot {
  width: .6rem; height: .6rem; border-radius: 50%;
  background: var(--pyk-dim); flex: none;
}
.pyk-dot.busy { background: var(--pyk-warn); animation: pyk-pulse 1s infinite; }
.pyk-dot.ready { background: var(--pyk-good); }
.pyk-dot.error { background: var(--pyk-bad); }
@keyframes pyk-pulse { 50% { opacity: .3; } }

/* --- two columns, split by a draggable gutter ---
   The split is a custom property rather than a fixed fraction so the drag
   handler only has to set one value, and so `Reset pane sizes` is a single
   removeProperty. */
.pyk-columns {
  flex: 1 1 auto; min-height: 0;
  display: grid;
  grid-template-columns: var(--pyk-col-split, 50%) var(--pyk-gutter) 1fr;
  background: var(--pyk-bg);
}
.pyk-pane {
  display: flex; flex-direction: column; min-width: 0; min-height: 0;
  background: var(--pyk-bg);
}
.pyk-toolbar {
  display: flex; align-items: center; gap: .5rem; flex-wrap: wrap;
  padding: .5rem .7rem;
  background: var(--pyk-panel);
  border-bottom: 1px solid var(--pyk-edge);
  flex: none;
}
.pyk-toolbar .pyk-label {
  font-size: .78rem; text-transform: uppercase; letter-spacing: .08em;
  color: var(--pyk-dim); margin-right: .15rem;
}
.pyk-spacer { flex: 1 1 auto; }

/* --- controls --- */
.pyk-playground button, .pyk-playground select {
  font: inherit; font-size: .86rem;
  color: var(--pyk-text); background: #2f333a;
  border: 1px solid var(--pyk-edge); border-radius: 5px;
  padding: .3rem .6rem; cursor: pointer;
  /* One height for every control in a toolbar. Without it buttons and
     selects differ by a couple of pixels and the row looks unsettled. */
  height: 30px;
}
.pyk-playground select { padding-right: 1.4rem; }
.pyk-playground button:hover:not(:disabled),
.pyk-playground select:hover { border-color: var(--pyk-accent); }
.pyk-playground button:disabled { opacity: .4; cursor: not-allowed; }
.pyk-playground .pyk-primary {
  background: #33406b; border-color: #4a5c95;
  color: #cdd7f5; font-weight: 600;
}
.pyk-playground .pyk-primary:hover:not(:disabled) { filter: brightness(1.12); }
/* Run and Stop occupy the same slot: Stop replaces Run while a program is
   executing, and Run comes back when it ends. They are therefore sized as
   one control -- same min-width, padding and font -- so the swap cannot
   shift the toolbar by a pixel, whichever of the two labels is showing.
   A little larger than the other buttons, being the ones you aim for. */
.pyk-playground .pyk-run, .pyk-playground .pyk-stop {
  display: inline-flex; align-items: center; justify-content: center;
  min-width: 5.25rem;
  gap: .3rem;
  font-weight: 600;
}
.pyk-playground .pyk-run { color: var(--pyk-good); border-color: #3f5136; }
.pyk-playground .pyk-file { height: auto; }   /* the small tab row opts out */
.pyk-playground .pyk-run:hover:not(:disabled) { background: #31402b; }
.pyk-playground .pyk-stop {
  background: #6f2434; border-color: #9a3346;
  color: #ffd6dd;
}
.pyk-playground .pyk-stop:hover:not(:disabled) { filter: brightness(1.12); }

/* --- editors --- */
.pyk-editor { flex: 1 1 auto; min-height: 0; width: 100%; }
.pyk-files {
  display: flex; gap: .3rem; padding: .3rem .7rem; flex: none;
  background: #202327; border-bottom: 1px solid var(--pyk-edge);
  overflow-x: auto;
}
.pyk-files:empty { display: none; }
.pyk-playground .pyk-file {
  font-size: .78rem; padding: .18rem .5rem; border-radius: 4px;
  background: transparent; border: 1px solid transparent;
  color: var(--pyk-dim); white-space: nowrap;
}
.pyk-playground .pyk-file.active { background: #2f333a; color: var(--pyk-text); border-color: var(--pyk-edge); }

/* --- output --- */
.pyk-output-wrap {
  flex: none; height: var(--pyk-out-split, 34%); min-height: 0;
  display: flex; flex-direction: column;
}
.pyk-output-head {
  display: flex; align-items: center; gap: .5rem;
  padding: .35rem .7rem; background: var(--pyk-panel);
  border-bottom: 1px solid var(--pyk-edge); flex: none;
}
.pyk-output {
  flex: 1 1 auto; margin: 0; padding: .5rem .7rem; overflow: auto;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: .82rem; line-height: 1.45; white-space: pre-wrap;
  background: #17191c;
}
.pyk-output.pyk-no-scroll { overflow: hidden; }
.pyk-output .note { color: var(--pyk-dim); }
.pyk-output .err  { color: var(--pyk-bad); }
.pyk-output .good { color: var(--pyk-good); }
.pyk-preview { flex: 1 1 auto; width: 100%; border: 0; background: #fff; }
.pyk-hidden { display: none !important; }

/* --- drag handles between the three panes --- */
.pyk-gutter {
  position: relative; background: var(--pyk-edge); flex: none;
  touch-action: none;          /* the pointer belongs to us, not to scrolling */
}
.pyk-gutter::after {
  /* A 1px line is right to look at and far too thin to grab, so the hit
     area is widened invisibly on both sides. */
  content: ""; position: absolute; inset: -3px; z-index: 1;
}
.pyk-gutter-v { cursor: col-resize; }
.pyk-gutter-h { cursor: row-resize; height: var(--pyk-gutter); }
.pyk-gutter:hover, .pyk-gutter.dragging { background: var(--pyk-accent); }

/* While a drag is in flight the cursor must not flicker as it passes over
   text, and it must not be stolen by the preview iframe -- a pointer that
   enters a cross-origin frame stops reporting to us and the pane sticks. */
.pyk-playground.pyk-dragging { user-select: none; }
.pyk-playground.pyk-dragging iframe { pointer-events: none; }
.pyk-playground.pyk-dragging.dragging-v { cursor: col-resize; }
.pyk-playground.pyk-dragging.dragging-h { cursor: row-resize; }

/* --- settings dialog ---
   Positioned inside the component, not over the whole viewport, so an
   embedding page keeps its own chrome usable and nothing escapes the box
   the host gave us. */
.pyk-playground .pyk-icon {
  padding: .25rem .45rem; line-height: 1; font-size: 1rem;
  background: transparent; border-color: transparent;
}
.pyk-playground .pyk-icon:hover { background: #2f333a; }
.pyk-playground .pyk-settings {
  display: inline-flex; align-items: center; gap: .4rem;
  padding: .3rem .55rem;
  background: transparent; border-color: transparent;
}
.pyk-playground .pyk-settings:hover { background: #2f333a; border-color: var(--pyk-edge); }
/* An inline SVG rather than a glyph: it inherits the text colour, stays
   crisp at any size, and does not depend on the platform having a font
   with the character in it. */
.pyk-settings svg { display: block; flex: none; }
.pyk-modal-backdrop {
  position: absolute; inset: 0; z-index: 20;
  background: rgba(0, 0, 0, .55);
  display: flex; align-items: center; justify-content: center;
}
.pyk-modal {
  background: var(--pyk-panel); color: var(--pyk-text);
  border: 1px solid var(--pyk-edge); border-radius: 8px;
  min-width: 19rem; max-width: 24rem; margin: 1rem;
  box-shadow: 0 14px 44px rgba(0, 0, 0, .55);
}
.pyk-modal-head {
  display: flex; align-items: center; gap: .5rem;
  padding: .6rem .8rem; border-bottom: 1px solid var(--pyk-edge);
}
.pyk-modal-body { padding: .85rem; display: grid; gap: 1rem; }
.pyk-field { display: grid; gap: .4rem; }
.pyk-field > label { font-size: .82rem; color: var(--pyk-dim); }
/* Beats `.pyk-field > label` above, which is for the group heading. */
.pyk-field > label.pyk-check {
  display: flex; align-items: center; gap: .5rem;
  font-size: .86rem; color: var(--pyk-text); cursor: pointer;
}
.pyk-check input { accent-color: var(--pyk-accent); margin: 0; flex: none; }
.pyk-field-row { display: flex; align-items: center; gap: .6rem; }
.pyk-field-row input[type="range"] { flex: 1 1 auto; accent-color: var(--pyk-accent); }
.pyk-value {
  font-family: ui-monospace, monospace; font-size: .82rem;
  min-width: 3.2rem; text-align: right; color: var(--pyk-text);
}
.pyk-hint { font-size: .78rem; color: var(--pyk-dim); margin: 0; }

/* --- the editor marker for a compile error --- */
.pyk-error-marker {
  position: absolute; background: rgba(247, 118, 142, .28);
  border-bottom: 2px solid var(--pyk-bad);
}
.pyk-error-gutter { color: var(--pyk-bad) !important; }

@media (max-width: 900px) {
  /* Stacked: the column gutter has nothing left to split, so it goes away
     rather than sitting in the layout as a dead handle. */
  .pyk-columns {
    grid-template-columns: 1fr;
    grid-template-rows: 1fr var(--pyk-gutter) 1fr;
  }
  .pyk-gutter-v { cursor: row-resize; }
}
'''


# ==========================================================================
# Generated artifact: the UI
# ==========================================================================

PLAYGROUND_JS = r'''// The playground user interface: two editors, a target selector, an example
// selector, and a shared output pane. Generated by
// tools/playground/generator.py.
//
// Embedding this in another page is one call:
//
//   import { mountPlayground } from "./assets/playground.js";
//   mountPlayground(document.getElementById("host"), { base: "./assets" });
//
// Everything it needs (Ace, the Pyking mode, Pyodide, the compiler, the
// examples) is fetched relative to the options below, so the whole build/
// directory can be moved or served from a sub-path unchanged.

import { PykingRuntime, JsRunner } from "./pyking-runtime.js";

const STORAGE_KEY = "pyking-playground.settings";

/** What the settings dialog starts from, before anything saved is layered
 *  over it. The two output switches default on: a pane you cannot scroll
 *  loses what it cannot show, and output that accumulates across runs is
 *  hard to read the newest of. `autoRun` defaults off -- running on every
 *  edit is a preference, and it is the one setting that can start the
 *  multi-megabyte runtime download without an explicit button press.
 *
 *  The last two are `pyk`'s front-end flags -- `--typecheck` and `--ast`
 *  -- and both default off, because each of them changes what compiling
 *  *means*: the first can reject a program every backend would have
 *  accepted (the checker covers only a fragment of the language so far),
 *  and the second replaces the generated code with a view of the front
 *  end. Someone who has not asked for that should get plain
 *  compilation. */
const DEFAULT_SETTINGS = {
  fontSize: 13,
  scrollOutput: true,
  clearOnRun: true,
  autoRun: false,
  typecheck: false,
  printAst: false,
};

/** How long the source has to sit still before an automatic run. Long
 *  enough to finish a word -- half-written code is mostly code that does
 *  not compile, and re-running it per keystroke would say so per keystroke. */
const AUTO_RUN_DELAY = 600;

const DEFAULTS = {
  base: "./assets",
  pykingURL: "./pyking/",
  examplesURL: "./examples/",
  theme: "ace/theme/tomorrow_night",
  initialTarget: "nodejs",
  initialExample: "subset_control.pyk",
};

export async function mountPlayground(host, options = {}) {
  const cfg = { ...DEFAULTS, ...options };
  const meta = await fetchJSON(cfg.base + "/playground.json");
  await ensureAce(cfg);

  const ui = buildDom(host, meta, cfg);
  const runtime = new PykingRuntime({
    pyodideIndexURL: meta.pyodideIndexURL,
    pykingURL: cfg.pykingURL,
    workerURL: cfg.base + "/pyking-worker.js",
  });

  const app = new Playground(ui, meta, cfg, runtime);
  await app.init();
  return app;
}

// --------------------------------------------------------------- the app

class Playground {
  constructor(ui, meta, cfg, runtime) {
    this.ui = ui;
    this.meta = meta;
    this.cfg = cfg;
    this.runtime = runtime;
    this.files = {};          // last successful compile: {name: text}
    this.views = new Set();   // which of those are front-end views, not code
    this.current = null;      // which of those is shown on the right
    this.errorMarker = null;
    this.frame = null;         // the sandboxed iframe a JS run lives in
    this.frameSeq = 0;
    this.autoRunTimer = null;  // pending "run while you type"
    this.autoRunning = false;
    this.programmaticEdit = false;
    this.jsRunner = new JsRunner(cfg.base + "/js-worker.js");
    this.running = null;       // {origin, kind} while something executes
    this.stopped = false;      // last run ended by the user, not by itself
    this.settings = { ...DEFAULT_SETTINGS, ...loadSettings() };
  }

  async init() {
    const { ui } = this;

    this.left = ace.edit(ui.leftEditor, {
      mode: "ace/mode/pyking", theme: this.cfg.theme,
      tabSize: 4, useSoftTabs: true, showPrintMargin: false,
      fontSize: 13, scrollPastEnd: 0.3,
    });
    this.right = ace.edit(ui.rightEditor, {
      mode: "ace/mode/text", theme: this.cfg.theme,
      tabSize: 4, useSoftTabs: true, showPrintMargin: false,
      fontSize: 13, scrollPastEnd: 0.3,
    });
    // Ace's language workers add no value here (they would lint the
    // *generated* code) and would need extra vendored files.
    this.left.session.setUseWorker(false);
    this.right.session.setUseWorker(false);
    this.left.session.on("change", () => {
      this.clearError();
      // Only what the *user* typed schedules a run. Ace fires the same event
      // for `setValue`, so loading an example -- which happens once during
      // startup -- would otherwise trigger a run, and with it the runtime
      // download, before anyone had touched the page.
      if (!this.programmaticEdit) this.scheduleAutoRun();
    });

    ui.target.addEventListener("change", () => this.onTargetChange());
    ui.example.addEventListener("change", () => this.loadExample(ui.example.value));
    ui.compile.addEventListener("click", () => this.compile());
    ui.runLeft.addEventListener("click", () => this.runFromSource());
    ui.runRight.addEventListener("click", () => this.runGenerated());
    ui.stopLeft.addEventListener("click", () => this.stopRun());
    ui.stopRight.addEventListener("click", () => this.stopRun());
    ui.copy.addEventListener("click", () => this.copyRight());
    ui.clear.addEventListener("click", () => this.clearOutput());

    this.installSplitters();
    this.installSettings();
    this.applySettings();

    // Ace measures its container once and caches the result, so a pane that
    // changes size -- by a drag, by the window resizing, by the host page
    // reflowing -- has to be told. Observing is more reliable than trying to
    // remember every place that could have caused it.
    if (globalThis.ResizeObserver) {
      const observer = new ResizeObserver(() => {
        this.left.resize();
        this.right.resize();
      });
      observer.observe(ui.leftEditor);
      observer.observe(ui.rightEditor);
    }

    // Keyboard shortcuts.
    //
    // Registered as Ace commands rather than as one bubbling keydown
    // listener, because Ace handles keys on its own hidden textarea first: a
    // listener on the container would not run until Ace had already inserted
    // the newline that Shift+Enter would otherwise type.
    //
    // Shift+Enter runs, and means the Run button of whichever pane has focus
    // -- the source pane compiles to Python and runs that, the generated
    // pane runs what is displayed. Overriding it costs nothing, since plain
    // Enter already inserts a newline and Shift+Enter merely duplicated it.
    const bind = (editor, name, bindKey, exec) =>
      editor.commands.addCommand({ name, bindKey, exec, readOnly: true });

    const COMPILE = { win: "Ctrl-Enter", mac: "Command-Enter" };
    const RUN = { win: "Shift-Enter", mac: "Shift-Enter" };
    const RUN_ACCEL = { win: "Ctrl-Shift-Enter", mac: "Command-Shift-Enter" };

    bind(this.left, "pykCompile", COMPILE, () => this.compile());
    bind(this.right, "pykCompile", COMPILE, () => this.compile());
    bind(this.left, "pykRun", RUN, () => this.runFromSource());
    bind(this.right, "pykRun", RUN, () => this.runGenerated());
    bind(this.left, "pykRunAccel", RUN_ACCEL, () => this.runFromSource());
    bind(this.right, "pykRunAccel", RUN_ACCEL, () => this.runGenerated());

    // The same keys when focus is outside both editors -- on a dropdown, a
    // button, or the page itself. Ace stops propagation for keys it handled,
    // but the check for an enclosing editor is explicit so that a future Ace
    // that stops doing so cannot make this fire twice.
    ui.root.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && !ui.modal.classList.contains("pyk-hidden")) {
        this.closeSettings();
        return;
      }
      if (event.key !== "Enter") return;
      if (!ui.modal.classList.contains("pyk-hidden")) return;
      if (event.target?.closest?.(".ace_editor")) return;
      const accel = event.ctrlKey || event.metaKey;
      if (!accel && !event.shiftKey) return;
      event.preventDefault();
      if (accel && !event.shiftKey) this.compile();
      else this.runFromSource();
    });

    await this.loadExample(this.cfg.initialExample, { silent: true });
    this.onTargetChange();
    this.note("Press Compile to start. The Python runtime (~12 MB) loads on "
              + "first use, then stays warm.");
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
    const known = entry && entry.targets.length > 0 && target !== "ast"
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
    this.note("Starting the Python runtime — a one-off ~12 MB download, "
              + "then it stays warm for the rest of the session.");

    try {
      await this.runtime.ready((msg) => { phase = msg; this.status("busy", msg + "…"); });
      this.status("ready", `ready in ${((Date.now() - started) / 1000).toFixed(1)}s`);
      return true;
    } catch (err) {
      // Stopping during the boot rejects it on purpose; that is the user
      // getting what they asked for, not a failure to report.
      if (this.stopped) return false;
      this.status("error", "failed");
      this.error("Could not start the Python runtime: " + err.message);
      return false;
    } finally {
      clearInterval(tick);
    }
  }

  /** The front-end flags the settings dialog switches on, in the shape
   *  `PykingRuntime.compile` takes them. */
  compilerOptions() {
    return {
      typecheck: this.settings.typecheck,
      ast: this.settings.printAst,
    };
  }

  async compile() {
    if (!(await this.ensureRuntime())) return;
    const target = this.ui.target.value;
    const result = await this.runtime.compile(
      this.left.getValue(), target, "playground.pyk", this.compilerOptions());
    this.clearError();

    if (!result.ok) {
      this.showFiles({});
      this.error(result.text);
      if (result.info) this.markError(result.info);
      return;
    }
    this.showFiles(result.files, result.views);
    const names = Object.keys(result.files);
    // With --ast nothing was compiled *to* anything: the front end ran and
    // stopped, whatever target is selected, so saying "compiled to nodejs"
    // would name a backend that never saw the program.
    const what = this.settings.printAst
      ? "Stopped after the front end (--ast)" : `Compiled to ${target}`;
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
    this.right.setValue(name ? this.files[name] : "", -1);
    for (const tab of this.ui.files.children) {
      tab.classList.toggle("active", tab.textContent === name);
    }
    // The Run button beside this pane runs *what is shown*, so switching
    // tabs can change whether there is anything runnable there.
    this.updateRunButtons();
  }

  onTargetChange() {
    const target = this.ui.target.value;
    this.right.session.setMode("ace/mode/" + this.meta.modes[target]);
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
    this.ui.runRight.title = !how
      ? `${target} cannot run in a browser — there is no `
        + `${target.startsWith("java") ? "JVM" : "C compiler"} here`
      : !haveCode ? "Compile first, then run"
      : viewing ? `${this.current} is a view of the front end, not code to run`
      : `Run the generated ${target} code (Shift+Enter)`;
  }

  // -- running ----------------------------------------------------------
  //
  // Every execution goes through beginRun/endRun, which own the Stop button
  // and the record of what is currently running. Three backends sit behind
  // that one lifecycle:
  //
  //   python          the Pyodide worker      stop = terminate the worker
  //   script, module  the JavaScript worker   stop = terminate the worker
  //   page            an iframe preview       stop = remove the frame
  //
  // Only the `html` target uses a frame, because it *is* a page: it draws
  // into its own document rather than printing. The other two run on workers
  // precisely so that a program which never returns can still be stopped --
  // a same-process iframe shares the main thread and would take the page
  // down with it.

  /** The Run button next to the source: compile to Python and execute it,
   *  whatever target happens to be selected. */
  async runFromSource() {
    // Before starting the runtime, so the one-off "downloading Python…"
    // note survives rather than being wiped by the clear that follows it.
    this.beforeRun();
    // Armed here rather than around the execution alone, so it covers the
    // whole of what pressing Run costs: booting the runtime, compiling, then
    // executing. The first Run of a session spends seconds on the download,
    // and leaving that unstoppable is the one case where the button is most
    // obviously wanted.
    this.beginRun("left", "python");
    try {
      if (!(await this.ensureRuntime())) return;
      // `--typecheck` applies here too -- it is a check on the program, and
      // one that rejects it should reject it whichever button was pressed.
      // `--ast` does not: it is a view of the front end, it belongs in the
      // pane that shows compiler output, and honouring it here would mean
      // Run had nothing to run.
      const result = await this.runtime.compile(
        this.left.getValue(), "python", "playground.pyk",
        { typecheck: this.settings.typecheck });
      this.clearError();
      if (!result.ok) {
        this.error(result.text);
        if (result.info) this.markError(result.info);
        return;
      }
      const code = Object.values(result.files)[0];
      if (this.ui.target.value !== "python") {
        this.note("Running the Python translation of the source.");
      }
      await this.executePython(code);
    } finally {
      this.endRun();
    }
  }

  /** The Run button in the generated pane: execute exactly what is shown. */
  async runGenerated() {
    const target = this.ui.target.value;
    const how = this.meta.run[target];
    if (!how) return;          // nothing runs, so nothing is cleared either
    this.beforeRun();
    const code = this.right.getValue();
    this.beginRun("right", how === "python" || how === "page" ? how : "js");

    // A rendered page has no completion event -- it may still be drawing --
    // so it ends its own run on a timer rather than when this returns.
    if (how === "page") return this.showPage(code, target);

    try {
      if (how === "python") {
        if (!(await this.ensureRuntime())) return;
        await this.executePython(code);
      } else {
        await this.executeJs(how, code, target);
      }
    } finally {
      this.endRun();
    }
  }

  async executePython(code) {
    this.showText();
    try {
      const result = await this.runtime.runPython(code, {
        onOutput: (text) => this.write(text),
      });
      if (!result.ok) this.error(result.traceback.trimEnd());
      else this.good("— python finished —");
    } catch (err) {
      // `stop()` rejects everything in flight; that is not an error to report.
      if (!this.stopped) this.error("Python runtime error: " + err.message);
    }
  }

  async executeJs(how, code, target) {
    this.showText();
    try {
      await this.jsRunner.run(how, code, { onOutput: (text) => this.write(text) });
      this.good(`— ${target} finished —`);
    } catch (err) {
      if (!this.stopped) this.error(err.message);
    }
  }

  /** The `html` target: a complete self-contained page, shown rather than
   *  piped into the text pane. */
  showPage(code, target) {
    this.stopFrame();
    const frame = document.createElement("iframe");
    frame.className = "pyk-preview";
    frame.sandbox = "allow-scripts";
    frame.srcdoc = code;
    this.showPreview();
    this.ui.preview.replaceWith(frame);
    this.ui.preview = frame;
    this.frame = frame;
    this.note(`Rendering the ${target} page below.`);
    // A page has no natural "finished": it may still be drawing. The Stop
    // button appears as for anything else and removes the frame; otherwise
    // the run is considered over once it has had a moment to render.
    setTimeout(() => { if (this.running?.kind === "page") this.endRun(); }, 1500);
  }

  stopFrame() {
    if (this.frame && this.frame.parentNode && this.frame !== this.ui.preview) {
      this.frame.remove();
    }
    this.frame = null;
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
    if (kind === "python") this.runtime.stop();
    else if (kind === "js") this.jsRunner.stop();
    else this.stopFrame();
    this.endRun();
    this.error("— stopped —");
    if (kind === "python") {
      this.status("busy", "restarting Python");
      // stop() terminated the interpreter, so a fresh one is already coming
      // up in the background; say when it is usable again.
      this.runtime.ready((msg) => this.status("busy", msg))
        .then(() => this.status("ready", "ready"))
        .catch(() => this.status("error", "failed"));
    }
  }

  // -- output pane ------------------------------------------------------

  showText() { this.ui.output.classList.remove("pyk-hidden");
               this.ui.preview.classList.add("pyk-hidden"); }
  showPreview() { this.ui.output.classList.add("pyk-hidden");
                  this.ui.preview.classList.remove("pyk-hidden"); }

  // -- run while you type -----------------------------------------------

  /** Replace the source without it counting as typing. Also the method to
   *  use from an embedding page, for the same reason. */
  setSource(text) {
    // Ace fires "change" synchronously from setValue, so a plain flag is
    // enough and no reset-on-a-timer is needed.
    this.programmaticEdit = true;
    try {
      this.left.setValue(text, -1);
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
  note(text) { this.showText(); this.write(text + "\n", "note"); }
  good(text) { this.showText(); this.write(text + "\n", "good"); }
  error(text) { this.showText(); this.write(text + "\n", "err"); }
  clearOutput() { this.ui.output.textContent = ""; this.showText(); this.stopFrame(); }

  // -- error marking ----------------------------------------------------

  /** Underline the span the compiler complained about. `lexer.Info` counts
   *  rows from 1 and columns from 0; Ace counts both from 0. */
  markError(info) {
    const Range = ace.require("ace/range").Range;
    const range = new Range(info.row1 - 1, info.col1, info.row2 - 1, info.col2);
    this.errorMarker = this.left.session.addMarker(range, "pyk-error-marker", "text");
    this.left.session.setAnnotations([{
      row: info.row1 - 1, column: info.col1, type: "error", text: "compile error",
    }]);
    this.left.scrollToLine(info.row1 - 1, true, true);
  }

  clearError() {
    if (this.errorMarker !== null) {
      this.left.session.removeMarker(this.errorMarker);
      this.errorMarker = null;
      this.left.session.clearAnnotations();
    }
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
    // Each of these changes what the *next* compile produces, so anything
    // already on the right was produced under different flags -- dropped
    // rather than left standing, for the reason onTargetChange drops it.
    for (const key of ["typecheck", "printAst"]) {
      this.ui[key].addEventListener("change", () => {
        this.settings[key] = this.ui[key].checked;
        this.showFiles({});
        this.saveSettings();
      });
    }
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
    this.left.setFontSize(px);
    this.right.setFontSize(px);
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
    for (const key of ["typecheck", "printAst"]) {
      this.ui[key].checked = this.settings[key];
    }
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
      typecheck: this.settings.typecheck,
      printAst: this.settings.printAst,
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
                  title="Compile to Python and run it (Shift+Enter)">▶ Run</button>
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
        <div class="pyk-files" data-r="files"></div>
        <div class="pyk-editor" data-r="rightEditor"></div>
        <div class="pyk-gutter pyk-gutter-h" data-r="gutterH" role="separator"
             aria-orientation="horizontal" title="Drag to resize"></div>
        <div class="pyk-output-wrap" data-r="outputWrap">
          <div class="pyk-output-head">
            <span class="pyk-label">Output</span>
            <span class="pyk-spacer"></span>
            <button data-r="clear">Clear</button>
          </div>
          <pre class="pyk-output" data-r="output"></pre>
          <iframe class="pyk-preview pyk-hidden" data-r="preview"
                  sandbox="allow-scripts" title="Generated page preview"></iframe>
        </div>
      </section>
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
            <label>Compiler</label>
            <label class="pyk-check">
              <input type="checkbox" data-r="typecheck">
              Enable typechecker
            </label>
            <label class="pyk-check">
              <input type="checkbox" data-r="printAst">
              Print AST output
            </label>
            <p class="pyk-hint">The compiler's own --typecheck and --ast.
              The type checker covers only part of the language so far and
              refuses the rest. --ast shows the front end's own view of the
              program and stops there, so there is no code to run.</p>
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
  // of each example and worth seeing before you pick one.
  const groups = [
    ["Works on every target", meta.examples.filter((e) => e.universal)],
    ["Python only (uses lists, for, match, …)",
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

async function fetchJSON(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`cannot fetch ${url}: ${response.status}`);
  return response.json();
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

/** Ace is a classic (non-module) script, and the Pyking mode registers
 *  itself against the global it defines. Loading them here rather than from
 *  the host page keeps embedding to a single import. */
async function ensureAce(cfg) {
  if (!globalThis.ace) await loadScript(cfg.base + "/vendor/ace/ace.js");
  ace.config.set("basePath", cfg.base + "/vendor/ace");
  if (!ace.config.$modes || !ace.config.$modes["ace/mode/pyking"]) {
    await loadScript(cfg.base + "/pyking-mode.js");
  }
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = src;
    script.onload = resolve;
    script.onerror = () => reject(new Error("could not load " + src));
    document.head.appendChild(script);
  });
}
'''


# ==========================================================================
# Generated artifact: the host page
# ==========================================================================

INDEX_HTML = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pyking Playground</title>
<!--
  Generated by tools/playground/generator.py -- do not edit; run `make`.

  This page is deliberately thin: it is a host for the playground component,
  not the component itself. Everything below the <div> is what you would copy
  into a page of your own (see tools/playground/README.md, "Embedding").
-->
<link rel="stylesheet" href="assets/playground.css">
<style>
  html, body { height: 100%; margin: 0; background: #1d1f21; }
  #playground { height: 100%; }
  noscript { color: #e6e6e6; font: 15px system-ui, sans-serif; padding: 2rem; display: block; }
</style>
</head>
<body>
<div id="playground"></div>
<noscript>The Pyking playground compiles in your browser, so it needs JavaScript.</noscript>
<script type="module">
  import { mountPlayground } from "./assets/playground.js";
  mountPlayground(document.getElementById("playground"), {
    base: "./assets",
    pykingURL: "./pyking/",
    examplesURL: "./examples/",
  }).then((app) => {
    // A handle on the mounted playground, for the console and for anything
    // driving the page from outside it. `mountPlayground` returns the same
    // object, so an embedding page need not rely on this global.
    window.pykingPlayground = app;
  }).catch((err) => {
    document.getElementById("playground").textContent =
      "Could not start the playground: " + err.message;
    console.error(err);
  });
</script>
</body>
</html>
'''


# ==========================================================================
# Build steps
# ==========================================================================

def vendor(cdn=False):
    """Download Ace and Pyodide into vendor/, once. Cached: a file already
    present is left alone, so repeat builds are offline and instant."""
    if cdn:
        print("vendor: CDN=1, nothing to download "
              "(the page will load Ace and Pyodide from jsdelivr)")
        return

    jobs = [(ACE_CDN, VENDOR / "ace", ACE_FILES),
            (PYODIDE_CDN, VENDOR / "pyodide", PYODIDE_FILES)]
    for base, out_dir, names in jobs:
        out_dir.mkdir(parents=True, exist_ok=True)
        for name in names:
            target = out_dir / name
            if target.exists() and target.stat().st_size > 0:
                continue
            url = f"{base}/{name}"
            print(f"  fetching {name} …", end="", flush=True)
            try:
                with urllib.request.urlopen(url, timeout=120) as response:
                    data = response.read()
            except (urllib.error.URLError, TimeoutError) as e:
                raise SystemExit(
                    f"\nvendor: could not download {url}: {e}\n"
                    "  No network? Build against the CDN instead:  make CDN=1"
                )
            target.write_bytes(data)
            print(f" {len(data) / 1048576:.2f} MB")
    total = sum(p.stat().st_size for p in VENDOR.rglob("*") if p.is_file())
    print(f"vendor: {total / 1048576:.1f} MB cached in {VENDOR.relative_to(HERE)}/")


def build(cdn=False):
    """Generate build/ from scratch."""
    if BUILD.exists():
        shutil.rmtree(BUILD)
    assets = BUILD / "assets"
    (BUILD / "pyking").mkdir(parents=True)
    (BUILD / "examples").mkdir(parents=True)
    assets.mkdir(parents=True)

    # 1. the compiler, verbatim, plus the browser entry point
    modules = compiler_modules()
    for name in modules:
        shutil.copy2(SRC_DIR / name, BUILD / "pyking" / name)
    (BUILD / "pyking" / "pyking_web.py").write_text(PYKING_WEB_PY)
    (BUILD / "pyking" / "manifest.json").write_text(json.dumps(
        {"modules": modules + ["pyking_web.py"],
         "note": "copied from src/ by tools/playground/generator.py"},
        indent=2) + "\n")

    # 2. the examples, and what each one is known to compile to
    targets = target_order()
    examples = build_examples(targets)

    # 3. the Ace mode, with the language's own word lists baked in
    keywords = read_list_literal(SRC_DIR / "lexer.py", "keywords")
    builtins = read_list_literal(SRC_DIR / "analyses.py", "BUILTINS")
    types = [k for k in keywords if k in ("Int", "String", "Bool")]
    (assets / "pyking-mode.js").write_text(
        PYKING_MODE_JS
        .replace("%%KEYWORDS%%", "|".join(k for k in keywords if k not in types))
        .replace("%%TYPES%%", "|".join(types))
        .replace("%%BUILTINS%%", "|".join(builtins)))

    # 4. the page itself
    (assets / "playground.css").write_text(PLAYGROUND_CSS)
    (assets / "playground.js").write_text(PLAYGROUND_JS)
    (assets / "pyking-runtime.js").write_text(PYKING_RUNTIME_JS)
    # The two threads execution happens on -- see PYKING_WORKER_JS.
    (assets / "pyking-worker.js").write_text(PYKING_WORKER_JS)
    (assets / "js-worker.js").write_text(
        JS_WORKER_JS.replace("%%PYK_FORMAT%%", js_value_formatter()))
    (BUILD / "index.html").write_text(INDEX_HTML)

    # 5. the manifest the UI is driven by -- targets, modes, examples
    (assets / "playground.json").write_text(json.dumps({
        "generatedBy": "tools/playground/generator.py",
        "pyodideIndexURL": (f"{PYODIDE_CDN}/" if cdn else "./assets/vendor/pyodide/"),
        "aceURL": (ACE_CDN if cdn else "./assets/vendor/ace"),
        "targets": [{"name": t, "label": TARGET_LABEL[t]} for t in targets],
        "modes": {t: TARGET_MODE[t] for t in targets},
        "run": {t: TARGET_RUN[t] for t in targets if t in TARGET_RUN},
        "examples": examples,
    }, indent=2) + "\n")

    # 6. vendored assets (or nothing at all, under CDN=1)
    if cdn:
        patch_for_cdn(assets)
    else:
        if not (VENDOR / "ace" / "ace.js").exists():
            raise SystemExit("build: vendor/ is empty -- run `make vendor` first "
                             "(or build against the CDN with `make CDN=1`).")
        shutil.copytree(VENDOR / "ace", assets / "vendor" / "ace")
        shutil.copytree(VENDOR / "pyodide", assets / "vendor" / "pyodide")

    size = sum(p.stat().st_size for p in BUILD.rglob("*") if p.is_file())
    print(f"build: {BUILD.relative_to(HERE)}/ "
          f"({size / 1048576:.1f} MB, {len(examples)} examples, "
          f"{len(targets)} targets{', CDN assets' if cdn else ''})")


def patch_for_cdn(assets):
    """Point the loader at jsdelivr instead of a vendor/ directory."""
    path = assets / "playground.js"
    path.write_text(path.read_text().replace(
        'cfg.base + "/vendor/ace/ace.js"', f'"{ACE_CDN}/ace.js"').replace(
        'ace.config.set("basePath", cfg.base + "/vendor/ace")',
        f'ace.config.set("basePath", "{ACE_CDN}")'))


def build_examples(code_targets):
    """Copy `tests/*.pyk` and record which targets each one is known to
    accept, straight out of `tests/test_cases.toml` -- the same manifest
    `make test` runs from, so the playground cannot claim support the test
    suite does not.

    The manifest also names modes that are not code generation at all --
    `typecheck` is a `--typecheck` flag over the front end, and several of
    its programs are meant to be *rejected*. The playground compiles, so
    those entries are filtered out here rather than being mistaken for
    backends; a program left with no code-generation target simply makes no
    claim about which ones accept it.
    """
    with open(TESTS_DIR / "test_cases.toml", "rb") as f:
        cases = tomllib.load(f)["cases"]
    known = {case["file"]: case["targets"] for case in cases}
    declared = {t for targets in known.values() for t in targets}
    every = sorted(declared & set(code_targets))
    other = sorted(declared - set(code_targets))
    if other:
        print(f"build: note: manifest also lists {', '.join(other)}, which "
              "is not a code-generation target -- ignored for the playground")

    entries = []
    for path in sorted(TESTS_DIR.glob("*.pyk")):
        shutil.copy2(path, BUILD / "examples" / path.name)
        targets = [t for t in known.get(path.name, ["python"]) if t in code_targets]
        entries.append({
            "file": path.name,
            "name": path.stem.replace("_", " "),
            "targets": targets,
            "universal": bool(targets) and len(targets) == len(every),
        })
    missing = sorted(set(known) - {e["file"] for e in entries})
    if missing:
        print(f"build: WARNING {len(missing)} manifest entries have no .pyk: "
              f"{', '.join(missing)}")
    return entries


def check():
    """Compile every example for every target it claims to support, using the
    generated shim under the host CPython. Catches a broken shim or a
    regressed backend without needing a browser.

    The settings dialog's two front-end flags are checked here too, since
    neither is reachable by selecting a target: every example is compiled
    once more with `--ast` *against a code-generation target*, which is
    what that flag has to override, and the type-checker fixtures are held
    to the same rule the test suite holds them to -- a `typecheck_*`
    program must check and a `fail_typecheck_*` one must not (see
    tests/test_script.py, which owns *what* they infer; this only proves
    the flag reaches the checker through the shim)."""
    manifest = json.loads((BUILD / "assets" / "playground.json").read_text())
    sys.path.insert(0, str(BUILD / "pyking"))
    import pyking_web                                     # noqa: E402

    failures = 0
    checked = 0

    def expect(label, ok, result):
        """One check: `ok` says whether compiling was supposed to succeed."""
        nonlocal failures, checked
        checked += 1
        if result["ok"] == ok:
            return
        failures += 1
        print(f"  FAIL {label}: "
              + (result["text"] if not result["ok"]
                 else "compiled, but was expected to be refused"))

    for entry in manifest["examples"]:
        name = entry["file"]
        source = (BUILD / "examples" / name).read_text()
        for target in entry["targets"] + ["ast"]:
            expect(f"{name} -> {target}", True,
                   pyking_web.compile_source(source, target, name))
        # `--ast` stops before any backend whatever target is selected, so
        # it is checked once, against one that would otherwise generate.
        expect(f"{name} -> --ast", True,
               pyking_web.compile_source(source, "python", name, ast=True))
        if name.startswith("typecheck_") or name.startswith("fail_typecheck_"):
            expect(f"{name} -> --typecheck", not name.startswith("fail_"),
                   pyking_web.compile_source(source, "python", name,
                                             typecheck=True, ast=True))
    print(f"check: {checked - failures}/{checked} example/target pairs compiled")
    if failures:
        raise SystemExit(1)


def serve(port):
    """Serve build/ and print a URL the terminal will linkify."""
    if not (BUILD / "index.html").exists():
        raise SystemExit("serve: nothing built yet -- run `make build` first.")

    port = first_free_port(port)
    handler = functools.partial(QuietHandler, directory=str(BUILD))
    # Threaded, not the stdlib default. A browser opens several connections at
    # once and speculatively pre-connects ones it may never use; a
    # single-threaded server blocks on the idle one while the page waits for
    # ~20 files including an 8 MB WebAssembly binary, which looks exactly like
    # a hang. `python3 -m http.server` has the same flaw.
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    with http.server.ThreadingHTTPServer(("", port), handler) as httpd:
        url = f"http://localhost:{port}/"
        print()
        print("  Pyking playground is being served.")
        print()
        print(f"      {url}")
        print()
        print("  Open that link in a browser (ctrl/cmd-click it in most")
        print("  terminals). It must be *served*, not opened from disk:")
        print("  browsers block the module and WebAssembly loads a file://")
        print("  page would need.")
        print()
        print("  Press Ctrl+C to stop.")
        print()
        # serve_forever() never returns, so an unflushed banner would sit in
        # the buffer forever whenever stdout is a pipe rather than a terminal.
        sys.stdout.flush()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nserve: stopped.")


def first_free_port(start, tries=20):
    for port in range(start, start + tries):
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(("", port))
                return port
            except OSError:
                continue
    raise SystemExit(f"serve: no free port in {start}..{start + tries - 1}")


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    """Same as the stdlib handler, minus a log line per asset -- Pyodide
    alone is five requests, and the useful output is the URL above."""

    # Keep-alive, so the browser does not reopen a connection per file.
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def end_headers(self):
        # Two different caching needs. Everything `make` regenerates must
        # never be served stale, or you debug the previous build. The
        # vendored Ace and Pyodide are version-pinned and never regenerated,
        # so letting the browser keep them turns a reload from a 12 MB
        # download plus a WebAssembly recompile into no work at all.
        if "/assets/vendor/" in self.path:
            self.send_header("Cache-Control", "public, max-age=86400")
        else:
            self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="generator.py", description="Build the Pyking web playground.")
    parser.add_argument("command",
                        choices=("vendor", "build", "check", "serve", "all"))
    parser.add_argument("--cdn", action="store_true",
                        help="load Ace and Pyodide from a CDN instead of vendor/")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args(argv)

    if args.command in ("vendor", "all"):
        vendor(args.cdn)
    if args.command in ("build", "all"):
        build(args.cdn)
    if args.command in ("check", "all"):
        check()
    if args.command in ("serve", "all"):
        serve(args.port)


if __name__ == "__main__":
    main()
