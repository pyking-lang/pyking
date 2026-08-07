"""The driver: what `pyk` on the command line actually runs.

It sequences the stages -- lexing, parsing, the analyses, symbolizing,
optionally type checking -- and then hands the result to whichever of the
four commands was asked for:

    pyk <file>              run it with the python backend
    pyk run <file>          run it with the interpreter
    pyk repl                start the REPL
    pyk compile <file>      compile it (alias: `pyk c`)

Two of those *run* a Pyking program, by two different routes, and the
difference is worth knowing. `pyk <file>` compiles to Python, runs that
with the host's own interpreter and deletes it again -- so what runs is
generated Python, with Python's semantics underneath it (arbitrary-
precision integers, Python's own recursion limit). `pyk run` uses
`src/interpreter.py`, which runs the AST directly with Pyking's
semantics: 32-bit integers, and errors reported against Pyking source
positions. Where the two disagree, the interpreter is the reference (see
docs/targets.md).

The driver stays thin. It parses argv, sequences stages, and reports
errors; each backend owns its own translation, packaging and file naming
-- `esm` writing three files is `target_js_packaging.package`'s business,
and deriving a Java class name from an `--output` path is
`target_java.py`'s.

Every message it prints goes through `wrap`, so a long path or a long
diagnostic reflows to a fixed width instead of running off the terminal.
`format_error` turns any of the front end's five error types into that
one form, and is handed to the REPL as well, so a mistake made at a
prompt is reported in exactly the words it would have been reported in
from a file.
"""

import os
import subprocess
import sys
import tempfile
import textwrap
from dataclasses import dataclass

from analyses import analyze_program, symbolize, AnalysisError
from lexer import lexing, pprint_info, pprint_token, LexError
from parser import parse, ParseError
from syntax import pprint_program
import interpreter
import target_c
import typesystem
import target_java
import target_js_core
import target_js_packaging
import target_ocaml
from target_python import translate_program, pprint_py_program

# The compiling targets, in the order the usage message lists them. The
# interpreter is *not* one of them: it produces no source file, so it is
# a command (`pyk run`) rather than something `--target` selects. The
# test harness calls it a target because there it is one -- a way of
# running a program and comparing its output (see tests/test_script.py).
TARGETS = (
    ("python",)
    + target_js_packaging.TARGETS
    + target_c.STANDARDS
    + target_java.VERSIONS
    + (target_ocaml.TARGET,)
)

