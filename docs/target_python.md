# The Python target

**Targets in this family:** `python12` and `python14`, aliased `python`
(`python12`, the default target).

**Key points**

- The **reference backend**: it compiles the entire language, and every
  other target is measured against its output.
- Output is one `.py` file, runnable with `python3` -- Python 3.12 or
  3.14, as the target says -- importing nothing but `dataclass` (and
  `Callable`) where it declares a datatype.
- Pyking's three binding forms — `=`, `var`, `:=` — all become plain
  Python assignment, because Python has no distinction to keep.
- Where Pyking is *stricter* than Python, the difference is compiled
  away: block scoping becomes **renaming**, and refutable comprehension
  patterns become a generated **match helper**.
- Type annotations are erased, except a datatype's fields, which a
  dataclass needs; nothing checks them at any stage.
- Least optimal at: shadowed bindings (renamed, so generated names drift
  from the source) and refutable comprehension patterns (a helper
  function per clause, hoisted to the top of the file).

Implementation: `src/target_python.ml`.

## What is supported

Everything. Pyking is defined by what this backend accepts — the parser
and the name analysis reject a program before it gets here, and anything
that survives those stages compiles. There is no "unsupported" list.

## How things compile

### Bindings and mutation

Python has one assignment statement, so all three Pyking forms collapse
into it. The distinction is real in Pyking and checked before this point
(`:=` requires a `var`, and a `var` may not be shadowed), so nothing is
lost by the time code is generated:

```pyking                          # generated Python
x = 1                              x = 1
var total = 0                      total = 0
total := total + x                 total = total + x
print(x, total)                    print(x, total)
```

### Booleans

`true`/`false` compile straight to Python's `True`/`False` — that part is
a plain value, not a formatting concern, so a bound, returned, or
compared boolean looks exactly as you'd expect in the generated code.
Printing one is the exception: Python's own `print` would write it back
out capitalised, `True`/`False`, but Pyking prints `true`/`false` (see
"The builtins and the host boundary" in `docs/architecture.md`) — the one place this
backend's native behavior actively disagrees with Pyking's, rather than
simply lacking a distinction Pyking makes.

Which arguments need that spelling is read off the **type checker's own
answers**: `translate_program` takes `tmap`, the symbol → type table, and
`bool_kind` asks it about each `print` argument. Pyking is statically
typed, so there is always an answer to ask for.

```pyking                                     # generated Python
print(1 < 2, true, 5, "hi")                   print('true' if 1 < 2 else 'false', 'true' if True else 'false', 5, 'hi')
count = 3                                     count = 3
print(count)                                  print(count)
```

A `Bool` becomes an inline `'true' if <expr> else 'false'` — `<expr>` is
evaluated exactly once either way, since it's the conditional's own
condition, not repeated in each branch. A type with no `Bool` anywhere
inside it — `Int`, `String`, `()`, `[Int]`, `(Int, String)` — is passed
through completely unwrapped, exactly as if this backend didn't exist.
That second case is the common one, and it is why an ordinary program
compiles to Python with no helper in front of it at all.

What is left is a value that really can hold a `Bool` where Python and
Pyking spell it differently — a `[Bool]`, a `(Int, Bool)`, or a type
nothing has pinned down. Those go through a small generated helper that
walks the value at *runtime* and formats it by `builtin.ml`'s
rules:

```pyking                              # generated Python (only ever emitted if needed)
flags = [true, false]
print(flags)                           print(__pyk_str(flags, True))    # [true, false]
```

Booleans are not the only thing the host spells its own way. A string
prints **bare on its own and quoted inside a list, a tuple or a
datatype value** (`builtin.ml`, `quote_string`): in double quotes, with
`\`, `"`, a newline, a tab, a carriage return and a NUL escaped
(`\\`, `\"`, `\n`, `\t`, `\r`, `\0`). A `Char` prints the same way in
single quotes, escaping `'` where a string escapes `"` (`quote_char`):
`['a', '\'']`. Python's own `repr` picks its quotes for itself, writing
`['say "hi"']` where every other target writes `["say \"hi\""]`, and
cannot tell a Char from a one-character string at all. So a value that
can hold a String or a Char *inside* a container goes through the helper
too, whatever its booleans say (`nests_a_string`). A string or a Char on
its own does not: it prints bare, which Python already agrees with, and
neither does a container of `Int`s. `tests/printing_quotes.pyk` and
`tests/char_lists.pyk` are the cases.

`isinstance`, not `v is True`/`v is False`: Python's `bool` is a subclass
of `int` and `1 == True`, but `isinstance(1, bool)` is always `False`, so
an ordinary Pyking `Int` that happens to hold `0` or `1` is never
misprinted as a boolean this way. The helper is generated at most once
per file, lazily, the first time an argument actually needs it — so a
program that never prints anything this backend can't classify never
gets one at all — and named to avoid every identifier in the source (the
same scheme `__pm*` comprehension helpers use, see below), so it can
never collide with a user's own name. When present, it prints in its own
commented-off **prelude** block ahead of the rest of the file (mirroring
the convention `target_js_packaging.ml` uses for its own prelude, for the
same reason: it's boilerplate for the host, not a translation of
anything the Pyking source wrote):

```python
# --- prelude begins ---
# Pyking prints a Bool as `true`/`false`, not Python's own capitalised
# `True`/`False`, wherever it sits -- on its own, or inside a list or
# a tuple. This helper exists because at least one value printed below
# isn't provably free of Bools from its Pyking source form alone (a
# variable, a call, or a container), so it is walked at runtime.

def __pyk_str(v, top, path=()):
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, str):
        if top:
            return v
        if type(v) is not str:                # a Char
            out = '\''
            for c in v:
                out = out + ('\\\\' if c == '\\' else ...)
            return out + '\''
        out = '"'
        for c in v:
            out = out + ('\\\\' if c == '\\' else ...)
        return out + '"'
    if isinstance(v, list):
        if type(v) is not list:               # an array or a DynArray
            if id(v) in path:
                return '...'
            path = path + (id(v),)
        ...
    if isinstance(v, tuple):
        ...
    if hasattr(v, '__dataclass_fields__'):    # a datatype's value
        if id(v) in path:
            return '...'
        path = path + (id(v),)
        ...
    if isinstance(v, dict):                   # a MutMap
        ...
    return str(v)

# --- prelude ends; the compiled program follows ---
```

The walk is what makes a boolean print as `true` wherever it sits —
`print([true, false])` writes `[true, false]`, and `print((1, true))`
writes `(1, true)` — which is the rule `builtin.ml` states and
the interpreter implements. The `top` parameter carries the one thing
that changes with depth: a string prints bare on its own and quoted
inside a container, and the quoting is Pyking's own (double quotes for a
String, single quotes for a Char, backslash escapes) rather than
Python's `repr`, which would switch to single quotes for a string
containing a double quote and so disagree with the other backends on
`print(('say "hi"', 1))`. The `path` parameter is the recursion-path
guard of "Mutable structs" below.

### Characters

A `Char` is a one-character Python `str` of a class of its own, emitted
in the prelude of every module that makes one:

```python
class __PykChar(str):
    # A Char: one code point, told from a String when printed.
    __slots__ = ()
```

The subclass is there for printing alone: the helper above tells a Char
from a String by `type(v) is not str`, which is true of a Char built in
any module, whatever that module's prelude calls its class. Everything
else is the `str` it is: `==` and `<` compare code points, a `case 'a':`
pattern is a literal pattern on the one-character string, and
`string(c)` is Python's `str(c)`, which answers a plain `str`. As an
annotation a Char is `str`.

What makes a Char:

```pyking                        # generated Python
c = 'é'                          c = __PykChar('é')
d = s[i]                         d = __PykChar(s[i])
for c in s: ...                  for c in __pyk_chars(s): ...
[c for c in s]                   [c for c in __pyk_chars(s)]
char(n) / char(s)                __pyk_char_of_int(n) / __pyk_char_of_str(s)
```

