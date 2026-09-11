#!/usr/bin/env python3
"""Builds the Pyking playground: a static web page that runs the real
compiler in the browser, with no server-side execution. The compiler is
src/ compiled to JavaScript by js_of_ocaml, so the page runs the same
front end and the same backends `pyk` does -- there is no Python and no
Python runtime in the page at all.

Nothing under build/ is checked in. Every generated artifact comes from
this file or from assets/ beside it; see README.md for the design, what
each generated file does, and what is read out of the repository so the
playground cannot drift from the compiler it ships.

Usage: `make`, or directly:

    python3 generator.py vendor     download Ace into vendor/
    python3 generator.py build      generate build/
    python3 generator.py check      compile every example, headless
    python3 generator.py serve      serve build/ and print the URL

Data structures:
    QuietHandler -- the HTTP handler build/ is served with.

Functions:
    vendor(cdn) -- downloads Ace into vendor/.
    build(cdn) -- generates build/ from scratch.
    check() -- compiles every example for every target it claims, headless.
    serve(port) -- serves build/ and prints the URL.
    main(argv) -- the command-line entry point.
"""

import argparse
import functools
import hashlib
import http.server
import json
import shutil
import socket
import socketserver
import subprocess
import sys
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SRC_DIR = REPO / "src"
TESTS_DIR = REPO / "tests"
ASSETS = HERE / "assets"
BUILD = HERE / "build"
VENDOR = HERE / "vendor"

# --- what we vendor -------------------------------------------------------

ACE_VERSION = "1.43.4"
ACE_CDN = f"https://cdn.jsdelivr.net/npm/ace-builds@{ACE_VERSION}/src-min-noconflict"

# Only the modes the target list actually needs, plus the search box. Ace
# loads modes lazily from its basePath, so these must sit beside ace.js.
ACE_FILES = [
    "ace.js",
    "ext-searchbox.js",
    "mode-python.js",
    "mode-javascript.js",
    "mode-c_cpp.js",
    "mode-java.js",
    "mode-html.js",
    "mode-ocaml.js",
    "theme-tomorrow_night.js",
]

# --- the compiler, and what each target means to the page -----------------

# The compiler as one JavaScript file: `dune` builds it from src/ and
# src/web/, and the page loads exactly this.
# The compiler as JavaScript. `make` at the repository root builds it
# into build/pyking.js -- the same file the `iweb` target ships -- so
# there is one copy of it and one place it comes from. This runs the
# build itself when it is missing or stale, so `make -C tools/playground`
# still works on its own.
BUNDLE_TARGET = "src/web/pyking_web.bc.js"
BUNDLE_NAME = "pyking.js"
SHARED_BUNDLE = REPO / "build" / BUNDLE_NAME

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


def bundle_path():
    """The compiled compiler, built if it is not there already.

    `make` at the repository root writes build/pyking.js; this reuses it
    when it is there and current, and runs the same dune build itself
    otherwise, so the playground can still be built on its own.
    () -> Path"""
    try:
        subprocess.run(["dune", "build", BUNDLE_TARGET], cwd=REPO, check=True)
    except FileNotFoundError:
        raise SystemExit(
            "generator.py: dune not found. Building the compiler for the "
            "browser needs dune, an OCaml compiler and js_of_ocaml; see "
            "docs/build.md."
        )
    except subprocess.CalledProcessError:
        raise SystemExit(f"generator.py: `dune build {BUNDLE_TARGET}` failed")
    path = REPO / "_build" / "default" / BUNDLE_TARGET
    if not path.exists():
        raise SystemExit(f"generator.py: {BUNDLE_TARGET} was not built")
    # Keep the shared copy in step, so `make` at the root and `make -C
    # tools/playground` cannot end up with different compilers.
    SHARED_BUNDLE.parent.mkdir(parents=True, exist_ok=True)
    source = path.read_bytes()
    if not SHARED_BUNDLE.exists() or SHARED_BUNDLE.read_bytes() != source:
        SHARED_BUNDLE.write_bytes(source)
    return SHARED_BUNDLE


