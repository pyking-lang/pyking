# The JavaScript targets

**Targets in this family:** `node22`, `node24`, `web2020`, `web2024`,
`iweb2020` and `iweb2024`, aliased `node` (`node22`), `web` (`web2020`)
and `iweb` (`iweb2020`).

**Key points**

- One translation, `src/target_js_core.ml`; three packagings,
  `src/target_js_packaging.ml`. The targets accept exactly the same
  programs and differ only in **where `print` goes** and what files come
  out.
- JavaScript fits Pyking better than Python does: `const` is an immutable
  binding, `let` a mutable one, and `{ }` blocks are scopes — so `=`,
  `var`, `:=` and block scoping map straight across, with far less
  rewriting than the Python target needs.
- They compile everything the type checker accepts.
- `print` and `debug` are the two things crossing the runtime boundary
  (`src/builtin.ml`). `print` is `console.log` under node, and in a
  browser writes through the `io` library's own implementation, which
  a page embedding the program may replace. `debug` is `console.error`
  everywhere, and `--release` removes it.
- Least optimal at: integer range — a JavaScript number is a double, so
  a program past the signed 32-bit range prints what double arithmetic
  gives — and renaming more shadowed bindings than JavaScript strictly
  requires.

## The three targets

| targets | alias | files | what runs the program |
|---|---|---|---|
| `node22`, `node24` | `node` | `foo.js`, `pyk-runtime.js`, `package.json` | `node foo.js` |
| `web2020`, `web2024` | `web` | `foo.js`, `pyk-runtime.js`, `foo.html` | a browser, over HTTP |
| `iweb2020`, `iweb2024` | `iweb` | `foo.html`, `pyking.js`, the `.pyk` sources | a browser, over HTTP |

## Two editions: ES2020 and ES2024

A JavaScript target writes one of two ECMAScript editions
(`Targets.es_edition`): `node22`, `web2020` and `iweb2020` ES2020,
`node24`, `web2024` and `iweb2024` ES2024. A web target's version is its
edition, and a node target's is the node release, whose edition is
fixed here -- node 22 runs all of ES2024 and node 24 all of ES2025, so
the choice is conservative rather than forced.

A program's own modules are the same text in both: they use nothing
past ES2020. What differs is a page's loader. It waits for the program
(`web`) or for its sources (`iweb`) at the top level of a module script,
which is ES2022; an ES2020 page wraps those statements in an async
function called at once (`awaiting`).

*Not optimal:* an `iweb2020` page's own script is ES2020, but the
interpreter it ships, `pyking.js`, is js_of_ocaml's output, which uses
`||=` (ES2021) and `Object.hasOwn` (ES2022) -- so an `iweb` page needs an
ES2022 browser whichever edition it was compiled for.

