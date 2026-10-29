#!/usr/bin/env python3
"""The highlight suite: `pyk highlight`, which writes Pyking code
coloured for a slide, and the browser's `runtime.highlight`, which
writes the same.

What it checks:

  fixtures  every case in CASES is `pyk highlight` run on a file in
            tests/highlight/ with some options, compared byte for byte
            with tests/highlight/expected/<name>: a program with every
            class of span, a fragment that does not lex as a whole, a
            program indented with non-breaking spaces, and a notebook
            with every kind of block -- in HTML, RTF and text, each
            theme, font, size, background and spacing, and a notebook's
            page, whole and single blocks.
  shapes    what every HTML, RTF and text output must be whatever the
            case: a <pre> with inline styles and no class, ASCII; a
            complete, balanced RTF document; text that is the source
            again once its non-breaking spaces are ordinary ones, and a
            program that still runs and prints the same.
  notebook  split mode's files, a notebook's JSON written the same as
            its Markdown, the whole page's head, and the blocks counted.
  errors    every refusal's message, exactly.
  palette   the colours, read out of tools/webrun/assets/pyking-monaco.js
            -- the playground's own `pyking-light` and `pyking-dark` --
            and compared with what `pyk highlight` writes for each class,
            so the two cannot drift.
  browser   the compiler bundle and its worker under node, through
            PykingRuntime's `highlight`: the same HTML, RTF and text as
            the command line, the defaults, and the options it refuses.

Usage: python3 tests/test_highlight.py [--compiler CMD] [--bless]

`--bless` writes every fixture's expected output from what pyk writes
now; read the difference before committing it.

Functions:
    run(compiler, args) -- one run of pyk.
    check_fixtures(compiler, bless) -- every case against its fixture.
    check_shapes(compiler) -- what every output must be.
    check_notebook(compiler) -- split, JSON, the whole page.
    check_errors(compiler) -- every refusal.
    monaco_palettes() -- the themes, as pyking-monaco.js defines them.
    check_palette(compiler) -- the colours, against that file.
    check_browser(compiler) -- runtime.highlight under node.
    main(argv) -- the command-line entry point.
"""

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import suite  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
HERE = REPO / "tests" / "highlight"
EXPECTED = HERE / "expected"
MONACO = REPO / "tools" / "webrun" / "assets" / "pyking-monaco.js"
WORKER = REPO / "tools" / "webrun" / "assets" / "pyking-worker.js"
RUNTIME = REPO / "tools" / "webrun" / "assets" / "pyking-runtime.js"
STYLESHEET = REPO / "tools" / "notebook" / "assets" / "notebook.css"
DEFAULT_COMPILER = str(REPO / "pyk")
NBSP = "\u00a0"
TIMEOUT = 120

# Each case: the expected file's name, the input under tests/highlight/,
# and the options. A whole notebook's HTML is compared from its <body>
# on: its head holds the notebook's stylesheet, checked on its own.
CASES = [
    ("every_class.html", "every_class.pyk", []),
    ("every_class.html_flag.html", "every_class.pyk", ["--html", "--theme", "light"]),
    ("every_class.dark.html", "every_class.pyk",
     ["--theme", "dark", "--background", "theme", "--size", "18", "--font", "Fira Code"]),
    ("every_class.colour.html", "every_class.pyk", ["--background", "#F0F0E0", "--spaces", "all"]),
    ("every_class.none.html", "every_class.pyk", ["--spaces", "none", "--font", "Courier New"]),
    ("every_class.rtf", "every_class.pyk", ["--rtf"]),
    ("every_class.dark.rtf", "every_class.pyk",
     ["--rtf", "--theme", "dark", "--size", "24", "--background", "theme"]),
    ("every_class.all.rtf", "every_class.pyk", ["--rtf", "--spaces", "all", "--background", "#102030"]),
    ("every_class.none.rtf", "every_class.pyk", ["--rtf", "--spaces", "none", "--font", "Monaco"]),
    ("every_class.txt", "every_class.pyk", ["--text"]),
    ("every_class.all.txt", "every_class.pyk", ["--text", "--spaces", "all"]),
    ("every_class.none.txt", "every_class.pyk", ["--text", "--spaces", "none"]),
    ("fragment.html", "fragment.pyk", []),
    ("fragment.rtf", "fragment.pyk", ["--rtf"]),
    ("fragment.txt", "fragment.pyk", ["--text"]),
    ("nbsp.html", "nbsp.pyk", []),
    ("nbsp.rtf", "nbsp.pyk", ["--rtf", "--size", "32"]),
    ("nbsp.none.txt", "nbsp.pyk", ["--text", "--spaces", "none"]),
    ("book.block2.html", "book.md", ["--block", "2"]),
    ("book.block5.rtf", "book.md", ["--block", "5", "--rtf", "--theme", "dark"]),
    ("book.block1.txt", "book.md", ["--notebook", "whole", "--block", "1", "--text"]),
    ("book.page.html", "book.md", ["--notebook", "page"]),
    ("book.page.rtf", "book.md", ["--notebook", "page", "--rtf"]),
    ("book.page.txt", "book.md", ["--notebook", "page", "--text"]),
    ("book.whole.html", "book.md", ["--notebook", "whole"]),
    ("book.whole.dark.html", "book.md", ["--notebook", "whole", "--theme", "dark", "--background", "theme"]),
    ("book.whole.rtf", "book.md", ["--notebook", "whole", "--rtf", "--size", "20"]),
    ("book.whole.txt", "book.md", ["--notebook", "whole", "--text"]),
]

