---
title: Install
description: Install Pyking on macOS, Linux or WSL, with Nix, or run it in Docker.
---

Pyking is one program, `pyk`, together with its standard library.
Compiling, interpreting and the REPL need nothing else.

## macOS

Install with [Homebrew](https://brew.sh):

```sh
brew update
brew install pyking-lang/tap/pyking
```

`brew upgrade pyking` updates it and `brew uninstall pyking` removes it.

## Linux and WSL

```sh
curl -fsSL https://github.com/pyking-lang/pyking-releases/releases/latest/download/install.sh | sh
```

This installs the latest release for your user, with no `sudo`: `pyk` goes
in `~/.local/bin/`. Add that directory to your `PATH` if the installer says
it is not there. Run the command again to update. Options go after
`sh -s --`:

```sh
curl -fsSL …/install.sh | sh -s -- --system        # for every user, in /usr/local (sudo)
curl -fsSL …/install.sh | sh -s -- --version 0.2.0 # a given release
curl -fsSL …/install.sh | sh -s -- --uninstall     # remove it
```

On Debian and Ubuntu, a `.deb` package is also available:

```sh
curl -fLO https://github.com/pyking-lang/pyking-releases/releases/latest/download/pyking_amd64.deb
sudo apt install ./pyking_amd64.deb      # pyking_arm64.deb on ARM
```

## Nix

On Linux and macOS, with flakes enabled:

```sh
nix run github:pyking-lang/pyking-releases -- hello.pyk   # run it without installing
nix profile install github:pyking-lang/pyking-releases    # install pyk
```

`nix profile upgrade pyking-releases` updates it and `nix profile remove
pyking-releases` removes it.

## Docker

The image runs `pyk` in the current directory, which is the container's
`/work`:

```sh
docker run --rm -it -v "$PWD:/work" ghcr.io/pyking-lang/pyking hello.pyk
docker run --rm -it -v "$PWD:/work" ghcr.io/pyking-lang/pyking          # the REPL
```

To use the playground, the notebook or the help, publish the port and
open the link it prints:

```sh
docker run --rm -p 8000:8000 ghcr.io/pyking-lang/pyking playground --port 8000
```

`ghcr.io/pyking-lang/pyking:full` also holds Python, node, a C compiler, a
JDK and OCaml, so `pyk compile --run` works for every target.

## Check the installation

```sh
pyk --version
```

Save this program as `hello.pyk`:

```pyking
print("Hello from Pyking")
```

Then run it with the interpreter, or compile it and run the result:

```sh
pyk hello.pyk                          # run it with the interpreter
pyk hello.pyk -t node                  # compile to JavaScript and run it with node
pyk compile -t c hello.pyk             # compile to C: build/hello.c, and the program ./hello
```

To start from an example instead, list them and save one in the current
directory:

```sh
pyk example                            # one example per line
pyk example use_args.pyk               # save it here
pyk use_args.pyk -- 3 'Hello world!'   # and run it
```

The playground's Examples menu offers the same ones.

## What else you may need

- `pyk notebook` and `pyk playground` need nothing more: `pyk` serves them
  itself.
- Running compiled output needs that target's own tools: `node` for
  JavaScript, a C compiler for C, a JDK for Java, `ocamlopt` for OCaml and
  `python3` for Python. Compiling alone needs none of them.
- Interpreting a program that has an external module of its own needs the
  OCaml compiler `pyk` was built with. The standard library works without it.
