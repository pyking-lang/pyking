#!/usr/bin/env python3
"""Runs the packaging's own test cases: that the tree every package
ships, installed the way Homebrew installs it, is a working Pyking that
needs nothing from this repository -- and, when a package has been built
here, that it is what it claims to be.

The Homebrew package itself can only be built on a Mac, so the first
part stages the shipped tree around *this* machine's `pyk` instead
(tools/packaging/packaging.py, `stage`), and installs it into a
temporary prefix shaped like Homebrew's: the tree in
Cellar/pyking/<version>/libexec, and bin/pyk a link to a link to it.
Then, from a directory outside the repository:

  - `pyk --version` says the version in VERSION;
  - a program runs, and a program importing the standard library
    compiles, which needs lib/ found through the links;
  - the standard library runs under the interpreter from the plugins
    the tree ships, compiled beside it by `build_plugins` -- none is
    compiled again into the cache;
  - the `iweb2020` target compiles, which needs share/pyking.js;
  - `pyk notebook` and `pyk playground` start and serve their pages, and
    `pyk notebook --mode test` checks a notebook;
  - `pyk example` lists the examples and saves one, and the playground
    offers the same ones;
  - the tree holds what it should and nothing else;
  - the tarball is reproducible and unpacks to one directory, and the
    cask names its URL, checksum and version.

The same tree is then packed the Linux way, which this suite can check
end to end on Linux: a .deb, read back by its own reader and, where dpkg
exists, by `dpkg-deb`, then unpacked and run; and install.sh, run against
a release copied into a temporary directory, installing into a temporary
home -- installing, reinstalling, refusing a wrong checksum, refusing
macOS, and uninstalling. SHA256SUMS and the ELF reader are checked too.

The last part runs only when tools/packaging/build/ holds packages
(`make packaging`): it unpacks each one, checks its `pyk` -- the Mac's
architectures from the Mach-O header, each Linux one's architecture,
that it is dynamically linked and the glibc it asks for from the ELF
file, and each package's library plugins, which needs neither system --
checks SHA256SUMS and both casks against the files, and runs what
this machine can run. It never runs `brew`, `dpkg -i` or a release.

The Docker and Nix formats are checked without either: the Dockerfile
has both images, what they need, and no ENTRYPOINT; tools/packaging/nix/
fetches the browser libraries tools/webrun/server.py names, builds the
shipped tree and is locked; where Nix is installed, `nix-instantiate
--parse` reads it. Building it is `make packaging FORMATS=nix`'s.

What a release says has changed is CHANGELOG.md's section for its
version (`packaging.changelog_notes`): the suite checks that 0.1.0's is
read as a release would show it, and that a section that is missing,
undated or empty is refused.

Usage: python3 tests/test_packaging.py [--compiler PYK]
                                        [--sample PERCENT [--seed N]]

`--compiler` names the `pyk` to package, `./pyk` by default. It has to be
an executable file, not a command, since it is what the package holds.
`--sample PERCENT` (`make quicktest`) runs PERCENT of the seven groups
of checks, at least one, chosen at random by `--seed N`.

Functions:
    check_stage() -- the shipped tree, installed as Homebrew would.
    check_deb(tree) -- the .deb of a tree.
    check_install_sh(tree) -- install.sh, against a local release.
    check_readers() -- the Mach-O and ELF readers, and SHA256SUMS.
    check_built() -- the packages tools/packaging/build/ holds.
    check_docker_nix(check) -- the Dockerfile, and tools/packaging/nix/.
    check_changelog(check) -- what a release says has changed.
    main(argv) -- the command-line entry point.
"""

import base64
import hashlib
import io
import json
import os
import platform
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "tools" / "packaging"))

import suite  # noqa: E402  (after sys.path, which is what finds it)
import test_notebook  # noqa: E402
import packaging  # noqa: E402

server = packaging.server

REPO = HERE.parent
COMPILER = REPO / "pyk"
TIMEOUT = 60

HELLO = 'print("hello from", "the package", 1 + 2)\n'
HELLO_OUTPUT = "hello from the package 3\n"
# A program that imports the standard library: compiling it at all means
# lib/ was found beside the resolved executable.
IMPORTS = "import sys\n\nprint(len(sys.args()))\n"
# One that runs the standard library through the interpreter, which loads
# each library's plugin from the tree.
LIBRARY = ('import io\nimport sys\nio.write_line("read " ++ io.read_line())\n'
           'print(sys.args())\n')
LIBRARY_OUTPUT = "read typed\n['a', 'b']\n"


class Checks:
    """A running count of checks, and the failures among them."""

    def __init__(self):
        self.count = 0
        self.failures = []

    def __call__(self, label, ok, detail=""):
        self.count += 1
        if not ok:
            self.failures.append(label + (f": {detail}" if detail else ""))
        return ok


def run(command, cwd, env):
    """Runs a command, capturing both streams. [..] -> Path -> {..} ->
    CompletedProcess"""
    return subprocess.run([str(c) for c in command], cwd=cwd, env=env,
                          capture_output=True, text=True, timeout=TIMEOUT)


def install_like_homebrew(tree, prefix):
    """Links a staged tree into prefix the way Homebrew does: the tree is
    Cellar/pyking/<version>/libexec, and bin/pyk is a link to the keg's
    bin/pyk, itself a link to libexec/pyk. Answers prefix/bin/pyk.
    Path -> Path -> Path"""
    keg_bin = tree.parent / "bin"
    keg_bin.mkdir(parents=True, exist_ok=True)
    (keg_bin / "pyk").symlink_to(Path("..") / "libexec" / "pyk")
    (prefix / "bin").mkdir(parents=True, exist_ok=True)
    (prefix / "bin" / "pyk").symlink_to(os.path.relpath(keg_bin / "pyk", prefix / "bin"))
    return prefix / "bin" / "pyk"


