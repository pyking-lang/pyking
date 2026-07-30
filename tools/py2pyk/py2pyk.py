#!/usr/bin/env python3
"""py2pyk: translate a subset of Python source into Pyking source.

Usage:

    python3 py2pyk.py foo.py            # writes foo.pyk
    python3 py2pyk.py foo.py -o out.pyk # writes out.pyk
    python3 py2pyk.py foo.py --stdout   # prints the translation instead

Parsing is done with Python's own `ast` module (the standard library's
parser for Python itself -- there is no reason to hand-write another one
here). Everything downstream -- picking which constructs Pyking can
express, deciding where Python's implicit function-scoped mutation needs
Pyking's explicit `var`/`:=`, and printing Pyking's own syntax -- is
specific to this tool and lives entirely in this file. It does not import
anything from `boot/`, and it does not modify anything outside
`tools/py2pyk/`; see `tools/py2pyk/README.md` for what is and is not
supported and why.
"""

import argparse
import ast
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

class UnsupportedFeature(Exception):
    """Raised for any Python construct py2pyk does not translate. Carries
    the offending node so the CLI can report a source position, the way
    `boot/`'s own LexError/ParseError/AnalysisError do for Pyking source."""

    def __init__(self, node, message):
        self.node = node
        self.message = message
        self.lineno = getattr(node, "lineno", None)
        self.col_offset = getattr(node, "col_offset", None)
        super().__init__(message)

    def format(self, filename):
        if self.lineno is not None and self.col_offset is not None:
            loc = f"{filename}:{self.lineno}:{self.col_offset + 1}"
        elif self.lineno is not None:
            loc = f"{filename}:{self.lineno}"
        else:
            loc = filename
        return f"{loc}: unsupported: {self.message}"


def unsupported(node, message):
    raise UnsupportedFeature(node, message)


# ---------------------------------------------------------------------------
# Scope: mirrors Pyking's own name-scoping rules (boot/analyses.py), kept as
# an independent re-implementation rather than an import, so py2pyk works
# standalone and never reaches into boot/'s internals. Doing this analysis
# ourselves, on the Python source positions, gives errors that point at the
# *Python* line the trouble is on, rather than round-tripping through
# pykboot.
# ---------------------------------------------------------------------------

BUILTIN_NAMES = ("print", "range", "str", "len")

MUTABLE = "mutable variable"
BINDING = "binding"
PARAMETER = "parameter"
LOOP_VAR = "loop variable"
PATTERN_VAR = "pattern variable"
FUNCTION = "function"
BUILTIN = "builtin"


class Scope:
    """One node of the lexical scope chain. `child()` opens a nested scope
    (an if/for/while/def body); its bindings are simply never merged back
    into the parent, which is what makes them disappear on the way out --
    the same trick boot/analyses.py plays with a plain dict."""

    def __init__(self, parent=None):
        self.parent = parent
        self.names = {}

    def child(self):
        return Scope(self)

    def lookup(self, name):
        """The *kind* a name is bound as (see the MUTABLE/BINDING/...
        constants), or None if it isn't in scope."""
        s = self
        while s is not None:
            if name in s.names:
                return s.names[name][0]
            s = s.parent
        return None

    def is_bound(self, name):
        return self.lookup(name) is not None

    def bind(self, name, kind, node):
        s = self
        while s is not None:
            existing = s.names.get(name)
            if existing is not None and existing[0] == MUTABLE:
                unsupported(
                    node,
                    f"cannot bind '{name}': a mutable variable '{name}' "
                    f"(from line {existing[1]}) is already in scope, and Pyking "
                    "does not allow shadowing a mutable variable -- update it "
                    "with ':=' or choose another name",
                )
            s = s.parent
        self.names[name] = (kind, getattr(node, "lineno", "?"))

    def check_bound(self, name, node):
        if not self.is_bound(name):
            unsupported(
                node,
                f"name '{name}' is not bound at this point -- Pyking only sees "
                "what was already defined earlier in the enclosing scope "
                "(no forward references, no calling a function defined later, "
                "no mutual recursion between two separate functions)",
            )


def new_root_scope():
    root = Scope()
    for name in BUILTIN_NAMES:
        root.names[name] = (BUILTIN, None)
    return root


# ---------------------------------------------------------------------------
# Small helpers over the Python AST
# ---------------------------------------------------------------------------

def flatten_target_names(target):
    """Names bound by an assignment target (Name, or nested Tuple/List of
    Names), in left-to-right order, as (name, node) pairs. Anything else
    (Attribute, Subscript, Starred) is not a name-binding target Pyking can
    express and is rejected by the caller before this is used."""
    if isinstance(target, ast.Name):
        return [(target.id, target)]
    if isinstance(target, (ast.Tuple, ast.List)):
        out = []
        for elt in target.elts:
            out.extend(flatten_target_names(elt))
        return out
    unsupported(
        target,
        "an assignment target must be a plain name or a (possibly nested) "
        "tuple/list of names -- Pyking's '=' can only destructure tuples of "
        "names, not attributes, subscripts, or starred targets",
    )


def target_shape_key(target):
    """A hashable description of a target's *shape* (nesting of names),
    ignoring the names themselves -- used to check that every branch of a
    value-form-if candidate destructures the same way."""
    if isinstance(target, ast.Name):
        return "name"
    if isinstance(target, (ast.Tuple, ast.List)):
        return tuple(target_shape_key(e) for e in target.elts)
    return None


def is_elif_chain(if_node):
    """True if `if_node.orelse` is exactly Python's encoding of an
    `elif ...:` (a single nested `If`), as opposed to a real `else:`."""
    return len(if_node.orelse) == 1 and isinstance(if_node.orelse[0], ast.If)


