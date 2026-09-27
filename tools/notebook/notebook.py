#!/usr/bin/env python3
"""Serves a Pyking notebook: a Markdown file whose Pyking code blocks run
in the browser. What `pyk notebook FILE.md` starts, and `make notebook`
(on PYKING-TUTORIAL.md). Nothing is built first: the page, the shared
scripts and the compiler bundle are served from where they sit. See
README.md beside this file.

Usage: python3 tools/notebook/notebook.py [--port N] FILE.md

Functions:
    site(document) -- what the notebook serves, for one document.
    main(argv) -- the command-line entry point.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "webrun"))

import server  # noqa: E402  (after sys.path, which is what finds it)

server.require_python("pyk notebook")

import json  # noqa: E402

HERE = Path(__file__).resolve().parent
ASSETS = HERE / "assets"


def site(document):
    """What the notebook serves: the page, its scripts, the document's
    own directory under doc/, and which document to open.
    Path -> server.Site"""
    config = json.dumps({"document": document.name}).encode() + b"\n"
    return server.common_site().extended(
        mounts={"/notebook/": ASSETS, "/doc/": document.parent},
        files={"/": ASSETS / "index.html", "/index.html": ASSETS / "index.html"},
        answers={"/notebook.json": (lambda: config, "application/json")},
    )


def main(argv=None):
    """The command-line entry point. [String]? -> ()"""
    args = server.tool_arguments("pyk notebook", argv, document=True)
    document = Path(args.document).resolve()
    if not document.is_file():
        raise SystemExit(f"pyk notebook: no such file: {args.document}")
    if document.suffix.lower() not in (".md", ".markdown"):
        raise SystemExit(
            f"pyk notebook: {args.document} is not a Markdown file (.md)")
    server.check_bundle("pyk notebook")
    server.check_vendor("pyk notebook")
    port = args.port if args.port is not None else server.DEFAULT_PORT
    server.serve(site(document), "Pyking notebook", port, args.port is not None,
                 [f"Notebook: {document}", ""])


if __name__ == "__main__":
    main()
