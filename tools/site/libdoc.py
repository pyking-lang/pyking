#!/usr/bin/env python3
"""The library reference: reads the standard library in lib/ and writes
one Markdown page per module, for the website's "Libraries" section.

A module is a directory of lib/ holding `<name>.pyk`, `<name>_external.pyk`
or both. Its documentation is its `##` comments: a `##` block opening
either file describes the module, and a `##` block directly above a
`public` line describes what that line exports. A plain `#` comment is a
note for whoever maintains the library and is never published. What each
item is shown as is its own line of source, without `public`, so the
types are the ones the checker holds the library to. See README.md beside
this file.

Usage: python3 tools/site/libdoc.py [LIB]    print what is undocumented

Data structures:
    Item -- one exported name: its kind, its name, its signature, its doc.
    Module -- one library: its name, its description, its items.

Functions:
    read_modules(lib) -- every module in a lib/ directory.
    read_module(directory) -- one module, from its one or two files.
    problems(modules) -- what is undocumented, one line each.
    module_page(module) -- one module's page, as Markdown.
    index_page(modules) -- the section's overview page, as Markdown.
    write_pages(modules, directory) -- writes every page into directory.
"""

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

DOC = "##"

# `public def name : type` -- a signature, from either half.
SIGNATURE = re.compile(r"^public\s+def\s+([A-Za-z_]\w*)\s*:")
# `public def name(...)` -- a definition, from the Pyking half.
DEFINITION = re.compile(r"^public\s+def\s+([A-Za-z_]\w*)\s*\(")
# `public NAME: T = value` -- a value.
VALUE = re.compile(r"^public\s+([A-Za-z_]\w*)\s*:")


@dataclass
class Item:
    """One exported name. `kind` is "function" or "value"."""
    kind: str
    name: str
    signature: str
    doc: str
    file: str
    line: int


@dataclass
class Module:
    """One library: its name, the `##` text describing it, and what it
    exports."""
    name: str
    description: str
    items: list = field(default_factory=list)
    files: list = field(default_factory=list)
    directory: Path = None

    def summary(self):
        """The description's first sentence. () -> String"""
        first = self.description.split("\n\n")[0].replace("\n", " ").strip()
        match = re.match(r"(.+?\.)(\s|$)", first)
        return match.group(1) if match else first


def _doc_text(line):
    """The text of one `##` line, without the marker. String -> String"""
    text = line[len(DOC):]
    return text[1:] if text.startswith(" ") else text


def _is_doc(line):
    """Whether a line is a `##` comment. String -> Bool"""
    return line.startswith(DOC) and not line.startswith(DOC + "#")


def _opening_doc(lines):
    """The `##` block a file opens with, or "". [String] -> String"""
    block = []
    for line in lines:
        if not _is_doc(line):
            break
        block.append(_doc_text(line))
    return "\n".join(block).strip()


def _doc_above(lines, index):
    """The `##` block directly above line `index`, or "".
    [String] -> Int -> String"""
    block = []
    k = index - 1
    while k >= 0 and _is_doc(lines[k]):
        block.append(_doc_text(lines[k]))
        k -= 1
    # A block that opens the file is the module's, not the item's.
    if k < 0:
        return ""
    return "\n".join(reversed(block)).strip()


def _header(lines, index):
    """A definition's header: from `public def` to the `:` that opens its
    body, joined onto one line. [String] -> Int -> String"""
    text = ""
    for line in lines[index:]:
        text += (" " if text else "") + line.strip()
        depth = text.count("(") - text.count(")")
        if depth == 0 and text.endswith(":"):
            return text[:-1].rstrip()
    raise ValueError(f"no end to the header on line {index + 1}")


def _items(path):
    """What one file exports. Path -> [Item]"""
    lines = path.read_text().splitlines()
    items = []
    for index, line in enumerate(lines):
        if not line.startswith("public"):
            continue
        doc = _doc_above(lines, index)
        if SIGNATURE.match(line):
            name = SIGNATURE.match(line).group(1)
            signature = line[len("public"):].strip()
            kind = "function"
        elif DEFINITION.match(line):
            name = DEFINITION.match(line).group(1)
            signature = _header(lines, index)[len("public"):].strip()
            kind = "function"
        elif VALUE.match(line):
            name = VALUE.match(line).group(1)
            signature = line[len("public"):].strip()
            kind = "value"
        else:
            raise ValueError(f"{path}:{index + 1}: a public line not understood: {line}")
        items.append(Item(kind, name, signature, doc, path.name, index + 1))
    return items