**`node` and `web` emit the same JavaScript** for a program's own
modules. Both are ES modules, and both compile a Pyking module to a
`.js` module of its own. They differ in the entry point -- `web` adds
an HTML file that loads the program -- and in the shared
`pyk-runtime.js`, which is where `print` goes (see "Standard output in a
browser" below).

```html
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>foo.pyk</title>
<script type="module">
import { flush } from './io_external.js';
try {
  await import('./foo.js');
} catch (error) {
  if (error === null || error.pykExit === undefined) throw error;
  if (error.pykExit !== 0) console.log(`exited with status ${error.pykExit}`);
} finally {
  flush();
}
</script>
```

That is the whole page. Output goes to the browser console, not onto the
page: what a compiled program prints is what `node foo.js` prints, and a
reader comparing the two should not have to account for a difference.
The loader writes out a line `io.write` left unfinished once the program
stops, and reports a `sys.exit` whose status is not 0.

### Standard output in a browser

In a browser `print` is not `console.log` directly: it writes through
`write_line` in the `io` library's browser implementation,
`lib/io/io_external_browser.js`, copied beside the program as
`io_external.js` whether or not the program imports `io`. That one file
is where a page's standard output is, so a page embedding the program --
the playground, a notebook -- replaces it, and `print` and `io.write`
share one stream in order. The implementation writes to `console.log` a
line at a time, since `console.log` always ends a line: `io.write` holds
text back until a newline completes it, and `flush` writes the rest.

`debug` writes with `console.error` on all three targets, which on node
is standard error. A program compiled with `--release` has no `debug`
left in it.

**The `package.json` is `node`'s alone.** `{ "type": "module" }` is what
lets a program be plain `.js` there: node decides a file's module system
from its extension first and the nearest manifest second, so `.js`
without one means CommonJS and the `import` lines fail.

A browser never reads one — a `<script type="module">` says outright
what it is loading — so **`web` writes no manifest**, and neither does
`iweb`. That matters beyond tidiness: a `package.json` saying
`"type": "module"` governs every `.js` file *below* it, so one written
into a directory holding other JavaScript changes how node reads that
too. Writing one only where it is needed keeps that reach where it was
asked for.

The consequence for `web` is worth knowing: its `.js` files are
perfectly good ES modules, but `node foo.js` on them needs a manifest
you supply, because the target did not assume you wanted one. Serving
the page, which is how the target is meant to be run, needs nothing.

An existing `package.json` is never overwritten — it belongs to whatever
project the output landed in.

**A `web` program has to be served.** A browser refuses a module
fetched over `file://`, and the program is a module. `pyk compile -t web
--run` starts `pyk serve` in the output directory for exactly that
reason, and prints the page's own address before it:

```
  open http://localhost:8000/prog.html
$ pyk serve --port 8000 .
```

The server only says which port it took, so the address of the page --
which is what a reader actually needs -- is printed by the compiler. Any
static server does; the port is python's own default, so a taken port is
an error rather than a silent move to another one.

### The interpreted target

`iweb` compiles nothing at all. The page ships the program's Pyking
**source** and the Pyking compiler built to JavaScript, and interprets
it in the browser:

```html
<script type="module">
import './pyking.js';
import * as pykExt_io from './io_external.js';

const sources = {};
sources['foo.pyk'] = await (await fetch('./foo.pyk')).text();

globalThis.pykSources = sources;
globalThis.pykExternals = {io: pykExt_io};
// `print` writes through the `io` library, as a compiled page's does,
// and `debug` to the console.
globalThis.pykOnPrint = (line) => pykExt_io.write(line);
globalThis.pykOnDebug = (line) => console.error(line.replace(/\n$/, ''));

const result = JSON.parse(pykRunProgram('foo.pyk'));
pykExt_io.flush();
if (!result.ok) console.error(result.text);
else if (result.exit) console.log(`exited with status ${result.exit}`);
</script>
```

`--release` is honoured by the page rather than by a compilation: it
asks for `pykRunProgram('foo.pyk\nrelease')`, and the page's front end
removes every call to `debug` before it runs the program, as
`pyk compile --release` does for a compiled target.

The point is coverage. A backend supports a subset; the interpreter
supports everything `src/typesystem.ml` accepts, so `for`, `while`,
`match`, lists and comprehensions all work in a browser under `iweb`
where `web` refuses them. The price is that the program is interpreted
rather than compiled, and that `pyking.js` (about 5 MB) ships with it.

`pyking.js` is the same file the playground runs, built by `make` into
`share/pyking.js`. The compiler looks for it beside itself; `make` is
what puts it there, and says so plainly if it is not:

```
Usage error: target 'iweb' ships the interpreter, and 'pyking.js' is
  not beside the compiler; run `make` to build it.
```

Compiling **in the directory the sources already sit in** copies each
`.pyk` onto itself, which is nothing to do — so it is skipped rather
than reported as overwriting the input. `pyk compile -t iweb foo.pyk`
in `foo.pyk`'s own directory is the ordinary case, and works.

**Modules and external modules work exactly as they do for `web`.**
Every module's `.pyk` file ships, including an external module's
declaration — the module system runs in the page, reading those instead
of a directory. An external module's *implementation* is its browser
JavaScript, imported by the page and reached through a host hook, where
`pyk foo.pyk` reaches the OCaml one.

## What is supported

`print`; `def` with parameters, `return` and recursion, its body
written under the header or on the header's own line (`def f(x): e`);
`if` / `else if` / `else`;
`while`; `loop` with `break` and `continue`; `=`, `var`, `:=`; tuples,
including a binding that takes one apart; `if … then … else …`
expressions; integers, strings and booleans; `+ - * /`, unary minus,
comparisons, and calls. Tail position and `return if c:` are supported
(see below); nested `def` and lambdas work too — JavaScript has
closures. Arrays (`array(...)`, `a[i]`, `a[i] := v`, `len`, `same`) are
too; see "Arrays" below. So are mutable structs (`var struct`,
`p.x := v`, `same`); see "Mutable structs", and DynArrays (`dynarray(...)`,
`push`, `pop`, `insert`, `remove`, `clear`); see "DynArrays", and MutMaps;
see "MutMaps"; slices (`s[i:j]`), views (`view`) and `copy_into`; see
"Slices and views"; and pointers (`&`, `*`); see "Pointers".
`==` and `!=` compare lists, tuples, structs and
datatypes part by part; see "Equality".

## Lists, `match` and value forms

A `+` the checker typed as two Strings or two lists is `pykConcat`,
which looks at its left operand: a Pyking list is an array and
JavaScript's `+` would stringify one, so which of the two joins it is is
decided at run time -- the same answer `pykFormat` gives for printing.
Every other `+` is JavaScript's own.

Lists, list comprehensions and `match` *are* supported. A Pyking tuple
is a JavaScript array, so a **list is an array carrying a marker** --
`pykList` in the compiled program sets it, and `pykFormat` reads it to
tell `[1, 2]` from `(1, 2)`. It is a property rather than a class
because the program and the formatter live in different modules, where
two `class` declarations would not be the same class. A `match` becomes an if/else chain over the subject, held in a
name of its own so it is evaluated once; an arm whose pattern always
matches becomes the `else`, so a `match` that fits nothing does nothing.

A **value-form binding**, `x = if c:` or `x = match e:`, is a `let`
each of the statement's tails assigns, read once by the binding after
it:

```js
let __value = undefined;
const __subject = foo;
if (__subject === 8) {
  __value = "eight";
} else {
  const n = __subject;
  __value = pykFormat(n);
}
const x = __value;
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

### Datatypes

A constructor is a function of the module that declares it, building a
tagged object with the runtime's `pykData`:

```pyking                          # generated JavaScript
datatype Shape:                    function Circle(v0) {
    Circle(radius: Float)            return pykData('Circle', [v0], ['radius']);
    Dot                            }
```

The object holds the constructor's name (`pykTag`), its fields in
order (`pykValues`), and each named field again as a property of its
own name, so `x.radius` is JavaScript's own property access. A pattern
tests `pykTag` and takes the fields by position. `pykFormat` prints the
value as Pyking does. A JavaScript number cannot say whether it is a
Float, so a construction whose arguments hold one is wrapped in
`pykWithShape`, which records the descriptor `pykShaped` reads (see
"Floats"). A value built where a field's type is a type variable -- `Some(x)`
inside a generic function -- has no such descriptor, so a constructor
whose fields can hold a Float or a Char through a type parameter passes
`pykData` a template of them too (`'($0)'` for `Some(a)`, `'($0,d($0))'`
for `Cons(a, L(a))`), and a value printed with the type `Option(Char)`
goes through `pykShaped` with `d(c)`, which reads the fields through the
template with `$0` as `c`: `Some('a')`, not `Some(97)`. The datatype's own name is bound to its name as a string,
which is what an import of it imports. The functions hoist, so a
constructor may be used above its declaration, as Pyking allows. A
`var struct` is built by `pykStruct` instead, and its value is shared
and written in place (see "Mutable structs").

A `match` with a guard is a labelled block the arms leave with
`break`, rather than an `if`/`else` chain: a guard is asked after its
pattern has bound what it binds, and a false one goes on to the next
case, which a chain cannot say. A `match` with no guard is the chain it
always was.

### `loop`, `break` and `continue`

A `loop` is `while (true)` over a `let` holding the accumulator: the
initializer gives it its first value, every tail of the body assigns the
next one, and `break`/`continue` are JavaScript's own. A `break x` or
`continue x` assigns `x` to that `let` first (`x = …; break;`), which is
all it takes: the loop is worth what the `let` holds, and the next turn
starts from it.

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
         made + [show])
```

A loop with no function in its body keeps the plain `let`, so ordinary
output stays ordinary. A `while` clause on a loop with a carrier is
asked inside the body, after the per-turn `const` it reads
(`while (true) { const [i, made] = tmp1; if (!(i < n)) { break; } … }`),
since the accumulator's own name exists only there. A `break x`/`continue
x` assigns the carrier. A `for … of` header needs none of this:
JavaScript already gives each iteration its own binding for the element.

A **lambda** in the body is the same case and gets the same answer:
`defines_function` answers true for one, so `loop made = [] for i in
[0, 1, 2]: made + [lam x. x + i]` gets the carrier and the per-turn
`const` exactly as a `def` does. It matches `Walk.NExpr (ELambda _)` as
well as `Walk.NStmt (SFunctionDef _)`, which is the whole of the
difference — a lambda is an expression, so a predicate that looked only
at statements would have walked straight past it and left every turn's
lambda sharing the last turn's value.

#### Lambdas

A lambda is an arrow function, and its parameters are its own scope —
the one place this backend needs no renaming at all:

```pyking                          // generated JavaScript
double = lam x. x * 2              const double = (x) => x * 2;
adder = lam x. lam y. x + y        const adder = (x) => (y) => x + y;
```

The body is one expression in both languages, so the arrow's
expression form is what is emitted; nothing here needs a block body or
a `return`.

An arrow function is an `AssignmentExpression`, which binds looser than
everything else this printer emits, so one used as a **callee** or as
an operand is parenthesized: `(lam x. x + 1)(5)` has to print as
`((x) => x + 1)(5)`, since `(x) => x + 1(5)` is an arrow whose body is
a call. `tests/lambda_basic.pyk` pins it.

### Control flow, functions, expressions

```pyking
use mutation

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

function pykQuote(text) { /* " quoted the way Pyking quotes a String */ }

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
would print as though it were nested. The real `pykFormat` also takes
a third argument, the values printing is inside of, which is how a
value that holds itself prints `...` (see "Mutable structs"). It lives in `pyk-runtime.js`,
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

### The conversions

`string(x)` is the runtime's own `pykFormat` -- or `pykFloatStr` and
`pykShaped` where a Float is in it -- which is what `print` writes with.
`String(x)` is not Pyking's `string`: the two disagree about tuples and
about how a Float is written.

`int`, `float` and `bool` go by the argument's type. A number is one
JavaScript type, so `float` of an Int is the value itself, and a Bool is
`b ? 1 : 0`. A String goes through `pykParseInt` and `pykParseFloat`,
and `int` of a Float through `pykTrunc`, in `pyk-runtime.js`, since
`Number` and `parseInt` read strings Pyking does not (`" 3"`, `"0x1F"`)
and `Math.trunc` answers a NaN where Pyking answers 0. `bool` is a
comparison: `x === "true"`, `x === 1`, or `c !== 0` for a Char.

`char(x)` is the operand for a Char, `pykCharOfInt(n)` for an Int (`n`
where it is a Unicode scalar value, else 0) and `pykCharOfString(s)` for
a String (its first code point, 0 for `""`). `int(c)` and `float(c)` are
the code point itself, and `string(c)` is `pykShaped(c, 'c')`, which is
`String.fromCodePoint(c)`. See "Chars" below.

### `range` and `len`

Two helpers the module writes for itself where it uses them: `pykRange`
builds the list of Ints `range` answers, and refuses a step of zero as
the interpreter does; `pykLen` answers a list's length or a String's in
code points, which is how Pyking counts it -- a `for..of` over the
string, so a surrogate pair counts once.

A program that defines its own `len` is naming its own function and
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
correctly, `[s]` a list of `s`, `{s}` an array of `s`, `<s>` a DynArray of
`s`, `v{s}` a view of `s`, `p(s)` a pointer to `s`, `@(k,v)` a MutMap
whose entries are `(k, v)`, and `(s,s)` a tuple. It nests:

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

`pykFloatStr` takes its digits from JavaScript's own `String(x)`, which
is the shortest that reads back as the same double, as Python's `repr`
and every other backend's are, and lays them out as Pyking writes a
Float: an exponent from `1e16` up and below `0.0001`, and `.0` on a
whole number.

`pykFloatStr` and `pykShaped` live in `pyk-runtime.js` beside
`pykFormat` — `pykShaped` calls it for every non-Float position — and a
module imports whichever of them it uses, the same way it imports
`print`.

`float(n)` compiles to the operand and nothing else: a JavaScript number
is already a double, so widening has nothing to do, and it is the print
site that makes the result read as `3.0`. `int(x)` is `Math.trunc(x)`.

## Chars

A `Char` is a JavaScript **number**: its code point. That is what the
browser interpreter (`src/web/pyking_web.ml`) hands a JavaScript external
too, so a Char means one thing whichever way the program runs. A literal
`'a'` is `97`, a pattern `case 'a':` is `subject === 97`, and `==`, `<`
and the rest are JavaScript's own on the numbers.

A String is counted in code points, not in the UTF-16 units JavaScript
indexes by:

```pyking            // generated JavaScript
s[i]                 pykCharAt(s, i)       // throws RangeError out of range
for c in s:          for (const c of pykChars(s)) {
[f(c) for c in s]    pykList(pykChars(s).flatMap(...))
len(s)               pykLen(s)
```

`pykChars` lists a String's code points (`Array.from` walks a surrogate
pair as one); the compiler uses it wherever the checker typed the
sequence `String`. All four are helpers the module writes for itself
where it uses them, as `pykRange` is.

