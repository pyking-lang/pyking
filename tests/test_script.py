"""Runs every test program against every target it declares support for.

`tests/test_cases.toml` lists the programs and their targets; each one is
compiled, executed, and its output compared against the sibling `.out`
file. The same `.out` serves every target -- that is the point of the
exercise: a Pyking program means one thing, whichever backend ran it.

Two kinds of expected output, and the distinction is worth keeping
straight:

  <name>.out       what the program *prints* when it runs. Every backend
                   is compared against this one file.
  <name>.ast.out   what `--typecheck --ast` prints for it: the program
                   pretty-printed with the types the checker inferred,
                   or -- for a `fail_typecheck_*` program -- the error it
                   was written to provoke. Only the `typecheck` target
                   reads this.
  <name>.notail.out
  <name>.notail.ast.out
                   the same two, for a program compiled with
                   --no-tail-call-opt. Tail calls become loops before
                   anything else sees the program (see
                   docs/optimization.md), so these are what it is
                   without that pass: the `.notail.out` must match the
                   `.out` -- meaning is what the pass must not change --
                   while the `.notail.ast.out` shows the program as it
                   was written. Read by the `python_notail` and
                   `typecheck_notail` targets.

A `typecheck_*` program therefore has *both*: its types are pinned by the
`.ast.out`, and it still runs on the backends like any other program, so
the two halves cannot drift apart.

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
  java8   compile to a temp .java, build it with `javac --release <8|17|21>`,
  java17  run the class with `java`, compare stdout. All three share one
  java21  backend and differ only in how the Java is printed, the same
          reason all three run here.
  ocaml   compile to a temp .ml, build it with `ocamlfind ocamlopt -w +a`,
          run the binary, compare stdout. Every warning is on: the
          target's promise is clean OCaml, so a warning is a failure.
  html    no browser is needed: the page's embedded module is extracted
          and run under node with a small `document` stub that captures
          what the program writes into the page, which is then compared
          like any other output. See `run_html` for what that does and
          does not prove.
  interpret
          nothing is compiled: `pyk run` runs the program on the AST with
          src/interpreter.py and its stdout is compared like any other
          backend's. That comparison is the point -- the interpreter is a
          second definition of the language's semantics, and the cheapest
          way to keep it honest is to hold it to the same `.out` files
          the nine compiling targets are held to.

Every (target, program) pair is independent -- each compiles into a
temporary directory of its own and nothing is written back into the
repository -- so they are run by a pool of `--jobs` threads, one per
usable CPU by default (`make test`); `--jobs 1` runs them one at a time
(`make stest`). A finished result waits for the ones listed before it,
so the transcript is the same either way.
"""

import argparse
import glob
import os
import re
import subprocess
import sys
import tempfile
import tomllib
from concurrent.futures import ThreadPoolExecutor

PYK = os.path.join("src", "pyk.py")
CASES_FILE = os.path.join("tests", "test_cases.toml")
# The `typecheck` target is not a backend: it compiles nothing and runs
# nothing. It type-checks a program and compares the *printed AST*
# against the `.ast.out` file, which is how a `typecheck_*.pyk` test pins
# down the types the checker infers. See `run_typecheck` below.
TYPECHECK_TARGET = "typecheck"
# Nor is `interpret` a backend: it compiles nothing either, and runs the
# program on the AST with src/interpreter.py. It is still compared
# against the same `.out` as every compiling target, which is what makes
# it a test of the *language* rather than of the interpreter alone. Its
# subset is the type checker's (see `interpreter.check`), so a program
# outside that fragment simply does not list it.
INTERPRET_TARGET = "interpret"
# A `typecheck_*` program must type-check, and its `.ast.out` holds the
# printed AST; it lists real backends too, so the program it describes is
# one that actually runs. A `fail_typecheck_*` one must *not* check, and
# its `.ast.out` holds the error message instead -- and it is checked and
# nothing more, since a program written to be refused is not one to run.
TYPECHECK_PREFIX = "typecheck_"
FAIL_TYPECHECK_PREFIX = "fail_typecheck_"
# The two targets that turn the tail-call pass off. `python_notail` runs
# the program without it and compares the same output the optimized one
# produced -- if those two ever differ, the pass changed what a program
# means. `typecheck_notail` prints the AST without it, which is where a
# program's own shape is pinned once the pass has rewritten it.
TYPECHECK_NOTAIL_TARGET = "typecheck_notail"
PYTHON_NOTAIL_TARGET = "python_notail"
NOTAIL_FLAG = "--no-tail-call-opt"
# What the `typecheck` target compares against, beside the `.out` every
# backend shares.
AST_SUFFIX = ".ast.out"
# How many runs to keep in flight, when neither `--jobs` nor this says.
# See `default_jobs`.
JOBS_VARIABLE = "PYK_TEST_JOBS"