def check_stage(check, compiler):
    """The shipped tree, staged around this machine's pyk and installed
    into a temporary prefix, used from outside the repository.
    Checks -> ()"""
    version = packaging.version()
    vendored = all(path.exists() for path, _ in packaging.server.vendor_files())
    with tempfile.TemporaryDirectory(prefix="pyk-packaging-") as directory:
        root = Path(directory)
        tree = root / "Cellar" / "pyking" / version / "libexec"
        try:
            packaging.stage(compiler, tree, vendor=vendored)
            plugins = packaging.build_plugins(tree)
        except packaging.Refusal as refusal:
            check("the tree stages", False, str(refusal))
            return
        # Before anything runs from the tree: Python writes __pycache__
        # beside a script it runs.
        files = {str(p.relative_to(tree)) for p in tree.rglob("*") if p.is_file()}
        for wanted in ["pyk", "LICENSE", "CHANGELOG.md", "PYKING-TUTORIAL.md", "share/pyking.js",
                       "share/plugin/pyk_plugin.cmi", "lib/sys/sys.pyk",
                       "lib/io/io_external.cmxs", "tools/notebook/check.js",
                       "tools/notebook/assets/index.html",
                       "tools/emacs/pyking-mode.el",
                       "tools/nbverify/nbverify.py", "tools/nbverify/README.md",
                       "tools/playground/assets/index.html"]:
            check(f"the tree holds {wanted}", wanted in files)
        python = sorted(f for f in files if f.startswith("tools/") and f.endswith(".py")
                        and f != "tools/nbverify/nbverify.py")
        check("the web tools hold no Python: pyk serves them", not python, ", ".join(python))
        verifier = run([sys.executable, str(tree / "tools" / "nbverify" / "nbverify.py"), "--version"],
                       root, dict(os.environ))
        check("the tree's nbverify says VERSION",
              verifier.stdout.strip() == f"nbverify {version}", verifier.stdout + verifier.stderr)
        check("every library with an OCaml implementation has its plugin",
              all(plugin.exists() for plugin in plugins) and len(plugins) >= 4,
              ", ".join(str(p.relative_to(tree)) for p in plugins))
        examples = {source for source, _ in packaging.examples_shipped()}
        check("the tree holds every example and their list",
              examples <= files and len(examples) > 1, ", ".join(sorted(examples - files)))
        stray = sorted(f for f in files if f.endswith(("~", ".DS_Store", "Makefile",
                                                        "e2e.mjs", ".pyc"))
                       or (f.startswith("tests/") and f not in examples) or "/#" in f)
        check("the tree holds nothing else", not stray, ", ".join(stray[:5]))

        pyk = install_like_homebrew(tree, root / "prefix")
        work = root / "work"
        work.mkdir()
        (work / "hello.pyk").write_text(HELLO)
        (work / "imports.pyk").write_text(IMPORTS)
        env = {k: v for k, v in os.environ.items() if k != "PYKING_LIB_PATH"}
        if not vendored:
            env["PYKING_WEB_NO_VENDOR"] = "1"

        result = run([pyk, "--version"], work, env)
        check("`pyk --version` says VERSION",
              result.stdout.strip() == f"pyk {version}", result.stdout + result.stderr)
        result = run([pyk, "hello.pyk"], work, env)
        check("a program runs", result.stdout == HELLO_OUTPUT,
              result.stdout + result.stderr)
        result = run([pyk, "compile", "-t", "pyking", "--stdout", "imports.pyk"], work, env)
        check("the standard library is found through the links",
              result.returncode == 0, result.stderr.strip())
        # The plugins the tree ships are the ones loaded: with a cache of
        # its own, which a plugin compiled on demand would be written to,
        # the interpreter leaves it empty.
        (work / "library.pyk").write_text(LIBRARY)
        cache = root / "cache"
        cache.mkdir()
        result = subprocess.run([pyk, "library.pyk", "--", "a", "b"], cwd=work,
                                env=dict(env, XDG_CACHE_HOME=str(cache)), input="typed\n",
                                capture_output=True, text=True, timeout=TIMEOUT)
        check("the interpreter runs the standard library from its plugins",
              result.stdout == LIBRARY_OUTPUT, result.stdout + result.stderr)
        check("the plugins it loads are the tree's own, compiled for it",
              not any(cache.rglob("*.cmxs")),
              ", ".join(str(p) for p in cache.rglob("*.cmxs")))
        listed = run([pyk, "example"], work, env)
        names = [line.split()[0] for line in listed.stdout.splitlines()[2:-2]]
        check("`pyk example` lists the examples, one per line, under headings",
              listed.returncode == 0 and "use_args.pyk" in names
              and listed.stdout.startswith("File name")
              and all(len(line) <= 80 for line in listed.stdout.splitlines()),
              listed.stdout + listed.stderr)
        result = run([pyk, "example", "use_args.pyk"], work, env)
        check("`pyk example use_args.pyk` saves it here",
              result.returncode == 0 and (work / "use_args.pyk").read_text()
              == (REPO / "tests" / "lib_sys_use_args.pyk").read_text(),
              result.stdout + result.stderr)
        result = run([pyk, "example", "use_args.pyk"], work, env)
        check("and refuses to save it over the file now there",
              result.returncode == 1 and "already" in result.stderr, result.stderr)
        result = run([pyk, "use_args.pyk", "--", "2", "hi"], work, env)
        check("the example it saved runs", result.stdout == "0 hi\n1 hi\n",
              result.stdout + result.stderr)
        result = run([pyk, "compile", "-t", "iweb2020", "-o", "page", "hello.pyk"],
                     work, env)
        check("share/pyking.js is found for the iweb2020 target",
              result.returncode == 0 and (work / "build" / "page.html").exists()
              and (work / "build" / "pyking.js").exists(),
              result.stderr.strip())
        # A program compiled where pyk itself is -- the root of a checkout
        # -- gets a build/ of its own, which leaves what pyk ships alone.
        shutil.copy2(work / "hello.pyk", tree / "hello.pyk")
        try:
            for target in ["web2020", "iweb2020", "python12"]:
                result = run([pyk, "compile", "-t", target, "hello.pyk"], tree, env)
                check(f"a {target} program compiled beside pyk builds",
                      result.returncode == 0, result.stderr.strip())
            check("and leaves share/ as it was",
                  (tree / "share" / "pyking.js").exists()
                  and (tree / "share" / "plugin" / "pyk_plugin.cmi").exists()
                  and (tree / "share" / "help" / "index.json").exists())
            result = run([pyk, "hello.pyk"], work, env)
            check("and pyk still runs a program", result.stdout == HELLO_OUTPUT,
                  result.stdout + result.stderr)
        finally:
            shutil.rmtree(tree / "build", ignore_errors=True)
            for name in ["hello.pyk", "hello"]:
                (tree / name).unlink(missing_ok=True)

        # Nothing on the PATH: the servers are pyk's own, and need no Python.
        (root / "empty").mkdir()
        bare = dict(env, PATH=str(root / "empty"))
        port = test_notebook.free_port()
        process, printed = test_notebook.start(
            [str(pyk)], ["notebook", "--port", str(port), str(tree / "PYKING-TUTORIAL.md")],
            bare)
        if check("`pyk notebook` starts from the package", process is not None, printed):
            try:
                for path in ["/", "/notebook/notebook.js", "/webrun/web.js",
                             "/pyking/pyking.js", "/doc/PYKING-TUTORIAL.md"]:
                    status, _ = test_notebook.fetch(port, path)
                    check(f"the packaged notebook serves {path}", status == 200,
                          f"status {status}")
                if vendored:
                    status, _ = test_notebook.fetch(port, "/vendor/ace/ace.js")
                    check("the packaged notebook serves Ace", status == 200)
            finally:
                test_notebook.stop(process)
        notebook = work / "task.md"
        notebook.write_text("```pyking task\nprint(1)\n```\n\n"
                            "```pyking solution\nprint(2)\n```\n\n```stdout\n2\n```\n")
        result = run([pyk, "notebook", "--mode", "test", "task.md"], work, env)
        check("`pyk notebook --mode test` checks a notebook from the package",
              result.returncode == 0 and "0 problems" in result.stdout,
              (result.stdout + result.stderr).strip())
        port = test_notebook.free_port()
        process, printed = test_notebook.start(
            [str(pyk)], ["playground", "--port", str(port)], bare)
        if check("`pyk playground` starts from the package", process is not None, printed):
            try:
                status, body = test_notebook.fetch(port, "/assets/playground.json")
                offered = json.loads(body).get("examples", []) if status == 200 else []
                check("the packaged playground offers what `pyk example` lists",
                      [e["file"] for e in offered] == names, f"status {status}")
                for example in offered:
                    status, _ = test_notebook.fetch(port, "/examples/" + example["file"])
                    check(f"and serves {example['file']}", status == 200, f"status {status}")
            finally:
                test_notebook.stop(process)
        port = test_notebook.free_port()
        process, printed = test_notebook.start(
            [str(pyk)], ["pykhelp", "--port", str(port)], bare)
        if check("`pyk pykhelp` starts from the package", process is not None, printed):
            try:
                status, body = test_notebook.fetch(port, "/help/pages/index.json")
                sections = json.loads(body).get("sections", []) if status == 200 else []
                check("the packaged help has its generated pages",
                      any(s["id"] == "libraries" and s["pages"] for s in sections),
                      f"status {status}")
                status, _ = test_notebook.fetch(port, "/help/help.js")
                check("and the help's own script", status == 200, f"status {status}")
            finally:
                test_notebook.stop(process)
        port = test_notebook.free_port()
        process, printed = test_notebook.start(
            [str(pyk)], ["serve", "--port", str(port), str(work)], bare)
        if check("`pyk serve` starts from the package", process is not None, printed):
            try:
                status, body = test_notebook.fetch(port, "/build/page.html")
                check("it serves the iweb2020 page compiled above",
                      status == 200 and body == (work / "build" / "page.html").read_bytes(),
                      f"status {status}")
            finally:
                test_notebook.stop(process)

        # The language server is pyk itself: a session from the package,
        # with nothing on the PATH, finds the standard library.
        (work / "args.pyk").write_text("import sys\nprint(sys.args())\n")
        session = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {"textDocument": {
                "uri": (work / "args.pyk").as_uri(), "languageId": "pyking", "version": 1,
                "text": (work / "args.pyk").read_text()}}},
            {"jsonrpc": "2.0", "id": 2, "method": "textDocument/hover", "params": {
                "textDocument": {"uri": (work / "args.pyk").as_uri()},
                "position": {"line": 1, "character": 10}}},
            {"jsonrpc": "2.0", "id": 3, "method": "shutdown"},
            {"jsonrpc": "2.0", "method": "exit"}]
        framed = b"".join(b"Content-Length: %d\r\n\r\n" % len(json.dumps(m).encode())
                          + json.dumps(m).encode() for m in session)
        result = subprocess.run([pyk, "lsp", "--stdio"], cwd=work, env=bare, input=framed,
                                capture_output=True, timeout=TIMEOUT)
        check("`pyk lsp` from the package answers a hover from the standard library",
              result.returncode == 0 and b"sys.args: () -> [String]" in result.stdout,
              (result.stdout + result.stderr).decode(errors="replace")[-300:])

        first = packaging.tarball(tree, root / "a.tar.gz")
        second = packaging.tarball(tree, root / "b.tar.gz")
        check("the tarball is reproducible", first == second)
        with tarfile.open(root / "a.tar.gz") as archive:
            names = archive.getnames()
            tops = {name.split("/")[0] for name in names}
            check("the tarball unpacks to one directory", tops == {"libexec"}, str(tops))
            member = archive.getmember("libexec/pyk")
            check("pyk stays executable in the tarball", member.mode & 0o111 != 0)

        url = f"{packaging.RELEASES}/v{version}/pyking-{version}-macos.tar.gz"
        text = packaging.cask(url, first, ["arm64", "x86_64"])
        for wanted in ['cask "pyking" do', f'url "{url}"', f'sha256 "{first}"',
                       f'version "{version}"', 'binary "pyking-#{version}/pyk"',
                       f'depends_on macos: ">= :{packaging.MACOS_MINIMUM_NAME}"',
                       '"-dr", "com.apple.quarantine", "#{staged_path}/pyking-#{version}"']:
            check(f"the cask says {wanted}", wanted in text)
        check("the cask is not a formula, which Homebrew would build",
              "< Formula" not in text and "def install" not in text)
        check("the binary the cask links is the tarball's pyk",
              f"pyking-{version}/pyk" in [n.replace("libexec", f"pyking-{version}", 1)
                                           for n in names])
        check("a universal cask names no architecture", "depends_on arch" not in text)
        check("a one-architecture cask says which",
              "depends_on arch: :arm64" in packaging.cask(url, first, ["arm64"])
              and "depends_on arch: :intel" in packaging.cask(url, first, ["x86_64"]))
        check("the cask depends on nothing else",
              text.count("depends_on") == 1, text)
        if shutil.which("ruby"):
            (root / "pyking.rb").write_text(text)
            result = run(["ruby", "-c", root / "pyking.rb"], root, env)
            check("the cask is valid Ruby", result.returncode == 0, result.stderr)


