// The notebook's exercises, quizzes and rules on the page: what
// exercises.js read out of the document, made into something a student
// answers and a teacher reviews. A student sees an exercise's visible
// tests, submits an answer and may ask for the solution; a teacher sees
// every block. Progress is kept in the browser, per document. See
// tools/notebook/README.md, "Exercises and quizzes".
//
// Data structures:
//   Activities -- the exercises and quizzes of one document (or one
//     fragment of a page), their state, and the page around them.
//   State -- per item: {key, state, points, failures, used, code?,
//     chosen?, shown?, feedback?}; `state` is "open", "solved" or "failed".
//
// Functions:
//   Activities(cells, doc, root, options) -- mounts them into root.
//   results() -- every item's state and the totals, for an embedding page.
//   lineDiff(a, b) -- two texts' lines side by side, what differs marked.

import { escapeHTML } from "./markdown.js";
import { allowedLine, checkQuiz, award, graded, normalizeOutput, quizAward, rightAnswers, sameOutput,
  summary } from "./exercises.js";

/** How long one run of a submitted answer may take, in milliseconds. */
const SUBMIT_TIMEOUT = 10000;

const STORE_PREFIX = "pyking-notebook.progress:";

export class Activities {
  /** cells: the Cells the document's cells belong to; doc: what
   *  renderMarkdown answered; root: the element holding its HTML;
   *  options: {mode, storageKey, summary, onChange, cellOffset, checks}.
   *  With `checks`, a teacher sees what test mode finds under each
   *  element, once `showChecks` is given it. */
  constructor(cells, doc, root, options = {}) {
    this.cells = cells;
    this.doc = doc;
    this.notebook = doc.notebook;
    this.root = root;
    this.mode = options.mode === "teacher" ? "teacher" : "student";
    this.storageKey = options.storageKey ? STORE_PREFIX + options.storageKey : null;
    this.onChange = options.onChange ?? null;
    this.offset = options.cellOffset ?? 0;
    this.states = {};
    this.widgets = {};
    this.bars = [];
    this.checks = this.teacher && !!options.checks;
    this.reports = [];         // one per element checked: {element, checked}
    this.reportOf = new Map(); // part index -> its element's report
    this.load();
    this.build(options.summary !== false);
  }

  /** The Cell made from the document's cell at index. Int -> Cell */
  cell(index) {
    return this.cells.cells[this.offset + index];
  }

  get teacher() {
    return this.mode === "teacher";
  }

  // -- state -------------------------------------------------------------

  load() {
    let saved = {};
    if (this.storageKey) {
      try {
        saved = JSON.parse(localStorage.getItem(this.storageKey) || "{}");
      } catch {
        saved = {};
      }
    }
    for (const item of this.notebook.items) {
      const kept = saved[item.id];
      this.states[item.id] = kept && kept.key === item.key ? kept
        : { key: item.key, state: "open", points: 0, failures: 0, used: 0 };
    }
  }

  save() {
    if (!this.storageKey) return;
    try {
      localStorage.setItem(this.storageKey, JSON.stringify(this.states));
    } catch {
      /* not kept; the page still works */
    }
  }

  /** Records a change to an item and tells whoever is listening. */
  changed() {
    this.save();
    for (const bar of this.bars) this.renderBar(bar);
    const results = this.results();
    this.onChange?.(results);
    this.root.dispatchEvent(new CustomEvent("pkn-results", { detail: results, bubbles: true }));
  }

  /** Every item's state, and the totals: what an embedding page asks.
   *  An item submitted with git is not `graded`, and the totals leave it
   *  out. () -> {items, solved, total, points, max, pass, passed, done} */
  results() {
    const items = this.notebook.items.map((item) => {
      const state = this.states[item.id];
      return {
        id: item.id,
        kind: item.kind,
        number: item.number,
        state: state.state,
        points: state.points,
        maxPoints: item.points,
        attemptsLeft: item.attempts === null ? null : Math.max(0, item.attempts - state.used),
        graded: graded(item),
      };
    });
    return { items, ...summary(this.notebook, this.states) };
  }

  /** Forgets every answer and puts every exercise's code back. */
  startOver() {
    for (const item of this.notebook.items) {
      this.states[item.id] = { key: item.key, state: "open", points: 0, failures: 0, used: 0 };
      this.widgets[item.id]?.reset();
    }
    this.changed();
  }

  // -- building ------------------------------------------------------------

