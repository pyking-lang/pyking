import glob
import os
import subprocess
import sys
import tempfile

PYKBOOT = os.path.join("boot", "pykboot.py")


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    test_files = sorted(glob.glob(os.path.join("tests", "*.pyk")))
    passed = 0
    failed = 0

    for path in test_files:
        out_path = os.path.splitext(path)[0] + ".out"
        with open(out_path, "r") as f:
            expected_output = f.read()

        with tempfile.NamedTemporaryFile(suffix=".py", delete=False) as tmp:
            generated_path = tmp.name
        try:
            compiled = run([sys.executable, PYKBOOT, "--output", generated_path, path])
            if compiled.returncode != 0:
                print(f"{path} FAILED")
                print("--- expected output ---")
                print(expected_output, end="")
                print("--- pykboot.py error ---")
                print(compiled.stderr, end="")
                failed += 1
                continue

            generated_output = run([sys.executable, generated_path]).stdout

            if generated_output == expected_output:
                print(f"{path} OK.")
                passed += 1
            else:
                print(f"{path} FAILED")
                print("--- expected output ---")
                print(expected_output, end="")
                print("--- generated output ---")
                print(generated_output, end="")
                failed += 1
        finally:
            if os.path.exists(generated_path):
                os.remove(generated_path)

    total = passed + failed
    print()
    print(f"Ran {total} tests: {passed} passed, {failed} failed.")

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
