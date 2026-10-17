#!/usr/bin/env python3
"""tinyweb without Pyking: the website's pages and downloads for using
lib/tinyweb's implementations from Python, JavaScript, OCaml, C and Java
directly, which `site.py` stages beside the library reference.

Each implementation the compiler copies beside a program is a library
in its own right, so this publishes them under the name a program in
that language would import -- `tinyweb.py`, `tinyweb.js`, `tinyweb.ml`
with an interface `tinyweb.mli`, `tinyweb.c` with a header `tinyweb.h`,
`Tinyweb.java` -- with an example in each language (in this directory,
and tested by tests/test_tinyweb.py) and the code Pyking generates for
every tinyweb test. What each page says about a function is one table,
`DESCRIPTIONS`; its parameters' names are the Python implementation's
and its types the declarations' in tinyweb_external.pyk, so no language
can disagree with another about either. See README.md beside this file.

Usage: python3 tools/site/tinywebdoc.py DIRECTORY   write the downloads

Data structures:
    Function -- one function of the library: name, parameters, types, text.
    Language -- one language: its files, its commands, how it writes a type.

Functions:
    functions() -- the library's functions, in the order they are declared.
    library_files(language) -- {file name: text} of the renamed library.
    c_header() -- tinyweb.h, from the table.
    ocaml_interface() -- tinyweb.mli, from the table.
    examples(compiler, language, directory) -- the tests, compiled.
    see_also(directory) -- the tinyweb page's links to these pages.
    write(content, public, compiler) -- every page and every download,
        and the links on the tinyweb page.
"""

import ast
import io
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
LIB = REPO / "lib" / "tinyweb"
EXAMPLES = HERE / "tinyweb"
TESTS = REPO / "tests"
DECLARATIONS = LIB / "tinyweb_external.pyk"

# What each function does, in words every language's page shares.
DESCRIPTIONS = {
    "web_init": "Serves the program's page on `port` and prints its address, "
                "`tinyweb: http://127.0.0.1:N/`; port 0 picks any free port. Call it "
                "before anything else. With `PYKING_TINYWEB_LOG` set it does nothing.",
    "canvas": "A new canvas, `width` by `height` pixels, placed below what the page "
              "already shows. Answers the string that names it: \"canvas\", with a "
              "number added where something on the page has that name already.",
    "fill_canvas": "Fills the whole canvas `c` with `color`, a CSS color such as "
                   "`\"#ff0000\"` or `\"red\"`.",
    "draw_circle": "A filled circle on the canvas `c`, centred at (`x`, `y`).",
    "draw_rect": "A filled rectangle on the canvas `c`, with its top left corner at "
                 "(`x`, `y`).",
    "draw_line": "A straight line on the canvas `c`, from (`x1`, `y1`) to (`x2`, `y2`), "
                 "`width` pixels wide.",
    "draw_text": "`words` written on the canvas `c`, with the top left corner of the "
                 "text at (`x`, `y`), `size` pixels high.",
    "make_button": "A button showing `title`, placed below what the page already "
                   "shows, which calls `on_click` each time it is pressed. Answers the "
                   "string that names it: `title`, with a number added where something "
                   "on the page has that name already.",
    "label": "A line of text, placed below what the page already shows. Answers the "
             "string that names it to `set_label`: `text`, with a number added where "
             "something on the page has that name already.",
    "set_label": "Replaces the text of the label `id` with `text`.",
    "make_slider": "A slider from `low` to `high`, starting at `value`, placed below "
                   "what the page already shows, which calls `on_change` with each new "
                   "value it is moved to. Answers the string that names it: \"slider\", "
                   "with a number added where something on the page has that name "
                   "already.",
    "apply_style": "Changes the page's look. With `kind` \"theme\", `value` names a "
                   "theme: \"light\" (the default), \"dark\", \"plain\", \"paper\" or "
                   "\"retro\". With `kind` \"page\", \"button\", \"label\", "
                   "\"slider\" or \"canvas\", `property` of every element of that kind "
                   "becomes `value`; with `kind` \"element\", only the element `id`'s. "
                   "`property` is one of background, color, border, radius, font, size, "
                   "padding, gap, accent and width, and `value` is CSS, such as "
                   "\"#336699\" or \"12px\". `id` is \"\" except for an element.",
    "load_sample": "Starts loading the sound file `name` and answers a string naming "
                   "it to `play_sample`: `name`, with a number added where something on "
                   "the page has that name already. The name is looked up beside where the program "
                   "runs first, and then among the samples tinyweb ships in "
                   "`tinyweb_assets/`: kick1.wav, snare1.wav, hihat1.wav and "
                   "piano_c1.wav.",
    "play_sample": "Plays the sample `sample`: at the time `at` on the page's clock, or "
                   "now if that has passed; `volume` times as loud, and `rate` times as "
                   "fast, which raises its pitch as much.",
    "splash": "Shows the splash screen: the page dimmed, and a message asking the "
              "reader to click, since a browser plays no sound before the reader has "
              "clicked or pressed a key. The page waits there -- what the program "
              "draws next, its frames and its clock -- until the reader does. It is "
              "shown at most once, and not at all where the reader has already "
              "clicked. The first `play_sample` before a click shows it too; a "
              "program that plays sound only from callbacks calls it at the end of "
              "its main code.",
    "set_splash": "Sets what the splash screen says, \"Click to Start\" until it is "
                  "set. An empty `message` turns the splash screen off.",
    "time": "The page's clock, in seconds, as the page last reported it: inside an "
            "`on_frame` callback, the time the frame is for. It is the audio clock "
            "once sound has started, so a time read here is a time `play_sample` "
            "can be given.",
    "on_frame": "Calls `draw` before each frame the page shows, with the time the "
                "frame is for.",
    "on_mouse": "Calls `click` with the position, in pixels from the top left corner, "
                "of every click on the canvas `c`.",
    "on_key": "Calls `pressed` with the name of every key pressed while the page has "
              "the focus: a letter or digit as itself, and otherwise the browser's "
              "name for it, such as \"ArrowLeft\", \"Enter\" or \" \".",
}