  build(withSummary) {
    const parts = this.doc.parts;
    const at = (part) => this.root.querySelector(`[data-part="${part.index}"]`);
    const used = new Set();

    if (this.notebook.rules) {
      const part = parts.find((p) => p.kind === "rules");
      at(part)?.replaceWith(this.rulesBox(this.notebook.rules));
      used.add(part.index);
    }
    for (const example of this.notebook.examples) {
      for (const test of example.tests) {
        for (const block of [test.input, test.eventsPart, test.output, test.error]) {
          if (!block) continue;
          used.add(block.index);
          const element = at(block);
          if (this.teacher || block.attrs.visible === "true" || block.attrs.visible === true) {
            const box = ioBox(block);
            element?.replaceWith(box);
            // What a cell is to print stands where its output will, in line
            // with its code, and the output takes its place when it runs.
            const cell = example.cell === null ? null : this.cell(example.cell);
            if (cell && block === test.output) {
              cell.ui.output.before(box);
              cell.expected = box;
            }
          } else {
            element?.remove();
          }
        }
      }
    }
    for (const item of this.notebook.items) {
      const widget = item.kind === "exercise"
        ? new ExerciseWidget(this, item, at, used) : new QuizWidget(this, item, at, used);
      this.widgets[item.id] = widget;
    }
    if (this.checks) this.buildReports(at);
    // Whatever is left is an input block that filled in a cell, or one
    // exercises.js complained about: neither is shown.
    for (const part of parts) {
      if (part.cell === null && !used.has(part.index) && part.kind !== "pyking") at(part)?.remove();
    }
    if (withSummary && (this.notebook.items.length || this.notebook.rules)) {
      const prose = this.root.querySelector(".pkn-prose") ?? this.root;
      const top = this.bar();
      const bottom = this.bar();
      const rules = prose.querySelector(".pkn-rules");
      const below = rules?.nextElementSibling?.classList.contains("pkn-check")
        ? rules.nextElementSibling : rules;
      if (rules) below.after(top);
      else prose.prepend(top);
      prose.append(bottom);
    }
    if (this.checks) {
      const prose = this.root.querySelector(".pkn-prose") ?? this.root;
      this.top = element("div", "pkn-check pkn-check-summary");
      const bar = this.bars[0];
      const rules = prose.querySelector(".pkn-rules");
      if (bar) bar.after(this.top);
      else if (rules) rules.after(this.top);
      else prose.prepend(this.top);
      this.showChecks(null);
    }
  }

  // -- teacher checks ------------------------------------------------------

  /** A report under every element test mode checks -- the rules, each
   *  exercise, each quiz, each cell the document runs -- and one where a
   *  block exercises.js complained about stands on its own.
   *  (Part -> Element?) -> () */
  buildReports(at) {
    const { doc } = this;
    const report = (anchor, indices, checked) => {
      const r = { element: element("div", "pkn-check"), checked };
      anchor.after(r.element);
      for (const index of indices) this.reportOf.set(index, r);
      this.reports.push(r);
      return r;
    };
    const rules = this.root.querySelector(".pkn-rules");
    if (rules) report(rules, [doc.parts.find((p) => p.kind === "rules").index], true);
    const blocks = (tests) => tests.flatMap((test) =>
      [test.input, test.output, test.error].filter(Boolean).map((block) => block.index));
    const owned = new Set();
    for (const item of this.notebook.items) {
      const widget = this.widgets[item.id];
      const indices = [item.part];
      if (item.kind === "quiz") {
        if (item.answerPart !== null) indices.push(item.answerPart);
      } else {
        if (item.cell !== null) owned.add(item.cell);
        if (item.solution) {
          owned.add(item.solution.cell);
          indices.push(doc.cells[item.solution.cell].part);
        }
        indices.push(...blocks(item.tests), ...item.allowedParts.map((block) => block.index));
      }
      report(widget.key?.isConnected ? widget.key : widget.box, indices, true);
    }
    for (const spec of doc.cells) {
      if (owned.has(spec.index)) continue;
      const examples = this.notebook.examples.filter((e) => e.cell === spec.index);
      report(this.cell(spec.index).element,
        [spec.part, ...examples.flatMap((e) => blocks(e.tests))], true);
    }
    const lines = new Set(this.notebook.problems.map((p) => p.line));
    for (const part of doc.parts) {
      if (this.reportOf.has(part.index) || !lines.has(part.line)) continue;
      const anchor = at(part);
      if (anchor) report(anchor, [part.index], false);
    }
  }

  /** Shows what test mode found under each element, or that it is still
   *  being checked where `problems` is null. [Problem]? -> () */
  showChecks(problems) {
    if (!this.checks) return;
    const found = new Map(this.reports.map((r) => [r, []]));
    const loose = [];
    for (const problem of problems ?? []) {
      const r = this.reportFor(problem.line);
      if (r) found.get(r).push(problem);
      else loose.push(problem);
    }
    for (const r of this.reports) {
      const mine = found.get(r);
      r.element.classList.toggle("pkn-hidden", !r.checked && problems !== null && !mine.length);
      r.element.innerHTML = checkReport(problems === null ? null : mine, "");
    }
    this.top.innerHTML = checkReport(problems === null ? null : loose,
      "Teacher check", problems?.length ?? 0);
  }

  /** The report a problem at this line belongs to: its block's, or the
   *  one of the block it is inside. Int -> Report? */
  reportFor(line) {
    const parts = this.doc.parts.filter((p) => p.line <= line);
    const part = parts.find((p) => p.line === line) ?? parts[parts.length - 1];
    return part ? this.reportOf.get(part.index) ?? null : null;
  }

