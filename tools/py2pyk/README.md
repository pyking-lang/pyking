# py2pyk

A standalone tool that translates a subset of Python source into
[Pyking](../../PYKING.md) source. It is independent of the rest of this
repository's compiler (`boot/`): it does not import from it, and nothing
outside `tools/py2pyk/` depends on it either. The only place the two
touch is the test harness, which uses `boot/pykboot.py` as a black box to
check that what py2pyk produces is valid, working Pyking.

## Summary

```
python3 py2pyk.py foo.py            # writes foo.pyk
python3 py2pyk.py foo.py -o out.pyk # writes out.pyk instead
python3 py2pyk.py foo.py --stdout   # prints the translation, writes nothing
```

Python is parsed with the standard library's own `ast` module -- there is
no reason to hand-write a second Python parser for this. Everything from
there on (deciding what Pyking can express, and printing Pyking's own
syntax) is py2pyk's own code, in `py2pyk.py`.

Pyking is a considerably smaller language than Python (see [the feature
summary in PYKING.md](../../PYKING.md#feature-summary)): no classes, no
exceptions, no `import`, no dict/set, no indexing, no attribute access, no
`and`/`or`/`not`, no `%`/`//`/`**`, no `break`/`continue`. py2pyk
translates the subset that *is* expressible, and refuses everything else
with a specific, explained error rather than emitting something that
looks plausible but means something else, or that pykboot itself will
choke on. **When py2pyk accepts a program, the translation is meant to be
behaviourally exact** -- same output for the same input, always -- not an
approximation. That is also what the test suite (`make test`) checks: it
doesn't compare source text, it runs the original `.py` and the
round-tripped Pyking-compiled-back-to-`.py` and diffs their stdout.

The two hardest parts of the whole translation, and the ones worth
understanding before reading the source, are:

- **Variable classification** -- Python's `if`/`for`/`while` don't
  introduce scopes; Pyking's do. Deciding when a reassigned name needs
  Pyking's `var`/`:=` instead of a plain `=`, and when Pyking's
  value-form `if` can express a conditional assignment without a `var`
  at all, is the one genuinely nontrivial piece of this tool. See
  ["Variable classification"](#variable-classification-var-vs--vs-value-form-if)
  below.
- **What plainly has no Pyking equivalent** -- indexing, attribute
  access, dict/set, exceptions, `and`/`or`/`not`, and several others are
  not corners py2pyk hasn't gotten to yet; Pyking's grammar has no way to
  express them at all. These are permanent limitations, not a roadmap.

## Usage

```
python3 py2pyk.py <input.py> [-o OUTPUT.pyk] [--stdout]
```

- With no `-o`/`--stdout`, the output is `<input>` with its suffix
  changed to `.pyk`, written next to the input file (`foo.py` -> `foo.pyk`).
- `-o PATH` writes to `PATH` instead.
- `--stdout` prints the translation instead of writing a file (and skips
  writing one even if `-o` is also given).
- On any unsupported construct, or on a Python syntax error, py2pyk
  prints one message to stderr naming the exact line/column and the
  reason, and exits with status 1. It never writes a partial or best-guess
  output file.

## Testing

```
make test
```

runs `test_script.py`, which for every `tests/*.py` file:

1. translates it with `py2pyk.py`;
2. compiles the result back to Python with `boot/pykboot.py` -- this
   step is also, as a side effect, the check that py2pyk produced *valid*
   Pyking, since an invalid translation fails here with pykboot's own
   error;
3. runs the original `.py` and the round-tripped `.py`, and compares
   their stdout.

It prints one `<file>: OK.` or `<file>: FAIL.` line per test (with a
reason on failure) and a final `N/M passed` summary. `tests/` currently
holds 30 programs, all of which pass; see the next section for what each
demonstrates.

## What's in `tests/`

Every file is ordinary, directly-runnable Python (`python3 tests/foo.py`
works with no py2pyk involved) chosen to exercise one construct or
translation strategy clearly:

| File | Demonstrates |
|---|---|
| `arithmetic.py` | `+ - * /`, parentheses, precedence |
| `comparisons.py` | `< <= > >= ==` |
| `unary_minus.py` | unary `-`, double negation, precedence vs. `*`/`+` |
| `strings.py` | string literals, escapes, `+` concatenation, `str()` |
| `tuples.py` | tuple literals: unit, singleton, bare, nested |
| `tuple_destructuring.py` | `=`-destructuring, incl. nested and singleton |
| `variables_rebinding.py` | plain rebinding, parameter shadowing an outer name |
| `functions_basic.py` | `def ... :` block-body functions |
| `functions_expr_body.py` | auto-collapsed `def name(...) = expr` bodies |
| `type_annotations.py` | `int`/`str`/`bool`/`list[int]` annotations |
| `if_then_else_expr.py` | Python's `a if c else b` -> `if c then a else b` |
| `else_if_ladder.py` | `elif` chain -> `else if` |
| `recursion_factorial.py`, `recursion_fibonacci.py`, `recursion_gcd.py` | self-recursion |
| `nested_functions_closure.py` | a `def` nested in a `def`, closing over a parameter |
| `for_loop_range.py` | `for x in range(...)`, incl. start/stop/step |
| `for_loop_list.py` | `for x in <list>` |
| `for_tuple_destructure.py` | `for a, b in pairs:` desugared (see below) |
| `while_loop.py` | `while` |
| `accumulator_var.py` | `+=`/`*=` promoted to `var`/`:=` |
| `accumulator_nested_if.py` | `var` promoted across a `for`+`if` boundary |
| `max_of_list.py` | two names promoted to `var` together across an `if`/`elif` with no `else` |
| `sum_of_squares.py`, `power_by_loop.py` | small numeric algorithms without `%`/`**` |
| `conditional_assignment_valueif.py` | `if`/`elif`/`else` all assigning one name -> value-form `if` |
| `conditional_assignment_tuple.py` | same, but the assigned name is a tuple destructuring |
| `boolean_flags_and_helpers.py` | `True`/`False` literals, a boolean-returning helper built from `if`/`elif`/`else` (no `and`/`or`) |
| `list_comprehensions.py` | filter, multiple `for`s, nesting |
| `list_comprehension_pattern.py` | a tuple pattern (`(_, label)`) as a comprehension target |

Deliberately *not* in `tests/`: anything relying on a feature listed
under ["Not supported"](#not-supported-and-why) below -- indexing,
`%`/`//`/`**`, `and`/`or`/`not`, dict/set, mutual recursion, forward
references, `match`, and so on. A few of those are shown inline in this
README instead, as the error py2pyk gives for them.

## The translation, feature by feature

### Literals, operators, calls

Int and string literals, `+ - * /`, unary `-`, `< <= > >= ==`, function
calls, list literals, tuple literals, and `if c then a else b` (from
Python's `a if c else b`) all translate directly -- Pyking's precedence
for these matches Python's exactly, so py2pyk reuses Python's own parse
tree shape and only adds parentheses where Pyking's grammar would
otherwise misparse (e.g. an `if`-expression is always
self-parenthesized, since PYKING.md documents at least one position --
inside a comprehension's own `if` -- where that is mandatory, and it's
harmless everywhere else).

Only four call targets are ever bound in a fresh Pyking program:
`print`, `range`, `str`, `len` (see `BUILTINS` in `boot/analyses.py`).
Any other call must be to a function defined earlier in the same file;
`int()`, `abs()`, `sum()`, `min()`, `max()`, `sorted()`, `enumerate()`,
`zip()`, `input()`, `list()`, `dict()`, `isinstance()`, ... have no
Pyking binding at all and are rejected as calls to an unknown name.
Keyword arguments and `*args` unpacking in a call are rejected too --
Pyking's call syntax is positional-only.

### `True`/`False`

Pyking's grammar has no boolean literal at all -- `Bool` is a reserved
*type* name, but there is no `true`/`false`-style token that produces
one. The *only* way to produce a `Bool` value in Pyking is a comparison. Since
every backend agrees a comparison's result prints as `True`/`False`
(see `boot/runtime_interface.py`), py2pyk translates the Python literals
that way:

```python
found = False          # ->  found = (1 == 2)
done = True             # ->  done = (1 == 1)
```

This is a translation trick, not a Pyking language feature -- don't take
`(1 == 1)` as idiomatic Pyking to write by hand; it's just the only
expression that is guaranteed to evaluate to a `Bool` with the value the
source asked for.

### Variable classification: `var` vs `=` vs value-form `if`

This is the one place Python and Pyking genuinely disagree about what
code *means*, not just how it's spelled. Python scopes at function
boundaries only: a name assigned inside an `if`/`for`/`while` body stays
visible for the rest of the function. Pyking scopes at every block: a
name assigned inside one of those bodies is gone the moment the block
ends (see ["Names and scoping"](../../PYKING.md#names-and-scoping)).
Naively translating every Python `=` to a Pyking `=` would silently
change the meaning of most real Python code the moment a variable is
touched inside a loop or a branch.

py2pyk resolves this with a classification pass (`classify_function` in
`py2pyk.py`) that runs once per Python function (and once for the module
top level) before any code is emitted. For every name that's ever
assigned in that function, it looks at every place the name is *read* or
*(re)assigned*, and finds the lowest block those places have in common
(their "LCA", lowest common ancestor, in the tree of `if`/`for`/`while`
bodies). Three outcomes:

1. **Every assignment to the name happens at that common block's own
   level** (no assignment is nested inside a child `if`/`for`/`while` of
   it) -- a plain, repeated Pyking `=` is enough; nothing crosses a scope
   boundary. This is `variables_rebinding.py` and most of `arithmetic.py`.

2. **Some assignment happens directly at that level, and at least one
   other assignment (or an `x += ...`) happens nested inside a child
   block of it** -- the *first* such direct-level assignment becomes
   `var name = ...`, and *every* other assignment to the name (however
   deeply nested) becomes `name := ...`. This is the classic accumulator
   pattern:

   ```python
   total = 0                    # var total = 0
   for v in values:
       total = total + v        #     total := total + v
   print(total)
   ```

   See `accumulator_var.py`, `accumulator_nested_if.py`, `max_of_list.py`
   (which promotes two independent names, `result` and `first`, this way
   inside the same `if`/`elif`).

3. **No assignment happens directly at that level -- every one is nested
   inside a child block, and there's no unconditional default to
   initialize a `var` with.** py2pyk does not give up immediately here:
   if the *only* nested assignments are the last statement of every
   branch of one exhaustive `if`/`elif`/.../`else` (mandatory `else`,
   same assignment target in every branch), it uses Pyking's own
   [value-form `if`](../../PYKING.md#ifmatch-statements-as-bound-values)
   instead of a `var`:

   ```python
   if x >= 10:            #  label =
       label = "big"      #      if x >= 10:
   elif x >= 0:            #          "big"
       label = "small"     #      else if x >= 0:
   else:                   #          "small"
       label = "negative"  #      else:
   return label            #          "negative"
   ```

   (`conditional_assignment_valueif.py`; `conditional_assignment_tuple.py`
   shows the same thing with a tuple-destructuring target,
   `lo, hi = a, b`.) If the nested assignments *don't* form that exact
   shape (no `else`, or scattered across more than one `if`, or mixed
   with a `for`/`while`), py2pyk has no way to give the name a value on
   every path and rejects the program:

   ```
   $ python3 py2pyk.py -
   def f(x):
       if x > 0:
           y = 1
       print(y)
   <stdin>:3:9: unsupported: 'y' is only assigned conditionally (on line(s) 3)
   and is used outside that conditional -- Pyking has no uninitialized 'var',
   and this isn't a plain if/elif/.../else that assigns it in every branch
   (which py2pyk could bind with a value-form 'if'); give it a default value
   before the conditional
   ```

This same analysis is what makes `x += 1`/`x -= 1`/`x *= 1`/`x /= 1`
possible: an augmented assignment always needs its target to already be
a Pyking `var` (see `accumulator_var.py`), so py2pyk requires an
unconditional plain assignment to have already promoted it. `%=`, `//=`,
and `**=` are rejected outright, for the same reason their non-augmented
operators are (see below).

**A name a `for`-loop binds as its own loop variable is a separate,
simpler case, and is never promoted to `var`:** Pyking's `for name in
...:` scopes `name` to the loop body alone (`analyses.py`'s `SFor` case
discards the loop's binding when the loop ends), while Python's leaks it
into the rest of the function. If the same name is read or reassigned
anywhere outside the loop body that bound it, there is no `var` that
could stand in for it -- a `for` loop can't declare its target as an
existing `var`, only bind a fresh name -- so py2pyk rejects it directly
rather than silently changing what the last-seen value means:

```
$ python3 py2pyk.py -
def f():
    total = 0
    for total in range(3):
        print(total)
    return total
<stdin>:2:5: unsupported: 'total' is used on line(s) 2, 5, outside the
'for' loop(s) on line(s) 3 that bind it as their loop variable -- Pyking's
'for' variable is scoped to the loop body only and never leaks (unlike
Python's); use a different name for the loop variable, or (to keep the
last value) assign it to a separate 'var' as the last statement of the loop body
```

### `for a, b in pairs:` (tuple-target `for`)

Pyking's `for` statement only ever binds a single name (see the
`for_stmt` rule in [PYKING.md's grammar](../../PYKING.md#grammar)) --
unlike a list comprehension's `for`, it does not accept a full pattern.
py2pyk still translates Python's tuple-target `for`, by binding a fresh
element name and destructuring it as the loop body's first statement,
which is always a sound, irrefutable rewrite of the identical Python
semantics:

```python
for a, b in pairs:      # for item in pairs:
    print(a, b)          #     (a, b) = item
                          #     print(a, b)
```

See `for_tuple_destructure.py`.

### Forward references and mutual recursion

Pyking functions are only visible to code written *after* them --
"A function does see its own name... but two functions cannot yet call
each other, and a `def` cannot refer to a binding written below it" (see
["Names and scoping"](../../PYKING.md#names-and-scoping)). py2pyk
enforces the identical rule itself, with its own scope-chain
implementation (`Scope` in `py2pyk.py`, deliberately not imported from
`boot/analyses.py` -- see "Design notes" below) so that a forward
reference is reported against the *Python* source line, before pykboot
ever sees the (invalid) output:

```
$ python3 py2pyk.py -
def main():
    return helper()


def helper():
    return 42
<stdin>:2:12: unsupported: name 'helper' is not bound at this point --
Pyking only sees what was already defined earlier in the enclosing scope
(no forward references, no calling a function defined later, no mutual
recursion between two separate functions)
```

Straight self-recursion (`recursion_factorial.py`,
`recursion_fibonacci.py`, `recursion_gcd.py`) is unaffected: a function's
own name is bound before its body is checked.

### Type annotations

`int`, `str`, `bool`, and `list[T]`/`tuple[T, ...]` annotations (nesting
freely) are translated to Pyking's `Int`/`String`/`Bool`/`[T]`/`(T, ...)`
syntax. Anything else -- `Optional[int]`, a string-quoted forward
reference, a user-defined type, `Any`, ... -- is silently **dropped**,
never rejected: PYKING.md is explicit that annotations "are parsed and
stored in the AST... but nothing is verified against them" and "every
backend erases them completely," so omitting an annotation Pyking has no
syntax for is always safe -- it carries no information any backend could
have acted on anyway, so dropping it is never a behaviour change. See `type_annotations.py`.

## Not supported, and why

Some of these are permanent (Pyking's grammar genuinely has no way to
express them); a few are choices py2pyk makes to stay predictable rather
than guess. Each gives a specific, worded error naming the construct.

**No Pyking equivalent at all:**

- **Indexing/subscripting** (`x[i]`, `x[a:b]`) -- Pyking's grammar has no
  indexing operator (see the `atom`/`call_tail` rule in
  [PYKING.md's grammar](../../PYKING.md#grammar): a call can chain after
  an atom, nothing else can). This also rules out list *mutation*
  (`xs[i] = v`) and slicing.
- **Attribute access** (`x.attr`, `x.method()`) -- there is no `.`
  operator in Pyking at all, so no method calls (`.append`, `.upper`,
  `.items`, ...) and no attribute lookups.
- **Dicts and sets** (literals and comprehensions) -- Pyking has `Int`,
  `String`, `Bool`, lists, and tuples; no mapping or set type.
- **Classes** -- no objects, no `self`, no inheritance.
- **Exceptions** -- no `try`/`except`/`finally`/`raise`/`assert`.
- **`and`/`or`/`not`** -- Pyking's only boolean-producing operators are
  the five comparisons (`< <= > >= ==`); there is no boolean connective
  at all. Rewrite with nested `if` statements (De Morgan by hand for
  `not`, where that's even possible -- `not (a == b)` has no single
  Pyking comparison to invert to, since there is no `!=` either).
- **`!=`, `is`, `is not`, `in`/`not in` as a boolean test** -- Pyking's
  five comparisons don't include any of these. (`in` is fine, and
  translated, in a `for`-loop header or a comprehension -- just not as a
  standalone boolean expression.)
- **`%`, `//`, `**`, and all bitwise operators** (`| & ^ << >> ~`) --
  Pyking's arithmetic is `+ - * /` only. `/` itself *is* translated,
  matching Python's true division exactly (`boot/target_c.py` spells out
  that Pyking's `/` is true division, same as Python's, in the course of
  explaining why the C backend can't support it yet).
- **`None`, floats, bytes, complex** -- Pyking has `Int`/`String`/`Bool`
  and nothing else; there is no null/optional value and no
  floating-point type.
- **f-strings** -- rewrite with `+` and `str(...)` (see `strings.py`).
- **`break`/`continue`/`pass`** -- there is no loop-exit, loop-continue,
  or no-op statement in Pyking's grammar at all.
- **`import`/`from ... import`** -- py2pyk translates one self-contained
  file; Pyking has no module system yet.
- **`global`/`nonlocal`** -- no equivalent; relatedly, a nested function
  can *read* an enclosing `var` (ordinary lexical scoping) but can never
  write to one, matching Python's own behaviour without `nonlocal`.
- **`lambda`** -- no anonymous functions; give it a name with `def`.
- **`match`/`case`** -- deliberately not translated, and not merely
  unimplemented: Python's own `match` AST does not distinguish a
  tuple-shaped sequence pattern (`case (a, b):`) from a list-shaped one
  (`case [a, b]:`) -- both parse to the same `ast.MatchSequence` -- but
  Pyking's grammar treats a tuple pattern and a list pattern as
  different, incompatible pattern kinds (one destructures a tuple value,
  the other a list, and only the list one accepts a `..rest` marker).
  There is no sound way to recover which one the source meant from the
  AST alone, so py2pyk refuses the whole statement rather than guess.
- **`async`/`await`** -- Pyking has no concurrency model.
- **Chained comparisons** (`a < b < c`) -- Pyking's comparisons don't
  chain (see the grammar notes in PYKING.md); write them out.
- **A comprehension with a list-shaped target** (`[a, b] for [a, b] in
  rows`) -- accepted by Python, but with different *semantics* than the
  same-looking Pyking list pattern would have (Python raises on a
  length mismatch; Pyking's list pattern silently filters non-matching
  elements out of the comprehension's result -- see
  ["Arbitrary, refutable patterns in list comprehensions"](../../PYKING.md#new-in-pyking-not-in-python)).
  Translating it would quietly change what the program does on
  mismatched input, so py2pyk rejects it; a plain name or a tuple target
  (`(a, b)`) is unaffected, since those always require an exact match in
  both languages.
- **A Python `match`-style refutable comprehension filter** (matching a
  literal against a sequence value to filter it, `[1 for 0 in xs]`) --
  not just unsupported but not even valid Python syntax (`0` isn't an
  assignable target), so it can never appear in a `.py` file py2pyk is
  asked to translate. Pyking's equivalent (see the PYKING.md link above)
  is a Pyking-only extension with nothing on the Python side to translate
  *from*.

**Choices py2pyk makes for predictability, not grammar limits:**

- **Forward references and mutual recursion between functions** --
  Pyking could theoretically be extended to allow these, but doesn't
  today (see ["Names and scoping"](../../PYKING.md#names-and-scoping));
  py2pyk enforces the same rule Pyking would enforce anyway, just
  earlier and against the Python source position.
- **A `for`-loop's own target used outside its loop** -- see above;
  Python leaks it, Pyking never does, and there's no `var` a `for`
  header can bind to instead.
- **Chained assignment** (`a = b = 1`) and **multiple assignment
  targets** in one statement -- assign one target per statement instead.
  (Pyking has no syntax for it, and re-evaluating the right-hand side
  once per target to fake it would change behaviour if it has side
  effects.)
- **Starred targets/unpacking** (`a, *rest = xs`, `f(*args)`) -- Pyking's
  assignment targets and call arguments have no rest-marker; a `..rest`
  marker exists only in `match`/comprehension *patterns*, not here.
- **Default parameter values, `*args`, `**kwargs`, keyword-only or
  positional-only parameters, keyword arguments in a call, decorators**
  -- Pyking's parameter and call-argument lists are both a fixed,
  positional, undecorated list.
- **A bare `return`** (no value) -- `return_stmt` in Pyking's grammar
  always takes a value; there is no bare form.
- **`x: int` with no value** (a declaration with nothing to bind) --
  every Pyking binding needs a value on the same statement.

## Design notes

- **Why `ast`, not a hand-written parser.** The project's own convention
  (see the top-level `CLAUDE.md`) is to hand-write the *Pyking* parser,
  because that parser is meant to become part of the self-hosted
  compiler eventually. There is no such reason to hand-write a *Python*
  parser: Python already ships one, it is complete, and it is what every
  other Python tool uses.
- **Why py2pyk re-implements Pyking's scope rules instead of importing
  `boot/analyses.py`.** Doing so gives errors positioned against the
  Python source line the trouble is actually on -- far more useful than
  translating first and letting `pykboot` reject the *generated* Pyking
  file, which would point at a line number in a file the user never
  wrote. It also keeps py2pyk genuinely independent, per the brief:
  nothing under `tools/py2pyk/` reaches into `boot/`, and nothing outside
  `tools/py2pyk/` is affected by anything here. The two only meet, as a
  black box, inside `test_script.py`.
- **Why classification is a separate pass instead of inline
  heuristics.** Deciding `var` vs. `=` vs. value-form `if` needs to see
  *every* use of a name in a function before emitting the *first*
  statement that touches it (the earliest assignment might need to
  become `var name = ...` only because of an assignment three blocks
  later) -- that is inherently a whole-function analysis, not something
  a single top-to-bottom pass can decide as it goes.
- **Safety net, not just a claim.** py2pyk's own scope-checking pass
  really does mirror Pyking's rules (no shadowing a `var`, sequential-only
  visibility, and so on), but as a second line of defence, `make test`'s
  step 2 -- compiling the generated `.pyk` with the *real* `pykboot` --
  means any gap in py2pyk's own checking still gets caught, just with a
  less specific error, rather than silently producing a program pykboot
  itself would refuse.
