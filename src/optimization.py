"""Tail-call optimization: Pyking AST in, Pyking AST out. A function
that calls itself in tail position becomes a `loop` carrying its own
parameters, and a group of functions that tail-call each other becomes
one worker carrying a state tag. Runs for every mode unless
--no-tail-call-opt is given, so every backend and the interpreter get it
at once. See docs/optimization.md for what counts as a tail call, what
is deliberately left alone, and the groups this cannot make work.

Data structures:
    Context -- what a rewrite needs: which names are recursive here, and
        how each one says "go round again".

Functions:
    optimize(stmts) -- the whole program, tail calls rewritten.
    tail_calls(func, names) -- the names func tail-calls.
"""

from dataclasses import dataclass, fields, is_dataclass, replace

from syntax import (
    pprint_type,
    EInt, EVar, EEq, ECall, EIf, ETuple,
    SLet, SLetStmt, SVar, SMutate, SReturn, SReturnStmt, SExprStmt,
    SFor, SWhile, SLoop, SBreak, SContinue, SIf, SFunctionDef, SMatch,
    MatchCase, Param, TInt, TargetName, TargetTuple,
)


# The generated worker for a mutually recursive group, and the parameter
# that says which of its functions is running. Both are ordinary Pyking
# names -- they appear in `--ast` output and in every backend's source,
# so they are named to read as what they are rather than to hide.
GROUP_NAME = "tail_group"
STATE_NAME = "state"


@dataclass(frozen=True)
class Context:
    """What rewriting one body needs. Fields: names, {String: Int?}
    (the calls this loop stands for, each mapped to the state tag it
    becomes, or None where the loop carries no tag); arity, Int (how
    many values the loop carries, 0 for a loop carrying nothing);
    reserved, {String} (every name the program already uses)."""
    names: dict
    arity: int
    reserved: frozenset


def optimize(stmts):
    """A whole program with its tail calls rewritten. Never rejects: a
    program it cannot improve comes back as it was. [Stmt] -> [Stmt]"""
    return _block(stmts, _identifiers(stmts))


# --- finding tail calls ----------------------------------------------
#
# Tail position is PYKING.md's own: a block's last statement,
# recursively through the branches of an `if` and the arms of a `match`,
# plus the operand of every `return`. The walk stops at a nested `def`
# -- a tail call written there belongs to *that* function -- and at a
# `for`, `while` or `loop`, since a `break` written inside one of those
# would belong to it rather than to the loop being built.


def tail_calls(func, names):
    """The names in `names` that func calls in tail position.
    SFunctionDef -> {String} -> {String}"""
    found = set()
    if func.expr is not None:
        _record_call(func.expr, names, found)
        return found
    _tail_calls_in(func.body or [], names, found, tail=True)
    return found


def _tail_calls_in(stmts, names, found, tail):
    """Records the tail calls in one block. The last statement is in
    tail position when tail; a `return` anywhere is.
    [Stmt] -> {String} -> {String} -> Bool -> ()"""
    for index, statement in enumerate(stmts):
        last = index == len(stmts) - 1
        _tail_calls_in_stmt(statement, names, found, tail and last)


def _tail_calls_in_stmt(statement, names, found, tail):
    """Records the tail calls in one statement. Stmt -> {String} ->
    {String} -> Bool -> ()"""
    match statement:
        case SReturn(_, expr, _):
            _record_call(expr, names, found)
        case SReturnStmt(_, inner, _):
            _tail_calls_in_stmt(inner, names, found, tail=True)
        case SExprStmt(_, expr, _) if tail:
            _record_call(expr, names, found)
        case SIf(_, _, then_body, else_body, _):
            _tail_calls_in(then_body, names, found, tail)
            if else_body is not None:
                _tail_calls_in(else_body, names, found, tail)
        case SMatch(_, _, cases, _):
            for case_clause in cases:
                if case_clause.expr is not None:
                    _record_call(case_clause.expr, names, found)
                else:
                    _tail_calls_in(case_clause.body, names, found, tail)
        case SFor() | SWhile() | SLoop() | SFunctionDef():
            # A `break` written in one of these would belong to it, and
            # a `def`'s tail is its own.
            pass


def _record_call(expr, names, found):
    """Records expr if it is a call to one of names, or if a branch of
    it is: `if c then a else f(x)` waits for nothing either, so its
    branches are tail positions as much as an `if` statement's are.
    Expr -> {String} -> {String} -> ()"""
    match expr:
        case ECall(_, EVar(_, name, _), _, _) if name in names:
            found.add(name)
        case EIf(_, _, then_expr, else_expr, _):
            _record_call(then_expr, names, found)
            _record_call(else_expr, names, found)


