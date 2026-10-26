# Steps towards a more complete Pyking

What Pyking is missing today, from operators to I/O, and the order in
which to add it. Two of the steps are *opt-in* parts of the language,
turned on per module with `use`:

- `use mutation` -- mutable variables (`var`, `:=`), destructive
  arrays and maps, mutable fields.
- `use objects` -- classes, methods, interfaces and inheritance.

Without them a module is **functional and immutable**: `=` binds, data
never changes in place, and a loop that adds something up is a `loop`
with an accumulator. Effects on the outside world -- `print`, `io`,
`fs`, `tinyweb` -- stay available everywhere. A library may use
mutation inside itself, and an external module (host code, as in
tinyweb) does whatever its host does; neither makes the module that
imports it mutable.

**Every module is parsed by the same parser.** `use` turns on
features; it never changes how anything is read. A construct belonging
to a feature that the module has not turned on is parsed as usual and
then refused as a syntax error, naming the `use` line that would allow
it.

This is a plan written before any code. Each step lists what it adds,
the decisions it needs, and what it touches. Where a decision is
proposed rather than settled, the step says so under **Open**.

**Status:** steps 1 and 2 are implemented (October 2026), with the
decisions marked **Decided** below; where the code and this file
disagree, the code is right. `PYKING.md` is the reference for what was
built.

## Contents

