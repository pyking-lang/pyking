"""Recursive-descent parser: tokens (from lexer.py) to the AST defined
in syntax.py. Also enforces the handful of grammar rules that cannot be
expressed in EBNF -- duplicate pattern captures, value-form if/match
branches, one statement per line. See PYKING.md for the grammar and
docs/source.md ("parser.py").

Data structures:
    ParseError -- a parse failure, with the source position.

Functions:
    parse(tokens) -- parses a full token stream into a list of statements.
    parse_statement(tokens) -- parses one statement.
    parse_expr(tokens) -- parses one expression.
    parse_block(tokens) -- parses one indented block.
    parse_type(tokens) -- parses one type annotation.
    parse_pattern(tokens) -- parses one match/case pattern.
    combine_info(start, end) -- spans an Info from two nodes' Infos.
"""

from dataclasses import replace

from lexer import (
    Info,
    TokInt, TokString, TokIdent,
    TokAdd, TokSub, TokMul, TokDiv,
    TokLessThanEq, TokLessThan, TokGreatThanEq, TokGreatThan, TokEqEq,
    TokColon, TokIndent, TokDedent, TokEq, TokLParen, TokRParen, TokComma,
    TokLBracket, TokRBracket, TokDotDot,
    TokDef, TokReturn, TokFor, TokIn, TokIf, TokWhile, TokThen, TokElse, TokVar,
    TokAssign, TokMatch, TokCase, TokArrow, TokPipe,
    TokTypeInt, TokTypeString, TokTypeBool, TokTrue, TokFalse,
)
from syntax import (
    EInt, EString, EBool, EVar,
    EAdd, ESub, EMul, EDiv, ENeg,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EList, ETuple,
    EIf, EListComp, CompFor, CompIf,
    PInt, PString, PBool, PWildcard, PCapture, PTuple, PList, ListRest, MatchCase,
    pprint_stmt, pprint_pattern,
    Stmt,
    SLet, SLetStmt, SVar, SMutate, SReturn, SReturnStmt, SExprStmt, SFor, SWhile, SIf,
    SFunctionDef, SMatch,
    TInt, TString, TBool, TList, TTuple, TOr, TFunction, Param,
    TargetName, TargetTuple,
)


class ParseError(Exception):
    """A syntax failure, with the source position."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


def combine_info(start, end):
    """Spans an Info from the start of start to the end of end.
    Info -> Info -> Info"""
    return Info(start.file, start.row1, start.col1, end.row2, end.col2)


_eof_info = None


def _here(tokens):
    """The Info to blame for a parse error at the current position: the
    next token's, or end-of-file. [Token] -> Info"""
    return tokens[0].info if tokens else _eof_info


# --- parser ---

def parse_atom(tokens):
    """Parses one atom: a literal, name, parenthesized expression,
    tuple, list, or list comprehension. [Token] -> (Expr, [Token])"""
    match tokens:
        case [TokInt(info, v), *rest]:
            return parse_call_tail(EInt(info, v), rest)
        case [TokString(info, s), *rest]:
            return parse_call_tail(EString(info, s), rest)
        case [TokTrue(info), *rest]:
            return parse_call_tail(EBool(info, True), rest)
        case [TokFalse(info), *rest]:
            return parse_call_tail(EBool(info, False), rest)
        case [TokIdent(info, name), *rest]:
            return parse_call_tail(EVar(info, name), rest)
        case [TokLParen(lp_info), TokRParen(rp_info), *rest]:
            # (): the empty tuple, i.e. Unit.
            return parse_call_tail(ETuple(combine_info(lp_info, rp_info), []), rest)
        case [TokLParen(lp_info), *rest]:
            first, rest = parse_expr(rest)
            match rest:
                case [TokComma(_), TokRParen(rp_info), *rest]:
                    # (e,): a singleton tuple.
                    tuple_info = combine_info(lp_info, rp_info)
                    return parse_call_tail(ETuple(tuple_info, [first]), rest)
                case [TokComma(_), *rest]:
                    # (e, e, ...): reuse `parse_args`'s "comma-separated
                    # exprs up to ')', trailing comma allowed" shape --
                    # it's exactly the tuple-tail grammar too.
                    elements, rp_info, rest = parse_args(rest)
                    tuple_info = combine_info(lp_info, rp_info)
                    return parse_call_tail(ETuple(tuple_info, [first] + elements), rest)
                case [TokRParen(rp_info), *rest]:
                    # (e): just a parenthesized expression, not a tuple.
                    wrapped = replace(first, info=combine_info(lp_info, rp_info))
                    return parse_call_tail(wrapped, rest)
                case _:
                    raise ParseError(_here(rest), "expected ',' or ')'")
        case [TokLBracket(lb_info), TokRBracket(rb_info), *rest]:
            return parse_call_tail(EList(combine_info(lb_info, rb_info), []), rest)
        case [TokLBracket(lb_info), *rest]:
            first, rest = parse_expr(rest)
            match rest:
                case [TokFor(_), *_]:
                    # [expr for pattern in seq ...]: a list comprehension,
                    # not a plain list literal.
                    clauses, rb_info, rest = parse_comp_clauses(rest)
                    comp_info = combine_info(lb_info, rb_info)
                    return parse_call_tail(EListComp(comp_info, first, clauses), rest)
                case [TokComma(_), *rest]:
                    elements, rb_info, rest = parse_list_elements(rest)
                    list_info = combine_info(lb_info, rb_info)
                    return parse_call_tail(EList(list_info, [first] + elements), rest)
                case [TokRBracket(rb_info), *rest]:
                    list_info = combine_info(lb_info, rb_info)
                    return parse_call_tail(EList(list_info, [first]), rest)
                case _:
                    raise ParseError(
                        _here(rest), "expected ',', 'for', or ']' in list literal"
                    )
        case [t, *_]:
            raise ParseError(t.info, "unexpected token in expression")
        case []:
            raise ParseError(_here(tokens), "unexpected end of input in expression")


