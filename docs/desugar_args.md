# Default parameters and named arguments

`src/desugar_args.ml` is a pass from the Pyking AST to the Pyking AST.
It runs first, before symbolizing and before anything reasons about the
program, and it removes two pieces of syntax entirely:

```pyking                           # what the pass builds
def greet(who: String = "world"):   def greet__default__who() -> String:
    print("hi " + who)                  'world'
                                    def greet(who: String):
greet()                                 print("hi " + who)
greet(who = "you")
                                    greet(greet__default__who())
                                    greet('you')
```

Nothing after the pass knows the sugar exists. The type checker, the
mutability analysis, the tail-call pass, the interpreter and all six
backends see ordinary definitions and ordinary calls, which is why
**every target supports the feature** without a line of its own.

What the sugar *means* is in PYKING.md ("Default parameters", "Named
arguments"). This page is the design.

## A default is a generated `def`, not a hoisted binding

The obvious lowering is to evaluate each default once, where the
definition stands, and bind it to a name:

```pyking
greet__default__who = 'world'       # the lowering NOT used here
def greet(who: String): ...
```

That is Python's rule, and it fails four ways in a language with
`def` hoisting and modules.

**It breaks a call from a sibling definition.** A `def` name is visible
throughout its block, so this is ordinary Pyking:

```pyking
def main():
    greet()

def greet(who: String = "world"):
    print("hi " + who)
```

A binding placed before `def greet` stands *after* `def main`, and
`main`'s body is checked in the environment at its own position — so
the binding is not in scope and the program is a name error. Moving the
binding to the top of the block fixes that one and breaks the other
direction, where a default reads something bound earlier in the same
block:

```pyking
xs = [1, 4]
def slice_(size: Int = len(xs)): ...
```

There is no placement that satisfies both, and a rule that tries
("hoist as far as the free names allow") is one nobody can predict from
reading the code.

**It has nowhere to put a module's defaults.** A call to `mod.greet()`
from another module would have to name `mod`'s binding, so the binding
becomes part of `mod`'s public surface — and its name must then be
stable, which rules out the usual "append a number if taken" answer to
a collision.

**It pollutes the namespace** with names the `check_no_function_clash`
and no-shadowing-a-`var` rules then apply to.

**It is the mutable-default footgun**, imported into a language with no
mutable data and therefore none of the benefit.

A generated `def` dissolves all four. It is hoisted like any `def`, so a
sibling reaches it; it is `public` when the function it belongs to is,
so the existing export machinery carries it across a module boundary;
its name is stable; and it lives in the block the definition was
written in, which is what makes the scope rule below true by
construction.

The cost is that a default is evaluated **per call** rather than once.
In a language with no mutable state that is observable only through
cost — rebuilding `[1, 4, 80]` at each call — and through a default
that has side effects, where per-call is arguably the less surprising
answer.

## Definition scope, for free

```pyking
size = 10
def scaled(x: Int = size) -> Int: x * 2
size = 20
print(scaled())            # 20, from the first `size`
```

The generated `def scaled__default__x()` is emitted immediately before
`def scaled`, between the two bindings, and a body captures what is
bound where it is written. Nothing in the pass enforces the rule; the
placement is the rule. `tests/typecheck_defaults_scope.pyk` pins it,
including the nested case where the default reads an enclosing
function's parameter.

## Named arguments in any order

```pyking
box(width = 4, depth = 6)      # in parameter order
box(depth = 6, width = 4)      # in any other
```

Both become a positional call, `box(4, box__default__height(), 6)`. What
differs is evaluation order: Pyking evaluates the arguments as written
-- the depth's before the width's -- and then the defaults of the
parameters left out, in parameter order. A call whose names are already
in parameter order keeps the old rule, a default evaluated in its own
position, so no existing program changes meaning.

Putting the arguments in position therefore needs nothing when the
names are in order. When they are not, the pass looks at each slot's
expression (`pure`): a literal, a name, a lambda, or a tuple, list,
constructor or field of those cannot be seen to run, so it may move.
If at most one slot is impure, moving the others changes nothing either,
and the call is simply reordered. Otherwise each impure slot is bound,
in evaluation order, by a `let` expression around the call -- the same
`ELet` node a program writes (PYKING.md, "Let expressions"):

```
let depth__arg = note("depth", 6) in
let width__arg = note("width", 4) in
let height__arg = box__default__height() in
box(width__arg, height__arg, depth__arg)
```

Each name is the parameter's own with `__arg` after it (`field<k>__arg`
for a constructor's unnamed field), so the names of one call never
clash, and one call's inside another's argument is a `let` of its own,
inside that argument. `-t pyking` prints exactly this, so the printed
program means what the written one does. How each stage handles a
`let` is in the target pages, "Let expressions".

A tail call whose arguments were reordered is inside an `ELet`, which
`opt_tailcall.ml` does not look into, so it stays a call.

## An implicit parameter may be left out

A definition's implicit parameters are part of its signature here too,
marked as such, because a named argument may fill one
(`show(3, fmt = loud)`). What makes them different is that a call may
leave them out entirely: the type checker resolves them later
(docs/implicits.md).

So `ordered` decides first whether the call supplies any of them --
more positional arguments than there are explicit parameters, or a name
that is one of theirs -- and if it does not, it treats the definition
as having its explicit parameters only. Nothing is inserted and no
argument is reported missing; the call is an ordinary call of the
explicit arity, and the checker fills the rest.

## An overloaded callee: the count, not the choice

A `::` name may stand for several definitions, and which one a call
means is the type checker's question (docs/overloading.md). This pass
cannot answer it -- it has no types -- but it cannot ignore the call
either, because a default it erases here is what lets one of those
definitions take fewer arguments, and after the erasure the checker
sees only the arity the parameters were written with.

So `overloaded` settles the *count*: it takes every `q::name`
definition in scope, asks which of them a call of this many arguments
could reach (`takes`, which counts a default as optional and an
implicit parameter as omittable), and then

- fills the defaults of the single definition that takes it that way,
- refuses the call where two take it and one of them needs a default,
- leaves it alone otherwise, for the checker to resolve by types.

A named argument on such a call is refused outright: putting one in its
parameter's place needs to know whose parameter list to use.

## Only where the callee resolves to a definition

The sugar is available when the callee is a name that resolves, in
scope, to a `def`, or a qualified name reaching a public `def` of an
imported Pyking module. It is refused for a binding that happens to
hold a function, for a builtin, and for an external module's function.

This is not a restriction the pass could avoid: a function's *type* says
nothing about defaults or parameter names, deliberately, so

```pyking
g = greet
g(who = 'you')
```

has no information to work from — `g` is a `(String) -> String` like any
other. Falling through silently would leave the named argument ignored
and the arity wrong, so the pass says what is happening instead.

That means the pass does its own name resolution: it carries a scope
mapping each name to `Definition`, `Binding` or `Imported`, rebuilt per
block rather than mutated, hoisting each block's `def` names first the
way `analyses.ml` and `typesystem.ml` do. Shadowing has to be right or
the pass would apply the wrong function's defaults silently:

```pyking
def greet(who: String = 'world'): ...
if ready:
    greet = 1
    greet()          # a Binding here, not the def
```

A name nothing has bound at all is left alone rather than refused, so
the type checker reports the unbound name in its own words.

## Across a module boundary

`Module.load` desugars each module in dependency order, threading a
`signatures` table, so by the time a module is rewritten every module it
imports has been — and their parameter lists are known. The table is
opaque and lives in this module; `module.ml` never looks inside it.

Two import forms, two ways to reach a generated def:

- `import mod` — the call becomes `mod.greet__default__who()`. The
  generated def is one of `mod`'s public names, so `resolve_imports`
  puts it in the field list like any other.
- `from mod import greet` — the local name has no module to qualify, so
  the pass **adds the generated names to that import's own field list**.
  `from mod import greet` becomes, in the tree, `from mod import greet,
  greet__default__who`, and the call is a plain `greet__default__who()`.

Because the generated defs only exist after this pass, a module's
`publics` is computed again in `Module.load` after it runs.

An **exported** function's defaulted parameter must carry a type
annotation. Without one the generated def is unannotated, and
`typesystem.check_exports` refuses exporting a `def` whose type the
source does not write down. Requiring the annotation is a language rule
(PYKING.md) rather than a workaround: it also makes a mismatched default
report against the default expression's own span.

An **external** module is recorded in the table as foreign rather than
merely absent, so a call into one refuses the sugar by name.

## Constructors are definitions here

A datatype's constructor is a definition to this pass, its fields its
parameters: a construction takes positional, named and defaulted
arguments exactly as a call does, and a field's default is a generated
def named `field__default__<Constructor>__<field>` -- starting with a
lowercase letter, as a def's name must -- written just before the
datatype. An unnamed field is known by a name no program can write
(`#1`, `#2`, ...), so no argument can name it. After the pass, every
argument of a construction is in its field's position and carries the
field's own name where it has one, which is how the interpreter and the
JavaScript backend keep a value's fields by name.

A field written with no type and a default that is not a literal keeps
no type in the AST (`Field`'s type is `None`): its generated def has no
return type, and the type checker takes the field's type from it where
the def is written (docs/type_inference.md, "A field's type from its
default").

A constructor *pattern* is filled in by the same names: the positional
patterns first, each `field = pattern` put where its field is, in any
order, and `_` for every field the pattern does not mention. Nothing
after the pass sees a named field pattern.

One rewrite belongs here because this pass knows what each name means.
`x.f` is parsed as `module.name`, since the parser cannot know which
names are modules; where `x` is a binding here it becomes a field read.
An uppercase name is always a constructor: no binding may start with an
uppercase letter, which the parser refuses.

## A literal default is written at the call

A default that is a literal -- an integer, a float, a string or a
boolean, with no type written or the literal's own -- generates no def:
each call that leaves it out is given the literal itself, so
`def step(n: Int = 1)` called as `step()` is `step(1)`. A literal
evaluates to the same value wherever it is written and can be seen to
do nothing, so moving it from the definition to the call changes
nothing a program can observe; what it saves is a def and a call per
omitted argument in every backend's output. `parameter.default` says
which of the two a default is (`Literal` or `Generated`), and an import
brings in only the generated ones.

## `..base` in a construction

`C(x = e, ..base)` fills every field of `C` not written before the `..`
from `base`, by name: it becomes `C(x = e, y = base.y, ...)`, and then
goes through the ordering above like any construction (`updated`). Only
a constructor that is its datatype's only one may be written so
(`meta.sole`), so the fields `base` holds are the constructor's. What
is written before the `..` is evaluated first, then `base`, once: a
base that is not a name is bound by `let update__base = base in ...`,
and where it is, each argument before it that is not `pure` is bound
first by a `let` of its own, `<field>__arg`, in the order written. A
field with no name cannot be read by name, so `..` refuses to fill one.
The parser keeps `..base` as an argument labelled `..`
(`Syntax.spread_label`); nothing after this pass sees one.

## Names

A generated def is `<function>__default__<parameter>`. It is a legal
Pyking identifier, which keeps `-t pyking` output re-parsable — feeding
that output back in generates nothing new, since it holds no defaults.

The spelling is **not reserved**. Reserving it in the lexer would make
`-t pyking` output unlexable, which is the property the name was chosen
to preserve. Instead the pass checks, at the point it generates a name,
that the block does not already bind it, and refuses if it does. That
gives the same stability a reservation would — the name is never
renumbered, so an exported one does not change when an unrelated
binding is added — without the cost.

`Desugar_args.generated_name` is what the REPL uses to keep these out of
`:ls`.

## Where it runs

Three front ends, because `Module.load` is not the only one:

| front end | where |
|---|---|
| `pyk` and the playground's multi-module path | `Module.load`'s fold, before `Analyses.symbolize` and `resolve_imports` |
| the playground's single-file path | `pyking_web.ml`'s `front_end`, before `Analyses.symbolize` |
| the REPL | `repl.ml`'s `submit`, before the entry is concatenated onto `seen` |

The pass emits nodes with symbol `0` and the existing `symbolize` call
numbers them, so nothing has to re-symbolize.

The REPL is the one that needs care. An entry is recovered from `seen`
by *position*, so the pass rewrites the entry — which it may lengthen —
and `seen` is rebuilt from the result, exactly as the tail-call pass
does. The session carries the `signatures` table as a seventh field, so
a function defined in one entry is callable with its defaults in a
later one, and redefining it in a later entry is ordinary shadowing.
The table also records the names an entry bound to something that is
*not* a definition, which is what makes `g = greet` in one entry turn
the sugar off for `g` in the next.

`--no-typechecking` stops the front end after `symbolize` and reads the
named file alone, so it does not desugar: `-t pyking --no-typechecking`
prints the program with its defaults and named arguments as written.
That is the `pyking_nosugar` test target, and it is the only place the
sugar's own printed form is pinned. The `pyking_rerun` target runs what
`-t pyking` printed with the interpreter and compares it against the
`.out`, so a printed `let` that lost the evaluation order fails it.

## What it does not do

- **No overloading.** The rewrite never changes a function's arity, so
  `analyses.apply_signatures` keeps folding a `def f : (Int) -> Int`
  line onto its definition, and one name still means one function.
- **No cycle check.** `def f(x = f(1))` is ordinary recursion: it type
  checks, and it runs until the call-depth limit, reporting a Pyking
  runtime error whose stack trace names `f__default__x`.
- **Nothing about closures.** A default that reads a binding from
  around it makes the generated def a closure, which every backend
  compiles as it compiles any other -- C as a function taking what it
  captures (`docs/target_c.md`).
