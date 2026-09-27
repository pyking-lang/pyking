#!/usr/bin/env python3
"""Builds the packages Pyking is installed from on another machine. Each
package format is one entry in FORMATS; the only one so far is Homebrew,
for macOS, which ships a universal (arm64 + x86_64) `pyk` with no
dependency beyond the system itself. Everything is written under
build/ beside this file. See README.md beside this file and
docs/build.md ("Packaging").

Every format ships the same tree, `stage` builds it: the executable,
lib/, build/pyking.js and the web tools, at the paths they have in the
repository, since that is where `pyk` looks for them (src/install.ml).

Usage: `make packaging`, or directly:

    python3 packaging.py build [--archs arm64,x86_64]   every format
                                     (Homebrew: on an Apple Silicon Mac)
    python3 packaging.py setup             make the release toolchains, once
    python3 packaging.py release [--yes]   publish the build: release + tap
    python3 packaging.py install-local     brew install the local build
    python3 packaging.py uninstall-local   and remove it again
    python3 packaging.py stage --binary PYK --dest DIR
    python3 packaging.py formula --tarball FILE --url URL --output FILE

Data structures:
    Refusal -- why a package cannot be built here, as a message.
    Homebrew -- the Homebrew format: a tarball and two formulas, and the
      release toolchains they are built with (`setup`).

Functions:
    version() -- the version, from VERSION.
    stage(binary, destination) -- the shipped tree, with this binary.
    tarball(source, output) -- a reproducible .tar.gz; answers its sha256.
    macho_archs(path) -- the architectures a Mach-O file holds.
    formula(url, sha256, archs) -- a Homebrew formula, as text.
    main(argv) -- the command-line entry point.
"""

import argparse
import gzip
import hashlib
import json
import os
import platform
import shlex
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
BUILD = HERE / "build"

sys.path.insert(0, str(REPO / "tools" / "webrun"))

import server  # noqa: E402  (after sys.path, which is what finds it)

NAME = "pyking"
# The code repository is private, so what a user downloads is kept in a
# public repository of its own, holding both the releases and the formula.
# Homebrew finds the tap `pyking-lang/macos` in the repository
# `pyking-lang/homebrew-macos`, which is what makes INSTALL work.
PUBLIC_REPO = "pyking-lang/homebrew-macos"
INSTALL = "brew install pyking-lang/macos/pyking"
HOMEPAGE = f"https://github.com/{PUBLIC_REPO}"
RELEASES = HOMEPAGE + "/releases/download"
DESCRIPTION = "Compiler and interpreter for Pyking, a small statically typed Python-like language"
LICENSE = "MIT"
MACOS_MINIMUM = "11.0"
MACOS_MINIMUM_NAME = "big_sur"
LOCAL_TAP = "pyking-lang/local"

# What the shipped tree holds, as (path in the repository, path in the
# package). A directory is copied with only the files SHIPPED_SUFFIXES
# allows, which keeps editor backups, caches and stray temporary files
# out of a package without listing them.
SHIPPED = [
    ("LICENSE", "LICENSE"),
    ("PYKING-TUTORIAL.md", "PYKING-TUTORIAL.md"),
    ("lib", "lib"),
    ("build/pyking.js", "build/pyking.js"),
    ("tools/webrun/server.py", "tools/webrun/server.py"),
    ("tools/webrun/package.json", "tools/webrun/package.json"),
    ("tools/webrun/assets", "tools/webrun/assets"),
    ("tools/webrun/vendor", "tools/webrun/vendor"),
    ("tools/notebook/notebook.py", "tools/notebook/notebook.py"),
    ("tools/notebook/package.json", "tools/notebook/package.json"),
    ("tools/notebook/assets", "tools/notebook/assets"),
    ("tools/playground/playground.py", "tools/playground/playground.py"),
    ("tools/playground/assets", "tools/playground/assets"),
]
SHIPPED_SUFFIXES = {".pyk", ".js", ".ml", ".mli", ".py", ".c", ".h", ".java",
                    ".css", ".html", ".json", ".md", ".woff2"}

# CPU types in a Mach-O header (mach/machine.h).
CPU_TYPES = {0x01000007: "x86_64", 0x0100000C: "arm64"}

