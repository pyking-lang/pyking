# `module.ml`: design

How `src/module.ml` turns a file into a program: which modules a program
is made of, in what order they are compiled and run, what each of them
exports, and what each import means. For what the rules *are* (as
language, not implementation), see PYKING.md, "Modules"; for where this
module sits in the pipeline, see [architecture.md](architecture.md); for
what each target does with a module, see [targets.md](targets.md) and
the per-family pages.

## Three steps, in one order

A program of several modules is compiled in three steps, and the order
is the whole design:

1. **Load.** `load(path)` reads the program's own file, and then every
   module it imports, and every module *those* import. It refuses a
   cycle while it is doing so, and answers with the modules in
   dependency order -- everything a module imports comes before it, and
   the program's own module is last.
2. **Check, module by module, in that order.** The type checker is run
   once per module, and is given the *signature* of each module this one
   imports: `sigmaps`, pairing a module's name with what it exports and
   at what type.
3. **Make the signature.** `make_sigmap(stmts, tmap)` reads the checker's
   result back and keeps the public names' types. That is the input step
   2 needs for the next module, which is why the three steps run in a
   loop rather than as three passes.

There is always at least one module that imports nothing, and that is
where it starts. Nothing else could: the graph is acyclic, so it has a
source.

## The graph is built while it is walked

`visit` is an ordinary depth-first search over the import graph, and it
does three things at once. It reads and parses each module it reaches
(`read_file`). It appends each one to `order` *after* everything that
module imports, which is a topological sort. And it carries the path of
imports it is following in `stack`, which is what makes a cycle
findable: reaching a module already on the stack is a cycle, and the
ring to report is the tail of the stack from that module round to
itself.

A module already in `parsed` but not on the stack has been finished, so
the walk stops rather than reading it twice -- which is also what makes a
diamond (two modules importing a third) one module rather than two.

## One numbering across the whole program

Every node of every module gets a symbol from one sequence:
`analyses.symbolize(stmts, start)` continues past `start`, and each
module is handed the highest the one before it reached. That is what
lets a single type table and a single call-free table span a program of
several modules -- and it matters at run time, because a closure a
module exports is called from the module that imported it, and the table
it is read against is the *calling* machine's (see
[interpreter.md](interpreter.md)).

`--no-typechecking` is the one path that does not go through `load` at
all: it stops the front end after `symbolize`, and reading a module the
program imports is something only the stages after that need, so it
reads the one file it was given (`read_file`) and nothing else.

## What a module exports

`check_publics` answers with the names a module exports and where each
was made public, and refuses two things while it does: a name exported
twice, and an exported name bound more than once at the top level. Both
are the same rule -- a module exports one thing under one name -- and
having it here means every later stage can take "this name means that
definition" for granted.

A `def` may be marked on its definition or on its own signature line, so
one name can be marked twice and still be one definition;
`one_definition` is what tells that from two different things sharing a
name. Two `def`s of one name is not this module's error to report:
`analyses.block_functions` already refuses it, in its own words.

## Default parameters cross the boundary

A `public` function's default parameters work from another module. The
mechanism is the one `src/desugar_args.ml` uses everywhere: a default is
a generated `def` named `<function>__default__<parameter>`, and it
inherits the `public` of the function it belongs to — so it is exported
like any other name, appears in `check_publics`, in the sigmap and in a
plain import's field list, and can be called as `mod.greet__default__who()`
by anyone who cares to.

`load` desugars each module in dependency order, threading the pass's
own table, so by the time a module is rewritten every module it imports
has been and their parameter lists are known. Because the generated
defs only exist after that pass, `load` computes each module's
`publics` again once it has run.

The two import forms reach a default differently. `import mod` gives the
call `mod.greet__default__who()`. `from mod import greet` has no module
name to qualify, so the pass **adds the generated names to that import's
own field list** — the tree holds `from mod import greet,
greet__default__who` — and the call is a plain `greet__default__who()`.

An **exported** function's defaulted parameter must carry a type
annotation. Without one the generated def is unannotated, and
`typesystem.check_exports` refuses exporting a `def` whose type the
source does not write down.

An **external** module's functions take neither defaults nor named
arguments: what they offer is written in a target language, which has
no parameter names Pyking can see. A declaration file cannot carry a
default either, since it holds signatures and a signature is a type.

## What an import means

`resolve_imports` settles two things that the parser could not.

**A plain import's fields.** `import list` says nothing about what it
brings in; what it brings in is whatever `list` exports. So the
statement's `fields` list is *empty* out of the parser and filled in
here, from the imported module's public names. That is why the modules
are resolved in dependency order too: the module being resolved has
already been read, so its public names are known.

