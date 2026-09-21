# Type inference

How Pyking works out the type of a function nobody annotated.

The rules a *program* is judged by are in [../PYKING.md](../PYKING.md),
"Type checking". How the checker is built as a piece of software is in
[typesystem.md](typesystem.md). This page is the algorithm: what it
does, how it compares to Hindley-Milner, and how the code implements it.

**Part I** is the design — the idea, worked examples, and the
comparison. **Part II** is the code — the data structures, the key
functions, and how they fit together. Part I stands on its own; read
Part II when you are about to change something.

---

# Part I — The design

## 1. The idea

A `def` that wrote its type down is checked where it stands. A `def`
that did not is worked out **from its body**, the first time something
calls it.

```
                    ┌──────────────────────────────────────┐
   def double(n):   │  nothing happens here                │
       n * 2        │  (the definition is put aside)       │
                    └──────────────────────────────────────┘
                                     │
                        first call reaches it
                                     ▼
   x = double(21)   ┌──────────────────────────────────────┐
                    │  1. n := ?1        (a metavariable)  │
                    │  2. check the body: `*` wants Int,   │
                    │     so ?1 := Int, and the body is Int│
                    │  3. nothing left open, so the type   │
                    │     is (Int) -> Int                  │
                    │  4. check `double(21)` against it    │
                    └──────────────────────────────────────┘
```

The call is a **trigger** and a **scope**. It is not a source of
parameter types. Step 1 does not look at `21`; it invents a variable and
lets the body decide. That is the whole design, and everything else
follows from it.

Because the body decides, the answer is the **principal type**: the most
general type that body has, the one from which every type it can be used
at follows. It does not depend on which caller arrived first, or on what
that caller happened to pass.

## 2. A worked example

```pyking
def apply(f, x):
    f(x)

print(apply(id, 3))
```

Step by step, with `?n` for metavariables:

| | what happens | what is known |
|---|---|---|
| 1 | `apply`'s parameters and result get fresh variables | `f : ?1`, `x : ?2`, result `?3` |
| 2 | the body is `f(x)`. Calling `?1` says it is a function of one argument | `?1 := (?4) -> ?5` |
| 3 | the argument `x : ?2` is unified with the parameter `?4` | `?4 := ?2` |
| 4 | the call is worth `?5`, and that is what the body supplies | `?3 := ?5` |
| 5 | nothing solved `?2` or `?5`; generalise both | `apply : all a b. ((a) -> b, a) -> b` |
| 6 | now check `apply(id, 3)` against that scheme | fresh instance per call |

Nothing in step 2–4 looked at `id` or `3`. They are checked in step 6,
against a type that was already settled — exactly as a call to a fully
annotated function is checked.

Step 6 in detail: the scheme is **instantiated** with fresh variables,
giving `((?6) -> ?7, ?6) -> ?7`. Then `id : all c. (c) -> c`
instantiates to `(?8) -> ?8`, and unifying it with `(?6) -> ?7` gives
`?6 := ?8` and `?7 := ?8`. Then `3 : Int` unifies with `?6`, so
everything collapses to `Int` and the call is worth `Int`. A second
call, `apply(id, 'hi')`, gets its own instantiation and its own
variables, and comes out `String`.

## 3. Where the demands come from

The body "decides" the parameters by making **demands**, and every
demand is unification against a type the construct already knows:

```
   n * 2            `*` takes two Ints        →  unify(?n, Int)
   if c: ...        a condition is Bool       →  unify(?c, Bool)
   for x in xs:     a `for` walks a list      →  unify(?xs, [?e])
   case [h] ++ t:   this pattern matches a list  →  unify(?s, [?e])
   f(x)             `f` is a function          →  unify(?f, (?a) -> ?b)
   n, s = pair      `pair` is a 2-tuple        →  unify(?p, (?a, ?b))
   return e         every path gives one type  →  unify(?r, typeof(e))
   if c: a else: b  branches are one type      →  unify(typeof(a), typeof(b))
```

Each is written where the construct is checked, and each answers there
and then. There is no phase that gathers demands and solves them later.

