# `target_js_core.py`: design

How `src/target_js_core.py` translates Pyking to JavaScript, and why
its `Scope` is so much simpler than `target_python.py`'s. For what each
construct compiles to and where the output is not optimal, see
[target_js.md](target_js.md); for how the three JavaScript targets
(`nodejs`, `html`, `esm`) are built from this module's output, see
[target_js_packaging.md](target_js_packaging.md); for a one-page
summary, see [source.md](source.md#target_js_corepy).

## Why this `Scope` doesn't need what Python's does

`target_python.py`'s `Scope` carries eight fields — `outer`, `local`,
`block`, `shadowed`, `captured`, `loop_names`, `depth`, `mutables` —
because Python scopes at the function boundary and Pyking scopes at
every block, and reconciling the two needs to know, for every binding,
both what's already live in the enclosing Python function and what any
function defined in that scope reads from (or writes to) around itself
(see [target_python_internals.md](target_python_internals.md)).

This module's `Scope` is three fields:

```python
@dataclass(frozen=True)
class Scope:
    names: dict         # Pyking name -> JavaScript name
    block: frozenset    # names bound by the innermost Pyking block
    taken: frozenset    # every JavaScript name already spoken for here
```

That's the whole mechanism, and it's enough because the premise is
different: **JavaScript's `{ }` blocks are lexical scopes, exactly as
Pyking's are.** A `const` or `let` declared inside an `if` body is
already invisible outside it, with no help from this backend — so the
renaming problem `target_python.py` spends most of its complexity
solving simply doesn't arise here for the *shadowing* case. `_block_scope`
is one line (`Scope(scope.names, frozenset(), scope.taken)` — keep the
enclosing names, drop which ones this block itself bound) instead of the
six-argument reconstruction Python's `_block_scope` needs, precisely
because there's no `shadowed`/`captured` bookkeeping to carry forward.

What JavaScript *does* still need a rename for is narrower: `const`
cannot be redeclared in the same block (a syntax error, not a runtime
one), and a `const` shadowing an outer name makes that name
unreadable **earlier in the same block**, before its own declaration —
the temporal dead zone. `_bind` checks exactly those conditions (a name
already in `RESERVED`, already a key in `scope.names`, or already one of
its *values* — the same "don't collide with a name some earlier rename
already produced" check `target_python.py`'s `_bind` makes, for the
identical reason).

`taken` is what `names` cannot say. That dict holds each Pyking name's
*current* JavaScript name, so after `x`, `x2`, `x3` it no longer
remembers that `x2` was ever used, and would offer it back to a fourth
binding — a duplicate declaration, which JavaScript refuses. `taken`
accumulates instead of replacing. It is also how a `loop` reserves its
accumulator: the `let` stands in the block around the loop, but the name
is in scope only in the loop's body, so `_reserve` adds the JavaScript
name without binding the Pyking one. See [target_js.md](target_js.md), "Scope and
renaming," for what a rename actually looks like in the output.

The one thing JavaScript's block scoping does *not* give for free is a
loop turn. That `let` around the loop is one binding for every turn, so
a function written in the body would close over the last turn's value
rather than its own — Pyking binds the accumulator afresh each time
round. `_defines_function` asks whether the body writes a `def` at all;
where it does, the `let` becomes a carrier holding what the next turn
starts with and the accumulator becomes a `const` inside the body, which
is one binding per turn. Where it does not, the plain `let` stands, so
an ordinary loop compiles to ordinary JavaScript. See
[target_js.md](target_js.md), "A `def` inside a loop".

## `JsRuntimeCall`: one core, three ways to print it

The core doesn't decide what a call across the runtime interface (see
`runtime_interface.py`'s own page) is *spelled* as in the output — it
emits `JsRuntimeCall(info, operation, args)`, naming the operation
(`"print"`) rather than committing to `print(...)` or
`runtime.print(...)`. That deferral is the entire reason
`target_js_packaging.py` can build three genuinely different targets
(a self-contained script calling `console.log` directly, a
self-contained page writing into a DOM element, and an ES module that
receives a `runtime` object and calls `runtime.print`) from **one**
translation of the Pyking program: `pprint_js_expr`'s `JsRuntimeCall`
case takes a `runtime` dict (operation name to JavaScript expression)
and looks up the spelling at print time, not translation time. Nothing
about how the Pyking source translates changes across the three
targets — only what gets substituted in for `print` when the string is
finally rendered. See [target_js_packaging.md](target_js_packaging.md)
for how each of the three builds that dictionary.

`JsImport` works exactly the same way, for exactly the same reason. The
core says *what* an import brings in -- the module, the name it is known
by here, and the fields it takes -- and the packager says how that is
written: `require` for `nodejs`, a call to the module's `init(runtime)`
for `esm`, and a reference to a module already built above it on the
page for `html`. Exports need no node at all: the packager knows a
module's public names and writes the one line that hands them out.

`runtime` is therefore not a bare dict any more but a `JsHost`, holding
the operation spellings *and* how an import is written. One value rather
than two parameters, since it is threaded through every printer here.

## One statement-shaped AST, but operators collapse into a table

`JsExpr`/`JsStmt` mirror `syntax.py`'s one-class-per-variant style for
statements (`JsConst`, `JsLet`, `JsIf`, `JsWhile`, `JsFunc`, ...), the
same way every backend's own AST does. Binary and unary operators are
the one place this module deliberately does *not* mirror
`target_python.py`'s choice of one class per operator (`PyAdd`, `PySub`,
...): here they're a single `JsBinary(op: String, left, right)` node,
with `_BINARY_OPS` mapping each Pyking AST class to its JavaScript
spelling. The reason is that the printer needs a precedence table for
these operators regardless (`_PRECEDENCE`, keyed by the same strings),
so a second table mapping AST classes to those same strings would say
nothing the first one doesn't — there's no benefit to nine near-identical
dataclasses here the way there is in `syntax.py`, where each node is
consumed by many different passes, not just printed. `EEq` is worth
noting specifically: it becomes JavaScript's `===`, not `==`, because
Pyking only ever compares values of the same type (`Int`/`Int`,
`String`/`String`, `Bool`/`Bool`), and JavaScript's loose `==` would
relate values *across* types in a way nothing in Pyking's own semantics
does.

