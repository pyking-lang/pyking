# Constructors, destructors and immutable objects

This note answers four questions about classes in Pyking (`use
objects`):

1. Can a class have several constructors, taking different parameters?
2. Can a constructor run code?
3. Can a class have a destructor?
4. Can a constructor be private, so that a class makes objects that
   never change and are always valid?

Each answer comes with a small complete program. Every program here was
run with the interpreter and compiled for Python, Node, Java, C (`c-gc`
where a list is used) and OCaml, and gave the same output on each. The
last part says what is missing and proposes what to add.

The rules referred to are in `PYKING.md`, "Classes and interfaces" and
"Classes across modules", and the reasons for them in
`design/plan-objects.md` (§3.2, §7 and §11.4).

---

## 1. Several constructors

**Today: one constructor per class, its header.** A class's header
lists its fields, and those fields are its constructor's parameters,
as for a struct. A class can't declare a second constructor, and two
classes of one name are refused (`'P' is already declared`). Methods
can't be overloaded either: `def a::make(self, ...)` inside a class is
refused, since `::` names belong to module-level `def`s.

### 1a. Defaults and named arguments cover many cases

Most of what Java does with several constructors (`Rect(w)`,
`Rect(w, h)`, `Rect(w, h, label)`) is done by defaults and named
arguments:

```pyking
use objects

class Rect(width: Float, height: Float = 1.0, label: String = "rect"):
    area: Float = width * height
    def show(self) -> String:
        self.label + " " + string(self.width) + "x" + string(self.height) + " = " + string(self.area)

print(Rect(2.0, 3.0))
print(Rect(4.0))
print(Rect(2.0, label = "strip"))
print(Rect(height = 5.0, width = 1.0))
```

prints

```
rect 2.0x3.0 = 6.0
rect 4.0x1.0 = 4.0
strip 2.0x1.0 = 2.0
rect 1.0x5.0 = 5.0
```

### 1b. Different parameters: factory functions

When the ways of making an object take *different kinds* of input
(cartesian or polar coordinates, or a string to parse), the idiom is a
module-level function per way. Pyking's static overloading (`::`)
lets them share one name. A call is resolved by the argument types, so
`point("3.5,4.5")` finds `text::point` without the qualifier. Two
overloads with the same parameter types, like `cartesian::point` and
`polar::point` (both two Floats), can only be called with the
qualifier, which reads like a named constructor:

```pyking
use objects
import math
import text

class Point(x: Float, y: Float):
    def show(self) -> String:
        "(" + string(self.x) + ", " + string(self.y) + ")"

def cartesian::point(x: Float, y: Float) -> Point:
    Point(x, y)

def polar::point(r: Float, angle: Float) -> Point:
    Point(r * math.cos(angle), r * math.sin(angle))

def text::point(s: String) -> Point:
    match text.split(s, ","):
        case [a, b]: Point(float(a), float(b))
        case _: panic("not a point: " + s)

def origin() -> Point:
    Point(0.0, 0.0)

print(cartesian::point(1.0, 2.0))
print(polar::point(2.0, 0.0))
print(point("3.5,4.5"))
print(origin())
```

prints `(1.0, 2.0)`, `(2.0, 0.0)`, `(3.5, 4.5)` and `(0.0, 0.0)`.

### 1c. A changed copy: the update form

The struct update form also works on objects:
`Person(age = 37, ..ada)` makes a new `Person` with `ada`'s fields
except `age`. It goes through the constructor, so the checks of §2
run again. It also respects `private`: outside the class,
`Acc(balance = 1000000, ..a)` is refused with
`'balance' is private to 'Acc'`.

**What you can't do:** declare `Point(s: String)` beside
`Point(x: Float, y: Float)`. And you can't make a factory the only way
in, because the header constructor is always there too (see §4).

---

## 2. Code in constructors

**Today: no constructor body, but field initialisers can call any
function.** The class body may declare fields with initialisers,
`name: T = e`. An initialiser can use the header's parameters and
module-level names, can't use `self`, and runs in a fixed order: the
parent's part, then the header fields, then the body fields in the
order written. A function called there may check its argument and stop
the program with `panic`. That is how validation and normalisation are
written today:

```pyking
use objects
import text

def checked_percent(p: Int) -> Int:
    if p < 0 or p > 100:
        panic("a percent is between 0 and 100, not " + string(p))
    p

def clean(s: String) -> String:
    text.trim(s)

class Grade(name: String, percent: Int):
    who: String = clean(name)
    valid: Int = checked_percent(percent)
    letter: String = if percent >= 90 then "A" else if percent >= 50 then "C" else "F"
    def show(self) -> String:
        self.who + ": " + self.letter

print(Grade("  ada ", 95))
print(Grade("bo", 60))
print(Grade("cy", 120))
```

prints `ada: A` and `bo: C`, then stops with the runtime error `a
percent is between 0 and 100, not 120`.

It works, but it is clumsy:

- **A check has to be stored in a field** (`valid`) just to run.
- **A header field can't be normalised.** `name` keeps the untrimmed
  string, so a second field `who` holds the clean one, and both are
  visible.
- **Only `panic` can say no.** There are no exceptions. A constructor
  can't answer "no object" in a way the caller handles.
- **Statements aren't allowed in a class body.** `print("made")` there
  is a parse error. Each piece of code has to be an expression that
  produces a field.

### 2b. Failing gracefully: a factory answering `Result`

To let the caller handle bad input, put the check in a function that
answers a `Result`:

```pyking
use objects

class Temperature(kelvin: Float):
    def celsius(self) -> Float:
        self.kelvin - 273.15

def temperature(k: Float) -> Result(Temperature, String):
    if k < 0.0:
        Error("below absolute zero: " + string(k))
    else:
        Ok(Temperature(k))

for k in [300.0, -5.0]:
    match temperature(k):
        case Ok(t): print("ok", t.celsius())
        case Error(m): print("refused:", m)

print(Temperature(-5.0).celsius())
```

prints `ok 26.850000000000023`, `refused: below absolute zero: -5.0`,
and then `-278.15`.

That last line is the problem: **nothing stops a caller from going
around the factory** and making `Temperature(-5.0)` directly. Within a
module that can't be prevented today. §4 shows the closest
approximation across modules.

---

## 3. Destructors

**Today: none, and by design.** Objects are garbage-collected on every
target except plain C (where a class's objects are never freed; `c-gc`
collects them). Nothing runs when an object becomes unreachable. Java,
Python, JavaScript and OCaml don't promise *when* (or *whether*) a
finaliser runs, so a Pyking destructor couldn't give the same output
on each target.

**A finding while writing this note: `__del__` leaks through on
Python.** A method named `__del__` is accepted as an ordinary method:

