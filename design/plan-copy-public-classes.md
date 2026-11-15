# Plan: `copy(x)`, `deepcopy(x)` and public classes

Status: implemented (November 2026): both parts, both phases of part 2.
The name is `deepcopy` (not `clone`), and a shallow `copy` comes with
it. PYKING.md, "Copying" and "Classes across modules", is the reference;
docs/modules.md, "Classes cross the boundary by name", and each target's
page say how. Where the implementation differs from the text below:

- **OCaml `deepcopy`** walks the value's own blocks at run time rather
  than a copier written per type (§1.3): OCaml objects, arrays and records
  are blocks it can copy, and a pointer is told by its method table.
- **`copy` also refuses a type variable** (§1.2a), as `deepcopy` does.
- **A definition with no annotations is not generalised** over a type it
  copies: its first use decides it, as for `+`.
- **C views** hold the whole array's length (`whole`), so a view is
  copied with the array behind it on C as on every other target.
- **OCaml class patterns** use exceptions (`exn`), the one extensible
  type every module shares, rather than a `pyk_obj` type per module.
- **Existing bugs fixed on the way:** the interpreter's classes of one
  name in two modules were one class; an override's call that leaves out
  an argument was refused rather than given the default from where the
  method is first declared; OCaml's `same` on two related object types
  did not compile, nor a member named after an OCaml keyword; and C's
  struct order for a datatype and a mutable struct holding each other.

This plan covers two features:

1. **`copy(x)` and `deepcopy(x)`**, builtins that make a shallow and a
   deep copy of any value.
2. **Public classes**: classes and interfaces that can be used,
   implemented and extended across modules.

The two are independent and can be built in either order. Part 1 is
smaller and goes first. Part 2 is a large change with two phases.

Decisions already taken (answers in this conversation):

