# The C targets

**Targets in this family:** `c89`, `c99`, `c23` -- plain C -- and
`c23-gc` (alias `c-gc`), c23 with a collector.

**Key points**

- One backend, `src/target_c.ml`, with a `standard` parameter. The
  three plain targets translate *identically*; the standard decides
  comments, where declarations may appear, how booleans are spelled,
  and which headers are needed. `c23-gc` is c23 with the
  **Boehm–Demers–Weiser collector, bdwgc**, and compiles more.
- It infers no types of its own: every type it writes is read out of the
  checker's `tmap`, as `src/target_ocaml.ml` reads them.
- **Plain C** is meant to be clean, readable C for teaching: it
  allocates with `malloc` and never frees, and checks no array index.
  An array is a struct `{ int len; T *items; }` passed by value, read as
  `a.items[i]`. Lists, datatypes holding themselves and a function value
  that could outlive the stack frame it captures from need a heap that
  is freed, so plain C refuses them with a source position, saying
  c23-gc compiles them.
- **c23-gc** allocates from the collector, which frees what nothing
  holds, and checks every index and array size. It compiles everything
  the checker accepts but a polymorphic parameter: lists as typed cons
  cells, a datatype holding itself as a pointer to a collected struct,
  and a closure's environment on the collected heap (see "Memory").
- On all four, a `var struct`, a `DynArray`, a `MutMap` and a view are
  pointers to a struct written in place (see "Var structs", "DynArrays",
  "MutMaps" and "Slices and views"), `==` compares lists, tuples, structs
  and datatypes part by part, and printing a value that holds itself
  writes `...` where it repeats.
- A polymorphic function is compiled **once per type it is used at**; a
  tuple is a struct and a datatype a tagged union, both passed by value;
  a nested `def` or a lambda is a function of its own taking what it
  captures; a function value is a function pointer and an environment.
- Output is one `.c` file per module needing the C standard library
  (and on c23-gc bdwgc), and only the headers it uses.
- Least optimal at: strings, which every join (`+` on two strings) and
  conversion allocates afresh.

Verified with `gcc -pedantic` under all four.

## The four targets

| | `c89` | `c99` | `c23` | `c23-gc` |
|---|---|---|---|---|
| comments | `/* … */` | `// …` | `// …` | `// …` |
| declarations | hoisted to the top of each block | where they appear | where they appear | where they appear |
| booleans | `int`, `1`/`0` | `bool`, `true`/`false`, `<stdbool.h>` | `bool`, `true`/`false` | `bool`, `true`/`false` |
| memory | `malloc`, never freed | the same | the same | bdwgc, freed when nothing holds it |
| indexes and sizes | not checked | not checked | not checked | checked |
| built with | `cc -std=c89 foo.c -lm` | `cc -std=c99 foo.c -lm` | `cc -std=c23 foo.c -lm` | `cc -std=c23 -DPYKING_GC foo.c -lgc -lm` |

C89 has no compound literals and no non-constant aggregate
initializers, so every struct is built by a function of its own
(`pyk_mk_...`), which reads the same under all of them.

## Memory

**Plain C** allocates a String, an array's elements and the like with
`malloc` and never frees them: a program that drops what it makes
keeps it until it ends. That is what keeps its output plain, and why it
refuses what only a heap that is freed makes sense for.

**c23-gc** links bdwgc, the Boehm–Demers–Weiser conservative collector,
and nothing else manages memory.

