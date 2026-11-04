#!/usr/bin/env python3
"""Runs every test suite and reports them together: what `make test`
calls.

The fourteen suites stay fourteen separate scripts, each runnable on its own --
this one sequences them, keeps their output intact, and adds the
combined summary at the end. It runs *all* of them even when one fails,
so a single broken case does not hide what the other thirteen would have
said, and exits non-zero if any did.

`--target` narrows the program suite to one target or one family, and
the other thirteen are skipped: none of them is a target, and none would
mean anything narrowed to one. `--suite` runs only the suites named,
comma-separated (`--suite tinyweb`, `--suite repl,lsp`).

`--quick PERCENT` is `make quicktest`: the programs suite runs the
latest version of each family only, and node, web, C and Java on
PERCENT of their cases; packaging, tinyweb and lsp run PERCENT of their
checks. The choice is random, by `--seed N`, which is printed so a run
can be repeated.

`--stop-at-error` is `make test STOP_AT_ERROR=true`: the first failure
ends the run. The driver reads each suite's output as it is printed, and
at the first `FAILED` line lets the rest of that failure's report
through, interrupts the suite, runs none after it, and prints the
summary of what ran. Suites that gather their failures and print them
at the end print each one as it happens instead (`suite.stop_at_error`).

Usage: python3 tests/test_all.py [--jobs N] [--target T] [--suite S,...]
                                 [--quick PERCENT [--seed N]]
                                 [--stop-at-error] [--compiler CMD]

Functions:
    parse_args(argv) -- the flags, as a map.
    suites(args) -- the suites to run, in order, with their arguments.
    run_suite(command, environment, stop) -- runs one suite, stopping
      it at its first failure where `stop` says to.
    report(tally, targets, broken, skipped, reason, stopped) -- the
      combined summary.
    main(argv) -- the command-line entry point.
"""

import os
import queue
import random
import re
import signal
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import suite  # noqa: E402  (after sys.path, which is what makes it findable)


