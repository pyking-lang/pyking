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
"""

import glob
import os
import re
import subprocess
import sys
import tempfile
import tomllib

PYKBOOT = os.path.join("src", "pykboot.py")
CASES_FILE = os.path.join("tests", "test_cases.toml")
# The `typecheck` target is not a backend: it compiles nothing and runs
# nothing. It type-checks a program and compares the *printed AST*
# against the `.ast.out` file, which is how a `typecheck_*.pyk` test pins
# down the types the checker infers. See `run_typecheck` below.
TYPECHECK_TARGET = "typecheck"
# A `typecheck_*` program must type-check, and its `.ast.out` holds the
# printed AST; it lists real backends too, so the program it describes is
# one that actually runs. A `fail_typecheck_*` one must *not* check, and
# its `.ast.out` holds the error message instead -- and it is checked and
# nothing more, since a program written to be refused is not one to run.
TYPECHECK_PREFIX = "typecheck_"
FAIL_TYPECHECK_PREFIX = "fail_typecheck_"
# What the `typecheck` target compares against, beside the `.out` every
# backend shares.
AST_SUFFIX = ".ast.out"


def is_typecheck_file(name):
    return name.startswith((TYPECHECK_PREFIX, FAIL_TYPECHECK_PREFIX))


def expected_path(source, target):
    """The file holding what this target should produce: the printed AST
    for `typecheck`, the program's own output for every backend."""
    stem = os.path.splitext(source)[0]
    return stem + (AST_SUFFIX if target == TYPECHECK_TARGET else ".out")

TARGETS = (
    "python", "nodejs", "esm", "html", "c89", "c23", "java8", "java17",
    "java21", "ocaml", TYPECHECK_TARGET,
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


def compile_to(source, target, output):
    return run([sys.executable, PYKBOOT, "--target", target, "--output", output, source])


# The Python backend builds a per-turn factory (`__pyk_turn1`) for a
# `def` written inside a loop, so that each turn's functions keep that
# turn's bindings -- see PYKING.md, "Names and scoping". It is the one
# construct that makes generated Python look unlike its source, so it is
# also the one worth pinning: a program that never writes a `def` inside
# a loop must never produce one.
FACTORY_MARKER = "__pyk_turn"


def has_def_inside_loop(source):
    """Whether `source` writes a `def` anywhere inside a `for`/`while`
    body.

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
            open_blocks.append((indent, stripped.startswith(("for ", "while "))))
    return False


def run_python(source, workdir):
    generated = os.path.join(workdir, "program.py")
    compiled = compile_to(source, "python", generated)
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
    expect_failure = os.path.basename(source).startswith(FAIL_TYPECHECK_PREFIX)
    result = run([sys.executable, PYKBOOT, "--typecheck", "--ast", source])
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


RUNNERS = {
    TYPECHECK_TARGET: run_typecheck,
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
        # A program whose types are pinned must also be a program that
        # runs: `python` compiles the whole language, so a
        # `typecheck_*` file that does not list it is describing
        # something nothing ever executes.
        if checks and "python" not in targets:
            print(
                f"WARNING: {name} pins its types but lists no backend; add "
                f'"python" so the program it describes is one that runs'
            )
        # A `fail_typecheck_*` program is written to be refused, so there
        # is nothing to run and no `.out` to compare.
        if fails and targets != [TYPECHECK_TARGET]:
            print(
                f"WARNING: {name} is named {FAIL_TYPECHECK_PREFIX}* so it "
                f'must list exactly targets = ["{TYPECHECK_TARGET}"]'
            )
        for target in targets:
            path = expected_path(os.path.join("tests", name), target)
            if not os.path.exists(path):
                print(f"WARNING: {name} lists {target} but {path} is missing")
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
            with open(expected_path(source, target)) as f:
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