## 4. What is left open becomes a variable

When the body is done, any metavariable still unsolved is one the body
never had to decide — which is exactly what a type variable means. They
are bound by one `all` at the top:

```
   after checking the body:   ((?2) -> ?5, ?2) -> ?5
   generalise:                all a b. ((a) -> b, a) -> b
```

**With one exception**, and it is the only place generalising is
*unsound* rather than merely imprecise:

```pyking
def hold(n):
    def wrap(other): (n, other)     # `other` generalises; `n`'s type does not
    (wrap(1), wrap('two'))
```

`wrap` reads `n`, whose type belongs to `hold` — whoever calls `hold`
chooses it, so `wrap` may not promise to work for every type of `n`.
The rule is *do not generalise a variable the enclosing environment
already holds*, and it gives:

```
   hold : all a. (a) -> ((a, Int), (a, String))
   wrap : all b. (b) -> (a, b)          for hold's own `a`
```

Note `wrap`'s type mentions `a` without binding it. Pyking has no syntax
for "the type my enclosing function was called at", so `-t pyking`
prints no annotation for `wrap` rather than a letter that would read as
more general than the truth.

## 5. Rank one, and why that is the whole story

A metavariable stands for a **type**, never for a scheme. So an `all`
can never be solved *into* one, and **inference never produces a
higher-rank type.**

Every *use* of a polymorphic thing is instantiated with fresh variables
before it is used:

```pyking
def map(f, lst): ...
print(map(id, [1, 2, 3]))
```

`id : all a. (a) -> a` arrives at `map`'s parameter as one of its
instances, `(?9) -> ?9`, not as the `all` itself. So `map` comes out
`((a) -> b, [a]) -> [b]` — the same as if `double` had been passed, and
the same whichever call came first.

The one exception is a parameter whose type is **written** polymorphic.
Such a parameter demands the scheme itself rather than one of its
instances, and the two are made one scheme by unifying under the
quantifier (§12a) — which is what lets a written `all` mention a
variable from outside it:

```pyking
def use : (all a. (a) -> a) -> ()
def use(f):
    print(f(1), f(true))            # `f` is polymorphic because it says so
```

There the argument must be that scheme *whole*, and it is compared as a
scheme rather than instantiated. Being written down is the entire
difference:

| | inference | annotation |
|---|---|---|
| rank | 1 only | any |
| guarantee | the principal type, always | what you wrote is what is enforced |
| decidable | yes | not a question — nothing is guessed |

This line is deliberate. Inferring rank-2 types is undecidable in
general, and anything that guesses at them gives up the guarantee in the
middle column, which is the one property the whole design exists to
provide.

## 6. Recursion

While a body is checked, its own name means the **monotype** its
parameters were given. So a recursive call is an ordinary call to
something already in scope, and what it returns is one more variable the
body goes on to solve:

```pyking
def countdown(n):
    if n < 1:
        0                          # this branch says the result is Int
    else:
        countdown(n - 1) + 1       # `+ 1` says the recursive call gave Int
```

Both branches must be one type, `<` says `n` is Int, and the answer is
`(Int) -> Int`. Nothing is guessed, and nothing needs a second pass over
the body. A function with no base case at all types the same way:

```pyking
def forever(n):
    forever(n + 1) + 1             # (Int) -> Int; it simply never returns
```

Functions that name **each other** are worked out as one group:

```
    def even(n): ... odd(n - 1) ...
    def odd(n):  ... even(n - 1) ...

    ┌─ group ──────────────────────────────────────────┐
    │  even := (?1) -> ?2      odd := (?3) -> ?4       │  monotypes
    │  check even's body, then odd's, in that scope    │
    │  generalise both, together                       │  schemes
    └──────────────────────────────────────────────────┘
```

The group is the **strongly connected component** of the call graph
among the block's definitions — the ones that really do depend on each
other. Only those. A sibling this body merely *calls* is worked out and
generalised first, on demand, so it is already polymorphic by the time
this body uses it. That distinction is what makes the next section work.

## 7. `let`-polymorphism: the line between a `def` and a parameter

