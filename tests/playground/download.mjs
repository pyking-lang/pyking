// The playground's Download, driven under node: each case is compiled by
// the bundle as the page compiles it, packed by
// tools/playground/assets/download.js with the standard library read from
// lib/, and the zip is read back by Python's zipfile. A case with `run`
// is then unpacked and built and run with its own Makefile, `make run`,
// and must print its `.out`; a case with `holds` must hold those files.
//
//   node download.mjs BUNDLE LIB CASES.json
//
// CASES.json is [{program, target, run: bool, holds: [file], events}]
// with paths from the repository's root. The answer, one JSON line on
// stdout, is {checks, failures: [String]}.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..", "..");
const { packFiles, zip } = await import(path.join(repo, "tools", "playground", "assets", "download.js"));

const [bundle, lib, listed] = process.argv.slice(2);
const cases = JSON.parse(fs.readFileSync(listed, "utf8"));

globalThis.self = globalThis;
const read = (p) => { try { return fs.readFileSync(p); } catch { return null; } };
const text = (p) => { const b = read(p); return b === null ? null : b.toString("utf8"); };
globalThis.pykLibraryFile = (p) => text(path.join(lib, p));
globalThis.pykFetchSource = (name) => {
  const m = /^([A-Za-z_][A-Za-z0-9_]*?)(_external)?\.pyk$/.exec(name);
  return m ? text(path.join(lib, m[1], name)) : null;
};
createRequire(import.meta.url)(path.resolve(bundle));

const failures = [];
let checks = 0;
for (const c of cases) {
  const where = `${c.program} on ${c.target}`;
  const source = fs.readFileSync(path.join(repo, c.program), "utf8");
  globalThis.pykSources = { "playground.pyk": source };
  const compiled = JSON.parse(globalThis.pykCompile(source, c.target, "playground.pyk"));
  if (!compiled.ok) {
    failures.push(`${where}: the page refused it: ${compiled.text}`);
    continue;
  }
  const analysis = JSON.parse(globalThis.pykAnalyze("playground.pyk"));
  const entries = await packFiles({
    target: c.target, files: compiled.files, externals: analysis.ok ? analysis.externals : [],
    source, name: "playground.pyk",
    get: async (p) => { const b = read(path.join(lib, p)); return b === null ? null : new Uint8Array(b); },
    bundle: async () => new Uint8Array(fs.readFileSync(bundle)),
  });
  const folder = `playground-${c.target}`;
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "pyk-download-"));
  try {
    const archive = path.join(work, folder + ".zip");
    fs.writeFileSync(archive, zip(entries.map((e) => ({ name: `${folder}/${e.name}`, data: e.data }))));
    const check = spawnSync("python3", ["-c",
      "import sys, zipfile\nz = zipfile.ZipFile(sys.argv[1])\nbad = z.testzip()\n"
      + "assert bad is None, bad\nz.extractall(sys.argv[2])\nprint(len(z.namelist()))",
      archive, work], { encoding: "utf8" });
    if (check.status !== 0) {
      failures.push(`${where}: zipfile refused the download: ${check.stderr.trim().split("\n").pop()}`);
      continue;
    }
    const unpacked = path.join(work, folder);
    const missing = (c.holds ?? []).filter((f) => !fs.existsSync(path.join(unpacked, f)));
    if (missing.length) {
      failures.push(`${where}: the download has no ${missing.join(", ")}`);
      continue;
    }
    if (c.run) {
      const environment = { ...process.env };
      if (c.events) {
        environment.PYKING_TINYWEB_LOG = path.join(work, "page.log");
        environment.PYKING_TINYWEB_EVENTS = path.join(repo, c.events);
      }
      const ran = spawnSync("make", ["--no-print-directory", "-s", "run"],
        { cwd: unpacked, env: environment, encoding: "utf8", input: "", timeout: 300000 });
      const expected = text(path.join(repo, c.program.replace(/\.pyk$/, ".out"))) ?? "";
      if (ran.status !== 0) {
        failures.push(`${where}: make run ended with status ${ran.status}: `
          + `${(ran.stderr || ran.stdout || "").trim().split("\n").slice(-3).join(" / ")}`);
        continue;
      }
      if (ran.stdout !== expected) {
        failures.push(`${where}: make run printed ${JSON.stringify(ran.stdout.slice(0, 200))}, `
          + `not its .out`);
        continue;
      }
      const clean = spawnSync("make", ["--no-print-directory", "-s", "clean"], { cwd: unpacked, encoding: "utf8" });
      if (clean.status !== 0) {
        failures.push(`${where}: make clean ended with status ${clean.status}`);
        continue;
      }
    }
    checks += 1;
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}
console.log(JSON.stringify({ checks, failures }));
