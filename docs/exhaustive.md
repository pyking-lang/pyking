# Exhaustiveness

Every `match` matches every value of its subject's type, and every case
in it is reachable. `src/exhaustive.ml` checks both, once per module,
after the type checker has worked out every type. PYKING.md,
"Exhaustiveness", has the rule as the language states it. This page is
how it is decided.

## One question, asked twice

Both checks ask whether a pattern is **useful** after some rows: is
there a value that the pattern matches and that no row matches?

- **A case is reachable** when its pattern is useful after the
  unguarded cases above it. A guarded case above it may fail its guard,
  so it takes nothing away.
- **A `match` is exhaustive** when `_` is not useful after all its
  unguarded cases.

When `_` is useful, the answer is a value no case matches, written as
the pattern that would match it. That is what the refusal names: `no
case matches Triangle(_, _, _)`.

## The algorithm

Usefulness is Maranget's ("Warnings for pattern matching", JFP 2007).
The rows are a matrix, one column per position still to match. The
first column is decided by the shapes its patterns name:

- **Every shape of the column's type is named.** Each one is tried in
  turn: the rows are specialized to it, and each part of the shape
  becomes a column of its own.
  - The shapes of a type are a datatype's constructors, `true` and
    `false`, or the one shape of a tuple.
- **A shape is missing.** Only the rows whose first pattern matches
  anything can take a value of the missing shape. They are kept, and
  the witness has the missing shape in front, written with `_` for each
  of its parts.
  - A column nothing was written in is matched by nothing, so its
    witness is `_`.
- **The type cannot be enumerated.** An `Int` or a `String` is never
  covered by its literals. Its witness is a literal none of them is:
  the first unused number from 0, or the first string none matches.

A `|` is tried one alternative at a time, and an `as` reads as its
pattern.

## Lists

A list's shape is its length. A pattern without a rest marker has one
length. One with a marker takes every length from its fixed part up.

1. Each column first finds `L`, the longest length any pattern in it
   fixes.
2. A list then has `L + 2` shapes: exactly 0, 1, … `L` elements, and
   "more than `L`".
3. A rest pattern is each of the shapes it takes.
4. "More than `L`" is specialized at `L + 1` elements, which no pattern
   without a rest marker has.

`[]` and `[x, ..rest]` cover a list between them for this reason, and
so do `[]`, `[x]` and `[x, y, ..r]`.

## Strings split with `+`

A `"prefix" + rest + "suffix"` pattern is treated as a literal of its
own. It matches some strings, and the check does not try to say which.
The result is conservative in both directions:

- A set of them never covers a `String`.
- A literal after one that would take it is not reported as
  unreachable.

The check only ever refuses a `match` that really misses a value.

## Types

The column types come from the checker's `tmap`:

- The subject's type, at the `match`.
- Each constructor's field types, with the datatype's parameters
  substituted.

A column whose type is unknown takes its shapes from the patterns
written in it. A body the checker never reached has no types: an
unannotated function nothing calls. Its `match`es are left alone. That
code never runs, and nothing could be said about it anyway.

## What the backends do with it

Every target can rely on a `match` running one of its arms.

- **Python** and **JavaScript** emit no fallthrough.
- **C** and **Java** compile an unguarded last arm as the chain's
  `else`. A `Bool` `match` with no `_` then returns on every path,
  which `javac` and C's "every path returns" check need.
- **OCaml** is the one target whose host checks exhaustiveness itself.
  It cannot see through a `when`, and a `when` is how it compiles a
  guard, a `+` split and a list pattern with elements after `..`. So
  it asks `Exhaustive.covers` of the arms it *can* see, and adds `| _
  -> assert false` only when those do not cover.
  - Adding one where OCaml can see the arms cover would be warning 11,
    an unused case.
  - The generated file also turns off warning 4, fragile match, since
    `_` over a datatype is how Pyking says "every other constructor".

## What changed for existing programs

Before this pass, only a `match` whose value was taken had to cover. A
statement `match` that no case took did nothing. The old rule was
checked by eye: one refutable column of a tuple at a time, and every
list length. The new one is exact, and it applies to every `match`.

So two things changed:

- A program with a statement `match` over Ints and no `_` is refused.
  The fix is `case _: ()`.
- A `match` that the old rule refused as not covering, `(true, true)`,
  `(true, false)`, `(false, _)`, is now accepted.
