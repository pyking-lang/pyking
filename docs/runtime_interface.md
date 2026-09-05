# `runtime_interface.ml`: design

How `src/runtime_interface.ml` draws the line between a Pyking program
and the outside world, and why it is its own module rather than living
inside a backend. For where this fits in the pipeline, see
[architecture.md](architecture.md), "The runtime interface"; for a
one-page summary, see [source.md](source.md#runtime_interfaceml).

## The WebAssembly split, applied here

A Pyking program on its own only computes — nothing in the *language*
can reach a console, a file, or a clock. Everything a program can be
*observed* to do crosses a boundary this module writes down, in the
same spirit as WebAssembly's own split between a core language that
cannot touch anything outside its own linear memory and a separate host
specification that says what a module may import and call. The point
of drawing that line explicitly, rather than letting `print` be
whatever each backend's host language happens to call output, is that
it turns "what can a Pyking program do to the world" into a closed,
readable list — right now, one entry — instead of an implicit property
of nine different code generators.

`Operation(name, variadic, doc)` is the whole vocabulary for describing
one crossing point: a name a program can call, whether it takes a fixed
or open-ended number of arguments, and a description of what it does
and what it produces. `PRINT` is the only one defined today —
`OPERATIONS = (PRINT,)` — and `lookup(name)` is how every other module
in the compiler asks "is this name one of *those*, or an ordinary
Pyking name?" without needing to know how many operations exist or
maintain its own copy of the list.

## No host code, on purpose

The module docstring is emphatic about this, and it's worth
understanding why it matters rather than taking it as a style rule:
**this file contains no host code at all** — no Python, no JavaScript,
nothing from the interpreter; nothing here decides how `print` actually
writes a line on any
host. What it *does* pin down is the part every host has to agree on
regardless of how it writes that line: the formatting rules —

- arguments are formatted individually and joined with single spaces,
  then a newline;
- a string prints bare (no quotes);
- an integer prints in base 10;
- unit prints as `()` — never a host's own word for "nothing," not
  Python's `None`, not JavaScript's `undefined`;
- a boolean prints as `true`/`false`, Pyking's own spelling, not any
  host language's.

If those rules lived in each backend instead, "does a Pyking program
print the same thing under `node prog.js` as under `python3 prog.py`"
would be nine separate claims to keep in sync by hand, checked (if at
all) by remembering to. Because they live here once, every backend
implementing `print` is implementing the *same* specification, and
`type_inference.md`'s note about a real bug this design caught (`str`
capitalizing a Bool under one backend and not another, found because
the interpreter — this module's most literal implementation — disagreed
with the generated Python) is the kind of thing centralizing the rule
is meant to prevent, not just describe after the fact.

## How a backend actually binds to it

Nothing here is executable in the sense of *doing* I/O — it's a
description, and every backend consults it the same way, at the same
point in translation: recognizing that a call is *to* the runtime
interface rather than to an ordinary Pyking function.

```ocaml
| ECall (info, EVar (_, name, _), args, _)
  when Runtime_interface.lookup name <> None -> ...
```

That guard appears, nearly verbatim, in `target_python.ml`,
`target_js_core.ml`, `target_c.ml`, `target_java.ml`, and
`target_ocaml.ml` — every backend's expression translator has exactly
one arm gated on `Runtime_interface.lookup`, because that's the
one place a call needs different treatment than an ordinary function
call: not "translate `func(args)` as a call," but "translate this as
whatever *this host* does to produce output." What differs from there
is entirely host-specific and lives in each backend, not here:

- **`target_js_core.ml`** doesn't even decide what the call looks like
  in JavaScript — it emits a `JsRuntimeCall(operation, args)` node and
  leaves the actual spelling (`print(...)` vs. `runtime.print(...)`) to
  `target_js_packaging.ml`, since that's the one thing the three
  JavaScript targets disagree about. See that module's own page.
- **`target_c.ml`**/**`target_java.ml`** turn it into `printf(...)`/
  `System.out.println(...)`, with their own type-driven formatting
  glue for the parts C and Java don't spell the way Pyking does (see
  their internals pages for why a `Bool` needs a conditional in C but
  not in Java).
- **`target_ocaml.ml`** turns it into `print_endline`, needing almost
  no glue at all, since OCaml already spells `true`/`false`/`()`
  exactly as Pyking does.
- **`interpreter.ml`** is the one consumer that doesn't translate
  anything — it *performs* the operation directly, through a `Host`
  object (`ConsoleHost`, `BufferHost`, `CallbackHost`), since the
  interpreter runs a program rather than emitting one. Its
  `format_value`/`display_value` are this module's formatting rules
  implemented for real, and — being the reference implementation for
  the whole language — are the one place a disagreement between this
  specification and an actual implementation would be a bug in the
  *interpreter*, not in the spec.

## Adding an operation

The docstring's closing line — "add an operation here first; the
backends then bind it" — is the intended order of work, not just a
suggestion: a new host capability starts as an `Operation` entry in
`OPERATIONS`, with its semantics written into `doc` the way `PRINT`'s
are, *before* any backend is taught to emit anything for it. That
ordering is what keeps this module the single source of truth for what
a Pyking program may observe — a backend that implemented some
capability without an entry here would be granting a program access to
the world that no other backend, and no specification, agreed to.