# How each architecture's toolchain is reached: an opam switch built for
# MACOS_MINIMUM, the arm64 one beside your usual switches and the x86_64
# one run under Rosetta by opam's own x86_64 binary, with a root of its
# own (README.md, "One-time setup"). $PYK_ARM64 / $PYK_X86_64 say otherwise.
RELEASE_SWITCH = "pyking-release"
OPAM_X86_64_VERSION = "2.6.0"
OCAML_VERSION = "5.5.0"
OPAM_X86_64 = "~/.local/bin/opam-x86_64"
TOOLCHAINS = {
    "arm64": ("PYK_ARM64", f"opam exec --switch {RELEASE_SWITCH} --"),
    "x86_64": ("PYK_X86_64", "arch -x86_64 {home}/.local/bin/opam-x86_64 exec "
               f"--root {{home}}/.opam-x86_64 --switch {RELEASE_SWITCH} --"),
}
# What creates each of those switches, for the refusal that asks for one.
SETUP = {
    "arm64": [f"MACOSX_DEPLOYMENT_TARGET={MACOS_MINIMUM} opam switch create "
              f"{RELEASE_SWITCH} {OCAML_VERSION} --no-switch",
              f"opam install --switch {RELEASE_SWITCH} dune"],
    "x86_64": ["softwareupdate --install-rosetta --agree-to-license",
               "mkdir -p ~/.local/bin && curl -fL -o " + OPAM_X86_64
               + f" https://github.com/ocaml/opam/releases/download/{OPAM_X86_64_VERSION}"
               f"/opam-{OPAM_X86_64_VERSION}-x86_64-macos && chmod +x " + OPAM_X86_64,
               f"arch -x86_64 {OPAM_X86_64} init --root ~/.opam-x86_64 --bare --no-setup",
               f"arch -x86_64 /usr/bin/env MACOSX_DEPLOYMENT_TARGET={MACOS_MINIMUM} "
               f"{OPAM_X86_64} switch create --root ~/.opam-x86_64 {RELEASE_SWITCH} {OCAML_VERSION}",
               f"arch -x86_64 {OPAM_X86_64} install --root ~/.opam-x86_64 "
               f"--switch {RELEASE_SWITCH} dune"],
}


class Refusal(Exception):
    """Why a package cannot be built here: a message for the user."""


def version():
    """The version, from VERSION at the root. () -> String"""
    return (REPO / "VERSION").read_text().strip()


def run(command, **kwargs):
    """Runs a command, printing it first; raises Refusal when it fails.
    [String] -> {..} -> CompletedProcess"""
    print("  $ " + shlex.join(str(c) for c in command))
    try:
        return subprocess.run([str(c) for c in command], check=True, **kwargs)
    except FileNotFoundError:
        raise Refusal(f"{command[0]} not found")
    except subprocess.CalledProcessError as e:
        raise Refusal(f"`{shlex.join(str(c) for c in command)}` failed "
                      f"(exit {e.returncode})")


# --- the shipped tree ------------------------------------------------------


def _shipped(path):
    """Whether a file under a shipped directory goes in the package.
    Path -> Bool"""
    return path.suffix in SHIPPED_SUFFIXES and not path.name.startswith((".", "#"))


def stage(binary, destination, vendor=True):
    """Builds the shipped tree in destination, with `binary` as its `pyk`.
    Refuses when something it ships has not been built or downloaded;
    `vendor` false ships whatever of vendor/ there is, for a test that
    renders no page. Path -> Path -> Bool -> Path"""
    shipped = [(s, t) for s, t in SHIPPED
               if vendor or s != "tools/webrun/vendor" or (REPO / s).exists()]
    missing = [source for source, _ in shipped if not (REPO / source).exists()]
    if vendor:
        missing += [str(path.relative_to(REPO)) for path, _ in server.vendor_files()
                    if not path.exists()][:1]
    if missing:
        raise Refusal("not built or not downloaded yet: " + ", ".join(missing)
                      + " (`make build` and `make vendor` write them)")
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    shutil.copy2(binary, destination / "pyk")
    (destination / "pyk").chmod(0o755)
    for source, target in shipped:
        origin = REPO / source
        if origin.is_file():
            (destination / target).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(origin, destination / target)
            continue
        for path in sorted(origin.rglob("*")):
            if path.is_file() and _shipped(path) and "__pycache__" not in path.parts:
                copy = destination / target / path.relative_to(origin)
                copy.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, copy)
    return destination


def tarball(source, output):
    """Packs a directory as output, a .tar.gz whose one top-level entry is
    the directory's name. Reproducible: sorted, owned by root, dated 0.
    Answers the archive's sha256. Path -> Path -> String"""
    def normalised(info):
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        info.mode = 0o755 if info.isdir() or info.mode & 0o111 else 0o644
        return info

    output.parent.mkdir(parents=True, exist_ok=True)
    with open(output, "wb") as raw, \
            gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped, \
            tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as archive:
        paths = [source] + sorted(source.rglob("*"))
        for path in paths:
            name = str(Path(source.name) / path.relative_to(source))
            archive.add(path, arcname=name, recursive=False, filter=normalised)
    return hashlib.sha256(output.read_bytes()).hexdigest()


