"""Static analyses over the Pyking AST (src/syntax.py): mutability
checking, symbolizing (giving every node a unique integer id), and which
expressions can produce output. The first two run after parsing and
before any backend; the third is asked for by the backends whose host
language leaves evaluation order unspecified. See PYKING.md, "Names and
scoping", and docs/architecture.md, docs/source.md ("analyses.py").

Names and types are src/typesystem.py's, which every mode runs: a name
that is not in scope is refused there, in this module's words. What is
left here is the one rule types do not state -- which names may be
written to with `:=`, and that nothing may shadow one that can be.

Data structures:
    AnalysisError -- a name/scoping failure, with the source position.
    Binding -- what the environment records for one name in scope.
    Effects -- which calls in a program can end up printing.

Functions:
    analyze_mutability(stmts) -- checks a whole program's mutability.
    analyze_stmts(stmts, env) -- analyzes a statement sequence.
    analyze_stmt(s, env) -- analyzes one statement.
    analyze_scope(stmts, env) -- analyzes a nested block.
    bind(env, name, kind, info) -- extends env with one binding.
    bind_target(env, target, kind) -- binds every name in an assign target.
    bind_pattern(env, pattern) -- binds every name a pattern captures.
    pattern_bindings(pattern) -- the (name, info) pairs a pattern binds.
    bound_names(stmt) -- the (name, info) pairs a statement binds in its block.
    target_names(target) -- the (name, info) pairs an assign target binds.
    block_functions(stmts) -- the defs at the top of a block, name -> node.
    check_no_function_clash(name, info, functions) -- checks no other
        binding in the block shares a def's name.
    symbolize(stmts) -- gives every node a unique integer sym.
    walk(node) -- every node in a tree, the tree itself included.
    all_functions(stmts) -- every def in a program, at any depth, by name.
"""

import itertools
from dataclasses import dataclass, fields, is_dataclass, replace

from lexer import Info
import runtime_interface
from syntax import (
    EVar, EQualified, ECall,
    PCapture, PTuple, PList, PText,
    SLet, SLetStmt, SVar, SMutate, SReturn, SReturnStmt, SExprStmt, SIf,
    ForIn,
    SLoop, SBreak, SContinue,
    SFunctionDef, SFunctionSig, SMatch, SImport,
    TFunction, TForall,
    TargetName, TargetTuple,
)


