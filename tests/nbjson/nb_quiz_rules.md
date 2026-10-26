# Strings, a short assignment

```rules max = 5 pass = 3
Answer the quizzes below. Each quiz says how many points it is worth;
you pass with 3 points of 5.
```

`len` gives the length of a string, and `+` joins two of them.

```pyking
s = "pyk" + "ing"
print(s, len(s))
```

What does `len("abc" + "de")` give?

```quiz name = "length" points = 2 attempts = 2
* 2

* 3

* 5
```

```answer
- That is the length of `"de"`.
- That is the length of `"abc"`.
-> The joined string is `"abcde"`.
```

Which of these are `String`s?

```quiz name = "strings" points = 3
[] `"42"`

[] `42`

[] `string(42)`
```

```answer
-> A string literal.
- An `Int`.
-> `string` turns its argument into a `String`.
```

A warm-up, worth nothing: which operator joins strings?

```quiz name = "warmup"
* `+`

* `&`
```

```answer
-> `+` joins two strings, as it adds two numbers.
- `&` is a bitwise and of two `Int`s.
```
