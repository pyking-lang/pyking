# Pyking Interpreter Design Plan

## Goals

Build Pyking as a single language platform with:

- a CLI interpreter: `pyk myfile.pyk`
- a REPL: `pyk repl`
- shared implementation between interpreter and compiler to avoid duplication
- step-by-step debugging support for the playground
- comprehensive LSP and DAP support
- good editor integration across VS Code, Emacs, Vim, Sublime, Zed, PyCharm, and others

The central design principle is: **one language core, many frontends**.

---

## Recommended architecture

Split the project into four major layers:

1. **Language core**
2. **Runtime and execution**
3. **Developer tooling**
4. **Distribution and editor integration**

Each layer should have narrow interfaces so the interpreter, REPL, debugger, LSP, and DAP all reuse the same analysis and execution machinery.

---

## 1. Language core

This is the heart of the project and should contain everything that understands Pyking syntax and semantics.

### Responsibilities

- lexing
- parsing
- AST construction
- name resolution
- type checking, if Pyking has types
- scope analysis
- diagnostics
- source mapping
- incremental parsing support later, if needed

### Suggested submodules

- `lexer/`
- `parser/`
- `ast/`
- `semantics/`
- `diagnostics/`
- `source/`
- `symbol/`

### Design rules

- Keep AST nodes immutable.
- Attach source spans to every meaningful node.
- Do not mix runtime behavior into AST classes.
- Put semantic rules in dedicated analysis passes.
- Make diagnostics first-class, structured objects, not just strings.

### Compiler reuse strategy

If you already have a compiler, the interpreter should reuse as much of the compiler pipeline as possible:

- parser shared by both
- AST shared by both
- semantic analysis shared by both
- possibly IR shared by both

The main difference should be in the final execution backend:

- compiler backend emits bytecode / machine code / target output
- interpreter backend executes the same analyzed program directly or via IR

This avoids a “second language implementation” problem.

---

## 2. Runtime and execution

This layer executes analyzed Pyking programs.

### Recommended approach

Use an intermediate representation between semantic analysis and execution.

#### Option A: AST interpreter
Directly execute the AST.

- simplest to build initially
- fast to prototype
- good for early REPL support
- easier debugging hooks

Downside: can become awkward as the language grows.

#### Option B: bytecode or custom IR interpreter
Lower AST to a simpler IR, then interpret that IR.

- better reuse between compiler and interpreter
- easier to optimize later
- easier to add step debugging
- cleaner boundary between language and runtime

**Recommendation:** use a shared IR if the compiler already exists or is planned to exist. If the compiler does not yet exist, start with AST execution but design the interface so IR can be inserted later without rewriting tooling.

### Runtime components

- `value/` for runtime values
- `environment/` for scopes and bindings
- `call/` for function invocation
- `controlflow/` for return, break, continue, exceptions
- `heap/` or `gc/` if needed
- `stdlib/` for built-in functions and modules

### Execution engine API

Create a narrow interface like:

- `runFile(path)`
- `runProgram(source)`
- `runExpression(expr)`
- `step()`
- `setBreakpoint()`
- `inspectFrame()`

This same execution engine should be used by:

- CLI interpreter
- REPL
- debugger
- playground
- DAP server

---

## 3. Shared session model

Introduce a shared notion of a **session**.

A session is the unit that owns:

- source files or snippets
- environment state
- loaded modules
- diagnostics
- breakpoints
- current stack frames
- REPL history
- debug state

### Why this matters

The REPL, the online playground, and the debugger all need persistent state across multiple user actions. A session model keeps them consistent and prevents each frontend from inventing its own runtime state.

### Session types

- **script session**: run a file once and exit
- **REPL session**: persistent interactive state
- **debug session**: persistent state plus stepping, breakpoints, and stack inspection
- **language-server session**: parse and analyze many open documents incrementally

All of them should use the same core parsing and analysis APIs.

---

## 4. CLI design

### CLI commands

