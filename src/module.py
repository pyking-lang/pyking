"""The module system: one file is one module, and a program is the
acyclic graph of the modules its main file reaches. Reads and parses
every module a program needs, puts them in dependency order, and settles
what each one exports and what each import means, before the type checker
sees any of them. See docs/modules.md for the design and PYKING.md
("Modules") for the language.

This is step 1 of the three the compiler takes over a program of several
modules: `load` here, then the type checker once per module in the order
`load` gives, and then `make_sigmap` on each result, which is what the
next module is checked against.

Data structures:
    ModuleError -- a module-level failure, with the source position.
    Module -- one file: its name, path, tokens, statements, the modules
        it imports and the names it exports.
    Context -- what a backend is told about the module it is compiling
        beyond its statements.

Functions:
    load(path) -- every module the program at path needs, dependencies
        first, parsed, symbolized and with every import resolved.
    read_file(path) -- one file, lexed and parsed, and nothing else.
    context(units, unit) -- what a backend needs to know about one
        module of a program beyond its statements.
    make_sigmap(stmts, tmap) -- a module's exported names and their types.
    public_names(stmts) -- the names a module exports, unchecked.
    module_name(path) -- the module name a file has.
    module_path(directory, name) -- the file a module name means.
    sigmaps_for(module, sigmaps) -- the signatures one module needs.
"""

import os

from analyses import BUILTINS, highest_sym, symbolize
from dataclasses import dataclass, field, replace
from lexer import lexing
from parser import parse
from syntax import SFunctionDef, SFunctionSig, SImport, SLet, SLetStmt, SVar

# What a Pyking module is written in. A module name is a file name
# without it, in the directory of the file that imports it -- Pyking has
# no search path (see docs/modules.md, "Finding a module").
EXTENSION = ".pyk"


class ModuleError(Exception):
    """A module-level failure -- a missing module, a cycle, a collision,
    a name that is not exported -- with the source position."""

    def __init__(self, info, message):
        super().__init__(message)
        self.info = info
        self.message = message


@dataclass(frozen=True)
class Context:
    """What a backend needs to know about the module it is compiling
    beyond its statements -- everything that is true of it only as part
    of a program. Fields: name: String (the module's own name), main:
    Bool (whether it is the program's own module, the one whose top
    level is where the program starts), separate: Bool (whether the
    program has more than one module at all; a program of one is
    compiled exactly as it was before there were modules), starts:
    [String] (the modules the program's own module must run before its
    own top level, in order), sigmaps: {String: {String: Type}} (what
    every module of the program exports and at what type, which is how
    a backend that must know a type for an imported name finds one)."""
    name: str
    main: bool
    separate: bool
    starts: list
    sigmaps: dict


def context(units, unit):
    """The Context for one module of a program. `units` pairs each
    module with what the checker worked out for it, dependencies first.
    [(Module, a)] -> Module -> Context"""
    return Context(
        name=unit.name,
        main=unit is units[-1][0],
        separate=len(units) > 1,
        starts=([other.name for other, _ in units[:-1]]
                if unit is units[-1][0] else []),
        sigmaps={other.name: other.sigmap or {} for other, _ in units},
    )


@dataclass(frozen=True)
class Module:
    """One module of a program. Fields: name: String (its file's stem,
    which is what another module imports it by), path: String (the file
    it was read from), tokens: [Token] (kept for `--tokens`, which
    prints every module of the program), stmts: [Stmt], imports:
    [String] (the modules it imports, in source order, without repeats),
    publics: {String: Info} (the names it exports, and where each was
    made public), sigmap: {String: Type}? (each of those names and the
    type the checker gave it -- filled in after the module is checked,
    and None until then)."""
    name: str
    path: str
    tokens: list
    stmts: list
    imports: list = field(default_factory=list)
    publics: dict = field(default_factory=dict)
    sigmap: dict = None


# --- finding a module ------------------------------------------------


def module_name(path):
    """The module name a file has: its stem. String -> String"""
    return os.path.splitext(os.path.basename(path))[0]


def module_path(directory, name):
    """The file a module name means, in the directory of the file that
    imported it. String -> String -> String"""
    return os.path.join(directory, name + EXTENSION)


# --- reading one module ----------------------------------------------


