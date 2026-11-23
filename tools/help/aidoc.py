#!/usr/bin/env python3
"""Pyking for AI assistants: what a coding assistant reads to write
Pyking -- the short guide, PYKING-LLM.md, the instructions a project
gives its assistant, and the standard library as plain text, short
enough for a small model's context.

`make` writes it into share/help/ai/ (help.py), where `pyk ai` reads it
(src/ai_command.ml), and the website publishes the same files as
llms.txt, llms-small.txt, llms-full.txt and llms/ (tools/site/site.py).
See sitesrc/documentation/ai.md.

What it writes, into one directory:

    PYKING-LLM.md     the short guide, as it is
    PYKING.md         the full language reference, as it is
    AGENTS.md         the instructions `pyk ai init` puts in a project
    lib/index.md      every library and submodule, with one line on each
    lib/NAME.md       one library or submodule, short: its description,
                      how to import it, and each export's signature
                      with its first sentence, under its topic
    lib/NAME.full.md  the same exports in full, each under `## name`:
                      what it does, its parameters, what it answers and
                      its examples with their output

NAME is the module, `list`, or the submodule, `tinyweb.color`.

Usage: python3 tools/help/aidoc.py [DIRECTORY]   (default share/help/ai)

Functions:
    parts(module) -- a module as the parts it is listed in.
    short_page(part) -- a part's exports, one signature and line each.
    full_page(part) -- a part's exports in full.
    index_page(modules) -- every part, with its first sentence.
    write(directory) -- writes everything above into directory.
    llms_txt(modules, url) -- the website's llms.txt.
    write_site(public, url) -- the website's llms files, into public/.
    main(argv) -- the command-line entry point.
"""

import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))

import libdoc  # noqa: E402  (after sys.path, which is what finds it)

GUIDE = REPO / "PYKING-LLM.md"
REFERENCE = REPO / "PYKING.md"
AGENTS = HERE / "agents-template.md"
OUTPUT = REPO / "share" / "help" / "ai"


@dataclass
class Part:
    """What `pyk ai lib NAME` shows: a module, or one submodule of a
    module sorted into submodules. `name` is how it is imported,
    `importing` the import line a program writes."""
    name: str
    description: str
    importing: str
    items: list


def _first_sentence(text):
    """A text's first sentence, on one line. String -> String"""
    first = text.split("\n\n")[0].replace("\n", " ").strip()
    match = re.match(r"(.+?\.)(\s|$)", first)
    return match.group(1) if match else first


def parts(module):
    """A module as `pyk ai lib` lists it: the module, and one part per
    submodule where its exports are in submodules (tinyweb). The
    prelude says nothing imports it. Module -> [Part]"""
    inside = list(dict.fromkeys(libdoc.submodule(item.name) for item in module.items))
    if module.name == "prelude":
        importing = "# nothing to import: these are builtins, called by their own names"
    elif module.name == "tinyweb":
        importing = "import tinyweb as tw"
    else:
        importing = f"import {module.name}"
    found = [Part(module.name, module.description, importing,
                  [item for item in module.items if not libdoc.submodule(item.name)])]
    for sub in inside:
        if sub:
            last = sub.split(".")[-1]
            found.append(Part(f"{module.name}.{sub}", module.submodules.get(sub, ""),
                              f"import {module.name}.{sub} as {last}",
                              [item for item in module.items
                               if libdoc.submodule(item.name) == sub]))
    if len(found) > 1:
        rows = "\n".join(f"- `{p.name}`: {_first_sentence(p.description)}" for p in found[1:])
        found[0].description += ("\n\nIts submodules, each imported on its own "
                                 f"(`pyk ai lib NAME` lists one):\n\n{rows}")
    return found


def _short_name(item):
    """An export's name as `pyk ai lib NAME.ITEM` finds it: without its
    submodule. Item -> String"""
    return item.name.split("::")[0].split(".")[-1] + (
        "::" + item.name.split("::")[1] if "::" in item.name else "")


def _topics(items):
    """Items grouped by their topic, in order. [Item] -> [(String, [Item])]"""
    order = list(dict.fromkeys(item.topic for item in items))
    return [(topic, [item for item in items if item.topic == topic]) for topic in order]


def short_page(part):
    """A part's exports, short: its description, the import line, then
    each export's signature with its first sentence. Part -> String"""
    lines = [f"# {part.name}", "", part.description.strip(), "", "```pyking",
             part.importing, "```", "",
             f"`pyk ai lib {part.name}.NAME` shows one of these in full, with an example.", ""]
    for topic, items in _topics(part.items):
        if topic:
            lines += [f"## {topic}", ""]
        lines.append("```")
        for item in items:
            lines.append(item.signature.strip())
            lines.append("    " + _first_sentence(item.text or item.doc))
        lines += ["```", ""]
    return "\n".join(lines).rstrip() + "\n"


