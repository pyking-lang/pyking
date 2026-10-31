#!/usr/bin/env python3
"""nbverify: grades a Pyking notebook's tasks and quizzes for the
ID2202 autograder, as its `run_verifier` tests run a verifier -- the
answer's run arrives as JSON on standard input, and whether it is
accepted goes out as JSON on standard output. What a test is checked
against is all in its `params`: the expected output, the tinyweb log,
the diff-allowed, optional-last, any-order and ignore-chars rules, a
quiz's right
answers. Nothing else is read.

The same file makes those params and runs the answer:

    nbverify.py                      verify one run (JSON on stdin)
    nbverify.py paramschema          the [test.options.verifier_param_schema]
    nbverify.py paramdata BOOK [--name NAME] [--case N | --output-dir DIR]
                [--program FILE] [--pyk PYK]
                                     each test's [test.options]
    nbverify.py run [--pyk PYK] [--events TEXT] [--until N --until-match P...]
                FILE [-- ARGS]       run an answer the way a test does
    nbverify.py try [--pyk PYK] [-L DIR] [--json] FILE
                                     run and verify an answer on one test
                                     (its [test.options] on stdin)
    nbverify.py --help | --version

It needs nothing but Python 3.8 and, for `paramdata`, `run` and `try`,
pyk.
See tools/nbverify/README.md.

Data structures:
    VERSION -- the Pyking version this file belongs to, written by make.
    PARAMS -- every verifier parameter: its name, type and default.
    LISTS -- the parameters holding a list, written as JSON in a string.
    Case -- one test case of an item: its input and what it should do.

Functions:
    verify(data) -- the verdict on one run.
    verify_task(params, run) -- the verdict on a task's run.
    call_count(source, name) -- how often a program names a function.
    over_calls(source, limits) -- the first max_calls limit a program
        goes past.
    verify_quiz(params, run) -- the verdict on a quiz's answer.
    same_output(a, b, rules) -- whether two outputs count as the same.
    allowed_rules(text) -- a diff-allowed block's lines as rules.
    order_rules(last, order) -- optional-last and any-order lines as rules.
    chars_rules(pairs) -- ignore-chars lines as rules.
    task_rules(params) -- every rule a task's params hold.
    clean_line(rules, line) -- a line without the characters ignore-chars removes.
    split_arguments(text) -- arguments as the notebook splits them.
    run_program(pyk, path, stdin, args, events) -- one run of a program.
    launch(argv) -- `run`: a program run, its trailer on stderr.
    read_toml(text) -- the TOML paramdata writes, read.
    attempt(argv) -- `try`: one test's run of a program, verified.
    items(notebook) -- a notebook's tasks and quizzes, named.
    cases(item, pyk) -- what each test of an item should do.
    paramdata(argv) -- `paramdata`.
    paramschema() -- `paramschema`.
    main(argv) -- the command-line entry point.
"""

import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# BEGIN version (written by make from VERSION; do not edit)
VERSION = "0.1.8-dev"
# END version

USAGE = """\
Usage: nbverify.py                    verify one run: JSON on standard input
       nbverify.py paramschema        print the verifier_param_schema
       nbverify.py paramdata BOOK [--name NAME] [--case N | --output-dir DIR]
                   [--program FILE] [--pyk PYK]
                                      print or write each test's [test.options]
       nbverify.py run [--pyk PYK] [--events TEXT] [--until N --until-match P...]
                   [-L DIR] FILE [-- ARGS]
                                      run an answer as a test runs it;
                                      --until stops it once tinyweb's log
                                      has had N lines a --until-match
                                      pattern matches (compare-until)
       nbverify.py try [--pyk PYK] [-L DIR] [--json] FILE
                                      run an answer on the test whose
                                      [test.options] is on standard input,
                                      and verify it; --json prints the run
                                      for the verifier instead
       nbverify.py --help | --version

With no argument, nbverify reads one run of an answer as the ID2202
autograder's run_verifier hands it over -- {"cmd", "code", "stdout",
"stderr", "files", "params"} -- and prints {"accepted": true, "reason":
null} with status 0, or {"accepted": false, "reason": "..."} with status 1:
the reason a student would be given in the notebook. "params" says what
is checked, and is what `paramdata` writes for each test of a task
or a quiz, from the notebook (.json, or .md through `pyk notebook
--to-json`). The solution is run there, with pyk, for what it prints;
--pyk names pyk, else $PYK, else pyk on the PATH.

`paramschema` prints the schema the params follow, for the autograder's
config.toml. `run` is the test's command: it runs FILE with pyk, tinyweb
logging what it draws and the events delivered, and adds what nbverify
needs to standard error after a line `--- nbverify run ---`.

`try` is a test without the autograder: it reads one test file's TOML,
as `paramdata --case N` prints it, on standard input, runs FILE with
`run` on that test's input, events and arguments, and verifies the run
with the test's params, printing the verdict as the verifier does:

    nbverify.py paramdata BOOK --name NAME --case 1 | nbverify.py try FILE

With --json it verifies nothing and prints the run instead, the JSON
nbverify.py with no argument reads.

BOOK's items are named by their name = attribute; one item with no name
is `default`, and an unnamed one may be called task-N, practice-N or
quiz-N.
See tools/nbverify/README.md."""

#: How long `paramdata` lets a solution run, in seconds.
SOLUTION_TIMEOUT = 60

#: The line after which `run` writes its trailer on standard error.
TRAILER = "--- nbverify run ---\n"

#: Every verifier parameter: name, type, default, and what it says.
PARAMS = [
    ("kind", "string", "task", "task or quiz; a practice is graded as a task"),
    ("name", "string", "", "the item's name, for the reasons"),
    ("compare_stdout", "bool", False, "standard output is compared"),
    ("expected_stdout", "string", "", "what it should print"),
    ("compare_stderr", "bool", False, "what debug writes is compared"),
    ("expected_stderr", "string", "", "what debug should write"),
    ("compare_tinyweb", "bool", False, "tinyweb's log is compared"),
    ("expected_tinyweb", "string", "", "the tinyweb log it should write"),
    ("compare_code", "bool", False, "the exit status is compared"),
    ("expected_code", "int", 0, "the exit status it should end with"),
    ("diff_allowed", "list", [], "diff-allowed lines, with the solution"),
    ("optional_last", "list", [], "optional-last lines, with the solution"),
    ("any_order", "list", [], "any-order lines, with the solution"),
    ("ignore_chars", "list", [], "[chars, pattern] pairs of ignore-chars lines, with the solution"),
    ("max_calls", "list", [], "[N, name] pairs: name written at most N times"),
    ("details", "bool", False, "the reason shows the test and both outputs"),
    ("test_stdin", "string", "", "the test's standard input, for details"),
    ("test_args", "list", [], "the test's arguments, for details"),
    ("test_events", "string", "", "the test's tinyweb events, for details"),
    ("quiz_alternatives", "int", 0, "how many alternatives the quiz has"),
    ("quiz_multiple", "bool", False, "any number may be chosen ([])"),
    ("quiz_right", "list", [], "the right alternatives, from 1"),
    ("quiz_explanations", "list", [], "each alternative's explanation"),
]