def read_file(path, info=None):
    """Lexes and parses one file into a Module, and nothing else: no
    module it imports is read, and nothing about what it exports is
    checked. `info` is the import that asked for it, for the error a
    missing file raises. What `--no-typechecking` stops at, so that this
    front end and the OCaml one in ocaml-src/ -- which reads one file
    and has no module system -- can be compared.
    String -> Info? -> Module"""
    try:
        with open(path, "r") as f:
            data = f.read()
    except OSError:
        if info is None:
            # The program's own file: nothing imported it, so there is
            # no import to point at and no module error to raise.
            raise
        raise ModuleError(
            info,
            f"cannot read module '{module_name(path)}': there is no file "
            f"'{path}'",
        )
    tokens = lexing(path, list(data))
    return Module(
        name=module_name(path), path=path, tokens=tokens, stmts=parse(tokens)
    )


def read_module(path, info=None):
    """`read_file`, with the modules it imports and the names it exports
    worked out and checked. String -> Info? -> Module"""
    unit = read_file(path, info)
    return replace(
        unit,
        imports=imported_modules(unit.stmts),
        publics=check_publics(unit.stmts),
    )


def imported_modules(stmts):
    """The modules a program imports, in source order and without
    repeats -- two imports of one module are one dependency.
    [Stmt] -> [String]"""
    names = []
    for statement in stmts:
        match statement:
            case SImport(_, module, _, _, _) if module not in names:
                names.append(module)
    return names


# --- what a module exports -------------------------------------------


def public_names(stmts):
    """Every name the source marked `public`, in order, paired with the
    statement that marked it. A `def` may be marked on its definition or
    on its signature line, so a name can appear twice.
    [Stmt] -> [(String, Stmt)]"""
    found = []
    for statement in stmts:
        match statement:
            case SFunctionDef(_, name) | SFunctionSig(_, name) if statement.public:
                found.append((name, statement))
            case SLet(_, target) | SLetStmt(_, target) if statement.public:
                found.append((target.name, statement))
    return found


def bound_at_top_level(stmts):
    """Every name the top level of a module binds, paired with the
    statement that binds it, in source order. An import is not one: what
    it binds came from elsewhere, and `check_publics` compares the two.
    [Stmt] -> [(String, Stmt)]"""
    bound = []
    for statement in stmts:
        match statement:
            case SFunctionDef(_, name) | SVar(_, name):
                bound.append((name, statement))
            case SLet(_, target) | SLetStmt(_, target):
                bound += [(name, statement) for name in _target_names(target)]
    return bound


def _target_names(target):
    """The names an assignment target binds.
    AssignTarget -> [String]"""
    names = getattr(target, "name", None)
    if names is not None:
        return [names]
    return [n for element in target.elements for n in _target_names(element)]


def check_publics(stmts):
    """The names a module exports, refusing a name exported twice and
    one bound more than once at the top level -- an exported name means
    one thing in its module, so there is one definition for another
    module to reach. [Stmt] -> {String: Info}"""
    publics = {}
    for name, statement in public_names(stmts):
        earlier = publics.get(name)
        if earlier is not None and not _one_definition(name, stmts):
            raise ModuleError(
                statement.info,
                f"'{name}' is already public in this module (line "
                f"{earlier.row1}); a module exports one thing under one name",
            )
        publics.setdefault(name, statement.info)

    bindings = {}
    for name, statement in bound_at_top_level(stmts):
        if name in publics and name in bindings:
            raise ModuleError(
                statement.info,
                f"'{name}' is public, and is bound twice at the top level of "
                f"this module (already on line {bindings[name].row1}); an "
                "exported name is bound once, so that another module "
                "reaches one definition",
            )
        bindings[name] = statement.info
    return publics


def _one_definition(name, stmts):
    """Whether every `public` on `name` belongs to one definition -- a
    `def` and its own signature line, where writing it on either is
    enough. A name given to two `def`s is refused by
    `analyses.block_functions` in its own words, so it is not refused
    here. String -> [Stmt] -> Bool"""
    marked = [s for n, s in public_names(stmts) if n == name]
    return all(isinstance(s, (SFunctionDef, SFunctionSig)) for s in marked)


# --- resolving what an import means ----------------------------------


def resolve_imports(module, loaded):
    """`module` with every import resolved: a plain import's `fields`
    filled in with the module's public names, a selected one checked
    against them, and every name it brings in checked for a collision
    with the module's own. Module -> {String: Module} -> Module"""
    # What the module already uses: the builtins, which nothing may take
    # the name of, and everything its top level binds.
    taken = {name: None for name in BUILTINS}
    for name, statement in bound_at_top_level(module.stmts):
        taken[name] = statement.info

    stmts = []
    for statement in module.stmts:
        if not isinstance(statement, SImport):
            stmts.append(statement)
            continue
        statement = _resolved(statement, loaded[statement.module])
        for _, local in statement.fields if statement.selected else ():
            _claim(taken, local, statement, module)
        if not statement.selected:
            _claim(taken, statement.name, statement, module)
        stmts.append(statement)
    return replace(module, stmts=stmts)


