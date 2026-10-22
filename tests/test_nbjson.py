#!/usr/bin/env python3
"""The nbjson suite: notebooks as JSON, as `pyk notebook --to-json`,
`--to-markdown` and `--json-schema` write them, and as `pyk notebook`
serves and tests them.

For every notebook in tests/nbjson/: it is turned into JSON, the JSON
is checked against the schema `--json-schema` writes, and it is turned
back into Markdown, which must be the notebook again byte for byte; and
test mode must pass on the notebook and say the same of its JSON. Then
the schema itself (a Draft 2020-12 schema, checked with python's
`jsonschema`, which must be installed, and with the small validator
here), short documents written the uncommon ways a block can be written,
the command line's defaults and refusals, the help, and a notebook's
JSON served by `pyk notebook`.

Usage: python3 tests/test_nbjson.py [--compiler CMD] [--only BOOK,...]

`--only` checks the notebooks named (by stem), and the rest of the
suite as always.

Functions:
    validate(schema, value) -- what is wrong with a value, by a schema.
    check_notebook(compiler, path) -- one notebook's round trip and test mode.
    check_edges(compiler) -- short documents written the uncommon ways.
    check_command_line(compiler) -- defaults, refusals and the help.
    check_serving(compiler) -- a notebook's JSON served as its Markdown.
    main(argv) -- the command-line entry point.
"""

import concurrent.futures
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import suite  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "tests" / "nbjson"
DEFAULT_COMPILER = str(REPO / "pyk")
TIMEOUT = 600


# --- a JSON Schema validator, for the keywords the notebook schema uses ---

def _type_ok(kind, value):
    if kind == "object":
        return isinstance(value, dict)
    if kind == "array":
        return isinstance(value, list)
    if kind == "string":
        return isinstance(value, str)
    if kind == "boolean":
        return isinstance(value, bool)
    if kind == "null":
        return value is None
    if kind == "integer":
        return (isinstance(value, int) and not isinstance(value, bool)) or (
            isinstance(value, float) and value.is_integer())
    if kind == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return False


def validate(schema, value, root=None, path="$"):
    """What is wrong with a value by a schema: type, const, enum,
    properties, required, additionalProperties, minProperties, items,
    oneOf, $ref to #/$defs, minimum and pattern. A keyword it does not
    know is a problem too, so the schema cannot outgrow this check.
    {..} -> Any -> [String]"""
    root = root or schema
    known = {"$schema", "$id", "title", "description", "type", "const", "enum", "properties",
             "required", "additionalProperties", "minProperties", "items", "oneOf", "$ref",
             "$defs", "minimum", "pattern"}
    problems = [f"{path}: the schema uses {k}, which this check does not know"
                for k in schema if k not in known]
    if "$ref" in schema:
        name = schema["$ref"].removeprefix("#/$defs/")
        return problems + validate(root["$defs"][name], value, root, path)
    if "type" in schema:
        kinds = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_type_ok(k, value) for k in kinds):
            return problems + [f"{path}: {json.dumps(value)[:60]} is not {' or '.join(kinds)}"]
    if "const" in schema and value != schema["const"]:
        problems.append(f"{path}: is not {json.dumps(schema['const'])}")
    if "enum" in schema and value not in schema["enum"]:
        problems.append(f"{path}: {json.dumps(value)[:60]} is not one of {schema['enum']}")
    if "minimum" in schema and _type_ok("number", value) and value < schema["minimum"]:
        problems.append(f"{path}: {value} is less than {schema['minimum']}")
    if "pattern" in schema and isinstance(value, str) and not re.search(schema["pattern"], value):
        problems.append(f"{path}: {value!r} does not match {schema['pattern']}")
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        for name in schema.get("required", []):
            if name not in value:
                problems.append(f"{path}: has no {name}")
        if len(value) < schema.get("minProperties", 0):
            problems.append(f"{path}: has fewer than {schema['minProperties']} fields")
        for name, item in value.items():
            if name in properties:
                problems += validate(properties[name], item, root, f"{path}.{name}")
            elif schema.get("additionalProperties") is False:
                problems.append(f"{path}: has {name}, which it may not")
            elif isinstance(schema.get("additionalProperties"), dict):
                problems += validate(schema["additionalProperties"], item, root, f"{path}.{name}")
    if isinstance(value, list) and "items" in schema:
        for k, item in enumerate(value):
            problems += validate(schema["items"], item, root, f"{path}[{k}]")
    if "oneOf" in schema:
        fits = [validate(s, value, root, path) for s in schema["oneOf"]]
        good = sum(1 for f in fits if not f)
        if good != 1:
            best = min(fits, key=len)
            problems.append(f"{path}: fits {good} of oneOf's schemas, not one"
                            + (f" ({best[0]})" if best else ""))
    return problems


