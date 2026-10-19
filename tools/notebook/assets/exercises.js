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
//   Exercise -- {kind: "exercise", id, number, key, line, part, cell,
//     attempts, points, penalty, stdin, args, solution, tests}.
//   Solution -- {cell, line, available}.
//   Test -- {line, stdin, args, input, output, error}: one input and what
//     it should print; `input`, `output` and `error` are the blocks.
//   Quiz -- {kind: "quiz", id, number, key, line, part, answerPart,
//     question, alternatives, multiple, onePointCorrect, answers, attempts,
//     points, penalty, available}.
//   Example -- {cell, line, tests}: input and output under an ordinary cell.
//   Problem -- {line, message}.
//
// Functions:
//   structure(parts, cells) -- what the blocks make, and what is wrong.
//   normalizeOutput(text) -- output as it is compared.
//   sameOutput(a, b) -- whether two outputs count as the same.
//   checkQuiz(quiz, chosen) -- what a quiz answer got right and wrong.
//   rightAnswers(quiz) -- how many of a quiz's alternatives are right.
//   quizAward(quiz, chosen, failures) -- the points a check that ends a
//     quiz gives.
//   award(item, failures) -- the points an item solved after failures gives.
//   summary(notebook, states) -- solved, points and passing, for the page.

/** The attributes each kind of block may carry. */
const KNOWN = {
  rules: ["max", "pass"],
  exercise: ["exercise", "attempts", "points", "penalty", "stdin", "args", "readonly"],
  solution: ["solution", "available", "readonly"],
  // `playground` is the website's (tools/site/src/remark-pyking-cells.mjs).
  pyking: ["norun", "readonly", "error", "stdin", "args", "playground"],
  stdin: ["args", "visible"],
  args: [],
  stdout: ["visible"],
  stderr: ["visible"],
  quiz: ["attempts", "points", "penalty", "available", "one_point_correct"],
  answer: [],
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
              available: flag(part, "available", true, problem),
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
            } else {
              owner.tests.push(newTest(part));
            }
          } else if (part.kind === "stdin" && owner?.kind === "cell"
                     && (next?.kind === "stdout" || next?.kind === "stderr")) {
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
        case "stdout":
        case "stderr": {
          if (owner?.kind === "exercise" || owner?.kind === "cell") {
            const last = owner.tests[owner.tests.length - 1];
            const slot = part.kind === "stdout" ? "output" : "error";
            if (last && !last[slot]) {
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
  return {
    kind: "exercise",
    id: `exercise-${number_}`,
    number: number_,
    key: hash(part.text),
    line: part.line,
    part: part.index,
    cell: part.cell,
    attempts: count(part, "attempts", problem),
    points: number(part, "points", null, problem),
    penalty: number(part, "penalty", 0, problem) ?? 0,
    stdin,
    args: typeof part.attrs.args === "string" ? part.attrs.args : "",
    solution: null,
    tests: [],
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

function newTest(part, line = part.line) {
  return {
    line,
    input: part,
    stdin: part ? inputLines(part.text) : null,
    args: part ? (typeof part.attrs.args === "string" ? part.attrs.args : "") : null,
    output: null,
    error: null,
  };
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
  const sum = items.reduce((total, item) => total + (item.points ?? 0), 0);
  if (rules.max !== null && sum !== rules.max) {
    problems.push({ line: rules.line,
      message: `max is ${rules.max}, but the exercises and quizzes give ${sum} point${sum === 1 ? "" : "s"}` });
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

/** Whether two outputs count as the same. String -> String -> Bool */
export function sameOutput(a, b) {
  return normalizeOutput(a) === normalizeOutput(b);
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
  const items = notebook.items;
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
