# The JavaScript targets

**Targets in this family:** `node24`, `web24` and `iweb24`, aliased
`node`, `web` and `iweb`.

**Key points**

- One translation, `src/target_js_core.ml`; three packagings,
  `src/target_js_packaging.ml`. The targets accept exactly the same
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
  (`src/builtin.ml`), and the three targets bind it three
  ways: `console.log`, a page element, or a function the embedder passes
  in.
- Least optimal at: integer range — a JavaScript number is a double, so
  a program past the signed 32-bit range prints what double arithmetic
  gives — and renaming more shadowed bindings than JavaScript strictly
  requires.

## The three targets

| target | alias | files | what runs the program |
|---|---|---|---|
| `node24` | `node` | `foo.js`, `pyk-runtime.js`, `package.json` | `node foo.js` |
| `web24` | `web` | `foo.js`, `pyk-runtime.js`, `foo.html` | a browser, over HTTP |
| `iweb24` | `iweb` | `foo.html`, `pyking.js`, the `.pyk` sources | a browser, over HTTP |

**`node24` and `web24` emit the same JavaScript.** Both are ES modules,
both print with `console.log`, and both compile a Pyking module to a
`.js` module of its own. The only difference is the entry point: `web24`
adds an HTML file that loads the program, and nothing else.

```html
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>foo.pyk</title>
<script type="module" src="./foo.js"></script>
```

That is the whole page. Output goes to the browser console, not onto the
page: what a compiled program prints is what `node foo.js` prints, and a
reader comparing the two should not have to account for a difference.

**The `package.json` is `node`'s alone.** `{ "type": "module" }` is what
lets a program be plain `.js` there: node decides a file's module system
from its extension first and the nearest manifest second, so `.js`
without one means CommonJS and the `import` lines fail.

A browser never reads one — a `<script type="module">` says outright
what it is loading — so **`web24` writes no manifest**, and neither does
`iweb24`. That matters beyond tidiness: a `package.json` saying
`"type": "module"` governs every `.js` file *below* it, so one written
into a directory holding other JavaScript changes how node reads that
too. Writing one only where it is needed keeps that reach where it was
asked for.

The consequence for `web24` is worth knowing: its `.js` files are
perfectly good ES modules, but `node foo.js` on them needs a manifest
you supply, because the target did not assume you wanted one. Serving
the page, which is how the target is meant to be run, needs nothing.

An existing `package.json` is never overwritten — it belongs to whatever
project the output landed in.

**A `web24` program has to be served.** A browser refuses a module
fetched over `file://`, and the program is a module. `pyk compile -t web
--run` starts `python3 -m http.server` in the output directory for
exactly that reason, and prints the page's own address before it:

```
  open http://localhost:8000/prog.html
$ python3 -m http.server 8000 --directory .
```

The server only says which port it took, so the address of the page --
which is what a reader actually needs -- is printed by the compiler. Any
static server does; the port is python's own default, so a taken port is
an error rather than a silent move to another one.

### The interpreted target

`iweb24` compiles nothing at all. The page ships the program's Pyking
**source** and the Pyking compiler built to JavaScript, and interprets
it in the browser:

```html
<script type="module">
import './pyking.js';

const sources = {};
sources['foo.pyk'] = await (await fetch('./foo.pyk')).text();

globalThis.pykSources = sources;
globalThis.pykExternals = {};
globalThis.pykOnPrint = (line) => console.log(line.replace(/\n$/, ''));

const result = JSON.parse(pykRunProgram('foo.pyk'));
if (!result.ok) console.error(result.text);
</script>
```

The point is coverage. A backend supports a subset; the interpreter
supports everything `src/typesystem.ml` accepts, so `for`, `while`,
`match`, lists and comprehensions all work in a browser under `iweb24`
where `web24` refuses them. The price is that the program is interpreted
rather than compiled, and that `pyking.js` (about 5 MB) ships with it.

`pyking.js` is the same file the playground runs, built by `make` into
`build/pyking.js`. The compiler looks for it beside itself; `make` is
what puts it there, and says so plainly if it is not:

