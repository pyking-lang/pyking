// The notebook's exercises and quizzes: what the blocks markdown.js
// records (`parts`) make -- the rules, each exercise with its solution
// and tests, each quiz with its answers, the examples under ordinary
// cells, and the input blocks that fill in the cell after them -- and
// what is wrong with them. Also the grading arithmetic. Pure: no DOM, so
// the page, test mode (tools/notebook/check.js) and the test suite share
// it. See tools/notebook/README.md, "Exercises and quizzes".
//
// Data structures:
//   Notebook -- {rules, items, examples, problems}: what a document makes.
//   Rules -- {line, max, pass, html}: the one ```rules block.
//   Exercise -- {kind: "exercise", id, name, number, key, line, part, cell,
//     method, attempts, points, penalty, stdin, args, solution, tests,
//     allowed, allowedParts}: `allowed` the Rules of its diff-allowed blocks;
//     `method` "inline" (answered in the page) or "git" (not graded
//     here); `name` the name = it was given, or null.
//   Solution -- {cell, line, available, picture}: `picture` {canvas,
//     file} where the solution's canvas is saved as a picture, or null.
//   Test -- {line, stdin, args, events, input, eventsPart, output, error}:
//     one input and what it should print; `input`, `eventsPart`, `output`
//     and `error` are the blocks, `events` the tinyweb events delivered
//     once the program's top level has ended, or "". A stdin block split
//     by lines_per_multi_input is one Test per piece.
//   Quiz -- {kind: "quiz", id, name, number, key, line, part, answerPart,
//     question, alternatives, multiple, onePointCorrect, answers, attempts,
//     points, penalty, available}.
//   Example -- {cell, line, tests}: input and output under an ordinary cell.
//   Rule -- {text, pattern, slots}: one diff-allowed line, its literal
//     text as a RegExp with a number where each [+/-N] stands, and each
//     slot's N.
//   Problem -- {line, message}.
//
// Functions:
//   structure(parts, cells) -- what the blocks make, and what is wrong.
//   normalizeOutput(text) -- output as it is compared.
//   sameOutput(a, b, rules) -- whether two outputs count as the same.
//   allowedLine(rules, a, b) -- whether two lines differ only as a rule allows.
//   checkQuiz(quiz, chosen) -- what a quiz answer got right and wrong.
//   rightAnswers(quiz) -- how many of a quiz's alternatives are right.
//   quizAward(quiz, chosen, failures) -- the points a check that ends a
//     quiz gives.
//   award(item, failures) -- the points an item solved after failures gives.
//   summary(notebook, states) -- solved, points and passing, for the page.
//   graded(item) -- whether the page grades an item.
//   pictures(notebook) -- the pictures the solutions save.

/** The attributes each kind of block may carry. */
const KNOWN = {
  rules: ["max", "pass"],
  exercise: ["exercise", "name", "attempts", "points", "penalty", "stdin", "args", "readonly", "method"],
  solution: ["solution", "available", "readonly", "stdin", "args", "save_canvas", "file"],
  // `playground` is the website's (tools/site/src/remark-pyking-cells.mjs).
  pyking: ["norun", "readonly", "error", "stdin", "args", "playground"],
  stdin: ["args", "visible", "lines_per_multi_input"],
  args: [],
  stdout: ["visible"],
  stderr: ["visible"],
  events: ["visible"],
  quiz: ["name", "attempts", "points", "penalty", "available", "one_point_correct"],
  answer: [],
  "diff-allowed": [],
};

/** What the blocks of a document make, and the problems with them. Also
 *  fills in a cell's input from a ```stdin or ```args block right before
 *  it, which is the older way to give one. [Part] -> [Cell] -> Notebook */
