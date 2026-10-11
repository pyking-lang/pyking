#!/usr/bin/env python3
"""Runs the playground's own test cases: that the compiler bundle the
page loads still works, and that every example the page offers -- the
list in src/examples.toml, which `pyk example` reads too -- is a test
case the interpreter runs, and checks in the bundle with the standard
library it imports.

This drives the bundle directly: the bundle is what `make build`
already writes to `build/pyking.js`, and the example list comes from
`tools/playground/playground.py` itself, so the suite and the page cannot
disagree about what is offered.

What it does not cover is the page: mounting, the editor, the worker
boundary and the sandboxed iframe are what
`make -C tools/playground e2e` drives in a real browser, and that needs
Playwright.

Usage: python3 tests/test_playground.py [--bundle FILE]

Functions:
    plan() -- the bundle, the targets, and every example.
    check_examples() -- what is wrong with src/examples.toml.
    run_driver(bundle, plan) -- one node process over the bundle.
    main(argv) -- the command-line entry point.
"""

import contextlib
import io
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import suite  # noqa: E402  (after sys.path, which is what finds it)

REPO = HERE.parent
PLAYGROUND = REPO / "tools" / "playground"
# What `make build` writes: the same compiler the page loads, as one
# JavaScript file.
DEFAULT_BUNDLE = REPO / "build" / "pyking.js"
# Long enough that a bundle which has gone wrong is reported rather than
# hanging. Compiling every example takes a few seconds.
STEP_TIMEOUT = 600
# Plain `node`, with no flags, which is also how
# tools/playground/playground.py runs its own check. Elsewhere the suite
# passes `--no-experimental-detect-module` so that node cannot guess a
# generated `.js` into an ES module, and it probes for that flag first
# because an older node rejects it outright. Neither applies here: the
# driver below is a `.cjs` file, which is CommonJS by its extension, and
# the bundle is `eval`ed from a string rather than loaded as a module, so
# there is no guess for node to make.
NODE = ["node"]

# A program small enough to say nothing about any backend, and enough to
# prove the whole path works: it binds, calls and prints.
SMOKE = """def twice(n:Int) -> Int:
    return n * 2


print(twice(21))
"""
SMOKE_OUTPUT = ["42"]

