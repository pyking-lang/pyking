# Pyking language reference (bootstrap stage)))

Pyking is a small, statically-scoped, Python-like language. Its syntax and
core expression/statement forms are borrowed directly from Python (literals,
arithmetic and comparison operators, function definitions, `for`/`while`/`if`
control flow, indentation-based blocks). Pyking's one deliberate departure
from Python is around variable mutation: plain `=` only introduces an
*immutable* binding for a name, never a mutation. To declare a variable that
can change over time, it must first be introduced with `var`, and it is
updated afterwards with the `:=` operator rather than `=`.

This document describes the subset of the language currently understood by
the bootstrap implementation in `boot/` (`lexer.py`, `syntax.py`,
`parser.py`, `target_python.py`, `pykboot.py`). Pyking itself has no
evaluator — instead, `boot/pykboot.py` *compiles*: `python3
boot/pykboot.py <file> --output <out.py>` lexes and parses `<file>`,
translates the result to Python, and writes it to `<out.py>`, which can
then be run directly with `python3 <out.py>`. `boot/pykboot.py` always
requires exactly one of three flags telling it what to do — there is no
default action:

- `--output <file>` compiles and writes the generated Python to `<file>`
  (refusing to run if `<file>` would overwrite the input itself).
- `--stdout` compiles and prints the generated Python source to stdout
  instead of writing a file (handy for piping straight into `python3`).
- `--ast` prints the pretty-printed *Pyking* AST (in Pyking's own syntax,
  e.g. still showing `var`/`:=`) without compiling.

`--tokens` additionally prints the raw token stream first, on top of
whichever of the three above is chosen. A file that fails to lex or parse
reports a `Lexing error` / `Parsing error` to stderr with the offending
file, row, and column (start and end) instead of producing any output.

The `pykboot` wrapper script at the repository root forwards flags as-is
(e.g. `./pykboot --ast <file>`), but adds a convenience: called with
*only* a filename and no flags, it compiles to a temp file, runs it with
`python3`, and deletes the temp file afterward — i.e. `./pykboot <file>`
is the "just run it" shorthand.

## New in Pyking (not in Python)

A quick reference for readers already familiar with Python: everything
else in this document is either borrowed directly from Python or a
restriction of it, but these are genuinely new.

- **Immutable-by-default bindings**: plain `=` never mutates — it's
  always a fresh binding. A name must first be declared with `var`
  before it can be updated, and only then with `:=`: `var n = 0` then
  `n := n + 1` (a plain `n = n + 1` would just re-bind `n`, not update it
  in place).
- **Single-expression `case` arms**: `case pattern -> expr` is a `case`
  clause whose whole body is one expression, with no `:` or indented
  block — e.g. `case 0 -> "zero"` instead of `case 0:` followed by
  `return "zero"` on its own indented line.
- **`..`/`..name` list-pattern rest markers**: Python spells "match the
  rest of a list" as `*_`/`*name`; Pyking spells it `..`/`..name`, and it
  may appear anywhere in the pattern — start, middle, or end — not just
  once in a fixed position, e.g. `case [first, ..rest]:` or
  `case [a, b, ..middle, z]:`.
- **Arbitrary, refutable patterns in list comprehensions**:
  `[expr for pattern in seq]` accepts any Pyking pattern, not just a
  plain name or Python's simple destructuring targets — an element the
  pattern doesn't match is silently filtered out rather than raising an
  error, e.g. `[label for (_, label) in pairs]` or `[1 for 0 in readings]`
  (keeps only the elements equal to `0`).

## Feature summary

Expressions:

- Comments
- Integer and string literals (with backslash escapes)
- Variables (identifier references)
- Arithmetic operators (`+`, `-`, `*`, `/`) and parenthesized expressions
- Comparison operators (`<`, `<=`, `>`, `>=`, `==`)
- Function calls
- List literals (`[e1, e2, ...]`)
- List comprehensions (`[expr for pattern in seq if cond ...]`), with
  Python-like support for multiple/nested `for`s and `if`s — but unlike
  Python, `pattern` can be *any* Pyking pattern (not just a plain name or
  simple destructuring target), and an element the pattern doesn't match
  is filtered out rather than raising an error
