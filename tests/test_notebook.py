#!/usr/bin/env python3
"""Runs the notebook's own test cases: that the Markdown renderer renders
what it should, that every cell of PYKING-TUTORIAL.md runs through the
compiler worker the page uses, and that `pyk notebook` and `pyk
playground` serve what their pages load and refuse what they should.

None of it needs a browser. The renderer is a pure module, so node runs
it directly; the worker is loaded under node with the few browser globals
it touches stubbed out; and the server is fetched over HTTP. The page
itself -- editors, keys, buttons -- is not covered here.

Three parts:

  renderer  tests/notebook/features.md, which uses every feature the
            renderer supports, against tests/notebook/features.html;
            then a list of short cases against the HTML CommonMark and
            GitHub give for them.
  cells     every runnable cell of PYKING-TUTORIAL.md and features.md,
            run through tools/webrun/assets/pyking-worker.js: an `error`
            cell must be refused, every other cell must run.
  server    `pyk notebook` and `pyk playground` on a free port, each file
            the pages load fetched, and the refusals: a missing file, a
            file that is not Markdown, and a Python that is too old.

Usage: python3 tests/test_notebook.py [--compiler CMD] [--update]

`--update` rewrites features.html from what the renderer now produces;
read the diff before keeping it.

Functions:
    run_driver(update) -- the renderer and cell checks, in one node process.
    check_server(compiler) -- the server checks.
    main(argv) -- the command-line entry point.
"""

import http.client
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import suite  # noqa: E402  (after sys.path, which is what finds it)

REPO = HERE.parent
FIXTURES = HERE / "notebook"
FEATURES = FIXTURES / "features.md"
TUTORIAL = REPO / "PYKING-TUTORIAL.md"
BUNDLE = REPO / "build" / "pyking.js"
MARKDOWN = REPO / "tools" / "notebook" / "assets" / "markdown.js"
WORKER = REPO / "tools" / "webrun" / "assets" / "pyking-worker.js"
DEFAULT_COMPILER = str(REPO / "pyk")
STEP_TIMEOUT = 300
SERVER_TIMEOUT = 20

# Short cases for the renderer, each with the HTML it must give. Most are
# CommonMark's own examples; the rest are the GitHub extensions and the
# notebook's own conventions.
CASES = [
    ("*foo bar*", "<p><em>foo bar</em></p>"),
    ("a * foo bar*", "<p>a * foo bar*</p>"),
    ("foo*bar*", "<p>foo<em>bar</em></p>"),
    ("foo_bar_", "<p>foo_bar_</p>"),
    ("**foo*bar*baz**", "<p><strong>foo<em>bar</em>baz</strong></p>"),
    ("*foo**bar**baz*", "<p><em>foo<strong>bar</strong>baz</em></p>"),
    ("*(**foo**)*", "<p><em>(<strong>foo</strong>)</em></p>"),
    ("foo***bar***baz", "<p>foo<em><strong>bar</strong></em>baz</p>"),
    ("*foo [bar](/url)*", '<p><em>foo <a href="/url">bar</a></em></p>'),
    ("[link *foo **bar** `#`*](/uri)",
     '<p><a href="/uri">link <em>foo <strong>bar</strong> <code>#</code></em></a></p>'),
    ("[foo [bar](/uri)](/uri)", '<p>[foo <a href="/uri">bar</a>](/uri)</p>'),
    ("![foo *bar*](/url)", '<p><img src="/url" alt="foo bar"></p>'),
    ("[a](<b c>)", '<p><a href="b c">a</a></p>'),
    ("[link](/url(foo))", '<p><a href="/url(foo)">link</a></p>'),
    ("``foo ` bar``", "<p><code>foo ` bar</code></p>"),
    ("[x](javascript:alert(1))", '<p><a href="#">x</a></p>'),
    ("para\n2. not a list", "<p>para\n2. not a list</p>"),
    ("- a\n- b\n\n- c",
     "<ul>\n<li><p>a</p>\n</li>\n<li><p>b</p>\n</li>\n<li><p>c</p>\n</li>\n</ul>"),
    ("~~a~~ ~b~ ~~~c~~~", "<p><del>a</del> <del>b</del> ~~~c~~~</p>"),
    ("www.example.com.", '<p><a href="http://www.example.com">www.example.com</a>.</p>'),
    ("costs $5 and $6", "<p>costs $5 and $6</p>"),
    ("x <span>y</span> & z &amp; <3", "<p>x <span>y</span> &amp; z &amp; &lt;3</p>"),
    ("[^n] with no definition", "<p>[^n] with no definition</p>"),
    ("```pyking norun\nx = 1\n```",
     '<pre class="pkn-code" data-lang="pyking"><code>x = 1</code></pre>'),
]

