# The Java targets

**Targets in this family:** `java8`, `java17`, `java21`.

**Key points**

- One backend, `boot/target_java.py`, with a `version` parameter -- the
  same shape as `boot/target_c.py`'s `standard`. All three versions
  translate *identically*; only the printer differs, and in one place:
  whether a local declaration spells out its type or writes `var`.
- Java is statically typed and Pyking is not, so this backend **infers
  types** -- `int`, `String`, `boolean` -- for every binding, parameter
  and function, by the same three rules `target_c.py` uses.
- Output is one `.java` file with no imports: string concatenation is
  Java's own `+`, string equality is `.equals()`, and `System.out` needs
  nothing declared.
- `/` is **not supported**, for the same reason as the C targets:
  Pyking's division is Python's (`7 / 2` is `3.5`) and Java's on `int`
  truncates.
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
  scope mechanism `target_c.py` uses).

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

`print`; `def` with parameters, `return`, recursion, and the
single-expression `def f(x) = e` form; `if` / `else if` / `else`;
`while`; `=`, `var`, `:=`; `if … then … else …` expressions; integers,
strings and booleans; `+ - *`, unary minus, comparisons, and calls.

Type annotations are *used* here rather than erased, when they name a
type Java can represent -- exactly as in the C targets.

## What is not supported

Everything the JavaScript and C targets refuse -- lists, tuples, `for`,
`match`/`case`, comprehensions, value-form bindings, `str`/`len`/`range`
-- plus the following. All are refused at compile time with a source
position.

### `/`

```
$ python3 boot/pykboot.py -t java21 divide.pyk
'divide.pyk' 1:6-1:11 Unsupported by target 'java21': `/` is true division in
Pyking and truncating integer division in Java; matching it needs a
floating-point type this backend does not have yet
```

Same reasoning as [the C targets](target_c.md): the *value* would be
wrong, not just its rendering, and fixing that needs a floating-point
type this backend does not have.

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
type isn't `void`. This backend checks for it during translation --
conservatively: it recognises an unconditional `return`, or an `if`/`else`
whose *both* arms definitely return, which is exactly the shape every
function in this shared subset already needs to have (a `while` loop
can never be the proof on its own, since Pyking has no boolean literal to
spell an unconditional `while true:` with) -- and refuses anything it
cannot prove returns, rather than handing `javac` a file it will reject
with a less helpful message and no Pyking source position.

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
- `+` mixing an integer and a string -- Java would happily stringify the
  integer, but that is not what Pyking's `+` means (it has no implicit
  conversion), so this backend refuses it rather than translate `+` into
  two different Pyking operators depending on its operands.

### A recursive function returning non-`Int` without an annotation

```
Unsupported by target 'java21': `f` calls itself and does not return Int;
a recursive function's return type is assumed Int unless annotated, so
annotate it (`-> String`, `-> Bool`)
```

Same cause as the C targets: the signature must exist before the body is
translated (so the body can call it recursively), and the return type
starts as `Int` until the body says otherwise. Adding `-> String` or
`-> Bool` resolves it.

## How types are inferred

Identical to [the C targets](target_c.md#how-types-are-inferred): three
types -- `Int`, `String`, `Bool` -- and three rules (a binding takes its
initializer's type; a parameter takes its annotation when Java can
represent it, else a guess from whether the body concatenates or compares
it with a string, else `Int`; a function's return type is read back off
its translated body). The same caveat applies: rule 2 is a guess, and an
unannotated parameter the body only ever returns unchanged will infer
`Int` and refuse a call site that passes a string.

## Naming the class

Java requires the file holding a `public` class to share that class's
name exactly, so this backend cannot simply reuse the source's own
spelling the way every other target does. With no `--output`, the
default name is **Java-cased**, not the source's:

```
$ python3 boot/pykboot.py -t java21 foo_bar.pyk     # writes FooBar.java
$ python3 boot/pykboot.py -t java21 test1.pyk       # writes Test1.java
```

Words are split on anything that is not a letter or digit, each
capitalised and run together (`default_class_name` in
`boot/target_java.py`); a stem with none becomes `Program`, and one that
would start with a digit gets an underscore prefixed, since neither is a
legal Java identifier otherwise.

An explicit `--output` is trusted as-is instead: the class is named after
whatever file the caller chose, lower case and all --
`--output prog.java` writes a file holding `public final class prog`,
because that is what `javac` requires of a file called `prog.java`.

## How things compile

### The same program, all three versions

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
            System.out.println(sign(i) + " " + classify(i) + " " + ("a".equals("b") ? "True" : "False"));
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
`+` -- which already means concatenation once either side is a `String` --
and single spaces:

```pyking                          // generated Java
print(1, "two", 3 < 4)             System.out.println(1 + " " + "two" + " " + (3 < 4 ? "True" : "False"));
```

Java spells booleans `true`/`false`; Pyking prints `True`/`False`, so a
printed boolean becomes a conditional expression first, exactly as in the
C targets' `printf` arguments -- just built as an ordinary Java
sub-expression here rather than a separate format-string entry, since
`System.out.println` takes one argument, not a format and a list.

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
`target_c.py` uses and for the same reason (two Java locals is exactly
what two different types needs).

*Not optimal:* the renaming scope is shared across an entire translation
rather than scoped the way Java's own method bodies are, so a function
parameter that happens to share a name with an unrelated top-level
binding gets renamed even though the two could never actually collide in
the generated file (they are in different methods). `tests/subset_values.pyk`'s
`use(outer)` demonstrates this: its parameter compiles as `outer2`, not
because Java would object to `outer`, but because this backend's scope
mechanism does not know method bodies don't share a namespace with `main`.

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