def parse_args(argv):
    """`--jobs N`, `--target T`, `--suite S,...`, `--compiler CMD` and
    `--stop-at-error`, in any order. A suite there is none of, or a
    target with no programs suite to narrow, is refused.
    [String] -> {String: String}"""
    known = ("--jobs", "--target", "--suite", "--compiler", "--quick", "--seed")
    args = {}
    rest = list(argv)
    while rest:
        flag = rest.pop(0)
        if flag == "--stop-at-error":
            args[flag] = "yes"
            continue
        if flag not in known or not rest:
            print(f"usage: test_all.py [--jobs N] [--target T] [--suite S,...] "
                  f"[--quick PERCENT [--seed N]] [--stop-at-error] [--compiler CMD]",
                  file=sys.stderr)
            sys.exit(2)
        args[flag] = rest.pop(0)
    if "--quick" in args:
        # Checked here rather than by each suite, so a bad value is one
        # error and not one per suite.
        suite.sample_flags(["--sample", args["--quick"], "--seed", args.get("--seed", "0")])
        args.setdefault("--seed", str(random.randrange(1_000_000)))
    elif "--seed" in args:
        print("test_all.py: --seed goes with --quick", file=sys.stderr)
        sys.exit(2)
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
    thirteen are skipped when a target was named, since none of them is a
    target, and only those `--suite` names are run.
    {String: String} -> [(String, String, [String])]"""
    compiler = ["--compiler", args["--compiler"]] if "--compiler" in args else []
    sampled = (["--sample", args["--quick"], "--seed", args["--seed"]]
               if "--quick" in args else [])
    program = list(sampled)
    if "--jobs" in args:
        program += ["--jobs", args["--jobs"]]
    if "--target" in args:
        program += ["--target", args["--target"]]
    found = [("programs", "test_script.py", program + compiler)]
    if "--target" not in args:
        found += [
        ("repl", "test_repl.py", compiler),
        ("warnings", "test_warnings.py", compiler),
        ("libpath", "test_libpath.py", compiler),
        ("playground", "test_playground.py", []),
        ("notebook", "test_notebook.py", compiler),
        ("packaging", "test_packaging.py", compiler + sampled),
        ("site", "test_site.py", compiler),
        ("tinyweb", "test_tinyweb.py", compiler + sampled),
        ("lsp", "test_lsp.py", compiler + sampled),
        ("dap", "test_dap.py", compiler),
        ("nbjson", "test_nbjson.py", compiler),
        ("nbverify", "test_nbverify.py", compiler),
        ("highlight", "test_highlight.py", compiler),
        ]
    if "--suite" in args:
        found = [entry for entry in found if entry[0] in _named(args)]
    return found


def main(argv):
    """Runs every suite and reports them together. [String] -> Int"""
    args = parse_args(argv)
    handle, tally = tempfile.mkstemp(prefix="pyk-tally-")
    os.close(handle)
    handle, targets = tempfile.mkstemp(prefix="pyk-targets-")
    os.close(handle)
    environment = dict(os.environ, PYK_TEST_TALLY=tally, PYK_TEST_TARGET_TALLY=targets)
    stop = "--stop-at-error" in args
    if stop:
        environment[suite.STOP_AT_ERROR] = "1"
    broken, stopped = [], None
    if "--quick" in args:
        print(f"Quick: {args['--quick']}% sampled, seed {args['--seed']} "
              f"(make quicktest PERCENT={args['--quick']} SEED={args['--seed']} "
              f"repeats it).", flush=True)
    try:
        ran = []
        for name, script, arguments in suites(args):
            suite.heading(name)
            ran.append(name)
            returncode, interrupted = run_suite(
                [sys.executable, str(HERE / script)] + arguments, environment, stop)
            if interrupted:
                stopped = name
            elif returncode != 0 and not _reported(tally, name):
                # The suite failed without reaching its own footer -- a
                # missing bundle, a compiler that would not build. There
                # is no tally to add up, so it is named on its own.
                broken.append(name)
            if stop and (interrupted or returncode != 0):
                stopped = name
                break
        listed = [name for name, _, _ in suites(args)]
        skipped = [name for name, _, _ in suites({}) if name not in listed]
        reason = (f"--target {args['--target']}" if "--target" in args
                  else f"--suite {args.get('--suite')}")
        unrun = [name for name in listed if name not in ran]
        return report(tally, targets, broken, skipped, reason, (stopped, unrun))
    finally:
        os.unlink(tally)
        os.unlink(targets)


# A line that reports a failed check, in any suite: `name: label FAILED`,
# `name: FAILED label`, or a programs case's `label FAILED`.
FAILED = re.compile(r"\bFAILED\b")

# A line that starts the next case's report, which ends the failure's.
NEXT_CASE = re.compile(r"(\bFAILED\b|\bOK\.$)")

# How long a failure's report may go quiet before it is taken as done.
REPORT_QUIET = 2.0

# How long an interrupted suite has to clean up before it is killed.
CLEANUP = 15.0


def run_suite(command, environment, stop):
    """Runs one suite, its output going straight to ours. Where `stop`
    is set, reads that output as it comes instead and, at the first
    failure, lets the rest of that failure's report through, interrupts
    the suite and its children (SIGINT, so its `finally`s and temporary
    directories are cleaned up; killed if it lingers) and says so.
    [String] -> {String: String} -> Bool -> (Int, Bool)"""
    if not stop:
        # Not captured: a suite reports as it goes, and a run of this
        # one takes minutes.
        return subprocess.run(command, env=environment).returncode, False
    # A session of its own, so the whole of it -- pool workers, node,
    # Chromium -- can be interrupted together without interrupting us.
    process = subprocess.Popen(command, env=dict(environment, PYTHONUNBUFFERED="1"),
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    lines = queue.Queue()

    def read():
        for line in process.stdout:
            lines.put(line)
        lines.put(None)

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    failed = False
    try:
        while True:
            try:
                line = lines.get(timeout=REPORT_QUIET if failed else None)
            except queue.Empty:
                break
            if line is None:
                return process.wait(), False
            if failed and NEXT_CASE.search(line.rstrip()):
                break
            sys.stdout.write(line)
            sys.stdout.flush()
            if FAILED.search(line):
                failed = True
    except KeyboardInterrupt:
        _interrupt(process)
        raise
    _interrupt(process)
    return process.returncode, True


def _interrupt(process):
    """Interrupts a suite's session, then kills it if it has not ended
    within CLEANUP seconds. Popen -> ()"""
    try:
        os.killpg(process.pid, signal.SIGINT)
        process.wait(timeout=CLEANUP)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    except ProcessLookupError:
        process.wait()


def _reported(tally, name):
    """Whether this suite reached its own footer. Path -> String -> Bool"""
    return any(written == name for written, _, _ in suite.read_tally(tally))


def report(tally, targets, broken, skipped, reason, stopped=(None, [])):
    """The combined summary: the programs suite per target, one line per
    suite, then the totals, and why any suite was skipped. `stopped` is
    the suite `--stop-at-error` stopped at, if any, and those it left.
    Path -> Path -> [String] -> [String] -> String -> (String?, [String])
    -> Int"""
    at, unrun = stopped
    counted = suite.read_tally(tally)
    suite.heading("all suites")
    per_target = suite.read_tally(targets)
    if per_target:
        print("  programs per target:")
        width = max(len(name) for name, _, _ in per_target)
        for name, passed, failed in per_target:
            print(f"    {name:<{width}} {passed:>5} passed, {failed:>4} failed")
        print()
    for name, passed, failed in counted:
        print("  " + suite.COUNTS.format(
            name=name, passed=passed, failed=failed))
    for name in broken:
        print(f"  {name:<12} did not finish")
    for name in skipped:
        print(f"  {name:<12} skipped ({reason})")
    if at and at not in broken and not any(name == at for name, _, _ in counted):
        print(f"  {at:<12} stopped at its first failure")
    for name in unrun:
        print(f"  {name:<12} not run (--stop-at-error)")
    passed = sum(entry[1] for entry in counted)
    failed = sum(entry[2] for entry in counted)
    print()
    print(f"  {passed + failed} checks in {len(counted)} "
          f"suite{'' if len(counted) == 1 else 's'}, {failed} failed.")
    if at:
        print(f"  Stopped at the first failure, in {at} (--stop-at-error).")
    if failed or broken or at:
        print("  FAILED")
        return 1
    print("  ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
