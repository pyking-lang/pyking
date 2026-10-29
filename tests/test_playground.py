#!/usr/bin/env python3
"""Runs the playground's own test cases: that the compiler bundle the
page loads still works, and that every example the page offers -- the
list in src/examples.toml, which `pyk example` reads too -- is a test
case the interpreter runs, and checks in the bundle with the standard
library it imports.

This drives the bundle directly: the bundle is what `make build`
already writes to `share/pyking.js`, and the example list comes from
`tools/playground/playground.py` itself, so the suite and the page cannot
disagree about what is offered. The REPL the page's REPL tab runs is
driven here too: entries, what they print and show, the environment, the
refusals, `:edit`, an import and `:reset`. So is the Compiled code
tab's Download (tools/playground/assets/download.js): each case in
DOWNLOADS is compiled by the bundle and packed as the page packs it, the
zip is read back by Python's zipfile, and a case that runs is unpacked
and built and run with its own Makefile (tests/playground/download.mjs).
And the page's keys (tools/playground/assets/keys.js), under node
(tests/playground/keys.mjs): every command the playground adds and its
default keys, reading, matching, writing and showing a key on a Mac and
elsewhere, and the settings that hold them, an earlier version's
`debugKeys` migrated.

What it does not cover is the page: mounting, the editor, the worker
boundary and the sandboxed iframe are what
`make -C tools/playground e2e` drives in a real browser, and that needs
Playwright.

Usage: python3 tests/test_playground.py [--bundle FILE]

Functions:
    plan() -- the bundle, the targets, and every example.
    check_examples() -- what is wrong with src/examples.toml.
    run_driver(bundle, plan) -- one node process over the bundle.
    parity_pairs(compiler) -- what `pyk compile` makes of every case.
    run_parity(bundle, pairs) -- the same cases compiled by the bundle.
    check_downloads(bundle) -- the Download of every case in DOWNLOADS.
    check_keys() -- the page's keys, keys.js.
    main(argv) -- the command-line entry point.
"""

import contextlib
import io
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import suite  # noqa: E402  (after sys.path, which is what finds it)

REPO = HERE.parent
PLAYGROUND = REPO / "tools" / "playground"
# What `make build` writes: the same compiler the page loads, as one
# JavaScript file.
DEFAULT_BUNDLE = REPO / "share" / "pyking.js"
# Long enough that a bundle which has gone wrong is reported rather than
# hanging. Compiling every example takes a few seconds.
STEP_TIMEOUT = 1200
# Plain `node`, with no flags, which is also how
# tools/playground/playground.py runs its own check. Elsewhere the suite
# passes `--no-experimental-detect-module` so that node cannot guess a
# generated `.js` into an ES module, and it probes for that flag first
# because an older node rejects it outright. Neither applies here: the
# driver below is a `.cjs` file, which is CommonJS by its extension, and
# the bundle is `eval`ed from a string rather than loaded as a module, so
# there is no guess for node to make.
NODE = ["node"]

# A program small enough to say nothing about any backend, and enough to
# prove the whole path works: it binds, calls and prints.
SMOKE = """def twice(n:Int) -> Int:
    return n * 2


print(twice(21))
"""
SMOKE_OUTPUT = ["42"]

