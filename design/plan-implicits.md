# Static overloading, implicits, and lambdas

Three features that arrive together because the middle one needs the
other two: overloaded names disambiguated by type at compile time,
implicit parameters filled from the calling context, and lambdas,
which are what an implicit argument is sometimes built out of. The
design follows "Syntactic Implicit Parameters with Static Overloading"
(OOPSLA 2025); where it departs, the departure is a row in a table
below.

This is the plan the change follows: the decisions, then what each file
gets. Written before any code; where it disagrees with what was built,
the code is right and this file is stale.

## The shape of the whole thing in one paragraph

The type checker resolves every overloaded call and every implicit
argument and **changes nothing**. What it produces beside `tmap` is a
second table, `qmap`, keyed by a call's symbol, saying what that call
denotes and what to pass it. A new pass, `elaborate.ml`, consumes
`qmap` and rewrites the program into ordinary Pyking -- qualified names
renamed to plain ones, implicit arguments made explicit, lambdas built
where an implicit argument needs one. Everything downstream -- the
mutability analysis, the tail-call pass, nine backends and the
interpreter -- sees a program with no `::` and no `implicit` in it, and
needs to know nothing about either. That is `opt_tailcall.ml`'s
arrangement, for `opt_tailcall.ml`'s reason.

## Decisions: static overloading

| | Decision | Why |
|---|---|---|
| 1 | `int::str` is **one identifier** that happens to contain `::`, lexed as one `TokIdent` | `env` is already a map from a string to a type and already holds keys with a `.` in them (`mod.f`). No new token, no new AST node, no change to `env`'s shape |
| 2 | A **plain `def leq` is not a member of any overload set**. `leq(1,2)` resolves to it as names resolve today, and type-errors if it does not fit | The alternative is a fallback rule -- try the plain one, then the set -- which gives one name two meanings depending on what else the file happens to contain |
| 3 | Resolution is **argument-directed only**. The result type is a consequence of the choice, never an input to it | `called_at` is handed no expected type, and giving the checker one means threading `expected` through `check_expr` -- a change to the checker's shape rather than an addition to it |
| 4 | `::` is allowed **only on a `def` with at least one explicit parameter** | Decision 3 leaves nothing to resolve a qualified value or a nullary def by. Refusing at the definition beats refusing at every use |
| 5 | A candidate **fits** iff every argument type unifies with its parameter type in a trial store. Exactly one fit resolves; zero and two are both errors naming the candidates | Unification rather than matching is what lets `leq([171,10],[188])` pick `list::leq` from an argument type of `[?1]` and *solve* `?1` by choosing. Matching would need the argument ground first, and nothing would ever resolve inside a generic body |
| 6 | An argument type nothing has decided is **an error at the call**, not a deferred obligation | Deferring is inferred contexts, which is type classes. The fix a programmer wants is to write `implicit` on a parameter, and that is the feature next door |
| 7 | A **builtin's name is never part of an overload set**. `str(78)` is the builtin; `int::str(78)` is the def | `str`, `len`, `print`, `range`, `float` and `int` are `TBuiltin` and are checked by `check_builtin_call` rather than by unification. Joining the two rules would mean one call site using both |
| 8 | The uniqueness rule is **per block**, exactly as `analyses.block_functions` already enforces it | `int::helper` inside a function body is then legal and invisible outside it, like every other nested `def` |

## Decisions: implicits

