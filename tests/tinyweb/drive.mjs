// Runs a web24 build of a tinyweb program against the page in dom.mjs
// and delivers the events of its .events file, writing what the reader
// would have seen and heard, and what the program printed, as JSON on
// standard output. tests/test_tinyweb.py runs it twice for each program
// -- once with tinyweb_external_browser.js, which draws directly, and
// once with tinyweb_external_interpreter.js and tinyweb_page.js in its
// place -- and holds the two to one recording.
//
// Usage: node drive.mjs <directory holding program.js> <events file>

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { install } from "./dom.mjs";

const [directory, eventsFile] = process.argv.slice(2);
const page = install();
const printed = [];
console.log = (...parts) => printed.push(parts.join(" "));

// Long enough for a sample to load and a sound to start: each is a short
// chain of promises.
const settle = async () => {
  for (let i = 0; i < 10; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

const step = (title) => {
  page.record.push(title);
  for (const line of page.snapshot()) page.record.push("  | " + line);
};

const io = await import(pathToFileURL(path.join(directory, "io_external.js")).href);
try {
  await import(pathToFileURL(path.join(directory, "program.js")).href);
} catch (error) {
  if (error === null || error.pykExit === undefined) throw error;
}
io.flush();
await settle();
step("--- the top level has ended");

const events = eventsFile && fs.existsSync(eventsFile)
  ? fs.readFileSync(eventsFile, "utf8").split("\n").filter((l) => l.trim() !== "")
  : [];
for (const line of events) {
  page.record.push("> " + line);
  if (!page.deliver(line)) page.record.push("! nothing on the page for: " + line);
  io.flush();
  await settle();
  step("--- after " + line);
}
process.stdout.write(JSON.stringify({ record: page.record, stdout: printed.join("\n") }));
