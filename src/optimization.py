"""Tail-call optimization: Pyking AST in, Pyking AST out. A function
that calls itself in tail position becomes a `loop` carrying its own
parameters, and a group of functions that tail-call each other becomes
one worker carrying a state tag. Runs for every mode unless
--no-tail-call-opt is given, so every backend and the interpreter get it
at once.

It runs *after* the type checker and only on a program the checker
accepted, which is what makes the rewrite safe to leave unchecked: the
types decide which groups can be merged, and give the value a padded
slot is entered with. See docs/optimization.md for what counts as a
tail call, what is deliberately left alone, and why one check is
enough.

Data structures:
    Callee -- a call this loop stands for: its state tag and its arity.
    Context -- what a rewrite needs: the calls it stands for, the slots
        the loop carries, and the names the program already uses.
    Pass -- the two things filled in as the pass runs: the type table
        it extends, and the symbols it hands out.

Functions:
    optimize(stmts, tmap) -- the whole program, tail calls rewritten,
        with the type table extended for what was built.
    tail_calls(func, names) -- the names func tail-calls.
"""

from dataclasses import dataclass, fields, is_dataclass, replace

from typesystem import same_type
from syntax import (
    EInt, EString, EBool, EVar, EEq, ECall, EIf, EList, ETuple,
    SLet, SLetStmt, SVar, SMutate, SReturn, SReturnStmt, SExprStmt,
    SLoop, SBreak, SContinue, SIf, SFunctionDef, SMatch, ForIn,
    Param, TInt, TString, TBool, TList, TTuple, TFunction, TOr, TUnknown,
    TNever, TargetName, TargetTuple,
)


# The generated worker for a mutually recursive group, and the parameter
# that says which of its functions is running. Both are ordinary Pyking
# names -- they appear in `--ast` output and in every backend's source,
# so they are named to read as what they are rather than to hide.
GROUP_NAME = "tail_group"
STATE_NAME = "state"


@dataclass(frozen=True)
class Callee:
    """A call the loop being built stands for. Fields: tag, Int? (the
    state a call to it becomes, absent when the loop carries no state);
    arity, Int (how many arguments such a call gives -- which need not
    be how many the loop carries, since a group is as wide as its
    widest member)."""
    tag: int
    arity: int


@dataclass(frozen=True)
class Context:
    """What rewriting one body needs. Fields: names, {String: Callee}
    (the calls this loop stands for); slots, [String] (the values the
    loop carries, *not* counting the state tag, so a call that fills
    fewer of them can carry the rest forward); reserved, {String}
    (every name the program already uses)."""
    names: dict
    slots: list
    reserved: frozenset


class Pass:
    """The two things this pass fills in rather than rebuilds, for the
    same reason `typesystem.record` fills in one table: they are its
    result, not its context. `types` is the checker's table, extended
    for the annotatable nodes the pass builds -- without it, a
    `--typecheck --ast` run would print those with no type at all, the
    checker having never seen them. `symbols` hands out the identities
    those entries are keyed by, continuing past the highest the program
    already uses, which is exactly what `analyses.symbolize` will do
    with the rest afterwards. `reserved` is ordinary context: every name
    the program writes."""

    def __init__(self, reserved, types, first_symbol):
        self.reserved = frozenset(reserved)
        self.types = types
        self.next_symbol = first_symbol

    def symbol(self):
        """A symbol nothing else has. () -> Int"""
        self.next_symbol += 1
        return self.next_symbol - 1

    def record(self, node, type_):
        """Gives node a symbol of its own and remembers its type, so
        that a printed AST shows what the pass built with the types it
        built them from. a -> Type -> a"""
        node = replace(node, sym=self.symbol())
        self.types[node.sym] = type_
        return node


def optimize(stmts, tmap):
    """A whole program with its tail calls rewritten, and the checker's
    table extended for the nodes that rewriting built. Never rejects: a
    program it cannot improve comes back as it was.
    [Stmt] -> {Int: Type} -> ([Stmt], {Int: Type})"""
    types = dict(tmap)
    work = Pass(_identifiers(stmts), types, _highest_symbol(stmts) + 1)
    return _block(stmts, work), types