# The notebook's Pyking blocks: a cell, a norun fragment, an error cell,
# a readonly cell, a task's starting code and its solution.
BOOK_BLOCKS = 6


def run(compiler, args, cwd=None, env=None):
    """One run of pyk: (status, stdout, stderr). [String] -> [String] -> ..."""
    ran = subprocess.run(compiler + args, cwd=cwd, capture_output=True, timeout=TIMEOUT, env=env)
    return ran.returncode, ran.stdout.decode("utf-8", "replace"), ran.stderr.decode("utf-8", "replace")


class Checks:
    """Checks made, the failures among them, and each one's line."""

    def __init__(self):
        self.passed, self.failures, self.lines = 0, [], []

    def check(self, ok, label, detail=""):
        if ok:
            self.passed += 1
        else:
            self.failures.append(label + (f": {detail}" if detail else ""))
        self.lines.append(suite.case_line("highlight", ok, label, detail))
        return ok


def body_of(page):
    """A whole notebook's page from its <body> on. String -> String"""
    at = page.find("<body>")
    return page[at:] if at >= 0 else page


def first_difference(want, got):
    """Where two texts first differ, for a failure's detail. String -> String -> String"""
    for k, (a, b) in enumerate(zip(want, got)):
        if a != b:
            return f"at {k}: expected {want[k:k + 60]!r}, got {got[k:k + 60]!r}"
    return f"lengths {len(want)} and {len(got)}"


def check_fixtures(compiler, checks, bless):
    """Every case against its expected output, or writing it with --bless."""
    EXPECTED.mkdir(exist_ok=True)
    for name, source, options in CASES:
        status, out, err = run(compiler, ["highlight", str(HERE / source)] + options, cwd=REPO)
        label = f"{name}: pyk highlight {source} {' '.join(options)}".rstrip()
        if not checks.check(status == 0, label + " succeeds", err.strip()):
            continue
        if name.startswith("book.whole") and name.endswith(".html"):
            out = body_of(out)
        path = EXPECTED / name
        if bless:
            path.write_bytes(out.encode("utf-8"))
        want = path.read_bytes().decode("utf-8") if path.exists() else None
        checks.check(want == out, label + " is as expected",
                     "no fixture; run with --bless" if want is None else first_difference(want, out))


def check_html(checks, label, html):
    """What every HTML snippet is: a <pre> with the font, `white-space:
    pre` and the colour inline, spans with a style and nothing else, no
    class or stylesheet, ASCII."""
    checks.check(re.fullmatch(r"<pre style=\"font-family:'[^']+',monospace;white-space:pre;color:#[0-9a-f]{6}"
                              r"(;background:#[0-9a-f]{6})?(;font-size:\d+pt)?\">.*</pre>\n?", html, re.S)
                 is not None, label + ": a <pre> with its style inline", html[:120])
    checks.check("class=" not in html and "<style" not in html, label + ": no class and no stylesheet")
    tags = set(re.findall(r"<(/?[a-z]+)", html))
    checks.check(tags <= {"pre", "/pre", "span", "/span"}, label + ": only <pre> and <span>", str(tags))
    checks.check(all(re.fullmatch(r"color:#[0-9a-f]{6}(;font-style:italic)?", s)
                     for s in re.findall(r"<span style=\"([^\"]*)\"", html)),
                 label + ": each span only a colour, and italic")
    checks.check(html.isascii(), label + ": ASCII, every other character a reference")


def rtf_balanced(text):
    """Whether an RTF document's braces balance, escapes aside. String -> Bool"""
    depth = 0
    k = 0
    while k < len(text):
        c = text[k]
        if c == "\\":
            k += 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth < 0:
                return False
        k += 1
    return depth == 0