DRIVER = r"""// Drives the playground's compiler bundle under node.
const fs = require("fs");
// Evaluated rather than required: the bundle is a classic script, and
// `require` is a module-local in CommonJS that js_of_ocaml's runtime
// calls, so global code needs it put within reach. This is how
// tools/playground/playground.py loads it too.
globalThis.require = require;
(0, eval)(fs.readFileSync(process.argv[2], "utf8"));
const plan = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const progress = (text) => process.stderr.write("progress: " + text + "\n");

const failures = [];
const check = (label, ok, detail) => {
  if (!ok) failures.push(label + ": " + detail);
};

progress("the bundle is loaded; its entry points");
// 1. The entry points the page calls. stub.js registers them on the
//    global object; a rename in src/web/pyking_web.ml that the page was
//    not told about looks like this.
for (const name of ["pykCompile", "pykRun", "pykRunProgram", "pykAnalyze",
                    "pykTargets", "pykFormatHelper", "pykKeywords",
                    "pykBuiltins", "pykReplStart", "pykReplLine",
                    "pykReplImports", "pykReplSubmit", "pykReplComplete"]) {
  check("entry point " + name, typeof globalThis[name] === "function",
        "not registered on the global object");
}
if (failures.length) {
  console.log(JSON.stringify({ pairs: 0, failures }));
  process.exit(0);
}

// 2. What the page reads out of the compiler rather than keeping its own
//    copy of: the targets, the keywords its editor highlights, the
//    builtins it completes, and the value formatter its worker uses.
const targets = JSON.parse(pykTargets());
check("pykTargets", Array.isArray(targets) && targets.length > 0,
      JSON.stringify(targets));
const unknown = targets.filter(
  (t) => !plan.targets.includes(t) && !plan.leftOut.includes(t));
check("every target known to the playground", unknown.length === 0,
      unknown.join(", ") + " has no entry in playground.py's TARGET_MODE");
const keywords = JSON.parse(pykKeywords());
check("pykKeywords", Array.isArray(keywords) && keywords.includes("def"),
      JSON.stringify(keywords).slice(0, 120));
const builtins = JSON.parse(pykBuiltins());
check("pykBuiltins", Array.isArray(builtins) && builtins.includes("print"),
      JSON.stringify(builtins));
const helper = pykFormatHelper();
check("pykFormatHelper", typeof helper === "string" && helper.length > 0,
      "answered nothing");

progress("the smoke program on " + plan.targets.length + " targets");
// 3. One small program compiled for every target the page offers, and
//    run with the interpreter -- the two things a visitor does first.
for (const target of plan.targets) {
  const result = JSON.parse(pykCompile(plan.smoke, target, "smoke.pyk"));
  check("compile the smoke program -> " + target, result.ok === true,
        result.text || "refused with no message");
}
const printed = [];
globalThis.pykOnPrint = (line) => printed.push(line);
// One string in: the first line is the file name errors are reported
// against, the rest is the program (see src/web/pyking_web.ml).
const ran = JSON.parse(pykRun("smoke.pyk\n" + plan.smoke));
check("run the smoke program", ran.ok === true,
      ran.text || "refused with no message");
check("the smoke program's output",
      JSON.stringify(printed.map((l) => l.replace(/\n$/, ""))) ===
        JSON.stringify(plan.smokeOutput),
      JSON.stringify(printed));

// 3b. In a browser `print` writes through the `io` library's own
//     implementation, so a `web` program ships it -- read, as the page's
//     worker reads it, from the library beside the tools.
globalThis.pykLibraryFile = (path) =>
  fs.readFileSync(plan.lib + "/" + path, "utf8");
const page = JSON.parse(pykCompile(plan.smoke, "web2020", "smoke.pyk"));
check("a web program ships io_external.js",
      page.ok && typeof page.files?.["io_external.js"] === "string"
        && page.files["io_external.js"].includes("export function write_line"),
      JSON.stringify(Object.keys(page.files ?? {})));
delete globalThis.pykLibraryFile;

// 4. Every example the page offers checks as the page's Run checks it,
//    with the modules it imports read from lib/ as the worker reads them.
//    What it prints is the test suite's business: it is a test case.
globalThis.pykFetchSource = (name) => {
  const found = /^([A-Za-z_][A-Za-z0-9_]*?)(_external)?\.pyk$/.exec(name);
  try {
    return found ? fs.readFileSync(plan.lib + "/" + found[1] + "/" + name, "utf8") : null;
  } catch (error) {
    return null;
  }
};
progress(plan.examples.length + " examples");
let pairs = 0;
for (const example of plan.examples) {
  pairs += 1;
  globalThis.pykSources = { [example.file]: fs.readFileSync(example.path, "utf8") };
  const result = JSON.parse(pykAnalyze(example.file));
  check(example.file + " checks in the page", result.ok === true,
        result.text || "refused with no message");
}

// 5. The REPL tab's session (src/repl_session.ml): what an entry shows
//    goes to `pykOnShow`, what it prints to `pykOnPrint`, and each answer
//    carries the errors, the text to put back and the environment.
progress("the REPL tab's session");
let repl = 0;
const replCheck = (label, ok, detail) => {
  repl += 1;
  check("REPL: " + label, ok, detail);
};
const shown = [];
globalThis.pykOnShow = (line) => shown.push(line.replace(/\n$/, ""));
printed.length = 0;
const submit = (text) => {
  shown.length = 0;
  printed.length = 0;
  return JSON.parse(pykReplSubmit(text));
};
const names = (answer) => (answer.bindings ?? []).map((b) => `${b.name}=${b.value}:${b.type}`);
replCheck("a new session binds nothing", JSON.parse(pykReplStart()).bindings.length === 0,
          pykReplStart());
const opened = JSON.parse(pykReplLine("def f(n):"));
replCheck("a def header is not a whole entry, and indents the next line",
          !opened.complete && opened.indent === "    ", JSON.stringify(opened));
const open = JSON.parse(pykReplLine("if true: 1"));
replCheck("an if with no else could be continued", open.complete && open.continuable,
          JSON.stringify(open));
let answer = submit("x = 20");
replCheck("a binding is in the environment", names(answer).join() === "x=20:Int",
          JSON.stringify(answer));
answer = submit("x + 1");
replCheck("a value is shown with its type", shown.join("|") === "21 : Int",
          JSON.stringify(shown));
answer = submit("def f(n):\n    n * 2");
answer = submit("print(f(x))");
replCheck("what an entry prints is printed", printed.join("") === "40\n",
          JSON.stringify(printed));
replCheck("a function's type is settled by its use",
          names(answer).includes("f=<function>:(Int) -> Int"), JSON.stringify(names(answer)));
answer = submit("y = g(1)");
replCheck("a refusal is an error, in the CLI's words",
          answer.errors.length === 1 && answer.errors[0].includes("Name error: unbound name 'g'")
            && answer.pending === "", JSON.stringify(answer));
answer = submit("def h(n: Int) -> Int:\n    k(n)");
replCheck("a def naming what is not written yet comes back to be finished",
          answer.pending === "def h(n: Int) -> Int:\n    k(n)" && answer.errors.length === 1,
          JSON.stringify(answer));
answer = submit("1 / 0");
replCheck("a runtime error is an error", answer.errors.some((e) => e.includes("Runtime error")),
          JSON.stringify(answer));
answer = submit(":edit f");
replCheck(":edit puts the definition back", answer.pending === "def f(n):\n    n * 2",
          JSON.stringify(answer));
answer = submit(":ls");
replCheck(":ls shows what the environment holds", shown.join("|") === "x = 20 : Int|f = <function> : (Int) -> Int",
          JSON.stringify(shown));
const offered = (col, line) => JSON.parse(pykReplComplete(col + "\n" + line));
let complete = offered(1, "f");
replCheck("Tab offers what is bound, with its type, a keyword and a builtin",
          complete.start === 0 && JSON.stringify(complete.items.map((i) => i.label))
            === JSON.stringify(["f", "false", "float", "for", "from"])
          && complete.items[0].detail === "(Int) -> Int", JSON.stringify(complete));
complete = offered(6, "y = x + ");
replCheck("Tab where nothing has been typed offers everything",
          complete.start === 6 && complete.items.some((i) => i.label === "x"), JSON.stringify(complete).slice(0, 200));
complete = offered(2, ":e");
replCheck("Tab at the start offers the commands a page has",
          complete.items.length === 1 && complete.items[0].label === ":edit", JSON.stringify(complete));
complete = offered(2, ":l");
replCheck("and not one only a terminal has", complete.items.some((i) => i.label === ":ls")
          && !complete.items.some((i) => i.label === ":load"), JSON.stringify(complete));
answer = submit("import math");
complete = offered(9, "math.flo");
replCheck("Tab after an imported module's name offers what it exports",
          complete.start === 5 && complete.items.some((i) => i.label === "floor")
          && complete.items.every((i) => i.label.startsWith("flo")), JSON.stringify(complete));
answer = submit(":help");
replCheck(":help leaves out what only a terminal has",
          shown.join("\n").includes(":reset") && !shown.join("\n").includes(":load"),
          JSON.stringify(shown));
replCheck("an import names the modules to make ready first",
          pykReplImports("import io") === '["io"]', pykReplImports("import io"));
globalThis.pykExternals = { io: { write_line: (text) => { printed.push(text + "\n"); } } };
answer = submit("import io");
answer = submit('io.write_line("from io")');
replCheck("an imported module's JavaScript is reached",
          printed.join("") === "from io\n" && answer.errors.length === 0,
          JSON.stringify([printed, answer.errors]));
answer = submit(":reset");
replCheck(":reset empties the environment", answer.bindings.length === 0,
          JSON.stringify(answer));
answer = submit("var c = 1");
replCheck("a var needs use mutation, in the CLI's words",
          answer.errors.length === 1 && answer.errors[0].includes("needs 'use mutation'"),
          JSON.stringify(answer));
answer = submit("use mutation");
answer = submit("var c = 1");
answer = submit("c := c + 41");
answer = submit("c");
replCheck("a use line holds for the entries after it", shown.join("|") === "42 : Int"
          && answer.errors.length === 0, JSON.stringify([shown, answer.errors]));
answer = submit("[10, 20, 30][1] + (7 % 4) + (2 ^ 3) + (12 and 10)");
replCheck("the new operators answer as in a file", shown.join("|") === "39 : Int",
          JSON.stringify([shown, answer.errors]));
answer = submit("(lam (a, b). a + b)(\"con\", \"cat\")");
replCheck("a lam lambda joining two Strings", shown.join("|") === '"concat" : String',
          JSON.stringify([shown, answer.errors]));
answer = submit("x => x");
replCheck("the old lambda is refused by name",
          answer.errors.length === 1 && answer.errors[0].includes("lam x. x + 1"),
          JSON.stringify(answer));

// 6. A program that waits for its page, as tinyweb's `sdelay` does: an
//    external answering a promise stops the interpreter, which goes on
//    once the promise settles (pykSettle, pykResume) -- at the top
//    level, in a function the page calls back, and under the debugger.
progress("a program waiting for a promise");
const waited = [];
globalThis.pykOnPrint = (line) => waited.push(line);
let kept = null;
globalThis.pykExternals = { later: {
  twice: (n) => new Promise((resolve) => setTimeout(() => resolve(n * 2), 5)),
  keep: (f) => { kept = f; },
} };
globalThis.pykSources = {
  "waits.pyk": "import later\n\ndef again():\n    print(\"again\", later.twice(5))\n\n"
    + "later.keep(again)\nprint(\"before\")\nprint(\"after\", later.twice(21))\n",
  "later_external.pyk": "public def twice(n: Int) -> Int\npublic def keep(f: () -> ()) -> ()\n",
};
const waitCheck = (label, ok, detail) => check("waiting: " + label, ok, detail);
const started = JSON.parse(pykRunProgram("waits.pyk"));
waitCheck("the run says it waits", started.ok && started.waiting !== undefined,
          JSON.stringify(started));
waitCheck("what came before the wait is printed", waited.join("") === "before\n",
          JSON.stringify(waited));
Promise.resolve(pykSettle(started))
  .then((ended) => {
    waitCheck("the run ends once the promise settles", ended.ok && ended.waiting === undefined,
              JSON.stringify(ended));
    waitCheck("the answer reaches the program", waited.join("") === "before\nafter 42\n",
              JSON.stringify(waited));
    const call = kept();
    waitCheck("a callback that waits answers a promise", call && typeof call.then === "function",
              String(call));
    return call;
  })
  .then(() => {
    waitCheck("the callback goes on once its promise settles",
              waited.join("") === "before\nafter 42\nagain 10\n", JSON.stringify(waited));
    // Under the debugger the session says "waiting", and goes on once
    // pykDebugAnswer hands it the answer.
    waited.length = 0;
    const debugStarted = JSON.parse(pykDebugStart(JSON.stringify({
      main: "waits.pyk", files: ["waits.pyk"], stopOnEntry: false, breakpoints: [] })));
    waitCheck("the debugger starts", debugStarted.ok, JSON.stringify(debugStarted));
    let answer = JSON.parse(pykDebugRun("100000"));
    waitCheck("the debugger says the program waits", answer.state === "waiting"
              && answer.waiting !== undefined, JSON.stringify(answer));
    const promise = pykWaits.get(answer.waiting);
    pykWaits.delete(answer.waiting);
    return promise.then((value) => {
      pykDebugAnswer(answer.waiting + "\n" + JSON.stringify(value));
      answer = JSON.parse(pykDebugRun("100000"));
      waitCheck("the debugged program goes on with the answer",
                answer.state === "idle" && waited.join("") === "before\nafter 42\n",
                JSON.stringify([answer, waited]));
      pykDebugStop();
    });
  })
  .catch((error) => waitCheck("no error", false, String(error && error.stack || error)))
  .finally(() => console.log(JSON.stringify({ pairs, failures, repl })));
"""


