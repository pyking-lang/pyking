# The Python target

**Targets in this family:** `python` (the default).

**Key points**

- The **reference backend**: it compiles the entire language, and every
  other target is measured against its output.
- Output is one `.py` file, runnable with `python3`, importing nothing.
- Pyking's three binding forms — `=`, `var`, `:=` — all become plain
  Python assignment, because Python has no distinction to keep.
- Where Pyking is *stricter* than Python, the difference is compiled
  away: block scoping becomes **renaming**, and refutable comprehension
  patterns become a generated **match helper**.
- Type annotations are erased; nothing checks them at any stage.
- Least optimal at: shadowed bindings (renamed, so generated names drift
  from the source) and refutable comprehension patterns (a helper
  function per clause, hoisted to the top of the file).

Implementation: `src/target_python.ml`.

## What is supported

Everything. Pyking is defined by what this backend accepts — the parser
and the name analysis reject a program before it gets here, and anything
that survives those stages compiles. There is no "unsupported" list.

## How things compile

### Bindings and mutation

Python has one assignment statement, so all three Pyking forms collapse
into it. The distinction is real in Pyking and checked before this point
(`:=` requires a `var`, and a `var` may not be shadowed), so nothing is
lost by the time code is generated:

```pyking                          # generated Python
x = 1                              x = 1
var total = 0                      total = 0
total := total + x                 total = total + x
print(x, total)                    print(x, total)
```

### Booleans

`true`/`false` compile straight to Python's `True`/`False` — that part is
a plain value, not a formatting concern, so a bound, returned, or
compared boolean looks exactly as you'd expect in the generated code.
Printing one is the exception: Python's own `print` would write it back
out capitalised, `True`/`False`, but Pyking prints `true`/`false` (see
"The builtins and the host boundary" in `docs/architecture.md`) — the one place this
backend's native behavior actively disagrees with Pyking's, rather than
simply lacking a distinction Pyking makes.

Which arguments need that spelling is read off the **type checker's own
answers**: `translate_program` takes `tmap`, the symbol → type table, and
`bool_kind` asks it about each `print` argument. Pyking is statically
typed, so there is always an answer to ask for.

```pyking                                     # generated Python
print(1 < 2, true, 5, "hi")                   print('true' if 1 < 2 else 'false', 'true' if True else 'false', 5, 'hi')
count = 3                                     count = 3
print(count)                                  print(count)
```

A `Bool` becomes an inline `'true' if <expr> else 'false'` — `<expr>` is
evaluated exactly once either way, since it's the conditional's own
condition, not repeated in each branch. A type with no `Bool` anywhere
inside it — `Int`, `String`, `()`, `[Int]`, `(Int, String)` — is passed
through completely unwrapped, exactly as if this backend didn't exist.
That second case is the common one, and it is why an ordinary program
compiles to Python with no helper in front of it at all.

What is left is a value that really can hold a `Bool` where Python and
Pyking spell it differently — a `[Bool]`, a `(Int, Bool)`, or a type
nothing has pinned down. Those go through a small generated helper that
walks the value at *runtime* and formats it by `builtin.ml`'s
rules:

```pyking                              # generated Python (only ever emitted if needed)
flags = [true, false]
print(flags)                           print(__pyk_str(flags, True))    # [true, false]
```

Booleans are not the only thing the host spells its own way. A string
prints **bare on its own and quoted inside a list or a tuple**
(`builtin.ml`), with `'` escaped as `\'` — and Python's own
`repr` picks its quotes for itself, writing `["it's"]` where every other
target writes `['it\'s']`. So a value that can hold a string *inside* a
container goes through the helper too, whatever its booleans say
(`nests_a_string`). A string on its own does not: it prints bare, which
Python already agrees with, and neither does a container of `Int`s.
`tests/printing_quotes.pyk` is the case.

`isinstance`, not `v is True`/`v is False`: Python's `bool` is a subclass
of `int` and `1 == True`, but `isinstance(1, bool)` is always `False`, so
an ordinary Pyking `Int` that happens to hold `0` or `1` is never
misprinted as a boolean this way. The helper is generated at most once
per file, lazily, the first time an argument actually needs it — so a
program that never prints anything this backend can't classify never
gets one at all — and named to avoid every identifier in the source (the
same scheme `__pm*` comprehension helpers use, see below), so it can
never collide with a user's own name. When present, it prints in its own
commented-off **prelude** block ahead of the rest of the file (mirroring
the convention `target_js_packaging.ml` uses for its own prelude, for the
same reason: it's boilerplate for the host, not a translation of
anything the Pyking source wrote):

