# `target_python.ml`: internals

How `src/target_python.ml`'s own machinery works — the `Scope` object
and its renaming decision, the two free-variable analyses that decide
when a rename is needed, and how a refutable comprehension pattern and
a possibly-boolean `print` argument each get their generated helpers.
For what each Pyking construct compiles *to*, and where the output is
not optimal, see [target_python.md](target_python.md) — that page is
about the target's behavior; this one is about how the module that
implements it is built. For a one-page summary, see
[source.md](source.md#target_pythonml).

This page assumes you've read `target_python.md`'s "Blocks are scopes;
Python's are not," "A rebinding some function captured," and "A def
inside a loop" sections — they establish *what* problem each mechanism
below solves. This page is about *how*. The loop-capture factory
mechanism specifically has its own dedicated page, [gap.md](gap.md),
because it's the most involved single piece of this backend; it isn't
repeated here.

## The problem in one sentence, and the two questions it splits into

Pyking scopes at every block; Python scopes at every function. A
binding translated naively — Pyking name straight to the same Python
name — breaks the moment two blocks in the same Python function reuse a
name, because Python has nowhere for the inner one to go but the same
variable the outer one already occupies. The fix is renaming, and the
whole of `Scope`, `bind`, `free_names` and `captured_names` exists to
answer two different questions about *when* a rename is actually
needed — because renaming everything that merely *could* collide would
produce code where every third variable was `x2`, `y3`, and so on, and
that's not the goal; the goal is to rename only where skipping it would
be wrong, not merely unusual.

The two questions:

1. **Looking backward**: does this new binding land on a Python name
   that's still live in this function scope? (`bind`, using
   `scope.local`.)
2. **Looking forward**: does *anything already translated in this
   scope* — specifically, a nested function — depend on a name this
   binding is about to shadow? (`free_names`/`captured_names`,
   computed once per Python function scope before any of its statements
   are translated, and consulted by `bind` via `scope.shadowed`/
   `scope.captured`.)

## `Scope`: what's tracked, and why it's split the way it is

```ocaml
type scope = {
  outer : string SMap.t;         (* enclosing Python function scopes' renames *)
  local : string SMap.t;         (* this Python function scope's renames *)
  block : StringSet.t;           (* names bound by the innermost Pyking block *)
  shadowed : StringSet.t;        (* outer names this scope reads (question 2) *)
  captured : StringSet.t;        (* names nested functions read from around them *)
  loop_names : StringSet.t option; (* names the nearest loop rebinds each turn *)
  depth : int;                   (* Python function scopes deep; 0 is the module *)
  mutables : int SMap.t;         (* each `var` in scope -> the depth it was declared at *)
  used : StringSet.t;            (* every Python name already spoken for *)
}
```

The split between `outer` and `local` is not bookkeeping for its own
sake — it's what makes the *first* question cheap to answer correctly.
A binding only ever needs to dodge names that are **live in the same
Python function scope**: Python's own scoping already keeps `local`
apart from `outer` (a nested `def`'s local variables can't collide with
its enclosing function's, because Python itself won't let them), so
`bind` only has to check `local` — checking `outer` too would rename
things that don't actually collide in the generated code. `block` is
what tells rebinding (reusing a name — `x = 1` then `x = 2` in the same
block, which is two Pyking bindings that safely become one Python
variable, since the first is dead) apart from shadowing (a *nested*
block reusing an outer name, which is not safe to reuse): a name in
`scope.block` is this block's own, already assigned a Python name, so
binding it again just returns that same name — unless a function
already captured it (see "A rebinding some function captured" below,
and the `rebinding`/`captured` interaction in `bind`).

`loop_names` is explained fully in `gap.md`; the short version for
context here is that it's what tells `bind` a binding is happening
*inside* a loop, so that name can be recorded as "rebound each turn" —
information the turn-groups mechanism needs and nothing else does.

`depth` and `mutables` answer a question none of the others can: a `def`
that writes a `var` bound outside it has to say `global` or `nonlocal`,
and which of the two depends on *where the declaration is*, not on
anything about the name itself. `function_scope` increments `depth`;
`bind` records `mutables[name] = scope.depth` for a `var` and drops the
name for anything else, since a name rebound with `=` is no longer a
cell. A `var` at depth 0 is `global`, one deeper is `nonlocal`. See
[target_python.md](target_python.md), "A `var` written from inside a
function".

## `bind`: the actual decision

```ocaml
let bind ?(rebinding = false) ?(loop_carried = true) ?(mutable_ = false)
    name scope =
  if StringSet.mem name scope.block
     && not (rebinding && StringSet.mem name scope.captured)
  then (SMap.find name scope.local, scope)
  else
    let py_name =
      if
        StringSet.mem name reserved
        || SMap.mem name scope.local
        || SMap.exists (fun _ value -> value = name) scope.local
        || StringSet.mem name scope.used
        || StringSet.mem name scope.shadowed
      then fresh_py_name name scope
      else name
    in
    (py_name, { scope with ... })
```

Four conditions can force a rename, and it's worth having a concrete
example of each in mind:

