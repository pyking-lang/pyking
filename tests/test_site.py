#!/usr/bin/env python3
"""Runs the website's own test cases: that every library is documented,
that the library pages say what the libraries export, that the remark
plugin turns a page's Pyking blocks into the cells the notebook mounts,
and that every runnable example on the site runs.

None of it needs Astro, which `make website` installs on first use and
`make test` does not. The examples are run with the interpreter (`pyk
FILE`), the reference for what a program means; the page runs the same
compiler as JavaScript, which tests/test_notebook.py covers.

Six parts:

  docs      lib/ through tools/site/libdoc.py: nothing undocumented, and
            every module has a page naming each thing it exports.
  exports   for each module, a program importing every name libdoc found
            compiles, so the pages name nothing the library does not
            export.
  copies    a library's node implementation that its browser one says
            is a copy of it is one.
  plugin    tools/site/src/remark-pyking-cells.mjs, under node, on a
            small tree: cells, attributes, norun, and stdin/args blocks.
  sidebar   site.py's sidebar lists every page of Getting started and
            Libraries, tinyweb's pages for other languages included.
  cells     every runnable ```pyking block in sitesrc/ and in the
            generated library pages: an `error` block must be refused,
            every other must run, with its ```stdin and ```args.

Usage: python3 tests/test_site.py [--compiler CMD]

Functions:
    check_docs() -- the docs part.
    check_exports(compiler) -- the exports part.
    check_copies() -- the copies part.
    check_plugin() -- the plugin part.
    check_sidebar() -- the sidebar part.
    blocks(text) -- the runnable Pyking blocks of a Markdown page.
    check_cells(compiler) -- the cells part.
    main(argv) -- the command-line entry point.
"""

import importlib.util
import json
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
REPO = HERE.parent
sys.path.insert(0, str(REPO / "tools" / "site"))

import suite  # noqa: E402  (after sys.path, which is what finds it)
import libdoc  # noqa: E402
import tinywebdoc  # noqa: E402

# tools/site/site.py, by its path: `import site` is Python's own module.
_spec = importlib.util.spec_from_file_location("website", REPO / "tools" / "site" / "site.py")
website = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(website)

SOURCES = REPO / "sitesrc"
PLUGIN = REPO / "tools" / "site" / "src" / "remark-pyking-cells.mjs"
DEFAULT_COMPILER = str(REPO / "pyk")
TIMEOUT = 60

FENCE = re.compile(r"^(`{3,})\s*([A-Za-z]*)\s*(.*)$")

PLUGIN_DRIVER = r"""// Runs the remark plugin on a hand-made tree and prints what it made.
import { pathToFileURL } from "node:url";
const { default: plugin } = await import(pathToFileURL(process.argv[2]).href);
const code = (lang, value, meta = null) => ({ type: "code", lang, meta, value });
const tree = { type: "root", children: [
  code("pyking", "print(1)\n"),
  code("pyking", "x := 1", "error readonly"),
  code("pyking", "def f(x): ...", "norun"),
  code("stdin", "Ada\n"),
  code("args", "a 'b c'"),
  code("pyk", "print(2)"),
  code("stdin", "lost"),
  { type: "paragraph", children: [{ type: "text", value: "between" }] },
  code("pyking", "print(3)"),
  { type: "blockquote", children: [code("pyking", "print(<4>)")] },
  code("python", "print(5)"),
] };
plugin()(tree);
console.log(JSON.stringify(tree.children.map((n) =>
  n.type === "html" ? n.value
  : n.type === "code" ? `code:${n.lang}:${n.meta}`
  : n.type === "blockquote" ? "quote:" + n.children[0].value
  : n.type)));
"""

PLUGIN_EXPECTED = [
    '<div class="pkn-notebook pkn-embedded not-content"><div class="pkn-cell" >'
    '<pre class="pkn-cell-fallback"><code>print(1)</code></pre></div></div>',
    '<div class="pkn-notebook pkn-embedded not-content"><div class="pkn-cell" '
    'data-readonly data-error><pre class="pkn-cell-fallback"><code>x := 1</code>'
    '</pre></div></div>',
    "code:pyking:null",
    '<div class="pkn-notebook pkn-embedded not-content"><div class="pkn-cell" '
    'data-stdin="Ada\n" data-args="a \'b c\'"><pre class="pkn-cell-fallback">'
    "<code>print(2)</code></pre></div></div>",
    "paragraph",
    '<div class="pkn-notebook pkn-embedded not-content"><div class="pkn-cell" >'
    '<pre class="pkn-cell-fallback"><code>print(3)</code></pre></div></div>',
    'quote:<div class="pkn-notebook pkn-embedded not-content"><div class="pkn-cell" >'
    '<pre class="pkn-cell-fallback"><code>print(&lt;4&gt;)</code></pre></div></div>',
    "code:python:null",
]


