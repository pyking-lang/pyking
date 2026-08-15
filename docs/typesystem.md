# `typesystem.py`: design

How `src/typesystem.py` is built, as a piece of software: what gets
threaded through it, why the same functions serve both an annotated
`def` and one whose type is worked out later, and how it takes over
`analyses.py`'s job as well as its own. For what a program has to look
like to pass — the rules, not the mechanism — see PYKING.md, "Type
checking". For the deferred-checking scheme specifically (why a
function nobody annotated is checked at the call, the cache, the two
traces, the mistakes that shaped it), see
[type_inference.md](type_inference.md), which this page deliberately
does not repeat. For a one-page summary, see
[source.md](source.md#typesystempy).

## One function per AST datatype

The organizing idea is stated as a block of signatures near the top of
the file, written out the way a statically typed functional language
would state them — `check_stmt : Stmt -> Env -> TMap -> Type? -> Store
-> (Type, Env, Store)` and so on. That block is worth reading before
anything else here, because it is the actual contract: **no function
in this module dispatches on which sort of AST node it was handed**,
only on which *variant of its own datatype* it was handed. `check_expr`
is the only place an `Expr` is matched; `check_stmt` is the only place
a `Stmt` is; there is no function that takes "any node" and figures out
what to do. This mirrors `syntax.py`'s AST-as-ADT design and
`analyses.py`'s per-kind walk directly — the same discipline, applied
to a harder question (what type does this have?) instead of an easier
one (is every name bound?).

Keeping that discipline is what makes the file's size tractable to
read: a bug in how `if` expressions are checked is a bug in
`expr_type`'s `EIf` case, full stop — nothing about statement checking,
function checking, or the deferred half can be involved, because
nothing else calls into an `Expr`-shaped decision.

## Three things are threaded, and they behave differently on purpose

Every checking function passes along up to three values, and the
signature block calls out that they are not interchangeable. (Two
smaller ones ride along with them: the enclosing function's declared
return type, and the enclosing `Loop`. Both are plain context — read,
never accumulated — and both are absent where there is none, which is
how "`return` outside a function" and "`break` outside a loop" are the
same sentence twice.)

- **`Env`** (`{String: Type?}`) — the names in scope and what this
  checker knows about their types. Threaded exactly the way
  `analyses.py`'s environment is: `bind` returns a *new* dict, nothing
  is ever mutated, and "leaving a scope" is simply "stop using the
  extended copy." A value of `None` in this dict — not the same as the
  name being absent — means "in scope, no type known here yet": a `def`
  that didn't annotate everything, deferred rather than refused.
- **`Store`** — everything the deferred half of the checker (see
  `type_inference.md`) has worked out so far: where each unannotated
  `def` was written, what it's been checked at, which ones are
  mid-check right now. Also threaded like `Env` — every function that
  is handed a `Store` hands one back, and nothing in it is ever written
  to in place; see that page for why, and for what the fields actually
  hold.
- **`TMap`** (`{Int: Type}`) — the pass's *result*: a plain mutable
  dict, symbol to type, built up as checking proceeds and handed back
  once at the very end by `type_check`. This is the deliberate
  exception. Threading a third immutable table through every function
  purely so it could be merged back together at the top would be
  machinery for no reason — nothing downstream ever needs to compare
  two different `tmap`s or ask "what did `tmap` look like three calls
  ago." `record(tmap, sym, type_, store)` is the one function that
  writes into it, and it **merges** rather than overwrites (see below),
  which is the one piece of care an ordinary mutable dict wouldn't give
  you for free.

The rule of thumb that falls out: **a function that is handed a `Store`
returns one.** What it worked out is knowledge its caller needs, and
handing it back is the only way that knowledge survives the call
returning. `type_inference.md`'s "Hard decisions" section records a
real bug that came from getting this wrong once (state reachable from
a type instead of threaded as a value) and had to be undone — read it
if the temptation to shortcut this arises again.

## What every statement is asked

`check_stmt`'s signature ends in `(Type, Env, Store)` — a statement
supplies a type, leaves behind an environment for what follows it, and
threads the store. That first element is doing more work than it looks
like. Every kind of statement is asked the **same question** — *what
value do you supply?* — and the answers compose without any special
cases:

- An expression statement supplies its expression's type
  (`SExprStmt`).
- A `return e` supplies `e`'s type (`SReturn`) — which is exactly the
  wording PYKING.md's "Tail position" table uses for it, not a
  coincidence but the whole point: `check_stmt` *is* the mechanism that
  table describes.
- A `break`/`continue` supplies the enclosing loop's accumulator type,
  for the same reason and with the same payoff: `if c: x + 1 else:
  break` needs no special case, since both branches answer the same
  question with the same type. A `loop` itself supplies its accumulator,
  which is what makes `x = loop …` a binding like any other.
- An `if` (as a *statement* used in a value position — the last
  statement of a function body, say) supplies whichever branch's type,
  once both branches are required to agree.
- Most other statements (`SVar`, `SMutate`, `SWhile`, ...) supply
  `unit`, because they're run for effect, not value.

This is what lets `check_function` (below) treat "a body that returns
on every path" and "a body that ends in a value-producing expression"
as the same case rather than two — both are answered by asking the
body's last statement what it supplies, and comparing that against the
declared return type. There is no separate "does this function
definitely return?" analysis the way `target_java.py` needs one for
`javac`'s sake (see that module's own page) — the tail-position rule
*is* the analysis, already built into what `check_stmt` returns for
every kind of statement.

