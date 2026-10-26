# Operators

Pyking has two numeric types, `Int` and `Float`, and mixes neither on
its own. Strings are joined with `+`, which converts nothing either.

```pyking
print(7 / 2, 7.0 / 2.0, "ab" + "c")
```

What does `7 / 2` give?

```quiz name = "divide" attempts = 3 points = 2 penalty = 1
* `3`, since both operands are `Int`s.

* `3.5`, since division always gives a `Float`.

* A type error.
```

```answer
-> Dividing two `Int`s gives an `Int`.
- Only two `Float`s give a `Float`.
- `/` accepts `Int / Int`.
```

Which expressions does the checker accept?

```quiz name = "accepted" attempts = 2 points = 3 available = true
[] `"ab" + "c"`

[] `"ab" + 1`

[] `1.5 + 2`, an addition
   of a `Float` and an `Int`.

[] `float(2) + 1.5`
```

```answer
-> `+` joins two strings.
- `+` converts nothing: `string(1)` makes the `Int` a `String`.
- An `Int` has to be made a `Float` first.
-> `float(2)` is a `Float`.
```

Which operator updates a `var`?

```quiz name = "update" points = 1 available = false
* `=`

* `:=`

* `==`
```

```answer
- `=` makes a new binding.
-> `:=` writes a new value into the `var`.
-
```

Which of these are comparisons?

```quiz name = "compare" attempts = 1 points = 2 penalty = 2
[] `a == b`

[] `a := b`

[] `a < b`, which asks whether `a` is
   smaller than `b`.
```

```answer
-> Equality.
- An update of a `var`.
-> An ordering.
```

Practice, worth no points: what is `string(3) + "x"`?

```quiz name = "practice" attempts = 5
* `"3x"`

* A type error.
```

```answer
-> `string` makes a `String` of the `Int`.
-
```