- **`name in RESERVED`** — the Pyking name is a Python keyword
  (`def class(n): ...` needs `class` renamed to something, since
  `class` can't be a Python identifier at all).
- **`name in scope.local`** — this exact name is already bound
  *somewhere* in this Python function, in a way that would collide.
  This is the ordinary "two sibling blocks each shadow an outer `total`"
  case from `target_python.md`.
- **`name in scope.local.values()`** — a name isn't in conflict with
  another *Pyking* name, but it *is* the same text as a Python name some
  earlier rename already produced. Without this check, renaming `total`
  to `total2` once and then later needing to rename a second, unrelated
  `total` could produce `total2` again — a fresh collision manufactured
  by the renaming scheme itself. Checking against the *values* as well
  as the *keys* of `scope.local` is what rules that out.
- **`name in scope.shadowed`** — the name isn't shadowing anything
  visible right here, but some function *already translated in this
  scope* reads it from further out (question 2, from `free_names`
  below) — binding it here would make it local to the whole Python
  function and break that read, even though the read happens to be
  written *before* this binding in the source.

When none of those apply, the Pyking name is kept as-is — which is the
point of doing all this analysis up front rather than renaming
defensively: a program with no shadowing at all reads exactly like its
own source.

The `rebinding`/`captured` interaction is the other half of "A
rebinding some function captured": normally, rebinding a name already
in `scope.block` (`x = 1` then `x = 2`) is free — the first is dead in
Pyking too, so one Python variable serves both — *unless* a function
defined between the two bindings captured the first one. In Pyking,
that rebinding is a genuinely new binding, and the closure keeps the
old value; collapsing the two into one Python variable would let the
closure observe the second value instead. `scope.captured` is exactly
the set of names this scope's own nested functions read from around
them, so `rebinding and name in scope.captured` is precisely "this
would-be-free rebinding actually needs its own variable."

## `free_names`: what a function reads before it's bound anything itself

`_free_names(stmts, bound)` walks a statement list and collects every
name used **before** something in `stmts` (or already in `bound`, the
names already in scope when the walk starts — a `def`'s own parameters,
for instance) has bound it. The recursive structure
(`free_in_stmt`/`free_in_expr`) is a straightforward walk with one
thing worth calling out: it extends `bound` **in place** as it goes
(`bound.update(...)`, `bound.add(...)`), which is what makes order
matter correctly — a name read on line 3 that was bound on line 1 is
not free, but the identical name read on line 1 before any binding
would be. `SFunctionDef`'s own case adds the nested `def`'s name to
`bound` before recursing into anything (matching Pyking's own hoisting
rule — a block's `def`s are visible throughout it), and a nested `def`
that reads a name from *outside itself* still gets walked here rather
than skipped, because "a body reads this name from outside itself" is
exactly the question `captured_names` (next) needs answered for that
inner function too.

`function_scope`, called whenever translation enters a `def` body or a
comprehension (both genuine Python scopes on their own), is what
actually populates `scope.shadowed` for the body about to be
translated: it's called with `_free_names(body, params ∪ {def's own
name})` as its `shadowed` argument. Only *after* that computation is
available does `bind` have anything to consult — which is why
`free_names` always runs once, up front, for a whole function body
before any of that body's individual statements are translated one by
one.

## `captured_names`: the same question, one level removed

`_captured_names(stmts, bound)` asks something related but distinct:
not "what does *this* scope read from outside," but "what do the
**functions defined somewhere in this scope** read from around
*themselves*." `captured_in_block` walks the block, and for every
`SFunctionDef` it finds, calls `free_names` on *that function's own
body* — reusing the exact same free-variable machinery, just rooted one
level deeper. The result feeds `scope.captured`, which is what `bind`
checks for the rebinding-that-a-closure-captured case described above.

Both analyses run once per Python function scope, before any statement
in it is translated — not incrementally, statement by statement — which
is necessary because whether an *early* binding needs renaming can
depend on what a function *later* in the same scope reads. There's no
way to know that without having looked ahead first.

## Generated helpers: built lazily, emitted separately

Two constructs in this backend need code that doesn't correspond to
anything the Pyking source wrote — host boilerplate, not a translation:

**A refutable comprehension pattern.** `build_match_helper` is called
the first time a comprehension's `for` clause needs one (see
`target_python.md`, "List comprehensions with refutable patterns," for
what makes a pattern refutable and what the desugared shape looks
like), synthesizing a small `PyFunctionDef` — pattern-only, capturing
nothing from the surrounding scope — and adding it to `gen.pending`,
the list `translate_program` drains and prepends to the final output
exactly once, regardless of how deeply the comprehension that needed it
was nested. `fresh_comp_names` allocates both the loop-item name and the
helper's own name checked against `gen.used` — every identifier anywhere
in the source, collected once by `collect_identifiers` — so a generated
name can never collide with, or shadow, anything the program actually
wrote.

**A possibly-boolean `print` argument.** Pyking spells its booleans
`true`/`false`; Python's `print` would spell the same value
`True`/`False`. Most arguments don't need a runtime check at all —
`bool_kind` reads the argument's type out of `tmap`, the checker's
symbol → type table that `translate_program` is handed, and
`wrap_print_argument` emits either an inline `'true' if <expr> else
'false'` (for a `Bool`) or the expression completely unwrapped (for a
type with no `Bool` anywhere inside it, which is most of them). Only a
value that genuinely can hold one — a `[Bool]`, a `(Int, Bool)`, a type
nothing pinned down — makes `format_helper_name` build (once, lazily,
the first time it's actually needed) a small `__pyk_str` helper and
route the argument through a call to it. Reading the types rather than
guessing at AST shapes is what keeps an ordinary program's output free
of a prelude it has no use for. Like the comprehension helper, this one is kept
separate from the translated program itself and printed in its own
marked-off prelude block (`pprint_py_program`), because it's boilerplate
for the host Python interpreter, not a rendering of anything the Pyking
source wrote — the same distinction `target_js_packaging.ml` draws for
its own generated preludes.