def flatten_if_chain(if_node):
    """An `if`/`elif`/.../`else` ladder as (list of (test, body) branches,
    final_else_body_or_None) -- mirrors how Pyking's own parser flattens
    the identical nested-If shape when printing `else if`."""
    branches = []
    node = if_node
    while True:
        branches.append((node.test, node.body))
        if is_elif_chain(node):
            node = node.orelse[0]
            continue
        final_else = node.orelse if node.orelse else None
        return branches, final_else


# ---------------------------------------------------------------------------
# Classification pass: for every name assigned inside one Python function
# (or the module top level), decide whether Pyking needs a plain '='
# binding, a 'var'/':=' pair, or the value-form 'if' construct.
#
# Every block Pyking's grammar treats as its own scope (an if/elif/else
# branch, a for body, a while body) is *not* a scope in Python -- a name
# assigned inside one is visible to the rest of the enclosing function.
# Reproducing that without turning every such name into a `var` is the
# whole reason this pass exists; see the README for the algorithm in
# prose and worked examples.
# ---------------------------------------------------------------------------

class FunctionInfo:
    """The result of classifying one function (or the module) body:
    `var_names`: names that need 'var'/':=' rather than plain '='.
    `var_decl_node`: for each var name, the id() of the assignment node
        that becomes its 'var name = ...' declaration (every other
        assignment to it becomes ':=').
    `valueif_targets`: id(if_node) -> list of names that `if` supplies as
        a value-form binding (so the caller must not also translate its
        branches' tail assignments as ordinary statements).
    `valueif_owner`: name -> id(if_node) it is supplied by.
    `errors` is not populated here; classification raises immediately via
    `unsupported` when a name's assignments can't be reconciled at all.
    """

    def __init__(self):
        self.var_names = set()
        self.var_decl_node = {}
        self.valueif_targets = {}
        self.valueif_owner = {}


def _common_prefix(paths):
    if not paths:
        return ()
    shortest = min(paths, key=len)
    prefix = []
    for i in range(len(shortest)):
        val = shortest[i]
        if all(len(p) > i and p[i] == val for p in paths):
            prefix.append(val)
        else:
            break
    return tuple(prefix)


def classify_function(body):
    """`body`: the list of statements making up one function's (or the
    module's) top-level block. Does not descend into nested `def`s -- each
    gets its own independent `classify_function` call when the translator
    reaches it."""

    occurrences = {}     # name -> list of ("load"|"store"|"augstore", path, node, stmt)
    path_to_stmts = {}    # path -> the actual statement list at that path
    next_id = [0]

    def fresh():
        next_id[0] += 1
        return next_id[0]

    def record(name, kind, path, node, stmt):
        occurrences.setdefault(name, []).append((kind, path, node, stmt))

    def record_loads(expr, path):
        if expr is None:
            return
        for node in ast.walk(expr):
            if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
                record(node.id, "load", path, node, None)

    def scan_block(stmts, path):
        path_to_stmts[path] = stmts
        for stmt in stmts:
            scan_stmt(stmt, path)

    def scan_stmt(stmt, path):
        if isinstance(stmt, ast.Assign):
            record_loads(stmt.value, path)
            if len(stmt.targets) == 1:
                for name, node in flatten_target_names(stmt.targets[0]):
                    record(name, "store", path, node, stmt)
        elif isinstance(stmt, ast.AnnAssign):
            if stmt.value is not None and isinstance(stmt.target, ast.Name):
                record_loads(stmt.value, path)
                record(stmt.target.id, "store", path, stmt.target, stmt)
        elif isinstance(stmt, ast.AugAssign):
            record_loads(stmt.value, path)
            if isinstance(stmt.target, ast.Name):
                record(stmt.target.id, "augstore", path, stmt.target, stmt)
        elif isinstance(stmt, ast.For):
            record_loads(stmt.iter, path)
            child = path + (fresh(),)
            for name, node in flatten_target_names(stmt.target):
                record(name, "forstore", child, node, stmt)
            scan_block(stmt.body, child)
        elif isinstance(stmt, ast.While):
            record_loads(stmt.test, path)
            child = path + (fresh(),)
            scan_block(stmt.body, child)
        elif isinstance(stmt, ast.If):
            record_loads(stmt.test, path)
            then_path = path + (fresh(),)
            scan_block(stmt.body, then_path)
            if stmt.orelse:
                else_path = path + (fresh(),)
                scan_block(stmt.orelse, else_path)
        elif isinstance(stmt, ast.Return):
            record_loads(stmt.value, path)
        elif isinstance(stmt, ast.Expr):
            record_loads(stmt.value, path)
        elif isinstance(stmt, ast.FunctionDef):
            record(stmt.name, "store", path, stmt, stmt)
            # Nested def bodies are classified independently later; a
            # closure only *reads* an enclosing var (Python has no
            # implicit write-through without 'nonlocal', which py2pyk
            # rejects), so skipping them here cannot hide a needed
            # promotion -- see README "Variable classification".
        # Anything else is left to the real translation pass to accept or
        # reject; classification is best-effort and only needs to be
        # right about the constructs it recognizes above.

    scan_block(body, ())

    info = FunctionInfo()

    def path_within(path, ancestor):
        return path[:len(ancestor)] == ancestor

    for name, occs in occurrences.items():
        forstores = [o for o in occs if o[0] == "forstore"]
        if forstores:
            # A 'for' loop's own target is scoped to its body alone in
            # Pyking (unlike Python, where it leaks into the rest of the
            # enclosing function) -- see PYKING.md "Names and scoping" and
            # analyses.py's SFor case. Every other occurrence of this name
            # (read, write, or another loop reusing it) must fall inside
            # one of the loop bodies that bind it as their target, or
            # there is no faithful translation.
            loop_paths = [o[1] for o in forstores]
            outside = [
                o for o in occs
                if o[0] != "forstore" and not any(path_within(o[1], lp) for lp in loop_paths)
            ]
            if outside:
                lines = sorted({o[3].lineno for o in forstores})
                bad_lines = sorted({o[2].lineno for o in outside})
                unsupported(
                    outside[0][2],
                    f"'{name}' is used on line(s) {', '.join(map(str, bad_lines))}, "
                    f"outside the 'for' loop(s) on line(s) {', '.join(map(str, lines))} "
                    f"that bind it as their loop variable -- Pyking's 'for' variable is "
                    "scoped to the loop body only and never leaks (unlike Python's); "
                    "use a different name for the loop variable, or (to keep the last "
                    "value) assign it to a separate 'var' as the last statement of the loop body",
                )

        assigns = [o for o in occs if o[0] in ("store", "augstore")]
        if not assigns:
            continue  # read-only (a parameter, a loop variable, ...)
        all_paths = [o[1] for o in occs]
        lca = _common_prefix(all_paths)
        lca_assigns = [o for o in assigns if o[1] == lca]
        deeper_assigns = [o for o in assigns if o[1] != lca]
        has_aug = any(o[0] == "augstore" for o in assigns)

        if not deeper_assigns and not has_aug:
            continue  # every assignment is a plain '=' at the same block

        if lca_assigns:
            # A definition unconditionally reached at the LCA's own level
            # exists -- promote to 'var', declared there.
            first = min(lca_assigns, key=lambda o: o[3].lineno)
            info.var_names.add(name)
            info.var_decl_node[name] = id(first[3])
            continue

        if has_aug:
            unsupported(
                assigns[0][3],
                f"'{name}' is updated with an augmented assignment but is "
                "never given an initial value that unconditionally runs "
                "before it -- Pyking's 'var' needs an initializer",
            )

        # CASE C: every assignment to `name` is nested strictly deeper than
        # its LCA -- the only shape py2pyk can still express without a
        # 'var' is an exhaustive if/elif/.../else whose every branch ends
        # by assigning exactly this name (Pyking's value-form 'if').
        owning_if = _find_valueif_owner(path_to_stmts.get(lca, []), name, deeper_assigns)
        if owning_if is None:
            lines = sorted({o[3].lineno for o in deeper_assigns})
            unsupported(
                deeper_assigns[0][3],
                f"'{name}' is only assigned conditionally (on line(s) "
                f"{', '.join(map(str, lines))}) and is used outside that "
                "conditional -- Pyking has no uninitialized 'var', and this "
                "isn't a plain if/elif/.../else that assigns it in every "
                "branch (which py2pyk could bind with a value-form 'if'); "
                "give it a default value before the conditional",
            )
        info.valueif_targets.setdefault(id(owning_if), []).append(name)
        info.valueif_owner[name] = id(owning_if)

    return info


