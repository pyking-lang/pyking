// `pyk notebook --mode test FILE.md`: checks a notebook instead of serving
// it. The document is read by the page's own renderer (assets/markdown.js
// and assets/tasks.js), and every program in it is run by the page's
// own compiler worker (../webrun/assets/pyking-worker.js) under node, with
// the few browser globals it touches stood in for. So what passes here is
// what the page does. See README.md beside this file, "Test mode".
//
// What is checked is assets/checks.js's, which the page in teacher mode
// runs too.
//
// Usage: node check.js DOCUMENT BUNDLE LIB [NAME]
// Prints one `file:line: message` per problem and a summary line, and
// exits with 1 if there was a problem. NAME is what the document is
// called in them, where it is not the file itself (a .json notebook,
// which `pyk notebook` turns into Markdown first).
//
// Functions:
//   main(argv) -- checks one document.
//   boot(bundle, lib) -- the compiler worker, loaded under node.
//   execute(ask, source, name, stdin, args, events, until) -- runs one program.

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { renderMarkdown } from "./assets/markdown.js";
import { checkNotebook } from "./assets/checks.js";
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

/** Runs one program, delivering the tinyweb `events` once its top level
 *  has ended, and ending it where a compare-until limit (`until`) says:
 *  {ok, text?, stdout, stderr, exit}.
 *  Function -> String -> String -> String -> String -> String? ->
 *  {events, patterns}? -> Promise<{...}> */
export async function execute(ask, source, name, stdin, args, events = "", until = null) {
  const ran = await ask({ type: "run", source, name, stdin, args: splitArguments(args ?? ""),
    tinywebEvents: events ?? "", tinywebUntil: until });
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
  if (argv.length !== 3 && argv.length !== 4) {
    process.stderr.write("usage: node check.js DOCUMENT BUNDLE LIB [NAME]\n");
    return 2;
  }
  const [document, bundle, lib, shown] = argv;
  const file = shown ?? (path.relative(process.cwd(), document) || document);
  const doc = renderMarkdown(fs.readFileSync(document, "utf8"));
  const { notebook } = doc;

  let ask;
  try {
    ask = await boot(bundle, lib);
  } catch (err) {
    process.stderr.write(`${file}: the compiler did not start: ${err.message}\n`);
    return 1;
  }
  const run = (source, name, stdin, args, events, until) =>
    execute(ask, source, name, stdin, args, events, until);
  const { problems } = await checkNotebook(doc, run);

  for (const p of problems) process.stdout.write(`${file}:${p.line}: ${p.message}\n`);
  const items = notebook.items.length;
  process.stdout.write(`notebook test: ${file}: ${doc.cells.length} cell`
    + `${doc.cells.length === 1 ? "" : "s"}, ${items} task${items === 1 ? "" : "s"} and quiz`
    + `${items === 1 ? "" : "zes"}, ${problems.length} problem${problems.length === 1 ? "" : "s"}.\n`);
  return problems.length ? 1 : 0;
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = await main(process.argv.slice(2));
}