```
Usage error: target 'iweb24' ships the interpreter, and 'pyking.js' is
  not beside the compiler; run `make` to build it.
```

Compiling **in the directory the sources already sit in** copies each
`.pyk` onto itself, which is nothing to do — so it is skipped rather
than reported as overwriting the input. `pyk compile -t iweb foo.pyk`
in `foo.pyk`'s own directory is the ordinary case, and works.

**Modules and external modules work exactly as they do for `web24`.**
Every module's `.pyk` file ships, including an external module's
declaration — the module system runs in the page, reading those instead
of a directory. An external module's *implementation* is still
JavaScript, imported by the page and reached through a host hook, which
is why `iweb24` runs a program that `pyk foo.pyk` refuses: a terminal
cannot call JavaScript, and a browser can.

## What is supported

`print`; `def` with parameters, `return` and recursion, its body
written under the header or on the header's own line (`def f(x): e`);
`if` / `else if` / `else`;
`while`; `loop` with `break` and `continue`; `=`, `var`, `:=`; tuples,
including a binding that takes one apart; `if … then … else …`
expressions; integers, strings and booleans; `+ - * /`, unary minus,
comparisons, and calls. Tail position and `return if c:` are supported
(see below); nested `def` and lambdas work too — JavaScript has
closures.

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
because the program and the formatter live in different modules, where
two `class` declarations would not be the same class. A `match` becomes an if/else chain over the subject, held in a
name of its own so it is evaluated once; an arm whose pattern always
matches becomes the `else`, so a `match` that fits nothing does nothing.

```
$ pyk compile -t node24 tests/for_simple.pyk
'tests/for_simple.pyk' 2:0-3:22 Unsupported by target 'node24': `for`
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
`builtin.ml` says a tuple looks like.

Lists have no representation yet, so an array unambiguously means a
tuple here. That is what makes this formatting rule safe today, and is
the thing to revisit when lists arrive: the two will need telling apart.

### `loop`, `break` and `continue`

A `loop` is `while (true)` over a `let` holding the accumulator: the
initializer gives it its first value, every tail of the body assigns the
next one, and `break`/`continue` are JavaScript's own, operand and all
— they have none.

```pyking                          // generated JavaScript
res = loop x = 5:                  let x = 5;
    if x <= 10:                    while (true) {
        x + 1                        if (x <= 10) {
    else:                              x = x + 1;
        break                        } else {
                                       break;
                                     }
                                   }
                                   const res = x;
```

The loop's own value is the accumulator's `let`, so binding one is that
`const` after the loop, and a loop in tail position is `return x`. That
works because a `break` is JavaScript's own: it leaves the `let` holding
what this turn started with, which is exactly what the loop is worth,
and a `for`/`while` that runs out of turns leaves the same thing there.
A tuple accumulator is an array, assigned as a whole
(`[x, y] = [x + 1, y]`), so the next turn's values are computed before
any of them is stored. A `loop:` carrying nothing has no `let` at all
and is worth `[]`, JavaScript's spelling of unit.

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
defines a function (`defines_function`), the `let` becomes a *carrier*
holding what the next turn starts with, and the accumulator itself
becomes a `const` inside the body — one binding per turn, which is what
each function closes over:

```pyking                          // generated JavaScript
fns =                              let tmp1 = [0, pykList([])];
loop i, made = 0, []:              while (true) {
    def show(): i * 10               const [i, made] = tmp1;
    if i > 3:                        function show() { return i * 10; }
        break                        if (i > 3) { break; }
    else:                            tmp1 = [i + 1, pykConcat(made, pykList([show]))];
        (i + 1,                    }
         made ++ [show])
