# The Java targets

**Targets in this family:** `java8`, `java17`, `java21`.

**Key points**

- One backend, `src/target_java.ml`, with a `version` parameter -- the
  same shape as `src/target_c.ml`'s `standard`. All three versions
  translate *identically*; only the printer differs, and in one place:
  whether a local declaration spells out its type or writes `var`.
- Java is statically typed and Pyking is not, so this backend **infers
  types** -- `int`, `String`, `boolean` -- for every binding, parameter
  and function, by the same three rules `target_c.ml` uses.
- Output is one `.java` file with no imports: string concatenation is
  Java's own `+`, string equality is `.equals()`, and `System.out` needs
  nothing declared.
- `/` is Java's own `/` on `int`: Pyking divides integers truncating
  toward zero, which is what Java does.
- **Unlike C, a function must provably return on every path.** `javac`
  refuses to compile one that can fall off the end instead of returning,
  where C only warns -- so this backend checks that itself and refuses
  the program at compile time rather than handing `javac` code it will
  reject anyway. The same strictness makes code after an unconditional
  `return` a compile error, so that is checked and refused too.
- The output file and its class are named in Java's own style, not the
  source's: `foo_bar.pyk` compiles by default to `FooBar.java`, holding
  `public final class FooBar`. See "Naming the class" below.
- Least optimal at: renaming more shadowed bindings than a Java method's
  own scoping strictly requires (inherited from the same conservative
  scope mechanism `target_c.ml` uses).

Verified with `javac --release 8`, `--release 17` and `--release 21`
(the last two by way of a JDK 21 `javac`, which supports emitting all
three).

## The three targets

| | `java8` | `java17` | `java21` |
|---|---|---|---|
| local declarations | `final int x = 1;` | `final var x = 1;` | `final var x = 1;` |
| compile with | `javac --release 8` | `javac --release 17` | `javac --release 21` |

`var` is local-variable type inference (JEP 286, Java 10): java8 predates
it and spells the type out; java17 and java21 both have it and use it.
That is the one axis "use more language features in higher targets" means
here, because the subset this backend accepts (below) never reaches a
construct java17 and java21 would themselves translate differently --
no `record`, no pattern-matching `switch`, nothing a `match` on real
values or tuples as records would eventually give java21 that java17
lacks. Until this backend supports one of those, java17 and java21 emit
the same file beyond the `--release` number in the header comment.
Everything else is shared: one translation, one AST, one set of type
rules, one printer with a single `if version` branch in it.

## What is supported

`print`; `def` with parameters, `return` and recursion, its body
written under the header or on the header's own line (`def f(x): e`);
`if` / `else if` / `else`;
`while`; `loop` with `break` and `continue`; `=`, `var`, `:=`; `if … then … else …` expressions;
integers, strings and booleans; `+ - *`, unary minus, comparisons, and
calls. Tail position, `return if c:`, and unit-returning (`void`)
methods are supported too -- see below.

Type annotations are *used* here rather than erased, when they name a
type Java can represent -- exactly as in the C targets.

## What is not supported

Everything the JavaScript and C targets refuse -- lists, tuples, `for`,
`match`/`case`, comprehensions, value-form bindings, `str`/`len`/`range`
-- plus the following. All are refused at compile time with a source
position.

### Lambdas

```
Unsupported by target 'java21': lambdas, which this backend has no
closure semantics for
```

Java *has* lambdas, and refuses Pyking's for the reason it refuses a
nested `def`: one would need a functional-interface type this backend
does not infer. The two are the same construct from here, so they get
the same answer.

### Nested `def`

```
Unsupported by target 'java21': a nested function -- Java has no local
functions with Pyking's closure semantics; a lambda would need a
functional-interface type this backend does not infer, and could not
mutate a captured variable the way a nested `def` may need to
```

Java's closest equivalent to a nested function is a lambda assigned to a
functional-interface type (`java.util.function.BiFunction<...>` and
friends), and it falls short in two ways a straightforward translation
would need: Java has no built-in functional interface for every arity a
Pyking function might have, and a lambda cannot reassign a captured local
the way a `var`-mutating nested `def` could. Rather than emit something
that works for some nested `def`s and not others, this backend refuses
all of them, the same call C makes for a different reason (no nested
functions at all).

