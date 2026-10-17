# Bootstrapping: what Pyking needs before `src/` can be written in it

The compiler in `src/` is OCaml, about 34 000 lines in 35 modules. The
plan is to rewrite it in Pyking and compile the rewrite with the OCaml
one. This file lists what Pyking still lacks for that rewrite to read
cleanly. The goal is a translation that reads like the OCaml it
replaces, not one that works around the language at every turn.

Algebraic data types, pattern matching over them, or-patterns, `as`
patterns, guards, field access and the exhaustiveness pass are built.
See PYKING.md, "Datatypes", and docs/exhaustive.md. Everything below
comes on top of them.

The counts are lines of `src/*.ml` matching a pattern, comments
included. They show how much each feature is used, and are not exact.

## What Pyking has today

**Types:**
- `Int`, `Float`, `String` and `Bool`.
- Lists, tuples, functions and unit.
- Type variables and `all`.
- Datatypes with parameters, built by constructors with positional,
  named and defaulted fields.

**Expressions:**
- `+ - * /`, unary `-`, `++`, and `< <= > >= ==`.
- `if … then … else`, lambdas, list comprehensions and field access
  `x.f`.

**Patterns:**
- Literals, names and `_`.
- Tuples, lists with `..rest`, and `++` on lists and literal string
  prefixes.
- Constructors, `|` and `as`.
- Guards with `if`.

**Definitions:**
- `def` with defaults, named arguments, inference, overloading with
  `::`, and implicits.
- `var` and `:=`, but only on Int, Float and Bool.
- `for`, `while` and `loop`.

**Modules:**
- `import`, `from` and `public`.
- External modules written in a target language.

**Libraries:** `io`, `fs`, `sys`, `time` and `math`.

## Must have

Without these, the translation would be contorted rather than clean.

### 1. Boolean connectives and `!=`

**Use in src/:** `&&` 308 lines, `||` 188, `not` about 150, `<>` 176.
- Every guard and every condition in the type checker uses one.
- Today `a && b` has to be written `if a then b else false`, which
  doubles the length of a condition.

**Direction:**
- `and`, `or` and `not` as keywords that short-circuit, as Python
  spells them.
- `!=` as a comparison.
- Every backend has these natively, and the interpreter needs one
  continuation for the short circuit.

### 2. Equality and ordering beyond the scalars

**Use in src/:**
- OCaml's `=` is used on strings in about 160 lines, and also on
  options and tuples.
- `compare` sorts names in `target_python.ml`, `target_ocaml.ml` and
  `pyk.ml`.
- Every `SMap`/`StringSet` needs an ordering on strings.

**Pyking today:** `==` takes two Ints, Floats, Strings or Bools, and `<`
takes Int or Float only.

**Direction:**
- Structural `==` (and `!=`) on lists, tuples and datatypes whose
  leaves are comparable. It is refused for functions.
- `<` and `<=` on `String`, lexicographic by byte.
- Alternatively, an `eq` and a `compare` resolved as implicits, which
  the language already has the machinery for. That is more honest
  about functions, and more to write.

### 3. Records: functional update

**Use in src/:**
- `{ r with f = … }` appears in 173 lines. The `store`, the
  interpreter's `state`, `ctx` and `acc` in every backend, and
  `Module.t` are rebuilt this way everywhere.
- Field access appears in more than 400 lines.

**Pyking today:** a one-constructor datatype with named fields is a
record, and `x.f` reads a field. What is missing is building a copy
with some fields changed.

**Direction:** `store with (fresh = store.fresh + 1)`. Desugar_args can
expand it into a constructor call that copies every other field by
position, for a datatype of one constructor. A datatype with several
constructors needs a `match`, so it is refused there.

### 4. Option and Result, and a way to fail

**Use in src/:**
- `Some` and `None` appear in about 2 300 lines, and `option` fields
  are everywhere in the AST (`typ option`, `expr option`).
- `raise` appears in 219 lines, `try` in 62, and the compiler declares
  18 exceptions:
  - one per stage: `Parse_error`, `Type_error`, `Module_error`,
    `Analysis_error` and `Lex_error`;
  - `Unsupported` in each backend;
  - `Decline` and `Needs_escape` for local control flow;
  - `Not_found` and `Failure` from the standard library.

