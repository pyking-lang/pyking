#!/usr/bin/env python3
"""The nbverify suite: tools/nbverify/nbverify.py grading the tasks
and quizzes of the notebooks in tests/nbjson/ the way the ID2202
autograder would run it.

For every task and quiz of every notebook there, `paramdata` writes
a test file per test, and each student solution for it in
tests/nbverify/ -- `<book>_<name>_s<N>.pyk`, `<name>` being `default`
for a notebook's only, unnamed item -- is run by each test's command,
`nbverify.py run`, and verified with that test's params. What it gets
is held to the notebook's own tests/nbverify/<book>.toml: whether it is
accepted, and the reason the first refused test gives. Every item has a solution accepted
and one refused. Each solution is graded a second time the way a
teacher tries one, `paramdata --case N | nbverify.py try`, on every
test, and must get the same verdict; one solution per item goes through
a real shell pipe, and `try`'s TOML reader must read every test file as
tomllib does. Then `paramschema` and the params against it, the
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
    grade_try(texts, solution) -- the same through `nbverify.py try`.
    check_try(compiler, items, texts, targets) -- a real pipe per item,
      and try's TOML reader against tomllib.
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

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools" / "nbverify"))
import nbverify as nbverify_module  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
BOOKS = REPO / "tests" / "nbjson"
SOLUTIONS = REPO / "tests" / "nbverify"
NBVERIFY = REPO / "tools" / "nbverify" / "nbverify.py"
ACTIVITIES = REPO / "tools" / "notebook" / "assets" / "activities.js"
DEFAULT_COMPILER = str(REPO / "pyk")
TIMEOUT = 300
SOLUTION_NAME = re.compile(r"^(.+)_s([0-9]+)\.pyk$")


class Checks:
    """Checks made and the failures among them, each printed as it is
    made."""

    def __init__(self):
        self.passed, self.failures = 0, []

    def check(self, ok, label, detail=""):
        if ok:
            self.passed += 1
        else:
            self.failures.append(label + (f": {detail}" if detail else ""))
        print(suite.case_line("nbverify", ok, label, detail), flush=True)
        return ok


def nbverify(args, data=None, cwd=None, env=None):
    """One run of nbverify.py: (status, stdout, stderr)."""
    ran = subprocess.run([sys.executable, str(NBVERIFY)] + args, input=data, capture_output=True,
                         text=True, cwd=cwd, env=env, timeout=TIMEOUT)
    return ran.returncode, ran.stdout, ran.stderr


def book_items(compiler, only=None):
    """Every notebook's items, with the test files paramdata writes for
    each: {(book, name): [test.options]}, the files' texts in the same
    shape, and the checks making them.
    [String] -> [String]? -> ({(String, String): [{..}]}, {(String, String): [String]}, Checks)"""
    env = dict(os.environ, PYK=compiler[0])
    found, texts, checks = {}, {}, Checks()
    for book in sorted(BOOKS.glob("*.md")):
        if only and book.stem not in only:
            continue
        ran = subprocess.run(compiler + ["notebook", str(book), "--to-json", "-o", "-"],
                             capture_output=True, text=True, timeout=TIMEOUT)
        if not checks.check(ran.returncode == 0, f"{book.name}: --to-json", ran.stderr.strip()):
            continue
        notebook = json.loads(ran.stdout)
        counts, items = {"task": 0, "practice": 0, "quiz": 0}, []
        for block in notebook["blocks"]:
            if block["type"] in counts:
                counts[block["type"]] += 1
                name = (block.get("attributes") or {}).get("name")
                items.append(name or f"{block['type']}-{counts[block['type']]}")
        if len(items) == 1 and items[0] in ("task-1", "practice-1", "quiz-1"):
            items = ["default"]
        for name in items:
            with tempfile.TemporaryDirectory(prefix="pyk-nbverify-") as directory:
                status, _, err = nbverify(["paramdata", str(book), "--name", name, "--output-dir", directory],
                                          env=env)
                if not checks.check(status == 0, f"{book.name} {name}: paramdata", err.strip()):
                    continue
                tests, written = [], []
                for file in sorted(Path(directory).iterdir()):
                    text = file.read_text(encoding="utf-8")
                    written.append(text)
                    tests.append(tomllib.loads(text)["test"]["options"])
                found[(book.stem, name)] = tests
                texts[(book.stem, name)] = written
    return found, texts, checks


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


def grade_try(texts, solution, env):
    """A solution graded by `nbverify.py try` on each test file's text, as
    `paramdata --case N | nbverify.py try solution.pyk` does:
    (accepted, the first refused test's reason). [String] -> Path -> {..} -> (Bool, String)"""
    for text in texts:
        with tempfile.TemporaryDirectory(prefix="pyk-nbverify-") as directory:
            shutil.copy(solution, Path(directory) / "solution.pyk")
            status, out, err = nbverify(["try", "solution.pyk"], text, cwd=directory, env=env)
            try:
                verdict = json.loads(out)
            except json.JSONDecodeError:
                return False, f"try answered no JSON (status {status}): {err.strip()}"
            if verdict.get("accepted") is not True:
                if status != 1:
                    return False, f"try refused with status {status}, not 1: {verdict} {err.strip()}"
                return False, verdict.get("reason") or ""
            if status != 0:
                return False, f"try accepted with status {status}, not 0"
    return True, ""


def check_try(compiler, items, texts, targets):
    """For every item, its first solution through a real shell pipe from
    `paramdata --case 1`, getting what `try` says of the first test file;
    and every test file read by try's own TOML reader as tomllib reads it.
    [String] -> {..} -> {..} -> {String: (String, String)} -> Checks"""
    checks = Checks()
    env = dict(os.environ, PYK=compiler[0])
    for key, written in sorted(texts.items()):
        for k, text in enumerate(written):
            try:
                same = nbverify_module.read_toml(text) == tomllib.loads(text)
                detail = ""
            except nbverify_module.Refusal as refusal:
                same, detail = False, str(refusal)
            checks.check(same, f"{key[0]} {key[1]} test {k + 1}: try reads its TOML as tomllib does",
                         detail)
    for (book, name) in sorted(items):
        solutions = sorted(f for f, item in targets.items() if item == (book, name))
        if not solutions or not texts.get((book, name)):
            continue
        with tempfile.TemporaryDirectory(prefix="pyk-nbverify-") as directory:
            shutil.copy(SOLUTIONS / solutions[0], Path(directory) / "solution.pyk")
            pipe = (f"{shlex.quote(sys.executable)} {shlex.quote(str(NBVERIFY))} paramdata "
                    f"{shlex.quote(str(BOOKS / (book + '.md')))} --name {shlex.quote(name)} --case 1"
                    f" | {shlex.quote(sys.executable)} {shlex.quote(str(NBVERIFY))} try solution.pyk")
            piped = subprocess.run(pipe, shell=True, cwd=directory, capture_output=True, text=True,
                                   env=env, timeout=TIMEOUT)
            status, out, err = nbverify(["try", "solution.pyk"], texts[(book, name)][0],
                                        cwd=directory, env=env)
            checks.check(piped.returncode == status and piped.stdout == out and out.startswith("{"),
                         f"{book} {name}: paramdata --case 1 | try {solutions[0]}",
                         f"piped {piped.returncode} {piped.stdout.strip()} {piped.stderr.strip()}; "
                         f"from the file {status} {out.strip()} {err.strip()}")
    return checks


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


def check_solutions(compiler, update, items, texts, only=None):
    """Every solution graded, and held to its notebook's <book>.toml;
    every item with a solution accepted and one refused.
    [String] -> Bool -> {..} -> {..} -> [String]? -> (Checks, Int, {String: (String, String)})"""
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
        tried = dict(zip(targets, pool.map(
            lambda f: grade_try(texts[targets[f]], SOLUTIONS / f, env), targets)))
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
    for file, (accepted, reason) in tried.items():
        checks.check((accepted, reason) == verdicts[file],
                     f"{file}: paramdata --case N | try, on every test, says the same",
                     f"try says {'accepted' if accepted else 'refused: ' + reason}; "
                     f"the autograder's way {verdicts[file]}")
    for path in sorted(changed):
        write_cases(path, {f: c for f, c in cases.items() if sources[f] == path})
        print(f"nbverify: {path.name} rewritten; read the diff before keeping it")
    for book, name in items:
        mine = [f for f, item in targets.items() if item == (book, name) and f in cases]
        checks.check(any(cases[f]["accepted"] for f in mine) and any(not cases[f]["accepted"] for f in mine),
                     f"{book} {name}: a solution accepted and one refused",
                     f"{len(mine)} solution{'' if len(mine) == 1 else 's'}")
    return checks, len(verdicts), targets


def check_schema(items):
    """paramschema is TOML the autograder reads -- a type and a default
    of that type per param -- and every test's params follow it.
    {..} -> Checks"""
    checks = Checks()
    status, out, err = nbverify(["paramschema"])
    if not checks.check(status == 0, "paramschema", err):
        return checks
    schema = tomllib.loads(out)["test"]["options"]["verifier_param_schema"]
    kinds = {"int": int, "bool": bool, "string": str}
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
                       (json.dumps(dict(accepted, params={"kind": "essay"})), "params.kind is task or quiz")]:
        status, out, _ = nbverify([], data)
        checks.check(status == 2 and said in json.loads(out)["reason"], f"refuses input: {said}", out)
    with tempfile.TemporaryDirectory(prefix="pyk-nbverify-") as directory:
        two = Path(directory) / "two.md"
        two.write_text("```pyking task name = \"a\"\nprint(1)\n```\n\n```stdout\n1\n```\n\n"
                       "Text.\n\n```quiz\n* x\n\n* y\n```\n\n```answer\n-> r\n- w\n```\n")
        one = Path(directory) / "one.md"
        one.write_text("```pyking task\nprint(1)\n```\n\n```stdin\n1\n```\n\n```stdout\n1\n```\n\n"
                       "```stdin\n2\n```\n\n```stdout\n1\n```\n")
        status, out, _ = nbverify(["paramdata", str(two), "--name", "quiz-1"], env=env)
        checks.check(status == 0 and "verifier_params.kind = \"quiz\"" in out,
                     "an unnamed item is called quiz-N, counting quizzes", out[-200:])
        status, out, _ = nbverify(["paramdata", str(one), "--name", "default", "--case", "2"], env=env)
        checks.check(status == 0 and "test 2 of 2" in out and 'stdin = "2\\n"' in out,
                     "--case N prints that test", out[:300])
        refusals = [
            (["paramdata", str(two)], "has 2 tasks and quizzes (a, quiz-1): give --name"),
            (["paramdata", str(two), "--name", "b"], "no task or quiz named 'b'"),
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
        test = ('[test.options]\nargs = ["run", "solution.pyk"]\nstdin = ""\n'
                'verifier_params.kind = "quiz"\nverifier_params.quiz_alternatives = 2\n'
                'verifier_params.quiz_right = "[2]"\n')
        answer = Path(directory) / "answer.pyk"
        answer.write_text("print([2])\n")
        status, out, err = nbverify(["try", str(answer)], test, env=env)
        checks.check(status == 0 and json.loads(out or "{}") == {"accepted": True, "reason": None},
                     "try verifies a run on the test on stdin, with status 0", out + err)
        status, out, err = nbverify(["try", str(answer)], test.replace('"[2]"', '"[1]"'), env=env)
        checks.check(status == 1 and json.loads(out or "{}").get("accepted") is False,
                     "try refuses a wrong answer with status 1", out + err)
        status, out, err = nbverify(["try", str(answer)], test.replace('"[2]"', '[2]'), env=env)
        checks.check(status == 0, "try also reads a list param written as a list", out + err)
        for data, args, said in [
            (test, ["try"], "give the program to run"),
            (test, ["try", "--events", "x", str(answer)], "unknown option --events"),
            (test, ["try", str(Path(directory) / "missing.pyk")], "no such program"),
            (test, ["try", str(answer), "--", "a"], "come from the test"),
            ("x = 1\n", ["try", str(answer)], "holds no [test.options]"),
            ("[test.options\n", ["try", str(answer)], "line 1: a table's name ends with ]"),
            ('[test.options]\nstdin = "a\n', ["try", str(answer)], "line 2: a string is not closed"),
            ('[test.options]\nstdin = 1 2\n', ["try", str(answer)], "line 2: the line goes on"),
            ('[test.options]\nstdin = ""\nstdin = ""\n', ["try", str(answer)], "given twice"),
            (test.replace('["run", "solution.pyk"]', '["x"]'), ["try", str(answer)], "not a run command"),
            (test.replace('verifier_params.quiz_right = "[2]"', 'verifier_params.quiz_right = "[2"'),
             ["try", str(answer)], "params.quiz_right is not a JSON list"),
        ]:
            status, out, err = nbverify(args, data, env=env)
            checks.check(status == 2 and said in err,
                         f"try refuses: {said}", (out + err).strip())
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
    items, texts, made = book_items(compiler, only)
    graded, count, targets = check_solutions(compiler, update, items, texts, only)
    for checks in (made, graded, check_try(compiler, items, texts, targets),
                   check_schema(items), check_command_line(compiler)):
        passed += checks.passed
        failures += checks.failures
    if failures:
        print()
    for failure in failures:
        print(f"nbverify: FAILED {failure}")
    tests = sum(len(t) for t in items.values())
    print(f"nbverify: {len(items)} tasks and quizzes, {tests} tests, {count} solutions.")
    suite.footer("nbverify", passed, len(failures), f"{count} solutions")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