```python
# --- prelude begins ---
# Pyking prints a Bool as `true`/`false`, not Python's own capitalised
# `True`/`False`, wherever it sits -- on its own, or inside a list or
# a tuple. This helper exists because at least one value printed below
# isn't provably free of Bools from its Pyking source form alone (a
# variable, a call, or a container), so it is walked at runtime.

def __pyk_str(v, top):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, str):
        if top:
            return v
        out = '\''
        for c in v:
            out = out + ('\\\\' if c == '\\' else ...)
        return out + '\''
    if isinstance(v, list):
        ...
    if isinstance(v, tuple):
        ...
    return str(v)

# --- prelude ends; the compiled program follows ---
```

The walk is what makes a boolean print as `true` wherever it sits —
`print([true, false])` writes `[true, false]`, and `print((1, true))`
writes `(1, true)` — which is the rule `builtin.ml` states and
the interpreter implements. The `top` parameter carries the one thing
that changes with depth: a string prints bare on its own and quoted
inside a container, and the quoting is Pyking's own (single quotes,
backslash escapes) rather than Python's `repr`, which would switch to
double quotes for a string containing an apostrophe and so disagree with
the other backends on `print(("it's", 1))`.

### A `var` written from inside a function

A mutable variable is one location, so a `def` that writes one bound
outside it writes *that* location. Python does not agree by default:
assigning a name anywhere in a function makes it local to the whole
function, so the obvious translation would silently make a second
variable — and, worse, would raise `UnboundLocalError` the moment the
body also *read* it.

So a function body declares what it writes, before anything else in it:

```pyking                       # generated Python
var x = 8                       x = 8

def foo(y):                     def foo(y):
    x := y                          global x
                                    x = y
                                    return ()
```

`global` for a `var` declared at the module level, `nonlocal` for one in
an enclosing function:

```pyking                       # generated Python
def outer(start):               def outer(start):
    var total = start               total = start

    def bump(n):                    def bump(n):
        total := total + n              nonlocal total
                                        total = total + n
                                        return ()
    bump(1)                         bump(1)
    return total                    return total
```

`Scope` carries what that decision needs: `depth`, how many Python
function scopes deep the translation is (0 is the module), and
`mutables`, each `var` in scope and the depth its declaration sits at.
`mutated_names` collects the names a body writes with `:=` and does not
itself declare with `var`, stopping at a nested `def` — that body
declares its own. Nothing needs to be declared for a name the body
declares itself, and nothing may shadow a `var` anyway (PYKING.md,
"Names and scoping"), so there is never a second candidate for a write
to mean.

This is the one backend that needs any of this. JavaScript closes over
the binding and OCaml over the `ref`; C and Java have no closures at all
and refuse such a function outright, with a worded error.

### Names that are keywords in Python

A name can be a perfectly good Pyking identifier and a reserved word in
Python — `lambda`, `class`, `pass`, `del`, `import`, and the rest.
Emitting it unchanged would produce a file that will not parse, so such
a name is renamed by the same mechanism that renames a shadowed one:

```pyking                          # generated Python
def lambda(n):                     def lambda2(n):
    n * 2                  ->          return n * 2
```

The list comes from the standard `keyword` module (`kwlist` plus
`softkwlist`) rather than being written out here, so it cannot go stale
against the Python this compiler runs on. Renaming picks `lambda2`,
`lambda3`, … — skipping any that is itself taken or reserved.

### Blocks are scopes; Python's are not

Pyking makes every block a scope. Python scopes at function boundaries
only, so a binding that shadows an outer name inside an `if`/`for`/
`while`/`case` body would land on the *same* Python variable and the
outer name would come back changed. The backend renames it, keeping the
new name close to the source one — `total`, then `total2`, then `total3`:

```pyking                          # generated Python
total = 1                          total = 1
if 1 < 2:                          if 1 < 2:
    total = 2                          total2 = 2
    print(total)                       print(total2)
print(total)                       print(total)
```

Renaming happens **only where it is needed**, so generated code keeps the
names actually written wherever it can. Not inside a `def` body or a
comprehension (Python already scopes those), and not when the shadowed
binding is unreachable anyway — rebinding within one block, or two
sibling blocks that each use the same name.