  rulesBox(rules) {
    const box = element("section", "pkn-rules");
    const limits = [];
    if (rules.max !== null) limits.push(`<span><b>${formatNumber(rules.max)}</b> points</span>`);
    if (rules.pass !== null) limits.push(`<span>pass at <b>${formatNumber(rules.pass)}</b></span>`);
    const git = this.notebook.items.filter((item) => !graded(item))
      .reduce((total, item) => total + (item.points ?? 0), 0);
    if (git) limits.push(`<span>and <b>${formatNumber(git)}</b> submitted with git, graded elsewhere</span>`);
    box.innerHTML = `<div class="pkn-rules-head"><span class="pkn-rules-title">Rules</span>`
      + `${limits.length ? `<span class="pkn-rules-limits">${limits.join("")}</span>` : ""}</div>`
      + `<div class="pkn-rules-body">${rules.html}</div>`;
    return box;
  }

  /** A progress bar, shown at the top and at the end. () -> Element */
  bar() {
    const bar = element("div", "pkn-progress");
    bar.innerHTML = `<span data-r="solved"></span><span data-r="points"></span>`
      + `<button class="pkn-tag pkn-start-over" data-r="reset">start over</button>`;
    bar.querySelector('[data-r="reset"]').addEventListener("click", () => {
      if (globalThis.confirm?.("Forget every answer in this notebook and start over?") ?? true) {
        this.startOver();
      }
    });
    this.bars.push(bar);
    this.renderBar(bar);
    return bar;
  }

  renderBar(bar) {
    const s = summary(this.notebook, this.states);
    const solved = bar.querySelector('[data-r="solved"]');
    const points = bar.querySelector('[data-r="points"]');
    solved.className = s.done ? "pkn-good" : "";
    solved.innerHTML = s.total
      ? `${s.done ? ICON.check : ""}<b>${s.solved}</b> of <b>${s.total}</b> solved` : "";
    const parts = [];
    if (s.max !== null || this.notebook.items.some((item) => item.points !== null)) {
      parts.push(`<b>${formatNumber(s.points)}</b>${s.max !== null ? ` of ${formatNumber(s.max)}` : ""} points`);
    }
    if (s.pass !== null) {
      parts.push(s.passed ? `${ICON.check}passed` : `pass at ${formatNumber(s.pass)}`);
    }
    points.className = s.passed ? "pkn-good" : "";
    points.innerHTML = parts.join(" · ");
  }
}

// ---------------------------------------------------------------- exercise

class ExerciseWidget {
  constructor(activities, item, at, used) {
    this.a = activities;
    this.item = item;
    this.cell = item.cell === null ? null : activities.cell(item.cell);
    this.solutionCell = item.solution ? activities.cell(item.solution.cell) : null;
    const state = activities.states[item.id];

    const box = element("section", "pkn-exercise");
    box.id = item.id;
    box.innerHTML = `
      <div class="pkn-activity-head">
        <span class="pkn-activity-title">Exercise ${item.number}</span>
        <span class="pkn-badges" data-r="badges"></span>
      </div>
      <div data-r="body"></div>
      <div class="pkn-git pkn-hidden" data-r="git">Please submit via your git account.</div>
      <div class="pkn-tests" data-r="tests"></div>
      <div class="pkn-activity-actions" data-r="actions">
        <button class="pkn-button pkn-primary" data-r="submit">Submit</button>
        <button class="pkn-button pkn-hidden" data-r="diff">See result diff</button>
        <button class="pkn-button pkn-hidden" data-r="show">Show a solution</button>
      </div>
      <div class="pkn-feedback pkn-hidden" data-r="feedback"></div>
      <div class="pkn-solution pkn-hidden" data-r="solution">
        <div class="pkn-solution-label">Solution</div>
      </div>`;
    this.ui = {};
    for (const el of box.querySelectorAll("[data-r]")) this.ui[el.dataset.r] = el;
    const anchor = this.cell?.element ?? at(activities.doc.parts[item.part]);
    anchor?.before(box);
    if (this.cell) this.ui.body.append(this.cell.element);
    else anchor?.remove();
    // An answer submitted with git is written elsewhere: no box for it.
    this.git = item.method === "git";
    if (this.git) {
      this.ui.body.classList.add("pkn-hidden");
      this.ui.git.classList.remove("pkn-hidden");
    }
    if (this.solutionCell) this.ui.solution.append(this.solutionCell.element);
    let shownTests = 0;
    for (const test of item.tests) {
      for (const block of [test.input, test.eventsPart, test.output, test.error]) {
        // One stdin block split into several tests is shown once.
        if (!block || used.has(block.index)) continue;
        used.add(block.index);
        const placeholder = at(block);
        if (this.a.teacher || isVisible(block)) {
          this.ui.tests.append(ioBox(block));
          shownTests += 1;
        }
        placeholder?.remove();
      }
    }
    // What the comparison allows to differ: a teacher's to see.
    for (const block of item.allowedParts) {
      used.add(block.index);
      if (this.a.teacher) {
        this.ui.tests.append(ioBox(block));
        shownTests += 1;
      }
      at(block)?.remove();
    }
    if (shownTests) {
      this.ui.tests.prepend(element("div", "pkn-tests-label",
        this.a.teacher ? "Tests" : "Examples"));
    }
    this.ui.submit.addEventListener("click", () => this.submit());
    this.ui.diff.addEventListener("click", () => this.showDiff());
    this.ui.show.addEventListener("click", () => {
      this.a.states[item.id].shown = true;
      this.render();
      this.a.changed();
    });
    if (this.cell) {
      this.cell.onEdit((source) => {
        const s = this.a.states[item.id];
        s.code = source === this.cell.spec.source ? undefined : source;
        this.a.save();
      });
      if (state.code !== undefined) this.cell.setSource(state.code);
    }
    this.box = box;
    this.render();
  }