def _find_valueif_owner(lca_stmts, name, deeper_assigns):
    """Search the statements directly in `name`'s LCA block for a single
    if/elif/.../else statement whose every branch ends in an assignment to
    `name` (same target shape throughout), covering exactly the deeper
    assignments recorded for it. Returns that `ast.If` node, or None."""
    wanted_nodes = {id(o[3]) for o in deeper_assigns}
    for stmt in lca_stmts:
        if not isinstance(stmt, ast.If):
            continue
        branches, final_else = flatten_if_chain(stmt)
        if final_else is None:
            continue
        bodies = [body for _, body in branches] + [final_else]
        tails = []
        shape = None
        ok = True
        for body in bodies:
            if not body or not isinstance(body[-1], ast.Assign):
                ok = False
                break
            assign = body[-1]
            if len(assign.targets) != 1:
                ok = False
                break
            try:
                names = [n for n, _ in flatten_target_names(assign.targets[0])]
            except UnsupportedFeature:
                ok = False
                break
            if name not in names:
                ok = False
                break
            this_shape = target_shape_key(assign.targets[0])
            if shape is None:
                shape = this_shape
            elif this_shape != shape:
                ok = False
                break
            tails.append(assign)
        if not ok:
            continue
        if {id(t) for t in tails} == wanted_nodes:
            return stmt
    return None


# ---------------------------------------------------------------------------
# Expression translation
# ---------------------------------------------------------------------------

BINOP_SYMBOLS = {ast.Add: ("+", 2), ast.Sub: ("-", 2), ast.Mult: ("*", 3), ast.Div: ("/", 3)}
BINOP_UNSUPPORTED = {
    ast.Mod: "'%%' (modulo) has no Pyking operator (only +, -, *, /)",
    ast.FloorDiv: "'//' (floor division) has no Pyking operator ('/' is true "
                  "division, matching Python's own '/')",
    ast.Pow: "'**' (power) has no Pyking operator",
    ast.BitOr: "'|' has no Pyking operator (no bitwise operators at all)",
    ast.BitAnd: "'&' has no Pyking operator (no bitwise operators at all)",
    ast.BitXor: "'^' has no Pyking operator (no bitwise operators at all)",
    ast.LShift: "'<<' has no Pyking operator (no bitwise operators at all)",
    ast.RShift: "'>>' has no Pyking operator (no bitwise operators at all)",
    ast.MatMult: "'@' has no Pyking operator",
}

COMPARE_SYMBOLS = {
    ast.Lt: "<", ast.LtE: "<=", ast.Gt: ">", ast.GtE: ">=", ast.Eq: "==",
}
COMPARE_UNSUPPORTED = {
    ast.NotEq: "'!=' has no Pyking operator (Pyking has <, <=, >, >=, == only)",
    ast.Is: "'is' has no Pyking operator",
    ast.IsNot: "'is not' has no Pyking operator",
    ast.In: "'in' as a boolean test has no Pyking operator (it is only "
            "meaningful in a 'for' header or a comprehension here)",
    ast.NotIn: "'not in' has no Pyking operator",
}

