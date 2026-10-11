#!/usr/bin/env python3
"""Serves the Pyking playground: a web page that runs the real compiler in
the browser, with no server-side execution. The compiler is src/
compiled to JavaScript by js_of_ocaml, so the page runs the same front
end and the same backends `pyk` does -- there is no Python and no Python
runtime in the page at all.

Nothing is built first: the page, the shared scripts in tools/webrun/,
the compiler bundle build/pyking.js and the examples in tests/ are served
from where they sit, and what the page needs to know about them is
worked out per request. See README.md for the design.

The page is served by `pyk playground` (src/web_tools.ml, which
builds the same manifest and is held to it by tests/test_notebook.py);
this file is what the website build and the headless check use.

Usage: `make check`, or directly:

    python3 playground.py check      compile every example, headless

Functions:
    examples_available() -- whether tests/ and tomllib are there to offer any.
    code_targets() -- the targets the page offers, in dropdown order.
    offered_examples(code_targets) -- the examples the page offers.
    page_manifest() -- what the page is driven by, as JSON.
    site() -- what the playground serves.
    check() -- compiles every example for every target it claims, headless.
    main(argv) -- the command-line entry point.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "webrun"))

import server  # noqa: E402  (after sys.path, which is what finds it)

import argparse  # noqa: E402
import json  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import tomllib  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
TESTS_DIR = REPO / "tests"
ASSETS = HERE / "assets"

# --- what each target means to the page -----------------------------------

# Which Ace mode highlights each target's output, and how (or whether) the
# browser can execute it. `python`, `c89`/`c23`, `java*` and `ocaml` are
# display-only: there is no Python interpreter, C compiler, JVM or OCaml
# runtime in a browser, which is a property of the target rather than a
# shortcoming of the playground. Running the *program* needs none of them
# -- that is the interpreter, and it is compiled into the page (see
# `runFromSource` in assets/playground.js).
PYKING_TARGET = "pyking"

TARGET_MODE = {
    "pyking": "text",
    "python14": "python",
    "node24": "javascript",
    "web24": "html",
    "iweb24": "html",
    "c89": "c_cpp",
    "c99": "c_cpp",
    "c23": "c_cpp",
    "java8": "java",
    "java17": "java",
    "java21": "java",
    "ocaml5.5": "ocaml",
}
TARGET_RUN = {
    # Both JavaScript targets emit the same ES module, so both run the
    # same way here: inlined into a worker as a module.
    "node24": "module",
    "web24": "module",
}
TARGET_LABEL = {
    "pyking": "Pyking (the front end's own output)",
    "python14": "Python 3.14",
    "node24": "JavaScript - node 24",
    "web24": "JavaScript - web (ES2024)",
    "iweb24": "Pyking interpreted in the browser",
    "c89": "C89",
    "c99": "C99",
    "c23": "C23",
    "java8": "Java 8",
    "java17": "Java 17",
    "java21": "Java 21",
    "ocaml5.5": "OCaml 5.5",
}



# `iweb` compiles nothing: it packages a program with the interpreter so
# a browser can run it. This page already *is* that -- it runs the
# interpreter -- so the target has nothing to offer here, and it could
# not produce its own page anyway without a copy of pyking.js to ship.
NOT_IN_THE_PAGE = {"iweb24"}



def offered_examples(code_targets, notes=False):
    """Which tests/*.pyk the page offers, and which targets each is known
    to accept, straight out of tests/test_cases.toml (README.md, "What is
    read out of the repository") -- so the playground cannot claim
    support the test suite does not. A program of several modules is
    left out entirely: the page compiles one file.

    Nothing is written, so that tests/test_playground.py can ask the same
    question without building a page. `notes` prints what was left out
    and why, which is for the build rather than for a test.
    [String] -> Bool -> [{...}]"""
    with open(TESTS_DIR / "test_cases.toml", "rb") as f:
        cases = tomllib.load(f)["cases"]
    # A program that imports is not one this page can compile: it has
    # one file and no filesystem, so there is no module for an `import`
    # to reach (see docs/modules.md). Both halves are left out -- the
    # program that imports, and the modules it imports, which are not
    # programs of their own.
    #
    # `libs` counts as importing too: a library is resolved off a search
    # path the page does not have, so a program naming one is no more
    # compilable here than a program naming a module beside it. The
    # libraries themselves need no exclusion, since they live under
    # lib/ rather than in tests/.
    with_modules = {case["file"] for case in cases
                    if case.get("modules") or case.get("libs")}
    imported = {name for case in cases for name in case.get("modules", [])}
    skipped = with_modules | imported
    known = {case["file"]: case["targets"] for case in cases
             if case["file"] not in skipped}
    declared = {t for targets in known.values() for t in targets}
    every = sorted(declared & set(code_targets))
    other = sorted(declared - set(code_targets) - NOT_IN_THE_PAGE)
    if other and notes:
        print(f"build: note: manifest also lists {', '.join(other)}, which "
              "is not a code-generation target -- ignored for the playground")
    skipped_here = sorted(declared & NOT_IN_THE_PAGE)
    if skipped_here and notes:
        print(f"build: note: {', '.join(skipped_here)} is a target of the "
              "compiler's but not one this page offers -- see README.md")

    entries = []
    for path in sorted(TESTS_DIR.glob("*.pyk")):
        if path.name in skipped:
            continue
        targets = [t for t in known.get(path.name, ["python"]) if t in code_targets]
        entries.append({
            "file": path.name,
            "name": path.stem.replace("_", " "),
            "targets": targets,
            "universal": bool(targets) and len(targets) == len(every),
        })
    missing = sorted(set(known) - {e["file"] for e in entries})
    if missing and notes:
        print(f"build: WARNING {len(missing)} manifest entries have no .pyk: "
              f"{', '.join(missing)}")
    return entries



def examples_available():
    """Whether the examples can be offered: tests/ is there, as in a
    checkout but not a package. () -> Bool"""
    return TESTS_DIR.is_dir()


def code_targets():
    """The targets the page offers, in the order the dropdown shows them.
    The compiler's own list is checked against this one by `check` and by
    tests/test_playground.py. () -> [String]"""
    return [t for t in TARGET_MODE if t not in NOT_IN_THE_PAGE]


def page_manifest():
    """What the page is driven by: the targets, how each is shown and run,
    and the examples. Worked out per request, so an edit to the manifest
    shows on the next reload. () -> Bytes"""
    targets = code_targets()
    examples = offered_examples(targets) if examples_available() else []
    return json.dumps({
        "targets": [{"name": t, "label": TARGET_LABEL[t]} for t in targets],
        "modes": {t: TARGET_MODE[t] for t in targets},
        "run": {t: TARGET_RUN[t] for t in targets if t in TARGET_RUN},
        "examples": examples,
    }, indent=2).encode() + b"\n"


def site():
    """What the playground serves: its page and scripts, the manifest,
    and each offered example from tests/. () -> server.Site"""
    files = {"/": ASSETS / "index.html", "/index.html": ASSETS / "index.html"}
    if examples_available():
        for entry in offered_examples(code_targets()):
            files["/examples/" + entry["file"]] = TESTS_DIR / entry["file"]
    return server.common_site().extended(
        mounts={"/assets/": ASSETS},
        files=files,
        answers={"/assets/playground.json": (page_manifest, "application/json")},
    )


# --- checking without a browser ------------------------------------------

CHECK_JS = r"""// Compiles every example for every target it claims, under node.
// Written by tools/playground/playground.py; nothing here is shipped.
const fs = require("fs");
const path = require("path");
// Evaluated rather than required: the bundle is a classic script, and a
// package.json saying "type": "module" above it would otherwise make
// node read it as an ES module.
// `require` is a module-local in CommonJS and js_of_ocaml's runtime
// calls it, so global code needs it put within reach.
globalThis.require = require;
(0, eval)(fs.readFileSync(process.argv[2], "utf8"));
const manifest = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const examples = process.argv[4];

// Every target the compiler has must be one the page knows how to show,
// or deliberately left out of it (NOT_IN_THE_PAGE in playground.py).
const offered = new Set(manifest.targets.map((t) => t.name));
const unknown = JSON.parse(pykTargets())
  .filter((t) => !offered.has(t) && t !== "iweb24");
if (unknown.length) {
  console.log("  FAIL target(s) " + unknown.join(", ") + " exist in the compiler "
    + "but have no entry in TARGET_MODE/TARGET_LABEL in playground.py");
  process.exit(1);
}

let checked = 0;
let failures = 0;
const expect = (label, ok, result) => {
  checked += 1;
  if (result.ok === ok) return;
  failures += 1;
  console.log("  FAIL " + label + ": " + (result.ok
    ? "compiled, but was expected to be refused" : result.text));
};

for (const entry of manifest.examples) {
  const name = entry.file;
  const source = fs.readFileSync(path.join(examples, name), "utf8");
  if (name.startsWith("fail_typecheck_")) {
    // Only the refusal is asserted (README.md, "Verifying without a
    // browser"). Every target checks the program, so any one of them
    // refuses it.
    expect(name + " -> pyking", false,
           JSON.parse(pykCompile(source, "pyking", name)));
    continue;
  }
  for (const target of entry.targets.concat(["pyking"])) {
    expect(name + " -> " + target, true,
           JSON.parse(pykCompile(source, target, name)));
  }
}
console.log(`check: ${checked - failures}/${checked} example/target pairs compiled`);
process.exit(failures ? 1 : 0);
"""



def check():
    """Compiles every example for every target it claims to support,
    through the compiler the page itself loads, under node -- catching a
    regressed backend without a browser (README.md, "Verifying without a
    browser"). () -> ()"""
    server.check_bundle("check")
    with tempfile.TemporaryDirectory(prefix="pyk-playground-") as directory:
        manifest = Path(directory) / "playground.json"
        manifest.write_bytes(page_manifest())
        script = Path(directory) / "check.cjs"
        script.write_text(CHECK_JS)
        try:
            result = subprocess.run(
                ["node", str(script), str(server.BUNDLE), str(manifest),
                 str(TESTS_DIR)],
                cwd=HERE,
            )
        except FileNotFoundError:
            raise SystemExit("check: node not found; it is what runs the compiler.")
    if result.returncode:
        raise SystemExit(1)


def main(argv=None):
    """The command-line entry point. [String]? -> ()"""
    parser = argparse.ArgumentParser(
        prog="playground.py", description="Check the Pyking web playground's examples.")
    parser.add_argument("command", choices=("check",))
    parser.parse_args(argv)
    check()


if __name__ == "__main__":
    main()
