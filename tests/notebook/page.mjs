// Drives a notebook page in a real, headless Chromium, over the DevTools
// protocol with node's own WebSocket -- no package needed -- and checks
// what its exercises and quizzes do: tests/test_notebook.py serves
// tests/notebook/features.md and runs this against it, once in student
// mode and once in teacher mode.
//
// Usage: node page.mjs <chromium> <url> <student|teacher> <document>
// Writes {checks, failures} as JSON. <document> is the file the server
// serves, a copy: in teacher mode the driver edits it to see the page
// reload, and in both drawing.md beside it saves its picture there.

import fs from "node:fs";
import path from "node:path";

import { progress, start } from "../chromium.mjs";

const [browser, url, mode, served] = process.argv.slice(2);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// What runs in the page: helpers, then one script per phase, each
// answering [[label, ok, detail]].
const HELPERS = `
  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => [...root.querySelectorAll(s)];
  const hidden = (el) => !el || el.closest(".pkn-hidden") !== null;
  const nb = window.pykingNotebook;
  const exercise = (n) => $("#exercise-" + n);
  const quiz = (n) => $("#quiz-" + n);
  const settle = async (box) => {
    await new Promise((r) => setTimeout(r, 100));
    for (let i = 0; i < 300 && $("[data-r=feedback]", box).textContent.includes("Checking"); i++) {
      await new Promise((r) => setTimeout(r, 100));
    }
    return $("[data-r=feedback]", box).innerText;
  };
  const submit = async (n, source) => {
    if (source !== undefined) nb.cells.filter((c) => c.spec.attrs.exercise)[n - 1].setSource(source);
    $("[data-r=submit]", exercise(n)).click();
    return settle(exercise(n));
  };
  const answer = (n, chosen) => {
    const inputs = $$("input", quiz(n));
    for (const [k, input] of inputs.entries()) if (input.checked !== chosen.includes(k)) input.click();
    $("[data-r=submit]", quiz(n)).click();
    return $("[data-r=feedback]", quiz(n)).innerText;
  };
  const checks = [];
  const check = (label, ok, detail = "") => checks.push([label, !!ok, String(detail).slice(0, 300)]);
`;

const SOLUTION = JSON.stringify('import io\nimport sys\nline = io.read_line()\n'
  + 'print(line, "/", line)\nprint("args:", sys.args())\n');