  reset() {
    this.cell?.setSource(this.cell.spec.source);
    this.render();
  }

  render() {
    const { item } = this;
    const s = this.a.states[item.id];
    const badges = [];
    if (item.points !== null) {
      badges.push(badge(s.state === "solved"
        ? `${formatNumber(s.points)} of ${formatNumber(item.points)} points`
        : `${formatNumber(item.points)} point${item.points === 1 ? "" : "s"}`));
      if (item.penalty && !this.git) badges.push(badge(`−${formatNumber(item.penalty)} per failed try`));
    }
    if (this.git) {
      badges.push(badge("submitted with git"));
    } else {
      if (item.attempts !== null && s.state === "open") {
        const left = item.attempts - s.used;
        badges.push(badge(`${left} attempt${left === 1 ? "" : "s"} left`, "pkn-badge-attempts"));
      }
      badges.push(stateBadge(s.state));
    }
    this.ui.badges.innerHTML = badges.join("");
    this.box.dataset.state = this.git ? "git" : s.state;
    this.ui.submit.classList.toggle("pkn-hidden", this.git);
    this.ui.submit.disabled = s.state !== "open" || !this.cell;
    this.ui.diff.classList.toggle("pkn-hidden", !this.lastFailure);
    const solutionShown = this.a.teacher || (s.shown && item.solution?.available);
    this.ui.show.classList.toggle("pkn-hidden",
      !item.solution || this.a.teacher || !item.solution.available || !!s.shown);
    this.ui.solution.classList.toggle("pkn-hidden", !solutionShown);
    if (solutionShown) this.solutionCell?.editor?.resize(true);
    this.feedback(s.feedback ?? null);
  }

  feedback(feedback) {
    const box = this.ui.feedback;
    box.classList.toggle("pkn-hidden", !feedback);
    if (!feedback) return;
    box.className = `pkn-feedback pkn-feedback-${feedback.kind}`;
    box.innerHTML = feedback.html;
  }

  /** Runs the answer on every test, and the solution beside it where
   *  there is one; solved when every output matches. */
  async submit() {
    const { item } = this;
    const s = this.a.states[item.id];
    if (s.state !== "open" || !this.cell || this.busy) return;
    this.busy = true;
    this.ui.submit.disabled = true;
    this.feedback({ kind: "busy", html: "Checking your answer…" });
    let failed = null;
    try {
      const tests = item.tests.length ? item.tests
        : [{ stdin: null, args: null, output: null, error: null, input: null }];
      for (const test of tests) {
        const stdin = test.stdin ?? item.stdin;
        const args = test.args ?? item.args;
        const answer = await this.run(this.cell.source(), stdin, args, "answer", test.events);
        const expected = this.solutionCell
          ? await this.run(this.solutionCell.spec.source, stdin, args, "solution", test.events)
          : { ok: true, stdout: test.output?.text ?? "", stderr: test.error?.text ?? "", exit: 0 };
        if (!expected.ok) {
          failed = { test, stdin, args, problem: "The solution itself did not run:\n"
            + (expected.text ?? ""), answer, expected, broken: true };
          break;
        }
        const problem = compare(answer, expected, test, !!this.solutionCell, item.allowed);
        if (problem) {
          failed = { test, stdin, args, problem, answer, expected };
          break;
        }
      }
    } finally {
      this.busy = false;
    }
    // What "See result diff" shows: the first test whose outputs differ.
    this.lastFailure = failed && !failed.broken && failed.answer?.ok ? failed : null;
    if (failed?.broken) {
      s.feedback = { kind: "bad", html: `<pre>${escapeHTML(failed.problem)}</pre>` };
    } else if (!failed) {
      s.state = "solved";
      s.points = award(item, s.failures);
      s.feedback = { kind: "good", html: `${ICON.check} Solved${item.points !== null
        ? ` — ${formatNumber(s.points)} of ${formatNumber(item.points)} points` : ""}.` };
    } else {
      s.failures += 1;
      s.used += 1;
      const out = item.attempts !== null && s.used >= item.attempts;
      if (out) s.state = "failed";
      const detail = item.attempts === 1 ? "" : failureHTML(failed);
      const left = item.attempts === null ? "" : out ? " No attempts are left."
        : ` ${item.attempts - s.used} attempt${item.attempts - s.used === 1 ? "" : "s"} left.`;
      s.feedback = { kind: "bad",
        html: `<div>${out ? "Not solved." : "Not quite."}${left}</div>${detail}` };
    }
    this.render();
    this.a.changed();
  }