### A function that does not return on every path

```
Unsupported by target 'java21': `f` does not return a value on every
path; unlike Python, javac refuses to compile a method that can fall off
the end instead of returning, so make sure every branch ends in `return`
```

Python returns `None` implicitly when a function's control falls off the
end; `javac` treats that as a compile error for any method whose return
type isn't `void`. Two things narrow when this can fire at all. A method
whose return type *is* `void` -- one yielding unit, see "Tail position
and unit" above -- is exempt, because there is nothing for it to return.
And tail position means a branch need only *end in an expression* to
count as returning, so an exhaustive `if`/`else` satisfies the rule with
no `return` written. What is left is a genuine gap: a path that produces
no value in a method some other path gives one to. This backend checks
for it during translation -- conservatively: it recognises an unconditional `return`, or an `if`/`else`
whose *both* arms definitely return, which is exactly the shape every
function in this shared subset already needs to have. It also recognises
one loop: the `while (true)` a Pyking `loop` compiles to, when nothing
`break`s out of it. That one is not an optional refinement -- a `loop`
with no `break` never finishes, so a method ending in one has no path
off the end, and javac agrees (JLS 14.21: such a statement cannot
complete normally). Refusing it would refuse a perfectly ordinary
program. A `while` loop is still never the proof on its own,
`while true:` included: `stmt_definitely_returns` (see
`src/target_java.ml`) attempts no analysis of a *condition*,
deliberately -- real `javac` does special-case a constant-`true` one,
but recognising that here would mean recognising it for `while 1 == 1:`
too, and Pyking's `loop` is now the way to write a loop that provably
does not end. The backend refuses anything it cannot prove returns by
these rules, rather than
handing `javac` a file it will reject with a less helpful message and no
Pyking source position.

### Unreachable code after a `return`

```pyking
def f(n):
    if n < 0:
        return 1
    else:
        return 2
    print(n)     # rejected: never runs
```

```
Unsupported by target 'java21': unreachable statement -- javac refuses
code after a branch that always returns, where Python would simply never
run it; remove it or restructure the function
```

Python happily keeps dead code after an exhaustive `if`/`else` around; it
simply never executes. `javac`'s reachability analysis treats it as a
compile error, so this backend checks for the same shape (a statement
following one that definitely returns) and refuses it first.

### A `loop` Java cannot give a value

```
Unsupported by target 'java21': a loop worth `()` -- a loop with no
accumulator is worth unit, and Java has no value for one; carry the
value the loop is for, or run the loop for what it does rather than
what it is worth
```

The same shapes the C backend refuses, for the same reason: a loop with
no accumulator (worth unit) or with several slots (worth the tuple of
them) *whose value something wants*, an `if` with no `else` as the last
statement of a loop body, and a body ending in something with no value.
Each is a case Pyking answers with unit or a tuple, which Java has
nothing to hold. Running such a loop for what it does is fine.

### `:=` that changes a variable's type

```pyking
var v = 1
v := "text"     # rejected
```

A Java local has one type for its whole declaration. As in C, this
restricts `:=` only -- rebinding with `=` is a *new* binding and gets a
new Java local, which may well have a different type.

### Type mismatches Java cannot bridge

- `if … then … else …` whose branches differ in type -- Java's `?:` is
  typed once for both arms in the way this backend uses it.
- `==` between different types -- likewise.
- `+` or `++` mixing an integer and a string -- Java would happily
  stringify the integer for `+`, but that is not what either Pyking
  operator means (neither has any implicit conversion), so this backend
  refuses the mix rather than let Java's own `+` paper over it.
- A type variable in an annotation (`def id(x:a) -> a`). Java has
  generics, but this backend infers one concrete type per function and
  emits no type parameters, so a type the caller chooses has nothing
  here to become.
- A list, in any form. This backend infers one concrete type per name
  and has no representation for a list of one; `match` over a scalar is
  supported, as an if/else chain over the subject.

