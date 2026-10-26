#!/usr/bin/env python3
"""tinyweb's own suite: what no (program, target) pair can say about it.

`tests/test_script.py` runs every `lib_tinyweb_*` program headless on
each target it lists, and compares the commands it logs with its
`.page` file. This suite checks what that leaves out:

  embedded   every native implementation carries the page as it is in
             lib/tinyweb/ (tools/tinyweb/embed_page.py --check).
  refused    on each of those targets, a program that never calls
             `web_init`, and one that asks for a port there is none of,
             ends with status 1 and says why on standard error.
  served     a program that calls `web_init`, run on each native target
             with no log set, serves its page: GET / and
             /tinyweb_page.js answer the page, a sample is found, and
             the commands that arrive on /commands, with the events of
             its `.events` file posted to /events one at a time, are the
             ones its `.page` file lists. Each `sdelay` is answered as a
             page would, its clock at the end of it.
  sdelay     the page's side of `sdelay` under node with its clock moved
             by hand (tests/tinyweb/sdelay.mjs); a program calling it
             refused for web; and on each native target, a click while
             the program waits in it runs its function then.
  default    compiled for each target with no --output, into the
             directory the command runs in, a program brings the
             library's samples with it in tinyweb_assets/.
  standalone each implementation, published by tools/site/tinywebdoc.py
             as a library of its own (`tinyweb.py`, `tinyweb.ml` with its
             `.mli`, `tinyweb.c` with its `.h`, ...), builds with the
             example written against it, which, run with no page, logs
             what lib_tinyweb_sound_graphics1.pyk does.
  browser    the web implementation, which draws directly, does what
             the command one does through tinyweb_page.js: each program
             is run both ways against the same small DOM under node, and
             -- where a Chromium is found -- both ways in a real browser,
             and what was drawn is compared (see `BROWSER` below).

Usage: python3 tests/test_tinyweb.py [--compiler CMD] [--only PART]
                                      [--sample PERCENT [--seed N]]

`--sample PERCENT` (`make quicktest`) runs PERCENT of each part's checks but the
embed check, at
least one, chosen at random by `--seed N`.

Functions:
    page_cases() -- the tinyweb programs, with their .events and .page.
    compacted(commands) -- what a page connecting late is sent.
    check_embedded() -- the embed check.
    check_served(case, target) -- one program served on one target.
    check_default_output(compiler, target) -- compiling with no --output.
    main(argv) -- the command-line entry point.
"""

import http.client
import http.server
import base64
import json
import os
import queue
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))

import suite  # noqa: E402

TIMEOUT = 120
EMBED = ROOT / "tools" / "tinyweb" / "embed_page.py"
LIB = ROOT / "lib" / "tinyweb"

# One target per family that runs a program outside a browser, with the
# extension its output takes; `interpret` is `pyk <file>` itself.
SERVED_TARGETS = {
    "interpret": None,
    "python12": ".py",
    "node22": ".js",
    "ocaml4.14": ".ml",
    "c23": ".c",
    "java21": ".java",
}


# --- the cases ---

def page_cases():
    """Every tinyweb program in tests/: (stem, .events lines, .page lines,
    .out text). () -> [(Path, [String], [String], String)]"""
    cases = []
    for page in sorted(HERE.glob("lib_tinyweb_*.page")):
        stem = page.with_suffix("")
        events = stem.with_suffix(".events")
        cases.append((
            stem,
            events.read_text().split("\n") if events.exists() else [],
            page.read_text().splitlines(),
            stem.with_suffix(".out").read_text() if stem.with_suffix(".out").exists() else "",
        ))
    return cases


def engine_event(case):
    """The first line of a case's events that stands for what the page's
    own engine sends -- a beat, a timer, a rendering, a report -- which a
    page under a driver makes itself rather than being told, or None. A
    text area's change and a file picked a driver causes as a reader
    would. (Path, [String], [String], String) -> String?"""
    for line in case[1]:
        words = line.split()
        if not words:
            continue
        if words[0] == "report":
            return line
        if words[0] == "report_text" and not re.match(r'report_text "(value\.|file)', line):
            return line
        if words[0] == "cb" and not re.search(r'"(change|loaded)"$', line.strip()):
            return line
    return None


def drawn_cases(skipped, where):
    """The page cases a page can be driven through; the rest are named in
    `skipped`. [String] -> String -> [case]"""
    cases = []
    for case in page_cases():
        line = engine_event(case)
        if waits(case):
            skipped.append(f"{case[0].name}.pyk {where}: it waits in `sdelay`, which the web "
                           f"target refuses (`refused` checks that)")
        elif line is None:
            cases.append(case)
        else:
            skipped.append(f"{case[0].name}.pyk {where}: its events stand for the page's own "
                           f"engine ({line})")
    return cases


def waits(case):
    """Whether a case's program calls `sdelay`, which waits for its page:
    a page answers that only as its clock goes on. (case) -> Bool"""
    return "sdelay(" in case[0].with_suffix(".pyk").read_text()


def excluded(stem, target):
    """Whether tests/test_cases.toml leaves `target` out for the case
    `stem` -- C, for a program holding a list. Path -> String -> Bool"""
    import tomllib
    sys.path.insert(0, str(HERE))
    import test_script
    with open(HERE / "test_cases.toml", "rb") as f:
        cases = tomllib.load(f)["cases"]
    for case in cases:
        if case["file"] == stem.name + ".pyk":
            return any(target in test_script.selected_targets(key)
                       for key in case.get("excluded", {}))
    return False


