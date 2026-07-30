# Pyking language reference

Pyking is a small, lexically-scoped, Python-like language. Its syntax and
core expression/statement forms are borrowed directly from Python
(literals, arithmetic and comparison operators, function definitions,
`for`/`while`/`if` control flow, indentation-based blocks). Its
deliberate departures are around binding and scope: plain `=` only
introduces an *immutable* binding for a name, never a mutation; a
variable that changes over time must be introduced with `var` and updated
with `:=`; and every block is a scope, so a name bound inside one is gone
after it.

This document is the language reference: what Pyking programs mean, and
what the bootstrap implementation in `boot/` currently accepts. It says
nothing about the compiler itself: what targets a program can be compiled
to and what each supports is in [docs/targets.md](docs/targets.md), and
how the compiler is put together is in
[docs/architecture.md](docs/architecture.md).

Examples are marked `python` where they are also valid Python, and
`pyking` where they use something Python has no spelling for.

## New in Pyking (not in Python)

A quick reference for readers already familiar with Python: everything
else in this document is either borrowed directly from Python or a
restriction of it, but these are genuinely new.

- **Full lexical scoping, with every block a scope**: Python scopes only
  at function boundaries, so a name bound inside an `if`/`for`/`while`
  body outlives it. In Pyking every block is a scope — an `if`/`else`
  branch, a loop body, a `case` arm, a value-form branch — so a binding
  made inside one is gone after it, and using a name that no enclosing
  scope binds is a compile-time error rather than a `NameError` at run
  time. Any binding may shadow a name already in scope (parameters,
  `for` variables, pattern variables, `def`s, `=` bindings), with one
  exception: a mutable variable may not be shadowed while it is in
  scope, which is what keeps `:=` pointing at exactly one variable.
  All of it is checked at compile time. See "Names and scoping" for the
  details.
- **Immutable-by-default bindings**: plain `=` never mutates — it's
  always a fresh binding. A name must first be declared with `var`
  before it can be updated, and only then with `:=`: `var n = 0` then
  `n := n + 1` (a plain `n = n + 1` would just re-bind `n`, not update it
  in place).
- **Single-expression `case` arms**: `case pattern -> expr` is a `case`
  clause whose whole body is one expression, with no `:` or indented
  block — e.g. `case 0 -> "zero"` instead of `case 0:` followed by
  `return "zero"` on its own indented line.
- **Single-expression function bodies**: `def name(params) = expr` is a
  `def` whose whole body is one expression, with no `:` or indented
  block — e.g. `def add(a, b) = a + b` instead of `def add(a, b):`
  followed by `return a + b` on its own indented line. Just like the
  `case`/`->` extension above, it means a body of one `return expr`. The expression may also stand
  on the line after the `=`, indented, when it no longer fits beside the
  header.
- **`if ... then ... else ...` expressions**: Python writes a conditional
  expression with the condition in the middle (`e1 if cond else e2`);
  Pyking puts it first, behind a new `then` keyword —
  `if cond then e1 else e2`. Semantically the two are identical (only the
  taken branch is evaluated, and `else` is mandatory), and Pyking's form
  matches Python's exactly. This is a genuinely new *keyword*, so
  `then` is reserved everywhere and can no longer be used as an
  identifier.
- **`else if` instead of `elif`**: Pyking has no `elif` keyword — an
  `if` statement chains with the two ordinary keywords `else if`, e.g.
  `else if n == 0:` on its own line. It means exactly what Python's
  `elif` does, so it is neither more nor less than
  sugar for an `else:` block containing a single nested `if` statement.
- **`if`/`match` statements as bound values**: the right-hand side of an
  `=` binding may be a block-form `if` or `match` instead of an
  expression — `x = if cond:` / `x = match e:`, written over as many
  lines as the branches need. They stay *statements*; binding one just
  requires that it produce a value, which is the last expression of
  whichever branch runs, and a bound `if` must therefore have an `else`.
  Python has no statement that evaluates to a value (its `if`/`match`
  yield nothing, and its conditional *expression* holds no statements),
  so no backend can express it as one. Any bound value may also
  start on the line after its `=`, indented — a layout Python has no
  need for, since its right-hand sides are always expressions.
