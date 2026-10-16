# The C targets

**Targets in this family:** `c89`, `c23`.

**Key points**

- One backend, `src/target_c.ml`, with a `standard` parameter. The two
  targets translate *identically*; only the printer differs, in four
  places: comments, where declarations may appear, how booleans are
  spelled, and which headers are needed.
- C is statically typed and Pyking is not, so this backend **infers
  types** — `Int`, `String`, `Bool` — for every binding, parameter and
  function. That inference is what most of the unsupported list comes
  from.
- What the top level binds is a file-scope variable, so a function
  reads it as Pyking says it may, and a top-level `def` is a value: a
  pointer to the C function, which may be bound, passed and handed to an
  external module as a callback. A nested `def` and a lambda are not:
  C has no closures.
- Output is one `.c` file with no dependencies beyond the C standard
  library, and only the headers the program actually uses.
- `/` is C's own `/`: Pyking divides integers truncating toward zero,
  which is what C has done since C99.
- Least optimal at: string concatenation, which allocates and never
  frees.

Verified with `gcc -pedantic -Wall -Wextra` under both standards, plus
`-Wdeclaration-after-statement` for C89.

## The two targets

| | `c89` | `c23` |
|---|---|---|
| comments | `/* … */` | `// …` |
| declarations | hoisted to the top of each block | where they appear |
| booleans | `int`, `1`/`0` | `bool`, `true`/`false` |
| headers | only what is used | only what is used, and never `<stdbool.h>` |

C23 still needs `<stdio.h>` for `printf` — it removed the need for *some*
headers, not for all of them — so "avoid headers when not needed" means
each file includes exactly what its program uses. A program that only
prints an integer never sees `<string.h>`.

Everything else is shared: one translation, one AST, one set of type
rules, one printer with four `if standard ==` branches in it.

## What is supported

`print`; `def` with parameters, `return` and recursion, its body
written under the header or on the header's own line (`def f(x): e`);
`if` / `else if` / `else`;
`while`; `loop` with `break` and `continue`; `=`, `var`, `:=`; `if … then … else …` expressions;
integers, strings and booleans; `+ - *`, unary minus, comparisons, and
calls; a function reading or writing what the top level bound; and a
top-level `def` as a value -- bound, passed, called through and handed
to an external module. Tail position, `return if c:`, and unit-returning
(`void`) functions are supported too — see below.

Type annotations are *used* here rather than erased, when they name a
type C can represent.

## What is not supported

Everything the JavaScript targets refuse — lists, tuples, `for`,
`match`/`case`, comprehensions, value-form bindings, `len`/`range`
— plus the following, each because C demands an answer Pyking never had
to give. All are refused at compile time with a source position.

### A `loop` C cannot give a value

```
Unsupported by target 'c23': a loop worth `()` -- a loop with no
accumulator is worth unit, and C has no value for one; carry the value
the loop is for, or run the loop for what it does rather than what it
is worth
```

A loop with no accumulator *runs* here perfectly well -- it is a
`while (1)` or a `while (c)` like any other -- but it is worth unit, and
C has no value for one, so only a program that wants its *value* is
refused. Two more shapes are refused for the same want of a value: a
loop carrying several slots, whose value would be the tuple of them, and
an `if` with no `else` as the *last* statement of a loop body, which
leaves a turn with nothing to hand on. And a loop body ending in
something that produces no value —
a binding, a `while` — says nothing about the next turn either. Each is
a case Pyking answers with `()`; here it is refused instead, with the
position of the statement that produced nothing.

A tuple accumulator is refused too, for the ordinary reason: this
backend has no tuples.

### Lambdas

```
Unsupported by target 'c23': lambdas, which C has no closures for
```

A lambda is an anonymous function that closes over what is bound where
it is written, and both halves are out of reach: C has no anonymous
functions and no closures. A top-level `def` is the way to write a
function that is passed somewhere: it is a C function, and a pointer to
it is the value ("Functions as values", below).

### Nested `def`

```
Unsupported by target 'c23': a nested function -- C has no nested
functions, and one reading its enclosing scope could not be hoisted to
file scope without closures
```

C has no nested functions. Hoisting one to file scope works only if it
reads nothing from around it but the top level — which is to say, only
without closures.

A **default parameter** is compiled as a generated `def` in the block
the definition stands in (docs/desugar_args.md), so one written at the
top level reads what the top level bound like any other function:

