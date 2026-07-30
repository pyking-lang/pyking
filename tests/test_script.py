"""Runs every test program against every target it declares support for.

`tests/test_cases.toml` lists the programs and their targets; each one is
compiled, executed, and its output compared against the sibling `.out`
file. The same `.out` serves every target -- that is the point of the
exercise: a Pyking program means one thing, whichever backend ran it.

How each target is executed:

  python  compile to a temp .py, run it with python3, compare stdout.
  nodejs  compile to a temp .js, run it with node, compare stdout.
  esm     compile to a temp .js (plus its wrappers and package.json), run
          the generated node driver -- that wrapper is what a user would
          run, so that is what gets tested.
  c89     compile to a temp .c, build it with `cc -std=c89`, run the
  c23     binary, compare stdout. Both standards run every C case: they
          share one backend and differ only in how the C is printed, so a
          difference between them is exactly the kind of bug worth
          catching.
  html    no browser is needed: the page's embedded module is extracted
          and run under node with a small `document` stub that captures
          what the program writes into the page, which is then compared
          like any other output. See `run_html` for what that does and
          does not prove.
"""

import glob
import os
import re
import subprocess
import sys
import tempfile
import tomllib

PYKBOOT = os.path.join("boot", "pykboot.py")
CASES_FILE = os.path.join("tests", "test_cases.toml")
TARGETS = ("python", "nodejs", "esm", "html", "c89", "c23")

# The compiler used for the C targets; `cc` is the standard name.
C_COMPILER = os.environ.get("CC", "cc")

# Stands in for the browser: the generated page's only contact with the
# outside world is the element it prints into, so a `document` with one
# accumulating `textContent` is the whole of what it needs.
DOM_STUB = """let __pykCaptured = '';
globalThis.document = {
  getElementById: () => ({
    get textContent() { return __pykCaptured; },
    set textContent(value) { __pykCaptured = value; },
  }),
};
"""
DOM_FLUSH = "\nprocess.stdout.write(__pykCaptured);\n"

SCRIPT_RE = re.compile(r'<script type="module">\n(.*?)\n</script>', re.S)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def compile_to(source, target, output):
    return run([sys.executable, PYKBOOT, "--target", target, "--output", output, source])


def run_python(source, workdir):
    generated = os.path.join(workdir, "program.py")
    compiled = compile_to(source, "python", generated)
    if compiled.returncode != 0:
        return None, compiled.stderr
    return run([sys.executable, generated]).stdout, None


def run_nodejs(source, workdir):
    generated = os.path.join(workdir, "program.js")
    compiled = compile_to(source, "nodejs", generated)
    if compiled.returncode != 0:
        return None, compiled.stderr
    return run(["node", generated]).stdout, None


def run_esm(source, workdir):
    """Runs the generated node driver, not the module directly: the
    driver is the file a user would run, and exercising it also checks
    that the module's `run(runtime)` interface is wired up -- and that the
    generated package.json really does put node in ES module mode, since
    the driver's `import` fails without it."""
    module = os.path.join(workdir, "program.js")
    compiled = compile_to(source, "esm", module)
    if compiled.returncode != 0:
        return None, compiled.stderr
    return run(["node", os.path.join(workdir, "program.node.js")]).stdout, None


def run_html(source, workdir):
    """Runs the page's program under node with a stubbed `document`.

    This executes the real generated program and the real `print` path --
    the code that appends to the page -- and compares what would have
    appeared there. It does not prove that a browser parses the page or
    that the layout works; only a headless browser could do that, and one
    would be a heavy dependency for an otherwise stdlib-only repository.
    """
    page = os.path.join(workdir, "program.html")
    compiled = compile_to(source, "html", page)
    if compiled.returncode != 0:
        return None, compiled.stderr
    with open(page) as f:
        script = SCRIPT_RE.search(f.read())
    if script is None:
        return None, 'no <script type="module"> found in the generated page'
    # `.mjs` here is the harness's own choice, not the compiler's: the
    # extracted text came from a `<script type="module">` and so is a
    # module by definition, and the extension says so without depending
    # on a manifest the html target has no reason to write.
    harness = os.path.join(workdir, "program.page.mjs")
    with open(harness, "w") as f:
        f.write(DOM_STUB + script.group(1) + DOM_FLUSH)
    executed = run(["node", harness])
    if executed.returncode != 0:
        return None, executed.stderr
    return executed.stdout, None


def run_c(source, workdir, standard):
    """Compiles to C, builds it with the system compiler, runs the binary.
    `-pedantic` is on: the point of having a `c89` target at all is that
    its output really is C89, and a compiler that merely tolerates it
    would hide the difference from `c23`."""
    generated = os.path.join(workdir, "program.c")
    compiled = compile_to(source, standard, generated)
    if compiled.returncode != 0:
        return None, compiled.stderr
    binary = os.path.join(workdir, "program")
    built = run([C_COMPILER, f"-std={standard}", "-pedantic", "-o", binary, generated])
    if built.returncode != 0:
        return None, built.stderr
    return run([binary]).stdout, None


RUNNERS = {
    "python": run_python,
    "nodejs": run_nodejs,
    "esm": run_esm,
    "html": run_html,
    "c89": lambda source, workdir: run_c(source, workdir, "c89"),
    "c23": lambda source, workdir: run_c(source, workdir, "c23"),
}


def load_cases():
    """The manifest, with a warning for anything that has drifted out of
    step with the files actually on disk."""
    with open(CASES_FILE, "rb") as f:
        cases = tomllib.load(f)["cases"]
    listed = {case["file"] for case in cases}
    on_disk = {os.path.basename(p) for p in glob.glob(os.path.join("tests", "*.pyk"))}
    for missing in sorted(on_disk - listed):
        print(f"WARNING: tests/{missing} is not listed in {CASES_FILE}")
    for missing in sorted(listed - on_disk):
        print(f"WARNING: {CASES_FILE} lists {missing}, which does not exist")
    return cases


def main():
    cases = load_cases()
    passed = {target: 0 for target in TARGETS}
    failed = {target: 0 for target in TARGETS}

    for target in TARGETS:
        for case in cases:
            if target not in case["targets"]:
                continue
            source = os.path.join("tests", case["file"])
            expected_path = os.path.splitext(source)[0] + ".out"
            with open(expected_path) as f:
                expected = f.read()

            with tempfile.TemporaryDirectory() as workdir:
                actual, error = RUNNERS[target](source, workdir)

            label = f"target {target}: {source}"
            if error is not None:
                print(f"{label} FAILED")
                print("--- compile/run error ---")
                print(error, end="")
                failed[target] += 1
            elif actual == expected:
                print(f"{label} OK.")
                passed[target] += 1
            else:
                print(f"{label} FAILED")
                print("--- expected output ---")
                print(expected, end="")
                print("--- actual output ---")
                print(actual, end="")
                failed[target] += 1

    print()
    print("Summary")
    total_failed = 0
    for target in TARGETS:
        total = passed[target] + failed[target]
        print(
            f"  target {target:<7} {passed[target]:3d} passed, "
            f"{failed[target]:3d} failed  (of {total} supported cases)"
        )
        total_failed += failed[target]
    total_run = sum(passed.values()) + sum(failed.values())
    print(f"  {total_run} runs over {len(cases)} programs and {len(TARGETS)} targets.")

    if total_failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