### A recursive or forward-called function returning non-`Int` without an annotation

```
Unsupported by target 'java21': `f` calls itself and does not return Int;
a recursive function's return type is assumed Int unless annotated, so
annotate it (`-> String`, `-> Bool`)

Unsupported by target 'java21': `g` is called before it is defined and
does not return Int; a call written above a `def` is typed from the
annotation, or Int without one, so annotate the return type
(`-> String`, `-> Bool`)
```

Same cause as the C targets: a signature must exist before a call can be
translated, and for a body that has not been read yet the return type
can only come from the annotation, so without one it starts as `Int`.
Adding `-> String` or `-> Bool` resolves both.

### A function reading a binding from around it

```
Unsupported by target 'java21': 'x' is bound outside this function --
these are static methods, with no closure over the code around them: a method reads its parameters and calls other methods, nothing else
```

Pyking's functions may read the bindings in scope where they are written
(PYKING.md, "Names and scoping"); this backend's cannot. A function body
here starts from its own parameters, reaches other functions by name,
and sees nothing else. Passing the value in as a parameter is the fix.

Until this was checked, such a program compiled and then failed in the
host compiler with a message about a name this backend had emitted --
which is exactly what refusing it at compile time, with a Pyking source
position, exists to avoid.

A **default parameter** whose expression reads a binding from around
the definition is refused here for the same reason: a default is
compiled as a generated `def` in the block the definition stands in
(docs/desugar_args.md), so it is a function like any other and reads
only its own parameters and other functions.

```pyking
size = 10
def scaled(x: Int = size) -> Int: x * 2     # refused here
def step(n: Int = 1) -> Int: n * 10         # fine: a literal
```


### A function used as a value

```
Unsupported by target 'java21': `double` is a function used as a value -- these are static methods, not values: only a call can name one
```

A `def`'s name may be *called* here, and nothing else. Binding it
(`twice = double`) or passing it on would emit a bare method name in
Java and a function pointer assigned to an `int` in C — code that does
not compile, and did not, before this was checked. Under C89 it was
merely a warning, which is why the same program built there and failed
under C23.

### An expression statement that is not a call

Pyking lets any expression stand as a statement and discards its value.
Java allows only a call, an assignment or an increment there, so `i + 1;`
is *not a statement* to `javac`. An expression that calls nothing has no
effect to keep, so it is emitted as a comment rather than as code:

```pyking                          # generated Java
i + 1                              // i + 1;   (no effect: value discarded)
print(i)                           System.out.println(i);
```

One that *is* a call is a legal Java statement and is emitted as such.
One in between — `f(1) + 2`, a call buried inside an expression — has an
effect Java cannot express in statement position, so it is refused
rather than silently dropped.

### Forward references and mutual recursion

These are supported, and need less than they do in C: every `def`'s
signature is registered before any body is translated, and that is all —
these are static methods of one class, so Java itself does not care what
order they are written in and nothing has to be declared ahead.

## How types are inferred

