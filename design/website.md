# The website's documentation: a new structure

This is a plan. It changes no pages. It says which sections and pages
the website should have, in what order, with what names, and what each
page holds. Once it is agreed, the pages are written from it.

## What there is today

The header has five sections: **Install**, **Getting started**,
**Documentation**, **Libraries** and **Playground**
(`tools/site/src/sections.mjs`). The pages are written by hand in
`sitesrc/` and staged by `tools/help/help.py`. The same help is served
by `pyk pykhelp` and shown in the playground's Help tab.

| Section | Pages now | Source |
|---|---|---|
| Install | Install | `sitesrc/install.md` |
| Getting started | Language overview; Styling tinyweb | `sitesrc/getstarted/` |
| Documentation | Language reference; Editors; Code on slides; tinyweb in other languages | `PYKING.md`, `sitesrc/documentation/`, `tools/site/tinywebdoc.py` |
| Libraries | one page per module | generated from `lib/` |
| Playground | the playground | `tools/site/src/pages/playground.astro` |

Problems this plan fixes:

- The language reference is one 6,700-line page. It mixes the meaning
  of the language with its grammar, with type-checker internals, and
  with notes on what the bootstrap implementation accepts. It is hard
  to look things up in.
- There is no page for the playground, the notebook, debugging, the
  command line, the REPL or the compiler targets. These are documented
  only in `docs/` and `tools/*/README.md`, which are written for people
  working on Pyking, not for people using it.
- Getting started has a single tour page. It does not show the `use`
  modes, and it does not say how to set Pyking up.
- "Styling tinyweb" sits in Getting started, but it is reference
  material for one library.

## The new structure at a glance

The header keeps its five sections, in the same order. Only Getting
started and Documentation change.

```
Install                       (unchanged; per-platform details)
Getting started
  1. Pyking in 20 minutes
  2. Setting up Pyking
  3. Debugging
Documentation
  Tools
    1. Editors                (kept)
    2. Playground             (new)
    3. Notebook               (new)
    4. Command line           (new)
    5. REPL                   (new)
    6. Compiler targets       (new)
    7. Code on slides         (kept, moved here)
  Language
    8.  Language reference    (rewritten; a group of pages, see below)
    9.  Pyking vs. other languages   (new; Python, JavaScript, C,
                                      Java, OCaml)
    10. Grammar               (new)
  tinyweb
    11. tinyweb in other languages   (kept, regrouped: C, Java,
                                      JavaScript, OCaml, Python)
    12. Styling tinyweb       (moved from Getting started)
Libraries                     (unchanged; generated from lib/)
Playground                    (unchanged)
```

The Tools / Language / tinyweb grouping above is the order of the pages,
not a level of the menu: the Documentation sidebar has two levels and
no more. Every page above is a main entry, in bold and clickable; the
Language reference's pages (8.1–8.16) and tinyweb's pages for other
languages are sub-entries, listed smaller under their main page while
it or one of them is open. A main page with no sub-pages lists its `##`
headings under it while it is open; a sub-page's headings are not in
the menu. The section's landing page (the header link) moves
from `/documentation/language/` to the first page of the Language
reference. Users come to Documentation mostly to look things up in the
language.

**Moved:** "Styling tinyweb" leaves Getting started for Documentation's
tinyweb group (`sitesrc/documentation/tinyweb-styles.md`), beside
tinyweb's pages for other languages: the library pages are generated
from `lib/`, so it stays a page of its own. The old address redirects.

**Replaced:** "Language overview" (`sitesrc/getstarted/overview.md`) is
replaced by "Pyking in 20 minutes". Its examples are reused there.

---

## Getting started

Three pages, read in order. Every example is a runnable ` ```pyking `
cell. A cell meant to fail uses ` ```pyking error `.

### 1. Pyking in 20 minutes

`sitesrc/getstarted/pyking-in-20-minutes.md`. This is the landing page
of the section. It is a fast tour for someone who knows some Python. It
should be dense, with short prose and many small examples, and it ends
with links to where each topic is covered in full.

**What Pyking is** (one screen, mostly bullets)
- A small, statically typed, Python-like language: Python's syntax, but
  lexical scoping with every block a scope, and immutable by default.
- Type inference: annotations are optional, and every program is
  checked before it runs.
- One program, many targets: run it with the interpreter (`pyk
  prog.pyk`) or compile it to Python, JavaScript (node, web page), C
  (with or without a GC), Java or OCaml. Give a one-line table of the
  families and link to Compiler targets.
