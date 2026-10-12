#!/usr/bin/env python3
"""Runs every test suite and reports them together: what `make test`
calls.

The nine suites stay nine separate scripts, each runnable on its own --
this one sequences them, keeps their output intact, and adds the
combined summary at the end. It runs *all* of them even when one fails,
so a single broken case does not hide what the other eight would have
said, and exits non-zero if any did.

`--target` narrows the program suite to one target or one family, and
the other eight are skipped: none of them is a target, and none would
mean anything narrowed to one. `--suite` runs only the suites named,
comma-separated (`--suite tinyweb`, `--suite repl,lsp`).

Usage: python3 tests/test_all.py [--jobs N] [--target T] [--suite S,...]
                                 [--compiler CMD]

Functions:
    parse_args(argv) -- the flags, as a map.
    suites(args) -- the suites to run, in order, with their arguments.
    report(tally, broken, skipped, reason) -- the combined summary.
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
    """`--jobs N`, `--target T`, `--suite S,...` and `--compiler CMD`, in
    any order. A suite there is none of, or a target with no programs
    suite to narrow, is refused. [String] -> {String: String}"""
    known = ("--jobs", "--target", "--suite", "--compiler")
    args = {}
    rest = list(argv)
    while rest:
        flag = rest.pop(0)
        if flag not in known or not rest:
            print(f"usage: test_all.py [--jobs N] [--target T] [--suite S,...] "
                  f"[--compiler CMD]", file=sys.stderr)
            sys.exit(2)
        args[flag] = rest.pop(0)
    if "--suite" in args:
        names = [name for name, _, _ in suites({})]
        unknown = [s for s in _named(args) if s not in names]
        if unknown:
            print(f"test_all.py: no suite {', '.join(unknown)}; the suites are "
                  f"{', '.join(names)}", file=sys.stderr)
            sys.exit(2)
        if "--target" in args and "programs" not in _named(args):
            print("test_all.py: --target narrows the programs suite, which "
                  "--suite leaves out", file=sys.stderr)
            sys.exit(2)
    return args


def _named(args):
    """The suites `--suite` names. {String: String} -> [String]"""
    return [s.strip() for s in args["--suite"].split(",") if s.strip()]


def suites(args):
    """The suites to run, in order: (name, script, arguments). The last
    eight are skipped when a target was named, since none of them is a
    target, and only those `--suite` names are run.
    {String: String} -> [(String, String, [String])]"""
    compiler = ["--compiler", args["--compiler"]] if "--compiler" in args else []
    program = []
    if "--jobs" in args:
        program += ["--jobs", args["--jobs"]]
    if "--target" in args:
        program += ["--target", args["--target"]]
    found = [("programs", "test_script.py", program + compiler)]
    if "--target" not in args:
        found += [
        ("repl", "test_repl.py", compiler),
        ("libpath", "test_libpath.py", compiler),
        ("playground", "test_playground.py", []),
        ("notebook", "test_notebook.py", compiler),
        ("packaging", "test_packaging.py", compiler),
        ("site", "test_site.py", compiler),
        ("tinyweb", "test_tinyweb.py", compiler),
        ("lsp", "test_lsp.py", compiler),
        ]
    if "--suite" in args:
        found = [entry for entry in found if entry[0] in _named(args)]
    return found


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
        reason = (f"--target {args['--target']}" if "--target" in args
                  else f"--suite {args.get('--suite')}")
        return report(tally, broken, skipped, reason)
    finally:
        os.unlink(tally)


def _reported(tally, name):
    """Whether this suite reached its own footer. Path -> String -> Bool"""
    return any(written == name for written, _, _ in suite.read_tally(tally))


def report(tally, broken, skipped, reason):
    """The combined summary: one line per suite, then the totals, and why
    any suite was skipped. Path -> [String] -> [String] -> String -> Int"""
    counted = suite.read_tally(tally)
    suite.heading("all suites")
    for name, passed, failed in counted:
        print("  " + suite.COUNTS.format(
            name=name, passed=passed, failed=failed))
    for name in broken:
        print(f"  {name:<12} did not finish")
    for name in skipped:
        print(f"  {name:<12} skipped ({reason})")
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
