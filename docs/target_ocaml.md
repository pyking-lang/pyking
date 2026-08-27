# The OCaml target

**Targets in this family:** `ocaml`.

**Key points**

- One backend, `src/target_ocaml.py`. It is the only one whose supported
  subset is not a list of constructs but a *stage*: it compiles exactly
  what `src/typesystem.py` accepts, and it compiles it by **running the
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

Verified with `ocamlfind ocamlopt -w +a`, every warning on: the target's
promise is clean OCaml, so a warning is a failing test rather than a
note. See "What the compiler would have said" below.

## What is supported

Exactly the fragment `src/typesystem.py` checks, no more and no less:

- `print`, and the builtins `str`, `len` and one-argument `range`;
- `def` with fully annotated parameters and return type — recursion,
  mutual recursion, nested functions, and a body written on the header's
  own line (`def f(x): e`);
- functions as values: passed as arguments, returned, and called;
- `=` bindings, including ones that shadow;
- `if` / `else if` / `else`, in statement form and in value form
  (`x = if c:`), and `if … then … else …` expressions;
- `loop` with `break` and `continue`, in every position a value stands;
- tuples, including a binding that takes one apart;
- `return`, in tail position or as a guard;
- integers, strings and booleans; `+ - *`, comparisons, `==`, and calls.

The annotations a `def` must carry are the type checker's requirement,
not this backend's — but they are what makes it possible to emit OCaml
with none.

## What is not supported

Everything the type checker does not cover is refused before translation
begins, with the checker's own message framed as this target's
limitation:

```
$ pyk compile -t ocaml program.pyk
'program.pyk' 1:0-1:9 Unsupported by target 'ocaml': this target
  compiles only programs that type-check, and this one does not:
  Construct is not supported
```

That covers `var` and `:=`, `for`, `while`, `match`/`case`, lists,
comprehensions, `/`, unary minus, and any `def` missing an annotation. Passing `--typecheck` is not required and changes nothing:
the check happens either way.

Two further things the checker accepts and this backend still refuses,
each because OCaml has no way to say it.

### A `return` that is neither in tail position nor a guard

OCaml expressions have no early exit. A `return` at the end of a body is
just that body's value, and a `return` guarding the rest of a function
is an `if … then … else …` with the rest in the `else` — so both of
these compile:

```
def clamp(n:Int) -> Int:
    if n < 0:
        return 0
    n * 2
```

```ocaml
let clamp n = if n < 0 then 0 else n * 2
```

A `return` anywhere else — in the middle of a body with statements after
it that are not the alternative — has no OCaml spelling, and is refused
rather than approximated. Inside a `loop` there is one more case: a loop
is a local function here, so returning from it and returning from the
*enclosing* function are two different things. They coincide exactly
when the loop is the function's own value, which is where a `return` in
a loop body compiles; anywhere else — a loop whose value is bound, and
so wanted where it stands — it is refused:

```
'prog.pyk' 16:12-16:28 Unsupported by target 'ocaml': a `return` inside
  a loop that is not the function's own value: OCaml has no early exit,
  and this loop's value is wanted where it stands, so returning from it
  cannot leave the function too
```

### A `break` or `continue` that is neither in tail position nor a guard

The same rule, for the same reason. `break` in tail position is the
value the loop function returns and `continue` there is its tail call,
and either one guarding the rest of the body is an `if … then … else …`
with that rest in the `else` — which covers the shapes a loop is
normally written in, since a statement written *after* an unconditional
`break`/`continue` is a parse error to begin with (see PYKING.md). What
is left is a `break` inside an `if`/`else` neither arm of which leaves,
with statements after it; that would need the rest of the body
duplicated into every branch, and is refused instead.

### A `def` naming one written further down, with something in between

Pyking makes every `def` in a block visible throughout it, wherever it is
written. OCaml expresses that with `let rec … and …`, which binds a
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

But a statement between them breaks the group:

```
y = 1

def f() -> Int:
    g()

y = 2

def g() -> Int:
    y
```

```
'program.pyk' 3:0-4:7 Unsupported by target 'ocaml': `f` names `g`,
  which is written further down with something in between: OCaml binds
  a group of mutually recursive functions with `let rec ... and ...`,
  which has to be written together
```

Moving the group down past `y = 2` would compile, but it would change
which binding of `y` the bodies see — Pyking's capture is positional
(see [../PYKING.md](../PYKING.md), "Names and scoping") — so the backend
refuses instead of quietly changing the program's meaning. Writing the
two `def`s next to each other is the fix.

## How the type checker is reused

`type_check(stmts)` returns a `tmap`: symbol → type, with an entry for
**every expression**, not just the ones an annotation could be written
on. This backend is the reason that is true. Two decisions need it:

- **`print` is the only thing that needs a type.** Pyking's `+` and
  `++` map straight onto OCaml's `+` and `^`, so nothing has to ask an
  operand's type to choose between them.
