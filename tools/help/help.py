#!/usr/bin/env python3
"""The help: Pyking's documentation as Markdown pages, generated once and
read by everything that shows it -- the website (tools/site/site.py),
the playground's Help tab, and `pyk help`.

It writes, into one directory (build/help/ by default), every page of
sitesrc/ as it is, the language reference made from PYKING.md, and the
library reference made from lib/ by libdoc.py; and `index.json`, which
lists the sections, their pages in order, and each page's headings --
what the website's left menu and the Help tab's menu are made from. A
page's ```pyking blocks are cells, run in the page as the notebook runs
them. See tools/help/README.md.

Usage: python3 tools/help/help.py [DIRECTORY]

Data structures:
    SECTIONS -- the sections, in menu order: id, label, and whether the
        playground's Help tab shows them.

Functions:
    language_page() -- PYKING.md as the language reference page.
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
OUTPUT = REPO / "build" / "help"

# The sections, in the order the menus show them. `help` says whether
# the playground's Help tab shows the section; `pages`, where given,
# narrows it to those pages.
SECTIONS = [
    {"id": "install", "label": "Install", "help": False},
    {"id": "getstarted", "label": "Getting started", "help": True},
    {"id": "documentation", "label": "Documentation", "help": True,
     "pages": ["documentation/language"]},
    {"id": "libraries", "label": "Libraries", "help": True},
]


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


def language_page():
    """PYKING.md as the language reference: front matter in place of its
    title, and a link into docs/ -- which is not published -- kept as its
    text. () -> String"""
    text = LANGUAGE.read_text()
    lines = text.split("\n")
    if lines and lines[0].startswith("# "):
        lines = lines[1:]
    body = "\n".join(lines).lstrip("\n")
    body = re.sub(r"\[([^\]]+)\]\((?:docs/|\.\./)[^)]*\)", r"\1", body)
    return ("---\ntitle: Language reference\n"
            "description: The Pyking language, construct by construct, with its grammar.\n"
            "sidebar:\n  order: 1\n---\n\n" + body)


def _copy_sources(directory):
    """Every Markdown page of sitesrc/, at the same path. Path -> ()"""
    for page in sorted(SOURCES.rglob("*.md")):
        target = directory / page.relative_to(SOURCES)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(page, target)


def _pages(directory, section):
    """A section's pages, in menu order: {slug, file, title, label,
    headings}.
    Path -> {...} -> [{...}]"""
    root = directory / section["id"]
    if (directory / f"{section['id']}.md").is_file():
        files = [directory / f"{section['id']}.md"]
    else:
        files = sorted(root.glob("*.md")) if root.is_dir() else []
    pages = []
    for page in files:
        text = page.read_text()
        fields = front_matter(text)
        slug = page.relative_to(directory).with_suffix("").as_posix()
        if slug.endswith("/index"):
            slug = slug[:-len("/index")]
        order = fields.get("sidebar.order", "")
        title = fields.get("title", page.stem)
        pages.append({
            "slug": slug,
            "file": page.relative_to(directory).as_posix(),
            "title": title,
            "label": fields.get("sidebar.label") or title,
            "order": int(order) if order.lstrip("-").isdigit() else 1000,
            "headings": headings(text),
        })
    pages.sort(key=lambda p: (p["order"], p["label"]))
    return pages


def write(directory=OUTPUT):
    """Writes every page and index.json into directory, which is emptied
    first. Answers the index. Path -> {...}"""
    directory = Path(directory)
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True)
    _copy_sources(directory)
    (directory / "documentation").mkdir(exist_ok=True)
    (directory / "documentation" / "language.md").write_text(language_page())
    libdoc.write_pages(libdoc.read_modules(libdoc.LIB), directory / "libraries")
    index = {"sections": []}
    for section in SECTIONS:
        pages = _pages(directory, section)
        index["sections"].append({
            "id": section["id"], "label": section["label"],
            "pages": [{k: v for k, v in p.items() if k != "order"} for p in pages],
            "help": [p["slug"] for p in pages if section["help"]
                     and p["slug"] in section.get("pages", [p["slug"]])],
        })
    (directory / "index.json").write_text(json.dumps(index, indent=2) + "\n")
    return index


def main(argv=None):
    """Writes the help into the directory given, or build/help/.
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
