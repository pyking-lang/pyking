"""The driver: what `pyk` on the command line runs. Parses argv,
sequences the front-end stages, and dispatches to one of three commands
(`pyk <file>`, `repl`, `compile`). Every program is type-checked, so a
program that does not check is refused whatever was asked for. A program
of several modules runs the middle of that sequence once per module, in
the order src/module.py puts them in. Each
backend owns its own translation, packaging and file naming. See
docs/architecture.md ("Command line"), docs/modules.md and
docs/source.md ("pyk.py").

Data structures:
    Options -- argv parsed into one value: command, filename, flags.

Functions:
    main(argv) -- argv in, exit status out.
    parse_args(argv) -- argv, as an Options.
    front_end(options) -- loads the program's modules, then checks and
        analyses each of them.
    format_error(error) -- formats any front-end error as one line.
    command_interpret(checked) -- `pyk <file>`.
    command_repl() -- `pyk repl`.
    command_compile(checked, options) -- `pyk compile`.
    compile_program(checked, target, output_path, options) -- every file
        the program compiles to, and the one --stdout prints.
    wrap(text) -- reflows text to the driver's line width.
"""

import os
import sys
import textwrap
from dataclasses import dataclass, replace

from analyses import (
    analyze_mutability, apply_signatures, highest_sym, symbolize, AnalysisError,
)
import execution
import optimization
from lexer import pprint_info, pprint_token, LexError
import module
from parser import ParseError
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
  --no-typechecking     skip the type checker, and with it the
                        mutability analysis and the tail-call pass,
                        which both need what it works out. Only
                        `compile -t pyking` accepts it: every other
                        target and the interpreter need the types.
                        What it prints is then the program as written,
                        with the source's own annotations -- which is
                        what the OCaml bootstrap in ocaml-src/ prints,
                        and what `make test-ocaml` compares.
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
    tokens: Bool, tail_calls: Bool, typecheck: Bool."""
    command: str
    filename: str = None
    target: str = "python"
    output: str = None
    stdout: bool = False
    run: bool = False
    symbols: bool = False
    tokens: bool = False
    tail_calls: bool = True
    typecheck: bool = True


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
            case "--no-typechecking":
                flags["typecheck"] = False
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
    if not flags.get("typecheck", True) and (
        command != "compile" or flags.get("target") != execution.PYKING_TARGET
    ):
        # Every backend but this one reads the types, and so does the
        # interpreter: the Python one to know what to format, the OCaml
        # one for every type it emits, and the rest through the
        # tail-call pass, which the checker's table is what makes
        # decidable. `-t pyking` is the one that can print a program
        # nothing has checked, since it prints the program itself.
        usage_error(
            "--no-typechecking only applies to 'pyk compile -t "
            f"{execution.PYKING_TARGET}': every other target, and the "
            "interpreter, need the types the checker works out"
        )
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
    (module.ModuleError, "Module error"),
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
    """Every stage before a backend, over every module the program
    reaches: loading (which lexes, parses, symbolizes and orders them),
    type checking, the mutability analysis, and the tail-call pass, each
    module in the order it is loaded in -- so a module is checked after
    everything it imports, against what those export. Under
    `--no-typechecking` it stops after loading, and every table is None.
    Exits via fail() on the first error.
    Options -> [(Module, {Int: Type}?)]"""
    # `--no-typechecking` is the one flag that stops the front end early,
    # and comparing this front end against the OCaml one in ocaml-src/
    # is the only reason it exists. That one reads a single file and has
    # no module system at all, so neither does this: the file named is
    # lexed, parsed and symbolized, nothing it imports is read, and
    # `-t pyking` -- the only target that accepts the flag (see
    # `parse_args`) -- prints the program the parser built, with the
    # source's own annotations.
    try:
        if not options.typecheck:
            unit = module.read_file(options.filename)
            report_tokens([unit], options)
            return [(replace(unit, stmts=symbolize(unit.stmts)), None)]
        modules = module.load(options.filename)
    except (LexError, ParseError, AnalysisError, module.ModuleError) as e:
        fail(e)

    report_tokens(modules, options)

    # Every module is checked against what the ones it imports export,
    # which is why they are checked in this order -- and `make_sigmap`
    # is what turns each result into the next module's input. It is made
    # from the program the *checker* saw, since the tail-call pass below
    # can only change how a module computes what it exports, never what
    # it exports or at what type.
    checked, sigmaps = [], {}
    # The tail-call pass builds nodes and so hands out more symbols;
    # they continue past the highest in the whole program, since one
    # numbering spans every module of it (see analyses.symbolize).
    highest = max([highest_sym(unit.stmts) for unit in modules], default=0)
    for unit in modules:
        tmap = check_module(unit, module.sigmaps_for(unit, sigmaps))
        sigmap = module.make_sigmap(unit.stmts, tmap)
        sigmaps[unit.name] = sigmap
        stmts, tmap, highest = optimize_module(
            unit.stmts, tmap, highest, options
        )
        checked.append((replace(unit, stmts=stmts, sigmap=sigmap), tmap))
    return checked


def report_tokens(modules, options):
    """Prints the token stream of every module of the program under
    `--tokens`, in the order they are compiled; for a one-file program
    that is the one file. [Module] -> Options -> ()"""
    if not options.tokens:
        return
    for unit in modules:
        print("\n".join(
            f"{pprint_info(t.info)} {pprint_token(t)}" for t in unit.tokens
        ))
        print("")


def check_module(unit, sigmaps):
    """One module through the type checker and the mutability analysis,
    returning the types it worked out. Exits via fail() on the first
    error. Module -> [(String, {String: Type})] -> {Int: Type}"""
    # Pyking is statically typed, so this is not a mode: a program that
    # does not check is refused, whatever was asked for. The checker
    # carries a scope of its own, so it reports an unbound name too, in
    # analyses.py's words.
    try:
        tmap = typesystem.type_check(unit.stmts, sigmaps)
    except (AnalysisError, typesystem.TypeError_) as e:
        fail(e)

    # The one rule types do not state: only a `var` may be written to
    # with `:=`, and nothing may shadow one.
    try:
        analyze_mutability(unit.stmts)
    except AnalysisError as e:
        fail(e)
    return tmap


def optimize_module(program, tmap, highest, options):
    """One module through the tail-call pass, with the symbols it hands
    out continuing past `highest` -- the highest anywhere in the program
    so far, which is what the next module continues past in turn.
    Tail calls become loops before anything reads the program, so what
    the `pyking` target prints and what every backend compiles are the
    same program.
    [Stmt] -> {Int: Type} -> Int -> Options -> ([Stmt], {Int: Type}, Int)"""
    if not (options.tail_calls and not compiling_natively(options)):
        return program, tmap, highest
    # The pass builds nodes, so symbols are handed out again --
    # `symbolize` keeps the ones already given -- and it extends `tmap`
    # for what it built, since the checker will not run again to say
    # what those nodes are.
    program, tmap = optimization.optimize(program, tmap)
    program = symbolize(program, highest)
    return program, tmap, max(highest, highest_sym(program))


# --- the commands ----------------------------------------------------


def command_repl():
    """Runs `pyk repl`. Imported lazily to avoid a cycle at import time.
    () -> Int"""
    import repl

    return repl.start(format_error)


# How many calls a runtime error's stack trace shows before it says how
# many more there were.
TRACE_LIMIT = 10


def command_interpret(checked):
    """Runs `pyk <file>` with the interpreter; prints a runtime error
    (with a truncated stack trace) if one occurs. Every module of the
    program runs, in the order it was checked in, each in a top level of
    its own. [(Module, {Int: Type})] -> Int"""
    units = [(unit.name, apply_signatures(unit.stmts)) for unit, _ in checked]
    state = interpreter.run_modules(units, interpreter.ConsoleHost())
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


def compile_program(checked, target, output_path, options):
    """Every file the program compiles to, as {path: contents}, and the
    text of the one `--stdout` prints -- the program's own module, since
    a module it imports is a file and `--stdout` writes none. A module
    is written beside the program's output under its own name, which is
    also what the generated import in that output names it by.
    [(Module, {Int: Type}?)] -> String -> String? -> Options
    -> ({String: String}, String)"""
    main_unit, _ = checked[-1]
    directory = os.path.dirname(output_path or "")

    if target in target_js_packaging.TARGETS:
        # The JavaScript targets package a whole program at once: `html`
        # has one file to put every module in, and the other two share
        # one runtime module between them.
        taken = target_js_packaging.reserved_names(
            [unit.name for unit, _ in checked]
        )
        return target_js_packaging.package_program(
            target,
            [(unit, translate_js(unit, target, taken)) for unit, _ in checked],
            output_path, options.stdout,
        )

    files, primary = {}, None
    for unit, tmap in checked:
        path = (output_path if unit is main_unit
                else os.path.join(directory, default_name(target, unit.name)))
        contents, companions = compile_unit(
            unit, tmap, target, checked, path, options
        )
        if unit is main_unit:
            primary = contents
        if path is not None:
            files[path] = contents
            files.update(companions)
    return files, primary


def translate_js(unit, target, taken):
    """One module through the JavaScript backend's language half.
    `taken` names the JavaScript the packager writes around it.
    Module -> String -> {String} -> [JsStmt]"""
    try:
        return target_js_core.translate_program(
            apply_signatures(unit.stmts), taken
        )
    except target_js_core.UnsupportedError as e:
        fail_unsupported(target, e)


def compile_unit(unit, tmap, target, checked, path, options):
    """One module compiled for one target: the text of its own file, and
    the companion files that go beside it -- a C header, an OCaml
    interface -- keyed by path. `checked` is the whole program, in the
    order its modules must run, which the program's own module needs to
    start them. Nothing is written here; a companion is left out
    entirely where there is no path to put it beside (`--stdout`).
    Module -> {Int: Type}? -> String -> [(Module, {Int: Type}?)] ->
    String? -> Options -> (String, {String: String})"""
    context = module.context(checked, unit)
    main, source = context.main, os.path.basename(unit.path)

    if target == execution.PYKING_TARGET:
        # Pyking back out again: the program as the front end worked it
        # out, with the checker's types and the tail-call pass's loops.
        # It is printed *before* `apply_signatures`, so a `def name :
        # type` line stays the line the source wrote rather than being
        # folded onto its header.
        return pprint_program(
            unit.stmts, symbols=options.symbols, tmap=tmap
        ) + "\n", {}

    program = apply_signatures(unit.stmts)

    if target == "python":
        return pprint_py_program(translate_program(program, tmap)) + "\n", {}

    if target in target_c.STANDARDS:
        # One backend, two standards: the difference is in how the C is
        # printed, not in what it means.
        try:
            c_program = target_c.translate_program(program, context)
        except target_c.UnsupportedError as e:
            fail_unsupported(target, e)
        text = target_c.pprint_c_program(c_program, target, source)
        if main or path is None:
            # The program's own module declares nothing for anyone else
            # to include, so it has no header.
            return text, {}
        header = os.path.join(
            os.path.dirname(path), unit.name + target_c.HEADER_EXTENSION
        )
        return text, {
            header: target_c.pprint_c_header(c_program, target, source)
        }

    if target in target_java.VERSIONS:
        # Java requires the public class to share its file's name
        # exactly. An explicit `--output` is trusted as-is: the class is
        # named after whatever file the caller chose. With none, `path`
        # was already picked in Java's own casing above, and the class
        # matches it too.
        class_name = (
            os.path.splitext(os.path.basename(path))[0] if path is not None
            else target_java.default_class_name(unit.name)
        )
        try:
            java_program = target_java.translate_program(program, context)
        except target_java.UnsupportedError as e:
            fail_unsupported(target, e)
        return target_java.pprint_java_program(
            java_program, target, class_name, source
        ), {}

    # The one backend that infers nothing: it reads the types back out
    # of the table `front_end` filled, which is why this target
    # type-checks whether or not `--typecheck` was passed, and why a
    # program that does not check has already been refused.
    try:
        ocaml_program = target_ocaml.translate_program(program, tmap, context)
    except target_ocaml.UnsupportedError as e:
        fail_unsupported(target, e)
    text = target_ocaml.pprint_ocaml_program(ocaml_program, source)
    if main or path is None:
        # Nothing imports the program's own module, so it needs no
        # interface saying what it exports.
        return text, {}
    interface = os.path.splitext(path)[0] + target_ocaml.INTERFACE_EXTENSION
    return text, {
        interface: target_ocaml.pprint_ocaml_interface(ocaml_program, source)
    }


def default_name(target, stem):
    """What a file compiled from `stem` is called when nothing says.
    The source's own name with the target's extension -- except for the
    Java targets, which require the public class to share its file's
    name exactly, so the name is Java-cased rather than the source's own
    spelling: `foo_bar.pyk` writes `FooBar.java`.
    String -> String -> String"""
    if target in target_java.VERSIONS:
        return target_java.default_class_name(stem) + ".java"
    return stem + EXTENSIONS[target]


def command_compile(checked, options):
    """Runs `pyk compile <file>`: translates every module of the program
    for options.target and writes the files, or prints the program's own
    module (--stdout). A module the program imports is written beside the
    program's own output, under its own name.
    [(Module, {Int: Type}?)] -> Options -> Int"""
    target, filename = options.target, options.filename
    main_unit, main_tmap = checked[-1]
    program, tmap = main_unit.stmts, main_tmap
    stem = os.path.splitext(os.path.basename(filename))[0]
    output_path = options.output

    if not options.stdout and output_path is None:
        # Nothing said where to put it: use the source file's own name,
        # with the target's extension, in the directory the command was
        # run from -- `pyk compile -t nodejs tests/hello.pyk` writes
        # `./hello.js`. For `esm` this is a stem, and the three files are
        # named from it.
        output_path = default_name(target, stem)

    # Every file the program was read from: the program's own, and every
    # module it imports. `-t pyking` writes `.pyk` files, and a module
    # is written under its own name, so without this a program compiled
    # into its own directory would overwrite the module beside it.
    sources = {os.path.abspath(unit.path) for unit, _ in checked}

    def write(path, contents):
        """Writes one output file; usage_error if it would overwrite a
        file the program was read from, or its directory does not exist.
        String -> String -> ()"""
        if os.path.abspath(path) in sources:
            what = (
                "the input file"
                if os.path.abspath(path) == os.path.abspath(filename)
                else f"'{os.path.basename(path)}', a module this program imports"
            )
            usage_error(
                f"writing '{path}' would overwrite {what}; choose a "
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

    directory = os.path.dirname(output_path or "")
    files, primary = compile_program(checked, target, output_path, options)

    if options.stdout:
        print(primary, end="")
        return 0

    for path, contents in files.items():
        if os.path.basename(path) == target_js_packaging.MODULE_MANIFEST:
            write_manifest(path, contents)
        else:
            write(path, contents)

    if options.run:
        # `--stdout` wrote no file, and parse_args already refused the
        # combination, so there is always something here to run. The
        # modules the program imports are named in the order they must
        # be built and run, which is the order they were compiled in.
        return execution.execute(
            target, output_path,
            [os.path.join(directory, default_name(target, unit.name))
             for unit, _ in checked[:-1]],
        )
    return 0


def main(argv):
    """Runs pyk. [String] -> Int"""
    options = parse_args(argv)
    if options.command == "repl":
        return command_repl()

    checked = front_end(options)

    # A `def name : type` line is another spelling of the annotations a
    # header could carry, so it is folded onto the header before a
    # backend or the interpreter reads the program: downstream there is
    # then one shape to read, and a backend that cannot represent a type
    # still sees the type it must refuse. The `pyking` target is the
    # exception, and folds nothing -- it prints the program as it stands.
    if options.command == "compile":
        return command_compile(checked, options)
    return command_interpret(checked)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