DRIVER = r"""// Drives the notebook's renderer and the compiler worker under node.
import fs from "node:fs";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const plan = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const { renderMarkdown } = await import(pathToFileURL(plan.markdown).href);
const failures = [];
let checks = 0;
const check = (label, ok, detail = "") => {
  checks += 1;
  if (!ok) failures.push(label + (detail ? ": " + detail : ""));
};

// 1. The renderer, on the fixture that uses every feature.
const features = renderMarkdown(fs.readFileSync(plan.features, "utf8"),
                                { baseURL: "doc/" });
if (plan.update) fs.writeFileSync(plan.golden, features.html);
const golden = fs.existsSync(plan.golden) ? fs.readFileSync(plan.golden, "utf8") : "";
check("features.md renders as features.html", features.html === golden,
      firstDifference(features.html, golden));
check("the front matter's title", features.title === "Every notebook feature",
      JSON.stringify(features.title));
check("math is noticed", features.math === true);
check("three runnable cells, with their attributes",
      JSON.stringify(features.cells.map((c) => c.attrs)) === JSON.stringify([
        { norun: false, readonly: false, error: false },
        { norun: false, readonly: false, error: true },
        { norun: false, readonly: true, error: false }]),
      JSON.stringify(features.cells.map((c) => c.attrs)));
check("the headings the contents list is made from",
      features.headings.map((h) => h.id).join(" ") ===
        "features code-cells lists tables quotes-and-callouts math footnotes "
        + "setext-heading features-1",
      features.headings.map((h) => h.id).join(" "));

// 2. The short cases.
for (const [source, want] of plan.cases) {
  const got = renderMarkdown(source).html.trim();
  check("renders " + JSON.stringify(source), got === want,
        "got " + JSON.stringify(got));
}

// 2b. A ```stdin or ```args block fills in the cell right after it, and
//     only that one.
const inputs = renderMarkdown(
  "```stdin\nfirst\nsecond\n```\n```args\na 'b c'\n```\n```pyking\nprint(1)\n```\n"
  + "\n```stdin\nlost\n```\n\nA paragraph.\n\n```pyking\nprint(2)\n```\n");
check("a stdin and an args block fill in the next cell",
      inputs.cells[0]?.stdin === "first\nsecond\n" && inputs.cells[0]?.args === "a 'b c'",
      JSON.stringify(inputs.cells[0]));
check("an input block is not shown on its own", !inputs.html.includes("first"),
      inputs.html);
check("anything between lets an input block go",
      inputs.cells[1]?.stdin === null, JSON.stringify(inputs.cells[1]));

// 3. The worker, loaded as the page loads it: `self` is the global
//    object, `importScripts` evaluates a file, and a synchronous fetch is
//    answered from the manifest below or, for the standard library, from
//    lib/ -- which is where a program's `import io` reads io.pyk from.
globalThis.self = globalThis;
globalThis.require = createRequire(import.meta.url);
// The worker makes the console its output pane, so the answer this
// driver prints goes through the console as it was.
const report = console.log.bind(console);
const replies = [];
self.postMessage = (message) => replies.push(message);
self.importScripts = (url) => (0, eval)(fs.readFileSync(plan.bundle, "utf8"));
const libURL = pathToFileURL(plan.lib).href + "/";
globalThis.XMLHttpRequest = class {
  open(method, url) { this.url = url; }
  send() {
    if (this.url.startsWith(libURL)) {
      const path = decodeURIComponent(this.url.slice("file://".length));
      this.status = fs.existsSync(path) ? 200 : 404;
      this.responseText = this.status === 200 ? fs.readFileSync(path, "utf8") : "";
      return;
    }
    this.status = 200;
    this.responseText = JSON.stringify({ bundle: "pyking.js", stamp: "test" });
  }
};
(0, eval)(fs.readFileSync(plan.worker, "utf8"));
let nextId = 1;
const ask = async (message) => {
  const id = nextId++;
  replies.length = 0;
  self.onmessage({ data: { id, ...message } });
  // A run that imports a JavaScript module answers once that import is
  // done; everything else answers before `onmessage` returns.
  for (let spins = 0; !replies.some((reply) => reply.id === id) && spins < 1000; spins++) {
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  const text = (type) =>
    replies.filter((reply) => reply.type === type).map((reply) => reply.text).join("");
  const answer = replies.find((reply) => reply.id === id);
  return { answer, printed: text("stdout"), debugged: text("debug"), read: text("stdin") };
};

const booted = await ask({ type: "init", pykingURL: "http://test/pyking/", libURL });
check("the worker boots", booted.answer?.type === "result",
      JSON.stringify(booted.answer));
const words = (await ask({ type: "words" })).answer?.value ?? {};
check("the worker answers the word lists",
      words.keywords?.includes("def") && words.builtins?.includes("print")
      && words.targets?.includes("pyking") && words.formatHelper?.includes("pykFormat"),
      JSON.stringify(words).slice(0, 160));

let cells = 0;
for (const document of plan.documents) {
  const rendered = renderMarkdown(fs.readFileSync(document.path, "utf8"));
  check(document.name + " has runnable cells", rendered.cells.length > 0);
  for (const cell of rendered.cells) {
    cells += 1;
    const label = `${document.name} cell ${cell.index + 1}`;
    const ran = await ask({ type: "run", source: cell.source, name: `cell-${cell.index + 1}.pyk` });
    const result = ran.answer?.value;
    if (cell.attrs.error) {
      check(label + " is refused, as marked", result?.ok === false,
            "it ran: " + JSON.stringify(ran.printed));
    } else {
      check(label + " runs", result?.ok === true, result?.text ?? JSON.stringify(ran.answer));
    }
    const expected = document.outputs?.[cell.index];
    if (expected !== undefined) {
      check(label + " prints what it should", ran.printed === expected,
            JSON.stringify(ran.printed));
    }
  }
}
// 4. The standard library in the page: io and sys are the worker's own,
//    reading what the page collected and writing to the pane.
const program = [
  "import io", "import sys",
  "name = io.read_line(\"who? \")",
  "debug(\"read\", name)",
  "print(\"hello\", name, sys.args(), io.is_eof() == false)",
  "print(io.read())",
  "sys.exit(3)",
  "print(\"never\")",
].join("\n") + "\n";
const analysis = (await ask({ type: "analyze", source: program, name: "reads.pyk" })).answer?.value;
check("a program reading stdin and sys.args says so",
      analysis?.ok && analysis.stdin && analysis.args
      && JSON.stringify(analysis.externals) === '["io","sys"]', JSON.stringify(analysis));
const quiet = (await ask({ type: "analyze", source: "import io\nio.write_line(\"x\")\n",
                           name: "w.pyk" })).answer?.value;
check("a program that only writes reads nothing", quiet?.ok && !quiet.stdin && !quiet.args,
      JSON.stringify(quiet));
const ran = await ask({ type: "run", source: program, name: "reads.pyk",
                        stdin: "Ada\nthe rest\n", args: ["a", "b c"] });
check("it runs to sys.exit(3)", ran.answer?.value?.ok && ran.answer.value.exit === 3,
      JSON.stringify(ran.answer));
check("it reads stdin and its arguments",
      ran.printed === "who? hello Ada ['a', 'b c'] true\nthe rest\n\n",
      JSON.stringify(ran.printed));
check("what it read is echoed", ran.read === "Ada\n", JSON.stringify(ran.read));
check("its debug line is marked apart", ran.debugged === "read Ada\n",
      JSON.stringify(ran.debugged));

report(JSON.stringify({ checks, cells, failures }));

function firstDifference(a, b) {
  if (!b) return "features.html is missing; run with --update";
  let i = 0;
  while (i < a.length && a[i] === b[i]) i++;
  const line = a.slice(0, i).split("\n").length;
  return `first difference on line ${line}: got `
    + JSON.stringify(a.slice(i, i + 60)) + ", expected " + JSON.stringify(b.slice(i, i + 60));
}
"""


