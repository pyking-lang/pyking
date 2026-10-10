#!/usr/bin/env python3
"""Builds the packages Pyking is installed from on another machine, and
publishes them. Each package format is one entry in FORMATS:

  homebrew  macOS: a universal (arm64 + x86_64) `pyk` in a tarball, and a
            Homebrew formula for it. Built on an Apple Silicon Mac.
  linux     Linux and WSL: a `pyk` per architecture, linked against an
            old glibc, as a tarball (which install.sh installs) and a
            .deb. Built in Docker.

Every format ships the same tree, which `stage` builds: the executable,
lib/ with each library's interpreter plugin, build/pyking.js,
build/plugin/ and the web tools, at the paths they have in the
repository, since that is where `pyk` looks for them (src/install.ml).
The plugins are compiled by `build_plugins` with the toolchain that
built the executable, since a plugin loads only into the `pyk` its
compiler built.
Everything is written under build/ beside this file, and one release on
GitHub holds every platform's files. See README.md beside this file and
docs/build.md ("Packaging").

Usage: `make packaging`, or directly:

    python3 packaging.py build [--formats F,..] [--archs A,..]
    python3 packaging.py setup [--formats F,..]   make the build toolchains
    python3 packaging.py release [--yes]   publish the build: release + tap
    python3 packaging.py install-local     install the local build here
    python3 packaging.py uninstall-local   and remove it again
    python3 packaging.py stage --binary PYK --dest DIR
    python3 packaging.py formula --tarball FILE --url URL --output FILE

Data structures:
    Refusal -- why a package cannot be built here, as a message.
    Homebrew -- the macOS format, and the toolchains it is built with.
    Linux -- the Linux format, and the Docker images it is built in.

Functions:
    version() -- the version, from VERSION.
    stage(binary, destination) -- the shipped tree, with this binary.
    build_plugins(tree, prefix) -- the tree's library plugins, compiled.
    tarball(source, output) -- a reproducible .tar.gz; answers its sha256.
    macho_archs(path) -- the architectures a Mach-O file holds.
    elf_info(path) -- an ELF file's architecture, and whether it is static.
    glibc_needed(path) -- the newest glibc version an ELF file asks for.
    deb(tree, arch, output) -- a .deb installing the tree.
    formula(url, sha256, archs) -- a Homebrew formula, as text.
    release_assets(v) -- every file a release of v holds.
    write_checksums(v) -- SHA256SUMS over the assets built.
    release(assume_yes) -- publishes the build, and tags it in CODE_REPO.
    main(argv) -- the command-line entry point.
"""

import argparse
import gzip
import hashlib
import io
import json
import os
import platform
import re
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
# The code repository is private, so what a user downloads lives in public
# repositories of its own: every release in RELEASES_REPO, and the Homebrew
# formula in TAP_REPO, which Homebrew knows as the tap `pyking-lang/tap`.
RELEASES_REPO = "pyking-lang/pyking-releases"
# The private code repository, where `make release` tags the commit a
# release was built from as `release-<version>`.
CODE_REPO = "pyking-lang/pyking"
TAP_REPO = "pyking-lang/homebrew-tap"
HOMEPAGE = f"https://github.com/{RELEASES_REPO}"
RELEASES = HOMEPAGE + "/releases/download"
BREW_INSTALL = "brew install pyking-lang/tap/pyking"
LINUX_INSTALL = f"curl -fsSL {HOMEPAGE}/releases/latest/download/install.sh | sh"
DESCRIPTION = "Compiler and interpreter for Pyking, a small statically typed Python-like language"
LICENSE = "MIT"
MAINTAINER = "pyking-lang <pyking-lang@users.noreply.github.com>"
PYTHON_MINIMUM = "3.10"
MACOS_MINIMUM = "11.0"
MACOS_MINIMUM_NAME = "big_sur"
LOCAL_TAP = "pyking-lang/local"
ARCHS = ("arm64", "x86_64")
# Other spellings of the two architectures, as uname, Debian and Docker
# write them.
ARCH_ALIASES = {"aarch64": "arm64", "amd64": "x86_64"}
INSTALL_SH = HERE / "install.sh"
DOCKERFILE = HERE / "linux" / "Dockerfile"

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
                    ".css", ".html", ".json", ".md", ".woff2", ".wav"}
# What a library plugin is compiled against: the interface of the one
# module of `pyk` a plugin names. `stage` ships the one from the build
# that made the binary, never this checkout's by accident, and a plugin
# itself (a .cmxs) is never copied -- `build_plugins` compiles it for the
# binary it will be loaded into.
PLUGIN_DIRECTORY = Path("build") / "plugin"
PLUGIN_INTERFACE = REPO / PLUGIN_DIRECTORY / "pyk_plugin.cmi"
PLUGIN_BUILT = Path("default") / "src" / "plugin" / ".pyk_plugin.objs" / "byte" / "pyk_plugin.cmi"

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


def shown(path):
    """A path as messages print it: relative to the repository when it is
    in it. Path -> Path"""
    try:
        return path.relative_to(REPO)
    except ValueError:
        return path


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


def stage(binary, destination, vendor=True, interface=None):
    """Builds the shipped tree in destination, with `binary` as its `pyk`
    and `interface` -- the pyk_plugin.cmi of the build that made it,
    this checkout's by default -- as what its library plugins are
    compiled against. The plugins themselves are `build_plugins`'s.
    Refuses when something it ships has not been built or downloaded;
    `vendor` false ships whatever of vendor/ there is, for a test that
    renders no page. Path -> Path -> Bool -> Path? -> Path"""
    interface = Path(interface) if interface else PLUGIN_INTERFACE
    shipped = [(s, t) for s, t in SHIPPED
               if vendor or s != "tools/webrun/vendor" or (REPO / s).exists()]
    missing = [source for source, _ in shipped if not (REPO / source).exists()]
    if not interface.exists():
        missing.append(str(shown(interface)))
    if vendor:
        missing += [str(shown(path)) for path, _ in server.vendor_files()
                    if not path.exists()][:1]
    if missing:
        raise Refusal("not built or not downloaded yet: " + ", ".join(missing)
                      + " (`make build` and `make vendor` write them)")
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    shutil.copy2(binary, destination / "pyk")
    (destination / "pyk").chmod(0o755)
    (destination / PLUGIN_DIRECTORY).mkdir(parents=True)
    shutil.copy2(interface, destination / PLUGIN_DIRECTORY / interface.name)
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


