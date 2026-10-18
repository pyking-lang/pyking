# The Java targets

**Targets in this family:** `java8`, `java17`, `java21`.

**Key points**

- One backend, `src/target_java.ml`. It infers no types of its own:
  every type it writes is read out of the checker's `tmap`, as
  `src/target_ocaml.ml` reads them. So it takes the whole language the
  checker accepts, and `make test` runs every test program on all three
  versions.
- Pyking's polymorphism is Java's generics; a list is a `java.util.List`;
  a tuple is a class of the shared runtime; a datatype is a class per
  constructor; a function value is a `java.util.function` interface.
- The three versions are **three shapes of output**: plain classes and
  casts for java8, records, sealed interfaces and `instanceof` patterns
  for java17, records and a pattern `switch` for every `match` on java21.
- Every program is written with **`PykRuntime.java`** beside it: the
  tuple classes, the function interfaces beyond two parameters, the
  interfaces polymorphic parameters are passed as, and the helpers that
  print a value, build a list and convert a String.
- A nested `def` is a **static method** taking what it captures as its
  first parameters; a `var` a closure captures lives in a one-element
  array.
- The output file and its class are named in Java's own style, not the
  source's: `foo_bar.pyk` compiles by default to `FooBar.java`. See
  "Naming the class".

Verified with `javac --release 8`, `--release 17` and `--release 21`
from one JDK 21.

## The three shapes

The same function, a `match` with a guard over a datatype:

```pyking
datatype Shape:
    Circle(radius: Int)
    Rect(width: Int, height: Int)

def area(s: Shape) -> Int:
    match s:
        case Circle(r): 3 * r * r
        case Rect(w, h) if w == h: w * w
        case Rect(w, h): w * h
```

java8 tests the class and casts:

```java
    private static int area(final Shape s) {
        final Shape s$1 = s;
        match$2: {
            if (s$1 instanceof Circle) {
                final int r = ((Circle) s$1).radius;
                return 3 * r * r;
            }
            if (s$1 instanceof Rect) {
                final int w = ((Rect) s$1).width;
                final int h = ((Rect) s$1).height;
                if (w == h) {
                    return w * w;
                }
            }
            {
                final int w2 = ((Rect) s$1).width;
                final int h2 = ((Rect) s$1).height;
                return w2 * h2;
            }
        }
    }
```

java17 binds a pattern variable in the `instanceof` and reads the
record's accessors:

```java
            if (s$1 instanceof Circle t$3) {
                final int r = t$3.radius();
                return 3 * r * r;
            }
```

java21 takes the value apart with record patterns, every other test in
the case's `when`:

```java
        switch (s$1) {
            case Circle(var t$2) -> {
                final int r = t$2;
                return 3 * r * r;
            }
            case Rect(var t$3, var t$4) when PykRuntime.truth((int) t$3 == (int) t$4) -> {
                ...
            }
            ...
            default -> {
                throw new IllegalStateException();
            }
        }
```

java8 also spells every local's type, where java17 and java21 write
`var` for a type that needs no spelling out.

## How types are written

| Pyking | Java |
|---|---|
| `Int`, `Float`, `Bool` | `int`, `double`, `boolean`; `Integer`, `Double`, `Boolean` as a type argument |
| `String` | `String` |
| `()` | `Void`, whose one value is `null`; a function answering it is `void` |
| `[T]` | `java.util.List<T>` |
| `(A, B)` | `PykRuntime.T2<A, B>`, up to `T8` and beyond as a program needs |
| `(A) -> R`, `(A, B) -> R`, `() -> R` | `java.util.function.Function`, `BiFunction`, `Supplier` |
| a function of three or more parameters | `PykRuntime.Fn3`, `Fn4`, ... |
| a type variable `a` | the method's type parameter `A` |
| `Tree(a)` | the datatype's own class, `Tree<A>` |
| a parameter of type `all a. (a) -> a` | `PykRuntime.Poly$...`, an interface with one generic method |

A value of a type variable is a boxed object, so `==` on two of them
unboxes first: Java's `==` on two `Integer`s compares the objects.

**The checker's types come first.** A type it wrote down in the body of
a polymorphic function is in that function's own variables, so the
backend can declare every local with its type. Where Java can infer a
type argument itself -- an empty list, a tuple, a comprehension -- the
backend lets it rather than writing one down.

**A top-level value of a polymorphic type** -- `same = id`, at
`(a) -> a` -- has no Java type, since a field has no type parameters. It
is held as `Object`, built at its type with the variables erased, and
read back at the type each use instantiates.

**A def nothing reaches is not compiled.** The checker works out an
unannotated def's types the first time something calls it, so a def no
live code reaches has none, and nothing needs it.

## Datatypes

A datatype is a base type and a class per constructor. java8 writes an
abstract class and a final subclass per constructor; java17 and java21
write a sealed interface and a record per constructor. Each constructor
implements `PykRuntime.Data`, which is how the runtime prints it, and
has a factory method of its own name answering the base type:

```java
    private static Shape Circle(final int radius) {
        return new Circle(radius);
    }
```

A construction calls the factory, so Java infers a polymorphic call's
type variables from the datatype rather than from the one constructor:
`fold(f, Nil(), xs)` would otherwise infer `Nil<A>` where it needed
`List<A>`.

