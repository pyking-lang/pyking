# Plan: collections, conversions, `fmap` and folds, Map, Option and Result

> **Status (November 2026): implemented**, on every target, with the
> recommendations of §16. Where the implementation differs from what is
> written below, it says so here:
>
> - **The builtins written in Pyking** (§7, §11): `fmap`, `filter`,
>   `foldl`, `foldr`, `any`, `all`, `list`, `list_init`,
>   `dynarray(n, v)`, `dynarray_init`, `map_init` and `mutmap_init` are
>   overload sets in a new lib/prelude (`list::fmap`, `array::fmap`,
>   ...), which the parser imports, under the `::` names only, into a
>   module that calls one of them -- as Option arrives. A module's own
>   `map` or `filter` means itself. A call is resolved by the
>   collection's type; a parameter nothing has decided is refused with
>   the annotation to write, as D3's answer says, rather than fixed by
>   its first call (§7.3).
> - **Conversions** (§6) of `array`, `dynarray`, `mutmap` and `map` are
>   typed members of the builtin sets that elaborate.ml rewrites into
>   the list form (`list::array([x for x in v])`, `items(m)` for a map),
>   so no backend has a conversion of its own. An Option converts to a
>   list only.
> - **The Map** (§8.6, §12.7) is each runtime's MutMap representation,
>   printed as `map(...)` and compared by its entries; lib/map changes
>   one by copying it through a MutMap, so a change takes time in
>   proportion to the Map's size (alternative B, not the HAMT). A Map is
>   not a key (§8.5's last point).
> - **`panic(message)`** is a new builtin, which `unwrap` and `expect`
>   need; their messages do not show the error value, since `string` of
>   a type variable is refused. `ok_or` is `result.ok_or`, not
>   `option.ok_or`, so that lib/option needs no Result. `sort_by` and
>   `sort_on` exist, on the one merge sort written in Pyking, so the
>   comparisons are the same on every target. `random.shuffle` stays a
>   list's.
> - **The checker** gained what the calls need: a lambda argument is
>   checked after a call's other arguments and seeded with its
>   parameter's type; a lambda's body may settle which overloaded
>   definition is meant; a binding's annotation inside a generic body may
>   name the body's type variables; a map's key type that is a type
>   variable is checked where a call decides it; a comprehension's
>   condition is unified with Bool. elaborate.ml numbers the nodes it
>   builds past every module's, which a library's rewritten conversions
>   first showed to be needed.
>
> Section 2 lists the decisions taken with the user; every other choice
> is a recommendation, with its alternatives written out where the
> choice is not obvious (section 12).

## Contents

1. Goal
2. Decisions taken
3. What exists today
4. The collection types
5. Making collections: one shape for every type
6. Conversions
7. The builtin higher-order functions
8. The immutable Map
9. Option and Result
10. The libraries, function by function
11. Builtin or library: the rule and the verdicts
12. Alternatives considered
13. Implementation, across the system
14. Phases
15. What is missing
16. Open questions

---

## 1. Goal

Make every collection type feel the same, so that someone who has learnt
one has learnt them all:

- **Making one** works the same way for every type, as `array` and
  `array_init` already do: `list([1, 2])`, `list(100, 'a')` and
  `list_init(n, f)`, and the same for `dynarray`, `map` and `mutmap`.
- **Converting** uses the same names: `list(array(100, "a"))` turns an
  array into a list, and `array(xs)`, `dynarray(xs)`, `map(m)` and
  `mutmap(m)` work the same way.
- **A new immutable `Map(K, V)` type** joins MutMap, with an interface as
  close to MutMap's as immutability allows.
- **One set of standard operations, by one name on every type:**
  - builtins: `fmap`, `foldl`, `foldr`, `filter`, `any`, `all`;
  - per-type libraries: `lib/list`, `lib/array`, `lib/dynarray`,
    `lib/map`, `lib/mutmap`, `lib/option` and `lib/result`, whose names
    are chosen from Haskell, OCaml and Rust.
- **`Option` and `Result`:**
  - Option is already builtin.
  - `Result(t, e)` joins it, Rust-like, with the constructors
    `Ok(value)` and `Error(error)` (not Rust's `Err`).

## 2. Decisions taken

Asked and answered before this plan was written (November 2026):

| # | Question | Decision |
|---|---|---|
| D1 | In what order does an immutable Map keep its keys? | **Insertion order**, as MutMap and Python do. Converting between Map and MutMap keeps it. |
| D2 | What do `fmap` and the other whole-collection functions do on a mutable collection? | They return a **new collection** of the same kind. Making an Array, DynArray or MutMap still needs `use mutation`. In-place versions get their own names. |
| D3 | Should one function work over any collection (a Haskell `Functor`)? | **No higher-kinded types.** `fmap` is resolved at each call by the type of collection it is given, as `len` is today. |
| D4 | Argument order | **Function first**, as in Haskell and OCaml: `fmap(f, xs)`, `filter(p, xs)`, `foldl(f, init, xs)`, `foldr(f, init, xs)`. |

Taken from the request itself:

- **Builtins:** `fmap`, `foldl` and `foldr` are builtins at least.
- **The constructors:** `list` / `list_init`, `dynarray` / `dynarray_init`,
  `map` / `map_init` and `mutmap` / `mutmap_init` follow the
  `array` / `array_init` pattern.
- **Conversions:** the constructors convert, so `list(array(...))`
  works.
- **Result:** the constructors are `Ok` and `Error`.

## 3. What exists today

**Types:**
- `[T]`: lists, immutable;
- `Array(T)`, `DynArray(T)` and `MutMap(K, V)`: mutable; making or
  writing one needs `use mutation`;
- `Slice(T)`: a view onto an array;
- `String`: of `Char`;
- `Option(a)`: lib/option, imported automatically into a module that
  uses it.

**The builtin overload sets** (`Builtin.overload_sets`) are told apart
only by how many arguments they take:

| Set | Members |
|---|---|
| `array` | `list::array`, `fill::array` |
| `array_init` | `init::array_init`, `unfold::array_init` |
| `dynarray` | `empty::dynarray`, `list::dynarray` |
| `mutmap` | `empty::mutmap`, `list::mutmap` |

**Builtins that already accept several collection kinds:**
- `len` takes a list, an array, a DynArray, a MutMap, a view or a String.
  The checker tests the argument's *kind*, not one fixed type
  (typesystem.ml, the `"len"` case).
- `remove`, `get`, `has`, `keys`, `values` and `items` decide between
  DynArray and MutMap the same way.
- **This is the mechanism `fmap` and the folds will build on.**

**Indexed-parameter inference:** an unannotated parameter used as `xs[i]`
gets its container kind (list, array, …) from the function's first
call, and defaults to a list when nothing decides. `fmap` reuses this
(§7.3).

**Libraries:**
- **lib/array:** `copy`, `to_list`, `fill`, `swap`, `reverse`, `concat`,
  `resize`, `equal`, `sort`;
- **lib/dynarray:** `copy`, `to_list`, `to_array`, `from_array`,
  `extend`, `reverse`, `equal`, `sort`;
- **lib/option:** `is_some`, `is_none`, `or_else`;
- **lib/text:** functions on Strings.

**What lists rely on instead:** lists have no library. Programs use
comprehensions and patterns, and many test programs define their own
`map`, `filter`, `fold`, `reverse` and `zip`.

**Names that yield:** `Builtin.yielding` lets a module's own definition
or import of a builtin's name win in that module (`get`, `push`, …).

**Equality:**
- `==` covers immutable values only.
- `==` on a type variable is refused for now, which is why lib/array has
  `int::equal`, `float::equal`, … and `equal_by`.

---

## 4. The collection types

| Type | Kind | Ordered | Indexable | Grows | `==` | Made by |
|---|---|---|---|---|---|---|
| `[T]` | immutable | yes | `xs[i]`, linear time | no (`+` copies) | structural | literal, `list`, `list_init`, comprehension |
| `Array(T)` | mutable, fixed size | yes | `a[i]`, constant | no | refused (`same`) | `array`, `array_init` |
| `DynArray(T)` | mutable | yes | `v[i]`, constant | `push` / `pop` / … | refused | `dynarray`, `dynarray_init` |
| `Slice(T)` | view on an array | yes | `w[i]` | no | refused | `view` |
| **`Map(K, V)`** (new) | immutable | insertion order | `m[k]` | `map.insert` gives a new Map | structural (§8.5) | `map`, `map_init` |
| `MutMap(K, V)` | mutable | insertion order | `d[k]` | `d[k] := v` | refused | `mutmap`, `mutmap_init` |
| `Option(T)` | immutable | – | – | – | structural | `Some(x)`, `None` |
| **`Result(T, E)`** (new) | immutable | – | – | – | structural | `Ok(x)`, `Error(e)` |
| `String` | immutable, of `Char` | yes | `s[i]` | no | structural | literal |

**Option and Result as containers:** they hold zero or one value, so
`fmap`, the folds, `filter` (Option only), `any` and `all` apply to them
as in Haskell's Functor/Foldable and Rust's `Option::map`.

**Strings are not collections for `fmap`:** a String holds only Chars,
so `fmap` could not change the element type. `list(s)` gives the Chars
as a list (§6), and lib/text keeps the String functions.

---

## 5. Making collections: one shape for every type

**The pattern:**
- `<type>(…)` makes a collection from a list or from one value, and
  converts from other collections.
- `<type>_init(…)` makes one by calling a function.

As today, the forms within one set differ in how many arguments they
take, so a call is never ambiguous on that count. The one-argument
conversion form is then picked by the argument's kind (§6).

### 5.1 Sequences: list, array, dynarray

| Call | Form | Makes | Gate |
|---|---|---|---|
| `list(xs)` | `conv::list` | a list of the elements of `xs`, any collection (§6); `list([1, 2])` is allowed and is `[1, 2]` | – |
| `list(n, v)` | `fill::list` | `n` copies of `v` (Haskell `replicate`, OCaml `List.init n (fun _ -> v)`, Rust `vec![v; n]`) | – |
| `list_init(n, f)`, `f: (Int) -> T` | `init::list_init` | element `i` is `f(i)` (OCaml `List.init`, Rust `(0..n).map(f)`) | – |
| `list_init(n, seed, f)`, `f: (S) -> (T, S)` | `unfold::list_init` | each element and the next seed from `f` | – |
| `array(xs)` | `conv::array` (replaces `list::array`) | from any sequence-like collection | `use mutation` |
| `array(n, v)` | `fill::array` | unchanged | `use mutation` |
| `array_init(n, f)` / `array_init(n, seed, f)` | unchanged | unchanged | `use mutation` |
| `dynarray()` | `empty::dynarray` | unchanged | `use mutation` |
| `dynarray(xs)` | `conv::dynarray` (replaces `list::dynarray`) | from any sequence-like collection | `use mutation` |
| `dynarray(n, v)` (new) | `fill::dynarray` | `n` copies of `v` | `use mutation` |
| `dynarray_init(n, f)` / `dynarray_init(n, seed, f)` (new) | `init::`, `unfold::dynarray_init` | as `array_init` | `use mutation` |

**The rules carry over from arrays unchanged:**
- `_init` calls `f` in index order, once per element.
- A negative `n` is a runtime error, everywhere but plain C.
- `list(3, f)` is a list of three copies of `f`; `list_init(3, f)` calls
  `f`.
- The `shared-fill` warning covers `list(n, v)` and `dynarray(n, v)`
  when `v` is mutable, as it covers `array(n, v)` today.

### 5.2 Maps: map, mutmap

The user asked for `map_init` alongside `map(pairs)`. A map has keys,
not a size, so the `_init` forms take what the keys come from:

| Call | Form | Makes | Gate |
|---|---|---|---|
| `map()` | `empty::map` | an empty Map; its types come from use or an annotation | – |
| `map(pairs)` | `conv::map` | from a list of `(key, value)` pairs, or from another Map or a MutMap (§6). A key written twice keeps its first place and its last value, as `mutmap` does today. | – |
| `map_init(keys, f)`, `keys: [K]`, `f: (K) -> V` | `init::map_init` | key `k` maps to `f(k)`, in the order of `keys` (Haskell `Map.fromSet`, Python `{k: f(k) for k in keys}`) | – |
| `map_init(n, seed, f)`, `f: (S) -> ((K, V), S)` | `unfold::map_init` | `n` entries unfolded from a seed, a later key replacing an earlier one's value | – |
| `mutmap()`, `mutmap(pairs)` | as today, `conv::mutmap` | also converts from a Map | `use mutation` |
| `mutmap_init(keys, f)` / `mutmap_init(n, seed, f)` (new) | as `map_init` | | `use mutation` |

**There is no fill form for maps:** one value under `n` keys needs the
keys, which is `map_init(keys, lam _. v)`.

**Alternatives for `map_init`:** see §12.4.

---

## 6. Conversions

The one-argument form of each constructor converts. Which collection the
argument is must be known at the call, either written or inferred (§7.3
covers parameters with no type).

| from \ to | `list(x)` | `array(x)` | `dynarray(x)` | `map(x)` | `mutmap(x)` |
|---|---|---|---|---|---|
| `[T]` | itself | copy | copy | needs `[(K, V)]` | needs `[(K, V)]` |
| `Array(T)` | elements | copy | copy | needs pairs | needs pairs |
| `DynArray(T)` | elements now | copy | copy | needs pairs | needs pairs |
| `Slice(T)` | elements | copy | copy | needs pairs | needs pairs |
| `String` | `[Char]` | `Array(Char)` | `DynArray(Char)` | – | – |
| `Map(K, V)` | `[(K, V)]` in order | `Array((K, V))` | `DynArray((K, V))` | itself | copy (thaw) |
| `MutMap(K, V)` | `[(K, V)]` in order | as Map | as Map | snapshot (freeze) | copy |
| `Option(T)` | `[]` or `[x]` | `[]`/`[x]` as an array | as an array | – | – |

**The rules:**
- **Every conversion copies:** nothing returned shares with its
  argument, so `array(a)` is a fresh array. That replaces
  `array.copy(a)`, which stays as a synonym.
- **Converting to a mutable collection needs `use mutation`**, as making
  one does.
- **To a map, the elements must be `(K, V)` pairs**, with `K` a key type.
  Otherwise the checker says what the element type is.
- **`list(s)` for a String** gives its Chars, as `text.chars(s)` does.
  The reverse is `text.from_chars`: `string(xs)` keeps meaning "the text
  `print` writes", so it is never a conversion of Chars.
- **Retirements:** `dynarray.to_list`, `dynarray.to_array`,
  `dynarray.from_array` and `array.to_list` become synonyms of the
  builtins. They are kept in their libraries, marked "same as
  `list(a)`", so no program breaks.

---

## 7. The builtin higher-order functions

### 7.1 The set

Six builtins, all function first (D4), all answering a new value (D2):

| Builtin | Type, per collection `C` | Haskell | OCaml | Rust |
|---|---|---|---|---|
| `fmap(f, c)` | `((A) -> B, C(A)) -> C(B)` | `fmap` | `List.map` | `.map` |
| `filter(p, c)` | `((A) -> Bool, C(A)) -> C(A)` | `filter` | `List.filter` | `.filter` |
| `foldl(f, init, c)` | `((B, A) -> B, B, C(A)) -> B` | `foldl` | `List.fold_left` | `.fold` |
| `foldr(f, init, c)` | `((A, B) -> B, B, C(A)) -> B` | `foldr` | `List.fold_right` (arguments in another order) | `.rfold` |
| `any(p, c)` | `((A) -> Bool, C(A)) -> Bool` | `any` | `List.exists` | `.any` |
| `all(p, c)` | `((A) -> Bool, C(A)) -> Bool` | `all` | `List.for_all` | `.all` |

```pyking
use mutation

xs = [1, 2, 3, 4]
print(fmap(lam x. x * 10, xs))                    # [10, 20, 30, 40]
print(filter(lam x. x % 2 == 0, xs))              # [2, 4]
print(foldl(lam (acc, x). acc - x, 0, xs))        # -10   ((((0-1)-2)-3)-4)
print(foldr(lam (x, acc). x - acc, 0, xs))        # -2    (1-(2-(3-(4-0))))
print(fmap(lam x. x + 1, array([1, 2])))          # array([2, 3])
print(fmap(lam x. string(x), Some(4)))            # Some("4")
ages = map([("ann", 31), ("bo", 5)])
print(filter(lam a. a > 18, ages))                # map([("ann", 31)])
print(all(lam x. x > 0, xs), any(lam x. x > 3, xs))   # true true
```

### 7.2 What each does, per collection

| Collection | `fmap` gives | `filter` gives | the folds, `any`, `all` walk |
|---|---|---|---|
| `[T]` | a list | a list | the elements, first to last |
| `Array(T)` | a new array (`use mutation`) | a new array, possibly shorter (`use mutation`) | the elements |
| `DynArray(T)` | a new DynArray (`use mutation`) | a new DynArray (`use mutation`) | the elements as they are at the call |
| `Slice(T)` | a new **array** (`use mutation`), as `w[1:]` is | a new array | the elements |
| `Map(K, V)` | a Map, the same keys in the same order, each value `f(v)` | a Map of the entries whose **value** passes | the **values**, in key order |
| `MutMap(K, V)` | a new MutMap (`use mutation`) | a new MutMap (`use mutation`) | the values |
| `Option(T)` | `Some(f(x))` or `None` | `Some(x)` if `p(x)`, else `None` | zero or one value |
| `Result(T, E)` | `Ok(f(x))`, or the same `Error(e)` | **refused**: there is no error to give when `p` fails (use `result.and_then`) | the `Ok` value, if any |
| `String` | refused: write `fmap(f, list(s))` | refused: write `list(s)` first | refused, with the same advice |

**Maps act on values,** as Haskell's `Functor (Map k)` and `Foldable`
do. lib/map has the `_with_key` versions (`map_with_key`,
`filter_with_key`, `fold_with_key`).

**This differs from `for k in m`,** which walks the keys, as Python's and
today's MutMap's does. The two are deliberately different. §12.6 has the
alternatives.

### 7.3 Typing and resolution

**The kind check:** each builtin is typed as `len` is. The checker reads
the kind of the collection argument (list, Array, DynArray, Slice, Map,
MutMap, Option, Result) and gives the result type for that kind. There
are no higher-kinded type variables (D3).

**When the kind is not yet known:**
- **An unannotated parameter** gets its kind from the function's first
  call, exactly as indexed-parameter inference does for `xs[i]`. So
  `def double_all(c): fmap(lam x. x * 2, c)` works when it is called as
  `double_all([1, 2])`.
- **A later call with another kind is an error** that names the first
  call: "`c` was fixed to a list by its first call, at line 3".
- **A function that is never called** defaults to a list.

This keeps D3: one definition serves one kind of collection. Its element
type stays generic.

**The function argument is checked after the collection, although it is
written first:**
- The lambda's parameter types come from the collection, so in
  `fmap(lam x. x.name, people)` the checker needs `people`'s type before
  it checks the lambda.
- The checker therefore checks these builtins' arguments in the order
  collection, then init, then function.
- **Evaluation order is unchanged:** at run time the arguments are still
  evaluated left to right, as PYKING.md "Evaluation order" says. Only the
  checking order changes.
- This is the cost of D4; Haskell gets it free from unification over
  curried types.

**Purity:** the order of the calls is part of the meaning, since `f` may
print:
- `fmap`, `filter`, `any` and `all` call `f` in the collection's order,
  each element once.
- `any` and `all` stop at the first answer that decides.
- `foldl` calls from the first element.
- `foldr` calls from the **last** element (it is strict, not lazy). On a
  long list every target loops without recursing, so `foldr` on a list
  of a million elements does not overflow the stack.

**Names a program defines itself:** `fmap`, `filter`, `foldl`, `foldr`,
`any`, `all`, `list`, `map`, `list_init`, `map_init`, `dynarray_init`
and `mutmap_init` are added to `Builtin.yielding`. The many test
programs and student programs that define their own `map` or `filter`
keep working, and their own definition wins in their module.

---

## 8. The immutable Map

### 8.1 The type

`Map(K, V)` is a builtin type like `MutMap(K, V)`:
- **Keys** are the same as MutMap's: the Key capability, hashed and
  compared; no Float, no function, nothing mutable.
- **Insertion order** is kept (D1).
- **Writing** is impossible: an update gives a new Map and leaves the
  old one as it was. That is cheap, because the two share almost
  everything (§8.6).

```pyking
import map

ages = map([("ann", 31), ("bo", 5)])
older = map.insert(ages, "cy", 40)
print(ages, older)        # map([("ann", 31), ("bo", 5)]) map([("ann", 31), ("bo", 5), ("cy", 40)])
print(older["cy"], get(older, "zed", 0), has(ages, "cy"), len(older))   # 40 0 false 3
```

### 8.2 Reading: shared with MutMap, builtin

| Call | Answers |
|---|---|
| `m[k]` | the value; a missing key is a runtime error, `the Map has no key "zed"` |
| `get(m, k, default)` | the value, or `default` |
| `has(m, k)` | whether there is an entry |
| `keys(m)`, `values(m)`, `items(m)` | lists, in order |
| `len(m)` | the number of entries |
| `for k in m`, comprehensions | the keys, in order |

These builtins accept a Map as well as a MutMap: the checker's
`mutmap_parts` case becomes "a Map or a MutMap". None of them needs
`use mutation`.

### 8.3 Changing: a new Map, from lib/map

The builtin writers (`remove`, `discard`, `clear`, `d[k] := v`) stay
MutMap-only. On a Map they are refused with "a Map is never changed:
`map.insert(m, k, v)` gives a new one".

**The updates are library functions,** qualified as `map.insert`,
`map.remove` and so on. They therefore never clash with the builtin
writers of the same name, which answer `()` and need `use mutation`.

- **Why not builtins:** a pure `insert` answering a Map next to a
  mutating `insert` answering `()` would be one name with two meanings.
- **Where the names come from:** `map.insert` is Haskell's and Rust's
  name, and `map.remove` is Rust's (Haskell's `delete`).
- **Alternatives:** §12.5.

### 8.4 Order

**Insertion order:**
- A new key goes at the end.
- Updating an existing key keeps its place.
- A removed key that is put back goes to the end.

These are MutMap's rules, so `mutmap(m)` and `map(d)` keep the order.

### 8.5 Equality, printing, hashing

- **`==`** compares the entries and **ignores order**: two Maps are equal
  when they have the same keys with equal values. This is Python's dict
  rule and Haskell's Map rule. It needs `V` to be comparable, as for
  lists.
- **Printing:** a Map prints as what makes it, `map([("ann", 31)])`, in
  insertion order. So two equal Maps may print differently, and the
  documentation says so.
- **A Map is a Key** when `K` and `V` are, so a Map may be a key of
  another Map. Its hash ignores order, matching `==`.

### 8.6 Representation

**One persistent structure on every target**, so that order, `==`,
hashing and costs agree everywhere:
- A hash array mapped trie (HAMT) maps each key to its value and its
  insertion number.
- A second persistent tree maps insertion numbers to keys, for walking
  in order.
- Lookup, insert and remove take O(log n), with a large base.
- Walking takes O(n).

**Where the code lives:**
- The structure is **written in Pyking**, in an internal module that the
  runtime imports, as lib/array's sort is. Every target then runs the
  same algorithm.
- It needs one new primitive, `hash(k)`, defined identically on every
  target for every Key type. That means FNV-style hashing over the
  printed structure, not each language's own hash, which differs
  between targets and runs.
- §12.7 has the alternatives: native dicts copied on write, or each
  language's own persistent maps.

**The Map type itself is builtin, not a library datatype,** so that:
- it prints as `map([...])`;
- `==` and Key work as described;
- the checker knows `Map(K, V)` for `m[k]`.

The interpreter and the backends wrap the Pyking-written structure in
that type.

---

## 9. Option and Result

### 9.1 Option

Unchanged as a type: `Option(a)` is `Some(value) | None`, imported
automatically from lib/option and shadowed by a module's own. lib/option
grows (§10.6).

### 9.2 Result

```pyking
public datatype Result(t, e):
    Ok(value: t)
    Error(error: e)
```

**Like Option:**
- lib/result declares Result, and it is imported automatically into a
  module that uses `Result`, `Ok` or `Error` without declaring its own.
- A module that declares its own `Result`, `Ok` or `Error` means its
  own. tests/adt_option.pyk, which has its own `Result` and `Ok`, keeps
  working.

**The constructor is `Error`, not Rust's `Err`,** as asked.
- `Error` is a common name for a datatype or constructor in user
  programs; the shadowing rule covers that.
- Neither the checker nor the runtime uses `Error` as a reserved word:
  runtime errors are not values.

**The error type is free.** By convention it is a String in the
examples, as Rust's `Result<T, String>` is in teaching code.

```pyking
import result

def parse_age(s: String) -> Result(Int, String):
    n = int(s)
    if string(n) == s and n >= 0 then Ok(n) else Error("not an age: " + s)

print(parse_age("31"), parse_age("x"))                 # Ok(31) Error("not an age: x")
print(fmap(lam n. n + 1, parse_age("31")))             # Ok(32)
print(result.and_then(parse_age("31"), lam n. if n < 150 then Ok(n) else Error("too old")))
print(result.unwrap_or(parse_age("x"), 0))             # 0
```

**On every target,** Result is an ordinary two-constructor datatype,
compiled as Option is.

---

## 10. The libraries, function by function

**The naming rule:**
1. Where Haskell, OCaml and Rust agree on a name, take it.
2. Where they differ, take the clearest to a beginner, preferring
   Haskell for list functions (the user's `fmap`, `foldl`, `foldr`) and
   Rust for Option and Result (the user's "like Rust").
3. Never use `_opt`-style suffixes: a function that may find nothing
   answers an `Option`.

**The same name means the same thing in every library:**
- `list.reverse`, `array.reverse` and `dynarray.reverse` all reverse.
- On a mutable collection the operations that rearrange elements —
  `reverse`, `sort`, `fill`, `swap`, `shuffle` — work **in place** and
  answer `()`. On a list they answer a new list. This matches today's
  lib/array, and Rust's `slice::sort` / `slice::reverse`.
- Where a mutable collection also wants a copying version, it is
  `sorted(a)` / `reversed(a)`, from Python.

**Equality and order on element types:** generic `==` and `<` on a type
variable are refused today (§3). So every function that compares
elements comes two ways:
- **overloads for the base types**, as lib/array's `int::sort` and
  `string::equal` are: Int, Float, String, Char, Bool;
- **a `_by` version** taking the comparison: `sort_by(xs, before)`,
  `contains_by(xs, x, alike)`.

When equality and order constraints are inferred (§15.2), the overloads
collapse into one generic definition each, and the `_by` versions stay.

In the tables below, the columns are: the Pyking name and type; Haskell;
OCaml; Rust. `T`, `U` and `S` are type variables; `p` is a predicate;
`f` is a function.

### 10.1 lib/list (new)

**Access**

| Pyking | Haskell | OCaml | Rust |
|---|---|---|---|
| `first(xs) -> Option(T)` | `listToMaybe` | `List.nth_opt xs 0` | `first` |
| `last(xs) -> Option(T)` | `last` (partial) | – | `last` |
| `nth(xs, i) -> Option(T)` | `!?` | `List.nth_opt` | `get` |
| `rest(xs) -> [T]` (empty for `[]`) | `drop 1` | `List.tl` (partial) | `[1..]` |
| `is_empty(xs) -> Bool` | `null` | `= []` | `is_empty` |

**Building and reshaping**

| Pyking | Haskell | OCaml | Rust |
|---|---|---|---|
| `reverse(xs)` | `reverse` | `List.rev` | `rev` |
| `flatten(xss: [[T]]) -> [T]` | `concat` | `List.concat` | `flatten` |
| `flat_map(f, xs)` | `concatMap` | `List.concat_map` | `flat_map` |
| `zip(xs, ys) -> [(T, U)]` | `zip` | `List.combine` (raises) | `zip` |
| `unzip(ps) -> ([T], [U])` | `unzip` | `List.split` | `unzip` |
| `zip_with(f, xs, ys)` | `zipWith` | `List.map2` (raises) | `zip().map()` |
| `enumerate(xs) -> [(Int, T)]` | `zip [0..]` | `List.mapi` | `enumerate` |
| `intersperse(x, xs)` | `intersperse` | – | `intersperse` |
| `chunks(n, xs) -> [[T]]` | `chunksOf` (split pkg) | – | `chunks` |
| `windows(n, xs) -> [[T]]` | – | – | `windows` |
| `scanl(f, init, xs)` | `scanl` | – | `scan` (differs) |
| `scanr(f, init, xs)` | `scanr` | – | – |
| `unfold(seed, f: (S) -> Option((T, S)))` | `unfoldr` | `Seq.unfold` | `successors`/`from_fn` |

**Taking parts**

| Pyking | Haskell | OCaml | Rust |
|---|---|---|---|
| `take(n, xs)` / `drop(n, xs)` | `take` / `drop` | `List.take` / `drop` (5.3) | `take` / `skip` |
| `take_while(p, xs)` / `drop_while(p, xs)` | `takeWhile` / `dropWhile` | `take_while` / `drop_while` | `take_while` / `skip_while` |
| `split_at(n, xs) -> ([T], [T])` | `splitAt` | – | `split_at` |
| `span(p, xs) -> ([T], [T])` | `span` | – | – |
| `partition(p, xs) -> ([T], [T])` | `partition` | `List.partition` | `partition` |

**Searching and counting**

| Pyking | Haskell | OCaml | Rust |
|---|---|---|---|
| `find(p, xs) -> Option(T)` | `find` | `List.find_opt` | `find` |
| `find_index(p, xs) -> Option(Int)` | `findIndex` | `List.find_index` | `position` |
| `count(p, xs) -> Int` | `length . filter` | – | `filter().count()` |
| `reduce(f, xs) -> Option(T)` | `foldl1` (partial) | – | `reduce` |
| `contains(x, xs)` (base-type overloads), `contains_by(alike, x, xs)` | `elem` | `List.mem` | `contains` |
| `index_of(x, xs) -> Option(Int)` (overloads), `index_of_by` | `elemIndex` | – | `position(==)` |
| `unique(xs)` (overloads; keeps first occurrences), `unique_by` | `nub` | `sort_uniq` (sorts) | `dedup` (adjacent only) |
| `group(xs) -> [[T]]` (adjacent runs; overloads), `group_by` | `group` / `groupBy` | – | `chunk_by` |

**Numbers and order**

| Pyking | Haskell | OCaml | Rust |
|---|---|---|---|
| `sum(xs)`, `product(xs)` (Int and Float overloads) | `sum` / `product` | – | `sum` / `product` |
| `maximum(xs) -> Option(T)`, `minimum` (overloads), `maximum_by(before, xs)` | `maximum` (partial) | – | `max` / `min` |
| `sort(xs)` (stable; overloads), `sort_by(before, xs)`, `sort_on(key, xs)` | `sort` / `sortBy` / `sortOn` | `List.sort` | `sort` / `sort_by` / `sort_by_key` |

**Comparing lists**

| Pyking | Haskell | OCaml | Rust |
|---|---|---|---|
| `equal_by(alike, xs, ys)` | – | `List.equal` | `eq_by` |

**Kept out of lib/list:**
- `length` (`len` is builtin) and `map` (`fmap` is builtin).
- `append` (`+` joins lists) and `replicate` (`list(n, v)`).
- `for_each` (a `for` loop does that).
- `head` and `tail`: `first` and `rest` never fail.

**Argument order:** function first (D4) everywhere a function is given.
Where a count or a value is the configuration, it also comes first:
`take(n, xs)`, `contains(x, xs)`. The collection comes last throughout,
as in Haskell, so §15.6's `|>` would read naturally.

### 10.2 lib/array (extended)

**Kept:** `copy` (now the same as `array(a)`), `to_list`, `fill`,
`swap`, `reverse` (in place), `concat`, `resize`, `equal`, `sort` (in
place).

**Added, with lib/list's meaning:**
- `first`, `last`, `nth` and `is_empty`;
- `find`, `find_index`, `count`, `contains`, `index_of`;
- `sum`, `product`, `maximum`, `minimum`;
- `sort_by`, `sort_on` (both in place);
- `zip`, `enumerate`, `reduce` and `flat_map`, each answering a new
  array.

**Added for arrays only:**
- `sorted(a)` and `reversed(a)`: new arrays.
- `map_in_place(f, a)`: `f: (T) -> T`, in place. This is the in-place
  `fmap` of D2 (OCaml `Array.map_inplace`, Rust `iter_mut`).
- `shuffle(a)` needs lib/random, so it lives there as
  `random.shuffle`.

Every function that makes an array needs `use mutation` in the calling
module; reading functions do not.

### 10.3 lib/dynarray (extended)

**Kept:** `copy`, `to_list`, `to_array`, `from_array` (the last three now
synonyms of the conversions), `extend`, `reverse`, `equal`, `sort`.

**Added:**
- the same functions as lib/array adds;
- `truncate(v, n)` (Rust `truncate`);
- `retain(p, v)`, an in-place `filter` (Rust `retain`);
- `append(v, w)`, which pushes all of `w` (Rust `append`).

### 10.4 lib/map (new)

All pure. Each answers a new Map, or a value; none needs `use mutation`.

**Changing (each gives a new Map)**

| Pyking | Haskell (`Data.Map`) | OCaml (`Map`) | Rust (`HashMap`) |
|---|---|---|---|
| `insert(m, k, v) -> Map` | `insert` | `add` | `insert` |
| `remove(m, k) -> Map` (no error when absent) | `delete` | `remove` | `remove` |
| `insert_with(f, m, k, v)`: `f(old, v)` where `k` is there | `insertWith` | `update` | `entry().and_modify()` |
| `adjust(f, m, k)`: `f` on `k`'s value where there is one | `adjust` | `update` | `get_mut` |
| `alter(f, m, k)`, `f: (Option(V)) -> Option(V)` | `alter` | `update` | `entry` |
| `union(m1, m2)` (left wins), `union_with(f, m1, m2)` | `union` / `unionWith` | `union` | `extend` |
| `intersection(m1, m2)`, `difference(m1, m2)` | `intersection` / `difference` | – | – |
| `map_with_key(f, m)`, `f: (K, V) -> U` | `mapWithKey` | `mapi` | `iter().map()` |
| `filter_with_key(p, m)` | `filterWithKey` | `filter` | `retain` (in place) |
| `partition(p, m) -> (Map, Map)` | `partition` | `partition` | – |
| `singleton(k, v)` | `singleton` | `singleton` | – |

**Reading (each gives a value)**

| Pyking | Haskell (`Data.Map`) | OCaml (`Map`) | Rust (`HashMap`) |
|---|---|---|---|
| `lookup(m, k) -> Option(V)` | `lookup` | `find_opt` | `get` |
| `fold_with_key(f, init, m)`, `f: (B, K, V) -> B` | `foldlWithKey` | `fold` | `iter().fold()` |
| `find_key(p, m) -> Option(K)` | – | `find_first_opt` | `iter().find()` |
| `is_empty(m)` | `null` | `is_empty` | `is_empty` |
| `equal_by(alike, m1, m2)` | – | `equal` | – |

**Builtins cover the rest:** `m[k]`, `get`, `has`, `keys`, `values`,
`items`, `len`, the conversions, and `fmap`, `filter` and the folds on
values.

### 10.5 lib/mutmap (new)

**In place, needing `use mutation`:**
- `update(f, d, k)`: `f` on `k`'s value where there is one.
- `insert_with(f, d, k, v)`: for counting,
  `mutmap.insert_with(lam (a, b). a + b, counts, w, 1)`.
- `extend(d, pairs)`.
- `retain(p, d)`: filter in place.

**Pure, reading:** `lookup(d, k) -> Option(V)`, `fold_with_key`,
`find_key`, `is_empty` and `equal_by`.

**Copying:** `copy(d)`, the same as `mutmap(d)`.

### 10.6 lib/option (extended)

Rust names, as asked.

| Pyking | Rust | Haskell | OCaml |
|---|---|---|---|
| `is_some(o)`, `is_none(o)` (kept) | same | `isJust` / `isNothing` | `is_some` / `is_none` |
| `unwrap_or(o, default)` | `unwrap_or` | `fromMaybe` | `value ~default` |
| `unwrap_or_else(o, f: () -> T)` | `unwrap_or_else` | `maybe` | – |
| `and_then(o, f: (T) -> Option(U))` | `and_then` | `>>=` | `bind` |
| `or_else(o, f: () -> Option(T))` | `or_else` | `<\|>` | – |
| `ok_or(o, e) -> Result(T, E)` | `ok_or` | `maybe (Left e) Right` | `to_result ~none` |
| `zip(o1, o2) -> Option((T, U))` | `zip` | `liftA2 (,)` | – |
| `flatten(oo)` | `flatten` | `join` | `join` |
| `unwrap(o)` (runtime error on `None`), `expect(o, message)` | same | `fromJust` | `get` |
| `all_some(os: [Option(T)]) -> Option([T])` | `collect` | `sequence` | – |
| `values(os: [Option(T)]) -> [T]` (drops the `None`s) | `flatten` | `catMaybes` | `filter_map` |

**`or_else` changes meaning:**
- Today's `option.or_else(o, default)` is Rust's `unwrap_or`. Rust's
  `or_else` takes a function, and following Rust means `or_else` must
  too.
- **Recommendation:** rename today's `or_else` to `unwrap_or`, and give
  `or_else` Rust's meaning.
- An old call `or_else(o, 0)` then fails to compile, since 0 is not a
  function, and the message suggests `unwrap_or`.
- §12.8 has the alternative of keeping it.

**Rust's `map`, `filter` and `iter` are the builtins** `fmap`, `filter`
and the folds. **Rust's `or`** cannot be a name, since `or` is a keyword;
`or_else(o, lam (). other)` does that job.

### 10.7 lib/result (new)

| Pyking | Rust | Haskell (`Either`) |
|---|---|---|
| `is_ok(r)`, `is_error(r)` | `is_ok` / `is_err` | `isRight` / `isLeft` |
| `ok(r) -> Option(T)`, `error(r) -> Option(E)` | `ok` / `err` | – |
| `unwrap_or(r, default)`, `unwrap_or_else(r, f: (E) -> T)` | same | `fromRight` / `either` |
| `and_then(r, f: (T) -> Result(U, E))` | `and_then` | `>>=` |
| `or_else(r, f: (E) -> Result(T, F))` | `or_else` | – |
| `map_error(f, r)` | `map_err` | `first` (Bifunctor) |
| `unwrap(r)`, `expect(r, message)`, `unwrap_error(r)` | same | – |
| `flatten(rr)` | `flatten` | `join` |
| `all_ok(rs: [Result(T, E)]) -> Result([T], E)` (the first error) | `collect` | `sequence` |
| `partition_results(rs) -> ([T], [E])` | – | `partitionEithers` |

**`map_error` takes its function first, like `fmap`,** although
`and_then` takes it second, as Rust's method chains read. §12.3 says
why.

---

## 11. Builtin or library: the rule and the verdicts

**A name is builtin when all four of these hold:**
1. **It means the same thing on every collection kind.** A builtin can
   take every kind under one unqualified name; a library function is
   reached as `list.f`, `array.f`, …, one per module.
2. **It is in daily use from the first lessons.** A qualified name or an
   `import` line is a real cost in every small program.
3. **It needs the checker's help:** a kind-dependent result type, or the
   collection-first checking order (§7.3).
4. **It is unlikely to clash badly.** Where it does clash, it yields to a
   program's own definition (§7.3).

Everything else is library code, written in Pyking where possible, so
that every target runs the same code.

**Verdicts:**

| Name | Verdict | Why |
|---|---|---|
| `fmap`, `foldl`, `foldr` | **builtin** | asked for; every kind; result type depends on the kind |
| `filter`, `any`, `all` | **builtin** | every kind; as common as `fmap`; `filter` needs the kind-dependent result |
| `list`, `list_init`, `map`, `map_init`, `dynarray_init`, `mutmap_init` | **builtin** | constructors, like `array`; the conversion form needs the kind check |
| `len`, `get`, `has`, `keys`, `values`, `items` | builtin (exist) | extended to Map |
| `flat_map` | library, per module | common, but its meaning differs: on Option it is `and_then` |
| `zip`, `enumerate`, `reverse`, `sort`, `sum`, `find`, `take`, `drop`, … | library | not meaningful on every kind (Map, Option), or comparison-dependent |
| `contains`, `unique`, `maximum`, `sort` | library | need `==` or `<` on elements: overloads per base type (§10) |
| Map updates (`insert`, `remove`, …) | library (`map.insert`) | would clash with the mutating builtins of the same names |
| Option / Result helpers | library | type-specific; Rust's names read best qualified (`result.and_then`) |
| `hash` | internal primitive | needed by Map; whether to expose it is §16 Q5 |
| `is_empty` | library, per module | `len(c) == 0` is enough to make builtin unnecessary |

**Summary:**
- 6 new higher-order builtins: `fmap`, `filter`, `foldl`, `foldr`,
  `any`, `all`.
- 6 new constructor sets: `list`, `list_init`, `map`, `map_init`,
  `dynarray_init`, `mutmap_init`.
- New forms of existing sets:
  - `array`, `dynarray` and `mutmap` gain the conversion form;
  - `dynarray` gains `dynarray(n, v)`.
- The reading builtins extended to Map.
- Everything else goes in seven libraries.

---

## 12. Alternatives considered

### 12.1 Generic `fmap` through higher-kinded types (rejected by D3)

**What it is:** add type variables of kind `* -> *` and a
`Functor` / `Foldable` capability, as Haskell's classes or OCaml's
functors.

**Pros:**
- One `double_all` serves every collection.
- The laws are stated once.
- Haskell students meet the real thing.

**Cons:**
- A new kind system in the checker.
- Dictionary passing in Java, C and OCaml.
- Error messages about kinds, which are hard for beginners.
- A large change across all 23 targets.

**Status:** possible later, on top of §15.2's constraints. Kind-based
resolution does not block it.

### 12.2 A distinct name per collection: `list_map`, `array_map`, … (rejected)

**Pros:** no checker work, and the names say what they do.

**Cons:** the request is one `fmap` for everything, and the names
multiply by seven.

### 12.3 Argument order (decided by D4)

**Collection first** (`fmap(xs, f)`, Rust and Python methods):
- **Pros:** reads like `xs.map(f)`; the lambda comes last, which reads
  well over several lines; the checker sees the collection first.
- **Cons:** not Haskell; with function first, `fmap(f)` could later be
  partially applied.

**Decision:** function first, with the checker reordering how it checks
(§7.3).

**The Option and Result helpers keep Rust's order** (`and_then(o, f)`),
since they are Rust's functions. `map_error(f, r)` follows `fmap`,
because it is a map.

### 12.4 What `map_init` takes

- **A. Keys and a function, `map_init(keys, f)` (recommended).** It is
  the useful one: a table from a list of names. Haskell has
  `fromSet f keys`.
- **B. A size and a function giving pairs, `map_init(n, f)` with
  `f: (Int) -> (K, V)`.** This mirrors `array_init` exactly. But a key
  produced twice silently shrinks the map, and it is rarely what a
  program wants.
- **C. Only the unfold form.** Too indirect for the common case.

**Recommendation:** A, plus the unfold form, for the symmetry with
`array_init`'s two forms.

### 12.5 How a Map is updated

- **A. Library functions, `map.insert(m, k, v)` (recommended).** There is
  no clash with the mutating builtins, and the module name says it is
  the immutable one.
- **B. Builtin `insert` / `remove` that answer a new Map when given a
  Map.** Shorter. But one name would answer `()` for a MutMap and a Map
  for a Map, and a forgotten `m2 = …` loses the update silently. The
  checker could warn about an unused Map result.
- **C. Syntax: `m with [k: v]`, like the struct update `..e`.**
  Readable, but it is new syntax for one type.
- **D. Different builtin names: `put(m, k, v)` and `without(m, k)`.**
  Unqualified, and they clash with nothing today. They are new words
  that no source language uses.

### 12.6 What a Map's elements are for `fmap` and the folds

- **A. The values (recommended; Haskell).** `fmap` keeps the keys, which
  a Functor must, and `filter` keeps the Map a Map.
- **B. The `(key, value)` pairs (Rust's `iter()`).** Folds see both, but
  `fmap` then gives a list of something, not a Map, which breaks
  `fmap`'s "same kind out".
- **C. The keys (Python's iteration).** It matches `for k in m`, but
  `fmap` over keys is not a Map either.

**Recommendation:** A. `for`/comprehensions stay on keys; documentation
and hover text make the difference explicit.

### 12.7 Representing a Map

- **A. One Pyking-written HAMT plus an order tree, with a defined
  `hash` (recommended).** Identical behaviour and costs everywhere. It
  is more code to write once, and a little slower than native
  structures.
- **B. A native dict or HashMap, copied on every update.** Trivial to
  write. But an update takes O(n), so building a Map in a loop is
  quadratic, which is the trap the array costs paragraph warns about.
- **C. Each language's own persistent map:** OCaml `Map` (sorted, needs
  `compare`), Java (none in the JDK), JS (none), Python (none). There is
  no common ground, and orders would differ.
- **D. A sorted balanced tree, keys ordered by a defined `compare`.**
  That gives up insertion order (D1).

### 12.8 Today's `option.or_else`

- **A. Rename it to `unwrap_or` and give `or_else` Rust's meaning
  (recommended).** It follows Rust, as asked, and old calls fail to
  compile with a hint.
- **B. Keep `or_else(o, default)`** and name Rust's `or_else` something
  else (`or_try`). There is no breaking change. But a Rust reader
  expects otherwise, and the request says "like Rust".

### 12.9 Builtin `fmap` on `String`

- **A. Refused, suggesting `list(s)` (recommended).**
- **B. `fmap(f: (Char) -> Char, s) -> String`**, a String-to-String map.
  Handy, but `fmap` could then not change the element type, which
  breaks the Functor shape.
- **C. Gives a `[U]`.** That breaks "same kind out".

---

## 13. Implementation, across the system

CLAUDE.md: every part that sees the change is updated, and every feature
has tests on every target it runs on.

**The compiler**

- **builtin.ml:**
  - new entries `fmap`, `filter`, `foldl`, `foldr`, `any`, `all`, each
    with a hover doc;
  - the new overload sets (`list`, `list_init`, `map`, `map_init`,
    `dynarray_init`, `mutmap_init`) and the new forms of `array`,
    `dynarray` and `mutmap`;
  - `yielding` extended;
  - `writers` unchanged.
- **lexer and parser:** none; these are ordinary calls. The auto-import
  of `Result` / `Ok` / `Error` goes next to Option's
  (parser.ml:3796).
- **typesystem.ml:**
  - the `Map` type;
  - the kind cases for the new builtins, modelled on `len`, including
    the collection-first checking order;
  - the conversion form's kind dispatch;
  - `mutmap_parts` widened to Map for the readers;
  - refusals with their messages: a writer on a Map, `filter` on a
    Result, `fmap` on a String, a conversion to a map from non-pairs;
  - Key for Map;
  - `==` on Map (order-free);
  - first-call kind fixing for the new builtins, as indexed-parameter
    inference does.
- **elaborate.ml:** a resolved call names its member's plain name
  (`list__fmap`, `array__fmap`, …), as the overload sets do today.
- **interpreter.ml:**
  - a value for Map (`VMap`, wrapping the Pyking-written structure or a
    native one; the interpreter may use OCaml's own structures provided
    the order and equality rules hold);
  - each new builtin, its printing, and `for` over a Map.
- **warnings.ml:** `shared-fill` covers `list(n, v)` and
  `dynarray(n, v)`.

**The backends:** each implements the member names.
- **Python:** comprehensions and `functools.reduce`; the Map runtime
  class.
- **JS:** `Array.prototype.map` / `filter` / `reduce` / `reduceRight`;
  the Map runtime class.
- **Java:** generic static methods in `PykRuntime`.
- **OCaml:** `List.map`, `List.fold_left`, and `List.fold_right` written
  as a loop over the reversed list.
- **C, both kinds:** runtime functions over the target's closures and
  lists.
- **Plain C:** the no-collector subset decides which of these it keeps.
  Lists and closures already exist there; a Map allocates and never
  frees, as everything else in plain C does.

**The libraries:**
- new: lib/list, lib/map, lib/mutmap, lib/result;
- extended: lib/array, lib/dynarray, lib/option;
- written in Pyking, with `##` docs and examples that the help generator
  and the site's runnable cells check;
- the internal Map module, with its `hash` primitive in every target's
  runtime.

**The tools**

- **REPL:** printing a Map; auto-imports of Result.
- **LSP:**
  - completion and hover for the new builtins and the library
    functions;
  - semantic tokens for the builtin words (`Builtin.words`);
  - the signature help of a builtin shows the per-kind types.
- **DAP:** the Variables view shows a Map as its entries, as for MutMap.
- **Playground:** the word list (from `Builtin.words`), and examples.
- **Notebook:** a chapter on collections, `fmap` and the folds.
- **Editor grammars:** the new builtin words, in VS Code
  (`pyking.tmLanguage.json`) and Emacs (`pyking-mode.el`).
- **Help pages:** generated from the libraries.

**The documentation:**
- **PYKING.md:**
  - new sections "Maps (`Map(K, V)`)", "Collections: making and
    converting", "fmap and the folds" and "Result";
  - the Arrays, DynArrays and MutMaps sections pointing at them;
  - the "Static overloading" exceptions list updated;
  - the feature summary and grammar notes.
- **docs/:** `builtin.md`, `type_inference.md` (the kind-resolved
  builtins and the checking order), and each `target_*.md` (how Map and
  the builtins are compiled).
- **CHANGELOG.md:** under Unreleased.

**Tests:**
- **Program tests on every target:** each constructor form, each
  conversion in §6's table, each builtin on each kind, Map semantics
  (order, `==`, Key, printing, the update functions), Result and the new
  Option functions, each library function, and `yielding` (programs
  defining their own `map` and `filter`).
- **`fail_*` cases for every refusal:**
  - writers on a Map;
  - `filter` on a Result;
  - `fmap` on a String;
  - non-pair conversion to a map;
  - a mutable conversion without `use mutation`;
  - a kind disagreement between calls;
  - an undecidable kind;
  - a non-key Map key;
  - the old `or_else(o, value)`.
- **Tools:** LSP completion and hover, REPL transcripts, DAP variables,
  and the help and site cells.
- **Examples:** tests that define their own `map`, `filter`, `fold`,
  `reverse` or `zip` keep theirs. Example programs in `essentials/`,
  `web_examples/` and `src/examples.toml` that would read better with
  the builtins are updated as part of the change.

---

## 14. Phases

Each phase is finished completely, tests and docs included, before the
next starts.

1. **Kind-resolved builtins.** The checker mechanism (§7.3) and the
   member naming, proven on `list(xs)` conversions and the `list` /
   `list_init` constructors.
2. **The constructors and conversions** for list, array and dynarray:
   §5.1 and §6 without the maps.
3. **`fmap`, `filter`, `foldl`, `foldr`, `any`, `all`** on lists,
   Arrays, DynArrays, Slices and Option.
4. **Result,** lib/result, the lib/option extension and the `or_else`
   rename. The builtins are extended to Result.
5. **Map:** the type, its representation and `hash`, the readers, `for`,
   printing, `==` and Key, the constructors and conversions (§5.2), and
   the builtins on Map and MutMap. Then lib/map and lib/mutmap.
6. **lib/list** and the lib/array and lib/dynarray extensions.
7. **Tools sweep:** notebook chapter, playground examples, editor
   grammars, and the help pages, checked end to end.

---

## 15. What is missing

Things the request does not mention that a collections design usually
needs, with a recommendation for each.

### 15.1 Sets: `Set(T)` and `MutSet(T)`

**What is missing:** the obvious companions of Map and MutMap.
- Constructors: `set(xs)`, `set_init`, `mutset(...)`.
- Builtins: `has`, `len`, `for`, `fmap`, `filter`, the folds.
- lib/set: `insert`, `remove`, `union`, `intersection`, `difference`,
  `is_subset`.

**Recommendation:** next after Map. The representation is the same as
Map's, with `()` values.

### 15.2 Equality and order constraints

**What is missing:** generic `==` and `<` on a type variable are refused
today. That forces the base-type overloads and `_by` versions
throughout §10.

**What it would take:** a small constraint system, `Eq` and `Ord` on
type variables, inferred and passed as hidden implicits (Pyking already
has implicits). Then `contains`, `unique`, `sort` and `maximum` are each
one definition.

**Recommendation:** the most valuable follow-up. It is also the
foundation §12.1 would need.

### 15.3 A propagation operator for Option and Result

**What is missing:** Rust's `?`, `let n = parse(s)?`, which returns the
`Error` early.

**Recommendation:** worth having once Result exists, perhaps spelled
`try e` to avoid a symbol. It is a statement-level rewrite into a
`match` with `return`.

### 15.4 Membership: `x in xs`

**What is missing:** Python's `in` as an expression. Pyking has `in`
only in `for`.

**Recommendation:** `x in c` for every collection: a key for maps, an
element for sequences, a substring for Strings. It needs §15.2 for
generic elements; until then base types and keys.

### 15.5 An immutable indexed sequence

**What is missing:** lists are linked, so `xs[i]` takes linear time,
while Arrays are mutable.

**Recommendation:** a persistent `Vector(T)`, like Haskell's `Data.Vector`
or a Clojure/Scala vector, with constant-ish indexing and cheap
`vector.set`. Later; Map's HAMT technique carries over.

### 15.6 A pipeline operator

**What is missing:** with function-first order (D4), chains nest:
`foldl(f, 0, filter(p, fmap(g, xs)))`.

**Recommendation:**
- OCaml/F#'s `|>` reads left to right:
  `xs |> fmap(g) |> filter(p) |> foldl(f, 0)`.
- `x |> f(a)` means `f(a, x)`, which works precisely because the
  collection is the last argument.
- It is a small parser rewrite, and a strong argument for D4.

### 15.7 Function combinators

**What is missing:** Haskell's `id`, `const`, `flip`, `compose` (`.`),
`curry` and `uncurry`.

**Recommendation:** a small lib/function. `compose` is useful with
`fmap`.

### 15.8 Iterators and laziness

**What is missing:**
- `range(n)` builds a list today.
- `fmap` over a big range allocates the whole range first.
- Rust's iterators, Python's generators and Haskell's laziness avoid
  that.

**Recommendation:** not now; strict collections are simpler to teach
and to compile to C. Revisit if programs need streams (`take(5, …)` of
an infinite sequence).

### 15.9 Queues, stacks, heaps

**What is missing:** a DynArray is a stack, but there is no queue,
deque or priority queue (Rust `VecDeque` / `BinaryHeap`, Python
`collections.deque` / `heapq`).

**Recommendation:** lib/queue and lib/heap, written in Pyking, once
§15.2 lets a heap order its elements generically.

### 15.10 Strings as collections

**What is missing:** `fmap` and the folds refuse Strings (§12.9).

**Recommendation:**
- lib/text gains `map_chars(f, s)` and `filter_chars(p, s)`, so common
  String work need not go through `list(s)`.
- A `string_init(n, f)` would complete the constructor pattern.

### 15.11 Methods under `use objects`

**What is missing:** with classes, students may expect `xs.fmap(f)`.

**Recommendation:** not for builtin collections, which are not objects.
The `|>` operator of §15.6 gives the same reading order without it.

### 15.12 Pattern matching on the new types

**What is missing:** lists have patterns; Arrays, Maps and DynArrays do
not.

**Recommendation:** keep it that way. Matching on Option and Result
already works, since they are datatypes.

### 15.13 Conversions to String and from String

**What is missing:** `string(xs)` prints, `text.from_chars` builds.

**Recommendation:** add `text.join_chars` as a synonym, if lessons show
that students reach for `string(chars)`.

### 15.14 A sorted map

**What is missing:** D1 chose insertion order, but ordered traversal by
key — ranges, the smallest key — is sometimes needed (Rust's `BTreeMap`,
Haskell's `Data.Map`).

**Recommendation:** `map.sorted_keys(m)` covers most uses. A
`SortedMap(K, V)` comes after §15.2.

---

## 16. Open questions

Recommendations stand unless the user says otherwise.

| # | Question | Recommendation | Where |
|---|---|---|---|
| Q1 | What do `map_init`'s forms take? | keys and a function, plus an unfold form | §12.4 |
| Q2 | How is a Map updated? | lib/map functions (`map.insert`) | §12.5 |
| Q3 | Do `fmap` and the folds see a Map's values, pairs or keys? | values | §12.6 |
| Q4 | How is a Map represented? | one Pyking-written HAMT and order tree, with a defined `hash` | §12.7 |
| Q5 | Is `hash` exposed to programs? | not at first: it is internal, used by Map; expose it with Sets if they need it | §8.6 |
| Q6 | Rename `option.or_else` to `unwrap_or`? | yes | §12.8 |
| Q7 | `fmap` on a String? | refused, suggesting `list(s)` | §12.9 |
| Q8 | Do `unwrap` / `expect` belong in a teaching language? | yes, as in Rust, with the runtime error naming the call | §10.6, §10.7 |
| Q9 | Which of §15 come next? | §15.2 (Eq/Ord), then §15.1 (Sets) and §15.6 (`\|>`) | §15 |