- **What allocates.** A String the program makes -- a join, a
  conversion, a Char's UTF-8, a value printed inside a tuple -- and a
  String a library answers (`io.read`, `fs.read_text`, `text`'s slices)
  come from `GC_MALLOC_ATOMIC`, since a String holds no pointers for the
  collector to follow. An array's elements come from `GC_MALLOC_ATOMIC`
  where an element holds no pointer (an `Int`, `Char`, `Float` or
  `Bool`, or a tuple or datatype of only those) and from `GC_MALLOC`
  where it does. A list's cells, a datatype holding itself, a closure's
  environment and a `var` a closure captures come from `GC_MALLOC` (the
  last from `GC_MALLOC_ATOMIC` where it holds no pointer).
- **Starting it.** `main` calls `GC_INIT()` before the program's own
  top level, which is a block of its own after it.
- **Where it comes from.** bdwgc is a system library: `brew install
  bdw-gc` on macOS, `apt install libgc-dev` on Debian and Ubuntu, `dnf
  install gc-devel` on Fedora. Only c23-gc needs it. `pyk compile --run`
  (and the Makefile it writes) finds it with `pkg-config bdw-gc`, and
  otherwise in `/opt/homebrew`, `/usr/local`, `/opt/local` and `/usr`;
  where it is nowhere, `pyk` says so and how to install it, rather than
  leaving the C compiler to say `gc.h` is missing. By hand:

  ```
  cc -std=c23 -DPYKING_GC -o prog prog.c $(pkg-config --cflags --libs bdw-gc) -lm
  ```

  `PYKING_GC` is read by the libraries' C files, which allocate from
  the collector under it and with `malloc` without it.
- **Tested.** `tests/gc_strings.pyk` drops over fifty MB of Strings and
  `tests/gc_lists.pyk` some forty MB of list cells, tree nodes and
  closure environments; each manifest entry (`c_peak_mb`) holds a
  c23-gc build to a small fraction of that: tests/test_script.py runs it
  with its data segment limited to that much (`RLIMIT_DATA`, set on Linux
  only, which enforces it; macOS refuses the call, so there the case
  checks only the output), so a build that freed nothing would fail.
  Memory is not compared across targets.

## What is refused

| refused | where | why |
|---|---|---|
| a list, `[e for ...]`, `for x in` a list, `range` outside a `for` header, a list pattern | plain C | a list's cells are made and dropped as the program goes, which needs a heap that is freed |
| `array(xs)` from anything but a list literal; `array.to_list` | plain C | the same: `array([1, 2])` builds the array straight from the literal's elements, with no list between, but any other list is a list |
| a datatype holding itself, directly or through another, a tuple, an array or a list (`Tree(a)`) | plain C | a value of it has no size of its own, so it is a pointer into the heap |
| a function value that captures, returned, or held in a tuple, a datatype, an array, a list or a top-level binding | plain C | its environment is on the stack of the function that made it |
| a polymorphic parameter (`all a. (a) -> a`) | all four | one function would have to serve every type, which needs one representation for all of them |
| a polymorphic function as a value, other than as an argument or another name for it | all four | a value has one type, and the function is compiled once per type |

Each refusal on plain C says that c23-gc compiles it.

`for x in range(a, b, c)` builds no list on any of them: it is a
counting loop. On plain C, `len` of a list literal is its count of
elements, each worked out for what it does and no list made.

## Lists (c23-gc)

A list is a **pointer to its first cell**, `NULL` for `[]`. A cell is a
struct declared once per element type, guarded like every compound
type, and made from the collector by `pyk_cons_<code>`:

```c
typedef struct pyk_l_Li_ {
    int head;
    struct pyk_l_Li_ *tail;
} pyk_l_Li_;
```

Lists are never changed, so a list shares its cells with every list
built onto it.

| Pyking | C |
|---|---|
| `[1, 2]` | `pyk_cons_Li_(1, pyk_cons_Li_(2, NULL))`, the elements worked out left to right first where they can print |
| `[x * x for x in xs if x > 0]` | loops of their own appending at the end, through `pyk_endN`; in place where it is a binding's value or what a function answers, and otherwise a function of its own (`main_list`) taking what it reads from around it |
| `xs + ys` | `pyk_append_Li_(xs, ys)`: xs copied, ys shared |
| `xs[i]` | `pyk_nth_Li_(xs, i)`, which stops the program with `the index 5 is outside a list of 2 elements` |
| `len(xs)` | `pyk_length_Li_(xs)` |
| `range(a, b, c)` as a value | `pyk_range(a, b, c)` |
| `for x in xs`, `loop acc = e for x in xs:` | `for (x_at = xs; x_at != NULL; x_at = x_at->tail) { x = x_at->head; ... }` |
| `array(xs)` | `pyk_array_of_Li_(xs)` |
| `case [a, b]:`, `case [x, ..rest]:` | the cells tested present (`s != NULL && s->tail != NULL`), then each element read where it sits (`s->tail->head`); rest is `s->tail` |
| `case [a, ..mid, z]:` | the length tested, the elements after the rest counted back from the end (`pyk_drop_Li_`), and mid a copy (`pyk_take_Li_`) |

Printing a list, on its own or inside a value, is `pyk_show_<code>`:
`[`, each element as it is written inside a value, and `]`. A list
whose element type nothing settles (`empty = []`) is `NULL` wherever it
is read: it is `[]` at every list type.

## Chars and Strings

A `Char` is an `int` holding its code point; `'a'` is written `97`, and
`case 'a':` tests `== 97`. A String stays UTF-8 and is counted in code
points, walked by the helper `pyk_utf8_step(p, &c)`, which decodes the
code point at `p` into `c` and answers where the next one starts, or
`NULL` at the end:

| Pyking | C |
|---|---|
| `len(s)` | `pyk_utf8_length(s)`: code points, not bytes |
| `s[i]` | `pyk_char_at(s, i)`; out of range it writes the error to stderr and exits with 1 |
| `for c in s`, `loop acc = e for c in s:` | `for (c_at = s; (c_at = pyk_utf8_step(c_at, &c)) != NULL; )`: no list, so no heap |
| `string(c)`, printing a Char | `pyk_utf8(c)`: its UTF-8 bytes, in a String of its own |
| `int(c)`, `float(c)`, `bool(c)` | `c`, `(double)c`, `c != 0` |
| `char(n)`, `char(s)`, `char(c)` | `pyk_char_of_int(n)` (0 unless a Unicode scalar value), `pyk_char_of_string(s)` (its first code point, 0 for `""`), `c` |
| `<`, `==`, ... on Chars | the same operators on the code points |

Inside a tuple or a datatype (`pyk_show_...`), a Char is written by
`pyk_quote_char` (`'a'`, with `\'`, `\\`, `\n`, `\t`, `\r`, `\0`
escaped) and a String by `pyk_quote` (`"abc"`, with `\\`, `\"`, `\n`,
`\t`, `\r` escaped). A C string ends at its first NUL byte, so
`string('\0')` is `""` here.

## How types are written

| Pyking | C |
|---|---|
| `Int`, `Char`, `Float`, `Bool`, `String` | `int`, `int` (the code point), `double`, `int`/`bool`, `const char *` |
| `()` | `void` as a result, `int` as a value (0) |
| `(Int, String)` | `pyk_t_Tis_`, a struct with `a0`, `a1` |
| `Shape`, `Maybe(Int)` | `pyk_d_D<module>_Shape__`, `pyk_d_D<module>_Maybe_i_`: a struct with a `tag` and a union of the constructors' fields |
| `Tree(Int)`, a datatype holding itself (c23-gc) | `pyk_d_D<module>_Tree_i_ *`: a pointer to that struct, from the collector |
| `(Int) -> Int` | `pyk_c_Fi_i_`: a function `fn` taking the environment first, the environment `env`, and `plain`, the function itself where it captures nothing |
| `Array(Int)` | `pyk_a_Ai_`: a struct of `len` and a pointer to the elements, `items` |
| `[Int]` (c23-gc) | `pyk_l_Li_ *`: a pointer to the first cell, `NULL` for `[]` |
| `DynArray(Int)` | `pyk_v_Vi_ *`: a pointer to a struct of `len`, `cap` and `items` |
| a `var struct` `Point` | `pyk_d_D<module>_Point__ *`: a pointer to its struct |
| `MutMap(String, Int)` | `pyk_m_Msi_ *`: a pointer to its entries' struct |
| `Slice(Int)`, a view | `pyk_w_Wi_ *`: a pointer to the array's elements, a start and a length |
| `Ptr(Int)` | `int *`: C's own pointer |

A compound type's name is its **code**: one letter per scalar (`i`,
`c`, `f`, `b`, `s`, `u` for unit), and `T...`, `D<module>_<name>_...`,
`F..._..._`, `A..._`, `V..._`, `W..._`, `M..._`, `P..._` and `L..._` for
a tuple, a datatype, a function, an array, a DynArray, a view, a MutMap, a
pointer and a list. A datatype is
always named with its module, so every file of a program writes the
same struct. Each type is declared guarded (`#ifndef PYK_TYPE_...`), so
a header and the file including it may both carry it, and a module's
header carries every type its file declares.

