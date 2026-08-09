# Type inference

How Pyking gives a type to a function nobody annotated, why it is done
this way rather than the usual way, and what it costs. The rules a
program is judged by are in [../PYKING.md](../PYKING.md), "Type
checking"; this page is about the mechanism, the decisions behind it, and
the things it deliberately does not do.

## The idea in one paragraph

A function that wrote its type down is checked where it is written. A
function that did not is **not checked there at all** — it is put aside
with `TUnknown` where its type should be, and checked the first time
something *calls* it, with its parameters taken from that call. There is
no separate inference pass, no constraint store and no unification: the
same `check_stmt`/`check_expr` that check an annotated function check an
unannotated one, in the same way, just later and with the parameter types
supplied by a call site instead of by the source.

```pyking
def double(n):        # nothing is checked here
    n * 2

x = double(21)        # here: n is Int, so `n * 2` is Int, so double is (Int) -> Int
```

## Why not the usual way

Hindley–Milner-style inference solves a system of constraints and reports
a failure as a clash between two types that were unified — often far from
where either was written, and phrased in terms of the solver rather than
the program. That is the thing this design is trying to avoid. Deferring
instead of solving keeps every error a statement about *one* place:

```
'scale.pyk' 16:12-16:17 Type error: argument 1 has type String, but Int
  was expected
```

That message comes out of the ordinary argument check, at the call, with
the call's own span — the same message a fully annotated function would
have produced. Nothing about it needed inference-specific wording, which
is the point: **inference reuses the checking machinery rather than
adding a layer above it.**

The price is generality. This is not principal-type inference: a function
is checked once per shape of use rather than once for all uses, there are
no type variables, and a few programs a real inferencer would accept are
refused here (see "What this does not do").

## The pieces

Four additions to `src/typesystem.py` and `src/syntax.py` carry the whole
scheme.

| | |
|---|---|
| **`TUnknown`** | a type nothing has decided yet — an unannotated parameter or return type. Never the final answer for anything the checker finished, and not spellable in source. |
| **`TFunction.tmsym`** | the symbol of the `def` a function type came from, so what is worked out can be recorded against the *definition* rather than against one of its uses. |
| **`TFunction.definition`** | the `def` whose body is still to be checked. Its presence is what distinguishes "a function type" from "a function type that is still a promise", and its symbol is `tmsym`. |
| **`TOr`** | `Int \| String`: a value that is one of several types. Written by hand, and produced by the checker to summarise a function used at more than one type. |

Everything the deferral accumulates lives in one immutable value, the
**store**, threaded through the pass exactly as the environment is:

```python
Store(environments, instances, checking, frame)
```

- **`environments`** — `tmsym` → the environment that `def` was
  *written* in, which is where its body is checked from wherever it is
  called.
- **`instances`** — `tmsym` → one `Instance` per shape it has already
  been checked at: the parameters *as passed* (the cache key), the
  result, the same call with everything it established filled in (what a
  reader is shown), and the uses it went through.
- **`checking`** — the definitions whose bodies are being checked right
  now, which is how a recursive call is recognised as one.
- **`frame`** — what the innermost inference is gathering: the instances
  it has gone through, and what its `return`s have supplied.

A definition is named by `tmsym`, the symbol of its `def` — a value, so
two types built for one definition at different moments are the same
function without anything being asked about object identity.

**Nothing in the store is ever written to.** An inference gets it with a
fresh frame and its own definition marked as being checked; when the
inference ends, `learned(store, inner)` keeps the two tables — knowledge,
true whoever asked — and returns to the caller's frame and checking set
simply by using the caller's store again. That one line replaced a
`try/finally` restoring two mutable flags, and it is the only place the
difference between *what was found out* and *what was being done* has to
be stated.

## What happens at a call

`check_call` does one thing for both kinds of function, which is why
there is no second code path to keep in step:

