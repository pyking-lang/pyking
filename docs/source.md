# The source, file by file

What every module in `src/` is, and what is inside it: the data
structures it defines, the functions that matter, and the decisions the
code embodies. It is the reading order as much as the reference — the
modules are listed in the order a program passes through them.

For the *shape* of the compiler (the pipeline, the runtime interface, the
tests) see [architecture.md](architecture.md); for what each target
accepts see [targets.md](targets.md); for the language itself see
[../PYKING.md](../PYKING.md). This page is about the code.

`src/` is one dune **library** (`pyking`, unwrapped) plus a small
executable that links it. Unwrapped means the modules are reachable as
`Lexer`, `Parser`, `Syntax` and so on rather than under a `Pyking.`
prefix, and one module refers to another by that name directly. The
library depends on nothing outside the standard library, which is what
lets `src/web/` compile the same code to JavaScript with js_of_ocaml;
only the executable adds `unix`, for the process handling `--run`
needs, and `dynlink`, for the interpreter's plugins -- with the one
module a plugin names, `src/plugin/pyk_plugin.ml`, a library of its own.
See [build.md](build.md).

That flatness is not an oversight — these files are to be rewritten *in
Pyking* one day, and Pyking's own module system is one file per module
with no hierarchy to express.

Every module has an `.mli` beside it — bar the two entry points, which
nothing calls — holding what another module may use and nothing else,
so what this page calls a module's main functions and what is
*reachable* from outside it are two different lists. The second is
[interfaces.md](interfaces.md), which also says which types are opaque
and which module calls which.

## At a glance