# --- rewriting one body ----------------------------------------------


def _rewrite_block(stmts, context, jumping):
    """A block whose last statement is what the loop does next, and
    whose `return`s are likewise wherever they are. `jumping` says the
    block is not the loop body's own tail, so going round has to be said
    out loud with `continue` rather than left to falling off the end.
    [Stmt] -> Context -> Bool -> [Stmt]"""
    if not stmts:
        return stmts
    out = []
    for statement in stmts[:-1]:
        out.extend(_rewrite_inner(statement, context))
    return out + _rewrite_tail(stmts[-1], context, jumping)


def _rewrite_tail(statement, context, jumping):
    """The last statement of a block, as the statements saying what the
    loop does next. Stmt -> Context -> Bool -> [Stmt]"""
    match statement:
        case SExprStmt(info, expr, _) | SReturn(info, expr, _):
            return _going_on(info, expr, context, jumping)

        case SReturnStmt(_, inner, _):
            # `return if c: ...` -- the branches are the tails, and the
            # `return` itself has nothing left to say.
            return _rewrite_tail(inner, context, jumping)

        case SIf(info, cond, then_body, else_body, _):
            # A path that runs no branch supplies unit, and that is what
            # the function would have returned.
            return [SIf(
                info,
                cond,
                _rewrite_block(then_body, context, jumping),
                _rewrite_block(else_body, context, jumping)
                if else_body is not None
                else [SBreak(info, ETuple(info, []))],
            )]

        case SMatch(info, subject, cases, _):
            # A subject matching no arm falls out of the function as
            # unit, which the `break` after the match is. That `break`
            # is also why every arm has to *jump*: an arm that merely
            # ended in the next accumulator would fall out of the match
            # and reach it.
            return [
                SMatch(
                    info, subject,
                    [_rewrite_case(c, context, jumping=True) for c in cases],
                ),
                SBreak(info, ETuple(info, [])),
            ]

        case SLoop(info, _, _, _, _, _):
            # A loop of the program's own in tail position is what the
            # function is worth, so it is bound and then broken with.
            name = _fresh(context.reserved, "answer")
            return [
                SLetStmt(info, TargetName(info, name), statement),
                SBreak(info, EVar(info, name)),
            ]

        case _:
            # Anything else supplies unit (PYKING.md, "Tail position").
            info = statement.info
            return [statement, SBreak(info, ETuple(info, []))]


def _rewrite_case(case_clause, context, jumping):
    """One arm of a `match` in tail position. A `case p -> e` arm means
    a `return e`, so it becomes a block whose tail is rewritten like any
    other. MatchCase -> Context -> Bool -> MatchCase"""
    if case_clause.expr is not None:
        info = case_clause.expr.info
        return replace(
            case_clause,
            expr=None,
            body=_going_on(info, case_clause.expr, context, jumping),
        )
    return replace(
        case_clause, body=_rewrite_block(case_clause.body, context, jumping)
    )


def _rewrite_inner(statement, context):
    """A statement that is not the block's last: only the `return`s
    inside it change, since each one leaves the function and so is a
    tail position of its own -- and one written here has to jump.
    Stmt -> Context -> [Stmt]"""
    match statement:
        case SReturn(info, expr, _):
            return _going_on(info, expr, context, jumping=True)

        case SReturnStmt(_, inner, _):
            return _rewrite_tail(inner, context, jumping=True)

        case SIf(info, cond, then_body, else_body, sym):
            return [SIf(
                info,
                cond,
                _rewrite_inners(then_body, context),
                None if else_body is None else _rewrite_inners(else_body, context),
                sym,
            )]

        case SMatch(info, subject, cases, sym):
            return [SMatch(
                info,
                subject,
                [
                    c if c.expr is not None
                    else replace(c, body=_rewrite_inners(c.body, context))
                    for c in cases
                ],
                sym,
            )]

    # A `for`, `while` or `loop` of the program's own: a `break` written
    # inside it would belong to it, so the `return`s in there stay
    # `return`s. A nested `def` is its own business.
    return [statement]


def _rewrite_inners(stmts, context):
    """Every statement of a block, none of them its last.
    [Stmt] -> Context -> [Stmt]"""
    return [out for s in stmts for out in _rewrite_inner(s, context)]