Identical to [the C targets](target_c.md#how-types-are-inferred): four
types -- `Int`, `Float`, `String`, `Bool` -- and three rules (a binding
takes its
initializer's type; a parameter takes its annotation when Java can
represent it, else a guess from whether the body concatenates or compares
it with a string or combines it with a float literal, else `Int`; a
function's return type is read back off
its translated body). The same caveat applies: rule 2 is a guess, and an
unannotated parameter the body only ever returns unchanged will infer
`Int` and refuse a call site that passes a string. Annotations naming a
tuple, list or function type are ignored here too — for a function type
what refuses the program is the *call* through the parameter, `call to
unknown function`, since a `def` is not a value this backend can pass.

**Every argument is checked against the parameter type this backend
worked out**, and a mismatch is refused with the position of the call,
as it is in C and for the same reason: Java widens an `int` to a
`double` silently, so an argument at the wrong type would compile and be
quietly wrong. A refusal there means this backend could not work the
type out, not that the program is ill-typed.

## Floats

A `Float` is a `double`. Arithmetic and `/` are Java's own, which are
IEEE's, and equality is `==` rather than `.equals()` — the two differ
exactly on the values Pyking cares about, since `Double.equals` reports
two NaNs equal and `==` does not. `float(n)` and `int(x)` are casts, and
Java's narrowing cast truncates toward zero.

`System.out.println` builds its line by string concatenation, so a
`double` joining it would be written by `Double.toString`. It is wrapped
in a generated `pykFloatStr` instead, implementing `docs/builtin.md`'s
rule. Two things about that helper are not optional:

- **`String.format` takes `Locale.ROOT`.** The default locale writes
  `1,0e+00` wherever the decimal separator is a comma, and one `.out`
  file is compared against every target.
- **`Double.toString` is not used.** It was not the shortest round trip
  before JDK 19, and `java8` is the floor here — so the digits are found
  by formatting at increasing precision until the text reads back as the
  same double.

## Naming the class

Java requires the file holding a `public` class to share that class's
name exactly, so this backend cannot simply reuse the source's own
spelling the way every other target does. With no `--output`, the
default name is **Java-cased**, not the source's:

```
$ pyk compile -t java21 foo_bar.pyk   # writes FooBar.java
$ pyk compile -t java21 test1.pyk     # writes Test1.java
```

Words are split on anything that is not a letter or digit, each
capitalised and run together (`default_class_name` in
`src/target_java.ml`); a stem with none becomes `Program`, and one that
would start with a digit gets an underscore prefixed, since neither is a
legal Java identifier otherwise.

An explicit `--output` is trusted as-is instead: the class is named after
whatever file the caller chose, lower case and all --
`--output prog.java` writes a file holding `public final class prog`,
because that is what `javac` requires of a file called `prog.java`.

## How things compile

### The same program, all three versions

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

`java8`:

```java
// Generated from prog.pyk by the Pyking compiler. Do not edit.
// Target: java8. Compile with:  javac --release 8 Prog.java
//         then run with:            java Prog

public final class Prog {

    private static String sign(final int n) {
        return n < 0 ? "neg" : "pos";
    }

    private static String classify(final int n) {
        if (n < 0) {
            return "low";
        } else if (n == 0) {
            return "zero";
        } else {
            return "high";
        }
    }

    public static void main(String[] args) {
        int i = 0;
        while (i < 2) {
            System.out.println(sign(i) + " " + classify(i) + " " + "a".equals("b"));
            i = i + 1;
        }
    }
}
```

`java17`/`java21` differ in exactly one line -- the loop variable
declares with `var` instead of spelling out `int`:

```java
        var i = 0;
```

Top-level Pyking statements become the body of `main`; `def`s become
`private static` methods, in source order -- which works because name
analysis already requires definition before use.

### Tail position and unit (`void`)

A method body's last statement supplies its value (see "Tail position"
in PYKING.md), so a `return` is pushed down into it, recursively through
`if` branches -- which also means the definitely-returns check below is
satisfied by an exhaustive `if`/`else` whose branches merely *end in an
expression*, with no `return` written:

```pyking                          // generated Java
def pick(x, y, z):                 private static int pick(final int x, ...) {
    if z > 5:                          if (z > 5) {
        x + y              ->              return x + y;
    else:                              } else {
        2 * x                              return 2 * x;
                                       }
                                   }
```

A method that returns no value on any path has Pyking's unit type, which
Java spells `void` -- a body whose tail is a `print` (which yields
unit), a loop, or a binding. Such a method is exempt from the
definitely-returns rule, since there is nothing to return:

```pyking                          // generated Java
def announce(label: String, n):    private static void announce(final String label, final int n) {
    print(label, n)        ->          System.out.println(label + " " + n);
                                   }
```

A `void` call has no value to use, so calling one anywhere but as a
statement of its own is refused with a source position rather than
handed to `javac` as `'void' type not allowed here`.

### `loop`, `break` and `continue`

A `loop` is `while (true)` over one non-`final` local holding the
accumulator. The initializer declares it -- and its Java type is the
initializer's, by the ordinary inference rule -- every tail of the body
assigns the next turn's value, and `break`/`continue` are Java's own,
operand and all: they have none.