```pyking
use objects

class P(x: Int):
    def __del__(self) -> ():
        print("bye")

p = P(1)
print(p.x)
```

The interpreter, Node, Java, C and OCaml print `1`. **Python prints `1`
and then `bye`**, because the generated class binds the method as
`__del__`, which CPython runs as a finaliser. Other Python special
names (`__eq__`, `__hash__`, `__len__`, `__repr__`, ...) probably have
the same problem, since the generated class binds them under the name
written. That breaks the rule that every target gives the same output.
§5.6 proposes a fix.

For resources (files, sockets), the idiom is explicit: open, use,
close. lib/fs, for one, reads and writes a whole file in one call, so
there is nothing left open.

---

## 4. Private constructors and immutable objects

### 4a. Immutable objects: the default

**An object whose fields aren't `var` never changes.** Fields are
immutable unless written `var`, and `var` needs `use mutation`.
Writing a non-`var` field is refused even under `use mutation` (`the
field 'x' of 'P' never changes, so it is not written with ':=';
declare it 'var x'`). Without `use mutation`, `:=` isn't allowed at
all. So the classic immutable value class is the plain one. Its
"setters" are methods answering a new object (the update form of §1c
does the same):

```pyking
use objects

class Person(name: String, age: Int, emails: [String] = []):
    def with_age(self, age: Int) -> Person:
        Person(self.name, age, self.emails)
    def with_email(self, e: String) -> Person:
        Person(self.name, self.age, self.emails + [e])
    def eq(self, other: Person) -> Bool:
        self.name == other.name and self.age == other.age and self.emails == other.emails

ada = Person("Ada", 36)
older = ada.with_age(37).with_email("ada@example.org")
print(ada)
print(older)
print(ada == Person("Ada", 36), same(ada, older))
```

prints

```
Person("Ada", 36, [])
Person("Ada", 37, ["ada@example.org"])
true false
```

`ada` is unchanged. Since `Person` can't change, sharing it is safe,
and `copy`/`deepcopy` of it are never needed.

### 4b. But immutability is shallow

A field that can't be reassigned may still hold something mutable. An
`Array`, a `DynArray`, a `MutMap`, a `mutable struct` or an object
with `var` fields can be changed in place by anyone holding the
object:

```pyking
use objects, mutation

class Team(name: String, scores: Array(Int))

t = Team("red", array([1, 2, 3]))
t.scores[0] := 99
print(t.scores)

class SafeTeam(name: String, private scores: Array(Int)):
    def score(self, i: Int) -> Int:
        self.scores[i]

def safe_team(name: String, scores: [Int]) -> SafeTeam:
    SafeTeam(name, array(scores))

s = safe_team("blue", [1, 2, 3])
print(s.score(0))
```

prints `array([99, 2, 3])` and `1`. Making the field `private` and
exposing only reads protects it from outside. But a caller who calls
`SafeTeam("x", arr)` directly keeps `arr` and can still change it.
Only a factory that copies (here `array(scores)`), and *being the only
way in*, makes the object truly immutable. Nothing in the language
says so or checks it: Pyking has no "deeply immutable" class.

### 4c. A private constructor, emulated across modules

**There is no private constructor today.** A `public class` exports
its constructor (plan-copy-public-classes.md, choice C1 A), and inside
a module every class's constructor can be called. But one combination
of what exists gets close: **a public interface, a class that isn't
public, and public factory functions.** The class's name, and so its
constructor, can't be reached from another module:

```pyking
# money.pyk
use objects

# The interface is public; the class is not, so no other module can
# call its constructor. The only way in is the checked function.
public interface Money:
    def cents(self) -> Int
    def plus(self, other: Money) -> Money
    def times(self, k: Int) -> Money

class Cents(private amount: Int) implements Money:
    override def cents(self) -> Int:
        self.amount
    override def plus(self, other: Money) -> Money:
        Cents(self.amount + other.cents())
    override def times(self, k: Int) -> Money:
        Cents(self.amount * k)
    def show(self) -> String:
        string(self.amount / 100) + "." + string(self.amount % 100 / 10) + string(self.amount % 10) + " kr"

public def money(kronor: Int, ore: Int = 0) -> Result(Money, String):
    if kronor < 0 or ore < 0 or ore > 99:
        return Error("not an amount: " + string(kronor) + ":" + string(ore))
    m: Money = Cents(kronor * 100 + ore)
    Ok(m)

public def zero() -> Money:
    Cents(0)
```

```pyking
# main.pyk
import money
import result

price = result.unwrap(money.money(12, 50))
total = price.times(3).plus(money.zero())
print(price, total, total.cents())
print(money.money(5, 120))
```

prints

```
12.50 kr 37.50 kr 3750
Error("not an amount: 5:120")
```

and `money.Cents(5)` in another module is refused (`unknown
constructor 'money.Cents'`). Printing a `Money` still calls `Cents`'s
`show`, since dispatch is dynamic.

This is a workaround, and it has four holes:

1. **Callers only see the interface.** A field can't be read; it has
   to be a method (`cents()`). Another module can't name `Cents` in a
   class pattern either.
2. **The interface is open.** Any module may implement it, so a forged
   `Money` gets past every check:

   ```pyking
   use objects
   import money
   class Fake(n: Int) implements money.Money:
       override def cents(self) -> Int: -self.n
       override def plus(self, other: money.Money) -> money.Money: self
       override def times(self, k: Int) -> money.Money: self
   print(Fake(5).cents())      # -5
   ```

3. **Inside `money.pyk`, nothing is private.** Every function in the
   module can still call `Cents(-1)`.
4. **A friction:** an upcast isn't made inside a constructor's
   argument. `Ok(Cents(...))` in a function returning
   `Result(Money, String)` is refused (`its body ends in a value of
   type Result(Cents, String)`), hence the annotated `m: Money` line.
   This follows the documented rule (upcasts are made only where a
   type is written: an annotation, a parameter, a field, or a list,
   tuple or `if` there). But it is the first thing anyone writing a
   factory with `Result` or `Option` will meet.

---

## Summary: today

| Question | Today | How it is written instead |
|---|---|---|
| Several constructors | no, one per class (its header) | defaults and named arguments; factory functions, overloaded with `::`; the update form `C(f = v, ..o)` |
| Code in a constructor | no body; body-field initialisers may call any function (`self` not allowed) | a checking function called from a field initialiser, `panic` to refuse; or a factory answering `Result` |
| Destructors | no; objects are garbage-collected | explicit open/use/close; (Python wrongly runs a method named `__del__`) |
| Immutable objects | yes, by default: fields without `var` never change | methods or the update form answering a new object |
| Deep immutability | not checked; a field may hold an `Array` | `private` field plus a copying factory, by convention |
| Private constructor | no | public interface + non-public class + public factory, with the holes listed in §4c |
| Forbid implementing or extending | no `sealed`/`final` | a `datatype`, when the set of cases is closed |