## Tail position and hoisting, the same shape as Python's

`translate_tail_stmts`/`translate_tail_stmt` push the "what does this
supply" question down into the last statement of a body, exactly the
way `target_python.py`'s `_translate_tail_block`/`_translate_tail_stmt`
do, and for the identical reason: PYKING.md's tail-position rule is one
rule, and every backend that runs it has the same shape of function
pushing `return` (or, here, nothing at all where JavaScript's own
implicit `undefined` already serves — see `_yields_unit`) into whichever
branch of an `if` actually runs. `declare_functions` is the equally
familiar two-pass hoist — bind every `def` name in a block before
translating any of it — matching `analyses.py`'s `block_functions` and
`typesystem.py`'s `declare_functions` in spirit, though this one is
simpler than either: JavaScript's own `function` declarations already
hoist and already support forward reference at *runtime*, so nothing
here is making recursion or mutual recursion possible the way
`declare`/`define` are in `interpreter.py`. What this pass buys is
purely about *naming*: a `def` that gets renamed for shadowing needs
every call site that mentions it — including ones written *above* the
`def` in the source — to say the renamed name, and that can only be
known once the whole block's names have been decided.

## The printer takes `runtime` as a parameter, throughout

Every printer function in this module — `pprint_js_expr`,
`pprint_js_stmt`, `pprint_js_program` — threads `runtime` as an
explicit argument, rather than a module-level flag the way
`syntax.py`'s `pprint_program` sets `_show_symbols`/`_tmap` around one
call (see `docs/syntax.md`). The difference is deliberate: `syntax.py`'s
flags are genuinely global to one print — everything in a single
`pyking` target shares the same `symbols`/`tmap` setting — while
the `JsHost` varies *per target*, and `target_js_packaging.py` calls
this printer once per module of the program on top of that -- three
separate times in the course of building one `esm` output (once for the module itself, differently for each of its
generated wrappers' inlined copies, where applicable) with a different
mapping each time. A parameter, not a global, is what makes those calls
independent of each other and safe to make in any order or even
concurrently — nothing here needs the "one call, then restore" discipline
`syntax.py`'s design depends on.
