from dataclasses import replace

from lexer import (
    Info,
    TokInt, TokString, TokIdent,
    TokAdd, TokSub, TokMul, TokDiv,
    TokLessThanEq, TokLessThan, TokGreatThanEq, TokGreatThan, TokEqEq,
    TokColon, TokIndent, TokDedent, TokEq, TokLParen, TokRParen, TokComma,
    TokLBracket, TokRBracket, TokDotDot,
    TokDef, TokReturn, TokFor, TokIn, TokIf, TokWhile, TokThen, TokElse, TokVar,
    TokAssign, TokMatch, TokCase, TokArrow,
    TokTypeInt, TokTypeString, TokTypeBool,
)
from syntax import (
    EInt, EString, EVar,
    EAdd, ESub, EMul, EDiv,
    ELessThan, ELessThanEq, EGreatThan, EGreatThanEq, EEq, ECall, EList, ETuple,
    EIf, EListComp, CompFor, CompIf,
    PInt, PString, PWildcard, PCapture, PTuple, PList, ListRest, MatchCase,
    Stmt,
    SLet, SLetStmt, SVar, SMutate, SReturn, SExprStmt, SFor, SWhile, SIf,
    SFunctionDef, SMatch,
    TInt, TString, TBool, TList, TTuple, Param,
    TargetName, TargetTuple,
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
    match tokens:
        # The `row1 ==` guard restricts call-chaining (`f(1)(2)`) to a '('
        # on the same source row as where `expr` ended. Without it, this
        # would also (wrongly) chain onto a '(' that starts the *next*
        # statement -- there are no statement-separator tokens in this
        # grammar (see the module comment above), so e.g. `print(x)`
        # followed on the next line by a parenthesized tuple statement
        # like `(a, b) = ...` would otherwise be misparsed as one giant
        # call `print(x)(a, b)`.
        case [TokLParen(lp_info), *rest] if lp_info.row1 == expr.info.row2:
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


def parse_comp_clauses(tokens):
    """Parses a list comprehension's clauses -- at least one `for`,
    followed by any mix of further `for`/`if` clauses (the caller has
    already peeked that `tokens` starts with `for`) -- up to and
    including the closing ']'."""
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
    """The lowest-precedence expression level: either an if expression
    (`if e then e else e` -- Pyking extension, see PYKING.md) or a
    comparison. Which one it is shows in the very first token, so this
    stays LL(1); it's only at *statement* level that `if` is ambiguous
    (see the `TokIf` case in `parse_statement`)."""
    match tokens:
        case [TokIf(info), *rest]:
            # The condition is a full `expr`, so a nested if expression may
            # appear here unparenthesized (`if if a then b else c then ...`).
            cond, rest = parse_expr(rest)
            return parse_if_expr_tail(info, cond, rest)
        case _:
            return parse_comparison(tokens)


def parse_if_expr_tail(if_info, cond, tokens):
    """Parses the `then expr else expr` tail of an if expression, given the
    already-parsed `if` token info and condition. Split out from
    `parse_expr` because `parse_statement` reaches this same point by a
    different route: it has to consume `if` and the condition itself before
    it can tell an if statement from an if expression.

    Both branches are `expr`, not `tuple_or_expr`, so a comma ends the if
    expression rather than being swallowed by it -- `if a then b else c, d`
    is a 2-tuple whose first element is the if expression, matching how
    Python reads `b if a else c, d`. The `else` branch recurses through
    `parse_expr`, making the construct right-associative, so a chained
    `else if ...` reads (and parses) like an `elif` ladder. Unlike the if
    *statement*, `else` is mandatory: that is what keeps `if a then if b
    then c else d else e` unambiguous, since each `else` then has exactly
    one possible owner -- the classic dangling-else problem comes from the
    `else` being *optional*, which is true of Pyking's if statement but
    deliberately not of its if expression."""
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
    """Parses the block and optional `else` tail of an if statement, given
    the already-parsed `if` token info and condition; `tokens` starts just
    after the header's ':'. The mirror image of `parse_if_expr_tail` --
    `parse_statement` reaches one or the other only after consuming the
    `"if" , expr` prefix the statement and the expression share.

    `else if` (two keywords -- Pyking has no `elif`) recurses here and
    becomes a nested `SIf` that is the outer statement's entire else
    body: exactly the AST an explicit `else:` block containing a single
    if statement produces, so a ladder needs no AST node of its own. The
    nested header must be the *statement* form, i.e. end in ':' -- an if
    expression is not allowed to start an `else` tail, which is what
    keeps `else if` unambiguous."""
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
    """Parses either a single `expr`, or a *bare* (unparenthesized) tuple:
    `expr , expr , ...` -- Pyking's Python-like implicit-tuple
    construction. Deliberately requires at least two elements and forbids
    a trailing comma: since this grammar has no statement-separator
    tokens (see the module comment above), a trailing comma here would be
    indistinguishable from the start of the following statement -- a
    singleton tuple must be written with explicit parens, `(e,)`."""
    first, rest = parse_expr(tokens)
    return parse_tuple_tail(first, rest)


def parse_tuple_tail(first, tokens):
    """Given an already-parsed first `expr`, continues a bare tuple if the
    next token is a comma, otherwise returns `first` unchanged. Split out of
    `parse_tuple_or_expr` so `parse_statement` can reuse it after having
    parsed the first element by a different route (see its `TokIf` case)."""
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


def parse_target_atom(tokens):
    """A single assignment target: a name, or a fully parenthesized
    tuple-target group (0, 1 [singleton, trailing comma required], or 2+
    comma-separated targets, trailing comma optional for 2+ -- same
    shape as a parenthesized tuple expression)."""
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
    """The full assignment-target grammar: a single `parse_target_atom`,
    or a *bare* (unparenthesized) comma-separated sequence of 2+ of them
    -- like bare tuple expressions, deliberately with no trailing comma
    (see `parse_tuple_or_expr`)."""
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
    """Speculatively parses `tokens` as `target =`, returning `(target,
    rest)` positioned just after the '=' on success, or `None` if
    `tokens` doesn't begin with a valid `target =` -- callers fall back
    to parsing `tokens` as a general statement/expression instead. Since
    this parser is purely functional over immutable token lists, a
    failed speculative parse has no side effects to undo."""
    try:
        target, rest = parse_target(tokens)
    except ParseError:
        return None
    match rest:
        case [TokEq(_), *rest]:
            return target, rest
        case _:
            return None


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


def parse_pattern_atom(tokens):
    """A single pattern: int/string/'_'/identifier, or a fully
    parenthesized tuple pattern (0, 1 [singleton, trailing comma
    required], or 2+ comma-separated patterns, trailing comma optional
    for 2+ -- same shape as a parenthesized tuple expression)."""
    match tokens:
        case [TokInt(info, v), *rest]:
            return PInt(info, v), rest
        case [TokString(info, s), *rest]:
            return PString(info, s), rest
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
    """Parses comma-separated list-pattern items up to ']', where each
    item is either a `..`/`..name` rest marker or an ordinary pattern.
    Returns `(items, rbracket_info, rest)`; `items` is `Pattern | ListRest`
    values in source order (the caller enforces "at most one `ListRest`")."""
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
    """Top-level pattern grammar: `parse_pattern_atom`, or a *bare*
    (unparenthesized) comma-separated sequence of 2+ of them -- like bare
    tuple expressions, deliberately with no trailing comma."""
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
    """Collects every name `pattern` would bind, as `(name, info)` pairs,
    by walking its sub-patterns (tuple/list patterns nest arbitrarily)."""
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
    """Raises ParseError if `pattern` binds the same name more than once
    -- mirroring Python's own restriction on repeated names within a
    single `match` pattern, since both plain `match`/`case` and the list
    comprehension desugaring in `target_python.py` compile a Pyking
    pattern down to a real Python `case` pattern."""
    seen = set()
    for name, info in _pattern_captures(pattern):
        if name in seen:
            raise ParseError(info, f"duplicate binding '{name}' in pattern")
        seen.add(name)


def parse_case(tokens):
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


def parse_match_stmt(match_info, tokens):
    """Parses a match statement from just after its `match` keyword."""
    subject, rest = parse_expr(tokens)
    match rest:
        case [TokColon(_), *rest]:
            cases, rest = parse_cases(rest)
            match_info = combine_info(match_info, cases[-1].info)
            return SMatch(match_info, subject, cases), rest
        case _:
            raise ParseError(_here(rest), "expected ':' after match header")


# --- value-form if/match (`x = if c:` / `x = match e:`) ---
#
# These stay ordinary if/match *statements*; binding one with '=' just
# additionally requires that it yield a value on every path, which the
# two checks below enforce -- neither restriction is expressible in the
# grammar itself, so they're checked here rather than falling out of the
# parse. `target_python.py` relies on both holding.

def _check_value_stmt(stmt):
    """Checks that `stmt` -- the if/match statement on the right-hand side
    of a binding -- yields a value whichever way it branches: an `if` must
    have its `else` (there is no value to bind if the condition fails), and
    every branch must end in a value (see `_check_value_block`). A `match`
    needs no such existence check: `parse_cases` already requires at least
    one case, and an unmatched subject is a runtime error, not a branch
    that silently falls through."""
    match stmt:
        case SIf(info, _, then_body, else_body):
            if else_body is None:
                raise ParseError(info, "an 'if' bound with '=' must have an 'else' branch")
            _check_value_block(then_body, info)
            _check_value_block(else_body, info)
        case SMatch(_, _, cases):
            for case_clause in cases:
                # `case pattern -> expr` is an expression by construction;
                # only the block form can end in the wrong thing.
                if case_clause.expr is None:
                    _check_value_block(case_clause.body, case_clause.info)


def _check_value_block(stmts, info):
    """Checks that one branch of a value-form if/match ends in something
    that yields a value: an expression statement, or a nested if/match
    that recursively does the same -- which is also what makes an
    `else if` ladder work in value form, since the ladder *is* a nested
    if statement as the else branch's only statement (see
    `parse_if_stmt_tail`). Every statement before the last is an ordinary
    statement, run for its effect."""
    match stmts:
        case [*_, SExprStmt()]:
            return
        case [*_, (SIf() | SMatch()) as nested]:
            _check_value_stmt(nested)
        case [*_, last]:
            raise ParseError(last.info, "a branch bound with '=' must end in an expression")
        case _:
            raise ParseError(info, "a branch bound with '=' must end in an expression")


def parse_bound_value(tokens):
    """Parses the right-hand side of a binding's '=': either an ordinary
    `tuple_or_expr`, or -- Pyking extension -- an `if`/`match` statement
    in *value form*. Returns `(node, rest)`, where the node is an `Expr`
    for the ordinary case and the `SIf`/`SMatch` itself for the value
    form; callers tell them apart by type (`Stmt` vs. `Expr`).

    A `match` on the right of '=' is unambiguously the value form --
    `match` is a reserved keyword, so it can never start an expression.
    An `if` is the same standoff `parse_statement` faces between an if
    statement and an if expression, resolved the same way: parse the
    shared `"if" , expr` prefix once, then dispatch on ':' (value form)
    versus 'then' (an ordinary if expression)."""
    match tokens:
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


def _expect_expr_value(value):
    """Rejects a value-form if/match where only an expression is allowed.
    The value form binds by assigning in each branch's tail, which is
    exactly what an *immutable* binding does and what `var`/`:=` do not
    -- see PYKING.md."""
    match value:
        case Stmt():
            raise ParseError(
                value.info,
                "a value-form 'if'/'match' can only be bound with '=', not 'var' or ':='",
            )
        case _:
            return value


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
                case [TokEq(_), *rest]:
                    # Pyking extension: `def name(...) = expr` is a
                    # single-expression function body, not valid Python
                    # syntax -- mirrors `case pattern -> expr`.
                    expr, rest = parse_tuple_or_expr(rest)
                    def_info = combine_info(info, expr.info)
                    return SFunctionDef(def_info, name, params, None, return_type, expr), rest
                case _:
                    raise ParseError(_here(rest), "expected ':' or '=' after def header")

        case [TokReturn(info), *rest]:
            expr, rest = parse_tuple_or_expr(rest)
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
            expr = _expect_expr_value(expr)
            return SVar(combine_info(info, expr.info), name, expr), rest

        case [TokIdent(info, name), TokAssign(_), *rest]:
            expr, rest = parse_bound_value(rest)
            expr = _expect_expr_value(expr)
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
            target, rest = _assign
            value, rest = parse_bound_value(rest)
            let_info = combine_info(target.info, value.info)
            match value:
                case Stmt():
                    return SLetStmt(let_info, target, value), rest
                case _:
                    return SLet(let_info, target, value), rest

        case _:
            expr, rest = parse_tuple_or_expr(tokens)
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
