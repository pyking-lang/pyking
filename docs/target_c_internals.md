# `target_c.py`: internals

How `src/target_c.py` infers the types C forces onto a program Pyking
never required them for, how it pins down the evaluation order C leaves
open, and how it makes one translation serve both
`c89` and `c23`. For what each construct compiles to and what's
refused, see [target_c.md](target_c.md); for a one-page summary, see
[source.md](source.md#target_cpy).

## Types as strings, not a type system

`INT`, `BOOL`, `STRING`, `UNIT` are the literal strings `"Int"`,
`"Bool"`, `"String"`, `"Unit"` — not a mini reimplementation of
`syntax.py`'s `Type` hierarchy. Every `CExpr` carries one as its
`ctype` field, and the whole of this backend's type *reasoning* is
comparing these four strings against each other and looking them up in
small dicts (`_C_TYPES`, keyed by `standard`, since `Bool` is `int` in
c89 and a real `bool` in c23; `_FORMATS`, the `printf` conversion per
type). This is deliberately the simplest representation that works:
there's no subtyping, no type variables, no need to compare a `TList`'s
element type recursively the way `typesystem.py`'s `same_type` does —
this backend's subset has exactly three value types and a unit type,
so four constant strings and a couple of dict lookups are the whole
mechanism, with none of the machinery a real type system would need for
questions this backend never has to ask.

## Why this backend has to infer anything at all

Pyking itself needs no static types to run — the interpreter and the
Python backend both work directly from untyped source. C does need
them, for the mundane reason that `int x = ...;` requires deciding what
comes before the name. This backend's job is therefore not "translate
Pyking's types to C's" (there mostly aren't any to translate — Pyking
programs are usually unannotated) but "work out, well enough to compile,
what C type every value needs," and it does that with three
deliberately simple rules rather than a real inference algorithm — see
[target_c.md](target_c.md), "How types are inferred," for the rules
themselves. What follows is how each one is actually computed.

**A binding takes its initializer's type** — trivial, since
`translate_expr` already had to work out the initializer's `ctype` to
build its `CExpr` in the first place; `SLet`'s case in `translate_stmt`
just reads `value.ctype` off the already-translated right-hand side.

**A parameter takes its annotation, when C can represent it, else a
guess.** `_param_type` tries `_annotated_type` first (see above); when
that's `None` — the parameter wasn't annotated, or was annotated with
something C has no type for, like a tuple — it falls back to
`_used_as_string`, which walks the function's body looking for exactly
one piece of
evidence: is this parameter ever added to, or compared with, a string
literal? If so, it's guessed as `String`; otherwise it defaults to
`Int`. This is a real, acknowledged weakness rather than a hidden one —
`target_c.md` calls it out as "not optimal" directly: a parameter that
only ever flows through unchanged (`def id(x): x`, called with a
string) gives no evidence either way, and the guess lands on `Int`,
producing C that won't compile. The fix, when it happens, is to
annotate the parameter; a real inference pass (unifying types across
every call site the way `typesystem.py`'s deferred checking does — see
`type_inference.md`) would remove the guess entirely, at a cost in
complexity this backend has so far chosen not to pay.

**A function's return type is read back off its translated body**, not
declared in advance — which is the one rule that needs real machinery,
because C requires a function's return type in its *signature*, and a
signature has to exist before the body that determines it has been
translated (a call written above the `def`, or a recursive call inside
it, needs *some* type to check against before the real one is known).

## The two-pass shape: provisional first, real answer after

`declare_functions` runs before any function body is translated (the
same two-pass hoisting `analyses.py`'s `block_functions` and
`typesystem.py`'s `declare_functions` both perform, for the same
reason: forward references and recursion need every name bound before
any body is walked). What it registers is deliberately **provisional**:
the annotation, if the `def` wrote a return type, or `Int` as a guess
if it didn't — because at this point, no body has run yet to say
otherwise.

`function` then translates the body for real, and where its guess was
wrong, has to notice and say so precisely:

- **`_return_types(body)`** walks the translated body collecting every
  `ctype` that flows through a `CReturn` — a function with more than
  one is a hard error (a function returning more than one type has no
  single C signature).
- **`_calls(body, c_name)`** checks whether the function calls
  *itself* anywhere in its own translated body — because a recursive
  call was necessarily typed against the *provisional* `Int` before the
  real return type was known, so a mismatch between what was assumed
  and what the body actually returns is likely that assumption leaking
  through, not a genuinely inconsistent function. The two error
  messages in `function` are deliberately different for this reason:
  a recursive mismatch says "annotate it, since a recursive function's
  return type is assumed `Int`," while a non-recursive one just says
  "returns more than one type" — the fix differs, so the message does
  too.
- **`called_early`**, populated in `translate_expr`'s `ECall` case
  whenever a call is translated before its callee's `function` pass has
  run (`name not in self.defined`), is what makes the *other* half of
  this precise: a call written *above* a `def` was also typed against
  the provisional guess, and if the real return type disagrees, that
  call site's own generated C is now wrong too — caught after the fact,
  once the real type is known, with the same "annotate it" guidance.

Once the real type is settled, `self.signatures[func.name]` is updated
to it, so every call translated *after* this point sees the corrected
signature; only calls that ran ahead of the definition needed the
special-cased check above.

## Two things C won't let this backend get away with