HOST_UNAME = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64",
              "amd64": "x86_64"}.get(platform.machine(), platform.machine())


def read_ar(path):
    """The members of an ar archive, in order, as (name, bytes).
    Path -> [(String, Bytes)]"""
    data = path.read_bytes()
    assert data[:8] == b"!<arch>\n", "not an ar archive"
    members, at = [], 8
    while at < len(data):
        header = data[at:at + 60]
        name, size = header[:16].decode().strip().rstrip("/"), int(header[48:58])
        members.append((name, data[at + 60:at + 60 + size]))
        at += 60 + size + (size % 2)
    return members


def check_deb(check, tree):
    """The .deb of a tree, for this machine's architecture: its layout,
    its control file, what dpkg-deb says of it, and that the pyk it
    installs runs. Checks -> Path -> ()"""
    arch = packaging.canonical_arch(HOST_UNAME)
    if arch not in packaging.ARCHS:
        return
    with tempfile.TemporaryDirectory(prefix="pyk-packaging-") as directory:
        root = Path(directory)
        first = packaging.deb(tree, arch, root / "a.deb")
        check("the .deb is reproducible", first == packaging.deb(tree, arch, root / "b.deb"))
        members = read_ar(root / "a.deb")
        check("the .deb holds debian-binary, control and data, in that order",
              [name for name, _ in members] == ["debian-binary", "control.tar.gz",
                                               "data.tar.gz"], str([n for n, _ in members]))
        control_tar = tarfile.open(fileobj=io.BytesIO(members[1][1]))
        control = control_tar.extractfile("./control").read().decode()
        fields = dict(line.split(": ", 1) for line in control.splitlines()
                      if ": " in line and not line.startswith(" "))
        for key, wanted in [("Package", "pyking"), ("Version", packaging.version()),
                            ("Architecture", packaging.DEB_ARCH[arch])]:
            check(f"the .deb's control says {key}: {wanted}", fields.get(key) == wanted,
                  fields.get(key, "(missing)"))
        floor = ".".join(map(str, packaging.GLIBC_FLOOR))
        check("the .deb depends on the C library alone",
              fields.get("Depends") == f"libc6 (>= {floor})", fields.get("Depends", "(missing)"))
        check("the .deb recommends nothing: pyk serves its own pages",
              "Recommends" not in fields, fields.get("Recommends", ""))
        data = tarfile.open(fileobj=io.BytesIO(members[2][1]))
        link = data.getmember("./usr/bin/pyk")
        check("the .deb links /usr/bin/pyk into /usr/lib/pyking",
              link.issym() and link.linkname == "../lib/pyking/pyk")
        check("the .deb installs the tree in /usr/lib/pyking",
              "./usr/lib/pyking/lib/sys/sys.pyk" in data.getnames())
        if shutil.which("dpkg-deb"):
            info = run(["dpkg-deb", "--field", root / "a.deb", "Package", "Architecture"],
                       root, dict(os.environ))
            check("dpkg-deb reads the .deb", info.returncode == 0
                  and f"Architecture: {packaging.DEB_ARCH[arch]}" in info.stdout,
                  info.stdout + info.stderr)
            unpacked = root / "unpacked"
            run(["dpkg-deb", "-x", root / "a.deb", unpacked], root, dict(os.environ))
            result = run([unpacked / "usr" / "bin" / "pyk", "--version"], root, dict(os.environ))
            check("the pyk the .deb installs runs through /usr/bin/pyk",
                  result.stdout.strip() == f"pyk {packaging.version()}",
                  result.stdout + result.stderr)


