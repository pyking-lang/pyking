import os
import sys

from analyses import analyze_program, AnalysisError
from lexer import lexing, pprint_info, pprint_token, LexError
from parser import parse, ParseError
from syntax import pprint_program
import target_c
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

USAGE = (
    "Usage: python3 boot/pykboot.py [--tokens] [--target|-t <target>] "
    "[--ast | --stdout | --output <file>] <filename>\n"
    f"       <target> is one of: {', '.join(TARGETS)} (default: python)\n"
    "       without --ast/--stdout/--output, compiles to <filename's stem>"
    " plus the target's extension, in the current directory\n"
    "       (Java targets instead Java-case the stem, e.g. foo_bar.pyk ->"
    " FooBar.java)"
)

args = sys.argv[1:]
show_tokens = False
show_ast = False
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
    elif arg == "--stdout":
        show_stdout = True
    elif arg in ("--target", "-t"):
        i += 1
        if i >= len(args):
            print("Usage error: --target requires a <target> argument", file=sys.stderr)
            print(USAGE, file=sys.stderr)
            sys.exit(1)
        target = args[i]
        if target not in TARGETS:
            print(
                f"Usage error: unknown target '{target}'; expected one of "
                f"{', '.join(TARGETS)}",
                file=sys.stderr,
            )
            sys.exit(1)
    elif arg == "--output":
        i += 1
        if i >= len(args):
            print("Usage error: --output requires a <file> argument", file=sys.stderr)
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
    print(f"{pprint_info(e.info)} Lexing error: {e.message}", file=sys.stderr)
    sys.exit(1)

if show_tokens:
    print("\n".join(f"{pprint_info(t.info)} {pprint_token(t)}" for t in tokens))
    print("")

try:
    program = parse(tokens)
except ParseError as e:
    print(f"{pprint_info(e.info)} Parsing error: {e.message}", file=sys.stderr)
    sys.exit(1)

# Name analysis runs for every mode, `--ast` included: it is part of the
# front end, not of any backend, and an AST whose names don't resolve is
# not a program worth printing or compiling.
try:
    analyze_program(program)
except AnalysisError as e:
    print(f"{pprint_info(e.info)} Name error: {e.message}", file=sys.stderr)
    sys.exit(1)

# `--ast` is the Pyking AST, which every target shares, so it is printed
# before any backend runs and ignores `--target`.
if show_ast:
    print(pprint_program(program))
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
            f"Note: '{path}' already exists and does not set "
            '"type": "module"; node will read the generated .js files as '
            "CommonJS until it does. Left untouched.",
            file=sys.stderr,
        )


def write(path, contents):
    """Writes one output file, refusing to clobber the source and turning
    a missing output directory into a usage error rather than a
    traceback -- `esm` writes several files, so both checks have to happen
    per file rather than once on `--output`."""
    if os.path.abspath(path) == os.path.abspath(filename):
        print(
            f"Usage error: writing '{path}' would overwrite the input file; "
            "choose a different output path.",
            file=sys.stderr,
        )
        sys.exit(1)
    directory = os.path.dirname(path)
    if directory and not os.path.isdir(directory):
        print(
            f"Usage error: cannot write '{path}': the directory "
            f"'{directory}' does not exist.",
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
            f"{pprint_info(e.info)} Unsupported by target '{target}': {e.message}",
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
            f"{pprint_info(e.info)} Unsupported by target '{target}': {e.message}",
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
            f"{pprint_info(e.info)} Unsupported by target '{target}': {e.message}",
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