def run_driver(update):
    """The renderer and cell checks, in one node process. Answers
    (checks, failures, cells), or (None, [message], 0) when node could
    not be run at all. Bool -> (Int?, [String], Int)"""
    plan = {
        "markdown": str(MARKDOWN),
        "worker": str(WORKER),
        "bundle": str(BUNDLE),
        "lib": str(REPO / "lib"),
        "features": str(FEATURES),
        "golden": str(FIXTURES / "features.html"),
        "update": update,
        "cases": CASES,
        "documents": [
            {"name": "PYKING-TUTORIAL.md", "path": str(TUTORIAL)},
            {"name": "features.md", "path": str(FEATURES),
             "outputs": {"0": "Hello world 2026\n", "2": "49\n"}},
        ],
    }
    with tempfile.TemporaryDirectory(prefix="pyk-notebook-") as directory:
        script = Path(directory) / "driver.mjs"
        script.write_text(DRIVER)
        plan_path = Path(directory) / "plan.json"
        plan_path.write_text(json.dumps(plan))
        try:
            result = subprocess.run(
                ["node", str(script), str(plan_path)],
                capture_output=True, text=True, timeout=STEP_TIMEOUT)
        except FileNotFoundError:
            return None, ["node not found; it is what runs the renderer"], 0
        except subprocess.TimeoutExpired:
            return None, [f"timed out after {STEP_TIMEOUT} seconds"], 0
    if result.returncode != 0 or not result.stdout.strip():
        detail = (result.stderr or result.stdout or "no output").strip()
        return None, [f"the driver did not finish: {detail.splitlines()[-1]}"], 0
    answer = json.loads(result.stdout.strip().splitlines()[-1])
    return answer["checks"], answer["failures"], answer["cells"]


