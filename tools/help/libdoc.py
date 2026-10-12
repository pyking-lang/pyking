#!/usr/bin/env python3
"""The library reference: reads the standard library in lib/ and writes
one Markdown page per module, for the help's "Libraries" section, which
the website and the playground's Help tab both show (help.py).

A module is a directory of lib/ holding `<name>.pyk`, `<name>_external.pyk`
or both. Its documentation is its `##` comments: a `##` block opening
either file describes the module, and a `##` block directly above a
`public` line describes what that line exports. A plain `#` comment is a
note for whoever maintains the library and is never published. What each
item is shown as is its own line of source, without `public`, so the
types are the ones the checker holds the library to.

An item's block is a summary paragraph, any further paragraphs, then
three sections, each a line `# Name`: `# Parameters`, a list of
`- name: text` in the order the parameters are written; `# Returns`,
what the function answers, left out where it answers `()`; and
`# Examples`, a ```` ```pyking ```` block followed by a ```` ```stdout ````
block holding exactly what it prints. Every example is run by
tests/test_site.py and its output compared. See tools/help/README.md.

Usage: python3 tools/help/libdoc.py [LIB]    print what is undocumented

Data structures:
    Example -- one example: its fence's words, its code, what it prints.
    Item -- one exported name: its kind, name, signature, doc and sections.
    Module -- one library: its name, its description, its items.

Functions:
    read_modules(lib) -- every module in a lib/ directory.
    read_module(directory) -- one module, from its one or two files.
    problems(modules) -- what is undocumented or wrongly documented.
    examples(modules) -- every example, with where it is written.
    module_page(module) -- one module's page, as Markdown.
    index_page(modules) -- the section's overview page, as Markdown.
    write_pages(modules, directory) -- writes every page into directory.
"""

import html
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

DOC = "##"

# `public def name : type` -- a signature, from either half.
SIGNATURE = re.compile(r"^public\s+def\s+([A-Za-z_]\w*)\s*:")
# `public def name(...)` -- a definition, or a declaration naming its
# parameters.
DEFINITION = re.compile(r"^public\s+def\s+([A-Za-z_]\w*)\s*\(")
# `public NAME: T = value` -- a value.
VALUE = re.compile(r"^public\s+([A-Za-z_]\w*)\s*:")
# `def name : type`, public or not, in a declaration half: the form
# lib/ no longer uses.
UNNAMED = re.compile(r"^(?:public\s+)?def\s+[A-Za-z_]\w*\s*:")

SECTIONS = ("Parameters", "Returns", "Examples")


@dataclass
class Example:
    """One example: the words after ```pyking (`norun`, `stdin = ...`),
    its code, and what it prints, or None where no stdout block follows."""
    words: str
    code: str
    stdout: str


