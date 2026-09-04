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

`print`; `def` with parameters, `return` and recursion, its body
written under the header or on the header's own line (`def f(x): e`);
`if` / `else if` / `else`;
`while`; `loop` with `break` and `continue`; `=`, `var`, `:=`; tuples,
including a binding that takes one apart; `if … then … else …`
expressions; integers, strings and booleans; `+ - * /`, unary minus,
comparisons, and calls. Tail position and `return if c:` are supported
(see below); nested `def` works too — JavaScript has closures.

## What is not supported

Refused at compile time, with the source position:

| construct | why |
|---|---|
| `for` loops | needs the iterable protocol |
| value-form `x = if c:` / `x = match e:` | a JavaScript block is not an expression, so a value taken from one needs a temporary this backend does not build |
| `str`, `len`, `range` | no JavaScript standard-library shim yet |

`++` is `pykConcat`, which looks at its left operand: a Pyking list is
an array and JavaScript's `+` would stringify one, so which of the two
`++` means is decided at run time. This backend infers no types, so
that is the same answer `pykFormat` gives for printing.

Lists, list comprehensions and `match` *are* supported. A Pyking tuple
is a JavaScript array, so a **list is an array carrying a marker** --
`pykList` in the compiled program sets it, and `pykFormat` reads it to
tell `[1, 2]` from `(1, 2)`. It is a property rather than a class
because for the `esm` target the program and the formatter live in
different modules, where two `class` declarations would not be the same
class. A `match` becomes an if/else chain over the subject, held in a
name of its own so it is evaluated once; an arm whose pattern always
matches becomes the `else`, so a `match` that fits nothing does nothing.

```
$ pyk compile -t nodejs tests/for_simple.pyk
'tests/for_simple.pyk' 2:0-3:22 Unsupported by target 'nodejs': `for`
  loops are not supported by the JavaScript backends yet
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

### Tuples

A tuple is a JavaScript array — built, taken apart and printed as one:

```pyking                          // generated JavaScript
pair = (1, true)                   const pair = [1, true];
a, b = pair                        const [a, b] = pair;
print(pair)                        print(pair);        // (1, true)
```

Destructuring is JavaScript's own array pattern, which fits exactly.
Printing is where the two languages part: `pykFormat` (see "`print` and
the runtime boundary") writes an array in Pyking's notation — `()`,
`(1,)`, `(1, 2)` — with strings inside it quoted, since that is what
`runtime_interface.py` says a tuple looks like.

Lists have no representation yet, so an array unambiguously means a
tuple here. That is what makes this formatting rule safe today, and is
the thing to revisit when lists arrive: the two will need telling apart.

### `loop`, `break` and `continue`

A `loop` is `while (true)` over a `let` holding the accumulator: the
initializer gives it its first value, every tail of the body assigns the
next one, and `break`/`continue` are JavaScript's own — with the
operand, where one is written, assigned first.

```pyking                          // generated JavaScript
res = loop x = 5:                  let x = 5;
    if x <= 10:                    while (true) {
        continue x + 1               if (x <= 10) {
    else:                              x = x + 1;
        break                          continue;
                                     } else {
                                       break;
                                     }
                                   }
                                   const res = x;
```

The loop's own value is what it `break`s with, so binding one is that
`const` after the loop, and a loop in tail position is `return x`. A
tuple accumulator is an array, assigned as a whole
(`[x, y] = [x + 1, y]`), so the next turn's values are computed before
any of them is stored -- and where such a loop breaks with something
that is *not* that array (`break acc` in a loop carrying two values,
which is what the tail-call pass builds), the answer gets a `let` of its
own rather than being squeezed into the accumulator. A `loop:` carrying
nothing needs the same `let` for the same reason, since it has no
accumulator to squeeze anything into: `n = loop: break 7` binds `7`,
not `[]`. A bare `break` in such a loop leaves unit there, which is the
accumulator it was going round with.

That `let` is only half the answer, because a `for`/`while` has a second
way to stop: **running out**. The loop is then worth its accumulator
rather than whatever a `break` would have left (PYKING.md, "What a loop
is worth"), and JavaScript has no loop `else` to say so in — so a
second `let` carries the flag one would have been, set to `true` and
cleared by every `break`:

```pyking                          // generated JavaScript
loop acc = 0 for x in xs:          let acc = 0;
    if acc > limit:                let tmp1 = [];
        break acc                  let tmp2 = true;
    else:                          for (const x of xs) {
        continue acc + x             if (acc > limit) {
                                       tmp1 = acc; tmp2 = false; break;
                                     } else { acc = acc + x; continue; }
                                   }
                                   if (tmp2) { tmp1 = acc; }
