#!/usr/bin/env python3
"""Runs the library search path's own test cases: how `pyk` resolves an
imported module through the four levels it looks in, and how it refuses
one it cannot find.

The `.pyk` suite in test_script.py runs (program, target) pairs, so
nothing there can reach any of this: the order of `-L` flags, an
environment variable, a name that resolves in two places at once, and
the wording of a failure are properties of the *invocation* rather than
of a program. This covers those.

Each case builds a throwaway tree of tiny libraries, each exporting a
`tag()` that answers with its own name, and runs the program with the
interpreter -- so what is printed says which library was actually
found. See docs/libraries.md, "The search path".

The built-in level (a `lib/` beside the executable) is not exercised
here: it is what the whole standard library in the `.pyk` suite already
resolves through.

The other half of what an invocation decides is where `pyk compile`
writes: build/ beside the executable, its Makefile, an earlier build/
replaced and anyone else's refused, and `pyk <file> -t <target>`
(`build_cases`).

Usage: python3 tests/test_libpath.py [--compiler CMD]

Functions:
    cases() -- every case, in the order they are reported.
    build_cases() -- every check of where `pyk compile` writes.
    run(compiler, case, root) -- one case; answers (ok, detail).
    main(argv) -- the command-line entry point.
"""

import os
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import suite  # noqa: E402  (after sys.path, which is what finds it)

REPO = HERE.parent
DEFAULT_COMPILER = [str(REPO / "pyk")]
# Long enough for a compile that has gone wrong to be reported as a
# failure rather than as a hang.
STEP_TIMEOUT = 60
# The separator a path list uses inside an environment variable, which
# src/pyk.ml takes from the platform for the same reason every other
# tool on it does.
SEPARATOR = ";" if os.name == "nt" else ":"


def library(directory, name, tag, external=False, body=True):
    """A library folder holding one module: `<directory>/<name>/`, with
    `tag()` answering `tag`. `external` writes a declaration file
    instead, and `body` False writes the folder and no module at all --
    which is what a library missing its own source looks like.
    Path -> String -> String -> Bool -> Bool -> ()"""
    folder = directory / name
    folder.mkdir(parents=True, exist_ok=True)
    if not body:
        return
    if external:
        (folder / f"{name}_external.pyk").write_text(
            f"public def tag : () -> String\n")
        return
    (folder / f"{name}.pyk").write_text(
        "public def tag() -> String:\n"
        f'    return "{tag}"\n')


def program(directory, name="prog.pyk", module="mylib"):
    """A program importing one module and printing its tag.
    Path -> String -> String -> Path"""
    path = directory / name
    path.write_text(f"import {module}\n\nprint({module}.tag())\n")
    return path