def check_rtf(checks, label, rtf):
    """What every RTF output is: one balanced {\\rtf1 ...} group, a font
    and a colour table, ASCII."""
    checks.check(rtf.startswith("{\\rtf1\\ansi") and rtf.rstrip("\n").endswith("}"),
                 label + ": one {\\rtf1 ...} document")
    checks.check(rtf_balanced(rtf), label + ": its braces balance")
    checks.check("{\\fonttbl{\\f0\\fmodern\\fcharset0 " in rtf and "{\\colortbl;\\red" in rtf,
                 label + ": a font table and a colour table")
    checks.check(rtf.isascii(), label + ": ASCII, every other character \\uN? or \\~")


def plain(text):
    """Text with its non-breaking spaces ordinary ones. String -> String"""
    return text.replace(NBSP, " ")


def check_shapes(compiler, checks):
    """What every output is, whatever the options; and the text a
    program, written with non-breaking spaces, that still runs."""
    source = (HERE / "every_class.pyk").read_text(encoding="utf-8")
    for options in ([], ["--theme", "dark"], ["--background", "theme", "--size", "12"], ["--spaces", "all"]):
        for name in ("every_class.pyk", "fragment.pyk", "nbsp.pyk"):
            _, html, _ = run(compiler, ["highlight", str(HERE / name)] + options)
            check_html(checks, f"{name} {' '.join(options)} html".replace("  ", " "), html)
            _, rtf, _ = run(compiler, ["highlight", str(HERE / name), "--rtf"] + options)
            check_rtf(checks, f"{name} {' '.join(options)} rtf".replace("  ", " "), rtf)
    _, text, _ = run(compiler, ["highlight", str(HERE / "every_class.pyk"), "--text"])
    checks.check(plain(text) == source, "text: the source again, its non-breaking spaces ordinary",
                 first_difference(source, plain(text)))
    indents = [line[:len(line) - len(line.lstrip(NBSP))] for line in text.split("\n")]
    checks.check(all(set(i) <= {NBSP} for i in indents) and any(indents),
                 "text: indentation is non-breaking spaces")
    checks.check(" " in text and all(NBSP not in line.lstrip(NBSP) for line in text.split("\n")),
                 "text: and only indentation, by default")
    _, every, _ = run(compiler, ["highlight", str(HERE / "every_class.pyk"), "--text", "--spaces", "all"])
    outside = re.sub(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'', "", every)
    checks.check(" " not in outside and plain(every) == source,
                 "text --spaces all: no ordinary space left outside a literal")
    literals = re.findall(r'"(?:[^"\\]|\\.)*"', every)
    checks.check(literals == re.findall(r'"(?:[^"\\]|\\.)*"', source),
                 "and a String literal keeps its spaces as written", literals[:3])
    _, none, _ = run(compiler, ["highlight", str(HERE / "every_class.pyk"), "--text", "--spaces", "none"])
    checks.check(none == source, "text --spaces none: the source itself")
    nbsp = (HERE / "nbsp.pyk").read_text(encoding="utf-8")
    _, back, _ = run(compiler, ["highlight", str(HERE / "nbsp.pyk"), "--text", "--spaces", "none"])
    checks.check(back == plain(nbsp), "a non-breaking indentation read as spaces")
    _, again, _ = run(compiler, ["highlight", str(HERE / "nbsp.pyk"), "--text"])
    checks.check(again == nbsp, "and written back as it was")
    _, spaced, _ = run(compiler, ["highlight", str(HERE / "nbsp.pyk")])
    with tempfile.TemporaryDirectory(prefix="pyk-highlight-") as directory:
        ordinary = Path(directory) / "ordinary.pyk"
        ordinary.write_text(plain(nbsp), encoding="utf-8")
        _, ordinary_html, _ = run(compiler, ["highlight", str(ordinary)])
        checks.check(spaced == ordinary_html, "a program indented either way highlights the same")
        tabbed = Path(directory) / "tabbed.pyk"
        tabbed.write_text(source.replace("    ", "\t"), encoding="utf-8")
        _, tabs, _ = run(compiler, ["highlight", str(tabbed), "--text", "--spaces", "none"])
        checks.check(tabs == source, "a tab is four spaces")
        crlf = Path(directory) / "crlf.pyk"
        crlf.write_bytes(source.replace("\n", "\r\n").encode("utf-8"))
        _, html_crlf, _ = run(compiler, ["highlight", str(crlf)])
        _, html_lf, _ = run(compiler, ["highlight", str(HERE / "every_class.pyk")])
        checks.check(html_crlf == html_lf, "a carriage return is dropped")
        _, want, _ = run(compiler, [str(HERE / "every_class.pyk")])
        for options in ([], ["--spaces", "all"], ["--spaces", "none"]):
            copied = Path(directory) / "copied.pyk"
            _, written, _ = run(compiler, ["highlight", str(HERE / "every_class.pyk"), "--text",
                                           "-o", str(copied)] + options)
            status, got, err = run(compiler, [str(copied)])
            checks.check(status == 0 and got == want,
                         f"the text {' '.join(options) or 'by default'} runs, and prints the same",
                         err.strip() or first_difference(want, got))
        empty = Path(directory) / "empty.pyk"
        empty.write_text("", encoding="utf-8")
        status, out, _ = run(compiler, ["highlight", str(empty), "--text"])
        checks.check(status == 0 and out == "", "an empty program is empty text")
        status, out, _ = run(compiler, ["highlight", str(empty)])
        checks.check(status == 0 and out.startswith("<pre style=") and out.endswith("></pre>\n"),
                     "and an empty <pre>", out)
        out_file = Path(directory) / "out.html"
        status, out, _ = run(compiler, ["highlight", str(HERE / "every_class.pyk"), "-o", str(out_file)])
        checks.check(status == 0 and out == "" and out_file.read_text() == html_lf,
                     "--output writes the file, and nothing on standard output")
        status, out, _ = run(compiler, ["highlight", str(HERE / "every_class.pyk"), "-o", "-"])
        checks.check(out == html_lf, "-o - is standard output")