- Tuple literals (`(e1, e2, ...)`, the singleton `(e,)`, and the empty
  tuple `()`), constructible with or without the enclosing parentheses
  (`e1, e2, ...` — Python-like implicit tuples)

Statements:

- Immutable bindings (`=`), which may destructure a tuple value into
  several names at once (e.g. `a, b = 1, 2` or `(a, (b, c)) = pair`)
- Mutable variables (`var` and `:=`) — Pyking extension
- Function definitions (`def`), with optional parameter and return type
  annotations (`Int`, `String`, `Bool`, list types `[T]`, tuple types
  `(T1, T2, ...)` including the unit type `()`, and nesting of any of
  these) — annotations are pretty-printed in Pyking's own syntax but
  erased entirely when compiling to Python
- `return` statements
- `for`/`in` loops
- `while` loops
- `if`/`else` statements
- `match`/`case` pattern matching, including `case pattern -> expr` —
  Pyking extension, tuple patterns (`case (a, b):`), and list patterns
  (`case [a, ..rest]:`) that destructure a tuple or list value
- Expression statements

Structure:

- Indentation-based blocks

## Grammar

EBNF for the subset currently accepted by `parse()` in `boot/parser.py`.
`INDENT`/`DEDENT` are not literal characters — they are synthesized by the
lexer from 4-space indentation changes (see "Indentation-based blocks"
below). Comments are stripped by the lexer and don't appear here.

```ebnf
program     = { statement } ;

block       = INDENT , { statement } , DEDENT ;

statement   = function_def
            | return_stmt
            | for_stmt
            | while_stmt
            | if_stmt
            | match_stmt
            | var_decl
            | assignment
            | mutation
            | expr_stmt ;

function_def = "def" , ident , "(" , [ params ] , ")" , [ "->" , type ] , ":" , block ;
params       = param , { "," , param } ;
param        = ident , [ ":" , type ] ;

type         = "Int" | "String" | "Bool"
             | "[" , type , "]"
             | "(" , [ type , { "," , type } ] , ")" ;

return_stmt = "return" , expr ;

for_stmt    = "for" , ident , "in" , expr , ":" , block ;

while_stmt  = "while" , expr , ":" , block ;

if_stmt     = "if" , expr , ":" , block , [ "else" , ":" , block ] ;

match_stmt  = "match" , expr , ":" , INDENT , case_clause , { case_clause } , DEDENT ;
case_clause = "case" , pattern , ":" , block
            | "case" , pattern , "->" , expr ;
pattern     = pattern_atom , { "," , pattern_atom } ;
pattern_atom = int | string | "_" | ident
             | "(" , ")"
             | "(" , pattern_atom , "," , ")"
             | "(" , pattern_atom , ( "," , pattern_atom )+ , [ "," ] , ")"
             | list_pattern ;

list_pattern = "[" , [ list_pattern_items ] , "]" ;
list_pattern_items = list_pattern_item , { "," , list_pattern_item } ;
list_pattern_item  = pattern_atom | rest_marker ;
rest_marker        = ".." , [ ident ] ;

var_decl    = "var" , ident , "=" , tuple_or_expr ;
assignment  = target , "=" , tuple_or_expr ;
mutation    = ident , ":=" , tuple_or_expr ;

target      = target_atom , { "," , target_atom } ;
target_atom = ident
            | "(" , ")"
            | "(" , target_atom , "," , ")"
            | "(" , target_atom , ( "," , target_atom )+ , [ "," ] , ")" ;

expr_stmt   = tuple_or_expr ;

tuple_or_expr = expr , { "," , expr } ;

expr        = additive , [ comp_op , additive ] ;
comp_op     = "<" | "<=" | ">" | ">=" | "==" ;

additive    = multiplicative , { ( "+" | "-" ) , multiplicative } ;
multiplicative = atom , { ( "*" | "/" ) , atom } ;

atom        = ( int | string | ident | list_lit | list_comp | tuple_lit
              | "(" , expr , ")" ) ,
              { call_tail } ;
call_tail   = "(" , [ args ] , ")" ;
args        = expr , { "," , expr } ;

list_lit    = "[" , [ args ] , "]" ;

list_comp   = "[" , expr , comp_for , { comp_for | comp_if } , "]" ;
comp_for    = "for" , pattern , "in" , expr ;
comp_if     = "if" , expr ;

tuple_lit   = "(" , ")"
            | "(" , expr , "," , ")"
            | "(" , expr , ( "," , expr )+ , [ "," ] , ")" ;

ident       = letter , { letter | digit } ;
int         = digit , { digit } ;
string      = "'" , { string_char } , "'"
            | '"' , { string_char } , '"' ;
string_char = any_char_except_quote_or_backslash
            | "\" , escape ;
escape      = "n" | "t" | "r" | "\" | "'" | '"' ;
```

