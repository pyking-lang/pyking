#!/usr/bin/env python3
"""Test harness for py2pyk.

For every `tests/*.py` file:

  1. translate it with py2pyk.py into Pyking source;
  2. compile that Pyking source back into Python with boot/pykboot.py
     (the project's real bootstrap compiler -- this is also, as a side
     effect, the ground truth check that py2pyk produced *valid* Pyking:
     an invalid translation fails here with pykboot's own error);
  3. run the original `.py` and the round-tripped `.py` each with
     `python3`, and compare their stdout.

A test passes if both programs run to completion and print identical
output. This is deliberately black-box: it never compares source text,
only observable behaviour, which is the property py2pyk is supposed to
preserve.

Run via `make test` in this directory, or directly:

    python3 test_script.py
"""

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PY2PYK = HERE / "py2pyk.py"
PYKBOOT = HERE.parent.parent / "boot" / "pykboot.py"
TESTS_DIR = HERE / "tests"


def run_python(path, cwd):
    return subprocess.run(
        [sys.executable, str(path)],
        cwd=cwd, capture_output=True, text=True, timeout=30,
    )


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
        [sys.executable, str(PYKBOOT), "--output", str(roundtrip_py), str(pyk_file)],
        capture_output=True, text=True, timeout=30,
    )
    if compile_back.returncode != 0:
        return False, f"pykboot failed to compile the generated .pyk:\n{_indent(compile_back.stderr)}"

    original = run_python(py_file, cwd=py_file.parent)
    if original.returncode != 0:
        return False, f"original Python program failed:\n{_indent(original.stderr)}"

    roundtrip = run_python(roundtrip_py, cwd=tmp_dir)
    if roundtrip.returncode != 0:
        return False, f"round-tripped Python program failed:\n{_indent(roundtrip.stderr)}"

    if original.stdout != roundtrip.stdout:
        return False, (
            "output mismatch:\n"
            f"  original:   {original.stdout!r}\n"
            f"  round-trip: {roundtrip.stdout!r}"
        )
    return True, None


def _indent(text, prefix="    "):
    return "\n".join(prefix + line for line in text.rstrip("\n").splitlines())


def main():
    if not PYKBOOT.exists():
        print(f"test_script.py: cannot find pykboot at {PYKBOOT}", file=sys.stderr)
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