def check_notebook(compiler, checks):
    """A notebook's blocks: split mode's files, each its own block; a
    notebook's JSON written as its Markdown; the whole page's head."""
    book = HERE / "book.md"
    with tempfile.TemporaryDirectory(prefix="pyk-highlight-") as directory:
        for extension, flag in ((".html", []), (".rtf", ["--rtf"]), (".txt", ["--text"])):
            status, out, err = run(compiler, ["highlight", str(book), "--output-dir", directory] + flag)
            files = sorted(p.name for p in Path(directory).glob("book-*" + extension))
            want = [f"book-{n}{extension}" for n in range(1, BOOK_BLOCKS + 1)]
            checks.check(status == 0 and sorted(files) == sorted(want),
                         f"split{extension}: one file per Pyking block, numbered from 1", err.strip() or str(files))
            checks.check(out.splitlines() == [f"Wrote {Path(directory) / name}" for name in want],
                         f"split{extension}: says what it wrote", out)
            for n in range(1, BOOK_BLOCKS + 1):
                _, block, _ = run(compiler, ["highlight", str(book), "--block", str(n)] + flag)
                path = Path(directory) / f"book-{n}{extension}"
                checks.check(path.exists() and path.read_text(encoding="utf-8") == block,
                             f"split{extension}: book-{n} is --block {n}")
        copy = Path(directory) / "beside.md"
        shutil.copy(book, copy)
        status, _, err = run(compiler, ["highlight", str(copy), "--notebook", "split"])
        checks.check(status == 0 and (Path(directory) / f"beside-{BOOK_BLOCKS}.html").exists(),
                     "split: beside the notebook by default", err.strip())
        status, _, err = run(compiler, ["highlight", "beside.md", "--text"], cwd=directory)
        checks.check(status == 0 and (Path(directory) / "beside-1.txt").exists(),
                     "split: a bare file name is beside it in the current directory", err.strip())
        json_book = Path(directory) / "book.json"
        status, _, err = run(compiler, ["notebook", str(book), "--to-json", "-o", str(json_book)])
        checks.check(status == 0, "the notebook as JSON", err.strip())
        for name, _, options in CASES:
            if not name.startswith("book."):
                continue
            _, from_md, _ = run(compiler, ["highlight", str(book)] + options)
            _, from_json, err = run(compiler, ["highlight", str(json_book)] + options)
            if name.startswith("book.whole") and name.endswith(".html"):
                from_md, from_json = body_of(from_md), body_of(from_json)
            checks.check(from_md == from_json and from_md != "",
                         f"{name}: the notebook's JSON writes what its Markdown does", err.strip())
    status, page, err = run(compiler, ["highlight", str(book), "--notebook", "whole"])
    head = page[:page.find("<body>")]
    checks.check(page.startswith("<!doctype html>") and '<meta charset="utf-8">' in head,
                 "whole: a standalone UTF-8 page")
    checks.check("<title>Highlighting a notebook</title>" in head, "whole: titled from the front matter")
    checks.check(STYLESHEET.read_text(encoding="utf-8") in head, "whole: with the notebook page's stylesheet")
    body = body_of(page)
    checks.check(body.count("<pre style=") == BOOK_BLOCKS + 2,
                 "whole: every Pyking block and the stdin and stdout blocks a snippet",
                 str(body.count("<pre style=")))
    checks.check("data-pyk-piece" not in body and "pkn-cell" not in body and "pkn-part" not in body,
                 "whole: no marker or notebook placeholder left")
    checks.check("<li>one</li>" in body and "<strong>Task.</strong>" in body and "Squares and greetings</h1>" in body,
                 "whole: the prose rendered by the notebook's renderer")
    checks.check("yes" not in body and "Right." not in body and "One task." not in body,
                 "whole: quizzes, answers and rules left out")
    _, rtf, _ = run(compiler, ["highlight", str(book), "--notebook", "whole", "--rtf"])
    checks.check("title:" not in rtf and "---" not in rtf, "whole --rtf: the front matter left out")
    check_rtf(checks, "whole --rtf", rtf)
    _, page_html, _ = run(compiler, ["highlight", str(book), "--notebook", "page"])
    pres = [line for line in page_html.split("\n") if line.startswith("<pre")]
    checks.check(len(pres) == BOOK_BLOCKS and "Squares" not in page_html,
                 "page: every Pyking block, and no prose", str(len(pres)))