def _wrap(prec, min_prec, text):
    return f"({text})" if prec < min_prec else text


def translate_type(node):
    """Best-effort mapping of a Python annotation to a Pyking type. Returns
    None (meaning: omit the annotation) for anything not immediately
    obvious -- annotations are erased by every Pyking backend anyway (see
    PYKING.md "Type annotations"), so dropping one is always safe."""
    if node is None:
        return None
    if isinstance(node, ast.Constant) and node.value is None:
        return "()"
    if isinstance(node, ast.Name):
        return {"int": "Int", "str": "String", "bool": "Bool"}.get(node.id)
    if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name):
        base = node.value.id
        if base == "list":
            inner = translate_type(node.slice)
            return f"[{inner}]" if inner else None
        if base == "tuple":
            elts = node.slice.elts if isinstance(node.slice, ast.Tuple) else [node.slice]
            inners = [translate_type(e) for e in elts]
            if any(i is None for i in inners):
                return None
            return f"({', '.join(inners)})"
    return None


class ExprTranslator:
    def __init__(self, scope):
        self.scope = scope

    def name_ref(self, node):
        self.scope.check_bound(node.id, node)
        return node.id

    def translate(self, node, min_prec=0):
        method = getattr(self, f"_t_{type(node).__name__}", None)
        if method is None:
            unsupported(node, f"the '{type(node).__name__}' expression form is not supported")
        return method(node, min_prec)

    def _t_Constant(self, node, min_prec):
        v = node.value
        if isinstance(v, bool):
            # Pyking has no boolean literal syntax, but comparisons do
            # produce real Bool values (see PYKING.md / runtime_interface's
            # print formatting), so a self-evidently-true/false comparison
            # stands in for the literal -- see README "True/False/None".
            return "(1 == 1)" if v else "(1 == 2)"
        if isinstance(v, int):
            return str(v)
        if isinstance(v, str):
            return _quote_pyking_string(v)
        if v is None:
            unsupported(node, "'None' has no Pyking equivalent (no null/optional value)")
        if isinstance(v, float):
            unsupported(node, "float literals are not supported (Pyking has no floating-point type)")
        unsupported(node, f"literal of type {type(v).__name__} is not supported")

    def _t_Name(self, node, min_prec):
        if not isinstance(node.ctx, ast.Load):
            unsupported(node, "a name may only be read here, not assigned")
        return self.name_ref(node)

    def _t_BinOp(self, node, min_prec):
        op_type = type(node.op)
        if op_type in BINOP_UNSUPPORTED:
            unsupported(node, BINOP_UNSUPPORTED[op_type])
        if op_type not in BINOP_SYMBOLS:
            unsupported(node, f"the '{op_type.__name__}' operator is not supported")
        sym, prec = BINOP_SYMBOLS[op_type]
        left = self.translate(node.left, prec)
        right = self.translate(node.right, prec + 1)
        return _wrap(prec, min_prec, f"{left} {sym} {right}")

    def _t_UnaryOp(self, node, min_prec):
        if isinstance(node.op, ast.USub):
            operand = self.translate(node.operand, 5)
            return _wrap(4, min_prec, f"-{operand}")
        if isinstance(node.op, ast.UAdd):
            return self.translate(node.operand, min_prec)
        if isinstance(node.op, ast.Not):
            unsupported(
                node,
                "'not' has no Pyking operator; rewrite the surrounding "
                "condition using the complementary comparison "
                "(e.g. 'not (a < b)' as 'a >= b') or nested 'if' statements",
            )
        unsupported(node, "this unary operator is not supported")

    def _t_BoolOp(self, node, min_prec):
        word = "and" if isinstance(node.op, ast.And) else "or"
        unsupported(
            node,
            f"'{word}' has no Pyking operator (Pyking has no boolean "
            "connectives at all, only the comparison operators <, <=, >, "
            f">=, =='); rewrite using nested 'if' statements",
        )

    def _t_Compare(self, node, min_prec):
        if len(node.ops) != 1:
            unsupported(node, "chained comparisons (e.g. 'a < b < c') are not "
                               "supported -- Pyking's comparisons don't chain; "
                               "write them out as separate comparisons")
        op_type = type(node.ops[0])
        if op_type in COMPARE_UNSUPPORTED:
            unsupported(node, COMPARE_UNSUPPORTED[op_type])
        if op_type not in COMPARE_SYMBOLS:
            unsupported(node, f"the '{op_type.__name__}' comparison is not supported")
        sym = COMPARE_SYMBOLS[op_type]
        left = self.translate(node.left, 2)
        right = self.translate(node.comparators[0], 2)
        return _wrap(1, min_prec, f"{left} {sym} {right}")

    def _t_IfExp(self, node, min_prec):
        cond = self.translate(node.test, 0)
        body = self.translate(node.body, 0)
        orelse = self.translate(node.orelse, 0)
        # Always self-parenthesized: it's always valid here, and it's the
        # one place PYKING.md documents as sometimes *required* (a
        # comprehension's own 'if'/'in'); see the grammar notes on if_expr.
        return f"(if {cond} then {body} else {orelse})"

    def _t_Call(self, node, min_prec):
        if not isinstance(node.func, ast.Name):
            unsupported(
                node,
                "only calls to a plain name are supported -- Pyking has no "
                "attribute access, so a method call ('x.f()') or a call "
                "through a subscript/attribute expression cannot be translated",
            )
        name = node.func.id
        if node.keywords:
            unsupported(node, "keyword arguments are not supported -- Pyking's "
                               "call syntax is positional-only")
        args = []
        for a in node.args:
            if isinstance(a, ast.Starred):
                unsupported(a, "'*args' unpacking in a call is not supported")
            args.append(self.translate(a, 0))
        if name not in BUILTIN_NAMES:
            self.scope.check_bound(name, node.func)
            if self.scope.lookup(name) != FUNCTION:
                unsupported(node, f"'{name}' is not a function -- it cannot be called")
        return f"{name}({', '.join(args)})"

    def _t_List(self, node, min_prec):
        elts = []
        for e in node.elts:
            if isinstance(e, ast.Starred):
                unsupported(e, "'*' unpacking inside a list literal is not supported")
            elts.append(self.translate(e, 0))
        return f"[{', '.join(elts)}]"

    def _t_Tuple(self, node, min_prec):
        if not node.elts:
            return "()"
        elts = []
        for e in node.elts:
            if isinstance(e, ast.Starred):
                unsupported(e, "'*' unpacking inside a tuple literal is not supported")
            elts.append(self.translate(e, 0))
        if len(elts) == 1:
            return f"({elts[0]},)"
        return f"({', '.join(elts)})"

    def _t_ListComp(self, node, min_prec):
        comp_scope = self.scope.child()
        comp_translator = ExprTranslator(comp_scope)
        clauses = []
        for i, gen in enumerate(node.generators):
            if gen.is_async:
                unsupported(gen, "'async for' in a comprehension is not supported")
            # The first generator's iterable is evaluated in the enclosing
            # scope (matching Pyking's own EListComp semantics); later ones
            # already see earlier generators' pattern variables.
            iter_scope = self.scope if i == 0 else comp_scope
            iter_translator = ExprTranslator(iter_scope) if i == 0 else comp_translator
            seq = iter_translator.translate(gen.iter, 0)
            pattern = translate_pattern(gen.target, comp_scope)
            clauses.append(f"for {pattern} in {seq}")
            for cond in gen.ifs:
                clauses.append(f"if {comp_translator.translate(cond, 0)}")
        elt = comp_translator.translate(node.elt, 0)
        return f"[{elt} {' '.join(clauses)}]"


