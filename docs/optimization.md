# Tail calls, and the loops they become

`src/optimization.py` is a pass from the Pyking AST to the Pyking AST.
It finds calls in tail position and rewrites them into `loop`s, so that
a tail-recursive function runs in one frame instead of thousands. It
runs for every mode unless `--no-tail-call-opt` says otherwise, on
**programs the type checker accepts** — the types are what make the
rewrite decidable, and the gate is one rule rather than a list of
exceptions. Everything else is compiled as written, and so is the
`ocaml` target, whose host eliminates tail calls itself (see "The target
that needs none of this").

This page is the design. What the guarantee *means* is in PYKING.md
("Tail calls"); what the pass produces is pinned by the
`typecheck_tco_*` tests, each of which has its `.ast.out` (the program
after the pass) beside its `.notail.ast.out` (the program as written).

## Why an AST pass and not nine backends

A tail call is a jump. Every target here can express a jump — Python and
JavaScript have `while`, C and Java have `while`, OCaml has tail
calls of its own — but each would need its own analysis, its own notion
of tail position, and its own bugs. Pyking already has a construct that
*is* a jump with an accumulator, so the whole thing is one rewrite in
the language itself:

```pyking                        # what the pass builds
def climb(x):                   def climb(x):
    if x >= 20000:                  loop x = x:
        1000 + x                        if x >= 20000:
    else:                                   break 1000 + x
        climb(x + 1)                    else:
                                            x + 1
```

Eight backends benefit without knowing this pass exists, the interpreter
included, and the ninth — OCaml — already had what they are being given. And because the output is ordinary Pyking, it can be read:
`--ast` shows it, and any mistake in it is a mistake in a program a
person can look at.

## What counts as a tail call

Tail position is PYKING.md's own, and the pass walks exactly it:

- the **last statement** of a body, recursively through the branches of
  an `if` and the arms of a `match`;
- the operand of **every `return`**, wherever it is written — a `return`
  leaves the function, so nothing is waiting for its value either;
- the branches of an **`if` expression** in one of those positions, so
  `def f(x) = if c then 0 else f(x - 1)` counts;
- a **`def ... = expr`** body, which is one `return` spelled shorter.

The walk stops in three places, each for a reason:

- **at a nested `def`** — a tail call written there is *that* function's
  tail call, not this one's;
- **at a `for`, a `while` or a `loop`** — the rewrite says "go round
  again" with `continue` and "stop" with `break`, and inside one of
  those a `break` would belong to it instead. A `return` written there
  stays a `return`;
- **at anything still waiting for the answer**. `n * factorial(n - 1)`
  is not a tail call, and a function whose only recursion looks like
  that is left exactly as written.

## Why it runs after the checker

Two of the pass's decisions are questions about types, and nothing else
in the compiler can answer them.

**A slot has to be entered with something.** A group merged into one
loop is as wide as its widest member, so a narrower one enters with a
value for the slots it does not have. Inside the loop that costs
nothing — a call carries the slots it does not fill *forward*, keeping
whatever they held — but the entry wrapper has nothing to carry:

```pyking
def ping(n) = tail_group1(0, n, ???)     # `pong`'s `step` slot
```

The value is never *read*: the state it belongs to has no such
parameter. All that is asked of it is that the slot can hold it, which
is exactly what a type is. So the pass writes a zero of the slot's
type — `0`, `''`, `false`, `()`, `[]`, a tuple of those — and where the
type has none (a function, or an alternative), declines the group.

**A group has to agree about its slots.** Merging `ping(n: Int)` with
`pong(mark: String)` would give the shared slot two types, and only the
checker knows that. Reading it from the `tmap` is the difference between
declining such a group and emitting one the checker then refuses, with
an error about an accumulator nobody wrote.

### Why one check is enough

The checker runs once, before the pass, and never again — the rewritten
program is not re-checked, because it cannot fail. The argument, per
piece:

- **Self-recursion.** The accumulator's type is the parameter tuple's. A
  tail call `f(a1..an)` type-checked in the original, so `(a1..an)` has
  exactly that type, which is what the body must produce. Every other
  tail becomes `break e`, and `e` was the function's value on that path,
  so the loop is worth the function's return type. A tail `if` with no
  `else` gains `else: break ()`, and in a program that checks, such an
  `if` already means the function returns unit.
- **Merging.** Each slot's type is the one its members share (the gate);
  a branch's `param = slot` rebinding is that type; a tail call to
  member *j* puts member *j*'s argument types into those slots; a padded
  slot gets its own current value or a zero of its type; and every
  `break` gives the group's shared return type.
- **The worker is emitted fully annotated**, from the `tmap`, even for a
  group nobody annotated. That is what makes the argument *local*: the
  worker would be checked where it is written, by the ordinary annotated
  path, rather than inferred at its call sites and reasoned about.

The one direction the pass can move a program is *toward* checking:
turning a recursion into a loop removes recursion that inference cannot
see past. It cannot move one the other way.

## One function that calls itself

The parameters become the accumulator, under **their own names** — the
loop's header reads `loop x = x:`, binding a fresh `x` each turn from
what the last turn produced. Nothing in the body is renamed, and nothing
is redirected through a synthetic variable: the code inside the loop is
the code the programmer wrote.

Inside, each tail position becomes what the loop needs:

| tail position | becomes |
|---|---|
| a call to the function itself | the next accumulator — its arguments, as the body's last expression |
| the same, but reached through a `return` before the end | `continue` with those arguments |
| any other expression, or `return e` | `break e` |
| an `if` / `match` | the same statement, with every branch rewritten |
| an `if` with no `else` | an `else` that `break`s with `()` — the path that ran no branch is the one the function returned nothing from |
| a `loop` of the program's own | bound to a name, then broken with |
| anything else (`=`, `var`, `for`, `while`) | kept, then `break ()` |

A `match` in tail position is the one place every arm has to *jump*
rather than fall out of the match: a subject matching no arm falls out
of the function as unit, so a `break ()` follows the match, and an arm
that merely ended in the next accumulator would reach it.

The pass declines a function whose parameters are not distinct names it
leaves alone — one that rebinds its own parameter, or its own name, in
its body. The loop carries those names, and a rewrite has to mean the
same thing as what it replaced.

## A group that calls each other

Two functions that call each other in tail position are a loop as much
as one that calls itself, but neither can hold it alone. The pass finds
the group — the functions that tail-call their way round to each other —
and gives them **one loop between them**, carrying a `state` that says
whose body is running. Each original becomes a one-line wrapper that
starts the worker in its own state:

```pyking                        # what the pass builds
def is_even(n):                 def tail_group1(state, n):
    if n == 0:                      loop state, n = state, n:
        true                            if state == 0:
    else:                                   if n == 0:
        is_odd(n - 1)                           break true
                                            else:
def is_odd(n):                                  1, n - 1
    if n == 0:                          else if n == 0:
        false                               break false
    else:                               else:
        is_even(n - 1)                      0, n - 1

                                def is_even(n) = tail_group1(0, n)
                                def is_odd(n) = tail_group1(1, n)
```

The worker is `tail_group1`, `tail_group2`, … and the state is `state`,
each bumped (`tail_group2`, `state2`) only if the program already uses
that name. The slots keep the group's own parameter names, so no body is
rewritten; a member whose parameter is called something else at that
position gets one binding for it and nothing more, and a name that would
mean something else inside another member's body falls back to a fresh
one. The worker is annotated from the `tmap`, whether or not the group
was.

Three things follow from doing it this way:

- **One copy of each body.** The alternative — giving every member its
  own copy of the merged loop — grows with the square of the group.
- **The wrappers stay functions**, so a program that passes `is_even`
  around, or calls it before it is written, is unaffected.
- **A group of one is not a group.** A function that only calls itself
  takes the simpler rewrite above; the state exists to say *which* body,
  and there is only one.

### Members of different widths

A group need not agree about how many arguments it takes. The
accumulator is as wide as the **widest** member, and a narrower one
simply leaves the last slots alone:

```pyking                        # what the pass builds
def ping(n):                    def tail_group1(state, n, step):
    if n == 0:                      loop state, n, step = state, n, step:
        0                               if state == 0:
    else:                                   if n == 0:
        pong(n - 1, 2)                          break 0
                                            else:
def pong(n, step):                              1, n - 1, 2
    if n == 0:                          else if n == 0:
        1                                   break 1
    else:                               else:
        ping(n - step)                      0, n - step, step

                                def ping(n) = tail_group1(0, n, 0)
                                def pong(n, step) = tail_group1(1, n, step)
```

Two places had to say something about the slot `ping` has no parameter
for, and they say different things for the same reason — what is *in
scope* there:

- **Inside the loop**, `step` is a slot the turn is already carrying, so
  the call to `ping` carries it forward: `0, n - step, step`. Nothing is
  invented, and the value stays whatever the last `pong` put there.
- **At the wrapper**, nothing has run and there is nothing to carry, so
  the pass writes a zero of the slot's type — the `0` in
  `tail_group1(0, n, 0)`. It is never read: state 0 is `ping`, and
  `ping` has no third parameter.

Slots are matched **by position**: slot *i* is parameter *i* of every
member that has one, and takes its name from the first member that does.
Two functions that agree in arity but not in order — `f(count, name)`
beside `g(name, count)` — are therefore a group whose slots disagree,
and are declined rather than quietly rearranged.

## The groups this declines

Merging asks four things of the checker's types, and a group that fails
any of them is left as the recursion it was written as. All four are
`_shared` in `src/optimization.py`:

1. **The members agree per position.** Every function that has slot *i*
   must put the same type in it. `ping(n: Int)` beside
   `pong(mark: String)` does not.
2. **A padded slot has a zero to write.** `Int`, `String`, `Bool`, `()`,
   a tuple of those and a list all have one; a function type does not,
   and neither does an alternative — there is no one value that is both
   an `Int` and a `String`.
3. **They agree about what they answer with.** In a program that checks
   this is already true — if `ping` tail-calls `pong`, `pong`'s answer
   *is* `ping`'s — so it is a condition that costs nothing and states
   the assumption out loud.
4. **Each member has one definite type.** A function nothing calls has
   none, and one checked at several argument shapes has several; neither
   gives a shared loop a single answer.

Declining is invisible: the program compiles and runs exactly as
written, one frame per call, and `--ast` shows it unchanged. That is the
whole difference from how this used to work, when a group was merged on
arity alone and the checker refused the result with a message about an
accumulator nobody had written.

`tests/typecheck_tco_declined.pyk` holds two of these — a group whose
slot would need two types, and one whose padded slot is a function —
and `tests/typecheck_tco_declined_group.pyk` shows that one disagreeing
member is enough: `first` and `second` agree perfectly, and `third` is
what keeps all three as recursion. Their `.ast.out` and
`.notail.ast.out` are the same program twice over, which is exactly what
being declined means.

## The target that needs none of this

OCaml eliminates tail calls itself, so the `ocaml` target is compiled
from the program **as written** — the pass is skipped for it entirely.

That is not a nicety. This backend compiles a `loop` into a local
recursive function (docs/target_ocaml.md, "loop"), so running the pass
first would have the two modules taking turns translating one program
into the other's shape, and undoing each other:

```ocaml
(* what the pass and this backend produce between them *)
let f1 x =
  let rec _pyk1 x = if x >= 20000 then 1000 + x else _pyk1 (x + 1) in
  _pyk1 x

(* what the program said, which is what the target now emits *)
let rec f1 x = if x >= 20000 then 1000 + x else f1 (x + 1)
```

The second is what a person would write, and `ocamlopt` turns its tail
call into a jump either way. The mutual case is where the round trip
really shows: two mutually recursive functions became a `tail_group1`
worker with a `state` tag and a tuple accumulator, in a language whose
answer to mutual recursion is `let rec … and …`.

```ocaml
let rec is_even n = if n = 0 then true else is_odd (n - 1)
and is_odd n = if n = 0 then false else is_even (n - 1)
```

Five million levels deep, self-recursive and mutually recursive alike,
in constant space — which is the same guarantee the pass gives
everywhere else, obtained by not getting in the way.

Which targets these are is one list in `src/pyk.py`,
`NATIVE_TAIL_CALLS = ("ocaml",)`, read by `compiling_natively`. A
backend for another host with proper tail calls adds its name to it and
needs nothing else. `tests/test_script.py` pins the arrangement from the
other side: generated OCaml containing a `tail_group` worker is a
failure, since that is the pass's fingerprint.

Three consequences worth stating plainly:

- **`--ast` is unaffected.** It ignores `--target` (it prints the
  Pyking AST every backend shares), so it must not depend on one
  either: `pyk compile -t ocaml --ast` prints the optimized AST, and
  only an actual compile takes the other path.
- **The `ocaml` target checks the program as written.** Its subset is
  whatever `src/typesystem.py` accepts, and what it hands the checker is
  now the original — so a `fail_tco_*` program compiles here perfectly
  well, and, in the other direction, a program that only checks *after*
  the pass would not.
- **`--no-tail-call-opt` changes nothing for this target**, which is the
  right answer to "what does turning the pass off do to OCaml": nothing,
  because it was never on.

## Where it runs

`src/pyk.py` owns the order, and every stage is called there:

```
lex -> parse -> names -> symbolize -> typecheck -> optimize -> symbolize -> --ast / backend
                          (skipped under --typecheck, where the checker checks names too)
```

Three things about that line are load-bearing:

- **The checker runs for every mode**, not only under `--typecheck`.
  Its answer decides whether the pass may run; whether a *failure* is
  reported is a separate question, and one only `--typecheck`, `pyk run`
  and the `ocaml` target answer yes to. A program outside the checker's
  fragment compiles exactly as it always did, unoptimized and unbothered.
- **`optimize` hands back an extended `tmap`.** The checker will not run
  again, so the pass records what it built — the loop's accumulator, the
  worker's parameters and its type — keyed by symbols it allocates past
  the highest already in use. Without that, `--typecheck --ast` would
  print the rewritten program with those annotations missing.
- **`symbolize` runs again** for everything else the pass built, keeping
  the symbols already handed out (see `docs/analyses.md`), so a moved
  statement carries its own identity through.

`src/repl.py` does the same per entry, in the same order: an entry is
checked, then optimized, so a function written at the prompt runs the
way it would in a file. It checks the entry a second time afterwards —
not to verify the rewrite, which needs none, but because a merged group
is a different number of statements and the prompt prints a type per
statement it runs.

One thing follows from types-first that is worth knowing at a prompt: an
*unannotated* function is only given a type when something calls it, so
a `def` entered on its own has none yet and is left as written. Writing
the annotations, or calling it in the same entry, is what lets the pass
see it. In a file this never comes up — the call is somewhere in the
program.

## What the tests hold

Each `typecheck_tco_*` program is checked four ways, which is what makes
the pass safe to leave on:

| file | what it pins |
|---|---|
| `.ast.out` | the program after the pass, with the types the checker gave it |
| `.notail.ast.out` | the program as written |
| `.out` | what it prints |
| `.notail.out` | what it prints with the pass off — **the same file's contents** |

That last pair is the whole safety argument: the pass may change how
much room a program needs, never what it prints. `tests/test_script.py`
compares the two files directly as well as running both.

`tests/typecheck_tco_deep.pyk` is the one that would not run at all
without this: twenty thousand levels, self-recursive, mutually
recursive, and through a group of two different widths. It lists no
`python_notail`, because running it with the pass off is precisely the
crash the pass exists to prevent.

Several tests elsewhere in the suite are tail-recursive by nature and so
exercise this pass without being about it — `tests/recursion_mutual.pyk`,
`tests/typecheck_infer_mutual.pyk`, `tests/typecheck_recursion.pyk`.
Their `.out` files were captured before the pass existed and are
unchanged, which is the strongest thing said about it here.

Programs outside the checker's fragment are the other side of the same
coin: `tests/list_pattern_recursive.pyk` is tail-recursive and uses
`match`, so it is compiled as written and recurses, exactly as it did
before any of this existed. Its `.out` is unchanged too.
