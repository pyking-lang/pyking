# Adding `Float` to Pyking

IEEE 754 binary64, with `+ - * /` overloaded over `Int` and `Float`, on
every target. This is the plan the change follows: the decisions, then
what each file gets. Written before any code; where it disagrees with
what was built, the code is right and this file is stale.

## The ten decisions

| | Decision | Why |
|---|---|---|
| 1 | An arithmetic operator whose operand type nothing has decided **defaults to `Int`** | Every program that compiles today still compiles and means the same thing. The alternative -- refusing as ambiguous -- breaks every unannotated arithmetic program, `typecheck_noann_*` included |
| 2 | A literal has **digits on both sides of the point** (`1.0`, `0.5`), or an **exponent** (`1e9`, `1.5e-3`, `2E+10`). `1.` and `.5` are refused | Digits on both sides keeps `x.field` unambiguous for the lexer. An exponent is the only way to write 10³⁰⁸. No magnitude bound: overflow to `inf` is IEEE's own answer and the same in both builds |
| 3 | **No mixed arithmetic.** `1 + 1.0` is refused; `float(n:Int) -> Float` and `int(x:Float) -> Int` convert | Implicit widening would break `check_binary`'s "unify the operands first", which the whole operator table rests on, and would make `1 / 2` change meaning with context |
| 4 | **Shortest round-trip**, always visibly a Float. One rule, written by us on every target, never the host's default | One `.out` file is compared across nine backends, and every host spells a double differently |
| 5 | **IEEE exactly.** `/` never traps, `inf`/`-inf`/`nan` are ordinary values, `==` and `<` are IEEE's -- so `nan == nan` is false | The type is named "IEEE 754 binary64". Half-implementing it is worse than either extreme |
| 6 | The text is Python's `repr` rule with the punctuation normalised (below) | The rule every modern language converged on; `print(0.1)` writes `0.1` |
| 7 | JavaScript formats a Float **by its static type**, through a shape descriptor computed from `tmap` | JS has one number type: `String(1.0)` is `"1"`, and no run-time test can tell an Int from a Float |
| 8 | **Float goes everywhere Int already is**: `< <= > >=`, `==`, `str`, unary `-`, and `var` | Leaving Float out of `var` would make a running total impossible, which is the first thing anyone writes with floats |
| 9 | A Float **may cross an external module boundary** on every target | It is less code than refusing: `check_boundary_type` refuses only type variables and function types |
| 10 | Tests: arithmetic, printing, conversion, `var`, `typecheck_float_*` with its `noann` twin, three `fail_typecheck_float_*`, an external field, a playground example | Printing earns its keep -- nine hosts, one `.out`. The `noann` twin is the standing check on decision 1 |

Two decisions are mine rather than the grilling's, and are called out
here so they are not silently assumed:

- **A Float is not a pattern.** `case 1.5:` is a parse error, because
  `parse_pattern_atom` is simply not taught `TokFloat`. Matching on a
  double is an IEEE footgun with no use in sight, and the cheapest
  refusal is the one that already has a source position.
- **`%` is not affected**, because Pyking has no modulo operator.

## Two consequences worth seeing before the work starts

**An unannotated function that adds is an `Int` function.** `def add(a,
b): a + b` infers `(Int, Int) -> Int`, and making it a Float function is
a matter of saying so -- `def add(a:Float, b:Float) -> Float`, or having
a Float reach it from a call. That is decision 1, and PYKING.md says it
out loud.

**But an unannotated function that *compares* stays open.** `def
less(a, b): a < b` leaves its operand undecided and generalises to a
promise `verified` then refuses, exactly as `==` does today, so the
first call settles it and `less(1.0, 2.0)` works. The asymmetry is not
a special case: `operator_result` answers "several rows agreeing on the
result" *before* it reaches the default, and `<` has two rows both
answering Bool where `+` has two rows that disagree.

## The text of a Float

One algorithm, implemented five times over (six with the interpreter),
identical to the character. `nan`, `inf`, `-inf`, `-0.0` are literal;
everything else is the shortest decimal that reads back as the same
double, presented positionally unless the exponent is extreme.

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

