#!/usr/bin/env python3
"""The help: Pyking's documentation as Markdown pages, generated once and
read by everything that shows it -- the website (tools/site/site.py),
the playground's Help tab, and `pyk pykhelp`.

It writes, into one directory (share/help/ by default), every page of
sitesrc/ as it is, the language reference and the grammar made from
PYKING.md -- one page per `##` part of it, PYKING.md being the one
source of the language's documentation -- and the library reference
made from lib/ by libdoc.py; and `index.json`, which lists the sections,
their pages in order (each with the sidebar group it is shown under, if
any), and each page's headings -- what the website's left menu and the
Help tab's menu are made from. A
page's ```pyking blocks are cells, run in the page as the notebook runs
them. See tools/help/README.md.

Usage: python3 tools/help/help.py [DIRECTORY]

Data structures:
    SECTIONS -- the sections, in menu order: id, label, and whether the
        playground's Help tab shows them.
    LANGUAGE_PAGES -- each `##` part of PYKING.md: the page it becomes,
        its menu label and its description.

Functions:
    split_parts(text) -- PYKING.md's `##` parts, as (heading, lines).
    promote(lines) -- a part's headings one level up, outside code.
    language_pages() -- PYKING.md as the language reference's pages and
        the grammar page: {file: text}.
    headings(text) -- a page's `##` headings, with their anchors.
    front_matter(text) -- a page's front matter, as a dictionary.
    write(directory) -- writes every page and index.json.
    main(argv) -- the command-line entry point.
"""

import json
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))

import libdoc  # noqa: E402  (after sys.path, which is what finds it)

SOURCES = REPO / "sitesrc"
LANGUAGE = REPO / "PYKING.md"
OUTPUT = REPO / "share" / "help"

# The sections, in the order the menus show them. `help` says whether
# the playground's Help tab shows the section; `groups`, where given,
# narrows it to the pages of those sidebar groups.
SECTIONS = [
    {"id": "install", "label": "Install", "help": False},
    {"id": "getstarted", "label": "Getting started", "help": True},
    {"id": "documentation", "label": "Documentation", "help": True,
     "groups": ["Language"]},
    {"id": "libraries", "label": "Libraries", "help": True},
]

# Each `##` part of PYKING.md, in its order there: the file it becomes
# under the help's directory, and its description. The first is the
# Language reference's own page, the others are listed under it; the
# Grammar is a page of its own beside it. A part PYKING.md has and this
# does not name, or the other way round, stops the build (language_pages).
LANGUAGE_PAGES = [
    ("Overview", "documentation/language/index.md",
     "What Pyking is, how it differs from Python, and its modes at a glance."),
    ("Programs, modes and `use`", "documentation/language/programs-and-use.md",
     "A program, its modules, and the use lines that turn on mutation, pointers and objects."),
    ("Values and basic types", "documentation/language/values.md",
     "Int, Float, String, Char, Bool and unit: their literals and what they mean."),
    ("Operators and expressions", "documentation/language/expressions.md",
     "Operators, calls, evaluation order, if expressions, lambdas and let."),
    ("Names, bindings and scope", "documentation/language/names-and-scope.md",
     "Immutable bindings, block scope and shadowing."),
    ("Mutable state", "documentation/language/mutable-state.md",
     "var and :=, mutable structs and pointers, under use mutation."),
    ("Functions", "documentation/language/functions.md",
     "def, default and named arguments, annotations, return, tail position and tail calls."),
    ("Control flow", "documentation/language/control-flow.md",
     "if, for, while and loop, break and continue."),
    ("Collections", "documentation/language/collections.md",
     "Lists, tuples, Maps, Arrays, DynArrays, MutMaps, slices and views, and the folds."),
    ("Datatypes, structs and pattern matching", "documentation/language/datatypes.md",
     "datatype, struct, match and its patterns, Option and Result."),
    ("Objects", "documentation/language/objects.md",
     "Classes, abstract classes and interfaces, under use objects."),
    ("Types and type inference", "documentation/language/types.md",
     "The types, what the checker checks, type variables and inference."),
    ("Overloading and implicits", "documentation/language/overloading-and-implicits.md",
     "Static overloading and implicit parameters."),
    ("Modules", "documentation/language/modules.md",
     "Modules, public, imports, submodules and modules implemented elsewhere."),
    ("Builtins and I/O", "documentation/language/builtins.md",
     "print, debug, len, range, the conversions and panic, and where input and output go."),
    ("Warnings", "documentation/language/warnings.md",
     "What the compiler warns about, and the -W flags."),
    ("Grammar", "documentation/grammar.md",
     "Pyking's syntax: lexical structure, layout, the grammar in EBNF, and how it compares with Python."),
]
# The sidebar order of the Language reference and of the Grammar, among
# the Documentation pages of sitesrc/ (vs-other-languages.md is 9).
REFERENCE_ORDER, GRAMMAR_ORDER = 8, 10


