# The interfaces between modules

Every module in `src/` has an `.mli` beside it — bar the two entry
points, which nothing calls. The `.mli` is the module's contract: what
another module may use, and nothing else. Everything a module does not
name there is unreachable from outside it, whatever the `.ml` defines.

This page is the map of those contracts — which module may refer to
which, what crosses each boundary, and which types are opaque. For what
each module *is* see [source.md](source.md); for the pipeline it sits in
see [architecture.md](architecture.md); for how the two dune targets are
put together see [build.md](build.md).

## The rule

**A name is in an `.mli` only if something outside its own module calls
it.** A function or value used only inside the module that defines it
stays private, however much it reads like an API from the outside.

That is checkable, and it is checked: every `val` in every `.mli` here
has at least one caller in another module, with the single exception
named at the end of this page.

Everything else is private, including a great deal that reads like an
API: each non-terminal of the parser, each `check_*` of the type
checker, each `translate_*` of a backend, the scope every backend
threads, and every helper that formats a message.

Types follow the same rule and one more: **a type is abstract unless a
caller has to look inside it.** A caller that only makes a value with
one function and hands it to another needs no constructors, so it does
not get them.

## The module graph

The library is flat and unwrapped — a module is `Parser`, not
`Pyking.Parser` — and the references between them are acyclic. Read the
stack downwards: a module may refer to anything below it and nothing
above it. `src/dune`'s `modules` field lists them in an order that
respects that, which is what makes the library link.