## Arrays

An array (PYKING.md, "Arrays") is a struct declared once per element
type, guarded like every compound type, and passed **by value**: its
length and a pointer to its elements.

```c
typedef struct pyk_a_Ai_ {
    int len;
    int *items;
} pyk_a_Ai_;
```

Assigning one, passing it, answering it, holding it in a tuple, a
datatype or another array, and capturing it copy the struct, never the
elements: every name holding an array sees a write through any other.
`same(a, b)` is `a.items == b.items`, and `len(a)` is `a.len`.

| Pyking | C |
|---|---|
| `array([4, 1, 2])` | `(t = pyk_new_Ai_(3), t.items[0] = 4, ..., t)`: the elements written straight in, left to right; no list is made |
| `array(xs)`, any other list (c23-gc) | `pyk_array_of_Li_(xs)` |
| `array(n, v)` | `pyk_fill_Ai_(n, v)`: n times the one value v |
| `array(n, f)` | `pyk_init_Fi_i_(n, f)`: element i is `f.fn(f.env, i)`, for i = 0, 1, ... in turn |
| `array(n, seed, f)` | `pyk_unfold_Fi_Tii__(n, seed, f)`: each turn `r = f.fn(f.env, s)`, element i is `r.a0` and `s` becomes `r.a1` |
| `a[i]` | `a.items[i]` on plain C; `pyk_at_Ai_(a, i)`, checked, on c23-gc |
| `for x in a`, `loop acc = e for x in a:` | `for (x_at = 0; x_at < x_array.len; x_at++) { x = x_array.items[x_at]; ... }` |

**Checks (c23-gc).** Plain C checks nothing: its maker is `malloc`, and
an index outside the array is undefined, as in any C. On c23-gc every
maker starts with `pyk_new_<code>(n)`, which asks
`pyk_array_items` for the elements: a negative `n` stops the program
with `an array's size is never negative, and this one is -1`, and `n`
elements of more bytes than a `size_t` counts -- or more than the
collector can find -- with `an array of N elements is more than this
machine can hold`, both before an element is made or `f` called once.
Every read and write goes through `pyk_check_index(i, a.len)`, which
stops the program with `the index 5 is outside an array of 2 elements`
(`element` for one). Like every runtime error here, it writes `error:`
and the message to stderr and exits with status 1; `exit` flushes what
the program printed before.

**An element write** `a[i] := v` is statements of its own, run in the
order PYKING.md gives: the array into a temporary, the index into
another, the index checked, and only then the value worked out and
written into the array the temporary holds -- even when working it out
rebinds the name the array came from. On c23-gc:

```c
pyk_a_Ai_ pyk_arr2 = held;
int pyk_idx3 = 0;
pyk_check_index(pyk_idx3, pyk_arr2.len);
pyk_arr2.items[pyk_idx3] = replace_held();
```

Plain C writes `held.items[0] = replace_held();`, operands that can
print pinned in order first.

`a[i] += e` reaches the backend already as that, its array and index
named once (`element__array`, `element__index`, desugar_args.md).

