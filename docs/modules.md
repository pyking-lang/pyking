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

`sigmap` is `{String: Type}` -- one entry per exported name -- and it is
the whole of what one module sees of another. The types are the
checker's own `T*` nodes, read out of the `tmap` it returned, so an
imported polymorphic function arrives with its `all` intact and
instantiates at the call like any other.

It is made from the program the *checker* saw, before the tail-call pass
runs: that pass can change how a module computes what it exports, never
what it exports or at what type.

**A module says what it exports, and is refused if it cannot.** A `def`
that annotated nothing has no type until something calls it
(`infer_definition`), because inference reads a definition off its own
module's use of it. So an exported one has to be either fully annotated
or called somewhere in the module that exports it, and
`typesystem.check_exports` refuses the module otherwise -- in the file
that exports it, rather than leaving the module that imports it to find
out. That is what makes the sigmap total, and `make_sigmap` relies on
it.

Inferring such a definition here instead would mean inferring it from no
use at all, and would move the failure to whoever imported it. The rule
also keeps the order honest: a module is checked before anything that
imports it, and by the time that check is done it knows everything it
offers.

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