def parse_call_tail(expr, tokens):
    """Parses zero or more call suffixes onto expr, chaining `f(1)(2)`.
    A `(` only extends expr if it starts on the same source row expr
    ended on, so it cannot swallow the next statement's.
    Expr -> [Token] -> (Expr, [Token])"""
    match tokens:
        case [TokLParen(lp_info), *rest] if lp_info.row1 == expr.info.row2:
            args, rparen_info, rest = parse_args(rest)
            call_info = combine_info(expr.info, rparen_info)
            return parse_call_tail(ECall(call_info, expr, args), rest)
        case _:
            return expr, tokens


def parse_args(tokens):
    """Parses comma-separated call arguments up to and including ')'.
    [Token] -> ([Expr], Info, [Token])"""
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
    """Parses comma-separated list elements up to and including ']'.
    [Token] -> ([Expr], Info, [Token])"""
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


def parse_comp_clauses(tokens):
    """Parses a list comprehension's for/if clauses up to and including
    ']'. [Token] -> ([CompClause], Info, [Token])"""
    clauses = []
    rest = tokens
    while True:
        match rest:
            case [TokFor(info), *rest2]:
                pattern, rest2 = parse_pattern(rest2)
                _check_no_duplicate_captures(pattern)
                match rest2:
                    case [TokIn(_), *rest2]:
                        seq, rest2 = parse_expr(rest2)
                        clauses.append(CompFor(combine_info(info, seq.info), pattern, seq))
                        rest = rest2
                    case _:
                        raise ParseError(
                            _here(rest2), "expected 'in' after comprehension pattern"
                        )
            case [TokIf(info), *rest2]:
                cond, rest2 = parse_expr(rest2)
                clauses.append(CompIf(combine_info(info, cond.info), cond))
                rest = rest2
            case [TokRBracket(info), *rest2]:
                return clauses, info, rest2
            case _:
                raise ParseError(
                    _here(rest), "expected 'for', 'if', or ']' in list comprehension"
                )


def parse_unary(tokens):
    """Parses unary minus (`-expr`) or falls through to an atom.
    [Token] -> (Expr, [Token])"""
    match tokens:
        case [TokSub(info), *rest]:
            operand, rest = parse_unary(rest)
            return ENeg(combine_info(info, operand.info), operand), rest
        case _:
            return parse_atom(tokens)


def parse_multiplicative(tokens):
    """Parses `*`/`/`, left-associative. [Token] -> (Expr, [Token])"""
    left, rest = parse_unary(tokens)
    while True:
        match rest:
            case [TokMul(_), *rest2]:
                right, rest2 = parse_unary(rest2)
                left, rest = EMul(combine_info(left.info, right.info), left, right), rest2
            case [TokDiv(_), *rest2]:
                right, rest2 = parse_unary(rest2)
                left, rest = EDiv(combine_info(left.info, right.info), left, right), rest2
            case _:
                return left, rest