**Printing** an array, on its own or inside a tuple, a datatype or
another array, is `pyk_show_<code>`: `array([`, each element as it is
written inside a list (a String quoted, a Char in single quotes), and
`])`.

On plain C a function value is held in an array only where it
captures nothing: one whose environment is on the stack is refused, as
in a tuple.
`tests/array_nolist.pyk` exercises all of this, and `lib/array`, without
a list; `array_bounds_read.pyk`, `array_bounds_write.pyk` and
`array_negative_size.pyk` the three runtime errors.

## Var structs

A `var struct` (PYKING.md, "Var structs") is a **pointer** to its
struct on every C target: plain C allocates it with `malloc` and never
frees it, c23-gc with `GC_MALLOC` (`GC_MALLOC_ATOMIC` where no field
holds a pointer). Its constructor makes one; every name, parameter,
element and field holding it holds the pointer, so a write through any
is seen through all.

| Pyking | C |
|---|---|
| `var struct Point(x: Int, y: Int = 0)` | `typedef struct pyk_d_D<module>_Point__ pyk_d_D<module>_Point__;` ahead, then `struct pyk_d_D<module>_Point__ { int x; int y; };` |
| `Point(5)` | `pyk_mk_D<module>_Point___Point(5, 0)` |
| `p.x` | `p->x` |
| `p.x := v` | `p->x = v;` |
| `p.x += e` | `field__owner = p; field__owner->x = field__owner->x + e;` (desugared before the backend) |
| `same(p, q)` | `p == q` |
| `case Point(x, y):` | the fields read as they are: `p->x`, `p->y` |

**A field write** runs its owner first, then the value, then the write.
Where the owner is a local of its own, or neither the owner nor the
value calls anything, nothing can tell the two apart and the write is
the one line above. Otherwise the owner goes in a temporary first:

```c
pyk_d_Dmain_Counter__ *pyk_owner17 = field__owner;
pyk_owner17->n = field__owner->n + switch_();
```

A datatype that reaches itself through a var struct, an array or a DynArray
holds only a pointer to it, so it stays a value: it is declared ahead,
as a datatype holding itself is, and needs no heap of its own (plain C
compiles it).

## DynArrays

A DynArray (PYKING.md, "DynArrays") is a **pointer** to a struct declared once per
element type -- its length, its capacity and its elements:

```c
typedef struct pyk_v_Vi_ {
    int len;
    int cap;
    int *items;
} pyk_v_Vi_;
```

`pyk_grow_<code>` doubles the elements when they are full, with
`realloc` on plain C and `GC_REALLOC` on c23-gc (the allocator
markers). Each operation is a helper of the file, written once per
element type:

| Pyking | C |
|---|---|
| `dynarray()`, `dynarray([1, 2])` | `pyk_new_Vi_(0)`; `(t = pyk_new_Vi_(2), t->items[0] = 1, t->items[1] = 2, t)` |
| `dynarray(xs)`, any other list (c23-gc) | `pyk_of_list_Vi_(xs)` |
| `push(v, x)`, `insert(v, i, x)` | `pyk_push_Vi_(v, x)`, `pyk_insert_Vi_(v, i, x)` |
| `pop(v)`, `remove(v, i)`, `clear(v)` | `pyk_pop_Vi_(v)`, `pyk_remove_Vi_(v, i)`, `pyk_clear_Vi_(v)` |
| `v[i]`, `v[i] := x` | `v->items[i]` on plain C; `pyk_at_Vi_(v, i)` and a checked write on c23-gc |
| `len(v)`, `same(v, w)` | `v->len`, `v == w` |
| `for x in v` | `for (x_at = 0; x_at < x_array->len; x_at++) { x = x_array->items[x_at]; ... }`: the length read again every turn |

**Plain C checks nothing**: popping an empty DynArray, or an index outside
it, is undefined, as in C. **c23-gc** checks each and stops the program
with status 1: `pop from an empty DynArray`, `insert's index 5 is outside 0
to 2, the DynArray's length`, and `the index 5 is outside a DynArray of 2
elements` -- an element write checks its index before the value is
worked out and again before it writes, since the value may have shrunk
the DynArray. It also clears a slot an element leaves where the element can
hold a pointer, so the collector does not keep what it held.

## Structural `==`

`==` and `!=` on a list, a tuple, a struct or a datatype call a
function written once per type, `pyk_eq_<code>(a, b)`, answering 1 or
0: a tuple element by element, a list cell by cell (and both ending
together), a datatype by its tag and then the fields of its
constructor. A part that is a scalar is compared with C's `==` -- a
Float by IEEE's rule, so `nan` equals nothing and the two zeros are
equal -- and a String with `strcmp`; `!=` is `!pyk_eq_...`. Scalars
compare as they always did, inline.

## MutMaps

A MutMap (PYKING.md, "MutMaps") is a **pointer** to a struct declared once
per key and value type: its entries' keys and values side by side, in
the order the keys came. Replacing a key's value keeps its place;
removing an entry moves the later ones down.

```c
typedef struct pyk_m_Msi_ {
    int len;
    int cap;
    int version;   /* c23-gc */
    int nslots;    /* c23-gc */
    int *slots;    /* c23-gc */
    const char **keys;
    int *values;
} pyk_m_Msi_;
```