DRIVER = r"""// Drives the playground's compiler bundle under node.
const fs = require("fs");
// Evaluated rather than required: the bundle is a classic script, and
// `require` is a module-local in CommonJS that js_of_ocaml's runtime
// calls, so global code needs it put within reach. This is how
// tools/playground/playground.py loads it too.
globalThis.require = require;
(0, eval)(fs.readFileSync(process.argv[2], "utf8"));
const plan = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));

const failures = [];
const check = (label, ok, detail) => {
  if (!ok) failures.push(label + ": " + detail);
};

// 1. The entry points the page calls. stub.js registers them on the
//    global object; a rename in src/web/pyking_web.ml that the page was
//    not told about looks like this.
for (const name of ["pykCompile", "pykRun", "pykRunProgram", "pykAnalyze",
                    "pykTargets", "pykFormatHelper", "pykKeywords",
                    "pykBuiltins"]) {
  check("entry point " + name, typeof globalThis[name] === "function",
        "not registered on the global object");
}
if (failures.length) {
  console.log(JSON.stringify({ pairs: 0, failures }));
  process.exit(0);
}

// 2. What the page reads out of the compiler rather than keeping its own
//    copy of: the targets, the keywords its editor highlights, the
//    builtins it completes, and the value formatter its worker uses.
const targets = JSON.parse(pykTargets());
check("pykTargets", Array.isArray(targets) && targets.length > 0,
      JSON.stringify(targets));
const unknown = targets.filter(
  (t) => !plan.targets.includes(t) && !plan.leftOut.includes(t));
check("every target known to the playground", unknown.length === 0,
      unknown.join(", ") + " has no entry in playground.py's TARGET_MODE");
const keywords = JSON.parse(pykKeywords());
check("pykKeywords", Array.isArray(keywords) && keywords.includes("def"),
      JSON.stringify(keywords).slice(0, 120));
const builtins = JSON.parse(pykBuiltins());
check("pykBuiltins", Array.isArray(builtins) && builtins.includes("print"),
      JSON.stringify(builtins));
const helper = pykFormatHelper();
check("pykFormatHelper", typeof helper === "string" && helper.length > 0,
      "answered nothing");

// 3. One small program compiled for every target the page offers, and
//    run with the interpreter -- the two things a visitor does first.
for (const target of plan.targets) {
  const result = JSON.parse(pykCompile(plan.smoke, target, "smoke.pyk"));
  check("compile the smoke program -> " + target, result.ok === true,
        result.text || "refused with no message");
}
const printed = [];
globalThis.pykOnPrint = (line) => printed.push(line);
// One string in: the first line is the file name errors are reported
// against, the rest is the program (see src/web/pyking_web.ml).
const ran = JSON.parse(pykRun("smoke.pyk\n" + plan.smoke));
check("run the smoke program", ran.ok === true,
      ran.text || "refused with no message");
check("the smoke program's output",
      JSON.stringify(printed.map((l) => l.replace(/\n$/, ""))) ===
        JSON.stringify(plan.smokeOutput),
      JSON.stringify(printed));

// 3b. In a browser `print` writes through the `io` library's own
//     implementation, so a `web` program ships it -- read, as the page's
//     worker reads it, from the library beside the tools.
globalThis.pykLibraryFile = (path) =>
  fs.readFileSync(plan.lib + "/" + path, "utf8");
const page = JSON.parse(pykCompile(plan.smoke, "web24", "smoke.pyk"));
check("a web program ships io_external.js",
      page.ok && typeof page.files?.["io_external.js"] === "string"
        && page.files["io_external.js"].includes("export function write_line"),
      JSON.stringify(Object.keys(page.files ?? {})));
delete globalThis.pykLibraryFile;

// 4. Every example the page offers checks as the page's Run checks it,
//    with the modules it imports read from lib/ as the worker reads them.
//    What it prints is the test suite's business: it is a test case.
globalThis.pykFetchSource = (name) => {
  const found = /^([A-Za-z_][A-Za-z0-9_]*?)(_external)?\.pyk$/.exec(name);
  try {
    return found ? fs.readFileSync(plan.lib + "/" + found[1] + "/" + name, "utf8") : null;
  } catch (error) {
    return null;
  }
};
let pairs = 0;
for (const example of plan.examples) {
  pairs += 1;
  globalThis.pykSources = { [example.file]: fs.readFileSync(example.path, "utf8") };
  const result = JSON.parse(pykAnalyze(example.file));
  check(example.file + " checks in the page", result.ok === true,
        result.text || "refused with no message");
}
console.log(JSON.stringify({ pairs, failures }));
"""


def plan():
    """The targets the page offers and every example it will offer, asked
    of the playground itself so that the two cannot disagree.
    () -> {...}"""
    sys.path.insert(0, str(PLAYGROUND))
    import playground

    with contextlib.redirect_stdout(io.StringIO()):
        targets = playground.code_targets()
        sources = playground.example_sources()
    return {
        "targets": targets,
        "leftOut": sorted(playground.NOT_IN_THE_PAGE),
        "smoke": SMOKE,
        "smokeOutput": SMOKE_OUTPUT,
        "lib": str(REPO / "lib"),
        "examples": [
            {"file": name, "path": str(path)} for name, path in sources.items()
        ],
    }