@dataclass
class Function:
    """One function: its name, its parameters' names and Pyking types,
    its Pyking result type, and what it does."""
    name: str
    params: list
    result: object
    text: str


# --- the declarations, read ---

def _split(text):
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


def parse_type(text):
    """A declared type as a value: "Int", "Float", "String", "()", or
    ("fn", [params], result). String -> Type"""
    text = text.strip()
    if text.startswith("(") and "->" in text:
        depth = 0
        for i, ch in enumerate(text):
            depth += ch == "("
            depth -= ch == ")"
            if depth == 0:
                break
        inside, rest = text[1:i], text[i + 1:].strip()
        if rest.startswith("->"):
            return ("fn", [parse_type(p) for p in _split(inside)], parse_type(rest[2:]))
        return parse_type(inside)
    return text


def functions():
    """The library's functions, in the order tinyweb_external.pyk declares
    them, with the Python implementation's parameter names.
    () -> [Function]"""
    names = {}
    tree = ast.parse((LIB / "tinyweb_external.py").read_text())
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and not node.name.startswith("_"):
            names[node.name] = [a.arg for a in node.args.args]
    found = []
    for line in DECLARATIONS.read_text().splitlines():
        match = re.match(r"^(?:public\s+)?def\s+(\w+)\s*:\s*(.*)$", line)
        named = re.match(r"^(?:public\s+)?def\s+(\w+)\s*\((.*)\)\s*(->.*)$", line)
        if match:
            name, declared = match.group(1), parse_type(match.group(2))
        elif named:
            # `def name(p: T, ...) -> R`: the same type, its parameters named.
            params = [p.split(":", 1)[1].strip() for p in _split(named.group(2))]
            name = named.group(1)
            declared = parse_type(f"({', '.join(params)}) {named.group(3)}")
        else:
            continue
        _, params, result = declared
        found.append(Function(name, list(zip(names[name], params)), result,
                              DESCRIPTIONS[name]))
    return found


# --- the languages ---

def py_type(t):
    if isinstance(t, tuple):
        return f"Callable[[{', '.join(py_type(p) for p in t[1])}], None]"
    return {"Int": "int", "Float": "float", "String": "str", "()": "None"}[t]