@dataclass
class Item:
    """One exported name. `kind` is "function" or "value"; `text` is the
    doc before its sections, `params` the documented (name, text) pairs,
    `returns` the Returns section, `examples` the Examples, and
    `param_lines` the Parameters entries as written."""
    kind: str
    name: str
    signature: str
    doc: str
    file: str
    line: int
    text: str = ""
    params: list = field(default_factory=list)
    returns: str = ""
    examples: list = field(default_factory=list)
    unknown: list = field(default_factory=list)
    param_lines: list = field(default_factory=list)


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
    body, joined onto one line -- or the whole line, for a declaration,
    which has no body. [String] -> Int -> String"""
    text = ""
    for line in lines[index:]:
        text += (" " if text else "") + line.strip()
        depth = text.count("(") - text.count(")")
        if depth == 0 and text.endswith(":"):
            return text[:-1].rstrip()
        if depth == 0 and not text.endswith(":") and re.search(r"\)\s*->\s*\S", text):
            return text
    raise ValueError(f"no end to the header on line {index + 1}")


def _split_top(text):
    """Splits `text` at the commas not inside brackets. String -> [String]"""
    parts, depth, current = [], 0, ""
    for ch in text:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += ch
    if current.strip():
        parts.append(current.strip())
    return parts


def signature_parts(signature):
    """A function signature taken apart: its name, each parameter as
    (name, type, default or None), and its result type -- or None where
    the parameters are not named. String -> (String, [(String, String,
    String?)], String)?"""
    match = re.match(r"^def\s+(\w+)\s*\(", signature)
    if not match:
        return None
    depth, i = 1, match.end()
    while depth:
        depth += {"(": 1, ")": -1}.get(signature[i], 0)
        i += 1
    params = []
    for part in _split_top(signature[match.end():i - 1]):
        name, _, rest = part.partition(":")
        declared, _, default = rest.partition("=")
        params.append((name.strip(), declared.strip(), default.strip() or None))
    result = signature[i:].strip()
    result = result[2:].strip() if result.startswith("->") else "()"
    return match.group(1), params, result


def _sections(doc):
    """An item's doc split at its `# Name` lines: the text before them,
    and {name: text}. String -> (String, {String: String})"""
    text, found, current, fence = [], {}, None, False
    for line in doc.split("\n"):
        if line.startswith("```"):
            fence = not fence
        heading = re.match(r"^# (\w+)\s*$", line)
        if heading and not fence:
            current = heading.group(1)
            found[current] = []
            continue
        (found[current] if current else text).append(line)
    return "\n".join(text).strip(), {k: "\n".join(v).strip() for k, v in found.items()}


def _params(section):
    """The `- name: text` entries of a Parameters section, a line `- `a`,
    `b`: text` documenting several at once. String -> [(String, String)]"""
    entries = []
    for line in section.split("\n"):
        match = re.match(r"^- ((?:`\w+`(?:, )?)+): (.*)$", line)
        if match:
            for name in re.findall(r"`(\w+)`", match.group(1)):
                entries.append((name, match.group(2)))
        elif entries and line.startswith("  "):
            name, text = entries[-1]
            entries[-1] = (name, text + " " + line.strip())
    return entries


def _param_lines(section):
    """The Parameters section's entries as written, one per `- ` line,
    with its continuation lines joined on. String -> [String]"""
    lines = []
    for line in section.split("\n"):
        if line.startswith("- "):
            lines.append(line)
        elif lines and line.startswith("  "):
            lines[-1] += " " + line.strip()
    return lines


def _examples(section):
    """The examples in an Examples section: each ```pyking block, and the
    ```stdout block right after it if there is one. String -> [Example]"""
    found, lines, i = [], section.split("\n"), 0
    while i < len(lines):
        opening = re.match(r"^```(?:pyking|pyk)\b(.*)$", lines[i])
        if not opening:
            i += 1
            continue
        i += 1
        code = []
        while i < len(lines) and not lines[i].startswith("```"):
            code.append(lines[i])
            i += 1
        i += 1
        stdout = None
        if i < len(lines) and lines[i].startswith("```stdout"):
            i += 1
            out = []
            while i < len(lines) and not lines[i].startswith("```"):
                out.append(lines[i])
                i += 1
            i += 1
            stdout = "".join(line + "\n" for line in out)
        found.append(Example(opening.group(1).strip(), "\n".join(code) + "\n", stdout))
    return found


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
        text, sections = _sections(doc)
        items.append(Item(kind, name, signature, doc, path.name, index + 1,
                          text=text,
                          params=_params(sections.get("Parameters", "")),
                          param_lines=_param_lines(sections.get("Parameters", "")),
                          returns=sections.get("Returns", ""),
                          examples=_examples(sections.get("Examples", "")),
                          unknown=[s for s in sections if s not in SECTIONS]))
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


def _item_problems(where, item):
    """What is wrong with one item's documentation. String -> Item -> [String]"""
    out = [f"{where}: `{item.name}` has a section `# {name}`, which is none of "
           + ", ".join(SECTIONS) for name in item.unknown]
    if not item.text:
        out.append(f"{where}: `{item.name}` says nothing before its sections")
    if not item.examples:
        out.append(f"{where}: `{item.name}` has no example under `# Examples`")
    for example in item.examples:
        if example.stdout is None:
            out.append(f"{where}: an example of `{item.name}` has no ```stdout block after it")
    if item.kind != "function":
        return out
    parts = signature_parts(item.signature)
    if parts is None:
        return out + [f"{where}: `{item.name}` is declared `def {item.name} : ...`; "
                      "name its parameters: `def name(p: T, ...) -> R`"]
    _, params, result = parts
    named = [name for name, _, _ in params]
    documented = [name for name, _ in item.params]
    if documented != named:
        out.append(f"{where}: `{item.name}`'s Parameters list {documented or 'nothing'}, "
                   f"but its parameters are {named or 'none'}")
    if result != "()" and not item.returns:
        out.append(f"{where}: `{item.name}` answers {result} and has no `# Returns`")
    if result == "()" and item.returns:
        out.append(f"{where}: `{item.name}` answers () and has a `# Returns`")
    return out