```

The flag is built only where both ways out exist: a plain `loop:` can
end only by breaking, and a loop carrying nothing is worth the unit its
`let` already holds. `tests/loop_worth_ran_out.pyk` is the case, and the
C and Java backends answer the same question at their own generated
exhaustion test (`docs/target_c.md`).

The accumulator's `let` stands in the block *around* the loop, since
that is where it has to be declared, but the name is in scope only in
the loop's own body — so a second loop reusing the Pyking name gets a
fresh JavaScript one rather than a duplicate declaration, and a name the
accumulator shadowed means what it meant again afterwards.

#### A `def` inside a loop

That single `let` is one binding for every turn, which is exactly wrong
for a function written in the body: Pyking binds the accumulator afresh
on every turn, and a function outlives the turn it was written on, so
all of them would close over the last turn's value. Where the body
defines a function (`_defines_function`), the `let` becomes a *carrier*
holding what the next turn starts with, and the accumulator itself
becomes a `const` inside the body — one binding per turn, which is what
each function closes over:

```pyking                          // generated JavaScript
fns =                              let tmp1 = [0, pykList([])];
loop i, made = 0, []:              while (true) {
    def show(): i * 10               const [i, made] = tmp1;
    if i >= 3:                       function show() { return i * 10; }
        break made ++ [show]         ...
    else:                            tmp1 = [i + 1, pykConcat(made, pykList([show]))];
        continue i + 1,              continue;
                made ++ [show]     }
```

A loop with no function in its body keeps the plain `let`, so ordinary
output stays ordinary. A `for … of` header needs none of this:
JavaScript already gives each iteration its own binding for the element.

### Control flow, functions, expressions

```pyking
def sign(n): if n < 0 then "neg" else "pos"


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

### Tail position

A function body's last statement supplies its value (see "Tail position"
in PYKING.md), so a `return` is pushed down into it, recursively through
`if` branches:

```pyking                          // generated JavaScript
def pick(x, y, z):                 function pick(x, y, z) {
    if z > 5:                        if (z > 5) {
        x + y              ->          return x + y;
    else:                            } else {
        2 * x                          return 2 * x;
                                     }
                                   }
```

A `print` in tail position stays a statement -- it yields unit -- and a
tail that is a loop or a binding produces no value, so nothing is
returned. Such a function reports `undefined` in JavaScript, but Pyking's
unit prints `()` everywhere, so `pykFormat` converts it (see below)
rather than the generated function returning some stand-in value: this
is the one place a JS host already inspects a value, so the conversion
costs the compiled program nothing. `return if c:`
compiles the same way, written explicitly. (`return match e:` needs
`match`, which this family does not support yet.)

### `print` and the runtime boundary

A `print` call is not an ordinary call: it crosses the runtime interface,
so the core emits a `JsRuntimeCall` and lets the packager decide what it
looks like. Self-contained targets get a **prelude**, delimited so it is
obvious which lines came from the `.pyk` file:

```js
// --- prelude begins ---
// A Pyking program cannot do I/O by itself; its host must define `print`.

function pykFormat(value, inner) {
  if (value === undefined) return '()';
  if (typeof value === 'string') return inner ? pykQuote(value) : value;
  if (Array.isArray(value)) {
    const parts = value.map((element) => pykFormat(element, true));
    return parts.length === 1 ? '(' + parts[0] + ',)' : '(' + parts.join(', ') + ')';
  }
  return String(value);
}

function pykQuote(text) { /* ' quoted the way Pyking quotes */ }

function print(...values) {
  console.log(values.map((value) => pykFormat(value)).join(' '));
}

// --- prelude ends; the compiled program follows ---
```