def check_docs():
    """Nothing in lib/ is undocumented, and every module's page names
    each of its items. () -> [(String, String?)]"""
    modules = libdoc.read_modules(libdoc.LIB)
    results = [("every library is documented",
                "\n  ".join(libdoc.problems(modules)) or None)]
    results.append(("lib/ has modules", None if modules else "none found"))
    for module in modules:
        page = libdoc.module_page(module)
        missing = [item.name for item in module.items
                   if f"### `{item.name}`" not in page or item.signature not in page]
        results.append((f"the {module.name} page lists every export",
                        f"missing: {', '.join(missing)}" if missing else None))
    return results


def check_exports(compiler):
    """For each module, a program importing every name libdoc found
    compiles. String -> [(String, String?)]"""
    results = []
    for module in libdoc.read_modules(libdoc.LIB):
        names = ", ".join(item.name for item in module.items)
        with tempfile.TemporaryDirectory(prefix="pyk-site-") as directory:
            program = Path(directory) / "probe.pyk"
            program.write_text(f"from {module.name} import {names}\n")
            ran = subprocess.run(
                shlex.split(compiler) + ["compile", "-t", "pyking", "--stdout", str(program)],
                capture_output=True, text=True, timeout=TIMEOUT)
        results.append((f"{module.name} exports what its page names",
                        None if ran.returncode == 0 else (ran.stderr or ran.stdout).strip()))
    return results


def check_copies():
    """Each lib/<name>/<name>_external_node.js that the browser
    implementation beside it names as a copy of itself is the same file.
    () -> [(String, String?)]"""
    results = []
    for browser in sorted(libdoc.LIB.glob("*/*_external_browser.js")):
        name = browser.name[: -len("_external_browser.js")]
        node = browser.with_name(f"{name}_external_node.js")
        if f"{node.name} is a copy of this file" not in browser.read_text():
            continue
        same = node.exists() and node.read_bytes() == browser.read_bytes()
        results.append((f"{node.name} is a copy of {browser.name}",
                        None if same else "they differ; copy the browser one over"))
    return results


def check_plugin():
    """The remark plugin, under node, on a hand-made tree.
    () -> [(String, String?)]"""
    with tempfile.TemporaryDirectory(prefix="pyk-site-") as directory:
        script = Path(directory) / "driver.mjs"
        script.write_text(PLUGIN_DRIVER)
        try:
            ran = subprocess.run(["node", str(script), str(PLUGIN)],
                                 capture_output=True, text=True, timeout=TIMEOUT)
        except FileNotFoundError:
            return [("the remark plugin", "node not found")]
    if ran.returncode != 0:
        return [("the remark plugin", ran.stderr.strip())]
    got = json.loads(ran.stdout.strip().splitlines()[-1])
    detail = None
    if got != PLUGIN_EXPECTED:
        wrong = next(k for k in range(max(len(got), len(PLUGIN_EXPECTED)))
                     if k >= len(got) or k >= len(PLUGIN_EXPECTED)
                     or got[k] != PLUGIN_EXPECTED[k])
        detail = (f"node {wrong}: got {got[wrong] if wrong < len(got) else None!r}, "
                  f"expected {PLUGIN_EXPECTED[wrong] if wrong < len(PLUGIN_EXPECTED) else None!r}")
    return [("the remark plugin makes cells, as the notebook does", detail)]