DEFAULTS = {name: default for name, _, default, _ in PARAMS}

#: The parameters holding a list: TOML gets each as a string of JSON.
LISTS = {name for name, kind, _, _ in PARAMS if kind == "list"}

#: A pyk error report: the file, its span, and the kind of error.
PYK_ERROR = re.compile(
    r"'[^'\n]*'\s+\d+:\d+-\d+:\d+ (?:Lexing|Parsing|Module|Name|Type|Runtime) error:")


class Refusal(Exception):
    """A command that cannot be done, and why."""


# --- comparing output ----------------------------------------------------

def normalize_output(text):
    """Output as it is compared: each line without the spaces at its end,
    and no blank lines at the end. String -> String"""
    lines = [line.rstrip() for line in text.replace("\r", "").split("\n")]
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines)


NUMBER = r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"
SLOT = re.compile(r"\[\s*\+\s*/\s*-\s*([0-9]+(?:\.[0-9]+)?)\s*\]")


def allowed_rules(lines):
    """Diff-allowed lines as rules: a pattern with a number where each
    [+/-N] stands, and each slot's N. A line that is not a rule is left
    out. A rule is (kind, pattern, slots), the kind "number" here.
    [String] -> [(String, Pattern, [Float])]"""
    rules = []
    for text in lines:
        text = text.rstrip()
        if not text.strip():
            continue
        pattern, slots, rest, bad = "", [], text, False
        while True:
            found = SLOT.search(rest)
            literal = rest[:found.start()] if found else rest
            if "[" in literal or "]" in literal:
                bad = True
                break
            pattern += re.escape(literal)
            if not found:
                break
            pattern += "(" + NUMBER + ")"
            slots.append(float(found.group(1)))
            rest = rest[found.end():]
        if not bad and slots:
            rules.append(("number", re.compile(pattern), slots))
    return rules


def star_pattern(text):
    """A pattern written with * for any text, matching a whole line.
    String -> Pattern"""
    return re.compile(".*".join(re.escape(piece) for piece in text.split("*")), re.DOTALL)


ORDER_LINE = re.compile(r"\s*(BETWEEN|ANY):\s*(.*)")


def order_rules(last, order):
    """Optional-last lines, and any-order BETWEEN: and ANY: lines, as
    rules of the kinds "last", "between" and "any". A line that is not
    a rule is left out. [String] -> [String] -> [Rule]"""
    rules = [("last", star_pattern(text.strip()), []) for text in last if text.strip()]
    for text in order:
        found = ORDER_LINE.fullmatch(text.rstrip())
        if found and found.group(2).strip():
            kind = "any" if found.group(1) == "ANY" else "between"
            rules.append((kind, star_pattern(found.group(2).strip()), []))
    return rules


def chars_rules(pairs):
    """Ignore-chars lines, each [chars, pattern], as rules of the kind
    "chars", the slots the characters removed from a line the pattern
    matches. [[String, String]] -> [Rule]"""
    return [("chars", star_pattern(text.strip()), chars) for chars, text in pairs
            if chars and text.strip()]


def task_rules(params):
    """Every rule a task's params hold. {..} -> [Rule]"""
    return (allowed_rules(params["diff_allowed"])
            + order_rules(params["optional_last"], params["any_order"])
            + chars_rules(params["ignore_chars"]))


def allowed_line(rules, a, b):
    """Whether two lines differ only in numbers a rule allows to differ.
    [Rule] -> String -> String -> Bool"""
    for kind, pattern, slots in rules:
        if kind != "number":
            continue
        x = pattern.fullmatch(a)
        y = x and pattern.fullmatch(b)
        if not y:
            continue
        if all(abs(float(x.group(k + 1)) - float(y.group(k + 1))) <= tolerance + 1e-9
               for k, tolerance in enumerate(slots)):
            return True
    return False


def clean_line(rules, line):
    """A line without the characters the ignore-chars rules it matches
    remove, wherever they stand. [Rule] -> String -> String"""
    ignored = "".join(chars for kind, pattern, chars in rules
                      if kind == "chars" and pattern.fullmatch(line))
    return "".join(c for c in line if c not in ignored) if ignored else line


def same_output(a, b, rules=()):
    """Whether two outputs count as the same: line for line, but for what
    `rules` allow to differ. String -> String -> [Rule] -> Bool"""
    x, y = normalize_output(a), normalize_output(b)
    if x == y:
        return True
    if not rules:
        return False
    return compare_lines(rules, lines_of(x), lines_of(y))


def lines_of(text):
    """The lines of a normalized output, none where it is empty.
    String -> [String]"""
    return text.split("\n") if text else []


def matches(rules, kind, line):
    """Whether a rule of the kind matches the line. [Rule] -> String ->
    String -> Bool"""
    return any(k == kind and pattern.fullmatch(line) for k, pattern, _ in rules)


def kept(rules, lines):
    """The lines left once those an optional-last rule matches, and blank
    ones, are dropped from the end, or from right before the `splash`
    lines that end it, which tinyweb's inserted call writes after the
    program's own, as their indices. Each optional-last rule drops at
    most one line. [Rule] -> [String] -> [Int]"""
    unused = [pattern for kind, pattern, _ in rules if kind == "last"]

    def optional(k):
        if lines[k] == "":
            return True
        j = next((j for j, pattern in enumerate(unused) if pattern.fullmatch(lines[k])), None)
        if j is None:
            return False
        del unused[j]
        return True
    end = len(lines)
    while end and optional(end - 1):
        end -= 1
    tail = end
    while tail and lines[tail - 1] == "splash":
        tail -= 1
    n = tail
    while n and optional(n - 1):
        n -= 1
    return list(range(n)) + list(range(tail, end))


def stretches(rules, lines):
    """Lines cut at those a BETWEEN: rule matches: each stretch the line
    that starts it (None for the first), the lines no ANY: rule matches,
    and those one does. [Rule] -> [String] -> [(String?, [String], [String])]"""
    out = [(None, [], [])]
    for line in lines:
        if matches(rules, "between", line):
            out.append((line, [], []))
        else:
            out[-1][2 if matches(rules, "any", line) else 1].append(line)
    return out