# --- the server ------------------------------------------------------------


def free_port():
    """A port nothing is listening on. () -> Int"""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def fetch(port, path, method="GET"):
    """One request, with the path sent exactly as given.
    Int -> String -> String -> (Int, Bytes)"""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request(method, path)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def start(compiler, arguments, environment):
    """Starts `pyk` with arguments and waits for it to print its URL.
    Answers the process, or None with what it printed instead.
    [String] -> [String] -> {..} -> (Popen?, String)"""
    process = subprocess.Popen(
        compiler + arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, env=environment)
    lines = []
    # A thread, since a server that never prints its URL must not block
    # the suite: the deadline below is what gives up on it.
    reader = threading.Thread(
        target=lambda: lines.extend(iter(process.stdout.readline, "")), daemon=True)
    reader.start()
    deadline = time.monotonic() + SERVER_TIMEOUT
    while time.monotonic() < deadline:
        if any("http://" in line for line in lines):
            return process, "".join(lines)
        if process.poll() is not None:
            reader.join(timeout=1)
            return None, "".join(lines)
        time.sleep(0.05)
    process.kill()
    return None, "".join(lines) + " (timed out)"


def stop(process):
    """Ends a server started by `start`. Popen -> ()"""
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()


def check_server(compiler):
    """`pyk notebook` and `pyk playground` serve what their pages load, and
    `pyk notebook` refuses what it should. [String] -> (Int, [String])"""
    failures = []
    checks = 0

    def check(label, ok, detail=""):
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(label + (f": {detail}" if detail else ""))

    # The browser libraries are not needed to answer these requests, and a
    # fresh checkout has not downloaded them.
    environment = dict(os.environ, PYKING_WEB_NO_VENDOR="1")

    port = free_port()
    process, printed = start(
        compiler, ["notebook", "--port", str(port), str(FEATURES)], environment)
    check("`pyk notebook` starts and prints its URL", process is not None, printed)
    if process is not None:
        try:
            check("it serves on the port asked for", f"localhost:{port}/" in printed)
            for path in ["/", "/notebook/notebook.js", "/notebook/markdown.js",
                         "/notebook/notebook.css", "/webrun/web.js",
                         "/webrun/pyking-worker.js", "/webrun/pyking-runtime.js",
                         "/webrun/pyking-mode.js", "/lib/io/io.pyk",
                         "/lib/io/io_external.pyk",
                         "/lib/io/io_external_browser.js"]:
                status, _ = fetch(port, path)
                check(f"it serves {path}", status == 200, f"status {status}")
            status, body = fetch(port, "/notebook.json")
            check("notebook.json names the document",
                  status == 200 and json.loads(body).get("document") == FEATURES.name,
                  body[:80])
            status, body = fetch(port, "/doc/" + FEATURES.name)
            check("the document is served as it is on disk",
                  status == 200 and body == FEATURES.read_bytes())
            status, body = fetch(port, "/pyking/manifest.json")
            check("the compiler's manifest carries a stamp",
                  status == 200 and len(json.loads(body).get("stamp", "")) == 16)
            status, body = fetch(port, "/pyking/pyking.js")
            check("the compiler bundle is served whole",
                  status == 200 and len(body) == BUNDLE.stat().st_size)
            for path in ["/doc/../../Makefile", "/doc/%2e%2e/%2e%2e/Makefile",
                         "/doc/.hidden", "/nothing-here"]:
                status, _ = fetch(port, path)
                check(f"it refuses {path}", status == 404, f"status {status}")
        finally:
            stop(process)

    port = free_port()
    process, printed = start(
        compiler, ["playground", "--port", str(port)], environment)
    check("`pyk playground` starts and prints its URL", process is not None, printed)
    if process is not None:
        try:
            status, _ = fetch(port, "/")
            check("the playground serves its page", status == 200, f"status {status}")
            status, body = fetch(port, "/assets/playground.json")
            manifest = json.loads(body) if status == 200 else {}
            check("the playground's manifest lists targets and examples",
                  manifest.get("targets") and manifest.get("examples"),
                  f"status {status}")
            example = (manifest.get("examples") or [{"file": "?"}])[0]["file"]
            status, _ = fetch(port, "/examples/" + example)
            check("the playground serves an example", status == 200, f"status {status}")
        finally:
            stop(process)

    def refused(label, arguments, expected, env=None):
        result = subprocess.run(compiler + arguments, capture_output=True, text=True,
                                env=env or environment, timeout=SERVER_TIMEOUT)
        output = result.stdout + result.stderr
        check(label, result.returncode != 0 and expected in output, output.strip())

    refused("a missing file is refused", ["notebook", "no-such-file.md"],
            "no such file")
    refused("a file that is not Markdown is refused",
            ["notebook", str(REPO / "Makefile")], "is not a Markdown file")
    refused("a filename for the playground is refused",
            ["playground", str(FEATURES)], "takes no filename")
    with tempfile.TemporaryDirectory(prefix="pyk-notebook-") as directory:
        old = Path(directory) / "python-3.9"
        old.write_text("#!/bin/sh\necho '3 9'\n")
        old.chmod(0o755)
        refused("a Python older than 3.10 is refused", ["notebook", str(FEATURES)],
                "needs Python 3.10 or later", dict(environment, PYTHON=str(old)))
    refused("a Python that is not there is refused", ["notebook", str(FEATURES)],
            "could not be run",
            dict(environment, PYTHON=str(Path("/nonexistent") / "python3")))
    return checks, failures