def check_sidebar():
    """site.py's sidebar_items, over the pages of Getting started and of
    Libraries staged in a temporary directory, links every one of them.
    () -> [(String, String?)]"""
    results = []
    with tempfile.TemporaryDirectory(prefix="pyk-site-") as directory:
        content = Path(directory)
        libraries = content / "libraries"
        libdoc.write_pages(libdoc.read_modules(libdoc.LIB), libraries)
        languages = libraries / "tinyweb-languages"
        languages.mkdir()
        (languages / "index.md").write_text(tinywebdoc.index_page())
        for language in tinywebdoc.LANGUAGES:
            (languages / f"{language.slug}.md").write_text(
                f"---\ntitle: tinyweb for {language.name}\nsidebar:\n"
                f"  label: {language.name}\n---\n")
        (content / "getstarted").mkdir()
        for page in (REPO / "sitesrc" / "getstarted").glob("*.md"):
            (content / "getstarted" / page.name).write_text(page.read_text())
        for name in ("getstarted", "libraries"):
            linked = set()
            pending = website.sidebar_items(content / name, f"/{name}/")
            while pending:
                item = pending.pop()
                pending.extend(item.get("items", []))
                if "link" in item:
                    linked.add(item["link"])
            pages = {f"/{page.parent.relative_to(content).as_posix()}/"
                     + ("" if page.stem == "index" else f"{page.stem}/")
                     for page in (content / name).rglob("*.md")}
            missing = sorted(pages - linked)
            results.append((f"the sidebar links every page under {name}/",
                            f"missing: {', '.join(missing)}" if missing else None))
    links = tinywebdoc.see_also("tinyweb-languages")
    missing = [l.slug for l in tinywebdoc.LANGUAGES if f"/{l.slug}/)" not in links]
    results.append(("the tinyweb page links each language's page",
                    f"missing: {', '.join(missing)}" if missing else None))
    return results


def blocks(text):
    """The runnable Pyking blocks of a Markdown page, as the remark
    plugin finds them: each with its words, and the stdin and args
    blocks just before it. String -> [{source, words, stdin, args}]"""
    found = []
    lines = text.splitlines()
    pending = {}
    k = 0
    while k < len(lines):
        match = FENCE.match(lines[k])
        if not match:
            if lines[k].strip():
                pending = {}
            k += 1
            continue
        ticks, lang, rest = match.groups()
        end = k + 1
        while end < len(lines) and not lines[end].startswith(ticks):
            end += 1
        body = "\n".join(lines[k + 1:end])
        lang = lang.lower()
        words = rest.lower().split()
        if lang in ("stdin", "args"):
            pending = {**pending, lang: body}
        elif lang in ("pyking", "pyk") and "norun" not in words:
            found.append({"source": body + "\n", "words": words,
                          "stdin": pending.get("stdin"), "args": pending.get("args")})
            pending = {}
        else:
            pending = {}
        k = end + 1
    return found


def check_cells(compiler):
    """Every runnable block in sitesrc/ and in the generated library
    pages runs, or is refused where it is marked `error`.
    String -> ([(String, String?)], Int)"""
    with tempfile.TemporaryDirectory(prefix="pyk-site-") as directory:
        generated = Path(directory) / "libraries"
        libdoc.write_pages(libdoc.read_modules(libdoc.LIB), generated)
        pages = [(path.relative_to(REPO), path) for path in sorted(SOURCES.rglob("*.md"))]
        pages += [(Path("libraries") / path.name, path) for path in sorted(generated.glob("*.md"))]
        results = []
        count = 0
        for label, path in pages:
            for index, block in enumerate(blocks(path.read_text())):
                count += 1
                program = Path(directory) / f"cell{count}.pyk"
                program.write_text(block["source"])
                args = shlex.split(block["args"]) if block["args"] else []
                stdin = block["stdin"] + "\n" if block["stdin"] else ""
                ran = subprocess.run(
                    shlex.split(compiler) + [str(program)] + (["--"] + args if args else []),
                    input=stdin, capture_output=True, text=True, timeout=TIMEOUT)
                name = f"{label} block {index + 1}"
                if "error" in block["words"]:
                    results.append((name + " is refused, as marked",
                                    None if ran.returncode != 0
                                    else "it ran: " + ran.stdout.strip()))
                else:
                    results.append((name + " runs",
                                    None if ran.returncode == 0
                                    else (ran.stderr or ran.stdout).strip()))
    return results, count


def main(argv):
    """Runs every part and reports it. [String] -> Int"""
    compiler = DEFAULT_COMPILER
    if argv[:1] == ["--compiler"] and len(argv) == 2:
        compiler = argv[1]
    elif argv:
        print("usage: test_site.py [--compiler CMD]", file=sys.stderr)
        return 2
    cells, count = check_cells(compiler)
    results = check_docs() + check_exports(compiler) + check_copies() + check_plugin() + check_sidebar() + cells
    failed = 0
    for name, detail in results:
        if detail is None:
            continue
        failed += 1
        print(f"site: {name} FAILED")
        print(f"  {detail}")
    print(f"site: {len(results) - failed}/{len(results)} checks passed, "
          f"{count} example{'' if count == 1 else 's'} run.")
    suite.footer("site", len(results) - failed, failed,
                 f"{len(results)} checks")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
