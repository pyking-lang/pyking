"""The driver: what `pyk` on the command line runs. Parses argv,
sequences the front-end stages, and dispatches to one of four commands
(`pyk <file>`, `run`, `repl`, `compile`). Each backend owns its own
translation, packaging and file naming. See docs/architecture.md
("Command line") and docs/source.md ("pyk.py").

Data structures:
    Options -- argv parsed into one value: command, filename, flags.

Functions:
    main(argv) -- argv in, exit status out.
    parse_args(argv) -- argv, as an Options.
    front_end(options) -- runs lexing/parsing/analyses/symbolizing/typing.
    format_error(error) -- formats any front-end error as one line.
    command_python(program, filename) -- `pyk <file>`.
    command_run(program) -- `pyk run`.
    command_repl() -- `pyk repl`.
    command_compile(program, options) -- `pyk compile`.
    wrap(text) -- reflows text to the driver's line width.
"""

import os
import subprocess
import sys
import tempfile
import textwrap
from dataclasses import dataclass

from analyses import analyze_program, symbolize, AnalysisError
import optimization
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

# The targets whose host language eliminates tail calls itself, and which
# are therefore compiled from the program as written rather than from the
# one src/optimization.py rewrote -- there the rewrite would only be
# undone (see docs/optimization.md, "The target that needs none of
# this"). One name, written here: a list is easier to read than a
# question asked of every backend, and adding to it is one line.
NATIVE_TAIL_CALLS = ("ocaml",)

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
    """Reflows text to WIDTH, continuation lines indented; never breaks
    a word or a hyphen. String -> String -> String"""
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
    """The Targets: block for --help: one row per group of targets
    sharing an output extension. () -> String"""
    groups = {}
    for name in TARGETS:
        groups.setdefault(EXTENSIONS[name], []).append(name)
    rows = [(", ".join(names), extension) for extension, names in groups.items()]
    column = max(len(names) for names, _ in rows) + 3
    return "\n".join(f"  {names.ljust(column)}{extension}" for names, extension in rows)


# The help comes in two lengths, sharing the part nobody can do without.
# What someone who typed `pyk` by itself needs is the shape of the
# command and the flags; what someone who asked for `--help` wants is
# everything, including the target table and the paragraphs explaining
# what the commands actually do.
_SYNOPSIS = """Usage: pyk [options] <filename>          run it with the python backend
       pyk run [options] <filename>      run it with the interpreter
       pyk repl                          start the REPL
       pyk compile [options] <filename>  compile it (alias: pyk c)

Options:
  -t, --target <name>   compile for <name> (default: python)
  -o, --output <file>   write the output to <file>
  --stdout              print the generated code instead of writing it
  --ast                 print the parsed program and stop
  --typecheck           type-check before doing anything else
  --help                this, in full: the rest of the flags, what each
                        command does, and what each target writes"""

# The flags someone reaches for once they know the shape of the tool:
# two that show a stage's own output, and one that turns off a
# transformation nobody has to know about to use the compiler.
_MORE_OPTIONS = """More options:
  --symbols             with --ast, also print each node's symbol
  --tokens              print the token stream first
  --no-tail-call-opt    leave tail calls as calls. A function that calls
                        itself in tail position is otherwise rewritten
                        into a `loop` carrying its parameters, and a
                        group of functions that tail-call each other
                        into one loop they share -- so such a function
                        runs in constant space on every target. Turning
                        it off is for reading the program as written,
                        and for the recursion depth it restores."""

# The short form names the targets in a sentence rather than a table:
# someone who wants to know what `-t` takes is answered by the list, and
# someone who wants to know what each one *writes* is asking for --help.
USAGE = f"""{_SYNOPSIS}

Targets:
{wrap('  ' + ', '.join(TARGETS) + '.', indent='  ')}"""