# What the primary output file is called when `--output` doesn't say. Each
# backend owns its own extension; `esm` names three files from this stem.
EXTENSIONS = {
    "python": ".py",
    **target_js_packaging.PRIMARY_EXTENSIONS,
    **{standard: ".c" for standard in target_c.STANDARDS},
    **{version: ".java" for version in target_java.VERSIONS},
    target_ocaml.TARGET: target_ocaml.EXTENSION,
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


USAGE = f"""Usage: pyk [options] <filename>          run it with the python backend
       pyk run [options] <filename>      run it with the interpreter
       pyk repl                          start the REPL
       pyk compile [options] <filename>  compile it (alias: pyk c)

Options:
  -t, --target <name>   compile for <name> (default: python)
  -o, --output <file>   write the output to <file>
  --stdout              print the generated code instead of writing it
  --ast                 print the parsed program and stop
  --symbols             with --ast, also print each node's symbol
  --typecheck           type-check before doing anything else
  --tokens              print the token stream first

Targets:
{_target_table()}

`pyk <filename>` compiles to a temporary file, runs it, and removes it.
`pyk run` runs the program directly instead, on the AST, with Pyking's
own semantics -- 32-bit integers, and its own runtime errors. It covers
the fragment the type checker covers, and type-checks first.

`pyk compile` writes a file named after the source, in the current
directory, unless --output says otherwise. The `esm` target writes three
more files beside its .js: a .node.js driver, an .html wrapper, and
package.json. The Java targets name the file and its class in Java's own
casing: foo_bar.pyk -> FooBar.java."""


# --- what was asked for ----------------------------------------------

# The commands, and the one that is meant when a command word is left
# out. A bare `pyk foo.pyk` runs the program -- the thing someone with a
# file in their hand almost always wants -- and every other command says
# its name.
COMMANDS = {"run": "run", "repl": "repl", "compile": "compile", "c": "compile"}
DEFAULT_COMMAND = "python"


@dataclass(frozen=True)
class Options:
    """Everything argv said, as one value: which command, which file, and
    the flags. The flags are shared by every command rather than being
    per-command, so that `--tokens` and `--ast` mean the same thing
    wherever they are written."""
    command: str
    filename: str = None
    target: str = "python"
    output: str = None
    stdout: bool = False
    ast: bool = False
    symbols: bool = False
    typecheck: bool = False
    tokens: bool = False


def usage_error(message):
    """A complaint about how the command was written -- not about the
    program it names. Prints the usage message after it, since someone
    who got a flag wrong is usually one line away from getting it
    right."""
    print(wrap(f"Usage error: {message}"), file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(1)


def parse_args(argv):
    """argv, as an `Options`. Raises no exceptions: anything malformed
    ends in `usage_error`."""
    command = DEFAULT_COMMAND
    if argv and argv[0] in COMMANDS:
        command, argv = COMMANDS[argv[0]], argv[1:]

    flags = {"command": command}
    positional = []
    rest = list(argv)
    while rest:
        argument, rest = rest[0], rest[1:]
        match argument:
            case "--tokens":
                flags["tokens"] = True
            case "--ast":
                flags["ast"] = True
            case "--symbols":
                flags["symbols"] = True
            case "--typecheck":
                flags["typecheck"] = True
            case "--stdout":
                flags["stdout"] = True
            case "--target" | "-t":
                if not rest:
                    usage_error("--target requires a <target> argument")
                flags["target"], rest = rest[0], rest[1:]
                if flags["target"] not in TARGETS:
                    usage_error(
                        f"unknown target '{flags['target']}'; expected one of "
                        f"{', '.join(TARGETS)}"
                    )
            case "--output" | "-o":
                if not rest:
                    usage_error("--output requires a <file> argument")
                flags["output"], rest = rest[0], rest[1:]
            case _:
                positional.append(argument)

    if command == "repl":
        if positional:
            usage_error("'pyk repl' takes no filename")
        return Options(**flags)
    if len(positional) != 1:
        print(USAGE)
        sys.exit(1)
    return Options(filename=positional[0], **flags)


# --- reporting -------------------------------------------------------

# One line per stage that can refuse a program, in the order the stages
# run. Every one of these errors carries an `Info`, which is what lets
# them all be reported the same way; the label is the only thing that
# differs, and it names the stage in the words the docs use for it.
ERROR_KINDS = (
    (LexError, "Lexing error"),
    (ParseError, "Parsing error"),
    (AnalysisError, "Name error"),
    (typesystem.TypeError_, "Type error"),
    (interpreter.RuntimeError_, "Runtime error"),
)


def format_error(error):
    """Any of the front end's errors as one `'file' row:col-row:col Kind:
    message` line, reflowed -- or `None` if this is not one of them.

    Handed to the REPL as well as used here, so that the same mistake is
    reported in the same words whether it was made in a file or at a
    prompt."""
    for kind, label in ERROR_KINDS:
        if isinstance(error, kind):
            return wrap(f"{pprint_info(error.info)} {label}: {error.message}")
    return None


def fail(error):
    """Report one of those errors and stop."""
    print(format_error(error), file=sys.stderr)
    sys.exit(1)


def fail_unsupported(target, error):
    """Report a construct a backend does not translate. Not one of
    `ERROR_KINDS`: each backend raises its own `UnsupportedError`, and
    the message names the target that refused it, since another one may
    well accept the same program."""
    print(
        wrap(
            f"{pprint_info(error.info)} Unsupported by target "
            f"'{target}': {error.message}"
        ),
        file=sys.stderr,
    )
    sys.exit(1)


# --- the front end ---------------------------------------------------


def front_end(options):
    """Everything every command needs: the program, symbolized, and the
    types if anything asked for them.

    The name analysis runs for every mode, `--ast` included -- it is part
    of the front end, not of any backend, and an AST whose names don't
    resolve is not a program worth printing, compiling or running. The
    exception is type checking, which replaces it: the checker's
    environment *is* a scope and it checks names against it as it goes,
    reporting one it cannot find with the analysis's own `AnalysisError`,
    so which pass found it makes no difference to what is printed.

    `pyk run` always type-checks, because that is the interpreter's gate
    (see `interpreter.check`), so it takes that path whether or not
    `--typecheck` was written."""
    with open(options.filename, "r") as f:
        data = f.read()

    try:
        tokens = lexing(options.filename, list(data))
    except LexError as e:
        fail(e)

    if options.tokens:
        print("\n".join(f"{pprint_info(t.info)} {pprint_token(t)}" for t in tokens))
        print("")

    try:
        program = parse(tokens)
    except ParseError as e:
        fail(e)

    checking = options.typecheck or options.command == "run"
    if not checking:
        try:
            analyze_program(program)
        except AnalysisError as e:
            fail(e)

    # Every node gets a unique symbol once the names check out. This runs
    # for every mode, like the analysis before it: `--symbols` prints
    # them, `tmap` is keyed by them, and so is the interpreter's
    # call-free table. Nothing needs symbolizing again afterwards,
    # because no later pass synthesizes nodes into the tree.
    program = symbolize(program)

    tmap = None
    if checking:
        try:
            tmap = interpreter.check(program)
        except (AnalysisError, typesystem.TypeError_) as e:
            fail(e)

    return program, tmap


# --- the commands ----------------------------------------------------


def command_repl():
    """`pyk repl`. Imported here rather than at the top of the module
    because the REPL is handed this module's own error formatting, and
    importing it lazily keeps that from being a cycle at import time."""
    import repl

    return repl.start(format_error)


# How many calls a runtime error's stack trace shows before it says how
# many more there were. The stack lives on the heap and may legitimately
# be thousands deep -- a recursion that ran away is exactly the case
# where a trace is wanted and exactly the case where printing all of it
# would bury the message that came first.
TRACE_LIMIT = 10


def command_run(program):
    """`pyk run <file>`: interpret the program.

    The type checker has already accepted it (see `front_end`), so what
    is left is running it and reporting a runtime error the same way
    every other error is reported -- with the calls that were in progress
    under it, innermost first, since the machine keeps its own stack and
    can simply read them off."""
    state = interpreter.run_program(program, interpreter.ConsoleHost())
    error = interpreter.failure(state)
    if error is None:
        return 0
    print(format_error(error), file=sys.stderr)
    trace = interpreter.stack_trace(state)
    for name, info in trace[:TRACE_LIMIT]:
        print(wrap(f"  in '{name}', called at {pprint_info(info)}"), file=sys.stderr)
    if len(trace) > TRACE_LIMIT:
        print(f"  ... {len(trace) - TRACE_LIMIT} more calls", file=sys.stderr)
    return 1


def command_python(program, filename):
    """`pyk <file>`: compile with the python backend to a temporary file,
    run it, and remove it -- even if the run fails.

    The oldest way to run a Pyking program, and still the one that covers
    the whole language: the interpreter runs the type checker's fragment,
    while this runs whatever `target_python.py` can translate. The exit
    status is the program's own."""
    source = pprint_py_program(translate_program(program)) + "\n"
    handle, path = tempfile.mkstemp(prefix="pyk", suffix=".py")
    try:
        with os.fdopen(handle, "w") as f:
            f.write(source)
        return subprocess.run([sys.executable, path]).returncode
    finally:
        os.remove(path)


def command_compile(program, options):
    """`pyk compile <file>`: translate the program for `--target` and
    write it out, print it (`--stdout`), or -- for `esm` -- write the
    several files that target names for itself."""
    target, filename = options.target, options.filename
    stem = os.path.splitext(os.path.basename(filename))[0]
    output_path = options.output

    if not options.stdout and output_path is None:
        # Nothing said where to put it: use the source file's own name,
        # with the target's extension, in the directory the command was
        # run from -- `pyk compile -t nodejs tests/hello.pyk` writes
        # `./hello.js`. For `esm` this is a stem, and the three files are
        # named from it. Java is the exception: it requires the public
        # class to share its file's name exactly, so the default name is
        # Java-cased rather than the source's own spelling -- `foo_bar.pyk`
        # writes `FooBar.java`, not `foo_bar.java`.
        if target in target_java.VERSIONS:
            output_path = target_java.default_class_name(stem) + ".java"
        else:
            output_path = stem + EXTENSIONS[target]

    def write(path, contents):
        """Writes one output file, refusing to clobber the source and
        turning a missing output directory into a usage error rather than
        a traceback -- `esm` writes several files, so both checks have to
        happen per file rather than once on `--output`."""
        if os.path.abspath(path) == os.path.abspath(filename):
            usage_error(
                f"writing '{path}' would overwrite the input file; choose a "
                "different output path."
            )
        directory = os.path.dirname(path)
        if directory and not os.path.isdir(directory):
            usage_error(
                f"cannot write '{path}': the directory '{directory}' does not "
                "exist."
            )
        with open(path, "w") as f:
            f.write(contents)

    def write_manifest(path, contents):
        """Writes the `esm` target's `package.json`, but never over one
        that is already there: that file belongs to whatever project the
        output landed in, and overwriting it could break far more than
        this build. An existing manifest that already means "ES modules"
        is silently fine; one that doesn't gets a warning, since the
        generated `.js` files will not load without it."""
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

    if target == "python":
        py_source = pprint_py_program(translate_program(program))
        if options.stdout:
            print(py_source)
        else:
            write(output_path, py_source + "\n")
    elif target in target_c.STANDARDS:
        # One backend, two standards: the difference is in how the C is
        # printed, not in what it means.
        try:
            c_program = target_c.translate_program(program)
        except target_c.UnsupportedError as e:
            fail_unsupported(target, e)
        c_source = target_c.pprint_c_program(
            c_program, target, os.path.basename(filename)
        )
        if options.stdout:
            print(c_source, end="")
        else:
            write(output_path, c_source)
    elif target in target_java.VERSIONS:
        try:
            java_program = target_java.translate_program(program)
        except target_java.UnsupportedError as e:
            fail_unsupported(target, e)
        # Java requires the public class to share its file's name exactly.
        # An explicit `--output` is trusted as-is: the class is named
        # after whatever file the caller chose. With none, `output_path`
        # was already picked in Java's own casing above, and the class
        # matches it too.
        class_name = (
            os.path.splitext(os.path.basename(output_path))[0]
            if output_path is not None
            else target_java.default_class_name(stem)
        )
        java_source = target_java.pprint_java_program(
            java_program, target, class_name, os.path.basename(filename)
        )
        if options.stdout:
            print(java_source, end="")
        else:
            write(output_path, java_source)
    elif target == target_ocaml.TARGET:
        # The OCaml backend compiles exactly what the type checker
        # accepts, and says so through the same `UnsupportedError` as the
        # others -- a program that does not type-check is refused here
        # with the checker's own message, whether or not `--typecheck`
        # was passed.
        try:
            ocaml_program = target_ocaml.translate_program(program)
        except target_ocaml.UnsupportedError as e:
            fail_unsupported(target, e)
        ocaml_source = target_ocaml.pprint_ocaml_program(
            ocaml_program, os.path.basename(filename)
        )
        if options.stdout:
            print(ocaml_source, end="")
        else:
            write(output_path, ocaml_source)
    else:
        # The JavaScript backends support a subset of Pyking so far;
        # anything outside it is reported here rather than emitting
        # broken JavaScript.
        try:
            js_program = target_js_core.translate_program(program)
        except target_js_core.UnsupportedError as e:
            fail_unsupported(target, e)

        source_name = os.path.basename(filename)
        if options.stdout:
            print(target_js_packaging.primary_source(target, js_program, source_name))
        else:
            for path, contents in target_js_packaging.package(
                target, js_program, source_name, output_path
            ).items():
                if os.path.basename(path) == target_js_packaging.MODULE_MANIFEST:
                    write_manifest(path, contents)
                else:
                    write(path, contents)
    return 0


def main(argv):
    """argv in, exit status out."""
    options = parse_args(argv)
    if options.command == "repl":
        return command_repl()

    program, tmap = front_end(options)

    # `--ast` is the Pyking AST, which every target and the interpreter
    # share, so it is printed before any of them runs and ignores
    # `--target`. With the types worked out it is printed against `tmap`,
    # so the annotations shown are the ones the checker inferred rather
    # than the ones the source happened to write.
    if options.ast:
        print(pprint_program(program, symbols=options.symbols, tmap=tmap))
        return 0

    match options.command:
        case "run":
            return command_run(program)
        case "compile":
            return command_compile(program, options)
        case _:
            return command_python(program, options.filename)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