def is_typecheck_file(name):
    return name.startswith((TYPECHECK_PREFIX, FAIL_TYPECHECK_PREFIX))


def expected_path(source, target):
    """The file holding what this target should produce: the printed AST
    for the two typecheck targets, the program's own output for every
    backend, each with `.notail` in front of it where the target turns
    the tail-call pass off."""
    stem = os.path.splitext(source)[0]
    if target == TYPECHECK_TARGET:
        return stem + AST_SUFFIX
    if target == TYPECHECK_NOTAIL_TARGET:
        return stem + ".notail" + AST_SUFFIX
    if target == PYTHON_NOTAIL_TARGET:
        return stem + ".notail.out"
    return stem + ".out"


TARGETS = (
    "python", "nodejs", "esm", "html", "c89", "c23", "java8", "java17",
    "java21", "ocaml", INTERPRET_TARGET, TYPECHECK_TARGET,
    PYTHON_NOTAIL_TARGET, TYPECHECK_NOTAIL_TARGET,
)

# The compiler used for the C targets; `cc` is the standard name.
C_COMPILER = os.environ.get("CC", "cc")

# The JDK tools used for the Java targets; `javac`/`java` are the standard
# names on `PATH`.
JAVA_COMPILER = os.environ.get("JAVAC", "javac")
JAVA_RUNTIME = os.environ.get("JAVA", "java")

# The OCaml native compiler. `ocamlfind ocamlopt` rather than plain
# `ocamlopt` for the same reason `cc` is used for C: it is the spelling a
# user reaches for.
OCAML_COMPILER = os.environ.get("OCAMLOPT", "ocamlfind ocamlopt").split()

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


def executed(result):
    """The output of a program that ran, as `(stdout, error)`.

    A program that dies part-way still has whatever it printed first on
    stdout, so comparing that alone would call a crash a pass as long as
    the surviving prefix matched. The exit status is the difference, and
    every runner goes through here so that none of them forgets it."""
    if result.returncode != 0:
        return None, (
            f"the program exited with status {result.returncode}\n"
            f"{result.stderr}"
        )
    return result.stdout, None


def compile_to(source, target, output, flags=()):
    return run(
        [sys.executable, PYK, "compile", "--target", target, "--output", output]
        + list(flags)
        + [source]
    )


# The Python backend builds a per-turn factory (`__pyk_turn1`) for a
# `def` written inside a loop, so that each turn's functions keep that
# turn's bindings -- see PYKING.md, "Names and scoping". It is the one
# construct that makes generated Python look unlike its source, so it is
# also the one worth pinning: a program that never writes a `def` inside
# a loop must never produce one.
FACTORY_MARKER = "__pyk_turn"

# src/optimization.py names the worker it builds for a mutually recursive
# group `tail_group1`, `tail_group2`, ... The OCaml target is compiled
# from the program as written, since OCaml eliminates tail calls itself
# (see docs/optimization.md), so one of these appearing in generated
# OCaml means the pass ran where it should not have.
GROUP_MARKER = "tail_group"