def parse_additive(tokens):
    """Parses `+`/`-`, left-associative. [Token] -> (Expr, [Token])"""
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
    """Parses the lowest-precedence expression level: an if expression
    or a comparison. [Token] -> (Expr, [Token])"""
    match tokens:
        case [TokIf(info), *rest]:
            cond, rest = parse_expr(rest)
            return parse_if_expr_tail(info, cond, rest)
        case _:
            return parse_comparison(tokens)


def parse_if_expr_tail(if_info, cond, tokens):
    """Parses the `then expr else expr` tail of an if expression (see
    PYKING.md, "if/then/else expressions"), given the already-parsed
    `if` and condition.
    Info -> Expr -> [Token] -> (EIf, [Token])"""
    match tokens:
        case [TokThen(_), *rest]:
            then_expr, rest = parse_expr(rest)
            match rest:
                case [TokElse(_), *rest]:
                    else_expr, rest = parse_expr(rest)
                    if_expr = EIf(
                        combine_info(if_info, else_expr.info), cond, then_expr, else_expr
                    )
                    return if_expr, rest
                case _:
                    raise ParseError(_here(rest), "expected 'else' in if expression")
        case _:
            raise ParseError(_here(tokens), "expected 'then' in if expression")


def parse_if_stmt_tail(if_info, cond, tokens):
    """Parses the block and optional else/else-if tail of an if
    statement (see PYKING.md, "else if instead of elif"), given the
    already-parsed `if` and condition; tokens starts just after ':'.
    Info -> Expr -> [Token] -> (SIf, [Token])"""
    then_body, rest = parse_block(tokens)
    match rest:
        case [TokElse(_), TokIf(elif_info), *rest]:
            elif_cond, rest = parse_expr(rest)
            match rest:
                case [TokColon(_), *rest]:
                    nested, rest = parse_if_stmt_tail(elif_info, elif_cond, rest)
                    if_info = combine_info(if_info, nested.info)
                    return SIf(if_info, cond, then_body, [nested]), rest
                case _:
                    raise ParseError(
                        _here(rest), "expected ':' after 'else if' condition"
                    )
        case [TokElse(_), TokColon(_), *rest]:
            else_body, rest = parse_block(rest)
            if_info = combine_info(if_info, _block_end_info(if_info, else_body))
            return SIf(if_info, cond, then_body, else_body), rest
        case [TokElse(else_info), *_]:
            raise ParseError(else_info, "expected ':' or 'if' after 'else'")
        case _:
            if_info = combine_info(if_info, _block_end_info(if_info, then_body))
            return SIf(if_info, cond, then_body, None), rest


def parse_comparison(tokens):
    """Parses a comparison operator; comparisons do not chain.
    [Token] -> (Expr, [Token])"""
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


def parse_tuple_or_expr(tokens):
    """Parses one expression, or a bare (unparenthesized) tuple
    `expr, expr, ...`. [Token] -> (Expr, [Token])"""
    first, rest = parse_expr(tokens)
    return parse_tuple_tail(first, rest)


def parse_tuple_tail(first, tokens):
    """Continues a bare tuple from an already-parsed first element if
    the next token is a comma, otherwise returns first unchanged.
    Expr -> [Token] -> (Expr, [Token])"""
    match tokens:
        case [TokComma(_), *rest]:
            elements = [first]
            while True:
                elem, rest = parse_expr(rest)
                elements.append(elem)
                match rest:
                    case [TokComma(_), *rest2]:
                        rest = rest2
                    case _:
                        break
            tuple_info = combine_info(first.info, elements[-1].info)
            return ETuple(tuple_info, elements), rest
        case _:
            return first, tokens


def parse_type(tokens):
    """Parses a type, including `|` alternatives (Int | String); `|`
    binds looser than everything else a type is built from.
    [Token] -> (Type, [Token])"""
    first, rest = parse_type_atom(tokens)
    alternatives = [first]
    while True:
        match rest:
            case [TokPipe(_), *after]:
                alternative, rest = parse_type_atom(after)
                alternatives.append(alternative)
            case _:
                break
    if len(alternatives) == 1:
        return first, rest
    return (TOr(combine_info(first.info, alternatives[-1].info), alternatives),
            rest)


