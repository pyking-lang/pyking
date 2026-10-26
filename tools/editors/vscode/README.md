# Pyking for VS Code and Cursor

Support for the Pyking language in VS Code and Cursor:

- `.pyk` files are Pyking, highlighted, with `#` comments, bracket
  pairs and indentation after a line ending in `:`;
- the Pyking language server, `pyk lsp`, which is part of `pyk`, gives
  diagnostics, hover, go to definition, the outline, completion,
  signature help, references, rename, folding, semantic
  highlighting and quick fixes;
- the Pyking debugger, `pyk dap`, also part of `pyk`: **Run > Start
  Debugging** on a `.pyk` file stops at its breakpoints, steps, and
  shows the calls in progress and their variables.

The extension contains neither the server nor the debugger. It needs `pyk` installed and
on the `PATH`, or named by `pyking.server.path`.

## Settings

| setting | default | meaning |
|---|---|---|
| `pyking.server.path` | `pyk` | the `pyk` executable |
| `pyking.server.args` | `["lsp"]` | its arguments; `--stdio` is added after them |
| `pyking.libPath` | `[]` | more library directories, searched after the server's `-L` flags |
| `pyking.diagnostics` | `change` | `change`: check as you type; `save`: check on open and save |
| `pyking.trace.server` | `off` | `messages` or `verbose` shows the protocol in the Pyking output channel |
| `pyking.debugger.args` | `["dap"]` | what `pyking.server.path` is started with as the debugger |

To see what the server receives and sends, set `pyking.server.args` to
`["lsp", "--log", "/tmp/pyk-lsp.log"]`. The command **Pyking: Restart
Language Server** restarts it.

## Debugging

With a `.pyk` file open, **Run > Start Debugging** debugs it with no
`launch.json`. A `launch.json` configuration of type `pyking` can say
more: `program`, `args`, `stdin` (a file the program reads), `cwd`,
`stopOnEntry`, `justMyCode` (step over library code, on by default),
`libPath` and `release`. `["dap", "--log", "/tmp/pyk-dap.log"]` in
`pyking.debugger.args` logs the debugger's messages.

## Installing

Every release has the extension attached as `pyking-<version>.vsix`, at
https://github.com/pyking-lang/pyking-releases/releases. Install it from
the command line:

```
code --install-extension pyking-<version>.vsix
cursor --install-extension pyking-<version>.vsix
```

or in the Extensions view: the `...` menu, **Install from VSIX...**.

## Building

`make vsix` builds `pyking-<version>.vsix`, with the version taken from
the repository's `VERSION` file. It needs `node` 20 or later and `npm`.

```
make vsix                  # writes ./pyking-<version>.vsix
make vsix OUT=/some/dir    # writes /some/dir/pyking-<version>.vsix
```

The build is staged in `build/`, which it removes when it is done;
`npm ci` installs the dependencies pinned in `package-lock.json` there,
and `vsce` packages the extension with `vscode-languageclient` inside
it.
