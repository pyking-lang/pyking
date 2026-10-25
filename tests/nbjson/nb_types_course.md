# Types in Pyking

Pyking is statically typed: every program is checked before it runs.
This lesson goes through the basic types, what the checker infers, and
what it refuses.

## The basic types

| Type | Example values | Written as |
|:-----|:---------------|:-----------|
| `Int` | `0`, `-7`, `42` | digits |
| `Float` | `1.5`, `0.25` | digits with a point |
| `String` | `"hi"` | in double quotes |
| `Bool` | `true`, `false` | the two words |
| `()` | `()` | unit |

```pyking
print(42, 1.5, "hi", true)
```

A binding may say its type. The checker then holds the value to it:

```pyking readonly
n: Int = 3
name: String = "Ada"
print(name, n)
```

> [!NOTE]
> An annotation is checked, not trusted: a wrong one is a type error.

```pyking error
n: Int = "three"
print(n)
```

## Functions

A function's parameters and result can be annotated too. Where they
are not, the checker works them out from the body.

```pyking
def double(x: Int) -> Int:
    x * 2

def twice(f, x):
    f(f(x))

print(double(5), twice(double, 3))
```

A fragment, not meant to run on its own:

```pyking norun
def area(w: Float, h: Float) -> Float: ...
```

## Conversions

Nothing is converted on its own. `int`, `float` and `string` convert
explicitly, which is how a program reads a number:

```pyking stdin = "21"
import io
n = int(io.read_line())
print(n * 2)
```

## Check yourself

What is the type of `[1.5, 2.5]`?

```quiz name = "list-type" points = 1 attempts = 2
* `[Float]`

* `[Int]`

* `Float`
```

```answer
-> A list of `Float`s.
- `1.5` is not an `Int`.
- It is a list, not one number.
```

Which of these does the checker refuse?

```quiz name = "refused" points = 2 available = true
[] `x: Int = 2.0`

[] `y = 1 + 2`

[] `z = 1.0 + 2`

[] `w: String = string(3)`
```

```answer
-> `2.0` is a `Float`, not an `Int`.
- Two `Int`s add to an `Int`.
-> A `Float` and an `Int` do not mix.
- `string(3)` is a `String`.
```

## Task

Write a program that reads a temperature in whole degrees Celsius and
prints it in Fahrenheit as a `Float`: $F = C \cdot 9 / 5 + 32$.
Convert with `float` before computing.

```pyking task name = "fahrenheit" points = 3 attempts = 3 stdin = "100"
print("Add your code here")
```

```pyking solution
import io
c = int(io.read_line())
print(float(c) * 9.0 / 5.0 + 32.0)
```

```stdin visible = true
0
```

```stdout visible = true
32.0
```

```stdin
37
```

```stdin
-40
```