def check_install_sh(check, tree):
    """install.sh against a release in a temporary directory, into a
    temporary home. Checks -> Path -> ()"""
    script = packaging.INSTALL_SH
    with tempfile.TemporaryDirectory(prefix="pyk-packaging-") as directory:
        root = Path(directory)
        release = root / "release"
        release.mkdir()
        asset = f"pyking-linux-{HOST_UNAME}.tar.gz"
        sha = packaging.tarball(tree, release / asset)
        (release / "SHA256SUMS").write_text(f"{sha}  {asset}\n")
        home = root / "home"
        home.mkdir()
        env = {k: v for k, v in os.environ.items() if k not in ("XDG_DATA_HOME",)}
        env.update(HOME=str(home), PYKING_DOWNLOAD_BASE=release.as_uri())
        if platform.system() != "Linux":
            # install.sh refuses anything but Linux, by design -- a Mac is sent
            # to Homebrew, which is checked below. To exercise it here all the
            # same, a stand-in `uname` says Linux; the pyk it installs is this
            # machine's own, so it still runs.
            linux = root / "linuxbin"
            linux.mkdir()
            (linux / "uname").write_text(
                '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo '
                f'{HOST_UNAME} ;; *) exec /usr/bin/uname "$@" ;; esac\n')
            (linux / "uname").chmod(0o755)
            env["PATH"] = f"{linux}:{env['PATH']}"
        pyk = home / ".local" / "bin" / "pyk"

        result = run(["sh", script], root, env)
        installed = check("install.sh installs into ~/.local", result.returncode == 0
                          and pyk.is_symlink()
                          and (home / ".local" / "share" / "pyking" / "pyk").exists(),
                          result.stdout + result.stderr)
        check("install.sh says what it installed",
              f"Installed pyk {packaging.version()}" in result.stdout, result.stdout)
        (root / "hello.pyk").write_text(HELLO)
        if installed:
            ran = run([pyk, root / "hello.pyk"], root, env)
            check("the pyk install.sh installed runs a program", ran.stdout == HELLO_OUTPUT,
                  ran.stdout + ran.stderr)
        again = run(["sh", script], root, env)
        check("install.sh installs over an earlier installation", again.returncode == 0,
              again.stderr)

        (release / "SHA256SUMS").write_text(f"{'0' * 64}  {asset}\n")
        bad = run(["sh", script], root, env)
        check("install.sh refuses a download that does not match SHA256SUMS",
              bad.returncode != 0 and "does not match its checksum" in bad.stderr,
              bad.stdout + bad.stderr)
        (release / "SHA256SUMS").write_text(f"{sha}  {asset}\n")

        fake = root / "fakebin"
        fake.mkdir()
        (fake / "uname").write_text("#!/bin/sh\necho Darwin\n")
        (fake / "uname").chmod(0o755)
        mac = run(["sh", script], root, dict(env, PATH=f"{fake}:{env['PATH']}"))
        check("install.sh sends a Mac to Homebrew", mac.returncode != 0
              and packaging.BREW_INSTALL in mac.stderr, mac.stderr)
        wrong = run(["sh", script, "--frob"], root, env)
        check("install.sh refuses an unknown option", wrong.returncode != 0
              and "unknown option" in wrong.stderr, wrong.stderr)

        gone = run(["sh", script, "--uninstall"], root, env)
        check("install.sh --uninstall removes it", gone.returncode == 0
              and not pyk.exists() and not pyk.is_symlink()
              and not (home / ".local" / "share" / "pyking").exists(), gone.stderr)
    for shell in ("dash", "busybox"):
        if shutil.which(shell):
            parsed = run([shell] + (["sh"] if shell == "busybox" else []) + ["-n", script],
                         REPO, dict(os.environ))
            check(f"install.sh parses under {shell}", parsed.returncode == 0, parsed.stderr)