def _highest_symbol(node, highest=0):
    """The largest symbol anything in node carries, so the pass can hand
    out ones nothing else has. a -> Int -> Int"""
    if is_dataclass(node):
        sym = getattr(node, "sym", 0)
        highest = max(highest, sym if isinstance(sym, int) else 0)
        for f in fields(node):
            highest = _highest_symbol(getattr(node, f.name), highest)
    elif isinstance(node, (list, tuple)):
        for element in node:
            highest = _highest_symbol(element, highest)
    return highest


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
                _tail_calls_in(case_clause.body, names, found, tail)
        case SLoop() | SFunctionDef():
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

        case SLoop(info, _, _, _, _, _, _, _):
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
    """One arm of a `match` in tail position: its block, rewritten like
    any other. MatchCase -> Context -> Bool -> MatchCase"""
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
                    replace(c, body=_rewrite_inners(c.body, context))
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
            name in context.names and len(args) == context.names[name].arity
        ):
            state = _state_of(call_info, context.names[name], args, context)
            if state is None:
                # A loop carrying nothing: there is no next value to
                # give it, only another turn.
                return [SContinue(info, None)]
            return [SContinue(info, state)] if jumping else [SExprStmt(info, state)]
    return [SBreak(info, expr)]


def _chooses_call(expr, context):
    """Whether a branch of this `if` expression, however deeply
    chained, is a call the loop stands for. Expr -> Context -> Bool"""
    found = set()
    _record_call(expr, set(context.names), found)
    return bool(found)


def _state_of(info, callee, args, context):
    """The accumulator a call to a rewritten function becomes: its
    arguments, the state tag in front where there is a group, and the
    slots it does not fill carried forward from the turn it is on --
    which is what lets one loop serve functions of different widths.
    None where the loop carries nothing at all.
    Info -> Callee -> [Expr] -> Context -> Expr?"""
    values = list(args) + [
        EVar(info, slot) for slot in context.slots[len(args):]
    ]
    if callee.tag is not None:
        values = [EInt(info, callee.tag)] + values
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    return ETuple(info, values)


# --- one function that calls itself ----------------------------------


def _rewrite_self(func, work):
    """func with its own tail calls turned into a loop carrying its
    parameters. SFunctionDef -> Pass -> SFunctionDef"""
    slots = [p.name for p in func.params]
    context = Context(
        {func.name: Callee(None, len(func.params))}, slots, work.reserved
    )
    body = func.body
    carried = [work.types.get(p.sym) for p in func.params]
    return replace(
        func,
        body=[_loop_over(
            func.info, slots,
            _rewrite_block(body, context, jumping=False),
            carried, work,
        )],
    )


def _loop_over(info, names, body, carried, work):
    """The loop a rewritten body runs in: it carries the names it was
    given, starting from what they already hold. `carried` is what the
    checker says each of them is, so that the loop node carries its own
    type into the table.
    Info -> [String] -> [Stmt] -> [Type?] -> Pass -> SLoop"""
    if not names:
        return SLoop(info, None, None, None, None, body)
    target = (
        TargetName(info, names[0]) if len(names) == 1
        else TargetTuple(info, [TargetName(info, name) for name in names])
    )
    init = (
        EVar(info, names[0]) if len(names) == 1
        else ETuple(info, [EVar(info, name) for name in names])
    )
    loop = SLoop(info, target, init, None, None, body)
    if any(type_ is None for type_ in carried):
        return loop
    accumulator = carried[0] if len(carried) == 1 else TTuple(info, list(carried))
    return work.record(loop, accumulator)


# --- a group that calls each other -----------------------------------


