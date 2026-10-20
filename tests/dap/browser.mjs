// Runs a program through the debugger in the browser bundle -- the
// pykDebug* entries the playground's worker calls -- stopping at the
// breakpoints given, and writes every stop as tests/test_dap.py's
// `native_stops` records one from `pyk dap`: the reason, and each frame's
// name and line with its scopes' variables.
//
// Usage: node browser.mjs <share/pyking.js> <lib> <program> <[lines]>

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

const [bundle, lib, program, lines] = process.argv.slice(2);
globalThis.require = createRequire(import.meta.url);
globalThis.pykOnPrint = () => {};
globalThis.pykOnDebug = () => {};
globalThis.pykFetchSource = (name) => {
  const found = /^([A-Za-z_][A-Za-z0-9_]*?)(_external)?\.pyk$/.exec(path.basename(name));
  if (!found) return null;
  const file = path.join(lib, found[1], path.basename(name));
  return fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
};

(0, eval)(fs.readFileSync(bundle, "utf8"));

const name = path.basename(program);
globalThis.pykSources = { [name]: fs.readFileSync(program, "utf8") };
const breakpoints = JSON.parse(lines).map((line) => ({ line }));
const started = JSON.parse(globalThis.pykDebugStart(JSON.stringify({
  main: name, files: [name], breakpoints: [{ file: name, breakpoints }] })));
if (!started.ok) {
  process.stderr.write(JSON.stringify(started));
  process.exit(1);
}
const stops = [];
for (let k = 0; k < 10000 && stops.length < 50; k++) {
  const answer = JSON.parse(globalThis.pykDebugRun("5000"));
  const stopped = answer.events.find((e) => e.kind === "stopped");
  if (answer.state === "stopped" && stopped) {
    const stop = { reason: stopped.reason, frames: [] };
    for (const frame of JSON.parse(globalThis.pykDebugFrames())) {
      const entry = { name: frame.name, line: frame.span.row1, scopes: {} };
      for (const scope of JSON.parse(globalThis.pykDebugScopes(String(frame.id)))) {
        entry.scopes[scope.name] = JSON.parse(globalThis.pykDebugVariables(String(scope.ref)))
          .map((v) => [v.name, v.value, v.type]);
      }
      stop.frames.push(entry);
    }
    stops.push(stop);
    globalThis.pykDebugCommand("continue");
  } else if (answer.state !== "running") {
    break;
  }
}
process.stdout.write(JSON.stringify(stops));