- **`..`/`..name` list-pattern rest markers**: Python spells "match the
  rest of a list" as `*_`/`*name`; Pyking spells it `..`/`..name`, and it
  may appear anywhere in the pattern — start, middle, or end — not just
  once in a fixed position, e.g. `case [first, ..rest]:` or
  `case [a, b, ..middle, z]:`.
- **Arbitrary, refutable patterns in list comprehensions**:
  `[expr for pattern in seq]` accepts any Pyking pattern, not just a
  plain name or Python's simple destructuring targets. When the pattern
  is *refutable* — a literal, or a list pattern — an element that doesn't
  match is silently filtered out rather than raising an error, e.g.
  `[1 for 0 in readings]` (keeps only the elements equal to `0`) or
  `[a + b for [a, b] in rows]` (skips any row that isn't a 2-element
  list). Irrefutable patterns (names and tuple destructuring like
  `[label for (_, label) in pairs]`) simply bind, exactly as in Python.

## Feature summary

Expressions:

- Comments
- Integer and string literals (with backslash escapes)
- Variables (identifier references)
- Arithmetic operators (`+`, `-`, `*`, `/`), unary minus (`-x`, and
  negative literals like `-5`), and parenthesized expressions
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
- If expressions (`if cond then e1 else e2`) — Pyking extension; note the
  keyword order differs from Python's `e1 if cond else e2`

Statements:

- Immutable bindings (`=`), which may destructure a tuple value into
  several names at once (e.g. `a, b = 1, 2` or `(a, (b, c)) = pair`),
  and whose right-hand side may be an `if`/`match` *statement* in value
  form (`x = if cond:` / `x = match e:`) — Pyking extension
- Mutable variables (`var` and `:=`) — Pyking extension
- Function definitions (`def`), with optional parameter and return type
  annotations (`Int`, `String`, `Bool`, list types `[T]`, tuple types
  `(T1, T2, ...)` including the unit type `()`, and nesting of any of
  these) — annotations are pretty-printed in Pyking's own syntax but
  erased when compiling; also `def name(params) = expr`,
  a single-expression body, which may stand on the next line indented —
  Pyking extension
- `return` statements
- `for`/`in` loops
- `while` loops
- `if`/`else` statements, chained with `else if` — spelled as two
  keywords; Pyking has no `elif`
- `match`/`case` pattern matching, including `case pattern -> expr` —
  Pyking extension, tuple patterns (`case (a, b):`), and list patterns
  (`case [a, ..rest]:`) that destructure a tuple or list value
- Expression statements

Structure:

- Indentation-based blocks
- Lexical scoping, with every block a scope, free shadowing of immutable
  names, and no shadowing of a mutable one — checked statically by
  (see "Names and scoping")

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

function_def = "def" , ident , "(" , [ params ] , ")" , [ "->" , type ] ,
               ( ":" , block
               | "=" , bound_expr ) ;
params       = param , { "," , param } ;
param        = ident , [ ":" , type ] ;

type         = "Int" | "String" | "Bool"
             | "[" , type , "]"
             | "(" , [ type , { "," , type } ] , ")" ;

return_stmt = "return" , tuple_or_expr ;

for_stmt    = "for" , ident , "in" , expr , ":" , block ;

while_stmt  = "while" , expr , ":" , block ;

if_stmt     = "if" , expr , ":" , block ,
              { "else" , "if" , expr , ":" , block } ,
              [ "else" , ":" , block ] ;

match_stmt  = "match" , expr , ":" , INDENT , case_clause , { case_clause } , DEDENT ;
case_clause = "case" , pattern , ":" , block
            | "case" , pattern , "->" , expr ;
pattern     = pattern_atom , { "," , pattern_atom } ;
pattern_atom = int | "-" , int | string | "_" | ident
             | "(" , ")"
             | "(" , pattern_atom , "," , ")"
             | "(" , pattern_atom , ( "," , pattern_atom )+ , [ "," ] , ")"
             | list_pattern ;

list_pattern = "[" , [ list_pattern_items ] , "]" ;
list_pattern_items = list_pattern_item , { "," , list_pattern_item } ;
list_pattern_item  = pattern_atom | rest_marker ;
rest_marker        = ".." , [ ident ] ;

