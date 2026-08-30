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
return type, and what the enclosing loop carries (`acc_type`). Both are
plain context — read, never accumulated — and both are absent where
there is none, which is how "`return` outside a function" and "`break`
outside a loop" are the same sentence twice.)

- **`Env`** (`{String: Type}`) — the names in scope and their types.
  Threaded exactly the way `analyses.py`'s environment is: `bind`
  returns a *new* dict, nothing is ever mutated, and "leaving a scope"
  is simply "stop using the extended copy." There is no third state: a
  name is in the dict with a type, or it is not in scope. That is worth
  stating because it was not always so — `None` used to mean "in scope,
  no type known here yet", for a `def` that didn't annotate everything,
  and inference removed the need for it by giving such a `def` an
  incomplete `TFunction` instead.
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
  question with the same type. That answer is a *fiction* in the
  `break`'s case — the statement never falls through, so nothing can
  observe it — and it is a useful one, since the alternative is a bottom
  type in every branch comparison.
- A `loop` supplies what it **breaks with**, not what it carries. The
  two are different questions (PYKING.md, "loop loops"), and the
  difference is what lets a loop carrying `(Int, Int)` be worth an
  `Int` — the shape every accumulator-passing function has after
  `src/optimization.py` has been through it. The ways out are collected
  in the store's frame as `Exit(info, type)`, exactly as an inference's
  `return`s are, in a frame of the loop's own so a nested loop's ways
  out are not mistaken for this one's. `loop_value` then requires them
  to agree: one value leaves a loop however many `break`s it has, so
  there is one type for it, and the `info` each `Exit` carries is what
  lets the refusal point at the `break` that disagreed rather than at
  the loop. The rule is about the `break`s agreeing with *each other* —
  a bare `break` joins in by giving the accumulator — so a loop carrying
  nothing is held to it just the same. `merge` is deliberately not used
  here: a loop worth `Int | String` would be a value no `if` branch
  could sit beside, and the C and Java backends already refused one
  (docs/target_c.md, docs/target_java.md), so the front end now agrees
  with them instead of building a type two backends throw out.
- A loop with **no `break` at all** never finishes, so it supplies
  `TNever` — the one type `accepts` takes anywhere, since there is no
  value to be wrong about. That is what lets a function whose body is
  such a loop honour whatever return type it declares. `TNever` is never
  inferred for an expression, and never written in source.
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
its value has — which is what `-t pyking` is for: printing the
type that was worked out is the only way to see it, since nothing was
written down to check it against.

## Builtins: a type of their own

`print`, `range`, `str` and `len` are bound to `TBuiltin(name)` from the
very first environment `type_check` builds (`builtin_env`), rather than
to a `TFunction`, because none of the four genuinely fits one — `print`
takes any number of arguments of any type, which no fixed parameter
list can express, and none of them is a value in the sense
`runtime_interface.py` means: they're host *operations*, callable and
nothing else. `check_builtin_call` gives each its own rule, applied
only at the point of a call; using one any other way (`x = print`,
passing `str` as an argument) is refused, exactly as the C and Java
backends refuse `print` as a value for the analogous reason.

`TBuiltin` is a variant of `syntax.py`'s `Type` rather than a class of
this module's own, so `Env` stays a map from a name to a type and every
lookup dispatches on a type variant. It is like `TUnknown` and `TNever`
in being unwritable in source; it goes further in never being recorded
in `tmap` either, so it cannot reach printed output. Two `TBuiltin`s
are the same type when they name the same operation.

## `env` *is* the scope

There is no separate name analysis: this module replaced it (see
`pyk.py`'s `front_end`, and `architecture.md`'s "Symbols and types").
That's only sound because this module's `Env` genuinely does the same
job the old `analyze_program`'s environment did, and more: a name must be bound
where it's used, a block's own bindings don't survive it, an inner
binding shadows an outer one, a `def`'s name is in scope in its own
body, and the builtins are in scope from the start — all of that falls
out of the same immutable-dict-rebuilding discipline `analyses.py`
established, reused here rather than reinvented. An unbound name raises
`analyses.AnalysisError` — imported, not a locally defined lookalike —
specifically so the driver's `Name error` message reads identically
whichever pass caught it; a caller shouldn't be able to tell which one
ran from the wording alone.

