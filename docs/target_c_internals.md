# Inside `target_c.ml`

How the C backend is built. What it compiles to, and why, is
[target_c.md](target_c.md).

## Types come from the checker

`type_of` reads an expression's type out of `tmap`, at the instance
being written: `ctx.sigma` is what each type variable of that instance
stands for, and every type is substituted by it. `ctype` writes a
Pyking type as C and declares a compound one once in the file (`types`,
with its builder in `helpers`); `code` is the name every compound type
and every instance is built from. `holds_itself` is the test for a
datatype holding itself, through a list too, which `boxed` turns into
the pointer c23-gc writes and plain C refuses.

## Two kinds of target

`standard_of` splits a target into its standard and whether it links
the collector: `c23-gc` is `("c23", true)`, which sets `ctx.gc`. Every
construct only c23-gc compiles is behind `ctx.gc`; on plain C the same
construct reaches a refusal whose text says c23-gc compiles it
(`heap_reason`, `escaping`, the datatype refusal in `ctype`). Plain C's
output is meant to stay as plain as it is, so nothing c23-gc adds
reaches it.

## The allocator markers

A helper that allocates on both kinds of target writes a marker,
`\001M:atomic:\001(`, `\001M:scanned:\001(` or `\001M:resize:\001(`,
which `expand_captures ~gc` replaces once the target is known:
`GC_MALLOC_ATOMIC`, `GC_MALLOC` and `GC_REALLOC` on c23-gc, `malloc`
and `realloc` on plain C. What only c23-gc compiles -- cells, nodes,
environments -- names `GC_MALLOC` directly.

## The AST is text

An expression is a `cexpr`: its text, its precedence, and whether it is
a closure whose environment is in this function's own frame
(`local_env`), which `finished` refuses to return and the constructors
refuse to hold. A statement is a `cstmt`; `block` prints a block, and
under c89 moves every declaration to its top.

## Order

`in_order` translates an operation's pieces left to right and puts each
that can print, but the last, in a temporary declared at the top of the
function, with `sequenced` writing the assignments in front of the
result by the comma operator. `pre` holds the statements an expression
needs run first -- an environment to fill -- which the statement
translators put in front of the statement (`flush`).

## Arrays

`Array(T)` is a `TCon` like a datatype's, so every match on `TCon` --
`code`, `ctype`, `shower`, `holds_itself` -- tests for `array_name`
first. `ctype` declares the struct and `pyk_new_<code>`, which on
c23-gc asks `pyk_array_items` for the elements, choosing
`GC_MALLOC_ATOMIC` by `holds_pointers`, and on plain C mallocs them; `array_getter` writes
`pyk_at_<code>`; `make_array` compiles the four makers the elaborator
names (`list__array`, `fill__array`, `init__array`, `unfold__array`),
each a helper of the file but `list__array` of a list literal, which is
a comma expression. `SSetIndex` and `for x in a` are in `stmt` and
`loop`.

## Lists

On c23-gc `ctype` of `TList` declares the cell struct `pyk_l_<code>`
(`head`, `tail`) and its maker `pyk_cons_<code>`, and writes the type as
a pointer to it; `list_element` stands unit in for an element type
nothing settles. `list_helper` writes the per-type helpers on demand:
`length`, `nth` (checked, through `pyk_list_index`), `take`, `drop`,
`append` and `array` (`pyk_array_of_<code>`); `range_helper` is
`pyk_range`. `shower` writes `pyk_show_<code>`.

- `EList` is nested `pyk_cons_` calls over `in_order`'s pieces.
- `pattern` on a `PList` tests the cells present first and reads each
  element where it sits; elements after a rest are counted back from
  the end through `length` and `drop`, the rest itself a `take`.
- `comprehension` writes a comprehension as statements building into a
  named list through an end pointer, one `each` loop per `for` (over a
  `range`, a String, an array or a list, its pattern tested where it is
  refutable) and an `if` per condition. `tail` uses it where the
  comprehension is what a function answers or a block assigns, and
  `stmt` where it is a binding's value; anywhere else `expr` lifts it
  into a function of its own (`<family>_list`), through `lift_with`
  like a lambda, whose body is then that `return`.
- `loop` walks a list's cells for `for x in xs`.
- `empty_list` and `empty_binding` bind a name whose type is a list of
  an unsettled element to `NULL`, which is `[]` at every list type.
- `host_type` carries a list across to an external module as its cell
  pointer, and `translate_program` declares the cell types the host's
  signatures name, as it does their tuples.

## Datatypes holding themselves

On c23-gc `ctype` of a `boxed` datatype first declares it ahead
(`<name>_fwd`, `typedef struct X X;`), so the fields -- and list cells
-- reaching it again find it, then completes the struct and writes
makers that `GC_MALLOC` the value. `member_of` is `->` for one and `.`
otherwise, used by `pattern`, `EField`, `field_accessor` and `shower`.
`shower` keeps the printers it is writing in `st.building`; reaching
one again (two datatypes holding each other) declares it ahead in
`st.helper_protos`, which the printer writes before the helpers.

## Heap environments