| | Decision | Why |
|---|---|---|
| 9 | `implicit bar: T` is **part of the function type**, by name and by position, and the name is significant for equality: `(implicit bar: T) -> U` and `(implicit baz: T) -> U` are different types | Decision 15 resolves at the *call*, from the type of what is being called. A type that had forgotten the name could not be resolved against a scope |
| 10 | Implicit parameters are **trailing**, always | It makes filling them "append", keeps an arity error counting explicit parameters only, and -- decision 25 -- lets them live in a field of their own so nothing that reads a function's parameters has to change |
| 11 | A caller may supply one **by name** (`less_index(e, l, leq = intpair::leq)`), never positionally | Named arguments already exist (`desugar_args.ml`), so this is nearly free, and it is the escape hatch for when resolution picks a fit the programmer did not want |
| 12 | `implicit` and a default value on one parameter is **refused** | Two mechanisms for one slot, and no rule for which wins that is not arbitrary |
| 13 | The search at a call needing `implicit bar : T` gathers **every implicit binding visible whose base name is `bar`** -- `bar` itself and every `q::bar` -- and requires exactly one whose type unifies with `T`. A non-implicit binding is invisible to it. Shadowing applies per qualified name. There is **no specificity ordering** | Koka's mistake is letting any value in scope be captured by accident; the `implicit` keyword at the *definition* is what makes the search safe. No specificity means no overlapping-instance rules and no coherence argument to make |
| 14 | Resolution is **recursive and builds a tree**: choosing a candidate that itself has implicit parameters creates new obligations, discharged in **the outermost call site's scope**, to a depth of 32, after which the chain is named in the error | `list::leq` for `[[Int]]` legitimately recurses. A depth limit beats a structural-decrease argument that the checker would have to prove |
| 15 | An obligation **never crosses a `def` boundary**. If `g`'s body calls something with an implicit parameter and `g`'s scope has no implicit of that name, it is an error there, and `g` must declare the implicit parameter itself | This is the decision that defines the system. Propagating outward is inferred contexts; stopping at the boundary is what keeps the feature syntactic, decidable, and explainable in one sentence |
| 16 | An implicit argument whose candidate has implicit parameters of its own is passed as a **lambda** that supplies them: `(p1, p2) => list::leq(p1, p2, int::leq)` | This is the dictionary, and it is why lambdas arrive in this change. See the consequence below |
| 17 | Only `def` and `=` may be `implicit`. No `implicit var` | A mutable binding resolved at compile time is a trap: the write happens at run time and the choice does not |

**The consequence of decision 16, stated rather than buried.** A
generated wrapper captures no *value* -- everything free in it is a
function name -- so a generated `def` would have compiled on all nine
targets, where a lambda compiles on four: `target_c.ml` and
`target_java.ml` have no closures and refuse a lambda outright
(`target_java.ml:1251` already says why). So a program whose implicit
resolution needs a wrapper is Python/JS/OCaml/`interpret` only, and
`typecheck_implicit_nested` lists four targets rather than nine.
Switching to a generated `def` is a change to one function in
`elaborate.ml` if that turns out to matter.

## Decisions: modules

| | Decision | Why |
|---|---|---|
| 18 | A **public implicit** is imported unqualified and automatically; a public non-implicit is reached through the module name as today | This is the feature: an ordering a library defines is usable in the file that imports it without naming it |
| 19 | Auto-import is **not transitive** | What is in scope stays what this file says. The cost -- a library cannot re-export another's orderings -- is stated in PYKING.md rather than fixed |
| 20 | After `import mod`: `int::leq(...)` works unqualified, and `mod.leq(...)` resolves among `mod`'s public `q::leq` | Both are the same rule applied in the two places a name can be written |
| 21 | Two imported modules exporting the same implicit is an error **only when a resolution finds two fits** | Implicits arrive silently, so an eager collision check would make two unrelated libraries un-importable together |
| 22 | A `.external.pyk` declaration may be `implicit`; `check_boundary_type` keeps refusing what it already refuses | An implicit *function* cannot cross a boundary that refuses function types anyway, so this costs one flag and no rule |
| 23 | `sigmap` becomes `(string * typ * bool) list` -- the third component is implicitness | Implicitness is a property of the binding, not of the type, and the sigmap is internal |

## Decisions: lambdas, and the pipeline

| | Decision | Why |
|---|---|---|
| 24 | `x => x + 1`, `(x, y) => x + y`, `(x: Int) => x + 1`. **Body is one expression**, no return annotation, `=>` lowest precedence and right-associative | A block body would put statements inside an expression, which is where `analyze_mutability`'s "no expression mutates anything" stops being true |
| 25 | A lambda is **monomorphic**, including when bound by `=`. `def` is how a polymorphic function is written | Generalisation hangs off `SFunctionDef` -- `instances` is keyed by a def's symbol and `infer_definition` is triggered by a call. Generalising `=` bindings is a new axis in the checker, not a case in one |
| 26 | A lambda captures lexically and cannot recurse. Its body is **never the enclosing function's tail** | `opt_tailcall.ml:162` already stops at `SLoop` and `SFunctionDef` for this reason; a lambda is the same thing |
| 27 | C and Java **refuse** a lambda with a source position. Python, JavaScript, OCaml and the interpreter translate it | Neither has closures, and neither does lambda lifting. Python's `lambda` is expression-only, which is decision 24 from the other end |
| 28 | The checker produces `qmap` and **changes nothing**; `elaborate.ml` consumes it and produces ordinary Pyking | `opt_tailcall.ml`'s arrangement. Nine backends and the interpreter need no case, and `-t pyking` prints a program that says what it means |
| 29 | `qmap` carries **the type of every node it asks for**, and `elaborate.ml` extends `tmap` as it builds. **The checker does not run again** | `optimize_module` in `pyk.ml` already does exactly this for the tail-call pass: "it extends `tmap` for what it built, since the checker will not run again to say what those nodes are". The cost is that nothing *checks* the rewrite, paid for the way `docs/optimization.md` pays for it -- with a written argument that it preserves typing by construction |
| 30 | `elaborate.ml` **renames** `q::b` to `q__b` program-wide, and a program that also binds `q__b` is refused by name | It is what keeps `::` out of nine backends that have no legal spelling for it. Deterministic, so two modules rename the same name the same way with no shared state |

