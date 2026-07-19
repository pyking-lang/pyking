import glob
import os
import subprocess
import sys
import tempfile

PYKBOOT = os.path.join("boot", "pykboot.py")


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    test_files = sorted(glob.glob(os.path.join("tests", "*.py")))
    passed = 0
    failed = 0

    for path in test_files:
        original_output = run([sys.executable, path]).stdout

        generated = run([sys.executable, PYKBOOT, path])
        if generated.returncode != 0:
            print(f"{path} FAILED")
            print("--- original output ---")
            print(original_output, end="")
            print("--- pykboot.py error ---")
            print(generated.stderr, end="")
            failed += 1
            continue

        with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as tmp:
            tmp.write(generated.stdout)
            tmp_path = tmp.name
        try:
            generated_output = run([sys.executable, tmp_path]).stdout
        finally:
            os.remove(tmp_path)

        if original_output == generated_output:
            print(f"{path} OK.")
            passed += 1
        else:
            print(f"{path} FAILED")
            print("--- original output ---")
            print(original_output, end="")
            print("--- generated output ---")
            print(generated_output, end="")
            failed += 1

    total = passed + failed
    print()
    print(f"Ran {total} tests: {passed} passed, {failed} failed.")

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
