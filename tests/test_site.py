#!/usr/bin/env python3
"""Runs the website's own test cases, and the help's, which the website
is made from: that every library is documented, that the library pages
say what the libraries export, that each library example prints what
its documentation says, that the remark plugin turns a page's Pyking
blocks into the cells the notebook mounts, that the menus list every
page, and that every runnable example on the site runs.

None of it needs Astro, which `make website` installs on first use and
`make test` does not. The examples are run with the interpreter (`pyk
FILE`), the reference for what a program means; the page runs the same
compiler as JavaScript, which tests/test_notebook.py covers.

Thirteen parts:

  docs      lib/ through tools/help/libdoc.py: nothing undocumented or
            documented wrongly -- every parameter in order, a Returns
            where one is answered, an example with its output -- no
            declaration without named parameters, and every module has
            a page boxing each thing it exports.
  exports   for each module, a program importing every name libdoc found
            compiles, so the pages name nothing the library does not
            export.
  copies    a library's node implementation that its browser one says
            is a copy of it is one.
  plugin    tools/site/src/remark-pyking-cells.mjs, under node, on a
            small tree: cells, attributes, norun, stdin/args blocks, and
            a task, which becomes a fragment of a notebook.
  notebook  every page in sitesrc/ has none of the problems the
            notebook's tasks.js finds in tasks and quizzes.
  examples  every example in lib/'s documentation, `norun` ones too,
            run with its stdin and args, in a directory of its own and
            with tinyweb's log set, prints exactly its ```stdout block.
  sidebar   the help's index (tools/help/help.py) and site.py's left
            menus list every page of every section, tinyweb's pages for
            other languages included; the Help tab's pages are among them;
            every menu has two levels, pages and their own pages, and
            no heading that is not a page; Documentation lists the tools,
            the language and tinyweb in that order, with the language
            reference's pages under it.
  reference PYKING.md is the language reference: every `##` part of it
            is a page (help.py, LANGUAGE_PAGES), its sections the page's
            `##` sections, the Grammar a page of its own; every link to a
            heading of another part leads to that part's page, and to a
            heading that page has.
  runtime   every sound a library's page plays is copied into the
            website's runtime.
  publish   what `make website-release` commits (tools/site/publish.py,
            `fill`): a built site replaces everything in a clone but
            .git, with .nojekyll and the CNAME naming the domain, and the
            site's address is https at that domain; and the build it
            served before is kept beside the new one, older ones not.
  build     the build's id (tools/site/site.py, `build_id`): the same
            files make the same id and any change a new one; the staged
            scripts and runtime move under v/<build>/, and version.json
            names the build, its commit and date and the Pyking version;
            the pages load the scripts and the runtime from there and
            tell shell.js the build.
  cells     every runnable ```pyking block of the help's pages -- sitesrc/,
            the language reference and the library pages: an `error`
            block must be refused, every other must run, with its
            ```stdin and ```args.
  excerpts  every compiled-code excerpt of the help's pages -- a
            ```<lang> excerpt target=<T> block, as "Pyking vs. other
            languages" shows what the compiler writes -- is found, line by
            line and in order, in what `pyk compile -t T --stdout` writes
            for the ```pyking block before it; a `...` line stands for
            lines left out.
  shell     every page loads tools/site/public/site/shell.js first, with
            the sections, and the shell's page starts no playground and
            no cells; then tests/site/shell.mjs drives the shell in
            Chromium, on pages of its own: each section kept open as it
            was left, links, Back, the theme, plain pages, and a new
            build reloaded onto at a moment that loses nothing. Skipped,
            and said so, where there is no Chromium.

Usage: python3 tests/test_site.py [--compiler CMD]

Functions:
    check_docs() -- the docs part.
    check_exports(compiler) -- the exports part.
    check_copies() -- the copies part.
    check_plugin() -- the plugin part.
    check_notebook() -- the notebook part.
    check_examples(compiler) -- the examples part.
    check_sidebar() -- the sidebar part.
    check_reference() -- the reference part.
    check_runtime() -- the runtime part.
    check_publish() -- the publish part.
    check_build() -- the build part.
    blocks(text) -- the runnable Pyking blocks of a Markdown page.
    check_cells(compiler) -- the cells part.
    excerpts(text) -- the compiled-code excerpts of a Markdown page.
    excerpt_problems(text, compiler) -- where they are not what the
        compiler writes.
    check_excerpts(compiler) -- the excerpts part.
    check_shell() -- the shell part.
    main(argv) -- the command-line entry point.
"""

