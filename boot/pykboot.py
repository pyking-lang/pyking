
import sys
from dataclasses import dataclass


class LexError(Exception):
    """Raised for lexical errors (mirrors OCaml's `failwith`)."""


# --- info ---

@dataclass(frozen=True)
class Info:
    file: str
    row1: int
    col1: int
    row2: int
    col2: int


def pprint_info(info):
    match info:
        case Info(file, r1, c1, r2, c2):
            return f"'{file}' {r1}:{c1}-{r2}:{c2}"


# --- token ADT ---

class Token:
    """Base class for the token ADT."""


@dataclass(frozen=True)
class TokInt(Token):
    value: int
    info: Info


@dataclass(frozen=True)
class TokString(Token):
    value: str
    info: Info


@dataclass(frozen=True)
class TokAdd(Token):        # '+' user defined
    info: Info


@dataclass(frozen=True)
class TokSub(Token):        # '-' user defined
    info: Info


@dataclass(frozen=True)
class TokMul(Token):        # '*' user defined
    info: Info


@dataclass(frozen=True)
class TokDiv(Token):        # '/' user defined
    info: Info


@dataclass(frozen=True)
class TokLessThanEq(Token):  # '<='
    info: Info


@dataclass(frozen=True)
class TokLessThan(Token):   # '<'
    info: Info


@dataclass(frozen=True)
class TokGreatThanEq(Token):  # '>='
    info: Info


@dataclass(frozen=True)
class TokGreatThan(Token):  # '>'
    info: Info


@dataclass(frozen=True)
class TokEqEq(Token):       # '=='
    info: Info


@dataclass(frozen=True)
class TokColon(Token):      # ':'
    info: Info


@dataclass(frozen=True)
class TokIndent(Token):     # start of an indented scope
    info: Info


@dataclass(frozen=True)
class TokDedent(Token):     # end of an indented scope
    info: Info


@dataclass(frozen=True)
class TokEq(Token):         # '='
    info: Info


@dataclass(frozen=True)
class TokLParen(Token):     # '('
    info: Info


@dataclass(frozen=True)
class TokRParen(Token):     # ')'
    info: Info


@dataclass(frozen=True)
class TokDot(Token):        # '.'
    info: Info


@dataclass(frozen=True)
class TokComma(Token):      # ','
    info: Info


@dataclass(frozen=True)
class TokDef(Token):        # 'def'
    info: Info


@dataclass(frozen=True)
class TokReturn(Token):     # 'return'
    info: Info


@dataclass(frozen=True)
class TokFor(Token):        # 'for'
    info: Info


@dataclass(frozen=True)
class TokIn(Token):         # 'in'
    info: Info


@dataclass(frozen=True)
class TokIdent(Token):
    value: str
    info: Info


def pprint_token(tok):
    match tok:
        case TokInt(x):
            return f"TokInt({x})"
        case TokString(s):
            return f"TokString('{s}')"
        case TokAdd():
            return "TokAdd"
        case TokSub():
            return "TokSub"
        case TokMul():
            return "TokMul"
        case TokDiv():
            return "TokDiv"
        case TokLessThanEq():
            return "TokLessThanEq"
        case TokLessThan():
            return "TokLessThan"
        case TokGreatThanEq():
            return "TokGreatThanEq"
        case TokGreatThan():
            return "TokGreatThan"
        case TokEqEq():
            return "TokEqEq"
        case TokColon():
            return "TokColon"
        case TokIndent():
            return "TokIndent"
        case TokDedent():
            return "TokDedent"
        case TokEq():
            return "TokEq"
        case TokLParen():
            return "TokLParen"
        case TokRParen():
            return "TokRParen"
        case TokDot():
            return "TokDot"
        case TokComma():
            return "TokComma"
        case TokDef():
            return "TokDef"
        case TokReturn():
            return "TokReturn"
        case TokFor():
            return "TokFor"
        case TokIn():
            return "TokIn"
        case TokIdent(s):
            return f"TokIdent('{s}')"


# --- lexer ---

def is_digit(x):
    return "0" <= x <= "9"


def is_letter(x):
    return x == "_" or ("a" <= x <= "z") or ("A" <= x <= "Z")


def is_digit_letter(x):
    return is_digit(x) or is_letter(x)


keywords = ["for", "in"]


def keyword_token(name, info):
    match name:
        case "for":
            return TokFor(info)
        case "in":
            return TokIn(info)


def string_until(pred, chars):
    """Returns the longest prefix of `chars` matching `pred`, and the rest."""
    i = 0
    while i < len(chars) and pred(chars[i]):
        i += 1
    return "".join(chars[:i]), chars[i:]


def skip(chars):
    match chars:
        case [_, *xs]:
            return xs
        case _:
            raise LexError("Unexpected end")


