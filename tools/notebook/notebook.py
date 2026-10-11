#!/usr/bin/env python3
"""Serves a Pyking notebook: a Markdown file whose Pyking code blocks run
in the browser. What `pyk notebook FILE.md` starts, and `make notebook`
(on PYKING-TUTORIAL.md). Nothing is built first: the page, the shared
scripts and the compiler bundle are served from where they sit. See
README.md beside this file.

`--mode student` (the default) or `--mode teacher` says who the page is
for; `--mode test` serves nothing, and checks the notebook instead with
check.js under node.

Usage: python3 tools/notebook/notebook.py [--port N] [--mode M] FILE.md

Functions:
    site(document, mode) -- what the notebook serves, for one document.
    test(document) -- checks the document, and answers the exit status.
    main(argv) -- the command-line entry point.
"""

import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "webrun"))

import server  # noqa: E402  (after sys.path, which is what finds it)

server.require_python("pyk notebook")

import json  # noqa: E402

HERE = Path(__file__).resolve().parent
ASSETS = HERE / "assets"
CHECK = HERE / "check.js"
MODES = ("student", "teacher", "test")


def site(document, mode="student"):
    """What the notebook serves: the page, its scripts, the document's
    own directory under doc/, and which document to open in which mode.
    Path -> String -> server.Site"""
    config = json.dumps({"document": document.name, "mode": mode}).encode() + b"\n"
    return server.common_site().extended(
        mounts={"/notebook/": ASSETS, "/doc/": document.parent},
        files={"/": ASSETS / "index.html", "/index.html": ASSETS / "index.html"},
        answers={"/notebook.json": (lambda: config, "application/json")},
    )


def test(document):
    """Checks the document with check.js under node, which prints what is
    wrong with it, and answers its exit status. Path -> Int"""
    node = shutil.which("node")
    if node is None:
        raise SystemExit("pyk notebook --mode test runs the notebook's code under node, "
                         "and node was not found.")
    return subprocess.run([node, str(CHECK), str(document), str(server.BUNDLE),
                           str(server.LIB)]).returncode


def main(argv=None):
    """The command-line entry point. [String]? -> ()"""
    args = server.tool_arguments("pyk notebook", argv, document=True, modes=MODES)
    document = Path(args.document).resolve()
    if not document.is_file():
        raise SystemExit(f"pyk notebook: no such file: {args.document}")
    if document.suffix.lower() not in (".md", ".markdown"):
        raise SystemExit(
            f"pyk notebook: {args.document} is not a Markdown file (.md)")
    server.check_bundle("pyk notebook")
    if args.mode == "test":
        if args.port is not None:
            raise SystemExit("pyk notebook: --mode test serves nothing, so it takes no --port")
        sys.exit(test(document))
    server.check_vendor("pyk notebook")
    port = args.port if args.port is not None else server.DEFAULT_PORT
    server.serve(site(document, args.mode), "Pyking notebook", port, args.port is not None,
                 [f"Notebook: {document} ({args.mode} mode)", ""])


if __name__ == "__main__":
    main()