var_decl    = "var" , ident , "=" , bound_expr ;
assignment  = target , "=" , bound_value ;
mutation    = ident , ":=" , bound_expr ;

(* A bound value may start on the line after its "=", indented -- the
   lexer wraps it in the same INDENT/DEDENT any other block gets. *)
bound_value = tuple_or_expr | value_stmt | INDENT , bound_value , DEDENT ;
bound_expr  = tuple_or_expr | INDENT , bound_expr , DEDENT ;

value_stmt  = value_if | match_stmt ;
value_if    = "if" , expr , ":" , block ,
              { "else" , "if" , expr , ":" , block } ,
              "else" , ":" , block ;

target      = target_atom , { "," , target_atom } ;
target_atom = ident
            | "(" , ")"
            | "(" , target_atom , "," , ")"
            | "(" , target_atom , ( "," , target_atom )+ , [ "," ] , ")" ;

expr_stmt   = tuple_or_expr ;

tuple_or_expr = expr , { "," , expr } ;

expr        = if_expr | comparison ;

if_expr     = "if" , expr , "then" , expr , "else" , expr ;

comparison  = additive , [ comp_op , additive ] ;
comp_op     = "<" | "<=" | ">" | ">=" | "==" ;

additive    = multiplicative , { ( "+" | "-" ) , multiplicative } ;
multiplicative = unary , { ( "*" | "/" ) , unary } ;
unary       = "-" , unary | atom ;

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
- An `if_stmt`'s chain is written `else if`, two ordinary keywords —
  there is no `elif` keyword to reserve. The chained header must be the
  *statement* form, i.e. end in `:`; `else if c then a else b` is an
  error, since an `if_expr` may not start an `else` tail. This makes
  `else if` exactly equivalent to an `else` block holding one nested
  `if_stmt`, and that is how it is parsed: `boot/parser.py` builds no
  ladder node, just an `SIf` whose `else_body` is a one-element list
  holding the next `SIf`. Both pretty-printers undo the nesting when
  printing (as `else if` in Pyking's own syntax), so
  a ladder round-trips flat instead of stepping one level right per
  branch — and an `else:` block a program *did* write with a single
  nested `if_stmt` inside prints as an `else if` chain, the two being
  the same AST.
- A trailing `else` is optional at every point in the chain, so a ladder
  may end after its last `else if` block and run no branch at all.
- `if_expr` sits at the very bottom of the precedence ladder, below
  `comparison`, and its three sub-expressions are each a full `expr`. Two
  consequences: the branches extend as far right as they can (`if c then
  1 else 2 + 1` has `2 + 1` as its else branch, not `(if ...) + 1`), and
  an `if_expr` cannot be an operand without parentheses (`1 + if c then a
  else b` is a syntax error; write `1 + (if c then a else b)`).
- The branches are `expr`, not `tuple_or_expr`, so a comma ends the
  `if_expr` instead of being absorbed into it: `if c then a else b, d` is
  a two-element tuple whose first element is the `if_expr`. This matches
  how Python reads `a if c else b, d`.
- `if_expr` is right-associative, so an `else` branch that is itself an
  `if_expr` chains flat, with the very same `else if` keyword pair the
  `if_stmt` ladder uses, only inline:
  `if a then 1 else if b then 2 else 3`.
- Unlike `if_stmt`, `if_expr`'s `else` is **mandatory**, and that is what
  makes the two `if`s coexist without ambiguity. Because every `else`
  therefore has exactly one possible owner, even
  `if a then if b then c else d else e` has a single valid parse (the
  inner `if` must claim the first `else`, so the outer claims the
  second). The classic dangling-else ambiguity comes from `else` being
  *optional* — true of Pyking's `if_stmt`, deliberately not of its
  `if_expr`. The two also never compete for the same token in practice:
  an `if_stmt`'s `else` always starts a line after a DEDENT, an
  `if_expr`'s is always inline. This holds for the `else if` pair too,
  and what follows it separates the two cases the same way a leading
  `if` is separated at `statement` (see the next note): a `:` ends an
  `if_stmt` chain's condition, a `then` an `if_expr` chain's.
- A `statement` beginning with `if` is where the real parsing difficulty
  lies: it may be an `if_stmt` or an `expr_stmt` holding an `if_expr`,
  and the two share the entire `"if" , expr` prefix. Since that `expr`
  can be arbitrarily long, no bounded lookahead separates them — the
  grammar is not LL(1) at `statement`. `boot/parser.py` handles this
  without backtracking by parsing the shared prefix once and then
  dispatching on the single token that follows it: `:` means `if_stmt`,
  `then` means `if_expr`. (An `if_stmt` whose *condition* is an `if_expr`
  needs no special handling — `expr` already covers it, so
  `if if a then b else c:` parses.)
- The right-hand side of an `assignment` faces that same standoff and
  resolves it the same way: `x = if c:` is a `value_stmt`, `x = if c
  then a else b` an ordinary `expr`, and only the token after the shared
  `"if" , expr` prefix (`:` or `then`) tells them apart. A `match` on
  the right of `=` needs no such care — `match` is a reserved keyword,
  so it can never begin an `expr`.
- Two restrictions on a `value_stmt` are not expressible in the grammar
  and are checked by the parser instead, since every backend depends on
  both: every branch's `block` must **end in an expression**
  (an `expr_stmt`, or a nested `value_stmt` that recursively ends in
  one), and a `value_if`'s final `else` is **mandatory** — a binding
  cannot be left without a value when no condition holds. A `match_stmt`
  needs no such existence rule: it already requires at least one
  `case_clause`, and a subject matching none of them is a runtime error,
  not a silently skipped branch. The nested-`value_stmt` case is also
  what makes an `else if` ladder work in value form, a ladder being
  exactly a nested `if_stmt` as its `else` branch's only statement.
- Only `assignment` accepts a `value_stmt` — `var_decl`, `mutation` and
  `return_stmt` keep taking a plain `tuple_or_expr` (for the first two
  the parser says so explicitly if you try). The value form works by
  assigning to the target in each
  branch's tail, which is what an immutable binding does; `var`/`:=`
  distinguish *declaring* from *updating*, and a form that expands to
  one assignment per branch has no way to say which of the two each of
  those is.
- The indented `bound_value`/`bound_expr` form holds exactly **one**
  value: anything left in the block before its DEDENT is an error
  (`expected a single value in the indented block after '='`). It exists
  mainly for a `value_stmt` whose header would otherwise share the `=`
  line, but nothing restricts it to those — `x =` followed by an
  indented `1 + 2` is the same rule, as is `var`/`:=` and a
  single-expression `function_def` body (all three take a `bound_expr`:
  the next-line layout, but no `value_stmt`). Both pretty-printers
  normalize it away, printing the value back on the `=` line; the two
  spellings are the same AST.
- A `value_stmt` is rejected in each `bound_expr` position with an error
  naming it (`a 'def ... =' body takes an expression; a value-form
  'if'/'match' can only be bound with '='`). For `def` the reason is not
  just symmetry with `var`/`:=`: a value form binds its target in every
  branch tail, whereas a function body would have to `return` from each
  one instead — a different desugaring, not a restriction of the same
  one. Write `def f(x):` with a block body and a `match` inside it.
- Statements before a branch's last one are ordinary statements, run for
  their effect: a branch may bind local names, print, or update an
  enclosing `var` before yielding its value. This is a consequence of
  how a `value_stmt` compiles — it stays one `if`/`match` *statement*,
  with only the branch tails turned into assignments to the target — and
  is why the value form is not the same as an `if_expr` spread over
  several lines.
- `comp_if` and `comp_for`'s sequence are the one place an `if_expr`
  needs parentheses: `[x for x in xs if (if a then b else c)]`. Written
  bare, the comprehension's own `if`/`in` would run straight into the
  `if_expr`'s keywords. Python restricts these exact two positions for
  exactly this reason (its grammar admits only an `or_test` there,
  excluding the conditional expression), so `[x for x in xs if b if a
  else c]` is a syntax error in Python too. Pyking's parser is in fact
  lenient enough to recover in some of these cases, but both
  pretty-printers always emit the parentheses.
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
- `unary` is the only prefix operator: `-expr` negates, and nests
  (`- -x`). It sits between `multiplicative` and `atom`, so it binds
  tighter than `*`/`/` and looser than a `call_tail` — `-x * y` is
  `(-x) * y`, and `-f(x)` negates the call's *result*, not `f`. It
  applies to the operand it precedes and no further, so parentheses are
  what extend it over a sum: `-x + 1` is `(-x) + 1`, not `-(x + 1)`.
- The same `-` token serves both operators and they never compete: a
  binary `-` can only appear where an expression has just ended, a unary
  one only where an expression is about to begin, so spacing never
  matters (`10 - -3`, `10 - - 3` and `10 - -3` all subtract minus three).
  One consequence of the grammar having no statement separators (see
  `call_tail` above) does follow: a statement *starting* with `-` on the
  line after an expression statement continues that expression instead
  of starting a new one, exactly as a leading `(` does.
- A `pattern_atom` admits a negative integer, matching Python
  (`case -1:`). Only a literal — a pattern is matched, never evaluated,
  so there is no expression there for the general `unary` rule to apply
  to.
- `match_stmt` requires at least one `case_clause`.
- Unlike Python, where `match`/`case` are context-sensitive ("soft")
  keywords, they're always reserved in Pyking — a variable or parameter
  can't be named `match` or `case`. The same is true of `Int`, `String`,
  and `Bool` (the atomic type names): they're reserved everywhere, not
  just in type position, so no identifier may be named after one of them
  either, and of `then`, which has no Python counterpart at all.
- `param`'s `[ ":" , type ]` and `function_def`'s `[ "->" , type ]` are
  both optional and independent — a function may annotate none, some, or
  all of its parameters, with or without a return type. Annotations are
  purely syntactic: they're parsed, stored in the AST, and pretty-printed
  back out, but there is no type checker yet, so nothing is verified
  against them, and every backend erases them completely — no generated
  code carries type syntax at all.
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
  mirroring Python's own restriction on repeated names within one
  `match` pattern.
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
  always requires `:` and an indented block). It *means* a `case pattern:`
  block whose only statement is `return expr` — so, like
  a bare `return_stmt`, it's only meaningful inside a `function_def`; the
  parser doesn't check this, matching how `return_stmt` itself is already
  accepted anywhere without that check.