- Tools: REPL, playground in the browser (nothing runs on a server),
  notebooks for teaching, a language server and a debugger for the
  usual editors, and standard libraries, including `tinyweb` for
  graphics, games and web pages.
- A small "where to try it" box: the Playground link, and `pyk
  playground` locally.

**Hello, world, and running a program**
- `print`, string concatenation with `+`, `string(n)`.
- `pyk hello.pyk`, then `pyk compile hello.pyk --target python --run`.
  Show this as a shell block, not a cell.

**Three modes, chosen with `use`**
- Explain the idea: a module is functional and immutable unless its
  first lines say otherwise. A construct from a mode that is not turned
  on is a syntax error that names the `use` line it needs. `use` is per
  module, and importing a module does not turn its modes on.
- **Immutable (the default, no `use` line).** A small example: `=`
  bindings, recursion, a list comprehension, `match` on a datatype.
  Show that `x = 1` then `x = 2` is a new binding, not an update, with
  a nested block to show scoping.
- **Mutable (`use mutation`).** `var`/`:=`, `+=`, a `while` loop, an
  `Array`/`DynArray`, a `MutMap` word count, and a `mutable struct`.
  Also one `pyking error` cell: `:=` on an `=` binding. Mention `use
  mutation, pointers` in one sentence with a link.
- **Objects (`use objects`).** A tiny `interface Shape` with two
  classes, dynamic dispatch, and `self`. Say it follows Java's semantics
  in Python's spelling.

**Language tour** (one short example each, two or three lines of prose)
- Values and types: `Int`, `Float`, `String`, `Char`, `Bool`
  (`true`/`false`), no implicit conversions, and `float(n)`.
- Functions: `def`, a one-line body, default and named arguments,
  annotations, and inference of a polymorphic function (`twice`).
- Lambdas (`lam x. x + 1`), `if … then … else` expressions, and `let`.
- Lists, tuples, comprehensions, `fmap`/`filter`/`foldl`.
- Datatypes and structs, and `match` with or-patterns, guards and `as`.
- `Option` and `Result` instead of `None` and exceptions.
- The `loop` loop.
- Modules: `import`, `from … import`, and `public`.
- Overloading and implicits: one example each, flagged as advanced.

**Input and output**
- Reading standard input with the `io` library (read lines, sum
  numbers), and `sys.args()`.
- `print` versus `debug`: `debug` writes to stderr, and `--release`
  removes it.

**A first tinyweb program**
- A runnable cell that draws something and reacts to a click or a key.
- Mention that it runs in the playground's Web output tab and with
  `pyk compile --target web --run`.

**Where next**
- Links to Setting up Pyking, the Language reference, Libraries and the
  Playground.

### 2. Setting up Pyking

`sitesrc/getstarted/setting-up.md`.

**Installing Pyking**
- Supported platforms in a table: macOS (Homebrew cask), Linux and WSL
  (install script), Nix, and Docker (image tags `latest`/`full`). Give
  the one command per platform, and link to the Install section for
  details and upgrades.
- Check the installation: `pyk --version`, then `pyk example`.
- **What you can do once it is installed**, as a short table of
  commands with one line each:
  - `pyk prog.pyk`: run with the interpreter
  - `pyk repl`: the REPL
  - `pyk compile prog.pyk --target T [--run]`: compile, and run
  - `pyk playground`: the playground, served locally
  - `pyk notebook book.md`: a notebook
  - `pyk serve dir`: serve a compiled web page
  - `pyk example [NAME]`: the bundled examples
  - `pyk pykhelp`: this documentation, offline
  - `pyk highlight`: code for slides
  - `pyk lsp` / `pyk dap`: for editors
- What else each target needs to *run*: `python3`, `node`, a C compiler
  plus bdwgc (`libgc-dev` / `bdw-gc`) for `c-gc`, a JDK, `ocamlopt`.
  Compiling alone needs none of them.

**Editor support**
- A summary table of editors (VS Code, Cursor, Neovim, Vim, Emacs,
  Sublime Text, Zed, PyCharm/IntelliJ, Helix) with three columns:
  highlighting, language server, debugger. Link each row to its section
  on the Editors page.
- **What the language server is.** LSP is a standard protocol: `pyk
  lsp` is one program that every editor talks to, so every editor gets
  the same features. List the features briefly: diagnostics, hover
  with types, go to definition, completion, signature help, rename,
  references, inlay hints with inferred types, quick fixes, outline,
  folding and semantic highlighting.
- Say that nothing else needs installing, because the server is part of
  `pyk`.
- Link to Editors for setup.

### 3. Debugging

