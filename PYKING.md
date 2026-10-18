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
- **Modules that export nothing by default**: a file is a module, and a
  name in it is private until `public` is written in front of it —
  the opposite of Python, where every top-level name of an imported
  module is reachable. The import forms look like Python's
  (`import m`, `import m as n`, `from m import a, b as c`), with no
  `import *`: every name a module reaches is written down. Circular
  imports are a compile-time error rather than a run-time surprise, so
  the modules of a program run in one order, each after everything it
  imports. See "Modules".
- **Submodules by dotted names**: `def mymod.foo(...)` defines `foo` in
  the submodule `mymod` of its file, reached as `hello.mymod.foo`, or
  with `from hello import mymod` or `from hello.mymod import foo`; there
  are no package folders or `__init__` files. `import hello.mymod` binds
  `mymod` rather than `hello`. See "Submodules".
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
- **`let` expressions**: `let x = 78 in x + 1` binds a name — or takes a
  tuple apart — for one expression, its body, and is worth the body.
  Python has no counterpart (its nearest is the `:=` operator, which
  binds in the enclosing scope instead). `let` is a new keyword, so it
  is reserved everywhere. See "Let expressions".
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
  first turn, and what the body ends in is the `x` the next turn gets,
  so a loop needs no mutable variable to add something up. A loop is
  *worth* the accumulator it stopped with -- which makes it usable as a
  bound value -- or unit where it carries none. `break` ends it and
  `continue` starts the next turn early; neither takes an operand, since
  the accumulator has already said everything there is to say. See
  "`loop` loops" below.
- **`..`/`..name` list-pattern rest markers**: Python spells "match the
  rest of a list" as `*_`/`*name`; Pyking spells it `..`/`..name`, and it
  may appear anywhere in the pattern — start, middle, or end — not just
  once in a fixed position, e.g. `case [first, ..rest]:` or
  `case [a, b, ..middle, z]:`.
- **Datatypes**: `datatype Tree(a):` declares an algebraic data type,
  its constructors on indented lines or after its `:`, several to a
  line separated by commas, each with its fields -- positional, named,
  defaulted -- and a value is built by calling a constructor with the
  rules a call to a `def` follows (`Leaf(7, age = 100)`). Python's
  nearest is a class per constructor; a datatype is one type, its
  constructors are its only values, and `match` takes them apart. See
  "Datatypes".
- **Structs**: `struct Point(x: Int, y = 78)` is a datatype of one
  constructor, and `Point(x = 5, ..p)` builds a copy of `p` with `x`
  changed. Python's nearest is a frozen dataclass and
  `dataclasses.replace`. See "Structs".
- **Uppercase is for types and constructors**: every name a program
  binds starts with a lowercase letter or `_`, so a constant is
  `pi = 3.14` rather than Python's `PI = 3.14`, and an uppercase name is
  always a type or a constructor.
- **Every `match` matches every value**: a `match` that some value
  reaches no case of is refused at compile time, naming a value it
  misses, and so is a case no value can reach. Python's `match` quietly
  does nothing for a subject no case takes. See "Exhaustiveness".
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
- Float literals (`1.0`, `0.5`, `1e9`, `1.5e-3`) — IEEE 754 binary64,
  with a digit required on each side of the point
- Boolean literals (`true`, `false`) — Pyking extension; spelled
  lowercase, unlike Python's `True`/`False`
- Variables (identifier references)
- Arithmetic operators (`+`, `-`, `*`, `/`), overloaded over `Int` and
  `Float`, unary minus (`-x`, and negative literals like `-5`), and
  parenthesized expressions. Nothing is converted implicitly: `float(n)`
  and `int(x)` are how the two numeric types meet
- Conversions `string(x)`, `int(x)`, `float(x)` and `bool(x)` between
  `Int`, `Float`, `String` and `Bool`, each answering a default (0, NaN,
  false) where there is no right answer (see "Conversions")
- Concatenation (`++`) for strings and lists — Pyking extension; a
  separate operator from `+`, which only ever adds
- Comparison operators (`<`, `<=`, `>`, `>=`, `==`)
- Type variables (`def id(x:a) -> a`) and `all` quantifiers, including
  first-class polymorphism — Pyking extension; a `def`'s type may also
  be written on a line of its own (`def id : (a) -> a`)
- Function calls, whose arguments may be **named** after the parameters
  they fill (`box(width = 4, depth = 6)`) where the callee is a `def`
  this module can see — Pyking extension (see "Named arguments")
- Qualified names (`m.f`) — Pyking extension; a public name of an
  imported module, reached through the name that module was imported
  under (see "Modules")
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
- **Lambdas** (`x => x + 1`, `(x, y) => x + y`) — Pyking extension; an
  expression that is a function, whose body is one expression. A lambda
  is monomorphic; `def` is how a polymorphic function is written (see
  "Lambdas")
