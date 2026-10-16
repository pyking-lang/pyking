---
title: Editors
description: Set up your editor to use the Pyking language server, pyk lsp.
sidebar:
  order: 2
---

`pyk` includes a language server, `pyk lsp`. An editor starts it and
talks to it over the Language Server Protocol (LSP). The server is part
of `pyk`, so there is nothing else to install: an editor only needs to
know how to start it.

The server gives:

- **Diagnostics**: the first error in a file, from lexing, parsing, the
  module system, names, types or mutability. An error in an imported
  module is shown at the `import` that reaches it.
- **Hover**: the type of the expression, binding, parameter or
  definition under the cursor, and for a name, the `##` comment above
  its definition.
- **Go to definition**: where a name is bound, in the same file, in a
  module it imports, or in the standard library.
- **Outline** (document symbols): the `def`s, the top-level bindings
  and the imports.
- **Completion**: keywords, builtins, the names in scope, and after
  `m.` the names that module `m` exports.

Each document is checked as a program, together with the modules it
imports. A module that is open in the editor is read from the editor,
so an unsaved change is seen by every file that imports it.

## Options and settings

```sh
pyk lsp [--stdio] [-L DIR]... [--log FILE]
```

- `--stdio` uses standard input and output. It is the only transport and
  the default; it is accepted because some editors always pass it.
- `-L DIR` / `--lib-path DIR`, and the environment variable
  `PYKING_LIB_PATH`, add library directories, as for `pyk`.
- `--log FILE` appends every message in and out, and any internal error,
  to `FILE`. Use it when an editor's setup does not work: standard
  output carries only the protocol, and editors often hide standard
  error.

An editor can send two settings, as `initializationOptions` or as the
`pyking` section of its workspace configuration:

| setting | default | meaning |
|---|---|---|
| `libPath` | `[]` | more library directories, searched after `-L` |
| `diagnostics` | `"change"` | `"change"`: check as you type, once typing pauses; `"save"`: check only when a file is opened or saved |

The examples below assume `pyk` is on your `PATH`. If it is not, write
its full path in place of `pyk`.

## VS Code