```pyking
def identity(x): x

def pair_up(n, word):
    (identity(n), identity(word))    # fine: two instances of a scheme
```

`identity` is a *definition*, so it is generalised before anything that
names it is checked, and each use gets its own instance. That is
`let`-polymorphism.

```pyking
def use(f):
    print(f(1), f(true))             # error: argument 1 has type Bool,
                                     #        but Int was expected
```

`f` is a *parameter*, so it has a type, not a scheme, and the second use
is checked against what the first settled. This is precisely
Hindley-Milner's line, and this checker draws it in the same place.

**A lambda is on the parameter's side of that line**, and stays there
however it is bound:

```pyking
def named(x): x
print(named(1), named("a"))          # fine: a definition, generalised

id = x => x
print(id(1))
print(id("a"))                       # error: argument 1 has type
                                     #        String, but Int was
                                     #        expected
```

`check_lambda` gives each unannotated parameter a metavariable, checks
the body in the environment the lambda stands in, and answers a
`TFunction` — nothing generalises it, so what the first use settles is
what every later use is held to. A type variable *written* in a lambda
parameter's annotation is a metavariable too, shared by every parameter
that names it: a lambda has nothing to quantify one over, so `(x: a) =>
x` means "some type, to be settled" rather than "every type".

That is Hindley-Milner's rule rather than a shortcut. Generalising at a
lambda is what a higher-rank system does, and every guarantee in
section 5 rests on not doing it. It is also why the machinery is
untouched: generalisation hangs off `SFunctionDef` — `store.instances`
is keyed by a definition's symbol and `infer_definition` is triggered by
a call — so a lambda simply never reaches it. `def` is how a polymorphic
function is written.

## 8. Comparison with Hindley-Milner

**What is the same.** The type system is Hindley-Milner's:
rank-1 polymorphism, generalisation at definitions, instantiation at
uses, first-order unification with an occurs check, and the "not free in
the environment" side condition on generalisation. What it accepts and
what it infers match algorithm W. Where the two would disagree, this one
is wrong.

**What is different, and why.**

| | textbook algorithm W | here |
|---|---|---|
| **when** a definition is worked out | in dependency order, before its uses | on first use — the call is the trigger |
| a definition nobody uses | still typed | never typed; prints as written |
| **where** solving happens | a substitution threaded through, or a constraint set solved at the end | eagerly, at each construct that demands a type |
| what is threaded | a substitution | a `Store` — the substitution plus what has been worked out about definitions |
| after generalising | done | the body is checked once more with the variables rigid (`verified`) |
| overloading | not present | four builtins, handled by the re-check (§9) |

The first row is the only structural difference, and it buys three
things:

1. **No dependency ordering pass.** A definition is worked out when
   something needs it, which visits the call graph in dependency order
   by construction. Mutual recursion is handled by the SCC computed at
   that moment, over the block's definitions only.
2. **The body is checked in the scope it was written in**, which the
   store records. That is what keeps deferring sound: a body checked at
   a call site is *not* checked in the caller's scope.

   ```pyking
   def f(n):
       n + offset        # error: `offset` is not in scope here ...

   offset = 10
   print(f(1))           # ... even though it is in scope here
   ```
3. **Errors stay local.** Because solving happens at the demand,
   a failure is reported at the construct that made it, in the words the
   checker already uses:

   ```
   'scale.pyk' 16:12-16:17 Type error: argument 1 has type String, but
     Int was expected
   ```

   A constraint solver would report the same program as a clash between
   two constraints, some distance from either.

**Two implementation details that matter.**

- **The occurs check.** Solving a variable to a type mentioning it
  builds an infinite type. `f(f)` asks for exactly that, and it is
  refused rather than looped over.
- **Which of two variables is solved.** When two metavariables meet, the
  *younger* is solved to the older. A variable handed out earlier may
  belong to an enclosing scope, and solving that one to a fresh inner
  variable would lose the fact that §4's side condition depends on.
  Variables are named `?0`, `?1`, … in the order handed out, so their
  names *are* their ages. This is the level discipline of a
  rank/level-based HM implementation, in one comparison.

