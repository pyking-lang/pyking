# `target_js_packaging.ml`: design

How `src/target_js_packaging.ml` turns one JavaScript translation into
three different targets, and why the formatting helper is duplicated
into each host rather than shared. For what `nodejs`/`html`/`esm`
support and how a program behaves once compiled, see
[target_js.md](target_js.md); for the translation this module packages,
see [target_js_core.md](target_js_core.md); for a one-page summary, see
[source.md](source.md#target_js_packagingml).

## One translation, three files, one difference between them

`target_js_core.ml` does all the actual work of turning Pyking into
JavaScript, and produces the *same* output regardless of which of the
three JS targets is chosen — the only thing that differs across
`nodejs`, `html`, and `esm` is **where `print` goes**, which is exactly
the one place the core deferred a decision by emitting `JsRuntimeCall`
instead of a concrete call (see that module's page). This module is
where the deferred decision finally gets made, three different ways:

```ocaml
package_nodejs ...:      pprint_js_program js_program (host "print" ...)
package_html ...:        pprint_js_program js_program (host "print" ...)
package_esm_module ...:  pprint_js_program js_program (host "runtime.print" ...)
```

`nodejs` and `html` both spell it `print` — a bare function name — but
they're not the same `print`: each target additionally *defines* one,
right above the compiled program, wired to a different sink
(`console.log` for `nodejs`, a DOM element's `textContent` for `html`).
`esm` doesn't define anything at all; it spells the call
`runtime.print`, because the whole premise of that target is that the
compiled module doesn't decide what "print" means — it receives a
`runtime` object as a parameter and calls whatever that object
supplies. That's the mechanism behind `target_js.md`'s claim that the
`esm` module "reaches nothing by itself": there's no `print` definition
inside it at all, only a call to a name that has to arrive from outside.

## The prelude: visibly separated from the compiled program

`nodejs` and `html` are meant to be **self-contained** — one file,
runnable or openable with nothing else — so each one carries its own
`print` definition (and the shared `pykFormat` helper) directly ahead
of the compiled program. `_prelude(*parts)` wraps that host code
between `_PRELUDE_BEGIN`/`_PRELUDE_END` marker comments specifically so
a reader looking at the generated `.js` file can tell at a glance which
lines came from the `.pyk` source and which are harness the packager
added — the same convention `target_python.ml`'s Bool-formatting helper
and comprehension-pattern helper both follow (see
[target_python_internals.md](target_python_internals.md)), for the
identical reason: generated boilerplate should never be mistaken for a
translation of something the program actually wrote. `esm`'s own
module has no prelude at all, which `prelude`'s docstring calls out
explicitly — not an oversight, but the same boundary drawn a different
way: instead of defining host code inline, the module simply declines
to have any, and expects it from its caller.

## `pykFormat`: copied, not shared, on purpose

Every host defines its own copy of `_FORMAT_JS` — a tiny function
converting a computed value to `runtime_interface.ml`'s printed form (a
Bool prints `true`/`false` in JavaScript already; the one thing that
needs converting is `undefined`, which is what a unit-returning
function actually evaluates to, and which has to print as `()`). Three
copies of eleven lines might look like something a shared module should
own instead — but the formatting rules belong to a **host**, not to the
compiler, and a module in the compiled program that formatted its own
output would already have made a decision that isn't the compiler's to
make (see `runtime_interface.ml`'s own page: this module deliberately
holds no host code at all). Each packaged target *is* one host, and
each one gets its own copy for the same reason `ConsoleHost`,
`BufferHost`, and `CallbackHost` in `interpreter.ml` are three separate
classes rather than one parameterized by a callback that also happens
to format — formatting and delivering are the same operation, performed
by whoever owns the sink.

## Modules: three ways to cross a boundary

`package_program` is where a program of several modules is put together,
and the three targets diverge more here than anywhere else -- see
[target_js.md](target_js.md), "Modules", for the generated code.

The shape they share is that the *body* of a module is the same text in
all three: `target_js_core.ml` translates it once, and only the import
lines and the export line differ. `nodejs_import`, `esm_import` and
`page_import` are those three spellings, handed to the core inside a
`JsHost` exactly as the `print` spelling is.

Two things are this module's alone. **The runtime module.** A `nodejs`
program of several files would otherwise carry a copy of `pykFormat` and
`print` in each one, so they move into `pyk-runtime.js`, required by
every module that prints. The hyphen in the name is the point: a Pyking
module is imported by name, so its file's stem is an identifier, and no
Pyking module can ever be called that. **The page's helpers.** A page is
one scope, so `pykList` and `pykConcat` are emitted once for the whole
program rather than once per module -- which is what
`pprint_js_program`'s `helpers=False` and `js_helpers` are for.

A program of *one* module goes down the path it always did, in all three
targets: a self-contained script, a self-contained page, and a module
with its wrappers.

## `esm`: four files from one stem

Every other target writes exactly the path it's given. `esm` can't,
because it produces a module, a node driver, an HTML wrapper, and a
manifest — four files, whose *endings* aren't the caller's to pick
(`out/prog.node.js` has to end in exactly that, or node driver
conventions break). `esm_paths(output_path)` resolves this by treating
whatever path it's handed as a **stem**: `output_stem` strips off any
already-known extension first (so `--output out/prog`, `--output
out/prog.js`, and `--output out/prog.html` all normalize to the same
`out/prog`), and `esm_paths` then appends the four real endings onto
that shared stem. `package(target, ...)`'s `"esm"` case is the only one
returning more than a single-entry dict — `{path: contents}` for all
four at once — which is what lets `pyk.ml`'s driver write every file a
target produces through one uniform interface, without needing to know
in advance how many files any particular target writes.

`MODULE_MANIFEST_JSON` (`{"type": "module"}`) is what lets the module
and the node driver be plain `.js` files rather than `.mjs`: Node
decides a file's module system from its extension first and the
nearest `package.json` second, so without this manifest a `.js` file
reads as CommonJS and the driver's `import` fails. `manifest_declares_module`
exists because this manifest is never blindly overwritten — an existing
`package.json` belongs to whatever project the output landed in, so the
driver checks (via this function) whether it already says `"type":
"module"` before deciding whether to write one at all, rather than
clobbering a file this module didn't create.