Two things follow from decisions 1 and 30 that are worth seeing before
the work starts. **`env` keeps its shape**: a call to an unbound `leq`
scans the map for keys equal to `leq` or ending in `::leq`, which is
O(scope) once per unresolved call and needs no multimap. And **`env`'s
value grows one field**: `binding = { type_ : typ; implicit : bool }`.
`docs/typesystem.md`'s "a name is in the map with a type, or it is not
in scope" becomes "with a type and whether it is implicit" -- still
total, still no third state to ask about.

## The examples, corrected

The spec's examples do not compile as written: Pyking has no `and`
operator, `less_index` accumulates `x + 1` where it means `i + 1`, and
`list::leq`'s implicit is written `(a, b) -> Bool`. These are the
versions that become `tests/module_implicit_mod.pyk` and
`tests/module_implicit.pyk`.

```
# module_implicit_mod.pyk
public implicit def int::leq(x: Int, y: Int) -> Bool:
    x <= y

public implicit def float::leq(x: Float, y: Float) -> Bool:
    x <= y

public implicit def list::leq(xs: [a], ys: [a],
                              implicit leq: (a, a) -> Bool) -> Bool:
    match (xs, ys):
        case ([x] ++ xrest, [y] ++ yrest):
            if leq(x, y):
                list::leq(xrest, yrest)
            else:
                false
        case ([], []): true
        case (_, _): false

public def less_index(elem: a, lst: [a],
                      implicit leq: (a, a) -> Bool) -> Int:
    loop i = 0 for x in lst:
        if leq(x, elem):
            i + 1
        else:
            break
```

```
# module_implicit.pyk
import module_implicit_mod as mod

print(mod.int::leq(7, 8), mod.float::leq(7.8, 99.3))
print(leq(88, 100), leq(79.12, 18.2), leq([171, 10], [188]))
print(mod.less_index(10, [7, 4, 12, 2]))
print(mod.less_index(30.3, [1.4, 10.12, 23.1, 55.1]))

implicit def intpair::leq(x: (Int, Int), y: (Int, Int)) -> Bool:
    x1, x2 = x
    y1, y2 = y
    if leq(x1, y1):
        leq(x2, y2)
    else:
        false

e = (4, 8)
l = [(2, 2), (5, 7), (1, 3)]
print(mod.less_index(e, l))
```

printing

```
true true
true false false
2
3
1
```

Four things in those twenty lines are the whole feature. `leq(88, 100)`
resolves by argument type among four candidates. `leq([171,10],[188])`
picks `list::leq` from an argument type that is still a metavariable at
the point of choosing, and the choice solves it. `list::leq`'s own
`implicit leq` is discharged twice -- against `int::leq` from the call
site in `main`, and against its own *parameter* `leq` in its recursive
call, where decision 2 makes the plain name win with no search at all.
And `intpair::leq`, written below the prints, is in scope above them
because `def` names are visible throughout their block.

## The algorithm, stated once

**An overloaded call** `name(a1..an)` where `name` is not bound plainly
and at least one `q::name` is in scope:

1. Check `a1..an` **once**, in order, giving their types and a store.
   Arguments are not re-checked per candidate: the store they leave is
   what the candidates are tried against, and it is what keeps the
   first mistake in an argument the one reported.
2. Candidates: every binding whose key is `q::name`, plus -- for
   `mod.name(...)` -- every `mod.q::name`.
3. Each candidate is instantiated in a **trial store**, its arity
   checked against the explicit arguments, and each argument unified
   with its parameter. Trials are free: the store is a value.
4. Exactly one survivor wins and its store is kept. Zero is "no
   definition of `name` accepts arguments of type ...", listing the
   candidates and their types. Two or more is an ambiguity naming both.
5. The winner's implicit parameters are then discharged, left to right,
   in the scope of the call.

**An implicit parameter** `implicit bar : T` at a call site:

1. Candidates: every **implicit** binding in scope whose base name is
   `bar`.
