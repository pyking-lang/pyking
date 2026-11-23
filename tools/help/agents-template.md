# This project is written in Pyking

Pyking looks like Python but is a different language: statically typed,
immutable by default, with its own syntax for lambdas, updates,
datatypes and more. Code written as Python will not compile.

**Before writing or changing any `.pyk` file, read `PYKING-LLM.md` in
this directory, all of it.** When it and Python disagree, it is right.

## Check every change

- `pyk check FILE.pyk` type-checks a program and the modules it
  imports without running it. Run it after every edit.
- `pyk FILE.pyk` runs a program. A program using `tinyweb` serves a web
  page and keeps running, so check it with `pyk check` instead.
- An error names the file, the line and what is wrong, and usually what
  to write instead. Fix exactly that, then check again. Do not change
  working code to silence a warning you do not understand.

## Look things up, do not guess

- `pyk ai lib` lists the standard library; `pyk ai lib NAME` lists what
  a library exports (`pyk ai lib text`, `pyk ai lib tinyweb`,
  `pyk ai lib tinyweb.color`); `pyk ai lib NAME.ITEM` shows one export
  in full, with an example (`pyk ai lib tinyweb.circle`).
  Run it before calling a library function you have not used here:
  names and parameter order differ from Python's.
- `pyk ai ref WORDS` prints the sections of the language reference whose
  titles hold the words (`pyk ai ref match`, `pyk ai ref loop`).
- A library of this project's own is a `.pyk` file: what it exports is
  marked `public`, and its `##` comments describe each export.

## Style

- Annotate every `def`'s parameters and result type.
- Put `use mutation` and `use objects` lines first, then the imports.
- Prefer `match`, comprehensions and `loop` over mutation where the
  program does not need state.