def check_macho(check):
    """The Mach-O reader, on headers made here. Checks -> ()"""
    with tempfile.TemporaryDirectory(prefix="pyk-packaging-") as directory:
        root = Path(directory)
        fat = root / "fat"
        fat.write_bytes(b"\xca\xfe\xba\xbe" + struct.pack(">I", 2)
                        + struct.pack(">iiIII", 0x01000007, 3, 0, 0, 0)
                        + struct.pack(">iiIII", 0x0100000C, 0, 0, 0, 0))
        check("a universal header reads as both architectures",
              packaging.macho_archs(fat) == ["x86_64", "arm64"], str(packaging.macho_archs(fat)))
        thin = root / "thin"
        thin.write_bytes(b"\xcf\xfa\xed\xfe" + struct.pack("<i", 0x0100000C) + bytes(24))
        check("a thin header reads as its one", packaging.macho_archs(thin) == ["arm64"])
        check("a file that is not Mach-O reads as none",
              packaging.macho_archs(REPO / "VERSION") == [])
        # An ELF header with no program headers at all: static, arm64.
        elf = root / "elf"
        elf.write_bytes(b"\x7fELF\x02\x01\x01" + bytes(9) + struct.pack("<HH", 2, 0xB7)
                        + bytes(64 - 20))
        check("an ELF header reads as its machine, static when it names no loader",
              packaging.elf_info(elf) == ("arm64", True), str(packaging.elf_info(elf)))
        check("a file that is not ELF reads as none",
              packaging.elf_info(REPO / "VERSION") is None)
        v = "9.9.9"
        names = packaging.release_assets(v)
        check("a release holds the Mac tarball, each Linux tarball and .deb under "
              "both names, the VS Code extension, install.sh and SHA256SUMS",
              len(names) == 12 and names[-1] == "SHA256SUMS" and "install.sh" in names
              and "pyking-linux-x86_64.tar.gz" in names and "pyking_9.9.9_arm64.deb" in names
              and "pyking-9.9.9.vsix" in names,
              str(names))
        saved = packaging.BUILD
        try:
            packaging.BUILD = root
            (root / "install.sh").write_text("echo\n")
            (root / "pyking_arm64.deb").write_bytes(b"x")
            sums = packaging.read_checksums(packaging.write_checksums(v))
            check("SHA256SUMS lists what is built, and only that",
                  sums == {"install.sh": hashlib.sha256(b"echo\n").hexdigest(),
                           "pyking_arm64.deb": hashlib.sha256(b"x").hexdigest()}, str(sums))
        finally:
            packaging.BUILD = saved