def macho_archs(path):
    """The architectures a Mach-O file holds -- several for a universal
    one -- read from its header, so it works on any system. Empty for a
    file that is not Mach-O. Path -> [String]"""
    with open(path, "rb") as f:
        head = f.read(8)
        if len(head) < 8:
            return []
        if head[:4] == b"\xca\xfe\xba\xbe":             # universal
            count = struct.unpack(">I", head[4:8])[0]
            found = []
            for _ in range(count):
                cputype = struct.unpack(">i16x", f.read(20))[0] & 0xFFFFFFFF
                found.append(CPU_TYPES.get(cputype, hex(cputype)))
            return found
        if head[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):   # thin
            cputype = struct.unpack("<i", head[4:8])[0] & 0xFFFFFFFF
            return [CPU_TYPES.get(cputype, hex(cputype))]
    return []


# --- Homebrew ----------------------------------------------------------------


def formula(url, sha256, archs):
    """The Homebrew formula installing the package at url. It builds
    nothing: the tarball holds the binary, and the formula puts the tree
    in libexec/ and links bin/pyk to it. String -> String -> [String] ->
    String"""
    only = "" if set(archs) >= {"arm64", "x86_64"} else (
        f"\n  depends_on arch: :{'arm64' if archs == ['arm64'] else 'x86_64'}")
    return f'''# Generated by tools/packaging/packaging.py -- do not edit; run
# `make packaging` in the pyking repository.
class Pyking < Formula
  desc "{DESCRIPTION}"
  homepage "{HOMEPAGE}"
  url "{url}"
  sha256 "{sha256}"
  version "{version()}"
  license "{LICENSE}"

  depends_on macos: :{MACOS_MINIMUM_NAME}{only}

  def install
    # The tree stays together: pyk finds lib/, build/ and tools/ beside
    # its own resolved path.
    libexec.install Dir["*"]
    bin.install_symlink libexec/"pyk"
  end

  def caveats
    <<~EOS
      `pyk notebook` and `pyk playground` need Python 3.14 or later on
      your PATH; nothing else does. Compiling for a target and running
      the result needs that target's own tools (node, cc, javac, ...).

      To read the tutorial as a notebook:
        pyk notebook #{{opt_libexec}}/PYKING-TUTORIAL.md
    EOS
  end

  test do
    (testpath/"hello.pyk").write "print(\\"hello\\", 1 + 2)\\n"
    assert_equal "hello 3\\n", shell_output("#{{bin}}/pyk #{{testpath}}/hello.pyk")
    assert_match version.to_s, shell_output("#{{bin}}/pyk --version")
  end
end
'''