def ask_compiler(function, *args):
    """One question put to the compiled compiler, under node: the answer
    `function` gives, parsed as JSON. This is how the generator reads the
    target list, the language's word lists and the JavaScript value
    formatter -- out of the compiler itself rather than out of a copy
    (README.md, "What is read out of the repository").
    String -> String... -> Any"""
    bundle = bundle_path()
    # Read and evaluate rather than `require`: the bundle is a classic
    # script, but a package.json saying "type": "module" anywhere above
    # it makes node read a .js file as an ES module, and whether
    # `require` then works depends on the node version. Reading the text
    # sidesteps the module system entirely, so this behaves the same
    # wherever the repository happens to sit.
    script = (
        f"const fs = require('fs');\n"
        # The bundle is evaluated in global scope, which is what it
        # expects; js_of_ocaml's own runtime calls `require`, which is a
        # module-local in CommonJS, so it is put where global code can
        # see it.
        f"globalThis.require = require;\n"
        f"(0, eval)(fs.readFileSync({json.dumps(str(bundle))}, 'utf8'));\n"
        f"process.stdout.write(String(globalThis[{json.dumps(function)}]"
        f"({', '.join(json.dumps(a) for a in args)})));\n"
    )
    try:
        result = subprocess.run(
            # --input-type=commonjs for the same reason: without it, the
            # code passed to -e is read as an ES module in a "type":
            # "module" scope, where `require` is not defined.
            ["node", "--input-type=commonjs", "-e", script],
            capture_output=True, text=True, check=True,
        )
    except FileNotFoundError:
        raise SystemExit(
            "generator.py: node not found. The generator asks the compiled "
            "compiler for the target list and the language's word lists, "
            "which needs node."
        )
    except subprocess.CalledProcessError as e:
        raise SystemExit(f"generator.py: {function}() failed:\n{e.stderr}")
    return result.stdout


def ask_json(function, *args):
    """`ask_compiler`, for a function that answers JSON.
    String -> String... -> Any"""
    return json.loads(ask_compiler(function, *args))


def js_value_formatter():
    """The pykFormat helper the JavaScript backend generates, read out of
    the compiler rather than hand-copied. () -> String"""
    formatter = ask_compiler("pykFormatHelper")
    if "pykFormat" not in formatter:
        raise SystemExit(
            "generator.py: pykFormatHelper() did not answer with the "
            "JavaScript backend's value formatter."
        )
    return formatter


# `iweb` compiles nothing: it packages a program with the interpreter so
# a browser can run it. This page already *is* that -- it runs the
# interpreter -- so the target has nothing to offer here, and it could
# not produce its own page anyway without a copy of pyking.js to ship.
NOT_IN_THE_PAGE = {"iweb24"}


def target_order():
    """Every target the compiler has, in the order the dropdown shows
    them (pyking first), read out of the compiler. () -> [String]"""
    names = [n for n in ask_json("pykTargets") if n not in NOT_IN_THE_PAGE]
    missing = [n for n in names if n not in TARGET_MODE]
    if missing:
        raise SystemExit(
            f"generator.py: target(s) {missing} exist in the compiler but have "
            "no entry in TARGET_MODE/TARGET_LABEL -- add them here."
        )
    return names


def asset(name):
    """One generated artifact's source text, out of assets/.
    String -> String"""
    return (ASSETS / name).read_text()


# --- build steps ----------------------------------------------------------


def vendor(cdn=False):
    """Downloads Ace into vendor/, once; a file already present is left
    alone. Bool -> ()"""
    if cdn:
        print("vendor: CDN=1, nothing to download "
              "(the page will load Ace from jsdelivr)")
        return

    directory = VENDOR / "ace"
    directory.mkdir(parents=True, exist_ok=True)
    fetched = 0
    for name in ACE_FILES:
        path = directory / name
        if path.exists():
            continue
        url = f"{ACE_CDN}/{name}"
        try:
            with urllib.request.urlopen(url) as response:
                path.write_bytes(response.read())
        except urllib.error.URLError as e:
            raise SystemExit(f"vendor: cannot fetch {url}: {e}")
        fetched += 1
    size = sum(p.stat().st_size for p in VENDOR.rglob("*") if p.is_file())
    print(f"vendor: {'downloaded ' + str(fetched) if fetched else 'up to date'}"
          f" ({size / 1048576:.1f} MB in {VENDOR.relative_to(HERE)}/)")