**Finding a key** is `pyk_find_<code>(d, k)`, its position or -1.

- **Plain C** looks at each key in turn with `pyk_eq_<code>`: simple to
  read, and linear in the MutMap's size. It checks nothing: reading or
  removing a missing key, and changing a MutMap a `for` is walking, are
  undefined.
- **c23-gc** keeps a hash index, `slots`: open addressing over the
  positions, at least twice as many slots as entries, hashed by
  `pyk_hash_<code>` (FNV-1a for a String, combined part by part for a
  tuple, a list or a datatype -- agreeing with `pyk_eq_<code>`). It is
  rebuilt when it fills and when a removal moves entries, so a removal
  is linear. A missing key stops the program with `the MutMap has no key
  "b"` (`... to remove` for `remove`), the key written as a value is.
  `version` counts the keys put in and taken out (not a replaced
  value), and a `for` checks it at every advance, the last included:
  `the MutMap changed while a for loop was reading it`.

| Pyking | C |
|---|---|
| `mutmap()`, `mutmap([("a", 1)])` | `pyk_new_Msi_()`; `(t = pyk_new_Msi_(), pyk_put_Msi_(t, "a", 1), t)` |
| `d[k]`, `d[k] := v` | `pyk_at_Msi_(d, k)`, `pyk_put_Msi_(d, k, v);` |
| `get`, `has`, `remove`, `discard`, `clear` | `pyk_get_Msi_`, `pyk_has_Msi_`, ... |
| `keys`, `values`, `items` (c23-gc) | lists, in order |
| `len(d)`, `same(d, e)` | `d->len`, `d == e` |
| `for k in d` | `for (k_at = 0; k_at < k_mutmap->len; k_at++) { k = k_mutmap->keys[k_at]; ... }`, with `pyk_mutmap_walk` in the test on c23-gc |

Printing one is `mutmap([(k, v), ...])`, guarded on the path as a DynArray is.

## Slices and views

`s[i:j]` copies a run into a new value of the sequence's own kind --
a view's into an array -- through `pyk_slice_<code>(s, i, j)`; a bound
left out is 0 or the length, read off the sequence held in a name. It
slices an array, a DynArray, a view and a String (by code point, allocated
as every String is) on every C target, and a list on c23-gc.

A view, `view(a, i, j)`, is a **pointer** to a struct of the array's
elements, where its run starts and its length, so two views are `same`
only where they are one; a view of a view points into the same array,
the offsets added:

```c
typedef struct pyk_w_Wi_ {
    int len;
    int start;
    int *items;
} pyk_w_Wi_;
```

Element k is `w->items[w->start + k]`, read through `pyk_at_Wi_(w, k)`
and written in place. `copy_into(dst, src)` is `pyk_copy_<code>(dst
elements, room, src elements, n)`, which is `memmove`, right where the
two overlap.

c23-gc checks every bound, with the messages every target writes: `the
slice 2:4 is outside an array of 3 elements`, `the view 1:9 is outside
an array of 4 elements`, `the index 2 is outside a view of 2 elements`,
`copy_into copies 3 elements into 2`. Plain C checks none of them.

On the path, a view counts as the array it is a run of.
`tests/mutmap_slice_nolist.pyk` exercises MutMaps, `==`, slices and views
with no list, so plain C runs it too.

## Pointers

`Ptr(T)` (PYKING.md, "Pointers") is C's own `T *`, on every C target:

| Pyking | C |
|---|---|
| `&x`, a `var` | `&x` |
| `&a[i]`, an array's element | `&a.items[i]` on plain C; `pyk_place_Ai_(a, i)`, the index checked, on c23-gc |
| `&w[i]`, a view's element | `pyk_place_Wi_(w, i)`: `&w->items[w->start + i]`, checked on c23-gc |
| `&p.x`, a var struct's field | `&p->x` |
| `&*p` | `p` |
| `*p`, `*p := v` | `*p`, `*p = v;` (the pointer in a temporary first where the value could change it) |
| `p == q` | `p == q`: the same place |

Printing one is `Ptr(` and what it points at now, `)`; on the path it
counts as the place it points at.

**Plain C** keeps a `var` whose address is taken where C keeps it: a
local on its function's stack. Its address may be handed down to a call
(`swap(&x, &y)`), read and written through, compared, and kept in a
local of the same function -- and nothing else: an address of a local
that could outlive its function (answered, or put in a value, a field,
an element or another variable) is refused, saying c23-gc compiles it.
A top-level `var` is a static, so its address may go anywhere.

**c23-gc** moves every local `var` whose address is taken to a cell on
the collected heap, as a `var` a closure captures is, so the address
may outlive the function (`tests/pointers_escape.pyk`).

## Printing a value that holds itself

An array, a DynArray or a var struct may hold itself, through a datatype:
printing one already being printed further out writes `...`, as every
target does; one only shared prints in full each time. Only a printer
that can meet such a store takes the path from the value printed first,
a list of cells on the C stack:

```c
typedef struct pyk_path {
    const void *at;
    const struct pyk_path *up;
} pyk_path;

static const char *pyk_show_Dmain_Node__(pyk_d_Dmain_Node__ *v, const pyk_path *up)
{
    const char *out;
    pyk_path here;
    if (pyk_on_path(up, v)) {
        return "...";
    }
    here.at = v;
    here.up = up;
    ...
}
```