def cases():
    """Every case, in the order they are reported. Each answers
    (name, build), where `build` prepares a tree under a fresh directory
    and answers (arguments, environment, expected) -- `expected` being
    the text the run must print, or a fragment its refusal must contain.
    () -> [(String, Callable)]"""

    def from_flag(root):
        library(root / "libs", "mylib", "flag")
        return ([f"-L{root / 'libs'}"], {}, "flag\n")

    def from_flag_separate(root):
        library(root / "libs", "mylib", "flag")
        return (["-L", str(root / "libs")], {}, "flag\n")

    def from_environment(root):
        library(root / "libs", "mylib", "environment")
        return ([], {"PYKING_LIB_PATH": str(root / "libs")}, "environment\n")

    def local_beats_flag(root):
        # A module beside the importing file is level 1, so it wins even
        # though a library of the same name is on the path.
        (root / "mylib.pyk").write_text(
            'public def tag() -> String:\n    return "local"\n')
        library(root / "libs", "mylib", "flag")
        return ([f"-L{root / 'libs'}"], {}, "local\n")

    def flag_beats_environment(root):
        library(root / "flagged", "mylib", "flag")
        library(root / "environed", "mylib", "environment")
        return (
            [f"-L{root / 'flagged'}"],
            {"PYKING_LIB_PATH": str(root / "environed")},
            "flag\n",
        )

    def flags_left_to_right(root):
        library(root / "first", "mylib", "first")
        library(root / "second", "mylib", "second")
        return (
            [f"-L{root / 'first'}", f"-L{root / 'second'}"],
            {},
            "first\n",
        )

    def environment_left_to_right(root):
        library(root / "first", "mylib", "first")
        library(root / "second", "mylib", "second")
        joined = SEPARATOR.join([str(root / "first"), str(root / "second")])
        return ([], {"PYKING_LIB_PATH": joined}, "first\n")

    def environment_separator_skips_empty(root):
        # A trailing separator is an empty entry, and an empty entry is
        # dropped rather than read as the current directory.
        library(root / "libs", "mylib", "environment")
        joined = SEPARATOR.join(["", str(root / "libs"), ""])
        return ([], {"PYKING_LIB_PATH": joined}, "environment\n")

    def unknown_module(root):
        return ([], {}, "cannot read module 'mylib'")

    def unknown_module_names_paths(root):
        # The refusal has to say where it looked, in order and with
        # where each candidate came from.
        library(root / "libs", "other", "other")
        return ([f"-L{root / 'libs'}"], {}, "(-L)")

    def flag_at_missing_directory(root):
        # A path that is not there is not an error in itself; it just
        # holds nothing, and the module is still unresolved.
        return ([f"-L{root / 'nowhere'}"], {}, "cannot read module 'mylib'")

    def library_folder_without_module(root):
        library(root / "libs", "mylib", "", body=False)
        return ([f"-L{root / 'libs'}"], {}, "cannot read module 'mylib'")

    def both_halves(root):
        # A level holding both files is one module, not a collision: the
        # .pyk is its Pyking half and the _external.pyk the host's. What
        # proves it resolved as one module here is the refusal that
        # follows -- the interpreter looks for the host half's OCaml
        # implementation beside the declaration, and there is none.
        library(root / "libs", "mylib", "written")
        (root / "libs" / "mylib" / "mylib_external.pyk").write_text(
            "public def other : () -> String\n")
        return ([f"-L{root / 'libs'}"], {},
                "OCaml implementation")

    return [
        ("from -Lpath", from_flag),
        ("from -L path", from_flag_separate),
        ("from PYKING_LIB_PATH", from_environment),
        ("local beats -L", local_beats_flag),
        ("-L beats PYKING_LIB_PATH", flag_beats_environment),
        ("two -L, left to right", flags_left_to_right),
        ("PYKING_LIB_PATH, left to right", environment_left_to_right),
        ("PYKING_LIB_PATH skips an empty entry",
         environment_separator_skips_empty),
        ("FAILS: unknown module", unknown_module),
        ("FAILS: refusal names the paths tried", unknown_module_names_paths),
        ("FAILS: -L at a missing directory", flag_at_missing_directory),
        ("FAILS: library folder with no module", library_folder_without_module),
        ("both halves of a name are one module", both_halves),
    ]


def run(compiler, build, root):
    """One case: prepares its tree, runs the program, and answers
    (ok, detail). A case whose expected text is a whole printed output
    must match it exactly; one naming a fragment of a refusal must
    contain it, since a refusal also carries absolute paths.
    [String] -> Callable -> Path -> (Bool, String)"""
    arguments, environment, expected = build(root)
    source = program(root)
    child = dict(os.environ)
    child.pop("PYKING_LIB_PATH", None)
    child.update(environment)
    try:
        result = subprocess.run(
            compiler + arguments + [str(source)],
            capture_output=True, text=True, timeout=STEP_TIMEOUT,
            cwd=root, env=child,
        )
    except subprocess.TimeoutExpired:
        return False, f"timed out after {STEP_TIMEOUT} seconds"
    both = result.stdout + result.stderr
    if expected.endswith("\n"):
        if result.stdout == expected:
            return True, ""
        return False, f"expected {expected!r}, got {both!r}"
    # Every message the driver prints is reflowed to its own width, so a
    # fragment is looked for with runs of whitespace flattened rather
    # than as it happens to have been broken across lines.
    flattened = " ".join(both.split())
    if " ".join(expected.split()) in flattened:
        return True, ""
    return False, f"expected {expected!r} somewhere in {both!r}"