def plan():
    """The targets the page offers and every example it will offer, asked
    of the playground itself so that the two cannot disagree.
    () -> {...}"""
    sys.path.insert(0, str(PLAYGROUND))
    import playground

    with contextlib.redirect_stdout(io.StringIO()):
        targets = playground.code_targets()
        sources = playground.example_sources()
    return {
        "targets": targets,
        "leftOut": sorted(playground.NOT_IN_THE_PAGE),
        "smoke": SMOKE,
        "smokeOutput": SMOKE_OUTPUT,
        "lib": str(REPO / "lib"),
        "examples": [
            {"file": name, "path": str(path)} for name, path in sources.items()
        ],
    }


def check_examples():
    """What is wrong with src/examples.toml: an example whose source is
    missing or is not a test case the interpreter runs, a name given
    twice or not ending in .pyk, and a line of `pyk example` longer than
    80 columns. () -> [String]"""
    import tomllib

    with open(REPO / "src" / "examples.toml", "rb") as f:
        listed = tomllib.load(f).get("examples", [])
    with open(HERE / "test_cases.toml", "rb") as f:
        cases = {case["file"]: case for case in tomllib.load(f)["cases"]}
    problems = [] if listed else ["src/examples.toml lists no example"]
    width = max([len("File name")] + [len(e.get("name", "")) for e in listed]) + 2
    names = [e.get("name", "") for e in listed]
    for example in listed:
        name, source = example.get("name", ""), example.get("source", "")
        if not (source and name and example.get("description")):
            problems.append(f"{name or source or '?'}: needs source, name and description")
            continue
        if not (REPO / source).is_file():
            problems.append(f"{name}: no file {source}")
        case = cases.get(Path(source).name) if Path(source).parent == Path("tests") else None
        if (case is None or case["file"].startswith("fail_")
                or "interpret" in case.get("excluded", {})):
            problems.append(f"{name}: {source} is not a case of test_cases.toml run by interpret")
        if not name.endswith(".pyk") or "/" in name:
            problems.append(f"{name}: a name is a file name ending in .pyk")
        if names.count(name) > 1:
            problems.append(f"{name}: named twice")
        if width + len(example["description"]) > 80:
            problems.append(f"{name}: its line of `pyk example` is longer than 80 columns")
    return problems