## 9. What is left of ad-hoc polymorphism

Hindley-Milner has no overloading. Pyking has four overloaded things —
`str`, `len`, `==` and `++` — each accepting several unrelated types and
no single type. A body that uses one on a parameter has made a demand
unification cannot express.

The rule:

```
   1. the demand passes against a metavariable
      (nothing has decided it, and an operator is a reasonable
       thing to do to an unannotated parameter)
                              │
   2. generalisation proposes a scheme  all a. (a) -> String
                              │
   3. `verified` re-checks the body with `a` RIGID
      → `str(a)` is refused, because `a` is not one of the three
                              │
   4. the proposal is dropped; the definition keeps its monotype,
      with the variable still open
                              │
   5. the first call solves it, and that is what the definition is
```

```pyking
def announce(value):
    'got ' ++ str(value)     # `str` asks what it was given

print(announce(1))           # announce : (Int) -> String
# print(announce(true))      # error: argument 1 has type Bool, but Int
                             #        was expected
```

So `verified` is not only insurance. Its *failure* is the mechanism by
which ad-hoc polymorphism is handled at all. The known answer is type
classes or implicit arguments; `tests/fail_typecheck_infer_pinned.pyk`
pins the current refusal so whatever fills the gap has something to
change.

## 9aa. Overloading, and why it is not deferred

Section 9 says what is left of ad-hoc polymorphism. Since then there is
one more thing: a definition may be *overloaded* by a `::` qualifier,
and a call that leaves the qualifier out is resolved by its arguments
(docs/overloading.md).

It is resolved **where the call is written**, and nowhere else. The
arguments are checked once, and every candidate is tried against what
they turned out to be; exactly one fitting resolves it. The test is
unification, so choosing a candidate may be what decides an argument's
type — but the choice is made there and then, with whatever is known
there and then.

What is *not* done is deferring the choice until something later
decides the type:

```pyking
def both(x): (twice(x), twice(x))    # refused
```

Every candidate fits an argument type nothing has decided, so the call
is ambiguous, and the checker says so rather than carrying a
"`twice` at some type" constraint out of the body and into `both`'s
type. That constraint is a *context*, and inferring contexts is type
classes: it would make a definition's principal type depend on what its
body happened to call, which is exactly the property section 5
guarantees against. The feature that solves the problem properly is an
implicit parameter, and the error message names it.

## 9a. Two numeric types, no type classes

`Int` and `Float` make `+ - * /` overloaded as well, and they are the
case §9's mechanism does *not* cover. The difference is what the
operator answers: `str` and `==` give one type whichever argument they
take, so the answer can be reported while the argument stays open. `+`
gives back what it was given, so it cannot.

`operator_result` is where that shows, and it has three cases:

1. the operand type is settled — find its row in the table, or refuse;
2. still open, and every row agrees on the result — answer that result
   and leave the operand open. This is `==`, `<`, `<=`, `>` and `>=`,
   all of which answer `Bool`;
3. still open, and the rows disagree — **unify the operand with the
   first row's type**. `+ - * /` list `Int` first, so an undecided one
   is Int arithmetic.

Case 3 is a default, and defaults are what this inference otherwise
avoids: the type it reports is no longer the *principal* one, because
`def add(a, b): a + b` could as well have been `(Float, Float) ->
Float`. That is the price, and three alternatives were weighed against
it:

- **Refuse as ambiguous, requiring an annotation.** Principal, and it
  breaks every unannotated arithmetic program — the whole
  `typecheck_noann_*` family included. A type system that takes working
  programs away to gain a property nobody asked for is the wrong trade.
- **A numeric type variable, resolved later.** Type classes without the
  name: it needs a constraint store, a solver pass and a defaulting rule
  of its own, and §12's "unify is eager and local, there is no
  constraint store" stops being true. Every error message gets worse.
- **Widen an Int to a Float implicitly.** Then `check_binary` no longer
  unifies its operands before consulting the table, which is the
  assumption the table rests on — and `1 / 2` changes meaning with
  context.

