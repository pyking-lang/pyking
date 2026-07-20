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

## Feature summary

Expressions:

- Comments
- Integer and string literals (with backslash escapes)
- Variables (identifier references)
- Arithmetic operators (`+`, `-`, `*`, `/`) and parenthesized expressions
- Comparison operators (`<`, `<=`, `>`, `>=`, `==`)
- Function calls
- List literals (`[e1, e2, ...]`)

Statements:

- Immutable bindings (`=`)
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
- `match`/`case` pattern matching, including `case pattern -> expr` — Pyking extension
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
pattern     = int | string | "_" | ident ;

var_decl    = "var" , ident , "=" , expr ;
assignment  = ident , "=" , expr ;
mutation    = ident , ":=" , expr ;

expr_stmt   = expr ;

expr        = additive , [ comp_op , additive ] ;
comp_op     = "<" | "<=" | ">" | ">=" | "==" ;

additive    = multiplicative , { ( "+" | "-" ) , multiplicative } ;
multiplicative = atom , { ( "*" | "/" ) , atom } ;

atom        = ( int | string | ident | list_lit | "(" , expr , ")" ) , { call_tail } ;
call_tail   = "(" , [ args ] , ")" ;
args        = expr , { "," , expr } ;

list_lit    = "[" , [ args ] , "]" ;

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
  uses that.
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
- `pattern` is intentionally minimal: an integer or string literal matches
  only that exact value; `_` always matches, discarding the value; a plain
  `ident` also always matches, but binds the value to that name. There's
  no support yet for guards (`if`), or-patterns (`|`), or structural
  (tuple/list) patterns.
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

### Immutable bindings (`=`)

`name = expr` binds `name` to the value of `expr`. Per the Pyking design,
this is a binding, not a mutation — it is not meant to update an existing
variable in place (the bootstrap parser accepts the syntax as shown; there
is no evaluator yet to enforce the distinction at runtime).

```python
x = 1
x = x + 1
print(x)
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
value), or a plain identifier (always matches, binds the value to that
name) — see the grammar notes above for what isn't supported yet (guards,
or-patterns, structural patterns).

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
