# `parser.py`: design

How `src/parser.py` turns a token list into the AST from `syntax.py`,
and why it is shaped the way it is. For the grammar itself, see
PYKING.md; for where this module sits in the pipeline, see
[architecture.md](architecture.md); for a one-page summary, see
[source.md](source.md#parserpy).

## The shape every function shares

Every parsing function has the same signature: tokens in, `(node,
rest_of_tokens)` out. There is no shared mutable position (no "cursor"
object, no index into a fixed array) — a parser function consumes some
prefix of its input and hands back exactly what is left, and the caller
decides what to do with it. This is what a token list bought back at
`lexer.py`'s door: because `lexing` returns `[Token]` rather than an
iterator or a stream, every parsing function can pattern-match on its
own prefix (`case [TokIdent(info, name), *rest]:`) and simply return
`rest`, the tail Python's own list slicing already computed. There is
no off-by-one bookkeeping anywhere in this file — no function ever
writes `tokens[i]` — because there is no `i`.

The trade is that "the position" is threaded explicitly through every
return value instead of hidden in an object. That is more verbose
locally (`first, rest = parse_expr(rest)` appears hundreds of times) but
it is also what makes backtracking safe by construction: nothing to
undo, because nothing was mutated. `_try_parse_assignment_target`
(below) leans on exactly this — it can attempt a parse and simply throw
the result away on failure, because failing to consume anything never
happened; the caller's own `tokens` binding is untouched either way.

## Recursive descent, one function per precedence level

Pyking's expression grammar is parsed by **precedence climbing** written
out as a chain of functions, each one level tighter than the last:

```
parse_atom → parse_call_tail → parse_unary → parse_multiplicative
  → parse_additive → parse_comparison → parse_expr → parse_tuple_or_expr
```

Each function calls the next-tighter one for its operands and handles
exactly one precedence level itself. `parse_additive` is a representative
one to read closely:

```python
def parse_additive(tokens):
    left, rest = parse_multiplicative(tokens)
    while True:
        match rest:
            case [TokAdd(_), *rest2]:
                right, rest2 = parse_multiplicative(rest2)
                left, rest = EAdd(combine_info(left.info, right.info), left, right), rest2
            case [TokConcat(_), *rest2]:
                ...
            case [TokSub(_), *rest2]:
                ...
            case _:
                return left, rest
```

`parse_type` follows the same shape one level down: `parse_type_arrow`
is where a single parameter needs no parentheses (`x -> x` is
`(x) -> x`), and the parenthesized branch of `parse_type_atom` reads a
list followed by `->` as a parameter list and one without as a tuple --
except for a single type in parentheses, which is *grouping*, since
`(1)` is likewise just `1` among values.

The `while True` loop, not recursion, is what makes `+`/`++`/`-`
**left-associative**: `1 + 2 + 3` parses as `parse_multiplicative` reads
`1`, then the loop sees `+`, reads `2` with another call to
`parse_multiplicative`, builds `EAdd(1, 2)`, loops again, sees `+`,
reads `3`, and builds `EAdd(EAdd(1, 2), 3)` — always folding the new
term onto the *left* of what came before. A recursive call on the right
side instead (`parse_additive(rest2)` in place of
`parse_multiplicative(rest2)`) would build right-nested trees and give
`+` the wrong associativity; every level in this chain that *is*
left-associative is careful to recurse into the next-tighter function
for its operand, not into itself. `parse_comparison`, by contrast,
does **not** loop — a second comparison operator after the first simply
isn't matched, which is what "comparisons do not chain" means at the
parser level: `1 < 2 < 3` parses `1 < 2` and then stops, leaving `< 3`
for the caller (`parse_statement`'s catch-all) to reject as leftover
input rather than nonsense sitting inside one expression.

`parse_unary` is unusual in the chain: it recurses into *itself*
(`operand, rest = parse_unary(rest)`) rather than the next level down,
because unary minus is prefix and can stack (`- -x`, though the printer
always parenthesizes a re-negation — see `syntax.md`). It falls through
to `parse_atom` the moment the next token isn't another `-`, which is
the base case.

`parse_expr` sits at the *loosest* level, not the tightest — it is
where `if`-expressions are recognized, since `if c then a else b` has to
bind looser than every operator (`1 + if c then 2 else 3` should parse
the addition around the whole conditional, not swallow only part of
it). `parse_tuple_or_expr`, one level looser still, is where a bare
comma turns one expression into a tuple literal — kept as a separate
function from `parse_expr` because a comma is *not* legal everywhere an
expression is (inside a call's argument list, for instance, the comma
means "next argument," so `parse_args` calls `parse_expr` directly and
never sees `parse_tuple_or_expr` at all).

## `parse_atom` and the token-that-decides

`parse_atom` is the base of the precedence chain, and it is also where
almost every piece of punctuation gets dispatched: a literal, a name, a
parenthesized group, a list, or a list comprehension, distinguished
entirely by pattern-matching the token(s) in front. The one genuinely
interesting case is `(`, because Pyking overloads parentheses across four
different meanings, and the parser has to read past the first sub-expr
to know which:

```python
case [TokLParen(lp_info), *rest]:
    first, rest = parse_expr(rest)
    match rest:
        case [TokComma(_), TokRParen(rp_info), *rest]:   # (e,)  singleton tuple
        case [TokComma(_), *rest]:                          # (e, e, ...) tuple
        case [TokRParen(rp_info), *rest]:                   # (e)  just grouping
```

`(e)` and `(e,)` are one token of lookahead apart, and the parser reads
that one token — is the next thing `,` or `)` — only *after* it already
has `first` in hand, rather than trying to guess up front. This is the
same idea `parse_tuple_tail` uses for a target or a pattern: parse one
element, then decide from what follows whether there is a tuple here at
all. `EList`'s open bracket does the analogous three-way split between
an empty list, a list literal, and a list *comprehension* — the
distinguishing token there is `for`, checked right after the first
element, which is also where Python's own grammar makes the same
decision for the same reason.

## `combine_info`: spans are built, never copied

Every node's `info` covers from its first token to its last. There is
no token that means "end of expression," so a node's span has to be
assembled explicitly, and `combine_info(start, end)` is the one
function that does it — `Info(start.file, start.row1, start.col1,
end.row2, end.col2)`, taking the *start* of one span and the *end* of
another. Every construct with more than one token follows the pattern
`combine_info(first_thing.info, last_thing.info)`; a single-token
node (`EInt`, `TokAdd` turned into nothing since operators have no
node of their own) just reuses that token's `Info` outright. The
convention matters because it is what a source-position error can rely
on: a `def`'s `Info` reaching all the way to its closing statement,
say, is not something the lexer could ever have known — only the
parser, once it has actually found the end, can say where a whole
construct really stopped.

## Where the grammar is not LL(1), and how that's handled without backtracking

Two places in the grammar need more than one token of lookahead to know
which rule applies, and the parser resolves both **by parsing the
shared prefix once**, rather than by speculatively trying one
alternative and rewinding on failure.

**`if` as a statement vs. as an expression statement.** `if cond: ...`
(a statement) and `if cond then a else b` (an expression, standing alone
as a statement) share the entire `"if", cond` prefix — and `cond` can
be arbitrarily long, so no fixed lookahead distinguishes them in
advance. `parse_statement`'s `case [TokIf(info), *rest]:` arm parses
`cond` exactly once with the ordinary `parse_expr` (which already knows
how to parse an if-*expression* as a sub-expression, so a condition
that is itself `if a then b else c` needs no special case), and only
then looks at the very next token — `:` or `then` — to decide which
tail parser to call, `parse_if_stmt_tail` or `parse_if_expr_tail`. No
token is ever un-consumed.

**Assignment targets vs. plain expressions.** `x = 1` (a binding) and
`x` alone (an expression statement) start with the same token, but
worse: `a, b = 1, 2` means the target can be an arbitrarily long,
possibly nested, comma-separated prefix — genuinely not somthing a
fixed number of lookahead tokens can rule in or out. Here the parser
*does* speculate, but safely, because of the "no mutation" property
from the top of this page: `_try_parse_assignment_target` calls
`parse_target`, catches `ParseError`, and returns `None` on failure —
at which point `parse_statement`'s `case` simply falls through to the
next arm, `parse_tuple_or_expr`, and reparses the same tokens from
scratch as a plain expression. Nothing was consumed by the failed
attempt because nothing outside the local `target, rest = ...` binding
was ever touched. The call happens inside the `case` pattern's own
guard —

```python
case [TokIdent() | TokLParen(), *_] if (
    _assign := _try_parse_assignment_target(tokens)
) is not None:
```

— using a walrus assignment so the work of the speculative parse
(finding the target, its annotation, and the position just after `=`)
isn't thrown away and redone if the guard succeeds; the guard's own
result becomes `_assign`, unpacked on the next line. Once the target
*and* a following `=` are both found, the choice becomes committed —
finding a `:` after the target is enough to treat a type-annotation
parse failure past that point as a real error rather than another
reason to fall through, since a target followed by `:` cannot mean
anything else. That's the comment on the `TokColon` match inside
`_try_parse_assignment_target` making that distinction explicit.

## Value-form `if`/`match`: one AST shape, two positions

`x = if c: ...` and `return if c: ...` are two different places the
same construct can appear — a value-form `if` or `match`, whose
branches are statements ending in an expression rather than a single
expression the way the *expression* form's `then`/`else` are. Both
routes go through **`parse_bound_value`**, which returns either a
plain `Expr` or a `Stmt` (an `SIf`/`SMatch` built with the *statement*
grammar), and the caller distinguishes the two with `match value: case
Stmt(): ...`. This is why `SLetStmt` and `SReturnStmt` exist as
separate node kinds from `SLet`/`SReturn` in `syntax.py`: the thing
being bound or returned is structurally a statement, not an expression,
and the AST says so rather than pretending otherwise.

`_check_value_stmt`/`_check_value_block` are what make that legal in
the first place: a value-form `if` must have an `else` (unlike the
statement form, where a missing `else` just means "do nothing" — but
here every path must supply a value), and every branch must *end* in an
expression or in a nested if/match that recursively does. Neither rule
is expressible in EBNF — "every branch of this production ends in an
expression-statement, recursively through nested ifs" is not a
context-free grammar rule, it's a property checked by walking the
already-parsed tree — which is why it lives here, as a post-parse
check over the `SIf`/`SMatch` `parse_bound_value` just built, rather
than as a grammar rule that could reject the input by construction.
`_expect_expr_value` is the complementary check for positions that
*don't* accept the statement form (a `var` declaration, a `:=`
mutation) — `parse_bound_value` is reused
there too, since the indentation rule ("a bound value may start on the
next line, indented") is identical, and only afterward is the result
narrowed back down to "must have been a plain expression."

## Checks that live here because nowhere else can do them cheaply

Five rules are enforced by this module even though they are, in a
sense, "not parsing":

- **`_check_no_duplicate_captures`** — a pattern may not bind the same
  name twice (`case (x, x):`). This *could* wait for `analyses.py`'s
  name-scoping walk, but by the time that runs, the error would be
  reported without the specific "this pattern, right here" framing a
  parse-time check gets for free, since the pattern is still the
  thing on the parser's hands. It is called at every point a pattern
  finishes parsing — `parse_case`, and each comprehension's `for`
  clause in `parse_comp_clauses` — rather than once at the top, since a
  pattern can appear in more than one place a program is built from.
- **`_check_value_stmt`** (above) — a rule about tree shape once
  parsing already produced the tree, not about the token stream.
- **`_check_loop_context`** — a `break`/`continue` belongs to the
  innermost `loop` it is written in, and may not reach out of a `for`, a
  `while` or a `def` to find one. It is a walk of the finished program
  from `parse`, carrying two things: the loop currently in hand, and
  what cut it off if something did — which is what lets the message say
  *why* ("this one is inside a `for`, which it may not reach out of")
  rather than only that no loop was found. It is here rather than in
  `analyses.py` for the same reason `_check_value_stmt` is: it needs
  only the tree's shape, never what a name means. Being here, it also
  holds under `--typecheck`, which replaces the name analysis entirely.
- **`_check_reachable`** — nothing may be written after a `break` or a
  `continue` in the same block, since nothing there can run. It is
  applied as each block is built, comparing the statement just parsed
  with the one before it, so the position blamed is the unreachable
  statement's own. Deliberately *not* extended to `return`: statements
  after one are ordinary Pyking, and a branch that returns early is a
  normal way to write a body.
- **`_check_own_line`** — see below.
- **`_on_header_line` / `_check_inline_value` / `_check_ends_line` /
  `_check_nothing_indented`** — the other half of the same
  reconstruction, in `parse_block`: a block may be the single
  *expression* written on its header's own line. "Own line" is again
  read off the rows the tokens carry — the first token after the `:`
  starts on the row that `:` ends on (`_on_header_line`). Deciding it
  there rather than by "is there a `TokIndent`?" is what keeps a block
  written on the *next* line without indentation the error it always
  was. The other three are what "one expression, and the line ends
  there" means: `_check_inline_value` refuses anything but an
  `SExprStmt` (a `return`, a binding, a nested header), so nothing
  hides behind a `:`; `_check_ends_line` refuses an `else` that shares
  the line its block ended; `_check_nothing_indented` refuses an
  indented block under one, which would belong to nothing. A second
  statement on the line is left to `_check_own_line`, which already
  covers it. See PYKING.md, "A block on its header's own line".

## `_check_own_line`: reconstructing a fact the lexer didn't record

`lexer.py` emits no token for "end of line" (see `docs/lexer.md`) — only
`TokIndent`/`TokDedent` say anything about line structure at all. That
is what makes `print h` parse as two separate atoms rather than one
call, since there's no space in the grammar for "a bare name directly
followed by another bare name" to mean anything: `parse_atom` parses
`print` as a call-less `EVar`, hands back `rest` starting at `h`, and
the *statement* parser is left holding two adjacent things it has no
rule for gluing together. Silently accepting that (parsing `print` as
one statement and quietly starting a new one at `h`, discarding
`print`'s value) would be a real bug — and it is exactly the bug this
function exists to catch instead.

`_check_own_line(previous, current, what, describe)` looks at nothing
but the two nodes' `Info`: if `current` starts on the same row
`previous` ended on, that's the tell — two things that should each have
been on a line of their own are sharing one. This works precisely
*because* every node's span was built by `combine_info` to reach all
the way to its real end, so "same row" is a reliable proxy for "these
two are adjacent with nothing (not even a newline) between them,"
without the lexer ever having tokenized "end of line" as a thing in its
own right. It's called after every statement in `parse_block` and
`parse`, and after every `case` clause in `parse_cases` — the two
places a sequence of same-kind things is read one at a time — with a
`describe` callback (`_statement_text`/`_case_text`) that renders each
side back through `pprint_stmt`/`pprint_pattern` so the error message
can *show* what the parser thinks it read as each half:

```
'prog.pyk' 1:6-1:8 Parsing error: each statement must start on a new
  line. In this case, 'print' and 'h' are seen as two different
  statements
```

`_shorten` caps that rendering at `_QUOTE_LIMIT` (32) characters so a
long statement doesn't blow out the error message; the limit is chosen
to be long enough to be recognizable and short enough that two of them
plus a sentence still read as one line.

## Errors: one exception, no recovery

Every failure is a `ParseError(info, message)`, and there is no
recovery: the first mistake stops the parser, the way the lexer stops
at the first lexical one. `_here(tokens)` supplies the position to
blame when there's no token left to point at (an empty `rest`) — the
last real token's `Info`, cached in the module-level `_eof_info` by
`parse` before the main loop starts, so every inner function facing
"ran out of input" has somewhere sensible to point without having to
carry the original token list's tail down through every call. As with
the lexer, this is a deliberate floor rather than an oversight: see
`design/plan-eval-lsp.md` for where per-token diagnostics with
recovery are planned and why they aren't built yet.
