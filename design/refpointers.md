# Pointers, references and aliasing: C, Java and Pyking

This note compares three ways a program can reach one piece of data
through more than one name: C's pointers, Java's references, and
Pyking's three mechanisms. The three in Pyking are shared values
(objects, `mutable struct`s, arrays and the other mutable collections),
aliasing as it follows from `=`, and, under `use mutation, pointers`,
pointers.

It is a design note, not the reference. PYKING.md ("Mutable state",
"Collections", "Classes and interfaces") says what Pyking programs
mean. docs/pointers.md tells the full story of pointers, and
design/plan-objects.md the story of objects.

Every example below was compiled and run. The C examples were built
with `gcc -std=c99 -Wall`, the Java examples with `javac`, and the
Pyking examples with `pyk`. The outputs in the comments are what the
programs printed.

## Contents

1. [The shared idea: indirection](#the-shared-idea-indirection)
2. [Pointers in C](#pointers-in-c)
3. [References in Java](#references-in-java)
4. [C pointers and Java references compared](#c-pointers-and-java-references-compared)
5. [Pyking: values, and the things that are shared](#pyking-values-and-the-things-that-are-shared)
6. [Pyking: aliasing](#pyking-aliasing)
7. [Pyking: objects are references](#pyking-objects-are-references)
8. [Pyking: pointers, when enabled](#pyking-pointers-when-enabled)
9. [One task, five ways: swap and move](#one-task-five-ways-swap-and-move)
10. [The comparison table](#the-comparison-table)
11. [Living without null](#living-without-null)
12. [Observations](#observations)
13. [When are Pyking's pointers useful?](#when-are-pykings-pointers-useful)

## The shared idea: indirection

A pointer and a reference are both values that do not hold the data
themselves. Each one *leads to* data held somewhere else. Two
consequences follow from that:

- **Aliasing.** Two names can lead to the same data, so a write
  through one is seen through the other.
- **Identity apart from contents.** "Are these the same thing?" is a
  different question from "Do these hold equal values?"

The languages differ in what may be pointed at and what may be done
with the pointer. They also differ in what happens when nothing is
pointed at, and in who decides when the data stops existing.

## Pointers in C

A C pointer is a memory address with a type. Any object with storage
has an address: a local, a global, an array element, a struct field,
or memory from `malloc`.

```c
#include <stdio.h>
#include <stdlib.h>

struct point { int x, y; };

void swap(int *a, int *b) { int t = *a; *a = *b; *b = t; }
void move(struct point p) { p.x += 1; }          /* a copy */
void move_ptr(struct point *p) { p->x += 1; }    /* the caller's */

int main(void) {
    int x = 1, y = 2;
    swap(&x, &y);
    printf("%d %d\n", x, y);                     /* 2 1 */

    struct point a = {1, 2};
    struct point b = a;                          /* copies the struct */
    move(a);
    move_ptr(&b);
    printf("%d %d\n", a.x, b.x);                 /* 1 2 */

    int xs[3] = {10, 20, 30};
    int *p = xs;                                 /* &xs[0] */
    printf("%d %d\n", *(p + 2), p[1]);           /* 30 20 */

    int **pp = &p;
    **pp = 11;
    printf("%d\n", xs[0]);                       /* 11 */

    struct point *h = malloc(sizeof *h);
    h->x = 5;
    struct point *alias = h;
    alias->x = 6;
    printf("%d %d\n", h->x, h == alias);         /* 6 1 */
    free(h);                                     /* alias now dangles */
    int *nothing = NULL;
    printf("%d\n", nothing == NULL);             /* 1 */
    return 0;
}
```

The essential properties:

- **Address-of is explicit.** `&x` makes a pointer to any variable,
  local ones included, and to any element or field. A pointer's type,
  `int *`, says what it points to.
- **Dereference is explicit.** `*p` reads and `*p = v` writes. `p->x`
  is shorthand for `(*p).x`.
- **Everything else is a value and is copied.** `struct point b = a`
  copies the whole struct. Passing a struct copies it. To share a
  struct you pass a pointer to it.
- **Parameters are passed by value.** C has no reference parameters.
  `swap(&x, &y)` gets its effect by passing addresses *as values*.
- **Arithmetic.** `p + 2` points two elements further on, and `p[i]`
  is `*(p + i)`. An array used as a value decays to a pointer to its
  first element, so arrays and pointers are nearly interchangeable.
- **`NULL`.** Any pointer may be null. Dereferencing a null pointer is
  undefined behaviour, and nothing checks it.
- **Lifetime is the programmer's job.** A pointer to a local outlives
  the local if it is returned. A pointer to freed memory still exists.
  Both *dangle*, and using one is undefined behaviour. Memory from
  `malloc` lives until `free`.
- **Pointers to pointers.** `int **pp` points to a pointer variable,
  and `**pp = 11` writes through both.
- **Casts and `void *`.** A pointer can be converted to another
  pointer type, or to and from an integer. The type system can be
  stepped around.
- **Equality is address equality.** `h == alias` asks whether both
  point at the same place. Comparing the contents takes code or
  `memcmp`.

## References in Java

A Java reference names an object. Every value whose type is a class,
an interface or an array is a reference. The eight primitive types
(`int`, `double`, `boolean`, …) are plain values.

```java
public class Refs {
    static class Point { int x, y; Point(int x, int y) { this.x = x; this.y = y; } }

    static void swap(Integer a, Integer b) { Integer t = a; a = b; b = t; }  // no effect
    static void move(Point p) { p.x += 1; }                // the caller's object
    static void replace(Point p) { p = new Point(0, 0); }  // only the parameter

    public static void main(String[] args) {
        Integer x = 1, y = 2;
        swap(x, y);
        System.out.println(x + " " + y);                   // 1 2

        Point a = new Point(1, 2);
        Point b = a;                                       // the same object
        move(b);
        replace(a);
        System.out.println(a.x + " " + (a == b));          // 2 true

        Point c = new Point(2, 2);
        System.out.println(a == c);                        // false: identity

        int[] xs = {10, 20, 30};
        int[] ys = xs;
        ys[0] = 11;
        System.out.println(xs[0]);                         // 11

        Point nothing = null;
        try { nothing.x = 1; }
        catch (NullPointerException e) { System.out.println("NullPointerException"); }
    }
}
```

The essential properties:

- **Objects exist only behind references.** `new Point(1, 2)` answers
  a reference. No variable ever holds the object itself, so
  `Point b = a` copies the reference, never the object.
- **Dereferencing is implicit.** `p.x` and `p.m()` follow the
  reference. There is no `*` and no `&`.
- **No address-of.** A reference can only name a whole object. No
  reference can name a local variable, a field or an array element.
  That is why `swap(Integer, Integer)` cannot swap the caller's
  variables. It swaps its own copies of two references.
- **Parameters are passed by value, and the values are references.**
  `move(b)` changes the caller's object because both hold the same
  reference. `replace(a)` changes nothing the caller sees because it
  only rebinds its own parameter. This is often called "passing
  references by value" (sometimes "call by sharing").
- **No arithmetic and no casts to integers.** A reference cannot be
  moved through memory, and an array is reached only by index, with
  every index checked.
- **`null`.** Every reference type includes `null`. Using it throws a
  `NullPointerException`. This is a checked error at run time, not
  undefined behaviour.
- **The garbage collector owns lifetime.** An object lives as long as
  it is reachable, so a reference never dangles, and there is no
  `free`.
- **Two equalities.** `==` compares references (identity), and
  `equals` compares whatever the class says.
- **Casts are checked.** A downcast throws `ClassCastException` if the
  object is not of that class. The type system cannot be stepped
  around.

## C pointers and Java references compared

**Alike.** In both languages:

- Assigning a pointer or a reference shares the data rather than
  copying it, so two names can alias one thing.
- Passing one to a function lets the function change the caller's
  data, while the pointer or reference *itself* is passed by value.
- `==` on two of them is identity, not equality of contents.
- Linked structures (lists, trees, graphs, cycles) are built from them.
- A "nothing" value exists (`NULL`, `null`), and every pointer or
  reference type includes it.

**Different:**

- *Targets.* A C pointer can point at **any place in memory**: a
  variable, a field or an element. A Java reference names only a
  **whole object**. This is the difference that matters most: C can
  write through a pointer to the caller's local variable, and Java
  cannot.
- *Visibility.* C makes indirection visible (`&`, `*`, `->`) and
  struct values the default. Java makes indirection invisible and the
  only way to hold an object.
- *Memory.* C allows arithmetic on pointers and treats arrays as
  pointers. Java has neither.
- *Safety.* In C, null, dangling and out-of-bounds pointers are
  undefined behaviour. In Java, null and a bad index are exceptions,
  and a dangling reference cannot happen.
- *Lifetime.* C has manual `malloc`/`free` and automatic stack
  variables. Java has garbage collection.

## Pyking: values, and the things that are shared

Pyking divides its types into two kinds, and that division answers
most aliasing questions before pointers come in.

- **Values that never change.** Int, Float, Char, Bool, String, lists,
  tuples, Maps, plain `struct`s, datatypes, Option and Result, and
  functions. Nothing can change one in place, so it does not matter
  whether two names share one copy or hold two copies: no program can
  tell. (Every backend does share them: a list is never copied
  because it is bound to another name.) To "change" one, a program
  builds a new value. For example, `Point(x = 5, ..p)` builds a
  changed copy of a plain struct.
- **Things that are shared.** Arrays, DynArrays, MutMaps, views,
  `mutable struct`s and objects. These can be written in place, and
  *every name, parameter, element and field holding one holds the same
  one*, exactly as in Java. Each type can only be made or written
  under `use mutation` (objects under `use objects`). `same(a, b)` asks
  whether two names hold the same one, which is Java's `==` on
  references.

So the shared kinds have the semantics of Java references, but without
`null` and without implicit sharing of everything. A plain `struct` is
a value, as in C. A `mutable struct` is shared, as Java's objects are.
The keyword `mutable` is what moves a struct from one kind to the
other.

## Pyking: aliasing

Aliasing in Pyking follows from two rules:

1. **`=` never copies and never writes.** `b = a` binds a new name to
   the very thing `a` holds. For a value that never changes this is
   unobservable. For a shared kind, `b` and `a` are now aliases.
2. **A `var` holds a value. It is not itself shared.** `m = n` where
   `n` is a `var` binds `m` to the value `n` holds *now*. A later
   `n := 2` makes `n` hold another value and leaves `m` as it was. No
   name other than `n` can write `n`, except a pointer to it (see the
   next sections) or a function that captured it.

```pyking
use mutation

mutable struct Point(x: Int, y: Int)

struct P2(x: Int, y: Int)

def move(p: Point) -> ():
    p.x += 1

a = Point(1, 2)
b = a
move(b)
print(a, same(a, b))         # Point(2, 2) true

v = P2(1, 2)
w = P2(x = 5, ..v)
print(v, w)                  # P2(1, 2) P2(5, 2)

xs = array([1, 2, 3])
ys = xs
ys[0] := 9
print(xs, same(xs, ys))      # array([9, 2, 3]) true

var n = 1
m = n
n := 2
print(n, m)                  # 2 1

var k = 0
def bump() -> ():
    k += 1
bump()
bump()
print(k)                     # 2

c = Point(1, 2)
print(same(c, Point(1, 2)))  # false
```

How this lines up with C and Java:

- **Shared kinds alias as Java's objects do.** `move(b)` changes the
  caller's `Point`, as Java's `move` does. A parameter is never a
  `var`, so there is nothing like Java's `replace`: a function cannot
  rebind its argument at all.
- **Plain structs are values, as C's are.** No other name can ever see
  a change to one, because none can be made. Where C *copies* to keep
  two structs apart, Pyking does not need to copy, because neither can
  change.
- **A `var` is a variable in C's sense: a place.** Without pointers,
  the only ways to reach it are its own name and the functions that
  captured it (`bump` above). A function cannot be given a caller's
  `var` to write. Pyking has no reference parameters, the same rule as
  in C and Java. The idiom is to return the new values and store them
  with one `:=`, as in `q, r := divmod(17, 5)` (PYKING.md, "Mutable
  variables").
- **Copying shared things is explicit.** `copy(x)`, a slice `a[i:j]`,
  `array(a)` and `Point(x = 1, ..p)` make new things. Each of those is
  *shallow*: an array or `mutable struct` held inside is shared by both.
  `deepcopy(x)` shares nothing writable with `x` (PYKING.md, "Copying"). A view
  (`view(a, i, j)`) is the reverse: it aliases a run of an array on
  purpose. It is the safe replacement for C's `p + i`.
- **There is no `null`.** A field that may hold nothing has an
  `Option` type. A linked structure ends in a datatype case such as
  `End`, never in a null reference.
- **Identity and equality are separate.** `same` is identity. `==` is
  refused on a `mutable struct` and calls `eq` on an object. Pyking
  never compares shared things by contents unless the program says
  how.

## Pyking: objects are references

Under `use objects`, objects follow Java's semantics in Python's
spelling. Every object is shared by every name, element and field
holding it:

```pyking
use objects, mutation

class Account(owner: String):
    var balance: Int = 0
    def deposit(self, n: Int) -> ():
        self.balance := self.balance + n

def pay(a: Account) -> ():
    a.deposit(10)

acc = Account("ada")
other = acc
pay(other)
print(acc.balance, same(acc, other))      # 10 true
```

Compared with Java:

- **The same:** objects exist only behind references, dereferencing is
  implicit (`a.deposit`, `self.balance`), calls share the object,
  dynamic dispatch, and identity kept apart from equality (`same`
  versus `==`, which calls `eq`, Java's `equals`).
- **Different:**
  - There is **no `null`**. An `Account` always is one, and
    `Option(Account)` says "maybe none".
  - An object with no `var` field **never changes**, so sharing it is
    as unobservable as sharing a list.
  - Writing a field needs a `var` field *and* `use mutation`.
  - Downcasts happen only through `match` patterns (`case c: Circle:`),
    never through a cast that can fail.
  - `==` is refused unless the class defines `eq`, where Java silently
    falls back to identity.
- **Compared with C:** an object is what C would write as a `struct *`
  from `malloc` that is never freed and never null, without `->` and
  without arithmetic. The C backend compiles it as exactly that, a
  pointer to a struct that starts with its class descriptor.

Objects and `mutable struct`s are the same idea at two sizes: a shared
record with writable fields. Objects add methods, inheritance and
interfaces.

## Pyking: pointers, when enabled

`use mutation, pointers` adds C's pointers for teaching how memory is
addressed. Pyking keeps C's notation and C's power to point at a
*variable*, and removes everything that makes C's pointers unsafe.

```pyking
use mutation, pointers

mutable struct Point(x: Int, y: Int)

def swap(a: Ptr(Int), b: Ptr(Int)) -> ():
    t = *a
    *a := *b
    *b := t

var x = 1
var y = 2
swap(&x, &y)
print(x, y)                    # 2 1

p = &x
q = &x
*p := 5
print(x, *q, p == q, p)        # 5 5 true Ptr(5)

pt = Point(1, 2)
px = &pt.x
*px += 10
print(pt)                      # Point(11, 2)

a = array([1, 2, 3])
e = &a[1]
*e := 20
print(a)                       # array([1, 20, 3])

var r = &x
pp = &r
*pp := &y
print(*r)                      # 1, since r now points at y

var s = Point(0, 0)
ps = &s
*ps := Point(3, 4)
print(s, (*ps).x)              # Point(3, 4) 3

def counter() -> Ptr(Int):
    var n = 0
    &n

c = counter()
*c += 1
print(*c)                      # 1
```

**What is kept from C:**

- `&place` and `*p` are written as in C, and so is `(*pp).x`, where C
  would also allow `pp->x`.
- `Ptr(T)` is typed, and pointers to pointers (`Ptr(Ptr(Int))`) work.
- A pointer can name a **variable**, so `swap(&x, &y)` works, which
  Java cannot express. It can also name an array element (`&a[i]`) or
  a `mutable struct` field (`&p.x`).
- `p == q` is identity: both point at the same place.
- A pointer to a `var` that holds a `mutable struct` writes the `var`,
  not the struct. `*ps := Point(3, 4)` makes `s` hold a new struct,
  just as `*ps = ...` replaces what `s` holds in C. Writing a field
  through it is `(*ps).x := ...`.

**What is removed or made safe:**

| C hazard | Pyking |
|---|---|
| `NULL` | none. `Option(Ptr(T))` is a pointer that may be absent, and `match` decides which before use |
| arithmetic, `p + 1`, `p[i]` | refused. A run of an array is a view |
| `malloc`/`free` | none. Memory is the language's to manage |
| a dangling pointer to a returned local | the `var` lives as long as a pointer to it (`counter` above). Plain C targets refuse the program, and `c23-gc` moves the variable to the collected heap |
| a pointer into a growable buffer | `&d[i]` on a DynArray is refused, because its elements move when it grows |
| a pointer to a constant | `&` of an `=` binding, a list element, a plain struct field, a literal or a call result is refused: none of these is a place |
| casts, `void *` | none. `Ptr(T)` is one type |
| printing an address | a pointer prints what it points at, `Ptr(5)`, so every target prints the same |

The table shows the design choice: Pyking's pointer is C's pointer
reduced to the *safe* part of the idea, a typed name for a writable
place. Every target can run that, including Python, JavaScript, Java
and OCaml, which have no pointers. On those targets a pointer is a
small object holding the place's container and slot, with `get` and
`set` (docs/pointers.md, "What each target makes of them").

## One task, five ways: swap and move

The two classic tests of indirection are swapping two of the caller's
variables, and changing a record the caller holds.

| | swap the caller's `x` and `y` | change the caller's record |
|---|---|---|
| C | `swap(&x, &y)` with `int *` parameters | pass `&rec`, write `p->x`. Passing `rec` changes only a copy |
| Java | impossible. Return the pair, or wrap the values in an object or array | pass the reference, write `p.x`. Every object is shared |
| Pyking, no extensions | impossible, by design. Return a tuple and write `x, y := y, x` | impossible: a plain `struct` never changes. Build a new one with `Point(x = ..., ..p)` and return it |
| Pyking, `use mutation` | `x, y := y, x`, or a function returning the pair | a `mutable struct` (or array) is shared: pass it and write `p.x := ...`, as in Java |
| Pyking, `use objects` | as above | an object with a `var` field: as in Java |
| Pyking, `use mutation, pointers` | `swap(&x, &y)` with `Ptr(Int)` parameters, as in C | as with `use mutation`, or through a pointer to the field, `&p.x` |

## The comparison table

| | C pointer | Java reference | Pyking shared values (`mutable struct`, array, …) | Pyking object | Pyking pointer |
|---|---|---|---|---|---|
| Needs | nothing | nothing | `use mutation` to make or write. Reading and passing need nothing | `use objects` (and `use mutation` for `var` fields) | `use mutation, pointers` |
| Written as type | `T *` | the class name | `Point`, `Array(T)`, … | the class or interface name | `Ptr(T)` |
| Made by | `&x`, `malloc`, an array decaying | `new C(...)` | a constructor, `array(...)`, … | the class's constructor | `&place` |
| Can point at | any object in memory: a variable, a field, an element, the heap | a whole object or array only | (it *is* the shared thing) | (it *is* the shared thing) | a `var`, an array or view element, a `mutable struct` field, `*p` |
| Dereference | explicit: `*p`, `p->f` | implicit: `r.f` | implicit: `p.x`, `a[i]` | implicit: `o.f`, `o.m()` | explicit: `*p`, `(*p).f` |
| Assignment `b = a` | copies the address: aliases | copies the reference: aliases | binds a new name to the same thing: aliases | aliases | aliases (both name one place) |
| Plain records | copied by value | (no value records before Java's `record`s, which are still references) | a plain `struct` is a value that never changes | — | — |
| Passing to a function | by value: the pointer is copied | by value: the reference is copied | the thing is shared, and the callee cannot rebind the caller's name | as in Java | as in C |
| Changes a caller's local variable | yes, via `&x` | no | no | no | yes, via `&x` |
| Null | `NULL`, unchecked | `null`, `NullPointerException` | none. `Option(T)` | none. `Option(C)` | none. `Option(Ptr(T))` |
| Arithmetic | yes | no | no. A view stands for a run of an array | no | no. Refused with a hint to use a view |
| Bounds checking | none | always | always (except plain C targets) | — | — |
| Lifetime | manual (`free`) or stack. Can dangle | garbage collected. Never dangles | managed. Never dangles | managed. Never dangles | managed. A pointed-at `var` lives as long as the pointer. Plain C refuses an escaping one |
| Identity test | `p == q` | `r == s` | `same(a, b)` | `same(a, b)` | `p == q` |
| Contents equality | by hand, `memcmp` | `equals` | by hand (`==` is refused on `mutable struct`) | `==` calls the class's `eq` | `*p == *q` |
| Casts | free, including to integers | checked downcasts | none | `match` patterns only | none |
| Printing | the address (`%p`) | `Class@hash` unless `toString` | the contents, `Point(2, 2)`, with `...` for a cycle | the header fields or `show` | the target, `Ptr(5)` |
| Purpose | systems programming, memory layout | sharing objects safely | state changed in place, Java-style | Java-style object-oriented programming | teaching C's memory model safely |

## Living without null

Java gives every reference type an extra value, `null`. C does the same
for every pointer type with `NULL`. Pyking has neither. A type means
exactly its values: a `Point` is always a point, a `Ptr(Int)` always
points at an Int, and an `Account` is always an account. "Maybe
nothing" is a type of its own, `Option(T)`, whose values are `None`
and `Some(v)`. Taking a `Some` apart is done with `match`, or with the
`option` library (`unwrap_or`, `and_then`, `unwrap`, …).

Tony Hoare, who added null references to ALGOL W in 1965, later called
them his "billion-dollar mistake". Rust, Swift, Kotlin, Haskell and
OCaml all leave them out or keep them outside ordinary types. Pyking
follows them. The choice has a cost, though. The rest of this section
looks at what null is *used for* in C and Java, and what a Pyking
program writes instead.

### What null is used for, and what Pyking writes instead

**1. "There is no result."** A search that finds nothing, or a map
lookup with no entry. Java returns `null`. Pyking returns an `Option`,
and the caller has to say what happens in the `None` case before it
can use the value:

```pyking
def half(n: Int) -> Option(Int):
    if n % 2 == 0 then Some(n / 2) else None

match half(3):
    case Some(h): print("half is", h)
    case None: print("odd")          # odd
```

**2. "This link leads nowhere."** The end of a linked list, a leaf's
missing child, a node with no parent. C and Java use a null `next`.
Pyking ends the structure with a datatype case (`End`, as in "Mutable
structs" in PYKING.md), or with an `Option` field.

**3. "Not set yet."** In Java, a field or variable can start as `null`
and be filled in later. This is the case that costs the most without
null, and it is where the limitations below come from.

### The limitations

- **Every field and variable is initialised when it is made.** `var x`
  with no value does not exist. A class's fields are set from the
  constructor or from a body initialiser, never left empty. If the
  value really only exists later, its type has to say so
  (`Option(T)`), and every later use has to deal with `None`, even when
  the programmer knows it has been set by then.

- **Cycles take two steps and an `Option`.** Two objects that refer to
  each other cannot both be made first. Java writes `ada.partner =
  bob; bob.partner = ada;` with `partner` starting as `null`. Pyking
  needs the field to be `Option(Person)`:

  ```pyking
  use mutation

  mutable struct Person(name: String, partner: Option(Person))

  ada = Person("Ada", None)
  bob = Person("Bob", Some(ada))
  ada.partner := Some(bob)

  def partner_name(p: Person) -> String:
      match p.partner:
          case Some(q): q.name
          case None: "nobody"

  print(partner_name(ada), partner_name(bob))     # Bob Ada
  ```

  After construction, the program knows `partner` is always set, but
  the type still says it might not be. Every reader of the field pays
  for one moment during setup.

- **An array needs its elements up front.** Java's `new Point[n]` is
  an array of `n` nulls to be filled in later. Pyking has no empty
  slot to start from. The choices are:
  - an array of `Option`s;
  - an `array_init` that makes every element at once;
  - a DynArray that grows as elements are made;
  - a dummy value (`array(n, Point(0, 0))`), which brings back null's
    problem under another name.

  ```pyking
  use mutation
  import option

  mutable struct Point(x: Int, y: Int)

  slots: Array(Option(Point)) = array(3, None)
  slots[1] := Some(Point(1, 2))
  print(slots)                  # array([None, Some(Point(1, 2)), None])

  points = array_init(3, lam i. Point(i, 0))
  print(points)                 # array([Point(0, 0), Point(1, 0), Point(2, 0)])

  print(option.unwrap_or(slots[0], Point(0, 0)))   # Point(0, 0)
  ```

- **More words at each use.** Where Java writes `p.partner.name` and
  hopes, Pyking writes a `match` or an `option` call. Kotlin and Swift
  keep this short with `?.`, `?:` and `!!`. Pyking has no such
  operators yet, so a chain of possibly-missing values is a nested
  `match` or an `and_then` chain.

- **An escape hatch that fails anyway.** `option.unwrap(o)` and
  `option.expect(o, msg)` take the value without a `match`, and stop
  the program on `None` (`Runtime error: option.unwrap of None`). That
  is the `NullPointerException` again. It is a choice the program
  writes visibly rather than one hidden in every dereference, but
  overusing it gives back exactly what null costs.

- **Some cost at run time on some targets.** On C, an `Option` is a
  small tagged struct passed by value, with no allocation. On Java and
  Python, a `Some` is an object of its own wrapping the value. A Java
  field that would be a nullable reference becomes a reference to a
  `Some` that holds the reference. This costs one extra allocation and
  one extra indirection. It rarely matters for teaching programs, but
  it is a cost that `null` does not have.

- **The boundary to other languages.** A function implemented in Java,
  JavaScript or Python (an external module) can still produce
  `null`/`None`/`undefined`. The Pyking side has no type that admits
  it. The external module's wrapper has to turn a possibly-missing
  result into an `Option` before it reaches Pyking code. If it does
  not, the Pyking guarantee is broken at that edge.

### Pros and cons

| | Without null (Pyking) | With null (Java, C) |
|---|---|---|
| A value of type `T` | is always a `T` | might be null; the type does not say |
| "Might be missing" | written in the type, `Option(T)`, and visible in every signature | invisible: documented, or discovered at run time |
| Forgetting the missing case | refused at compile time: a `match` must cover `None` | a `NullPointerException` (Java) or undefined behaviour (C), often far from where the null was made |
| Using a value known to be present | free: no check, no unwrapping | free, but every reader must trust it is present |
| Deferred initialisation | needs `Option` and a `match` at every use, or restructuring | simple: start with `null`, fill in later |
| Cyclic and mutually linked objects | an `Option` field and two steps | two plain assignments |
| Arrays filled in later | `Array(Option(T))`, `array_init`, or a DynArray | `new T[n]`, filled in later |
| Code length at each use | longer: `match`, `unwrap_or`, `and_then` | shorter |
| Run-time cost | none on C; one wrapper per `Some` on Java and Python | none |
| Pointers (`Ptr(T)`) | can always be dereferenced; `Option(Ptr(T))` when they may not | every dereference is a possible crash |
| Teaching | students learn to say what "nothing" means, and the checker helps | students meet the most common runtime error early and often |
| Talking to other languages | missing values must be converted at the boundary | the same `null` crosses freely, for better and worse |

### Summary

Leaving null out moves the "maybe missing" question from run time to
the type. Where a value may really be missing, the program is about as
long as before and much safer, because the checker makes every `None`
case handled. Where a value is missing only *for a moment*, such as
during set-up, in a cycle, or in an array still being filled, the
`Option` stays in the type forever after. That is the real limitation.
Languages without null soften it in two ways: operators like `?.`, and
late-initialisation forms like Kotlin's `lateinit` or Swift's implicitly
unwrapped optionals, which are checked once at first use. Pyking has
neither for now, and adding one would be a deliberate step back towards
null, so it should be weighed against the teaching goal.

## Observations

- **Pyking's sharing is opt-in by type.** C makes a programmer opt in
  with `*`, and Java opts every object in. Pyking decides by the
  declaration: `struct` or `mutable struct`, list or `Array`. A reader
  can tell from the type whether aliasing can be observed at all.
- **Pointers are the only way to alias a variable.** Everything else
  in Pyking aliases *data*. A `var` can be written through another
  name only with `&` (or by a function that captured it). That keeps
  C's most surprising kind of aliasing behind its own `use` line.
- **No null anywhere.** All three Pyking mechanisms use Option for
  "nothing", which removes the failure that C and Java share. What
  that costs is in "Living without null".
- **An object's `var` field has no address.** `&o.balance` is refused,
  while `&p.x` on a `mutable struct` is allowed. The error says the
  field is "of a struct or datatype that never changes", which is not
  accurate for an object's `var` field. Allowing `&o.f` for a `var`
  field, or at least rewording that message, is an open point.
- **`same` does not take pointers.** Pointer identity is `==`, while
  `same` serves the shared kinds. That matches C (`p == q`) and keeps
  `same` for things that have no `==` of their own, but it is one
  more thing to learn.

## When are Pyking's pointers useful?

When a program already has mutation and objects, does it need pointers
at all? Usually it does not. In the cases below, though, a pointer
says something that references cannot say directly.

The difference is in *what* each one can name:

- **A reference** names a *thing that was made to be shared*: an
  object, a `mutable struct`, an array. Whoever declared its type
  decided that it is shared.
- **A pointer** names a *place*: a `var`, one element of an array, or
  one field of a `mutable struct`. The place does not have to be
  declared as shared. Any such place can be pointed at, and a function
  given the pointer neither knows nor cares which kind of place it is.

So pointers help when the thing to be written is not a shared object
but a *slot*, whether a variable or a slot inside something, and when
code should work for many such slots.

### 1. One function for many kinds of places

A function that updates "some Int somewhere" works the same for a
variable, an array element and a struct field:

```pyking
use mutation, pointers

mutable struct Player(name: String, score: Int)

def add_capped(p: Ptr(Int), n: Int, cap: Int) -> ():
    *p := if *p + n > cap then cap else *p + n

var total = 0
scores = array([5, 9])
ada = Player("Ada", 3)
add_capped(&total, 7, 10)
add_capped(&scores[1], 4, 10)
add_capped(&ada.score, 20, 10)
print(total, scores, ada)       # 7 array([5, 10]) Player("Ada", 10)
```

Without pointers there are three ways to write this:

- three functions, one for each kind of place;
- wrapping every counter in a shared cell (below);
- passing a getter and a setter:

```pyking
use mutation

def add_capped(get: () -> Int, set: (Int) -> (), n: Int, cap: Int) -> ():
    set(if get() + n > cap then cap else get() + n)

var total = 0
def set_total(v: Int) -> ():
    total := v
add_capped(lam (). total, set_total, 7, 10)
print(total)                    # 7
```

The getter and setter pair is exactly what a pointer *is*. The Python,
JavaScript, Java and OCaml backends compile a pointer into an object
with `get` and `set` over a container and a slot (docs/pointers.md).
With pointers, the language writes that pair for the program.

### 2. Choosing at run time which variable to update

```pyking
use mutation, pointers

var evens = 0
var odds = 0
for n in [1, 2, 3, 4, 5]:
    counter = if n % 2 == 0 then &evens else &odds
    *counter += n
print(evens, odds)              # 6 9
```

Without pointers, the update is written twice, once in each branch of
an `if`. Or the two counters become one array, chosen by index
(`sums[n % 2] += n`), which works but gives up the two names. With two
counters this hardly matters. It matters when the update is long, or
when the choice is made in one place and the update happens in
another, so that the program needs to carry *which variable* around
as a value.

### 3. Removing from a linked list: the pointer to a link

This is C's classic pointer-to-pointer technique. To remove a node, a
program must change whatever link leads to it. For the first node that
link is the list variable itself, and for any later node it is the
`next` field of the node before. A pointer can name either, so one
loop handles both:

```pyking
use mutation, pointers

datatype Link:
    End
    Next(node: Node)

mutable struct Node(value: Int, next: Link)

def remove(start: Ptr(Link), v: Int) -> ():
    var at = start
    var looking = true
    while looking:
        match *at:
            case End:
                looking := false
            case Next(node):
                if node.value == v:
                    *at := node.next
                    looking := false
                else:
                    at := &node.next

var list = Next(Node(1, Next(Node(2, Next(Node(3, End))))))
remove(&list, 1)
remove(&list, 3)
print(list)                     # Next(Node(2, End))
```

Without pointers, the first node is a special case. The function
returns the new list, and the loop keeps track of the node *before*
the one it looks at:

```pyking
use mutation

datatype Link:
    End
    Next(node: Node)

mutable struct Node(value: Int, next: Link)

def remove(list: Link, v: Int) -> Link:
    match list:
        case End:
            End
        case Next(first):
            if first.value == v:
                first.next
            else:
                var prev = first
                var looking = true
                while looking:
                    match prev.next:
                        case End:
                            looking := false
                        case Next(node):
                            if node.value == v:
                                prev.next := node.next
                                looking := false
                            else:
                                prev := node
                list

var list = Next(Node(1, Next(Node(2, Next(Node(3, End))))))
list := remove(list, 1)
list := remove(list, 3)
print(list)                     # Next(Node(2, End))
```

Both versions are correct. The pointer version has one case where the
other has two, and it is the shape a C textbook uses. The same
technique inserts into a sorted list, or links a new node into a
binary search tree, where `&node.left` or `&node.right` is "where the
new node goes".

### 4. A cursor into data that may be in several containers

`first_negative` in docs/pointers.md answers an `Option(Ptr(Int))`: the
place where something was found, which the caller can then write
through. An index does the same for a single array. A pointer is
better when the place could be in different containers, such as either
of two arrays or a field. The caller then writes `*p := 0` without
knowing where `p` points.

### 5. Teaching C, and translating from it

The main purpose of `use pointers` is to teach C's memory model:

- addresses, `&` and `*`;
- out-parameters, `swap`, pointer-to-pointer;
- why a pointer to a returned local is dangerous (plain C targets
  refuse it, and `c23-gc` keeps the variable alive).

A C algorithm written with pointers can be moved into Pyking almost
line by line. It then runs safely on every target, and the C backend
compiles it to real C pointers that students can read.

### When references are enough

For most programs with mutation or objects, pointers add nothing:

| What the program needs | Without pointers | Pointers needed? |
|---|---|---|
| state shared between parts of a program | a `mutable struct` or an object, passed around | no |
| a function that changes the caller's data | pass the shared object, and write its fields | no |
| a function that "returns" several values | return a tuple, and store it with `a, b := f()` | no |
| a function that updates a variable | return the new value and write it with `:=`; or a closure that captured the `var` | rarely |
| one value that several parts update | a cell, `mutable struct Cell(value: T)`, which is a hand-made reference to one value (Java writes `int[1]` or `AtomicInteger`) | no |
| a position in an array | an index | rarely |
| a callback that updates state | a closure over a `var` | no |
| one function for any variable, element or field | a getter and setter, or one function per kind of place | convenient: §1 |
| choosing which variable to update at run time | an `if` with the update twice, or an array with an index | convenient: §2 |
| changing "whatever link leads here" in a linked structure | special-case the first node, or keep the previous node | convenient: §3 |
| learning or translating C | — | yes: the reason they exist |

The cell is worth a closer look, because it shows exactly where a
pointer and a reference differ:

```pyking
use mutation

mutable struct Cell(value: Int)

def add(c: Cell, n: Int) -> ():
    c.value += n

total = Cell(0)
add(total, 7)
add(total, 5)
print(total.value)              # 12
```

A `Cell` does what `Ptr(Int)` does for this program, but the value had
to be *made* a `Cell` from the start. Every use reads `total.value`,
and an array element or an existing field cannot be turned into a
`Cell` after the fact. A pointer leaves the data as it was declared,
and `&` points into it only where the program needs that.

**In short:** pointers are never strictly necessary. Every Pyking
program with them can be rewritten using cells, closures, indices or
returned values, and that is how most backends implement them. They
are worth having for two reasons:

- They teach C's model honestly and safely.
- In a few patterns they remove a special case or a pair of helper
  closures: generic updates of a place, choosing a variable at run
  time, and pointer-to-link algorithms on linked structures and trees.

In everyday code with mutation and objects, references are enough.
