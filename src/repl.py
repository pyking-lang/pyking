"""The REPL: `pyk repl`. A session is a program written one entry at a
time: each entry is checked against what the entries before it left
behind, then run there. Includes a multi-line terminal line editor
(Editor) with history, indentation, and Pyking-aware line completion.
See docs/source.md ("repl.py") and README.md.

Data structures:
    Session -- a REPL session: statements seen, machine state, types,
        store, source text of each definition.
    Buffer -- the entry being typed: lines, cursor row/col.
    Editor -- the terminal line editor.
    PipeReader -- the non-terminal (piped input) reader.
    Outcome -- what a meta-command leaves behind.

Functions:
    start(format_error) -- runs the REPL loop.
    submit(session, stmts, report, source) -- checks and runs one entry.
    new_session() -- an empty session.
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
    """A REPL session. An entry is checked the way it is run: each is
    its own group, checked and run against what earlier entries left
    behind (see docs/source.md, "repl.py"). Fields:
    seen: (Stmt,) (every statement given so far, for symbolize),
    state: interpreter.State (the machine's names -> values),
    types: {String: Type} (the checker's names -> types),
    store: typesystem.Store (what the checker has worked out),
    sources: {String: String} (each name's own source text, for :edit)."""
    seen: tuple = ()
    state: interpreter.State = None
    types: dict = field(default_factory=typesystem.builtin_env)
    store: typesystem.Store = field(default_factory=typesystem.empty_store)
    sources: dict = field(default_factory=dict)


def new_session():
    """An empty session: builtins in scope, nothing seen. () -> Session"""
    return Session(state=interpreter.initial_state([], interpreter.ConsoleHost()))


# --- reading ---------------------------------------------------------


def complete(source):
    """Whether source is a whole entry, per the parser (anything wrong
    for another reason counts as complete). String -> Bool"""
    try:
        parse(lexing("<repl>", list(source + "\n")))
        return True
    except (LexError, ParseError) as e:
        return not any(e.message.startswith(reason) for reason in INCOMPLETE)


def next_indent(source):
    """The indentation the line after source belongs at: one level in
    if the last line opened a block (ends in ':'), level with it
    otherwise. String -> String"""
    lines = [line for line in source.splitlines() if line.strip()]
    if not lines:
        return ""
    last = lines[-1]
    indent = last[: len(last) - len(last.lstrip())]
    return indent + INDENT if last.rstrip().endswith(":") else indent


def parse_source(source, name="<repl>"):
    """source as a list of statements. Raises LexError/ParseError.
    String -> String -> [Stmt]"""
    return parse(lexing(name, list(source + "\n")))


def read_entry(read_line):
    """One entry, a line at a time from read_line (the non-terminal
    fallback). Returns the source text, or None at end of input.
    (String -> String) -> String?"""
    line = read_line(PROMPT)
    if line is None:
        return None
    if complete(line):
        # A block that parses is not necessarily finished (`def f():`
        # with one statement parses fine, but `else:` may follow), so
        # only a single complete line is submitted without a blank line.
        return line
    lines = [line]
    while True:
        more = read_line(CONTINUATION)
        if more is None or not more.strip():
            return "\n".join(lines)
        lines.append(more)


# --- the editing buffer ----------------------------------------------
#
# A frozen value with pure operations over it, so that everything about
# *what the text is* can be reasoned about (and tested) without a
# terminal anywhere in sight. `Editor` below owns the parts that cannot
# be pure: the tty, the history, and the screen.


@dataclass(frozen=True)
class Buffer:
    """The entry being typed. Fields: lines: (String,), row: Int,
    col: Int (cursor position)."""
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
    """A Buffer holding text, cursor at the end (default) or the start.
    String -> Bool -> Buffer"""
    lines = tuple(text.split("\n")) or ("",)
    if not at_end:
        return Buffer(lines, 0, 0)
    return Buffer(lines, len(lines) - 1, len(lines[-1]))


def _indent_step(line, col):
    """How much one backspace at col removes: back to the previous
    indentation stop if only spaces precede col, else one character.
    String -> Int -> Int"""
    if line[:col].strip():
        return 1
    return col - (col - 1) // len(INDENT) * len(INDENT)


def _with_line(buf, row, text, col):
    """buf with line row replaced by text, cursor at col.
    Buffer -> Int -> String -> Int -> Buffer"""
    lines = buf.lines[:row] + (text,) + buf.lines[row + 1:]
    return Buffer(lines, row, col)


def insert(buf, text):
    """Inserts text at the cursor. Buffer -> String -> Buffer"""
    line = buf.line
    return _with_line(
        buf, buf.row, line[: buf.col] + text + line[buf.col:], buf.col + len(text)
    )


def newline(buf, indent):
    """Splits the line at the cursor, carrying indent onto the new one.
    Buffer -> String -> Buffer"""
    line = buf.line
    head, tail = line[: buf.col], line[buf.col:]
    lines = buf.lines[: buf.row] + (head, indent + tail) + buf.lines[buf.row + 1:]
    return Buffer(lines, buf.row + 1, len(indent))


def backspace(buf):
    """Deletes backwards: a whole level of indentation at a time when
    that is what is being deleted (see _indent_step), else one
    character. Buffer -> Buffer"""
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
    """Deletes the character at the cursor. Buffer -> Buffer"""
    line = buf.line
    if buf.col < len(line):
        return _with_line(buf, buf.row, line[: buf.col] + line[buf.col + 1:], buf.col)
    if buf.row == len(buf.lines) - 1:
        return buf
    joined = line + buf.lines[buf.row + 1]
    lines = buf.lines[: buf.row] + (joined,) + buf.lines[buf.row + 2:]
    return Buffer(lines, buf.row, buf.col)


def kill_to_end(buf):
    """Deletes from the cursor to the end of the line. Buffer -> Buffer"""
    return _with_line(buf, buf.row, buf.line[: buf.col], buf.col)


def left(buf):
    """Moves the cursor left one character, across line boundaries.
    Buffer -> Buffer"""
    if buf.col > 0:
        return replace(buf, col=buf.col - 1)
    if buf.row == 0:
        return buf
    return Buffer(buf.lines, buf.row - 1, len(buf.lines[buf.row - 1]))


def right(buf):
    """Moves the cursor right one character, across line boundaries.
    Buffer -> Buffer"""
    if buf.col < len(buf.line):
        return replace(buf, col=buf.col + 1)
    if buf.row == len(buf.lines) - 1:
        return buf
    return Buffer(buf.lines, buf.row + 1, 0)


def up(buf):
    """One line up, keeping the column where it fits, or None if
    already on the first line. Buffer -> Buffer?"""
    if buf.row == 0:
        return None
    return Buffer(buf.lines, buf.row - 1, min(buf.col, len(buf.lines[buf.row - 1])))


def down(buf):
    """One line down, or None if already on the last line.
    Buffer -> Buffer?"""
    if buf.row == len(buf.lines) - 1:
        return None
    return Buffer(buf.lines, buf.row + 1, min(buf.col, len(buf.lines[buf.row + 1])))


def home(buf):
    """Moves the cursor to the start of the line. Buffer -> Buffer"""
    return replace(buf, col=0)


def end(buf):
    """Moves the cursor to the end of the line. Buffer -> Buffer"""
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
    "\t": "tab",
    "\x7f": "backspace", "\x08": "backspace",
    "\x01": "home", "\x05": "end", "\x0b": "kill",
    "\x03": "interrupt", "\x04": "eof", "\x0c": "clear",
}

# The keycode a terminal reports for Return when it reports keys as
# numbers rather than as characters, and the modifier bit for Shift. A
# terminal in "CSI u" mode sends Shift+Return as `\x1b[13;2u`, and one
# using xterm's older `modifyOtherKeys` as `\x1b[27;2;13~`; both are read
# below. A terminal doing neither sends a plain `\r` for Shift+Return,
# indistinguishable from Return itself -- see `submit` in HELP.
_RETURN_KEY = 13
_SHIFT = 2

# How long to wait for the rest of an escape sequence before concluding
# that the Escape key was pressed on its own. An arrow key sends its
# bytes in one burst, so anything still absent after this came from a
# human finger.
_ESCAPE_DELAY = 0.05


class Editor:
    """A multi-line line editor over a terminal in raw mode, with
    history of whole entries (not lines, unlike readline). is_complete
    and indent_for are the only things it needs to know about the
    language: whether Enter submits, and how far the next line indents."""

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
        """One entry, or None at end of input; '' if abandoned with
        Escape/Ctrl-C. initial, if given, seeds the buffer instead of
        starting empty. self -> String -> String?"""
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
                    case "submit":
                        # Shift+Return: this entry is finished, whatever
                        # it looks like -- the way out of a block without
                        # the blank line, and the only key here that is
                        # about *ending* rather than editing.
                        return self._finish(buf, self._submitted(buf))
                    case "tab":
                        buf = insert(buf, INDENT)
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
        """Shows message and waits for one key: Escape means "cancel",
        anything else means "edit". self -> String -> String"""
        self._write(message.replace("\n", "\r\n") + "\r\n")
        with self._raw():
            _, key = self._key()
        return "cancel" if key in ("escape", "interrupt", "eof") else "edit"

    def _submits(self, buf):
        """Whether Enter ends the entry: a single complete line does; a
        multi-line block ends only on a blank line. self -> Buffer -> Bool"""
        if len(buf.lines) == 1:
            return self.is_complete(buf.text)
        return not buf.line.strip()

    def _submitted(self, buf):
        """buf's text, with the trailing blank line dropped.
        self -> Buffer -> String"""
        lines = buf.lines
        while len(lines) > 1 and not lines[-1].strip():
            lines = lines[:-1]
        return "\n".join(lines)

    def _before(self, buf):
        """The text above and including the cursor's line, for
        indent_for. self -> Buffer -> String"""
        return "\n".join(buf.lines[: buf.row + 1])

    def _finish(self, buf, result):
        """Leaves the entry on screen, moves the cursor below it, and
        records result in history. self -> Buffer -> String? -> String?"""
        self._to_bottom()
        self._write("\r\n")
        if result and result.strip() and (not self.history or self.history[-1] != result):
            self.history.append(result)
        return result

    # --- the terminal ---

    class _Raw:
        """A context manager: raw terminal mode for one read(), restored
        on exit."""

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
        """The next key, as ("text", characters) or ("key", name).
        self -> (String, String)"""
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
        """The key an Escape byte started: "escape" alone, "submit" for
        a modified Return, or a control-sequence key. self -> String"""
        if not self._waiting():
            return "escape"
        match self._char():
            case "\r" | "\n":
                # Return with something held down -- Alt or Shift,
                # depending on the terminal. Either way it means "this
                # entry is finished".
                return "submit"
            case "[":
                return self._control_sequence()
        return "ignored"

    def _control_sequence(self):
        """Reads a \\x1b[ sequence to its final letter and names it.
        self -> String"""
        parameters = ""
        while True:
            char = self._char()
            if char is None:
                return "ignored"
            if not (char.isdigit() or char == ";"):
                return self._named(parameters, char)
            parameters += char

    def _named(self, parameters, final):
        """The key a control sequence stands for, from its parameters and
        its final letter."""
        numbers = [int(part) for part in parameters.split(";") if part.isdigit()]
        match (final, numbers):
            case ("u", [_RETURN_KEY, modifier, *_]) if modifier >= _SHIFT:
                return "submit"
            case ("~", [27, modifier, _RETURN_KEY]) if modifier >= _SHIFT:
                # xterm's `modifyOtherKeys`, which says the keycode last.
                return "submit"
            case ("~", [number, *_]):
                return _TILDES.get(str(number), "ignored")
            case (letter, _) if letter in _ARROWS:
                return _ARROWS[letter]
        return "ignored"

    def _waiting(self):
        return bool(select.select([sys.stdin.fileno()], [], [], _ESCAPE_DELAY)[0])

    def _char(self):
        """Reads one character, decoding UTF-8 if needed, or None at
        end of input. self -> String?"""
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
        """Escapes that move the cursor from from_row to the (row,
        column) pair to. self -> Int -> (Int, Int) -> String"""
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
    """Reads entries from something that is not a terminal (a pipe, a
    transcript). Same interface as Editor; ignores initial and answers
    every ask() with "cancel"."""

    interactive = False

    def read(self, initial=""):
        """One entry, or None at end of input. self -> String -> String?"""
        def read_line(prompt):
            try:
                return input(prompt)
            except EOFError:
                return None

        return read_entry(read_line)

    def ask(self, _message):
        """Always "cancel" (there is no key to press). self -> String -> String"""
        return "cancel"


def make_reader():
    """An Editor if stdin is a terminal, a PipeReader otherwise.
    () -> Editor | PipeReader"""
    if termios is None or not sys.stdin.isatty():
        return PipeReader()
    return Editor(complete, next_indent)


# --- accepting an entry ----------------------------------------------


def submit(session, stmts, report, source=""):
    """Checks stmts as one entry (all of it, before any of it runs),
    then runs whichever of them the checker accepted, reporting any
    runtime error via report. source is kept per-name for :edit.
    Returns (session, refused) -- refused is the check-time error, if
    any, left for the caller to handle rather than reported here.
    Session -> [Stmt] -> (Exception -> ()) -> String -> (Session, Exception?)"""
    seen = symbolize(list(session.seen) + list(stmts))
    entry = seen[len(session.seen):]
    try:
        checked = check_entry(entry, session.types, session.store)
    except (AnalysisError, typesystem.TypeError_) as e:
        return session, e

    # `seen` grows whether or not every statement runs: a symbol handed
    # out once must not be handed out again.
    session = replace(session, seen=tuple(seen))
    state = interpreter.declare_entry(session.state, entry)
    for stmt, supplied, types, store in checked:
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
            store=store,
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
    """What stmt defined, as name -> the source text that defined it
    (sliced from source by whole lines, or pprint_program if no
    source). Stmt -> String -> {String: String}"""
    names = defined_names(stmt)
    if not names:
        return {}
    text = statement_source(source, stmt) if source else pprint_program([stmt])
    return {name: text for name in names}


def defined_names(stmt):
    """The names a top-level statement binds. Stmt -> [String]"""
    match stmt:
        case SFunctionDef(_, name, _, _, _, _, _):
            return [name]
    return [name for name, _ in bound_names(stmt)]


def statement_source(source, stmt):
    """The whole lines of source a statement covers.
    String -> Stmt -> String"""
    lines = source.splitlines()
    return "\n".join(lines[stmt.info.row1 - 1: stmt.info.row2])


def check_entry(entry, types, store):
    """Checks entry as one group (defs declared together via
    declare_functions, then check_stmt per statement), keeping each
    statement's environment and store rather than only the last.
    [Stmt] -> {String: Type} -> Store -> [(Stmt, Type, {String: Type}, Store)]"""
    types, store = typesystem.declare_functions(entry, types, store)
    tmap = {}
    checked = []
    for stmt in entry:
        supplied, types, store = typesystem.check_stmt(
            stmt, types, tmap, None, None, store
        )
        checked.append((stmt, supplied, types, store))
    return checked


def show(value, type_):
    """Prints value as `value : Type`, or nothing for unit/None.
    Value? -> Type? -> ()"""
    if value is None or isinstance(value, interpreter.VUnit):
        return
    print(value_text(value) + type_suffix(type_))


def value_text(value):
    """A value as the prompt shows it: display_value, except a
    function shows as <function>. Value -> String"""
    match value:
        case interpreter.VClosure() | interpreter.VBuiltin():
            return "<function>"
    return interpreter.display_value(value)


def type_suffix(type_):
    """` : Type`, or "" if type_ is None. Type? -> String"""
    return f" : {pprint_type(type_)}" if type_ is not None else ""


def binding_types(session):
    """name -> Type for what the session has bound, resolved against
    its store (so a deferred function shows what it turned out to be).
    Session -> {String: Type}"""
    return {
        name: typesystem.resolved(type_, session.store)
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
    """Prints the command list. Session -> String -> (Exception -> ()) -> Session"""
    print(HELP)
    return session


def meta_ls(session, _argument, _report):
    """Prints what the session has bound, as `name = value : Type`
    (builtins excluded), in binding order.
    Session -> String -> (Exception -> ()) -> Session"""
    bindings = interpreter.bindings_in_scope(session.state.env)
    types = binding_types(session)
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
    """Prints the type of the expression argument, checked in the
    session's own type environment.
    Session -> String -> (Exception -> ()) -> Session"""
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
        checked, store = typesystem.check_expr(
            stmts[0].expr, session.types, {}, session.store
        )
        print(pprint_type(typesystem.resolved(checked, store)))
    except (AnalysisError, typesystem.TypeError_) as e:
        report(e)
    return session


def meta_ast(session, argument, report):
    """Prints the parsed form of the statement argument.
    Session -> String -> (Exception -> ()) -> Session"""
    if not argument:
        print("usage: :ast <statement>")
        return session
    try:
        print(pprint_program(parse_source(argument)))
    except (LexError, ParseError) as e:
        report(e)
    return session


def meta_tokens(session, argument, report):
    """Prints the token stream for the line argument.
    Session -> String -> (Exception -> ()) -> Session"""
    try:
        for token in lexing("<repl>", list(argument + "\n")):
            print(f"{pprint_info(token.info)} {pprint_token(token)}")
    except LexError as e:
        report(e)
    return session


@dataclass(frozen=True)
class Outcome:
    """What a meta-command leaves behind. Fields: session: Session,
    pending: String (text to put back in front of the user; only :edit
    sets this)."""
    session: Session
    pending: str = ""


def meta_load(session, argument, report):
    """Reads a file and submits its statements as one entry.
    Session -> String -> (Exception -> ()) -> Session"""
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
    """Puts the source text that defined argument back into the prompt
    to edit and re-enter. Session -> String -> (Exception -> ()) -> Outcome"""
    if not argument:
        print("usage: :edit <name>")
        return session
    text = session.sources.get(argument)
    if text is None:
        print(f"nothing named '{argument}' was defined in this session")
        return session
    return Outcome(session, pending=text)


def meta_reset(_session, _argument, _report):
    """Starts a new, empty session. Session -> String -> (Exception -> ()) -> Session"""
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

HELP = """
Commands:
  :help            this help list
  :quit, :q        leave (or type Ctrl-D)
  :ls              list all bound values and variables
  :type <expr>     the type of expression <expr>
  :edit <name>     edit defined <name> again
  :ast <stmt>      the parsed form of <stmt>
  :tokens <line>   the token stream for <line>
  :load <file>     read a file into the session
  :reset           forget everything and start again
"""


def run_meta(session, line, report):
    """Runs the meta-command in line, or reports "unknown command".
    Session -> String -> (Exception -> ()) -> Outcome"""
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
    """The name an "unbound name" error is about, or None.
    Exception -> String?"""
    if isinstance(error, AnalysisError) and error.message.startswith(UNBOUND):
        return error.message[len(UNBOUND):].rstrip("'")
    return None


def undefined_message(name):
    """The prompt shown when a def names something not yet defined
    (see docs/source.md, "repl.py"). String -> String"""
    return (
        f"Identifier '{name}' is not yet defined. Press <esc> to cancel or "
        f"<space> to continue editing."
    )


def defines_function(stmts):
    """Whether stmts includes a def. [Stmt] -> Bool"""
    return any(isinstance(stmt, SFunctionDef) for stmt in stmts)


def start(format_error, read=None, session=None):
    """Runs the REPL loop until end of input or :quit. format_error is
    the driver's (src/pyk.py); read/session let a non-terminal caller
    drive the loop. (Exception -> String?) -> reader? -> Session? -> Int"""
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
