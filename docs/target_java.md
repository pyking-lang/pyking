# The Java targets

**Targets in this family:** `java8`, `java17`, `java21`.

**Key points**

- One backend, `src/target_java.ml`. It infers no types of its own:
  every type it writes is read out of the checker's `tmap`, as
  `src/target_ocaml.ml` reads them. So it takes the whole language the
  checker accepts, and `make test` runs every test program on all three
  versions.
- Pyking's polymorphism is Java's generics; a list is a `java.util.List`;
  a tuple is a class of the shared runtime; an array, a DynArray and a view
  are the runtime's `PykArray`, `PykDynArray` and `PykView`, a MutMap its
  `PykMutMap` over a `LinkedHashMap`, a pointer its `PykPtr`; a datatype is a class per constructor; a `mutable struct` is a
  class with fields written in place; a function value is a
  `java.util.function` interface.
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
| `Char` | `PykRuntime.PykChar`, a final class holding the code point as an `int` |
| `()` | `Void`, whose one value is `null`; a function answering it is `void` |
| `[T]` | `java.util.List<T>` |
| `Array(T)` | `PykRuntime.PykArray<T>`, holding an `Object[]` (see "Arrays, DynArrays and views") |
| `DynArray(T)` | `PykRuntime.PykDynArray<T>`, holding a `java.util.ArrayList<Object>` |
| `Slice(T)` | `PykRuntime.PykView<T>`: the array it is of, an offset and a length |
| `MutMap(K, V)` | `PykRuntime.PykMutMap<K, V>`, holding a `java.util.LinkedHashMap` (see "Equality and MutMaps") |
| `Map(K, V)` | `PykRuntime.PykMap<K, V>`, a `PykMutMap` nothing writes (see "Equality and MutMaps") |
| `Ptr(T)` | `PykRuntime.PykPtr<T>`: the store it points into and a slot (see "Pointers") |
| `(A, B)` | `PykRuntime.T2<A, B>`, up to `T8` and beyond as a program needs |
| `(A) -> R`, `(A, B) -> R`, `() -> R` | `java.util.function.Function`, `BiFunction`, `Supplier` |
| a function of three or more parameters | `PykRuntime.Fn3`, `Fn4`, ... |
| a type variable `a` | the method's type parameter `A` |
| `Tree(a)` | the datatype's own class, `Tree<A>` |
| a parameter of type `all a. (a) -> a` | `PykRuntime.Poly$...`, an interface with one generic method |

A value of a type variable is a boxed object, so `==` on two of them
unboxes first: Java's `==` on two `Integer`s compares the objects.

A list literal is `java.util.Arrays.asList(...)`, and `[]` is
`java.util.Collections.emptyList()`, whose element type Java infers
from where it goes -- except as an element of a list literal next to
non-empty ones (`[[1, 2], [], [3]]`), where `asList` would infer it
from nothing and refuse the call: there it is
`java.util.Collections.<Integer>emptyList()`, the element type the
checker settled, where that type names no variable.

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

A datatype of one constructor -- a `struct` -- is that constructor's
class alone, which is then the type: a record on java17 and java21, a
final class on java8, with no base type and no factory. A construction
is `new Point(1, 2)` (`new Box<>(...)` where it has parameters), and a
pattern on it tests nothing.

A **`mutable struct`** (PYKING.md, "Mutable structs") is a final class on
every version -- a record's fields are final, and a mutable struct's are
written in place -- with a public, non-final field per field, a
constructor, and `PykRuntime.Data`'s two methods:

```java
    private static final class Point implements PykRuntime.Data {
        public int x;
        public int y;
        public Point(int x, int y) {
            this.x = x;
            this.y = y;
        }
        public String pykTag() { return "Point"; }
        public Object[] pykFields() { return new Object[] { x, y }; }
    }
```

