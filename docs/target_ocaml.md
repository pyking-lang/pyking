# The OCaml target

**Targets in this family:** `ocaml5.5`.

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

- `print`, and the builtins `string`, `len`, `float`, `int` and `range`;
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
- tuples, including a binding that takes one apart;
- `return`, anywhere it can be written;
- lambdas (`x => x + 1`);
- integers, floats, strings and booleans; `+ - * /`, unary minus,
  `++`, comparisons, `==`, and calls.

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
'program.pyk' 3:0-4:7 Unsupported by target 'ocaml5.5': `f` names a
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
'program.pyk' 13:17-13:18 Unsupported by target 'ocaml5.5': printing a
  value of type a
```

### `|` around a `++` split or a list split from its end

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

- **`print` and `debug` are the only things that need a type.** Pyking's `+` and
  `++` map straight onto OCaml's `+` and `^`, so nothing has to ask an
  operand's type to choose between them.
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
into `loop`s for every other target, is skipped for `ocaml5.5` (see
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
which is what the loop is worth. A loop carrying several values takes a
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
    "reached " ++ string(reached)
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

- **a `++` pattern over a string.** OCaml's patterns do not split a
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
it was applied to. A field read is a `match` with one arm per
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
"Builtins").

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

`debug` is the same line through `prerr_endline`, on standard error. A
program compiled with `--release` has no `debug` left in it. The checker
records a type for a callee it resolved to a definition and none for a
builtin, which is how a program's own `debug` is told from the builtin.

### Builtins

| Pyking | OCaml |
|---|---|
| `string(n)` | `string_of_int n` (or `string_of_bool`, or nothing at all for a `String`) |
| `len(s)` | `String.length s` |
| `len(xs)` | `List.length xs` |
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
them. `tests/evaluation_order.pyk` is the case that pins this down; it
runs on every target that supports it, and one `.out` has to serve them
all.

### Names

An OCaml value name must start with a lowercase letter or an underscore
and must not be a keyword, so a Pyking `Total` becomes `v_Total` and a
Pyking `method` becomes `method_`. `_` is on the keyword list for
OCaml's own reason: it is the wildcard pattern rather than a name, so
`let _ = 2` binds nothing and `_` is not an expression. Everything else
reaches the output unchanged.

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