def run_driver(bundle, prepared):
    """One node process over the bundle. Answers (pairs, failures, REPL
    checks), or (None, [message], 0) where node could not be run at all.
    Path -> {...} -> (Int?, [String], Int)"""
    directory = tempfile.mkdtemp(prefix="pyk-playground-")
    try:
        script = Path(directory) / "driver.cjs"
        script.write_text(DRIVER)
        prepared_path = Path(directory) / "plan.json"
        prepared_path.write_text(json.dumps(prepared))
        try:
            result = suite.run_with_progress(
                NODE + [str(script), str(bundle), str(prepared_path)],
                "the bundle", STEP_TIMEOUT)
        except FileNotFoundError:
            return None, ["node not found; it is what runs the compiler bundle"], 0
        except subprocess.TimeoutExpired:
            return None, [f"timed out after {STEP_TIMEOUT} seconds"], 0
        if result.returncode != 0 or not result.stdout.strip():
            detail = (result.stderr or result.stdout or "no output").strip()
            return None, [f"the driver did not finish: {detail.splitlines()[-1]}"], 0
        answer = json.loads(result.stdout.strip().splitlines()[-1])
        return answer["pairs"], answer["failures"], answer.get("repl", 0)
    finally:
        import shutil

        shutil.rmtree(directory, ignore_errors=True)