`sitesrc/getstarted/debugging.md`. This covers three ways to debug,
from simplest to fullest.

**`debug` statements**
- `debug(...)` is `print` for diagnostics: same arguments, but it
  writes to standard error. It may be used where `print` may not (it
  will be allowed in pure functions).
- `--release` removes every `debug` call, arguments and all. Show an
  example, and show that an argument's side effects disappear too.
- Where `debug` output appears: the terminal, the playground's output
  (marked apart), the notebook, and the editor's debug console.

**The debugger in the playground**
- The Debug tab: start, breakpoints in the gutter, continue, step over,
  step in and step out, pause and stop.
- The Variables view (scopes, structured values) and the call stack.
- Evaluating an expression where the program stopped: it is
  type-checked against the names in scope, and only a `var` can be
  assigned.
- Conditional breakpoints, hit counts and logpoints.
- Debugging tinyweb callbacks: a breakpoint in an event handler stops
  when the event arrives.
- Two or three screenshots.

**The debugger in an editor (DAP)**
- What DAP is: one adapter, `pyk dap`, that editors start. It shares
  its core with the playground's debugger, so stepping behaves the same
  in both.
- It always debugs with the interpreter, never a compiled target.
- The launch options as a table: `program`, `args`, `stdin`, `cwd`,
  `stopOnEntry`, `justMyCode`, `libPath`, `release`, `warnings`.
- Breakpoint kinds, the Runtime errors breakpoint, and where stdout and
  `debug` output go.
- A link to Editors for each editor's setup.

---

## Documentation

### Tools

#### 1. Editors (kept)

`sitesrc/documentation/editors.md`, kept as it is. Changes:
- Its opening list of LSP features is the full version of the summary
  in Setting up. Keep the two consistent.
- Move "The debugger" launch-option detail to the Debugging page and
  link to it from here, so it is written once.

#### 2. Playground (new)

`sitesrc/documentation/playground.md`. Every feature, with a screenshot
where it helps. Sources: `tools/playground/README.md`.

- **What it is**: the real compiler compiled to JavaScript, so nothing
  runs on a server. The website's copy, and `pyk playground` locally.
- **The layout**: editor on the left, tabs on the right, a draggable
  split, and the layout remembered between visits.
- **Writing code**: highlighting, errors underlined as you type, and
  the language server in the page (hover, completion, go to definition
  and the rest).
- **Examples**: the Examples menu, and where the examples come from.
- **Running**: ▶ Run with the interpreter, the Run output tab, standard
  input given to a run, and Stop.
- **Compiled code**: the Target list, Compile, running the compiled
  output, Copy and Download (with a Makefile per target).
- **Web output**: tinyweb programs in a browser-window frame.
- **REPL tab**: the REPL in the page, with its environment view.
- **Debug tab**: a short summary that links to Debugging.
- **Help tab**: this documentation, offline.
- **Sharing**: "Copy code as link" (the program is in the URL fragment
  and never reaches a server).
- **Copy for slides**: a summary that links to Code on slides.
- **Settings**: theme (light/dark), editor, font size, key bindings and
  layout.
- **Keyboard shortcuts**: a table.
- **Embedding the playground in another page**.
- **Limitations**: what it does not offer, for example external modules
  of a program's own.

#### 3. Notebook (new)

`sitesrc/documentation/notebook.md`. Source: `docs/notebook.md`,
rewritten for users. Every feature should have an example notebook
fragment shown as Markdown source, plus a screenshot of how it renders.

