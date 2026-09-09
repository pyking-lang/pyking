# `builtin.ml`: design

How `src/builtin.ml` collects what the compiler knows about the names a
Pyking program may call without binding them, why that is one table
rather than a fact each stage keeps a copy of, and what deliberately
stays outside it. For a one-page summary see
[source.md](source.md#builtinml); for where it sits in the pipeline see
[architecture.md](architecture.md), "The builtins and the host
boundary".

## Four readers, one table

`print`, `range`, `str` and `len` are in scope in every program and are
bound by nothing. Four parts of the compiler need that fact, and each
needs something different about it:

- `typesystem.ml` puts the names in the environment before the first
  statement is checked, and checks each call's arity against the one it
  is allowed.
- `interpreter.ml` binds each name to a callable value, and computes
  what each one answers.
- `module.ml` needs the names, since nothing a program imports may take
  one.
- every backend needs to know which calls *leave* the program, and
  which of the rest it has no translation for.

Those are four questions about the same four names, and before this
module they were answered from four independent lists: `analyses.ml`
held the names, `runtime_interface.ml` held `print` alone with its arity
and its semantics, `target_js_core.ml` held `["str"; "range"; "len"]` as
the ones it refuses, and `target_ocaml.ml` held the same three in a
different order as the ones it translates. `target_python.ml` held no
list at all and matched the names as literals in five separate arms.
Nothing made any of them agree, so adding a builtin meant finding all of
them.

## What the table holds

```ocaml
type t = {
  name : string;
  min_args : int;
  max_args : int option;
  crosses_host : bool;
  doc : string;
}
```

`max_args` is an option, and `None` *is* variadic — there is no separate
flag that could disagree with the bounds. `print` is `(0, None)`, which
is why it never fails an arity check; `str` and `len` are `(1, Some 1)`;
`range` is `(1, Some 3)`.

The order of the table is the order the playground publishes as its word
list (`pykBuiltins`), so it is the order someone writing Pyking sees.

The table itself is private. A caller asks for `names`, for
`pure_names`, for one entry by `lookup`, or for the single property a
backend branches on, `crosses_host` — the same arrangement
`src/targets.ml` uses for the target table, and for the same reason: a
caller reading rows would be free to ask a question the module has not
agreed to answer.

`doc` is the one field nothing reads. It is the specification of what
the builtin means, kept beside the arity it is checked against rather
than in a comment somewhere else, and it is what a new operation is
written into first.

## The host boundary is a field, not a module

A Pyking program on its own only computes: it cannot reach a console, a
file or a clock. `print` is the only thing a program can be *observed*
to do, and that distinction is worth keeping — but it is a property of
an operation rather than a reason for a second module, so it is the
`crosses_host` field.

Every backend consults it at the same point in translation, recognising
that a call is one that leaves the program rather than a call to an
ordinary Pyking function:

```ocaml
| ECall (info, EVar (_, name, _), args, _) when Builtin.crosses_host name -> ...
```

What each backend does from there is host-specific and lives in that
backend:

- `target_js_core.ml` does not even decide what the call looks like in
  JavaScript. It emits `JsRuntimeCall (info, name, args)` and leaves the
  spelling — `print(...)` against `runtime.print(...)` — to
  `target_js_packaging.ml`, since that is the one thing the three
  JavaScript targets disagree about.
- `target_c.ml` and `target_java.ml` emit `printf(...)` and
  `System.out.println(...)`, each with its own formatting glue for the
  parts C and Java do not spell the way Pyking does.
- `target_ocaml.ml` emits `print_endline`, needing almost no glue:
  OCaml already spells `true`, `false` and `()` as Pyking does.
- `interpreter.ml` does not translate anything — it *performs* the
  operation, through a host, since it runs a program rather than
  emitting one.

`pure_names` is the other side of the same field: the builtins that do
not cross the boundary, which is exactly the list a backend with no
translation for them has to refuse. `target_js_core.ml` and
`target_ocaml.ml` both read it instead of restating it.

## What is deliberately not here

Two things cannot be said in this module, and the module graph is why.
`builtin.ml` sits before `analyses.ml`, because everything downstream
reads it, so it can depend on nothing that comes later.

**Which argument types a builtin accepts** is `typesystem.ml`'s. `str`
and `len` are two of the four overloaded names in the language — `str`
takes an Int, a String, a Bool, a list or a tuple; `len` takes a list or
a String — and those sets are not checked by comparison but settled by
unification against the checker's own metavariables. Writing them here
would mean a `Syntax.typ` in a table that otherwise needs nothing from
the AST, and a second place for a rule the checker would still have to
apply.

**What a builtin computes** is `interpreter.ml`'s, and could not move
here even if that were wanted: it needs `value`, `host` and the
environment chain, and `interpreter.ml` sits after `typesystem.ml` in
the module graph. What this module holds instead is what the checker and
the interpreter have to agree on *before* either runs — the name, how
many arguments, and whether the call is observable.

So the table is the declaration and not the implementation. That is the
ceiling, and it is a real one: adding a builtin still touches the
checker, the interpreter and each backend. What it no longer touches is
four lists that could drift.

## The formatting rules

Every backend has to agree on these before one program can print the
same characters everywhere, and they are `print`'s and `str`'s meaning
rather than any host's:

- arguments are formatted individually and joined with single spaces,
  then a newline;
- an integer prints in base 10;
- a string prints **bare** on its own, and **quoted** inside a list or a
  tuple — `print("hi")` writes `hi`, and `print(["hi"])` writes
  `['hi']`;
- unit prints as `()`, never a host's own word for "no value" — not
  Python's `None`, not JavaScript's `undefined`;
- a boolean prints as `true`/`false`, Pyking's own spelling rather than
  any host language's.

`interpreter.ml`'s `format_value` and `display_value` are these rules
implemented for real — the second is the quoted form, and the first is
the top-level one that differs only for a string. Being the reference
implementation for the language, a disagreement between them and this
specification is a bug in the interpreter rather than in the spec.
`target_js_packaging.ml`'s `format_js` is the same rules in JavaScript,
shared by every module of a compiled program — and the playground reads
that formatter back out of the compiler through `pykFormatHelper`
rather than keeping a copy, because a hand-copied one drifted the moment
booleans stopped printing capitalised (`tools/playground/README.md`).

## Adding a builtin

Write the entry here first — its arity, whether it crosses the host, and
its semantics in `doc` — before any stage is taught to do anything with
it. Then four edits follow, and none of them is optional:

1. an argument rule in `typesystem.ml`'s `check_builtin_call`, or the
   name is refused at every call;
2. a case in `interpreter.ml`'s `apply_builtin`, or a program calling it
   type-checks and then fails at run time;
3. in each backend, either a translation or a refusal that names the
   target;
4. a test, and its entry in `tests/test_cases.toml`.

A builtin with no entry here is one the backends and the checker would
each have to be told about separately, which is the state this module
replaced.