def _quote_pyking_string(s):
    escapes = {"\\": "\\\\", "'": "\\'", "\n": "\\n", "\t": "\\t", "\r": "\\r"}
    body = "".join(escapes.get(ch, ch) for ch in s)
    return f"'{body}'"


def translate_pattern(target, scope):
    """A comprehension target -- Name or nested Tuple/List -- as a Pyking
    pattern, binding each captured name into `scope` (comprehensions are
    their own scope, matching Pyking's EListComp)."""
    if isinstance(target, ast.Name):
        scope.bind(target.id, PATTERN_VAR, target)
        return target.id
    if isinstance(target, (ast.Tuple, ast.List)):
        if isinstance(target, ast.List):
            unsupported(
                target,
                "a list-shaped comprehension target ('[a, b] for ... in ...') "
                "is not supported by py2pyk; Pyking's comprehension patterns "
                "distinguish list patterns from tuple patterns and Python's "
                "own comprehension targets don't carry that distinction "
                "syntactically -- use a plain name or a tuple target instead",
            )
        parts = [translate_pattern(e, scope) for e in target.elts]
        return f"({', '.join(parts)})"
    unsupported(target, "a comprehension target must be a name or a nested tuple of names")


# ---------------------------------------------------------------------------
# Statement translation
# ---------------------------------------------------------------------------

INDENT = "    "


