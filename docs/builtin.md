# `builtin.ml`: design

How `src/builtin.ml` collects what the compiler knows about the names a
Pyking program may call without binding them, why that is one table
rather than a fact each stage keeps a copy of, and what deliberately
stays outside it. For a one-page summary see
[source.md](source.md#builtinml); for where it sits in the pipeline see
[architecture.md](architecture.md), "The builtins and the host
boundary".

## Four readers, one table

`print`, `range`, `str`, `len`, `float` and `int` are in scope in every
program and are bound by nothing. Four parts of the compiler need that
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
flag that could disagree with the bounds. `print` is `(0, None)`, which
is why it never fails an arity check; `str`, `len`, `float` and `int`
are `(1, Some 1)`; `range` is `(1, Some 3)`.

The order of the table is the order the playground publishes as its word
list (`pykBuiltins`), so it is the order someone writing Pyking sees.

The table itself is private. A caller asks for `names`, for
`pure_names`, for one entry by `lookup`, or for the single property a
backend branches on, `crosses_host` — the same arrangement
`src/targets.ml` uses for the target table, and for the same reason: a
caller reading rows would be free to ask a question the module has not
agreed to answer.

`doc` is the one field nothing reads. It is the specification of what
the builtin means, kept beside the arity it is checked against rather
than in a comment somewhere else, and it is what a new operation is
written into first.

## The host boundary is a field, not a module

A Pyking program on its own only computes: it cannot reach a console, a
file or a clock. `print` is the only thing a program can be *observed*
to do, and that distinction is worth keeping — but it is a property of
an operation rather than a reason for a second module, so it is the
`crosses_host` field.

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
  parts C and Java do not spell the way Pyking does.
- `target_ocaml.ml` emits `print_endline`, needing almost no glue:
  OCaml already spells `true`, `false` and `()` as Pyking does.
- `interpreter.ml` does not translate anything — it *performs* the
  operation, through a host, since it runs a program rather than
  emitting one.

`pure_names` is the other side of the same field: the builtins that do
not cross the boundary, which is exactly the list a backend with no
translation for them has to refuse. `target_js_core.ml` and
`target_ocaml.ml` both read it instead of restating it.

## What is deliberately not here

Two things cannot be said in this module, and the module graph is why.
`builtin.ml` sits before `analyses.ml`, because everything downstream
reads it, so it can depend on nothing that comes later.

**Which argument types a builtin accepts** is `typesystem.ml`'s. `str`
and `len` are two of the four overloaded names in the language — `str`
takes an Int, a String, a Bool, a list or a tuple; `len` takes a list or
a String — and those sets are not checked by comparison but settled by
unification against the checker's own metavariables. Writing them here
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

## The formatting rules

Every backend has to agree on these before one program can print the
same characters everywhere, and they are `print`'s and `str`'s meaning
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
