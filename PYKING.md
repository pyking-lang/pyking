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
evaluator — instead, `boot/pykboot.py` *compiles* by default: running
`python3 boot/pykboot.py <file>` (or the equivalent `./pykboot <file>`
wrapper script at the repository root) lexes and parses `<file>`,
translates the result to Python, and writes it as `<basename>.py` in the
current working directory — not next to `<file>` itself, so compiling
`some/dir/hello.pyk` from elsewhere writes `./hello.py` — which can then be
run directly with `python3 hello.py`. Pass `--stdout` to print the
generated Python source to stdout instead of writing the file (handy for
piping straight into `python3`). Two more flags select earlier stages
instead, for inspection: `--tokens` prints the raw token stream, and
`--ast` prints the pretty-printed *Pyking* AST (in Pyking's own syntax,
e.g. still showing `var`/`:=`) without compiling. A file that fails to lex
or parse reports a `Lexing error` / `Parsing error` to stderr with the
offending file, row, and column (start and end) instead of producing any
output.

## Feature summary

Expressions:

- Comments
- Integer and string literals (with backslash escapes)
- Variables (identifier references)
- Arithmetic operators (`+`, `-`, `*`, `/`) and parenthesized expressions
- Comparison operators (`<`, `<=`, `>`, `>=`, `==`)
- Function calls

Statements:

- Immutable bindings (`=`)
- Mutable variables (`var` and `:=`) — Pyking extension
- Function definitions (`def`)
- `return` statements
- `for`/`in` loops
- `while` loops
- `if`/`else` statements
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
            | var_decl
            | assignment
            | mutation
            | expr_stmt ;

function_def = "def" , ident , "(" , [ params ] , ")" , ":" , block ;
params       = ident , { "," , ident } ;

return_stmt = "return" , expr ;

for_stmt    = "for" , ident , "in" , expr , ":" , block ;

while_stmt  = "while" , expr , ":" , block ;

if_stmt     = "if" , expr , ":" , block , [ "else" , ":" , block ] ;

var_decl    = "var" , ident , "=" , expr ;
assignment  = ident , "=" , expr ;
mutation    = ident , ":=" , expr ;

expr_stmt   = expr ;

expr        = additive , [ comp_op , additive ] ;
comp_op     = "<" | "<=" | ">" | ">=" | "==" ;

additive    = multiplicative , { ( "+" | "-" ) , multiplicative } ;
multiplicative = atom , { ( "*" | "/" ) , atom } ;

atom        = ( int | string | ident | "(" , expr , ")" ) , { call_tail } ;
call_tail   = "(" , [ args ] , ")" ;
args        = expr , { "," , expr } ;

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
