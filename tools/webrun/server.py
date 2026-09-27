#!/usr/bin/env python3
"""What the Pyking web tools share on the Python side: the Python version
check, the downloaded browser libraries, and a small static server that
serves files from where they sit in the source tree, with no build step.
The playground (tools/playground/playground.py) and the notebook
(tools/notebook/notebook.py) are both started through it, and so is
`pyk playground` / `pyk notebook`. See README.md beside this file and
docs/build.md ("The web tools").

Nothing here runs Pyking: the page runs the compiler itself, as the
JavaScript file build/pyking.js. The server only hands out files.

Usage: `make vendor`, or directly:

    python3 tools/webrun/server.py vendor    download Ace and KaTeX

Data structures:
    Site -- what one tool serves: URL prefixes mapped to directories,
      single files, and answers computed per request.
    Handler -- the HTTP handler a Site is served with.

Functions:
    require_python(tool) -- exits with a message below Python 3.14.
    vendor() -- downloads Ace and KaTeX into vendor/.
    vendor_files() -- every vendored file, with the URL it comes from.
    check_vendor(tool) -- exits with a message if vendor/ is incomplete.
    bundle_manifest() -- the compiler bundle's manifest, with its stamp.
    check_bundle(tool) -- exits with a message if build/pyking.js is missing.
    common_site() -- the Site entries every tool shares.
    free_port(start, explicit) -- the port to listen on.
    serve(site, tool, port, explicit, lines) -- serves a Site until Ctrl+C.
    tool_arguments(tool, argv, document) -- parses a tool's command line.
"""

import sys

# The tools say which Python they need before anything else can fail on
# an older one. So this whole file must stay parseable by an old Python:
# no syntax newer than 3.6 anywhere in it.
MINIMUM_PYTHON = (3, 14)


def require_python(tool):
    """Exits with a message when the running Python is older than
    MINIMUM_PYTHON. String -> ()"""
    if sys.version_info[:2] < MINIMUM_PYTHON:
        found = "%d.%d.%d" % sys.version_info[:3]
        wanted = "%d.%d" % MINIMUM_PYTHON
        sys.exit("%s: Python %s or later is required, and this is Python %s "
                 "(%s)." % (tool, wanted, found, sys.executable))


import argparse  # noqa: E402  (after the version check, on purpose)
import functools  # noqa: E402
import hashlib  # noqa: E402
import http.server  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import posixpath  # noqa: E402
import socket  # noqa: E402
import urllib.error  # noqa: E402
import urllib.parse  # noqa: E402
import urllib.request  # noqa: E402
from pathlib import Path  # noqa: E402

HERE = Path(__file__).resolve().parent
ASSETS = HERE / "assets"
VENDOR = HERE / "vendor"
# The tools/ directory's parent: the repository in a checkout, and the
# installation's root in a distribution, which mirrors the same tree.
ROOT = HERE.parent.parent
BUNDLE = ROOT / "build" / "pyking.js"

DEFAULT_PORT = 8000

ACE_VERSION = "1.43.4"
ACE_CDN = ("https://cdn.jsdelivr.net/npm/ace-builds@%s/src-min-noconflict"
           % ACE_VERSION)
# Ace loads modes and themes lazily from its basePath, so every one a page
# may ask for must sit beside ace.js.
ACE_FILES = [
    "ace.js",
    "ext-searchbox.js",
    "mode-python.js",
    "mode-javascript.js",
    "mode-c_cpp.js",
    "mode-java.js",
    "mode-html.js",
    "mode-ocaml.js",
    "mode-sh.js",
    "mode-json.js",
    "theme-tomorrow.js",
    "theme-tomorrow_night.js",
]

KATEX_VERSION = "0.16.22"
KATEX_CDN = "https://cdn.jsdelivr.net/npm/katex@%s/dist" % KATEX_VERSION
KATEX_FONTS = [
    "AMS-Regular", "Caligraphic-Bold", "Caligraphic-Regular", "Fraktur-Bold",
    "Fraktur-Regular", "Main-Bold", "Main-BoldItalic", "Main-Italic",
    "Main-Regular", "Math-BoldItalic", "Math-Italic", "SansSerif-Bold",
    "SansSerif-Italic", "SansSerif-Regular", "Script-Regular",
    "Size1-Regular", "Size2-Regular", "Size3-Regular", "Size4-Regular",
    "Typewriter-Regular",
]
# The stylesheet lists woff2 first, which every browser the page runs in
# takes, so the woff and ttf copies are not fetched.
KATEX_FILES = ["katex.min.js", "katex.min.css"] + [
    "fonts/KaTeX_%s.woff2" % name for name in KATEX_FONTS]

