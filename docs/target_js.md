# The JavaScript targets

**Targets in this family:** `nodejs`, `html`, `esm`.

**Key points**

- One translation, `src/target_js_core.py`; three packagings,
  `src/target_js_packaging.py`. The targets accept exactly the same
  programs and differ only in **where `print` goes** and what files come
  out.
- JavaScript fits Pyking better than Python does: `const` is an immutable
  binding, `let` a mutable one, and `{ }` blocks are scopes — so `=`,
  `var`, `:=` and block scoping map straight across, with far less
  rewriting than the Python target needs.
- They implement a **subset** of the language: no lists, tuples, `for`,
  `match`, comprehensions or value-form bindings. Anything outside it is
  refused with a source position.
- `print` is the one thing crossing the runtime boundary
  (`src/runtime_interface.py`), and the three targets bind it three
  ways: `console.log`, a page element, or a function the embedder passes
  in.
- Least optimal at: float display (`6` where Python prints `6.0`), and
  renaming more shadowed bindings than JavaScript strictly requires.

## The three targets

| target | files | `print` goes to | notes |
|---|---|---|---|
| `nodejs` | `foo.js` | `console.log`, called directly | self-contained; `node foo.js` |
| `html` | `foo.html` | a visible box on the page | self-contained; opens from disk |
| `esm` | `foo.js`, `foo.node.js`, `foo.html`, `package.json` | a function the embedder supplies | the page wrapper must be *served* |

`esm` is the one worth understanding. The module reaches nothing by
itself — it exports `run(runtime)` and prints through `runtime.print`:

```js
export function run(runtime) {
  let i = 0;
  while (i < 5) {
    runtime.print(i);
    i = i + 1;
  }
}
```

so the same module prints to a terminal under the generated node driver,
onto the page under the generated HTML wrapper, and could just as well
print into a debugger, a test harness, or a text box in someone else's
application — with no recompilation. Running either wrapper behaves
exactly like the `nodejs` and `html` targets.

The `package.json` (`{ "type": "module" }`) is what lets those files be
plain `.js`: node decides a file's module system from its extension
first and the nearest manifest second, so `.js` without one means
CommonJS and the driver's `import` fails. An existing `package.json` is
never overwritten — it belongs to whatever project the output landed in.

The `esm` HTML wrapper *imports* the module, and browsers refuse module
imports over `file://`, so it needs serving (`python3 -m http.server`).
The standalone `html` target embeds the program instead, which is why it
exists as a separate target rather than as a wrapper.

## What is supported

`print`; `def` with parameters, `return`, recursion, and the
single-expression `def f(x) = e` form; `if` / `else if` / `else`;
`while`; `=`, `var`, `:=`; `if … then … else …` expressions; integers,
strings and booleans; `+ - * /`, unary minus, comparisons, and calls.
Nested `def` works too — JavaScript has closures.

## What is not supported

Refused at compile time, with the source position:

| construct | why |
|---|---|
| lists, tuples, tuple destructuring | no value representation yet in the JS AST |
| `for` loops | needs the iterable protocol the lists work would bring |
| `match`/`case`, patterns | needs a pattern compiler; JavaScript has no `match` |
| list comprehensions | builds on lists and patterns |
| value-form `x = if c:` / `x = match e:` | needs the statement forms above |
| `str`, `len`, `range` | no JavaScript standard-library shim yet |

```
$ python3 src/pykboot.py -t nodejs tests/for_simple.pyk
'tests/for_simple.pyk' 2:0-3:22 Unsupported by target 'nodejs': `for` loops
are not supported by the JavaScript backends yet
```

## How things compile

### Bindings

The mapping is exact, which is the nicest thing about this backend:

```pyking                          // generated JavaScript
x = 1                              const x = 1;
var total = 0                      let total = 0;
total := total + x                 total = total + x;
print(x, total)                    print(x, total);
```

`=` really is `const` — a rebinding gets a fresh `const`, not a
reassignment — and `var`/`:=` really are `let` and assignment.

### Control flow, functions, expressions