- **What a notebook is**: a Markdown file whose ` ```pyking ` blocks are
  runnable cells, served by `pyk` and run in the browser. It is meant
  for teaching and for exploring.
- **Running one**: the command table (`pyk notebook book.md`, `--mode
  teacher|student|test`, `--port`), and reloading when the file
  changes.
- **Prose**: Markdown, and math with KaTeX.
- **Cells**: each cell is a whole program (so it needs its own `use
  mutation`), a cell's input (stdin), what a cell prints, and tinyweb
  in a cell.
- **Assignments**: tasks and practices (solution, tests and hints),
  examples, and quizzes. Each gets a worked example.
- **Who is reading**: student and teacher mode, and what each shows.
- **Test mode**: checking a whole notebook from the command line, and
  using it in CI.
- **JSON form**: `--to-json`, `--to-markdown`, `--json-schema`, and
  when to use each.
- **Grading with `nbverify`**.
- **Notebooks on this website**: the site's own pages use the same
  cells.

#### 4. Command line (new)

`sitesrc/documentation/command-line.md`. Every `pyk` command, with its
flags. Source: `pyk --help` and `docs/pyk.md`.

- An overview table of commands: run, `repl`, `compile` (`c`),
  `notebook`, `playground`, `serve`, `example`, `pykhelp`,
  `highlight`, `lsp`, `dap`.
- One subsection per command: synopsis, flags and examples.
- Shared flags: `-L` (library path), `-W…` (warnings, `-Werror`),
  `--release`, `--use`, and program arguments.
- Where `pyk compile` writes (`build/`), `--stdout`, `--no-build` and
  `--run`.
- Exit codes and the shape of error messages.
- The library search path.

#### 5. REPL (new)

`sitesrc/documentation/repl.md`. Source: `docs/repl.md`, rewritten for
users.

- Starting it: `pyk repl`, `--use`, and in the playground.
- Entering code: one line or several, Shift+Return, and how a block
  ends.
- What it shows: a value with its type, and the environment.
- `use` in a session: it applies for the rest of the session.
- Imports in a session.
- Errors: an entry is checked whole before any of it runs, and an
  undefined name can be offered as "define it later".
- Meta-commands, as a table.
- Completion and history.

#### 6. Compiler targets (new)

`sitesrc/documentation/targets.md`. Source: `docs/targets.md` and
`docs/target_*.md` (the user-facing parts only).

- Families, versions and aliases (the table in `docs/targets.md`).
- All targets: what each writes, how to run it, and its language
  coverage (the C restrictions in particular).
- Choosing a target: a short guide.
- Per family, one subsection each (Python, node, web, iweb, C, C with
  GC, Java, OCaml): what the output looks like, what it needs to run,
  how tinyweb works there, and known differences.
- `--release` and tail calls per target.
- External modules: implementing a module in the target language.

#### 7. Code on slides (kept, moved)

`sitesrc/documentation/slides.md`, unchanged. It moves into the Tools
group.

### Language

#### 8. Language reference (rewritten)

This is the core of the plan. It is a **group of pages**, not one page,
so the sidebar works as a table of contents and each page is short
enough to scan. It describes **what programs mean**. It has no EBNF
and no lexical fine print, which go to Grammar, and no compiler
internals, which stay in `docs/`. It is written for lookup, not reading
start to finish.

Every page follows the same pattern:

- One paragraph: what the feature is for.
- **Mode badge**: *core* (always available), *`use mutation`*, *`use
  objects`* or *`use mutation, pointers`*.
- A **Python badge** when it differs from Python ("new in Pyking", "as
  Python", or "differs from Python: …").
- A short summary table of the forms, where there is more than one.
- Rules, as short paragraphs or bullets, each followed by a runnable
  example.
- At least one `pyking error` example for the most common mistake,
  showing the real error message.
- "See also" links.

Source: `PYKING.md`, reorganized. `PYKING.md` stays the single source
(see "How this is built" below).

The pages, in order, with their section headings:

**8.1 Overview**
- What Pyking is, in one paragraph.
- How to read this reference (badges, runnable examples).
- **New in Pyking**: the "differs from Python" list, compact, with each
  item linking to its page.
- Modes at a glance: a table of `use` features against the constructs
  each turns on.

**8.2 Programs, modes and `use`**
- A program and its modules (one file is one module).
- `use` lines: where they go, and combining them (`use mutation,
  objects`).
- The default: functional and immutable.
- `use mutation`: what it turns on (var, `:=`, compound assignment,
  arrays, DynArray, MutMap, mutable structs and `loop`'s mutable
  forms, to be checked).
- `use pointers`: requires `mutation`.
- `use objects`: classes and interfaces.
- `use` is per module, and is not inherited through imports.
- The error for a construct whose mode is off.

**8.3 Values and basic types**
- `Int` (range, literals in decimal, hex and binary, overflow
  behaviour)
- `Float` (IEEE binary64, literals, NaN and infinity)
- `Bool` (`true`/`false`)
- `Char` (one code point, single quotes)
- `String` (double quotes, escapes, Unicode, immutable)
- Unit `()`
- Conversions: `string`, `int`, `float`, `bool`, `char`, and the
  defaults they answer.
- No implicit conversion: `Int` and `Float` meet only through
  `float`/`int`.

**8.4 Operators and expressions**
- Arithmetic (`+ - * / % ^`, unary minus), and how they behave on `Int`
  and on `Float`.
- `+` as concatenation (strings and lists, one type per `+`).
- Comparison (no chaining), and equality on structured values.
- Boolean (`and`/`or`/`not`, `&&`/`||`/`!`, short-circuit).
- Bitwise (`& | xor ~ << >>`).
- Indexing and slicing (summary, linking to Collections).
- Precedence table, linking to Grammar for the full grammar.
- Evaluation order: left to right.
- `if … then … else` expressions.
- `let … in` expressions.
- Lambdas (`lam x. …`, tuple parameters, closures).

**8.5 Names, bindings and scope**
- Immutable bindings with `=`, and tuple destructuring.
- Every block is a scope.
- Shadowing: free for immutable names, with the one exception for
  `var`.
- `def` names are visible throughout their block (mutual recursion),
  and binding before use otherwise.
- Clashes that are errors (a binding and a function with one name,
  and so on).
- Qualified names (`m.f`).
- Warnings: unused names and shadowing `=` (linking to Warnings).

**8.6 Mutable state** *(use mutation)*
- `var` and `:=`; compound assignment (`+=`, …).
- Why `=` never mutates.
- Mutable variables captured by closures.
- Mutable structs: fields written in place, sharing.
- Pointers *(use mutation, pointers)*: `&x`, `*p`, `*p := v`, `Ptr(T)`;
  no null, no arithmetic.

**8.7 Functions**
- `def`: parameters, body, and a body on the header's line.
- Tail position and implicit result: the last statement is the value.
- `return`, including `return` of an `if`/`match`.
- Type annotations on parameters and results.
- Default parameters.
- Named arguments.
- Functions as values, higher-order functions and closures.
- Recursion and tail calls (what is guaranteed, and on which targets).
- `if`/`match` statements as values.

**8.8 Control flow**
- `if` / `else if` / `else`.
- `for … in` (over ranges, lists and other collections).
- `while`.
- `loop` (accumulator loops) and its three forms.
- `break` and `continue`.
- Expression statements.

**8.9 Collections**
- Lists: literals, `+`, indexing, `len`, and comprehensions.
- Tuples: literals, singleton and empty, and destructuring.
- Maps (`Map(K, V)`), immutable and ordered.
- Arrays (`Array(T)`) *(use mutation)*.
- DynArrays (`DynArray(T)`) *(use mutation)*.
- MutMaps (`MutMap(K, V)`) *(use mutation)*.
- Slices (copies) and views (shared).
- Making and converting: `list(...)`, `array(...)`, `map(...)` and the
  rest.
- `fmap`, `filter`, `foldl`, `foldr`, `any`, `all` on every
  collection.
- A summary table: each collection × immutable/mutable × ordered ×
  operations.

**8.10 Datatypes, structs and pattern matching**
- `datatype`: constructors, fields (named and positional), and type
  parameters.
- `struct`: a datatype with one constructor, and defaults.
- `mutable struct` (linking to 8.6).
- `match`/`case`: literal, constructor, tuple, list and wildcard
  patterns.
- Or-patterns, `as` and guards.
- Exhaustiveness: what is checked and the error message.
- `Option` and `Result`: the builtin datatypes and the idioms for them.

**8.11 Objects** *(use objects)*
- Classes: fields, `__init__` (to check the name), methods and `self`.
- Inheritance: one parent, overriding, and `super`.
- Abstract classes.
- Interfaces: abstract methods, default methods, and implementing many.
- Dynamic dispatch, and objects being shared (reference semantics).
- Classes and the type checker (subtyping, where allowed).
- How objects mix with datatypes and modules.

**8.12 Types and type inference**
- The types (a table: basic, collections, function types, tuples,
  datatypes, classes, `Ptr`).
- Annotations: where they may be written.
- Inference: unannotated functions get the most general type.
- Type variables and `all` quantifiers.
- Number defaults: what a literal becomes when nothing decides.
- What is checked, and what is not.
- Reading type error messages (two or three annotated examples).

**8.13 Overloading and implicits** *(advanced)*
- Static overloading (`def int::leq`), and how a call is resolved.
- Ambiguity errors and how to fix them.
- Implicit parameters: declaring, supplying and resolving.
- Public implicits across modules.

**8.14 Modules**
- One file is one module.
- Nothing exported by default; `public`.
- What a module may export.
- `import m`, `import m as n`, `from m import a, b as c`.
- Submodules (`a.b`).
- No circular imports.
- When a module's top level runs.
- How modules are found (search path, `-L`).
- External modules: implemented in a target language (linking to
  Compiler targets).

**8.15 Builtins and I/O**
- The builtin functions: `print`, `debug`, `range`, `len`, `string`,
  `int`, … as a table with types.
- `print` versus `debug`, and `--release`.
- The prelude: what is in scope without importing.
- Pointers to the libraries for I/O (`io`, `sys`, `fs`).

**8.16 Warnings**
- What is reported.
- The `-W` flags, and `-Werror`.
- Silencing a warning (`_name`).

#### 9. Pyking vs. other languages (new)

`sitesrc/documentation/vs-other-languages.md`, or a small group of
pages with one per language if it grows long. It is for a reader who
knows one of the target languages and wants to know what carries over,
or who wants to know what their program becomes when compiled. There
is one part per target family. Sources: `docs/target_*.md`, the
user-facing parts only, and `docs/targets.md`.

The page opens with:
- One paragraph: Pyking is Python's syntax with ML's semantics
  (immutable by default, every block a scope, static types with
  inference, datatypes and `match`). Each `use` mode adds a familiar
  imperative or object-oriented layer.
- **A table across languages**: rows are features and columns are
  Pyking, Python, JavaScript, C, Java and OCaml. Rows include: typing
  (static or dynamic, inferred or declared), default mutability, block
  scope, integer type and overflow, division, `None`/`null`,
  exceptions, sum types, pattern matching, closures, tail calls,
  objects, generics and memory management.
- How to see the mapping yourself: the playground's Compiled code tab,
  and `pyk compile --target T --stdout`.

Every part has the same four sections, so parts can be compared side
by side:

1. **Syntax: similar and different.** A side-by-side table of the same
   small constructs in both languages.
2. **Semantics: similar and different.** Mostly bullets, with one
   runnable Pyking example where a difference would surprise a reader
   of that language.
3. **How Pyking compiles to it.** A mapping table of Pyking
   construct/type → generated code, followed by one small program
   shown as Pyking and its generated output side by side, with one
   datatype, one `match` and one `var`.
4. **Targets and limits.** The versions, what is needed to run the
   output, what the target refuses (if anything), and where the output
   differs (integer overflow and so on).

**9.1 Compared to Python** (`python12`, `python14`)
- *Syntax, similar*: indentation, `def`, `if`/`for`/`while`, `return`,
  list comprehensions, `match`/`case`, slicing, `import`/`from … import
  … as`, `#` comments, and most operators.