1. Check the callee and the arguments, exactly as before.
2. For each parameter, ask `argument_type` what it is *for this call*:
   - the `def` wrote an annotation → the argument is checked against it
     and the annotation wins; a mismatch is the ordinary argument error;
   - the `def` wrote nothing (`TUnknown`) → the argument's own type is
     what the parameter is;
   - both sides are functions → whatever *both* of them know is compared
     (`check_compatible`), and the argument's type is what the body sees.
     That is what lets an unannotated function be passed to a function
     whose parameter type *is* written, and be worked out where it is
     finally called.
3. If the callee has no `definition`, the call is finished: its type is
   the declared result, as it always was.
4. Otherwise `infer_call` takes over: cache lookup, then check the body
   in the environment the store recorded for that definition, extended
   with the parameters, then record what came out.

The environment in step 4 is the reason the deferral does not break
Pyking's lexical scoping. A body checked at a call site is *not* checked
in the caller's scope:

```pyking
def f(n):
    n + offset        # error: `offset` is not in scope here ...

offset = 10
print(f(1))           # ... even though it is in scope here
```

## Recursion, and why there are two traces

A recursive call is the one call a first pass cannot type: what it
returns is exactly what the pass is working out. So the checker does not
try. `infer_call` raises `_Recursive` — a signal, not an error — and the
trace is abandoned at the first place that can carry on without it:

- the nearest enclosing **`if`** — the statement (`try_branch`) or the
  expression (`try_expr`) — whose other branch may well say what the
  function returns. A branch that was abandoned found out nothing, so it
  is asked for the store it began with; a branch that finished hands
  what it found out to its sibling, since only one of them runs but both
  are checked, and what either worked out about a function is true
  either way (`tests/typecheck_infer_branch_uses.pyk`);
- failing that, the **body itself**, if some `return` has already been
  seen (`trace`);
- failing that, the signal keeps going outwards, because in a cycle of
  three functions the branch that rescues it may be two calls away.

That first trace ends with a *candidate* result. A second trace then
checks the whole body again with the function's own name bound to
`(params) -> candidate`, so the recursive call now has a type and every
path — the recursive one included — is checked for real. **The second
trace is the one that counts.**

```pyking
def fact(n):
    if n < 1:
        1                     # trace 1 learns: Int
    else:
        n * fact(n - 1)       # trace 1 abandons this branch
                              # trace 2 checks it, with fact : (Int) -> Int
```

Both forms of `if` matter, and only one of them was there at first. A
recursive function written as a one-liner,

```pyking
def fact(n) = if n <= 1 then 1 else fact(n - 1) * n
```

has its recursion in a branch of an *expression*, and a version that
could only abandon a trace inside an `if` **statement** could not check
it at all — the signal escaped the body and came back as "cannot work
out what 'fact' returns" for a function that plainly returns an Int. The
two forms ask the same question and now get the same answer.

A function whose *return* type was annotated skips all of this: its own
name means `(params) -> declared` while its body is checked, so the
recursive call is an ordinary call and one pass is enough.

When nothing can rescue the signal, it becomes an error naming the
function and what would fix it:

```
Type error: cannot work out what 'forever' returns: every way through
  its body calls it again. Annotate its return type, or return a value
  on some path that does not recurse
```

## Caching, and what `tmap` ends up holding

Every inference is remembered in the store as an instance, so a function
called a hundred times with the same argument types is checked once. Without that, mutual recursion would not terminate and an ordinary
program would be checked exponentially.

`tmap` — the symbol → type table the whole pass produces — is written
through `record`, which **merges** rather than overwrites. A deferred
function checked at two argument types has two answers for everything
inside it, and both are true:

```pyking
def echo(x):
    x

number = echo(1)        # number : Int
word = echo('two')      # word   : String
```

Each binding keeps the exact type of its own call, and the function's
own type is the alternatives it was used at, each one whole:

```
same = echo        # same : ((Int) -> Int) | ((String) -> String)
```

A `def` with several types is printed *as it was written* by
`--typecheck --ast`, because the syntax of a `def` header has one slot
per parameter and no way to say which result goes with which — see
"The mistake that made this page necessary".

`record` also *resolves* a function type before storing it: a function
that had not been called yet was passed around as `(?) -> ?`, and what is
recorded should be what it turned out to be.

## Hard decisions