**Whether the names are free.** Everything an import brings in -- a
module's local name, or each name a `from` line takes -- is claimed in a
table that starts with the builtins and holds every name the module's
own top level binds. A second claim on one name is refused. It is the
one check that has to see both sides of the boundary, which is why it is
here and not in the checker.

A `from` line naming something the module does not export is refused
here as well, with a different message where the module *has* that name
but did not mark it `public`: that is a different mistake from naming
something that is not there, and worth saying so.

## The signature is a map from a name to a type

`sigmap` is `[(String, Type, Bool)]` -- one entry per exported name,
its type, and whether it was written `implicit` -- and it is the whole
of what one module sees of another. The types are the checker's own
`T*` nodes, read out of the `tmap` it returned, so an imported
polymorphic function arrives with its `all` intact and instantiates at
the call like any other.

The **names** are the source's own, since that is what the file
importing the module writes. The sigmap a *backend* is handed is
different: `Module.context` renames each entry with `Names.renamed` and
folds its implicit parameters in with `Typesystem.without_implicits`,
because that is what the generated file declares
(docs/overloading.md).

It is made from the program the *checker* saw, before the tail-call pass
runs: that pass can change how a module computes what it exports, never
what it exports or at what type.

**A module says what it exports, and is refused if it cannot.** An
exported name carries its complete type in the source: a public `def`
annotates every parameter and its return type or has a signature line
of its own, and a public `=` binding annotates its name.
`typesystem.check_exports` refuses the module otherwise -- in the file
that exports it, rather than leaving the module that imports it to find
out. That is what makes the sigmap total, and `make_sigmap` relies on
it.

A `def` that annotated nothing has no type until something calls it
(`infer_definition`), because inference reads a definition off its own
module's use of it. Such a call settles what this module's own program
needs, so it is not taken as a promise to another one: an exported name
says its type where it is exported. The rule also keeps the order
honest: a module is checked before anything that imports it, and by the
time that check is done it knows everything it offers.

The checker reads it back through `import_env`, which puts a selected
name in the environment under the name it is known by here and a field
of a plain import under `alias.field` -- the spelling `EQualified` looks
up. So a qualified name is an ordinary environment lookup, and there is
no second mechanism for reaching across a module boundary.

Imports go into the environment *before* the first statement is checked
rather than as the walk reaches them. They are declarations of the
module, like a `def`, not statements in its sequence -- and it has to be
that way round, because a deferred definition's body is checked in the
environment recorded where it was written, which is the environment at
the start of the block.

## A public implicit is found unqualified

A name that is **both `public` and `implicit`** is reachable from an
unqualified call in the importing file, and from the implicit search,
as well as through the module name. It is still bound under one
spelling -- `alias.field` -- so a resolution names the module it came
from, and the generated call reads `mod.int__leq` rather than a name
nothing declared.

Nothing else is auto-imported, and it is not transitive: what a file
sees is what that file imports. See PYKING.md, "A public implicit
arrives unqualified", and [implicits.md](implicits.md).

## One file on its own

Two front ends compile a single file with no program around it: the REPL
and the browser playground. Neither can resolve an import -- there is no
other file to reach -- so `typesystem.available` refuses one in both, in
the same words, rather than each saying it differently.

What a module *exports* is a different question, and one that needs only
the file: `check_publics` refuses a name exported twice, or an exported
name bound twice, without looking at anything else. The playground runs
it for that reason, so a program the compiler would refuse is refused
there too. The test suite depends on it: a `fail_typecheck_module_*`
program has to be refused by every front end that claims to compile a
file, and the playground's own check asserts exactly that.

A program that imports is not offered as a playground example at all,
nor are the modules it imports -- the page compiles one file, and a
module is not a program.

## Running and compiling a program of several modules

Every module's top level runs once, in dependency order, and its public
bindings are what the modules importing it are given.

An external module has no top level at all: what it exports is the
host's, so nothing of it runs and no backend starts it.

`interpreter.run_modules` does that directly: each module runs in a top
level of its own, and `exported_values` reads its public names out of
the environment it left behind. It uses `run_entry` rather than
`enter_block`, because a block puts the enclosing scope back when it
ends and a module's top level has no enclosing scope to go back to --
what it bound is what it exports.

Each backend does the same thing in its host language's own terms, and
the differences between them are what [targets.md](targets.md) and the
family pages describe. Two shapes cover all of them: hosts with a module
system of their own (Python, JavaScript, OCaml) let the host's import
run the module, and hosts without one (C, Java) get an explicit
`<module>_init()` / `Module.init()` that the program's own entry point
calls, in the order `load` gave.

`module.Context` is what a backend is told about the module it is
compiling beyond its statements: its name, whether it is the program's
own module, whether the program has more than one module at all, the
modules to start before it, and every module's sigmap. A program of one
module gets a `Context` that says so, and every backend then emits
exactly what it emitted before there were modules -- which is what keeps
the module system from showing up in the output of a program that has no
modules.

