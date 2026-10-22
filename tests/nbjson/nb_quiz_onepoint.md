# Why types?

Every Pyking program is type-checked before it runs, whatever is then
done with it.

```quiz name = "useful" points = 2 one_point_correct = true
Why can static type checking be useful?

[] It enables duck typing in a general way.

[] It may rule out errors already at compile time.

[] It makes every program run without errors.

[] It may make the execution performance better.
```

```answer
- False, duck typing belongs to dynamic typing.
-> True, it can catch hard-to-detect errors before the program runs.
- False, a division by zero is still an error at run time.
-> True, some checks are no longer needed at run time.
```

When does Pyking check the types of a program?

```quiz name = "when" points = 1
* Before it runs, every time.

* Only when it is compiled to C.

* Never: types are only comments.
```

```answer
-> The checker runs for every program and every target.
- The interpreter checks the program too.
- An annotation is checked, not ignored.
```
