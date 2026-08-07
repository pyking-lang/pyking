# The source, file by file

What every module in `src/` is, and what is inside it: the data
structures it defines, the functions that matter, and the decisions the
code embodies. It is the reading order as much as the reference — the
modules are listed in the order a program passes through them.

For the *shape* of the compiler (the pipeline, the runtime interface, the
tests) see [architecture.md](architecture.md); for what each target
accepts see [targets.md](targets.md); for the language itself see
[../PYKING.md](../PYKING.md). This page is about the code.

`src/` is deliberately **not a package**: no `__init__.py`, no relative
imports. The modules import each other by plain name (`from lexer import
...`), which works because Python puts a script's own directory on
`sys.path` when `src/pyk.py` is run. That flatness is not an oversight —
these files are to be rewritten *in Pyking* one day, and Pyking has no
module system to express a directory hierarchy with.

## At a glance

| module | lines | what it is |
|---|---:|---|
| [`lexer.py`](#lexerpy) | ~585 | Characters → tokens. Also defines `Info`, the source span every later node carries. |
| [`syntax.py`](#syntaxpy) | ~980 | The AST: one frozen dataclass per variant, documented as algebraic data types, plus the pretty printer that prints Pyking back out. |
| [`parser.py`](#parserpy) | ~1085 | Recursive descent, tokens → AST, and the few rules the grammar cannot state. |
| [`analyses.py`](#analysespy) | ~515 | Static analyses over the AST: names and scoping (`analyze_program`), and `symbolize`, which numbers every node. |
| [`typesystem.py`](#typesystempy) | ~850 | The type checker: one function per AST datatype, producing `tmap` (symbol → type). Its fragment is also the interpreter's and the OCaml backend's. |
| [`runtime_interface.py`](#runtime_interfacepy) | ~86 | The boundary between a pure Pyking program and the world: the operations a host must provide, and how values are formatted. No host code at all. |
| [`interpreter.py`](#interpreterpy) | ~1470 | The interpreter: values, environments, and a resumable small-step machine that runs the AST. The reference for runtime semantics. |
| [`repl.py`](#replpy) | ~900 | `pyk repl`: a session as a program written one entry at a time, and the multi-line editor it is typed into. |
| [`target_python.py`](#target_pythonpy) | ~2120 | The Python backend, and the only one that compiles the whole language. |
| [`target_js_core.py`](#target_js_corepy) | ~647 | The JavaScript backend's language half: a `Js*` AST, translation, printer. |
| [`target_js_packaging.py`](#target_js_packagingpy) | ~316 | Its packaging half: `nodejs`, `html`, `esm`, and the JavaScript side of the runtime interface. |
| [`target_c.py`](#target_cpy) | ~1093 | The C backend, for `c89` and `c23`. Infers the types C insists on. |
| [`target_java.py`](#target_javapy) | ~1127 | The Java backend, for `java8`/`java17`/`java21`. Also proves every function returns. |
| [`target_ocaml.py`](#target_ocamlpy) | ~1217 | The OCaml backend. Infers nothing: it reads the checker's `tmap`. |
| [`pyk.py`](#pykpy) | ~570 | The driver: argv, stage sequencing, error reporting, the four commands. |

Two shapes recur everywhere and are worth reading once rather than
sixteen times:

**One dataclass per variant, plus `match`.** Every tree in the
repository — tokens, the AST, types, values, each backend's own AST — is
written as a set of frozen dataclasses with a shared marker base class,
and consumed by `match`/`case`. That is how a variant type would be
written in a language that has one, which is what the self-hosted
compiler will be written in. New variants follow the same style rather
than being collapsed into one class with a `kind` field.

**Tables are threaded, not mutated.** Environments, scopes and type
environments are rebuilt by extension (`{**env, name: value}`) rather
than updated in place. Entering a nested scope is "keep using what you
were handed"; leaving one is "go back to the caller's" — which is what
makes a block's bindings unable to escape it, with no scope stack to
pop.

---

## `lexer.py`

**Characters → tokens, and the vocabulary of source positions.**

Everything downstream reports errors against `Info`, so this module is
imported by every other one.

### Data structures

- **`Info(file, row1, col1, row2, col2)`** — a frozen dataclass: the span
  a token or node covers. Rows count from 1, columns from 0. Attached to
  every token by the lexer, and carried onto every AST node by the
  parser, so any later stage can report against the source.
  `pprint_info` renders it as `'file' row:col-row:col`, the form every
  error message in the compiler begins with.
- **The token ADT** — `Token` as a marker base class and one frozen
  dataclass per kind: `TokInt(info, value)`, `TokString(info, value)`,
  `TokIdent(info, name)`, the operators (`TokAdd`, `TokSub`, `TokMul`,
  `TokDiv`, `TokEqEq`, `TokLessThan`, …), the punctuation (`TokColon`,
  `TokComma`, `TokLParen`, `TokArrow`, `TokDotDot`, …), the keywords
  (`TokDef`, `TokReturn`, `TokFor`, `TokIf`, `TokMatch`, `TokVar`, …),
  and the two that carry the block structure, **`TokIndent`** and
  **`TokDedent`**.
- **`keywords`** — the reserved words, as one list: control flow and
  declarations, the type names `Int`/`String`/`Bool`, and the literals
  `true`/`false`. `tools/emacs/pyking-mode.el` mirrors this list split
  three ways, and must be kept in step with it.
- **`LexError(info, message)`** — raised for a lexical error.

### Main functions

- **`lexing(file, chars) -> [Token]`** — the lexer. It consumes a *list
  of characters* (not a string) with structural pattern matching (`match
  rest: case ['-', '>', *rest]: …`), tracking row and column by hand as
  it goes. Indentation is turned into `TokIndent`/`TokDedent` here, which
  is what lets the parser treat a block as a bracketed construct.
- **`string_until(pred, chars)`** — the longest prefix satisfying `pred`,
  used for numbers and identifiers.
- **`scan_string(file, r, c, quote, chars)`** — a string literal, with
  its backslash escapes decoded.
- **`is_digit` / `is_letter` / `is_digit_letter`** — character classes.
- **`keyword_token(name, info)`** — the keyword token for a name, or
  `None` if it is an ordinary identifier.
- **`pprint_token(tok)`** — a token as text, by `match`/`case` over the
  ADT.

Adding an operator or keyword means three edits in this file: a `case`
arm in `lexing`, a `Tok*` dataclass, and a `case` arm in `pprint_token`.

---

## `syntax.py`

**The AST, and how to print it.** Every backend and every analysis
consumes exactly this.

The name is not an accident: `src/` is a flat set of script modules, so a
module named `ast.py` would shadow the standard library's `ast` on
`sys.path` — which breaks `dataclasses` itself, since it reaches `ast`
through `inspect`. Do not rename it back.

### Data structures

The file opens with one block of **`datatype` comments** naming every
group, its variants and their fields, in OCaml-ish notation (`[T]` for a
list of `T`, `T?` for a field that may be absent). Dataclasses can state
a node's fields but not that a group is a *closed set of alternatives*,
which is exactly what every `match` over the AST relies on — so the
comments state it. They are hand-written, and keeping them in step with
the classes is part of changing the AST.

The groups:

- **`Expr`** — `EInt`, `EString`, `EBool`, `EVar`, `EAdd`, `ESub`,
  `EMul`, `EDiv`, `ENeg`, `ELessThan`, `ELessThanEq`, `EGreatThan`,
  `EGreatThanEq`, `EEq`, `ECall`, `EList`, `ETuple`, `EIf`, `EListComp`.
- **`Type`** — `TInt`, `TString`, `TBool`, `TList`, `TTuple`,
  `TFunction`. `TTuple` with no elements is the unit type `()`.
  `TFunction` is both written in source and built by the checker.
- **`Pattern`** — `PInt`, `PString`, `PBool`, `PWildcard`, `PCapture`,
  `PTuple`, `PList`.
- **`CompClause`** — `CompFor`, `CompIf` (list comprehensions).
- **`AssignTarget`** — `TargetName`, `TargetTuple`.
- **`Stmt`** — `SLet` (`x = e`), `SLetStmt` (`x = if c: …`), `SVar`,
  `SMutate` (`:=`), `SReturn`, `SReturnStmt`, `SExprStmt`, `SFor`,
  `SWhile`, `SIf`, `SFunctionDef`, `SMatch`.
- **Single-constructor records** — `Param`, `ListRest`, `MatchCase`.

Every node carries `info` (its span) and `sym` (its symbol, `0` until
`symbolize` runs). Every node is frozen, so passes that change the tree
rebuild it with `dataclasses.replace`.

### Main functions

- **`pprint_program(stmts, symbols=False, tmap=None)`** — the only entry
  point callers use. `symbols=True` appends each node's `@n`;
  `tmap` makes every annotation printed come from the *checker* rather
  than from the source, so `pyk compile --typecheck --ast` shows inferred
  types. Both are module-level display flags that this function sets and
  restores around its one call, rather than parameters threaded through
  every printer.
- **`pprint_expr` / `pprint_stmt` / `pprint_type` / `pprint_pattern` /
  `pprint_param` / `pprint_target`** — the printers themselves, each a
  `match` over its own datatype. Output is valid Pyking, which is what
  keeps `--ast` re-parsable.

---

## `parser.py`

**Recursive descent: tokens → AST.**

### Main functions

The expression grammar is one function per precedence level, each taking
a token list and returning `(node, rest)`:

`parse_atom` → `parse_call_tail` → `parse_unary` →
`parse_multiplicative` → `parse_additive` → `parse_comparison` →
`parse_expr` → `parse_tuple_or_expr`.

Around them:

- **`parse_statement(tokens)`** — one statement, dispatching on the
  leading token, including the `if`/`match` forms that can be *bound*
  (`x = if c:`) or *returned* (`return match e:`), via
  `parse_bound_value`.
- **`parse_block(tokens)`** — a `TokIndent`-delimited block; a missing
  one is `expected an indented block`, which is also what tells the REPL
  an entry is unfinished.
- **`parse_type` / `parse_param` / `parse_params`** — annotations. A
  parenthesized list followed by `->` is a `TFunction`; without the
  arrow it is a `TTuple`.
- **`parse_pattern`, `parse_case`, `parse_cases`, `parse_match_stmt`** —
  `match`/`case`, including list patterns with a `..rest` marker.
- **`parse_target`** and `_try_parse_assignment_target` — assignment
  targets, including tuple destructuring.
- **`parse(tokens) -> [Stmt]`** — the whole program.

Two helpers matter beyond their size. **`combine_info(start, end)`**
builds each node's span from its first token's start to its last token's
end — a new grammar rule combines infos the same way rather than reusing
one token's span. **`_here(tokens)`** is the position to blame when the
input has run out.

Two checks live here rather than in a later stage, so that they fail with
a source position at parse time: **`_check_no_duplicate_captures`** (a
pattern may not bind one name twice) and **`_check_value_stmt`** (every
branch of a value-form `if`/`match` must yield a value — which
`target_python.py` then relies on).

`ParseError(info, message)` carries the position.

---

## `analyses.py`

**Static analyses over the parsed AST**, run between the parser and
anything else, for every mode. Errors are `AnalysisError(info, message)`.

### Data structures

- **`Binding(kind, info)`** — what the name environment records: which
  kind of binding introduced a name (`MUTABLE`, `BINDING`, `PARAMETER`,
  `LOOP_VAR`, `PATTERN_VAR`, `FUNCTION`, `BUILTIN`) and where. The kind
  is what makes an error say *what* the name is; `info` is what lets it
  point at the other line.
- **`BUILTINS`** — `("print", "range", "str", "len")`. Pyking's grammar
  has no notion of a builtin, so these are seeded into the top-level
  environment; that is what lets every *other* unbound name be an error.
  Imported by `typesystem.py` and `interpreter.py` rather than repeated.

### Main functions

- **`analyze_program(stmts)`** — the entry point. A single recursive walk
  carrying a name environment, enforcing two rules: every name used must
  be bound in an enclosing scope, and a `var` may not be shadowed (which
  is what keeps `:=` unambiguous).
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
  hoisted name unambiguous. Both `typesystem.py` and `interpreter.py`
  import it rather than restating the rules.
- **`symbolize(stmts) -> [Stmt]`** — gives every node a unique integer
  `sym`, post-order from 1 (`0` means "not symbolized"). Unlike the
  analysis it *rewrites*: nodes are frozen, so it rebuilds the tree with
  `replace`. Its walk is generic over dataclass fields, so a node added
  to `syntax.py` gets a symbol without touching this file. Existing
  symbols are kept and new ones continue past the highest, which makes it
  safe to run twice.

---

## `typesystem.py`

**The type checker.** Run under `--typecheck`, by `pyk run`, and by the
OCaml backend. It runs *instead of* `analyze_program`, not after it: its
environment is a scope, so it checks names itself and raises
`analyses.AnalysisError` — in the analysis's own words — for a name it
cannot find.

What it means for a *program* is PYKING.md's "Type checking" section;
this file is how those rules are applied.

### Data structures

- **`tmap`** — the result: one mutable dict from a node's `sym` to the
  `Type` worked out for it. Every expression gets an entry, not just the
  annotatable constructs, which is what lets `target_ocaml.py` read types
  back instead of inferring them again. A `SFunctionDef`'s entry is its
  *function* type, not its return type.
- **`env`** — name → `Type`, a `Builtin`, or `None`. Used immutably: a
  binding hands what follows it an extended copy. `None` means "in scope
  with no type here" (a `def` that is not fully annotated); `Builtin` is
  a name that denotes a host operation, callable but never a value,
  because none of the four fits a `TFunction`.
- **`OPERATORS`** — node class → (spelling, list of signatures). A *list*
  because several operators are overloaded: `+` is `Int + Int` and
  `String + String`, and both operands must match the same signature.
- **`TypeError_(info, message)`** — a type error, or the floor:
  `Construct is not supported`, raised for everything outside the
  fragment. That floor is deliberate — a checker that quietly accepted
  what it had not reasoned about would be worse than one that says where
  it stops.

### Main functions

One function per AST datatype, each taking a node of exactly that type
and returning exactly one kind of answer (the signatures are written out
OCaml-style near the top of the file):

- **`type_check(stmts) -> tmap`** — the entry point.
- **`check_stmts(stmts, env, tmap, return_type) -> Type`** — a block's
  type: its last statement's. Calls `declare_functions` first.
- **`check_stmt(stmt, …) -> (Type, Env)`** — the type of the value a
  statement *supplies*, plus the environment the statements after it are
  checked in. That single question — what value does this supply? — is
  why a branch that `return`s and a branch that ends in an expression
  compare without either being a special case.
- **`check_expr(expr, env, tmap) -> Type`** — records into `tmap`;
  `expr_type` holds the rules themselves.
- **`check_function`, `function_type`, `check_param`** — a `def` is
  checked only when every parameter and the return type is annotated;
  its type is then a `TFunction`.
- **`check_call`, `check_builtin_call`** — anything of function type may
  be called; the four builtins are checked at the call site, where their
  signatures live.
- **`check_annotation(annotation, actual)`** — an annotation is
  *checked*, never replaced. That is the difference between an annotation
  and a comment.
- **`same_type(a, b)`** — structural equality. Never `==`: `T*` nodes are
  dataclasses, so `==` would compare `info` and `sym` too.
- **`declare_functions(stmts, env)`** — every `def` of a block bound
  before any of it is checked, through `analyses.block_functions`. That
  one step is recursion, mutual recursion and forward references.

---

## `runtime_interface.py`

**The boundary between pure Pyking code and the outside world**, in the
spirit of WebAssembly's split between a core language that can observe
nothing and a separate host specification.

Backend-agnostic by construction: no Python, no JavaScript, no
interpreter code. It holds the *names* of the operations and their
semantics, including the value-formatting rules, because every backend
has to agree on those before one program can print the same characters
everywhere.

- **`Operation(name, variadic, doc)`** — one operation a host must
  provide.
- **`PRINT`**, **`OPERATIONS`**, **`NAMES`** — today's whole interface:
  one operation.
- **`lookup(name)`** — the `Operation` a name denotes, or `None` for an
  ordinary Pyking name. `target_python.py`, `target_js_core.py` and
  `interpreter.py` all route through it.

The formatting rules pinned here: arguments formatted individually and
joined with single spaces, then a newline; a string bare; an integer in
base 10; unit as `()` — never the host's own word for "no value"; a
boolean as `true`/`false`, Pyking's spelling rather than Python's.

Add an operation here first; the backends then bind it.

---

## `interpreter.py`

**The interpreter: a resumable machine that runs the AST directly.**

Every other backend answers "what would this program look like in C, in
Java, in Python?". This one answers "what does this program *do*?", in
Pyking's own terms — which makes it the reference for runtime semantics:
where a backend disagrees with it, the backend is wrong.

It runs exactly the fragment `typesystem.py` accepts. The gate is the
checker itself (`check`), the same arrangement `target_ocaml.py` uses, so
there is no second list of supported constructs to keep in step.

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

### Data structures

- **`Value`** — `VInt`, `VString`, `VBool`, `VUnit`, `VList`,
  `VClosure(name, params, body, expr, env)`, `VBuiltin(name)`, and
  `VUndefined(name)` (a hoisted `def` whose definition has not run yet).
  No host objects and no host dictionaries inside a value: the
  representation has to survive being rewritten in Pyking and compiled to
  machine code.
- **`Env(bindings, parent)`** — a persistent chain of frames. `extend`
  builds a new head; `lookup` walks outwards. Pyking's scoping falls
  straight out of it: a block runs in a chain of its own, `=` makes a new
  frame (a rebinding shadows, it never updates), and a `def` captures the
  chain it was created in. Everything `target_python.py` has to work for
  — renaming shadowed bindings, per-turn factories — is simply what this
  representation does.
- **`Control`** — `CEval(expr)`, `CStmt(stmt)`, `CApply(value)`,
  `CDone(value)`, `CFailed(error)`.
- **`Kont`** — one class per "what to do with the value I am about to
  get": `KSeq`, `KBind`, `KBinaryLeft`, `KBinaryRight`, `KCallee`,
  `KArgument`, `KBranch`, `KDiscard`, `KReturnTo`. Each holds `rest`, so
  the chain is a linked list — pushing and popping cost one allocation
  and no copying, and two states can share a tail, which is what makes a
  paused state cheap to keep. Most also hold the `env` their remaining
  work runs in, and the machine restores it when the continuation is
  popped; `KSeq` is the one deliberate exception, since adopting the
  environment it is handed is exactly how a binding becomes visible to
  the statements after it.
- **`Frame(name, info, kont, env, parent, depth)`** — one Pyking call:
  the caller's continuation and environment, and how deep this is. This
  is Pyking's call stack, in the machine's own data.
- **`Runtime(host, simple, max_depth)`** and **`State(control, env, kont,
  stack, runtime)`** — the settings a run never changes, kept apart from
  the progress it does. A `State` is a plain value; keeping one is how a
  debugger pauses.
- **`Host`** — one method per `runtime_interface` operation, with three
  implementations: `ConsoleHost` (a stream), `BufferHost` (collected
  lines), `CallbackHost` (a function per line — the shape a debugger or a
  browser worker wants).
- **`RuntimeError_(info, message)`** — carried by `CFailed`. Never thrown
  through `step`.

### Main functions

- **`check(stmts) -> tmap`** — the gate: `typesystem.type_check`.
- **`initial_state(stmts, host, env=None, max_depth=…)`** — a machine
  about to run. `env` lets a caller continue an earlier session, which is
  what the REPL passes.
- **`step(state) -> state`** — one small step. Total: every state has a
  successor, including a finished or failed one, which is what lets `run`
  be a bare loop. `_step_eval`, `_step_stmt` and `_step_apply` are its
  three halves-and-a-bit.
- **`run(state, steps=None) -> state`** — step until the machine stops,
  or until `steps` steps have been taken. The bounded form is what makes
  this usable from somewhere that must not block.
- **`run_program(stmts, host) -> state`**, **`finished`**, **`result`**,
  **`failure`**, **`unwrap`**, **`stack_trace`** — the embedding API.
- **`declare_entry(state, stmts)` / `eval_in(state, stmt) -> state` /
  `eval_statement(state, stmt)`** — running statements in an existing
  machine's environment, which is what a prompt does. `declare_entry` is
  entering a block for a group that is not one: an entry's `def`s come
  into scope together, so two of them may call each other, while a later
  entry is a later group. `eval_in` then runs one statement there;
  `eval_statement` is the two together, for a group of one — the shape a
  debugger's "evaluate in this frame" wants.
- **`declare(stmts, env)` / `define(env, node)`** — the two halves of
  Pyking's `def` rule. `declare` puts one write-once cell per `def` in the
  block's frame, holding `VUndefined`; `define` fills it when the
  definition is reached, with a closure capturing the environment *there*.
  That is how a name can be visible throughout its block while a body
  still captures what was bound where it is written — and why using one
  too early says "its `def` has not run yet" rather than "unbound".
- **`format_value(value)` / `display_value(value)`** —
  `runtime_interface`'s formatting rules, written iteratively with an
  explicit stack so that a deeply nested value cannot overflow the host's
  stack. The two differ over strings: `print` *emits* text, so
  `format_value` writes a string bare, while a prompt, a list's elements
  and (later) a debugger's variable view *display* a value, so
  `display_value` quotes it.
- **`wrap32(n)`** — a Pyking `Int` is a signed 32-bit integer, and `+`,
  `-` and `*` wrap two's complement, as they do in C and Java. See
  [targets.md](targets.md#integers-are-32-bit) for which backends differ.
- **`call_free_symbols(node)`** — the one optimisation: an expression
  containing no call can neither suspend nor reach the host, so it is
  evaluated in one gulp by `_evaluate` instead of one continuation at a
  time. Which expressions those are is computed once, before the program
  runs, and kept as a set of symbols in `Runtime`. The recursion in
  `_evaluate` is bounded by how deeply the *source* nests expressions, so
  it cannot be driven deep by a long-running program.

---

## `repl.py`

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

### Data structures

- **`Session(seen, state, types)`** — the machine's environment and the
  checker's, extended in step, plus every statement the session has been
  given. `seen` exists for one narrow reason: `symbolize` numbers a tree
  from the highest symbol already in it, so handing it the accumulated
  statements is what keeps a later entry from reusing an earlier entry's
  symbols — which the machine's call-free table is keyed by.
- **`Buffer(lines, row, col)`** — the entry being typed, as a frozen
  value with pure operations over it (`insert`, `newline`, `backspace`,
  `left`, `up`, …). Everything about *what the text is* can therefore be
  reasoned about without a terminal in sight.
- **`Editor`** — a small multi-line editor over a terminal in raw mode.
  It holds only what is unavoidably stateful: the tty, the history of
  *entries*, and how much of the screen the last redraw used.
- **`META`** — the meta-commands, each `(session, argument, report) ->
  session`, so one that changes the session and one that only reports
  have the same shape.
- **`INCOMPLETE`** — the two things the parser says when it stopped
  because the input *ran out*. That is what makes a block keep reading,
  rather than a trailing `:` being guessed at.

### Main functions

- **`start(format_error, read=None, session=None)`** — the loop.
  `format_error` is `pyk.py`'s own, so an error made at the prompt is
  reported in exactly the words it would have been reported in from a
  file; the other two arguments let something other than a terminal drive
  the REPL (a transcript test, another front end).
- **`submit(session, stmts, report)`** / **`check_entry(entry, types)`**
  — check the whole entry first, then run it a statement at a time,
  stopping at the first runtime error with both environments left
  describing exactly the statements that ran.
- **`make_reader()`** — the editor when there is a terminal, plain
  `input()` (via `read_entry`) otherwise: a pipe has no cursor to move
  and no history to walk.
- **`complete(source)` / `next_indent(source)`** — the two things the
  editor needs to know about the language: whether Enter submits, and
  how far in the next line starts. Both are answers, not guesses:
  completeness is the parser's, and indentation follows the one rule
  that a line ending in `:` opens a block.
- **`meta_help`, `meta_vals`, `meta_type`, `meta_ast`, `meta_tokens`,
  `meta_load`, `meta_reset`** — the commands. `:vals` lists what the
  session bound as `name = value : Type`, reading the values from the
  machine's environment and the types from the checker's; `:type` checks
  an expression in that same type environment, so it can name whatever
  the session bound.

### The line editor

`Editor` exists because `readline` cannot do the one thing a REPL with
blocks in it needs: recall a *whole* entry. `readline` history is one
line per `input()` call, so pressing Up after defining a five-line
function offers its last line, which is not a program.

Here the buffer is a list of lines: Up and Down move within the entry and,
at its edges, step through the history of entries — so a function comes
back whole and can be edited anywhere in it. Left and Right move through
it a character at a time (across line boundaries), Escape abandons what
is being typed, Ctrl-C does the same, and Ctrl-D at an empty prompt ends
the session. Enter submits a single line that parses, and otherwise opens
a new line, already indented to where it belongs; a blank line ends a
block, which is Python's REPL rule and the only one that lets a block
have more than one statement in it.

Drawing is one redraw per keystroke: go back to the top of the last
drawing, clear it, write the entry again, and put the cursor where the
buffer says it is — with the terminal's width in the row arithmetic, so
a line long enough to wrap is still followed correctly.

---

## `target_python.py`

**The Python backend** — the first one written, the reference for the
others, and the only one that compiles the whole language.

### Data structures

- **The `Py*` AST** — `PyInt`, `PyString`, `PyVar`, `PyAdd`, `PyCall`,
  `PyIf`, `PyFor`, `PyMatch`, `PyAssign`, … Structurally the same shape
  as `syntax.py`'s, with two deliberate collapses: Pyking's `SLet`,
  `SVar` and `SMutate` all become one `PyAssign`, since Python has no
  immutable-binding distinction; and `SLetStmt` has no node at all, since
  it compiles to an ordinary `PyIf`/`PyMatch` with a `PyAssign` pushed
  into each branch's tail.
- **`Scope`** — Pyking name → the Python name standing in for it. Pyking
  blocks are scopes and Python's are not, so a binding that shadows
  another *within one Python function scope* is renamed (`total` →
  `total2`). `_bind`, `_lookup`, `_block_scope` and `_function_scope` are
  the whole mechanism, and it renames only when it must — never inside a
  `def` body or a comprehension, where Python already scopes.

### Main functions

- **`translate_program(stmts)`**, **`translate_stmt(s, scope) -> (node,
  scope)`**, **`translate_expr(e, scope)`**, plus `translate_pattern`,
  `translate_target`, `translate_case`. Statement translators return the
  scope so a sequence accumulates bindings; a caller entering a block
  discards it. Each `match` ends in `case _: raise NotImplementedError`,
  so a future construct without a translation fails loudly.
- **`pprint_py_program` / `pprint_py_stmt` / `pprint_py_expr`** — `Py*`
  AST → Python source.
- **`_declare_functions`** — binds every `def` in a block before
  translating it. Python resolves forward references itself, but a
  *renamed* function has to be renamed before the call above it is
  emitted.
- **`_free_names`** and **`_captured_names`** — the two analyses that
  carry the scoping story: a scope renames a binding that shadows a name
  its body reads from outside itself, and a rebinding some function
  already captured gets its own Python variable, because in Pyking it is
  a *new* binding.
- **`_turn_groups` / `_absorbed` / `_translate_turn_group`** — a `def`
  written inside a loop is built by a small per-turn factory, so each
  turn's functions keep that turn's values; `def`s that name each other
  are built together. Nothing but `def`s moves — a `return` or a `:=`
  carried into a factory would change what it means. See
  [target_python.md](target_python.md).
- **`_bool_shape` / `_wrap_print_argument` / `_bool_format_helper_name`**
  — Pyking prints `true`/`false` and Python prints `True`/`False`, so a
  printed argument is formatted rather than merely printed: inline when
  the AST shape proves it is (or is not) a Bool, and through a small
  generated helper only when it genuinely cannot be told.

---

## `target_js_core.py`

**The JavaScript backend's language half.** Knows nothing about
packaging.

- **The `Js*` AST** — `JsExpr`/`JsStmt` and their variants, including
  **`JsRuntimeCall`**, whose spelling is supplied by the packager. That
  one node is why the same core output serves all three JS targets.
- **`Scope`** — like the Python backend's, but far less busy:
  JavaScript's `const`/`let` are Pyking's `=`/`var` and `{ }` blocks are
  scopes, so it renames only where JavaScript forces it (`const`
  redeclaration, and the temporal dead zone), not on every shadow.
- **`translate_program` / `translate_stmts` / `translate_stmt` /
  `translate_expr`**, plus `translate_tail_stmts` for tail position and
  `declare_functions` for the same reason `target_python.py` has one.
- **`pprint_js_program` / `pprint_js_stmt` / `pprint_js_expr`** — the
  printer takes the `runtime` spelling to substitute into runtime calls.
- **`UnsupportedError(info, message)`** — anything outside the subset,
  with a position.

---

## `target_js_packaging.py`

**The JavaScript backend's packaging half**, and the JavaScript side of
the runtime interface — each host's `print`, and the shared `pykFormat`,
which is exactly what differs between the three targets.

- **`TARGETS`** = `("nodejs", "html", "esm")`, **`PRIMARY_EXTENSIONS`**.
- **`package_nodejs` / `package_html` / `package_esm_module` /
  `package_esm_node_driver` / `package_esm_html`** — one self-contained
  script, one self-contained page, and the module plus its two wrappers.
- **`package(target, js_program, source, output_path) -> {path:
  contents}`** — everything a target writes, so that `esm` writing four
  files is this module's business and not the driver's.
- **`primary_source(target, …)`** — what `--stdout` prints.
- **`esm_paths` / `output_stem` / `manifest_declares_module`** — how an
  `--output` path becomes the four `esm` files, and why an existing
  `package.json` is never overwritten.

---

## `target_c.py`

**The C backend**, serving both `c89` and `c23`. One backend rather than
two because the standards disagree about *printing* — comments, whether
declarations may follow statements, whether `bool` exists — not about
meaning, so `standard` reaches only the printer.

- **The `C*` AST**, and the type vocabulary `INT`/`BOOL`/`STRING`/`UNIT`
  with `_C_TYPES` and `_FORMATS` (the `printf` conversion per type).
- **`translate_program(stmts)`** — the translation, whose real work is
  the type inference C forces and Pyking never needed: every expression
  node carries a type, bindings take their initializer's, parameters
  their annotation (when C can represent it) or a guess from the body,
  and a function's return type is read off its translated body. Where
  inference cannot answer, it raises `UnsupportedError` rather than
  emitting C that will not compile.
- **`pprint_c_program(program, standard, source)`** and its statement and
  expression printers — the only place `standard` is consulted.
- Prototypes are emitted ahead of the definitions, so a call may name a
  function written further down.

---

## `target_java.py`

**The Java backend**, serving `java8`, `java17` and `java21` — the same
shape as the C backend, with a `version` parameter instead of a
`standard`. The three versions differ only in whether a local declaration
writes `var` (Java 10's local-variable type inference) or spells its type
out.

- **The `J*` AST** — `JInt`, `JStr`, `JBool`, `JVar`, `JBinary`,
  `JCall`, `JCond`, **`JEquals`** (`.equals()`, since Java's `==` on
  strings compares references), and the statement variants.
- **`translate_program(stmts)`** — infers types the way `target_c.py`
  does, and additionally proves two things `javac` insists on:
  **`_definitely_returns`** (every path of a value-returning function
  returns) and **`_check_reachable`** (nothing follows a statement that
  always returns). Both are refused at compile time with a position.
- **`pprint_java_program(program, version, class_name, source)`**.
- **`default_class_name(stem)`** — Java requires the file and its public
  class to match exactly, so `foo_bar.pyk` becomes `FooBar.java`. The
  driver applies it; deriving a class name from an explicit `--output` is
  this module's business.

---

## `target_ocaml.py`

**The OCaml backend**, and the one that infers nothing: it *runs*
`typesystem.type_check` and reads the types back out of `tmap`, which is
why the checker records an entry for every expression. Its supported
subset is therefore exactly the checker's, and a program that does not
check is refused with the checker's own message.

- **`TARGET`** = `"ocaml"`, **`EXTENSION`** = `".ml"`, and the `O*` AST.
- **`translate_program(stmts)`** — most of the translation is direct
  (`let … in` is a block scope, a rebinding is a new binding, `let rec …
  and …` is Pyking's rule that every `def` in a block is visible
  throughout it, and `true`/`false`/`()` are spelled identically). The
  interesting work is what it emits *around* that: no type annotations at
  all, `rec` only where something recurses, `_name` for a binding nothing
  reads, and — via **`_Effects`** and **`in_order`** — a `let` inserted
  wherever two operands of one expression can both print, since Pyking
  evaluates left to right and OCaml does not promise to.
- **`pprint_ocaml_program(program, source)`**.

The test harness builds this target's output with `-w +a`, so a compiler
warning about generated code is a failing test.

---

## `pyk.py`

**The driver.** It parses argv, sequences the stages, reports errors, and
dispatches to one of four commands. Everything else — translation,
packaging, file naming — belongs to the backends.

```
pyk <file>              run it with the python backend
pyk run <file>          run it with the interpreter
pyk repl                start the REPL
pyk compile <file>      compile it (alias: pyk c)
```

### Data structures

- **`Options`** — everything argv said, as one frozen value: the command,
  the filename, and the flags. Flags are shared by every command rather
  than per-command, so `--tokens` and `--ast` mean the same thing
  wherever they are written.
- **`TARGETS` / `EXTENSIONS`** — built from the backends themselves, so
  the usage message and the default output name cannot drift from what
  the compiler actually supports.
- **`ERROR_KINDS`** — one row per stage that can refuse a program, in the
  order the stages run: `LexError`, `ParseError`, `AnalysisError`,
  `TypeError_`, `RuntimeError_`. Every one carries an `Info`, which is
  what lets them all be reported the same way.

### Main functions

- **`main(argv) -> status`** — argv in, exit status out.
- **`parse_args(argv) -> Options`**; anything malformed ends in
  **`usage_error`**, which prints the usage after the complaint.
- **`front_end(options) -> (program, tmap)`** — lex, parse, analyse,
  symbolize, and type-check when asked (or when `pyk run` asks, since
  that is the interpreter's gate). The name analysis runs for every mode
  *except* when the checker does, which replaces it.
- **`command_python` / `command_run` / `command_compile` /
  `command_repl`** — the four. `command_repl` imports `repl` lazily,
  because the REPL is handed this module's own `format_error` and
  importing it at the top would be a cycle.
- **`format_error(error)`** — any front-end error as one
  `'file' row:col-row:col Kind: message` line, reflowed. Used here and
  handed to the REPL.
- **`wrap(text)`** — every message this module prints is reflowed to 70
  columns with continuation lines indented, so a long path or diagnostic
  stays readable in a narrow terminal.