# The oldest Python the web tools promise to run on (tools/webrun/server.py).
OLDEST_PYTHON = "3.10"
OLDEST_IMAGE = f"python:{OLDEST_PYTHON}-alpine"
# Run inside the oldest Python: both servers started, and what each page
# is driven by fetched from them.
OLDEST_SCRIPT = f"""
import os, subprocess, sys, time, urllib.request
os.environ["PYKING_WEB_NO_VENDOR"] = "1"
assert sys.version_info[:2] == ({OLDEST_PYTHON.replace(".", ", ")}), sys.version
servers = [subprocess.Popen([sys.executable, "tools/notebook/notebook.py", "--port", "8871",
                             "tests/notebook/features.md"], stdout=subprocess.DEVNULL),
           subprocess.Popen([sys.executable, "tools/playground/playground.py", "serve",
                             "--port", "8872"], stdout=subprocess.DEVNULL)]
try:
    for url in ["http://127.0.0.1:8871/notebook.json", "http://127.0.0.1:8872/assets/playground.json"]:
        for _ in range(50):
            try:
                urllib.request.urlopen(url).read()
                break
            except OSError:
                time.sleep(0.1)
        else:
            sys.exit("no answer from " + url)
finally:
    for server in servers:
        server.terminate()
print("ok")
"""


