# `target_js_packaging.ml`: design

How `src/target_js_packaging.ml` turns `target_js_core.ml`'s compiled
JavaScript into files a host can run. For what each construct compiles
to see [target_js.md](target_js.md); for the core see
[target_js_core.md](target_js_core.md); for a one-page summary see
[source.md](source.md#target_js_packagingml).

## One emission, three targets

`node`, `web` and `iweb` share this module, and the first two share
almost all of it: **the JavaScript they emit is identical**. Both are ES
modules, both print with `console.log`, and both compile one Pyking
module to one `.js` file. `web` adds an HTML file that loads the
program; that is the whole of the difference.

That is a recent simplification worth knowing about, because the shape
of this file still shows where it came from. There used to be three JS
targets — a CommonJS `nodejs`, an `esm` that exported `run(runtime)` with
a node driver and an HTML wrapper beside it, and an `html` that inlined
every module into one page — and each needed its own spelling for an
import, an export and `print`. Making everything an ES module removed
all three variations at once: `require`/`module.exports` went, the
`init(runtime)` protocol went, and the page stopped being a special case
in which modules could not be files.

## ES modules do the module system's work

`interpreted_page` aside, this module writes almost no glue, because ES
modules already mean what Pyking means:

- a module's top level runs **once**, the first time something imports
  it;
- imports resolve **before** the importing file runs.

Together those are exactly "every module runs after everything it
imports". So there is no `init` to generate, no order for the program to
arrange, and no bookkeeping to get wrong. `js_module` writes the body,
an `import` line per Pyking import, and an `export` clause for a
module's public names — and stops.

`module_import` is the one place a spelling is decided: a module reached
under its own name is a namespace import (`import * as helper from
'./helper.js'`), and a `from` line names what it takes, with `as` for a
rename. Note `as` and not `:` — an import clause is not an object
pattern, and writing it as one is a syntax error rather than a wrong
answer, which is how the mistake was found.

## `print` lives in a module of its own

`pyk-runtime.js` holds `print` and the value formatting
`builtin.ml` lays down, and every file of a program imports it
rather than carrying its own copy. One definition, so a program cannot
print two ways; and a module that prints nothing imports nothing.

`pykFormat` tells a Pyking list, array and tuple apart -- all three are
JavaScript arrays -- by the marker the program put on it: `pykList` for
a list, `pykArray` for an array (printed `array([...])`), `pykDynArray`
for a DynArray (printed `dynarray([...])`), none for a tuple; a MutMap is a `Map`
marked `pykMutMap`, printed `mutmap([...])` with its entries as tuples
(`map([...])` where it is also marked `pykMap`, a Pyking Map);
a view is an object marked `pykView`, printed `view([...])` with its
array's elements, and on the cycle path it stands for that array; a
pointer (`pykPtr`) prints `Ptr(...)` with what it points at, and stands
for its store on the path. `pykShaped`'s
descriptor has `{s}` for an array, `<s>` for a DynArray, `v{s}` for a view,
`p(s)` for a pointer, `d(s,s)` for a datatype's value by its type
arguments (its fields read through the constructor's `pykFields`
template, `$i` the i-th argument) and `@(k,v)` for a MutMap or Map whose parts need their type to print, beside `[s]` for a list (target_js.md,
"Arrays" and "DynArrays"). The checks an array makes, and `pykFail`, which reports a
runtime error, are the program module's own helpers rather than this
module's, written only where a program uses them.

`pykFormat` walks with a path -- the values it is inside of -- and
prints `...` for a value already on it, so an array or a `var struct`
that holds itself prints its cycle once, while a value that is only
shared prints in full each time (interpreter.ml's `display_value`;
target_js.md, "Mutable structs"). `pykShaped` passes the path on, and
`pykLater` is a `print` argument whose descriptor waits until every
argument is worked out. A module whose program reports a missing MutMap
key (`pykMutMapGet`, `pykMutMapRemove`) imports `pykShaped` for it even
where it prints nothing itself. `format_js` is also what the playground's
worker reads (`pykFormatHelper`), so the path is a parameter with a
default rather than a variable at the module's top level, which an
indirect `eval` would keep to itself.

Both targets send it to `console.log`. The page deliberately does *not*
print onto itself: what a compiled program prints should be what `node
foo.js` prints, and a reader comparing the two should not have to
account for a difference.

## `web`: the page is a loader

```html
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>foo.pyk</title>
<script type="module" src="./foo.js"></script>
```

Nothing visible, because there is nothing to show. The output is in the
browser console.

A page of ES modules must be **served** — a browser refuses a module
fetched over `file://` — which is why `--run` starts
`pyk serve` rather than opening the file.

## `iweb`: shipping the interpreter instead

`interpreted_page` is the one function here that does not package
compiled code, because `iweb` compiles none. The page carries the
program's Pyking **source**, the compiler built to JavaScript
(`pyking.js`), and three lines that put them together: the sources into
`pykSources`, the external modules into `pykExternals`, and a call to
`pykRunProgram`.

The point is coverage. A backend supports a subset; the interpreter
supports everything `src/typesystem.ml` accepts, so a program using
`for`, `while`, `match` or lists runs in a browser here where `web`
refuses it. The price is the interpreter's size and interpreted speed.

Sources are fetched rather than inlined so the page stays readable and
the `.pyk` files stay files — a reader can open one. It is served
either way, so the fetch costs nothing extra.

## What is not here

Naming the output files, and copying an external module's
implementation, are the driver's (`pyk.ml`). This module answers with
`(path, contents)` pairs and writes nothing itself, which is what lets
the same code serve `--stdout`, a real compile, and the browser
playground.
