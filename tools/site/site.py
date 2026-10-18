#!/usr/bin/env python3
"""Builds the Pyking website into website/: what `make website` runs.

The site is Astro with Starlight (astro.config.mjs beside this file). Its
pages are the help (tools/help/help.py: the Markdown files in sitesrc/,
the language reference from PYKING.md and one page per library from
lib/), and tinyweb's pages for using it from other languages, with
their downloads, written by tinywebdoc.py; its
runtime -- the compiler bundle, the
notebook's cells, the playground, the shared web scripts, the vendored
editor and the standard library -- is the same set of files `pyk
playground` serves, written out under runtime/. Everything is staged in
build/ beside this file first, and Astro reads it from there. See
README.md beside this file.

Usage: python3 tools/site/site.py [build | dev | stage] [--port N]

Functions:
    check_node() -- exits with a message unless node is new enough.
    install() -- runs `npm ci` when node_modules/ is missing or stale.
    grammar(bundle) -- the Pyking TextMate grammar, from the compiler's words.
    export_runtime(directory) -- writes the runtime into directory.
    sidebar_items(directory, path) -- the sidebar entries for staged pages.
    sidebar(index, tinyweb) -- the left menu of every section.
    stage() -- fills build/ with the pages, the static files, the runtime
        and the sidebar.
    astro(command, args) -- runs Astro's own command line.
    main(argv) -- the command-line entry point.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "tools" / "webrun"))
sys.path.insert(0, str(REPO / "tools" / "playground"))
sys.path.insert(0, str(REPO / "tools" / "help"))
sys.path.insert(0, str(HERE))

import server  # noqa: E402  (after sys.path, which is what finds it)
import playground  # noqa: E402
import help as helpdoc  # noqa: E402
import libdoc  # noqa: E402
import tinywebdoc  # noqa: E402

# Where tinyweb's pages for other languages go, under Documentation.
TINYWEB = "documentation/tinyweb"
OUTPUT = REPO / "website"
PICTURES = REPO / "sitesrc" / "pics"
STAGE = HERE / "build"
MODULES = HERE / "node_modules"
ASTRO = MODULES / "astro" / "bin" / "astro.mjs"

# Astro 7 needs this node or a later one.
MINIMUM_NODE = (22, 12)

# What a browser fetches from lib/: a module's Pyking source, its
# browser implementation, and the sounds a page plays (tinyweb's samples,
# in tinyweb_assets/). The plugins and the other targets' files stay.
LIB_SUFFIXES = (".pyk", ".js", ".wav", ".mp3", ".ogg", ".png")


def check_node():
    """Exits with a message unless node is MINIMUM_NODE or later. () -> ()"""
    wanted = "%d.%d" % MINIMUM_NODE
    try:
        version = subprocess.run(["node", "--version"], capture_output=True,
                                 text=True, check=True).stdout.strip()
    except (FileNotFoundError, subprocess.CalledProcessError):
        raise SystemExit(f"website: node not found, and node {wanted} or later "
                         "is required to build the site.")
    parts = version.lstrip("v").split(".")
    if tuple(int(p) for p in parts[:2]) < MINIMUM_NODE:
        raise SystemExit(f"website: found node {version}, but node {wanted} or "
                         "later is required to build the site.")


def install():
    """Runs `npm ci` when node_modules/ is missing or older than the lock
    file. No bin links: Astro is run through node, and a filesystem that
    cannot hold a symbolic link can still hold the site. () -> ()"""
    lock = HERE / "package-lock.json"
    marker = MODULES / ".package-lock.json"
    if marker.exists() and marker.stat().st_mtime >= lock.stat().st_mtime:
        return
    print("website: installing Astro and Starlight (npm ci)", flush=True)
    try:
        subprocess.run(["npm", "ci", "--no-bin-links", "--no-audit", "--no-fund"],
                       cwd=HERE, check=True)
    except FileNotFoundError:
        raise SystemExit("website: npm not found; it comes with node.")
    except subprocess.CalledProcessError:
        raise SystemExit("website: npm ci failed.")


def _words(bundle):
    """The compiler's keywords and builtins, asked of the bundle under node.
    Path -> {keywords, builtins}"""
    script = ('globalThis.require = require;'
              '(0, eval)(require("fs").readFileSync(process.argv[1], "utf8"));'
              'console.log(JSON.stringify({keywords: JSON.parse(pykKeywords()),'
              ' builtins: JSON.parse(pykBuiltins())}));')
    result = subprocess.run(["node", "-e", script, str(bundle)],
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout.strip().splitlines()[-1])


def grammar(bundle):
    """The Pyking TextMate grammar the site's code blocks are highlighted
    with, made from the compiler's own word lists, as the editors' mode
    is. Path -> {...}"""
    words = _words(bundle)
    keywords = words["keywords"]
    types = [w for w in keywords if w[:1].isupper()]
    constants = [w for w in keywords if w in ("true", "false")]
    control = [w for w in keywords if w not in types and w not in constants]
    alternatives = lambda ws: r"\b(?:" + "|".join(ws) + r")\b"
    return {
        "name": "pyking",
        "scopeName": "source.pyking",
        "aliases": ["pyk"],
        "patterns": [
            {"name": "comment.line.number-sign.pyking", "match": "#.*$"},
            {"name": "string.quoted.double.pyking", "match": r'"(?:[^"\\]|\\.)*"'},
            {"name": "string.quoted.single.pyking", "match": r"'(?:[^'\\]|\\.)*'"},
            {"name": "constant.numeric.pyking", "match": r"\b\d+(?:\.\d+)?\b"},
            {"match": r"\b(def)\s+([A-Za-z_]\w*)",
             "captures": {"1": {"name": "keyword.declaration.pyking"},
                          "2": {"name": "entity.name.function.pyking"}}},
            {"name": "keyword.control.pyking", "match": alternatives(control)},
            {"name": "storage.type.pyking", "match": alternatives(types)},
            {"name": "constant.language.pyking", "match": alternatives(constants)},
            {"name": "support.function.builtin.pyking",
             "match": alternatives(words["builtins"]) + r"(?=\s*\()"},
            {"name": "keyword.operator.pyking",
             "match": r":=|->|=>|\.\.|==|<=|>=|\+\+|[-+*/<>=]"},
        ],
    }


def _copy_tree(source, target, suffixes=None):
    """Copies a directory, keeping only files with one of `suffixes` when
    given, and never a hidden or backup file. Path -> Path -> (String)? -> ()"""
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if any(part.startswith(".") or part.endswith("~") or part.startswith("#")
               or part == "__pycache__" for part in relative.parts):
            continue
        if path.is_dir() or (suffixes and not path.name.endswith(suffixes)):
            continue
        (target / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target / relative)


def export_runtime(directory):
    """Writes the runtime into directory: what `pyk playground` serves --
    the notebook's scripts and the help among it -- each at the URL path
    the server gives it.
    The playground's own page is left out -- the site has its own.
    Path -> ()"""
    site = playground.site()
    for prefix, source in site.mounts.items():
        suffixes = LIB_SUFFIXES if prefix == "/lib/" else None
        _copy_tree(source, directory / prefix.strip("/"), suffixes)
    for path, source in site.files.items():
        if path in ("/", "/index.html"):
            continue
        target = directory / path.lstrip("/")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    for path, (make, _) in site.answers.items():
        target = directory / path.lstrip("/")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(make())


def _front_matter(page):
    """A page's title, and its sidebar label, order and whether it is
    hidden, from its front matter. Path -> (String, String, Int, Bool)"""
    lines = page.read_text().split("\n")
    fields, section = {}, ""
    for line in lines[1:lines.index("---", 1)] if lines[0] == "---" else []:
        key, _, value = line.strip().partition(":")
        value = value.strip().strip('"')
        if not line.startswith(" "):
            section = key
        fields[(section if line.startswith(" ") else "") + "." + key] = value
    title = fields.get(".title", page.stem)
    order = fields.get("sidebar.order", "")
    return (title, fields.get("sidebar.label") or title,
            int(order) if order.lstrip("-").isdigit() else 1000,
            fields.get("sidebar.hidden") == "true")


def sidebar_items(directory, path):
    """The sidebar entries for the staged pages in directory, served
    under path: a link per page and a group per subdirectory, labelled
    by its index page, each sorted by sidebar order and then label.
    Path -> String -> [{String: ...}]"""
    entries = []
    for page in sorted(directory.iterdir()):
        if page.is_file() and page.suffix in (".md", ".mdx") and not page.name.startswith("_"):
            _, label, order, hidden = _front_matter(page)
            if not hidden:
                link = path if page.stem == "index" else f"{path}{page.stem}/"
                entries.append(((order, label), {"label": label, "link": link}))
        elif page.is_dir():
            items = sidebar_items(page, f"{path}{page.name}/")
            index = page / "index.md"
            _, label, order, _ = (_front_matter(index) if index.exists()
                                  else (page.name, page.name, 1000, False))
            here = f"{path}{page.name}/"
            items = ([{**item, "label": "Overview"} for item in items if item.get("link") == here]
                     + [item for item in items if item.get("link") != here])
            if items:
                entries.append(((order, label), {"label": label, "items": items}))
    return [entry for _, entry in sorted(entries, key=lambda e: e[0])]


def sidebar(index, tinyweb):
    """The left menu of every section, by the section's id: its label,
    the path of its first page, and its pages -- each with a link and its
    headings, and tinyweb's pages for other languages as a group under
    Documentation. {...} -> [{...}] -> {String: {...}}"""
    menus = {}
    for section in index["sections"]:
        pages = [{"label": page["label"], "link": f"/{page['slug']}/",
                  "headings": page["headings"]} for page in section["pages"]]
        if section["id"] == "documentation":
            pages.append({"label": "Tinyweb without Pyking", "link": f"/{TINYWEB}/",
                          "headings": [], "items": tinyweb})
        menus[section["id"]] = {"label": section["label"],
                                "path": pages[0]["link"] if pages else "/",
                                "pages": pages}
    return menus


def stage():
    """Fills build/: content/ with the help and tinyweb's pages for other
    languages, pics/ from sitesrc/pics/, public/ from public/, the runtime
    and tinyweb's downloads,
    the left menus and the grammar; and empties Astro's cache. () -> ()"""
    server.check_bundle("website")
    server.check_vendor("website")
    # The cache too: Astro keeps the pages it rendered, and would not
    # notice that the remark plugin they were rendered with has changed.
    for name in ("content", "public", "cache", "pics"):
        shutil.rmtree(STAGE / name, ignore_errors=True)
    for line in libdoc.problems(libdoc.read_modules(libdoc.LIB)):
        print("website: warning: " + line)
    index = helpdoc.write(STAGE / "content")
    (STAGE / "content" / "index.json").unlink()
    _copy_tree(HERE / "public", STAGE / "public")
    # The pictures the site's stylesheet names, which Astro bundles from here.
    _copy_tree(PICTURES, STAGE / "pics", (".jpeg", ".jpg", ".png", ".svg", ".webp"))
    # tinyweb's implementations as libraries of their own, with the code
    # Pyking generates for its tests, which needs the compiler.
    tinywebdoc.write(STAGE / "content" / TINYWEB, STAGE / "public" / "tinyweb",
                     [str(REPO / "pyk")],
                     library=STAGE / "content" / "libraries" / "tinyweb.md",
                     href=f"../../{TINYWEB}/")
    export_runtime(STAGE / "public" / "runtime")
    # The left menu is the site's own (src/components/Sidebar.astro),
    # read from here; Starlight's `autogenerate` would find nothing, the
    # pages being staged outside src/content/docs/.
    tinyweb = [item for item in sidebar_items(STAGE / "content" / TINYWEB, f"/{TINYWEB}/")
               if item.get("link") != f"/{TINYWEB}/"]
    (STAGE / "sidebar.json").write_text(
        json.dumps(sidebar(index, tinyweb), indent=2) + "\n")
    (STAGE / "pyking.tmLanguage.json").write_text(
        json.dumps(grammar(server.BUNDLE), indent=2) + "\n")


def astro(command, args=()):
    """Runs Astro's own command line in this directory. String -> [String] -> ()"""
    env = {**os.environ, "PYKING_SITE_STAGE": str(STAGE),
           "PYKING_SITE_OUT": str(OUTPUT), "ASTRO_TELEMETRY_DISABLED": "1"}
    result = subprocess.run(["node", str(ASTRO), command, *args], cwd=HERE, env=env)
    if result.returncode:
        raise SystemExit(f"website: astro {command} failed.")


def main(argv=None):
    """The command-line entry point. [String]? -> ()"""
    parser = argparse.ArgumentParser(prog="site.py",
                                     description="Build the Pyking website.")
    parser.add_argument("command", nargs="?", default="build",
                        choices=("build", "dev", "stage"))
    parser.add_argument("--port", type=int, default=None)
    args = parser.parse_args(argv)
    check_node()
    stage()
    if args.command == "stage":
        return
    install()
    if args.command == "dev":
        astro("dev", ["--port", str(args.port)] if args.port else [])
        return
    astro("build")
    print(f"website: built into {OUTPUT}")


if __name__ == "__main__":
    main()