# --- running pyk -------------------------------------------------------------

def run(compiler, args, cwd=None, data=None):
    """One run of pyk: (status, stdout, stderr). [String] -> [String] -> ..."""
    ran = subprocess.run(compiler + args, cwd=cwd, capture_output=True, text=True,
                         input=data, timeout=TIMEOUT)
    return ran.returncode, ran.stdout, ran.stderr


class Checks:
    """Checks made, the failures among them, and each one's line."""

    def __init__(self):
        self.passed, self.failures, self.lines = 0, [], []

    def check(self, ok, label, detail=""):
        if ok:
            self.passed += 1
        else:
            self.failures.append(label + (f": {detail}" if detail else ""))
        self.lines.append(suite.case_line("nbjson", ok, label, detail))
        return ok

    def merge(self, other):
        self.passed += other.passed
        self.failures += other.failures
        self.lines += other.lines


def jsonschema_validator(schema_text):
    """A Draft 2020-12 validator from the `jsonschema` package, or None
    where it is not installed. String -> Validator?"""
    try:
        import jsonschema  # noqa: PLC0415
    except ImportError:
        return None
    schema = json.loads(schema_text)
    jsonschema.Draft202012Validator.check_schema(schema)
    return jsonschema.Draft202012Validator(schema)


def check_notebook(compiler, path, schema, standard):
    """One notebook: to JSON, valid by the schema, back to the same
    Markdown; and test mode passing on both, saying the same.
    [String] -> Path -> {..} -> Validator? -> Checks"""
    checks = Checks()
    name = path.name
    with tempfile.TemporaryDirectory(prefix="pyk-nbjson-") as directory:
        json_path = Path(directory) / (path.stem + ".json")
        md_path = Path(directory) / (path.stem + ".md")
        status, _, err = run(compiler, ["notebook", str(path), "--to-json", "-o", str(json_path)])
        if not checks.check(status == 0, f"{name}: --to-json", err.strip()):
            return checks
        try:
            value = json.loads(json_path.read_text())
        except json.JSONDecodeError as error:
            checks.check(False, f"{name}: --to-json writes JSON", str(error))
            return checks
        problems = validate(schema, value)
        checks.check(not problems, f"{name}: the JSON is valid by the schema", "; ".join(problems[:3]))
        if standard is not None:
            errors = list(standard.iter_errors(value))
            checks.check(not errors, f"{name}: the JSON is valid by jsonschema",
                         errors[0].message[:200] if errors else "")
        status, _, err = run(compiler, ["notebook", str(json_path), "--to-markdown", "-o", str(md_path)])
        if checks.check(status == 0, f"{name}: --to-markdown", err.strip()):
            same = md_path.read_bytes() == path.read_bytes()
            checks.check(same, f"{name}: back to Markdown, byte for byte", first_difference(
                path.read_text(), md_path.read_text()))
        md_status, md_out, md_err = run(compiler, ["notebook", "--mode", "test", str(path)], cwd=REPO)
        checks.check(md_status == 0, f"{name}: test mode passes", (md_out + md_err).strip()[-600:])
        json_status, json_out, json_err = run(
            compiler, ["notebook", "--mode", "test", str(json_path)], cwd=directory)
        said = (md_out + md_err).replace(str(path.relative_to(REPO)), "NOTEBOOK")
        said_json = (json_out + json_err).replace(str(json_path), "NOTEBOOK")
        checks.check(json_status == md_status and said == said_json,
                     f"{name}: test mode says the same of its JSON",
                     first_difference(said, said_json))
    return checks