- The two `case_clause` forms can be freely mixed within one `match_stmt`.
- The `"=" , tuple_or_expr` form of `function_def` is a genuine Pyking
  extension in the same spirit as `case pattern -> expr` above — it isn't
  valid Python syntax at all (Python's `def` always requires `:` and an
  indented block). It *means* a `def name(...):` block whose only
  statement is `return expr`. Unlike `case pattern -> expr` (which
  parses its expression with plain `expr`, not `tuple_or_expr`), the `def`
  form uses `tuple_or_expr` — the same grammar `return_stmt` itself uses
  in the implementation — so a bare tuple works with no extra parens,
  e.g. `def swap(a, b) = b, a`.

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

A `-` written where an expression is expected is instead unary minus,
which negates what follows it. That covers negative literals (`-5`) and
negation of anything else — a variable, a call's result, a parenthesized
expression — and it may be repeated (`- -x`).

```python
x = 5
low = -12

print(-x, -low, - -5)
print(-(x + 1), -x + 1)
print(10 - -3, -x * 2)
```

It binds tighter than `*` and `/` and looser than a call, so `-x * y`
means `(-x) * y` and `-f(x)` negates the result of `f(x)` rather than
`f`. It reaches only over the operand it precedes, which is why `-x + 1`
is `(-x) + 1` and the parentheses in `-(x + 1)` are doing real work.
Since a binary `-` can only follow a completed expression and a unary
one can only start a new one, spacing never changes the reading: `10 - -3`
and `10 - - 3` are the same.