`return_type`, threaded alongside `env`, is what a `return` is checked
against: the enclosing function's declared type while its body is being
checked, `INFERRING` (a distinct sentinel value, not a type) while an
*unannotated* function's return type is being worked out — in which
case a `return` doesn't compare against anything, it **contributes**
its type to `store.frame.returns` instead, via `check_return` — and
`None` at the top level of a program, where `SReturn`'s case checks for
exactly that and refuses `return` outside a function. Three states, one
field, threaded down through every nested block rather than looked at
once when a body finishes — because a `return` can appear anywhere
inside nested `if`s and loops, not only at the end.

## `if`: the one place a trace can be abandoned

`SIf`'s case in `check_stmt` is the most involved single case in the
file, and it's worth reading once alongside `type_inference.md`'s
"Recursion, and why there are two traces" — this is the *other* half
of that mechanism, the half that lives in ordinary statement checking
rather than in the deferred machinery itself. Both branches are checked
with `try_branch` rather than plain `check_stmt`, because either one
might contain a call this checker cannot yet type (a recursive call to
the very function whose body is being worked out) — `try_branch`
catches the `_Recursive` signal that raises in that case and reports
back `(type, store, signal)` instead of letting the signal propagate
further, which is what makes `if n < 1: return 1 else: return n *
fact(n - 1)` checkable at all: the `then` branch types cleanly, the
`else` branch's recursive call can't be typed on this pass, and the
`if` is where that gets noticed and handled rather than immediately
failing.

