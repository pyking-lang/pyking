# Pyking

A small, lexically-scoped, Python-like language, and a compiler for it.

Pyking borrows its syntax from Python — literals, arithmetic, functions,
`for`/`while`/`if`, indentation-based blocks — and departs from it where
Python's dynamism gets in the way: plain `=` is an *immutable binding*
rather than an assignment, mutable variables are declared with `var` and
updated with `:=`, and every block is a real scope, checked at compile
time.

Pyking has no interpreter. It compiles, and the same program can be
emitted for several targets:

```sh
python3 boot/pykboot.py            hello.pyk   # ./hello.py  (python is the default)
python3 boot/pykboot.py -t nodejs  hello.pyk   # ./hello.js
python3 boot/pykboot.py -t html    hello.pyk   # ./hello.html
python3 boot/pykboot.py -t esm     hello.pyk   # ./hello.js + .node.js + .html + package.json
python3 boot/pykboot.py -t c89     hello.pyk   # ./hello.c  (C89)
python3 boot/pykboot.py -t c23     hello.pyk   # ./hello.c  (C23)
python3 boot/pykboot.py -t java8   hello.pyk   # ./Hello.java  (Java 8)
python3 boot/pykboot.py -t java17  hello.pyk   # ./Hello.java  (Java 17)
python3 boot/pykboot.py -t java21  hello.pyk   # ./Hello.java  (Java 21)
```

The output is named after the source unless `--output` says otherwise;
`--stdout` prints it instead, and `--ast` shows the parsed program.

`./pyk hello.pyk` compiles and runs a program in one step, and
`make test` runs the whole suite across every target.

## Documentation

- **[PYKING.md](PYKING.md)** — the language: feature summary, full EBNF
  grammar, scoping rules, and a worked example for every construct.
- **[docs/targets.md](docs/targets.md)** — the compiler targets: every
  one at a glance, which parts of the language each accepts, and links to
  a page per family ([Python](docs/target_python.md),
  [JavaScript](docs/target_js.md), [C](docs/target_c.md),
  [Java](docs/target_java.md)) documenting how each construct is compiled
  and where the output is not optimal.
- **[docs/architecture.md](docs/architecture.md)** — the compiler itself:
  pipeline diagram, the stages, the runtime interface that separates a
  program from the world it prints into, and how the tests work.
- **[CLAUDE.md](CLAUDE.md)** — repository conventions, for anyone (or
  anything) making changes here.

## Layout

| path | contents |
|---|---|
| `boot/` | the bootstrap compiler, one module per stage |
| `tests/` | Pyking programs, their expected output, and the test runner |
| `docs/` | design and architecture notes |
| `tools/emacs/` | a major mode for editing `.pyk` files |
| `src/` | reserved for the eventual self-hosted implementation |

Requires Python 3.11+ (`match`/`case`, `tomllib`). Running the generated
code needs `node` for the JavaScript targets, a C compiler for the C
ones, and a JDK (`javac`/`java`) for the Java ones; producing it needs
none of them. No third-party dependencies.
