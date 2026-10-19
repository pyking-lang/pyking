#!/usr/bin/env python3
"""Serves the Pyking playground: a web page that runs the real compiler in
the browser, with no server-side execution. The compiler is src/
compiled to JavaScript by js_of_ocaml, so the page runs the same front
end and the same backends `pyk` does -- there is no Python and no Python
runtime in the page at all.

Nothing is built first: the page, the shared scripts in tools/webrun/,
the compiler bundle share/pyking.js and the examples src/examples.toml
lists are served from where they sit, and what the page needs to know about them is
worked out per request. See README.md for the design.

The page is served by `pyk playground` (src/web_tools.ml, which
builds the same manifest and is held to it by tests/test_notebook.py);
this file is what the website build and the headless check use.

Usage: `make check`, or directly:

    python3 playground.py check      check the targets and examples, headless

Functions:
    code_targets() -- the targets the page offers, in dropdown order.
    listed_examples() -- src/examples.toml's entries.
    offered_examples() -- the examples the page offers.
    example_sources() -- where each offered example is.
    page_manifest() -- what the page is driven by, as JSON.
    site() -- what the playground serves.
    check() -- checks the page's targets and examples against the bundle, headless.
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
EXAMPLES = REPO / "src" / "examples.toml"
ASSETS = HERE / "assets"

# --- what each target means to the page -----------------------------------

# Which Ace mode highlights each target's output, and how (or whether) the
# browser can execute it. `python*`, `c*`, `java*` and `ocaml*` are
# display-only: there is no Python interpreter, C compiler, JVM or OCaml
# runtime in a browser, which is a property of the target rather than a
# shortcoming of the playground. Running the *program* needs none of them
# -- that is the interpreter, and it is compiled into the page (see
# `runFromSource` in assets/playground.js).
PYKING_TARGET = "pyking"

TARGET_MODE = {
    "pyking": "text",
    "python12": "python",
    "python14": "python",
    "node22": "javascript",
    "node24": "javascript",
    "web2020": "html",
    "web2024": "html",
    "iweb2020": "html",
    "iweb2024": "html",
    "c89": "c_cpp",
    "c99": "c_cpp",
    "c23": "c_cpp",
    "java8": "java",
    "java17": "java",
    "java21": "java",
    "ocaml4.14": "ocaml",
    "ocaml5.5": "ocaml",
}
TARGET_RUN = {
    # Every JavaScript target emits the same ES module, so all of them
    # run the same way here: inlined into a worker as a module.
    "node22": "module",
    "node24": "module",
    "web2020": "module",
    "web2024": "module",
}
TARGET_LABEL = {
    "pyking": "Pyking (the front end's own output)",
    "python12": "Python 3.12",
    "python14": "Python 3.14",
    "node22": "JavaScript - node 22 (ES2020)",
    "node24": "JavaScript - node 24 (ES2024)",
    "web2020": "JavaScript - web (ES2020)",
    "web2024": "JavaScript - web (ES2024)",
    "iweb2020": "Pyking interpreted in the browser (ES2020)",
    "iweb2024": "Pyking interpreted in the browser (ES2024)",
    "c89": "C89",
    "c99": "C99",
    "c23": "C23",
    "java8": "Java 8",
    "java17": "Java 17",
    "java21": "Java 21",
    "ocaml4.14": "OCaml 4.14",
    "ocaml5.5": "OCaml 5.5",
}



# `iweb` compiles nothing: it packages a program with the interpreter so
# a browser can run it. This page already *is* that -- it runs the
# interpreter -- so the target has nothing to offer here, and it could
# not produce its own page anyway without a copy of pyking.js to ship.
NOT_IN_THE_PAGE = {"iweb2020", "iweb2024"}



def listed_examples():
    """src/examples.toml's entries, in its order, or none where the file
    is missing. () -> [{...}]"""
    if not EXAMPLES.is_file():
        return []
    with open(EXAMPLES, "rb") as f:
        return tomllib.load(f).get("examples", [])


def offered_examples():
    """The examples the page offers: each the name it is offered by and
    its one-line description. () -> [{...}]"""
    return [{"file": e["name"], "description": e["description"]}
            for e in listed_examples()]


def example_sources():
    """Where each offered example is, by the name it is offered by.
    () -> {String: Path}"""
    return {e["name"]: REPO / e["source"] for e in listed_examples()}


def code_targets():
    """The targets the page offers, in the order the dropdown shows them.
    The compiler's own list is checked against this one by `check` and by
    tests/test_playground.py. () -> [String]"""
    return [t for t in TARGET_MODE if t not in NOT_IN_THE_PAGE]


def page_manifest():
    """What the page is driven by: the version (the root's VERSION file,
    which `pyk` is built with), the targets, how each is shown and run,
    and the examples. Worked out per request, so an edit to the manifest
    shows on the next reload. () -> Bytes"""
    targets = code_targets()
    examples = offered_examples()
    return json.dumps({
        "version": (REPO / "VERSION").read_text().strip(),
        "targets": [{"name": t, "label": TARGET_LABEL[t]} for t in targets],
        "modes": {t: TARGET_MODE[t] for t in targets},
        "run": {t: TARGET_RUN[t] for t in targets if t in TARGET_RUN},
        "examples": examples,
    }, indent=2).encode() + b"\n"


def site():
    """What the playground serves: its page and scripts, the manifest,
    and each offered example under the name it is offered by.
    () -> server.Site"""
    files = {"/": ASSETS / "index.html", "/index.html": ASSETS / "index.html"}
    for name, source in example_sources().items():
        files["/examples/" + name] = source
    return server.common_site().extended(
        mounts={"/assets/": ASSETS},
        files=files,
        answers={"/assets/playground.json": (page_manifest, "application/json")},
    )


# --- checking without a browser ------------------------------------------

CHECK_JS = r"""// Checks the page's targets and every example, under node.
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
const sources = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));
const lib = process.argv[5];