These are the places where more than one answer was defensible. Each one
is written down because the code alone does not show what was rejected.

### 1. Where the definition's environment comes from

A deferred body must be checked in the scope it was *written* in, not the
one it is called from. The environment therefore has to be stored, and
the natural place — inside the `TFunction` itself — cannot hold it: the
environment contains the function, so building one immutably would need
the other to exist first.

The answer is `store.environments`, written twice for the same
definition: `declare_functions` records the block-entry environment (so a
forward call has *some* correct-enough scope), and the `def` statement
records the environment at its own position over the top of it when the
block reaches it. Because the key is the definition's *symbol* rather
than an object, every type naming that definition sees the newer answer
without anything having been mutated under it.

**What was rejected, and then chosen anyway.** The first version put the
environment in a mutable record the types pointed at, on the grounds that
threading a table through every function of the pass would be machinery
in front of the rules. That was the wrong trade: a record reachable from
a type, changing under everyone holding it, is exactly the kind of thing
nobody can reason about by reading. The store is now threaded through
every function, and the price — one more parameter, one more result —
turned out to be worth paying.

### 2. `_Recursive` is an exception, not a machine state

Everywhere else this repository avoids control-flow-by-exception. Here it
is the right tool: the signal has to unwind an arbitrarily deep recursive
descent to the nearest enclosing `if`, and threading an "unresolved"
result through every return value would put the recursion case into
functions that have nothing to do with it. The signal never reaches a
user: `infer_call` turns it into a sentence, or re-raises it for the
inference that can.

**The subtlety that cost a rewrite:** the *first* version turned an
unresolvable trace into an error immediately, inside `trace`. That breaks
a cycle of three functions — `a → b → c → a`, where only `a` has the
branch that ends the recursion, so the signal must travel through `b` and
`c` untouched. The signal therefore carries the definition it is about,
and only the inference of *that* definition may convert it. It carries
the store as well, since an exception unwinds past every store its
callers were about to be handed, and a trace needs one thing out of an
abandoned attempt: what its `return`s had already supplied.

### 3. `TOr` instead of type variables

`echo` above is polymorphic, and a real inferencer would give it
`(a) -> a`. Pyking has no type variables, so what is recorded for a
function used at two types is the two types:

```
((Int) -> Int) | ((String) -> String)
```

Each alternative is one whole instantiation — its parameters and its
result, kept together. That is weaker than `(a) -> a` (it says nothing
about a use that has not happened yet) but it is *exactly* what the
checker enforces, which is the property that matters. See the section
below on the mistake that this replaced.

The alternatives are parenthesised because `->` reaches past `|` in
Pyking's type grammar: `(Int, Int) -> Int | (String, String) -> String`
would read as one function returning
`Int | ((String, String) -> String)`. Printing them parenthesised keeps
`--typecheck --ast` output re-parsable and keeps an error message
unambiguous however the reader groups it.

### 4. A mixed body yields an alternative type, not an error

```pyking
def maybe(n):
    if n > 0:
        return 1
    print('nothing')      # supplies unit
```

The `return`s and the tail position between them say this returns
`Int | ()`, and that is what it gets. The annotated checker *refuses* the
same shape (`-> Int` with a body that can fall off the end), so the two
differ here.

**Why:** an inference that refuses has to explain a rule the program
never stated, while an alternative type is a true statement about the
function, and the mistake — if it is one — then shows up where the value
is used, in terms of what it is. A written annotation is still enforced
strictly; nothing about inference loosens it.

### 5. Two `TUnknown`s are the same type — and what that broke

`same_type(TUnknown, TUnknown)` is true, because an incomplete function
type has to equal itself for the instance cache to find it. That makes
two *different* unannotated functions compare equal, since both are
`(?) -> ?`:

```pyking
def chooser(loud):
    if loud:
        shout
    else:
        whisper       # same type as `shout`, as far as anything knows
```

Taking one to stand for both would mean checking `shout`'s body every
time the value `whisper` returned is called — silently checking the wrong
function. Rather than leave that hole open, `check_not_conflated` refuses
the `if` and says why. The program is legal Pyking and runs correctly
under every backend; only the *checker* declines it, and an annotation on
either function fixes it.

