# Immutable bindings

In Pyking a name bound with `=` keeps its value for as long as it is in
scope. To change a value later, declare it with `var` and update it
with `:=`.

```pyking
x = 3
var y = 4
y := y + x
print(x, y)
```

What does the program below print?

```pyking norun
var n = 1
n := n * 10
n := n + 2
print(n)
```

```quiz
* 1

* 10

* 12

* It is refused by the checker.
```

```answer
- `n` is updated twice before it is printed.
- The second update adds 2.
-> First `n` becomes 10, then 12.
- A `var` may be updated with `:=`.
```