def parse_type_atom(tokens):
    """Parses one type with no `|` in it (a function type included,
    since `->` binds tighter than `|`). [Token] -> (Type, [Token])"""
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
            # One parenthesized list, two types: it is a function's
            # parameter list when `->` follows and a tuple otherwise --
            # `(Int, Bool)` against `(Int, Bool) -> Int`. Deciding it on
            # the token after `)` is what keeps a *parameter* that is
            # itself a tuple writable, as `((Int, Bool)) -> Int`: the
            # inner pair is read as a tuple because no arrow follows it,
            # and the outer as a parameter list because one does.
            elements, rp_info, rest = parse_type_elements(rest)
            match rest:
                case [TokArrow(_), *after_arrow]:
                    # The result is a whole type in its turn, so a
                    # function returning a function needs no parentheses
                    # and `->` groups to the right:
                    # `(Int) -> (Int) -> Int`.
                    result, rest = parse_type(after_arrow)
                    return (TFunction(combine_info(lp_info, result.info),
                                      elements, result),
                            rest)
                case _:
                    return TTuple(combine_info(lp_info, rp_info), elements), rest
        case [t, *_]:
            raise ParseError(t.info, "expected a type")
        case []:
            raise ParseError(_here(tokens), "unexpected end of input in type")


def parse_type_elements(tokens):
    """Parses comma-separated types up to and including ')'.
    [Token] -> ([Type], Info, [Token])"""
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
    """Parses one parameter, `name` or `name:type`. [Token] -> (Param, [Token])"""
    match tokens:
        case [TokIdent(info, name), TokColon(_), *rest]:
            type_, rest = parse_type(rest)
            return Param(combine_info(info, type_.info), name, type_), rest
        case [TokIdent(info, name), *rest]:
            return Param(info, name, None), rest
        case _:
            raise ParseError(_here(tokens), "expected a parameter")


def parse_params(tokens):
    """Parses comma-separated parameters up to and including ')'.
    [Token] -> ([Param], [Token])"""
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


def parse_target_atom(tokens):
    """Parses one assignment target: a name, or a parenthesized
    tuple-target group. [Token] -> (AssignTarget, [Token])"""
    match tokens:
        case [TokIdent(info, name), *rest]:
            return TargetName(info, name), rest
        case [TokLParen(lp_info), TokRParen(rp_info), *rest]:
            return TargetTuple(combine_info(lp_info, rp_info), []), rest
        case [TokLParen(lp_info), *rest]:
            first, rest = parse_target_atom(rest)
            match rest:
                case [TokComma(_), TokRParen(rp_info), *rest]:
                    tuple_info = combine_info(lp_info, rp_info)
                    return TargetTuple(tuple_info, [first]), rest
                case [TokComma(_), *rest]:
                    elements, rp_info, rest = parse_target_paren_tail(rest)
                    tuple_info = combine_info(lp_info, rp_info)
                    return TargetTuple(tuple_info, [first] + elements), rest
                case [TokRParen(rp_info), *rest]:
                    return replace(first, info=combine_info(lp_info, rp_info)), rest
                case _:
                    raise ParseError(_here(rest), "expected ',' or ')' in assignment target")
        case [t, *_]:
            raise ParseError(t.info, "expected an identifier or '(' in assignment target")
        case []:
            raise ParseError(_here(tokens), "unexpected end of input in assignment target")


def parse_target_paren_tail(tokens):
    """Parses comma-separated targets up to and including ')'.
    [Token] -> ([AssignTarget], Info, [Token])"""
    match tokens:
        case [TokRParen(info), *rest]:
            return [], info, rest
        case _:
            elem, rest = parse_target_atom(tokens)
            match rest:
                case [TokComma(_), *rest]:
                    elems, rp_info, rest = parse_target_paren_tail(rest)
                    return [elem] + elems, rp_info, rest
                case [TokRParen(info), *rest]:
                    return [elem], info, rest
                case _:
                    raise ParseError(_here(rest), "expected ',' or ')' in assignment target")


def parse_target(tokens):
    """Parses an assignment target: one parse_target_atom, or a bare
    comma-separated sequence of them. [Token] -> (AssignTarget, [Token])"""
    first, rest = parse_target_atom(tokens)
    match rest:
        case [TokComma(_), *rest]:
            elements = [first]
            while True:
                elem, rest = parse_target_atom(rest)
                elements.append(elem)
                match rest:
                    case [TokComma(_), *rest2]:
                        rest = rest2
                    case _:
                        break
            tuple_info = combine_info(first.info, elements[-1].info)
            return TargetTuple(tuple_info, elements), rest
        case _:
            return first, rest