`%.{p}e` and a parse back are the two host primitives it needs, and
every target has both. The round-trip check is what makes the shortest
digit count correct even where a host's own formatter is not (Java
before 19 is the case in point). The `decpt` thresholds are Python's,
so `repr` agrees with this rule on everything but the exponent's
punctuation.

Worked, and these are the printing test's expectations:

| value | text | |
|---|---|---|
| `1.0` | `1.0` | no point in the digits, so one is added |
| `0.5` | `0.5` | |
| `0.1` | `0.1` | shortest, not `0.1000000000000000055511151231257827` |
| `100.0` | `100.0` | *not* `1e2` -- the `decpt` rule is why |
| `0.0001` | `0.0001` | `decpt` -3, positional |
| `1e-5` | `1e-5` | `decpt` -4, exponential; no leading zero in the exponent |
| `1e15` | `1000000000000000.0` | `decpt` 16 |
| `1e16` | `1e16` | `decpt` 17; no `+` in the exponent |
| `1e300` | `1e300` | |
| `1/3.0` | `0.3333333333333333` | 16 digits |
| `-0.0` | `-0.0` | |
| `1.0/0.0` | `inf` | |
| `0.0/0.0` | `nan` | |

Two locale traps, both real and both silent: **Java's `String.format`
must take `Locale.ROOT`**, or a comma-decimal locale writes `1,0e+00`;
**C's `sprintf` respects `LC_NUMERIC`**, and the generated C is safe
only because it never calls `setlocale` and C starts in the `"C"`
locale. Both get a one-line comment where they are emitted.

One OCaml trap, in the interpreter and nowhere else: **polymorphic `=`
on a value that wraps a float is `compare`, not IEEE** -- `Some nan =
Some nan` is `true` where `nan = nan` is `false`. Every Float
comparison unwraps to two `float`s first.

## `src/`

### Front end

- **`lexer.ml`** -- `TokFloat of info * float`; `"Float"` joins
  `keywords` and gets `TokTypeFloat`; `pprint_token` and `token_info`
  get both. The integer arm grows a lookahead: after the digit run, a
  `.` followed by a digit, or `e`/`E` followed by an optional sign and a
  digit, makes it a Float instead. No `max_float_literal` -- decision 2.
- **`syntax.ml`** -- `EFloat of info * float * int` in the `expr` group,
  `TFloat of info * int` in the `typ` group. `expr_info`, `expr_sym`,
  `with_info`, the precedence list at `:436`, and `pprint_expr` (which
  prints `pyk_float_str`'s text, so `-t pyking` output re-parses and an
  `.ast.out` is stable) and the type printer.
- **`parser.ml`** -- `TokFloat` in `parse_atom` (through
  `parse_call_tail`, like `TokInt`); `TokTypeFloat` in
  `parse_type_atom`. **Not** in `parse_pattern_atom`.
- **`analyses.ml`** -- a `symbolize` case, and `EFloat` in the leaf list
  at `:685`. `Builtin.names` already seeds the environment, so `float`
  and `int` arrive there for free.
- **`walk.ml`** -- `EFloat` in the no-children list at `:53`.
- **`opt_tailcall.ml`** -- expected to need nothing; it passes
  expressions through. Confirmed by the build, not by reading.
- **`type_experiment.ml`** -- nothing. It is a fragment covering integer
  literals by design.

### `typesystem.ml`

- `t_float`, `TFloat` in `same_type` (`:457`), `KFloat` in `kind`,
  `kind_matches` and `kind_type`.
- `operator_of` gains rows: `+ - * /` become
  `[(KInt, KInt); (KFloat, KFloat)]` and `< <= > >=` become
  `[(KInt, KBool); (KFloat, KBool)]`; `==` gains `(KFloat, KBool)`.