Case 3 costs one line of principality in a corner, and takes nothing
away. The asymmetry it leaves is real and worth stating plainly: an
unannotated `a + b` is Int, and an unannotated `a > b` is open. Both are
consequences of the same three cases, and `tests/typecheck_float_default.pyk`
pins them.

## 10. What the design gives up

- **Rank-2 types are written, not inferred** (§5).
- **An uncalled definition gets no type.** Nothing triggers it. It
  prints exactly as written.
- **Overloaded builtins fix a parameter to its first call's type** (§9).
- **`?` in printed output does not round-trip.** `-t pyking` output is
  otherwise re-parsable Pyking; `?` is printed where a type has no
  spelling — an uncalled function, or a nested definition holding an
  enclosing scope's variable — and there is deliberately no syntax for
  it.

---

# Part II — The code

Everything below is `src/typesystem.ml` unless said otherwise.

## 11. The two kinds of variable

Both are `syntax.ml`'s `TVar`, told apart by one field:

| | `rigid=True` | `rigid=False` |
|---|---|---|
| called | a **rigid** variable | a **metavariable** |
| written | `a`, from source | `?0`, `?1`, … never from source |
| means | a type the **caller** chose | a type **this check** is still choosing |
| a body may | assume nothing about it | have it become anything |
| compared by | `same_type` — equal only to itself | `unify` — solved to whatever it meets |

They are exact opposites, which is why one class serves both: the field
says who does the choosing. `TUnknown` is a third thing again — not a
type yet, standing where an annotation was not written.

A metavariable's solution lives in `store.solutions`, never in the node,
so a type stays an ordinary immutable value.

```
   fresh_meta(info, store)   →  a new ?n, and the store that handed it out
   is_meta(type_)            →  is this one?
   meta_age(name)            →  when it was handed out ("?7" → 7)
   solving(store, n, t)      →  the store in which ?n is t
   prune(type_, store)       →  follow solutions at the OUTERMOST level only
   zonk(type_, store)        →  follow them all the way down, everywhere
   metas_in(type_, store)    →  which are still unsolved in here
   occurs(name, type_, store)→  would solving this build an infinite type?
```

`prune` is the cheap one, used to decide which `case` a type falls into.
`zonk` is the thorough one, used whenever a type leaves the machinery —
into a message, into `tmap`, into a comparison that must see through
everything.

## 12. `unify`

```
unify : Type -> Type -> Store -> Store?
```

The store in which two types are one type, or `None` where none is. Its
cases, in order:

```
   ?a  vs  ?a        → nothing to do
   ?a  vs  ?b        → solve the YOUNGER to the older        (§8)
   ?a  vs  T         → occurs check, then solve ?a := T
   T   vs  ?a        → the same, the other way round
   [S] vs  [T]       → unify the elements
   (S…) vs (T…)      → same length, unify componentwise
   (S…)->R vs (T…)->Q→ same arity, unify parameters then results
   all a. S vs all b. T
                     → same arity, unify UNDER the quantifier (§12a)
   anything else     → `same_type` decides; nothing to solve
```

That last line covers two ground types and two rigid variables: either
they already are one type or no solution makes them one.

### 12a. Unifying under a quantifier

A scheme is not ground. It can hold a metavariable that came from
instantiating something enclosing it, and that variable still has to be
solved:

```pyking
def extract : (all r. ((a) -> r) -> r) -> a
def pack_int : all r. ((Int) -> r) -> r

print(extract(pack_int))
```

`extract`'s own `a` is instantiated at the call, so the parameter it
wants is `all r. ((?2) -> r) -> r`, and the argument is
`all r. ((Int) -> r) -> r`. Comparing those structurally answers no —
`?2` is not `Int` — but they are one scheme as soon as `?2 := Int`.

`unify_under` makes them one:

```
   1. rename BOTH binders to the same fresh rigid variables
      all r. ((?2) -> r) -> r     →   ((?2) -> !7) -> !7
      all r. ((Int) -> r) -> r    →   ((Int) -> !7) -> !7
   2. unify the bodies                    ?2 := Int
   3. escape check
```

