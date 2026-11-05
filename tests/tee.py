#!/usr/bin/env python3
"""Runs a command, printing what it writes and appending it to a log
file as well: what `make test LOG=FILE` runs each of its steps under.

Unlike `cmd | tee FILE`, it answers the command's own exit status, which
a plain pipe in make's /bin/sh loses (there is no portable `pipefail`).
The command's stderr is merged into its stdout, so the log holds the
lines in the order they appeared on the screen.

Usage: python3 tests/tee.py FILE COMMAND [ARGUMENT...]

Functions:
    main(argv) -- the command-line entry point.
"""

import os
import subprocess
import sys


def main(argv):
    """Runs the command, copying its output to the screen and the log.
    [String] -> Int"""
    if len(argv) < 2:
        print("usage: tee.py FILE COMMAND [ARGUMENT...]", file=sys.stderr)
        return 2
    path, command = argv[0], argv[1:]
    # Unbuffered, so a Python child's lines reach the screen as it prints
    # them rather than when its pipe fills.
    environment = dict(os.environ, PYTHONUNBUFFERED="1")
    with open(path, "ab") as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, env=environment)
        screen = sys.stdout.buffer
        while True:
            try:
                line = process.stdout.readline()
            except KeyboardInterrupt:
                # ^C reaches the command too; keep copying what it says
                # while it stops, and answer its status.
                continue
            if not line:
                break
            screen.write(line)
            screen.flush()
            log.write(line)
            log.flush()
        while True:
            try:
                return process.wait()
            except KeyboardInterrupt:
                continue


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
