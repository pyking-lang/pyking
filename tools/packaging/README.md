# Packaging

Builds the packages Pyking is installed from on another machine. One
format so far: **Homebrew, for macOS**, with a universal `pyk` that runs
natively on Apple Silicon and on Intel Macs.

```sh
make packaging            # at the repository root: every package, into build/
```

## Installing with Homebrew

```sh
brew install pyking-lang/macos/pyking
```

or, equivalently, tap once and then use the short name:

```sh
brew tap pyking-lang/macos
brew install pyking
```

After that `pyk` is on the `PATH`:

```sh
pyk --version
pyk hello.pyk
pyk notebook $(brew --prefix pyking)/libexec/PYKING-TUTORIAL.md
```

`brew upgrade pyking` updates it and `brew uninstall pyking` removes it.

**What it needs.** Nothing to install, and no other Homebrew formula: the
package holds a compiled `pyk` that links only macOS's own libraries, and
Homebrew is only what puts it on the `PATH`. It runs on macOS 11 (Big Sur)
or later. Two things need more, and only when used:

- `pyk notebook` and `pyk playground` need **Python 3.14 or later** on the
  `PATH` (or named by `$PYTHON`). They say so if it is missing.
- Compiling for a target *and running the result* needs that target's own
  tools: `node` for JavaScript, `cc` for C, a JDK for Java, `ocamlopt` for
  OCaml, `python3` for Python. Compiling alone needs none of them, and
  `pyk file.pyk` (the interpreter) needs nothing.

## What a package holds

Every format ships the same tree, the repository's own layout minus
everything that is not needed to use the compiler, since `pyk` finds what
ships beside it by looking in its own directory (`src/install.ml`):

```
pyk                    the compiler (universal: arm64 + x86_64)
LICENSE
PYKING-TUTORIAL.md
lib/                   the standard library
build/pyking.js        the compiler as JavaScript: the iweb24 target and the pages
tools/webrun/          the web tools' server, scripts, and Ace and KaTeX
tools/notebook/
tools/playground/      without examples: the playground starts with one program
```

The Homebrew formula puts the tree in the keg's `libexec/` and links
`bin/pyk` to it. `pyk` resolves every symbolic link to its own path before
looking beside itself, which is what makes that link work.

## Building a release

On an Apple Silicon Mac, with the one-time setup below done
(`make packaging-setup`):

1. Set the version in `VERSION` (e.g. `0.2.0`) and commit it. It is
   compiled into the binary (`pyk --version`) and names the tarball, the
   release and the formula.
2. `make packaging`. It builds `pyk` twice -- arm64 natively, x86_64 under
   Rosetta -- joins them with `lipo`, signs the result ad hoc, and refuses
   it if it links anything outside `/usr/lib` and `/System`. It writes:

   ```
   tools/packaging/build/
     pyking-0.2.0-macos.tar.gz     the package
     homebrew/pyking.rb            the formula, naming the GitHub release
     homebrew-local/pyking.rb      the same formula, naming the file above
   ```
3. `make packaging-install` installs that build with Homebrew and runs the
   formula's own test, before anything is published. See "Trying a build
   locally" below.
4. `make release-macos` publishes it. Nothing about the code repository
   is published: `pyking-lang/pyking` can stay private.

   - It checks everything first: that the build is the universal package
     for `VERSION` and its formula matches it, that `gh` is logged in,
     that git has a name and an email for the commit, that the
     repository below exists and is public, and that release
     `v0.2.0` does not exist yet.
   - It says what it is about to do and asks. `make release-macos YES=1`
     does not ask.
   - It creates the release `v0.2.0` of **`pyking-lang/homebrew-macos`**,
     holding the tarball, then downloads it back from the formula's URL
     and checks its checksum.
   - It clones the same repository, commits the formula as
     `Formula/pyking.rb` ("pyking 0.2.0") and pushes it. `brew upgrade`
     picks it up from there.
   - It ends with one line: **SUCCEEDED**, with the install command, or
     **FAILED**, with the reason.

   A published release is never replaced: everyone who installed it
   holds its checksum. To change one, bump `VERSION` and release again.

The public repository is made once, and holds no code:

```sh
gh repo create pyking-lang/homebrew-macos --public --description "Pyking for macOS: releases and Homebrew tap"
```

It is both things a user downloads from: the releases, since Homebrew
downloads them without credentials and so cannot reach a private
repository, and the tap, `Formula/pyking.rb`. Its name is what makes
`brew install pyking-lang/macos/pyking` work: Homebrew looks for the tap
`<owner>/<tap>` in the repository `<owner>/homebrew-<tap>`. The first
release gives it a README if it is empty. `make release-macos` needs `gh`
(`brew install gh`, then `gh auth login`).

The tarball is reproducible -- sorted, owned by root, dated 0 -- so
building the same tree twice gives the same checksum.

## Trying a build locally

Current Homebrew installs a formula only from a tap, so the local build is
installed through a tap made for it:

```sh
make packaging-install      # tap pyking-lang/local, install, brew test
make packaging-uninstall    # uninstall, and remove the tap
```

By hand, that is:

```sh
brew tap-new --no-git pyking-lang/local
cp tools/packaging/build/homebrew-local/pyking.rb \
   "$(brew --repository)/Library/Taps/pyking-lang/homebrew-local/Formula/"
brew install pyking-lang/local/pyking
brew test pyking-lang/local/pyking
```

Uninstall the local one before installing the published one, since both
install a `pyk`.