What `analyses.py` still owns is *mutability*, and it is a separate
question rather than a leftover. This module does check `var` and `:=`
— a `var` is `Int` or `Bool`, and a `:=` must give the type the
declaration fixed — but which names may be *written to* is not
something a type can say: the same `Int` is a `var` in one scope and an
`=` binding in another, so the answer is about the binding form, not
the value. That is why `analyze_mutability` is a walk of its own,
running after this pass; it needs no types, and this pass needs no
knowledge of which `Int`s are cells.

That order also settles the wording. By the time the mutability walk
runs, every name is known to be bound, so a name it cannot find in its
own environment is never "unbound" — it is "not a mutable variable",
which is the message worth printing.

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

## `+` and `++`: naming the operator that would have worked

Splitting concatenation out of `+` moved a whole class of mistake from
"wrong types" to "wrong operator", and a message that only said what
`+` accepts would leave the reader to work the rest out. So a failing
operator names its look-alike when — and only when — that look-alike
would have taken these operands:

```
'prog.pyk' 3:6-3:18 Type error: `+` cannot be applied to String and
  String; it accepts Int + Int. Did you mean `++`, the concatenation
  operator?
```

`ALTERNATIVES` pairs the two in both directions, so `1 ++ 2` is told
about `+` by the same rule. The condition is checked against the
partner's row in `OPERATORS` rather than hard-coded, which keeps the
suggestion honest: it is offered only where the swap really is the fix.
`1 + 'a'` gets no suggestion, because no operator here takes an Int and
a String, and `'x' - 'y'` gets none either, because `-` has no
look-alike. A suggestion that might not work is worse than none, for
the same reason `docs/type_inference.md` gives about reported types.

## Type variables, without a solver

A written annotation may name a type it does not fix. The rules are in
PYKING.md ("Type variables"); what matters here is how little machinery
they took, and why.

**Quantification happens once, where a written type enters the checker.**
`generalize(type_, info)` wraps a type in a `TForall` over the variables
it leaves free, and it is called at exactly three places: the type
assembled from a `def`'s own annotations (`function_type`), the type a
`def name : type` line gives (`declare_signatures`), and a binding's
annotation (`check_annotation`). Miss one and a bare `TFunction` holding
a free `TVar` reaches the rest of the pass, where it compares unequal to
the same type properly quantified — which is exactly the bug that made
`g: (a) -> a = id` refuse a program that is right.

**Checking a body needs no substitution at all.** A `TVar` is
`same_type` with itself and with nothing else, so binding a parameter to
the variable its signature names *is* skolemization: a body that adds 1
to an `a` is refused where it is written, because `a` is not `Int`. This
is the whole of `check_function`'s change — strip the quantifier, bind
the parameters to what is underneath.

**A call matches, it does not unify.** `match_type` walks the declared
parameters against the arguments' actual types one way, binding each
quantified variable the first time it is reached and requiring agreement
after that. There is no occurs check and nothing to solve, because a
variable is only ever bound to a type already known. What it cannot
reach it cannot decide, so `all a. (Int) -> a` is refused at the call
rather than silently answered.

**Two `all`s are compared up to renaming.** `same_type` canonicalizes
both sides' bound variables by position (`canonical`), which is what
makes a nested `all` — first-class polymorphism — a comparable thing at
all. Nothing more general was built: an argument wanted at
`all x. (x) -> x` must be that type, not merely one that could be
instantiated to it.

**Inference never produces a variable.** A `def` with no annotations is
worked out exactly as before, in alternatives (`docs/type_inference.md`),
and `declared_type` puts `TUnknown` where nothing is written — not a
`TVar`. The two vocabularies stay apart, which is why a signature
mixing variables with `|` is refused outright rather than given a
meaning nothing here would honour.

## Patterns, lists, and the one rule they share

Three things were added together because they are one story: a list has
an element type, a pattern is checked against the type of what it
matches, and a `match`'s arms agree the way an `if`'s branches do.

**`check_pattern` is the whole of pattern checking** — one function over
the Pattern datatype, taking the type the pattern matches and answering
the environment its captures bind. Nothing in a pattern is evaluated, so
there is no store to thread and no way for one to suspend.

