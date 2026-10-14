#!/usr/bin/env python3
"""Writes tinyweb's page into each native implementation.

A program that calls `tinyweb.web_init` serves its own page, and every
implementation that can serve one carries the page with it, so a
compiled program needs nothing beside itself to show it. The page is two
files in lib/tinyweb/, tinyweb_page.html and tinyweb_page.js -- the same
renderer the iweb page, the playground and the notebook mount -- and
this script copies both, as string literals, into the block each
implementation marks with `BEGIN tinyweb page` and `END tinyweb page`.

The web24 implementation, tinyweb_external_browser.js, draws without
the page script, but its look is the page's: the block of
tinyweb_page.js between `BEGIN tinyweb style` and `END tinyweb style` is
copied into it as it is.

    python3 tools/tinyweb/embed_page.py           rewrite every block
    python3 tools/tinyweb/embed_page.py --check   say which are stale

tests/test_tinyweb.py runs the check, so a change to the page that was
not copied fails `make test`. See docs/libraries.md, "tinyweb".

Functions:
  literal_lines(language, text) -- the page as that language's literals.
  block(language, html, js) -- the text between the two markers.
  embedded(path, html, js) -- the file with its block rewritten.
  style_block(js) -- the page script's style block, markers included.
  with_style(path, js) -- web24's file with its style block rewritten.
  main(argv) -- rewrites or checks every implementation.
"""

import json
import sys
from pathlib import Path

LIB = Path(__file__).resolve().parents[2] / "lib" / "tinyweb"
PAGE_HTML = LIB / "tinyweb_page.html"
PAGE_JS = LIB / "tinyweb_page.js"
BEGIN = "BEGIN tinyweb page"
END = "END tinyweb page"
NOTE = "written by tools/tinyweb/embed_page.py from tinyweb_page.html and tinyweb_page.js; do not edit"

BROWSER = LIB / "tinyweb_external_browser.js"
STYLE_BEGIN = "// BEGIN tinyweb style"
STYLE_END = "// END tinyweb style"

# Each implementation, the language its block is written in.
IMPLEMENTATIONS = {
    "tinyweb_external.py": "python",
    "tinyweb_external_node.js": "javascript",
    "tinyweb_external.ml": "ocaml",
    "tinyweb_external.c": "c",
    "TinywebExternal.java": "java",
}


def escaped(language, line):
    """One line of the page as a string literal of `language`.
    String -> String -> String"""
    text = json.dumps(line)
    if language == "c":
        # A C89 compiler reads `??=` and its kind as trigraphs.
        text = text.replace("??", "?\\?")
    if language == "ocaml":
        # OCaml's escapes are JSON's, but for the \uXXXX one, which an
        # ASCII page never needs.
        assert "\\u" not in text, line
    return text


def literal_lines(language, text):
    """The page as one literal per line, each ending in its newline.
    String -> String -> [String]"""
    lines = text.splitlines(keepends=True)
    return [escaped(language, line) for line in lines]


def block(language, html, js):
    """What goes between the two markers: the page's two files as two
    values the implementation serves. String -> String -> String -> String"""
    h, j = literal_lines(language, html), literal_lines(language, js)
    if language == "python":
        out = [f"# {NOTE}"]
        out.append("_PAGE_HTML = \"\".join([")
        out += [f"    {line}," for line in h]
        out.append("])")
        out.append("_PAGE_JS = \"\".join([")
        out += [f"    {line}," for line in j]
        out.append("])")
    elif language == "javascript":
        out = [f"// {NOTE}"]
        out.append("const PAGE_HTML = [")
        out += [f"  {line}," for line in h]
        out.append("].join(\"\");")
        out.append("const PAGE_JS = [")
        out += [f"  {line}," for line in j]
        out.append("].join(\"\");")
    elif language == "ocaml":
        out = [f"(* {NOTE} *)"]
        out.append("let page_html = String.concat \"\" [")
        out += [f"  {line};" for line in h]
        out.append("]")
        out.append("let page_js = String.concat \"\" [")
        out += [f"  {line};" for line in j]
        out.append("]")
    elif language == "c":
        out = [f"/* {NOTE} */"]
        out.append("static const char *const tinyweb_page_html[] = {")
        out += [f"    {line}," for line in h]
        out.append("    0")
        out.append("};")
        out.append("static const char *const tinyweb_page_js[] = {")
        out += [f"    {line}," for line in j]
        out.append("    0")
        out.append("};")
    elif language == "java":
        out = [f"    // {NOTE}"]
        out.append("    private static final String[] PAGE_HTML = {")
        out += [f"        {line}," for line in h]
        out.append("    };")
        out.append("    private static final String[] PAGE_JS = {")
        out += [f"        {line}," for line in j]
        out.append("    };")
    else:
        raise ValueError(language)
    return "\n".join(out) + "\n"


def embedded(path, html, js):
    """The text of the implementation at `path` with its block rewritten,
    or None where it has no block. Path -> String -> String -> String?"""
    text = path.read_text()
    lines = text.splitlines(keepends=True)
    try:
        start = next(i for i, line in enumerate(lines) if BEGIN in line)
        end = next(i for i, line in enumerate(lines) if END in line and i > start)
    except StopIteration:
        return None
    language = IMPLEMENTATIONS[path.name]
    return "".join(lines[: start + 1]) + block(language, html, js) + "".join(lines[end:])


def style_block(js):
    """The lines of the page script from `BEGIN tinyweb style` to `END
    tinyweb style`, both included. String -> String"""
    start, end = js.index(STYLE_BEGIN), js.index(STYLE_END)
    return js[start:js.index("\n", end) + 1]


def with_style(path, js):
    """The text of web24's implementation with its style block replaced
    by the page script's, or None where it has none. Path -> String -> String?"""
    text = path.read_text()
    if STYLE_BEGIN not in text or STYLE_END not in text:
        return None
    start, end = text.index(STYLE_BEGIN), text.index(STYLE_END)
    return text[:start] + style_block(js) + text[text.index("\n", end) + 1:]


def main(argv):
    """Rewrites every implementation's block, or with --check reports the
    stale ones and answers 1. [String] -> Int"""
    check = "--check" in argv
    html, js = PAGE_HTML.read_text(), PAGE_JS.read_text()
    for name, text in (("tinyweb_page.html", html), ("tinyweb_page.js", js)):
        if not text.isascii():
            print(f"embed_page: {name} is not ASCII, and C cannot carry it", file=sys.stderr)
            return 1
    stale = []
    for name in IMPLEMENTATIONS:
        path = LIB / name
        if not path.exists():
            continue
        new = embedded(path, html, js)
        if new is None:
            stale.append(f"{name} has no `{BEGIN}` block")
            continue
        if new != path.read_text():
            if check:
                stale.append(f"{name} carries an old copy of the page")
            else:
                path.write_text(new)
                print(f"embed_page: wrote {path}")
    new = with_style(BROWSER, js)
    if new is None:
        stale.append(f"{BROWSER.name} has no `{STYLE_BEGIN[3:]}` block")
    elif new != BROWSER.read_text():
        if check:
            stale.append(f"{BROWSER.name} carries an old copy of the page's style")
        else:
            BROWSER.write_text(new)
            print(f"embed_page: wrote {BROWSER}")
    for message in stale:
        print(f"embed_page: {message}", file=sys.stderr)
    if stale and check:
        print("embed_page: run python3 tools/tinyweb/embed_page.py", file=sys.stderr)
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