def _resolved(statement, imported):
    """One import with its fields settled: the module's public names for
    the plain form, and the names the source asked for -- each checked to
    be exported -- for the `from` form.
    SImport -> Module -> SImport"""
    if not statement.selected:
        return replace(
            statement, fields=[(name, name) for name in imported.publics]
        )
    for name, _ in statement.fields:
        if name not in imported.publics:
            raise ModuleError(
                statement.info,
                f"module '{imported.name}' does not export '{name}'"
                + _hint(name, imported),
            )
    return statement


def _hint(name, imported):
    """Why a name a module has is still not one it exports, or "" for a
    name it does not have at all. String -> Module -> String"""
    if any(name == bound for bound, _ in bound_at_top_level(imported.stmts)):
        return (
            f": it is defined in '{imported.path}' but not marked 'public', "
            "and a module exports nothing by default"
        )
    return ""


def _claim(taken, name, statement, module):
    """Records that `name` is now in use in `module`, refusing it if
    something already has it.
    {String: Info} -> String -> SImport -> Module -> ()"""
    if name in taken:
        earlier = taken[name]
        where = ("the name of a builtin" if earlier is None
                 else f"already bound on line {earlier.row1}")
        raise ModuleError(
            statement.info,
            f"this import brings in '{name}', which module '{module.name}' "
            f"cannot use for it: it is {where}. Rename one of them, with "
            f"'as' on the import if that is the one to move",
        )
    taken[name] = statement.info


# --- the graph -------------------------------------------------------


def load(path):
    """Every module the program in `path` needs, dependencies first and
    the program itself last: read, parsed, symbolized with one numbering
    across the whole program, and with every import resolved. Raises
    ModuleError for a missing module or a cycle. String -> [Module]"""
    parsed = {}
    order = []
    _visit(module_name(path), path, None, parsed, order, [])

    modules = []
    highest = 0
    loaded = {}
    for name in order:
        module = parsed[name]
        module = replace(module, stmts=symbolize(module.stmts, highest))
        highest = highest_sym(module.stmts)
        module = resolve_imports(module, loaded)
        loaded[name] = module
        modules.append(module)
    return modules


def _visit(name, path, info, parsed, order, stack):
    """Depth-first over the import graph, appending each module to
    `order` after everything it imports. `stack` is the path of imports
    being followed, which is what a cycle is reported from.
    String -> String -> Info? -> {String: Module} -> [String] ->
    [(String, Info)] -> ()"""
    if name in [held for held, _ in stack]:
        raise ModuleError(info, _cycle_message(name, stack))
    if name in parsed:
        return
    module = read_module(path, info)
    parsed[name] = module
    # The importing file's own directory, as it was named rather than
    # made absolute: a module is beside the file that imports it (see
    # docs/modules.md, "Finding a module"), and an error naming it
    # should read the way the command that found it did.
    directory = os.path.dirname(path)
    for statement in module.stmts:
        if not isinstance(statement, SImport):
            continue
        _visit(
            statement.module,
            module_path(directory, statement.module),
            statement.info,
            parsed,
            order,
            stack + [(name, info)],
        )
    order.append(name)


def _cycle_message(name, stack):
    """The cycle an import closes, as the ring of modules it runs
    through. String -> [(String, Info)] -> String"""
    held = [module for module, _ in stack]
    ring = held[held.index(name):] + [name]
    return (
        f"module '{name}' imports itself"
        if len(ring) == 2 and ring[0] == ring[1]
        else f"these modules import one another: {' -> '.join(ring)}"
    ) + ". Pyking has no circular imports: a module is compiled, and run, " \
        "after everything it imports"


# --- what the type checker is given ----------------------------------


def make_sigmap(stmts, tmap):
    """A module's exported names and the types the checker worked out
    for them -- what another module is checked against, and all of this
    module that another one can see. Every exported name has one:
    `typesystem.check_exports` refuses a module that exports a `def` it
    worked out no type for.
    [Stmt] -> {Int: Type} -> {String: Type}"""
    exported = check_publics(stmts)
    return {
        name: tmap[statement.sym]
        for name, statement in bound_at_top_level(stmts)
        if name in exported
    }


def sigmaps_for(module, sigmaps):
    """The signatures needed to check one module: its own imports', out
    of every module checked so far. Module -> {String: {String: Type}} ->
    [(String, {String: Type})]"""
    return [(name, sigmaps[name]) for name in module.imports]
