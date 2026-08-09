#!/usr/bin/env python3
"""Test harness for py2pyk: translates each tests/*.py, compiles the
result back to Python with src/pyk.py, and diffs the two programs'
stdout. Black-box throughout -- never compares source text, only
observable behavior. See README.md, "Testing", for what each step
checks and how the comparison normalizes boolean spelling. Run via
`make test`, or `python3 test_script.py` directly.

Functions:
    run_case(py_file, tmp_dir) -- translates, compiles back, runs both
        programs, and compares one test case; returns (ok, detail).
    main() -- runs every tests/*.py file and prints the summary.
"""

import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PY2PYK = HERE / "py2pyk.py"
PYK = HERE.parent.parent / "src" / "pyk.py"
TESTS_DIR = HERE / "tests"


def run_python(path, cwd):
    """Runs a Python file with python3. Path -> Path ->
    subprocess.CompletedProcess"""
    return subprocess.run(
        [sys.executable, str(path)],
        cwd=cwd, capture_output=True, text=True, timeout=30,
    )


_PYTHON_BOOL_RE = re.compile(r"\bTrue\b|\bFalse\b")


def _normalized_for_comparison(text):
    """text with Python's True/False lowercased to Pyking's spelling
    (README.md, "Testing"). String -> String"""
    return _PYTHON_BOOL_RE.sub(lambda m: m.group(0).lower(), text)


def run_case(py_file, tmp_dir):
    """Translates, compiles back, runs, and compares one tests/*.py
    file. Path -> Path -> (Bool, String?)"""
    pyk_file = tmp_dir / (py_file.stem + ".pyk")
    roundtrip_py = tmp_dir / (py_file.stem + ".roundtrip.py")

    translate = subprocess.run(
        [sys.executable, str(PY2PYK), str(py_file), "-o", str(pyk_file)],
        capture_output=True, text=True, timeout=30,
    )
    if translate.returncode != 0:
        return False, f"py2pyk failed:\n{_indent(translate.stderr)}"

    compile_back = subprocess.run(
        [sys.executable, str(PYK), "compile", "--output", str(roundtrip_py),
         str(pyk_file)],
        capture_output=True, text=True, timeout=30,
    )
    if compile_back.returncode != 0:
        return False, f"pyk failed to compile the generated .pyk:\n{_indent(compile_back.stderr)}"

    original = run_python(py_file, cwd=py_file.parent)
    if original.returncode != 0:
        return False, f"original Python program failed:\n{_indent(original.stderr)}"

    roundtrip = run_python(roundtrip_py, cwd=tmp_dir)
    if roundtrip.returncode != 0:
        return False, f"round-tripped Python program failed:\n{_indent(roundtrip.stderr)}"

    original_stdout = _normalized_for_comparison(original.stdout)
    if original_stdout != roundtrip.stdout:
        return False, (
            "output mismatch:\n"
            f"  original:   {original.stdout!r}\n"
            f"  round-trip: {roundtrip.stdout!r}"
        )
    return True, None


def _indent(text, prefix="    "):
    """text with prefix before each line. String -> String -> String"""
    return "\n".join(prefix + line for line in text.rstrip("\n").splitlines())


def main():
    """Runs every tests/*.py file and prints a pass/fail summary.
    () -> Int (exit status)"""
    if not PYK.exists():
        print(f"test_script.py: cannot find the compiler at {PYK}", file=sys.stderr)
        return 1

    cases = sorted(TESTS_DIR.glob("*.py"))
    if not cases:
        print(f"test_script.py: no tests/*.py files found under {TESTS_DIR}", file=sys.stderr)
        return 1

    import tempfile
    passed = 0
    failed = 0
    failures = []
    with tempfile.TemporaryDirectory(prefix="py2pyk-tests-") as tmp:
        tmp_dir = Path(tmp)
        for py_file in cases:
            case_tmp = tmp_dir / py_file.stem
            case_tmp.mkdir()
            ok, detail = run_case(py_file, case_tmp)
            if ok:
                print(f"{py_file.name}: OK.")
                passed += 1
            else:
                print(f"{py_file.name}: FAIL.")
                print(_indent(detail, "    "))
                failed += 1
                failures.append(py_file.name)

    total = passed + failed
    print()
    print(f"{passed}/{total} passed, {failed}/{total} failed.")
    if failures:
        print("Failed: " + ", ".join(failures))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
