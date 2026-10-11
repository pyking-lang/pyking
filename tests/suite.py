#!/usr/bin/env python3
"""How the eight test suites report themselves, in one place so they do
it the same way.

Each suite prints its own detail, then one footer line of a fixed shape;
`tests/test_all.py` runs all eight, lets that output through unchanged,
and prints a combined summary at the end. The tally it adds up does not
travel on stdout -- a suite appends it to the file named by
`$PYK_TEST_TALLY` instead, so running one suite on its own prints
exactly what it always did plus its footer.

Functions:
    heading name -- the banner that opens one suite's output.
    footer name passed failed detail -- the one-line summary that closes
      it, and the tally the driver collects.
    read_tally path -- the tallies a run collected, in order.
    find_chromium() -- a Chromium the browser checks can drive, or None.
"""

import os
import shutil
from pathlib import Path

# Wide enough for the longest line the suites print, and the same for
# every banner so they line up when read one after another.
WIDTH = 68

# How a suite's counts are written, here and in the combined summary, so
# the two read as one table.
COUNTS = "{name:<12} {passed:>5} passed, {failed:>4} failed"


def heading(name):
    """The banner that opens one suite's output. Flushed, because the
    suite that follows it is a child process writing to the same stream
    and a buffered heading would land after its output. String -> ()"""
    print()
    print(f"--- {name} " + "-" * max(3, WIDTH - len(name) - 5))
    print(flush=True)


def footer(name, passed, failed, detail=""):
    """The one-line summary that closes a suite, and the tally
    `test_all.py` adds up. `detail` says what was counted, in the
    suite's own units. String -> Int -> Int -> String -> ()"""
    line = "  " + COUNTS.format(name=name + ":", passed=passed, failed=failed)
    print()
    print(line + (f"   ({detail})" if detail else ""))
    path = os.environ.get("PYK_TEST_TALLY")
    if path:
        with open(path, "a") as tally:
            tally.write(f"{name}\t{passed}\t{failed}\n")


def read_tally(path):
    """The tallies a run collected, in the order the suites wrote them.
    Path -> [(String, Int, Int)]"""
    if not os.path.exists(path):
        return []
    out = []
    with open(path) as tally:
        for line in tally:
            name, passed, failed = line.rstrip("\n").split("\t")
            out.append((name, int(passed), int(failed)))
    return out


CHROME_NAMES = ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable",
                "chrome", "chrome-headless-shell", "headless_shell"]


def find_chromium():
    """A Chromium to run pages in: $PYKING_CHROME, else one on the PATH,
    else one Playwright has downloaded, else None. () -> String?"""
    named = os.environ.get("PYKING_CHROME")
    if named:
        return named
    for name in CHROME_NAMES:
        found = shutil.which(name)
        if found:
            return found
    mac = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    if mac.exists():
        return str(mac)
    caches = [Path.home() / ".cache" / "ms-playwright",
              Path.home() / "Library" / "Caches" / "ms-playwright"]
    for cache in caches:
        for pattern in ("chromium_headless_shell-*/*/chrome-headless-shell",
                        "chromium_headless_shell-*/*/headless_shell",
                        "chromium-*/chrome-linux*/chrome",
                        "chromium-*/chrome-mac*/Chromium.app/Contents/MacOS/Chromium"):
            for found in sorted(cache.glob(pattern), reverse=True):
                if os.access(found, os.X_OK):
                    return str(found)
    return None