def check_built(check):
    """Each package tools/packaging/build/ holds: its tree, its binary's
    architectures, and both casks' checksums -- and each Linux tarball
    and .deb, and SHA256SUMS. Answers how many there were. Checks -> Int"""
    linux = sorted(packaging.BUILD.glob(f"pyking-{packaging.version()}-linux-*.tar.gz"))
    for archive in linux:
        u = archive.name.removesuffix(".tar.gz").rsplit("-", 1)[1]
        arch = packaging.canonical_arch(u)
        with tempfile.TemporaryDirectory(prefix="pyk-packaging-") as directory:
            with tarfile.open(archive) as tar:
                tar.extractall(directory, filter="data")
            tops = list(Path(directory).iterdir())
            pyk = tops[0] / "pyk" if len(tops) == 1 else Path(directory) / "missing"
            info = packaging.elf_info(pyk) if pyk.exists() else None
            check(f"{archive.name}'s pyk is a dynamically linked {arch} binary",
                  info == (arch, False), str(info))
            if pyk.exists():
                needed = packaging.glibc_needed(pyk)
                check(f"{archive.name}'s pyk asks for no glibc past the floor",
                      needed <= packaging.GLIBC_FLOOR, ".".join(map(str, needed)))
            plugins = sorted(tops[0].glob("lib/*/*_external.cmxs")) if len(tops) == 1 else []
            check(f"{archive.name} holds the library plugins",
                  len(plugins) >= 4 and all((packaging.elf_info(p) or ("",))[0] == arch
                                            for p in plugins),
                  ", ".join(p.name for p in plugins))
            check(f"{archive.name} holds each plugin's digest, without which pyk compiles it",
                  plugins and all(p.with_suffix(".digest").exists() for p in plugins))
            if platform.system() == "Linux" and HOST_UNAME == u:
                result = run([pyk, "--version"], directory, dict(os.environ))
                check(f"{archive.name}'s pyk runs here",
                      result.stdout.strip() == f"pyk {packaging.version()}",
                      result.stdout + result.stderr)
        fixed = packaging.BUILD / f"pyking-linux-{u}.tar.gz"
        check(f"{fixed.name} is {archive.name}", fixed.exists()
              and fixed.read_bytes() == archive.read_bytes())
        package = packaging.BUILD / f"pyking_{packaging.version()}_{packaging.DEB_ARCH[arch]}.deb"
        if check(f"{package.name} is built beside it", package.exists()):
            members = read_ar(package)
            control = tarfile.open(fileobj=io.BytesIO(members[1][1])) \
                .extractfile("./control").read().decode()
            check(f"{package.name} says Architecture: {packaging.DEB_ARCH[arch]}",
                  f"Architecture: {packaging.DEB_ARCH[arch]}" in control)
    sums_file = packaging.BUILD / "SHA256SUMS"
    if sums_file.exists():
        sums = packaging.read_checksums(sums_file)
        wrong = [name for name, sha in sums.items() if not (packaging.BUILD / name).exists()
                 or hashlib.sha256((packaging.BUILD / name).read_bytes()).hexdigest() != sha]
        check("SHA256SUMS matches the files built", not wrong, ", ".join(wrong))
    archives = sorted(packaging.BUILD.glob("pyking-*-macos*.tar.gz"))
    for archive in archives:
        name = archive.name
        sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        suffix = name.removesuffix(".tar.gz").split("-macos")[1]
        wanted = sorted(suffix.lstrip("-").split("-")) if suffix else ["arm64", "x86_64"]
        with tempfile.TemporaryDirectory(prefix="pyk-packaging-") as directory:
            with tarfile.open(archive) as tar:
                tar.extractall(directory, filter="data")
            tops = list(Path(directory).iterdir())
            if not check(f"{name} unpacks to one directory", len(tops) == 1):
                continue
            pyk = tops[0] / "pyk"
            check(f"{name}'s pyk is {' + '.join(wanted)}",
                  sorted(packaging.macho_archs(pyk)) == wanted,
                  str(packaging.macho_archs(pyk)))
            check(f"{name} holds the web tools and the library",
                  (tops[0] / "tools" / "notebook" / "check.js").exists()
                  and (tops[0] / "lib").is_dir() and (tops[0] / "share" / "pyking.js").exists())
            plugins = sorted(tops[0].glob("lib/*/*_external.cmxs"))
            check(f"{name} holds the library plugins, each {' + '.join(wanted)}",
                  len(plugins) >= 4 and all(sorted(packaging.macho_archs(p)) == wanted
                                            for p in plugins),
                  ", ".join(f"{p.name} {packaging.macho_archs(p)}" for p in plugins))
            check(f"{name} holds each plugin's digest, without which pyk compiles it",
                  plugins and all(p.with_suffix(".digest").exists() for p in plugins))
            if sys.platform == "darwin" and platform.machine() in wanted:
                result = run([pyk, "--version"], directory, dict(os.environ))
                check(f"{name}'s pyk runs here",
                      result.stdout.strip() == f"pyk {packaging.version()}",
                      result.stdout + result.stderr)
        for kind in ("homebrew", "homebrew-local"):
            rb = packaging.BUILD / kind / "pyking.rb"
            if rb.exists() and name in rb.read_text():
                check(f"{kind}/pyking.rb has {name}'s checksum", f'sha256 "{sha}"' in rb.read_text())
    return len(archives) + len(linux)