def first_difference(a, b):
    """Where two texts first differ, for a failure's detail. String -> String -> String"""
    for k, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return f"at character {k}: {a[max(0, k - 30):k + 30]!r} / {b[max(0, k - 30):k + 30]!r}"
    if len(a) != len(b):
        return f"one is {abs(len(a) - len(b))} characters longer"
    return ""


#: Documents written the uncommon ways: each must come back exactly.
EDGES = {
    "empty": "",
    "only text": "# A title\n\nSome text.\n",
    "no final newline": "Text.\n\n```pyking\nprint(1)\n```",
    "unclosed": "Text.\n\n```pyking\nprint(1)\n",
    "unclosed, no newline": "```stdout\n1",
    "crlf": "Text.\r\n\r\n```pyking exercise points = 1\r\nprint(1)\r\n```\r\n\r\n```stdout\r\n1\r\n```\r\n",
    "tight headers": "```pyking exercise name=\"x\" points=10 stdin=\"3\" method=inline\nprint(1)\n```\n",
    "attributes out of order": "```pyking points = 2 exercise\nprint(1)\n```\n```stdout\n1\n```\n",
    "braces": "```{.pyking .norun}\ndef f(): ...\n```\n",
    "pyk and capitals": "```pyk ReadOnly\nprint(1)\n```\n",
    "tilde fence": "~~~pyking\nprint(1)\n~~~\n",
    "long fence": "````pyking\nprint(\"```\")\n````\n",
    "long close": "```pyking\nprint(1)\n`````\n",
    "a fence in the body": "````stdout\n```\n````\n",
    "no blank line between": "```pyking exercise\nprint(1)\n```\n```stdout\n1\n```\n",
    "two blank lines between": "```pyking exercise\nprint(1)\n```\n\n\n```stdout\n1\n```\n",
    "spaces in the gap": "```pyking exercise\nprint(1)\n```\n  \n```stdout\n1\n```\n",
    "front matter": "---\ntitle: T\nnote: ```pyking\n---\n\n```pyking\nprint(1)\n```\n",
    "html": "<div>\n```pyking\nprint(1)\n```\n</div>\n\n```pyking\nprint(2)\n```\n",
    "comment": "<!--\n```pyking\nprint(1)\n```\n-->\n",
    "math": "$$\n```pyking\n$$\n",
    "in a list": "- item\n\n  ```pyking\n  print(1)\n  ```\n",
    "other languages": "```python\n```pyking\n```\n\n```\nplain\n```\n",
    "a quiz written loosely": "```quiz\nWhich?\n*   One\n  more\n*Two\n* Three\n```\n```answer\n->  Right\n  still\n-\n```\n",
    "an answer with stray text": "```quiz\n* A\n```\n```answer\nhello\n-> A\n```\n",
    "stray blocks": "```answer\n- x\n```\n\n```stdout\n1\n```\n\n```pyking solution\nprint(1)\n```\n",
    "out of order": "```pyking exercise\nprint(1)\n```\n```pyking solution\nprint(1)\n```\n```diff-allowed\nx [+/-1]\n```\n"
                    "```stdin\n1\n```\n```stderr\nd\n```\n```stdout\n1\n```\n```events\nclick \"a\"\n```\n",
    "cell examples": "```pyking\nprint(1)\n```\n```stdin\nx\n```\n```events\nclick \"b\"\n```\n```stdout\n1\n```\n",
    "input before a cell": "```stdin\nAda\n```\n```args\na b\n```\n```pyking\nprint(1)\n```\n",
    "odd values": "```pyking exercise points = 1.50 attempts = abc penalty = -1 stdin = 'it''s' args = \"a\\\"b\"\n```\n",
}


