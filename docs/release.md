# `release.ml`: design

`pyk compile --release` compiles a program in release mode: every call to
the builtin `debug` is removed, arguments and all, and `print` is kept.
`src/release.ml` is the pass that does it, one rewrite from the Pyking
AST to the Pyking AST.

## Where it runs

After the type checker and `elaborate.ml`, and before the tail-call
pass, for every module of the program. After the checker because the
checker's table is what tells the builtin from a definition a program
named `debug` (below), and because the rewrite preserves typing, so
nothing needs checking again. Before the tail-call pass because a
removed `debug` can leave a call in tail position that was not before,
and the pass should see it there.

It is a pass rather than a flag each backend reads, for the reason the
tail-call pass is: what comes out is ordinary Pyking, so no backend --
and not `-t pyking`, which prints what was compiled -- knows it exists.
The interpreter takes no `--release` and runs a program as written.
`iweb` compiles nothing, so its page is told to run the pass itself:
it asks the bundle for `pykRunProgram('<main>\nrelease')`.

## Which calls

A call whose callee is the name `debug` is the builtin only where no
definition of the program took the name. The checker records a type for
every callee it resolved to a definition and none for a builtin, so a
callee with no entry in `tmap` is the builtin. A program's own
`def debug(x: Int) -> Int` is called as it was written
(`tests/typecheck_release_shadow.pyk`).

## What replaces a call

`debug(...)` is worth unit, and in value position it becomes `()`, under
the call's own symbol, so the type the checker recorded for it still
applies:

```pyking
nothing = debug("computing")     ->    nothing = ()
```

A call written as a statement is dropped. The one place that cannot be
done blindly is the last statement of a block whose value is used -- a
function body, a branch, a loop's body -- since the block would then be
worth what came before it instead of unit. There the statement is
dropped where what comes before it leaves unit anyway (a binding, or an
expression statement the checker typed `()`), and otherwise stays as the
statement `()`:

```pyking
def report(x: Int):                    def report(x:Int) -> ():
    if x > 2:                              if x > 2:
        debug("large", x)        ->            ()
    else:                                  else:
        print("small", x)                      print('small', x)
```

Every backend compiles the statement `()` to nothing: Python, JavaScript
and OCaml say it as they would any unit, and C and Java, which have no
unit value, emit no statement for it. A module's top level has no value,
so a `debug` there is always dropped.

The arguments go with the call: a `debug` whose argument calls a
function that prints no longer prints. That is the point of the mode,
and the reason `debug` exists beside `print` at all.

## Where the output is not optimal

A branch that was only a `debug` is kept as `()` when its block's value
is used, even where nothing reads it -- an `if` statement's branches,
say, when the `if` is the last statement of a function returning unit.
Telling those apart would need the question "is this block's value
read", which only the backends answer today.

## Tests

`tests/typecheck_release.pyk`, `tests/typecheck_release_values.pyk` and
`tests/typecheck_release_shadow.pyk` carry `release = true` in the
manifest: every compiled target is built with `--release` and must then
write nothing to standard error, and each `.ast.out` pins the program
the pass produced.
