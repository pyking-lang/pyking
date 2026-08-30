# `repl.py`: design

How `src/repl.py` — `pyk repl` — turns a sequence of typed entries into
a running session, and how its terminal editor works. For where the
REPL sits in the pipeline, see [architecture.md](architecture.md); for
a one-page summary, see [source.md](source.md#replpy).

## The one rule everything else follows from

> **An entry is checked the way it is run.**

That sentence, from the module's own docstring, is worth sitting with
before reading any of the code, because almost every design choice in
this file exists to make it true. A REPL session is not "one Pyking
program, typed a bit at a time" — it behaves differently from a file in
one specific way, and the whole module is built around getting that
difference right rather than papering over it.

Consider what "one accumulated program" would mean: every entry so far
concatenated and re-checked as a single block, from the top, each time.
That's the naive approach, and it's wrong in a way that shows up
immediately. Inside one Pyking block, `def` has a special rule — every
`def` in the block is hoisted, visible throughout it, and (per
`analyses.py`'s `check_no_function_clash`) a name may be defined as a
function **at most once per block**. Redefining a name at the REPL
prompt — typing `def double(n): n * 2`, running it, then typing a
better `def double(n): n * 2 + 1` to replace it — is one of the most
ordinary things a REPL session does. Treated as "one accumulated
block," that's exactly the error `analyses.py` exists to catch: two
`def`s sharing a name in one block.

The fix is not to special-case redefinition. It's to notice that a REPL
session genuinely *isn't* one block: **each entry is checked as its own
group**, against what the entries before it left behind — the same
relationship one top-level block has to the next in an ordinary Pyking
file, not the relationship two statements inside one block have to each
other. Redefining `double` is then ordinary shadowing, exactly as
writing `x = 1` twice in sequence at the top level of a file is
shadowing, not a name clash. A function written in an earlier entry
keeps whatever it captured from that entry's own environment — a later
redefinition of a name it used doesn't reach backward and change it,
for the same reason a closure in `interpreter.py`'s `Env` chain never
sees a later rebinding (see that module's own page). And a function
written *now* is invisible to one written in an *earlier* entry, since
that earlier entry's hoisting only ever reached across its own group.

Two mutually recursive functions have to arrive in the **same** entry,
because hoisting only works within a group — which is exactly why a
half-finished entry (a `def` that calls a name not yet defined) is kept
around to be extended rather than thrown away as an error; see
"`undefined_name`/`undefined_message`" below.

## `Session`: two environments extended in step

`Session` carries the state the loop threads from one entry to the
next: `state` (`interpreter.State` — the machine's names to values),
`types` (the checker's names to types), `store` (what the deferred
half of the type checker has worked out — see `typesystem.py`'s own
page and `type_inference.md`), `kinds` (the mutability analysis's names
to binding kinds, so `:=` at the prompt is held to the same rule a file
is), and `sources` (each name's own defining text, for `:edit`). `types`/`store` and `state` are genuinely two
separate environments, extended by two separate modules
(`typesystem.declare_functions`/`check_stmt` for the first,
`interpreter.declare_entry`/`eval_in` for the second) — the REPL keeps
both in step by construction, rather than by deriving one from the
other, because they answer different questions (what type does this
have vs. what value does this have) that happen to be checked and run
over the same entries in the same order.

`seen` is easy to overlook and easy to get wrong: it's every statement
the session has ever been given, kept **only** so `symbolize` (in
`analyses.py`) can keep numbering forward from the highest symbol
already assigned, rather than restarting at 1 for every entry and
handing out a symbol that some earlier entry's statement already
holds. `interpreter.py`'s call-free-symbol table (`Runtime.simple`) is
keyed by symbol, so a symbol collision between two different entries
would silently let one entry's optimization data answer for another
entry's node. `submit` grows `seen` **before** checking whether the
entry's statements actually get to run, specifically because a symbol,
once handed out, must never be handed out again — even to a statement
that turns out to be refused.

## `submit`: check the whole entry first, run it one statement at a time

```python
def submit(session, stmts, report, source=""):
    ...
    checked = check_entry(entry, session.types, session.store)
    ...
    for stmt, supplied, types, store in checked:
        after = interpreter.eval_in(state, stmt)
        ...
```

The two-phase shape — check *everything* in the entry, and only once
that succeeds, run statements one at a time — matters for a reason
specific to a REPL: an entry can be several statements long (a `def`
followed by a call to it, typed together), and if checking happened
statement-by-statement interleaved with running, a type error in the
*second* statement would be reported only after the *first* one had
already run and possibly printed something. `check_entry` mirrors
`typesystem.py`'s own two-pass shape for a block — `declare_functions`
first (so the entry's own `def`s can call each other or forward-
reference within the entry, exactly as within an ordinary block).
That's what "checked the way it is run" cashes out to concretely: the
grouping the type checker uses (declare, then check) is the same
grouping the interpreter uses (`declare_entry`, then `eval_in` per
statement) — one entry, two passes each, kept in the same order.

A refusal at check time (`AnalysisError` or `typesystem.TypeError_`)
is caught and returned as `(session, refused)` rather than printed
inside `submit` — the caller decides what to do with it, which matters
because the REPL's main loop sometimes wants to do something other than
print an error: see the next section. A *runtime* error, by contrast,
is reported immediately (`report(error)`) and the loop moves on, since
by the time a statement is running, there's no better place to surface
the mistake than where it happened.

## `undefined_name`/`undefined_message`: a refusal that offers to keep going

An entry refused for naming something unbound is, more often than not,
one that isn't *finished* — the first half of two mutually recursive
functions, say, where the second hasn't been typed yet. Reporting that
as an ordinary error and discarding the entry would force retyping the
whole thing. Instead, `undefined_name` recognizes exactly this shape of
refusal (an `AnalysisError` whose message starts with `analyses.py`'s
own `"unbound name '"` wording — read out of that module rather than
duplicated, so the two can never say it differently), and — provided
the entry actually defines a function, and there's an interactive
reader to ask — the loop calls `reader.ask(undefined_message(name))`
and, on anything but "cancel," hands the same source text right back as
`pending`, to be re-opened in the editor rather than lost. `Escape`
still drops it; every other key means "let me keep writing." This is
the concrete mechanism behind PYKING.md's promise that mutual recursion
works at the REPL prompt the same way it works in a file — the *first*
half of it is never treated as a mistake, only as incomplete.

## The Buffer/Editor split: what's pure, and what has to be stateful

`Buffer(lines, row, col)` is a frozen value, and every operation on it
(`insert`, `newline`, `backspace`, `left`, `up`, ...) takes one and
returns a new one — nothing about "what the text currently says" is
ever mutable. That's a deliberate, testable boundary: the module
docstring on this section says it outright — "everything about *what
the text is* can be reasoned about (and tested) without a terminal
anywhere in sight." `Editor` is where everything that genuinely can't
be pure lives instead: the actual tty in raw mode, the history of past
entries, and how much of the screen the last redraw used. Splitting the
two apart means a change to, say, how Backspace behaves at the start of
an indentation level (`_indent_step`) is a change to one pure function
that a unit test can call directly with a string and a column number —
no terminal, no `termios`, no simulated keypresses required.

`Editor.read` runs the actual key loop: read a key, apply the matching
`Buffer` operation, redraw, repeat, until something decides the entry
is finished. What counts as "finished" is itself two different
questions the editor answers by delegating outward rather than
hard-coding: `is_complete` (passed in as `complete`, from this same
module — ultimately, "does the parser say this entry is a whole unit?")
decides whether **Enter** submits or opens a new line, and
`indent_for` (`next_indent`) decides how far that new line starts
indented. Neither is a guess about Pyking's grammar living inside the
editor — the editor asks the one thing that actually knows,
`parse_source`, via `complete`'s `try: parse(...) except
(LexError, ParseError)` — and `INCOMPLETE` is the specific list of
parser messages that mean "ran out of input" rather than "this is
wrong," which is what lets a half-typed `def f():` keep reading instead
of erroring on the spot.

Parsing whole is not the same as being finished, and since a block may
be written on its header's own line (see PYKING.md) that difference now
shows up on a *single* line: `if c: print(1)` parses, but `else:
print(2)` may still follow — on the next line, which is the only place
it may go. `continuable` is the second half of the question, and it is
asked of the parser too rather than of a trailing `:` — it parses the
line and looks at what the last statement *is*: an `if` with no `else`
yet, following an `else if` chain down to the innermost rung. Only a
line that both parses and cannot be continued submits on its own;
everything else waits for the blank line, exactly as a multi-line entry
always has. `def f(x): x * x` therefore runs on Enter — nothing can be
indented under it, and nothing continues a `def`.

## Recognizing Shift+Return, and why it needs three code paths

`readline`-style history is one line per `input()` call — which makes
recalling a *whole* multi-line function with Up impossible, since Up
would only ever bring back the function's last line. That's the reason
this module has its own editor at all rather than leaning on the
standard library's: `Editor.history` stores whole entries, and Up/Down
move within one entry first, then step through the history of entries
once they reach its edges.

Ending a multi-line entry still needs a key, though, and Pyking has no
"blank line" requirement baked into `Enter` the way that would be the
simplest option — a blank line already means something else (it's how
a block normally ends). `Shift+Return` is the intended "finish this
entry now" key, and terminals report it in one of (at least) three
different ways, none of them a plain, distinguishable byte:

- **CSI u** mode reports Return-with-a-modifier as a numbered key
  event, `\x1b[13;2u` — `13` is `_RETURN_KEY`, `2` is `_SHIFT`, decoded
  in `_named`'s `("u", [_RETURN_KEY, modifier, *_])` case.
- **xterm's `modifyOtherKeys`** reports the same event with the pieces
  in the other order, `\x1b[27;2;13~` — decoded by `_named`'s `("~",
  [27, modifier, _RETURN_KEY])` case, checked separately because the
  keycode comes *last* here instead of first.
- **Neither** — a terminal doing plain VT100 sends an unmodified `\r`
  for Shift+Return, indistinguishable from ordinary Return. There is no
  code path for this because there is nothing to decode; `HELP` says so
  explicitly ("where it does not arrive, a blank line still ends a
  block"), so the feature degrades to "just use a blank line" rather
  than silently doing nothing.

`_escape` is where an `\x1b` byte is triaged before any of that:
`_waiting()` polls with a short timeout (`_ESCAPE_DELAY`, 50ms) to tell
a lone Escape keypress (nothing follows) from the start of a longer
escape sequence (an arrow key, or one of the two Shift+Return
encodings above, whose remaining bytes arrive in the same burst) —
a human pressing Escape and an arrow key both start with the same
byte, and only *waiting slightly* distinguishes "nothing else is
coming" from "the rest is already in the buffer."

## Drawing: recomputed, not incremental

`_draw` redraws the entire entry on every keystroke — move the cursor
back to the top of what was drawn last time, clear from there, write
the whole thing out again, and place the cursor precisely. It counts
rows using the actual terminal width (`shutil.get_terminal_size`), not
one row per line of the buffer, because a single long line wraps onto
more than one terminal row, and undercounting that would leave the
cursor-repositioning math wrong the moment any line got long enough to
wrap. The one fragile corner — a line whose text ends *exactly* at the
right margin — is called out in a comment and handled by forcing a
wrap and erasing the character that forced it, because different
terminals disagree about where the cursor sits in that exact case, and
picking one behavior explicitly is more predictable than trusting each
terminal's own guess.

This whole approach (redraw everything, recompute positions from
scratch) is simpler than tracking incremental screen deltas, and it's
affordable specifically because a REPL entry is short — redrawing a few
lines on every keystroke is not a performance concern the way
redrawing a full-screen editor buffer would be.

## Meta-commands: one shape, two behaviors

Every entry in `META` — `:help`, `:ls`, `:type`, `:edit`, `:ast`,
`:tokens`, `:load`, `:reset` — has the signature `(session, argument,
report) -> session`, which is what lets `run_meta` call any of them
uniformly without knowing which one it has. Only `:edit` ever needs to
say more than "here's the session to carry on with" — it wants to put
text back in front of the user — so rather than changing every
command's signature to accommodate that one case, `run_meta` wraps
whatever comes back in an `Outcome(session, pending="")`, and
`meta_edit` is the one function that constructs an `Outcome` with a
real `pending` value directly. A command that "only reports" (`:ls`,
`:type`) and a command that "changes the session" (`:load`, `:reset`)
end up looking identical to the loop — both just return a session — and
the asymmetry is confined to the one command that actually needs it.