def problems(modules):
    """What is undocumented or documented wrongly: a module with no `##`
    description, or one described in both halves; an exported item with
    no `##` block, or whose block lacks a summary, documents parameters
    the item does not have in another order, misses or has a Returns it
    should not, or has an example with no output to compare; and a
    declaration in the unnamed form. [Module] -> [String]"""
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
            where = f"{directory / item.file}:{item.line}"
            if not item.doc:
                out.append(f"{where}: `{item.name}` has no `##` block above it")
            else:
                out.extend(_item_problems(where, item))
        for name in module.files:
            for number, line in enumerate((module.directory / name).read_text().splitlines(), 1):
                if name.endswith("_external.pyk") and UNNAMED.match(line):
                    out.append(f"{directory / name}:{number}: a declaration names no "
                               "parameters; write `def name(p: T, ...) -> R`")
    return out


def examples(modules):
    """Every example, with the module and item it documents.
    [Module] -> [(Module, Item, Example)]"""
    return [(module, item, example) for module in modules
            for item in module.items for example in item.examples]


# --- the page ---

def _type_html(text):
    """A type, its built-in names and type variables marked.
    String -> String"""
    return re.sub(r"\b(Int|Float|String|Bool)\b", r'<span class="t">\1</span>',
                  html.escape(text, quote=False))


def signature_html(item):
    """The item's signature as HTML: `def`, its name, each parameter's
    name, type and default, and its result. Item -> String"""
    name = f'<span class="n">{html.escape(item.name)}</span>'
    if item.kind == "value":
        declared, _, value = item.signature[len(item.name):].lstrip(" :").partition("=")
        return (f"{name}: {_type_html(declared.strip())}"
                + (f" = {html.escape(value.strip())}" if value else ""))
    parts = signature_parts(item.signature)
    if parts is None:
        return f'<span class="k">def</span> {name} : ' + _type_html(
            item.signature.split(":", 1)[1].strip())
    _, params, result = parts
    shown = []
    for pname, declared, default in params:
        text = f'<span class="p">{html.escape(pname)}</span>: {_type_html(declared)}'
        if default is not None:
            text += f" = {html.escape(default)}"
        shown.append(text)
    one_line = ", ".join(shown)
    if len(item.signature) > 72:
        listed = "".join(f"\n    {p}," for p in shown)
        return f'<span class="k">def</span> {name}({listed}\n) -&gt; {_type_html(result)}'
    return f'<span class="k">def</span> {name}({one_line}) -&gt; {_type_html(result)}'


def _example_markdown(example):
    """An example as the page shows it: a cell, and what it prints shown
    under it where it prints anything. Example -> String"""
    words = f" {example.words}" if example.words else ""
    text = f"```pyking{words}\n{example.code}```"
    if example.stdout:
        text += f"\n\n```stdout visible = true\n{example.stdout}```"
    return text


def item_markdown(module, item):
    """One item, boxed: its name as a heading, its signature, what it
    does, its parameters, what it answers and its examples.
    Module -> Item -> String"""
    parts = ['<div class="pyk-api">', "", f"## {item.name}", "",
             f'<pre class="pyk-sig"><code>{signature_html(item)}</code></pre>', "",
             item.text or item.doc]
    if item.params:
        parts += ["", '<p class="pyk-api-label">Parameters</p>', ""]
        parts += item.param_lines
    if item.returns:
        parts += ["", '<p class="pyk-api-label">Returns</p>', "", item.returns]
    if item.examples:
        parts += ["", '<p class="pyk-api-label">Example</p>']
        for example in item.examples:
            parts += ["", _example_markdown(example)]
    return "\n".join(parts + ["", "</div>"])


def module_page(module):
    """One module's page, as Markdown: its description, how to import
    it, then each value and each function in a box. Module -> String"""
    summary = module.summary().replace('"', '\\"')
    parts = [
        "---",
        f"title: {module.name}",
        f'description: "{summary}"',
        "---",
        "",
        module.description,
        "",
        f"```pyking norun\nimport {module.name}\n```",
    ]
    for item in module.items:
        parts += ["", item_markdown(module, item)]
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
