#!/usr/bin/env python3
"""Runs every test suite and reports them together: what `make test`
calls.

The six suites stay six separate scripts, each runnable on its own --
this one sequences them, keeps their output intact, and adds the
combined summary at the end. It runs *all* of them even when one fails,
so a single broken case does not hide what the other five would have
said, and exits non-zero if any did.

`--target` narrows the program suite to one target or one family, and
the other five are skipped: none of them is a target, and none would
mean anything narrowed to one.

Usage: python3 tests/test_all.py [--jobs N] [--target T] [--compiler CMD]

Functions:
    parse_args(argv) -- the flags, as a map.
    suites(args) -- the suites to run, in order, with their arguments.
    report(tally, broken, skipped, target) -- the combined summary.
    main(argv) -- the command-line entry point.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import suite  # noqa: E402  (after sys.path, which is what makes it findable)


def parse_args(argv):
    """`--jobs N`, `--target T` and `--compiler CMD`, in any order.
    [String] -> {String: String}"""
    known = ("--jobs", "--target", "--compiler")
    args = {}
    rest = list(argv)
    while rest:
        flag = rest.pop(0)
        if flag not in known or not rest:
            print(f"usage: test_all.py [--jobs N] [--target T] "
                  f"[--compiler CMD]", file=sys.stderr)
            sys.exit(2)
        args[flag] = rest.pop(0)
    return args


def suites(args):
    """The suites to run, in order: (name, script, arguments). The last
    five are skipped when a target was named, since none of them is a
    target. {String: String} -> [(String, String, [String])]"""
    compiler = ["--compiler", args["--compiler"]] if "--compiler" in args else []
    program = []
    if "--jobs" in args:
        program += ["--jobs", args["--jobs"]]
    if "--target" in args:
        program += ["--target", args["--target"]]
    found = [("programs", "test_script.py", program + compiler)]
    if "--target" in args:
        return found
    return found + [
        ("repl", "test_repl.py", compiler),
        ("libpath", "test_libpath.py", compiler),
        ("playground", "test_playground.py", []),
        ("notebook", "test_notebook.py", compiler),
        ("packaging", "test_packaging.py", compiler),
    ]


def main(argv):
    """Runs every suite and reports them together. [String] -> Int"""
    args = parse_args(argv)
    handle, tally = tempfile.mkstemp(prefix="pyk-tally-")
    os.close(handle)
    environment = dict(os.environ, PYK_TEST_TALLY=tally)
    broken = []
    try:
        for name, script, arguments in suites(args):
            suite.heading(name)
            # Not captured: a suite reports as it goes, and a run of this
            # one takes minutes.
            result = subprocess.run(
                [sys.executable, str(HERE / script)] + arguments,
                env=environment,
            )
            if result.returncode != 0 and not _reported(tally, name):
                # The suite failed without reaching its own footer -- a
                # missing bundle, a compiler that would not build. There
                # is no tally to add up, so it is named on its own.
                broken.append(name)
        ran = [name for name, _, _ in suites(args)]
        skipped = [name for name, _, _ in suites({}) if name not in ran]
        return report(tally, broken, skipped, args.get("--target"))
    finally:
        os.unlink(tally)


def _reported(tally, name):
    """Whether this suite reached its own footer. Path -> String -> Bool"""
    return any(written == name for written, _, _ in suite.read_tally(tally))


def report(tally, broken, skipped, target):
    """The combined summary: one line per suite, then the totals.
    Path -> [String] -> [String] -> String? -> Int"""
    counted = suite.read_tally(tally)
    suite.heading("all suites")
    for name, passed, failed in counted:
        print("  " + suite.COUNTS.format(
            name=name, passed=passed, failed=failed))
    for name in broken:
        print(f"  {name:<12} did not finish")
    for name in skipped:
        print(f"  {name:<12} skipped (--target {target})")
    passed = sum(entry[1] for entry in counted)
    failed = sum(entry[2] for entry in counted)
    print()
    print(f"  {passed + failed} checks in {len(counted)} "
          f"suite{'' if len(counted) == 1 else 's'}, {failed} failed.")
    if failed or broken:
        print("  FAILED")
        return 1
    print("  ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
