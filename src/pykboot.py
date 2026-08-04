import os
import sys
import textwrap

from analyses import analyze_program, symbolize, AnalysisError
from lexer import lexing, pprint_info, pprint_token, LexError
from parser import parse, ParseError
from syntax import pprint_program
import target_c
import typesystem
import target_java
import target_js_core
import target_js_packaging
from target_python import translate_program, pprint_py_program

TARGETS = (
    ("python",) + target_js_packaging.TARGETS + target_c.STANDARDS + target_java.VERSIONS
)

# What the primary output file is called when `--output` doesn't say. Each
# backend owns its own extension; `esm` names three files from this stem.
EXTENSIONS = {
    "python": ".py",
    **target_js_packaging.PRIMARY_EXTENSIONS,
    **{standard: ".c" for standard in target_c.STANDARDS},
    **{version: ".java" for version in target_java.VERSIONS},
}

# Every message this module prints is laid out for a terminal this wide.
# 70 rather than the usual 80 so that output still reads well once a
# `$ ` prompt, a quoting mail client, or a docs code block has eaten a
# few columns.
WIDTH = 70


def wrap(text, indent="  "):
    """`text` reflowed to `WIDTH`, with continuation lines indented so a
    wrapped message still reads as one message rather than as several.

    Neither long words nor hyphens are broken: the things most likely to
    be long here are paths, identifiers and flags (`--stdout`,
    `foo_bar.pyk`, `some/deep/dir`), and splitting one across a line
    break would make it unsearchable and, for a flag, unreadable."""
    return "\n".join(
        textwrap.wrap(
            text,
            width=WIDTH,
            subsequent_indent=indent,
            break_long_words=False,
            break_on_hyphens=False,
        )
    )


def _target_table():
    """The `Targets:` block: one row per group of targets sharing an
    output extension, in `TARGETS` order. Built from `TARGETS`/
    `EXTENSIONS` rather than written out, so a backend that adds a target
    shows up here without anyone remembering to update a second list."""
    groups = {}
    for name in TARGETS:
        groups.setdefault(EXTENSIONS[name], []).append(name)
    rows = [(", ".join(names), extension) for extension, names in groups.items()]
    column = max(len(names) for names, _ in rows) + 3
    return "\n".join(f"  {names.ljust(column)}{extension}" for names, extension in rows)


# Spelled in terms of `pyk`, the wrapper script at the repository root,
# rather than this module's own path: `pyk` is the documented front end
# (see README.md), it forwards every flag here untouched, and it is what
# a reader who just typed something wrong almost certainly ran. The one
# place the two genuinely differ is a bare filename with no flags at all
# -- `pyk` runs the program, this module compiles it to a file -- so that
# case is spelled out below rather than glossed over.
USAGE = f"""Usage: pyk [options] <filename>

Options:
  -t, --target <name>   compile for <name> (default: python)
  --output <file>       write the output to <file>
  --stdout              print the generated code instead of writing it
  --ast                 print the parsed program and stop
  --symbols             with --ast, also print each node's symbol
  --typecheck           type-check before doing anything else
  --tokens              print the token stream first

Targets:
{_target_table()}

With no options at all, `pyk <filename>` compiles to a temporary file,
runs it, and removes it. Otherwise the output is named after the
source file, in the current directory, unless --output says otherwise.

The `esm` target writes three more files beside its .js: a .node.js
driver, an .html wrapper, and package.json. The Java targets name the
file and its class in Java's own casing: foo_bar.pyk -> FooBar.java."""

args = sys.argv[1:]
show_tokens = False
show_ast = False
show_symbols = False
typecheck = False
show_stdout = False
output_path = None
target = "python"
positional = []