- *Syntax, different*: `true`/`false`; `else if` instead of `elif`;
  `^` instead of `**`; `lam x.` instead of `lambda x:`; `if … then …
  else` expressions; `'a'` is a Char, while strings take double quotes
  only; `var`/`:=` (not the walrus); no chained comparisons; and
  `datatype`, `struct`, `let`, `loop`, `public` and `use`.
- *Syntax, absent*: `try`/`except`/`raise`, `with`, decorators,
  `*args`/`**kwargs`, `yield`, `async`, `global`/`nonlocal`, f-strings,
  and dict/set literals. Each says what to use instead (to check the
  list).
- *Semantics, similar*: values, evaluation order, lists, strings,
  closures, and classes under `use objects`.
- *Semantics, different*: static types with inference, so errors come
  before running; every block is a scope; `=` never mutates; `Int`
  division truncates and `Int` and `Float` never mix; no `None` or
  exceptions, but `Option`/`Result` and `panic`; `match` must be
  exhaustive; nothing is exported without `public`; and `Map` is
  immutable while `MutMap` is the dict.
- *Compiling*: datatypes become frozen dataclasses (with type
  parameters, a `type` alias for the union, and class patterns in
  `match`); block scopes become renamed variables (`total`, `total2`);
  `var`s written from inside a function; `loop`/`break`/`continue`;
  Pyking names that are Python keywords; module names Python has
  already taken; `Array`/`DynArray`/views/pointers as runtime classes;
  tail position as `return`; value-form `if`/`match`; and the
  conversions. Also: everything the language has is supported.
