---
title: Editors
description: Set up your editor to use the Pyking language server, pyk lsp, and the Pyking debugger, pyk dap.
sidebar:
  order: 2
---

`pyk` includes a language server, `pyk lsp`, and a debugger, `pyk dap`.
An editor starts them and talks to them over the Language Server
Protocol (LSP) and the Debug Adapter Protocol (DAP). Both are part of
`pyk`, so there is nothing else to install: an editor only needs to know
how to start them. Each editor's section below sets up both.

The server gives:

- **Diagnostics**: the first error in a file, from lexing, parsing, the
  module system, names, types or mutability. An error in an imported
  module is shown at the `import` that reaches it. In a file with no
  error, its warnings: a name bound and never used, and an `=` that
  shadows a name from outside its block (see "Options and settings").
- **Quick fixes** for a warning: `_` put in front of a name that is
  never used.
- **Hover**: the type of the expression, binding, parameter or
  definition under the cursor, and for a name, the `##` comment above
  its definition. Types are inferred where a function is called, so
  inside a function nothing calls, hover says so instead; while the
  program has a type error, it says that.
- **Go to definition**: where a name is bound, in the same file, in a
  module it imports, or in the standard library.
- **Outline** (document symbols): the `def`s, the top-level bindings
  and the imports.
- **Completion**: keywords, builtins, the names in scope, and after
  `m.` the names that module `m` exports.
- **Signature help**: while a call is typed, the function's parameters
  with their types, the one being written marked, and what its `##`
  comment says of each. A named argument marks its parameter.
- **References** and **highlights**: every place a name is written, in
  the file and in the modules of the program.
- **Rename**: a binding and every use of it renamed together. A rename
  that would make a use mean another binding is refused, and so is one
  of a name the standard library defines.
- **Inlay hints**: the types the checker inferred, shown after each
  binding and parameter written without one, and after a `def` that does
  not say what it returns.
- **Folding**: blocks, runs of comment lines, and the imports.
- **Semantic highlighting**: functions, parameters, variables (a `var`
  apart from an `=` binding), modules, types, constructors and fields.
- **Quick fixes**: `+` for the `++` and `^` for the `**` Pyking no
  longer has, `and` for an `&` on Bools and the like, the `use mutation`
  line a `var` needs, a name in scope for a misspelt one, and an annotation changed to the type
  of the value.

Each document is checked as a program, together with the modules it
imports. A module that is open in the editor is read from the editor,
so an unsaved change is seen by every file that imports it.

## Options and settings

```sh
pyk lsp [--stdio] [-L DIR]... [--log FILE] [-W...]
```

- `--stdio` uses standard input and output. It is the only transport and
  the default; it is accepted because some editors always pass it.
- `-L DIR` / `--lib-path DIR`, and the environment variable
  `PYKING_LIB_PATH`, add library directories, as for `pyk`.
- `--log FILE` appends every message in and out, and any internal error,
  to `FILE`. Use it when an editor's setup does not work: standard
  output carries only the protocol, and editors often hide standard
  error.
- `-Wall`, `-Wno-unused-binding`, `-Werror` and `pyk`'s other -W flags
  say which warnings are shown until the editor's `warnings` setting
  says otherwise.

An editor can send three settings, as `initializationOptions` or as the
`pyking` section of its workspace configuration:

| setting | default | meaning |
|---|---|---|
| `libPath` | `[]` | more library directories, searched after `-L` |
| `diagnostics` | `"change"` | `"change"`: check as you type, once typing pauses; `"save"`: check only when a file is opened or saved |
| `warnings` | `[]` | which warnings are shown, as `pyk`'s flags: `["-Wall"]`, `["-Wno-unused-function", "-Werror"]`; empty is the defaults |

A warning -- a name bound and never used, say -- is shown as a warning
and the name faded, with a quick fix that puts `_` in front of it; one
the `warnings` setting makes an error is shown as an error. `pyk lsp
-Wall` says what is shown until an editor sends the setting.

## The debugger

```sh
pyk dap [--stdio] [--log FILE] [-W...]
```

`pyk dap` runs a program with the interpreter, as `pyk <file>` does, and
lets the editor set breakpoints, step through the program, and show the
calls in progress, their variables, and the value of an expression
where the program stopped. It speaks DAP on standard input and output;
`--stdio` and `--log` are as for `pyk lsp`. The editor's *launch*
request says what to run:

| argument | default | meaning |
|---|---|---|
| `program` | | the Pyking file to run |
| `args` | `[]` | the program's own arguments, what `sys.args()` answers |
| `stdin` | | a file the program reads as its standard input; without one it reads nothing |
| `cwd` | | the directory the program runs in |
| `stopOnEntry` | `false` | stop at the first statement |
| `justMyCode` | `true` | step over the code of the standard library and of `-L` libraries |
| `libPath` | `[]` | more library directories, searched after `-L` |
| `release` | `false` | debug the program as `--release` compiles it, every `debug()` removed |
| `warnings` | `[]` | `pyk`'s -W flags for the program's check, after those `pyk dap` was started with; its warnings are written to the debug console, and one made an error stops the launch |

A breakpoint stops at the first statement starting on its line or after
it, and may have a condition (a Bool expression), a hit count (`3` for
the third time only, `>= 3`, `% 2`) or a log message, which is printed
instead of stopping, with each `{expression}` in it replaced by its
value. A runtime error stops the program where it happens unless the
editor turns off the **Runtime errors** breakpoint. An expression
evaluated where the program stopped -- a watch, the debug console, a
hover -- is type-checked against the names in scope there. Only a `var`
can be given a new value. A tinyweb program's callbacks are debugged
too: a breakpoint in one stops when its event arrives.

