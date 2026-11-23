#!/usr/bin/env python3
"""The ai suite: what Pyking gives a coding assistant -- the short guide
PYKING-LLM.md, `pyk check`, `pyk ai`, and the files tools/help/aidoc.py
writes for them and for the website's llms.txt.

What it checks:

  guide     PYKING-LLM.md stays short enough for a small model's
            context, and has its parts. (Its examples are run by
            tests/test_site.py, as the help's are.)
  files     aidoc.py: every library and submodule has a short and a
            full page and a line in the index; every export of lib/ is
            in its part's short page by its signature and in its full
            page under `## name`; the website's llms.txt links only
            files the site has, and every library's two pages.
  check     `pyk check`: a program with no error, a type error, a
            warning, an error in an imported module, a tinyweb program
            (checked, not served), and arguments after `--` refused.
  ai        `pyk ai`: its usage, `guide`, every form of `lib` and `ref`
            and what each refuses, and `init` in a fresh directory, a
            second time, over an older guide, beside an AGENTS.md and a
            CLAUDE.md of a project's own, and in no directory.

Usage: python3 tests/test_ai.py [--compiler CMD]

Functions:
    check_guide() -- the guide part.
    check_files() -- the files part.
    check_check(compiler) -- the check part.
    check_ai(compiler) -- the ai part.
    main(argv) -- the command-line entry point.
"""

import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
REPO = HERE.parent
sys.path.insert(0, str(REPO / "tools" / "help"))

import suite  # noqa: E402  (after sys.path, which is what finds it)
import aidoc  # noqa: E402
import libdoc  # noqa: E402

DEFAULT_COMPILER = str(REPO / "pyk")
GUIDE = REPO / "PYKING-LLM.md"
TIMEOUT = 60
# The guide's budget: about 8,000 tokens at four characters a token,
# which leaves room for a program in a 16,000-token context.
GUIDE_LIMIT = 32000


def run(compiler, args, cwd=None):
    """Runs pyk with args. String -> [String] -> Path? -> CompletedProcess"""
    return subprocess.run(shlex.split(compiler) + args, capture_output=True, text=True,
                          timeout=TIMEOUT, cwd=cwd)


def check_guide():
    """PYKING-LLM.md is short and has its parts. () -> [(String, String?)]"""
    text = GUIDE.read_text()
    results = [("the guide is at most %d characters" % GUIDE_LIMIT,
                None if len(text) <= GUIDE_LIMIT else f"it has {len(text)}")]
    for heading in ("## How to work", "## Python habits that are wrong in Pyking",
                    "## Collections", "## Modules and libraries",
                    "## When the compiler refuses a program"):
        results.append((f"the guide has '{heading}'",
                        None if heading in text.splitlines() else "missing"))
    for command in ("pyk check", "pyk ai lib", "pyk ai ref"):
        results.append((f"the guide or AGENTS.md names `{command}`",
                        None if command in text or command in aidoc.AGENTS.read_text()
                        else "neither does"))
    return results


def check_files():
    """aidoc.py's pages and the website's llms files.
    () -> [(String, String?)]"""
    results = []
    modules = libdoc.read_modules(libdoc.LIB)
    with tempfile.TemporaryDirectory(prefix="pyk-ai-") as directory:
        out = Path(directory) / "ai"
        aidoc.write(out)
        for name in ("PYKING-LLM.md", "PYKING.md", "AGENTS.md", "lib/index.md"):
            results.append((f"aidoc writes {name}",
                            None if (out / name).is_file() else "missing"))
        index = (out / "lib" / "index.md").read_text()
        for module in modules:
            for part in aidoc.parts(module):
                short = out / "lib" / f"{part.name}.md"
                full = out / "lib" / f"{part.name}.full.md"
                if not short.is_file() or not full.is_file():
                    results.append((f"{part.name} has a short and a full page", "missing"))
                    continue
                short_text, full_text = short.read_text(), full.read_text()
                absent = [item.name for item in part.items
                          if item.signature.strip() not in short_text]
                results.append((f"{part.name}'s short page has every signature",
                                f"missing: {absent}" if absent else None))
                headings = set(re.findall(r"^## (.+)$", full_text, re.M))
                absent = [item.name for item in part.items
                          if aidoc._short_name(item) not in headings]
                results.append((f"{part.name}'s full page has every export",
                                f"missing: {absent}" if absent else None))
                results.append((f"the index lists {part.name}",
                                None if f"- `{part.name}`:" in index else "missing"))
        url = "https://example.org/"
        public = Path(directory) / "public"
        public.mkdir()
        aidoc.write_site(public, url)
        llms = (public / "llms.txt").read_text()
        links = re.findall(re.escape(url) + r"([^\s)]+)", llms)
        site_pages = {"documentation/ai/"}
        broken = [link for link in links
                  if link not in site_pages and not (public / link).is_file()]
        results.append(("llms.txt links only files the site has",
                        f"broken: {broken}" if broken else None))
        unlinked = [part.name for module in modules for part in aidoc.parts(module)
                    if f"llms/lib/{part.name}.md" not in links
                    or f"llms/lib/{part.name}.full.md" not in links]
        results.append(("llms.txt links every library's two pages",
                        f"missing: {unlinked}" if unlinked else None))
        results.append(("llms-small.txt is the guide",
                        None if (public / "llms-small.txt").read_text() == GUIDE.read_text()
                        else "differs"))
        results.append(("llms-full.txt is the reference",
                        None if (public / "llms-full.txt").read_text()
                        == (REPO / "PYKING.md").read_text() else "differs"))
    return results