def _try_parse_assignment_target(tokens):
    """Speculatively parses tokens as `target [: type] =`. Returns None,
    positioned just after '=' on success, if tokens does not begin with
    one. [Token] -> (AssignTarget, Type?, [Token])?"""
    try:
        target, rest = parse_target(tokens)
    except ParseError:
        return None
    annotation = None
    match rest:
        case [TokColon(_), *after_colon]:
            # Committed: a target followed by ':' can only be an
            # annotated assignment, so a bad type here is reported as
            # itself rather than swallowed into a `None` that would send
            # the caller off to reparse this as an expression and
            # complain about the colon instead.
            annotation, rest = parse_type(after_colon)
    match rest:
        case [TokEq(_), *rest]:
            return target, annotation, rest
        case _:
            return None


# How much of a construct an error message quotes before it gives up and
# says "...". Long enough for the whole of a short statement -- which is
# what the message is usually about -- and short enough that two of them
# and a sentence still fit on a line.
_QUOTE_LIMIT = 32


def _check_own_line(previous, current, what, describe):
    """Raises ParseError if current begins on the same source line
    previous ended on (see PYKING.md, "a statement starts a line of its
    own"). a -> a -> String -> (a -> String) -> ()"""
    if current.info.row1 > previous.info.row2:
        return
    raise ParseError(
        current.info,
        f"each {what} must start on a new line. In this case, "
        f"'{describe(previous)}' and '{describe(current)}' are seen as two "
        f"different {what}s",
    )


def _statement_text(stmt):
    """A statement's own syntax, shortened for an error message.
    Stmt -> String"""
    return _shorten(pprint_stmt(stmt))


def _case_text(clause):
    """A case clause's pattern, shortened for an error message.
    MatchCase -> String"""
    return _shorten(f"case {pprint_pattern(clause.pattern)}")


def _shorten(text):
    """Truncates text to one line, short enough to quote in a sentence.
    String -> String"""
    first = text.split("\n")[0].strip()
    if len(first) <= _QUOTE_LIMIT:
        return first
    return first[: _QUOTE_LIMIT - 3] + "..."


def parse_block(tokens):
    """Parses one indented block, TokIndent to matching TokDedent.
    [Token] -> ([Stmt], [Token])"""
    match tokens:
        case [TokIndent(_), *rest]:
            stmts = []
            while True:
                match rest:
                    case [TokDedent(_), *rest]:
                        return stmts, rest
                    case _:
                        stmt, rest = parse_statement(rest)
                        if stmts:
                            _check_own_line(
                                stmts[-1], stmt, "statement", _statement_text
                            )
                        stmts.append(stmt)
        case _:
            raise ParseError(_here(tokens), "expected an indented block")


def _block_end_info(header_info, body):
    """The Info ending a header+block construct: the last statement's,
    or the header's own if the block is empty.
    Info -> [Stmt] -> Info"""
    return body[-1].info if body else header_info


def parse_pattern_atom(tokens):
    """Parses one pattern: literal, wildcard, name, or parenthesized
    tuple pattern. [Token] -> (Pattern, [Token])"""
    match tokens:
        case [TokSub(info), TokInt(int_info, v), *rest]:
            # A negative integer *literal* pattern (`case -1:`). Only a
            # literal: a pattern is matched, never evaluated, so there is
            # no expression here for a general unary minus to apply to.
            return PInt(combine_info(info, int_info), -v), rest
        case [TokInt(info, v), *rest]:
            return PInt(info, v), rest
        case [TokString(info, s), *rest]:
            return PString(info, s), rest
        case [TokTrue(info), *rest]:
            return PBool(info, True), rest
        case [TokFalse(info), *rest]:
            return PBool(info, False), rest
        case [TokIdent(info, "_"), *rest]:
            return PWildcard(info), rest
        case [TokIdent(info, name), *rest]:
            return PCapture(info, name), rest
        case [TokLParen(lp_info), TokRParen(rp_info), *rest]:
            return PTuple(combine_info(lp_info, rp_info), []), rest
        case [TokLParen(lp_info), *rest]:
            first, rest = parse_pattern_atom(rest)
            match rest:
                case [TokComma(_), TokRParen(rp_info), *rest]:
                    return PTuple(combine_info(lp_info, rp_info), [first]), rest
                case [TokComma(_), *rest]:
                    elements, rp_info, rest = parse_pattern_paren_tail(rest)
                    return PTuple(combine_info(lp_info, rp_info), [first] + elements), rest
                case [TokRParen(rp_info), *rest]:
                    return replace(first, info=combine_info(lp_info, rp_info)), rest
                case _:
                    raise ParseError(_here(rest), "expected ',' or ')' in tuple pattern")
        case [TokLBracket(lb_info), TokRBracket(rb_info), *rest]:
            return PList(combine_info(lb_info, rb_info), [], None, []), rest
        case [TokLBracket(lb_info), *rest]:
            items, rb_info, rest = parse_list_pattern_items(rest)
            prefix = []
            list_rest = None
            suffix = []
            for item in items:
                if isinstance(item, ListRest):
                    if list_rest is not None:
                        raise ParseError(
                            item.info, "a list pattern can have at most one '..' rest"
                        )
                    list_rest = item
                elif list_rest is None:
                    prefix.append(item)
                else:
                    suffix.append(item)
            return PList(combine_info(lb_info, rb_info), prefix, list_rest, suffix), rest
        case _:
            raise ParseError(
                _here(tokens),
                "expected a pattern (integer, string, '_', identifier, tuple, or list)",
            )


