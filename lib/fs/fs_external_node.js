// The JavaScript implementation of the Pyking module declared in
// fs_external.pyk, for node. An ES module, like every external
// implementation the JavaScript targets import. A browser has no
// filesystem: fs_external_browser.js beside this one is what web and
// iweb use, and says so.
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
