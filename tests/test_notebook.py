#!/usr/bin/env python3
"""Runs the notebook's own test cases: that the Markdown renderer renders
what it should, that every cell of PYKING-TUTORIAL.md runs through the
compiler worker the page uses, and that `pyk notebook`, `pyk
playground` and `pyk serve` serve what their pages load and refuse what
they should.

Only the page part needs a browser, and it is skipped without one. The renderer is a pure module, so node runs
it directly; the worker is loaded under node with the few browser globals
it touches stubbed out; and the server is fetched over HTTP. The page
itself -- editors, keys, buttons -- is not covered here.

Five parts:

  renderer  tests/notebook/features.md, which uses every feature the
            renderer supports, against tests/notebook/features.html;
            then a list of short cases against the HTML CommonMark and
            GitHub give for them.
  cells     every runnable cell of PYKING-TUTORIAL.md and features.md,
            run through tools/webrun/assets/pyking-worker.js: an `error`
            cell must be refused, every other cell must run.
  server    `pyk notebook`, `pyk playground`, `pyk pykhelp` and `pyk serve` on a free
            port, each file the pages load fetched, the playground's
            manifest and every file tools/playground/playground.py's Site
            names compared with what pyk serves, the mode the page is
            told, and the refusals: a missing file, a file that is not
            Markdown, a mode there is none of, a missing directory, an
            address to listen on that is not one.
  test mode `pyk notebook --mode test` passes features.md, and reports
            exactly what tests/notebook/broken.out says about broken.md.
  page      where a Chromium is found (tests/suite.py, find_chromium) and
            the editor has been vendored (`make vendor`), features.md
            served and driven in it by tests/notebook/page.mjs: in
            student mode, exercises submitted wrong and right, quizzes
            answered, progress kept over a reload and forgotten by start
            over; in teacher mode, every solution, test and answer shown.

Usage: python3 tests/test_notebook.py [--compiler CMD] [--update]

`--update` rewrites features.html from what the renderer now produces,
and broken.out from what test mode now reports; read the diffs before
keeping them.

Functions:
    run_driver(update) -- the renderer and cell checks, in one node process.
    check_server(compiler) -- the server checks.
    check_test_mode(compiler, update) -- the test-mode checks.
    check_page(compiler, chromium) -- the page checks, in Chromium.
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
BUNDLE = REPO / "share" / "pyking.js"
MARKDOWN = REPO / "tools" / "notebook" / "assets" / "markdown.js"
EXERCISES = REPO / "tools" / "notebook" / "assets" / "exercises.js"
BROKEN = FIXTURES / "broken.md"
WORKER = REPO / "tools" / "webrun" / "assets" / "pyking-worker.js"
VENDOR = REPO / "tools" / "webrun" / "vendor" / "ace" / "ace.js"
PAGE_DRIVER = FIXTURES / "page.mjs"
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
     '<pre class="pkn-code" data-lang="pyking" data-part="0"><code>x = 1</code></pre>'),
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
const flags = (c) => Object.keys(c.attrs).filter((a) => c.attrs[a]).join("+") || "-";
check("fourteen runnable cells, with their attributes",
      features.cells.map(flags).join(" ") ===
        "- error readonly - readonly error - - - exercise solution exercise exercise solution",
      features.cells.map(flags).join(" "));
check("a cell's input from its header, and from a block before it",
      features.cells[3].stdin === "Ada\n" && features.cells[3].args === "first 'second one'"
      && features.cells[4].stdin === "7\n" && features.cells[6].stdin === "Grace\n",
      JSON.stringify(features.cells.slice(3, 7).map((c) => [c.stdin, c.args])));
check("the headings the contents list is made from",
      features.headings.map((h) => h.id).join(" ") ===
        "features code-cells exercises-and-quizzes lists tables quotes-and-callouts math "
        + "footnotes setext-heading features-1",
      features.headings.map((h) => h.id).join(" "));

// 1b. What exercises.js makes of it.
const nb = features.notebook;
check("features.md has no notebook problems", nb.problems.length === 0,
      JSON.stringify(nb.problems));
check("the rules: max 10, pass 8", nb.rules?.max === 10 && nb.rules?.pass === 8,
      JSON.stringify(nb.rules));
check("three exercises and two quizzes, in order",
      nb.items.map((i) => i.id).join(" ") === "exercise-1 exercise-2 exercise-3 quiz-1 quiz-2",
      nb.items.map((i) => i.id).join(" "));
const [ex1, ex2, ex3, quiz1, quiz2] = nb.items;
check("exercise 1: header, solution and three tests",
      ex1.attempts === 3 && ex1.points === 5 && ex1.stdin === "123\n" && ex1.args === "go for it"
      && ex1.solution?.available === true && ex1.tests.length === 3
      && ex1.tests[0].args === "my 123" && ex1.tests[0].output === null
      && ex1.tests[1].output?.text.startsWith("Another") && ex1.tests[2].stdin === null,
      JSON.stringify(ex1).slice(0, 300));
check("exercise 2: no solution, no points, a stdout",
      ex2.solution === null && ex2.points === null && ex2.attempts === null
      && ex2.tests.length === 1 && ex2.tests[0].output.attrs.visible === "true",
      JSON.stringify(ex2).slice(0, 300));
check("exercise 3: a solution that is not available, and a penalty",
      ex3.solution?.available === false && ex3.penalty === 1 && ex3.attempts === 2,
      JSON.stringify(ex3).slice(0, 300));
check("quiz 1: one answer, from *", !quiz1.multiple && quiz1.alternatives.length === 2
      && quiz1.answers.map((a) => a.correct).join() === "true,false" && !quiz1.available,
      JSON.stringify(quiz1).slice(0, 300));
check("quiz 2: any answers, from [], with an empty explanation",
      quiz2.multiple && quiz2.available && quiz2.attempts === 2 && quiz2.penalty === 1
      && quiz2.answers.map((a) => a.correct).join() === "true,false,true"
      && quiz2.answers[2].html === "" && quiz2.alternatives[0].html.includes("<code>var</code>"),
      JSON.stringify(quiz2).slice(0, 300));
check("examples under ordinary cells: one shown, one with input and stderr",
      nb.examples.length === 2 && nb.examples[0].tests[0].output.text === "my out"
      && nb.examples[1].tests[0].stdin === "echo me\n" && nb.examples[1].tests[0].error !== null,
      JSON.stringify(nb.examples).slice(0, 300));

// 1c. The fence header's attributes, and the grading arithmetic.
const { parseInfo } = await import(pathToFileURL(plan.markdown).href);
const grading = await import(pathToFileURL(plan.exercises).href);
for (const [info, want] of [
  ['pyking exercise attempts = 3 stdin = "1 2" points=5',
   { exercise: true, attempts: "3", stdin: "1 2", points: "5" }],
  ["stdin args='a \\'b\\' c' visible=true", { args: "a 'b' c", visible: "true" }],
  ['pyking stdin = "two\\nlines"', { stdin: "two\nlines" }],
  ["{.pyking .norun}", { norun: true }],
  ["pyking norun, readonly", { norun: true, readonly: true }],
]) {
  const got = parseInfo(info).attrs;
  check("reads the fence header " + JSON.stringify(info),
        JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
}
check("output is compared without trailing spaces or blank lines",
      grading.sameOutput("a  \nb\n\n\n", "a\nb") && !grading.sameOutput("a\n b", "a\nb"));
const radio = { multiple: false, answers: [{ correct: false }, { correct: true }] };
const boxes = { multiple: true, answers: [{ correct: true }, { correct: false }, { correct: true }] };
check("a quiz answer: right, wrong, and a right one missed",
      grading.checkQuiz(radio, [1]).correct && !grading.checkQuiz(radio, [0]).correct
      && JSON.stringify(grading.checkQuiz(boxes, [0, 1])) === '{"correct":false,"missed":true,"wrong":[1]}'
      && grading.checkQuiz(boxes, [2, 0]).correct,
      JSON.stringify(grading.checkQuiz(boxes, [0, 1])));
check("points less the penalty for each failure, never below 0",
      grading.award({ points: 5, penalty: 2 }, 0) === 5 && grading.award({ points: 5, penalty: 2 }, 2) === 1
      && grading.award({ points: 5, penalty: 2 }, 3) === 0 && grading.award({ points: null, penalty: 0 }, 0) === 0);
const totals = grading.summary(nb, { "exercise-1": { state: "solved", points: 5 },
  "quiz-1": { state: "solved", points: 2 }, "quiz-2": { state: "failed", points: 0 } });
check("the totals: solved, points, and whether they pass",
      totals.solved === 2 && totals.total === 5 && totals.points === 7 && totals.max === 10
      && totals.passed === false && totals.done === false, JSON.stringify(totals));

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
        "exercises": str(EXERCISES),
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
                         "/notebook/notebook.css", "/notebook/exercises.js",
                         "/notebook/activities.js", "/webrun/web.js",
                         "/webrun/pyking-worker.js", "/webrun/pyking-runtime.js",
                         "/webrun/pyking-mode.js", "/lib/io/io.pyk",
                         "/lib/io/io_external.pyk",
                         "/lib/io/io_external_browser.js"]:
                status, _ = fetch(port, path)
                check(f"it serves {path}", status == 200, f"status {status}")
            status, body = fetch(port, "/notebook.json")
            check("notebook.json names the document, in student mode",
                  status == 200 and json.loads(body).get("document") == FEATURES.name
                  and json.loads(body).get("mode") == "student",
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
        compiler, ["notebook", "--port", str(port), "--mode", "teacher", str(FEATURES)],
        environment)
    check("`pyk notebook --mode teacher` starts", process is not None, printed)
    if process is not None:
        try:
            status, body = fetch(port, "/notebook.json")
            check("notebook.json says teacher mode",
                  status == 200 and json.loads(body).get("mode") == "teacher", body[:80])
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
            check("the playground's manifest names pyk's version",
                  manifest.get("version") == (REPO / "VERSION").read_text().strip(),
                  manifest.get("version"))
            check("the playground's manifest lists targets and examples",
                  manifest.get("targets") and manifest.get("examples"),
                  f"status {status}")
            example = (manifest.get("examples") or [{"file": "?"}])[0]["file"]
            status, _ = fetch(port, "/examples/" + example)
            check("the playground serves an example", status == 200, f"status {status}")
            sys.path.insert(0, str(REPO / "tools" / "webrun"))
            sys.path.insert(0, str(REPO / "tools" / "playground"))
            import playground
            check("its manifest is the one tools/playground/playground.py builds",
                  manifest == json.loads(playground.page_manifest()))
            # The website copies the pages' runtime from playground.py's
            # Site, so pyk must serve what it names, byte for byte.
            site = playground.site()
            paths = list(site.files)
            for prefix, directory in site.mounts.items():
                first = next((f for f in sorted(Path(directory).rglob("*"))
                              if f.is_file() and not f.name.startswith(".")), None)
                if first is not None:
                    paths.append(prefix + first.relative_to(directory).as_posix())
            for path in paths:
                status, body = fetch(port, path)
                wanted = site.resolve(path)
                if wanted is not None and wanted.is_dir():
                    wanted = wanted / "index.html"
                check(f"it serves {path} as playground.py's Site names it",
                      status == 200 and body == wanted.read_bytes(), f"status {status}")
            status, body = fetch(port, "/pyking/manifest.json", "HEAD")
            check("a HEAD answers with no body", status == 200 and body == b"", f"status {status}")
            status, _ = fetch(port, "/assets/nothing", "POST")
            check("a POST is not answered", status == 501, f"status {status}")
        finally:
            stop(process)

    port = free_port()
    process, printed = start(compiler, ["pykhelp", "--port", str(port)], environment)
    check("`pyk pykhelp` starts and prints its URL", process is not None, printed)
    if process is not None:
        try:
            status, body = fetch(port, "/")
            check("the help serves its page",
                  status == 200 and b"mountHelp" in body, f"status {status}")
            status, body = fetch(port, "/help/pages/index.json")
            index = json.loads(body) if status == 200 else {}
            check("it serves the help's index", bool(index.get("sections")), f"status {status}")
            page = next((p for s in index.get("sections", []) for p in s["pages"]
                         if p["slug"] == "libraries/io"), None)
            status, body = fetch(port, "/help/pages/" + (page or {}).get("file", "?"))
            check("and a page of it", status == 200 and b"pyk-api" in body, f"status {status}")
            status, _ = fetch(port, "/notebook/notebook.js")
            check("and the notebook that runs its cells", status == 200, f"status {status}")
        finally:
            stop(process)

    with tempfile.TemporaryDirectory(prefix="pyk-serve-") as directory:
        (Path(directory) / "page.html").write_text("<p>page</p>\n")
        (Path(directory) / "sub").mkdir()
        (Path(directory) / "sub" / "index.html").write_text("<p>sub</p>\n")
        port = free_port()
        process, printed = start(compiler, ["serve", "--port", str(port), directory],
                                 dict(environment, PATH=directory))
        check("`pyk serve` starts with nothing on the PATH", process is not None, printed)
        if process is not None:
            try:
                status, body = fetch(port, "/page.html")
                check("it serves a file as it is", status == 200 and body == b"<p>page</p>\n",
                      f"status {status}")
                status, body = fetch(port, "/")
                check("it lists a directory with no index.html",
                      status == 200 and b'href="page.html"' in body, f"status {status}")
                status, _ = fetch(port, "/sub")
                check("a directory without its / is redirected", status == 301, f"status {status}")
                status, body = fetch(port, "/sub/")
                check("a directory's index.html is its page",
                      status == 200 and body == b"<p>sub</p>\n", f"status {status}")
                status, _ = fetch(port, "/../etc/passwd")
                check("nothing above the directory is served", status == 404, f"status {status}")
            finally:
                stop(process)

    def refused(label, arguments, expected, env=None):
        result = subprocess.run(compiler + arguments, capture_output=True, text=True,
                                env=env or environment, timeout=SERVER_TIMEOUT)
        output = result.stdout + result.stderr
        # pyk reflows a message to 70 columns, so where a line breaks
        # depends on how long the paths in it are.
        flowed = " ".join(output.split())
        check(label, result.returncode != 0 and expected in flowed, output.strip())

    refused("a missing file is refused", ["notebook", "no-such-file.md"],
            "no such file")
    refused("a file that is not Markdown is refused",
            ["notebook", str(REPO / "Makefile")], "is not a Markdown file")
    refused("an unknown mode is refused", ["notebook", "--mode", "exam", str(FEATURES)],
            "--mode is student, teacher or test")
    refused("--mode test with a port is refused",
            ["notebook", "--mode", "test", "--port", "8000", str(FEATURES)],
            "takes no --port")
    refused("--mode for anything but the notebook is refused",
            ["compile", "--mode", "test", str(FEATURES)], "only applies to 'pyk notebook'")
    refused("a filename for the playground is refused",
            ["playground", str(FEATURES)], "takes no filename")
    refused("a filename for the help is refused", ["pykhelp", str(FEATURES)],
            "takes no filename")
    refused("a directory that is not there is refused", ["serve", "no-such-directory"],
            "no such directory")
    refused("a PYKING_WEB_HOST that is not an address is refused", ["serve", str(REPO)],
            "PYKING_WEB_HOST is \"nowhere\", not an IPv4 address",
            dict(environment, PYKING_WEB_HOST="nowhere"))
    return checks, failures


def check_test_mode(compiler, update):
    """`pyk notebook --mode test` passes features.md, and reports what
    broken.out says about broken.md, line by line. [String] -> Bool ->
    (Int, [String])"""
    failures = []
    environment = dict(os.environ, PYKING_WEB_NO_VENDOR="1")

    def mode_test(document):
        return subprocess.run(compiler + ["notebook", "--mode", "test",
                                          str(document.relative_to(REPO))],
                              cwd=REPO, capture_output=True, text=True,
                              env=environment, timeout=STEP_TIMEOUT)

    good = mode_test(FEATURES)
    if good.returncode != 0:
        failures.append("features.md passes test mode: "
                        + (good.stdout + good.stderr).strip())
    bad = mode_test(BROKEN)
    golden = BROKEN.with_suffix(".out")
    if update:
        golden.write_text(bad.stdout)
    expected = golden.read_text() if golden.exists() else ""
    if bad.returncode != 1:
        failures.append(f"broken.md fails test mode: it ended with {bad.returncode}: "
                        + bad.stderr.strip())
    if bad.stdout != expected:
        got, want = bad.stdout.splitlines(), expected.splitlines()
        k = next((k for k in range(max(len(got), len(want)))
                  if k >= len(got) or k >= len(want) or got[k] != want[k]), 0)
        failures.append("broken.md is reported as broken.out says: line "
                        f"{k + 1}: got {got[k] if k < len(got) else None!r}, "
                        f"expected {want[k] if k < len(want) else None!r}")
    return 2, failures


def check_page(compiler, chromium):
    """features.md served in each mode and driven in Chromium by
    page.mjs. [String] -> String -> (Int, [String])"""
    checks, failures = 0, []
    for mode in ("student", "teacher"):
        port = free_port()
        process, printed = start(
            compiler, ["notebook", "--port", str(port), "--mode", mode, str(FEATURES)],
            dict(os.environ))
        if process is None:
            checks += 1
            failures.append(f"{mode}: the notebook did not start: {printed}")
            continue
        try:
            ran = suite.run_with_progress(
                ["node", str(PAGE_DRIVER), chromium, f"http://127.0.0.1:{port}/", mode],
                "the page in Chromium", STEP_TIMEOUT)
            try:
                result = json.loads(ran.stdout)
            except json.JSONDecodeError:
                result = {"checks": 1, "failures": [
                    f"{mode}: the driver did not answer: {(ran.stderr or ran.stdout).strip()[-300:]}"]}
            checks += result["checks"]
            failures += result["failures"]
        finally:
            stop(process)
    return checks, failures


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
    for failure in server_failures:
        print(f"notebook: FAILED {failure}")
    print(f"notebook: server, {served} checks.")

    tested, test_failures = check_test_mode(compiler, update)
    for failure in test_failures:
        print(f"notebook: FAILED {failure}")
    print(f"notebook: test mode, {tested} checks.")

    chromium = suite.find_chromium()
    if chromium is None or not VENDOR.exists():
        why = "no Chromium found" if chromium is None else "no vendored editor (make vendor)"
        print(f"notebook: the page in a browser skipped ({why}).")
    else:
        paged, page_failures = check_page(compiler, chromium)
        test_failures += page_failures
        tested += paged
        for failure in page_failures:
            print(f"notebook: FAILED {failure}")
        print(f"notebook: the page in Chromium, {paged} checks.")

    total = checks + served + tested
    failed = len(failures) + len(server_failures) + len(test_failures)
    suite.footer("notebook", total - failed, failed,
                 f"{len(CASES)} renderer cases, {cells} cells, the server")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