class FunctionTranslator:
    """Translates one function body (or the module top level). Holds the
    `FunctionInfo` classification for *this* function only -- a nested
    `def` gets its own `FunctionTranslator` over its own `FunctionInfo`."""

    def __init__(self, info):
        self.info = info

    def block(self, stmts, scope, level):
        lines = []
        for stmt in stmts:
            lines.extend(self.stmt(stmt, scope, level))
        if not lines:
            unsupported(stmts[0] if stmts else ast.Module(body=[], type_ignores=[]),
                        "an empty block has no Pyking equivalent")
        return lines

    def expr_of(self, scope):
        return ExprTranslator(scope)

    def stmt(self, node, scope, level):
        method = getattr(self, f"_s_{type(node).__name__}", None)
        if method is None:
            unsupported(node, f"the '{type(node).__name__}' statement form is not supported")
        return method(node, scope, level)

    def _pad(self, level):
        return INDENT * level

    # -- assignment family --------------------------------------------

    def _emit_target(self, target):
        if isinstance(target, ast.Name):
            return target.id
        if isinstance(target, (ast.Tuple, ast.List)):
            parts = [self._emit_target(e) for e in target.elts]
            return f"({', '.join(parts)})" if len(target.elts) != 1 else f"({parts[0]},)"
        unsupported(target, "unsupported assignment target")

    def _assign_like(self, name_kind_node, target, value_text, scope, level, source_node):
        """Emit the right Pyking statement for one assignment to a single
        Name, given this function's classification of that name."""
        pad = self._pad(level)
        if name_kind_node in self.info.var_names:
            if self.info.var_decl_node[name_kind_node] == id(source_node):
                scope.bind(name_kind_node, MUTABLE, source_node)
                return [f"{pad}var {name_kind_node} = {value_text}"]
            kind = scope.lookup(name_kind_node)
            if kind != MUTABLE:
                unsupported(
                    source_node,
                    f"'{name_kind_node}' was classified as needing 'var' but is "
                    "not yet in scope as one here -- likely an update reachable "
                    "before its own initializer runs",
                )
            return [f"{pad}{name_kind_node} := {value_text}"]
        scope.bind(name_kind_node, BINDING, source_node)
        return [f"{pad}{name_kind_node} = {value_text}"]

    def _s_Assign(self, node, scope, level):
        if len(node.targets) != 1:
            unsupported(node, "chained assignment ('a = b = value') is not "
                               "supported -- assign one target per statement")
        target = node.targets[0]
        et = self.expr_of(scope)
        value_text = et.translate(node.value, 0)
        return self._emit_assign_target(target, value_text, scope, level, node)

    def _s_AnnAssign(self, node, scope, level):
        if node.value is None:
            unsupported(node, "a variable declaration with no value ('x: int') "
                               "has no Pyking equivalent -- every binding needs a value")
        if not isinstance(node.target, ast.Name):
            unsupported(node, "an annotated assignment target must be a plain name")
        et = self.expr_of(scope)
        value_text = et.translate(node.value, 0)
        return self._emit_assign_target(node.target, value_text, scope, level, node)

    def _emit_assign_target(self, target, value_text, scope, level, node):
        pad = self._pad(level)
        names = flatten_target_names(target)
        if isinstance(target, ast.Name):
            name, _ = names[0]
            return self._assign_like(name, target, value_text, scope, level, node)
        # A Tuple/List target -- even a singleton like '(h,) = (99,)' --
        # always needs real destructuring syntax; only a bare ast.Name
        # target can take the direct-bind fast path above.
        # Tuple/list destructuring: none of the destructured names can
        # individually be a promoted 'var' (classification only promotes
        # single-Name assignments), so this is always a plain binding.
        for name, n in names:
            if name in self.info.var_names:
                unsupported(
                    n,
                    f"'{name}' is destructured here but is also reassigned "
                    "elsewhere across a block boundary -- py2pyk cannot mix "
                    "tuple destructuring with 'var' promotion for the same name",
                )
            scope.bind(name, BINDING, n)
        target_text = self._emit_target(target)
        return [f"{pad}{target_text} = {value_text}"]

    def _s_AugAssign(self, node, scope, level):
        if not isinstance(node.target, ast.Name):
            unsupported(node, "an augmented assignment target must be a plain name "
                               "(no attribute or subscript targets)")
        name = node.target.id
        op_type = type(node.op)
        if op_type in BINOP_UNSUPPORTED:
            unsupported(node, BINOP_UNSUPPORTED[op_type])
        if op_type not in BINOP_SYMBOLS:
            unsupported(node, f"'{op_type.__name__}=' has no Pyking equivalent")
        sym, _ = BINOP_SYMBOLS[op_type]
        scope.check_bound(name, node.target)
        if scope.lookup(name) != MUTABLE:
            unsupported(
                node,
                f"'{name} {sym}=' updates '{name}' in place, which requires it "
                f"to be a Pyking 'var'; py2pyk did not classify it as one -- "
                "it needs an unconditional plain assignment before this point",
            )
        et = self.expr_of(scope)
        rhs = et.translate(node.value, 2 if sym in ("+", "-") else 3)
        pad = self._pad(level)
        return [f"{pad}{name} := {name} {sym} {rhs}"]

    # -- control flow -----------------------------------------------

    def _s_Return(self, node, scope, level):
        if node.value is None:
            unsupported(node, "a bare 'return' (no value) has no Pyking "
                               "equivalent -- 'return' always takes a value")
        et = self.expr_of(scope)
        value = et.translate(node.value, 0)
        return [f"{self._pad(level)}return {value}"]

    def _s_Expr(self, node, scope, level):
        et = self.expr_of(scope)
        value = et.translate(node.value, 0)
        return [f"{self._pad(level)}{value}"]

    def _s_Pass(self, node, scope, level):
        unsupported(node, "'pass' has no Pyking equivalent (there is no "
                           "empty/no-op statement); remove it or give the "
                           "block real content")

    def _s_Break(self, node, scope, level):
        unsupported(node, "'break' is not supported -- Pyking's grammar has "
                           "no loop-exit statement; rewrite the loop condition "
                           "(e.g. a 'while' whose condition covers the exit case)")

    def _s_Continue(self, node, scope, level):
        unsupported(node, "'continue' is not supported -- Pyking's grammar has "
                           "no loop-continuation statement; rewrite using 'if'/"
                           "'else' to skip the rest of the body instead")

    def _s_If(self, node, scope, level):
        owned = self.info.valueif_targets.get(id(node))
        if owned:
            return self._value_if(node, owned, scope, level)
        pad = self._pad(level)
        lines = [f"{pad}if {self.expr_of(scope).translate(node.test, 0)}:"]
        lines.extend(self.block(node.body, scope.child(), level + 1))
        node2 = node
        while node2.orelse:
            if is_elif_chain(node2):
                node2 = node2.orelse[0]
                lines.append(f"{pad}else if {self.expr_of(scope).translate(node2.test, 0)}:")
                lines.extend(self.block(node2.body, scope.child(), level + 1))
                continue
            lines.append(f"{pad}else:")
            lines.extend(self.block(node2.orelse, scope.child(), level + 1))
            break
        return lines

    def _value_if(self, node, names, scope, level):
        # An exhaustive if/elif/.../else whose every branch ends by
        # assigning the same name(s) -- classify_function only reaches
        # here after confirming that shape (see _find_valueif_owner) --
        # translates to Pyking's value-form 'if': one binding statement
        # whose branches supply the value instead of assigning it
        # themselves (see PYKING.md "if/match statements as bound values").
        pad = self._pad(level)
        inner = level + 1
        branches, final_else = flatten_if_chain(node)
        target_node = branches[0][1][-1].targets[0]
        target_text = self._emit_target(target_node)

        def branch_lines(test, body, header_word):
            branch_scope = scope.child()
            # The condition itself is evaluated in the outer scope, not
            # the branch's own (branch_scope isn't bound to anything yet).
            header = (f"{self._pad(inner)}{header_word} {self.expr_of(scope).translate(test, 0)}:"
                      if test is not None else f"{self._pad(inner)}else:")
            lines = [header]
            *stmts_before, tail = body
            for s in stmts_before:
                lines.extend(self.stmt(s, branch_scope, inner + 1))
            tail_value = self.expr_of(branch_scope).translate(tail.value, 0)
            lines.append(f"{INDENT * (inner + 1)}{tail_value}")
            return lines

        lines = [f"{pad}{target_text} ="]
        first_test, first_body = branches[0]
        lines.extend(branch_lines(first_test, first_body, "if"))
        for test, body in branches[1:]:
            lines.extend(branch_lines(test, body, "else if"))
        lines.extend(branch_lines(None, final_else, "else"))

        # Bind the name(s) in the *outer* scope only now that the branches
        # (which must not see it yet) have been translated.
        for name, n in flatten_target_names(target_node):
            scope.bind(name, BINDING, n)
        return lines

    def _s_For(self, node, scope, level):
        if node.orelse:
            unsupported(node, "a 'for ... else:' clause has no Pyking "
                               "equivalent (Pyking's 'for' has no 'else')")
        et_iter = self.expr_of(scope)
        iterable = et_iter.translate(node.iter, 0)
        pad = self._pad(level)
        body_scope = scope.child()
        if isinstance(node.target, ast.Name):
            loop_var = node.target.id
            body_scope.bind(loop_var, LOOP_VAR, node.target)
            header = f"{pad}for {loop_var} in {iterable}:"
            body_lines = self.block(node.body, body_scope, level + 1)
            return [header] + body_lines
        # Tuple/list target: Pyking's 'for' statement only binds a single
        # name, so bind a fresh element name and destructure it as the
        # body's first statement (irrefutable, exactly matching Python's
        # own for-loop unpacking semantics).
        names = [n for n, _ in flatten_target_names(node.target)]
        loop_var = _fresh_name("item", names, scope)
        body_scope.bind(loop_var, LOOP_VAR, node.target)
        target_text = self._emit_target(node.target)
        for name, n in flatten_target_names(node.target):
            body_scope.bind(name, BINDING, n)
        header = f"{pad}for {loop_var} in {iterable}:"
        destructure = f"{pad}{INDENT}{target_text} = {loop_var}"
        body_lines = self.block(node.body, body_scope, level + 1)
        return [header, destructure] + body_lines

    def _s_While(self, node, scope, level):
        if node.orelse:
            unsupported(node, "a 'while ... else:' clause has no Pyking "
                               "equivalent (Pyking's 'while' has no 'else')")
        pad = self._pad(level)
        cond = self.expr_of(scope).translate(node.test, 0)
        body_lines = self.block(node.body, scope.child(), level + 1)
        return [f"{pad}while {cond}:"] + body_lines

    # -- def ------------------------------------------------------------

    def _s_FunctionDef(self, node, scope, level):
        if node.decorator_list:
            unsupported(node, "decorators are not supported")
        if node.args.vararg or node.args.kwarg or node.args.kwonlyargs or node.args.posonlyargs:
            unsupported(node, "only a plain, fixed positional parameter list is "
                               "supported -- no '*args', '**kwargs', keyword-only "
                               "or positional-only parameters")
        if node.args.defaults:
            unsupported(node, "default parameter values are not supported -- "
                               "Pyking's call syntax is positional-only with no "
                               "way to omit a trailing argument")
        scope.bind(node.name, FUNCTION, node)
        pad = self._pad(level)
        params = []
        for a in node.args.args:
            ty = translate_type(a.annotation)
            params.append(f"{a.arg}:{ty}" if ty else a.arg)
        ret = translate_type(node.returns)
        header_tail = f" -> {ret}" if ret else ""
        body_scope = scope.child()
        for a in node.args.args:
            body_scope.bind(a.arg, PARAMETER, a)
        if _is_single_return_body(node.body):
            value = node.body[0].value
            if value is None:
                unsupported(node.body[0], "a bare 'return' has no value to use "
                                           "as a single-expression function body")
            et = self.expr_of(body_scope)
            expr_text = et.translate(value, 0)
            return [f"{pad}def {node.name}({', '.join(params)}){header_tail} = {expr_text}"]
        nested_info = classify_function(node.body)
        nested = FunctionTranslator(nested_info)
        body_lines = nested.block(node.body, body_scope, level + 1)
        return [f"{pad}def {node.name}({', '.join(params)}){header_tail}:"] + body_lines


