"""The REPL: `pyk repl`.

A session is a *program being written one entry at a time*, and that is
exactly how this is built. Each entry is checked against what the entries
before it left behind, and then run there -- in two environments extended
in step, the checker's and the machine's.

    $ pyk repl
    Pyking REPL.  :help for commands, :quit to leave.
    > x = 21
    > def double(n:Int) -> Int:
    .     n * 2
    .
    > double(x)
    42 : Int
    > :ls
    x      = 21 : Int
    double = <function> : (Int) -> Int

**An entry is checked the way it is run**, and that one rule settles
everything a prompt does differently from a file. An entry is a group:
its `def`s are declared together, so two of them may call each other
(`interpreter.declare_entry` does the same with the values), and
everything in it is checked and run against the environments already
there. A later entry is a later group -- so redefining a name is
ordinary Pyking shadowing rather than the "one `def` per name per block"
error it would be inside one block, a function written earlier keeps
whatever it captured, and a function written now is invisible to one
written before it, because it was not there when that one was written.
`:reset` starts again from nothing.

Nothing here reimplements anything. Reading is `lexer.lexing` and
`parser.parse`; checking is `typesystem.declare_functions` and
`check_stmt`, whose environment the session keeps, so `:ls`, `:type`
and the echoed value of an expression all name types the checker worked
out rather than types inferred a second time; running is
`interpreter.eval_in`; showing a value is `interpreter.display_value`.
Even the error messages are the driver's: `start` takes `src/pyk.py`'s
own `format_error`, so a mistake made at the prompt is reported in the
words it would have been reported in from a file.

Three mechanics are worth spelling out.

**Deciding an entry is finished** uses the parser's own answer rather
than guessing from a trailing `:`. A single line that parses is
submitted as soon as it is typed; anything else -- a block header, an
unclosed bracket -- keeps reading, with the prompt as `.`, until a blank
line ends it. That is Python's REPL rule, and it is the only one that
lets a block have more than one statement in it.

**A block indents itself.** The next line is offered already indented to
where it belongs: one level in after a line ending in `:`, and the same
level otherwise, however deeply the blocks nest. It is offered, not
imposed -- backspace takes it away, which is how a branch dedents to its
`else`.

**A value is shown when there is one**, as `value : Type`. A statement's
value is what PYKING.md's "Tail position" calls the value it supplies --
the machine hands back the value and the checker the type, so the two
halves of the line come from the two places that know: an expression
shows, a binding or a `def` supplies unit and shows nothing.

## The line editor

`Editor` is a small multi-line editor over a terminal in raw mode, used
when the REPL is talking to a terminal at all; piped input takes the
plain `input()` path below it, which is what the tests and
`pyk repl < file` use.

It exists because `readline` cannot do the one thing a REPL with blocks
in it needs: recall a *whole* entry. `readline` history is one line per
`input()` call, so pressing Up after defining a five-line function
offers its last line, which is not a program. Here the buffer is a list
of lines, Up and Down walk within it and then into history, and what
history holds is entries -- so a function comes back whole and can be
edited anywhere in it.

The editing state is a frozen `Buffer(lines, row, col)` with pure
operations over it; the class holds only what is unavoidably stateful --
the terminal, the history, and how much of the screen the last redraw
used.
"""

import os
import select
import shutil
import sys
from dataclasses import dataclass, field, replace

from analyses import BUILTINS, bound_names, symbolize, AnalysisError
from lexer import lexing, pprint_info, pprint_token, LexError
from parser import parse, ParseError
from syntax import pprint_program, pprint_type, SExprStmt, SFunctionDef
import interpreter
import typesystem

try:                                    # POSIX only; without it there is
    import termios                      # no raw mode, and the REPL falls
    import tty                          # back on plain `input()`.
except ImportError:                     # pragma: no cover -- platform
    termios = None
    tty = None


PROMPT = "> "
CONTINUATION = ". "

BANNER = "Pyking REPL.  :help for commands, :quit to leave."

# One level of indentation, in the only width Pyking accepts (see
# PYKING.md, "Indentation-based blocks").
INDENT = "    "

# What the parser says when it stopped because the input ran out rather
# than because it was wrong. A line that ends this way is not an error
# yet: it is an entry that is still being typed. The parser is the only
# thing that knows this, which is why the REPL asks it rather than
# looking for a trailing ':'.
INCOMPLETE = ("unexpected end of input", "expected an indented block")


