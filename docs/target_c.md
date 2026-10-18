# The C targets

**Targets in this family:** `c89`, `c99`, `c23`.

**Key points**

- One backend, `src/target_c.ml`, with a `standard` parameter. The three
  targets translate *identically*; the standard decides comments, where
  declarations may appear, how booleans are spelled, and which headers
  are needed.
- It infers no types of its own: every type it writes is read out of the
  checker's `tmap`, as `src/target_ocaml.ml` reads them.
- C has no garbage collector, so this backend compiles **everything that
  needs no heap**, and refuses with a source position what does: a list,
  a datatype holding itself, and a function value that could outlive
  the stack frame it captures from.
- A polymorphic function is compiled **once per type it is used at**; a
  tuple is a struct and a datatype a tagged union, both passed by value;
  a nested `def` or a lambda is a function of its own taking what it
  captures; a function value is a function pointer and an environment
  on the stack.
- Output is one `.c` file per module with no dependencies beyond the C
  standard library, and only the headers it uses.
- Least optimal at: strings, which every `++` and conversion allocates
  and nothing frees.

Verified with `gcc -pedantic` under all three standards.

## The three targets

| | `c89` | `c99` | `c23` |
|---|---|---|---|
| comments | `/* … */` | `// …` | `// …` |
| declarations | hoisted to the top of each block | where they appear | where they appear |
| booleans | `int`, `1`/`0` | `bool`, `true`/`false`, `<stdbool.h>` | `bool`, `true`/`false` |

C89 has no compound literals and no non-constant aggregate
initializers, so every struct is built by a function of its own
(`pyk_mk_...`), which reads the same under all three.

## What needs a heap, and is refused

| refused | why |
|---|---|
| a list, `[e for ...]`, `for x in` a list, `range` outside a `for` header | every list is allocated, and nothing would free it |
| a datatype holding itself, directly or through another (`Tree(a)`) | a value of it has no size of its own |
| a function value that captures, returned, or held in a tuple, a datatype or a top-level binding | its environment is on the stack of the function that made it |
| a polymorphic parameter (`all a. (a) -> a`) | one function would have to serve every type, which needs one representation for all of them |
| a polymorphic function as a value, other than as an argument or another name for it | a value has one type, and the function is compiled once per type |

`for x in range(a, b, c)` builds no list: it is a counting loop.
A `match` over a list, a list pattern and `len` of a list are refused
with the list. A String's `len` is `strlen`.

## How types are written

| Pyking | C |
|---|---|
| `Int`, `Float`, `Bool`, `String` | `int`, `double`, `int`/`bool`, `const char *` |
| `()` | `void` as a result, `int` as a value (0) |
| `(Int, String)` | `pyk_t_Tis_`, a struct with `a0`, `a1` |
| `Shape`, `Maybe(Int)` | `pyk_d_D<module>_Shape__`, `pyk_d_D<module>_Maybe_i_`: a struct with a `tag` and a union of the constructors' fields |
| `(Int) -> Int` | `pyk_c_Fi_i_`: a function `fn` taking the environment first, the environment `env`, and `plain`, the function itself where it captures nothing |

A compound type's name is its **code**: one letter per scalar (`i`,
`f`, `b`, `s`, `u` for unit), and `T...`, `D<module>_<name>_...` and
`F..._..._` for a tuple, a datatype and a function. A datatype is
always named with its module, so every file of a program writes the
same struct. Each type is declared guarded (`#ifndef PYK_TYPE_...`), so
a header and the file including it may both carry it, and a module's
header carries every type its file declares.

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
*count = &count_cell;`, and every closure takes the pointer.

As a value, a def is a closure: a wrapper taking the environment first,
the environment -- a struct of what it captures, on the stack of the
function that made the value -- and the plain function where it
captures nothing:

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

Calling one is `f.fn(f.env, x)`. A value whose environment is in this
function's frame is never returned, stored at the top level, or put in
a tuple or a datatype: each is refused where it is written.

## Datatypes and `match`

A constructor is a function building the struct, `pyk_mk_<code>_Circle`;
a field every constructor has is read by a function switching on the
tag. A `match` holds its subject in a local and is an if/else chain of
tests on it; every `match` matches every value (exhaustive.md), so the
last case needs no test. Where a case has a guard, the cases are a
chain of `if`s that a matched one leaves by `goto`.

Printing a compound value calls a function written for its type,
`pyk_show_<code>`, building its text with `pyk_concat`.

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

A program whose functions only compute — nearly every program — has
nothing to order, and its operands stay exactly where the source put
them; no temporary is declared and the output is byte for byte what it
was. `tests/evaluation_order.pyk` pins the straight-line cases down and
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

- **Strings leak.** `pyk_concat`, a conversion and the text of a printed
  compound value allocate and never free. Pyking has no ownership to
  compile into a `free`.
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

The boundary carries `Int`, `Float`, `String`, `Bool`, unit, a tuple of
those -- the struct this backend writes for it, which the implementation
declares the same, guarded the same (`lib/time/time_external.c`) -- and
a callback. A declaration naming a list is left out, and a call to one
is refused: only what a program uses of a library is compiled at all
([modules.md](modules.md), "What a program uses"), so `sys.exit`
compiles here while `sys.args` is refused.

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
