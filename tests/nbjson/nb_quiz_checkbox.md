# Lists in Pyking

A list holds values of one type, written between square brackets:
`[1, 2, 3]` is a `[Int]`. `len` gives its length.

```pyking
xs = [1, 2, 3]
print(len(xs), xs)
```

```quiz name = "lists" points = 3 attempts = 2
Which of these are well-typed Pyking lists?

[] `[1, 2, 3]`

[] `[1, "two", 3]`

[] `["a", "b"]`

[] `[true, 1]`

[] `[[1], [2, 3]]`
```

```answer
-> A list of three `Int`s.
- An `Int` and a `String` cannot share one list.
-> A list of two `String`s.
- A `Bool` and an `Int` cannot share one list.
-> A list of lists of `Int`, a `[[Int]]`.
```