def plugin_sources(tree):
    """Every library under a tree's lib/ with an OCaml implementation, as
    the plugin it is to have. Path -> [Path]"""
    return sorted(ml.with_suffix(".cmxs") for ml in (tree / "lib").glob("*/*_external.ml"))


def build_plugins(tree, prefix=(), env=None):
    """Compiles the plugin of every library in a staged tree, with the
    tree's own `pyk` run through `prefix` -- the command that reaches the
    toolchain the binary was built with -- and refuses a library left
    without one. Path -> [String] -> {..}? -> [Path]"""
    run(list(prefix) + [tree / "pyk", "plugins", tree / "lib"], env=env)
    plugins = plugin_sources(tree)
    missing = [str(p.relative_to(tree)) for p in plugins if not p.exists()]
    if missing:
        raise Refusal("no plugin was built for " + ", ".join(missing))
    return plugins


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


# ELF machine numbers (elf.h).
ELF_MACHINES = {0x3E: "x86_64", 0xB7: "arm64"}


def elf_info(path):
    """An ELF file's architecture, and whether it is static -- whether it
    names no program interpreter, the dynamic loader a shared-library
    binary needs. None for a file that is not a 64-bit little-endian ELF.
    Path -> (String, Bool)?"""
    with open(path, "rb") as f:
        head = f.read(64)
        if len(head) < 64 or head[:4] != b"\x7fELF" or head[4] != 2 or head[5] != 1:
            return None
        machine = struct.unpack("<H", head[18:20])[0]
        phoff = struct.unpack("<Q", head[32:40])[0]
        phentsize, phnum = struct.unpack("<HH", head[54:58])
        interpreter = False
        for k in range(phnum):
            f.seek(phoff + k * phentsize)
            if struct.unpack("<I", f.read(4))[0] == 3:      # PT_INTERP
                interpreter = True
    return ELF_MACHINES.get(machine, hex(machine)), not interpreter


# The newest glibc a Linux `pyk` may ask for: AlmaLinux 8's, which is
# what the build image has, and Debian 10's.
GLIBC_FLOOR = (2, 28)


def glibc_needed(path):
    """The newest glibc version an ELF file asks for, read from the
    version names its dynamic symbols carry. (0,) for a file naming none.
    Path -> (Int, ...)"""
    found = re.findall(rb"GLIBC_(\d+)\.(\d+)(?:\.(\d+))?", path.read_bytes())
    versions = [tuple(int(n) for n in groups if n) for groups in found]
    return max(versions, default=(0,))


def canonical_arch(name):
    """An architecture's name as this module spells it. String -> String"""
    return ARCH_ALIASES.get(name, name)


# --- the .deb --------------------------------------------------------------

DEB_ARCH = {"arm64": "arm64", "x86_64": "amd64"}
UNAME_ARCH = {"arm64": "aarch64", "x86_64": "x86_64"}


def _tar_gz(entries):
    """A reproducible .tar.gz, in memory, from (TarInfo, bytes?) pairs.
    [(TarInfo, Bytes?)] -> Bytes"""
    buffer = io.BytesIO()
    with gzip.GzipFile(filename="", mode="wb", fileobj=buffer, mtime=0) as zipped, \
            tarfile.open(fileobj=zipped, mode="w", format=tarfile.GNU_FORMAT) as archive:
        for info, data in entries:
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            archive.addfile(info, io.BytesIO(data) if data is not None else None)
    return buffer.getvalue()


def _tar_entry(name, kind, data=None, mode=0o644, target=""):
    """One tar entry: a file, a directory or a symbolic link.
    String -> String -> Bytes? -> Int -> String -> (TarInfo, Bytes?)"""
    info = tarfile.TarInfo(name)
    info.mode = mode
    if kind == "dir":
        info.type, info.mode = tarfile.DIRTYPE, 0o755
    elif kind == "link":
        info.type, info.linkname, info.mode = tarfile.SYMTYPE, target, 0o777
    else:
        info.size = len(data)
    return info, data


def _ar(members):
    """An ar archive, the container a .deb is, from (name, bytes) pairs.
    [(String, Bytes)] -> Bytes"""
    out = [b"!<arch>\n"]
    for name, data in members:
        header = f"{name:<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n"
        out += [header.encode(), data, b"\n" if len(data) % 2 else b""]
    return b"".join(out)