def segments(lines):
    """A .page file split where the events were delivered: the top
    level's commands, then each event with what it caused.
    [String] -> ([String], [(String, [String])])"""
    top, after = [], []
    for line in lines:
        if line.startswith("> "):
            after.append((line[2:], []))
        elif after:
            after[-1][1].append(line)
        else:
            top.append(line)
    return top, after


# --- commands as lines ---

def quote(text):
    return json.dumps(text, ensure_ascii=False)


def log_line(command):
    """A command as the line every headless implementation writes for it:
    each identifier quoted, and an element's text after it only where the
    two differ. {String: Value} -> String"""
    c = command.get
    q = lambda name: quote(c(name))  # noqa: E731
    flag = lambda name: "true" if c(name) else "false"  # noqa: E731
    op = c("op")
    seconds = lambda x: f"{x:.3f}"  # noqa: E731

    def named(id_field, text_field):
        return q(id_field) + ("" if c(id_field) == c(text_field) else " " + q(text_field))

    def state():
        words = [c("kind"), q("c")]
        if c("value") != "":
            words.append(q("value"))
        if c("numbers") != "":
            words.append(c("numbers"))
        return " ".join(words)

    lines = {
        "canvas": lambda: f"canvas {q('id')} {c('width')} {c('height')}",
        "clear": lambda: f"clear {q('c')} {c('color')}",
        "shape": lambda: (f"{c('kind')} {q('c')} {c('numbers')} {q('color')} {q('outline')} "
                          f"{seconds(c('width'))} {seconds(c('alpha'))}"),
        "text": lambda: (f"text {q('c')} {seconds(c('x'))} {seconds(c('y'))} {q('color')} "
                         f"{c('size')} {q('font')} {c('align')} {c('baseline')} {flag('bold')} "
                         f"{q('outline')} {seconds(c('outline_width'))} {seconds(c('alpha'))} "
                         f"{q('words')}"),
        "measure": lambda: f"measure {q('id')} {c('size')} {q('font')} {flag('bold')} {q('words')}",
        "on_pointer": lambda: f"on_pointer {q('c')}",
        "row": lambda: f"row {q('id')}",
        "column": lambda: f"column {q('id')}",
        "inside": lambda: f"inside {q('id')}",
        "bitmap": lambda: (f"bitmap {q('c')} {q('id')} {c('x')} {c('y')} {seconds(c('scale'))} "
                           f"{c('width')} {c('height')} {' '.join(map(str, c('rect')))} "
                           f"{digest(base64.b64decode(c('data')))}"),
        "state": state,
        "image_load": lambda: f"load_image {named('id', 'name')}",
        "image": lambda: (f"image {q('c')} {q('picture')} {c('x')} {c('y')} {c('width')} "
                          f"{c('height')} {seconds(c('alpha'))}"),
        "button": lambda: f"button {named('id', 'title')}",
        "label": lambda: f"label {named('id', 'text')}",
        "set_label": lambda: f"set_label {q('id')} {q('text')}",
        "slider": lambda: f"slider {q('id')} {c('low')} {c('high')} {c('value')}",
        "checkbox": lambda: f"checkbox {named('id', 'title')} {flag('checked')}",
        "radio": lambda: f"radio {named('id', 'title')} {q('group')} {flag('chosen')}",
        "choice": lambda: f"choice {q('id')} {c('chosen')} {q('options')}",
        "text_input": lambda: f"text_input {named('id', 'placeholder')}",
        "number": lambda: f"number {q('id')} {c('low')} {c('high')} {c('value')}",
        "set_checked": lambda: f"set_checked {q('id')} {flag('checked')}",
        "set_value": lambda: f"set_value {q('id')} {c('value')}",
        "load": lambda: f"load {named('id', 'name')}",
        "cmd": lambda: (f"{c('kind')} {q('id')}" + ("" if c("text") == "" else " " + q("text"))
                        + ("" if c("numbers") == "" else " " + c("numbers"))),
        "on_mouse": lambda: f"on_mouse {q('c')}",
        "style": lambda: f"style {q('id')} {c('kind')} {c('prop')} {q('value')}",
        "splash_text": lambda: f"splash_text {q('text')}",
        "sdelay": lambda: f"sdelay {seconds(c('seconds'))}",
    }
    return lines.get(op, lambda: op)()


def digest(data):
    """FNV-1a, 32 bits, of the bytes, as the log writes a bitmap's.
    Bytes -> String"""
    h = 2166136261
    for b in data:
        h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    return f"{h:08x}"


def split_line(line):
    """A log or events line as its first word, the quoted identifier after
    it (None where there is none) and the words after that.
    String -> (String, String?, [String])"""
    first, _, rest = line.partition(" ")
    rest = rest.lstrip()
    if not rest.startswith('"'):
        return first, None, rest.split()
    id, end = json.JSONDecoder().raw_decode(rest)
    return first, id, rest[end:].split()


# What a page connecting later is sent again of a generic command, by
# its first word: the last of its kind and element only, or nothing
# (tinyweb.pyk gives each kind its mode; sound before any event is kept
# as everything else is).
REPLACED = ("set_text", "visible", "enabled", "master", "tempo", "swing", "channel", "listen",
            "cursor")
NOT_KEPT = ("render", "render_end", "download", "save_canvas", "audio")

# The first word of every line that draws on a canvas, which a `clear`
# of that canvas makes invisible to a page connecting later.
DRAWING = ("clear", "rect", "circle", "ellipse", "arc", "line", "lines", "curve", "bezier",
           "polygon", "path", "erase", "text", "image", "bitmap", "translate", "rotate", "scale",
           "push", "pop", "reset", "shadow", "blend", "line_style", "clip")