**Direction:**
- `Option(a)` and `Result(a, e)` as datatypes in a standard library
  module, with `map`, `bind`, `default` and `is_some`. They can be
  written in Pyking today.
- One error mechanism, which is the open decision. Either:
  - **(a)** exceptions declared as datatype constructors, with `raise`
    and `try … except Ctor(...)`. These are cheap in Python,
    JavaScript, Java and OCaml, and C needs `setjmp` or result
    threading.
  - **(b)** `Result` with a propagation operator (Rust's `?`). This is
    pure and works on every target, but it changes the parser's 75
    mutually recursive functions into ones returning `Result`.
- The stages raise once and stop, so (a) is the smaller rewrite. (b)
  fits the "no mutation, values threaded" rule in CLAUDE.md better.

### 5. Characters and string access

**Use in src/:**
- Char literals appear in 434 lines.
- The lexer matches `char list`, with arms like `'+' :: '+' :: xs`.
- `String.get` / `s.[i]` appear in 86 lines, `String.sub` in 105,
  `String.length` in 190, and `Char.code` / `Char.chr` in about 20.
- They are needed by the JSON parser, the LSP's UTF-16 conversion, and
  every backend's escaping.

**Pyking today:** a string can be split only around literal text, and
measured with `len`.

**Direction:**
- A `Char` type with literals (`'a'`, which needs a new quote rule
  since `'` already delimits strings; perhaps `c'a'`).
- `ord`, `chr`, `chars(s) -> [Char]` and `from_chars([Char])`.
- Char ranges in patterns: `case 'a'..'z'`.
- The lexer then translates one arm for one arm, as list patterns over
  `[Char]`.

### 6. Finite maps and sets

**Use in src/:**
- `SMap` is defined in 10 modules, with 173 uses.
- `IntMap`, `IntSet`, `StringSet` and `SSet` have about 180 uses.
- `tmap`, `qmap`, `store.solutions` and every scope are persistent
  maps.
- Association lists stand in elsewhere, in 135 lines.

**Direction:**
- A persistent balanced tree (AVL or red-black) written in Pyking over
  datatypes, in a library: `map.empty`, `add`, `find` (answering an
  `Option`), `remove`, `fold` and `bindings`.
- Keys are compared through an implicit `compare` parameter. No
  functors are needed: `Map.Make (String)` becomes a `Map(String, v)`
  whose operations take `implicit compare: (k, k) -> Int`.
- This needs item 2 (String ordering) or that implicit.

### 7. Mutually recursive datatypes across the AST

**Use in src/:** `syntax.ml` declares `expr`, `typ`, `pattern`, `stmt`
and six more as one `type … and …`.

**Pyking today:** every datatype of a module is in scope throughout it,
so mutual recursion already works.

**Missing:** the AST's single-constructor nodes (`Param`, `ListRest`,
`MatchCase`) are records in all but name. Item 3 covers what they
need.

## Should have

These can be done without, but are noticeably awkward.

### 8. Integer remainder and bit operations

**Use in src/:** `mod` appears in 7 lines, and `land`, `lor`, `lsl` and
`lsr` in 18, all of them UTF-8 and UTF-16 encoding.

**Direction:** `%` as an operator, truncating like `/` (`math.mod` is
floored). Bit operations go in a `bits` library rather than in the
syntax.

### 9. String building

**Use in src/:**
- `Printf.sprintf` appears in 623 lines, almost all of them `%s` and
  `%d`.
- `^` appears in 297 lines, `String.concat` in 210, `Buffer` in 138,
  and `String.split_on_char` in 30.

**Direction:**
- `join(sep, [String])` and `split(s, sep)` in a `string` library.
- Optionally f-strings: `f"'{name}' is {n}"`.
- `Buffer` becomes a list joined once at the end.

### 10. A list library

**Use in src/:**
- `List.` appears in 1 760 lines: `map` 437, `fold` 327, `filter` 160,
  `exists`/`for_all` 138, `assoc` 135, `mem` 75, `rev` 75, `nth` 66
  and `find` 34.
- `@` appears in 477 lines.

**Direction:** a `list` module written in Pyking: `map`, `fold`,
`filter`, `exists`, `all`, `find`, `assoc`, `rev`, `nth`,
`concat_map`, `zip`, and `sort(xs, implicit compare)`. `++` already
does what `@` does.

