# Tail calls, and the loops they become

`src/optimization.py` is a pass from the Pyking AST to the Pyking AST.
It finds calls in tail position and rewrites them into `loop`s, so that
a tail-recursive function runs in one frame instead of thousands. It
runs for every mode unless `--no-tail-call-opt` says otherwise, and
before anything reads the program — so `--ast` prints what it built, the
checker checks it, and every backend compiles it. Every backend but one:
OCaml eliminates tail calls itself, and gets the program as written (see
"The target that needs none of this").

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
one. The worker takes the group's annotations where they agree and none
where they do not.

Three things follow from doing it this way:

- **One copy of each body.** The alternative — giving every member its
  own copy of the merged loop — grows with the square of the group.
- **The wrappers stay functions**, so a program that passes `is_even`
  around, or calls it before it is written, is unaffected.
- **A group of one is not a group.** A function that only calls itself
  takes the simpler rewrite above; the state exists to say *which* body,
  and there is only one.

A group whose functions take different numbers of arguments is left
alone: there is no one accumulator for them to share. Their own
self-calls, if any, are still rewritten.

## The groups this cannot make work

Merging is decided on what the pass can see — how many arguments each
function takes — and one thing it cannot see is what type each argument
holds. The slots are shared, so the members have to agree about them,
and where they do not the checker refuses what the pass built:

```pyking
def ping(n: Int) -> String:
    if n == 0:
        "done"
    else:
        pong("x")           # ping's slot holds an Int here,


def pong(mark: String) -> String:
    if mark == "":
        "empty"
    else:
        ping(1)             # and a String here
```

Each function on its own is perfectly well typed — `ping` takes an Int,
`pong` takes a String, both give a String, and every call passes what it
should. It is the *merged* loop that cannot be: its one slot would have
to carry an Int one way round and a String the other.

```
'prog.pyk' 20:4-23:17 Type error: the branches of this 'if' have
  different types: (Int, Int) and (Int, String)
```

The error is reported against the program's own source, since the pass
moves statements rather than inventing them — but it is describing the
accumulator, which the program never mentions. That is the honest cost
of the rewrite, and `--no-tail-call-opt` is the answer:

```sh
pyk --no-tail-call-opt prog.pyk        # runs, at the price of the stack
```

`tests/fail_tco_group_parameters.pyk` and
`tests/fail_tco_group_mixed.pyk` pin both halves of this: each fails the
`typecheck` target with the message above, and passes `typecheck_notail`
with the program printed as written. The second shows that one
disagreeing member spoils the group it is in — `first` and `second`
agree perfectly, and `third` is what makes the loop impossible.

Two shapes that might look like the same problem are not:

- **Different arities** are visible to the pass, so such a group is
  never merged in the first place (`tests/typecheck_tco_unmerged.pyk`).
- **Different return types** cannot arise in a program that type-checks
  at all: if `ping` tail-calls `pong`, `pong`'s answer *is* `ping`'s, so
  a group that checks without the pass already agrees about that.

C and Java have one restriction of their own: they have no tuple, so a
merged loop's accumulator becomes one local per slot, and a loop that
would have to answer with *all* of them at once — a bare `break` in a
multi-slot loop — is refused there. The pass never writes one: every
exit it builds carries the value the function was returning.

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

Which targets these are is the *backends'* knowledge, not the driver's:
`target_ocaml.NATIVE_TAIL_CALLS` says so, and `src/pyk.py` assembles the
set the way it assembles `TARGETS` and `EXTENSIONS`. A backend for a
host with proper tail calls would set the same flag and need nothing
else. `tests/test_script.py` pins it from the other side: generated
OCaml containing a `tail_group` worker is a failure, since that is the
pass's fingerprint.

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

`src/pyk.py` calls `optimize` after `symbolize` and before the type
checker, unless this run is compiling for a target that does the job
itself (above):

```
parse -> analyze names -> symbolize -> optimize -> symbolize -> typecheck -> --ast / backend
```

`symbolize` runs again because the pass builds nodes, and it keeps the
symbols already handed out (see `docs/analyses.md`), so a moved
statement carries its own identity through. The checker therefore checks
the program that will actually run, `--ast` prints it, and `tmap` is
keyed to it — which is what the OCaml backend needs, since it reads
types back rather than inferring them.

`src/repl.py` applies the same pass to each entry, so a function written
at the prompt runs the way it would in a file. An entry is its own group
of `def`s, which is exactly the unit the pass wants.

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
without this: twenty thousand levels, both self-recursive and mutually
recursive. It lists no `python_notail`, because running it with the pass
off is precisely the crash the pass exists to prevent.

Several tests elsewhere in the suite are tail-recursive by nature and so
exercise this pass without being about it —
`tests/list_pattern_recursive.pyk`, `tests/recursion_mutual.pyk`,
`tests/typecheck_infer_mutual.pyk`. Their `.out` files were captured
before the pass existed and are unchanged, which is the strongest thing
said about it here.