**Printing** is the Float problem again -- a code point is an Int to
look at -- and is solved the same way: the descriptor has a `c` for a
Char, and every print, `string(x)` and datatype construction whose type
holds a Char goes through `pykShaped`. A Char at the top level prints as
itself (`String.fromCodePoint`); inside a list, tuple or datatype as
`'a'` (`pykQuoteChar`), where a String is `"abc"` (`pykQuote`), each
with builtin.ml's escapes.

```javascript
print(pykShaped(c, 'c'));              // c : Char      -> a
print(pykShaped(cs, '[c]'));           // cs : [Char]   -> ['a', 'b']
print(pykShaped(pair, '(c,.)'));       // (Char, String) -> ('a', "b")
```

*Not complete, as for Floats:* a datatype value records its shape when
it is built, from the arguments' types there; one built inside a
polymorphic function, where the field's type is a type variable, prints
its Char as the code point.

## Arrays

**An array is a JavaScript array carrying a marker**, as a list is:
`pykArray` sets `pykArray = true` on it, and `pykFormat` reads the
marker to print `array([1, 2])` where a list prints `[1, 2]` and a
tuple `(1, 2)`. A property rather than a class, for the reason a list's
marker is one: the program and the formatter live in different modules.
Everything else an array does is the JavaScript array's own -- `length`
is O(1), `for..of` walks it, `flatMap` maps it -- and an array is a
reference, so assigning, passing, returning and storing one never copy
it. `same(a, b)` is `a === b`.