- *Versions*: 3.12 versus 3.14, and what differs in the output.

**9.2 Compared to JavaScript** (`node22`, `node24`, `web2020`,
`web2024`, `iweb2020`, `iweb2024`)
- *Syntax*: blocks by indentation, not braces; no `let`/`const`, but
  `=` (like `const`) and `var` (like `let`); `lam x. e` in place of
  `x => e`; `match` in place of `switch`; `==` is structural; and no
  `===`.
- *Semantics, similar*: closures, first-class functions, objects
  shared by reference (under `use objects`), and single-threaded
  tinyweb callbacks like the event loop.
- *Semantics, different*: static types; `Int` and `Float` are
  separate types, and `Int` `/` truncates; no `undefined`/`null`; no
  implicit conversion (`"a" + 1` is an error); structural equality;
  block scope everywhere (no hoisting surprises); and `Char` as its own
  type.
- *Compiling*: datatypes as tagged objects (`pykData`); tuples; the
  runtime file `pyk-runtime.js`; numbers (`Math.trunc` for `/`) and
  Floats; Chars; arrays, DynArrays and views; mutable structs;
  pointers; equality; names that are JavaScript keywords and
  renaming; tail position; and `print` in node versus in a browser.
- *The three targets*: node (a script), web (an HTML page plus JS, run
  with `pyk serve`), and iweb (the page running the interpreter).
  ES2020 versus ES2024. tinyweb on the web targets.