def check_examples():
    """What is wrong with src/examples.toml: an example whose source is
    missing or is not a test case the interpreter runs, a name given
    twice or not ending in .pyk, and a line of `pyk example` longer than
    80 columns. () -> [String]"""
    import tomllib

    with open(REPO / "src" / "examples.toml", "rb") as f:
        listed = tomllib.load(f).get("examples", [])
    with open(HERE / "test_cases.toml", "rb") as f:
        cases = {case["file"]: case for case in tomllib.load(f)["cases"]}
    problems = [] if listed else ["src/examples.toml lists no example"]
    width = max([len("File name")] + [len(e.get("name", "")) for e in listed]) + 2
    names = [e.get("name", "") for e in listed]
    for example in listed:
        name, source = example.get("name", ""), example.get("source", "")
        if not (source and name and example.get("description")):
            problems.append(f"{name or source or '?'}: needs source, name and description")
            continue
        if not (REPO / source).is_file():
            problems.append(f"{name}: no file {source}")
        case = cases.get(Path(source).name) if Path(source).parent == Path("tests") else None
        if case is None or "interpret" not in case["targets"]:
            problems.append(f"{name}: {source} is not a case of test_cases.toml run by interpret")
        if not name.endswith(".pyk") or "/" in name:
            problems.append(f"{name}: a name is a file name ending in .pyk")
        if names.count(name) > 1:
            problems.append(f"{name}: named twice")
        if width + len(example["description"]) > 80:
            problems.append(f"{name}: its line of `pyk example` is longer than 80 columns")
    return problems


def run_driver(bundle, prepared):
    """One node process over the bundle. Answers (pairs, failures), or
    (None, [message]) where node could not be run at all.
    Path -> {...} -> (Int?, [String])"""
    directory = tempfile.mkdtemp(prefix="pyk-playground-")
    try:
        script = Path(directory) / "driver.cjs"
        script.write_text(DRIVER)
        prepared_path = Path(directory) / "plan.json"
        prepared_path.write_text(json.dumps(prepared))
        try:
            result = subprocess.run(
                NODE + [str(script), str(bundle), str(prepared_path)],
                capture_output=True, text=True, timeout=STEP_TIMEOUT,
            )
        except FileNotFoundError:
            return None, ["node not found; it is what runs the compiler bundle"]
        except subprocess.TimeoutExpired:
            return None, [f"timed out after {STEP_TIMEOUT} seconds"]
        if result.returncode != 0 or not result.stdout.strip():
            detail = (result.stderr or result.stdout or "no output").strip()
            return None, [f"the driver did not finish: {detail.splitlines()[-1]}"]
        answer = json.loads(result.stdout.strip().splitlines()[-1])
        return answer["pairs"], answer["failures"]
    finally:
        import shutil

        shutil.rmtree(directory, ignore_errors=True)


def parse_args(argv):
    """`--bundle FILE` or the default. [String] -> Path"""
    if argv[:1] == ["--bundle"]:
        if len(argv) < 2:
            print("usage: test_playground.py [--bundle FILE]", file=sys.stderr)
            sys.exit(2)
        return Path(argv[1])
    if argv:
        print("usage: test_playground.py [--bundle FILE]", file=sys.stderr)
        sys.exit(2)
    return DEFAULT_BUNDLE


def main(argv):
    """Runs the checks and reports them. [String] -> Int"""
    bundle = parse_args(argv)
    if not bundle.exists():
        print(f"playground: FAILED -- no bundle at {bundle}")
        print("  `make build` writes it; it is the compiler the page loads")
        suite.footer("playground", 0, 1, "no bundle to drive")
        return 1
    prepared = plan()
    pairs, failures = run_driver(bundle, prepared)
    listed = check_examples()
    for problem in listed:
        print(f"playground: FAILED src/examples.toml: {problem}")
    for failure in failures:
        print(f"playground: FAILED {failure}")
    if pairs is None:
        suite.footer("playground", 0, 1, "the bundle could not be driven")
        return 1
    checks = len(prepared["targets"]) + 11
    print(f"playground: the bundle's {len(prepared['targets'])} targets, its "
          "entry points and the smoke program OK.")
    print(f"playground: {pairs} examples checked in the page.")
    failed = len(failures) + len(listed)
    suite.footer(
        "playground", checks + pairs - len(failures) - (1 if listed else 0), failed,
        f"{len(prepared['examples'])} examples, "
        f"{len(prepared['targets'])} targets")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