def compare_lines(rules, x, y):
    """Whether two outputs' lines are the same as the rules say, as the
    notebook's tasks.js compares them: each line first without the
    characters an ignore-chars rule it matches removes, which the other
    rules see; optional-last lines dropped from
    the end of each, or from right before its closing `splash` lines; then, where there are ANY: rules, the stretches
    compared in turn -- the lines that start them and those no ANY: rule
    matches line for line, the rest as a bag; otherwise line for line.
    [Rule] -> [String] -> [String] -> Bool"""
    def same(p, q):
        return p == q or allowed_line(rules, p, q)
    x = [clean_line(rules, line) for line in x]
    y = [clean_line(rules, line) for line in y]
    left = [x[i] for i in kept(rules, x)]
    right = [y[i] for i in kept(rules, y)]
    if not any(kind == "any" for kind, _, _ in rules):
        return len(left) == len(right) and all(same(p, q) for p, q in zip(left, right))
    s, t = stretches(rules, left), stretches(rules, right)
    if len(s) != len(t):
        return False
    for (cut, fixed, free), (cut2, fixed2, free2) in zip(s, t):
        if (cut is None) != (cut2 is None) or (cut is not None and not same(cut, cut2)):
            return False
        if len(fixed) != len(fixed2) or not all(same(p, q) for p, q in zip(fixed, fixed2)):
            return False
        unused = list(free2)
        for line in free:
            j = next((j for j, other in enumerate(unused) if same(line, other)), None)
            if j is None:
                return False
            del unused[j]
        if unused:
            return False
    return True


def canonical(rules, text):
    """An output's lines in the order the rules make them comparable,
    each as (the line ignore-chars has cleaned, the line as written):
    optional-last lines dropped from the end, and in each stretch the
    lines an ANY: rule matches sorted among the places they hold, the
    others where they are. String -> [(String, String)]"""
    written = lines_of(normalize_output(text))
    clean = [clean_line(rules, line) for line in written]
    pairs = [(clean[i], written[i]) for i in kept(rules, clean)]
    if not any(kind == "any" for kind, _, _ in rules):
        return pairs
    out, stretch = [], []

    def flush():
        free = iter(sorted(p for p in stretch if matches(rules, "any", p[0])))
        out.extend(next(free) if matches(rules, "any", p[0]) else p for p in stretch)
        stretch.clear()
    for p in pairs:
        if matches(rules, "between", p[0]):
            flush()
            out.append(p)
        else:
            stretch.append(p)
    flush()
    return out


def split_arguments(text):
    """Arguments as the notebook splits a line of them: at blanks, with
    quotes keeping a blank inside one. String -> [String]"""
    out, current, quote, i = [], None, None, 0
    while i < len(text):
        c = text[i]
        if quote:
            if c == quote:
                quote = None
            elif c == "\\" and quote == '"' and i + 1 < len(text):
                i += 1
                current += text[i]
            else:
                current += c
        elif c in "'\"":
            quote = c
            current = current or ""
        elif c == "\\" and i + 1 < len(text):
            i += 1
            current = (current or "") + text[i]
        elif c.isspace():
            if current is not None:
                out.append(current)
            current = None
        else:
            current = (current or "") + c
        i += 1
    if current is not None:
        out.append(current)
    return out


# --- verifying -------------------------------------------------------------

def decoded(stream):
    """A stream of the autograder's input as text. {enc, data} -> String"""
    if isinstance(stream, str):
        return stream
    if not isinstance(stream, dict):
        return ""
    data = stream.get("data") or ""
    if stream.get("enc") == "base64":
        return base64.b64decode(data).decode("utf-8", "replace")
    return data


def answer_run(data):
    """What a run of an answer did: its output, what debug wrote, the
    tinyweb log, its status, whether it ran at all and its source -- read
    from the trailer `run` adds to standard error, where there is one.
    {..} -> {stdout, stderr, tinyweb, code, ok, error, source?}"""
    stderr = decoded(data.get("stderr"))
    run = {"stdout": decoded(data.get("stdout")), "stderr": stderr, "tinyweb": "",
           "code": data.get("code"), "ok": True, "error": "", "source": None}
    at = stderr.rfind(TRAILER)
    if at >= 0 and (at == 0 or stderr[at - 1] == "\n"):
        try:
            trailer = json.loads(stderr[at + len(TRAILER):].strip() or "{}")
        except json.JSONDecodeError:
            trailer = {}
        run["stderr"] = trailer.get("stderr", stderr[:at])
        run["tinyweb"] = trailer.get("tinyweb", "")
        run["ok"] = trailer.get("status", "ok") == "ok"
        run["error"] = trailer.get("error", "")
        if isinstance(trailer.get("source"), str):
            run["source"] = trailer["source"]
    if run["code"] is None:
        run["code"] = 0
    return run


def first_difference(expected, got, rules):
    """The first line two outputs differ at, numbered from 1, as
    (number, expected line, got line); a missing line is None. Where the
    rules let lines come in any order, the lines are counted in the
    order canonical() puts them in, and compared as ignore-chars cleans
    them, but shown as written.
    String -> String -> [Rule] -> (Int, String?, String?)"""
    left, right = canonical(rules, expected), canonical(rules, got)
    for k in range(max(len(left), len(right))):
        a = left[k] if k < len(left) else None
        b = right[k] if k < len(right) else None
        if a is None or b is None or not (a[0] == b[0] or allowed_line(rules, a[0], b[0])):
            return k + 1, a and a[1], b and b[1]
    return len(left), None, None


def details(params, run, drawing=False):
    """The failed test and both outputs, as the notebook shows them under
    a task; where what it drew differs, the first line of tinyweb's
    log that does. {..} -> {..} -> Bool -> String"""
    rows = []
    if params["test_stdin"]:
        rows.append("stdin:\n" + params["test_stdin"].rstrip("\n"))
    if params["test_args"]:
        rows.append("args: " + " ".join(quoted_argument(a) for a in params["test_args"]))
    if params["test_events"]:
        rows.append("events:\n" + params["test_events"].rstrip("\n"))
    if drawing:
        line, want, have = first_difference(params["expected_tinyweb"], run["tinyweb"],
                                            task_rules(params))
        rows.append(f"what it drew differs at line {line} of tinyweb's log:")
        rows.append("expected: " + (want if want is not None else "(nothing)"))
        rows.append("got: " + (have if have is not None else "(nothing)"))
    elif params["compare_stderr"]:
        rows.append("expected:\n" + params["expected_stdout"].rstrip("\n"))
        rows.append("expected from debug:\n" + params["expected_stderr"].rstrip("\n"))
        rows.append("got:\n" + run["stdout"].rstrip("\n"))
        rows.append("got from debug:\n" + run["stderr"].rstrip("\n"))
    else:
        rows.append("expected:\n" + params["expected_stdout"].rstrip("\n"))
        rows.append("got:\n" + run["stdout"].rstrip("\n"))
    return "\n" + "\n".join(rows)


def quoted_argument(argument):
    """An argument as the notebook's args field would take it back: in
    double quotes where it holds a blank, a quote or a backslash, or is
    empty. String -> String"""
    if argument and not any(c.isspace() or c in "'\"\\" for c in argument):
        return argument
    return '"' + argument.replace("\\", "\\\\").replace('"', '\\"') + '"'