Read the comments in that case in order — they explain, in sequence:
why a missing `else` defers the "no value on this path" problem to
wherever the value is actually needed rather than raising it here; why
the `else` branch is checked against the store the `then` branch
*produced*, not the one both started from (only one branch runs, but
both were checked, and whatever either found out about a function is
equally true regardless of which branch executes at runtime); and why
two functions that are each still just a promise (`TUnknown`
everywhere) cannot be allowed to flow out of one `if` as if they were
the same thing (`check_not_conflated` — see `type_inference.md`, "Two
`TUnknown`s are the same type").

## Annotations are checked, never replaced

`check_annotation(annotation, actual)` is a small function carrying a
large idea: where a binding wrote an annotation, that annotation is a
**claim about the program**, verified against what the value actually
turned out to be — not silently overwritten by the inferred type, and
not trusted blindly either. `f: (Int, String) -> Int = foo` is an error
if `foo` turns out to be `(Int, Int) -> Int`, reported at the
annotation (not at `foo`), because the value is a perfectly good value
of its own type and the disagreement is something the *program* stated.
That's the difference between an annotation and a comment: a comment
is never checked against anything, so it can go stale forever without
consequence; an annotation here cannot.

A binding with no annotation makes no claim and simply takes whatever
its value has — which is what `--typecheck --ast` is for: printing the
type that was worked out is the only way to see it, since nothing was
written down to check it against.

## Builtins: bound to something that isn't a type

`env` maps a name to a `Type`, to `None` (in scope, unannotated `def`,
not yet known), or to a third thing: a `Builtin`. `print`, `range`,
`str` and `len` are bound to `Builtin(name)` from the very first
environment `type_check` builds (`builtin_env`), rather than to a
`TFunction`, because none of the four genuinely fits one — `print`
takes any number of arguments of any type, which no fixed parameter
list can express, and none of them is a value in the sense
`runtime_interface.py` means: they're host *operations*, callable and
nothing else. `check_builtin_call` gives each its own rule, applied
only at the point of a call; using one any other way (`x = print`,
passing `str` as an argument) is refused, exactly as the C and Java
backends refuse `print` as a value for the analogous reason.

## `env` *is* the scope, while `--typecheck` is on

`analyses.py`'s `analyze_program` runs for every mode except one:
`--typecheck` replaces it outright rather than running after it (see
`pyk.py`'s `front_end`, and `architecture.md`'s "Symbols and types").
That's only sound because this module's `Env` genuinely does the same
job `analyses.py`'s environment does, and more: a name must be bound
where it's used, a block's own bindings don't survive it, an inner
binding shadows an outer one, a `def`'s name is in scope in its own
body, and the builtins are in scope from the start — all of that falls
out of the same immutable-dict-rebuilding discipline `analyses.py`
established, reused here rather than reinvented. An unbound name raises
`analyses.AnalysisError` — imported, not a locally defined lookalike —
specifically so the driver's `Name error` message reads identically
whichever pass caught it; a caller shouldn't be able to tell which one
ran from the wording alone.

The one rule `analyses.py` still owns exclusively is that a `var` may
not be shadowed. This checker refuses `var` outright (it's outside the
fragment it accepts), so there is, for now, nothing here that rule
would need to protect. CLAUDE.md and `architecture.md` both call this
out as the last piece standing between the two passes: once this
checker's fragment grows to include `var`, the corresponding rule has
to move here too, and at that point `analyses.py`'s job is finished.

## Hoisting `def`s, the same way `analyses.py` does

`declare_functions(stmts, env, store)` binds every `def` in a block
before any statement in it is checked — the same two-pass shape
`analyses.py`'s `analyze_stmts` uses, going through the very same
`block_functions` helper (imported, not restated) so the two passes
cannot come to different conclusions about which programs are legal.
What differs is what gets bound: a fully annotated `def` is bound to
its real `TFunction`; one that isn't gets `declared_type`'s
placeholder — a `TFunction` with `TUnknown` standing in for whatever
wasn't written down, carrying `tmsym`/`definition` so it can be found
again later — and `store` additionally remembers *where* that
placeholder's real body will need to be checked, since by the time
something calls it, the call site's own scope is not the right one to
check the body in (see `type_inference.md`, "Where the definition's
environment comes from").

## Comparing types: never `==`

Every `T*` node from `syntax.py` is a frozen dataclass, which means
Python's own `==` compares *every* field — including `info` (the
source span) and `sym` (the symbol) — neither of which is part of what
a type *means*. Two `Int`s written in different places, or one written
in source and one built by this checker, would compare unequal under
`==` despite being the same type. `same_type(a, b)` is the real
comparison throughout this file: structural, recursive into a type's
own fields (`TList`'s element, `TTuple`'s elements, `TFunction`'s
parameters and result), and deliberately blind to the two fields that
say *where a type came from* rather than *what it is*. `accepts`
extends it with the one piece of subtyping the language has — an
alternative type accepted where any one of its members would be,
never the other way around — and is built on top of `same_type` rather
than duplicating its structural walk.