Notes that don't fall out of the grammar alone:

- `comp_op` does not repeat — `1 < 2 < 3` is not a valid `expr` (comparisons
  don't chain).
- `while_stmt` has no `else` clause (unlike Python's `while`/`else`).
- `additive` and `multiplicative` are left-associative.
- `call_tail` can repeat after any atom, so `f(1)(2)` parses (a call
  result can itself be called), even though no example in this document
  uses that. This chaining only applies to a `(` on the *same source row*
  as the atom it follows — a `(` that starts a new row is always treated
  as the start of the next statement instead, never as a continuation of
  the previous one. (There are no statement-separator tokens in this
  grammar at all — see the parser module comment in `boot/parser.py` —
  so without this row check, a statement immediately followed by one
  starting with `(`, e.g. a parenthesized tuple destructuring assignment,
  would be misparsed as one giant chained call.)
- There is no unary minus — `-x` is not a valid atom.
- `match_stmt` requires at least one `case_clause`.
- Unlike Python, where `match`/`case` are context-sensitive ("soft")
  keywords, they're always reserved in Pyking — a variable or parameter
  can't be named `match` or `case`. The same is true of `Int`, `String`,
  and `Bool` (the atomic type names): they're reserved everywhere, not
  just in type position, so no identifier may be named after one of them
  either.
- `param`'s `[ ":" , type ]` and `function_def`'s `[ "->" , type ]` are
  both optional and independent — a function may annotate none, some, or
  all of its parameters, with or without a return type. Annotations are
  purely syntactic: they're parsed, stored in the AST, and pretty-printed
  back out, but there is no type checker yet, so nothing is verified
  against them, and `target_python.py` erases them completely (generated
  Python carries no type syntax at all).
- A tuple `type` with zero elements, `()`, is the Unit type. One with a
  single element, e.g. `(Int)`, is a genuine 1-element tuple type, not a
  parenthesized `Int` — Pyking's type grammar has no parenthesization for
  grouping, so there's no ambiguity to resolve. Tuple and list types can
  nest arbitrarily, e.g. `[(Int, Bool)]` or `(Int, [String], (Bool, Bool))`.
- The same is true of `tuple_lit`, `target_atom`, and `pattern_atom`:
  `()` is the empty tuple, and a *parenthesized* single element followed
  by a comma, e.g. `(1,)`, `(x,)`, or `case (p,):`, is a genuine singleton
  tuple/target/pattern, distinct from a plain parenthesized `(1)`/`(x)`/
  `(p)` (which is just grouping, unwrapped by the parser). Tuples nest
  arbitrarily in all three positions.
- `tuple_or_expr`, `target`, and `pattern` all also accept a *bare*
  (unparenthesized) form — `1, 2`, `a, b`, `case a, b:` — but deliberately
  require at least two elements and forbid a trailing comma there: a
  singleton must be written with explicit parens, `(e,)`/`(name,)`/
  `case (p,):`. This isn't just a style rule — since (as noted above)
  there are no statement-separator tokens, a bare trailing comma is
  genuinely ambiguous with the start of the next statement, and the
  parser doesn't detect or reject it: `x = 1,` followed by `print(x)` on
  the next line silently parses as the single statement
  `x = (1, print(x))` instead of two statements. Always use the
  parenthesized singleton form when there's any doubt.
- `pattern_atom` is intentionally minimal beyond tuples and lists: an
  integer or string literal matches only that exact value; `_` always
  matches, discarding the value; a plain `ident` also always matches, but
  binds the value to that name; a parenthesized group destructures a
  tuple value element-by-element; a `list_pattern` destructures a list
  value. All of these nest arbitrarily (e.g. `case (a, [b, ..c]):`).
  There's still no support for guards (`if`) or or-patterns (`|`).
- No pattern (tuple, list, or nested combination of either) may bind the
  same name more than once — e.g. `case [a, ..b, a]:` is rejected at
  parse time with "duplicate binding 'a' in pattern". This mirrors
  Python's own restriction on repeated names within one `match` pattern,
  since both plain `match`/`case` and the list comprehension desugaring
  (see below) ultimately compile a Pyking pattern down to a real Python
  `case` pattern.
- `list_pattern_items` may contain **at most one** `rest_marker`,
  appearing anywhere among the items — patterns before it are a prefix
  that must match the start of the list, patterns after it are a suffix
  that must match the end, and `rest_marker` itself consumes everything
  in between (possibly nothing). A bare `..` matches and discards that
  middle portion; `..name` matches and binds it (as a list) to `name`.
  With no rest marker at all, `list_pattern` matches only a list of
  exactly that length. `[]` matches only the empty list.
- `comp_for`'s `pattern` is `pattern` (i.e. the *full* pattern grammar,
  same as a `case_clause`'s), not just a name or Python's assignment-like
  targets — this is Pyking's one deliberate departure from Python's own
  comprehension grammar. An element the pattern doesn't match (a literal
  that doesn't equal it, or a list pattern whose shape doesn't fit) is
  silently filtered out of the result, the same way a non-exhaustive
  `match` simply does nothing for an unmatched value — it never raises
  an error. `list_comp` always starts with a `comp_for`; `comp_for`/
  `comp_if` may then repeat in any order, matching Python's own
  multi-clause comprehensions (nested `for`s, interspersed `if`s).
- Bracketed/parenthesized literals (`list_lit`, `list_comp`, `tuple_lit`,
  call `args`, etc.) do not support line continuation the way Python's
  do: this lexer has no notion of "inside brackets" and synthesizes
  `INDENT`/`DEDENT` purely from each physical line's leading whitespace
  (see "Indentation-based blocks" below), so a multi-element literal
  must currently stay on one source line.
- The `"case" , pattern , "->" , expr` form of `case_clause` is a genuine
  Pyking extension — it isn't valid Python `match` syntax at all (Python
  always requires `:` and an indented block). It compiles to an ordinary
  `case pattern:` block whose only statement is `return expr` — so, like
  a bare `return_stmt`, it's only meaningful inside a `function_def`; the
  parser doesn't check this, matching how `return_stmt` itself is already
  accepted anywhere without that check.