def deb(tree, arch, output):
    """A .deb installing the tree in /usr/lib/pyking/, with /usr/bin/pyk a
    link to its pyk. Written directly -- it is an ar archive of two
    tarballs -- so building one needs no dpkg. Recommends Python for the
    web tools and depends on the C library alone. Answers its sha256.
    Path -> String -> Path -> String"""
    prefix = "./usr/lib/pyking"
    data, sums, size = [], [], 0
    for directory in ("./", "./usr/", "./usr/bin/", "./usr/lib/", "./usr/share/",
                      "./usr/share/doc/", "./usr/share/doc/pyking/"):
        data.append(_tar_entry(directory, "dir"))
    data.append(_tar_entry(prefix + "/", "dir"))
    for path in sorted(tree.rglob("*")):
        name = f"{prefix}/{path.relative_to(tree).as_posix()}"
        if path.is_dir():
            data.append(_tar_entry(name + "/", "dir"))
            continue
        content = path.read_bytes()
        size += len(content)
        mode = 0o755 if os.access(path, os.X_OK) else 0o644
        data.append(_tar_entry(name, "file", content, mode))
        sums.append(f"{hashlib.md5(content).hexdigest()}  {name[2:]}")
    copyright_text = (REPO / "LICENSE").read_bytes()
    data.append(_tar_entry("./usr/share/doc/pyking/copyright", "file", copyright_text))
    sums.append(f"{hashlib.md5(copyright_text).hexdigest()}  usr/share/doc/pyking/copyright")
    data.append(_tar_entry("./usr/bin/pyk", "link", target="../lib/pyking/pyk"))
    control = f"""Package: {NAME}
Version: {version()}
Architecture: {DEB_ARCH[arch]}
Maintainer: {MAINTAINER}
Installed-Size: {(size + len(copyright_text) + 1023) // 1024}
Depends: libc6 (>= {'.'.join(map(str, GLIBC_FLOOR))})
Recommends: python3 (>= {PYTHON_MINIMUM})
Section: devel
Priority: optional
Homepage: {HOMEPAGE}
Description: {DESCRIPTION}
 Pyking is a small, statically typed language with Python's syntax. This
 package holds its compiler and interpreter, pyk, which needs nothing but
 the C library, and its standard library. `pyk notebook` and `pyk
 playground` use Python {PYTHON_MINIMUM} or later, which is why it is
 recommended.
"""
    control_tar = _tar_gz([
        _tar_entry("./", "dir"),
        _tar_entry("./control", "file", control.encode()),
        _tar_entry("./md5sums", "file", ("\n".join(sums) + "\n").encode()),
    ])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(_ar([("debian-binary", b"2.0\n"),
                            ("control.tar.gz", control_tar),
                            ("data.tar.gz", _tar_gz(data))]))
    return hashlib.sha256(output.read_bytes()).hexdigest()


# --- the release's files ---------------------------------------------------


def release_assets(v):
    """Every file a release of v holds, by name: the macOS tarball, each
    Linux architecture's tarball and .deb -- under their versioned names
    and under the fixed ones install.sh and a `latest` link ask for --
    install.sh, and SHA256SUMS over the rest. String -> [String]"""
    names = [f"{NAME}-{v}-macos.tar.gz"]
    for arch in ARCHS:
        u, d = UNAME_ARCH[arch], DEB_ARCH[arch]
        names += [f"{NAME}-{v}-linux-{u}.tar.gz", f"{NAME}-linux-{u}.tar.gz",
                  f"{NAME}_{v}_{d}.deb", f"{NAME}_{d}.deb"]
    return names + ["install.sh", "SHA256SUMS"]


def write_checksums(v):
    """Writes build/SHA256SUMS over the release's files that are built,
    in the format `sha256sum -c` reads. String -> Path"""
    lines = []
    for name in release_assets(v)[:-1]:
        path = BUILD / name
        if path.exists():
            lines.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {name}")
    target = BUILD / "SHA256SUMS"
    target.write_text("\n".join(lines) + "\n")
    return target


def read_checksums(path):
    """SHA256SUMS as a map from name to sha256. Path -> {String: String}"""
    pairs = (line.split(None, 1) for line in path.read_text().splitlines() if line.strip())
    return {name.strip().lstrip("*"): sha for sha, name in pairs}


# --- Homebrew ----------------------------------------------------------------


def check_archs(name, archs):
    """Refuses an architecture this module does not know. String ->
    [String] -> ()"""
    unknown = sorted(set(archs) - set(ARCHS))
    if unknown:
        raise Refusal(f"{name}: unknown architecture {', '.join(unknown)}")


