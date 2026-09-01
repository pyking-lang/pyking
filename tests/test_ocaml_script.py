"""Holds the OCaml bootstrap in `ocaml-src/` to what `src/` does.

Both implementations read a Pyking file and print the program back out
as Pyking source, and this compares the two, character for character,
over every program in `tests/`:

  src/       python3 src/pyk.py compile -t pyking --stdout
             --no-typechecking <program>
  ocaml-src/ main.exe <program>

Type checking is off on both sides. The OCaml tree has only a stub of a
checker so far, so what is being compared is the lexer, the parser,
`symbolize` and the pretty printer -- which is exactly what has been
translated. With the checker off, `-t pyking` prints the program the
parser built with the source's own annotations, and the OCaml side
prints the same thing.

Each program is run twice on each side, the second time with
`--symbols`, so that the two `symbolize` passes are held to handing out
the same numbers as well.

Standard output, standard error and the exit status are all compared, so
a program *refused* counts too: thirteen of the `fail_typecheck_*`
programs are refused by the parser rather than the checker, and their
error line -- position, wording, and the reflow to 70 columns -- is
compared like any other output.

Every program is independent, so they are run by a pool of `--jobs`
threads, one per usable CPU by default; a finished result waits for the
ones listed before it, so the transcript does not depend on how the work
was scheduled. The job plumbing and the timeout are `test_script.py`'s,
imported rather than restated.
"""

import glob
import os
import sys
from concurrent.futures import ThreadPoolExecutor

import test_script

PYK = os.path.join("src", "pyk.py")
# The OCaml tree, its build command, and what that command produces.
# `dune build --root` keeps every file it writes inside ocaml-src/.
OCAML_DIR = "ocaml-src"
BUILD = ["dune", "build", "--root", OCAML_DIR]
OCAML_BINARY = os.path.join(OCAML_DIR, "_build", "default", "main.exe")
# The flags that make the two comparable: the Pyking target prints the
# program itself, and with no checker there are no inferred types in it
# -- which is the state the OCaml side is in (see src/pyk.py).
PYK_FLAGS = ["compile", "--target", "pyking", "--stdout", "--no-typechecking"]
# Each program is printed twice: as source, and with every node labelled
# with the number `symbolize` gave it. The second run is what holds the
# two symbolize passes to handing out the same numbers -- src/ walks the
# dataclasses generically and ocaml-src/ has a case per node, so nothing
# but this would catch the two disagreeing.
RUNS = ([], ["--symbols"])
PROGRAMS = os.path.join("tests", "*.pyk")


def build():
    """Builds the OCaml bootstrap; exits with its output if it fails.
    () -> ()"""
    try:
        result = test_script.run(BUILD)
    except FileNotFoundError:
        raise SystemExit(
            f"{BUILD[0]}: not found. Building ocaml-src/ needs dune and an "
            "OCaml compiler; see docs/ocaml_bootstrap.md."
        )
    if result.returncode != 0:
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        raise SystemExit(f"{' '.join(BUILD)} failed")


def programs():
    """Every test program, in a fixed order. () -> [String]"""
    return sorted(glob.glob(PROGRAMS))


def difference(expected, actual):
    """The first line the two differ on, worded for the report, or ""
    if they do not differ. String -> String -> String"""
    if expected == actual:
        return ""
    expected_lines, actual_lines = expected.split("\n"), actual.split("\n")
    for number in range(max(len(expected_lines), len(actual_lines))):
        mine = expected_lines[number] if number < len(expected_lines) else None
        theirs = actual_lines[number] if number < len(actual_lines) else None
        if mine != theirs:
            return (
                f"--- line {number + 1} ---\n"
                f"  src/:       {'<no line>' if mine is None else mine!r}\n"
                f"  ocaml-src/: {'<no line>' if theirs is None else theirs!r}\n"
            )
    return ""


def compare(source, flags):
    """Runs one program through both implementations with `flags`, and
    words every way they differed. String -> [String] -> [String]"""
    python = test_script.run(
        [sys.executable, PYK] + PYK_FLAGS + flags + [source]
    )
    ocaml = test_script.run([OCAML_BINARY] + flags + [source])

    reports = []
    if python.returncode != ocaml.returncode:
        reports.append(
            f"--- exit status ---\n"
            f"  src/:       {python.returncode}\n"
            f"  ocaml-src/: {ocaml.returncode}\n"
        )
    reports.append(difference(python.stdout, ocaml.stdout))
    reports.append(difference(python.stderr, ocaml.stderr))
    return [report for report in reports if report]


def run_case(source):
    """Runs one program through both implementations, twice, and words
    the result rather than printing it: a run this far from the
    reporting loop is one that can happen on any thread.
    String -> (String, Bool)"""
    reports = []
    for flags in RUNS:
        differences = compare(source, flags)
        if differences:
            reports.append(
                f"--- printed {' '.join(flags) or 'as source'} ---\n"
                + "".join(differences)
            )
    if not reports:
        return f"{source} OK.\n", False
    return f"{source} FAILED\n" + "".join(reports), True


def outcomes(sources, jobs):
    """The result of every program, always in the order they were
    listed. [String] -> Int -> iterator of (String, Bool)"""
    if jobs == 1:
        for source in sources:
            yield run_case(source)
        return
    pool = ThreadPoolExecutor(max_workers=jobs)
    try:
        futures = [pool.submit(run_case, source) for source in sources]
        for future in futures:
            yield future.result()
    finally:
        # Not `with`: that waits for every queued task, so an interrupted
        # run would sit through the whole suite before reporting it.
        pool.shutdown(wait=False, cancel_futures=True)


def parse_jobs(argv):
    """How many runs this invocation wants in flight. [String] -> Int"""
    if not argv:
        return test_script.default_jobs()
    if argv[0] in ("-j", "--jobs") and len(argv) == 2:
        return test_script.positive(argv[1], "--jobs")
    raise SystemExit("usage: test_ocaml_script.py [--jobs N]")


def main():
    jobs = parse_jobs(sys.argv[1:])
    build()
    sources = programs()

    print(f"{len(sources)} programs on {jobs} worker{'' if jobs == 1 else 's'}.")
    failed = 0
    for report, did_fail in outcomes(sources, jobs):
        print(report, end="")
        failed += 1 if did_fail else 0

    print()
    print("Summary")
    print(
        f"  {len(sources) - failed} passed, {failed} failed "
        f"(of {len(sources)} programs)."
    )
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
