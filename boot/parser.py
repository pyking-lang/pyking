from dataclasses import replace

from lexer import (
    Info,
    TokInt, TokString, TokIdent,
    TokAdd, TokSub, TokMul, TokDiv,
    TokLessThanEq, TokLessThan, TokGreatThanEq, TokGreatThan, TokEqEq,
    TokColon, TokIndent, TokDedent, TokEq, TokLParen, TokRParen, TokComma,
    TokLBracket, TokRBracket,
    TokDef, TokReturn, TokFor, TokIn, TokIf, TokWhile, TokElse, TokVar, TokAssign,
    TokMatch, TokCase, TokArrow,
    TokTypeInt, TokTypeString, TokTypeBool,
)
from syntax import (
    EInt, EString, EVar,
    EAdd, ESub, EMul, EDiv,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EList,
    PInt, PString, PWildcard, PCapture, MatchCase,
    SLet, SVar, SMutate, SReturn, SExprStmt, SFor, SWhile, SIf, SFunctionDef, SMatch,
    TInt, TString, TBool, TList, TTuple, Param,
)


class ParseError(Exception):
    """Raised for syntax errors; carries the source position of the error."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


def combine_info(start, end):
    """Builds an Info spanning from the start of `start` to the end of `end`,
    e.g. for an AST node built from several tokens: the first token's start
    position and the last token's end position."""
    return Info(start.file, start.row1, start.col1, end.row2, end.col2)


_eof_info = None


def _here(tokens):
    """Returns the Info to blame for a parse error at the current position:
    the next token's info if there is one, otherwise the end of the file."""
    return tokens[0].info if tokens else _eof_info


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
        case [TokLParen(lp_info), *rest]:
            expr, rest = parse_expr(rest)
            match rest:
                case [TokRParen(rp_info), *rest]:
                    wrapped = replace(expr, info=combine_info(lp_info, rp_info))
                    return parse_call_tail(wrapped, rest)
                case _:
                    raise ParseError(_here(rest), "expected ')'")
        case [TokLBracket(lb_info), *rest]:
            elements, rb_info, rest = parse_list_elements(rest)
            list_info = combine_info(lb_info, rb_info)
            return parse_call_tail(EList(list_info, elements), rest)
        case [t, *_]:
            raise ParseError(t.info, "unexpected token in expression")
        case []:
            raise ParseError(_here(tokens), "unexpected end of input in expression")


def parse_call_tail(expr, tokens):
    match tokens:
        case [TokLParen(_), *rest]:
            args, rparen_info, rest = parse_args(rest)
            call_info = combine_info(expr.info, rparen_info)
            return parse_call_tail(ECall(call_info, expr, args), rest)
        case _:
            return expr, tokens


def parse_args(tokens):
    match tokens:
        case [TokRParen(info), *rest]:
            return [], info, rest
        case _:
            arg, rest = parse_expr(tokens)
            match rest:
                case [TokComma(_), *rest]:
                    args, rparen_info, rest = parse_args(rest)
                    return [arg] + args, rparen_info, rest
                case [TokRParen(info), *rest]:
                    return [arg], info, rest
                case _:
                    raise ParseError(_here(rest), "expected ',' or ')' in call arguments")


def parse_list_elements(tokens):
    match tokens:
        case [TokRBracket(info), *rest]:
            return [], info, rest
        case _:
            elem, rest = parse_expr(tokens)
            match rest:
                case [TokComma(_), *rest]:
                    elems, rb_info, rest = parse_list_elements(rest)
                    return [elem] + elems, rb_info, rest
                case [TokRBracket(info), *rest]:
                    return [elem], info, rest
                case _:
                    raise ParseError(_here(rest), "expected ',' or ']' in list literal")


def parse_multiplicative(tokens):
    left, rest = parse_atom(tokens)
    while True:
        match rest:
            case [TokMul(_), *rest2]:
                right, rest2 = parse_atom(rest2)
                left, rest = EMul(combine_info(left.info, right.info), left, right), rest2
            case [TokDiv(_), *rest2]:
                right, rest2 = parse_atom(rest2)
                left, rest = EDiv(combine_info(left.info, right.info), left, right), rest2
            case _:
                return left, rest


def parse_additive(tokens):
    left, rest = parse_multiplicative(tokens)
    while True:
        match rest:
            case [TokAdd(_), *rest2]:
                right, rest2 = parse_multiplicative(rest2)
                left, rest = EAdd(combine_info(left.info, right.info), left, right), rest2
            case [TokSub(_), *rest2]:
                right, rest2 = parse_multiplicative(rest2)
                left, rest = ESub(combine_info(left.info, right.info), left, right), rest2
            case _:
                return left, rest


