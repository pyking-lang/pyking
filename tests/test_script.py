"""Runs every test program against every target it declares support for.

`tests/test_cases.toml` lists the programs and their targets; each one is
compiled, executed, and its output compared against the sibling `.out`
file. The same `.out` serves every target -- that is the point of the
exercise: a Pyking program means one thing, whichever backend ran it.

Two kinds of expected output, and the distinction is worth keeping
straight:

  <name>.out       what the program *prints* when it runs. Every backend
                   is compared against this one file.
  <name>.ast.out   what `-t pyking` prints for it: the program
                   pretty-printed with the types the checker inferred,
                   or -- for a `fail_typecheck_*` program -- the error it
                   was written to provoke. Only the `pyking` target
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
                   `pyking_notail` targets.

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
  ocaml   compile to a temp .ml, build it with `ocamlopt -w +a`,
          run the binary, compare stdout. Every warning is on: the
          target's promise is clean OCaml, so a warning is a failure.
  html    no browser is needed: the page's embedded module is extracted
          and run under node with a small `document` stub that captures
          what the program writes into the page, which is then compared
          like any other output. See `run_html` for what that does and
          does not prove.
  interpret
          nothing is compiled: `pyk <file>` runs the program on the AST with
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

# What runs the compiler: the executable `make build` puts in the
# repository root. `--compiler` points the suite at another build of it,
# which is what a bisect or a second working tree wants.
PYK = os.path.join(".", "pyk")
DEFAULT_COMPILER = [PYK]
COMPILER = list(DEFAULT_COMPILER)
CASES_FILE = os.path.join("tests", "test_cases.toml")
# The `pyking` target compiles Pyking to Pyking: it runs the front end
# and prints the program back, with the types the checker inferred. That
# printed AST is compared against the `.ast.out` file, which is how a
# `typecheck_*.pyk` test pins those types down. See `run_pyking` below.
PYKING_TARGET = "pyking"
# Nor is `interpret` a backend: it compiles nothing either, and runs the
# program on the AST with src/interpreter.ml. It is still compared
# against the same `.out` as every compiling target, which is what makes
# it a test of the *language* rather than of the interpreter alone. Its
# subset is the type checker's (see `interpreter.check`), and every
# program is type-checked, so every program that runs at all lists it.
INTERPRET_TARGET = "interpret"

# An external module is declared in `<name>.external.pyk` and implemented
# in the target's own language. A program that imports one has to be
# compiled: the interpreter runs the AST, and there is none for what the
# implementation provides (see docs/modules.md, "External modules").
EXTERNAL_SUFFIX = ".external.pyk"
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
# means. `pyking_notail` prints the AST without it, which is where a
# program's own shape is pinned once the pass has rewritten it.
PYKING_NOTAIL_TARGET = "pyking_notail"
PYTHON_NOTAIL_TARGET = "python14_notail"
NOTAIL_FLAG = "--no-tail-call-opt"
# What the `pyking` target compares against, beside the `.out` every
# backend shares.
AST_SUFFIX = ".ast.out"
# How many runs to keep in flight, when neither `--jobs` nor this says.
# See `default_jobs`.
JOBS_VARIABLE = "PYK_TEST_JOBS"


def is_typecheck_file(name):
    return name.startswith((TYPECHECK_PREFIX, FAIL_TYPECHECK_PREFIX))


def expected_path(source, target):
    """The file holding what this target should produce: the printed AST
    for the two pyking targets, the program's own output for every
    backend, each with `.notail` in front of it where the target turns
    the tail-call pass off."""
    stem = os.path.splitext(source)[0]
    if target == PYKING_TARGET:
        return stem + AST_SUFFIX
    if target == PYKING_NOTAIL_TARGET:
        return stem + ".notail" + AST_SUFFIX
    if target == PYTHON_NOTAIL_TARGET:
        return stem + ".notail.out"
    return stem + ".out"


# Every target the suite can run, in the order the summary lists them.
# The compiling ones are src/targets.ml's, spelled the same way; the four
# after them compile nothing (see the notes above each).
TARGETS = (
    "python14", "node24", "web24", "iweb24", "c89", "c99", "c23",
    "java8", "java17", "java21", "ocaml5.5", INTERPRET_TARGET, PYKING_TARGET,
    PYTHON_NOTAIL_TARGET, PYKING_NOTAIL_TARGET,
)

# The unversioned name of each family, for `--target`: naming a family
# selects every version of it, which is what a change to one backend
# wants tested. A name that is already a target selects just that one.
FAMILIES = {
    "python": ["python14"],
    "node": ["node24"],
    "web": ["web24"],
    "iweb": ["iweb24"],
    "c": ["c89", "c99", "c23"],
    "java": ["java8", "java17", "java21"],
    "ocaml": ["ocaml5.5"],
}


def selected_targets(name):
    """The targets a --target argument selects: a whole family, or one
    target. String -> [String]"""
    if name in FAMILIES:
        return FAMILIES[name]
    if name in TARGETS:
        return [name]
    return []

# How the JavaScript targets are run.
#
# A node from 22.12 on guesses whether a .js file is an ES module, and
# that guess quietly makes under-declared output work -- output an older
# node then refuses. So the guess is turned off where it can be, and what
# is tested is what the compiler actually declares: a package.json beside
# the output, or a .mjs name.
#
# The flag that turns it off only exists from node 22.7, and an older
# node rejects an option it does not know rather than ignoring it. So it
# is offered and kept only if node takes it -- and a node too old for the
# flag is also too old to guess, which is the behaviour the flag is
# asking for in the first place.
def node_command():
    """`node`, with detection turned off where that is possible.
    () -> [String]"""
    flag = "--no-experimental-detect-module"
    try:
        probe = subprocess.run(["node", flag, "-e", ""], capture_output=True)
    except FileNotFoundError:
        return ["node"]
    return ["node", flag] if probe.returncode == 0 else ["node"]


NODE = node_command()

# The compiler used for the C targets; `cc` is the standard name.
C_COMPILER = os.environ.get("CC", "cc")

# The JDK tools used for the Java targets; `javac`/`java` are the standard
# names on `PATH`.
JAVA_COMPILER = os.environ.get("JAVAC", "javac")
JAVA_RUNTIME = os.environ.get("JAVA", "java")

# The OCaml native compiler. Plain `ocamlopt`: a generated Pyking program
# uses no package, so `ocamlfind` would only add a dependency on a
# working ld.conf. The same default `src/execution.py` uses, so a machine
# set up for one is set up for the other.
OCAML_COMPILER = os.environ.get("OCAMLOPT", "ocamlopt").split()

# Stands in for the browser: the generated page's only contact with the
# outside world is the element it prints into, so a `document` with one
# accumulating `textContent` is the whole of what it needs.
#
# `document` is declared here rather than assigned onto `globalThis`,
# because the stub and the program share one module scope: a Pyking
# program binding `globalThis` would emit a `const globalThis` that this
# text then reads before its initializer runs. `document` itself is safe
# to name, being one of the words `target_js_core.py` renames a Pyking
# binding away from.
DOM_STUB = """let __pykCaptured = '';
const document = {
  getElementById: () => ({
    get textContent() { return __pykCaptured; },
    set textContent(value) { __pykCaptured = value; },
  }),
};
"""
DOM_FLUSH = "\nprocess.stdout.write(__pykCaptured);\n"

SCRIPT_RE = re.compile(r'<script type="module">\n(.*?)\n</script>', re.S)


# A Pyking loop need never end (PYKING.md, "Leaving a loop"), so a test
# that gets one wrong hangs rather than fails. Nothing here should take
# anywhere near this long.
STEP_TIMEOUT = 300


def run(cmd):
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=STEP_TIMEOUT
        )
    except subprocess.TimeoutExpired as expired:
        return subprocess.CompletedProcess(
            cmd, 1, expired.stdout or "",
            f"timed out after {STEP_TIMEOUT} seconds",
        )


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
        COMPILER + ["compile", "--target", target, "--output", output]
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

# src/opt_tailcall.ml names the worker it builds for a mutually recursive
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


def run_python(source, workdir, modules):
    return _run_python(source, workdir, [])


def _run_python(source, workdir, flags):
    generated = os.path.join(workdir, "program.py")
    compiled = compile_to(source, "python14", generated, flags)
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


def run_node(source, workdir, modules):
    """Runs the compiled ES module under node.

    The generated package.json beside it is what makes a plain `.js` an
    ES module to node; without it the `import` lines would be read as
    CommonJS and fail, so running this exercises that too."""
    generated = os.path.join(workdir, "program.js")
    compiled = compile_to(source, "node24", generated)
    if compiled.returncode != 0:
        return None, compiled.stderr
    return executed(run(NODE + [generated]))


def run_web(source, workdir, modules):
    """Compiles the page, then runs the module it loads, under node.

    The `web` target emits the same ES modules `node` does and prints to
    the console, so the program itself runs identically here; what is
    checked on top is that the page exists and really does load that
    module. A browser would be needed to prove it renders, and one is a
    heavy dependency for an otherwise stdlib-only repository."""
    page = os.path.join(workdir, "program.html")
    compiled = compile_to(source, "web24", page)
    if compiled.returncode != 0:
        return None, compiled.stderr
    with open(page) as f:
        text = f.read()
    if '<script type="module" src="./program.js">' not in text:
        return None, "the generated page does not load ./program.js"
    # The `web` target writes no package.json -- a browser does not read
    # one -- so running its module under node needs the harness to say
    # what a browser would have taken for granted.
    with open(os.path.join(workdir, "package.json"), "w") as f:
        f.write('{\n  "type": "module"\n}\n')
    return executed(run(NODE + [os.path.join(workdir, "program.js")]))


# The driver that runs an `iweb` page's program outside a browser: the
# page's own script is three lines of glue around `pykRunProgram`, and
# this is the same glue with node's filesystem in place of `fetch`. What
# it proves is that the interpreter, the sources and the external
# modules the page ships really do run the program; that a browser
# parses the page is `make -C tools/playground e2e`'s business.
IWEB_DRIVER = """
import fs from 'fs';
const here = process.argv[2];
const files = fs.readdirSync(here);
globalThis.pykSources = Object.fromEntries(
  files.filter((f) => f.endsWith('.pyk'))
       .map((f) => [f, fs.readFileSync(here + '/' + f, 'utf8')]));