def _expect(name, ran, code, out=(), err=(), absent=()):
    """A check of one run: its exit code, text its stdout must hold, text
    its stderr must hold, and text neither may.
    String -> CompletedProcess -> Int -> ... -> (String, String?)"""
    problems = []
    if ran.returncode != code:
        problems.append(f"exit {ran.returncode}, not {code}")
    problems += [f"stdout lacks {text!r}" for text in out if text not in ran.stdout]
    problems += [f"stderr lacks {text!r}" for text in err if text not in ran.stderr]
    problems += [f"it says {text!r}" for text in absent
                 if text in ran.stdout or text in ran.stderr]
    detail = "; ".join(problems) + f"\n{ran.stdout[:600]}\n{ran.stderr[:600]}"
    return (name, detail if problems else None)


def check_check(compiler):
    """`pyk check`. String -> [(String, String?)]"""
    with tempfile.TemporaryDirectory(prefix="pyk-check-") as directory:
        d = Path(directory)
        (d / "good.pyk").write_text('print("hi")\n')
        (d / "bad.pyk").write_text("print(1 + 2.0)\n")
        (d / "unused.pyk").write_text("y = 2\n")
        (d / "shapes.pyk").write_text("public def square(x: Int) -> Int: x * \"x\"\n")
        (d / "main.pyk").write_text("import shapes\nprint(shapes.square(2))\n")
        (d / "page.pyk").write_text(
            "import tinyweb as tw\nimport tinyweb.color as color\ntw.web_init()\n"
            "c = tw.canvas(100, 100)\ntw.circle(c, 50, 50, 20, color.red)\n")
        return [
            _expect("check: a program with no error", run(compiler, ["check", "good.pyk"], d),
                    0, out=["good.pyk: no errors."], absent=["hi"]),
            _expect("check: a type error", run(compiler, ["check", "bad.pyk"], d),
                    1, err=["Type error"], absent=["no errors"]),
            _expect("check: a warning, and no error", run(compiler, ["check", "unused.pyk"], d),
                    0, out=["no errors."], err=["Unused binding 'y'"]),
            _expect("check: an error in an imported module",
                    run(compiler, ["check", "main.pyk"], d), 1, err=["shapes.pyk"]),
            _expect("check: a tinyweb program, not served",
                    run(compiler, ["check", "page.pyk"], d), 0, out=["page.pyk: no errors."],
                    absent=["http://"]),
            _expect("check: arguments after -- refused",
                    run(compiler, ["check", "good.pyk", "--", "x"], d), 1,
                    err=["'pyk check' runs none"]),
        ]