export function structure(parts, cells) {
  const problems = [];
  const problem = (part, message) => problems.push({ line: part.line, message });
  const items = [];
  const examples = [];
  let rules = null;
  let exercises = 0;
  let quizzes = 0;

  const groups = [];
  for (const part of parts) {
    if (!groups.length || groups[groups.length - 1][0].group !== part.group) groups.push([]);
    groups[groups.length - 1].push(part);
  }

  for (const group of groups) {
    // What the blocks after it belong to: an exercise, an ordinary cell,
    // or nothing.
    let owner = null;
    let pending = {};          // ```stdin / ```args waiting for a cell
    for (let k = 0; k < group.length; k++) {
      const part = group[k];
      const next = group[k + 1];
      checkAttributes(part, problem);
      if (part.attrs.visible !== undefined) flag(part, "visible", false, problem);
      switch (part.kind) {
        case "rules": {
          if (rules) problem(part, "a notebook has one rules block, and this is a second");
          else rules = readRules(part, problem);
          owner = null;
          break;
        }
        case "exercise": {
          exercises += 1;
          owner = readExercise(part, cells, exercises, problem);
          items.push(owner);
          break;
        }
        case "solution": {
          if (owner?.kind !== "exercise" || owner.solution || owner.tests.length) {
            problem(part, "a solution belongs right after the exercise it solves");
            owner = null;
          } else if (part.cell === null) {
            problem(part, "a solution is run, so it cannot be norun");
          } else {
            owner.solution = {
              cell: part.cell, line: part.line,
              // A student is shown it only where it says so.
              available: flag(part, "available", false, problem),
              picture: readPicture(part, problem),
            };
            // Run on its own, a solution reads what the exercise does.
            const cell = cells[part.cell];
            if (cell.stdin === null) cell.stdin = owner.stdin;
            if (cell.args === null) cell.args = owner.args;
          }
          break;
        }
        case "quiz": {
          quizzes += 1;
          const quiz = readQuiz(part, quizzes, problem);
          items.push(quiz);
          if (next?.kind === "answer") {
            readAnswer(quiz, next, problem);
            k += 1;
          } else {
            problem(part, "a quiz needs an answer block right after it");
          }
          owner = null;
          break;
        }
        case "answer":
          problem(part, "an answer block belongs right after its quiz");
          owner = null;
          break;
        case "diff-allowed": {
          if (owner?.kind !== "exercise") {
            problem(part, "a diff-allowed block belongs under an exercise");
          } else {
            if (!owner.solution) problem(part, "a diff-allowed block loosens how an answer is compared with the solution, which this exercise does not have");
            owner.allowed.push(...readAllowed(part, problem));
            owner.allowedParts.push(part);
          }
          break;
        }
        case "pyking": {
          if (part.cell !== null) {
            const cell = cells[part.cell];
            if (pending.stdin !== undefined && cell.stdin === null) cell.stdin = pending.stdin;
            if (pending.args !== undefined && cell.args === null) cell.args = pending.args;
          }
          pending = {};
          owner = { kind: "cell", cell: part.cell, line: part.line, tests: [] };
          examples.push(owner);
          break;
        }
        case "stdin":
        case "args": {
          if (owner?.kind === "exercise") {
            if (part.kind === "args") {
              problem(part, "an exercise's test gives its arguments as args = on its stdin block");
            } else if (part.attrs.lines_per_multi_input !== undefined) {
              owner.tests.push(...splitTests(part, owner, problem));
            } else {
              owner.tests.push(newTest(part));
            }
          } else if (part.kind === "stdin" && owner?.kind === "cell"
                     && ["stdout", "stderr", "events"].includes(next?.kind)) {
            owner.tests.push(newTest(part));
          } else if (["pyking", "stdin", "args"].includes(next?.kind)) {
            pending[part.kind] = part.kind === "stdin"
              ? inputLines(part.text) : part.text.replace(/\n+$/, "");
          } else {
            problem(part, `this ${part.kind} block fills in no cell: write it right before `
              + "one, or under a cell or an exercise followed by its stdout");
          }
          break;
        }
        case "events": {
          if (owner?.kind === "exercise" || owner?.kind === "cell") {
            const last = owner.tests[owner.tests.length - 1];
            if (last && !last.eventsPart && !last.output && !last.error) {
              for (const test of owner.tests.filter((t) => t.input && t.input === last.input)) {
                test.eventsPart = part;
                test.events = part.text;
              }
            } else {
              const test = newTest(null, part.line);
              test.eventsPart = part;
              test.events = part.text;
              owner.tests.push(test);
            }
          } else {
            problem(part, "an events block belongs under a cell or an exercise");
          }
          break;
        }
        case "stdout":
        case "stderr": {
          if (owner?.kind === "exercise" || owner?.kind === "cell") {
            const last = owner.tests[owner.tests.length - 1];
            const slot = part.kind === "stdout" ? "output" : "error";
            if (last && !last[slot] && last.input?.attrs.lines_per_multi_input !== undefined) {
              problem(part, "a stdin block with lines_per_multi_input has no stdout or stderr after it: each piece is compared with the solution");
            } else if (last && !last[slot]) {
              last[slot] = part;
            } else {
              const test = newTest(null, part.line);
              test[slot] = part;
              owner.tests.push(test);
            }
          } else {
            problem(part, `a ${part.kind} block belongs under a cell or an exercise`);
          }
          break;
        }
        default:
          break;
      }
    }
  }

  for (const item of items) {
    if (item.kind === "exercise") checkExercise(item, problems);
  }
  for (const example of examples) {
    for (const test of example.tests) {
      if (!test.output && !test.error) {
        problems.push({ line: test.line, message: "this stdin block has no stdout or stderr after it" });
      }
    }
  }
  checkNames(items, problems);
  if (rules) checkPoints(rules, items, problems);
  problems.sort((a, b) => a.line - b.line);
  return { rules, items, examples: examples.filter((e) => e.tests.length), problems };
}

