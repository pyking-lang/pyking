#!/usr/bin/env python3
"""What the Pyking web tools share on the Python side: the downloaded
browser libraries, and the Site the website build (tools/site/site.py)
copies the pages' runtime from. The pages are served by `pyk` itself
(src/web_tools.ml, src/web_server.ml), so nothing here is shipped or
needed to run them. See README.md beside this file and docs/build.md
("The web tools").

Nothing here runs Pyking: the page runs the compiler itself, as the
JavaScript file build/pyking.js.

Usage: `make vendor`, or directly:

    python3 tools/webrun/server.py vendor    download Ace, KaTeX and Monaco

Data structures:
    Site -- what one tool serves: URL prefixes mapped to directories,
      single files, and answers computed per request.

Functions:
    vendor() -- downloads Ace, KaTeX and Monaco into vendor/.
    vendor_files() -- every vendored file, with the URL it comes from.
    check_vendor(tool) -- exits with a message if vendor/ is incomplete.
    bundle_manifest() -- the compiler bundle's manifest, with its stamp.
    check_bundle(tool) -- exits with a message if build/pyking.js is missing.
    common_site() -- the Site entries every tool shares.
"""

import argparse
import functools
import hashlib
import json
import os
import posixpath
import shutil
import tarfile
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ASSETS = HERE / "assets"
VENDOR = HERE / "vendor"
# The tools/ directory's parent: the repository in a checkout, and the
# installation's root in a distribution, which mirrors the same tree.
ROOT = HERE.parent.parent
BUNDLE = ROOT / "build" / "pyking.js"
# The standard library, which a program run in the page imports from:
# its Pyking sources, and each module's browser implementation.
LIB = ROOT / "lib"

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

# Monaco, the playground's editor, is fetched as its npm tarball and only
# the prebuilt AMD distribution, package/min/vs/, is kept: the editor loads
# its languages, its workers and its stylesheet from beside loader.js.
MONACO_VERSION = "0.57.0"
MONACO_TARBALL = ("https://registry.npmjs.org/monaco-editor/-/monaco-editor-%s.tgz"
                  % MONACO_VERSION)
MONACO = VENDOR / "monaco"
MONACO_PREFIX = "package/min/vs/"
# What says the distribution is there and complete: two files the page
# loads, and a marker naming the version, written after everything else.
MONACO_FILES = ["vs/loader.js", "vs/editor/editor.main.js",
                "monaco-editor-%s.json" % MONACO_VERSION]

# Set by the test suite, which serves pages it never renders and must run
# without a network: the vendored libraries are then not required.
NO_VENDOR_VARIABLE = "PYKING_WEB_NO_VENDOR"


# --- the vendored libraries ------------------------------------------------


def vendor_files():
    """Every vendored file: (local path, URL). Monaco's are the files
    that say it is there, each with the tarball it comes from.
    () -> [(Path, String)]"""
    return ([(VENDOR / "ace" / name, ACE_CDN + "/" + name) for name in ACE_FILES]
            + [(VENDOR / "katex" / name, KATEX_CDN + "/" + name)
               for name in KATEX_FILES]
            + [(MONACO / name, MONACO_TARBALL) for name in MONACO_FILES])


def vendor():
    """Downloads Ace, KaTeX and Monaco into vendor/, once; a file already
    present is left alone. () -> ()"""
    fetched = 0
    for path, url in vendor_files():
        if path.exists():
            continue
        if url == MONACO_TARBALL:
            fetched += _vendor_monaco()
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


def _vendor_monaco():
    """Downloads Monaco's tarball and unpacks its min/vs/ into
    vendor/monaco/vs/, replacing whatever version was there. It is
    unpacked beside vendor/monaco/ and moved into place whole, so an
    interrupted download leaves nothing that looks complete. Answers how
    many files it wrote. () -> Int"""
    if (MONACO / MONACO_FILES[-1]).exists():
        return 0
    VENDOR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=VENDOR, prefix=".monaco-") as scratch:
        archive = Path(scratch) / "monaco.tgz"
        try:
            with urllib.request.urlopen(MONACO_TARBALL) as response:
                archive.write_bytes(response.read())
        except urllib.error.URLError as e:
            raise SystemExit(f"vendor: cannot fetch {MONACO_TARBALL}: {e}")
        unpacked = Path(scratch) / "monaco"
        written = 0
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                if not (member.isfile() and member.name.startswith(MONACO_PREFIX)):
                    continue
                rest = posixpath.normpath(member.name[len(MONACO_PREFIX):])
                if rest.startswith(("..", "/")):
                    continue
                target = unpacked / "vs" / rest
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source:
                    target.write_bytes(source.read())
                written += 1
        (unpacked / MONACO_FILES[-1]).write_text(json.dumps(
            {"version": MONACO_VERSION, "from": MONACO_TARBALL,
             "kept": MONACO_PREFIX}, indent=2) + "\n")
        if MONACO.exists():
            shutil.rmtree(MONACO)
        unpacked.rename(MONACO)
    return written + 1


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
    """What every tool serves: the shared scripts, the vendored libraries,
    the compiler bundle, the standard library, the notebook's scripts and
    the help -- its page and scripts, and the pages tools/help/help.py
    generated -- each at the path the pages expect them. () -> Site"""
    return Site(
        mounts={"/webrun/": ASSETS, "/vendor/": VENDOR, "/lib/": LIB,
                "/notebook/": ROOT / "tools" / "notebook" / "assets",
                "/help/": ROOT / "tools" / "help" / "assets",
                "/help/pages/": ROOT / "build" / "help"},
        files={"/pyking/pyking.js": BUNDLE},
        answers={"/pyking/manifest.json": (bundle_manifest, "application/json")},
    )


def main(argv=None):
    """The command-line entry point. [String]? -> ()"""
    parser = argparse.ArgumentParser(
        prog="server.py", description="The Pyking web tools' shared files.")
    parser.add_argument("command", choices=("vendor",))
    parser.parse_args(argv)
    vendor()


if __name__ == "__main__":
    main()