# Compiles what `parity_pairs` lists with the bundle, the program's own
# file supplied as the page supplies it and every other file read from
# beside it or from lib/, as the page's worker reads them; answers each
# pair the bundle disagrees with `pyk compile` about.
PARITY_DRIVER = r"""
const fs = require("fs");
const path = require("path");
globalThis.require = require;
const [bundle, pairsFile, lib] = process.argv.slice(2);
let dir = ".";
globalThis.pykFetchSource = (name) => {
  const beside = path.join(dir, name);
  if (fs.existsSync(beside)) return fs.readFileSync(beside, "utf8");
  const found = /^([A-Za-z_][A-Za-z0-9_]*?)(_external)?\.pyk$/.exec(name);
  const inLib = found && path.join(lib, found[1], name);
  return inLib && fs.existsSync(inLib) ? fs.readFileSync(inLib, "utf8") : null;
};
globalThis.pykLibraryFile = (p) => {
  const q = path.join(lib, p);
  return fs.existsSync(q) ? fs.readFileSync(q, "utf8") : null;
};
(0, eval)(fs.readFileSync(bundle, "utf8"));
const failures = [];
const all = JSON.parse(fs.readFileSync(pairsFile, "utf8"));
let done = 0;
for (const pair of all) {
  if (done++ % 250 === 0) {
    process.stderr.write(`progress: ${done - 1} of ${all.length} compiled\n`);
  }
  dir = path.dirname(pair.path);
  const name = path.basename(pair.path);
  const source = fs.readFileSync(pair.path, "utf8");
  globalThis.pykSources = { [name]: source };
  const result = JSON.parse(pykCompile(source, pair.target, name));
  const label = pair.path + " -> " + pair.target;
  if (result.ok !== pair.ok) {
    failures.push(label + ": " + (pair.ok ? "pyk compiles it and the page refuses it: "
      + (result.text || "") : "the page compiles what pyk refuses"));
  } else if (pair.ok && pair.text !== null
             && !Object.values(result.files).includes(pair.text)) {
    failures.push(label + ": the page's files differ from what pyk compiles");
  }
}
console.log(JSON.stringify({ failures }));
"""


