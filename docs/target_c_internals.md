# Inside `target_c.ml`

How the C backend is built. What it compiles to, and why, is
[target_c.md](target_c.md).

## Types come from the checker

`type_of` reads an expression's type out of `tmap`, at the instance
being written: `ctx.sigma` is what each type variable of that instance
stands for, and every type is substituted by it. `ctype` writes a
Pyking type as C and declares a compound one once in the file (`types`,
with its builder in `helpers`); `code` is the name every compound type
and every instance is built from. `holds_itself` is the test that
refuses a datatype holding itself.

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
out of one. `function_value` makes a closure: a wrapper taking the
environment first, the environment where the def captures anything, and
the plain function where it does not. `host_arguments` hands a host its
callback as a plain function.

## Liveness

`unreferenced` is whether a def is reached from its block's live code,
transitively; one that is not is not compiled, since the checker never
worked out its types.