def run_steps(title, steps, check):
    """Runs setup steps, each only when it has not been done, then check.
    Answers the problem, or None when all went well.
    String -> [(String, () -> Bool, () -> ())] -> (() -> ()) -> String?"""
    print(f"\n{title}:")
    try:
        for label, done, do in steps:
            if done():
                print(f"  done already: {label}")
                continue
            print(f"  {label}")
            do()
            if not done():
                raise Refusal(f"{label}: the step ran, but did not take effect")
        check()
        return None
    except Refusal as refusal:
        return str(refusal)


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
      `pyk notebook` and `pyk playground` need Python 3.10 or later on
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
        check_archs(self.name, archs)
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
        suffix = "" if set(archs) >= set(ARCHS) else "-" + "-".join(archs)
        top = f"{NAME}-{v}"
        interfaces = [BUILD / f"_build-{arch}" / PLUGIN_BUILT for arch in archs]
        if len({path.read_bytes() for path in interfaces}) > 1:
            raise Refusal("the architectures' pyk_plugin.cmi differ, so a plugin "
                          "compiled against the shipped one would not load into both")
        tree = stage(universal, BUILD / "stage" / top, interface=interfaces[0])
        self.plugins(tree, archs, binaries)
        name = f"{NAME}-{v}-macos{suffix}.tar.gz"
        archive = BUILD / name
        sha = tarball(tree, archive)

        release = BUILD / "homebrew" / "pyking.rb"
        release.parent.mkdir(parents=True, exist_ok=True)
        release.write_text(formula(f"{RELEASES}/v{v}/{name}", sha, archs))
        local = BUILD / "homebrew-local" / "pyking.rb"
        local.parent.mkdir(parents=True, exist_ok=True)
        local.write_text(formula(archive.resolve().as_uri(), sha, archs))
        print(f"homebrew: {shown(archive)} ({', '.join(archs)}, "
              f"{archive.stat().st_size / 1048576:.1f} MB, sha256 {sha[:12]}…)")
        print(f"homebrew: {shown(release)} (for the release v{v})")
        print(f"homebrew: {shown(local)} (for `make packaging-install`)")
        if suffix:
            print(f"homebrew: NOTE this package holds {', '.join(archs)} only; "
                  "do not publish it as the release.")

    def plugins(self, tree, archs, binaries):
        """Builds the tree's library plugins universal: each architecture's
        compiled by its own toolchain, in a tree of its own staged around
        that architecture's binary, and the slices joined with lipo.
        Path -> [String] -> [Path] -> ()"""
        slices = {}
        for arch, binary in zip(archs, binaries):
            own = stage(binary, BUILD / "stage-plugins" / arch, vendor=False,
                        interface=BUILD / f"_build-{arch}" / PLUGIN_BUILT)
            build_plugins(own, self.toolchain(arch), env=self.environment())
            slices[arch] = own
        for plugin in plugin_sources(tree):
            parts = [slices[arch] / plugin.relative_to(tree) for arch in archs]
            if len(parts) > 1:
                run(["lipo", "-create", "-output", plugin] + parts)
            else:
                shutil.copy2(parts[0], plugin)
            run(["codesign", "--force", "--sign", "-", plugin])
            if sorted(macho_archs(plugin)) != archs:
                raise Refusal(f"{plugin} holds {macho_archs(plugin)}, not {archs}")

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
        as `build` would. Answers one (label, problem?) row per
        architecture. () -> [(String, String?)]"""
        if sys.platform != "darwin" or platform.machine() != "arm64":
            return [("homebrew", "its toolchains are set up on an Apple Silicon "
                                 "Mac, and this is not one (FORMATS=linux sets up "
                                 "only the Linux one)")]
        return [(f"homebrew {arch}", run_steps(f"homebrew {arch}", steps,
                                               lambda arch=arch: self.preflight(arch)))
                for arch, steps in (("arm64", self._arm64_steps()),
                                    ("x86_64", self._x86_64_steps()))]

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

    def uninstall_local(self):
        """Removes what install_local installed, and the tap. () -> ()"""
        subprocess.run(["brew", "uninstall", f"{LOCAL_TAP}/pyking"])
        subprocess.run(["brew", "untap", LOCAL_TAP])


# --- Linux -------------------------------------------------------------------


class Linux:
    """The Linux format: `pyk` linked against glibc, in a Debian container
    per architecture whose glibc is old enough for one binary to run on
    every current distribution and on WSL. Dynamically linked because the
    interpreter loads library plugins, which a static binary cannot; the
    glibc it may ask for is GLIBC_FLOOR at most. Ships a tarball per
    architecture (what install.sh installs) and a .deb."""

    name = "linux"
    PLATFORM = {"arm64": "linux/arm64", "x86_64": "linux/amd64"}
    OCAML_ARCH = {"arm64": "arm64", "x86_64": "amd64"}
    # The images a built tree is run in: a current distribution, and the
    # oldest the glibc floor promises.
    RUN_IMAGES = ("debian:stable-slim", "debian:10-slim")

    def refusal(self):
        """Why this machine cannot build the format, or None.
        () -> String?"""
        if not shutil.which("docker"):
            return ("Docker is needed to build the Linux packages (Docker Desktop, "
                    "OrbStack or Colima on a Mac)")
        if subprocess.run(["docker", "info"], capture_output=True).returncode:
            return "Docker is installed but not running; start it and try again"
        return None

    def image(self, arch):
        """The build image's tag: the architecture and a hash of the
        Dockerfile and the OCaml version, so either changing makes a new
        one. String -> String"""
        digest = hashlib.sha256(DOCKERFILE.read_bytes() + OCAML_VERSION.encode())
        return f"pyking-linux-build:{arch}-{digest.hexdigest()[:12]}"

    def has_image(self, arch):
        """Whether the build image exists. String -> Bool"""
        return subprocess.run(["docker", "image", "inspect", self.image(arch)],
                              capture_output=True).returncode == 0

    def emulates(self, arch):
        """Whether Docker runs arch's containers here, natively or emulated.
        String -> Bool"""
        result = subprocess.run(["docker", "run", "--rm", "--platform", self.PLATFORM[arch],
                                 "alpine:3.22", "uname", "-m"], capture_output=True, text=True)
        return result.returncode == 0 and result.stdout.strip() == UNAME_ARCH[arch]

    def emulation_help(self, arch):
        """How to make Docker run arch's containers. String -> String"""
        return (f"Docker cannot run {arch} containers here. Docker Desktop and "
                "OrbStack emulate the other architecture out of the box (check "
                "that it is enabled in their settings); on Linux, register QEMU "
                "once with\n    docker run --privileged --rm tonistiigi/binfmt "
                f"--install {self.OCAML_ARCH[arch]}")

    def preflight(self, arch):
        """Refuses before anything is built when arch's image is missing or
        does not build for arch. String -> ()"""
        if not self.emulates(arch):
            raise Refusal(self.emulation_help(arch))
        if not self.has_image(arch):
            raise Refusal(f"no {arch} build image ({self.image(arch)}); "
                          "`make packaging-setup` builds it")
        found = subprocess.run(["docker", "run", "--rm", "--platform", self.PLATFORM[arch],
                                self.image(arch), "ocamlopt", "-config-var", "architecture"],
                               capture_output=True, text=True).stdout.strip()
        if found != self.OCAML_ARCH[arch]:
            raise Refusal(f"the {arch} build image builds for {found or 'nothing'}")

    def setup(self):
        """Builds the image for each architecture, when it is not there.
        Answers one (label, problem?) row per architecture.
        () -> [(String, String?)]"""
        reason = self.refusal()
        if reason:
            return [("linux", reason)]
        rows = []
        for arch in ARCHS:
            native = UNAME_ARCH[arch] == platform.machine() or arch == platform.machine()
            slow = "several minutes" if native else "30-60 minutes emulated"

            def emulation(arch=arch):
                raise Refusal(self.emulation_help(arch))

            steps = [
                (f"run {arch} containers", lambda arch=arch: self.emulates(arch), emulation),
                (f"build the image {self.image(arch)} (compiles OCaml {OCAML_VERSION}, "
                 f"which takes {slow})",
                 lambda arch=arch: self.has_image(arch),
                 lambda arch=arch: run(["docker", "build", "--platform", self.PLATFORM[arch],
                                        "--build-arg", f"OCAML_VERSION={OCAML_VERSION}",
                                        "-t", self.image(arch), DOCKERFILE.parent])),
            ]
            rows.append((f"linux {arch}", run_steps(f"linux {arch}", steps,
                                                    lambda arch=arch: self.preflight(arch))))
        return rows

    def user(self):
        """Runs a container as the caller, so what it writes into a mounted
        directory is the caller's. () -> [String]"""
        return [] if sys.platform == "win32" else ["--user", f"{os.getuid()}:{os.getgid()}"]

    def binary(self, arch):
        """Builds pyk for arch in its image, into a dune build directory of
        its own in the repository, which the container sees mounted, and
        refuses one asking for a glibc newer than GLIBC_FLOOR; answers its
        path. String -> Path"""
        directory = BUILD / f"_build-linux-{arch}"
        BUILD.mkdir(parents=True, exist_ok=True)
        inside = "/src/" + directory.relative_to(REPO).as_posix()
        run(["docker", "run", "--rm", "--platform", self.PLATFORM[arch], *self.user(),
             "-v", f"{REPO}:/src", "-w", "/src", self.image(arch),
             "dune", "build", "--root", "/src", "--build-dir", inside, "src/pyk.exe"])
        path = directory / "default" / "src" / "pyk.exe"
        info = elf_info(path)
        if info != (arch, False):
            raise Refusal(f"{path} is {info}, not a dynamically linked {arch} binary")
        needed = glibc_needed(path)
        if needed > GLIBC_FLOOR:
            raise Refusal(f"{path} asks for glibc {'.'.join(map(str, needed))}, and "
                          f"the package promises {'.'.join(map(str, GLIBC_FLOOR))}")
        return path

    def plugins(self, arch, tree):
        """Builds the staged tree's library plugins in arch's image, with
        the tree's own pyk and the image's OCaml -- the one that built it.
        The tree is mounted at its own path, so the paths agree inside and
        out. String -> Path -> ()"""
        build_plugins(tree, ["docker", "run", "--rm", "--platform", self.PLATFORM[arch],
                             *self.user(), "-v", f"{tree}:{tree}", self.image(arch)])

    def check_runs(self, arch, tree):
        """Runs the staged tree in plain containers of other distributions
        -- the oldest the glibc floor promises among them: its version, a
        program, and one importing libraries, which loads their plugins.
        String -> Path -> ()"""
        with tempfile.TemporaryDirectory(prefix="pyk-linux-") as directory:
            (Path(directory) / "hello.pyk").write_text('print("hello", 1 + 2)\n')
            (Path(directory) / "library.pyk").write_text(
                'import io\nimport time\nio.write_line("io " ++ str(time.instant() > 0))\n')
            for image in self.RUN_IMAGES:
                result = subprocess.run(
                    ["docker", "run", "--rm", "--platform", self.PLATFORM[arch],
                     "-v", f"{tree}:/t:ro", "-v", f"{directory}:/p:ro", image, "sh", "-c",
                     "/t/pyk --version && /t/pyk /p/hello.pyk && /t/pyk /p/library.pyk"],
                    capture_output=True, text=True)
                if result.stdout.splitlines() != [f"pyk {version()}", "hello 3", "io true"]:
                    raise Refusal(f"the {arch} package does not run in {image}: "
                                  + (result.stdout + result.stderr).strip()[-300:])

    def build(self, archs):
        """Builds, for each architecture, the tarball (under both names)
        and the .deb (under both names), and copies install.sh. [String] -> ()"""
        check_archs(self.name, archs)
        for arch in archs:
            self.preflight(arch)
        v = version()
        for arch in archs:
            binary = self.binary(arch)
            u, d = UNAME_ARCH[arch], DEB_ARCH[arch]
            tree = stage(binary, BUILD / f"stage-linux-{arch}" / f"{NAME}-{v}",
                         interface=BUILD / f"_build-linux-{arch}" / PLUGIN_BUILT)
            self.plugins(arch, tree)
            self.check_runs(arch, tree)
            archive = BUILD / f"{NAME}-{v}-linux-{u}.tar.gz"
            sha = tarball(tree, archive)
            shutil.copy2(archive, BUILD / f"{NAME}-linux-{u}.tar.gz")
            package = BUILD / f"{NAME}_{v}_{d}.deb"
            deb_sha = deb(tree, arch, package)
            shutil.copy2(package, BUILD / f"{NAME}_{d}.deb")
            print(f"linux: {shown(archive)} ({archive.stat().st_size / 1048576:.1f}"
                  f" MB, sha256 {sha[:12]}…)")
            print(f"linux: {shown(package)} ({package.stat().st_size / 1048576:.1f}"
                  f" MB, sha256 {deb_sha[:12]}…)")
        shutil.copy2(INSTALL_SH, BUILD / "install.sh")
        (BUILD / "install.sh").chmod(0o755)
        if set(archs) != set(ARCHS):
            print(f"linux: NOTE only {', '.join(archs)} was built; "
                  "`make release` needs every architecture.")

    def install_local(self):
        """Installs the local build into ~/.local with install.sh, as the
        one-liner would, reading the files from build/. () -> ()"""
        u = UNAME_ARCH.get(canonical_arch(platform.machine()), platform.machine())
        if not (BUILD / f"{NAME}-linux-{u}.tar.gz").exists():
            raise Refusal(f"nothing built for {u}; run `make packaging` first")
        write_checksums(version())
        run(["sh", INSTALL_SH], env=dict(os.environ,
                                         PYKING_DOWNLOAD_BASE=BUILD.resolve().as_uri()))

    def uninstall_local(self):
        """Removes what install_local installed. () -> ()"""
        run(["sh", INSTALL_SH, "--uninstall"])