class Homebrew:
    """The Homebrew format: a universal macOS `pyk` in a tarball, and two
    formulas for it -- one naming the GitHub release it is to be attached
    to, one naming the file itself, for installing before publishing."""

    name = "homebrew"
    archs = ("arm64", "x86_64")

    def refusal(self):
        """Why this machine cannot build the format, or None.
        () -> String?"""
        if sys.platform != "darwin":
            return ("the Homebrew package holds macOS binaries, so it is "
                    "built on a Mac; nothing was built here")
        for tool in ("lipo", "otool", "codesign"):
            if not shutil.which(tool):
                return f"{tool} not found; install the Xcode command line tools"
        return None

    def toolchain(self, arch):
        """The command prefix that runs arch's release toolchain on this Mac.
        String -> [String]"""
        host = platform.machine()
        if arch != host and not (arch == "x86_64" and host == "arm64"):
            raise Refusal(f"an {host} Mac cannot build for {arch}; build the "
                          f"package on an Apple Silicon Mac, or pass --archs {host}")
        variable, default = TOOLCHAINS[arch]
        spelled = os.environ.get(variable) or default.format(home=Path.home())
        if arch == host:
            spelled = spelled.removeprefix("arch -x86_64 ")
        return shlex.split(spelled)

    def environment(self):
        """The environment a build runs in: the macOS floor, and none of the
        current switch's variables, which would point a release toolchain at
        the wrong compiler. () -> {..}"""
        env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET=MACOS_MINIMUM)
        for key in list(env):
            if key.startswith(("OPAM_", "OCAML")) or key == "CAML_LD_LIBRARY_PATH":
                del env[key]
        return env

    def preflight(self, arch):
        """Refuses before anything is built when arch's toolchain is
        missing, builds for another architecture, has no dune, or has a
        runtime compiled for a macOS newer than MACOS_MINIMUM -- which the
        linker would warn about and the binary would then not keep.
        String -> ()"""
        prefix = self.toolchain(arch)
        env = self.environment()
        fix = ("\n  Create it once (tools/packaging/README.md, \"One-time setup\"):\n"
               + "".join(f"    {line}\n" for line in SETUP[arch])
               + f"  or name another with ${TOOLCHAINS[arch][0]}.")

        def ask(*command):
            result = subprocess.run(prefix + list(command), capture_output=True,
                                    text=True, env=env)
            return result.stdout.strip() if result.returncode == 0 else None

        where = shlex.join(prefix)
        program = next((word for word in prefix if word != "arch" and not word.startswith("-")), None)
        if program and not shutil.which(program):
            raise Refusal(f"{program} is not installed, so there is no {arch} toolchain "
                          f"through `{where}`." + fix)
        found = ask("ocamlopt", "-config-var", "architecture")
        expected = {"arm64": "arm64", "x86_64": "amd64"}[arch]
        if found != expected:
            raise Refusal(f"no {arch} OCaml toolchain through `{where}`"
                          + (f" (it builds for {found})" if found else "") + "." + fix)
        if ask("dune", "--version") is None:
            raise Refusal(f"the {arch} toolchain through `{where}` has no dune." + fix)
        library = Path(ask("ocamlopt", "-where"))
        newest = max((self.minimum_macos(library / name)
                      for name in ("libasmrun.a", "stdlib.a")), default=(0,))
        if newest > tuple(int(n) for n in MACOS_MINIMUM.split(".")):
            raise Refusal(
                f"the {arch} toolchain through `{where}` was compiled for macOS "
                f"{'.'.join(map(str, newest))}, and the package promises "
                f"{MACOS_MINIMUM}: a binary linked from it may not start there. "
                f"Build a switch for {MACOS_MINIMUM}." + fix)

    def minimum_macos(self, path):
        """The newest macOS any object in an archive was compiled for, from
        its load commands. Path -> (Int, ...)"""
        listed = subprocess.run(["otool", "-l", path], capture_output=True, text=True)
        versions = [tuple(int(n) for n in line.split()[1].split("."))
                    for line in listed.stdout.splitlines()
                    if line.split()[:1] in (["minos"], ["version"])
                    and line.split()[1][:1].isdigit()]
        return max(versions, default=(0,))

    def binary(self, arch):
        """Builds pyk for one architecture, in a dune build directory of
        its own, and answers its path. String -> Path"""
        prefix = self.toolchain(arch)
        directory = BUILD / f"_build-{arch}"
        # dune makes the build directory but not its parent.
        BUILD.mkdir(parents=True, exist_ok=True)
        run(prefix + ["dune", "build", "--root", REPO, "--build-dir", directory,
                      "src/pyk.exe"], env=self.environment())
        path = directory / "default" / "src" / "pyk.exe"
        if macho_archs(path) != [arch]:
            raise Refusal(f"{path} is {macho_archs(path)}, not {arch}")
        return path

    def check_linkage(self, path):
        """Refuses a binary that links anything but the system's own
        libraries: the package promises no dependencies. Path -> ()"""
        listed = subprocess.run(["otool", "-L", path], capture_output=True,
                                text=True, check=True).stdout
        foreign = sorted({lib for lib in self.linked(listed)
                          if not lib.startswith(("/usr/lib/", "/System/"))})
        if foreign:
            raise Refusal(f"{path} links {', '.join(foreign)}, which a Mac "
                          "without Homebrew's libraries would not have")

    @staticmethod
    def linked(listing):
        """The libraries an `otool -L` listing names. A library line is
        indented; the others name the file -- once per architecture, for a
        universal one. String -> [String]"""
        return [line.split()[0] for line in listing.splitlines()
                if line[:1] in ("\t", " ") and line.strip()]

    def build(self, archs):
        """Builds the tarball and both formulas. [String] -> ()"""
        archs = sorted(archs)
        # Every toolchain is checked before any is used, so a missing one is
        # reported at once rather than after the others have built.
        for arch in archs:
            self.preflight(arch)
        binaries = [self.binary(arch) for arch in archs]
        universal = BUILD / "pyk-macos"
        if len(binaries) > 1:
            run(["lipo", "-create", "-output", universal] + binaries)
        else:
            shutil.copy2(binaries[0], universal)
        # An arm64 binary must carry a signature to start; lipo keeps each
        # slice's, and signing again ad hoc makes sure of it.
        run(["codesign", "--force", "--sign", "-", universal])
        if sorted(macho_archs(universal)) != archs:
            raise Refusal(f"{universal} holds {macho_archs(universal)}, not {archs}")
        self.check_linkage(universal)

        v = version()
        suffix = "" if set(archs) >= set(self.archs) else "-" + "-".join(archs)
        top = f"{NAME}-{v}"
        tree = stage(universal, BUILD / "stage" / top)
        name = f"{NAME}-{v}-macos{suffix}.tar.gz"
        archive = BUILD / name
        sha = tarball(tree, archive)

        release = BUILD / "homebrew" / "pyking.rb"
        release.parent.mkdir(parents=True, exist_ok=True)
        release.write_text(formula(f"{RELEASES}/v{v}/{name}", sha, archs))
        local = BUILD / "homebrew-local" / "pyking.rb"
        local.parent.mkdir(parents=True, exist_ok=True)
        local.write_text(formula(archive.resolve().as_uri(), sha, archs))
        print(f"homebrew: {archive.relative_to(REPO)} ({', '.join(archs)}, "
              f"{archive.stat().st_size / 1048576:.1f} MB, sha256 {sha[:12]}…)")
        print(f"homebrew: {release.relative_to(REPO)} (for the release v{v})")
        print(f"homebrew: {local.relative_to(REPO)} (for `make packaging-install`)")
        if suffix:
            print(f"homebrew: NOTE this package holds {', '.join(archs)} only; "
                  "do not publish it as the release.")

    def install_local(self):
        """Installs the local build through the tap pyking-lang/local.
        () -> ()"""
        local = BUILD / "homebrew-local" / "pyking.rb"
        if not local.exists():
            raise Refusal("nothing built yet; run `make packaging` first")
        if not shutil.which("brew"):
            raise Refusal("brew not found")
        repository = Path(subprocess.run(["brew", "--repository"], capture_output=True,
                                         text=True, check=True).stdout.strip())
        tap = repository / "Library" / "Taps" / "pyking-lang" / "homebrew-local"
        if not tap.exists():
            run(["brew", "tap-new", "--no-git", LOCAL_TAP])
        (tap / "Formula").mkdir(parents=True, exist_ok=True)
        shutil.copy2(local, tap / "Formula" / "pyking.rb")
        formula_name = f"{LOCAL_TAP}/pyking"
        # A rebuilt tarball keeps its version and changes its checksum, so
        # the copy brew cached from the last install is dropped first.
        cached = subprocess.run(["brew", "--cache", formula_name], capture_output=True,
                                text=True).stdout.strip()
        if cached:
            Path(cached).unlink(missing_ok=True)
        installed = subprocess.run(["brew", "list", "--versions", formula_name],
                                   capture_output=True).returncode == 0
        run(["brew", "reinstall" if installed else "install", formula_name])
        run(["brew", "test", formula_name])

    def setup(self):
        """Makes both release toolchains (README.md, "One-time setup"),
        running each step only when it has not been done, then checks them
        as `build` would. Prints one line per architecture and a verdict,
        and answers whether both are ready. () -> Bool"""
        if sys.platform != "darwin" or platform.machine() != "arm64":
            print("packaging setup: FAILED -- the release toolchains are set up on "
                  "an Apple Silicon Mac, and this is not one.")
            return False
        results = {}
        for arch, steps in (("arm64", self._arm64_steps()), ("x86_64", self._x86_64_steps())):
            print(f"\n{arch}:")
            try:
                for label, done, do in steps:
                    if done():
                        print(f"  done already: {label}")
                        continue
                    print(f"  {label}")
                    do()
                    if not done():
                        raise Refusal(f"{label}: the step ran, but did not take effect")
                self.preflight(arch)
                results[arch] = None
            except Refusal as refusal:
                results[arch] = str(refusal)
        print()
        for arch, problem in results.items():
            print(f"  {arch:<7} {'ready' if problem is None else 'FAILED: ' + problem}")
        ok = all(problem is None for problem in results.values())
        print()
        print("packaging setup: " + ("SUCCEEDED -- both release toolchains are ready; "
                                     "`make packaging` builds the package."
                                     if ok else "FAILED -- see above; running it again "
                                     "resumes where it stopped."))
        return ok

    def _opam(self, opam, root, *args):
        """An opam command for a release toolchain, in the environment a
        build uses. [String] -> String? -> String... -> [String]"""
        return opam + (["--root", root] if root else []) + list(args)

    def _has_switch(self, opam, root):
        """Whether the release switch exists. [String] -> String? -> Bool"""
        listed = subprocess.run(self._opam(opam, None, "switch", "list", "--short")
                                + (["--root", root] if root else []),
                                capture_output=True, text=True, env=self.environment())
        return listed.returncode == 0 and RELEASE_SWITCH in listed.stdout.split()

    def _switch_works(self, opam, root):
        """Whether the release switch exists and its compiler runs: a
        `switch create` that was interrupted leaves a switch that is listed
        but has no OCaml in it. [String] -> String? -> Bool"""
        return self._has_switch(opam, root) and subprocess.run(
            self._opam(opam, None, "exec") + (["--root", root] if root else [])
            + ["--switch", RELEASE_SWITCH, "--", "ocamlopt", "-version"],
            capture_output=True, env=self.environment()).returncode == 0

    def _has_dune(self, opam, root):
        """Whether the release switch has dune. [String] -> String? -> Bool"""
        return subprocess.run(
            self._opam(opam, None, "exec") + (["--root", root] if root else [])
            + ["--switch", RELEASE_SWITCH, "--", "dune", "--version"],
            capture_output=True, env=self.environment()).returncode == 0

    def _switch_steps(self, opam, root):
        """Creating the release switch for MACOS_MINIMUM, and giving it dune.
        [String] -> String? -> [(String, () -> Bool, () -> ())]"""
        rooted = ["--root", root] if root else []
        log = f"{root or '~/.opam'}/log"
        slow = "10-30 minutes under Rosetta" if opam[0] == "arch" else "several minutes"

        def create():
            # An interrupted `switch create` leaves either a listed switch
            # with no compiler in it, or only its directory, unregistered,
            # which opam then refuses to create a switch over.
            leftover = Path(root or os.environ.get("OPAMROOT") or Path.home() / ".opam") \
                / RELEASE_SWITCH
            if self._has_switch(opam, root):
                print(f"  (removing the incomplete switch {RELEASE_SWITCH} first)")
                run(opam + ["switch", "remove"] + rooted + [RELEASE_SWITCH, "--yes"],
                    env=self.environment())
            elif leftover.is_dir():
                print(f"  (removing {leftover}, left by an interrupted run)")
                shutil.rmtree(leftover)
            run(opam + ["switch", "create"] + rooted
                + [RELEASE_SWITCH, OCAML_VERSION, "--no-switch", "--yes"],
                env=self.environment())

        return [
            (f"create the switch {RELEASE_SWITCH} (OCaml {OCAML_VERSION}, for macOS "
             f"{MACOS_MINIMUM}). This compiles OCaml, which takes {slow} and "
             "prints nothing while it does; to watch it, run\n"
             f'    tail -f "$(ls -t {log}/*.out | head -1)"\n  in another terminal',
             lambda: self._switch_works(opam, root), create),
            (f"install dune into {RELEASE_SWITCH}",
             lambda: self._has_dune(opam, root),
             lambda: run(opam + ["install"] + rooted
                         + ["--switch", RELEASE_SWITCH, "dune", "--yes"],
                         env=self.environment())),
        ]

    def _arm64_steps(self):
        """The arm64 toolchain's steps. () -> [(String, () -> Bool, () -> ())]"""
        def need_opam():
            raise Refusal("opam not found; install it (`brew install opam`) and "
                          "run this again")
        return [("opam", lambda: shutil.which("opam") is not None, need_opam)] \
            + self._switch_steps(["opam"], None)

    def _x86_64_steps(self):
        """The x86_64 toolchain's steps: Rosetta, opam's x86_64 binary, its
        root, then the switch. () -> [(String, () -> Bool, () -> ())]"""
        opam_path = Path(OPAM_X86_64).expanduser()
        root = str(Path("~/.opam-x86_64").expanduser())
        opam = ["arch", "-x86_64", str(opam_path)]
        url = (f"https://github.com/ocaml/opam/releases/download/{OPAM_X86_64_VERSION}"
               f"/opam-{OPAM_X86_64_VERSION}-x86_64-macos")

        def rosetta():
            return subprocess.run(["arch", "-x86_64", "/usr/bin/true"],
                                  capture_output=True).returncode == 0

        def has_opam():
            return (opam_path.is_file() and os.access(opam_path, os.X_OK)
                    and macho_archs(opam_path) == ["x86_64"])

        def download():
            opam_path.parent.mkdir(parents=True, exist_ok=True)
            print(f"  $ download {url}")
            partial = opam_path.with_suffix(".part")
            try:
                urllib.request.urlretrieve(url, partial)
            except OSError as e:
                raise Refusal(f"cannot download {url}: {e}")
            partial.chmod(0o755)
            partial.replace(opam_path)

        return [
            ("install Rosetta", rosetta,
             lambda: run(["softwareupdate", "--install-rosetta", "--agree-to-license"])),
            (f"download opam {OPAM_X86_64_VERSION} for x86_64 to {OPAM_X86_64}",
             has_opam, download),
            (f"initialise the opam root {root}",
             lambda: (Path(root) / "config").exists(),
             lambda: run(opam + ["init", "--root", root, "--bare", "--no-setup", "--yes"],
                         env=self.environment())),
        ] + self._switch_steps(opam, root)

    def release(self, assume_yes):
        """Publishes the build: a release v<VERSION> of PUBLIC_REPO holding
        the tarball, checked by downloading it back, then the formula
        committed and pushed to the same repository, which is the tap. Checks everything it can first,
        asks before changing anything unless assume_yes, and never replaces
        a published release. Prints a verdict; answers whether it succeeded.
        Bool -> Bool"""
        v = version()
        tag = f"v{v}"
        name = f"{NAME}-{v}-macos.tar.gz"
        archive = BUILD / name
        rb = BUILD / "homebrew" / "pyking.rb"
        url = f"{RELEASES}/{tag}/{name}"

        # 1. The build: this version, universal, and its formula agreeing.
        if not archive.exists():
            others = sorted(p.name for p in BUILD.glob(f"{NAME}-*-macos*.tar.gz"))
            raise Refusal(f"no universal package for {v} (no {name} in "
                          f"{BUILD.relative_to(REPO)}/"
                          + (f"; found {', '.join(others)}" if others else "")
                          + "); run `make packaging` first")
        sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        text = rb.read_text() if rb.exists() else ""
        if f'url "{url}"' not in text or f'sha256 "{sha}"' not in text:
            raise Refusal(f"{rb.relative_to(REPO)} does not describe {name}; "
                          "run `make packaging` again")

        # 2. The tools and the two repositories.
        if not shutil.which("gh") or not shutil.which("git"):
            raise Refusal("git and gh (the GitHub CLI) are needed: `brew install gh`, "
                          "then `gh auth login`")
        if subprocess.run(["gh", "auth", "status"], capture_output=True).returncode:
            raise Refusal("gh is not logged in; run `gh auth login`")
        # Checked here, not left to the commit: a commit that fails comes
        # after the release exists, which would leave it without a formula.
        for key in ("user.name", "user.email"):
            # Asked from outside any repository, as the fresh clone will be:
            # a name set only in this repository's own config is not used there.
            if not subprocess.run(["git", "config", key], capture_output=True, text=True,
                                  cwd=tempfile.gettempdir()).stdout.strip():
                raise Refusal(f"git has no {key}, which the tap commit needs: "
                              f'git config --global {key} "..."')
        repo = PUBLIC_REPO
        viewed = subprocess.run(["gh", "repo", "view", repo, "--json",
                                 "visibility,isEmpty"], capture_output=True, text=True)
        if viewed.returncode:
            raise Refusal(f"the repository {repo} does not exist or is not "
                          f"reachable; create it with\n    gh repo create {repo} "
                          '--public --description "Pyking for macOS: releases and '
                          'Homebrew tap"')
        info = json.loads(viewed.stdout)
        if info.get("visibility") != "PUBLIC":
            raise Refusal(f"{repo} is {info.get('visibility', '?').lower()}; it must be "
                          "public, since Homebrew downloads without credentials:\n"
                          f"    gh repo edit {repo} --visibility public "
                          "--accept-visibility-change-consequences")
        if subprocess.run(["gh", "release", "view", tag, "--repo", repo],
                          capture_output=True).returncode == 0:
            raise Refusal(f"{repo} already has a release {tag}. A published "
                          "tarball is never replaced, since everyone who installed "
                          "it holds its checksum; bump VERSION and build again")

        # 3. Say what will happen, and ask.
        print(f"\nAbout to publish Pyking {v}:")
        print(f"  1. create the release {tag} of {repo}, with {name}"
              f" ({archive.stat().st_size / 1048576:.1f} MB, sha256 {sha[:12]}…)")
        print(f"  2. commit Formula/pyking.rb for {v} to {repo} and push it")
        if not assume_yes:
            try:
                answer = input("Publish? [y/N] ")
            except EOFError:
                answer = ""
            if answer.strip().lower() not in ("y", "yes"):
                print("release: nothing was published.")
                return False

        with tempfile.TemporaryDirectory(prefix="pyk-release-") as directory:
            work = Path(directory)
            # 4. The release. A repository with no commit cannot hold a tag,
            #    so an empty one is given a README first.
            if info.get("isEmpty"):
                self._first_commit(work / "first", repo, {
                    "README.md": self._release_readme()}, "Describe the releases")
            notes = (f"Pyking {v} for macOS 11 or later: one universal `pyk` for Apple "
                     f"Silicon and Intel, with no dependencies.\n\n"
                     f"    {INSTALL}\n\n"
                     f"sha256: `{sha}`\n")
            run(["gh", "release", "create", tag, archive, "--repo", repo,
                 "--title", f"Pyking {v}", "--notes", notes])
            fetched = work / name
            print(f"  $ download {url}")
            try:
                urllib.request.urlretrieve(url, fetched)
            except OSError as e:
                raise Refusal(f"the release was created, but {url} cannot be "
                              f"downloaded ({e}); the tap was not changed")
            if hashlib.sha256(fetched.read_bytes()).hexdigest() != sha:
                raise Refusal(f"the release was created, but {url} does not have the "
                              "built tarball's checksum; the tap was not changed")

            # 5. The formula, beside the releases: this repository is the tap.
            tap = work / "tap"
            run(["gh", "repo", "clone", repo, tap])
            (tap / "Formula").mkdir(exist_ok=True)
            shutil.copy2(rb, tap / "Formula" / "pyking.rb")
            run(["git", "-C", tap, "add", "Formula/pyking.rb"])
            if subprocess.run(["git", "-C", tap, "diff", "--cached", "--quiet"]).returncode:
                run(["git", "-C", tap, "commit", "-m", f"pyking {v}"])
                run(["git", "-C", tap, "push", "origin", "HEAD"])
            else:
                print(f"  ({repo} already has this formula)")
        print(f"\nrelease: SUCCEEDED -- Pyking {v} is published. Install it with\n"
              f"    {INSTALL}\n"
              "or, where an earlier version is installed, `brew update && brew upgrade pyking`.")
        return True

    def _first_commit(self, directory, repo, files, message):
        """Gives an empty repository its first commit on main.
        Path -> String -> {String: String} -> String -> ()"""
        run(["gh", "repo", "clone", repo, directory])
        run(["git", "-C", directory, "symbolic-ref", "HEAD", "refs/heads/main"])
        for name, text in files.items():
            (directory / name).write_text(text)
            run(["git", "-C", directory, "add", name])
        run(["git", "-C", directory, "commit", "-m", message])
        run(["git", "-C", directory, "push", "origin", "HEAD"])

    def _release_readme(self):
        """The README of the releases repository. () -> String"""
        return (f"# Pyking for macOS\n\nReleases of Pyking for macOS, and the "
                "Homebrew formula that installs them: each release a "
                "universal `pyk` (Apple Silicon and Intel, macOS 11 or later) with "
                "no dependencies.\n\nInstall with [Homebrew](https://brew.sh):\n\n"
                f"```sh\n{INSTALL}\n```\n\n"
                "`pyk notebook` and `pyk playground` also need Python 3.14 or later "
                "on the `PATH`.\n")

    def uninstall_local(self):
        """Removes what install_local installed, and the tap. () -> ()"""
        subprocess.run(["brew", "uninstall", f"{LOCAL_TAP}/pyking"])
        subprocess.run(["brew", "untap", LOCAL_TAP])


