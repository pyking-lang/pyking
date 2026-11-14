---
title: Setting up Pyking
description: Install Pyking, check that it works, and set up your editor.
sidebar:
  order: 2
---

Pyking is one program, `pyk`, together with its standard library. This
page says how to install it, what you can do with it then, and how to
set up your editor.

## Installing Pyking

One command installs it on each platform. The [Install](/install/)
page has the details: other options, upgrading and removing it.

| platform | install with |
|---|---|
| macOS | Homebrew: `brew install pyking-lang/tap/pyking` |
| Linux and WSL | the install script: `curl -fsSL https://github.com/pyking-lang/pyking-releases/releases/latest/download/install.sh \| sh` |
| Debian and Ubuntu | the script above, or the `.deb` package |
| Linux and macOS, with Nix | `nix profile install 'github:pyking-lang/pyking/release-<version>?dir=tools/packaging/nix'` |
| Docker | `docker run --rm -it -v "$PWD:/work" ghcr.io/pyking-lang/pyking` starts the REPL; the `full` tag also holds every target's tools |

### Check the installation

```sh
pyk --version
```

prints the version. Then list the bundled examples, save one, and run
it:

```sh
pyk example                            # one example per line
pyk example hello.pyk                  # save it in the current directory
pyk hello.pyk                          # and run it
```

## What you can do once it is installed

| command | does |
|---|---|
| `pyk prog.pyk` | runs a program with the interpreter |
| `pyk repl` | starts the [REPL](/documentation/repl/) |
| `pyk compile prog.pyk --target T` | compiles a program for target `T`; add `--run` to run it too |
| `pyk playground` | serves the [playground](/documentation/playground/) on your machine and prints a link to open |
| `pyk notebook book.md` | opens a [notebook](/documentation/notebook/) in the browser |
| `pyk serve dir` | serves a directory, such as a page compiled for `web` |
| `pyk example [NAME]` | lists the bundled examples, or saves the one named |
| `pyk pykhelp` | serves this documentation, for reading offline |
| `pyk highlight prog.pyk` | colours code for slides: HTML, RTF or text |
| `pyk lsp`, `pyk dap` | the language server and the debugger, which an editor starts |

`pyk --help` lists every option. The [Command line](/documentation/command-line/)
page covers them.

### What each target needs to run

The interpreter, the REPL, the playground and the notebook need nothing
but `pyk`. Running a compiled program needs its target's own tools.
Compiling alone needs none of them.

| target | to run the result, you need |
|---|---|
| `python` | `python3`, 3.12 or later |
| `node` | `node`, 22 or later |
| `web`, `iweb` | a browser; `--run` serves the page with `pyk serve` |
| `c` | a C compiler, `cc` |
| `c-gc` | a C compiler with C23, and the bdwgc collector: `brew install bdw-gc` on macOS, `apt install libgc-dev` on Debian and Ubuntu, `dnf install gc-devel` on Fedora |
| `java` | a JDK, 21 or later (`java8` and `java17` are older targets) |
| `ocaml` | `ocamlopt`, 4.14 or later |

A version in the table is that family's default target, which names
the oldest version its output runs on. See
[Compiler targets](/documentation/targets/) for the others.

Interpreting a program that has an external module of its own needs
the OCaml compiler that `pyk` was built with. The standard library
works without it.

## Editor support

`pyk` includes a language server, `pyk lsp`, and a debugger, `pyk dap`.
Each editor below is set up on the [Editors](/documentation/editors/)
page.

| editor | highlighting | language server | debugger |
|---|---|---|---|
| [VS Code](/documentation/editors/#vs-code) | yes, from the Pyking extension | yes | yes |
| [Cursor](/documentation/editors/#cursor) | yes, from the Pyking extension | yes | yes |
| [Neovim](/documentation/editors/#neovim) | no grammar | yes | yes, with nvim-dap |
| [Vim](/documentation/editors/#vim) | no grammar | yes, with vim-lsp or coc.nvim | yes, with vimspector |
| [Emacs](/documentation/editors/#emacs) | yes, from `pyking-mode.el` | yes, with eglot or lsp-mode | yes, with dape |
| [Sublime Text](/documentation/editors/#sublime-text) | yes, from a syntax file you save | yes, with the LSP package | not yet |
| [Zed](/documentation/editors/#zed) | not yet | not yet | not yet |
| [PyCharm and IntelliJ IDEA](/documentation/editors/#pycharm-and-intellij-idea) | yes, from the VS Code extension's grammar | yes, with LSP4IJ | yes, with LSP4IJ |
| [Helix](/documentation/editors/#helix) | no | yes | yes, experimental |

### What the language server is

The Language Server Protocol (LSP) is a standard way for an editor to
talk to a program that knows a language. `pyk lsp` is that program for
Pyking. Every editor starts the same `pyk lsp`, so every editor gets
the same features:

- **Diagnostics**: the first error in a file, as you type, and its
  warnings.
- **Hover**: the type of what is under the cursor, and a name's `##`
  comment.
- **Go to definition**, **references** and **rename**.
- **Completion**, and **signature help** while a call is typed.
- **Inlay hints**: the types the checker inferred, shown where none is
  written.
- **Quick fixes**, such as the `use mutation` line a `var` needs.
- **Outline**, **folding** and **semantic highlighting**.

The server is part of `pyk`, so nothing else needs installing: an
editor only needs to know how to start it. The debugger, `pyk dap`,
works the same way, over the Debug Adapter Protocol (DAP); see
[Debugging](/getstarted/debugging/).