def js_type(t):
    if isinstance(t, tuple):
        return f"({', '.join(js_type(p) for p in t[1])}) => void"
    return {"Int": "number", "Float": "number", "String": "string", "()": "undefined"}[t]


def ml_type(t):
    if isinstance(t, tuple):
        params = t[1] or ["()"]
        return "(" + " -> ".join(ml_type(p) for p in params) + " -> " + ml_type(t[2]) + ")"
    return {"Int": "int", "Float": "float", "String": "string", "()": "unit"}[t]


def c_declarator(t, name):
    if isinstance(t, tuple):
        params = ", ".join(c_declarator(p, "") .strip() for p in t[1]) or "void"
        return f"{c_declarator(t[2], '').strip()} (*{name})({params})"
    base = {"Int": "int", "Float": "double", "String": "const char *", "()": "void"}[t]
    return base + name if base.endswith("*") else (base + " " + name).rstrip()


def java_type(t, boxed=False):
    if isinstance(t, tuple):
        params = [java_type(p, True) for p in t[1]]
        if not params:
            return "Runnable"
        return ("Consumer" if len(params) == 1 else "BiConsumer") + "<" + ", ".join(params) + ">"
    if boxed:
        return {"Int": "Integer", "Float": "Double", "String": "String"}[t]
    return {"Int": "int", "Float": "double", "String": "String", "()": "void"}[t]


def signature(language, f):
    """How `language` writes f's signature. String -> Function -> String"""
    if language == "python":
        params = ", ".join(f"{n}: {py_type(t)}" for n, t in f.params)
        return f"def {f.name}({params}) -> {py_type(f.result)}"
    if language == "javascript":
        params = ", ".join(n for n, _ in f.params)
        doc = " ".join([f"@param {{{js_type(t)}}} {n}" for n, t in f.params]
                       + [f"@returns {{{js_type(f.result)}}}"])
        return f"/** {doc} */\nexport function {f.name}({params})"
    if language == "ocaml":
        params = [ml_type(t) for _, t in f.params] or ["unit"]
        return f"val {f.name} : {' -> '.join(params)} -> {ml_type(f.result)}"
    if language == "c":
        params = ", ".join(c_declarator(t, n) for n, t in f.params) or "void"
        return c_declarator(f.result, f"tinyweb_{f.name}({params})") + ";"
    if language == "java":
        params = ", ".join(f"{java_type(t)} {n}" for n, t in f.params)
        return f"public static {java_type(f.result)} {f.name}({params})"
    raise ValueError(language)


def c_header():
    """tinyweb.h: the C library's functions, each with what it does.
    () -> String"""
    lines = [
        "/* tinyweb: graphics, widgets and sound on a web page the program",
        "   serves itself, for C. Compile tinyweb.c with the program; it needs",
        "   a POSIX system (sockets and select).",
        "",
        "   Call tinyweb_web_init first. Once main has returned, the program",
        "   keeps serving its page and calling the functions it handed over,",
        "   until it is stopped. */",
        "",
        "#ifndef TINYWEB_H",
        "#define TINYWEB_H",
    ]
    for f in functions():
        lines += ["", "/* " + _wrap(_plain(f.text), 70, "   ").lstrip() + " */",
                  signature("c", f)]
    lines += ["", "#endif", ""]
    return "\n".join(lines)


def ocaml_interface():
    """tinyweb.mli: the OCaml library's functions, each with what it does.
    () -> String"""
    lines = [
        "(** tinyweb: graphics, widgets and sound on a web page the program",
        "    serves itself, for OCaml. Link it with unix.",
        "",
        "    Call [web_init] first. Once the program's top level has ended, it",
        "    keeps serving its page and calling the functions it handed over,",
        "    until it is stopped. *)",
    ]
    for f in functions():
        lines += ["", "(** " + _wrap(_plain(f.text), 70, "    ").lstrip() + " *)",
                  signature("ocaml", f)]
    lines += [
        "",
        "(** {2 Serving the page from a loop of your own}",
        "",
        "    The page is otherwise served once the program's top level has",
        "    ended. A program that keeps running a loop of its own can serve it",
        "    from there instead: wait on [descriptors ()] beside its own, and",
        "    call [handle ()] when one is ready. *)",
        "",
        "(** What the server waits on: nothing until [web_init]. *)",
        "val descriptors : unit -> Unix.file_descr list",
        "",
        "(** Answers what is waiting and calls what the page's events reach,",
        "    without waiting for anything more. *)",
        "val handle : unit -> unit",
    ]
    return "\n".join(lines) + "\n"