FORMATS = {"homebrew": Homebrew(), "linux": Linux()}


def host_format():
    """The format whose packages install on this machine. () -> Format"""
    return FORMATS["homebrew" if sys.platform == "darwin" else "linux"]


# --- publishing --------------------------------------------------------------


def release(assume_yes):
    """Publishes the build: one release v<VERSION> of RELEASES_REPO holding
    every platform's files, each downloaded back and checked against
    SHA256SUMS, then the formula committed and pushed to TAP_REPO, then --
    asked separately -- the commit it was built from tagged in CODE_REPO
    as release-<VERSION>. Checks everything it can first, asks before
    changing anything unless assume_yes, and never replaces a published
    release. Answers whether it succeeded. Bool -> Bool"""
    v = version()
    tag = f"v{v}"
    names = release_assets(v)

    # 1. The build: every file for this version, agreeing with SHA256SUMS
    #    and with the formula.
    missing = [name for name in names if not (BUILD / name).exists()]
    if missing:
        raise Refusal(f"the release of {v} is not fully built; missing from "
                      f"{shown(BUILD)}/: {', '.join(missing)}.\n"
                      "  `make packaging` builds every platform (on an Apple "
                      "Silicon Mac with Docker)")
    sums = read_checksums(BUILD / "SHA256SUMS")
    for name in names[:-1]:
        if sums.get(name) != hashlib.sha256((BUILD / name).read_bytes()).hexdigest():
            raise Refusal(f"SHA256SUMS does not match {name}; run `make packaging` again")
    mac = names[0]
    rb = BUILD / "homebrew" / "pyking.rb"
    text = rb.read_text() if rb.exists() else ""
    if f'url "{RELEASES}/{tag}/{mac}"' not in text or f'sha256 "{sums[mac]}"' not in text:
        raise Refusal(f"{shown(rb)} does not describe {mac}; "
                      "run `make packaging` again")

    # 2. The tools and the two repositories.
    if not shutil.which("gh") or not shutil.which("git"):
        raise Refusal("git and gh (the GitHub CLI) are needed: `brew install gh`, "
                      "then `gh auth login`")
    if subprocess.run(["gh", "auth", "status"], capture_output=True).returncode:
        raise Refusal("gh is not logged in; run `gh auth login`")
    # Checked here, not left to the commit: a commit that fails comes after
    # the release exists, which would leave it without a formula. Asked from
    # outside any repository, as the fresh clone will be: a name set only in
    # this repository's own config is not used there.
    for key in ("user.name", "user.email"):
        if not subprocess.run(["git", "config", key], capture_output=True, text=True,
                              cwd=tempfile.gettempdir()).stdout.strip():
            raise Refusal(f"git has no {key}, which the tap commit needs: "
                          f'git config --global {key} "..."')
    state = {}
    for repo, description in ((RELEASES_REPO, "Pyking releases for macOS, Linux and WSL"),
                              (TAP_REPO, "Homebrew tap for Pyking")):
        viewed = subprocess.run(["gh", "repo", "view", repo, "--json", "visibility,isEmpty"],
                                capture_output=True, text=True)
        if viewed.returncode:
            raise Refusal(f"the repository {repo} does not exist or is not reachable; "
                          f'create it with\n    gh repo create {repo} --public '
                          f'--description "{description}"')
        state[repo] = json.loads(viewed.stdout)
        if state[repo].get("visibility") != "PUBLIC":
            raise Refusal(f"{repo} is {state[repo].get('visibility', '?').lower()}; it "
                          "must be public, since it is downloaded without credentials:\n"
                          f"    gh repo edit {repo} --visibility public "
                          "--accept-visibility-change-consequences")
    if subprocess.run(["gh", "release", "view", tag, "--repo", RELEASES_REPO],
                      capture_output=True).returncode == 0:
        raise Refusal(f"{RELEASES_REPO} already has a release {tag}. A published "
                      "release is never replaced, since everyone who installed it "
                      "holds its checksums; bump VERSION and build again")
    commit, code_tag, tagged = code_tag_preflight(v)

    # 3. Say what will happen, and ask.
    size = sum((BUILD / name).stat().st_size for name in names) / 1048576
    print(f"\nAbout to publish Pyking {v}:")
    print(f"  1. create the release {tag} of {RELEASES_REPO}, marked latest, with "
          f"{len(names)} files ({size:.1f} MB):")
    for name in names:
        print(f"       {name}")
    print(f"  2. commit Formula/pyking.rb for {v} to {TAP_REPO} and push it")
    print(f"  3. then ask whether to tag {commit[:12]} in {CODE_REPO} as {code_tag}"
          + (" (it already is)" if tagged else ""))
    if not assume_yes and not confirm("Publish? [y/N] "):
        print("release: nothing was published.")
        return False

    with tempfile.TemporaryDirectory(prefix="pyk-release-") as directory:
        work = Path(directory)
        # 4. The release. A repository with no commit cannot hold a tag, so
        #    an empty one is given a README first.
        if state[RELEASES_REPO].get("isEmpty"):
            first_commit(work / "releases", RELEASES_REPO,
                         {"README.md": releases_readme()}, "Describe the releases")
        notes = (f"Pyking {v}: the compiler and interpreter, with no dependencies.\n\n"
                 f"**macOS** 11 or later, Apple Silicon and Intel:\n\n    {BREW_INSTALL}\n\n"
                 f"**Linux and WSL**, x86_64 and aarch64, any distribution:\n\n"
                 f"    {LINUX_INSTALL}\n\n"
                 f"Or, on Debian, Ubuntu and WSL Ubuntu, the `.deb` for your "
                 f"architecture: `sudo apt install ./pyking_amd64.deb`.\n\n"
                 f"Checksums are in `SHA256SUMS`.\n")
        run(["gh", "release", "create", tag, *[BUILD / name for name in names],
             "--repo", RELEASES_REPO, "--title", f"Pyking {v}", "--notes", notes,
             "--latest"])
        # Every file, fetched back from where users fetch it -- and install.sh
        # once more through `latest`, which is what the one-liner reads.
        checks = [(f"{RELEASES}/{tag}/{name}", name) for name in names[:-1]]
        checks.append((f"{HOMEPAGE}/releases/latest/download/install.sh", "install.sh"))
        for url, name in checks:
            fetched = work / "fetched"
            print(f"  $ download {url}")
            try:
                urllib.request.urlretrieve(url, fetched)
            except OSError as e:
                raise Refusal(f"the release was created, but {url} cannot be "
                              f"downloaded ({e}); the tap was not changed")
            if hashlib.sha256(fetched.read_bytes()).hexdigest() != sums[name]:
                raise Refusal(f"the release was created, but {url} does not match "
                              "SHA256SUMS; the tap was not changed")

        # 5. The formula, in the tap.
        tap = work / "tap"
        run(["gh", "repo", "clone", TAP_REPO, tap])
        if state[TAP_REPO].get("isEmpty"):
            run(["git", "-C", tap, "symbolic-ref", "HEAD", "refs/heads/main"])
            (tap / "README.md").write_text(tap_readme())
            run(["git", "-C", tap, "add", "README.md"])
        (tap / "Formula").mkdir(exist_ok=True)
        shutil.copy2(rb, tap / "Formula" / "pyking.rb")
        run(["git", "-C", tap, "add", "Formula/pyking.rb"])
        if subprocess.run(["git", "-C", tap, "diff", "--cached", "--quiet"]).returncode:
            run(["git", "-C", tap, "commit", "-m", f"pyking {v}"])
            run(["git", "-C", tap, "push", "origin", "HEAD"])
        else:
            print(f"  ({TAP_REPO} already has this formula)")
    # 6. The tag in the code repository, asked for on its own: the release
    #    is out whatever the answer.
    if tagged:
        outcome = f"{CODE_REPO} already tags {commit[:12]} as {code_tag}"
    elif assume_yes or confirm(f"\nTag {commit[:12]} in {CODE_REPO} as {code_tag}? [y/N] "):
        try:
            tag_code(commit, code_tag, v)
        except Refusal as refusal:
            raise Refusal(f"Pyking {v} is published -- the release and the formula -- "
                          f"but tagging {commit[:12]} as {code_tag} failed: {refusal}. "
                          f"Tag it by hand: git tag -a {code_tag} -m 'Pyking {v}' "
                          f"{commit[:12]} && git push origin {code_tag}")
        outcome = f"tagged {commit[:12]} in {CODE_REPO} as {code_tag}"
    else:
        outcome = (f"not tagged; to tag it later: git tag -a {code_tag} -m "
                   f"'Pyking {v}' {commit[:12]} && git push origin {code_tag}")
    print(f"\nrelease: SUCCEEDED -- Pyking {v} is published; {outcome}.\n"
          f"  macOS:         {BREW_INSTALL}\n"
          f"  Linux and WSL: {LINUX_INSTALL}")
    return True