- **Let expressions** (`let x = 78 in x + 1`, `let (a, b) = pair in a + b`)
  — Pyking extension; one binding, seen by the body alone (see "Let
  expressions")
- **Static overloading** (`def int::leq(...)`, `def float::leq(...)`) —
  Pyking extension; a qualifier makes two definitions of one base name
  distinct, and a call written without it is resolved by its arguments
  (see "Static overloading")

Statements:

- Immutable bindings (`=`), with an optional type annotation on the
  name (`x: Int = 1`), which may destructure a tuple value into
  several names at once (e.g. `a, b = 1, 2` or `(a, (b, c)) = pair`),
  and whose right-hand side may be an `if`/`match` *statement* in value
  form (`x = if cond:` / `x = match e:`) — Pyking extension
- Mutable variables (`var` and `:=`) — Pyking extension
- **Default parameters** (`def greet(who: String = "world"):`), used
  when a call leaves that argument out; the default is an expression
  evaluated in the scope the `def` is written in, at each call that
  omits it — Pyking extension (see "Default parameters")
- **Implicit parameters** (`def foo(x: a, implicit bar: (a) -> b)`),
  filled from the calling context by name and by type where a call
  leaves them out; `implicit` in front of a `def` or an `=` binding is
  what makes one findable — Pyking extension (see "Implicits")
- Function definitions (`def`), with optional parameter and return type
  annotations (`Int`, `Float`, `String`, `Bool`, list types `[T]`, tuple types
  `(T1, T2, ...)` including the singleton `(T,)` and the unit type `()`,
  function types
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
  worth it when they stop, with `break` and `continue` (neither taking
  an operand) -- Pyking extension
- `if`/`else` statements, chained with `else if` — spelled as two
  keywords; Pyking has no `elif`
- `match`/`case` pattern matching, including tuple patterns
  (`case (a, b):`), list patterns (`case [a, ..rest]:`, or the same
  written `[a] ++ rest`; `"get " ++ rest` splits a string) and
  constructor patterns (`case Leaf(v, age = n):`) that destructure a
  tuple, a list or a datatype's value
- **Datatypes** (`datatype Shape: Circle(radius: Float) / Square(Float)`),
  with type parameters (`datatype Tree(a):`), fields that are
  positional, named or defaulted, and constructors applied with a
  call's rules; a named field is read with `.` (`p.x`) — Pyking
  extension (see "Datatypes")
- **Structs** (`struct Point(x: Int, y = 78)`), datatypes of one
  constructor, and updates (`Point(x = 5, ..p)`) — Pyking extension (see
  "Structs")
- Patterns of every kind may be combined with `|` (`case 1 | 2:`), bind
  the whole value as well with `as` (`case Node(l, r) as whole:`), and
  carry a guard (`case n if n > 0:`); every `match` matches every
  value, and every case is reachable (see "Exhaustiveness")
- Expression statements
- Output with `print`, and diagnostic output with `debug` — Pyking
  extension; `debug` writes the way `print` does, where diagnostics go,
  and a program built in release mode has none of it (see "Builtins"
  under "Type checking")
- A block written on its header's own line (`def f(x): x * x`,
  `if c: print(1)`, `case 0: "zero"`) — one expression, meaning exactly
  what the indented form means
- Imports (`import m`, `import m as n`, `from m import a, b as c`) and
  exports (`public` in front of a `def`, a `def` signature line, a
  `datatype`, a `struct`, or an `=` binding) — Pyking extension; both belong to a module's top level,
  and there is no `import *` (see "Modules")

Structure:

- Left-to-right evaluation: an operator's operands and a call's
  arguments run in the order they are written -- named arguments
  included, whatever order the parameters are in -- and all of a call's
  arguments before the call (see "Evaluation order")
- Indentation-based blocks, with a line continued while a bracket is
  open (see "Lines and continuation")
- Lexical scoping, with every block a scope, free shadowing of immutable
  names, and no shadowing of a mutable one — checked statically by
  (see "Names and scoping")
- Lexical scoping with `def` *names* visible throughout their block, so
  functions may be recursive, mutually recursive, or called before they
  are written — while what a body *captures* is what is bound where the
  body stands; every other binding stays sequential, and a `def` may not
  share its name with another binding of the same block (see "Names and
  scoping")
- Statically typed: every program is type-checked, whatever is then done
  with it, and a type error stops the compile (see "Type checking")
- One file is one module, exporting only what it marks `public`, and a
  program is the acyclic graph of the modules its main file reaches —
  each running its own top level before anything that imports it (see
  "Modules")

## Grammar

EBNF for the subset currently accepted by `parse()` in `src/parser.ml`.
`INDENT`/`DEDENT` are not literal characters — they are synthesized by the
lexer from 4-space indentation changes (see "Indentation-based blocks"
below). Comments are stripped by the lexer and don't appear here.

```ebnf
(* An import and a `public` belong to a module's top level, so they are
   here rather than in `statement`, which is what a block holds. *)
program     = { top_statement } ;
top_statement = import_stmt
            | from_stmt
            | public_stmt
            | datatype_stmt
            | struct_stmt
            | statement ;

import_stmt = "import" , module_item , { "," , module_item } ;
module_item = module_path , [ "as" , ident ] ;
from_stmt   = "from" , module_path , "import" , field_item , { "," , field_item } ;
(* A module, or a submodule of one: `hello`, `hello.mymod`. *)
module_path = ident , { "." , ident } ;
field_item  = ident , [ "as" , ident ] ;
public_stmt = "public" , ( function_def | function_sig | datatype_stmt
                          | struct_stmt | assignment ) ;

(* A datatype belongs to a module's top level. Its name and every
   constructor's start with an uppercase letter; its parameters are type
   variables. Its constructors follow the ':' on its own line, or on
   indented lines under it, or both; a line holds one or more,
   separated by commas. *)
datatype_stmt = "datatype" , [ sub_path , "." ] , upper_ident , [ "(" , type_var , { "," , type_var } , ")" ] ,
                ":" , ( constructor_line , [ INDENT , { constructor_line } , DEDENT ]
                      | INDENT , constructor_line , { constructor_line } , DEDENT ) ;
constructor_line = constructor , { "," , constructor } ;
constructor = upper_ident , [ "(" , [ field , { "," , field } ] , ")" ] ;
(* A field is a type alone (positional only), or named; a named field's
   type may be left to its default. Unnamed fields come first, and every
   field after one with a default has one too. *)
field       = type
            | ident , ":" , type , [ "=" , expr ]
            | ident , "=" , expr ;
upper_ident = ? an ident beginning with an uppercase letter ? ;

(* A struct is a datatype of one constructor, named as the type is. Its
   fields are in parentheses on its own line -- every type variable they
   name is then a parameter -- or on indented lines under its ':', a
   line holding one or more separated by commas, after the parameters
   written in parentheses. With neither it has no fields. *)
struct_stmt = "struct" , [ sub_path , "." ] , upper_ident ,
              [ "(" , [ field , { "," , field } ] , ")"
              | [ "(" , type_var , { "," , type_var } , ")" ] , ":" ,
                INDENT , field_line , { field_line } , DEDENT ] ;
field_line  = field , { "," , field } ;

(* A block is indented under its header, or is the single expression
   written on the header's own line -- which the EBNF cannot say, since
   it cannot see where a line ends; see the notes below. *)
block       = INDENT , { statement } , DEDENT
            | expr_stmt ;

statement   = function_def
            | function_sig
            | return_stmt
            | loop_stmt
            | break_stmt
            | continue_stmt
            | if_stmt
            | match_stmt
            | var_decl
            | assignment
            | mutation
            | expr_stmt ;

(* `implicit` marks a definition an implicit argument may be resolved
   to; a definition's own name may carry a `::` qualifier, which is what
   makes two definitions of one base name distinct. *)
function_def = [ "implicit" ] , "def" , def_name ,
               "(" , [ params ] , ")" , [ "->" , type ] , ":" , block ;
(* The second form names its parameters; it ends its line, every
   parameter has a type and none a default, and it means the first form
   with the parameter types in order. *)
function_sig = "def" , def_name , ":" , type
             | "def" , def_name , "(" , [ named_type , { "," , named_type } ] ,
               ")" , "->" , type ;
named_type   = ident , ":" , type ;
(* A dotted name defines in a submodule: `mymod.foo`, `mymod.deep.foo`. *)
def_name     = [ sub_path , "." ] , ( ident | qualified_name ) ;
sub_path     = ident , { "." , ident } ;
(* No whitespace is permitted on either side of the "::", and neither
   half may be a keyword. *)
qualified_name = ident , "::" , ident ;
(* Every parameter after the first one with a default has one too, and
   every implicit parameter comes after every ordinary one. *)
params       = param , { "," , param } , { "," , implicit_param }
             | implicit_param , { "," , implicit_param } ;
param        = ident , [ ":" , type ] , [ "=" , expr ] ;
implicit_param = "implicit" , ident , ":" , type ;

type         = type_atom , [ "->" , type ] ;
type_atom    = "Int" | "Float" | "String" | "Bool"
             | type_var
             | [ sub_path , "." ] , upper_ident , [ "(" , type , { "," , type } , ")" ]
             | "all" , type_var , { type_var } , "." , type
             | "[" , type , "]"
             | type_paren ;
(* One parenthesized list, three readings, decided by the token after
   ")" and by whether a comma is written -- exactly as `tuple_lit` and a
   parenthesized expression are told apart among values. *)
type_paren   = "(" , [ type , { "," , type } ,
                       { "," , implicit_param } , [ "," ] ] , ")" ,
               "->" , type
             | "(" , implicit_param , { "," , implicit_param } , ")" ,
               "->" , type
             | "(" , type , ")"
             | "(" , ")"
             | "(" , type , "," , ")"
             | "(" , type , ( "," , type )+ , [ "," ] , ")" ;
type_var     = ? an ident beginning with a lowercase letter ? ;

return_stmt = "return" , bound_value ;

(* `for`, `while` and the accumulator loop are one construct with
   different halves written; every combination of them is a loop_stmt. *)
loop_stmt   = ( "loop" , accumulator , [ iteration ]
              | iteration ) , ":" , block ;
accumulator = target , [ ":" , type ] , "=" , tuple_or_expr ;
iteration   = "for" , ident , "in" , expr | "while" , expr ;

break_stmt    = "break" ;
continue_stmt = "continue" ;

if_stmt     = "if" , expr , ":" , block ,
              { "else" , "if" , expr , ":" , block } ,
              [ "else" , ":" , block ] ;

(* Always indented: a `match` opens a list of clauses rather than a
   block of statements, and a `case` clause is not an expression, so
   there is nothing its header's line could carry. *)
match_stmt  = "match" , expr , ":" , INDENT , case_clause , { case_clause } , DEDENT ;
case_clause = "case" , pattern , [ "if" , expr ] , ":" , block ;
pattern     = pattern_as , { "," , pattern_as } ;
pattern_as  = pattern_or , [ "as" , ident ] ;
pattern_or  = pattern_join , { "|" , pattern_join } ;
pattern_join = pattern_atom , { "++" , pattern_atom } ;
pattern_atom = int | "-" , int | string | bool | "_" | ident
             | constructor_pattern
             | "(" , ")"
             | "(" , pattern_as , ")"
             | "(" , pattern_as , "," , ")"
             | "(" , pattern_as , ( "," , pattern_as )+ , [ "," ] , ")"
             | list_pattern ;
(* Positional sub-patterns first, then named ones in any order; a field
   not mentioned matches anything. *)
constructor_pattern = [ sub_path , "." ] , upper_ident ,
                      [ "(" , [ field_pattern , { "," , field_pattern } ] , ")" ] ;
field_pattern = pattern_as | ident , "=" , pattern_as ;

list_pattern = "[" , [ list_pattern_items ] , "]" ;
list_pattern_items = list_pattern_item , { "," , list_pattern_item } ;
list_pattern_item  = pattern_as | rest_marker ;
rest_marker        = ".." , [ ident ] ;

var_decl    = "var" , ident , "=" , bound_expr ;
assignment  = [ "implicit" ] , target , [ ":" , type ] , "=" , bound_value ;
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
            | sub_path , "." , ident
            | "(" , ")"
            | "(" , target_atom , "," , ")"
            | "(" , target_atom , ( "," , target_atom )+ , [ "," ] , ")" ;

expr_stmt   = tuple_or_expr ;

tuple_or_expr = expr , { "," , expr } ;

expr        = lambda | if_expr | let_expr | comparison ;

(* A lambda takes everything to its right that one expression can hold,
   so `=>` associates to the right and binds looser than every
   operator; a comma ends it, since `x => a, b` is a pair. *)
lambda      = lambda_params , "=>" , expr ;
lambda_params = ident
            | "(" , [ param , { "," , param } ] , ")" ;

if_expr     = "if" , expr , "then" , expr , "else" , expr ;

(* Like a lambda, the body takes everything to its right that one
   expression can hold. *)
let_expr    = "let" , target , [ ":" , type ] , "=" , expr , "in" , expr ;

comparison  = additive , [ comp_op , additive ] ;
comp_op     = "<" | "<=" | ">" | ">=" | "==" ;

additive    = multiplicative , { ( "+" | "++" | "-" ) , multiplicative } ;
multiplicative = unary , { ( "*" | "/" ) , unary } ;
unary       = "-" , unary | atom ;

atom        = ( float | int | string | bool | ident | list_lit | list_comp
              | tuple_lit | construct
              | "(" , expr , ")" ) ,
              { call_tail | field_tail } ;
(* A constructor applied to its fields, with a call's arguments; one with
   no fields is written bare. *)
construct   = [ sub_path , "." ] , upper_ident , [ call_tail ] ;
field_tail  = "." , ident ;
(* Every named argument comes after every positional one; the named
   ones may be written in any order. A constructor's arguments may end
   in `..expr`, which gives every field not written before it. *)
call_tail   = "(" , [ call_args ] , ")" ;
call_args   = expr , { "," , expr } , { "," , named_arg } , [ "," , update ]
            | named_arg , { "," , named_arg } , [ "," , update ]
            | update ;
named_arg   = ident , "=" , expr ;
update      = ".." , expr ;
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
(* A point needs a digit on each side, so `1.` and `.5` are not floats.
   An exponent alone makes one: `1e9` is a Float. *)
float       = digits , "." , digits , [ exponent ]
            | digits , exponent ;
digits      = digit , { digit } ;
exponent    = ( "e" | "E" ) , [ "+" | "-" ] , digits ;
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
- Two rules about `break`/`continue` cannot be stated in the grammar and
  are checked in `src/parser.ml` beside the others, so they hold in
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
    'continue' has already left the loop, so nothing written after it
    in the same block runs
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
  `if_stmt`, and that is how it is parsed: `src/parser.ml` builds no
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
  grammar is not LL(1) at `statement`. `src/parser.ml` handles this
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
  grammar at all — see the parser module comment in `src/parser.ml` —
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
  either; of `then` and `let`, which have no Python counterpart at all; and of
  `true`/`false`, which do have a Python counterpart (`True`/`False`) but
  not this spelling of one — a Pyking program cannot use `true`, `false`,
  `True`, or `False` as an identifier (the first two because they're
  keywords, the last two because they're simply unbound: Pyking has no
  binding for Python's capitalised spelling).
- `assignment`'s `[ ":" , type ]` annotates the *binding*, e.g.
  `x: Int = 1`. Like every other annotation it is optional and nothing
  verifies it (see "Type annotations"), but it is the one the type
  checker writes back into: `pyk compile -t pyking` prints each binding
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
- **A tuple type is written the way the tuple value is.** A tuple `type`
  with zero elements, `()`, is the Unit type; one with a single element
  is `(Int,)`, carrying the same comma the singleton value `(1,)`
  carries; and `(Int, Bool)` upwards needs no comma to be a tuple, with
  a trailing one allowed as it is among values. So `(1,)` has type
  `(Int,)` and `(1, true)` has type `(Int, Bool)`, each spelled like the
  value it describes. Tuple and list types nest arbitrarily, e.g.
  `[(Int, Bool)]`, `(Int, [String], (Bool, Bool))` or `((Int,),)`.
- **Parentheses around one type are grouping**, exactly as they are
  around one expression: `(Int)` is `Int`, `((Int))` is `Int` again, and
  `(1)` is likewise just `1`. The comma is the whole difference between
  grouping and a singleton, in types and in values alike — which is why
  a singleton must be written with it in both.
- The trailing `[ "->" , type ]` in `type` is what makes a **function
  type**, `(Int, Bool) -> Int`. The parenthesized list before the arrow
  is the *parameter list*, and the same list without an arrow after it is
  a tuple — which is the whole rule, decided by the one token after `)`.
  So `(Int, Bool)` is a pair, `(Int, Bool) -> Int` takes two parameters,
  and `((Int, Bool)) -> Int` takes one parameter that is a pair. The
  arrow settles the singleton too: `(Int) -> Int` and `(Int,) -> Int`
  both take one `Int` — the comma is a list's, and there is no tuple
  there for it to make — while `((Int,)) -> Int` takes one parameter
  that *is* a one-tuple. The
  result is a `type` in its turn, so `->` groups to the right:
  `(Int) -> (Int) -> Int` returns a function and needs no parentheses of
  its own. A function type may appear wherever a type may, including
  nested inside list and tuple types — `[(Int) -> Bool]`,
  `((Int) -> Int, Int)` — and as another function type's parameter,
  `((Int) -> Int) -> Int`.
- The same is true of `tuple_lit`, `target_atom`, and `pattern_atom` —
  and of `type_paren` above, which is the point of writing them alike:
  `()` is the empty tuple, and a *parenthesized* single element followed
  by a comma, e.g. `(1,)`, `(x,)`, `case (p,):` or `(Int,)`, is a genuine
  singleton tuple/target/pattern/type, distinct from a plain
  parenthesized `(1)`/`(x)`/`(p)`/`(Int)` (which is just grouping,
  unwrapped by the parser). Tuples nest arbitrarily in all four
  positions.
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
  destructures a list value; a `constructor_pattern` destructures a
  datatype's value. All of these nest arbitrarily (e.g.
  `case (a, [b, ..c]):`). An identifier starting with an uppercase
  letter is a constructor wherever a pattern holds it, so `case Red:`
  matches the constructor `Red` rather than binding a name.
- `|` binds looser than `++` and tighter than `as`, which binds looser
  than everything but the comma: `case 1 | 2, x as y:` is
  `case (1 | 2), (x as y):`. Every alternative of a `|` binds the same
  names, refused at parse time otherwise:

  ```
  'prog.pyk' 3:22-3:28 Parsing error: every alternative of '|' binds
    the same names, and 'x' is bound in one of them but not in this one
  ```
- A guard is any expression, read after the pattern and up to the
  `:`. It is asked only once its pattern has matched, and it sees the
  names the pattern binds.
- A `datatype` is written at a module's top level only; inside a block
  it is a parse error. Two constructors on one line are separated by a
  comma, and a line of them after the header's starts a line of its
  own. A field written
  `name = default` with no type takes its default's type (see
  "Datatypes"). A `struct` is written at the top level too, and two
  fields on one of its lines are separated by a comma.
- `..expr` is written only as the last argument of a constructor, and
  at most once; in a call to a `def` it is a parse error.
- An uppercase identifier in an expression is a constructor. Every
  name a program binds -- with `=`, `var` or `def`, as a parameter, a
  loop variable, in a pattern, or as an import's alias -- starts with a
  lowercase letter or `_`; one starting with an uppercase letter is
  refused at parse time, since an uppercase name is a type or a
  constructor. A constant is written `pi = 3.14`, not `PI = 3.14`. A
  `from` line renaming a datatype or a constructor gives it a name
  starting with an uppercase letter, as the name it renames does.
- `x.name` reads a field where `x` is a value, and reaches a module's
  public name where `x` is an imported module; the two are told apart by
  what `x` is bound to. The `.` and the field name are on the line the
  value ends on.
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
  silently filtered out of the result — it never raises an error. (A
  `match`, unlike a comprehension, has to match every value; see
  "Exhaustiveness".) `list_comp` always starts with a `comp_for`; `comp_for`/
  `comp_if` may then repeat in any order, matching Python's own
  multi-clause comprehensions (nested `for`s, interspersed `if`s).
- A `qualified_name` may be a **definition's** name and nothing else --
  not a binding, a `var`, a parameter, a loop variable, a pattern
  capture, a module name or an import alias -- and the definition must
  take at least one argument, since the arguments of a call are what
  resolve which of them is meant. Both are refused where they are
  written (`'int::zero' takes no argument, so nothing could say which
  definition of 'zero' a call means`). A module-qualified name is
  `m.int::leq`: the module is written with a `.` and the definition's
  own qualifier with a `::`, and the two never mix.
- A **dotted** `def_name`, datatype name or `=` target -- `mymod.foo` --
  defines a name in a submodule (see "Submodules"), and is written only
  at a module's top level: inside a block it is refused. A
  `qualified_name` goes last, `mymod.int::abs`. Every `.` in a dotted
  name, in a `module_path` and in a `sub_path` is on the row the name
  before it ended on.
- `implicit` in front of a statement marks a `def` or an `=` binding of
  one name, and nothing else. It is a statement's prefix rather than a
  top-level one, so a definition inside a function may be implicit
  there and nowhere else; `public implicit def ...` is written in that
  order.
- An `implicit_param` needs both its name and its type written: the
  pair is what resolves it. It may not carry a default value, and a
  lambda may not have one at all.
- `lambda_params` shares `param` with `function_def`, but a lambda
  parameter may **not** carry a default value: a default is evaluated in
  the scope the definition is written in, and a lambda is an expression
  written wherever it stands. Writing one is refused (`the lambda
  parameter 'x' may not have a default value; only a 'def' parameter
  may`).
- A lambda's parenthesized parameter list is told from a parenthesized
  expression by what follows the `)`: `(x)` is a lambda's parameter list
  only when `=>` comes next, and is the expression `x` otherwise. The
  EBNF cannot say this, so `src/parser.ml` decides it by trying the
  parameter list and falling back.
- **A line may be continued while a bracket is open.** The lexer
  synthesizes `INDENT`/`DEDENT` from each physical line's leading
  whitespace (see "Indentation-based blocks" below), and suspends that
  entirely while an `(` or `[` is unclosed — so a parameter list, a
  call's arguments, a list literal, a comprehension and a tuple may each
  span several lines. The continuation lines are part of the same
  statement and their own indentation means nothing; outside brackets,
  indentation means exactly what it did. See "Lines and continuation".
- `block`'s bare-`expr_stmt` alternative is taken **only** when that
  expression begins on the row the header's `:` ends on. The EBNF cannot
  state this, for the same reason it cannot state "a statement starts a
  line of its own": the lexer emits no token for a line break, so both
  are checked in `src/parser.ml` against the positions the tokens
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

An `Int` holds **at least the signed 32-bit range**, −2 147 483 648 to
2 147 483 647. Every implementation carries that much; several carry
more, and none is made to pretend otherwise.

**Past that range the result is undefined.** `2147483647 + 1` may be
2 147 483 648, or −2 147 483 648, or anything else the host arrives at —
the language does not say, and two implementations may answer
differently without either being wrong. There is no overflow error to
handle, and nothing is inserted into generated code to force one answer:
what a target computes is what its own arithmetic computes.

A program that stays inside the 32-bit range therefore means the same
thing everywhere, and that is the range to write programs for. One that
leaves it is relying on a width the language does not promise.

**What a program may write down stops at 32 bits, whatever the host.** A
literal outside the range is a lexical error on every target, so the
front end refuses the same programs wherever it runs:

```pyking error
biggest = 2147483647      # fine
too_big = 2147483648      # Lexing error: integer literal is too large
```

The lower end is one short of the range for a reason worth knowing: a
negative literal is unary minus applied to a positive one, so
`-2147483648` asks for the literal `2147483648`, which is refused.
Write `-2147483647` — or, if the exact value is needed,
`-2147483647 - 1`, which computes it without writing it.

`docs/targets.md` shows what each target does past the range, and why
nothing is inserted to hide the difference.

```python
count = 42
message = "hello, pyking"
quoted = 'it\'s a test with a "quoted" word\nand a second line'
print(count, message)
print(quoted)
```

### Float literals

A `Float` is **IEEE 754 binary64**, double precision, and it means
exactly that on every implementation. Unlike an `Int`, whose width the
language leaves open past 32 bits, a Float is the same 64 bits
everywhere, so a Float program means one thing wherever it runs.

A literal is a digit run with a point that has **digits on both sides**,
an exponent, or both:

```pyking
half = 0.5
one = 1.0
billion = 1e9
tiny = 1.5e-3
huge = 2E+10
```

Neither `1.` nor `.5` is a literal — a point needs a digit after it,
which is what keeps `1.` and a name written after a value unambiguous.
Write `1.0` and `0.5`.

There is no bound on the magnitude the way there is on an integer
literal. A literal past what a double holds is an **infinity**, which is
IEEE's own answer and the same on every host:

```pyking
print(1e400)              # inf
```

**The infinities and NaN are ordinary values.** Division never fails:

```pyking
zero = 0.0
print(1.0 / zero)         # inf
print(-1.0 / zero)        # -inf
print(zero / zero)        # nan
```

NaN brings IEEE's one surprise with it, and Pyking does not hide it:
**a NaN is equal to nothing, itself included**, and every ordering
against one is false.

```pyking
nan = 0.0 / 0.0
print(nan == nan)         # false
print(nan < 1.0)          # false
print(nan >= 1.0)         # false
```

The two zeros are different values that compare equal, and print
differently:

```pyking
print(0.0)                # 0.0
print(-0.0)               # -0.0
print(0.0 == -0.0)        # true
```

**How a Float is written** is part of the language, since one program
prints the same characters wherever it runs: the shortest decimal that
reads back as the same double, always with a point or an exponent, so a
Float is always visibly one.

```pyking
print(1.0)                # 1.0, not 1
print(0.1)                # 0.1, not the exact binary value
print(100.0)              # 100.0, not 1e2
print(1e16)               # 1e16
print(1.0 / 3.0)          # 0.3333333333333333
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
expression looks it up as a variable reference. A name a program binds
starts with a lowercase letter or an underscore: one starting with an
uppercase letter is a type or a constructor (see "Datatypes").

```python
x = 10
y = x
print(x, y)
```

### Arithmetic operators and parenthesized expressions

`+`, `-`, `*`, and `/` are left-associative binary operators with the usual
precedence (`*`/`/` bind tighter than `+`/`-`). Parentheses override the
default precedence.

**All four are overloaded over `Int` and `Float`**: each takes two
operands of one type and answers that same type. There is no third
possibility — an `Int` beside a `Float` is refused, not widened, and
`float(n)` and `int(x)` are what a program writes instead. See "Numbers,
and what the checker defaults to" under "Type checking".

On two Ints, `/` is **integer division, truncating toward zero**.
Truncation is toward zero rather than downward, so `-7 / 2` is `-3` and
not `-4`:

```pyking
print(7 / 2, (0 - 7) / 2)     # 3 -3
print(7 / (0 - 2))            # -3
print((0 - 7) / (0 - 2))      # 3
```

Dividing an Int by zero is left to whatever the target does with it, and
the targets differ — see `docs/targets.md`.

On two Floats, `/` is **IEEE division**: not truncated, and never a
failure. Dividing by zero answers an infinity or a NaN, the same way on
every target (see "Float literals" above).

```pyking
print(7.0 / 2.0)              # 3.5
print(-7.0 / 2.0)             # -3.5
print(1.0 / 0.0)              # inf
```

```python
a = 2 + 3 * 4
b = (2 + 3) * 4
c = 10 - 4 / 2
print(a, b, c)
```

A `-` written where an expression is expected is instead unary minus,
which negates what follows it, an `Int` or a `Float` alike. That covers
negative literals (`-5`, `-2.5`) and negation of anything else — a
variable, a call's result, a parenthesized expression — and it may be
repeated (`- -x`).

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

**A Float is not a pattern.** `case 1.5:` is refused, because matching
on one means comparing a double for equality, and IEEE equality is not
the relation a reader of a `match` expects — a NaN matches no case, its
own spelling included. A program that wants that comparison writes `==`
and says so.

### Concatenation (`++`) — Pyking extension

`++` joins two strings, or two lists, into one. It is left-associative
and sits at the same precedence as `+` and `-`, so a chain of them needs
no parentheses and `*`/`/` still bind tighter.

```python
print("con" ++ "cat")
print("a" ++ "b" ++ "c" ++ "d")
print([1, 2] ++ [3, 4])
```

Concatenation has an operator of its own because `+` does not do it.
Where Python writes `+` for both, Pyking keeps them apart: `+` adds two
numbers and nothing else, `++` joins and never adds. Nothing is both, so
the two never meet in one expression, and neither one has to be read as
the other.

```python
print(2 + 3)        # 5
print("2" ++ "3")   # 23
```

### Comparison operators

`<`, `<=`, `>`, `>=`, and `==` compare two arithmetic expressions and
produce a single comparison expression (comparisons do not chain).

```python
print(1 < 2, 2 <= 2, 3 > 4, 3 >= 3, 2 == 2)
```

All five take two operands of one type, as the arithmetic operators do:
two `Int`s or two `Float`s, and `==` additionally two `String`s or two
`Bool`s. On Floats the comparison is IEEE's, which is where NaN's
behaviour comes from (see "Float literals" above).

```pyking
print(1.5 < 2.5, 1.5 == 1.5)
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
raising an error:

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

**A mutable variable may hold a value of any type**: a number, a
String, a tuple, a list, a datatype's value or a function. What changes
is which value the name holds; a list held by a `var` is still never
changed in place, so updating one builds the new list and stores it:

```pyking
var balls = [(10, 20), (30, 40)]
balls := [(x + 1, y) for (x, y) in balls]
balls := balls ++ [(0, 0)]
print(balls)
```

Its type is its initializer's, decided once, and every `:=` must give
that same type — a mutation is not a rebinding, so it cannot change what
the name holds. Nothing else marks the name as mutable: reading one
yields an ordinary value of that type, usable anywhere an immutable one
is, which is why `total` above is added to, compared and printed like
any binding. (There are no references or pointers yet; when there are,
that reading step becomes something a program can talk about.)

A mutable variable is also the one name that may not be shadowed, and
`:=` only ever accepts one — both checked at compile time, and neither
of them a question about types; see "Names and scoping" below.

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
    "param " ++ string(n)


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

```pyking error
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
fns =
loop made = [] for i in range(3):
    def show(): i
    made ++ [show]

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
everywhere — `print`, `debug`, `range`, `string`, `len`, `int`, `float`
and `bool` — since no
Pyking program
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

### Default parameters

A parameter may be given a **default**: an expression used when a call
leaves that argument out.

```pyking
def greet(who: String = "world", times: Int = 1) -> Int:
    print("hello, " ++ who)
    return times


print(greet())               # hello, world
print(greet("pyking"))       # hello, pyking
print(greet("a", 3))         # hello, a
```

Every parameter after the first one with a default has one too, so a
positional call is never ambiguous about which parameter it filled:

```pyking error
def f(a: Int = 1, b: Int) -> Int: a + b     # refused
```

A default is an ordinary expression, and it is evaluated **in the scope
the `def` is written in, at each call that omits the argument**. Both
halves matter. Rebinding a name after the definition does not change
what the default is worth:

```pyking
size = 10


def scaled(x: Int = size) -> Int:
    return x * 2


size = 20

print(scaled())              # 20 -- the first `size`, not the second
```

and a default that has an effect has it once per call that omits it,
not once when the `def` is reached:

```pyking
var counter = 0


def tick(from_: Int = counter) -> Int:
    return from_ + 1


print(tick())                # 1
counter := 40
print(tick())                # 41
```

A default may name anything in scope where the definition stands,
including a function written further down — a `def` name is visible
throughout its block, so a default may call one:

```pyking
def padded(amount: Int = width()) -> Int:
    return amount + 1


def width() -> Int:
    return 7
```

**A default is not part of a function's type.** `greet` above has type
`(String, Int) -> Int`, exactly as it would without the defaults, and
nothing that holds the function as a value carries them:

```pyking norun
g = greet
print(g())                   # refused: `g` is a binding, not a definition
```

The same rule settles where the sugar is available at all: a call may
leave an argument out only where the callee is a `def` this module can
see the parameters of — written directly by name, or reached as
`module.name` through an imported Pyking module. A builtin has no
parameter names, and an external module's function is written in another
language, so neither takes one.

An **exported** function's defaulted parameter must carry a type
annotation:

```pyking error
public def greet(who: String = "world") -> String: "hi " ++ who
public def greet(who = "world") -> String: "hi " ++ who     # refused
```

An exported function carries its complete type in the source, and a
parameter's type is part of that whether or not it also has a default
(see "What a module may export").

A default may be written on a parameter of a nested `def`, in a loop
body, or anywhere else a definition may stand; what it captures is what
is bound where the definition is written, as any body is.

### Named arguments

An argument may be written `name = expr`, naming the parameter it fills:

```pyking
def box(width: Int = 1, height: Int = 2, depth: Int = 3) -> Int:
    return (width * 100) + (height * 10) + depth


print(box(height = 9))          # 193 -- width and depth default
print(box(4, depth = 6))        # 426
print(box(width = 4, depth = 6))
```

Three rules:

- **Every positional argument comes first.** A positional argument after
  a named one has no position left to mean.
- **Names may be written in any order.** `box(depth = 6, width = 4)`
  is `box(4, 2, 6)`. The arguments still run in the order they are
  written (see "Evaluation order"): the depth's before the width's.
- **A parameter is filled once.** Naming one that a positional argument
  already filled is refused, as is naming the same one twice.

A name may be given to a parameter that has no default — it is a way of
saying at the call site what an argument is for:

```pyking
def join(left: String, right: String) -> String: left ++ "-" ++ right

print(join("a", right = "c"))
```

but a name does not make a parameter optional: every parameter without a
default still has to be given something.

Named arguments are available exactly where defaults are — the callee
must be a `def` this module can see the parameters of, since neither is
part of a function's type.

An omitted argument is worth its default **in its own position**, so a
default with an effect has that effect between the supplied arguments
around it rather than before or after all of them -- where the names
are written in the parameters' order. Where they are not, every
argument written runs first, in the order written, and then the
defaults of the parameters left out, in the parameters' order:

```pyking
def note(label: String, n: Int) -> Int:
    print(label)
    n

def box(width: Int, height: Int = note("height", 1), depth: Int = 2) -> Int:
    width * 100 + height * 10 + depth

print(box(depth = note("depth", 6), width = note("width", 4)))
```

```
depth
width
height
416
```

### Type annotations

An immutable binding may be annotated on its name, `x: Int = 1`:

```pyking
count: Int = 42
name: String = "pyking"
total: Int = count + 1
```

Parameters and the return value may optionally be annotated with a type:
`Int`, `Float`, `String`, `Bool`, a list type `[T]`, a tuple type `(T1, T2, ...)`
or `(T,)`, or a function type `(T1, T2, ...) -> T` (all nesting freely,
e.g. `[(Int, Bool)]` or `[(Int) -> Bool]`). `()`, the zero-element tuple
type, is the Unit type, and `(T)` with no comma is grouping rather than
a tuple. Annotations are entirely optional and independent per
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
`SFunctionDef.return_type` and `SLet.type` in `src/syntax.ml`) and
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
holds.

```python
var i = 0
while i < 3:
    print(i)
    i := i + 1
```

### One loop, three halves — Pyking extension

`for`, `while` and `loop` are the same construct with different halves
written: an **accumulator** and an **iteration clause**, either of which
may be left out. So they combine, and `break` and `continue` mean the
same thing in every combination.

```pyking
def total(xs:[Int]) -> Int:
    return loop acc = 0 for x in xs:
        acc + x


def countdown(from_:Int) -> Int:
    return loop i = from_ while i > 0:
        i - 1
```

A `for`/`while` is a loop, so a `break` in one belongs to *it* — there
is no crossing out of a loop any more. A `def` is the one thing a
`break` still may not reach out of.

**Going round.** A loop that carries an accumulator carries what its
body *ends in*: the body's last statement is the next turn's
accumulator, recursively through the branches of a trailing `if` or
`match`, exactly as tail position works everywhere else. A path that
`break`s, `continue`s or `return`s says nothing, since none of them
reaches the end of the body.

```pyking
def total(xs:[Int]) -> Int:
    return loop acc = 0 for x in xs:
        acc + x                 # the next turn's `acc`
```

A loop carrying nothing asks nothing of its body: there is no next
accumulator for it to give, so it may end in any type at all.

**Leaving a loop.** `break` ends the loop. It takes no operand: the
loop is worth the accumulator the turn it stopped on started with, so
there is nothing left to say. `continue` is the other way round -- it
starts the next turn at once, with that same accumulator unchanged --
and takes no operand for the same reason.

**What a loop is worth.** One rule:

> the accumulator it stopped with, if one is written; else `()`.

However it stops -- on a `break`, or by a `for`/`while` running out of
turns -- the answer is the same, so a loop that can stop both ways
still has one value rather than two. A plain `loop:` that never breaks
never stops, and nothing ever asks.

### `loop` loops -- Pyking extension

`loop` is a loop whose state is a *binding* rather than a mutable
variable, and which is worth something when it stops. Python has no
equivalent, so everything in this section is Pyking source rather than
valid Python.

`loop x = 5:` evaluates `5` once and binds `x` to it for the first turn.
What the body ends in is the next turn's `x`, and `break` ends the loop,
which is then worth the `x` the turn it stopped on started with:

```pyking
counted = loop x = 5:
    if x <= 10:
        x + 1
    else:
        break

print(counted)          # 11
```

The body's last statement is the accumulator, recursively through the
branches of a trailing `if` or `match` -- the same tail-position rule a
function body follows. A path ending in `break`, `continue` or `return`
says nothing, since none of them reaches the end of the body.

**What a loop carries is what it is worth.** The accumulator is the
state -- the initializer's type, and what the body must end in -- and it
is the loop's value when it stops, whichever way it stops. So a loop
answers with what it carries, and a loop that carries two things answers
with the pair:

```pyking
def factorial(n, acc) -> Int:
    (left, product) = loop n, acc = n, acc:   # carries (Int, Int)
        if n == 0:
            break                             # and is worth (Int, Int)
        else:
            (n - 1, n * acc)
    return product


print(factorial(10, 1))        # 3628800
```

`continue` says "go round again" from wherever it is written, skipping
the rest of the body; the next turn starts with the accumulator this one
started with, so it is a way to leave the accumulator alone for a turn:

```pyking
def total_positive(xs:[Int]) -> Int:
    return loop acc = 0 for x in xs:
        if x < 0:
            continue        # this element adds nothing
        acc + x


print(total_positive([1, 0 - 5, 2]))    # 3
```

**A loop is worth its accumulator**, so it stands wherever a value-form
`if`/`match` does -- bound with `=`, returned with `return`, or left as
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
every turn, and what the body ends in has to give the whole tuple back.

```pyking
foo, bar = loop x, y = 0, true:
    if x <= 10:
        (x + 1, y)
    else:
        break


print(foo, bar)         # 11 true
```

**`loop:` carries nothing.** Written with no accumulator its body may
end in anything -- there is no accumulator to say, so nothing is asked
of its last statement -- and the loop is worth `()`. The only way out
is `break`.

```pyking norun
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

```pyking norun
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

### Lambdas — Pyking extension

`x => x + 1` is an expression that is a function. One parameter needs no
parentheses, so `x => x + 1` and `(x) => x + 1` are the same thing;
several need them, and a parameter may be annotated. The body is **one
expression** — there is no block form.

`=>` binds looser than every operator and associates to the right, so a
lambda takes everything to its right that one expression can hold. A
comma ends it, since `x => a, b` is a pair whose first element is the
lambda.

```pyking
double = x => x * 2
add = (x, y) => x + y
typed = (n: Int) => n - 1
nothing = () => 7

print(double(21), add(3, 4), typed(10), nothing())

# A lambda answering with a lambda; `=>` associates to the right, so no
# parentheses are needed.
adder = x => y => x + y
print(adder(6)(7))

# An `if` expression is one expression, so it is a body like any other.
sign = n => if n < 0 then 0 - 1 else 1
print(sign(-5), sign(5))
```

A lambda captures what is bound where it is written, exactly as a `def`
body does, and a later binding of a name is a new binding rather than a
write to the old one — so what a lambda captured does not change under
it (see "Names and scoping").

```pyking
base = 100
shift = n => n + base
base = 200
print(shift(1))     # 101: the binding `shift` captured
```

**A lambda is monomorphic.** Its parameters are one type, settled
between its body and its uses, and never generalised; a `def` with the
same body is polymorphic and serves every type at once. That is
Hindley-Milner's own distinction between a `let`-bound definition and a
lambda-bound one, and it is the whole of the difference here:

```pyking
def named(x): x
print(named(1), named("a"))     # fine: `named` is polymorphic

id = x => x
print(id(1))
# print(id("a"))                -- error: `id` is Int -> Int by now
```

Two more rules follow from a lambda being an expression rather than a
definition. A lambda parameter may not have a default value, since a
default belongs to the scope a definition is written in. And a lambda
parameter is a binding like any other, so it may not shadow a `var`.

### Let expressions — Pyking extension

`let target = value in body` is an expression: `value` is evaluated
once, bound to `target`, and the whole is worth `body`. The target is
what an `=` binding takes — a name, or a tuple taken apart — with an
optional annotation, checked as a binding's is. What it binds is seen by
the body and nowhere else, not even by `value`.

```pyking
foo = let x = 78 in x + 1
print(foo)                                  # 79

# One binding per `let`; a later one sees the earlier.
print(let a = 2 in let b = a * 3 in a + b)  # 8

pair = (1, (2, 3))
print(let (x, (y, z)) = pair in x + y * z)  # 7
print(let t: (Int, String) = (4, "four") in t)
```

Like a lambda, the body takes everything to its right that one
expression can hold, so parentheses end it: `1 + (let x = 10 in x) * 2`
is 21. A name a `let` binds starts with a lowercase letter, may not
shadow a `var`, and may not be bound twice in one target.

### Static overloading — Pyking extension

Two definitions may share a base name if a **qualifier** tells them
apart:

```pyking
def int::twice(x: Int) -> Int: x * 2
def string::twice(x: String) -> String: x ++ x

print(twice(21), twice("ab"))       # 42 abab
print(int::twice(3))                # 6
```

`int` and `float` are not special: the qualifier is part of the name and
nothing else, and `wow::twice` works exactly as well. What it does is
make the names unique, so both definitions may be written in one block.

A call may write the whole name or leave the qualifier out. Leaving it
out is resolved by the **arguments**: the one definition whose
parameters they fit is the one meant. Nothing else takes part — not the
result type, and not what the call is used for.

```pyking
def a::join(x: Int, y: Int) -> Int: x + y
def b::join(x: String, y: String) -> String: x ++ y

print(join(2, 3), join("hi", "!"))  # 5 hi!
```

Three rules follow, and each is refused where it is written:

- **A `::` name belongs to a `def` that takes at least one argument.**
  A binding, a `var`, a parameter, a loop variable, a pattern capture,
  a module name and an import alias may not carry one, and neither may
  a `def` with no parameters — there would be nothing to resolve it by.
- **A plain definition is not a member of any set.** If a block binds
  `twice` with no qualifier, `twice(...)` means that one and is a type
  error if it does not fit.
- **A builtin's name is never part of a set.** `string(1)` is the builtin
  whatever `q::string` definitions are in scope.

Resolution needs the argument types to be decided. Inside a function
whose parameter could be anything, they are not, and the call is
refused with the way out named:

```pyking
# def both(x): (twice(x), twice(x))
#   -- error: nothing here decides which 'twice' is meant. Annotate it,
#      or take the definition as an implicit parameter
```

Two definitions that both fit is an error too. There is no ordering
between them: write the one that is meant.

**A default parameter counts.** It lets a definition take fewer
arguments, so it is part of what says whether a call could mean that
definition — and two definitions taking one call, where one of them
needs a default, is refused:

```pyking
def b::my2(x: Bool, y: Int) -> Int: y + 100
def c::my2(x: Bool, y: Int, z: Int = 1000) -> Int: y + z

# print(my2(true, 1))
#   -- error: 'b::my2' takes them as written and 'c::my2' takes them
#      with its default for 'z'
```

Where only one definition can take the call that way, it is the one
meant and its default is used. A **named argument** may not be written
on an overloaded call at all: putting one in its parameter's place
needs to know which definition is meant, which the arguments have not
said yet.

### Implicits — Pyking extension

A parameter written `implicit` may be left out at a call, and is filled
from the calling context by **name** and by **type**:

```pyking
def foo(x: a, implicit bar: (a) -> b) -> (b, b):
    (bar(x), bar(x))

def my1() -> ():
    implicit def bar(z: Int) -> String: string(z) ++ "!"
    print(foo(78))                  # ('78!', '78!')

def my2() -> ():
    implicit def bar(z: String) -> String: z ++ "!"
    print(foo("hi"))                # ('hi!', 'hi!')
```

`foo` is written once and means two things, because the implicit `bar`
it asks for is a different definition in each scope. The name matters:
`implicit bar` asks for something *called* `bar`, so the parameter's
name is part of `foo`'s type —

```
foo : (a, implicit bar: (a) -> b) -> (b, b)
```

— and that is what `-t pyking` prints and what a written annotation has
to say.

**Only an `implicit` definition is ever resolved to.** A binding of the
right name and the right type that was not written `implicit` is
invisible to the search:

```pyking error
def my3() -> ():
    def bar(z: Int) -> String: string(z)
    print(foo(1))       # error: there is a 'bar', but it is not
                        #        declared 'implicit'
```

`implicit` goes in front of a `def` or an `=` binding of one name, and
in front of `def` it follows `public`. Any value may be implicit, not
only a function:

```pyking
implicit width = 4

def pad(text: String, implicit width: Int) -> String:
    loop out = text while len(out) < width:
        out ++ "."

print(pad("a"))         # a...
print(pad("a", 8))      # a....... -- written out, which always works
```

Implicit parameters come after every ordinary one, each needs its type
written, and none may have a default value: an omitted implicit
argument is resolved rather than defaulted. A call writes out every
implicit argument or none of them, by position or by the parameter's
name (`pad("a", width = 8)`).

**A definition with implicit parameters, or one that is itself
implicit, writes its whole type down** — resolving is a question about
types, so there has to be a type to ask it of.

**An implicit obligation does not cross a `def`.** If a body calls
something whose type carries an implicit `bar` and that body has no
implicit `bar` in scope, it is an error there, and the fix is to write
`implicit bar` among its own parameters. What the body's *caller* has
in scope does not reach inside it.

What does work — and is why the parameter is part of the type — is
passing such a function as a value and calling it elsewhere. The
resolution happens where the **call** is written:

```pyking norun
def apply_twice(f: (Int, implicit bar: (Int) -> String) -> (String, String),
                n: Int) -> (String, String):
    implicit def bar(z: Int) -> String: string(z * 2)
    f(n)

print(apply_twice(foo, 5))          # ('10', '10')
```

An implicit may be resolved to a definition that takes implicits of its
own, and those are discharged in turn, in the scope of the call. A
chain that does not stop is cut at a fixed depth and reported.

**A function carrying an implicit parameter may be passed where an
ordinary function is wanted**, and its implicit is then resolved where
it is *passed*:

```pyking
implicit my = 10

def bar(a, f):                  # `f` is an ordinary (Int) -> a here:
    f(a + 1)                    # a body cannot discover an implicit

def foo(x: Int, implicit my: Int) -> Int: x + my

print(bar(7, foo))              # 18 -- foo's `my` is the 10 above
```

Writing the implicit into `f`'s own type says the other thing: resolve
it in `bar`'s body, against whatever is in scope there.

```pyking
def bar(a, f: (Int, implicit my: Int) -> Int):
    implicit my = 7
    f(a + 1)                    # 15
```

That is the whole of what the annotation decides, and it is why an
implicit parameter is part of a function's type.

The adaptation goes both ways, so the annotated `f` above still accepts
a function that asks for nothing — `bar(2, x => x + 1)` works, and the
lambda simply never sees the implicit. A function that needs less
stands wherever one that needs more is wanted.

The two features meet: an implicit definition may be overloaded, and
the search considers every qualifier.

```pyking
implicit def int::leq(x: Int, y: Int) -> Bool: x <= y
implicit def float::leq(x: Float, y: Float) -> Bool: x <= y

implicit def list::leq(xs: [a], ys: [a],
                       implicit leq: (a, a) -> Bool) -> Bool:
    match (xs, ys):
        case ([x] ++ xrest, [y] ++ yrest):
            if leq(x, y):
                list::leq(xrest, yrest)
            else:
                false
        case ([], []): true
        case (_, _): false

print(leq(88, 100), leq(79.12, 18.2), leq([171, 10], [188]))
# true false false
```

### `match`/`case` pattern matching

`match expr:` is followed by one or more indented `case pattern:` clauses;
the body of the first case whose pattern matches runs. A pattern is an
integer literal, a string literal, a boolean literal, `_` (always
matches, discards the value), a plain identifier (always matches, binds
the value to that name), or a tuple pattern that destructures a tuple
value element by element (with or without parentheses, nesting
arbitrarily, and sub-patterns can themselves be literals, `_`,
identifiers, or further tuple patterns) — see the grammar notes above,
and the sections below for constructor patterns, or-patterns, `as` and
guards. A `match` matches every value of its subject's type, which is
why `describe` ends in a case that binds a name (see "Exhaustiveness").

```python
def describe(n):
    match n:
        case 0:
            return "zero"
        case 1:
            return "one"
        case value:
            return "many: " ++ string(value)


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
            return "exactly one: " ++ string(x)
        case [a, b, c]:
            return "exactly three"
        case [first, ..rest]:
            return "prefix + rest, first=" ++ string(first)


print(describe([]))
print(describe([1]))
print(describe([1, 2, 3]))
```

A case that no value can reach -- every value it matches is taken by a
case above it -- is refused, so after `[first, ..rest]`, which takes
every list of one element or more, nothing more may be written. The
other forms, `[..init, last]`, `[p, q, ..mid, r]`, `[u, v, ..]` and
`[_, ..w]`, are each shown in a function of their own in
`tests/list_pattern_match.pyk`.

**Splitting with `++`.** A pattern may be written as pieces joined with
`++`, the concatenation operator read backwards: a pattern says how the
value was put together. Every piece but one has a fixed length, and the
one name in the middle takes whatever is left:

```pyking norun
[x] ++ xs                is  [x, ..xs]
first ++ [x, y, z]       is  [..first, x, y, z]
[x, y] ++ m ++ [k1, k2]  is  [x, y, ..m, k1, k2]
```

For a list the two spellings are the same pattern, and the printed
program uses the `..` one whichever was written. For a **string** this is the only
spelling, and the only way to match a string by anything but equality:

```pyking
def command(line:String) -> String:
    match line:
        case "get " ++ rest:
            return "GET(" ++ rest ++ ")"
        case "<" ++ body ++ ">":
            return body
        case other:
            return "?" ++ other
```

Only *literal* text can be stripped this way. `_ ++ rest` leaves two
parts open and is refused, and so is a chain mixing a list with a
string, or one whose pieces are not all of fixed length (`[x, ..r] ++ ys`
would need two rest markers).

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

### Or-patterns, `as` and guards

`p1 | p2` matches what either alternative matches. The alternatives
bind the same names, at the same types, so the arm after it sees one set
of bindings whichever matched:

```pyking
def on_axis(p: (Int, Int)) -> String:
    match p:
        case (0, 0): "origin"
        case (x, 0) | (0, x): "on an axis at " ++ string(x)
        case _: "elsewhere"


print(on_axis((3, 0)), on_axis((0, -4)), on_axis((1, 1)))
```

`pattern as name` binds the whole value the pattern matched, beside
what the pattern takes apart:

```pyking
match (1, (2, 3)):
    case (x, (y, z) as inner):
        print(x, y, z, inner)
```

A **guard**, `case pattern if condition:`, is asked once the pattern has
matched, with what the pattern bound in scope. A guard that is false
goes on to the next case, as a pattern that does not match does. The
guard is a `Bool`:

```pyking
def sign(n: Int) -> String:
    match n:
        case 0: "zero"
        case m if m > 0: "positive"
        case _: "negative"


print(sign(5), sign(0), sign(-5))
```

Guards are asked in order, and only as far as the first that holds, so
one that calls a function calls it only when every case above it was
passed over.

### Datatypes — Pyking extension

`datatype` declares a type of its own: a name, the type variables it is
written over, and its **constructors**, one per indented line. A value
of the datatype is built by a constructor, and is one of them and
nothing else:

```pyking
datatype Shape:
    Circle(radius: Float)
    Rect(width: Float, height: Float)
    Dot


def area(s: Shape) -> Float:
    match s:
        case Circle(r): 3.0 * r * r
        case Rect(w, h): w * h
        case Dot: 0.0


print(area(Circle(1.0)), area(Rect(2.0, 3.0)), area(Dot))
print(Rect(2.0, 3.0), Dot)
```

The name of a datatype and of each constructor starts with an
uppercase letter, which is what tells a constructor from a name in a
pattern: `case Dot:` matches the constructor, and `case dot:` binds
whatever arrives. A constructor with no fields is written bare, `Dot`,
in a pattern and as a value. A datatype is declared at the top level of
a module, and every datatype of the module is in scope throughout it,
so datatypes may name each other in any order, and one may name
itself.

Constructors may share a line, separated by commas, and the first line
of them may follow the datatype's `:` directly; each further line of
them is indented under it:

```pyking
datatype Color: Red, Green, Blue
    Gray(level: Int), Black

datatype Bit: Zero, One

print(Gray(3), One)
```

A value prints as the constructor applied to its fields, every field by
position, a string among them quoted: `Rect(2.0, 3.0)`.

**A field** is a type alone, which makes it positional, or a name and a
type, which may also be given by name. A named field may carry a
default, any expression, and may leave its type to it:

```pyking
def opening() -> Int:
    return 100


datatype Account:
    Account(String, balance = opening(), currency = "SEK")


print(Account("ada"))
print(Account("grace", 10))
print(Account("don", currency = "EUR"))
```

A field with no type written has its default's type, and that default
has to decide one: `items = []` is refused, since an empty list says
nothing about what it holds. An exported datatype writes its fields'
types down, a literal default's apart (see "What a module may
export").

A constructor is called with exactly the rules a `def` is (see "Default
parameters" and "Named arguments"): positional arguments first, named
ones in any order, every field without a default
given something, and a default evaluated at each construction that
leaves it out, in the scope the datatype is declared in. The unnamed
fields come first, and every field after one with a default has one
too.

**A datatype may have parameters**, written as type variables after its
name, and applied to types where it is named -- `Tree(Int)`,
`Option(String)`. A polymorphic function over one is written and
inferred like any other:

```pyking
datatype Option(a):
    Nothing
    Just(a)


def default(o: Option(a), d: a) -> a:
    match o:
        case Just(x): x
        case Nothing: d


print(default(Just(3), 0), default(Nothing, "none"))
```

A field's type may name only the datatype's own parameters.

**A constructor pattern** takes a value apart by the same rules a call
puts one together: positional patterns first, then `field = pattern`,
here in any order, and a field the pattern does not mention matches
anything:

```pyking
datatype Person:
    Person(name: String, age: Int, admin: Bool = false)


def role(p: Person) -> String:
    match p:
        case Person(admin = true): "admin"
        case Person(n, age = a) if a < 18: n ++ " is young"
        case Person(name = n): n


print(role(Person("ada", 36)), role(Person("tim", 12)), role(Person("root", 1, true)))
```

**A named field is read with `.`**, `p.name`, where every constructor of
the datatype has a field of that name at one type -- so a datatype of one
constructor is a record:

```pyking
datatype Point:
    Point(x: Int, y: Int)


p = Point(3, 4)
print(p.x * p.x + p.y * p.y)
```

A constructor is not a value of its own: one with fields is always
applied to them, and `Point` alone is refused.

**Across modules**, `public datatype` exports the datatype and every
constructor. A constructor is reached through the module as any public
name is -- `shapes.Circle(1.0)`, `case shapes.Circle(r):` -- and a
datatype named on a `from` line brings its constructors with it:
`from shapes import Shape` makes `Circle` a constructor here. A public
definition whose type names a datatype that is not public is refused,
since a module holding such a value could not say its type.

### Structs — Pyking extension

`struct` declares a datatype of one constructor, named as the type is.
It means exactly the `datatype` it stands for, which is why everything
"Datatypes" says of fields, defaults, construction, patterns and
modules holds of it:

```pyking
struct Point(x: Int, y = 78)

# the same as
#   datatype Point:
#       Point(x: Int, y: Int = 78)

p = Point(7, 10)
print(p, Point(1), p.x + p.y)
```

Its fields are in parentheses after its name, or on indented lines under
its `:`, a line holding one or more separated by commas. With neither,
it has no fields:

```pyking
struct Size:
    width: Int, height: Int
    unit = "px"


struct Pair(Int, Int)


struct Empty


print(Size(4, 5), Pair(1, 2), Empty)
```

**Type parameters** are written in parentheses before the `:` of the
indented form. On one line, every type variable a field names is a
parameter, in the order they first appear:

```pyking
struct Pair(a, b):
    first: a
    second: b


struct Box(value: a, label = "box")


print(Pair(1, "one"), Box(true).label)
```

A struct's value, like every value in Pyking, never changes: there is
no assignment to a field. A changed copy is built instead.

**`..base`** as the last argument of a constructor gives every field
not written before it from `base`, a value of the same datatype, by
name:

```pyking
struct Point(x: Int, y: Int, z: Int = 0)


p = Point(7, 10)
print(Point(x = 5, ..p))          # Point(5, 10, 0)
print(Point(1, ..p))              # Point(1, 10, 0)
```

`Point(x = 5, ..p)` means `Point(x = 5, y = p.y, z = p.z)`: what is
written before the `..` is evaluated first, in the order written, and
`base` after it, once. Defaults play no part, since every field left
out comes from `base`. A field an update can fill is one with a
name, so an unnamed field is given before the `..`. `..` is written for
any datatype of one constructor -- one of several might not be the
constructor `base` was built by -- and is refused where it fills no
field, and in a call to a `def`, which has no fields to fill. Where the
datatype has parameters, the fields written may change them:
`Pair(first = true, ..Pair(1, "one"))` is a `Pair(Bool, String)`.

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
            "on the y axis, " ++ side
        case (x, y): "at " ++ string(x) ++ "," ++ string(y)
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
        case xx: string(xx)

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
| a `loop` | the accumulator it stopped with |
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
ending in a `for` or `while` that carries no accumulator:

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

### Lines and continuation

A statement ends where the tokens stop being able to continue it, and
each line's leading whitespace is what opens and closes blocks — but
**not while a bracket is open**. Inside an unclosed `(` or `[` the
indentation rules are suspended entirely, so a parameter list, a call's
arguments, a list literal, a comprehension and a tuple may each span
several lines:

```pyking
def window(
        start: Int,
        size: Int,
        step: Int) -> Int:
    return start + (size * step)


numbers = [
    1,
    2,
    3,
    4]

print(window(
    1,
    2,
    3))
```

The continuation lines are part of the same statement, and their own
indentation means nothing at all — it is there for the reader. Nesting
one bracket inside another keeps the line open until the outermost one
closes. Outside brackets, indentation means exactly what it did.

There is no backslash continuation: a line is continued by an open
bracket or not at all.

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

**Pyking is statically typed.** Every program is checked before anything
is printed, compiled or run — there is no flag for it and no way round
it — and a failure stops the compile. Static semantics come in three
kinds, reported under three labels:

- the shape rules the grammar cannot state: a value-form `if` must have
  its `else` and every branch must end in an expression (see the section
  on `if`/`match` statements as bound values), a `case` pattern may
  not bind the same name twice, and no name a program binds starts with
  an uppercase letter. These are reported as `Parsing error`.
- names and types, both settled by the checker: every name must be bound
  where it is used, and every value must have the type its use requires.
  An unbound name is a `Name error`; everything else below is a
  `Type error`.
- mutability, the one rule about a name that a type cannot state: `:=`
  may only name a `var`, and a `var` may not be shadowed (see "Names and
  scoping"). Also a `Name error`.

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
`Int`, `Float`, `String`, `Bool`, list types `[T]`, tuple types
`(T1, T2, ...)`
— with `(T,)` the one-element one and `()`, the zero-element tuple, the
unit type — function types `(T1, T2, ...) -> T`, datatypes (`Shape`,
`Tree(Int)`; see "Datatypes"), and type *variables* (see "Type
variables" below). Two datatypes are one type when they are the same
declaration applied to the same types: two datatypes of one name in two
modules are two types.

There is no "one of these" type. A value is an `Int` or it is a
`String`; nothing says it may be either, and there is no narrowing that
would make such a thing usable. A function that has to serve several
types serves them the way `map` does — with a variable, which says the
*caller* chooses and the body does not care. Where the body does care
— `string(value)`, say, which asks what it was given — there is nothing to
write and nothing to infer, and the definition means the one type it
was first used at. Closing that gap needs something like type classes,
which Pyking does not have.

The function type is the one a program rarely writes but the checker
constantly infers, since it is what a `def`'s *name* means. So it is
what `pyk compile -t pyking` prints for a name bound to a function,
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

### Numbers, and what the checker defaults to

`Int` and `Float` are two types and nothing converts between them on its
own. `+`, `-`, `*`, `/` and the five comparisons each take two operands
of **one** type, so one of each is refused where it is written:

```pyking error
print(1 + 1.0)
# Type error: `+` cannot be applied to Int and Float; it accepts
# Int + Int or Float + Float. Pyking mixes no numbers on its own:
# `float(n)` makes an Int a Float, and `int(x)` truncates a Float to an
# Int
```

Two builtins are what a program writes instead. `float(n)` widens an
`Int`; `int(x)` truncates a `Float` toward zero, the rounding `/`
already does on two Ints.

```pyking
total = 7
count = 2
print(total / count)                      # 3
print(float(total) / float(count))        # 3.5
```

Implicit widening is deliberately absent. It would mean `1 / 2` changed
meaning depending on what surrounded it, which is the thing about a
numeric tower that costs the most and is hardest to see.

**Where nothing has decided, an arithmetic operator means `Int`.** An
unannotated `def` whose parameters no literal and no call pins down is
an `Int` function:

```pyking
def add(a, b):
    return a + b          # add : (Int, Int) -> Int
```

That keeps every program written before Float existed compiling and
meaning what it did. A Float one says so — with an annotation, or with a
Float reaching the body:

```pyking
def fadd(a:Float, b:Float) -> Float:
    return a + b

def twice(x):
    return x * 2.0        # twice : (Float) -> Float
```

**The comparisons behave differently, and that is not an oversight.**
`<` answers `Bool` whichever type it compares, so it has nothing to
decide and leaves its operands open — exactly as `==` already did:

```pyking
def taller(a, b):
    return a > b          # settled by the first call, at either type
```

A `var` may hold a `Float`, as it may hold an `Int` or a `Bool`, which
is what a running total needs.

### What is checked

**Literals and names.** `1` is `Int`, `'s'` is `String`, `true` and
`false` are `Bool`. A name has the type of the binding it refers to,
under Pyking's ordinary lexical scoping.

**Operators.** Both operands must match the *same* signature:

| operator | accepts | gives |
|---|---|---|
| `+` | `Int + Int` | `Int` |
| `++` | `String ++ String` | `String` |
| `-`, `*`, `/` | `Int`, `Int` | `Int` |
| `-` (unary) | `Int` | `Int` |
| `++` | two lists of one type | that list type |
| `<`, `<=`, `>`, `>=` | `Int`, `Int` | `Bool` |
| `==` | two `Int`s, two `String`s or two `Bool`s | `Bool` |

So `1 + 'a'` is an error, and so is `'a' + 'b'` — `+` adds and only
adds, and joining two strings is `++`'s job. And so is `1 == 'a'` — a
comparison of two different types is refused rather than answered
`false`.

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
has; `-t pyking` then prints the type that was worked out, which is what
makes that output worth reading.

A `let` expression binds by the same rules: its value is checked where
the `let` is written, its annotation against that value, and its body
with the target bound. The `let` has its body's type. A name it binds
has one type, as a name an `=` binding binds does: binding a lambda
with `let` does not make it polymorphic.

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
print(fact(7), picked, 'grade ' ++ (if picked > 5 then 'a' else 'b'))
```

An `if` with no `else` supplies unit, whatever its one branch ends in:
there is a way through such a statement that runs no branch at all, so
there is no value it can be counted on for. A function that needed that
value is refused where the value was needed — at the function, not at
the `if`. A condition must be `Bool` — there is no truthiness.

**Tuples.** `(e1, e2, ...)` has the tuple type of its elements, `()` is
unit, and a binding may take one apart -- `a, b = pair` binds each name
to its part, and is refused if the value is not a tuple of that many.

**Loops.** A loop has one type, and it is the accumulator's: its
initializer's, which an annotation on the header is checked against
exactly as a binding's is, and which what the body ends in must give.
The loop itself is worth that type, since a loop is worth the
accumulator it stopped with:

```pyking
counted = loop x = 1:      # carries Int
    if x > 3:
        break              # and is worth Int
    else:
        x + 1              # the next turn's accumulator
```

A body that ends in something else is refused, since a turn would hand
on a value the next one cannot take:

```
'prog.pyk' 12:4-12:12 Type error: this loop carries Int, but its body
  ends in ()
```

`break`, `continue` and `return` supply *nothing*, which is what lets a
branch that breaks sit beside one that ends in the next accumulator
without either being a special case: the branch that supplies a value
decides, exactly as it does in an `if` one of whose branches returns. A
body all of whose paths jump is asked for nothing at all. A `return`
written in a loop body leaves the *function*, so what it gives is one
of the function's answers like any other `return`.

A `loop:` with no accumulator carries unit, is worth unit, and discards
whatever its body ends in -- so its body's last statement may be of any
type.

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
        'x' ++ spell(n - 1)          # checked against (Int) -> String


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

**Builtins.** `print`, `debug`, `range`, `string`, `len`, `int`,
`float` and `bool` are checked at the call, each by its own rule,
because none of them is a function *value*: a builtin is a host operation (see "Names
and scoping"), it has no type that can be written down, and it may be
called and nothing else.

| call | accepts | gives |
|---|---|---|
| `print(…)` | any number of arguments, of any type | `()` |
| `debug(…)` | any number of arguments, of any type | `()` |
| `string(x)` | one `Int`, `Float`, `String`, `Bool`, list or tuple | `String` |
| `len(x)` | one list or `String` | `Int` |
| `range(n)` | one to three `Int`s | `[Int]` |
| `int(x)` | one `Int`, `Float`, `String` or `Bool` | `Int` |
| `float(x)` | one `Int`, `Float`, `String` or `Bool` | `Float` |
| `bool(x)` | one `Int`, `Float`, `String` or `Bool` | `Bool` |

```pyking
count = len("hello")          # Int
label = "n = " ++ string(count)   # String
numbers = range(4)            # [Int]
ratio = float(count) / 2.0    # Float

print(label, numbers, count, ratio)  # anything, any number of them
```

**Conversions.** `string`, `int`, `float` and `bool` are how a value of
one type becomes another — Pyking converts nothing on its own. `string`
writes a value exactly as `print` would. The other three answer every
argument they accept, and where there is no right answer they answer a
**default**: 0 for `int`, NaN for `float`, false for `bool`.

- `int` truncates a Float toward zero, takes true to 1 and false to 0,
  and reads a String written as an optional `+` or `-` and decimal digits,
  with nothing around them — not a space, not a point, not `0x`. An
  answer outside the signed 32-bit range, and a Float with no Int to
  truncate to (a NaN, an infinity), is 0.
- `float` widens an Int, takes true to 1.0 and false to 0.0, and reads a
  String written the way a Float literal is — digits, an optional
  fraction, an optional exponent, and an optional sign — or as `inf`,
  `-inf` or `nan`, which is how `print` writes those. So
  `float(string(x))` is `x`.
- `bool` is true for `true`, the String `"true"`, the Int 1 and the Float
  1.0, and false for anything else — `"True"` and 2 included.

Each accepts its own type too, and answers it unchanged.

```pyking
print(int("42"), int("4 2"), int(-2.9), int(true))   # 42 0 -2 1
print(float("1e3"), float("one"), float(false))       # 1000.0 nan 0.0
print(bool("true"), bool("yes"), bool(1), bool(2.0))  # true false true false
print(string(1.5) ++ "!", string([1, 2]))             # 1.5! [1, 2]
```

The defaults stand in for an answer Pyking cannot yet give. Once it has
an **option type**, `int`, `float` and `bool` will answer either no value
or the value converted, so a program can tell `int("0")` from
`int("zero")`; until then it has to check the String itself.

Using one as a value rather than calling it is an error — `shout = print`
is refused — which is also what the C and Java backends do with `print`.

`debug` is `print`'s twin for diagnostic output — Pyking extension. It
takes and formats its arguments exactly as `print` does, and writes the
line where diagnostics go rather than to the program's output, so
tracing a program never changes what it prints. A program built in
**release mode** has every call to `debug` removed, arguments and all,
and `print` kept:

```pyking
def square(x: Int) -> Int:
    debug("square of", x)       # a diagnostic line, gone in release mode
    return x * x

print(square(7))                # 49, in both modes
```

A call removed in release mode is worth the unit it always was, so a
program means the same thing in both modes except for its diagnostics —
and for anything an argument to `debug` would have done, which does not
happen at all. That difference is also the reason `debug` exists beside
`print`: writing a diagnostic is not something a program is *observed*
to do, so `debug` will be allowed in a pure function, where `print` will
not.

A program may define a `debug` of its own, like any other name; a call to
it is an ordinary call, and release mode leaves it alone.

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


def shout(word:String) -> String: word ++ '!'


kind = sign(4)
loud = shout('hi')
```

### Type variables

An annotation may name a type it does not fix. A **type variable** is an
identifier beginning with a lowercase letter, and it stands for a type
the *caller* chooses:

```pyking
def id(x:a) -> a:
    return x


print(id(1))          # 1
print(id('two'))      # two
print(id(true))       # true
```

Every variable a written type leaves free is **quantified at its
outermost level**, so `(a) -> a` and `all a. (a) -> a` are the same
type. The quantifier may be written out, and one `all` may bind several
variables at once, but it is never needed at the top and is never
printed there:

```pyking
def pick(x:a, y:b) -> (a, a, b):     # all a b. (a, b) -> (a, a, b)
    return (x, x, y)
```

**A variable written twice is one type.** `(a, a) -> a` takes two
arguments of the same type, whichever the caller picks; two different
ones are refused. And a variable is **rigid inside the body that
declares it** — the body knows nothing about `a` beyond its being some
type, so `x + 1` on an `a` is an error where it is written rather than
at whichever call turned out to be wrong.

**A type may be written on a line of its own.** `def name : type` gives
the type of the `def name(...)` in the same block; the two need not be
adjacent, and the definition then writes no annotations of its own,
since a `def` says its type in one place or the other:

```pyking
def compose : ((b) -> c, (a) -> b, a) -> c

def compose(g, f, x):
    return g(f(x))
```

**A `def` with no body is a signature too**, with its parameters named:
`def scale(n: Int, factor: Int) -> Int`, on a line of its own, says what
`def scale : (Int, Int) -> Int` says. Every parameter has a type and none
has a default, and the result type is written, since the line declares a
function rather than defining one:

```pyking
def scale(n: Int, factor: Int) -> Int

def scale(n, factor):
    return n * factor

print(scale(6, 7))
```

**A single parameter needs no parentheses**: `x -> x` and `(x) -> x` are
one type — the `->` after the `)` is what makes the parenthesized list a
parameter list. With no arrow after it, one type in parentheses is
*grouping*, `(x)` being `x`, as the grammar notes above say; a
one-element tuple is `(x,)`, written with the comma the value `(1,)` is
written with.

**An `all` written inside a type stays there**, which is first-class
polymorphism: a parameter can demand a function that is itself
polymorphic, rather than one at whatever single type the caller picked.

```pyking
def both_ways : (all x. (x) -> x) -> String
def both_ways(f):
    return f('a') ++ string(f(1))       # f used at two types, in one body
```

Without the inner `all` the variable would be bound at the top, and `f`
would be a function at one type for the whole body.

**A polymorphic value fits wherever one of its instances does.** Every
instance of `all a. (a) -> a` exists, so it is a `(Int) -> Int` where
one is asked for. The inner `all` above is the stronger demand, and only
a value that really is polymorphic meets that one:

```pyking
def apply(f:(Int) -> Int, x:Int) -> Int:
    return f(x)


def id(x:a) -> a:
    return x


print(apply(id, 3))                  # 3
```

Type variables are **written and also inferred**. A `def` with no
annotations gets one wherever its body never asks what a parameter is
(see "Functions without annotations"), so the two halves of this
section describe one kind of type reached two ways — and the inferred
half is checked against the body exactly as a written one is.

### Lists and `match`, checked

A list literal's elements agree on one type, the way an `if`'s branches
do and for the same reason: they are all elements of the same list. The
empty list is the exception that proves it — with nothing to disagree,
`[]` is `[a]` for a type variable nothing has constrained, and since a
Pyking list is immutable it fits wherever a list of anything is
wanted:

```pyking
def count(xs:[Int]) -> Int:
    return len(xs)


print(count([]), count([1, 2]))     # 0 2
```

A **pattern is checked against the type of what it matches**, and what
it answers is the names it binds: `case [x, ..rest]` over a `[Int]`
gives `x : Int` and `rest : [Int]`. A pattern that could never match —
a String pattern over an Int — is refused where it is written.

The **arms of a `match` agree on one type**, again the `if` rule. Where
the arms disagree only in how general they are, the more general one
wins, which is what lets a base case return `[]`:

```pyking
def reverse(xs:[Int]) -> [Int]:
    match xs:
        case []:
            return []                    # [a], and so [Int] here
        case [x, ..rest]:
            return reverse(rest) ++ [x]
```

A constructor pattern is checked the same way: it demands that the
subject be its datatype, at parameters it leaves to be settled, and each
field's pattern is checked against that field's type. A guard is
checked in the environment its pattern binds, and must be a `Bool`.

A field written with no type has its default's type, worked out from
the default alone, where it is written: the field's uses agree with it
or are refused, and a default whose type is still open -- `[]`, or a
call answering a type variable -- is refused with a request to write the
type. An update `C(f = e, ..base)` is checked as `C(f = e, g = base.g,
...)`: `base` must have every field it fills, which is to say be a value
of `C`'s datatype.

### Exhaustiveness

**Every `match` matches every value of its subject's type**, whether
its value is taken or it is a statement. A `match` some value would
reach no case of is refused, and the refusal names such a value, as the
pattern that would match it:

```pyking error
datatype Shape:
    Circle(Float)
    Square(Float)
    Triangle(Float, Float, Float)


def area(s: Shape) -> Float:
    match s:
        case Circle(r): 3.0 * r * r
        case Square(a): a * a
```

```
'prog.pyk' 9:4-11:29 Type error: this 'match' does not match every
  value: no case matches Triangle(_, _, _). Add a case for it, or a
  'case _'
```

A `match` with nothing to do for most values says so with `case _: ()`.

What counts as covered is decided by the patterns and the type, exactly,
whatever they nest: a datatype's every constructor, both of a `Bool`'s
values, every length of a list (`[]` and `[x, ..rest]` between them take
them all), and a tuple position by position, so `(true, true)`,
`(true, false)` and `(false, _)` cover a `(Bool, Bool)`. An `Int` or a
`String` has too many values to name, so only a case that takes any of
them -- `_`, a name, or a `++` split with a name for all of the string
-- covers one.

**A case with a guard does not count towards covering**, since its
guard may be false:

```pyking error
def sign(n: Int) -> String:
    match n:
        case m if m > 0: "positive"
        case m if m <= 0: "not positive"
```

**Every case is reachable.** A case whose every value is taken by the
unguarded cases above it is refused rather than left as code that never
runs:

```pyking error
datatype Color:
    Red
    Blue


def name(c: Color) -> String:
    match c:
        case Red: "red"
        case _: "another"
        case Blue: "blue"
```

The two rules are one question asked twice -- is there a value this
pattern matches and no case above it does? -- which is how the refusal
can name the value it found.

A comprehension's `for` walks a list and its pattern binds over the
elements; an element the pattern does not match is left out rather than
being an error, matching what the construct already means.

### Functions without annotations

A `def` that did not write its type down is not checked where it is
written. It is worked out the first time something **uses** it —
calling it, or reading its name as a value — but not *from* that use. Its parameters start as types nothing has decided,
and what the **body** does with them is what decides them:

```pyking
def double(n):
    n * 2                    # nothing is checked here ...


doubled = double(21)         # ... here: `*` says n is Int, so double
                             # is (Int) -> Int
```

What comes out is the **principal type**: the most general type the body
has, from which every type it can be used at follows. So a definition is
worth the same whatever calls it and in whatever order:

```pyking
def apply(f, x):
    f(x)                     # apply : ((a) -> b, a) -> b, always
```

Three rules follow, and they are the whole of what a program has to
know:

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

**A body is still checked where it is written.** The call says *when*
the body is checked; it does not say what is in scope while it is. A
body that names something bound *after* the `def` is an error, however
late the call comes:

```pyking error
def f(n):
    n + offset               # error: unbound name 'offset'


offset = 10
print(f(1))
```

**A definition is worked out once**, at its first use, and every later
one uses what came out. A parameter the body never asks about becomes a
**type variable**, which is what lets one definition serve every later
call, at a different type each time:

```pyking
def echo(x):
    x


number = echo(1)             # number : Int
word = echo('two')           # word   : String
same = echo                  # same : (a) -> a
```

A parameter the body asks a question no *one* type answers is the
exception. `string` accepts an Int, a Float, a String, a Bool, a list
and a tuple, and Pyking has no way to say "any of those" — so such a parameter cannot become a variable
and is fixed instead to what the first call passed:

```pyking
def announce(value):
    'got ' ++ string(value)     # `string` asks what it was given


print(announce(1))           # announce : (Int) -> String
# print(announce(true))      # error: argument 1 has type Bool, but Int
                             #        was expected
```

That is a real limit rather than an oversight, and a written annotation
would not help either, because there is none to write.

**A parameter is not generalised.** A parameter used at *two* types
inside one body would have to be polymorphic itself, and inference does
not invent that — a `def` gets a type variable, a parameter gets a type:

```pyking
def use(f):
    print(f(1), f(true))     # error: argument 1 has type Bool, but Int
                             #        was expected
```

Writing the type down is how that program is expressed, and the checker
then enforces it (see "Type variables" above for the `all`):

```pyking
def use : (all a. (a) -> a) -> ()
def use(f):
    print(f(1), f(true))     # fine: `f` is polymorphic because it says so
```

That line is deliberate. Inferring such a type is undecidable in
general, and guessing at it made the checker's answers depend on the
order a program's calls were written in. Inference has one guarantee —
the principal type, always — and first-class polymorphism is written
rather than guessed.

**Handing over a polymorphic function does not narrow what receives
it.** What a body asks of a parameter is what that parameter is worth,
and being passed something more general than it asked for changes
nothing about the body:

```pyking
def id(x): x


def apply(f, x):             # apply : ((a) -> b, a) -> b
    f(x)


def bump(n): n + 1


print(apply(id, 'hi'))       # hi
print(apply(bump, 1))        # 2
```

The same definition serves both calls, and it would serve them in either
order: what `apply` is worth does not depend on which caller reached it
first.

The inferred signature is not taken on trust. The body is checked
against it a second time with the variables rigid — the same check an
annotated polymorphic function gets — so what is reported is always
something the checker enforces.

**Recursion is not a special case.** While a body is checked, its own
name means a plain type rather than a variable one, so a recursive call
is an ordinary call and its result is one more thing the body decides:

```pyking
def fact(n):                 # (Int) -> Int
    if n < 1:
        1
    else:
        n * fact(n - 1)


def forever(n):              # (Int) -> Int: `+ 1` says what the
    forever(n + 1) + 1       # recursive call gave back
```

Functions that name **each other** are worked out together and get their
type variables together, so `even` and `odd` below are one question with
one answer. A function they merely call is worked out first, and is
polymorphic by the time they use it.

```pyking
def even(n):
    if n == 0 then true else odd(n - 1)


def odd(n):
    if n == 0 then false else even(n - 1)
```

**Two functions of unknown type are indistinguishable**, so an `if` that
yields one of them is refused: nothing could say which of the two a
later call would be checking. Annotating either one settles it.

Which functions ended up with which types is what
`pyk compile -t pyking` prints, and is the best way to see what
was worked out — the reasoning behind all of this is in
[docs/type_inference.md](docs/type_inference.md).

### Names, and what is not checked

**Names are the checker's too.** Its environment *is* the scope, so it
applies the rules under "Names and scoping" — a name must be bound where
it is used, a block's bindings do not escape it, a name is visible only
after its own binding *unless it is a `def`*, an inner binding shadows an
outer one, a `def` may not share its name with another binding of its
block, and the builtins are in scope throughout. An unbound name is
reported as a name error rather than a type error, since that is what it
is:

```
'prog.pyk' 14:16-14:23 Name error: unbound name 'missing'
```

**Mutability is not a type.** A `var` may hold any type, and the checker
says only that each `:=` gives the type its declaration fixed; *which* names may be written to is a separate question, and
one a type cannot answer — the same `Int` is a `var` in one scope and an
`=` binding in another. So a pass of its own applies the two rules under
"Mutable variables": `:=` may only name a `var`, and nothing may shadow
one. Both are `Name error`s.

A name may be in scope and still have no type the checker knows — a
builtin, or a function's own name inside its own body. Using one is
refused as `Construct is not supported` rather than as an unbound name,
since the name is perfectly well bound; it is the *type* that is
missing.

### Overloading and implicits, resolved

Two more things the checker settles, and the only two where it decides
what a *name* means rather than what a type is (see "Static
overloading" and "Implicits").

**An overloaded call is resolved by its arguments.** They are checked
once, and each `q::name` definition in scope is then tried against what
they turned out to be. Exactly one fitting resolves the call; none and
several are both errors, and an argument type nothing has decided fits
every candidate, which is reported as such. The test is unification, so
choosing a candidate may be what *decides* an argument's type —
`leq([171, 10], [188])` picks `list::leq` and settles the element type
by doing so.

**An implicit parameter is resolved by name and type.** Every
`implicit` binding in scope whose base name is the parameter's is
tried, with its own implicit parameters set aside as obligations to
discharge in turn, in the scope of the call. A binding that was not
written `implicit` is never considered. Exactly one fit resolves it.

Both are questions about the program's *text*, settled once, where the
call is written. Nothing is deferred to a caller and nothing is decided
at run time: a program that compiles has one definition per call site,
chosen before anything runs.

## Modules

**One file is one module.** A file called `list.pyk` is the module
`list`, and a program is that file together with every module it
reaches. There is no declaration to write and no directory layout to
follow: the file's own name is the module's name.

### Nothing is exported by default

A name at the top of a module is the module's own until `public` is
written in front of it. `public` goes before a `def`, before a `def`'s
signature line, or before an `=` binding:

```pyking
# list.pyk

step = 1

public def next(n:Int) -> Int:
    return n + step


public def previous : (Int) -> Int
def previous(n):
    return n - step


public first: Int = 0
```

`next`, `previous` and `first` are what another module can reach.
`step` is not, even though `first` and both functions are worked out
from it: what a module exports is a name, not the things that name was
built from.

A definition says its type in one place or the other (see "Type
variables"), and `public` follows the same rule loosely: writing it on
either the signature line or the definition exports the definition, and
writing it on both is allowed and means the same thing.

Two restrictions hold:

- **A `var` cannot be public.** A module exports values and functions,
  not variables another module could write to.
- **An exported name is bound once.** A module exports one thing under
  one name, so a name marked `public` is not also bound a second time at
  the top level, and two `public`s of one name are refused.

### What a module may export

**A module says what it exports, in the file that exports it.** An
exported name carries its complete type in the source: a public `def`
annotates every parameter and its return type, or has a signature line
of its own, and a public `=` binding annotates its name:

```pyking
# Each of these says what it is.

public def next(n:Int) -> Int:
    return n + 1


public def double : (Int) -> Int
def double(n): n * 2


public size: Int = 12
```

```pyking error
public def triple(n): n * 3
```

```
'list.pyk' 1:0-1:27 Type error: 'triple' is public, and a public
  function or value needs a complete annotated type signature:
  annotate every parameter and the return type, or give it a 'def
  triple : ...' signature line.
```

A `def` that writes no annotations is worked out from a call — inference
reads a definition off its own module's use of it (see "Functions
without annotations"). That works out what this module's own program
needs, and it is not a promise to another one, so a call here does not
stand in for the annotations: what crosses the boundary is what the
source wrote down.

A `public datatype` or `public struct` says its fields' types the same
way: a field whose default is not a literal has its type written beside
it (`value: Int = start()`).

A written type is the type it always was, so an exported function is as
general as its annotation says. `identity` here is exported as
`(a) -> a` and may be used at every type:

```pyking
public def identity : (a) -> a
def identity(x): x
```

### Importing a whole module

`import` brings a module in under a name, and its public names are
reached through that name and a dot:

```pyking norun
import list
import web

print(list.next(7))
```

Several modules may be named on one line, which means exactly what the
separate lines mean:

```pyking norun
import list, web
```

A module may be brought in under a name of the program's choosing, which
is then the only name it has here:

```pyking norun
import numerical as nm

print(nm.sum(3))
```

### Importing names

`from` takes named things out of a module and binds them in this
module's own top level, so they are written without a qualifier. Each
may be renamed:

```pyking norun
from list import next, first
from list import previous as back

print(next(first))
print(back(2))
```

The module itself is *not* in scope after a `from` line: `list.next` is
an error there unless `import list` is also written.

**There is no `import *`.** Every name a module reaches is written down,
so reading the top of a file says where each of them comes from.

### What an import may name

A `from` line may only name something the module exports. A name the
module has but did not mark `public` is refused, and so is a name it
does not have at all.

Every name an import brings in must be free: a collision with anything
the importing module binds at its top level, with a builtin, or with
another import, is refused rather than settled by one of them winning.
`as` is how a collision is resolved.

An import belongs to a module's **top level** — it says what the module
is built from, so it cannot be written inside a `def`, a loop or a
branch. Like a `def`, an import is visible throughout the module rather
than from its line down, so where it is written among the other
top-level statements does not matter.

### Submodules

A definition whose name has a dot in it is in a **submodule** of its
module: `mymod.foo` is `foo` in the submodule `mymod`, and
`mymod.another.foo` is `foo` in `another` inside `mymod`. A submodule is
nothing but those names -- there is no file or declaration for it -- so
a library groups what it offers by subject inside one file:

```pyking norun
# hello.pyk
public def mymod.foo(x: Int) -> Int: x + 1
public def mymod.another.foo(x: Int) -> Int: x + 100
public mymod.limit: Int = 10

public datatype shapes.Shape:
    Circle(r: Float)
    Square(s: Float)

def mymod.helper(x: Int) -> Int: mymod.foo(x) * 2
```

A `def`, a signature line, an `=` binding and a datatype may have a
dotted name, at a module's top level only. A dotted datatype's
constructors are in its submodule too: `shapes.Circle(1.0)`, and `case
shapes.Circle(r):`. Each name is `public` or not on its own, as any
other is.

**Inside its own file**, a name in a submodule is always written with
its whole path -- `mymod.foo(1)`, even inside `mymod.helper` -- so a name
means the same thing wherever it is read. A submodule's name is then
taken in the whole file: nothing else there, at the top level or in any
block, may be called `mymod`, so `mymod.foo` is never a field of a
value. A dotted name and the plain one with `__` in place of each dot
(`mymod.foo` and `mymod__foo`) are one name, and a module may not define
both.

**From another module** there are four ways to reach one:

```pyking norun
import hello
print(hello.mymod.foo(7))          # through the module

from hello import mymod            # the submodule, by its own name
print(mymod.foo(8))
print(mymod.another.foo(8))

import hello.mymod as m            # the same, renamed; without `as`
print(m.foo(9))                    # it is known as `mymod`

from hello.mymod import foo        # one name out of it
print(foo(10))
```

`import hello.mymod` binds `mymod`, the last part, rather than `hello`.
A name a submodule did not make public is refused from outside, however
it is reached, and so are a submodule the module does not have and a
name the submodule does not have. A name that stands for a submodule
here -- `mymod` above, or `m` -- is taken in the whole file, as one of
the file's own is.

### A public implicit arrives unqualified

A `public` name is reached through the module name (`mod.less_index`).
A name that is **both `public` and `implicit`** is different: it is also
found by an unqualified call in the file that imports the module,
automatically, so an ordering a library defines is usable without being
named.

```pyking norun
# ordering.pyk
public implicit def int::leq(x: Int, y: Int) -> Bool: x <= y
public def less_index(elem: a, lst: [a],
                      implicit leq: (a, a) -> Bool) -> Int: ...
```

```pyking norun
# main.pyk
import ordering as ord

print(ord.int::leq(7, 8))       # by its full name, which always works
print(leq(88, 100))             # found because it is public *and* implicit
print(ord.less_index(10, [7, 4, 12, 2]))
```

`less_index` is public and not implicit, so it is reached through
`ord.` like anything else — but *its* implicit parameter is resolved at
each call, against everything in scope there, including implicits this
file writes itself.

Auto-import is **not transitive**: what is in scope is what this file
imports. If `main` imports `middle` and `middle` imports `ordering`,
`ordering`'s implicits do not reach `main`. The cost is that a library
cannot re-export another's orderings; the gain is that reading a file
says where every name it uses comes from.

### No circular imports

A module is compiled, and run, after everything it imports. Two modules
that import each other — directly, or round a longer ring — have no such
order, so a cycle is a compile-time error naming the ring it found:

```
'b.pyk' 1:0-1:8 Module error: these modules import one another: a -> b
  -> a. Pyking has no circular imports: a module is compiled, and run,
  after everything it imports
```

### When a module runs

A module's top level is ordinary code, and it runs **once**, before the
top level of anything that imports it. The order is the one the imports
themselves give, and the program's own module is last:

```pyking
# base.pyk
print("base")

public def one() -> Int:
    return 1
```

```pyking norun
# middle.pyk
import base

print("middle")

public def two() -> Int:
    return base.one() + 1
```

```pyking norun
# main.pyk
import middle

print("main")
print(middle.two())
```

```
base
middle
main
2
```

`base` runs before `middle` because `middle` imports it, and both run
before `main`. Nothing else about the order is promised, and nothing
needs to be: a program's modules form an acyclic graph, and every module
sees a fully-run version of everything it imports.

### Finding a module

`import list` in `dir/main.pyk` reads `dir/list.pyk` — a module is
looked for beside the file that imports it, whatever directory the
compiler was run from. There is no search path and no way to reach
another directory.

### A module implemented elsewhere

A module can be implemented in a target language rather than in Pyking.
A file called `sys_external.pyk` is still the module `sys`, but it holds
*signatures only* — every name it exports is written down with its type
and left without a body, in either form of a signature line; the one that
names its parameters says what each is for. A name ending in `_external` therefore never
names a module of its own: `import sys_external` is refused, and the
module is imported as `sys`.

```pyking norun
public def loadfile(path: String) -> String

public def start : Int
```

Importing it is no different from importing any other module, and a call
is checked against the type written here:

```pyking norun
import sys

print(sys.loadfile("notes.txt"))
print(sys.start)
```

Two rules hold of such a file, and each is refused where it is broken:

- **Signatures and nothing else.** No bodies, no top-level bindings. The
  file says what the module offers; something else provides it.
- **No type variables, and no functions but callbacks, in a
  signature.** A parameter may be a function whose own parameters cross
  the boundary and which answers `()`: the host calls it back, for its
  effect. No other function crosses, and one implementation cannot be
  polymorphic.

A plain `sys.pyk` is unaffected: a signature there still has to describe
a `def` in the same file, exactly as before.

**A module may be written in both.** `sys.pyk` and `sys_external.pyk`
are one module `sys`, not two: the first is written in Pyking against
what the second declares, and a program that imports `sys` reaches
everything either half offers, under the one name.

```pyking norun
# clock_external.pyk -- what the host provides
public def now() -> Int

def raw() -> Int


# clock.pyk -- written against it
public def doubled() -> Int:
    return raw() * 2
```

```pyking norun
import clock

print(clock.now())
print(clock.doubled())
```

Two things follow, and both are the ordinary rules read across the two
files rather than anything new:

- **A declaration is in scope in the Pyking half**, unqualified and with
  no import — `raw()` above is written as any other name of the module
  is, because it *is* one.
- **`public` means the same on either side.** `raw` is not public, so
  `clock.raw()` from another module is refused exactly as a `def`
  written without `public` would be. A name declared in one half and
  defined in the other is refused too: a module offers one thing under
  one name.

Everything else about such a module — which file implements it for which
target, what each Pyking type becomes on the other side, and how the
interpreter reaches it — is about *compiling* rather than about the
language, and lives in [docs/modules.md](docs/modules.md).

### Modules and types

An imported name has the type the checker gave it where it was written.
Nothing is inferred a second time and nothing crosses the boundary but
the exported names and their types, so a mistake about one is reported
where it is made:

```pyking norun
from list import next

print(next("seven"))
```

```
'main.pyk' 3:11-3:18 Type error: argument 1 has type String, but Int
  was expected
```

A public function whose type was never written down has the type the
checker worked out for it, including its type variables, so a
polymorphic function stays polymorphic across the boundary.