def _plain(text):
    return text.replace("`", "")


def _wrap(text, width, indent):
    words, lines, line = text.split(), [], indent
    for word in words:
        if len(line) + len(word) + 1 > width and line.strip():
            lines.append(line.rstrip())
            line = indent
        line += word + " "
    lines.append(line.rstrip())
    return "\n".join(lines)


@dataclass
class Language:
    """One language: its slug and name, the code-block language, the
    target its examples are compiled for, the library's files as they
    are published, and how to build and run a program."""
    slug: str
    name: str
    fence: str
    target: str
    example: str
    run: list
    generated_run: list


LANGUAGES = [
    Language("python", "Python", "python", "python14", "example.py",
             ["python3 example.py"], ["python3 program.py"]),
    Language("javascript", "JavaScript", "js", "node24", "example.js",
             ["node example.js"], ["node program.js"]),
    Language("ocaml", "OCaml", "ocaml", "ocaml5.5", "example.ml",
             ["ocamlopt -I +unix unix.cmxa tinyweb.mli tinyweb.ml example.ml -o example",
              "./example"],
             ["ocamlopt -I +unix unix.cmxa tinyweb_external.ml tinyweb.mli tinyweb.ml program.ml -o program",
              "./program"]),
    Language("c", "C", "c", "c23", "example.c",
             ["cc -o example example.c tinyweb.c", "./example"],
             ["cc -std=c23 -o program tinyweb_external.c tinyweb.c program.c", "./program"]),
    Language("java", "Java", "java", "java21", "Example.java",
             ["javac Tinyweb.java Example.java", "java Example"],
             ["javac TinywebExternal.java Tinyweb.java Program.java", "java Program"]),
]


def library_files(language):
    """The library as `language` publishes it: {file name: text}.
    Language -> {String: String}"""
    if language.slug == "python":
        return {"tinyweb.py": (LIB / "tinyweb_external.py").read_text()}
    if language.slug == "javascript":
        return {"tinyweb.js": (LIB / "tinyweb_external_node.js").read_text(),
                "package.json": '{\n  "type": "module"\n}\n'}
    if language.slug == "ocaml":
        return {"tinyweb.ml": (LIB / "tinyweb_external.ml").read_text(),
                "tinyweb.mli": ocaml_interface()}
    if language.slug == "c":
        return {"tinyweb.c": (LIB / "tinyweb_external.c").read_text(),
                "tinyweb.h": c_header()}
    if language.slug == "java":
        return {"Tinyweb.java": (LIB / "TinywebExternal.java").read_text()
                .replace("TinywebExternal", "Tinyweb")}
    raise ValueError(language.slug)


def cases():
    """The tinyweb tests, as (name, source). () -> [(String, Path)]"""
    return [(p.stem, p) for p in sorted(TESTS.glob("lib_tinyweb_*.pyk"))]


def examples(compiler, language, directory):
    """Compiles every tinyweb test for `language` into a directory of its
    own under `directory`, as `pyk compile` writes it, less the samples.
    Answers [(name, the program's own file)]. -> [(String, Path)]"""
    out = []
    for name, source in cases():
        target = directory / name
        target.mkdir(parents=True, exist_ok=True)
        main = "Program.java" if language.slug == "java" else "program" + {
            "python": ".py", "javascript": ".js", "ocaml": ".ml", "c": ".c"}[language.slug]
        ran = subprocess.run(compiler + ["compile", "-t", language.target, "-o",
                                         str(target / main), str(source)],
                             capture_output=True, text=True)
        if ran.returncode != 0:
            raise SystemExit(f"website: {name} does not compile for {language.target}:\n"
                             + ran.stderr)
        shutil.rmtree(target / "tinyweb_assets", ignore_errors=True)
        out.append((name, target / main))
    return out