A `case` pattern may use a negative integer literal too — `case -1:` —
matching Python. That is a literal only: patterns are matched, not
evaluated, so `case -x:` is not a negation of anything.

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
arbitrarily.

A *refutable* pattern — a literal, or a list pattern — may reject a value,
and an element it doesn't match is filtered out of the result rather than
raising an error, the same semantics as an unmatched `match`/`case`:

```python
readings = [0, 5, 0, 8, 3]
only_zero = [1 for 0 in readings]
print(only_zero)

rows = [[1, 2], [3], [4, 5], []]
pair_sums = [a + b for [a, b] in rows]
print(pair_sums)
```

`0 in readings` above only produces one `1` per element that literally
equals `0` (filtering out everything else); `[a, b] in rows` only matches
sub-lists of exactly two elements, filtering out `[3]` and `[]`.

An *irrefutable* pattern — a plain name, `_`, or a tuple destructuring
built from those — always binds and never filters, matching how the same
target behaves in a Python comprehension. A tuple pattern is a fixed-arity
destructuring (like its tuple type `(T1, ..., Tn)`), so a wrong-arity
value is a shape error that surfaces at runtime the same way Python's own
unpacking would, rather than being silently skipped:

```python
pairs = [(1, "a"), (2, "b"), (3, "c")]
labels = [label for (_, label) in pairs]
print(labels)
```