const STUDENT = [`(async () => { ${HELPERS}
  let r = nb.results();
  check("six open items, worth 12 with 9 to pass",
    r.total === 6 && r.solved === 0 && r.max === 12 && r.pass === 9, JSON.stringify(r));
  check("the rules show max and pass", /12\\s*points/.test($(".pkn-rules").innerText)
    && /pass at\\s*9/.test($(".pkn-rules").innerText), $(".pkn-rules")?.innerText);
  check("a progress bar at the top and at the end", $$(".pkn-progress").length === 2);
  check("the solution is hidden, and can be asked for",
    hidden($("[data-r=solution]", exercise(1))) && !hidden($("[data-r=show]", exercise(1))));
  check("only the visible tests are shown", $$(".pkn-io", exercise(1)).length === 2,
    $$(".pkn-io", exercise(1)).length);
  check("a solution that is not available cannot be asked for",
    hidden($("[data-r=show]", exercise(3))));
  check("no answer key", $$(".pkn-answer-key").length === 0);
  check("an ordinary cell's visible stdout is shown, a hidden one not",
    $$(".pkn-io-stdout").some((b) => b.innerText.includes("my out"))
    && !$$(".pkn-io").some((b) => b.innerText.includes("echo me"))
    && $$(".pkn-io-stderr").some((b) => b.innerText.includes("to stderr")));

  let said = await submit(1);
  check("a wrong answer uses an attempt and shows a failed test",
    said.includes("2 attempts left") && said.includes("expected") && said.includes("got"), said);
  said = await submit(1, ${SOLUTION});
  check("the right answer solves it, with full points",
    said.includes("Solved") && said.includes("5 of 5"), said);
  check("a solved exercise is marked", exercise(1).dataset.state === "solved"
    && $(".pkn-badge-solved", exercise(1)) !== null);
  $("[data-r=show]", exercise(1)).click();
  check("asking shows the solution", !hidden($("[data-r=solution]", exercise(1))));

  said = await submit(2, 'print("Hello, world")');
  check("an exercise with no solution is checked against its stdout", said.includes("Solved"), said);

  await submit(3);
  said = await submit(3);
  check("out of attempts, an exercise is failed and closed",
    exercise(3).dataset.state === "failed" && $("[data-r=submit]", exercise(3)).disabled
    && said.includes("No attempts"), said);

  said = answer(1, [1]);
  check("a wrong choice shows why", !hidden($("[data-explain='1']", quiz(1)))
    && $("[data-explain='1']", quiz(1)).innerText.includes("checker"), said);
  said = answer(1, [0]);
  check("the right choice solves the quiz", quiz(1).dataset.state === "solved"
    && said.includes("2 of 2"), said);

  said = answer(2, [1]);
  check("a checkbox quiz says a right answer was missed",
    said.includes("not checked") && said.includes("1 attempt left"), said);
  said = answer(2, [0]);
  check("out of attempts, an available quiz reveals its answers",
    quiz(2).dataset.state === "failed" && said.includes("marked")
    && $$("[data-mark]", quiz(2)).filter((m) => m.innerHTML !== "").length === 3, said);

  check("a quiz shows its question inside its box, then its rule",
    $(".pkn-quiz-question", quiz(3))?.innerText.includes("static type checking")
    && $(".pkn-quiz-hint", quiz(3)).innerText.includes("exactly 2 alternatives are correct"),
    $(".pkn-quiz-hint", quiz(3))?.innerText);
  said = answer(3, [1, 2]);
  check("one point per right answer, in its one attempt",
    quiz(3).dataset.state === "failed" && said.includes("1 of 2 points")
    && $("[data-r=badges]", quiz(3)).innerText.includes("1 of 2 points"), said);

  r = nb.results();
  check("the results: three solved, 8 points, not passed",
    r.solved === 3 && r.points === 8 && r.passed === false && r.done === false, JSON.stringify(r));
  check("the progress bar says so", $(".pkn-progress").innerText.includes("3 of 6 solved")
    && $(".pkn-progress").innerText.includes("8 of 12"), $(".pkn-progress").innerText);
  return checks;
})()`, "reload", `(async () => { ${HELPERS}
  const r = nb.results();
  check("progress is kept over a reload", r.solved === 3 && r.points === 8, JSON.stringify(r));
  check("so is the code of an exercise",
    nb.cells.filter((c) => c.spec.attrs.exercise)[0].source().includes("read_line"));
  check("and a failed exercise stays closed", $("[data-r=submit]", exercise(3)).disabled);
  window.confirm = () => true;
  $(".pkn-start-over").click();
  const after = nb.results();
  check("start over forgets every answer", after.solved === 0 && after.points === 0
    && nb.cells.filter((c) => c.spec.attrs.exercise)[0].source() === 'print("Add your code here")',
    JSON.stringify(after));
  return checks;
})()`];

// drawing.md, opened beside features.md: the picture its solution saves,
// an exercise submitted with git, and -- for a student -- answers that
// fail, the diff of the first test that did not match, and answers that
// pass.
const SQUARE = (color, grow = "") => JSON.stringify("import tinyweb as tw\nimport tinyweb.color as color\nimport io\n"
  + `size = int(io.read_line())${grow}\nc = tw.canvas(100, 100)\n`
  + `tw.rect(c, 10, 10, size, size, color.hex(0x${color.slice(1)}))\nprint(size)\n`);