def _going_on(info, expr, context, jumping):
    """What the loop does with this value: go round again when it is a
    call the loop stands for, and stop with it otherwise.
    Info -> Expr -> Context -> Bool -> [Stmt]"""
    match expr:
        case EIf(if_info, cond, then_expr, else_expr, _) if _chooses_call(
            expr, context
        ):
            # An `if` expression one of whose branches goes round again:
            # as an expression there is nowhere to say that, so it
            # becomes the statement it already means.
            return [SIf(
                if_info,
                cond,
                _going_on(if_info, then_expr, context, jumping),
                _going_on(if_info, else_expr, context, jumping),
            )]
        case ECall(call_info, EVar(_, name, _), args, _) if (
            name in context.names and len(args) == context.arity - (
                0 if context.names[name] is None else 1
            )
        ):
            if context.arity == 0:
                return [SContinue(info, None)]
            state = _state_of(call_info, context.names[name], args)
            return [SContinue(info, state)] if jumping else [SExprStmt(info, state)]
    return [SBreak(info, expr)]


def _chooses_call(expr, context):
    """Whether a branch of this `if` expression, however deeply
    chained, is a call the loop stands for. Expr -> Context -> Bool"""
    found = set()
    _record_call(expr, set(context.names), found)
    return bool(found)


def _state_of(info, tag, args):
    """The accumulator a call to a rewritten function becomes: its
    arguments, with the state tag in front where there is a group.
    Info -> Int? -> [Expr] -> Expr"""
    values = list(args) if tag is None else [EInt(info, tag)] + list(args)
    if len(values) == 1:
        return values[0]
    return ETuple(info, values)


# --- one function that calls itself ----------------------------------


def _rewrite_self(func, reserved):
    """func with its own tail calls turned into a loop carrying its
    parameters. SFunctionDef -> {String} -> SFunctionDef"""
    context = Context({func.name: None}, len(func.params), frozenset(reserved))
    body = func.body if func.body is not None else [
        SReturn(func.expr.info, func.expr)
    ]
    return replace(
        func,
        body=[_loop_over(func.info, [p.name for p in func.params],
                         _rewrite_block(body, context, jumping=False))],
        expr=None,
    )


def _loop_over(info, names, body):
    """The loop a rewritten body runs in: it carries the names it was
    given, starting from what they already hold.
    Info -> [String] -> [Stmt] -> SLoop"""
    if not names:
        return SLoop(info, None, None, None, body)
    target = (
        TargetName(info, names[0]) if len(names) == 1
        else TargetTuple(info, [TargetName(info, name) for name in names])
    )
    init = (
        EVar(info, names[0]) if len(names) == 1
        else ETuple(info, [EVar(info, name) for name in names])
    )
    return SLoop(info, target, init, None, body)


# --- a group that calls each other -----------------------------------


def _merge(group, reserved, index):
    """The worker and wrappers a mutually recursive group becomes, or
    None if it is one this cannot make: its functions must agree on how
    many parameters they take. [SFunctionDef] -> {String} -> Int ->
    [Stmt]?"""
    arity = len(group[0].params)
    if any(len(func.params) != arity for func in group):
        return None

    worker = _fresh(reserved, f"{GROUP_NAME}{index}")
    state = _fresh(reserved | {worker}, STATE_NAME)
    slots = _slot_names(group, reserved | {worker, state})
    tags = {func.name: tag for tag, func in enumerate(group)}
    context = Context(
        tags, arity + 1, frozenset(reserved | {worker, state} | set(slots))
    )

    branches = [_branch(func, slots, context) for func in group]
    dispatch = _dispatch(group[0].info, state, tags, group, branches)
    body = [_loop_over(group[0].info, [state] + slots, [dispatch])]
    return [
        SFunctionDef(
            group[0].info,
            worker,
            [Param(group[0].info, state, TInt(group[0].info))]
            + _worker_params(group, slots),
            body,
            _shared_return_type(group),
        )
    ] + [_wrapper(func, worker, tags[func.name]) for func in group]


def _branch(func, slots, context):
    """One function's body inside the worker: its parameters read off
    the slots they were passed in, and its tail calls rewritten.
    SFunctionDef -> [String] -> Context -> [Stmt]"""
    body = func.body if func.body is not None else [
        SReturn(func.expr.info, func.expr)
    ]
    rebindings = [
        SLet(param.info, TargetName(param.info, param.name),
             EVar(param.info, slot))
        for param, slot in zip(func.params, slots)
        if param.name != slot
    ]
    return rebindings + _rewrite_block(body, context, jumping=False)


def _dispatch(info, state, tags, group, branches):
    """The `if state == 0: ... else: ...` chain choosing whose body
    runs. The last function needs no test: the state is one of them.
    Info -> String -> {String: Int} -> [SFunctionDef] -> [[Stmt]] -> Stmt"""
    chain = branches[-1]
    for func, branch in reversed(list(zip(group[:-1], branches[:-1]))):
        chain = [SIf(
            info,
            EEq(info, EVar(info, state), EInt(info, tags[func.name])),
            branch,
            chain,
        )]
    return chain[0]