```pyking            // generated JavaScript
array(xs)            pykArrayOfList(xs)        // a copy, marked
array(n, v)          pykArrayFill(n, v)        // n times the one v
array(n, f)          pykArrayInit(n, f)        // f(0), f(1), ... in order
array(n, s, f)       pykArrayUnfold(n, s, f)   // [element, next] = f(state)
a[i]                 pykAt(a, i)
len(a)               a.length
same(a, b)           a === b
for x in a:          for (const x of a) {
[f(x) for x in a]    pykList(a.flatMap(...))
```

The four forms are the elaborated `list__array`, `fill__array`,
`init__array` and `unfold__array`; their arguments are worked out left
to right like any call's, and each helper checks the size before it
calls `f` or allocates anything: a negative one is the runtime error
`an array's size is never negative, and this one is -1`, and one the
JavaScript engine refuses to allocate (a `RangeError`) is `an array of N
elements is more than this machine can hold`. `f` is never called for
`n = 0`, and an unfold's last state is dropped.

**Reads are checked.** `pykAt` refuses an index below 0 or at
`length` and above -- JavaScript would answer `undefined`, and a
negative index never counts from the end -- with `the index 5 is
outside an array of 2 elements` (`element` when there is one). `for`
uses the array's own iterator, which reads `a[i]` as each turn is
reached, so a write to a later element during the loop is seen, as the
interpreter's walk by index does.