The name it picks has to miss every name an **enclosing** block is still
using, and that is more than the scope's `local` map can answer: `local`
holds one Python name per Pyking name, so `x` → `x3` at the third level
has already overwritten the `x2` the second level is still reading.
`Scope.used` is what remembers the ones a shadow replaced — every Python
name handed out by an enclosing block of this Python function scope. It
is inherited by `block_scope` and reset by `function_scope`, and it
deliberately does *not* travel back out of a finished block, so two
sibling blocks may still reuse a name. Without it, a fourth level of
`x` wraps back round to `x2` and assigns over the second level's
binding — silently, since the program still runs.
`tests/shadowing_depth.pyk` is the case, and
`tests/shadowing_depth_loops.pyk` the same through `for` and `loop`.

There is a second way the two scopings disagree, and it needs looking
*ahead* rather than behind. Any binding of a name inside a Python
function makes that name local to the **whole** function, so a block that
shadows a name the rest of the function still reads cannot keep the
plain name either:

```pyking                          # generated Python
def helper(n):                     def helper(n):
    n                                  return n

def branchy(n):                    def branchy(n):
    if n > 0:                          if n > 0:
        def helper(m):                     def helper2(m):
            m * 10                             return m * 10
        helper(n)                          return helper2(n)
    else:                              else:
        helper(n)                          return helper(n)
```

Spelling both `helper` would turn the else branch into a read of the
local one — `UnboundLocalError` at run time, not a name that merely looks
odd. The decision is made per `def` body, from what that body reads
*freely*: names it uses without having bound them itself at that point
(`free_names`). Only those are protected, so a body that shadows a name
it never reads from outside keeps the source's own spelling:

```pyking                          # generated Python
x = 1                              x = 1
def f(n):                          def f(n):
    x = 2                              x = 2
    x + n                              return x + n
```

### A rebinding some function captured

Pyking's `=` is a binding, so rebinding a name makes a *new* one and a
function written earlier keeps the old (PYKING.md, "Names and scoping").
Python has one variable per name per scope, so the second binding gets
its own — but only when a function in that scope actually captured the
first (`captured_names`), so code without closures over the name is
untouched:

```pyking                          # generated Python
x = 1                              x = 1
def show(): x                      def show(): return x
x = "two"                          x2 = 'two'
print(x, show())                   print(x2, show())      → two 1
```

### `loop`, `break` and `continue`

A `loop` is Python's `while True` over one variable holding the
accumulator: the initializer gives it its first value, every tail of the
body assigns the next one, and `break`/`continue` are Python's own,
operand and all -- they have none.

```pyking                          # generated Python
res = loop x = 5:                  x = 5
    if x <= 10:                    while True:
        continue                       if x <= 10:
    if x < 30:                             continue
        x + 2                          if x < 30:
    else:                                  x = x + 2
        break                          else:
                                           break
                                   res = x
```

The loop's own value is the accumulator variable, so binding one is that
assignment after the loop, and a loop in tail position is `return x`.
That works because a `break` is Python's own: it leaves the variable
holding what this turn started with, which is exactly what the loop is
worth. A tuple accumulator is a Python tuple, assigned as a whole
(`x, y = x + 1, y`), so the next turn's values are computed before any
of them is stored. A `loop:` carrying nothing has no variable at all and
is worth `()`, which is what a binding of one gets.

The one place this differs from what the source says is a body path with
no value at all — an `if` with no `else` as the body's last statement.
PYKING.md's tail-position table says such a statement supplies unit, so
the generated `else` assigns `()`, which is what the interpreter does
with it too.

### Unit, and `print` as a value

This backend spells Pyking's unit as Python's empty tuple, `()`: a
unit-returning `def` gets an explicit `return ()`, and the literal `()`
is itself. Python's own `print` is the one thing that does not agree —
it answers `None`, where Pyking's `print` yields unit
(`builtin.ml`) — so a `print` call *used as a value* is
followed by the unit it is worth:

```pyking                          # generated Python
x = print("a")                     x = (print('a'), ())[1]
```

Written as a statement it keeps the bare call, since nothing reads what
a statement is worth:

```pyking                          # generated Python
print("a")                         print('a')
```

Without that, `print(print("a"))` writes `None` where every other target
writes `()`, and `(print("a"), 1)` writes `(None, 1)`. It is not only a
matter of spelling: `__pyk_str` walks a value, so a `None` sitting
inside a list or tuple would show up there too.
`tests/unit_values.pyk` covers both positions.

### A `def` inside a loop

A loop binds afresh on every turn, so a function written in one keeps
that turn's values. Python would leave every copy sharing the last, so
the run of `def`s is built by a small factory taking the loop-carried
names — the values passed are that turn's. This applies to all three
loops: `for`, `while` and `loop`, whose accumulator is loop-carried like
anything else the body binds:

```pyking                          # generated Python
for i in range(3):                 for i in range(3):
    def show(): i                      def __pyk_turn1(i):
    fns := fns + [show]                    def show():
                                               return i
                                           return show
                                       show = __pyk_turn1(i)
                                       fns = fns + [show]
```

The `def`s that **name each other** go into *one* factory, wherever they
are written in the body, so a recursive function calls this turn's copy
and functions that call each other find each other there. The factory
name is allocated like the comprehension helpers' (`__pm*`), checked
against every identifier in the source, so it cannot collide.

Nothing but `def`s moves: a `return` between the members still returns
from the enclosing function, a `:=` still writes the variable it names,
and side effects keep their order. The one exception is a capture bound
*between* the members — a factory called at the first of them cannot
take it as a parameter, so that binding travels with the group and is
returned alongside the functions.

Two narrowings keep this from firing where it is not needed. A `def`
captures **positionally** — a name the block rebinds further *down* is a
different binding, which no turn touches from where the `def` stands —
and `var`s are excluded, because `:=` updates the one binding and a
function reading a `var` is meant to see that.

*Not optimal:* the factory is built whenever the capture exists, even
for a function that never outlives its turn — knowing otherwise needs
escape analysis, which this backend does not do. [gap.md](gap.md) has
the whole mechanism, the cases it covers, and what remains.

`tests/lexical_capture*.pyk` pin all of this, and
`tests/shadowing_functions.pyk` runs the cases the renaming above covers — the sibling
branch above, the outer name read *before* the shadowing binding, three
levels of nesting that need no renaming at all, and a closure reading
the outer name from a block that shadows it.

*Not optimal:* a heavily shadowing program reads with `x2`, `x3` in the
output where the source says `x` throughout. The alternative — leaving
the names alone — would be wrong rather than ugly, so the trade is worth
it; but it does mean generated Python is not always a line-for-line
mirror of the source.

### Statement forms that Python spells differently

`else if` is Pyking's spelling of `elif`, and a body written on its
header's own line — `def f(x): e`, `case p: e` — is an ordinary block of
one statement. Both are undone on the way out: the first into `elif`,
the second into a body whose tail expression becomes a `return`:

```pyking
def sign(n): if n < 0 then "neg" else "pos"


def classify(n):
    if n < 0:
        return "low"
    else if n == 0:
        return "zero"
    else:
        return "high"
```

```python
def sign(n):
    return 'neg' if n < 0 else 'pos'
def classify(n):
    if n < 0:
        return 'low'
    elif n == 0:
        return 'zero'
    else:
        return 'high'
```

Note the operand order flips for the `if` expression: Pyking writes the
condition first (`if c then a else b`), Python writes it in the middle.

### Tail position

A function body's last statement supplies the function's value (see
"Tail position" in PYKING.md), so the backend pushes a `return` down
into it — recursively, so branches of branches are covered:

```pyking                          # generated Python
def pick(x, y, z):                 def pick(x, y, z):
    if z > 5:                          if z > 5:
        x + y              ->              return x + y
    else:                              else:
        2 * x                              return 2 * x
```

`translate_tail_block`/`translate_tail_stmt` do this, and they are
deliberately the same recursion as `translate_value_block` below with
`return` in place of the assignment — which is why an `if` nested in a
`match` nested in an `if` needs no case of its own.

A body that can fall out of its end produces unit on that path, and unit
is `()` — Python's implicit `None` is *not* it, and printing one would
write `None` where every other backend writes `()`. So a `return ()` is
appended exactly when control can reach the end (`falls_through`),
which keeps unit a real value instead of a print-time special case:

```pyking                          # generated Python
def greet(n):                      def greet(n):
    print(n)               ->          print(n)
                                       return ()
```

A body that already returns on every path gets nothing added, so the
common `if`/`else` case stays clean.

Two things are left alone. A `print` in tail position stays a statement:
it yields unit, and Python's implicit `None` already *is* unit, so
`return print(x)` would say the same thing less clearly (and is the one
form the C and Java backends cannot express at all). And a tail that is
a loop or a binding produces no value, so no `return` is emitted and the
function returns `None`.

`return if c:` / `return match e:` compile the same way, just written
explicitly, which additionally works before the end of a body where the
implicit rule cannot reach.

### Value-form `if`/`match`

Binding a block-form `if` or `match` with `=` has no Python equivalent —
Python has no statement that evaluates to a value. It compiles to the
same statement with the *assignment pushed into every branch tail*:

