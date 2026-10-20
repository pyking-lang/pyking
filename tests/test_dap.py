#!/usr/bin/env python3
"""The debugger's tests: `pyk dap`, the debug adapter, and the same
session core in the browser bundle.

Four parts:

  sessions  each tests/dap/<name>.dap is a session script run against
            `pyk dap` over stdio; what the adapter sent is compared
            with <name>.out.
  transport framing, a message split across writes, --log, the exit
            status, and the command's refusals.
  browser   the same stops through the pykDebug* entries of
            share/pyking.js under node (tests/dap/browser.mjs): every
            stop of a program, its frames and their variables, must be
            what `pyk dap` shows. The playground's Debug tab is
            tests/lsp/playground.mjs's.
  editors   the VS Code extension's debugger, and the website's Editors
            page saying how to start `pyk dap` in each editor.

A script is one step per line; `#` starts a comment. Files are named
relative to tests/dap/.

  env NAME VALUE             set in the adapter's environment (before
                             the first step)
  launch FILE [JSON]         initialize, then launch FILE, JSON adding
                             to the launch arguments
  break FILE [LINE...]       setBreakpoints, plain lines
  breakpoints FILE JSON      setBreakpoints, the breakpoints as JSON
  exceptions [FILTER...]     setExceptionBreakpoints
  configure                  configurationDone
  wait EVENT                 everything up to that event
  stack                      stackTrace
  scopes N                   the scopes of the Nth frame of the last
                             stack, from 1
  variables SCOPE            the variables of a scope of the last scopes
  expand NAME                the parts of a variable of the last
                             variables
  evaluate N TEXT            TEXT evaluated in the Nth frame
  set SCOPE NAME TEXT        setVariable
  continue / next / in / out / pause
  request COMMAND JSON       any request
  disconnect

Usage: python3 tests/test_dap.py [--compiler CMD] [--update]

`--update` rewrites every .out from what `pyk dap` now sends; read the
diffs before keeping them.
"""

import json
import os
import queue
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import suite  # noqa: E402  (after sys.path, which is what makes it findable)

REPO = HERE.parent
CASES = HERE / "dap"
BUNDLE = REPO / "share" / "pyking.js"
LIB = REPO / "lib"
BROWSER = CASES / "browser.mjs"
VSCODE = REPO / "tools" / "editors" / "vscode"
EDITORS_PAGE = REPO / "sitesrc" / "documentation" / "editors.md"
DEFAULT_COMPILER = str(REPO / "pyk")
TIMEOUT = 20

# The programs whose every stop must look the same through `pyk dap` and
# through the browser bundle, each with the lines it has breakpoints on.
PARITY = [("basics.pyk", [5, 11]), ("errors.pyk", [2]), ("closures.pyk", [4, 9])]


# --- running a session -----------------------------------------------------


def frame(text):
    """A message body with its header. String -> Bytes"""
    body = text.encode()
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


def reader(stream, out):
    """Reads framed messages from a stream into a queue, then None at the
    end. Stream -> Queue -> ()"""
    while True:
        header = b""
        while not header.endswith(b"\r\n\r\n"):
            byte = stream.read(1)
            if not byte:
                out.put(None)
                return
            header += byte
        found = re.search(rb"Content-Length: *(\d+)", header, re.I)
        if not found:
            out.put({"unframed": header.decode(errors="replace")})
            continue
        out.put(json.loads(stream.read(int(found.group(1))).decode()))