def parity_pairs(compiler, offered):
    """Every case of tests/test_cases.toml on every target it runs on that
    the page offers, with whether `pyk compile` accepts it and the text it
    prints for the program's own file.
    [String] -> [String] -> [{...}]"""
    import concurrent.futures
    import os
    sys.path.insert(0, str(HERE))
    import test_script

    with contextlib.redirect_stdout(io.StringIO()):
        cases = test_script.load_cases()
    wanted = []
    for case in cases:
        if case["file"].startswith("fail_"):
            continue
        for target in case["targets"]:
            if target in offered:
                wanted.append((str(HERE / case["file"]), target))

    def compiled(pair):
        path, target = pair
        result = subprocess.run(
            compiler + ["compile", "-t", target, "--stdout", path],
            capture_output=True, text=True, cwd=REPO,
        )
        return {
            "path": path,
            "target": target,
            "ok": result.returncode == 0,
            "text": None if result.returncode else result.stdout,
        }

    done = []
    with concurrent.futures.ThreadPoolExecutor(os.cpu_count() or 4) as pool:
        for answer in pool.map(compiled, wanted):
            done.append(answer)
            if len(done) % 250 == 0:
                print(f"  pyk compile: {len(done)} of {len(wanted)} compiled", flush=True)
    return done


def run_parity(bundle, pairs):
    """The pairs compiled by the bundle: every one it disagrees with
    `pyk compile` about. Path -> [{...}] -> [String]"""
    directory = tempfile.mkdtemp(prefix="pyk-parity-")
    try:
        script = Path(directory) / "parity.cjs"
        script.write_text(PARITY_DRIVER)
        listed = Path(directory) / "pairs.json"
        listed.write_text(json.dumps(pairs))
        try:
            result = suite.run_with_progress(
                NODE + [str(script), str(bundle), str(listed), str(REPO / "lib")],
                "the page's Compile", STEP_TIMEOUT, cwd=REPO)
        except subprocess.TimeoutExpired:
            return [f"parity: timed out after {STEP_TIMEOUT} seconds"]
        if result.returncode != 0 or not result.stdout.strip():
            detail = (result.stderr or result.stdout or "no output").strip()
            return [f"parity: the driver did not finish: {detail.splitlines()[-1]}"]
        return json.loads(result.stdout.strip().splitlines()[-1])["failures"]
    finally:
        import shutil

        shutil.rmtree(directory, ignore_errors=True)