```
┌──── the entry points ────────────────────────────────────────────────┐
│                                                                      │
│  pyk.ml              the driver: argv, the stages, and one of        │
│                      five commands. Links unix, and with it          │
│                      repl.ml, execution.ml and web_tools.ml.         │
│  web/pyking_web.ml   the playground: the same stages, answering      │
│                      JSON. Compiled to JavaScript by js_of_ocaml.    │
│                                                                      │
│  Both export nothing. Each is run by the `let () = ...` at the       │
│  bottom of its own file, and nothing may depend on either.           │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
                                    │
┌──── the executable's other modules ──────────────────────────────────┐
│                                                                      │
│  repl.ml         start           the prompt, and the editor it is    │
│                                  typed into                          │
│  execution.ml    execute,        what --run builds and runs          │
│                  pyking_target                                       │
│  web_tools.ml    start, tool     pyk notebook / pyk playground:      │
│                                  hands over to the tool's server     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
                                    │
┌──── the library: unwrapped, and depends on nothing ──────────────────┐
│                                                                      │
│  the backends    translate_program, pprint_<lang>_program,           │
│                  Unsupported                                         │
│    target_python.ml  target_js_core.ml ──▶ target_js_packaging.ml    │
│    target_c.ml       target_java.ml        target_ocaml.ml           │
│                              │                                       │
│                              ▼                                       │
│  interpreter.ml  the embedding API: run_program, run_modules,        │
│                  initial_state/step/run, result/failure/             │
│                  stack_trace, declare_entry/eval_in, and the         │
│                  value a prompt or a page shows                      │
│                              │                                       │
│                              ▼                                       │
│  opt_tailcall.ml optimize                                            │
│                              │                                       │
│                              ▼                                       │
│  typesystem.ml   type_check, and what checking a session one         │
│                  entry at a time needs                               │
│  type_experiment.ml   type_check, for the fragment it covers         │
│                              │                                       │
│                              ▼                                       │
│  module.ml       load, make_sigmap, check_publics, the path          │
│                  helpers, and what a backend is told (context)       │
│  elaborate.ml    program: overloading and implicits out of the AST   │
│                              │                                       │
│        ┌──────────┬──────┴─────────┬────────────────┐               │
│        ▼          ▼                ▼                ▼               │
│  parser.ml   desugar_args.ml  analyses.ml     targets.ml            │
│  parse       desugar,         symbolize,      all, default,         │
│              no_signatures,   highest_sym,    resolve, family_of,   │
│              external_module, analyze_mutability, members,          │
│              generated_name   block_functions, extension            │
│                    │          target_names,                         │
│                    │          pattern_bindings,                     │
│                    │          effects/may_print                     │
│                    │                │                               │
│                              │                                       │
│                    ┌─────────┴─────────┐                             │
│                    ▼                   ▼                             │
│             walk.ml             builtin.ml         names.ml          │
│             children, fold,     names, pure_names, is_qualified,     │
│             exists, fold_stmts, lookup,            base, renamed,    │
│             exists_stmts,       crosses_host       qualifier, field  │
│             name_field                                               │
│                    │                                                 │
│                    ▼                                                 │
│             syntax.ml    the AST, its accessors, pprint_program      │
│                    │                                                 │
│                    ▼                                                 │
│             lexer.ml     info, token, lexing, keywords               │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

The arrows pick out the edges worth naming; the layering is the rule.

Two modules are `open`ed rather than qualified, and they are the ones
whose contents are the compiler's shared vocabulary rather than a
service. `Syntax` is opened by the fourteen modules that work on the
AST: `walk.ml`, `analyses.ml`, `desugar_args.ml`, `parser.ml`,
`module.ml`, both checkers,
`opt_tailcall.ml`, `interpreter.ml`, `repl.ml` and the five language
backends. `Lexer` is opened by eleven — ten of those, and `syntax.ml`
itself, whose nodes carry an `info`. `target_js_packaging.ml` opens
neither and opens `Target_js_core` instead, whose AST it works on.

## What calls what

The driver is the one module that touches nearly everything. This is a
compile, with the crossing named at each step:

```
 Pyk.main argv
   │
   ├─ Module.load filename                          every module, in
   │    ├─ Lexer.chars_of_string, Lexer.lexing       dependency order
   │    ├─ Parser.parse
   │    ├─ Analyses.symbolize ~start
   │    └─ Analyses.highest_sym
   │
   ├─ for each module of the program, in that order:
   │    ├─ Typesystem.type_check stmts sigmaps        → tmap
   │    │    ├─ Analyses.block_functions              (the same rule the
   │    │    ├─ Analyses.builtins                      front end applies)
   │    │    └─ raises Analyses.Analysis_error         for an unbound name
   │    ├─ Analyses.analyze_mutability stmts
   │    ├─ Optimization.optimize stmts tmap           → stmts, tmap
   │    │    ├─ Typesystem.same_type, Typesystem.covers
   │    │    └─ Walk.fold_stmts, Walk.name_field
   │    └─ Module.make_sigmap stmts tmap              → the next module's
   │                                                    sigmap
   │
   ├─ pyk <file>
   │    └─ Interpreter.run_modules units Interpreter.console_host
   │         then Interpreter.failure / .stack_trace
   │
   └─ pyk compile -t <target>
        ├─ Target_python.translate_program stmts tmap
        │    └─ Target_python.pprint_py_program
        ├─ Target_js_core.translate_program ~taken stmts
        │    └─ Target_js_packaging.package_program
        │         └─ Target_js_core.pprint_js_program, .uses
        ├─ Target_c.translate_program stmts context
        │    └─ Target_c.pprint_c_program / .pprint_c_header
        ├─ Target_java.translate_program stmts context
        │    └─ Target_java.pprint_java_program
        ├─ Target_ocaml.translate_program stmts tmap context
        │    └─ Target_ocaml.pprint_ocaml_program / .pprint_ocaml_interface
        ├─ -t pyking: Syntax.pprint_program stmts symbols tmap
        └─ --run:     Execution.execute target path modules