`pykFormat` is where the runtime interface's formatting rules live.
Three cases need it. JavaScript's `undefined` — what a unit-returning
function actually gives back — is Pyking's `()`. An array is a tuple, and
prints in Pyking's notation rather than JavaScript's `[1,2]`. And a
string inside one is quoted, where a string printed on its own is not,
which is why the second parameter exists at all.

Everything else `String(value)` already gets right, booleans included:
JavaScript spells them `true`/`false`, exactly Pyking's own spelling
(see PYKING.md), so there is nothing to convert. (This used to be the one
place JavaScript disagreed with Pyking's formatting, back when Pyking
printed booleans the Python way, capitalised — see
`docs/target_python.md`'s "Booleans" for the backend that has the
opposite problem, having to *override* its native `True`/`False` to
match.)

Note the arrow function in `print`: `values.map(pykFormat)` would hand
`map`'s *index* argument to `inner`, and every argument after the first
would print as though it were nested. The `html` target substitutes a
`print` that appends to a `<pre>` on the page; `esm` has no prelude at
all, since it is handed a `runtime` instead of building one.

### Names that are keywords in JavaScript

A name can be a good Pyking identifier and a reserved word in JavaScript
-- `class`, `function`, `new`, `typeof`, `delete`, `super`, and the rest,
plus the strict-mode-only ones (generated code is `const`/`let`
throughout, so it is effectively strict). Such a name is renamed by the
same mechanism that handles shadowing below:

```pyking                          // generated JavaScript
def class(n):                      function class2(n) {
    n * 2                  ->        return n * 2;
                                   }
```

The list (`RESERVED` in `src/target_js_core.py`) also holds a few
globals a generated file leans on -- `undefined`, `console`, `String` --
because shadowing one of those would break the prelude rather than the
program's own syntax, which is harder to spot.

It holds the generated program's **own** runtime beside them:
`pykFormat`, `pykQuote`, `pykConcat`, `pykList`, `pykOutput`, `pykWrite`
and `print`. Those are not words JavaScript has taken but ones this
compiler emits, and a binding of one is a redeclaration rather than a
shadow -- `const pykFormat = 3` beside the prelude's `function
pykFormat` is a `SyntaxError`, so the file does not run at all. The
`esm` packaging keeps its helpers in a module of their own and would
survive, which is exactly why the list lives in the core: the three
packagings must accept the same programs. `tests/renaming_runtime.pyk`
is the case.

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

### `str`, `range` and `len`

```
Unsupported by target 'nodejs': the builtin `str` is not supported yet
```

Refused at compile time rather than emitted. `String(x)` is not Pyking's
`str` — the two disagree about booleans, among other things — and a
Pyking list is not a JavaScript array here, so `range` and `len` have
nothing to compile to either. Until they do, a call to one is a compile
error with a source position; emitting it would produce a file that
loads and then dies with `str is not defined` at the moment it runs.

A program that defines its own `str` is naming its own function and
compiles as usual.

### Functions used before they are written

Every `def` in a block is bound before the block is translated
(`declare_functions`), mirroring the front end. JavaScript hoists a
function declaration by itself, so a forward reference — a recursive
call, two functions calling each other, a helper written below — *runs*
without help; what needs the pre-pass is the renaming above. A nested
`def` whose name is already taken compiles to `other2`, and a call
written above it has to say `other2` too, or it would resolve to
whatever the shadowed name holds. The `def` statement itself then reads
the name back rather than binding again, since binding twice would
rename twice.

### Numbers

JavaScript has one number type and Pyking has only `Int`, so the two
line up everywhere except division: JavaScript's `/` is float division,
and Pyking's truncates toward zero. `Math.trunc` around the quotient is
the whole of the difference, and it is right for either sign.

```pyking            // generated JavaScript
7 / 2                Math.trunc(7 / 2)
```

*Not optimal, and deliberately so:* an `Int` is 32-bit and wrapping in
Pyking, and nothing here enforces that — a JavaScript number is a
double, so a program that overflows prints a value this backend does not
wrap. Matching it would mean `| 0` on every arithmetic operator, or
`BigInt` throughout, either of which costs the thing this backend is
built for: output that reads like the source. See
[targets.md](targets.md) for the same difference measured across all the
backends.

## Modules

A Pyking module is a JavaScript module, except on the page, where there
is only one file to put them in. What differs between the three targets
is how a module is brought in and how its public names are handed out;
the compiled body is the same text in all of them, which is what
`JsHost` is for — the packager supplies the spelling of an import
exactly as it supplies the spelling of `print`.

### `nodejs`: CommonJS

A one-module program is the single self-contained script it has always
been. A program of several is several files, each `require`ing the ones
it imports:

```javascript
// helper.js
const priv = 3;

