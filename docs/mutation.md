# Mutation

Pointers, which come on top of this, have a page of their own:
[pointers.md](pointers.md).

Everything in Pyking that changes a value in place, in one place: what a
program writes and what it means (the guide), then how the compiler
implements it (the internals). PYKING.md is the reference for each
construct; this page is the tour through all of them, and the map of
where each lives in `src/`.

The design these follow is the mutation plan (`mutation5.md` and its
successors at the repository's root, section 19, "Final Claude
Remarks"), whose decisions are named `FCR-...` below.

## Contents

1. [The guide](#the-guide)
   1. [One switch: `use mutation`](#one-switch-use-mutation)
   2. [Variables: `var`, `:=` and compound assignment](#variables-var--and-compound-assignment)
   3. [Several variables at once: tuple `:=`](#several-variables-at-once-tuple-)
   4. [Arrays](#arrays)
   5. [DynArrays](#dynarrays)
   6. [MutMaps](#mutmaps)
   7. [Slices and views](#slices-and-views)
   8. [Mutable structs: `var struct`](#mutable-structs-var-struct)
   9. [Sharing, identity and equality](#sharing-identity-and-equality)
   10. [Printing what holds itself](#printing-what-holds-itself)
   11. [Order of evaluation](#order-of-evaluation)
   12. [What each target makes of it](#what-each-target-makes-of-it)
2. [The internals](#the-internals)
   1. [Where each piece lives](#where-each-piece-lives)
   2. [Lexer and parser](#lexer-and-parser)
   3. [Desugaring](#desugaring)
   4. [The checker](#the-checker)
   5. [The interpreter](#the-interpreter)
   6. [The backends](#the-backends)
   7. [Warnings and tools](#warnings-and-tools)
   8. [Tests](#tests)

## The guide

### One switch: `use mutation`

A module is functional until it says otherwise: `=` binds a name once,
and no value changes. `use mutation` at the top of a module turns on
everything on this page. Without it, each construct is parsed as usual
and then refused, naming the line that would allow it:

```
'prog.pyk' 3:0-3:8 Parsing error: ':=' writes the field 'x' of a var
  struct, which needs 'use mutation' at the top of this module
```

The switch gates **making and writing**, never holding (FCR-A1). A
module without it may receive an array or a `var struct` from one with
it, read it, pass it on and return it.

### Variables: `var`, `:=` and compound assignment

`var n = 0` declares a variable; `n := n + 1` writes it. The compound
forms read and write it in one statement:

| form | means |
|---|---|
| `n += e`, `n -= e`, `n *= e`, `n /= e`, `n %= e`, `n ^= e` | `n := n op e` |
| `n &= e`, `n \|= e`, `n xor= e`, `n <<= e`, `n >>= e` | the same, bitwise |

A compound assignment is a statement, never a value, and works on a
`var`, an array's element (`a[i] += 1`) and a `var struct`'s field
(`p.x += 1`). `+=` joins Strings as `+` does.

### Several variables at once: tuple `:=`

`a, b := b, a` swaps two `var`s: the right side is worked out once, all
of it, and only then are the names written, left to right. The names
are distinct `var`s, and may nest to match the value's shape:
`(q, r), done := divmod(n, d), true`.

### Arrays

`Array(T)`: a fixed number of elements, written in place and shared.

```pyking
use mutation

a = array([3, 1, 2])          # from a list
zeros = array(4, 0)           # four copies of one value
squares = array_init(5, lam i. i * i)                  # element i is f(i)
powers = array_init(5, 1, lam s. (s, s * 2))           # unfolding a seed
a[0] := a[1] + a[2]
print(a, len(a), squares[4], powers)
```

- `array` fills, `array_init` generates; each is a set of two forms,
  told apart by how many arguments they take.
- `a[i]` reads, `a[i] := v` writes, `len(a)` never changes. An index
  outside the array is a runtime error on every target but plain C.
- `for x in a` reads each element as it is reached.
- `lib/array` has the rest: `copy`, `to_list`, `fill`, `swap`,
  `reverse`, `concat`, `resize`, `equal`, `sort`.
- `array(n, v)` with an array `v` stores one row `n` times, which the
  `shared-fill` warning points out; `array_init(n, lam _. array(m, 0))`
  makes a row each time.

PYKING.md, "Arrays", has every rule.

### DynArrays

`DynArray(T)`: an array that grows, for building a collection one element at
a time (FCR-B8).

```pyking
use mutation

v: DynArray(String) = dynarray()
push(v, "a")
push(v, "c")
insert(v, 1, "b")
print(v)                     # dynarray(["a", "b", "c"])
print(pop(v), remove(v, 0), v)       # c a dynarray(["b"])
```

- `dynarray()` and `dynarray(xs)` make one; `push`, `pop`, `insert`, `remove` and
  `clear` change it; `v[i]`, `v[i] := x`, `len(v)` and `same` are an
  array's.
- A `for` goes on while its index is below the length the DynArray has at
  that turn: it walks what it pushes, and ends sooner after a `remove`.
- The writers' names yield to a module's own: a `def insert` or an
  imported `push` means itself in that module.
- `lib/dynarray` has `copy`, `to_list`, `to_array`, `from_array`, `extend`,
  `reverse`, `equal` and `sort`.

PYKING.md, "DynArrays", has every rule.

### MutMaps

`MutMap(K, V)`: a map that remembers the order its keys were put in
(FCR-F1 to F4).

```pyking
use mutation

stock = mutmap([("apple", 3)])
stock["pear"] := 5
stock["apple"] -= 1
print(stock, get(stock, "fig", 0), has(stock, "pear"))
print(remove(stock, "apple"), keys(stock), items(stock))
```

- `mutmap()` and `mutmap(pairs)` make one; `d[k]` reads (a missing key is
  an error), `d[k] := v` adds or replaces.
- `get`, `has`, `remove`, `discard`, `keys`, `values`, `items`, `clear`,
  `len` and `same` do the rest; a key taken out and put back goes to the
  end.
- `for k in d` walks the keys in order; adding or removing a key during
  the walk is an error, replacing a value is not.
- A key's type is one whose values never change and always equal
  themselves (the `Key` capability, FCR-F3): no Float, no function, no
  mutable value, nothing holding one.

PYKING.md, "MutMaps", has every rule.

### Slices and views

`s[i:j]` copies a run of a list, a String, an array or a DynArray; `view(a,
i, j)` shares one of an array (FCR-G1).

```pyking
use mutation

a = array([1, 2, 3, 4, 5])
copied = a[1:3]
shared = view(a, 1, 3)
copied[0] := 0
shared[1] := 0
print(a, copied, shared)       # array([1, 2, 0, 4, 5]) array([0, 3]) view([2, 0])
copy_into(a, view(a, 2, 5))
print(a)                       # array([0, 4, 5, 4, 5])
```

- A slice is shallow and new; a view is a window, `Slice(T)`, and
  writing it writes the array. A view of a view reaches the same array.
- `copy_into(dst, src)` is `memmove`: right where the two overlap.
- Bounds are `0 <= i <= j <= len`, checked on every target but plain C.

PYKING.md, "Slices and views", has every rule.

### Mutable structs: `var struct`

A struct whose fields are written in place, and whose values are shared:

```pyking
use mutation

var struct Account(owner: String, balance: Int = 0)

def deposit(a: Account, amount: Int) -> ():
    a.balance += amount

acct = Account("ada")
deposit(acct, 100)
print(acct)                  # Account("ada", 100)
```

- `var struct` makes every field writable; a plain `struct` and every
  `datatype` stay values that never change (FCR-D1, D2).
- `p.x := e` and the compound forms write a field of any expression
  giving a `var struct`: `ps[i].x := 0`, `get().n += 1`.
- Whether a field may be written is its type's question, not the
  name's: `p = Account(...)` binds `p` once and `p.balance := 1` still
  writes (FCR-D3). `var` is for rebinding.
- `Account(owner = "b", ..acct)` makes a new struct; a pattern reads the
  fields as they are when it is matched.
- A `var struct` holding its own type through a datatype builds linked
  lists, trees and graphs, cycles included (FCR-D6).
- A generic one, `var struct Cell(value: a)`, is one type once made.

PYKING.md, "Mutable structs", has every rule.

### Sharing, identity and equality

An array, a DynArray, a MutMap and a `var struct` are *shared*: `b = a`, `f(a)`, `[a, a]` and
a field holding `a` are all the one value, and a write through any of
them is seen through every other. This is Java's and Python's model,
and there are no reference parameters: a function changes what it is
given by writing into it (FCR-E, section 8 of the plan).

`same(a, b)` asks whether two arrays, DynArrays, MutMaps or `var struct`s are
one.
`==` compares neither: equal contents are a question the program asks
explicitly -- `array.equal(a, b)` for arrays, a function of its own for
a struct -- since "the same elements now" is not "the same" for a value
that changes (FCR-B4, D4).

Values that never change compare with `==` part by part (FCR-N18):
lists, tuples, structs and datatypes are equal when their parts are,
Floats inside by IEEE's rule. A value holding a mutable one, or a
function, is refused by `==`, naming what it holds.

### Printing what holds itself

A value that holds itself -- a `var struct` whose field leads back to
it, an array holding an array that holds the first -- prints `...` where
it would repeat. Only a value already being printed, on the path from
the outermost one, is cut; a value merely shared prints in full each
time it appears (FCR-D5):

```
Node(1, Next(Node(2, Next(...))))
array([Point(3, 3), Point(3, 3)])
```

`print`, `string`, the REPL and the debugger's values all follow this
rule; the debugger also shows a struct's fields one level at a time, so
a cycle is only expanded as far as it is clicked open.

### Order of evaluation

Every write has one order, on every target (FCR-C3):

- `n := e`: `e`, then the write.
- `a[i] := e`: `a`, then `i`, then the index check, then `e`, then the
  write into the array `a` was. A compound form reads the element after
  the check.
- `p.x := e`: `p`, then `e`, then the write into the struct `p` was. A
  compound form reads the field before `e`.
- `a, b := e`: `e`, then each name, left to right.
- `print(a, f())`: every argument, left to right, then the output -- so
  what `f` writes into `a` is printed.

### What each target makes of it

| | Python | JavaScript | Java | OCaml | plain C | `c23-gc` |
|---|---|---|---|---|---|---|
| `var` | a variable | `let` | a local, or a static field at the top level | a `ref` | a variable | a variable |
| array | a `list` subclass, never grown | a JS array marked `pykArray` | `PykRuntime.PykArray<T>` | `'a array` | `struct { int len; T *items; }`, malloc'd | the same, from the collector |
| DynArray | `__PykDynArray`, a `list` subclass | a JS array marked `pykDynArray` | (see target_java.md) | `(T option array * int) ref` | (see target_c.md) | (see target_c.md) |
| MutMap | (see target_python.md) | (see target_js.md) | (see target_java.md) | (see target_ocaml.md) | (see target_c.md) | (see target_c.md) |
| index check | yes | yes | yes | yes | **no** | yes |
| `var struct` | a class with writable fields | an object | a final class | a record with `mutable` fields | a pointer to a malloc'd struct | a pointer to a collected struct |
| freed | by Python | by JS | by the JVM | by OCaml | **never** | by bdwgc |

Plain C (`c89`, `c99`, `c23`) is kept as C a course would write by
hand: no checks, no collector, `a.items[i]` and `p->x` as they are.
What it allocates is never freed, so it suits programs that allocate a
bounded amount; `c23-gc` runs the rest.

## The internals

### Where each piece lives

| piece | files |
|---|---|
| `use` gates | `parser.ml` (`check_features`), `typesystem.ml` (`store.mutation`, for an imported `var struct`'s constructor) |
| builtins | `builtin.ml`: `overload_sets` (`array`, `array_init`, `dynarray`, `mutmap`), `writers` (`push`, `pop`, `insert`, `remove`, `clear`, `discard`), `yielding` (those, `same`, `get`, `has`, `keys`, `values`, `items`) |
| equality and keys | `typesystem.ml`: `equality_problem`, `key_problem`, `demand_key`; `interpreter.ml`: `equal_parts` |
| compound tokens | `lexer.ml` (`TokCompound`) |
| statements | `syntax.ml`: `SVar`, `SMutate`, `SMutateTuple`, `SSetIndex`, `SSetField` |
| `var struct` | `syntax.ml`: the last flag of `SDatatype` and of `Datatype` |
| sugar | `desugar_args.ml`: tuple `:=`, compound element and field writes |
| types | `typesystem.ml`: `Array(T)`, `array`/`array_init`, `same`, element and field writes, `check_open_arrays` |
| the `var` rule | `analyses.ml` (`analyze_mutability`) |
| running | `interpreter.ml`: `VArray`, `VData`'s field array, the write continuations, `display_value` |
| warnings | `warnings.ml`: `shared-fill`; a compound write counts as a read |
| library | `lib/array/array.pyk`, `lib/dynarray/dynarray.pyk` |

### Lexer and parser

- The lexer makes one `TokCompound (info, op)` for `+=`, `<<=` and the
  rest; `xor=` is the word `xor` and `=` with no space between, which
  the parser reads (and `parse_chain` refuses to read as `xor`
  applied to `=`).
- `parse_expr_statement_from` decides what an expression followed by
  `:=` or a compound operator writes: a name (`SMutate`), an element
  (`EIndex` → `SSetIndex`) or a field (`EField`, or `EQualified`, which a
  plain `p.x` parses as → `SSetField`). Anything else is refused,
  naming the three forms.
- A compound write is kept in its long form, `SMutate (x, x + e)`,
  `SSetIndex (a, i, a[i] + e)`, `SSetField (p, x, p.x + e)`, with the
  read starting where the statement does. `Syntax.compound_parts` and
  `index_compound_parts` recognise it again, so `-t pyking` prints
  `x += e`.
- `var struct` is `parse_struct ~writable:true`, at the top level and
  after `public`; inside a block, and in front of `datatype`, it is
  refused. One with no fields is refused.
- `check_features` refuses every construct of the section when the
  module has no `use mutation`, including a call making an array and
  a constructor of this module's own `var struct`.

### Desugaring

`desugar_args.ml` removes the sugar before anything reasons about it:

- `a, b := e` becomes `a__new, b__new = e` and one `:=` per name.
- `a[i] op= e` becomes `element__array = a`, `element__index = i` and
  the write through them, so `a` and `i` are worked out once.
- `p.x op= e` becomes `field__owner = p` and the write through it.

The temporaries have an empty span at the statement's end, so nothing
pointing at a name in the source lands on one, and the checker reports
a write's errors at the statement.

### The checker

- **Arrays**: `Array` is a type of one parameter with no constructors;
  `builtin_env` binds the members of `array` and `array_init`; `EIndex`,
  `len` and `for` take arrays; `SSetIndex` checks the owner, the index
  and the value in the order they run.
- **`var struct`**: the declaration's flag goes into `store.datatypes`
  with the datatype, and into a module's signature with it, so an
  importer knows. `SSetField` checks that the owner is a `var struct`
  (a plain struct's write is refused with how to build a copy), finds
  the field with `field_type` -- the function `EField` reads one with --
  and checks the value against it.
- **Making one**: the parser refuses a constructor of this module's own
  `var struct` without `use mutation`; `check_expr`'s `EConstruct`
  refuses one another module declares, from `store.mutation`, which
  `type_check ~mutation` sets from the module's `use` lines
  (`Module.uses_mutation`).
- **`same`** takes two values of one type that has an identity: an
  array, a DynArray or a `var struct`. One nothing has decided is an array.
- **Equality**: `check_binary` accepts `==` and `!=` on a list, a tuple
  or an immutable datatype when `equality_problem` finds no part without
  equality -- a function, an identity type, a type variable -- and
  otherwise refuses it naming that part.
- **Slices**: `ESlice` is a node of its own, typed as its sequence's
  kind (a view's slice is an array). `Slice` is a type of one parameter
  that `store_element` reads like an array's, so indexing, writing,
  `for` and `len` take it; `view` and `copy_into` are builtins.
- **MutMaps**: `MutMap` is a type of two parameters; `mutmap_parts` reads them.
  `EIndex` and `SSetIndex` on a MutMap take a key, `for` and a
  comprehension walk its keys, and `check_builtin_call` types its
  builtins. `demand_key` refuses a key type `key_problem` finds a
  non-key in, at each use and, for every binding, at the end of the
  module.
- **DynArrays**: `DynArray` is a type of one parameter like `Array`;
  `store_element` reads the element type of either, which is what
  `EIndex`, `SSetIndex`, `for` and `len` ask. `builtin_env` binds
  `empty::dynarray` and `list::dynarray`, and `check_builtin_call` types the five
  writers: the first argument is unified with a DynArray, an index with Int,
  a value with the element type.
- **Open types** (FCR-H2): `check_open_arrays` refuses a binding whose
  type holds an array of undecided elements, or a `var struct` of an
  undecided parameter, at the end of the module.

### The interpreter

- An array is `VArray of value array`, shared by reference; a DynArray is
  `VDynArray of dynarray`, a record of an array of room and a length, grown by
  doubling, a removed element's slot cleared.
- A MutMap is `VMutMap of mutmap`: its entries in insertion order (`None`
  where one was removed, compacted as the store grows), a `Hashtbl` from
  key to position -- a key's structure is OCaml's structural hash and
  equality, since no key holds a Float, a function or a mutable value --
  and a version that insertions and removals bump; a `for` over it
  records the version and checks it at every step (`walking_version`).
- `==` is `equal_parts`, part by part, Floats by IEEE.
- A view is `VView of view`, the array, an offset and a length; a slice
  is `slice_value`, evaluated as a list of its sequence and bounds is.
- Every datatype's value is `VData (constructor, fields)`, the fields a
  `(label, value) array`. Only a `var struct`'s are ever written, so the
  sharing is unobservable for the rest; `same` compares the arrays with
  `==`. A `var struct` always has a field, so two never share an empty
  array.
- Writes are continuations: `KSetArray`, `KSetIndex` (the check),
  `KSetValue` for an element; `KSetOwner`, `KSetField` for a field.
- `display_value` keeps the path of arrays and structs it is inside
  (a `Leave` piece pops one) and prints `...` for one already on it.

### The backends

Each backend's page says how it compiles these: docs/target_python.md,
docs/target_js.md, docs/target_java.md, docs/target_ocaml.md and
docs/target_c.md. All share the rules above: the order of evaluation,
`same` as host identity, and a printer with the recursion-path guard.

### Warnings and tools

- `shared-fill` (on by default) reports `array(n, v)` with a mutable
  `v`, from the checker's resolution of the call.
- `unused-var` counts a compound write as a read, since it reads.
- The REPL, the language server (hover, completion, signature help for
  `array` and `array_init`), the debugger and the playground need
  nothing of their own: they use the checker and `display_value`.

### Tests

| what | cases |
|---|---|
| compound assignment | `typecheck_compound_assign*`, `fail_typecheck_compound_*` |
| tuple `:=` | `typecheck_tuple_mutate`, `fail_typecheck_tuple_mutate_*` |
| arrays | `array_*`, `typecheck_array`, `fail_typecheck_array_*`, `tests/warnings/shared_fill.pyk`, `tests/repl/arrays.repl` |
| the collector | `gc_strings` (`c_peak_mb`, on `c23-gc`) |
| DynArray | `dynarray_basic`, `dynarray_lib`, `dynarray_bounds`, `dynarray_pop_empty`, `typecheck_dynarray`, `fail_typecheck_dynarray_*` |
| `==` | `equality`, `fail_typecheck_eq_*` |
| MutMap | `mutmap_basic`, `mutmap_changed`, `mutmap_missing`, `typecheck_mutmap`, `fail_typecheck_mutmap_*` |
| slices and views | `slices`, `slice_bounds`, `view_bounds`, `typecheck_slices`, `fail_typecheck_slice_*`, `fail_typecheck_view_*`, `fail_typecheck_copy_into_type` |
| all of them on every C | `mutable_values` |
| order | `eval_order_calls` |
| `var struct` | `var_struct`, `var_struct_import`, `typecheck_var_struct`, `fail_typecheck_var_struct_*`, `fail_typecheck_struct_write`, `fail_typecheck_var_datatype` |