def _is_single_return_body(body):
    return len(body) == 1 and isinstance(body[0], ast.Return)


def _fresh_name(base, avoid, scope):
    if base not in avoid and not scope.is_bound(base):
        return base
    i = 2
    while f"{base}{i}" in avoid or scope.is_bound(f"{base}{i}"):
        i += 1
    return f"{base}{i}"


# ---------------------------------------------------------------------------
# Module driver
# ---------------------------------------------------------------------------

REJECTED_MODULE_NODES = {
    ast.ClassDef: "class definitions are not supported (Pyking has no objects/classes)",
    ast.Try: "'try'/'except' is not supported (Pyking has no exceptions)",
    ast.TryStar: "'try*' is not supported (Pyking has no exceptions)",
    ast.With: "'with' is not supported (Pyking has no context managers)",
    ast.Raise: "'raise' is not supported (Pyking has no exceptions)",
    ast.Assert: "'assert' is not supported (Pyking has no exceptions to raise)",
    ast.Import: "'import' is not supported (py2pyk translates one self-contained file)",
    ast.ImportFrom: "'from ... import ...' is not supported (py2pyk translates one self-contained file)",
    ast.Global: "'global' is not supported (Pyking has no global-declaration statement; "
                "a module-level 'var' is already visible to nested defs that only read it)",
    ast.Nonlocal: "'nonlocal' is not supported (Pyking has no equivalent; "
                  "a 'var' cannot be reassigned from a nested function)",
    ast.Delete: "'del' is not supported (Pyking has no way to unbind a name)",
    ast.AsyncFunctionDef: "'async def' is not supported (Pyking has no concurrency model)",
    ast.AsyncFor: "'async for' is not supported (Pyking has no concurrency model)",
    ast.AsyncWith: "'async with' is not supported (Pyking has no concurrency model)",
}
if hasattr(ast, "Match"):
    REJECTED_MODULE_NODES[ast.Match] = (
        "'match'/'case' is not translated: Python's match-statement AST does not "
        "distinguish a tuple-shaped sequence pattern ('case (a, b):') from a "
        "list-shaped one ('case [a, b]:'), but Pyking's grammar treats them as "
        "different pattern kinds, so there is no sound way to pick one automatically"
    )