A store guards itself only where its own elements or fields can reach
its type, and only a type that can reach such a store passes the path
on: every other printer is as it was, one parameter and no path.

A datatype that reaches itself through a store is on the path too, as
every target counts it. C copies such a value, so it has no address of
its own to compare: its cell holds the value's address and
`pyk_alike_<code>`, which says two are one where they have the same
constructor holding the same stores (`tests/cycle_immutable.pyk`). Two
such values built apart from the same parts count as one here where the
interpreter, which compares the objects, would print one more level.
`tests/var_struct.pyk` and `tests/mutable_values.pyk` print cycles
through var structs, an array and a DynArray.

## Polymorphic functions

A def with type variables is a **template**: it is compiled once per
instance a call asks for, named for the types (`first_mis` is `first`
at `(Int, String)`), and the instances asked for while compiling one are
compiled in turn. What an instance is at is read off the call: its
result and its arguments, matched against the def's own type. A
polymorphic function handed as an argument is the instance the other
arguments settle, and another name for one (`same = id`) is that
function.

A call to another module's polymorphic function asks that module for
the instance: `Target_c.translate_all` translates every module of a
program, gathers what each asks of the others, and translates again
until nothing new is asked. The importing file declares the instance; the
module that wrote the function defines it.

A def nothing reaches is not compiled: the checker works out an
unannotated def's types the first time something calls it, so one no
live code reaches has none.

## Functions as values

A nested `def` is a function of its own, named after the one it is
written in (`scaled_times`), taking what it captures before its own
parameters. What it captures is known only once the module is done --
it may call another that captures more -- so the text holds a marker
where the captures go, and the printer fills them in. A `var` a closure
captures lives in a cell its owner keeps, `int count_cell = 0; int
*count = &count_cell;` on plain C and `int *count =
GC_MALLOC_ATOMIC(sizeof *count); *count = 0;` on c23-gc, and every
closure takes the pointer.

As a value, a def is a closure: a wrapper taking the environment first,
the environment -- a struct of what it captures -- and the plain
function where it captures nothing. On plain C the environment is on
the stack of the function that made the value:

```c
struct pyk_env_scaled_times {
    int pyk_unused;
    int factor;
};
static int pyk_w_scaled_times(void *env, int p1)
{
    struct pyk_env_scaled_times *e = env;
    return scaled_times(e->factor, p1);
}

int scaled(int factor, int x)
{
    struct pyk_env_scaled_times pyk_env3;
    pyk_env3.factor = factor;
    return apply_twice(pyk_mk_Fi_i_(pyk_w_scaled_times, &pyk_env3, NULL), x);
}
```

Calling one is `f.fn(f.env, x)`. On plain C a value whose environment
is in this function's frame is never returned, stored at the top
level, or put in a tuple, a datatype, an array or a list: each is
refused where it is written.

On c23-gc the environment is made on the collected heap where the
value is, inside the expression, so the value may go anywhere:

```c
pyk_c_Fi_i_ adder(int n)
{
    struct pyk_env_adder_add *pyk_env1;
    return (pyk_env1 = GC_MALLOC(sizeof *pyk_env1), pyk_env1->n = n, pyk_mk_Fi_i_(pyk_w_adder_add, pyk_env1, NULL));
}
```

## Datatypes and `match`

A constructor is a function building the struct, `pyk_mk_<code>_Circle`;
a field every constructor has is read by a function switching on the
tag. A datatype of one constructor -- a `struct` -- is a plain struct
with no tag and no union, its named fields members of their own names,
an unnamed one `f<i>`; a field read is `p.x`, and a pattern on it tests
nothing. A `match` holds its subject in a local and is an if/else chain of
tests on it; every `match` matches every value (exhaustive.md), so the
last case needs no test. Where a case has a guard, the cases are a
chain of `if`s that a matched one leaves by `goto`.

Printing a compound value calls a function written for its type,
`pyk_show_<code>`, building its text with `pyk_concat`.

**A datatype holding itself** -- directly, or through another datatype,
a tuple, an array or a list -- has no size of its own, so on c23-gc a
value of it is a **pointer** to its struct, which its constructor
makes with `GC_MALLOC`. The struct is declared ahead (`typedef struct
pyk_d_... pyk_d_...;`) so that its fields, and the list cells holding
it, can name it before it is complete; a member is read through `->`
(`s->tag`, `s->u.Node.f0`), and a printer called before it is written
-- two datatypes holding each other -- is declared ahead too. Plain C
refuses one.

## The top level

What the top level binds is a **file-scope variable**, declared
`static` above the functions and assigned where the binding is, so a
function reads it and `:=` writes it with nothing captured. A block's
bindings stay locals.

## Evaluation order

Pyking evaluates an operator's operands, and a call's arguments, left to
right. C leaves both unspecified, and compilers really do differ: on
x86-64, `gcc` and `clang` evaluate a call's arguments right to left,
while on AArch64 they evaluate them left to right. That is invisible
unless the order can change what is printed or worked out, so the
backend pins down two kinds of operand:

- one that can **print** -- `analyses.Effects`, the same walk of the
  call graph the OCaml backend uses -- before any later one that prints;