def parse_list_pattern_items(tokens):
    """Parses comma-separated list-pattern items up to ']' (each a
    pattern, or a `..`/`..name` rest marker), in source order.
    [Token] -> ([Pattern | ListRest], Info, [Token])"""
    match tokens:
        case [TokRBracket(info), *rest]:
            return [], info, rest
        case _:
            item, rest = parse_list_pattern_item(tokens)
            match rest:
                case [TokComma(_), *rest]:
                    items, rb_info, rest = parse_list_pattern_items(rest)
                    return [item] + items, rb_info, rest
                case [TokRBracket(info), *rest]:
                    return [item], info, rest
                case _:
                    raise ParseError(_here(rest), "expected ',' or ']' in list pattern")


def parse_list_pattern_item(tokens):
    match tokens:
        case [TokDotDot(info), TokIdent(name_info, name), *rest]:
            return ListRest(combine_info(info, name_info), name), rest
        case [TokDotDot(info), *rest]:
            return ListRest(info, None), rest
        case _:
            return parse_pattern_atom(tokens)


def parse_pattern_paren_tail(tokens):
    match tokens:
        case [TokRParen(info), *rest]:
            return [], info, rest
        case _:
            elem, rest = parse_pattern_atom(tokens)
            match rest:
                case [TokComma(_), *rest]:
                    elems, rp_info, rest = parse_pattern_paren_tail(rest)
                    return [elem] + elems, rp_info, rest
                case [TokRParen(info), *rest]:
                    return [elem], info, rest
                case _:
                    raise ParseError(_here(rest), "expected ',' or ')' in tuple pattern")


def parse_pattern(tokens):
    """Parses a pattern: one parse_pattern_atom, or a bare
    comma-separated sequence of them. [Token] -> (Pattern, [Token])"""
    first, rest = parse_pattern_atom(tokens)
    match rest:
        case [TokComma(_), *rest]:
            elements = [first]
            while True:
                elem, rest = parse_pattern_atom(rest)
                elements.append(elem)
                match rest:
                    case [TokComma(_), *rest2]:
                        rest = rest2
                    case _:
                        break
            pattern_info = combine_info(first.info, elements[-1].info)
            return PTuple(pattern_info, elements), rest
        case _:
            return first, rest


def _pattern_captures(pattern):
    """Every name pattern binds, as (name, info) pairs.
    Pattern -> [(String, Info)]"""
    match pattern:
        case PCapture(info, name):
            return [(name, info)]
        case PTuple(_, elements):
            return [c for e in elements for c in _pattern_captures(e)]
        case PList(_, prefix, rest, suffix):
            caps = [c for e in prefix for c in _pattern_captures(e)]
            if rest is not None and rest.name is not None:
                caps.append((rest.name, rest.info))
            caps += [c for e in (suffix or []) for c in _pattern_captures(e)]
            return caps
        case _:
            return []


def _check_no_duplicate_captures(pattern):
    """Raises ParseError if pattern binds the same name more than once.
    Pattern -> ()"""
    seen = set()
    for name, info in _pattern_captures(pattern):
        if name in seen:
            raise ParseError(info, f"duplicate binding '{name}' in pattern")
        seen.add(name)