- `pyk myfile.pyk`
- `pyk repl`
- `pyk debug myfile.pyk`
- `pyk fmt`
- `pyk check`
- `pyk lsp`
- `pyk dap`

Some of these may not exist immediately, but the CLI should be designed as a command router from day one.

### CLI structure

- thin shell entrypoint
- command parser
- command dispatcher
- shared execution backend

### Why keep it thin

The CLI should not contain language logic. It should only:

- parse flags and command names
- initialize a session
- invoke the shared runtime/tooling APIs
- render output and exit codes

This makes the CLI easy to maintain and prevents duplication with the REPL and debugger.

---

## 5. REPL design

The REPL should feel like a first-class environment, not just a loop around `eval`.

### REPL requirements

- multiline input
- persistent variable state
- history
- tab completion
- useful prompts
- escape commands for inspection and control
- clear error messages
- optional pretty-printing of results

### Escape command examples

- `:help`
- `:vars`
- `:type x`
- `:ast <expr>`
- `:stack`
- `:break file:line`
- `:continue`
- `:reset`
- `:load file.pyk`

### REPL architecture

The REPL should have three layers:

1. **line editor**  
   handles input, history, completion

2. **command parser**  
   distinguishes between Pyking code and escape commands

3. **session executor**  
   sends statements to the shared execution engine

### REPL reuse

Use the same evaluator and environment as:

- script execution
- debugger
- playground

The REPL should probably compile each input chunk the same way as a file, but in an interactive session mode.

---

## 6. Debugging architecture

You want both local step-by-step debugging and online playground debugging.

### Core debugging capabilities

- set and clear breakpoints
- step into
- step over
- step out
- continue
- pause
- inspect variables
- inspect call stack
- inspect current source location
- watch expressions, if feasible
- exception breakpoints

### Best design choice

Build a **debuggable execution engine** as part of the runtime rather than bolting debugging onto the CLI.

The execution engine should emit events such as:

- `ProgramStarted`
- `LineReached`
- `BreakpointHit`
- `StepCompleted`
- `FunctionEntered`
- `FunctionExited`
- `ExceptionThrown`
- `ProgramFinished`

This event stream becomes the basis for:

- REPL debug mode
- playground debug mode
- DAP implementation

### Step execution implementation

Support debugging best by executing programs in small units:

- AST node boundaries, or
- IR instruction boundaries

If you use a shared IR, instruction-level stepping becomes much easier and more precise.

### Online playground support

For the playground, expose the debugger through a backend service that can:

- create sessions
- accept code updates
- run stepping commands
- return current source position
- return stack and variable data in JSON

This keeps the browser UI thin and the server authoritative.

---

## 7. LSP design

LSP should be backed by the same core analysis engine used by the compiler and CLI.

### LSP features to target

- diagnostics
- hover
- go to definition
- find references
- rename
- document symbols
- workspace symbols
- completion
- signature help
- formatting
- code actions
- semantic tokens
- inlay hints, if desired later

### Important design decision

The LSP server should not parse or analyze Pyking independently. It should call the shared language core.

### Document model

Maintain a workspace model with:

- open files
- their latest text versions
- parse trees / ASTs
- symbol tables
- diagnostics cache
- dependency graph

### Incremental design

Even if you start with full re-analysis on each change, design the API so incremental updates can be added later:

- `updateDocument(uri, text, version)`
- `closeDocument(uri)`
- `analyzeDocument(uri)`
- `resolveSymbol(position)`

### LSP server shape

Use a single server process that speaks JSON-RPC. It should be separate from the language core, but the core should be importable as a library.

---

## 8. DAP design

DAP is for interactive debugging in editors and IDEs.

### DAP features to target

- launch
- attach
- setBreakpoints
- configurationDone
- continue
- next
- stepIn
- stepOut
- pause
- stackTrace
- scopes
- variables
- evaluate
- setVariable
- threads
- terminated event

### DAP server shape

Like the LSP server, the DAP server should be thin and delegate to the shared debugger runtime.

### Debugger state model

