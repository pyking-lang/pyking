// The JavaScript implementation of the Pyking module declared in
// fs.external.pyk. An ES module, like every external implementation the
// JavaScript targets import. Node only: a browser has no filesystem,
// which is why `fs` offers no web24/iweb24 implementation and the
// library claims neither target.
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";

export function read_text(filename) {
  return readFileSync(filename, "utf8");
}

export function write_text(filename, text) {
  writeFileSync(filename, text, "utf8");
}

export function exists(filename) {
  return existsSync(filename) && statSync(filename).isFile();
}