def front_matter(text):
    """A page's front matter as {key: value}, a nested key written
    `parent.key`. String -> {String: String}"""
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return {}
    fields, parent = {}, ""
    for line in lines[1:lines.index("---", 1)]:
        key, _, value = line.strip().partition(":")
        value = value.strip().strip('"')
        if line.startswith(" "):
            fields[f"{parent}.{key}"] = value
        else:
            parent = key
            fields[key] = value
    return fields


def slugify(text):
    """The anchor a heading gets, as Starlight and the notebook's
    renderer both make it. String -> String"""
    text = re.sub(r"<[^>]+>", "", text).lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)
    return re.sub(r"\s", "-", text) or "section"


def headings(text):
    """A page's `##` headings, outside code blocks: [{text, anchor}].
    String -> [{String: String}]"""
    found, fence = [], False
    for line in text.split("\n"):
        if line.startswith(("```", "~~~")):
            fence = not fence
        elif not fence and line.startswith("## "):
            title = line[3:].strip()
            found.append({"text": re.sub(r"`", "", title), "anchor": slugify(title)})
    return found


def _fences(lines):
    """Each line with whether it is inside a fenced code block (the
    fence lines themselves count as inside). [String] -> [(String, Bool)]"""
    marked, fence = [], None
    for line in lines:
        match = re.match(r"^(`{3,}|~{3,})", line)
        if fence is None and match:
            fence = match.group(1)
            marked.append((line, True))
        elif fence is not None:
            if line.startswith(fence) and not line.strip().strip(fence[0]):
                fence = None
            marked.append((line, True))
        else:
            marked.append((line, False))
    return marked


def split_parts(text):
    """PYKING.md's `##` parts, in order, each its heading and its lines
    after it; what comes before the first (the title and the preamble)
    is left out. String -> [(String, [String])]"""
    parts = []
    for line, inside in _fences(text.split("\n")):
        if not inside and line.startswith("## "):
            parts.append((line[3:].strip(), []))
        elif parts:
            parts[-1][1].append(line)
    return parts


def promote(lines):
    """A part's headings one level up, `###` becoming `##`, outside code
    blocks: a part is a page, and its `###` sections are the page's
    sections. [String] -> [String]"""
    return [line[1:] if not inside and re.match(r"^#{3,6} ", line) else line
            for line, inside in _fences(lines)]


def language_pages():
    """PYKING.md as the language reference's pages and the grammar page,
    by the file each is written to: each part with front matter, a link
    into docs/ -- which is not published -- kept as its text, and a link
    to a heading of another part pointed at that part's page.
    () -> {String: String}"""
    parts = split_parts(LANGUAGE.read_text())
    named = [title for title, _, _ in LANGUAGE_PAGES]
    found = [title for title, _ in parts]
    if found != named:
        raise SystemExit("help: PYKING.md's `##` parts are not the pages LANGUAGE_PAGES "
                         f"names:\n  PYKING.md: {found}\n  help.py:   {named}")
    bodies, anchors = {}, {}
    for (title, lines), (_, file, _) in zip(parts, LANGUAGE_PAGES):
        body = "\n".join(promote(lines)).strip("\n")
        body = re.sub(r"\[([^\]]+)\]\((?:docs/|\.\./)[^)]*\)", r"\1", body)
        bodies[file] = body
        for line, inside in _fences(body.split("\n")):
            if not inside and re.match(r"^#{2,6} ", line):
                anchors.setdefault(slugify(line.lstrip("#").strip()), file)
    pages = {}
    for index, (title, file, description) in enumerate(LANGUAGE_PAGES):
        def link(match, file=file):
            target = anchors.get(match.group(2))
            if target is None or target == file:
                return match.group(0)
            slug = target[: -len(".md")].removesuffix("/index")
            return f"]({'/' + slug}/#{match.group(2)})"
        body = re.sub(r"\]\((#)([^)\s]+)\)", link, bodies[file])
        if file == "documentation/grammar.md":
            sidebar = f"  order: {GRAMMAR_ORDER}\n  group: Language\n"
        elif index == 0:
            sidebar = (f"  label: Language reference\n  order: {REFERENCE_ORDER}\n"
                       "  group: Language\n")
        else:
            sidebar = f"  parent: Language reference\n  position: {index}\n"
        page_title = "Language reference" if index == 0 else title.replace("`", "")
        pages[file] = (f'---\ntitle: "{page_title}"\ndescription: "{description}"\n'
                       f"sidebar:\n{sidebar}---\n\n{body}\n")
    return pages