globalThis.pykExternals = {};
for (const f of files) {
  if (f.endsWith('.js') && f !== 'pyking.js') {
    // An external module is an ES module, but node decides that from
    // the file extension and the nearest package.json -- and an `iweb`
    // program has neither, because nothing about it runs under node: a
    // browser reading `<script type="module">` needs no such hint. So
    // the copy this driver imports is named .mjs, which says it outright
    // and leaves pyking.js (a classic script) read as one.
    const mjs = here + '/' + f.slice(0, -3) + '.pyk-test.mjs';
    fs.copyFileSync(here + '/' + f, mjs);
    globalThis.pykExternals[f.slice(0, -3)] = await import(mjs);
  }
}
globalThis.pykOnPrint = (line) => process.stdout.write(line);
await import(here + '/pyking.js');
const result = JSON.parse(pykRunProgram(process.argv[3]));
if (!result.ok) {
  process.stderr.write(result.stage + ': ' + result.text + '\\n');
  process.exit(1);
}
"""


def run_iweb(source, workdir, modules):
    """Runs an `iweb` program the way its page does, under node.

    Nothing is compiled for this target: the page ships the Pyking
    sources and the interpreter built to JavaScript, so what runs is the
    program itself, interpreted. That is why it supports the whole
    language where a backend supports a subset -- and why its output is
    compared against the same `.out` as every other target."""
    page = os.path.join(workdir, "program.html")
    compiled = compile_to(source, "iweb24", page)
    if compiled.returncode != 0:
        return None, compiled.stderr
    driver = os.path.join(workdir, "run-iweb.mjs")
    with open(driver, "w") as f:
        f.write(IWEB_DRIVER)
    return executed(run(NODE + [driver, workdir, os.path.basename(source)]))


def run_c(source, workdir, modules, standard):
    """Compiles to C, builds it with the system compiler, runs the binary.
    `-pedantic` is on: the point of having a `c89` target at all is that
    its output really is C89, and a compiler that merely tolerates it
    would hide the difference from `c23`."""
    generated = os.path.join(workdir, "program.c")
    compiled = compile_to(source, standard, generated)
    if compiled.returncode != 0:
        return None, compiled.stderr
    binary = os.path.join(workdir, "program")
    built = run(
        [C_COMPILER, f"-std={standard}", "-pedantic", "-o", binary]
        + [os.path.join(workdir, name + ".c") for name in modules]
        + [generated]
    )
    if built.returncode != 0:
        return None, built.stderr
    return executed(run([binary]))


def run_java(source, workdir, modules, version):
    """Compiles to Java, builds it with `javac --release <version>`, runs
    the class with `java`. The class is named `Program` here rather than
    whatever the backend would pick by default -- `--output` always names
    it explicitly (see `src/target_java.ml`), so the test harness's own
    naming choice never has to match the source file's."""
    generated = os.path.join(workdir, "Program.java")
    compiled = compile_to(source, version, generated)
    if compiled.returncode != 0:
        return None, compiled.stderr
    release = version.removeprefix("java")
    built = run(
        [JAVA_COMPILER, "--release", release, "-d", workdir]
        + [os.path.join(workdir, java_class_name(name) + ".java")
           for name in modules]
        + [generated]
    )
    if built.returncode != 0:
        return None, built.stderr
    return executed(run([JAVA_RUNTIME, "-cp", workdir, "Program"]))


