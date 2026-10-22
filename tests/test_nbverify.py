#!/usr/bin/env python3
"""The nbverify suite: tools/nbverify/nbverify.py grading the exercises
and quizzes of the notebooks in tests/nbjson/ the way the ID2202
autograder would run it.

For every exercise and quiz of every notebook there, `paramdata` writes
a test file per test, and each student solution for it in
tests/nbverify/ -- `<book>_<name>_s<N>.pyk`, `<name>` being `default`
for a notebook's only, unnamed item -- is run by each test's command,
`nbverify.py run`, and verified with that test's params. What it gets
is held to the notebook's own tests/nbverify/<book>.toml: whether it is
accepted, and the reason the first refused test gives. Every item has a solution accepted
and one refused. Then `paramschema` and the params against it, the
reasons against the notebook page's own words, the version, and the
command line's refusals.

Usage: python3 tests/test_nbverify.py [--compiler CMD] [--update] [--only BOOK,...]

`--update` rewrites the reasons in the <book>.toml files from what
nbverify now says; whether each solution is accepted is never
rewritten. Read the diff before keeping it. `--only` grades the
solutions of the notebooks named (by stem) and nothing else.

Functions:
    solution_item(file, books) -- the notebook and item a solution file is for.
    grade(tests, solution) -- the verdict on a solution, over every test.
    check_solutions(compiler, update, items) -- every solution against
      its notebook's <book>.toml.
    check_schema(tests) -- paramschema, and every test's params by it.
    check_command_line(compiler) -- the help, the version and the refusals.
    main(argv) -- the command-line entry point.
"""

import concurrent.futures
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import suite  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
BOOKS = REPO / "tests" / "nbjson"
SOLUTIONS = REPO / "tests" / "nbverify"
NBVERIFY = REPO / "tools" / "nbverify" / "nbverify.py"
ACTIVITIES = REPO / "tools" / "notebook" / "assets" / "activities.js"
DEFAULT_COMPILER = str(REPO / "pyk")
TIMEOUT = 300
SOLUTION_NAME = re.compile(r"^(.+)_s([0-9]+)\.pyk$")


class Checks:
    """Checks made and the failures among them."""

    def __init__(self):
        self.passed, self.failures = 0, []

    def check(self, ok, label, detail=""):
        if ok:
            self.passed += 1
        else:
            self.failures.append(label + (f": {detail}" if detail else ""))
        return ok


def nbverify(args, data=None, cwd=None, env=None):
    """One run of nbverify.py: (status, stdout, stderr)."""
    ran = subprocess.run([sys.executable, str(NBVERIFY)] + args, input=data, capture_output=True,
                         text=True, cwd=cwd, env=env, timeout=TIMEOUT)
    return ran.returncode, ran.stdout, ran.stderr


def book_items(compiler, only=None):
    """Every notebook's items, with the test files paramdata writes for
    each: {(book, name): [test.options]}, and the failures making them.
    [String] -> [String]? -> ({(String, String): [{..}]}, [String])"""
    env = dict(os.environ, PYK=compiler[0])
    found, failures = {}, []
    for book in sorted(BOOKS.glob("*.md")):
        if only and book.stem not in only:
            continue
        ran = subprocess.run(compiler + ["notebook", str(book), "--to-json", "-o", "-"],
                             capture_output=True, text=True, timeout=TIMEOUT)
        if ran.returncode != 0:
            failures.append(f"{book.name}: --to-json: {ran.stderr.strip()}")
            continue
        notebook = json.loads(ran.stdout)
        counts, items = {"exercise": 0, "quiz": 0}, []
        for block in notebook["blocks"]:
            if block["type"] in counts:
                counts[block["type"]] += 1
                name = (block.get("attributes") or {}).get("name")
                items.append(name or f"{block['type']}-{counts[block['type']]}")
        if len(items) == 1 and items[0] in ("exercise-1", "quiz-1"):
            items = ["default"]
        for name in items:
            with tempfile.TemporaryDirectory(prefix="pyk-nbverify-") as directory:
                status, _, err = nbverify(["paramdata", str(book), "--name", name, "--output-dir", directory],
                                          env=env)
                if status != 0:
                    failures.append(f"{book.name} {name}: paramdata: {err.strip()}")
                    continue
                tests = []
                for file in sorted(Path(directory).iterdir()):
                    with open(file, "rb") as f:
                        tests.append(tomllib.load(f)["test"]["options"])
                found[(book.stem, name)] = tests
    return found, failures