def confirm(question):
    """Asks a yes/no question; anything but yes, or no terminal, is no.
    String -> Bool"""
    try:
        answer = input(question)
    except EOFError:
        answer = ""
    return answer.strip().lower() in ("y", "yes")


def git(*args):
    """A git command in this repository, answering its output, or None
    when it fails. String... -> String?"""
    result = subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def code_tag_preflight(v):
    """Checks, before anything is published, that the commit the release
    is built from can be tagged: no uncommitted change to a tracked file,
    HEAD already on GitHub in CODE_REPO, origin being CODE_REPO, and the
    tag either absent or already on HEAD. Answers (commit, tag, whether it
    is already tagged). String -> (String, String, Bool)"""
    code_tag = f"release-{v}"
    changed = git("status", "--porcelain", "--untracked-files=no")
    if changed is None:
        raise Refusal(f"{REPO} is not a git repository, so the release commit "
                      "cannot be tagged")
    if changed:
        # Each line is a status code, then the path; git() strips the
        # output, which can take the first line's leading blank with it.
        files = [line.split(None, 1)[1] for line in changed.splitlines()]
        raise Refusal("the working tree has uncommitted changes, so the release "
                      f"would not be the commit {code_tag} names: "
                      + ", ".join(files[:6]) + (" ..." if len(files) > 6 else "")
                      + "\n  Commit or discard them, build again, and release.")
    origin = git("remote", "get-url", "origin") or ""
    if CODE_REPO not in origin.removesuffix(".git"):
        raise Refusal(f"origin is {origin or 'not set'}, not {CODE_REPO}, so the tag "
                      "would be pushed somewhere else")
    commit = git("rev-parse", "HEAD")
    if subprocess.run(["gh", "api", f"repos/{CODE_REPO}/commits/{commit}", "--silent"],
                      capture_output=True).returncode:
        raise Refusal(f"HEAD ({commit[:12]}) is not on GitHub in {CODE_REPO}; push it "
                      "first (`git push`), so the tag names a commit others can see")
    remote = subprocess.run(["gh", "api", f"repos/{CODE_REPO}/git/ref/tags/{code_tag}",
                             "--jq", ".object.sha"], capture_output=True, text=True)
    if remote.returncode == 0:
        # An annotated tag names its tag object; peel it to the commit.
        peeled = subprocess.run(["gh", "api", f"repos/{CODE_REPO}/git/tags/"
                                 f"{remote.stdout.strip()}", "--jq", ".object.sha"],
                                capture_output=True, text=True)
        target = peeled.stdout.strip() if peeled.returncode == 0 else remote.stdout.strip()
        if target != commit:
            raise Refusal(f"{CODE_REPO} already has the tag {code_tag}, on "
                          f"{target[:12]} rather than HEAD ({commit[:12]}); bump VERSION")
        return commit, code_tag, True
    return commit, code_tag, False