The variables are named `!0`, `!1`, … from the same counter behind `?n`.
`!` is unwritable in source, so they collide with nothing a program
could have named.

**The escape check** is what keeps step 2 sound. Every metavariable free
in either body *before* step 1 belongs to a scope where `!7` means
nothing, so one solved to a type naming it would name a type nobody
there can name:

```
   all r. (r) -> r    vs   all r. (r) -> ?m      ?m from outside
   →  ((!7) -> !7)    vs   ((!7) -> ?m)          →  ?m := !7   ✗ refused
```

`free_vars` answers it directly: a variable bound by the scheme is gone
by then, so anything named `!n` still free in a solution has escaped.

Schemes binding **different** numbers of variables are not one scheme,
and fall through to `same_type`, which says no.

This is the only place `unify` looks inside an `all`. `same_type` keeps
its own quantifier case — comparing up to renaming, deciding nothing —
for `accepts` and `verified`, the two places where nothing may be
solved.

Two helpers put a name on the common shape:

```
   demand(actual, wanted, info, what, store)  →  store, or a Type_error
                                                 saying what wanted it
   demand_list(actual, info, what, store)     →  (element type, store)
```

`demand` is how a construct asks for a type — `unify` plus one message.
`demand_list` makes a fresh `?e`, demands `[?e]`, and hands back `?e`.

## 13. The `Store`

One immutable value threaded through the whole pass, like `env`.

| field | holds | written by |
|---|---|---|
| `solutions` | `?n` → what it turned out to be | `solving` |
| `environments` | a definition's symbol → the environment it was **written** in | `with_environment` |
| `instances` | a definition's symbol → its one `Instance(type)` | `remembering` |
| `checking` | the definitions being worked out right now | `checking_now` |
| `captured` | metavariables a definition could **not** generalise | `infer_definition` |
| `frame` | what the innermost body is gathering: `returns` | `returning` |
| `fresh` | the counter behind `?n` | `fresh_meta` |
| `signatures` | a definition's symbol → the type a `def name : type` line gave it | `with_signature` |
| `groups` | a definition's symbol → its block's `def`s | `declare_functions` |

The last two are **given** rather than worked out; the rest accumulate.

**Nothing in it is ever written to.** Every function handed a store
returns one, because what it worked out is knowledge its caller needs. A
metavariable is handed out once, so no two checks can disagree about
one — which is what lets `learned(store, inner)` keep an inner check's
solutions, instances, environments and counter while going back to the
caller's own frame and checking set.

## 14. Two ways in, and where they meet

```
   check_stmt: SFunctionDef
        │
        ├── fully annotated? ──yes──►  check_function
        │                              (checked here, now, with the
        │                               declared variables RIGID)
        │
        └── no ─────────────────────►  declared_type
                                       (a TFunction with TUnknown where
                                        the annotation was missing, plus
                                        `tmsym` and `definition`)
                                              │
                                       put aside; the store records the
                                       environment it was written in
                                              │
                        ┌─────────────────────┴─────────────────────┐
                        │                                           │
             something CALLS it                      its NAME is read as
                        │                                   a value
                   infer_call                                │
                        │                                work_out
                        └─────────────► infer_definition ◄──────┘
                                              │
                                          a scheme in
                                        `store.instances`
                                              │
                                          called_at
                                       (like any other call)
```

`check_function` and `infer_definition` produce the same kind of thing —
a scheme — and from then on nothing downstream can tell which one made
it. That is why `called_at` has no second code path.

**A partly annotated `def` goes down the right-hand branch, and what it
wrote still counts.** `fully_annotated` asks for every parameter *and*
the return type, so `def f(n: Int):` is deferred; but `monotypes_for`
then starts the body from the types the source wrote, with a
metavariable only where nothing was. An annotation is a claim about the
program wherever it is written, and one on a definition the checker
infers the rest of is enforced like any other.

## 15. `infer_definition`, step by step

The heart of the pass. Given a deferred `TFunction`:

```
 1  body_env   = environment_of(store, tmsym)     where it was WRITTEN
 2  group      = inference_group(node, store)     the SCC (§6)
 3  monotypes  = monotypes_for(group, store)      what the source wrote,
                                                  ?a for what it did not
 4  mark every member `checking_now`

 5  for each member:
        its own written-in environment
        + every member bound to its monotype       ← recursion works here
        + its parameters bound to the monotype's
        body_result(...)                           what the body supplies
        required(...)                              unify that with ?r

 6  learned(store, inner)                          keep what was worked out

 7  for each member:
        outer  = free_metas(its environment)       §4's side condition
        store.captured |= outer ∩ metas_in(mono)
        scheme = generalise(node, mono, outer, store)

 8  remember EVERY scheme  ──  before verifying any of them
 9  for each member:
        verifying(...)  → the scheme, or the monotype if it does not hold
        remember it, record it in `tmap`

10  return settled_type(func_type, store)
```

Step 8 is not optional. `verified` re-checks a body, and a body
re-checked while a name it calls is still unworked would work that one
out all over again — which for two functions that call each other never
ends.

Step 5 binds each member in **its own** written-in environment, not the
group's or the caller's, because what a body captures is what was bound
where it stands.

## 16. Generalising

```
generalise : SFunctionDef -> TFunction -> {String} -> Store -> Type
```

`zonk` the monotype, take the metavariables still unsolved, drop the
ones in `outer`, name what is left `a`, `b`, … and wrap the result in
one `TForall`. `free_metas(env, store)` computes `outer` by walking the
types the environment binds.

```
verified : SFunctionDef -> Type -> {Int: Type} -> Store -> {Int: Type}?
```

Checks the body again with the scheme's variables **rigid** — the same
check an annotated polymorphic function gets. It answers the `tmap` that
check filled, so an adopted scheme is what the body's own nodes are
reported as, or `None`.

```
verifying : ... -> Type
```

`generalise` + `verified`, falling back to the zonked monotype. Two
reasons it exists: it makes "a type this checker reports is one it
enforces" true by construction, and its fallback is §9's mechanism.

## 17. Calls

```
check_call ──► settled_type ──┬── still deferred? ──► infer_call
                              │                       (work it out, then
                              │                        check this call)
                              └── otherwise ────────► called_at
```

`settled_type(type_, store)` prunes first, then replaces a deferred
`TFunction` with the scheme its definition turned out to have. Pruning
matters: a definition reached through a metavariable that has since been
solved to it — a function put in a list and taken out again — must be
seen for what it is.

```
called_at(scheme, call, args, env, tmap, store)
    1. instantiate the scheme          fresh variables, this call's own
    2. is it still just `?f`?          then BUILD (?a…) -> ?r and unify
    3. check the arity
    4. check_arguments: left to right, so the first mistake is reported
```

Step 2 is the one place a type is *built* by a demand rather than
compared against one. It is what types `f(x)` inside a body where
nothing has yet said what `f` is.

`work_out` runs wherever a definition's name is read as a value --
`check_expr`'s `EVar` case, and `fitted` below. Handing a definition
somewhere is a demand on its type as surely as calling it is, and
without it the body would never be checked at all: a `def` passed into
a list, bound to a name, or returned would reach run time unchecked.

```
fitted(expected, actual, arg, position, tmap, store)
    work_out(actual, ...)              a deferred argument is worked out
    settled_type(actual, store)
    expected is not a written `all`?   then INSTANTIATE the argument
    unify(expected, actual, store)
```

The instantiation on the second-to-last line is §5: an argument that is
itself polymorphic stands wherever one of its instances is wanted. Where
the parameter *is* written `(all a. …)` the two are compared as schemes
instead, by `unify`'s last case falling through to `same_type`.

## 18. Reporting

```
   record(tmap, sym, type_, store)    zonk, then store under the symbol
   displayed(type_, store)            name leftover metavariables a, b, …
                                      — except `store.captured` ones,
                                        which become `?`
   shown(type_, store)                zonk + displayed + pprint, for a message
   shown_nested(type_, store)         the same, parenthesised where needed
```

A metavariable's own name must never reach a message, so every error
that names a type goes through `shown`. Where two types appear in one
message they are named **together** — packed into one tuple, displayed,
unpacked — so a variable standing in both reads as the same letter in
both.