**An element write** is `a[i] := v`, statement `SSetIndex`, and runs in
the order PYKING.md lays down: the array, then the index, then the
index checked, then the value, then the write -- into the array first
worked out, even where working out the value rebinds the name it came
from. JavaScript's own `a[i] = v` already evaluates `a` and `i` before
`v` and writes into the object `a` held then; what it cannot do is
check in between, so the check is a statement of its own
(`pykCheckIndex`) and the write is a `JsSetIndex`:

```javascript
pykCheckIndex(held, 0);              // held[0] := replace_held()
held[0] = replace_held();
const __array = pykAt(grid, 1);      // grid[1][2] := 7
pykCheckIndex(__array, 2);
__array[2] = 7;
```

An owner or index that is a plain name or number is used as it is;
anything else is held in a `const` first so it is worked out once. A
compound `a[i] += e` arrives from desugar_args.ml with both already in
temporaries, `element__array` and `element__index`, and its value reads
the element through `pykAt`.

**Printing** is `pykFormat`'s marker case, and an array whose elements
are Floats or Chars goes through `pykShaped` with `{s}` in the
descriptor, as a list does with `[s]`. Strings and Chars inside are
quoted, an empty array is `array([])`, and nested ones nest.

**A runtime error** goes through `pykFail`. Under node it writes
`error: <message>` to stderr and throws an Error carrying `pykExit = 1`,
with an `uncaughtException` handler that sets the status to 1 -- so
the program stops with status 1 after what it printed, without node's
stack trace, and without `process.exit`, which may drop output still
going to a pipe (the `sys` module's handler reads the same `pykExit`).
In a browser it throws a plain Error with the message, which the page
reports the way it reports any other failure: the console, or the
playground's error line.

All of these helpers are the module's own, written where it uses them
with whichever of the others they call (`array_helpers` in
target_js_core.ml), as `pykRange` is.

## Mutable structs

**A `var struct`'s value is one JavaScript object**, which every name,
parameter, element and field holding it shares -- an object is a
reference, so assigning, passing, returning and storing one never copy
it, exactly as PYKING.md says a mutable struct behaves. Its one
constructor builds it with the module's own `pykStruct` rather than
`pykData`:

```pyking                              # generated JavaScript
var struct Point(x: Int, y: Int = 0)   function Point(v0, v1) {
                                         return pykStruct('Point', [v0, v1], ['x', 'y']);
                                       }
p.x := 10                              p.x = 10;
p.y += 1                               const field__owner = p;
                                       field__owner.y = field__owner.y + 1;
same(p, q)                             p === q
```

The fields are the object's own properties, written in place. What a
datatype keeps as `pykValues` -- the fields by position, which a
pattern and `pykFormat` read -- is a getter here, worked out from the
properties each time it is read, so it can never disagree with a write.
`pykTag` and `pykShape` are as a datatype's, so a pattern, a field read
and printing treat the two alike; a `..` update is an ordinary
constructor call, so it builds a new object.

**A field write** is `SSetField`, a `JsSetField`, and JavaScript's own
`owner.field = value` already runs in PYKING.md's order: the owner,
then the value, then the write into the object the owner was. A
compound `p.x += e` arrives from desugar_args.ml with its owner held in
`field__owner`, so the owner is worked out once. `same(a, b)` is
`a === b`, as for arrays.

**Printing stops at a cycle.** A `var struct` can hold itself, through
a datatype or an array, and so can an array; printing one must not
recurse forever. `pykFormat` takes a third argument, the *path*: the
arrays, tuples, lists and datatype values it is inside of. A value
already on the path prints as `...`; one that is merely shared -- the
same struct twice in an array -- is off the path again by the time it
is met the second time, and prints in full:

```text
Node(1, Next(Node(2, Next(...))))            a.next := Next(b), b.next is Next(a)
array([Point(3, 3), Point(3, 3)])            the one Point twice
```

That is interpreter.ml's `display_value` rule. Only an array or a
`var struct` can repeat, but the guard is on every value holding others
-- it costs the same, and an immutable value can never be met inside
itself. `pykShaped` passes the path along without checking it: a value
can only reach itself through a datatype's value, which the descriptor
leaves to `pykFormat` (`.`). `string(v)` is the same `pykFormat`, so it
stops at a cycle too.

**`print` formats after it has every argument.** Its arguments are an
ordinary call's, all worked out left to right before `print` formats
any of them, so `print(a, f())` shows a write `f` made into `a`. The
one exception would be an argument with a descriptor, which
`pykShaped` formats where it is written: a Float array that is not the
last argument is therefore handed over as `pykLater(xs, '{f}')`, which
holds the value and its descriptor until `print`'s own `pykFormat`
applies it. A list or tuple of Floats cannot change and keeps its
`pykShaped`, and a `var struct` carries its descriptor inside it.

## DynArrays

**A DynArray is a JavaScript array carrying a marker of its own**,
`pykDynArray = true`, as an array carries `pykArray`: a JavaScript array
already grows and shrinks, so a DynArray needs nothing an array does not
have, and `pykFormat` reads the marker to print `dynarray([1, 2])`. It is a
reference, shared by every name, parameter and element holding it, and
`same(v, w)` is `v === w`. Indexing, `len` and element writes are an
array's, with the index checked against the length the DynArray has now;
the error says `a DynArray` where an array's says `an array` (`pykIndexError`
reads the marker).