def check_oldest_python():
    """Whether the web tools run on the oldest Python they promise: with a
    `python3.10` on the PATH, or else in the python:3.10 Docker image if it
    is already here (nothing is downloaded). Answers (ran, problem?).
    () -> (Bool, String?)"""
    local = shutil.which(f"python{OLDEST_PYTHON}")
    if local:
        command, cwd = [local, "-c", OLDEST_SCRIPT], REPO
    elif shutil.which("docker") and subprocess.run(
            ["docker", "image", "inspect", OLDEST_IMAGE], capture_output=True).returncode == 0:
        command, cwd = ["docker", "run", "--rm", "-v", f"{REPO}:/src:ro", "-w", "/src",
                        OLDEST_IMAGE, "python3", "-c", OLDEST_SCRIPT], REPO
    else:
        return False, None
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True,
                            timeout=SERVER_TIMEOUT * 3)
    if result.stdout.strip() == "ok":
        return True, None
    return True, (result.stderr or result.stdout).strip().splitlines()[-1:] or ["failed"]


def parse_args(argv):
    """`--compiler CMD` and `--update`. [String] -> ([String], Bool)"""
    compiler = [DEFAULT_COMPILER]
    update = False
    rest = list(argv)
    while rest:
        flag = rest.pop(0)
        if flag == "--compiler" and rest:
            compiler = shlex.split(rest.pop(0))
        elif flag == "--update":
            update = True
        else:
            print("usage: test_notebook.py [--compiler CMD] [--update]",
                  file=sys.stderr)
            sys.exit(2)
    return compiler, update


def main(argv):
    """Runs the checks and reports them. [String] -> Int"""
    compiler, update = parse_args(argv)
    missing = [p for p in (BUNDLE, TUTORIAL, FEATURES) if not p.exists()]
    if missing:
        for path in missing:
            print(f"notebook: FAILED -- {path} is missing")
        suite.footer("notebook", 0, 1, "nothing to test")
        return 1

    checks, failures, cells = run_driver(update)
    for failure in failures:
        print(f"notebook: FAILED {failure}")
    if checks is None:
        suite.footer("notebook", 0, 1, "the renderer could not be driven")
        return 1
    print(f"notebook: renderer and {cells} cells, {checks} checks.")

    served, server_failures = check_server(compiler)
    ran, problem = check_oldest_python()
    if ran:
        served += 1
        if problem:
            server_failures.append(f"the web tools on Python {OLDEST_PYTHON}: {problem}")
        print(f"notebook: the web tools on Python {OLDEST_PYTHON}"
              f" {'FAILED' if problem else 'OK'}.")
    else:
        print(f"notebook: the web tools on Python {OLDEST_PYTHON} skipped "
              f"(no python{OLDEST_PYTHON}, and no {OLDEST_IMAGE} image here).")
    for failure in server_failures:
        print(f"notebook: FAILED {failure}")
    print(f"notebook: server, {served} checks.")

    total = checks + served
    failed = len(failures) + len(server_failures)
    suite.footer("notebook", total - failed, failed,
                 f"{len(CASES)} renderer cases, {cells} cells, the server")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