/** Complains about an attribute the block's kind does not take.
 *  Part -> (Part -> String -> ()) -> () */
function checkAttributes(part, problem) {
  const known = KNOWN[part.kind] ?? [];
  for (const name of Object.keys(part.attrs)) {
    if (!known.includes(name)) {
      const block = part.kind === "pyking" ? "a pyking cell" : `a ${part.kind} block`;
      problem(part, `${block} takes no attribute '${name}'`);
    }
  }
}

function readRules(part, problem) {
  return {
    line: part.line,
    max: number(part, "max", null, problem),
    pass: number(part, "pass", null, problem),
    html: part.html ?? "",
  };
}

function readExercise(part, cells, number_, problem) {
  if (part.cell === null) problem(part, "an exercise is run, so it cannot be norun");
  const stdin = typeof part.attrs.stdin === "string" ? inputLines(part.attrs.stdin) : "";
  const method = part.attrs.method ?? "inline";
  if (method === "code_box") {
    problem(part, "method code_box is now called inline");
  } else if (!["inline", "git"].includes(method)) {
    problem(part, `method is inline or git, not '${method}'`);
  }
  return {
    kind: "exercise",
    id: `exercise-${number_}`,
    name: readName(part, problem),
    number: number_,
    key: hash(part.text),
    line: part.line,
    part: part.index,
    cell: part.cell,
    method: method === "git" ? "git" : "inline",
    attempts: count(part, "attempts", problem),
    points: number(part, "points", null, problem),
    penalty: number(part, "penalty", 0, problem) ?? 0,
    stdin,
    args: typeof part.attrs.args === "string" ? part.attrs.args : "",
    solution: null,
    tests: [],
    allowed: [],
    allowedParts: [],
  };
}

function readQuiz(part, number_, problem) {
  if (part.mixed) problem(part, "a quiz's alternatives are all * (choose one) or all [] (choose any)");
  if (!part.alternatives.length) problem(part, "a quiz needs at least one alternative");
  const onePointCorrect = flag(part, "one_point_correct", false, problem);
  if (onePointCorrect && !part.multiple && !part.mixed && part.alternatives.length) {
    problem(part, "one_point_correct is for a quiz whose alternatives are [] (choose any)");
  }
  return {
    kind: "quiz",
    id: `quiz-${number_}`,
    name: readName(part, problem),
    number: number_,
    key: hash(part.text),
    line: part.line,
    part: part.index,
    answerPart: null,
    question: part.question ?? "",
    alternatives: part.alternatives,
    multiple: part.multiple,
    onePointCorrect,
    answers: [],
    // One point per right answer is a score, so it is checked once
    // unless the quiz says otherwise.
    attempts: count(part, "attempts", problem) ?? (onePointCorrect ? 1 : null),
    points: number(part, "points", null, problem),
    penalty: number(part, "penalty", 0, problem) ?? 0,
    available: flag(part, "available", false, problem),
  };
}

function readAnswer(quiz, part, problem) {
  quiz.answers = part.answers;
  quiz.answerPart = part.index;
  quiz.key = hash(quiz.key + part.text);
  if (part.answers.stray) problem(part, "an answer block holds only its entries, each starting with - or ->");
  if (part.answers.length !== quiz.alternatives.length) {
    problem(part, `the quiz has ${quiz.alternatives.length} alternative`
      + `${quiz.alternatives.length === 1 ? "" : "s"} and its answer `
      + `${part.answers.length} entr${part.answers.length === 1 ? "y" : "ies"}`);
  }
  const right = part.answers.filter((a) => a.correct).length;
  if (!quiz.multiple && right !== 1) {
    problem(part, `a quiz whose alternatives are * has one right answer (->), not ${right}`);
  }
  if (quiz.onePointCorrect && quiz.multiple && quiz.points !== right) {
    problem(part, `with one_point_correct, points is the number of right answers (${right}), `
      + `not ${quiz.points ?? "missing"}`);
  }
}