- *Limits*: integer overflow past 32 bits.

**9.3 Compared to C** (`c89`, `c99`, `c23`, `c23-gc`)
- *Syntax*: no braces, semicolons or declarations of types (inferred);
  `&x`/`*p` look the same under `use mutation, pointers`; `match` in
  place of `switch`; `datatype` in place of tagged unions; and
  `mutable struct` in place of `struct`.
- *Semantics, similar*: `Int` arithmetic, pointers (without null,
  arithmetic or `free`), mutable structs as references, and arrays
  with a length.
- *Semantics, different*: memory is managed, never freed by the
  program; no undefined behaviour from out-of-bounds access (checked)
  or null; strings are immutable values; closures and polymorphic
  functions exist; and modules in place of headers.
- *Compiling*: the type mapping table (`Int` → `int`, `String` →
  `const char *`, a datatype → a struct with a tag and a union, a
  closure → a function plus environment, …); datatypes and `match` as
  an if/else chain; polymorphic functions (specialized); functions as
  values; the top level; evaluation order; modules as one C file;
  external modules in C; and classes simulated with descriptors.
- *Memory*: plain C uses `malloc` and never frees, and refuses what
  needs a freeing heap (lists, recursive datatypes, closures outliving
  their frame, polymorphic parameters). `c23-gc` uses bdwgc and
  accepts the whole language. Say how to install bdwgc.
- *Limits*: what plain C refuses (from "What is refused"); `int` is 32
  bits and overflow is undefined; floating-point contraction.

**9.4 Compared to Java** (`java8`, `java17`, `java21`)
- *Syntax*: no class around the program, no type declarations
  (inferred), and no `new` (constructors are functions); `interface`
  and `class` under `use objects` read like Java's in Python's
  spelling, with explicit `self`.
- *Semantics, similar*: objects, single inheritance plus interfaces,
  dynamic dispatch, abstract classes, generics (type variables), and
  garbage collection.
- *Semantics, different*: functions and data live outside classes;
  immutable by default; datatypes and exhaustive `match` (like sealed
  interfaces with records and pattern-matching `switch`); no `null`
  and no exceptions; and structural `==`, not reference `==`.
- *Compiling*: the three shapes of output (the same `match` in Java 8,
  17 and 21); the type mapping table (`Int` → `int`, `[T]` →
  `java.util.List<T>`, tuples → `T2…`, functions →
  `java.util.function`); datatypes as an abstract class with
  subclasses (java8) or a sealed interface with records (java17+);
  functions as values; polymorphic parameters; loops and `match`;
  printing; arrays, DynArrays and views; equality and MutMaps;
  pointers; naming the class; modules; external modules; and classes
  as nested Java classes.
- *Limits*: `int` is 32 bits, and overflow wraps.

**9.5 Compared to OCaml** (`ocaml4.14`, `ocaml5.5`)
- *Syntax*: Python-style indentation in place of `let … in` chains
  (though `let … in` exists); `def` in place of `let rec`; `lam x.` in
  place of `fun x ->`; `match`/`case` in place of `match … with |`;
  `datatype` in place of `type … = | …`; `Some(x)` with parentheses;
  and type annotations as `x: Int`, with type variables written `a`
  where OCaml writes `'a`.
- *Semantics, similar*: almost all of the core. Hindley–Milner-style
  inference, immutable bindings, variants and exhaustive `match`,
  `Option`/`Result`, closures, tail calls, and `var`/`:=` as `ref`.
- *Semantics, different*: statements and an implicit last value in
  place of expressions everywhere; `return`, `break` and `continue`;
  overloading and implicits (OCaml has neither); `+` on strings and
  lists; classes are Java-style, not OCaml objects; and no functors.
- *Compiling*: how the type checker is reused; blocks and bindings as
  `let`; functions; lambdas; `if`; tail calls; `loop`/`break`/
  `continue` and leaving a function early; `for`/`while`; `match` and
  patterns; datatypes as OCaml variants (renaming `Some` → `Some_` and
  so on); `var` as `ref` with `!x`; tuples; Chars; arrays, mutable
  structs, DynArrays, views, pointers and maps; and classes (and why
  they are not OCaml classes).