```

`Module.context` is what every backend that compiles a module *as part
of a program* is told beyond its statements, and it is one value rather
than a growing list of parameters. `Targets` is the only place a target
is named: `pyk.ml`, `module.ml`, `execution.ml` and four of the backends
read their own names back out of it.

Three crossings are worth naming because they are not the pipeline:

- **`Interpreter.binary_operands`** is called by `target_c.ml`,
  `target_java.ml`, `target_js_core.ml` and `target_python.ml`. The
  interpreter is the reference for what an operator means, so the
  backends ask it which two expressions an operator application holds
  rather than each matching the ten constructors again.
- **`Analyses.effects` / `Analyses.may_print`** are called by
  `target_c.ml` and `target_ocaml.ml` alone — the two hosts that leave
  the order of an operator's operands unspecified, and so have to pin
  down the operands that can print.
- **`Module.public_names`, `.external_signatures`, `.is_declaration`**
  are called by `interpreter.ml`, which has to run a program of several
  modules and reach an external one through its host.

The two other front ends call the same library functions the driver
does. `repl.ml` is the only caller of the type checker's entry-at-a-time
half (`builtin_env`, `empty_store`, `declare_functions`, `check_stmt`,
`check_expr`, `zonk`, `displayed`, `settled_type`) and of the
interpreter's (`initial_state`, `declare_entry`, `eval_in`, `result`,
`bindings_in_scope`); `web/pyking_web.ml` calls `Module.load` with its
own `sources`, so a program of several modules can run in a page with no
filesystem under it.

## The opaque types

Most of what the compiler passes between modules is the AST, and that is
public in full: `syntax.ml` declares it and fourteen modules match on
it.
Beyond that:

| type | in | shape | why |
|---|---|---|---|
| `Lexer.info`, `Lexer.token` | `lexer.mli` | public | the parser matches tokens; every stage reads a span's fields |
| the AST groups | `syntax.mli` | public | the whole compiler is `match`es over them |
| `Syntax.config` | `syntax.mli` | abstract | a caller starts from `default_config` or calls `pprint_program`, which builds one |
| `Analyses.kind`, `.binding`, `.env` | `analyses.mli` | public | the REPL carries a session's bindings and makes a builtin's |
| `Analyses.effects` | `analyses.mli` | abstract | `effects` makes one, `may_print` reads it |
| `Desugar_args.signatures` | `desugar_args.mli` | abstract | `module.ml` threads one through its fold and never looks inside; the REPL keeps one in its session |
| `Module.t`, `.context`, `.sources` | `module.mli` | public | the driver reads a module's name and path, a backend reads its context, the playground supplies its own sources |
| `Typesystem.store` | `typesystem.mli` | public | see below |
| `Typesystem.binding`, `.env` | `typesystem.mli` | public | the REPL carries a session's environment from one entry to the next, and `:ls` reads whether a name is implicit |
| `Typesystem.resolution`, `.argument` | `typesystem.mli` | public | `elaborate.ml` rewrites the program by them, node for node |
| `Interpreter.value` | `interpreter.mli` | public | a prompt and a page show values |
| `Interpreter.env` | `interpreter.mli` | abstract | `bindings_in_scope` is all a caller needs of a frame chain |
| `Interpreter.state` | `interpreter.mli` | a record of opaque parts | a caller keeps a state and reads its `env`; `control`, `kont`, `frame`, `loop` and `runtime` are the machine's own |
| `Target_js_core.jsexpr`, `.jsstmt`, `.jshost` | `target_js_core.mli` | public | the packager decides how a runtime call and an import are spelled, and both reach it as nodes |
| `Target_js_core.jstarget` | `target_js_core.mli` | abstract | nothing outside the core looks inside a binding's target |
| `cprogram`, `jprogram`, `oprogram`, `pyprogram` | the four other backends | abstract | `translate_program` is the only thing that makes one and the printer the only thing that reads one |
| `Elaborate.program` | `elaborate.mli` | -- | takes `qmap` and `tmap` and answers the rewritten module and an extended `tmap`; the pass keeps nothing |
| `Repl.session`, `.reader` | `repl.mli` | abstract | `start`'s own parameters, for driving a session without a terminal |

**`Typesystem.store` is the one interface here that is wider than it
should be.** It is the whole of what inference has worked out — eleven
fields — and `repl.ml` needs exactly one of them: it starts each entry
with an empty `tmap` and reads the table back afterwards. Two accessors
in `typesystem.ml` (`tmap` of a store, and a store with an empty one)
would let the type be abstract like the interpreter's `env`. Until then
the fields are visible, and nothing but `repl.ml` reads them.

## The two files with no interface

`pyk.ml` and `web/pyking_web.ml` are entry points, not modules anything
calls, and neither has an `.mli`. Both are run by a `let () = ...` at
the bottom of the file: `pyk.ml` by `exit (main ...)`, and
`pyking_web.ml` by registering its entry points on the global object
through the primitives in `stub.js`. dune gives an executable's main
module an empty interface of its own, so a hand-written file holding no
`val` would only restate what dune already enforces.

Nothing may depend on the driver, which is what keeps every stage usable
from the other two front ends. `pyk.ml` hands `format_error` to
`repl.ml` as an argument rather than the REPL importing it — a cycle
otherwise, and the reason the REPL reports a mistake at the prompt in
the words a file would get.

## The two exceptions

Both are named, so that a third has to be argued for rather than
assumed.

**The interpreter's embedding API.** `Interpreter.step`, `.run`,
`.format_value` and `.eval_statement` have no caller outside their own
module. `design/plan-eval-lsp.md` names each of them as the surface the
debugger, DAP and LSP servers are to sit on: `run_program` and
`run_modules` are `step` and `run` with the loop written for the caller,
and a debugger will want the loop itself.

**`walk.ml`.** `children` and the folds built on it are the compiler's
one shared traversal, and the module exists to be called that way, so
they stay exported whether or not each has a caller today. `fold` is the
one with none — it is the primitive the other four are written over, and
a pass wanting a shape they do not cover needs it.

Nothing else in `src/` is exported without a caller.

## Keeping them in step

Adding a function to a module does *not* mean adding it to the `.mli`:
leave it private until a second module needs it. When one does, add the
`val` with its docstring — two parts, what it does and a type signature
in the AST's own notation (`[T]` for a list, `T?` for an option,
`(A, B)` for a pair), as everywhere else in `src/`.

A new module in `src/` needs its `.mli` in the same change, a row in
`src/dune`'s `modules` field in an order that keeps the graph acyclic,
and an entry here and in [source.md](source.md).

The build is warning-free, and two of the warnings that keep it that way
were not available before the interfaces existed. Both mean the same
thing -- something is dead -- so fix rather than silence them:

- **Warning 32/34, an unused private value or type.** With an `.mli`, a
  definition that is neither exported nor used inside its own module is
  reachable from nowhere. Without one, every definition was implicitly
  public and the compiler could never say so.
- **Warning 37, an unused constructor.** A private variant whose
  constructor is only ever matched and never built is a case that
  cannot happen.

Narrowing the interfaces to the rule above turned up six more names
reachable from nowhere, and those went the same way: `Targets.expand`,
`Runtime_interface.names`, `Syntax.comp_info`, `Walk.exprs`,
`Walk.stmts_in` and `Interpreter.buffer_host`. Two others were kept and
made private instead, since each is used inside its own module:
`Interpreter.finished` and `Interpreter.max_call_depth`. `Walk.fold` was
made private on the same ground and then exported again, as the second
exception above.

Adding the interfaces in the first place turned up eleven. Ten were
leftovers of superseded designs and were removed in the same change --
twelve definitions in all, since the prelude markers went with the
function
that emitted them: a `browser ()` from before `--run` printed a URL for
the `web` targets instead of launching one, a `PyDiv` node for a `/`
the Python backend compiles to `PyFloorDiv`, the prelude markers no
JavaScript file writes any more, two per-backend target lists that
`Targets` now answers, and three diagnostic name tables nothing reports
from. The eleventh was `type_experiment.ml`'s `env`, which every
docstring in that module names and which a parameter annotation now
uses.