USAGE_FULL = f"""{_SYNOPSIS}

{_MORE_OPTIONS}

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
    """argv parsed into one value. Flags are shared by every command.
    Fields: command: String, filename: String?, target: String,
    output: String?, stdout: Bool, ast: Bool, symbols: Bool,
    typecheck: Bool, tokens: Bool, tail_calls: Bool."""
    command: str
    filename: str = None
    target: str = "python"
    output: str = None
    stdout: bool = False
    ast: bool = False
    symbols: bool = False
    typecheck: bool = False
    tokens: bool = False
    tail_calls: bool = True


def compiling_natively(options):
    """Whether this run hands the program to a backend whose own host
    eliminates tail calls, in which case the pass would only be undone
    (see docs/optimization.md). `--ast` is not compiling: it ignores
    --target, so it must not depend on one either.
    Options -> Bool"""
    return (
        options.command == "compile"
        and not options.ast
        and options.target in NATIVE_TAIL_CALLS
    )


def usage_error(message):
    """Prints message and the usage text to stderr, and exits 1.
    String -> ()"""
    print(wrap(f"Usage error: {message}"), file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(1)


def parse_args(argv):
    """Parses argv into an Options; exits via usage_error on anything
    malformed. [String] -> Options"""
    command = DEFAULT_COMMAND
    if argv and argv[0] in COMMANDS:
        command, argv = COMMANDS[argv[0]], argv[1:]

    flags = {"command": command}
    positional = []
    rest = list(argv)
    while rest:
        argument, rest = rest[0], rest[1:]
        match argument:
            case "--help" | "-h":
                print(USAGE_FULL)
                sys.exit(0)
            case "--tokens":
                flags["tokens"] = True
            case "--ast":
                flags["ast"] = True
            case "--symbols":
                flags["symbols"] = True
            case "--typecheck":
                flags["typecheck"] = True
            case "--no-tail-call-opt":
                flags["tail_calls"] = False
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
    """Formats a front-end error as `'file' row:col-row:col Kind:
    message`, or None if error is not one of ERROR_KINDS.
    Exception -> String?"""
    for kind, label in ERROR_KINDS:
        if isinstance(error, kind):
            return wrap(f"{pprint_info(error.info)} {label}: {error.message}")
    return None


def fail(error):
    """Prints error and exits 1. Exception -> ()"""
    print(format_error(error), file=sys.stderr)
    sys.exit(1)


def fail_unsupported(target, error):
    """Prints an UnsupportedError, naming target, and exits 1.
    String -> UnsupportedError -> ()"""
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
    """Lexes, parses, checks names (or types, for pyk run or
    --typecheck), and symbolizes options.filename. Exits via fail() on
    the first error. Options -> ([Stmt], {Int: Type}?)"""
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
    # call-free table.
    program = symbolize(program)

    # Tail calls become loops before anything reads the program, so what
    # `--ast` prints, what the checker checks and what every backend
    # compiles are the same program (see docs/optimization.md). The pass
    # builds nodes, so symbols are handed out again -- `symbolize` keeps
    # the ones already given and continues past the highest.
    if options.tail_calls and not compiling_natively(options):
        program = symbolize(optimization.optimize(program))

    tmap = None
    if checking:
        try:
            tmap = interpreter.check(program)
        except (AnalysisError, typesystem.TypeError_) as e:
            fail(e)

    return program, tmap


# --- the commands ----------------------------------------------------


def command_repl():
    """Runs `pyk repl`. Imported lazily to avoid a cycle at import time.
    () -> Int"""
    import repl

    return repl.start(format_error)


# How many calls a runtime error's stack trace shows before it says how
# many more there were.
TRACE_LIMIT = 10


def command_run(program):
    """Runs `pyk run <file>` with the interpreter; prints a runtime
    error (with a truncated stack trace) if one occurs.
    [Stmt] -> Int"""
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
    """Runs `pyk <file>`: compiles with the Python backend to a temp
    file, runs it, removes it. Returns the program's own exit status.
    [Stmt] -> String -> Int"""
    source = pprint_py_program(translate_program(program)) + "\n"
    handle, path = tempfile.mkstemp(prefix="pyk", suffix=".py")
    try:
        with os.fdopen(handle, "w") as f:
            f.write(source)
        return subprocess.run([sys.executable, path]).returncode
    finally:
        os.remove(path)


def command_compile(program, options):
    """Runs `pyk compile <file>`: translates the program for
    options.target and writes, or prints (--stdout), the result.
    [Stmt] -> Options -> Int"""
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
        """Writes one output file; usage_error if it would overwrite
        the source or its directory does not exist.
        String -> String -> ()"""
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
        """Writes the esm target's package.json, unless one already
        exists there (warns if it doesn't declare ES modules).
        String -> String -> ()"""
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
    """Runs pyk. [String] -> Int"""
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