`accepts` is covariant in a list's element *and* in a tuple's parts,
which is what carries `[!]` inside a structure: `([], 0)` has to fit
`([Int], Int)`. Both are sound because both are immutable in Pyking --
nothing can be written into either.

**`agree(a, b)` replaced `same_type` wherever two branches meet.** It
answers the type they both fit, keeping the more general, and it is used
by `if`, the `if` expression, a `match`'s arms, a list literal's
elements, and a type variable met twice at one call. What forced it is
the empty list: `[]` is `[!]`, so a base case returning `[]` has to sit
beside a branch returning `[Int]`. `accepts` gained one covariant case
for `TList` to make that work, which is sound because a Pyking list is
immutable.

**`covers` decides whether a `match` is total**, and it is deliberately
syntactic: one irrefutable pattern, both of a Bool's values, or a set of
list patterns taking every length. That last rule is not a flourish — it
is how every recursion over a list is written (`case []` and
`case [x, ..rest]`), and without it the value form would demand a
redundant `case _` in the language's commonest idiom. Totality is
required only where a value is taken (`require_total`, from `SLetStmt`
and `SReturnStmt`), because a `match` that fits no arm does nothing and
there would be no value.

**`covers_column` reads those same rules one level in.** A tuple's shape
is fixed by its type, so a column that matches anything in every pattern
can rule no value out, and a set of tuple patterns covers as soon as
*one* column does: `(a, true)` and `(a, false)` take every `(Int, Bool)`
for exactly the reason `true` and `false` take every `Bool`, and
`(a, [])` beside `(a, [b, ..rest])` takes every `(Int, [Int])`. Without
it those need a `case _` that can never run — which is worse than
untidy, since `target_ocaml.py` compiles what this checker accepts and
OCaml *can* see the arm is unreachable, so it warns, and a warning about
generated code fails that target's tests.

One refutable column is the whole of the rule, and the limit is
deliberate: columns that only cover *together* — `(true, true)`,
`(true, false)`, `(false, _)` — are answered no. Saying no asks for an
arm that is not needed; saying yes without a decision procedure would
accept a `match` with a hole in it. A refutable pattern nested inside a
*list element* is not read this way either (`[[], ..r]` beside
`[[a, ..s], ..r]` over a `[[Int]]` still wants a `case _`).
`tests/match_exhaustive_tuple.pyk` pins what is covered.

## One loop, and what it is worth

`for`, `while` and `loop` are one node, so the checker has one case for
all of them. Three additions to what was already there:

**The iteration clause** (`check_iteration`): a `for` walks a `[T]` and
binds its element over the body; a `while` is a `Bool` test, asked where
the accumulator is in scope so it can ask about it.

**`result`** is checked in the accumulator's scope — not the element's,
since there may have been no turns, and nothing the body bound is in
scope either. What a loop is worth is the `result` expression if one is
written, else the accumulator if one is, else unit; every `break` must
`agree` with that. A plain `loop:` is the exception, and `loop_value`
decides it from the `break`s alone: it ends only by breaking, so they
are the only answer there is.

**A `break` supplies `TNever`**, and so does a `continue`. Nothing
arrives after either, every type accepts `TNever`, and `agree` keeps the
other branch's answer — which is what lets a branch that breaks sit
beside one that goes round again. A *bare* `break` is `break ()`, so
what it gives the loop is unit rather than the accumulator.

**A loop with an accumulator must say what the next turn carries on
every path**, which `ends_every_path`/`ends_here` check structurally:
each path ends in a `continue`, a `break` or a `return`, or in an
`if`/`match` whose branches all do (a `match` has to cover its subject
as well). A `continue`'s operand goes into `Frame.carries`, which is
also what the accumulator widening reads. A loop carrying nothing is
asked none of this.

### The accumulator can widen

`loop i, acc = 0, [] for x in xs:` starts at `(Int, [!])` and ends at
`(Int, [(Int, String)])`. The body cannot be checked against the
initializer's type, because from the second turn on it will see the
wider one. So where the accumulator holds a `TNever` anywhere
(`has_never`), the body is walked once against a **throwaway `tmap`**,
purely to learn the width; the real check then runs against the settled
type. Recording both passes into the real table would merge them into a
`TOr` — which is what the first cut did, and why the probe table is
separate.

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
