---
title: Pyking
description: A small, statically typed, Python-like language that compiles to Python, JavaScript, C, Java and OCaml.
template: splash
hero:
  tagline: A small, statically typed language that reads like Python and compiles to Python, JavaScript, C, Java and OCaml.
  actions:
    - text: Get started
      link: /getstarted/overview/
      icon: right-arrow
    - text: Install
      link: /install/
      variant: minimal
    - text: Open the playground
      link: /playground/
      variant: minimal
---

## Try it

This is a whole Pyking program. Press **▶** to run it in your browser,
change it, and run it again.

```pyking
def greet(name: String) -> String:
    return "Hello, " ++ name

for name in ["Ada", "Grace", "Barbara"]:
    print(greet(name))
```

## What Pyking is

- **Python's syntax, with stricter rules.** Indentation, `def`, `for`,
  `if` and `match` work as they do in Python. A name bound with `=`
  cannot change. A variable that changes is declared with `var` and
  updated with `:=`. Every block is a scope.
- **Statically typed, with types inferred.** Every program is checked
  before it runs. You write types where they help a reader, and the
  checker works out the rest.
- **Compiles to many targets.** `pyk compile` turns one program into
  Python, JavaScript for node or the browser, C89 to C23, Java 8 to 21,
  or OCaml. `pyk` with no command runs the program with the
  interpreter.
- **Comes with an interpreter, a REPL and notebooks.** `pyk repl` starts
  an interactive session. `pyk notebook` serves a Markdown file whose
  code runs in the browser, like the examples on this site.