/** What a solution's save_canvas and file say: the canvas whose drawing
 *  is saved, and the file it is saved as -- a .png beside the notebook,
 *  named by plain parts. Both or neither. Part -> (..) -> {canvas, file}? */
function readPicture(part, problem) {
  const { save_canvas: canvas, file } = part.attrs;
  if (canvas === undefined && file === undefined) return null;
  if (typeof canvas !== "string" || canvas === "") {
    problem(part, "file = names where a canvas is saved, so it needs save_canvas = \"…\" too");
    return null;
  }
  if (typeof file !== "string" || file === "") {
    problem(part, "save_canvas = needs file = \"….png\", the file the canvas is saved as");
    return null;
  }
  const plain = file.split("/").every((p) => /^[A-Za-z0-9_.-]+$/.test(p) && !p.startsWith("."));
  if (!plain || !file.endsWith(".png")) {
    problem(part, `file is a .png beside the notebook, named by letters, digits, _, - and ., not '${file}'`);
    return null;
  }
  return { canvas, file };
}

/** A stdin block whose lines_per_multi_input = N makes a test of every N
 *  lines, each with the block's arguments. Its tests are compared with
 *  the solution, so the exercise needs one and nothing may follow it
 *  as its output. Part -> Exercise -> Part? -> (..) -> [Test] */
function splitTests(part, owner, problem) {
  const n = Number(part.attrs.lines_per_multi_input);
  if (!Number.isInteger(n) || n < 1) {
    problem(part, `lines_per_multi_input is a whole number of at least 1, not '${part.attrs.lines_per_multi_input}'`);
    return [newTest(part)];
  }
  if (!owner.solution) problem(part, "a stdin block with lines_per_multi_input is compared with the solution, which this exercise does not have");
  const lines = part.text.replace(/\n+$/, "").split("\n");
  if (lines.length % n !== 0) {
    problem(part, `its ${lines.length} line${lines.length === 1 ? "" : "s"} are not pieces of ${n}`);
  }
  const tests = [];
  for (let k = 0; k < lines.length; k += n) {
    const test = newTest(part);
    test.stdin = inputLines(lines.slice(k, k + n).join("\n"));
    tests.push(test);
  }
  return tests;
}

/** The rules a diff-allowed block holds, one per line that is not
 *  blank. Part -> (..) -> [Rule] */
function readAllowed(part, problem) {
  const rules = [];
  for (const [k, text] of part.text.split("\n").entries()) {
    if (text.trim() === "") continue;
    const rule = allowedRule(text.trimEnd());
    if (typeof rule === "string") problemAt(problem, part, k, rule);
    else rules.push(rule);
  }
  if (!rules.length && !part.text.trim()) problem(part, "a diff-allowed block needs at least one line");
  return rules;
}

/** A problem on the k-th line of a block's text. */
function problemAt(problem, part, k, message) {
  problem({ ...part, line: part.line + 1 + k }, message);
}

/** The digits a number in output is written with: a sign, digits, and a
 *  fraction or exponent. */
const NUMBER = "[-+]?(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][-+]?\\d+)?";

/** One diff-allowed line as a Rule, or why it is not one: its text is
 *  matched exactly, and each [+/-N] stands for a number allowed to be N
 *  away from the solution's. String -> Rule | String */
function allowedRule(text) {
  const slots = [];
  let pattern = "";
  let rest = text;
  const slot = /\[\s*\+\s*\/\s*-\s*([0-9]+(?:\.[0-9]+)?)\s*\]/;
  for (;;) {
    const found = slot.exec(rest);
    const literal = found ? rest.slice(0, found.index) : rest;
    if (/[[\]]/.test(literal)) {
      return `a diff-allowed line's [ ] holds +/- and a number, as [+/-2] or [+/-0.5]: '${text}'`;
    }
    pattern += literal.replace(/[.*+?^${}()|\\]/g, "\\$&");
    if (!found) break;
    pattern += `(${NUMBER})`;
    slots.push(Number(found[1]));
    rest = rest.slice(found.index + found[0].length);
  }
  if (!slots.length) return `a diff-allowed line needs a [+/-N] where a number may differ: '${text}'`;
  return { text, pattern: new RegExp(`^${pattern}$`), slots };
}