- one a call could **change** -- it reads a `var` a call can write (a
  top-level one, or one a closure captures), a field of a var struct,
  an element of an array or a DynArray, a DynArray's length, or itself calls
  something -- before a later operand with a call that can change
  something; and an operand with such a call before a later one it
  could change. Which calls can change something is a walk of the call
  graph beside the printing one (`changes`): a def that writes a `var`
  not its own, a field, an element or a DynArray, or calls one that does, a
  builtin that writes, or another module's function (whose body this
  walk cannot see); a call through a function value can wherever
  anything in the program writes. A def that only computes, such as a
  recursive `fib`, changes nothing, so `fib(n - 1) + fib(n - 2)` stays
  as written. `count + tick()`, where `tick` adds one
  to the top-level `var count`, reads `count` first
  (`tests/eval_order_calls.pyk`).

C's one construct that fixes an order inside an expression is the comma
operator, so `in_order` pulls every printing operand but the last into a
temporary and puts the assignments in front of the result:

```
called = add(step("f", 10), step("g", 20))
```

```c
called = (pyk_t1 = step("f", 10), add(pyk_t1, step("g", 20)));
```

The temporaries are declared at the top of the function they appear in
(`pyk_t1`, `pyk_t2`, ...; a Pyking name starting `pyk_` takes a `_`), never beside the statement that needs them: an
operand written in a `while` condition is evaluated again every turn,
and one written in a branch of an `if` expression only when that branch
is chosen, so the assignment has to stay inside the expression it
belongs to. Ordering a *statement's* pieces in front of it would be
wrong in both places, which is why the comma operator does the work
rather than a hoisted statement. `print` works the same way:

```
print(step("l", 1), step("m", 2))
```

```c
printf("%d %d\n", (pyk_t7 = step("l", 1), pyk_t7), step("m", 2));
```

A program whose expressions only compute — no call beside a `var`, a
field or an element it could change — has nothing to order, and its
operands stay exactly where the source put them; no temporary is
declared.

**`print` writes its arguments once every one is worked out.** Where an
argument holds an array, a DynArray or a var struct and a later argument
calls something, which could change it, every argument is put in a
temporary first, in order, and only then formatted:

```c
(pyk_t6 = c, pyk_t7 = bump(c), printf("%s %d\n", pyk_show_Dmain_Counter__(pyk_t6), pyk_t7));
``` `tests/evaluation_order.pyk` pins the straight-line cases down and
`tests/evaluation_order_branches.pyk` the two conditional ones; one
`.out` serves every target.

## Floating-point contraction

C lets a compiler fuse `a * b + c` into one fused multiply-add, rounded
once where every other host rounds twice; clang does it by default on
AArch64, so a Float can differ in its last digit. A file that uses
`double` therefore starts with

```c
#if defined(__clang__)
#pragma STDC FP_CONTRACT OFF
#elif defined(__GNUC__)
#pragma GCC optimize ("fp-contract=off")
#endif
```

`tests/lib_random_basic.pyk` is the case that showed it.

## Modules

C has one namespace for a whole program and no import at all, so a
Pyking module becomes two files -- a translation unit and the header
another unit includes it through -- and the module's own name becomes
part of every name it exports.

```pyking
# helper2.pyk
def scale(n:Int) -> Int:
    return n * 2


public def inc(x:Int) -> Int:
    return scale(x) + 1


public greeting: String = "hi"
```

```c
/* helper2.h */
#ifndef PYK_HELPER2_H
#define PYK_HELPER2_H

extern const char *helper2_greeting;

int helper2_inc(int x);

/* Runs the module's own top level; the program calls it once, before any module that imports this one. */
void helper2_init(void);

#endif  /* PYK_HELPER2_H */
```

```c
/* helper2.c */
#include "helper2.h"

/* What this module exports as a value; its own top level below is what fills each of them in. */
const char *helper2_greeting;

/* Declared ahead of their definitions: a Pyking function may be called before it is written. */
static int scale(int n);
int helper2_inc(int x);

static int scale(int n)
{
    return n * 2;
}

int helper2_inc(int x)
{
    return scale(x) + 1;
}

void helper2_init(void)
{
    const char *greeting;

    greeting = "hi";
    helper2_greeting = greeting;
}
```

```c
/* program.c */
#include <stdio.h>

#include "helper2.h"

int main(void)
{
    helper2_init();
    printf("%d\n", helper2_inc(1));
    printf("%s\n", helper2_greeting);

    return 0;
}
```

Four things are worth reading off that.

**A public name carries its module's.** `inc` becomes `helper2_inc`,
because two modules may each define an `inc` and C would see one name.
A private name keeps its own spelling -- two modules' `static scale` are
two functions.

**`static` is the privacy.** Anything the module does not export is
`static`, in every module of a program of several -- including the
program's own. A program of *one* module emits no `static` at all, which
is what keeps a single-file program's output what it always was.

**A public value is a variable, filled in by `init`.** The binding is
translated like any other, and `<module>_init` ends by handing what it
worked out to the file-scope variable the header declares.

