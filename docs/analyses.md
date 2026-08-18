# `analyses.py`: design

How `src/analyses.py` checks names and scoping, gives every AST node a
unique symbol, and works out which expressions can print. For what the
rules *are* (as language, not
implementation), see PYKING.md, "Names and scoping"; for where this
module sits in the pipeline, see [architecture.md](architecture.md);
for a one-page summary, see [source.md](source.md#analysespy).

## The environment is a dict that gets rebuilt, not mutated

`analyze_program` and everything it calls thread one value through the
whole walk: `env`, a plain `{name: Binding}` dict. Every function that
introduces a name returns a **new** dict — `bind` is `return {**env,
name: Binding(kind, info)}`, never `env[name] = ...` — and that one
line is the entire mechanism lexical scoping is built from here. There
is no separate "push a scope" / "pop a scope" pair of operations, and
no stack of scopes to manage:

- **Entering a nested block** is simply "keep using the `env` you were
  handed." `analyze_scope(stmts, env)` calls `analyze_stmts(stmts,
  env)` and does nothing with what comes back.
- **Leaving one** is "go back to the caller's own `env`," which
  requires no action at all — the caller's local variable was never
  touched, because the callee only ever built new dicts on top of a
  *copy* of what it started with.

That is what makes a block's own bindings provably unable to escape it:
`analyze_if`'s `then_body`/`else_body` branches are each analyzed with
`analyze_scope`, whose return value the caller (`analyze_stmt`'s `SIf`
case) never uses — the environment `analyze_stmt` itself returns for
`SIf` is the *original* `env`, unchanged, exactly because nothing a
branch bound was ever folded back in. Contrast this with
`analyze_stmts`, which *does* thread the return value from one
statement to the next (`env = analyze_stmt(stmt, env)` in a loop) —
that's how `x = 1` followed by `print(x)` in the same block sees `x`:
each statement hands the next one its own extended copy, and the whole
sequence's final environment is simply whatever the last statement left
behind. **Whether a name escapes its block is entirely a question of
whose return value gets reused** — nothing more elaborate is needed,
and there is no environment-stack data structure anywhere in this file.

`typesystem.py`'s `Env` and `interpreter.py`'s persistent `Env` chain
both follow the identical discipline, for the identical reason — see
their own design pages.

## `analyze_stmt` returns an environment; `analyze_expr` doesn't

Every statement analyzer returns `{String: Binding}` — the environment
the statements *after* it should see — while every expression analyzer
returns nothing (`None`; its job is only to raise on the first unbound
name). That split is a direct reflection of the language: a Pyking
expression cannot introduce a binding visible to what follows it (there
is no `x := 1` expression form, no assignment-as-expression), but a
statement — `x = 1`, `var y = 2`, `def f(): ...` — can. `SReturn`,
`SExprStmt`, `SWhile` and the rest all return `env` completely
unchanged for the same reason: they don't bind anything, so what
follows them sees exactly what they saw.

## The one exception to "binding in source order": `def`

Every other binding form is visible only *after* itself — `x = x + 1`
reads whatever `x` meant before this line, then rebinds the name; the
`SLet` case in `analyze_stmt` is explicit about this, analyzing `expr`
before calling `bind_target`. A `def`, though, has to be visible
**throughout its whole block**, including above where it's written —
that's what makes recursion, mutual recursion between two functions,
and a helper defined at the bottom of a file all work (see PYKING.md).

`block_functions(stmts)` is what makes this safe rather than magical:
it collects every `SFunctionDef` at the top level of one block into a
`name -> node` dict *before* anything in the block is walked, checking
two things while it's at it — no two `def`s in the same block share a
name, and no *other* binding in the block (a `SLet`, a `SVar`, a loop
variable) shares a `def`'s name either (`check_no_function_clash`,
applied via `bound_names` for every non-`def` statement). Both checks
exist because a hoisted name has to mean exactly one thing throughout
its block; if two different statements could each claim it, "the
function named there" would be ambiguous depending on where in the
block you asked. `analyze_stmts` then binds every one of
`block_functions`'s results *first*, in one pass, before walking any
statement's actual body:

```python
def analyze_stmts(stmts, env):
    for stmt in block_functions(stmts).values():
        env = bind(env, stmt.name, FUNCTION, stmt.info)
    for stmt in stmts:
        env = analyze_stmt(stmt, env)
    return env
