
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
class TokIf(Token):         # 'if'
    info: Info


@dataclass(frozen=True)
class TokElse(Token):       # 'else'
    info: Info


@dataclass(frozen=True)
class TokVar(Token):        # 'var'
    info: Info


@dataclass(frozen=True)
class TokAssign(Token):     # ':=' (mutation of a `var`)
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
        case TokIf():
            return "TokIf"
        case TokElse():
            return "TokElse"
        case TokVar():
            return "TokVar"
        case TokAssign():
            return "TokAssign"
        case TokIdent(_,s):
            return f"TokIdent('{s}')"


# --- lexer ---

def is_digit(x):
    return "0" <= x <= "9"


def is_letter(x):
    return x == "_" or ("a" <= x <= "z") or ("A" <= x <= "Z")


def is_digit_letter(x):
    return is_digit(x) or is_letter(x)


keywords = ["for", "in", "if", "else", "var", "def", "return"]


def keyword_token(name, info):
    match name:
        case "for":
            return TokFor(info)
        case "in":
            return TokIn(info)
        case "if":
            return TokIf(info)
        case "else":
            return TokElse(info)
        case "var":
            return TokVar(info)
        case "def":
            return TokDef(info)
        case "return":
            return TokReturn(info)


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


def scan_string(quote, chars):
    """Consumes a string body up to and including the closing `quote`,
    decoding backslash escapes as it goes. Returns `(value, length, rest)`
    where `length` is the number of source characters consumed (including
    the closing quote, excluding the opening one already consumed by the
    caller)."""
    value = []
    length = 0
    rest = chars
    while True:
        match rest:
            case []:
                raise LexError("Unexpected end of string literal")
            case ["\\", e, *xs] if e in _ESCAPES:
                value.append(_ESCAPES[e])
                length += 2
                rest = xs
            case ["\\", e, *_]:
                raise LexError(f"Unknown escape sequence '\\{e}' in string literal")
            case [c, *xs] if c == quote:
                return "".join(value), length + 1, xs
            case [c, *xs]:
                value.append(c)
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
                text, body_length, ys = scan_string(s, xs)
                length = 1 + body_length
                tokens.append(TokString(fi(r, c, length), text))
                c = c + length
                rest = ys

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
                raise LexError(f"Toking error: unknown character '{x}'.")

    return tokens

class ParseError(Exception):
    """Raised for syntax errors."""


# --- expression AST ---

class Expr:
    """Base class for the expression AST."""


@dataclass(frozen=True)
class EInt(Expr):
    info: Info
    value: int


@dataclass(frozen=True)
class EString(Expr):
    info: Info
    value: str


@dataclass(frozen=True)
class EVar(Expr):
    info: Info
    name: str


@dataclass(frozen=True)
class EAdd(Expr):           # left + right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class ESub(Expr):           # left - right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class EMul(Expr):           # left * right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class EDiv(Expr):           # left / right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class ELessThan(Expr):      # left < right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class ELessThanEq(Expr):    # left <= right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class EGreatThan(Expr):     # left > right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class EGreatThanEq(Expr):   # left >= right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class EEq(Expr):            # left == right
    info: Info
    left: Expr
    right: Expr


@dataclass(frozen=True)
class ECall(Expr):          # func(args...)
    info: Info
    func: Expr
    args: list


def _wrap(prec, min_prec, s):
    return f"({s})" if prec < min_prec else s


_PRINT_ESCAPES = {
    "\\": "\\\\",
    "'": "\\'",
    "\n": "\\n",
    "\t": "\\t",
    "\r": "\\r",
}


def _quote_string(s):
    # Always delimit with single quotes and escape whatever the lexer's
    # `scan_string` can decode back (backslash, the quote itself, and the
    # non-printable escapes), so the output round-trips through the lexer.
    body = "".join(_PRINT_ESCAPES.get(ch, ch) for ch in s)
    return f"'{body}'"


def pprint_expr(e, min_prec=0):
    # min_prec is the precedence required by the surrounding context; a
    # sub-expression built from a lower-precedence operator is parenthesized
    # so re-parsing the printed form reproduces the same AST.
    match e:
        case EInt(_, v):
            return str(v)
        case EString(_, s):
            return _quote_string(s)
        case EVar(_, name):
            return name
        case EAdd(_, l, r):
            return _wrap(2, min_prec, f"{pprint_expr(l, 2)} + {pprint_expr(r, 3)}")
        case ESub(_, l, r):
            return _wrap(2, min_prec, f"{pprint_expr(l, 2)} - {pprint_expr(r, 3)}")
        case EMul(_, l, r):
            return _wrap(3, min_prec, f"{pprint_expr(l, 3)} * {pprint_expr(r, 4)}")
        case EDiv(_, l, r):
            return _wrap(3, min_prec, f"{pprint_expr(l, 3)} / {pprint_expr(r, 4)}")
        case ELessThan(_, l, r):
            return _wrap(1, min_prec, f"{pprint_expr(l, 2)} < {pprint_expr(r, 2)}")
        case ELessThanEq(_, l, r):
            return _wrap(1, min_prec, f"{pprint_expr(l, 2)} <= {pprint_expr(r, 2)}")
        case EGreatThan(_, l, r):
            return _wrap(1, min_prec, f"{pprint_expr(l, 2)} > {pprint_expr(r, 2)}")
        case EGreatThanEq(_, l, r):
            return _wrap(1, min_prec, f"{pprint_expr(l, 2)} >= {pprint_expr(r, 2)}")
        case EEq(_, l, r):
            return _wrap(1, min_prec, f"{pprint_expr(l, 2)} == {pprint_expr(r, 2)}")
        case ECall(_, f, args):
            return f"{pprint_expr(f, 4)}({', '.join(pprint_expr(a) for a in args)})"


