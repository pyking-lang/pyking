# Packaging

Builds the packages Pyking is installed from on another machine, and
publishes them. The formats:

| Format | For | Holds |
|---|---|---|
| **Homebrew** | macOS 11 or later | a universal `pyk` (Apple Silicon and Intel) and a formula |
| **Linux** | every distribution, and WSL | a `pyk` per architecture (x86_64, aarch64), linked against glibc 2.28, as a tarball and a `.deb` |
| **Docker** | anything that runs Docker | the Linux tree on Debian, for x86_64 and arm64: `pyking` (pyk alone) and `pyking:full` (with every target's host), at `ghcr.io/pyking-lang/pyking` |
| **Nix** | Linux and macOS | a flake in `pyking-lang/pyking-releases` installing the release's tarballs |

Both hold a `pyk` that needs nothing but the system's C library, and the
standard library's interpreter plugins, compiled by the toolchain that
built that `pyk`. One release on GitHub holds every platform's files.

```sh
make packaging-setup     # once: the toolchains the packages are built with
make packaging           # every package, into tools/packaging/build/
make packaging-install   # try the build on this machine
make release             # publish it
```

## Installing

### macOS

```sh
brew install pyking-lang/tap/pyking
```

or, equivalently, `brew tap pyking-lang/tap` once and then `brew install
pyking`. `brew upgrade pyking` updates it and `brew uninstall pyking`
removes it. The tutorial as a notebook:

```sh
pyk notebook $(brew --prefix pyking)/libexec/PYKING-TUTORIAL.md
```

### Linux and WSL

```sh
curl -fsSL https://github.com/pyking-lang/pyking-releases/releases/latest/download/install.sh | sh
```

installs the latest release for your own user, with no sudo: the tree in
`~/.local/share/pyking/` and `pyk` in `~/.local/bin/`, which it asks you to
add to your `PATH` if it is not there. Options go after `sh -s --`:

```sh
curl -fsSL …/install.sh | sh -s -- --system        # every user, /usr/local (sudo)
curl -fsSL …/install.sh | sh -s -- --version 0.2.0 # that release
curl -fsSL …/install.sh | sh -s -- --uninstall     # remove it
```

Running it again updates to the latest release. It checks each download
against the release's `SHA256SUMS` and installs nothing if it does not
match, and it refuses macOS (use Homebrew there). It works the same in
WSL 1 and 2, in any distribution.

On **Debian, Ubuntu and WSL Ubuntu**, the `.deb` is an alternative, for
those who prefer apt; it puts the tree in `/usr/lib/pyking/` and `pyk` in
`/usr/bin/`:

```sh
curl -fLO https://github.com/pyking-lang/pyking-releases/releases/latest/download/pyking_amd64.deb
sudo apt install ./pyking_amd64.deb      # pyking_arm64.deb on ARM
```

It recommends `python3 (>= 3.10)` for the notebook, which apt installs by
default; `--no-install-recommends` installs `pyk` alone. It is not in an
apt repository, so `apt upgrade` does not update it: install the next
`.deb`, or use the one-liner.

### Nix

On Linux and macOS, with flakes enabled:

```sh
nix run github:pyking-lang/pyking-releases -- hello.pyk   # run it once
nix profile install github:pyking-lang/pyking-releases    # install pyk
nix profile upgrade pyking-releases                       # update it
nix profile remove pyking-releases                        # remove it
```

The flake builds nothing: its package unpacks the release's tarball for
the system -- Linux's per architecture, the universal macOS one on
both Macs -- fetched by its sha256, into `libexec/pyking/`, with
`bin/pyk` a link. On Linux `autoPatchelfHook` points `pyk` and its
plugins at Nix's own glibc, since NixOS has no `/lib64/ld-linux*`. It
is also a flake input like any other (`pyking.packages.${system}.default`).

### Docker

On anything that runs Docker, x86_64 or arm64. The current directory is
the container's `/work`, which is where `pyk` runs:

```sh
docker run --rm -it -v "$PWD:/work" ghcr.io/pyking-lang/pyking hello.pyk
docker run --rm -it -v "$PWD:/work" ghcr.io/pyking-lang/pyking          # the REPL
docker run --rm -p 8000:8000 ghcr.io/pyking-lang/pyking playground --port 8000
```

and the printed link opens the playground (or the notebook, or the help)
in the host's browser: the image sets `PYKING_WEB_HOST=0.0.0.0`, so `pyk`
listens on the container's every interface rather than its own
127.0.0.1, which `-p` cannot reach. Publish the port at the same number,
since the link names the container's. Add `--user "$(id -u):$(id -g)"`
for what `pyk compile` writes into `/work` to be yours rather than
root's.

Two images, each for both architectures:

| Tag | Holds |
|---|---|
| `latest`, `0.2.0` | `pyk` and its tree on Debian 13 (about 55 MB to download) |
| `full`, `0.2.0-full` | the same, with Python 3.14, node 24, gcc, a JDK 21 and OCaml 5.5.0 -- the OCaml `pyk` was built by -- so `pyk compile --run` runs every target, and a program's own external module compiles its plugin (about 500 MB) |

A tinyweb program run in a container serves its page on the
container's 127.0.0.1, so it cannot be opened from outside; the web
tools above can.

### What it needs

Nothing: `pyk` is one binary, linked against macOS's own libraries on a
Mac and against glibc 2.28 or later on Linux -- every current
distribution has it -- and the standard library's plugins ship beside
it. Three things need more, and only when used:

- Interpreting a program with an external module of its own needs **the
  OCaml `pyk` was built by** (5.5.0), to compile that module's plugin.
  `pyk` says so, with the version, if it is missing.
- `pyk notebook`, `pyk playground` and `pyk serve` need nothing more:
  `pyk` serves their pages itself. On WSL, the printed link opens in the
  Windows browser.
- Compiling for a target *and running the result* needs that target's own
  tools: `node` for JavaScript, `cc` for C, a JDK for Java, `ocamlopt` for
  OCaml, `python3` for Python. Compiling alone needs none of them, and
  `pyk file.pyk` (the interpreter) needs nothing.

## What a package holds

Every format ships the same tree, the repository's own layout minus
everything that is not needed to use the compiler, since `pyk` finds what
ships beside it by looking in its own directory (`src/install.ml`):

```
pyk                    the compiler
LICENSE
PYKING-TUTORIAL.md
lib/                   the standard library
build/pyking.js        the compiler as JavaScript: the iweb24 target and the pages
tools/webrun/          the web tools' scripts, and Ace, Monaco and KaTeX
tools/notebook/
tools/playground/      without examples: the playground starts with one program
tools/emacs/           pyking-mode.el, which registers `pyk lsp` with eglot
```

The language server is `pyk lsp`, so it is in every package already.

Homebrew puts it in the keg's `libexec/` and links `bin/pyk` to it; the
`.deb` in `/usr/lib/pyking/` with `/usr/bin/pyk` a link; install.sh in
`~/.local/share/pyking/` with `~/.local/bin/pyk` a link. `pyk` resolves
every symbolic link to its own path before looking beside itself, which
is what makes all three work.

## Building a release

On an Apple Silicon Mac with Docker (Docker Desktop, OrbStack or Colima),
with the one-time setup below done:

1. Set the version in `VERSION` (e.g. `0.2.0`, not `0.2.0-dev`), date its
   section in `CHANGELOG.md` (`## [0.2.0] - 2026-11-01`, where it said
   `Unreleased`), and commit both. The version is compiled into the
   binary (`pyk --version`) and names the release and its files; the
   section is what the release says has changed. Between releases,
   `VERSION` says the next version with `-dev`, and `CHANGELOG.md` collects
   its changes under `## [0.2.1] - Unreleased`, in the sections [Keep a
   Changelog](https://keepachangelog.com/en/1.1.0/) names (Added,
   Changed, Fixed, ...).
2. `make packaging` builds every format, into `tools/packaging/build/`:

   ```
   pyking-0.2.0-macos.tar.gz          Homebrew: universal pyk
   homebrew/pyking.rb                 its formula, naming the release
   homebrew-local/pyking.rb           the same, naming the file above
   pyking-0.2.0-linux-x86_64.tar.gz   Linux: pyk, per architecture
   pyking-0.2.0-linux-aarch64.tar.gz
   pyking-linux-x86_64.tar.gz         the same two, under the names
   pyking-linux-aarch64.tar.gz          install.sh downloads
   pyking_0.2.0_amd64.deb             the .debs
   pyking_0.2.0_arm64.deb
   pyking_amd64.deb                   the same two, under names a
   pyking_arm64.deb                     `latest` link can name
   pyking-0.2.0.vsix                  the VS Code and Cursor extension
   install.sh
   SHA256SUMS                         every file above
   nix/flake.nix                      the Nix flake, naming the release
   nix/flake.lock                     the nixpkgs it is locked to
   ```

   and, in Docker rather than in `build/`, one image per variant and
   architecture, tagged by the name a release pushes it under:
   `ghcr.io/pyking-lang/pyking:0.2.0-arm64`, `...:0.2.0-x86_64`,
   `...:0.2.0-full-arm64` and `...:0.2.0-full-x86_64`.

   - **macOS:** `pyk` is built twice -- arm64 natively, x86_64 under
     Rosetta -- by toolchains compiled for macOS 11, joined with `lipo`,
     signed ad hoc, and refused if it links anything outside `/usr/lib`
     and `/System`. The library plugins are built the same way: each
     architecture's `pyk plugins` by its own switch, in a tree of its own,
     and each plugin's slices joined with `lipo` and signed. The digest
     `pyk plugins` writes beside each plugin is shipped with it: without
     it `pyk` does not trust the plugin and compiles one, which needs
     OCaml. The tree's `pyk` then runs a program importing every
     library as each architecture, with no OCaml and an empty plugin
     cache.
   - **Linux:** `pyk` is built in an AlmaLinux 8 container per
     architecture (the other architecture emulated), linked dynamically
     against its glibc 2.28 -- dynamically because the interpreter loads
     plugins, which a static binary cannot. It is refused unless its ELF
     header says it is a dynamically linked binary for the right
     architecture and it asks for no glibc newer than 2.28
     (`GLIBC_FLOOR`). Its plugins are then built in the same container
     with the staged `pyk plugins`, and the staged tree is run --
     `pyk --version`, a program, and one importing libraries, which
     loads their plugins -- in current Debian and in Debian 10, to show
     it runs outside the system it was built on and on the oldest glibc
     it promises. The `.deb` is written directly by `packaging.py`, so no
     `dpkg` is needed; it depends on `libc6 (>= 2.28)` and nothing else.
   - **Docker:** made from the Linux tarballs above, so the format comes
     after `linux` and needs its tarballs (`FORMATS=linux,docker` builds
     both): `docker/Dockerfile`, with each architecture's tarball as
     `pyking.tar.gz` in the build context, has two targets. `slim`
     unpacks it on `debian:13-slim`; `full` copies that tree onto
     `python:3.14-slim-trixie`, the same Debian, with gcc, the JDK, node
     (from nodejs.org, checked against `NODE_SHA256`) and the OCaml of
     the Linux build image -- the compiler that built this `pyk`, at the
     path it was installed at, so the plugin of a program's own external
     module loads. That OCaml's runtime was compiled without PIE, which
     Debian's gcc links by default, so `ocamlopt` is `docker/ocamlopt`, a
     wrapper adding `-ccopt -no-pie` to every link but a plugin's
     (`-shared`). Each image is then run: `pyk --version`, a program and
     one importing libraries in both; in `slim` the playground, fetched
     from outside the container through its published port; in `full`
     `pyk compile --run` for Python, node, C, Java and OCaml, and a
     program whose external module's plugin is compiled there.
   - **Nix:** `nix/flake.nix` names every tarball of the release by its
     URL and its sha256, for `x86_64-linux`, `aarch64-linux` and both
     Darwins. Everything Nix does happens in a `nixos/nix` container
     (`NIX_IMAGE`), so no machine needs Nix: `nix flake lock` writes
     `flake.lock`, pinning `nixpkgs` (`NIXPKGS`); every system's
     derivation is instantiated, which evaluates each fetch without
     downloading anything; and, per architecture, the same flake with
     the local Linux tarball beside it in place of the download is built
     and its `pyk` run -- its version, a program and one importing
     libraries, with no OCaml there. The macOS package is evaluated but
     never built here.
   - **VS Code:** `make -C tools/editors/vscode vsix` packs the extension,
     with the language client it depends on, as `pyking-<version>.vsix`,
     which is checked to hold the client and to say `VERSION`. It needs
     node 20 or later and npm, and the network for `npm ci`. One file
     serves every platform: it starts the `pyk lsp` the user installed.

   Every format is checked before any is built, so a machine that cannot
   build one says so at once. `FORMATS=linux` (or `homebrew`, `docker`, `nix`,
   `vscode`) builds some formats, and `ARCHS=arm64` some architectures; neither is meant for
   publishing, and `make release` refuses a release that is not complete.
3. `make packaging-install` installs that build on this machine: through
   Homebrew and the local tap `pyking-lang/local` on a Mac (then runs the
   formula's own test), or with install.sh into `~/.local` on Linux,
   reading the files from `build/`. `make packaging-uninstall` undoes it.
4. `make release` publishes it. The code repository `pyking-lang/pyking`
   stays private: nothing about it is published.

   - It checks everything first: that `VERSION` is not a `-dev` one, that
     `CHANGELOG.md` has a dated, non-empty section for it, that every file
     of the release above exists for `VERSION` and matches `SHA256SUMS`, that the formula
     describes the Mac tarball, that `gh` is logged in, that git has a
     name and an email for the tap commit, that both repositories below
     exist and are public, and that release `v0.2.0` does not exist yet;
     that `nix/flake.nix` installs every system's tarball of this release
     by the checksum in `SHA256SUMS`, and is locked; that every Docker
     image is there for `VERSION`, that the `gh` login may write packages
     (`gh auth refresh -s write:packages` gives it the scope), and that
     `ghcr.io/pyking-lang/pyking:0.2.0` has not been pushed.
     And, for the tag at the end: that no tracked file has uncommitted
     changes (so the release is exactly the commit the tag names), that
     `origin` is `pyking-lang/pyking` and HEAD is already pushed there,
     and that `release-0.2.0` does not already name another commit.
   - It lists what it is about to do and asks. `make release YES=1` does
     not ask, here or at the tag.
   - It creates the release `v0.2.0` of **`pyking-lang/pyking-releases`**
     with every file, marked *latest* so the one-liner's `latest` link
     names it, and with notes that are the version's section of
     `CHANGELOG.md` ("What's changed") followed by how to install it, then downloads each file back -- and install.sh once more
     through `latest` -- and checks it against `SHA256SUMS`.
   - It clones **`pyking-lang/homebrew-tap`**, commits the formula as
     `Formula/pyking.rb` ("pyking 0.2.0") and pushes it. `brew upgrade`
     picks it up from there.
   - It commits `flake.nix`, `flake.lock` and the README to
     **`pyking-lang/pyking-releases`** ("pyking 0.2.0: the Nix flake") and
     pushes them, then runs `nix run github:pyking-lang/pyking-releases/<that
     commit> -- --version` in a Nix container, which downloads the
     release as a user's Nix would.
   - It logs Docker in to `ghcr.io` with the `gh` token, pushes the four
     images, and joins each variant's two architectures with `docker
     buildx imagetools create` under its version and its floating tag
     (`0.2.0` and `latest`, `0.2.0-full` and `full`). A new package on
     ghcr.io is private: the first release says so if the image cannot
     be pulled without a login, and it is made public once, under
     Package settings at
     <https://github.com/orgs/pyking-lang/packages/container/pyking/settings>.
     Each later version inherits that.

     Should the push fail once the release is out, `make release` will
     not run again for that version (the release exists), so push them by
     hand, logged in as `gh auth token | docker login ghcr.io -u <you>
     --password-stdin`:

     ```sh
     for t in 0.2.0-arm64 0.2.0-x86_64 0.2.0-full-arm64 0.2.0-full-x86_64; do
       docker push ghcr.io/pyking-lang/pyking:$t; done
     docker buildx imagetools create -t ghcr.io/pyking-lang/pyking:0.2.0 \
       -t ghcr.io/pyking-lang/pyking:latest \
       ghcr.io/pyking-lang/pyking:0.2.0-arm64 ghcr.io/pyking-lang/pyking:0.2.0-x86_64
     docker buildx imagetools create -t ghcr.io/pyking-lang/pyking:0.2.0-full \
       -t ghcr.io/pyking-lang/pyking:full \
       ghcr.io/pyking-lang/pyking:0.2.0-full-arm64 ghcr.io/pyking-lang/pyking:0.2.0-full-x86_64
     ```
   - It asks, on its own, `Tag <commit> in pyking-lang/pyking as
     release-0.2.0? [y/N]`, and on yes tags HEAD in the code repository
     -- annotated, "Pyking 0.2.0" -- and pushes the tag to `origin`. On no
     the release stands untagged, and it prints the two commands that tag
     it later. A commit that already carries the tag is left alone.
   - It ends with one line: **SUCCEEDED**, saying whether it tagged, with
     both install commands, or **FAILED**, with the reason. A tag that
     fails to push after the release is out says so, and how to tag by
     hand.

   A published release is never replaced: everyone who installed it
   holds its checksums. To change one, bump `VERSION` and release again.

The two public repositories are made once, and neither holds code:

```sh
gh repo create pyking-lang/pyking-releases --public --description "Pyking releases for macOS, Linux and WSL"
gh repo create pyking-lang/homebrew-tap --public --description "Homebrew tap for Pyking"
```

`pyking-lang/pyking-releases` holds every download, since users fetch them
without credentials and so cannot reach a private repository.
`pyking-lang/homebrew-tap` holds only the formula; its name is what makes
`brew install pyking-lang/tap/pyking` work, since Homebrew looks for the
tap `<owner>/<tap>` in the repository `<owner>/homebrew-<tap>`. The first
release gives each a README if it is empty, and every release rewrites
`pyking-lang/pyking-releases`'s, beside its flake. The Docker images need
no repository of their own: `ghcr.io/pyking-lang/pyking` is a package of
the organisation, linked to `pyking-lang/pyking-releases` by the images'
`org.opencontainers.image.source` label. `make release` needs `gh`
(`brew install gh`, then `gh auth login`).

## Trying a build locally

`make packaging-install`, above, is the short way. By hand, on a Mac --
current Homebrew installs a formula only from a tap:

```sh
brew tap-new --no-git pyking-lang/local
cp tools/packaging/build/homebrew-local/pyking.rb \
   "$(brew --repository)/Library/Taps/pyking-lang/homebrew-local/Formula/"
brew install pyking-lang/local/pyking
brew test pyking-lang/local/pyking
```

Uninstall the local one before installing the published one, since both
install a `pyk`. On Linux, install.sh reads a build from a directory
instead of a release when `PYKING_DOWNLOAD_BASE` names one:

```sh
PYKING_DOWNLOAD_BASE=file://$PWD/tools/packaging/build sh tools/packaging/install.sh
```

The Docker images are on this machine once built, under the names a
release pushes:

```sh
docker run --rm -it -v "$PWD:/work" ghcr.io/pyking-lang/pyking:0.2.0-arm64 hello.pyk
```

The flake can be tried with Nix, here or in its container:

```sh
nix run ./tools/packaging/build/nix -- --version    # only once the release exists
```

A `.deb` can be tried in a throwaway container:

```sh
docker run --rm -v $PWD/tools/packaging/build:/b debian:stable-slim sh -c \
  'apt-get update -qq && apt-get install -y -qq --no-install-recommends /b/pyking_arm64.deb && pyk --version'
```

## One-time setup

```sh
make packaging-setup                 # FORMATS=linux on a Linux machine
```

does all of it, for every format: each step runs only if it has not been
done, so running it again after a failure resumes where it stopped. It
then checks each toolchain the way `make packaging` does, prints `ready`
or the problem for each format and architecture, and ends with one line
saying whether the setup **SUCCEEDED** or **FAILED** (with a matching
exit status).

### Linux: the build images

One Docker image per architecture, `pyking-linux-build:<arch>-<hash>`,
from `linux/Dockerfile`: AlmaLinux 8, with an opam switch holding OCaml and
dune. Its tag carries a hash of the Dockerfile and the OCaml version, so
changing either makes the next setup build a new image. Building one
compiles OCaml -- several minutes natively, 30-60 emulated.

The other architecture runs emulated. Docker Desktop and OrbStack do that
out of the box; on Linux, QEMU has to be registered once, which setup
does not do for you, since it changes the host:

```sh
docker run --privileged --rm tonistiigi/binfmt --install amd64   # or arm64
```

By hand, setup is:

```sh
docker build --platform linux/arm64 -t pyking-linux-build:arm64-<hash> tools/packaging/linux
docker build --platform linux/amd64 -t pyking-linux-build:x86_64-<hash> tools/packaging/linux
```

(`make packaging-setup` prints the tags it expects.) A Linux build then
runs as your own user, with the repository mounted, so what it writes into
`tools/packaging/build/` is yours.

The Docker format makes nothing of its own: its images are made from
the Linux packages, and the full one copies the Linux build image's
OCaml, so setup only checks that those images exist. The Nix format's
setup pulls `nixos/nix`.

### macOS: the release toolchains

It needs opam for your own architecture already (`brew install opam`),
and Rosetta may ask for your password. Creating each switch compiles OCaml -- several
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
MACOSX_DEPLOYMENT_TARGET=11.0 opam switch create pyking-release \
  --packages=ocaml-variants.5.5.0+options,ocaml-option-no-compression --no-switch
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
arch -x86_64 /usr/bin/env MACOSX_DEPLOYMENT_TARGET=11.0 ~/.local/bin/opam-x86_64 switch create --root ~/.opam-x86_64 pyking-release \
  --packages=ocaml-variants.5.5.0+options,ocaml-option-no-compression
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
architecture, is OCaml 5.5.0, has dune, and has a runtime compiled for
macOS 11 or older. A failed check prints the commands above; `make
packaging-setup` runs them.

Both switches are the release built **without zstd**
(`ocaml-option-no-compression`, which needs `ocaml-variants`; it is
still the official release). Since 5.1, OCaml compresses its compiled
files with zstd when it finds the library while it is built, and that
changes the checksum of every interface. The arm64 build finds
Homebrew's zstd and the x86_64 one under Rosetta cannot, so without the
option the two halves of `pyk` would disagree about the plugin
interface. A switch built with zstd is refused, and `make
packaging-setup` replaces it.

It also checks that the two are the same compiler: a plugin is compiled
against one `pyk_plugin.cmi` and has to load into both halves of the
universal `pyk`, so their standard libraries must have the same
checksum. Every build of a release without zstd has the same one, on
every architecture, and `STDLIB_CHECKSUMS` in `packaging.py` records it
for `OCAML_VERSION`: when the version is bumped, add the new one, read
from a fresh switch with

```sh
opam exec --switch pyking-release -- sh -c 'ocamlobjinfo "$(ocamlopt -where)/stdlib.cmi"' | grep -m1 Stdlib
```

A switch with another checksum was built differently -- with zstd, or
from a download opam kept in its cache from before the release was
final -- and the refusal says which switch, and how to make it again
from a fresh download (`opam update`, `opam clean --download-cache`,
`opam switch remove`, then `make packaging-setup`). To use other toolchains, put
their prefixes in `PYK_ARM64` and `PYK_X86_64`:

```sh
PYK_X86_64="arch -x86_64 /opt/x86/bin/opam exec --switch mine --" make packaging
```

On an Intel Mac, `make packaging ARCHS=x86_64` builds the Intel package
with `PYK_X86_64` (without its `arch -x86_64`); the universal one needs an
Apple Silicon Mac.

## Testing

`tests/test_packaging.py` is part of `make test`, on every system. It
stages the shipped tree around the machine's own `pyk`, then:

- installs it into a temporary prefix shaped like Homebrew's (`bin/pyk` a
  link to a link into `Cellar/pyking/<version>/libexec`) and, from outside
  the repository, checks that `pyk --version`, a program, the standard
  library, the `iweb24` target, `pyk notebook` and `pyk playground` all
  work, that the tree holds nothing it should not, that the tarball is
  reproducible, and that the formula says what it should (and is valid
  Ruby, where `ruby` exists);
- packs it as a `.deb`, reads it back -- with its own reader, and with
  `dpkg-deb` where it exists -- and runs the `pyk` it installs;
- runs install.sh against a release copied into a temporary directory,
  into a temporary home: installing, installing again, refusing a wrong
  checksum, sending a Mac to Homebrew, refusing an unknown option, and
  uninstalling; and checks that it parses under `dash` and BusyBox;
- checks the Mach-O and ELF readers and `SHA256SUMS`;
- checks the Docker and Nix formats without either: that the Dockerfile
  has both images and what they need, and that the flake installs every
  system's tarball by its checksum, which `make release` refuses
  otherwise (parsed by `nix-instantiate`, where Nix is installed).

When `tools/packaging/build/` holds packages, it also unpacks them and
checks each `pyk` -- the Mac's architectures from the Mach-O header, each
Linux one's architecture, that it is dynamically linked and the glibc it
asks for from the ELF file, and every package's library plugins, which
needs neither system -- checks `SHA256SUMS` and both formulas against the
files, checks `nix/flake.nix` against the tarballs built, and runs what
this machine can run. It never runs `brew`, `dpkg -i`
or a release; `make packaging-install` is the test that installs.

## Adding a format

A format is a class in `packaging.py` with a `name`, `refusal()` (why this
machine cannot build it, or `None`), `setup()`, `build(archs)`, and
`install_local()` / `uninstall_local()` if it can be installed where it is
built, entered in `FORMATS`. `make packaging` builds every entry. It ships
the tree `stage()` builds, writes into `build/`, and adds its files to
`release_assets`, which is what `make release` publishes. A format made
from another's output, as Docker and Nix are from Linux's tarballs, is
entered after it, since `FORMATS` is the order they are built in, and
one published somewhere other than the release -- a registry, a
repository -- is published by `release()` after the release, and
checked by it before anything is.

## Layout

```
tools/packaging/
  packaging.py     the formats, the shipped tree, the tarball, the .deb,
                   the formula, the release
  install.sh       the Linux and WSL installer, published with every release
  linux/Dockerfile the Linux build image
  docker/          the Docker images: Dockerfile (slim and full), and
                   ocamlopt, the full image's wrapper around OCaml
  Makefile         setup, build, install-local, uninstall-local, release,
                   clean
  README.md
  build/           what `make packaging` writes; `make clean` removes it
```