```pyking                          # generated Python
label = if 1 < 2:                  if 1 < 2:
    helper = "yes"                     helper = 'yes'
    helper                             label = helper
else:                              else:
    "no"                               label = 'no'
```

This is why everything else about a branch keeps working — local
bindings, mutation of an enclosing `var`, prints. Wrapping the branches
in a helper function would have broken all three.

### `match`/`case`

`match` maps onto Python's own, and an arm's tail expression becomes a
`return` like any other tail position — which is why an arm that is one
expression is only meaningful inside a function:

```pyking                          # generated Python
def describe(n):                   def describe(n):
    match n:                           match n:
        case 0: "zero"                     case 0:
        case _: "many"                         return 'zero'
                                           case _:
                                               return 'many'
```

### List comprehensions with refutable patterns

A pattern is **irrefutable** when it matches every value it could be
given, so it only ever *binds* — a plain name like `x`, a wildcard `_`,
or a tuple built from those. It is **refutable** when it can fail to
match, so it also *filters*: `0` matches only zero, `[a, b]` only a
two-element list. In a comprehension that difference is visible in the
result, since an element a refutable pattern rejects is dropped rather
than raising an error.

Pyking allows *any* pattern in a comprehension's `for` clause; Python
allows only an irrefutable assignment target. An irrefutable pattern
therefore compiles straight across, while a refutable one — a literal, or
any list pattern — becomes a generated `__pm*` helper that attempts the
match with a real `match` statement and returns `[]` (filtered out) or a
one-element list (matched):

```pyking
rows = [[1, 2], [3], [4, 5]]
sums = [a + b for [a, b] in rows]
names = [n for (n, _) in [(1, "a"), (2, "b")]]
```

```python
def __pm1(v):
    match v:
        case [a, b]:
            return [(a, b)]
    return []
rows = [[1, 2], [3], [4, 5]]
sums = [a + b for item1 in rows for (a, b) in __pm1(item1)]
names = [n for (n, _) in [(1, 'a'), (2, 'b')]]
```

The second comprehension needed no helper: `(n, _)` always binds. The
`item1`/`__pm1` names are checked against every identifier in the source,
so they can never collide with a user name.

| `for` pattern | refutable? | compiles to | helper? |
|---|---|---|---|
| name `x`, wildcard `_` | no | native `for x in seq` | no |
| tuple of irrefutables `(x, _)` | no | native `for (x, _) in seq` | no |
| literal `0`, `"a"`, `true` | yes | two clauses + helper | **yes** |
| any list pattern `[a, b]`, `[x, ..r]` | yes | two clauses + helper | **yes** |
| tuple holding either `(x, 0)` | yes | two clauses + helper | **yes** |

*Not optimal:* every refutable clause adds a top-level function to the
file, hoisted above the program, and each match runs through a list
allocation. A direct `filter`-style expression would be tighter, but
Python's comprehension grammar cannot express a pattern test inline —
this is the cheapest encoding that keeps the result a single
comprehension.

### Functions used before they are written

Every `def` in a block is bound before the block is translated
(`declare_functions`), mirroring the front end. Python needs no help to
*run* a forward reference — it resolves a global or a closure variable
when the call happens — but the translation does, because a name here may
be renamed: a nested `def` that shadows something in the same Python
function scope compiles to `helper2`, and a call written above it has to
say `helper2` too. Without the pre-pass that call would fall through to
the name the *shadowed* binding compiled to and quietly call the wrong
thing.

Being in scope is not the same as having run: a call that executes before
its `def` raises `NameError`/`UnboundLocalError`, which is Pyking's rule
as much as Python's (see PYKING.md, "Names and scoping").

### `range`

Pyking's `range` yields a **list** of `Int` — the language has lists and
no lazy-sequence type, and the type checker says so. Python's own
`range` is a lazy object that prints as `range(0, 2)` and matches no list
pattern, so a range used as a *value* is materialised:

```pyking                          # generated Python
xs = range(2)                      xs = list(range(2))
print(xs)                          print(xs)          → [0, 1]

for i in range(3):                 for i in range(3):     ← still lazy
    print(i)                           print(i)
```

The `for` header keeps the lazy form, which is where building the list
would actually cost something.

### Type annotations