1. [Where Pyking stands](#where-pyking-stands)
2. [What every step touches](#what-every-step-touches)
3. [Step 1 -- `use`, and mutation behind it](#step-1----use-and-mutation-behind-it)
4. [Step 2 -- Operators and lambdas: `+` joins, `lam x. e`, `xs[i]`, `and or not` (`&& || !`), `!=`, `%`, `^`, bitwise `& | xor ~ << >>`](#step-2----operators-and-lambdas)
5. [Step 3 -- Equality and ordering on every data type](#step-3----equality-and-ordering-on-every-data-type)
6. [Step 4 -- Option, Result and failure](#step-4----option-result-and-failure)
7. [Step 5 -- Slicing, membership and richer `for`](#step-5----slicing-membership-and-richer-for)
8. [Step 6 -- Strings: interpolation, long strings, escapes](#step-6----strings-interpolation-long-strings-escapes)
9. [Step 7 -- The list library](#step-7----the-list-library)
10. [Step 8 -- Maps and sets](#step-8----maps-and-sets)
11. [Step 9 -- I/O and the system libraries](#step-9----io-and-the-system-libraries)
12. [Step 10 -- Type aliases and smaller type-system items](#step-10----type-aliases-and-smaller-type-system-items)
13. [Step 11 -- `use mutation`: arrays, mutable maps, compound assignment](#step-11----use-mutation-arrays-mutable-maps-compound-assignment)
14. [Step 12 -- `use objects`: classes and methods](#step-12----use-objects-classes-and-methods)
15. [Step 13 -- `use objects`: interfaces, inheritance, mutable fields](#step-13----use-objects-interfaces-inheritance-mutable-fields)
16. [Step 14 -- Tooling that a complete language implies](#step-14----tooling-that-a-complete-language-implies)
17. [Later, or not at all](#later-or-not-at-all)
18. [Summary table](#summary-table)

## Where Pyking stands

This is what the language has today, checked against `PYKING.md`, the
lexer's keyword list, `lib/`, and the interpreter (October 2026).

### What it has

| Area | Today |
|---|---|
| Literals | `Int` (decimal, `0x`, `0b`, signed 32-bit promised), `Float` (IEEE binary64), `String` (`'…'`/`"…"`, escapes `\n \t \r \\ \' \"`), `Bool` (`true`/`false`) |
| Operators | `+ - * /` over `Int` and `Float` (Int `/` truncates), unary `-`, `++` on strings and lists, `< <= > >=` on numbers, `==` on `Int`, `Float`, `String`, `Bool` |
| Data | lists, tuples, `datatype` (parameterised, named and defaulted fields), `struct` with `..p` update, field access `p.x` |
| Control | `if`/`else if`/`else`, `if … then … else`, `match` with guards, or-patterns, `as`, list and string patterns, exhaustiveness; `for x in xs`, `while`, `loop` with accumulator, `break`/`continue`, tail calls everywhere |
| Functions | `def`, lambdas `x => …`, `let … in`, default and named arguments, static overloading `int::f`, implicits, type variables and `all` (rank-n) |
| Bindings | immutable `=` with tuple destructuring, `var` and `:=` (always on today), block scoping |
| Modules | one file per module, `public`, `import`/`from`, submodules, external (host) modules |
| Types | HM inference with annotations, checked; no implicit numeric conversion |
| Builtins | `print`, `debug`, `range`, `len`, `string`, `int`, `float`, `bool` |
| Libraries | `io` (read, read_line, is_eof, write), `fs` (read_text, write_text, exists), `sys` (args, env, exit), `math`, `random` (pure, seeded), `text`, `time`, `tinyweb` |
| Targets | interpreter, Python, node/web/iweb, Java, OCaml, C (no-heap subset) |

### What it lacks

Probed against the interpreter, every one of these is refused today:

| Area | Missing | Today's error or workaround |
|---|---|---|
| Boolean logic | `and`, `or`, `not`, and their symbol spellings (step 2) | nested `if`; there is no way to combine two conditions in one expression |
| Comparison | `!=` | `if a == b then false else true` |
| Arithmetic | `%`, `^` (power), bitwise and, or, xor, not, shifts | `math.int::mod`, `math.pow` (Float only) |
| Equality | `==` on lists, tuples, datatypes | "`==` cannot be applied to [Int] and [Int]" |
| Ordering | `<` on strings, tuples, lists | "`<` cannot be applied to String and String" |
| Access | `xs[i]`, `s[i]`, slices, `t.0` | `text.char_at`, a recursive helper, or a pattern |
| Membership | `x in xs`, `"ab" in s` | `text.contains`; nothing for lists |
| Iteration | `for (k, v) in pairs`, `for c in "abc"`, `enumerate`, `zip` | a `for` header binds one name and walks only lists |
| Strings | interpolation, `"""…"""`, `\u{…}`, fixed-decimal formatting | `"x = " ++ string(x)` |
| Failure | Option, Result, `assert`, a defined failure | conversions answer 0/NaN/false; libraries return `""` (docs/libraries.md, "Failure, where the language has none") |
| Collections | a list library, maps, sets | each program writes its own `map`, `filter`, `sort` |
| Types | type aliases, equality-constrained type variables | write the type out each time |
| Mutation | arrays updated in place, mutable maps, `+=` | `var` holding an immutable list, rebuilt each time |
| Objects | classes, methods, interfaces, inheritance | datatypes, plus functions that take the value |
| I/O | reading all lines, listing directories, appending, failure reporting, JSON | `io.read` and a hand-written split |

## What every step touches

A feature is not done until every one of these is:

- **Front end**:
  - `src/lexer.ml`
  - `src/parser.ml`
  - `src/syntax.ml` (AST and the Pyking pretty-printer: `-t pyking` must round-trip)
  - the feature gate (step 1)
- **Analysis**:
  - `src/typesystem.ml`
  - `src/exhaustive.ml`
  - `src/elaborate.ml`
  - `src/analyses.ml`
  - `src/scopes.ml`
- **Running**:
  - `src/interpreter.ml`, including the debugger's view of values
  - the REPL
- **Backends**:
  - `target_python`
  - `target_js_core` and packaging (`node`, `web`, `iweb`)
  - `target_java`
  - `target_ocaml`
  - `target_c`, which states what needs a heap and is refused
- **Editors**:
  - LSP: completion, hover, semantic tokens, and a quick fix where one fits
  - the playground's Monaco grammar
  - `tools/editors/vscode/syntaxes/pyking.tmLanguage.json`
  - `tools/emacs/pyking-mode.el`
  - the notebook's code highlighting
- **Docs**:
  - `PYKING.md`: grammar, feature summary, details
  - `PYKING-TUTORIAL.md`
  - `docs/typesystem.md`
  - `docs/targets.md`: the shared-subset table
  - the help generator (`tools/help`)
  - `CHANGELOG.md`
- **Tests**:
  - `tests/*.pyk` with `.out`
  - a `fail_*` case per new error
  - `tests/test_cases.toml` exclusions, with reasons
  - a playground example where it teaches something

Each step below lists only what is particular to it.

---

## Step 1 -- `use`, and mutation behind it

The foundation for steps 11 to 13. It is small, it changes the meaning
of no program that is accepted, and it should land before anything else
makes mutation more attractive.

### Syntax

```pyking
use mutation

var total = 0
for x in [1, 2, 3]:
    total := total + x
print(total)
```

```ebnf
program     = { use_stmt } , { top_statement } ;
use_stmt    = "use" , feature , { "," , feature } ;
feature     = "mutation" | "objects" ;   (* read as identifiers, checked after *)
```

- **`use` is a new keyword**, reserved everywhere.
- **Placement:** `use` lines come first in a module, before any import
  or statement; comments may precede them. A `use` anywhere else is
  refused: "'use' turns on a feature for the whole module, so it is
  written before anything else".
- **The feature list:** a module may write several `use` lines, or one
  with commas. Naming a feature twice is refused, and so is an unknown
  one: "there is no feature 'mutaton'; the features are mutation and
  objects".
- **Reserve the future words now**, so that step 12 breaks no program:
  `use`, `class`, `interface`, `extends`, `self` and `super`.

### What `use mutation` gates today

| Construct | Without `use mutation` |
|---|---|
| `var x = e` | Parsing error |
| `x := e` | Parsing error |
| `loop x = …` | **not gated**: its accumulator is a fresh binding each turn, not a mutation |
| `while`, `for` | **not gated**. `for` is how a functional program prints each element, and `while not io.is_eof()` needs no mutable state |

The error names the construct and the cure, and points at the
construct:

```
'prog.pyk' 3:0-3:3 Parsing error: 'var' declares a mutable variable,
  which needs 'use mutation' at the top of this module
```

### Where the gate is

The gate is a pass over the parsed module, run before scoping and
type checking, for example `src/features.ml`. Its errors are reported
as `Parsing error`s. The parser records the `use` set in the module's
AST and otherwise ignores it. That keeps the promise that every module
is parsed by the same parser. The pass is one place that knows which
construct belongs to which feature, as `builtin.ml` is one table of
builtins.

### Scope of a `use`

- **Per module, never inherited.** Importing a module that uses
  mutation does not turn mutation on in the importer, and a module
  cannot turn a feature on for anything that imports it. The one
  exception is in step 11: a library whose API is mutation can require
  it of its importers.
- **Submodules** (`def mymod.f`) share their file's `use` set.
- **External modules** are host code, outside the language: tinyweb
  keeps its state in JavaScript, OCaml, C or Java, and its Pyking
  signature file needs no `use`.
- **The libraries in `lib/`** that use `var` today write `use mutation`
  themselves: `random`, `text` and `tinyweb`.

### Where else a program is written

- **REPL**: `use mutation` typed at the prompt turns it on for the rest
  of the session. `pyk repl --use mutation` does the same from the
  start.
- **Notebook**: each code cell is checked as its own module, so a cell
  writes its own `use`. **Decided**: per cell; no notebook-wide
  setting.
- **Playground**: like a file. The LSP offers a quick fix, "Add 'use
  mutation' at the top of the module", on the gate's error.

### Migration

These programs use `var` or `:=` today and each gets a `use mutation`
line:

| Where | Files |
|---|---|
| `tests/*.pyk` | 67 |
| notebook test files under `tests/notebook` and `tests/nbjson` | 22 |
| `web_examples/`, `pyking-web-examples/` | 21 |
| `lib/` | 3 |

- **Also update** the examples in `src/examples.toml`, and the
  examples in `PYKING.md` that use `var` (the section "Mutable
  variables" moves under a new section "Features turned on with
  `use`").
- **New tests**: a `fail_use_*` case for each refusal (gated construct,
  misplaced `use`, unknown feature, repeated feature).
- **A test that importing is not inheriting**: a module using
  mutation, imported by one that does not.

### Open

- Should a feature be turned on from the command line
  (`pyk --use mutation prog.pyk`) for teaching set-ups? **Decided**: no
  outside the REPL (`pyk repl --use mutation`), so that a file always
  says what it needs.

---

## Step 2 -- Operators and lambdas

Four changes: `+` takes over joining from `++`, lambdas are written
`lam x. e` instead of `x => e`, lists are indexed with `xs[i]`, and the
missing Boolean, arithmetic and bitwise operators arrive. The most
visible gap is the last: today no expression can combine two
conditions.

### `+` joins strings and lists, and `++` goes

| Operands | `+` gives |
|---|---|
| `Int + Int` | `Int`, addition |
| `Float + Float` | `Float`, addition |
| `String + String` | `String`, the two joined |
| `[a] + [a]` | `[a]`, the two joined |

```pyking
print("con" + "cat", [1, 2] + [3, 4])     # concat [1, 2, 3, 4]
greeting = "Hello, " + name + "!"
```

- **One type on both sides, always.** Every operand of a `+` is a
  number of one type, or every one is a String, or every one is a list
  of one element type. Nothing is converted and nothing is mixed, so
  each of these is a type error that names the cure:

  ```
  "n = " + 5          # `+` cannot be applied to String and Int; write string(5)
  [1, 2] + 3          # `+` cannot be applied to [Int] and Int; write [3]
  "ab" + ["c"]        # `+` cannot be applied to String and [String]
  [1] + ["a"]         # the two lists hold Int and String
  ```

  A chain `a + b + c` is left-associative, so the rule holds for every
  operand: all strings or all lists, never a mixture.
- **Inference**: `+` becomes one more overloaded operator, with four
  rows instead of two. **As built**: a `+` whose operands nothing has
  decided is left open and decided by a later use -- as `++` was --
  and a definition is not generalised over it; what nothing decides by
  the end of the module adds two Ints (docs/typesystem.md).
  - **Deciding the row**: where an operand's type is known, it
    decides; a String literal on either side makes the other side a
    String.
  - **Default**: where nothing decides, `+` defaults to `Int`, as the
    arithmetic operators do today (design/plan-float.md, decision 1).
    So `def join(a, b): a + b` is `(Int, Int) -> Int` unless annotated
    or used at another type first.
  - **`-`, `*`, `/` and `%` stay numeric.** There is no `"ab" * 3`;
    `text.repeat` does that.
- **Patterns follow**: the pattern that splits a list or a string is
  written with `+` too, as in `case [first] + rest:` and
  `case "get " + path:`. The rules for what may stand on each side are
  the same as today's `++` pattern.
- **`++` is removed**: the lexer still reads the token, and the parser
  refuses it where it stands: "'++' is now written '+': `a + b` joins
  two strings or two lists". It stays refused rather than becoming
  free, so an old program never changes meaning silently.
- **Why**: Python, JavaScript and Java all join strings with `+`, and
  every student arriving from one of them writes it first. The
  argument in `PYKING.md`, "Concatenation", that `+` should only ever
  add, is given up. The rule "all strings or all lists" keeps what
  mattered from it: `+` still never converts, so `"2" + 3` is an error
  and not `"23"`.
- **Backends stay as they are**: after type checking, `elaborate.ml`
  rewrites a `+` at String or list type into the concatenation node
  that `++` produces today. No backend learns anything new: Python,
  JavaScript, Java, OCaml (`^`, `@`) and C (a string join that
  allocates) keep emitting what they emit for `++` now.
- **Migration**: a script, not `sed -i`, rewrites `++` to `+`
  outside strings and comments. It covers:

  | Where | Files |
  |---|---|
  | `tests/*.pyk` | 173 |
  | `lib/` | 6 |
  | notebooks (essentials and test notebooks) | 11 |
  | `web_examples/`, `pyking-web-examples/` | 25 |

  It also covers `PYKING.md`, `PYKING-TUTORIAL.md`, the help pages and
  the playground examples. The `.out` files do not change. The editor
  grammars drop `++` as an operator.

### Lambdas are written `lam x. e`, and `=>` goes

```pyking
inc = lam x. x + 1
add = lam (x, y). x + y
typed = lam (x: Int). x * 2
later = lam (). print("now")
curried = lam x. lam y. x + y
print(list.map([1, 2, 3], lam n. n * n))
```

| Today | New |
|---|---|
| `x => x + 1` | `lam x. x + 1` |
| `(x, y) => x + y` | `lam (x, y). x + y` |
| `(x: Int) => x * 2` | `lam (x: Int). x * 2` |
| `() => print("now")` | `lam (). print("now")` |

```ebnf
lambda        = "lam" , lambda_params , "." , expr ;
lambda_params = ident
              | "(" , [ param , { "," , param } ] , ")" ;
```

- **What it means is unchanged**: a lambda is still one expression,
  monomorphic, with no default values, and its body still takes
  everything to its right that one expression can hold. So
  `lam x. lam y. x + y` nests to the right, and a comma ends the body,
  as it ends `=>`'s today: `lam x. x, 2` is a pair.
- **`lam` is a new keyword**, reserved everywhere. No program in the
  repository uses it as a name.
- **`=>` is removed**: the lexer still reads the token, and the parser
  refuses it with "a lambda is now written 'lam x. x + 1'".
- **A gain for the parser**: `lam` says at the start that a lambda
  begins. Today `(x)` is a parameter list only if `=>` follows it, and
  `src/parser.ml` tries the parameter list and falls back
  (`PYKING.md`, the lambda grammar note). With `lam`, that guess goes.

#### Problems with the syntax, and how this design avoids them

The `.` already has four jobs in Pyking, and the lambda's `.` must not
collide with any of them:

| `.` today | Example | Collides with `lam … .`? |
|---|---|---|
| field access | `p.x` | no: the parameters are read up to the first `.`, so `lam p. p.x` is clear |
| module and submodule names | `geo.area`, `def geo.area(…)` | no, for the same reason |
| qualified type names | `geo.Point` | **yes, in a typed parameter**, see below |
| quantifiers | `all a. (a) -> a` | **yes, in a typed parameter**, see below |
| Float literals | `1.5` | no: a Float needs a digit on each side of its point, so `lam x. 1.5` and `lam x.1` lex the same way |

1. **Unparenthesised typed parameters would be ambiguous.** In
   `lam x: a. Some(x)`, the type `a. Some(x)` reads as the qualified
   type `a.Some(x)`. In `lam f: all a. (a) -> a. f(1)`, it is unclear
   which `.` ends the parameters. **Avoided**: a typed parameter, or
   more than one parameter, is always written in parentheses:
   `lam (x: a). Some(x)`. Inside parentheses the type ends at the `)`,
   so the `.` after it can only be the lambda's. An unparenthesised
   parameter is a single name with no type.
2. **`lam x.y` with no space** is a lambda whose body is `y`, not a
   lambda reading field `y` of `x`. It is unambiguous to the parser,
   but a reader can take it for field access. **Decided**: accepted
   without a space, as the lambda calculus writes `λx.y`; no layout
   rule.
3. **Several parameters: `lam (x, y)` or `lam x, y`?** The proposal is
   parentheses, the same list a `def` writes, because `lam x, y. e` in
   a call (`f(lam x, y. e)`) looks like two arguments. `(x, y)` is a
   parameter list, not a tuple pattern, as it is for `=>` today: a
   lambda taking one pair is written `lam (p). let (a, b) = p in a + b`.
   **Not proposed**: `lam x y. e`. It reads as curried, and Pyking
   functions take several arguments at once, so `lam x. lam y. e` is
   how currying is written.
4. **No parameters**: `lam (). e`, matching `def f():`. **Decided**:
   `lam (). e`; `lam. e` is not accepted.
5. **Familiarity.** `lam x. e` follows the lambda calculus
   (`λx. e`), not Python's `lambda x: e` or JavaScript's `x => e`. That
   is a deliberate choice for teaching, not a syntax conflict.
   `lambda x: e` cannot be used anyway: a `:` there would clash with
   the type annotation on a parameter.

- **Migration**: the same rewriting script as for `++` turns `=>`
  lambdas into `lam` ones, in 18 test programs and 4 notebooks. No
  library and no web example uses a lambda.
- **Docs**: `PYKING.md`, "Lambdas", and the tutorial. The JavaScript
  backend emits `=>` itself; that is generated code and is unaffected.

### Lists are indexed with `xs[i]`

```pyking
xs = [10, 20, 30]
print(xs[0], xs[2], xs[len(xs) - 1])     # 10 30 30
rows = [[1, 2], [3, 4]]
print(rows[1][0])                        # 3
```

- **`e[i]`** reads element `i` of a list, counting from 0. The list
  is any expression of type `[a]`, the index an `Int`, and the result
  an `a`. It is read-only: writing `xs[i] := v` is an array's (step
  11), and a list never changes.
- **Grammar**: an index is a tail after an atom, beside a call and a
  field, so it binds as tightly as they do and chains:
  `f(x)[0]`, `p.items[2]`, `rows[1][0]`.

  ```ebnf
  atom        = ( … ) , { call_tail | field_tail | index_tail } ;
  index_tail  = "[" , expr , "]" ;
  ```

- **A `[` on the next row starts a new statement**, as a `(` already
  does (`PYKING.md`, `call_tail`), so a list literal on its own line
  is not read as indexing the line before. The `[` of an index is on
  the row its list ends on.
- **Out of range**, including any negative index, is a runtime error
  in the interpreter, and whatever the host does in compiled code,
  until step 4 makes it a defined failure on every target. So `xs[-1]`
  is not the last element. **Decided**: refused now (a runtime error in
  the interpreter); Python's negative indices are decided together with
  slicing in step 5, so that `xs[-1]` and `xs[-2:]` follow one rule.
- **Lists only, for now.** Strings, slices, tuples and maps are
  indexed in steps 5 and 8. **Not here**: `t[0]` on a tuple, which
  would need a different result type per index.
- **Type errors** name the cure: `xs["a"]` says the index must be an
  Int, and `n[0]` on an Int says only a list is indexed.
- **Cost**: O(1) is not promised. A list is an array on Python, JS
  and Java and the interpreter, so it is O(1) there; on `ocaml` it is
  a linked list, so `List.nth` is O(i). The C target refuses lists
  already.
- **Backends**:

  | Target | `xs[i]` becomes |
  |---|---|
  | Python, JS | `xs[i]` |
  | Java | `xs.get(i)` |
  | OCaml | `List.nth xs i` |
  | interpreter | an index into its list value |

### Boolean, arithmetic and bitwise operators

| Operator | Types | Meaning |
|---|---|---|
| `a and b`, `a or b` | `Bool`, `Bool` → `Bool` | short-circuit: `b` runs only when needed |
| `a and b`, `a or b` | `Int`, `Int` → `Int` | bitwise and, bitwise or: the same as `a & b` and `a` or-bar `b`. Both operands always run |
| `not a` | `Bool` → `Bool` | negation |
| `not a` | `Int` → `Int` | bitwise not: the same as `~a` |
| `a != b` | whatever `==` takes | `not (a == b)`; for Floats this is IEEE `!=`, so `nan != nan` is true |
| `a % b` | `Int` or `Float`, one type | remainder; Int truncates toward zero like `/`, so `a == (a / b) * b + a % b`. Float is C's `fmod` |
| `a ^ b` | `Int ^ Int` → `Int`, `Float ^ Float` → `Float` | power, as in mathematics (and Lua, Haskell, Julia); right-associative, so `2 ^ 3 ^ 2` is `2 ^ 9`; binds tighter than unary minus, so `-2 ^ 2` is `-4`, as `-2²` is in mathematics |
| `a & b` | `Int`, `Int` → `Int` | bitwise and |
| `a xor b` | `Int`, `Int` → `Int`, `Bool`, `Bool` → `Bool` | bitwise exclusive or, an infix word, since `^` is power; on Bools, true where exactly one is |
| `~a` | `Int` → `Int` | bitwise not: `-a - 1`, the two's complement reading on every target |
| `a << n` | `Int`, `Int` → `Int` | shift left: `a` times 2ⁿ, overflow undefined as for `*` |
| `a >> n` | `Int`, `Int` → `Int` | arithmetic shift right: the sign is kept, so `-8 >> 1` is `-4` |

Bitwise or is `a | b` on two Ints. It is left out of the table above
only because a `|` cannot be written inside a Markdown table cell.

```pyking
flags = 0b0101
print(flags & 0b0100, flags | 0b0010, flags xor 0b1111, ~flags)   # 4 7 10 -6
print(1 << 4, 256 >> 2, -8 >> 1)                                   # 16 64 -4
```

**Two spellings.** `&&` is another way to write `and`, `||` another
way to write `or`, and `!` another way to write `not`. The words read
like Python; the symbols are what students arriving from C, Java or
JavaScript write first, and what they will meet next. On Bools each
pair is one operator: the same short-circuit, the same AST node. Only
the words also work on Ints (below).

```pyking
if x > 0 and not done: print(x)
if x > 0 && !done: print(x)          # the same
```

**On Ints, the words are bitwise.** `and`, `or` and `not` are
overloaded like `+`: on two Bools they are logic, on two Ints they are
the bitwise operators of this step.

```pyking
print(12 and 10, 12 or 10, not 0)        # 8 14 -1
print(12 & 10, 12 | 10, ~0)              # the same
mask = flags and 0xff                    # an Int
```

- **One type on both sides**, as for `+`: `1 and true` is refused.
- **No short-circuit on Ints.** `0 and f()` still calls `f()`: a
  bitwise result needs both operands, and `0` is not "false".
- **Inference**: where nothing decides the operands' type, the words
  default to `Bool`, not `Int`. `def both(a, b): a and b` is
  `(Bool, Bool) -> Bool`. Logic is what these words are written for
  most often, and the default keeps every program that compiles today
  meaning the same.
- **Precedence does not change with the type.** `and` stays looser
  than comparison, so `x and 1 == 1` is `x and (1 == 1)`: an Int and a
  Bool, which is refused. Mask tests are written with parentheses,
  `(flags and 4) == 4`, or with `&`, which binds tighter than `==`.
- **The symbols stay `Bool` only.** `&&`, `||` and `!` on Ints are
  refused with a hint: "on Ints, write 'and' or '&'". In C and
  JavaScript, `5 && 2` is `1` (or `2`) and `!5` is `0`. Making them
  bitwise here would give a student from those languages a different
  answer with no error. **Decided**: the symbols stay Bool's alone.
- **Python differs too.** In Python `12 and 10` answers `10` (the
  second operand, by truthiness), not `8`. Here it is a type-checked
  bitwise and, so the step's tests and the `PYKING.md` section must
  call this out for Python students.
- **Backends**: after type checking, `elaborate.ml` rewrites `and`,
  `or` and `not` at Int type into `&`, `|` and `~`. No backend sees
  the overload.

**No truthiness.** `and`, `or` and `not` take a `Bool` or an `Int`,
never a list, a String or anything else, and `if` still takes only a
`Bool`. `if xs:` stays a type error, rather than meaning "is not
empty", and `if n and 1:` is refused because its condition is an
Int.

**Precedence**, loosest first, Python's:

```
lam     <  if-expr  <  or ||  <  and &&  <  not  <  comparison
        <  |  <  xor  <  &  <  << >>  <  + -  <  * / %
        <  unary - ! ~  <  ^  <  call/field/index
```

```ebnf
expr        = lambda | if_expr | let_expr | disjunction ;
additive    = multiplicative , { ( "+" | "-" ) , multiplicative } ;
pattern_join = pattern_atom , { "+" , pattern_atom } ;
disjunction = conjunction , { ( "or" | "||" ) , conjunction } ;
conjunction = negation , { ( "and" | "&&" ) , negation } ;
negation    = "not" , negation | comparison ;
comparison  = bit_or , [ comp_op , bit_or ] ;
comp_op     = "<" | "<=" | ">" | ">=" | "==" | "!=" ;
bit_or      = bit_xor , { "|" , bit_xor } ;
bit_xor     = bit_and , { "xor" , bit_and } ;
bit_and     = shift , { "&" , shift } ;
shift       = additive , { ( "<<" | ">>" ) , additive } ;
multiplicative = unary , { ( "*" | "/" | "%" ) , unary } ;
unary       = ( "-" | "!" | "~" ) , unary | power ;
power       = atom , [ "^" , unary ] ;
```

### Decisions

- **New keywords**: `and`, `or`, `not` and `xor` are reserved. `&&`,
  `||`, `!`, `&`, `|`, `~`, `<<` and `>>` are new tokens in
  expressions; the lexer reads the longest one, so `!=` is still
  inequality, `&&` is never two `&`, and `<<` is never two `<`.
- **`!` binds as tightly as unary `-`**, as it does in C, Java and
  JavaScript, where `not` binds as loosely as Python's. So `!a == b` is
  `(!a) == b`, as a student from those languages expects, and
  `not a == b` is `not (a == b)`, as one from Python expects. They are
  still one operator; only where it may be written differs.
- **Mixing spellings** in one expression (`a and b || c`) is allowed:
  `||` and `or` share a precedence level, as do `&&` and `and`.
  **Decided**: allowed.
- **The spelling is kept**: the AST records which spelling was
  written, so `-t pyking` prints the program back as it was written.
  Backends ignore it.
- **Patterns**: `||` in a pattern is refused with "alternatives in a
  pattern are separated by '|'", since `case 1 || 2:` is the likely
  slip.
- **Comprehension filters**: `x in xs` is not an operator until step
  5, so a comprehension's `if` filter has no ambiguity to resolve yet.
- **`%` by zero**: undefined, as `/` by zero is today. Step 4 may
  define both together.
- **`^` with a negative Int exponent**: refused at run time with a
  defined failure once step 4 exists. Until then it is undefined.
- **`^` is power, not XOR.** Python spells power `**` and XOR `^`;
  Pyking follows mathematics instead, and writes exclusive or as the
  infix word `xor`, beside `and` and `or`. A program carried over from
  Python that writes `a ** b` gets a parse error suggesting `a ^ b`,
  and the Python backend emits `**` (C emits `pow`, or a loop for
  Int). Each backend emits its own XOR for `xor`: `^` in Python, C,
  Java and JS, `lxor` in OCaml.
- **Bitwise operators take `Int` only.** On two Bools, `&` and `|` are
  refused with a hint: "on Bools, write 'and' (or '&&')". Pyking keeps
  one way to combine conditions and that way short-circuits. The words
  `and`, `or` and `not` are the one bridge: they work on both, as
  logic on Bools and bitwise on Ints. **Decided**: `xor` works on two
  Bools too, as `!=` does (first refused with a pointer to `!=`, then
  allowed). Elaboration turns it into a Bool xor node that the
  backends emit as `!=` (`<>` in OCaml), since JS `^` gives a number.
- **Precedence is Python's**: the bitwise operators bind tighter than
  comparison, so `flags & mask == 0` is `(flags & mask) == 0`, as in
  Python. C, Java and JavaScript read it the other way, which is a
  well-known bug in those languages, not a convention worth copying.
- **`|` in expressions and in patterns.** In a pattern `|` separates
  alternatives, as today; in an expression it is bitwise or. A pattern
  holds no expressions, so the two never meet. A guard
  (`case n if n | 1 == 3:`) is an expression and reads `|` as bitwise
  or.
- **Shifts by a negative count, or by 32 or more**, are undefined, as
  Int overflow is (`docs/targets.md`, "Integers hold 32 bits"). Hosts
  differ there: JavaScript takes the count modulo 32, Python
  shifts by any amount. Step 4 may define the negative case together
  with division by zero.
- **`>>` is arithmetic on every target**: `>>` in Python, Java and JS
  (never JS's `>>>`), `asr` in OCaml. C leaves `>>` of a negative
  number to the compiler, so the C backend emits a helper that keeps
  the sign. `~` is `~` in C, Java, JS and Python, and `lnot` in
  OCaml.
- **Integer width.** An Int holds at least 32 bits, so `~`, `<<` and
  `xor` agree on every target for results inside the signed 32-bit
  range. JavaScript's bitwise operators work on 32-bit integers, which
  is exactly that range; outside it the result is undefined, as
  for `+`.
- **Compound assignment** under `use mutation` (step 11) covers these
  too: `&=`, `|=`, `<<=` and `>>=`. **Open**: `xor=`, which reads
  oddly; the proposal is to leave it out.
- **Short-circuit on every target**: `&&`/`||` in C, Java, JS and
  OCaml, and `and`/`or` in Python, whichever spelling the source
  used. A side effect in the right operand is
  a test.
- **Chained comparisons** (`a < b < c`) stay refused. The proposal is
  to say so with a suggestion: "write 'a < b and b < c'".

**Exhaustiveness**: a guard written with `and` is still opaque to
`exhaustive.ml`, as guards are today.

---

## Step 3 -- Equality and ordering on every data type

`==` works on four types today. A list of points cannot be compared,
searched or sorted, and a map (step 8) needs ordered keys.

### What it adds

- **`==` and `!=`** on lists, tuples, datatypes and structs, compared
  structurally and element by element. Floats inside compare by IEEE
  rules, so `[nan] == [nan]` is false.
- **`<`, `<=`, `>` and `>=`** compare these:
  - strings: by Unicode code point, lexicographically
  - `Bool`: `false < true`
  - tuples and lists: lexicographically, element by element
  - datatypes: by constructor order in the declaration, then by
    fields. **Open**: whether to give datatypes ordering at all, or
    only `==`. The proposal is to include it, because sorting a list
    of `Card(suit, rank)` is a classic exercise.
- **Refused:** comparing a function, or anything holding one. The
  error names the function type found inside.

### Polymorphic code

`def contains(xs: [a], x: a)` needs `==` on `a`. The proposal is
**equality and ordering type variables**, as in Standard ML: the
checker infers that `a` must be comparable, and a call at a function
type is refused where it is made. They are compiled by **passing the
comparison as a hidden argument**, as `elaborate.ml` already does for
implicits, so every target gets them, C included. The programmer
writes nothing.

- **The alternative**: make `==` an implicit
  (`implicit eq: (a, a) -> Bool`) that the user's code mentions. This
  is more general, since a user could define their own equality, but
  heavier for beginners. The proposal is to infer the constraint and
  leave user-defined equality to step 12, where classes can define
  `eq`.

### Targets

- **Python, OCaml and the interpreter** already compare structurally.
  Check that datatypes compare by constructor order, not by name, and
  that the interpreter has an ordering at all.
- **JS, Java and C** need a generated comparison per type, or a
  runtime helper that walks values with a type descriptor.
  `target_js_core` already formats Floats through a shape descriptor
  computed from the types (`docs/target_js.md`), and the same
  mechanism serves here.
- **C** generates one `eq_T` / `cmp_T` per type in use, for the types
  it supports.

---

## Step 4 -- Option, Result and failure

`PYKING.md` already promises this: "Once it has an option type, `int`,
`float` and `bool` will answer either no value or the value
converted". Libraries cannot report failure today (docs/libraries.md).

### A prelude

A module that every program imports implicitly (`lib/prelude`) holds:

```pyking
public datatype Option(a): None, Some(a)
public datatype Result(a, e): Ok(a), Err(e)
```

- **Names:** `None`, `Some`, `Ok` and `Err` are constructors in scope
  everywhere and may be shadowed by imports. `None` reads as Python's
  `None` would, which is a feature here.
- **Helper functions**: `option.or_else(o, default)`, `option.map`,
  `result.map`, `result.is_ok`, and so on. Whether they live in the
  prelude or in `lib/option` and `lib/result` is open.

### Conversions

`int("4 2")` answers 0 today.

- **Proposal**: keep `int`, `float` and `bool` total, as they are, and
  add `parse_int`, `parse_float` and `parse_bool` (builtins, or in
  `text`). Each returns an `Option`.
- **Why**: changing `int(s)` itself would break every program that
  reads a number, and would make `int(3.7)` and `int("3")` differ in
  type.
- **Open**: whether this contradicts the promise in `PYKING.md`. That
  paragraph would then be rewritten.

### Defined failure

| Construct | Meaning |
|---|---|
| `fail(message)` | a builtin of type `(String) -> a`. It stops the program, writes `error: message` to standard error, and exits with status 1, the same on every target |
| `assert cond` / `assert cond, message` | a statement, `fail("assertion failed: …")` with the source position. Removed by `--release`, like `debug`. `assert` becomes a keyword |

- **What becomes defined**: index out of range (steps 2 and 5), a missing
  map key (step 8), and **open**: Int division and `%` by zero. Today
  that is the host's choice (`docs/targets.md`, "Differences that
  survive the subset"). Defining it costs a check per division on C,
  JS and Python, so the proposal is to define it, because a beginner's
  program should fail the same way everywhere.
- **No exceptions.** Nothing catches a `fail`. Recoverable failure is
  a `Result`, and a library that can fail returns one (step 9).

### Later

A `?` operator that returns early from `Err` or `None`
(`n = parse_int(s)?`) makes Result usable without nested `match`es. It
is left to a follow-up once real programs show whether it is missed.

---

## Step 5 -- Slicing, membership and richer `for`

### Slicing, string indexing and negative indices (default, read-only)

List indexing `xs[i]` arrives in step 2. This step extends it:

```pyking
xs = [10, 20, 30]
print(xs[-1], xs[1:], "pyking"[0], "pyking"[0:2])   # 30 [20, 30] p py
```

- **`s[i]`** reads a string's character, a `String` of length 1,
  counted in code points (step 6).
- **`e[a:b]`** slices a list or a string, either bound optional,
  clamped as in Python, so a slice never fails.
- **Negative indices**, decided here for indexing and slicing
  together. Python has them and students coming from Python expect
  them, but they hide off-by-one bugs. The proposal is to allow them,
  as in Python, in both: `xs[-1]` is the last element.
- **Out of range** is now a defined failure (step 4).
  `list.get(xs, i)` returns an `Option` (step 7).
- **Tuples are not indexed**: `t[0]` would need a type per index. The
  proposal is to leave tuple access to patterns and `let (a, b) = t`.
  **Open**: `t.0`.

### Membership

- **`x in xs`**: a list holds an element equal to `x` (needs step 3).
- **`sub in s`**: a string contains a substring.
- **`not in`**: the negation of either.

This sits at comparison precedence. In a comprehension, `for x in e`
reads `e` up to a `for` or `if` at bracket depth 0. A membership test
inside `e` needs parentheses, and a membership test in an `if` filter
needs none. This is a parser rule to write down and test.

### `for` takes a pattern, and walks a string

- **`for (k, v) in pairs:`** binds as a comprehension's `for` already
  does. A refutable pattern in a statement `for` is **refused**, unlike
  a comprehension where it filters: a loop that silently skips
  elements is a bug, not a feature.
- **`for c in "abc":`** walks the characters. A comprehension walks a
  string too.
- **Builtins** `enumerate(xs)` → `[(Int, a)]` and `zip(xs, ys)` →
  `[(a, b)]`. They are builtins, not library functions, because Python
  programs write them without an import. **Open**: whether to keep the
  builtin table this small and put them in `lib/list` instead.

---

## Step 6 -- Strings: interpolation, long strings, escapes

| Feature | Syntax | Notes |
|---|---|---|
| Interpolation | `f"x = {x}, sum = {a + b}"` | `{e}` is `string(e)`; `{{`/`}}` write braces. Any expression, type-checked as written |
| Formatting | `f"{x:.2}"` | **open**: a small format spec, only fixed decimals for Float and a width (`{n:5}`). Without it, `text.fixed(x, 2)` |
| Long strings | `"""…"""`, `'''…'''` | span lines, and the lexer suspends indentation inside as it does in brackets. **Open**: whether to strip the common indentation, which Python does not |
| Escapes | `\u{e9}`, `\x41`, `\0` | code points written as escapes, for Unicode text |
| Digit separators | `1_000_000` | decimal and Float. Hex and binary have them already |
| Raw strings | `r"\d+"` | only if a regular-expression library arrives |

- **No `Char` type.** A character stays a `String` of length 1, as
  `text.char_at` and string patterns already treat it.
- **Lengths in code points.** "Length" and "index" count code points
  on every target. That is what `text.length` promises today; check
  that `len` on a String does the same on JS and Java, where strings
  are UTF-16.

---

## Step 7 -- The list library

A functional language without `map`, `filter` and `fold` makes every
program write them. Add `lib/list`, written in Pyking like `random`,
so that it runs on every target that has lists:

| Group | Functions |
|---|---|
| Transform | `map`, `filter`, `filter_map`, `flat_map`, `flatten`, `reverse`, `take`, `drop`, `take_while`, `drop_while`, `chunks`, `windows` |
| Fold | `fold`, `fold_right`, `sum` (Int and Float, via overloading), `product`, `count`, `any`, `all` |
| Search | `find` → `Option`, `index_of` → `Option`, `contains`, `get` → `Option`, `head`/`last` → `Option` |
| Order | `sort`, `sort_by(xs, key)`, `sort_with(xs, cmp)`, `min`/`max` → `Option`, `unique` |
| Build | `repeat(x, n)`, `init(n, f)`, `zip`, `unzip`, `enumerate`, `partition`, `group_by` |
| Strings | `text.join` exists; add `text.chars`, `text.from_chars` |

- **Requirements**: steps 3 (`sort` and `contains` need comparison)
  and 4 (Option).
- **`sort` is stable**, and is written in Pyking (merge sort), so it
  is the same on every target.
- **Naming** follows `text`: lowercase with underscores, the list
  first, so that a future `|>` or method syntax reads naturally.
- **Open**: a pipe operator `xs |> list.map(f)`. It suits the
  functional default, but it is a new operator for beginners to read.
  It could be added in this step or left out.

---

## Step 8 -- Maps and sets

Immutable, persistent collections, available without `use mutation`:

```pyking
import map
ages = {"ada": 36, "alan": 41}          # Map(String, Int)
older = map.set(ages, "ada", 37)        # a new map; ages is unchanged
print(ages["alan"], map.get(older, "bob"))   # 41 None
```

- **Types `Map(k, v)` and `Set(a)`.** The key or element type needs
  ordering (step 3).
- **Written in Pyking** as balanced trees in `lib/map` and `lib/set`,
  as `random` is, so that they are identical everywhere and need no
  host code. Lookup costs O(log n).
- **Literals** `{k: v, …}` for a map and `{a, b}` for a set. `{}` is
  an empty map. An empty set is `set.empty()`. This is the first use
  of braces, which interpolation (step 6) uses only inside `f"…"`.
- **`m[k]`** fails if `k` is missing (step 4). `map.get` returns an
  `Option`.
- **`k in m`** tests a key, and **`for (k, v) in m`** walks the
  entries in key order, which is deterministic on every target, as the
  tests need.
- **Operations**: `set`, `remove`, `get`, `has`, `keys`, `values`,
  `items`, `size`, `merge`, `from_list`, `map_values`, `filter`;
  `union`, `intersect` and `difference` for sets.
- **C** refuses them, as it refuses lists.

---

## Step 9 -- I/O and the system libraries

With Result (step 4), the libraries can report failure instead of
returning `""`.

| Library | Add |
|---|---|
| `io` | `read_lines()` → `[String]` (to end of input), `read_all()`, `read_int()`/`read_float()` → `Option` for the common exercise "read a number", `write_error(s)` (standard error without `debug`'s release removal) |
| `fs` | `read_text` and `write_text` returning `Result`; `append_text`, `list_dir`, `is_dir`, `make_dir`, `remove`, `rename`, `read_lines`. Paths: `fs.join(a, b)`, `basename`, `dirname`, `extension` |
| `sys` | `env_get` → `Option` (replacing the `env_has` pair over time), `platform()`, `exit` exists |
| `text` | character classes (`is_digit`, `is_alpha`, `is_space`, `is_upper`), `pad_left`, `pad_right`, `fixed(x, decimals)`, `parse_int` if not a builtin (step 4), `index_of` → `Option`, `count`, `split_lines` |
| `time` | `sleep(ms)` where the host allows (not on the web page), monotonic `millis()` for timing |
| `math` | Int `pow`, `isqrt`, constants `pi`, `e`, `inf`, `nan` as public bindings if missing |
| `json` (new) | `datatype Json: Null, Bool(Bool), Num(Float), Str(String), Arr([Json]), Obj(Map(String, Json))`; `json.parse(s)` → `Result`; `json.write(j)` |
| `random` | already complete for teaching; add `sample(xs, k)` |

### Constraints

- **The web targets** have no files or standard input. Each library
  states what it does in the browser, as `docs/libraries.md`, "What
  each library reaches", does today. Functions with no browser meaning
  return `Err("not available in the browser")` rather than failing.
- **Out of scope**: networking (HTTP), processes and sockets. They
  need asynchrony, which the language does not have (see "Later").

---

## Step 10 -- Type aliases and smaller type-system items

- **Type aliases**: `type Point = (Float, Float)` and
  `type Pair(a) = (a, a)`. An alias is not a new type. `type` becomes
  a keyword, and an alias is `public` like a datatype.
- **Printing a type**: the checker prints an alias by its name where
  it can, so error messages stay short.
- **Recursive aliases are refused.** A recursive type is a `datatype`.
- **A one-constructor struct** reads its fields by name today. Step 5
  leaves tuple access to patterns. **Open**: `t.0`, reconsidered here.
- **Errors mentioning equality or ordering constraints** (step 3) need
  wording that a beginner can act on: "`contains` compares elements
  with `==`, and a function cannot be compared".
- **Not here**: general type classes, row polymorphism, GADTs.
  Implicits cover what overloading needs, and the language stays
  small.

---

## Step 11 -- `use mutation`: arrays, mutable maps, compound assignment

Everything in this step is refused without `use mutation`.

### Compound assignment

`x += 1` means `x := x + 1` for `+ - * / %` and the bitwise
operators of step 2, on a `var` only. `s += "!"` and
`xs += [x]` join, under the same one-type rule as `+`.

- **Why `+=`**: Python spells it this way, and on a `var` it can only
  mean mutation, since nothing can be rebound in place.
- **The alternative**: a spelling such as `+:=` keeps every mutation
  visibly `:=`. The proposal is `+=`.
- **Gated**: it is mutation syntax, so without `use mutation` it is
  refused like `:=`.

### Arrays

`Array(a)`: fixed or growable, updated in place, O(1) indexed on every
target that has it.

```pyking
use mutation
import array

a = array.make(5, 0)          # [0, 0, 0, 0, 0], an Array(Int)
a[2] := 7                     # in place
array.push(a, 9)
for x in a: print(x)
print(len(a), a[2], array.to_list(a))
```

- **Mutation syntax**: `a[i] := v` writes an element. It is mutation
  syntax, gated like `:=`. Reading `a[i]`, `len(a)` and `for x in a`
  is ordinary syntax.
- **Library functions**: `array.make`, `from_list`, `to_list`,
  `push`, `pop`, `insert`, `remove`, `sort_in_place`, `fill` and
  `copy`.
- **A library that requires a feature.** `array.pyk` begins with
  `use mutation` and, new, `public use mutation`, which **requires
  mutation of every importer**. Importing `array` without it is refused
  at the import: "the array library changes values in place; write
  'use mutation' to use it". This keeps arrays, which make aliasing
  visible, out of functional modules, while tinyweb (effects on the
  outside world) stays usable everywhere.
- **Aliasing is real**: `b = a` names the same array, and `a[0] := 1`
  is seen through `b`. This is the point of the feature and is what
  `PYKING.md` must explain.
- **No `==` on arrays** (step 3): identity or contents is the question
  a beginner gets wrong. Compare with `array.same(a, b)` (identity) and
  `array.to_list(a) == …` (contents).
- **Targets**:

  | Target | An `Array` is |
  |---|---|
  | Python | `list` |
  | JS | `Array` |
  | Java | `ArrayList` |
  | OCaml | a growable record over `array` |
  | interpreter | a mutable value |
  | C | **open**: a heap block never freed, as strings are, or refused like lists. The proposal is fixed-size arrays only, allocated and never freed, documented as a leak like `+` on strings |

### Mutable maps

`Dict(k, v)` in `lib/dict`, required-mutation like `array`, with
`d[k] := v`, `dict.remove`, `k in d` and iteration in insertion order.

- **Host-backed**, unlike the persistent `Map` of step 8: a hash map
  on each host, for speed.
- **Keys**: strings, numbers, Bools, and tuples of those (hashable on
  every host). **Open**: any comparable key.

### What stays functional even here

- **Lists, tuples, datatypes, structs and `Map` are never changed in
  place.** `use mutation` adds new things; it does not change the
  meaning of existing ones.
- **A `var` holding a list** still rebuilds it, as `PYKING.md` says
  today.

---

## Step 12 -- `use objects`: classes and methods

The first half of object orientation: a class is a type with fields
and methods, without inheritance yet. Refused without `use objects`.

```pyking
use objects

class Circle(radius: Float):
    def area(self) -> Float:
        3.14159 * self.radius * self.radius

    def scaled(self, k: Float) -> Circle:
        Circle(self.radius * k)

c = Circle(2.0)
print(c.area(), c.scaled(2.0).radius)
```

### Decisions (proposed)

- **Declaring**: a class declares its fields in the header, as a
  struct does: positional, named or defaulted, with the same
  construction rules (`Circle(radius = 2.0)`). It is written at the top
  level only, as datatypes are.
- **Methods**: methods are `def`s in the class body with an explicit
  `self`, as in Python. They are called with `obj.method(args)`, and
  named and default arguments work as for any `def`. A method may call
  another as `self.other()`.
- **Fields are immutable** under `use objects` alone. A method that
  "changes" an object returns a new one, as `scaled` does. Mutable
  fields need both features (step 13). This keeps the two features
  independent: objects do not smuggle mutation in.
- **Equality**: `==` on objects is structural only when the class
  defines `def eq(self, other: Circle) -> Bool`, and refused otherwise.
  Two objects being "the same" is a decision the class makes.
- **Printing**: `print(c)` writes `Circle(radius=2.0)`, as a struct
  prints. A class may define `def show(self) -> String`, which `print`
  and `string` then use.
- **Visibility**: `public class` exports the type, its constructor and
  every method. **Open**: `private` members. The proposal is a leading
  `_` meaning private to the class, checked, because the module system
  already makes everything private by default and a second keyword is
  one more thing to learn.
- **Type checking**: a class is a nominal type, like a datatype.
  - **Method calls**: `x.m()` needs `x`'s type known at that point,
    the same rule field access `p.x` follows today. Where it is not
    known, the error asks for an annotation.
  - **Static members**: none. A module-level `def` does that job.
- **Patterns**: `case Circle(r):` matches a class as it matches a
  struct, positional fields first. Exhaustiveness treats a class as a
  one-constructor type.
- **`self`** is a keyword (reserved in step 1). It is valid only as a
  method's first parameter and inside a method body.

### Targets

| Target | A class is |
|---|---|
| Python, JS, Java | a class |
| OCaml | a record type plus functions taking it; dispatch is static until step 13 |
| C | a struct by value plus functions, exactly as a struct is today, since there is no dispatch yet |
| interpreter | a datatype value with a method table |

The elaborator can lower classes to datatypes plus functions before any
backend sees them, as overloading and implicits are lowered today. That
keeps this step mostly in the front end.

---

## Step 13 -- `use objects`: interfaces, inheritance, mutable fields

### Interfaces and dynamic dispatch

```pyking
use objects

interface Shape:
    def area(self) -> Float
    def name(self) -> String: "shape"      # a default body

class Square(side: Float) extends Shape:
    def area(self) -> Float: self.side * self.side

shapes: [Shape] = [Square(2.0), Circle(1.0)]
for s in shapes: print(s.name(), s.area())
```

- **Interfaces**: an `interface` declares method signatures and may
  give defaults. A class `extends` one or more interfaces, and every
  signature without a default must be defined. A missing one is refused
  at the class, naming it.
- **Class inheritance**: a class may `extends` **one** class and any
  number of interfaces, and inherits fields and methods.
  - **Overriding** a method requires an identical signature. **Open**:
    an `override` marker. The proposal is to require it, because a
    misspelled method silently not overriding is the classic bug.
  - **`super.m(...)`** calls the parent's version.
  - **The parent's fields** come first in the constructor.
- **Subtyping** meets inference only where a type is **expected**:
  - an annotated binding or parameter
  - a declared return type
  - a list literal whose type is annotated, as in `shapes` above

  Elsewhere `[Square(2.0), Circle(1.0)]` is a type error that suggests
  the annotation. This keeps HM inference intact and the rule
  explainable: Pyking never guesses a common supertype.
- **Downcasting**: `match s: case Square(side): …` tests the class.
  Such a `match` needs a `case _` (an interface is open), and
  exhaustiveness says so.

### Mutable fields: both features

```pyking
use objects, mutation

class Counter(var count: Int = 0):
    def tick(self):
        self.count := self.count + 1
```

- **`var` fields**: a `var` field needs `use mutation`, and
  `obj.f := v` is mutation syntax, gated as `:=` is.
- **Objects with a `var` field are references**: aliasing is visible,
  and `==` is refused unless `eq` is defined (step 12).
- **Objects without one** stay values, and the backends may copy them.

### Targets

| Target | Interfaces and inheritance become |
|---|---|
| Python, JS | classes |
| Java | interfaces and abstract classes |
| OCaml | records of closures, or OCaml objects; **open**, decided by which keeps the generated code readable |
| C | a struct with a vtable pointer. Objects that are references need a heap. **Proposal**: refused on C, like recursive datatypes, with the usual message |

---

## Step 14 -- Tooling that a complete language implies

These are not language features, but a complete language is expected
to have them, and steps 4 and 6 make them cheap:

- **`pyk test`**: runs every `def test_*()` in a file or folder,
  reporting `assert` failures with positions (step 4). The notebook's
  test mode and nbverify already show what results should look like.
- **`pyk fmt`**: the Pyking pretty-printer already round-trips the AST.
  Comments are what a formatter must keep, so the lexer needs to keep
  them.
- **Doc comments**: `##` lines above a `def`. `lib/math/math.pyk`
  already writes them for the help generator. Make them a documented
  convention, so the LSP's hover shows them for user code too.

---

## Later, or not at all

Each of these is a real gap. Each is either a large design of its own
or at odds with a small teaching language, so none is in the steps
above:

| Feature | Why later |
|---|---|
| Exceptions (`try`/`except`) | Result and `fail` cover teaching needs. If wanted, a third feature `use exceptions` fits the same mechanism |
| Asynchrony, concurrency | needed for networking and timers outside tinyweb's callbacks; a large design across seven targets |
| Networking, processes | need asynchrony on the web and node targets |
| 64-bit or big integers | the 32-bit promise is a deliberate portability floor; an `Int64`/`BigInt` library type is possible later |
| Bytes and binary files | no course need yet |
| Regular expressions | hosts disagree on syntax; a `text.match`-style library over one dialect is possible |
| Generators, lazy sequences | `range` is already lazy in `for` headers; a general `Seq(a)` waits for a need |
| General type classes | implicits and the inferred equality of step 3 cover the cases met so far |
| Packages and versions | modules and the search path suffice until libraries are shared outside the repo |

---

## Summary table

| Step | Adds | Gated by | Needs | New keywords |
|---|---|---|---|---|
| 1 | `use`, gate on `var`/`:=` | -- | -- | `use` (+ reserves `class interface extends self super`) |
| 2 | `+` joins strings and lists (`++` removed); `lam x. e` (`=>` removed); `xs[i]` on lists; `and or not` (bitwise on Ints) and their symbol spellings, `!= % ^`, bitwise and, or, `xor`, `~`, `<<`, `>>` | -- | -- | `lam and or not xor` |
| 3 | `==`/`<` on every data type, inferred comparable type variables | -- | -- | -- |
| 4 | prelude `Option`/`Result`, `parse_*`, `fail`, `assert`, defined failures | -- | 3 (for `Option` equality) | `assert` |
| 5 | `s[i]`, negative indices, slices, `in`/`not in`, `for` patterns, string `for`, `enumerate`/`zip` | -- | 3, 4 | -- |
| 6 | `f"…"`, `"""…"""`, `\u{…}`, digit separators | -- | -- | -- |
| 7 | `lib/list` | -- | 3, 4 | -- |
| 8 | `Map`, `Set`, `{…}` literals | -- | 3, 4, 5 | -- |
| 9 | `io`, `fs`, `sys`, `text`, `time`, `math` additions, `json` | -- | 4, 8 | -- |
| 10 | type aliases | -- | -- | `type` |
| 11 | `+=`, `Array`, `Dict`, `a[i] := v`, `public use` | `use mutation` | 1, 5 | -- |
| 12 | `class`, methods, `self`, `eq`/`show` | `use objects` | 1 | (reserved in 1) |
| 13 | `interface`, `extends`, `super`, `override`, `var` fields | `use objects` (+ `mutation` for `var` fields) | 12, 11 | `override` |
| 14 | `pyk test`, `pyk fmt`, doc comments | -- | 4 | -- |

Steps 2 and 6 are independent of everything else and can be done in
any order. Step 1 should come first, so that every later example is
written knowing which module needs which feature.