def code_only(source):
    """A program's text with every comment and string literal blanked
    out, so only its code is left. String -> String"""
    out, i = [], 0
    while i < len(source):
        c = source[i]
        if c == "#":
            while i < len(source) and source[i] != "\n":
                i += 1
        elif c in "'\"":
            i += 1
            while i < len(source) and source[i] not in (c, "\n"):
                i += 2 if source[i] == "\\" else 1
            i += 1
            out.append(" ")
        else:
            out.append(c)
            i += 1
    return "".join(out)


def call_count(source, name):
    """How many times a program writes `name` as a whole name outside its
    comments and strings: `rect(`, `tw.rect(` and `def rect` all count,
    `rect_w` and `rectangle` do not. String -> String -> Int"""
    word = re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])")
    return len(word.findall(code_only(source)))


def over_calls(source, limits):
    """The first [N, name] limit a program writes its name more often
    than, as (name, count, N), or None. String -> [[Int, String]] ->
    (String, Int, Int)?"""
    for limit in limits:
        if not (isinstance(limit, list) and len(limit) == 2):
            raise Refusal(f"params.max_calls holds {limit!r}, not an [N, name] pair")
        most, name = limit
        count = call_count(source, str(name))
        if count > int(most):
            return name, count, int(most)
    return None


def verify_task(params, run):
    """The reason a task's run is refused, as the notebook gives it,
    or None where it passes. {..} -> {..} -> String?"""
    if params["max_calls"]:
        if run["source"] is None:
            raise Refusal("the run carries no source to check max_calls against: "
                          "run the answer with nbverify.py run")
        over = over_calls(run["source"], params["max_calls"])
        if over:
            name, count, most = over
            return (f"Your program uses {name} {count} time{'' if count == 1 else 's'}, "
                    f"and may use it at most {most} time{'' if most == 1 else 's'}.")
    if not run["ok"]:
        return "Your program did not run:\n" + run["error"].rstrip()
    rules = task_rules(params)
    problem = None
    if params["compare_stdout"] and not same_output(run["stdout"], params["expected_stdout"], rules):
        problem = "The output is not what it should be."
    elif params["compare_tinyweb"] and not same_output(run["tinyweb"], params["expected_tinyweb"], rules):
        problem = "What it drew with tinyweb is not what it should be."
    elif params["compare_stderr"] and not same_output(run["stderr"], params["expected_stderr"], rules):
        problem = "What debug printed is not what it should be."
    elif params["compare_code"] and run["code"] != params["expected_code"]:
        problem = (f"Your program ended with status {run['code']}, "
                   f"and should end with {params['expected_code']}.")
    if problem and params["details"]:
        problem += details(params, run, problem.startswith("What it drew"))
    return problem


QUIZ_ANSWER = re.compile(r"\[\s*(?:-?\d+\s*(?:,\s*-?\d+\s*)*)?\]")


def verify_quiz(params, run):
    """The reason a quiz's answer -- a program printing the list of the
    alternatives chosen, from 1 -- is refused, or None where it is right.
    {..} -> {..} -> String?"""
    if not run["ok"]:
        return "Your program did not run:\n" + run["error"].rstrip()
    text = run["stdout"].strip()
    if not QUIZ_ANSWER.fullmatch(text):
        return ("Your answer is not a list of the alternatives chosen, "
                "such as [1, 3], printed on its own.")
    chosen = [int(n) for n in re.findall(r"-?\d+", text)]
    count = params["quiz_alternatives"]
    multiple = params["quiz_multiple"]
    for n in chosen:
        if n < 1 or n > count:
            return f"There is no alternative {n}: the quiz has {count}, numbered from 1."
    for n in chosen:
        if chosen.count(n) > 1:
            return f"Alternative {n} is chosen more than once."
    if not chosen:
        return "Check at least one answer first." if multiple else "Choose an answer first."
    if not multiple and len(chosen) > 1:
        return "Choose one answer."
    right = set(int(n) for n in params["quiz_right"])
    wrong = sorted(n for n in chosen if n not in right)
    missed = any(n not in chosen for n in right)
    if not wrong and not missed:
        return None
    lines = ["Not right."]
    if multiple and missed:
        lines.append("One or more right answers were not checked.")
    explanations = params["quiz_explanations"]
    for n in wrong:
        if n - 1 < len(explanations) and explanations[n - 1]:
            lines.append(f"{n}: {explanations[n - 1]}")
    return "\n".join(lines)


def param_value(name, value):
    """A parameter as given, a list parameter's JSON string read back
    into the list. String -> Any -> Any"""
    if name not in LISTS or not isinstance(value, str):
        return value
    try:
        value = json.loads(value)
    except json.JSONDecodeError as err:
        raise Refusal(f"params.{name} is not a JSON list: {err}")
    if not isinstance(value, list):
        raise Refusal(f"params.{name} is not a JSON list")
    return value


def encoded(name, value):
    """A parameter as a test file holds it: a list parameter as a string
    of JSON. String -> Any -> Any"""
    return json.dumps(value, ensure_ascii=False) if name in LISTS else value


def verify(data):
    """The verdict on one run: {accepted, reason}. {..} -> {..}"""
    if not isinstance(data, dict):
        raise Refusal("the input is not a JSON object")
    given = data.get("params") or {}
    if not isinstance(given, dict):
        raise Refusal("params is not an object")
    params = dict(DEFAULTS)
    params.update({k: param_value(k, v) for k, v in given.items() if k in DEFAULTS})
    run = answer_run(data)
    if params["kind"] == "quiz":
        reason = verify_quiz(params, run)
    elif params["kind"] == "task":
        reason = verify_task(params, run)
    else:
        raise Refusal(f"params.kind is task or quiz, not {params['kind']!r}")
    return {"accepted": reason is None, "reason": reason}


# --- running a program -------------------------------------------------------

def find_pyk(given=None):
    """The pyk to run: --pyk, else $PYK, else pyk on the PATH.
    String? -> String"""
    pyk = given or os.environ.get("PYK") or shutil.which("pyk")
    if not pyk:
        raise Refusal("pyk was not found: give --pyk PATH, or set $PYK")
    return pyk