FORMATS = {"homebrew": Homebrew()}


def main(argv=None):
    """The command-line entry point. [String]? -> Int"""
    parser = argparse.ArgumentParser(prog="packaging.py",
                                     description="Build Pyking's packages.")
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="build every format")
    build.add_argument("--archs", default="",
                       help="comma-separated architectures (default: all)")
    commands.add_parser("setup", help="make the release toolchains, once")
    published = commands.add_parser("release", help="publish the build")
    published.add_argument("--yes", action="store_true", help="do not ask first")
    commands.add_parser("install-local", help="brew install the local build")
    commands.add_parser("uninstall-local", help="remove it again")
    staged = commands.add_parser("stage", help="the shipped tree, with a binary")
    staged.add_argument("--binary", required=True, type=Path)
    staged.add_argument("--dest", required=True, type=Path)
    staged.add_argument("--no-vendor", action="store_true",
                        help="ship vendor/ as it is, even incomplete")
    written = commands.add_parser("formula", help="a formula for a tarball")
    written.add_argument("--tarball", required=True, type=Path)
    written.add_argument("--url", required=True)
    written.add_argument("--output", required=True, type=Path)
    written.add_argument("--archs", default="arm64,x86_64")
    args = parser.parse_args(argv)

    try:
        if args.command == "build":
            for fmt in FORMATS.values():
                reason = fmt.refusal()
                if reason:
                    raise Refusal(f"{fmt.name}: {reason}")
                archs = [a for a in args.archs.split(",") if a] or list(fmt.archs)
                unknown = sorted(set(archs) - set(fmt.archs))
                if unknown:
                    raise Refusal(f"{fmt.name}: unknown architecture {', '.join(unknown)}")
                fmt.build(archs)
        elif args.command == "release":
            try:
                if not FORMATS["homebrew"].release(args.yes):
                    return 1
            except Refusal as refusal:
                print(f"packaging: {refusal}", file=sys.stderr)
                print("release: FAILED -- see above.")
                return 1
        elif args.command == "setup":
            if not FORMATS["homebrew"].setup():
                return 1
        elif args.command == "install-local":
            FORMATS["homebrew"].install_local()
        elif args.command == "uninstall-local":
            FORMATS["homebrew"].uninstall_local()
        elif args.command == "stage":
            stage(args.binary, args.dest, vendor=not args.no_vendor)
        elif args.command == "formula":
            sha = hashlib.sha256(args.tarball.read_bytes()).hexdigest()
            args.output.write_text(formula(args.url, sha, args.archs.split(",")))
    except Refusal as refusal:
        print(f"packaging: {refusal}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