**Order is explicit.** C runs no code before `main`, so every module's
top level is a `void <module>_init(void)` and `main` calls them in
dependency order before its own body. Those calls are *statements of
`main`*, not lines the printer adds around it, which is what puts them
after the declarations `c89` hoists to the top of a block -- a
declaration may not follow a statement there. The program's own module therefore
includes the header of *every* module of the program, not only the ones
it imports directly: it is where those calls are written, and C has to
be told a function exists before a call names it.

Building it is `cc -o prog helper2.c program.c` -- the modules first,
the program's own unit last -- which is what `--run` and the test
harness both do.

## Where the output is not optimal

- **Strings are not shared.** `pyk_concat`, a conversion and the text
  of a printed compound value allocate a new String each time; on
  c23-gc the collector frees it when nothing holds it, and plain C
  never does.
- **Printing a list joins one String per element**, each a copy of the
  last: quadratic in the list's length.
- **A polymorphic function is compiled once per type**, which grows the
  file as fast as the types it is used at.
- **A lifted function takes every name it mentions** from around it, used
  or shadowed inside.
- **Integers are `int`.** Overflow is undefined in C, as Pyking leaves
  it.
- **No optimisation.** The C compiler does that work afterwards.

## External modules

A module implemented in C (`sys.c`, declared in `sys_external.pyk` --
see [modules.md](modules.md)) is reached with **no header**. The
compiler generates nothing for it, so instead of `#include "sys.h"` the
file that imports it carries the declarations, taken from the
signatures:

```c
// What the external modules this one imports implement.
const char *sys_loadfile(const char *);
extern int sys_start;
```

A name is `<module>_<field>`, which is the convention a compiled Pyking
module already uses, so an implementation reads the same whether it was
written by hand or generated. `sys.c` is copied beside the program's
output and handed to the compiler with it.

An external module has no Pyking top level, so no `sys_init()` is
declared and none is called.

The boundary carries `Int`, `Char` (an `int`, its code point), `Float`, `String`, `Bool`, unit, a tuple of
those -- the struct this backend writes for it, which the implementation
declares the same, guarded the same (`lib/time/time_external.c`) -- and
a callback. On c23-gc a list of those crosses too, as a pointer to its
first cell, the cell struct declared by the implementation as the
program declares it and its cells made with `GC_MALLOC`
(`tests/external_shapes_mod1_external.c`, and `sys`'s `args` and `env`
and `tinyweb`'s `draw_pairs`, under `#ifdef PYKING_GC`). On plain C a
declaration naming a list is left out, and a call to one is refused:
only what a program uses of a library is compiled at all
([modules.md](modules.md), "What a program uses"), so `sys.exit`
compiles there while `sys.args` is refused.

`sys.args`, `sys.prog_name` and `sys.prog_path` need the program's own
argv, which only `main` is handed: on c23-gc, a program importing `sys`
has `int main(int argc, char **argv)`, which hands them to
`sys_external.c` through `pyk_sys_start(argc, argv)` after
`GC_INIT()`.

**A module in two halves** is compiled too. Its generated file declares
the names its own declaration half provides, so its Pyking half calls
them as `<module>_<field>`, and a file importing it declares the ones it
takes. `io` and `sys` are both, and `tests/module_external_mixed.pyk`
is the worked example.

**A declaration taking a callback** takes a plain pointer to a C
function, `pyk_fn_ii_v` for `(Int, Int) -> ()`. The program hands it a
top-level `def` by name, a lambda capturing nothing (lifted to a
function of its own), or a function value's `plain` pointer, which one
capturing nothing carries; one that captures stops the program with a
message, since a plain pointer carries no environment.
`tests/external_callback_named.pyk` is the worked example, and `tinyweb`
the library: `tinyweb_external.c` serves a program's page from one
`select` loop it runs from `atexit`, once `main` has returned
(libraries.md, "tinyweb").

`Bool` is the one type the two targets spell differently: the
declaration says `int` under `c89` and `bool` under `c23`, following
each standard. An implementation file serving both has to agree with
whichever it is compiled under, so it needs the usual
`#if __STDC_VERSION__ >= 199901L` around `<stdbool.h>`. A mismatch here
links quietly and works on most ABIs -- the declaration and the
definition are in different translation units, so nothing sees both --
which is why it is worth getting right rather than discovering.

**A program is linked with `-lm`**, after its files, by `--run` and by
the test harness alike: the `math` library's functions are libm's, which
glibc keeps apart from the C library, and a library resolves only what
the files before it left open. Elsewhere `-lm` is accepted and does
nothing. `math` compiles to a `math.h` of its own beside the program,
which a quoted `#include "math.h"` would find, so `math_external.c`
includes the system's as `<math.h>`. C89's has no `log2`, `cbrt`,
`hypot` or `trunc`; that file uses the library's under C99 and later and
its own under C89 (libraries.md, "One folder per library").

## Let expressions

A `let target = value in body` (PYKING.md, "Let expressions") is compiled as the value assigned to an evaluation-order temporary with the comma operator, `(pyk_t1 = x(), f(pyk_t1))`, a tuple's parts each into one of their own (`pyk_t2 = pyk_t1.a0`), the temporaries declared at the top of the function as `in_order`'s are.
A call whose named arguments are not in parameter order, with more
than one that has an effect, reaches this backend as nested `let`s
(`docs/desugar_args.md`).