def compacted(lines):
    """What a page connecting late is sent of these commands: nothing
    drawn on a canvas before it was cleared, no label text before it was
    set again. The top level's sound is kept. Applied to what arrived before anything was
    delivered, since a page may connect after the top level has sent
    some of it. [String] -> [String]"""
    kept = []
    for line in lines:
        op, id, _ = split_line(line)
        if op == "clear":
            kept = [k for k in kept
                    if not (split_line(k)[0] in DRAWING and split_line(k)[1] == id)]
        if op in NOT_KEPT:
            continue
        if op in ("set_label", "set_checked", "set_value") + REPLACED:
            kept = [k for k in kept
                    if not (split_line(k)[0] == op and split_line(k)[1] == id)]
        kept.append(line)
    return kept


def event_of(line):
    """An events-file line as the JSON a page posts. String -> {String: Value}"""
    if line.startswith("key "):
        return {"ev": "key", "key": line[4:]}
    if line.startswith("key_up "):
        return {"ev": "key_up", "key": line[7:]}
    kind, id, words = split_line(line)
    if kind == "enter":
        text, _ = json.JSONDecoder().raw_decode(" ".join(words))
        return {"ev": "enter", "id": id, "text": text}
    if kind == "check":
        return {"ev": "check", "id": id, "checked": words[0] == "true"}
    if kind == "pick":
        return {"ev": "pick", "id": id}
    if kind == "choose":
        return {"ev": "choose", "id": id, "value": int(words[0])}
    if kind == "click":
        return {"ev": "click", "id": id}
    if kind == "slide":
        return {"ev": "slide", "id": id, "value": int(words[0])}
    if kind == "frame":
        return {"ev": "frame", "t": float(words[0])}
    if kind in ("mouse", "press", "release", "move"):
        return {"ev": kind, "c": id, "x": int(words[0]), "y": int(words[1])}
    if kind == "measured":
        return {"ev": "measured", "id": id, "width": float(words[0])}
    if kind == "cb":
        return {"ev": "cb", "id": id, "kind": json.loads(" ".join(words))}
    if kind == "report":
        return {"ev": "report", "reports": {id: [float(w) for w in words]}}
    if kind == "report_text":
        return {"ev": "report", "reports": {id: json.loads(" ".join(words))}}
    return {"ev": kind}


# --- embedded ---

def check_embedded():
    """[(String, String?)]"""
    ran = subprocess.run([sys.executable, str(EMBED), "--check"],
                         capture_output=True, text=True, timeout=TIMEOUT)
    return [("every native implementation carries the page",
             None if ran.returncode == 0 else ran.stderr.strip())]


# --- served ---

class Served:
    """A program running with its page served: its standard output read
    as it comes, and the address it printed."""

    def __init__(self, command, cwd):
        env = {k: v for k, v in os.environ.items()
               if k not in ("PYKING_TINYWEB_LOG", "PYKING_TINYWEB_EVENTS")}
        self.process = subprocess.Popen(
            command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL, text=True, start_new_session=True)
        self.lines = queue.Queue()
        self.output = []
        self.errors = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_errors, daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def _read_errors(self):
        for line in self.process.stderr:
            self.errors.append(line)

    def address(self):
        """The port the program said it serves on, or None if it ended
        first. () -> Int?"""
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            try:
                line = self.lines.get(timeout=1)
            except queue.Empty:
                continue
            if line is None:
                return None
            found = re.match(r"tinyweb: http://127\.0\.0\.1:(\d+)/$", line.rstrip("\n"))
            if found:
                return int(found.group(1))
            self.output.append(line)
        return None

    def settle(self, expected, seconds=2.0):
        """Reads what the program prints until it is `expected` or
        `seconds` have passed: a host may write its output after telling
        the page an event is done. String -> Float -> ()"""
        deadline = time.time() + seconds
        while "".join(self.output) != expected and time.time() < deadline:
            try:
                line = self.lines.get(timeout=0.05)
            except queue.Empty:
                continue
            if line is None:
                self.lines.put(None)
                return
            self.output.append(line)

    def stop(self):
        """Stops the program and answers everything it printed after the
        address. () -> String"""
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            # macOS answers EPERM for a group whose process has exited.
            pass
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            self.process.wait()
        while True:
            try:
                line = self.lines.get(timeout=5)
            except queue.Empty:
                break
            if line is None:
                break
            self.output.append(line)
        return "".join(self.output)


class Stream:
    """The page's end of /commands: every command as it arrives. Where
    `answer` is true, it answers each `sdelay` as a page would, its clock
    going on to where the `sdelay` ends: the first `seconds` from 0, each
    later one `seconds` after the last ended."""

    def __init__(self, port, answer=True):
        self.port = port
        self.answer = answer
        self.clock = None
        self.connection = http.client.HTTPConnection("127.0.0.1", port, timeout=TIMEOUT)
        self.connection.request("GET", "/commands")
        self.response = self.connection.getresponse()
        self.commands = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            while True:
                line = self.response.readline()
                if not line:
                    break
                text = line.decode("utf-8").rstrip("\r\n")
                if text.startswith("data:"):
                    for command in json.loads(text[5:].strip()):
                        self.commands.put(command)
                        if self.answer and command.get("op") == "sdelay":
                            self.answer_sdelay(command)
        except (OSError, ValueError):
            pass
        self.commands.put(None)

    def answer_sdelay(self, command):
        """Answers an `sdelay` at the time it ends. {String: Value} -> ()"""
        self.clock = (0.0 if self.clock is None else self.clock) + float(command["seconds"])
        event = {"ev": "sdelay", "id": command["id"], "t": self.clock}
        fetch(self.port, "POST", "/events", json.dumps(event).encode())

    def until_done(self):
        """Every command up to the next `event_done`, as log lines, less
        the frame bookkeeping; None if the stream ended first.
        () -> [String]?"""
        got = []
        while True:
            try:
                command = self.commands.get(timeout=TIMEOUT)
            except queue.Empty:
                return None
            if command is None:
                return None
            if command.get("op") == "event_done":
                return got
            if command.get("op") != "frame_done":
                got.append(log_line(command))

    def until(self, op):
        """Every command up to and including the next with `op`, as log
        lines; None if the stream ended first. String -> [String]?"""
        got = []
        while True:
            try:
                command = self.commands.get(timeout=TIMEOUT)
            except queue.Empty:
                return None
            if command is None:
                return None
            got.append(command)
            if command.get("op") == op:
                return got