A refutable pattern therefore does two things at once — it *filters* and
it *binds* — while an irrefutable one only binds. That is a statement
about the language; how a backend achieves it is its own business, and
the Python target's encoding is described in
[docs/target_python.md](docs/target_python.md).

`tests/list_comprehension_pattern_helper.pyk` exercises every refutable
case; the other `list_comprehension_*` tests use irrefutable patterns.

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
tuple arity is only caught when the program runs).

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

A mutable variable is also the one name that may not be shadowed, and
`:=` only ever accepts one — both checked at compile time; see "Names and
scoping" below.

### Names and scoping

Pyking is **lexically scoped**: every use of a name refers to the
innermost enclosing binding of that name, decided entirely by where the
code is written. A scope is a function body or any indented block — the
body of an `if`/`else` branch, a `for` or `while` loop, a `case` arm, a
value-form branch — plus a list comprehension and the file's top level.
Names bound inside a scope are not visible outside it:

```pyking
total = 0

if 1 < 2:
    inner = total + 1
    print(inner)

# `inner` is not in scope here -- using it is a compile-time error.
```

**What binds a name.** An `=` binding, a `var` declaration, a `def` (its
own name, visible to its body so a function can call itself, and to the
rest of the enclosing scope), a parameter, a `for` variable, a pattern
variable in a `case` arm or comprehension. All of them behave the same
way with respect to scope.

**Shadowing.** Any of those may reuse a name that is already in scope;
the inner binding wins until its scope ends, and the outer one is
untouched and visible again afterwards. Two `=` bindings of the same name
in one scope are the same thing — the second shadows the first, which is
why a binding may change what a name means (and even its type) without
ever being an update:

```pyking
n = "outer"


def describe(n) =
    "param " + str(n)


print(describe(1), n)
```

**The one restriction:** a `var` may not be shadowed. While a mutable
variable is in scope, no binding of any kind may reuse its name — not an
`=` binding, parameter, `for` variable, pattern variable, `def`, or
another `var`:

```pyking
var count = 0

# Each of these is a compile-time error while `count` is in scope:
#   count = 1                  (binding shadows the variable)
#   def f(count): ...          (parameter shadows it)
#   for count in range(3): ... (loop variable shadows it)
```

This is what makes `:=` unambiguous. `count := 1` updates the mutable
variable `count` denotes; if an inner scope could rebind that name to
something immutable, a reader would have to search every enclosing scope
to know whether a given `:=` updates the variable, is an error, or
reaches a *different* variable of the same name. With shadowing
forbidden, the answer is always the nearest `var` — and correspondingly
`:=` requires one: applying it to a binding, parameter, or pattern
variable is an error, not a silent conversion.

A `var` may itself shadow any *immutable* name, and two sibling scopes
may each declare their own `var` of one name, since neither is in scope
where the other is:

```pyking
count = 100


def tally(items):
    var count = 0
    for item in items:
        count := count + item
    return count


print(tally([1, 2, 3]), count)
```