i = 0
while i < len(args):
    arg = args[i]
    if arg == "--tokens":
        show_tokens = True
    elif arg == "--ast":
        show_ast = True
    elif arg == "--symbols":
        show_symbols = True
    elif arg == "--typecheck":
        typecheck = True
    elif arg == "--stdout":
        show_stdout = True
    elif arg in ("--target", "-t"):
        i += 1
        if i >= len(args):
            print(
                wrap("Usage error: --target requires a <target> argument"),
                file=sys.stderr,
            )
            print(USAGE, file=sys.stderr)
            sys.exit(1)
        target = args[i]
        if target not in TARGETS:
            print(
                wrap(
                    f"Usage error: unknown target '{target}'; expected one of "
                    f"{', '.join(TARGETS)}"
                ),
                file=sys.stderr,
            )
            sys.exit(1)
    elif arg == "--output":
        i += 1
        if i >= len(args):
            print(
                wrap("Usage error: --output requires a <file> argument"),
                file=sys.stderr,
            )
            print(USAGE, file=sys.stderr)
            sys.exit(1)
        output_path = args[i]
    else:
        positional.append(arg)
    i += 1

if len(positional) != 1:
    print(USAGE)
    sys.exit(1)

filename = positional[0]
with open(filename, "r") as f:
    data = f.read()

try:
    tokens = lexing(filename, list(data))
except LexError as e:
    print(
        wrap(f"{pprint_info(e.info)} Lexing error: {e.message}"),
        file=sys.stderr,
    )
    sys.exit(1)

if show_tokens:
    print("\n".join(f"{pprint_info(t.info)} {pprint_token(t)}" for t in tokens))
    print("")

try:
    program = parse(tokens)
except ParseError as e:
    print(
        wrap(f"{pprint_info(e.info)} Parsing error: {e.message}"),
        file=sys.stderr,
    )
    sys.exit(1)

# Name analysis runs for every mode, `--ast` included: it is part of the
# front end, not of any backend, and an AST whose names don't resolve is
# not a program worth printing or compiling. The exception is
# `--typecheck`, which replaces it: the type checker carries an
# environment of its own and refuses any name it cannot find there, so
# running both would mean judging names twice, by two passes that cover
# different fragments of the language.
if not typecheck:
    try:
        analyze_program(program)
    except AnalysisError as e:
        print(
            wrap(f"{pprint_info(e.info)} Name error: {e.message}"),
            file=sys.stderr,
        )
        sys.exit(1)

# Every node gets a unique symbol once the names check out. This runs
# for every mode, like the analysis before it: `--symbols` prints the
# symbols, and a later pass that wants to hang information off a node
# needs them to exist whether or not anyone asked to see them.
program = symbolize(program)

# Type checking is opt-in (`--typecheck`) while it covers only part of
# the language -- see src/typesystem.py. It runs after symbolizing and
# before `--ast`, so a printed AST shows the types it worked out. It
# leaves the AST alone and reports what it inferred in `tmap`, a symbol
# -> type table, which is why symbolizing has to have happened first and
# does not have to happen again afterwards.
tmap = None
if typecheck:
    tmap = {}
    try:
        typesystem.type_check(program, {}, tmap)
    except typesystem.TypeError_ as e:
        print(
            wrap(f"{pprint_info(e.info)} Type error: {e.message}"),
            file=sys.stderr,
        )
        sys.exit(1)

# `--ast` is the Pyking AST, which every target shares, so it is printed
# before any backend runs and ignores `--target`. With `--typecheck` it
# is printed against `tmap`, so the annotations shown are the ones the
# checker inferred rather than the ones the source happened to write.
if show_ast:
    print(pprint_program(program, symbols=show_symbols, tmap=tmap))
    sys.exit(0)

stem = os.path.splitext(os.path.basename(filename))[0]

if not show_stdout and output_path is None:
    # Nothing said where to put it: use the source file's own name, with
    # the target's extension, in the directory the command was run from --
    # `pykboot.py -t nodejs tests/hello.pyk` writes `./hello.js`. For
    # `esm` this is a stem, and the three files are named from it. Java
    # is the exception: it requires the public class to share its file's
    # name exactly, so the default name is Java-cased rather than the
    # source's own spelling -- `foo_bar.pyk` writes `FooBar.java`, not
    # `foo_bar.java`.
    if target in target_java.VERSIONS:
        output_path = target_java.default_class_name(stem) + ".java"
    else:
        output_path = stem + EXTENSIONS[target]