# The Download's cases: a program, a target, and either `run` -- the
# unpacked zip's `make run` prints the program's .out -- or `holds`, files
# the zip must hold.
DOWNLOAD_DRIVER = HERE / "playground" / "download.mjs"
DOWNLOAD_RUNS = ["python12", "node22", "c89", "c23", "java21", "ocaml4.14"]
DOWNLOADS = (
    [{"program": "tests/lib_math_basic.pyk", "target": t, "run": True}
     for t in DOWNLOAD_RUNS]
    + [{"program": "tests/lib_random_basic.pyk", "target": t, "run": True}
       for t in DOWNLOAD_RUNS]
    + [{"program": "tests/lib_tinyweb_image.pyk", "target": t, "run": True,
        "events": "tests/lib_tinyweb_image.events"} for t in DOWNLOAD_RUNS]
    + [{"program": "tests/lib_tinyweb_image.pyk", "target": "web2020",
        "holds": ["playground.html", "playground.js", "tinyweb.js",
                  "tinyweb_external.js", "io_external.js", "pyk-runtime.js",
                  "tinyweb_assets/ball.png", "tinyweb_assets/star.png", "Makefile"]},
       {"program": "tests/lib_tinyweb_image.pyk", "target": "iweb2020",
        "holds": ["playground.html", "playground.pyk", "pyking.js", "tinyweb.pyk",
                  "tinyweb_external.pyk", "tinyweb_external.js", "io_external.js",
                  "tinyweb_page.js", "tinyweb_assets/ball.png", "Makefile"]}])


def check_downloads(bundle):
    """The Download of every case in DOWNLOADS: (checks passed, failures).
    Path -> (Int, [String])"""
    directory = tempfile.mkdtemp(prefix="pyk-download-")
    try:
        listed = Path(directory) / "cases.json"
        listed.write_text(json.dumps(DOWNLOADS))
        try:
            result = suite.run_with_progress(
                NODE + [str(DOWNLOAD_DRIVER), str(bundle), str(REPO / "lib"), str(listed)],
                "the Download", STEP_TIMEOUT, cwd=REPO)
        except subprocess.TimeoutExpired:
            return 0, [f"download: timed out after {STEP_TIMEOUT} seconds"]
        if result.returncode != 0 or not result.stdout.strip():
            detail = (result.stderr or result.stdout or "no output").strip()
            return 0, [f"download: the driver did not finish: {detail.splitlines()[-1]}"]
        answer = json.loads(result.stdout.strip().splitlines()[-1])
        return answer["checks"], answer["failures"]
    finally:
        import shutil

        shutil.rmtree(directory, ignore_errors=True)