def fetch(port, method, path, body=None):
    """(status, bytes) of one request to the program's server."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=TIMEOUT)
    connection.request(method, path, body=body)
    response = connection.getresponse()
    data = response.read()
    connection.close()
    return response.status, data


REFUSALS = [
    ("calls nothing first", "c = tw.canvas(10, 20)\n",
     "tinyweb: call tinyweb.web_init(port) before anything else, or set PYKING_TINYWEB_LOG"),
    ("asks for port 70000", "tw.web_init(70000)\n",
     "tinyweb: cannot serve the page on port 70000: a port is a number from 0 to 65535"),
]


def check_refused(compiler, target, body, message):
    """A program that misuses tinyweb, run with no log set: it must end
    with status 1 and say `message` on standard error. -> String?"""
    with tempfile.TemporaryDirectory(prefix="pyk-tinyweb-") as workdir:
        stem = Path(workdir) / "refused"
        stem.with_suffix(".pyk").write_text(
            "import tinyweb as tw\n\nprint(\"before\")\n" + body + "print(\"after\")\n")
        env = {k: v for k, v in os.environ.items()
               if k not in ("PYKING_TINYWEB_LOG", "PYKING_TINYWEB_EVENTS")}
        ran = subprocess.run(served_command(compiler, stem, target, workdir), cwd=workdir,
                             env=env, capture_output=True, text=True, timeout=TIMEOUT,
                             stdin=subprocess.DEVNULL)
        said = " ".join(ran.stderr.split())
        if ran.returncode != 1:
            return f"it ended with status {ran.returncode}, not 1:\n{ran.stderr[-1500:]}"
        if " ".join(message.split()) not in said:
            return f"it did not say `{message}`:\n{ran.stderr[-1500:]}"
        if ran.stdout.splitlines()[-1:] != ["before"]:
            return f"it printed {ran.stdout!r}, where only `before` comes first"
    return None


def served_command(compiler, stem, target, workdir):
    """How to run `stem.pyk` on `target` with its page served: `pyk` for
    the interpreter, `pyk compile --run` for the rest, which builds and
    runs it with that target's own commands. -> [String]"""
    source = str(stem.with_suffix(".pyk"))
    if target == "interpret":
        return compiler + [source]
    # `pyk compile` writes into build/ beside the executable it is asked
    # for, and --run runs it from there.
    output = os.path.join(workdir, "program")
    return compiler + ["compile", "-t", target, "-o", output, "--run", source]


def check_served(compiler, case, target):
    """One program, run on one target with its page served, held to its
    .page and .out files. -> String? (None when it passed)"""
    stem, events, page, expected_out = case
    top, delivered = segments(page)
    with tempfile.TemporaryDirectory(prefix="pyk-tinyweb-") as workdir:
        served = Served(served_command(compiler, stem, target, workdir), workdir)
        try:
            port = served.address()
            if port is None:
                served.stop()
                return "it printed no address:\n" + "".join(served.errors)[-2000:]
            status, html = fetch(port, "GET", "/")
            if status != 200 or html.decode() != (LIB / "tinyweb_page.html").read_text():
                return f"GET / answered {status} and not tinyweb_page.html"
            status, js = fetch(port, "GET", "/tinyweb_page.js")
            if status != 200 or js.decode() != (LIB / "tinyweb_page.js").read_text():
                return f"GET /tinyweb_page.js answered {status} and not tinyweb_page.js"
            status, sample = fetch(port, "GET", "/tinyweb_assets/kick1.wav")
            if status != 200 or sample != (LIB / "tinyweb_assets" / "kick1.wav").read_bytes():
                return f"GET /tinyweb_assets/kick1.wav answered {status} and not the sample"
            status, _ = fetch(port, "GET", "/no-such-file.wav")
            if status != 404:
                return f"GET of a missing file answered {status}, not 404"
            stream = Stream(port)
            received = []
            for index, (line, caused) in enumerate(delivered):
                fetch(port, "POST", "/events", json.dumps(event_of(line)).encode())
                got = stream.until_done()
                if got is None:
                    return (f"the stream ended before `{line}` was answered:\n"
                            + "".join(served.errors)[-2000:])
                if index == 0:
                    # What arrived before the first event was answered is
                    # the top level's commands, compacted where the page
                    # connected late, followed by what the event caused.
                    split = len(got) - len(caused)
                    before, got = got[:split], got[split:]
                    if compacted(before) != compacted(top):
                        return ("the top level sent\n  " + "\n  ".join(before)
                                + "\nwhere the .page file says\n  " + "\n  ".join(top))
                if got != caused:
                    return (f"`{line}` caused\n  " + "\n  ".join(got)
                            + "\nwhere the .page file says\n  " + "\n  ".join(caused))
                received.append(got)
            if not delivered:
                time.sleep(0.5)
        finally:
            expected = "".join(l for l in expected_out.splitlines(keepends=True))
            served.settle(expected)
            output = served.stop()
        if output != expected:
            return f"it printed\n{output}\nwhere the .out file says\n{expected}"
    return None