| module | lines | what it is |
|---|---:|---|
| [`lexer.ml`](#lexerml) | ~450 | Characters → tokens. Also defines `info`, the source span every later node carries. |
| [`syntax.ml`](#syntaxml) | ~960 | The AST: one variant type per node group, plus the pretty printer that prints Pyking back out. |
| [`parser.ml`](#parserml) | ~1520 | Recursive descent, tokens → AST, and the few rules the grammar cannot state. |
| [`module.ml`](#moduleml) | ~520 | The module system: which modules a program is made of, in what order, what each exports, and what each import means. |
| [`submodules.ml`](#submodulesml) | ~520 | Submodules: every dotted name (`mymod.foo`) made the plain name it compiles to, and an import naming a submodule made the `from` line taking its members, inside `module.load`. |
| [`splash.ml`](#splashml) | ~110 | tinyweb's splash screen: `tinyweb.splash()` called at the end of a program that can play a sound, inside `module.load`. |
| [`desugar_args.ml`](#desugar_argsml) | ~620 | Default parameters and named arguments, rewritten away before anything else reads the program, so no later stage knows they exist. |
| [`analyses.ml`](#analysesml) | ~1030 | Static analyses over the AST: mutability (`analyze_mutability`), `symbolize`, which numbers every node, and `effects`, which says what can print. |
| [`walk.ml`](#walkml) | ~190 | One `children` function over every AST node, for the passes that ask a question of a whole subtree. |
| [`typesystem.ml`](#typesystemml) | ~3010 | The type checker: one function per AST datatype, producing `tmap` (symbol → type). Also the type *inference*, which is the same machinery run at a call site rather than at a definition. Its fragment is the interpreter's, and nearly all of the OCaml backend's. |
| [`exhaustive.ml`](#exhaustiveml) | ~420 | Every `match` matches every value and every case is reachable: Maranget's usefulness, over the checker's types. |
| [`type_experiment.ml`](#type_experimentml) | ~140 | An alternative checker, a fragment of one, run instead of the real one by `--type-experiment`. |
| [`release.ml`](#releaseml) | ~180 | `--release`: every call to the builtin `debug` removed, before any backend sees the program. |
| [`prune.ml`](#pruneml) | ~160 | What a program uses of the modules it imports, for the C and Java targets: the rest of each module removed, and every import narrowed. |
| [`opt_tailcall.ml`](#opt_tailcallml) | ~1190 | Tail calls into loops: one AST-to-AST pass over a program the checker accepted, so every backend and the interpreter get tail recursion at once. |
| [`builtin.ml`](#builtinml) | ~110 | The builtins (`print`, `debug`, `range`, `string`, `len`, ...): each one's name, arity, whether it crosses the host boundary, and what it does. One table, and no host code at all. |
| [`interpreter.ml`](#interpreterml) | ~1670 | The interpreter: values, environments, and a resumable small-step machine that runs the AST. The reference for runtime semantics. |
| [`plugin_host.ml`](#plugin_hostml) | ~330 | How the interpreter reaches a module implemented in a target language: its OCaml implementation, compiled to a plugin and loaded with Dynlink. |
| [`plugin/pyk_plugin.ml`](#pluginpyk_pluginml) | ~20 | The registry a loaded plugin fills in. |
| [`repl.ml`](#replml) | ~750 | `pyk repl`'s terminal half: the multi-line editor an entry is typed into, and the loop. |
| [`repl_session.ml`](#repl_sessionml) | ~700 | A REPL session: a program written one entry at a time. Shared by `pyk repl` and the playground's REPL tab. |
| [`target_python.ml`](#target_pythonml) | ~2410 | The Python backend, and the only one that compiles the whole language. |
| [`target_js_core.ml`](#target_js_coreml) | ~1280 | The JavaScript backend's language half: a `Js*` AST, translation, printer. |
| [`target_js_packaging.ml`](#target_js_packagingml) | ~300 | Its packaging half: `node`, `web`, `iweb`, and the JavaScript side of the runtime interface. |
| [`target_c.ml`](#target_cml) | ~1990 | The C backend, for `c89` and `c23`. Infers the types C insists on, and pins down the evaluation order C leaves open. |
| [`target_java.ml`](#target_javaml) | ~1690 | The Java backend, for `java8`/`java17`/`java21`. Also proves every function returns. |
| [`target_ocaml.ml`](#target_ocamlml) | ~2900 | The OCaml backend. Infers nothing: it reads the checker's `tmap`. |
| [`execution.ml`](#executionml) | ~200 | What `--run` runs: the commands each target's host uses to build and run what was compiled. |
| [`install.ml`](#installml) | ~20 | Where this installation keeps `lib/`, `build/` and `tools/`: the executable's directory, symbolic links resolved. |
| [`version.ml`](#versionml) | 1 | The version, generated from `VERSION` by `src/dune`. |
| [`web_tools.ml`](#web_toolsml) | ~330 | `pyk notebook`, `pyk playground` and `pyk serve`: what each serves. |
| [`web_server.ml`](#web_serverml) | ~360 | A small HTTP/1.1 server, in the `pyk` process. |
| [`scopes.ml`](#scopesml) | ~420 | What the names in a module mean: every use with the binding it reaches, and which names are in scope where. The language server and the debugger read it. |
| [`lsp.ml`](#lspml) | ~2000 | The language server: a state, and one message in to the messages out. |
| [`debug_session.ml`](#debug_sessionml) | ~900 | The debugger's core: a program run a step at a time, with breakpoints, stepping, the calls in progress and their variables. Protocol-free. |
| [`dap.ml`](#dapml) | ~480 | The debug adapter: the Debug Adapter Protocol over a `debug_session.ml` session. |
| [`json.ml`](#jsonml) | ~220 | JSON read and written. |
| [`notebook_format.ml`](#notebook_formatml) | ~950 | A notebook's Markdown as JSON and back, character for character, and the JSON Schema the JSON follows. |
| [`pyk.ml`](#pykml) | ~780 | The driver: argv, stage sequencing, error reporting, the six commands. |
| [`web/pyking_web.ml`](#webpyking_webml) | ~320 | The browser entry point: the same library compiled to JavaScript, for the playground and the notebook. |

Two shapes recur everywhere and are worth reading once rather than
twenty times:

**One constructor per variant, plus `match`.** Every tree in the
repository — tokens, the AST, types, values, each backend's own AST — is
one variant type with one constructor per alternative, consumed by
`match`. A `match` that misses a case is a compile error, which is the
whole reason the shape is worth insisting on; it is also how the tree
will be written once the compiler is rewritten in Pyking, whose own
variant types are meant to be read the same way. New variants follow
the same style rather than being collapsed into one record with a
`kind` field.

**Tables are threaded, not mutated.** Environments, scopes and type
environments are rebuilt by extension (`SMap.add name value env`) rather
than updated in place. Entering a nested scope is "keep using what you
were handed"; leaving one is "go back to the caller's" — which is what
makes a block's bindings unable to escape it, with no scope stack to
pop.

---

## `lexer.ml`

**Characters → tokens, and the vocabulary of source positions.**

Everything downstream reports errors against `Info`, so this module is
imported by every other one.

**Design, in depth:** [lexer.md](lexer.md).

### Data structures

- **`info = { file; row1; col1; row2; col2 }`** — a record: the span
  a token or node covers. Rows count from 1, columns from 0. Attached to
  every token by the lexer, and carried onto every AST node by the
  parser, so any later stage can report against the source.
  `pprint_info` renders it as `'file' row:col-row:col`, the form every
  error message in the compiler begins with.
- **`token`** — one variant type, one constructor per kind:
  `TokInt of info * int`, `TokFloat of info * float`,
  `TokString of info * string`,
  `TokIdent of info * string`, the operators (`TokAdd`, `TokConcat`,
  `TokSub`, `TokMul`, `TokDiv`, `TokEqEq`, `TokLessThan`, …), the punctuation (`TokColon`,
  `TokComma`, `TokLParen`, `TokArrow`, `TokFatArrow`, `TokDotDot`, …),
  the keywords
  (`TokDef`, `TokReturn`, `TokFor`, `TokIf`, `TokMatch`, `TokVar`, …),
  and the two that carry the block structure, **`TokIndent`** and
  **`TokDedent`**.
- **`keywords`** — the reserved words, as one list: control flow and
  declarations, the type names `Int`/`Float`/`String`/`Bool`, and the literals
  `true`/`false`. `tools/emacs/pyking-mode.el` mirrors this list split
  three ways, and must be kept in step with it.
- **`Lex_error (info, message)`** — raised for a lexical error.

### Main functions

- **`lexing file chars -> [token]`** — the lexer. It consumes a *list
  of characters* (not a string) by matching on it (`| '-' :: '>' :: xs
  -> …`), carrying row, column, the indentation stack and the tokens so
  far along as parameters rather than mutating anything. Indentation is turned into `TokIndent`/`TokDedent` here, which
  is what lets the parser treat a block as a bracketed construct.
  A hexadecimal (`0xff8800`) or binary (`0b0101`) literal is read here
  too, its `_` between digits dropped, and becomes the same `TokInt` a
  decimal one does, held to the same bound (`max_int_literal`).
- **`string_until(pred, chars)`** — the longest prefix satisfying `pred`,
  used for numbers and identifiers.
- **`scan_string(file, r, c, quote, chars)`** — a string literal, with
  its backslash escapes decoded.
- **`is_digit` / `is_letter` / `is_digit_letter`** — character classes.
- **`keyword_token(name, info)`** — the keyword token for a name, or
  `None` if it is an ordinary identifier.
- **`pprint_token tok`** — a token as text, by `match` over the type.

Adding an operator or keyword means three edits in this file: an arm in
`lexing`, a `Tok*` constructor, and an arm in `pprint_token`. The
compiler catches the third if you forget it.

---

## `syntax.ml`

**The AST, and how to print it.** Every backend and every analysis
consumes exactly this.

The name is `syntax.ml` rather than `ast.ml` because everything else
already says so — the `open Syntax` at the top of a dozen modules, the
docs, the error messages. See [syntax.md](syntax.md) for the reason the
name was ever a question.

**Design, in depth:** [syntax.md](syntax.md).

### Data structures

The file opens with one recursive `type ... and ...` declaring every
group at once, with a trailing comment on each constructor saying what
it is written as in source. The declaration is the datatype description:
a `match` that misses a case is a compile error, so nothing here can
drift out of step with the code that reads it. What the comments still
carry is the notation the type cannot (`[T]` is `t list`, `T?` is
`t option`) and the source syntax each variant stands for.

The groups:

- **`Expr`** — `EInt`, `EString`, `EBool`, `EVar`, `EAdd`, `ESub`,
  `EMul`, `EDiv`, `ENeg`, `EConcat`, `ELessThan`, `ELessThanEq`,
  `EGreatThan`, `EGreatThanEq`, `EEq`, `EBinary`, `EUnary`, `EIndex`,
  `ECall`, `EList`, `ETuple`, `EIf`, `EListComp`, `ELambda`, `ELet`,
  `EConstruct`, `EField`. `EBinary` and `EUnary` carry every other
  operator as a `binop`/`unop` -- `%`, `^`, `!=`, `and`/`or`/`not` in
  either spelling, and the bitwise ones -- with the spelling `and`,
  `or` and `not` were written in, so `-t pyking` prints them back as
  written; `xor` on two Bools becomes `BBoolXor`, printed `xor` and
  compiled as `!=`. `EIndex` is `xs[i]`. The parser makes an `EAdd` of every
  `+`; `elaborate.ml` makes one the checker typed as a String or a list
  an `EConcat`, which is what every backend compiles as a join. `ELambda`
  holds a `Param` list and one *expression*: a lambda's body is never a
  block. `EConstruct` is a constructor applied to its fields, with the
  module it is reached through where it is another's; `EField` reads a
  named field. `ELet` is `let target[: type] = value in body`: one
  target, as an `=` binding's, and worth its body. `desugar_args.ml`
  also builds them, for a call whose named arguments are out of
  parameter order (see `docs/desugar_args.md`).
- **`LoopIter`** — `ForIn`, `WhileTest`. A loop's iteration clause;
  `None` for a bare `loop:`. `SFor` and `SWhile` no longer exist:
  `for x in e:` and `while c:` *are* `SLoop`, with no accumulator
  written, which is what lets every combination of the three halves
  work without a construct of its own.
- **`Pattern`** — `PInt`, `PString`, `PBool`, `PWildcard`, `PCapture`,
  `PTuple`, `PList`, `PText`, `PConstructor`, `POr`, `PAs`. `PText` is a
  string split around a fixed beginning and end (`"ab" + rest`); the
  list form of `+` is folded into `PList` by the parser, so only the
  string one is a node. `PConstructor` carries positional and named
  field patterns; after `desugar_args.ml` every field is positional.
- **`Type`** — `TInt`, `TString`, `TBool`, `TList`, `TTuple`,
  `TUnknown`, `TBuiltin`, `TFunction`, `TVar`, `TForall`, `TCon`,
  `TData`. `TCon` is a datatype applied to its parameters, under the
  canonical name in a type the checker made; `TData` is what a
  module's signature says about a datatype, and is never written or
  printed.
  `TVar` is a type variable a written annotation names and a caller
  chooses; `TForall` binds them, and the outermost one is implicit --
  supplied by the checker and never printed. A `TVar` the *checker* made
  rather than the source is *flexible* (`rigid=False`): the element type
  of `[]`, which nothing has constrained. `TTuple` with no
  elements is the unit type `()`; `TUnknown` is a type nothing has
  decided yet, and
  `TBuiltin` the type of a host operation — neither is written in
  source, and both are produced only by the checker.
  `TFunction` is both written in source and built by the checker, and
  carries two fields that belong to the checker alone — `definition`, the
  `def` whose body is still to be checked, and `tmsym`, that
  definition's symbol, which is how the checker names it in the tables it
  keeps (see [type_inference.md](type_inference.md)). Neither is part of what a
  function type *means*, so neither takes part in comparing two of
  them.
- **`CompClause`** — `CompFor`, `CompIf` (list comprehensions).
- **`AssignTarget`** — `TargetName`, `TargetTuple`.
- **`stmt`** — `SLet` (`x = e`), `SLetStmt` (`x = if c: …`), `SVar`,
  `SMutate` (`:=`), `SReturn`, `SReturnStmt`, `SExprStmt`,
  `SLoop` (`loop x = e:`), `SBreak`, `SContinue`, `SIf`,
  `SFunctionDef`, `SFunctionSig`, `SMatch`, `SImport`, `SDatatype`
  (with its `constructor`s and each one's `field`s). `SLoop` carries
  its accumulator as a `target`/`init` pair, both absent for the bare
  `loop:`; `SBreak` and `SContinue` carry nothing but their span, since
  a loop is worth the accumulator it stopped with.
- **Single-constructor records** — `param`, `list_rest`, `match_case`
  (pattern, guard, body), `constructor`, `field`, and `datatype`
  (canonical name, parameters, constructors with their fields' names and
  types: what `TData` carries).

Every node carries `info` (its span) and `sym` (its symbol, `0` until
`symbolize` runs), written first and last in each constructor. Nothing
is mutated, so a pass that changes the tree rebuilds it — which is
exactly what `symbolize` does.

### Main functions

- **`pprint_program(stmts, symbols=False, tmap=None)`** — the only entry
  point callers use. `symbols=True` appends each node's `@n`;
  `tmap` makes every annotation printed come from the *checker* rather
  than from the source, so `pyk compile -t pyking` shows inferred
  types. Both are module-level display flags that this function sets and
  restores around its one call, rather than parameters threaded through
  every printer.
- **`pprint_expr` / `pprint_stmt` / `pprint_type` / `pprint_pattern` /
  `pprint_param` / `pprint_target`** — the printers themselves, each a
  `match` over its own datatype. Output is valid Pyking, which is what
  keeps the `pyking` target's output re-parsable.

---

## `parser.ml`

**Recursive descent: tokens → AST.**

**Design, in depth:** [parser.md](parser.md).

### Main functions

The expression grammar is one function per precedence level, each taking
a token list and returning `(node, rest)`:

`parse_atom` → `parse_call_tail` → `parse_unary` →
`parse_multiplicative` → `parse_additive` → `parse_comparison` →
`parse_expr` → `parse_tuple_or_expr`.

`parse_expr` is also where a lambda is read: `lam` starts one, and
`parse_lambda` reads its parameters up to the `.` (docs/parser.md).
`parse_uses` reads a module's leading `use` lines, and
`check_features` refuses what a feature the module did not turn on
would allow -- `var` and `:=` without `use mutation`.

Around them:

- **`parse_statement(tokens)`** — one statement, dispatching on the
  leading token, including the `if`/`match` forms that can be *bound*
  (`x = if c:`) or *returned* (`return match e:`), via
  `parse_bound_value`.
- **`parse_block(tokens, header_info)`** — one block: `TokIndent`-
  delimited, or the single *expression* written on the header's own
  line, which is why it is handed the `:` that opened it (PYKING.md, "A
  block on its header's own line"). Neither shape present is `expected
  an indented block`, which is also what tells the REPL an entry is
  unfinished. `parse_cases` has only the indented shape: a `match`
  opens a list of clauses, not a block of statements.
- **`parse_type` / `parse_type_atom` / `parse_param` / `parse_params`** —
  annotations. A parenthesized list followed by `->` is a `TFunction`;
  without the arrow it is a `TTuple`. At one element the comma decides,
  as it does among values: `(Int,)` is a one-tuple and `(Int)` is
  grouping. `parse_type` reads an arrow and `parse_type_atom`
  everything else.
- **`parse_pattern`, `parse_case`, `parse_cases`, `parse_match_stmt`** —
  `match`/`case`, including list patterns with a `..rest` marker, and a
  case's `if` guard. `parse_pattern_as` and `parse_pattern_or` are the
  two levels above the `+` that splits; `parse_constructor_pattern` reads a
  constructor's field patterns, positional first. `check_alternatives`
  refuses an or-pattern whose alternatives bind different names.
- **`parse_datatype`, `parse_constructor`, `parse_field`** — a
  `datatype` declaration, reached only from `parse_top_statement` and
  `parse_public`, so one inside a block is refused. A field written
  `name = literal` gets the literal's type here (`literal_type`), one
  written `name = expr` with any other default no type at all, and
  `check_fields` holds the fields to a call's rules: unnamed first,
  every one after a default defaulted. `parse_type_name`,
  `parse_type_params` and `parse_fields` are shared with `struct`.
- **`parse_struct`** — a `struct`, built straight into the `SDatatype`
  of its one constructor, so nothing after the parser knows it was
  written. `params_follow` tells a parenthesized list of type parameters
  (followed by `:`) from one of fields, and `type_variables` collects
  the one-line form's parameters from its fields.
- **`parse_args`** — also reads a last `..expr`, kept as an argument
  labelled `Syntax.spread_label`; `parse_call_tail` refuses one in a
  call.
- **`parse_construct`, `parse_type_application`** — a constructor in an
  expression, and a datatype in a type: an uppercase identifier, with
  its arguments where a `(` follows on its row. `parse_call_tail` reads
  `.name` after an expression as a field.
- **`parse_loop_stmt(info, tokens)`** — a `loop`, from just after the
  keyword: the optional accumulator (a target, an optional annotation,
  `=`, an expression) and the body. A loop is also a *bound* value, so
  `parse_bound_value` reaches it too.
- **`parse_target`** and `try_parse_assignment_target` — assignment
  targets, including tuple destructuring.
- **`parse(tokens) -> [Stmt]`** — the whole program.

Two helpers matter beyond their size. **`combine_info(start, end)`**
builds each node's span from its first token's start to its last token's
end — a new grammar rule combines infos the same way rather than reusing
one token's span. **`here(tokens)`** is the position to blame when the
input has run out.

Six checks live here rather than in a later stage, so that they fail
with a source position at parse time: **`check_lowercase`** (no name a
program binds starts with an uppercase letter, which is kept for types
and constructors; `check_plain_name` and `check_import_name` call it),
**`check_no_duplicate_captures`**
(a pattern may not bind one name twice), **`check_value_stmt`** (every
branch of a value-form `if`/`match` must yield a value — which
`target_python.ml` then relies on), **`check_own_line`** (a
statement, and a `case` clause, begins a line of its own — the rule that
stops `print h` from being read as two statements, which the grammar
cannot state because it cannot see line boundaries),
**`check_loop_context`** (a `break`/`continue` belongs to a `loop`, and
may not reach out of a `for`, a `while` or a `def` to find one), and
**`check_reachable`** (nothing may be written after one in the same
block). The last two are shape rather than scope — neither needs to know
what a name means — which is why they are here and not in
`analyses.ml`, and being here they hold in every mode.

A `def` header with no body -- `def f(n: Int, s: String) -> Int`, ending
its line, every parameter typed and none with a default -- is read as
the signature line `def f : (Int, String) -> Int` (`SFunctionSig`); the
parameter names are not kept, since nothing after the parser needs them.

`Parse_error (info, message)` carries the position.

---

## `module.ml`

**The module system.** One file is one module; a program is the acyclic
graph of the modules its main file reaches. This reads and parses all of
them, refuses a cycle, puts them in dependency order, settles what each
one exports and what each import means, and turns a checked module into
the signature the next one is checked against. Errors are
`Module_error (info, message)`, reported as `Module error`.

**Design, in depth:** [modules.md](modules.md).

### Data structures

- **`Module`** — one file: `name` (its stem, which is what another
  module imports it by), `path`, `tokens` (kept for `--tokens`, which
  prints every module of the program), `stmts`, `imports` (the modules
  it imports, in source order), `publics` (each exported name and where
  it was made public), and `sigmap` (each exported name and its type,
  filled in after the module is checked).
- **`Context`** — what a backend is told about the module it is
  compiling beyond its statements: `name`, `main` (whether it is the
  program's own module), `separate` (whether the program has more than
  one module at all), `starts` (the modules the program's own module
  runs before its own top level), and `sigmaps` (every module's exports
  and their types). A program of one module gets a `Context` saying so,
  and every backend then emits exactly what it emitted before there were
  modules.

### Main functions

- **`load(path) -> [Module]`** — every module the program needs,
  dependencies first and the program itself last, parsed, symbolized
  with one numbering across the whole program, and with every import
  resolved. Raises `Module_error` for a missing module or a cycle.
  Before the modules are made ready, `with_splash` hands the program's
  own module to `splash.ml`; `~splash:false` (the language server)
  leaves it out.
- **`read_file(path) -> Module`** — one file, lexed and parsed, and
  nothing else: what `--no-typechecking` stops at, which is why nothing
  a program imports is opened under that flag.
- **`module_file directory name info`** — the file a module name means
  and whether it declares an **external** module: `sys_external.pyk`
  before `sys.pyk`, refusing a name that has both.
- **`check_declaration stmts path`** / **`check_boundary_type`** — a
  declaration file holds public signatures and nothing else, and a
  signature may not name a function type or a type variable.
- **`implementation_name name target`** / **`implementation_path`** —
  what an external module's implementation is called on a target
  (`sys.py`, `sys.js`, `sys.c`, `Sys.java`, `sys.ml`), and that file,
  checked to exist.
- **`external_sigmap stmts`** — an external module's exports, taken from
  what it declared: there is no body for the checker to work them out
  from, so nothing is checked and nothing is inferred.
- **`class_name stem`** — the Java class (and file) name for a stem,
  `foo_bar` → `FooBar`. Naming a module's file is this module's
  business; `target_java.default_class_name` is this.
- **`check_publics(stmts) -> {name: info}`** — what a module exports,
  refusing a name exported twice and an exported name bound twice.
- **`resolve_imports(module, loaded) -> Module`** — each plain import's
  `fields` filled in from the imported module's public names, each
  selected name checked to be exported, and every name an import brings
  in checked for a collision with the module's own or with a builtin.
- **`make_sigmap(stmts, tmap) -> {name: Type}`** — a checked module's
  exports and their types: the input the next module is checked against.
- **`context(units, unit) -> Context`** — one module's `Context`.
- **`module_name(path)` / `module_path(directory, name)`** — the file a
  module name means, and back. A module is looked for beside the file
  that imports it.

---

## `submodules.ml`

**Submodules, made plain.** A name with a dot in it, `def mymod.foo`, is
in the submodule `mymod` of its file. This pass, run by `module.ml`'s
`prepare` before the sugar, gives every dotted name the plain name it
compiles to -- the parts joined by `__`, a capital kept for a datatype or
a constructor, an overload's qualifier in front -- and turns an import
naming a submodule into the `from` line taking its public members. It
works on the module's tokens and parses it again, so expressions,
patterns and types are covered by one rule. The REPL calls it per
entry, with the earlier entries as `context`.

**Design, in depth:** [modules.md](modules.md), "Submodules".

### Data structures

- **`Error`** -- a refusal and where, reported as a `Module error`.
- **`table`** -- a module's dotted names, each with its plain name;
  `Module.t`'s `dotted` field.

### Main functions

- **`module_ ?context tokens stmts declarations imported`** -- one
  module rewritten, its declaration half with it, and its table.
- **`root name`** -- the module an import's dotted name reaches.

---

## `splash.ml`

**tinyweb's splash screen, called where a program can play a sound.** A
browser plays no sound before the reader has clicked or pressed a key,
so a program any of whose modules can call tinyweb's `play`,
`play_file`, `sound.start` or `sound.tone` gets `tinyweb.splash()` as the last statement of its own
top level -- after an import of tinyweb, under a name the module does
not use, where it has no plain one. "Can call" is syntactic: a module
names one through a plain import of tinyweb, or uses one it took with
`from` -- by the plain name submodules.ml gave it (`sound__start`),
since the pass runs after that one, and an import of `tinyweb.sound`
becomes a `from` line taking every member, used or not. Runs inside `module.load`, on the parsed modules,
before the sugar is removed and anything is symbolized, so the call is
checked and compiled like one the program wrote, on every target and
the interpreter. The REPL has no end of a top level, and does not run
it.

**Design, in depth:** [libraries.md](libraries.md), "The splash screen".

### Main functions

- **`program name file modules main -> [stmt]`** -- the main module's
  statements, with the call (and the import) added where the program
  can play.

---

## `desugar_args.ml`

**Default parameters and named arguments, removed.** A default becomes
a generated zero-argument `def` in the block the definition is written
in, and an omitted argument becomes a call to it; a named argument is
put back in its parameter's position. What comes out is ordinary
Pyking, so the checker, the tail-call pass, the interpreter and all six
backends need nothing — which is why every target supports the feature.

It runs inside `module.load`, before `symbolize`, and separately in the
two front ends that do not go through `module.load`: the playground's
single-file path and the REPL. See
[desugar_args.md](desugar_args.md) for the design, and PYKING.md for
what the sugar means.

### Data structures

- **`parameter`** — one parameter of a definition the pass has seen: its
  name, and its default, where it has one: `Generated` with the name of
  the generated `def` holding it, or `Literal` with the literal written
  at each call.
- **`meta`** — what a call needs to know about the definition it
  reaches: its parameters, whether the module exports it, and for a
  constructor whether it is its datatype's only one (`sole`).
- **`module_info`** — one module: its definitions, the set of other
  names its top level binds, and whether it is written in another
  language.
- **`signatures`** — the same for every module desugared so far,
  threaded through a program in dependency order. Opaque outside the
  module.
- **`denotation`** — what a name means where a call uses it:
  `Definition`, `Binding` or `Imported`. The pass resolves names itself,
  because applying the wrong function's defaults would be silent.

### Main functions

- **`desugar signatures name stmts`** — rewrites one module, and answers
  with what the next one may use. A module already in `signatures` is
  one being extended an entry at a time, which is what the prompt does.
- **`external_module signatures name`** — records a module written in
  another language, so a call into it refuses the sugar by name rather
  than by absence.
- **`generated_name name`** — whether the pass made this name up, which
  is what keeps the REPL's `:ls` from listing it.
- **`block` / `rewrite` / `expression`** — the walk: a block's `def`
  names are hoisted first, each definition's generated defs are emitted
  immediately before it, and every call is resolved against the scope.
- **`inlined` / `default_of`** — whether a default is a literal written
  at the call rather than a generated def.
- **`constructed`** — one construction with its arguments in position
  and labelled with their fields; **`updated`** — one written with
  `..base`, its missing fields read from `base` by name.
- **`ordered`** — the full positional argument list one call supplies,
  filling each omitted parameter with its literal or a call to its
  default. Answers
  nothing where the call says nothing the sugar has to act on, so an
  ordinary arity mistake is left to the type checker's own words.

---

## `analyses.ml`

**Static analyses over the parsed AST**, run between the parser and
anything else, for every mode. Errors are `Analysis_error (info, message)`.
`Effects` is the exception to "for every mode": it is not run by the
driver at all, but asked for by the two backends whose host language
leaves evaluation order unspecified.

**Design, in depth:** [analyses.md](analyses.md).

### Data structures

- **`Binding(kind, info)`** — what the name environment records: which
  kind of binding introduced a name (`MUTABLE`, `BINDING`, `PARAMETER`,
  `LOOP_VAR` — a `for` variable or a `loop` accumulator —,
  `PATTERN_VAR`, `FUNCTION`, `BUILTIN`) and where. The kind
  is what makes an error say *what* the name is; `info` is what lets it
  point at the other line.
- The **builtins** are `builtin.ml`'s rather than this module's.
  Pyking's grammar has no notion of one, so `Builtin.names` is seeded
  into the top-level environment here, in `typesystem.ml` and in
  `interpreter.ml`; that is what lets every *other* unbound name be an
  error.
- **`Effects(stmts)`** — which of the program's functions can end up
  printing, by a fixed-point walk of the call graph; `may_print(expr)`
  answers for one expression. A call whose target is not a known `def`
  is assumed to print if anything in the program does, since
  overestimating costs a temporary and underestimating prints in the
  wrong order. The walk stops at a lambda: building a closure prints
  nothing, and the call that runs its body is an ordinary call wherever
  it is written. `target_ocaml.ml` and `target_c.ml` use it to decide
  which operands need their order pinned down (see
  [target_ocaml.md](target_ocaml.md) and [target_c.md](target_c.md),
  "Evaluation order"); it lives here rather than in either because it is
  an analysis of the Pyking AST, with nothing target-specific in it.

### Main functions

- **`analyze_mutability(stmts)`** — the entry point. A single recursive
  walk carrying a binding-kind environment, enforcing the two rules a
  type cannot state: `:=` may only name a `var`, and a `var` may not be
  shadowed (which is what keeps `:=` unambiguous). It runs *after*
  `typesystem.ml`, so every name it meets is already known to be bound,
  and it descends into an expression for one reason only: a lambda's
  parameters are bindings, so the no-shadowing-a-`var` rule has to reach
  them (**`analyze_lambdas`**). It still looks for no mutation there,
  since no expression mutates anything.
- **`bind(env, name, kind, info)`** — every binding form funnels through
  here, which is where the no-shadowing-a-`var` rule lives.
- **`analyze_stmt(s, env) -> env`** — returns the environment its
  statement leaves behind; that is how a sequence accumulates bindings.
  **`analyze_scope(stmts, env)`** deliberately discards it, and that
  discarding is the whole of lexical scoping here.
- **`analyze_stmts(stmts, env)`** — binds every `def` in the block
  *before* walking any of it, which is what makes functions usable ahead
  of their definition, and the one departure from binding in source
  order.
- **`block_functions(stmts)`** — the `def`s at the top of one block, as
  name → node, refusing two of the same name; with
  **`check_no_function_clash`** it enforces the two rules that make a
  hoisted name unambiguous. Both `typesystem.ml` and `interpreter.ml`
  import it rather than restating the rules.
- **`apply_signatures(stmts)`** — folds each `def name : type` line
  onto the definition it describes and drops the line. A signature is
  another spelling of the annotations a header could carry, so after
  this there is one shape for every later stage to read: a backend that
  refuses a type it cannot represent needs to know nothing about
  signatures. Run by `pyk.ml` after the `pyking` target has printed, so
  that output still shows the program as it stands — and by the
  playground's own driver (`src/web/pyking_web.ml`), which repeats `pyk.ml`'s front end
  and has to gain each step it gains. Only well-formed
  pairings are folded — a signature naming no definition is left for
  `typesystem.ml` to refuse in its own words.
- **`symbolize ?start stmts -> [stmt]`** — gives every node a unique
  integer `sym`, post-order from `start` + 1 (`0` means "not
  symbolized"). Unlike the analysis it *rewrites*: nothing is mutated,
  so it rebuilds the tree, threading the counter through as a value. It
  is one case per constructor, so a node added to `syntax.ml` needs a
  case here or it keeps symbol `0`. Existing
  symbols are kept and new ones continue past the highest, which makes it
  safe to run twice. `start` is what makes one numbering span a program
  of several modules; `highest_sym stmts` is what the next module
  continues past.
- **`all_functions stmts`** — every `def` in a program by name. It
  exists for `effects`, and folds over `walk.ml`'s `children`, as do the
  backends' own whole-program questions.

---

## `walk.ml`

**One generic traversal of the AST**, for the passes that ask a question
of a whole subtree rather than of one node kind: which functions can
print (`analyses.effects`), whether an expression holds a call (the
interpreter's call-free table), whether a name is used as a string (the
C and Java backends).

### Data structures

- **`node`** — any AST node, whatever its type: `NExpr`, `NType`,
  `NPattern`, `NListRest`, `NCompClause`, `NTarget`, `NParam`,
  `NLoopIter`, `NMatchCase`, `NStmt`. What a traversal that does not
  care which kind of node it is looking at carries.

### Main functions

- **`children n`** — one node's immediate children, in the order
  `syntax.ml` declares the fields they came from. This is the whole
  module; everything else is a fold over it.
- **`fold f acc n`** / **`exists p n`** — over a subtree, pre-order;
  **`fold_stmts`** / **`exists_stmts`** over a statement sequence.
- **`name_field n`** — the value of a node's `name` field, where it has
  one. Fourteen node kinds do; a `PText`'s captured middle (`rest`) and
  a `TForall`'s bound variables (`vars`) deliberately do not, so neither
  counts as an identifier for `opt_tailcall.ml`'s "does this program
  write this name" tests.

A node kind added to `syntax.ml` needs a case in `children`, and nothing
but a pass that would have looked inside it will notice if it is missed.

---

## `typesystem.ml`

**The type checker.** Run for every mode and every target: Pyking is
statically typed, so a program it refuses is refused. It is also the
only pass that checks *names* — its environment is a scope, so it raises
`Analyses.Analysis_error`, in that module's own words, for a name it
cannot find.

What it means for a *program* is PYKING.md's "Type checking" section;
this file is how those rules are applied.

**Design, in depth:** [typesystem.md](typesystem.md) (the module
itself); [type_inference.md](type_inference.md) (the deferred-checking
scheme specifically).

### Data structures

- **`tmap`** — the result: a map from a node's `sym` to the type worked
  out for it. It is a field of the `store`, which is threaded and handed
  back everywhere already, so it needs no mutation of its own. Every expression gets an entry, not just the
  annotatable constructs, which is what lets `target_ocaml.ml` read types
  back instead of inferring them again. A `SFunctionDef`'s entry is its
  *function* type, not its return type. Entries are written through
  `record`, which **merges**: a function checked at two argument types
  has two answers for everything inside it, and both are true.
- **`Store`** — everything inference has worked out, as one immutable
  value threaded through the pass exactly as the environment is: where
  each definition was written, what has been inferred about it, which
  definitions are being checked right now, and what the innermost
  inference has gone through (`Instance`, `Use`, `Frame`). Nothing in it
  is ever written to; an update rebuilds the one field that changed, and
  a nested inference "ends" by the caller simply using its own store
  again.
- **`Inferring`** — stands in for a declared return type while one is
  being worked out; a `return` checked against it contributes its type to
  the store's frame instead of being compared with one.
- **`acc_type`** — what the loop the statement being checked belongs to
  carries, threaded beside the declared return type and `None` where
  there is no such loop. A bare `loop:` carries unit, so `None` and
  `()` are different answers: the first says there is no loop at all,
  which is what refuses a `break` outside one.
- **`env`** — name → `Type`, and nothing else: a name it does not hold
  is a name not in scope. Used immutably: a binding hands what follows
  it an extended copy. The four host operations are in it at their
  `TBuiltin` type, callable but never a value, because none of them
  fits a `TFunction`.
- **`check_pattern` / `agree`** — patterns are checked against the type
  they match and answer what they bind; `agree` is what two branches,
  two list elements or two meetings of one type variable must reach.
  Whether a `match` covers every value is not this pass's question but
  `exhaustive.ml`'s, asked once the types are worked out
  (`check_matches`); until then every `match` is taken to be total, so
  a `match` whose every arm returns ends its block.
- **`types` / `datatypes` / `constructors`** (store fields) — every
  datatype name in scope as the source spells it (`Tree`, `m.Tree`) and
  the canonical name it means (bare for this module's own, `module.Name`
  for another's), each datatype's parameters and its constructors' field
  types, and each constructor's datatype. Filled once per module by
  `declare_datatypes`, before the first statement is checked, from the
  module's own `datatype`s and the `TData` entries of its imports'
  sigmaps. A field with no type written is a metavariable, recorded in
  **`field_defaults`** under its default's def, and **`field_default`**
  settles it where `check_stmt` reaches that def. A written annotation is read through `resolved`, which
  replaces every datatype name with the canonical one and refuses one
  that is unknown or applied to the wrong number of types.
- **`operator_of` / `binop_rows`** — an operator's spelling and its
  rows, one per operand type it accepts. A *list* because operators are
  overloaded: `==` relates two `Int`s, `Float`s, `String`s or `Bool`s,
  `+` adds two numbers or joins two Strings (lists have a case of their
  own), and the words `and`/`or`, and `xor`, are logic on Bools and
  bitwise on Ints.
  Both operands must match the same row. A `+` whose operands nothing
  has decided is left open in `pending_plus` and settled by
  `settle_plus` (docs/typesystem.md).
- **`alternative(expr, left, right)`** — what to write instead, where
  the mistake has an obvious cure: `string(n)` for a String `+` an Int,
  `and` for `&` on Bools, `&` for `&&` on Ints. `1 & 'a'`, which nothing
  accepts, is offered nothing.
- **`Type_error (info, message)`** — a type error, or the floor:
  `Construct is not supported`, raised for everything outside the
  fragment. That floor is deliberate — a checker that quietly accepted
  what it had not reasoned about would be worse than one that says where
  it stops.

### Main functions

One function per AST datatype, each taking a node of exactly that type
and returning exactly one kind of answer (the signatures are written out
OCaml-style near the top of the file):

- **`type_check(stmts, sigmaps=()) -> (tmap, qmap)`** — the entry
  point. One module in, the types it worked out back, and beside them
  what every call it resolved denotes; `sigmaps` pairs the name of
  every module this one imports with what that module exports, at what
  type, and whether it is implicit, which is all of it this check can
  see.
- **`import_env(stmts, env, store) -> Env`** — what a module's imports
  bring into scope, put there before the first statement is checked
  since an import is a declaration of the module rather than a statement
  in its sequence. Each binding keeps whether it was written
  `implicit`, which is what an unqualified call and the implicit search
  look through a module for. **`available(module, info, store)`** is
  the refusal a file checked on its own gets.
- **`check_exports(stmts, tmap)`** — the other direction: a module that
  exports a name whose type the source does not write down is refused.
  An exported `def` is fully annotated or carries a signature line, and
  an exported `=` binding annotates its name.
- **`check_stmts(stmts, env, tmap, return_type, acc_type, store) -> (Type,
  Store)`** — a block's type: its last statement's (`env` is not
  returned; a block is a scope). Calls `declare_functions` first.
- **`check_stmt(stmt, env, tmap, return_type, acc_type, store) -> (Type, Env,
  Store)`** — the type of the value a statement *supplies*, the
  environment the statements after it are checked in, and the store.
  That single question — what value does this supply? — is why a branch
  that `return`s, a branch that `break`s and a branch that ends in an
  expression compare without any of them being a special case: a
  `return` supplies the function's type, and a `break`/`continue`
  supplies nothing at all, since neither reaches the end of its block.
  `SVar` and `SMutate` supply unit: a
  `var` has its initializer's type, whatever it is, and a `:=` must give
  the type the declaration fixed. Neither says anything about
  *mutability* — that is `analyses.analyze_mutability`'s.
- **`check_turn(body, turn_env, tmap, return_type, accumulator, store)
  -> (Type?, Store)`** — one pass over a loop body: what it supplies is
  what the next turn carries, and `None` where every path through it
  jumps. A loop with an accumulator holds that answer to the
  accumulator's type (**`carry_error`** is the refusal); one with none
  asks nothing of it. Either way the loop's own type is the
  accumulator, which is what it is worth however it stops. A `return`
  written in the body leaves the enclosing function, so the frame comes
  back as it went in.
- **`ends_every_path(stmts)` / `endshere(statement)`** — whether every
  path through a block jumps (`continue`, `break`, `return`),
  structurally: an `if` or a `match` counts when all its branches do,
  and a `match` has to cover its subject as well. `check_stmts` uses it
  to know that what follows is unreachable.
- **`check_target(target, type_, env, tmap, store) -> Env`** — a binding
  target, one name or a tuple taken apart; a destructuring target
  requires a tuple type of the same length.
- **`check_expr(expr, env, tmap, store) -> (Type, Store)`** — records
  into `tmap`; `expr_type` holds the rules themselves.
- **`check_function`, `function_type`, `check_param`** — a `def` that
  wrote its whole type down is checked here, where it is written; its
  type is a `TFunction`.
- **`check_lambda(info, params, body, env, store) -> (Type, Store)`** —
  a lambda. Lambda-bound and so monomorphic: each unannotated parameter
  is a metavariable, a type variable written in one is a metavariable
  too (shared by every parameter naming it), and nothing generalises the
  result. Deferred inference is not reached at all — that machinery is
  keyed by a definition's symbol.
- **`candidates_for` / `resolve_overload`** — an overloaded call. The
  arguments are checked once and each `q::name` in scope is tried
  against what they turned out to be, in a store of its own; exactly
  one fitting resolves it. See [overloading.md](overloading.md).
- **`discharge` / `resolve_implicit`** — an implicit parameter. Every
  *implicit* binding whose base name is the parameter's is tried, with
  its own implicit parameters set aside as obligations discharged in
  turn, in the scope of the call. See [implicits.md](implicits.md).
- **`adapted`** — the same, for an *explicit* argument: a function
  carrying implicit parameters, passed where a type without them is
  wanted, has them supplied here. Tried where an argument does not fit
  its parameter and before the mismatch is reported.
- **`without_implicits(type_)`** — the type a definition has once its
  implicit parameters are ordinary ones, which is what every stage
  after `elaborate.ml` sees of it. Read by the backends' sigmap and by
  the pass itself, so the two cannot disagree.
- **`declared_type` / `infer_call` / `infer_definition` /
  `inference_group` / `body_result`** — the deferred half. A `def` that
  did *not* write its type down is put aside with `TUnknown` in place of
  what it did not say, and worked out the first time something calls it
  — from its *body*, not from that call: every parameter goes in as a
  metavariable and the body's own demands solve them. `inference_group`
  is which definitions are done together (the ones that name each
  other), and `Store` is what carries the answers: an immutable value
  threaded like `env`, so a definition is worked out once and every
  later call uses what came out. See
  [type_inference.md](type_inference.md).
- **`unify` / `prune` / `zonk` / `occurs` / `meta_age` / `instantiate`**
  — the unification. First-order and eager: `unify` is called where a
  type is *demanded* — a call's arguments, an operator's operands, two
  branches, a pattern against its subject — and answers there, so there
  is no constraint store and no solver pass. `store.solutions` holds
  what has been solved, `zonk` reads it back, `occurs` refuses a type
  that would contain itself, and `meta_age` decides which of two
  metavariables is solved to the other — the younger, so a variable
  belonging to an enclosing scope keeps its identity.
- **`generalise` / `free_metas` / `verified` / `verifying`** — the type
  variables. What the body left unsolved is what it never had to decide,
  so it is bound by one `all` at the top — *except* what the scope the
  definition was written in already held (`free_metas`), which is
  Hindley-Milner's side condition and the one place generalising is
  unsound rather than merely imprecise. `verified` then checks the body
  again with the variables rigid before the scheme is adopted; where
  that fails, the definition keeps its monotype, which is how the four
  overloaded builtins are handled at all. See
  [type_inference.md](type_inference.md#9-what-is-left-of-ad-hoc-polymorphism).
- **`one_type` / `agree` / `accepts` / `satisfies`** — agreement.
  `one_type` is the single type every way out of a body gives, unifying
  them one by one so a base case returning `[]` settles against a branch
  returning `[Int]`, and refusing two that cannot be one type at the
  later one; `agree` is that rule for two branches; `accepts` decides
  nothing and is for the two places nothing may be solved — a written
  annotation, and `verified`'s re-check — being `same_type` plus the use
  of a scheme at an instance of itself (`instance_for`); and `satisfies`
  is `unify` with `accepts` behind it, for where a declared type meets a
  supplied one.
- **`check_call`, `check_builtin_call`** — anything of function type may
  be called; the four builtins are checked at the call site, where their
  signatures live.
- **`check_annotation(annotation, actual)`** — an annotation is
  *checked*, never replaced. That is the difference between an annotation
  and a comment.
- **`same_type a b`** — structural equality. Never `=`: every `T*`
  constructor carries `info` and `sym`, which `=` would compare too.
- **`declare_functions(stmts, env, store)`** — every `def` of a block
  bound before any of it is checked, through `analyses.block_functions`.
  That one step is recursion, mutual recursion and forward references.

---

## `exhaustive.ml`

**Every `match` matches every value, and every case is reachable.** Run
by the checker at the end of `type_check` (`Typesystem.check_matches`),
since what a pattern can match is a question about its type, and the
types are only settled then. Its refusal is raised as `Refused` and
reported as a `Type error`. See [exhaustive.md](exhaustive.md).

### Data structures

- **`head`** — the outermost shape of a value: one constructor of a
  datatype, `true` or `false`, a tuple of n, an Int or String literal, a
  string split around a prefix and a suffix, a list of exactly n, or a
  list of n or more.
- **`pat`** — a pattern as the algorithm reads it: `Any`, a shape and
  its parts (`Con`), `Or`, or a list with a rest marker (`Rest`), whose
  shapes depend on the column it is in.

### Main functions

- **`check datatype tmap stmts`** — every `match` in `stmts`: each case
  must be useful after the unguarded cases above it, and `_` must not
  be useful after all of them. `datatype` answers a canonical name's
  declaration, and `tmap` gives each subject's type.
- **`useful datatype rows q types`** — the core: a value `q` matches and
  no row does, as one pattern per column, or `None`. A column whose
  shapes are all of its type's specializes on each; one whose shapes are
  not takes the default rows and names a shape no row has.
- **`covers datatype type_ patterns`** — whether the patterns match
  every value of a type. The OCaml backend asks it of the arms OCaml can
  see, to know whether OCaml needs a catch-all.

## `type_experiment.ml`

**An alternative type checker**, a fragment of one, run instead of
`typesystem.ml` by `pyk --type-experiment`. It covers integer literals,
names, `+`, and the bindings those need; everything else raises
`Type_error (info, "Construct is not supported")`, in `typesystem.ml`'s
own words, and an unbound name raises `Analyses.Analysis_error` so the
driver reports it as a `Name error` exactly as it would otherwise.

It exists to be grown against real programs, and the flag is how it is
run. Its shape is `typesystem.ml`'s and is the one to keep as it grows:
one function per AST datatype, each taking a node of exactly that type;
an `env` mapping a name to its type, used immutably; and one `tmap`,
from a node's symbol to the type worked out for it, returned as the
pass's result.

`pyk.ml`'s `format_error` has a line for this module's `Type_error`
saying the same word as the real checker's: the flag swaps which checker
runs, not how a refusal reads.

---

## `opt_tailcall.ml`

**Tail calls into loops.** One pass from the AST to the AST, run after
the type checker and only over a program it accepted — the types are
what decide which groups can share a loop, and what a slot a narrower
member does not fill is entered with. What `-t pyking` prints and what each
backend compiles are then the same program.

**Design, in depth:** [optimization.md](optimization.md).

### Data structures

- **`Callee`** — a call the loop being built stands for: its state tag,
  and how many arguments it gives (which need not be how many the loop
  carries).
- **`Context`** — what rewriting one body needs: the calls it stands
  for, the slots the loop carries, and the names the program uses.
- **`Pass`** — the two things filled in rather than rebuilt, for the
  reason `typesystem.record` fills one table: the checker's `tmap`,
  extended for the annotatable nodes the pass builds, and the symbols
  those entries are keyed by.

### Main functions

- **`optimize(stmts, tmap) -> ([Stmt], {Int: Type})`** — the entry
  point. It never rejects a program: one it cannot improve comes back as
  it was. The table comes back extended, since the checker will not run
  again to say what the new nodes are.
- **`tail_calls(func, names)`** — the names `func` calls in tail
  position. Tail position is PYKING.md's own, and the walk stops at a
  nested `def` (whose tails are its own) and at a `for`/`while`/`loop`
  (where a `break` would belong to that loop instead).
- **`rewrite_block` / `rewrite_tail` / `rewrite_inner` /
  `going_on`** — the rewrite: a recursive call becomes what the block
  ends in, which is what the next turn carries, and anything else
  becomes a `return` (leaving the loop and leaving the function are one
  thing here, since the loop *is* the function's body).
- **`hoist` / `goes_round` / `always_returns` / `_Decline`** — going
  round can only be said by ending a block, so a call in a statement
  that is not the block's last is restructured first: a guard that
  always returns takes what follows it into its `else`. Where that
  cannot be done the rewrite declines and the function is left as the
  recursion it was.
- **`rewrite_self`** — a function that calls itself, as a loop carrying
  its own parameters under their own names.
- **`merge`** — a mutually recursive group, as one `tail_groupN` worker
  carrying a `state`, with each original left as a wrapper. The
  accumulator is as wide as the widest member; a narrower one carries
  the slots it does not fill forward inside the loop, and enters with a
  zero of their type at its wrapper.
- **`shared`** — the gate, and the only part that reads types: the
  members must agree per position and on what they answer with, every
  padded slot must have a zero to write, and each member must have one
  definite type. A group failing any of these is left as recursion.

---

## `builtin.ml`

**The names a Pyking program may call without binding them**, and what
every stage has to agree about each one: its arity, whether calling it
can be observed outside the program, and what it does. One table, read
by the checker, the interpreter and every backend — which is why it
sits before `analyses.ml` in the module graph.

Backend-agnostic by construction: no host code of any kind, and nothing
from the interpreter.

**Design, in depth:** [builtin.md](builtin.md).

- **`t = { name; min_args; max_args; crosses_host; doc }`** — one
  builtin. `max_args` is `None` for a variadic one, which is the whole
  of what makes `print` take any number of arguments; there is no
  separate flag that could disagree with the bounds.
- **`names`** / **`pure_names`** — every builtin's name, and the ones
  that do *not* cross the host boundary, which is exactly the list a
  backend with no translation for them has to refuse.
- **`lookup(name)`** — the entry a name denotes, or `None` for an
  ordinary Pyking name. `typesystem.ml` reads the arity from it.
- **`crosses_host(name)`** — whether the call leaves the program. Every
  backend has one arm gated on this; `interpreter.ml` performs the
  operation through its host there instead.
- **`float_text(x)`** — a Float as `print` and `string` write it: the
  shortest decimal that reads back as the same double, always with a
  point or an exponent. It is here rather than in a backend because
  every backend has to agree about it, and each emits the same algorithm
  in its own host language — no two hosts spell a double alike. See
  [builtin.md](builtin.md), "How a Float is written".
- **`parse_int(text)` / `parse_float(text)` / `truncate_float(x)`** —
  what `int` and `float` make of a String, and `int` of a Float: Pyking's
  own grammar, in the signed 32-bit range (`int_min`, `int_max`), with
  `None` -- or 0 -- where there is no answer. The interpreter calls them;
  every backend emits the same rules as a helper of its own, since no
  host's parser reads the same strings. See [builtin.md](builtin.md),
  "Conversions".

The formatting rules pinned here: arguments formatted individually and
joined with single spaces, then a newline; a string bare on its own and
quoted inside a list or a tuple; an integer in base 10; unit as `()` —
never the host's own word for "no value"; a boolean as `true`/`false`,
Pyking's spelling rather than Python's.

Two things are deliberately elsewhere, because neither can be said
without a type or a value: which argument *types* a builtin accepts is
`typesystem.ml`'s, since those are settled by unification rather than
comparison, and what a builtin computes is `interpreter.ml`'s. Write a
new builtin's entry here first; the checker, the interpreter and each
backend then bind it.

---

## `names.ml`

**The spelling rules for a qualified name.**

`int::leq` is one identifier that happens to hold a `::`, so this is
the only place one is taken apart -- the lexer, the parser, the type
checker and `elaborate.ml` all ask here rather than each splitting a
string of its own.

**Design, in depth:** [overloading.md](overloading.md).

### Main functions

- **`is_qualified name`**, **`qualifier name`**, **`base name`** -- the
  parts.
- **`renamed name`** -- the plain name a qualified one compiles to,
  `int::leq` -> `int__leq`. Deterministic, which is what lets two
  modules agree on it with no shared state.
- **`field name`** -- the part of a dotted name after the module it is
  reached through, so a key like `mod.int::leq` can be asked the
  questions above.

---

## `elaborate.ml`

**Overloading and implicits, removed after the type checker.**

The checker changes nothing; what it writes down is `qmap`, and this
pass rewrites the program by it. Three things happen: every qualified
name becomes the plain one `Names.renamed` gives it, every call the
checker resolved names the definition it reaches, and every implicit
parameter becomes an ordinary argument -- built from a *lambda* where
the value filling it takes implicit arguments of its own. What comes
out is ordinary Pyking, so no backend and not the interpreter knows
either feature exists.

**Design, in depth:** [implicits.md](implicits.md),
[overloading.md](overloading.md).

### Main functions

- **`program qmap tmap stmts -> ([stmt], tmap)`** -- the entry point.
  Every node it builds is given a symbol of its own and its type
  recorded, from what `qmap` carried: the checker does not run again
  (implicits.md, "Why one check is enough").
- **`generated_name name`** -- whether the pass made this name up,
  which is what keeps a generated lambda's parameter out of the
  prompt's listing.
- **`check_no_rename_clash stmts`** -- refuses a program that binds
  both `q::b` and the plain name it compiles to.

---

## `release.ml`

**`--release`, as a pass.** Every call to the builtin `debug` removed,
arguments and all: one in value position becomes `()`, under the call's
own symbol so its recorded type still applies, and one written as a
statement is dropped wherever that leaves its block's value as it was --
and otherwise left as the statement `()`, which every backend compiles
to nothing. The builtin is told from a definition a program named
`debug` by `tmap`: the checker records a type for a callee it resolved
to a definition and none for a builtin. Runs after `elaborate.ml` and
before the tail-call pass, for every module.

**Design, in depth:** [release.md](release.md).

### Main functions

- **`program tmap stmts -> [stmt]`** -- the entry point: one module with
  its calls to `debug` removed.

---

## `prune.ml`

**What a program uses of the modules it imports**, for the C and Java
targets, which compile a subset of the language and must not refuse a
library for a function the program never calls. Every module but the
program's own keeps the definitions its importers name, the ones its
top-level statements name, and the ones those call -- closed over each
kept body, by name -- and every statement that is not a definition.
Every import is narrowed to the names the importing module uses, which
is what decides which declared names the C backend declares and the
Java backend checks. The browser bundle's `pykAnalyze` reads the same
narrowed imports to tell whether a program reads standard input.

**Design, in depth:** [modules.md](modules.md), "What a program uses".

### Main functions

- **`program units -> units`** -- every module of a program, dependencies
  first, pruned from the program's own module backwards, so a module is
  pruned once everything that imports it has said what it needs.

---

## `interpreter.ml`

**The interpreter: a resumable machine that runs the AST directly.**

Every other backend answers "what would this program look like in C, in
Java, in Python?". This one answers "what does this program *do*?", in
Pyking's own terms — which makes it the reference for runtime semantics:
where a backend disagrees with it, the backend is wrong.

It runs exactly the fragment `typesystem.ml` accepts. The gate is the
checker itself (`check`), the same arrangement `target_ocaml.ml` uses, so
there is no second list of supported constructs to keep in step.

**Design, in depth:** [interpreter.md](interpreter.md).

### Why a machine

A recursive `eval` would be shorter and a dead end: a debugger, the
playground and a DAP adapter all need execution that can be paused,
inspected and resumed, and a recursive walker can only be paused by
blocking a host thread. So execution is a small-step machine, `step(State)
-> State`, driven from a flat loop. Three properties follow, and all
three are design rather than accident:

- **Depth costs heap, not host stack**, so a deep Pyking recursion cannot
  overflow Python's stack — and an explicit `max_depth` (10 000) turns a
  runaway one into an ordinary Pyking error rather than an out-of-memory
  kill.
- **A block does not grow the continuation chain**: sequencing is an
  *index* into a statement list, so re-entering a block replaces its
  continuation instead of stacking another.
- **Errors are a machine state** (`CFailed`), not a host exception thrown
  through `step`, so a debugger can stop *at* an error with the frames
  intact.
- **Waiting is a machine state too** (`CWaiting`): a host whose answer
  is not ready raises `Wait n` from an external call, the machine stops
  there, and `resume` goes on with the answer (`waiting`,
  `runner_waiting`; a waiting callback raises `Suspended`). This is how
  tinyweb's `sdelay` waits for a page in a browser.

### Data structures

- **`Value`** — `VInt`, `VFloat`, `VString`, `VBool`, `VUnit`, `VList`, `VTuple`,
  `VClosure(name, params, body, env)`, `VBuiltin(name)`, and
  `VUndefined(name)` (a hoisted `def` whose definition has not run yet),
  and `VData(constructor, fields)`, a datatype's value, each field with
  its name where it has one -- which is what `x.name` looks up, and why
  `desugar_args.ml` leaves the names on a construction's arguments.
  A lambda is a `VClosure` too, named `lambda`, holding the one
  `SExprStmt` that supplies its body — so applying one goes through the
  machinery a `def` goes through.
  No host objects and no host dictionaries inside a value: the
  representation has to survive being rewritten in Pyking and compiled to
  machine code.
- **`Env(bindings, parent)`** — a persistent chain of frames. `extend`
  builds a new head; `lookup` walks outwards. Pyking's scoping falls
  straight out of it: a block runs in a chain of its own, `=` makes a new
  frame (a rebinding shadows, it never updates), and a `def` captures the
  chain it was created in. Everything `target_python.ml` has to work for
  — renaming shadowed bindings, per-turn factories — is simply what this
  representation does.
- **`Control`** — `CEval(expr)`, `CStmt(stmt)`, `CApply(value)`,
  `CDone(value)`, `CFailed(error)`.
- **`Kont`** — one class per "what to do with the value I am about to
  get": `KSeq`, `KBind`, `KVarBind` (a `var`), `KMutate` (a `:=`),
  `KBinaryLeft`, `KBinaryRight`, `KCallee`,
  `KArgument`, `KElement` (one element of a tuple, a list or a
  constructor's fields), `KField` (the value whose field is read),
  `KGuard` (a case's guard: true runs the body, false tries the cases
  after it), `KBranch` (an `if`
  statement), `KChoose` (an `if` expression), `KLet` (a `let`'s value has arrived), `KDiscard`, `KStartLoop`,
  `KSequence` (a `for`'s list), `KTest` (a `while`'s condition),
  `KIterate`, `KReturnTo`. Each holds `rest`, so
  the chain is a linked list — pushing and popping cost one allocation
  and no copying, and two states can share a tail, which is what makes a
  paused state cheap to keep. Most also hold the `env` their remaining
  work runs in, and the machine restores it when the continuation is
  popped; `KSeq` is the one deliberate exception, since adopting the
  environment it is handed is exactly how a binding becomes visible to
  the statements after it.
- **`Frame(name, info, kont, env, parent, depth, loops)`** — one Pyking
  call: the caller's continuation, environment and loops, and how deep
  this is. This is Pyking's call stack, in the machine's own data.
- **`Loop(node, accumulator, env, kont, parent)`** — one `loop` in
  progress: what a `break`/`continue` needs in order to leave it or go
  round again. A stack of these is the loop counterpart of the frame
  stack, and a call enters with none of its own — a `break` may not
  cross a `def`.
- **`Runtime(host, simple, max_depth)`** and **`State(control, env, kont,
  stack, runtime, loops)`** — the settings a run never changes, kept
  apart from the progress it does. A `State` is a plain value; keeping
  one is how a debugger pauses.
- **`Host`** — one method per builtin that crosses the host boundary, with two
  implementations: `ConsoleHost` (a stream) and `CallbackHost` (a
  function per line — the shape a debugger or a browser worker wants).
- **`Runtime_error (info, message)`** — carried by `CFailed`. Never thrown
  through `step`.

### Main functions

- **`initial_state(stmts, host, env=None, max_depth=…)`** — a machine
  about to run. `env` lets a caller continue an earlier session, which is
  what the REPL passes.
- **`step(state) -> state`** — one small step. Total: every state has a
  successor, including a finished or failed one, which is what lets `run`
  be a bare loop. `step_eval`, `step_stmt` and `step_apply` are its
  three halves-and-a-bit.
- **`run ?steps state -> state`** — step until the machine stops,
  or until `steps` steps have been taken. The bounded form is what makes
  this usable from somewhere that must not block.
- **`run_program stmts host -> state`**, **`initial_state`**,
  **`finished`**, **`result`**, **`failure`**, **`stack_trace`** — the
  embedding API.
- **`run_modules(units, host) -> state`** — a program of several
  modules: each runs in a top level of its own, in dependency order, and
  what it exports is what the ones after it are given. **`module_env`**
  builds a module's starting environment from those exports and
  **`exported_values`** reads its own back out. A module's top level
  runs one statement at a time, each in the environment the one before
  it left, without putting an enclosing scope back afterwards, since
  there is none to go back to; **`runner`** is that sequence as a value
  (`start_modules`, `runner_step`, `runner_done`), which is what a
  debugger steps, and `run_modules` drives it to its end.
  **`load_modules(state, units, exports)`** is the same into a machine
  already running, which is what a REPL entry's imports do, and
  **`bind_imports(state, stmts, exports)`** binds an entry's imports into
  its environment. **`with_host(state, host)`** swaps the host, which is
  how a session gains an external module's implementation.
- **Hosts** -- `console_host` and `callback_host(externals?, debug_line?,
  print_line)`: where `print` and `debug` go, and how an external module
  is reached. `debug` writes to standard error unless a host says
  otherwise.
- **`callback(state, info, callee, args) -> value`** /
  **`apply(state, callee, args) -> state`** — a function value called in
  a machine of its own that shares `state`'s runtime: how a host calls
  back a Pyking function it was handed. An external call hands
  `externals.call` the first, so a host may call back during the call or
  later; `apply` is the same for a finished machine, answering its
  state. `call` and `step` are one recursive group so that `call` can
  run one. The runtime's **`drive`**, where one is given, is how such a
  machine is run to its end: a debugger passes its own, which stops at
  breakpoints in a callback.
- **`statement_at`, `call_depth`, `innermost_call_site`, `calls`,
  `own_bindings`, `with_env`, `assign`** -- what a debugger reads of a
  paused machine: the statement about to start, the calls in progress
  (each with its call site, its caller's environment and the
  environment the function was written in), the names a frame binds
  itself, and a `var`'s cell written.
- **`declare_entry(state, stmts)` / `eval_in(state, stmt) -> state` /
  `eval_statement(state, stmt)`** — running statements in an existing
  machine's environment, which is what a prompt does. `declare_entry` is
  entering a block for a group that is not one: an entry's `def`s come
  into scope together, so two of them may call each other, while a later
  entry is a later group. `eval_in` then runs one statement there;
  `eval_statement` is the two together, for a group of one — the shape a
  debugger's "evaluate in this frame" wants.
- **`_turn(state, loop)` / `_leave(state, loop, value)`** — a turn of a
  loop body, and the end of a loop. `turn` binds the accumulator afresh
  and enters the body with `KIterate` waiting for its value, which comes
  back here — so a turn costs no continuation chain however many turns
  there are, and a loop that never ends never grows. `leave` delivers
  the loop's value where the loop statement stood -- the accumulator
  this turn started with, which is what a `break` leaves with too.
  `finish` is the other end: a loop that ran out of turns is worth
  that same accumulator.
- **`bind_target(env, target, value)`** — binds one name, or takes a
  tuple apart; used by both `KBind` and each turn of a loop.
- **`declare(stmts, env)` / `define(env, node)`** — the two halves of
  Pyking's `def` rule. `declare` puts one write-once cell per `def` in the
  block's frame, holding `VUndefined`; `define` fills it when the
  definition is reached, with a closure capturing the environment *there*.
  That is how a name can be visible throughout its block while a body
  still captures what was bound where it is written — and why using one
  too early says "its `def` has not run yet" rather than "unbound".
- **`mutate(env, name, value)`** — the module's other mutation, and what
  `:=` is: it walks outward for the frame holding the name and
  overwrites that entry. A `var` is declared into a frame of its own
  (`KVarBind`), which is what makes the cell fresh each turn of a loop it
  is written in, and a closure over that frame sees what is written to it
  afterwards — which is what a `var` means.
- **`format_value(value)` / `display_value(value)`** —
  `builtin.ml`'s formatting rules, written iteratively with an
  explicit stack so that a deeply nested value cannot overflow the host's
  stack. The two differ over strings: `print` *emits* text, so
  `format_value` writes a string bare, while a prompt, a list's elements
  and (later) a debugger's variable view *display* a value, so
  `display_value` quotes it.
- **Integers are the host's own.** A Pyking `Int` holds at least the
  signed 32-bit range and overflow is undefined, so nothing here narrows
  a result — there is no wrapping step. See
  [targets.md](targets.md#integers-hold-32-bits-and-overflow-is-undefined)
  for what each host does past that range.
- **`call_free_symbols(node)`** — the one optimisation: an expression
  containing no call can neither suspend nor reach the host, so it is
  evaluated in one gulp by `evaluate` instead of one continuation at a
  time. Which expressions those are is computed once, before the program
  runs, and kept as a set of symbols in `Runtime`. The recursion in
  `evaluate` is bounded by how deeply the *source* nests expressions, so
  it cannot be driven deep by a long-running program. A lambda is
  call-free whatever its body holds: building a closure calls nothing,
  and the body is stepped later, when it is applied.

---

## `plugin_host.ml`

**How the interpreter reaches a module implemented in a target
language**: through its OCaml implementation, compiled with a generated
registration file into a `.cmxs` and loaded into `pyk` with Dynlink. A
value crosses by its declared type (`to_host`, `of_host`), since nothing
else says whether an immediate OCaml value is an Int, a Bool or unit; a
tuple is built as a block of its own, never an array, which the runtime
would flatten for Floats. A plugin is used from beside the
implementation where the digest written there says it was built from
what it would be built from now, and is otherwise compiled into the
cache with `$OCAMLOPT`, which must be the OCaml `pyk` was built by. In
the executable, since it starts a process and loads code.

**Design, in depth:** [libraries.md](libraries.md), "How the interpreter
reaches an OCaml implementation".

### Data structures

- **`unit_ = { name; declared; declaration_path }`** -- one external
  module: its name, every name it declares with its type, and where its
  declaration half is, beside which its implementation is.

### Main functions

- **`load units`** -- loads every module's plugin, refusing one that
  cannot be built or loaded with a `Module_error` at its declaration.
- **`externals units -> Interpreter.externals`** -- the host's way into
  those modules: a value, or a call, by the declared type. A callback
  parameter becomes a curried OCaml function that calls the closure back
  through the interpreter (`to_host`'s `TFunction` case).
- **`build_plugin unit output`** / **`digest unit`** / **`built_from path
  digest`** -- compiling one plugin, what it is built from, and whether
  a plugin was built from that. `pyk plugins` and `make libs` use them.
- **`set_arguments program arguments`** -- `Sys.argv` made what the
  program would have been started with, through
  `caml_sys_modify_argv`, since `sys_external.ml` reads its arguments
  from there.

## `plugin/pyk_plugin.ml`

**The registry a loaded plugin fills in**: `(module, name)` -> the OCaml
value implementing it, as an untyped `Obj.t`. A plugin's generated
registration code calls `register` once per declared name when Dynlink
loads it; `plugin_host.ml` reads it back with `find`. A library of its
own, unwrapped and linked only into the executable, so a plugin compiled
outside this build names it `Pyk_plugin` and finds its `.cmi` in
`share/plugin/`. Its table is mutable because loading a plugin answers
nothing: the plugin's initialisation runs for its effect, and this is
where that effect lands. `after_program f` asks for `f` to run once the
program's top level has ended, and `pyk.ml` runs them
(`run_after_program`) after a top level that succeeded: how a plugin
delivers events to the callbacks it was handed. `on_idle descriptors
handle` asks for the REPL's idle time: `repl.ml` waits on
`idle_descriptors ()` beside standard input and calls `run_idle ()` when
one is ready. `set_directory`/`directory` are where each module's
implementation was found, which `plugin_host.ml` records before it loads
the plugin. It depends on the standard library alone, so its `.cmi`
is the same for every architecture a package ships: a descriptor crosses
it as an `Obj.t`, converted back to a `Unix.file_descr` by `repl.ml`.

---

## `repl.ml`

**`pyk repl`.** A session is a *program being written one entry at a
time*, and the module is built that way: each entry is checked against
what the entries before it left behind, and then run there — in two
environments extended in step, the checker's and the machine's.

**An entry is checked the way it is run**, which is the rule everything
else follows from. An entry is a group: its `def`s are declared together
(`typesystem.declare_functions` for the types, `interpreter.declare_entry`
for the values), so two of them may call each other. A later entry is a
later group — so redefining a name is ordinary Pyking shadowing rather
than the "one `def` per name per block" error it would be inside one
block, a function written earlier keeps whatever it captured, and a
function written now is invisible to one written before it.

**Design, in depth:** [repl.md](repl.md).

The session is `repl_session.ml`'s (below), which the playground's
REPL tab shares: `Session`, `Outcome`, `META` but `:load`, `INCOMPLETE`,
`import_modules`, `submit`, `undefined_name` and `complete` /
`continuable` / `next_indent` are there. This module keeps the editor,
the readers, `:load`, `undefined_message`, the loop, and the terminal's
host (`terminal_host`), which reaches a module implemented in a target
language through its plugin.

### Data structures

- **`Session(seen, state, types, store, kinds, sources, arguments,
  libs, modules, sigmaps, exports, hosted, host)`** — the machine's
  environment, the checker's, and the mutability analysis's, all
  extended in step, plus two records of what has arrived -- and what the
  entries have imported: the modules as the module system prepared
  them, what each exports for the checker and for the machine, and the
  ones implemented in a target language, which `host` reaches. `seen` exists for one narrow reason: `symbolize` numbers a
  tree from the highest symbol already in it, so handing it the
  accumulated statements is what keeps a later entry from reusing an
  earlier entry's symbols — which the machine's call-free table is keyed
  by. `sources` is name → the text that defined it, sliced out of the
  entry it arrived in by the statement's own span: that is what `:edit`
  brings back, and it is the text rather than a printed AST, so a
  definition returns with its comments and spacing intact.
- **`Outcome(session, pending)`** — what a meta-command leaves behind.
  Only `:edit` has anything to put in `pending` (text to place in front
  of the user instead of an empty prompt); every other command returns a
  bare session, which `run_meta` wraps.
- **`buffer_ = { lines; row; col }`** — the entry being typed, as an
  immutable record with pure operations over it (`insert`, `newline`, `backspace`,
  `left`, `up`, …). Everything about *what the text is* can therefore be
  reasoned about without a terminal in sight.
- **`Editor`** — a small multi-line editor over a terminal in raw mode.
  It holds only what is unavoidably stateful: the tty, the history of
  *entries*, and how much of the screen the last redraw used. While a
  plugin waits on descriptors (`Pyk_plugin.idle_descriptors`) -- a page
  `tinyweb.web_init` serves -- waiting for a key is also waiting for
  them: what a ready one runs is written above the entry, with the
  terminal back in its own mode, and the entry is drawn again below it.
  Piped input, which takes the plain reader, lets plugins answer what is
  waiting before each line instead.
- **`META`** — the meta-commands, each `(session, argument, report) ->
  session`, so one that changes the session and one that only reports
  have the same shape.
- **`INCOMPLETE`** — the two things the parser says when it stopped
  because the input *ran out*. That is what makes a block keep reading,
  rather than a trailing `:` being guessed at.

### Main functions

- **`start(format_error, read=None, session=None)`** — the loop.
  `format_error` is `pyk.ml`'s own, so an error made at the prompt is
  reported in exactly the words it would have been reported in from a
  file; the other two arguments let something other than a terminal drive
  the REPL (a transcript test, another front end).
- **`import_modules(session, stmts)`** — an entry's imports first: the
  modules they newly reach are loaded (`Module.load_imports`), checked
  as a program's would be (`check_import`), their plugins loaded and
  their top levels run into the session (`Interpreter.load_modules`),
  and the entry comes back with its imports resolved.
- **`submit(session, stmts, report, source)`** /
  **`check_entry(entry, types)`** — check the whole entry first, then run
  it a statement at a time, stopping at the first runtime error with both
  environments left describing exactly the statements that ran. A
  *refusal* is returned rather than reported, because the caller may have
  something better to do with it than print it; `accept` is the wrapper
  for callers that do not.
- **`undefined_name(error)` / `undefined_message(name)`** — an entry
  refused for naming something that does not exist yet is usually one
  that is still being written, so a `def` that calls an unknown name gets
  the offer to keep editing rather than the error and a lost entry.
  Pressing Escape drops it; anything else hands it back with the text
  intact, which is how two mutually recursive functions are entered
  together — they have to arrive in one entry, since an entry is the
  group whose `def`s are declared before it is checked.
- **`make_reader()`** — the editor when there is a terminal,
  `PipeReader` otherwise: a pipe has no cursor to move and no history to
  walk. Both answer the same two calls, `read(initial="")` and
  `ask(message)`, which is what lets the loop be written once.
- **`complete(source)` / `continuable(source)` / `next_indent(source)`**
  — the three things the editor needs to know about the language:
  whether the input ran out, whether the next line could still extend
  what is there (an `if` with no `else`, whose block may have been on
  the header's line), and how far in that next line starts. Enter submits a single line only when it is complete
  and not continuable. All three are answers rather than guesses: the
  first two are the parser's, and indentation follows the one rule that
  a line *ending* in `:` opens a block.
- **`meta_help`, `meta_ls`, `meta_type`, `meta_edit`, `meta_ast`,
  `meta_tokens`, `meta_load`, `meta_reset`** — the commands. `:ls`
  lists what the session bound as `name = value : Type`, reading the
  values from the machine's environment and the types from the checker's;
  `:type` checks an expression in that same type environment, so it can
  name whatever the session bound; `:edit <name>` puts the text that
  defined a name back in the prompt, so a definition can be grown a piece
  at a time instead of retyped — re-entering it is an ordinary entry, so
  the new definition shadows the old one and whatever was built from the
  old one keeps it.

### The line editor

`Editor` exists because `readline` cannot do the one thing a REPL with
blocks in it needs: recall a *whole* entry. `readline` history is one
line per `input()` call, so pressing Up after defining a five-line
function offers its last line, which is not a program.

Here the buffer is a list of lines: Up and Down move within the entry and,
at its edges, step through the history of entries — so a function comes
back whole and can be edited anywhere in it. Left and Right move through
it a character at a time (across line boundaries), Tab inserts one level
of indentation at the start of a line and completes the word before the
cursor elsewhere (`Repl_session.completions`), Shift+Return finishes an entry without the blank line
(where the terminal distinguishes it from Return — `named` reads both
the `CSI u` and the older `modifyOtherKeys` encodings), Escape abandons
what is being typed, Ctrl-C does the same, and Ctrl-D at an empty prompt
ends the session. Enter submits a single line that parses, and otherwise opens
a new line, already indented to where it belongs; a blank line ends a
block, which is Python's REPL rule and the only one that lets a block
have more than one statement in it.

Backspace inside a line's indentation removes a whole level at a time,
back to the previous stop rather than by a fixed four — indentation *is*
the block structure in Pyking, so a dedent is one thing the user meant to
do, and a line that has drifted off the grid is put back on it.

`read(initial="")` is how text arrives that was not typed here: an entry
handed back to be finished, or a definition `:edit` brought up. From the
first keystroke it is an ordinary buffer.

Drawing is one redraw per keystroke: go back to the top of the last
drawing, clear it, write the entry again, and put the cursor where the
buffer says it is — with the terminal's width in the row arithmetic, so
a line long enough to wrap is still followed correctly.

---

## `target_python.ml`

**The Python backend** — the first one written, the reference for the
others, and the only one that compiles the whole language.

**Design, in depth:** [target_python.md](target_python.md) (what
compiles to what); [target_python_internals.md](target_python_internals.md)
(this module's own machinery — `Scope`, renaming, the loop-capture
factory).

### Data structures

- **The `Py*` AST** — `PyInt`, `PyString`, `PyVar`, `PyAdd`, `PyCall`,
  `PyIf`, `PyFor`, `PyMatch`, `PyAssign`, … Structurally the same shape
  as `syntax.ml`'s, with two deliberate collapses: Pyking's `SLet`,
  `SVar` and `SMutate` all become one `PyAssign`, since Python has no
  immutable-binding distinction; and `SLetStmt` has no node at all, since
  it compiles to an ordinary `PyIf`/`PyMatch` with a `PyAssign` pushed
  into each branch's tail.
- **`Scope`** — Pyking name → the Python name standing in for it. Pyking
  blocks are scopes and Python's are not, so a binding that shadows
  another *within one Python function scope* is renamed (`total` →
  `total2`). `bind`, `lookup`, `block_scope` and `function_scope` are
  the whole mechanism, and it renames only when it must — never inside a
  `def` body or a comprehension, where Python already scopes. Its `used`
  field is every Python name an enclosing block of the same Python
  function scope has been given: the name → name map holds only the
  newest one per Pyking name, so `used` is what stops a third shadow
  being handed a name the first is still reading.

### Main functions

- **`translate_program(stmts, tmap)`**, **`translate_stmt(s, scope) -> (node,
  scope)`**, **`translate_expr(e, scope)`**, plus `translate_pattern`,
  `translate_target`, `translate_case`. Statement translators return the
  scope so a sequence accumulates bindings; a caller entering a block
  discards it, and may answer with a *list* of Python statements where
  one Pyking statement needs several (a `loop` is a variable and a
  `while`). Each `match` ends in `case _: raise NotImplementedError`,
  so a future construct without a translation fails loudly.
- **`SDatatype`'s case and `annotation`** — a datatype as one frozen
  dataclass per constructor (`PyDataclass`) and a `type` alias for the
  union (`PyTypeAlias`), its fields annotated with the checker's types;
  `annotation` quotes one naming a datatype not declared yet unless the
  target is `python14`, whose annotations are deferred.
- **`translate_loop` / `translate_loop_block` / `translate_loop_tail`**
  — a `loop` as `while True` over one variable: the initializer gives it
  its first value and every tail of the body assigns the next, which is
  the same push-into-the-tails shape `translate_value_block` uses for a
  value-form `if`.
- **`pprint_py_program` / `pprint_py_stmt` / `pprint_py_expr`** — `Py*`
  AST → Python source.
- **`declare_functions`** — binds every `def` in a block before
  translating it. Python resolves forward references itself, but a
  *renamed* function has to be renamed before the call above it is
  emitted.
- **`free_names`** and **`captured_names`** — the two analyses that
  carry the scoping story: a scope renames a binding that shadows a name
  its body reads from outside itself, and a rebinding some function
  already captured gets its own Python variable, because in Pyking it is
  a *new* binding.
- **`turn_groups` / `absorbed` / `translate_turn_group`** — a `def`
  written inside a loop is built by a small per-turn factory, so each
  turn's functions keep that turn's values; `def`s that name each other
  are built together. Nothing but `def`s moves — a `return` or a `:=`
  carried into a factory would change what it means. See
  [target_python.md](target_python.md).
- **`bool_kind` / `wrap_print_argument` / `format_helper_name`**
  — Pyking prints `true`/`false` and Python prints `True`/`False`, so a
  printed argument is formatted rather than merely printed: inline for a
  Bool, bare for a type with no Bool anywhere inside it, and through a
  small generated helper only for one that can hold one. The type comes
  from `tmap`, which `translate_program` takes for exactly this — which
  is why an ordinary program compiles to Python with no prelude at all.
- **`mutated_names` / `scope_declarations`** — a `def` that writes a
  `var` bound outside it opens with `global` or `nonlocal`, since
  assigning a name anywhere in a Python function makes it local to the
  whole function. `Scope.depth` (0 is the module) and `Scope.mutables`
  (each `var`, and the depth its declaration sits at) pick between the
  two.

---

## `target_js_core.ml`

**The JavaScript backend's language half.** Knows nothing about
packaging.

**Design, in depth:** [target_js_core.md](target_js_core.md) (this
module); [target_js.md](target_js.md) (what compiles to what, across
all three JS targets).

- **The `Js*` AST** — `JsExpr`/`JsStmt` and their variants, including
  **`JsRuntimeCall`**, whose spelling is supplied by the packager. That
  one node is why the same core output serves all three JS targets.
- **`Scope`** — like the Python backend's, but far less busy:
  JavaScript's `const`/`let` are Pyking's `=`/`var` and `{ }` blocks are
  scopes, so it renames only where JavaScript forces it (`const`
  redeclaration, and the temporal dead zone), not on every shadow. It
  also carries the checker's **`tmap`**, which is what a `Float` needs:
  a JavaScript number cannot say whether Pyking called it an Int or a
  Float, so the type decides at the print site
  (`printed_argument`, `float_shape`; see
  [target_js.md](target_js.md), "Floats").
- **`translate_program(stmts, tmap, taken=())` / `translate_stmts` /
  `translate_stmt` /
  `translate_expr`**, plus `translate_tail_stmts` for tail position,
  `translate_loop` and friends for a `loop` (a `while (true)` over a
  `let` -- or, where the body defines a function, over a carrier holding
  the next turn's value, with the accumulator a `const` inside the body
  so each turn's functions close over that turn: `defines_function`),
  and `declare_functions` for the same reason
  `target_python.ml` has one. A statement translator may answer with a
  list, since a loop is several JavaScript statements.
- **`translate_target`** — a binding target: a name, or the array
  pattern that takes a tuple apart, tuples being arrays here.
- **`pprint_js_program` / `pprint_js_stmt` / `pprint_js_expr`** — the
  printer takes a **`JsHost`**: the spelling to substitute into each
  runtime call, and how an import is written. `js_helpers` is the
  generated runtime the program uses, split out so a page holding
  several modules emits one copy rather than one per module.
- **`JsImport`** — what an import brings in, named rather than spelled,
  exactly as `JsRuntimeCall` is.
- **`Unsupported (info, message)`** — anything outside the subset,
  with a position.

---

## `target_js_packaging.ml`

**The JavaScript backend's packaging half**, and the JavaScript side of
the runtime interface. `node` and `web` emit the same ES modules and
both print with `console.log`; `web` adds a page that loads the
program, and `iweb` compiles nothing at all and ships the interpreter
instead.

**Design, in depth:** [target_js_packaging.md](target_js_packaging.md).

- **`targets`** — the JavaScript targets, read out of `targets.ml`.
- **`js_module unit js_program main target`** — one Pyking module as one
  ES module: its body, `print` imported where it prints, its imports,
  and an `export` clause unless it is the program's own.
- **`shared_runtime ()`** — `pyk-runtime.js`: `print` and the value
  formatting every module of the program imports rather than repeating,
  including `pykFloatStr` and `pykShaped`, which are how a Float is
  written where the value itself cannot say it is one.
- **`web_page module source`** — a `web` program's HTML: a loader and
  nothing else, since the program prints to the console.
- **`interpreted_page main sources externals`** — an `iweb` program's
  HTML: the interpreter, the Pyking sources, the external modules, and
  the call that runs them. Nothing is compiled for this target.
- **`package_program target units output_path stdout -> ([(path,
  contents)], string)`** — everything a whole program writes, and the
  text `--stdout` prints. `node` and `web` share it entirely; `web` adds
  the page.
- **`module_import`** — an import as an ES `import`, handed to the core
  inside a `jshost`. **`runtime_module`** is where `print` lives;
  **`reserved_names`** is what the packager tells the core it has taken.
- **`manifest_declares_module`** — why an existing `package.json` is
  never overwritten.

---

## `target_c.ml`

**The C backend**, serving `c89`, `c99` and `c23`. One backend because
the standards disagree about *printing* -- comments, where declarations
go, how a boolean is spelled -- not about meaning.

**Design, in depth:** [target_c_internals.md](target_c_internals.md);
[target_c.md](target_c.md) (what compiles to what, and what is refused).

- **`translate_program ?requested stmts tmap context standard`** -- one
  module, its types read from `tmap`. C has no garbage collector, so it
  compiles what needs none and refuses a list, a datatype holding
  itself and a function value that could outlive its environment.
- **`translate_all units standard`** -- every module of a program, each
  compiling the instances of its polymorphic functions the others call.
- **`ctype` / `code`** -- a type as C, every compound one declared once
  in the file under a name built from its code; **`shower`** the
  function that prints one.
- **`instance` / `drain`** -- a polymorphic def compiled once per type a
  call asks for.
- **`lift` / `function_value`** -- a nested def or a lambda as a function
  taking what it captures, and a function value as a closure.
- **`in_order` / `sequenced`** -- operands that can print, put in
  temporaries and ordered with the comma operator.
- **`member_names` / `member_path` / `sole_fields`** -- where a
  constructor's fields live: the members of a plain struct for a
  datatype of one constructor, the union's otherwise.
- **`pprint_c_program` / `pprint_c_header`** -- the translation unit,
  and the `.h` a module the program imports is included through.

---

## `target_java.ml`

**The Java backend**, serving `java8`, `java17` and `java21`, as three
shapes of output: plain classes and casts, records with `instanceof`
patterns, and records with a pattern `switch`.

**Design, in depth:** [target_java_internals.md](target_java_internals.md);
[target_java.md](target_java.md) (what compiles to what).

- **`translate_program stmts tmap context version`** -- one module, its
  types read from `tmap`: generics for type variables, `java.util.List`
  for a list, the runtime's `T2`, ... for a tuple, a class per
  constructor, `java.util.function` for a function value.
- **`jt`** -- a type as Java; **`pattern`**, **`match_stmt`** and
  **`switch_stmt`** -- a `match` for each shape. **`sole_constructor`**
  -- a datatype of one constructor, which is its record (or class) alone,
  built with `new`.
- **`lift`** -- a nested def as a static method taking what it captures;
  **`poly_wrap`** -- a function handed to a polymorphic parameter, as an
  object of the runtime's interface for it.
- **`pprint_java_program`** and **`runtime_source`** -- a module's class,
  and `PykRuntime.java` for the whole program.
- **`default_class_name(stem)`** -- Java requires the file and its public
  class to match exactly, so `foo_bar.pyk` becomes `FooBar.java`.

---

## `target_ocaml.ml`

**The OCaml backend**, and the one that infers nothing: it *runs*
`typesystem.type_check` and reads the types back out of `tmap`, which is
why the checker records an entry for every expression. A program that
does not check is refused with the checker's own message; its supported
subset is nearly all of the checker's, less a short list of shapes OCaml
cannot be given, each refused with a source position.

**Design, in depth:** [target_ocaml_internals.md](target_ocaml_internals.md)
(this module — why it infers nothing, the block-as-expression
translation, evaluation-order fixing, mutual-recursion grouping);
[target_ocaml.md](target_ocaml.md) (what compiles to what, and what's
refused).

- **`EXTENSION`** = `".ml"`,
  **`INTERFACE_EXTENSION`** = `".mli"`, and the `O*` AST.
- **`translate_program stmts tmap context target`** — `target` names the
  OCaml release: `ocaml4.14` has no `List.take`/`List.drop`, so a list
  pattern's middle is `List.filteri` there (`ctx.slices`). The table comes from
  `src/pyk.ml`, which type-checks every program; this module fills none
  of its own. Most of
  the translation is direct
  (`let … in` is a block scope, a rebinding is a new binding, `let rec …
  and …` is Pyking's rule that every `def` in a block is visible
  throughout it, and `true`/`false`/`()` are spelled identically). The
  interesting work is what it emits *around* that: no type annotations at
  all, `rec` only where something recurses, `name` for a binding nothing
  reads, and — via **`analyses.Effects`** and **`in_order`** — a `let`
  inserted wherever two operands of one expression can both print, since
  Pyking evaluates left to right and OCaml does not promise to.
- **`_Translator.loop`** — a `loop` as a local recursive function
  applied at once: the accumulator is its parameter, `continue` is a
  tail call, `break` is the value it returns. A `for` clause carries
  what is left of the sequence as a second parameter, and running out of
  it leaves the loop with the accumulator; a `while` clause asks its
  test with the accumulator in scope, and a turn not taken leaves the
  loop the same way. `rec` is computed from the translated body, never
  assumed, since a needless one is a warning and the harness treats
  warnings as errors.
- **`pprint`** — an `O*` expression as OCaml text; a `match` of one arm
  with no guard is printed as `let`, since its pattern cannot fail.
- **`regroup`** — the block's statements reordered so every group of
  `def`s that name each other is consecutive, which is what
  `let rec … and …` needs. Only `def`s move, and only down; a `def`
  that would pass a rebinding of a name its body reads, or a use of its
  own name, is refused instead.
- **`matcher`** and **`arm_for`** — one Pyking pattern as an OCaml
  pattern plus the two things OCaml cannot say there: the conditions
  the arm tests with `when`, and the bindings its body opens with. That
  is what compiles a `+` pattern over a string and a list pattern with
  elements after `..`. A `when` hides an arm from OCaml's exhaustiveness
  check, so the catch-all is decided from the unguarded arms alone.
- **`escaping`** and **`OEscape`** — a `return` OCaml has no value
  spelling for leaves by a local exception instead, with the value in a
  cell. `function_binding` translates a body without one first and
  builds one only when the attempt raises `Needs_escape`.
- **`specialisations`** — what each definition's type variables turn out
  to be, read off the call sites where every call in the module agrees
  and the name is never handed anywhere as a value. It is what lets a
  body that prints one of its parameters compile at all, since OCaml has
  no runtime type to print from.
- **`pprint_ocaml_program(program, source)`**, and
  **`pprint_ocaml_interface(program, source)`** — the `.mli` a module
  the program imports is seen through, which is the whole of privacy on
  this target. **`public_name`** spells an exported name from the name
  alone, since the module importing it has not seen the module it comes
  from.

The test harness builds this target's output with `-w +a`, so a compiler
warning about generated code is a failing test.

---

## `targets.ml`

**Every target, named once.** The table of targets with their family
and extension, each family's default (what its unversioned name means),
and `Targets.default`, the one `pyk compile` uses. `version` is what a
target's name says after its family's; `es_edition` the ECMAScript
edition a JavaScript target writes (2020 or 2024). See
[targets.md](targets.md).

---

## `execution.ml`

**What `--run` runs.** Compiling a program and running it are two
different pieces of knowledge, and this is the second: which command
builds a `.c` and which runs the binary belongs to the target, not to
the driver. One table, so `pyk.ml` stays a sequencer.

**Design, in depth:** [pyk.md](pyk.md), "Running what was compiled".

### Data structures

- **`Plan`** — what one target needs: `build` (commands that must each
  succeed first), `run` (the program itself), and `directory` (where to
  run them). Everything in it is absolute, since the commands run in the
  *output file's* directory rather than the caller's.

### Main functions

- **`plan_for(target, path, modules) -> Plan`** — the commands for one
  target, and a `note` printed before them. `python3 prog.py`; `node
  prog.js`; `pyk serve` for `web` and `iweb`, whose pages
  must be served because a browser refuses a module over `file://` —
  there the note is the page's own URL, since the server says only which
  port it took; `cc`/`javac`/`ocamlopt` and then the
  result for the compiled ones; and, for `pyking`, this compiler again —
  what runs Pyking is the interpreter. `modules` names
  the program's other files in dependency order, which the three that
  *link* a program rather than importing at run time need — and which,
  for OCaml, is also the order the modules' top levels run in.
- **`execute(target, path, modules) -> status`** — runs them, printing
  each first, prefixed `$ `, on **stderr** so the program's own output on
  stdout stays its own.
- **`C_COMPILER` / `JAVA_COMPILER` / `JAVA_RUNTIME` / `OCAML_COMPILER`**
  — `$CC`, `$JAVAC`, `$JAVA`, `$OCAMLOPT`, the same variables
  `tests/test_script.py` reads.

---

## `pyk.ml`

**The driver.** It parses argv, sequences the stages, reports errors, and
dispatches to one of five commands. Everything else — translation,
packaging, file naming, and running what was compiled — belongs to the
backends and to `execution.ml`.

```
pyk <file>              run it with the interpreter
pyk repl                start the REPL
pyk compile <file>      compile it (alias: pyk c)
pyk notebook <file.md>  serve a notebook (web_tools.ml)
pyk playground          serve the playground (web_tools.ml)
pyk serve [<dir>]       serve a directory's files (web_tools.ml)
```

**Design, in depth:** [pyk.md](pyk.md).

### Data structures

- **`options`** — everything argv said, as one immutable record: the
  command, the filename, and the flags. Flags are shared by every command rather
  than per-command, so `--tokens` and `--symbols` mean the same thing
  wherever they are written.
- **`targets` / `extensions`** — built from the backends themselves, so
  the usage message and the default output name cannot drift from what
  the compiler actually supports.
- **The errors `format_error` knows** — one line per stage that can
  refuse a program, in the order the stages run: `Lex_error`,
  `Parse_error`, `Module_error`, `Analysis_error`, `Type_error` (from
  either checker), `Runtime_error`. Every one carries an `info`, which
  is what lets them all be reported the same way.

### Main functions

- **`main ()`** — argv in, exit status out.
- **`parse_args argv -> options`**; anything malformed ends in
  **`usage_error`**, which prints the usage after the complaint.
- **`front_end options`** — load the program's modules, then per module
  lex, parse, symbolize, type-check, check mutability, and run the
  tail-call pass. One branch, and it is `--no-typechecking`'s: otherwise
  every program takes the same route, and a refusal at any step is an
  error.
- **`command_web tool options`** — `pyk notebook`, `pyk playground` and
  `pyk serve`, which run no front end: `Web_tools.start` serves until
  Ctrl+C, and this prints why when it could not.
- **`needs_page checked` / `command_serve checked options`** — whether a
  program imports a library marked `<name>.page`, and running one: it is
  compiled for `iweb` into a fresh directory and served, unless
  `--headless` says to interpret it here (docs/libraries.md, "A library
  that needs a page").
- **`command_dap options`** -- `pyk dap`'s stdio transport over
  `dap.ml`: the program gets standard streams of its own (its output a
  file read back into `output` events, its input the launch's `stdin`
  file), it runs in slices between messages, and a callback the host
  makes once the top level has ended runs in a loop of its own while the
  host waits. `runtime_report` words a runtime error as `pyk <file>`
  prints it, for both.
- **`command_interpret` / `command_compile`**, and `Repl.start` for the
  third. `command_compile` also writes a library's `<name>_assets/`
  beside a web page (`library_assets`). The REPL is *handed* this module's `format_error` rather than
  importing it, which is what keeps the dependency one-way — a cycle
  between two modules of one library does not link.
- **`format_error error -> string option`** — any front-end error as one
  `'file' row:col-row:col Kind: message` line, reflowed; `None` for an
  exception that is not one, so a caller can re-raise it unchanged.
- **`wrap text`** — every message this module prints is reflowed to 70
  columns with continuation lines indented, so a long path or diagnostic
  stays readable in a narrow terminal.

---

## `lsp.ml`

**The language server, `pyk lsp`.** In the library, so js_of_ocaml
compiles it into the browser bundle as well: the playground's worker
calls the same code. It opens no file and keeps no mutable state; the
transport (`command_lsp` in `pyk.ml`, `pykLsp` in `web/pyking_web.ml`)
holds the state between messages. See
[../design/lsp.md](../design/lsp.md).

### Data structures

- **`state`** -- where files come from (`Module.sources`) and the
  library path, the settings (`libPath`, check on change or on save),
  the open `document`s (URI, path, text, version, whether due to be
  checked), each document's `analysis`, what was last published per
  document, and the protocol's `phase` (`Fresh`, `Running`,
  `Shut_down`, `Exited`).
- **`analysis`** -- what checking a document as a program found: the
  modules loaded, each checked module's `tmap` and sigmap, the first
  error as a `problem` (span, `pyk`'s label for the stage, message),
  and `typed`, the last check that reached the document's own module,
  which hover reads while the program does not check.
- **`settings`** -- the library path, and whether to check on change
  or on save.

### Main functions

- **`handle state text -> (state, [text])`** -- one JSON-RPC message.
  Requests before `initialize` and after `shutdown` are refused with the
  protocol's codes, an unknown request is `MethodNotFound`, an unknown
  notification is ignored, and an exception while answering becomes an
  internal error and a `window/logMessage`.
- **`idle state`** -- checks every document due and publishes its
  diagnostics where they changed. A change marks every open document
  due, since one may import another.
- **`analyse state document previous`** -- the front end over the
  document, as `pyk.ml` runs it; an error in a module the document
  imports is reported at the import that reaches it.
- **`untyped_hover analysis tmap document row`** -- what hover says
  inside a top-level `def` with no type to show: that nothing calls
  the function (its definition has no type in `tmap`), or that the
  program has a type error. Anywhere else, nothing.
- **`hover`, `definition`, `document_symbols`, `completion`,
  `signature_help`, `references`, `highlights`, `prepare_rename` /
  `rename`, `folding_ranges`, `semantic_tokens`,
  `code_actions`** -- one request each. Names come from `scopes.ml`'s
  walk over the text as it is now, types from the last check that
  reached the document's own module. `open_call` reads the call a
  position is inside from the text, since a call being typed seldom
  parses; `rename` refuses a new name that would mean something else
  at any place the old one is written. After `m.` completion offers
  what `m` exports and its submodules, after `m.sub.` that submodule's
  public names (`submodule_items`, from the module's `dotted` table),
  and after a submodule imported under a name of its own the names it
  brought in.
- **`position` / `row_col`** -- the one conversion between
  `Lexer.info` (rows from 1, byte columns) and LSP positions (lines from
  0, UTF-16 columns).

---

## `scopes.ml`

**What the names in a module mean**, read by the language server and
by the debugger (the names a Watch expression may use). A walk that
binds as `analyses.ml` does -- every `def` of a block before any of it,
a module's imports before its first statement.

### Data structures

- **`meaning`** -- what a name refers to: `Bound` (a place, the
  binding's symbol, what kind of binding), `Module_of` a module,
  `Builtin`, or `Unknown`.
- **`found`** -- every use of a name with its meaning, a name taken by
  a `from` line among them, and which names are in scope from where to
  where.

### Main functions

- **`resolve units unit`** -- the walk: `resolve_block` binds a block's
  `def`s first, `resolve_stmt` and `resolve_expr` follow every construct
  that binds a name.
- **`use_at`, `names_at`, `bindings`** -- the use at a position, the
  names in scope there, and every binding the scopes hold.

---

## `debug_session.ml`

**The debugger's core**, protocol-free: `pyk dap` (`dap.ml`) and the
playground's Debug tab (`web/pyking_web.ml`) are two transports over it.
A session is a value; `advance t steps` runs a slice and answers the
events, so nothing waits. See [debugging.md](debugging.md).

### Data structures

- **`program`** -- every module as the checker saw it (`source`: the
  module, its `tmap`, its imports' sigmaps, what its names mean) beside
  what the interpreter runs.
- **`t`** -- the runs in progress (the top level, and callbacks, each an
  `Interpreter.runner` or a machine), where the session is (`Running`
  towards a goal, stopped, waiting for a callback, over), the
  breakpoints, and the frames and references of the current stop.

### Main functions

- **`prepare`** -- a loaded program checked and made ready to run as
  `pyk <file>` runs it.
- **`advance`** -- steps, checking at each statement started whether a
  breakpoint, a pause or the stepping goal stops there. A statement that
  continues the line the one before it started (the value of `x = if
  ...`) is not a new line to stop at. Stepping over or out of a call
  stops in the caller once the call returns.
- **`resume`**, **`push_call`**, **`set_breakpoints`** -- go on, a
  callback to run, and a file's breakpoints, each verified at the first
  statement on its line or after it.
- **`waiting_on`**, **`answer`** -- the number the running run waits on
  for the page (tinyweb's `sdelay` in a browser), where `advance` goes
  no further, and the session with that run handed its answer.
- **`frames`**, **`scopes`**, **`variables`** -- the calls in progress
  where it stopped, each frame's environment, a value's parts.
- **`evaluate`**, **`set_variable`** -- an expression checked against
  the names in scope at a frame (types from the checker's `tmap`, a
  value's own where that names a variable) and run in the frame's
  environment; a `var` given a new value through `:=`.

---

## `dap.ml`

**The debug adapter, `pyk dap`**: one DAP message in, the messages to
send back, over a `debug_session.ml` session. In the library; the stdio
transport is `command_dap` in `pyk.ml`, which supplies `hooks` (how a
launch loads, checks and starts a program, and how a failed run is
reported) and runs the program in slices between messages. See
[debugging.md](debugging.md).

---

## `completion.ml`

**What completion needs whoever asks**: the word ending at a column and
the module written before it with a `.` (`word_before`, `qualifier`,
which reads the whole `m.sub.` before the cursor),
which names a pass made up (`hidden`), the candidates fitting a prefix
(`matching`) and what they have in common (`common_prefix`). `lsp.ml`
and `repl_session.ml` (`completions`) each work their candidates out
and use these. See `docs/repl.md`, "Completion".

---

## `json.ml`

**JSON read and written**, for the language server. A number is a
float; a `\u` escape, surrogate pairs included, becomes UTF-8. `parse`
raises `Parse_error` for anything else. `pretty` writes a value laid
out for reading, for a notebook's JSON.

---

## `notebook_format.ml`

**A notebook as JSON, and back**: `pyk notebook --to-json`,
`--to-markdown` and `--json-schema`, and `pyk notebook FILE.json`. The
Markdown between the notebook's blocks is kept as written, and the
blocks are found and grouped as `tools/notebook/assets/markdown.js` and
`tasks.js` find and group them: a task or a practice with its solution,
tests and diff-allowed blocks, a quiz with its answer, a cell with the
tests under it. A block is written back from its fields in one
canonical layout, and how the source wrote it where that differs -- the
header, the fence, the closing line, the blank lines before it, a
quiz's text -- is kept beside the fields and used while it still says
what they do. See [notebook.md](notebook.md), "JSON". In the library,
since it is pure.

### Data structures

- **`value`** — an attribute's value, typed: `VString`, `VNumber`
  (`max`, `pass`, `attempts`, `points`, `penalty`,
  `lines_per_multi_input`) or `VBool` (`available`, `visible`,
  `one_point_correct`, and a bare word).
- **`fence`** — one notebook block as written: `language`, `attrs`,
  the raw `info` after the marker, the `marker`, the `body` (each line
  with its newline), the closing line (`None` at the end of the text),
  and the `gap` of blank lines before it where a block is right before.
- **`piece`** — `Text` between blocks, or a `Fence`.
- **`owner`** — a task, a practice or a cell as it is grouped: its
  head, which of the three it is, the solution, the tests (each a list of slot and block), the diff-allowed
  blocks, and the order they were written in.

### Main functions

- **`of_markdown text -> Json.t`** — `scan` splits the text into
  pieces: a fence at the left margin in a notebook language, outside
  another fenced block, an HTML block, display math and the front
  matter. A run of fences with only blank lines between is one group,
  which `group_json` gives owners as tasks.js does.
- **`to_markdown value -> string`** — the Markdown, raising
  `Format_error` with a path (`blocks[3].tests[0]`) where the value is
  not a notebook.
- **`schema`** — the JSON Schema (Draft 2020-12), built as a `Json.t`
  and printed by `Json.pretty`.
- **`parse_info info`** — a header as markdown.js's `parseInfo` reads
  it, a value of `(...)` groups (`max_calls = (2,rect) (1,circle)`)
  kept as one string; **`canonical_info`** the header the canonical
  layout writes, such a value bare.

---

## `examples.ml`

**The examples list**: what `pyk example` lists and saves and the
playground offers, read from `src/examples.toml`. Each example is a
test program, so the suite keeps it working. In the library because it
is pure; nothing in the browser bundle uses it.

- **`example`** — `{ source; name; description }`: the program's path
  from the tree's root, the file name it is saved as, and one line.
- **`file`** — `src/examples.toml`, from the tree's root.
- **`read text`** — every `[[examples]]` table with all three keys.
- **`find name examples`** — the one saved as `name`.
- **`listing examples`** — a table: the headings "File name" and
  "Description", a row of dashes under each, then one line per example.

---

## `repl_session.ml`

**A REPL session, without the terminal**: what `pyk repl` (`repl.ml`)
and the playground's REPL tab (`web/pyking_web.ml`) share. An entry is
checked as one group against what the entries before it left behind,
and run there; see `repl.ml` above and [repl.md](repl.md) for the
rules. It opens no file and reads no terminal: everything it shows goes
through its host, which is what puts it in the library.

- **`host`** — `{ write; machine; connect; from }`: where a line the
  session shows goes (a value, a command's answer), the interpreter's
  host given how to reach the modules imported so far, how to reach a
  module implemented in a target language (a plugin in a terminal,
  `pykExternals` in a page), and where an imported module's files are
  read if not from disk.
- **`session`** — abstract; see `Session` above.
- **`binding`** — `{ implicit; name; value; type_ }`: one name, as `:ls`
  shows it, and what the page's environment table lists.
- **`outcome`** — `{ out_session; pending }`: what a meta-command leaves.
- **`new_session ?libs host`**, **`submit`**, **`accept`** — as above.
- **`complete`**, **`continuable`**, **`next_indent`** — whether an entry
  is finished, and where its next line is indented.
- **`imported_modules session stmts`** — the modules an entry's imports
  would newly load, loading nothing: what a page makes ready first.
- **`bindings session`** — what the session has bound, in binding order.
- **`run_meta ?extra session line report`** — `:help`, `:ls`, `:type`,
  `:edit`, `:ast`, `:tokens` and `:reset`, plus `extra`, the terminal's
  `:load`; `:help` lists `:load` and `:quit` only where `extra` is given.
- **`undefined_name`**, **`defines_function`** — what a front end needs
  to offer an entry back for finishing.

---

## `web_tools.ml`

**`pyk notebook`, `pyk playground`, `pyk pykhelp` and `pyk serve`.** Each page is a
directory under `tools/` beside the running executable, served by
`web_server.ml` in this process, so nothing else has to be installed
(see [build.md](build.md), "The web tools"). In the executable rather
than the library, since it listens on a socket.

### Data structures

- **`tool`** — `Notebook | Playground | Help | Files`; `Files` is `pyk serve`.
- **`case`** — what the playground reads of one `[[cases]]` table of
  `tests/test_cases.toml`: `file`, `targets`, `modules`, `libs`.
- **`playground_targets`** — the targets the playground offers, in menu
  order, with each one's label, Ace mode and how the page runs it. The
  same table is in `tools/playground/playground.py`, for `make check`
  and the website; `tests/test_notebook.py` holds the two manifests
  equal.

### Main functions

- **`start tool port mode path -> (int, string) result`** — the
  notebook: checks the document, then `--mode test` runs
  `tools/notebook/check.js` under node and answers its status, and any
  other mode serves `notebook_site`. A `.json` notebook is the Markdown
  `notebook_format.ml` makes of it: served at `doc/<stem>.md`, worked out
  on every request, and written to a temporary file for test mode. The playground serves
  `playground_site`; the help serves `help_site`, refusing where
  `share/help/` was not generated (`check_help`); `pyk serve` serves a directory, listing one with no
  `index.html`. Each refuses a missing compiler bundle or, unless
  `$PYKING_WEB_NO_VENDOR` is set, missing browser libraries, with the
  reason as a sentence for the driver to print.
- **`common_site ()`** — what every page loads: `/webrun/`, `/vendor/`,
  `/lib/`, `/notebook/` (the notebook's scripts, which run a cell
  anywhere), `/help/` and `/help/pages/` (the help's scripts and its
  generated pages), `/pyking/pyking.js` and `/pyking/manifest.json`,
  whose stamp is a digest of the bundle.
- **`offered_examples ()`** — the playground's examples, the list in
  `src/examples.toml` (`examples.ml`), which a package ships; each is
  served at `/examples/<name>`, the name `pyk example` saves it as.

---

## `web_server.ml`

**A static HTTP/1.1 server on 127.0.0.1**, or on the address
`$PYKING_WEB_HOST` names (`address`). One thread: `select` waits
on the listening socket and every connection, so a browser's idle
speculative connection does not hold up the files a page is waiting
for. Each connection's unanswered bytes are threaded through the loop as
a value. Keep-alive is the default; `GET` and `HEAD` are answered, and
anything else is `501`.

### Data structures

- **`site`** — `mounts` (a URL prefix ending in `/` to a directory),
  `files` (an exact URL path to a file), `answers` (an exact URL path to
  a function making the body, and its content type), and `listing`
  (whether a directory with no `index.html` is listed). A path with a
  component starting with `.` names nothing, which is what keeps `..`
  out.

### Main functions

- **`serve site title port explicit lines`** — listens on `port` when
  `explicit`, else on the first free port of twenty from it or, failing
  that, any free port, prints a
  banner with the link, and serves until Ctrl+C. `SIGPIPE` is ignored,
  so a browser closing a connection mid-reply does not end it.
- **`respond site path`** — what a `GET` answers: a computed answer, a
  file, a directory's `index.html`, a redirect adding a directory's `/`,
  or `404`. Everything but `/vendor/` is sent `Cache-Control: no-store`,
  since it is served from where it is edited.

---

## `install.ml`

**Where this installation keeps what ships beside `pyk`**: `lib/`,
`share/pyking.js` and `tools/`. `root ()` is the running executable's
directory after `Unix.realpath`, so a `pyk` reached through a symbolic
link -- Homebrew's `bin/pyk` is two -- finds the directory it was
installed in. The standard library's search path, the `iweb` target's
`pyking.js` and `web_tools.ml` all ask it rather than reading
`Sys.executable_name` themselves. In the executable, since it needs
`unix`.

## `version.ml`

**The version**, one string. Not checked in: `src/dune` writes it from
the `VERSION` file at the root when the executable is built, and `pyk
--version` prints it. See [build.md](build.md), "Packaging".

---

## `web/pyking_web.ml`

**The browser entry point**: the same library, compiled to JavaScript
with js_of_ocaml, so `tools/playground/` and `tools/notebook/` run the
real compiler in the page instead of a Python runtime.

It registers a handful of functions on the global object through the
primitives in `src/web/stub.js` — `pykCompile` (a program and a target
in, generated source or a formatted error out), `pykRun` (the
interpreter, emitting each line as the program produces it),
`pykRunProgram` (a program of several modules, sources supplied by the
page or fetched through its `pykFetchSource`, externals through
`pykExternals`, and `release` on a second line), `pykAnalyze` (which of
a program's modules are implemented in JavaScript, and whether it reads
standard input or its arguments), `pykTargets`, `pykFormatHelper`,
`pykKeywords` and `pykBuiltins`, `pykCallback` (a Pyking function
handed to JavaScript, called back by the id it crossed as), `pykResume`
(a run or a callback that waits for the page -- an external that
answered a promise, which crossed as `{"pyk_wait":n}` -- handed what the
promise settled with; `pykSettle` in `stub.js` drives it), and the
REPL tab's session (`repl_session.ml`): `pykReplStart`, `pykReplLine`
(whether text is a whole entry, and the next line's indentation),
`pykReplImports` (the modules implemented in JavaScript an entry would
load) and `pykReplSubmit` (one entry, answering its errors, the text to
put back in the prompt and the bindings; what it shows goes to
`pykOnShow`). A value
crosses by its declared type (`externals_for`, `json_of_typed`,
`coerce`), so a callback becomes `{"pyk_callback":id}` and an integral
number declared `Float` comes back a `Float`. A `debug` line goes to `pykOnDebug`; a
`sys.exit` in a JavaScript implementation crosses back as data and ends
the run with `{"ok":true,"exit":code}`. The
last four are what the pages ask the bundle for when they load, so
the page's target list, its syntax mode's keyword list and its JavaScript
worker's formatter all come from the compiler rather than from a
hand-kept copy.

Nothing here is compiler logic: every entry lexes, parses, checks and
compiles through the same functions `pyk.ml` calls, and reports a
refusal with the same `format_error`. The one thing it may not use is
the library's `unix` half — the executable links that, this does not,
which is why the library depends on nothing outside the standard
library. See [build.md](build.md) and
`tools/playground/README.md`.