import importlib.util
import json
import os
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
sys.path.insert(0, str(REPO / "tools" / "help"))

import suite  # noqa: E402  (after sys.path, which is what finds it)
import help as helpdoc  # noqa: E402
import libdoc  # noqa: E402
import tinywebdoc  # noqa: E402

# tools/site/site.py, by its path: `import site` is Python's own module.
_spec = importlib.util.spec_from_file_location("website", REPO / "tools" / "site" / "site.py")
website = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(website)
_spec = importlib.util.spec_from_file_location("publish", REPO / "tools" / "site" / "publish.py")
publish = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(publish)

SOURCES = REPO / "sitesrc"
PLUGIN = REPO / "tools" / "site" / "src" / "remark-pyking-cells.mjs"
SHELL_DRIVER = HERE / "site" / "shell.mjs"
MARKDOWN = REPO / "tools" / "notebook" / "assets" / "markdown.js"
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
  code("pyking", "print(7)\n", "playground"),
  code("pyking", "print(8)", "norun playground"),
  { type: "paragraph", children: [{ type: "text", value: "after" }] },
  code("pyking", "print(6)", "task points = 1"),
  code("stdout", "6"),
] };
plugin()(tree);
console.log(JSON.stringify(tree.children.map((n) =>
  n.type === "html" ? n.value
  : n.type === "code" ? `code:${n.lang}:${n.meta}`
  : n.type === "pykingTry" ? `try:${n.data.hName}.${n.data.hProperties.className}:`
    + n.children.map((c) => c.type === "code" ? `code:${c.lang}:${c.meta}` : c.value).join("|")
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
    'try:div.pyking-try:<div class="pkn-notebook pkn-embedded not-content">'
    '<div class="pkn-cell" ><pre class="pkn-cell-fallback"><code>print(7)</code></pre>'
    '</div></div>|<p class="pyking-try-foot not-content"><a class="pyking-try-link" '
    'href="/playground/#code=cHJpbnQoNykK">Try in playground</a></p>',
    'try:div.pyking-try:code:pyking:null|<p class="pyking-try-foot not-content">'
    '<a class="pyking-try-link" href="/playground/#code=cHJpbnQoOCkK">'
    'Try in playground</a></p>',
    "paragraph",
    '<div class="pkn-notebook pkn-embedded not-content"><div class="pkn-fragment" '
    'data-markdown="```pyking task points = 1\nprint(6)\n```\n\n```stdout\n6\n```">'
    '</div></div>',
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
                   if f"## {item.name}\n" not in page
                   or f'<span class="n">{item.name}</span>' not in page]
        results.append((f"the {module.name} page lists every export",
                        f"missing: {', '.join(missing)}" if missing else None))
    return results


def check_exports(compiler):
    """For each module, a program importing every name libdoc found
    compiles. String -> [(String, String?)]"""
    results = []
    for module in libdoc.read_modules(libdoc.LIB):
        # A submodule's names are taken from the submodule, one line each.
        lines = {}
        for item in module.items:
            inside = libdoc.submodule(item.name)
            path = module.name + ("." + inside if inside else "")
            lines.setdefault(path, []).append(item.name[len(inside) + 1:] if inside else item.name)
        # A probe per submodule, since two submodules may each have a name
        # the other has too (`smooth.circle` and `circle`).
        problems = []
        for path, names in lines.items():
            with tempfile.TemporaryDirectory(prefix="pyk-site-") as directory:
                program = Path(directory) / "probe.pyk"
                program.write_text(f"from {path} import {', '.join(names)}\n")
                ran = subprocess.run(
                    shlex.split(compiler) + ["compile", "-t", "pyking", "--stdout", str(program)],
                    capture_output=True, text=True, timeout=TIMEOUT)
            if ran.returncode != 0:
                problems.append((ran.stderr or ran.stdout).strip())
        results.append((f"{module.name} exports what its page names",
                        "\n".join(problems) if problems else None))
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


NOTEBOOK_DRIVER = r"""// Prints the problems the notebook finds in each page given.
import fs from "node:fs";
import { pathToFileURL } from "node:url";
const { renderMarkdown } = await import(pathToFileURL(process.argv[2]).href);
const found = {};
for (const page of process.argv.slice(3)) {
  found[page] = renderMarkdown(fs.readFileSync(page, "utf8")).notebook.problems
    .map((p) => `${p.line}: ${p.message}`);
}
console.log(JSON.stringify(found));
"""


def check_notebook():
    """Every page in sitesrc/ has none of the problems the notebook finds
    in tasks and quizzes. () -> [(String, String?)]"""
    pages = sorted(SOURCES.rglob("*.md"))
    with tempfile.TemporaryDirectory(prefix="pyk-site-") as directory:
        script = Path(directory) / "driver.mjs"
        script.write_text(NOTEBOOK_DRIVER)
        ran = subprocess.run(["node", str(script), str(MARKDOWN), *map(str, pages)],
                             capture_output=True, text=True, timeout=TIMEOUT)
    if ran.returncode != 0:
        return [("the notebook reads the pages", ran.stderr.strip())]
    found = json.loads(ran.stdout.strip().splitlines()[-1])
    return [(f"{Path(page).relative_to(REPO)} has no task or quiz problems",
             "\n  ".join(problems) or None) for page, problems in found.items()]


def _example_input(words):
    """The stdin and the arguments an example's fence gives it, as the
    notebook reads `stdin = "..."` and `args = "..."`.
    String -> (String, [String])"""
    found = {}
    for key, value in re.findall(r'(stdin|args)\s*=\s*"((?:[^"\\]|\\.)*)"', words):
        found[key] = value.replace("\\n", "\n").replace('\\"', '"')
    return found.get("stdin", ""), shlex.split(found.get("args", ""))


def _quiet_page(directory):
    """The environment a program runs in here: tinyweb's log and events
    set, so a program with a page writes what it draws to a file rather
    than serving it. String -> {String: String}"""
    events = Path(directory) / "events"
    events.write_text("")
    return {**os.environ, "PYKING_TINYWEB_LOG": str(Path(directory) / "page.log"),
            "PYKING_TINYWEB_EVENTS": str(events)}


def check_examples(compiler):
    """Every example in lib/'s documentation prints its ```stdout block,
    run with its input in a directory of its own, with tinyweb's log set
    so a page needs no browser. String -> [(String, String?)]"""
    results = []
    for module, item, example in libdoc.examples(libdoc.read_modules(libdoc.LIB)):
        if example.stdout is None:
            continue
        stdin, args = _example_input(example.words)
        with tempfile.TemporaryDirectory(prefix="pyk-example-") as directory:
            program = Path(directory) / "example.pyk"
            program.write_text(example.code)
            env = _quiet_page(directory)
            ran = subprocess.run(
                shlex.split(compiler) + [str(program)] + (["--"] + args if args else []),
                input=stdin, capture_output=True, text=True, timeout=TIMEOUT,
                cwd=directory, env=env)
        name = f"the example of {module.name}.{item.name}"
        if ran.returncode != 0:
            results.append((name + " runs", (ran.stderr or ran.stdout).strip()))
        else:
            results.append((name + " prints what its documentation says",
                            None if ran.stdout == example.stdout else
                            f"expected {example.stdout!r}, got {ran.stdout!r}"))
    return results


def check_sidebar():
    """The help's index and site.py's left menus, over the help written
    into a temporary directory with tinyweb's pages for other languages,
    list every page of every section; and the Help tab's pages are pages
    of the index. () -> [(String, String?)]"""
    results = []
    with tempfile.TemporaryDirectory(prefix="pyk-site-") as directory:
        content = Path(directory)
        index = helpdoc.write(content)
        languages = content / website.TINYWEB
        languages.mkdir(parents=True)
        (languages / "index.md").write_text(tinywebdoc.index_page())
        for language in tinywebdoc.LANGUAGES:
            (languages / f"{language.slug}.md").write_text(
                f"---\ntitle: tinyweb for {language.name}\nsidebar:\n"
                f"  label: {language.name}\n---\n")
        tinyweb = [item for item in website.sidebar_items(languages, f"/{website.TINYWEB}/")
                   if item.get("link") != f"/{website.TINYWEB}/"]
        menus = website.sidebar(index, tinyweb)
        for section in index["sections"]:
            name = section["id"]
            linked = set()
            pending = list(menus[name]["pages"])
            while pending:
                item = pending.pop()
                pending.extend(item.get("items", []))
                linked.add(item["link"])
            root = content / name
            found = ([content / f"{name}.md"] if (content / f"{name}.md").is_file()
                     else sorted(root.rglob("*.md")))
            pages = {"/" + page.relative_to(content).with_suffix("").as_posix()
                     .removesuffix("/index") + "/" for page in found}
            missing = sorted(pages - linked)
            results.append((f"the left menu of {section['label']} links every page",
                            f"missing: {', '.join(missing)}" if missing else None))
            slugs = {page["slug"] for page in section["pages"]}
            stray = [slug for slug in section["help"] if slug not in slugs]
            results.append((f"the Help tab shows pages of {section['label']}",
                            f"not pages: {', '.join(stray)}" if stray else None))
            absent = [page["file"] for page in section["pages"]
                      if not (content / page["file"]).is_file()]
            results.append((f"every page of {section['label']} in the index is written",
                            f"missing: {', '.join(absent)}" if absent else None))
        shown = [slug for section in index["sections"] for slug in section["help"]]
        wanted = ["getstarted/pyking-in-20-minutes", "documentation/language",
                  "documentation/language/functions", "documentation/grammar", "libraries"]
        results.append(("the Help tab shows Getting started, the language reference, "
                        "the grammar and the libraries",
                        None if all(w in shown for w in wanted) else f"shows {shown}"))
        documentation = menus["documentation"]["pages"]
        deep = [item["label"] for section in index["sections"]
                for entry in menus[section["id"]]["pages"]
                for item in entry.get("items", []) if item.get("items")]
        results.append(("every left menu has two levels: pages, and their own pages under them",
                        f"a third level under: {deep}" if deep else None))
        labels = [entry["label"] for entry in documentation]
        results.append(("Documentation's menu has no headings that are not pages",
                        None if all(entry.get("link") for entry in documentation)
                        and not any(entry.get("group") for entry in documentation)
                        else f"{labels}"))
        tops = [entry["link"] for entry in documentation]
        wanted_order = ["/documentation/editors/", "/documentation/language/",
                        "/documentation/grammar/", f"/{website.TINYWEB}/"]
        results.append(("Documentation's menu lists the tools, then the language, "
                        "then tinyweb",
                        None if all(w in tops for w in wanted_order)
                        and [tops.index(w) for w in wanted_order]
                        == sorted(tops.index(w) for w in wanted_order)
                        else f"{tops}"))
        reference = next((entry for entry in documentation
                          if entry["link"] == "/documentation/language/"), {})
        under = [item["link"] for item in reference.get("items", [])]
        expected = ["/" + file[: -len(".md")] + "/" for _, file, _ in helpdoc.LANGUAGE_PAGES[1:]
                    if file != "documentation/grammar.md"]
        results.append(("the language reference's pages are listed under it, in "
                        "PYKING.md's order",
                        None if under == expected else f"under it: {under}"))
        tinyweb_entry = next((entry for entry in documentation
                              if entry["link"] == f"/{website.TINYWEB}/"), {"items": []})
        results.append(("tinyweb's pages for other languages are listed under "
                        "Tinyweb without Pyking",
                        None if tinyweb_entry.get("items") else f"{tinyweb_entry}"))
    links = tinywebdoc.see_also(f"../../{website.TINYWEB}/")
    missing = [l.slug for l in tinywebdoc.LANGUAGES if f"/{l.slug}/)" not in links]
    results.append(("the tinyweb page links each language's page",
                    f"missing: {', '.join(missing)}" if missing else None))
    return results


def check_reference():
    """PYKING.md is the language reference, a page per `##` part.
    () -> [(String, String?)]"""
    results = []
    text = helpdoc.LANGUAGE.read_text()
    parts = helpdoc.split_parts(text)
    named = [title for title, _, _ in helpdoc.LANGUAGE_PAGES]
    results.append(("every `##` part of PYKING.md is a page help.py names, in order",
                    None if [title for title, _ in parts] == named
                    else f"PYKING.md: {[title for title, _ in parts]}"))
    pages = helpdoc.language_pages()
    results.append(("the Grammar is a page of its own",
                    None if "documentation/grammar.md" in pages else sorted(pages)))
    # A part's `###` sections are its page's `##` ones, which the menus
    # list; every part has at least one.
    bare = [file for file, page in pages.items() if not helpdoc.headings(page)]
    results.append(("every page of the reference has sections the menu lists",
                    f"none in: {', '.join(bare)}" if bare else None))
    deep = [file for file, page in pages.items()
            if any(line.startswith("### ") and not inside
                   for line, inside in helpdoc._fences(page.split("\n")))
            and not any(line.startswith("## ") and not inside
                        for line, inside in helpdoc._fences(page.split("\n")))]
    results.append(("every page's headings are promoted a level",
                    f"not in: {', '.join(deep)}" if deep else None))
    # Every link to a heading leads to a page that has it.
    anchors = {}
    for file, page in pages.items():
        slug = "/" + file[: -len(".md")].removesuffix("/index") + "/"
        anchors[slug] = {helpdoc.slugify(line.lstrip("#").strip())
                         for line, inside in helpdoc._fences(page.split("\n"))
                         if not inside and re.match(r"^#{2,6} ", line)}
    broken = []
    for file, page in pages.items():
        own = "/" + file[: -len(".md")].removesuffix("/index") + "/"
        for target, anchor in re.findall(r"\]\((/documentation/[^)#]*/)?#([^)\s]+)\)", page):
            if anchor not in anchors.get(target or own, set()):
                broken.append(f"{file}: {target or ''}#{anchor}")
    results.append(("every link to a heading of the reference leads to a page that has it",
                    "\n  ".join(broken) if broken else None))
    # A part help.py does not name stops the build, said plainly.
    original = helpdoc.LANGUAGE
    with tempfile.TemporaryDirectory(prefix="pyk-site-") as directory:
        changed = Path(directory) / "PYKING.md"
        changed.write_text(text + "\n## Something new\n\nText.\n")
        helpdoc.LANGUAGE = changed
        try:
            helpdoc.language_pages()
            refused = None
        except SystemExit as error:
            refused = str(error)
        finally:
            helpdoc.LANGUAGE = original
    results.append(("a `##` part help.py does not name stops the help's build",
                    None if refused and "Something new" in refused else repr(refused)))
    return results


def check_runtime():
    """Every sound in a library's assets is one the website copies into
    its runtime, since a page fetches it from there. () -> [(String, String?)]"""
    left = [str(path.relative_to(REPO)) for path in sorted(libdoc.LIB.glob("*/*_assets/*"))
            if path.suffix in (".wav", ".mp3", ".ogg")
            and not path.name.endswith(website.LIB_SUFFIXES)]
    return [("the website's runtime has every sound a page plays",
             f"not copied: {', '.join(left)}" if left else None)]


def check_publish():
    """What `make website-release` commits to the Pages repository: a
    built site in place of everything in a clone but .git, its paths
    starting with `_` kept by .nojekyll, CNAME naming the domain, and a
    README naming the commit; and the address is https at that domain.
    () -> [(String, String?)]"""
    with tempfile.TemporaryDirectory(prefix="pyk-site-") as directory:
        built, clone = Path(directory) / "website", Path(directory) / "clone"
        (built / "_astro").mkdir(parents=True)
        (built / "index.html").write_text("<p>new</p>\n")
        (built / "_astro" / "page.js").write_text("// new\n")
        (clone / ".git").mkdir(parents=True)
        (clone / ".git" / "HEAD").write_text("ref: refs/heads/main\n")
        (clone / "old").mkdir()
        (clone / "old" / "index.html").write_text("<p>gone</p>\n")
        (clone / "stale.txt").write_text("gone\n")
        # The build the clone serves now, which open tabs may still be
        # fetching from, and an older one no tab should be on.
        (clone / "version.json").write_text('{"build": "aaaa"}\n')
        for build in ("aaaa", "zzzz"):
            (clone / "v" / build).mkdir(parents=True)
            (clone / "v" / build / "lib.pyk").write_text(build + "\n")
        (built / "v" / "bbbb").mkdir(parents=True)
        (built / "v" / "bbbb" / "lib.pyk").write_text("bbbb\n")
        (built / "version.json").write_text('{"build": "bbbb"}\n')
        output = website.OUTPUT
        publish.website.OUTPUT = built
        try:
            publish.fill(clone, "0123456789abcdef")
        finally:
            publish.website.OUTPUT = output
        found = sorted(str(path.relative_to(clone)) for path in clone.rglob("*")
                       if path.is_file())
        wanted = [".git/HEAD", ".nojekyll", "CNAME", "README.md", "_astro/page.js",
                  "index.html", "v/aaaa/lib.pyk", "v/bbbb/lib.pyk", "version.json"]
        cname = (clone / "CNAME").read_text() if (clone / "CNAME").exists() else ""
        readme = (clone / "README.md").read_text() if (clone / "README.md").exists() else ""
    return [("a release replaces the Pages clone's files with the site's, keeping .git "
             "and the build served before, but no older one",
             None if found == wanted else f"found {found}"),
            ("the Pages README names the commit the site was built from",
             None if "0123456789abcdef" in readme else readme),
            ("the Pages CNAME names the domain, alone",
             None if cname == publish.DOMAIN + "\n" else repr(cname)),
            ("the website is published over https, at the domain's root",
             None if publish.SITE_URL == f"https://{publish.DOMAIN}/" else publish.SITE_URL)]


def check_build():
    """The build's id, version.json, and the pages naming the build.
    () -> [(String, String?)]"""
    results = []
    with tempfile.TemporaryDirectory(prefix="pyk-build-") as directory:
        root = Path(directory)
        content, public = root / "content", root / "public"
        (content / "a").mkdir(parents=True)
        (content / "a" / "page.md").write_text("one\n")
        staged = public / website.VERSIONED / website.STAGED
        (staged / "site").mkdir(parents=True)
        (staged / "site" / "shell.js").write_text("// shell\n")
        (staged / "runtime" / "pyking").mkdir(parents=True)
        (staged / "runtime" / "pyking" / "pyking.js").write_text("// compiler\n")
        first = website.build_id([content, public])
        results.append(("the same files make the same build id",
                        None if website.build_id([content, public]) == first else "it changed"))
        (content / "a" / "page.md").write_text("two\n")
        changed = website.build_id([content, public])
        (content / "a" / "page.md").rename(content / "a" / "other.md")
        renamed = website.build_id([content, public])
        results.append(("a page's text, or its name, changing makes a new build id",
                        None if len({first, changed, renamed}) == 3
                        else f"{first} {changed} {renamed}"))
        info = website.version_build(public, [content, public], "3a4f2c1", "2026-11-03",
                                     "0.1.9")
        build = info["build"]
        moved = public / website.VERSIONED / build
        results.append(("the scripts and the runtime move under v/<build>/",
                        None if (moved / "site" / "shell.js").is_file()
                        and (moved / "runtime" / "pyking" / "pyking.js").is_file()
                        and not staged.exists()
                        else sorted(str(p.relative_to(public)) for p in public.rglob("*"))))
        named = json.loads((public / "version.json").read_text())
        results.append(("version.json names the build, its commit and date, and the version",
                        None if named == {"build": build, "commit": "3a4f2c1",
                                          "date": "2026-11-03", "pyking": "0.1.9"}
                        and len(build) == 12 else repr(named)))
        results.append(("the build's directory says which build it is",
                        None if json.loads((moved / "build.json").read_text()) == named
                        else (moved / "build.json").read_text()))
        # A download made again from the same files, later, is the same
        # zip: the build id hashes it.
        files = root / "made" / "example"
        files.mkdir(parents=True)
        (files / "main.py").write_text("print(1)\n")
        tinywebdoc._zip(files, root / "first.zip")
        os.utime(files / "main.py", (0, 0))
        tinywebdoc._zip(files, root / "second.zip")
        results.append(("tinyweb's downloads are the same zip when made again from the same files",
                        None if (root / "first.zip").read_bytes() == (root / "second.zip").read_bytes()
                        else "the zips differ"))
    commit, date = website.commit_info()
    results.append(("the site names the commit it is built from, and its date",
                    None if re.fullmatch(r"[0-9a-f]{7,}", commit)
                    and re.fullmatch(r"\d{4}-\d\d-\d\d", date) else f"{commit!r} {date!r}"))
    site = REPO / "tools" / "site"
    config = (site / "astro.config.mjs").read_text()
    page = (site / "src" / "pages" / "playground.astro").read_text()
    results.append(("every page loads its scripts from v/<build>/ and tells shell.js the build",
                    None if "const scripts = `${prefix}/v/${build}/site`" in config
                    and '"data-build": build' in config and "/v/${build}/site/favicon.svg" in config
                    else "astro.config.mjs"))
    results.append(("the playground page runs the runtime from v/<build>/, says the build "
                    "when its version is hovered, and answers the shell",
                    None if "`v/${build}/runtime/`" in page and "built: host.dataset.built" in page
                    and "window.pykingUpdate" in page else "playground.astro"))
    results.append(("the site's cells answer the shell",
                    None if "window.pykingUpdate" in (site / "public" / "site" / "cells.js")
                    .read_text() else "cells.js"))
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


ELLIPSIS = re.compile(r"^(?:#|//|/\*|\(\*)?\s*\.\.\.\s*(?:\*/|\*\))?$")


def excerpts(text):
    """The compiled-code excerpts of a Markdown page: each ```<lang>
    excerpt target=<T> block, with the ```pyking block before it, the
    program it is an excerpt of. String -> [{source, target, lines, line}]"""
    found, lines, last, k = [], text.splitlines(), None, 0
    while k < len(lines):
        match = FENCE.match(lines[k])
        if not match:
            k += 1
            continue
        ticks, lang, rest = match.groups()
        end = k + 1
        while end < len(lines) and not lines[end].startswith(ticks):
            end += 1
        body = lines[k + 1:end]
        words = rest.split()
        target = next((w[len("target="):].strip('"') for w in words if w.startswith("target=")), None)
        if lang.lower() in ("pyking", "pyk"):
            last = "\n".join(body) + "\n"
        elif "excerpt" in words and target:
            found.append({"source": last, "target": target, "lines": body, "line": k + 1})
        k = end + 1
    return found


def excerpt_problems(text, compiler):
    """Where an excerpt is not what the compiler writes: each excerpt's
    lines, stripped and with `...` lines skipped, must be found in order
    among the lines `pyk compile -t T --stdout` writes for its program.
    String -> String -> [(String, String)]"""
    problems = []
    for excerpt in excerpts(text):
        name = f"the {excerpt['target']} excerpt at line {excerpt['line']}"
        if excerpt["source"] is None:
            problems.append((name, "no ```pyking block before it"))
            continue
        with tempfile.TemporaryDirectory(prefix="pyk-excerpt-") as directory:
            program = Path(directory) / "example.pyk"
            program.write_text(excerpt["source"])
            ran = subprocess.run(
                shlex.split(compiler) + ["compile", "-t", excerpt["target"], "--stdout",
                                         str(program)],
                capture_output=True, text=True, timeout=TIMEOUT, cwd=directory)
        if ran.returncode != 0:
            problems.append((name, "does not compile: " + (ran.stderr or ran.stdout).strip()))
            continue
        written = [line.strip() for line in ran.stdout.splitlines()]
        at = 0
        for line in excerpt["lines"]:
            wanted = line.strip()
            if not wanted or ELLIPSIS.match(wanted):
                continue
            try:
                at = written.index(wanted, at) + 1
            except ValueError:
                problems.append((name, f"the compiler does not write {wanted!r} (or not "
                                       "in this order)"))
                break
    return problems


def check_excerpts(compiler):
    """Every compiled-code excerpt of the help's pages is what the
    compiler writes. String -> [(String, String?)]"""
    results = []
    with tempfile.TemporaryDirectory(prefix="pyk-site-") as directory:
        generated = Path(directory) / "help"
        helpdoc.write(generated)
        for path in sorted(generated.rglob("*.md")):
            text = path.read_text()
            count = len(excerpts(text))
            if not count:
                continue
            problems = excerpt_problems(text, compiler)
            label = path.relative_to(generated)
            results.append((f"{label}: its {count} compiled-code excerpts are what "
                            "the compiler writes",
                            "\n  ".join(f"{n}: {p}" for n, p in problems) or None))
    return results


def check_cells(compiler):
    """Every runnable block of the help's pages -- sitesrc/, the language
    reference and the library pages -- runs, or is refused where it is
    marked `error`. String -> ([(String, String?)], Int)"""
    with tempfile.TemporaryDirectory(prefix="pyk-site-") as directory:
        generated = Path(directory) / "help"
        helpdoc.write(generated)
        pages = [(path.relative_to(generated), path) for path in sorted(generated.rglob("*.md"))]
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
                    input=stdin, capture_output=True, text=True, timeout=TIMEOUT,
                    cwd=directory, env=_quiet_page(directory))
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


def check_shell():
    """The shell that keeps every section open (shell.js): that the site
    loads it first in every page, telling it the sections; that the
    shell's own page starts no playground and no cells; and the shell in
    Chromium (tests/site/shell.mjs), on pages of its own.
    () -> [(String, String?)]"""
    site = REPO / "tools" / "site"
    config = (site / "astro.config.mjs").read_text()
    shell_at = config.find('src: scripts + "/shell.js"')
    results = [
        ("every page loads shell.js first, with the base and the sections",
         None if 0 <= shell_at < config.find('src: scripts + "/cells.js"')
         and '"data-sections": JSON.stringify(SECTIONS' in config
         and '"data-base": prefix' in config
         else "astro.config.mjs's head does not start with shell.js"),
        ("the shell's own page starts no playground",
         None if 'classList.contains("pyking-shell")'
         in (site / "src" / "pages" / "playground.astro").read_text()
         else "playground.astro mounts the playground in the shell"),
        ("the shell's own page mounts no cells",
         None if 'classList.contains("pyking-shell")'
         in (site / "public" / "site" / "cells.js").read_text()
         else "cells.js mounts the cells in the shell"),
    ]
    chromium = suite.find_chromium()
    if chromium is None:
        print("site: the shell in Chromium skipped (no Chromium found)")
        return results
    try:
        ran = suite.run_with_progress(["node", str(SHELL_DRIVER), chromium],
                                      "the shell in Chromium", 300)
        found = json.loads(ran.stdout)
    except (json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        return results + [("the shell in Chromium", f"the driver did not answer: {error}")]
    results += [(f"the shell: {failure}", failure) for failure in found["failures"]]
    results += [("the shell", None)] * (found["checks"] - len(found["failures"]))
    print(f"site: the shell in Chromium, {found['checks']} checks.")
    return results


def main(argv):
    """Runs every part and reports it. [String] -> Int"""
    compiler = DEFAULT_COMPILER
    if argv[:1] == ["--compiler"] and len(argv) == 2:
        compiler = argv[1]
    elif argv:
        print("usage: test_site.py [--compiler CMD]", file=sys.stderr)
        return 2
    cells, count = check_cells(compiler)
    results = (check_docs() + check_exports(compiler) + check_copies() + check_plugin()
               + check_notebook() + check_examples(compiler) + check_sidebar()
               + check_reference() + check_runtime() + check_publish() + check_build()
               + cells + check_excerpts(compiler) + check_shell())
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