A value of it is a reference: assigning, passing, returning or storing
one shares the one object, so a write through any name holding it is
seen through all. It has no `equals` of its own (the checker refuses
`==` on one), and `same(a, b)` is `(Object) a == (Object) b`, true
exactly when the two are one object. A field is read as `p.x` and
written as `p.x = v;` -- Java's own assignment to a field works out the
owner first, then the value, then writes into the object the owner was,
which is Pyking's order; a compound `p.x += e` arrives with its owner
already in a temporary (`desugar_args.md`). A pattern on one reads the
fields as they are when it is matched; on java21, where a record pattern
cannot take a class apart, its case is a type pattern (`case Point t$1`)
and its fields are read off the variable. A `struct` without `var`, and
every datatype, stays a record or a final class with final fields.

A field every constructor has is a method of the base type,
`p.name()`, which is what `x.name` compiles to. A field with no name is
`f$0`, `f$1`, ...; a name Java reserves takes a `$`.

## Functions as values

A def's name used as a value is a lambda calling its method, of the
interface its type at that use names. A call answering nothing used as
a value is `PykRuntime.unit(() -> call)`; an `if ... then ... else`
evaluated for its effect alone is an if statement instead, so a branch
calling one may read a variable the method changes, which a lambda may
not. A Pyking lambda is a Java lambda.
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

A loop's accumulator is a local, assigned at the end of each turn -- and
by a `break x`/`continue x` just before it jumps, so the loop is worth
`x` or the next turn starts from it; a
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
run time: a boxed `Double` is a Float, a `PykChar` a Char, a `List` a
list, a `PykArray`, `PykDynArray` or `PykView` an array, a DynArray or a view
(`array([1, 2])`, `dynarray([1, 2])`, `view([1, 2])`), a `PykMutMap` its
entries as tuples (`mutmap([("ada", 37)])`), a `Tuple` a tuple, a `Data`
a datatype. A Java value carries its
class, so the walk needs nothing from the compiler. A Char at top level
is its character (`PykChar.toString`); inside another value a String is
written in double quotes and a Char in single quotes, escaped as
`Builtin.quote_string` and `Builtin.quote_char` say.

**A cycle** -- an array, a DynArray, a MutMap or a mutable struct that holds
itself, directly or through other values -- is written `...` where it
repeats: `Node(1, Next(Node(2, Next(...))))`. The walk keeps its
**path**, the stores, MutMaps and datatype values it is inside of, in an
identity set (a view is on it as the array it is of); a value
already on it is `...`, and one only shared -- the same struct twice in
an array -- is on the path only while it is being written, so it prints
in full each time. `string(v)` and every other formatting go through the
same walk.

**Every argument is worked out before any is written.** A line of
several values is one string concatenation where nothing can change in
between; where an argument whose value can change (an array, a DynArray, a
view, a MutMap, a mutable struct, anything holding one) comes before one that calls something, the
arguments go to `PykRuntime.line(a, f(a))` instead, which Java calls
only once both are evaluated, so a change `f` makes to `a` is printed.

## Chars and Strings

A Char is `PykRuntime.PykChar`, a class of its own rather than an `int`
so that `PykRuntime.str` can tell it from an Int when it walks a list.
It holds the code point in `code`, and its `equals`, `hashCode` and
`compareTo` are the code point's, so `==` on two Chars is
`java.util.Objects.equals` like any other object, and `<`, `<=`, `>`,
`>=` compare `a.code` with `b.code`. A literal `'a'` and a pattern
`case 'a':` are `PykRuntime.chr(97)`.

A Java String is UTF-16, but Pyking counts a String in code points:
`len(s)` is `PykRuntime.len`, `s.codePointCount(0, s.length())`;
`s[i]` is `PykRuntime.charAt`, the code point at
`s.offsetByCodePoints(0, i)`, throwing `IndexOutOfBoundsException` out
of range as a list's `get` does; and `for c in s`, `loop ... for c in s`
and `[e for c in s]` walk `PykRuntime.chars(s)`, the String's Chars as a
list. `int(c)` is `c.code`, `float(c)` `(double) c.code`, `bool(c)`
`c.code != 0`, and `char(x)` is `PykRuntime.charOfInt` (`'\0'` for an
Int that is no code point) or `PykRuntime.charOfString` (`'\0'` for
`""`). No external module takes or answers a Char today; one that did
would see a `PykRuntime.PykChar`.

## Arrays, DynArrays and views