**Bindings are sequential.** A scope's names come into being in the order
they are written, so a name must already be bound where it is used —
including inside a function body, which may only refer to what is in
scope at the point the function is *defined*. A function does see its own
name, so it can call itself; but two functions cannot yet call each
other, and a `def` cannot refer to a binding written below it, even
though a backend's own scoping would resolve both at call time. The rule
errs on the safe side: everything it accepts also runs, whereas making
`def`s visible throughout their scope would equally accept `print(f())`
written above `def f`, which Python rejects at runtime.

**Checking.** All of this is checked statically, before any code is
generated, and reported as a `Name error` against the offending source
position. A handful of names are predefined and count as bound
everywhere — `print`, `range`, `str` and `len` — since no Pyking program
declares them; every other unbound name is an error.

**Compiling preserves this.** A backend whose own scoping is coarser than
Pyking's has to work to keep these rules; how each one does is a compiler
concern rather than a language one, described in
[docs/targets.md](docs/targets.md).

### Function definitions (`def`)

`def name(params):` introduces a function with a comma-separated parameter
list, followed by an indented block of statements as its body.

```python
def average(a, b):
    return (a + b) / 2


print(average(4, 8))
```

`def name(params) = expr` is a single-expression alternative — Pyking
extension, with no Python equivalent, so (unlike every other example in
this document) the following is Pyking source, not valid Python. It means
a `def name(params):` whose only statement is `return expr`, letting short
functions be written on one line. It plays
the same role for `def` that `case pattern -> expr` plays for `match`/
`case` (see below): both are one-expression shorthands for an implicit
`return`. Since it's parsed with `tuple_or_expr`, a bare comma-separated
tuple works with no extra parentheses.

```pyking
def average(a, b) = (a + b) / 2
def swap(a, b) = b, a

print(average(4, 8))
print(swap(1, 2))
```

A return type annotation can still be given before the `=`, exactly as
with the `:`/block form:

```pyking
def average(a:Int, b:Int) -> Int = (a + b) / 2
```

