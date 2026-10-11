// `pyk notebook --mode test FILE.md`: checks a notebook instead of serving
// it. The document is read by the page's own renderer (assets/markdown.js
// and assets/exercises.js), and every program in it is run by the page's
// own compiler worker (../webrun/assets/pyking-worker.js) under node, with
// the few browser globals it touches stood in for. So what passes here is
// what the page does. See README.md beside this file, "Test mode".
//
// What is checked: the problems exercises.js finds in the blocks (order,
// pairing, quiz and answer counts, points against the rules' max); that
// every cell runs, and every `error` cell is refused; that each
// exercise's starting code runs; that each solution runs on every input
// it is tested with and prints what any stdout or stderr block after it
// says; and the same of an ordinary cell's stdout and stderr blocks.
//
// Usage: node check.js DOCUMENT BUNDLE LIB
// Prints one `file:line: message` per problem and a summary line, and
// exits with 1 if there was a problem.
//
// Functions:
//   main(argv) -- checks one document.
//   boot(bundle, lib) -- the compiler worker, loaded under node.
//   execute(ask, source, name, stdin, args) -- runs one program.

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { renderMarkdown } from "./assets/markdown.js";
import { sameOutput } from "./assets/exercises.js";
import { splitArguments } from "../webrun/assets/web.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WORKER = path.join(HERE, "..", "webrun", "assets", "pyking-worker.js");

/** Loads the compiler worker into this process, as a page loads it into
 *  a worker, and answers the function a request is made with.
 *  String -> String -> Promise<(message) -> Promise<reply>> */
export async function boot(bundle, lib) {
  globalThis.self = globalThis;
  globalThis.require = createRequire(import.meta.url);
  const replies = [];
  self.postMessage = (message) => replies.push(message);
  self.importScripts = () => (0, eval)(fs.readFileSync(bundle, "utf8"));
  const libURL = pathToFileURL(lib).href + "/";
  globalThis.XMLHttpRequest = class {
    open(method, url) { this.url = url; }
    send() {
      if (this.url.startsWith(libURL)) {
        const file = fileURLToPath(this.url);
        this.status = fs.existsSync(file) ? 200 : 404;
        this.responseText = this.status === 200 ? fs.readFileSync(file, "utf8") : "";
        return;
      }
      this.status = 200;
      this.responseText = JSON.stringify({ bundle: "pyking.js", stamp: "check" });
    }
  };
  const log = console.log;
  (0, eval)(fs.readFileSync(WORKER, "utf8"));
  // The worker makes the console its output pane; this script's own
  // report goes through the console as it was.
  console.log = log;
  let next = 1;
  const ask = async (message) => {
    const id = next++;
    replies.length = 0;
    self.onmessage({ data: { id, ...message } });
    // A run that imports a JavaScript module answers once that import is
    // done; everything else answers before `onmessage` returns.
    for (let spins = 0; !replies.some((r) => r.id === id) && spins < 10000; spins++) {
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    const text = (type) => replies.filter((r) => r.type === type).map((r) => r.text).join("");
    const exit = replies.find((r) => r.type === "exit");
    return {
      answer: replies.find((r) => r.id === id),
      stdout: text("stdout"),
      stderr: text("debug"),
      failure: text("failure"),
      exit: exit ? exit.code : null,
    };
  };
  const booted = await ask({ type: "init", pykingURL: "http://check/pyking/", libURL });
  if (booted.answer?.type !== "result") {
    throw new Error(booted.answer?.message ?? "the compiler did not start");
  }
  return ask;
}

/** Runs one program: {ok, text?, stdout, stderr, exit}.
 *  Function -> String -> String -> String -> String -> Promise<{...}> */
export async function execute(ask, source, name, stdin, args) {
  const ran = await ask({ type: "run", source, name, stdin, args: splitArguments(args ?? "") });
  const value = ran.answer?.value;
  if (ran.answer?.type !== "result") {
    return { ok: false, text: ran.answer?.message ?? "no answer", stdout: ran.stdout, stderr: ran.stderr };
  }
  if (!value.ok || ran.failure) {
    return { ok: false, text: (value.text ?? ran.failure).trimEnd(), stdout: ran.stdout, stderr: ran.stderr };
  }
  return { ok: true, stdout: ran.stdout, stderr: ran.stderr, exit: value.exit ?? ran.exit ?? 0 };
}

/** Checks one document. [String] -> Promise<Int> */
export async function main(argv) {
  if (argv.length !== 3) {
    process.stderr.write("usage: node check.js DOCUMENT BUNDLE LIB\n");
    return 2;
  }
  const [document, bundle, lib] = argv;
  const file = path.relative(process.cwd(), document) || document;
  const problems = [];
  let checks = 0;
  const report = (line, message) => problems.push({ line, message });
  const check = (ok, line, message) => {
    checks += 1;
    if (!ok) report(line, message);
  };

  const doc = renderMarkdown(fs.readFileSync(document, "utf8"));
  const { notebook } = doc;
  checks += 1;
  for (const p of notebook.problems) report(p.line, p.message);

  let ask;
  try {
    ask = await boot(bundle, lib);
  } catch (err) {
    process.stderr.write(`${file}: the compiler did not start: ${err.message}\n`);
    return 1;
  }
  const lineOf = (cell) => doc.parts[cell.part]?.line ?? 0;
  const run = (source, name, stdin, args) => execute(ask, source, name, stdin, args);

  // Every cell runs, or is refused where it says it should be.
  const roles = new Map();
  for (const item of notebook.items) {
    if (item.kind !== "exercise") continue;
    if (item.cell !== null) roles.set(item.cell, item);
    if (item.solution) roles.set(item.solution.cell, item);
  }
  for (const cell of doc.cells) {
    const name = `cell-${cell.index + 1}.pyk`;
    const item = roles.get(cell.index);
    const stdin = item ? item.stdin : cell.stdin ?? "";
    const args = item ? item.args : cell.args ?? "";
    const result = await run(cell.source, name, stdin, args);
    const what = cell.attrs.exercise ? "the exercise's starting code"
      : cell.attrs.solution ? "the solution" : "this cell";
    if (cell.attrs.error) {
      check(!result.ok, lineOf(cell), "this cell is marked error, but it runs");
    } else {
      check(result.ok, lineOf(cell), `${what} does not run:\n  ${(result.text ?? "").replace(/\n/g, "\n  ")}`);
    }
  }

  // Each test of an exercise with a solution, and each example under a
  // cell: what runs is what the block after it says.
  const compare = async (source, name, line, test, stdin, args) => {
    const result = await run(source, name, stdin, args);
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
    if (item.kind !== "exercise" || !item.solution) continue;
    const source = doc.cells[item.solution.cell].source;
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
  for (const p of problems) process.stdout.write(`${file}:${p.line}: ${p.message}\n`);
  const items = notebook.items.length;
  process.stdout.write(`notebook test: ${file}: ${doc.cells.length} cell`
    + `${doc.cells.length === 1 ? "" : "s"}, ${items} exercise${items === 1 ? "" : "s"} and quiz`
    + `${items === 1 ? "" : "zes"}, ${problems.length} problem${problems.length === 1 ? "" : "s"}.\n`);
  return problems.length ? 1 : 0;
}

function indent(text) {
  const body = text.replace(/\n$/, "");
  return body === "" ? "    (nothing)" : body.split("\n").map((l) => "    " + l).join("\n");
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main(process.argv.slice(2));
}
