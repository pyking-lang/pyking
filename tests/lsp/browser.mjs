// Runs a session of the language server through the browser bundle, the
// server the playground's worker talks to: tests/test_lsp.py hands it the
// messages of a tests/lsp/<name>.lsp script and compares what comes back
// with what `pyk lsp` answered to the same messages.
//
// Usage: node browser.mjs <share/pyking.js> <lib> <directory> < steps.json
// `steps.json` is [{send: [text...], idle: bool}], and what is written is
// [[messages answered...] per step], each message as parsed JSON.
//
// Files are read the way the playground's worker reads them: a document
// the editor opened is in the messages; any other name is a file under
// <directory> (absolute names are under /), or else a module of the
// standard library under <lib>, by its own name.

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const [bundle, lib, directory] = process.argv.slice(2);
globalThis.require = createRequire(import.meta.url);

globalThis.pykFetchSource = (name) => {
  for (const candidate of [path.join("/", name), path.join(directory, name)]) {
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
      return fs.readFileSync(candidate, "utf8");
    }
  }
  const found = /^([A-Za-z_][A-Za-z0-9_]*?)(_external)?\.pyk$/.exec(path.basename(name));
  if (!found) return null;
  const file = path.join(lib, found[1], path.basename(name));
  return fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
};

(0, eval)(fs.readFileSync(bundle, "utf8"));

const steps = JSON.parse(fs.readFileSync(0, "utf8"));
const answers = steps.map((step) => {
  const out = [];
  for (const text of step.send) out.push(...JSON.parse(globalThis.pykLsp(text)));
  if (step.idle) out.push(...JSON.parse(globalThis.pykLspIdle()));
  return out;
});
process.stdout.write(JSON.stringify(answers));