- **`operator_result` gains its third case**, which is decision 1. The
  rule becomes three, and the third subsumes today's single-row case:
  1. the common type is settled -- find its row, or refuse;
  2. still open and every row agrees on the result -- answer that
     result, leave the operand open (today's `==`, and now `<`);
  3. still open otherwise -- **unify the operand with the first row's
     type** and answer that row's result.
- `ENeg` (`:2259`) stops unifying with Int outright and asks the same
  three-case helper with `[(KInt, KInt); (KFloat, KFloat)]`.
- `check_mutable` (`:919`) gains `TFloat`.
- `check_builtin_call` -- `str` accepts `KFloat`; `float` takes one
  `KInt` and answers Float; `int` takes one `KFloat` and answers Int.
  `range` and `len` are unchanged.
- The refusal for `1 + 1.0` is unification's, and `operator_error` must
  **name the conversion**: an operator refused with one Int and one
  Float operand says that `float(...)` and `int(...)` are how to mix
  them. A refusal that does not say the way out is the expensive kind.

### `builtin.ml`

Two entries after `len`, each `min_args = 1`, `max_args = Some 1`,
`crosses_host = false`:

- `float` -- "Answer an Int as a Float. Exact for a magnitude below
  2^53; above it, the nearest double."
- `int` -- "Answer a Float as an Int, truncating toward zero -- the same
  rounding `/` does. A value with no Int to truncate to (a NaN, an
  infinity, one past the Int range) is undefined, as an Int overflow
  is."

`docs/builtin.md`'s formatting rules gain the Float line and the
algorithm above.

### `interpreter.ml`

- `VFloat of float`, and `describe` answers `"Float"`.
- `EFloat` in the direct evaluator (`:762`).
- `arith`, `compare_with` and `divide` (`:508`-`:527`) gain
  `VFloat, VFloat` arms. **`divide` does not trap on a Float**: only
  `VInt _, VInt 0` keeps the trap, and `1.0 /. 0.0` is `infinity`.
  Every comparison unwraps to two `float`s before comparing -- the
  OCaml trap above.
- `display_value` gains a `VFloat` arm calling `pyk_float_str`, written
  here as the reference implementation (`format_value` needs nothing:
  only a String differs at the top level).
- `apply_builtin` gains `float` and `int`.
- The `datatype` comment block gains `VFloat`; it is hand-written and
  drifts silently.

### Backends

**`target_python.ml`.** Python has a real float, so no `tmap` work
beyond what is there. `bool_kind` widens to a `format_kind`: a type with
no Bool **and no Float** anywhere inside it still prints bare through
the host's own `str`, and anything else goes through the generated
`__pyk_str` walker, which gains an `isinstance(x, float)` arm calling a
new `__pyk_float` helper. The helper is the algorithm above in Python.
`EFloat` is a `PyFloat` literal; `/` on two Floats is Python's own `/`
(the `__pyk_divide` helper stays for Ints only), so `translate_expr`'s
`EDiv` arm needs the operand type -- which `translate_program` already
has.

**`target_js_core.ml`.** The one backend that gains a `tmap` parameter.
`EFloat` is a `JsNum`-alike; `/` on Floats is JavaScript's own `/`
without the `Math.trunc` wrapper (`:347`). Formatting is decision 7: at
a `print` or `str` argument whose static type **contains a Float**, the
call carries a **shape descriptor** derived from that type -- `"f"` for
a Float, `"[s]"` for a list of shape `s`, `"(s1,s2)"` for a tuple, `"."`
for a part with no Float in it. Where the type contains no Float at all
the call is emitted exactly as it is today, so ordinary output stays
byte-for-byte what it was. A descriptor rather than a generated walker
per shape: JS needs the type to settle a *value* question, not a
spelling one, and one extra parameter to `pykFormat` says it.

**`target_js_packaging.ml`.** `pykFormat` takes the third argument and
consults it; `pykFloatStr` joins `pykFormat` and `pykQuote` in
`pyk-runtime.js`.

**`target_c.ml`.** `ctype` gains `Float` -> `double`. `EFloat` is a
`CFloat`; `require` accepts it at `+ - * /`, the comparisons, `==` and
unary `-`; `/` on Floats is C's own. `pyk_float_str` joins `pyk_concat`
in the prelude, written to **C89** -- no `isnan`/`isinf` (they are
C99), so `x != x` for NaN and a `DBL_MAX` comparison for the
infinities, and `strtod`/`sprintf("%.*e", …)`, both of which C89 has.

**`target_java.ml`.** `jtype` gains `Float` -> `double`. Equality on
two doubles is `==`, never `.equals`. A static `pykFloatStr` in the
generated class, using `String.format(Locale.ROOT, "%.<p>e", …)` and
`Double.parseDouble`. Java 8 is the floor, so nothing from `java.util.
DoubleSummaryStatistics` or JDK 19's fixed `Double.toString`.

**`target_ocaml.ml`.** No inference to add -- it reads `tmap`. What it
needs is the *spelling*: `+. -. *. /.` where the operand type is Float,
and the plain forms where it is Int, decided at `:591`-`:651` from the
type already in hand. A `pyk_float_str` in the preamble. The harness
builds with `-w +a`, so the emitted helper must be warning-free.

**`src/web/pyking_web.ml`, `stub.js`.** `pyk_encode` writes a VFloat as
`{"pyk_float": "<canonical text>"}` and `value_of_json` parses it back.
JSON cannot carry NaN or an infinity, and the canonical text round-trips
exactly by construction, so nothing is lost. No library declares a Float
today (decision 9 permits one, it does not add one), so this is
defensive -- and it is the bridge that dropped a tuple once.

**`src/module.ml`.** Nothing. `check_boundary_type` refuses type
variables and function types; a scalar already crosses.

One thing `Float` does **not** inherit from `Int`: the 32/63-bit split.
A binary64 is a binary64 natively and under js_of_ocaml, so unlike
`Int`, a Float means the same thing in both builds and on every host.
`docs/targets.md` says so.

## `tests/`

| file | what it pins | targets |
|---|---|---|
| `float_arithmetic` | `+ - * /`, precedence, unary `-`, `/` by zero giving `inf` and `nan` | all + `interpret` |
| `float_printing` | every row of the table above | all + `interpret` |
| `float_compare` | `< <= > >=`, `==`, and that every comparison with `nan` is false | all + `interpret` |
| `float_convert` | `float`/`int` round trips, truncation toward zero on both signs | all + `interpret` |
| `float_var` | a `var x : Float` accumulator driven by `:=` | all + `interpret` |
| `float_shapes` | a Float in a list and in a tuple, printed -- the JS descriptor's test | the four whose boundary carries them, + `interpret` |
| `typecheck_float` | `.ast.out` pinning the inferred types | backends + `interpret` |
| `typecheck_noann_float` | the same with the annotations off, **same `.out`** -- decision 1's standing check | as above |
| `fail_typecheck_float_mixed` | `1 + 1.0` | `pyking` |
| `fail_typecheck_float_literal` | `1.` and `.5` (a `Parsing error`) | `pyking` |
| `fail_typecheck_float_pattern` | `case 1.5:` (a `Parsing error`) | `pyking` |
| `module_external_*` | one existing case gains a Float field | as it has |

Plus one playground example, which `test_playground.py` then compiles on
every target the page claims.

`float_printing` is the case that matters most, and it is the one most
likely to fail first on Java 8 and on C89.

## Docs, and the two that get forgotten

- **`PYKING.md`** -- the feature summary; the EBNF for a float literal;
  "Integer and string literals" becomes "Numeric and string literals"
  and states IEEE 754 binary64, that overflow is `inf` rather than
  undefined, and that a Float is the same on every host where an Int is
  not; "Type checking" gets decision 1, decision 3, the `var` rule, and
  the `nan == nan` surprise; a worked example.
- **`docs/builtin.md`** -- `float` and `int`; the Float formatting rule
  and the algorithm.
- **`docs/architecture.md`** -- the operator table's third case.
- **`docs/type_inference.md`** -- why the default is Int and why
  comparison behaves differently; the alternative (a numeric type
  variable) and why it was refused.
- **`docs/targets.md`** -- Float in the shared-subset table, and the
  note that it does not have `Int`'s width caveat.
- **`docs/source.md`** -- `target_js_core.ml` now takes `tmap`.
- **`docs/target_python.md`** -- `bool_kind` widened.
- **`docs/target_js.md`** -- the shape descriptor.
- **`docs/target_c.md`** -- the C89 constraints on the helper.
- **`docs/target_java.md`** -- `Locale.ROOT`, and `==` not `.equals`.
- **`docs/target_ocaml.md`** -- picking `+.` from `tmap`.
- **`tools/emacs/pyking-mode.el`** -- `pyking-mode-types` gains
  `"Float"` (it must still equal `lexer.ml`'s `keywords` split three
  ways) and `pyking-mode-builtins` gains `float` and `int`. Verified by
  running the batch indent check, not by eyeballing.

## Order of work

1. Front end: lexer, syntax, parser, analyses, walk. `-t pyking
   --no-typechecking` then round-trips a float literal, which is the
   first thing that can be checked.
2. `typesystem.ml` and `builtin.ml`, then the `fail_typecheck_*` cases
   and `typecheck_float` -- the `pyking` target needs no backend.
3. `interpreter.ml`, and the whole `.pyk` set on `interpret`. It is the
   reference, so it settles what every `.out` file holds.
4. The backends, in the order of how much each has to invent:
   `target_ocaml` (reads `tmap`), `target_python`, `target_js_*`
   (the `tmap` thread), `target_c`, `target_java`.
5. The web bridge and the playground example.
6. Docs, the emacs mode, and a clean warning-free rebuild.
7. All four suites green, and `make test` with no `TARGET`.

## What the work changed

Written after the fact. Where this disagrees with the plan above, the
code is right.

**Two hosts needed more than the plan expected.**

- **Python raises where IEEE answers.** `1.0 / 0.0` is a
  `ZeroDivisionError`, not `inf` — Python is the only host that does
  this. So a Float division goes through `__pyk_fdiv`, beside the
  `__pyk_div` an Int division already needed, for the opposite reason.
- **C could not simply include `<math.h>`.** It was wanted only for
  `HUGE_VAL`, and glibc declares `fadd` there — which a Pyking `def` is
  free to be called, and one in the test suite is. The header is now
  included only for a literal that overflowed to an infinity;
  `<float.h>`, which declares no functions, carries `DBL_MAX` for the
  rest.

**Float exposed two holes in C and Java that were not about Float.**
Both backends infer each function's parameter types from its own body,
and neither checked a call's arguments against what it had worked out.
An `Int` passed where a `String` was inferred at least fails to build;
a `double` passed where an `int` was inferred converts silently and is
quietly wrong. Both now refuse a mismatch with the position of the call.
Their parameter guess also learned Float, from an operand combined with
a float literal — the same shape as the existing "used as a string"
guess.

**One OCaml invariant was easy to miss.** The tail-call pass synthesizes
nodes the checker never walked, so they have no `tmap` entry, and
`type_of` raises. Picking `+.` over `+` therefore has to be a *total*
lookup: an absent entry means an Int, because that pass rewrites calls
and introduces no arithmetic of its own. One test caught it
(`typecheck_noann_loop_break`), and it would have been a crash rather
than a wrong answer.

**Two smaller departures.** The Int default earned a test of its own,
`typecheck_float_default`, rather than living inside the `noann` twin —
the twin has to share its `.out` unchanged, and the default is worth
saying out loud. And the boundary test is a new `external_float` with
its own five implementations rather than a Float field bolted onto
`external_all`, which would have perturbed a pinned case for no gain.

**One thing is not finished, and is stated rather than hidden.** On the
`iweb` target the interpreter runs in the page and external values cross
as JSON, which has neither a NaN nor a way to tell `2` from `2.0`. A
Pyking Float can be *passed* to an external module there (it crosses
under a `pyk_float` marker, as a tuple already does), but one cannot
come back: the decoder has only the value's own shape to go on. Nothing
under `lib/` declares a Float, and every compiled target carries one in
both directions.
