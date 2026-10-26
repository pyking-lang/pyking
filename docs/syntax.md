# `syntax.ml`: design

How `src/syntax.ml` represents the Pyking AST and prints it back out,
and why. For the AST itself as a reference (every variant and its
fields), read the file's own `datatype` comment block first — it is
meant to be read directly, not reproduced here. For where this module
sits in the pipeline, see [architecture.md](architecture.md); for a
one-page summary, see [source.md](source.md#syntaxml).

## Why `syntax.ml` and not `ast.ml`

Nothing forbids the shorter name now: OCaml module names live in a
namespace of their own, and an `Ast` module would shadow nothing. The
name is `syntax.ml` because everything else already says so — the
`open Syntax` at the top of a dozen modules, the docs, the error
messages — and because "syntax" is what the file holds: the shape a
program has after parsing, and the printer that puts it back.

It is worth knowing why the name was ever a question. The first
implementation was Python, where `src/` was a flat set of script
modules on `sys.path`: a file literally named `ast.py` would have sat
in front of the standard library's own, and `dataclasses` reaches that
one indirectly at class-definition time, so every module in the
compiler would have failed to import. That hazard is gone with the
language it belonged to.

## The AST as algebraic data types

Every node group — `expr`, `typ`, `pattern`, `comp_clause`,
`assign_target`, `stmt`, and the single-constructor `param`,
`list_rest`, `match_case` — is one variant type, with one constructor
per alternative: `EAdd`,
`ESub`, `EMul`, ... each carrying exactly the fields that variant needs.
This is the same shape `lexer.ml`'s `token` uses, and it is consumed
everywhere by `match` rather than by method dispatch. It is also the
shape the AST will keep once this compiler is rewritten *in* Pyking —
see CLAUDE.md — since Pyking's own variant types are meant to be read
the same way.

The type declaration says all of it: `type expr = EInt of ... | EAdd of
... | ...` is one closed set of alternatives, and a `match` over it that
misses a case is a compile error rather than a `None` returned at run
time. That is the one thing the first implementation could not have. It
was Python, where each variant was a frozen dataclass subclassing a
marker base class, and a dataclass can say what fields a class has but
not that the set of subclasses is closed — so the file stated it by hand,
in one comment block near the top:

```
# datatype Expr:
#     EInt(info: Info, value: Int, sym: Int)
#     EAdd(info: Info, left: Expr, right: Expr, sym: Int)
#     ...
```

That block is now the type declaration itself, and the drift it could
suffer is gone with it: the compiler reads the same text a reader does.
What survives from the comment block is the *legend* — `[T]` for a list
of `T`, `T?` for a field that may be absent — and the trailing comment on
each variant saying what it is written as in source. `[T]` in particular
is no longer only a comment: `expr list` says the element type outright,
where the Python could annotate a field `list` and nothing more.

What the old block bought, the type declaration keeps: **the whole shape
of the AST reads in one place**. Gathering every group in one recursive
`type ... and ...` also lets mutually referencing types be compared side
by side — `TFunction` mentions `stmt`, so reading whether the two agree
means reading two lines, not scrolling between two ends of the file.

The declaration orders the six alternative-types first and the three
single-constructor "records" last. One recursive `type ... and ...`
binds them all at once, so nothing has to be declared before it is
mentioned and the order is free to be the one a reader wants — which is
what the first implementation could not do: in Python a class had to see
a name before using it, so `EListComp` (which holds `[CompClause]`) was
declared after `CompClause` even though it belongs with the other `E*`
variants, and the comment block's order and the file's order disagreed.

Every node also carries two fields the grammar doesn't produce: `info` (its source span, attached by the
parser) and `sym` (`0` until `symbolize` — see `analyses.ml` — assigns
one post-order). Both are ordinary fields of the constructor, written
first and last; nothing mutates a tree in place, so a pass that needs to
change a node rebuilds it, which is exactly what `symbolize` does to
attach symbols after the fact.

## Two fields the desugarer empties

`param` carries a default (`Param of info * string * typ option * expr
option * int`) and an `ECall`'s arguments each carry the parameter name
they were written with (`(string option * expr) list`). Both are
`None` in every program any stage after `module.load` sees:
`desugar_args.ml` removes them, rewriting a default into a generated
`def` and putting a named argument back in its parameter's position
(see [desugar_args.md](desugar_args.md)).