def _merge(group, work, index):
    """The worker and wrappers a mutually recursive group becomes, or
    None if the checker's types say it is one this cannot make (see
    `_shared`). [SFunctionDef] -> Pass -> Int -> [Stmt]?"""
    shape = _shared(group, work.types)
    if shape is None:
        return None
    slot_types, result = shape
    width = len(slot_types)

    worker = _fresh(work.reserved, f"{GROUP_NAME}{index}")
    state = _fresh(work.reserved | {worker}, STATE_NAME)
    slots = _slot_names(group, width, work.reserved | {worker, state})
    tags = {func.name: tag for tag, func in enumerate(group)}
    context = Context(
        {
            func.name: Callee(tags[func.name], len(func.params))
            for func in group
        },
        slots,
        frozenset(work.reserved | {worker, state} | set(slots)),
    )

    info = group[0].info
    branches = [
        _branch(func, slots, slot_types, context, work) for func in group
    ]
    dispatch = _dispatch(info, state, tags, group, branches)
    carried = [TInt(info)] + list(slot_types)
    body = [_loop_over(info, [state] + slots, [dispatch], carried, work)]

    params = [work.record(Param(info, state, TInt(info)), TInt(info))] + [
        work.record(Param(info, slot, type_), type_)
        for slot, type_ in zip(slots, slot_types)
    ]
    definition = work.record(
        SFunctionDef(info, worker, params, body, result),
        TFunction(info, [TInt(info)] + list(slot_types), result),
    )
    # Every slot has a type, so every wrapper has something to enter the
    # ones it does not fill with. The value is never read -- the state
    # it belongs to has no such parameter -- so being of the right type
    # is the whole of what is asked of it.
    zeros = [_zero(type_, info) for type_ in slot_types]
    return [definition] + [
        _wrapper(func, worker, tags[func.name], zeros) for func in group
    ]


def _shared(group, types):
    """What the group's functions agree on, as (slot types, result
    type), or None if the checker's types say they do not agree enough
    to share one loop. Four things are asked, and each of them is a
    thing only the checker knows (docs/optimization.md, "The gate").
    [SFunctionDef] -> {Int: Type} -> ([Type], Type)?"""
    signatures = [_signature(func, types) for func in group]
    if any(signature is None for signature in signatures):
        return None                      # 4. one definite type each
    width = max(len(params) for params, _ in signatures)

    slot_types = []
    for position in range(width):
        here = [
            params[position] for params, _ in signatures if position < len(params)
        ]
        if not all(same_type(type_, here[0]) for type_ in here):
            return None                  # 1. the members agree per position
        if len(here) != len(signatures) and _zero(here[0], group[0].info) is None:
            return None                  # 2. a padded slot needs a zero
        slot_types.append(here[0])

    results = [result for _, result in signatures]
    if not all(same_type(result, results[0]) for result in results):
        return None                      # 3. and on what they answer with
    return slot_types, results[0]


def _signature(func, types):
    """The parameter and result types the checker worked out for func,
    or None where it did not work out exactly one -- a function nothing
    called, or one checked at several shapes, has no single answer to
    give a shared loop. SFunctionDef -> {Int: Type} -> ([Type], Type)?"""
    match types.get(func.sym):
        case TFunction(_, params, result, _, _, _) if len(params) == len(func.params):
            if any(_undecided(type_) for type_ in list(params) + [result]):
                return None
            return list(params), result
    return None


def _undecided(type_):
    """Whether the checker left this type open, so that nothing can be
    written down for it. Type -> Bool"""
    return isinstance(type_, (TUnknown, TNever))


def _zero(type_, info):
    """A value of this type to enter a slot with, or None for a type
    that has no obvious one. Never read -- see `_merge` -- so the only
    thing asked of it is that it type-checks. Type -> Info -> Expr?"""
    match type_:
        case TInt():
            return EInt(info, 0)
        case TString():
            return EString(info, "")
        case TBool():
            return EBool(info, False)
        case TList():
            return EList(info, [])
        case TTuple(_, elements):
            insides = [_zero(element, info) for element in elements]
            if any(inside is None for inside in insides):
                return None
            return ETuple(info, insides)
    # A function has no zero, and neither has an alternative: there is
    # no one value that is both an Int and a String.
    return None