def run_program(pyk, path, stdin, args, events="", libs=(), stream=False, until=None):
    """One run of a Pyking program with pyk: tinyweb writing its log, and
    delivering `events` once the top level has ended. With `stream`,
    standard input and output are this process's own. `until`, a task's
    compare-until as (N, [pattern]), ends the run with status 0 once the
    log has had N lines a pattern matches ($PYKING_TINYWEB_UNTIL).
    String -> String -> String? -> [String] -> String -> [String] -> Bool ->
    (Int, [String])? -> {stdout, stderr, tinyweb, code, ok, error}"""
    with tempfile.TemporaryDirectory(prefix="nbverify-") as directory:
        log = os.path.join(directory, "tinyweb.log")
        env = dict(os.environ)
        env["PYKING_TINYWEB_LOG"] = log
        env.pop("PYKING_TINYWEB_EVENTS", None)
        if events:
            events_file = os.path.join(directory, "events.txt")
            with open(events_file, "w", encoding="utf-8") as f:
                f.write(events if events.endswith("\n") else events + "\n")
            env["PYKING_TINYWEB_EVENTS"] = events_file
        env.pop("PYKING_TINYWEB_UNTIL", None)
        if until:
            until_file = os.path.join(directory, "until.txt")
            with open(until_file, "w", encoding="utf-8") as f:
                f.write("\n".join([str(until[0])] + list(until[1])) + "\n")
            env["PYKING_TINYWEB_UNTIL"] = until_file
        command = [pyk] + [f"-L{lib}" for lib in libs] + [path, "--"] + list(args)
        try:
            ran = subprocess.run(
                command, env=env, stderr=subprocess.PIPE,
                stdout=None if stream else subprocess.PIPE,
                input=None if stream else (stdin or "").encode("utf-8"),
                timeout=None if stream else SOLUTION_TIMEOUT)
        except subprocess.TimeoutExpired:
            return {"stdout": "", "stderr": "", "tinyweb": "", "code": 124, "ok": False,
                    "error": f"it did not finish in {SOLUTION_TIMEOUT} seconds"}
        except OSError as err:
            return {"stdout": "", "stderr": "", "tinyweb": "", "code": 127, "ok": False,
                    "error": f"pyk could not be started: {err}"}
        stderr = ran.stderr.decode("utf-8", "replace")
        tinyweb = ""
        if os.path.exists(log):
            with open(log, encoding="utf-8", errors="replace") as f:
                tinyweb = f.read()
    error, ok = "", True
    found = list(PYK_ERROR.finditer(stderr))
    if ran.returncode != 0 and found:
        start = found[-1].start()
        error, stderr, ok = stderr[start:], stderr[:start], False
    return {"stdout": "" if stream else ran.stdout.decode("utf-8", "replace"),
            "stderr": stderr, "tinyweb": tinyweb, "code": ran.returncode, "ok": ok,
            "error": error}


def run_arguments(command, argv):
    """A `run` or `try` command line: --pyk, --events, --until and
    --until-match (`run` only) and -L, the program, and what follows it, a
    `--` in front dropped; the compare-until as (N, [pattern]), or None.
    String -> [String] ->
    (String?, String, [String], String, [String], (Int, [String])?)"""
    pyk, events, libs, rest = None, "", [], list(argv)
    most, matches = None, []
    flags = (("--pyk", "--events", "--until", "--until-match", "-L") if command == "run"
             else ("--pyk", "-L"))
    while rest and rest[0].startswith("-") and rest[0] != "--":
        flag = rest.pop(0)
        if flag in flags and rest:
            value = rest.pop(0)
            if flag == "--pyk":
                pyk = value
            elif flag == "--events":
                events = value
            elif flag == "--until":
                if not value.isdigit() or int(value) < 1:
                    raise Refusal(f"{command}: --until is a number of events, from 1, not {value!r}")
                most = int(value)
            elif flag == "--until-match":
                matches.append(value)
            else:
                libs.append(value)
        elif flag.startswith("-L") and len(flag) > 2:
            libs.append(flag[2:])
        else:
            raise Refusal(f"{command}: unknown option {flag}")
    if not rest:
        raise Refusal(f"{command}: give the program to run")
    path, args = rest[0], rest[1:]
    if args and args[0] == "--":
        args = args[1:]
    if (most is None) != (not matches):
        raise Refusal(f"{command}: --until and --until-match come together")
    return pyk, events, libs, path, args, (most, matches) if most else None


def launch(argv):
    """`run`: runs a program with standard input and output its own, then
    writes what it wrote to standard error, the trailer line, and one
    line of JSON: its status, what debug wrote, its error, the tinyweb
    log and the program's source. Exits with the program's status.
    [String] -> Int"""
    pyk, events, libs, path, args, until = run_arguments("run", argv)
    sys.stdout.flush()
    ran = run_program(find_pyk(pyk), path, None, args, events, libs, stream=True, until=until)
    written = ran["stderr"] + ran["error"]
    sys.stderr.write(written)
    if written and not written.endswith("\n"):
        sys.stderr.write("\n")
    sys.stderr.write(TRAILER)
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            source = f.read()
    except OSError:
        source = ""
    sys.stderr.write(json.dumps({"status": "ok" if ran["ok"] else "failed",
                                 "stderr": ran["stderr"], "error": ran["error"],
                                 "tinyweb": ran["tinyweb"], "source": source}) + "\n")
    sys.stderr.flush()
    return ran["code"]


# --- trying an answer on one test -------------------------------------------

#: A TOML bare key, the escapes of a basic string, and a number.
BARE_KEY = re.compile(r"[A-Za-z0-9_-]+")
ESCAPES = {"b": "\b", "t": "\t", "n": "\n", "f": "\f", "r": "\r", '"': '"', "\\": "\\"}
TOML_NUMBER = re.compile(r"[-+]?(?:0|[1-9][0-9_]*)(?:\.[0-9_]+)?(?:[eE][-+]?[0-9_]+)?")


