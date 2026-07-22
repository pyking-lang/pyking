from dataclasses import dataclass


class LexError(Exception):
    """Raised for lexical errors; carries the source position of the error."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


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
    info: Info
    value: int


@dataclass(frozen=True)
class TokString(Token):
    info: Info
    value: str


@dataclass(frozen=True)
class TokAdd(Token):        # '+' user defined
    info: Info


@dataclass(frozen=True)
class TokSub(Token):        # '-' user defined
    info: Info


@dataclass(frozen=True)
class TokArrow(Token):      # '->' (single-expression `case` clause)
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
class TokDotDot(Token):     # '..' (list-pattern "rest" marker: `..`/`..name`)
    info: Info


@dataclass(frozen=True)
class TokComma(Token):      # ','
    info: Info


@dataclass(frozen=True)
class TokLBracket(Token):   # '['
    info: Info


@dataclass(frozen=True)
class TokRBracket(Token):   # ']'
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
class TokIf(Token):         # 'if'
    info: Info


@dataclass(frozen=True)
class TokWhile(Token):      # 'while'
    info: Info


@dataclass(frozen=True)
class TokThen(Token):       # 'then' (if expression: `if e then e else e`)
    info: Info


@dataclass(frozen=True)
class TokElse(Token):       # 'else'
    info: Info


@dataclass(frozen=True)
class TokVar(Token):        # 'var'
    info: Info


@dataclass(frozen=True)
class TokMatch(Token):      # 'match'
    info: Info


@dataclass(frozen=True)
class TokCase(Token):       # 'case'
    info: Info


@dataclass(frozen=True)
class TokAssign(Token):     # ':=' (mutation of a `var`)
    info: Info


@dataclass(frozen=True)
class TokTypeInt(Token):    # 'Int' (type annotation)
    info: Info


@dataclass(frozen=True)
class TokTypeString(Token):  # 'String' (type annotation)
    info: Info


@dataclass(frozen=True)
class TokTypeBool(Token):   # 'Bool' (type annotation)
    info: Info


@dataclass(frozen=True)
class TokIdent(Token):
    info: Info
    value: str


def pprint_token(tok):
    match tok:
        case TokInt(_,x):
            return f"TokInt({x})"
        case TokString(_,s):
            return f"TokString('{s}')"
        case TokAdd():
            return "TokAdd"
        case TokSub():
            return "TokSub"
        case TokArrow():
            return "TokArrow"
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
        case TokDotDot():
            return "TokDotDot"
        case TokComma():
            return "TokComma"
        case TokLBracket():
            return "TokLBracket"
        case TokRBracket():
            return "TokRBracket"
        case TokDef():
            return "TokDef"
        case TokReturn():
            return "TokReturn"
        case TokFor():
            return "TokFor"
        case TokIn():
            return "TokIn"
        case TokIf():
            return "TokIf"
        case TokWhile():
            return "TokWhile"
        case TokThen():
            return "TokThen"
        case TokElse():
            return "TokElse"
        case TokVar():
            return "TokVar"
        case TokMatch():
            return "TokMatch"
        case TokCase():
            return "TokCase"
        case TokAssign():
            return "TokAssign"
        case TokTypeInt():
            return "TokTypeInt"
        case TokTypeString():
            return "TokTypeString"
        case TokTypeBool():
            return "TokTypeBool"
        case TokIdent(_,s):
            return f"TokIdent('{s}')"


# --- lexer ---

def is_digit(x):
    return "0" <= x <= "9"


def is_letter(x):
    return x == "_" or ("a" <= x <= "z") or ("A" <= x <= "Z")


def is_digit_letter(x):
    return is_digit(x) or is_letter(x)


keywords = [
    "for", "in", "if", "while", "then", "else", "var", "def", "return",
    "match", "case", "Int", "String", "Bool",
]


def keyword_token(name, info):
    match name:
        case "for":
            return TokFor(info)
        case "in":
            return TokIn(info)
        case "if":
            return TokIf(info)
        case "while":
            return TokWhile(info)
        case "then":
            return TokThen(info)
        case "else":
            return TokElse(info)
        case "var":
            return TokVar(info)
        case "def":
            return TokDef(info)
        case "return":
            return TokReturn(info)
        case "match":
            return TokMatch(info)
        case "case":
            return TokCase(info)
        case "Int":
            return TokTypeInt(info)
        case "String":
            return TokTypeString(info)
        case "Bool":
            return TokTypeBool(info)


def string_until(pred, chars):
    """Returns the longest prefix of `chars` matching `pred`, and the rest."""
    i = 0
    while i < len(chars) and pred(chars[i]):
        i += 1
    return "".join(chars[:i]), chars[i:]


_ESCAPES = {
    "n": "\n",
    "t": "\t",
    "r": "\r",
    "\\": "\\",
    "'": "'",
    '"': '"',
}


def scan_string(file, r, c, quote, chars):
    """Consumes a string body up to and including the closing `quote`,
    decoding backslash escapes as it goes. `r`/`c` is the position of the
    opening quote, used to build precise Info for any error raised here.
    Returns `(value, length, rest)` where `length` is the number of source
    characters consumed (including the closing quote, excluding the opening
    one already consumed by the caller)."""
    value = []
    length = 0
    rest = chars
    while True:
        match rest:
            case []:
                info = Info(file, r, c + 1 + length, r, c + 1 + length)
                raise LexError(info, "unexpected end of string literal")
            case ["\\", e, *xs] if e in _ESCAPES:
                value.append(_ESCAPES[e])
                length += 2
                rest = xs
            case ["\\", e, *_]:
                info = Info(file, r, c + 1 + length, r, c + 3 + length)
                raise LexError(info, f"unknown escape sequence '\\{e}'")
            case [c2, *xs] if c2 == quote:
                return "".join(value), length + 1, xs
            case [c2, *xs]:
                value.append(c2)
                length += 1
                rest = xs


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
                            fi(r, c, len(spaces)),
                            "indentation must be a multiple of 4 spaces",
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
                                fi(r, c, len(spaces)),
                                "unindent does not match any outer "
                                "indentation level",
                            )
                    line_start = False
                c = c + len(spaces)
                rest = ys

            # Integer
            case [x, *_] if is_digit(x):
                y, ys = string_until(is_digit, rest)
                tokens.append(TokInt(fi(r, c, len(y)), int(y)))
                c = c + len(y)
                rest = ys

            # Line comment
            case ["#", *xs]:
                text, ys = string_until(lambda ch: ch != "\n", xs)
                c = c + 1 + len(text)
                rest = ys

            # String
            case [s, *xs] if s in ("'", '"'):
                text, body_length, ys = scan_string(file, r, c, s, xs)
                length = 1 + body_length
                tokens.append(TokString(fi(r, c, length), text))
                c = c + length
                rest = ys

            # Operators that are user defined in real pyking
            case ["+", *xs]:
                tokens.append(TokAdd(fi(r, c, 1)))
                c, rest = c + 1, xs
            case ["-", ">", *xs]:  # Pyking extension: single-expression `case` clauses
                tokens.append(TokArrow(fi(r, c, 2)))
                c, rest = c + 2, xs
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
            case [":", "=", *xs]:
                tokens.append(TokAssign(fi(r, c, 2)))
                c, rest = c + 2, xs
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
            case ["[", *xs]:
                tokens.append(TokLBracket(fi(r, c, 1)))
                c, rest = c + 1, xs
            case ["]", *xs]:
                tokens.append(TokRBracket(fi(r, c, 1)))
                c, rest = c + 1, xs
            case [".", ".", *xs]:  # list-pattern rest marker: `..` / `..name`
                tokens.append(TokDotDot(fi(r, c, 2)))
                c, rest = c + 2, xs
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
                    case k if k in keywords:
                        tokens.append(keyword_token(k, fi(r, c, length)))
                    case _:
                        tokens.append(TokIdent(fi(r, c, length), y))
                c = c + length
                rest = ys

            case []:
                while indent_stack[-1] > 0:
                    indent_stack.pop()
                    tokens.append(TokDedent(fi(r, c, 0)))
                break

            case [x, *_]:
                raise LexError(fi(r, c, 1), f"unexpected character '{x}'")

    return tokens