ERRORS = [
    (["every_class.pyk", "--theme", "blue"], "--theme is light or dark, not 'blue'"),
    (["every_class.pyk", "--spaces", "some"], "--spaces is indent, all or none, not 'some'"),
    (["every_class.pyk", "--background", "red"], "--background is none, theme or a colour #rrggbb, not 'red'"),
    (["every_class.pyk", "--background", "#12345"], "--background is none, theme or a colour #rrggbb, not '#12345'"),
    (["every_class.pyk", "--size", "0"], "--size is a whole number of points from 1 to 1000, not '0'"),
    (["every_class.pyk", "--size", "12.5"], "--size is a whole number of points from 1 to 1000, not '12.5'"),
    (["every_class.pyk", "--font", "a;b"],
     "--font names a font in letters, digits, spaces, '-', '_' and '.', not 'a;b'"),
    (["every_class.pyk", "--theme"], "--theme needs a value"),
    (["every_class.pyk", "--html", "--rtf"], "--html and --rtf each say what is written, so only one may be given"),
    (["every_class.pyk", "--colour", "x"], "there is no option '--colour'; `pyk highlight --help` lists them"),
    ([], "names no file; `pyk highlight --help` says what it takes"),
    (["every_class.pyk", "fragment.pyk"], "takes one file"),
    (["missing.pyk"], "no such file: missing.pyk"),
    (["expected"], "expected is neither a Pyking program (.pyk) nor a notebook (.md, or .json)"),
    (["notes.txt"], "notes.txt is neither a Pyking program (.pyk) nor a notebook (.md, or .json)"),
    (["every_class.pyk", "--notebook", "whole"],
     "--notebook says how a notebook is written, and every_class.pyk is a program"),
    (["every_class.pyk", "--block", "1"], "--block picks a notebook's block, and every_class.pyk is a program"),
    (["every_class.pyk", "--output-dir", "."],
     "--output-dir is where a notebook's blocks are written, and every_class.pyk is a program"),
    (["book.md", "--notebook", "all"], "--notebook is split, page or whole, not 'all'"),
    (["book.md", "--block", "0"], "--block is a block's number, counted from 1, not '0'"),
    (["book.md", "--block", "7"], "--block 7: book.md has 6 pyking blocks, numbered from 1"),
    (["book.md", "--notebook", "split", "-o", "x.html"],
     "--notebook split writes one file per block, so --output-dir names where, not --output"),
    (["book.md", "--notebook", "page", "--output-dir", "."],
     "--output-dir is where --notebook split writes one file per block"),
    (["book.md", "--output-dir", "no-such-directory"], "no such directory: no-such-directory"),
    (["prose.md"], "prose.md has no pyking blocks"),
    (["bad.json"], "bad.json is not JSON"),
    (["other.json"], "other.json is not a notebook"),
]


