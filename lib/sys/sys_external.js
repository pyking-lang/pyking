// The JavaScript implementation of the names declared in
// sys.external.pyk. Node only: a browser has neither arguments nor an
// environment, which is why `sys` claims no web24/iweb24.
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