function inc(x) {
  return x + priv;
}

const greeting = 'hi';

module.exports = { inc, greeting };
```

```javascript
// program.js
const { print } = require('./pyk-runtime.js');

const helper = require('./helper.js');
const { inc: bump } = require('./helper.js');
print(helper.inc(1));
print(bump(10));
print(helper.greeting);
```

The host half — `print` and the formatting `src/runtime_interface.py`
lays down for it — moves into a module of its own rather than being
copied into every file. Its name is `pyk-runtime.js`, with a hyphen: a
Pyking module is imported by name, so its file's stem is an identifier,
and no Pyking module can ever be called that. A module that never
prints does not require it.

Requiring one module twice, as `program.js` does above, is one module:
node caches it, and the two lines are the two import statements the
source wrote.

### `esm`: one `init(runtime)` per module

The `esm` contract is that the program is pure and the host is handed
in, and that has to hold for every module of it, not just the program's
own. So a module the program imports exports an `init(runtime)` that
runs its top level and answers with what it exports:

```javascript
// helper.js
let pykExports;

export function init(runtime) {
  if (pykExports !== undefined) return pykExports;
  const priv = 3;

  function inc(x) {
    return x + priv;
  }

  const greeting = 'hi';
  pykExports = { inc, greeting };
  return pykExports;
}
```

```javascript
// program.js
import { init as pykInit_helper } from './helper.js';

export function run(runtime) {
  const helper = pykInit_helper(runtime);
  const { inc: bump } = pykInit_helper(runtime);
  runtime.print(helper.inc(1));
  ...
}
```

The memoization is what makes a module run **once** however many other
modules import it — which is also what lets each import statement call
`init` where it stands, rather than the program having to wire the whole
graph up front. `pykInit_<module>` is spoken for in
`target_js_core.RESERVED`'s manner: the packager tells
`translate_program` those names are taken, so a Pyking binding of one is
renamed rather than shadowing it.

### `html`: every module on one page

A page is one file, so a module becomes a block of it — built in the
order the modules must run, and reached afterwards by its own name:

```javascript
// The module 'helper', from helper.pyk.
const helper = (() => {
  const priv = 3;

  function inc(x) {
    return x + priv;
  }

  const greeting = 'hi';
  return { inc, greeting };
})();

const { inc: bump } = helper;
print(helper.inc(1));
```

Each module's body is inside a function scope of its own, so two modules
binding the same name do not collide; only the module names themselves
are on the page. An `import` of a module already built above it under
its own name writes nothing at all — the `const` is already there under
that name — which is why the page has no line for `import helper`.

The generated runtime helpers (`pykList`, `pykConcat`) are emitted once
for the whole page rather than once per module, since a page is one
scope and a second `function pykList` in it is a syntax error.

**Privacy leaves no trace** on any of the three: JavaScript's own
privacy is what a module exports, so `priv` above is unreachable from
outside `helper.js` on `nodejs` and `esm` — and on the page it is inside
the block. Nothing needs saying in the output.

## Where the output is not optimal

- **No 32-bit wrapping**, as above.
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