# --- statement AST ---

class Stmt:
    """Base class for the statement AST."""


@dataclass(frozen=True)
class SLet(Stmt):           # name = expr (immutable binding)
    info: Info
    name: str
    expr: Expr


@dataclass(frozen=True)
class SVar(Stmt):           # var name = expr (mutable declaration)
    info: Info
    name: str
    expr: Expr


@dataclass(frozen=True)
class SMutate(Stmt):        # name := expr (mutation of a `var`)
    info: Info
    name: str
    expr: Expr


@dataclass(frozen=True)
class SReturn(Stmt):        # return expr
    info: Info
    expr: Expr


@dataclass(frozen=True)
class SExprStmt(Stmt):      # expr used as a statement, e.g. print(x)
    info: Info
    expr: Expr


@dataclass(frozen=True)
class SFor(Stmt):           # for name in iterable: body
    info: Info
    name: str
    iterable: Expr
    body: list


@dataclass(frozen=True)
class SIf(Stmt):            # if cond: then_body [else: else_body]
    info: Info
    cond: Expr
    then_body: list
    else_body: list = None


@dataclass(frozen=True)
class SFunctionDef(Stmt):   # def name(params...): body
    info: Info
    name: str
    params: list
    body: list


def pprint_stmt(s, level=0):
    pad = "    " * level
    match s:
        case SLet(_, name, expr):
            return f"{pad}{name} = {pprint_expr(expr)}"
        case SVar(_, name, expr):
            return f"{pad}var {name} = {pprint_expr(expr)}"
        case SMutate(_, name, expr):
            return f"{pad}{name} := {pprint_expr(expr)}"
        case SReturn(_, expr):
            return f"{pad}return {pprint_expr(expr)}"
        case SExprStmt(_, expr):
            return f"{pad}{pprint_expr(expr)}"
        case SFor(_, name, iterable, body):
            lines = [f"{pad}for {name} in {pprint_expr(iterable)}:"]
            lines += [pprint_stmt(st, level + 1) for st in body]
            return "\n".join(lines)
        case SIf(_, cond, then_body, else_body):
            lines = [f"{pad}if {pprint_expr(cond)}:"]
            lines += [pprint_stmt(st, level + 1) for st in then_body]
            if else_body is not None:
                lines.append(f"{pad}else:")
                lines += [pprint_stmt(st, level + 1) for st in else_body]
            return "\n".join(lines)
        case SFunctionDef(_, name, params, body):
            lines = [f"{pad}def {name}({', '.join(params)}):"]
            lines += [pprint_stmt(st, level + 1) for st in body]
            return "\n".join(lines)


def pprint_program(stmts):
    return "\n".join(pprint_stmt(s) for s in stmts)


# --- parser ---
#
# There are no newline/separator tokens in the token stream (see `lexing`);
# statement boundaries fall out naturally because each statement's grammar
# stops consuming as soon as the next token can't extend it. Blocks are
# delimited by the TokIndent/TokDedent tokens produced by the lexer.

def parse_atom(tokens):
    match tokens:
        case [TokInt(info, v), *rest]:
            return parse_call_tail(EInt(info, v), rest)
        case [TokString(info, s), *rest]:
            return parse_call_tail(EString(info, s), rest)
        case [TokIdent(info, name), *rest]:
            return parse_call_tail(EVar(info, name), rest)
        case [TokLParen(_), *rest]:
            expr, rest = parse_expr(rest)
            match rest:
                case [TokRParen(_), *rest]:
                    return parse_call_tail(expr, rest)
                case _:
                    raise ParseError("expected ')'")
        case [t, *_]:
            raise ParseError(f"{pprint_info(t.info)}: unexpected token in expression")
        case []:
            raise ParseError("unexpected end of input in expression")


def parse_call_tail(expr, tokens):
    match tokens:
        case [TokLParen(info), *rest]:
            args, rest = parse_args(rest)
            return parse_call_tail(ECall(info, expr, args), rest)
        case _:
            return expr, tokens


def parse_args(tokens):
    match tokens:
        case [TokRParen(_), *rest]:
            return [], rest
        case _:
            arg, rest = parse_expr(tokens)
            match rest:
                case [TokComma(_), *rest]:
                    args, rest = parse_args(rest)
                    return [arg] + args, rest
                case [TokRParen(_), *rest]:
                    return [arg], rest
                case _:
                    raise ParseError("expected ',' or ')' in call arguments")


