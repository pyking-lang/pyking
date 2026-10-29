#!/usr/bin/env python3
"""Runs the language server's test cases: `pyk lsp` driven over stdio by
scripted sessions, the same sessions through the server in the browser
bundle, the playground's editor in a real Chromium, and the editors'
configuration. See design/lsp.md, "Testing".

Four parts:

  sessions  every tests/lsp/<name>.lsp script, run against `pyk lsp`;
            what the server sends is compared with tests/lsp/<name>.out.
            Then the transport itself: framing, a message split across
            writes, --log, the exit status, and the command's refusals.
  browser   the same scripts through pykLsp in share/pyking.js under
            node (tests/lsp/browser.mjs), which must answer the same.
  page      where a Chromium is found and `make vendor` has run, the
            playground driven by tests/lsp/playground.mjs: a marker, a
            hover, completion and the outline in its editor, and the
            rest of the page -- its tabs, the REPL, the debugger, the
            settings, Copy for slides read back off the clipboard, and
            every command's keys pressed for real. Skipped otherwise.
  editors   the VS Code extension's manifest and grammar, the Emacs
            mode's eglot entry (where emacs is installed), and the setup
            snippets on the website.

A script is one step per line; `#` starts a comment. Positions are
LINE:COLUMN, both from 1, the column in UTF-16 code units, as an editor
shows them; files are named relative to tests/lsp/.

  initialize [JSON]          initialize (with initializationOptions)
                             and initialized
  open FILE                  didOpen with the file's text
  change FILE                didChange with the text on the lines
                             after it, up to a line holding only `.`
  edit FILE L:C-L:C "TEXT"   didChange replacing a range
  save FILE / close FILE     didSave / didClose
  hover / definition FILE L:C,  complete FILE L:C,  symbols FILE
  config JSON                workspace/didChangeConfiguration
  request METHOD JSON        any request; notify METHOD JSON any
                             notification; $URI(FILE) is a file's URI
  raw TEXT                   TEXT sent as a message body as it is
  idle                       the editor goes quiet: what is published
  shutdown / exit

Usage: python3 tests/test_lsp.py [--compiler CMD] [--update]
                                  [--sample PERCENT [--seed N]]

`--update` rewrites every .out from what `pyk lsp` now sends; read the
diffs before keeping them.

`--sample PERCENT` (`make quicktest`) runs PERCENT of the sessions, and of the
other three parts (the transport, the playground, the editors), at
least one, chosen at random by `--seed N`.

Functions:
    parse_script(path) -- a script as steps.
    run_native(compiler, steps) -- the steps through `pyk lsp`.
    run_browser(steps) -- the steps through the browser bundle.
    transcript(script, events) -- what a session said, as .out text.
    check_transport(compiler) -- the framing and the command.
    check_editors() -- the editors' configuration.
    main(argv) -- the command-line entry point.
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

import suite  # noqa: E402  (after sys.path, which is what finds it)

REPO = HERE.parent
CASES = HERE / "lsp"
BUNDLE = REPO / "share" / "pyking.js"
LIB = REPO / "lib"
BROWSER = CASES / "browser.mjs"
PAGE_DRIVER = CASES / "playground.mjs"
MONACO = REPO / "tools" / "webrun" / "vendor" / "monaco"
VSCODE = REPO / "tools" / "editors" / "vscode"
EMACS_MODE = REPO / "tools" / "emacs" / "pyking-mode.el"
EDITORS_PAGE = REPO / "sitesrc" / "documentation" / "editors.md"
DEFAULT_COMPILER = str(REPO / "pyk")
# Where the compilers under test are installed: the standard library
# beside each is named $LIB in what a session said.
ROOTS = []
# How long the server must have been quiet before `idle` takes what it
# published: twice its own 200 ms, with room for a loaded machine.
QUIET = 0.6
TIMEOUT = 20
# How long a step sending no request waits for the one answer a raw
# message may get: the server answers at once, and most get none.
RAW_WAIT = 3


# --- scripts ---------------------------------------------------------------


def uri(name):
    """The URI of a file under tests/lsp/. String -> String"""
    return (CASES / name).as_uri()


def position(text):
    """An LSP position from LINE:COLUMN, both from 1. String -> {..}"""
    line, column = text.split(":")
    return {"line": int(line) - 1, "character": int(column) - 1}


def parse_script(path):
    """A script as steps: each {label, send: [message text], requests:
    [id], idle}. Path -> [{..}]"""
    lines = path.read_text().splitlines()
    steps, versions, next_id = [], {}, 1
    k = 0

    def request(method, params):
        nonlocal next_id
        message = {"jsonrpc": "2.0", "id": next_id, "method": method}
        if params is not None:
            message["params"] = params
        next_id += 1
        return message

    def notification(method, params):
        return {"jsonrpc": "2.0", "method": method, "params": params}

    def document(name):
        return {"uri": uri(name)}

    while k < len(lines):
        line = lines[k]
        k += 1
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        word, _, rest = line.strip().partition(" ")
        rest = re.sub(r"\$URI\(([^)]*)\)", lambda m: uri(m.group(1)), rest)
        messages, idle = [], False
        if word == "initialize":
            options = json.loads(rest) if rest else None
            params = {"processId": None, "rootUri": CASES.as_uri(), "capabilities": {}}
            if options is not None:
                params["initializationOptions"] = options
            messages = [request("initialize", params), notification("initialized", {})]
        elif word == "open":
            versions[rest] = 1
            messages = [notification("textDocument/didOpen", {"textDocument": {
                "uri": uri(rest), "languageId": "pyking", "version": 1,
                "text": (CASES / rest).read_text()}})]
        elif word == "change":
            body = []
            while lines[k] != ".":
                body.append(lines[k])
                k += 1
            k += 1
            versions[rest] = versions.get(rest, 0) + 1
            messages = [notification("textDocument/didChange", {
                "textDocument": {"uri": uri(rest), "version": versions[rest]},
                "contentChanges": [{"text": "\n".join(body) + "\n"}]})]
        elif word == "edit":
            name, span, text = rest.split(" ", 2)
            start, end = span.split("-")
            versions[name] = versions.get(name, 0) + 1
            messages = [notification("textDocument/didChange", {
                "textDocument": {"uri": uri(name), "version": versions[name]},
                "contentChanges": [{"range": {"start": position(start), "end": position(end)},
                                    "text": json.loads(text)}]})]
        elif word in ("save", "close"):
            method = "textDocument/didSave" if word == "save" else "textDocument/didClose"
            messages = [notification(method, {"textDocument": document(rest)})]
        elif word in ("hover", "definition", "complete"):
            name, at = rest.split(" ")
            method = {"hover": "textDocument/hover", "definition": "textDocument/definition",
                      "complete": "textDocument/completion"}[word]
            messages = [request(method, {"textDocument": document(name), "position": position(at)})]
        elif word == "symbols":
            messages = [request("textDocument/documentSymbol", {"textDocument": document(rest)})]
        elif word == "config":
            messages = [notification("workspace/didChangeConfiguration",
                                     {"settings": json.loads(rest)})]
        elif word == "request":
            method, _, params = rest.partition(" ")
            messages = [request(method, json.loads(params) if params else None)]
        elif word == "notify":
            method, _, params = rest.partition(" ")
            messages = [notification(method, json.loads(params) if params else {})]
        elif word == "raw":
            messages = [rest]
        elif word == "idle":
            idle = True
        elif word == "shutdown":
            messages = [request("shutdown", None)]
        elif word == "exit":
            messages = [{"jsonrpc": "2.0", "method": "exit"}]
        else:
            raise ValueError(f"{path.name}:{k}: unknown step {word!r}")
        steps.append({
            "label": line.strip(),
            "send": [m if isinstance(m, str) else json.dumps(m) for m in messages],
            "requests": [m["id"] for m in messages if isinstance(m, dict) and "id" in m],
            "raw": word == "raw",
            "idle": idle,
        })
    return steps


# --- running a session -----------------------------------------------------


def frame(text):
    """A message body with its header. String -> Bytes"""
    body = text.encode()
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


def reader(stream, out):
    """Reads framed messages from a stream into a queue, then None at the
    end, putting any bytes that are not a framed message as an error.
    Stream -> Queue -> ()"""
    while True:
        header = b""
        while not header.endswith(b"\r\n\r\n"):
            byte = stream.read(1)
            if not byte:
                out.put(None)
                return
            header += byte
        found = re.search(rb"Content-Length: *(\d+)", header)
        if not found:
            out.put({"unframed": header.decode(errors="replace")})
            continue
        out.put(json.loads(stream.read(int(found.group(1))).decode()))


def start(compiler, arguments=(), log=None):
    """Starts `pyk lsp` in tests/lsp/, with a thread reading what it sends.
    [String] -> [String] -> Path? -> (Popen, Queue)"""
    command = compiler + ["lsp", "--stdio"] + list(arguments)
    if log is not None:
        command += ["--log", str(log)]
    process = subprocess.Popen(command, cwd=CASES, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    messages = queue.Queue()
    threading.Thread(target=reader, args=(process.stdout, messages), daemon=True).start()
    return process, messages


def run_native(compiler, steps):
    """The steps through `pyk lsp`: per step, the messages it answered,
    and at the end the exit status. [String] -> [{..}] -> ([[{..}]], Int?)"""
    process, messages = start(compiler)
    answers, held = [], []
    try:
        for step in steps:
            for text in step["send"]:
                process.stdin.write(frame(text))
            process.stdin.flush()
            got, waiting = [], set(step["requests"])
            deadline = time.monotonic() + (TIMEOUT if waiting else RAW_WAIT)
            # Every request is answered; a raw message may be, once.
            while waiting or step["raw"]:
                try:
                    message = messages.get(timeout=max(0.05, deadline - time.monotonic()))
                except queue.Empty:
                    break
                if message is None:
                    break
                if "id" in message and "method" not in message:
                    got.append(message)
                    waiting.discard(message.get("id"))
                    if step["raw"]:
                        break
                else:
                    held.append(message)
            if step["idle"]:
                while True:
                    try:
                        message = messages.get(timeout=QUIET)
                    except queue.Empty:
                        break
                    if message is None:
                        break
                    held.append(message)
                got += held
                held = []
            answers.append(got)
        process.stdin.close()
        status = process.wait(timeout=TIMEOUT)
    except (subprocess.TimeoutExpired, BrokenPipeError):
        process.kill()
        status = None
    return answers, status


def run_browser(steps):
    """The steps through pykLsp in share/pyking.js, under node: per step,
    the messages it answered. [{..}] -> [[{..}]]"""
    result = subprocess.run(
        ["node", str(BROWSER), str(BUNDLE), str(LIB), str(CASES)],
        input=json.dumps([{"send": s["send"], "idle": s["idle"]} for s in steps]),
        capture_output=True, text=True, timeout=TIMEOUT * 3)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip()[-500:])
    return json.loads(result.stdout)


# --- what a session said ---------------------------------------------------


def normalised(text, browser=False):
    """A message's text with paths made the same on every machine: a file
    of the standard library as $LIB/..., one of the cases as $CASES/...
    The browser reads a library module from beside the program, so its
    URIs are mapped the same way. String -> Bool -> String"""
    text = re.sub(r'file://[^"]*?/lib/([A-Za-z_0-9]+)/([^"/]+\.pyk)', r"$LIB/\1/\2", text)
    for root in ROOTS:
        text = text.replace(str(root / "lib"), "$LIB")
    text = text.replace(CASES.as_uri(), "$CASES").replace(str(CASES), "$CASES")
    text = text.replace(str(REPO), "$REPO")
    names = {p.name: f"$LIB/{p.parent.name}/{p.name}" for p in LIB.glob("*/*.pyk")}
    text = re.sub(r"\$CASES/([^\"/]+\.pyk)",
                  lambda m: names.get(m.group(1), m.group(0))
                  if not (CASES / m.group(1)).exists() else m.group(0), text)
    return text


def events(answers, browser=False):
    """What each step was answered, as lines: a response's result or
    error, and at `idle` every document's diagnostics as last published,
    sorted by URI. A version number is left out of an initialize result,
    as the two servers report different ones. [[{..}]] -> Bool -> [[String]]"""
    out = []
    for got in answers:
        lines = []
        published = {}
        for message in got:
            if message.get("method") == "textDocument/publishDiagnostics":
                published[message["params"]["uri"]] = message["params"]
            elif message.get("method") == "window/logMessage":
                lines.append("log " + message["params"]["message"])
            elif "result" in message or "error" in message:
                body = message.get("result", None) if "result" in message else {"error": message["error"]}
                if isinstance(body, dict) and "serverInfo" in body:
                    body = dict(body, serverInfo={"name": body["serverInfo"]["name"]})
                lines.append(json.dumps(body, sort_keys=True, ensure_ascii=False))
        for key in sorted(published):
            params = published[key]
            diagnostics = params["diagnostics"]
            if browser:
                # A missing module is described by where it was looked
                # for, which is a different list in a page.
                diagnostics = [dict(d, message="(module error)") if d.get("code") == "Module error"
                               else d for d in diagnostics]
            lines.append(f"diagnostics {key} v{params.get('version')} "
                         + json.dumps(diagnostics, sort_keys=True, ensure_ascii=False))
        out.append([normalised(line, browser) for line in lines])
    return out


def transcript(steps, said, status):
    """What a session said, as the text of its .out: each step, then what
    it was answered. [{..}] -> [[String]] -> Int? -> String"""
    text = []
    for step, lines in zip(steps, said):
        text.append("> " + step["label"])
        text += lines
    text.append(f"> exit status {status}")
    return "\n".join(text) + "\n"


def without_module_messages(said):
    """A native session's lines with a missing module's message hidden,
    as `events` hides it for the browser. [[String]] -> [[String]]"""
    def hide(line):
        if not line.startswith("diagnostics "):
            return line
        head, _, body = line.partition(" [")
        diagnostics = json.loads("[" + body)
        diagnostics = [dict(d, message="(module error)") if d.get("code") == "Module error"
                       else d for d in diagnostics]
        return head + " " + json.dumps(diagnostics, sort_keys=True, ensure_ascii=False)
    return [[hide(line) for line in lines] for lines in said]


# --- the transport ---------------------------------------------------------


def check_transport(compiler):
    """`pyk lsp` as a process: framing, a split message, two in one write,
    --log, the exit status with and without shutdown, and the refusals.
    [String] -> (Int, [String])"""
    failures, checks = [], 0

    def check(label, ok, detail=""):
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(label + (f": {detail}" if detail else ""))

    initialize = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
    shutdown = json.dumps({"jsonrpc": "2.0", "id": 2, "method": "shutdown"})
    exit_ = json.dumps({"jsonrpc": "2.0", "method": "exit"})

    with tempfile.TemporaryDirectory(prefix="pyk-lsp-") as directory:
        log = Path(directory) / "lsp.log"
        process, messages = start(compiler, log=log)
        whole = frame(initialize)
        process.stdin.write(whole[:10])
        process.stdin.flush()
        time.sleep(0.3)
        process.stdin.write(whole[10:])
        process.stdin.flush()
        first = messages.get(timeout=TIMEOUT)
        check("a message split across two writes is read whole",
              isinstance(first, dict) and first.get("id") == 1 and "capabilities" in first.get("result", {}),
              str(first)[:200])
        process.stdin.write(b"content-length: %d\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n"
                            % len(shutdown.encode()) + shutdown.encode() + frame(exit_))
        process.stdin.flush()
        second = messages.get(timeout=TIMEOUT)
        check("a header in lower case, beside another header, is read",
              isinstance(second, dict) and second.get("id") == 2, str(second)[:200])
        status = process.wait(timeout=TIMEOUT)
        check("shutdown, then exit, in one write, ends with status 0", status == 0, f"status {status}")
        check("nothing but framed messages is written",
              messages.get(timeout=TIMEOUT) is None)
        logged = log.read_text() if log.exists() else ""
        check("--log records what came in and what went out",
              '--> {"jsonrpc": "2.0", "id": 1' in logged and '<-- {"jsonrpc":"2.0","id":1' in logged,
              logged[:200])

    process, messages = start(compiler)
    process.stdin.write(frame(initialize))
    process.stdin.close()
    status = process.wait(timeout=TIMEOUT)
    check("the editor going away without shutdown ends with status 1", status == 1, f"status {status}")

    for label, arguments, expected in [
            ("a file is refused", ["lsp", "main.pyk"], "takes no filename"),
            ("--log is refused for anything but lsp", ["repl", "--log", "x"], "only applies to 'pyk lsp'"),
            ("--stdio is refused for anything but lsp", ["main.pyk", "--stdio"], "--stdio"),
            ("arguments after -- are refused", ["lsp", "--", "a"], "runs none")]:
        result = subprocess.run(compiler + arguments, cwd=CASES, capture_output=True, text=True,
                                timeout=TIMEOUT, stdin=subprocess.DEVNULL)
        output = result.stdout + result.stderr
        check(f"`pyk {' '.join(arguments)}`: {label}",
              result.returncode != 0 and expected in " ".join(output.split()),
              output.strip()[:200])
    return checks, failures


# --- the editors -----------------------------------------------------------


def lexer_keywords():
    """The keywords src/lexer.ml lists. () -> {String}"""
    source = (REPO / "src" / "lexer.ml").read_text()
    block = re.search(r"let keywords\s*=\s*\[(.*?)\]", source, re.S)
    return set(re.findall(r'"([^"]+)"', block.group(1))) if block else set()


def check_editors():
    """The VS Code extension, the Emacs mode and the website's snippets.
    () -> (Int, [String], [String])"""
    failures, skipped, checks = [], [], 0

    def check(label, ok, detail=""):
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(label + (f": {detail}" if detail else ""))

    manifest = json.loads((VSCODE / "package.json").read_text())
    languages = manifest.get("contributes", {}).get("languages", [])
    check("the VS Code extension says .pyk is Pyking",
          any(l.get("id") == "pyking" and ".pyk" in l.get("extensions", []) for l in languages))
    settings = manifest.get("contributes", {}).get("configuration", {}).get("properties", {})
    check("it starts `pyk lsp` by default",
          settings.get("pyking.server.path", {}).get("default") == "pyk"
          and settings.get("pyking.server.args", {}).get("default") == ["lsp"],
          json.dumps({k: v.get("default") for k, v in settings.items()}))
    check("it offers the libPath and diagnostics settings",
          "pyking.libPath" in settings and "pyking.diagnostics" in settings)
    grammar = json.loads((VSCODE / "syntaxes" / "pyking.tmLanguage.json").read_text())
    words = set(re.findall(r"[a-z_A-Z]+", json.dumps(grammar)))
    missing = sorted(lexer_keywords() - words)
    check("its grammar knows every keyword src/lexer.ml has", lexer_keywords() and not missing,
          ", ".join(missing))
    check("the extension's script names the client library and the server",
          "vscode-languageclient" in (VSCODE / "extension.js").read_text())

    emacs = shutil.which("emacs")
    if emacs is None:
        skipped.append("the Emacs mode's eglot entry (no emacs)")
    else:
        result = subprocess.run(
            [emacs, "--batch", "-Q", "-L", str(EMACS_MODE.parent), "-l", "pyking-mode",
             "--eval", "(progn (require 'eglot) (let ((entry (assoc 'pyking-mode eglot-server-programs)))"
                       " (princ (format \"%S\" (if (functionp (cdr entry)) (funcall (cdr entry) nil)"
                       " (cdr entry))))))"],
            capture_output=True, text=True, timeout=TIMEOUT * 3)
        check("the Emacs mode registers `pyk lsp` with eglot",
              '("pyk" "lsp")' in result.stdout, (result.stdout + result.stderr).strip()[-200:])

    page = EDITORS_PAGE.read_text()
    for editor in ["VS Code", "Cursor", "Neovim", "Vim", "Emacs", "Sublime Text", "Zed",
                   "PyCharm", "Helix"]:
        check(f"the website's Editors page covers {editor}", editor in page)
    blocks = re.findall(r"```(\w*)\n(.*?)```", page, re.S)
    snippets = [body for language, body in blocks if language not in ("", "pyking", "sh", "text")]
    # A snippet naming the command: "pyk" quoted, or `pyk` followed by a
    # word, as a shell or a settings field writes it.
    names = re.compile(r'["\']pyk["\']|(?<![\w-])pyk\s+\w')
    wrong = [body.strip().splitlines()[0] for body in snippets
             if names.search(body) and not re.search(r'["\'\s](lsp|dap)["\'\s]', body)]
    check("every snippet on it that names pyk starts `pyk lsp` or `pyk dap`", snippets and not wrong,
          "; ".join(wrong[:3]))
    return checks, failures, skipped


# --- the command line ------------------------------------------------------


def parse_args(argv):
    """`--compiler CMD`, `--update`, and `--sample PERCENT` with `--seed N`.
    [String] -> ([String], Bool, Number?, Int)"""
    compiler, update = [DEFAULT_COMPILER], False
    percent, seed, rest = suite.sample_flags(argv)
    while rest:
        flag = rest.pop(0)
        if flag == "--compiler" and rest:
            compiler = shlex.split(rest.pop(0))
        elif flag == "--update":
            update = True
        else:
            print("usage: test_lsp.py [--compiler CMD] [--update] "
                  "[--sample PERCENT [--seed N]]", file=sys.stderr)
            sys.exit(2)
    return compiler, update, percent, seed


def main(argv):
    """Runs the four parts and reports them. [String] -> Int"""
    compiler, update, percent, seed = parse_args(argv)
    parts = suite.sample(["transport", "playground", "editors"], percent, seed, "parts")
    if percent is not None:
        print(f"lsp: {percent:g}% of the sessions and of the other parts, seed {seed}: "
              f"{', '.join(parts)}.", flush=True)
    found = shutil.which(compiler[0])
    if found:
        ROOTS.append(Path(os.path.realpath(found)).parent)
    passed, failed, skipped = 0, 0, []

    def report(label, ok, detail=""):
        nonlocal passed, failed
        if ok:
            passed += 1
            if label:
                print(f"lsp: {label} OK.", flush=True)
        else:
            failed += 1
            print(f"lsp: FAILED {label}" + (f": {detail}" if detail else ""))

    scripts = suite.sample(sorted(CASES.glob("*.lsp")), percent, seed, "sessions")
    sessions = {}
    for script in scripts:
        steps = parse_script(script)
        answers, status = run_native(compiler, steps)
        said = events(answers)
        sessions[script] = (steps, said)
        text = transcript(steps, said, status)
        golden = script.with_suffix(".out")
        if update:
            golden.write_text(text)
        expected = golden.read_text() if golden.exists() else ""
        if text == expected:
            report(f"{script.name} through `pyk lsp`", True)
        else:
            got, want = text.splitlines(), expected.splitlines()
            k = next((k for k in range(max(len(got), len(want)))
                      if k >= len(got) or k >= len(want) or got[k] != want[k]), 0)
            report(f"{script.name} says what {golden.name} does", False,
                   f"line {k + 1}: got {got[k] if k < len(got) else None!r}, "
                   f"expected {want[k] if k < len(want) else None!r}")
    print(f"lsp: {len(scripts)} sessions through `pyk lsp`.")

    if "transport" in parts:
        checks, failures = check_transport(compiler)
        for failure in failures:
            report(failure, False)
        for _ in range(checks - len(failures)):
            report("", True)
        print(f"lsp: the transport, {checks} checks.")
    else:
        skipped.append("the transport (not in the sample)")

    if not BUNDLE.exists() or shutil.which("node") is None:
        skipped.append("the browser bundle (no share/pyking.js or no node)")
    else:
        for script, (steps, said) in sessions.items():
            try:
                theirs = events(run_browser(steps), browser=True)
            except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as e:
                report(f"{script.name} in the browser bundle", False, str(e)[:300])
                continue
            # The browser has no `exit` status to report, and is told of
            # no library directory beyond what the page serves.
            mine = without_module_messages(said)
            differ = next((k for k, (a, b) in enumerate(zip(mine, theirs)) if a != b), None)
            report(f"{script.name} answers the same in the browser bundle",
                   differ is None and len(mine) == len(theirs),
                   "" if differ is None else
                   f"step {steps[differ]['label']!r}: pyk lsp {mine[differ]} but the bundle {theirs[differ]}")
        print(f"lsp: {len(sessions)} sessions through the browser bundle.")

    chromium = suite.find_chromium()
    if "playground" not in parts:
        skipped.append("the playground in a browser (not in the sample)")
    elif chromium is None or not MONACO.exists() or not PAGE_DRIVER.exists():
        why = ("no Chromium found" if chromium is None
               else "no vendored Monaco (make vendor)" if not MONACO.exists() else "no driver")
        skipped.append(f"the playground in a browser ({why})")
    else:
        sys.path.insert(0, str(HERE))
        import test_notebook
        port = test_notebook.free_port()
        process, printed = test_notebook.start(
            compiler, ["playground", "--port", str(port)], dict(os.environ))
        if process is None:
            report("the playground starts", False, printed)
        else:
            try:
                ran = suite.run_with_progress(
                    ["node", str(PAGE_DRIVER), chromium, f"http://127.0.0.1:{port}/"],
                    "the playground in Chromium", 600)
                try:
                    result = json.loads(ran.stdout)
                except json.JSONDecodeError:
                    result = {"checks": 1, "failures": [
                        "the driver did not answer: " + (ran.stderr or ran.stdout).strip()[-300:]]}
                for failure in result["failures"]:
                    report(f"playground: {failure}", False)
                for _ in range(result["checks"] - len(result["failures"])):
                    report("", True)
                print(f"lsp: the playground in Chromium, {result['checks']} checks.")
            finally:
                test_notebook.stop(process)

    if "editors" in parts:
        checks, failures, skipped_editors = check_editors()
        skipped += skipped_editors
        for failure in failures:
            report(failure, False)
        for _ in range(checks - len(failures)):
            report("", True)
        print(f"lsp: the editors' configuration, {checks} checks.")
    else:
        skipped.append("the editors' configuration (not in the sample)")

    for part in skipped:
        print(f"lsp: {part} skipped.")
    suite.footer("lsp", passed, failed, f"{len(scripts)} sessions, the transport, the editors")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