// Every target the compiler has must be one the page knows how to show,
// or deliberately left out of it (NOT_IN_THE_PAGE in playground.py).
const offered = new Set(manifest.targets.map((t) => t.name));
const unknown = JSON.parse(pykTargets())
  .filter((t) => !offered.has(t) && !t.startsWith("iweb"));
if (unknown.length) {
  console.log("  FAIL target(s) " + unknown.join(", ") + " exist in the compiler "
    + "but have no entry in TARGET_MODE/TARGET_LABEL in playground.py");
  process.exit(1);
}

// Every example checks as the page's Run checks it, with the modules it
// imports read from lib/ as the worker reads them.
globalThis.pykFetchSource = (name) => {
  const found = /^([A-Za-z_][A-Za-z0-9_]*?)(_external)?\.pyk$/.exec(name);
  try {
    return found ? fs.readFileSync(path.join(lib, found[1], name), "utf8") : null;
  } catch (error) {
    return null;
  }
};
let checked = 0;
let failures = 0;
for (const entry of manifest.examples) {
  checked += 1;
  globalThis.pykSources = { [entry.file]: fs.readFileSync(sources[entry.file], "utf8") };
  const result = JSON.parse(pykAnalyze(entry.file));
  if (result.ok) continue;
  failures += 1;
  console.log("  FAIL " + entry.file + ": " + result.text);
}
console.log(`check: ${checked - failures}/${checked} examples checked`);
process.exit(failures ? 1 : 0);
"""



def check():
    """Checks every target the compiler has is one the page knows, and
    every example as the page's Run checks it, through the compiler the
    page itself loads, under node (README.md, "Verifying without a
    browser"). () -> ()"""
    server.check_bundle("check")
    with tempfile.TemporaryDirectory(prefix="pyk-playground-") as directory:
        manifest = Path(directory) / "playground.json"
        manifest.write_bytes(page_manifest())
        script = Path(directory) / "check.cjs"
        script.write_text(CHECK_JS)
        sources = Path(directory) / "sources.json"
        sources.write_text(json.dumps({k: str(v) for k, v in example_sources().items()}))
        try:
            result = subprocess.run(
                ["node", str(script), str(server.BUNDLE), str(manifest),
                 str(sources), str(REPO / "lib")],
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
