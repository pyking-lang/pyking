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
what the bootstrap implementation in `src/` currently accepts. It says
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
- **A block on its header's own line**: any header ending in `:` may
  carry its block on that same line instead of indenting it, as long as
  what it carries is one **expression** — `def add(a, b): a + b`,
  `if n < 0: print("negative")`, `case 0: "zero"`,
  `for x in xs: print(x)`. Python allows something similar but wider:
  any *simple* statement, and `;` to write several. Pyking's line holds
  a value and nothing else, so nothing is ever hidden behind a ':' — no
  `return`, no binding, no `:=` — and the line ends there, which is why
  an `else` starts the next one. The two layouts are the same program:
  `def add(a, b): a + b` is `def add(a, b):` followed by `a + b` on its
  own indented line, down to the AST, so nothing after the parser can
  tell which was written. That is what makes a definition short enough
  to read at a glance stay on one line, and lets several such
  definitions follow one another with nothing in between.
- **Lowercase `true`/`false` boolean literals**: Python spells its two
  boolean values `True`/`False`; Pyking spells them lowercase, `true` and
  `false`, matching most other languages' convention rather than
  Python's. They are genuinely new *keywords* (not existing identifiers
  given a meaning), so, like `then` below, neither `true` nor `false` can
  be used as an identifier anywhere. `1 == 1` and `true` are
  interchangeable Pyking values — the only difference is that one is
  computed and the other is written directly — and every backend prints
  either one the same way; see "Booleans" below.
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
- **`loop`, an accumulator loop with `break` and `continue`**: Python
  has no loop that *carries a value*. `loop x = 5:` binds `x` for the
  first turn, and what the body produces is the `x` the next turn gets,
  so a loop needs no mutable variable to add something up. `break` ends
  it -- the loop is then worth what it broke with, which makes a loop
  usable as a bound value -- and `continue` starts the next turn early.
  Both take an optional value: `break e` stops with `e`, `continue e`
  goes round with it. What a loop *carries* and what it is *worth* are
  separate questions, which is what lets a loop carrying two values
  answer with one. See "`loop` loops" below.
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
- Boolean literals (`true`, `false`) — Pyking extension; spelled
  lowercase, unlike Python's `True`/`False`
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

- Immutable bindings (`=`), with an optional type annotation on the
  name (`x: Int = 1`), which may destructure a tuple value into
  several names at once (e.g. `a, b = 1, 2` or `(a, (b, c)) = pair`),
  and whose right-hand side may be an `if`/`match` *statement* in value
  form (`x = if cond:` / `x = match e:`) — Pyking extension
- Mutable variables (`var` and `:=`) — Pyking extension
- Function definitions (`def`), with optional parameter and return type
  annotations (`Int`, `String`, `Bool`, list types `[T]`, tuple types
  `(T1, T2, ...)` including the unit type `()`, function types
  `(T1, T2, ...) -> T`, and nesting of any of these) — annotations are
  pretty-printed in Pyking's own syntax but erased when compiling
- `return` statements, whose operand may be an ordinary expression or
  an `if`/`match` *statement* in value form (`return if cond:` /
  `return match e:`) — Pyking extension
- **Tail position**: a function body's last statement supplies the
  function's value with no `return` written, recursively through
  `if` branches and `case` arms — Pyking extension
- `for`/`in` loops
- `while` loops
- `loop` loops, which carry an accumulator from turn to turn and are
  worth it when they stop, with `break` and `continue` (each taking an
  optional value) -- Pyking extension
- `if`/`else` statements, chained with `else if` — spelled as two
  keywords; Pyking has no `elif`
- `match`/`case` pattern matching, including tuple patterns
  (`case (a, b):`) and list patterns (`case [a, ..rest]:`) that
  destructure a tuple or list value
- Expression statements
- A block written on its header's own line (`def f(x): x * x`,
  `if c: print(1)`, `case 0: "zero"`) — one expression, meaning exactly
  what the indented form means

Structure:

- Left-to-right evaluation: an operator's operands and a call's
  arguments run in the order they are written, and all of a call's
  arguments before the call (see "Evaluation order")
- Indentation-based blocks
- Lexical scoping, with every block a scope, free shadowing of immutable
  names, and no shadowing of a mutable one — checked statically by
  (see "Names and scoping")