# Set by the test suite, which serves pages it never renders and must run
# without a network: the vendored libraries are then not required.
NO_VENDOR_VARIABLE = "PYKING_WEB_NO_VENDOR"


# --- the vendored libraries ------------------------------------------------


def vendor_files():
    """Every vendored file: (local path, URL). () -> [(Path, String)]"""
    return ([(VENDOR / "ace" / name, ACE_CDN + "/" + name) for name in ACE_FILES]
            + [(VENDOR / "katex" / name, KATEX_CDN + "/" + name)
               for name in KATEX_FILES])


def vendor():
    """Downloads Ace and KaTeX into vendor/, once; a file already present
    is left alone. () -> ()"""
    fetched = 0
    for path, url in vendor_files():
        if path.exists():
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            with urllib.request.urlopen(url) as response:
                path.write_bytes(response.read())
        except urllib.error.URLError as e:
            raise SystemExit(f"vendor: cannot fetch {url}: {e}")
        fetched += 1
    size = sum(p.stat().st_size for p in VENDOR.rglob("*") if p.is_file())
    state = f"downloaded {fetched} files" if fetched else "up to date"
    print(f"vendor: {state} ({size / 1048576:.1f} MB in "
          f"{VENDOR.relative_to(ROOT)}/)")


def check_vendor(tool):
    """Exits with a message when a vendored file is missing, unless the
    test suite said it does not need them. String -> ()"""
    if os.environ.get(NO_VENDOR_VARIABLE):
        return
    missing = [path for path, _ in vendor_files() if not path.exists()]
    if missing:
        raise SystemExit(
            f"{tool}: the browser libraries are not downloaded "
            f"({len(missing)} files missing from {VENDOR}).\n"
            f"  Run `make vendor` in the repository once (it needs the "
            f"network), or `python3 {HERE / 'server.py'} vendor`.")


# --- the compiler bundle ---------------------------------------------------


def bundle_manifest():
    """The manifest the page's compiler worker boots from: the bundle's
    name and a stamp of its bytes, which the page re-reads to notice a
    rebuild under an open tab (pyking-runtime.js, `_checkStamp`).
    () -> Bytes"""
    stamp = _bundle_stamp(BUNDLE.stat().st_mtime_ns, BUNDLE.stat().st_size)
    return json.dumps({"bundle": "pyking.js", "stamp": stamp,
                       "note": "build/pyking.js, built from src/ by dune"},
                      indent=2).encode() + b"\n"


@functools.lru_cache(maxsize=4)
def _bundle_stamp(mtime, size):
    """A hash of the bundle's bytes, worked out once per version of the
    file rather than once per request. Int -> Int -> String"""
    return hashlib.sha256(BUNDLE.read_bytes()).hexdigest()[:16]


def check_bundle(tool):
    """Exits with a message when build/pyking.js is missing. String -> ()"""
    if not BUNDLE.exists():
        raise SystemExit(
            f"{tool}: no compiler bundle at {BUNDLE}.\n"
            f"  `make` in the repository builds it; a distribution ships it.")


# --- serving ---------------------------------------------------------------


class Site:
    """What one tool serves. `mounts` maps a URL prefix ending in `/` to a
    directory, `files` an exact URL path to one file, and `answers` an
    exact URL path to (function giving bytes, content type)."""

    def __init__(self, mounts=None, files=None, answers=None):
        self.mounts = dict(mounts or {})
        self.files = dict(files or {})
        self.answers = dict(answers or {})

    def extended(self, mounts=None, files=None, answers=None):
        """This site with more entries; the new ones win.
        {..} -> {..} -> {..} -> Site"""
        return Site({**self.mounts, **(mounts or {})},
                    {**self.files, **(files or {})},
                    {**self.answers, **(answers or {})})

    def resolve(self, path):
        """The file a URL path names, or None. A path with a `..` or a
        hidden component names nothing. String -> Path?"""
        if path in self.files:
            return self.files[path]
        parts = [p for p in path.split("/") if p]
        if any(p.startswith(".") for p in parts):
            return None
        for prefix in sorted(self.mounts, key=len, reverse=True):
            if path.startswith(prefix):
                rest = posixpath.normpath(path[len(prefix):] or ".")
                if rest.startswith(".."):
                    return None
                return self.mounts[prefix] / rest
        return None