def write_compiler():
    """Copies the compiled compiler into build/pyking/ and writes the
    manifest naming it. Answers True if the file had to be written, so
    `serve` can say that the compiler under it had moved on.

    The manifest carries a *stamp*: a hash of exactly the bytes that were
    written. The page reads it back before every compile, which is what
    stops a tab booted from an earlier build quietly disagreeing with
    `pyk` (see assets/pyking-runtime.js, `_checkStamp`). () -> Bool"""
    source = bundle_path().read_bytes()
    (BUILD / "pyking").mkdir(parents=True, exist_ok=True)
    path = BUILD / "pyking" / BUNDLE_NAME
    written = not path.exists() or path.read_bytes() != source
    if written:
        path.write_bytes(source)
    (BUILD / "pyking" / "manifest.json").write_text(json.dumps(
        {"bundle": BUNDLE_NAME,
         "stamp": hashlib.sha256(source).hexdigest()[:16],
         "note": f"{BUNDLE_TARGET}, built from src/ by dune"},
        indent=2) + "\n")
    return written


def build(cdn=False):
    """Generates build/ from scratch. Bool -> ()"""
    if BUILD.exists():
        shutil.rmtree(BUILD)
    assets = BUILD / "assets"
    (BUILD / "pyking").mkdir(parents=True)
    (BUILD / "examples").mkdir(parents=True)
    assets.mkdir(parents=True)

    # 1. the compiler, as one JavaScript file
    write_compiler()

    # 2. the examples, and what each one is known to compile to
    targets = target_order()
    examples = build_examples(targets)

    # 3. the Ace mode, with the language's own word lists baked in
    keywords = ask_json("pykKeywords")
    builtins = ask_json("pykBuiltins")
    types = [k for k in keywords if k in ("Int", "String", "Bool")]
    (assets / "pyking-mode.js").write_text(
        asset("pyking-mode.js")
        .replace("%%KEYWORDS%%", "|".join(k for k in keywords if k not in types))
        .replace("%%TYPES%%", "|".join(types))
        .replace("%%BUILTINS%%", "|".join(builtins)))

    # 4. the page itself
    (assets / "playground.css").write_text(asset("playground.css"))
    (assets / "playground.js").write_text(asset("playground.js"))
    (assets / "pyking-runtime.js").write_text(asset("pyking-runtime.js"))
    # The two threads execution happens on -- see assets/pyking-worker.js.
    (assets / "pyking-worker.js").write_text(asset("pyking-worker.js"))
    (assets / "js-worker.js").write_text(
        asset("js-worker.js").replace("%%PYK_FORMAT%%", js_value_formatter()))
    (BUILD / "index.html").write_text(asset("index.html"))

    # 5. the manifest the UI is driven by -- targets, modes, examples
    (assets / "playground.json").write_text(json.dumps({
        "generatedBy": "tools/playground/generator.py",
        "aceURL": (ACE_CDN if cdn else "./assets/vendor/ace"),
        "targets": [{"name": t, "label": TARGET_LABEL[t]} for t in targets],
        "modes": {t: TARGET_MODE[t] for t in targets},
        "run": {t: TARGET_RUN[t] for t in targets if t in TARGET_RUN},
        "examples": examples,
    }, indent=2) + "\n")

    # 6. vendored assets (or nothing at all, under CDN=1)
    if cdn:
        patch_for_cdn(assets)
    else:
        if not (VENDOR / "ace" / "ace.js").exists():
            raise SystemExit("build: vendor/ is empty -- run `make vendor` first "
                             "(or build against the CDN with `make CDN=1`).")
        shutil.copytree(VENDOR / "ace", assets / "vendor" / "ace")

    size = sum(p.stat().st_size for p in BUILD.rglob("*") if p.is_file())
    print(f"build: {BUILD.relative_to(HERE)}/ "
          f"({size / 1048576:.1f} MB, {len(examples)} examples, "
          f"{len(targets)} targets{', CDN assets' if cdn else ''})")


def patch_for_cdn(assets):
    """Points the loader at jsdelivr instead of a vendor/ directory.
    Path -> ()"""
    path = assets / "playground.js"
    path.write_text(path.read_text().replace(
        'cfg.base + "/vendor/ace/ace.js"', f'"{ACE_CDN}/ace.js"').replace(
        'ace.config.set("basePath", cfg.base + "/vendor/ace")',
        f'ace.config.set("basePath", "{ACE_CDN}")'))


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


def build_examples(code_targets):
    """The examples the page offers, copied into build/examples.
    [String] -> [{...}]"""
    entries = offered_examples(code_targets, notes=True)
    for entry in entries:
        shutil.copy2(TESTS_DIR / entry["file"], BUILD / "examples" / entry["file"])
    return entries