`type_check` reads the whole `tmap` back through `zonk` and `displayed`
at the very end, because a variable still open where it was recorded may
have been solved by something written further down.

## 19. Where everything is

| what | functions |
|---|---|
| metavariables | `fresh_meta`, `fresh_metas`, `is_meta`, `meta_age`, `solving`, `prune`, `zonk`, `metas_in`, `occurs` |
| unification | `unify`, `unify_under`, `demand`, `demand_list`, `agree`, `satisfies` |
| instantiating | `instantiate`, `instantiated`, `substitute`, `generalize`, `canonical` |
| deferring | `declared_type`, `declare_functions`, `declare_signatures`, `check_stmt`'s `SFunctionDef` case |
| working out | `infer_call`, `infer_definition`, `work_out`, `inference_group`, `names_used`, `monotypes_for`, `body_result`, `required`, `one_type` |
| generalising | `generalise`, `free_metas`, `names_in`, `next_name`, `verified`, `verifying` |
| calls | `check_call`, `settled_type`, `called_at`, `check_arguments`, `fitted` |
| comparison | `same_type`, `accepts`, `instance_for` |
| the store | `Store`, `Instance`, `Given`, `Exit`, `Frame`, `with_environment`, `remembering`, `checking_now`, `learned` |
| reporting | `record`, `displayed`, `shown`, `shown_nested` |

## 20. Tests

**`tests/typecheck_hm_*.pyk`** are the direct test of this page. Each
pins a principal type in its `.ast.out` and is run on every backend that
accepts it, so a type the checker infers is one that demonstrably runs
and means the same thing everywhere.

| test | property |
|---|---|
| `hm_apply`, `hm_compose` | the basic shapes, and where each variable comes from |
| `hm_map`, `hm_fold`, `hm_lists`, `hm_pipeline` | list functions, the empty list, composing them |
| `hm_tuples` | a variable per component |
| `hm_letpoly` | one caller, two instances (§7) |
| `hm_generalisation`, `hm_nested` | what may **not** be generalised (§4) |
| `hm_mutual`, `hm_recursion` | a group, and a recursive call deciding its own result (§6) |
| `hm_higher_order` | a function parameter worked out from the body, used at two element types |
| `hm_order` | the same function with its callers in either order, giving one answer |
| `hm_branch_uses` | what one branch of an `if` works out is true in the other |
| `hm_shadowed` | many instances of one definition |
| `hm_annotation_agrees` | each body written twice, annotated and not, reaching one type |
| `hm_annotated_rank2` | first-class polymorphism, written down (§5) |

**`tests/fail_typecheck_hm_*.pyk`** pin what is refused and how it is
worded: `hm_occurs` and `hm_infinite` (the occurs check, through an
application and through a constructor), `hm_rank2` (a parameter used at
two types), `hm_argument` (an inferred type enforced like a written one).

First-class polymorphism, being written rather than inferred, is pinned
by three files outside those families:

- `tests/typecheck_type_first_class.pyk` — a parameter demanded at
  `(all x. (x) -> x)`, used at two types in one body.
- `tests/typecheck_type_first_class_twice.pyk` — the same, with both
  uses reaching the *result* type: `(all a. a -> a) -> (Int, Bool)`. The
  argument is a definition with no annotation, so an inferred scheme is
  what satisfies a written one.
- `tests/typecheck_type_first_class_outer.pyk` — the quantified
  parameter *also mentions a variable from outside it*, so the two
  schemes are one only after unifying under the quantifier (§12a).
- `tests/fail_typecheck_type_first_class.pyk` — refuses a `(Int) -> Int`
  where that `all` is demanded, the direction that makes the annotation
  mean something. The other direction, a polymorphic argument where an
  *instance* is wanted, is always fine and is checked in the same file.

**`tests/typecheck_noann_*.pyk`** are twenty of the annotated
`typecheck_*` programs with every annotation removed, sharing their
`.out` unchanged — the standing check that an annotation says what a
program means to a reader and to the checker, never what it does.