  run(source, stdin, args, role, events = "") {
    return this.a.cells.capture(source, {
      name: `${this.item.id}-${role}.pyk`,
      stdin,
      args: this.a.cells.web.splitArguments(args),
      timeout: SUBMIT_TIMEOUT,
      tinyweb: true,
      events: events ?? "",
    });
  }

  /** Shows the first test whose outputs differed, side by side: its
   *  input, the pictures the two drew where they drew any, and what each
   *  printed and drew, a line only one of them wrote marked. () -> () */
  async showDiff() {
    const failed = this.lastFailure;
    if (!failed) return;
    const { answer, expected } = failed;
    const host = this.box.closest(".pkn-notebook") ?? document.body;
    const backdrop = element("div", "pkn-modal-backdrop");
    const drawn = (answer.page?.length ?? 0) + (expected.page?.length ?? 0) > 0;
    const sections = [];
    sections.push(`<div class="pkn-diff-case">
        <div class="pkn-diff-case-title">The test case</div>
        ${io("stdin", failed.stdin || "(none)")}
        ${io("args", failed.args || "(none)")}
        ${failed.test?.events ? io("events", failed.test.events) : ""}
      </div>
      <div class="pkn-diff-what">${escapeHTML(failed.problem)}</div>
      <div class="pkn-diff-legend"><span class="pkn-diff-del">only in your submission</span>
        <span class="pkn-diff-add">only in the possible solution</span>
        ${this.item.allowed.length
          ? `<span class="pkn-diff-allowed">a difference the exercise allows</span>` : ""}</div>`);
    if (drawn) {
      sections.push(`<h4 class="pkn-diff-title">tinyweb: what each drew on its page</h4>
        <div class="pkn-diff-pair">
          <figure><figcaption>Your submission</figcaption><div class="pkn-diff-page" data-r="mine"></div></figure>
          <figure><figcaption>Possible solution</figcaption><div class="pkn-diff-page" data-r="theirs"></div></figure>
        </div>`);
    }
    const rules = this.item.allowed;
    sections.push(diffSection("Standard output", answer.stdout, expected.stdout, rules));
    if ((answer.tinyweb ?? "") !== "" || (expected.tinyweb ?? "") !== "") {
      sections.push(diffSection("tinyweb: the commands each sent its page",
        answer.tinyweb ?? "", expected.tinyweb ?? "", rules));
    }
    if (failed.test?.error || normalizeOutput(answer.stderr) !== normalizeOutput(expected.stderr)) {
      sections.push(diffSection("debug (standard error)", answer.stderr, expected.stderr, rules));
    }
    if ((answer.exit ?? 0) !== (expected.exit ?? 0)) {
      sections.push(`<div class="pkn-diff-what">Your submission ended with status ${answer.exit ?? 0}; `
        + `the possible solution with ${expected.exit ?? 0}.</div>`);
    }
    backdrop.innerHTML = `<div class="pkn-modal pkn-diff" role="dialog" aria-modal="true"
        aria-label="Result diff">
      <div class="pkn-modal-head"><strong>Exercise ${this.item.number}: the first test that did not match</strong>
        <button class="pkn-icon pkn-modal-close" data-r="close" title="Close (Esc)"
          aria-label="Close">✕</button></div>
      <div class="pkn-modal-body">${sections.join("")}</div>
    </div>`;
    host.append(backdrop);
    const pages = [];
    const onKey = (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        close();
      }
    };
    const close = () => {
      for (const page of pages) page.close();
      backdrop.remove();
      document.removeEventListener("keydown", onKey, true);
      this.ui.diff.focus();
    };
    document.addEventListener("keydown", onKey, true);
    backdrop.addEventListener("click", (event) => {
      if (event.target === backdrop) close();
    });
    const closer = backdrop.querySelector('[data-r="close"]');
    closer.addEventListener("click", close);
    closer.focus();
    if (drawn) {
      const { cells } = this.a;
      pages.push(await cells.drawPage(backdrop.querySelector('[data-r="mine"]'), answer.page ?? []));
      pages.push(await cells.drawPage(backdrop.querySelector('[data-r="theirs"]'), expected.page ?? []));
    }
  }
}

/** One output of a submission and of the solution side by side, as a
 *  table: a line only the submission wrote in red on the left, one only
 *  the solution wrote in green on the right, and a pair that differs
 *  only as a diff-allowed rule allows marked on both.
 *  String -> String -> String -> [Rule] -> String */