```pyking            // generated JavaScript
dynarray()                pykDynArrayEmpty()
dynarray(xs)              pykDynArrayOfList(xs)          // a copy, marked
push(v, x)           pykPush(v, x)             // answers (), not the length
pop(v)               pykPop(v)                 // 'pop from an empty DynArray'
insert(v, i, x)      pykInsert(v, i, x)        // 0 <= i <= len(v)
remove(v, i)         pykRemove(v, i)           // checked as a read is
clear(v)             pykClear(v)               // length = 0
v[i]                 pykAt(v, i)
v[i] := x            pykCheckIndex(v, i);
                     pykSetAt(v, i, x);
len(v)               v.length
```

Each helper is the module's own and emitted where it is used, with
those it calls, as the array helpers are; a program that defines its
own `push` (or any of the five) calls its own. `splice`, `pop` and
`length = 0` drop the elements they remove, so a removed slot keeps
nothing alive.

**An element write is checked twice.** Working out `x` in `v[i] := x`
may shrink the DynArray, so after the check `pykCheckIndex` makes before the
value, `pykSetAt` checks the index again as it writes -- an array
cannot change length, so its write stays the plain `JsSetIndex`.

**`for x in v`** is JavaScript's own `for..of`, whose array iterator
reads `length` afresh at every turn and each element as it is reached:
exactly Pyking's rule, so what is pushed during the walk is walked and
what is removed ends it sooner. A comprehension's `flatMap` maps the
elements the DynArray holds when it starts.

**Printing** is the marker case, with `<s>` in a descriptor for a DynArray
of Floats or Chars, and a DynArray is on `pykFormat`'s path like any value
holding others, so one reached again inside itself prints `...` (see
"Mutable structs"). A DynArray with a descriptor that is not `print`'s last
argument is handed over as `pykLater`, as an array is.

## Slices and views

**A slice copies.** `s[i:j]` is `pykSlice(s, i, j)`, and `s[i:]` is
`pykSlice(s, i)` -- a left-out end is the length, a left-out start `0`.
The call works out the sequence, then the bounds, in that order, and
the helper checks `0 <= i <= j <= length` before it copies: outside
that, the runtime error `the slice 2:4 is outside an array of 3
elements` (`a list`, `a String`, `a DynArray`, `a view`). The result is a
new value of the sequence's own kind, read off its marker: an array
(`pykArray`) or a view gives an array, a DynArray a DynArray, anything else a
list; a String is sliced by code point (`Array.from`) and joined again.
The copy is shallow, as JavaScript's `slice` is.

**A view shares.** `view(a, i, j)` is `pykView(a, i, j)`, an object
naming the array, an offset into it and a length:

```javascript
{ pykView: true, owner: a, offset: 1, length: 3 }
```

A view of a view names the same array, the offsets added, and its
bounds are checked against the view it is made from (`the view 0:2 is
outside a view of 1 element`). Every call makes a new object, so
`same(w, w2)` -- `===` -- is false for two views made separately, as
the interpreter says. The property is called `length` so that `len(w)`
is `w.length`, as an array's is, and `pykIndexError` (which reads the
marker to say `a view`) works on it unchanged.

```pyking            // generated JavaScript
view(a, 1, 4)        pykView(a, 1, 4)
w[k]                 pykViewAt(w, k)        // checked against the view
w[k] := x            pykCheckIndex(w, k);
                     pykViewSet(w, k, x);   // owner[offset + k] = x
len(w)               w.length
for x in w:          for (const x of pykViewWalk(w)) {
[f(x) for x in w]    pykList(pykViewItems(w).flatMap(...))
copy_into(d, s)      pykCopyInto(d, s)
```

A view's length never changes, so its write needs no second check.
`pykViewWalk` is a generator reading `owner[offset + i]` as each turn
comes; `pykViewItems` is the elements as they are, a new array.

**`copy_into(dst, src)`** copies `src`'s elements out first and then
writes them over `dst`'s first ones, which is memmove's result where
the two are views of one array and overlap. A longer `src` is the
runtime error `copy_into copies 2 elements into 1`. `view` and
`copy_into` are the program's own where it defines or imports one.

**Printing** is `view([21, 30, 41])`: the array's elements from the
offset, as they are now; `v{s}` in a descriptor where they are Floats
or Chars, handed to `print` as `pykLater` when it is not the last
argument. On `pykFormat`'s path a view stands for its array, so a view
of an array met inside that array prints `...`.

## Pointers

**A pointer is an object naming a place**: `get` and `set` read and
write it, and `store` and `slot` say which place it is, which is what
two pointers compare.

```javascript
{ pykPtr: true, store, slot, get: () => ..., set: (value) => { ... } }
```