const DOUBLING = (second) => JSON.stringify("import io\na = int(io.read_line())\n"
  + `b = int(io.read_line())\nprint(a * 2, ${second})\n`);
const DRAWING = `(async () => { ${HELPERS}
  const until = async (test, ms = 30000) => {
    for (let i = 0; i < ms / 100; i++) {
      if (await test()) return true;
      await new Promise((r) => setTimeout(r, 100));
    }
    return false;
  };
  const picture = () => [...document.querySelectorAll(".pkn-prose img")]
    .find((img) => img.src.startsWith("blob:"));
  check("the picture a solution saves is made, and shown where the text names it",
    await until(() => picture()?.complete && picture().naturalWidth === 100),
    [...document.querySelectorAll(".pkn-prose img")].map((img) => img.src).join(" "));
  const git = exercise(3);
  check("an exercise submitted with git says so, with nothing to submit",
    !hidden($("[data-r=git]", git)) && /Please submit via your git account/.test($("[data-r=git]", git).innerText)
    && hidden($("[data-r=submit]", git)) && /submitted with git/.test($("[data-r=badges]", git).innerText),
    git.innerText);
  check("the rules say what is submitted with git", /5\\s*submitted with git/.test($(".pkn-rules").innerText),
    $(".pkn-rules").innerText);
  const r = nb.results();
  check("the totals leave it out", r.total === 2 && r.max === 4, JSON.stringify(r));
  if (nb.cfg.mode === "teacher") {
    check("a teacher sees its solution", !hidden($("[data-r=solution]", git)));
    return checks;
  }
  check("a student does not see its solution, nor a button for it",
    hidden($("[data-r=solution]", git)) && hidden($("[data-r=show]", git)));
  check("a split stdin block is shown once", $$(".pkn-io-stdin", exercise(2)).length === 1,
    $$(".pkn-io-stdin", exercise(2)).length);

  const diff = () => $("[data-r=diff]", exercise(1));
  check("no diff to see before a Submit", hidden(diff()));
  let fb = await submit(1, ${SQUARE("#0000ff", " + 1")});
  check("a drawing that is not the solution's fails", /Not quite/.test(fb)
    && /drew with tinyweb is not what it should be/.test(fb), fb);
  check("and offers to see the diff", !hidden(diff()));
  diff().click();
  check("the diff shows both pictures", await until(() => $$(".pkn-diff canvas[data-tinyweb-id]").length === 2),
    $$(".pkn-diff canvas").length);
  const modal = $(".pkn-diff");
  const text = modal.innerText;
  check("it names the two sides", /Your submission/.test(text) && /Possible solution/.test(text), text.slice(0, 200));
  check("it shows the test case's stdin and args",
    $$(".pkn-diff-case .pkn-io-text", modal).map((e) => e.innerText.trim()).join("|") === "10|(none)",
    $$(".pkn-diff-case .pkn-io-text", modal).map((e) => e.innerText).join("|"));
  const red = $$(".pkn-diff-line.pkn-diff-del", modal).map((e) => e.innerText);
  const green = $$(".pkn-diff-line.pkn-diff-add", modal).map((e) => e.innerText);
  check("what only the submission drew is red, what only the solution drew green",
    red.some((l) => l.includes("#0000ff")) && green.some((l) => l.includes("#ff0000"))
    && !red.some((l) => l.includes("#ff0000")),
    JSON.stringify([red, green]));
  check("output that differs only as diff-allowed allows is said to be the same",
    /Standard output\\s*the same/.test(text), text.slice(0, 600));
  check("and its lines are marked as an allowed difference",
    $$(".pkn-diff-line.pkn-diff-allowed", modal).map((e) => e.innerText).join(" ") === "11 10",
    $$(".pkn-diff-line.pkn-diff-allowed", modal).map((e) => e.innerText).join(" "));
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  check("Escape closes it", !$(".pkn-diff"));
  fb = await submit(1, ${SQUARE("#ff0000", " + 3")});
  check("a square three pixels too big fails", /Not quite/.test(fb), fb);
  fb = await submit(1, ${SQUARE("#ff0000", " - 2")});
  check("one two pixels too small, which diff-allowed allows, solves it", /Solved/.test(fb), fb);
  check("and the diff is gone", hidden(diff()));

  fb = await submit(2, ${DOUBLING("if a == 3 then 0 else b * 2")});
  check("an answer wrong on the second piece of input fails", /Not quite/.test(fb), fb);
  $("[data-r=diff]", exercise(2)).click();
  const second = await until(() => $(".pkn-diff")) && $(".pkn-diff");
  check("the diff is of that piece of input",
    $(".pkn-diff-case .pkn-io-text", second)?.innerText.trim() === "3\\n4",
    $(".pkn-diff-case .pkn-io-text", second)?.innerText);
  check("a line that differs is red on the left and green on the right",
    $$(".pkn-diff-del", second).some((e) => e.innerText === "6 0")
    && $$(".pkn-diff-add", second).some((e) => e.innerText === "6 8"),
    $$(".pkn-diff-table", second).map((e) => e.innerText).join(" | "));
  check("with no tinyweb, no pictures", $$(".pkn-diff canvas", second).length === 0);
  $("[data-r=close]", second.closest(".pkn-modal-backdrop")).click();
  check("its close button closes it", !$(".pkn-diff"));
  return checks;
})()`;