`make packaging ARCHS=arm64` builds a package for one architecture, which
needs only the arm64 release switch -- useful for trying the packaging
before setting up Rosetta. Its tarball is named for it
(`pyking-0.2.0-macos-arm64.tar.gz`), its formula says
`depends_on arch: :arm64`, and it is not meant to be published.

## One-time setup: the release toolchains

```sh
make packaging-setup
```

does all of it: each step below runs only if it has not been done, so
running it again after a failure resumes where it stopped. It then checks
both toolchains the way `make packaging` does, prints `ready` or the
problem for each architecture, and ends with one line saying whether the
setup **SUCCEEDED** or **FAILED** (with a matching exit status). It needs
opam for your own architecture already (`brew install opam`), and Rosetta
may ask for your password. Creating each switch compiles OCaml -- several
minutes natively, 10-30 under Rosetta -- and opam prints nothing while
`ocaml-compiler: sh make` runs; the step says how to follow its log. An
interrupted run is safe to repeat: a switch left half-made is removed
and created again.

What it does, and how to do it by hand, follows.

A release is built by two opam switches made for it, both called
`pyking-release`, one per architecture. Your everyday switch is not used
and not touched. They exist for two reasons:

- **macOS 11.** The linker can only promise what the objects it links
  were compiled for, and OCaml's runtime and standard library are
  compiled when a switch is created -- for the macOS of that day, unless
  told otherwise. A switch created with `MACOSX_DEPLOYMENT_TARGET=11.0`
  gives a `pyk` that really starts on Big Sur. (Linking an everyday switch
  gives a stream of `ld: warning: object file ... was built for newer
  'macOS' version` lines, and a binary that may not.)
- **Intel.** OCaml does not cross-compile to macOS, so the x86_64 half is
  built by an x86_64 OCaml running under Rosetta. It is run by opam's own
  x86_64 release binary, kept apart as `~/.local/bin/opam-x86_64` with its
  own root (`~/.opam-x86_64`); no Intel Homebrew is involved. Apple's
  `clang`, `make` and the rest are universal, so under `arch -x86_64` they
  build for Intel by themselves.

Both need only dune -- not js_of_ocaml, since the JavaScript bundle is
the same on every architecture, and `make build` makes it with your usual
switch.

**arm64**, beside your usual switches:

```sh
MACOSX_DEPLOYMENT_TARGET=11.0 opam switch create pyking-release 5.5.0 --no-switch
opam install --switch pyking-release dune
```

**x86_64**, under Rosetta:

```sh
softwareupdate --install-rosetta --agree-to-license
mkdir -p ~/.local/bin
curl -fL -o ~/.local/bin/opam-x86_64 \
  https://github.com/ocaml/opam/releases/download/2.6.0/opam-2.6.0-x86_64-macos
chmod +x ~/.local/bin/opam-x86_64
arch -x86_64 ~/.local/bin/opam-x86_64 init --root ~/.opam-x86_64 --bare --no-setup
arch -x86_64 /usr/bin/env MACOSX_DEPLOYMENT_TARGET=11.0 ~/.local/bin/opam-x86_64 switch create --root ~/.opam-x86_64 pyking-release 5.5.0
arch -x86_64 ~/.local/bin/opam-x86_64 install --root ~/.opam-x86_64 --switch pyking-release dune
```

The switch builds OCaml from source, so the `switch create` line takes a
few minutes.

Check them with:

```sh
opam exec --switch pyking-release -- ocamlopt -config-var architecture
# arm64
arch -x86_64 ~/.local/bin/opam-x86_64 exec --root ~/.opam-x86_64 --switch pyking-release -- ocamlopt -config-var architecture
# amd64
```

Those two command prefixes are what `make packaging` builds with. Before
building anything it checks each one: that it answers, builds for its
architecture, has dune, and has a runtime compiled for macOS 11 or older.
A failed check prints the commands above; `make packaging-setup` runs
them. To use other toolchains, put
their prefixes in `PYK_ARM64` and `PYK_X86_64`:

```sh
PYK_X86_64="arch -x86_64 /opt/x86/bin/opam exec --switch mine --" make packaging
```

On an Intel Mac, `make packaging ARCHS=x86_64` builds the Intel package
with `PYK_X86_64` (without its `arch -x86_64`); the universal one needs an
Apple Silicon Mac.

## Testing

`tests/test_packaging.py` is part of `make test`, on every system. It
stages the shipped tree around the machine's own `pyk`, installs it into a
temporary prefix shaped like Homebrew's (`bin/pyk` a link to a link into
`Cellar/pyking/<version>/libexec`), and from outside the repository checks
that `pyk --version`, a program, the standard library, the `iweb24`
target, `pyk notebook` and `pyk playground` all work, that the tree holds
nothing it should not, that the tarball is reproducible, and that the
formula says what it should (and is valid Ruby, where `ruby` exists).

When `tools/packaging/build/` holds a package, it also unpacks it, reads the
architectures of its `pyk` from the Mach-O header -- which works on any
system -- checks both formulas' checksums against the tarball, and on a
Mac runs the binary. It never runs `brew`; `make packaging-install` is the
test that does.

## Adding a format

A format is a class in `packaging.py` with a `name`, the `archs` it
builds, `refusal()` (why this machine cannot build it, or `None`) and
`build(archs)`, entered in `FORMATS`. `make packaging` builds every entry.
It ships the tree `stage()` builds and writes into `build/`.

## Layout

```
tools/packaging/
  packaging.py     the formats, the shipped tree, the tarball, the formula
  Makefile         setup, build, install-local, uninstall-local, release,
                   clean
  README.md
  build/           what `make packaging` writes; `make clean` removes it
```