def _zip(directory, path):
    """Writes every file under `directory` into the zip at `path`."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(directory.rglob("*")):
            if file.is_file():
                archive.write(file, file.relative_to(directory.parent))


# --- the pages ---

def _code(fence, text):
    return f"```{fence}\n{text.rstrip()}\n```"


def language_page(language, generated, base):
    """One language's page, as Markdown. -> String"""
    files = library_files(language)
    example = (EXAMPLES / language.example).read_text()
    named = ", ".join(f"`{name}`" for name in files if name != "package.json")
    parts = [
        "---",
        f"title: tinyweb for {language.name}",
        "sidebar:",
        f"  label: {language.name}",
        f'description: "tinyweb used from {language.name}, with no Pyking: the library, '
        f'how to build and run a program, and every function."',
        "---",
        "",
        f"tinyweb's {language.name} implementation is a library of its own: a "
        f"{language.name} program can use it to draw on a web page, add buttons, "
        "labels and sliders to it, play sounds and answer the reader, with no Pyking "
        "anywhere. It is the file Pyking copies beside a program compiled for "
        f"`{language.target}`, renamed {named}.",
        "",
        f"**Download** [tinyweb-{language.slug}.zip]({base}/tinyweb-{language.slug}.zip): "
        f"{named}, the example below, and the samples in `tinyweb_assets/`.",
        "",
        "## Running a program",
        "",
        "The program serves its own page: `web_init` starts the server and prints "
        "its address, and once the program's own code has finished it goes on "
        "serving the page and calling the functions it handed over until it is "
        "stopped (Ctrl-C). Open the address in a browser.",
        "",
        _code("sh", "\n".join(language.run)),
        "",
        "The page asks for a sample beside where the program runs first, then in "
        "`tinyweb_assets/` there.",
        "",
        "## An example",
        "",
        _code(language.fence, example),
        "",
        "## Functions",
        "",
        "Every function but `web_init` needs `web_init` to have been called first, "
        "or `PYKING_TINYWEB_LOG` to be set (below); otherwise it says so and the "
        "program ends with status 1.",
    ]
    for f in functions():
        parts += ["", f"### `{f.name}`", "", _code(language.fence, signature(language.slug, f)),
                  "", f.text]
    parts += [
        "",
        "## Without a page",
        "",
        "Two environment variables, each a file path, run a program with no page at "
        "all, which is how it is tested: with `PYKING_TINYWEB_LOG` set, every command "
        "the program would send its page is appended to that file as one line, and "
        "once the program's own code has finished the events "
        "`PYKING_TINYWEB_EVENTS` lists -- `click ID`, `slide ID VALUE`, `frame T`, "
        "`mouse ID X Y`, `key NAME`, one per line -- are delivered as if a reader had "
        "caused them.",
        "",
        _code("sh", "PYKING_TINYWEB_LOG=page.log PYKING_TINYWEB_EVENTS=clicks.txt " +
              language.run[-1]),
        "",
        "## What Pyking generates",
        "",
        f"Pyking's own tinyweb tests, compiled for `{language.target}`. Each comes with "
        "the libraries it needs as Pyking writes them -- tinyweb's implementation "
        "under its own name, and the module Pyking compiles from tinyweb's Pyking "
        "half -- and is built and run with:",
        "",
        _code("sh", "\n".join(language.generated_run)),
    ]
    for name, main, source in generated:
        parts += [
            "",
            f"### {name}",
            "",
            _code("pyking norun", source.read_text()),
            "",
            f"[{name}.zip]({base}/examples/{name}.zip)",
            "",
            "<details>",
            f"<summary>{main.name}, as Pyking generates it</summary>",
            "",
            _code(language.fence, main.read_text()),
            "",
            "</details>",
        ]
    return "\n".join(parts).rstrip() + "\n"