def check_edges(compiler, schema):
    """Short documents written the uncommon ways, each back exactly, and
    edits to the JSON taking effect. [String] -> {..} -> Checks"""
    checks = Checks()
    with tempfile.TemporaryDirectory(prefix="pyk-nbjson-") as directory:
        for label, text in EDGES.items():
            md = Path(directory) / "edge.md"
            md.write_bytes(text.encode())
            js = Path(directory) / "edge.json"
            status, _, err = run(compiler, ["notebook", str(md), "--to-json", "-o", str(js)])
            if not checks.check(status == 0, f"edge {label}: --to-json", err.strip()):
                continue
            ran = subprocess.run(compiler + ["notebook", str(js), "--to-markdown", "-o", "-"],
                                 capture_output=True, timeout=TIMEOUT)
            back = ran.stdout.decode("utf-8", "replace")
            checks.check(ran.returncode == 0 and ran.stdout == text.encode(),
                         f"edge {label}: back exactly",
                         ran.stderr.decode().strip() or first_difference(text, back))
        # An attribute changed in the JSON is written, even where the
        # header was not written the canonical way.
        md = Path(directory) / "edit.md"
        md.write_text("```pyking exercise points=10 name=\"x\"\nprint(1)\n```\n```stdout\n1\n```\n")
        _, out, _ = run(compiler, ["notebook", str(md), "--to-json", "-o", "-"])
        value = json.loads(out)
        exercise = value["blocks"][0]
        checks.check(exercise["type"] == "exercise" and exercise["attributes"] == {"points": 10, "name": "x"}
                     and "info" in exercise, "an exercise's attributes, typed", json.dumps(exercise))
        exercise["attributes"]["points"] = 5
        exercise["tests"][0]["stdout"]["text"] = "2\n"
        js = Path(directory) / "edit.json"
        js.write_text(json.dumps(value))
        _, back, _ = run(compiler, ["notebook", str(js), "--to-markdown", "-o", "-"])
        checks.check(back == "```pyking exercise points = 5 name = \"x\"\nprint(1)\n```\n```stdout\n2\n```\n",
                     "an edited attribute is written in the canonical way", repr(back))
        quiz = {"format": "pyking-notebook", "version": 1, "blocks": [
            {"type": "markdown", "text": "Pick:\n\n"},
            {"type": "quiz", "attributes": {"name": "q", "points": 1}, "question": "",
             "alternatives": [{"marker": "*", "text": "A"}, {"marker": "*", "text": "B"}],
             "answer": {"entries": [{"correct": True, "text": "Yes."}, {"correct": False, "text": ""}]}}]}
        js.write_text(json.dumps(quiz))
        problems = validate(schema, quiz)
        checks.check(not problems, "a quiz written by hand is valid", "; ".join(problems))
        _, back, _ = run(compiler, ["notebook", str(js), "--to-markdown", "-o", "-"])
        checks.check(back == "Pick:\n\n```quiz name = \"q\" points = 1\n* A\n\n* B\n```\n\n```answer\n-> Yes.\n-\n```\n",
                     "a quiz written from its fields", repr(back))
        bad = {"format": "pyking-notebook", "version": 1, "blocks": [{"type": "nothing"}]}
        checks.check(validate(schema, bad) != [], "the schema refuses a block of no type it knows")
    return checks