def check_errors(compiler, checks):
    """Every refusal: status 1, `pyk highlight: <message>` on stderr,
    nothing on stdout."""
    with tempfile.TemporaryDirectory(prefix="pyk-highlight-") as directory:
        for name in ("every_class.pyk", "fragment.pyk", "book.md"):
            shutil.copy(HERE / name, Path(directory) / name)
        (Path(directory) / "notes.txt").write_text("print(1)\n")
        (Path(directory) / "expected").mkdir()
        (Path(directory) / "prose.md").write_text("# Only prose\n\n```python\nprint(1)\n```\n\n```stdout\n1\n```\n")
        (Path(directory) / "bad.json").write_text("{not json")
        (Path(directory) / "other.json").write_text('{"format": "something else"}')
        for args, message in ERRORS:
            status, out, err = run(compiler, ["highlight"] + args, cwd=directory)
            said = " ".join(err.split())
            want = "pyk highlight: " + message
            checks.check(status == 1 and out == "" and said.startswith(want),
                         f"refuses {' '.join(args) or 'no file'}", f"status {status}, said {said!r}")
        # Without node, a whole notebook's HTML cannot be rendered; its
        # RTF and text need no node.
        empty = Path(directory) / "bin"
        empty.mkdir()
        environment = dict(os.environ, PATH=str(empty))
        status, out, err = run(compiler, ["highlight", "book.md", "--notebook", "whole"], cwd=directory, env=environment)
        checks.check(status == 1 and out == "" and "node was not found" in " ".join(err.split()),
                     "refuses a whole notebook's HTML without node", err.strip())
        status, _, err = run(compiler, ["highlight", "book.md", "--notebook", "whole", "--rtf"], cwd=directory,
                             env=environment)
        checks.check(status == 0, "a whole notebook's RTF needs no node", err.strip())
    status, out, _ = run(compiler, ["highlight", "--help"])
    checks.check(status == 0 and out.startswith("Usage: pyk highlight") and "--notebook whole" in out,
                 "pyk highlight --help")
    _, out, err = run(compiler, [])
    checks.check("pyk highlight <file> [options]" in out + err, "pyk's usage names pyk highlight")
    _, full, _ = run(compiler, ["--help"])
    checks.check("`pyk highlight <file>` writes" in full, "pyk --help says what it does")


# --- the palette -------------------------------------------------------------

# The Monaco token each class is coloured as in pyking-monaco.js.
MONACO_TOKENS = {
    "comment": "comment", "string": "string", "number": "number", "constant": "constant",
    "keyword": "keyword", "type": "type", "function": "function", "builtin": "predefined",
    "operator": "operator",
}


def monaco_palettes():
    """The two themes pyking-monaco.js defines: for each, the foreground,
    the background, and each class's colour and whether it is italic.
    () -> {String: {foreground, background, classes: {String: (String, Bool)}}}"""
    text = MONACO.read_text(encoding="utf-8")
    rules_text = re.search(r"const rules = \(c\) => \[(.*?)\];", text, re.S).group(1)
    rules = {}
    for token, key, rest in re.findall(r'\{ token: "([^"]+)", foreground: c\.(\w+)([^}]*)\}', rules_text):
        rules[token] = (key, "italic" in rest)
    themes = {}
    for name, body in re.findall(r'defineTheme\("pyking-(\w+)", \{(.*?)\n  \}\);', text, re.S):
        colours = dict(re.findall(r'(\w+): "([0-9a-f]{6})"', re.search(r"rules: rules\(\{(.*?)\}\)", body, re.S).group(1)))
        background = re.search(r'"editor\.background": "(#[0-9a-f]{6})"', body).group(1)
        foreground = re.search(r'"editor\.foreground": "(#[0-9a-f]{6})"', body).group(1)
        classes = {}
        for kind, token in MONACO_TOKENS.items():
            key, italic = rules[token]
            classes[kind] = ("#" + colours[key], italic)
        themes[name] = {"foreground": foreground, "background": background, "classes": classes}
    return themes


# A piece of every_class.pyk of each class, and the class it is.
SAMPLES = [
    ("# Every class of span pyk highlight colours, in a program that runs.", "comment"),
    ("def", "keyword"), ("match", "keyword"), ("use", "keyword"), ("and", "keyword"),
    ("Shape", "type"), ("Float", "type"), ("Circle", "type"),
    ("true", "constant"), ("false", "constant"),
    ("0x1F", "number"), ("0b101", "number"), ("3.0", "number"), ("2.0e1", "number"),
    ("&quot;big: &quot;", "string"), ("'a'", "string"),
    ("area", "function"), ("describe", "function"),
    ("print", "builtin"), ("range", "builtin"), ("len", "builtin"), ("string", "builtin"),
    (":=", "operator"), ("&lt;&lt;", "operator"), ("^", "operator"), ("!=", "operator"), ("%", "operator"),
]