def parse_expr(tokens):
    left, rest = parse_additive(tokens)
    match rest:
        case [TokLessThan(_), *rest]:
            right, rest = parse_additive(rest)
            return ELessThan(combine_info(left.info, right.info), left, right), rest
        case [TokLessThanEq(_), *rest]:
            right, rest = parse_additive(rest)
            return ELessThanEq(combine_info(left.info, right.info), left, right), rest
        case [TokGreatThan(_), *rest]:
            right, rest = parse_additive(rest)
            return EGreatThan(combine_info(left.info, right.info), left, right), rest
        case [TokGreatThanEq(_), *rest]:
            right, rest = parse_additive(rest)
            return EGreatThanEq(combine_info(left.info, right.info), left, right), rest
        case [TokEqEq(_), *rest]:
            right, rest = parse_additive(rest)
            return EEq(combine_info(left.info, right.info), left, right), rest
        case _:
            return left, rest


def parse_type(tokens):
    match tokens:
        case [TokTypeInt(info), *rest]:
            return TInt(info), rest
        case [TokTypeString(info), *rest]:
            return TString(info), rest
        case [TokTypeBool(info), *rest]:
            return TBool(info), rest
        case [TokLBracket(lb_info), *rest]:
            element, rest = parse_type(rest)
            match rest:
                case [TokRBracket(rb_info), *rest]:
                    return TList(combine_info(lb_info, rb_info), element), rest
                case _:
                    raise ParseError(_here(rest), "expected ']' in list type")
        case [TokLParen(lp_info), *rest]:
            elements, rp_info, rest = parse_type_elements(rest)
            return TTuple(combine_info(lp_info, rp_info), elements), rest
        case [t, *_]:
            raise ParseError(t.info, "expected a type")
        case []:
            raise ParseError(_here(tokens), "unexpected end of input in type")


def parse_type_elements(tokens):
    match tokens:
        case [TokRParen(info), *rest]:
            return [], info, rest
        case _:
            elem, rest = parse_type(tokens)
            match rest:
                case [TokComma(_), *rest]:
                    elems, rp_info, rest = parse_type_elements(rest)
                    return [elem] + elems, rp_info, rest
                case [TokRParen(info), *rest]:
                    return [elem], info, rest
                case _:
                    raise ParseError(_here(rest), "expected ',' or ')' in tuple type")


def parse_param(tokens):
    match tokens:
        case [TokIdent(info, name), TokColon(_), *rest]:
            type_, rest = parse_type(rest)
            return Param(combine_info(info, type_.info), name, type_), rest
        case [TokIdent(info, name), *rest]:
            return Param(info, name, None), rest
        case _:
            raise ParseError(_here(tokens), "expected a parameter")


def parse_params(tokens):
    match tokens:
        case [TokRParen(_), *rest]:
            return [], rest
        case _:
            param, rest = parse_param(tokens)
            match rest:
                case [TokComma(_), *rest]:
                    params, rest = parse_params(rest)
                    return [param] + params, rest
                case [TokRParen(_), *rest]:
                    return [param], rest
                case _:
                    raise ParseError(_here(rest), "expected ',' or ')' in parameter list")


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
            raise ParseError(_here(tokens), "expected an indented block")


def _block_end_info(header_info, body):
    """The Info to use as the end of a header+block construct: the last
    statement's info, or the header's own info if the block is empty."""
    return body[-1].info if body else header_info


def parse_pattern(tokens):
    match tokens:
        case [TokInt(info, v), *rest]:
            return PInt(info, v), rest
        case [TokString(info, s), *rest]:
            return PString(info, s), rest
        case [TokIdent(info, "_"), *rest]:
            return PWildcard(info), rest
        case [TokIdent(info, name), *rest]:
            return PCapture(info, name), rest
        case _:
            raise ParseError(
                _here(tokens),
                "expected a pattern (integer, string, '_', or identifier)",
            )


def parse_case(tokens):
    match tokens:
        case [TokCase(info), *rest]:
            pattern, rest = parse_pattern(rest)
            match rest:
                case [TokColon(_), *rest]:
                    body, rest = parse_block(rest)
                    case_info = combine_info(info, _block_end_info(info, body))
                    return MatchCase(case_info, pattern, body=body), rest
                case [TokArrow(_), *rest]:
                    # Pyking extension: `case pattern -> expr` is a
                    # single-expression case, not valid Python match syntax.
                    expr, rest = parse_expr(rest)
                    case_info = combine_info(info, expr.info)
                    return MatchCase(case_info, pattern, expr=expr), rest
                case _:
                    raise ParseError(
                        _here(rest), "expected ':' or '->' after case pattern"
                    )
        case _:
            raise ParseError(_here(tokens), "expected a 'case' clause")