C has no way to say "this function sometimes doesn't return a value on
some path" — a `def` whose `if` is missing an `else` on one branch that
ends in an expression supplies unit on the other, an alternative
Pyking's own tail-position rule accepts and Python's `None` quietly
absorbs. C has neither Python's leniency nor a way to spell "or
nothing," so `_falls_through(body)` walks the translated body checking
whether control can reach the end without an explicit `return`, and
`function` refuses to emit such a function at all if its inferred
return type isn't `UNIT` — falling off the end of a non-`void` C
function is undefined behavior, not a compile error, which is worse:
the C compiler would happily build a program that returns whatever
garbage happened to be in the return register. Refusing at Pyking
compile time, with a source position, is strictly better than shipping
that.

## `c89` vs `c23`: one translation, one printer parameter

Both standards disagree about *how C is printed*, not about what the
translated program means — comments (`/* */` vs `//`), whether `bool`
exists as a real type, and where declarations may appear. `standard`
reaches exactly the parts of the printer that need to know: `_C_TYPES`
(so `Bool` prints as `int` under c89 and `bool` under c23),
`_bool_literal` (`1`/`0` vs `true`/`false`), `_comment`, and — the one
genuinely structural difference — `_emit_block`.

C89 allows a declaration only at the **start** of a block; C23 allows
one anywhere a statement can appear, matching what Pyking itself
allows. Rather than reject C89 or refuse the difference, `_emit_block`
does the translation itself: under `c89`, every `CDecl` in the block is
split into a bare declaration (hoisted to the top, in source order) and
an assignment left where it originally stood — so `var x = a` becomes
`int x;` at the block's top and `x = a;` where the binding actually
was. Because each Pyking binding already has its own distinct C
variable name (renamed for shadowing exactly as every other backend's
`Scope` renames — see `target_c.py`'s own `Scope`/`_bind`, which follow
the same shape `target_js_core.py`'s do), hoisting the bare declaration
ahead of its assignment can never accidentally capture the wrong
variable; the split is purely mechanical.

## Forward references: prototypes, always

Because a call needs to have *seen* a declaration before C will accept
it — unlike Java, which doesn't care about order at all (see
[target_java_internals.md](target_java_internals.md)) — `pprint_c_program`
emits a prototype for **every** function ahead of all the definitions,
not just the ones that are actually called before they're written.
Emitting all of them uniformly, rather than only the ones that strictly
need one, is what keeps the generated file's shape independent of
which order the source happened to define things in — a detail
`target_c.md`'s "Forward references and mutual recursion" section notes
directly: the output doesn't depend on an ordering the language itself
says doesn't matter.

## Strings: a real helper, because C has no `++`

Unlike `target_java.py`, where string concatenation is just Java's own
`+` and equality is `.equals()` (see that page), C has neither. This
backend generates one small `pyk_concat` helper (written in the subset
both standards accept, so one copy serves both) and translates an
`EConcat` into a call to it; equality between two strings becomes
`strcmp(...) == 0`. `CProgram.uses_concat`/`uses_strcmp` track whether
either was needed at all, which is what lets `_headers` include
`<string.h>` (and, for `pyk_concat`'s `malloc`, `<stdlib.h>`) only in a
program that actually uses them — a program printing one integer pulls
in nothing beyond `<stdio.h>`.

## Evaluation order: the comma operator, not a hoisted statement

Pyking evaluates left to right; C does not say. The rule and the
generated shapes are in [target_c.md](target_c.md), "Evaluation order",
and the analysis that decides which operands need pinning down is
`analyses.Effects` (see [analyses.md](analyses.md)). What belongs here is
why the ordering is done *inside* the expression.

The obvious approach is to hoist: compute the operand into a variable in
a statement in front of the one that needs it, which is exactly what the
generated C would look like if a person had written it. It is wrong in
two places this backend supports:

- a `while` condition is evaluated again before every turn, so an
  assignment in front of the loop would run once and the loop would test
  a stale value;
- the branches of an `if` expression run only when chosen, so an
  assignment lifted out of one would run whichever branch was taken.

Both are ordinary programs here, and neither is detectable from inside
`expr`, which does not know what statement it is being translated for.
So `in_order`/`sequenced` use the comma operator instead: `(t = a, f(t,
b))` is a single expression, self-contained wherever it lands, and the
comma is a sequence point. It composes the way `target_ocaml.py`'s `let`
does, which is why the two backends' translation code reads the same
despite the very different output.

Two consequences worth knowing:

- **The temporaries are declared at the top of the function**, not
  beside their use, because a temporary written into a `while` condition
  has to outlive the condition it is assigned in. `_Translator.temps`
  collects them while a body is translated and `declarations` turns them
  into `CVarDecl`s; `function` prepends them, and `translate_program`
  does the same for `main`. Under `c89`, `_emit_block` already hoists
  declarations to the top of a block, so a `CVarDecl` joins that group
  and prints nothing of its own.
- **`print` is the exception**, because it is a statement here (a
  `CPrint`, not a `CExpr`): there is no expression to wrap, and none is
  needed, so its ordering assignments are emitted as plain statements in
  front of the `printf`. That also means `stmt` can answer with a list
  where it used to answer with one statement — every caller goes through
  `_as_stmts`.

A program whose functions only compute allocates no temporary and gets
byte-for-byte the output it got before any of this existed, which is the
property to preserve when changing it.