```pyking
def sign(n) = if n < 0 then "neg" else "pos"


def classify(n):
    if n < 0:
        return "low"
    else if n == 0:
        return "zero"
    else:
        return "high"


var i = 0
while i < 2:
    print(sign(i), classify(i), "a" == "b")
    i := i + 1
```

```js
function sign(n) {
  return n < 0 ? 'neg' : 'pos';
}

function classify(n) {
  if (n < 0) {
    return 'low';
  } else if (n === 0) {
    return 'zero';
  } else {
    return 'high';
  }
}

let i = 0;
while (i < 2) {
  print(sign(i), classify(i), 'a' === 'b');
  i = i + 1;
}
```

Note `===`, not `==`: Pyking compares integers, strings and booleans, and
JavaScript's loose equality would relate values across those types.
Function definitions are set off with a blank line before and after, the
spacing a JavaScript programmer would write.

### `print` and the runtime boundary

A `print` call is not an ordinary call: it crosses the runtime interface,
so the core emits a `JsRuntimeCall` and lets the packager decide what it
looks like. Self-contained targets get a **prelude**, delimited so it is
obvious which lines came from the `.pyk` file:

```js
// --- prelude begins ---
// A Pyking program cannot do I/O by itself; its host must define `print`.

function pykFormat(value) {
  return String(value);
}

function print(...values) {
  console.log(values.map(pykFormat).join(' '));
}

// --- prelude ends; the compiled program follows ---
```

`pykFormat` exists because the runtime interface fixes how values print,
and it is where a future value type that *does* need converting would
land — but today `String(value)` alone already gets every current type
right, including booleans: JavaScript already spells them `true`/`false`,
exactly Pyking's own spelling (see PYKING.md), so there is nothing left
to convert. (This used to be the one place JavaScript disagreed with
Pyking's formatting, back when Pyking printed booleans the Python way,
capitalised — see `docs/target_python.md`'s "Booleans" for the backend
that now has the opposite problem, having to *override* its native
`True`/`False` to match.) The `html` target substitutes a `print` that
appends to a `<pre>` on the page; `esm` has no prelude at all, since it
is handed a `runtime` instead of building one.

### Scope and renaming

JavaScript blocks are scopes, so shadowing across blocks needs no help at
all — a `const` inside `{ }` simply shadows the outer one, which is
exactly Pyking's rule. Renaming is still needed for two JavaScript-
specific reasons: `const` cannot be redeclared in one block (and Pyking's
`x = 1; x = 2` is two bindings), and a `const` shadowing an outer name
makes that name unreadable *earlier in the same block* — the temporal
dead zone — so

```pyking
x = 1
if 1 < 2:
    print(x)     # Pyking: the outer x
    x = 2        # a new binding
```

would throw rather than read the outer `x` if both were called `x`.

*Not optimal:* rather than detect exactly which shadows hit the dead
zone, the backend renames whenever a name is already in scope. That is
always correct and sometimes unnecessary, so generated code occasionally
says `x2` where plain `x` would have been fine.

### Numbers

Pyking's `/` is Python's true division, so `(4 + 8) / 2` is a float and
Python prints `6.0`. JavaScript has a single number type and prints `6`.
The value is right; only the rendering differs.

*Not optimal, and deliberately so:* matching Python exactly would mean
carrying the int/float distinction into the generated code — integers as
`BigInt`, division as `Number`, and a coercion helper wrapped around
every arithmetic operator and comparison. That would cost the thing this
backend is built for: output that reads like the source. Programs whose
printed output contains a float are therefore marked python-only in
`tests/test_cases.toml` (`arithmetic_division.pyk`,
`short_function_values.pyk`).

## Where the output is not optimal

- **Float display**, as above.
- **Over-eager renaming** around the temporal dead zone, as above.
- **`pykFormat` on every printed value**, including integers that
  `String()` would have handled — one code path is easier to keep
  consistent across three hosts than three special cases.
- **Duplicated formatting in the `esm` wrappers.** Each wrapper carries
  its own few lines of `pykFormat` rather than importing one, because
  formatting is what a *host* does with the values it is handed; a module
  that formatted its own output would already have decided what output
  looks like.
- **No optimisation.** The backend is a printer: no constant folding, no
  dead-code elimination, no tail calls.