def has_def_inside_loop(source):
    """Whether `source` writes a `def` anywhere inside a `for`, `while`
    or `loop` body.

    Indentation is the block structure in Pyking, in strict multiples of
    four with no line continuations (see PYKING.md), so reading it off
    the text is exact rather than a guess."""
    open_blocks = []          # (indent, opened by a loop?)
    with open(source) as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            indent = len(line) - len(line.lstrip())
            while open_blocks and indent <= open_blocks[-1][0]:
                open_blocks.pop()
            if stripped.startswith("def ") and any(
                is_loop for _, is_loop in open_blocks
            ):
                return True
            open_blocks.append((
                indent,
                stripped.startswith(("for ", "while ", "loop "))
                or stripped == "loop:",
            ))
    return False


def run_python(source, workdir):
    return _run_python(source, workdir, [])


def _run_python(source, workdir, flags):
    generated = os.path.join(workdir, "program.py")
    compiled = compile_to(source, "python", generated, flags)
    if compiled.returncode != 0:
        return None, compiled.stderr
    with open(generated) as f:
        code = f.read()
    if FACTORY_MARKER in code and not has_def_inside_loop(source):
        return None, (
            f"generated a per-turn factory ({FACTORY_MARKER}*) for a program "
            "with no `def` inside a loop -- ordinary programs must compile to "
            "ordinary Python"
        )
    return executed(run([sys.executable, generated]))


def run_nodejs(source, workdir):
    generated = os.path.join(workdir, "program.js")
    compiled = compile_to(source, "nodejs", generated)
    if compiled.returncode != 0:
        return None, compiled.stderr
    return executed(run(["node", generated]))


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
    return executed(run(["node", os.path.join(workdir, "program.node.js")]))


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
    return executed(run(["node", harness]))


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
    return executed(run([binary]))


def run_java(source, workdir, version):
    """Compiles to Java, builds it with `javac --release <version>`, runs
    the class with `java`. The class is named `Program` here rather than
    whatever the backend would pick by default -- `--output` always names
    it explicitly (see `src/target_java.py`), so the test harness's own
    naming choice never has to match the source file's."""
    generated = os.path.join(workdir, "Program.java")
    compiled = compile_to(source, version, generated)
    if compiled.returncode != 0:
        return None, compiled.stderr
    release = version.removeprefix("java")
    built = run([JAVA_COMPILER, "--release", release, "-d", workdir, generated])
    if built.returncode != 0:
        return None, built.stderr
    return executed(run([JAVA_RUNTIME, "-cp", workdir, "Program"]))


def run_ocaml(source, workdir):
    """Compiles to OCaml, builds it with `ocamlfind ocamlopt`, runs the
    binary.

    The bytecode compiler would do as well, but the native one is the
    stricter reader of the two and is what a user would reach for. The
    generated module is compiled with no interface beside it, so an
    unused top-level binding is exported rather than dead -- which is
    exactly right for a translated Pyking program, where the top level's
    bindings are the program's own."""
    generated = os.path.join(workdir, "program.ml")
    compiled = compile_to(source, "ocaml", generated)
    if compiled.returncode != 0:
        return None, compiled.stderr
    with open(generated) as f:
        code = f.read()
    if GROUP_MARKER in code:
        return None, (
            f"generated a merged tail-call group ({GROUP_MARKER}*) -- OCaml "
            "eliminates tail calls itself, so this target compiles the "
            "program as written and the pass must not have run"
        )
    binary = os.path.join(workdir, "program")
    built = run(
        OCAML_COMPILER + ["-w", "+a-70", "-I", workdir, "-o", binary, generated]
    )
    if built.returncode != 0:
        return None, built.stderr
    # `-w +a` turns every warning on: the point of a target whose output
    # is meant to be clean OCaml is that a compiler reading it has nothing
    # to say about it, so a warning here is a bug worth seeing. The one
    # exception, `-70`, is "this module has no .mli" -- a fact about how
    # the module is being built here, not about the code in it.
    complaints = about_the_code(built.stderr)
    if complaints:
        return None, f"the OCaml compiler warned about generated code:\n{complaints}"
    return executed(run([binary]))


