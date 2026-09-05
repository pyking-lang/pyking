# `target_java.ml`: internals

How `src/target_java.ml` is built — largely a repeat of
[target_c_internals.md](target_c_internals.md), so this page focuses on
where the two genuinely differ rather than re-deriving what they share.
For what each construct compiles to and what's refused, see
[target_java.md](target_java.md); for a one-page summary, see
[source.md](source.md#target_javaml).

## What's the same as `target_c.ml`, and why that's not an accident

This backend's module docstring says it outright: "structured like
target_c.ml." The type representation (`INT`/`BOOL`/`STRING`/`UNIT` as
plain strings, a `jtype` on every `JExpr`), the three inference rules
(a binding takes its initializer's type; a parameter takes its
annotation or a guess from `used_as_string`; a function's return type
is read off its translated body), the two-pass `declare_functions` /
`function` shape with a provisional `Int` return type and
`called_early` tracking for calls that ran ahead of the real answer,
`contains_call`, `Scope`/`bind`'s renaming — all of it is close enough
to `target_c.ml`'s own version that reading
[target_c_internals.md](target_c_internals.md) first is the efficient
way to understand this module. That's deliberate, not incidental: both
languages force the same kind of static type onto an untyped Pyking
program, for the same underlying reason (C and Java both compile ahead
of time, unlike Python and JavaScript, whose translations need no
static types at all), so the same inference machinery, built once and
reused in shape if not in code, answers the same questions for both.

What follows is everything that's genuinely different.

## `_FEATURES`: one printer, gated by version instead of standard

Where `target_c.ml` has two *standards* that disagree about several
things (comments, declaration placement, `bool`'s existence), the three
Java versions disagree about exactly **one** thing this backend's
subset ever exercises: whether a local declaration can write `var`
(JEP 286, Java 10's local-variable type inference — absent from java8,
available from java17 on) or has to spell its type out. `_FEATURES` is
a small per-version table with two entries, `release` (for the
`--release` flag suggested in a compile-with comment) and
`var_locals` (a bare boolean), consulted in exactly one place,
`local_type`. There's no equivalent of `target_c.ml`'s `emit_block`
split — nothing about *where* a declaration may appear differs across
Java versions the way it does between C89 and C23 — so this module's
per-version surface is much smaller than the C backend's per-standard
one, in direct proportion to how much less the three Java versions
actually disagree about, within the subset this backend reaches.

## Two things `javac` checks that `cc` doesn't

This is the biggest real difference in behavior, and it's a difference
in what the *target compiler* enforces, not a difference this backend
invented. C's `falls_through` check (see
[target_c_internals.md](target_c_internals.md)) exists because falling
off the end of a non-`void` C function is **undefined behavior** — `cc`
will happily accept it and produce a program that returns garbage.
`javac` takes the opposite position: a method that provably might not
return a value on every path, or that has unreachable code after a
statement that always returns, is a **compile error**, full stop. So
this backend has to prove both properties itself, conservatively, and
refuse at Pyking compile time whenever it can't:

- **`definitely_returns`/`stmt_definitely_returns`** walk a
  translated body's *last* statement, recognizing exactly two shapes as
  guaranteed: an unconditional `return`, or an `if`/`else` where
  **both** arms definitely return. That's deliberately a subset of what
  `javac`'s own flow analysis can prove — a `while` loop that can never
  fall through, for instance, isn't recognized here — but Pyking has no
  boolean literal that would let a program spell `while true:` in the
  first place, so the gap between what this function proves and what
  `javac` could prove never actually costs a real program anything.
  What matters is the other direction: anything this function calls
  "definitely returns" really does, so a program it accepts is one
  `javac` will accept too.
- **`check_reachable`** walks a statement list looking for the first
  statement that comes *after* one `stmt_definitely_returns` already
  called guaranteed — code `javac` would refuse as unreachable, where
  Python would simply never execute it and say nothing. This runs
  after *every* block is translated (`stmts`' own case calls it
  unconditionally, not just at the end of a function body), because
  unreachable code can follow a guaranteed-return statement anywhere a
  block appears, not only at a function's top level.

Both checks report the mismatch as a Pyking compile-time error with a
source position, rather than emitting Java that `javac` would then
reject with a less legible message pointing at generated code the
programmer never wrote.

## `JEquals`: Java gives this backend something C doesn't have

C has no `+` for strings and no `==` that compares string *contents*
(only pointers), which is why `target_c.ml` needs a generated
`pyk_concat` helper and an `strcmp` call for every string operation
(see that page). Java needs neither: string concatenation is Java's own
`+`, so an `EConcat` translates straight to a `JBinary("+", ...)`, no
helper involved. String *equality* still
needs care — Java's `==` on `String` compares object references, not
contents, which would silently produce wrong answers for two distinct
`String` objects holding equal text — so `EEq` between two strings
becomes its own AST node, `JEquals`, printed as `left.equals(right)`
rather than folded into the general `JBinary` case. This is one
targeted accommodation, not a general string-handling subsystem the way
C's is.

## Naming the file to match the class

Java requires the file holding a `public` class to share that class's
name *exactly* — a constraint neither C nor Python nor JavaScript has.
`default_class_name(stem)` is what makes `pyk compile -t java21
foo_bar.pyk` write `FooBar.java` (words split on anything that isn't a
letter or digit, each capitalized and run together) rather than
`foo_bar.java`, which `javac` would refuse outright for a file
containing `public final class FooBar`. This only applies to the
*default* name; an explicit `--output` is trusted as-is, and the class
inside it is named after whatever file the caller chose instead — see
[target_java.md](target_java.md), "Naming the class," for the exact
rule and the corner cases (a stem with no word at all, one that would
start with a digit).

## Forward references: free, unlike C

One place this backend is *simpler* than `target_c.ml`: Java methods
are all members of one class, and `javac` doesn't care what order
they're declared in — no prototype-emission step is needed the way C's
`pprint_java_program`'s counterpart needs one. `declare_functions` still
runs its two-pass hoist here, but purely for **naming**: a `def` that
gets renamed for shadowing needs every call site — including ones
written above it — to use the renamed name, which can only be decided
once the whole block's names are known. That's the same reason
`target_js_core.ml`'s `declare_functions` exists despite JavaScript's
own `function` declarations already hoisting at runtime (see that
page) — a recurring shape across backends: hoisting for *execution* is
sometimes free from the host language, but hoisting for *consistent
naming* under a renaming scheme never is.
