# Default parameters and named arguments

`src/desugar_args.ml` is a pass from the Pyking AST to the Pyking AST.
It runs first, before symbolizing and before anything reasons about the
program, and it removes two pieces of syntax entirely:

```pyking                           # what the pass builds
def greet(who: String = "world"):   def greet__default__who() -> String:
    print("hi " ++ who)                 'world'
                                    def greet(who: String):
greet()                                 print("hi " ++ who)
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
    print("hi " ++ who)
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

## Named arguments are written in parameter order

```pyking
box(width = 4, depth = 6)      # fine
box(depth = 6, width = 4)      # refused
```

The restriction is what removes an entire subsystem. Without it, a call
whose names are out of order has to preserve the source order of its
argument expressions, which means temporaries:

```pyking
supplied_c = first()
supplied_a = second()
foo(supplied_a, default_b, supplied_c)
```

Temporaries are statements, and a call is not always in statement
position. There is no way to hoist one out of a `while` condition, an
`if`-expression branch or a comprehension body without changing when it
runs, so the rule would need a three-tier policy — reorder freely when
every argument is call-free, hoist temporaries when the call is a
statement, refuse otherwise — and the third tier means a program stops
compiling as soon as its call is nested one level deeper.

With the order fixed, nothing is ever reordered. Arguments run left to
right in parameter order, which is what they already did, and a call
means the same thing wherever it is written.

A default fills its own positional slot, so its side effects fall
*between* the supplied arguments around it rather than before or after
all of them. That follows from the same rule and is stated in
PYKING.md.

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
sugar's own printed form is pinned.

## What it does not do

- **No overloading.** The rewrite never changes a function's arity, so
  `analyses.apply_signatures` keeps folding a `def f : (Int) -> Int`
  line onto its definition, and one name still means one function.
- **No cycle check.** `def f(x = f(1))` is ordinary recursion: it type
  checks, and it runs until the call-depth limit, reporting a Pyking
  runtime error whose stack trace names `f__default__x`.
- **Nothing about closures.** A default that reads a binding from
  around it makes the generated def a closure, which the C and Java
  backends refuse as they refuse any other — see `docs/target_c.md` and
  `docs/target_java.md`. A default built from literals and calls
  compiles everywhere.