def check_docker_nix(check):
    """The Docker images' Dockerfile and ocamlopt wrapper, and the Nix
    package in tools/packaging/nix/: that default.nix fetches the browser
    libraries tools/webrun/server.py names, at its versions, builds as
    every package does and wraps pyk with its OCaml; that the flake calls
    it on every system and is locked; that both parse where Nix exists;
    and that a release refuses a Nix file that is not committed.
    Checks -> ()"""
    dockerfile = packaging.IMAGE_DOCKERFILE.read_text()
    for wanted in ("AS slim", "AS full", "ADD pyking.tar.gz", "PYKING_WEB_HOST=0.0.0.0",
                   "COPY --chmod=755 ocamlopt", "/opt/opam/release/lib/ocaml",
                   "sha256sum -c"):
        check(f"the Dockerfile has {wanted!r}", wanted in dockerfile)
    commands = [line for line in dockerfile.splitlines() if not line.startswith("#")]
    check("neither image has an ENTRYPOINT", not any("ENTRYPOINT" in line for line in commands))
    check('both images run CMD ["pyk", "repl"]',
          [line for line in commands if line.startswith("CMD")] == ['CMD ["pyk", "repl"]'] * 2)
    wrapper = packaging.IMAGE_DOCKERFILE.parent / "ocamlopt"
    check("the full image's ocamlopt is executable and links executables with -no-pie",
          os.access(wrapper, os.X_OK) and "-ccopt -no-pie" in wrapper.read_text())

    directory = packaging.Nix.DIRECTORY
    default = (directory / "default.nix").read_text()
    flake = (directory / "flake.nix").read_text()
    for name, version in (("ace", server.ACE_VERSION), ("katex", server.KATEX_VERSION),
                          ("monaco", server.MONACO_VERSION)):
        check(f"default.nix fetches {name} {version}, as server.py does",
              f'  {name} = "{version}";' in default)
    listed = {f"{group}/{path}" for group, body in
              re.findall(r'\n  (ace|katex)Files = \{\n(.*?)\n  \};', default, re.S)
              for path in re.findall(r'"([^"]+)" = "sha256-[A-Za-z0-9+/=]+";', body)}
    vendored = {str(path.relative_to(server.VENDOR)) for path, url in server.vendor_files()
                if not path.is_relative_to(server.MONACO)}
    check("default.nix fetches every Ace and KaTeX file server.py vendors, and no other",
          listed == vendored, str(sorted(listed ^ vendored)))
    hashes = {f"{group}/{path}": sri for group, body in
              re.findall(r'\n  (ace|katex)Files = \{\n(.*?)\n  \};', default, re.S)
              for path, sri in re.findall(r'"([^"]+)" = "(sha256-[A-Za-z0-9+/=]+)";', body)}
    local = {name: server.VENDOR / name for name in hashes if (server.VENDOR / name).exists()}
    if local:
        wrong = [name for name, path in local.items() if hashes[name] != "sha256-" + base64.b64encode(
            hashlib.sha256(path.read_bytes()).digest()).decode()]
        check("default.nix's hashes are those of the files `make vendor` downloaded",
              not wrong, ", ".join(wrong))
    check("default.nix fetches them from server.py's URLs",
          server.ACE_CDN.replace(server.ACE_VERSION, "${ace}") in default
          and server.KATEX_CDN.replace(server.KATEX_VERSION, "${katex}") in default
          and server.MONACO_TARBALL.replace(server.MONACO_VERSION, "${monaco}") in default)
    check("default.nix keeps Monaco's min/vs/ and writes the marker server.py checks",
          f"{server.MONACO_PREFIX.rstrip('/')}" in default
          and "monaco-editor-${monaco}.json" in default
          and server.MONACO_FILES[-1].replace(server.MONACO_VERSION, "${monaco}") in default)
    for wanted in ("make build", "packaging.py stage --binary pyk --dest $out/libexec/pyking",
                   "pyk plugins $out/libexec/pyking/lib",
                   "--set-default OCAMLOPT ${ocamlPackages.ocaml}/bin/ocamlopt",
                   "ocamlPackages.js_of_ocaml-compiler", 'mainProgram = "pyk"',
                   'lib.fileContents (root + "/VERSION")'):
        check(f"default.nix has {wanted!r}", wanted in default)
    check("default.nix is a function for callPackage",
          re.search(r"^\{ lib\n", default, re.M) is not None)
    check("the flake calls default.nix with callPackage on all four systems",
          "callPackage ./default.nix { }" in flake
          and all(f'"{system}"' in flake for system in
                  ("x86_64-linux", "aarch64-linux", "x86_64-darwin", "aarch64-darwin")))
    for name, text in (("default.nix", default), ("flake.nix", flake)):
        check(f"{name}'s braces and brackets balance",
              text.count("{") == text.count("}") and text.count("[") == text.count("]"))
    try:
        lock = json.loads((directory / "flake.lock").read_text())
        pinned = lock["nodes"]["nixpkgs"]["locked"]
        original = lock["nodes"]["nixpkgs"]["original"]
        locked = (pinned["type"] == "github" and len(pinned["rev"]) == 40
                  and f'github:{original["owner"]}/{original["repo"]}/{original["ref"]}' in flake)
    except (OSError, ValueError, KeyError) as e:
        locked = False
        pinned = str(e)
    check("flake.lock pins the nixpkgs flake.nix names", locked, str(pinned))
    if shutil.which("nix-instantiate"):
        for name in ("default.nix", "flake.nix"):
            parsed = subprocess.run(["nix-instantiate", "--parse", str(directory / name)],
                                    capture_output=True, text=True)
            check(f"nix-instantiate parses {name}", parsed.returncode == 0, parsed.stderr)
    check("a release's flake is named at its tag in the code repository",
          packaging.nix_flake("9.8.7")
          == f"github:{packaging.CODE_REPO}/release-9.8.7?dir=tools/packaging/nix")
    nix = packaging.Nix()
    nix.INSIDE = "tools/packaging/no-such-nix"
    try:
        nix.release_preflight()
        check("a release whose Nix files are not committed is refused", False, "it was accepted")
    except packaging.Refusal as refusal:
        check("a release whose Nix files are not committed is refused", True, str(refusal))