### 6. An uncalled function gets no type at all

Nothing is inferred for a function nobody calls — there is nothing to
infer it from. `--typecheck --ast` prints it exactly as written, with no
annotations. That is honest, and it is also why the `typecheck_infer_*`
tests all call what they define.

The same is true, more subtly, of a cycle of three or more: while the
cycle is being resolved every trace through the middle of it is
abandoned, so only the function the cycle closes on ends up recorded —
until something outside the cycle calls one of the others (see
`tests/typecheck_infer_mutual.pyk`, which shows both).

### 7. `?` in printed output does not round-trip

`--typecheck --ast` output is otherwise re-parsable Pyking, and `|` was
added to the type grammar partly to keep it that way. `?` is the one
exception: it is printed for a `TUnknown` — a function passed somewhere
and never called — and there is deliberately no syntax for it, because
there is nothing a program could mean by writing one.

### 8. The mistake that made this page necessary

The first version of this collapsed two function types **component-wise**
instead of keeping them side by side. A function called with two Ints and
then with two Strings was recorded as

```
(Int | String, Int | String) -> Int | String        # wrong
```

on the reasoning that this was "a summary of how the definition was
used", and the loss of correlation was written up right here as an
acceptable price. It was not acceptable, for a reason the write-up
missed: **the summary claimed something the checker refuses.** That type
says an Int and a String may be mixed in one call, and

```pyking
def combine(x, y) = x + y

print(combine(1, 3))
print(combine('hi', 'now'))
print(combine(12, 'hi'))      # Type error: `+` cannot be applied to
                              #             Int and String
```

is exactly the call it licenses and the checker rejects. A reported type
that disagrees with the checker is worse than no reported type at all —
in a REPL it is the *only* thing the user has to go on, and it was
telling them their program was fine when it was not.

Three specific errors, worth separating because they have different
lessons:

1. **Merging destroyed information that had already been computed.** The
   two instantiations were sitting in the store, correlated and correct;
   `merge` threw the correlation away at the last moment,
   to produce something that fitted in one `TFunction`. The fix is to
   stop doing that: `merge` keeps function types as alternatives like
   everything else.
2. **I let the *printer's* convenience decide the *type*.** The collapse
   existed because `pprint_program` prints a `def` header with one slot
   per parameter and one for the result, and a `TOr` does not fit that
   shape. That is a fact about the syntax, not about the function. Now a
   function with several types is printed *as it was written*, and its
   type is read where the function is used — `same = echo` prints
   `((Int) -> Int) | ((String) -> String)`, and so does `:ls` in the
   REPL.
3. **I documented the trade-off instead of testing it.** The old text
   said the collapse "loses the correlation … which is the price of
   having no type variables" — plausible-sounding, and it went unchecked
   because no test compared a *reported* type against a call the checker
   would refuse. `tests/typecheck_infer_overload.pyk` and
   `tests/fail_typecheck_infer_mixed.pyk` are that test, as a pair: one
   pins the type, the other pins the refusal of the call that type must
   not license.

The rule that came out of it: **a type this checker reports must be one
it would enforce.** If a type cannot be written down in the syntax
available, print less, never print something stronger.

### 9. Two functions nobody has worked out yet are not the same argument

The instance cache is keyed on what a call passed, and the first version
compared those with `same_type`. That is the right relation for checking
a program and the wrong one for a cache, and the difference is invisible
until two *deferred* functions are passed to the same function:

```pyking
def id(x) = x
def extract(packed) = packed(id)
def pack_int(k) = k(41)
def pack_string(k) = k('hello')

print(extract(pack_int))       # 41     : Int
print(extract(pack_string))    # 'hello' : Int   ← reported wrongly
```

`pack_int` and `pack_string` are both `(?) -> ?` — nothing has decided
either — so `same_type` calls them equal, the cache hit, and the answer
worked out for the *first* call came back for the second. The value was
right (the interpreter does not consult types), the reported type was
not, and because nothing was re-checked, nothing new was recorded: the
`|` types the user expected never appeared.