const TEACHER = [`(async () => { ${HELPERS}
  check("the solution is shown, with no button", !hidden($("[data-r=solution]", exercise(1)))
    && hidden($("[data-r=show]", exercise(1))));
  check("even one that is not available", !hidden($("[data-r=solution]", exercise(3))));
  check("every test is shown", $$(".pkn-io", exercise(1)).length === 4,
    $$(".pkn-io", exercise(1)).length);
  check("every quiz has its answer key", $$(".pkn-answer-key").length === 3);
  check("hidden output under a cell is shown too",
    $$(".pkn-io").some((b) => b.innerText.includes("echo me")));
  check("a quiz's button says Submit", $("[data-r=submit]", quiz(1))?.innerText === "Submit");
  check("a one_point_correct quiz does not count its attempts",
    !$("[data-r=badges]", quiz(3)).innerText.includes("attempt"),
    $("[data-r=badges]", quiz(3)).innerText);

  for (let i = 0; i < 1200 && nb.checked === undefined; i++) await new Promise((r) => setTimeout(r, 100));
  const reports = $$(".pkn-check:not(.pkn-check-summary)");
  check("the checks ran", nb.checked !== undefined && nb.checked.length === 0,
    JSON.stringify(nb.checked));
  check("a check under every exercise, quiz, cell and the rules",
    reports.length === 6 + nb.cells.filter((c) => !c.spec.attrs.exercise && !c.spec.attrs.solution).length + 1,
    reports.length);
  check("each of them says no problems, in green",
    reports.every((r) => $(".pkn-check-good", r)?.innerText.includes("no problems")),
    reports.map((r) => r.innerText).join(" | "));
  check("so does the line at the top",
    $(".pkn-check-summary .pkn-check-good")?.innerText.includes("no problems found in this notebook"),
    $(".pkn-check-summary")?.innerText);
  check("a quiz's check is right below it and its answer key",
    quiz(1).nextElementSibling?.classList.contains("pkn-answer-key")
    && quiz(1).nextElementSibling.nextElementSibling?.classList.contains("pkn-check"));
  return checks;
})()`, "edit", `(async () => { ${HELPERS}
  for (let i = 0; i < 1200 && nb.checked === undefined; i++) await new Promise((r) => setTimeout(r, 100));
  const scroller = document.scrollingElement;
  check("the page reloaded where it was scrolled to",
    Math.abs(scroller.scrollTop - Number(sessionStorage.getItem("scrolled"))) < 5,
    scroller.scrollTop + " " + sessionStorage.getItem("scrolled"));
  const bad = $$(".pkn-check").filter((r) => $(".pkn-check-bad", r));
  check("the edited file's problem is shown where it is, in red",
    bad.length === 2 && bad.some((r) => r.innerText.includes("an answer block belongs right after its quiz"))
    && bad.some((r) => r.classList.contains("pkn-check-summary") && r.innerText.includes("1 problem found")),
    bad.map((r) => r.innerText).join(" | "));
  return checks;
})()`];