```pyking                          // generated Java
res = loop x = 5:                  var x = 5;
    if x <= 10:                    while (true) {
        x + 1                          if (x <= 10) {
    else:                                  x = x + 1;
        break                          } else {
                                           break;
                                       }
                                   }
                                   final var res = x;
```

The accumulator is the one binding here that is deliberately *not*
`final` (see "Immutable bindings stay immutable"): Pyking rebinds it
every turn, and one Java local carries all of them. A loop carrying
several values gets one local per slot, with the next turn's values
computed into `final` locals first so that a slot reading another sees
the turn it is still on.

A loop is worth the accumulator it stopped with, so the locals already
hold the answer: a `break` is Java's own and leaves them holding what
this turn started with. A loop of several slots is worth all of them at
once, which Java has no tuple for -- so one whose value something wants
is refused, while one run for what it does (the shape every
accumulator-passing function has after the tail-call pass, whose every
exit is a `return`) compiles here.

A `while c` can also stop by **running out**, and the loop is worth the
same accumulator then. Java has no loop `else`, and needs none: the
exhaustion test is written by this backend itself, `if (!c) break;` at
the top of a `while (true)`. [target_c.md](target_c.md) says the same
of C.

Binding a loop is that `final` declaration after it, and a loop in tail
position is `return x` -- unless nothing breaks out of the loop, in
which case the `return` is left out, javac refusing a statement that
cannot be reached.

### Names that are keywords in Java

A name can be a good Pyking identifier and a reserved word in Java --
`static`, `class`, `final`, `public`, `new`, `instanceof`, and the rest.
Such a name is renamed by the same mechanism that handles shadowing:

```pyking                          // generated Java
def static(n):                     private static int static2(final int n) {
    n * 2                  ->          return n * 2;
                                   }
```

The list (`RESERVED` in `src/target_java.ml`) also holds `String`,
`System`, `args` and `main`: not keywords, but a Pyking function
shadowing one would break the generated file just as thoroughly. And
`_`, which is a keyword in Java 9 and later and an unnamed variable
(a preview feature) in 21 -- an ordinary Pyking name that `java8` alone
would have accepted, so it is renamed for every version rather than
splitting the family (`tests/renaming_runtime.pyk`).

### Immutable bindings stay immutable

Pyking's `=` is a binding, never a reassignment, so it translates to a
Java local declared `final`; `var`/`:=` translate to one that is not:

```pyking                          // generated Java (java17)
x = 1                              final var x = 1;
var total = 0                      var total = 0;
total := total + x                 total = total + x;
```

Method parameters are `final` too -- Pyking has no way to reassign one
(`:=` only ever targets a `var`), so the parameter really is immutable for
the whole call, and the generated signature says so.

### `print` and booleans

Every argument's type is known statically, so a `print` call becomes one
`System.out.println` whose argument is the values joined with Java's own
`+` -- which means concatenation once either side is a `String`, and is
what this backend emits for Pyking's `++` as well -- and single spaces:

```pyking                          // generated Java
print(1, "two", 3 < 4)             System.out.println(1 + " " + "two" + " " + (3 < 4));
```