- The two `case_clause` forms can be freely mixed within one `match_stmt`.

## Feature details

### Comments

A `#` starts a line comment that runs to the end of the line. It may appear
on its own line or trail after other tokens.

```python
# This is a line comment.
x = 1  # comments may also trail after other tokens
print(x)
```

### Integer and string literals

Integers are sequences of digits. Strings are delimited by either single or
double quotes, and support backslash escapes: `\n`, `\t`, `\r`, `\\`, `\'`,
and `\"` (so a string can contain its own delimiter, or the other quote
character, once escaped).

```python
count = 42
message = "hello, pyking"
quoted = 'it\'s a test with a "quoted" word\nand a second line'
print(count, message)
print(quoted)
```

### Variables (identifier references)

An identifier is a name starting with a letter or underscore, followed by
any number of letters, digits, or underscores. Using a name in an
expression looks it up as a variable reference.

```python
x = 10
y = x
print(x, y)
```

### Arithmetic operators and parenthesized expressions

`+`, `-`, `*`, and `/` are left-associative binary operators with the usual
precedence (`*`/`/` bind tighter than `+`/`-`). Parentheses override the
default precedence.

```python
a = 2 + 3 * 4
b = (2 + 3) * 4
c = 10 - 4 / 2
print(a, b, c)
```