def parse_cases(tokens):
    match tokens:
        case [TokIndent(_), *rest]:
            cases = []
            while True:
                match rest:
                    case [TokDedent(_), *rest]:
                        if not cases:
                            raise ParseError(
                                _here(rest), "match statement requires at least one case"
                            )
                        return cases, rest
                    case _:
                        case_clause, rest = parse_case(rest)
                        cases.append(case_clause)
        case _:
            raise ParseError(_here(tokens), "expected an indented block of 'case' clauses")


def parse_statement(tokens):
    match tokens:
        case [TokDef(info), TokIdent(_, name), TokLParen(_), *rest]:
            params, rest = parse_params(rest)
            return_type = None
            match rest:
                case [TokArrow(_), *rest2]:
                    return_type, rest = parse_type(rest2)
                case _:
                    pass
            match rest:
                case [TokColon(_), *rest]:
                    body, rest = parse_block(rest)
                    def_info = combine_info(info, _block_end_info(info, body))
                    return SFunctionDef(def_info, name, params, body, return_type), rest
                case _:
                    raise ParseError(_here(rest), "expected ':' after def header")

        case [TokReturn(info), *rest]:
            expr, rest = parse_expr(rest)
            return SReturn(combine_info(info, expr.info), expr), rest

        case [TokFor(info), TokIdent(_, name), TokIn(_), *rest]:
            iterable, rest = parse_expr(rest)
            match rest:
                case [TokColon(_), *rest]:
                    body, rest = parse_block(rest)
                    for_info = combine_info(info, _block_end_info(info, body))
                    return SFor(for_info, name, iterable, body), rest
                case _:
                    raise ParseError(_here(rest), "expected ':' after for header")

        case [TokWhile(info), *rest]:
            cond, rest = parse_expr(rest)
            match rest:
                case [TokColon(_), *rest]:
                    body, rest = parse_block(rest)
                    while_info = combine_info(info, _block_end_info(info, body))
                    return SWhile(while_info, cond, body), rest
                case _:
                    raise ParseError(_here(rest), "expected ':' after while header")

        case [TokMatch(info), *rest]:
            subject, rest = parse_expr(rest)
            match rest:
                case [TokColon(_), *rest]:
                    cases, rest = parse_cases(rest)
                    match_info = combine_info(info, cases[-1].info)
                    return SMatch(match_info, subject, cases), rest
                case _:
                    raise ParseError(_here(rest), "expected ':' after match header")

        case [TokIf(info), *rest]:
            cond, rest = parse_expr(rest)
            match rest:
                case [TokColon(_), *rest]:
                    then_body, rest = parse_block(rest)
                    match rest:
                        case [TokElse(_), TokColon(_), *rest]:
                            else_body, rest = parse_block(rest)
                            if_info = combine_info(info, _block_end_info(info, else_body))
                            return SIf(if_info, cond, then_body, else_body), rest
                        case _:
                            if_info = combine_info(info, _block_end_info(info, then_body))
                            return SIf(if_info, cond, then_body, None), rest
                case _:
                    raise ParseError(_here(rest), "expected ':' after if header")

        case [TokVar(info), TokIdent(_, name), TokEq(_), *rest]:
            expr, rest = parse_expr(rest)
            return SVar(combine_info(info, expr.info), name, expr), rest

        case [TokIdent(info, name), TokEq(_), *rest]:
            expr, rest = parse_expr(rest)
            return SLet(combine_info(info, expr.info), name, expr), rest

        case [TokIdent(info, name), TokAssign(_), *rest]:
            expr, rest = parse_expr(rest)
            return SMutate(combine_info(info, expr.info), name, expr), rest

        case _:
            expr, rest = parse_expr(tokens)
            return SExprStmt(expr.info, expr), rest


def parse(tokens):
    """Parses a full token stream into a list of top-level statements."""
    global _eof_info
    _eof_info = tokens[-1].info if tokens else Info("<empty>", 1, 0, 1, 0)
    stmts = []
    rest = tokens
    while rest:
        stmt, rest = parse_statement(rest)
        stmts.append(stmt)
    return stmts
