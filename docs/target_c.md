# The C targets

**Targets in this family:** `c89`, `c23`.

**Key points**

- One backend, `boot/target_c.py`, with a `standard` parameter. The two
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
`while`; `=`, `var`, `:=`; `if … then … else …` expressions; integers,
strings and booleans; `+ - *`, unary minus, comparisons, and calls.

Type annotations are *used* here rather than erased, when they name a
type C can represent.

## What is not supported

Everything the JavaScript targets refuse — lists, tuples, `for`,
`match`/`case`, comprehensions, value-form bindings, `str`/`len`/`range`
— plus the following, each because C demands an answer Pyking never had
to give. All are refused at compile time with a source position.

### `/`

```
$ python3 boot/pykboot.py -t c23 divide.pyk
'divide.pyk' 1:6-1:11 Unsupported by target 'c23': `/` is true division in
Pyking and truncating integer division in C; matching it needs a
floating-point type this backend does not have yet
```

Pyking's `7 / 2` is `3.5`; C's is `3`. Unlike the JavaScript targets,
where only the *printed form* differs, here the **value** would be wrong.
Producing the right one needs a floating-point type throughout, and
printing it the way Python does needs a float-repr routine; neither
exists yet, so `/` is refused rather than quietly computing something
else.

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

### A recursive function returning non-`Int` without an annotation

```
Unsupported by target 'c23': `f` calls itself and does not return Int; a
recursive function's return type is assumed Int unless annotated, so
annotate it (`-> String`, `-> Bool`)
```

The signature must exist before the body is translated, so the return
type starts as `Int`. Adding `-> String` resolves it.

## How types are inferred

Three types — `Int`, `String`, `Bool` — and three rules:

1. A **binding** takes the type of its initializer.
2. A **parameter** takes its annotation when that annotation names a type
   C can represent; otherwise it is inferred from whether the body
   concatenates or compares it with a string, and failing that it is
   `Int`.
3. A **function's return type** is read back off its translated body.

Annotations naming a tuple or list type are *ignored* rather than
rejected. Nothing in Pyking checks annotations, and
`tests/types_tuples.pyk` annotates parameters as tuples and then passes
integers — so inference is the more truthful reading of such a program.

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
        printf("%s %s %s\n", sign(i), classify(i), strcmp("a", "b") == 0 ? "True" : "False");
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

### Booleans

Pyking prints booleans `True`/`False`, which C spells neither way, so a
printed boolean becomes a conditional expression. The type itself follows
the standard:

```c
int negate(int flag)      /* c89 */
bool negate(bool flag)    // c23

printf("%s\n", negate(1 < 2) ? "True" : "False");   /* both */
```

### `print`

Types are known statically, so each call becomes one `printf` with a
format string built at compile time — `%d` for integers, `%s` for
strings, and `%s` plus a ternary for booleans:

```pyking                          /* generated C */
print(1, "two", 3 < 4)             printf("%d %s %s\n", 1, "two", 3 < 4 ? "True" : "False");
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