# --- sdelay ---

SDELAY_PROGRAM = """import tinyweb as tw

tw.web_init(0)


def hit():
    print("hit")


b = tw.button("Hit", on_click = hit)
print("waiting")
tw.sdelay(0.5)
print("after", tw.time())
"""


def check_sdelay_events(compiler, target):
    """A program waiting in `sdelay`, run on one target with its page
    served: a click posted while it waits runs the button's function then
    and there, and the program goes on once the page answers, at the
    clock the answer gave. -> String?"""
    with tempfile.TemporaryDirectory(prefix="pyk-tinyweb-") as workdir:
        stem = Path(workdir) / "waits"
        stem.with_suffix(".pyk").write_text(SDELAY_PROGRAM)
        served = Served(served_command(compiler, stem, target, workdir), workdir)
        expected = "waiting\nhit\nafter 0.5\n"
        try:
            port = served.address()
            if port is None:
                served.stop()
                return "it printed no address:\n" + "".join(served.errors)[-2000:]
            stream = Stream(port, answer=False)
            got = stream.until("sdelay")
            if got is None:
                return "the stream ended before the program sent `sdelay`"
            waiting = got[-1]
            if waiting.get("seconds") != 0.5:
                return f"`sdelay` was sent as {waiting!r}"
            fetch(port, "POST", "/events", json.dumps({"ev": "click", "id": "Hit"}).encode())
            if stream.until_done() is None:
                return ("the click posted while the program waited was not answered:\n"
                        + "".join(served.errors)[-2000:])
            answer = {"ev": "sdelay", "id": waiting["id"], "t": 0.5}
            fetch(port, "POST", "/events", json.dumps(answer).encode())
        finally:
            served.settle(expected)
            output = served.stop()
        if output != expected:
            return f"it printed\n{output}\nwhere it should have printed\n{expected}"
    return None


def check_sdelay_refused_on_web(compiler):
    """A program calling `sdelay` is refused for the web target, where it
    is called, saying why; for iweb it compiles. -> String?"""
    with tempfile.TemporaryDirectory(prefix="pyk-tinyweb-") as workdir:
        source = Path(workdir) / "waits.pyk"
        source.write_text(SDELAY_PROGRAM)
        ran = subprocess.run(compiler + ["compile", "-t", "web2024", str(source)], cwd=workdir,
                             capture_output=True, text=True, timeout=TIMEOUT)
        said = " ".join(ran.stderr.split())
        wanted = ("waits.pyk' 12:0-12:9 Module error: 'tinyweb.sdelay' cannot be used on "
                  "target 'web2024': it waits for the page's audio clock")
        if ran.returncode == 0:
            return "it compiled for web"
        if wanted not in said:
            return f"it did not say `{wanted}`:\n{ran.stderr[-1500:]}"
        ran = subprocess.run(compiler + ["compile", "-t", "iweb", str(source)], cwd=workdir,
                             capture_output=True, text=True, timeout=TIMEOUT)
        if ran.returncode != 0:
            return f"it did not compile for iweb:\n{ran.stderr[-1500:]}"
    return None


SDELAY_PAGE = HERE / "tinyweb" / "sdelay.mjs"


def check_sdelay_page():
    """The page's side of `sdelay`, under node with its clock moved by
    hand (tests/tinyweb/sdelay.mjs). -> String?"""
    with tempfile.TemporaryDirectory(prefix="pyk-tinyweb-") as workdir:
        # A module wherever node is told .js files are not.
        page = Path(workdir) / "tinyweb_page.mjs"
        shutil.copyfile(LIB / "tinyweb_page.js", page)
        ran = subprocess.run(NODE + [str(SDELAY_PAGE), str(page)], capture_output=True,
                             text=True, timeout=TIMEOUT)
    if ran.returncode != 0:
        return (ran.stdout + ran.stderr)[-2000:]
    return None


# --- standalone ---

sys.path.insert(0, str(ROOT / "tools" / "site"))
import tinywebdoc  # noqa: E402

STANDALONE_CASE = HERE / "lib_tinyweb_sound_graphics1"


# Every target a program is compiled for, by one version of each family.
DEFAULT_TARGETS = ["python12", "node22", "web2020", "iweb2020", "c89", "java21", "ocaml4.14"]


def check_default_output(compiler, target):
    """Compiles lib_tinyweb_frames.pyk for target with no --output, in an
    empty directory, and answers what is wrong with what that wrote.
    [String] -> String -> String?"""
    with tempfile.TemporaryDirectory(prefix="pyk-tinyweb-") as workdir:
        ran = subprocess.run(
            compiler + ["compile", "-t", target, str(HERE / "lib_tinyweb_frames.pyk")],
            cwd=workdir, capture_output=True, text=True, timeout=TIMEOUT)
        if ran.returncode != 0:
            return (ran.stderr or ran.stdout).strip()
        wanted = sorted(p.name for p in (LIB / "tinyweb_assets").iterdir()
                        if p.is_file() and not p.name.startswith("."))
        found = Path(workdir) / "build" / "tinyweb_assets"
        got = sorted(p.name for p in found.iterdir()) if found.is_dir() else []
        return None if got == wanted else f"tinyweb_assets/ holds {got}, expected {wanted}"


