# The Pyking language server -- a design in three steps

`pyk lsp` is a language server: an editor starts it, and the two talk
the Language Server Protocol (LSP) as JSON-RPC over the server's
standard input and output. This page says what the server is made of,
what each of three steps adds, and how it is tested and shipped. Step 1
is built, and so are the parts of steps 2 and 3 marked built below; the
rest is the plan. It replaces the LSP part of
[plan-eval-lsp.md](plan-eval-lsp.md) (section 8), which assumed a
Python compiler.

## What it is made of

- **`src/lsp.ml`** -- the server itself, in the library and so free of
  `unix`: a state (the open documents, the settings, what each check
  found) and one function from a message received to the messages to
  send. It runs the compiler's own front end -- `Module.load`,
  `Typesystem.type_check`, `Analyses.analyze_mutability` -- and reads
  its answers out of what they produce, so there is no second parser,
  scope or type checker to drift from the compiler's.
- **`src/json.ml`** -- JSON read and written, which the server needs and
  the standard library does not have.
- **`pyk lsp`** -- the transport, in `src/pyk.ml`: messages framed by
  `Content-Length` on stdin and stdout, and the debounce (below). The
  only part that needs `unix`.
- **The browser** -- `src/web/pyking_web.ml` registers the same server
  as `pykLsp(message)` in `share/pyking.js`. The playground's worker
  speaks LSP to it over `postMessage`, and its editor, Monaco, is the
  client. The playground and every editor get the same answers from the
  same code.

Nothing needs to be installed: `pyk` is one native executable, and the
server is part of it.

### Options

```
pyk lsp [--stdio] [-L DIR]... [--log FILE] [-W...]
```

- `--stdio` -- talk over standard input and output. It is the only
  transport and the default; the flag is accepted because some clients
  (VS Code's among them) always pass it.
- `-L DIR` / `--lib-path DIR`, and `$PYKING_LIB_PATH` -- where libraries
  are looked for, as for `pyk`. The editor can add more (below).
- `--log FILE` -- every message in and out, and any internal error, is
  appended to FILE. For debugging an editor's setup: standard output
  carries nothing but the protocol, and standard error is often hidden.
- `-W<name>`, `-Wall`, `-Werror`, ... -- which warnings are reported
  until an editor's `warnings` setting says otherwise (see
  docs/warnings.md).

Settings an editor may send, in `initializationOptions` or as the
`pyking` section of `workspace/didChangeConfiguration`:

| setting | default | meaning |
|---|---|---|
| `libPath` | `[]` | more library directories, searched after `-L` |
| `diagnostics` | `"change"` | `"change"`: check as you type, once typing pauses; `"save"`: check only on open and save |
| `warnings` | `[]` | which warnings are reported, as -W flags applied to the defaults: a list (`["-Wall", "-Werror=unused-function"]`) or one string of them. Each time it is sent it replaces what was sent before; a flag naming no warning is passed over |

Where a document's check gets through, its warnings are its
diagnostics: severity 2, or 1 for one a `-Werror` made an error, with
the flag (`-Wunused-binding`) as the code and the `Unnecessary` tag, so
an editor fades the name. A code action on one puts `_` in front of the
name, which no warning reports. Where the check stops at an error, that
error is the only diagnostic.

### Positions

The compiler's `Lexer.info` counts rows from 1 and columns from 0 in
bytes; LSP counts lines from 0 and columns from 0 in UTF-16 code units.
`Lsp` converts in one place, both ways, with the line's text at hand,
so a line holding `é` or an emoji is right on both sides.

### One program per document

A document is checked as a program: `Module.load` from that file, with
the library path above, reading every file from the editor's open
buffers where it has one and from the disk otherwise. So an unsaved
change to a module is seen by every file that imports it. What a check
found -- the modules, their statements, the types -- is kept per
document and is what hover, definition, outline and completion read. A
document that does not parse keeps the last check that did, so the
outline and completion keep working while a line is half typed.

### Debouncing

Checking on every keystroke would check a program a dozen times a
second. A change only marks the document as due. The transport checks
due documents once no message has arrived for 200 ms; the browser does
the same with a timer. `"diagnostics": "save"` does not mark on change.

## Step 1 -- basic (built)

