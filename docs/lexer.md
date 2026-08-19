# `lexer.py`: design

How `src/lexer.py` turns source text into tokens, and why it is built
the way it is. For what indentation *means* in the language, see
PYKING.md, "Indentation-based blocks"; for where this module sits in
the pipeline, see [architecture.md](architecture.md); for a one-page
summary of its data structures and functions, see
[source.md](source.md#lexerpy).

## Why a list of characters, not a string

`lexing(file, chars)` takes `chars: [Char]` — the result of `list(str)`
— not the string itself. The whole lexer is one `match rest: case
[x, *xs]: ...` block, and structural pattern matching on a list is what
lets a rule like

```python
case ["<", "=", *xs]:
    tokens.append(TokLessThanEq(fi(r, c, 2)))
```

read as "the next two characters are exactly these," with the
unmatched remainder bound to `xs` in the same line. A string doesn't
destructure that way in Python; slicing it (`s[0:2] == "<="`) says the
same thing but not as one pattern, and doesn't bind the rest for the
next iteration. The list is walked by *rebinding* `rest` each time
through the loop (`rest = ys`), not by an index into the original
string — there is no `i += 1` anywhere in this function. That is a
direct consequence of pattern matching driving the control flow: each
`case` produces the new remainder itself, as `xs` or `ys`, rather than
a length for the caller to advance by.

The cost is that every arm still has to track `r`/`c` (row, column) by
hand, since the list itself carries no position information — only the
tokens built from it do, via `fi(r, c, length)`, a closure over the
lexer's local `r`/`c`.

## Tokens: one dataclass per kind

Every token is a frozen dataclass — `TokInt(info, value)`,
`TokAdd(info)`, `TokIdent(info, value)`, and so on — subclassing the
`Token` marker base class, rather than one `Token(kind, value)` class
with a `kind` field. `TokAdd` and `TokIdent` are only two variants of
the same thing, but Python has no built-in sum type to say so, and this
is the closest approximation: a base class states "one of these," and
each subclass states one alternative's shape. `src/syntax.py`'s AST and
every backend's own AST (`Py*`, `Js*`, `C*`, ...) repeat the same
pattern for the same reason — see CLAUDE.md's note on why: this is
meant to become an actual variant type once the compiler is rewritten
in Pyking, and the dataclass-per-variant style is the version of that
idea Python can express today. `pprint_token` is what a `match` over
that type looks like: one `case TokXxx():` arm per variant, each
returning what a debugger would want to see.

Two thirds of the `Tok*` classes hold only `info` — punctuation and
operators have nothing else to remember. `TokInt`, `TokString` and
`TokIdent` carry a `value` because their identity *is* their content.
`TokIndent`/`TokDedent` carry only `info` too, despite meaning
something structural — see below.

## Indentation as tokens

The parser never looks at columns. Instead, the lexer turns a change in
indentation into ordinary tokens, `TokIndent` and `TokDedent`, spliced
into the stream at the point the change happens — so `parse_block` in
`parser.py` can treat a block exactly like a bracketed construct,
consuming a `TokIndent`, statements, and a `TokDedent`, the same way it
would consume `(`, arguments, `)`. This is the standard trick for
adding Python-style layout to a recursive-descent parser without
threading column state through every grammar rule, and it is why this
module — not `parser.py` — is where "indentation must be a multiple of
4 spaces" and "unindent does not match any outer indentation level" are
raised: those are lexical facts about a line's leading whitespace, not
facts about grammar.

The mechanism is `indent_stack`, a list of indentation *levels*
(`len(spaces) // 4`, not raw column counts), starting at `[0]`, plus a
`line_start` flag that is true only at the beginning of a line and
turned off the moment the lexer has looked at that line's leading
spaces once — which is what stops "is this line more or less indented"
from being asked again for every token on the line. The rule, checked
only when `line_start` is true and the line is not blank or a
comment (`x != "\n" and x != "#"` in the guard, and the inner check
`ys[0] not in ("\n", "#")` for a line that is *all* spaces):

- **deeper** than `indent_stack[-1]`: push the new level, emit one
  `TokIndent`. Exactly one, however much deeper — Pyking has no notion
  of "indent by more than one level in a single step" the way column
  counting alone would allow, though `parse_block` never actually
  offers a chance to write one, since a block opens right after the
  line that increased the level.
- **shallower**: pop and emit one `TokDedent` per level stepped back
  through, in a `while` loop — this is the "closes several nested
  blocks at once" rule from PYKING.md, and it is why `TokDedent` can
  appear more than once in a row with nothing between them.
- **anything in between** that isn't already on the stack (e.g. the
  stack is `[0, 1, 3]` and the line indents to level 2): a
  `LexError`, "unindent does not match any outer indentation level" —
  there is no block this could be closing back into.