An `Array(T)` (PYKING.md, "Arrays") is `PykRuntime.PykArray<T>`, a
final class of the runtime holding its elements in an `Object[]`; a
`DynArray(T)` (PYKING.md, "DynArrays") is `PykRuntime.PykDynArray<T>`, holding a
`java.util.ArrayList<Object>` that `remove` and `pop` clear the slot of;
and a view, a `Slice(T)` (PYKING.md, "Slices"), is
`PykRuntime.PykView<T>`, the `PykArray` it is of with an offset and a
length, reading and writing that array's own elements. All three extend
`PykRuntime.PykStore<T>`, which holds what they share: `check`, `get`,
`set`, the walk and `toList`. There
is no `int[]` or `double[]` for an array of Ints or Floats yet: every
element is boxed, as in a list, so one class serves every element type
and a generic function over `Array(t)` is an ordinary generic method.
Assigning, passing, returning or storing one copies the reference
alone, so every name holding one sees a write through another; a `var`
holding one that a closure captures is a cell holding the reference,
like any other `var`.

| Pyking | Java |
|---|---|
| `array(xs)` | `PykRuntime.<T>arrayOfList(xs)` |
| `array(n, v)` | `PykRuntime.<T>arrayFill(n, v)`: every element the one `v` |
| `array(n, f)` | `PykRuntime.<T>arrayInit(n, f)`: `f(0)`, `f(1)`, ... in order |
| `array(n, seed, f)` | `PykRuntime.<T, S>arrayUnfold(n, seed, f)` |
| `dynarray()`, `dynarray(xs)` | `PykRuntime.<T>dynarrayEmpty()`, `PykRuntime.<T>dynarrayOfList(xs)` |
| `view(a, i, j)` | `a.view(i, j)`: a view of the same array, offsets added for a view's |
| `a[i]` | `a.get(i)` |
| `a[i] := v` | the four statements below |
| `len(a)` | `a.size()` |
| `same(a, b)` | `(Object) a == (Object) b`, as for two mutable structs |
| `for x in a` | Java's enhanced `for` over the store, an `Iterable<T>` |
| `push(v, x)`, `pop(v)` | `v.push(x)`, `v.pop()` |
| `insert(v, i, x)`, `remove(v, i)`, `clear(v)` | `v.insert(i, x)`, `v.remove(i)`, `v.clear()` |
| `copy_into(dst, src)` | `PykRuntime.copyInto(dst, src)`: `System.arraycopy`, a memmove |
| `a[low:high]` | `a.slice(low, high)`, a new value of its kind (see "Slices") |

A builtin that answers nothing (`push`, `insert`, `clear`) answers a
`Void`, so its call is a value where one is wanted and a statement of
its own otherwise. A program's own `push`, `remove`, ... is called
instead wherever it defines one.

The element type is written as an explicit type argument where the
checker settled it, which also gives a lambda argument its interface;
a lambda handed to a factory or written into an element is cast to its
own type besides, since `Object` is no interface Java can type one by.

**Every index is checked**, a read's and a write's: `get` and `set`
call `check`, which stops the program with `the index 5 is outside an
array of 2 elements` (`a DynArray of`, `a view of`) for an index below 0 or
past the end as the length is then -- there is no counting from the
end. `pop` of an empty DynArray stops it with `pop from an empty DynArray`,
`insert` outside 0 to the length with `insert's index 5 is outside 0 to
2, the DynArray's length`, `view` outside its array with `the view 1:5 is
outside an array of 3 elements`, and `copy_into` of more than fit with
`copy_into copies 3 elements into 2`. A negative size stops it with `an array's size
is never negative, and this one is -1`, before the factory calls
anything or makes anything, and an `OutOfMemoryError` making the
elements with `an array of N elements is more than this machine can
hold`. A runtime error is `PykRuntime.fail`: it flushes `System.out`,
writes `error: ` and the message to `System.err` and exits with
status 1. **`panic(message)`** is `PykRuntime.panic(message)`, a generic
`static <T> T panic(String)` that throws `fail(message)`, so it stands
in an expression of any type (`PykRuntime.<Integer>panic(...)` where the
checker settled the type without variables) or as a statement.

