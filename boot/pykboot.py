import os
import sys

from lexer import lexing, pprint_info, pprint_token, LexError
from parser import parse, ParseError
from syntax import pprint_program
from target_python import translate_program, pprint_py_program


FLAGS = ("--tokens", "--ast", "--stdout")

args = sys.argv[1:]
show_tokens = "--tokens" in args
show_ast = "--ast" in args
show_stdout = "--stdout" in args
positional = [a for a in args if a not in FLAGS]

if len(positional) != 1:
    print("Usage: python3 boot/pykboot.py [--tokens] [--ast] [--stdout] <filename>")
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

if show_ast:
    print(pprint_program(program))
else:
    py_ast = translate_program(program)
    py_source = pprint_py_program(py_ast)

    if show_stdout:
        print(py_source)
    else:
        # Written to the current working directory, not next to the input file.
        out_path = os.path.splitext(os.path.basename(filename))[0] + ".py"
        if os.path.abspath(out_path) == os.path.abspath(filename):
            print(
                f"Usage error: input '{filename}' would be overwritten by its own "
                "compiled output; pass a non-'.py' source file (e.g. a '.pyk' file).",
                file=sys.stderr,
            )
            sys.exit(1)

        with open(out_path, "w") as f:
            f.write(py_source + "\n")
