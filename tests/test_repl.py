#!/usr/bin/env python3
"""Runs the REPL's own test cases: every tests/repl/*.repl fed to
`pyk repl` on standard input, with the session's combined output
compared against the sibling .out file.

The `.pyk` suite in test_script.py runs *files*, so nothing there
reaches the REPL: how an entry is checked against the ones before it,
what a value prints as, and what each meta-command answers are all
REPL-only. This covers those.

Piped input takes repl.ml's plain reader rather than the terminal
editor, so a case here exercises the session and not the keystroke
handling; the prompts appear inline in the expected output because that
is what a pipe sees. Editing itself -- history, cursor movement,
Escape -- is not covered.

Usage: python3 tests/test_repl.py [--compiler CMD]

Functions:
    cases() -- every .repl file, in name order.
    run(compiler, case) -- one case; answers (ok, actual, expected).
    main(argv) -- the command-line entry point.
"""

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import suite  # noqa: E402  (after sys.path, which is what finds it)

REPL_DIR = HERE / "repl"
DEFAULT_COMPILER = [str(HERE.parent / "pyk")]
TIMEOUT = 60


def cases():
    """Every .repl file, in name order. () -> [Path]"""
    return sorted(REPL_DIR.glob("*.repl"))


def run(compiler, case):
    """Feeds one case to `pyk repl` and compares the session's output
    with the sibling .out. [String] -> Path -> (Bool, String, String)"""
    expected_path = case.with_suffix(".out")
    expected = expected_path.read_text() if expected_path.exists() else None
    try:
        # stderr into stdout rather than captured beside it: a refusal is
        # reported on stderr and a value on stdout, and what a session
        # means is the two in the order they were written.
        result = subprocess.run(
            compiler + ["repl"],
            input=case.read_text(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return False, f"<timed out after {TIMEOUT}s>", expected
    actual = result.stdout
    if expected is None:
        return False, actual, None
    return actual == expected, actual, expected


def main(argv):
    """argv in, exit status out. [String] -> Int"""
    compiler = DEFAULT_COMPILER
    if "--compiler" in argv:
        compiler = argv[argv.index("--compiler") + 1].split()
    found = cases()
    if not found:
        print("no cases in tests/repl/")
        return 1
    failed = 0
    for case in found:
        ok, actual, expected = run(compiler, case)
        name = case.relative_to(HERE.parent)
        if ok:
            print(f"repl: {name} OK.")
            continue
        failed += 1
        if expected is None:
            print(f"repl: {name} FAILED -- no {case.with_suffix('.out').name}")
            print("  it produced:")
            for line in actual.splitlines():
                print(f"    {line}")
            continue
        print(f"repl: {name} FAILED")
        for line in _diff(expected, actual):
            print(f"  {line}")
    suite.footer("repl", len(found) - failed, failed,
                 f"{len(found)} session{'' if len(found) == 1 else 's'}")
    return 1 if failed else 0


def _diff(expected, actual):
    """The two side by side, line by line. String -> String -> [String]"""
    import difflib
    return list(difflib.unified_diff(
        expected.splitlines(), actual.splitlines(),
        fromfile="expected", tofile="actual", lineterm=""))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