`recall` now compares with **`same_instance`**: `same_type`, except that
a function still to be worked out is only ever the same as itself, which
is decided by the symbol of the `def` it came from. A `TUnknown` is the
*absence* of an answer, and
two absences are not a shared answer.

This is the third bug in the same family. `TUnknown == TUnknown` is
needed for a type to equal itself; everywhere it meets two *different*
deferred functions it has to be corrected — refused outright in an `if`
(§5), and here distinguished by identity.

### 10. What a call reports about a function it was given

Fixing the cache exposed a second, quieter version of the same mistake,
and then a third. An instance is recorded as `(params, result)`, and what
a reader is shown for the function is built from those — so if `params`
holds a deferred function type, showing it means resolving that
function, which meant merging *every* use of it anywhere:

```
pack_string : (((Int) -> Int) | ((String) -> String)) -> String   # wrong
```

`pack_string` applies its argument to `'hello'`; it does not accept an
`(Int) -> Int`. The type over-claimed, this time by mixing in what a
*different* call had taught about `id`.

The first attempt at narrowing was to report what a call *learned*: the
instances of an argument that appeared while its body was being checked.
That is wrong in the other direction, and the case that shows it is
plain:

```pyking
def identity(x) = x

def use(f):
    a = f(42)          # an instance that already existed
    b = f(true)        # a new one
    print(a, b)

first = identity(1)    # ← makes (Int) -> Int known before `use` is checked
use(identity)          # use : ((Bool) -> Bool) -> ()      ← under-claiming
```

`use` went through *both* shapes of `identity`; only one of them was new.
Counting what appeared cannot see the other, because a cache hit creates
nothing.

So the pass records **uses**, not creations. Each inference gets a frame
in the store, and every `infer_call` notes the instance it went through,
whether it worked it out or found it already worked out. A call that
*reuses* a remembered answer also inherits what that answer was based on,
so the narrowing is transitive through a chain of calls. `use` is then
`(((Int) -> Int) | ((Bool) -> Bool)) -> ()`, `pack_string` is still
`((String) -> String) -> String`, and each says exactly what its own
body did.

The one thing left un-narrowed is an argument a body never calls: it
taught that call nothing, so everything known about it is reported. `?`
would be the alternative, and it would say less than is known rather
than more.

### 11. A backend bug the tests found

`str(true)` printed `True` under the Python backend and `true` everywhere
else. `src/runtime_interface.py` pins Pyking's spelling for booleans, and
`src/interpreter.py` is the reference, so the backend was wrong: it now
wraps a `str` argument the same way it already wrapped a printed one.
Worth recording because it is the pattern to expect — a test written for
one part of the compiler catching a disagreement in another.

## Where the code is

| what | where |
|---|---|
| the types | `TUnknown`, `TOr`, `TFunction.tmsym`/`.definition` in `src/syntax.py` |
| `\|` in the grammar | `TokPipe` in `src/lexer.py`, `parse_type`/`parse_type_atom` in `src/parser.py` |
| deferring a definition | `declared_type`, `declare_functions`, the `SFunctionDef` case of `check_stmt` |
| checking at the call | `check_call`, `argument_type`, `check_compatible`, `infer_call` |
| the two traces | `infer_body`, `trace`, `try_branch`, `_Recursive` |
| alternatives | `merge`, `accepts`, `every`, `resolved` |
| the store | `Store`, `Instance`, `Use`, `Frame`, and the functions that build a new one: `with_environment`, `remembering`, `checking_now`, `noting`, `returning`, `learned` |
| the cache and the table | `instances_of`, `recall`, `record` |

## Testing it

Eight `tests/typecheck_infer_*.pyk` programs pin what is inferred — each
has an `.ast.out` holding the printed AST with the inferred types, and an
`.out` holding what the program prints, checked on every backend that
accepts it. Three `tests/fail_typecheck_infer_*.pyk` pin what is refused
and how it is worded.

The most valuable of these is the plainest: because the `interpret`
target runs each of them and compares against the same `.out` as the
compiling targets, a type the checker infers is also a program that
demonstrably runs and means the same thing everywhere.