**An element write runs in Pyking's order**, not Java's: `a[i] = v`
would work `v` out before it checks `i`. So `owner[index] := value` is

```java
        final PykRuntime.PykArray<?> array$1 = owner;
        final int index$2 = index;
        array$1.check(index$2);
        array$1.set(index$2, value);
```

-- the store and the index held (`PykDynArray<?> dynarray$1`, `PykView<?>
view$1` for the others), the index checked, and only then the value
worked out and written into the store held, even where working it out
rebinds the variable the owner was read from; `set` checks again, since
working the value out may have shrunk a DynArray. A compound `a[i] += e`
arrives with its owner and index already in temporaries
(`desugar_args.md`). `set` takes an `Object`, since the owner is held
with a wildcard; the checker has already made sure the value fits.

**Walking a store** is Java's enhanced `for`: `PykStore`'s iterator
reads element `i` when turn `i` is reached, and goes on while `i` is
below the length as it is then, so a write to a later element during
the loop is seen, what is pushed onto a DynArray is walked, and a removal
ends the walk sooner. A comprehension over a store is
`PykRuntime.flatMap` over `toList()`, the elements as they are when it
starts.

**Printing** an array is `PykRuntime.str`'s walk: `array([` (`dynarray([`,
`view([`) and the elements as they are written inside a list -- Strings
and Chars quoted, a store inside nested -- then `])`; one met again
inside itself is `...` ("Printing").

## Slices