def _copy_sources(directory):
    """Every Markdown page of sitesrc/, at the same path. Path -> ()"""
    for page in sorted(SOURCES.rglob("*.md")):
        target = directory / page.relative_to(SOURCES)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(page, target)


def _pages(directory, section):
    """A section's pages, in menu order: {slug, file, title, label,
    headings, parent, group}. A page whose front matter names a
    `sidebar.parent` comes after that page, by its `sidebar.position`, and
    `parent` is the parent's slug; it is in its parent's group. `group` is
    the `sidebar.group` the menu shows the page under, or "".
    Path -> {...} -> [{...}]"""
    root = directory / section["id"]
    if (directory / f"{section['id']}.md").is_file():
        files = [directory / f"{section['id']}.md"]
    else:
        files = sorted(root.rglob("*.md")) if root.is_dir() else []
    pages = []
    for page in files:
        text = page.read_text()
        fields = front_matter(text)
        slug = page.relative_to(directory).with_suffix("").as_posix()
        if slug.endswith("/index"):
            slug = slug[:-len("/index")]
        order = fields.get("sidebar.order", "")
        title = fields.get("title", page.stem)
        parent = fields.get("sidebar.parent", "")
        position = fields.get("sidebar.position", "")
        pages.append({
            "slug": slug,
            "file": page.relative_to(directory).as_posix(),
            "title": title,
            "label": fields.get("sidebar.label") or title,
            "order": int(order) if order.lstrip("-").isdigit() else 1000,
            "headings": headings(text),
            "parent": parent,
            "position": int(position) if position.isdigit() else 0,
            "group": fields.get("sidebar.group", ""),
        })
    labels = {p["label"]: p for p in pages if not p["parent"]}
    for page in pages:
        if page["parent"]:
            page["order"] = labels[page["parent"]]["order"] if page["parent"] in labels else 1000
            page["group"] = labels[page["parent"]]["group"] if page["parent"] in labels else ""
    pages.sort(key=lambda p: (p["order"], p["parent"] or p["label"], 1 if p["parent"] else 0,
                              p["position"], p["label"]))
    for page in pages:
        page["parent"] = (labels[page["parent"]]["slug"]
                          if page["parent"] in labels else "")
    return pages


def write(directory=OUTPUT):
    """Writes every page and index.json into directory, which is emptied
    first. Answers the index. Path -> {...}"""
    directory = Path(directory)
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True)
    _copy_sources(directory)
    for file, text in language_pages().items():
        (directory / file).parent.mkdir(parents=True, exist_ok=True)
        (directory / file).write_text(text)
    libdoc.write_pages(libdoc.read_modules(libdoc.LIB), directory / "libraries")
    index = {"sections": []}
    for section in SECTIONS:
        pages = _pages(directory, section)
        index["sections"].append({
            "id": section["id"], "label": section["label"],
            "pages": [{k: v for k, v in p.items() if k not in ("order", "position")}
                      for p in pages],
            "help": [p["slug"] for p in pages if section["help"]
                     and ("groups" not in section or p["group"] in section["groups"])],
        })
    (directory / "index.json").write_text(json.dumps(index, indent=2) + "\n")
    return index


def main(argv=None):
    """Writes the help into the directory given, or share/help/.
    [String]? -> ()"""
    argv = sys.argv[1:] if argv is None else argv
    directory = Path(argv[0]) if argv else OUTPUT
    for line in libdoc.problems(libdoc.read_modules(libdoc.LIB)):
        print("help: warning: " + line)
    index = write(directory)
    count = sum(len(s["pages"]) for s in index["sections"])
    print(f"help: {count} pages written into {directory}")


if __name__ == "__main__":
    main()
