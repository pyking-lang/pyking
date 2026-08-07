#!/usr/bin/env python3
"""Test harness for py2pyk.

For every `tests/*.py` file:

  1. translate it with py2pyk.py into Pyking source;
  2. compile that Pyking source back into Python with src/pyk.py
     (the project's real bootstrap compiler -- this is also, as a side
     effect, the ground truth check that py2pyk produced *valid* Pyking:
     an invalid translation fails here with the compiler's own error);
  3. run the original `.py` and the round-tripped `.py` each with
     `python3`, and compare their stdout.

A test passes if both programs run to completion and print identical
output (after normalizing one, permanent, documented difference: Python's
`print` spells a boolean `True`/`False`, Pyking's spells it `true`/`false`
-- see `_normalized_for_comparison` below). This is deliberately
black-box otherwise: it never compares source text, only observable
behaviour, which is the property py2pyk is supposed to preserve.

Run via `make test` in this directory, or directly:

    python3 test_script.py
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
    return subprocess.run(
        [sys.executable, str(path)],
        cwd=cwd, capture_output=True, text=True, timeout=30,
    )


_PYTHON_BOOL_RE = re.compile(r"\bTrue\b|\bFalse\b")


def _normalized_for_comparison(text):
    """Python's own `print` writes a bool `True`/`False`; Pyking's own
    `print` writes `true`/`false` (see PYKING.md's "Boolean literals" --
    a deliberate, permanent difference between the two languages, not
    something py2pyk's translation could or should paper over). Comparing
    raw stdout would therefore report a mismatch on every test that
    prints a boolean, even one translated perfectly, so the *original*
    Python program's output is normalized to Pyking's spelling before
    comparing -- the round-tripped program's output already uses it.

    This is a whole-word substitution, so it would incorrectly normalize
    a string that happens to *contain* the word "True" or "False" as data
    rather than as a boolean's repr (e.g. `print("True Story")`); none of
    the programs in tests/ do that."""
    return _PYTHON_BOOL_RE.sub(lambda m: m.group(0).lower(), text)


def run_case(py_file, tmp_dir):
    """Returns (ok, detail) for one tests/*.py file."""
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
    return "\n".join(prefix + line for line in text.rstrip("\n").splitlines())


def main():
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