class AnalysisError(Exception):
    """A name/scoping failure, with the source position of the offending
    name."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


# --- kinds of binding ---

MUTABLE = "mutable variable"      # var name = ...
BINDING = "binding"               # name = ...
PARAMETER = "parameter"           # def f(name)
LOOP_VAR = "loop variable"        # for name in ... / loop name = ...
PATTERN_VAR = "pattern variable"  # case ...name...:
FUNCTION = "function"             # def name(...)
BUILTIN = "builtin"               # see `BUILTINS`
IMPORTED = "imported name"        # import m / from m import name

# Names that are not bound in a Pyking program but that the generated
# Python calls directly. Extend when a program starts using another one.
BUILTINS = ("print", "range", "str", "len")


@dataclass(frozen=True)
class Binding:
    """What the environment records for one name in scope. Fields:
    kind: String (one of the constants above), info: Info? (None for a
    builtin, which has no source position)."""
    kind: str
    info: Info = None    # None for a builtin, which has no source position


def where_bound(binding):
    """Formats where a binding was declared, for an error message; empty
    for a builtin. Binding -> String"""
    if binding.info is None:
        return ""
    return f" (declared on line {binding.info.row1})"


def bind(env, name, kind, info):
    """Extends env with name bound as kind. Raises AnalysisError if name
    is already bound as a mutable variable.
    {String: Binding} -> String -> String -> Info -> {String: Binding}"""
    existing = env.get(name)
    if existing is not None and existing.kind == MUTABLE:
        raise AnalysisError(
            info,
            f"cannot bind '{name}': the mutable variable '{name}'"
            f"{where_bound(existing)} is in scope, and a mutable variable may not "
            "be shadowed (update it with ':=', or choose another name)",
        )
    return {**env, name: Binding(kind, info)}


def pattern_bindings(pattern):
    """The names a pattern binds, as (name, info) pairs, in source
    order. Pattern -> [(String, Info)]"""
    match pattern:
        case PCapture(info, name):
            return [(name, info)]
        case PTuple(_, elements):
            return [b for e in elements for b in pattern_bindings(e)]
        case PText(info, _, name, _, _):
            return [] if name is None else [(name, info)]
        case PList(_, prefix, rest, suffix):
            bindings = [b for e in prefix for b in pattern_bindings(e)]
            if rest is not None and rest.name is not None:
                bindings.append((rest.name, rest.info))
            bindings += [b for e in (suffix or []) for b in pattern_bindings(e)]
            return bindings
        case _:
            return []


def bind_pattern(env, pattern):
    """Extends env with everything pattern binds.
    {String: Binding} -> Pattern -> {String: Binding}"""
    for name, info in pattern_bindings(pattern):
        env = bind(env, name, PATTERN_VAR, info)
    return env


def bind_target(env, target, kind=BINDING):
    """Extends env with every name in an assignment target (which may
    destructure a tuple, `a, b = ...`).
    {String: Binding} -> AssignTarget -> String -> {String: Binding}"""
    match target:
        case TargetName(info, name):
            return bind(env, name, kind, info)
        case TargetTuple(_, elements):
            for element in elements:
                env = bind_target(env, element, kind)
            return env


# --- mutability ---

# The one rule types cannot state: `:=` writes to a name, and only a
# `var` may be written to. Everything else about a name -- that it is
# in scope where it is used, and what it holds -- src/typesystem.py
# settles, so this walk never descends into an expression: no
# expression mutates anything.

def analyze_scope(stmts, env):
    """Analyzes a nested block in env; whatever it binds is not visible
    outside it. [Stmt] -> {String: Binding} -> ()"""
    analyze_stmts(stmts, env)


def bound_names(stmt):
    """The names a statement binds in the block it is written in
    (excludes for/pattern/parameter names, and a def's own name), as
    (name, info) pairs. Stmt -> [(String, Info)]"""
    match stmt:
        case SLet(_, target, _) | SLetStmt(_, target, _):
            return target_names(target)
        case SVar(info, name, _):
            return [(name, info)]
        case SImport(info, _, name, selected, fields):
            # The plain form binds the module's own local name; the
            # `from` form binds each field under the name it is known by
            # here. Both are top-level bindings like any other.
            if selected:
                return [(local, info) for _, local in fields]
            return [(name, info)]
        case _:
            return []


def target_names(target):
    """The (name, info) pairs an assignment target binds.
    AssignTarget -> [(String, Info)]"""
    match target:
        case TargetName(info, name):
            return [(name, info)]
        case TargetTuple(_, elements):
            return [pair for e in elements for pair in target_names(e)]
    return []


def block_functions(stmts):
    """Returns the function definitions (defs) within a block. Raises
    AnalysisError if two defs in the block share a name, or if any other
    binding in the block shares a def's name.
    [Stmt] -> {String: SFunctionDef}"""
    functions = {}
    for stmt in stmts:
        if not isinstance(stmt, SFunctionDef):
            continue
        earlier = functions.get(stmt.name)
        if earlier is not None:
            raise AnalysisError(
                stmt.info,
                f"'{stmt.name}' is already defined as a function in this "
                f"block{where_bound(Binding(FUNCTION, earlier.info))}; a "
                "function name may be defined once per block (a nested block "
                "may shadow it)",
            )
        functions[stmt.name] = stmt
    for stmt in stmts:
        for name, info in bound_names(stmt):
            check_no_function_clash(name, info, functions)
    return functions


def check_no_function_clash(name, info, functions):
    """Raises AnalysisError if name is one of functions' keys.
    String -> Info -> {String: SFunctionDef} -> ()"""
    clash = functions.get(name)
    if clash is not None:
        raise AnalysisError(
            info,
            f"cannot bind '{name}': a function '{name}' is defined in this "
            f"block{where_bound(Binding(FUNCTION, clash.info))}, and a "
            "function's name may not also be bound there (a nested block may "
            "shadow it)",
        )


def analyze_stmts(stmts, env):
    """Analyzes a statement sequence in env, threading the environment
    from one statement to the next; every def in the sequence is bound
    first. Returns the environment left after the last statement.
    [Stmt] -> {String: Binding} -> {String: Binding}"""
    for stmt in block_functions(stmts).values():
        env = bind(env, stmt.name, FUNCTION, stmt.info)
    for stmt in stmts:
        env = analyze_stmt(stmt, env)
    return env


def analyze_value_stmt(stmt, env):
    """Analyzes a value-form if/match/loop (the right-hand side of a
    binding); does not bind the target itself.
    Stmt -> {String: Binding} -> ()"""
    match stmt:
        case SLoop():
            # A loop in value position is analyzed exactly as one written
            # on its own: it binds its accumulator in its own body and
            # nothing in the block around it.
            analyze_stmt(stmt, env)
        case SIf(_, _, then_body, else_body):
            analyze_scope(then_body, env)
            analyze_scope(else_body, env)
        case SMatch(_, _, cases):
            for case_clause in cases:
                analyze_case(case_clause, env)


def analyze_case(case_clause, env):
    """Analyzes one case clause; the pattern's variables are bound in
    the arm's own scope. MatchCase -> {String: Binding} -> ()"""
    case_env = bind_pattern(env, case_clause.pattern)
    analyze_scope(case_clause.body, case_env)


def analyze_stmt(s, env):
    """Analyzes one statement in env. Returns the environment the
    statements after it should see. Stmt -> {String: Binding} -> {String: Binding}"""
    match s:
        case SLet(_, target, _):
            return bind_target(env, target)

        case SLetStmt(_, target, stmt):
            analyze_value_stmt(stmt, env)
            return bind_target(env, target)

        case SVar(info, name, _):
            return bind(env, name, MUTABLE, info)

        case SImport():
            # An import binds names like anything else, so the
            # no-shadowing-a-`var` rule reaches it too. There is nothing
            # inside one to walk.
            for name, info in bound_names(s):
                env = bind(env, name, IMPORTED, info)
            return env

        case SMutate(info, name, _):
            existing = env.get(name)
            if existing is not None and existing.kind == MUTABLE:
                return env
            # The type checker has already refused a name in no scope at
            # all, so a name missing here is one bound where this walk
            # does not follow; either way it is not a `var`.
            what = "not a mutable variable" if existing is None else (
                f"a {existing.kind}{where_bound(existing)}, not a mutable variable"
            )
            raise AnalysisError(
                info,
                f"cannot update '{name}' with ':=': it is {what} (declare it "
                "with 'var' to make it one)",
            )

        case SReturn(_, _) | SExprStmt(_, _) | SBreak(_) | SContinue(_):
            return env

        case SReturnStmt(_, stmt):
            # `return if c:` / `return match e:` -- the branches are
            # ordinary nested scopes, exactly as in `SLetStmt`, and
            # nothing is bound in the enclosing one.
            analyze_value_stmt(stmt, env)
            return env

        case SLoop(_, target, _, _, iterate, body):
            # The accumulator is bound for the body only, exactly as an
            # `=` binding's target is bound for what follows it.
            inner = env
            if target is not None:
                inner = bind_target(env, target, LOOP_VAR)
            match iterate:
                case ForIn(info, name, _, _):
                    analyze_scope(body, bind(inner, name, LOOP_VAR, info))
                case _:
                    analyze_scope(body, inner)
            return env

        case SIf(_, _, then_body, else_body):
            analyze_scope(then_body, env)
            if else_body is not None:
                analyze_scope(else_body, env)
            return env

        case SMatch(_, _, cases):
            for case_clause in cases:
                analyze_case(case_clause, env)
            return env

        case SFunctionSig(_, _, _):
            # A signature says what a `def` in this block is; it binds no
            # name of its own and mentions none, so there is nothing here
            # for this walk to check. `typesystem.py` is what pairs it
            # with its definition.
            return env

        case SFunctionDef(info, name, params, body, _return_type):
            # The function's own name is bound before its body is walked,
            # so a function may call itself; the parameters then bind in
            # the body's scope, shadowing anything but a mutable variable.
            env = bind(env, name, FUNCTION, info)
            body_env = env
            for param in params:
                body_env = bind(body_env, param.name, PARAMETER, param.info)
            analyze_scope(body, body_env)
            return env

        case _:
            raise NotImplementedError(f"no mutability analysis for statement {s!r}")


def analyze_mutability(stmts):
    """Checks that every `:=` names a `var`, and that nothing shadows
    one. Raises AnalysisError on the first problem; never rewrites the
    AST. [Stmt] -> ()

    """
    env = {name: Binding(BUILTIN) for name in BUILTINS}
    analyze_stmts(stmts, env)


# --- symbolize ---


def highest_sym(node):
    """The largest sym anywhere in node, or 0 if none is symbolized --
    which is where the next module's `symbolize` continues from.
    a -> Int"""
    if is_dataclass(node) and hasattr(node, "sym"):
        return max(
            [node.sym]
            + [highest_sym(getattr(node, f.name)) for f in fields(node)]
        )
    if isinstance(node, (list, tuple)):
        return max([0] + [highest_sym(element) for element in node])
    return 0


def symbolize(stmts, start=0):
    """Rebuilds stmts so every node has a unique sym, numbered
    post-order starting after `start` (0 means "not symbolized"). A node
    that already has a symbol keeps it; safe to run more than once. A
    program of several modules passes each module the highest symbol the
    one before it reached, so no two nodes in it share a symbol -- which
    is what lets one call-free table and one type table span the whole
    program. [Stmt] -> Int -> [Stmt]"""
    counter = itertools.count(max(highest_sym(stmts), start) + 1)

    def renumber(node):
        if is_dataclass(node) and hasattr(node, "sym"):
            updated = {
                f.name: renumber(getattr(node, f.name))
                for f in fields(node)
                if f.name != "sym"
            }
            return replace(node, **updated, sym=node.sym or next(counter))
        if isinstance(node, list):
            return [renumber(element) for element in node]
        if isinstance(node, tuple):
            return tuple(renumber(element) for element in node)
        return node

    return [renumber(s) for s in stmts]


def apply_signatures(stmts):
    """stmts with every `def name : type` line folded into the
    definition it describes and then removed, wherever one is written.

    A signature is another way of writing the annotations a `def` header
    could have carried, so moving them onto the header leaves one shape
    for every later stage to read: a backend that refuses a type it
    cannot represent, or infers from the ones it is given, needs to know
    nothing about signatures at all. Like `symbolize` this rebuilds
    rather than mutates, and is generic over dataclass fields so a new
    node needs nothing here.

    Only well-formed pairings are folded; a signature naming no
    definition, or one of the wrong arity, is left for typesystem.py to
    refuse in its own words. [Stmt] -> [Stmt]"""

    def annotated(node, signature):
        """A definition carrying the types its signature gave it.
        The quantifier is dropped: the parts written on a header are
        quantified again wherever they are read.
        SFunctionDef -> Type -> SFunctionDef"""
        written = signature.body if isinstance(signature, TForall) else signature
        if not isinstance(written, TFunction) \
                or len(written.params) != len(node.params):
            return node
        return replace(
            node,
            params=[replace(p, type=t)
                    for p, t in zip(node.params, written.params)],
            return_type=written.result,
        )

    def apply(node):
        if isinstance(node, list):
            signatures = {s.name: s for s in node
                          if isinstance(s, SFunctionSig)}
            out = []
            for item in node:
                if isinstance(item, SFunctionSig):
                    continue
                if isinstance(item, SFunctionDef) and item.name in signatures:
                    signature = signatures[item.name]
                    item = annotated(item, signature.type)
                    # `public` on either line exports the definition, so
                    # the one on the signature comes with the types.
                    if signature.public and not item.public:
                        item = replace(item, public=True)
                out.append(apply(item))
            return out
        if isinstance(node, tuple):
            return tuple(apply(item) for item in node)
        if is_dataclass(node):
            return replace(node, **{f.name: apply(getattr(node, f.name))
                                    for f in fields(node)})
        return node

    return apply(stmts)


# --- effects ---
#
# Says which expressions can produce output, since that is the only
# thing a host language's unspecified evaluation order can make
# observably different from Pyking's left-to-right. Deliberately
# conservative: overestimating who prints costs a temporary, and
# underestimating prints in the wrong order. Used by the backends whose
# host does not fix the order (docs/target_ocaml.md and
# docs/target_c.md, "Evaluation order").


def walk(node):
    """Every node in a tree, the tree itself included; generic over
    dataclass fields. Expr|Stmt|[Stmt] -> (Expr|Stmt,)"""
    if isinstance(node, (list, tuple)):
        for item in node:
            yield from walk(item)
    elif is_dataclass(node):
        yield node
        for f in fields(node):
            yield from walk(getattr(node, f.name))


def all_functions(stmts):
    """Every def in a program, at any depth, by name. [Stmt] ->
    {String: SFunctionDef}"""
    functions = {}
    for node in walk(stmts):
        if isinstance(node, SFunctionDef):
            functions[node.name] = node
    return functions


class Effects:
    """Which calls in a program can end up printing, by a fixed-point
    walk of the call graph. A call whose target is not a known def is
    treated as printing if any function in the program does, and a call
    into another module always is: this walk sees one module."""

    def __init__(self, stmts):
        """Computes self.printing (function names that print) and
        self.unknown_prints (whether an unknown callee must be assumed
        to) by iterating to a fixed point. [Stmt] -> Effects"""
        self.functions = all_functions(stmts)
        self.printing = set()
        self.unknown_prints = False
        changed = True
        while changed:
            changed = False
            for name, func in self.functions.items():
                if name not in self.printing and self._body_prints(func):
                    self.printing.add(name)
                    changed = True
            if self.printing and not self.unknown_prints:
                self.unknown_prints = True
                changed = True

    def _body_prints(self, func):
        """Whether func's body contains a call that may print, given
        self.printing so far. SFunctionDef -> Bool"""
        for node in walk(func):
            if isinstance(node, ECall) and self._call_prints(node):
                return True
        return False

    def _call_prints(self, call):
        """Whether call may print, given self.printing so far. ECall ->
        Bool"""
        match call.func:
            case EVar(_, name, _):
                if runtime_interface.lookup(name) is not None:
                    return True
                if name in BUILTINS:
                    return False
                if name in self.functions:
                    return name in self.printing
            case EQualified():
                # Another module's, and this walk sees only this one --
                # so the conservative answer, which is what the whole
                # class gives where it cannot see a body.
                return True
        return self.unknown_prints

    def may_print(self, expr):
        """Whether evaluating expr can produce output. Expr -> Bool"""
        return any(
            isinstance(node, ECall) and self._call_prints(node)
            for node in walk(expr)
        )