def standalone_builds(language, workdir):
    """The commands that build a language's example, in the directory
    holding the library and the example. -> [[String]]"""
    ocaml = os.environ.get("OCAMLOPT", "ocamlopt").split()
    c = os.environ.get("CC", "cc").split()
    if language.slug == "ocaml":
        return [ocaml + ["-w", "+a-70", "-I", "+unix", "unix.cmxa", "tinyweb.mli", "tinyweb.ml",
                         "example.ml", "-o", "example"]]
    if language.slug == "c":
        # The header is included into the library too, so the compiler
        # holds the two to one set of declarations.
        return [c + ["-std=c89", "-pedantic", "-Wall", "-include", "tinyweb.h", "-c",
                     "tinyweb.c"],
                c + ["-std=c89", "-pedantic", "-Wall", "-o", "example", "example.c",
                     "tinyweb.o"]]
    if language.slug == "java":
        return [[os.environ.get("JAVAC", "javac"), "-d", ".", "Tinyweb.java", "Example.java"]]
    return []


def standalone_run(language):
    if language.slug == "python":
        return [sys.executable, "example.py"]
    if language.slug == "javascript":
        return NODE + ["example.js"]
    if language.slug == "java":
        return [os.environ.get("JAVA", "java"), "-cp", ".", "Example"]
    return ["./example"]


def check_standalone(language):
    """One language's published library and example, built and run with
    no page. -> String?"""
    with tempfile.TemporaryDirectory(prefix="pyk-tinyweb-") as workdir:
        for name, text in tinywebdoc.library_files(language).items():
            (Path(workdir) / name).write_text(text)
        shutil.copyfile(tinywebdoc.EXAMPLES / language.example, Path(workdir) / language.example)
        for command in standalone_builds(language, workdir):
            built = subprocess.run(command, cwd=workdir, capture_output=True, text=True,
                                   timeout=TIMEOUT)
            if built.returncode != 0 or (language.slug in ("c", "ocaml") and built.stderr):
                return f"{' '.join(command)}:\n{built.stderr[-2000:]}"
        shutil.copyfile(STANDALONE_CASE.with_suffix(".events"), Path(workdir) / "events")
        env = dict(os.environ, PYKING_TINYWEB_LOG="page.log", PYKING_TINYWEB_EVENTS="events")
        ran = subprocess.run(standalone_run(language), cwd=workdir, env=env,
                             capture_output=True, text=True, timeout=TIMEOUT,
                             stdin=subprocess.DEVNULL)
        if ran.returncode != 0:
            return f"it ended with status {ran.returncode}:\n{ran.stderr[-2000:]}"
        if ran.stdout != STANDALONE_CASE.with_suffix(".out").read_text():
            return f"it printed\n{ran.stdout}"
        log = (Path(workdir) / "page.log").read_text()
        if log != STANDALONE_CASE.with_suffix(".page").read_text():
            return f"it logged\n{log}\nwhere {STANDALONE_CASE.name}.page says otherwise"
    return None


# --- in a browser ---

DRIVER = HERE / "tinyweb" / "drive.mjs"
NODE = ["node", "--no-experimental-detect-module"]


def page_compiled(compiler, target, directory, stem):
    """Compiles `stem.pyk` for a page target so that `directory` holds
    program.html and everything beside it: `pyk compile` writes into
    build/ beside the name it is given, whose files are moved up.
    -> CompletedProcess"""
    ran = subprocess.run(compiler + ["compile", "-t", target, "-o", str(directory / "program"),
                                     str(stem.with_suffix(".pyk"))],
                         capture_output=True, text=True, timeout=TIMEOUT)
    build = directory / "build"
    if ran.returncode == 0 and build.is_dir():
        for path in build.iterdir():
            shutil.move(str(path), str(directory / path.name))
        build.rmdir()
    return ran


def builds(compiler, stem, workdir):
    """The program compiled for web2020 twice, into two directories: once
    as the target builds it, with tinyweb_external_browser.js drawing
    directly, and once with tinyweb_external_interpreter.js and
    tinyweb_page.js in its place -- what iweb and the playground run.
    -> ((Path, Path)?, String?)"""
    direct, commands = Path(workdir) / "direct", Path(workdir) / "commands"
    direct.mkdir()
    ran = page_compiled(compiler, "web2020", direct, stem)
    if ran.returncode != 0:
        return None, ran.stderr
    shutil.copytree(direct, commands)
    shutil.copyfile(LIB / "tinyweb_external_interpreter.js", commands / "tinyweb_external.js")
    shutil.copyfile(LIB / "tinyweb_page.js", commands / "tinyweb_page.js")
    for d in (direct, commands):
        (d / "package.json").write_text('{\n  "type": "module"\n}\n')
    return (direct, commands), None


def first_difference(a, b):
    """Where two recordings part, as a few lines of each. -> String"""
    at = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
    show = lambda r: "\n    ".join(r[max(0, at - 3):at + 4])  # noqa: E731
    return (f"they part at line {at + 1}:\n  drawing directly:\n    {show(a)}"
            f"\n  through commands:\n    {show(b)}")