def check_ai(compiler):
    """`pyk ai`. String -> [(String, String?)]"""
    guide = GUIDE.read_text()
    results = [
        _expect("ai: its usage", run(compiler, ["ai"]), 0,
                out=["pyk ai init", "pyk ai lib", "pyk ai ref"]),
        _expect("ai: an unknown form", run(compiler, ["ai", "bogus"]), 1,
                err=["there is no 'pyk ai bogus'"]),
    ]
    ran = run(compiler, ["ai", "guide"])
    results.append(("ai guide prints PYKING-LLM.md",
                    None if ran.returncode == 0 and ran.stdout == guide
                    else f"exit {ran.returncode}: {ran.stderr[:300]}"))
    lib = [
        ("every library", ["lib"], 0, ["# The standard library", "- `text`:",
                                       "- `tinyweb.color`:"], []),
        ("a library", ["lib", "text"], 0, ["# text", "import text",
                                           "def split(s: String, by: String) -> [String]"], []),
        ("a library in full", ["lib", "text", "--full"], 0, ["## split", "Parameters:"], []),
        ("a submodule", ["lib", "tinyweb.color"], 0,
         ["import tinyweb.color as color", "def color.rgb("], []),
        ("a submodule by its last name", ["lib", "color"], 0, ["# tinyweb.color"], []),
        ("an export", ["lib", "text.split"], 0,
         ["## split", "Example:", "It prints:", '["a", "b", "", "c"]'], []),
        ("an export of a submodule", ["lib", "color.rgb"], 0,
         ["import tinyweb.color as color", "## rgb"], []),
        ("an overloaded export", ["lib", "list.sort"], 0, ["## int::sort", "## string::sort"], []),
        ("an export by its name alone", ["lib", "unwrap_or_else"], 0, [], []),
        ("a name several libraries export", ["lib", "circle"], 0,
         ["Several libraries export 'circle'", "- tinyweb:", "- tinyweb.smooth:"], []),
    ]
    for name, args, code, out, err in lib:
        results.append(_expect(f"ai lib: {name}", run(compiler, ["ai"] + args), code, out, err))
    results += [
        _expect("ai lib: an unknown library, with a suggestion",
                run(compiler, ["ai", "lib", "txt"]), 1, err=["did you mean 'text'?"]),
        _expect("ai lib: an unknown export of a library",
                run(compiler, ["ai", "lib", "text.splt"]), 1,
                err=["'text' exports no 'splt'"]),
        _expect("ai lib: two names", run(compiler, ["ai", "lib", "a", "b"]), 1,
                err=["one name at most"]),
        _expect("ai ref: every section", run(compiler, ["ai", "ref"]), 0,
                out=["- Collections", "  - Tuple literals"]),
        _expect("ai ref: a section, with its text", run(compiler, ["ai", "ref", "tuple", "literals"]),
                0, out=["### Tuple literals", "Taking a part"]),
        _expect("ai ref: a part, with its sections listed",
                run(compiler, ["ai", "ref", "Datatypes,", "structs"]), 0,
                out=["## Datatypes, structs and pattern matching", "Its sections",
                     "- `match`/`case` pattern matching"], absent=["### Structs"]),
        _expect("ai ref: many sections, named", run(compiler, ["ai", "ref", "e"]), 0,
                out=["sections' titles hold 'e'"]),
        _expect("ai ref: no section", run(compiler, ["ai", "ref", "zzzz"]), 1,
                err=["no section's title holds 'zzzz'"]),
    ]
    template = aidoc.AGENTS.read_text()
    with tempfile.TemporaryDirectory(prefix="pyk-ai-") as directory:
        d = Path(directory)
        fresh = d / "fresh"
        fresh.mkdir()
        ran = run(compiler, ["ai", "init"], fresh)
        results.append(_expect("ai init: a fresh project", ran, 0,
                               out=["PYKING-LLM.md written", "AGENTS.md written",
                                    "CLAUDE.md written"]))
        written = {name: (fresh / name).read_text() if (fresh / name).is_file() else None
                   for name in ("PYKING-LLM.md", "AGENTS.md", "CLAUDE.md")}
        results.append(("ai init: the three files hold the guide, the template and @AGENTS.md",
                        None if written == {"PYKING-LLM.md": guide, "AGENTS.md": template,
                                            "CLAUDE.md": "@AGENTS.md\n"}
                        else f"{ {k: (v or '')[:60] for k, v in written.items()} }"))
        results.append(_expect("ai init: again, keeping everything",
                               run(compiler, ["ai", "init"], fresh), 0,
                               out=["PYKING-LLM.md is up to date.", "AGENTS.md kept",
                                    "CLAUDE.md kept"]))
        (fresh / "PYKING-LLM.md").write_text("an older guide\n")
        (fresh / "AGENTS.md").write_text("# ours\nRead PYKING-LLM.md.\n")
        results.append(_expect("ai init: an older guide is updated, AGENTS.md kept",
                               run(compiler, ["ai", "init", str(fresh)]), 0,
                               out=["PYKING-LLM.md updated", "AGENTS.md kept as it is."],
                               absent=["does not mention"]))
        results.append(("ai init: the older guide is replaced, AGENTS.md is not",
                        None if (fresh / "PYKING-LLM.md").read_text() == guide
                        and (fresh / "AGENTS.md").read_text().startswith("# ours")
                        else "it is not"))
        own = d / "own"
        own.mkdir()
        (own / "AGENTS.md").write_text("# Our rules\n")
        (own / "CLAUDE.md").write_text("Be brief.\n")
        results.append(_expect("ai init: a project's own AGENTS.md and CLAUDE.md, with advice",
                               run(compiler, ["ai", "init", "own"], d), 0,
                               out=["does not mention PYKING-LLM.md", "Add the line `@AGENTS.md`"]))
        results.append(("ai init: a project's own files are left as they were",
                        None if (own / "AGENTS.md").read_text() == "# Our rules\n"
                        and (own / "CLAUDE.md").read_text() == "Be brief.\n" else "changed"))
        results.append(_expect("ai init: no such directory",
                               run(compiler, ["ai", "init", "nowhere"], d), 1,
                               err=["there is no directory 'nowhere'"]))
    return results


def main(argv):
    """Runs every part and reports it. [String] -> Int"""
    compiler = DEFAULT_COMPILER
    if argv[:1] == ["--compiler"] and len(argv) == 2:
        compiler = argv[1]
    elif argv:
        print("usage: test_ai.py [--compiler CMD]", file=sys.stderr)
        return 2
    results = check_guide() + check_files() + check_check(compiler) + check_ai(compiler)
    failed = 0
    for name, detail in results:
        print(suite.case_line("ai", detail is None, name, detail or ""))
        if detail is not None:
            failed += 1
            suite.stop_at_error("ai", name)
    suite.footer("ai", len(results) - failed, failed, f"{len(results)} checks")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