A field every constructor has is a method of the base type,
`p.name()`, which is what `x.name` compiles to. A field with no name is
`f$0`, `f$1`, ...; a name Java reserves takes a `$`.

## Functions as values

A def's name used as a value is a lambda calling its method, of the
interface its type at that use names. A Pyking lambda is a Java lambda.
A function answering unit answers `null` as a value, so one interface
serves both.

A **nested `def`** is lifted to a static method of the class, named
after the method it was written in (`outer$inner`), taking what it
captures before its own parameters. What a lifted method captures is
known only once the module is translated, since one may call another
that captures more, so the text holds a marker where the captures go and
the printer fills them in. A captured name is passed under the same
name it has where it was bound: every local of a method family has a
name of its own.

A **`var` a closure captures** is a one-element array, `final int[]
count = { 0 };`, so the closure and its owner write one cell. Java
refuses to create an array of a generic type, so the cell of a `var`
holding a list, a tuple or another generic type is made by
`PykRuntime.cell(value)`, a `@SafeVarargs` method answering its
argument array.

A **loop whose body writes a closure** gives every turn its own final
accumulator, read from the variable the loop carries, since a lambda
captures only what is effectively final -- and in Pyking each turn's
accumulator is a binding of its own.

## Polymorphic parameters

A parameter of type `all a. (a) -> a` is an interface of the runtime
with one generic method, named by a hash of its shape, so two modules
agree on it without seeing each other:

```java
    public interface Poly$176b03d5 {
        <B0> B0 apply(B0 q$1);
    }
```

A lambda cannot implement a generic method, so a function handed to one
is an anonymous class whose method calls it. The parts of the type that
mention none of the parameter's own variables are the interface's type
parameters, so `all r. ((a) -> r) -> r` is one interface for every `a`.

## Loops and `match`

A loop's accumulator is a local, assigned at the end of each turn; a
`for` is Java's enhanced `for`; `while c` is Java's `while`. A constant
condition is wrapped in `PykRuntime.truth`, since javac refuses the body
of `while (false)`.

A `match` holds its subject in a local. On java8 and java17 it is an
if/else chain, and a chain whose cases have guards is a labelled block
each case leaves with `break`. Every `match` matches every value
(exhaustive.md), so the last case needs no test. On java21 it is a
`switch`; a `break` written in one leaves the innermost loop by its
label, since an unlabelled one would leave the `switch`.

javac refuses a statement it can prove unreachable, and a method that
can fall off its end: the backend drops what follows a statement that
cannot complete, and ends a method that can with a `throw`.

## Printing

`print` writes one line with `System.out.println`. A String is itself, an
Int or Bool its `String.valueOf`, a Float `PykRuntime.floatStr` -- the
shortest text that reads back as the same double, in Pyking's own
spelling -- and anything else `PykRuntime.str`, which walks the value at
run time: a boxed `Double` is a Float, a `List` a list, a `Tuple` a
tuple, a `Data` a datatype. A Java value carries its class, so the walk
needs nothing from the compiler.

## Naming the class

Java requires the file holding a `public` class to share that class's
name exactly. With no `--output`, the default name is **Java-cased**:

```
$ pyk compile -t java21 foo_bar.pyk   # writes FooBar.java
```

Words are split on anything that is not a letter or digit, each
capitalised and run together (`Module.class_name`); a stem with none
becomes `Program`, and one that would start with a digit gets an
underscore prefixed. An explicit `--output` is trusted as-is: the class
is named after the file. A module whose class would be `PykRuntime` is
refused.

## Modules

A module is a class, its exports public static members, its top level a
method `init` that `main` calls for every module of the program in
dependency order. A qualified name is Java's own: `helper.inc(1)` is
`Helper.inc(1)`. The classes and `PykRuntime.java` are compiled together
in the default package.

A program's runtime is the union of what its modules need, so `pyk`
writes it once, after translating every module.

## External modules

A module implemented in Java is a class named the same way,
`SysExternal.java`, copied beside the output and compiled with it. Its
methods take Java's own types: a callback is the `java.util.function`
interface of its shape, `Runnable` and `Consumer` for one answering
unit, and a list or a tuple is the runtime's. A program hands a callback
a lambda calling the def, or a method reference to a function value.

`sys` reads the program's arguments and its class through two system
properties, `pyking.args` and `pyking.main`, which the generated `main`
of a program importing `sys` sets: only `main` is given them.

## Where the output is not optimal

- **Every value of a type variable is boxed**, and `==` on one unboxes.
- **A lifted def takes every name it mentions** from around it, used or
  shadowed inside.
- **`int` is 32 bits.** Overflow wraps, which Pyking leaves undefined.
- **No optimisation**: javac and the JIT do that work.

## Let expressions

A `let target = value in body` (PYKING.md, "Let expressions") is compiled as `PykRuntime.<A, R>let(x(), a -> body)`: the value is evaluated before the lambda holding the body runs. A tuple target is held in a temporary and each part bound by a `let` of its own inside it. A `var` mentioned in the body lives in a cell, as for any lambda (`captured_vars`).
A call whose named arguments are not in parameter order, with more
than one that has an effect, reaches this backend as nested `let`s
(`docs/desugar_args.md`).
