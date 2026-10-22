# Reading the reference

The language is described in the
[language reference](https://pyking.org/), and every example there can
be run.

Which line binds `x` to the **sum** of 1 and 2?

```quiz name = "binding" points = 1
* `x = 1 + 2`, an *immutable* binding.

* `x := 1 + 2`, which needs a **`var`** first.

* `x == 1 + 2`, see the [operators](https://pyking.org/) page.
```

```answer
-> Right: `=` binds **once**.
- `:=` only updates a name declared with `var`.
- `==` is a comparison giving a `Bool`; see [the reference](https://pyking.org/).
```

Which of these equal $2^3$?

```quiz name = "power" points = 2
[] `8`, that is $2 \cdot 2 \cdot 2$.

[] `2 * 3`, since $2 \times 3 = 6$.

[] `4 * 2`

[] **nine**
```

```answer
-> $2^3 = 8$.
- That is $6$, not $8$.
-> `4 * 2` is $8$ as well.
- **No**: $3^2 = 9$, not $2^3$.
```