- **A `var`'s address.** JavaScript has no address of a variable, so a
  `var` whose address the module takes anywhere (`addressed` in the
  scope, gathered once by walk.ml) gets one place object beside its
  `let`, reading and writing the variable through closures:

  ```javascript
  let x = 1;
  const x__place = pykVarPlace(() => x, (pykNew) => { x = pykNew; });
  ```

  `&x` is `x__place`, so every `&x` of one variable is one object --
  its own `store` -- and two of them are equal. The closures keep the
  variable alive after its function returns, as a closure's captured
  variable is, so a pointer to a local may outlive the call
  (tests/pointers_escape.pyk). The variable itself stays an ordinary
  `let`: reads and writes of `x` are unchanged, and a `var` whose
  address is never taken gets no place.
- **An element.** `&a[i]` is `pykElemPlace(a, i)`: the array, then the
  index, then the check (`the index 5 is outside an array of 2
  elements`, or `a view of`), then a place whose store is the array and
  whose slot is `i`. A view's element is its array's, at `offset + i`,
  so a pointer through a view and one through the array are equal.
- **A field.** `&s.f` is `pykFieldPlace(s, 'f')`: the var struct object,
  and the field's name as the slot.
- **`&*p`** is `p`.

`*p` is `p.get()`, and `*p := v` is `p.set(v)`, which works out the
pointer, then the value, then writes. A compound `*p += 1` arrives with
the pointer held in `pointer__target`. `p == q` is `pykEqual`, which
compares a pointer's `store` and `slot` -- also where pointers sit in a
list or a tuple. A pointer that may be absent is an `Option(Ptr(T))`,
an ordinary datatype value.

**Printing** is `Ptr(12)`: what the pointer points at now, as a value
inside a list prints (Strings and Chars quoted), never an address;
`p(s)` in a descriptor where it is a Float or a Char, and `pykLater`
when such a pointer is not `print`'s last argument. On `pykFormat`'s
path a pointer stands for its store.

## Equality

`==` and `!=` on Ints, Floats, Strings, Chars, Bools and `()` are
JavaScript's `===` and `!==`: each is one primitive here (a Char a
number, `()` `undefined`), and `===` already follows IEEE for a Float --
`NaN === NaN` is false and `-0 === 0` true. On a list, a tuple, a struct
or a datatype the checker's type of the left operand says so, and the
comparison is the module's own `pykEqual`, since `===` on two objects
asks whether they are one:

```pyking                          // generated JavaScript
[1, 2] == xs                       pykEqual(pykList([1, 2]), xs)
p != Point(0, 0)                   !pykEqual(p, Point(0, 0))
```

`pykEqual` walks both values: arrays (lists and tuples) by length, then
element by element; Maps by size, then each key's value in the other,
whatever the order; pointers by `store` and `slot` (see "Pointers");
datatype and struct values by `pykTag`, then their `pykValues`;
anything else with `===`. It never takes a value's
identity as its equality, so `xs == xs` is false where `xs` holds a
NaN, as in every other target. The checker refuses `==` on anything
mutable, so a cycle cannot reach it.

## MutMaps

**A MutMap is a JavaScript `Map`** with two properties on it: the marker
`pykMutMap = true`, which `pykFormat` reads, and `pykVersion`. A `Map`
already keeps its keys in the order they were put in, keeps a replaced
key where it is, and puts a key deleted and put back at the end --
Pyking's rules exactly. It is a reference, so every name holding a MutMap
shares it, and `same(d, e)` is `d === e`.

A `Map` compares object keys by identity, so a key is stored under
`pykKey(k)`: a number, String, Bool or `()` key is itself, and a tuple,
list or datatype key is text built from its parts (Strings quoted, so
`("a,b", "c")` and `("a", "b,c")` have different texts) -- two keys have one
text exactly when they are `==`. A MutMap's keys are all of one type, so
a key's text never meets a String key. Each entry is the `[key, value]`
pair, which is also what printing writes as a tuple.

```pyking            // generated JavaScript
mutmap()               pykMutMap()
mutmap(pairs)          pykMutMapOfList(pairs)      // first place, last value
d[k]                 pykMutMapGet(d, k)          // missing: an error
d[k] := v            pykMutMapPut(d, k, v);
get(d, k, x)         pykMutMapGetOr(d, k, x)
has(d, k)            pykMutMapHas(d, k)
keys(d)              pykMutMapKeys(d)            // also values, items
remove(d, k)         pykMutMapRemove(d, k)
discard(d, k)        pykMutMapDiscard(d, k)
clear(d)             pykMutMapClear(d)
len(d)               d.size
for k in d:          for (const k of pykMutMapWalk(d)) {
[f(k) for k in d]    pykList(pykMutMapKeys(d).flatMap(...))
```

`remove` and `clear` are a DynArray's or a MutMap's by their first argument's
type, and each of these names is the program's own where it defines or
imports one. `d[k] := v` is a call, so the MutMap, the key and the value
are worked out in that order before the write, with nothing checked
first. A missing key is the runtime error `the MutMap has no key "b"`
(`... to remove` for `remove`), the key written as a value inside
another is; where the key's type holds a Char, the call passes the key's
descriptor too, so `'z'` prints as a Char rather than its code point.
`pykShaped` writes it, so a module reading a MutMap imports `pykShaped`.