def check_palette(compiler, checks):
    """Each class's colour, and the foreground and background, as
    pyking-monaco.js has them, in what pyk highlight writes."""
    themes = monaco_palettes()
    checks.check(set(themes) == {"light", "dark"}, "pyking-monaco.js defines pyking-light and pyking-dark",
                 str(sorted(themes)))
    for theme, palette in themes.items():
        _, html, _ = run(compiler, ["highlight", str(HERE / "every_class.pyk"), "--theme", theme,
                                    "--background", "theme"])
        checks.check(f"color:{palette['foreground']};background:{palette['background']}" in html.split(">")[0],
                     f"{theme}: the editor's foreground and background")
        spans = {}
        for style, text in re.findall(r'<span style="([^"]*)">([^<]*)</span>', html):
            spans.setdefault(text, set()).add(style)
        for text, kind in SAMPLES:
            colour, italic = palette["classes"][kind]
            want = f"color:{colour}" + (";font-style:italic" if italic else "")
            checks.check(spans.get(text) == {want}, f"{theme}: {text} is a {kind}, {want}", str(spans.get(text)))
        for text in ("count", "(", ",", ":", "mutation"):
            checks.check(text not in spans, f"{theme}: {text} is plain")
        _, rtf, _ = run(compiler, ["highlight", str(HERE / "every_class.pyk"), "--theme", theme, "--rtf"])
        table = re.search(r"\{\\colortbl;(.*?)\}", rtf).group(1)
        colours = ["#%02x%02x%02x" % tuple(int(v) for v in m)
                   for m in re.findall(r"\\red(\d+)\\green(\d+)\\blue(\d+);", table)]
        wanted = {palette["foreground"]} | {c for c, _ in palette["classes"].values()}
        checks.check(set(colours) == wanted and colours[0] == palette["foreground"],
                     f"{theme}: the RTF's colour table", str(colours))


# --- the browser -------------------------------------------------------------

DRIVER = r"""// The compiler bundle and its worker under node, reached through
// PykingRuntime as a page reaches them: the runtime's Worker is this
// same global, which the worker script has set up.
import fs from "node:fs";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const plan = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const report = console.log.bind(console);
globalThis.self = globalThis;
globalThis.require = createRequire(import.meta.url);
let toPage = null;
self.postMessage = (message) => toPage?.({ data: message });
self.importScripts = () => (0, eval)(fs.readFileSync(plan.bundle, "utf8"));
globalThis.XMLHttpRequest = class {
  open(method, url) { this.url = url; }
  send() {
    this.status = 200;
    this.responseText = JSON.stringify({ bundle: "pyking.js", stamp: null });
  }
};
(0, eval)(fs.readFileSync(plan.worker, "utf8"));
const workerReceives = self.onmessage;
globalThis.Worker = class {
  constructor() { toPage = (event) => this.onmessage?.(event); }
  postMessage(message) { setTimeout(() => workerReceives({ data: message }), 0); }
  terminate() {}
};
const { PykingRuntime } = await import(pathToFileURL(plan.runtime).href);
const runtime = new PykingRuntime({ pykingURL: "http://test/pyking/", workerURL: "worker.js" });
const answers = [];
for (const request of plan.requests) {
  try {
    const value = request.options === undefined
      ? await runtime.highlight(request.source)
      : await runtime.highlight(request.source, request.options);
    answers.push({ ok: true, value });
  } catch (error) {
    answers.push({ ok: false, message: error.message });
  }
}
const direct = JSON.parse(self.pykHighlight(plan.requests[0].source, ""));
report(JSON.stringify({ answers, direct, ready: runtime.isReady }));
"""

# Options for the browser, and the command line's flags for the same.
BROWSER = [
    (None, []),
    ({}, []),
    ({"theme": "dark", "font": "Fira Code", "size": 18, "background": "theme", "spaces": "all"},
     ["--theme", "dark", "--font", "Fira Code", "--size", "18", "--background", "theme", "--spaces", "all"]),
    ({"theme": "light", "size": "24", "background": "#ABCDEF", "spaces": "none"},
     ["--size", "24", "--background", "#ABCDEF", "--spaces", "none"]),
    ({"theme": None, "font": None, "size": None, "background": None, "spaces": None}, []),
    ({"background": "none", "spaces": "indent", "font": "Menlo"}, []),
]