```

That two-pass shape — bind all the names, *then* walk all the bodies —
is the entire mechanism. By the time any function's body is analyzed
(inside `analyze_stmt`'s `SFunctionDef` case), its own name and every
sibling `def`'s name are already in `env`, so a call to any of them
resolves. `block_functions` deliberately only looks at *this* block's
top level, not nested ones — a `def` written inside an `if` branch is
hoisted only within that branch's own `analyze_scope` call, which is
why "hoisting" here never reaches further than the block that lexically
contains it. `typesystem.py`'s `declare_functions` and
`interpreter.py`'s `declare`/`define` both import `block_functions`
directly rather than reimplementing this logic, specifically so the
three passes cannot disagree about which programs are legal — see their
own pages.

## The one shadowing rule this module enforces

`bind` checks exactly one thing before adding a name: is there already
a **mutable** (`var`) binding of it in scope? If so, it refuses —
"a mutable variable may not be shadowed" — because that's what keeps
`:=` unambiguous. Once a name can mean two different `var`s depending
on which block you're standing in, `x := 1` would have to pick one, and
there is no good way to pick. Every *other* combination is fine: an
ordinary `=` binding may shadow an ordinary `=` binding, a parameter, a
loop variable — shadowing itself is not the problem, only shadowing a
mutable one is. `SMutate`'s own analysis (`analyze_stmt`'s `SMutate`
case) checks the complementary direction: `:=` targeting a name that
*isn't* `MUTABLE` — an ordinary binding, say — is refused too, with a
message naming what it actually is, since `:=` only ever means "update
this `var`."

`Binding(kind, info)` records not just *that* a name is bound but
*what kind* of thing bound it (`MUTABLE`, `BINDING`, `PARAMETER`,
`LOOP_VAR`, `PATTERN_VAR`, `FUNCTION`, `BUILTIN`) — which is what lets
every one of these error messages say something specific ("cannot
update `x` with `:=`: it is a parameter, not a mutable variable")
instead of a generic "cannot do that here." `where_bound` turns the
`info` half into "(declared on line N)" when there is one — a builtin
has none, since it was never written in this source file at all.

## Comprehensions are their own scope

`EListComp`'s case in `analyze_expr` is the one place an *expression*
analyzer extends the environment locally, because a list comprehension
genuinely is its own small scope: `[x + y for x in xs for y in f(x)]`
has to make `x` visible to `f(x)` (a later clause) and to the element
expression, but nowhere else. The loop over `clauses` accumulates
`comp_env` exactly the way `analyze_stmts` accumulates `env` across
statements — each `CompFor`'s pattern is bound into `comp_env` after
its own `sequence` is checked *against the environment so far* (so
`for y in f(x)` sees `x` from the clause before it, but the clause
binding `x` doesn't see itself) — and `comp_env` is a local variable
inside this one `case` arm, never returned, so none of it leaks past
the comprehension's own closing bracket.

## Symbols: a generic walk, so a new AST node needs no code here

`symbolize(stmts)` is unlike everything above it in this file: it
**rewrites** the tree rather than only reading it. Every node is a
frozen dataclass, so "rewrite" means "build a new tree with
`dataclasses.replace`," bottom-up — `renumber(node)` recurses into every
field first (so children get their symbols assigned before their
parent's own `replace` call happens), then replaces `node`'s `sym`
field if it was `0`.

The walk is written generically over `is_dataclass(node) and
hasattr(node, "sym")`, not as one `match`/`case` arm per AST node type.
That is a deliberate difference from every other tree walk in this
file (`analyze_expr`, `analyze_stmt`, ... are all one `match` per node
kind) and the reason is squarely practical: `syntax.py` has upward of
forty node kinds, and `symbolize`'s job — "give this node a number, and
recurse into its children, whatever they are" — doesn't actually depend
on *which* forty kinds. Writing it generically means a brand-new AST
node added to `syntax.py` gets symbolized for free, with nothing to
touch in this file; `analyses.py`'s CLAUDE.md entry says exactly this —
"`symbolize` needs nothing" when the language grows a construct. It is
the one place in the compiler where reflection over dataclass fields
substitutes for exhaustive pattern matching, and it works because the
job at hand (assign a number, recurse) is genuinely uniform across
every node kind, unlike name analysis or type checking, where each
kind means something different and *has* to be handled on its own
terms.

`_highest_sym` walks the same way, read-only, to find where numbering
should *resume*: `symbolize` starts its counter one past the largest
symbol already present, rather than always starting at 1. Combined
with "replace `sym` only if it was 0," this is what makes the function
**idempotent under extension** — running it twice on an already-fully
symbolized tree changes nothing (nothing has `sym == 0` left to
replace), and running it on a tree where *some* new nodes have been
spliced in since the last run (which nothing in this compiler currently
does, but a future pass might) assigns fresh numbers only to those,
without renumbering anything that already had one. That guarantee is
stated up front because it costs nothing to provide and is exactly the
property a pass that synthesizes new nodes into an already-symbolized
tree would need.

## `Effects`: what can print, for backends whose host does not fix the order

`Effects` is the one thing here the driver never runs. It answers a
question only a backend asks: *can evaluating this expression produce
output?*

Pyking evaluates left to right (PYKING.md, "Evaluation order"). Two of
the host languages do not promise anything: C leaves the order of an
operator's operands and a call's arguments unspecified, and OCaml does
the same. That is invisible for an expression that only computes, and
plainly visible the moment two of its pieces print — which is how the
difference reached the test suite in the first place, as
`tests/evaluation_order.pyk` passing on one machine and failing on
another (AArch64 and x86-64 disagree about a call's arguments, and both
are conforming).

So `target_c.py` and `target_ocaml.py` both need to know which operands
to pin down, and the answer is the same for both. It lives here because
it is an analysis of the Pyking AST — no C, no OCaml, nothing about
temporaries — and because one definition cannot drift from the other.

The computation is a fixed point over the program's call graph. A
function prints if its body calls `print` directly or calls a function
already known to print; the `while changed` loop repeats until a pass
adds nothing. Two decisions make it usable:

- **Conservative on the unknown.** A call whose target is not one of the
  program's own `def`s — a parameter of function type, say — cannot be
  resolved, so it counts as printing if *anything* in the program does
  (`unknown_prints`, which turns on once `printing` is non-empty and
  stays on). Overestimating costs a temporary nobody needed;
  underestimating prints in the wrong order. The error is deliberately
  pushed to the side that is only ugly.
- **Whole-program, once.** `Effects(stmts)` is built before translation
  starts and asked `may_print(expr)` many times, rather than recomputed
  per expression.

The backends differ only in what they do with the answer: OCaml inserts
a `let`, C assigns to a temporary and uses the comma operator. See
[target_ocaml_internals.md](target_ocaml_internals.md) and
[target_c.md](target_c.md), "Evaluation order".