class TomlReader:
    """The TOML paramdata writes, read from a position: tables, dotted
    keys, basic and literal strings, ints, floats, bools and arrays of
    them. Anything else is refused with its line."""

    def __init__(self, text):
        self.text, self.at = text, 0

    def fail(self, message):
        """Refuses the text at the current position. String -> !"""
        line = self.text.count("\n", 0, self.at) + 1
        raise Refusal(f"try: the TOML on standard input, line {line}: {message}")

    def blank(self, newlines):
        """Skips blanks and comments, and line ends where `newlines`.
        Bool -> ()"""
        while self.at < len(self.text):
            c = self.text[self.at]
            if c in " \t" or (newlines and c in "\r\n"):
                self.at += 1
            elif c == "#":
                while self.at < len(self.text) and self.text[self.at] != "\n":
                    self.at += 1
            else:
                return

    def key(self):
        """A dotted key, as its parts. () -> [String]"""
        parts = []
        while True:
            self.blank(False)
            if self.text.startswith(('"', "'"), self.at):
                parts.append(self.string())
            else:
                found = BARE_KEY.match(self.text, self.at)
                if not found:
                    self.fail("a key is expected")
                parts.append(found.group())
                self.at = found.end()
            self.blank(False)
            if not self.text.startswith(".", self.at):
                return parts
            self.at += 1

    def string(self):
        """A basic or literal string on one line. () -> String"""
        quote = self.text[self.at]
        self.at += 1
        out = []
        while True:
            if self.at >= len(self.text) or self.text[self.at] in "\r\n":
                self.fail("a string is not closed on its line")
            c = self.text[self.at]
            self.at += 1
            if c == quote:
                return "".join(out)
            if c == "\\" and quote == '"':
                e = self.text[self.at:self.at + 1]
                self.at += 1
                if e in ESCAPES:
                    out.append(ESCAPES[e])
                elif e in ("u", "U"):
                    width = 4 if e == "u" else 8
                    digits = self.text[self.at:self.at + width]
                    if len(digits) != width or not all(d in "0123456789abcdefABCDEF" for d in digits):
                        self.fail(f"\\{e} needs {width} hexadecimal digits")
                    self.at += width
                    out.append(chr(int(digits, 16)))
                else:
                    self.fail(f"unknown escape \\{e}")
            else:
                out.append(c)

    def value(self):
        """One value. () -> Any"""
        self.blank(False)
        if self.text.startswith(('"' * 3, "'" * 3), self.at):
            self.fail("a multi-line string is not read here")
        if self.text.startswith(('"', "'"), self.at):
            return self.string()
        if self.text.startswith("[", self.at):
            self.at += 1
            items = []
            while True:
                self.blank(True)
                if self.text.startswith("]", self.at):
                    self.at += 1
                    return items
                items.append(self.value())
                self.blank(True)
                if self.text.startswith(",", self.at):
                    self.at += 1
                elif not self.text.startswith("]", self.at):
                    self.fail("an array's values are separated by commas")
        for word, meaning in (("true", True), ("false", False)):
            if self.text.startswith(word, self.at) and not BARE_KEY.match(self.text, self.at + len(word)):
                self.at += len(word)
                return meaning
        found = TOML_NUMBER.match(self.text, self.at)
        if found and not BARE_KEY.match(self.text, found.end()) and not self.text.startswith(".", found.end()):
            self.at = found.end()
            number = found.group().replace("_", "")
            return float(number) if any(c in number for c in ".eE") else int(number)
        self.fail("a string, a number, a bool or an array is expected")

    def end_of_line(self):
        """Refuses anything but a comment after a line's value. () -> ()"""
        self.blank(False)
        if self.at < len(self.text) and self.text[self.at] not in "\r\n":
            self.fail("the line goes on after its value")

    def place(self, table, parts):
        """The table a dotted name reaches, made where missing.
        {..} -> [String] -> {..}"""
        for part in parts:
            table = table.setdefault(part, {})
            if not isinstance(table, dict):
                self.fail(f"{'.'.join(parts)} is not a table")
        return table

    def document(self):
        """The whole text, as nested dicts. () -> {..}"""
        root = {}
        table = root
        while True:
            self.blank(True)
            if self.at >= len(self.text):
                return root
            if self.text.startswith("[[", self.at):
                self.fail("an array of tables is not read here")
            if self.text.startswith("[", self.at):
                self.at += 1
                parts = self.key()
                if not self.text.startswith("]", self.at):
                    self.fail("a table's name ends with ]")
                self.at += 1
                table = self.place(root, parts)
            else:
                parts = self.key()
                if not self.text.startswith("=", self.at):
                    self.fail("a key is followed by =")
                self.at += 1
                value = self.value()
                holder = self.place(table, parts[:-1])
                if parts[-1] in holder:
                    self.fail(f"{'.'.join(parts)} is given twice")
                holder[parts[-1]] = value
            self.end_of_line()


def read_toml(text):
    """The TOML paramdata writes, as nested dicts. String -> {..}"""
    return TomlReader(text).document()


