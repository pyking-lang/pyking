
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


@dataclass(frozen=True)
class TokString(Token):
    value: str


@dataclass(frozen=True)
class TokAdd(Token):        # '+' user defined
    pass


@dataclass(frozen=True)
class TokSub(Token):        # '-' user defined
    pass


@dataclass(frozen=True)
class TokMul(Token):        # '*' user defined
    pass


@dataclass(frozen=True)
class TokDiv(Token):        # '/' user defined
    pass


@dataclass(frozen=True)
class TokLessThanEq(Token):  # '<='
    pass


@dataclass(frozen=True)
class TokLessThan(Token):   # '<'
    pass


@dataclass(frozen=True)
class TokGreatThanEq(Token):  # '>='
    pass


@dataclass(frozen=True)
class TokGreatThan(Token):  # '>'
    pass


@dataclass(frozen=True)
class TokEqEq(Token):       # '=='
    pass


@dataclass(frozen=True)
class TokColon(Token):      # ':'
    pass


@dataclass(frozen=True)
class TokEq(Token):         # '='
    pass


@dataclass(frozen=True)
class TokLParen(Token):     # '('
    pass


@dataclass(frozen=True)
class TokRParen(Token):     # ')'
    pass


@dataclass(frozen=True)
class TokDot(Token):        # '.'
    pass


@dataclass(frozen=True)
class TokComma(Token):      # ','
    pass


@dataclass(frozen=True)
class TokDef(Token):        # 'def'
    pass


@dataclass(frozen=True)
class TokReturn(Token):     # 'return'
    pass


@dataclass(frozen=True)
class TokIdent(Token):
    value: str


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
        case TokIdent(s):
            return f"TokIdent('{s}')"


# --- lexer ---

def is_digit(x):
    return "0" <= x <= "9"


def is_letter(x):
    return x == "_" or ("a" <= x <= "z") or ("A" <= x <= "Z")


def is_digit_letter(x):
    return is_digit(x) or is_letter(x)


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
    """Lexes a list of characters into a list of (info, token) pairs."""

    def fi(r, c, length):
        return Info(file, r, c, r, c + length)

    tokens = []
    r, c = 1, 0
    rest = chars

    while True:
        match rest:
            # Integer
            case [x, *_] if is_digit(x):
                y, ys = string_until(is_digit, rest)
                tokens.append((fi(r, c, len(y)), TokInt(int(y))))
                c = c + len(y)
                rest = ys

            # Line comment
            case ["#", *xs]:
                _, ys = string_until(lambda ch: ch != "\n", xs)
                r = r + 1
                c = 0
                rest = ys

            # String
            case [s, *xs] if s in ("'", '"'):
                text, ys = string_until(lambda ch: ch != s, xs)
                length = 2 + len(text)
                tokens.append((fi(r, c, length), TokString(text)))
                c = c + length
                rest = skip(ys)

            # Operators that are user defined in real pyking
            case ["+", *xs]:
                tokens.append((fi(r, c, 1), TokAdd()))
                c, rest = c + 1, xs
            case ["-", *xs]:
                tokens.append((fi(r, c, 1), TokSub()))
                c, rest = c + 1, xs
            case ["*", *xs]:
                tokens.append((fi(r, c, 1), TokMul()))
                c, rest = c + 1, xs
            case ["/", *xs]:
                tokens.append((fi(r, c, 1), TokDiv()))
                c, rest = c + 1, xs
            case ["<", "=", *xs]:
                tokens.append((fi(r, c, 2), TokLessThanEq()))
                c, rest = c + 2, xs
            case ["<", *xs]:
                tokens.append((fi(r, c, 1), TokLessThan()))
                c, rest = c + 1, xs
            case [">", "=", *xs]:
                tokens.append((fi(r, c, 2), TokGreatThanEq()))
                c, rest = c + 2, xs
            case [">", *xs]:
                tokens.append((fi(r, c, 1), TokGreatThan()))
                c, rest = c + 1, xs
            case ["=", "=", *xs]:
                tokens.append((fi(r, c, 2), TokEqEq()))
                c, rest = c + 2, xs

            # Language lex items
            case [":", *xs]:
                tokens.append((fi(r, c, 1), TokColon()))
                c, rest = c + 1, xs
            case ["=", *xs]:
                tokens.append((fi(r, c, 1), TokEq()))
                c, rest = c + 1, xs
            case ["(", *xs]:
                tokens.append((fi(r, c, 1), TokLParen()))
                c, rest = c + 1, xs
            case [")", *xs]:
                tokens.append((fi(r, c, 1), TokRParen()))
                c, rest = c + 1, xs
            case [".", *xs]:
                tokens.append((fi(r, c, 1), TokDot()))
                c, rest = c + 1, xs
            case [",", *xs]:
                tokens.append((fi(r, c, 1), TokComma()))
                c, rest = c + 1, xs
            case [" ", *xs]:
                c, rest = c + 1, xs
            case ["\n", *xs]:
                r, c, rest = r + 1, 0, xs

            # Keywords and identifiers
            case [x, *_] if is_letter(x):
                y, ys = string_until(is_digit_letter, rest)
                length = len(y)
                match y:
                    case "def":
                        tokens.append((fi(r, c, length), TokDef()))
                    case "return":
                        tokens.append((fi(r, c, length), TokReturn()))
                    case _:
                        tokens.append((fi(r, c, length), TokIdent(y)))
                c = c + length
                rest = ys

            case []:
                break

            case [x, *_]:
                raise LexError(f"Toking error: unknown character '{x}'.")

    return tokens

# Main

if len(sys.argv) != 2:
    print("Usage: pykboot <filename>")
    sys.exit(1)

filename = sys.argv[1]
with open(filename, "r") as f:
    data = f.read()

tokens = lexing(filename, list(data))
print("\n".join(f"{pprint_info(fi)} {pprint_token(t)}" for fi, t in tokens))