The program's standard output and its `debug` lines arrive in the
editor's debug console, as standard output and standard error.

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
  "pyking.warnings": [],
  "pyking.trace.server": "off"
}
```

To log the server's messages, set `"pyking.server.args"` to
`["lsp", "--log", "/tmp/pyk-lsp.log"]`. The command **Pyking: Restart
Language Server** restarts it.

### Debugging

The extension adds a `pyking` debugger that starts `pyk dap`. With a
`.pyk` file open, **Run > Start Debugging** debugs it; click left of a
line number to set a breakpoint. To give the program arguments or
input, add a configuration to `.vscode/launch.json`:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "pyking",
      "request": "launch",
      "name": "Debug the current Pyking file",
      "program": "${file}",
      "args": [],
      "stdin": "${workspaceFolder}/input.txt",
      "stopOnEntry": false,
      "justMyCode": true
    }
  ]
}
```

The setting `"pyking.debugger.args"` (default `["dap"]`) is what
`pyking.server.path` is started with; `["dap", "--log",
"/tmp/pyk-dap.log"]` logs the adapter's messages.

## Cursor

Cursor installs the same `.vsix` as VS Code:

```sh
cursor --install-extension pyking-<version>.vsix
```

or, in the Extensions view, open the `...` menu and choose **Install
from VSIX...**. The settings are the same as for VS Code.

### Debugging

The same as in VS Code: the extension's `pyking` debugger starts `pyk
dap`, and **Run > Start Debugging** debugs the open `.pyk` file.

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

### Debugging

With [nvim-dap](https://github.com/mfussenegger/nvim-dap):

```lua
local dap = require("dap")
dap.adapters.pyking = { type = "executable", command = "pyk", args = { "dap" } }
dap.configurations.pyking = {
  {
    type = "pyking",
    request = "launch",
    name = "Debug this file",
    program = "${file}",
  },
}
```

`:lua require("dap").toggle_breakpoint()` sets a breakpoint and
`:lua require("dap").continue()` starts debugging. vimspector, below,
works in Neovim too.

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

### Debugging

With [vimspector](https://github.com/puremourning/vimspector), put a
`.vimspector.json` in the project's directory:

```json
{
  "adapters": {
    "pyking": { "name": "pyking", "command": ["pyk", "dap"] }
  },
  "configurations": {
    "Debug this file": {
      "adapter": "pyking",
      "filetypes": ["pyking"],
      "configuration": { "request": "launch", "program": "${file}" }
    }
  }
}
```

`:call vimspector#Launch()` starts debugging, and
`:call vimspector#ToggleBreakpoint()` sets a breakpoint.

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

### Debugging

With [dape](https://github.com/svaante/dape), from GNU ELPA:

```elisp
(with-eval-after-load 'dape
  (add-to-list 'dape-configs
               '(pyking modes (pyking-mode)
                        command "pyk" command-args ("dap")
                        :type "pyking" :request "launch"
                        :program dape-buffer-default)))
```

`M-x dape` then `pyking` debugs the file in the buffer, and `M-x
dape-breakpoint-toggle` sets a breakpoint.

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
    - match: '"(\\.|[^"\\])*"'
      scope: string.quoted.double.pyking
    - match: '''(\\.|[^''\\])'''
      scope: constant.character.pyking
    - match: '\b(for|in|if|while|loop|break|continue|then|else|var|def|return|match|case|public|implicit|import|from|as)\b'
      scope: keyword.control.pyking
    - match: '\b(Int|Float|String|Char|Bool)\b'
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

### Debugging

The [Debugger](https://packagecontrol.io/packages/Debugger) package
starts only the debug adapters it ships with, and has no setting to
start another, so `pyk dap` cannot be used from Sublime Text yet. Debug
in another editor here, or in the playground's Debug tab.

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

### Debugging

LSP4IJ also starts debug adapters. In **Run > Edit Configurations...**,
add a **Debug Adapter Protocol** configuration:

- **Server** tab: command `pyk dap`.
- **Mappings** tab, **File name patterns**: `*.pyk`, so breakpoints can
  be set in Pyking files.
- **Configuration** tab: the file to debug, debug mode **Launch**, and
  as the DAP parameters:

```json
{ "type": "pyking", "request": "launch", "program": "${file}" }
```

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

### Debugging

Helix's debugger is set per language, in the same `[[language]]`
block:

```toml
[language.debugger]
name = "pyk dap"
transport = "stdio"
command = "pyk"
args = ["dap"]

[[language.debugger.templates]]
name = "launch"
request = "launch"
completion = [ { name = "program", completion = "filename" } ]
args = { program = "{0}" }
```

`:debug-start launch` asks for the file and starts debugging, and the
debug menu sets breakpoints. Helix's debugger is experimental.

## When it does not work

- Run `pyk --version` in a terminal. If it fails, `pyk` is not on the
  `PATH` the editor sees; give the editor the full path instead.
- Add `--log FILE` to the command, for example `pyk lsp --log
  /tmp/pyk-lsp.log`, open a `.pyk` file, and read the log. If the file
  is empty, the editor did not start the server. `pyk dap --log FILE`
  does the same for the debugger.