def solution_item(file, items):
    """The notebook and item a solution file is for, by its name -- a
    notebook's stem, `_`, the item's name, `_s` and a number -- or None.
    String -> {(String, String): ..} -> (String, String)?"""
    m = SOLUTION_NAME.match(file)
    if not m:
        return None
    stem = m.group(1)
    for book, name in items:
        if stem == f"{book}_{name}":
            return book, name
    return None


def grade(tests, solution, env):
    """A solution run by each test's command, in a directory of its own
    as solution.pyk, and verified with that test's params, as the
    autograder does: (accepted, the first refused test's reason).
    [{..}] -> Path -> {..} -> (Bool, String)"""
    for options in tests:
        with tempfile.TemporaryDirectory(prefix="pyk-nbverify-") as directory:
            shutil.copy(solution, Path(directory) / "solution.pyk")
            command = [sys.executable, str(NBVERIFY)] + options["args"]
            ran = subprocess.run(command, input=options.get("stdin", "").encode(), cwd=directory,
                                 capture_output=True, env=env, timeout=TIMEOUT)
            data = {
                "cmd": ["./graded-bin"] + options["args"], "code": ran.returncode,
                "stdout": {"enc": "utf8", "data": ran.stdout.decode("utf-8", "replace")},
                "stderr": {"enc": "utf8", "data": ran.stderr.decode("utf-8", "replace")},
                "files": {}, "params": options["verifier_params"],
            }
            status, out, err = nbverify([], json.dumps(data), env=env)
            try:
                verdict = json.loads(out)
            except json.JSONDecodeError:
                return False, f"nbverify answered no JSON (status {status}): {err.strip()}"
            if verdict.get("accepted") is not True:
                if status != 1:
                    return False, f"nbverify refused with status {status}, not 1: {verdict}"
                return False, verdict.get("reason") or ""
            if status != 0:
                return False, f"nbverify accepted with status {status}, not 0"
    return True, ""


def toml_string(text):
    return json.dumps(text, ensure_ascii=False)


def write_cases(path, cases):
    """A <book>.toml, one table per solution in file order. Path -> {..} -> ()"""
    lines = [f"# What tests/test_nbverify.py expects nbverify to say of each solution",
             f"# to {path.stem}.md: whether it is accepted, and the reason the first",
             "# refused test gives. `--update` rewrites the reasons; read the diff.", ""]
    for file in sorted(cases):
        case = cases[file]
        lines += ["[[solution]]", f"file = {toml_string(file)}",
                  f"accepted = {'true' if case['accepted'] else 'false'}",
                  f"reason = {toml_string(case.get('reason', ''))}", ""]
    path.write_text("\n".join(lines))


def check_solutions(compiler, update, items, only=None):
    """Every solution graded, and held to its notebook's <book>.toml;
    every item with a solution accepted and one refused.
    [String] -> Bool -> {..} -> [String]? -> (Checks, Int)"""
    checks = Checks()
    cases, sources = {}, {}
    for path in sorted(SOLUTIONS.glob("*.toml")):
        if only and path.stem not in only:
            continue
        checks.check((BOOKS / (path.stem + ".md")).exists(), f"{path.name} is named after a notebook in tests/nbjson")
        with open(path, "rb") as f:
            for case in tomllib.load(f).get("solution", []):
                cases[case["file"]] = case
                sources[case["file"]] = path
                checks.check(case["file"].startswith(path.stem + "_"), f"{path.name} holds {case['file']}",
                             "a solution belongs in the file of its notebook")
    files = sorted(p.name for p in SOLUTIONS.glob("*.pyk")
                   if not only or any(p.name.startswith(b + "_") for b in only))
    env = dict(os.environ, PYK=compiler[0])
    for file in files:
        checks.check(file in cases, f"{file} is in its notebook's .toml")
    for file in cases:
        checks.check(file in files, f"{sources[file].name}'s {file} is a file in tests/nbverify")
    targets = {}
    for file in files:
        item = solution_item(file, items)
        if checks.check(item is not None, f"{file} names a notebook in tests/nbjson and an item of it"):
            targets[file] = item
    jobs = max(1, len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count() or 1)
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        verdicts = dict(zip(targets, pool.map(
            lambda f: grade(items[targets[f]], SOLUTIONS / f, env), targets)))
    changed = set()
    for file, (accepted, reason) in verdicts.items():
        want = cases.get(file)
        if want is None:
            continue
        checks.check(accepted == want["accepted"],
                     f"{file} is {'accepted' if want['accepted'] else 'refused'}",
                     f"nbverify says {'accepted' if accepted else 'refused: ' + reason}")
        if update and reason != want.get("reason", ""):
            want["reason"] = reason
            changed.add(sources[file])
        elif not update:
            checks.check(reason == want.get("reason", ""), f"{file}: the reason",
                         f"nbverify says {reason!r}, cases.toml {want.get('reason', '')!r}")
    for path in sorted(changed):
        write_cases(path, {f: c for f, c in cases.items() if sources[f] == path})
        print(f"nbverify: {path.name} rewritten; read the diff before keeping it")
    for book, name in items:
        mine = [f for f, item in targets.items() if item == (book, name) and f in cases]
        checks.check(any(cases[f]["accepted"] for f in mine) and any(not cases[f]["accepted"] for f in mine),
                     f"{book} {name}: a solution accepted and one refused",
                     f"{len(mine)} solution{'' if len(mine) == 1 else 's'}")
    return checks, len(verdicts)