```pyking
size = 10
def scaled(x: Int = size) -> Int: x * 2     # fine: `size` is file scope
def step(n: Int = 1) -> Int: n * 10         # fine: a literal
```


### `:=` that changes a variable's type

```pyking
var v = 1
v := "text"     # rejected
```

A C variable has one type for its whole life. Note this restricts `:=`
only: rebinding with `=` is fine, because that is a *new* binding and
gets a new C variable, which may well have a different type.

### Type mismatches C cannot bridge

- `if … then … else …` whose branches differ in type — C's `?:` needs one
  type on both arms.
- `==` between different types — likewise.
- `+` or `++` mixing an integer and a string.
- A list, in any form -- a literal, a comprehension, or a pattern. C has
  no value model for one, and Pyking has no garbage collector, so a
  representation would have to answer a question this backend has not
  been asked yet. `match` over a scalar *is* supported, as an if/else
  chain over the subject.
- A type variable in an annotation (`def id(x:a) -> a`). C needs one
  concrete type per function, and this backend infers no polymorphism,
  so guessing `Int` would compile a call at any other type into code
  that is quietly wrong.

### A function that produces a value on some paths and none on others

```
Unsupported by target 'c23': `f` produces a value on some paths and none
on others; C has one return type per function, and falling off the end of
a non-`void` one is undefined behaviour, so give every path a value (an
`if` needs its `else`)
```

An `if` with no `else` whose branch ends in an expression gives one path
a value and leaves the other with unit. C has a single return type per
function and no way to say "or nothing", and falling off the end of a
non-`void` function is undefined behaviour -- the compiler will happily
build a program that returns whatever was in the return register. This
is the same rule `target_java.ml` enforces because `javac` demands it;
here it is enforced because the C standard does *not*.

### A recursive or forward-called function returning non-`Int` without an annotation

```
Unsupported by target 'c23': `f` calls itself and does not return Int; a
recursive function's return type is assumed Int unless annotated, so
annotate it (`-> String`, `-> Bool`)

Unsupported by target 'c23': `g` is called before it is defined and does
not return Int; a call written above a `def` is typed from the
annotation, or Int without one, so annotate the return type
(`-> String`, `-> Bool`)
```

A signature must exist before the call can be translated, and for a
function whose body has not been read yet the return type can only come
from its annotation — so without one it starts as `Int`. Adding
`-> String` or `-> Bool` resolves both.

### A function over functions, as a value

```
Unsupported by target 'c23': `apply` is used as a value and itself takes or answers a function -- C has a type for a function over values, and none for one over functions
```