def check_changelog(check):
    """CHANGELOG.md has a dated section for 0.1.0, which a release would
    show, and a section that is missing, undated or empty is refused, as
    `make release` refuses it. Checks -> ()"""
    try:
        notes = packaging.changelog_notes("0.1.0")
        check("CHANGELOG.md's 0.1.0 section is what a release shows",
              notes.startswith("### Added") and "[0.1.0]:" not in notes, notes[:80])
    except packaging.Refusal as refusal:
        check("CHANGELOG.md's 0.1.0 section is what a release shows", False, str(refusal))
    with tempfile.TemporaryDirectory(prefix="pyk-packaging-") as directory:
        log = Path(directory) / "CHANGELOG.md"
        log.write_text("# Changelog\n\n## [2.0.0] - Unreleased\n\n- soon\n\n"
                       "## [1.0.0] - 2026-01-02\n\n\n## [0.9.0] - 2025-12-01\n\n- old\n\n"
                       "[2.0.0]: https://example.com\n")
        for v, wanted in (("2.0.0", "not dated"), ("1.0.0", "says nothing"),
                          ("3.0.0", "no section")):
            try:
                packaging.changelog_notes(v, log)
                check(f"a changelog section that {wanted.replace('not', 'is not')} is refused",
                      False, "it was not")
            except packaging.Refusal as refusal:
                check(f"a changelog section that {wanted.replace('not', 'is not')} is refused",
                      wanted in str(refusal), str(refusal))
        check("the last section stops at the link references",
              packaging.changelog_notes("0.9.0", log) == "- old")


def main(argv):
    """Runs the checks and reports them. [String] -> Int"""
    compiler = COMPILER
    percent, seed, argv = suite.sample_flags(argv)
    if argv[:1] == ["--compiler"] and len(argv) == 2:
        compiler = Path(shutil.which(argv[1]) or argv[1]).resolve()
    elif argv:
        print("usage: test_packaging.py [--compiler PYK] [--sample PERCENT [--seed N]]",
              file=sys.stderr)
        return 2
    if not compiler.is_file():
        print(f"packaging: FAILED -- no compiler at {compiler}; `make build` writes it")
        suite.footer("packaging", 0, 1, "nothing to package")
        return 1
    try:
        subprocess.run([str(compiler), "--version"], capture_output=True, timeout=TIMEOUT)
    except OSError as e:
        print(f"packaging: FAILED -- {compiler} does not run on this machine ({e.strerror}); "
              "it was built for another platform. `make clean && make` rebuilds it here.")
        suite.footer("packaging", 0, 1, "the compiler is for another platform")
        return 1
    check = Checks()
    groups = suite.sample(["stage", "deb", "install.sh", "macho", "docker and nix",
                           "changelog", "built"], percent, seed, "groups")
    if percent is not None:
        print(f"packaging: {percent:g}% of the groups of checks, seed {seed}: "
              f"{', '.join(groups)}.", flush=True)
    if "stage" in groups:
        check_stage(check, compiler)
    if "deb" in groups or "install.sh" in groups:
        vendored = all(path.exists() for path, _ in packaging.server.vendor_files())
        with tempfile.TemporaryDirectory(prefix="pyk-packaging-") as directory:
            tree = packaging.stage(compiler, Path(directory) / f"pyking-{packaging.version()}",
                                   vendor=vendored)
            if "deb" in groups:
                check_deb(check, tree)
            if "install.sh" in groups:
                check_install_sh(check, tree)
    if "macho" in groups:
        check_macho(check)
    if "docker and nix" in groups:
        check_docker_nix(check)
    if "changelog" in groups:
        check_changelog(check)
    built = check_built(check) if "built" in groups else 0
    for failure in check.failures:
        print(f"packaging: FAILED {failure}")
    print("packaging: the shipped tree, installed as Homebrew would, "
          f"{'OK' if not check.failures else 'with failures'}.")
    print(f"packaging: {built} built package{'' if built == 1 else 's'} in "
          f"{packaging.BUILD.relative_to(REPO)}/ checked"
          + ("" if built else " (none built; `make packaging` on a Mac builds one)") + ".")
    failed = len(check.failures)
    suite.footer("packaging", check.count - failed, failed,
                 f"the staged tree, {built} built package{'' if built == 1 else 's'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