def common_site():
    """What every tool serves: the shared scripts, the vendored libraries
    and the compiler bundle, each at the path the pages expect them.
    () -> Site"""
    return Site(
        mounts={"/webrun/": ASSETS, "/vendor/": VENDOR},
        files={"/pyking/pyking.js": BUNDLE},
        answers={"/pyking/manifest.json": (bundle_manifest, "application/json")},
    )


class Handler(http.server.SimpleHTTPRequestHandler):
    """The stdlib handler, answering from a Site rather than one
    directory, and without a log line per file."""

    # Keep-alive, so the browser does not reopen a connection per file.
    protocol_version = "HTTP/1.1"
    site = Site()

    def log_message(self, *args):
        pass

    def _path(self):
        """The request's URL path, decoded, without the query.
        () -> String"""
        return urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)

    def translate_path(self, path):
        found = self.site.resolve(urllib.parse.unquote(
            urllib.parse.urlsplit(path).path))
        if found is not None and found.is_dir():
            found = found / "index.html"
        # A path that resolves nowhere becomes one that does not exist,
        # which the stdlib answers with a 404.
        return str(found) if found is not None else str(HERE / ".missing")

    def _answer(self, head_only):
        """Answers a computed path; False when the path is not one.
        Bool -> Bool"""
        entry = self.site.answers.get(self._path())
        if entry is None:
            return False
        make, content_type = entry
        body = make()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head_only:
            self.wfile.write(body)
        return True

    def do_GET(self):
        if not self._answer(False):
            super().do_GET()

    def do_HEAD(self):
        if not self._answer(True):
            super().do_HEAD()

    def end_headers(self):
        # The vendored libraries are version-pinned, so they cache;
        # everything else is served from the source tree and must not, or
        # an edit is debugged against the previous copy.
        if self._path().startswith("/vendor/"):
            self.send_header("Cache-Control", "public, max-age=86400")
        else:
            self.send_header("Cache-Control", "no-store")
        super().end_headers()


def free_port(start, explicit):
    """The port to listen on: `start` itself when it was asked for
    explicitly, else the first free one at or after it.
    Int -> Bool -> Int"""
    tries = 1 if explicit else 20
    for port in range(start, start + tries):
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(("127.0.0.1", port))
                return port
            except OSError:
                continue
    if explicit:
        raise SystemExit(f"serve: port {start} is in use")
    raise SystemExit(f"serve: no free port in {start}..{start + tries - 1}")


def serve(site, tool, port, explicit, lines=()):
    """Serves a Site on localhost and prints a URL the terminal will turn
    into a link, until Ctrl+C. Site -> String -> Int -> Bool -> [String]
    -> ()"""
    port = free_port(port, explicit)
    handler = type("SiteHandler", (Handler,), {"site": site})
    # Threaded, not the stdlib default: a single-threaded server blocks on
    # an idle speculative connection while the page waits for a dozen
    # files including the compiler, which looks like a hang.
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    with http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) as httpd:
        url = f"http://localhost:{port}/"
        print()
        print(f"  {tool} is being served.")
        print()
        print(f"      {url}")
        print()
        for line in lines:
            print(f"  {line}")
        print("  Open that link in a browser (ctrl/cmd-click it in most")
        print("  terminals). Press Ctrl+C to stop.")
        print()
        # serve_forever() never returns, so an unflushed banner would sit
        # in the buffer whenever stdout is a pipe rather than a terminal.
        sys.stdout.flush()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nserve: stopped.")


def tool_arguments(tool, argv, document):
    """Parses a tool's command line: `--port N`, and a document when
    `document` says the tool takes one. String -> [String] -> Bool ->
    Namespace"""
    parser = argparse.ArgumentParser(prog=tool)
    parser.add_argument("--port", type=int, default=None,
                        help=f"the port to serve on (default: {DEFAULT_PORT}, "
                             "or the next free one)")
    if document:
        parser.add_argument("document", help="the Markdown file to open")
    return parser.parse_args(argv)


def main(argv=None):
    """The command-line entry point. [String]? -> ()"""
    require_python("server.py")
    parser = argparse.ArgumentParser(
        prog="server.py", description="The Pyking web tools' shared files.")
    parser.add_argument("command", choices=("vendor",))
    parser.parse_args(argv)
    vendor()


if __name__ == "__main__":
    main()