def index_page():
    """The overview page, as Markdown. -> String"""
    rows = "\n".join(
        f"| [{l.name}](./{l.slug}/) | {', '.join(f'`{n}`' for n in library_files(l) if n != 'package.json')} "
        f"| `{l.run[0]}` |"
        for l in LANGUAGES)
    return f"""---
title: tinyweb in other languages
description: "tinyweb's implementations, used directly from Python, JavaScript, OCaml, C and Java."
sidebar:
  label: tinyweb without Pyking
  order: 2000
---

[tinyweb](../tinyweb/) draws, plays and answers on a web page, and every
language a Pyking program compiles to has an implementation of it --
the file Pyking copies beside the program. Each is also a library a
program written in that language can use with no Pyking at all: the
same functions, under the language's own names and types.

| Language | Files | Build |
|---|---|---|
{rows}

A program calls `web_init(port)` first, which serves its page and prints
its address; port 0 picks a free one. Everything the program draws or
adds to the page is sent there as a command, and what the reader does
comes back as an event that calls the function the program handed over.
Once the program's own code has finished, it goes on serving the page
until it is stopped. A page that is opened late, or reloaded, is sent
what is on it first.

## What the page and the program say to each other

For anyone writing an implementation of their own: the page the program
serves is `tinyweb_page.html` and `tinyweb_page.js`, which every
implementation carries, and the program answers

| request | answer |
|---|---|
| `GET /` | the page |
| `GET /tinyweb_page.js` | the page's script |
| `GET /commands` | server-sent events, each a JSON array of commands |
| `POST /events` | one event, as JSON |
| `GET /<file>` | a file beside where the program runs, such as a sample |

A command is an object such as `{{"op": "circle", "c": 3, "x": 100, "y": 50,
"radius": 30, "color": "#ff0000"}}`, and an event one such as
`{{"ev": "click", "id": 4, "t": 1.25}}`, where `t` is the page's clock.
After each event the program sends `{{"op": "event_done"}}`, and after a
frame's callbacks `{{"op": "frame_done"}}`, before which the page asks for
no next frame.
"""


def see_also(href):
    """The section the tinyweb library page ends with, linking the pages
    for other languages at `href`, a link from that page.
    String -> String"""
    links = ", ".join(f"[{l.name}]({href}{l.slug}/)" for l in LANGUAGES)
    return f"""## Without Pyking

Each of tinyweb's implementations is also a library of its own, usable
from a program written in that language with no Pyking at all: {links}.
[tinyweb without Pyking]({href}) has the overview.
"""


def write(content, public, compiler, library=None, href="", base="../../../tinyweb"):
    """Writes the pages into `content` and the downloads into `public`:
    one zip per language, and one per generated example. `library` is the
    tinyweb library page, which gets `see_also(href)` at its end; `base`
    is where `public` is, from a language's page. Path -> Path ->
    [String] -> Path? -> String -> String -> ()"""
    content.mkdir(parents=True, exist_ok=True)
    (content / "index.md").write_text(index_page())
    if library is not None and library.exists():
        library.write_text(library.read_text().rstrip("\n") + "\n\n" + see_also(href))
    for language in LANGUAGES:
        out = public / language.slug
        bundle = out / f"tinyweb-{language.slug}"
        shutil.rmtree(out, ignore_errors=True)
        bundle.mkdir(parents=True)
        for name, text in library_files(language).items():
            (bundle / name).write_text(text)
        shutil.copyfile(EXAMPLES / language.example, bundle / language.example)
        shutil.copytree(LIB / "tinyweb_assets", bundle / "tinyweb_assets")
        _zip(bundle, out / f"tinyweb-{language.slug}.zip")
        compiled = examples(compiler, language, out / "examples")
        generated = []
        for (name, main), (_, source) in zip(compiled, cases()):
            _zip(main.parent, out / "examples" / f"{name}.zip")
            generated.append((name, main, source))
        (content / f"{language.slug}.md").write_text(
            language_page(language, generated, f"{base}/{language.slug}"))


def main(argv):
    """Writes the downloads into a directory, for a look at them.
    [String] -> Int"""
    if len(argv) != 1:
        print(__doc__.split("\n\n")[2], file=sys.stderr)
        return 2
    directory = Path(argv[0])
    write(directory / "content", directory / "public", [str(REPO / "pyk")])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