@dataclass(frozen=True)
class Session:
    """A REPL session: two environments, and a record of what has been
    seen.

    `state` is the machine's -- names to values. `types` is the
    checker's -- names to types, the same table `typesystem.py` threads
    through a program. They are extended in step, one entry at a time,
    which is what lets the prompt answer both "what is `x`" and "what
    type is `x`" without inferring anything twice.

    `sources` is what each name was *written* as -- the text of the
    statement that bound it, sliced out of the entry it arrived in by its
    own source span. That is what `:edit` brings back, and it is the
    text, not a printed AST: a definition comes back with its comments,
    its spacing and its own choices intact, which is the difference
    between editing what you wrote and editing a rendering of it.

    `seen` is every statement the session has been given, kept for one
    narrow purpose: `symbolize` numbers a tree from the highest symbol
    already in it, so handing it the accumulated statements is what stops
    a later entry from reusing an earlier entry's symbols -- which the
    machine's call-free table is keyed by.

    **An entry is checked the way it is run.** Each one is its own group:
    its `def`s are declared together, so they may call each other, and it
    is checked against the environment the entries before it left behind
    -- exactly what `interpreter.declare_entry` and `eval_in` do with the
    values. So redefining a name is what it is anywhere else in Pyking, a
    binding that shadows an earlier one; a function written earlier keeps
    whatever it captured; and a function written now is invisible to one
    written before it, because it was not there when that one was
    written."""
    seen: tuple = ()
    state: interpreter.State = None
    types: dict = field(default_factory=typesystem.builtin_env)
    sources: dict = field(default_factory=dict)


def new_session():
    """A session with nothing in it: the builtins in scope, in both
    environments, and nothing seen yet."""
    return Session(state=interpreter.initial_state([], interpreter.ConsoleHost()))


# --- reading ---------------------------------------------------------


def complete(source):
    """Whether `source` is a whole entry, as far as the parser is
    concerned. An entry that failed for any reason other than running out
    of input is complete: it is wrong, and waiting for more would only
    delay saying so."""
    try:
        parse(lexing("<repl>", list(source + "\n")))
        return True
    except (LexError, ParseError) as e:
        return not any(e.message.startswith(reason) for reason in INCOMPLETE)


def next_indent(source):
    """The indentation the line after `source` belongs at: one level in
    from the last line if it opened a block, and level with it otherwise.

    A block is opened by a line ending in `:` -- `def`, `if`, `else`,
    `while`, `for`, `case`, and a bound `x = if c:` alike -- so one rule
    covers all of them, at whatever depth they are nested. It is an
    offer, not a decision: what the user does with the indentation
    afterwards is what actually decides the block."""
    lines = [line for line in source.splitlines() if line.strip()]
    if not lines:
        return ""
    last = lines[-1]
    indent = last[: len(last) - len(last.lstrip())]
    return indent + INDENT if last.rstrip().endswith(":") else indent


def parse_source(source, name="<repl>"):
    """`source` as a list of statements. Raises `LexError`/`ParseError`
    like the driver's own front end does."""
    return parse(lexing(name, list(source + "\n")))


def read_entry(read_line):
    """One entry, read a line at a time from `read_line` -- the fallback
    for input that is not a terminal (a pipe, a transcript), where there
    is nothing to edit and no cursor to move.

    Returns the source text, or `None` at end of input. Whether it
    *parses* is decided again by the caller; this only decides when to
    stop reading, and it uses the parser to do it."""
    line = read_line(PROMPT)
    if line is None:
        return None
    lines = [line]
    while not complete("\n".join(lines)):
        more = read_line(CONTINUATION)
        if more is None or not more.strip():
            break
        lines.append(more)
    return "\n".join(lines)


# --- the editing buffer ----------------------------------------------
#
# A frozen value with pure operations over it, so that everything about
# *what the text is* can be reasoned about (and tested) without a
# terminal anywhere in sight. `Editor` below owns the parts that cannot
# be pure: the tty, the history, and the screen.


@dataclass(frozen=True)
class Buffer:
    """The entry being typed: its lines, and where the cursor is in
    them."""
    lines: tuple = ("",)
    row: int = 0
    col: int = 0

    @property
    def text(self):
        return "\n".join(self.lines)

    @property
    def line(self):
        return self.lines[self.row]


def buffer_of(text, at_end=True):
    """A buffer holding `text`, with the cursor at the end of it (where a
    recalled history entry wants it) or at the very start."""
    lines = tuple(text.split("\n")) or ("",)
    if not at_end:
        return Buffer(lines, 0, 0)
    return Buffer(lines, len(lines) - 1, len(lines[-1]))


def _indent_step(line, col):
    """How much one backspace at `col` removes: back to the previous
    indentation stop when there is nothing but spaces to the left, and
    one character everywhere else."""
    if line[:col].strip():
        return 1
    return col - (col - 1) // len(INDENT) * len(INDENT)