def parse_case(tokens):
    """Parses one case clause: `case pattern:` block, or
    `case pattern -> expr`. [Token] -> (MatchCase, [Token])"""
    match tokens:
        case [TokCase(info), *rest]:
            pattern, rest = parse_pattern(rest)
            _check_no_duplicate_captures(pattern)
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
    """Parses an indented block of one or more case clauses.
    [Token] -> ([MatchCase], [Token])"""
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
                        if cases:
                            _check_own_line(
                                cases[-1], case_clause, "'case' clause", _case_text
                            )
                        cases.append(case_clause)
        case _:
            raise ParseError(_here(tokens), "expected an indented block of 'case' clauses")


def parse_match_stmt(match_info, tokens):
    """Parses a match statement, from just after the `match` keyword.
    Info -> [Token] -> (SMatch, [Token])"""
    subject, rest = parse_expr(tokens)
    match rest:
        case [TokColon(_), *rest]:
            cases, rest = parse_cases(rest)
            match_info = combine_info(match_info, cases[-1].info)
            return SMatch(match_info, subject, cases), rest
        case _:
            raise ParseError(_here(rest), "expected ':' after match header")


# --- value-form if/match (`x = if c:` / `x = match e:`) -- see
# PYKING.md, "if/match statements as bound values" ---

def _check_value_stmt(stmt):
    """Raises ParseError unless stmt (an if/match in value form) yields
    a value on every path. Stmt -> ()"""
    match stmt:
        case SIf(info, _, then_body, else_body):
            if else_body is None:
                raise ParseError(
                    info, "a value-form 'if' must have an 'else' branch"
                )
            _check_value_block(then_body, info)
            _check_value_block(else_body, info)
        case SMatch(_, _, cases):
            for case_clause in cases:
                # `case pattern -> expr` is an expression by construction;
                # only the block form can end in the wrong thing.
                if case_clause.expr is None:
                    _check_value_block(case_clause.body, case_clause.info)


def _check_value_block(stmts, info):
    """Raises ParseError unless stmts ends in an expression statement or
    a nested if/match that recursively does.
    [Stmt] -> Info -> ()"""
    match stmts:
        case [*_, SExprStmt()]:
            return
        case [*_, (SIf() | SMatch()) as nested]:
            _check_value_stmt(nested)
        case [*_, last]:
            raise ParseError(
                last.info,
                "every branch of a value-form 'if'/'match' must end in an expression",
            )
        case _:
            raise ParseError(
                info,
                "every branch of a value-form 'if'/'match' must end in an expression",
            )


def parse_bound_value(tokens):
    """Parses the right-hand side of a binding's '=': an expression, or
    an if/match statement in value form (an SIf/SMatch; callers tell
    the two apart by type). May be indented onto the next line.
    [Token] -> (Expr | Stmt, [Token])"""
    match tokens:
        case [TokIndent(_), *rest]:
            value, rest = parse_bound_value(rest)
            match rest:
                case [TokDedent(_), *rest]:
                    return value, rest
                case _:
                    raise ParseError(
                        _here(rest),
                        "expected a single value in the indented block after '='",
                    )
        case [TokMatch(info), *rest]:
            stmt, rest = parse_match_stmt(info, rest)
            _check_value_stmt(stmt)
            return stmt, rest
        case [TokIf(info), *rest]:
            cond, rest = parse_expr(rest)
            match rest:
                case [TokColon(_), *rest]:
                    stmt, rest = parse_if_stmt_tail(info, cond, rest)
                    _check_value_stmt(stmt)
                    return stmt, rest
                case [TokThen(_), *_]:
                    expr, rest = parse_if_expr_tail(info, cond, rest)
                    return parse_tuple_tail(expr, rest)
                case _:
                    raise ParseError(
                        _here(rest), "expected ':' or 'then' after if condition"
                    )
        case _:
            return parse_tuple_or_expr(tokens)


def _expect_expr_value(value, what):
    """Raises ParseError if value is a value-form if/match, naming what
    (the position that requires a plain expression). Otherwise returns
    value. (Expr | Stmt) -> String -> Expr"""
    match value:
        case Stmt():
            raise ParseError(
                value.info,
                f"{what} takes an expression; a value-form 'if'/'match' "
                "can only be bound with '=' or returned with 'return'",
            )
        case _:
            return value


