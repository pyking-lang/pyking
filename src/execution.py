"""What `--run` runs: the commands each target's host uses to build and
run what `pyk compile` wrote. One table, so the driver stays a sequencer
and each target's toolchain is stated in one place. See docs/pyk.md
("Running what was compiled").

The commands are the ones a user would type by hand, and each is printed
before it runs -- to stderr, so a program's own output on stdout stays
its own. The toolchain is taken from the environment where there is a
choice about it: $CC, $JAVAC, $JAVA and $OCAMLOPT.

Data structures:
    Plan -- the commands one target needs, and where to run them.

Functions:
    plan_for(target, path, modules) -- the commands that build and run
        path, given the program's other files in dependency order.
    execute(target, path, modules) -- runs them; returns the program's
        status.
"""

import os
import shlex
import subprocess
import sys
from dataclasses import dataclass

import target_c
import target_java
import target_js_packaging
import target_ocaml

# Where there is a choice of tool, the environment makes it -- the same
# names tests/test_script.py reads, so a machine set up for one is set up
# for the other.
C_COMPILER = os.environ.get("CC", "cc")
JAVA_COMPILER = os.environ.get("JAVAC", "javac")
JAVA_RUNTIME = os.environ.get("JAVA", "java")
# Plain `ocamlopt`: nothing here needs a package, and `ocamlfind` adds a
# dependency on a working ld.conf for no gain. Split, since an override
# may still be more than one word.
OCAML_COMPILER = os.environ.get("OCAMLOPT", "ocamlopt").split()

# Opening a page is the one "run" that hands the file to something else
# entirely, and the two systems spell it differently.
BROWSER = "open" if sys.platform == "darwin" else "xdg-open"

# The interpreter, reached the way this process was: `pyking` compiles to
# Pyking, and what runs Pyking is this compiler.
PYK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pyk.py")

PYKING_TARGET = "pyking"


@dataclass(frozen=True)
class Plan:
    """The commands one target needs to turn its output into a running
    program. Fields: build: [[String]] (commands run first, each of
    which must succeed), run: [String] (the program itself),
    directory: String (where to run them)."""
    build: list
    run: list
    directory: str


def plan_for(target, path, modules=()):
    """The commands that build and run what was compiled to path.
    `modules` names the other files the program was compiled to, in the
    order they must be built and run -- dependencies first -- which is
    what the targets that link a program rather than importing at run
    time need. String -> String -> [String] -> Plan"""
    # Everything is made absolute, since the commands run in the output
    # file's own directory rather than the one `pyk` was called from.
    path = os.path.abspath(path)
    directory = os.path.dirname(path)
    binary, _ = os.path.splitext(path)
    others = [os.path.abspath(other) for other in modules]

    if target == "python":
        return Plan([], [sys.executable, path], directory)
    if target == PYKING_TARGET:
        return Plan([], [sys.executable, PYK, path], directory)
    if target == "nodejs":
        return Plan([], ["node", path], directory)
    if target == "esm":
        # The generated driver is the file a user would run: it imports
        # the module and supplies it a runtime.
        return Plan([], ["node", binary + ".node.js"], directory)
    if target == "html":
        return Plan([], [BROWSER, path], directory)
    if target in target_c.STANDARDS:
        # Every translation unit of the program, the modules first: each
        # is a file of its own, and `main` is in the last.
        return Plan(
            [[C_COMPILER, f"-std={target}", "-o", binary] + others + [path]],
            [binary],
            directory,
        )
    if target in target_java.VERSIONS:
        # Java's class is its file's name, which is what the compiler
        # already made sure of when it chose that name.
        class_name = os.path.splitext(os.path.basename(path))[0]
        return Plan(
            [[JAVA_COMPILER, "--release", target.removeprefix("java"),
              "-d", directory] + others + [path]],
            [JAVA_RUNTIME, "-cp", directory, class_name],
            directory,
        )
    if target == target_ocaml.TARGET:
        # OCaml links in the order given, and runs each module's top
        # level in that order, which is why the modules come first: a
        # module runs after everything it imports. An interface is
        # named ahead of the implementation it describes.
        sources = []
        for other in others:
            interface = os.path.splitext(other)[0] + target_ocaml.INTERFACE_EXTENSION
            if os.path.exists(interface):
                sources.append(interface)
            sources.append(other)
        return Plan(
            [OCAML_COMPILER + ["-I", directory, "-o", binary] + sources + [path]],
            [binary],
            directory,
        )
    raise KeyError(target)


def execute(target, path, modules=()):
    """Builds and runs what was compiled to path, printing each command
    before it runs. `modules` names the program's other files, in the
    order they must be built. Returns the program's exit status, or that
    of the build step that failed.
    String -> String -> [String] -> Int"""
    plan = plan_for(target, path, modules)
    for command in plan.build:
        status = _run(command, plan.directory)
        if status != 0:
            return status
    return _run(plan.run, plan.directory)


def _shown(command, directory):
    """One command as it is announced: a word naming something in the
    directory the command runs in is shortened to what a user standing
    there would type -- `.` for the directory itself, and `./name` where
    the name is the program being run, since a bare name would be looked
    up on PATH. [String] -> String -> String"""
    def word(text, first):
        if text == directory:
            return "."
        if os.path.isabs(text) and os.path.dirname(text) == directory:
            return ("./" if first else "") + os.path.basename(text)
        return text

    return shlex.join(
        word(text, index == 0) for index, text in enumerate(command)
    )


def _run(command, directory):
    """Announces one command and runs it. [String] -> String -> Int"""
    print(f"$ {_shown(command, directory)}", file=sys.stderr)
    sys.stderr.flush()
    try:
        return subprocess.run(command, cwd=directory).returncode
    except FileNotFoundError:
        print(f"pyk: '{command[0]}' not found", file=sys.stderr)
        return 127
