# Pointers

Pointers in Pyking: what a program writes and what it means (the
guide), then how the compiler implements them (the internals).
PYKING.md, "Pointers", is the reference; this page is the tour, and the
map of where each piece lives in `src/`. They belong to the mutation
design (docs/mutation.md), whose decisions are named `FCR-E1` to `E5`:
model P1, safe pointers, with `Option(Ptr(T))` for one that may point
nowhere.

## Contents

1. [The guide](#the-guide)
   1. [Why pointers](#why-pointers)
   2. [Turning them on](#turning-them-on)
   3. [Taking an address](#taking-an-address)
   4. [Reading and writing through one](#reading-and-writing-through-one)
   5. [Pointers to pointers, and to nothing](#pointers-to-pointers-and-to-nothing)
   6. [Equality and printing](#equality-and-printing)
   7. [How long a pointed-at variable lives](#how-long-a-pointed-at-variable-lives)
   8. [What pointers cannot do](#what-pointers-cannot-do)
   9. [What each target makes of them](#what-each-target-makes-of-them)
2. [The internals](#the-internals)
   1. [Where each piece lives](#where-each-piece-lives)
   2. [Lexer and parser](#lexer-and-parser)
   3. [The checker](#the-checker)
   4. [The interpreter](#the-interpreter)
   5. [The backends](#the-backends)
   6. [Tests](#tests)

## The guide

### Why pointers

They are here to teach C's model of memory: a variable has an address,
a function can be given that address, and a data structure can be
built from addresses. A Pyking program with pointers reads like the C
it stands for, and runs safely everywhere -- where C would have
undefined behaviour, Pyking either refuses the program or runs it as
written.

### Turning them on

```pyking
use mutation, pointers
```

`use pointers` needs `use mutation` in the same module, as an error
rather than an implication, so both are visible at the top of the file
(FCR-A2). Without `use pointers`, `&` and `*` in front of an operand are
refused, naming the line that would allow them.

### Taking an address

`&place` is a pointer to a place something may write. Its type is
`Ptr(T)`, where `T` is what the place holds.

| place | example | type |
|---|---|---|
| a `var` | `&count` | `Ptr(Int)` for an Int `var` |
| an element of an array | `&a[i]` | `Ptr(T)` for an `Array(T)` |
| an element of a view | `&w[i]` | the array's element `offset + i` |
| a field of a `mutable struct` | `&pt.x` | `Ptr(Int)` for an Int field |
| what a pointer points at | `&*p` | `p` itself |

Everything else has no address, and `&` of it is refused with the
reason: an `=` binding (nothing can write it), a list's element (a list
never changes), a DynArray's element (it moves when the DynArray grows), a plain
struct's field, a call's result and a literal (values, not places).

### Reading and writing through one

```pyking
use mutation, pointers

var total = 0

def add(into: Ptr(Int), amount: Int) -> ():
    *into += amount

add(&total, 5)
add(&total, 2)
print(total)         # 7
```

- `*p` reads what `p` points at, as it is now.
- `*p := v` writes it: `p` is worked out, then `v`, then the place `p`
  named is written. The compound forms read and write it back.
- A field through a pointer is `(*pp).x`, C's long form (FCR-E3): there
  is no `->` and no automatic dereferencing.
- `&` and `*` are prefix operators where an operand starts, and bitwise
  and and times between operands, as `-` is both. A line starting with
  `*` or `&` starts a statement, so `*p := 5` on a line of its own never
  continues the line before.

### Pointers to pointers, and to nothing

A `var` holding a pointer has an address too: `pp = &p` is a
`Ptr(Ptr(Int))`, and `**pp := 5` writes through both.

There is no null. A pointer that may point nowhere is an
`Option(Ptr(T))`, `None` or `Some(&x)` (FCR-E1), and a `match` decides
which before it is used:

```pyking
use mutation, pointers

def first_negative(xs: Array(Int)) -> Option(Ptr(Int)):
    var found = None
    var i = len(xs) - 1
    while i >= 0:
        if xs[i] < 0:
            found := Some(&xs[i])
        i -= 1
    found

nums = array([3, -4, 5])
match first_negative(nums):
    case Some(p):
        *p := 0
    case None:
        print("all positive")
print(nums)          # array([3, 0, 5])
```

### Equality and printing

- `p == q` is true when both name one place: the same variable, or the
  same slot of the same array or struct (FCR-E4). Pointers inside
  tuples, lists and datatypes compare so too.
- A pointer is never a MutMap's key: what it points at changes.
- A pointer prints as what it points at now, `Ptr(12)`, never as an
  address, so every target prints the same. A pointer that leads back
  into a value being printed prints `...` there, as any cycle does.

### How long a pointed-at variable lives

A `var` whose address is taken lives as long as a pointer to it
(FCR-E5), even after the function that declared it returns:

```pyking
use mutation, pointers

def counter() -> Ptr(Int):
    var n = 0
    &n

c = counter()
*c += 1
print(*c)            # 1
```

That is a dangling pointer in C. Plain C (`c89`, `c99`, `c23`) refuses
such a program, saying that `c23-gc` runs it; `c23-gc` keeps the
variable on its collected heap. Every other target keeps it as a
closure keeps a captured `var`.

### What pointers cannot do

- No null: `Option(Ptr(T))` instead.
- No arithmetic: `p + 1` is refused. A run of an array is a view
  (`view(a, i, j)`, PYKING.md "Slices and views").
- No `alloc` or `free`: memory is the language's to manage.
- No pointer to a list's or a DynArray's element, a MutMap's entry, an `=`
  binding or a temporary value.

### What each target makes of them

| target | a pointer to a `var` | to an element / a field | `*p` |
|---|---|---|---|
| plain C | `&x`, a C pointer | `&a.items[i]`, `&p->x` | `*p` |
| `c23-gc` | the same; a `var` whose address escapes is a collected cell | the same | `*p` |
| Python | a `__PykPtr`: the `var`'s box and its field name | `__PykPtr(store, slot)`: the array and index, or the struct and field name | `p.get()` |
| JavaScript | `{ pykPtr, store, slot, get, set }` over a place object beside the `var` | the same object over the array or struct | `p.get()` |
| Java | `PykRuntime.PykPtr<T>` over the `var`'s cell | the array or struct and a slot | `p.get()` |
| OCaml | an object over the `var`'s ref | an object over the array or record, with a reader and writer | `p#get` |

Each target's page (docs/target_python.md, target_js.md,
target_java.md, target_ocaml.md, target_c.md) gives the full
representation.

## The internals

### Where each piece lives

| piece | file |
|---|---|
| `use pointers` and its need of `use mutation` | `parser.ml`: `parse_with`, `check_features` |
| `*` and `&` starting a line | `lexer.ml`: `TokLineStar`, `TokLineAmp` |
| `&`, `*`, `**` as prefixes | `parser.ml`: `parse_unary` |
| `*p := v` | `parser.ml`: `parse_expr_statement_from`; `syntax.ml`: `SSetDeref` |
| the nodes | `syntax.ml`: `EAddr`, `EDeref`, `SSetDeref` |
| `*p op= v` | `desugar_args.ml`: the `pointer__target` temporary |
| types | `typesystem.ml`: `Ptr`, `ptr_name`, `t_ptr`, `ptr_target`; the `bvar` flag of a binding |
| running | `interpreter.ml`: `VPtr`, `location`, `address_of`, `read_location`, `write_location` |
| Option | `lib/option/option.pyk`; `parser.ml`: `with_option` |

### Lexer and parser

- **A line-start `*` or `&`** (outside brackets, first on its row, or
  just after an indentation token) is lexed as `TokLineStar` or
  `TokLineAmp`, which the parser reads only as a prefix. Without that,
  `*p := 5` after `print(x)` would continue it as `print(x) * p`, by the
  rule that a line continues while its tokens can.
- **`parse_unary`** reads `&e` as `EAddr`, `*e` as `EDeref`, and `**e`
  (one `TokStarStar`) as two `EDeref`s. The operand is a unary, so
  `&a[i]` takes the element and `*p.x` reads the field `x` of `p` --
  which is why a field through a pointer is `(*pp).x`.
- **`*p := v`** is parsed as an expression statement whose expression is
  an `EDeref`, as `a[i] := v` is from an `EIndex`; the compound forms are
  marked the same way, for `index_compound_parts`.
- **`use pointers`** without `use mutation` is refused where it is
  written; `check_features` refuses `EAddr`, `EDeref` and `SSetDeref`
  without `use pointers`.

### The checker

- `Ptr` is a type of one parameter, like `Array`. A binding records
  whether `var` made it (`bvar`), which is what `&x` asks.
- `EAddr` checks its operand's form -- a `var`; an `EIndex` of an array
  or a view; an `EField` of a `mutable struct` (or the `EQualified` a plain
  `p.x` is read as); an `EDeref` -- and refuses anything else, saying
  why. It types as `Ptr(T)`.
- `EDeref` unifies its operand with `Ptr(T)` and is a `T`; `SSetDeref`
  checks the pointer, then the value against `T`.
- `==` takes pointers (`equality_problem` finds nothing against them);
  `key_problem` refuses one as a MutMap's key.

### The interpreter

- A pointer is `VPtr of location`: `LCell` (a `var`'s cell, the same
  `value ref` a closure captures, so a pointer to a local outlives its
  call for free), `LElem` (an array and a slot -- a view's element is
  its array's) or `LField` (a struct's field array and a slot).
- `&` is evaluated as a list of the parts naming the place
  (`start_elements`), and `address_of` builds the location, checking an
  index; `*p` reads with `read_location`; `*p := v` is two
  continuations, `KDerefTarget` and `KDerefWrite`.
- Two pointers are equal when their locations are one place (physical
  equality of the cell or store, and the same slot). `display_value`
  prints `Ptr(...)` with what the location holds, the location's store
  on the path that stops a cycle; the debugger opens a pointer to `*`.

### The backends

Each backend's own page says how it represents a location; all share
the rules above. Plain C writes C's own pointers and refuses an address
that would outlive its function; `c23-gc` moves such a `var` to a
collected cell.

### Tests

| what | cases |
|---|---|
| pointers | `pointers`, `pointers_escape`, `typecheck_pointers` |
| refusals | `fail_typecheck_pointers_*`, `fail_typecheck_addr_*`, `fail_typecheck_deref_*`, `fail_typecheck_pointer_key` |
| Option | `option_builtin` |