def check_schema(items):
    """paramschema is TOML the autograder reads -- a type and a default
    of that type per param -- and every test's params follow it.
    {..} -> Checks"""
    checks = Checks()
    status, out, err = nbverify(["paramschema"])
    if not checks.check(status == 0, "paramschema", err):
        return checks
    schema = tomllib.loads(out)["test"]["options"]["verifier_param_schema"]
    kinds = {"int": int, "bool": bool, "string": str, "list": list}
    for name, spec in schema.items():
        checks.check(set(spec) == {"type", "default"} and spec.get("type") in kinds
                     and type(spec.get("default")) is kinds.get(spec.get("type")),
                     f"paramschema's {name} has a type and a default of that type", json.dumps(spec))
    for (book, name), tests in items.items():
        for k, options in enumerate(tests):
            params = options.get("verifier_params", {})
            wrong = [p for p, v in params.items()
                     if p not in schema or type(v) is not kinds[schema[p]["type"]]]
            checks.check(not wrong, f"{book} {name} test {k + 1}: its params are the schema's", ", ".join(wrong))
            checks.check(isinstance(options.get("args"), list) and options["args"][:1] == ["run"]
                         and isinstance(options.get("stdin"), str),
                         f"{book} {name} test {k + 1}: args run the answer, and stdin is given")
    return checks


