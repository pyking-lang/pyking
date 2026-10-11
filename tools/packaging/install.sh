#!/bin/sh
# Installs Pyking on Linux and WSL, from the releases on GitHub.
#
#   curl -fsSL https://github.com/pyking-lang/pyking-releases/releases/latest/download/install.sh | sh
#
# installs the latest release for your own user, in ~/.local, with no
# sudo. After `| sh -s --` it takes:
#
#   --system        for every user, in /usr/local (asks for sudo)
#   --version X     release X instead of the latest
#   --uninstall     remove it again (with --system, the system-wide one)
#
# It is POSIX sh, needs curl or wget, tar, and sha256sum or shasum, and
# refuses a download whose checksum is not the one the release lists.
# Published unchanged with every release; the source is
# tools/packaging/install.sh in the pyking repository.

set -eu

RELEASES="https://github.com/pyking-lang/pyking-releases/releases"
BREW="brew install pyking-lang/tap/pyking"

say() { printf '%s\n' "$*"; }
fail() { printf 'pyking install: %s\n' "$*" >&2; exit 1; }

usage() {
    say "usage: install.sh [--system] [--version X] [--uninstall]"
    say ""
    say "  --system      install for every user, in /usr/local (sudo)"
    say "  --version X   install release X instead of the latest"
    say "  --uninstall   remove Pyking again"
}

system=0
version=""
uninstall=0
while [ $# -gt 0 ]; do
    case "$1" in
        --system) system=1 ;;
        --version)
            [ $# -ge 2 ] || fail "--version needs a version, e.g. --version 0.2.0"
            version="${2#v}"
            shift ;;
        --version=*) version="${1#--version=}"; version="${version#v}" ;;
        --uninstall) uninstall=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
    shift
done

case "$(uname -s)" in
    Linux) ;;
    Darwin) fail "this installer is for Linux and WSL. On a Mac, use Homebrew: $BREW" ;;
    *) fail "this installer is for Linux and WSL, and this is $(uname -s)" ;;
esac
case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) fail "there is no Pyking build for $(uname -m); there are builds for x86_64 and aarch64" ;;
esac

if [ "$system" = 1 ]; then
    data=/usr/local/lib/pyking
    bin=/usr/local/bin
    if [ "$(id -u)" = 0 ]; then
        sudo=""
    elif command -v sudo >/dev/null 2>&1; then
        sudo=sudo
    else
        fail "--system needs root, or sudo"
    fi
else
    [ -n "${HOME:-}" ] || fail "HOME is not set"
    data="${XDG_DATA_HOME:-$HOME/.local/share}/pyking"
    bin="$HOME/.local/bin"
    sudo=""
fi

if [ "$uninstall" = 1 ]; then
    if [ ! -e "$data" ] && [ ! -L "$bin/pyk" ]; then
        fail "Pyking is not installed in $data"
    fi
    $sudo rm -f "$bin/pyk"
    $sudo rm -rf "$data"
    say "Removed Pyking: $data and $bin/pyk."
    exit 0
fi

# Where the files come from: a given release, the latest one, or -- for
# testing a build before it is published -- a directory named by
# PYKING_DOWNLOAD_BASE (a file:// URL works with curl).
if [ -n "${PYKING_DOWNLOAD_BASE:-}" ]; then
    base="$PYKING_DOWNLOAD_BASE"
elif [ -n "$version" ]; then
    base="$RELEASES/download/v$version"
else
    base="$RELEASES/latest/download"
fi

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        fail "curl or wget is needed to download Pyking"
    fi
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        fail "sha256sum or shasum is needed to check the download"
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM

asset="pyking-linux-$arch.tar.gz"
say "Downloading $asset${version:+ (version $version)}..."
fetch "$base/$asset" "$tmp/$asset" || fail "could not download $base/$asset"
fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" || fail "could not download $base/SHA256SUMS"
expected=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
[ -n "$expected" ] || fail "SHA256SUMS does not list $asset"
[ "$(sha256 "$tmp/$asset")" = "$expected" ] ||
    fail "the download does not match its checksum; nothing was installed"

mkdir "$tmp/unpacked"
tar -xzf "$tmp/$asset" -C "$tmp/unpacked"
top=$(ls "$tmp/unpacked")
[ -x "$tmp/unpacked/$top/pyk" ] || fail "the download does not hold pyk"

# Copied in beside the old installation, then swapped for it, so a failure
# half-way leaves the old one working.
$sudo mkdir -p "$(dirname "$data")" "$bin"
$sudo rm -rf "$data.new"
$sudo cp -R "$tmp/unpacked/$top" "$data.new"
$sudo rm -rf "$data"
$sudo mv "$data.new" "$data"
$sudo ln -sf "$data/pyk" "$bin/pyk"

installed=$("$bin/pyk" --version) || fail "pyk was installed in $data but does not run"
say "Installed $installed in $data, with $bin/pyk."

case ":$PATH:" in
    *":$bin:"*) ;;
    *)
        say ""
        say "$bin is not on your PATH. Add it, e.g. in ~/.profile or ~/.bashrc:"
        say "    export PATH=\"$bin:\$PATH\"" ;;
esac