2. A candidate fits iff unifying `T` with the candidate's type **minus
   its own trailing implicit parameters** succeeds. Those dropped
   parameters become obligations at the types the unification settled.
3. Exactly one fit, or the same two errors as above.
4. No obligations: the argument is the candidate's name. Obligations:
   the argument is a lambda of as many parameters as `T` takes, whose
   body calls the candidate with them and with each obligation
   discharged in turn -- decision 16.
5. Depth 32, then an error naming the chain.

An implicit **parameter** is an implicit binding in the body it belongs
to, which is what makes step 1 find `leq` inside `list::leq`.

## `src/`

### Front end

- **`lexer.ml`** -- `"implicit"` joins `keywords`. `TokFatArrow` (`=>`)
  joins the operator arms, `pprint_token` and `token_info`; it is tried
  before `=`, and is unrelated to `>=`. The identifier arm grows one
  lookahead: an identifier followed immediately by `::` followed
  immediately by a letter scans on into **one** `TokIdent` holding the
  `::`. No whitespace is permitted on either side, which is what keeps
  it unambiguous against the block `:` and the annotation `:`. A half
  that is a keyword (`if::f`, `Int::f`) is a lex error.
- **`names.ml`** (new, tiny, dependency-free, beside `builtin.ml` in
  the module graph) -- the spelling rules for a qualified name:
  `is_qualified`, `qualifier`, `base`, `renamed` (`q::b` -> `q__b`).
  One place, read by the parser, the checker and `elaborate.ml`.
- **`syntax.ml`** -- `ELambda of info * param list * expr * int` in the
  `expr` group, with its cases in `expr_info`, `expr_sym`, `with_info`,
  the precedence list and `pprint_expr` (which must print
  re-parsably: `(x, y) => body`). `TFunction` gains a **seventh field**,
  `implicit_param list`, where `and implicit_param = IParam of string *
  typ`. Decision 10 is what allows this: implicit parameters are
  trailing, so they live in a field of their own and every `match` that
  reads a function's explicit parameters needs a `, implicits` added and
  nothing more -- which the compiler finds. An `IParam` carries no
  `info` and no `sym` because it is part of a type, and types are
  synthesized and carry the enclosing `TFunction`'s span.
- **`parser.ml`** -- a qualified `TokIdent` is accepted as a `def`'s
  name and wherever a name is read; **refused** on an `=` binding, a
  `var`, a parameter, a loop variable, a pattern capture and a `def`
  with no parameters (decision 4). `implicit` before `def` and before
  `=`; `implicit name: type` in a parameter list, **trailing only**, and
  with no default (decision 12). `implicit name: type` in a function
  *type*, so `parse_type` reads what `pprint_type` writes.
  `parse_lambda`: after an identifier or a parenthesised parameter list
  followed by `TokFatArrow`, one expression; right-associative at the
  lowest precedence. A lambda parameter may be annotated, may not have
  a default, and may not be `implicit` (decision 24, decision 17).
- **`analyses.ml`** -- a `symbolize` case for `ELambda` (and its
  parameters, in field order). `analyze_mutability` **gains a descent
  into expressions, for lambdas only**: a lambda's parameters go through
  `bind`, so `var count = 0` followed by `f = count => count` is refused
  by the rule that already refuses every other shadowing of a `var`.
  The walk still never descends looking for mutation -- decision 24
  keeps that true -- it descends looking for a binding.
  `block_functions` needs nothing: `int::leq` and `float::leq` are
  different names.
- **`walk.ml`** -- `ELambda` in `children`, its body its one child.
  Nothing that folds over the AST would notice if this were missed,
  which is the reason it is written down here.
- **`opt_tailcall.ml`** -- expected to need nothing. `record_call`
  matches `ECall` and `EIf`, so a lambda is not a tail call and is not
  mistaken for one; confirmed by the build and by a test, not by
  reading.
- **`type_experiment.ml`** -- nothing.

### `typesystem.ml`

- `type env = binding SMap.t` with `binding = { type_ : typ; implicit :
  bool }`. `bind` gains the flag; every existing caller passes `false`.
- `check_function` binds implicit parameters **as implicit** in the
  body's environment -- the one line that makes `list::leq`'s recursive
  call find its own parameter.
- `same_type`, `unify`, `substitute`, `instantiate`, `generalize`,
  `free_vars`, `accepts`, `zonk` and `metas_in` each gain the implicit
  parameter list: compared by name *and* type (decision 9), substituted
  and zonked like any other type.
