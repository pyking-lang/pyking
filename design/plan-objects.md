# Plan: object-oriented programming (`use objects`)

This plan adds classes, interfaces and inheritance to Pyking, turned on
per module with `use objects`, the same way `use mutation` turns on
mutation. It replaces steps 12 and 13 of `design/steps.md`. Those steps
were written before `var struct` existed, and before the indexed
inference rule. Section 12 says what changed relative to them.

The requirements this plan answers:

- **Opt-in.** Nothing is OOP unless the module says `use objects`.
- **Fits the existing inference.** Hindley-Milner inference stays as it
  is. Methods may, and here must, have explicit signatures.
- **Close to Java's semantics** and still readable as Python: the
  generated Java and the generated Python both look like code a person
  would write.
- **Easy to understand and use** for students who know some Python and
  are on their way to Java.
- **Every target** compiles it: Java and Python, plus JavaScript, the
  web targets, OCaml (with its own objects), C (simulated with structs
  and function tables), and the interpreter.

Where a question had more than one sensible answer, section 11 lists
the alternatives, with pros and cons, and says which one this plan
recommends. The rest of the document is written as if those
recommendations were taken.

---

## Contents

1. [The design in one page](#1-the-design-in-one-page)
2. [A first example, and what it becomes](#2-a-first-example-and-what-it-becomes)
3. [The features](#3-the-features)
4. [Subtyping and type inference](#4-subtyping-and-type-inference)
5. [Error messages](#5-error-messages)
6. [Translation, target by target](#6-translation-target-by-target)
7. [What is left out, and why](#7-what-is-left-out-and-why)
8. [The rest of the system](#8-the-rest-of-the-system)
9. [Tests](#9-tests)
10. [Phases](#10-phases)
11. [Design alternatives](#11-design-alternatives)
12. [Relation to design/steps.md](#12-relation-to-designstepsmd)

---

## 1. The design in one page

```pyking
use objects

interface Shape:
    def area(self) -> Float
    def name(self) -> String
    def describe(self) -> String:
        self.name() + " of area " + string(self.area())

class Rect(width: Float, height: Float) implements Shape:
    override def area(self) -> Float:
        self.width * self.height
    override def name(self) -> String:
        "rectangle"

class Square(side: Float) extends Rect(side, side):
    override def name(self) -> String:
        "square"
```

| Feature | Included | Why |
|---|---|---|
| `class C(fields):` with fields in the header | yes | the same header a `struct` has, so nothing new to learn; it doubles as the constructor, as a Java record's does |
| Fields declared in the body, `name: T = e` | yes | a field that is not a constructor parameter (a counter starting at 0, a list starting empty) |
| Methods: `def m(self, p: T) -> R:` | yes | Python's spelling. `self` is explicit and written `self.x`, so a reader always sees what is a field |
| Explicit types on every method | **required** | the class's type is known before any body is checked, so calls, overriding and inference stay simple (§4) |
| Objects are references, with identity (`same`) | yes | Java's and Python's semantics, and what `var struct` already does |
| Fields immutable unless `var` (needs `use mutation`) | yes | keeps the two features independent; an object without `var` fields is safe to share |
| `def eq(self, other: C) -> Bool` makes `==` work | yes | Java's `equals`, Python's `__eq__`; without it `==` is refused and the error suggests `same` |
| `def show(self) -> String` controls printing | yes | Java's `toString`, Python's `__str__`; without it an object prints like a struct, `Rect(2.0, 3.0)` |
| `private` members | yes | Java's word, checked by the compiler; Python's `__name` gives the same privacy |
| `interface I:` with signatures and default bodies | yes | Java 8 interfaces, Python abstract base classes |
| `implements I, J` | yes | several interfaces, as in Java |
| `extends C(args)` | yes, **one** class | single inheritance, as in Java. The parent's constructor arguments are written in the header, so there is no `super(...)` call to place |
| `override def` | **required** whenever a supertype has the method | catches the misspelled method that silently fails to override; Java's `@Override`, Kotlin's `override`, OCaml's `method!` |
| `super.m(args)` | yes | calls the inherited implementation |
| `abstract class`, `abstract def` | yes (phase 3) | shared fields plus methods each subclass must give, which interfaces (no fields) cannot do |
| Upcasts inserted where a type is expected | yes | `shapes: [Shape] = [Rect(..), Square(..)]` just works; Pyking never guesses a common supertype (§4) |
| Downcasts by `match` (`case Square(s):`, `case sq: Square:`) | yes | Java's `instanceof` pattern, Python's `match` class patterns; no unchecked casts |
| Generic classes, `class Box(value: a)` | yes | as generic structs today; Java generics, Python's `Generic` |
| Methods with type variables of their own | no (later) | keeps C's and OCaml's tables simple; a module-level `def` does it (§11.12) |
| Method overloading | no | Python cannot express it; one name means one method (§7) |
| Static members, `null`, multiple class inheritance, protected, inner classes, reflection | no | §7 |

The rule that makes it fit Hindley-Milner, in one sentence: **the only
subtyping is an upcast from a class to one of its supertypes, made where
the expected type is already written down** (an annotation, a declared
parameter, a declared return type, a field). Everywhere else two types
must be equal, exactly as today. The checker makes each upcast an
explicit node in the program, so every backend sees it (§4).

---

## 2. A first example, and what it becomes

### Pyking

```pyking
use objects

interface Shape:
    def area(self) -> Float
    def name(self) -> String
    def describe(self) -> String:
        self.name() + " of area " + string(self.area())

class Rect(width: Float, height: Float) implements Shape:
    override def area(self) -> Float:
        self.width * self.height
    override def name(self) -> String:
        "rectangle"

class Square(side: Float) extends Rect(side, side):
    override def name(self) -> String:
        "square"

class Circle(radius: Float) implements Shape:
    override def area(self) -> Float:
        3.14159 * self.radius * self.radius
    override def name(self) -> String:
        "circle"

def total_area(shapes: [Shape]) -> Float:
    loop sum = 0.0 for s in shapes:
        sum + s.area()

shapes: [Shape] = [Rect(2.0, 3.0), Square(2.0), Circle(1.0)]
for s in shapes:
    print(s.describe())
print(total_area(shapes))
print(Square(2.0))
```

Output, on every target:

```
rectangle of area 6.0
square of area 4.0
circle of area 3.14159
13.14159
Square(2.0)
```

### Java (java17; java8 differs only where noted)

Classes are nested static classes of the program's class, as datatypes
are today (`docs/target_java.md`). Every method is `public`, since an
interface's methods are. Printing goes through `PykRuntime.Obj`, a
small interface next to today's `PykRuntime.Data` (§6.1).

```java
public final class Shapes {
    interface Shape extends PykRuntime.Obj {
        double area();
        String name();
        default String describe() {
            return this.name() + " of area " + PykRuntime.string(this.area());
        }
    }

    static class Rect implements Shape {
        public final double width;
        public final double height;
        public Rect(double width, double height) {
            this.width = width;
            this.height = height;
        }
        @Override public double area() { return this.width * this.height; }
        @Override public String name() { return "rectangle"; }
        @Override public String pykTag() { return "Rect"; }
        @Override public Object[] pykFields() { return new Object[] { width, height }; }
    }

    static final class Square extends Rect {
        public final double side;
        public Square(double side) {
            super(side, side);
            this.side = side;
        }
        @Override public String name() { return "square"; }
        @Override public String pykTag() { return "Square"; }
        @Override public Object[] pykFields() { return new Object[] { side }; }
    }

    static final class Circle implements Shape { /* as Rect */ }

    static double total_area(java.util.List<Shape> shapes) {
        double sum = 0.0;
        for (Shape s : shapes) sum = sum + s.area();
        return sum;
    }

    public static void main(String[] args) {
        java.util.List<Shape> shapes =
            java.util.Arrays.<Shape>asList(new Rect(2.0, 3.0), new Square(2.0), new Circle(1.0));
        for (Shape s : shapes) System.out.println(s.describe());
        System.out.println(PykRuntime.show(total_area(shapes)));
        System.out.println(PykRuntime.show(new Square(2.0)));
    }
}
```

Points to notice:
- **The upcasts are invisible in Java.** Java has the same subtyping. The
  checker's upcast node only decides the explicit `<Shape>` on
  `asList`, which Java needs to type the list.
- **`extends Rect(side, side)`** becomes `super(side, side)` as the
  constructor's first statement. That is legal Java because the
  arguments may only use header parameters, never `self` (§3.2).
- **A field is `final`** unless it is a `var` field.

### Python (python12 and python14)

```python
from abc import ABC, abstractmethod
from typing import override


class Shape(ABC):
    __slots__ = ()

    @abstractmethod
    def area(self) -> float: ...

    @abstractmethod
    def name(self) -> str: ...

    def describe(self) -> str:
        return self.name() + " of area " + pyk_string(self.area())


class Rect(Shape, PykObj):
    __slots__ = ('width', 'height')
    _pyk_fields = ('width', 'height')

    def __init__(self, width: float, height: float) -> None:
        self.width = width
        self.height = height

    @override
    def area(self) -> float:
        return self.width * self.height

    @override
    def name(self) -> str:
        return "rectangle"


class Square(Rect):
    __slots__ = ('side',)
    _pyk_fields = ('side',)

    def __init__(self, side: float) -> None:
        super().__init__(side, side)
        self.side = side

    @override
    def name(self) -> str:
        return "square"


def total_area(shapes: list[Shape]) -> float:
    sum_ = 0.0
    for s in shapes:
        sum_ = sum_ + s.area()
    return sum_


shapes: list[Shape] = [Rect(2.0, 3.0), Square(2.0), Circle(1.0)]
for s in shapes:
    print(s.describe())
print(pyk_show(total_area(shapes)))
print(pyk_show(Square(2.0)))
```

Points to notice:
- **`typing.override`** exists from Python 3.12, the oldest Python
  target, so `override def` has a direct counterpart.
- **`PykObj`** is the runtime's mixin that prints an object from
  `_pyk_fields` (§6.2).
- **Field immutability is the checker's job.** Python's `__slots__`
  cannot freeze a field, so a write is refused before the backend runs.

The OCaml, C, JavaScript and interpreter versions of the same program
are in section 6.

---

## 3. The features

### 3.1 The gate

`use objects` turns on:
- `class`, `interface` and `abstract class` declarations;
- method calls `e.m(...)` on objects (field reads `e.f` already exist);
- class patterns on classes and interfaces.

The parser already reads the words (`class`, `interface`, `extends`,
`self` and `super` are reserved in `src/lexer.ml`), and
`src/parser.ml`'s `features` already lists `"objects"`. As with
`mutation`:

- **One parser reads every module.** `class` in a module without
  `use objects` is a syntax error naming the line that would allow it:
  `'class' declares a class, which needs 'use objects' at the top of
  this module`.
- **A feature belongs to its module.** A module may *use* classes
  another module declared — make objects, call their methods, hold them
  in lists — without `use objects`. Only *declaring* a class or an
  interface needs it. This is the rule `var struct` already follows
  (making one needs `use mutation`, holding one does not), loosened
  because making an object changes nothing.
- **Mutation stays separate.** A `var` field needs `use mutation` in
  the declaring module, and writing `o.f := v` needs it in the writing
  module. `use objects` alone gives immutable objects.

New reserved words: `implements`, `override`, `abstract`, `private`.
`extends`, `class`, `interface`, `self` and `super` are reserved
already.

### 3.2 Classes, fields and constructors

```pyking
use objects, mutation

class Account(owner: String, limit: Float = 0.0):
    var balance: Float = 0.0
    history: [Float] = []

    def deposit(self, amount: Float):
        self.balance := self.balance + amount
```

- **Header fields** are the constructor's parameters, and each one is
  also a field, as in a `struct` or a Java record. Defaults and named
  arguments work as they do for a struct:
  `Account("ada", limit = 100.0)`.
- **Body fields** are written `name: T = e` or `var name: T = e`. The
  type is required on a body field, because `[]` alone says nothing. An
  initialiser may use the header parameters by their bare names and
  module-level names. It may not use `self`, so nothing can call a
  method on a half-built object. That is a classic Java pitfall
  (an overridable method called from a constructor), and this rule
  rules it out.
- **The order of construction** is fixed, and is Java's: the parent's
  part first (its header, then its body fields), then this class's
  header fields, then its body fields in the order written. Python's
  `__init__` is generated in the same order (§6.2).
- **A class is written at the top level** of a module (or a submodule),
  as a datatype is.
- **No field may share a name with a method**, in the class or its
  ancestors. Python keeps fields and methods in one namespace. The rule
  also stops `o.size` meaning two things.
- **No field may hide an inherited field.** Java allows that, and
  students find it confusing.
- **A constructor is a function value** like a datatype's constructor,
  so `map(Circle, [1.0, 2.0])` works. An `abstract class`'s is not.

Validation that Java would put in a constructor goes in a module-level
function that returns the object or fails. A future `init:` block is
discussed in §11.4.

### 3.3 Methods and `self`

```pyking
class Vec(x: Float, y: Float):
    def length(self) -> Float:
        math.sqrt(self.x * self.x + self.y * self.y)

    def scaled(self, k: Float = 2.0) -> Vec:
        Vec(self.x * k, self.y * k)

    def plus(self, other: Vec) -> Vec:
        Vec(self.x + other.x, self.y + other.y)
```

- **`self` is written** as the first parameter, without a type, and a
  field or method of the object is reached only through it (`self.x`,
  `self.length()`). That makes it obvious what is a field and what is a
  local, and it is Python's way. Java's implicit `this` is discussed in
  §11.2.
- **Every other parameter and the return type are annotated.** A
  method returning nothing writes no `->`, as a def returning `()` may
  today. With this rule a class's whole interface is known before any
  method body is checked (§4.1).
- **Methods are called with `e.m(args)`**, with named and default
  arguments as for any `def`. The defaults are filled in at the call
  site by the existing `desugar_args` pass, using the method's *static*
  declaration, so every backend sees full argument lists.
- **Defaults are written once**, on the topmost declaration of a method.
  An override may not write its own defaults. C++ and Python differ on
  which defaults a dynamically dispatched call uses; with this rule
  there is only one set.
- **A method used as a value**, `f = v.length`, is a function closed
  over `v`, which is worked out once at that point. This is Java's
  `v::length` and Python's bound method.
- **Recursion** works: a method may call any method of its class
  through `self`, in any order, since all signatures are known first.
- **Tail calls.** `self.m(...)` in tail position is turned into a loop
  only where it cannot be overridden: a `private` method, or a method
  of a class nothing extends within the program. Otherwise dynamic
  dispatch may run another body. `opt_tailcall` gains this one check.

### 3.4 Objects are references

Every object has identity, as in Java and Python:

- Assigning, passing, returning or storing one shares it, as with a
  `var struct`.
- `same(a, b)` asks whether two names hold one object. It already
  exists, for arrays and var structs.
- Without `var` fields an object never changes, so sharing it is never
  visible except through `same`. It behaves like a value but costs one
  allocation.

### 3.5 `var` fields (with `use mutation`)

```pyking
use objects, mutation

class Counter(var count: Int = 0):
    def tick(self):
        self.count += 1

c = Counter()
c.tick()
c.tick()
print(c.count)          # 2
```

`var` before a header or body field makes it writable. The rules are
those of `var struct` fields (`PYKING.md`, "Mutable structs"):
- `o.f := v` and the compound forms are allowed;
- the owner is worked out first, then the value;
- `=` does not write.

A class whose header has a `var` field still has a constructor taking
it as a parameter.

### 3.6 Equality and printing

- **`==` and `!=`** on a class type call its `eq` method, and are
  refused if the class (or an ancestor) has none:

  ```pyking
  class Money(cents: Int, currency: String):
      def eq(self, other: Money) -> Bool:
          self.cents == other.cents and self.currency == other.currency
  ```

  `eq`'s parameter has the class's own type. A subclass inherits it
  (`Square == Square` uses `Rect.eq` through an upcast). It may override
  it with the same signature. On an interface, `==` is allowed only if
  the interface declares `eq(self, other: I) -> Bool`.

  `==` on lists, tuples and datatypes holding objects then works too,
  element by element, through the existing inferred equality (step 3
  of `steps.md`). A type variable is comparable only if what it becomes
  is.

  Why not identity, as Java's `==` is? Pyking's `==` means "equal
  values" everywhere else. Making it mean identity for objects alone
  would be the one place where `==` changes meaning, and the bug Java
  students are warned about on day one. `same` is the identity test.

- **Printing.** An object prints like a struct: the class name and its
  header fields, `Square(2.0)`. Body fields are left out, as Java's
  record `toString` leaves out non-components. A cycle prints `...`, as
  for var structs.
  - **`def show(self) -> String`** replaces that everywhere: in
    `print`, `string`, f-strings, inside a printed list, in the REPL
    and in the debugger.
  - `show` and `eq` are ordinary methods with a reserved meaning. An
    override of them needs `override` like any other.

- **Ordering** (`<` on objects) is not included. §11.11 discusses a
  `compare` method.

### 3.7 `private`

```pyking
class Account(owner: String):
    private var balance: Float = 0.0

    def deposit(self, amount: Float):
        self.balance := self.balance + self.fee(amount)

    private def fee(self, amount: Float) -> Float:
        amount * 0.99
```

- `private` before a field or method makes it reachable only from the
  methods of that class, through any object of that class (Java's
  rule). Subclasses do not see it.
- Everything else is public. A class itself follows the module rule:
  `public class` exports it, its constructor and its public members.
- Java writes `private`. Python writes `__fee`, whose name mangling
  (`_Account__fee`) gives the same class privacy. C and OCaml check it
  at compile time only (OCaml's `method private`, too).
- `protected` is not included (§7).

### 3.8 Interfaces

```pyking
interface Named:
    def name(self) -> String

interface Shape extends Named:
    def area(self) -> Float
    def describe(self) -> String:
        self.name() + " of area " + string(self.area())
```

- **An interface declares method signatures**, and may give a body as a
  *default*, as in Java 8.
- **No fields.**
- **An interface may `extends` other interfaces.**
- **A class `implements` any number of interfaces** and must provide
  every method that has no default, in itself or an ancestor. A missing
  one is refused at the class, by name.
- **Two defaults of one name.** If a class inherits defaults of the
  same name from two interfaces, it must override the method (Java's
  rule). The two signatures must be identical, or the class is refused.
- **An interface is a type**: a parameter, a list's element, a field
  may be a `Shape`. It is never constructed.
- **An interface may have type parameters**, `interface Source(a):`,
  and a class implements an instance of it:
  `class Ones() implements Source(Int):`.

### 3.9 Inheritance

```pyking
class Animal(name: String):
    def sound(self) -> String:
        "..."
    def speak(self) -> String:
        self.name + " says " + self.sound()

class Dog(name: String, breed: String) extends Animal(name):
    override def sound(self) -> String:
        "woof"
    override def speak(self) -> String:
        super.speak() + "!"
```

- **`extends C(args)`** names one parent class and the arguments for its
  constructor. The arguments may use the header parameters. A parent
  with no header writes `extends C()`.
- **A subclass's own header** lists only the fields *it* adds, plus any
  parameters needed to build the parent. Note `name` in `Dog`: it is a
  parameter passed on to `Animal`. A header parameter with the same name
  and type as an inherited field is passed on, not a new field, so it is
  not "hiding" (§3.2). Any other clash is refused.
- **Dispatch is dynamic**, as in Java and Python: `a.speak()` runs the
  body of `a`'s class, wherever it is called from.
- **`override def`** must have exactly the parameter types, parameter
  names and return type it replaces. Return types are not covariant
  (§11.8).
- **`super.m(args)`**, inside a method, calls the implementation the
  class inherited: the parent class's, or else the unique interface
  default. If two defaults could be meant, it is refused, and the class
  must override.
- **Final.** A class nothing in the program extends is compiled as
  `final` in Java. That is an optimisation, not a keyword. A `final`
  keyword is discussed in §11.10.

### 3.10 Abstract classes (phase 3)

```pyking
abstract class Employee(name: String, base: Float):
    abstract def bonus(self) -> Float
    def pay(self) -> Float:
        self.base + self.bonus()

class Engineer(name: String) extends Employee(name, 5000.0):
    override def bonus(self) -> Float:
        500.0
```

- An `abstract class` may have `abstract def`s, signatures with no body,
  and cannot be constructed.
- A concrete subclass must provide every abstract method.
- This is the one thing interfaces cannot do: fields shared by every
  subclass.

### 3.11 Downcasting: class patterns

```pyking
def describe(s: Shape) -> String:
    match s:
        case Square(side):
            "a square of side " + string(side)
        case c: Circle:
            "a circle of radius " + string(c.radius)
        case _:
            s.name()
```

- **`case C(p1, p2, ...)`** matches an object of class `C` *or any of
  its subclasses*, and matches its header fields against the patterns,
  as for a struct. Named field patterns work as they do for structs.
- **`case x: C`** matches an object of class or interface `C` and binds
  it to `x` with that type: Java's `instanceof C x`, Python's
  `case C() as x`. It is the only way to get from a supertype to a
  subtype.
- **Order matters.** Cases run in order, so a `Square` case before a
  `Rect` case matters, and a later case that can never match is a
  warning (the existing unreachable-case check).
- **A `match` on an interface or an extensible class needs `case _`**
  (or `case x: I` for the static type itself), since another class may
  implement it. The existing exhaustiveness pass says so. A closed set
  of alternatives is what `datatype` is for; §11.9 discusses `sealed`.

There is no unchecked cast and no `isinstance` function: a `match` is
the one place a type is tested, and it always says what happens
otherwise.

### 3.12 Generic classes

```pyking
class Stack(a):
    private items: [a] = []
    ...

class Pair(first: a, second: b):
    def swap(self) -> Pair(b, a):
        Pair(self.second, self.first)

p = Pair(1, "one")
print(p.swap())              # Pair("one", 1)
```

- **Type parameters** follow the `struct` rule: on one line, every type
  variable a header field names, in the order they first appear; with
  only body fields, in parentheses after the class name, `class
  Stack(a):`.
- **Inside methods** the class's variables are rigid: a method of
  `Pair(a, b)` works for every `a` and `b`.
- **No variable of its own.** A method may not introduce type variables
  the class does not have (§11.12).
- **Generics are invariant.** A `Box(Square)` is not a `Box(Shape)`, nor
  is `[Square]` a `[Shape]` (§4.4).
- **A class with type parameters** is one type once made, as a `var
  struct` is: `s = Stack()` needs an annotation or a use that decides
  `a`.

---

## 4. Subtyping and type inference

### 4.1 The class table

Before any body is checked, the checker builds a **class table** for the
module (and reads those of the modules it imports from their signature
maps). For each class and interface it records:
- its type parameters;
- its parent class with that class's type arguments, and its interfaces;
- every field: type, `var` or not, `private` or not, inherited or not;
- every method: signature, where it is declared, where its
  implementation comes from, and whether it is abstract or private.

Everything in the table comes from annotations, so building it needs no
inference. That is why methods must be annotated, and why body fields
must state their types. The table is checked on its own:
- no cycles in `extends`;
- overrides match, and every `override` overrides something;
- every method a concrete class needs is provided;
- no field hides another, and no name is both a field and a method;
- diamond defaults are resolved.

Errors found here are reported at the class, before any body.

A class `C(a1..an)` is a new nominal type, `TCon(info, "C", [a1..an])`,
like a datatype's. An interface is one too. Unification treats them as
any type constructor: equal names, equal arguments.

### 4.2 Checking method bodies

Each method is checked as an annotated `def`:
- `self` has type `C(a1..an)`, with the class's variables rigid;
- the parameters have their declared types;
- the body must give the declared return type.

The body may use Pyking's full inference inside (locals, lambdas,
comprehensions), exactly as an annotated def's body does today. A body
field's initialiser is checked against its declared type, with the
header parameters in scope.

### 4.3 Method calls and field reads

`e.m(args)` and `e.f`:
1. Infer `e`'s type and prune it.
2. If it is a class or interface type `C(t1..tn)`, look `m` up in `C`'s
   table entry, walking up to ancestors. Substitute `t1..tn` for the
   class's variables. Check each argument against its parameter type,
   with upcasts allowed (§4.4). The call's type is the return type.
3. If it is still an unsolved variable, refuse with the message field
   reads already give: "nothing here says what class this value is, so
   there is no telling which method 'area' is meant; annotate it". This
   is today's rule for `p.x` on structs (tested above: `def getx(p):
   p.x` is refused even when only one struct has an `x`). Keeping one
   rule for fields and methods means one thing to learn.
4. If it is any other type, refuse: "a Float has no method 'area'".

Because inference runs left to right through a program, the type is
usually known by the time a method is called on it:
- `for s in shapes: s.area()`: `shapes` is a `[Shape]`, so `s` is.
- `[s.area() for s in shapes]` works for the same reason.
- `def f(s): s.area()` does not: annotate `s: Shape`.
- `map(lam s. s.area(), shapes)` depends on argument order; if it is
  refused, the message points at `s`. A comprehension is the idiomatic
  form anyway.

§11.6 discusses deferring such calls to the first call, as §9b now does
for indexed parameters.

### 4.4 Where upcasts happen

`S` is a **subtype** of `T` when `S = T`, or `S` is a class or interface
whose `extends`/`implements` chain reaches `T` with equal type
arguments. There is no other subtyping: no width subtyping, no variance
in generics, no numeric widening.

An expression is **checked against an expected type** — and may then be
an upcast — only at these points, where the expected type is written in
the program:

| Point | Example |
|---|---|
| an argument, where the parameter's declared type (after instantiation and pruning) is a class or interface | `total_area(shapes)`, `r.plus(sq)`, `Rect(...)`'s own fields |
| an annotated binding or `var` | `s: Shape = Square(2.0)` |
| a returned value, against a declared return type | `def pick() -> Shape: Square(1.0)` |
| a field's value: a constructor argument, a body field's initialiser, a field write | `holder.shape := Circle(1.0)` |
| a write to a `var` of a declared type | `var current: Shape = ...; current := Circle(1.0)` |
| the elements of a list or tuple literal, branches of an `if`/`match`, arms of a `loop` result, when one of the points above gives the expected type | `shapes: [Shape] = [Rect(..), Circle(..)]` |

The expected type is pushed *into* literals and branches, never out of
them. So:

```pyking
shapes: [Shape] = [Rect(2.0, 3.0), Circle(1.0)]     # fine: each element is upcast
mixed = [Rect(2.0, 3.0), Circle(1.0)]               # refused: annotate (§5)
s: Shape = if big then Rect(9.0, 9.0) else Circle(1.0)   # fine
```

Everywhere else, unification decides as it does today, and
`Square = Shape` is a mismatch.

**Why this rule.** Full subtype inference (MLsub-style algebraic
subtyping, or constraint solving with bounds) would change every type
Pyking prints and every error it gives, and would make principal types
hard to explain. Local, expected-type upcasts are what Java does at
assignments and calls, and what Python type checkers do with annotated
variables. A student who writes the type gets the upcast; one who does
not gets a message saying where to write it. Generic code is not
affected: a type variable is never "a subtype of" anything. It just
becomes `Square` or `Shape`.

**Invariance.** `[Square]` is not a `[Shape]`. Java's `List<Square>`
is not a `List<Shape>` either, and Pyking's lists compile to Java
lists. A function taking `[Shape]` called with a `[Square]` variable is
refused, and the message suggests annotating the list where it is made.
Immutable lists could safely be covariant (§11.7).

### 4.5 The upcast node

The checker records every upcast as an explicit node in the elaborated
program, `EUpcast(e, from, to)`. A backend that does not need it (Java,
Python, JavaScript, the interpreter) prints `e`. One that does (OCaml's
`(e :> shape)`, C's fat interface pointer, Java's explicit `<Shape>` on
a list) has the static types it needs, without re-inferring anything.
The `-t pyking` output prints nothing for it, so the program
round-trips.

### 4.6 What this costs the inference code

- `typesystem.ml` gains the class table, the method-call rule (next to
  field access, which already demands a known type), the subtype test,
  and a checking mode at the points in §4.4.
- Today's `expect`-style checks for annotated bindings and returns
  become the place where an upcast is tried after unification fails:
  *first unify; on a mismatch between two class/interface types, try
  the subtype test and insert the upcast*. Inference of everything
  without objects is unchanged.
- Generalisation is unchanged: classes are type constructors. A
  generalised scheme may mention them.
- `verified` (§9 of `docs/type_inference.md`) is unchanged: methods are
  already annotated, so their schemes are given, not proposed.

---

## 5. Error messages

Each refusal says what to write instead:

```
'shapes.pyk' 30:8-30:37 Type error: the elements of this list are a
  Rect and a Circle, and Pyking does not guess a common type; annotate
  the list, as in 'shapes: [Shape] = [...]'
'shapes.pyk' 12:4-12:24 Type error: 'Square' has no method 'nme' to
  override; did you mean 'name'?
'shapes.pyk' 9:0-9:52 Type error: class 'Rect' implements 'Shape' but
  does not define 'area(self) -> Float'
'shapes.pyk' 14:4-14:28 Type error: 'name' is defined by 'Rect', which
  'Square' extends: write 'override def name'
'shapes.pyk' 20:9-20:23 Type error: '==' compares two Rects, but 'Rect'
  has no 'eq' method; define 'def eq(self, other: Rect) -> Bool', or
  use 'same(a, b)' to ask whether they are one object
'shapes.pyk' 22:4-22:10 Type error: nothing here says what class 's' is,
  so there is no telling which method 'area' is meant; annotate it,
  as in 'def f(s: Shape)'
'bank.pyk' 7:8-7:20 Type error: 'balance' is private to 'Account'
'bank.pyk' 3:4-3:30 Parsing error: 'var' declares a field that can be
  written, which needs 'use mutation' at the top of this module
'shapes.pyk' 25:4-25:15 Type error: 'Shape' is an interface, which
  cannot be made; make a class that implements it
'shapes.pyk' 31:4-31:26 Type error: a [Square] is not a [Shape]: lists
  do not take subtypes; annotate the list where it is made
```

Each one is a `fail_typecheck_objects_*` test (§9). The did-you-mean
hints use `src/suggest.ml`, as other misspellings do.

---

## 6. Translation, target by target

All targets compile the same elaborated program: classes with resolved
method tables, explicit upcast nodes, calls with full argument lists,
and private members known. Each backend chooses a representation. The
running example is section 2's program, plus the counter of §3.5 and
the class patterns of §3.11.

### 6.1 Java (java8, java17, java21)

| Pyking | Java |
|---|---|
| `class C(x: Int)` | `static class C implements PykRuntime.Obj` with `public final int x;` and a constructor; `final` when nothing extends it |
| `var` field | non-final `public` field |
| `private` member | `private` |
| `interface I:` | nested `interface I extends PykRuntime.Obj`; a default body is a `default` method (Java 8+) |
| `extends B(args)` | `extends B`, and `super(args);` first in the constructor |
| `implements I, J` | `implements I, J` |
| `override def` | `@Override public` |
| `abstract class` / `abstract def` | `abstract static class` / `public abstract` method |
| `self.x` / `self.m()` | `this.x` / `this.m()` |
| `super.m()` | `super.m()`, or `I.super.m()` for an interface default |
| `o.m(a)` | `o.m(a)` |
| `C(...)` | `new C(...)` (`new C<>(...)` with type parameters) |
| `v.length` as a value | `v$1::length` after `final Vec v$1 = v;` |
| upcast | nothing, or a type witness (`Arrays.<Shape>asList`) |
| `a == b` with `eq` | `a.eq(b)`; the class also gets `equals(Object)` delegating to `eq` (for the runtime's list equality) and a constant `hashCode` |
| `show` | the runtime's `pykShow` calls it; `toString` returns it too |
| `case Square(side)` | java8: `if (s instanceof Square) { Square t$1 = (Square) s; double side = t$1.side; ... }`; java17: `if (s instanceof Square t$1)`; java21: `case Square t$1 ->` in a pattern `switch` |
| `case c: Circle` | the same, binding `c` |
| generic class `Pair(a, b)` | `static class Pair<A, B>` |

`PykRuntime.Obj` adds `pykTag()`, `pykFields()` and a default
`pykShow()` to the runtime. The printer treats an `Obj` as it treats
`Data`, except that it calls `pykShow()` when the class defines `show`.
Interfaces extend `Obj`, so a value of interface type prints.

The counter (§3.5) in Java:

```java
    static final class Counter implements PykRuntime.Obj {
        public int count;
        public Counter(int count) { this.count = count; }
        public void tick() { this.count = this.count + 1; }
        @Override public String pykTag() { return "Counter"; }
        @Override public Object[] pykFields() { return new Object[] { count }; }
    }
```

### 6.2 Python (python12, python14)

| Pyking | Python |
|---|---|
| `class C(x: Int)` | `class C(PykObj):` with `__slots__`, `_pyk_fields` and `__init__` |
| `interface I:` | `class I(ABC):` with `@abstractmethod` for signatures, plain methods for defaults, `__slots__ = ()` |
| `extends B(args)` / `implements I` | base classes: `class C(B, I):`, parent class first |
| `override def` | `@override` (from `typing`, 3.12+) |
| `abstract class` / `abstract def` | `ABC` base / `@abstractmethod` |
| `private` member | `__name` (mangled to `_C__name`) |
| `self.x` | `self.x` |
| `super.m()` | an explicit `Parent.m(self)` or `I.m(self)`, so the implementation is the one the checker chose, not whatever Python's MRO finds |
| `C(...)` | `C(...)` |
| `v.length` as a value | `v.length`, a bound method |
| `a == b` with `eq` | `a == b`; the class defines `__eq__` calling `eq` (Python then sets `__hash__` to `None`, which is right: objects are not map keys, §7) |
| `show` | `__str__`/`__repr__` call it; `pyk_show` uses it |
| `case Square(side)` | `case Square(side=side):` (keyword class patterns, so subclasses' `__match_args__` play no part) |
| `case c: Circle` | `case Circle() as c:` |
| generic `Pair(a, b)` | `class Pair[A, B](PykObj):` (PEP 695, 3.12+) |

**Dispatch.** Java dispatch looks in the class chain first, then
interface defaults. Python's MRO agrees for single inheritance plus
interfaces listed after the parent, which is the only shape Pyking
allows. Where a diamond of defaults could make the MRO pick a different
default than Java would, the checker has already forced an override
(§3.8), so the two never disagree. As a safety net, the backend writes
`name = Owner.name` in a class whose MRO winner differs from the
checker's choice. It should never fire, and there is a test that it
does not.

The counter (§3.5) in Python:

```python
class Counter(PykObj):
    __slots__ = ('count',)
    _pyk_fields = ('count',)

    def __init__(self, count: int = 0) -> None:
        self.count = count

    def tick(self) -> None:
        self.count = self.count + 1
```

### 6.3 JavaScript (node22, node24, web2020/2024, iweb2020/2024)

ES2015 classes, which every web target supports:

```javascript
const Shape = {                      // an interface: its defaults, and an id
  pykId: Symbol("Shape"),
  describe() { return this.name() + " of area " + pykString(this.area()); },
};

class Rect extends PykObj {
  constructor(width, height) { super(); this.width = width; this.height = height; }
  area() { return this.width * this.height; }
  name() { return "rectangle"; }
}
pykImplements(Rect, [Shape], ["width", "height"]);   // copies defaults not defined, records ids and fields

class Square extends Rect {
  constructor(side) { super(side, side); this.side = side; }
  name() { return "square"; }
}
pykImplements(Square, [], ["side"]);
```

- A class pattern is `instanceof` for classes and a check of the
  recorded interface ids for interfaces.
- `private` is checked at compile time and written with a `$p_` prefix.
  `#private` fields would also work, but they cannot be printed from
  outside the class.
- The web targets share this code. tinyweb programs can hold objects in
  their state with no change to tinyweb.

### 6.4 OCaml (ocaml4.14, ocaml5.5)

OCaml has its own object system: classes, inheritance, virtual (abstract)
methods, `method!` for overriding, `method private`, and structural
subtyping with *explicit* coercions `(e :> t)`. The upcast nodes of §4.5
are exactly where those coercions go. The one thing OCaml objects lack
is a runtime type test, needed for class patterns. Each object carries
one, as a list of itself viewed as each class it belongs to, through an
extensible variant:

```ocaml
type pyk_obj = ..

class type shape_t = object
  method area : float
  method name : string
  method describe : string
  method pyk_show : string
  method pyk_up : pyk_obj list
end
class type rect_t = object inherit shape_t method width : float method height : float end
class type square_t = object inherit rect_t method side : float end

type pyk_obj += Shape_obj of shape_t | Rect_obj of rect_t | Square_obj of square_t

class virtual shape = object (self)
  method virtual area : float
  method virtual name : string
  method describe = self#name ^ " of area " ^ Pyk.string_of_float self#area
  method virtual pyk_show : string
  method virtual pyk_up : pyk_obj list
end

class rect (width : float) (height : float) = object (self)
  inherit shape
  method width = width
  method height = height
  method area = self#width *. self#height
  method name = "rectangle"
  method pyk_show = Pyk.show_fields "Rect" [Pyk.F width; Pyk.F height]
  method pyk_up = [Rect_obj (self :> rect_t); Shape_obj (self :> shape_t)]
end

class square (side : float) = object (self)
  inherit rect side side as super
  method side = side
  method! name = "square"
  method! pyk_show = Pyk.show_fields "Square" [Pyk.F side]
  method! pyk_up = Square_obj (self :> square_t) :: super#pyk_up
end

let shapes : shape_t list =
  [ (new rect 2.0 3.0 :> shape_t); (new square 2.0 :> shape_t); (new circle 1.0 :> shape_t) ]
```

| Pyking | OCaml |
|---|---|
| `class C` | `class type c_t` (the type), then `class c` |
| field | a method returning it; a `var` field is `val mutable f` plus a `set_f` method |
| `o.f := v` | `o#set_f v` |
| `private def` | `method private` |
| `override def` | `method!` (OCaml then checks the override too) |
| `abstract` / interface signature | `method virtual`; the class is `class virtual` |
| `super.m()` | `super#m` (`inherit parent as super`) |
| upcast | `(e :> t)` |
| `case Square(side)` | `match List.find_map (function Square_obj o -> Some o \| _ -> None) s#pyk_up with Some o -> let side = o#side in ... \| None -> (next case)` |
| `a == b` with `eq` | `a#eq b` |
| `same(a, b)` | `a == b` (physical equality) |
| generic `Pair(a, b)` | `class ['a, 'b] pair` |

Class types come first, then the variant constructors, then the classes,
so the recursion between `pyk_up` and the class types resolves in one
module. An alternative representation, records of closures, is
discussed in §11.13.

### 6.5 C (c89, c99, c23, c23-gc)

C has no objects, so they are simulated the way C programs have always
done it:
- **a struct per class**, whose first member is the parent's struct
  (prefix layout), so a pointer to a `Square` is a valid pointer to a
  `Rect`;
- **a class descriptor per class**: a function table (vtable) with the
  same prefix layout, plus a pointer to the parent's descriptor for type
  tests;
- **an interface value as a fat pointer**: the object and the table of
  that class's implementation of the interface. The fat pointer is
  built at the upcast, where the checker knows the static class.

```c
/* the descriptor every class's begins with */
typedef struct pyk_class pyk_class;
struct pyk_class { const char *name; const pyk_class *parent; };

/* Rect */
typedef struct pyk_o_Dmain_Rect pyk_o_Dmain_Rect;
typedef struct pyk_vt_Dmain_Rect {
    pyk_class info;
    double (*area)(pyk_o_Dmain_Rect *self);
    pyk_str (*name)(pyk_o_Dmain_Rect *self);
} pyk_vt_Dmain_Rect;
struct pyk_o_Dmain_Rect { const pyk_vt_Dmain_Rect *vt; double width; double height; };

static double Rect_area(pyk_o_Dmain_Rect *self) { return self->width * self->height; }
static pyk_str Rect_name(pyk_o_Dmain_Rect *self) { return pyk_str_lit("rectangle"); }
static const pyk_vt_Dmain_Rect Rect_vt = { { "Rect", NULL }, Rect_area, Rect_name };

/* Square: Rect's struct first, Rect's table layout reused */
typedef struct pyk_o_Dmain_Square { pyk_o_Dmain_Rect super; double side; } pyk_o_Dmain_Square;
static pyk_str Square_name(pyk_o_Dmain_Rect *self) { return pyk_str_lit("square"); }
static const pyk_vt_Dmain_Rect Square_vt = { { "Square", &Rect_vt.info }, Rect_area, Square_name };

pyk_o_Dmain_Square *pyk_mk_Dmain_Square(double side) {
    pyk_o_Dmain_Square *o = PYK_ALLOC(sizeof *o);   /* malloc, or GC_MALLOC on c23-gc */
    o->super.vt = &Square_vt;
    o->super.width = side;  o->super.height = side; /* the parent's part first */
    o->side = side;
    return o;
}

/* Shape: an interface value is the object plus its table for Shape */
typedef struct pyk_it_Dmain_Shape {
    double (*area)(void *self);
    pyk_str (*name)(void *self);
    pyk_str (*describe)(void *self, const struct pyk_it_Dmain_Shape *it);
} pyk_it_Dmain_Shape;
typedef struct { void *self; const pyk_it_Dmain_Shape *it; } pyk_i_Dmain_Shape;

/* Rect as a Shape: entries that dispatch through Rect's own table */
static double Rect_as_Shape_area(void *s) { pyk_o_Dmain_Rect *o = s; return o->vt->area(o); }
static pyk_str Rect_as_Shape_name(void *s) { pyk_o_Dmain_Rect *o = s; return o->vt->name(o); }
static const pyk_it_Dmain_Shape Rect_as_Shape = { Rect_as_Shape_area, Rect_as_Shape_name, Shape_describe };

/* the upcast Square(2.0) : Shape, written where the checker put it */
pyk_i_Dmain_Shape s = pyk_i_Dmain_Shape_mk(pyk_mk_Dmain_Square(2.0), &Rect_as_Shape);
/* s.area() */
s.it->area(s.self);
```

| Pyking | C |
|---|---|
| object | a pointer to its struct, allocated once |
| `o.f` / `o.f := v` | `o->f` / `o->f = v`, through `super.` for an inherited field |
| `o.m(a)` on a class type | `o->vt->m(o, a)` (a direct call where nothing overrides `m`) |
| `o.m(a)` on an interface | `o.it->m(o.self, a)` |
| interface default | a function taking the fat pointer's two halves |
| upcast to a class | a pointer cast, `(pyk_o_Dmain_Rect *) sq` |
| upcast to an interface | a fat pointer built from the static class's table, as above |
| `case Square(side)` | walk `o->vt->info` up its `parent` chain looking for `&Square_vt.info`, then cast |
| generic class | one struct and table per instance, as generic datatypes are monomorphised on C today |
| `same(a, b)` | `a == b` (for interfaces, the `self` halves) |

**Memory.** Objects are heap allocated. As for `var struct`s today,
plain C (`c89`, `c99`, `c23`) `malloc`s them and never frees them, and
`c23-gc` takes them from the collector. Classes holding lists or
strings need `c23-gc`, with the usual manifest exclusion and message,
exactly as structs holding lists do. C89 has no compound literals, so a
fat pointer is made by a small generated function (`..._mk`), as above.

**Why fat pointers.** An object can implement several interfaces, so
there is no single prefix layout for them. A fat pointer is built in one
place (the upcast, whose static types are known), costs two words, and
dispatches in one indirection. The other option, a lookup of the
interface's table in the class descriptor at every call, is slower and
needs interface ids at run time. It is the fallback if fat pointers
prove awkward in generic containers (§11.14).

### 6.6 The interpreter

The interpreter represents an object as `VObject of { cls : class_info;
fields : value array }`:
- `class_info` holds the method table, resolved to slots when the
  program is loaded, plus the parent and interfaces for class patterns;
- a method call is a slot lookup;
- an upcast is the identity;
- `var` fields are written in place in the array.

The REPL and the debugger use the same values: the debugger shows an
object's fields as children in the Variables view, and `pykShow`'s text
as its value.

### 6.7 The `pyking` target

`-t pyking` prints classes back as Pyking: upcast nodes are dropped,
and `override`, `private`, defaults and annotations are kept as
written. The `pyking_rerun` check (re-running the printed program)
applies to every objects test.

### 6.8 Lean

Objects are outside the pure core `design/lean.md` formalises, as
mutation is. A module using objects is refused by `--core-json` with
the usual "outside the core" message, until a later design.

---

## 7. What is left out, and why

| Left out | Why |
|---|---|
| **Method overloading** (two `area`s with different parameters) | Python cannot express it, and Pyking's module-level overloading (`::`) already covers the need where it arises. One name, one method, also keeps error messages simple |
| **Static fields and methods** | a module-level `def` or binding does the job; Java's `static` is how Java gets module-level code at all, which Pyking already has. Generated Java puts module-level functions in static methods anyway |
| **`null`** | `Option(C)` says "maybe an object" in the type; no null pointer errors |
| **Multiple class inheritance** | Java does not have it. Interfaces with defaults give most of the benefit. Python would allow it, but its MRO is a lesson of its own |
| **`protected`, package-private** | two visibility levels (public, `private`) are enough to teach encapsulation. `protected` interacts with modules in ways Java itself gets wrong |
| **Inner and anonymous classes** | lambdas and closures already cover callbacks. An anonymous class implementing a one-method interface is a lambda |
| **Objects as `Map`/`MutMap` keys and in `Set`s** | needs a hash method kept consistent with `eq`; a later step can add `def hash(self) -> Int` with that rule checked |
| **Reflection, `getClass`, `isinstance`** | class patterns are the one, checked, way to test a type |
| **Unchecked casts** | same reason |
| **Constructors with bodies, several constructors** | header fields plus module-level factory functions; see §11.4 |
| **Properties (getters/setters that look like fields)** | a field is a field and a method is a method; a student can tell which from the call |
| **Exceptions as classes** | Pyking has no exceptions; see `steps.md`, "Later, or not at all" |
| **Operator overloading** beyond `==` and printing | `+` on objects would need ad-hoc resolution that inference does not do (§9 of `type_inference.md`) |

---

## 8. The rest of the system

Following CLAUDE.md, the feature is not done until each of these is
updated:

- **Lexer and parser** (`src/lexer.ml`, `src/parser.ml`, `src/syntax.ml`):
  - new declarations: class, interface, abstract class, members, `case
    x: C`;
  - the `use objects` gate, with the error naming the `use` line;
  - `-t pyking` printing.
- **Names and scopes** (`src/names.ml`, `src/scopes.ml`): class and
  member names; `self` and `super` only in methods; clashes between a
  class and a datatype, a function or a constructor.
- **Submodules and modules** (`src/module.ml`, `src/submodules.ml`):
  `public class`, a class imported from another module, the class table
  in the module's signature map.
- **Type checker** (`src/typesystem.ml`): class table, method calls,
  subtyping at the points of §4.4, upcast nodes, `eq`/`show`, private
  access, and the error messages of §5.
- **Exhaustiveness** (`src/exhaustive.ml`): class patterns, `case _`
  required on open types, unreachable cases after a superclass case.
- **Elaboration and passes**: `desugar_args` (method defaults and named
  arguments), `opt_tailcall` (the override check of §3.3), `prune` and
  `analyses` (unused private members are a warning: a new `-W` flag
  next to the existing unused-name warnings).
- **Every backend** (§6) and its runtime: `PykRuntime.Obj`, Python's
  `PykObj`, JS `PykObj`/`pykImplements`, OCaml's `Pyk.show_fields`,
  C's `pyk_class`.
- **The interpreter**, the **REPL** (a class typed at the prompt stays
  defined, and a redefinition replaces it as a function's does), and
  the **debugger** (DAP: objects in the Variables view, stepping into
  methods, breakpoints in methods).
- **The language server**:
  - hover shows a method's signature and its class;
  - completion after `o.` lists fields and methods, using the class
    table and the receiver's type;
  - go to definition on a method goes to its implementation in the
    static class, and "go to implementations" lists the overrides;
  - rename renames a method with its overrides;
  - document symbols show a class with its members;
  - semantic tokens mark classes, methods and fields.
- **Web tools**: the playground's highlighting, the notebook, `pyk
  serve`. Copy for slides needs the new keywords in
  `src/highlight.ml`.
- **Editor grammars**: VS Code and Emacs (the new keywords, `self` and
  `super`).
- **Help pages and documentation**:
  - `PYKING.md`: a new section "Classes and interfaces — Pyking
    extension", the `use` table's `objects` row, and the grammar;
  - `docs/type_inference.md`: a section on the class table and
    expected-type upcasts;
  - `docs/target_*.md`: the representations of §6;
  - `CHANGELOG.md`.
- **Examples**: an objects example in `src/examples.toml` (the shapes
  program), a notebook chapter on classes with tasks, and a tinyweb
  example whose game objects are classes.

---

## 9. Tests

Each phase adds, in `tests/`, run on every target in the manifest (with
`c` excluded only where a class holds a list or a string):

- **Programs**, `objects_*.pyk` with `.out`:
  - classes, fields, defaults, named arguments, body fields;
  - methods, recursion through `self`, methods as values;
  - `eq`, `show`, printing nested objects and cycles;
  - `private`;
  - generic classes;
  - interfaces and defaults, interface inheritance, diamonds resolved
    by override;
  - class inheritance, `super`, dispatch from a parent's method;
  - abstract classes;
  - every upcast point of §4.4;
  - class patterns in every position;
  - `var` fields with `use mutation`, aliasing and `same`;
  - objects in lists, tuples, datatypes, and in a `loop`'s accumulator;
  - tail calls in private methods.
- **`.ast.out`** for each, and `also = ["pyking_rerun"]` so the printed
  program round-trips.
- **Error cases**, `fail_typecheck_objects_*.pyk` and
  `fail_parse_objects_*.pyk`: every message of §5, the `use` gate for
  `class`, `interface`, `var` fields and field writes, a private access
  from another class and from a subclass, a missing override marker,
  an override that changes a type, an unannotated method parameter,
  making an interface or an abstract class, a body field using `self`,
  a field hiding a field, a field named like a method.
- **A Java/Python agreement check**: a test that compiles every
  objects program for java21 and python14 and compares the outputs. The
  manifest already does this by sharing one `.out`, but a dedicated
  diamond-and-defaults program guards §6.2's safety net.
- **LSP**: `tests/lsp/objects.lsp` (hover, completion after `.`,
  definition, rename of a method with overrides, symbols).
- **DAP**: stepping into a method, an object in the Variables view.
- **REPL**: a class across several inputs.
- **Playground and highlight**: the new keywords are coloured.
- **Notebook**: the classes chapter's tasks verify in `nbverify`.

---

## 10. Phases

Each phase is usable on its own, compiles on every target, and has its
documentation and tests before the next starts.

| Phase | Adds | Why this order |
|---|---|---|
| **1. Classes** | `class` with header and body fields, methods, `self`, `private`, `eq`, `show`, printing, `var` fields (with `use mutation`), generic classes, `case C(...)` on a class, methods as values | encapsulation alone is already useful: a `Vec`, an `Account`, a `Stack`. No subtyping yet, so inference is untouched apart from method calls |
| **2. Interfaces** | `interface`, `implements`, defaults, interface inheritance, upcasts at the points of §4.4, `case x: C`, `case _` rules for open types | introduces subtyping, and with it the upcast node, while there is still only one kind of supertype |
| **3. Inheritance** | `extends C(args)`, `override`, `super`, `abstract class`/`def`, dispatch from a parent's method, Java `final` for unextended classes | builds on the upcast machinery of phase 2; adds the parts with the most rules (override checking, construction order) |
| **4. Tooling polish** | LSP implementations/rename across overrides, DAP object views, notebook chapter, tinyweb example | needs the whole feature to be stable |

Rough size: phase 1 is about as large as structs plus `var struct`
were; phase 2 is mostly the checker and the C and OCaml backends; phase
3 is mostly the checker.

---

## 11. Design alternatives

Each subsection lists the options, with pros and cons, and the
recommendation (**Recommended**), which is what the rest of this
document assumes.

### 11.1 How fields and the constructor are declared

| Option | Example | Pros | Cons |
|---|---|---|---|
| **A. Header fields, like `struct` (Recommended)** | `class Rect(width: Float, height: Float):` | the same as struct, so already learned; no constructor boilerplate; Java records and Kotlin work this way; printing and patterns follow from the header | a constructor with logic needs a factory function |
| B. Python `__init__` | `def __init__(self, w: Float): self.width = w` | familiar to Python users | fields are discovered from assignments, which the checker would have to analyse; boilerplate; easy to forget a field |
| C. Java-style fields plus a constructor | `width: Float` … `init(self, w: Float): self.width = w` | close to Java | most boilerplate; needs "definitely assigned" checking, so every field is set exactly once |

A keeps Pyking's existing story ("a class is a struct with methods")
and is the least to write. Body fields (§3.2) cover the cases where a
field is not a parameter.

### 11.2 `self` explicit or implicit

| Option | Pros | Cons |
|---|---|---|
| **A. Explicit `self` parameter, `self.x` required (Recommended)** | Python's spelling; a reader always knows what is a field; no shadowing between fields and locals | more to type; Java writes `this` and lets it be implied |
| B. Implicit `this`, bare `x` reaches the field | Java's spelling; shorter | a local and a field can shadow each other; the generated Python would need `self.` added everywhere, so the two outputs read differently |
| C. Explicit `self`, written `this` | Java's word | Python users expect `self`; `self` is reserved already |

### 11.3 Must methods be annotated?

| Option | Pros | Cons |
|---|---|---|
| **A. Every parameter (except `self`) and the return type annotated (Recommended)** | the class table needs no inference; overriding is checked by comparing written types; errors are local; mutual recursion between methods is free | more to write than a plain `def` |
| B. Infer methods like defs, check overrides afterwards | less to write | mutually recursive methods across classes need fixpoints; an override's type depends on inference order; dynamic dispatch needs the types of *all* overrides before any call is typed |
| C. Annotate only methods that override or are overridden | a compromise | hard to explain which is which; adding a subclass would suddenly require annotations in the parent |

The task statement allows A, and it is what makes everything else
simple.

### 11.4 Constructor logic

| Option | Pros | Cons |
|---|---|---|
| **A. None: header and body fields only, factory functions for logic (Recommended, phase 1–3)** | no partially built objects; trivial to translate | validation lives outside the class |
| B. An `init:` block run after the fields are set, which may check and fail but not use `self`'s methods | validation inside the class | one more construct; Java and Python order must be matched exactly |
| C. Full constructors, several per class | Java-complete | overloading (§7), definite assignment, and calling overridable methods from constructors all come back |

B is a natural later addition, if courses ask for it.

### 11.5 What `==` means on objects

| Option | Pros | Cons |
|---|---|---|
| **A. Calls `eq`; refused without it; `same` for identity (Recommended)** | `==` keeps meaning "equal values" everywhere in Pyking; no Java `==` vs `equals` trap; Python's `__eq__` matches | unlike Java's `==` |
| B. Identity, as Java's `==` | closest to Java | `==` would mean value equality for structs and identity for objects, so changing a struct into a class silently changes results; the most common Java beginner bug |
| C. Structural, field by field, automatically | no code to write | wrong for mutable objects (two accounts with equal balances are not "the same account"), and differs from both Java and Python defaults |

### 11.6 Method calls on a value whose type is not yet known

| Option | Pros | Cons |
|---|---|---|
| **A. Refused, "annotate it", as for field reads today (Recommended)** | one rule for fields and methods; the message says exactly what to do; no new inference machinery | `def f(s): s.area()` needs `s: Shape` |
| B. Deferred to the first call, like §9b's indexed parameters: the demand "has a method `area`" waits until a call fixes the class | less to annotate | the first call fixes *one* class, so `f(Rect(...))` then `f(Circle(...))` is refused, which is surprising when both have `area`; should then also apply to fields, a separate change |
| C. Structural (row) types: `s` is "anything with `area`" | most flexible | not Java's semantics (nominal); poor error messages; hard to compile to Java and C |

B could later be done for fields and methods together, if A proves
annoying in practice.

### 11.7 Variance of lists and other generics

| Option | Pros | Cons |
|---|---|---|
| **A. Invariant: `[Square]` is not `[Shape]` (Recommended)** | Java's rule for `List`; nothing to explain about variance; keeps unification as it is | a `[Square]` must be built as a `[Shape]` where needed (annotate the literal) |
| B. Covariant for immutable lists, tuples and `Option` | sound, since they never change; more programs type-check | Java needs `List<? extends Shape>` or a cast in the output; the rule for arrays and DynArrays (must stay invariant, being writable) differs, which is one more thing to learn |
| C. An explicit conversion, `upcast_list(xs)` / `[s for s in xs]` with an annotation | explicit | boilerplate, though the comprehension form works today with A |

### 11.8 Overriding rules

| Option | Pros | Cons |
|---|---|---|
| **A. `override` required whenever a supertype has the method; identical signature (Recommended)** | catches misspellings and accidental overrides both ways; one rule for implementing an interface method and replacing a parent's; matches Kotlin, C#, and OCaml's `method!` | more to write than Java, where `@Override` is optional |
| B. `override` optional, as `@Override` in Java | less to write | a misspelled override silently adds a new method |
| C. Covariant return types allowed in overrides | Java allows them | needs subtyping in the override check and casts in some backends; rarely needed in teaching |

### 11.9 Closed hierarchies (`sealed`)

| Option | Pros | Cons |
|---|---|---|
| **A. None: use `datatype` for closed sets, classes for open ones (Recommended)** | one way to say "exactly these cases"; datatypes already have exhaustive matching | classes cannot be matched exhaustively |
| B. `sealed interface I permits A, B` as in Java 17 | exhaustive `match` on classes | duplicates datatypes; Java 8 has no `sealed`, so it would be checked only by Pyking |

### 11.10 A `final` keyword

| Option | Pros | Cons |
|---|---|---|
| **A. No keyword; the compiler marks unextended classes `final` in Java (Recommended)** | nothing to learn; the generated Java is still idiomatic | a library cannot forbid extension by others |
| B. `final class` / `final def` | Java's control | one more keyword and rule, rarely needed in a course |

### 11.11 Ordering objects

| Option | Pros | Cons |
|---|---|---|
| **A. Not in this plan (Recommended)** | small | `sort` on a list of objects needs a key function, `sort_by(lam a. a.age, xs)` |
| B. `def compare(self, other: C) -> Int` enables `<`, `<=`, `sort` | Java's `Comparable`, Python's `__lt__` | the same ad-hoc resolution as `eq`, a second reserved method; worth it if courses sort objects often |

### 11.12 Methods with type variables of their own

| Option | Pros | Cons |
|---|---|---|
| **A. Not allowed; a method uses only its class's variables (Recommended)** | C monomorphisation stays per class; OCaml needs no explicit polymorphic method types; overriding a generic method needs no rules | `def map(self, f: (a) -> b) -> Box(b)` must be a module-level `def map(box: Box(a), f: (a) -> b) -> Box(b)` |
| B. Allowed on non-overridable (private, or class not extended) methods only | covers `map` on a final class | the restriction depends on the rest of the program |
| C. Allowed everywhere | Java-complete | C cannot put an unboundedly generic method in a vtable (it would need dictionary passing); OCaml needs `method m : 'b. ...` annotations; override checking under quantifiers |

### 11.13 OCaml representation

| Option | Pros | Cons |
|---|---|---|
| **A. OCaml objects and classes (Recommended)** | the output reads as OCaml OOP; `method!`, `virtual`, `private` and `:>` map one to one; the upcast nodes say where `:>` goes | needs the `pyk_up` list for class patterns; OCaml object types are structural, so the generated class types must be written out to keep messages and casts nominal |
| B. Records of closures (explicit vtables, as on C) | one lowering shared with C and the interpreter; no OCaml object system subtleties | the output is not recognisable as OOP; inheritance is manual copying of records |
| C. First-class modules | idiomatic for some OCaml programmers | poor fit for dynamic dispatch on values in lists |

### 11.14 C representation of interface values

| Option | Pros | Cons |
|---|---|---|
| **A. Fat pointer (object + interface table), built at the upcast (Recommended)** | one indirection per call; no run-time search; the upcast node gives the static class | interface values are two words, so a list of `Shape` holds pairs; generic containers must store them by value |
| B. Thin pointer; the class descriptor holds a list of (interface id, table) pairs, searched at each call | every object reference is one pointer | a search per interface call; interface ids needed at run time |
| C. Refuse interfaces on plain C, as the old plan did | less work | breaks the "every target" requirement |

### 11.15 Where objects are lowered

| Option | Pros | Cons |
|---|---|---|
| **A. Native classes in Java, Python, JavaScript and OCaml; structs and tables in C; a resolved method table in the interpreter (Recommended)** | readable, idiomatic output on the targets students read (Java and Python), which is a stated goal | each backend has real work |
| B. Lower everything in the front end to datatypes plus records of closures | one implementation; backends almost untouched | the generated Java and Python would not contain classes at all, which defeats the purpose of teaching OOP through them |

### 11.16 Declaring objects in a module without `use objects`

| Option | Pros | Cons |
|---|---|---|
| **A. Only declaring needs `use objects`; using needs nothing (Recommended)** | a functional module can use a library's classes; matches `var struct` (holding needs nothing) | a module can call methods without saying "objects" |
| B. Every method call and class pattern needs `use objects` too | a module's `use` lines say everything it does | a library written with objects forces its users to turn objects on |

### 11.17 Generic syntax for interfaces and classes without header fields

| Option | Example | Pros | Cons |
|---|---|---|---|
| **A. Parentheses after the name, as struct type parameters today (Recommended)** | `class Stack(a):`, `interface Source(a):` | the existing struct rule | `class Stack(a):` reads like a header field named `a`; told apart because `a` has no type and is a type variable |
| B. Brackets | `class Stack[a]:` | Python 3.12's own syntax, unambiguous | a second spelling for type parameters in Pyking, whose types are written `Box(Int)` |

---

## 12. Relation to design/steps.md

Steps 12 and 13 of `design/steps.md` sketched objects before several
pieces existed. This plan keeps their direction and changes these
points:

| steps.md said | This plan | Why |
|---|---|---|
| fields immutable; a "changed" object is a new one | same, plus `var` fields with `use mutation` from phase 1 | `var struct` now exists and already defines writable fields and identity |
| `==` refused unless `eq` | same | — |
| privacy by a leading `_` | `private` keyword | Java's word, checked, and maps to Python's `__name`; `_` is an ordinary identifier character in Pyking |
| `extends` for interfaces and classes alike | `implements` for interfaces, `extends` for the one parent class | Java's distinction; makes "one class, many interfaces" visible in the header |
| `override` "open, proposed required" | required (§11.8) | — |
| objects with no `var` field "stay values, and backends may copy them" | every object is a reference | Java and Python semantics; copying would make `same` target-dependent |
| subtyping only where a type is expected | same, made precise as the points of §4.4 and the upcast node of §4.5 | — |
| OCaml representation open | OCaml objects (§11.13) | — |
| C refused for inheritance | C supported with prefix layout, vtables and fat pointers | the requirement that every target supports it |

When this plan is adopted, steps 12 and 13 in `design/steps.md` should
be shortened to a pointer to this file, and the summary table's last
rows updated to name `implements`, `override`, `abstract` and `private`.