They are fields of the existing nodes rather than nodes of their own on
purpose. A separate `ENamedArg` node would have been smaller to add and
would then need a case in every backend, the checker and the
interpreter — a case for something that can never reach them. Widening
instead means every consumer's `match` breaks once, the compiler finds
all of them, and the fix is a widened pattern rather than new
behaviour: `arg_exprs` drops the names, `plain_args` puts a bare
expression list back.

The printers do show both, which is what `--no-typechecking -t pyking`
prints and the only place the sugar's own form is pinned.

## `TFunction`: two fields the source never writes

Every other node's fields all come from parsing. `TFunction` is the one
exception, and it's worth understanding why. A parsed function type —
`(Int, Bool) -> Int` written in an annotation — has only `params` and
`result`; but the type checker (`src/typesystem.ml`) also needs to
represent *a function whose type was never written down*, deferred
until its first call (see [type_inference.md](type_inference.md)). That
needs somewhere to keep two more facts: which `def` this promise is
about (`definition`), and that `def`'s symbol (`tmsym`, used as a table
key because a symbol is a value and an AST node's identity is not one
you can hash reliably across a rebuilt tree). Rather than invent a
second type for "a function type still being worked out," `TFunction`
just grows two fields that are `None`/`0` for a type the parser built
and populated for one the checker built. `same_type` (in
`typesystem.ml`) ignores both when comparing two function types, since
neither is part of what the type *means* — only where it came from and
how much of it is still a promise.

## The pretty printer: precedence mirrors the parser, backwards

`pprint_expr`, `pprint_stmt`, and the rest exist so that `-t pyking` output
is itself valid Pyking — re-parsable, which is what makes
`-t pyking` a useful way to *see* what the checker inferred
rather than a debug dump only a human can read. That means every printer
has to solve the same problem the parser solved in the other direction:
decide when a sub-expression needs parentheses to force the same
grouping on re-parse.

The mechanism is `min_prec`, threaded through `pprint_expr` the way a
Pratt parser threads a minimum binding power: each call says "the
result must bind at least this tightly," and `_wrap(prec, min_prec, s)`
parenthesizes `s` exactly when its own precedence falls short. `EAdd`
prints its own operator at `prec_add` and asks its right operand for
`prec_add + 1` -- one *more* than its own -- which is what makes
`1 + (2 + 3)` keep its parens while `(1 + 2) + 3` sheds them: addition
is left-associative, so only the right side of one `+` ever needs
protecting from being re-associated. The levels are multiples of ten,
loosest first (`prec_low` for `lam`/`if`/`let`, then `prec_or`,
`prec_and`, `prec_not`, `prec_compare`, the bitwise ones, `prec_add`,
`prec_mul`, `prec_unary`, `prec_power`, `prec_atom`), which leaves room
for `level + 1`. `EConcat` prints as `+`, since a join is a `+` the
checker typed as a String or a list. The words `and`/`or`/`not` print
at their own level even where elaboration made them bitwise, which is
where the parser read them. `ENeg`'s comment spells out
the same idea for unary minus, including a case worth reading closely:
`-(-5)` is deliberately printed with parens around the inner negation
even though `--5` would parse identically, because a token that reads
as `--` looks like a mistake rather than a nested negation — a
readability decision layered on top of a correctness one.

`EIf`'s precedence (0, the loosest) is why an `if`-expression used
anywhere as an operand gets wrapped — `(if c then a else b) + 1` — while
its own `else` branch prints at precedence 0 too, on purpose: that is
what keeps an `else if` ladder flat (`if a then x else if b then y else
z`) instead of accumulating a parenthesis for every step, matching how
`parse_if_expr_tail` builds the chain by right recursion in the first
place. `SIf`'s statement-form printer does the analogous thing at the
statement level, but by a different mechanism — pattern-matching on the
shape of `else_body` in a loop, since statements don't have a precedence
to thread — collapsing a single nested `SIf` back into `else if:` rather
than an indented `else:` / `if:` pair. Both printers exist because both
parsers exist (`parse_if_expr_tail` for the expression, the loop in
`parse_if_stmt_tail` for the statement); each printer undoes exactly
the desugaring its own parser rule performed.

`ELambda` shares `EIf`'s precedence 0, and prints its body at 0 for the
same reason `EIf` prints its `else` branch there: a lambda associates to
the right, so `lam (x). lam (y). x + y` stays flat. Its parameter list
is *always* parenthesized, whatever the source wrote — `lam x. e` and
`lam (x). e` are the same node, and the parenthesized spelling is the
one the parser reads back whatever the parameters look like. A parameter's
type prints from `tmap` like every other annotation, so a lambda whose
parameter the source left bare prints with the type the checker worked
out for it.

