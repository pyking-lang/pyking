# `const` parameters, and what else mutation and objects lack

Status: design discussion (November 2026). Nothing here is
implemented.

This note answers two questions:

1. Should a parameter be able to promise that the function will not
   change what it is given, even when it is given a shared value such
   as an object or an array?
2. What else is missing from Pyking's mutable and object-oriented part?

design/refpointers.md is the background. It explains which Pyking
values are shared (arrays, DynArrays, MutMaps, views, `mutable
struct`s, objects) and which can never change.

Every Pyking example below was run with the current compiler, and the
outputs and error messages shown are the real ones.

## Contents

1. [The question](#1-the-question)
2. [What Pyking guarantees today](#2-what-pyking-guarantees-today)
3. [What a `const` promise has to settle](#3-what-a-const-promise-has-to-settle)
4. [Other languages](#4-other-languages)
5. [Design alternatives](#5-design-alternatives)
6. [Recommendation](#6-recommendation)
7. [What else is missing in the mutable and object-oriented part](#7-what-else-is-missing-in-the-mutable-and-object-oriented-part)

## 1. The question

```pyking norun
def total(const scores: Array(Int)) -> Int:
    ...                     # may read scores, never write it
```

The aim is a promise that is visible in the signature and checked by
the compiler: *this function only reads its argument*. A caller who
hands over an array, a `mutable struct` or an object then knows it
comes back unchanged, without reading the body. That is useful to
programmers and to teaching. "Who may change this?" is the central
question of programming with mutation, and a signature that answers it
is documentation the compiler checks.

The rest of this note is about how to make that promise mean
something.

## 2. What Pyking guarantees today

### Parameters are already "final"

A parameter is never a `var`, so a function cannot rebind it. Java's
`final` parameters, and JavaScript's `const`, already hold for every
Pyking parameter. The question is only about writes *through* a
parameter into shared data.

### Most values cannot change at all

Lists, tuples, Maps, plain `struct`s, datatypes and Strings never
change. A parameter of one of these types needs no promise. `const`
would matter only for the shared kinds.

### The `use mutation` gate is not a `const`

A module without `use mutation` cannot write an element, a field or a
`var` itself. It cannot even call a builtin that writes:

```
'l3.pyk' 2:4-2:8 Parsing error: 'push' changes a DynArray or a MutMap,
  which needs 'use mutation' at the top of this module
```

But it can call a *library function* or a *method* that writes. This
module has no `use mutation`, and sorts its caller's array anyway:

```pyking norun
import array

public def s(a: Array(Int)) -> ():
    array.sort(a)               # the caller's array is now sorted
```

The same goes for calling a method like `c.bump()` that writes a `var`
field. So the gate limits what a module *writes in its own text*. It
does not limit what happens to the data a module is given.

### Read-only interfaces already work for objects

A class can implement an interface that has only the reading methods,
and a function can take the interface:

```pyking
use objects, mutation

interface ReadCounter:
    def value(self) -> Int

class Counter() implements ReadCounter:
    private var n: Int = 0
    override def value(self) -> Int:
        self.n
    def bump(self) -> ():
        self.n := self.n + 1

def report(c: ReadCounter) -> String:
    "count = " + string(c.value())

c = Counter()
c.bump()
print(report(c))                # count = 1
```

Calling `c.bump()` in `report` is refused, which is the promise
wanted:

```
Type error: 'ReadCounter' has no field or method 'bump'
```

The pattern has two weaknesses. Every class needs a hand-written
interface for its read-only part. And a class pattern removes the
restriction again, the way `const_cast` does in C++:

```pyking
use objects, mutation

interface ReadCounter:
    def value(self) -> Int

class Counter() implements ReadCounter:
    private var n: Int = 0
    override def value(self) -> Int:
        self.n
    def bump(self) -> ():
        self.n := self.n + 1

def sneaky(c: ReadCounter) -> ():
    match c:
        case k: Counter: k.bump()
        case _: ()

c = Counter()
sneaky(c)
print(c.value())                # 1
```

Arrays, DynArrays, MutMaps and `mutable struct`s have no such
interface, so for them nothing can be expressed today.

### Defensive copies

A function that must not affect its caller's data can copy it first:
`array.copy(a)`, or `list(a)`, which makes an immutable list. A
`mutable struct` can be copied with `Point(..p)`. This is safe but
costs a copy, protects only shallowly, and promises nothing to the
caller, since the signature says nothing about it.

## 3. What a `const` promise has to settle

These are the questions every design below answers in some way.

**Q1. What counts as a write?** A write can happen in several ways:

- directly: `a[i] := v`, `p.x := v`, `o.f := v`;
- through a builtin: `push`, `pop`, `insert`, `copy_into`, …;
- through a library function, such as `array.sort(a)`;
- through a method that writes `self`;
- through a pointer: `&a[i]`, then `*p := v`;
- through another function the value is passed to, or one it is
  stored in or captured by, which writes it later.

A promise that misses any of these is worthless. In particular, the
last item means the analysis cannot stop at the function's own body.

**Q2. Shallow or deep?** `const a: Array(Point)` with `Point` a
`mutable struct` raises the question: may the function write
`a[0].x`?

- *Shallow* const (C, C++, TypeScript `readonly`, JavaScript
  `Object.freeze`) protects only the array's own slots.
- *Deep* or *transitive* const (D, and Rust's `&`) protects everything
  reached through it.

Shallow is easier to implement but surprises learners: "const, yet my
points changed." Deep matches the plain reading of the promise.

**Q3. Is it part of the type?** If `const` is in the type, then:

- `(const Array(Int)) -> Int` is a different function type from
  `(Array(Int)) -> Int`;
- a `const` value may be given to a function value only if that
  function's type is `const`;
- generic functions need "const polymorphism" (C++ writes two
  overloads, and D has `inout` for this).

If it is *not* part of the type, it is a checked property of a `def`.
The compiler checks it when the function is called by name, and must
be conservative when the function is called through a value.

**Q4. Methods.** For `o.m()` on a `const o`, the checker needs to know
whether `m` writes `self`. It can find out in two ways:

- it can *infer* this from the body, where there is one;
- it can be *declared*, which is needed for an interface's and an
  abstract class's methods, since those have no body.

Then overriding needs a rule: a read-only method cannot be overridden
by one that writes.

**Q5. What exactly is promised?** "This function does not write
through this name" is *read-only access*. It is **not** immutability.
While the function runs, another alias can still change the data: a
callback it was given, a global `var` holding the same array, or the
caller's own code through a pointer. C++, Kotlin, C# and TypeScript
all promise only read-only access, and their users regularly confuse
it with immutability. Only Rust (exclusive `&mut`) and D (`immutable`
as distinct from `const`) promise more, at a large cost.

**Q6. Escapes.** These are all ways to get a writable alias from a
read-only one:

- a class pattern (`case k: Counter`);
- taking a pointer (`&a[0]`);
- storing the value in a `var`, field or array;
- capturing it in a closure;
- returning it.

Each one must be refused, or make its result read-only too.

**Q7. Messages.** A refusal should name what writes, and where, for
example "`array.sort` changes the array it is given, and `scores` is
`const` here". It should not merely say that a type does not match.

**Q8. Targets.** This is a compile-time check only. No backend needs to
change, and no program runs any differently. The C backend could emit
`const` on pointer parameters, but nothing depends on that.

## 4. Other languages

| Language | Mechanism | Deep? | In the type? | Can be escaped | Notes |
|---|---|---|---|---|---|
| C | `const T *p` | no: each pointer level separately | yes | casting it away | protects through *this* pointer only; the data may still change through another |
| C++ | `const T&`, `const` methods, `mutable` fields | no: a pointer member's target stays writable | yes | `const_cast`, `mutable` | "const correctness" spreads through a code base: once one function takes `const&`, everything it calls must too; methods are often written twice, const and not |
| Java | `final` parameters and fields; `Collections.unmodifiableList` | no | `final` is not; unmodifiable lists fail at run time | — | `final` stops only rebinding (Pyking already has that). Unmodifiable views throw `UnsupportedOperationException`; the type is still `List` |
| Kotlin | `val`/`var`; `List` vs `MutableList` | no | yes: separate read-only interfaces | casting to `MutableList` | `List` is a read-only *view*, not immutable: the same object may be a `MutableList` elsewhere |
| C# | `readonly` fields and structs, `in` parameters, `IReadOnlyList<T>` | no | yes | casting | `in` is for value types (a read-only reference to a struct) |
| TypeScript | `readonly T[]`, `Readonly<T>` | no (`Readonly` is shallow) | yes, compile time only | assigning to a mutable alias is allowed | erased before run time |
| D | `const` and `immutable`, both transitive | yes | yes | casting (undefined behaviour) | the only mainstream deep const; `immutable` promises that nobody writes, `const` only that *this* name does not; `inout` avoids duplicate functions |
| Rust | `&T` vs `&mut T`, with borrowing | yes, except where a type opts out (`Cell`, `RefCell`) | yes | the opt-out types (`Cell`, `RefCell`) | `&T` also rules out *other* writers while it lives, so it means "unchanged during the call"; the price is the borrow checker |
| Swift | value types (`struct`, `Array`) copied on write; `inout` for writable parameters | for value types, yes | yes | — | parameters are constants; mutating a caller's data must be marked `inout` at both ends; classes have no const |
| Ada | parameter modes `in`, `out`, `in out` | `in` covers the value; an access (pointer) target only with `access constant` | yes | — | the mode is the promise, and is required on every parameter |
| Fortran | `intent(in)` | yes, for the argument | yes | — | the same idea as Ada's `in` |
| OCaml | immutable by default; `mutable` fields, arrays | — | — | — | no const; read-only access is given by an abstract type in a module signature exposing only readers |
| Python | none; `tuple`, `frozenset`, `@dataclass(frozen=True)`; `Sequence` vs `MutableSequence` in type hints | no | type hints, checked by mypy only | anything | read-only protocols are common in typed Python |
| JavaScript | `Object.freeze` | no | no: a runtime check | — | `const` only stops rebinding |

Three families stand out:

1. **Type qualifiers** (C, C++, D, TypeScript): `const` changes the
   type. This is precise and composes with function values, but it
   spreads through every signature, needs const and non-const
   versions of functions, and is shallow except in D.
2. **Read-only interfaces** (Kotlin, C#, typed Python): a supertype
   with only the reading operations. It fits languages with
   subtyping, but promises only a view, and a cast removes it.
3. **Parameter modes** (Ada, Fortran, Swift's `inout`): the promise
   belongs to the parameter, not the type. It is simple to read and
   to teach, but harder to apply to function values and stored
   references.

Rust's ownership is a fourth family. It is the only design that also
excludes other writers, and it is far beyond Pyking's scope.

## 5. Design alternatives

### A. Nothing new: conventions, read-only interfaces and copies

Document the read-only interface pattern from §2, and the habit of
taking a copy where it matters.

| Pros | Cons |
|---|---|
| no new syntax or checker work | no help at all for arrays, DynArrays, MutMaps and `mutable struct`s |
| the pattern teaches interfaces | every class needs a hand-written read interface |
| | a class pattern removes the restriction |
| | a copy costs time and protects only shallowly |

### B. Inferred "writes" information, shown but not declared

The compiler works out, for every `def`, which parameters it may write
through, deeply. For calls through unknown function values it assumes
the worst. The result is shown, not declared:

- in a hover: `total(scores: Array(Int)) -> Int · reads scores`;
- in the REPL's `:type`;
- in the library pages.

| Pros | Cons |
|---|---|
| no new syntax | promises nothing: a later edit can make a function write, and no caller is told |
| every function gets the information for free | needs the analysis in C (below) anyway |
| a good first step that C builds on | |

### C. A `const` (or `readonly`) parameter mode, checked by analysis, not in the type

```pyking norun
def total(readonly scores: Array(Int)) -> Int:
    var sum = 0
    for s in scores:
        sum += s
    sum
```

The mode is a promise about the `def`, in the Ada and Fortran style.
A pass after type checking, which knows the types, checks it:

- **Deep.** Everything reached from the parameter is read-only: an
  element read from it, a field of it, a name bound to a part of it in
  a `for` or a `match`, and a method's result when that result's type
  can hold shared data. These are all "read-only names" too.
- **No writing.** A direct write to a read-only name is refused, and
  so is `push` or any other writing builtin on one.
- **Calls are checked against the callee's modes.** A read-only name
  may be passed to a `def` only at a parameter that is itself
  `readonly`, or that the analysis has inferred to be read-only, for
  functions in the same module. Library functions and builtins carry
  their modes.
- **Methods.** A method is read-only if its body writes nothing
  through `self` and calls only read-only methods. This is inferred,
  as a fixpoint over the class. An interface or abstract method
  declares it (`def value(readonly self) -> Int`), and an override
  must keep it.
- **Escapes are refused**, each with its own message: `&` on a
  read-only place, storing a read-only name in a `var`, field, array
  or MutMap, capturing it in a lambda or nested `def`, passing it to
  a function *value*, and a class pattern binding it at a class.
  Returning it is allowed only from a function whose result is
  `readonly` too, or refused in a first version.
- **Not in the type.** `total` still has the type
  `(Array(Int)) -> Int`, so inference and every backend are
  untouched. Holding `total` as a value drops the promise. That is
  safe: the promise is about what the *body* does, and the body is
  checked.

| Pros | Cons |
|---|---|
| one keyword | function values do not carry the promise, so a higher-order function cannot require "give me a function that only reads" |
| deep, so it means what a learner expects | refusing every escape (closures, function values) will refuse some correct programs; the messages must say why, and how to write it instead |
| no change to the type system or backends | the analysis is a new pass with its own fixpoint over calls and methods |
| errors can name the exact write | it promises read-only access, not "unchanged during the call" (Q5) |
| matches the existing style of checks that are not about types (mutability is a Name error today, not a type) | |

### D. Read-only types (the Kotlin and C# route)

Add types `ReadArray(T)`, `ReadDynArray(T)` and `ReadMutMap(K, V)`,
or one `View(T)`, as supertypes of the writable ones, and allow the
upcast at a declared parameter, exactly where a class is upcast to an
interface today.

| Pros | Cons |
|---|---|
| in the type, so it works for function values, fields and lists of them | shallow: `ReadArray(Point)` still lets `a[0].x := 1` through |
| reuses the existing upcast rule | a new type per collection, plus every library function written for both |
| familiar from Kotlin, C# and Python's `Sequence` | `mutable struct`s get nothing unless each one gets a `Read` type too |
| | class patterns still escape for objects |

### E. A `Readonly(T)` type operator, deep (the D route)

`Readonly(T)` turns every shared type inside `T` into its read-only
counterpart, recursively, and `T` upcasts to `Readonly(T)`.

| Pros | Cons |
|---|---|
| in the type and deep: the most precise promise | type inference needs qualifier subtyping everywhere, not only at annotations |
| | generic functions need `inout`-style polymorphism over read-only-ness |
| | error messages full of `Readonly(...)` types |
| | a large change to the checker and every message |

### F. A runtime freeze

`freeze(a)` marks an array, struct or object so that any later write
fails at run time, as in JavaScript (`Object.freeze`) and Ruby.

| Pros | Cons |
|---|---|
| simple to explain | a runtime error instead of a compile-time one, which goes against Pyking's checked style |
| catches every write, however it is made | a check on every write on every target (C, Java, OCaml, …), which is slow and a lot of work |
| | permanent: it freezes the data, not one function's view of it |

### G. Swift-style value semantics, with copy on write

Make arrays and `mutable struct`s behave as values. A parameter then
gets a logical copy, and writing a caller's data needs an explicit
`inout`.

| Pros | Cons |
|---|---|
| no aliasing surprises at all | it reverses the semantics Pyking has chosen, Java's and Python's, which the generated code mirrors |
| | changes the meaning of every existing program |
| | needs copy-on-write on every target |

## 6. Recommendation

1. **Now: alternative A, written down.** Document the read-only
   interface pattern in PYKING.md ("Classes and interfaces"), and say
   plainly that `use mutation` does not protect data a module is given
   (§2). This costs nothing.
2. **Next: alternative B.** Infer "reads / writes" per parameter and
   show it in hovers, the REPL and the library pages. This is useful
   on its own and is the engine C needs.
3. **Then, if courses want the promise: alternative C**, with these
   choices:
   - a parameter mode, deep, not part of the type;
   - escapes refused with specific messages;
   - interface methods declare `readonly self`.

   Spell it **`readonly`** rather than `const`. In JavaScript and C++,
   `const` names a binding that cannot be rebound, which every Pyking
   `=` binding and parameter already is. `readonly` says what is
   promised: this name only reads. (`const` would still be accepted
   in an error message's hint, for those who try it.)

D and E are better saved for when Pyking needs read-only access in
*types*, for example fields and function values. The first course that
asks for "a list of read-only arrays" will show whether that time has
come. F and G go against the language's checked, Java-like reference
semantics.

Work for C, roughly:

- the parser and syntax: a modifier on parameters, kept by `-t pyking`;
- a new pass between the checker and elaboration, with the fixpoint
  over functions and methods;
- modes for builtins (in `builtin.ml`) and for the library functions;
- LSP hover and completion;
- the editor grammars;
- PYKING.md and the website;
- `fail_*` tests for every write and escape form in Q1 and Q6.

No backend changes.

## 7. What else is missing in the mutable and object-oriented part

These were checked against the current compiler. Items that
design/plan-objects.md §7 leaves out on purpose (method overloading,
static members, `protected`, inner classes, properties, operator
overloading, reflection) are not repeated here unless the reason has
changed.

### Gaps that limit real programs

| Missing | Today | Suggestion |
|---|---|---|
| **Classes across modules** | done since this note: `public class` and `public interface` (PYKING.md, "Classes across modules") | — |
| **Objects as Map/MutMap keys, and sets** | refused; there is no Set or MutSet type at all, objects or not | add `Set(T)`/`MutSet(T)` collections, and `def hash(self) -> Int` checked against `eq` (plan-objects.md §7 already sketches it) |
| **`for` over a user's collection** | `for x in Bag(...)` is refused; no iteration interface exists | an `Iterable(a)` interface (or an `items(self) -> [a]` convention) that `for` and comprehensions accept. Also, the message says "a 'for' loop walks a list or a String", which leaves out the arrays, DynArrays, MutMaps and views it does walk |
| **Read-only access** | only the interface pattern (§2) | §6 |
| **Constructor checks** | a constructor cannot check its arguments; validation lives in a factory function the class cannot require | plan-objects.md §11.4 option B, an `init:` block that may check and `panic` but not call methods |

### Gaps that make code longer

| Missing | Today | Suggestion |
|---|---|---|
| **Equality of `mutable struct`s** | `==` is refused and structs have no methods, so every comparison is a hand-written function | allow `def eq` for a `mutable struct` as for a class, or a builtin `equal(a, b)` comparing fields, deep and cycle-safe, as `print` already walks them |
| **Copying** | done since this note: the builtins `copy(x)` and `deepcopy(x)` (PYKING.md, "Copying") | — |
| **A pointer to an object's `var` field** | `&o.balance` is refused, while `&p.x` on a `mutable struct` is allowed; the message wrongly says the field never changes | allow it (it is a place like any other), or at least correct the message |
| **Generic methods and bounded generics** | a method cannot have type variables of its own; a type variable cannot be required to implement an interface | the plan's §11.12 already discusses the first; the second would let a `def` take any `a` that `implements Shape` without upcasting |
| **A standard cell** | everyone writes `mutable struct Cell(value: a)` | a small `ref` library type (`Ref(a)`, `get`, `set`), or say in PYKING.md that the one-line struct is the idiom |
| **Ordering objects** | `<` is refused; sorting needs a key function | fine as it is (plan-objects.md §11.11); `sort_by` covers it |

### Bugs found while checking

- **C backend** (fixed since). A datatype and a `mutable struct` that refer to each
  other, such as `datatype Link: End | Next(node: Node)` with `mutable
  struct Node(value: Int, next: Link)`, fail to compile on `c23-gc`
  ("field 'next' has incomplete type") when `Link` is reached before
  `Node`. `src/target_c.ml` writes `Node`'s struct before `Link`'s,
  although `Node` holds a `Link` by value. design/refpointers.md §13
  has a program that shows it.
- **The `&o.f` message** above.
- **The `for` message** above.
