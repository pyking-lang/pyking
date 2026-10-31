#!/usr/bin/env python3
"""Runs the warnings' own test cases: every tests/warnings/*.pyk that has
a sibling .out, run with `pyk` and the arguments its first line names,
with what it wrote and how it ended compared against the .out.

A warning is printed when `pyk` checks a program, before anything runs,
so the program suite -- which compares what a *compiled* program writes
-- cannot see one. This one runs `pyk` itself. A case's first line may
say what `pyk` is given before the file:

    # pyk: -Wall -Werror
    # pyk: compile -t python --stdout -Werror=unused-binding

and a case with no such line is run with no flag at all, which is what
pins the defaults. The .out holds standard error and standard output
together, in the order they were written -- every warning comes before
the program's first line -- and then `exit N`. A .pyk with no .out is a
module another case imports.

Each case runs in tests/warnings/ under its own name, so the file named
in every warning is the same wherever the suite is started from.

Usage: python3 tests/test_warnings.py [--compiler CMD] [--update]

`--update` rewrites every .out from what `pyk` now writes; read the diff
before keeping it.

Functions:
    cases() -- every case, in name order.
    arguments(case) -- what its first line says `pyk` is given.
    run(compiler, case) -- what one case writes, as its .out holds it.
    main(argv) -- the command-line entry point.
"""

import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import suite  # noqa: E402  (after sys.path, which is what finds it)

CASES = HERE / "warnings"
DEFAULT_COMPILER = [str(HERE.parent / "pyk")]
TIMEOUT = 60
MARKER = "# pyk:"


def cases():
    """Every case: a .pyk with a .out beside it, in name order. () -> [Path]"""
    return sorted(p for p in CASES.glob("*.pyk") if p.with_suffix(".out").exists())


def arguments(case):
    """What the case's first line says `pyk` is given before the file:
    `# pyk: -Wall` is ["-Wall"], and no such line is none. Path -> [String]"""
    first = case.read_text().split("\n", 1)[0]
    return first[len(MARKER):].split() if first.startswith(MARKER) else []


def run(compiler, case):
    """Runs one case: what it wrote, both streams in the order written,
    and `exit N`. [String] -> Path -> String"""
    given = arguments(case)
    # A command (`compile`) goes first, as `pyk` reads one; the file
    # comes after every flag.
    command = given[:1] if given[:1] == ["compile"] else []
    flags = given[len(command):]
    try:
        result = subprocess.run(
            compiler + command + flags + [case.name],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=TIMEOUT,
            cwd=CASES,
        )
    except subprocess.TimeoutExpired:
        return f"<timed out after {TIMEOUT}s>\n"
    return f"{result.stdout}exit {result.returncode}\n"


def main(argv):
    """argv in, exit status out. [String] -> Int"""
    compiler = DEFAULT_COMPILER
    if "--compiler" in argv:
        compiler = argv[argv.index("--compiler") + 1].split()
        # A path to the compiler is made absolute, since each case runs
        # in tests/warnings/.
        if os.sep in compiler[0]:
            compiler[0] = os.path.abspath(compiler[0])
    update = "--update" in argv
    found = cases()
    if not found:
        print("no cases in tests/warnings/")
        return 1
    failed = 0
    for case in found:
        actual = run(compiler, case)
        expected_path = case.with_suffix(".out")
        name = case.relative_to(HERE.parent)
        if update:
            expected_path.write_text(actual)
        expected = expected_path.read_text()
        if actual == expected:
            print(f"warnings: {name} OK.")
            continue
        failed += 1
        print(f"warnings: {name} FAILED")
        for line in _diff(expected, actual):
            print(f"  {line}")
    suite.footer("warnings", len(found) - failed, failed,
                 f"{len(found)} program{'' if len(found) == 1 else 's'}")
    return 1 if failed else 0


def _diff(expected, actual):
    """The two side by side, line by line. String -> String -> [String]"""
    import difflib
    return list(difflib.unified_diff(
        expected.splitlines(), actual.splitlines(),
        fromfile="expected", tofile="actual", lineterm=""))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
