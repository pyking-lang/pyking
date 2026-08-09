# The loop-capture factory mechanism

This page is the implementation-level companion to
[target_python.md](target_python.md), "A def inside a loop": how
`src/target_python.py` decides which `def`s need a per-turn factory,
which statements travel with them, and what the factory looks like.
Read that section first for the behavior; this page is the algorithm
behind it.

## Grouping: which `def`s build together

A `def` needs a factory when it reads a name the loop rebinds each turn
(`_loop_captures`, `_def_body_names`). A `def` that names another `def`
of the same block must join that one's factory too — otherwise the call
would resolve at the *factory's* definition time, before the loop ever
assigns the loop variable, and would find whatever the last turn left
behind.

`_turn_groups` finds these groups as the connected components of "names
another `def` of this block" among the block's `def`s (a small
union-find over the block's statement indices, `root`/`parent`), keeping
only the components that actually capture something. A `def` reads
whatever is in scope *at its own position* — `_loop_names_before` builds
that positionally, from what the loop already carries plus what the
block has bound above that point, `var`s excluded (a `var` is one
location per PYKING.md, not one per turn).

## Absorbed statements

A capture bound *between* two group members cannot be a parameter of a
factory called at the first of them — the factory has not been called
yet at that point in the source. `_absorbed` finds the statements between
the group's first and last member that the group needs, and pulls the
whole span between them into the factory, provided every statement in
that span can move.

A statement is **movable** (`_movable`) if it contains no `return` —
which would leave the factory rather than the enclosing function — and
no `:=` — which would write the factory's own local instead of the
variable it names. A nested `def`'s own `return`s do not count against
it: they leave *that* function, not this one. If something in the span
cannot move, only the bindings the group actually needs are absorbed
(`needed`), and those are lifted ahead of the statements left behind, so
the group's own order is preserved without moving what cannot move.

## Building the factory

`_translate_turn_group` translates the group's members and absorbed
statements, in source order, inside a synthesized function
(`_fresh_turn_name`, checked against every source identifier like the
comprehension helpers' `__pm*`) that takes the captured names as
parameters and returns whatever names the group bound — one value, or a
tuple. The call site then assigns that tuple back to the same names, in
the enclosing scope, at the point the group started.

Nothing else moves: statements outside the absorbed span keep their
place, their order, and their side effects; a `return`/`:=` among them
still means what it always did.

## What remains

The factory is built whenever a `def` inside a loop captures a
loop-rebound name, whether or not that function ever outlives its own
turn — telling the two apart needs escape analysis, which this backend
does not do. So a function that is only ever called within the turn it
is defined in still gets the indirection.

`tests/lexical_capture*.pyk` and `tests/lexical_capture_group.pyk` pin
the grouping, absorption and factory-building rules above.