def check_command_line(compiler):
    """The help, the version, the words the notebook page uses, and what
    is refused. [String] -> Checks"""
    checks = Checks()
    env = dict(os.environ, PYK=compiler[0])
    status, out, _ = nbverify(["--help"])
    checks.check(status == 0 and "paramschema" in out and "paramdata" in out, "--help prints the help")
    status, out, _ = nbverify(["--version"])
    version = (REPO / "VERSION").read_text().strip()
    checks.check(status == 0 and out.strip() == f"nbverify {version}",
                 "--version prints the VERSION file's version", out.strip())
    page = ACTIVITIES.read_text()
    for said in ["Your program did not run:", "The output is not what it should be.",
                 "What it drew with tinyweb is not what it should be.",
                 "What debug printed is not what it should be.", "Your program ended with status ",
                 "Check at least one answer first.", "Choose an answer first.",
                 "One or more right answers were not checked.", "Not right."]:
        checks.check(said in page and said in NBVERIFY.read_text(),
                     f"nbverify and the notebook page both say {said!r}")
    accepted = {"cmd": ["x"], "code": 0, "stdout": {"enc": "utf8", "data": "[2]\n"},
                "stderr": {"enc": "utf8", "data": ""}, "files": {},
                "params": {"kind": "quiz", "quiz_alternatives": 2, "quiz_right": [2]}}
    status, out, _ = nbverify([], json.dumps(accepted))
    checks.check(status == 0 and json.loads(out) == {"accepted": True, "reason": None},
                 "no argument: a run is read on stdin, and accepted with status 0", out)
    encoded = dict(accepted, stdout={"enc": "base64", "data": "WzFdCg=="})
    status, out, _ = nbverify([], json.dumps(encoded))
    checks.check(status == 1 and json.loads(out)["accepted"] is False, "a base64 stream is decoded", out)
    for data, said in [("{not json", "the input is not JSON"),
                       (json.dumps(dict(accepted, params={"kind": "essay"})), "params.kind is exercise or quiz")]:
        status, out, _ = nbverify([], data)
        checks.check(status == 2 and said in json.loads(out)["reason"], f"refuses input: {said}", out)
    with tempfile.TemporaryDirectory(prefix="pyk-nbverify-") as directory:
        two = Path(directory) / "two.md"
        two.write_text("```pyking exercise name = \"a\"\nprint(1)\n```\n\n```stdout\n1\n```\n\n"
                       "Text.\n\n```quiz\n* x\n\n* y\n```\n\n```answer\n-> r\n- w\n```\n")
        one = Path(directory) / "one.md"
        one.write_text("```pyking exercise\nprint(1)\n```\n\n```stdin\n1\n```\n\n```stdout\n1\n```\n\n"
                       "```stdin\n2\n```\n\n```stdout\n1\n```\n")
        status, out, _ = nbverify(["paramdata", str(two), "--name", "quiz-1"], env=env)
        checks.check(status == 0 and "verifier_params.kind = \"quiz\"" in out,
                     "an unnamed item is called quiz-N, counting quizzes", out[-200:])
        status, out, _ = nbverify(["paramdata", str(one), "--name", "default", "--case", "2"], env=env)
        checks.check(status == 0 and "test 2 of 2" in out and 'stdin = "2\\n"' in out,
                     "--case N prints that test", out[:300])
        refusals = [
            (["paramdata", str(two)], "has 2 exercises and quizzes (a, quiz-1): give --name"),
            (["paramdata", str(two), "--name", "b"], "no exercise or quiz named 'b'"),
            (["paramdata", str(one)], "has 2 tests: give --case N"),
            (["paramdata", str(one), "--case", "3"], "has 2 tests"),
            (["paramdata", str(one), "--case", "1", "--output-dir", directory], "give one"),
            (["paramdata", str(Path(directory) / "missing.md")], "no such notebook"),
            (["paramdata"], "give the notebook"),
            (["paramschema", "x"], "takes no argument"),
            (["frobnicate"], "unknown command"),
            (["run"], "give the program to run"),
        ]
        for args, said in refusals:
            status, _, err = nbverify(args, env=env)
            checks.check(status == 2 and said in err, f"refuses nbverify {' '.join(args[:1] + args[2:])}",
                         err.strip())
        program = Path(directory) / "p.pyk"
        program.write_text("import io\nimport sys\ndebug(\"to stderr\")\nprint(io.read_line(), sys.args())\nsys.exit(3)\n")
        ran = subprocess.run([sys.executable, str(NBVERIFY), "run", str(program), "--", "a", "b c"],
                             input="hi\n", capture_output=True, text=True, env=env, timeout=TIMEOUT)
        trailer = ran.stderr.split("--- nbverify run ---\n")
        checks.check(ran.returncode == 3 and ran.stdout == "hi ['a', 'b c']\n" and len(trailer) == 2
                     and trailer[0] == "to stderr\n" and json.loads(trailer[1])["status"] == "ok",
                     "run passes stdin, stdout and the status through, and adds its trailer",
                     repr((ran.returncode, ran.stdout, ran.stderr)))
    return checks


def main(argv):
    """The command-line entry point. [String] -> Int"""
    compiler, update, only, rest = [DEFAULT_COMPILER], False, None, list(argv)
    while rest:
        flag = rest.pop(0)
        if flag == "--compiler" and rest:
            compiler = shlex.split(rest.pop(0))
        elif flag == "--update":
            update = True
        elif flag == "--only" and rest:
            only = [b for b in rest.pop(0).split(",") if b]
        else:
            print("usage: test_nbverify.py [--compiler CMD] [--update] [--only BOOK,...]", file=sys.stderr)
            return 2
    compiler = [str(Path(compiler[0]).resolve())] + compiler[1:] if Path(compiler[0]).exists() else compiler
    passed, failures = 0, []
    items, made = book_items(compiler, only)
    failures += made
    passed += len(items)
    graded, count = check_solutions(compiler, update, items, only)
    for checks in (graded, check_schema(items), check_command_line(compiler)):
        passed += checks.passed
        failures += checks.failures
    for failure in failures:
        print(f"nbverify: FAILED {failure}")
    tests = sum(len(t) for t in items.values())
    print(f"nbverify: {len(items)} exercises and quizzes, {tests} tests, {count} solutions.")
    suite.footer("nbverify", passed, len(failures), f"{count} solutions")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