Maintain:

- current execution state
- stack frames
- scope objects
- breakpoints
- execution thread state
- paused/terminated status

### Why DAP matters

DAP is the standard way to integrate debugging into editors like VS Code and increasingly other IDEs. A clean DAP server gives broad compatibility with minimal editor-specific code.

---

## 9. Editor integration strategy

To support many editors, separate the system into:

1. **core language engine**
2. **LSP server**
3. **DAP server**
4. **small editor-specific adapters**

### Recommended editor distribution model

- one installable language package or binary
- one LSP executable
- one DAP executable or adapter
- editor plugins that just point to these executables

This is much easier than embedding the language engine separately into every plugin.

### Editor support suggestions

- **VS Code**: use LSP extension + DAP extension
- **Emacs**: use lsp-mode / eglot with your LSP server; optional dap-mode integration
- **Vim/Neovim**: use built-in LSP clients; optional DAP plugins
- **Sublime**: use LSP package + DAP package if available
- **Zed**: use its LSP integration; debugging support if/when available through its ecosystem
- **PyCharm / JetBrains**: often best via plugin integration with LSP/DAP-style endpoints or a custom plugin that launches them

### Installation model

To make setup easy:

- provide downloadable binaries
- provide package-manager distribution
- provide editor plugin configuration templates
- auto-detect the executable path when possible

---

## 10. What language should LSP/DAP servers be written in?

### Recommendation

Write the LSP and DAP servers in the **same implementation language as the compiler/interpreter core**, or in a language that can directly call that core as a library.

The important point is not JavaScript specifically; it is **thin server wrappers around a shared core library**.

### Practical choice options

#### Option 1: Same language as core, with native JSON-RPC servers
Best if the core language is already suitable for tooling.

Pros:
- one codebase for semantic logic
- no FFI complexity
- easiest to keep behavior aligned

Cons:
- editor ecosystem may require packaging effort

#### Option 2: Core in one language, servers in TypeScript/JavaScript
Good if you want fast protocol development and easy editor-oriented packaging.

Pros:
- excellent JSON-RPC ecosystem
- easy to build VS Code extensions
- easy to publish npm-based adapters

Cons:
- risk of duplicating language logic unless the server calls the shared core library directly
- if the core is not callable from JS, you may end up with two implementations

#### Option 3: Core in Rust/Go, servers in TypeScript or native binaries
This is a strong practical setup.

- core library in Rust or Go
- LSP/DAP servers as native binaries or thin TypeScript shells
- editor plugins only act as launchers

### My recommendation

If you want modularity and efficiency, choose:

- **core engine in a compiled language** such as Rust or Go
- **LSP/DAP servers as thin JSON-RPC processes**
- **editor plugins in the ecosystem’s preferred format**

For VS Code specifically, a TypeScript extension is natural. But the actual language intelligence should still live in the shared core service, not in the extension.

### Key rule

Do not implement the language semantics separately in JavaScript for LSP or DAP. That would create duplication and drift.

---

## 11. Suggested repository layout

A monorepo makes sense.

```text
pyking/
  Cargo.toml or go.mod or workspace root
  README.md
  docs/
  crates/ or packages/
  core/
    lexer/
    parser/
    ast/
    semantics/
    ir/
    runtime/
    diagnostics/
    source/
  cli/
  repl/
  debugger/
  lsp-server/
  dap-server/
  playground-server/
  stdlib/
  tests/
  fixtures/
  editors/
    vscode/
    emacs/
    vim/
    sublime/
    zed/
    jetbrains/
```

### Alternative

If using a language with strong package management, split into separate packages:

- `pyking-core`
- `pyking-cli`
- `pyking-lsp`
- `pyking-dap`
- `pyking-playground`

This helps versioning and reuse.

---

## 12. Data flow overview

### Script execution

`CLI -> session -> parse -> analyze -> compile/interpret -> runtime`

### REPL

`REPL input -> command parser -> session -> parse/analyze/execute -> output`

### Debugger

