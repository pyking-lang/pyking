// Drives a notebook page in a real, headless Chromium, over the DevTools
// protocol with node's own WebSocket -- no package needed -- and checks
// what its exercises and quizzes do: tests/test_notebook.py serves
// tests/notebook/features.md and runs this against it, once in student
// mode and once in teacher mode.
//
// Usage: node page.mjs <chromium> <url> <student|teacher>
// Writes {checks, failures} as JSON.

import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const [browser, url, mode] = process.argv.slice(2);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "pyk-notebook-"));
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
    $("[data-r=check]", quiz(n)).click();
    return $("[data-r=feedback]", quiz(n)).innerText;
  };
  const checks = [];
  const check = (label, ok, detail = "") => checks.push([label, !!ok, String(detail).slice(0, 300)]);
`;

const SOLUTION = JSON.stringify('import io\nimport sys\nline = io.read_line()\n'
  + 'print(line, "/", line)\nprint("args:", sys.args())\n');

const STUDENT = [`(async () => { ${HELPERS}
  let r = nb.results();
  check("five open items, worth 10 with 8 to pass",
    r.total === 5 && r.solved === 0 && r.max === 10 && r.pass === 8, JSON.stringify(r));
  check("the rules show max and pass", /10\\s*points/.test($(".pkn-rules").innerText)
    && /pass at\\s*8/.test($(".pkn-rules").innerText), $(".pkn-rules")?.innerText);
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

  r = nb.results();
  check("the results: three solved, 7 points, not passed",
    r.solved === 3 && r.points === 7 && r.passed === false && r.done === false, JSON.stringify(r));
  check("the progress bar says so", $(".pkn-progress").innerText.includes("3 of 5 solved")
    && $(".pkn-progress").innerText.includes("7 of 10"), $(".pkn-progress").innerText);
  return checks;
})()`, "reload", `(async () => { ${HELPERS}
  const r = nb.results();
  check("progress is kept over a reload", r.solved === 3 && r.points === 7, JSON.stringify(r));
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

const TEACHER = [`(async () => { ${HELPERS}
  check("the solution is shown, with no button", !hidden($("[data-r=solution]", exercise(1)))
    && hidden($("[data-r=show]", exercise(1))));
  check("even one that is not available", !hidden($("[data-r=solution]", exercise(3))));
  check("every test is shown", $$(".pkn-io", exercise(1)).length === 4,
    $$(".pkn-io", exercise(1)).length);
  check("every quiz has its answer key", $$(".pkn-answer-key").length === 2);
  check("hidden output under a cell is shown too",
    $$(".pkn-io").some((b) => b.innerText.includes("echo me")));
  return checks;
})()`];

const chrome = spawn(browser, [
  "--headless", "--no-sandbox", "--disable-gpu", "--no-first-run",
  "--no-default-browser-check", "--remote-debugging-port=0",
  `--user-data-dir=${profile}`, "about:blank",
], { stdio: "ignore" });

let output = { checks: 0, failures: [] };
try {
  let port = null;
  for (let i = 0; i < 300 && !port; i++) {
    const file = path.join(profile, "DevToolsActivePort");
    if (fs.existsSync(file)) port = Number(fs.readFileSync(file, "utf8").split("\n")[0]) || null;
    if (!port) await sleep(100);
  }
  if (!port) throw new Error("Chromium did not start");
  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  const socket = new WebSocket(version.webSocketDebuggerUrl);
  let next = 1;
  const waiting = new Map();
  socket.onmessage = (message) => {
    const data = JSON.parse(message.data);
    if (data.id !== undefined && waiting.has(data.id)) {
      const { resolve, reject } = waiting.get(data.id);
      waiting.delete(data.id);
      if (data.error) reject(new Error(data.error.message));
      else resolve(data.result);
    }
  };
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = () => reject(new Error("cannot reach Chromium"));
  });
  const send = (method, params = {}, sessionId = undefined) => {
    const id = next++;
    socket.send(JSON.stringify({ id, method, params, sessionId }));
    return new Promise((resolve, reject) => waiting.set(id, { resolve, reject }));
  };
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
  await send("Page.navigate", { url }, sessionId);
  await ready();
  await evaluate("localStorage.clear(); location.reload(); true");
  await ready();
  for (const phase of mode === "teacher" ? TEACHER : STUDENT) {
    if (phase === "reload") {
      await evaluate("location.reload(); true");
      await ready();
      continue;
    }
    for (const [label, ok, detail] of await evaluate(phase)) {
      output.checks += 1;
      if (!ok) output.failures.push(`${mode}: ${label}${detail ? ": " + detail : ""}`);
    }
  }
  socket.close();
} catch (error) {
  output = { checks: output.checks + 1, failures: [...output.failures, `${mode}: ${error.message}`] };
} finally {
  chrome.kill();
  await sleep(200);
  fs.rmSync(profile, { recursive: true, force: true });
}
process.stdout.write(JSON.stringify(output));