BROWSER_ERRORS = [
    ({"theme": "blue"}, "theme is light or dark, not 'blue'"),
    ({"size": 12.5}, "size is a whole number of points from 1 to 1000, not '12.5'"),
    ({"size": 0}, "size is a whole number of points from 1 to 1000, not '0'"),
    ({"background": "red"}, "background is none, theme or a colour #rrggbb, not 'red'"),
    ({"spaces": "some"}, "spaces is indent, all or none, not 'some'"),
    ({"font": "a;b"}, "font names a font in letters, digits, spaces, '-', '_' and '.', not 'a;b'"),
    ({"theme": 1}, "theme is a string"),
    ({"colour": "red"}, "highlight has no option 'colour'; it takes theme, font, size, background and spaces"),
    ([], "the options are an object: {theme, font, size, background, spaces}"),
]


def check_browser(compiler, checks):
    """runtime.highlight under node: what the command line writes, the
    defaults, and the options it refuses."""
    bundle = REPO / "share" / "pyking.js"
    if not checks.check(bundle.exists(), "the compiler bundle is built", f"no {bundle}; run make"):
        return
    sources = {name: (HERE / name).read_text(encoding="utf-8") for name in ("every_class.pyk", "fragment.pyk", "nbsp.pyk")}
    requests, expected = [], []
    for name, source in sources.items():
        for options, flags in BROWSER:
            request = {"source": source}
            if options is not None:
                request["options"] = options
            requests.append(request)
            outputs = {}
            for key, flag in (("html", "--html"), ("rtf", "--rtf"), ("text", "--text")):
                _, out, _ = run(compiler, ["highlight", str(HERE / name), flag] + flags)
                outputs[key] = out[:-1] if key == "html" else out
            expected.append((f"{name} {json.dumps(options)}", outputs))
    for options, message in BROWSER_ERRORS:
        requests.append({"source": "x = 1\n", "options": options})
    with tempfile.TemporaryDirectory(prefix="pyk-highlight-") as directory:
        plan = Path(directory) / "plan.json"
        plan.write_text(json.dumps({"bundle": str(bundle), "worker": str(WORKER), "runtime": str(RUNTIME),
                                    "requests": requests}))
        script = Path(directory) / "driver.mjs"
        script.write_text(DRIVER)
        try:
            ran = subprocess.run(["node", str(script), str(plan)], capture_output=True, text=True, timeout=TIMEOUT)
        except FileNotFoundError:
            checks.check(False, "node runs the browser checks", "node not found")
            return
    if not checks.check(ran.returncode == 0, "the bundle and its worker run under node", ran.stderr[-800:]):
        return
    result = json.loads(ran.stdout.strip().splitlines()[-1])
    answers = result["answers"]
    checks.check(result["ready"], "highlight boots the compiler when it is not loaded")
    for (label, outputs), answer in zip(expected, answers):
        if not checks.check(answer["ok"], f"runtime.highlight {label} resolves", answer.get("message", "")):
            continue
        for key in ("html", "rtf", "text"):
            got = answer["value"].get(key)
            checks.check(got == outputs[key], f"runtime.highlight {label}: {key} as pyk highlight writes it",
                         first_difference(outputs[key], got or ""))
        checks.check(sorted(answer["value"]) == ["html", "rtf", "text"], f"runtime.highlight {label}: {{html, rtf, text}}")
    checks.check(result["direct"] == answers[0].get("value"), "pykHighlight with no options is the defaults")
    for (options, message), answer in zip(BROWSER_ERRORS, answers[len(expected):]):
        checks.check(not answer["ok"] and answer.get("message") == message,
                     f"runtime.highlight refuses {json.dumps(options)}", str(answer))


def main(argv):
    """The command-line entry point. [String] -> Int"""
    compiler, bless, rest = [DEFAULT_COMPILER], False, list(argv)
    while rest:
        flag = rest.pop(0)
        if flag == "--compiler" and rest:
            compiler = shlex.split(rest.pop(0))
        elif flag == "--bless":
            bless = True
        else:
            print("usage: test_highlight.py [--compiler CMD] [--bless]", file=sys.stderr)
            return 2
    checks = Checks()
    check_fixtures(compiler, checks, bless)
    check_shapes(compiler, checks)
    check_notebook(compiler, checks)
    check_errors(compiler, checks)
    check_palette(compiler, checks)
    check_browser(compiler, checks)
    for line in checks.lines:
        print(line)
    if checks.failures:
        print()
    for failure in checks.failures:
        print(f"highlight: FAILED {failure}")
    print(f"highlight: {len(CASES)} fixtures, the shapes, notebooks, {len(ERRORS)} refusals, "
          f"the palette and the browser.")
    suite.footer("highlight", checks.passed, len(checks.failures), f"{len(CASES)} fixtures")
    return 1 if checks.failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