function diffSection(title, mine, theirs, rules = []) {
  const rows = lineDiff(normalizeOutput(mine ?? ""), normalizeOutput(theirs ?? ""),
    (a, b) => a === b || allowedLine(rules, a, b));
  const same = rows.every((row) => row.kind !== "change");
  const cell = (line, number, kind) => (line === null
    ? `<td class="pkn-diff-n"></td><td class="pkn-diff-line pkn-diff-none"></td>`
    : `<td class="pkn-diff-n">${number}</td>`
      + `<td class="pkn-diff-line${kind ? " " + kind : ""}">${escapeHTML(line) || " "}</td>`);
  const mark = (row, changed) => row.kind === "change" ? changed
    : row.kind === "same" && row.left !== row.right ? "pkn-diff-allowed" : "";
  const body = rows.map((row) => `<tr>${cell(row.left, row.l, mark(row, "pkn-diff-del"))}`
    + `${cell(row.right, row.r, mark(row, "pkn-diff-add"))}</tr>`).join("");
  const empty = rows.length === 0
    ? `<tr><td colspan="4" class="pkn-diff-empty">neither wrote anything</td></tr>` : "";
  return `<h4 class="pkn-diff-title">${escapeHTML(title)}`
    + `${same ? ` <span class="pkn-diff-same">the same</span>` : ""}</h4>
    <table class="pkn-diff-table"><colgroup><col class="pkn-diff-ncol"><col>
      <col class="pkn-diff-ncol"><col></colgroup><thead><tr><th colspan="2">Your submission</th>
      <th colspan="2">Possible solution</th></tr></thead><tbody>${body}${empty}</tbody></table>`;
}

/** Two texts' lines side by side, by their longest common subsequence:
 *  a row is a line the same on both sides -- by `same`, equality unless
 *  given -- or a change: what one side has and the other does not,
 *  paired up where both have some, null where a side has none. Line
 *  numbers count from 1.
 *  String -> String -> ((String, String) -> Bool)? -> [{kind, left, right, l, r}] */
export function lineDiff(a, b, same = (x, y) => x === y) {
  const x = a === "" ? [] : a.split("\n");
  const y = b === "" ? [] : b.split("\n");
  const n = x.length;
  const m = y.length;
  const longest = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      longest[i][j] = same(x[i], y[j]) ? longest[i + 1][j + 1] + 1
        : Math.max(longest[i + 1][j], longest[i][j + 1]);
    }
  }
  const rows = [];
  let gone = [];
  let added = [];
  const flush = () => {
    for (let k = 0; k < Math.max(gone.length, added.length); k++) {
      rows.push({ kind: "change", left: gone[k]?.[0] ?? null, l: gone[k]?.[1] ?? null,
                  right: added[k]?.[0] ?? null, r: added[k]?.[1] ?? null });
    }
    gone = [];
    added = [];
  };
  let i = 0;
  let j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && same(x[i], y[j])) {
      flush();
      rows.push({ kind: "same", left: x[i], right: y[j], l: i + 1, r: j + 1 });
      i += 1;
      j += 1;
    } else if (j >= m || (i < n && longest[i + 1][j] >= longest[i][j + 1])) {
      gone.push([x[i], i + 1]);
      i += 1;
    } else {
      added.push([y[j], j + 1]);
      j += 1;
    }
  }
  flush();
  return rows;
}

/** What is wrong with an answer's run, compared with what was expected,
 *  or null. {ok, stdout, stderr, exit, text} -> {..} -> Test -> Bool ->
 *  String? */
function compare(answer, expected, test, hasSolution, rules = []) {
  if (answer.timedOut) return "Your program did not finish in time.";
  if (!answer.ok) return "Your program did not run:\n" + (answer.text ?? "").trimEnd();
  const allowed = hasSolution ? rules : [];
  if ((hasSolution || test.output) && !sameOutput(answer.stdout, expected.stdout, allowed)) {
    return "The output is not what it should be.";
  }
  if (hasSolution && !sameOutput(answer.tinyweb ?? "", expected.tinyweb ?? "", allowed)) {
    return "What it drew with tinyweb is not what it should be.";
  }
  if (test.error && !sameOutput(answer.stderr, expected.stderr, allowed)) {
    return "What debug printed is not what it should be.";
  }
  if (hasSolution && (answer.exit ?? 0) !== (expected.exit ?? 0)) {
    return `Your program ended with status ${answer.exit ?? 0}, `
      + `and should end with ${expected.exit ?? 0}.`;
  }
  return null;
}

/** One failed test, as the student is shown it. {..} -> String */
function failureHTML(failed) {
  const rows = [`<div class="pkn-failure-what">${escapeHTML(failed.problem)}</div>`];
  if (failed.stdin) rows.push(io("stdin", failed.stdin));
  if (failed.args) rows.push(io("args", failed.args));
  if (failed.test?.events) rows.push(io("events", failed.test.events));
  if (failed.answer?.ok) {
    rows.push(io("expected", failed.expected.stdout + (failed.test.error ? failed.expected.stderr : "")));
    rows.push(io("got", failed.answer.stdout + (failed.test.error ? failed.answer.stderr : "")));
  }
  return `<div class="pkn-failure">${rows.join("")}</div>`;
}

function io(label, text) {
  return `<div class="pkn-io"><span class="pkn-input-label">${label}</span>`
    + `<pre class="pkn-io-text">${escapeHTML(text.replace(/\n$/, "")) || " "}</pre></div>`;
}

// -------------------------------------------------------------------- quiz