On c23-gc `function_value` makes a closure's environment inside the
expression -- `(e = GC_MALLOC(sizeof *e), e->x = x, pyk_mk_...(w, e,
NULL))`, `e` a function temporary and the `C` capture marker the
assignments -- so it is never `local_env` and may be returned or held
anywhere; plain C keeps it on the stack, filled through `pre`. A `var`
a closure captures is a collected cell on c23-gc (`stmt`, `SVar`).

## Var structs and DynArrays

`var_struct` reads a datatype's `writable` flag. `boxed` is true for
one on every target, so `ctype` declares it ahead and its makers
allocate through the allocator markers (malloc on plain C), and
`member_of` reads it through `->`. `holds_itself` stops at a var
struct, an array and a DynArray -- each holds a pointer -- and `ctype`
declares ahead any datatype that reaches itself through one
(`type_children`, `reaches_type`), so it stays a value. `SSetField`
in `stmt` writes `p->x = v`, its owner in a temporary only where the
value could change what the owner names (`has_call`).

A DynArray is `TCon "DynArray"` beside `Array`: `is_store`, `dynarray_element` and
`store_element` tell them apart from datatypes. `ctype` declares
`pyk_v_<code>` and `pyk_new_<code>(n)`; `dynarray_helper` writes the rest on
demand (`push`, `pop`, `insert`, `remove`, `clear`, the checked `at`,
`of_list`), with c23-gc's checks and slot clearing behind `ctx.gc`.
`make_array` makes them (`empty__dynarray`, `list__dynarray`), `builtin` calls
them, and `loop`/`each` walk one by index against its length as it is.

## Equality, MutMaps, slices and views

`structural ctx st info kind t` writes `pyk_eq_<code>` (kind "eq") or
`pyk_hash_<code>` (kind "hash") for a list, a tuple or a datatype and
answers how to call it -- scalars inline -- with the same
`building`/`helper_protos` guard as `shower` for recursive types. `EEq`
and `BNeq` use it for every non-scalar operand. `mutmap_helper` writes a
MutMap's helpers on demand (`find`, `put`, `at`, `take`, `remove`, ...;
`slot` and `index` keep c23-gc's hash index), and `walk_of` is how a
`for` walks any store, a MutMap's with its version check. `run_helper`
writes `slice`, `view` and a view's `at`; `copy_helper` copy_into's
`memmove`. `is_store` covers Array, DynArray, Slice and MutMap -- the TCons
that are not datatypes.

## Pointers

`Ptr` is in `is_store` (a TCon that is not a datatype) but not in
`store_element`; `ctype` writes it as C's `T *`. `expr` compiles `EAddr`
by its place and `EDeref` as `*`; `stmt` compiles `SSetDeref` as
`SSetField`'s write is ordered. `cells_of` adds, on c23-gc, the local
`var`s whose address is taken (`address_taken`) to the cells a body
keeps; on plain C `check_local_addresses`, run by `function_of`,
refuses an address of a local that could leave the function, tracking
the locals that hold one. A `var` declared in a block of the top level (a loop's
body) is a local of `main`, declared anew each time: `translate_program`
gives it a cell where a closure captures it or, on c23-gc, its address
is taken, made where it is declared -- a new one each turn -- and runs
the plain C check over the top level too, its own `var`s, statics,
left out.

## Printing and the path

`shower_at` writes a printer and answers a function of the value's text
and the path's; a path cell is `at` and, for a datatype copied by
value, `alike` (`alike_helper`, `shallow`); `shower` starts the path at NULL. `cyclic` is a store
whose own contents reach its type -- the only printers that guard
themselves with `pyk_on_path` and push a `pyk_path` cell -- and
`needs_path` a type that reaches one, whose printer takes `up` and
passes it on. Every other printer keeps its one parameter.

## Order beyond printing

`in_order` pins an operand that may print before a later one that
prints, and also an operand `stable` says a call could change -- a
captured or top-level `var` (`var$` in `st.taken`), a var struct's
field, an element, a DynArray's length, a call -- before a later operand
with a call that can change something (`has_call`, reading
`ctx.changing`, which `changes` works out per module by a fixed point
over its defs, as `Analyses.effects` does for printing), and
an operand with a call before a later unstable one. `print_call`
additionally pins every argument when one holding a store comes before
an argument with a call, so all are worked out before any is formatted.

## Instances

A polymorphic def is a `template`, kept with the scope it was written
in. `instance` works out what a call asks of one, by `matching` its type
against the call's result and arguments, and adds the instance to
`pending`; `drain` compiles what is pending, which may ask for more.
A call to another module's polymorphic function records a request and a
prototype instead, and `translate_all` translates a program's modules
until no module asks for a new one.

## Lifting and closures

`declare_defs`, `lift` and `lift_with` lift a nested def, as in the Java
backend, with markers for its captures that `expand_captures` fills in:
`A` the arguments, `P` the parameters, `E` an environment's members, `S`
the assignments filling one, and `U` the arguments a wrapper reads back
out of one, and `C` (c23-gc) the comma-separated assignments filling a
heap environment. `function_value` makes a closure: a wrapper taking the
environment first, the environment where the def captures anything, and
the plain function where it does not. `host_arguments` hands a host its
callback as a plain function.

## Liveness

`unreferenced` is whether a def is reached from its block's live code,
transitively; one that is not is not compiled, since the checker never
worked out its types.
