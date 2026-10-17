# Inside `target_java.ml`

How the Java backend is built. What it compiles to, and why, is
[target_java.md](target_java.md).

## Types come from the checker

Nothing here infers a type. `type_of` reads an expression's type out of
`tmap`, and falls back to the node's shape only for a node the tail-call
pass built, which the checker never saw. `jt` writes a Pyking type as
Java -- `~boxed` where Java needs a reference type, `~erase` (and
`ctx.erase`, set for the top level) where a type variable has no type
parameter to stand for and is written `Object`.

## The AST is text

An expression is a `jexpr`: its text, the precedence of its outermost
operator (`at` parenthesizes by it) and whether its static type is
boxed, which `unboxed` reads before a `==`. A statement is a `jstmt`,
small enough to print and to ask `completes` of: javac's rule for
whether a statement can finish (JLS 14.22), which `reachable` uses to
drop what follows one that cannot.

## Names

`scope` maps a Pyking name to a `binding`: its value, its type and its
`kind` -- a final local, a reassigned one, a cell (a `var` a closure
captures), a static field, an erased static, a method, or a place a
pattern bound. `fresh` hands out a name no local of the method family
has taken, so a local of an enclosing method keeps its name inside a
method lifted from it.

## Lifting

`declare_defs` binds every def of a block to a method before the block
is translated, so a def is visible throughout it. `lift` translates one
at its position as a static method (`method_of`) and records what it
captures in `captures`: the locals its body mentions, and the lifted
methods it reaches. Its parameters and its calls hold markers,
`\001P:name:k\001` and `\001A:name:k\001`; `expand_captures` replaces
them once the module is done, with what `closure` works out -- the
method's own captures and those of every method it reaches but did not
write.

## Matching

`pattern` answers a pattern's tests and the places it binds, each place
an expression over the subject that may be read twice. java17 binds a
pattern variable in a constructor's `instanceof` (`binding`), except
inside an or-pattern, where it would not be definitely matched.
`match_stmt` builds the chain, or the labelled block a guarded case
leaves; `switch_stmt` and `switch_pattern` build java21's `switch`, a
record pattern for a constructor or a tuple and `var` with its tests in
the `when` for anything else.

## Finishing a block

`tail_block` and `tail` translate a block whose last value is finished
by a `finish`: returned, assigned to a value-form binding's local, or
carried to a loop's next turn (`Turn`). `effect_of` translates an
expression evaluated for its effect alone.

## The runtime

A `jprogram` records the tuple arities, function arities and
polymorphic interfaces it names; `runtime_source` writes
`PykRuntime.java` for a whole program from all of its modules'.