- *Limits*: what is not supported (the list in "What is not
  supported"); `int` is 63 bits, so overflow disagrees with C/Java.

#### 10. Grammar (new)

`sitesrc/documentation/grammar.md`. All the syntax, in one place.
Sources: the "Grammar", "Indentation-based blocks", "Lines and
continuation" and "A block on its header's own line" parts of
`PYKING.md`, and `docs/syntax.md`.

- **Notation**: the EBNF conventions used.
- **Lexical structure**: characters and encoding, comments (`#` and
  `##` doc comments), identifiers (with the upper-case rule for types
  and constructors), keywords (with reserved words per mode), literals
  (int, float, char, string, escapes) and operators/punctuation.
- **Layout**: 4-space indentation, `INDENT`/`DEDENT`, line
  continuation inside brackets, and a block on its header's line (what
  may go there).
- **The grammar**, in parts, each with its EBNF and a one-paragraph
  explanation:
  - Programs and `use` lines
  - Imports and `public`
  - Declarations: `def`, datatype, struct, mutable struct, class,
    interface
  - Statements
  - Expressions, with the precedence and associativity table
  - Patterns
  - Types
- **Syntax by mode**: which productions each `use` adds.
- **Compared with Python**, a summary after the grammar. It is short
  and links to "Compared to Python" on page 9 for semantics and
  compilation:
  - *The same as Python*: indentation blocks, `def`, `if`/`for`/
    `while`, `return`, list comprehensions, `match`/`case`, slicing,
    `import`/`from … import … as`, `#` comments, most operators.
  - *Different*: `true`/`false`; `else if` instead of `elif`; `^`
    instead of `**`; `lam x.` instead of `lambda x:`; `if … then …
    else` expressions; char literals in single quotes; non-chaining
    comparisons; `&&`/`||`/`!` accepted; `:=` meaning update (not the
    walrus).
  - *New in Pyking*: `var`, `:=`, `use`, `datatype`, `struct`, `let …
    in`, `loop`, `public`, `implicit`, `Type::name` overloading, and
    pointers `&`/`*`.
  - *Not in Pyking*: `elif`, `lambda`, `global`/`nonlocal`, `try`/
    `except`/`raise`, `with`, decorators, `*args`/`**kwargs`,
    `yield`/generators, `async`, f-strings (to check each).

#### tinyweb in other languages (kept, regrouped)

The pages `tools/site/tinywebdoc.py` writes (C, Java, JavaScript,
OCaml, Python) are kept as they are, as the sub-entries of "Tinyweb
without Pyking".

---

## How this is built

- **Getting started and Tools pages** are new files in `sitesrc/`.
  Their `sidebar.order` sets the order above. Their `sidebar.group`
  chooses what the Help tab shows; the left menu ignores it.
- **Language reference, Pyking vs. other languages, and Grammar.** `PYKING.md` stays the one source
  for the language, as CLAUDE.md requires. Reorganize it so its `##`
  headings are the reference pages 8.1–8.16 plus a "Grammar" part, and
  have `help.py` split it at those headings into
  `documentation/language/*.md` and `documentation/grammar.md`. The
  alternative is one source file per page under `sitesrc/` with
  `PYKING.md` generated from them. Decide which before writing.
  Implementation notes about what `src/` accepts move to `docs/`.
- **Removed and moved pages** need redirects (`/getstarted/overview/`,
  `/getstarted/tinyweb-styles/`, `/documentation/language/` anchors),
  so links in the playground, notebooks and old blog posts keep working.
- The same pages appear in the playground's Help tab and in `pyk
  pykhelp`. Check that the Help tab's menu handles groups.
- Update `tools/site/README.md`, `tools/help/`, the site tests, and
  `CHANGELOG.md`.

## Things to check while writing

- The Grammar in `PYKING.md` lists `feature = "mutation" | "objects"`,
  but `use pointers` exists. It is out of date.
- Exactly which constructs each `use` turns on (arrays, DynArray,
  MutMap and `loop` under `mutation`?), for the modes table.
- The class constructor's name, and the list of Python features
  absent from Pyking. These are marked "to check" above. (`break` and
  `continue` exist, inside `loop`: see `docs/target_python.md`.)
- Page 9's generated-code examples should come from the compiler, not
  be written by hand, so they stay true. One option is a build step that
  compiles each example with `pyk compile --stdout` for each target.
- Which bundled examples (`src/examples.toml`) can be reused as the 20
  minutes page's cells.