### Comparison operators

`<`, `<=`, `>`, `>=`, and `==` compare two arithmetic expressions and
produce a single comparison expression (comparisons do not chain).

```python
print(1 < 2, 2 <= 2, 3 > 4, 3 >= 3, 2 == 2)
```

### Function calls

A call is a callee expression followed by `(`, a comma-separated list of
argument expressions, and `)`. Calls may be nested and may appear anywhere
an expression is expected.

```python
def add(a, b):
    return a + b


print(add(2, 3), add(add(1, 1), 5))
```

### List literals

`[e1, e2, ...]` builds a list from a comma-separated list of expressions,
using the same syntax as call arguments.

```python
values = [1, 2, 3]
var total = 0
for v in values:
    total := total + v
print(values, total)
```

### List comprehensions

`[expr for pattern in seq if cond ...]` builds a list by running `expr`
once for every element of `seq` that matches `pattern` (with any `if`
conditions also holding), in order. Multiple `for`/`if` clauses can be
mixed freely, just like Python's own comprehensions, including nested
`for`s over multiple sequences and a comprehension nested inside another
(the `expr`, a sequence, or a condition can itself be a comprehension).

```python
values = [1, 2, 3, 4, 5]
doubled = [x * 2 for x in values if x > 2]
print(doubled)

rows = [1, 2, 3]
cols = [10, 20]
products = [r * c for r in rows for c in cols]
print(products)

table = [[r * c for c in cols] for r in rows]
print(table)
```

Unlike Python, `pattern` is a full Pyking pattern, not just a plain name
or a simple destructuring target — it can be a literal, `_`, a tuple
pattern, or a list pattern (see "list patterns" below), and nests
arbitrarily. An element the pattern doesn't match is filtered out of the
result rather than raising an error — the same semantics as an unmatched
`match`/`case`.

```python
pairs = [(1, "a"), (2, "b"), (3, "c")]
labels = [label for (_, label) in pairs]
print(labels)

readings = [0, 5, 0, 8, 3]
only_zero = [1 for 0 in readings]
print(only_zero)

rows = [[1, 2], [3], [4, 5], []]
pair_sums = [a + b for [a, b] in rows]
print(pair_sums)
```

`readings for 0 in readings` above only produces one `1` per element that
literally equals `0` (filtering out everything else); `[a, b] in rows`
only matches sub-lists of exactly two elements, filtering out `[3]` and
`[]`. Since Python's own comprehension syntax can't express this
("refutable") pattern matching, `boot/target_python.py` compiles each
`for pattern in seq` clause into a small amount of extra machinery (an
auto-generated helper function that attempts the match via a real Python
`match` statement, plus a couple of supporting comprehension clauses) —
see the comment above `translate_expr`'s `EListComp` case for the details.
The generated Python is still a single ordinary list comprehension
expression; none of this is visible from Pyking source.

### Tuple literals