| capability | answered by |
|---|---|
| `textDocument/publishDiagnostics` | the first error any stage of the front end raises: lexing, parsing, the module system, names, types, mutability. An error in an imported module is reported at the import that reaches it, saying where it is, and in that module's own document where it is open |
| `textDocument/hover` | the type the checker recorded (`tmap`) for the smallest expression, binding, parameter or definition under the cursor, printed as Pyking; for a name, the `##` comment above its definition. Inside a top-level `def` with nothing to show, a note: nothing calls the function, so its types are not inferred, or the program has a type error |
| `textDocument/definition` | where a name is bound: in the file, in a module it imports, in the standard library. Builtins have none |
| `textDocument/documentSymbol` | the `def`s (with their nested ones), the top-level bindings and the imports |
| `textDocument/completion` | keywords, builtins, the names in scope where the cursor is, and after `m.` the names module `m` exports, with their types, and its submodules; after `m.sub.` that submodule's; after `import` or `from`, only modules: the standard library's, those in the library directories and beside the document (read through `list_dir`, which in the browser is the page's `pykListDir` where it has one), and those the program reaches |

The protocol: `initialize`, `initialized`, `shutdown`, `exit`,
`textDocument/didOpen`, `didChange` (full text), `didSave`, `didClose`,
`workspace/didChangeConfiguration`, `$/cancelRequest` (accepted;
requests are answered in order, so there is nothing to cancel), and
`MethodNotFound` for any other request. Notifications it does not know
are ignored, as the protocol asks.

One diagnostic per file: every stage raises on its first error, so the
front end stops there.

## Step 2 -- the everyday features

- **More than one diagnostic.** Parser error recovery (resynchronise at
  the next line at the block's indentation) and a checker that records
  an error and goes on with the binding's type unknown. This is the
  largest piece, and the one most worth having; it changes
  `parser.ml` and `typesystem.ml`, not just the server.
- **References, document highlight and rename** (built), from the same
  resolution go-to-definition uses (`scopes.ml`), across every module
  of the program. Rename refuses a new name that would mean something
  else where the old one is written, and a name a library defines.
- **Signature help** (built) from the callee's definition and its `##`
  comment, read from the text of the call, which seldom parses while it
  is typed; a named argument marks its parameter, and a constructor's
  fields are its parameters.
- **Inlay hints** (built, then removed): the inferred types written
  into the text read as code that is not there. Hover shows them.
- **Semantic tokens** (built), so a variable, a `var`, a parameter, a
  function, a module, a type, a constructor and a field are coloured
  apart.
- **Folding ranges** (built): blocks, comment runs, the imports.
- **Completion that knows the type**: fields after a qualified name are
  already there; add named arguments in a call and snippets for `def`,
  `match` and `loop`.
- **The notebook and the website's cells move to Monaco**, with
  diagnostics and hover in every cell.
- **A Zed extension**, and the VS Code extension published to the VS
  Code Marketplace and to Open VSX, which Cursor reads.

## Step 3 -- the rest

- **Formatting.** `pprint_program` prints the AST, and the lexer drops
  comments, so formatting would delete them. The lexer first records
  comments as trivia with their `info`, and the printer puts them back.
- **Code actions**: built are the quick fixes for `+`/`++`, a
  misspelt name and an annotation that disagrees with its value; still
  planned are annotating a binding or a function with its inferred
  type, adding a missing `else`, and importing a name from a library
  that exports it.
- **Workspace symbols** over every `.pyk` under the workspace folders,
  and **call hierarchy**.
- **Incremental sync** (`didChange` with ranges), and checking only the
  modules a change can reach.
- **Running and debugging**: code lenses that run a program with `pyk`.
  The DAP server, `pyk dap`, is built (`docs/debugging.md`).

## Editors

LSP is what lets one server serve every editor. What each needs:

| editor | what it needs |
|---|---|
| VS Code, Cursor | the extension in `tools/editors/vscode/`, a `.vsix` attached to every release: it says `.pyk` is Pyking, highlights it, and starts `pyk lsp` |
| Neovim | `vim.lsp.config` / `nvim-lspconfig` naming `pyk lsp` for the `pyking` filetype |
| Vim | `vim-lsp` or `coc.nvim`, the same command |
| Emacs | `tools/emacs/pyking-mode.el` registers `pyk lsp` with eglot, built into Emacs 29 |
| Sublime Text | the LSP package, a client entry for `pyk lsp` |
| Zed | step 2's extension; until then none |
| PyCharm and other JetBrains IDEs | the LSP4IJ plugin, with a server definition for `pyk lsp` |

The website's "Editors" page has each one's configuration.

## Testing

`tests/test_lsp.py` is a suite of `make test` of its own, in four
parts:

1. **Sessions.** `tests/lsp/<name>.lsp` is a script -- open a document,
   change it, ask for a hover at a line and column, and so on -- run
   against `pyk lsp` over stdio, and every message the server sends is
   compared with `tests/lsp/<name>.out`. One script per capability, one
   for the protocol's own edges (initialize twice, a request before
   initialize, unknown methods, malformed JSON, shutdown then exit), and
   one with non-ASCII text, where UTF-16 positions are pinned. `--update`
   rewrites the `.out` files.
2. **The browser.** The same scripts through `pykLsp` in
   `share/pyking.js` under node must give the same messages.
3. **The playground.** Where a Chromium is found, the playground is
   driven: an error is underlined, a hover shows a type, completion
   offers a name. Reported as skipped otherwise.
4. **The editors' configuration.** The VS Code extension's
   `package.json` names `pyk lsp` and the `.pyk` extension, the Emacs
   mode registers with eglot in `emacs --batch`, and every snippet on the
   website names `pyk lsp`.

## Packaging

The server is inside `pyk`, so every package already has it. What
`make packaging` adds is the `.vsix`, built from `tools/editors/vscode/`
with `npm` and `vsce` on the build machine, and attached to the release
by `make release`.