## External modules

A module can be implemented in the target's own language instead of in
Pyking. `sys.external.pyk` declares what it offers and at what type;
`sys_external.py`, `sys_external.js`, `sys_external.c`,
`SysExternal.java` and `sys_external.ml` implement it, one per target
family.

```
public def loadfile : (String) -> String
public def start    : Int
```

That is the whole of the declaration file. `import sys` reaches it
exactly as it reaches an ordinary module -- a qualified name is an
environment lookup, the checker holds every call to the type written
here, and nothing about the call site says which kind of module it is.

**`sys.external.pyk` is read; the implementation is not.** The compiler
lexes and parses the declaration and nothing else. It never reads,
rewrites or renames the implementation: it copies the one file for the
target being compiled beside the program's own output, under the name
the host itself resolves the module by, and leaves the rest to the host
toolchain. Compiling in the directory the implementation already sits in
copies nothing, so a hand-written file cannot be truncated by its own
copy.

Nothing is *generated* for an external module -- not even the header or
interface the other targets get. C is told what the module offers by
declarations emitted into the file that imports it, and OCaml infers
module `Sys`'s interface from `sys.ml`.

### Finding it

`import sys` looks in the directory of the importing file for
`sys.external.pyk` and `sys.pyk`, and takes whichever it finds -- or
both, which is one module in two halves (see below). The first level of
the search that holds *either* answers, so a library's two halves always
come from one place.

The implementation is `<module>_external.<ext>`, which is what the
generated code refers to. The suffix is not decoration: a module may
also have a Pyking half, and `sys.js` is then the file generated from
`sys.pyk`.

| target | implementation | what the generated program does |
|---|---|---|
| `python` | `sys_external.py` | `import sys_external` |
| `node24` | `sys_external.js` | `import * as sys_external from './sys_external.js'` |
| `c89`, `c23` | `sys_external.c` | declares `sys_loadfile` and calls it |
| `java8`/`17`/`21` | `SysExternal.java` | `SysExternal.loadfile(...)` |
| `ocaml5.5` | `sys_external.ml` | `Sys_external.loadfile ...` |
| `web24`, `iweb24` | `sys_external.web.js`, else `sys_external.js` | `import * as sys_external from './sys_external.js'` |

Java's is capitalised where the others are not, because javac requires
the file name and the public class to match. C is the one target whose
*symbols* are not named after the file: a name there is
`<module>_<field>`, so `sys_external.c` defines `sys_loadfile`.

A module's name becomes a name in the host's own namespace. The Python
backend handles the collision that follows -- `import time` would find
the interpreter's own -- by loading such a module by path instead (see
[target_python.md](target_python.md), "Module names Python has already
taken").

A target with no implementation file is refused before anything is
translated, naming the module and the file it looked for.

### Why a declaration file holds nothing else

A `.external.pyk` may contain signatures, and nothing but signatures --
no bodies and no top-level bindings. The file is a header, in the sense
C and OCaml already have one: it says what something else provides.

A signature there may be **private**. It is then in scope in the
module's own Pyking half and nowhere else, which is how a library keeps
a host function it needs without offering it. The boundary rule below
applies to a private signature exactly as to a public one, because what
crosses the boundary is the *call*, and the Pyking half makes it.

### A module in two halves

`foo.pyk` and `foo.external.pyk` are one module `foo`. Either may stand
alone -- a module written only in Pyking, or one only declared -- and
together they are still one name to whoever imports it.

```
lib/foo/foo.pyk            public def f1(x:Int): x * 2
                           public def f2(x:Int): g2(x)
lib/foo/foo.external.pyk   public def g1 : (Int) -> Int
                           def g2 : (Int) -> Int
lib/foo/foo_external.js    export function g1(x) { ... }
                           export function g2(x) { ... }
```

A program says `import foo` and calls `foo.f1`, `foo.f2` and `foo.g1`.
`foo.g2` is refused: `g2` is not public, so it is the module's own.

Three things make that work, and the first is the only one a reader of
Pyking sees:

- **The declarations are in scope in the Pyking half**, unqualified.
  `f2` calls `g2` as it would call anything else of its own module,
  because it is.
- **A qualified name reaches whichever half provides it.** The compiler
  answers that question once, in `Module.reached_module`, and every
  backend asks it rather than deciding: `foo.f1` reaches the file
  generated from `foo.pyk`, and `foo.g1` the implementation. The
  generated file imports the implementation too, which is what lets
  `f2` reach `g2`.
- **Each half exports only what it holds.** The generated file exports
  `f1` and `f2`; an importer reaches `g1` in the implementation
  directly. Exporting a name the file never declared would be a
  syntax error in JavaScript and a missing value in OCaml.