class QuizWidget {
  constructor(activities, item, at, used) {
    this.a = activities;
    this.item = item;
    const part = activities.doc.parts[item.part];
    const answerPart = item.answerPart === null ? null : activities.doc.parts[item.answerPart];
    used.add(part.index);
    if (answerPart) used.add(answerPart.index);

    const box = element("section", "pkn-quiz");
    box.id = item.id;
    const type = item.multiple ? "checkbox" : "radio";
    const options = item.alternatives.map((alternative, k) => `
      <label class="pkn-alternative" data-k="${k}">
        <input type="${type}" name="${item.id}" value="${k}">
        <span class="pkn-alternative-text">${alternative.html}</span>
        <span class="pkn-alternative-mark" data-mark="${k}"></span>
      </label>
      <div class="pkn-explanation pkn-hidden" data-explain="${k}"></div>`).join("");
    box.innerHTML = `
      <div class="pkn-activity-head">
        <span class="pkn-activity-title">Quiz ${item.number}</span>
        <span class="pkn-badges" data-r="badges"></span>
      </div>
      ${item.question ? `<div class="pkn-quiz-question">${item.question}</div>` : ""}
      <div class="pkn-quiz-hint">${quizRule(item)}</div>
      <div class="pkn-alternatives">${options}</div>
      <div class="pkn-activity-actions">
        <button class="pkn-button pkn-primary" data-r="submit">Submit</button>
      </div>
      <div class="pkn-feedback pkn-hidden" data-r="feedback"></div>`;
    this.ui = {};
    for (const el of box.querySelectorAll("[data-r]")) this.ui[el.dataset.r] = el;
    this.inputs = [...box.querySelectorAll("input")];
    for (const input of this.inputs) {
      input.addEventListener("change", () => {
        const s = this.a.states[item.id];
        s.chosen = this.chosen();
        this.a.save();
      });
    }
    this.ui.submit.addEventListener("click", () => this.submit());
    at(part)?.replaceWith(box);
    if (answerPart) {
      const key = at(answerPart);
      if (this.a.teacher) {
        this.key = this.answerKey();
        key?.replaceWith(this.key);
      }
      else key?.remove();
    }
    this.box = box;
    this.restore();
    this.render();
  }

  chosen() {
    return this.inputs.filter((input) => input.checked).map((input) => Number(input.value));
  }

  restore() {
    const chosen = new Set(this.a.states[this.item.id].chosen ?? []);
    for (const input of this.inputs) input.checked = chosen.has(Number(input.value));
  }

  reset() {
    this.restore();
    this.render();
  }

  answerKey() {
    const box = element("div", "pkn-answer-key");
    box.innerHTML = `<div class="pkn-tests-label">Answer</div>` + this.item.answers.map((answer, k) =>
      `<div class="pkn-key ${answer.correct ? "pkn-key-right" : "pkn-key-wrong"}">`
      + `${answer.correct ? ICON.check : ICON.cross}`
      + `<span><b>${this.item.alternatives[k]?.html ?? ""}</b>`
      + `${answer.html ? ` — ${answer.html}` : ""}</span></div>`).join("");
    return box;
  }

  render() {
    const { item } = this;
    const s = this.a.states[item.id];
    const badges = [];
    if (item.points !== null) {
      badges.push(badge(s.state === "solved" || (s.state === "failed" && s.points > 0)
        ? `${formatNumber(s.points)} of ${formatNumber(item.points)} points`
        : `${formatNumber(item.points)} point${item.points === 1 ? "" : "s"}`));
      if (item.penalty) badges.push(badge(`−${formatNumber(item.penalty)} per wrong answer`));
    }
    if (item.attempts !== null && !item.onePointCorrect && s.state === "open") {
      const left = item.attempts - s.used;
      badges.push(badge(`${left} attempt${left === 1 ? "" : "s"} left`, "pkn-badge-attempts"));
    }
    badges.push(stateBadge(s.state));
    this.ui.badges.innerHTML = badges.join("");
    this.box.dataset.state = s.state;
    const closed = s.state !== "open";
    for (const input of this.inputs) input.disabled = closed;
    this.ui.submit.disabled = closed;
    const reveal = s.state === "solved" || (s.state === "failed" && item.available) || this.a.teacher;
    for (const mark of this.box.querySelectorAll("[data-mark]")) {
      const answer = item.answers[Number(mark.dataset.mark)];
      mark.innerHTML = reveal && answer && (s.state !== "solved" || answer.correct)
        ? (answer.correct ? ICON.check : ICON.cross) : "";
      mark.className = "pkn-alternative-mark" + (answer?.correct ? " pkn-good" : " pkn-bad");
    }
    const explained = new Set(s.explained ?? []);
    for (const box of this.box.querySelectorAll("[data-explain]")) {
      const k = Number(box.dataset.explain);
      const answer = item.answers[k];
      const show = answer?.html && (explained.has(k)
        || (s.state === "failed" && item.available));
      box.classList.toggle("pkn-hidden", !show);
      box.classList.toggle("pkn-explanation-right", !!answer?.correct);
      box.innerHTML = show ? answer.html : "";
    }
    const feedback = s.feedback;
    this.ui.feedback.classList.toggle("pkn-hidden", !feedback);
    if (feedback) {
      this.ui.feedback.className = `pkn-feedback pkn-feedback-${feedback.kind}`;
      this.ui.feedback.innerHTML = feedback.html;
    }
  }