A Python `str` holds code points, so `s[i]` is the `i`-th code point and
`len(s)` counts code points with no help, as every target now does. An
index past the end raises Python's `IndexError`; a negative one counts
from the end, as it does for a list here. An array's index is checked (see "Arrays"). `__pyk_chars(s)` walks a
String (a `for` whose sequence the checker typed `String`) a Char at a
time. `char(n)` answers `'\0'` for a number that is not a Unicode
scalar value and `char("")` answers `'\0'`; `char(c)` of a Char is `c`.
`int(c)` is `__pyk_code(c)`, `float(c)` is `float(__pyk_code(c))`, and
`bool(c)` is `c != '\x00'`. `__pyk_code` is Python's `ord`, bound in the
prelude, so a program's own `def ord` cannot stand in for it.

A NUL, which a String or a Char may hold, is written `\x00` in the
generated source, which may not hold a raw one.

### Arrays

An array is a Python list of a class of its own, emitted in the prelude
of every module that makes one. The list is never grown: nothing but
the four makers below builds one, and nothing appends to it.

```python
class __PykArray(list):
    # An array: a list never grown, told from a list when printed.
    __slots__ = ()
```

As with a Char, the subclass is there for printing: the print helper
writes a list whose `type(v) is not list` as `array([1, 2])`, with its
elements written as they are inside a list (a String or a Char quoted),
`array([])` when it is empty. That is true of an array made in any
module. An array is never copied: a name, a parameter, a tuple or a
closure holds the one list. As an annotation an array is `list[T]`.

| Pyking | generated Python |
|---|---|
| `array(xs)` | `__pyk_array_list(xs)` |
| `array(n, v)` | `__pyk_array_fill(n, v)`: `[v] * n`, the one `v` in every element |
| `array(n, f)` | `__pyk_array_init(n, f)`: `f(0)`, `f(1)`, ... in that order |
| `array(n, seed, f)` | `__pyk_array_unfold(n, seed, f)` |
| `a[i]` | `__pyk_array_get(a, i)` |
| `len(a)` | `len(a)` |
| `same(a, b)` | `a is b` |
| `for x in a` | `for x in a`, which reads `a[i]` as each turn is reached |

Each maker checks its size first, before anything is called or made: a
negative one is the error `an array's size is never negative, and this
one is -1`, and a size Python cannot allocate is `an array of N
elements is more than this machine can hold`. Each helper is emitted
only where the program uses it.

Every index is checked by generated code. A Python list counts a
negative index from the end and raises its own `IndexError` past it;
an array does neither. `__pyk_array_get` answers the element, and
anything outside is the error `the index 5 is outside an array of 2
elements`. A runtime error goes through `__pyk_fail`, which flushes
standard output, writes `error: ` and the message to standard error,
and exits with status 1.

An element write `a[i] := v` keeps Pyking's order: the array, then the
index, then the index checked, then the value, then the write. Python's
own `a[i] = v` works out `v` first, so the check is a statement ahead
of it. Where the value cannot change what the array and the index are,
each a name no `:=` writes or a literal, they are written as
themselves; otherwise each is held in a temporary first, so the write
goes to the array the owner was even when the value rebinds a `var`:

```pyking                          # generated Python
a[i] := v                          __pyk_array_index(a, i)
                                   a[i] = v
held[0] := replace_held()          __pyk_owner1 = held
                                   __pyk_at1 = __pyk_array_index(__pyk_owner1, 0)
                                   __pyk_owner1[__pyk_at1] = replace_held()
```

`a[i] += e` arrives as `element__array = a`, `element__index = i` and
a write of `element__array[element__index] + e`, both names ones no
`:=` writes.

### DynArrays

A DynArray is a Python list of a class of its own too, emitted in the
prelude of every module that makes one, and grown and shrunk by the
list's own methods:

```python
class __PykDynArray(list):
    # A DynArray: an array that grows, told from a list when printed.
    __slots__ = ()
```

The print helper writes a list whose class is named `__PykDynArray` as
`dynarray([1, 2])`, its elements as inside a list; asking by name is what
makes a DynArray made in any module print right. Like an array, a DynArray is
never copied: a name, a parameter, an element or a field holds the one
list. As an annotation it is `list[T]`. Python's `list.pop` and `del`
leave nothing of a removed element behind, so a removed value is not
kept alive.

| Pyking | generated Python |
|---|---|
| `dynarray()` | `__PykDynArray()` |
| `dynarray(xs)` | `__PykDynArray(xs)` |
| `push(v, x)` | `v.append(x)` |
| `pop(v)` | `__pyk_dynarray_pop(v)`: the error `pop from an empty DynArray` on an empty one |
| `insert(v, i, x)` | `__pyk_dynarray_insert(v, i, x)`: `0 <= i <= len(v)` checked, then `v.insert(i, x)` |
| `remove(v, i)` | `__pyk_dynarray_remove(v, i)`: `v.pop(i)`, the index checked |
| `clear(v)` | `v.clear()` |
| `v[i]` | `__pyk_dynarray_get(v, i)` |
| `len(v)` | `len(v)` |
| `same(v, w)` | `v is w` |
| `for x in v` | `for x in v` |
| `[e for x in v]` | `[e for x in list(v)]` |

An index is checked against the length the DynArray has *now*, with the
message `the index 5 is outside a DynArray of 2 elements`, through
`__pyk_dynarray_index`. `push`, `insert` and `clear` are worth unit: as a
statement each is the bare call, and in value position it is followed
by the `()` it is worth, as `print` is (`(v.append(x), ())[1]`). A
program's own definition named `push`, `pop`, `insert`, `remove` or
`clear` is an ordinary call.

`for x in v` is Python's own loop over the list, which is already
Pyking's rule: Python's list iterator keeps an index and compares it
with the list's length at every turn, so what is pushed during the walk
is walked too, a removal ends it sooner, and each element is read when
its turn is reached. A comprehension walks the elements the DynArray has
when it starts, so it walks a copy, `list(v)`: a call in it that pushes
cannot lengthen it.

An element write `v[i] := x` keeps an array's order, with one more
check: the index is checked before the value is worked out and again
at the write, since the value's own work may have shrunk the DynArray. The
second check is the subscript itself, which Python works out after the
value. Where the value is a literal or a name no `:=` writes, nothing
can happen between the two, and the one check in the subscript is
enough:

```pyking                          # generated Python
v[2] := 7                          v[__pyk_dynarray_index(v, 2)] = 7
v[1] := shrink()                   __pyk_dynarray_index(v, 1)
                                   v[__pyk_dynarray_index(v, 1)] = shrink()
```