C is the exception that shows the rule: a name there is
`<module>_<field>` whichever half provides it, and both halves are
linked into one program, so nothing needs rewriting. C and Java do not
compile a module in two halves yet -- each refuses one with a message --
though both compile a module that is only a declaration half.

### What may cross the boundary

The types a declaration may name are the ones the target can carry, and
they are not the same everywhere:

| Pyking | python | node24, web24, iweb24 | c89, c99, c23 | java | ocaml |
|---|---|---|---|---|---|
| `Int` | `int` | `number` | `int` | `int` | `int` |
| `Float` | `float` | `number` | `double` | `double` | `float` |
| `String` | `str` | `string` | `const char *` | `String` | `string` |
| `Bool` | `bool` | `boolean` | `bool` / `int` | `boolean` | `bool` |
| `()` | `()` | `undefined` | `void` | `void` | `unit` |
| `(A, B)` | `tuple` | `Array` | refused | refused | tuple |
| `[A]` | `list` | `Array` + marker | refused | refused | `list` |

Three of these need care from whoever writes the implementation.

**An `Int` holds at least the signed 32-bit range, and past it the
result is undefined** (PYKING.md, "Integer and string literals"). An
implementation therefore has nothing to normalise: return whatever the
host computes. What it must not do is narrow the range *below* 32 bits —
a value inside it has to survive the round trip on every host.

**A `Float` needs no care at all on four of the five, and one caveat on
JavaScript.** It is IEEE 754 binary64 everywhere, so nothing is
converted at the boundary — but a JavaScript number cannot say whether
it is an Int or a Float, so an implementation is free to answer `2`
where the declaration says `Float` and the value is right either way.
What makes it *print* as `2.0` is the declared type, which the importing
module compiles from. The one gap is the `iweb` target, where the
interpreter runs in the page: a value coming back through JSON has only
its own shape to go on, so an external module cannot yet return a Float
there. Nothing under `lib/` declares one, and every compiled target
carries it (`tests/external_float.pyk`).

**A `.web.js` may differ from a `.js`.** The `web` and `iweb` targets
look for `sys_external.web.js` before `sys_external.js`, so a module
that needs different code in a browser writes both and one that does not
writes one. The file found is copied out as `sys_external.js` either
way, which is the name every generated import uses.

**A JavaScript list must say it is one**, and on the `iweb` target that
marker has to survive JSON: a value crossing into the interpreted page
is encoded by `src/web/stub.js`, which writes a tuple as
`{"pyk_tuple":[...]}` because `JSON.stringify` would drop the marker and
every array would arrive as a list.

A Pyking list and a Pyking
tuple are both arrays there, and the value formatter walks values rather
than reading types, so a list carries `pykList === true` and a tuple
does not. An implementation returning a plain array for a `[Int]` will
have it printed as a tuple. `tests/external_shapes_mod1.js` is the
worked example.

**A C `Bool` is spelled differently by the two standards.** `c89`
declares it `int` and `c23` declares it `bool`, because that is what
each standard has, and the declaration the importing file carries says
so. One `sys.c` serving both targets has to agree with whichever it is
compiled under -- the usual `#if __STDC_VERSION__ >= 199901L` around
`<stdbool.h>`, with a `typedef int bool` otherwise.
`tests/external_all_mod1.c` is the worked example. Getting this wrong
links and appears to work on most ABIs, which is exactly why it is
worth saying: the declaration and the definition are in different
translation units, so no compiler sees both.

**A function may not cross at all.** Handing a Pyking closure to a host
would need a calling convention on the other side, and there is none
yet, so a declaration naming a function type anywhere inside itself is
refused. A type variable is refused for a related reason: one
implementation cannot be polymorphic.

### Running one

It cannot be interpreted. `pyk prog.pyk` and `pyk repl` run the AST, and
what an external module exports has none -- it is written in a target
language. Importing one is refused there, and a program that uses one
has to be compiled. This is why such a program lists no `interpret`
target in `tests/test_cases.toml`, and why the harness does not warn
about its absence.

An external module has no Pyking top level either, so nothing runs
before the program's own: it is not among the modules a backend starts,
and C and Java emit no `<module>_init()` call for it.

## Where the files go

A module is compiled to a file beside the program's own output, named
after the module and given the target's extension -- `helper.py`,
`helper.js`, `helper.c` and `helper.h`, `Helper.java`, `helper.ml` and
`helper.mli`. The generated import in the program's output names it by
that name, so the two agree by construction.

`src/execution.ml` is where `--run` learns the rest: which of those
files have to be handed to the compiler, and in which order. For C, Java
and OCaml that order is the dependency order, since those three link a
program rather than importing at run time -- and for OCaml it is also
the order the modules' top levels run in.