def _item_full(part, item):
    """One export in full, under `## name`. Part -> Item -> String"""
    lines = [f"## {_short_name(item)}", "", "```", item.signature.strip(), "```", "",
             (item.text or item.doc).strip()]
    if item.param_lines:
        lines += ["", "Parameters:", ""] + item.param_lines
    if item.returns:
        lines += ["", "Returns: " + item.returns.strip()]
    for example in item.examples:
        lines += ["", "Example:", "", "```pyking", example.code.rstrip(), "```"]
        if example.stdout:
            lines += ["", "It prints:", "", "```", example.stdout.rstrip(), "```"]
    return "\n".join(lines)


def full_page(part):
    """A part's exports in full, each under `## name`. Part -> String"""
    lines = [f"# {part.name}", "", "```pyking", part.importing, "```"]
    for item in part.items:
        lines += ["", _item_full(part, item)]
    return "\n".join(lines).rstrip() + "\n"


def index_page(modules):
    """Every library and submodule, with its first sentence.
    [Module] -> String"""
    lines = ["# The standard library", "",
             "`pyk ai lib NAME` lists what one exports; `pyk ai lib NAME.ITEM` "
             "shows one export in full. A library is imported with `import NAME`; "
             "`prelude` is built in and needs no import.", ""]
    for module in modules:
        for part in parts(module):
            lines.append(f"- `{part.name}`: {_first_sentence(part.description)}")
    return "\n".join(lines) + "\n"


def write(directory=OUTPUT):
    """Writes the guide, the reference, the AGENTS.md template and the
    library's pages into directory, which is emptied first. Path -> ()"""
    directory = Path(directory)
    shutil.rmtree(directory, ignore_errors=True)
    (directory / "lib").mkdir(parents=True)
    shutil.copyfile(GUIDE, directory / "PYKING-LLM.md")
    shutil.copyfile(REFERENCE, directory / "PYKING.md")
    shutil.copyfile(AGENTS, directory / "AGENTS.md")
    modules = libdoc.read_modules(libdoc.LIB)
    (directory / "lib" / "index.md").write_text(index_page(modules))
    for module in modules:
        for part in parts(module):
            (directory / "lib" / f"{part.name}.md").write_text(short_page(part))
            (directory / "lib" / f"{part.name}.full.md").write_text(full_page(part))


def llms_txt(modules, url):
    """The website's llms.txt (llmstxt.org): what Pyking is, and links
    to the guide, the full reference and each library's pages, at the
    site's address url. [Module] -> String -> String"""
    rows = []
    for module in modules:
        for part in parts(module):
            rows.append(f"- [{part.name}]({url}llms/lib/{part.name}.md): "
                        f"{_first_sentence(part.description)} "
                        f"In full: {url}llms/lib/{part.name}.full.md")
    return "\n".join([
        "# Pyking",
        "",
        "> Pyking is a small, statically typed language with Python's syntax: every "
        "block is a scope, `=` never changes a name, types are inferred and checked "
        "before a program runs, and data is datatypes taken apart with `match`. "
        "It runs with an interpreter (`pyk prog.pyk`) and compiles to Python, "
        "JavaScript, C, Java and OCaml. It is not Python: read the guide before "
        "writing it.",
        "",
        "## Docs",
        "",
        f"- [Pyking for coding assistants]({url}llms-small.txt): the short guide, "
        "about 5,000 tokens. Start here.",
        f"- [The language reference]({url}llms-full.txt): every construct in full, "
        "about 80,000 tokens.",
        f"- [AGENTS.md]({url}llms/AGENTS.md): instructions for a project written in "
        "Pyking, as `pyk ai init` writes them.",
        f"- [AI-assisted programming]({url}documentation/ai/): how to set up an "
        "assistant for Pyking.",
        "",
        "## Libraries",
        "",
        f"- [Index]({url}llms/lib/index.md): every library, one line each.",
        *rows,
        "",
    ])


def write_site(public, url):
    """The website's llms files, into public/: llms.txt, llms-small.txt
    (the guide), llms-full.txt (the reference) and llms/, the files
    `write` makes. Path -> String -> ()"""
    public = Path(public)
    write(public / "llms")
    (public / "llms" / "PYKING-LLM.md").unlink()
    (public / "llms" / "PYKING.md").unlink()
    shutil.copyfile(GUIDE, public / "llms-small.txt")
    shutil.copyfile(REFERENCE, public / "llms-full.txt")
    (public / "llms.txt").write_text(llms_txt(libdoc.read_modules(libdoc.LIB), url))


def main(argv=None):
    """Writes everything into the directory given, or share/help/ai/.
    [String]? -> ()"""
    argv = sys.argv[1:] if argv is None else argv
    directory = Path(argv[0]) if argv else OUTPUT
    write(directory)
    print(f"ai: the guide and the library written into {directory}")


if __name__ == "__main__":
    main()