def _wrapper(func, worker, tag):
    """The one-line function left where a merged one was: it hands the
    worker its state and its arguments. SFunctionDef -> String -> Int ->
    SFunctionDef"""
    info = func.info
    return replace(
        func,
        body=None,
        expr=ECall(
            info,
            EVar(info, worker),
            [EInt(info, tag)] + [EVar(p.info, p.name) for p in func.params],
        ),
    )


def _slot_names(group, reserved):
    """One name per parameter position: the first function's, unless
    another function's body would have it mean something else, in which
    case a fresh one. [SFunctionDef] -> {String} -> [String]"""
    slots = []
    for position, param in enumerate(group[0].params):
        name = param.name
        if any(_would_capture(func, position, name) for func in group[1:]):
            name = _fresh(reserved | set(slots), f"{param.name}_slot")
        slots.append(name)
    return slots


def _would_capture(func, position, name):
    """Whether giving a slot this name would change what it means
    inside func: it does unless func's own parameter there is already
    called that, or func never mentions the name at all.
    SFunctionDef -> Int -> String -> Bool"""
    if func.params[position].name == name:
        return False
    return _mentions(func.body if func.body is not None else func.expr, name)


def _worker_params(group, slots):
    """The worker's parameters: the slots, annotated where every
    function in the group annotates that position the same way.
    [SFunctionDef] -> [String] -> [Param]"""
    params = []
    for position, slot in enumerate(slots):
        annotations = [func.params[position].type for func in group]
        shared = annotations[0] if _all_same(annotations) else None
        params.append(Param(group[0].params[position].info, slot, shared))
    return params


def _shared_return_type(group):
    """The worker's return type: the group's, where they agree.
    [SFunctionDef] -> Type?"""
    types = [func.return_type for func in group]
    return types[0] if _all_same(types) else None


def _all_same(types):
    """Whether every annotation here says the same thing -- compared as
    written, since nothing has checked them yet. [Type?] -> Bool"""
    written = [None if t is None else pprint_type(t) for t in types]
    return all(one == written[0] for one in written)


# --- walking the program ---------------------------------------------


def _block(stmts, reserved):
    """One block with its own functions rewritten and every nested block
    walked. [Stmt] -> {String} -> [Stmt]"""
    stmts = [_walk(s, reserved) for s in stmts]
    functions = _functions(stmts)
    if not functions:
        return stmts

    groups = _groups(functions)
    rewritten = {}
    replacements = {}
    for index, group in enumerate(groups, start=1):
        if len(group) == 1:
            func = functions[group[0]]
            if group[0] in tail_calls(func, {group[0]}) and _rewritable(func):
                rewritten[group[0]] = _rewrite_self(func, reserved)
            continue
        members = [functions[name] for name in group]
        if not all(_rewritable(func) for func in members):
            continue
        merged = _merge(members, reserved, index)
        if merged is None:
            # A group this cannot merge -- its functions take different
            # numbers of parameters -- may still have self-calls worth
            # rewriting.
            for func in members:
                if func.name in tail_calls(func, {func.name}):
                    rewritten[func.name] = _rewrite_self(func, reserved)
            continue
        replacements[group[0]] = merged
        for name in group[1:]:
            replacements[name] = []

    if not rewritten and not replacements:
        return stmts
    out = []
    for statement in stmts:
        match statement:
            case SFunctionDef(_, name, _, _, _, _, _) if name in replacements:
                out.extend(replacements[name])
            case SFunctionDef(_, name, _, _, _, _, _) if name in rewritten:
                out.append(rewritten[name])
            case _:
                out.append(statement)
    return out


def _walk(statement, reserved):
    """statement with every block inside it optimized. Stmt -> {String}
    -> Stmt"""
    match statement:
        case SFunctionDef(_, _, _, body, _, _, _) if body is not None:
            return replace(statement, body=_block(body, reserved))
        case SFor(_, _, _, body, _) | SWhile(_, _, body, _):
            return replace(statement, body=_block(body, reserved))
        case SLoop(_, _, _, _, body, _):
            return replace(statement, body=_block(body, reserved))
        case SIf(_, _, then_body, else_body, _):
            return replace(
                statement,
                then_body=_block(then_body, reserved),
                else_body=None if else_body is None else _block(else_body, reserved),
            )
        case SMatch(_, _, cases, _):
            return replace(
                statement,
                cases=[
                    c if c.body is None else replace(c, body=_block(c.body, reserved))
                    for c in cases
                ],
            )
        case SLetStmt(_, _, inner, _, _) | SReturnStmt(_, inner, _):
            return replace(statement, stmt=_walk(inner, reserved))
    return statement