| Question | Decision |
|---|---|
| a function value inside the copied data | **shared**: the copy holds the same function (Python's `deepcopy` does the same) |
| a pointer, `Ptr(T)`, anywhere in the type | **refused at compile time** |
| `deepcopy` where the type is only a type variable | **refused**, as `string(x)` is today |
| what another module may do with a public class | **everything, in two phases**: first using it, then implementing and extending it |

---

## Part 1: `copy(x)` and `deepcopy(x)`

### 1.1 Is it a good design?

Yes, with two cautions written into the documentation.

**For it:**

- **It completes the aliasing story.** design/refpointers.md shows that
  `=` and argument passing share arrays, `mutable struct`s and objects.
  Today a program can only copy those *shallowly* (`array.copy`,
  `Point(..p)`, slices), and cannot copy an object at all. `deepcopy` is
  the one way to say "a separate copy that shares nothing writable
  with the original".
- **One builtin for every type is the right shape.** A per-type
  `copy` cannot be written once for a generic `Array(a)`. A builtin
  that the compiler generates for each type at the call can, the same
  way `print` and `string` already work.
- **It is checked.** Since the type at the call is known, a program
  that deep-copies something that cannot be deep-copied (a pointer) is refused
  at compile time, not at run time.
- **It is good to teach with.** `same(deepcopy(a), a)` is `false`, and
  `deepcopy(a) == a` is `true` wherever `==` exists. Students can see the
  difference between identity and equality, and between shallow and
  deep, in two lines.

**Cautions:**

- **A deep copy copies everything reachable.** A `Player` that holds a
  reference to the whole `Game` drags a copy of the whole game along.
  This is the classic deep-copy pitfall, the same as in Python's
  `deepcopy`. PYKING.md will say so, with an example, and that a
  shallow copy is `copy(x)` (§1.2a).
- **The name.** `deepcopy` is Python's (`copy.deepcopy`) and says what
  it does. Java's `clone()` is shallow by default, so `clone` would
  mislead students on their way to Java. The shallow copy is `copy`,
  Python's `copy.copy` (§1.2a).

A class cannot customise its deep-copy in this plan. Java's `Cloneable` and
Python's `__deepcopy__` both show that a hook brings problems of its own
(when it is called, what it must copy). A class whose objects must not
be copied is rare in teaching code. §1.6 lists a possible later hook.

### 1.2 What it means

`deepcopy(x)` has the type `(T) -> T` and answers a value equal to `x`
that shares nothing writable with `x`.

| The value | What `deepcopy` gives |
|---|---|
| Int, Float, Char, Bool, String, `()` | the value itself |
| a list, tuple, Map, plain `struct`, datatype, Option, Result | a new one whose parts are deep-copied. Where the type holds nothing shared (`[Int]`, `Map(String, Int)`) this is the value itself: copying it would make no difference anyone could see, so it is not copied |
| an Array, a DynArray | a new one, with each element deep-copied |
| a MutMap | a new one, with the same keys (always immutable values) and each value deep-copied, in the same order |
| a view `Slice(T)` | a view, with the same bounds, of a deep-copy of the whole array behind it (see sharing below) |
| a `mutable struct` | a new struct, with each field deep-copied |
| an object | a new object **of its run-time class** (a `Shape` holding a `Square` deep-copies to a `Square`), with every field deep-copied, `private` and `var` fields included |
| a function | the same function (decision 1) |
| `Ptr(T)` anywhere in `T` | refused at compile time (decision 2) |

**Sharing and cycles are kept.** One deep-copy keeps a table of what it
has copied so far, keyed by identity, as Python's `deepcopy` does:

- If the same array is reached twice in `x`, the copy holds one new
  array, reached twice.
- A cycle (`a.next` leading back to `a`) gives a copy with the same
  cycle, and deep-copying always ends.
- A view and the array it is a view of, both inside `x`, give a view
  of the new array.

Only the shared kinds go in the table: arrays, DynArrays, MutMaps,
`mutable struct`s and objects. Everything else cannot be told apart
from a copy anyway.

**Where it is allowed:**

- in every module, with no `use` line. It changes nothing that
  exists, and a module without `use mutation` still cannot write the
  copy;
- only where the type is known at the call. `def f(x: a) -> a:
  deepcopy(x)` is refused with the message style of `string`: "'deep-copy'
  cannot be applied to a; it copies a value whose type is known where
  it is called". A type variable *inside* the type is refused the same
  way (`Array(a)`);
- `deepcopy(s)` on a `Stack(Int)`, an object of a generic class, *is*
  allowed, since its type is known at the call. Inside `Stack`'s own
  methods, `deepcopy(self.items)` has the type `[a]`, which is refused;
- not on plain C targets where the value itself cannot be made there.
  `deepcopy` follows each target's existing rules, so whatever a target
  can construct, it can deep-copy.

**Errors** (each a `fail_*` test):

- a pointer anywhere in the type, naming the path to it ("a
  `Node`'s field `p` is a `Ptr(Int)`; a pointer cannot be deep-copied");
- a type variable;
- the wrong number of arguments;
- `deepcopy` used as a value. Like every builtin, it can only be called.

### 1.2a `copy(x)`: the shallow copy

`copy(x)` has the type `(T) -> T` and makes a new *outermost* shared
value, whose parts are the original's own:

| The value | What `copy` gives |
|---|---|
| an Array, a DynArray | a new one holding the same elements (`array.copy(a)` for every collection) |
| a MutMap | a new one with the same entries, in the same order |
| a view | a view, with the same bounds, of a shallow copy of the array behind it |
| a `mutable struct` | a new struct holding the same field values (`Point(..p)` written for any struct) |
| an object | a new object of its run-time class, holding the same field values |
| anything else (Int, String, list, tuple, Map, plain `struct`, datatype, function, pointer) | the value itself: it is not shared-and-writable at the top, so a copy could not be told apart from it |

`copy` takes pointers (a copied struct holding a pointer holds the same
pointer) and needs no `use` line. Like `deepcopy`, it is refused where
the type is a type variable, since C and OCaml generate it per type.

### 1.3 How it is compiled

`deepcopy` is generated for each type, like `print`, because the targets
without run-time type information (C, OCaml) need the type at the call:

- **Type checker** (`typesystem.ml`): a new builtin rule, `(T) -> T`.
  It refuses a type variable or a `Ptr` inside `T`, with the messages
  above.
- **Interpreter** (`interpreter.ml`): a walk over the run-time value
  with an identity table (`VArray`, `VDynArray`, `VMutMap`, `VView`,
  structs and objects; physical equality on their stores).
- **Python and JavaScript**: one runtime function,
  `__pyk_deepcopy(x, memo)` / `pykDeepcopy`. It walks the run-time value, with
  `id()` or a `Map` as the identity table. No type information is
  needed.
- **Java**: a runtime method, `PykRuntime.deepcopy(Object, IdentityHashMap)`,
  dispatching on the run-time class. Every generated class and
  `mutable struct` gets a `pykDeepcopy(memo)` method that copies its own
  fields and calls its parent's for the parent's part.
- **OCaml**: a deep-copier generated per type, `deepcopy_<type>`, the way
  printers are generated today. A class gets a `pyk_deepcopy` method. A
  generic class's constructor already takes a printer per type
  parameter, and it takes a deep-copier per type parameter too. The identity
  table is an association list with physical equality, kept per kind.
  It is O(n²) on very large graphs, which is acceptable for a first
  version and will be noted in docs/target_ocaml.md.
- **C**: a deep-copier generated per type, as `show` is. The class
  descriptor gets a `deepcopy` entry beside `show`, so an object deep-copies as
  its run-time class. The identity table is a small open-addressing
  hash on pointers in the runtime. On `c23-gc` memory comes from the
  collector. On plain C it comes from `malloc` and is never freed, as
  plain C's `mutable struct`s are today.
- **The `pyking` target** prints `deepcopy(x)` back as written.
- **Release builds** keep it.

### 1.4 The rest of the system (CLAUDE.md)

- `builtin.ml`/`.mli`: the entry.
- `lsp.ml`: signature help and completion.
- REPL and DAP: nothing beyond the interpreter.
- Editor grammars: the builtin lists in Monaco, Ace, VS Code and Emacs.
- `src/highlight.ml`, if it lists builtins.
- PYKING.md:
  - "Builtins and I/O": the table row, and a new section `### Copying:
    deep-copy`, with the sharing and cycle rules, the deep-copy pitfall, and
    shallow copies for comparison;
  - "Mutable structs", "Arrays" and "Classes and interfaces": a line
    each pointing to it;
  - "Compared with Python": `copy.deepcopy(x)` → `deepcopy(x)`;
  - "Pyking vs. other languages": a row.
- `docs/builtin.md`, `docs/target_*.md` (each representation),
  CHANGELOG.
- design/refpointers.md and design/const.md: replace "nothing copies
  deeply" with `deepcopy`.

### 1.5 Tests

- `deepcopy_values.pyk`: every row of the table in §1.2, on every target.
  - Writing the copy leaves the original unchanged, and the reverse.
  - `same(deepcopy(a), a)` is false, and `deepcopy(x) == x` holds for
    comparable types.
- `deepcopy_sharing.pyk`: an array reached twice, a cycle of `mutable
  struct`s, a view together with its array, an object graph with
  subclasses seen as an interface, and a generic class at a known
  type.
- `deepcopy_functions.pyk`: a closure inside an object is shared, and a
  callback field still works.
- `fail_typecheck_deepcopy_pointer`, `_type_variable`, `_arity` and
  `_value`, each with its expected message.
- C targets: the same programs where the C rules allow them, and the
  existing "needs c23-gc" refusals elsewhere.
- `-t pyking` rerun, LSP completion lists, and the site examples.

### 1.6 Later, not now

- A `def deepcopy(self) -> C` hook in a class, called instead of the
  field-by-field copy, for classes holding handles or registries.
- A shallow `copy(x)` builtin for every shared kind, beside `deepcopy`.

---

## Part 2: public classes

### 2.1 Why it is not there already

design/plan-objects.md always meant `public class` to work. Its §3.7
says "`public class` exports it, its constructor and its public
members". The implementation stopped at the module boundary and
recorded why in the plan's status note: "Exporting one -- its table in
the module's signature, and each target reaching its constructor and
methods in another file -- is the next step." Today the parser refuses
it:

```
Parsing error: a class is used in the module declaring it: 'A' cannot
  be exported yet
```

Concretely, these pieces are missing:

1. **The signature has no room for classes.** What a module exports is
   its *sigmap*, a map from a name to a type (docs/modules.md). A
   class is not a type in that sense. It is an entry of the checker's
   class table (`class_info`: parent, interfaces, header, fields,
   methods with defaults, privacy). Datatypes went through the same
   step earlier (`TData` entries, canonical names `m.Tree`), and
   classes need the same thing.
2. **Every backend must reach a class in another file.** This is easy
   in Python, JavaScript and Java, where the host has modules or
   nested classes. It is real work in OCaml, where the class type,
   the constructor function and the downcast variant must appear in
   the `.mli`, and in C, below.
3. **C's method tables are numbered per module.** An object's table has
   one slot per method name *of the module* (`slots` in `target_c.ml`).
   An object made in module A and called in module B, or a class in B
   extending one in A, needs one numbering the whole program agrees
   on.
4. **Inheritance across files.** A subclass in B builds its parent's
   part, calls `super.m`, overrides methods, and inherits interface
   defaults from A. Each target lays out objects differently: C puts
   the parent's fields first, and OCaml builds objects with a
   function per class.
5. **Defaults of constructors and methods.** A call that leaves an
   argument out uses the default's code. docs/modules.md, "Default
   parameters cross the boundary", solves this for `def`s. Methods and
   constructors need the same.

None of these is a design problem. Together they touch the module
system, the checker and seven backends, which is why the work was
split off.

### 2.2 What it will look like

```pyking
# shapes.pyk
use objects

public interface Shape:
    def area(self) -> Float
    def name(self) -> String

public class Rect(width: Float, height: Float) implements Shape:
    override def area(self) -> Float:
        self.width * self.height
    override def name(self) -> String:
        "rectangle"
```

```pyking
# main.pyk
use objects
import shapes
from shapes import Rect

class Circle(r: Float) implements shapes.Shape:      # phase 2
    override def area(self) -> Float:
        3.14159 * self.r * self.r
    override def name(self) -> String:
        "circle"

class Square(side: Float) extends Rect(side, side):  # phase 2
    override def name(self) -> String:
        "square"

all: [shapes.Shape] = [Rect(2.0, 3.0), Circle(1.0), Square(2.0)]
for s in all:
    print(s.name(), s.area())
match all[0]:
    case shapes.Rect(w, h): print(w, h)
    case _: ()
```

Names work exactly as for datatypes, which already cross modules in
every form, as checked against the compiler: `shapes.Rect(...)`,
`from shapes import Rect`, a type `shapes.Shape`, and a pattern `case
shapes.Rect(w, h)`.

### 2.3 Design choices

**C1. What `public class` exports.**

| Option | Pros | Cons |
|---|---|---|
| **A. The class with every non-`private` member, and its constructor (Recommended; plan-objects §3.7)** | one word; `private` already says what is hidden | no way to export a class but hide its constructor |
| B. `public` on each member, as Java does | fine control | two meanings of `public` in one class body; verbose |
| C. As A, plus `private` on the header to hide the constructor (factory-only classes) | supports validated construction | one more rule; can be added later without breaking A |

**C2. What another module may do.** Decided: everything, in two
phases. Phase 1 is use: construct, call methods, read fields (and
write `var` fields, under `use mutation`), annotate types, hold
objects in collections, match class patterns, and use `same` and `==`
(through `eq`). Phase 2 is `implements` an imported interface and
`extends` an imported class, abstract classes included, with
`super.m` and overriding.

**C3. What a public signature may mention.** A public class's parent
and interfaces, and the types of its non-private fields and methods,
must themselves be public or imported. Otherwise the importing module
could not name them. This is the rule datatypes follow
(`check_exported_datatypes`), with the same kind of message. The
alternative, Java's "a public class may extend a package-private
one", is refused, because it lets a module hold values whose type it
cannot write.

**C4. `private` across modules.** It is unchanged: a private member is
reachable only from the methods of the class declaring it. Phase 2
adds one consequence, already true inside a module: a subclass in
another module cannot see or reuse a private member's name. Since
names of private members are now visible across files, the clash
message says that the member is a private member of the imported
class.

**C5. C's method table.**

| Option | Pros | Cons |
|---|---|---|
| **A. One slot numbering for the whole program: every method name of every module gets a slot (Recommended)** | the existing design with one list widened; `pyk` already compiles every module of a program together and hands each the others' signatures (`Module.Context`) | tables grow with the program's number of method names (classes × names pointers): fine for teaching programs |
| B. C++-style vtables: per class, inherited slots first, plus interface tables searched by an interface id | compact; the classic layout to teach | a different dispatch for interfaces; a larger rewrite of the backend |

**C6. OCaml.** A public class's class type, its constructor function,
its printer and deep-copier, and its case of the downcast variant go in the
module's `.mli`. A subclass in another module builds on the parent's
constructor function, which plan-objects' OCaml representation (§11.13)
already uses within a module.

**C7. Java.** Module classes already hold their classes as nested
classes. A public class becomes `public static`, and other modules
name it as `Shapes.Rect`. Nothing else changes.

**C8. Python and JavaScript.** Classes are module attributes or exports,
named as `shapes.Rect`. The JavaScript interface defaults that are
copied into implementing classes must be importable, so the interface's
defaults object is exported too.

**C9. The interpreter.** A class is looked up by canonical name
(`shapes.Rect`). The module's exported values carry its class table,
so a method call on an object made in another module finds its body.

### 2.4 Phase 1: using an imported class

- **Parser:** drop the refusal; `public` on `class`, `abstract class`
  and `interface`.
- **Module system** (`module.ml`):
  - sigmap entries for classes and interfaces, under the class's name;
  - canonical names `m.C` through `module_sigmap`, as for datatypes;
  - `from m import C` brings the class and its constructor;
  - the export checks of C3.
- **Checker** (`typesystem.ml`):
  - `declare_classes` reads imported entries into `classes`, by
    canonical name;
  - method calls, field reads, upcasts to an imported interface,
    class patterns, `eq` and `show`, defaults and named arguments of
    methods and constructors (extending "Default parameters cross the
    boundary");
  - exhaustiveness (`exhaustive.ml`): an imported class or interface
    is open, so `case _` is still needed.
- **Backends:**
  - Python, JavaScript and Java: qualified names (C7, C8);
  - OCaml: the `.mli` exports (C6);
  - C: the header exports the class descriptor and constructor, and
    the program-wide slot numbering (C5 A);
  - interpreter (C9);
  - the `pyking` target.
- **Tools:**
  - LSP hover, completion of an imported object's methods and fields,
    and go-to-definition into the other module;
  - REPL: `import` of a module with classes;
  - DAP: the Variables view of objects from another module;
  - the playground and notebook, which already read several modules.
- **Docs:**
  - PYKING.md: "Classes and interfaces" (remove "cannot be exported
    yet", and add a section "Classes across modules"), and "What a
    module may export";
  - docs/modules.md: "Classes cross the boundary by name";
  - docs/target_*.md, design/plan-objects.md status note, CHANGELOG.

### 2.5 Phase 2: implementing and extending across modules

- **Checker:**
  - `implements m.I` and `extends m.C(args)`;
  - override checks against the imported tables;
  - `super.m` into another module;
  - abstract classes;
  - interface defaults inherited from another module;
  - generic classes and interfaces (`implements m.Source(Int)`).
- **Backends:**
  - Python and Java: native inheritance across modules;
  - JavaScript: native `extends`, with the imported interface defaults
    copied in;
  - OCaml: the subclass's constructor function calls the imported
    parent's;
  - C: the parent's part of the layout comes from the imported
    header, and the descriptor's `parent` points to the imported
    descriptor;
  - interpreter: the inherited method bodies are found in the
    parent's module.
- **Tests and docs:** as phase 1, for every inheritance form.

### 2.6 Tests

Phase 1:

- `module_class_*` program cases, each a main module and one or more
  imported modules, run on every target:
  - construct, call, read and write fields, upcast to an imported
    interface;
  - match qualified and unqualified class patterns;
  - `eq`, `show` and `print`;
  - methods and constructors with defaults and named arguments;
  - generic classes (where the target supports them);
  - `deepcopy` of an imported object.
- `fail_typecheck_module_class_*` cases:
  - a private member from another module;
  - a public class with a non-public parent, interface or field type
    (C3);
  - a class pattern needing `case _`;
  - an unknown member.
- LSP: completion and hover for an imported object. REPL: an import
  with classes. DAP: object variables.

Phase 2, as further `module_class_*` cases:

- an imported interface implemented locally;
- an imported class extended, with an override, `super`, an abstract
  parent and a generic parent;
- a three-module chain;
- `fail_*` cases: overriding without `override`, a mismatched
  signature, a private name reused.

### 2.7 Risks

- **C.** The program-wide slot numbering changes every C program with
  classes. The C excerpts on the website (`tests/test_site.py`) and
  `docs/target_c.md` will change, and the plan includes updating them.
- **OCaml's recursive class types across files.** Two modules cannot
  depend on each other (imports are acyclic), so this cannot happen.
  A class in B extending A's class only needs A's `.mli`.
- **Size.** Phase 1 touches about fifteen files and phase 2 about ten.
  Both stay within the existing design: nothing in the checker's
  inference changes.

---

## Order of work

1. Part 1, `deepcopy`, complete with documentation and tests. One change.
2. Part 2, phase 1: using public classes. One change.
3. Part 2, phase 2: implementing and extending across modules. One
   change.
4. Separately, if wanted: the `c23-gc` struct-ordering bug from
   design/refpointers.md §13. It is small and independent, and could
   go before 1.

Each step ends with the full test suite on every target, and the site
suite run in the scratch copy as before.

Decisions taken at the go: the names are `copy` and `deepcopy`; C's
method table uses one slot numbering for the whole program (C5 A);
factory-only classes (C1 C) are left for later.