### 11. Parsing numbers that can fail

**Use in src/:** `int_of_string_opt` and its relatives.

**Pyking today:** `int(s)` answers 0 on failure.

**Direction:** once `Option` exists, add `parse_int(s) -> Option(Int)`
and `parse_float`. This is the plan builtin.ml already states.

### 12. Type aliases

**Use in src/:** a handful, such as `type env = binding SMap.t` and
`type sigmap = (string * typ * bool) list`, but they are named in
interfaces.

**Direction:** `type Env = Map(String, Binding)`, expanded by the
checker. No new runtime values.

### 13. Opaque exports

**Use in src/:** 34 `.mli` files declare about 17 abstract types.

**Pyking today:** `public datatype` exports the type and every
constructor, and a public definition whose type names a private
datatype is refused.

**Direction:** `public opaque datatype Store` exports the name without
the constructors. Another module can then hold and pass a `Store`, but
not build or match one.

### 14. Datatypes on C and Java

**Pyking today:** done. Java compiles every datatype (a class per
constructor, records from java17 on); C compiles every datatype that
does not hold itself, as a tagged union by value.

**Direction:**
- **C:** a datatype holding itself, and lists, need a heap. A tagged
  struct on the heap, never freed, would be acceptable for a compiler
  run.
- The bootstrap does not need it: the self-hosted compiler can start on
  OCaml, Python, JavaScript or Java.

### 15. Structural `==` on datatypes

This is item 2's datatype half, listed on its own because it was left
out of the datatype change on purpose. It changes `==`'s type rule
from "one of four kinds" to "any type without a function in it".

## Nice to have, or only for the executable

### 16. Mutable state

**Use in src/:**
- `ref` appears in four files, and only `interpreter.ml` holds
  language semantics in one: the write-once `def` cell and the `var`
  location.
- `Array` is used for the REPL editor's buffer and `KSeq`'s index.

**Direction:**
- A `Cell(a)` library type for the interpreter's two cells, or move the
  interpreter to a threaded store.
- Arrays become lists, or a persistent vector library.

### 17. Input, output and processes

**Use in src/:** `Unix` (60 lines), `Sys` (63), `Filename` (59), and
`Dynlink`.

**Where it is used:** all of it is in the executable half:
- `pyk.ml`, `execution.ml`, `repl.ml`, `web_server.ml` and
  `plugin_host.ml`.

**Direction:**
- Grow `fs` with `list_dir`, `write`, `exists` and path helpers.
- Add a `process` library with `run` and its exit status.
- The terminal editor, the HTTP server and the plugin loader can stay
  external modules written in OCaml. That is what external modules are
  for.

### 18. String escapes

**Use in src/:** OCaml literals use `\x1b` and `\027` in `repl.ml` and
`json.ml`.

**Direction:** add `\xNN` and `\u{…}` to the lexer's escapes.

### 19. Not needed

- Functors are only `Map.Make` and `Set.Make` (see item 6).
- `let rec` and `and` are hoisted `def`s.
- The `function` keyword is `x => match`, once a `match` expression
  exists, or a nested `def`.
- Labelled and optional arguments are defaults and named arguments.
- Polymorphic variants, GADTs, `lazy`, `Seq` and first-class modules
  are absent from `src/`, or nearly so.

### 20. A `match` expression

**Use in src/:** OCaml `match` is an expression in more than 400 places
nested inside other expressions, such as an argument or an operand.

**Pyking today:** `match` is a statement, though its value can be
bound or returned.

**Direction:** `match e with case p: v case q: w` on one line, or allow
the statement form wherever a bound value may stand. This is not
required, since a local binding always works, but it removes a temporary
in many places.

## Suggested order

1. `and`, `or`, `not`, `!=` and `%` (items 1 and 8): cheap, and they
   remove the most noise.
2. Functional update (3) and structural equality and String ordering
   (2, 15).
3. `Option` and `Result`, and the error decision (4).
4. `Char` and string access (5).
5. The `list`, `string` and `map`/`set` libraries, written in Pyking
   (6, 9 and 10).
6. Aliases, opaque exports, `parse_int` and escapes (11, 12, 13 and
   18).
7. `fs` and `process` for the driver (17). The REPL editor, the web
   server and the plugin host stay external.