def _functions(stmts):
    """The defs of one block, name -> node, dropping any name defined
    twice (a program the name analysis will refuse anyway).
    [Stmt] -> {String: SFunctionDef}"""
    found = {}
    twice = set()
    for statement in stmts:
        match statement:
            case SFunctionDef(_, name, _, _, _, _, _):
                if name in found:
                    twice.add(name)
                found[name] = statement
    for name in twice:
        del found[name]
    return found


def _groups(functions):
    """The block's functions in tail-call groups: each is a set that
    tail-calls its way round to itself, in the order the functions were
    written. {String: SFunctionDef} -> [[String]]"""
    names = set(functions)
    calls = {name: tail_calls(func, names) for name, func in functions.items()}
    order = list(functions)
    reaches = {name: _reachable(name, calls) for name in order}
    groups = []
    grouped = set()
    for name in order:
        if name in grouped:
            continue
        group = [
            other for other in order
            if other == name
            or (other in reaches[name] and name in reaches[other])
        ]
        grouped.update(group)
        groups.append(group)
    return groups


def _reachable(name, calls):
    """Every function reachable from name by tail calls. String ->
    {String: {String}} -> {String}"""
    seen = set()
    todo = list(calls.get(name, ()))
    while todo:
        current = todo.pop()
        if current in seen:
            continue
        seen.add(current)
        todo.extend(calls.get(current, ()))
    return seen


def _rewritable(func):
    """Whether func may be rewritten at all: its parameters have to be
    distinct names it does not bind again, since the loop carries them.
    SFunctionDef -> Bool"""
    names = [p.name for p in func.params]
    if len(set(names)) != len(names):
        return False
    body = func.body if func.body is not None else func.expr
    return not _binds(body, {func.name})


def _binds(node, names):
    """Whether node binds any of names anywhere inside it -- which would
    make a call written there mean something other than the function.
    a -> {String} -> Bool"""
    found = [False]

    def look(item):
        if found[0]:
            return
        match item:
            case SLet(_, target, _, _, _) | SLetStmt(_, target, _, _, _):
                if names & set(_target_names(target)):
                    found[0] = True
            case SVar(_, name, _, _) | SFor(_, name, _, _, _):
                if name in names:
                    found[0] = True
            case SLoop(_, target, _, _, _, _) if target is not None:
                if names & set(_target_names(target)):
                    found[0] = True
            case SFunctionDef(_, name, params, _, _, _, _):
                if name in names or names & {p.name for p in params}:
                    found[0] = True
        if is_dataclass(item):
            for f in fields(item):
                look(getattr(item, f.name))
        elif isinstance(item, (list, tuple)):
            for element in item:
                look(element)

    look(node)
    return found[0]


def _target_names(target):
    """Every name an assignment target binds. AssignTarget -> [String]"""
    match target:
        case TargetName(_, name, _):
            return [name]
        case TargetTuple(_, elements, _):
            return [name for e in elements for name in _target_names(e)]
    return []


def _mentions(node, name):
    """Whether name appears anywhere in node, as a use or a binding. A
    deliberately blunt test: it decides only whether a generated name
    may reuse a written one, where being over-careful costs a longer
    name and being wrong costs a captured variable. a -> String -> Bool"""
    found = [False]

    def look(item):
        if found[0]:
            return
        if is_dataclass(item):
            for f in fields(item):
                value = getattr(item, f.name)
                if f.name == "name" and value == name:
                    found[0] = True
                    return
                look(value)
        elif isinstance(item, (list, tuple)):
            for element in item:
                look(element)

    look(node)
    return found[0]


def _identifiers(node, acc=None):
    """Every identifier written anywhere in the program, so a generated
    name can avoid all of them. a -> {String}? -> {String}"""
    if acc is None:
        acc = set()
    if is_dataclass(node):
        for f in fields(node):
            value = getattr(node, f.name)
            if f.name == "name" and isinstance(value, str):
                acc.add(value)
            else:
                _identifiers(value, acc)
    elif isinstance(node, (list, tuple)):
        for element in node:
            _identifiers(element, acc)
    return acc


def _fresh(reserved, preferred):
    """preferred, or preferred2, preferred3, ... -- the first name the
    program does not already use. {String} -> String -> String"""
    if preferred not in reserved:
        return preferred
    n = 2
    while f"{preferred}{n}" in reserved:
        n += 1
    return f"{preferred}{n}"