`editor/playground -> DAP/debug API -> session -> step/inspect runtime`

### LSP

`editor -> LSP -> workspace model -> parse/analyze -> diagnostics/completions/etc.`

All roads should lead back to the same core language services.

---

## 13. Error handling and diagnostics

### Requirements

- precise source locations
- helpful messages
- recovery after syntax errors
- structured error codes
- distinguish parse errors, semantic errors, runtime errors

### Diagnostic object shape

Each diagnostic should include:

- code
- message
- severity
- file
- line/column range
- related notes
- optional help text

### Why this matters

LSP, CLI, REPL, debugger, and playground should all display the same diagnostics consistently.

---

## 14. Testing strategy

Use a layered test suite.

### Unit tests

- lexer
- parser
- semantic analysis
- runtime primitives
- debugger stepping
- diagnostics formatting

### Integration tests

- run scripts through CLI
- REPL command tests
- LSP request/response tests
- DAP request/response tests

### Golden tests

- source input
- expected AST
- expected diagnostics
- expected runtime output
- expected debug traces

### Editor integration tests

- smoke tests for VS Code extension
- launch LSP
- launch DAP
- verify basic editor features

---

## 15. Performance strategy

### Early stage

Focus on correctness and architecture first.

### Later stage optimizations

- incremental parsing
- incremental semantic analysis
- caching symbol tables
- memoizing module loading
- compiled IR
- lazy loading of stdlib modules
- avoiding unnecessary allocations in runtime values

### Debugger performance

Debugging requires more metadata, so keep a normal execution mode and a debug mode. Do not pay debugging overhead unless debugging is enabled.

---

## 16. Packaging and distribution

### Deliverables

- command-line executable `pyk`
- LSP server executable
- DAP server executable
- optional combined `pyk dev` launcher
- editor-specific plugins or config templates

### Packaging goals

- easy installation
- versioned releases
- cross-platform support
- no manual path wiring if possible

### Recommended approach

Ship a single distributable release bundle containing:

- `pyk`
- `pyk-lsp`
- `pyk-dap`

Then editor plugins can just reference those binaries.

---

## 17. Recommended implementation roadmap

### Phase 1: Core language foundation

- lexer
- parser
- AST
- source locations
- diagnostics
- minimal interpreter backend
- unit tests

### Phase 2: CLI and REPL

- `pyk myfile.pyk`
- `pyk repl`
- shared session API
- basic inspection commands

### Phase 3: Shared runtime and IR

- add or formalize IR
- move execution to shared runtime
- unify script and REPL execution semantics

### Phase 4: Debugger engine

- breakpoints
- stack inspection
- step execution
- event stream
- debug mode in CLI and REPL

### Phase 5: DAP server

- launch/attach
- stepping
- variables/scopes/stack
- editor debugging integration

### Phase 6: LSP server

- diagnostics
- hover
- completion
- go to definition
- references
- rename
- symbols
- semantic tokens

### Phase 7: Playground support

- remote session management
- debug stepping API
- source and state synchronization
- browser UI hooks

### Phase 8: Editor packages

- VS Code extension
- Emacs instructions
- Vim/Neovim setup
- Sublime setup
- Zed setup
- JetBrains integration strategy

---

## 18. Final architectural recommendation

The cleanest design is:

- one **shared language core**
- one **shared execution/runtime engine**
- one **debuggable session model**
- one **LSP server**
- one **DAP server**
- thin CLI/REPL/playground frontends

The LSP and DAP should be implemented as thin protocol servers in whichever language best supports packaging and JSON-RPC, but they should depend on the same core engine that powers the interpreter and compiler. That is the main safeguard against duplication.

If you already have a compiler, the best long-term solution is to factor out a shared AST/IR + semantic core and make both the compiler and interpreter consume it.

---

## Practical recommendation in one sentence

Build Pyking around a shared analyzed IR, expose that through a reusable runtime session API, and put CLI, REPL, debugger, LSP, and DAP on top as thin adapters.