def attempt(argv):
    """`try`: runs a program with `run` on the test whose [test.options]
    is on standard input, and prints the verifier's verdict on that run,
    or with --json the run itself, as the verifier reads it. [String] -> Int"""
    as_json = "--json" in argv[:argv.index("--") if "--" in argv else len(argv)]
    if as_json:
        argv = list(argv)
        argv.remove("--json")
    pyk, _, libs, path, rest, _ = run_arguments("try", argv)
    if rest:
        raise Refusal("try: the program's arguments come from the test, not the command line")
    if not os.path.exists(path):
        raise Refusal(f"try: no such program: {path}")
    if sys.stdin is None or sys.stdin.isatty():
        raise Refusal("try: give one test's [test.options] on standard input, "
                      "as paramdata --case N prints it")
    options = (read_toml(sys.stdin.read()).get("test") or {}).get("options")
    if not isinstance(options, dict):
        raise Refusal("try: standard input holds no [test.options]")
    args, stdin = options.get("args"), options.get("stdin", "")
    params = options.get("verifier_params")
    if not (isinstance(args, list) and args[:1] == ["run"] and all(isinstance(a, str) for a in args)):
        raise Refusal('try: the test\'s args are not a run command, ["run", ...]')
    if not isinstance(stdin, str):
        raise Refusal("try: the test's stdin is not a string")
    if not isinstance(params, dict):
        raise Refusal("try: the test has no verifier_params")
    _, events, _, _, program_args, until = run_arguments("run", args[1:])
    command = ["run"] + (["--events", events] if events else []) + until_flags(until) + [path]
    command += ["--"] + program_args if program_args else []
    own = [sys.executable, os.path.abspath(__file__), "run", "--pyk", find_pyk(pyk)]
    own += [f"-L{lib}" for lib in libs] + command[1:]
    try:
        ran = subprocess.run(own, input=stdin.encode("utf-8"), capture_output=True,
                             timeout=SOLUTION_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Refusal(f"try: {path} did not finish in {SOLUTION_TIMEOUT} seconds")
    data = {
        "cmd": ["./graded-bin"] + command, "code": ran.returncode,
        "stdout": {"enc": "utf8", "data": ran.stdout.decode("utf-8", "replace")},
        "stderr": {"enc": "utf8", "data": ran.stderr.decode("utf-8", "replace")},
        "files": {}, "params": params,
    }
    if as_json:
        sys.stdout.write(json.dumps(data, ensure_ascii=False) + "\n")
        return 0
    verdict = verify(data)
    sys.stdout.write(json.dumps(verdict) + "\n")
    return 0 if verdict["accepted"] else 1


# --- making the params -----------------------------------------------------

def read_notebook(path, pyk):
    """A notebook's JSON: read from a .json file, or a .md one turned into
    JSON by pyk. String -> String? -> {..}"""
    if not os.path.exists(path):
        raise Refusal(f"no such notebook: {path}")
    if path.lower().endswith((".md", ".markdown")):
        ran = subprocess.run([find_pyk(pyk), "notebook", path, "--to-json", "-o", "-"],
                             capture_output=True, text=True)
        if ran.returncode != 0:
            raise Refusal(ran.stderr.strip() or f"pyk could not read {path}")
        text = ran.stdout
    else:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    try:
        notebook = json.loads(text)
    except json.JSONDecodeError as err:
        raise Refusal(f"{path} is not JSON: {err}")
    if not isinstance(notebook, dict) or notebook.get("format") != "pyking-notebook":
        raise Refusal(f"{path} is not a notebook's JSON")
    return notebook


def items(notebook):
    """A notebook's tasks and quizzes, in order, each with the names it
    may be called by: its name = (or `default` where it is the only item
    and has none), and task-N, practice-N or quiz-N.
    {..} -> [({..}, [String])]"""
    found, counts = [], {"task": 0, "practice": 0, "quiz": 0}
    for block in notebook.get("blocks", []):
        kind = block.get("type")
        if kind in counts:
            counts[kind] += 1
            names = [f"{kind}-{counts[kind]}"]
            name = (block.get("attributes") or {}).get("name")
            if isinstance(name, str):
                names.insert(0, name)
            found.append((block, names))
    if len(found) == 1 and not isinstance((found[0][0].get("attributes") or {}).get("name"), str):
        found[0][1].insert(0, "default")
    return found


def chosen_item(notebook, name, path):
    """The item --name names, or the only one there is. Raises Refusal.
    {..} -> String? -> String -> ({..}, String)"""
    found = items(notebook)
    if not found:
        raise Refusal(f"{path} has no task or quiz")
    if name is None:
        if len(found) > 1:
            listed = ", ".join(names[0] for _, names in found)
            raise Refusal(f"{path} has {len(found)} tasks and quizzes ({listed}): "
                          "give --name to say which")
        return found[0][0], found[0][1][0]
    for block, names in found:
        if name in names:
            return block, names[0]
    listed = ", ".join(names[0] for _, names in found)
    raise Refusal(f"{path} has no task or quiz named {name!r}; it has {listed}")


def input_lines(text):
    """Text a program reads: lines, each ending in a newline. String -> String"""
    return text if text == "" or text.endswith("\n") else text + "\n"


def test_cases(item):
    """A task's tests as the notebook runs them: each with its stdin,
    arguments, events and the stdout and stderr blocks after it, a stdin
    block split by lines_per_multi_input one test a piece.
    {..} -> [{stdin, args, events, stdout?, stderr?}]"""
    attrs = item.get("attributes") or {}
    stdin = input_lines(attrs["stdin"]) if isinstance(attrs.get("stdin"), str) else ""
    args = attrs.get("args") if isinstance(attrs.get("args"), str) else ""
    tests = item.get("tests") or []
    if not tests:
        return [{"stdin": stdin, "args": args, "events": "", "stdout": None, "stderr": None}]
    cases = []
    for test in tests:
        given = test.get("stdin")
        events = (test.get("events") or {}).get("text", "")
        out = (test.get("stdout") or {}).get("text") if test.get("stdout") else None
        err = (test.get("stderr") or {}).get("text") if test.get("stderr") else None
        if given is None:
            cases.append({"stdin": stdin, "args": args, "events": events, "stdout": out, "stderr": err})
            continue
        given_attrs = given.get("attributes") or {}
        test_args = given_attrs.get("args") if isinstance(given_attrs.get("args"), str) else ""
        text = given.get("text", "")
        per = given_attrs.get("lines_per_multi_input")
        if isinstance(per, (int, float)) and int(per) >= 1:
            lines = text.rstrip("\n").split("\n")
            for k in range(0, len(lines), int(per)):
                piece = input_lines("\n".join(lines[k:k + int(per)]))
                cases.append({"stdin": piece, "args": test_args, "events": events,
                              "stdout": None, "stderr": None})
        else:
            cases.append({"stdin": input_lines(text), "args": test_args, "events": events,
                          "stdout": out, "stderr": err})
    return cases


def max_calls(value, name):
    """A task's max_calls = as [N, name] pairs; none where it has none.
    String? -> String -> [[Int, String]]"""
    if value is None:
        return []
    group = re.compile(r"\(\s*([0-9]+)\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)")
    text = value if isinstance(value, str) else ""
    found = list(group.finditer(text))
    if not found or group.sub("", text).strip():
        raise Refusal(f"{name!r} has max_calls = {value!r}, not one or more (N,name)")
    return [[int(m.group(1)), m.group(2)] for m in found]


def task_params(item, name, pyk):
    """Each test of a task as [test.options]: its stdin and
    arguments, and the params its run is verified with -- what the
    solution does on that input, where there is one, and what the stdout
    and stderr blocks say where there is not. {..} -> String -> String? ->
    [({..}, {..})]"""
    solution = item.get("solution")
    attempts = (item.get("attributes") or {}).get("attempts")
    limits = max_calls((item.get("attributes") or {}).get("max_calls"), name)
    until = compare_until(item, name)
    def lines(key):
        return [line for block in item.get(key) or []
                for line in block.get("text", "").split("\n")]
    rules = lines("diff_allowed")
    out = []
    with tempfile.TemporaryDirectory(prefix="nbverify-") as directory:
        program = os.path.join(directory, "solution.pyk")
        if solution:
            with open(program, "w", encoding="utf-8") as f:
                f.write(solution.get("code", ""))
        for k, case in enumerate(test_cases(item)):
            args = split_arguments(case["args"])
            params = dict(DEFAULTS, kind="task", name=name,
                          details=attempts != 1, max_calls=limits,
                          test_stdin=case["stdin"], test_args=args,
                          test_events=case["events"])
            if solution:
                ran = run_program(find_pyk(pyk), program, case["stdin"], args, case["events"],
                                  until=until)
                if not ran["ok"]:
                    raise Refusal(f"the solution of {name!r} does not run on test {k + 1}:\n"
                                  + ran["error"].rstrip())
                params.update(compare_stdout=True, expected_stdout=ran["stdout"],
                              compare_tinyweb=True, expected_tinyweb=ran["tinyweb"],
                              compare_code=True, expected_code=ran["code"], diff_allowed=rules,
                              optional_last=lines("optional_last"),
                              any_order=lines("any_order"),
                              ignore_chars=[[(block.get("attributes") or {}).get("chars", ""), line]
                                            for block in item.get("ignore_chars") or []
                                            for line in block.get("text", "").split("\n")
                                            if line.strip()],
                              compare_stderr=case["stderr"] is not None,
                              expected_stderr=ran["stderr"])
            else:
                if case["stdout"] is None and case["stderr"] is None:
                    raise Refusal(f"test {k + 1} of {name!r} has no solution and no stdout "
                                  "or stderr block to check an answer against")
                params.update(compare_stdout=case["stdout"] is not None,
                              expected_stdout=case["stdout"] or "",
                              compare_stderr=case["stderr"] is not None,
                              expected_stderr=case["stderr"] or "")
            out.append(({"stdin": case["stdin"], "args": args, "events": case["events"],
                         "until": until}, params))
    return out


def quiz_params(item, name):
    """A quiz as one test's params: its alternatives, which are right,
    and what explains each. {..} -> String -> [({..}, {..})]"""
    alternatives = item.get("alternatives") or []
    entries = (item.get("answer") or {}).get("entries") or []
    params = dict(DEFAULTS, kind="quiz", name=name,
                  quiz_alternatives=len(alternatives),
                  quiz_multiple=bool(alternatives) and all(a.get("marker") == "[]" for a in alternatives),
                  quiz_right=[k + 1 for k, e in enumerate(entries) if e.get("correct")],
                  quiz_explanations=[e.get("text", "") for e in entries])
    return [({"stdin": "", "args": [], "events": ""}, params)]


def toml_value(value):
    """A value as TOML writes it. Any -> String"""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(int(value)) if float(value).is_integer() else repr(float(value))
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(v) for v in value) + "]"
    text = json.dumps(str(value), ensure_ascii=False)
    return text.replace("\x7f", "\\u007f")


