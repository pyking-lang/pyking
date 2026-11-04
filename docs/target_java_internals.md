# Inside `target_java.ml`

How the Java backend is built. What it compiles to, and why, is
[target_java.md](target_java.md).

## Types come from the checker

Nothing here infers a type. `type_of` reads an expression's type out of
`tmap`, and falls back to the node's shape only for a node the tail-call
pass built, which the checker never saw. `jt` writes a Pyking type as
Java -- `~boxed` where Java needs a reference type, `~erase` (and
`ctx.erase`, set for the top level) where a type variable has no type
parameter to stand for and is written `Object`.

## The AST is text

An expression is a `jexpr`: its text, the precedence of its outermost
operator (`at` parenthesizes by it) and whether its static type is
boxed, which `unboxed` reads before a `==`. A statement is a `jstmt`,
small enough to print and to ask `completes` of: javac's rule for
whether a statement can finish (JLS 14.22), which `reachable` uses to
drop what follows one that cannot.

## Names

`scope` maps a Pyking name to a `binding`: its value, its type and its
`kind` -- a final local, a reassigned one, a cell (a `var` a closure
captures), a static field, an erased static, a method, or a place a
pattern bound. `fresh` hands out a name no local of the method family
has taken, so a local of an enclosing method keeps its name inside a
method lifted from it.

## Lifting

`declare_defs` binds every def of a block to a method before the block
is translated, so a def is visible throughout it. `lift` translates one
at its position as a static method (`method_of`) and records what it
captures in `captures`: the locals its body mentions, and the lifted
methods it reaches. Its parameters and its calls hold markers,
`\001P:name:k\001` and `\001A:name:k\001`; `expand_captures` replaces
them once the module is done, with what `closure` works out -- the
method's own captures and those of every method it reaches but did not
write.

## Matching

`pattern` answers a pattern's tests and the places it binds, each place
an expression over the subject that may be read twice. java17 binds a
pattern variable in a constructor's `instanceof` (`binding`), except
inside an or-pattern, where it would not be definitely matched.
`match_stmt` builds the chain, or the labelled block a guarded case
leaves; `switch_stmt` and `switch_pattern` build java21's `switch`, a
record pattern for a constructor or a tuple and `var` with its tests in
the `when` for anything else -- a var struct's constructor among them,
since its class is no record.

## Finishing a block

`tail_block` and `tail` translate a block whose last value is finished
by a `finish`: returned, assigned to a value-form binding's local, or
carried to a loop's next turn (`Turn`). `effect_of` translates an
expression evaluated for its effect alone.

## The runtime

A `jprogram` records the tuple arities, function arities and
polymorphic interfaces it names; `runtime_source` writes
`PykRuntime.java` for a whole program from all of its modules'.
Beside them it always holds the helpers every program may call: the
value printer (`str`, `show`, and `line` for a print whose arguments
must all be worked out first), `equal` and `hash` (Pyking's `==`, and a
hash agreeing with it), the conversions, `PykChar`, the stores --
`PykStore` and its `PykArray`, `PykVec` and `PykView` -- with their
factories (`arrayOfList`, `arrayFill`, `arrayInit`, `arrayUnfold`,
`vecEmpty`, `vecOfList`), `PykDict` with `dictEmpty` and `dictOfList`,
`copyInto`, the list and String `slice`, and `fail`, which ends the
program with a runtime error.

## Stores and Dicts

`store_of` tells an array, a Vec and a view (`Slice(T)`) apart, and
`jt` writes each as its runtime class, and a Dict (`dict_parts`) as
`PykDict<K, V>`, before the general `TCon` case, which would take them
for datatypes. `make_array` compiles the members of `array`, `vec` and
`dict` the elaborator leaves as calls, with the element type (a Dict's
key and value types) as explicit type arguments where `settled` says
Java can be told them; `typed_value` casts a lambda argument to its
interface. `a[i]`, `d[k]` and `len` need nothing of their own: each
class has `get` and `size` as a list does. `builtin` compiles `push`,
`pop`, `insert`, `remove`, `clear`, `view`, `get`, `has`, `discard`,
`keys`, `values` and `items` as a method call on their first argument
(`method_call`), and `effect_of` writes one whose value nobody reads as
a statement of its own. `SSetIndex` on a store holds the owner and the
index in temporaries and writes the check before the statement working
the value out, so the write runs in Pyking's order; on a Dict it is one
`put`, which Java already evaluates in Pyking's order (target_java.md,
"Arrays, Vecs and views", "Equality and Dicts"). `ESlice` is the
store's `slice` or the runtime's, `null` for a left-out `high`.
`walked` gives a `for` the store or Dict itself, an `Iterable`; `listed`
gives a comprehension a list of the elements or keys as they are when it
starts. `equal` (the OCaml helper) writes `==` on lists, tuples and
datatypes as `PykRuntime.equal`, and `structural_methods` gives java8's
tuple and datatype classes `equals` and `hashCode` through it, so they
can be keys.

## Var structs

`jdatatype` records a datatype's `writable` flag as `d_writable`, and
`pprint_datatype` writes a writable one as a final class with non-final
public fields on every version, before the cases that make a record.
`writable ctx t` asks `ctx.datatypes` -- which holds an imported
datatype too, with its flag, from `context.sigmaps` -- whether a type is
a var struct's; where it is, `EField` and a constructor pattern read a
field as `struct_field`, `s.x`, rather than a record's accessor, and
`switch_pattern`/`switch_parts` write a type pattern for it. `SSetField`
is one `s.x = v;`, the value cast by `typed_value` to the field's type
at this instance. `print_text` sends a print's arguments to
`PykRuntime.line` where one of a type that can change (not `fixed`)
comes before one holding a call. The runtime's `write` carries the
path set that turns a cycle into `...` (target_java.md, "Printing").

## Pointers

`ptr_target` reads a `Ptr(T)`, which `jt` writes as `PykRuntime.PykPtr<T>`.
`addressed_vars` finds every `var` `&` takes the address of; the module's
set is `ctx.addressed`, and `captured_vars` counts a body's own as
captured, so each lives in a cell. Such a cell holds the boxed type
(its binding's value is marked boxed, which `lift` reads to type the
cell it passes on), and a top-level one is a static cell rather than a
plain static. `address` compiles `&place`: a cell's `pointer(cell, 0)`
(the cell is the binding's value without its `[0]`), a store's
`pointer(i)`, a var struct's `pointer(s, k)`, and `&*p` as `p`. `EDeref`
is `get()`, `SSetDeref` one `set(v);`. A var struct's class gets
`pykSet`, which the pointer writes a field through.