`(e1, e2, ...)` builds a tuple, corresponding directly to a Python tuple.
Three shapes need explicit parentheses: `()` is the empty tuple (also
called Unit), `(e,)` is a singleton (the trailing comma is required — a
plain `(e)` is just a parenthesized `e`, not a tuple), and any 2+-element
tuple may optionally end in a trailing comma, `(e1, e2,)`. A 2+-element
tuple can *also* be written without the enclosing parentheses at all,
Python-style: `e1, e2, ...` — but this bare form requires at least two
elements and never allows a trailing comma (see the grammar notes above
for why). Tuples nest arbitrarily, with list literals or with themselves.

```python
unit = ()
single = (1,)
pair = (1, 2)
bare_pair = 1, 2
nested = (1, (2, 3), [4, 5])

print(unit, single, pair, bare_pair, nested)
```

### Immutable bindings (`=`) and tuple destructuring

`name = expr` binds `name` to the value of `expr`. Per the Pyking design,
this is a binding, not a mutation — it is not meant to update an existing
variable in place (the bootstrap parser accepts the syntax as shown; there
is no evaluator yet to enforce the distinction at runtime).

```python
x = 1
x = x + 1
print(x)
```

The left-hand side of `=` may also *destructure* a tuple value into
several names at once, either with or without parentheses, and nesting
freely — this is the only place in Pyking where the two forms interact:
the right-hand side is parsed with `tuple_or_expr` (so it may itself be a
bare tuple), while the left-hand side is a `target`, always resolved
independently of what the right-hand side turns out to be (there is no
type checker to confirm the two shapes actually match — a mismatched
tuple arity is only caught at Python runtime, when the generated
unpacking assignment fails).

```python
a, b = 1, 2
(c, d) = (10, 20)
(e, (f, g)) = (1, (2, 3))
(h,) = (99,)

print(a, b, c, d, e, f, g, h)
```

### Mutable variables (`var` and `:=`) — Pyking extension

`var name = expr` declares a new mutable variable, initialized to the
value of `expr`. Once declared, it is updated with `name := expr`, not `=`.

```python
var total = 0
total := total + 1
print(total)
```

### Function definitions (`def`)

`def name(params):` introduces a function with a comma-separated parameter
list, followed by an indented block of statements as its body.

```python
def average(a, b):
    return (a + b) / 2


print(average(4, 8))
```

### Type annotations

Parameters and the return value may optionally be annotated with a type:
`Int`, `String`, `Bool`, a list type `[T]`, or a tuple type
`(T1, T2, ...)` (nesting freely, e.g. `[(Int, Bool)]`). `()`, the
zero-element tuple type, is the Unit type. Annotations are entirely
optional and independent per parameter/return value — a function can mix
annotated and unannotated parameters freely.

```python
def add(a:Int, b:Int) -> Int:
    return a + b


def sum_list(xs:[Int]) -> Int:
    var total = 0
    for x in xs:
        total := total + x
    return total


def scale(x, factor:Int) -> Int:
    return x * factor


print(add(2, 3))
print(sum_list([1, 2, 3, 4]))
print(scale(3, 4))
```

There is no type checker yet — annotations are parsed and stored in the
AST (see `Param`/`SFunctionDef.return_type` in `boot/syntax.py`) and
pretty-printed back out in Pyking's own syntax, but nothing is verified
against them. Compiling to Python (`boot/target_python.py`) erases every
annotation: the generated Python source carries no type syntax at all.

### `return` statements

`return expr` evaluates `expr` and returns it as the function's result.

```python
def first(x, y):
    return x


print(first(1, 2))
```

### `for`/`in` loops

`for name in iterable:` binds `name` to each successive element produced
by `iterable`, running the indented body once per element.

```python
for i in range(3):
    print(i)
```

### `while` loops

`while cond:` runs its indented body repeatedly for as long as `cond`
holds. There is no `else` clause on `while` (unlike Python).

```python
var i = 0
while i < 3:
    print(i)
    i := i + 1
```

### `if`/`else` statements

`if cond:` runs its indented body when `cond` holds. An optional
`else:` with its own indented body runs otherwise.