# `ocamlfind` writes its own diagnostics to the same stream the compiler
# does, and they are about the *installation* rather than about anything
# that was compiled -- a switch whose `ld.conf` names a `stublibs`
# directory that is not there produces two of them on every single
# invocation. Reading those as "the generated code is not clean" would
# fail every OCaml case on a machine whose opam switch is merely untidy,
# which is what this filter is for. A real warning comes from the
# compiler and is not prefixed this way.
TOOL_NOISE_PREFIX = "ocamlfind:"


def about_the_code(stderr):
    """What the OCaml compiler said about the file, with the wrapper's
    own remarks about its installation dropped."""
    return "\n".join(
        line
        for line in stderr.splitlines()
        if line.strip() and not line.startswith(TOOL_NOISE_PREFIX)
    )


def run_interpret(source, _workdir):
    """Runs the program with the interpreter, and compares what it
    printed against the same `.out` every compiling target is compared
    against.

    Nothing is written to the work directory: `pyk run` produces no file
    at all, which is the whole difference between this and the nine
    targets above it. The exit status still goes through `executed`, so
    a program that prints its output and *then* hits a runtime error is a
    failure rather than a pass."""
    return executed(run([sys.executable, PYK, "run", source]))


def run_typecheck(source, workdir):
    """Type-checks `source`. Nothing is compiled or executed.

    For a `typecheck_*` program the result is its pretty-printed AST:
    the checker writes the types it inferred into it (`x: Int = 1`), so
    printing it is what the `.ast.out` records, and any error is a
    failure. The same program's `.out` records what it *prints*, checked
    by the backends it lists.

    For a `fail_typecheck_*` program it is the other way round -- the
    checker is *expected* to reject it, so the error message becomes the
    output to compare and type-checking cleanly is the failure."""
    return _typecheck(
        source,
        [],
        expect_failure=os.path.basename(source).startswith(FAIL_TYPECHECK_PREFIX),
    )


def _typecheck(source, flags, expect_failure):
    """Runs `pyk compile --typecheck --ast` with these extra flags, and
    answers with whichever stream this program is expected to produce."""
    result = run(
        [sys.executable, PYK, "compile", "--typecheck", "--ast"] + flags + [source]
    )
    if expect_failure:
        if result.returncode == 0:
            return None, (
                "expected type checking to fail, but it succeeded and "
                f"printed:\n{result.stdout}"
            )
        return result.stderr, None
    if result.returncode != 0:
        return None, result.stderr
    return result.stdout, None


def run_python_notail(source, workdir):
    """Runs the program with the tail-call pass off. Its output is
    compared against `.notail.out`, which must hold exactly what the
    `.out` does: the pass may make a program run in less space, never
    make it mean something else."""
    return _run_python(source, workdir, [NOTAIL_FLAG])


def run_typecheck_notail(source, _workdir):
    """Type-checks and prints the AST with the tail-call pass off, so
    the `.notail.ast.out` holds the program as it was written.

    The two typecheck targets never disagree about whether a program
    checks: the pass runs only on programs that already do, and cannot
    turn one into a program that does not (docs/optimization.md, "Why
    one check is enough"). What they disagree about is the *shape* they
    print."""
    return _typecheck(source, [NOTAIL_FLAG], expect_failure=False)