`seq[low:high]` (PYKING.md, "Slices") copies a run into a new value of
the sequence's own kind: `a.slice(low, high)` on an array, a DynArray or a
view (a view's is a new array), `PykRuntime.slice(xs, low, high)` on a
list and on a String, which counts in code points. Java works out the
sequence, then `low`, then `high`, and only then calls the copy, which
checks `0 <= low <= high <= length`: `the slice 2:9 is outside a list
of 3 elements` (`a String`, `an array`, `a DynArray`, `a view`). A left-out
`low` is `0`, a left-out `high` is `null`, the length the copy finds.

## Equality and MutMaps

**`==` and `!=`** on two Ints, Floats or Bools are Java's own, on two
Strings `equals`, on two Chars `java.util.Objects.equals`, and on two
lists, tuples, structs or datatypes `PykRuntime.equal(a, b)`: part by
part, a datatype by its constructor's tag and then field by field, and
a Float inside by IEEE's `==`, so `[nan] == [nan]` is false and `(-0.0,
1) == (0.0, 1)` true -- which a record's own `equals`, comparing with
`Double.compare`, would get wrong.

A **`MutMap(K, V)`** (PYKING.md, "MutMaps") is `PykRuntime.PykMutMap<K, V>`,
a `java.util.LinkedHashMap` of its entries in the order their keys were
first put, and a `version` counting the keys put and taken. A key is
compared and hashed by its own `equals` and `hashCode`: a key's type
holds no Float and nothing mutable, so a record's, a `List`'s and the
runtime's own classes' are Pyking's `==`. On java8, where a tuple or a
datatype is a plain class, the class's `equals` and `hashCode` are
`PykRuntime.equal` and `PykRuntime.hash`, a hash agreeing with it.

| Pyking | Java |
|---|---|
| `mutmap()`, `mutmap(pairs)` | `PykRuntime.<K, V>mutmapEmpty()`, `PykRuntime.<K, V>mutmapOfList(pairs)`: a key given twice keeps its first place and its last value |
| `d[k]` | `d.get(k)`, or `the MutMap has no key "bo"` |
| `d[k] := v` | `d.put(k, v);` -- Java works out the MutMap, the key and the value, then puts |
| `get(d, k, x)`, `has(d, k)` | `d.get(k, x)`, `d.has(k)` |
| `remove(d, k)`, `discard(d, k)`, `clear(d)` | `d.remove(k)` (or `the MutMap has no key "bo" to remove`), `d.discard(k)`, `d.clear()` |
| `keys(d)`, `values(d)`, `items(d)` | `d.keys()`, `d.values()`, `d.items()`: new lists, in order |
| `len(d)`, `same(d, e)` | `d.size()`, `(Object) d == (Object) e` |
| `for k in d` | Java's enhanced `for` over the keys |

A put of a key already there replaces its value where it is; one taken
and put again goes to the end. **Walking a MutMap** reads its keys in
order through an iterator that remembers the `version` it started at:
a key put or taken during the walk stops the program with `the MutMap
changed while a for loop was reading it` at the next `hasNext`, the one
that would end the loop too, before the `LinkedHashMap`'s own iterator
is touched; a value replaced is no change. A comprehension over a MutMap
walks `keys()`, the keys as they are when it starts.

A **`Map(K, V)`** (PYKING.md, "Maps") is `PykRuntime.PykMap<K, V>`, a
subclass of `PykMutMap` that only the reading builtins above ever reach:
`map()` and `map(pairs)` are `PykRuntime.<K, V>mapEmpty()` and
`mapOfList(pairs)`, and `m[k]` of a missing key stops the program with
`the Map has no key "zed"`. It prints as `map([("a", 1)])`, and
`PykRuntime.equal` compares two Maps by their entries in whatever order:
the same keys, each with an equal value. A Map is never a key, so it
needs no hash.

## Pointers

A **`Ptr(T)`** (PYKING.md, "Pointers") is `PykRuntime.PykPtr<T>`: the
store it points into and a slot in it, read by `get()` and written by
`set(v)`. The store is one of three:

| `&place` | Java | the store, the slot |
|---|---|---|
| `&x`, `x` a `var` | `PykRuntime.<T>pointer(x, 0)` | the `var`'s cell, 0 |
| `&a[i]`, `a` an array or a view | `a.pointer(i)`, the index checked now | the array, `i` (a view's `offset + i`) |
| `&s.f`, `s` a mutable struct | `PykRuntime.<T>pointer(s, k)` | the struct, its field's position `k` |
| `&*p` | `p` | |
| `*p` | `p.get()` | |
| `*p := v` | `p.set(v);` -- Java works out the pointer, then the value, then writes | |

A **`var` whose address is taken** lives in a cell, as a `var` a
closure captures does, but of the boxed type -- `final Integer[] x = {
1 };`, a static `Integer[]` at top level -- since a pointer reads and
writes it as an `Object[]`. The cell is made where the `var` is
declared, so a `var` declared in a loop is a new one each turn, and a
pointer to a local outlives its method as the cell does. A mutable struct
class implements `PykRuntime.Struct`, a `Data` with `pykSet(i, v)`,
through which a pointer writes field `i`; it reads it from
`pykFields()`.

**Two pointers are equal** (`PykPtr.equals`, so `PykRuntime.equal`
inside a list or a tuple too) when they name one place: the same store,
by identity, and the same slot. Two `&x` are equal; two `&j` from
different turns of a loop are not. A pointer **prints** as `Ptr(` and
what it points at now, as inside a list, then `)`; on the cycle path it
is the store it points into, so a pointer back into what is being
printed is `...`.

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

## Classes

A Pyking class (PYKING.md, "Classes and interfaces") is a nested class
of the module's own, an interface a nested Java interface:

- **The class** extends its parent at the type arguments the checker
  worked out, implements its interfaces, and -- at the top of a
  hierarchy -- `PykRuntime.Obj`, a `Data` the runtime prints by
  `pykTag()` and `pykFields()` (its header's fields), or by `pykShow()`
  where the class has a `show`. A class nothing in the program extends
  is `final`; an abstract one is `abstract`.
- **Fields** are `public final` (`private` where Pyking says so, not
  final where it says `var`); the constructor calls `super(...)` first,
  then sets its own header fields and its body fields.
- **Each method** is an instance method translated as a static one is,
  with `final C self = this;` first; every method is `public` (an
  interface's are), `@Override` where it overrides, a body in an
  interface a `default` method. A method's name Java or `Object` has
  taken gets a `$`.
- `super.m(...)` is `super.m(...)`, or `I.super.m(...)` for an
  interface's default. An upcast is a cast, which tells Java what a list
  literal or a call has to infer.
- **A `match` on an object** is an `instanceof` chain on every version
  (java21 included), its header's fields read through a cast.
