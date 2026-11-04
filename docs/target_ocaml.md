# The OCaml target

**Targets in this family:** `ocaml4.14`, `ocaml`.

**Key points**

- One backend, `src/target_ocaml.ml`. It is the only one whose supported
  subset is not a list of constructs but a *stage*: it compiles exactly
  what `src/typesystem.ml` accepts, and it compiles it by **running the
  type checker** and reading the types back out. There is no inference of
  its own.
- OCaml fits Pyking better than any other target here. A block is a
  scope in both languages, a rebinding is a new binding in both, `true` /
  `false` / `()` are spelled the same in both, and Pyking's rule that
  every `def` in a block is visible throughout it *is* `let rec … and …`.
- **The generated code carries no type annotations.** OCaml infers them,
  and they were already checked before a line was emitted.
- Output is one `.ml` file with no dependencies beyond the OCaml
  standard library, and no prelude at all unless the program prints a
  list.
- Least optimal at: `range`, which builds a list where OCaml would
  iterate.

Verified with `ocamlopt -w +a`, every warning on: the target's
promise is clean OCaml, so a warning is a failing test rather than a
note. See "What the compiler would have said" below.

## What is supported

Nearly all of the fragment `src/typesystem.ml` checks. The list this
backend maintains is the short one of what it *refuses*, in the next
section; everything else compiles:

- `print`, and the builtins `string`, `len`, `float`, `int`, `bool`,
  `char` and `range`;
- `def`, annotated or not — recursion, mutual recursion, nested
  functions, and a body written on the header's own line (`def f(x): e`);
- functions as values: passed as arguments, returned, and called;
- `=` bindings, including ones that shadow;
- `var` and `:=`, as OCaml `ref` cells;
- `if` / `else if` / `else`, in statement form and in value form
  (`x = if c:`), and `if … then … else …` expressions;
- `loop` with `break` and `continue`, in every position a value stands,
  and its `for`/`while` clauses;
- `match` / `case`, including list and text patterns;
- lists and list comprehensions;
- arrays: `array(...)` in its four forms, `a[i]`, `a[i] := v`, `len`,
  `same`, `for` and comprehensions over one, as OCaml's own `array`
  (see "Arrays");
- pointers: `&` of a `var`, an array's or a view's element, a var
  struct's field, or `*p`; `*p`, `*p := v`, `==` by place, printing
  (see "Pointers");
