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

Implementation: `src/target_python.py`.

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
"The runtime interface" in `docs/architecture.md`) — the one place this
backend's native behavior actively disagrees with Pyking's, rather than
simply lacking a distinction Pyking makes.

There is no type checker in an ordinary compile (see PYKING.md), so in
general this backend cannot know whether a given `print` argument holds
a `Bool` — but it doesn't need one to know for *most* arguments: a
comparison or a boolean literal always is one, and an arithmetic
expression or a literal int/string never is, straight from the Pyking
AST's own shape (`_bool_shape` in `target_python.py`). What a
*container* holds is a different question from what it is, so a list, a
tuple or a comprehension counts as unknown however plainly it is not
itself a `Bool`: `print([true])` has a boolean to spell either way.
Each argument is handled according to what that tells it:

```pyking                                     # generated Python
print(1 < 2, true, 5, "hi")                   print('true' if 1 < 2 else 'false', 'true' if True else 'false', 5, 'hi')
```

A provable `Bool` becomes an inline `'true' if <expr> else 'false'` —
`<expr>` is evaluated exactly once either way, since it's the
conditional's own condition, not repeated in each branch — and a provable
non-`Bool` is passed through completely unwrapped, exactly as if this
backend didn't exist. Everything else — a variable, a call, a list, a
tuple — goes through a small generated helper that walks the value at
*runtime* and formats it by `runtime_interface.py`'s rules:

```pyking                              # generated Python (only ever emitted if needed)
flags = [true, false]
print(flags)                           print(__pyk_str(flags, True))    # [true, false]
```

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
the convention `target_js_packaging.py` uses for its own prelude, for the
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
writes `(1, true)` — which is the rule `runtime_interface.py` states and
the interpreter implements. The `top` parameter carries the one thing
that changes with depth: a string prints bare on its own and quoted
inside a container, and the quoting is Pyking's own (single quotes,
backslash escapes) rather than Python's `repr`, which would switch to
double quotes for a string containing an apostrophe and so disagree with
the other backends on `print(("it's", 1))`.

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
(`_free_names`). Only those are protected, so a body that shadows a name
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
first (`_captured_names`), so code without closures over the name is
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
body assigns the next one, and `break`/`continue` are Python's own —
with the operand, where one is written, assigned first.

```pyking                          # generated Python
res = loop x = 5:                  x = 5
    if x <= 10:                    while True:
        continue x + 1                 if x <= 10:
    if x < 30:                             x = x + 1
        x + 2                              continue
    else:                              if x < 30:
        break                              x = x + 2
                                       else:
                                           break
                                   res = x
```

The loop's own value is what it `break`s with, so binding one is that
assignment after the loop, and a loop in tail position is `return x`. A
tuple accumulator is a Python tuple, assigned as a whole
(`x, y = x + 1, y`), so the next turn's values are computed before any
of them is stored -- and where such a loop breaks with something that is
*not* that tuple (`break acc` in a loop carrying two values, which is
what the tail-call pass builds), the answer gets a variable of its own
rather than being squeezed into the accumulator.

The one place this differs from what the source says is a body path with
no value at all — an `if` with no `else` as the body's last statement.
PYKING.md's tail-position table says such a statement supplies unit, so
the generated `else` assigns `()`, which is what the interpreter does
with it too.

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

`_translate_tail_block`/`_translate_tail_stmt` do this, and they are
deliberately the same recursion as `_translate_value_block` below with
`return` in place of the assignment — which is why an `if` nested in a
`match` nested in an `if` needs no case of its own.

A body that can fall out of its end produces unit on that path, and unit
is `()` — Python's implicit `None` is *not* it, and printing one would
write `None` where every other backend writes `()`. So a `return ()` is
appended exactly when control can reach the end (`_falls_through`),
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
(`_declare_functions`), mirroring the front end. Python needs no help to
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

Parsed, stored, pretty-printed back by `--ast`, and erased here —
function types (`(Int) -> Int`) exactly like the rest. Nothing verifies
them in an ordinary compile (`--typecheck` is a separate, opt-in pass;
see PYKING.md's "Type checking"), and the generated Python carries no
typing information at all:

```pyking                          # generated Python
def scale(x, factor:Int) -> Int:   def scale(x, factor):
    return x * factor                  return x * factor
```

## Where the output is not optimal

- **Renamed shadows.** Correct, but the generated names drift from the
  source (see above).
- **Comprehension helpers.** One generated function per refutable
  clause, plus a list allocation per element tested.
- **An unclassifiable `print` argument always pays for a function call.**
  `_bool_shape` (see "Booleans" above) only recognises a `Bool` from the
  Pyking AST shape directly in front of it; a variable or a function call
  falls back to the `__pyk_bool_str` runtime check even on every run where
  the value turns out not to be a `Bool` at all, since there's no static
  type information to rule that out ahead of time.
- **No `pass`.** Pyking has no empty block, so the case never arises —
  but it also means the backend has no way to emit one if the language
  ever gains it.
- **The immutability distinction disappears.** `=`, `var` and `:=` all
  become assignment, so generated Python will happily let you do things
  the Pyking source would have been rejected for. The checking lives in
  `src/analyses.py`, ahead of every backend; it is not re-expressible in
  the output.
- **No optimisation of any kind.** The backend is a printer: no constant
  folding, no dead-code elimination, no tail calls. `1 + 2` compiles to
  `1 + 2`.
