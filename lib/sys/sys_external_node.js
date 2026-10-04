// The JavaScript implementation of the names declared in
// sys_external.pyk, for node24. A browser has neither arguments nor an
// environment: sys_external_browser.js beside this one is what web24
// and iweb24 use, and says so.
//
// `process.argv` is [node, script, ...arguments], so the program is
// argv[1] and its own arguments start at 2.
//
// A Pyking list and a Pyking tuple are both arrays here, and the value
// formatter walks values rather than reading types, so a list says it
// is one with `pykList` (docs/modules.md, "What may cross the
// boundary").
import { basename, dirname, resolve } from "node:path";

const variables = Object.entries(process.env).map(([name, value]) => [
  name,
  value ?? "",
]);

function asList(items) {
  items.pykList = true;
  return items;
}

export function args() {
  return asList(process.argv.slice(2));
}

export function env() {
  return asList(variables.map((pair) => pair.slice()));
}

export function prog_name() {
  return basename(process.argv[1]);
}

export function prog_path() {
  return dirname(resolve(process.argv[1]));
}

// Leaving by exception rather than process.exit: process.exit may drop
// what is still being written to a pipe, where letting node end on its
// own writes it all out first. The handler is installed by importing
// this module, so only a program that uses `sys` has it; any other
// uncaught error is reported as node would, with status 1.
process.on("uncaughtException", (error) => {
  if (error && error.pykExit !== undefined) {
    process.exitCode = error.pykExit;
    return;
  }
  console.error(error && error.stack ? error.stack : error);
  process.exitCode = 1;
});

export function exit(code) {
  const stop = new Error(`exit ${code}`);
  stop.pykExit = code;
  throw stop;
}
