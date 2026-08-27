# `syntax.py`: design

How `src/syntax.py` represents the Pyking AST and prints it back out,
and why. For the AST itself as a reference (every variant and its
fields), read the file's own `datatype` comment block first — it is
meant to be read directly, not reproduced here. For where this module
sits in the pipeline, see [architecture.md](architecture.md); for a
one-page summary, see [source.md](source.md#syntaxpy).

## Why not `ast.py`

The obvious name for "the AST module" is taken — by the Python standard
library. `src/` is a flat set of script modules, not a package (see
CLAUDE.md), so nothing shadows a top-level import the way a package's
own submodule would; a module here literally named `ast.py` would sit
on `sys.path` in front of the real one. That would not just break an
explicit `import ast` somewhere in this codebase — it breaks
`dataclasses` itself, which reaches the standard library's `ast`
indirectly through `inspect` at class-definition time, before any of
this project's own code has run. Every `@dataclass` in every module
would fail to import. The name `syntax.py` sidesteps the problem
entirely rather than working around it (e.g. with a package and
relative imports, which `src/` deliberately avoids for a different
reason — see CLAUDE.md on the self-hosting plan).

## The AST as algebraic data types

Every node group — `Expr`, `Type`, `Pattern`, `CompClause`,
`AssignTarget`, `Stmt`, and the single-constructor `Param`, `ListRest`,
`MatchCase` — is a Python base class with no fields of its own, plus
one frozen `@dataclass` per variant that subclasses it: `EAdd`,
`ESub`, `EMul`, ... all extend `Expr` and carry exactly the fields that
variant needs. This is the same shape `lexer.py`'s `Token` uses, for
the same reason: Python has no closed sum type, and a base class plus
one final subclass per alternative is the nearest approximation,
consumed everywhere by `match`/`case` rather than by method dispatch.
It also happens to be the shape a real variant type would take once
this compiler is rewritten *in* Pyking — see CLAUDE.md — so nothing
here is written to be clever with Python; it is written to translate.

A dataclass, though, can only say what fields a class has — not that
`EAdd` and `EInt` are two cases of one thing, and nothing *else* is. A
`match` over `Expr` implicitly assumes exactly that: every `case` arm
is only exhaustive if the set of subclasses is closed. Python's type
checker (if one is even running) can't verify it, so the file states it
by hand, in one comment block near the top:

```
# datatype Expr:
#     EInt(info: Info, value: Int, sym: Int)
#     EAdd(info: Info, left: Expr, right: Expr, sym: Int)
#     ...
```

This is documentation a reader can trust because — deliberately —
nothing generates it and nothing checks it against the dataclasses
automatically. That is a real cost (it can drift; CLAUDE.md calls this
out explicitly as the one place in the file that nothing catches
drifting) traded for a real benefit: **the whole shape of the AST reads
in one place**, in a notation chosen for what it can say and Python's
annotations can't — `[T]` records an element type a bare `list`
annotation loses, and `T?` records that a field may be absent, which
`x: Type = None` only implies. Gathering every group here also lets
mutually referencing types be compared side by side — `TFunction`
mentions `SFunctionDef`, so reading whether the two agree means reading
two lines, not scrolling between two ends of the file.

The comment block orders the six alternative-types first and the three
single-constructor "records" last — not the order the classes are
*declared* in below, which instead follows a different constraint:
Python has to see a name before it's used, so `EListComp` (which holds
`[CompClause]`) is declared after `CompClause`, even though it's a
variant of `Expr` and so belongs with the other `E*` classes in the
comment block. The comment's order is for a reader; the file's order is
for the interpreter.

Every node also carries two fields the comment block includes but the
grammar doesn't produce: `info` (its source span, attached by the
parser) and `sym` (`0` until `symbolize` — see `analyses.py` — assigns
one post-order). Because every dataclass is frozen, nothing mutates a
tree in place; a pass that needs to change a node rebuilds it with
`dataclasses.replace`, which is exactly what `symbolize` does to attach
symbols after the fact.

