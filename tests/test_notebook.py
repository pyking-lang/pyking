#!/usr/bin/env python3
"""Runs the notebook's own test cases: that the Markdown renderer renders
what it should, that every cell of tests/notebook/features.md runs
through the compiler worker the page uses, and that `pyk notebook`, `pyk
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
            GitHub give for them; and what tasks.js makes of
            tests/notebook/drawing.md -- a task submitted with git,
            a solution saving a picture, stdin split into tests -- and of
            the headers it refuses.
  cells     every runnable cell of features.md,
            run through tools/webrun/assets/pyking-worker.js: an `error`
            cell must be refused, every other cell must run.
  server    `pyk notebook`, `pyk playground`, `pyk pykhelp` and `pyk serve` on a free
            port, each file the pages load fetched, the playground's
            manifest and every file tools/playground/playground.py's Site
            names compared with what pyk serves, the mode the page is
            told, and the refusals: a missing file, a file that is not
            Markdown, a mode there is none of, a missing directory, an
            address to listen on that is not one; and what POST /save/
            writes beside a copy of drawing.md, and refuses.
  test mode `pyk notebook --mode test` passes features.md and drawing.md, and reports
            exactly what tests/notebook/broken.out says about broken.md.
  page      where a Chromium is found (tests/suite.py, find_chromium) and
            the editor has been vendored (`make vendor`), features.md
            served and driven in it by tests/notebook/page.mjs: in
            student mode, tasks submitted wrong and right, quizzes
            answered, progress kept over a reload and forgotten by start
            over; in teacher mode, every solution, test and answer shown.
            Then drawing.md in each: its picture made, shown and saved,
            and for a student answers that fail with the diff of the
            first test that did not match, and answers that pass.

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
BUNDLE = REPO / "share" / "pyking.js"
MARKDOWN = REPO / "tools" / "notebook" / "assets" / "markdown.js"
TASKS = REPO / "tools" / "notebook" / "assets" / "tasks.js"
BROKEN = FIXTURES / "broken.md"
DRAWING = FIXTURES / "drawing.md"
ACTIVITIES = REPO / "tools" / "notebook" / "assets" / "activities.js"
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
check("twenty-nine runnable cells, with their attributes",
      features.cells.map(flags).join(" ") ===
        "- error readonly - readonly error - - - - task solution practice task solution practice solution practice solution "
        + "practice solution practice solution practice solution readonly+task solution practice solution",
      features.cells.map(flags).join(" "));
check("a cell's input from its header, and from a block before it",
      features.cells[3].stdin === "Ada\n" && features.cells[3].args === "first 'second one'"
      && features.cells[4].stdin === "7\n" && features.cells[6].stdin === "Grace\n",
      JSON.stringify(features.cells.slice(3, 7).map((c) => [c.stdin, c.args])));
check("the headings the contents list is made from",
      features.headings.map((h) => h.id).join(" ") ===
        "features code-cells tasks-and-quizzes lists tables quotes-and-callouts math "
        + "footnotes setext-heading features-1",
      features.headings.map((h) => h.id).join(" "));

// 1b. What tasks.js makes of it.
const nb = features.notebook;
check("features.md has no notebook problems", nb.problems.length === 0,
      JSON.stringify(nb.problems));
check("the rules: max 12, pass 9", nb.rules?.max === 12 && nb.rules?.pass === 9,
      JSON.stringify(nb.rules));
check("three tasks, seven practices and three quizzes, in order, each numbered as its kind",
      nb.items.map((i) => i.id).join(" ")
        === "task-1 practice-1 task-2 practice-2 practice-3 quiz-1 quiz-2 quiz-3 practice-4 practice-5 practice-6 task-3 practice-7",
      nb.items.map((i) => i.id).join(" "));
const [ex1, ex2, ex3, counter, limited, quiz1, quiz2, quiz3, doubled, dot, loosely, git] = nb.items;
check("names: a task's and a quiz's, and none where none is given",
      ex1.name === "twice" && quiz1.name === "typed" && ex2.name === null && quiz2.name === null,
      JSON.stringify(nb.items.map((i) => i.name)));
check("a task's events: one test, its clicks delivered after the top level",
      counter.tests.length === 1 && counter.tests[0].events === 'click "More"\nclick "More"'
      && counter.tests[0].output?.text === "1\n2" && counter.tests[0].stdin === null,
      JSON.stringify(counter.tests.map((t) => [t.events, t.output?.text])));
check("task 1: header, solution and three tests",
      ex1.attempts === 3 && ex1.points === 5 && ex1.stdin === "123\n" && ex1.args === "go for it"
      && ex1.solution?.available === true && ex1.tests.length === 3
      && ex1.tests[0].args === "my 123" && ex1.tests[0].output === null
      && ex1.tests[1].output?.text.startsWith("Another") && ex1.tests[2].stdin === null,
      JSON.stringify(ex1).slice(0, 300));
check("a practice: no solution, no points, a stdout",
      ex2.practice && !ex1.practice && ex2.solution === null && ex2.points === null && ex2.attempts === null
      && ex2.tests.length === 1 && ex2.tests[0].output.attrs.visible === "true",
      JSON.stringify(ex2).slice(0, 300));
check("task 2: a solution that is not available, and a penalty",
      ex3.solution?.available === false && ex3.penalty === 1 && ex3.attempts === 2,
      JSON.stringify(ex3).slice(0, 300));
check("a practice's max_calls: print at most twice",
      JSON.stringify(limited.maxCalls) === '[{"max":2,"name":"print"}]',
      JSON.stringify(limited.maxCalls));
check("lines_per_multi_input: a test for every line",
      JSON.stringify(doubled.tests.map((t) => t.stdin)) === '["1\\n","2\\n","3\\n"]',
      JSON.stringify(doubled.tests.map((t) => t.stdin)));
check("a solution with its own input saves its canvas as a picture",
      JSON.stringify(dot.solution.picture) === '{"canvas":"canvas","file":"dot.png"}'
      && features.cells[dot.solution.cell].stdin === "8\n" && features.cells[dot.solution.cell].args === "blue",
      JSON.stringify(dot.solution));
check("a practice compared loosely: a stderr test and all four blocks",
      loosely.tests.length === 1 && loosely.tests[0].error?.text === "checked"
      && JSON.stringify(loosely.allowed.map((r) => r.kind)) === '["number","last","any","any","chars"]'
      && loosely.allowedParts.map((p) => p.kind).join() === "diff-allowed,optional-last,any-order,ignore-chars",
      JSON.stringify([loosely.tests, loosely.allowed]));
const start = features.notebook.items.find((item) => item.name === "start");
check("a solution's run_on_submit, false where it is not given",
      start?.solution?.runOnSubmit === true && ex1.solution?.runOnSubmit === false
      && loosely.solution?.runOnSubmit === false,
      JSON.stringify(nb.items.map((i) => i.solution?.runOnSubmit)));
check("a practice compared as far as its compare-until says",
      start?.until?.events === 4 && start.until.rules.map((r) => r.text).join() === "sdelay*"
      && start.allowedParts.map((p) => p.kind).join() === "compare-until",
      JSON.stringify(start?.until));
check("a read-only task submitted with git",
      git.method === "git" && features.cells[git.cell].attrs.readonly === true,
      JSON.stringify(git).slice(0, 300));
check("an args block before a cell, and the other header form",
      features.cells[7].args === 'one "two three"' && features.html.includes("def g(x)"),
      JSON.stringify(features.cells[7]));
check("quiz 1: one answer, from *", !quiz1.multiple && quiz1.alternatives.length === 2
      && quiz1.answers.map((a) => a.correct).join() === "true,false" && !quiz1.available,
      JSON.stringify(quiz1).slice(0, 300));
check("quiz 2: any answers, from [], with an empty explanation",
      quiz2.multiple && quiz2.available && quiz2.attempts === 2 && quiz2.penalty === 1
      && quiz2.answers.map((a) => a.correct).join() === "true,false,true"
      && quiz2.answers[2].html === "" && quiz2.alternatives[0].html.includes("<code>var</code>"),
      JSON.stringify(quiz2).slice(0, 300));
check("quiz 3: its question inside, one point per right answer, one attempt",
      quiz3.multiple && quiz3.onePointCorrect && quiz3.points === 2 && quiz3.attempts === 1
      && quiz3.question === "<p>Why can static type checking be useful?</p>"
      && quiz3.alternatives.length === 5 && quiz3.alternatives[4].text.includes("OCaml")
      && quiz3.answers.map((a) => a.correct).join() === "false,true,false,true,false",
      JSON.stringify(quiz3).slice(0, 300));
check("examples under ordinary cells: one shown, one with input and stderr",
      nb.examples.length === 2 && nb.examples[0].tests[0].output.text === "my out"
      && nb.examples[1].tests[0].stdin === "echo me\n" && nb.examples[1].tests[0].error !== null,
      JSON.stringify(nb.examples).slice(0, 300));

// 1c. The fence header's attributes, and the grading arithmetic.
const { parseInfo } = await import(pathToFileURL(plan.markdown).href);
const grading = await import(pathToFileURL(plan.tasks).href);
for (const [info, want] of [
  ['pyking task attempts = 3 stdin = "1 2" points=5',
   { task: true, attempts: "3", stdin: "1 2", points: "5" }],
  ["stdin args='a \\'b\\' c' visible=true", { args: "a 'b' c", visible: "true" }],
  ['pyking stdin = "two\\nlines"', { stdin: "two\nlines" }],
  ["{.pyking .norun}", { norun: true }],
  ["pyking norun, readonly", { norun: true, readonly: true }],
  ["pyking practice max_calls = (2,rect) (1, circle) name = x",
   { practice: true, max_calls: "(2,rect) (1, circle)", name: "x" }],
]) {
  const got = parseInfo(info).attrs;
  check("reads the fence header " + JSON.stringify(info),
        JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
}
check("a name is counted outside comments and strings, as a whole name",
      grading.callCount('tw.rect(1)\n# rect\ns = "rect" ++ \'\\\'rect\'\nrect_w = rect(2)\nint::rect(rectangle)\n', "rect") === 3
      && JSON.stringify(grading.overCalls("rect(1)\nrect(2)\n", [{ max: 1, name: "rect" }]))
        === '{"name":"rect","count":2,"max":1}'
      && grading.overCalls("rect(1)\n", [{ max: 1, name: "rect" }]) === null);
check("output is compared without trailing spaces or blank lines",
      grading.sameOutput("a  \nb\n\n\n", "a\nb") && !grading.sameOutput("a\n b", "a\nb"));
const radio = { multiple: false, answers: [{ correct: false }, { correct: true }] };
const boxes = { multiple: true, answers: [{ correct: true }, { correct: false }, { correct: true }] };
check("a quiz answer: right, wrong, and a right one missed",
      grading.checkQuiz(radio, [1]).correct && !grading.checkQuiz(radio, [0]).correct
      && JSON.stringify(grading.checkQuiz(boxes, [0, 1])) === '{"correct":false,"missed":true,"wrong":[1]}'
      && grading.checkQuiz(boxes, [2, 0]).correct,
      JSON.stringify(grading.checkQuiz(boxes, [0, 1])));
const scored = { multiple: true, onePointCorrect: true, points: 2, penalty: 0,
  answers: [{ correct: false }, { correct: true }, { correct: false }, { correct: true }] };
check("one point per right answer, none for choosing more than there are",
      grading.rightAnswers(scored) === 2
      && grading.quizAward(scored, [1, 3], 0) === 2 && grading.quizAward(scored, [1], 0) === 1
      && grading.quizAward(scored, [0, 1], 0) === 1 && grading.quizAward(scored, [0, 2], 0) === 0
      && grading.quizAward(scored, [0, 1, 3], 0) === 0
      && grading.quizAward({ ...scored, penalty: 1 }, [1, 3], 1) === 1
      && grading.quizAward({ ...boxes, onePointCorrect: false, points: 2, penalty: 0 }, [0, 2], 0) === 2
      && grading.quizAward({ ...boxes, onePointCorrect: false, points: 2, penalty: 0 }, [0], 0) === 0);
check("points less the penalty for each failure, never below 0",
      grading.award({ points: 5, penalty: 2 }, 0) === 5 && grading.award({ points: 5, penalty: 2 }, 2) === 1
      && grading.award({ points: 5, penalty: 2 }, 3) === 0 && grading.award({ points: null, penalty: 0 }, 0) === 0);
const totals = grading.summary(nb, { "task-1": { state: "solved", points: 5 },
  "quiz-1": { state: "solved", points: 2 }, "quiz-2": { state: "failed", points: 0 } });
check("the totals: solved, points, and whether they pass",
      totals.solved === 2 && totals.total === 12 && totals.points === 7 && totals.max === 12
      && totals.passed === false && totals.done === false, JSON.stringify(totals));

// 1d. A task submitted with git, a solution that saves a picture,
//     and stdin blocks split into several tests.
const drawing = renderMarkdown(fs.readFileSync(plan.drawing, "utf8"), { baseURL: "doc/" }).notebook;
check("drawing.md has no notebook problems", drawing.problems.length === 0,
      JSON.stringify(drawing.problems));
const [square, doubling, elsewhere] = drawing.items;
check("a task is answered in the page unless it says method = git",
      square.method === "inline" && doubling.method === "inline" && elsewhere.method === "git"
      && grading.graded(square) && !grading.graded(elsewhere),
      JSON.stringify(drawing.items.map((i) => i.method)));
check("a solution saves its canvas as a picture",
      JSON.stringify(square.solution.picture) === '{"canvas":"canvas","file":"square.png"}'
      && doubling.solution.picture === null
      && JSON.stringify(grading.pictures(drawing).map((p) => [p.task.id, p.file]))
        === '[["task-1","square.png"]]',
      JSON.stringify(square.solution));
check("a solution is shown to a student only where it says available = true",
      elsewhere.solution.available === false && square.solution.available === false);
check("lines_per_multi_input splits a stdin block into tests",
      JSON.stringify(square.tests.map((t) => t.stdin)) === '["10\\n","20\\n","30\\n"]'
      && JSON.stringify(doubling.tests.map((t) => t.stdin)) === '["1\\n2\\n","3\\n4\\n"]'
      && doubling.tests.every((t) => t.input === doubling.tests[0].input),
      JSON.stringify([square.tests.map((t) => t.stdin), doubling.tests.map((t) => t.stdin)]));
const drawn = grading.summary(drawing, { "task-1": { state: "solved", points: 2 } });
check("a task submitted with git is left out of the totals",
      drawn.total === 3 && drawn.solved === 1 && drawn.points === 2 && drawn.max === 9,
      JSON.stringify(drawn));
for (const [header, problem] of [
  ["```pyking task method = svn\n```\n", "method is inline or git, not 'svn'"],
  ["```pyking task method = code_box\n```\n", "method code_box is now called inline"],
  ["```pyking task name = \"two words\"\n```\n", "a name is letters, digits"],
  ["```pyking task name = \"a\"\n```\n```stdout\n\n```\n\nText.\n\n```quiz name = \"a\"\n* x\n```\n```answer\n-> y\n```\n",
   "the name 'a' is given to the item on line 1 too"],
  ["```events\nclick \"go\"\n```\n", "an events block belongs under a cell or a task"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```stdin lines_per_multi_input = 1\n1\n```\n```events\nclick \"go\"\n```\n```stdout\n1\n```\n",
   "compared with the solution"],
  ["```pyking task\n```\n```pyking solution save_canvas = \"c\"\nprint(1)\n```\n",
   "save_canvas = needs file"],
  ["```pyking task\n```\n```pyking solution save_canvas = \"c\" file = \"../x.png\"\nprint(1)\n```\n",
   "file is a .png beside the notebook"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```stdin lines_per_multi_input = 2\n1\n2\n3\n```\n",
   "are not pieces of 2"],
  ["```pyking task\n```\n```stdin lines_per_multi_input = 1\n1\n```\n```stdout\n1\n```\n",
   "compared with the solution"],
  ["```diff-allowed\nx [+/-1]\n```\n", "belongs under a task"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```diff-allowed\nx [1]\n```\n",
   "holds +/- and a number"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```diff-allowed\nno slot here\n```\n",
   "needs a [+/-N]"],
  ["```optional-last\nsdelay*\n```\n", "an optional-last block belongs under a task"],
  ["```pyking task\n```\n```optional-last\nsdelay*\n```\n", "which this task does not have"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```optional-last\n```\n",
   "an optional-last block needs at least one line"],
  ["```ignore-chars chars = \" \"\npoint*\n```\n", "an ignore-chars block belongs under a task"],
  ["```pyking task\n```\n```ignore-chars chars = \" \"\npoint*\n```\n", "which this task does not have"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```ignore-chars\npoint*\n```\n",
   "an ignore-chars block says which characters to ignore"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```ignore-chars chars = \"\"\npoint*\n```\n",
   "an ignore-chars block says which characters to ignore"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```ignore-chars chars = \" \"\n```\n",
   "an ignore-chars block needs at least one line"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```ignore-chars chars = \" \" all\npoint*\n```\n",
   "an ignore-chars block takes no attribute 'all'"],
  ["```compare-until events = 8\nsdelay*\n```\n", "a compare-until block belongs under a task"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```compare-until\nsdelay*\n```\n",
   "says how many events to compare, as events = 60"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```compare-until events = 0\nsdelay*\n```\n",
   "events is a whole number of at least 1, not '0'"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```compare-until events = 3\n```\n",
   "a compare-until block needs at least one line"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```compare-until events = 3\nsdelay*\n```\n"
   + "```compare-until events = 4\nsdelay*\n```\n", "a task has one compare-until block, and this is a second"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```compare-until events = 3 chars = \"x\"\nsdelay*\n```\n",
   "a compare-until block takes no attribute 'chars'"],
  ["```any-order\nANY: x*\n```\n", "an any-order block belongs under a task"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```any-order\nplay*\n```\n",
   "starts with BETWEEN: or ANY:"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```any-order\nANY:\n```\n",
   "needs a pattern after ANY"],
  ["```pyking task\n```\n```pyking solution\nprint(1)\n```\n```any-order\nBETWEEN: sdelay*\n```\n",
   "needs an ANY: line"],
]) {
  const found = renderMarkdown(header).notebook.problems.map((p) => p.message);
  check("refuses " + JSON.stringify(header.split("\n")[header.includes("solution save") ? 2 : 0]),
        found.some((m) => m.includes(problem)), JSON.stringify(found));
}
const evented = renderMarkdown("```pyking task name = \"go\"\n```\n```pyking solution\nprint(1)\n```\n"
  + "```stdin lines_per_multi_input = 1\n1\n2\n```\n```events\nclick \"go\"\n```\n"
  + "```events\nclick \"stop\"\n```\n```stdout\n1\n```\n").notebook;
check("an events block belongs to the test before it, every piece of a split stdin included",
      evented.problems.length === 0 && evented.items[0].name === "go"
      && JSON.stringify(evented.items[0].tests.map((t) => [t.stdin, t.events]))
        === '[["1\\n","click \\"go\\""],["2\\n","click \\"go\\""],[null,"click \\"stop\\""]]',
      JSON.stringify([evented.problems, evented.items[0].tests.map((t) => [t.stdin, t.events])]));
check("a diff-allowed block's lines are the square's rules",
      JSON.stringify(square.allowed.map((r) => r.slots)) === "[[2,2],[2]]"
      && doubling.allowed.length === 0, JSON.stringify(square.allowed.map((r) => r.text)));
const rect = (n, color) => `rect "canvas" 10 10 ${n} ${n} 0 "${color}" "" 1.000 1.000`;
check("a number may differ by what a rule allows, and no more",
      grading.sameOutput(rect(40, "#ff0000") + "\n40", rect(42, "#ff0000") + "\n38", square.allowed)
      && !grading.sameOutput(rect(40, "#ff0000"), rect(43, "#ff0000"), square.allowed)
      && !grading.sameOutput(rect(40, "#ff0000"), rect(41, "#0000ff"), square.allowed)
      && !grading.sameOutput("40", "41", [])
      && !grading.sameOutput("40\n41", "40", square.allowed));
const decimals = renderMarkdown("```pyking task\n```\n```pyking solution\nprint(1)\n```\n"
  + "```diff-allowed\nx = [+/-3.21], y = [+/- 0.5]\n```\n").notebook.items[0].allowed;
check("a rule's slots may be decimals, several on a line",
      grading.allowedLine(decimals, "x = 1.5, y = 2", "x = -1.71, y = 2.5")
      && !grading.allowedLine(decimals, "x = 1.5, y = 2", "x = -1.72, y = 2")
      && !grading.allowedLine(decimals, "x = 1.5, y = 2", "x = 1.5, y = 2.6"),
      JSON.stringify(decimals.map((r) => r.slots)));
const drums = renderMarkdown("```pyking task\n```\n```pyking solution\nprint(1)\n```\n"
  + "```optional-last\nsdelay*\nsplash\n```\n```any-order\nBETWEEN: sdelay*\nANY: play \"song*\n"
  + "ANY: play \"wow*\n```\n").notebook;
const order = drums.items[0].allowed;
check("optional-last and any-order lines are rules of their kinds",
      drums.problems.length === 0 && JSON.stringify(order.map((r) => r.kind))
        === '["last","last","between","any","any"]', JSON.stringify([drums.problems, order]));
const beats = (...beats) => beats.map((b) => b.join("\n")).filter(Boolean).join("\nsdelay 0.250\n");
const song = 'play "song.wav" 0.0 1.0 1.0 0.0 0 0';
const wow = 'play "wow.wav" 0.0 1.0 1.0 0.0 0 0';
check("lines an optional-last line matches may end either side",
      grading.sameOutput("a\nsdelay 1.0", "a", order)
      && grading.sameOutput("a\nsplash", "a\nsdelay 0.5\n\n", order)
      && grading.sameOutput("a\nsdelay 0.250\nsplash", "a\nsplash", order.slice(0, 1))
      && !grading.sameOutput("a\nsdelay 0.250\nb\nsplash", "a\nb\nsplash", order.slice(0, 1))
      && !grading.sameOutput("sdelay 0.250\na", "a", order)
      && !grading.sameOutput("a\nsdelay 0.250\nb", "a\nb", order));
const until = renderMarkdown("```pyking task\n```\n```pyking solution\nprint(1)\n```\n"
  + "```compare-until events = 60\nsdelay*\nplay \"kick*\n```\n").notebook;
const limit = grading.untilLimit(until.items[0]);
check("a compare-until block is the task's limit, not a rule loosening the comparison",
      until.problems.length === 0 && until.items[0].allowed.length === 0
      && until.items[0].allowedParts.map((p) => p.kind).join() === "compare-until"
      && limit.events === 60 && limit.patterns.length === 2,
      JSON.stringify([until.problems, limit]));
check("its patterns match log lines whole, * standing for any text",
      new RegExp(limit.patterns[0]).test("sdelay 0.250")
      && new RegExp(limit.patterns[1]).test('play "kick1.wav" 0.0 1.0 1.0 0.0 0 0')
      && !new RegExp(limit.patterns[0]).test("> sdelay 1")
      && grading.untilLimit(drums.items[0]) === null,
      JSON.stringify(limit.patterns));
const twice = renderMarkdown("```pyking task\n```\n```pyking solution\nprint(1)\n```\n"
  + "```optional-last\nsdelay*\nsdelay*\n```\n").notebook.items[0].allowed;
check("each optional-last line drops at most one line from each side",
      !grading.sameOutput("a\nsdelay 0.250\nsdelay 1.0", "a", order.slice(0, 1))
      && !grading.sameOutput("a\nsdelay 0.25\nsdelay 0.25\nsdelay 0.25\nsplash", "a\nsplash", order)
      && grading.sameOutput("a\nsdelay 0.25\nsdelay 0.25\nsplash", "a\nsdelay 1\nsplash", twice)
      && !grading.sameOutput("a\nsdelay 0.25\nsdelay 0.25\nsdelay 0.25\nsplash", "a\nsplash", twice));
check("ANY lines may come in any order between BETWEEN lines",
      grading.sameOutput(beats([song, wow], [wow, song]), beats([wow, song], [song, wow]), order)
      && grading.sameOutput(beats([song, wow, song]), beats([song, song, wow]), order));
check("but each stretch holds the same ones, as many times",
      !grading.sameOutput(beats([song, wow], [wow]), beats([song], [wow, wow]), order)
      && !grading.sameOutput(beats([song, song]), beats([song]), order)
      && !grading.sameOutput(beats([song], [wow]), beats([song, wow]), order));
check("other lines keep their order, and a * stands for any text",
      grading.sameOutput(`x\n${song}\ny\n${wow}`, `x\n${wow}\ny\n${song}`, order)
      && !grading.sameOutput(`y\n${song}\nx`, `x\n${song}\ny`, order)
      && !grading.sameOutput('play "other.wav"\nplay "x"', 'play "x"\nplay "other.wav"', order));
const tolerant = renderMarkdown("```pyking task\n```\n```pyking solution\nprint(1)\n```\n"
  + "```any-order\nANY: tone*\n```\n```diff-allowed\ntone [+/-1]\n```\n").notebook.items[0].allowed;
check("diff-allowed holds inside any-order",
      grading.sameOutput("tone 10\ntone 20", "tone 21\ntone 9", tolerant)
      && !grading.sameOutput("tone 10\ntone 20", "tone 22\ntone 9", tolerant));
const freed = grading.excused(order, `${wow}\n${song}\nsdelay 0.250\nx\nsdelay 1`, `${song}\n${wow}\nsdelay 0.250\ny`);
check("the lines excused are the reordered ones and the optional end",
      JSON.stringify([[...freed.left].sort(), [...freed.right].sort()]) === "[[0,1,4],[0,1]]",
      JSON.stringify([[...freed.left], [...freed.right]]));
const ignoring = (...blocks) => renderMarkdown("```pyking task\n```\n```pyking solution\nprint(1)\n```\n"
  + blocks.join("")).notebook.items[0].allowed;
const spaced = ignoring("```ignore-chars chars = \" ,\"\npoint*\nplay*\n```\n");
check("ignore-chars lines are rules holding their block's chars",
      JSON.stringify(spaced.map((r) => [r.kind, r.chars])) === '[["chars"," ,"],["chars"," ,"]]',
      JSON.stringify(spaced));
check("a line ignore-chars matches loses every one of its chars, in any order",
      grading.cleanLine(spaced, "point 1, 2,,") === "point12"
      && grading.cleanLine(spaced, "other 1, 2") === "other 1, 2"
      && grading.sameOutput("point 1, 2\nend", "point1,2\nend", spaced)
      && grading.sameOutput("point ,1 2", "point 1,2", spaced)
      && !grading.sameOutput("point 1, 3", "point 1,2", spaced)
      && !grading.sameOutput("other 1, 2", "other 1,2", spaced));
check("each side is cleaned on its own",
      grading.sameOutput("point 1 2", "point", ignoring("```ignore-chars chars = \" 12\"\npoint *\n```\n"))
      && grading.sameLine(spaced, "play 1, 2", "play 12"));
const both = ignoring("```ignore-chars chars = \" \"\nx*\n```\n", "```ignore-chars chars = \";\"\nx*\ny*\n```\n");
check("several blocks that match a line all remove their chars",
      grading.cleanLine(both, "x 1; 2") === "x12" && grading.cleanLine(both, "y 1; 2") === "y 1 2"
      && grading.sameOutput("x 1;2", "x1 ;2", both));
const first = ignoring("```ignore-chars chars = \" \"\n*\n```\n", "```diff-allowed\nv=[+/-1]\n```\n",
  "```any-order\nANY: ab*\n```\n", "```optional-last\nend\n```\n");
check("the other rules see the lines ignore-chars has cleaned",
      grading.sameOutput("v = 1", "v=2", first)
      && grading.sameOutput("a b 1\nab 2\ne n d", "ab 2\na b1", first)
      && !grading.sameOutput("v = 1", "v=3", first));
const { lineDiff } = await import(pathToFileURL(plan.activities).href);
const rows = lineDiff("a\nb\nc\nd", "a\nB\nc\nd\ne");
const loose = lineDiff("v 1\nw", "v 2\nw", (x, y) => x === y || grading.allowedLine(
  renderMarkdown("```pyking task\n```\n```pyking solution\nprint(1)\n```\n```diff-allowed\nv [+/-1]\n```\n")
    .notebook.items[0].allowed, x, y));
check("a line diff takes lines a rule allows as the same",
      loose.every((r) => r.kind === "same") && loose[0].left === "v 1" && loose[0].right === "v 2",
      JSON.stringify(loose));
const cleaned = lineDiff("point 1, 2\nother 1, 2", "point 1,2\nother 1,2", (x, y) => grading.sameLine(spaced, x, y));
check("a line diff takes lines ignore-chars cleans alike as the same, and no others",
      JSON.stringify(cleaned.map((r) => [r.kind, r.left, r.right]))
        === '[["same","point 1, 2","point 1,2"],["change","other 1, 2","other 1,2"]]',
      JSON.stringify(cleaned));
check("a line diff pairs what changed and keeps what is the same",
      JSON.stringify(rows.map((r) => [r.kind, r.left, r.right]))
        === '[["same","a","a"],["change","b","B"],["same","c","c"],["same","d","d"],["change",null,"e"]]',
      JSON.stringify(rows));

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
  return { answer, printed: text("stdout"), debugged: text("debug"), read: text("stdin"),
           warned: text("warning") };
};

const booted = await ask({ type: "init", pykingURL: "http://test/pyking/", libURL });
check("the worker boots", booted.answer?.type === "result",
      JSON.stringify(booted.answer));
const words = (await ask({ type: "words" })).answer?.value ?? {};
check("the worker answers the word lists",
      words.keywords?.includes("def") && words.builtins?.includes("print")
      && words.targets?.includes("pyking") && words.formatHelper?.includes("pykFormat")
      && words.warnings?.some((w) => w.name === "unused-binding" && w.on === true),
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
      ran.printed === 'who? hello Ada ["a", "b c"] true\nthe rest\n\n',
      JSON.stringify(ran.printed));
check("what it read is echoed", ran.read === "Ada\n", JSON.stringify(ran.read));
check("its debug line is marked apart", ran.debugged === "read Ada\n",
      JSON.stringify(ran.debugged));

// 4a. Warnings: a run's arrive as `warning` messages, apart from what it
//     printed and its debug lines, and the flags a request carries are
//     the ones its check uses -- an error among them refusing the run.
const unused = "def helper() -> Int:\n    return 1\n\nprint(\"ran\")\n";
let warned = await ask({ type: "run", source: unused, name: "unused.pyk" });
check("a run's warnings arrive apart from its output",
      warned.answer?.value?.ok && warned.printed === "ran\n" && warned.debugged === ""
      && warned.warned === "'unused.pyk' 1:4-1:10 Warning: Function 'helper' is defined but never used. [-Wunused-function]\n",
      JSON.stringify(warned));
warned = await ask({ type: "run", source: unused, name: "unused.pyk", warnings: ["-w"] });
check("the flags a request carries are the ones its check uses",
      warned.answer?.value?.ok && warned.warned === "" && warned.printed === "ran\n", JSON.stringify(warned));
warned = await ask({ type: "run", source: unused, name: "unused.pyk", warnings: ["-Werror"] });
check("and a warning made an error refuses the run",
      warned.answer?.value?.ok === false && warned.answer.value.stage === "Warning"
      && warned.answer.value.text.includes("[-Werror=unused-function]") && warned.printed === "",
      JSON.stringify(warned));
await ask({ type: "words", warnings: [] });

// 4b. tinyweb's log kept apart from debug, as a submission is compared.
const drew = await ask({ type: "run", name: "drew.pyk", tinywebLog: "separate",
  source: "import tinyweb as tw\nc = tw.canvas(10, 20)\ndebug(\"mine\")\n" });
const logged = replies.filter((reply) => reply.type === "tinyweb").map((reply) => reply.text).join("");
check("with tinywebLog separate, tinyweb's log arrives on its own",
      drew.answer?.value?.ok && logged === 'canvas "canvas" 10 20\n' && drew.debugged === "mine\n",
      JSON.stringify([logged, drew.debugged]));

// 4c. A check run's sdelay does not wait: no one sees its page, so the
//     clock only moves on, the log says where, and the page is sent no
//     sdelay that would hold back what is drawn after it.
const delayed = await ask({ type: "run", name: "delayed.pyk", tinywebLog: "separate",
  source: "import tinyweb as tw\nprint(\"a\", tw.time())\ntw.sdelay(5.0)\n"
    + "print(\"b\", tw.time())\ntw.sdelay(2.5)\nc = tw.canvas(10, 20)\nprint(\"c\", tw.time())\n" });
const delayLog = replies.filter((reply) => reply.type === "tinyweb").map((reply) => reply.text).join("");
const sentDelays = replies.filter((reply) => reply.type === "page")
  .flatMap((reply) => reply.data).filter((command) => command.op === "sdelay");
check("a check run's sdelay answers at once, on a simulated clock",
      delayed.answer?.value?.ok && delayed.printed === "a 0.0\nb 5.0\nc 7.5\n",
      JSON.stringify([delayed.answer, delayed.printed]));
check("a check run's sdelay is in its log",
      delayLog === 'sdelay 5.000\nsdelay 2.500\ncanvas "canvas" 10 20\n', JSON.stringify(delayLog));
check("a check run's sdelay is not sent to its page", sentDelays.length === 0,
      JSON.stringify(sentDelays));

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
        "tasks": str(TASKS),
        "activities": str(ACTIVITIES),
        "drawing": str(DRAWING),
        "worker": str(WORKER),
        "bundle": str(BUNDLE),
        "lib": str(REPO / "lib"),
        "features": str(FEATURES),
        "golden": str(FIXTURES / "features.html"),
        "update": update,
        "cases": CASES,
        "documents": [
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


def fetch(port, path, method="GET", body=None):
    """One request, with the path sent exactly as given.
    Int -> String -> String -> Bytes? -> (Int, Bytes)"""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request(method, path, body=body)
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
                         "/notebook/notebook.css", "/notebook/tasks.js",
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

    # A picture a solution makes is saved beside the document: into a copy
    # here, since the server writes it.
    with tempfile.TemporaryDirectory(prefix="pyk-notebook-") as directory:
        copy = Path(directory) / DRAWING.name
        shutil.copy(DRAWING, copy)
        (Path(directory) / "pictures").mkdir()
        port = free_port()
        process, printed = start(compiler, ["notebook", "--port", str(port), str(copy)], environment)
        check("`pyk notebook` starts on a copy", process is not None, printed)
        if process is not None:
            try:
                status, body = fetch(port, "/notebook.json")
                check("notebook.json says where a picture is saved",
                      status == 200 and json.loads(body).get("save") == "save/", body[:120])
                picture = b"\x89PNG\r\n\x1a\n made by a page"
                status, _ = fetch(port, "/save/square.png", "POST", picture)
                check("a picture posted to save/ is written beside the document",
                      status == 200 and (Path(directory) / "square.png").read_bytes() == picture,
                      f"status {status}")
                status, _ = fetch(port, "/save/pictures/sub.png", "POST", picture)
                check("and into a directory beside it",
                      status == 200 and (Path(directory) / "pictures" / "sub.png").exists(),
                      f"status {status}")
                status, _ = fetch(port, "/save/square.png", "POST", picture)
                check("the same picture again is answered too", status == 200, f"status {status}")
                for path in ["/save/../escape.png", "/save/%2e%2e/escape.png", "/save/notes.txt",
                             "/save/.hidden.png", "/save/missing/x.png", "/save/"]:
                    status, _ = fetch(port, path, "POST", picture)
                    check(f"it refuses to save {path}", status == 400, f"status {status}")
                check("nothing was written outside the document's directory",
                      not (Path(directory).parent / "escape.png").exists()
                      and not (Path(directory) / "notes.txt").exists())
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
            check("notebook.json says teacher mode, and to watch the file",
                  status == 200 and json.loads(body).get("mode") == "teacher"
                  and json.loads(body).get("watch") is True
                  and json.loads(body).get("warnings") == [], body[:120])
        finally:
            stop(process)

    port = free_port()
    process, printed = start(
        compiler, ["notebook", "-Wall", "-Werror=unused-function", "--port", str(port), str(FEATURES)],
        environment)
    check("`pyk notebook -Wall` starts", process is not None, printed)
    if process is not None:
        try:
            status, body = fetch(port, "/notebook.json")
            check("notebook.json carries the -W flags, for the page's runs",
                  status == 200
                  and json.loads(body).get("warnings") == ["-Wall", "-Werror=unused-function"], body[:160])
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
            check("a POST where nothing takes one is not found", status == 404, f"status {status}")
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
    refused("-W flags are refused in test mode, which shows no warning",
            ["notebook", "--mode", "test", "-Wall", str(FEATURES)],
            "they are not for --mode test")
    refused("and by a command that checks no program",
            ["playground", "-Wall"], "-W and -w say which warnings a program is checked with")
    refused("a flag naming no warning is refused",
            ["notebook", "-Wsomething", str(FEATURES)], "'something' names no warning")
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

    for document in (FEATURES, DRAWING):
        good = mode_test(document)
        if good.returncode != 0:
            failures.append(f"{document.name} passes test mode: "
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
    return 3, failures


def check_page(compiler, chromium):
    """features.md served in each mode and driven in Chromium by
    page.mjs. [String] -> String -> (Int, [String])"""
    checks, failures = 0, []
    for mode in ("student", "teacher"):
        # Served from a copy: the teacher's driver edits it, and a page
        # saves the pictures its solutions make beside it.
        copy = Path(tempfile.mkdtemp(prefix="pyk-notebook-"))
        shutil.copytree(FIXTURES, copy, dirs_exist_ok=True)
        document = copy / FEATURES.name
        port = free_port()
        process, printed = start(
            compiler, ["notebook", "--port", str(port), "--mode", mode, str(document)],
            dict(os.environ))
        if process is None:
            checks += 1
            failures.append(f"{mode}: the notebook did not start: {printed}")
            continue
        try:
            ran = suite.run_with_progress(
                ["node", str(PAGE_DRIVER), chromium, f"http://127.0.0.1:{port}/", mode,
                 str(document)],
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
            if copy:
                shutil.rmtree(copy, ignore_errors=True)
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
    missing = [p for p in (BUNDLE, FEATURES) if not p.exists()]
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