def parse_multiplicative(tokens):
    left, rest = parse_atom(tokens)
    while True:
        match rest:
            case [TokMul(info), *rest2]:
                right, rest2 = parse_atom(rest2)
                left, rest = EMul(info, left, right), rest2
            case [TokDiv(info), *rest2]:
                right, rest2 = parse_atom(rest2)
                left, rest = EDiv(info, left, right), rest2
            case _:
                return left, rest


def parse_additive(tokens):
    left, rest = parse_multiplicative(tokens)
    while True:
        match rest:
            case [TokAdd(info), *rest2]:
                right, rest2 = parse_multiplicative(rest2)
                left, rest = EAdd(info, left, right), rest2
            case [TokSub(info), *rest2]:
                right, rest2 = parse_multiplicative(rest2)
                left, rest = ESub(info, left, right), rest2
            case _:
                return left, rest


def parse_expr(tokens):
    left, rest = parse_additive(tokens)
    match rest:
        case [TokLessThan(info), *rest]:
            right, rest = parse_additive(rest)
            return ELessThan(info, left, right), rest
        case [TokLessThanEq(info), *rest]:
            right, rest = parse_additive(rest)
            return ELessThanEq(info, left, right), rest
        case [TokGreatThan(info), *rest]:
            right, rest = parse_additive(rest)
            return EGreatThan(info, left, right), rest
        case [TokGreatThanEq(info), *rest]:
            right, rest = parse_additive(rest)
            return EGreatThanEq(info, left, right), rest
        case [TokEqEq(info), *rest]:
            right, rest = parse_additive(rest)
            return EEq(info, left, right), rest
        case _:
            return left, rest


def parse_params(tokens):
    match tokens:
        case [TokRParen(_), *rest]:
            return [], rest
        case [TokIdent(_, name), TokComma(_), *rest]:
            params, rest = parse_params(rest)
            return [name] + params, rest
        case [TokIdent(_, name), TokRParen(_), *rest]:
            return [name], rest
        case _:
            raise ParseError("expected parameter list")


def parse_block(tokens):
    match tokens:
        case [TokIndent(_), *rest]:
            stmts = []
            while True:
                match rest:
                    case [TokDedent(_), *rest]:
                        return stmts, rest
                    case _:
                        stmt, rest = parse_statement(rest)
                        stmts.append(stmt)
        case _:
            raise ParseError("expected an indented block")


def parse_statement(tokens):
    match tokens:
        case [TokDef(info), TokIdent(_, name), TokLParen(_), *rest]:
            params, rest = parse_params(rest)
            match rest:
                case [TokColon(_), *rest]:
                    body, rest = parse_block(rest)
                    return SFunctionDef(info, name, params, body), rest
                case _:
                    raise ParseError(f"{pprint_info(info)}: expected ':' after def header")

        case [TokReturn(info), *rest]:
            expr, rest = parse_expr(rest)
            return SReturn(info, expr), rest

        case [TokFor(info), TokIdent(_, name), TokIn(_), *rest]:
            iterable, rest = parse_expr(rest)
            match rest:
                case [TokColon(_), *rest]:
                    body, rest = parse_block(rest)
                    return SFor(info, name, iterable, body), rest
                case _:
                    raise ParseError(f"{pprint_info(info)}: expected ':' after for header")

        case [TokIf(info), *rest]:
            cond, rest = parse_expr(rest)
            match rest:
                case [TokColon(_), *rest]:
                    then_body, rest = parse_block(rest)
                    match rest:
                        case [TokElse(_), TokColon(_), *rest]:
                            else_body, rest = parse_block(rest)
                            return SIf(info, cond, then_body, else_body), rest
                        case _:
                            return SIf(info, cond, then_body, None), rest
                case _:
                    raise ParseError(f"{pprint_info(info)}: expected ':' after if header")

        case [TokVar(info), TokIdent(_, name), TokEq(_), *rest]:
            expr, rest = parse_expr(rest)
            return SVar(info, name, expr), rest

        case [TokIdent(info, name), TokEq(_), *rest]:
            expr, rest = parse_expr(rest)
            return SLet(info, name, expr), rest

        case [TokIdent(info, name), TokAssign(_), *rest]:
            expr, rest = parse_expr(rest)
            return SMutate(info, name, expr), rest

        case _:
            expr, rest = parse_expr(tokens)
            return SExprStmt(expr.info, expr), rest


def parse(tokens):
    """Parses a full token stream into a list of top-level statements."""
    stmts = []
    rest = tokens
    while rest:
        stmt, rest = parse_statement(rest)
        stmts.append(stmt)
    return stmts


# Main

args = sys.argv[1:]
show_tokens = "--tokens" in args
positional = [a for a in args if a != "--tokens"]

if len(positional) != 1:
    print("Usage: pykboot [--tokens] <filename>")
    sys.exit(1)

filename = positional[0]
with open(filename, "r") as f:
    data = f.read()

tokens = lexing(filename, list(data))
if show_tokens:
    print("\n".join(f"{pprint_info(t.info)} {pprint_token(t)}" for t in tokens))
    print("")

ast = parse(tokens)
print(pprint_program(ast))