def tag_code(commit, code_tag, v):
    """Tags commit as code_tag, annotated, and pushes the tag to origin.
    A local tag already on that commit is reused. String -> String ->
    String -> ()"""
    local = git("rev-parse", "--verify", "--quiet", f"refs/tags/{code_tag}^{{commit}}")
    if local is None:
        run(["git", "-C", REPO, "tag", "-a", code_tag, "-m", f"Pyking {v}", commit])
    elif local != commit:
        raise Refusal(f"the release is published, but a local tag {code_tag} already "
                      f"names {local[:12]}, not {commit[:12]}; delete it "
                      f"(git tag -d {code_tag}) and tag by hand")
    run(["git", "-C", REPO, "push", "origin", f"refs/tags/{code_tag}"])


def first_commit(directory, repo, files, message):
    """Gives an empty repository its first commit on main.
    Path -> String -> {String: String} -> String -> ()"""
    run(["gh", "repo", "clone", repo, directory])
    run(["git", "-C", directory, "symbolic-ref", "HEAD", "refs/heads/main"])
    for name, text in files.items():
        (directory / name).write_text(text)
        run(["git", "-C", directory, "add", name])
    run(["git", "-C", directory, "commit", "-m", message])
    run(["git", "-C", directory, "push", "origin", "HEAD"])


