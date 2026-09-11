#!/usr/bin/env python3
"""Runs the library search path's own test cases: how `pyk` resolves an
imported module through the four levels it looks in, and how it refuses
one it cannot find.

The `.pyk` suite in test_script.py runs (program, target) pairs, so
nothing there can reach any of this: the order of `-L` flags, an
environment variable, a name that resolves in two places at once, and
the wording of a failure are properties of the *invocation* rather than
of a program. This covers those.

Each case builds a throwaway tree of tiny libraries, each exporting a
`tag()` that answers with its own name, and runs the program with the
interpreter -- so what is printed says which library was actually
found. See docs/libraries.md, "The search path".

The built-in level (a `lib/` beside the executable) is not exercised
here: it is what the whole standard library in the `.pyk` suite already
resolves through.

Usage: python3 tests/test_libpath.py [--compiler CMD]

Functions:
    cases() -- every case, in the order they are reported.
    run(compiler, case, root) -- one case; answers (ok, detail).
    main(argv) -- the command-line entry point.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
DEFAULT_COMPILER = [str(REPO / "pyk")]
# Long enough for a compile that has gone wrong to be reported as a
# failure rather than as a hang.
STEP_TIMEOUT = 60
# The separator a path list uses inside an environment variable, which
# src/pyk.ml takes from the platform for the same reason every other
# tool on it does.
SEPARATOR = ";" if os.name == "nt" else ":"


def library(directory, name, tag, external=False, body=True):
    """A library folder holding one module: `<directory>/<name>/`, with
    `tag()` answering `tag`. `external` writes a declaration file
    instead, and `body` False writes the folder and no module at all --
    which is what a library missing its own source looks like.
    Path -> String -> String -> Bool -> Bool -> ()"""
    folder = directory / name
    folder.mkdir(parents=True, exist_ok=True)
    if not body:
        return
    if external:
        (folder / f"{name}.external.pyk").write_text(
            f"public def tag : () -> String\n")
        return
    (folder / f"{name}.pyk").write_text(
        "public def tag() -> String:\n"
        f'    return "{tag}"\n')


def program(directory, name="prog.pyk", module="mylib"):
    """A program importing one module and printing its tag.
    Path -> String -> String -> Path"""
    path = directory / name
    path.write_text(f"import {module}\n\nprint({module}.tag())\n")
    return path


def cases():
    """Every case, in the order they are reported. Each answers
    (name, build), where `build` prepares a tree under a fresh directory
    and answers (arguments, environment, expected) -- `expected` being
    the text the run must print, or a fragment its refusal must contain.
    () -> [(String, Callable)]"""

    def from_flag(root):
        library(root / "libs", "mylib", "flag")
        return ([f"-L{root / 'libs'}"], {}, "flag\n")

    def from_flag_separate(root):
        library(root / "libs", "mylib", "flag")
        return (["-L", str(root / "libs")], {}, "flag\n")

    def from_environment(root):
        library(root / "libs", "mylib", "environment")
        return ([], {"PYKING_LIB_PATH": str(root / "libs")}, "environment\n")

    def local_beats_flag(root):
        # A module beside the importing file is level 1, so it wins even
        # though a library of the same name is on the path.
        (root / "mylib.pyk").write_text(
            'public def tag() -> String:\n    return "local"\n')
        library(root / "libs", "mylib", "flag")
        return ([f"-L{root / 'libs'}"], {}, "local\n")

    def flag_beats_environment(root):
        library(root / "flagged", "mylib", "flag")
        library(root / "environed", "mylib", "environment")
        return (
            [f"-L{root / 'flagged'}"],
            {"PYKING_LIB_PATH": str(root / "environed")},
            "flag\n",
        )

    def flags_left_to_right(root):
        library(root / "first", "mylib", "first")
        library(root / "second", "mylib", "second")
        return (
            [f"-L{root / 'first'}", f"-L{root / 'second'}"],
            {},
            "first\n",
        )

    def environment_left_to_right(root):
        library(root / "first", "mylib", "first")
        library(root / "second", "mylib", "second")
        joined = SEPARATOR.join([str(root / "first"), str(root / "second")])
        return ([], {"PYKING_LIB_PATH": joined}, "first\n")

    def environment_separator_skips_empty(root):
        # A trailing separator is an empty entry, and an empty entry is
        # dropped rather than read as the current directory.
        library(root / "libs", "mylib", "environment")
        joined = SEPARATOR.join(["", str(root / "libs"), ""])
        return ([], {"PYKING_LIB_PATH": joined}, "environment\n")

    def unknown_module(root):
        return ([], {}, "cannot read module 'mylib'")

    def unknown_module_names_paths(root):
        # The refusal has to say where it looked, in order and with
        # where each candidate came from.
        library(root / "libs", "other", "other")
        return ([f"-L{root / 'libs'}"], {}, "(-L)")

    def flag_at_missing_directory(root):
        # A path that is not there is not an error in itself; it just
        # holds nothing, and the module is still unresolved.
        return ([f"-L{root / 'nowhere'}"], {}, "cannot read module 'mylib'")

    def library_folder_without_module(root):
        library(root / "libs", "mylib", "", body=False)
        return ([f"-L{root / 'libs'}"], {}, "cannot read module 'mylib'")

    def declared_twice(root):
        # One level holding both files is refused: which of the two was
        # meant would be a guess.
        library(root / "libs", "mylib", "written")
        (root / "libs" / "mylib" / "mylib.external.pyk").write_text(
            "public def tag : () -> String\n")
        return ([f"-L{root / 'libs'}"], {}, "is declared twice")

    return [
        ("from -Lpath", from_flag),
        ("from -L path", from_flag_separate),
        ("from PYKING_LIB_PATH", from_environment),
        ("local beats -L", local_beats_flag),
        ("-L beats PYKING_LIB_PATH", flag_beats_environment),
        ("two -L, left to right", flags_left_to_right),
        ("PYKING_LIB_PATH, left to right", environment_left_to_right),
        ("PYKING_LIB_PATH skips an empty entry",
         environment_separator_skips_empty),
        ("FAILS: unknown module", unknown_module),
        ("FAILS: refusal names the paths tried", unknown_module_names_paths),
        ("FAILS: -L at a missing directory", flag_at_missing_directory),
        ("FAILS: library folder with no module", library_folder_without_module),
        ("FAILS: declared twice in one level", declared_twice),
    ]


def run(compiler, build, root):
    """One case: prepares its tree, runs the program, and answers
    (ok, detail). A case whose expected text is a whole printed output
    must match it exactly; one naming a fragment of a refusal must
    contain it, since a refusal also carries absolute paths.
    [String] -> Callable -> Path -> (Bool, String)"""
    arguments, environment, expected = build(root)
    source = program(root)
    child = dict(os.environ)
    child.pop("PYKING_LIB_PATH", None)
    child.update(environment)
    try:
        result = subprocess.run(
            compiler + arguments + [str(source)],
            capture_output=True, text=True, timeout=STEP_TIMEOUT,
            cwd=root, env=child,
        )
    except subprocess.TimeoutExpired:
        return False, f"timed out after {STEP_TIMEOUT} seconds"
    both = result.stdout + result.stderr
    if expected.endswith("\n"):
        if result.stdout == expected:
            return True, ""
        return False, f"expected {expected!r}, got {both!r}"
    # Every message the driver prints is reflowed to its own width, so a
    # fragment is looked for with runs of whitespace flattened rather
    # than as it happens to have been broken across lines.
    flattened = " ".join(both.split())
    if " ".join(expected.split()) in flattened:
        return True, ""
    return False, f"expected {expected!r} somewhere in {both!r}"


def parse_args(argv):
    """`--compiler CMD` or the default. [String] -> [String]"""
    if argv[:1] == ["--compiler"]:
        if len(argv) < 2:
            print("usage: test_libpath.py [--compiler CMD]", file=sys.stderr)
            sys.exit(2)
        return argv[1].split()
    if argv:
        print("usage: test_libpath.py [--compiler CMD]", file=sys.stderr)
        sys.exit(2)
    return list(DEFAULT_COMPILER)


def main(argv):
    """Runs every case and reports it. [String] -> Int"""
    compiler = parse_args(argv)
    found = cases()
    failed = 0
    for name, build in found:
        directory = tempfile.mkdtemp(prefix="pyk-libpath-")
        try:
            ok, detail = run(compiler, build, Path(directory))
        finally:
            shutil.rmtree(directory, ignore_errors=True)
        if ok:
            print(f"libpath: {name} OK.")
            continue
        failed += 1
        print(f"libpath: {name} FAILED")
        print(f"  {detail}")
    print()
    print(f"  libpath {len(found) - failed} passed, {failed} failed "
          f"(of {len(found)} cases)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