## `TFunction`: two fields the source never writes

Every other node's fields all come from parsing. `TFunction` is the one
exception, and it's worth understanding why. A parsed function type —
`(Int, Bool) -> Int` written in an annotation — has only `params` and
`result`; but the type checker (`src/typesystem.py`) also needs to
represent *a function whose type was never written down*, deferred
until its first call (see [type_inference.md](type_inference.md)). That
needs somewhere to keep two more facts: which `def` this promise is
about (`definition`), and that `def`'s symbol (`tmsym`, used as a table
key because a symbol is a value and an AST node's identity is not one
you can hash reliably across a rebuilt tree). Rather than invent a
second type for "a function type still being worked out," `TFunction`
just grows two fields that are `None`/`0` for a type the parser built
and populated for one the checker built. `same_type` (in
`typesystem.py`) ignores both when comparing two function types, since
neither is part of what the type *means* — only where it came from and
how much of it is still a promise.

## The pretty printer: precedence mirrors the parser, backwards

`pprint_expr`, `pprint_stmt`, and the rest exist so that `--ast` output
is itself valid Pyking — re-parsable, which is what makes
`--typecheck --ast` a useful way to *see* what the checker inferred
rather than a debug dump only a human can read. That means every printer
has to solve the same problem the parser solved in the other direction:
decide when a sub-expression needs parentheses to force the same
grouping on re-parse.

The mechanism is `min_prec`, threaded through `_pprint_expr` the way a
Pratt parser threads a minimum binding power: each call says "the
result must bind at least this tightly," and `_wrap(prec, min_prec, s)`
parenthesizes `s` exactly when its own precedence falls short. `EAdd`
prints its own operator at precedence 2 and asks its right operand for
precedence 3 (`pprint_expr(r, 3)`) — one *more* than its own — which is
what makes `1 + (2 + 3)` keep its parens while `(1 + 2) + 3` sheds them:
addition is left-associative, so only the right side of one `+` ever
needs protecting from being re-associated. `EConcat` prints at the same
two numbers, since `++` shares `+`'s level and associativity. `ENeg`'s comment spells out
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

## Printing what the checker knows, not what the source wrote

`pprint_program(stmts, symbols=False, tmap=None)` is the *only* entry
point any caller uses — not `pprint_stmt` or `pprint_expr` directly,
even though those are the functions that do the actual formatting. The
reason is `tmap`: when the type checker has run, `--typecheck --ast`
is supposed to show the types it *inferred*, which may differ from (or
simply exist where the source omitted) what was written. The checker
doesn't write into the AST — see `typesystem.py`'s design note that it
touches nothing but its own `tmap` — so a printer that only looked at a
node's own `type` field would show the source's claim, not the
checker's answer.

`_node_type(node, annotation)` is the switch: if a `tmap` was given,
look up `node.sym` there and print *that*; otherwise fall back to the
node's own field. `_annotation` and `_function_header`/
`_return_annotation` all route through it. The interesting corner is a
`def` the checker gave more than one type — `merge` in `typesystem.py`
built a `TOr` for it, because it was called at two different argument
shapes (see [type_inference.md](type_inference.md)) — and there is
simply no slot in `def name(params) -> result` syntax to write two
answers at once, one per parameter and one per result, correlated. Given
that, `_function_header` falls back to printing the `def` exactly as
written, annotations and all, rather than trying to cram an
uncorrelated summary into a shape that can't hold it. That is the same
principle `typesystem.py`'s own design note states about `merge`: when
a type can't be written down in the syntax available, print less, never
print something that isn't true.

`symbols` and `tmap` are **module-level variables** (`_show_symbols`,
`_tmap`), not parameters threaded through every one of the dozen
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
them can be parsed from). This is what makes `--ast` output a *useful*
canonical form to diff or to read: two programs that mean the same
tuple print identically, whatever punctuation the author chose.
