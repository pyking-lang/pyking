# `builtin.ml`: design

How `src/builtin.ml` collects what the compiler knows about the names a
Pyking program may call without binding them, why that is one table
rather than a fact each stage keeps a copy of, and what deliberately
stays outside it. For a one-page summary see
[source.md](source.md#builtinml); for where it sits in the pipeline see
[architecture.md](architecture.md), "The builtins and the host
boundary".

## Four readers, one table

`print`, `debug`, `range`, `string`, `len`, `int`, `float` and `bool` are
in scope in every program and are bound by nothing. Four parts of the compiler need that
fact, and each needs something different about it:

- `typesystem.ml` puts the names in the environment before the first
  statement is checked, and checks each call's arity against the one it
  is allowed.
- `interpreter.ml` binds each name to a callable value, and computes
  what each one answers.
- `module.ml` needs the names, since nothing a program imports may take
  one.
- every backend needs to know which calls *leave* the program, and
  which of the rest it has no translation for.

Those are four questions about the same four names, and before this
module they were answered from four independent lists: `analyses.ml`
held the names, `runtime_interface.ml` held `print` alone with its arity
and its semantics, `target_js_core.ml` held `["str"; "range"; "len"]` as
the ones it refuses, and `target_ocaml.ml` held the same three in a
different order as the ones it translates. `target_python.ml` held no
list at all and matched the names as literals in five separate arms.
Nothing made any of them agree, so adding a builtin meant finding all of
them.

## What the table holds

```ocaml
type t = {
  name : string;
  min_args : int;
  max_args : int option;
  crosses_host : bool;
  doc : string;
}
```

`max_args` is an option, and `None` *is* variadic — there is no separate
flag that could disagree with the bounds. `print` and `debug` are
`(0, None)`, which is why they never fail an arity check; `string`, `len`, `float` and `int`
are `(1, Some 1)`; `range` is `(1, Some 3)`.

The order of the table is the order the playground publishes as its word
list (`pykBuiltins`), so it is the order someone writing Pyking sees.

The table itself is private. A caller asks for `names`, for
`pure_names`, for one entry by `lookup`, or for the single property a
backend branches on, `crosses_host` and `is_debug` — the same arrangement
`src/targets.ml` uses for the target table, and for the same reason: a
caller reading rows would be free to ask a question the module has not
agreed to answer.

`doc` is the one field nothing reads. It is the specification of what
the builtin means, kept beside the arity it is checked against rather
than in a comment somewhere else, and it is what a new operation is
written into first.

## The host boundary is a field, not a module

A Pyking program on its own only computes: it cannot reach a console, a
file or a clock. `print` and `debug` are the only things a program can
be *observed* to do without a library, and that distinction is worth
keeping — but it is a property of an operation rather than a reason for
a second module, so it is the `crosses_host` field. `is_debug` says
which of the two a call is: `print` writes the program's own output and
`debug` diagnostic output, to standard error where the host has one.

Every backend consults it at the same point in translation, recognising
that a call is one that leaves the program rather than a call to an
ordinary Pyking function:

```ocaml
| ECall (info, EVar (_, name, _), args, _) when Builtin.crosses_host name -> ...
```

What each backend does from there is host-specific and lives in that
backend:

- `target_js_core.ml` does not even decide what the call looks like in
  JavaScript. It emits `JsRuntimeCall (info, name, args)` and leaves the
  spelling — `print(...)` against `runtime.print(...)` — to
  `target_js_packaging.ml`, since that is the one thing the three
  JavaScript targets disagree about.
- `target_c.ml` and `target_java.ml` emit `printf(...)` and
  `System.out.println(...)`, each with its own formatting glue for the
  parts C and Java do not spell the way Pyking does -- and
  `fprintf(stderr, ...)` and `System.err.println(...)` for `debug`.
- `target_ocaml.ml` emits `print_endline`, needing almost no glue:
  OCaml already spells `true`, `false` and `()` as Pyking does.
  `prerr_endline` for `debug`.
- `target_python.ml` emits Python's own `print`, with
  `file=__import__('sys').stderr` for `debug`.
- `interpreter.ml` does not translate anything — it *performs* the
  operation, through a host, since it runs a program rather than
  emitting one: `print_line` for `print` and `debug_line` for `debug`.

Every one of those checks that the call reaches the builtin, and not a
program's own definition that took the name: the checker records a type
for a callee it resolved to a definition and none for a builtin, and a
backend without the checker's table asks its own scope.

`debug` is the builtin `--release` removes (src/release.ml). It is
`print`'s twin in every other respect, and the one a future *pure*
function will be allowed to call: writing diagnostic output is not
something a program is observed to do.

`pure_names` is the other side of the same field: the builtins that do
not cross the boundary, which is exactly the list a backend with no
translation for them has to refuse. `target_js_core.ml` and
`target_ocaml.ml` both read it instead of restating it.

## What is deliberately not here

Two things cannot be said in this module, and the module graph is why.
`builtin.ml` sits before `analyses.ml`, because everything downstream
reads it, so it can depend on nothing that comes later.

**Which argument types a builtin accepts** is `typesystem.ml`'s. `string`,
`len` and the three conversions are overloaded names in the language —
`string` takes an Int, a Float, a String, a Bool, a list or a tuple;
`len` takes a list or a String; `int`, `float` and `bool` each take an
Int, a Float, a String or a Bool — and those sets are not checked by
comparison but settled by unification against the checker's own
metavariables. Writing them here
would mean a `Syntax.typ` in a table that otherwise needs nothing from
the AST, and a second place for a rule the checker would still have to
apply.

**What a builtin computes** is `interpreter.ml`'s, and could not move
here even if that were wanted: it needs `value`, `host` and the
environment chain, and `interpreter.ml` sits after `typesystem.ml` in
the module graph. What this module holds instead is what the checker and
the interpreter have to agree on *before* either runs — the name, how
many arguments, and whether the call is observable.

So the table is the declaration and not the implementation. That is the
ceiling, and it is a real one: adding a builtin still touches the
checker, the interpreter and each backend. What it no longer touches is
four lists that could drift.

## Conversions

`string`, `int`, `float` and `bool` convert between Int, Float, String
and Bool, and what each answers is a rule of the language rather than of
any host (PYKING.md, "Conversions"). The two rules no host shares are
here, as `parse_int`, `parse_float` and `truncate_float`, because the
interpreter uses them and every backend implements them:

- **A String is read by Pyking's own grammar.** `int` accepts an
  optional sign and decimal digits, in the signed 32-bit range; `float`
  accepts an optional sign, digits, an optional fraction and an optional
  exponent, or `inf`, `-inf` and `nan`. Nothing else -- no space around
  it, no `0x`, no `_`. Every host's own parser disagrees somewhere:
  Python's `int` reads `" 3"` and `"1_000"`, OCaml's `int_of_string`
  reads `"0x1F"` and `"1_000"`, JavaScript's `Number` reads `" 3"` and
  `"0x1F"`, and C's `strtol` skips spaces. So each backend checks the
  text itself, and hands it to its host's parser only once it is known
  to be one.
- **A Float with no Int is 0.** `int` truncates toward zero, and a NaN,
  an infinity or a value outside the signed 32-bit range answers 0,
  where the hosts raise (Python, Java), answer whatever the hardware
  gives (C, OCaml) or answer NaN (JavaScript).

A conversion with no right answer answers a default -- 0, NaN, false --
because Pyking has no option type yet; once it has one, these will
answer none instead. `parse_int` accumulates as a negative number, so it
reaches the bottom of the range without passing through a value the
browser build's 32-bit `int` cannot hold.

## The formatting rules

Every backend has to agree on these before one program can print the
same characters everywhere, and they are `print`'s and `string`'s meaning
rather than any host's:

- arguments are formatted individually and joined with single spaces,
  then a newline;
- an integer prints in base 10;
- a Float prints by the rule below, which is the one thing here no host
  does the same way;
- a string prints **bare** on its own, and **quoted** inside a list or a
  tuple — `print("hi")` writes `hi`, and `print(["hi"])` writes
  `['hi']`;
- unit prints as `()`, never a host's own word for "no value" — not
  Python's `None`, not JavaScript's `undefined`;
- a boolean prints as `true`/`false`, Pyking's own spelling rather than
  any host language's.

### How a Float is written

Every host spells a double differently — JavaScript's `String(1.0)` is
`"1"`, Python's `repr(1e300)` is `"1e+300"`, OCaml's `string_of_float
1.0` is `"1."`, Java's `Double.toString(1e300)` is `"1.0E300"`, C's
`%g` drops the point — so no backend delegates. Each implements this
algorithm in its own host language, and one `.out` file is compared
against all of them.

```
pyk_float_str(x):
    if x != x:               return "nan"
    if x = +infinity:        return "inf"
    if x = -infinity:        return "-inf"
    sign = "-" if x is negative or negative zero else ""
    a = |x|
    if a = 0:                return sign + "0.0"
    for p in 0 .. 16:                      # p digits after the point
        s = format(a, "%.{p}e")
        if parse_float(s) = a: break
    digits = mantissa of s, point removed, trailing zeros stripped
    decpt  = exponent of s + 1             # a = 0.digits x 10^decpt
    if decpt <= -4 or decpt > 16:
        mant = digits[0] + ("." + digits[1:] if more than one digit)
        return sign + mant + "e" + (decpt - 1)
    if decpt <= 0:            return sign + "0." + "0"*(-decpt) + digits
    if decpt >= len(digits):  return sign + digits
                                     + "0"*(decpt-len(digits)) + ".0"
    return sign + digits[:decpt] + "." + digits[decpt:]
```

It needs two host primitives, `%.{p}e` and a parse back, and every
target has both. The round-trip check is what makes the digit count
correct even where a host's own formatter is not: `Double.toString` was
not the shortest round trip before JDK 19, and `java8` is the floor
here.

The `decpt` thresholds are Python's `repr`, and they are what keeps
`100.0` from printing as `1e2` — the naive "shortest `%g`" does exactly
that. Python's own `repr` therefore agrees with this rule on every value
but the exponent's punctuation, which it writes with a `+` and a leading
zero.

| value | text | |
|---|---|---|
| `1.0` | `1.0` | no point in the digits, so one is added |
| `0.1` | `0.1` | shortest, not the exact binary value |
| `100.0` | `100.0` | *not* `1e2` — the `decpt` rule |
| `0.0001` | `0.0001` | `decpt` -3, positional |
| `1e-5` | `1e-5` | `decpt` -4, exponential; no leading zero |
| `1e15` | `1000000000000000.0` | `decpt` 16 |
| `1e16` | `1e16` | `decpt` 17; no `+` |
| `1.0/3.0` | `0.3333333333333333` | 16 digits |
| `-0.0` | `-0.0` | the two zeros print differently |
| `1.0/0.0` | `inf` | |
| `0.0/0.0` | `nan` | |

`Builtin.float_text` is this in OCaml, and is the one the interpreter
and the `-t pyking` printer use. Two traps are worth naming because they
are silent: **Java's `String.format` must take `Locale.ROOT`**, or a
comma-decimal locale writes `1,0e+00`; and **C's `sprintf` respects
`LC_NUMERIC`**, which the generated C is safe from only because it never
calls `setlocale`.

A target whose values cannot say at run time whether they are an Int or
a Float has one more problem, and only JavaScript has it: see
[target_js.md](target_js.md), "Floats".

`interpreter.ml`'s `format_value` and `display_value` are these rules
implemented for real — the second is the quoted form, and the first is
the top-level one that differs only for a string. Being the reference
implementation for the language, a disagreement between them and this
specification is a bug in the interpreter rather than in the spec.
`target_js_packaging.ml`'s `format_js` is the same rules in JavaScript,
shared by every module of a compiled program — and the playground reads
that formatter back out of the compiler through `pykFormatHelper`
rather than keeping a copy, because a hand-copied one drifted the moment
booleans stopped printing capitalised (`tools/playground/README.md`).

## Adding a builtin

Write the entry here first — its arity, whether it crosses the host, and
its semantics in `doc` — before any stage is taught to do anything with
it. Then four edits follow, and none of them is optional:

1. an argument rule in `typesystem.ml`'s `check_builtin_call`, or the
   name is refused at every call;
2. a case in `interpreter.ml`'s `apply_builtin`, or a program calling it
   type-checks and then fails at run time;
3. in each backend, either a translation or a refusal that names the
   target;
4. a test, and its entry in `tests/test_cases.toml`.

A builtin with no entry here is one the backends and the checker would
each have to be told about separately, which is the state this module
replaced.