At end of input (`case []`), whatever is still on `indent_stack` above
`0` is popped and dedented, so a file that ends inside a block gets the
`TokDedent`s its last statement needs without a trailing blank line.

`TokIndent`/`TokDedent` carry an `Info` of zero length
(`fi(r, c, 0)`) at the position indentation was measured — they are a
structural marker, not text that was consumed, so there is nothing to
span.

## Reading a token

Every other `case` arm follows one shape: match the characters at the
front of `rest`, build a token with `fi(r, c, length)` for however many
characters it consumed, then advance `c` (or `r` and reset `c`, for
`"\n"`) and rebind `rest`. A few things are worth noticing about how
the arms are ordered and grouped:

- **Two-character operators are matched before their one-character
  prefix.** `["-", ">", *xs]` (the `->` of a return annotation and of
  a function type) comes before `["-", *xs]`; `["<", "=", *xs]`
  before `["<", *xs]`; and so on for `>=`, `==`, `:=`. Python's `match`
  tries arms in order, so this is the whole of "maximal munch" here —
  get the longer alternative in front of the shorter one it would
  otherwise shadow. There is no separate longest-match algorithm.
- **`string_until(pred, chars)`** is the one general-purpose scanner,
  used for runs of spaces, digits, and identifier characters alike: the
  longest prefix satisfying a predicate, returned with what's left. It
  does the work a hand-written `while i < len(s) and pred(s[i]): i += 1`
  loop would, once, so the three call sites (indentation, `TokInt`,
  `TokIdent`/keyword) don't each write their own.
- **An identifier is checked against `keywords` after being scanned,
  not while.** `y, ys = string_until(is_digit_letter, rest)` reads the
  whole word first (so `forever` scans as one identifier, not `for` +
  `ever`), and only then asks `k in keywords`. `is_letter` includes `_`
  but not digits, so an identifier may not *start* with one; `is_digit_letter`
  covers the rest of it. `keyword_token(name, info)` is a second `match`
  turning a matched keyword string into its specific token — kept
  separate from `lexing` itself so `is a keyword` and `which token is
  it` are two questions, not one `case` arm per keyword duplicated
  inline.
- **`keywords` is one flat list** (`"for"`, `"in"`, ..., `"Int"`,
  `"String"`, `"Bool"`, `"true"`, `"false"`) rather than split by what
  they're keywords *of* — control flow, type names, literals. Nothing
  in the lexer needs that distinction; `tools/emacs/pyking-mode.el`
  is the one place that does (for syntax-highlighting faces), and it
  is checked against this list explicitly rather than trusted to stay
  in step — see CLAUDE.md, "Changing the language."

## Comments and strings

A `#` comment consumes to (but not including) the next newline, and is
simply dropped — no `TokComment` exists, since nothing downstream ever
wants one back. A string literal is handed to `scan_string`, which
reads its own body up to the matching quote, decoding `\n`, `\t`, `\r`,
`\\`, `\'`, `\"` through the `_ESCAPES` table as it goes; an unknown
escape or an unterminated literal is a `LexError` positioned at the
backslash or at the point the input ran out, not at the string's
opening quote — the point is to put the reader's eye where the mistake
actually is. `scan_string` is a function of its own, not inlined into
`lexing`'s `match`, because it has to keep scanning *within* one
literal across a shape ordinary token matching doesn't have: a
two-character escape has to be consumed as a pair, and the closing
quote is matched last, which needs its own small loop rather than one
`case` arm.

## Errors

Every failure raises `LexError(info, message)`, an ordinary Python
exception carrying an `Info`. There is no error recovery here, or
anywhere in the front end before `--typecheck`'s replacement of
`analyze_program`: the first lexical mistake stops the lexer, `pyk.py`
formats it as one `Lexing error` line and reports it verbatim (see
`design/plan-eval-lsp.md` for where recoverable per-token diagnostics
are on the roadmap, and why they aren't built yet).

## What isn't tokenized

There is no token for whitespace between tokens on the same line (it is
consumed and dropped by `case [" ", *xs]`), and no token marking the
end of a line — only `TokIndent`/`TokDedent` say anything about
structure across lines. That absence is a real cost paid downstream:
`parser.py`'s `_check_own_line` (the rule that rejects `print h` as two
statements glued together) has to reconstruct "did this token start a
new line" from `Info` row numbers rather than reading it off a token,
because there is no such token to read. Adding one is the alternative;
CLAUDE.md notes it as a bigger change than the rule was worth. Keeping
the token stream free of anything the grammar itself doesn't need is
the same instinct that keeps comments out of it entirely.