```python
def classify(x):
    if x >= 10:
        return 1
    else:
        return 0


print(classify(12), classify(3))
```

### `match`/`case` pattern matching

`match expr:` is followed by one or more indented `case pattern:` clauses;
the body of the first case whose pattern matches runs. A pattern is an
integer literal, a string literal, `_` (always matches, discards the
value), a plain identifier (always matches, binds the value to that
name), or a tuple pattern that destructures a tuple value element by
element (with or without parentheses, nesting arbitrarily, and sub-patterns
can themselves be literals, `_`, identifiers, or further tuple patterns)
— see the grammar notes above for what isn't supported yet (guards,
or-patterns, list patterns).

```python
def describe(n):
    match n:
        case 0:
            return "zero"
        case 1:
            return "one"
        case value:
            return "many: " + str(value)


for i in [0, 1, 5]:
    print(describe(i))
```

```python
def classify_point(p):
    match p:
        case (0, 0):
            return "origin"
        case (x, 0):
            return "on the x axis"
        case (0, y):
            return "on the y axis"
        case (x, y):
            return "elsewhere"


print(classify_point((0, 0)))
print(classify_point((3, 0)))
print(classify_point((0, 3)))
print(classify_point((3, 4)))
```

A list pattern destructures a list value, and — unlike a tuple pattern —
may include **one** `..`/`..name` "rest" marker anywhere among its
elements, matching a run of zero or more elements there: `..` matches and
discards them, `..name` matches and binds them (as a list) to `name`.
Patterns before the marker are a required prefix, patterns after it are
a required suffix, and with no marker at all the list pattern matches
only a list of exactly that length. A plain `_` still matches (and
discards) a single element, exactly as in a tuple pattern.

```python
def describe(xs):
    match xs:
        case []:
            return "empty"
        case [x]:
            return "exactly one: " + str(x)
        case [a, b, c]:
            return "exactly three"
        case [first, ..rest]:
            return "prefix + rest, first=" + str(first)
        case [..init, last]:
            return "rest + suffix, last=" + str(last)
        case [p, q, ..mid, r]:
            return "matched middle"
        case [u, v, ..]:
            return "two elements, rest ignored"
        case [_, ..w]:
            return "first ignored, rest=" + str(w)


print(describe([]))
print(describe([1]))
print(describe([1, 2, 3]))
```

Since a pattern used in one function can only ever reach whichever
`case` is textually first among the ones its shape satisfies, the
`[p, q, ..mid, r]` / `[u, v, ..]` / `[_, ..w]` cases above are shadowed by
the earlier, more general `[first, ..rest]` case for any list of two or
more elements — see `tests/list_pattern_match.pyk` for each of the seven
forms demonstrated in its own function, so every one is actually reached.

A `case` clause can alternatively use `->` followed by a single
expression instead of `:` and an indented block — this is a Pyking-only
extension with no Python equivalent, so (unlike every other example in
this document) the following is Pyking source, not valid Python:
`case pattern -> expr` compiles to an ordinary `case pattern:` block
whose body is `return expr`, so it's only meaningful directly inside a
function (see the grammar notes above). The two forms can be mixed
freely within one `match`.

```pyking
def describe(n):
    match n:
        case 0 -> "zero"
        case 1 -> "one"
        case _ -> "many"


for i in [0, 1, 5]:
    print(describe(i))
```

### Expression statements

Any expression, most commonly a function call, may be used directly as a
statement; its value is simply discarded.

```python
print("hello, pyking")
```

### Indentation-based blocks

Blocks are delimited purely by indentation, in 4-space increments — there
are no `{ }` or `begin`/`end` keywords. Increasing the indentation opens a
nested block (after a line ending in `:`); returning to a shallower
indentation closes it, and a single line may close several nested blocks
at once.

```python
def bucket(x):
    for limit in range(3):
        if x < limit:
            return limit
    return 3


print(bucket(0), bucket(5))
```