RUNNERS = {
    TYPECHECK_TARGET: run_typecheck,
    TYPECHECK_NOTAIL_TARGET: run_typecheck_notail,
    PYTHON_NOTAIL_TARGET: run_python_notail,
    INTERPRET_TARGET: run_interpret,
    "python": run_python,
    "nodejs": run_nodejs,
    "esm": run_esm,
    "html": run_html,
    "c89": lambda source, workdir: run_c(source, workdir, "c89"),
    "c23": lambda source, workdir: run_c(source, workdir, "c23"),
    "java8": lambda source, workdir: run_java(source, workdir, "java8"),
    "java17": lambda source, workdir: run_java(source, workdir, "java17"),
    "java21": lambda source, workdir: run_java(source, workdir, "java21"),
    "ocaml": run_ocaml,
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
    # The naming convention and the manifest have to agree about which
    # programs have their types pinned, and about which of those are also
    # run, so that neither can drift silently.
    for case in cases:
        name = case["file"]
        targets = case["targets"]
        checks = name.startswith(TYPECHECK_PREFIX)
        fails = name.startswith(FAIL_TYPECHECK_PREFIX)
        uses_typecheck = TYPECHECK_TARGET in targets

        if (checks or fails) and not uses_typecheck:
            print(
                f"WARNING: {name} is named {TYPECHECK_PREFIX}* or "
                f"{FAIL_TYPECHECK_PREFIX}* but does not list the "
                f"{TYPECHECK_TARGET} target"
            )
        if uses_typecheck and not (checks or fails):
            print(
                f"WARNING: {name} uses the {TYPECHECK_TARGET} target "
                f"but is named neither {TYPECHECK_PREFIX}* nor "
                f"{FAIL_TYPECHECK_PREFIX}*"
            )
        # The pass must not change what a program means, and the pair of
        # outputs is where that is checked -- so a program that runs one
        # way should run the other.
        if PYTHON_NOTAIL_TARGET in targets and "python" not in targets:
            print(
                f"WARNING: {name} lists {PYTHON_NOTAIL_TARGET} but not "
                f'"python"; the two outputs are only worth comparing '
                f"together"
            )
        # A program whose types are pinned must also be a program that
        # runs: `python` compiles the whole language, so a
        # `typecheck_*` file that does not list it is describing
        # something nothing ever executes.
        if checks and "python" not in targets:
            print(
                f"WARNING: {name} pins its types but lists no backend; add "
                f'"python" so the program it describes is one that runs'
            )
        # The interpreter runs the checker's fragment, so a program whose
        # types are pinned is one it can run -- and the cheapest check
        # that the two agree is to actually run it.
        if checks and INTERPRET_TARGET not in targets:
            print(
                f"WARNING: {name} pins its types but does not list "
                f'"{INTERPRET_TARGET}"; the interpreter runs exactly the '
                f"fragment the checker accepts"
            )
        # A `fail_typecheck_*` program is written to be refused, so there
        # is nothing to run and no `.out` to compare.
        if fails and targets != [TYPECHECK_TARGET]:
            print(
                f"WARNING: {name} is named {FAIL_TYPECHECK_PREFIX}* so it "
                f'must list exactly targets = ["{TYPECHECK_TARGET}"]'
            )
        # The pass may make a program run in less space; it may never
        # make it print something else. Where both files exist, that is
        # a rule the suite can simply read.
        optimized = expected_path(os.path.join("tests", name), "python")
        plain = expected_path(os.path.join("tests", name), PYTHON_NOTAIL_TARGET)
        if os.path.exists(optimized) and os.path.exists(plain):
            with open(optimized) as f:
                first = f.read()
            with open(plain) as f:
                second = f.read()
            if first != second:
                print(
                    f"WARNING: {name}'s .out and .notail.out differ; the "
                    f"tail-call pass must not change what a program prints"
                )
        for target in targets:
            path = expected_path(os.path.join("tests", name), target)
            if not os.path.exists(path):
                print(f"WARNING: {name} lists {target} but {path} is missing")
    return cases


def plan(cases):
    """Every (target, program) pair the manifest declares, in the order
    their results are reported. [Case] -> [(String, String)]"""
    return [
        (target, os.path.join("tests", case["file"]))
        for target in TARGETS
        for case in cases
        if target in case["targets"]
    ]


def run_case(target, source):
    """Runs one program on one target and words the result, rather than
    printing it: a run this far from the reporting loop is one that can
    happen on any thread. (String, String) -> (String, Bool)"""
    with open(expected_path(source, target)) as f:
        expected = f.read()
    with tempfile.TemporaryDirectory() as workdir:
        actual, error = RUNNERS[target](source, workdir)

    label = f"target {target}: {source}"
    if error is not None:
        return f"{label} FAILED\n--- compile/run error ---\n{error}", True
    if actual == expected:
        return f"{label} OK.\n", False
    return (
        f"{label} FAILED\n"
        f"--- expected output ---\n{expected}"
        f"--- actual output ---\n{actual}",
        True,
    )


def outcomes(tasks, jobs):
    """The result of every task, always in the order the tasks were
    listed. With `jobs` above one they are run by a pool and a finished
    result waits for the ones before it, so what the suite prints does
    not depend on how the work happened to be scheduled.
    [(String, String)] -> Int -> iterator of (String, String, Bool)"""
    if jobs == 1:
        for target, source in tasks:
            report, failed = run_case(target, source)
            yield target, report, failed
        return
    pool = ThreadPoolExecutor(max_workers=jobs)
    try:
        futures = [pool.submit(run_case, *task) for task in tasks]
        for (target, _), future in zip(tasks, futures):
            report, failed = future.result()
            yield target, report, failed
    finally:
        # Not `with`: that waits for every queued task, so an interrupted
        # run would sit through the whole suite before reporting it.
        pool.shutdown(wait=False, cancel_futures=True)


def default_jobs():
    """How many runs to keep in flight when nothing asks for a number.

    The affinity mask rather than `os.cpu_count()`: inside a VM or a
    container that is the count of CPUs this process may actually use,
    which is what the pool should be sized to. () -> Int"""
    requested = os.environ.get(JOBS_VARIABLE)
    if requested:
        return positive(requested, JOBS_VARIABLE)
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:
        return os.cpu_count() or 1


def positive(value, what):
    """The value as a job count, or a usage error. String -> String -> Int"""
    if not value.isdigit() or int(value) < 1:
        raise SystemExit(f"{what}: expected a positive number, not {value!r}")
    return int(value)


def parse_jobs(argv):
    """How many runs this invocation wants in flight. [String] -> Int"""
    parser = argparse.ArgumentParser(
        description="Runs every test program on every target it declares."
    )
    parser.add_argument(
        "-j",
        "--jobs",
        metavar="N",
        type=lambda value: positive(value, "--jobs"),
        help=(
            "how many test runs to keep in flight (default: the number of "
            f"usable CPUs, or ${JOBS_VARIABLE}); 1 runs them one at a time"
        ),
    )
    jobs = parser.parse_args(argv).jobs
    return jobs if jobs is not None else default_jobs()


def main():
    jobs = parse_jobs(sys.argv[1:])
    cases = load_cases()
    tasks = plan(cases)
    passed = {target: 0 for target in TARGETS}
    failed = {target: 0 for target in TARGETS}

    print(f"{len(tasks)} runs on {jobs} worker{'' if jobs == 1 else 's'}.")
    for target, report, did_fail in outcomes(tasks, jobs):
        print(report, end="")
        if did_fail:
            failed[target] += 1
        else:
            passed[target] += 1

    print()
    print("Summary")
    total_failed = 0
    # Width taken from the names themselves rather than fixed, so the
    # columns stay lined up whatever a target is called -- `typecheck` is
    # already longer than every backend name.
    width = max(len(target) for target in TARGETS)
    for target in TARGETS:
        total = passed[target] + failed[target]
        print(
            f"  target {target:<{width}} {passed[target]:3d} passed, "
            f"{failed[target]:3d} failed  (of {total} supported cases)"
        )
        total_failed += failed[target]
    total_run = sum(passed.values()) + sum(failed.values())
    print(f"  {total_run} runs over {len(cases)} programs and {len(TARGETS)} targets.")

    if total_failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