No conversion needed for the boolean: Java's `+` already stringifies a
`boolean` operand as `true`/`false`, which is exactly Pyking's own
spelling too (see PYKING.md) -- unlike the C targets, where neither
standard spells a boolean's *printed* form the way Pyking does on its
own, so `target_c.ml`'s `printf` arguments need an explicit conditional
expression (see `docs/target_c.md`'s "Booleans"). A single boolean
argument to `print` on its own (no concatenation to trigger) compiles
just as directly -- `System.out.println` has an overload that takes a
`boolean` argument, and it also prints `true`/`false`.

### Strings

`String`, Java's own. Equality goes through `.equals()`, since `==` on
two `String`s compares references and would agree with Python's `==`
only by the accident of string interning; concatenation is Java's native
`+`, needing no helper the way C's `pyk_concat` does:

```pyking                          // generated Java
"a" == "b"                         "a".equals("b")
greeting + ", " + name + "!"       greeting + ", " + name + "!"
```

### Scope and renaming

Java blocks are lexical scopes, so shadowing across blocks needs no help.
Rebinding does: a Java local cannot be declared twice in one block, and
Pyking's `x = 1` then `x = 2` is two bindings, possibly of two different
types -- so the second gets a fresh Java name (`x2`), the same mechanism
`target_c.ml` uses and for the same reason (two Java locals is exactly
what two different types needs).

*Not optimal:* the renaming scope is shared across an entire translation
rather than scoped the way Java's own method bodies are, so a function
parameter that happens to share a name with an unrelated top-level
binding gets renamed even though the two could never actually collide in
the generated file (they are in different methods). `tests/subset_values.pyk`'s
`use(outer)` demonstrates this: its parameter compiles as `outer2`, not
because Java would object to `outer`, but because this backend's scope
mechanism does not know method bodies don't share a namespace with `main`.

## Modules

Java has classes and no free functions, so a Pyking module becomes a
class -- named the way this backend names the program's own class, since
Java requires the file and its public class to match -- and its exports
become that class's public members.

```java
// Helper2.java
public final class Helper2 {

    // What this module exports as a value; `init` below is what fills each of them in.
    public static String greeting;

    private static int scale(final int n) {
        return n * 2;
    }

    public static int inc(final int x) {
        return scale(x) + 1;
    }

    public static void init() {
        final var greeting = "hi";
        Helper2.greeting = greeting;
    }
}
```

```java
// Program.java
public final class Program {

    public static void main(String[] args) {
        // Every module of the program, in the order they must run.
        Helper2.init();

        System.out.println(Helper2.inc(1));
        System.out.println(Helper2.greeting);
    }
}
```

**`private`/`public` is the privacy**, and Java gives it for free: a
method the module does not export is `private static`, as every method
of a single-module program already was. A public value is a
`public static` field.

**A qualified name is Java's own.** `helper2.inc(1)` is `Helper2.inc(1)`
and `helper2.greeting` is `Helper2.greeting`, so nothing has to be
mangled: the class name *is* the namespace. A name a `from` line took
resolves to the same thing -- `bump` written in the source is
`Helper2.inc` in the output.

**`init` writes its own field by name.** The local that worked the value
out may have the same name as the field, so the assignment says
`Helper2.greeting` rather than `greeting`, which would be the local's
own.

**Order is explicit**, as it is in C: `main` calls `Module.init()` for
every module of the program in dependency order before its own body,
rather than leaving it to Java's class initialization, which runs when a
class is first touched and not before.

All the classes are compiled together (`javac -d . Helper2.java
Program.java`) and live in the default package, which is how they see
one another.

## Where the output is not optimal

- **Over-eager renaming**, as above -- inherited from the same
  conservative scope mechanism the C backend uses, which was built for a
  language (C) where the collision it guards against is real.
- **Integers are `int`.** No width control beyond Java's own overflow
  behaviour, and no bignum -- Python's integers are arbitrary precision,
  so a Pyking program that overflows will disagree with the Python
  target, the same limitation the C targets have.
- **Parameter inference is a guess** for unannotated parameters, as in
  the C targets.
- **No optimisation.** The backend is a printer: no constant folding, no
  dead-code elimination. `javac` and the JIT do that work afterwards.

## External modules

A module implemented in Java (declared in `sys.external.pyk` -- see
[modules.md](modules.md)) lives in **`Sys.java`**, capitalised where the
other targets' implementation files are not: javac requires the file
name and the public class to match, and the generated program calls
`Sys.loadfile(...)`. `Module.class_name` is the rule, the same one that
names a compiled module's file.

Nothing is generated for it and nothing is declared: Java resolves the
class by name, so the file is copied beside the program's output and
handed to javac with it. An external module has no Pyking top level, so
no `Sys.init()` is emitted or called.

The boundary carries `Int`, `String`, `Bool` and unit. A declaration
naming a tuple or a list is refused where it is written, before anything
is translated -- this backend has neither.
