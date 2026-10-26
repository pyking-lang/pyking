---
title: Reading what the reader types
---

# Reading what the reader types

```rules max = 5 pass = 3
Two tasks and a quiz. The first is compared with a solution, the
second with the output written under it.
```

`tw.text_input(placeholder, on_enter = f)` puts a text field on the
page. When the reader presses Enter in it, `f` is called with what was
typed. The field's id is its placeholder, or `text` when it has none.

```pyking readonly
import tinyweb as tw
tw.text_input("anything", on_enter = lam (words: String). print("got", words))
```

## Greeting

Show a label reading `Who are you?` and a text field whose placeholder
is `your name`. When a name is entered, the label should read
`Hello, ` and the name and `!`, and the program prints the same line.

```pyking task name = "greet" points = 2 attempts = 3
print("Add your code here")
```

```pyking solution available = true
import tinyweb as tw

shown = tw.label("Who are you?")

def greet(name: String):
    line = "Hello, " + name + "!"
    tw.set_text(shown, line)
    print(line)

tw.text_input("your name", on_enter = greet)
```

```events visible = true
enter "your name" "Ada"
```

```stdout visible = true
Hello, Ada!
```

```events
enter "your name" "Alan Turing"
enter "your name" "Grace"
```

## Counting letters

Make a text field with no placeholder. Each time something is entered,
print it between brackets and then how many characters it has, as
below. Nothing is printed before the first line is entered.

```pyking task name = "count" points = 2
print("Add your code here")
```

```events
enter "text" "pyking"
```

```stdout
[pyking] 6
```

```events
enter "text" ""
enter "text" "a b"
```

```stdout
[] 0
[a b] 3
```

## Quiz

```quiz name = "field-id" points = 1
What is the id of the field `tw.text_input("city")`?

* `"city"`

* `"text"`

* `"text_input"`
```

```answer
-> Right: a field with a placeholder is named by it.
- That is the id of a field with no placeholder.
- No, that is the kind of element.
```