def _annotation_node_ids(tree):
    """id()s of every node inside a type annotation -- parameter, return,
    or 'x: T = ...' -- anywhere in the tree. Annotations get their own
    lenient, best-effort translation (`translate_type`, which drops
    anything not obviously expressible rather than rejecting it, since
    Pyking erases annotations completely anyway), so the general
    unsupported-construct scan below must not also walk into them: a
    perfectly fine 'list[int]' annotation is an `ast.Subscript` and would
    otherwise trip the blanket "no indexing" rejection meant for actual
    subscript *expressions*."""
    ids = set()
    for node in ast.walk(tree):
        annotations = []
        if isinstance(node, ast.arg) and node.annotation is not None:
            annotations.append(node.annotation)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.returns is not None:
            annotations.append(node.returns)
        if isinstance(node, ast.AnnAssign):
            annotations.append(node.annotation)
        for ann in annotations:
            for sub in ast.walk(ann):
                ids.add(id(sub))
    return ids


def _check_supported_early(tree):
    """A pre-pass purely for better error messages: walk the whole tree
    once up front and reject module-scope-only constructs (import, class,
    try, ...) wherever they appear, before the main translation gets deep
    enough into a function to report a less on-topic error first."""
    skip = _annotation_node_ids(tree)
    for node in ast.walk(tree):
        if id(node) in skip:
            continue
        node_type = type(node)
        if node_type in REJECTED_MODULE_NODES:
            unsupported(node, REJECTED_MODULE_NODES[node_type])
        if isinstance(node, ast.Lambda):
            unsupported(node, "lambda expressions are not supported (Pyking has "
                               "no anonymous functions; define a named function with 'def')")
        if isinstance(node, (ast.Dict, ast.DictComp)):
            unsupported(node, "dict literals/comprehensions are not supported "
                               "(Pyking has no dict type)")
        if isinstance(node, (ast.Set, ast.SetComp)):
            unsupported(node, "set literals/comprehensions are not supported "
                               "(Pyking has no set type)")
        if isinstance(node, ast.GeneratorExp):
            unsupported(node, "generator expressions are not supported; use a "
                               "list comprehension instead")
        if isinstance(node, ast.Subscript):
            unsupported(node, "subscripting/indexing ('x[i]', 'x[a:b]') is not "
                               "supported -- Pyking's grammar has no indexing "
                               "operator at all")
        if isinstance(node, ast.Attribute):
            unsupported(node, f"attribute access ('.{node.attr}') is not supported "
                               "-- Pyking has no '.' operator, so no method calls "
                               "and no attribute lookups")
        if isinstance(node, ast.JoinedStr):
            unsupported(node, "f-strings are not supported; build the string with "
                               "'+' and 'str(...)' instead")
        if isinstance(node, ast.NamedExpr):
            unsupported(node, "the walrus operator ':=' is not supported as an "
                               "expression -- Pyking's ':=' is a statement that "
                               "updates an existing 'var', not an expression")
        # ast.Starred is checked contextually (call args, list/tuple
        # literals, assignment targets) where it can legally appear, not
        # rejected blanket here.


def translate_module(tree, filename="<input>"):
    _check_supported_early(tree)
    scope = new_root_scope()
    info = classify_function(tree.body)
    translator = FunctionTranslator(info)
    lines = []
    prev_was_def = False
    for i, stmt in enumerate(tree.body):
        is_def = isinstance(stmt, ast.FunctionDef)
        if i > 0 and (is_def or prev_was_def):
            lines.append("")
            lines.append("")
        lines.extend(translator.stmt(stmt, scope, 0))
        prev_was_def = is_def
    return "\n".join(lines) + "\n"


def translate_source(source, filename="<input>"):
    tree = ast.parse(source, filename=filename)
    return translate_module(tree, filename)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="py2pyk",
        description="Translate a Python source file into Pyking source.",
    )
    parser.add_argument("input", help="Python source file to translate ('-' for stdin)")
    parser.add_argument("-o", "--output", help="output .pyk path (default: alongside the input)")
    parser.add_argument("--stdout", action="store_true", help="print the translation instead of writing a file")
    args = parser.parse_args(argv)

    from_stdin = args.input == "-"
    if from_stdin:
        source = sys.stdin.read()
        display_name = "<stdin>"
    else:
        in_path = Path(args.input)
        try:
            source = in_path.read_text()
        except OSError as e:
            print(f"py2pyk: cannot read {in_path}: {e}", file=sys.stderr)
            return 1
        display_name = str(in_path)

    try:
        result = translate_source(source, filename=display_name)
    except SyntaxError as e:
        print(f"py2pyk: {display_name}: Python syntax error: {e}", file=sys.stderr)
        return 1
    except UnsupportedFeature as e:
        print(f"py2pyk: {e.format(display_name)}", file=sys.stderr)
        return 1

    if args.stdout or from_stdin:
        sys.stdout.write(result)
        return 0

    out_path = Path(args.output) if args.output else in_path.with_suffix(".pyk")
    out_path.write_text(result)
    print(f"py2pyk: wrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