## Printing what the checker knows, not what the source wrote

`pprint_program(stmts, symbols=False, tmap=None)` is the *only* entry
point any caller uses — not `pprint_stmt` or `pprint_expr` directly,
even though those are the functions that do the actual formatting. The
reason is `tmap`: the type checker has always run, so `-t pyking`
is supposed to show the types it *inferred*, which may differ from (or
simply exist where the source omitted) what was written. The checker
doesn't write into the AST — see `typesystem.ml`'s design note that it
touches nothing but its own `tmap` — so a printer that only looked at a
node's own `type` field would show the source's claim, not the
checker's answer.

`_node_type(node, annotation)` is the switch: if a `tmap` was given,
look up `node.sym` there and print *that*; otherwise fall back to the
node's own field. `annotation` and `function_header`/
`return_annotation` all route through it. The interesting corner is a
*parameter* whose own type is quantified — `f: all a. (a) -> a`, which
is what a body using its argument at two types infers (see
[type_inference.md](type_inference.md)). That `all` is not the
signature's outermost one, so unlike the outermost it has to be printed:
`f: (a) -> a` in a signature quantified further out is a different and
weaker claim, and printing it would say something the checker does not
enforce. `pprint_param` is where that is decided. The principle is
`typesystem.ml`'s own: when a type can't be written down in the syntax
available, print less, never print something that isn't true.

`spellable` applies that same principle one level down, to types rather
than to whole signatures. `TUnknown` prints as `?`, which the lexer does
not accept, and `TBuiltin` names an operation rather than a value — so
an annotation whose type holds one of them anywhere is left off
entirely. The type of `[]` used to be `[!]`, which made this an ordinary
program's problem rather than a corner of unreachable code: `xs = []`
printed as `xs = []` with no annotation at all, because `xs: [!] = []`
is not something this compiler can read back. Its element type is now a
flexible type variable, so it prints as `xs: [a] = []` and does read
back. `tests/typecheck_pyking_reparse.pyk` pins it.

`symbols` and `tmap` are **module-level variables** (`_show_symbols`,
`tmap`), not parameters threaded through every one of the dozen
printer functions. `pprint_program` sets them, calls the (parameterless,
from its own perspective) printers, and restores both in a `finally` —
so the flag exists for exactly the duration of one top-level call and
nothing recursive has to remember to pass it on. This works because
`pprint_program` is genuinely the only caller: nothing calls
`pprint_stmt` or `pprint_expr` from outside a `pprint_program` call
except other printer functions recursing into it, and the whole
operation is synchronous and single-threaded, so there is no
opportunity for one in-progress print to observe another's flags. It is
a deliberate trade of "global mutable state" (usually a smell) for
"twelve functions that don't need an extra parameter" — safe here
specifically because the scope of the mutation is pinned to one call.

`_sym(node, text)` is where `@n` actually gets appended, and it has one
piece of care worth noting: whether `text` needs parentheses *before*
the `@n` is added. `_SELF_DELIMITED` lists every node kind whose printed
form is already one token or already bracketed (`EInt`, `EList`,
`TargetName`, ...) — anything not on that list gets wrapped in parens
first, because `1 + 2` printed with symbols as `1@1 + 2@2@3` would put
the outer `EAdd`'s `@3` right after the `2`, reading as though it
belonged to the operand rather than the whole expression. Parenthesizing
first — `(1 + 2)@3` — removes the ambiguity the same way any of the
precedence parentheses do.

## Canonical forms

A few node kinds have more than one way to write the same thing, and
the printer always picks one, regardless of which the source used —
`(x,)` for a one-element tuple (never bare `x,`), fully parenthesized
tuples and tuple patterns (never the comma-only literal form some of
them can be parsed from). This is what makes `-t pyking` output a *useful*
canonical form to diff or to read: two programs that mean the same
tuple print identically, whatever punctuation the author chose.

Tuple *types* follow the value they describe, so `pprint_type` writes a
one-element tuple `(Int,)` with the same comma `(1,)` carries — and
grouping, having no shape of its own, simply disappears: a source
`(Int)` prints as `Int` and `((Bool))` as `Bool`. A comma written in a
*parameter list* disappears with it, `(Int,) -> Int` printing as
`(Int) -> Int`, since the arrow means there was no tuple there to make.