def _branch(func, slots, slot_types, context, work):
    """One function's body inside the worker: its parameters read off
    the slots they were passed in, and its tail calls rewritten. A
    function narrower than the group reads only the slots it has.
    SFunctionDef -> [String] -> [Type] -> Context -> Pass -> [Stmt]"""
    body = func.body
    rebindings = [
        work.record(
            SLet(param.info, TargetName(param.info, param.name),
                 EVar(param.info, slot)),
            type_,
        )
        for param, slot, type_ in zip(func.params, slots, slot_types)
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


def _wrapper(func, worker, tag, zeros):
    """The one-line function left where a merged one was: it hands the
    worker its state, its arguments, and a value of the right type for
    each slot it does not have.
    SFunctionDef -> String -> Int -> [Expr] -> SFunctionDef"""
    info = func.info
    call = ECall(
        info,
        EVar(info, worker),
        [EInt(info, tag)]
        + [EVar(p.info, p.name) for p in func.params]
        + list(zeros[len(func.params):]),
    )
    # A body of one expression: what the block supplies is that call's
    # value, which is what this function now returns (PYKING.md, "Tail
    # position").
    return replace(func, body=[SExprStmt(info, call)])


def _slot_names(group, width, reserved):
    """One name per slot -- as many as the widest function takes. Each
    is the name of the first function that *has* that position, unless
    some function's body would have it mean something else, in which
    case a fresh one. A function narrower than the group is asked too:
    it does not use the slot, but a name that captured something it
    reads would change it all the same.
    [SFunctionDef] -> Int -> {String} -> [String]"""
    slots = []
    for position in range(width):
        owner = next(
            func for func in group if position < len(func.params)
        ).params[position]
        name = owner.name
        if any(_would_capture(func, position, name) for func in group):
            name = _fresh(reserved | set(slots), f"{owner.name}_slot")
        slots.append(name)
    return slots


def _would_capture(func, position, name):
    """Whether giving a slot this name would change what it means
    inside func: it does unless func's own parameter there is already
    called that, or func never mentions the name at all.
    SFunctionDef -> Int -> String -> Bool"""
    if position < len(func.params) and func.params[position].name == name:
        return False
    return _mentions(func.body, name)


# --- walking the program ---------------------------------------------


def _block(stmts, work):
    """One block with its own functions rewritten and every nested block
    walked. [Stmt] -> Pass -> [Stmt]"""
    stmts = [_walk(s, work) for s in stmts]
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
                rewritten[group[0]] = _rewrite_self(func, work)
            continue
        members = [functions[name] for name in group]
        if not all(_rewritable(func) for func in members):
            continue
        merged = _merge(members, work, index)
        if merged is None:
            # A group the checker's types say cannot share one loop may
            # still have self-calls worth rewriting.
            for func in members:
                if func.name in tail_calls(func, {func.name}):
                    rewritten[func.name] = _rewrite_self(func, work)
            continue
        replacements[group[0]] = merged
        for name in group[1:]:
            replacements[name] = []

    if not rewritten and not replacements:
        return stmts
    out = []
    for statement in stmts:
        match statement:
            case SFunctionDef(_, name, _, _, _, _) if name in replacements:
                out.extend(replacements[name])
            case SFunctionDef(_, name, _, _, _, _) if name in rewritten:
                out.append(rewritten[name])
            case _:
                out.append(statement)
    return out


def _walk(statement, work):
    """statement with every block inside it optimized.
    Stmt -> Pass -> Stmt"""
    match statement:
        case SFunctionDef(_, _, _, body, _, _) if body is not None:
            return replace(statement, body=_block(body, work))
        case SLoop(_, _, _, _, _, body, after, _):
            rewritten = replace(statement, body=_block(body, work))
            if after is None:
                return rewritten
            return replace(rewritten, after=_block(after, work))
        case SIf(_, _, then_body, else_body, _):
            return replace(
                statement,
                then_body=_block(then_body, work),
                else_body=None if else_body is None else _block(else_body, work),
            )
        case SMatch(_, _, cases, _):
            return replace(
                statement,
                cases=[
                    c if c.body is None else replace(c, body=_block(c.body, work))
                    for c in cases
                ],
            )
        case SLetStmt(_, _, inner, _, _) | SReturnStmt(_, inner, _):
            return replace(statement, stmt=_walk(inner, work))
    return statement


def _functions(stmts):
    """The defs of one block, name -> node, dropping any name defined
    twice (a program the name analysis will refuse anyway).
    [Stmt] -> {String: SFunctionDef}"""
    found = {}
    twice = set()
    for statement in stmts:
        match statement:
            case SFunctionDef(_, name, _, _, _, _):
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
    return not _binds(func.body, {func.name})


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
            case SVar(_, name, _, _):
                if name in names:
                    found[0] = True
            case SLoop(_, target, _, _, iterate, _, _, _):
                if target is not None and names & set(_target_names(target)):
                    found[0] = True
                # A `for` binds its element name each turn, so it is a
                # rebinding like any other.
                match iterate:
                    case ForIn(_, name, _, _) if name in names:
                        found[0] = True
            case SFunctionDef(_, name, params, _, _, _):
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