- slices `s[i:j]` of lists, Strings, arrays, DynArrays and views; views
  (`view(a, i, j)`, `Slice(T)`) and `copy_into` (see "Slices and
  views");
- MutMaps: `mutmap(...)`, `d[k]`, `d[k] := v`, `get`, `has`, `keys`,
  `values`, `items`, `remove`, `discard`, `clear`, `len`, `same`, `for`
  and comprehensions (see "MutMaps");
- DynArrays: `dynarray(...)`, `push`, `pop`, `insert`, `remove`, `clear`,
  `v[i]`, `v[i] := x`, `len`, `same`, `for` and comprehensions (see
  "DynArrays");
- `var struct`s: fields written with `:=` and the compound operators,
  values shared by reference, `same`, and cycles printed with `...`
  (see "Var structs");
- tuples, including a binding that takes one apart;
- `return`, anywhere it can be written;
- lambdas (`lam x. x + 1`);
- integers, floats, strings, characters and booleans; `+ - * / % ^`,
  unary minus, comparisons, `==` and `!=` (on every type the checker
  lets them compare, as OCaml's structural `=` and `<>`; see "Equality"), `and`/`or`/`not`, the bitwise
  operators, `xs[i]` (`List.nth`), `s[i]` on a String, and calls.

A `def` needs no annotation here: the checker works one out from its
body, and this backend reads the answer back. Annotations are erased
either way — the output carries none.

## What is not supported

A program the type checker refuses is refused here first, with the
checker's own message framed as this target's limitation:

```
$ pyk compile -t ocaml program.pyk
'program.pyk' 1:0-1:9 Unsupported by target 'ocaml': this target
  compiles only programs that type-check, and this one does not:
  Construct is not supported
```

Beyond that, four things the checker accepts and this backend refuses,
each because OCaml has no way to be given it. Each raises `Unsupported`
with a source position, so nothing reaches `ocamlopt` that will not
build.

### A `break` or `continue` that is neither in tail position nor a guard

A loop is a local function here, so `break` in tail position is the
value that function returns and `continue` there is its tail call, and
either one guarding the rest of the body is an `if … then … else …`
with that rest in the `else` — which covers the shapes a loop is
normally written in, since a statement written *after* an unconditional
`break`/`continue` is a parse error to begin with (see PYKING.md). What
is left is a `break` inside an `if`/`else` neither arm of which leaves,
with statements after it; that would need the rest of the body
duplicated into every branch, and is refused instead.

A `return` needs no such rule: one this backend cannot write as a value
leaves through an escape instead (see "Leaving a function early").

### A `def` that cannot be moved to join its group

Pyking makes every `def` in a block visible throughout it, wherever it
is written. OCaml expresses that with `let rec … and …`, which binds a
group that has to be **written together**. Consecutive `def`s are
therefore fine, however they refer to each other:

```
def is_even(n:Int) -> Bool:
    if n == 0:
        true
    else:
        is_odd(n - 1)

def is_odd(n:Int) -> Bool:
    if n == 0:
        false
    else:
        is_even(n - 1)
```

```ocaml
let rec is_even n = if n = 0 then true else is_odd (n - 1)
and is_odd n = if n = 0 then false else is_even (n - 1)
```

A statement between them does not break the group: `regroup` moves the
earlier `def`s down to join the last of their group before anything is
translated, so the `let rec` is written where the group ends. A `def`
binds no value and runs nothing, so moving one changes nothing — which
is why only `def`s move and every other statement keeps its place.

```
y = 1

def f() -> Int:
    g()

y = 2

def g() -> Int:
    y
```

```ocaml
let _y = 1

let y = 2

let rec f () = g ()
and g () = y
```

Two things stop a `def` from moving, and both are refused rather than
compiled wrongly. One is a name its own body reads being bound again in
between — moving it would give it the later binding, where Pyking's
capture is positional (see [../PYKING.md](../PYKING.md), "Names and
scoping"). The other is the `def`'s own name being used in between —
moving it would leave that use reading a name OCaml has not bound yet.

```
'program.pyk' 3:0-4:7 Unsupported by target 'ocaml4.14': `f` names a
  `def` written further down: OCaml binds a group of mutually
  recursive functions with `let rec ... and ...`, which has to be
  written together, and this one cannot be moved down to join it --
  `y` is bound again in between, so moving it would give it the later
  one
```

Only a reference *forward* makes a group. A `def` naming one written
above it needs nothing done: OCaml already has that one in scope.

### Printing a value of a type variable

OCaml has no runtime type, so a value whose type is a variable cannot be
printed there at all. Two cases get through anyway. A variable *nothing
constrained* stands for a type no value of which was ever made — the
element type of `[]`, say — so the formatter it would need is never
reached, and one that names no type is emitted in its place. And a
definition every call in the module uses at one type is compiled at that
type: `specialisations` reads the instantiation off the call sites,
provided the name has one `def` in the module, is never handed anywhere
as a value, and every call agrees.

What is left is a definition used at two types whose body prints one of
its parameters, and that is refused:

```
'program.pyk' 13:17-13:18 Unsupported by target 'ocaml4.14': printing a
  value of type a
```

### `|` around a `+` split or a list split from its end

Both are tested in the arm's `when` (see "`match` and patterns"), and an
alternative of OCaml's `|` has no `when` of its own, so an alternative
holding one is refused.

### An element of a list pattern with elements after `..`

`[a, ..rest, b]` is matched by binding the whole subject and taking each
element by position, so each element has to be a pattern a `let` can
take: a name or `_`. A literal or a nested list there is refused.

## How the type checker is reused

`type_check(stmts)` returns a `tmap`: symbol → type, with an entry for
**every expression**, not just the ones an annotation could be written
on. This backend is the reason that is true. Two decisions need it:

- **`print` and `debug` are the only things that need a type.** A `+`
  that joins is a node of its own by the time it arrives (elaborate.ml
  makes it), and maps straight onto OCaml's `^` or `@`, so nothing has
  to ask an operand's type to choose; the other operators are one OCaml
  operator each, `+` or `+.` decided from the operand's type as `/` is.
- **Type variables need nothing, up to a point.** This backend writes no
  type annotations, and OCaml generalizes what a `let` binds, so a
  polymorphic Pyking function becomes a polymorphic OCaml one by itself
  -- `def id(x:a) -> a` is `let id x = x`, usable at every type its
  Pyking original was.
- **A polymorphic parameter is a record.** OCaml does not generalize a
  parameter, so a parameter of type `all a. (a) -> a` is passed in a
  record with a polymorphic field, `{ pyk_poly1 : 'b0. 'b0 -> 'b0 }`,
  declared at the top of the module -- one record per shape, the parts
  naming none of its own variables being the record's type parameters.
  A call wraps its argument, `use { pyk_poly1 = identity }`, and the body
  reads it, `f.pyk_poly1 1`. The records are declared in the module and
  its `.mli`, but numbered per module, so another module's call to such
  a function is not wrapped in the record it takes.
- **`print` formats by type.** An `Int` argument becomes
  `string_of_int e`, a `Bool` becomes `string_of_bool e`, a `String` is
  written as it is, unit becomes `"()"`, and a list of `Int` goes
  through the one generated helper.

`src/target_c.ml` and `src/target_java.ml` each carry their own
inference, written before the checker existed and answering a narrower
question (which C or Java type does this need to be declared as). This
backend does not, which is most of the reason it is the shortest of the
four.

## How things compile

### Blocks and bindings

A Pyking block is a scope and OCaml's `let … in` is a scope, so the
translation is direct. Nothing is renamed — `target_python.ml` renames
shadowed bindings because Python functions have one flat scope, and none
of that is needed here:

```
total = 1
total = total + 41
print(total)
```

```ocaml
let total = 1

let total = total + 41

let () = print_endline (string_of_int total)
```

Inside a function the same statements become nested `let … in`, with the
last statement supplying the value.

### Functions

A `def` becomes a `let`, with `rec` only when something actually
recurses and `and` only between functions that really do name each
other. A run of consecutive `def`s is split into the smallest groups
that still see each other, so two unrelated helpers do not end up
looking mutually recursive.

Whether a function recurses is decided on the *translated* OCaml, where
the binders are explicit: a body that shadows the function's own name
with a local binding mentions that name without recursing, and a
free-variable walk sees the difference that a search for the name alone
would not.

A `def` with no parameters takes unit, and a call with no arguments
passes it — `def f() -> Int:` becomes `let f () = …` and `f()` becomes
`f ()`. OCaml has no nullary function, so without the unit the binding
would be a *value*, evaluated where it is written rather than where it
is called: a body that prints would print at start-up, and one that
never returns (a `loop:` with no `break`, which Pyking allows) would
hang the program before `main` ran.

### Lambdas

A lambda is `fun x -> …`, and the rule a `def` with no parameters
follows applies here too: `() => e` takes unit, so it is `fun () -> e`
rather than a value evaluated where it stands.

```ocaml
let double = fun x -> x * 2
let adder = fun x -> fun y -> x + y
```

A lambda's parameters go through the same name planning every other
binding does, and an unread one is renamed `_x` like any other, so the
`-w +a` build the test harness uses stays warning-free.

### `if`

An `if` is an expression in OCaml, which is what Pyking's value form
already assumes. An `else:` containing another `if` prints as `else if`
rather than nesting a level deeper, and a whole chain that fits on one
line stays on one line:

```ocaml
let rec gcd a b =
  if a = b then a else if a > b then gcd (a - b) b else gcd a (b - a)
```

A statement-form `if` with no `else` becomes `if … then …`, whose value
is unit — which is exactly when Pyking allows one.

### Tail calls, and the pass that does not run here

OCaml eliminates tail calls itself, so this target is compiled from the
program as written: `src/opt_tailcall.ml`, which turns tail recursion
into `loop`s for every other target, is skipped for `ocaml` (see
docs/optimization.md, "The target that needs none of this"). A
tail-recursive Pyking function therefore compiles to a tail-recursive
OCaml one --

```ocaml
let rec f1 x = if x >= 20000 then 1000 + x else f1 (x + 1)
```

-- and a mutually recursive group to `let rec … and …`, which is what
`ocamlopt` was going to turn into a jump anyway. Running the pass first
would only have this backend undo it: a `loop` compiles to a local
recursive function here, so the two would take turns rewriting one
program into the other's shape.

`NATIVE_TAIL_CALLS` in `src/pyk.ml` is the list that says so; a backend
for another host with proper tail calls adds its name to it.

### `loop`, `break` and `continue`

A loop is a **local recursive function, applied at once**: the
accumulator is its parameter, going round is a tail call, and breaking
is the value the call returns. Nothing imperative is involved, and
OCaml's own tail-call optimisation is what makes it a loop rather than a
stack of calls — so a Pyking loop that runs a million turns runs in
constant space here.

```pyking
res = loop x = 5:
    if x <= 10:
        x + 1
    else:
        break
```

```ocaml
let res =
  let rec tmp1 x = if x <= 10 then tmp1 (x + 1) else x in
  tmp1 5
```

The three ways a body can say what happens next map one to one: the
body's last expression becomes `tmp1 e`, `continue` becomes `tmp1 x`,
and `break` becomes `x` -- the accumulator this turn was called with,
which is what the loop is worth. With a value, `continue v` becomes
`tmp1 v` and `break v` becomes `v`. A loop carrying several values takes a
tuple pattern parameter, `let rec tmp1 (x, y) = …`, and a `loop:`
carrying nothing takes a unit one.

Because a loop is an expression, it needs nothing said about it in any
of the positions a value can stand: bound with `=`, returned, or as a
function's last statement. `rec` is emitted only when the body really
does call the loop function — a loop that always breaks does not — since
`ocamlopt -w +a` treats a needless `rec` as an error.

### `for` and `while`

A `for`/`while` clause is the same local function with one more thing to
carry. A `for` walks a list, so what is left of it is a second
parameter, and running out of list is leaving the loop with the
accumulator:

```pyking
total = loop acc = 0 for x in xs:
    acc + x
```

```ocaml
let total =
  let rec tmp1 acc tmp3 =
    match tmp3 with
    | [] -> acc
    | x :: tmp2 -> tmp1 (acc + x) tmp2 in
  tmp1 0 xs
```

A `while` needs no extra parameter — the test is asked with the
accumulator in scope, and a turn not taken leaves the loop with it:

```ocaml
let rec tmp1 acc = if <test> then <body> else acc in
tmp1 <init>
```

`break`, `continue` and a body's last expression mean exactly what they
mean without a clause; `again` simply passes the remaining list along
with the next accumulator. The accumulator is worked out before the
sequence, which is the order `src/interpreter.ml` uses, and `in_order`
pins it down where both can print.

### Leaving a function early

A `return` at the end of a body is just that body's value, and a
`return` guarding the rest of a function is an `if … then … else …` with
the rest in the `else`:

```pyking
def clamp(n:Int) -> Int:
    if n < 0:
        return 0
    n * 2
```

```ocaml
let clamp n = if n < 0 then 0 else n * 2
```

A `return` anywhere else has no OCaml spelling as a value — inside a
loop whose value is wanted where it stands, inside an `if` run for what
it does with statements after it, or with unreachable statements after
it — so control leaves by exception instead. The body
is translated a second time with an **escape** in scope: a cell for the
value and a local exception for the control. The exception carries
nothing, so OCaml needs no type written for it, and infers the cell's
from what is put there.

```pyking
def described(n:Int) -> String:
    reached =
    loop k = n:
        if k > 100:
            break
        if k == 13:
            return "unlucky"
        k * 3
    "reached " + string(reached)
```

```ocaml
let described n =
  let tmp2 = ref None in
  let exception Tmp1 in
  try
    let reached =
      let rec tmp4 k =
        if k > 100 then k
        else if k = 13 then (tmp2 := Some "unlucky"; raise Tmp1)
        else tmp4 (k * 3) in
      tmp4 n in
    "reached " ^ string_of_int reached
  with Tmp1 -> (match !tmp2 with Some tmp3 -> tmp3 | None -> assert false)
```

Nothing is wrapped that does not need it: `function_binding` translates
the body without an escape first, and only builds one when the
translation asks for it (`Needs_escape`). A body with no such `return`
is byte-for-byte what it was.

### `match` and patterns

A Pyking `match` is OCaml's own, and most patterns are a spelling
change: `..` is `_`, `..name` is `name`, and a list splits with `::`.
Two shapes need what OCaml's patterns cannot say, and both go through
one mechanism — an arm may carry a `when` guard and open its body with
bindings the pattern could not make:

- **a `+` pattern over a string.** OCaml's patterns do not split a
  string, so the whole subject is bound and the guard tests its length
  and its ends; the middle comes out with `String.sub`. The length test
  is written first, which is what makes the `String.sub`s after it safe.
- **a list pattern with elements after `..`.** OCaml matches a list from
  the front only, so the whole subject is bound, the guard tests its
  length, and every element is taken by position with `List.nth`; the
  middle is `List.take` of `List.drop`.

A guard is the arm's `when` too, after the pattern's own tests, with
the bindings a split makes wrapped around it so that it can name them.
An or-pattern is OCaml's `(p1 | p2)` and an `as` pattern its `(p as
x)`.

Every `match` matches every value (docs/exhaustive.md), but a `when`
makes an arm invisible to OCaml's own exhaustiveness check. So
`Exhaustive.covers` is asked of the arms OCaml *can* see -- those with
no `when` -- and only where they do not cover is `| _ -> assert false`
written in. It is unreachable, and writing it where OCaml can see the
coverage would be warning 11.

### Datatypes

A datatype is OCaml's own variant type, all of a module's in one `type
... and ...`, its name lowercased (`tree`, with `_` added where OCaml
has taken the name: `list_`, `option_`) and its parameters `'a`. A
constructor keeps its name, with `_` added where Stdlib's would be
shadowed (`None_`, `Some_`, `Ok_`, `Error_`), and one of another module
is written through it, `Shapes.Circle`:

```pyking                          # generated OCaml
datatype Tree(a):                  type 'a tree =
    Leaf                             | Leaf
    Node(Tree(a), a, Tree(a))        | Node of 'a tree * 'a tree * 'a
```

Beside the declaration goes one printer per datatype, `pyk_show_tree`,
taking a printer per type parameter and then the value, and writing it
as Pyking prints it; a print site hands it the printers for the types
it was applied to. A datatype whose values can hold a cycle takes the
*path* as well, in front of the value (see "Var structs"). A field read is a `match` with one arm per
constructor. A `match` of one arm with no guard is printed as `let`
(`let Point (_, tmp1) = p in tmp1`), since every `match` is exhaustive
and its one pattern cannot fail -- which is what a field read of a
`struct` and its printer come to. A module the program imports declares its datatypes and
their printers in its `.mli` too. A generated file that declares or
matches a datatype opens with `[@@@warning "-fragile-match"]`: `_` over
a datatype is how Pyking says "every other constructor", which OCaml
calls fragile.

### `var` and `:=`

A mutable variable is an OCaml `ref`, which is the same idea spelled the
same way: `var x = 0` becomes `let x = ref 0 in`, `x := e` stays
`x := e` (unit-valued in both languages, so it needs nothing said about
where it stands), and every *read* of the name becomes `!x`.

```pyking
use mutation

var total = 0
total := total + 1
print(total)
```
```ocaml
let total = ref 0

let () = total := !total + 1; print_endline (string_of_int !total)
```

The scope falls out of `let … in` exactly as an `=` binding's does: a
`var` is in scope for the rest of its block and no further. What the
translation has to carry is which names are cells, so a read knows to
dereference — a set threaded through the block walk, pushed when a `var`
opens a scope and dropped when it closes. Pyking refuses to shadow a
`var`, which is what makes that set safe: a name in it means the same
cell wherever it is read.

### Tuples

A Pyking tuple is an OCaml tuple, and a binding that takes one apart is
`let (a, b) = …`. Printing is the only part with any work in it: OCaml
has no generic printer, so `print` formats a tuple by taking it apart
and formatting each element by its type, which is how a nested one works
too:

```pyking
pair = (1, true)
print(pair)
```

```ocaml
let pair = (1, true)

let () =
  print_endline
    (let (tmp1, tmp2) = pair in
     "(" ^ string_of_int tmp1 ^ ", " ^ string_of_bool tmp2 ^ ")")
```

A string inside a tuple is quoted, where one printed on its own is not,
so a `pyk_quote` helper joins the prelude when a program needs it (see
"Builtins"). It writes the String between double quotes, escaping `\`,
`"`, newline, tab, carriage return and NUL as `builtin.ml`'s
`quote_string` does; a `'` is left alone.

### Chars

A `Char` is an OCaml `int`, its code point: `'a'` compiles to `97` and
`case 'a':` to the pattern `97`, so `==`, `<` and the rest are OCaml's
own comparisons on ints. This is also how the interpreter's plugin host
hands a Char to an OCaml external implementation, so an external
written for the interpreter works here unchanged.

A String stays a UTF-8 `string`, counted in code points. Every helper
below is emitted only into a program that uses it, and each stands
alone (they ride with the conversion helpers):

| Pyking | OCaml |
|---|---|
| `'a'` | `97` |
| `len(s)` | `pyk_char_length s` -- code points, not bytes |
| `s[i]` | `pyk_char_at s i` -- the i-th code point, decoded with `String.get_utf_8_uchar` (OCaml 4.14 on); out of range raises `Invalid_argument`, as a list index out of range raises |
| `for c in s`, `[e for c in s]` | the walk is over `pyk_chars s`, the String's code points as an `int list` |
| `string(c)`, `print(c)` | `pyk_char_text c`, the code point UTF-8 encoded |
| a Char inside a list, tuple or datatype | `pyk_quote_char c`: `'a'`, escaping `'`, `\`, newline, tab, CR and NUL |
| `int(c)`, `float(c)`, `bool(c)` | `c`, `float_of_int c`, `c <> 0` |
| `char(n)`, `char(s)`, `char(c)` | `pyk_char_of_int n` (0 unless a scalar value), `pyk_char_of_string s` (its first code point, 0 for `""`), `c` |

### Arrays

An `Array(T)` is OCaml's own `T array`: a block shared by reference,
so assigning one, passing it, returning it, putting it in a tuple, list
or datatype and capturing it in a closure never copies it, which is
Pyking's rule as well. `len(a)` is `Stdlib.Array.length a`, which is
O(1), and `same(a, b)` is `a == b`, OCaml's physical equality. Every
name is written `Stdlib.Array.…`, since a program that imports
`lib/array` has a module `Array` of its own beside it (see "External
modules").

| Pyking | OCaml |
|---|---|
| `array(xs)` | `Stdlib.Array.of_list xs` |
| `array(n, v)` | `pyk_array_fill n v`: n slots holding the one `v`, not copies |
| `array(n, f)` | `pyk_array_init n f`: `f 0`, `f 1`, … in that order, which `Array.init` does not promise; `f` never runs for n = 0 |
| `array(n, seed, f)` | `pyk_array_unfold n seed f`: each `f s` gives an element and the next state; the last state is dropped |
| `a[i]` | `pyk_array_get a i` |
| `a[i] := v` | `pyk_array_check a i; Stdlib.Array.unsafe_set a i v`, the array and index held first |
| `for x in a` | a walk by index, reading `a.(i)` as each turn begins |
| `[e for x in a]` | the comprehension walks `Stdlib.Array.to_list a` |
| printing | `"array([" ^ … ^ "])"`, each element as a list writes it |

The helpers are emitted only into a program that uses them, each with
the ones it calls ahead of it.

**Checks.** OCaml's own bounds check raises `Invalid_argument "index
out of bounds"`, which names nothing the program said, so every index
is checked first by `pyk_array_check`, and a size by `pyk_array_size`
before anything is called or allocated. A failed check is a Pyking
runtime error: `pyk_array_fail` flushes what was printed, writes
`error: ` and the interpreter's message to standard error, and exits
with status 1:

```
error: the index 5 is outside an array of 2 elements
error: an array's size is never negative, and this one is -1
error: an array of N elements is more than this machine can hold
```

The last is for a size above `Sys.max_array_length`. A negative index
is an error too: nothing counts from the end.

**Writing an element.** `a[i] := v` works out the array, then the
index, then checks the index, and only then works out `v` — so a bad
index stops the program before `v` has done anything. The array and the
index are held under a name of their own (a plain immutable name is
used as it is), so the write goes into the array first named even when
working out `v` rebinds the `var` it came from:

```pyking
held[0] := replace_held()
```

```ocaml
let () =
  let tmp45 = !held in
  pyk_array_check tmp45 0;
  Stdlib.Array.unsafe_set tmp45 0 (replace_held ())
```

`a[i] op= e` reaches this backend already split into a binding of the
array, one of the index, and `a[i] := a[i] op e` on those two names.

**Walking.** A `for` over an array is the same local recursive function
any loop is (see "`for` and `while`"), with the turn's index as its
second parameter rather than the rest of a list: the loop stops when
the index reaches `Stdlib.Array.length a`, and otherwise reads the
element there as the turn begins. A write to a later element during the
loop is therefore seen when its turn comes, as it is in the
interpreter:

```ocaml
let rec tmp12 _tmp13 tmp14 =
  if tmp14 >= Stdlib.Array.length walked then ()
  else
    (let x = Stdlib.Array.unsafe_get walked tmp14 in
     ...;
     tmp12 () (tmp14 + 1)) in
tmp12 () 0
```

An array that is more than a plain name is held under one before the
loop starts, after the accumulator's first value.

**Types.** `array([])` says nothing to OCaml about its element type,
and a top-level binding of one would then have a type OCaml refuses to
generalise. Where the checker's type for it is made of the base types,
lists, tuples and arrays, it is written on the call:
`(Stdlib.Array.of_list [] : int array)`. An exported function's type
writes `Array(T)` as `T array` in the `.mli`.

### Var structs

A `var struct` is a variant of one constructor over an *inline record*
whose fields are all `mutable`, labelled with the fields' names:

```pyking                          # generated OCaml
var struct Point(x: Int, y: Int)   type point =
                                     | Point of { mutable x : int; mutable y : int }
```

OCaml allocates the constructor's block once, when the struct is made,
and every name, parameter, element and field that holds it holds that
one block — the sharing Pyking asks for, with nothing to add. A plain
`struct` and every other datatype stay ordinary immutable variants.

| Pyking | OCaml |
|---|---|
| `Point(1, 2)` | `Point { x = 1; y = 2 }` |
| `p.x` | `let Point { x = tmp1; _ } = p in tmp1` |
| `p.x := v` | `let Point tmp2 = p in tmp2.x <- v` |
| `case Point(a, b)` | `Point { x = a; y = b }`, the fields as they are when matched |
| `same(p, q)` | `p == q`, OCaml's physical equality |
| printing | `pyk_show_point p`, as a `struct` prints |

**Writing a field.** The owner is worked out first, then the value,
then the write — into the struct the owner was, whatever the value did
to the name it came from. OCaml fixes that order in a `let` alone, so
the write takes the record out of the owner with one, and works out the
value in its body. `p.x += e` reaches this backend already split into a
binding of the owner, `field__owner = p`, and a write through it. A
type variable of a generic `var struct` is fixed by the struct's first
use, which OCaml's own weak type variable does the same way.

**Cycles.** A var struct, or an array, can hold itself, so every
printer that can meet one again takes the *path*: an `Obj.t list` of
the arrays and var structs being formatted further out, innermost
first, `[]` where formatting starts. `pyk_guard` formats a value with
the value put on the path, or answers `...` where it is on it already:

```ocaml
let pyk_guard path value show =
  let key = Obj.repr value in
  if List.memq key path then "..." else show (key :: path)

let rec pyk_show_link path value =
  match value with
      | End -> "End"
      | Next f0 -> "Next(" ^ pyk_show_node path f0 ^ ")"
and pyk_show_node path value =
  pyk_guard path value (fun path -> (let Node { value = f0; next = f1 } = value in
    "Node(" ^ string_of_int f0 ^ ", " ^ pyk_show_link path f1 ^ ")"))
```

so `a.next := Next(a)` prints `Node(1, Next(...))`. Only what is on the
path from the value printed is `...`: a struct that is merely shared,
the same one twice in an array, prints in full both times, as the
interpreter's does. An array is guarded the same way, inline, where its
elements can lead back to it.

Which printers take the path is decided from the datatype's
declaration and those of its own module alone, so every module that
sees a datatype hands its printer the same arguments: one takes it
where its values can hold a cycle through an array, a DynArray, a MutMap or a
var struct, a type variable's value, or a type of another module. Such
a printer guards its value too, immutable or not, as the interpreter
puts every datatype value with fields on its path: the cycle stops at
whatever on it repeats first, so `o = Just(n)` with `n.nxt := o` prints
`Just(N(1, ...))`. Its type-parameter printers take the path too
(`show_a path f0`). A datatype of plain values -- `Point` above, a list
of Ints, a tree of Strings -- takes no path and prints as it did before
var structs existed.

In a recursive group a printer is monomorphic in the others, so a
generic datatype's printer that another datatype of the group calls at
one type would be fixed at that type. A generic printer in a recursive
group is therefore written with its type, which OCaml then uses at
every type:

```ocaml
let rec pyk_show_opt : 'a. (Obj.t list -> 'a -> string) -> Obj.t list -> 'a opt -> string =
  fun show_a path value -> pyk_guard path value (fun path -> ...)
and pyk_show_n path value = ... pyk_show_opt (fun path tmp12 -> pyk_show_n path tmp12) path f1 ...
```

### DynArrays

A `DynArray(T)` is a cell holding its storage and its length,
`(T option array * int) ref`. The cell is what every holder of the DynArray
shares, so `same(v, w)` is `v == w`; the storage is replaced when it
grows, and the length changes, by writing a new pair into the cell.
Stdlib's types alone make it up, so every module of a program writes
the same type for it without one declaring it for the others -- a
record type would be a different type in each module that declared it,
and OCaml 4.14 has no `Dynarray`. A slot past the length is `None`, so
an element popped, removed or cleared is not kept alive by the slot it
left.

| Pyking | OCaml |
|---|---|
| `dynarray()` | `ref ([\|\|], 0)`, its type written on it where it is plain, as `array([])`'s is |
| `dynarray(xs)` | `pyk_dynarray_of_list xs` |
| `v[i]` | `pyk_dynarray_get v i`, checked against the length it has now |
| `v[i] := x` | `pyk_dynarray_check v i; pyk_dynarray_set v i x`: checked before `x` is worked out, and again as it is written |
| `push(v, x)` | `pyk_dynarray_push v x`, the storage doubled where it is full |
| `pop(v)` | `pyk_dynarray_pop v` |
| `insert(v, i, x)` | `pyk_dynarray_insert v i x`, for 0 <= i <= the length |
| `remove(v, i)` | `pyk_dynarray_remove v i` |
| `clear(v)` | `pyk_dynarray_clear v`, which drops the storage |
| `len(v)` | `pyk_dynarray_length v` |
| `for x in v` | a walk by index, while it is below `pyk_dynarray_length v` at that turn |
| `[e for x in v]` | the comprehension walks `pyk_dynarray_to_list v` |
| printing | `"dynarray([" ^ … ^ "])"`, guarded as an array is (see "Var structs") |

A failure is a Pyking runtime error, through `pyk_array_fail`: `error:
the index 5 is outside a DynArray of 2 elements`, `error: pop from an empty
DynArray`, `error: insert's index 7 is outside 0 to 3, the DynArray's length`.
The helpers are emitted only into a program that uses them. A
program's own `push` (or `pop`, ..., `same`) is called as any of its
functions is: the checker gave it a type, which a builtin has none of.

### Slices and views

`s[i:j]` copies, into a new value of the sequence's own kind -- a
view's into an array -- through one helper per kind,
`pyk_slice_list`, `pyk_slice_string` (by code point), `pyk_slice_array`,
`pyk_slice_dynarray` and `pyk_slice_view`. Each takes the sequence, the low
bound (`0` where it was left out) and the high one as an option (`None`
where it was left out, the length then), worked out in that order, and
checks them with `pyk_slice_bounds` before copying: `error: the slice
2:4 is outside an array of 3 elements`.

A view, `Slice(T)`, is a triple: the array it is a view of, where it
starts in it, and its length, `(T array * int * int)`. The triple is
made once, by `view`, and shared like any value, so `same(w, w2)` is
`w == w2` -- two `view(...)` calls make two triples, which are not
`same` -- and it shares the array's elements, so a write through it is
a write to the array. A view of a view is a triple over the same array,
the offsets added.

| Pyking | OCaml |
|---|---|
| `view(a, i, j)` | `pyk_view a i j`, or `pyk_view_of_view w i j`, the bounds checked |
| `w[k]`, `w[k] := x` | `pyk_view_get w k`; `pyk_view_check w k; pyk_view_set w k x` |
| `len(w)` | `pyk_view_length w` |
| `for x in w` | a walk by index, reading the array as each turn begins |
| `[e for x in w]` | the comprehension walks `pyk_view_to_list w` |
| `copy_into(dst, src)` | `pyk_copy_into dst src`, an array passed as `pyk_whole a`, a view of all of it |
| printing | `"view([" ^ … ^ "])"`, the elements as they are now |

`copy_into` is `Stdlib.Array.blit`, which is memmove: right where the
two runs overlap. More from `src` than `dst` holds is `error: copy_into
copies 4 elements into 2`. On the cycle path a view is the array it is
a view of (`pyk_view_owner`), as the interpreter's is. `view` and
`copy_into` are builtins only where the program has no function of its
own by the name.

### Pointers

A `Ptr(T)` is an OCaml object naming a place:

```ocaml
< get : T; place : Obj.t * int; set : T -> unit >
```

`*p` is `p#get`, `*p := v` is `p#set v` (the pointer held first where
it is more than a plain name, so it is worked out before the value),
and `place` is the store the place is in and its slot there, which is
what two pointers are compared by. An object type is structural, so
every module writes the same type for a pointer, as for a DynArray.

| Pyking | OCaml |
|---|---|
| `&x`, `x` a `var` | `pyk_ptr_cell x`: the `var`'s ref itself, slot 0 |
| `&a[i]` | `pyk_ptr_elem a i`, the index checked as the address is taken |
| `&w[i]`, `w` a view | `pyk_ptr_view_elem w i`: the array's element `offset + i` |
| `&s.f`, `s` a var struct | `pyk_ptr_field s k get set`: the struct, the field's position, and a reader and a writer of the field |
| `&*p` | `p` |
| `p == q` | `pyk_ptr_same p q`: one store (`==`) and one slot |
| printing | `"Ptr(" ^ … p#get … ^ ")"`, what it points at now; on the path it is its store (`pyk_ptr_store`) |

A `var` is already a ref, allocated on the heap, so a pointer to a
local outlives the call that made it with nothing more to do
(tests/pointers_escape.pyk). A failed check is `error: the index 5 is
outside an array of 2 elements` (or `... a view of ...`).

**Equality.** OCaml's `=` would compare two pointers by the contents of
their objects -- and raise on the methods -- so `==` on a type that can
hold a pointer (`holds_pointer`: a pointer, a list, tuple or datatype
with one somewhere inside, or a datatype this module cannot see) is
`pyk_equal`, a structural walk of the two values that compares a
pointer -- the only object a Pyking value holds -- with
`pyk_ptr_same`, a Float by IEEE and a String by its text, as `=` does.
Every other `==` stays `=`.

### MutMaps

A `MutMap(K, V)` is a Stdlib hash table from each key to the *stamp* it
was put in under and its value, beside a counter:
`(K, int * V) Stdlib.Hashtbl.t * int ref`. Putting a new key in or
taking one out moves the counter on, and a new key is stamped with the
counter, so the stamps are the order the keys were put in; replacing a
value keeps its stamp, and so its place. The pair is made once, when
the MutMap is, and is what every holder shares, so `same(d, e)` is
`d == e`. Like a DynArray's, the type is Stdlib's alone, so every module
writes it the same. A key type is one OCaml's structural hashing and
`compare` agree with Pyking's `==` on -- the checker allows no Float,
function or mutable value in one.

| Pyking | OCaml |
|---|---|
| `mutmap()` | `(Stdlib.Hashtbl.create 8, ref 0)`, its type written on it where it is plain |
| `mutmap(pairs)` | `pyk_mutmap_of_list pairs`: a key twice keeps its first place and its last value |
| `d[k]` | `pyk_mutmap_get show d k`, `show` writing the key for the error |
| `d[k] := v` | `pyk_mutmap_set d k v`, the MutMap and the key held first |
| `get(d, k, x)` | `pyk_mutmap_get_or d k x`, `x` worked out as any argument is |
| `has(d, k)`, `len(d)` | `pyk_mutmap_has d k`, `pyk_mutmap_length d` |
| `remove(d, k)`, `discard(d, k)`, `clear(d)` | `pyk_mutmap_remove show d k`, `pyk_mutmap_discard d k`, `pyk_mutmap_clear d` |
| `keys(d)`, `values(d)`, `items(d)` | `pyk_mutmap_keys d`, ...: the entries sorted by stamp |
| `for k in d` | a walk by index over `pyk_mutmap_walk d`, the keys and the counter as the walk begins |
| `[e for k in d]` | the comprehension walks `pyk_mutmap_keys d` |
| printing | `"mutmap([" ^ … ^ "])"`, each entry as a `(k, v)` tuple, guarded as an array is |

**Walking.** The walk asks `pyk_mutmap_walk_length` for its length at
every advance, the last included, and that is where the counter is
compared with the one the walk began with: a key put in or taken out
during the walk is `error: the MutMap changed while a for loop was
reading it`. A value replaced is not. A missing key is `error: the MutMap
has no key "b"` (or `... to remove`), the key written as inside a
value.

Listing the entries sorts them, so `keys`, `items`, printing and the
start of a walk take `n log n`; reading, writing, `has`, `remove` and
`len` take constant time on average.

### Equality

`==` and `!=` are OCaml's structural `=` and `<>` (but see "Pointers"
for values holding a pointer), which compare exactly
what Pyking does on every type the checker lets them compare: scalars
by value (a Float by IEEE, so `nan = nan` is false and `-0.0 = 0.0`
true), lists and tuples element by element, datatypes by constructor
and then field by field. The checker refuses them on functions, arrays,
DynArrays, MutMaps, var structs and type variables, the values `=` would raise
on or compare by contents where Pyking compares by identity, so none
reaches it.

### `print`

`print_endline`, with the arguments formatted per
[builtin.ml](../src/builtin.ml) and joined with a
single space. Booleans and unit need no translating at all: OCaml spells
them `true`, `false` and `()` already, which no other target can say —
the Python backend has to override `print`'s capitalisation and the C
backend has to spell out a conditional.

```
print(1, "two", true)
```

```ocaml
let () =
  print_endline (string_of_int 1 ^ " " ^ "two" ^ " " ^ string_of_bool true)
```

Every argument is worked out before any is formatted. Where one of
them can hold an array or a var struct and another calls a function,
which could change it, each argument is held under a name of its own,
left to right, and the line is made from the names:

```pyking
print(acct, deposit(acct, 5))
```

```ocaml
let () =
  let tmp11 = deposit acct 5 in
  print_endline (pyk_show_account acct ^ " " ^ string_of_int tmp11)
```

`debug` is the same line through `prerr_endline`, on standard error. A
program compiled with `--release` has no `debug` left in it. The checker
records a type for a callee it resolved to a definition and none for a
builtin, which is how a program's own `debug` is told from the builtin.

### Builtins

| Pyking | OCaml |
|---|---|
| `string(n)` | `string_of_int n` (or `string_of_bool`, or nothing at all for a `String`) |
| `len(s)` | `pyk_char_length s` (code points; see "Chars") |
| `len(xs)` | `List.length xs` |
| `len(a)`, `same(a, b)` | `Stdlib.Array.length a`; `a == b` (see "Arrays") |
| `range(n)` | `List.init (max 0 n) Fun.id` |
| `range(a, b)`, `range(a, b, s)` | `pyk_range a b s`, a generated helper |
| `float(n)`, `float(b)` | `float_of_int n`; `if b then 1.0 else 0.0` |
| `float(s)` | `pyk_float_of_string s`, a generated helper |
| `int(b)` | `if b then 1 else 0` |
| `int(x)`, `int(s)` | `pyk_truncate x`, `pyk_int_of_string s`, generated helpers |
| `bool(s)`, `bool(n)`, `bool(x)` | `s = "true"`, `n = 1`, `x = 1.0` |
| printing a list | `pyk_string_of_int_list`, the one generated helper |

The helper exists because a Pyking list prints the way Python prints one
— `[0, 1]` — and OCaml's own list syntax separates with `;`:

```ocaml
let pyk_string_of_int_list xs =
  "[" ^ String.concat ", " (List.map string_of_int xs) ^ "]"
```

It is emitted only into programs that print a list.

### Evaluation order

Pyking evaluates an operator's operands, and a call's arguments, left to
right. OCaml leaves the order unspecified and in practice runs them
right to left. That is invisible unless two of them *print*, so the
backend works out which expressions can print — a walk of the call
graph, with a call to something that is not a `def` assumed to print if
anything in the program does — and pins those down with a `let`, the one
construct that does fix the order:

```
sum = step("a", 1) + step("b", 2)
```

```ocaml
let sum = let tmp1 = step "a" 1 in tmp1 + step "b" 2
```

A program whose functions only compute — nearly every program — has
nothing to order, and its operands stay exactly where the source put
them.

Arrays add a second reason to pin. An element read can fail, and sees a
write made before it, so where one of the operands reads an array (or
makes one), each operand that reads one or calls a function is pinned
as a printing one is: `a[0] + change()`, where `change` writes `a[0]`,
reads the element first, as the interpreter does.

The rule in full: where one operand *writes* -- prints, can fail (an
element read of an array, a DynArray or a MutMap, making an array), or calls
something that can change what a caller sees -- every operand that can
*see* it is pinned. Seeing is writing, or reading a `var`, a var
struct's field, a builtin's reading of a DynArray or a MutMap (`len`, `get`,
`has`, `keys`, ...), a `string(v)` of something that can hold an array,
a DynArray, a MutMap or a var struct, or calling any function, which may read
those. A builtin is told from a program's own function of the same
name by the type the checker gave the latter. Which functions change something is worked out like which print:
a function that writes a `var` it did not declare, an element, a field
or a DynArray, or calls one that does; a call this module cannot follow (a
parameter, another module's function) is taken to change something
where the program imports a module or has a changing function of its
own. So `print(tick(), tick())`, where `tick` increments a `var`,
prints `1 2`:

```ocaml
let () =
  let tmp1 = tick () in
  print_endline (string_of_int tmp1 ^ " " ^ string_of_int (tick ()))
``` `tests/evaluation_order.pyk` is the case that pins this down; it
runs on every target that supports it, and one `.out` has to serve them
all.

### Names

An OCaml value name must start with a lowercase letter or an underscore
and must not be a keyword, so a Pyking `Total` becomes `v_Total` and a
Pyking `method` becomes `method_`. `_` is on the keyword list for
OCaml's own reason: it is the wildcard pattern rather than a name, so
`let _ = 2` binds nothing and `_` is not an expression. `effect`, a
keyword from OCaml 5.3, is on the list too, so a datatype `Effect` is the
type `effect_`. Everything else reaches the output unchanged.

Neither rule is injective on its own — `mod` and `mod_` both want
`mod_`, and `Foo` and `v_Foo` both want `v_Foo` — and two Pyking names
landing on one OCaml name is a silent substitution rather than a shadow:
whichever `let` came last wins, and the other name reads as it. So the
names are chosen for the **whole program at once**, before anything is
translated (`plan_names`): a name OCaml already accepts keeps its own
spelling, and the rest take the first free `base`, `base2`, ….
`tests/renaming_runtime.pyk` pins both pairs.

### What the compiler would have said

A reader of generated code cannot act on a compiler warning, so the
generator answers them before they are raised. A parameter or local
binding that nothing reads is written `name`, which is OCaml's own way
of saying "deliberately discarded" — and is what such a binding is,
since Pyking's `x = expr` is a statement and a program may well write
one just to run the expression:

```
def nothing(n:Int) -> ():
    ignored = n
```

```ocaml
let nothing n = let _ignored = n in ()
```

The same goes for a top-level binding a later one rebinds: it is neither
read nor exported, which is the one case OCaml complains about at the
top level.

## Floats

OCaml is the closest fit of the five, because it also has one number
type per width and refuses to mix them. A `Float` is an OCaml `float`,
which is the same binary64, and the comparisons and `=` are OCaml's own
polymorphic ones, which on two floats compile to the IEEE primitives —
so `nan = nan` is false there as it is here.

What OCaml *does* spell differently is arithmetic: `+. -. *. /.` for
floats where the plain forms are for ints. This backend already reads
the checker's types, so it picks the spelling from the operand's type
rather than guessing, and `-.` for unary minus by the same rule. Both
sets sit at their usual precedence in the printer, which is what stops
`(a +. b) *. b` losing its parentheses.

`float(n)` and `int(x)` are `float_of_int` and `int_of_float`, and the
second truncates toward zero, which is what Pyking's `int` means.

Printing needs a `pyk_float_str` in the preamble, emitted only where a
Float is printed, implementing `docs/builtin.md`'s rule —
`string_of_float 1.0` is `"1."`, which is not it. A literal is written
by that same rule, since OCaml reads back every text it produces except
the three it spells by name: `nan`, `infinity` and `neg_infinity`, all
`Stdlib.`-qualified so a Pyking module named `Stdlib` could not shadow
them.

One thing to keep in mind when changing this backend: the tail-call pass
synthesizes nodes the checker never saw, so they have no entry in
`tmap`. Asking for the type of an operand must therefore be a total
lookup — an absent entry means an Int, because that pass rewrites calls
and introduces no arithmetic of its own.

## Modules

OCaml names a module after its file and capitalises it, which is Pyking's
own rule with one letter changed, so most of this target needs nothing:
`helper.pyk` is `helper.ml` is the module `Helper`, and `helper.inc`
is `Helper.inc`.

```pyking
# helper.pyk
priv = 3

public def inc(x:Int) -> Int:
    return x + priv


public greeting: String = "hi"
```

```ocaml
(* helper.ml *)
let priv = 3

let inc x = x + priv

let greeting = "hi"
```

```ocaml
(* helper.mli *)
val inc : int -> int

val greeting : string
```

```ocaml
(* program.ml *)
let () =
  print_endline (string_of_int (Helper.inc 1));
  print_endline Helper.greeting
```

**The `.mli` is the privacy**, and it is the whole of it: a name not
listed there cannot be reached from outside the file, which is exactly
what "not `public`" means. It is also the one place this backend writes
a type at all -- everywhere else it emits none, since OCaml infers them.
`interface_type` is what turns the checker's `Type` into OCaml's, and a
type it cannot write is refused rather than guessed at.

**A public name is spelled by a pure function of itself.** Everywhere
else, this backend picks OCaml names for a whole module at once
(`plan_names`), so that no two land on the same one. That cannot work
across a boundary: the module doing the importing has not seen the
module it imports. So an exported name goes through `public_name`,
which looks only at the name, and `plan_names` moves everything else
out of *its* way. Two exported names that would land on one OCaml name
are refused.

**A `from` line writes nothing.** `from helper import inc as bump`
binds no new name here: `bump` simply *means* `Helper.inc`, which is one
fewer binding than the source has and reads better than a `let bump =
Helper.inc` nothing would use twice.

**Order is the link order.** OCaml runs a module's top level when the
program is linked, in the order the files are given, so
`ocamlopt helper.mli helper.ml program.ml` is both the build and the
run order. Nothing is emitted for it.

**A private binding nothing reads is dead**, which it was not before:
without an `.mli`, every top-level binding is exported and none of them
is unused. With one, an unexported binding that nothing in the module
reads would draw warning 32 under `-w +a`, so it gets the `name` this
backend already gives an unread local. The one binding that keeps its
name anyway is a `let rec` whose only reader is itself: renaming it
would leave the call inside it naming nothing.

## Where the output is not optimal

- **`range` builds a list.** `List.init (max 0 n) Fun.id` allocates `n`
  cells so that `len(range(n))` and printing a range work at all. An
  OCaml programmer would write a loop or a sequence; Pyking's `range` is
  a value, so this backend materialises one. The `max 0` is there
  because `List.init` refuses a negative length where `range` answers
  with nothing. Two and three arguments go through `pyk_range`, a
  generated helper, for the same reason `pyk_string_of_int_list`
  exists — there is nothing in `Stdlib` to reach for.
- **Strings are built by concatenation.** `^` allocates a fresh string
  each time, so building text by recursion is quadratic. `Buffer` is
  what OCaml offers instead, and nothing in the Pyking source says which
  concatenations belong to one piece of text.
- **Integers are `int`.** OCaml's native 63-bit integer. A program that
  overflows the signed 32-bit range disagrees with the C and Java
  targets, which stop at 32 — but Pyking leaves that undefined, so
  neither is wrong and nothing is emitted to reconcile them.
- **No optimisation.** The backend is a printer: no constant folding, no
  dead-code elimination. The OCaml compiler does that work afterwards.
- **A guarded pattern binds by position.** `[a, ..rest, b]` walks the
  list once for its length and again for each element, where an OCaml
  programmer would take it apart in one pass. The shape is rare enough
  that the simple translation is the right one.
- **An escape is an exception.** A `return` OCaml has no value spelling
  for costs a `ref` and a local exception, where a hand-written OCaml
  function would be restructured not to need one. Only a body that
  actually holds such a `return` pays for it.

## External modules

A module implemented in OCaml (`sys.ml`, declared in `sys_external.pyk`
-- see [modules.md](modules.md)) needs **no `.mli`**. The compiler
generates nothing for it, and `ocamlopt` infers module `Sys`'s interface
from `sys.ml` itself; the file is copied beside the program's output and
named ahead of it on the command line, as a compiled module would be.

OCaml's own module name comes from the file name, which is exactly what
the generated `Sys.loadfile` refers to -- so nothing is renamed.

**An implementation must qualify every standard-library name it uses.**
A Pyking module compiles to an OCaml module of the same name, and the
generated files sit in the same directory as the copied implementation,
so a program importing a Pyking module named `sys` puts a module `Sys`
on the include path. An unqualified `Sys.argv` in an implementation then
resolves to *that* one and fails to compile — and only once the other
module's `.cmi` is there, so it can compile on a first build and break
on a second, or break only when a program happens to import both.
`Stdlib.Sys.argv` is unambiguous, and `lib/sys/sys_external.ml` and
`lib/fs/fs.ml` are written that way throughout; `Array`, `List` and
`String` are shadowable in exactly the same way.

Build it in the directory the output is in. Passing `-I <dir>` and an
absolute source path from somewhere else lets `ocamlopt` reach one
module by two routes, and it refuses the pair as making "inconsistent
assumptions" over an interface. `src/execution.ml` and the test harness
both run the build in that directory.

An external module has no Pyking top level, so nothing of it runs before
the program's own.

The boundary carries everything this backend does: `Int`, `String`,
`Bool`, unit, tuples and lists, each as OCaml's own.

## Linking unix

Every program on this target is linked with OCaml's `unix` library:

```
ocamlopt -I +unix unix.cmxa -I <dir> -o prog <modules> prog.ml
```

Nothing the compiler *generates* needs it. An external module's own
implementation may: `lib/sys/sys_external.ml` does, because nothing in
OCaml's `Stdlib` enumerates the environment, and
`lib/time/time_external.ml` does, because nothing there reads the clock
as a calendar. Without it neither library would be available here. `unix` ships with the compiler,
so this adds no dependency to install — and it is named before the
modules that use it, since OCaml links in the order it is given.

It is unconditional rather than worked out per program. Deciding would
mean the driver knowing which external implementations need which
libraries, and there is nothing in a declaration file that could say so;
linking a library the program never calls costs a little size and
nothing else.

Passing the flags explicitly also matters for `-w +a`: OCaml 5 moved the
`unix` directory, and a plain `ocamlopt` that finds it anyway does so
through a deprecated auto-include whose alert would fail the suite.

## Let expressions

A `let target = value in body` (PYKING.md, "Let expressions") is compiled as OCaml's own `let target = value in body`, the target the pattern an `=` binding would get.
A call whose named arguments are not in parameter order, with more
than one that has an effect, reaches this backend as nested `let`s
(`docs/desugar_args.md`).