---

## 5. What is missing, and a proposal

The proposals are ordered by value for the effort. Each fits the
existing design (no partially built objects, the same output on every
target, Python's look), and none breaks a program that works today.

### 5.1 Private constructors: `private` on the header

*(See §6 for a smaller proposal, `private` on a single constructor
parameter, which covers the commonest case and is now recommended
first.)*

```pyking
use objects

public class Money private (cents: Int):
    def plus(self, other: Money) -> Money:
        Money(self.cents + other.cents)

public def money(kronor: Int, ore: Int = 0) -> Result(Money, String):
    if kronor < 0 or ore < 0 or ore > 99 then Error("not an amount")
    else Ok(Money(kronor * 100 + ore))
```

- **Meaning:** the constructor can only be called within the module
  declaring the class: in its methods and in the module's functions.
  The class, its fields and its methods are still exported. Choice C1
  C in plan-copy-public-classes.md was explicitly left open for this.
- **Consequences, checked by the compiler:**
  - Another module can't call `Money(...)` or use it as a function
    value.
  - It can't use the update form `Money(cents = 5, ..m)`, which calls
    the constructor.
  - It can't `extends Money(...)`, since that calls the constructor too.
    So a private constructor also makes the class final outside its
    module, which is what Java programmers expect.
  - Class patterns (`case Money(c)`) and field reads still work: they
    read, they don't make.
- **Why module-private rather than class-private:** Pyking has no
  static methods. A factory is a module-level function, so the module
  is the unit that may construct. This is Kotlin's `private
  constructor` with Pyking's module as the scope.
- **Targets:**
  - **Java:** a package-private constructor, or a private one if the
    factory functions are generated in the same outer class (they
    are).
  - **Python, JavaScript:** nothing to enforce at run time; the
    checker enforces it, as `private` already is.
  - **C, OCaml:** the constructor function isn't exported (not in the
    `.h` or the `.mli`).
- **Messages:** "'Money' is made only in module 'money': its
  constructor is private; use 'money.money(...)'", naming the public
  functions that answer a `Money` if there are any.
- **Cost:** small. The parser accepts `private` before the header, the
  checker adds one flag to `class_info` and refuses the constructor in
  the cases above, and C and OCaml skip one export. The LSP needs to
  hide the constructor in completion, and the docs need it in "Classes
  across modules".

### 5.2 An `init:` block for validation (plan-objects.md §11.4 B)

```pyking
use objects

class Grade(name: String, percent: Int):
    init:
        require(0 <= percent and percent <= 100, "a percent is 0..100")
    letter: String = if percent >= 90 then "A" else "F"
```

- **Meaning:** one optional block per class, run after the header
  fields are set and before the body fields, with the same rules as an
  initialiser: header parameters and module names, no `self`. It may
  contain statements (`if`, `panic`, local bindings), so a check no
  longer needs a dummy field.
- **What stays the same:** no partially built object is visible, and
  the order (parent, header, `init:`, body fields) is fixed and the
  same on every target. Python's `__init__`, Java's constructor and
  C's and OCaml's make functions already run in that order. The block
  goes in one place among them.
- **A small addition worth making with it:** `require(cond, message)`,
  which is `if not cond then panic(message)`, also useful outside
  classes.
- **Normalising a header field** (the trimmed `name` of §2) would need
  `init:` to rebind a header parameter (`name = text.trim(name)`
  before the field is set). That gives a parameter two values. I
  propose *not* to allow it. Normalising is the job of a factory with
  a private constructor (§5.1), which keeps the rule that a header
  field is what was passed.

### 5.3 Several constructors: don't add them; name the idiom

I recommend **not** adding overloaded constructors (plan-objects.md §7
decided the same, and the reasons hold):

- Python can't express them, so the generated Python would need a
  dispatch it doesn't have.
- Static overloading by argument types already exists (`::`).
- Defaults and named arguments cover the common cases.

With §5.1, "factories plus a private constructor" becomes the one
complete answer: every way of making an object is a named, checked,
overloadable function, and the class can't be made any other way.
PYKING.md's "Classes and interfaces" should show the idiom (§1b and
§5.1 here) where it describes the constructor, so a Java programmer
finds it where they look.

### 5.4 Closing a hierarchy: `sealed` for interfaces across modules

Hole 2 of §4c (a forged `Money`) remains even with §5.1 if the type
handed out is an interface. plan-objects.md §11.9 recommended no
`sealed`, because a `datatype` already says "exactly these cases". For
immutable value types that need methods and hidden representations,
a smaller rule is enough:

- `public sealed interface Money:` may be implemented, and a `public
  sealed class` extended, **only in the module declaring it**.
- `match` on a sealed type is then exhaustive over its classes, which
  the exhaustiveness checker can do with the class table it already
  has (exhaustive.ml, `?classes`).
- In Java 17+ it compiles to `sealed ... permits ...`. On Java 8 and
  the other targets, only the checker enforces it.

With §5.1 the common case (one class) needs no `sealed` at all, so
this is second priority.

### 5.5 Checked deep immutability: `immutable class`

```pyking
use objects

immutable class Person(name: String, age: Int, emails: [String] = [])
```

- **Meaning:** the compiler checks that no field of this class or any
  class it extends is `var`, and that no field's type can change in
  place:
  - not an `Array`, `DynArray`, `MutMap` or `mutable struct`;
  - not a pointer;
  - not a class or interface that isn't itself `immutable`.
  The check is recursive through datatypes and structs.
  `copy_obstacle` in typesystem.ml already walks types this way for
  pointers and type variables, so it is the model.
- **What it buys:**
  - The property of §4b is guaranteed instead of a convention.
  - `copy` and `deepcopy` of such an object can return it unchanged,
    and the compiler can warn that the call does nothing.
  - An `immutable interface` can be implemented only by `immutable`
    classes. That gives values of an interface type the same promise.
  - Later, a structural `eq` and a `hash` (plan-objects.md §7, "objects
    as Map keys") are only sound for such classes. `immutable` is the
    natural gate for deriving them, so `Person` could be a `Map` key.
- **Cost:** moderate, and all in the checker. No backend changes.

### 5.6 Fix: Python special names (a bug, independent of the rest)

A method named `__del__` runs as a finaliser on Python only (§3), and
other dunder names may change Python's behaviour the same way. Either:

- **A.** Refuse method names that begin and end with `__` (simple;
  Pyking has its own `eq` and `show`), or
- **B.** Mangle them in the Python (and JavaScript) backends, as
  keywords already are.

I recommend A: the names mean nothing in Pyking, so refusing them with
a message ("'__del__' is a Python special name; Pyking calls no
method when an object is collected") also answers the question a
student was really asking. It needs a `fail_*` test and a sentence in
PYKING.md.

### 5.7 Upcasts into constructor arguments (a friction)

`Ok(Cents(...))` where `Result(Money, String)` is expected is refused
(§4c, hole 4). The checker already makes upcasts inside lists, tuples
and `if` where the type is written. Extending that to a datatype
constructor's arguments, when the expected datatype's type arguments
are known, removes the annotated binding every factory needs today.
It follows the same rule, "only where the type is written down", so
inference doesn't change in kind.

### 5.8 Destructors: still no

Garbage collection doesn't run finalisers deterministically on Python,
Java, JavaScript or OCaml, so a destructor would break same output on
every target. If resource handling is needed later, a scoped form
(`with open(...) as f:`, closing at the end of the block) gives
deterministic clean-up without tying it to object lifetime. That
belongs with lib/fs, not with classes.

### Order of work

| Step | Proposal | Size |
|---|---|---|
| 1 | §5.6 refuse dunder method names | small |
| 2 | §6 `private` constructor parameters (recommended) | small |
| 2b | §5.1 private constructors, if module-level factories that validate arguments are still wanted | small |
| 3 | §5.7 upcasts into constructor arguments | small to moderate |
| 4 | §5.2 `init:` block and `require` | moderate |
| 5 | §5.5 `immutable class` | moderate |
| 6 | §5.4 `sealed` | moderate; may be unnecessary after 2 |
| — | §5.3 overloaded constructors, §5.8 destructors | not proposed |

Each step reaches the whole system as CLAUDE.md asks: the parser and
checker, every backend where code changes, the LSP's completion and
hover, the editor grammars for a new keyword (`init`, `immutable`,
`sealed`), PYKING.md, the site's tour, and tests on every target with
`fail_*` cases for each refusal.


---

## 6. An immutable `StudentGroup`, and `private` constructor parameters

### 6.1 The task

A class `StudentGroup` that:

- keeps a list of students inside, as tuples `(name, age)`;
- is made empty, with `StudentGroup()`;
- has public methods `add_student(name, age)`, `delete_student(name)`,
  `list_students()` (the names), `age_of_student(name)` and so on;
- is completely immutable: a method that "changes" the group answers a
  new `StudentGroup` and leaves the old one as it was;
- keeps its own promises (here, that no name occurs twice and no age is
  negative), which only holds if nobody can build a group except
  through its methods.

It uses no interface: one class, used directly.

### 6.2 Can it be written today?

**The class can be written today, and runs the same on every target. Its
promises can't be kept.** The program below is the whole example.
`private students` in the header is accepted by today's compiler. It
makes `students` a private field with a default, so `StudentGroup()`
makes an empty group, and the methods make new groups by calling
`StudentGroup(...)` with a new list.

```pyking
use objects

# An immutable group of students, each a name and an age. Two
# promises hold for every group: no name occurs twice, and no age is
# negative. Every method that "changes" the group answers a new one.
class StudentGroup(private students: [(String, Int)] = []):

    # The group with `name` added, or with its age replaced if the
    # name is there already.
    def add_student(self, name: String, age: Int) -> StudentGroup:
        if age < 0:
            panic("an age is never negative: " + name + ", " + string(age))
        StudentGroup(self.without(name) + [(name, age)])

    # The group without `name`; the same students if it is not there.
    def delete_student(self, name: String) -> StudentGroup:
        StudentGroup(self.without(name))

    # The names, in the order they were added.
    def list_students(self) -> [String]:
        [n for (n, _) in self.students]

    def age_of_student(self, name: String) -> Option(Int):
        match [a for (n, a) in self.students if n == name]:
            case [a, ..]: Some(a)
            case []: None

    def size(self) -> Int:
        len(self.students)

    def eq(self, other: StudentGroup) -> Bool:
        self.students == other.students

    def show(self) -> String:
        "StudentGroup of " + string(self.size()) + ": " + string(self.list_students())

    private def without(self, name: String) -> [(String, Int)]:
        [(n, a) for (n, a) in self.students if n != name]

empty = StudentGroup()
g1 = empty.add_student("Ada", 36).add_student("Bo", 21).add_student("Cy", 19)
g2 = g1.delete_student("Bo").add_student("Ada", 37)

print(empty)
print(g1)
print(g2)
print(g1.age_of_student("Ada"), g2.age_of_student("Ada"), g2.age_of_student("Bo"))
print(g1 == g2, g1 == g1.delete_student("Nobody"))
```

prints, with the interpreter and compiled for Python, Node, Java,
C (`c-gc`) and OCaml alike:

```
StudentGroup of 0: []
StudentGroup of 3: ["Ada", "Bo", "Cy"]
StudentGroup of 2: ["Cy", "Ada"]
Some(36) Some(37) None
false true
```

**Immutable: yes.** `students` isn't `var`, so it is never reassigned.
A list of tuples of `String` and `Int` can't be changed in place
either, so the group is deeply immutable, not only shallowly (§4b).
`empty` and `g1` are unchanged after `g2` is made from them.

**But `private` on a header field hides the field and not the
parameter.** Four routes in, all accepted today, break the promises
from outside the class. Routes 1, 2 and 4 were run with the
interpreter, Python, Java and OCaml, with the same output on each;
route 3 with the interpreter:

```pyking
# after the class above
forged = StudentGroup([("Ada", 36), ("Ada", -5)])     # 1. positional
print(forged, forged.age_of_student("Ada"))
# StudentGroup of 2: ["Ada", "Ada"] Some(36)

also = StudentGroup(students = [("Bo", -1)])           # 2. named
print(also.age_of_student("Bo"))
# Some(-1)

class Sneaky(n: Int) extends StudentGroup([("Ghost", -100)])   # 3. extends
print(Sneaky(1).age_of_student("Ghost"))
# Some(-100)

match forged:                                          # 4. a pattern
    case StudentGroup(inside): print("read from outside:", inside)
# read from outside: [("Ada", 36), ("Ada", -5)]
```

Routes 1 to 3 *write* the private field from outside, by passing it to
the constructor. Route 4 *reads* it: a class pattern binds a private
header field anywhere, from another module too (checked with
`public class StudentGroup` imported by `from school import
StudentGroup`). One related leak: a class without `show` prints its
header fields, private ones included (`StudentGroup([("Ada", 36),
("Bo", 21)])`). The example defines `show`, so it doesn't show this.

What does work already: `p.students` from outside is refused (`'students'
is private to 'StudentGroup'`), and so is the update form
`StudentGroup(..g)`, since `..` fills the private field.

So **what is missing is exactly one rule**: a private header parameter
mustn't be given from outside the class. Pattern reading (route 4) is a
separate hole in today's `private`, and should be closed whatever is
decided here.

### 6.3 The proposal: `private` constructor parameters

The suggestion is to make `private` on a header parameter mean what a
reader of

```pyking
class StudentGroup(private students: [(String, Int)] = []):
```

expects: **the field is private, and so is the parameter.** Code outside
the class sees a constructor without it, `StudentGroup()`. Only the
class's own methods may pass it, which is what `add_student` and
`delete_student` do.

**My view: I agree, and I'd make it the next step,** ahead of §5.1
(making the whole constructor private). Reasons:

- **It adds no syntax.** The example above compiles today. The proposal
  only adds refusals, so the example's output doesn't change. Students
  write it this way already and expect it to be safe.
- **It closes a hole rather than adding a feature.** Today's private
  header field can be set by anyone, once, at construction, which is
  the moment that matters most for an immutable object. "Private" that
  everyone may set is hard to explain. With the proposal, `private`
  means one thing for header fields, body fields and methods: only the
  class's own methods reach it.
- **It fits immutable classes exactly.** The pattern "start from an
  empty value, grow by methods that answer new values" is how
  immutable collections are written in every functional language.
  It is how `Map` and `Set` already behave in Pyking. The class's
  promises then depend only on the class's own code, which can be
  checked by reading that class alone.
- **It also makes the object deeply private.** Since only methods can
  pass the field, nobody outside ever holds the list (or, for a
  `private items: Array(Int) = array([])`, the array) that the object
  keeps. That is the §4b problem solved without a copy.
- **It's small.** It is all in the checker and the tools. Every backend
  already compiles defaults, so the generated code doesn't change.

### 6.4 The rules, precisely

Where the user's proposal leaves a choice open, I propose:

1. **Who may give it: the class's own methods only.** That is the reach
   of `private` everywhere else. These may *not* give it:
   - another function in the same module;
   - another module;
   - a subclass, in its methods or its `extends StudentGroup(...)`;
   - the update form `StudentGroup(students = ..., ..g)`.

   All four get the default. A call from outside that gives it, by
   position or by name, is refused:
   `'students' is private to 'StudentGroup': only its methods give it;
   outside, 'StudentGroup' is made as StudentGroup()`.

2. **It must have a default.** Without one, nothing outside could make
   the object, and a method needs an object to run on, so the class
   could never be made at all. A private parameter without a default is
   refused where it is written, with that reason. (Today's §4
   examples, `Acc(owner, private balance)` or `SafeTeam(name, private
   scores)`, are classes whose maker supplies the private value. Under
   the proposal they need either a default and a method, or §5.1.)

3. **Private parameters come after the public ones.** They have
   defaults, so in practice they do already. The rule makes it certain
   that a positional call means the same parameters inside and outside
   the class, with the private ones simply not there outside.

4. **A class pattern outside the class writes `_` where a private field
   is.** `case StudentGroup(_)` is fine. `case StudentGroup(inside)` is
   refused (`'students' is private to 'StudentGroup': write '_' in its
   place`). A pattern keeps one shape everywhere, and nothing private
   is read. This rule closes route 4, and is worth doing even if the
   rest is not.

5. **Printing hides it.** A class without `show` prints a private field
   as `_`: `StudentGroup(_)`. That matters across modules: a class's
   inside would otherwise be in every printout. The REPL's echo and the
   debugger's Variables view still show everything, since they are
   tools for looking inside.

6. **The constructor as a function value has the public parameters
   only** where the class is not. A class whose parameters are all
   private behaves like one whose parameters all have defaults:
   `StudentGroup` alone means `StudentGroup()`, as it already does
   today (`G` with `class G(private xs: [Int] = [])` is `G([])`).

7. **Nothing else changes.** `copy`, `deepcopy`, `eq`, `same`, and
   `public class` across modules work as before. The rules apply in
   another module as in the declaring one, since the rule is about the
   class, not the module.

### 6.5 What it costs, and what it leaves out

**Implementation.**

| Part | Change |
|---|---|
| typesystem.ml | a constructor call, `extends`, or update form outside the class's methods may not give a private parameter, and is filled with its default; a private parameter needs a default and comes after the public ones; a class pattern outside writes `_` for a private field |
| desugar_args.ml | named and positional arguments outside the class are placed among the public parameters only |
| interpreter, backends | none for the constructor; printing a private field as `_` in each target's default `show` (Python, JS, Java, C, OCaml, interpreter) |
| LSP | signature help and completion of named arguments show `StudentGroup()` outside the class |
| docs | PYKING.md, "`private`" in "Classes and interfaces" and "What `public` exports"; CHANGELOG |
| tests | the example above as a program on every target; a `fail_*` for each route in §6.2, the missing default and the order rule; across modules too; an LSP signature case |

**What it leaves out.**

- **Making a group from arguments that are checked.** For example,
  `StudentGroup.of([("Ada", 36), ("Bo", 21)])` failing on a duplicate.
  Under the proposal that is a method on the empty group,
  `StudentGroup().add_all(pairs)`, which works but reads oddly. If
  courses want module-level factories that check their arguments,
  §5.1 (the whole constructor private to its module) is the
  complement. It can be added later without changing this rule.
- **Promises written in the class.** The promises live in the methods;
  nothing states them. An `init:` block (§5.2) would let the class check
  them once per object. With private parameters that matters less:
  every object is made by a method of the class, so the promises are
  all in one class to read.
- **Forbidding subclasses.** A subclass can't give the private
  parameter, but it can still add methods and override public ones.
  `final` (plan-objects.md §11.10) is a separate question.

**Alternatives considered.**

| Option | For | Against |
|---|---|---|
| **A. `private` on a header parameter hides the parameter too (the proposal; recommended)** | no new syntax; one meaning of `private`; closes a hole | changes what today's code means: passing a private header field from outside becomes an error (no program in the repository does so) |
| B. A new word for it, `hidden students: ...`, keeping today's `private` | nothing that compiles today changes meaning | two words for privacy, and the old one keeps its hole |
| C. Only §5.1, the whole constructor private to its module | also covers checked module-level factories | the class's promises then depend on the whole module, not only the class; and a module function can still forge a group |

A and C combine well: A for "made empty, grown by methods", C for "made
from arguments by a checked factory".

### 6.6 Three follow-up questions

#### A separate `hidden`, which only hides the parameter?

A header parameter has two separate kinds of visibility: who may
**pass** it to the constructor, and who may **read** the field
afterwards. With two words there are four combinations:

| Pass it | Read it | Written | Use |
|---|---|---|---|
| anyone | anyone | `students: T` | ordinary data (`Rect(w, h)`) |
| methods only | anyone | `hidden students: T = []` | **a read-only field**: outside code reads `g.students` but can't forge a group |
| anyone | methods only | `private students: T` (today's meaning) | almost none: the promises can be broken when the object is made |
| methods only | methods only | `hidden private students: T = []` | `StudentGroup` |

`hidden` does add one useful case, the read-only field. For an
immutable class it is safe, and it saves a getter method, which would
also need another name (a method never shares a field's name).

But `hidden` as the *only* fix leaves the third row legal, and that row
is the natural thing to write: a student writes `private students` and
believes it is protected. Two words that must be combined correctly is
also a lot for an introductory course.

**Recommendation:** `private` on a header parameter means both (§6.3).
`hidden` can be added later, alone, for the read-only case, without
breaking anything. That leaves three rows, each with a use.

#### Every constructor parameter private by default?

No, whichever of two things is meant:

- **If the parameters are hidden by default**, `Rect(2.0, 3.0)` stops
  working unless every parameter is marked `public`. The header is
  deliberately a struct's header, and it doubles as the constructor, as
  a Java record or a Python dataclass does. Every class in the tests,
  the docs and the tour would change.
- **If the fields are private by default** (Java's convention for
  classes), every class needs getters, and class patterns like
  `case Rect(w, h)` stop working outside the class. The usual argument,
  "don't let others change your fields", hardly applies: Pyking's fields
  are immutable unless `var`, so exposing one is safe.

Privacy is for protecting a promise (no duplicate names, no negative
ages). That is the exception, so opting in with `private` is the right
default. It is also Python's: everything is public unless marked.

#### What does a subclass see of a private field?

Run with today's compiler, base class `StudentGroup(private students:
[(String, Int)] = [])` with methods `add_student` and `size`:

- **A subclass can't see it.** `len(self.students)` in a method of
  `class Honours(level: Int) extends StudentGroup()` is refused:
  `'students' is private to 'StudentGroup'`.
- **It can't reuse the name.** A body field `students: Int = 3` in
  `Honours` is refused: "a class below it never declares a member of
  that name".
- **Inherited methods still work on it.** `Honours(1).size()` runs the
  parent's method, which reads the field. A subclass reaches the
  parent's state only through the parent's methods.
- **Today a subclass can set it.**
  `class Honours(level: Int, students: [(String, Int)]) extends
  StudentGroup(students)` passes any list, so `Honours(1, [("Eve",
  -3)])` holds a negative age. (`h.students` and a class pattern on
  `Honours` that binds it are refused, though: the header parameter
  only passes the inherited field on.) Under §6.3 the `extends` is
  refused: only `StudentGroup`'s own methods may give `students`, so a
  subclass gets the default.
- **The type is lost.** `Honours(1).add_student("Ada", 36)` answers a
  plain `StudentGroup`, since the parent's method makes a
  `StudentGroup` and can't make a subclass it doesn't know. A
  `case x: Honours` on the result doesn't match. This is the usual
  problem of inheritance in immutable classes, and why Scala's and
  Kotlin's value classes are final. In practice a class like this is
  best not extended. A `final` keyword (plan-objects.md §11.10) would
  let its author say so.

**A usability problem found on the way.** A subclass header parameter
named like an inherited field, but not passed to the parent, is
silently ignored:

```pyking
use objects
class A(n: Int)
class B(m: Int, n: Int) extends A(5)
print(B(1, 2).n)      # 5 -- the 2 is dropped (interpreter, Python, Java)
```

It isn't a semantic bug: Java's `B(int m, int n) { super(5); }` ignores
`n` the same way, and `b.n` is 5 there too. But in Pyking a header
parameter normally *is* the field, so `n` in `B`'s header reads as if it
sets the field. It should be refused (or warned about): "'n' is the
field 'B' inherits from 'A', and 'extends A(5)' does not pass it on;
pass it, or give the parameter another name".

### 6.7 Does this match Java?

Mostly. Private fields behave as in Java, and §6.3 gives the class Java
programmers already write. The differences come from the header, which
is modelled on Java's *records*, not on ordinary classes.

**Where it matches:**

| | Java | Pyking |
|---|---|---|
| Who reads a private field | the declaring class only; subclasses don't see it | the same |
| Per class, not per object | `other.students` works inside the class | the same |
| A subclass sets a parent's private state | only through a parent constructor it may call | the same, through `extends Parent(args)` |
| Inherited methods use the private field | yes | yes |
| A method answering `new StudentGroup(...)` | loses the subclass type | the same |
| A subclass constructor parameter not passed to `super` | silently unused | the same (§6.6) |

**§6.3 is the Java idiom.** In Java, `StudentGroup` is written:

```java
public final class StudentGroup {
    private final List<Student> students;

    public StudentGroup() { this(List.of()); }                     // what outsiders get
    private StudentGroup(List<Student> s) { this.students = s; }   // methods only

    public StudentGroup addStudent(String name, int age) {
        return new StudentGroup(...);
    }
}
```

`class StudentGroup(private students: [...] = [])` under §6.3 means
exactly this:
- the parameter's default is the public no-argument constructor;
- the private parameter is the private constructor;
- a subclass can't call a private super-constructor, so it gets the
  public one.

The Java backend could generate this pair. Today it writes a single
package-private constructor taking `students`, beside a `private final`
field, which is today's hole spelled in Java.

**Where it differs:**

1. **The header is a record, not a class.** In a Java `record`, every
   component is a constructor parameter with a public accessor, and the
   canonical constructor can't be less accessible than the record. So a
   record can't hide state at all. Pyking's `private` on a header field
   is its own addition, and §6.3 makes that field behave as a plain
   Java class's would.
2. **Patterns.** Java has deconstruction patterns only for records, and
   they go through the public accessors. An ordinary Java class never
   gives a private field out through a pattern. Today's `case
   StudentGroup(inside)` has no Java counterpart; §6.4 rule 4 removes
   it.
3. **Printing.** A Java class prints by default as
   `StudentGroup@1b6d3586`, with no fields; a record shows every
   component. Pyking prints like a record, private fields included.
   §6.4 rule 5, printing them as `_`, sits between the two.
4. **Immutable by default.** Java fields can be reassigned unless
   `final`; Pyking's can't unless `var`. Pyking is closer to records
   and to Kotlin's `val`.
5. **Static factories.** In Java the class's static methods may call
   its private constructor. Pyking has no static methods, so under
   §6.3 only instance methods may. That is why §6.5 writes
   `StudentGroup().add_all(pairs)` where Java writes
   `StudentGroup.of(pairs)`.
6. **Reusing a private field's name.** Java lets a subclass declare a
   field with the name of a parent's private field (a new, separate
   field). Pyking refuses it, deliberately: one name, one field.
7. **`final`.** Java writes `public final class StudentGroup`, and the
   type-loss problem of §6.6 never comes up. Pyking has no `final`. Its
   Java backend marks a class final only when nothing in the program
   extends it, and a `public class` is open to every module.

---

## 7. New proposal

This is what to implement. It takes §6's design with `private` alone:
a `private` header parameter is a private field that only the class's
own methods may give. There is no `hidden`. It also fixes the bugs and
leaks found while writing this note. Everything else in §5 and §6
stays a later possibility (§7.8).

### 7.1 The tasks

| Task | What | Kind | Size |
|---|---|---|---|
| T1 | `private` header parameters are given only by the class's own methods | language change | moderate |
| T2 | a class pattern outside the class doesn't bind a private field | leak (bug) | small |
| T3 | printing an object without `show` doesn't show private fields | leak (bug) | small to moderate (every target) |
| T4 | method and field names like `__del__` are refused (§5.6) | bug, Python only | small |
| T5 | a subclass header parameter named like an inherited field must pass it on | usability bug | small |
| T6 | upcasts into a datatype constructor's arguments, `Ok(Cents(...))` (§5.7) | friction, optional | small to moderate |

T1 to T3 together are what make `StudentGroup` (§6.2) keep its
promises. T4 and T5 are independent and can go first. None needs a new
keyword, so the editor grammars don't change.

**Compatibility.** A search of `tests/`, `lib/`, `essentials/`,
`web_examples/` and `pyking-web-examples/` found no program that does
any of these:
- passes a private header parameter from outside the class;
- binds a private field in a pattern;
- relies on a private field being printed;
- names a member `__...__`;
- declares a subclass parameter that is not passed on.

The full suite after each task confirms it.

### 7.2 T1: private constructor parameters

**The rule.** In `class C(a: Int, private xs: [Int] = [])`:

1. **Only `C`'s own methods may give `xs`**: a constructor call
   `C(...)` written inside a method declared in `C`, a lambda inside
   such a method included. Everywhere else `xs` takes its default:
   - other functions and top-level code, in `C`'s module or another;
   - body-field initialisers of `C`;
   - methods of a subclass, and a subclass's `extends C(...)`.

   That is the reach `private` has for fields and methods already.
2. **A private header parameter has a default.** Without one, nothing
   could ever make the object. This is refused where it is written.
3. **Private header parameters come after the others**, so a positional
   call means the same parameters inside and outside the class.
4. **Outside the class, giving it is refused**, by position or by name.
5. **Outside the class, the constructor as a function value takes the
   other parameters only.** `map(C, [1, 2])` makes `C(1)` and `C(2)`.
   When there are no other parameters, `C` alone already means `C()`,
   as for any constructor whose parameters all have defaults.
6. **Unchanged:**
   - reading the field (`o.xs` outside is refused, as today);
   - the update form (`C(xs = ..., ..o)` and `C(..o)` outside are
     refused, as today, since `..` fills the private field);
   - `copy`, `deepcopy`, `eq`, `same`, `var`;
   - `public class` across modules, where the rules are the same;
   - private body fields, which aren't parameters.

**Messages.**

| Where | Message |
|---|---|
| given from outside | `'xs' is private to 'C': only the methods of 'C' give it, and elsewhere 'C' is made without it, as C(a)` |
| given by a subclass's `extends` | `'xs' is private to 'C', so 'D' does not give it: write extends C(a), and 'xs' starts as its default` |
| no default | `'xs' is a private parameter of 'C', which only its methods give, so it needs a default: nothing else could make a 'C'` |
| out of order | `'xs' is private, so it comes after 'C''s other parameters: a call outside the class gives only those` |

**What changes, by part.**

| Part | Change |
|---|---|
| `src/desugar_args.ml` | It fills in defaults before the checker runs, so this is where "given" is still visible. The parameter record gains `private_ : bool`, kept in the signatures other modules see. The pass tracks the class whose method it is in. A call that gives a private parameter from outside the class's methods is refused (positional past the public ones, or named). An `extends` argument list is treated the same way. Outside the class, a constructor used as a function value becomes a lambda over the public parameters. |
| `src/typesystem.ml`, `declare_classes` | Rules 2 and 3, at the class's declaration. |
| `src/module.ml` | Whether a parameter is private travels in a public class's signature (`TClass`), so another module's desugar sees it. |
| `src/lsp.ml` | Outside the class, signature help, completion of named arguments, and the constructor's hover show only the public parameters. |
| interpreter, every backend | Nothing: by the time they see the program, every call has all its arguments. |
| web tools | Nothing of their own: the playground and notebook run `pyking.js`, which has the same front end. |

**Tests.**
- `immutable_student_group`: §6.2's program, on every target, with its
  `.out`.
- `module_class_private_param` with `_mod`: the same across modules,
  with `from ... import` and with an alias.
- `fail_typecheck_private_param_positional`, `_named`, `_extends`,
  `_function_value` (giving it through `map(C, ...)` with two
  arguments), `_no_default`, `_order`, `_body_field` (a body-field
  initialiser calling `C(...)` with it), `_subclass_method`, and
  `_other_module`.
- An LSP case: signature help inside and outside the class.

**Docs.**
- PYKING.md, "Classes and interfaces": the paragraphs on fields and
  the constructor and on `private`, with `StudentGroup` as the example.
- PYKING.md, "Classes across modules": "What `public` exports".
- `docs/desugar_args.md`; CHANGELOG ("Changed": what a private header
  parameter means).
- The site's "Pyking vs. other languages": the Java comparison of
  private constructors (§6.7).

### 7.3 T2: class patterns don't read private fields from outside

**The bug.** `case StudentGroup(inside):` binds the private field
anywhere, in another module too (§6.2, route 4).

**The rule.** Outside the methods of the class declaring a private
header field, a class pattern writes `_` in that field's place. Any
other pattern there is refused: a name, a literal, or a nested pattern.
Even a literal would test the private value.

**Message.** `'students' is private to 'StudentGroup': a pattern outside
it writes '_' in its place`.

**What changes.**
- `src/typesystem.ml`, where a class pattern's fields are checked: the
  same `store.current_class` test as `object_member`. Patterns reach
  the checker positional, with `_` for every field not written
  (`desugar_args.ml`), so `case StudentGroup()` and
  `case StudentGroup(_)` stay legal.
- `src/exhaustive.ml` needs nothing.

**Tests:** `fail_typecheck_private_pattern`, `_nested`, `_other_module`;
and a `_` pattern from outside and a binding pattern inside a method in
`immutable_student_group`.

**Docs:** PYKING.md, "Class patterns".

### 7.4 T3: printing doesn't show private fields

**The leak.** An object of a class without `show` prints its header
fields, private ones included: `StudentGroup([("Ada", 36)])`.

**The rule.** `print`, `string` and string interpolation write a
private header field as `_`: `StudentGroup(_)`, `Acc("ada", _)`. A
class that wants more defines `show`. The REPL's echo of a value and
the debugger's Variables view still show every field: they are tools
for looking inside, and they never ran `show` either.

**What changes.** Each target's default object printer, from the class's
`fd_private` flags:

| Part | Where |
|---|---|
| interpreter | `src/interpreter.ml`, the printing of an object (the `k_header` fields, about line 484). The REPL's echo and the DAP keep the full form, so the printer takes a flag. |
| Python | `src/target_python.ml`, the generated `__repr__` (about line 2432) |
| JavaScript | `src/target_js_core.ml`, the class descriptor's printed fields (about line 2442) |
| Java | `src/target_java.ml`, the runtime's object `toString` and the field list each class gives it (about line 3716) |
| C | `src/target_c.ml`, the class descriptor's show function |
| OCaml | `src/target_ocaml.ml`, `pyk_show` (about line 5874) |

**Tests:**
- `objects_print_private` on every target: a class with a private
  header field and no `show`, printed alone, in a list, and inside
  another object.
- A REPL case showing the full echo.
- The playground suite checks `pyking.js` against `pyk`.

**Docs:** PYKING.md, "Equality and printing"; `docs/interpreter.md` and
each `docs/target_*.md` that describes how an object prints.

### 7.5 T4: refuse Python's special names (§5.6)

**The bug.** A method named `__del__` runs as a finaliser on Python
only (§3). Other `__...__` members (`__eq__`, `__hash__`, `__len__`,
`__repr__`, `__class__`, `__dict__`, ...) are bound under the name
written and may change Python's behaviour the same way.

**The rule.** A method or field of a class (header, body, interface
signature) whose name begins and ends with `__` is refused.

**Message.** `'__del__' is a name Python gives a meaning of its own;
Pyking calls no method when an object is collected, and a member of
this name would behave differently on Python. Give it another name`.
For `__eq__` and `__str__`, the message names `eq` and `show` instead.

**What changes.**
- `src/typesystem.ml`, `declare_classes`: one check per member.
- Struct and datatype field names, top-level defs and module names
  reach Python too. A test should confirm whether a struct field or a
  top-level def named `__init__`/`__name__` misbehaves. If one does,
  the same rule extends there; if not, the rule stays on classes.

**Tests:** `fail_typecheck_objects_dunder_method`,
`fail_typecheck_objects_dunder_field`, and
`fail_typecheck_objects_dunder_interface`.

**Docs:** PYKING.md, "Methods"; `docs/target_python.md`.

### 7.6 T5: a subclass parameter named like an inherited field is passed on

**The problem.** In `class B(m: Int, n: Int) extends A(5)`, `n` has
the name of `A`'s field, so it "only passes it on". But `extends A(5)`
doesn't pass it, so `B(1, 2).n` is 5 and the 2 is silently dropped
(§6.6). Java behaves the same way, but in Pyking a header parameter
normally *is* the field, so the code reads as if it sets it.

**The rule.** A header parameter with the name of an inherited field
must be the argument `extends` gives for that field: `extends A(n)`, or
`extends A(n = n)`. Otherwise it is refused.

**Message.** `'n' is the field 'B' inherits from 'A', and 'extends A(5)'
does not pass it on, so the value given for it would be dropped: write
extends A(n), or give the parameter another name`.

**What changes.**
- `src/typesystem.ml`, `declare_classes`, the branch that lets a header
  parameter pass an inherited field on (about line 2645). By then the
  `extends` arguments are positional, so the check is that the argument
  at the field's position is the bare name `n`.
- An argument that only *uses* `n` (`extends A(n + 1)`) is refused too.
  The parameter has to be renamed, since `B`'s `n` would otherwise be
  `A`'s field with a different value than was given.

**Tests:** `fail_typecheck_objects_param_not_passed` and `_used` (the
`n + 1` case). The existing objects tests that pass a field on must
still pass.

**Docs:** PYKING.md, "Inheritance": the sentence on a header parameter
that only passes a field on.

### 7.7 T6 (optional): upcasts into constructor arguments (§5.7)

**The friction.** In a function returning `Result(Money, String)`,
`Ok(Cents(...))` is refused (`its body ends in a value of type
Result(Cents, String)`). A factory has to write `m: Money = Cents(...)`
and then `Ok(m)`.

**The rule.** Where the expected type of a datatype constructor's value
is written down (a declared result, an annotation, a parameter), its
arguments are checked against the constructor's field types at that
type's arguments, so an upcast is made there as it is in a list or a
tuple. This is still "only where the type is written", so inference
doesn't change in kind.

**What changes.** `src/typesystem.ml`: where an expected type is pushed
into lists, tuples and `if`, a datatype constructor's arguments are
added. `src/elaborate.ml` already wraps whatever the checker records
in `upcasts`.

**Tests:** `objects_upcast_constructor_arg` on every target (`Ok`,
`Some`, a user datatype, nested `Some(Ok(...))`), and one that stays
refused where nothing is written.

**Docs:** PYKING.md, "Where an object is seen as a supertype".

### 7.8 Not in this proposal

These stay where §5 and §6 discussed them, to reconsider if courses
need them:
- **`hidden`**, a read-only field that only the class can give
  (§6.6). It can be added later on its own.
- **Module scope for passing a private parameter**, Rust's rule
  (§6.6). Widening T1 to it later is backward compatible.
- **Making the whole constructor private**, §5.1.
- **`init:` and `require`**, §5.2.
- **`immutable class`**, §5.5.
- **`sealed` and `final`**, §5.4 and plan-objects.md §11.10.
- **A Java private-constructor pair.** The Java backend could generate
  the idiom of §6.7 (a public constructor without the private
  parameter, a private one with it). Defaults are filled at each call
  site, in the caller's Java class, so another module's call would
  need the public one. The generated Java would then show the rule,
  but nothing changes in behaviour.

### 7.9 Order and checking

1. **T4 and T5 first:** small, independent, each with its own tests.
2. **T2 next:** it closes a leak that exists whatever else is decided.
3. **T1, then T3:** with T2 these complete the private-parameter design.
   `immutable_student_group` is the test that must hold at the end.
4. **T6 last**, if wanted.

After each task:
- the full suite (`make test`): programs on every target, REPL,
  warnings, LSP, DAP, playground parity, notebook, site;
- PYKING.md and CHANGELOG updated in the same change, as CLAUDE.md
  asks;
- this file's §4 and §6 updated where they describe today's behaviour
  that the task changes.