def check_fake_page(compiler, case):
    """One program run both ways against tests/tinyweb/dom.mjs's page.
    -> String?"""
    stem, _, _, expected_out = case
    with tempfile.TemporaryDirectory(prefix="pyk-tinyweb-") as workdir:
        built, problem = builds(compiler, stem, workdir)
        if built is None:
            return problem
        recordings = []
        for directory in built:
            ran = subprocess.run(NODE + [str(DRIVER), str(directory),
                                         str(stem.with_suffix(".events"))],
                                 capture_output=True, text=True, timeout=TIMEOUT)
            if ran.returncode != 0:
                return f"{directory.name}: the driver failed:\n{ran.stderr[-2000:]}"
            recordings.append(json.loads(ran.stdout))
        direct, commands = recordings
        if direct["record"] != commands["record"]:
            return first_difference(direct["record"], commands["record"])
        if direct["stdout"] != commands["stdout"]:
            return (f"drawing directly it printed\n{direct['stdout']}\n"
                    f"and through commands\n{commands['stdout']}")
        if direct["stdout"] != expected_out.rstrip("\n"):
            return f"it printed\n{direct['stdout']}\nwhere the .out file says\n{expected_out}"
    return None


CHROME_DRIVER = HERE / "tinyweb" / "chrome.mjs"
# Every native target serves the one page and speaks the one protocol,
# which `served` checks on each; in a browser, two servers stand for
# them: one answering on a thread of its own, one from a select loop
# once the top level has ended.
CHROMIUM_SERVED_TARGETS = ["python12", "interpret"]
# What a case's recording must hold, in this order, where the three
# pages could agree by all leaving it out: a picture drawn at the top
# level, before it has loaded, and what is drawn after it.
CHROMIUM_DRAWS = {
    "lib_tinyweb_image_top": ["drawImage(tile.png, 0, 0, 200, 100)", "rect(20, 20, 60, 30)",
                              "drawImage(star.png, 100, 10, 50, 50)", "arc(170, 70, 15,"],
}
def marked(page):
    """A page whose module script says when its program's top level has
    ended, which the driver waits for. Path -> ()"""
    text = page.read_text()
    page.write_text(text.replace("</script>", "globalThis.__pykDone = true;\n</script>", 1))


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


def check_chromium(compiler, chromium, case):
    """One program as three pages in a real Chromium -- web drawing
    directly, web through commands, and iweb, where the interpreter
    runs it -- held to one recording. -> String?"""
    stem, _, _, expected_out = case
    with tempfile.TemporaryDirectory(prefix="pyk-tinyweb-") as workdir:
        built, problem = builds(compiler, stem, workdir)
        if built is None:
            return problem
        interpreted = Path(workdir) / "interpreted"
        interpreted.mkdir()
        ran = page_compiled(compiler, "iweb2020", interpreted, stem)
        if ran.returncode != 0:
            return ran.stderr
        pages = list(built) + [interpreted]
        for directory in pages:
            marked(directory / "program.html")
        handler = lambda *a, **k: Quiet(*a, directory=workdir, **k)  # noqa: E731
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            port = server.server_address[1]
            urls = [f"http://127.0.0.1:{port}/{d.name}/program.html" for d in pages]
            ran = suite.run_with_progress(
                NODE + [str(CHROME_DRIVER), chromium, str(stem.with_suffix(".events"))] + urls,
                f"{stem.name}.pyk in Chromium", 600)
        finally:
            server.shutdown()
            server.server_close()
        if ran.returncode != 0:
            return f"the Chromium driver failed:\n{ran.stderr[-2000:]}"
        recordings = json.loads(ran.stdout)
        for directory, recording in zip(pages, recordings):
            if "error" in recording:
                return f"{directory.name}: {recording['error']}"
        wanted = CHROMIUM_DRAWS.get(stem.name, [])
        lines = iter(recordings[0]["record"])
        for draw in wanted:
            if not any(draw in line for line in lines):
                return f"drawing directly: no {draw} where it belongs"
        names = ["drawing directly", "through commands", "interpreted"]
        for name, recording in zip(names[1:], recordings[1:]):
            if recording["record"] != recordings[0]["record"]:
                return (f"{name}: " + first_difference(recordings[0]["record"], recording["record"]))
        for name, recording in zip(names, recordings):
            if recording["stdout"] != expected_out.rstrip("\n"):
                return (f"{name}, it printed\n{recording['stdout']}\n"
                        f"where the .out file says\n{expected_out}")
    return None


def check_chromium_served(compiler, chromium, case, target):
    """One program run on `target` with its page served, the page opened
    in a real Chromium beside the web page drawing directly, and both
    held to one recording -- what tinyweb_page.html makes of the
    commands that reach it over HTTP. -> String?"""
    stem, _, _, _ = case
    with tempfile.TemporaryDirectory(prefix="pyk-tinyweb-") as workdir:
        built, problem = builds(compiler, stem, workdir)
        if built is None:
            return problem
        direct = built[0]
        marked(direct / "program.html")
        handler = lambda *a, **k: Quiet(*a, directory=workdir, **k)  # noqa: E731
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        program = Served(served_command(compiler, stem, target, workdir), workdir)
        try:
            port = program.address()
            if port is None:
                return "it printed no address:\n" + "".join(program.errors)[-2000:]
            urls = [f"http://127.0.0.1:{server.server_address[1]}/direct/program.html",
                    f"served:http://127.0.0.1:{port}/"]
            ran = suite.run_with_progress(
                NODE + [str(CHROME_DRIVER), chromium, str(stem.with_suffix(".events"))] + urls,
                f"{stem.name}.pyk served on {target}, in Chromium", 600)
        finally:
            program.stop()
            server.shutdown()
            server.server_close()
        if ran.returncode != 0:
            return f"the Chromium driver failed:\n{ran.stderr[-2000:]}"
        recordings = json.loads(ran.stdout)
        for name, recording in zip(("drawing directly", "served"), recordings):
            if "error" in recording:
                return f"{name}: {recording['error']}"
        if recordings[1]["record"] != recordings[0]["record"]:
            return "served: " + first_difference(recordings[0]["record"], recordings[1]["record"])
    return None