**A `for` notices a change.** `pykVersion` counts keys put in and taken
out -- not values replaced -- and `pykMutMapWalk` is a generator that
compares it with the count it started with at every step, the one that
would end the walk included, so putting a key in or taking one out
during the walk is the error `the MutMap changed while a for loop was
reading it`, at the next step, as in the interpreter.

**Printing** is `mutmap([("ada", 37), ("bo", 6)])`: the entries as
tuples. A MutMap holding Floats or Chars goes through `pykShaped` with
`@(k,v)`, and is handed to `print` as `pykLater` when it is not the last
argument, as an array is. A MutMap is on `pykFormat`'s path like any
value holding others, so one reached again inside itself prints `...`.

## Maps

**A Map is a MutMap's `Map` marked `pykMap` too** (`pykMapEmpty()`, and
`pykMapOfList(pairs)` for `map(pairs)`, which keeps a repeated key's first
place and last value). No write on a Map reaches the backend, so every
MutMap helper that reads -- `d[k]`, `get`, `has`, `keys`, `values`,
`items`, `len`, `for`, a comprehension -- serves a Map as it is, and the
conversions arrive rewritten into those (`list__mutmap(items(m))`). The
marker is what prints it as `map([...])`, and names it in a missing
key's error, `the Map has no key "zed"`. `==` on two Maps compares their
entries whatever their order (see "Equality"). `Map` is a reserved name
(with `Error` and `process`, which the runtime calls too), so a Pyking
constructor or binding called `Map` is renamed rather than shadowing the
global class the runtime builds with.

## `panic`

`panic(message)` is `pykFail(message)`, the call every runtime error is:
`error: <message>` on stderr and exit status 1 under node, an `Error`
in a browser. It is an expression that never answers, so it stands for
a value of any type: `x = if c then 5 else panic("never")` is
`c ? 5 : pykFail("never")`.

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
    "hello, " + name

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
source: `print`, `debug` and the value formatting `builtin.ml` lays
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

A module implemented in JavaScript (declared in `sys_external.pyk` --
see [modules.md](modules.md)) is an **ES module**: it uses `export`, and
the compiler emits `import * as sys_external from './sys_external.js'`
to reach it.

Every JavaScript target emits ES modules, so nothing special is needed
to reach one: the implementation is imported like any other module and
copied beside the program's output as `sys_external.js`.

**A browser needs different code from node**, so a module has one
implementation for each environment: `sys_external_node.js` for `node`
and `sys_external_browser.js` for `web` and `iweb` -- and `iweb`
takes `sys_external_interpreter.js` instead where a library has one, as
tinyweb does, since there the interpreter runs the program and talks to
its page in commands. Each is copied out as `sys_external.js`, which is
what the generated import names; tinyweb's renderer, `tinyweb_page.js`,
goes beside it on `iweb`. A
standard library's browser implementation says on the console what a
page cannot do ([libraries.md](libraries.md), "In the browser").

`sys.exit` stops a program by throwing an error carrying `pykExit`:
under node its implementation installs an `uncaughtException` handler
that makes that the process's status, which writes out everything
already printed before the process ends -- `process.exit` may drop what
is still being written to a pipe. In a browser, the page reads it.

Under `iweb` the implementation is reached from *interpreted* code:
the page imports it, puts it in `pykExternals`, and the interpreter
calls through a host hook, with values crossing as JSON; an exit crosses
back as `{"pyk_exit": code}`.

One thing an implementation has to know: **a Pyking list and a Pyking
tuple are both JavaScript arrays**, and the formatter walks values
rather than reading types, so a list carries `pykList === true` and a
tuple does not. Returning a plain array where the declaration says
`[Int]` prints it as a tuple. `tests/external_shapes_mod1_external_node.js`
is the worked example.

## Let expressions

A `let target = value in body` (PYKING.md, "Let expressions") is compiled as the call of an arrow function taking the name, `((a) => body)(x())`; a tuple target is a temporary parameter taken apart by a `const` inside the arrow function.
A call whose named arguments are not in parameter order, with more
than one that has an effect, reaches this backend as nested `let`s
(`docs/desugar_args.md`).

## Classes

A Pyking class (PYKING.md, "Classes and interfaces") is an ES class, and
an interface one too, never made:

- **Every class goes after the imports**, a parent before its child: a
  class is not hoisted as a function is, and `extends` reads its parent
  when the class statement runs.
- **The constructor** calls `super(...)` with the parent's arguments,
  then sets the class's own header fields and its body fields; each
  method takes its object as `self` (`const self = this;`).
- **`pykClass(C, tag, header, shape, classes, show)`**, after the
  classes, gives each class's prototype what printing and patterns read:
  `pykTag` and `pykValues` (its name and its header's fields), so
  `pykFormat` prints an object as it prints a datatype's value, with
  `pykShape` saying which fields are Floats; `pykClasses`, every class
  and interface it is, which a class pattern tests; and `pykShow`, true
  where `show` says how it prints.
- **`pykMixin(C, I)`** copies an interface's defaults into a class that
  has no body for them, from its own chain or a nearer interface.
- `obj.m(...)` is `obj.m(...)`; `super.m(...)` is
  `Owner.prototype.m.call(self, ...)`, the body the checker chose. An
  upcast is nothing.
