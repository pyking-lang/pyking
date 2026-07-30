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

Implementation: `boot/target_python.py`.

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

*Not optimal:* a heavily shadowing program reads with `x2`, `x3` in the
output where the source says `x` throughout. The alternative — leaving
the names alone — would be wrong rather than ugly, so the trade is worth
it; but it does mean generated Python is not always a line-for-line
mirror of the source.

### Statement forms that Python spells differently

`else if` is Pyking's spelling of `elif`, and a single-expression body —
`def f(x) = e` or `case p -> e` — is shorthand for a body of one
`return`. Both are undone on the way out:

```pyking
def sign(n) = if n < 0 then "neg" else "pos"


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

`match` maps onto Python's own, and a `-> expr` arm becomes a block whose
single statement is `return expr` — which is why an arrow arm is only
meaningful inside a function:

```pyking                          # generated Python
def describe(n):                   def describe(n):
    match n:                           match n:
        case 0 -> "zero"                   case 0:
        case _ -> "many"                       return 'zero'
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
| literal `0`, `"a"` | yes | two clauses + helper | **yes** |
| any list pattern `[a, b]`, `[x, ..r]` | yes | two clauses + helper | **yes** |
| tuple holding either `(x, 0)` | yes | two clauses + helper | **yes** |

*Not optimal:* every refutable clause adds a top-level function to the
file, hoisted above the program, and each match runs through a list
allocation. A direct `filter`-style expression would be tighter, but
Python's comprehension grammar cannot express a pattern test inline —
this is the cheapest encoding that keeps the result a single
comprehension.

### Type annotations

Parsed, stored, pretty-printed back by `--ast`, and erased here. Nothing
verifies them at any stage, so the generated Python carries no typing
information at all:

```pyking                          # generated Python
def scale(x, factor:Int) -> Int:   def scale(x, factor):
    return x * factor                  return x * factor
```

## Where the output is not optimal

- **Renamed shadows.** Correct, but the generated names drift from the
  source (see above).
- **Comprehension helpers.** One generated function per refutable
  clause, plus a list allocation per element tested.
- **No `pass`.** Pyking has no empty block, so the case never arises —
  but it also means the backend has no way to emit one if the language
  ever gains it.
- **The immutability distinction disappears.** `=`, `var` and `:=` all
  become assignment, so generated Python will happily let you do things
  the Pyking source would have been rejected for. The checking lives in
  `boot/analyses.py`, ahead of every backend; it is not re-expressible in
  the output.
- **No optimisation of any kind.** The backend is a printer: no constant
  folding, no dead-code elimination, no tail calls. `1 + 2` compiles to
  `1 + 2`.