def releases_readme():
    """The README of RELEASES_REPO. () -> String"""
    return (f"# Pyking releases\n\nReleases of Pyking, a compiler and interpreter with "
            "no dependencies.\n\n## macOS\n\nmacOS 11 or later, Apple Silicon and "
            f"Intel, with [Homebrew](https://brew.sh):\n\n```sh\n{BREW_INSTALL}\n```\n\n"
            "## Linux and WSL\n\nAny distribution, x86_64 or aarch64. Installs into "
            f"`~/.local`, with no sudo:\n\n```sh\n{LINUX_INSTALL}\n```\n\n"
            "`sh -s -- --system` installs for every user instead, `--version X` a "
            "given release, and `--uninstall` removes it. On Debian, Ubuntu and WSL "
            "Ubuntu, the `.deb` of a release works too:\n\n```sh\n"
            f"curl -fLO {HOMEPAGE}/releases/latest/download/pyking_amd64.deb\n"
            "sudo apt install ./pyking_amd64.deb\n```\n\n"
            f"`pyk notebook` and `pyk playground` also need Python {PYTHON_MINIMUM} or "
            "later.\n")


def tap_readme():
    """The README of TAP_REPO. () -> String"""
    return (f"# Pyking's Homebrew tap\n\n```sh\n{BREW_INSTALL}\n```\n\nThe formulas "
            f"install the releases in [{RELEASES_REPO}]({HOMEPAGE}).\n")


def main(argv=None):
    """The command-line entry point. [String]? -> Int"""
    parser = argparse.ArgumentParser(prog="packaging.py",
                                     description="Build Pyking's packages.")
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="build the packages")
    build.add_argument("--formats", default="",
                       help=f"comma-separated formats (default: {','.join(FORMATS)})")
    build.add_argument("--archs", default="",
                       help="comma-separated architectures (default: all)")
    setup = commands.add_parser("setup", help="make the build toolchains, once")
    setup.add_argument("--formats", default="")
    published = commands.add_parser("release", help="publish the build")
    published.add_argument("--yes", action="store_true", help="do not ask first")
    commands.add_parser("install-local", help="install the local build here")
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

    def chosen(spelled):
        names = [f for f in spelled.split(",") if f] or list(FORMATS)
        unknown = [f for f in names if f not in FORMATS]
        if unknown:
            raise Refusal(f"unknown format {', '.join(unknown)}; there are "
                          f"{', '.join(FORMATS)}")
        return [FORMATS[f] for f in names]

    try:
        if args.command == "build":
            formats = chosen(args.formats)
            # Every format is asked first, so a machine that cannot build one
            # says so before the others spend their time.
            refused = [(fmt.name, fmt.refusal()) for fmt in formats]
            refused = [(name, reason) for name, reason in refused if reason]
            if refused:
                others = [fmt.name for fmt in formats if fmt.name not in dict(refused)]
                raise Refusal("\n  ".join(f"{name}: {reason}" for name, reason in refused)
                              + (f"\n  FORMATS={','.join(others)} builds the rest."
                                 if others else ""))
            archs = sorted({canonical_arch(a) for a in args.archs.split(",") if a}) \
                or list(ARCHS)
            for fmt in formats:
                fmt.build(archs)
            print(f"checksums: {shown(write_checksums(version()))}")
        elif args.command == "setup":
            rows = [row for fmt in chosen(args.formats) for row in fmt.setup()]
            print()
            for label, problem in rows:
                print(f"  {label:<16} {'ready' if problem is None else 'FAILED: ' + problem}")
            ok = all(problem is None for _, problem in rows)
            print()
            print("packaging setup: " + ("SUCCEEDED -- everything `make packaging` "
                                         "builds with is ready." if ok else
                                         "FAILED -- see above; running it again "
                                         "resumes where it stopped."))
            if not ok:
                return 1
        elif args.command == "release":
            try:
                if not release(args.yes):
                    return 1
            except Refusal as refusal:
                print(f"packaging: {refusal}", file=sys.stderr)
                print("release: FAILED -- see above.")
                return 1
        elif args.command == "install-local":
            host_format().install_local()
        elif args.command == "uninstall-local":
            host_format().uninstall_local()
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
