# The C targets

**Targets in this family:** `c89`, `c23`.

**Key points**

- One backend, `src/target_c.py`, with a `standard` parameter. The two
  targets translate *identically*; only the printer differs, in four
  places: comments, where declarations may appear, how booleans are
  spelled, and which headers are needed.
- C is statically typed and Pyking is not, so this backend **infers
  types** — `Int`, `String`, `Bool` — for every binding, parameter and
  function. That inference is what most of the unsupported list comes
  from.
- Output is one `.c` file with no dependencies beyond the C standard
  library, and only the headers the program actually uses.
- `/` is **not supported**: Pyking's division is Python's (`7 / 2` is
  `3.5`) and C's truncates. This is the only feature the JavaScript
  targets have and these do not.
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

`print`; `def` with parameters, `return`, recursion, and the
single-expression `def f(x) = e` form; `if` / `else if` / `else`;
`while`; `loop` with `break` and `continue`, where the loop carries an
accumulator; `=`, `var`, `:=`; `if … then … else …` expressions;
integers, strings and booleans; `+ - *`, unary minus, comparisons, and
calls. Tail position, `return if c:`, and unit-returning (`void`)
functions are supported too — see below.

Type annotations are *used* here rather than erased, when they name a
type C can represent.

## What is not supported

Everything the JavaScript targets refuse — lists, tuples, `for`,
`match`/`case`, comprehensions, value-form bindings, `str`/`len`/`range`
— plus the following, each because C demands an answer Pyking never had
to give. All are refused at compile time with a source position.

### `/`

```
$ pyk compile -t c23 divide.pyk
'divide.pyk' 1:6-1:11 Unsupported by target 'c23': `/` is true
  division in Pyking and truncating integer division in C; matching it
  needs a floating-point type this backend does not have yet
```

Pyking's `7 / 2` is `3.5`; C's is `3`. Unlike the JavaScript targets,
where only the *printed form* differs, here the **value** would be wrong.
Producing the right one needs a floating-point type throughout, and
printing it the way Python does needs a float-repr routine; neither
exists yet, so `/` is refused rather than quietly computing something
else.

### A `loop` C cannot give a value

```
Unsupported by target 'c23': a `loop` with no accumulator -- C has no
value to give it, so write `loop x = 0:` and break with what you want
```

Three shapes are refused, all for the same reason: C has no unit value
to fall back on. A bare `loop:` carries nothing, so there is no variable
to declare and nothing for the loop to be worth. An `if` with no `else`
as the *last* statement of a loop body leaves a turn with nothing to
hand on. And a loop body ending in something that produces no value —
a binding, a `while` — says nothing about the next turn either. Each is
a case Pyking answers with `()`; here it is refused instead, with the
position of the statement that produced nothing.

A tuple accumulator is refused too, for the ordinary reason: this
backend has no tuples.

### Nested `def`

```
Unsupported by target 'c23': a nested function -- C has no nested
functions, and one reading its enclosing scope could not be hoisted to
file scope without closures
```

C has no nested functions. Hoisting one to file scope works only if it
reads nothing from around it — which is to say, only without closures.

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
- `+` mixing an integer and a string.

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
is the same rule `target_java.py` enforces because `javac` demands it;
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

### A function reading a binding from around it

```
Unsupported by target 'c23': 'x' is bound outside this function --
C has no closures: a function here reads its parameters and calls other functions, nothing else
```

Pyking's functions may read the bindings in scope where they are written
(PYKING.md, "Names and scoping"); this backend's cannot. A function body
here starts from its own parameters, reaches other functions by name,
and sees nothing else. Passing the value in as a parameter is the fix.

Until this was checked, such a program compiled and then failed in the
host compiler with a message about a name this backend had emitted --
which is exactly what refusing it at compile time, with a Pyking source
position, exists to avoid.

### A function used as a value

```
Unsupported by target 'c23': `double` is a function used as a value -- C has no function values here: a `def` becomes a C function, and only a call can name one
```

A `def`'s name may be *called* here, and nothing else. Binding it
(`twice = double`) or passing it on would emit a bare method name in
Java and a function pointer assigned to an `int` in C — code that does
not compile, and did not, before this was checked. Under C89 it was
merely a warning, which is why the same program built there and failed
under C23.

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

## How types are inferred

Three types — `Int`, `String`, `Bool` — and three rules:

1. A **binding** takes the type of its initializer.
2. A **parameter** takes its annotation when that annotation names a type
   C can represent; otherwise it is inferred from whether the body
   concatenates or compares it with a string, and failing that it is
   `Int`.
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

## How things compile

### The same program, both standards

```pyking
def sign(n) = if n < 0 then "neg" else "pos"


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
assigns the next turn's value, and `break`/`continue` are C's own, with
the operand assigned first where one is written:

```pyking                          /* generated C */
res = loop x = 5:                  int x = 5;
    if x <= 10:                    while (1) {
        continue x + 1                 if (x <= 10) {
    else:                                  x = x + 1;
        break                              continue;
                                       } else {
                                           break;
                                       }
                                   }
                                   int res = x;
```

`while (1)`, not `while (true)`: c89 has no `bool`, and this is the
spelling both standards read the same way. The loop's own value is the
accumulator it stopped with, so binding one is that declaration after
the loop, and a loop in tail position is `return x`. Since a turn may
only carry one C type, a `break`/`continue` whose operand has a
different type is refused rather than silently converted.

A `while (1)` no `break` leaves is a loop that never finishes, so
`_falls_through` (see "A function that produces a value on some paths
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

The list (`RESERVED` in `src/target_c.py`) is one list for both
standards -- C89 plus the C99/C11/C23 additions -- since a name renamed
under `c23` but not `c89` would make the two targets disagree about the
generated code for no good reason. It also holds `main`, `printf`,
`strcmp` and the generated helpers: not keywords, but a Pyking function
shadowing one would break the file just as thoroughly.

### Booleans

`true`/`false` literals translate directly to `CBool`, printed by
`_bool_literal` as whichever spelling the standard uses (`1`/`0` for
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
```

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
- **`-Wextra` finds unused variables and parameters.** Those are faithful
  translations — the Pyking programs really do bind names they never use
  — but a smarter backend would drop dead bindings rather than emit them.
- **No optimisation.** The backend is a printer: no constant folding, no
  dead-code elimination, no tail calls. The C compiler does that work
  afterwards, which is a large part of why targeting C is attractive.