def lexing(file, chars):
    """Lexes a list of characters into a list of tokens."""

    def fi(r, c, length):
        return Info(file, r, c, r, c + length)

    tokens = []
    r, c = 1, 0
    rest = chars
    indent_stack = [0]
    line_start = True

    while True:
        match rest:
            case [x, *_] if line_start and x != "\n" and x != "#":
                spaces, ys = string_until(lambda ch: ch == " ", rest)
                if ys and ys[0] not in ("\n", "#"):
                    if len(spaces) % 4 != 0:
                        raise LexError(
                            f"{pprint_info(fi(r, c, len(spaces)))}: "
                            "indentation must be a multiple of 4 spaces."
                        )
                    level = len(spaces) // 4
                    if level > indent_stack[-1]:
                        indent_stack.append(level)
                        tokens.append(TokIndent(fi(r, c, 0)))
                    else:
                        while level < indent_stack[-1]:
                            indent_stack.pop()
                            tokens.append(TokDedent(fi(r, c, 0)))
                        if level != indent_stack[-1]:
                            raise LexError(
                                f"{pprint_info(fi(r, c, len(spaces)))}: "
                                "unindent does not match any outer "
                                "indentation level."
                            )
                    line_start = False
                c = c + len(spaces)
                rest = ys

            # Integer
            case [x, *_] if is_digit(x):
                y, ys = string_until(is_digit, rest)
                tokens.append(TokInt(int(y), fi(r, c, len(y))))
                c = c + len(y)
                rest = ys

            # Line comment
            case ["#", *xs]:
                text, ys = string_until(lambda ch: ch != "\n", xs)
                c = c + 1 + len(text)
                rest = ys

            # String
            case [s, *xs] if s in ("'", '"'):
                text, ys = string_until(lambda ch: ch != s, xs)
                length = 2 + len(text)
                tokens.append(TokString(text, fi(r, c, length)))
                c = c + length
                rest = skip(ys)

            # Operators that are user defined in real pyking
            case ["+", *xs]:
                tokens.append(TokAdd(fi(r, c, 1)))
                c, rest = c + 1, xs
            case ["-", *xs]:
                tokens.append(TokSub(fi(r, c, 1)))
                c, rest = c + 1, xs
            case ["*", *xs]:
                tokens.append(TokMul(fi(r, c, 1)))
                c, rest = c + 1, xs
            case ["/", *xs]:
                tokens.append(TokDiv(fi(r, c, 1)))
                c, rest = c + 1, xs
            case ["<", "=", *xs]:
                tokens.append(TokLessThanEq(fi(r, c, 2)))
                c, rest = c + 2, xs
            case ["<", *xs]:
                tokens.append(TokLessThan(fi(r, c, 1)))
                c, rest = c + 1, xs
            case [">", "=", *xs]:
                tokens.append(TokGreatThanEq(fi(r, c, 2)))
                c, rest = c + 2, xs
            case [">", *xs]:
                tokens.append(TokGreatThan(fi(r, c, 1)))
                c, rest = c + 1, xs
            case ["=", "=", *xs]:
                tokens.append(TokEqEq(fi(r, c, 2)))
                c, rest = c + 2, xs

            # Language lex items
            case [":", *xs]:
                tokens.append(TokColon(fi(r, c, 1)))
                c, rest = c + 1, xs
            case ["=", *xs]:
                tokens.append(TokEq(fi(r, c, 1)))
                c, rest = c + 1, xs
            case ["(", *xs]:
                tokens.append(TokLParen(fi(r, c, 1)))
                c, rest = c + 1, xs
            case [")", *xs]:
                tokens.append(TokRParen(fi(r, c, 1)))
                c, rest = c + 1, xs
            case [".", *xs]:
                tokens.append(TokDot(fi(r, c, 1)))
                c, rest = c + 1, xs
            case [",", *xs]:
                tokens.append(TokComma(fi(r, c, 1)))
                c, rest = c + 1, xs
            case [" ", *xs]:
                c, rest = c + 1, xs
            case ["\n", *xs]:
                r, c, rest = r + 1, 0, xs
                line_start = True

            # Keywords and identifiers
            case [x, *_] if is_letter(x):
                y, ys = string_until(is_digit_letter, rest)
                length = len(y)
                match y:
                    case "def":
                        tokens.append(TokDef(fi(r, c, length)))
                    case "return":
                        tokens.append(TokReturn(fi(r, c, length)))
                    case k if k in keywords:
                        tokens.append(keyword_token(k, fi(r, c, length)))
                    case _:
                        tokens.append(TokIdent(y, fi(r, c, length)))
                c = c + length
                rest = ys

            case []:
                while indent_stack[-1] > 0:
                    indent_stack.pop()
                    tokens.append(TokDedent(fi(r, c, 0)))
                break

            case [x, *_]:
                raise LexError(f"Toking error: unknown character '{x}'.")

    return tokens

#def parse_statement(ts):
#    match ts:
#        case [(_,TokIdent), (_,TokEq, Tok*ts]
#
#def parse(tokens):


# Main

if len(sys.argv) != 2:
    print("Usage: pykboot <filename>")
    sys.exit(1)

filename = sys.argv[1]
with open(filename, "r") as f:
    data = f.read()

tokens = lexing(filename, list(data))
print("\n".join(f"{pprint_info(t.info)} {pprint_token(t)}" for t in tokens))