let output = { checks: 0, failures: [] };
let chrome = null;
try {
  chrome = await start(browser, "pyk-notebook-");
  const { send } = chrome;
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  await send("Runtime.enable", {}, sessionId);
  const evaluate = async (expression) => {
    const result = await send("Runtime.evaluate",
      { expression, awaitPromise: true, returnByValue: true }, sessionId);
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    }
    return result.result.value;
  };
  const ready = async () => {
    for (let i = 0; i < 600; i++) {
      await sleep(100);
      try {
        if (await evaluate("!!window.pykingNotebook && "
          + "document.querySelector('.pkn-status')?.textContent.includes('ready')")) return;
      } catch {
        /* still loading */
      }
    }
    throw new Error("the notebook did not become ready");
  };
  progress(`${mode}: loading the page`);
  await send("Page.navigate", { url }, sessionId);
  await ready();
  await evaluate("localStorage.clear(); location.reload(); true");
  await ready();
  const phases = mode === "teacher" ? TEACHER : STUDENT;
  for (const [k, phase] of phases.entries()) {
    progress(`${mode}: step ${k + 1}/${phases.length}${phase === "reload" ? ", reloading" : ""}`);
    if (phase === "reload") {
      await evaluate("location.reload(); true");
      await ready();
      continue;
    }
    if (phase === "edit") {
      // The server was started on a copy: edit it, and the page reloads
      // itself, scrolled where it was.
      const at = await evaluate("window.notReloaded = true; document.scrollingElement.scrollTop = 400; "
        + "sessionStorage.setItem('scrolled', String(document.scrollingElement.scrollTop)); "
        + "document.scrollingElement.scrollTop");
      fs.appendFileSync(served, "\n```answer\n-> lost\n```\n");
      let reloaded = false;
      for (let i = 0; i < 100 && !reloaded; i++) {
        await sleep(100);
        try {
          reloaded = await evaluate("!window.notReloaded");
        } catch {
          /* reloading */
        }
      }
      output.checks += 1;
      if (!reloaded) output.failures.push(`${mode}: the page reloads when its file changes`);
      await ready();
      continue;
    }
    for (const [label, ok, detail] of await evaluate(phase)) {
      output.checks += 1;
      if (!ok) output.failures.push(`${mode}: ${label}${detail ? ": " + detail : ""}`);
    }
  }

  progress(`${mode}: drawing.md`);
  const saved = path.join(path.dirname(served), "square.png");
  fs.rmSync(saved, { force: true });
  await evaluate("localStorage.clear(); true");
  await send("Page.navigate", { url: url + "?doc=drawing.md" }, sessionId);
  await ready();
  for (const [label, ok, detail] of await evaluate(DRAWING)) {
    output.checks += 1;
    if (!ok) output.failures.push(`${mode}: ${label}${detail ? ": " + detail : ""}`);
  }
  let written = false;
  for (let i = 0; i < 50 && !written; i++) {
    written = fs.existsSync(saved)
      && fs.readFileSync(saved).subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
    if (!written) await sleep(100);
  }
  output.checks += 1;
  if (!written) output.failures.push(`${mode}: the picture is saved beside the document as a PNG`);
} catch (error) {
  output = { checks: output.checks + 1, failures: [...output.failures, `${mode}: ${error.message}`] };
} finally {
  if (chrome) await chrome.stop();
}
process.stdout.write(JSON.stringify(output));