CHECK_JS = r"""// Compiles every example for every target it claims, under node.
// Written by tools/playground/generator.py; nothing here is shipped.
const fs = require("fs");
const path = require("path");
// Evaluated rather than required: the bundle is a classic script, and a
// package.json saying "type": "module" above it would otherwise make
// node read it as an ES module (see ask_compiler in generator.py).
// `require` is a module-local in CommonJS and js_of_ocaml's runtime
// calls it, so global code needs it put within reach.
globalThis.require = require;
(0, eval)(fs.readFileSync(process.argv[2], "utf8"));
const manifest = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const examples = process.argv[4];

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
    manifest = BUILD / "assets" / "playground.json"
    if not manifest.exists():
        raise SystemExit("check: nothing built yet -- run `make build` first.")
    script = BUILD / "check.cjs"
    script.write_text(CHECK_JS)
    try:
        result = subprocess.run(
            ["node", str(script), str(BUILD / "pyking" / BUNDLE_NAME),
             str(manifest), str(BUILD / "examples")],
            cwd=HERE,
        )
    except FileNotFoundError:
        raise SystemExit("check: node not found; it is what runs the compiler.")
    finally:
        script.unlink(missing_ok=True)
    if result.returncode:
        raise SystemExit(1)


def serve(port):
    """Serves build/ and prints a URL the terminal will linkify.
    Int -> ()"""
    if not (BUILD / "index.html").exists():
        raise SystemExit("serve: nothing built yet -- run `make build` first.")

    # build/pyking/ holds a *copy* of the compiled compiler, so editing
    # src/ and then serving an existing build would show the page one
    # compiler while `pyk` runs another -- the one difference nobody
    # would think to doubt, since both claim to be the front end's own
    # output. It is one file, so it is refreshed here rather than being
    # left to a rebuild that also re-copies the vendored assets. Nothing
    # else in build/ is touched; a change to the page, the examples or
    # the Ace mode still needs `make build`.
    if write_compiler():
        print("serve: refreshed the compiler from src/")

    port = first_free_port(port)
    handler = functools.partial(QuietHandler, directory=str(BUILD))
    # Threaded, not the stdlib default: a single-threaded server blocks
    # on an idle speculative connection while the page waits for a
    # dozen files including the compiler, which looks like a hang.
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    with http.server.ThreadingHTTPServer(("", port), handler) as httpd:
        url = f"http://localhost:{port}/"
        print()
        print("  Pyking playground is being served.")
        print()
        print(f"      {url}")
        print()
        print("  Open that link in a browser (ctrl/cmd-click it in most")
        print("  terminals). It must be *served*, not opened from disk:")
        print("  browsers block the module and worker loads a file://")
        print("  page would need.")
        print()
        print("  Press Ctrl+C to stop.")
        print()
        # serve_forever() never returns, so an unflushed banner would sit in
        # the buffer forever whenever stdout is a pipe rather than a terminal.
        sys.stdout.flush()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nserve: stopped.")


def first_free_port(start, tries=20):
    """The first free port at or after start, checked up to tries times.
    Int -> Int -> Int"""
    for port in range(start, start + tries):
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(("", port))
                return port
            except OSError:
                continue
    raise SystemExit(f"serve: no free port in {start}..{start + tries - 1}")


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    """The stdlib handler, minus a log line per asset."""

    # Keep-alive, so the browser does not reopen a connection per file.
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def end_headers(self):
        # Vendored Ace is version-pinned and never regenerated, so it
        # caches; everything make regenerates must not, or you debug the
        # previous build.
        if "/assets/vendor/" in self.path:
            self.send_header("Cache-Control", "public, max-age=86400")
        else:
            self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main(argv=None):
    """The command-line entry point. [String]? -> ()"""
    parser = argparse.ArgumentParser(
        prog="generator.py", description="Build the Pyking web playground.")
    parser.add_argument("command",
                        choices=("vendor", "build", "check", "serve", "all"))
    parser.add_argument("--cdn", action="store_true",
                        help="load Ace from a CDN instead of vendor/")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args(argv)

    if args.command in ("vendor", "all"):
        vendor(args.cdn)
    if args.command in ("build", "all"):
        build(args.cdn)
    if args.command in ("check", "all"):
        check()
    if args.command in ("serve", "all"):
        serve(args.port)


if __name__ == "__main__":
    main()
