# The Python implementation of the names declared in io_external.pyk.
#
# Standard input is read through its byte layer and decoded here, line
# by line, so that `is_eof` can look at what comes next without the text
# layer having read ahead of it. Standard output is Python's own, which
# is where `print` writes too.

import sys as _sys


def write(text):
    _sys.stdout.write(text)


def write_line(text):
    _sys.stdout.write(text + "\n")


def _ending(line):
    if line.endswith(b"\n"):
        line = line[:-1]
        if line.endswith(b"\r"):
            line = line[:-1]
    return line


def prompt_line(prompt):
    _sys.stdout.write(prompt)
    _sys.stdout.flush()
    return _ending(_sys.stdin.buffer.readline()).decode("utf-8")


def read():
    _sys.stdout.flush()
    return _sys.stdin.buffer.read().decode("utf-8")


def is_eof():
    _sys.stdout.flush()
    return _sys.stdin.buffer.peek(1)[:1] == b""