def _with_line(buf, row, text, col):
    lines = buf.lines[:row] + (text,) + buf.lines[row + 1:]
    return Buffer(lines, row, col)


def insert(buf, text):
    line = buf.line
    return _with_line(
        buf, buf.row, line[: buf.col] + text + line[buf.col:], buf.col + len(text)
    )


def newline(buf, indent):
    """Split the line at the cursor, carrying `indent` onto the new one."""
    line = buf.line
    head, tail = line[: buf.col], line[buf.col:]
    lines = buf.lines[: buf.row] + (head, indent + tail) + buf.lines[buf.row + 1:]
    return Buffer(lines, buf.row + 1, len(indent))


def backspace(buf):
    """Delete backwards -- a whole level of indentation at a time when
    that is what is being deleted.

    Inside the indentation, where everything to the left of the cursor is
    spaces, one press goes back to the previous multiple of four rather
    than removing one space. Indentation *is* the block structure in
    Pyking, so a dedent is one thing the user meant to do, not four; and
    since it moves to a stop rather than by a fixed four, a line that has
    drifted off the grid is put back on it."""
    if buf.col > 0:
        line = buf.line
        width = _indent_step(line, buf.col)
        return _with_line(
            buf, buf.row, line[: buf.col - width] + line[buf.col:], buf.col - width
        )
    if buf.row == 0:
        return buf
    # At the start of a line: join it onto the end of the one above.
    above = buf.lines[buf.row - 1]
    lines = (
        buf.lines[: buf.row - 1] + (above + buf.line,) + buf.lines[buf.row + 1:]
    )
    return Buffer(lines, buf.row - 1, len(above))


def delete(buf):
    line = buf.line
    if buf.col < len(line):
        return _with_line(buf, buf.row, line[: buf.col] + line[buf.col + 1:], buf.col)
    if buf.row == len(buf.lines) - 1:
        return buf
    joined = line + buf.lines[buf.row + 1]
    lines = buf.lines[: buf.row] + (joined,) + buf.lines[buf.row + 2:]
    return Buffer(lines, buf.row, buf.col)


def kill_to_end(buf):
    return _with_line(buf, buf.row, buf.line[: buf.col], buf.col)


def left(buf):
    if buf.col > 0:
        return replace(buf, col=buf.col - 1)
    if buf.row == 0:
        return buf
    return Buffer(buf.lines, buf.row - 1, len(buf.lines[buf.row - 1]))


def right(buf):
    if buf.col < len(buf.line):
        return replace(buf, col=buf.col + 1)
    if buf.row == len(buf.lines) - 1:
        return buf
    return Buffer(buf.lines, buf.row + 1, 0)


def up(buf):
    """One line up, keeping the column where it fits. `None` when there
    is no line above -- which is where the editor reaches for history."""
    if buf.row == 0:
        return None
    return Buffer(buf.lines, buf.row - 1, min(buf.col, len(buf.lines[buf.row - 1])))


def down(buf):
    if buf.row == len(buf.lines) - 1:
        return None
    return Buffer(buf.lines, buf.row + 1, min(buf.col, len(buf.lines[buf.row + 1])))


def home(buf):
    return replace(buf, col=0)


def end(buf):
    return replace(buf, col=len(buf.line))


# --- the terminal editor ---------------------------------------------

# The keys the editor understands, as names rather than escape
# sequences, so that `_dispatch` reads as editing rather than as
# terminal trivia.
_ARROWS = {"A": "up", "B": "down", "C": "right", "D": "left",
           "H": "home", "F": "end"}
_TILDES = {"1": "home", "3": "delete", "4": "end", "7": "home", "8": "end"}
_CONTROL = {
    "\r": "enter", "\n": "enter",
    "\x7f": "backspace", "\x08": "backspace",
    "\x01": "home", "\x05": "end", "\x0b": "kill",
    "\x03": "interrupt", "\x04": "eof", "\x0c": "clear",
}

# How long to wait for the rest of an escape sequence before concluding
# that the Escape key was pressed on its own. An arrow key sends its
# bytes in one burst, so anything still absent after this came from a
# human finger.
_ESCAPE_DELAY = 0.05