# The page's keys (tools/playground/assets/keys.js) under node: each
# command and its defaults, reading, matching, writing and showing a key,
# and the settings holding them, an earlier version's migrated.
KEYS_DRIVER = HERE / "playground" / "keys.mjs"


def check_keys():
    """The page's keys: (checks passed, failures). () -> (Int, [String])"""
    try:
        result = subprocess.run(NODE + [str(KEYS_DRIVER)], capture_output=True, text=True,
                                timeout=120, cwd=REPO)
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return 0, [f"keys: the driver did not run: {e}"]
    if result.returncode != 0 or not result.stdout.strip():
        detail = (result.stderr or result.stdout or "no output").strip()
        return 0, [f"keys: the driver did not finish: {detail.splitlines()[-1]}"]
    answer = json.loads(result.stdout.strip().splitlines()[-1])
    return answer["checks"] - len(answer["failures"]), answer["failures"]


def parse_args(argv):
    """`--bundle FILE` or the default. [String] -> Path"""
    if argv[:1] == ["--bundle"]:
        if len(argv) < 2:
            print("usage: test_playground.py [--bundle FILE]", file=sys.stderr)
            sys.exit(2)
        return Path(argv[1])
    if argv:
        print("usage: test_playground.py [--bundle FILE]", file=sys.stderr)
        sys.exit(2)
    return DEFAULT_BUNDLE


def main(argv):
    """Runs the checks and reports them. [String] -> Int"""
    bundle = parse_args(argv)
    if not bundle.exists():
        print(f"playground: FAILED -- no bundle at {bundle}")
        print("  `make build` writes it; it is the compiler the page loads")
        suite.footer("playground", 0, 1, "no bundle to drive")
        return 1
    prepared = plan()
    print(f"playground: driving the bundle ({len(prepared['targets'])} targets, "
          f"{len(prepared['examples'])} examples, the REPL).", flush=True)
    pairs, failures, repl = run_driver(bundle, prepared)
    listed = check_examples()
    # What `pyk compile` compiles, the page's Compile compiles, to the
    # same text.
    print("playground: compiling every case with `pyk compile` on the page's targets.",
          flush=True)
    parity = parity_pairs([str(REPO / "pyk")], prepared["targets"])
    print(f"playground: compiling the same {len(parity)} in the bundle.", flush=True)
    mismatches = run_parity(bundle, parity)
    print(f"playground: packing and building {len(DOWNLOADS)} downloads.", flush=True)
    downloaded, download_failures = check_downloads(bundle)
    keyed, key_failures = check_keys()
    for failure in key_failures:
        print(f"playground: FAILED {failure}")
    for failure in download_failures:
        print(f"playground: FAILED download: {failure}")
    for mismatch in mismatches:
        print(f"playground: FAILED {mismatch}")
    for problem in listed:
        print(f"playground: FAILED src/examples.toml: {problem}")
    for failure in failures:
        print(f"playground: FAILED {failure}")
    if pairs is None:
        suite.footer("playground", 0, 1, "the bundle could not be driven")
        return 1
    checks = len(prepared["targets"]) + 11 + repl
    print(f"playground: the bundle's {len(prepared['targets'])} targets, its "
          "entry points and the smoke program OK.")
    print(f"playground: {pairs} examples checked in the page.")
    print(f"playground: the REPL, {repl} checks.")
    print(f"playground: {len(parity)} compilations compared with pyk's, "
          f"{len(mismatches)} differ.")
    print(f"playground: {downloaded} of {len(DOWNLOADS)} downloads packed, "
          "unpacked and built.")
    print(f"playground: the page's keys, {keyed} checks passed.")
    failed = (len(failures) + len(listed) + len(mismatches) + len(download_failures)
              + len(key_failures))
    suite.footer(
        "playground",
        checks + pairs + len(parity) - len(failures) - len(mismatches)
        - (1 if listed else 0) + downloaded + keyed,
        failed,
        f"{len(prepared['examples'])} examples, "
        f"{len(prepared['targets'])} targets")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