```

A loop with no function in its body keeps the plain `let`, so ordinary
output stays ordinary. A `for … of` header needs none of this:
JavaScript already gives each iteration its own binding for the element.

A **lambda** in the body is the same case and gets the same answer:
`defines_function` answers true for one, so `loop made = [] for i in
[0, 1, 2]: made ++ [x => x + i]` gets the carrier and the per-turn
`const` exactly as a `def` does. It matches `Walk.NExpr (ELambda _)` as
well as `Walk.NStmt (SFunctionDef _)`, which is the whole of the
difference — a lambda is an expression, so a predicate that looked only
at statements would have walked straight past it and left every turn's
lambda sharing the last turn's value.

#### Lambdas

A lambda is an arrow function, and its parameters are its own scope —
the one place this backend needs no renaming at all:

```pyking                          // generated JavaScript
double = x => x * 2                const double = (x) => x * 2;
adder = x => y => x + y            const adder = (x) => (y) => x + y;
```

The body is one expression in both languages, so the arrow's
expression form is what is emitted; nothing here needs a block body or
a `return`.

An arrow function is an `AssignmentExpression`, which binds looser than
everything else this printer emits, so one used as a **callee** or as
an operand is parenthesized: `(x => x + 1)(5)` has to print as
`((x) => x + 1)(5)`, since `(x) => x + 1(5)` is an arrow whose body is
a call. `tests/lambda_basic.pyk` pins it.

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
would print as though it were nested. It lives in `pyk-runtime.js`,
which every module of the program imports, rather than being repeated in
each of them.

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

The list (`RESERVED` in `src/target_js_core.ml`) also holds a few
globals a generated file leans on -- `undefined`, `console`, `String` --
because shadowing one of those would break the prelude rather than the
program's own syntax, which is harder to spot.

A renamed name still has to be *exported* under the name a program
imports it by, and an export clause is the one place JavaScript allows a
reserved word: `export { arguments2 as arguments }` is legal where
`const arguments` is not. So `translate_program` answers with the
top-level names it had to rename, and the packaging writes the `as`
form for each of them. Without it a module exporting one would emit
`export { arguments };` — a name nothing in the file declares, which is
a `SyntaxError` rather than a wrong answer.

It holds the generated program's **own** runtime beside them:
`pykFormat`, `pykQuote`, `pykConcat`, `pykList`, `pykOutput`, `pykWrite`
and `print`. Those are not words JavaScript has taken but ones this
compiler emits, and a binding of one is a redeclaration rather than a
shadow -- `const pykFormat = 3` beside the prelude's `function
pykFormat` is a `SyntaxError`, so the file does not run at all. The
helpers now live in a module of their own and a redeclaration there
would be caught the same way, which is exactly why the list lives in the
core: every packaging must accept the same programs.
`tests/renaming_runtime.pyk` is the case.

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
Unsupported by target 'node24': the builtin `str` is not supported yet
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

*Not optimal, and deliberately so:* a JavaScript number is a double, so
a program that overflows the signed 32-bit range prints whatever the
double arithmetic gives. Pyking leaves that undefined, so there is
nothing to enforce. Pinning it to one answer would mean `| 0` on every
arithmetic operator, or
`BigInt` throughout, either of which costs the thing this backend is
built for: output that reads like the source. See
[targets.md](targets.md) for the same difference measured across all the
backends.

## Floats

This is the one place the JavaScript backends need something no other
target does, and the reason `translate_program` takes the checker's
`tmap` at all.

**A JavaScript number is one type.** `1.0 === 1` and `String(1.0)` is
`"1"`, so nothing about a value at run time says whether Pyking called
it an `Int` or a `Float`. Every other backend can tell: Python has a
real `float`, C and Java carry a `double`, OCaml reads the type off
`tmap`, and the interpreter holds a `VFloat`. Here the value cannot
answer, so the *type* does.

Arithmetic needs nothing — a JavaScript `/` is already IEEE division,
and the `Math.trunc` wrapper the Int case needs is simply left off.
Printing is where the type is consulted:

- an argument the checker typed `Float` becomes `pykFloatStr(x)`;
- one whose type holds a Float somewhere inside becomes
  `pykShaped(x, "<descriptor>")`;
- anything else is emitted exactly as it was before Float existed, so an
  ordinary program's output is unchanged to the byte.

Both answer a String, and a String at the top level prints bare, so
`print` and `pykFormat` need no third case.

**The descriptor** says which positions of a value are Floats, which is
all `pykFormat` is missing: `f` a Float, `.` anything it already prints
correctly, `[s]` a list of `s`, and `(s,s)` a tuple. It nests:

```javascript
print(pykShaped(xs, '[f]'));           // xs : [Float]
print(pykShaped(pair, '(f,.)'));       // pair : (Float, Int)
print(pykShaped(points, '[(f,f)]'));   // points : [(Float, Float)]
```

A descriptor rather than a generated walker per shape, which is what
`target_python.ml` does for Bools: there the type settles a *spelling*
and one walker serves every shape, here it settles which of two
representations a number is, and a string argument says that in one
token.

`pykFloatStr` and `pykShaped` live in `pyk-runtime.js` beside
`pykFormat` — `pykShaped` calls it for every non-Float position — and a
module imports whichever of them it uses, the same way it imports
`print`.

`float(n)` compiles to the operand and nothing else: a JavaScript number
is already a double, so widening has nothing to do, and it is the print
site that makes the result read as `3.0`. `int(x)` is `Math.trunc(x)`.

## Modules

A Pyking module is a JavaScript module — one `.js` file each, on every
JavaScript target. ES modules give Pyking's own rule for free: a
module's top level runs once, the first time something imports it, and
imports resolve before the importing file runs. That is exactly "every
module runs after everything it imports", so there is no `init` to call
and no order for the program to arrange.

`helper.pyk`:

```pyking
public def greet(name:String) -> String:
    "hello, " ++ name