class Editor:
    """A multi-line line editor over a terminal in raw mode.

    `read()` returns one entry: the whole text, however many lines it
    took. Up and Down move within the entry and, at its edges, step
    through the history of *entries* -- which is the thing `readline`
    cannot do and the reason this exists.

    Everything it needs to know about the language it is given:
    `is_complete(text)` decides when Enter submits rather than opening a
    new line, and `indent_for(text)` says how far in that new line
    starts."""

    interactive = True

    def __init__(self, is_complete, indent_for, prompt=PROMPT,
                 continuation=CONTINUATION, stream=None):
        self.is_complete = is_complete
        self.indent_for = indent_for
        self.prompt = prompt
        self.continuation = continuation
        self.stream = stream or sys.stdout
        self.history = []
        self._rows_up = 0        # rows between the top of the drawing and the cursor
        self._rows_total = 1

    # --- reading ---

    def read(self, initial=""):
        """One entry, or `None` at end of input. An entry abandoned with
        Escape or Ctrl-C comes back as `''`, which the caller ignores the
        way it ignores a blank line.

        `initial` is text to start from rather than an empty line: an
        entry handed back to be finished (see `undefined_message`), or
        the definition `:edit` brought up. It is an ordinary buffer from
        the first keystroke on -- there is nothing special about text
        that was not typed here."""
        buf = buffer_of(initial) if initial else Buffer()
        live, index = None, len(self.history)
        with self._raw():
            self._rows_up, self._rows_total = 0, 1
            self._draw(buf)
            while True:
                kind, key = self._key()
                if kind == "text":
                    buf = insert(buf, key)
                    self._draw(buf)
                    continue

                match key:
                    case "enter" if self._submits(buf):
                        return self._finish(buf, self._submitted(buf))
                    case "enter":
                        buf = newline(buf, self.indent_for(self._before(buf)))
                    case "escape" | "interrupt":
                        return self._finish(buf, "")
                    case "eof":
                        if not buf.text:
                            return self._finish(buf, None)
                    case "backspace":
                        buf = backspace(buf)
                    case "delete":
                        buf = delete(buf)
                    case "kill":
                        buf = kill_to_end(buf)
                    case "left":
                        buf = left(buf)
                    case "right":
                        buf = right(buf)
                    case "home":
                        buf = home(buf)
                    case "end":
                        buf = end(buf)
                    case "clear":
                        self._write("\x1b[H\x1b[J")
                        self._rows_up = 0
                    case "up":
                        moved = up(buf)
                        if moved is not None:
                            buf = moved
                        elif index > 0:
                            live = buf.text if index == len(self.history) else live
                            index -= 1
                            buf = buffer_of(self.history[index])
                    case "down":
                        moved = down(buf)
                        if moved is not None:
                            buf = moved
                        elif index < len(self.history):
                            index += 1
                            buf = buffer_of(
                                self.history[index]
                                if index < len(self.history)
                                else (live or "")
                            )
                self._draw(buf)

    def ask(self, message):
        """Put a question to the user and wait for one key: Escape means
        no, anything else means yes.

        One key rather than a line, because the answer decides what
        happens to the entry that is already half-written -- asking for a
        line and an Enter would be asking them to type something that is
        not Pyking into a Pyking prompt."""
        self._write(message.replace("\n", "\r\n") + "\r\n")
        with self._raw():
            _, key = self._key()
        return "cancel" if key in ("escape", "interrupt", "eof") else "edit"

    def _submits(self, buf):
        """Whether Enter ends the entry rather than opening a line.

        A single line that parses is done -- that is most entries. A
        block is not, however complete it looks, because a block may have
        more statements in it and only a blank line can say that it does
        not; that is Python's REPL rule, and the reason `def f():` on one
        line and its body on the next do not submit themselves."""
        if len(buf.lines) == 1:
            return self.is_complete(buf.text)
        return not buf.line.strip()

    def _submitted(self, buf):
        """The entry's text, with the blank line that ended a block
        dropped."""
        lines = buf.lines
        while len(lines) > 1 and not lines[-1].strip():
            lines = lines[:-1]
        return "\n".join(lines)

    def _before(self, buf):
        """What has been typed above the cursor -- what the indentation
        of the next line is decided from."""
        return "\n".join(buf.lines[: buf.row + 1])

    def _finish(self, buf, result):
        """Leave the entry on the screen, put the cursor below it, and
        remember it."""
        self._to_bottom()
        self._write("\r\n")
        if result and result.strip() and (not self.history or self.history[-1] != result):
            self.history.append(result)
        return result

    # --- the terminal ---

    class _Raw:
        """Raw mode for the duration of one `read`, restored afterwards
        so that everything the program itself prints is written to an
        ordinary terminal."""

        def __init__(self, fd):
            self.fd = fd
            self.saved = None

        def __enter__(self):
            if termios is not None and self.fd is not None:
                self.saved = termios.tcgetattr(self.fd)
                tty.setraw(self.fd)
            return self

        def __exit__(self, *_):
            if self.saved is not None:
                termios.tcsetattr(self.fd, termios.TCSADRAIN, self.saved)
            return False

    def _raw(self):
        return Editor._Raw(sys.stdin.fileno())

    def _write(self, text):
        self.stream.write(text)
        self.stream.flush()

    def _key(self):
        """The next key, as `("text", characters)` or `("key", name)`.

        Escape is the one ambiguous byte on a terminal: it begins every
        arrow key and is also a key of its own. Waiting `_ESCAPE_DELAY`
        for what follows is how the two are told apart."""
        char = self._char()
        if char is None:
            return "key", "eof"
        if char == "\x1b":
            return "key", self._escape()
        if char in _CONTROL:
            return "key", _CONTROL[char]
        if char < " ":
            return "key", "ignored"
        return "text", char

    def _escape(self):
        if not self._waiting():
            return "escape"
        if self._char() != "[":
            return "ignored"
        char = self._char()
        if char in _ARROWS:
            return _ARROWS[char]
        if char is not None and char.isdigit():
            # A `\x1b[<n>~` key: Delete, Home and End on some terminals.
            rest = self._char()
            return _TILDES.get(char, "ignored") if rest == "~" else "ignored"
        return "ignored"

    def _waiting(self):
        return bool(select.select([sys.stdin.fileno()], [], [], _ESCAPE_DELAY)[0])

    def _char(self):
        """One character, decoding a UTF-8 sequence if that is what
        arrives -- the terminal hands over bytes, and a Pyking string may
        hold anything."""
        first = os.read(sys.stdin.fileno(), 1)
        if not first:
            return None
        length = (
            1 if first[0] < 0x80 else
            2 if first[0] >> 5 == 0b110 else
            3 if first[0] >> 4 == 0b1110 else
            4
        )
        data = first + b"".join(
            os.read(sys.stdin.fileno(), 1) for _ in range(length - 1)
        )
        return data.decode("utf-8", errors="replace")

    # --- drawing ---
    #
    # One redraw per keystroke: go back to the top of what was drawn
    # last time, clear it, write the entry out again, and put the cursor
    # where the buffer says it is. Rows are counted with the terminal's
    # width in mind, so a line long enough to wrap is still followed
    # correctly.

    def _columns(self):
        return max(shutil.get_terminal_size().columns, 1)

    def _prompt_for(self, row):
        return self.prompt if row == 0 else self.continuation

    def _draw(self, buf):
        columns = self._columns()
        out = [f"\x1b[{self._rows_up}A" if self._rows_up else "", "\r\x1b[J"]

        row = 0
        cursor = (0, 0)
        for index, line in enumerate(buf.lines):
            text = self._prompt_for(index) + line
            out.append(("\r\n" if index else "") + text)
            if index == buf.row:
                at = len(self._prompt_for(index)) + buf.col
                cursor = (row + at // columns, at % columns)
            row += len(text) // columns + 1

        # A line that ends exactly at the right margin leaves the cursor
        # in a position terminals disagree about, so it is forced over to
        # the next row and the space that forced it is erased again.
        last = len(self._prompt_for(len(buf.lines) - 1)) + len(buf.lines[-1])
        if last and last % columns == 0:
            out.append(" \r\x1b[K")

        # Every line contributes `len // columns + 1` rows, so after the
        # last one the cursor is on the bottom row of the drawing --
        # which the forced wrap above is what makes reliably true.
        self._rows_total = row
        self._rows_up = cursor[0]
        out.append(self._move(row - 1, cursor))
        self._write("".join(out))

    def _move(self, from_row, to):
        """The escapes that take the cursor from the end of what was just
        drawn to where the buffer says it belongs."""
        to_row, to_column = to
        moves = ""
        if from_row > to_row:
            moves += f"\x1b[{from_row - to_row}A"
        elif from_row < to_row:
            moves += f"\x1b[{to_row - from_row}B"
        return moves + "\r" + (f"\x1b[{to_column}C" if to_column else "")

    def _to_bottom(self):
        below = self._rows_total - 1 - self._rows_up
        if below > 0:
            self._write(f"\x1b[{below}B")
        self._write("\r")


class PipeReader:
    """Reading entries from something that is not a terminal: a pipe, a
    transcript, a file fed in on stdin.

    It has the same two methods as the editor and can do neither of the
    interesting things with them -- there is no cursor to put text under
    and no key to press -- so `initial` is ignored and a question answers
    itself. Keeping the shape identical is what lets `start` be written
    once."""

    interactive = False

    def read(self, initial=""):
        def read_line(prompt):
            try:
                return input(prompt)
            except EOFError:
                return None

        return read_entry(read_line)

    def ask(self, _message):
        return "cancel"


def make_reader():
    """How this session reads entries: the editor when there is a
    terminal to edit on, and `PipeReader` otherwise -- a pipe has no
    cursor to move and no history to walk, and a transcript test wants
    exactly the lines it was given."""
    if termios is None or not sys.stdin.isatty():
        return PipeReader()
    return Editor(complete, next_indent)


# --- accepting an entry ----------------------------------------------


def submit(session, stmts, report, source=""):
    """Check `stmts` as one entry, run whichever of them the checker
    accepted, and return `(session, refused)` -- the session to carry on
    with, and the error that stopped the entry being accepted at all, if
    one did.

    Checking happens for all of them and before any of them runs, which
    is the only order that can work: the entry's `def`s are declared
    together, so the checker has to see the whole entry, and a statement
    that would not check must not be allowed to bind anything first.

    A *refusal* comes back rather than being reported here, because the
    caller may have something better to do with it than print it -- an
    entry refused for naming something not defined yet is one the user is
    probably still writing (see `undefined_message`). A *runtime* error
    is different: half the entry has already happened, so it is reported
    here and the session keeps what ran.

    `source` is the text the statements were parsed from, and the only
    use it has is `:edit`: each accepted statement records the slice of
    it that defined the name."""
    seen = symbolize(list(session.seen) + list(stmts))
    entry = seen[len(session.seen):]
    try:
        checked = check_entry(entry, session.types)
    except (AnalysisError, typesystem.TypeError_) as e:
        return session, e

    # `seen` grows whether or not every statement runs: a symbol handed
    # out once must not be handed out again.
    session = replace(session, seen=tuple(seen))
    state = interpreter.declare_entry(session.state, entry)
    for stmt, supplied, types in checked:
        after = interpreter.eval_in(state, stmt)
        error = interpreter.failure(after)
        if error is not None:
            report(error)
            return replace(session, state=state), None
        state = after
        session = replace(
            session,
            state=state,
            types=types,
            sources={**session.sources, **defined_sources(stmt, source)},
        )
        show(interpreter.result(after), supplied)
    return session, None


def accept(session, stmts, report, source=""):
    """`submit`, with a refusal simply reported -- for callers with
    nothing better to do with one than say so."""
    session, refused = submit(session, stmts, report, source)
    if refused is not None:
        report(refused)
    return session


def defined_sources(stmt, source):
    """What this statement defined, as name -> the text that defined it.

    The text is sliced out of `source` by the statement's own span, whole
    lines, so a `def` comes back exactly as it was written. With no
    source to slice -- a caller that had only an AST -- the statement is
    printed instead, which is still valid Pyking and still editable."""
    names = defined_names(stmt)
    if not names:
        return {}
    text = statement_source(source, stmt) if source else pprint_program([stmt])
    return {name: text for name in names}


def defined_names(stmt):
    """The names a top-level statement binds. `analyses.bound_names`
    answers it for every binding form; a `def`'s own name is the one it
    leaves out, since there it is `block_functions`' business."""
    match stmt:
        case SFunctionDef(_, name, _, _, _, _, _):
            return [name]
    return [name for name, _ in bound_names(stmt)]


def statement_source(source, stmt):
    """The lines of `source` a statement covers. Whole lines, rather than
    the exact span: what is wanted back is something to edit and
    re-enter, and that is a statement with its indentation on it."""
    lines = source.splitlines()
    return "\n".join(lines[stmt.info.row1 - 1: stmt.info.row2])


def check_entry(entry, types):
    """The entry checked as one group: for each statement, what it
    supplies and the type environment it leaves behind.

    `typesystem.py`'s own pieces do the work -- `declare_functions` for
    the group, then `check_stmt` for each statement in turn -- which is
    that module's `check_stmts` with the intermediate environments kept
    rather than discarded. Keeping them is what lets a runtime error
    part-way through an entry leave the session's two environments in
    step."""
    types = typesystem.declare_functions(entry, types)
    tmap = {}
    checked = []
    for stmt in entry:
        supplied, types = typesystem.check_stmt(stmt, types, tmap, None)
        checked.append((stmt, supplied, types))
    return checked


def show(value, type_):
    """Print a statement's value, if it supplied one, as `value : Type`.

    Unit is what a binding, a `def` and a `print` supply, and a prompt
    that echoed `() : ()` after every one of them would say nothing worth
    reading."""
    if value is None or isinstance(value, interpreter.VUnit):
        return
    print(value_text(value) + type_suffix(type_))


def value_text(value):
    """A value as the prompt shows it: `display_value`'s spelling, so a
    string is quoted and cannot be mistaken for a name, except that a
    function is shown as `<function>` -- what it *is* comes from the type
    that follows, and repeating the name there would only be noise."""
    match value:
        case interpreter.VClosure() | interpreter.VBuiltin():
            return "<function>"
    return interpreter.display_value(value)


def type_suffix(type_):
    """` : Type`, or nothing where the checker recorded no type."""
    return f" : {pprint_type(type_)}" if type_ is not None else ""


def binding_types(session):
    """name -> `Type` for what the session has bound, read straight out
    of the checker's environment rather than guessed from the values.

    A name may be in scope with no type -- `None`, which is what a `def`
    missing annotations gets -- and the builtins are there as operations
    rather than values; both come back as "no type to show"."""
    return {
        name: type_
        for name, type_ in session.types.items()
        if not isinstance(type_, typesystem.Builtin)
    }


# --- meta-commands ---------------------------------------------------
#
# Each takes the session and the argument text, and returns the session
# to carry on with -- so a command that changes the session (`:load`,
# `:reset`) and one that only reports (`:type`, `:ls`) have the same
# shape, and the loop needs to know nothing about which is which.


def meta_help(session, _argument, _report):
    print(HELP)
    return session


def meta_ls(session, _argument, _report):
    """What the session has bound, as `name = value : Type`. The builtins
    are in scope too and are left out: they are in every session, so
    listing them would only bury what this one did."""
    bindings = interpreter.bindings_in_scope(session.state.env)
    types = binding_types(session)
    # In the order the session bound them: the checker's environment is
    # extended binding by binding, while the machine's is a chain walked
    # innermost-first, and a listing reads better in the session's own
    # order.
    names = [name for name in types if name in bindings]
    names += [n for n in bindings if n not in types and n not in BUILTINS]
    if not names:
        print("no bindings yet")
        return session
    width = max(len(name) for name in names)
    for name in names:
        value = value_text(bindings[name]) + type_suffix(types.get(name))
        print(f"{name.ljust(width)} = {value}")
    return session


def meta_type(session, argument, report):
    """The type of an expression, from the checker itself.

    Checked in the session's own type environment, so it can name
    whatever the session bound -- and gives the answer a file would get,
    since it is the same function run over the same kind of table."""
    if not argument:
        print("usage: :type <expression>")
        return session
    try:
        stmts = parse_source(argument)
    except (LexError, ParseError) as e:
        report(e)
        return session
    if len(stmts) != 1 or not isinstance(stmts[0], SExprStmt):
        print(":type takes one expression")
        return session
    try:
        print(pprint_type(typesystem.check_expr(stmts[0].expr, session.types, {})))
    except (AnalysisError, typesystem.TypeError_) as e:
        report(e)
    return session


def meta_ast(session, argument, report):
    """The parsed form of a statement, printed by the same
    pretty-printer `--ast` uses."""
    if not argument:
        print("usage: :ast <statement>")
        return session
    try:
        print(pprint_program(parse_source(argument)))
    except (LexError, ParseError) as e:
        report(e)
    return session


def meta_tokens(session, argument, report):
    """The token stream for a line, as `--tokens` prints it."""
    try:
        for token in lexing("<repl>", list(argument + "\n")):
            print(f"{pprint_info(token.info)} {pprint_token(token)}")
    except LexError as e:
        report(e)
    return session


@dataclass(frozen=True)
class Outcome:
    """What a meta-command leaves behind: the session to carry on with,
    and -- for `:edit`, the only one that has anything to say about it --
    text to put back in front of the user.

    Most commands have nothing to add and return a bare session;
    `run_meta` wraps one of those, so a command only mentions `Outcome`
    when it means something by it."""
    session: Session
    pending: str = ""


def meta_load(session, argument, report):
    """Read a file and submit its statements as one entry. The file joins
    the session's program, so what it defines is usable afterwards --
    which is the point."""
    if not argument:
        print("usage: :load <file>")
        return session
    try:
        with open(argument) as f:
            source = f.read()
    except OSError as e:
        print(f"cannot read '{argument}': {e.strerror}")
        return session
    try:
        stmts = parse_source(source, argument)
    except (LexError, ParseError) as e:
        report(e)
        return session
    return accept(session, stmts, report, source)


def meta_edit(session, argument, _report):
    """Bring a definition back to be edited: `:edit foo` puts the text
    that defined `foo` into the prompt, exactly as it was written.

    Editing it and pressing Enter defines it again -- which is an
    ordinary entry, so the new definition shadows the old one and
    everything already built from the old one keeps it. That is how a
    function grows in a session without being retyped."""
    if not argument:
        print("usage: :edit <name>")
        return session
    text = session.sources.get(argument)
    if text is None:
        print(f"nothing named '{argument}' was defined in this session")
        return session
    return Outcome(session, pending=text)


def meta_reset(_session, _argument, _report):
    """Start over: a new block, with nothing bound and nothing checked."""
    print("session reset")
    return new_session()


META = {
    ":help": meta_help,
    ":ls": meta_ls,
    ":type": meta_type,
    ":edit": meta_edit,
    ":ast": meta_ast,
    ":tokens": meta_tokens,
    ":load": meta_load,
    ":reset": meta_reset,
}

QUIT = (":quit", ":q")

HELP = """Commands:
  :help            this list
  :quit, :q        leave (or type Ctrl-D)
  :ls              what this session has bound: name = value : Type
  :type <expr>     the type the checker gives <expr> here
  :edit <name>     bring back what defined <name>, to edit and re-enter
  :ast <stmt>      the parsed form of <stmt>
  :tokens <line>   the token stream for <line>
  :load <file>     read a file into the session
  :reset           forget everything and start again

Anything else is a Pyking statement. A block keeps reading -- the prompt
becomes '.', and each line starts indented where it belongs -- until a
blank line ends it.

Editing: the arrow keys move through the whole entry, up and down step
through earlier entries once they leave it, backspace over indentation
removes a whole level, and Escape abandons what is being typed."""


def run_meta(session, line, report):
    """Run a meta-command, as an `Outcome`. An unknown one says so rather
    than being parsed as Pyking: a leading ':' is never valid Pyking, so
    a typo here would otherwise be reported as a syntax error, which
    explains nothing."""
    word, _, argument = line.partition(" ")
    command = META.get(word)
    if command is None:
        print(f"unknown command '{word}'; :help lists them")
        return Outcome(session)
    result = command(session, argument.strip(), report)
    return result if isinstance(result, Outcome) else Outcome(result)


# --- the loop --------------------------------------------------------


# What the front end says when a name resolves to nothing. Read here
# rather than re-derived: the wording is `analyses.py`'s, in one place,
# and this is the one caller that wants the *name* out of it rather than
# the sentence.
UNBOUND = "unbound name '"


def undefined_name(error):
    """The name an "unbound name" error is about, or `None` for any
    other error."""
    if isinstance(error, AnalysisError) and error.message.startswith(UNBOUND):
        return error.message[len(UNBOUND):].rstrip("'")
    return None


def undefined_message(name):
    """What to say when a `def` names something that does not exist yet.

    Two functions that call each other have to arrive together, because
    an entry is a group and only the names in it are declared before it
    is checked (see `Session`). That is a rule about *entries*, not a
    mistake in the program, so the entry is not thrown away: the choice
    of what to do with it belongs to the person who typed it."""
    return (
        f"Identifier '{name}' is not yet defined. Press <esc> to cancel or "
        f"<space> to continue editing."
    )


def defines_function(stmts):
    return any(isinstance(stmt, SFunctionDef) for stmt in stmts)


def start(format_error, read=None, session=None):
    """Run the REPL until end of input or `:quit`, and return an exit
    status.

    `format_error` is the driver's own (see `src/pyk.py`), so that every
    error the session can produce -- lexical, syntactic, name, type,
    runtime -- is reported here in exactly the words the compiler reports
    it in. `read` and `session` are for a caller that drives the REPL
    from something other than a terminal: a transcript test, or a front
    end that has its own idea of where entries come from.

    `pending` is the one piece of state the loop carries: text that goes
    back in front of the user instead of an empty prompt -- an entry
    being finished, or a definition `:edit` brought up."""
    reader = read or make_reader()
    session = session or new_session()
    pending = ""

    def report(error):
        print(format_error(error), file=sys.stderr)

    print(BANNER)
    while True:
        try:
            source = reader.read(pending)
        except KeyboardInterrupt:
            # Abandons the entry being typed, not the session -- what
            # every REPL does, and the only reading of it that cannot
            # lose work.
            print()
            continue
        pending = ""
        if source is None:
            print()
            return 0
        line = source.strip()
        if not line:
            continue
        if line in QUIT:
            return 0
        if line.startswith(":"):
            outcome = run_meta(session, line, report)
            session = outcome.session
            pending = outcome.pending
            if pending and not reader.interactive:
                # Nothing to edit it with, so showing it is the whole of
                # what `:edit` can do here.
                print(pending)
                pending = ""
            continue
        try:
            stmts = parse_source(source)
        except (LexError, ParseError) as e:
            report(e)
            continue
        session, refused = submit(session, stmts, report, source)
        if refused is None:
            continue
        name = undefined_name(refused)
        if name is None or not defines_function(stmts) or not reader.interactive:
            report(refused)
            continue
        if reader.ask(undefined_message(name)) == "edit":
            pending = source