def until_flags(until):
    """A compare-until (N, [pattern]) as `run`'s flags; none where there
    is none. (Int, [String])? -> [String]"""
    if not until:
        return []
    flags = ["--until", str(until[0])]
    for pattern in until[1]:
        flags += ["--until-match", pattern]
    return flags


def compare_until(item, name):
    """A task's compare-until block as (N, [pattern]), or None where it
    has none. {..} -> String -> (Int, [String])?"""
    blocks = item.get("compare_until") or []
    if not blocks:
        return None
    if len(blocks) > 1:
        raise Refusal(f"{name!r} has {len(blocks)} compare-until blocks, and a task has one")
    events = (blocks[0].get("attributes") or {}).get("events")
    patterns = [line.strip() for line in blocks[0].get("text", "").split("\n") if line.strip()]
    if not isinstance(events, (int, float)) or isinstance(events, bool) \
            or int(events) != events or events < 1:
        raise Refusal(f"{name!r} has a compare-until block whose events = is not a number from 1")
    if not patterns:
        raise Refusal(f"{name!r} has a compare-until block with no pattern")
    return int(events), patterns


def test_toml(run, params, program, title):
    """One test's [test.options], as TOML. {..} -> {..} -> String -> String ->
    String"""
    command = ["run"]
    if run["events"]:
        command += ["--events", run["events"]]
    command += until_flags(run.get("until"))
    command += [program]
    if run["args"]:
        command += ["--"] + run["args"]
    lines = [f"# {title}", "[test.options]",
             f"args = {toml_value(command)}",
             f"stdin = {toml_value(run['stdin'])}"]
    for name, _, _, _ in PARAMS:
        lines.append(f"verifier_params.{name} = {toml_value(encoded(name, params[name]))}")
    return "\n".join(lines) + "\n"


def paramdata(argv):
    """`paramdata`: each test of an item as a test file's [test.options].
    [String] -> Int"""
    rest, name, case, directory, program, pyk, book = list(argv), None, None, None, "solution.pyk", None, None
    while rest:
        flag = rest.pop(0)
        if flag in ("--name", "--case", "--output-dir", "--program", "--pyk"):
            if not rest:
                raise Refusal(f"paramdata: {flag} needs a value")
            value = rest.pop(0)
            if flag == "--name":
                name = value
            elif flag == "--case":
                if not value.isdigit() or int(value) < 1:
                    raise Refusal(f"paramdata: --case is a test's number, from 1, not {value!r}")
                case = int(value)
            elif flag == "--output-dir":
                directory = value
            elif flag == "--program":
                program = value
            else:
                pyk = value
        elif flag.startswith("-"):
            raise Refusal(f"paramdata: unknown option {flag}")
        elif book is None:
            book = flag
        else:
            raise Refusal("paramdata: give one notebook")
    if book is None:
        raise Refusal("paramdata: give the notebook, as .json or .md")
    if case is not None and directory is not None:
        raise Refusal("paramdata: --case prints one test and --output-dir writes them all; give one")
    notebook = read_notebook(book, pyk)
    item, called = chosen_item(notebook, name, book)
    made = quiz_params(item, called) if item["type"] == "quiz" else task_params(item, called, pyk)
    total = len(made)
    stem = os.path.splitext(os.path.basename(book))[0]
    texts = [test_toml(run, params, program,
                       f"nbverify paramdata: {stem} {item['type']} {called!r}, test {k + 1} of {total}")
             for k, (run, params) in enumerate(made)]
    if directory is not None:
        os.makedirs(directory, exist_ok=True)
        for k, text in enumerate(texts):
            with open(os.path.join(directory, f"{called}_t{k + 1:02d}.test.toml"), "w",
                      encoding="utf-8") as f:
                f.write(text)
        return 0
    if case is not None:
        if case > total:
            raise Refusal(f"paramdata: {called!r} has {total} test{'' if total == 1 else 's'}")
        sys.stdout.write(texts[case - 1])
        return 0
    if total > 1:
        raise Refusal(f"paramdata: {called!r} has {total} tests: give --case N for one, "
                      "or --output-dir DIR for a file each")
    sys.stdout.write(texts[0])
    return 0


def paramschema():
    """`paramschema`: the verifier_param_schema, as config.toml writes it.
    () -> Int"""
    lines = ["[test.options.verifier_param_schema]"]
    for name, kind, default, _ in PARAMS:
        kind = "string" if name in LISTS else kind
        lines.append(f"{name} = {{type = \"{kind}\", default = {toml_value(encoded(name, default))}}}")
    sys.stdout.write("\n".join(lines) + "\n")
    return 0


# --- the command line ------------------------------------------------------

def main(argv):
    """The command-line entry point. [String] -> Int"""
    try:
        if not argv:
            try:
                data = json.loads(sys.stdin.read())
            except json.JSONDecodeError as err:
                raise Refusal(f"the input is not JSON: {err}")
            verdict = verify(data)
            sys.stdout.write(json.dumps(verdict) + "\n")
            return 0 if verdict["accepted"] else 1
        command, rest = argv[0], argv[1:]
        if command in ("--help", "-h"):
            print(USAGE)
            return 0
        if command == "--version":
            print(f"nbverify {VERSION}")
            return 0
        if command == "paramschema":
            if rest:
                raise Refusal("paramschema takes no argument")
            return paramschema()
        if command == "paramdata":
            return paramdata(rest)
        if command == "run":
            return launch(rest)
        if command == "try":
            return attempt(rest)
        raise Refusal(f"unknown command {command!r}; nbverify.py --help lists them")
    except Refusal as refusal:
        if not argv:
            sys.stdout.write(json.dumps({"accepted": False, "reason": f"nbverify: {refusal}"}) + "\n")
        else:
            sys.stderr.write(f"nbverify: {refusal}\n")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