A function value is a pointer to a C function over values ("Functions
as values", below). One whose own parameters or result are functions
would need a pointer type naming another, which the typedefs this
backend writes do not cover; calling such a function is fine, using it
as a value is not.

### Forward references and mutual recursion

These are supported. Pyking lets a function be used before it is written
(see PYKING.md, "Names and scoping"), so this backend registers every
top-level `def`'s signature before translating any body, and prints a
**prototype for every function** ahead of the definitions:

```c
/* Declared ahead of their definitions: a Pyking function may be called
   before it is written. */
int is_even(int n);
int is_odd(int n);
```

Prototypes are emitted for all of them rather than only those that need
one, so the output does not depend on the order the definitions happen
to be in — which is what the language says does not matter.

## The top level

Pyking's functions may read, and `:=` may write, what is bound where
they are written (PYKING.md, "Names and scoping"), and a function here
is always written at the top level -- a nested `def` is refused above.
So what the top level binds is a **file-scope variable**, declared
`static` above the functions and assigned where the binding is:

```pyking
canvas = tw.canvas(400, 200)
var presses = 0

def play_sound():
    presses := presses + 1
    print("snare, press " ++ string(presses))
```

```c
static int canvas;
static int presses;

static void play_sound(void)
{
    presses = presses + 1;
    printf("%s\n", pyk_concat("snare, press ", pyk_int_str(presses)));
}

int main(void)
{
    canvas = tinyweb_canvas(400, 200);
    presses = 0;
    ...
}
```

A rebinding is a variable of its own (`canvas2`), as it is in a block,
so a function keeps the value it was written after. A block's bindings
stay locals: no function can see them. A Pyking program never reads a
binding before it is made, so the zero C gives a file-scope variable is
never seen.

## Functions as values

A top-level `def` used as a value is a **pointer to the C function**,
and a function type is written through a typedef named for its shape --
one letter per parameter, then one for the result (`i`, `f`, `b`, `s`,
`v` for unit):

```c
#ifndef PYK_FN_II_V
#define PYK_FN_II_V
typedef void (*pyk_fn_ii_v)(int, int);
#endif
```

Each is guarded, so a module's header and the file including it may
both carry one. A parameter annotated with a function type is such a
pointer, and calling it is an ordinary C call:

```pyking
def twice(f: (Int) -> (), n: Int):
    f(n)
    f(n)
```

```c
static void twice(pyk_fn_i_v f, int n)
{
    f(n);
    f(n);
}
```

That is also what an external module is handed for a callback, so its
implementation declares the parameter as a plain function pointer --
`void (*on_click)(void)` -- and calls it. A function type is one over
values: its parameters are each a value and its result a value or unit,
which covers everything a callback may be (modules.md, "What may cross
the boundary"). Only a top-level `def` can be one, since neither a
nested `def` nor a lambda exists here; a parameter's function type must
be written down, as the type of an unannotated parameter is inferred
from what the body does with strings and numbers.

## How types are inferred

Four types — `Int`, `Float`, `String`, `Bool` — and three rules:

1. A **binding** takes the type of its initializer.
2. A **parameter** takes its annotation when that annotation names a type
   C can represent; otherwise it is inferred from whether the body
   concatenates or compares it with a string, or combines it with a
   float literal, and failing both of those it is `Int`.
3. A **function's return type** is read back off its translated body.

Annotations naming a tuple, list or function type are *ignored* rather
than rejected. An ordinary compile checks no annotation, and
`tests/types_tuples.pyk` annotates parameters as tuples and then passes
integers — so inference is the more truthful reading of such a program.
A parameter annotated `(Int) -> Int` is the same story with a sharper
end: the annotation is dropped, and what stops the program is the
*call* through that parameter, refused as `call to unknown function`,
since C has no value a `def` can become here.

*Not optimal:* rule 2 is a guess. A program that passes a string to an
unannotated parameter which the body only ever returns unchanged will
infer `Int` and emit C that does not compile. Annotating the parameter
fixes it, and a real inference pass (unifying uses across call sites)
would remove the guess entirely.

Because the guess can be wrong, **every argument is checked against the
parameter type this backend worked out**, and a mismatch is refused with
the position of the call. That matters most for numbers: C converts
between an `int` and a `double` without a word, so an argument at the
wrong type would compile and be quietly wrong, where an `Int` passed
where a `String` was inferred at least fails to build. A refusal here
means this backend could not work the type out, not that the program is
ill-typed — the checker accepted it, and every other target compiles it.

## Floats

A `Float` is a `double`, which both standards spell the same way — so
unlike a `Bool` it needs nothing to serve `c89` and `c23` alike.
Arithmetic, the comparisons and `==` are C's own, which are IEEE's, and
`/` is C's `/` unchanged: on two doubles it is not truncated, and a zero
divisor gives an infinity or a NaN rather than failing. `float(n)` and
`int(x)` are casts, and C's narrowing cast truncates toward zero, which
is the rounding Pyking's `int` means.

Printing is the part with no host answer. No `printf` conversion writes
a double the way Pyking does, so a `%s` is emitted and the value goes
through a generated `pyk_float_str` implementing `docs/builtin.md`'s
rule. Three things about it are worth knowing:

- It is written to **C89**, which has neither `isnan` nor `isinf`: a NaN
  is found with `x != x` and an infinity against `DBL_MAX` from
  `<float.h>`.
- It **allocates and never frees**, exactly as `pyk_concat` does. One
  static buffer would be shorter and wrong: `printf` with two Floats in
  it calls this twice before printing either, and both calls would hand
  back the same text.
- `<math.h>` is included **only** for a literal that overflowed to an
  infinity, which needs `HUGE_VAL`. It is kept out otherwise because
  that header declares a great many functions with short names — glibc's
  `fadd` among them — that an ordinary Pyking `def` is free to be
  called.

## How things compile

### The same program, both standards

```pyking
def sign(n): if n < 0 then "neg" else "pos"


def classify(n):
    if n < 0:
        return "low"
    else if n == 0:
        return "zero"
    else:
        return "high"


var i = 0
while i < 2:
    print(sign(i), classify(i), "a" == "b")
    i := i + 1
```

`c23`:

```c
// Generated from prog.pyk by the Pyking compiler. Do not edit.
// Target: c23. Compile with:  cc -std=c23 <this file>

#include <stdio.h>
#include <string.h>

const char *sign(int n)
{
    return n < 0 ? "neg" : "pos";
}

const char *classify(int n)
{
    if (n < 0) {
        return "low";
    } else if (n == 0) {
        return "zero";
    } else {
        return "high";
    }
}

int main(void)
{
    int i = 0;
    while (i < 2) {
        printf("%s %s %s\n", sign(i), classify(i), strcmp("a", "b") == 0 ? "true" : "false");
        i = i + 1;
    }

    return 0;
}
```

`c89` differs only in the comment syntax here — no declaration follows a
statement in this program, so nothing needs hoisting:

```c
/* Generated from prog.pyk by the Pyking compiler. Do not edit. */
/* Target: c89. Compile with:  cc -std=c89 <this file> */
```

Top-level Pyking statements become the body of `main`; `def`s become
file-scope functions, in source order — which works because the name
analysis already requires definition before use.

### Declaration hoisting (`c89`)

C89 allows declarations only at the start of a block, so the printer
splits each declaration from its initialization and lifts the
declarations to the top. Because every binding already has a name of its
own, hoisting cannot capture the wrong variable:

```pyking
def gcd(a, b):
    var x = a
    var y = b
    while x > 0:
        if x < y:
            var swap = x
            x := y
            y := swap
        x := x - y
    return y
```

`c23` keeps each declaration where the source put it:

```c
int gcd(int a, int b)
{
    int x = a;
    int y = b;
    while (x > 0) {
        if (x < y) {
            int swap = x;
            x = y;
            y = swap;
        }
        x = x - y;
    }
    return y;
}
```

`c89` splits every declaration from its initialization and lifts the
declarations — note the inner block gets its own, since C89 allows them
at the start of *any* block:

```c
int gcd(int a, int b)
{
    int x;
    int y;

    x = a;
    y = b;
    while (x > 0) {
        if (x < y) {
            int swap;

            swap = x;
            x = y;
            y = swap;
        }
        x = x - y;
    }
    return y;
}
```

### Tail position and unit (`void`)

A function body's last statement supplies its value (see "Tail position"
in PYKING.md), so a `return` is pushed down into it, recursively through
`if` branches. This matters more here than in the other backends:
without it a body ending in a bare expression compiled to a non-`void`
function that simply fell off its end, which is **undefined behaviour**,
not merely a dropped value.

```pyking                          /* generated C */
def pick(x, y, z):                 int pick(int x, int y, int z)
    if z > 5:                      {
        x + y              ->          if (z > 5) {
    else:                                  return x + y;
        2 * x                          } else {
                                           return 2 * x;
                                       }
                                   }
```

A function that returns no value on any path has Pyking's unit type,
which C spells `void` -- a body whose tail is a `print` (which yields
unit), a loop, or a binding:

```pyking                          /* generated C */
def announce(label: String, n):    void announce(const char *label, int n)
    print(label, n)        ->      {
                                       printf("%s %d\n", label, n);
                                   }
```

A `void` call has no value to use, so calling one anywhere but as a
statement of its own is refused with a source position rather than
emitted as C that will not compile.

### `loop`, `break` and `continue`

A `loop` is `while (1)` over one mutable variable holding the
accumulator. The initializer declares it — and its C type is the
initializer's, by the ordinary inference rule — every tail of the body
assigns the next turn's value, and `break`/`continue` are C's own,
operand and all: they have none.

```pyking                          /* generated C */
res = loop x = 5:                  int x = 5;
    if x <= 10:                    while (1) {
        x + 1                          if (x <= 10) {
    else:                                  x = x + 1;
        break                          } else {
                                           break;
                                       }
                                   }
                                   int res = x;
```

`while (1)`, not `while (true)`: c89 has no `bool`, and this is the
spelling both standards read the same way.

A loop carrying **several values** gets one variable per slot, and the
next turn's values go through temporaries so that a slot reading another
sees the turn it is still on:

```pyking                          /* generated C */
loop n, acc = n, acc:              int n = ...; int acc = ...;
    if n == 0:                     while (1) {
        break                          if (n == 0) { break; }
    else:                              { int n_next1 = n - 1;
        (n - 1, n * acc)                 int acc_next1 = n * acc;
                                         n = n_next1; acc = acc_next1; }
                                   }
```

Such a loop is worth all its slots at once, and C has no tuple to hold
that — so a program that wants its *value* is refused, while one that
runs it for what it does (the shape every accumulator-passing function
has after the tail-call pass, whose every exit is a `return`) compiles
here. Since a turn may only carry one C type per slot, a next-turn value
of a different type is refused rather than silently converted.

A `while c` has a second way to stop — **running out** — and the loop is
worth its accumulator then, exactly as it is when it breaks: the slots
already hold it, so nothing has to be put anywhere. C has no loop
`else`, and this backend needs none: the exhaustion test is one it
writes itself, `if (!c) break;` at the top of a `while (1)`.

A `while (1)` no `break` leaves is a loop that never finishes, so
`falls_through` (see "A function that produces a value on some paths
and none on others") counts a function ending in one as returning —
there is no path off the end to worry about.

### Names that are keywords in C

A name can be a good Pyking identifier and a reserved word in C --
`double`, `struct`, `static`, `void`, `char`, `sizeof`, and the rest.
Such a name is renamed by the same mechanism that handles shadowing:

```pyking                          /* generated C */
def double(n):                     int double2(int n)
    n * 2                  ->      {
                                       return n * 2;
                                   }
```

The list (`reserved` in `src/target_c.ml`) is one list for both
standards -- C89 plus the C99/C11/C23 additions -- since a name renamed
under `c23` but not `c89` would make the two targets disagree about the
generated code for no good reason. It also holds `main`, `printf`,
`strcmp` and the generated helpers: not keywords, but a Pyking function
shadowing one would break the file just as thoroughly. So does
everything the headers this backend includes declare at file scope
(`library_names`): a function or a top-level binding called `remove`,
`puts` or `y1` would be declared over `<stdio.h>`'s or `<math.h>`'s.

### Booleans

`true`/`false` literals translate directly to `CBool`, printed by
`bool_literal` as whichever spelling the standard uses (`1`/`0` for
c89, `true`/`false` — real keywords, no `<stdbool.h>` needed — for c23).
*Printing* a boolean is a separate concern from representing one: Pyking
prints booleans `true`/`false` too, but neither C standard spells its own
`Bool` representation that way on its own (c89's is just `int`; c23's
`bool` prints via `%d`, `1`/`0`, same as c89), so a printed boolean always
becomes a conditional expression regardless of standard:

```c
int negate(int flag)      /* c89 */
bool negate(bool flag)    // c23

printf("%s\n", negate(1 < 2) ? "true" : "false");   /* both */
```

(For c23 this means a boolean's *value* representation and its *printed*
spelling happen to agree — both `true`/`false` — but the conditional
expression is still there, generated the same way for both standards,
since the printer doesn't special-case c23 to skip it.)

### `print`

Types are known statically, so each call becomes one `printf` with a
format string built at compile time — `%d` for integers, `%s` for
strings, and `%s` plus a ternary for booleans:

```pyking                          /* generated C */
print(1, "two", 3 < 4)             printf("%d %s %s\n", 1, "two", 3 < 4 ? "true" : "false");
debug("n", 2)                      fprintf(stderr, "%s %d\n", "n", 2);
```

The conversions go by the argument's type. C's own are used where they
agree -- a cast widens an int, and `b ? 1 : 0` is a Bool -- and `bool`
is a comparison (`strcmp(s, "true") == 0`, `n == 1`). `string` of an
Int is `pyk_int_str`, of a Float the `pyk_float_str` `print` uses, of a
Bool a conditional. A String goes through `pyk_int_of_string` and
`pyk_float_of_string`, and `int` of a double through `pyk_truncate`:
static helpers emitted only where used, reading the text by hand, since
`strtol` skips spaces and reads hex. C89 has no `NAN`, so NaN is
`HUGE_VAL - HUGE_VAL`.

`debug` is the same call on `stderr`. A program compiled with
`--release` has none left, and a `debug` that was a block's last
statement, where its block's value is used, is left as the statement
`()` -- which this backend compiles to nothing. A program's own
definition named `print` or `debug` is an ordinary call: the builtin is
the name only where no signature of the program's claims it.

### Strings

`const char *`. Equality goes through `strcmp`; concatenation calls a
generated helper:

```c
static const char *pyk_concat(const char *a, const char *b)
{
    size_t la = strlen(a);
    size_t lb = strlen(b);
    char *result = malloc(la + lb + 1);
    memcpy(result, a, la);
    memcpy(result + la, b, lb + 1);
    return result;
}
```

The helper is written in the subset both standards accept, so one copy
serves `c89` and `c23` alike.

### Evaluation order

Pyking evaluates an operator's operands, and a call's arguments, left to
right. C leaves both unspecified, and compilers really do differ: on
x86-64, `gcc` and `clang` evaluate a call's arguments right to left,
while on AArch64 they evaluate them left to right. That is invisible
unless two of them *print*, so the backend works out which expressions
can print — `analyses.Effects`, the same walk of the call graph the
OCaml backend uses — and pins those down.

C's one construct that fixes an order inside an expression is the comma
operator, so `in_order` pulls every printing operand but the last into a
temporary and puts the assignments in front of the result:

```
called = add(step("f", 10), step("g", 20))
```

```c
called = (tmp1 = step("f", 10), add(tmp1, step("g", 20)));
```

The temporaries are declared at the top of the function they appear in
(`tmp1`, `tmp2`, ..., with a prefix `unused_prefix` guarantees the
program does not use), never beside the statement that needs them: an
operand written in a `while` condition is evaluated again every turn,
and one written in a branch of an `if` expression only when that branch
is chosen, so the assignment has to stay inside the expression it
belongs to. Ordering a *statement's* pieces in front of it would be
wrong in both places, which is why the comma operator does the work
rather than a hoisted statement. The one exception is `print`, which is
a statement here and so can put its assignments before itself:

```
print(step("l", 1), step("m", 2))
```

```c
tmp7 = step("l", 1);
printf("%d %d\n", tmp7, step("m", 2));
```

A program whose functions only compute — nearly every program — has
nothing to order, and its operands stay exactly where the source put
them; no temporary is declared and the output is byte for byte what it
was. `tests/evaluation_order.pyk` pins the straight-line cases down and
`tests/evaluation_order_branches.pyk` the two conditional ones; one
`.out` serves every target.

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

- **Concatenation leaks.** `pyk_concat` allocates and never frees, so a
  program leaks everything it concatenates. Pyking has no notion of
  ownership to compile into a `free`, and adding one means either a
  garbage collector, reference counting, or a lifetime analysis. This is
  the main thing standing between this and a serious C backend.
- **Integers are `int`.** No width control, no overflow behaviour beyond
  C's, and no bignum — Python's integers are arbitrary precision, so a
  Pyking program that overflows will disagree with the Python target.
- **Parameter inference is a guess** for unannotated parameters (above).
- **Ordering temporaries read as C, not as the source.** A comma
  expression is legal and correct C, but `(tmp1 = step("f", 10),
  add(tmp1, step("g", 20)))` is not what a person would write. A
  smarter backend would hoist the assignment to the statement in front
  of it wherever the expression is evaluated exactly once there, and
  keep the comma only for the `while` conditions and `if` expression
  branches that need it.
- **`-Wextra` finds unused variables and parameters.** Those are faithful
  translations — the Pyking programs really do bind names they never use
  — but a smarter backend would drop dead bindings rather than emit them.
- **No optimisation.** The backend is a printer: no constant folding, no
  dead-code elimination, no tail calls. The C compiler does that work
  afterwards, which is a large part of why targeting C is attractive.

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

The boundary carries what this backend carries: `Int`, `Float`, `String`,
`Bool` and unit. A declaration naming a tuple or a list is refused where a
program imports it, before anything is translated -- C has neither.
Only what a program uses is declared, and only what it uses of a
library is compiled at all ([modules.md](modules.md), "What a program
uses"), so `sys.exit` compiles here while `sys.args` is refused.

**A module in two halves** is compiled too. Its generated file declares
the names its own declaration half provides, so its Pyking half calls
them as `<module>_<field>`, and a file importing it declares the ones it
takes. `io` and `sys` are both, and `tests/module_external_mixed.pyk`
is the worked example.

**A declaration taking a callback** takes a pointer to a C function
("Functions as values"), so the program hands it a top-level `def`, which
reads what the top level bound through file-scope variables.
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