- Lexical scoping with `def` *names* visible throughout their block, so
  functions may be recursive, mutually recursive, or called before they
  are written — while what a body *captures* is what is bound where the
  body stands; every other binding stays sequential, and a `def` may not
  share its name with another binding of the same block (see "Names and
  scoping")
- Static checking in two layers: names and scoping always, types only
  under `--typecheck` and only over part of the language so far (see
  "Type checking")

## Grammar

EBNF for the subset currently accepted by `parse()` in `src/parser.py`.
`INDENT`/`DEDENT` are not literal characters — they are synthesized by the
lexer from 4-space indentation changes (see "Indentation-based blocks"
below). Comments are stripped by the lexer and don't appear here.

```ebnf
program     = { statement } ;

(* A block is indented under its header, or is the single expression
   written on the header's own line -- which the EBNF cannot say, since
   it cannot see where a line ends; see the notes below. *)
block       = INDENT , { statement } , DEDENT
            | expr_stmt ;

statement   = function_def
            | return_stmt
            | for_stmt
            | while_stmt
            | loop_stmt
            | break_stmt
            | continue_stmt
            | if_stmt
            | match_stmt
            | var_decl
            | assignment
            | mutation
            | expr_stmt ;

function_def = "def" , ident , "(" , [ params ] , ")" , [ "->" , type ] ,
               ":" , block ;
params       = param , { "," , param } ;
param        = ident , [ ":" , type ] ;

type         = type_atom , { "|" , type_atom } ;
type_atom    = "Int" | "String" | "Bool"
             | "[" , type , "]"
             | "(" , [ type , { "," , type } ] , ")" , [ "->" , type ] ;

return_stmt = "return" , bound_value ;

for_stmt    = "for" , ident , "in" , expr , ":" , block ;

while_stmt  = "while" , expr , ":" , block ;

loop_stmt   = "loop" , [ target , [ ":" , type ] , "=" , tuple_or_expr ] ,
              ":" , block ;

(* The operand is taken only from the keyword's own line -- see the
   notes below. *)
break_stmt    = "break" , [ tuple_or_expr ] ;
continue_stmt = "continue" , [ tuple_or_expr ] ;

if_stmt     = "if" , expr , ":" , block ,
              { "else" , "if" , expr , ":" , block } ,
              [ "else" , ":" , block ] ;

(* Always indented: a `match` opens a list of clauses rather than a
   block of statements, and a `case` clause is not an expression, so
   there is nothing its header's line could carry. *)
match_stmt  = "match" , expr , ":" , INDENT , case_clause , { case_clause } , DEDENT ;
case_clause = "case" , pattern , ":" , block ;
pattern     = pattern_atom , { "," , pattern_atom } ;
pattern_atom = int | "-" , int | string | bool | "_" | ident
             | "(" , ")"
             | "(" , pattern_atom , "," , ")"
             | "(" , pattern_atom , ( "," , pattern_atom )+ , [ "," ] , ")"
             | list_pattern ;

list_pattern = "[" , [ list_pattern_items ] , "]" ;
list_pattern_items = list_pattern_item , { "," , list_pattern_item } ;
list_pattern_item  = pattern_atom | rest_marker ;
rest_marker        = ".." , [ ident ] ;

var_decl    = "var" , ident , "=" , bound_expr ;
assignment  = target , [ ":" , type ] , "=" , bound_value ;
mutation    = ident , ":=" , bound_expr ;

(* A bound value may start on the line after its "=", indented -- the
   lexer wraps it in the same INDENT/DEDENT any other block gets. *)
bound_value = tuple_or_expr | value_stmt | INDENT , bound_value , DEDENT ;
bound_expr  = tuple_or_expr | INDENT , bound_expr , DEDENT ;

value_stmt  = value_if | match_stmt | loop_stmt ;
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

atom        = ( int | string | bool | ident | list_lit | list_comp | tuple_lit
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
bool        = "true" | "false" ;
string      = "'" , { string_char } , "'"
            | '"' , { string_char } , '"' ;
string_char = any_char_except_quote_or_backslash
            | "\" , escape ;
escape      = "n" | "t" | "r" | "\" | "'" | '"' ;
```

Notes that don't fall out of the grammar alone:

- **A statement starts a line of its own**, and so does a `case` clause.
  There is no statement separator in Pyking: a statement ends where the
  tokens stop being able to continue it, which by itself would make

  ```
  print h
  ```

  *two* statements — a bare `print`, then a bare `h` — and so a program
  that reads as though it prints and does not. The rule cannot be stated
  in the EBNF, because the grammar cannot see line boundaries: the lexer
  turns indentation into block structure and emits nothing at all for the
  end of a line. It is checked against the source positions the tokens
  carry, and reported as an ordinary `Parsing error`:

  ```
  'prog.pyk' 2:6-2:7 Parsing error: each statement must start on a new
    line. In this case, 'print' and 'h' are seen as two different
    statements
  ```

  Both are quoted back, because the mistake is not that something is in
  the wrong place but that *two* things were read where one was meant.

  One line may still hold a whole statement whose header opens a block
  (`x = if c:`), and a statement may still span as many lines as its
  blocks need. What one line may not hold is *two* statements.
- A `break`/`continue` takes its operand only when one begins **on the
  same line**. There are no statement separators (see the previous
  note), so a bare `break` followed by an expression on the next line
  would otherwise read as `break <that expression>` -- the same trap the
  `print h` rule exists for. The check is made against the positions the
  tokens carry, exactly as that one is.
- Two rules about `break`/`continue` cannot be stated in the grammar and
  are checked in `src/parser.py` beside the others, so they hold in
  every mode and are reported as a `Parsing error`. First, each may only
  appear in the body of a `loop`, and may not reach out of a `for`, a
  `while` or a `def` to find one:

  ```
  'prog.pyk' 3:8-3:13 Parsing error: 'break' may only appear in the
    body of a 'loop', and this one is inside a 'for', which it may not
    reach out of
  ```

  Second, nothing may be written after one in the same block, since
  nothing there can run:

  ```
  'prog.pyk' 3:4-3:17 Parsing error: this statement cannot be reached:
    'continue x + 1' has already left the loop, so nothing written
    after it in the same block runs
  ```

  A `return` is deliberately not part of that second rule: statements
  after one are legal Pyking, and a branch that returns is an ordinary
  way to leave a body early.
- A `loop_stmt` is a `value_stmt`, so a loop may be bound with `=` or
  returned with `return`, exactly as a value-form `if`/`match` may. It
  needs none of the rules those two obey -- every loop has an
  accumulator (unit where none was written), so there is no way through
  one that produces nothing.
- `comp_op` does not repeat — `1 < 2 < 3` is not a valid `expr` (comparisons
  don't chain).
- `while_stmt` has no `else` clause (unlike Python's `while`/`else`).
- An `if_stmt`'s chain is written `else if`, two ordinary keywords —
  there is no `elif` keyword to reserve. The chained header must be the
  *statement* form, i.e. end in `:`; `else if c then a else b` is an
  error, since an `if_expr` may not start an `else` tail. This makes
  `else if` exactly equivalent to an `else` block holding one nested
  `if_stmt`, and that is how it is parsed: `src/parser.py` builds no
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
  grammar is not LL(1) at `statement`. `src/parser.py` handles this
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
- `assignment` and `return_stmt` accept a `value_stmt`; `var_decl` and
  `mutation` keep taking a plain `tuple_or_expr`, and the parser says so
  explicitly if you try. The value form works by pushing something into
  each branch's tail — an assignment to the target for `assignment`, a
  `return` for `return_stmt` — and both of those are single, unambiguous
  things to push. `var`/`:=` distinguish *declaring* from *updating*,
  and a form that expands to one of them per branch has no way to say
  which of the two each of those is.
- The indented `bound_value`/`bound_expr` form holds exactly **one**
  value: anything left in the block before its DEDENT is an error
  (`expected a single value in the indented block after '='`). It exists
  mainly for a `value_stmt` whose header would otherwise share the `=`
  line, but nothing restricts it to those — `x =` followed by an
  indented `1 + 2` is the same rule, as is `var`/`:=` (both take a
  `bound_expr`: the next-line layout, but no `value_stmt`). Both
  pretty-printers
  normalize it away, printing the value back on the `=` line; the two
  spellings are the same AST.
- A `value_stmt` is rejected in each `bound_expr` position with an error
  naming it (`a 'var' declaration takes an expression; a value-form
  'if'/'match' can only be bound with '='`). A value form binds its
  target in every branch tail, which is what `var` declares and `:=`
  updates — neither of which the branches can decide between.
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
  grammar at all — see the parser module comment in `src/parser.py` —
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
  either; of `then`, which has no Python counterpart at all; and of
  `true`/`false`, which do have a Python counterpart (`True`/`False`) but
  not this spelling of one — a Pyking program cannot use `true`, `false`,
  `True`, or `False` as an identifier (the first two because they're
  keywords, the last two because they're simply unbound: Pyking has no
  binding for Python's capitalised spelling).
- `assignment`'s `[ ":" , type ]` annotates the *binding*, e.g.
  `x: Int = 1`. Like every other annotation it is optional and nothing
  verifies it (see "Type annotations"), but it is the one the type
  checker writes back into: `pyk compile --typecheck --ast` prints each binding
  with the type it inferred, in exactly this syntax, so that output can
  be fed back to the compiler. A destructuring target takes one
  annotation for the whole binding, not one per name.
- `param`'s `[ ":" , type ]` and `function_def`'s `[ "->" , type ]` are
  both optional and independent — a function may annotate none, some, or
  all of its parameters, with or without a return type. Annotations are
  purely syntactic in an ordinary compile: they're parsed, stored in the
  AST, and pretty-printed back out, and every backend erases them
  completely — no generated code carries type syntax at all. Whether
  anything is *verified* against them is a separate question, answered by
  "Type checking" at the end of this reference.
- A tuple `type` with zero elements, `()`, is the Unit type. One with a
  single element, e.g. `(Int)`, is a genuine 1-element tuple type, not a
  parenthesized `Int` — Pyking's type grammar has no parenthesization for
  grouping, so there's no ambiguity to resolve. Tuple and list types can
  nest arbitrarily, e.g. `[(Int, Bool)]` or `(Int, [String], (Bool, Bool))`.
- The trailing `[ "->" , type ]` in `type` is what makes a **function
  type**, `(Int, Bool) -> Int`. The parenthesized list before the arrow
  is the *parameter list*, and the same list without an arrow after it is
  a tuple — which is the whole rule, decided by the one token after `)`.
  So `(Int, Bool)` is a pair, `(Int, Bool) -> Int` takes two parameters,
  and `((Int, Bool)) -> Int` takes one parameter that is a pair. The
  result is a `type` in its turn, so `->` groups to the right:
  `(Int) -> (Int) -> Int` returns a function and needs no parentheses of
  its own. A function type may appear wherever a type may, including
  nested inside list and tuple types — `[(Int) -> Bool]`,
  `((Int) -> Int, Int)` — and as another function type's parameter,
  `((Int) -> Int) -> Int`.
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
  integer, string, or boolean literal matches only that exact value; `_`
  always matches, discarding the value; a plain `ident` also always
  matches, but binds the value to that name; a parenthesized group
  destructures a tuple value element-by-element; a `list_pattern`
  destructures a list value. All of these nest arbitrarily (e.g.
  `case (a, [b, ..c]):`). There's still no support for guards (`if`) or
  or-patterns (`|`).
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
- `block`'s bare-`expr_stmt` alternative is taken **only** when that
  expression begins on the row the header's `:` ends on. The EBNF cannot
  state this, for the same reason it cannot state "a statement starts a
  line of its own": the lexer emits no token for a line break, so both
  are checked in `src/parser.py` against the positions the tokens
  already carry. A block that begins on the *next* line without being
  indented is therefore not an inline block but the error it always was
  (`expected an indented block`).
- It is an `expr_stmt`, not a `statement`: only a value may be written
  there. A `return`, a binding, a `:=`, or a nested header is refused
  where it stands (`a block written on its header's own line must be
  one expression, and 'return a' is not; write it in an indented block
  instead`), so no line ever hides control flow or a new name behind
  its `:`. An `if` written there is the `if_expr`, which is an
  expression; the statement form is not.
- An inline block **ends its line**. Nothing may be indented under it
  (`a block written on its header's own line is the whole block, so
  nothing may be indented under it`), and nothing may continue the
  construct on the same line — an `else` has to start the next one
  (`'else' must start on a new line: the block written on the header's
  own line ends that line`). A second *statement* after it on the line
  is caught by the one-statement-per-line rule instead, since it is a
  sibling of the header rather than part of its block.
- The two layouts are the same program. `def add(a, b): a + b` parses to
  exactly what `def add(a, b):` followed by an indented `a + b` parses
  to, so nothing after the parser can tell them apart — including the
  pretty-printer, which prints every block indented.
- The rule is the *block's*, so it holds wherever a block does:
  `function_def`, `if_stmt` and its `else`, `for_stmt`, `while_stmt`,
  `loop_stmt` and `case_clause`. A `match_stmt`'s clause list is not a
  block and has no inline form.

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

An `Int` is a **signed 32-bit integer**: its values run from
−2 147 483 648 to 2 147 483 647, and `+`, `-` and `*` *wrap* rather than
overflowing, two's complement, so `2147483647 + 1` is −2 147 483 648.
Arithmetic is therefore total — there is no overflow error to handle —
and every result is again an `Int`.

```pyking
biggest = 2147483647
wrapped = biggest + 1     # -2147483648
```

This is what the interpreter implements, and the interpreter is what
defines the language's runtime behaviour. Not every compiler target
enforces the same width — some hosts count wider, and none of them is
made to pretend otherwise; `docs/targets.md` lists which and why. A
program that stays inside 32 bits means the same thing everywhere.

```python
count = 42
message = "hello, pyking"
quoted = 'it\'s a test with a "quoted" word\nand a second line'
print(count, message)
print(quoted)
```

### Boolean literals

`true` and `false` are literals for the two `Bool` values — Pyking
extension, with no Python equivalent, so (unlike every other example in
this section so far) the following is Pyking source, not valid Python:
Python spells the same two values `True`/`False`, capitalised, which
Pyking has no binding for at all (see the grammar notes above). They are
ordinary values, usable anywhere an expression is: bound with `=`,
declared with `var` and updated with `:=`, passed as arguments, returned,
compared with `==`, and so on.

```pyking
done = false
var flag = true

flag := false

print(done, flag)
```

A boolean literal and a comparison that happens to agree with it are
completely interchangeable — `true` is not a different kind of value from
what `1 == 1` produces, just a shorter way to write the same one:

```pyking
print(true == (1 == 1), false == (2 == 3))
```

`true`/`false` may also appear as a `match`/`case` pattern, matching only
that exact value — see ["`match`/`case` pattern
matching"](#matchcase-pattern-matching) below.

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

### Evaluation order

The pieces of an expression are evaluated **left to right**: an
operator's left operand before its right, a call's arguments in the
order they are written, and all of a call's arguments before the call
itself. The whole of the left operand runs before any of the right one
begins, so nesting does not change the rule.

This only matters when more than one piece has an effect — today, when
more than one of them *prints*.

```python
def step(label: String, value: Int) -> Int:
    print("step", label)
    value


sum = step("a", 1) + step("b", 2)
print("sum", sum)
```

```
step a
step b
sum 3
```

A condition is an expression like any other, so a `while` orders its
condition's pieces the same way on every turn. The branches of an
`if`/`then`/`else` expression are the exception that follows from what
`if` means rather than a special case: only the chosen branch runs at
all, and its own pieces then run left to right.

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
body of an `if`/`else` branch, a `for`, `while` or `loop` body, a `case`
arm, a value-form branch — plus a list comprehension and the file's top
level.
Names bound inside a scope are not visible outside it:

```pyking
total = 0

if 1 < 2:
    inner = total + 1
    print(inner)

# `inner` is not in scope here -- using it is a compile-time error.
```

**What binds a name.** An `=` binding, a `var` declaration, a `def` (its
own name, visible throughout the block it is written in — see "Bindings
are sequential — except `def`" below), a parameter, a `for` variable, a
`loop` accumulator, a pattern variable in a `case` arm or
comprehension. All of them behave
the same way with respect to *scope*; they differ only in when within
that scope the name becomes visible.

**Shadowing.** Any of those may reuse a name that is already in scope;
the inner binding wins until its scope ends, and the outer one is
untouched and visible again afterwards. Two `=` bindings of the same name
in one scope are the same thing — the second shadows the first, which is
why a binding may change what a name means (and even its type) without
ever being an update:

```pyking
n = "outer"


def describe(n):
    "param " + str(n)


print(describe(1), n)
```

**A `def`'s name is the exception to that.** Within one block, a
function name means exactly one thing: two `def`s of the same name are
an error, and so is any *other* binding of a name a `def` in that block
uses — in either order, and whatever the binding form:

```pyking
# Each of these is a compile-time error:
#   f = 1              def f(n): n * 2       (a binding and a function)
#   def f(n): n * 2    f = 1                 (the same, written the other way)
#   var f = 1          def f(n): n * 2       (a variable and a function)
#   def f(n): n        def f(n): n * 2       (two functions)
```

This is what makes the next rule safe. A function's name is visible
*throughout* its block, so if the name could also mean something else
there, a use of it would have two candidates and no reason to prefer
either — is `use()` below returning the number or the function?

```pyking
f = 1

def use(): f          # rejected: which `f`?

def f(n): n * 2
```

Nothing forbids the *name*; it forbids sharing a **block**. A nested
block may shadow a function freely, because there the answer is never in
doubt:

```pyking
f = 1


def use():
    def f(): 5        # a different block: this shadows the binding
    return f()


print(use())           # 5
```

**The other restriction:** a `var` may not be shadowed. While a mutable
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

**Bindings are sequential — except `def`.** A scope's names come into
being in the order they are written, so a name must already be bound
where it is used:

```pyking
# total = later + 1     -- error: `later` is not bound yet
later = 41
total = later + 1
```

**Functions are the exception**: every `def` in a block is in scope
throughout that block, from its first line, not from the `def` onward.
That is what makes a function usable before it is written — its own
recursive calls, two functions that call each other, a helper defined at
the bottom of the file — and it is safe to do for a `def` and not for an
`=` binding, because a `def` says what its name means on the `def`
itself, while a binding's meaning is whatever its right-hand side works
out to.

```pyking
def is_even(n):
    if n == 0:
        true
    else:
        is_odd(n - 1)        # written below; in scope anyway


def is_odd(n):
    if n == 0:
        false
    else:
        is_even(n - 1)       # and its own name, so plain recursion too


print(is_even(10), is_odd(10))
```

It applies per block, so a `def` inside a function body — or inside one
branch of an `if` — is in scope for that body or that branch, and
nowhere else. Nested functions may be mutually recursive on exactly the
same terms.

**Only the *names* are visible ahead — not the values.** A function
body sees whatever is bound *where the body is written*. Rebinding a
name afterwards makes a new binding; it does not reach back into a
function that already captured the old one:

```pyking
x = 1


def show() -> Int:
    return x


x = "two"
print(x, show())        # two 1
```

`show` was written where `x` was `1`, so that is the `x` it returns —
even though the name means something else, of another type, by the time
`show` is called. This follows from `=` being a binding rather than an
assignment, and it is what lets the type checker say anything reliable
about a function at all.

The two rules meet like this: the *name* of a `def` written below is
already usable, but the *bindings* it captures are the ones above it:

```pyking
x = 1


def f():
    return g()          # `g` is written below -- fine, it is a function


x = 2


def g():
    return x            # the `x` visible here: the second binding


print(f(), g())         # 2 2
```

A `var` is the deliberate other half: `:=` updates the one binding
rather than making a new one, so a function reading a `var` sees the
updates. That is what a `var` is for.

```pyking
var counter = 0


def read(): counter


counter := 42
print(read())           # 42
```

A loop binds afresh on every turn — its variable and everything in its
body — so a `def` written inside one keeps the turn it was written on,
not the last. Functions written in the same turn that call each other
find each other's copy from that turn, wherever in the body they are
written:

```pyking
var fns = []

for i in range(3):
    def show(): i
    fns := fns + [show]

for f in fns:
    print(f())          # 0, then 1, then 2
```

The design behind these rules, the alternatives, and how other languages
answer the same question are in
[docs/defshadow.md](docs/defshadow.md).

Being *in scope* is not the same as having *run*, though. A function
value comes into being when its `def` is reached, so a call that
executes before that fails at run time, exactly as the same program
would in Python:

```pyking
def top(n):
    helper(n)          # fine: `top` is called below, after both defs


def helper(n):
    n + 1


print(top(1))

# print(later(1))     -- compiles, but fails at run time: `later` has
# def later(n):          not been reached yet
#     n
```

**Checking.** All of this is checked statically, before any code is
generated, and reported as a `Name error` against the offending source
position. A handful of names are predefined and count as bound
everywhere — `print`, `range`, `str` and `len` — since no Pyking program
declares them; every other unbound name is an error. They are host
*operations*, not values: each may be called, and using one as a value
(`f = print`) is an error. `range(n)` yields a list of `Int`, which is
what the language has — there is no lazy-sequence type — though
iterating one with `for` need not build it. `print` produces no
value: it yields unit, `()`, so it is meaningful as a statement and not
as something to bind or return. Unit prints as `()` — the same in every
backend, whatever the host language calls its own absence of a value.

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

A body that is one expression may be written on the header's own line,
after the `:` (see "A block on its header's own line" below). It is the
same body: one statement, in tail position, so it supplies the
function's value exactly as an indented one does. A body that does
anything else — returns, binds a name, branches as a statement — goes
under the header, where it is plain.

```pyking
def average(a, b): (a + b) / 2
def swap(a, b): b, a

print(average(4, 8))
print(swap(1, 2))
```

Annotations are unaffected — the `:` that opens the block is the one
that was always there:

```pyking
def average(a:Int, b:Int) -> Int: (a + b) / 2
```

When the body stops fitting beside the header, indent it under the
header instead. Nothing else changes:

```pyking
def scaled(a, b):
    (a + b) * 2


def sign(n: Int) -> String:
    if n < 0 then "negative" else "positive"


print(scaled(1, 2), sign(-3))
```

### Type annotations

An immutable binding may be annotated on its name, `x: Int = 1`:

```pyking
count: Int = 42
name: String = "pyking"
total: Int = count + 1
```

Parameters and the return value may optionally be annotated with a type:
`Int`, `String`, `Bool`, a list type `[T]`, a tuple type `(T1, T2, ...)`,
or a function type `(T1, T2, ...) -> T` (all nesting freely, e.g.
`[(Int, Bool)]` or `[(Int) -> Bool]`). `()`, the zero-element tuple type,
is the Unit type. Annotations are entirely optional and independent per
parameter/return value — a function can mix annotated and unannotated
parameters freely.

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

**Function types.** `(T1, T2, ...) -> T` is the type of a function, and
may be written wherever a type may. The parentheses are the parameter
*list*'s, not a tuple's, so the count of parameters is what they show: a
function of two parameters is `(Int, Bool) -> Int`, and one of a single
parameter that happens to be a pair is `((Int, Bool)) -> Int`. Without an
arrow after it, the same parenthesized list is an ordinary tuple type.
The result is a type in its turn, so `->` groups to the right and a
function returning a function needs no parentheses of its own.

```python
def inc(n:Int) -> Int:
    return n + 1


def apply(f:(Int) -> Int, x:Int) -> Int:
    return f(x)


# Returning a function: the return type is `(Int) -> Int`.
def stepper(up:Bool) -> (Int) -> Int:
    return inc


# Nested: a list of them, a pair holding one, one taken by another.
def each(fs:[(Int) -> Int], first:((Int) -> Int, Int)) -> Int:
    return apply(inc, 0)


def under(f:((Int) -> Int) -> Int) -> Int:
    return 0


step:(Int) -> Int = inc

print(apply(inc, 1), apply(step, 1), apply(stepper(true), 1))
```

Annotations are parsed and stored in the AST (see `Param`,
`SFunctionDef.return_type` and `SLet.type` in `src/syntax.py`) and
pretty-printed back out in Pyking's own syntax. Compiling erases every
one of them: no generated code carries type syntax at all.

Nothing verifies an annotation in an ordinary compile. There *is* a type
checker, opt-in and covering only part of the language so far; what it
accepts, what it refuses, and which annotations it treats as declarations
rather than as decoration are in "Type checking" at the end of this
reference. How the pass itself is built is a compiler matter, described
in [docs/architecture.md](docs/architecture.md).

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

### `loop` loops -- Pyking extension

`loop` is a loop whose state is a *binding* rather than a mutable
variable, and which is worth something when it stops. Python has no
equivalent, so everything in this section is Pyking source rather than
valid Python.

`loop x = 5:` evaluates `5` once and binds `x` to it for the first turn.
What the body produces -- its value, by the ordinary tail-position rules
-- is the `x` the next turn gets. `break` ends the loop, and the loop is
then worth the accumulator it stopped with:

```pyking
counted = loop x = 5:
    if x <= 10:
        x + 1
    else:
        break

print(counted)          # 11
```

Both keywords take an optional value. `break e` stops the loop with `e`
rather than with the accumulator; `continue e` starts the next turn with
`e`; and a bare `continue` starts it with the accumulator unchanged. The
operand must begin on the same line as the keyword (see the grammar
notes above).

**What a loop carries and what it is worth are two questions.** The
accumulator is the state: the initializer's type, what the body must end
in, and what a `continue` has to give. The loop's *value* is whatever it
`break`s with, which may be something else entirely. Several `break`s
must agree on that one type, exactly as the two branches of an `if`
must -- one value leaves the loop, however many ways out it has (see
"Type checking"). Carrying one type and being worth another is what lets
a loop carrying two values answer with one:

```pyking
def factorial(n, acc) -> Int:
    loop n, acc = n, acc:      # carries (Int, Int)
        if n == 0:
            break acc          # and is worth Int
        else:
            n - 1, n * acc


print(factorial(10, 1))        # 3628800
```

`continue` is what tells the construct apart from a body that simply
ends in an expression: the last expression says "go round with this"
*after* everything else in the body has run, while `continue` says it
from wherever it is written and skips the rest:

```pyking
res = loop x = 5:
    if x <= 10:
        continue x + 1
    p = x + 10
    if p < 30:
        p + 2
    else:
        break

print(res)              # 23
```

**A loop is worth what it breaks with**, so it stands wherever a
value-form `if`/`match` does -- bound with `=`, returned with `return`, or left as
a function's last statement:

```pyking
def doubled_over(limit) -> Int:
    loop n = 1:
        if n > limit:
            break
        else:
            n * 2


print(doubled_over(50))   # 64
```

**Several values are one tuple.** The accumulator is a single value, so
a loop carrying two things carries a pair: the header takes it apart on
every turn, and everything that says what the next turn carries has to
give the whole tuple back.

```pyking
foo, bar = loop x, y = 0, true:
    if x <= 10:
        x + 1, y
    else:
        break x + 100, false


print(foo, bar)         # 111 false
```

**`loop:` carries nothing.** Written with no accumulator it is a loop
over unit: the body runs for what it does, its value is discarded, and
the only way out is a bare `break` -- there is nothing for an operand to
become. Such a loop is worth `()`.

```pyking
loop:
    print("forever")
```

That program is perfectly valid and never finishes, which is the point:
nothing about a loop requires it to end.

**Where `break` and `continue` belong.** Each belongs to the innermost
`loop` it is written in, and may not reach out of a `for`, a `while` or
a `def` to find one -- both checked at compile time (see the grammar
notes). `for` and `while` have no exit of their own, so a `break`
written inside one is an error rather than that loop's exit.

**Scope.** The accumulator is bound in the loop's own body and nowhere
else: it is gone after the loop, and a name it shadows means what it
meant again. Every turn binds it afresh, as a `for` variable is bound
afresh, so a `def` written inside a loop body keeps the turn it was
written on (see "Names and scoping").

```pyking
x = "outer"

shadowed = loop x = 1:
    if x > 2:
        break
    else:
        x + 1

print(shadowed, x)      # 3 outer
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
def sign(x): if x < 0 then "negative" else if x == 0 then "zero" else "positive"


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
print([x for x in [1, 2, 3, 4] if (if x < 3 then true else false)])
```

### `match`/`case` pattern matching

`match expr:` is followed by one or more indented `case pattern:` clauses;
the body of the first case whose pattern matches runs. A pattern is an
integer literal, a string literal, a boolean literal, `_` (always
matches, discards the value), a plain identifier (always matches, binds
the value to that name), or a tuple pattern that destructures a tuple
value element by element (with or without parentheses, nesting
arbitrarily, and sub-patterns can themselves be literals, `_`,
identifiers, or further tuple patterns) — see the grammar notes above for
what isn't supported yet (guards, or-patterns).

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

A boolean pattern matches only that exact value, the same way an integer
or string literal pattern does:

```pyking
def describe(flag):
    match flag:
        case true: "yes"
        case false: "no"


print(describe(1 < 2), describe(3 < 2))
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

A `case` clause opens a block like any other header, so an arm whose
body is one expression can be written on the clause's own line (see "A
block on its header's own line" below). The arm then supplies its value
the way any branch tail does: it is the function's value directly inside
a function, and the bound value when the whole `match` is bound with `=`
(see "`if`/`match` statements as bound values" below). Arms written each
way mix freely within one `match`.

```pyking
def describe(n):
    match n:
        case 0: "zero"
        case 1: "one"
        case _: "many"


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
        case (0, 0): "origin"
        case (0, y):
            side = if y > 0 then "up" else "down"
            "on the y axis, " + side
        case (x, y): "at " + str(x) + "," + str(y)
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
        case 7: "seven"
        case _: "big"
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
        case 2: "hi"
        case xx: str(xx)

print(z)
```

This is just a layout choice, not a different construct: it applies to
any bound value (an ordinary expression, and `var`/`:=` too), and both
pretty-printers print it back on the `=` line, since the two spellings
produce the identical AST.

### Expression statements

Any expression, most commonly a function call, may be used directly as a
statement. Its value is discarded — *unless* the statement is in **tail
position**, where it becomes the enclosing function's return value (see
"Tail position" below).

```python
print("hello, pyking")
```

### Tail position

A function body's **last statement is in tail position**, and whatever
value it produces is the function's result — there is no need to write
`return` for it. The rule is recursive, so it reaches through branches
rather than only the outermost statement:

| last statement | the function's value |
|---|---|
| an expression | that expression |
| an `if`/`else` | each branch's own tail, recursively |
| a `match` | each `case` arm's own tail, recursively |
| a `loop` | the accumulator it broke with |
| an explicit `return` | what it returns |
| anything else (`for`, `while`, `=`, `var`, `:=`) | unit, `()` |

```pyking
def add(x, y):
    x + y


def pick(x, y, z):
    if z > 5:
        x + y
    else:
        2 * x


def name_of(n):
    match n:
        case 0: "zero"
        case _:
            "many"


print(add(1, 2), pick(2, 3, 9), name_of(0))
```

Because the rule recurses, an `if` nested inside a `match` nested inside
an `if` needs nothing special: every branch of every level is itself in
tail position. An `else if` ladder works for the same reason — a ladder
*is* a nested `if` in the else branch (see "`if`/`else` statements").

Only the **last** statement is in tail position. An `if` with something
after it is an ordinary statement run for its effect, and the trailing
expression is the value:

```pyking
def not_last(n):
    var acc = 0
    if n > 0:
        acc := 1
    else:
        acc := 2
    acc + 10


print(not_last(1))
```

A branch that produces no value simply does not return one, and the
function yields unit for that path — an `if` with no `else`, or a body
ending in a loop:

```pyking
def only_then(n):
    if n > 0:
        "positive"


print(only_then(1), only_then(-1))
```

### Tail calls

A call in tail position is one nothing is waiting for: its answer is the
answer. So a function that calls *itself* in tail position is a loop
written as a recursion, and Pyking runs it as one -- the compiler
rewrites it into a `loop` carrying the parameters. A tail-recursive
function therefore runs in constant space on every target and in the
interpreter, however deep it goes:

```pyking
def climb(x):
    if x >= 20000:
        1000 + x
    else:
        climb(x + 1)       # a tail call: nothing waits for it


print(climb(0))            # 21000, in one frame
```

Functions that tail-call *each other* get the same treatment: the group
becomes one loop they share, as wide as its widest member. Nothing about
this changes what a program means -- only how much room it needs to
run -- and `pyk --no-tail-call-opt` turns it off, which is worth doing
only to read a program back as it was written.

The rewrite applies to programs the **type checker accepts**: what a
group can share, and what a slot one member has no argument for is
entered with, are questions about types. A program outside that fragment
(see "Type checking") is compiled as written and recurses as any other
language would. What counts as a tail call, what is left alone and why,
are in [docs/optimization.md](docs/optimization.md).

A call that is *not* in tail position is an ordinary recursion and stays
one: in `n * factorial(n - 1)` the multiplication is still waiting, so
there is nothing to turn into a loop.

### `return` with an `if`/`match`

`return` also accepts a value-form `if`/`match` directly, so each
branch's tail expression becomes the returned value. This says
explicitly what tail position says implicitly — and, unlike the implicit
rule, it works *before* the end of a body:

```pyking
def sign(x):
    return if x < 0:
        "negative"
    else:
        "not negative"


def classify(n):
    return match n:
        case 0: "zero"
        case _: "many"


print(sign(-2), classify(0))
```

The same two rules a value-form binding obeys apply here: a `return if`
must have its `else`, and every branch must end in an expression — there
would otherwise be a path with nothing to return.

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

### A block on its header's own line

Any header ending in `:` may carry its block on that same line instead
of indenting it, provided what it carries is **one expression**. Python
allows something similar but wider — any *simple* statement, and `;` to
write several; Pyking's line holds a value and nothing else.

```pyking
def square(x): x * x
def twice(x): x + x

if square(3) > 5: print("big")
else: print("small")

for i in range(3): print(i)
```

**It is the same program either way.** `def square(x): x * x` parses to
exactly what

```pyking
def square(x):
    x * x
```

parses to — one block, one statement — so nothing after the parser can
tell which was written, and the pretty-printer prints both indented. The
form is a layout, not a second kind of definition: what the body means,
where its names come from, whether its last expression is in tail
position (it is) are all unchanged.

It works for every header, because the rule belongs to the *block*:
`def`, `if` and its `else`, `for`, `while`, `loop`, and a `case` clause.

```pyking
def name_of(n):
    match n:
        case 0: "zero"
        case 1: "one"
        case _: "many"


print(name_of(0), name_of(7))
```

A `match`'s clause list is the one thing that looks like a block and is
not one: `match e:` opens a list of `case` clauses rather than a list of
statements, and a clause is not an expression, so there is nothing its
line could carry. The clauses are always indented under it.

#### What may be written there

An **expression**, and only an expression. A `return`, an `=` binding, a
`:=` mutation, or a nested header is not one, and is refused where it
stands:

```
'prog.pyk' 4:14-4:22 Parsing error: a block written on its header's
  own line must be one expression, and 'return a' is not; write it in
  an indented block instead
```

That is the whole point of the restriction. A line ending in `:` is a
promise that a value follows; letting a statement follow instead would
mean control flow and new names could hide behind a `:` at the end of a
line, and every such line would have to be read to the end to find out
what it did. So the value-producing forms stay on one line and
everything else goes under its header:

```pyking
def first_positive(a, b):
    if a > 0:
        return a
    b
```

Note that a function ending in a value needs no `return` at all (see
"Tail position"), so the shorthand is rarely what a one-line body wanted
in the first place. And `if` written inline is the `if`/`then`/`else`
*expression*, which is an expression like any other:

```pyking
def describe(n): if n < 0 then "negative" else "positive"
```

#### The line ends there

An inline block is the end of its line, and two rules follow. Each is
reported where it is written:

- **Nothing may be indented under it.** The header's line already held
  the block, so an indented line after it belongs to nothing — `if c:
  print(1)` with a second `print` indented below is refused rather than
  read as a two-statement body.
- **Nothing may continue the construct on that line.** An `else`
  belonging to the `if` starts the *next* line (see below).

So an `if` and its `else` each carry their own line:

```pyking
x = 2

if x > 1: print(7)
else: print(8)
```

Written `if x > 1: print(7) else: print(8)`, one line would hold an
`if`, its whole then-block, and the start of another block; that is the
run-on the one-statement-per-line rule exists to prevent, and it is
refused (`'else' must start on a new line: the block written on the
header's own line ends that line`). The same holds for an `else if`
rung.

A second *statement* sharing the line is caught by that
one-statement-per-line rule itself (see "Indentation-based blocks"
above): `if c: print(1) print(2)` puts the second `print` beside the
`if`, not inside it.

A block that begins on the *next* line without being indented is neither
form, and is the error it always was — `expected an indented block`.

## Type checking

Pyking's static semantics come in two layers. One is always on and is
about *names*; the other is about *types*, and today it is opt-in.

**Always checked**, in every mode and for every target — including
`--ast`, since a program whose names do not resolve is not worth
printing either:

- the shape rules the grammar cannot state: a value-form `if` must have
  its `else` and every branch must end in an expression (see the section
  on `if`/`match` statements as bound values), and a `case` pattern may
  not bind the same name twice. These are reported as `Parsing error`.
- names and scoping: every name must be bound where it is used, and a
  `var` may not be shadowed (see "Names and scoping"). These are
  reported as `Name error`.

**Checked only under `--typecheck`**: everything below. Without that
flag no type is ever verified — annotations are parsed, pretty-printed
and then erased, and each backend infers for itself whatever the target
language forces it to (which is why a program can be rejected by the C
or Java backend and accepted by the Python one). With the flag, the
program is type-checked before anything is printed or compiled, and a
failure is reported as `Type error` and stops the compile.

The checker covers a *fragment* of the language, and refuses everything
else rather than guessing:

```
'prog.pyk' 4:8-4:13 Type error: Construct is not supported
```

That is deliberate. A checker that quietly accepted what it had not
reasoned about would be worse than one that says where it stops — so
the list below is a floor that grows, not a description of what will
always be refused.

### Types

The checker works in the types "Type annotations" lists, and no others:
`Int`, `String`, `Bool`, list types `[T]`, tuple types `(T1, T2, ...)`
— with `()`, the zero-element tuple, as the unit type — function types
`(T1, T2, ...) -> T`, and *alternative* types `T1 | T2`.

An alternative type is a value that is one of several: `Int | String` is
satisfied by an integer and by a string, and by nothing else. It is
written with `|`, which binds looser than everything else a type is
built from, so a function alternative needs its own parentheses:

```pyking
first: Int | String = 41
second: Int | String = 'forty-two'


def render(value:Int | String) -> String:
    str(value)


print(render(first), render(second))
```

A builtin accepts an alternative type when it accepts every one of the
alternatives — `str` above takes `Int | String` because it takes each of
them. An operator does not: `+` needs to know which signature it is,
and `Int | String` is not one of them. There is no narrowing, and there
are no type variables; alternatives are the whole of what the language
can say about "one of these".

The function type is the one a program rarely writes but the checker
constantly infers, since it is what a `def`'s *name* means. So it is
what `pyk compile --typecheck --ast` prints for a name bound to a function,
whether or not the source said so:

```pyking
def choose(a:Int, keep:Bool) -> Int:
    if keep:
        return a
    else:
        return 0


picker = choose      # picker: (Int, Bool) -> Int
```

Two types are the same type when they have the same structure; where
they were written, and whether one was written at all, does not enter
into it. So a parameter annotated `(Int) -> Int` accepts any function of
that shape, and rejects `(Int) -> Bool`.

### What is checked

**Literals and names.** `1` is `Int`, `'s'` is `String`, `true` and
`false` are `Bool`. A name has the type of the binding it refers to,
under Pyking's ordinary lexical scoping.

**Operators.** Both operands must match the *same* signature:

| operator | accepts | gives |
|---|---|---|
| `+` | `Int + Int` | `Int` |
| `+` | `String + String` | `String` |
| `-`, `*` | `Int`, `Int` | `Int` |
| `<`, `<=`, `>`, `>=` | `Int`, `Int` | `Bool` |
| `==` | two `Int`s, two `String`s or two `Bool`s | `Bool` |

So `1 + 'a'` is an error, and so is `1 == 'a'` — a comparison of two
different types is refused rather than answered `false`.

**Bindings and expression statements.** An `=` binding takes the type of
its right-hand side, and that is what its name means to the statements
that follow. An expression statement has its expression's type, which is
what lets a block yield a value.

A binding that *annotates* itself is checked against that annotation —
an annotation is a claim about the program, and where one is written it
is verified rather than replaced, which is the whole difference between
an annotation and a comment. Both forms of binding are checked, the
ordinary one and the value form:

```pyking
def foo(x:Int, y:Int) -> Int: x + y


ok:(Int, Int) -> Int = foo      # fine
# f:(Int, String) -> Int = foo  # error: foo is (Int, Int) -> Int
# n:String = 1 + 2              # error: the value is an Int
```

```
'prog.pyk' 3:2-3:22 Type error: this binding is annotated (Int,
  String) -> Int, but its value has type (Int, Int) -> Int
```

A binding with no annotation claims nothing and takes whatever its value
has; `--typecheck --ast` then prints the type that was worked out, which
is what makes that output worth reading.

**Blocks and `if`.** A block's type is its last statement's, and unit if
it is empty. The two branches of an `if` must have the *same* type —
which is what makes `x = if ...` sound, since only one branch runs but
the binding has one type either way:

```pyking
flag = 3 < 4

best = if flag:      # both branches yield Int
    1
else:
    2

if flag:             # both branches yield unit
    a = 1
else:
    b = 'two'
```

The **expression** form is checked the same way, and always yields a
value: its `else` is mandatory, so there is no way through it that
produces nothing, and its two branches must agree on a type just as a
statement's do. It is an expression like any other — an argument, an
operand, the right-hand side of a binding, or the whole body of a
function:

```pyking
def fact(n): if n <= 1 then 1 else fact(n - 1) * n


picked = if 3 < 4 then 10 else 20
print(fact(7), picked, 'grade ' + (if picked > 5 then 'a' else 'b'))
```

An `if` with no `else` supplies unit, whatever its one branch ends in:
there is a way through such a statement that runs no branch at all, so
there is no value it can be counted on for. A function that needed that
value is refused where the value was needed — at the function, not at
the `if`. A condition must be `Bool` — there is no truthiness.

**Tuples.** `(e1, e2, ...)` has the tuple type of its elements, `()` is
unit, and a binding may take one apart -- `a, b = pair` binds each name
to its part, and is refused if the value is not a tuple of that many.

**Loops.** A loop is checked as two questions. What it *carries* is the
accumulator's type: its initializer's, which an annotation on the header
is checked against exactly as a binding's is, and which the body's own
value and every `continue e` must give. What it is *worth* is what its
`break`s give -- all of them the same type, with a bare `break` giving
the accumulator and taking part in that agreement like any other:

```pyking
counted = loop x = 1:      # carries Int
    if x > 3:
        break "far enough" # and is worth String
    else:
        x + 1              # the body still gives an Int
```

Two `break`s that disagree are refused, and the message points at the
second one -- where the disagreement is found:

```
'prog.pyk' 22:8-22:17 Type error: this loop is worth Int, from an
  earlier 'break', but this 'break' gives String
```

That rule is about the `break`s agreeing with each other, not with the
accumulator, so a loop carrying nothing is held to it just the same.

`break` and `continue` supply the accumulator's type wherever they
stand, exactly as `return` supplies the function's -- which is what lets
a branch that breaks sit beside one that ends in the next accumulator
without either being a special case. A body that ends in something with
no value is refused, since a turn would then have nothing to hand on:

```
'prog.pyk' 12:4-12:12 Type error: this loop carries Int, so its body
  must end in a value of that type -- the accumulator for the next
  turn -- but it ends in ()
```

A loop with **no `break` at all** never finishes, so it is worth nothing
that anything can be wrong about: a function whose body is such a loop
honours whatever return type it declares, since it never reaches one.

A `loop:` with no accumulator carries unit and discards its body's
value. `()` is therefore the only operand its `continue` may have, and
one that gives anything else is refused -- while its `break` may still
carry the loop's answer, which is a different question from its state:

```
'prog.pyk' 3:13-3:14 Type error: this loop carries no accumulator, so
  its 'continue' takes no value
```

**Functions.** A `def` that is *fully* annotated — every parameter and
the return type — is checked where it is written. One that is not is
checked where it is *called*, and by exactly the same rules; see
"Functions without annotations" below. Either way, its type is the
function type above, and:

- every `return` must give the declared return type;
- the body must *produce* that type, either by returning on every path
  or by ending in a value of it — the two ways "Tail position"
  describes, and a body that does neither does not honour its own
  annotation;
- a call must give as many arguments as there are parameters, each of
  the parameter's type, and the call has the return type.

**Tail position is checked as the language defines it**: the body's last
statement supplies the function's value, recursively through branches,
with no `return` written. So this checks, and `scale` returns `Int`
because both branches of its one statement do:

```pyking
def scale(x:Int, factor:Int) -> Int:
    if x * factor == 4:
        8
    else:
        9
```

The two ways mix, because the checker asks every statement the same
question "Tail position" asks — *what value do you supply?* — and a
`return` answers with what it returns, which is exactly what that
section's table says of it. So a branch that returns and a
branch that ends in an expression are comparable, and one may return
while the other supplies the value:

```pyking
def size(n:Int) -> Int:
    if n > 0:
        return n
    else:
        0 - n
```

A body that ends in a value of the *wrong* type is an error, and so is
one that ends without producing anything at all:

```
'prog.pyk' 2:4-2:8 Type error: 'f' returns Int, but its body ends in a
  value of type String
'prog.pyk' 1:0-3:16 Type error: 'f' returns Int, so its body must
  return on every path, or end in an expression of that type
```

**A body is checked where it is written.** The checker reads a `def`'s
body in the environment at that `def`'s own position, which is what the
language says the body captures — so what it checks is what runs:

```pyking
x = 1

def show() -> Int:
    x

x = 'two'          # fine: `show` was checked against the Int above
```

**Recursion and forward references check like anything else.** Every
`def` in a block is declared before any of the block is checked (see
"Names and scoping"), so a body has a type for its own name, for its
siblings', and for functions written below it — and a recursive or
mutually recursive call is then checked against that type like any other
call, argument by argument:

```pyking
def spell(n:Int) -> String:
    if n < 1:
        ''
    else:
        'x' + spell(n - 1)          # checked against (Int) -> String


def is_even(n:Int) -> Bool:
    if n == 0:
        true
    else:
        is_odd(n - 1)               # declared below, and known here


def is_odd(n:Int) -> Bool:
    if n == 0:
        false
    else:
        is_even(n - 1)
```

Nothing is taken on faith: the declared type is what the body is checked
*against*, and a body that does not honour it is refused. The same
applies to nested functions, per block.

**Builtins.** `print`, `range`, `str` and `len` are checked at the call,
each by its own rule, because none of them is a function *value*: a
builtin is a host operation (see "Names and scoping"), it has no type
that can be written down, and it may be called and nothing else.

| call | accepts | gives |
|---|---|---|
| `print(…)` | any number of arguments, of any type | `()` |
| `str(x)` | one `Int`, `String` or `Bool` | `String` |
| `len(x)` | one list or `String` | `Int` |
| `range(n)` | one to three `Int`s | `[Int]` |

```pyking
count = len("hello")          # Int
label = "n = " + str(count)   # String
numbers = range(4)            # [Int]

print(label, numbers, count)  # anything, any number of them
```

Using one as a value rather than calling it is an error — `shout = print`
is refused — which is also what the C and Java backends do with `print`.

Anything of function type may be called, not only a `def`'s own name, so
a parameter annotated with a function type is callable inside the body
and higher-order functions check like anything else:

```pyking
def inc(n:Int) -> Int:
    return n + 1


def twice(f:(Int) -> Int, x:Int) -> Int:
    return f(f(x))


answer = twice(inc, 5)      # answer: Int
```

Both body forms are checked the same way, and a function's parameters
are in scope only in its own body:

```pyking
def sign(n:Int) -> String:
    if n < 1:
        return 'small'
    else if n == 1:
        return 'one'
    else:
        return 'large'


def shout(word:String) -> String: word + '!'


kind = sign(4)
loud = shout('hi')
```

### Functions without annotations

A `def` that did not write its type down is not checked where it is
written. It is checked the first time something **calls** it, with its
parameters taken from that call — so the annotations a program leaves
out are supplied by its own use of the function, and everything above
applies unchanged:

```pyking
def double(n):
    n * 2                    # nothing is checked here ...


doubled = double(21)         # ... here: n is Int, so double is (Int) -> Int
```

Three rules follow from "checked at the call", and they are the whole of
what a program has to know:

**An annotation that *is* written is still a claim.** A half-annotated
`def` is checked against what it did say, at every call, exactly as a
fully annotated one is. Only what it left out comes from the call:

```pyking
def scale(n:Int, factor):    # `n` is a claim; `factor` is a question
    n * factor


print(scale(6, 7))
# print(scale('six', 7))     # error: argument 1 has type String, but
                             #        Int was expected
```

**A body is still checked where it is written.** The call decides what
the parameters are; it does not decide what else is in scope. A body
that names something bound *after* the `def` is an error, however late
the call comes:

```pyking
def f(n):
    n + offset               # error: unbound name 'offset'


offset = 10
print(f(1))
```

**A function used at two types is checked twice**, once each way, and
each call has the type its own arguments give it. Such a function has
*two types*, and that is what it is — one alternative per shape of call,
each keeping its own parameters and result together, since Pyking has no
type variables:

```pyking
def echo(x):
    x


number = echo(1)             # number : Int
word = echo('two')           # word   : String
same = echo                  # same : ((Int) -> Int) | ((String) -> String)
```

The alternatives are not interchangeable: `((Int, Int) -> Int) |
((String, String) -> String)` accepts two Ints or two Strings, and
refuses one of each — which a single `(Int | String, Int | String) ->
Int | String` would have allowed. A `def` with several types is printed
as it was *written* by `--typecheck --ast`, since a `def` header has one
slot per parameter and no way to say which result goes with which; bind
it to a name to see the whole type.

**Recursion needs a value on some path.** A recursive call cannot be
typed while the type it would give is still being worked out, so the
checker takes the answer from the paths that do *not* recurse and then
checks the whole body against it. A function whose every path recurses
has nothing to be worked out from, and is refused:

```pyking
def fact(n):                 # fine: the first branch says Int
    if n < 1:
        1
    else:
        n * fact(n - 1)


# def forever(n):            # error: cannot work out what 'forever'
#     forever(n + 1)         #        returns: every way through its
                             #        body calls it again
```

Annotating the return type removes the question entirely, and is the
answer for a function that genuinely has no non-recursive path.

**Two functions of unknown type are indistinguishable**, so an `if` that
yields one of them is refused: nothing could say which of the two a
later call would be checking. Annotating either one settles it.

Which functions ended up with which types is what
`pyk compile --typecheck --ast` prints, and is the best way to see what
was worked out — the reasoning behind all of this is in
[docs/type_inference.md](docs/type_inference.md).

### What is not checked

**Constructs outside the fragment.** `var` and `:=`, `for`, `while`,
`match`, list literals, list comprehensions, `/` and unary minus are all
refused with `Construct is not supported`. A call to a builtin *is*
checked — see below.

**Names, while `--typecheck` is on.** The type checker replaces the name
analysis rather than running after it, and does that checking itself:
its environment *is* the scope, so it applies the rules under "Names and
scoping" — a name must be bound where it is used, a block's bindings do
not escape it, a name is visible only after its own binding *unless it
is a `def`*, an inner binding shadows an outer one, a `def` may not
share its name with another binding of its block, and the builtins are
in scope throughout. An unbound name is reported
exactly as it is without the flag:

```
'prog.pyk' 14:16-14:23 Name error: unbound name 'missing'
```

The one rule that is *not* applied in this mode is the mutable one: a
`var` may not be shadowed. This checker does not cover `var` at all, so
there is nothing for that rule to protect here; compiling without
`--typecheck` applies it as usual.

A name may be in scope and still have no type the checker knows — a
builtin, or a function's own name inside its own body. Using one is
refused as `Construct is not supported` rather than as an unbound name,
since the name is perfectly well bound; it is the *type* that is
missing.