Parsed, stored, pretty-printed back by `-t pyking`, and erased here —
function types (`(Int) -> Int`) exactly like the rest. They are verified
before this backend ever sees them (see PYKING.md's "Type checking"),
and the generated Python carries no typing information at all:

```pyking                          # generated Python
def scale(x, factor:Int) -> Int:   def scale(x, factor):
    return x * factor                  return x * factor
```

## `/` needs a helper, because Python floors

Pyking's `/` truncates toward zero; Python's `//` rounds *down*, so the
two part company whenever exactly one operand is negative -- `-7 // 2`
is `-4` where every Pyking backend gives `-3`. A prelude helper corrects
the sign, emitted only in a program that divides:

```python
def __pyk_div(a, b):
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q
```

Division by zero falls through it to Python's own `ZeroDivisionError`,
which is what this target is documented as doing (see
[targets.md](targets.md)).

## A loop's value needs no loop `else`

Python's `for`/`while` take an `else` clause that runs exactly when the
loop finished without a `break`, and this backend needs none of it: a
Pyking loop is worth its accumulator both ways it can stop, so the
accumulator variable already holds the answer whether the loop ran out
of turns or broke out of them.

```pyking                                    # generated Python
answer =                                     i, acc = 0, []
loop i, acc = 0, [] for x in xs:             for x in xs:
    (i + 1, [(i, x)] ++ acc)                     i, acc = i + 1, [(i, x)] + acc
                                             answer = (i, acc)
```

## Modules

Python's own module system is Pyking's, name for name, so this is the
one target where nothing has to be arranged: a module is a file, an
import is an `import`, and a public name is a name the module binds.

```pyking
# helper.pyk
priv = 3

public def inc(x:Int) -> Int:
    return x + priv


public greeting = "hi"
```

```pyking
# main.pyk
import helper
from helper import inc as bump

print(helper.inc(1))
print(bump(10))
print(helper.greeting)
```

```python
# helper.py
priv = 3

def inc(x):
    return x + priv

greeting = 'hi'
```

```python
# main.py (or whatever --output named it)
import helper
from helper import inc as bump
print(helper.inc(1))
print(bump(10))
print(helper.greeting)
```

**Privacy leaves no trace.** Python has none to express: `priv` is a
module-level name like any other, and nothing stops a hand-written
`helper.priv`. The rule is the front end's, and it has already refused
every Pyking program that would need one.

**Order needs nothing either.** A module's top level runs when Python
first imports it, which is before the importing module's own top level
gets any further — exactly Pyking's rule, for exactly the same reason.

**Renaming composes.** An import binds a name in the module scope like a
`def` does, so it goes through `bind` with everything else. Where the
Pyking name would land on a Python name already in use, the generated
import says so in Python's own words — `import helper as helper2`,
`from helper import inc as bump2` — and the qualified references follow
it.

## Where the output is not optimal

- **Renamed shadows.** Correct, but the generated names drift from the
  source (see above).
- **Comprehension helpers.** One generated function per refutable
  clause, plus a list allocation per element tested.
- **A `print` argument whose type is unknown pays for a function call.**
  `bool_kind` (see "Booleans" above) answers from the checker's own
  table, so a variable, a call and a list are all settled where their
  types are; what is left is a value the checker could not pin down,
  which falls back to the `__pyk_str` runtime walk on every run.
- **No `pass`.** Pyking has no empty block, so the case never arises —
  but it also means the backend has no way to emit one if the language
  ever gains it.
- **The immutability distinction disappears.** `=`, `var` and `:=` all
  become assignment (plus a `global`/`nonlocal` where one is needed), so
  generated Python will happily let you do things the Pyking source would
  have been rejected for. The checking lives in `src/typesystem.ml` and
  `src/analyses.ml`, ahead of every backend; it is not re-expressible in
  the output.
- **No optimisation of any kind.** The backend is a printer: no constant
  folding, no dead-code elimination, no tail calls. `1 + 2` compiles to
  `1 + 2`.

## External modules

A module implemented in Python (`sys.py`, declared in
`sys.external.pyk` -- see [modules.md](modules.md)) is an ordinary
module: the generated program writes `import sys` and reaches it as
`sys.loadfile(...)`, exactly as it would a compiled one. The file is
copied beside the program's output, where `import` finds it.

One thing an implementation has to watch, because Python will not:

- **A module's name is a name in Python's own namespace.** A Pyking
  module called `sys` or `os` will not be found -- the builtin wins.

Integers need no care. Python's `int` is unbounded, and Pyking leaves
overflow past the signed 32-bit range undefined, so an implementation
returns whatever Python computes.

The boundary carries `Int`, `String`, `Bool`, unit, tuples and lists,
each as Python's own.