- `check_call` grows a third branch beside the builtin one and the
  deferred-definition one: a name not bound plainly, with candidates in
  scope, goes to `resolve_overload`. The algorithm above, in three new
  functions -- `candidates`, `fits`, `discharge`.
- `check_param` learns `implicit`; `check_function` refuses an
  unannotated parameter on a definition that is implicit or has
  implicit parameters, and `check_exports` needs nothing new because a
  public definition is already required to be complete.
- `import_env` binds an auto-imported public implicit **unqualified and
  implicit** (decision 18), and keeps binding `alias.field` as it does.
- `qmap` is a field of the `store`, filled by `record_resolution` and
  returned beside `tmap`, zonked at the end with it. Like `record` it
  **overwrites**: a generalisable body is checked twice and only
  `verified`'s pass counts, so a resolution from the discarded pass must
  not survive.
- `type_check` answers `(tmap, qmap)`. `type_experiment.type_check`
  answers an empty `qmap` so `pyk.ml` has one shape to handle.

Two errors are worth writing carefully, because they are the two a
programmer will meet: "no definition of `leq` accepts arguments of type
`([Int], [Int])`", listing what is in scope and at what type; and "no
implicit `leq` of type `(Int, Int) -> Bool` is in scope here" with, when
a *non*-implicit `leq` is in scope, the sentence that says why it was
not used.

### `elaborate.ml` (new)

`elaborate qmap tmap stmts -> ([stmt], tmap)`, called from `pyk.ml`
between the checker and the mutability analysis, with
`Analyses.symbolize ~start:highest` after it -- `optimize_module`'s
shape exactly. It does three things and nothing else:

1. **Renames** every `q::b`, at its definition and at every reference,
   to `q__b` (decision 30), refusing a program that also binds that
   name.
2. **Rewrites** each call `qmap` knows about: the callee becomes the
   resolved name, and the resolved implicit arguments are appended.
3. **Builds** a lambda for each implicit argument that needs one
   (decision 16), recursively.

Every node it builds gets a `tmap` entry from the type `qmap` carried
for it (decision 29). Its `.mli` is three lines; `docs/implicits.md`
carries the argument that the rewrite preserves typing, in the shape
`docs/optimization.md`'s "Why one check is enough" uses.

### `interpreter.ml`

`ELambda` in `_step_eval`, building a `VClosure` over the environment
it is reached in -- the representation already exists and holds no host
closure. `call_free_symbols` counts a lambda body as it counts any
expression. The `datatype` comment block is hand-written and drifts
silently. Nothing about implicits or `::` reaches here: the program it
runs has been elaborated.

### `module.ml`

- `sigmap` gains implicitness (decision 23); `make_sigmap` reads it from
  the checked module's own definitions.
- `check_publics` treats `int::leq` as the name it is, so exporting
  `leq` and `int::leq` is not a clash.
- `reached_module` answers for a qualified field as it does for a plain
  one. C and Java already refuse a module in two halves.
- `check_declaration` permits `implicit`; `check_boundary_type` is
  unchanged (decision 22).

### Backends

**`target_python.ml`.** `ELambda` is a `PyLambda`, which Python's own
expression-only `lambda` matches exactly. The scope machinery applies
unchanged -- a lambda parameter is a binding like any other, and
`_free_names`/`_captured_names` already answer for it once `walk.ml`
knows its children. **`_translate_capturing_defs` must learn that a
lambda inside a loop captures the turn**: today it looks for a nested
`def` and a lambda would slip past, silently closing over the last
turn's value.

**`target_js_core.ml`.** `ELambda` is an arrow function. The same
correction: `defines_function` (`:683`) matches `NStmt (SFunctionDef _)`
and must also answer true for a lambda, or the `let`-carrier of
`tests/loop_def_capture.pyk` is not built and every turn's lambda sees
the last turn's accumulator. Nothing would fail loudly; the output
would just be wrong.

**`target_ocaml.ml`.** `ELambda` is `fun x -> ...`, with the type read
from `tmap` as everything else is. Its list of refusals in
`docs/target_ocaml.md` is unchanged.

**`target_c.ml`, `target_java.ml`.** `ELambda` raises `Unsupported`
with its own position and the reason those two already give for a
nested function that reads what is around it. The message has to be
written for the case where the lambda was **generated** (decision 16):
it points at the call site whose implicit argument needed it, and says
so, or it is baffling.

### `pyk.ml`, `repl.ml`