def parse_statement(tokens):
    """Parses one statement. [Token] -> (Stmt, [Token])"""
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
                case [TokEq(_), *rest]:
                    # Pyking extension: `def name(...) = expr` is a
                    # single-expression function body, not valid Python
                    # syntax -- mirrors `case pattern -> expr`. Parsed
                    # with `parse_bound_value` so the body may sit on the
                    # next line, indented, exactly as a bound value may;
                    # a value-form if/match is not a body, though (that
                    # would have to `return` from each branch tail, not
                    # bind), so it is rejected here.
                    expr, rest = parse_bound_value(rest)
                    expr = _expect_expr_value(expr, "a 'def ... =' body")
                    def_info = combine_info(info, expr.info)
                    return SFunctionDef(def_info, name, params, None, return_type, expr), rest
                case _:
                    raise ParseError(_here(rest), "expected ':' or '=' after def header")

        case [TokReturn(info), *rest]:
            # `return` takes a `bound_value`, not just an expression: the
            # value-form `if`/`match` is allowed here as well as after
            # `=`, so `return if c:` propagates each branch's tail
            # expression into the return (see `SReturnStmt` in syntax.py).
            # `parse_bound_value` has already applied `_check_value_stmt`
            # to the statement form, so the mandatory `else` and the
            # every-branch-ends-in-a-value rules hold here too.
            value, rest = parse_bound_value(rest)
            return_info = combine_info(info, value.info)
            match value:
                case Stmt():
                    return SReturnStmt(return_info, value), rest
                case _:
                    return SReturn(return_info, value), rest

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
            return parse_match_stmt(info, rest)

        # A statement starting with `if` is either an if *statement*
        # (`if cond: block`) or an if *expression* used as an expression
        # statement (`if cond then a else b`). The two share the whole
        # `"if" , expr` prefix, and that `expr` can be arbitrarily long, so
        # no bounded lookahead tells them apart -- the grammar is not LL(1)
        # at this point. Rather than backtrack, parse the shared prefix once
        # and then dispatch on the single token that follows it: ':' for the
        # statement, 'then' for the expression. Note `parse_expr` already
        # handles a *condition* that is itself an if expression, so
        # `if (if a then b else c):` needs no special casing here.
        case [TokIf(info), *rest]:
            cond, rest = parse_expr(rest)
            match rest:
                case [TokColon(_), *rest]:
                    return parse_if_stmt_tail(info, cond, rest)
                case [TokThen(_), *_]:
                    expr, rest = parse_if_expr_tail(info, cond, rest)
                    expr, rest = parse_tuple_tail(expr, rest)
                    return SExprStmt(expr.info, expr), rest
                case _:
                    raise ParseError(
                        _here(rest), "expected ':' or 'then' after if condition"
                    )

        case [TokVar(info), TokIdent(_, name), TokEq(_), *rest]:
            expr, rest = parse_bound_value(rest)
            expr = _expect_expr_value(expr, "a 'var' declaration")
            return SVar(combine_info(info, expr.info), name, expr), rest

        case [TokIdent(info, name), TokAssign(_), *rest]:
            expr, rest = parse_bound_value(rest)
            expr = _expect_expr_value(expr, "a ':=' mutation")
            return SMutate(combine_info(info, expr.info), name, expr), rest

        # `target = expr`, where `target` may destructure a tuple (e.g.
        # `a, b = 1, 2` or `(a, b) = pair`) -- tried speculatively since,
        # unlike the fixed-prefix cases above, a target can be an
        # arbitrarily long comma-separated/nested prefix of tokens; if it
        # doesn't pan out (no valid target, or no '=' after it), this
        # falls through to the plain expression-statement case below.
        case [TokIdent() | TokLParen(), *_] if (
            _assign := _try_parse_assignment_target(tokens)
        ) is not None:
            target, annotation, rest = _assign
            value, rest = parse_bound_value(rest)
            let_info = combine_info(target.info, value.info)
            match value:
                case Stmt():
                    return SLetStmt(let_info, target, value, annotation), rest
                case _:
                    return SLet(let_info, target, value, annotation), rest

        case _:
            expr, rest = parse_tuple_or_expr(tokens)
            return SExprStmt(expr.info, expr), rest


def parse(tokens):
    """Parses a full token stream into a list of top-level statements.
    [Token] -> [Stmt]"""
    global _eof_info
    _eof_info = tokens[-1].info if tokens else Info("<empty>", 1, 0, 1, 0)
    stmts = []
    rest = tokens
    while rest:
        stmt, rest = parse_statement(rest)
        if stmts:
            _check_own_line(stmts[-1], stmt, "statement", _statement_text)
        stmts.append(stmt)
    return stmts
