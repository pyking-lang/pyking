import os
import sys

from analyses import analyze_program, AnalysisError
from lexer import lexing, pprint_info, pprint_token, LexError
from parser import parse, ParseError
from syntax import pprint_program
from target_python import translate_program, pprint_py_program


USAGE = "Usage: python3 boot/pykboot.py [--tokens] (--ast | --stdout | --output <file>) <filename>"

args = sys.argv[1:]
show_tokens = False
show_ast = False
show_stdout = False
output_path = None
positional = []

i = 0
while i < len(args):
    arg = args[i]
    if arg == "--tokens":
        show_tokens = True
    elif arg == "--ast":
        show_ast = True
    elif arg == "--stdout":
        show_stdout = True
    elif arg == "--output":
        i += 1
        if i >= len(args):
            print("Usage error: --output requires a <file> argument", file=sys.stderr)
            print(USAGE, file=sys.stderr)
            sys.exit(1)
        output_path = args[i]
    else:
        positional.append(arg)
    i += 1

if len(positional) != 1:
    print(USAGE)
    sys.exit(1)

filename = positional[0]
with open(filename, "r") as f:
    data = f.read()

try:
    tokens = lexing(filename, list(data))
except LexError as e:
    print(f"{pprint_info(e.info)} Lexing error: {e.message}", file=sys.stderr)
    sys.exit(1)

if show_tokens:
    print("\n".join(f"{pprint_info(t.info)} {pprint_token(t)}" for t in tokens))
    print("")

try:
    program = parse(tokens)
except ParseError as e:
    print(f"{pprint_info(e.info)} Parsing error: {e.message}", file=sys.stderr)
    sys.exit(1)

# Name analysis runs for every mode, `--ast` included: it is part of the
# front end, not of any backend, and an AST whose names don't resolve is
# not a program worth printing or compiling.
try:
    analyze_program(program)
except AnalysisError as e:
    print(f"{pprint_info(e.info)} Name error: {e.message}", file=sys.stderr)
    sys.exit(1)

if show_ast:
    print(pprint_program(program))
else:
    py_ast = translate_program(program)
    py_source = pprint_py_program(py_ast)

    if show_stdout:
        print(py_source)
    elif output_path is not None:
        if os.path.abspath(output_path) == os.path.abspath(filename):
            print(
                f"Usage error: --output '{output_path}' would overwrite the input "
                "file; choose a different output path.",
                file=sys.stderr,
            )
            sys.exit(1)

        with open(output_path, "w") as f:
            f.write(py_source + "\n")
    else:
        print(
            "Usage error: specify one of --ast, --stdout, or --output <file>.",
            file=sys.stderr,
        )
        print(USAGE, file=sys.stderr)
        sys.exit(1)