def write_manifest(path, contents):
    """Writes the `esm` target's `package.json`, but never over one that
    is already there: that file belongs to whatever project the output
    landed in, and overwriting it could break far more than this build.
    An existing manifest that already means "ES modules" is silently
    fine; one that doesn't gets a warning, since the generated `.js`
    files will not load without it."""
    if not os.path.exists(path):
        write(path, contents)
        return
    with open(path) as f:
        existing = f.read()
    if not target_js_packaging.manifest_declares_module(existing):
        print(
            wrap(
                f"Note: '{path}' already exists and does not set "
                '"type": "module"; node will read the generated .js files '
                "as CommonJS until it does. Left untouched."
            ),
            file=sys.stderr,
        )


def write(path, contents):
    """Writes one output file, refusing to clobber the source and turning
    a missing output directory into a usage error rather than a
    traceback -- `esm` writes several files, so both checks have to happen
    per file rather than once on `--output`."""
    if os.path.abspath(path) == os.path.abspath(filename):
        print(
            wrap(
                f"Usage error: writing '{path}' would overwrite the input "
                "file; choose a different output path."
            ),
            file=sys.stderr,
        )
        sys.exit(1)
    directory = os.path.dirname(path)
    if directory and not os.path.isdir(directory):
        print(
            wrap(
                f"Usage error: cannot write '{path}': the directory "
                f"'{directory}' does not exist."
            ),
            file=sys.stderr,
        )
        sys.exit(1)
    with open(path, "w") as f:
        f.write(contents)


if target == "python":
    py_source = pprint_py_program(translate_program(program))
    if show_stdout:
        print(py_source)
    else:
        write(output_path, py_source + "\n")
elif target in target_c.STANDARDS:
    # One backend, two standards: the difference is in how the C is
    # printed, not in what it means.
    try:
        c_program = target_c.translate_program(program)
    except target_c.UnsupportedError as e:
        print(
            wrap(
                f"{pprint_info(e.info)} Unsupported by target "
                f"'{target}': {e.message}"
            ),
            file=sys.stderr,
        )
        sys.exit(1)
    c_source = target_c.pprint_c_program(
        c_program, target, os.path.basename(filename)
    )
    if show_stdout:
        print(c_source, end="")
    else:
        write(output_path, c_source)
elif target in target_java.VERSIONS:
    try:
        java_program = target_java.translate_program(program)
    except target_java.UnsupportedError as e:
        print(
            wrap(
                f"{pprint_info(e.info)} Unsupported by target "
                f"'{target}': {e.message}"
            ),
            file=sys.stderr,
        )
        sys.exit(1)
    # Java requires the public class to share its file's name exactly. An
    # explicit `--output` is trusted as-is: the class is named after
    # whatever file the caller chose. With none, `output_path` was already
    # picked in Java's own casing above, and the class matches it too.
    class_name = (
        os.path.splitext(os.path.basename(output_path))[0]
        if output_path is not None
        else target_java.default_class_name(stem)
    )
    java_source = target_java.pprint_java_program(
        java_program, target, class_name, os.path.basename(filename)
    )
    if show_stdout:
        print(java_source, end="")
    else:
        write(output_path, java_source)
else:
    # The JavaScript backends support a subset of Pyking so far; anything
    # outside it is reported here rather than emitting broken JavaScript.
    try:
        js_program = target_js_core.translate_program(program)
    except target_js_core.UnsupportedError as e:
        print(
            wrap(
                f"{pprint_info(e.info)} Unsupported by target "
                f"'{target}': {e.message}"
            ),
            file=sys.stderr,
        )
        sys.exit(1)

    source_name = os.path.basename(filename)
    if show_stdout:
        print(target_js_packaging.primary_source(target, js_program, source_name))
    else:
        for path, contents in target_js_packaging.package(
            target, js_program, source_name, output_path
        ).items():
            if os.path.basename(path) == target_js_packaging.MODULE_MANIFEST:
                write_manifest(path, contents)
            else:
                write(path, contents)