/** Whether two lines are the same but for numbers a rule allows to
 *  differ: both match one rule, and each slot's two numbers are within
 *  its N. [Rule] -> String -> String -> Bool */
export function allowedLine(rules, a, b) {
  for (const rule of rules) {
    const x = rule.pattern.exec(a);
    const y = x && rule.pattern.exec(b);
    if (!y) continue;
    if (rule.slots.every((tolerance, k) =>
      Math.abs(Number(x[k + 1]) - Number(y[k + 1])) <= tolerance + 1e-9)) return true;
  }
  return false;
}

function newTest(part, line = part.line) {
  return {
    line,
    input: part,
    stdin: part ? inputLines(part.text) : null,
    args: part ? (typeof part.attrs.args === "string" ? part.attrs.args : "") : null,
    events: "",
    eventsPart: null,
    output: null,
    error: null,
  };
}

/** An item's name = : letters, digits, _ and -, starting with a letter
 *  or a digit; null where none is given. Part -> (..) -> String? */
function readName(part, problem) {
  const value = part.attrs.name;
  if (value === undefined) return null;
  if (typeof value !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(value)) {
    problem(part, `a name is letters, digits, _ and -, starting with a letter or a digit, not '${value}'`);
    return null;
  }
  return value;
}

/** Complains about a name two items share. [Item] -> [Problem] -> () */
function checkNames(items, problems) {
  const seen = new Map();
  for (const item of items) {
    if (item.name === null) continue;
    if (seen.has(item.name)) {
      problems.push({ line: item.line,
        message: `the name '${item.name}' is given to the item on line ${seen.get(item.name)} too` });
    } else {
      seen.set(item.name, item.line);
    }
  }
}

function checkExercise(item, problems) {
  const say = (line, message) => problems.push({ line, message });
  if (item.solution) return;
  if (!item.tests.length) {
    say(item.line, "an exercise needs a solution or a stdout block to check an answer against");
  }
  for (const test of item.tests) {
    if (!test.output && !test.error) {
      say(test.line, "with no solution, this input needs a stdout or stderr block after it");
    }
  }
}

function checkPoints(rules, items, problems) {
  const sum = items.filter(graded).reduce((total, item) => total + (item.points ?? 0), 0);
  if (rules.max !== null && sum !== rules.max) {
    const git = items.some((item) => !graded(item));
    problems.push({ line: rules.line,
      message: `max is ${rules.max}, but the exercises and quizzes ${git ? "graded in the page " : ""}`
        + `give ${sum} point${sum === 1 ? "" : "s"}` });
  }
  if (rules.max !== null && rules.pass !== null && rules.pass > rules.max) {
    problems.push({ line: rules.line, message: `pass (${rules.pass}) is more than max (${rules.max})` });
  }
}

/** An attribute that is a number of times: a whole number of at least 1,
 *  or null where it is not given (as often as wanted). */
function count(part, name, problem) {
  const value = part.attrs[name];
  if (value === undefined) return null;
  const n = Number(value);
  if (value === true || !Number.isInteger(n) || n < 1) {
    problem(part, `${name} is a whole number of at least 1, not '${value}'`);
    return null;
  }
  return n;
}

/** An attribute that is a number of points, 0 or more. */
function number(part, name, otherwise, problem) {
  const value = part.attrs[name];
  if (value === undefined) return otherwise;
  const n = Number(value);
  if (value === true || value === "" || !Number.isFinite(n) || n < 0) {
    problem(part, `${name} is a number of at least 0, not '${value}'`);
    return otherwise;
  }
  return n;
}

/** An attribute that is true or false. */
function flag(part, name, otherwise, problem) {
  const value = part.attrs[name];
  if (value === undefined) return otherwise;
  if (value === true || value === "true") return true;
  if (value === "false") return false;
  problem(part, `${name} is true or false, not '${value}'`);
  return otherwise;
}

/** Text a program reads on standard input: lines, each ending in a
 *  newline. String -> String */
function inputLines(text) {
  return text === "" || text.endsWith("\n") ? text : text + "\n";
}