def priv(): 1
```

becomes `helper.js`:

```js
function greet(name) {
  return "hello, " + name;
}

function priv() {
  return 1;
}

export { greet };
```

and the program that imports it:

```js
import { print } from './pyk-runtime.js';

import * as helper from './helper.js';
print(helper.greet('world'));
```

A `from` line takes its names directly, and `as` renames:

```pyking
from helper import greet as hello
```
```js
import { greet as hello } from './helper.js';
```

`pyk-runtime.js` is the one file the program does not get from its own
source: `print` and the value formatting `builtin.ml` lays
down, shared by every module rather than repeated in each.

**Privacy leaves no trace.** JavaScript's own privacy is what a module
exports, so `priv` above is simply unreachable from outside `helper.js`.
Nothing needs saying in the output.

## Where the output is not optimal

- **Integers are doubles**, as above — exact to 2^53, and past the
  signed 32-bit range Pyking says nothing about what the answer is.
- **Over-eager renaming** around the temporal dead zone, as above.
- **`pykFormat` on every printed value**, including integers that
  `String()` would have handled — one code path is easier to keep
  consistent across the hosts than a special case for each.
- **`pyking.js` is about 5 MB** on the `iweb` target — the whole
  compiler, shipped so the page can interpret rather than run compiled
  code. That is the trade the target makes, not an accident of it.
- **No optimisation.** The backend is a printer: no constant folding, no
  dead-code elimination, no tail calls.

## External modules

A module implemented in JavaScript (`sys.js`, declared in
`sys.external.pyk` -- see [modules.md](modules.md)) is an **ES module**:
it uses `export`, and the compiler emits `import * as sys from
'./sys.js'` to reach it.

Every JavaScript target emits ES modules, so nothing special is needed
to reach one: the implementation is imported like any other module and
copied beside the program's output as `sys.js`.

**A browser may need different code from node**, and `sys.web.js` is
where that goes. The `web` and `iweb` targets look for it first and fall
back to `sys.js`, so a module needing no browser-specific code writes
one file and a module needing it writes two. Whichever is found is
copied out as `sys.js`, which is what the generated import names.

Under `iweb24` the implementation is reached from *interpreted* code:
the page imports it, puts it in `pykExternals`, and the interpreter
calls through a host hook, with values crossing as JSON. That is why
`iweb24` runs a program `pyk foo.pyk` refuses -- see
[modules.md](modules.md), "Running one".

One thing an implementation has to know: **a Pyking list and a Pyking
tuple are both JavaScript arrays**, and the formatter walks values
rather than reading types, so a list carries `pykList === true` and a
tuple does not. Returning a plain array where the declaration says
`[Int]` prints it as a tuple. `tests/external_shapes_mod1.js` is the
worked example.