  submit() {
    const { item } = this;
    const s = this.a.states[item.id];
    if (s.state !== "open") return;
    const chosen = this.chosen();
    if (!chosen.length) {
      s.feedback = { kind: "busy", html: item.multiple ? "Check at least one answer first."
        : "Choose an answer first." };
      this.render();
      return;
    }
    s.chosen = chosen;
    const verdict = checkQuiz(item, chosen);
    if (verdict.correct) {
      s.state = "solved";
      s.points = quizAward(item, chosen, s.failures);
      s.explained = chosen;
      s.feedback = { kind: "good", html: `${ICON.check} Right${item.points !== null
        ? ` — ${formatNumber(s.points)} of ${formatNumber(item.points)} points` : ""}.` };
    } else {
      s.failures += 1;
      s.used += 1;
      const out = item.attempts !== null && s.used >= item.attempts;
      const lines = [];
      if (out) {
        s.state = "failed";
        s.points = quizAward(item, chosen, s.failures - 1);
        s.explained = [];
        if (s.points > 0) {
          lines.push(`Partly right: ${formatNumber(s.points)} of ${formatNumber(item.points)} points.`);
        }
        lines.push(item.available ? "Not right. The right answers are marked."
          : "Not right, and no attempts are left. The quiz is failed.");
      } else {
        s.explained = verdict.wrong;
        lines.push("Not right.");
        if (item.multiple && verdict.missed) lines.push("One or more right answers were not checked.");
        if (item.attempts !== null && !item.onePointCorrect) {
          const left = item.attempts - s.used;
          lines.push(`${left} attempt${left === 1 ? "" : "s"} left.`);
        }
      }
      s.feedback = { kind: "bad", html: lines.map((l) => `<div>${l}</div>`).join("") };
    }
    this.render();
    this.a.changed();
  }
}

// ----------------------------------------------------------------- helpers

/** A teacher check's text: checking where `problems` is null, else that
 *  nothing was found or the problems with their lines. The summary at the
 *  top is titled, and counts every problem in the document.
 *  [Problem]? -> String -> Int -> String */
function checkReport(problems, title, total = null) {
  const lead = title ? `${title}: ` : "";
  if (problems === null) {
    return `<div class="pkn-check-busy">${lead}checking${title ? " the notebook" : ""}…</div>`;
  }
  const count = total ?? problems.length;
  if (!count) {
    return `<div class="pkn-check-good">${ICON.check}${lead}no problems found`
      + `${title ? " in this notebook" : ""}.</div>`;
  }
  const rows = problems.map((p) => `<li><span class="pkn-check-line">line ${p.line}</span>`
    + `<span class="pkn-check-message">${escapeHTML(p.message)}</span></li>`).join("");
  return `<div class="pkn-check-bad">${ICON.cross}${lead}${count} problem${count === 1 ? "" : "s"}`
    + `${title ? " found in this notebook" : " found"}${rows ? ":" : "."}</div>`
    + (rows ? `<ul class="pkn-check-list">${rows}</ul>` : "");
}

/** What a quiz says a student is to do. Quiz -> String */
function quizRule(item) {
  if (!item.multiple) return "Choose one answer.";
  if (!item.onePointCorrect) return "Choose every right answer.";
  const n = rightAnswers(item);
  const alternatives = `${n} alternative${n === 1 ? "" : "s"}`;
  return `Choose every answer you believe is true. Note that in this case, exactly `
    + `${alternatives} ${n === 1 ? "is" : "are"} correct. If you check more than ${alternatives}, `
    + `you get zero points. Otherwise, you get 1 point for each correct answer.`;
}

function isVisible(block) {
  return block.attrs.visible === true || block.attrs.visible === "true";
}

/** A stdin, events, stdout or stderr block shown on the page.
 *  Part -> Element */
function ioBox(block) {
  const box = element("div", `pkn-io pkn-io-${block.kind}`);
  const args = block.kind === "stdin" && typeof block.attrs.args === "string"
    ? ` <span class="pkn-io-args">args: ${escapeHTML(block.attrs.args)}</span>` : "";
  box.innerHTML = `<span class="pkn-input-label">${block.kind}${args}</span>`
    + `<pre class="pkn-io-text">${escapeHTML(block.text) || " "}</pre>`;
  return box;
}

function element(tag, className, text = null) {
  const el = document.createElement(tag);
  el.className = className;
  if (text !== null) el.textContent = text;
  return el;
}

function badge(text, extra = "") {
  return `<span class="pkn-badge ${extra}">${escapeHTML(text)}</span>`;
}

function stateBadge(state) {
  if (state === "solved") return `<span class="pkn-badge pkn-badge-solved">${ICON.check}solved</span>`;
  if (state === "failed") return `<span class="pkn-badge pkn-badge-failed">${ICON.cross}failed</span>`;
  return "";
}

function formatNumber(n) {
  return Number.isInteger(n) ? String(n) : String(Math.round(n * 100) / 100);
}

const svg = (body) =>
  `<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true">${body}</svg>`;

const ICON = {
  check: svg('<path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'),
  cross: svg('<path d="M4.5 4.5l7 7M11.5 4.5l-7 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>'),
};
