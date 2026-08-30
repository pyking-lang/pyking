"""The driver: what `pyk` on the command line runs. Parses argv,
sequences the front-end stages, and dispatches to one of three commands
(`pyk <file>`, `repl`, `compile`). Every program is type-checked, so a
program that does not check is refused whatever was asked for. Each
backend owns its own translation, packaging and file naming. See
docs/architecture.md ("Command line") and docs/source.md ("pyk.py").

Data structures:
    Options -- argv parsed into one value: command, filename, flags.

Functions:
    main(argv) -- argv in, exit status out.
    parse_args(argv) -- argv, as an Options.
    front_end(options) -- runs lexing/parsing/symbolizing/typing/analyses.
    format_error(error) -- formats any front-end error as one line.
    command_interpret(program) -- `pyk <file>`.
    command_repl() -- `pyk repl`.
    command_compile(program, tmap, options) -- `pyk compile`.
    wrap(text) -- reflows text to the driver's line width.
"""

import os
import sys
import textwrap
from dataclasses import dataclass

from analyses import analyze_mutability, apply_signatures, symbolize, AnalysisError
import execution
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
# what `pyk <file>` does rather than something `--target` selects. The
# test harness calls it a target because there it is one -- a way of
# running a program and comparing its output (see tests/test_script.py).
#
# `pyking` is the odd one: it compiles Pyking to Pyking, which is to say
# it prints the program the front end worked out -- with the types the
# checker inferred, and the loops the tail-call pass built.
TARGETS = (
    ("python",)
    + target_js_packaging.TARGETS
    + target_c.STANDARDS
    + target_java.VERSIONS
    + (target_ocaml.TARGET, execution.PYKING_TARGET)
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
    execution.PYKING_TARGET: ".pyk",
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
_SYNOPSIS = """Usage: pyk [options] <filename>          run it with the interpreter
       pyk repl                          start the REPL
       pyk compile [options] <filename>  compile it (alias: pyk c)

Options:
  -t, --target <name>   compile for <name> (default: python)
  -o, --output <file>   write the output to <file>
  --stdout              print the generated code instead of writing it
  --run                 build and run what was compiled, with the
                        target's own commands
  --help                this, in full: the rest of the flags, what each
                        command does, and what each target writes"""

# The flags someone reaches for once they know the shape of the tool:
# two that show a stage's own output, and one that turns off a
# transformation nobody has to know about to use the compiler.
_MORE_OPTIONS = """More options:
  --symbols             with -t pyking, also print each node's symbol
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

Pyking is statically typed, and every program is type-checked before
anything else happens -- there is no flag for it and no way round it.

`pyk <filename>` runs the program on the AST, with Pyking's own
semantics: 32-bit integers, and its own runtime errors.

`pyk compile` writes a file named after the source, in the current
directory, unless --output says otherwise. The `esm` target writes three
more files beside its .js: a .node.js driver, an .html wrapper, and
package.json. The Java targets name the file and its class in Java's own
casing: foo_bar.pyk -> FooBar.java. The `pyking` target writes Pyking
again -- the program as the front end worked it out, with the types the
checker inferred and the loops the tail-call pass built.

`--run` builds and runs what was compiled, with the commands that
target's host uses, each printed before it runs:

  python           python3 prog.py
  nodejs           node prog.js
  esm              node prog.node.js
  html             xdg-open prog.html (open, on macOS)
  c89, c23         cc -std=<standard> -o prog prog.c, then prog
  java8, java17,   javac --release <version> prog.java, then java prog
  java21
  ocaml            ocamlopt -o prog prog.ml, then prog
  pyking           pyk prog.pyk

$CC, $JAVAC, $JAVA and $OCAMLOPT say which tool to use where there is a
choice. --run needs a file to run, so it cannot be combined with
--stdout."""


# --- what was asked for ----------------------------------------------

# The commands, and the one that is meant when a command word is left
# out. A bare `pyk foo.pyk` runs the program -- the thing someone with a
# file in their hand almost always wants -- and every other command says
# its name.
COMMANDS = {"repl": "repl", "compile": "compile", "c": "compile"}
DEFAULT_COMMAND = "interpret"


@dataclass(frozen=True)
class Options:
    """argv parsed into one value. Flags are shared by every command.
    Fields: command: String, filename: String?, target: String,
    output: String?, stdout: Bool, run: Bool, symbols: Bool,
    tokens: Bool, tail_calls: Bool."""
    command: str
    filename: str = None
    target: str = "python"
    output: str = None
    stdout: bool = False
    run: bool = False
    symbols: bool = False
    tokens: bool = False
    tail_calls: bool = True


def compiling_natively(options):
    """Whether this run hands the program to a backend whose own host
    eliminates tail calls, in which case the pass would only be undone
    (see docs/optimization.md). Options -> Bool"""
    return options.command == "compile" and options.target in NATIVE_TAIL_CALLS


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
            case "--run":
                flags["run"] = True
            case "--symbols":
                flags["symbols"] = True
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

    if flags.get("run") and flags.get("stdout"):
        usage_error("--run needs a file to run, so it cannot be used with --stdout")
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
    """Every stage before a backend, in the order they run: lexing,
    parsing, symbolizing, type checking, the mutability analysis, and
    the tail-call pass. Exits via fail() on the first error.
    Options -> ([Stmt], {Int: Type})"""
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

    # Every node gets a unique symbol before anything reasons about it:
    # `--symbols` prints them, `tmap` is keyed by them, and so is the
    # interpreter's call-free table.
    program = symbolize(program)

    # Pyking is statically typed, so this is not a mode: a program that
    # does not check is refused, whatever was asked for. The checker
    # carries a scope of its own, so it reports an unbound name too, in
    # analyses.py's words.
    try:
        tmap = typesystem.type_check(program)
    except (AnalysisError, typesystem.TypeError_) as e:
        fail(e)

    # The one rule types do not state: only a `var` may be written to
    # with `:=`, and nothing may shadow one.
    try:
        analyze_mutability(program)
    except AnalysisError as e:
        fail(e)

    # Tail calls become loops before anything reads the program, so what
    # the `pyking` target prints and what every backend compiles are the
    # same program. The pass builds nodes, so symbols are handed out again --
    # `symbolize` keeps the ones already given and continues past the
    # highest -- and it extends `tmap` for what it built, since the
    # checker will not run again to say what those nodes are.
    if options.tail_calls and not compiling_natively(options):
        program, tmap = optimization.optimize(program, tmap)
        program = symbolize(program)

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


def command_interpret(program):
    """Runs `pyk <file>` with the interpreter; prints a runtime error
    (with a truncated stack trace) if one occurs. [Stmt] -> Int"""
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


def command_compile(program, tmap, options):
    """Runs `pyk compile <file>`: translates the program for
    options.target and writes, or prints (--stdout), the result. tmap is
    the checker's table, which only the OCaml backend reads.
    [Stmt] -> {Int: Type}? -> Options -> Int"""
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

    if target == execution.PYKING_TARGET:
        # Pyking back out again: the program as the front end worked it
        # out, with the checker's types and the tail-call pass's loops.
        # It is printed *before* `apply_signatures`, so a `def name :
        # type` line stays the line the source wrote rather than being
        # folded onto its header.
        pyking_source = pprint_program(program, symbols=options.symbols, tmap=tmap)
        if options.stdout:
            print(pyking_source)
        else:
            write(output_path, pyking_source + "\n")
    elif target == "python":
        program = apply_signatures(program)
        py_source = pprint_py_program(translate_program(program, tmap))
        if options.stdout:
            print(py_source)
        else:
            write(output_path, py_source + "\n")
    elif target in target_c.STANDARDS:
        # One backend, two standards: the difference is in how the C is
        # printed, not in what it means.
        program = apply_signatures(program)
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
        program = apply_signatures(program)
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
        # The one backend that infers nothing: it reads the types back
        # out of the table `front_end` filled, which is why this target
        # type-checks whether or not `--typecheck` was passed (see
        # `required` there), and why a program that does not check has
        # already been refused before this point.
        program = apply_signatures(program)
        try:
            ocaml_program = target_ocaml.translate_program(program, tmap)
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
        program = apply_signatures(program)
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

    if options.run:
        # `--stdout` wrote no file, and parse_args already refused the
        # combination, so there is always something here to run.
        return execution.execute(target, output_path)
    return 0


def main(argv):
    """Runs pyk. [String] -> Int"""
    options = parse_args(argv)
    if options.command == "repl":
        return command_repl()

    program, tmap = front_end(options)

    # A `def name : type` line is another spelling of the annotations a
    # header could carry, so it is folded onto the header before a
    # backend or the interpreter reads the program: downstream there is
    # then one shape to read, and a backend that cannot represent a type
    # still sees the type it must refuse. The `pyking` target is the
    # exception, and folds nothing -- it prints the program as it stands.
    if options.command == "compile":
        return command_compile(program, tmap, options)
    return command_interpret(apply_signatures(program))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