Install the Pyking extension. It is attached to every release as
`pyking-<version>.vsix`, at
[github.com/pyking-lang/pyking-releases/releases](https://github.com/pyking-lang/pyking-releases/releases).
Download it, then:

```sh
code --install-extension pyking-<version>.vsix
```

or, in the Extensions view, open the `...` menu and choose **Install
from VSIX...**. The extension marks `.pyk` files as Pyking, highlights
them, and starts `pyk lsp --stdio`. Its settings:

```json
{
  "pyking.server.path": "pyk",
  "pyking.server.args": ["lsp"],
  "pyking.libPath": [],
  "pyking.diagnostics": "change",
  "pyking.trace.server": "off"
}
```

To log the server's messages, set `"pyking.server.args"` to
`["lsp", "--log", "/tmp/pyk-lsp.log"]`. The command **Pyking: Restart
Language Server** restarts it.

## Cursor

Cursor installs the same `.vsix` as VS Code:

```sh
cursor --install-extension pyking-<version>.vsix
```

or, in the Extensions view, open the `...` menu and choose **Install
from VSIX...**. The settings are the same as for VS Code.

## Neovim

Neovim 0.11 and later configure a server with `vim.lsp.config`. Add this
to your `init.lua`:

```lua
vim.filetype.add({ extension = { pyk = "pyking" } })

vim.lsp.config("pyking", {
  cmd = { "pyk", "lsp" },
  filetypes = { "pyking" },
  root_markers = { ".git" },
  init_options = { libPath = {}, diagnostics = "change" },
})
vim.lsp.enable("pyking")
```

With an older Neovim and
[nvim-lspconfig](https://github.com/neovim/nvim-lspconfig), register a
custom server:

```lua
vim.filetype.add({ extension = { pyk = "pyking" } })

local configs = require("lspconfig.configs")
if not configs.pyking then
  configs.pyking = {
    default_config = {
      cmd = { "pyk", "lsp" },
      filetypes = { "pyking" },
      root_dir = require("lspconfig.util").root_pattern(".git"),
      single_file_support = true,
    },
  }
end
require("lspconfig").pyking.setup({})
```

## Vim

With [vim-lsp](https://github.com/prabirshrestha/vim-lsp), add this to
your `.vimrc`:

```vim
autocmd BufRead,BufNewFile *.pyk setfiletype pyking

if executable('pyk')
  autocmd User lsp_setup call lsp#register_server({
    \ 'name': 'pyking',
    \ 'cmd': {server_info -> ['pyk', 'lsp']},
    \ 'allowlist': ['pyking'],
    \ })
endif
```

With [coc.nvim](https://github.com/neoclide/coc.nvim), set the file type
as above and add a server to `coc-settings.json` (`:CocConfig`):

```json
{
  "languageserver": {
    "pyking": {
      "command": "pyk",
      "args": ["lsp"],
      "filetypes": ["pyking"],
      "initializationOptions": { "libPath": [], "diagnostics": "change" }
    }
  }
}
```

## Emacs

`pyking-mode.el`, Pyking's Emacs mode, registers `pyk lsp` with eglot,
which is built into Emacs 29 and later. It ships with Pyking, in
`tools/emacs/` of the installation: under Homebrew that is
`$(brew --prefix)/opt/pyking/libexec/tools/emacs/`; with install.sh
`~/.local/share/pyking/tools/emacs/` (`/usr/local/lib/pyking/tools/emacs/`
with `--system`); with the `.deb` `/usr/lib/pyking/tools/emacs/`; and
with Nix `~/.nix-profile/libexec/pyking/tools/emacs/`. Add that directory to `load-path` and `(require 'pyking-mode)`.
With the mode loaded, `M-x eglot` in a `.pyk` buffer starts the server. To start
it in every Pyking buffer:

```elisp
(add-hook 'pyking-mode-hook #'eglot-ensure)
```

The variable `pyking-lsp-command` (default `("pyk" "lsp")`) is the
command eglot runs. Without `pyking-mode.el`, register the server
yourself for whichever mode you use for `.pyk` files:

```elisp
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs '(pyking-mode . ("pyk" "lsp"))))
```

With [lsp-mode](https://emacs-lsp.github.io/lsp-mode/) instead of
eglot:

```elisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(pyking-mode . "pyking"))
  (lsp-register-client
   (make-lsp-client :new-connection (lsp-stdio-connection '("pyk" "lsp"))
                    :activation-fn (lsp-activate-on "pyking")
                    :server-id 'pyking)))
```

## Sublime Text

Install the [LSP](https://packagecontrol.io/packages/LSP) package. Sublime
Text needs a syntax whose scope is `source.pyking`; save this as
`Packages/User/Pyking.sublime-syntax` (**Preferences > Browse
Packages...** opens `Packages/`):

```yaml
%YAML 1.2
---
name: Pyking
file_extensions: [pyk]
scope: source.pyking
contexts:
  main:
    - match: '#.*$'
      scope: comment.line.number-sign.pyking
    - match: '"(\\.|[^"\\])*"|''(\\.|[^''\\])*'''
      scope: string.quoted.pyking
    - match: '\b(for|in|if|while|loop|break|continue|then|else|var|def|return|match|case|public|implicit|import|from|as)\b'
      scope: keyword.control.pyking
    - match: '\b(Int|Float|String|Bool)\b'
      scope: storage.type.pyking
    - match: '\b(true|false)\b'
      scope: constant.language.pyking
    - match: '\b[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?\b'
      scope: constant.numeric.pyking
```

Then add a client in **Preferences > Package Settings > LSP >
Settings**:

```json
{
  "clients": {
    "pyking": {
      "enabled": true,
      "command": ["pyk", "lsp"],
      "selector": "source.pyking",
      "initializationOptions": { "libPath": [], "diagnostics": "change" }
    }
  }
}
```

## Zed

There is no Zed extension for Pyking yet. Zed requires an extension to
add a language, so a server cannot be configured on its own. An
extension is planned.

## PyCharm and IntelliJ IDEA

Install the [LSP4IJ](https://plugins.jetbrains.com/plugin/23257-lsp4ij)
plugin, which works in PyCharm, IntelliJ IDEA and the other JetBrains
IDEs. Then, in **Settings > Languages & Frameworks > Language Servers**,
add a server with **+**:

- **Server** tab: name `Pyking`, command `pyk lsp`.
- **Mappings** tab, **File name patterns**: the pattern `*.pyk`, with
  language id `pyking`.
- **Configuration** tab, **Initialization options**, if you need them:

```json
{ "libPath": [], "diagnostics": "change" }
```

For highlighting, the IDE can read the VS Code extension's grammar:
unzip `pyking-<version>.vsix` (it is a zip file) and add its
`extension/` directory in **Settings > Editor > TextMate Bundles**.

## Helix

Add this to `languages.toml` (`~/.config/helix/languages.toml`):

```toml
[language-server.pyk]
command = "pyk"
args = ["lsp"]

[[language]]
name = "pyking"
scope = "source.pyking"
file-types = ["pyk"]
comment-token = "#"
indent = { tab-width = 4, unit = "    " }
language-servers = ["pyk"]
```

Helix has no Pyking grammar, so the file is not highlighted, but
diagnostics, hover, go to definition, symbols and completion work.

## When it does not work

- Run `pyk --version` in a terminal. If it fails, `pyk` is not on the
  `PATH` the editor sees; give the editor the full path instead.
- Add `--log FILE` to the command, for example `pyk lsp --log
  /tmp/pyk-lsp.log`, open a `.pyk` file, and read the log. If the file
  is empty, the editor did not start the server.