def start(compiler, environment=None, log=None):
    """Starts `pyk dap` in tests/dap/, with a thread reading what it
    sends. [String] -> {String: String}? -> Path? -> (Popen, Queue)"""
    command = compiler + ["dap"]
    if log is not None:
        command += ["--log", str(log)]
    env = dict(os.environ)
    env.update(environment or {})
    process = subprocess.Popen(command, cwd=CASES, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    messages = queue.Queue()
    threading.Thread(target=reader, args=(process.stdout, messages), daemon=True).start()
    return process, messages


class Session:
    """A conversation with `pyk dap`: requests sent, and every message
    it sent back kept in order."""

    def __init__(self, compiler, environment=None):
        self.process, self.messages = start(compiler, environment)
        self.seq = 0

    def send(self, command, arguments=None):
        """Sends a request; answers its sequence number. String -> {..}? -> Int"""
        self.seq += 1
        message = {"seq": self.seq, "type": "request", "command": command}
        if arguments is not None:
            message["arguments"] = arguments
        try:
            self.process.stdin.write(frame(json.dumps(message)))
            self.process.stdin.flush()
        except BrokenPipeError:
            pass
        return self.seq

    def until(self, done):
        """Every message up to and including the first `done` holds.
        ({..} -> Bool) -> [{..}]"""
        got = []
        deadline = time.monotonic() + TIMEOUT
        while True:
            try:
                message = self.messages.get(timeout=max(0.05, deadline - time.monotonic()))
            except queue.Empty:
                got.append({"timeout": "nothing more arrived"})
                return got
            if message is None:
                got.append({"closed": True})
                return got
            got.append(message)
            if done(message):
                return got

    def request(self, command, arguments=None):
        """Sends a request and answers everything up to its response.
        String -> {..}? -> [{..}]"""
        seq = self.send(command, arguments)
        return self.until(lambda m: m.get("type") == "response" and m.get("request_seq") == seq)

    def close(self):
        """Ends the adapter; answers its exit status. () -> Int?"""
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            return self.process.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            self.process.kill()
            return None


def response_of(got):
    """The response among messages, or an empty one. [{..}] -> {..}"""
    return next((m for m in got if m.get("type") == "response"), {})


def run_script(compiler, path):
    """A script's steps against `pyk dap`: each step's label and what it
    was sent, and the exit status. [String] -> Path -> ([(String,
    [{..}])], Int?)"""
    lines = [line for line in path.read_text().splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    environment = {}
    while lines and lines[0].startswith("env "):
        _, name, value = lines.pop(0).split(" ", 2)
        environment[name] = value
    session = Session(compiler, environment)
    said = []
    frames, scopes, variables = [], [], []
    for line in lines:
        word, _, rest = line.strip().partition(" ")
        got = []
        if word == "launch":
            name, _, extra = rest.partition(" ")
            arguments = {"program": str(CASES / name)}
            arguments.update(json.loads(extra) if extra else {})
            got = session.request("initialize", {"adapterID": "pyking", "linesStartAt1": True,
                                                 "columnsStartAt1": True})
            seq = session.send("launch", arguments)
            got += session.until(lambda m: m.get("type") == "response" and m.get("request_seq") == seq)
            if response_of(got[-1:]).get("success"):
                got += session.until(lambda m: m.get("event") == "initialized")
        elif word == "break":
            name, *rows = rest.split()
            got = session.request("setBreakpoints", {
                "source": {"path": str(CASES / name)},
                "breakpoints": [{"line": int(r)} for r in rows]})
        elif word == "breakpoints":
            name, _, given = rest.partition(" ")
            got = session.request("setBreakpoints", {
                "source": {"path": str(CASES / name)}, "breakpoints": json.loads(given)})
        elif word == "exceptions":
            got = session.request("setExceptionBreakpoints", {"filters": rest.split()})
        elif word == "configure":
            got = session.request("configurationDone")
        elif word == "wait":
            got = session.until(lambda m: m.get("type") == "event" and m.get("event") == rest)
        elif word == "stack":
            got = session.request("stackTrace", {"threadId": 1})
            frames = response_of(got).get("body", {}).get("stackFrames", [])
        elif word == "scopes":
            fid = frames[int(rest) - 1]["id"] if int(rest) <= len(frames) else 0
            got = session.request("scopes", {"frameId": fid})
            scopes = response_of(got).get("body", {}).get("scopes", [])
        elif word == "variables":
            ref = next((s["variablesReference"] for s in scopes if s["name"] == rest), 0)
            got = session.request("variables", {"variablesReference": ref})
            variables = response_of(got).get("body", {}).get("variables", [])
        elif word == "expand":
            ref = next((v["variablesReference"] for v in variables if v["name"] == rest), 0)
            got = session.request("variables", {"variablesReference": ref})
            variables = response_of(got).get("body", {}).get("variables", [])
        elif word == "evaluate":
            n, _, text = rest.partition(" ")
            fid = frames[int(n) - 1]["id"] if int(n) <= len(frames) else 0
            got = session.request("evaluate", {"expression": text, "frameId": fid, "context": "watch"})
        elif word == "set":
            scope, name, text = rest.split(" ", 2)
            ref = next((s["variablesReference"] for s in scopes if s["name"] == scope), 0)
            got = session.request("setVariable", {"variablesReference": ref, "name": name, "value": text})
        elif word in ("continue", "next", "in", "out", "pause"):
            command = {"in": "stepIn", "out": "stepOut"}.get(word, word)
            got = session.request(command, {"threadId": 1})
        elif word == "request":
            command, _, given = rest.partition(" ")
            got = session.request(command, json.loads(given) if given else None)
        elif word == "disconnect":
            got = session.request("disconnect", {})
        else:
            raise ValueError(f"{path.name}: unknown step {word!r}")
        said.append((line.strip(), got))
    status = session.close()
    return said, status


def normalised(text):
    """A message's text with paths made the same on every machine.
    String -> String"""
    text = text.replace(str(CASES), "$CASES").replace(str(LIB), "$LIB")
    text = text.replace(str(REPO), "$REPO")
    return text


def shown(message):
    """One message as a line of a transcript: its sequence numbers left
    out, and the capabilities of `initialize` named rather than listed.
    {..} -> String"""
    message = {k: v for k, v in message.items() if k not in ("seq", "request_seq")}
    return normalised(json.dumps(message, sort_keys=True, ensure_ascii=False))


def transcript(said, status):
    """What a session said, as the text of its .out. [(String, [{..}])]
    -> Int? -> String"""
    text = []
    for label, got in said:
        text.append("> " + label)
        text += [shown(m) for m in got]
    text.append(f"> exit status {status}")
    return "\n".join(text) + "\n"


# --- the same stops in the browser -----------------------------------------


def native_stops(compiler, name, lines):
    """Every stop of a program at breakpoints through `pyk dap`: the
    reason, and each frame's name and line with its scopes' variables.
    [String] -> String -> [Int] -> [{..}]"""
    session = Session(compiler)
    session.request("initialize", {"adapterID": "pyking"})
    seq = session.send("launch", {"program": str(CASES / name)})
    session.until(lambda m: m.get("request_seq") == seq)
    session.request("setBreakpoints", {"source": {"path": str(CASES / name)},
                                       "breakpoints": [{"line": n} for n in lines]})
    session.request("configurationDone")
    stops = []
    for _ in range(50):
        got = session.until(lambda m: m.get("event") in ("stopped", "terminated"))
        last = got[-1]
        if last.get("event") != "stopped":
            break
        stop = {"reason": last["body"]["reason"], "frames": []}
        frames = response_of(session.request("stackTrace", {"threadId": 1}))["body"]["stackFrames"]
        for f in frames:
            entry = {"name": f["name"], "line": f["line"], "scopes": {}}
            for s in response_of(session.request("scopes", {"frameId": f["id"]}))["body"]["scopes"]:
                vars_ = response_of(session.request(
                    "variables", {"variablesReference": s["variablesReference"]}))["body"]["variables"]
                entry["scopes"][s["name"]] = [[v["name"], v["value"], v["type"]] for v in vars_]
            stop["frames"].append(entry)
        stops.append(stop)
        session.request("continue", {"threadId": 1})
    session.request("disconnect", {})
    session.close()
    return stops


def browser_stops(name, lines):
    """The same through the browser bundle under node.
    String -> [Int] -> [{..}]"""
    result = subprocess.run(
        ["node", str(BROWSER), str(BUNDLE), str(LIB), str(CASES / name), json.dumps(lines)],
        capture_output=True, text=True, timeout=TIMEOUT * 3)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip()[-500:])
    return json.loads(result.stdout)


# --- the transport ---------------------------------------------------------


def check_transport(compiler):
    """`pyk dap` as a process: framing, a split message, --log, the exit
    status, a program's output kept off the protocol, and the refusals.
    [String] -> (Int, [String])"""
    failures, checks = [], 0

    def check(label, ok, detail=""):
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(label + (f": {detail}" if detail else ""))

    initialize = json.dumps({"seq": 1, "type": "request", "command": "initialize",
                             "arguments": {"adapterID": "pyking"}})
    with tempfile.TemporaryDirectory(prefix="pyk-dap-") as directory:
        log = Path(directory) / "dap.log"
        process, messages = start(compiler, log=log)
        whole = frame(initialize)
        process.stdin.write(whole[:10])
        process.stdin.flush()
        time.sleep(0.3)
        process.stdin.write(whole[10:])
        process.stdin.flush()
        first = messages.get(timeout=TIMEOUT)
        check("a message split across two writes is read whole",
              isinstance(first, dict) and first.get("command") == "initialize"
              and first.get("success") and "supportsConfigurationDoneRequest" in first.get("body", {}),
              str(first)[:200])
        disconnect = json.dumps({"seq": 2, "type": "request", "command": "disconnect"})
        process.stdin.write(b"content-length: %d\r\n\r\n" % len(disconnect) + disconnect.encode())
        process.stdin.flush()
        second = messages.get(timeout=TIMEOUT)
        check("a header in lower case is read, and disconnect is answered",
              isinstance(second, dict) and second.get("command") == "disconnect", str(second)[:200])
        status = process.wait(timeout=TIMEOUT)
        check("disconnect ends with status 0", status == 0, f"status {status}")
        logged = log.read_text() if log.exists() else ""
        check("--log records what came in and what went out",
              '--> {"seq": 1' in logged and '<-- {"seq":1' in logged, logged[:200])

    session = Session(compiler)
    session.request("initialize", {"adapterID": "pyking"})
    seq = session.send("launch", {"program": str(CASES / "noisy.pyk")})
    session.until(lambda m: m.get("request_seq") == seq)
    session.request("configurationDone")
    got = session.until(lambda m: m.get("event") == "terminated")
    check("what a program writes, by print and by io.write, arrives as output, in order",
          "".join(m["body"]["output"] for m in got if m.get("event") == "output"
                  and m["body"]["category"] == "stdout") == "one\ntwo three\nfour\n",
          [m.get("body") for m in got if m.get("event") == "output"])
    check("nothing but framed messages is written",
          all("unframed" not in m for m in got), got[-1])
    session.request("disconnect", {})
    session.close()

    process, _ = start(compiler)
    process.stdin.close()
    status = process.wait(timeout=TIMEOUT)
    check("the editor going away ends the adapter", status is not None, f"status {status}")

    for label, arguments, expected in [
            ("a file is refused", ["dap", "main.pyk"], "takes no filename"),
            ("--stdio is accepted", ["dap", "--stdio", "x"], "takes no filename"),
            ("--port is refused", ["dap", "--port", "8000"], "--port only applies"),
            ("arguments after -- are refused", ["dap", "--", "a"], "runs none")]:
        result = subprocess.run(compiler + arguments, cwd=CASES, capture_output=True, text=True,
                                timeout=TIMEOUT, stdin=subprocess.DEVNULL)
        output = result.stdout + result.stderr
        check(f"`pyk {' '.join(arguments)}`: {label}",
              result.returncode != 0 and expected in " ".join(output.split()),
              output.strip()[:200])
    return checks, failures


# --- the editors -----------------------------------------------------------


def check_editors():
    """The VS Code extension's debugger and the website's instructions.
    () -> (Int, [String])"""
    failures, checks = [], 0

    def check(label, ok, detail=""):
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(label + (f": {detail}" if detail else ""))

    manifest = json.loads((VSCODE / "package.json").read_text())
    debuggers = manifest.get("contributes", {}).get("debuggers", [])
    pyking = next((d for d in debuggers if d.get("type") == "pyking"), None)
    check("the VS Code extension contributes a `pyking` debugger", pyking is not None,
          json.dumps(debuggers)[:200])
    if pyking:
        properties = pyking.get("configurationAttributes", {}).get("launch", {}).get("properties", {})
        for name in ("program", "args", "stdin", "stopOnEntry", "justMyCode"):
            check(f"its launch configuration takes `{name}`", name in properties)
        check("it offers a launch configuration to start from",
              any(c.get("type") == "pyking" for c in pyking.get("initialConfigurations", [])))
    check("it is started on the debugger's activation event",
          "onDebugResolve:pyking" in manifest.get("activationEvents", [])
          or "onDebug" in manifest.get("activationEvents", []),
          manifest.get("activationEvents"))
    script = (VSCODE / "extension.js").read_text()
    check("the extension starts `pyk dap` as the debug adapter",
          "DebugAdapterExecutable" in script and '"dap"' in script)

    page = EDITORS_PAGE.read_text()
    sections = dict(re.findall(r"^## (.+?)\n(.*?)(?=^## |\Z)", page, re.S | re.M))
    for editor in ["VS Code", "Cursor", "Neovim", "Vim", "Emacs", "Sublime Text",
                   "PyCharm and IntelliJ IDEA", "Helix"]:
        body = sections.get(editor, "")
        check(f"the Editors page says how to debug in {editor}",
              "pyk dap" in body or ('"dap"' in body and "pyk" in body) or "'dap'" in body
              or "Pyking: Debug" in body or "debugger" in body.lower(), editor)
    return checks, failures


# --- the command line ------------------------------------------------------


def parse_args(argv):
    """`--compiler CMD` and `--update`. [String] -> ([String], Bool)"""
    compiler, update = [DEFAULT_COMPILER], False
    rest = list(argv)
    while rest:
        flag = rest.pop(0)
        if flag == "--compiler" and rest:
            compiler = shlex.split(rest.pop(0))
        elif flag == "--update":
            update = True
        else:
            print("usage: test_dap.py [--compiler CMD] [--update]", file=sys.stderr)
            sys.exit(2)
    return compiler, update


def main(argv):
    """Runs the four parts and reports them. [String] -> Int"""
    compiler, update = parse_args(argv)
    passed, failed, skipped = 0, 0, []

    def report(label, ok, detail=""):
        nonlocal passed, failed
        if ok:
            passed += 1
            if label:
                print(f"dap: {label} OK.", flush=True)
        else:
            failed += 1
            print(f"dap: FAILED {label}" + (f": {detail}" if detail else ""))

    scripts = sorted(CASES.glob("*.dap"))
    for script in scripts:
        said, status = run_script(compiler, script)
        text = transcript(said, status)
        golden = script.with_suffix(".out")
        if update:
            golden.write_text(text)
        expected = golden.read_text() if golden.exists() else ""
        if text == expected:
            report(f"{script.name} through `pyk dap`", True)
        else:
            got, want = text.splitlines(), expected.splitlines()
            k = next((k for k in range(max(len(got), len(want)))
                      if k >= len(got) or k >= len(want) or got[k] != want[k]), 0)
            report(f"{script.name} says what {golden.name} does", False,
                   f"line {k + 1}: got {got[k] if k < len(got) else None!r}, "
                   f"expected {want[k] if k < len(want) else None!r}")
    print(f"dap: {len(scripts)} sessions through `pyk dap`.")

    checks, failures = check_transport(compiler)
    for failure in failures:
        report(failure, False)
    for _ in range(checks - len(failures)):
        report("", True)
    print(f"dap: the transport, {checks} checks.")

    if not BUNDLE.exists() or shutil.which("node") is None:
        skipped.append("the browser bundle (no share/pyking.js or no node)")
    else:
        for name, lines in PARITY:
            mine = native_stops(compiler, name, lines)
            try:
                theirs = browser_stops(name, lines)
            except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as e:
                report(f"{name} in the browser bundle", False, str(e)[:300])
                continue
            differ = next((k for k, (a, b) in enumerate(zip(mine, theirs)) if a != b), None)
            report(f"{name} stops the same in the browser bundle ({len(mine)} stops)",
                   mine and differ is None and len(mine) == len(theirs),
                   f"{len(mine)} stops in pyk dap, {len(theirs)} in the bundle" if differ is None
                   else f"stop {differ + 1}: pyk dap {json.dumps(mine[differ])[:300]} "
                        f"but the bundle {json.dumps(theirs[differ])[:300]}")
        print(f"dap: {len(PARITY)} programs through the browser bundle.")

    checks, failures = check_editors()
    for failure in failures:
        report(failure, False)
    for _ in range(checks - len(failures)):
        report("", True)
    print(f"dap: the editors' configuration, {checks} checks.")

    for part in skipped:
        print(f"dap: {part} skipped.")
    suite.footer("dap", passed, failed, f"{len(scripts)} sessions, the transport, the editors")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
