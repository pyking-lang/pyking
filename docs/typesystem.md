# `typesystem.ml`: design

How `src/typesystem.ml` is built as a piece of software: its shape, what
is threaded through it, and why each decision was made that way.

For the rules a *program* is judged by, see PYKING.md, "Type checking".
For the inference algorithm — how a function nobody annotated gets a
type — see [type_inference.md](type_inference.md), which this page does
not repeat. For a one-page summary of every function, see
[source.md](source.md#typesystemml).

## The shape of the pass

```
     [Stmt]  (symbolized)
        │
        ▼
   ┌─────────────────────────────────────────────────────────────┐
   │  type_check(stmts)                                          │
   │     env   = builtin_env()      print, range, str, len       │
   │     tmap  = {}                                              │
   │     store = empty_store()                                   │
   │        │                                                    │
   │        ▼                                                    │
   │  check_stmts ──► declare_functions   (hoist the block's defs)│
   │        │                                                    │
   │        └──► check_stmt  ─────► check_expr ─────► check_call │
   │                 │  │                  │                     │
   │                 │  └── check_pattern  └── check_binary      │
   │                 │                         check_builtin_call│
   │                 └── check_function | infer_definition       │
   │        │                                                    │
   │        ▼                                                    │
   │  zonk + displayed over the whole tmap                       │
   └─────────────────────────────────────────────────────────────┘
        │
        ▼
     {Int: Type}      symbol → type, for every node that has one
     {Int: Resolution} symbol → what that call denotes, for every one
                       overloading or an implicit parameter settled
```

One entry point, `type_check(stmts) -> (tmap, qmap)`. A whole program
in, the types it worked out back, and beside them what every call it
resolved denotes -- which `src/elaborate.ml` then rewrites the program
by (docs/implicits.md). It raises `Type_error` for the first thing
that does not check, and `Analyses.Analysis_error` for a name it cannot
find.

**The pass still changes nothing.** `qmap` is a second *result*, filled
by `record_resolution` exactly as `tmap` is filled by `record` -- both
overwrite, because a generalisable body is checked twice and
`verified`'s pass is the one that counts, and both are read back
through `zonk` at the end.

## One function per AST datatype

The organizing rule is stated as a block of signatures near the top of
the file, written the way a statically typed functional language would
state them:

```
   check_stmts  : [Stmt] -> Env -> TMap -> Type? -> Type? -> Store
                                                     -> (Type, Store)
   check_stmt   : Stmt  -> Env -> TMap -> Type? -> Type? -> Store
                                                -> (Type, Env, Store)
   check_expr   : Expr  -> Env -> TMap -> Store  -> (Type, Store)
   check_param  : Param -> Type -> TMap -> Store -> Type
   same_type    : Type  -> Type -> Bool
```

**No function in this module dispatches on which sort of AST node it was
handed** — only on which *variant of its own datatype* it was handed.
`check_expr` is the only place an `Expr` is matched; `check_stmt` is the
only place a `Stmt` is. There is no function that takes "any node" and
works out what to do with it.

This mirrors `syntax.ml`'s AST-as-ADT design and `analyses.ml`'s
per-kind walk, and it is what keeps a file this size tractable: a bug in
how `if` expressions are checked is a bug in `expr_type`'s `EIf` case,
and nothing about statements, functions or inference can be involved,
because nothing else reaches an `Expr`-shaped decision.

## What is threaded, and how each behaves

Six things travel with a check. They are not interchangeable, and the
differences are the design.

```
   ┌───────────┬────────────┬───────────────────────────────────────┐
   │ Env       │ immutable  │ names in scope → their types          │
   │ Store     │ immutable  │ everything worked out so far          │
   │ TMap      │ MUTABLE    │ the pass's result                     │
   ├───────────┼────────────┼───────────────────────────────────────┤
   │return_type│ context    │ what a `return` is checked against     │
   │ acc_type  │ context    │ what the enclosing loop carries        │
   │ tmap      │ (the same TMap)                                    │
   └───────────┴────────────┴───────────────────────────────────────┘
```

**`env` (`typ SMap.t`)** — the names in scope. Threaded exactly the
way `analyses.ml`'s environment is: `bind` returns a *new* map, nothing
is mutated, and leaving a scope is simply not using the extended copy.
There is no third state: a name is in the map with a type, or it is not
in scope.

**`Store`** — everything inference has worked out: solutions,
environments, instances, and the rest. Threaded like `Env`, and never
written to. See [type_inference.md](type_inference.md#13-the-store) for
the fields.

**`tmap` (`typ IntMap.t`)** — the pass's *result*: symbol to type,
built as checking proceeds and handed back once at the end. It is a
field of the `store`, which is threaded and returned everywhere already,
so recording a type costs nothing beyond what a store already carries
and nothing has to be mutated to make it work. `record` is the one
function that adds to it, and it *replaces* rather than accumulating: a
generalisable body is checked twice, and `verified`'s pass is the one
that counts.

**`return_type`** has three states, and it is threaded down through
every nested block rather than looked at once when a body finishes,
because a `return` can appear anywhere inside nested `if`s and loops:

| value | means | what `check_return` does |
|---|---|---|
| a `Type` | the enclosing function declared this | unify the `return` against it |
| `INFERRING` | the return type is being worked out | **collect** it into `store.frame.returns` |
| `None` | not inside a function | refuse: "`return` outside a function" |

**`acc_type`** is the same idea for loops, and `None` there gives
"`break` outside a loop" — the same sentence twice, from the same shape.

The rule that falls out: **a function handed a `Store` returns one.**
What it worked out is knowledge its caller needs, and handing it back is
the only way that knowledge survives the call returning.

## What every statement is asked

`check_stmt` ends in `(Type, Env, Store)`: a statement supplies a type,
leaves an environment for what follows, and threads the store. The first
element does more work than it looks like, because every kind of
statement is asked the **same question** — *what value do you supply?* —
and the answers compose with no special cases.

| statement | supplies |
|---|---|
| `SExprStmt` | its expression's type |
| `SReturn e` | `e`'s type |
| `SBreak` / `SContinue` | **nothing** (`None`) — it never falls through |
| a `loop` | the accumulator it carries — unit where it carries none |
| `SIf` / `SMatch` | whichever branch's type, once the branches agree |
| `SLet`, `SVar`, `SMutate`, … | `unit` — run for effect |

`return e` supplying "`e`'s type" is exactly the wording PYKING.md's
"Tail position" table uses. That is not a coincidence: `check_stmt` *is*
the mechanism that table describes.

Two payoffs:

- **`check_function` needs no reachability analysis.** "A body that
  returns on every path" and "a body that ends in a value" are the same
  case — ask the body's last statement what it supplies, and check that
  against the declared type. `target_java.ml` needs a real
  `definitely_returns` for `javac`'s sake; the front end does not,
  because the tail-position rule *is* the analysis.
- **`None` composes.** A branch that never falls through leaves the
  answer to its sibling, so `if c: x + 1 else: break` needs no special
  case.

`check_stmts` also tracks reachability for the *block's* value: once a
statement `ends_here`, everything after it is still checked — unreachable
code is code — but what the block is worth was settled where the block
was left.

## Blocks, and hoisting `def`s

`check_stmts` calls `declare_functions` before checking anything in the
block:

```
   block ──► declare_functions ──► every `def` bound, then
                                    every statement checked in order
```

That one step is recursion, mutual recursion and forward references: a
body is checked in an environment already holding its own name, its
siblings', and every enclosing block's. It goes through
`analyses.block_functions` — imported, not restated — so the two passes
cannot disagree about which programs are legal.

What gets bound depends on the `def`:

| | bound to | store also records |
|---|---|---|
| fully annotated | its real `TFunction`, quantified | — |
| not | `declared_type`'s placeholder: `TUnknown` where the annotation is missing, plus `tmsym` and `definition` | the environment it was written in, and its block's `def`s |

## `if`, and knowledge that outlives a branch

Both branches are checked, and the `else` is checked against the store
the `then` **left** — not the one they both started from. Only one
branch runs, but both are checked, and what either worked out is true
whichever way the program goes: a definition settled in the first branch
is settled in the second.

The two types are then held to being one type by `agree`, which is
`unify` — an `if` yields one value, so its branches have one type, and
where one of them was still open this is what settles it. A branch that
never falls through is `None` and leaves the answer to the other.

`tests/typecheck_hm_branch_uses.pyk` pins the first half,
`tests/typecheck_if_branches.pyk` the second.

## `env` *is* the scope

There is no separate name analysis; this module does that job too. It is
sound because `Env` does the whole of that job: a name must be bound
where it is used, a block's bindings do not survive it, an inner binding
shadows an outer one, a `def`'s name is in scope in its own body, and
the builtins are in scope from the start — all of it falling out of the
same immutable-map discipline `analyses.ml` established.

**What a name maps to is a `binding`**: its type, and whether the
binding was written `implicit`. There is still no option and no second
inhabitant — a name is in the map with a denotation, or it is not in
scope — and the second field is read by exactly two searches, the one
that resolves an overloaded call and the one that fills an implicit
parameter (docs/implicits.md). Everything else asks `type_of`.

An unbound name raises `Analyses.Analysis_error` — imported, not a
lookalike defined here — so the driver's `Name error` reads identically
whichever pass caught it. A caller should not be able to tell which one
ran from the wording.

**What `analyses.ml` still owns is mutability**, and it is a separate
question rather than a leftover. This module does check `var` and `:=`
for *types* — a `var` has its initializer's type, and a `:=` must give the type
the declaration fixed — but *which names may be written to* is not
something a type can say: the same `Int` is a `var` in one scope and an
`=` binding in another, so the answer is about the binding form. Hence
`analyze_mutability` is a walk of its own, running after this pass; it
needs no types, and this pass needs no knowledge of which `Int`s are
cells.

The order also settles the wording. By the time the mutability walk
runs, every name is known to be bound, so a name it cannot find is never
"unbound" — it is "not a mutable variable".

**An import is part of the scope too.** `type_check` takes the signature
of every module this one imports (`sigmaps`, from `src/module.ml`), and
`import_env` puts what they bring in into the environment before the
first statement is checked: a selected name under the name it is known
by here, and a field of a plain import under `alias.field`, which is the
spelling an `EQualified` looks up. So a qualified name is an ordinary
`Env` lookup, and nothing else in this module knows there is a module
boundary at all.

A **public implicit** is the one thing that stretches that. It is bound
under `alias.field` like anything else, and the two searches look
through the `.` when the binding is implicit — which is how an ordering
a module defines is found by an unqualified call, while still being
resolved to the module it came from (PYKING.md, "Modules").

They go in *up front* rather than as the walk reaches them because an
import is a declaration of the module, like a `def`, not a statement in
its sequence — and it has to be that way round: a definition whose type
was never written down is checked at the call, in the environment
recorded where it was written, which is the environment at the start of
the block. An import bound halfway down would not be in it.

An imported name arrives with the type the checker gave it where it was
written, `all` and all, so a polymorphic function stays polymorphic
across the boundary and instantiates at the call like any other. See
[modules.md](modules.md).

The other direction is `check_exports`, which `type_check` runs after
the walk: an exported name carries its complete type in the source — a
public `def` annotates every parameter and its return type or has a
signature line of its own, and a public `=` binding annotates its name.
A definition that annotated nothing has no type until something calls
it, and inference reads that definition off its *own* module's use of
it, which settles what this module needs rather than what it promises
elsewhere — so exporting one is refused here rather than left for
whoever imports it to trip over.

## Annotations are checked, never replaced

`check_annotation(annotation, actual, store)` carries a large idea in a
small function: an annotation is a **claim about the program**, verified
against what the value turned out to be — not silently overwritten by
the inferred type, and not trusted blindly either.

```pyking
f: (Int, String) -> Int = foo      # error at the ANNOTATION if `foo`
                                   # turns out to be (Int, Int) -> Int
```

Reported at the annotation, not at `foo`, because `foo` is a perfectly
good value of its own type and the disagreement is something the
*program* stated. That is the difference between an annotation and a
comment: a comment is never checked, so it can go stale forever; an
annotation here cannot.

It is also a **demand**, so `unify` runs first: a right-hand side still
open is settled by it, which is what makes `xs: [Int] = []` say what the
empty list holds. A binding with no annotation makes no claim and takes
whatever its value has — which is what `-t pyking` is for.

## Builtins: a type of their own

`print`, `range`, `string` and `len` are bound to `TBuiltin(name)` from the
first environment `type_check` builds, rather than to a `TFunction`,
because none of the four fits one. `print` takes any number of arguments
of any type, which no fixed parameter list expresses, and none of them is
a value in the sense `builtin.ml` means: they are host
*operations*, callable and nothing else.

`check_builtin_call` gives each its own rule, applied only at a call.
Using one any other way — `x = print`, passing `string` as an argument — is
refused, exactly as the C and Java backends refuse `print` as a value.

`TBuiltin` is a variant of `syntax.ml`'s `Type` rather than a class of
this module's own, so `Env` stays a map from a name to a type and every
lookup dispatches on a type variant. Like `TUnknown` it is unwritable in
source; unlike it, it is never recorded in `tmap`, so it cannot reach
printed output.

## Three kinds of type variable

`syntax.ml` has one node, `TVar`, and the checker uses it two ways. With
`TUnknown` that makes three things a reader has to keep apart:

| | written | means | compared by |
|---|---|---|---|
| `TVar(rigid=True)` | `a` | a type the **caller** chose | `same_type` — equal only to itself |
| `TVar(rigid=False)` | `?0`, `?1` | a type **this check** is choosing | `unify` — solved to what it meets |
| `TUnknown` | `?` | **not a type yet** — no annotation was written | never compared; replaced |

**Quantification happens once, where a written type enters the checker.**
`generalize(type_, info)` wraps a type in a `TForall` over the variables
it leaves free, and it is called at exactly three places: the type
assembled from a `def`'s own annotations (`function_type`), the type a
`def name : type` line gives (`declare_signatures`), and a binding's
annotation (`check_annotation`). Miss one and a bare `TFunction` holding
a free `TVar` reaches the rest of the pass, where it compares unequal to
the same type properly quantified.

**Checking an annotated body needs no substitution.** A rigid `TVar` is
`same_type` with itself and nothing else, so binding a parameter to the
variable its signature names *is* skolemization: a body that adds 1 to
an `a` is refused where it is written. That is the whole of
`check_function` — strip the quantifier, bind the parameters to what is
underneath.

**A call instantiates, then unifies.** `called_at` replaces the callee's
quantified variables with fresh metavariables, and `fitted` unifies each
argument with its parameter. Each call picks its own instance and
nothing is carried between two of them.

**Two `all`s are compared up to renaming, or unified under.** Which of
the two depends on whether anything may be solved.

`same_type` canonicalizes both sides' bound variables by position
(`canonical`) and decides — that is what `accepts` and `verified` use,
and it is what makes a parameter written `(all x. (x) -> x)` demand a
value polymorphic *the same way*, so a `(Int) -> Int` does not qualify
(`tests/fail_typecheck_type_first_class.pyk`).

`unify` instead renames both binders to the same fresh rigid variables
and unifies the bodies (`unify_under`), because a scheme is not ground:
it can hold a metavariable that came from instantiating something
enclosing it, and that one still has to be solved. An escape check
refuses a solution that would let a bound variable out. See
[type_inference.md](type_inference.md#12a-unifying-under-a-quantifier)
and `tests/typecheck_type_first_class_outer.pyk`.

**A type variable in a lambda's parameter annotation is a
metavariable.** Quantification is for definitions, and a lambda is not
one (PYKING.md, "Lambdas"): `check_lambda` replaces each variable the
annotations name with one fresh metavariable — one per *name*, so
`lam (x: a, y: a). …` still demands two arguments of one type — and
generalises nothing afterwards. `lam (x: a). x` therefore means "some
type, to be settled by the uses", which is what monomorphic has to mean
when a variable is written down.

**A polymorphic value may stand where an instance is wanted.**
`accepts` matches the quantified body against what is wanted and answers
whether some instantiation of it is that type (`instance_for`). One way
only and with no solving, for the two places nothing may be solved: a
written annotation, and `verified`'s re-check with the variables rigid.

## Patterns, lists, and the one rule they share

A list has an element type, a pattern is checked against the type of
what it matches, and a `match`'s arms agree the way an `if`'s branches
do. One story, three places.

**`check_pattern` is the whole of pattern checking** — one function over
the `Pattern` datatype, answering the environment its captures bind and
the store in which the subject has the shape the pattern looks at. A
pattern is a **demand**:

```
   case 1:              unify(subject, Int)
   case 'x':            unify(subject, String)
   case (a, b):         unify(subject, (?1, ?2)), then recurse
   case [h] + t:        unify(subject, [?e]), then recurse on ?e
   case name:           binds; demands nothing
   case _:              demands nothing
```

`pattern_shape` is the one that raises where the demand cannot be met,
so every pattern's refusal reads the same way. A pattern is therefore
also how something still open is *settled* — and `check_target` applies
the same idea to a destructuring binding, which is what lets
`n, s = pair` say what `pair` is inside a body being worked out.

**`agree(a, b, store)`** is what two branches are held to: `unify`, plus
`None` on either side meaning "leaves the answer to the other". It is
used by `if`, the `if` expression, a `match`'s arms, a list literal's
elements, and a loop's ways out. The empty list is why it must unify
rather than compare: `[]` is `[?e]`, so a base case returning `[]` has
to settle against a branch returning `[Int]`.

**`covers` decides whether a `match` is total**, deliberately
syntactically: one irrefutable pattern, both of a Bool's values, or a set
of list patterns taking every length. That last rule is not a flourish —
it is how every recursion over a list is written (`case []` and
`case [x, ..rest]`), and without it the value form would demand a
redundant `case _` in the language's commonest idiom. Totality is
required only where a value is taken (`require_total`, from `SLetStmt`
and `SReturnStmt`), because a `match` that fits no arm does nothing and
there would be no value.

**`covers_column` reads the same rules one level in.** A tuple's shape
is fixed by its type, so a column matching anything in every pattern
rules no value out, and a set of tuple patterns covers as soon as *one*
column does: `(a, true)` beside `(a, false)` takes every `(Int, Bool)`
for the reason `true` and `false` take every `Bool`. Without it those
need a `case _` that can never run — worse than untidy, since
`target_ocaml.ml` compiles what this checker accepts and OCaml *can* see
the arm is unreachable, so it warns, and a warning about generated code
fails that target's tests.

One refutable column is the whole of the rule, and the limit is
deliberate: columns that only cover *together* — `(true, true)`,
`(true, false)`, `(false, _)` — are answered no. Saying no asks for an
arm that is not needed; saying yes without a decision procedure would
accept a `match` with a hole in it.
`tests/match_exhaustive_tuple.pyk` pins what is covered.

## One loop, and what it is worth

`for`, `while` and `loop` are one node, so there is one case for all
three. Four things it decides:

**The iteration clause** (`check_iteration`): a `for` walks a list —
`demand_list`, so a sequence still open is settled to one — and binds its
element over the body; a `while` demands `Bool`, asked where the
accumulator is in scope so it can ask about it.

**What the loop is worth**: the accumulator, and nothing else. However
a loop stops — a `break`, or a `for`/`while` running out of turns — the
answer is the same, so there is one type to work out rather than two to
reconcile. A loop with no accumulator is worth unit.

**What the body ends in is the next turn's accumulator**, so
`check_turn`'s answer is held to the accumulator's type (`carry_error`
is the refusal). A body all of whose paths jump supplies `None` and is
asked nothing: `break`, `continue` and `return` never reach the end of
the body, which is what lets a branch that breaks sit beside one that
ends in the next accumulator. A loop carrying nothing asks nothing of
its body at all.

**A `return` in the body is the enclosing function's**, so it is
checked and gathered exactly as one written outside the loop is —
`check_turn` hands the frame back as it came, which is what lets an
unannotated function's return type be decided by a `return` written
inside a loop (`tests/typecheck_infer_loop_return.pyk`).

**The accumulator needs no special case to widen.** `loop kept = []`
starts as `[?e]`, and a body ending in `kept + [x]` solves `?e` by
ordinary unification — the same rule as everywhere else.

## Naming what to write instead

A failing operator says what it accepts, and where the mistake has an
obvious cure, names it -- when, and only when, the cure would take these
operands (`alternative` in `src/typesystem.ml`):

```
'prog.pyk' 1:6-1:16 Type error: `+` cannot be applied to String and
  Int; it accepts Int + Int or Float + Float or String + String or two
  lists of one type. `+` joins two Strings and converts nothing: write
  string(n)
'prog.pyk' 1:6-1:18 Type error: `&` cannot be applied to Bool and Bool;
  it accepts Int & Int. On Bools, write 'and' (or '&&')
'prog.pyk' 1:6-1:12 Type error: `&&` cannot be applied to Int and Int;
  it accepts Bool && Bool. On Ints, write 'and' or '&'
```

`1 & 'a'` gets no suggestion, because nothing takes an Int and a
String. The language server turns each of these into a quick fix
(`src/lsp.ml`, `code_actions`).

## Operators: one type, then the table

**Every operator Pyking has takes two operands of one type.** So
`check_binary` unifies the operands with *each other* first, and only
then asks the table (`operator_of`, `binop_rows`) about that one type:

```
   left, right  ──► unify ──► common ──► operator_result
                                             │
        ┌────────────────────────────────────┴──────────────┐
        │ `+` on lists → [a] + [a] is [a]: `common` itself   │
        │ `+` on two   → left open, recorded in             │
        │   open operands  `pending_plus` (below)           │
        │ one row   → unify `common` with what it wants      │
        │ several rows, one result  → that result; nothing   │
        │             here has to decide which row (`==`)    │
        │ several results → the first row: `-` is Int,      │
        │             `and` is Bool                          │
        │ `common` concrete → the row it matches             │
        └───────────────────────────────────────────────────┘
```

Doing it the other way round — trying each signature against each
operand — would pick the first row a still-open operand happened to fit,
and pin two types that had said nothing to whichever row the table lists
first.

**A `+` whose operands nothing has decided waits.** It is worth what
its operands are on every one of its rows -- Int, Float, String or a
list -- so its type is left open and recorded in `store.pending_plus`,
and a later use decides it: `def join(a, b): a + b` called with two
Strings joins them, as the `++` Pyking used to have did. Two rules keep
that sound:

- **A definition does not generalise over such a type.**
  `infer_definition` adds every still-open `pending_plus` operand to the
  metavariables the definition may not generalise, so the definition is
  monomorphic in it -- a type variable would have to add and join at
  once, and no backend can compile that. Its first use decides it, as
  it does for a lambda.
- **`settle_plus` runs when the module is done**: an operand still open
  becomes an Int, the arithmetic default; one that became an Int, a
  Float, a String or a list stays; anything else -- `join(true, false)`
  -- is refused at the `+`.

`elaborate.ml` then turns a `+` the checker typed as a String or a list
into the `EConcat` node every backend compiles as a join, and `and`,
`or` and `not` typed as Ints into the bitwise nodes, keeping their
spelling for `-t pyking`.

## Comparing types: never `==`

Every `T*` constructor carries `info` (the source span) and `sym`, so
OCaml's structural `=` compares those too. Neither is part of what a type
means: two `Int`s written in different places would compare unequal
despite being the same type.

```
   same_type(a, b)              structural; blind to `info` and `sym`
   accepts(expected, actual)    same_type + a scheme used at an instance
   satisfies(expected, actual, store)
                                unify first, accepts behind it
   unify(one, other, store)     the store in which they are one type
```

Which to use is decided by whether anything may be *solved*:

| use | when |
|---|---|
| `same_type` | two types that are both settled, and nothing may change |
| `accepts` | a written annotation, or `verified`'s rigid re-check — decides nothing |
| `satisfies` | a declared type meeting a supplied one, where either may still be open |
| `unify` | everywhere a construct demands a type |