A DynArray is a container on the printing path like an array (see "Mutable
structs" below): a DynArray holding itself prints `...` where it repeats.

### Slices and views

A slice `s[i:j]` is one prelude helper for every kind, `__pyk_slice(s,
i, j)`, with `0` for a left-out low bound and `None` for a left-out
high one. Python's own slice clamps a bound past the end where Pyking
checks it, and an array's or a DynArray's slice would be a plain list, so
the helper checks `0 <= i <= j <= len(s)` first -- the error `the slice
2:4 is outside an array of 3 elements`, naming a list, a String, an
array, a DynArray or a view -- and then copies with Python's own slice: a
list and a String as they are (a String's `len` and slice count code
points, as Pyking's do), an array or a DynArray wrapped in its own class
again, and a view's elements into a new array. The sequence, then the
bounds, then the check, as Pyking orders them.

A view is an object of a class of its own, emitted where a module makes
one, holding the array, the offset of its first element and its length:

```python
class __PykView:
    # A view: elements offset up to offset + length of an array, shared.
    __slots__ = ('owner', 'offset', 'length')

    def __len__(self):
        return self.length

    def __iter__(self):
        # Each element read as its turn comes.
        for i in range(self.offset, self.offset + self.length):
            yield self.owner[i]
```

| Pyking | generated Python |
|---|---|
| `view(a, i, j)` | `__pyk_view(a, i, j)`: a view of a view holds the same array, the offsets added |
| `w[k]` | `__pyk_view_get(w, k)` |
| `w[k] := x` | `w.owner[__pyk_view_index(w, k)] = x` |
| `len(w)` | `len(w)` |
| `for x in w` | `for x in w`, each element read as its turn comes |
| `[e for x in w]` | `[e for x in list(w)]`, the elements as they are when it starts |
| `same(w, v)` | `w is v`: two `view(...)` calls make two views |
| `copy_into(dst, src)` | `__pyk_copy_into(dst, src)` |

`__pyk_view_index` checks the index against the view's length -- `the
index 2 is outside a view of 2 elements`, even where the array goes on
-- and answers where the element is in the array. An element write keeps
an array's order, the check a statement ahead of a value that could be
seen to come first (`__pyk_view_index(w, k)` then `w.owner[w.offset +
k] = x`), and the view and the index held in temporaries where the
value could change them. `__pyk_view` checks its bounds against the
array's or the view's length, `the view 1:9 is outside an array of 4
elements`. A view's annotation is `object`: a module handed one need
not have the class.

`copy_into` reads all of `src` before it writes anything, which is
memmove's answer where the two overlap, and then writes it over the
first elements of `dst` with a slice assignment, of the array itself or
of the view's run of its array -- the same length, so nothing grows.
More elements than `dst` has is the error `copy_into copies 4 elements
into 2`. `view` and `copy_into` yield to a program's own definition of
the name.

A view prints as its elements are now, `view([21, 30, 41])`. On the
printing path it is the array it shares, so a view of an array inside
that array prints `...`. `tests/slices.pyk`, `tests/slice_bounds.pyk`,
`tests/view_bounds.pyk` and `tests/typecheck_slices.pyk` are the cases.

### Pointers

A pointer is an object of a class of its own, emitted where a module
takes an address, naming a place as a store and a slot in it: an array
and an index, or an object and the name of one of its fields.

```python
class __PykPtr:
    # A pointer: the place `slot` of `store` -- an array's element by
    # index, or a field by name of a var struct or of a var's box.
    __slots__ = ('store', 'slot')

    def __init__(self, store, slot): ...
    def get(self): ...                # store[slot], or getattr(store, slot)
    def set(self, value): ...         # store[slot] = value, or setattr(...)
    def __eq__(self, other): ...      # the same store, the same slot
```

Python has no address of a variable, so a `var` whose address the
module takes anywhere lives in a **box**, `__PykBox`, an object holding
its `value`. The box is made where the `var` is declared, so each turn
of a loop declaring one makes its own, and it lives for as long as
anything holds it -- a pointer to a function's local outlives the call.
Every read of such a `var` is `x.value`, every `:=` writes `x.value`;
a `var` whose address is never taken is the plain variable it always
was.

| Pyking | generated Python |
|---|---|
| `var x = 1` (address taken) | `x = __PykBox(1)` |
| `x`, `x := v` | `x.value`, `x.value = v` |
| `&x` | `__PykPtr(x, 'value')` |
| `&a[i]` | `__pyk_array_addr(a, i)`: the index checked as a read's |
| `&w[k]` | `__pyk_view_addr(w, k)`: the view's array, at `offset + k` |
| `&pt.y` | `__PykPtr(pt, 'y')` |
| `&*p` | `p` |
| `*p` | `p.get()` |
| `*p := v` | `p.set(v)`: the pointer, then the value, then the write |
| `p == q` | `p == q`: one store (`is`), one slot |

`*p += 1` arrives as `pointer__target = p` and a write of
`pointer__target.get() + 1`. A pointer's annotation is `object`.

A pointer prints as what it points at now, `Ptr(12)`, through the Bool
walker; on the printing path it is its store (the box, the array, the
struct), so a `var` holding a pointer to itself prints `Ptr(...)`.
`Option(Ptr(T))` is an ordinary datatype holding one. `==` on a type
holding pointers is Python's own, which calls `__eq__`.
`tests/pointers.pyk`, `tests/pointers_escape.pyk` and
`tests/typecheck_pointers.pyk` are the cases.

### Mutable structs

A `var struct` is a dataclass that is not frozen, declared where any
datatype's constructor is (see "Datatypes" below), with `eq=False` so
that two of them are equal only when they are one object. Its value is
an ordinary Python object, so it is shared the way Pyking says it is:
a name, a parameter, an element of an array or a list, a field of a
datatype or a closure holds the one object, and a write through any of
them is seen through all. `same(a, b)` is `a is b`, as for arrays. A
`..` update arrives as an ordinary constructor call, so it makes a new
object; a pattern `case Point(x, y)` reads the fields as they are.

```pyking                          # generated Python
use mutation
var struct Point(x: Int, y: Int = 0)  @dataclass(slots=True, eq=False)
                                   class Point:
                                       x: int
                                       y: int
p = Point(5)                       p = Point(5, 0)
p.x := 10                          p.x = 10
p.y += 1                           field__owner = p
                                   field__owner.y = field__owner.y + 1
```

A field write `o.f := v` keeps Pyking's order: the owner, then the
value, then the write. Python's own `o.f = v` works out `v` first, so
where the order could be seen -- the owner is not a name no `:=`
writes, and the value is not a literal or such a name -- the owner is
held in a temporary first, as an element write's is:

```pyking                          # generated Python
inner_of(box).x := 7               inner_of(box).x = 7
pick.x := switch()                 __pyk_owner1 = pick
                                   __pyk_owner1.x = switch()
```

A compound write `p.x += e` arrives as `field__owner = p` and a write
of `field__owner.x + e`, `field__owner` a name no `:=` writes.

**Printing.** A var struct prints as a struct does, `Point(10, 1)`,
through the Bool walker. A value that holds itself -- a var struct or
an array met again inside itself, through any datatypes, lists or
tuples between -- prints `...` where it repeats: `Node(1,
Next(Node(2, Next(...))))`. The walker carries `path`, the ids of the
arrays and datatype values it is inside of, and only a value already
on that path is a repetition; one that is merely shared, the same
struct twice in an array, prints in full each time. That is the
interpreter's rule (`display_value`), for `print` and `string` alike.

All of a `print`'s arguments are worked out before any is formatted,
so `print(a, f())` shows what `f` did to `a`. Python formats each
argument as it reaches it, so where an argument the walker formats can
still be changed -- its type holds an array, a DynArray or a var struct, or
is one the backend cannot see into -- and a later argument makes a call
(other than to a builtin that changes nothing, such as `len`), the
arguments are handed to a lambda first and formatted inside it:

```pyking                          # generated Python
print(acct, deposit(acct, 5))      (lambda __pyk_arg1, __pyk_arg2: print(__pyk_str(__pyk_arg1, True), __pyk_arg2))(acct, deposit(acct, 5))
```

Every other `print` is the plain call. `tests/var_struct.pyk`,
`tests/var_struct_import.pyk` and `tests/typecheck_var_struct.pyk` are
the cases.

### A `var` written from inside a function

A mutable variable is one location, so a `def` that writes one bound
outside it writes *that* location. Python does not agree by default:
assigning a name anywhere in a function makes it local to the whole
function, so the obvious translation would silently make a second
variable — and, worse, would raise `UnboundLocalError` the moment the
body also *read* it.

So a function body declares what it writes, before anything else in it:

```pyking                       # generated Python
var x = 8                       x = 8

def foo(y):                     def foo(y):
    x := y                          global x
                                    x = y
                                    return ()
```

`global` for a `var` declared at the module level, `nonlocal` for one in
an enclosing function:

```pyking                       # generated Python
def outer(start):               def outer(start):
    var total = start               total = start

    def bump(n):                    def bump(n):
        total := total + n              nonlocal total
                                        total = total + n
                                        return ()
    bump(1)                         bump(1)
    return total                    return total
```

`Scope` carries what that decision needs: `depth`, how many Python
function scopes deep the translation is (0 is the module), and
`mutables`, each `var` in scope and the depth its declaration sits at.
`mutated_names` collects the names a body writes with `:=` and does not
itself declare with `var`, stopping at a nested `def` — that body
declares its own. Nothing needs to be declared for a name the body
declares itself, and nothing may shadow a `var` anyway (PYKING.md,
"Names and scoping"), so there is never a second candidate for a write
to mean.

This is the one backend that needs any of this. JavaScript closes over
the binding and OCaml over the `ref`; C and Java keep such a `var` in a
cell its closures point to.

### Names that are keywords in Python

A name can be a perfectly good Pyking identifier and a reserved word in
Python — `lambda`, `class`, `pass`, `del`, `import`, and the rest.
Emitting it unchanged would produce a file that will not parse, so such
a name is renamed by the same mechanism that renames a shadowed one:

```pyking                          # generated Python
def lambda(n):                     def lambda_(n):
    n * 2                  ->          return n * 2
```

The list comes from the standard `keyword` module (`kwlist` plus
`softkwlist`) rather than being written out here, so it cannot go stale
against the Python this compiler runs on. Renaming picks `lambda_`,
the same in every module, so that a public name -- a constructor called
`None`, most often -- is imported by the name its own module bound it
under; where that is taken too, `lambda2`, `lambda3`, … — skipping any
that is itself taken or reserved.

The Python builtins the output and its prelude helpers call by name --
`list`, `len`, `isinstance`, `str`, `map`, `print`, `SystemExit` and
the rest of the list in `reserved` -- are renamed the same way. A
Pyking binding of one at a module's top level would otherwise replace
it for every helper in that file: `lib/array` writes `import list`, and
a bare `import list` there would leave `list(...)` in the generated
code calling the module. It is `import list as list_` instead, and a
program's own `def map(...)` is `def map_(...)`.

### Module names Python has already taken

A *module* name can collide too, and worse: `sys`, `time`, `math`,
`array` and about twenty others are built into the CPython interpreter,
so `import time` finds the frozen one before any sibling `time.py`. No
ordering of `sys.path` changes that — the builtin importer sits ahead of
the path finder in `sys.meta_path` — so a Pyking module with such a name
could never be reached at all.

A program importing one loads it by path instead, through a helper this
backend puts in the prelude:

```pyking                  # generated Python
import time               time = __pyk_import('time')
```

```python
def __pyk_import(name):
    from importlib.util import module_from_spec, spec_from_file_location
    from os.path import abspath, dirname, join
    spec = spec_from_file_location(name, join(dirname(abspath(__file__)), name + '.py'))
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
```

A `from` line binds the module once under `__pyk_mod_<name>` and takes
its fields off that, since loading it per field would run its top level
once per field.

The helper is emitted **only** where a program imports such a name, the
way every other helper here is: an ordinary program's output stays an
ordinary program's. `shadowed_modules` in `src/target_python.ml` is the
list, and it is a deliberate superset — some of those names are builtin
only on some platforms, and loading a Pyking module by path is right
either way, so a name in it that would not have collided costs a helper
and nothing else.

The other direction needs the same care: a library's Python
implementation that uses the standard library's module of the same
name. `lib/math/math_external.py` sits beside the generated `math.py`,
so where `math` is not built in, its own `import math` would find that
file; it looks for the standard library's everywhere on the path but
its own directory.

### Blocks are scopes; Python's are not

Pyking makes every block a scope. Python scopes at function boundaries
only, so a binding that shadows an outer name inside an `if`/`for`/
`while`/`case` body would land on the *same* Python variable and the
outer name would come back changed. The backend renames it, keeping the
new name close to the source one — `total`, then `total2`, then `total3`:

```pyking                          # generated Python
total = 1                          total = 1
if 1 < 2:                          if 1 < 2:
    total = 2                          total2 = 2
    print(total)                       print(total2)
print(total)                       print(total)
```

Renaming happens **only where it is needed**, so generated code keeps the
names actually written wherever it can. Not inside a `def` body or a
comprehension (Python already scopes those), and not when the shadowed
binding is unreachable anyway — rebinding within one block, or two
sibling blocks that each use the same name.

The name it picks has to miss every name an **enclosing** block is still
using, and that is more than the scope's `local` map can answer: `local`
holds one Python name per Pyking name, so `x` → `x3` at the third level
has already overwritten the `x2` the second level is still reading.
`Scope.used` is what remembers the ones a shadow replaced — every Python
name handed out by an enclosing block of this Python function scope. It
is inherited by `block_scope` and reset by `function_scope`, and it
deliberately does *not* travel back out of a finished block, so two
sibling blocks may still reuse a name. Without it, a fourth level of
`x` wraps back round to `x2` and assigns over the second level's
binding — silently, since the program still runs.
`tests/shadowing_depth.pyk` is the case, and
`tests/shadowing_depth_loops.pyk` the same through `for` and `loop`.

There is a second way the two scopings disagree, and it needs looking
*ahead* rather than behind. Any binding of a name inside a Python
function makes that name local to the **whole** function, so a block that
shadows a name the rest of the function still reads cannot keep the
plain name either:

```pyking                          # generated Python
def helper(n):                     def helper(n):
    n                                  return n

def branchy(n):                    def branchy(n):
    if n > 0:                          if n > 0:
        def helper(m):                     def helper2(m):
            m * 10                             return m * 10
        helper(n)                          return helper2(n)
    else:                              else:
        helper(n)                          return helper(n)
```

Spelling both `helper` would turn the else branch into a read of the
local one — `UnboundLocalError` at run time, not a name that merely looks
odd. The decision is made per `def` body, from what that body reads
*freely*: names it uses without having bound them itself at that point
(`free_names`). Only those are protected, so a body that shadows a name
it never reads from outside keeps the source's own spelling:

```pyking                          # generated Python
x = 1                              x = 1
def f(n):                          def f(n):
    x = 2                              x = 2
    x + n                              return x + n
```

### A rebinding some function captured

Pyking's `=` is a binding, so rebinding a name makes a *new* one and a
function written earlier keeps the old (PYKING.md, "Names and scoping").
Python has one variable per name per scope, so the second binding gets
its own — but only when a function in that scope actually captured the
first (`captured_names`), so code without closures over the name is
untouched:

```pyking                          # generated Python
x = 1                              x = 1
def show(): x                      def show(): return x
x = "two"                          x2 = 'two'
print(x, show())                   print(x2, show())      → two 1
```

### `loop`, `break` and `continue`

A `loop` is Python's `while True` over one variable holding the
accumulator: the initializer gives it its first value, every tail of the
body assigns the next one, and `break`/`continue` are Python's own. A
`break x` or `continue x` assigns `x` to that variable first
(`x = …` then `break`), which is all it takes: the loop is worth what
the variable holds, and the next turn starts from it.

```pyking                          # generated Python
res = loop x = 5:                  x = 5
    if x <= 10:                    while True:
        continue                       if x <= 10:
    if x < 30:                             continue
        x + 2                          if x < 30:
    else:                                  x = x + 2
        break                          else:
                                           break
                                   res = x
```

The loop's own value is the accumulator variable, so binding one is that
assignment after the loop, and a loop in tail position is `return x`.
That works because a `break` is Python's own: it leaves the variable
holding what this turn started with, which is exactly what the loop is
worth. A tuple accumulator is a Python tuple, assigned as a whole
(`x, y = x + 1, y`), so the next turn's values are computed before any
of them is stored. A `loop:` carrying nothing has no variable at all and
is worth `()`, which is what a binding of one gets.

The one place this differs from what the source says is a body path with
no value at all — an `if` with no `else` as the body's last statement.
PYKING.md's tail-position table says such a statement supplies unit, so
the generated `else` assigns `()`, which is what the interpreter does
with it too.

### Unit, and `print` as a value

This backend spells Pyking's unit as Python's empty tuple, `()`: a
unit-returning `def` gets an explicit `return ()`, and the literal `()`
is itself. Python's own `print` is the one thing that does not agree —
it answers `None`, where Pyking's `print` yields unit
(`builtin.ml`) — so a `print` call *used as a value* is
followed by the unit it is worth:

```pyking                          # generated Python
x = print("a")                     x = (print('a'), ())[1]
```

Written as a statement it keeps the bare call, since nothing reads what
a statement is worth:

```pyking                          # generated Python
print("a")                         print('a')
```

Without that, `print(print("a"))` writes `None` where every other target
writes `()`, and `(print("a"), 1)` writes `(None, 1)`. It is not only a
matter of spelling: `__pyk_str` walks a value, so a `None` sitting
inside a list or tuple would show up there too.
`tests/unit_values.pyk` covers both positions.

`debug` is Python's own `print` on standard error, reached through
`__import__('sys')` since a Pyking module may be called `sys` too:

```pyking                          # generated Python
debug("n", 2)                      print('n', 2, file=__import__('sys').stderr)
```

A program compiled with `--release` has no `debug` left in it. A
program's own definition named `print` or `debug` is an ordinary call.

### The conversions

`string(x)` is Python's `str` over the argument `print` would write, so
it formats a Bool and a Float as `print` does. `int`, `float` and `bool`
go by the argument's type. Python's own `int` and `float` are used where
they agree -- `int(b)` of a Bool, `float(n)` of an Int -- and `bool` is a
comparison (`s == 'true'`, `n == 1`, `c != '\x00'`). A Char's `int` and
`float` are its code point (see "Characters"). A String goes through
`__pyk_int` and `__pyk_float_of`, and `int` of a Float through
`__pyk_trunc`, prelude helpers emitted only where used: Python's `int`
reads `" 3"` and `"1_000"` and raises on a NaN, where Pyking answers 0.

### A `def` inside a loop

A loop binds afresh on every turn, so a function written in one keeps
that turn's values. Python would leave every copy sharing the last, so
the run of `def`s is built by a small factory taking the loop-carried
names — the values passed are that turn's. This applies to all three
loops: `for`, `while` and `loop`, whose accumulator is loop-carried like
anything else the body binds:

```pyking                          # generated Python
for i in range(3):                 for i in range(3):
    def show(): i                      def __pyk_turn1(i):
    fns := fns + [show]                    def show():
                                               return i
                                           return show
                                       show = __pyk_turn1(i)
                                       fns = fns + [show]
```

The `def`s that **name each other** go into *one* factory, wherever they
are written in the body, so a recursive function calls this turn's copy
and functions that call each other find each other there. The factory
name is allocated like the comprehension helpers' (`__pm*`), checked
against every identifier in the source, so it cannot collide.

Nothing but `def`s moves: a `return` between the members still returns
from the enclosing function, a `:=` still writes the variable it names,
and side effects keep their order. The one exception is a capture bound
*between* the members — a factory called at the first of them cannot
take it as a parameter, so that binding travels with the group and is
returned alongside the functions.

Two narrowings keep this from firing where it is not needed. A `def`
captures **positionally** — a name the block rebinds further *down* is a
different binding, which no turn touches from where the `def` stands —
and `var`s are excluded, because `:=` updates the one binding and a
function reading a `var` is meant to see that.

A `var` *declared inside* the loop is a new variable each turn,
though, and a function made in a turn keeps that turn's -- reading it
and writing it. Such a `var`, captured by a `def` or a lambda in the
loop, lives in a box (`__PykBox`, see "Pointers"), made afresh where it
is declared; the factory is handed the turn's box, and the function
reads and writes its `value`, with no `global` or `nonlocal`:

```pyking                          # generated Python
for k in range(3):                 for k in range(3):
    var j = k                          j = __PykBox(k)
    def bump() -> Int:                 def __pyk_turn1(j):
        j += 10                            def bump():
        j                                      j.value = j.value + 10
                                               return j.value
                                           return bump
                                       bump = __pyk_turn1(j)
```

`tests/loop_local_vars.pyk` is the case.

*Not optimal:* the factory is built whenever the capture exists, even
for a function that never outlives its turn — knowing otherwise needs
escape analysis, which this backend does not do. [gap.md](gap.md) has
the whole mechanism, the cases it covers, and what remains.

`tests/lexical_capture*.pyk` pin all of this, and
`tests/shadowing_functions.pyk` runs the cases the renaming above covers — the sibling
branch above, the outer name read *before* the shadowing binding, three
levels of nesting that need no renaming at all, and a closure reading
the outer name from a block that shadows it.

*Not optimal:* a heavily shadowing program reads with `x2`, `x3` in the
output where the source says `x` throughout. The alternative — leaving
the names alone — would be wrong rather than ugly, so the trade is worth
it; but it does mean generated Python is not always a line-for-line
mirror of the source.

### Lambdas

Pyking's lambda body is one expression and Python's `lambda` takes one
expression, so a lambda is Python's own, parameter for parameter. A
Python `lambda` is a function scope, so its parameters never need the
renaming a Pyking block's bindings need.

```pyking                          # generated Python
double = lam x. x * 2              double = lambda x: x * 2
adder = lam x. lam y. x + y        adder = lambda x: lambda y: x + y
```

A lambda **inside a loop** has the same problem a `def` there has, and a
cheaper answer. Each loop-carried name the body reads becomes a trailing
parameter whose default is that name, which Python evaluates where the
lambda is written — so each turn's lambda holds that turn's value:

```pyking                          # generated Python
for i in [0, 1, 2]:                for i in [0, 1, 2]:
    made + [lam x. x + i]              made = made + [lambda x, i=i: x + i]
```

A default is never reached positionally, because the call has exactly as
many arguments as the lambda's type has parameters, and the pinned ones
come after all of them. Outside a loop there are no loop-carried names,
so an ordinary lambda is emitted exactly as it was written.

A **comprehension** is a loop too: Python has one variable for all its
turns where Pyking binds the names a `for` clause binds afresh each
turn, so a lambda in it reading one pins it the same way, as it does a
name a loop around the comprehension rebinds:

```pyking                          # generated Python
[lam (). x * by for x in xs]       [lambda x=x: x * by for x in xs]
```

Without it, calling the lambdas gives the last element's value for
every one. A `let` taken apart by a one-element comprehension (see
"Let expressions") has one turn, and pins nothing.
`tests/closure_comprehension.pyk` is the case.

Two analyses this backend already runs had to learn about lambdas, and
neither would have failed loudly: `free_names`, so a binding that
shadows a name a lambda reads from outside itself is still renamed, and
`captured_names`, so a rebinding of a name a *lambda* captured gets its
own Python variable the way one a `def` captured does. Without the
second, `x = 1; f = lam (). x; x = 2` would print 2 where Pyking says 1.
`tests/lambda_loop_capture.pyk` and `tests/lambda_capture.pyk` pin both.

### Equality

`==` and `!=` compare lists, tuples, structs and datatypes part by
part. Python's own `==` does too -- a list element by element, a frozen
dataclass by its class and then its fields -- with one difference:
it takes an object to equal itself before comparing it, so a NaN
*inside* a list or a datatype equals itself there, `[nan] == [nan]`,
where Pyking follows IEEE and says false. So where a Float can sit
inside the compared type (`float_inside`), the comparison is the
prelude helper `__pyk_eq`, which walks both values and leaves only the
Floats to Python's `==`; everywhere else, a Float on its own included,
it is Python's own `==`/`!=`:

```pyking                          # generated Python
[1, 2] == xs                       [1, 2] == xs
Circle(1.0) != shape               not __pyk_eq(Circle(1.0), shape)
```

A datatype of another module is taken to hold a Float, since the
backend does not look into it. `tests/equality.pyk` is the case.

### MutMaps

A MutMap is a Python dict of a class of its own, emitted in the prelude
of every module that makes one. A Python dict keeps its keys in the
order they were put in, and replacing a value keeps its key's place,
which is Pyking's order; re-inserting a removed key puts it at the end
in both. The class adds one thing, a count of the keys put in and
taken out, which a `for` over it checks:

```python
class __PykMutMap(dict):
    # A MutMap: a dict, in the order its keys were put in, and a count
    # of the keys put in and taken out, which a for loop over it checks.
    __slots__ = ('changes',)

    def __init__(self):
        self.changes = 0
```

| Pyking | generated Python |
|---|---|
| `mutmap()` | `__PykMutMap()` |
| `mutmap(pairs)` | `__pyk_mutmap_list(pairs)`: a key written twice keeps its first place, its last value |
| `d[k]` | `__pyk_mutmap_get(d, k)`: `the MutMap has no key "b"` where it has none |
| `d[k] := v` | `__pyk_mutmap_set(d, k, v)` |
| `get(d, k, x)` | `d.get(__pyk_key(k), x)` |
| `has(d, k)` | `__pyk_mutmap_has(d, k)` |
| `remove(d, k)` | `__pyk_mutmap_remove(d, k)`: `the MutMap has no key "b" to remove` where it has none |
| `discard(d, k)` | `__pyk_mutmap_discard(d, k)` |
| `clear(d)` | `__pyk_mutmap_clear(d)` |
| `keys(d)` / `values(d)` / `items(d)` | `__pyk_mutmap_keys(d)` / `list(d.values())` / `__pyk_mutmap_items(d)` |
| `len(d)` | `len(d)` |
| `same(d, e)` | `d is e` |
| `for k in d` | `for k in __pyk_mutmap_walk(d)` |
| `[e for k in d]` | `[e for k in __pyk_mutmap_keys(d)]`, the keys as they are when it starts |

`remove` and `clear` are a DynArray's or a MutMap's by their first argument's
type; a program's own `get`, `has`, `keys`, `values`, `items`,
`discard`, `remove` or `clear` is an ordinary call. A missing key is
shown as `print` shows it inside a value, a String quoted, through the
Bool walker, which is in the prelude of any module that reads a MutMap.
`d[k] := v` is a call, so the MutMap, the key and the value are worked
out in that order before the write; `d[k] += 1` arrives as an array's
does and reads the key first.

**Keys.** A key type holds no Float, function or mutable value, so
Python's own hash and `==` agree with Pyking's `==` -- a frozen
dataclass hashes and compares its fields -- except that a list cannot
be hashed at all. Every helper taking a key passes it through
`__pyk_key`, which gives a hashable key back unchanged and holds any
other -- a list, or a tuple or datatype with one inside -- in a
`__PykKey`, hashed and compared by a form of it made of tuples
(`__pyk_frozen`); every helper giving keys back takes it out again
(`__pyk_unkey`). Two equal values are the same shape, so they are both
held or both not, and the choice is made the same way in every module.

**`for` over a MutMap.** `__pyk_mutmap_walk` is a generator over the keys
as they are when the loop starts. Each time the loop asks for the next
key -- the step that ends the loop included -- it compares the count
of changes with the count it started with, and a key put in or taken
out meanwhile is the error `the MutMap changed while a for loop was
reading it`. Replacing a value is not a change. Python's own check
(`dictionary changed size during iteration`) is not used: it sees a
change of size, not one insertion and one removal, and its message is
not ours.

**Printing.** A MutMap prints as what makes one, `mutmap([("ada", 37),
("bo", 6)])`: the Bool walker writes each entry as a `(key, value)`
tuple. A MutMap is a container on the printing path like an array or a
DynArray, so one holding itself prints `...` there. `tests/mutmap_basic.pyk`,
`tests/mutmap_changed.pyk`, `tests/mutmap_missing.pyk` and
`tests/typecheck_mutmap.pyk` are the cases.

### Maps

A Map is a dict of a class of its own too, `__PykMap`, shaped like
`__PykMutMap` (its `changes` stays 0). Nothing ever writes one, so the
MutMap helpers that only read -- `__pyk_mutmap_has`, `_keys`, `_items`,
`_walk`, `get` as `d.get(__pyk_key(k), x)` -- serve a Map unchanged,
and so do comprehensions, `len` and `for`. Only what makes one and a
missing key are its own:

| Pyking | generated Python |
|---|---|
| `map()` | `__PykMap()` |
| `map(pairs)` | `__pyk_map_list(pairs)`: a key written twice keeps its first place, its last value |
| `m[k]` | `__pyk_map_get(m, k)`: `the Map has no key "zed"` where it has none |

The conversions (`array(m)`, `mutmap(m)`, `map(d)`) arrive already
rewritten into these list forms by elaboration. A Map prints as
`map([("a", 1)])`, the walker telling it from a MutMap by its class.
`==` on Maps is the same keys, each with an equal value, in any order:
Python's own dict `==` already says so, and since `float_inside` cannot
look into a Map it goes through `__pyk_eq`, which compares a dict that
way part by part, so a Map nested in a list, tuple or datatype compares
the same. `tests/map_basic.pyk` and `tests/map_lib.pyk` are the cases.

### `panic`

`panic(message)` is `__pyk_fail(message)`, the helper every runtime
error here goes through: it flushes standard output, writes `error: `
and the message to standard error and raises `SystemExit(1)`. A call
in value position, `5 if c else __pyk_fail('never')`, never answers, so
it fits any type. `tests/panic_builtin.pyk` is the case.

### Statement forms that Python spells differently

`else if` is Pyking's spelling of `elif`, and a body written on its
header's own line — `def f(x): e`, `case p: e` — is an ordinary block of
one statement. Both are undone on the way out: the first into `elif`,
the second into a body whose tail expression becomes a `return`:

```pyking
def sign(n): if n < 0 then "neg" else "pos"


def classify(n):
    if n < 0:
        return "low"
    else if n == 0:
        return "zero"
    else:
        return "high"
```

```python
def sign(n):
    return 'neg' if n < 0 else 'pos'
def classify(n):
    if n < 0:
        return 'low'
    elif n == 0:
        return 'zero'
    else:
        return 'high'
```

Note the operand order flips for the `if` expression: Pyking writes the
condition first (`if c then a else b`), Python writes it in the middle.

### Tail position

A function body's last statement supplies the function's value (see
"Tail position" in PYKING.md), so the backend pushes a `return` down
into it — recursively, so branches of branches are covered:

```pyking                          # generated Python
def pick(x, y, z):                 def pick(x, y, z):
    if z > 5:                          if z > 5:
        x + y              ->              return x + y
    else:                              else:
        2 * x                              return 2 * x
```

`translate_tail_block`/`translate_tail_stmt` do this, and they are
deliberately the same recursion as `translate_value_block` below with
`return` in place of the assignment — which is why an `if` nested in a
`match` nested in an `if` needs no case of its own.

A body that can fall out of its end produces unit on that path, and unit
is `()` — Python's implicit `None` is *not* it, and printing one would
write `None` where every other backend writes `()`. So a `return ()` is
appended exactly when control can reach the end (`falls_through`),
which keeps unit a real value instead of a print-time special case:

```pyking                          # generated Python
def greet(n):                      def greet(n):
    print(n)               ->          print(n)
                                       return ()
```

A body that already returns on every path gets nothing added, so the
common `if`/`else` case stays clean.

Two things are left alone. A `print` in tail position stays a statement:
it yields unit, and Python's implicit `None` already *is* unit, so
`return print(x)` would say the same thing less clearly. And a tail that is
a loop or a binding produces no value, so no `return` is emitted and the
function returns `None`.

`return if c:` / `return match e:` compile the same way, just written
explicitly, which additionally works before the end of a body where the
implicit rule cannot reach.

### Value-form `if`/`match`

Binding a block-form `if` or `match` with `=` has no Python equivalent —
Python has no statement that evaluates to a value. It compiles to the
same statement with the *assignment pushed into every branch tail*:

```pyking                          # generated Python
label = if 1 < 2:                  if 1 < 2:
    helper = "yes"                     helper = 'yes'
    helper                             label = helper
else:                              else:
    "no"                               label = 'no'
```

This is why everything else about a branch keeps working — local
bindings, mutation of an enclosing `var`, prints. Wrapping the branches
in a helper function would have broken all three.

### `match`/`case`

`match` maps onto Python's own, and an arm's tail expression becomes a
`return` like any other tail position — which is why an arm that is one
expression is only meaningful inside a function:

```pyking                          # generated Python
def describe(n):                   def describe(n):
    match n:                           match n:
        case 0: "zero"                     case 0:
        case _: "many"                         return 'zero'
                                           case _:
                                               return 'many'
```

Every `match` matches every value (docs/exhaustive.md), so none needs a
fallthrough. A guard is Python's own `case p if g:`, and an or-pattern
and an `as` pattern are Python's `|` and `as`. One combination needs
help: a guard that names what a `+` string split bound, since Python
binds that only in the arm's body. There the split's bindings are made
in the guard itself, each as `[name := value]` -- a one-element list,
which is never false:

```pyking                          # generated Python
case "say " + rest                 case str() as __text if __text.startswith('say ') and [rest := __text[4:]] and len(rest) > 3:
        if len(rest) > 3: ...
```

A `+` split inside an alternative of `|` is refused: the split is
tested in the arm's guard, and Python's `|` has no guard per
alternative.

### Datatypes

A constructor is a frozen dataclass, `@dataclass(frozen=True,
slots=True)`, declared at the top of the program. Its fields are the
class's, annotated with the types the checker worked out -- a named
field by its name, an unnamed one `_0`, `_1`, ... -- so a dataclass's
own `__match_args__` makes a constructor pattern Python's class
pattern, `case Leaf(v, n):`, and `x.age` is attribute access. A
datatype's parameters are the class's PEP 695 type parameters, and the
datatype's own name is a `type` alias for the union of its
constructors, which is what an import of it imports -- unless a
constructor has the datatype's name, as a `struct`'s does, and the
class is the type. A `var struct`'s one class is
`@dataclass(slots=True, eq=False)` instead (see "Mutable structs"
above). A value prints through the Bool walker, which knows
a datatype's value by its `__dataclass_fields__`; a class whose Python
name is not its constructor's (a reserved word renamed) carries the
Pyking name as `_pyk_tag`.

```pyking                          # generated Python
datatype Shape:                    @dataclass(frozen=True, slots=True)
    Circle(radius: Float)          class Circle:
    Dot                                radius: float
                                   
                                   @dataclass(frozen=True, slots=True)
                                   class Dot:
                                       pass
                                   
                                   type Shape = Circle | Dot
```

The classes are written before anything else because a datatype is in
scope throughout its module, where a Python class is in scope only from
its statement on. **The two versions differ here only.** Python 3.12
evaluates a field's annotation when the class is made, so a field
naming a datatype not declared yet -- its own, in a recursive one -- is
quoted (`left: 'Tree[a]'`); `python14` relies on 3.14's deferred
annotations and writes it bare. A function type is
`collections.abc.Callable`, imported where one is used, and a datatype
of another module is named through its plain import, or `object` where
there is none.

*Not optimal:* a datatype's printing still goes through the walker
rather than a `__str__` of its own, so a program printing one carries
the prelude.

### List comprehensions with refutable patterns

A pattern is **irrefutable** when it matches every value it could be
given, so it only ever *binds* — a plain name like `x`, a wildcard `_`,
or a tuple built from those. It is **refutable** when it can fail to
match, so it also *filters*: `0` matches only zero, `[a, b]` only a
two-element list. In a comprehension that difference is visible in the
result, since an element a refutable pattern rejects is dropped rather
than raising an error.

Pyking allows *any* pattern in a comprehension's `for` clause; Python
allows only an irrefutable assignment target. An irrefutable pattern
therefore compiles straight across, while a refutable one — a literal, or
any list pattern — becomes a generated `__pm*` helper that attempts the
match with a real `match` statement and returns `[]` (filtered out) or a
one-element list (matched):

```pyking
rows = [[1, 2], [3], [4, 5]]
sums = [a + b for [a, b] in rows]
names = [n for (n, _) in [(1, "a"), (2, "b")]]
```

```python
def __pm1(v):
    match v:
        case [a, b]:
            return [(a, b)]
    return []
rows = [[1, 2], [3], [4, 5]]
sums = [a + b for item1 in rows for (a, b) in __pm1(item1)]
names = [n for (n, _) in [(1, 'a'), (2, 'b')]]
```

The second comprehension needed no helper: `(n, _)` always binds. The
`item1`/`__pm1` names are checked against every identifier in the source,
so they can never collide with a user name.

| `for` pattern | refutable? | compiles to | helper? |
|---|---|---|---|
| name `x`, wildcard `_` | no | native `for x in seq` | no |
| tuple of irrefutables `(x, _)` | no | native `for (x, _) in seq` | no |
| literal `0`, `"a"`, `true` | yes | two clauses + helper | **yes** |
| any list pattern `[a, b]`, `[x, ..r]` | yes | two clauses + helper | **yes** |
| tuple holding either `(x, 0)` | yes | two clauses + helper | **yes** |

*Not optimal:* every refutable clause adds a top-level function to the
file, hoisted above the program, and each match runs through a list
allocation. A direct `filter`-style expression would be tighter, but
Python's comprehension grammar cannot express a pattern test inline —
this is the cheapest encoding that keeps the result a single
comprehension.

### Functions used before they are written

Every `def` in a block is bound before the block is translated
(`declare_functions`), mirroring the front end. Python needs no help to
*run* a forward reference — it resolves a global or a closure variable
when the call happens — but the translation does, because a name here may
be renamed: a nested `def` that shadows something in the same Python
function scope compiles to `helper2`, and a call written above it has to
say `helper2` too. Without the pre-pass that call would fall through to
the name the *shadowed* binding compiled to and quietly call the wrong
thing.

Being in scope is not the same as having run: a call that executes before
its `def` raises `NameError`/`UnboundLocalError`, which is Pyking's rule
as much as Python's (see PYKING.md, "Names and scoping").

### `range`

Pyking's `range` yields a **list** of `Int` — the language has lists and
no lazy-sequence type, and the type checker says so. Python's own
`range` is a lazy object that prints as `range(0, 2)` and matches no list
pattern, so a range used as a *value* is materialised:

```pyking                          # generated Python
xs = range(2)                      xs = list(range(2))
print(xs)                          print(xs)          → [0, 1]

for i in range(3):                 for i in range(3):     ← still lazy
    print(i)                           print(i)
```

The `for` header keeps the lazy form, which is where building the list
would actually cost something.

### Type annotations

Parsed, stored, pretty-printed back by `-t pyking`, and erased here —
function types (`(Int) -> Int`) exactly like the rest. They are verified
before this backend ever sees them (see PYKING.md's "Type checking"),
and the generated Python carries no typing information at all:

```pyking                          # generated Python
def scale(x, factor:Int) -> Int:   def scale(x, factor):
    return x * factor                  return x * factor
```

## `/` needs a helper, because Python floors

Pyking's `/` truncates toward zero; Python's `//` rounds *down*, so the
two part company whenever exactly one operand is negative -- `-7 // 2`
is `-4` where every Pyking backend gives `-3`. A prelude helper corrects
the sign, emitted only in a program that divides:

```python
def __pyk_div(a, b):
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q
```

Division by zero falls through it to Python's own `ZeroDivisionError`,
which is what this target is documented as doing (see
[targets.md](targets.md)).

## Floats, where Python nearly agrees

Python has a real `float`, and it is the same IEEE 754 binary64 Pyking
means, so a value knows what it is at run time and arithmetic needs
nothing. Two things still do.

**Printing.** Python's `repr` follows the same thresholds Pyking's rule
does — that is where they came from — but writes an exponent with a sign
and a leading zero: `1e+300` where Pyking writes `1e300`, `1e-05` where
Pyking writes `1e-5`. So a Float is written by `__pyk_float`, the
prelude helper implementing `docs/builtin.md`'s rule, rather than by
`str`.

A bare Float is wrapped at the print site, as a `Bool` already is. One
nested inside a list or a tuple goes through the `__pyk_str` walker,
which gains an `isinstance(v, float)` arm — and gains it **only where
the module has a Float at all**, so a program without one carries
exactly the prelude it carried before.

**Division.** Python is the one host that *raises* where IEEE answers:
`1.0 / 0.0` is a `ZeroDivisionError` rather than `inf`. So a Float
division goes through `__pyk_fdiv`, beside the `__pyk_div` an Int
division already needs — for the opposite reason, but the same shape.

```python
def __pyk_fdiv(a, b):
    if b == 0.0:
        # Python raises where IEEE answers. Pyking follows IEEE.
        if a != a or a == 0.0:
            return float('nan')
        below = (a < 0.0) != (repr(b)[0] == '-')
        return float('-inf') if below else float('inf')
    return a / b
```

`float(n)` and `int(x)` are Python's own, which truncates toward zero
exactly as Pyking's `int` does.

## A loop's value needs no loop `else`

Python's `for`/`while` take an `else` clause that runs exactly when the
loop finished without a `break`, and this backend needs none of it: a
Pyking loop is worth its accumulator both ways it can stop, so the
accumulator variable already holds the answer whether the loop ran out
of turns or broke out of them.

```pyking                                    # generated Python
answer =                                     i, acc = 0, []
loop i, acc = 0, [] for x in xs:             for x in xs:
    (i + 1, [(i, x)] + acc)                      i, acc = i + 1, [(i, x)] + acc
                                             answer = (i, acc)
```

## Modules

Python's own module system is Pyking's, name for name, so this is the
one target where nothing has to be arranged: a module is a file, an
import is an `import`, and a public name is a name the module binds.

```pyking
# helper.pyk
priv = 3

public def inc(x:Int) -> Int:
    return x + priv


public greeting: String = "hi"
```

```pyking
# main.pyk
import helper
from helper import inc as bump

print(helper.inc(1))
print(bump(10))
print(helper.greeting)
```

```python
# helper.py
priv = 3

def inc(x):
    return x + priv

greeting = 'hi'
```

```python
# main.py (or whatever --output named it)
import helper
from helper import inc as bump
print(helper.inc(1))
print(bump(10))
print(helper.greeting)
```

**Privacy leaves no trace.** Python has none to express: `priv` is a
module-level name like any other, and nothing stops a hand-written
`helper.priv`. The rule is the front end's, and it has already refused
every Pyking program that would need one.

**Order needs nothing either.** A module's top level runs when Python
first imports it, which is before the importing module's own top level
gets any further — exactly Pyking's rule, for exactly the same reason.

**Renaming composes.** An import binds a name in the module scope like a
`def` does, so it goes through `bind` with everything else. Where the
Pyking name would land on a Python name already in use, the generated
import says so in Python's own words — `import helper as helper2`,
`from helper import inc as bump2` — and the qualified references follow
it.

## Where the output is not optimal

- **Renamed shadows.** Correct, but the generated names drift from the
  source (see above).
- **Comprehension helpers.** One generated function per refutable
  clause, plus a list allocation per element tested.
- **A `print` argument whose type is unknown pays for a function call.**
  `bool_kind` (see "Booleans" above) answers from the checker's own
  table, so a variable, a call and a list are all settled where their
  types are; what is left is a value the checker could not pin down,
  which falls back to the `__pyk_str` runtime walk on every run.
- **No `pass`.** Pyking has no empty block, so the case never arises —
  but it also means the backend has no way to emit one if the language
  ever gains it.
- **The immutability distinction disappears.** `=`, `var` and `:=` all
  become assignment (plus a `global`/`nonlocal` where one is needed), so
  generated Python will happily let you do things the Pyking source would
  have been rejected for. The checking lives in `src/typesystem.ml` and
  `src/analyses.ml`, ahead of every backend; it is not re-expressible in
  the output.
- **No optimisation of any kind.** The backend is a printer: no constant
  folding, no dead-code elimination, no tail calls. `1 + 2` compiles to
  `1 + 2`.

## External modules

A module implemented in Python (`sys.py`, declared in
`sys_external.pyk` -- see [modules.md](modules.md)) is an ordinary
module: the generated program writes `import sys` and reaches it as
`sys.loadfile(...)`, exactly as it would a compiled one. The file is
copied beside the program's output, where `import` finds it.

One thing an implementation has to watch, because Python will not:

- **A module's name is a name in Python's own namespace.** A Pyking
  module called `sys` or `os` will not be found -- the builtin wins.

Integers need no care. Python's `int` is unbounded, and Pyking leaves
overflow past the signed 32-bit range undefined, so an implementation
returns whatever Python computes.

The boundary carries `Int`, `String`, `Bool`, unit, tuples and lists,
each as Python's own.

## Let expressions

A `let target = value in body` (PYKING.md, "Let expressions") is compiled as the call of a lambda taking the name, `(lambda a: body)(x())`; a tuple target is a comprehension over the one value whose `for` takes it apart, and its only element, `[body for (a, b) in [x()]][0]`.
A call whose named arguments are not in parameter order, with more
than one that has an effect, reaches this backend as nested `let`s
(`docs/desugar_args.md`).

## Classes

A Pyking class (PYKING.md, "Classes and interfaces") is a Python class,
`src/classes.ml` saying what it has:

- **The class** names its parent and its interfaces as bases (an
  interface, or an abstract class with no parent, is an `abc.ABC`). Its
  body holds `__slots__` -- its own fields -- `_pyk_header`, the header's
  fields, which the Bool walker prints an object by, `__match_args__`
  (the same), which a class pattern matches by, and `_pyk_show = True`
  where the class has a `show`, which the walker then calls.
- **Each method** is a def at the module's top level named for its class,
  `Rect__area(self)`, and the class body names it: `area = Rect__area`,
  `name = override(Rect__name)` for an override, `area =
  abstractmethod(Shape__area)` where there is no body. Inside a class body
  Python would mangle the runtime's `__pyk_` helpers' names, which is why
  no method is written there. User defs never start with an uppercase
  letter, so these names meet none of the program's.
- **`__init__`** runs the parent's first, as an explicit
  `Parent.__init__(self, ...)`, then sets the class's own header fields
  and body fields; it answers nothing.
- **A private member** is written by the name Python's own mangling would
  give it inside its class, `_Account__balance`, everywhere, so it reads
  the same from a method and from the printer.
- **`super.m(...)`** is the static call `Owner.m(self, ...)` to the body
  the checker chose; Python's MRO plays no part. An upcast is nothing.
- **A class pattern** `case Dog(n, a)` is Python's own, by
  `__match_args__`; `case c: Cat` is `case Cat() as c`.
- `override` comes from `typing` (3.12+), `ABC` and `abstractmethod` from
  `abc`, imported only where used.