`check_module` answers `(tmap, qmap)`; `elaborate` runs next, before
`analyze_mutability`, and `optimize_module` after it, unchanged. No new
error kind: every refusal here is a `Type_error` or an
`Analysis_error`, and `format_error` already words both. The flag
`--no-typechecking` still stops before all of it and `-t pyking` then prints the
program as written, `::` and `implicit` included -- which is the only
way to see the unelaborated program, and is enough.

In the REPL an implicit arrives in the session environment like every
other binding, so a definition in one entry is a candidate in the next
with no work. `:ls` prints `implicit` and the qualified name.

## `tests/`

| file | what it pins | targets |
|---|---|---|
| `lambda_basic` | `x => x + 1`, `(x, y) => x + y`, `(x: Int) => x`, a lambda passed and called | python, js, ocaml, `interpret` |
| `lambda_capture` | a lambda closing over what is bound where it is written | as above |
| `lambda_loop_capture` | a lambda defined in a `loop` body -- the twin of `loop_def_capture.pyk`, and the test for the two corrections above | as above |
| `typecheck_lambda` | `.ast.out` pinning a lambda's inferred type, and decision 25: `f = x => x` is monomorphic | as above |
| `fail_typecheck_lambda_poly` | that same `f` used at two types | `pyking` |
| `fail_typecheck_lambda_var` | a lambda parameter shadowing a `var` (a `Name error`) | `pyking` |
| `fail_typecheck_lambda_c` | a lambda refused by C, with its position | -- (the refusal is per-target; checked in `test_script.py`'s unsupported path) |
| `overload_basic` | `int::str`-shaped overloading on one argument type, called unqualified and fully qualified | all + `interpret` |
| `overload_poly` | a polymorphic candidate (`[a]`) chosen beside monomorphic ones -- decision 5 | all + `interpret` |
| `typecheck_overload` | `.ast.out` pinning the **elaborated** program: the renaming and the chosen candidate at every call | backends + `interpret` |
| `fail_typecheck_overload_none` | no candidate accepts the arguments | `pyking` |
| `fail_typecheck_overload_ambiguous` | two candidates fit | `pyking` |
| `fail_typecheck_overload_open` | decision 6: `def f(x): leq(x, x)` | `pyking` |
| `fail_typecheck_overload_value` | decision 4: `::` on an `=` binding, and on a nullary `def` | `pyking` |
| `fail_typecheck_overload_rename` | decision 30: a program binding both `int::leq` and `int__leq` | `pyking` |
| `implicit_value` | an implicit `=` binding filling a parameter | all + `interpret` |
| `implicit_function` | the spec's `foo`/`my1`/`my2`, printing `78! 10!` and `hi! wow!` | all + `interpret` |
| `typecheck_implicit_nested` | `list::leq` of `[[Int]]` -- decision 16, the generated lambda, pinned in `.ast.out` | python, js, ocaml, `interpret` |
| `implicit_explicit_arg` | decision 11: `leq = intpair::leq` written at the call | all + `interpret` |
| `implicit_firstclass` | decision 15 satisfied: a function with an implicit parameter passed as a value and called in a scope that has the implicit | python, js, ocaml, `interpret` |
| `fail_typecheck_implicit_notimplicit` | the spec's `my3`: a `bar` in scope that is not `implicit` | `pyking` |
| `fail_typecheck_implicit_missing` | no implicit of that name at all | `pyking` |
| `fail_typecheck_implicit_ambiguous` | two implicits fit | `pyking` |
| `fail_typecheck_implicit_escape` | decision 15 refused: the obligation would have to cross a `def` | `pyking` |
| `fail_typecheck_implicit_depth` | decision 14's limit, with the chain in the message | `pyking` |
| `fail_typecheck_implicit_annotation` | an implicit definition that is not fully annotated | `pyking` |
| `module_implicit`, `module_implicit_mod` | the two files above: auto-import, qualified use, a local implicit added to an imported set | all + `interpret` |
| `fail_typecheck_module_implicit_transitive` | decision 19: an implicit two modules away | `pyking` |
| `typecheck_noann_*` twins | wherever an existing `noann` twin applies -- an annotation says what a program means, never what it does | as their originals |

`module_implicit` is the case that matters most and the one most likely
to break last: it is the only test where a resolution crosses a module
boundary, a candidate is added below its first use, and a recursive
obligation is discharged against a parameter.

## Docs, PYKING.md, and the one that gets forgotten

- **`PYKING.md`** -- the feature summary gains lambdas, `::` and
  `implicit`; the EBNF gains a lambda expression, a qualified name, an
  implicit parameter in a `def` header and in a function type; "Names
  and scoping" gains decision 2 and decision 8; "Type checking" gains
  the resolution rules -- decisions 3, 5, 6, 13, 14, 15 -- because which
  programs are well-typed is a property of the language; "Modules"
  gains decisions 18 through 21, with decision 19 stated as a
  limitation; a worked example for each of the three features.
- **`docs/overloading.md`** (new) -- decisions 1 to 8, the candidate
  search, why resolution is argument-directed, and what it costs.
- **`docs/implicits.md`** (new) -- decisions 9 to 17, the search, the
  recursion, the dictionary, decision 15 argued properly, and the
  soundness argument for `elaborate.ml` in the shape
  `docs/optimization.md` uses.
- **`docs/architecture.md`** -- `elaborate.ml` in the stage table, and
  the pipeline order.
- **`docs/source.md`** -- `names.ml` and `elaborate.ml`; `typesystem.ml`
  now answers `qmap`; `env`'s value has a second field.
- **`docs/type_inference.md`** -- why an undecided operand type is an
  error at an overloaded call (decision 6) and not a deferred
  constraint, and why a lambda does not generalise (decision 25).
- **`docs/typesystem.md`** -- the `env` value, and the three new
  functions.
- **`docs/modules.md`** -- auto-import, and what a sigmap now carries.
- **`docs/targets.md`** -- lambdas in the shared-subset table, and the
  note that a generated lambda is why a nested implicit resolution is
  not C or Java.
- **`docs/target_python.md`**, **`docs/target_js.md`** -- the loop
  capture correction; **`docs/target_c.md`**, **`docs/target_java.md`**
  -- the lambda refusal and its wording; **`docs/target_ocaml.md`** --
  `fun`.
- **`docs/interpreter.md`** -- `VClosure` from a lambda.
- **`tools/emacs/pyking-mode.el`** -- `"implicit"` joins
  `pyking-mode-keywords`, which must still equal `lexer.ml`'s
  `keywords` split three ways; `pyking-mode-font-lock-keywords` gains
  `=>` and a face for the `q::` prefix of a name. Indentation needs
  nothing -- a lambda opens no block, and a line ending in `=>` is a
  parse error unless a bracket is open. Verified by running the batch
  indent check over a `tests/*.pyk`, not by eyeballing.

## Order of work

1. **Lambdas, end to end**: lexer, syntax, parser, analyses, walk,
   checker, interpreter, the five backends, the four lambda tests. They
   are a feature of their own and are testable with nothing else in
   place, and the two loop-capture corrections are easiest to find
   while they are the only thing that changed.
2. **`::` and static overloading**, through `-t pyking`: `names.ml`,
   the lexer's identifier arm, the parser's refusals, the candidate
   search, and `elaborate.ml`'s renaming half. The `fail_typecheck_*`
   cases and `typecheck_overload` need no backend.
3. **Implicits in one file**: the `env` flag, the search, the
   obligations, `elaborate.ml`'s insertion half, then its lambda half.
   `interpret` settles what every `.out` holds, as it is the reference.
4. **Implicits across modules**: sigmaps, auto-import, decisions 19 to
   22, and `module_implicit`.
5. The remaining backends' test rows, the docs, the emacs mode, and a
   clean warning-free rebuild.
6. All four suites green, and `make test` with no `TARGET`.

## What the work changed

Written after the fact. Where this disagrees with the plan above, the
code is right.

**Decision 23 had to reach further than the sigmap.** The plan said the
sigmap carries implicitness; it also had to say which *names* a sigmap
carries, because there are two answers. The one the **checker** is
given keeps the source's own spelling -- `int::leq` -- since that is
what the importing file writes. The one a **backend** is given is
renamed and has its implicit parameters folded in, since that is what
the generated file declares. `Module.context` does the second, in one
place, and `Typesystem.without_implicits` is the fold, exported so the
pass and the backends cannot disagree about it. Three separate bugs
surfaced through this before it was one rule: an OCaml `.mli` writing
`val int::leq`, a JavaScript `export { int::pick }`, and C and Java
registering an imported function under a name no call used. A module's
`publics` needed the same treatment, for the JS export clause.

**The auto-import rule is one binding, not two.** The plan implied a
public implicit would be bound both unqualified and under `mod.name`.
Binding both made every such call ambiguous with itself. What it
actually does is stay bound under `alias.field` alone, with the two
searches looking *through* the `.` when the binding is implicit -- so a
resolution always names the module it came from, which is also what
lets `elaborate.ml` write `mod.int__leq` rather than a name nothing
declared.

**Decision 11 needed `desugar_args` to know about implicit parameters**,
not just the checker. That pass runs before the checker and refuses a
call missing an argument, so it had to learn that an implicit parameter
may be left out -- and that a call supplying *one* of them supplies all
of them. `called_at` then accepts a call whose argument count is
explicit + implicit and checks them positionally, resolving nothing.

**The REPL needed a third thing in its session.** An entry is checked
under the names it was typed with and run under the ones the rewrite
gave it, which the plan predicted; what it did not predict is that the
rewrite builds nodes, whose symbols must not be handed out twice, and
the machine's call-free table is keyed by symbol. `session.high` is the
high-water mark, and every `symbolize` in that module continues past
it. `:ls` bridges the two name spaces.

**Two error messages earned their own case.** An argument type nothing
has decided fits *every* candidate, so the ambiguity report would have
listed them all and said nothing useful; it now says the type is open
and names the two ways out. And a qualified name in a binding target
was swallowed by the parser's speculative path -- the refusal moved to
after the `=` is found, where the parse is committed.

**One decision was taken that the grilling did not ask about.**
`implicit` and `::` are refused in an **external module's declaration
half**, because no pass rewrites a declaration: a `::` name there would
reach the target's own source under a spelling it does not have. The
plan's decision 22 said an implicit declaration would be allowed; it is
not, and `fail_typecheck_external_overload` pins the refusal.

**`qmap` had to be merged where `tmap` is.** `learned` folds an inner
check's knowledge into the outer store, and it listed `tmap` but not
`qmap` -- so every resolution made while a *deferred* definition's body
was being worked out was dropped. Such a program type-checked and then
failed at run time with an arity error, because `elaborate.ml` found
nothing to rewrite the call by. `tests/typecheck_implicit_deferred.pyk`
is the case, and it is the one shape none of the planned tests covered:
overloading and implicits inside a `def` that wrote no types.

**Decision 16 had to reach explicit arguments too.** The plan gave the
lambda wrapper only to an *implicit* parameter filled by a definition
that takes implicits. The same demand arises one step earlier: a
function carrying `implicit my` passed where an ordinary function type
is wanted -- which is what `def bar(a, f): f(a + 1)` asks for, since a
body cannot discover an implicit parameter and inference gives `f` the
type `(Int) -> a`. `Typesystem.adapted` supplies the implicit at the
argument's position and records an `Adapted` resolution; `qmap` became
a variant to carry it, since it now describes a node rather than only a
call. Which scope answers is exactly what the annotation on `f`
decides, and the two readings give different answers, which
`typecheck_implicit_deferred` pins.

**And it had to go both ways.** A function asking for *nothing*, passed
where one asking for an implicit is wanted, is widened by a lambda that
takes the implicit argument and drops it -- so a parameter written
`f: (Int, implicit my: Int) -> Int` accepts both a definition that asks
for `my` and a plain lambda that does not. That is usually the
annotation to write, since it is the one that resolves the implicit
*inside* the function rather than where the argument was passed, and
without the widening direction the two wishes were exclusive.
`Adapted` therefore carries the wanted type, how many of its parameters
the wrapper hands on, and the arguments it adds -- one shape for both
directions, wrapping whatever expression was written rather than only a
name.

**One latent bug came out of it.** A JavaScript arrow function is an
`AssignmentExpression`, looser than everything `target_js_core`'s
printer emits, and `JsArrow` consulted no `min_prec` at all -- so
`(x => x + 1)(5)` printed as `(x) => x + 1(5)`, an arrow whose body is
a call. It had been there since lambdas arrived and no test applied one
where it stood; `tests/lambda_basic.pyk` does now.

**Defaults and `::` had to be made to see each other.** A default is
erased by `desugar_args` before the checker runs, and that pass fills
an omitted argument only where it can tell which definition a call
reaches -- which on an overloaded name it cannot. So `c::my2(x, y,
z = 1000)` looked like a three-parameter function by the time overload
resolution ran, `my2(true, 1)` matched only the two-parameter sibling,
and one of two applicable definitions was picked silently. The *count*
is now settled in `desugar_args` (`overloaded`): one definition taking
the call by using a default has its defaults filled, two taking it
where one needs a default is refused, and anything else is left to the
checker's types. A named argument on an overloaded call is refused
there too -- it was being dropped silently, since `arg_exprs` discards
the names nothing had put in place.

**Decision 16's cost is as stated.** `typecheck_implicit_nested` lists
Python, OCaml, `iweb24` and `interpret`, and is refused on C and Java
because the argument built for the inner implicit is a lambda.