The body may also start on the line *after* the `=`, indented — the same
layout any bound value may take (see "`if`/`match` statements as bound
values" below), and what keeps the form usable once the expression stops
fitting beside the header:

```pyking
def scaled(a, b) =
    (a + b) * 2


def sign(n: Int) -> String =
    if n < 0 then "negative" else "positive"


print(scaled(1, 2), sign(-3))
```

Note the body is still an *expression*: `if ... then ... else ...` as
above, not the block-form `if`/`match` that an `=` binding accepts. A
function body would have to `return` from each branch rather than bind,
which is a different desugaring — write `def name(params):` with a block
body for that.

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
against them. Compiling erases every annotation: no generated code
carries type syntax at all.

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

Further conditions chain with `else if` — two ordinary keywords, since
Pyking has no `elif`. Each `else if` takes its own condition and
indented body, and the first branch whose condition holds is the only
one that runs. The trailing `else:` stays optional: without it, a value
matching none of the conditions runs no branch at all. The example below
is therefore Pyking source, not valid Python — it compiles to Python's
`elif`.

```pyking
def grade(score):
    if score >= 90:
        return "A"
    else if score >= 80:
        return "B"
    else if score >= 70:
        return "C"
    else:
        return "F"


print(grade(95), grade(85), grade(75), grade(65))
```

Because `else if` is just an `else` block holding one nested `if`
statement (see the grammar notes above), the two forms below mean
exactly the same thing; the flat one is preferred, and is the form the
Pyking pretty-printer produces for either.

```pyking
if a:
    print(1)
else if b:
    print(2)

if a:
    print(1)
else:
    if b:
        print(2)
```

### `if`/`then`/`else` expressions

`if cond then e1 else e2` is an *expression*: it evaluates `cond`, then
yields `e1` or `e2`, whichever the condition selects — only the chosen
branch is evaluated. Python writes the same thing with the condition in
the middle, so (unlike most examples in this document) the following is
Pyking source, not valid Python; it compiles to Python's conditional
expression `e1 if cond else e2`.

Unlike the `if` *statement*, the `else` is mandatory — an expression must
always produce a value. The branches reach as far right as they can, so
parenthesize when mixing with operators, and an `else` branch that is
itself an if expression chains flat, reading like an `elif` ladder.

```pyking
def sign(x) = if x < 0 then "negative" else if x == 0 then "zero" else "positive"


def clamp(x, lo, hi):
    y = if x < lo then lo else x
    return if y > hi then hi else y


print(sign(-5), sign(0), sign(7))
print(clamp(42, 1, 10))

# The `+ 1` belongs to the else branch; parenthesize to apply it to the
# whole expression instead.
print(if 1 < 2 then 100 else 200 + 1)
print((if 1 < 2 then 100 else 200) + 1)

# Parentheses are required around an if expression used as a
# comprehension filter (see the grammar notes above).
print([x for x in [1, 2, 3, 4] if (if x < 3 then 1 == 1 else 1 == 2)])
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
`case pattern -> expr` means a `case pattern:` block whose body is
`return expr`, so it's only meaningful directly inside a
function (see the grammar notes above) — unless the whole `match` is
bound with `=`, where the arm supplies the bound value instead of
returning (see "`if`/`match` statements as bound values" below). The two
forms can be mixed freely within one `match`. `def name(params) = expr` (see "Function
definitions" above) is the same idea applied to a whole function body
instead of a single `case` arm.

```pyking
def describe(n):
    match n:
        case 0 -> "zero"
        case 1 -> "one"
        case _ -> "many"


for i in [0, 1, 5]:
    print(describe(i))
```

### `if`/`match` statements as bound values

An `=` binding may take a block-form `if` or `match` on its right-hand
side instead of an expression. The construct stays a statement — it is
written and indented exactly as it would be on its own — but the branch
that runs supplies the bound value, which is its **last expression**.
Python has no statement that evaluates to a value, so the examples in
this section are Pyking source, not valid Python.

```pyking
y = 3
my = 2

x = if 7 > my:
    78 + y
else:
    tt = 5 + y
    tt + 8

print(x)
```

Only the *last* statement of a branch is its value; everything before it
is an ordinary statement run for its effect, as `tt = 5 + y` is above. A
branch may equally print, or update an enclosing `var` — nothing is
hidden inside a new scope, because the compiled Python is the very same
`if` statement with each branch's final expression assigned to `x`:

```python
if 7 > my:
    x = 78 + y
else:
    tt = 5 + y
    x = tt + 8
```

A bound `if` must have an `else` (there would otherwise be no value to
bind when no condition holds), including at the end of an `else if`
ladder. Every branch must end in an expression; the parser rejects both
mistakes rather than binding something undefined.

`match` works the same way, with either style of `case` arm — `-> expr`
gives the value directly, and a block arm gives its last expression:

```pyking
def describe(point):
    text = match point:
        case (0, 0) -> "origin"
        case (0, y):
            side = if y > 0 then "up" else "down"
            "on the y axis, " + side
        case (x, y) -> "at " + str(x) + "," + str(y)
    return text


print(describe((0, 0)), describe((0, 5)), describe((3, 4)))
```

The last statement of a branch may itself be a bound-value `if`/`match`
rather than a plain expression, in which case *its* branches supply the
value — this is also what lets an `else if` ladder be bound, a ladder
being a nested `if` statement in the `else` branch:

```pyking
n = 7

k = if n > 5:
    match n:
        case 7 -> "seven"
        case _ -> "big"
else if n > 0:
    "small"
else:
    "none"

print(k)
```

The value form belongs to `=` alone: `var name = ...` and `name := ...`
still take an ordinary expression (use `=` for the value form, or an
`if ... then ... else ...` expression). A tuple `target` destructures the
bound value exactly as it does in a plain binding.

Finally, the bound value may begin on the line *after* the `=`, indented
one level — which reads better when a `match` subject or `if` condition
would otherwise crowd the binding, and is the only way to keep a long
header off the `=` line. The indented block holds exactly one value:

```pyking
y = 2

z =
    match y:
        case 2 -> "hi"
        case xx -> str(xx)

print(z)
```

This is just a layout choice, not a different construct: it applies to
any bound value (an ordinary expression, and `var`/`:=` too), and both
pretty-printers print it back on the `=` line, since the two spellings
produce the identical AST.

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
