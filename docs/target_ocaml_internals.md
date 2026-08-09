# `target_ocaml.py`: internals

How `src/target_ocaml.py` is built: why it's the one backend that
infers no types of its own, how a Pyking *block* becomes a single
OCaml *expression*, how it fixes the one place Pyking and OCaml
disagree about evaluation order, and how it groups mutually recursive
functions into `let rec ... and ...`. For what's supported and how each
construct compiles, see [target_ocaml.md](target_ocaml.md); for a
one-page summary, see [source.md](source.md#target_ocamlpy).

## The one backend that doesn't infer

Every other backend in this compiler solves some version of "Pyking
doesn't require types, but my target language does" — `target_c.py`
and `target_java.py` build their own small inference (see
[target_c_internals.md](target_c_internals.md)); `target_python.py`
and `target_js_core.py` don't need types at all, since Python and
JavaScript are as dynamically typed as Pyking. This module takes a
third path, and it's worth understanding why it's available here and
nowhere else: **OCaml is statically typed, but this backend's accepted
subset is exactly `typesystem.py`'s own** (see PYKING.md, "Type
checking," and `type_inference.md`), so rather than reimplementing type
inference, `translate_program` simply *runs the real checker* first —
`typesystem.type_check(stmts)` — and reads every expression's type back
out of its `tmap` when it needs one (`type_of`, `self.tmap[expr.sym]`).
That's only possible because `check_expr` records an entry for *every*
expression it reaches, not just the annotatable ones — a property
`typesystem.py`'s own page notes exists specifically so this backend
(and nothing else) can lean on it. A program that doesn't type-check
never reaches translation at all: `_checked_types` catches the
checker's own exception and re-raises it framed as this target's
limitation, keeping the checker's original wording rather than
inventing a second description of the same problem.

The payoff shows up as a genuine difference in what this backend can
express versus `target_c.py`/`target_java.py`: because it isn't
guessing (`_used_as_string`'s fallback has no OCaml equivalent), it
never has the class of bug the C backend documents as "not optimal" —
a parameter whose type can't be told from local evidence alone. And
because its subset moves in lockstep with the checker's, this is the
one backend whose accepted-language grows automatically whenever
`typesystem.py`'s does, with nothing here to update.

## Why the OCaml AST is so much smaller

`OExpr` has roughly a dozen variants; `PyExpr`/`JsExpr`/`CExpr` each
have closer to twenty. The reason is structural, not an oversight:
**OCaml is an expression language.** A Pyking *block* — a sequence of
statements — has no direct OCaml equivalent, because OCaml has no
statements at all in the sense Pyking, C, Java, and (mostly) Python do;
everything is an expression, sequenced with `;` or nested with `let
... in`. So where every other backend's AST needs a `Stmt`-shaped half
mirroring `syntax.py`'s own split, this one doesn't — `_Translator.block`
takes a whole `[Stmt]` and returns **one** `OExpr`, and every "kind of
statement" Pyking has becomes a decision about which OCaml expression
form represents it, not a new node.

`block(stmts, tail)`'s `tail` parameter is what decides the shape of
that one expression: whether the last statement supplies a value (a
function body, `tail=True`) or the block runs purely for effect (the
top level, or a branch of a unit-valued `if`, `tail=False`). Everything
before the last statement becomes an `OLet` (a Pyking binding) or an
`OSeq` (anything else, sequenced with OCaml's `;`) wrapping the
translation of what follows — which is precisely the shape a Pyking
block already has: one binding or effect after another, with the last
one mattering differently depending on where the whole block sits.

One shape gets special recognition before the general case: `if c:
return x` followed by more statements is the one form of early exit
OCaml *can* express, as `if c then x else <the rest>` — `block` checks
for exactly this pattern (`_definitely_returns(first.then_body)` with
statements still following) before falling through to the general
"can't have statements after an unconditional return" refusal
described in `target_ocaml.md`, "A `return` that is neither in tail
position nor a guard."

## Fixing evaluation order: `_Effects` and `in_order`

Pyking evaluates an operator's operands, and a call's arguments, left
to right. OCaml's own evaluation order is unspecified (and, in
practice, usually right to left) — invisible for anything that only
computes, and very visible the moment two operands can each **print**.
Getting this right needs two things: knowing *which* expressions can
print, and a way to force an order once it matters.

**`_Effects`** answers the first question with a small fixed-point
computation over the whole program's call graph, run once before
translation starts. A function "prints" if its body calls `print`
directly, or calls another function already known to print — computed
by repeatedly scanning every function's body and adding to
`self.printing` until a pass finds nothing new to add (the `while
changed` loop in `__init__`). The one deliberately conservative piece:
a call whose target *isn't* one of the program's own `def`s — a
parameter of function type, say — can't be resolved to a specific
function, so it's treated as printing if **any** function in the whole
program does (`self.unknown_prints`, which only turns on once
`self.printing` is non-empty, and once on stays on). Overestimating
who might print is safe here — it costs an occasional unnecessary
`let`, never a wrong answer — and underestimating would risk silently
printing in the wrong order, so the analysis is built to err in the
safe direction.

**`in_order(exprs)`** is where that answer gets used. It translates
every expression in `exprs` (an operator's two operands, or a call's
argument list) up front, checks how many of them `self.printing.may_print`
says could produce output, and — only when **two or more** can — pulls
every one but the *last* out into its own `let`, via a fresh temporary
name (`fresh_name`, checked against `_unused_prefix`'s guaranteed-unused
prefix, computed once per program the same way
`target_python.py`'s comprehension-helper names are checked against
`_used_identifiers`). The last expression can stay exactly where it is,
because nothing *after* it in the pulled-out sequence could ever be
reordered ahead of it — there's nothing left to reorder against. A
program whose functions only compute — nearly every Pyking program —
finds `may_print` false for everything, takes the `len(effectful) < 2`
early return, and pays nothing: operands stay exactly where the source
wrote them.

## Grouping mutually recursive functions

`let rec ... and ...` binds a *group* of functions that has to be
written together — OCaml has no way to say "these three are mutually
recursive" if a fourth, unrelated statement sits between two of them
in the block. Pyking's own rule is looser (every `def` in a block sees
every other, wherever each is written), so `groups(run, later)` has to
decide, for one run of consecutive `def`s, which of them actually *need*
to be bound together and which can be independent `let`s.

The algorithm is a small union-find over the block's own statement
indices: two `def`s merge into one component if either's *translated*
body's free variables (`_free_in_binding`, walking the already-built
`OExpr`, not the Pyking AST — see below) name the other — an
unrelated, much simpler structure than `typesystem.py`'s type-inference
`Store`, just `parent`/`root`, path-compressed, over a handful of local
indices. Once the components are found, each one becomes a `let rec`
group only if the group's own members reference names *outside
themselves that the group as a whole needs* (`captures`, after
subtracting the group's own bound names); otherwise, since nothing
forces them together, they translate as ordinary sibling `let`s.

The walk deliberately reads **translated** OCaml bindings rather than
the original Pyking AST, because only there are the binders explicit
enough to answer "does this body actually *recurse* through this name,
or does it merely shadow it with a local `let`?" — a Pyking body that
rebinds its own function's name locally reads that local binding, not
the recursive one, and a search over raw Pyking source text (or an
unscoped name search) couldn't tell the difference.

`_check_no_split_group` is the refusal path: if a `def` in one run
names a `def` in a *later* run — i.e., something other than another
`def` sits between them — there is no legal `let rec` for that pair,
because moving the group down past whatever's in between would change
which binding of some other name its body captures (Pyking's own
capture rule is positional — see PYKING.md, "Names and scoping"), and
silently relocating a group to make it compile would be exactly the
kind of quiet meaning-change this backend refuses to make. See
`target_ocaml.md`, "A `def` naming one written further down, with
something in between," for the error this produces and a worked
example.

## The polishing pass: silencing warnings before OCaml can raise them

OCaml's compiler warns about a bound name nothing reads — reasonably,
since it's usually a mistake, but a *reader* of generated code has no
way to act on a warning about code they didn't write by hand. Rather
than let warnings through (and, per `docs/architecture.md`'s note on
this target's test harness, a warning here is a **failing test** — the
suite builds with `-w +a`), `_polish` walks the translated tree and
renames every `let` binding nothing reads to `_name`, OCaml's own
convention for "deliberately discarded." This is not a hypothetical
case: `x = expr` is an ordinary Pyking statement whose only purpose can
legitimately be running `expr` for its side effect, discarding the
result — a case the language itself allows and this backend has to
translate cleanly rather than let the OCaml compiler flag as suspicious
code it never wrote by choice.

`_polish_items`'s comment about reading the top level **back to
front** is the one genuinely tricky piece: whether a top-level binding
is "read" depends only on what comes *after* it (an earlier binding a
later one shadows is dead, unless something between the two reads it
first), so `_rename_dead` walks each binding against the items that
follow it, not the ones before — the only direction in which
"liveness" is actually a well-defined question at all.