# --- where `pyk compile` writes ---
# The other half of what an invocation decides: every file generated
# goes in build/ beside the executable, with a Makefile, an earlier
# build/ is replaced and anyone else's refused, and `pyk <file> -t T`
# builds there and runs from there. See docs/pyk.md, "`build/`".

HELLO = 'import sys\nprint("hello", sys.args())\n'


def invoke(compiler, root, arguments):
    """Runs pyk in root. -> CompletedProcess"""
    return subprocess.run(compiler + arguments, capture_output=True, text=True,
                          timeout=STEP_TIMEOUT * 3, cwd=root, stdin=subprocess.DEVNULL)


def build_cases():
    """Every check of what `pyk compile` writes, each a function from the
    compiler and a fresh directory to (ok, detail).
    () -> [(String, Callable)]"""

    def native(compiler, root):
        (root / "hello.pyk").write_text('print("hello")\n')
        ran = invoke(compiler, root, ["compile", "-t", "c", "hello.pyk"])
        built = root / "build"
        wanted = ["hello", "hello.c", "Makefile", ".pyk-build"]
        missing = [n for n in wanted if not (built / n).exists()]
        if ran.returncode != 0 or missing:
            return False, f"status {ran.returncode}, missing {missing}: {ran.stderr}"
        beside = sorted(p.name for p in root.iterdir())
        if beside != ["build", "hello", "hello.pyk"]:
            return False, f"beside build/: {beside}"
        out = subprocess.run([str(root / "hello")], capture_output=True, text=True)
        return out.stdout == "hello\n", out.stdout + out.stderr

    def launcher(compiler, root):
        (root / "hello.pyk").write_text(HELLO)
        (root / "out").mkdir()
        ran = invoke(compiler, root, ["compile", "-t", "python", "-o", "out/hi", "hello.pyk"])
        if ran.returncode != 0 or not (root / "out" / "build" / "hi.py").exists():
            return False, ran.stderr
        out = subprocess.run([str(root / "out" / "hi"), "a"], capture_output=True, text=True)
        return out.stdout == "hello ['a']\n", out.stdout + out.stderr

    def replaced(compiler, root):
        (root / "hello.pyk").write_text(HELLO)
        invoke(compiler, root, ["compile", "-t", "node", "hello.pyk"])
        (root / "build" / "stale.txt").write_text("from before")
        ran = invoke(compiler, root, ["compile", "-t", "node", "hello.pyk"])
        if ran.returncode != 0:
            return False, ran.stderr
        return not (root / "build" / "stale.txt").exists(), "build/stale.txt survived"

    def refused(compiler, root):
        (root / "hello.pyk").write_text(HELLO)
        (root / "build").mkdir()
        (root / "build" / "mine.txt").write_text("somebody's own")
        ran = invoke(compiler, root, ["compile", "-t", "python", "hello.pyk"])
        said = " ".join(ran.stderr.split())
        if ran.returncode == 0 or "was not made by pyk compile" not in said:
            return False, f"status {ran.returncode}: {ran.stderr}"
        return (root / "build" / "mine.txt").exists(), "build/ was touched"

    def run_target(compiler, root):
        (root / "hello.pyk").write_text(HELLO)
        ran = invoke(compiler, root, ["hello.pyk", "-t", "ocaml", "--", "x"])
        if ran.stdout != "hello ['x']\n":
            return False, ran.stdout + ran.stderr
        beside = sorted(p.name for p in root.iterdir())
        return beside == ["build", "hello.pyk"], f"beside build/: {beside}"

    def makefile(compiler, root):
        if shutil.which("make") is None:
            return True, ""
        (root / "hello.pyk").write_text(HELLO)
        ran = invoke(compiler, root, ["compile", "-t", "java", "--no-build", "hello.pyk"])
        if ran.returncode != 0 or (root / "hello").exists() or (root / "build" / "Hello.class").exists():
            return False, "--no-build built something: " + ran.stderr
        made = subprocess.run(["make", "-s", "run", "ARGS=m"], cwd=root / "build",
                              capture_output=True, text=True, timeout=STEP_TIMEOUT * 3)
        if made.stdout != "hello ['m']\n":
            return False, made.stdout + made.stderr
        subprocess.run(["make", "-s", "clean"], cwd=root / "build", capture_output=True)
        return not list((root / "build").glob("*.class")), "make clean left classes"

    def page_link(compiler, root):
        (root / "hello.pyk").write_text('print("hello")\n')
        ran = invoke(compiler, root, ["compile", "-t", "web", "-o", "page", "hello.pyk"])
        if ran.returncode != 0 or (root / "page").exists():
            return False, "a page target left something beside build/: " + ran.stderr
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        server = subprocess.Popen(compiler + ["serve", "--port", str(port), "build/page.html"], cwd=root,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            for _ in range(20):
                line = server.stdout.readline()
                if "http://" in line:
                    return line.strip().endswith("/page.html"), line.strip()
            return False, "pyk serve printed no link"
        finally:
            server.terminate()
            server.wait()

    def page_free_port(compiler, root):
        (root / "hello.pyk").write_text('print("hello")\n')
        held = []
        for port in range(8000, 8020):
            taken = socket.socket()
            try:
                taken.bind(("127.0.0.1", port))
                taken.listen(1)
                held.append(taken)
            except OSError:
                taken.close()
        server = subprocess.Popen(compiler + ["hello.pyk", "-t", "web"], cwd=root,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            said = []
            for _ in range(20):
                line = server.stdout.readline()
                said.append(line.rstrip())
                if "http://" in line:
                    link = line.strip()
                    port = int(link.split(":")[2].split("/")[0])
                    if "--port" in "\n".join(said) or not link.endswith("/hello.html"):
                        return False, "\n".join(said)
                    return not 8000 <= port < 8020, link
                if not line:
                    break
            return False, "\n".join(said)
        finally:
            server.terminate()
            server.wait()
            for taken in held:
                taken.close()

    return [
        ("build/: a binary beside it, the generated files in it", native),
        ("build/: a launcher, and -o naming it elsewhere", launcher),
        ("build/: an earlier one is replaced", replaced),
        ("FAILS: build/ somebody else made", refused),
        ("build/: pyk <file> -t <target> runs it from there", run_target),
        ("build/: --no-build, and its Makefile", makefile),
        ("build/: pyk serve on a page links the page", page_link),
        ("build/: pyk <file> -t web takes a free port when 8000.. are taken",
         page_free_port),
    ]


def parse_args(argv):
    """`--compiler CMD` or the default. [String] -> [String]"""
    if argv[:1] == ["--compiler"]:
        if len(argv) < 2:
            print("usage: test_libpath.py [--compiler CMD]", file=sys.stderr)
            sys.exit(2)
        return argv[1].split()
    if argv:
        print("usage: test_libpath.py [--compiler CMD]", file=sys.stderr)
        sys.exit(2)
    return list(DEFAULT_COMPILER)


def main(argv):
    """Runs every case and reports it. [String] -> Int"""
    compiler = parse_args(argv)
    found = cases()
    failed = 0
    for name, build in found:
        directory = tempfile.mkdtemp(prefix="pyk-libpath-")
        try:
            ok, detail = run(compiler, build, Path(directory))
        finally:
            shutil.rmtree(directory, ignore_errors=True)
        if ok:
            print(f"libpath: {name} OK.")
            continue
        failed += 1
        print(f"libpath: {name} FAILED")
        print(f"  {detail}")
    for name, check in build_cases():
        directory = tempfile.mkdtemp(prefix="pyk-build-")
        try:
            ok, detail = check(compiler, Path(directory))
        except (OSError, subprocess.SubprocessError) as error:
            ok, detail = False, str(error)
        finally:
            shutil.rmtree(directory, ignore_errors=True)
        found = found + [(name, check)]
        if ok:
            print(f"libpath: {name} OK.")
            continue
        failed += 1
        print(f"libpath: {name} FAILED")
        print(f"  {detail}")
    suite.footer("libpath", len(found) - failed, failed,
                 f"{len(found)} invocation{'' if len(found) == 1 else 's'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