def read_module(directory):
    """One module, from its Pyking half and its external half -- either
    may be missing. Path -> Module?"""
    name = directory.name
    halves = [directory / f"{name}.pyk", directory / f"{name}_external.pyk"]
    present = [path for path in halves if path.is_file()]
    if not present:
        return None
    openings = [_opening_doc(path.read_text().splitlines()) for path in present]
    module = Module(name, "\n\n".join(text for text in openings if text),
                    files=[path.name for path in present], directory=directory)
    for path in present:
        module.items.extend(_items(path))
    module.items.sort(key=lambda item: (item.kind != "value", item.name))
    return module


def read_modules(lib):
    """Every module in a lib/ directory, by name. Path -> [Module]"""
    found = (read_module(directory) for directory in sorted(Path(lib).iterdir())
             if directory.is_dir())
    return [module for module in found if module is not None]


def problems(modules):
    """What is undocumented: a module with no `##` description, or one
    described in both halves, and an exported item with no `##` block
    above it. [Module] -> [String]"""
    out = []
    for module in modules:
        if not module.description:
            out.append(f"lib/{module.name}: no `##` block opens "
                       + " or ".join(module.files))
        directory = Path("lib") / module.name
        described = [name for name in module.files
                     if _opening_doc((module.directory / name).read_text().splitlines())]
        if len(described) > 1:
            out.append(f"lib/{module.name}: described in both {' and '.join(described)}; "
                       "keep the module's `##` block in one of them")
        for item in module.items:
            if not item.doc:
                out.append(f"{directory / item.file}:{item.line}: "
                           f"`{item.name}` has no `##` block above it")
    return out


def _fence(code):
    """A Pyking block that is shown, not run. String -> String"""
    return f"```pyking norun\n{code}\n```"


def module_page(module):
    """One module's page, as Markdown: its description, how to import
    it, then each value and function with its signature and its doc.
    Module -> String"""
    summary = module.summary().replace('"', '\\"')
    parts = [
        "---",
        f"title: {module.name}",
        f'description: "{summary}"',
        "---",
        "",
        module.description,
        "",
        _fence(f"import {module.name}"),
    ]
    for kind, heading in (("value", "Values"), ("function", "Functions")):
        items = [item for item in module.items if item.kind == kind]
        if not items:
            continue
        parts += ["", f"## {heading}"]
        for item in items:
            parts += ["", f"### `{item.name}`", "", _fence(item.signature), "", item.doc]
    return "\n".join(parts).rstrip() + "\n"


def index_page(modules):
    """The section's overview: every module with its first sentence.
    [Module] -> String"""
    rows = "\n".join(f"| [`{module.name}`](./{module.name}/) | {module.summary()} |"
                     for module in modules)
    return f"""---
title: Libraries
description: The standard library that comes with Pyking.
sidebar:
  label: Overview
  order: 0
---

The standard library comes with every installation of Pyking. A program
uses a module by importing it, and needs no flag to find it:

```pyking
import io

io.write("Hello, ")
io.write_line("libraries")
```

| Module | |
|---|---|
{rows}

These pages are generated from the libraries' own source, in `lib/`.
"""


def write_pages(modules, directory):
    """Writes the overview and one page per module into directory.
    [Module] -> Path -> ()"""
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "index.md").write_text(index_page(modules))
    for module in modules:
        (directory / f"{module.name}.md").write_text(module_page(module))


LIB = Path(__file__).resolve().parent.parent.parent / "lib"


def main(argv=None):
    """Prints what is undocumented, and exits nonzero if anything is.
    [String]? -> ()"""
    argv = sys.argv[1:] if argv is None else argv
    lib = Path(argv[0]) if argv else LIB
    found = problems(read_modules(lib))
    for line in found:
        print(line)
    raise SystemExit(1 if found else 0)


if __name__ == "__main__":
    main()