def run_ocaml(source, workdir, modules):
    """Compiles to OCaml, builds it with `ocamlopt`, runs the binary.

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
    # The modules first, each interface before its implementation: OCaml
    # links in the order it is given, and that is also the order the
    # modules' top levels run in.
    sources = []
    for name in modules:
        # An external module is copied rather than generated, so it has
        # no interface beside it: OCaml infers one from the source.
        interface = os.path.join(workdir, name + ".mli")
        if os.path.exists(interface):
            sources.append(interface)
        sources.append(os.path.join(workdir, name + ".ml"))
    built = run(
        OCAML_COMPILER + ["-w", "+a-70", "-I", workdir, "-o", binary]
        + sources + [generated]
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


# `$OCAMLOPT` may name a wrapper rather than the compiler, and
# `ocamlfind` -- the usual one -- writes its own diagnostics to the same
# stream. They are about the *installation* rather than about anything
# that was compiled: a switch whose `ld.conf` names a `stublibs`
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


def run_interpret(source, _workdir, modules):
    """Runs the program with the interpreter, and compares what it
    printed against the same `.out` every compiling target is compared
    against.

    Nothing is written to the work directory: `pyk <file>` produces no file
    at all, which is the whole difference between this and the nine
    targets above it. The exit status still goes through `executed`, so
    a program that prints its output and *then* hits a runtime error is a
    failure rather than a pass."""
    return executed(run(COMPILER + [source]))


def run_pyking(source, workdir, modules):
    """Compiles `source` to Pyking. Nothing is executed.

    For a `typecheck_*` program the result is its pretty-printed AST:
    the checker writes the types it inferred into it (`x: Int = 1`), so
    printing it is what the `.ast.out` records, and any error is a
    failure. The same program's `.out` records what it *prints*, checked
    by the backends it lists.

    For a `fail_typecheck_*` program it is the other way round -- the
    checker is *expected* to reject it, so the error message becomes the
    output to compare and type-checking cleanly is the failure."""
    return _pyking(
        source,
        [],
        expect_failure=os.path.basename(source).startswith(FAIL_TYPECHECK_PREFIX),
    )


def _pyking(source, flags, expect_failure):
    """Runs `pyk compile -t pyking --stdout` with these extra flags, and
    answers with whichever stream this program is expected to produce."""
    result = run(
        COMPILER + ["compile", "-t", PYKING_TARGET, "--stdout"]
        + flags + [source]
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


def run_python_notail(source, workdir, modules):
    """Runs the program with the tail-call pass off. Its output is
    compared against `.notail.out`, which must hold exactly what the
    `.out` does: the pass may make a program run in less space, never
    make it mean something else."""
    return _run_python(source, workdir, [NOTAIL_FLAG])


def run_pyking_notail(source, _workdir, modules):
    """Prints the program with the tail-call pass off, so the
    `.notail.ast.out` holds the program as it was written.

    The two pyking targets never disagree about whether a program
    checks: the pass runs only on programs that already do, and cannot
    turn one into a program that does not (docs/optimization.md, "Why
    one check is enough"). What they disagree about is the *shape* they
    print."""
    return _pyking(source, [NOTAIL_FLAG], expect_failure=False)


RUNNERS = {
    PYKING_TARGET: run_pyking,
    PYKING_NOTAIL_TARGET: run_pyking_notail,
    PYTHON_NOTAIL_TARGET: run_python_notail,
    INTERPRET_TARGET: run_interpret,
    "python14": run_python,
    "node24": run_node,
    "web24": run_web,
    "iweb24": run_iweb,
    "c89": lambda source, workdir, modules: run_c(source, workdir, modules, "c89"),
    "c99": lambda source, workdir, modules: run_c(source, workdir, modules, "c99"),
    "c23": lambda source, workdir, modules: run_c(source, workdir, modules, "c23"),
    "java8": lambda source, workdir, modules: run_java(
        source, workdir, modules, "java8"),
    "java17": lambda source, workdir, modules: run_java(
        source, workdir, modules, "java17"),
    "java21": lambda source, workdir, modules: run_java(
        source, workdir, modules, "java21"),
    "ocaml5.5": run_ocaml,
}


def load_cases():
    """The manifest, with a warning for anything that has drifted out of
    step with the files actually on disk."""
    with open(CASES_FILE, "rb") as f:
        cases = tomllib.load(f)["cases"]
    # A module a program imports is not a case of its own: it is not a
    # program, and it is compiled and run only as part of the one that
    # imports it. It is still a file the manifest accounts for, which is
    # what keeps the "not listed" warning honest.
    imported = {name for case in cases for name in case.get("modules", [])}
    listed = {case["file"] for case in cases}
    on_disk = {os.path.basename(p) for p in glob.glob(os.path.join("tests", "*.pyk"))}
    for missing in sorted(on_disk - listed - imported):
        print(f"WARNING: tests/{missing} is not listed in {CASES_FILE}")
    for missing in sorted((listed | imported) - on_disk):
        print(f"WARNING: {CASES_FILE} lists {missing}, which does not exist")
    for name in sorted(listed & imported):
        print(
            f"WARNING: {name} is both a program of its own and a module "
            f"another program imports; a module is listed only under the "
            f"program that imports it"
        )
    # The naming convention and the manifest have to agree about which
    # programs have their types pinned, and about which of those are also
    # run, so that neither can drift silently.
    for case in cases:
        name = case["file"]
        targets = case["targets"]
        checks = name.startswith(TYPECHECK_PREFIX)
        fails = name.startswith(FAIL_TYPECHECK_PREFIX)
        uses_pyking = PYKING_TARGET in targets
        # A program importing an external module cannot be interpreted:
        # what that module exports is written in a target language.
        external = any(module.endswith(EXTERNAL_SUFFIX)
                       for module in case.get("modules", []))

        if (checks or fails) and not uses_pyking:
            print(
                f"WARNING: {name} is named {TYPECHECK_PREFIX}* or "
                f"{FAIL_TYPECHECK_PREFIX}* but does not list the "
                f"{PYKING_TARGET} target"
            )
        if uses_pyking and not (checks or fails):
            print(
                f"WARNING: {name} uses the {PYKING_TARGET} target "
                f"but is named neither {TYPECHECK_PREFIX}* nor "
                f"{FAIL_TYPECHECK_PREFIX}*"
            )
        # The pass must not change what a program means, and the pair of
        # outputs is where that is checked -- so a program that runs one
        # way should run the other.
        if PYTHON_NOTAIL_TARGET in targets and "python14" not in targets:
            print(
                f"WARNING: {name} lists {PYTHON_NOTAIL_TARGET} but not "
                f'"python14"; the two outputs are only worth comparing '
                f"together"
            )
        # A program whose types are pinned must also be a program that
        # runs: `python` compiles the whole language, so a
        # `typecheck_*` file that does not list it is describing
        # something nothing ever executes.
        if checks and "python14" not in targets:
            print(
                f"WARNING: {name} pins its types but lists no backend; add "
                f'"python14" so the program it describes is one that runs'
            )
        # The interpreter runs the checker's fragment, so a program whose
        # types are pinned is one it can run -- and the cheapest check
        # that the two agree is to actually run it.
        if checks and INTERPRET_TARGET not in targets and not external:
            print(
                f"WARNING: {name} pins its types but does not list "
                f'"{INTERPRET_TARGET}"; the interpreter runs exactly the '
                f"fragment the checker accepts"
            )
        # Every program is type-checked, and the interpreter runs what
        # the checker accepts, so a program that runs at all runs there.
        # The exception is a program importing an external module: what
        # that exports is written in a target language, and only a
        # compiled program can reach it (see docs/modules.md).
        if not fails and INTERPRET_TARGET not in targets and not external:
            print(
                f'WARNING: {name} does not list "{INTERPRET_TARGET}"; every '
                f"program that runs at all runs under the interpreter"
            )
        # A `fail_typecheck_*` program is written to be refused, so there
        # is nothing to run and no `.out` to compare.
        if fails and targets != [PYKING_TARGET]:
            print(
                f"WARNING: {name} is named {FAIL_TYPECHECK_PREFIX}* so it "
                f'must list exactly targets = ["{PYKING_TARGET}"]'
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
    """Every (target, program) run the manifest declares, in the order
    their results are reported. [Case] -> [(String, String, [String])]"""
    return [
        (target, os.path.join("tests", case["file"]), module_names(case))
        for target in TARGETS
        for case in cases
        if target in case["targets"]
    ]


def module_names(case):
    """The modules one program imports, as module names, dependencies
    first -- the order the manifest lists them in, which is the order
    they must be built and run in. Case -> [String]"""
    # `sys.external.pyk` is module `sys`: the marker is part of the file
    # name, not of the name another module imports it by.
    return [os.path.splitext(os.path.splitext(name)[0])[0]
            if name.endswith(".external.pyk") else os.path.splitext(name)[0]
            for name in case.get("modules", [])]


def java_class_name(module_name):
    """What src/target_java.ml calls the file it compiles a module to;
    Java requires the class and its file to share a name.
    String -> String"""
    return "".join(
        word[:1].upper() + word[1:] for word in re.findall(r"[A-Za-z0-9]+", module_name)
    )


def run_case(target, source, modules):
    """Runs one program on one target and words the result, rather than
    printing it: a run this far from the reporting loop is one that can
    happen on any thread. `modules` names the modules the program
    imports, dependencies first, which the compiler writes beside the
    program's own output and which the targets that link a program have
    to be given in that order.
    String -> String -> [String] -> (String, Bool)"""
    with open(expected_path(source, target)) as f:
        expected = f.read()
    with tempfile.TemporaryDirectory() as workdir:
        actual, error = RUNNERS[target](source, workdir, modules)

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
    [(String, String, [String])] -> Int
    -> iterator of (String, String, Bool)"""
    if jobs == 1:
        for task in tasks:
            report, failed = run_case(*task)
            yield task[0], report, failed
        return
    pool = ThreadPoolExecutor(max_workers=jobs)
    try:
        futures = [pool.submit(run_case, *task) for task in tasks]
        for (target, _, _), future in zip(tasks, futures):
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


def parse_args(argv):
    """How many runs this invocation wants in flight, and what command
    runs the compiler. [String] -> (Int, [String])"""
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
    parser.add_argument(
        "--compiler",
        metavar="CMD",
        help=(
            "the command that runs the compiler, split on spaces "
            f"(default: {' '.join(DEFAULT_COMPILER)})"
        ),
    )
    parser.add_argument(
        "--target",
        metavar="NAME",
        help=(
            "run only this target, or every version of this family "
            f"({', '.join(sorted(FAMILIES))}); default: all of them"
        ),
    )
    arguments = parser.parse_args(argv)
    jobs = arguments.jobs if arguments.jobs is not None else default_jobs()
    compiler = (
        arguments.compiler.split() if arguments.compiler else DEFAULT_COMPILER
    )
    only = None
    if arguments.target:
        only = selected_targets(arguments.target)
        if not only:
            parser.error(
                f"unknown target {arguments.target!r}; expected one of "
                f"{', '.join(TARGETS)}, or a family "
                f"({', '.join(sorted(FAMILIES))})"
            )
    return jobs, compiler, only


def main():
    global COMPILER
    jobs, COMPILER, only = parse_args(sys.argv[1:])
    cases = load_cases()
    tasks = plan(cases)
    if only is not None:
        # The manifest is still read whole -- its warnings are about the
        # suite as a whole, not about the targets being run -- and only
        # the runs are narrowed.
        tasks = [task for task in tasks if task[0] in only]
    shown = TARGETS if only is None else tuple(t for t in TARGETS if t in only)
    passed = {target: 0 for target in shown}
    failed = {target: 0 for target in shown}

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
    # columns stay lined up whatever a target is called -- `pyking_notail`
    # is already longer than every backend name.
    width = max(len(target) for target in shown)
    for target in shown:
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
