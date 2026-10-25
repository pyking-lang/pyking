// What test mode checks in a notebook, shared by `pyk notebook --mode
// test` (../check.js, under node) and the page in teacher mode
// (notebook.js), so the two cannot disagree. Runs nothing itself: the
// caller hands in how a program is run. See tools/notebook/README.md,
// "Test mode".
//
// What is checked: the problems tasks.js finds in the blocks; that
// every cell runs, and every `error` cell is refused; that each
// task's starting code runs; that each solution runs on every input
// it is tested with and prints what any stdout or stderr block after it
// says, and keeps to its task's max_calls; and the same of an ordinary
// cell's stdout and stderr blocks.
//
// Data structures:
//   Run -- (source, name, stdin, args, events) -> Promise<{ok, text?,
//     stdout, stderr}>: runs one program, `args` as the text a header
//     writes, `events` the tinyweb events delivered after its top level.
//   Problem -- {line, message}, as tasks.js reports one.
//
// Functions:
//   checkNotebook(doc, run) -- every problem in a rendered document.

import { sameOutput, overCalls } from "./tasks.js";

/** Every problem in a document renderMarkdown answered: the blocks' own,
 *  then what running its programs finds, sorted by line.
 *  Doc -> Run -> Promise<{checks, problems}> */
export async function checkNotebook(doc, run) {
  const { notebook } = doc;
  const problems = [];
  let checks = 1;
  const check = (ok, line, message) => {
    checks += 1;
    if (!ok) problems.push({ line, message });
  };
  problems.push(...notebook.problems);
  const lineOf = (cell) => doc.parts[cell.part]?.line ?? 0;

  // Every cell runs, or is refused where it says it should be.
  const roles = new Map();
  for (const item of notebook.items) {
    if (item.kind !== "task") continue;
    if (item.cell !== null) roles.set(item.cell, item);
    if (item.solution) roles.set(item.solution.cell, item);
  }
  for (const cell of doc.cells) {
    const name = `cell-${cell.index + 1}.pyk`;
    const item = roles.get(cell.index);
    // A cell's own input first: a solution may name the one it is shown with.
    const stdin = cell.stdin ?? (item ? item.stdin : "");
    const args = cell.args ?? (item ? item.args : "");
    const result = await run(cell.source, name, stdin, args);
    const what = item?.cell === cell.index ? `the ${item.practice ? "practice" : "task"}'s starting code`
      : cell.attrs.solution ? "the solution" : "this cell";
    if (cell.attrs.error) {
      check(!result.ok, lineOf(cell), "this cell is marked error, but it runs");
    } else {
      check(result.ok, lineOf(cell), `${what} does not run:\n  ${(result.text ?? "").replace(/\n/g, "\n  ")}`);
    }
  }

  // Each test of a task with a solution, and each example under a
  // cell: what runs is what the block after it says.
  const compare = async (source, name, line, test, stdin, args) => {
    const result = await run(source, name, stdin, args, test.events ?? "");
    if (!result.ok) {
      check(false, line, `the program does not run on this input:\n  ${result.text}`);
      return;
    }
    if (test.output) {
      check(sameOutput(result.stdout, test.output.text), test.output.line,
        `the program prints\n${indent(result.stdout)}\nand this stdout block says\n${indent(test.output.text)}`);
    }
    if (test.error) {
      check(sameOutput(result.stderr, test.error.text), test.error.line,
        `the program writes to stderr\n${indent(result.stderr)}\nand this stderr block says\n${indent(test.error.text)}`);
    }
  };
  for (const item of notebook.items) {
    if (item.kind !== "task" || !item.solution) continue;
    const source = doc.cells[item.solution.cell].source;
    const over = overCalls(source, item.maxCalls);
    check(over === null, item.solution.line, over === null ? ""
      : `the solution uses ${over.name} ${over.count} times, and max_calls allows ${over.max}`);
    for (const test of item.tests) {
      await compare(source, `${item.id}-solution.pyk`, test.line, test,
        test.stdin ?? item.stdin, test.args ?? item.args);
    }
  }
  for (const example of notebook.examples) {
    if (example.cell === null) continue;
    const cell = doc.cells[example.cell];
    for (const test of example.tests) {
      await compare(cell.source, `cell-${cell.index + 1}.pyk`, test.line, test,
        test.stdin ?? cell.stdin ?? "", test.args ?? cell.args ?? "");
    }
  }

  problems.sort((a, b) => a.line - b.line);
  return { checks, problems };
}

function indent(text) {
  const body = text.replace(/\n$/, "");
  return body === "" ? "    (nothing)" : body.split("\n").map((l) => "    " + l).join("\n");
}