# --- the suite ---

def main(argv):
    compiler = [str(ROOT / "pyk")]
    only = None
    percent, seed, rest = suite.sample_flags(argv)

    def sampled(items, label):
        """`--sample`'s share of one part's checks. [a] -> String -> [a]"""
        return suite.sample(items, percent, seed, label)

    while rest:
        flag = rest.pop(0)
        if flag == "--compiler" and rest:
            compiler = shlex.split(rest.pop(0))
        elif flag == "--only" and rest:
            only = rest.pop(0)
        else:
            print("usage: test_tinyweb.py [--compiler CMD] [--only PART] "
                  "[--sample PERCENT [--seed N]]", file=sys.stderr)
            return 2
    results = []

    def record(result):
        """Keeps one check's (name, problem) and prints it now, so a long
        run shows how far it has got. (String, String?) -> ()"""
        name, problem = result
        results.append(result)
        if problem is None:
            print(f"tinyweb: {name} OK.", flush=True)
        else:
            print(f"tinyweb: {name} FAILED\n"
                  + "\n".join("    " + l for l in problem.splitlines()), flush=True)

    if percent is not None:
        print(f"tinyweb: {percent:g}% of each part's checks, seed {seed}.", flush=True)
    if only in (None, "embedded"):
        for result in check_embedded():
            record(result)
    if only in (None, "refused"):
        for target, (what, body, message) in sampled(
                [(t, r) for t in SERVED_TARGETS for r in REFUSALS], "refused"):
            try:
                problem = check_refused(compiler, target, body, message)
            except Exception as error:  # noqa: BLE001 -- reported, not raised
                problem = f"{type(error).__name__}: {error}"
            record((f"a program that {what} on {target}", problem))
    if only in (None, "served") or (only or "").startswith("served:"):
        targets = SERVED_TARGETS
        if only and only.startswith("served:"):
            targets = [only.split(":", 1)[1]]
        for case, target in sampled(
                [(c, t) for c in page_cases() for t in targets
                 if not excluded(c[0], t)], "served"):
            name = f"{case[0].name}.pyk served on {target}"
            try:
                problem = check_served(compiler, case, target)
            except Exception as error:  # noqa: BLE001 -- reported, not raised
                problem = f"{type(error).__name__}: {error}"
            record((name, problem))
    if only in (None, "sdelay"):
        record(("sdelay on the page, its clock moved by hand", check_sdelay_page()))
        record(("sdelay refused where a program is compiled for web",
                check_sdelay_refused_on_web(compiler)))
        for target in sampled(SERVED_TARGETS, "sdelay"):
            name = f"a click while sdelay waits, served on {target}"
            try:
                problem = check_sdelay_events(compiler, target)
            except Exception as error:  # noqa: BLE001 -- reported, not raised
                problem = f"{type(error).__name__}: {error}"
            record((name, problem))
    if only in (None, "default"):
        for target in sampled(DEFAULT_TARGETS, "default"):
            name = f"compiled for {target} with no --output, the samples come along"
            try:
                problem = check_default_output(compiler, target)
            except Exception as error:  # noqa: BLE001 -- reported, not raised
                problem = f"{type(error).__name__}: {error}"
            record((name, problem))
    if only in (None, "standalone"):
        for language in sampled(tinywebdoc.LANGUAGES, "standalone"):
            name = f"tinyweb for {language.name}, with no Pyking, runs its example"
            try:
                problem = check_standalone(language)
            except Exception as error:  # noqa: BLE001 -- reported, not raised
                problem = f"{type(error).__name__}: {error}"
            record((name, problem))
    skipped = []
    if only in (None, "browser"):
        for case in sampled(drawn_cases(skipped, "on a page under node"), "browser"):
            name = f"{case[0].name}.pyk drawn directly and through commands, on a page under node"
            try:
                problem = check_fake_page(compiler, case)
            except Exception as error:  # noqa: BLE001 -- reported, not raised
                problem = f"{type(error).__name__}: {error}"
            record((name, problem))
    if only in (None, "browser", "chromium"):
        chromium = suite.find_chromium()
        if chromium is None:
            skipped.append("in a real browser: no Chromium found ($PYKING_CHROME, the PATH, "
                           "or Playwright's download)")
        else:
            for case in sampled(drawn_cases(skipped, "in Chromium"), "chromium"):
                name = (f"{case[0].name}.pyk drawn directly, through commands and "
                        f"interpreted, in Chromium")
                try:
                    problem = check_chromium(compiler, chromium, case)
                except Exception as error:  # noqa: BLE001 -- reported, not raised
                    problem = f"{type(error).__name__}: {error}"
                record((name, problem))
            for case, target in sampled(
                    [(c, t) for c in drawn_cases([], "") for t in CHROMIUM_SERVED_TARGETS],
                    "chromium served"):
                name = (f"{case[0].name}.pyk served on {target}, in Chromium, drawn as "
                        f"the web page draws it")
                try:
                    problem = check_chromium_served(compiler, chromium, case, target)
                except Exception as error:  # noqa: BLE001 -- reported, not raised
                    problem = f"{type(error).__name__}: {error}"
                record((name, problem))
    for what in skipped:
        print(f"tinyweb: skipped {what}.")
    failed = sum(1 for _, problem in results if problem is not None)
    suite.footer("tinyweb", len(results) - failed, failed, f"{len(results)} checks")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
