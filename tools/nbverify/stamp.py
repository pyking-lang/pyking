#!/usr/bin/env python3
"""Writes the version in the VERSION file into nbverify.py, between its
`# BEGIN version` and `# END version` lines, so the tool says which
Pyking it belongs to when it is copied out alone. `make` runs it; the
file is left alone where it already says the version.

Usage: python3 tools/nbverify/stamp.py

Functions:
    stamp(version, text) -- nbverify.py's text with the version written in.
    main() -- the command-line entry point.
"""

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE / "nbverify.py"
VERSION = HERE.parent.parent / "VERSION"


def stamp(version, text):
    """nbverify.py's text with `VERSION = "..."` saying version.
    String -> String -> String"""
    return re.sub(r'(# BEGIN version[^\n]*\n)VERSION = "[^"\n]*"\n',
                  lambda m: f'{m.group(1)}VERSION = "{version}"\n', text, count=1)


def main():
    """The command-line entry point. () -> Int"""
    version = VERSION.read_text().strip()
    text = TOOL.read_text()
    stamped = stamp(version, text)
    if f'VERSION = "{version}"' not in stamped:
        print("stamp.py: nbverify.py has no version line to write", file=sys.stderr)
        return 1
    if stamped != text:
        TOOL.write_text(stamped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