- **Type variables need nothing, up to a point.** This backend writes no
  type annotations, and OCaml generalizes what a `let` binds, so a
  polymorphic Pyking function becomes a polymorphic OCaml one by itself
  -- `def id(x:a) -> a` is `let id x = x`, usable at every type its
  Pyking original was. A polymorphic *parameter* is where that stops:
  OCaml does not generalize one, and taking a function used at two types
  inside a body needs an explicit `'a.` annotation this backend does not
  write, so such a `def` is refused with a source position.
- **`print` formats by type.** An `Int` argument becomes
  `string_of_int e`, a `Bool` becomes `string_of_bool e`, a `String` is
  written as it is, unit becomes `"()"`, and a list of `Int` goes
  through the one generated helper.

`src/target_c.py` and `src/target_java.py` each carry their own
inference, written before the checker existed and answering a narrower
question (which C or Java type does this need to be declared as). This
backend does not, which is most of the reason it is the shortest of the
four.

## How things compile

### Blocks and bindings

A Pyking block is a scope and OCaml's `let … in` is a scope, so the
translation is direct. Nothing is renamed — `target_python.py` renames
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
program as written: `src/optimization.py`, which turns tail recursion
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

`NATIVE_TAIL_CALLS` in `src/pyk.py` is the list that says so; a backend
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
        continue x + 1
    else:
        break
```

```ocaml
let res =
  let rec _pyk1 x = if x <= 10 then _pyk1 (x + 1) else x in
  _pyk1 5
```

The four ways a body can say what happens next map one to one: the
body's last expression and `continue e` both become `_pyk1 e`, a bare
`continue` becomes `_pyk1 x`, `break e` becomes `e`, and a bare `break`
becomes `x`. A loop carrying several values takes a tuple pattern
parameter, `let rec _pyk1 (x, y) = …`, and a `loop:` carrying nothing
takes a unit one.

Because a loop is an expression, it needs nothing said about it in any
of the positions a value can stand: bound with `=`, returned, or as a
function's last statement. `rec` is emitted only when the body really
does call the loop function — a loop that always breaks does not — since
`ocamlfind ocamlopt -w +a` treats a needless `rec` as an error.

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
    (let (_pyk1, _pyk2) = pair in
     "(" ^ string_of_int _pyk1 ^ ", " ^ string_of_bool _pyk2 ^ ")")
```

A string inside a tuple is quoted, where one printed on its own is not,
so a `pyk_quote` helper joins the prelude when a program needs it (see
"Builtins").

### `print`

`print_endline`, with the arguments formatted per
[runtime_interface.py](../src/runtime_interface.py) and joined with a
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

### Builtins

| Pyking | OCaml |
|---|---|
| `str(n)` | `string_of_int n` (or `string_of_bool`, or nothing at all for a `String`) |
| `len(s)` | `String.length s` |
| `len(xs)` | `List.length xs` |
| `range(n)` | `List.init n Fun.id` |
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
let sum = let _pyk1 = step "a" 1 in _pyk1 + step "b" 2
```

A program whose functions only compute — nearly every program — has
nothing to order, and its operands stay exactly where the source put
them. `tests/evaluation_order.pyk` is the case that pins this down; it
runs on every target that supports it, and one `.out` has to serve them
all.

### Names

An OCaml value name must start with a lowercase letter or an underscore
and must not be a keyword, so a Pyking `Total` becomes `v_Total` and a
Pyking `method` becomes `method_`. Everything else reaches the output
unchanged.

### What the compiler would have said

A reader of generated code cannot act on a compiler warning, so the
generator answers them before they are raised. A parameter or local
binding that nothing reads is written `_name`, which is OCaml's own way
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

## Where the output is not optimal

- **`range` builds a list.** `List.init n Fun.id` allocates `n` cells so
  that `len(range(n))` and printing a range work at all. An OCaml
  programmer would write a loop or a sequence; Pyking's `range` is a
  value, so this backend materialises one. Only the one-argument form is
  supported.
- **Strings are built by concatenation.** `^` allocates a fresh string
  each time, so building text by recursion is quadratic. `Buffer` is
  what OCaml offers instead, and nothing in the Pyking source says which
  concatenations belong to one piece of text.
- **Integers are `int`.** OCaml's native 63-bit integer, so a program
  that overflows disagrees with the Python target, whose integers are
  arbitrary precision. The C and Java targets have the same gap, at
  32 bits.
- **No optimisation.** The backend is a printer: no constant folding, no
  dead-code elimination. The OCaml compiler does that work afterwards.
- **The subset is the checker's.** Everything the checker does not cover
  yet — `for`, `while`, `match`, lists as a language feature, `var` —
  would translate comfortably into OCaml, in some cases more directly
  than into any other target here. It is the front end that has not
  reached them, not this backend.