/** A short fingerprint of a block's text, which says whether progress
 *  saved for an item still belongs to it. String -> String */
function hash(text) {
  let h = 5381;
  for (let i = 0; i < text.length; i++) h = ((h * 33) ^ text.charCodeAt(i)) >>> 0;
  return h.toString(36);
}

// --- grading -----------------------------------------------------------

/** Output as it is compared: each line without the spaces at its end,
 *  and no blank lines at the end. String -> String */
export function normalizeOutput(text) {
  const lines = text.replace(/\r/g, "").split("\n").map((line) => line.trimEnd());
  while (lines.length && lines[lines.length - 1] === "") lines.pop();
  return lines.join("\n");
}

/** Whether two outputs count as the same: line for line, but for what
 *  `rules` allow to differ. String -> String -> [Rule]? -> Bool */
export function sameOutput(a, b, rules = []) {
  const x = normalizeOutput(a);
  const y = normalizeOutput(b);
  if (x === y) return true;
  if (!rules.length) return false;
  const left = x.split("\n");
  const right = y.split("\n");
  return left.length === right.length
    && left.every((line, k) => line === right[k] || allowedLine(rules, line, right[k]));
}

/** What an answer to a quiz got right and wrong: whether it is correct,
 *  whether a right alternative was left out, and the wrong ones chosen.
 *  Quiz -> [Int] -> {correct, missed, wrong} */
export function checkQuiz(quiz, chosen) {
  const picked = new Set(chosen);
  const wrong = [...picked].filter((k) => !quiz.answers[k]?.correct).sort((a, b) => a - b);
  const missed = quiz.answers.some((answer, k) => answer.correct && !picked.has(k));
  return { correct: !missed && wrong.length === 0, missed, wrong };
}

/** How many of a quiz's alternatives are right. Quiz -> Int */
export function rightAnswers(quiz) {
  return quiz.answers.filter((answer) => answer.correct).length;
}

/** The points a check that ends a quiz gives, after `failures` failed
 *  tries before it. With one_point_correct, one point per right answer
 *  chosen, and none where more were chosen than there are right answers;
 *  otherwise all the points when the answer is right and none when not.
 *  Either way less the penalty for each earlier failure, never below 0.
 *  Quiz -> [Int] -> Int -> Number */
export function quizAward(quiz, chosen, failures) {
  if (quiz.points === null) return 0;
  const verdict = checkQuiz(quiz, chosen);
  let score;
  if (!quiz.onePointCorrect) score = verdict.correct ? quiz.points : 0;
  else if (new Set(chosen).size > rightAnswers(quiz)) score = 0;
  else score = new Set(chosen).size - verdict.wrong.length;
  return Math.max(0, score - quiz.penalty * failures);
}

/** The points an item gives when solved after `failures` failed tries:
 *  its points less its penalty for each, never below 0; 0 for an item
 *  without points. Item -> Int -> Number */
export function award(item, failures) {
  if (item.points === null) return 0;
  return Math.max(0, item.points - item.penalty * failures);
}

/** What the page says at its top and its end: how many items are solved,
 *  the points so far, and whether they pass. `states` maps an item's id
 *  to {state, points}, `state` being "open", "solved" or "failed".
 *  Notebook -> {String: {state, points}} ->
 *  {solved, total, points, max, pass, passed, done} */
export function summary(notebook, states) {
  const items = notebook.items.filter(graded);
  const solved = items.filter((item) => states[item.id]?.state === "solved").length;
  const points = items.reduce((total, item) => total + (states[item.id]?.points ?? 0), 0);
  const max = notebook.rules?.max ?? null;
  const pass = notebook.rules?.pass ?? null;
  return {
    solved,
    total: items.length,
    points,
    max,
    pass,
    passed: pass === null ? null : points >= pass,
    done: items.length > 0 && solved === items.length,
  };
}

/** Whether the page grades an item: every quiz, and an exercise unless
 *  it is submitted with git. Item -> Bool */
export function graded(item) {
  return item.kind !== "exercise" || item.method !== "git";
}

/** The pictures the solutions save: what each one's canvas is saved as,
 *  the exercise it belongs to, and the input its solution is run on.
 *  Notebook -> [{exercise, canvas, file}] */
export function pictures(notebook) {
  return notebook.items
    .filter((item) => item.kind === "exercise" && item.solution?.picture)
    .map((item) => ({ exercise: item, ...item.solution.picture }));
}
