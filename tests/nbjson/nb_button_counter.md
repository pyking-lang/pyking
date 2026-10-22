# Counting clicks

A button runs a function every time it is clicked. The function is
called by the page long after the program's top level has ended, so
whatever it should remember between clicks lives in a `var`, which the
function changes with `:=`.

```pyking
import tinyweb as tw
tw.button("Hello", on_click = () => print("hello!"))
```

## Exercise

Make a button titled `Click me` and a label reading `0 clicks`. Every
click adds one to a count, prints `clicked` and the count, and sets the
label to the count followed by ` clicks`. Before any click the program
prints `ready`.

```pyking exercise name = "counter" points = 3
print("Add your code here")
```

```pyking solution
import tinyweb as tw

var count = 0
shown = tw.label("0 clicks")

def clicked():
    count := count + 1
    print("clicked", count)
    tw.set_text(shown, string(count) ++ " clicks")

tw.button("Click me", on_click = clicked)
print("ready")
```

```events
```

```stdout
ready
```

```events visible = true
click "Click me"
```

```stdout visible = true
ready
clicked 1
```

```events
click "Click me"
click "Click me"
click "Click me"
```

```stdout
ready
clicked 1
clicked 2
clicked 3
```

## Quiz

```quiz name = "why-var" points = 1
Why must the count be a `var` rather than `count = 0`?

[] A name bound with `=` can never be given another value.

[] A function may not read a name bound with `=` outside it.

[] `:=` may only change a `var`.
```

```answer
-> Right: `=` binds a name once and for all.
- It may read it; it may not change it.
-> Right.
```