def check_command_line(compiler):
    """Where each flag writes by default, -o, and what is refused; and
    that the flags are in the long help only. [String] -> Checks"""
    checks = Checks()
    with tempfile.TemporaryDirectory(prefix="pyk-nbjson-") as directory:
        book = Path(directory) / "book.md"
        book.write_text("# Book\n\n```pyking exercise name = \"e\"\nprint(1)\n```\n\n```stdout\n1\n```\n")
        status, _, err = run(compiler, ["notebook", str(book), "--to-json"], cwd=directory)
        checks.check(status == 0 and (Path(directory) / "book.json").exists(),
                     "--to-json writes book.json beside book.md", err)
        status, _, err = run(compiler, ["notebook", "book.md", "--to-json"], cwd=directory)
        checks.check(status == 1 and "is there already" in err, "--to-json does not write over book.json", err)
        status, _, err = run(compiler, ["notebook", "book.json", "--to-markdown"], cwd=directory)
        checks.check(status == 1 and "book.md is there already" in err,
                     "--to-markdown does not write over book.md", err)
        status, _, err = run(compiler, ["notebook", "book.json", "--to-markdown", "-o", "copy.md"], cwd=directory)
        checks.check(status == 0 and (Path(directory) / "copy.md").read_text() == book.read_text(),
                     "--to-markdown -o names the file", err)
        status, _, err = run(compiler, ["notebook", "book.json", "--to-markdown", "-o", "book.md"], cwd=directory)
        checks.check(status == 0, "-o may name a file that is there", err)
        status, _, err = run(compiler, ["notebook", "--json-schema"], cwd=directory)
        schema_file = Path(directory) / "notebook.schema.json"
        checks.check(status == 0 and schema_file.exists(), "--json-schema writes notebook.schema.json", err)
        _, printed, _ = run(compiler, ["notebook", "--json-schema", "-o", "-"], cwd=directory)
        checks.check(printed == schema_file.read_text(), "--json-schema -o - prints it")
        status, _, err = run(compiler, ["notebook", "--json-schema", "-o", "s.json"], cwd=directory)
        checks.check(status == 0 and (Path(directory) / "s.json").exists(), "--json-schema -o names the file", err)
        (Path(directory) / "broken.json").write_text("{not json")
        (Path(directory) / "other.json").write_text('{"format": "something"}')
        (Path(directory) / "typo.json").write_text(
            '{"format": "pyking-notebook", "version": 1, "blocks": [{"type": "cell"}]}')
        refusals = [
            (["notebook", "book.json", "--to-json"], "is not a Markdown notebook"),
            (["notebook", "book.md", "--to-markdown"], "is not a notebook's JSON"),
            (["notebook", "book.md", "--to-json", "--to-markdown"], "only one may be given"),
            (["notebook", "book.md", "--to-json", "--mode", "teacher"], "takes no --mode or --port"),
            (["notebook", "book.md", "--to-json", "--port", "8123"], "takes no --mode or --port"),
            (["notebook", "book.md", "--json-schema"], "takes no notebook"),
            (["notebook", "book.md", "-o", "x"], "--output names what --to-json"),
            (["compile", "book.md", "--to-json"], "only applies to 'pyk notebook'"),
            (["notebook", "missing.md", "--to-json"], "no such file"),
            (["notebook", "broken.json", "--to-markdown", "-o", "-"], "is not JSON"),
            (["notebook", "other.json", "--to-markdown", "-o", "-"], "is not a notebook"),
            (["notebook", "typo.json", "--to-markdown", "-o", "-"], "blocks[0] has no code"),
            (["notebook", "broken.json", "--mode", "test"], "is not JSON"),
        ]
        for args, said in refusals:
            status, _, err = run(compiler, args, cwd=directory)
            checks.check(status != 0 and said in " ".join(err.split()),
                         f"refuses pyk {' '.join(args)}", err.strip()[:200])
    _, short, short_err = run(compiler, [])
    _, full, _ = run(compiler, ["--help"])
    for flag in ("--to-json", "--to-markdown", "--json-schema"):
        checks.check(flag in full, f"pyk --help lists {flag}")
        checks.check(flag not in short + short_err, f"pyk alone does not list {flag}")
    return checks


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def check_serving(compiler):
    """`pyk notebook book.json` serves the Markdown it stands for, and
    tells the page so. [String] -> Checks"""
    checks = Checks()
    with tempfile.TemporaryDirectory(prefix="pyk-nbjson-") as directory:
        book = Path(directory) / "book.md"
        book.write_text((FIXTURES / sorted(os.listdir(FIXTURES))[0]).read_text()
                        if FIXTURES.exists() and os.listdir(FIXTURES) else "# Book\n")
        run(compiler, ["notebook", str(book), "--to-json"])
        port = free_port()
        env = dict(os.environ, PYKING_WEB_NO_VENDOR="1")
        process = subprocess.Popen(compiler + ["notebook", "--port", str(port), str(Path(directory) / "book.json")],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
        try:
            base = f"http://127.0.0.1:{port}"
            config = None
            for _ in range(100):
                try:
                    config = json.loads(urllib.request.urlopen(base + "/notebook.json", timeout=5).read())
                    break
                except OSError:
                    time.sleep(0.1)
            checks.check(config is not None and config.get("document") == "book.md",
                         "the page is told the document is book.md", json.dumps(config))
            if config:
                served = urllib.request.urlopen(base + "/doc/book.md", timeout=5).read().decode()
                checks.check(served == book.read_text(), "doc/book.md is the Markdown the JSON stands for",
                             first_difference(book.read_text(), served))
                value = json.loads((Path(directory) / "book.json").read_text())
                value["blocks"].insert(0, {"type": "markdown", "text": "Changed.\n\n"})
                (Path(directory) / "book.json").write_text(json.dumps(value))
                served = urllib.request.urlopen(base + "/doc/book.md", timeout=5).read().decode()
                checks.check(served.startswith("Changed.\n\n"), "and what it is now, once it changes", served[:40])
        finally:
            process.terminate()
            process.wait(timeout=10)
    return checks


def main(argv):
    """The command-line entry point. [String] -> Int"""
    compiler, only, rest = [DEFAULT_COMPILER], None, list(argv)
    while rest:
        flag = rest.pop(0)
        if flag == "--compiler" and rest:
            compiler = shlex.split(rest.pop(0))
        elif flag == "--only" and rest:
            only = [b for b in rest.pop(0).split(",") if b]
        else:
            print("usage: test_nbjson.py [--compiler CMD] [--only BOOK,...]", file=sys.stderr)
            return 2
    total = Checks()
    status, schema_text, err = run(compiler, ["notebook", "--json-schema", "-o", "-"])
    if not total.check(status == 0, "--json-schema", err):
        schema_text = "{}"
    schema = json.loads(schema_text)
    total.check(schema.get("$schema") == "https://json-schema.org/draft/2020-12/schema",
                "the schema is a Draft 2020-12 schema")
    total.check(not validate(schema, {"format": "pyking-notebook", "version": 1, "blocks": []}),
                "an empty notebook is valid", "; ".join(validate(schema, {"format": "pyking-notebook", "version": 1, "blocks": []})))
    try:
        standard = jsonschema_validator(schema_text)
        total.check(standard is not None, "python's jsonschema is installed",
                    "it checks every notebook's JSON against the schema; install it with "
                    "`python3 -m pip install --user jsonschema` (Debian and Ubuntu: "
                    "`sudo apt install python3-jsonschema`)")
        if standard is not None:
            total.check(True, "jsonschema accepts the schema")
    except Exception as error:  # noqa: BLE001
        standard = None
        total.check(False, "jsonschema accepts the schema", str(error))
    notebooks = sorted(FIXTURES.glob("*.md"))
    total.check(len(notebooks) >= 30, "tests/nbjson holds at least 30 notebooks", str(len(notebooks)))
    if only:
        notebooks = [p for p in notebooks if p.stem in only]
    jobs = max(1, len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count() or 1)
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(check_notebook, compiler, path, schema, standard) for path in notebooks]
        futures.append(pool.submit(check_edges, compiler, schema))
        futures.append(pool.submit(check_command_line, compiler))
        futures.append(pool.submit(check_serving, compiler))
        for future in futures:
            total.merge(future.result())
    for line in total.lines:
        print(line)
    if total.failures:
        print()
    for failure in total.failures:
        print(f"nbjson: FAILED {failure}")
    print(f"nbjson: {len(notebooks)} notebooks, {len(EDGES)} short documents, the command line and serving.")
    suite.footer("nbjson", total.passed, len(total.failures), f"{len(notebooks)} notebooks")
    return 1 if total.failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
