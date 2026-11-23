---
title: AI-assisted programming
description: Set up a coding assistant -- also a small model running on your own machine -- to write Pyking, with pyk ai init, pyk check and pyk ai.
sidebar:
  order: 5
  group: Tools
---

A coding assistant, such as opencode or Claude Code, can write Pyking
for you. But a language model has seen very little Pyking, and Pyking
looks like Python, so a model left to itself writes Python: `True`,
`x = x + 1` to update a variable, `lambda x: ...`, `xs.append(x)`. The
compiler refuses all of it.

Pyking gives an assistant three things that fix this:

- **A short guide**, `PYKING-LLM.md`: about 5,000 tokens on how Pyking
  differs from Python, with an example of every construct. It is small
  enough for the context of a model running on your own machine.
- **A check it can run**, `pyk check FILE`: every error with its line
  and, most of the time, what to write instead.
- **Documentation it can look up**, `pyk ai lib` and `pyk ai ref`:
  every library function's signature and example, and any section of
  the language reference, as plain text in the terminal.

## Setting up a project

In the directory of your project, run:

```sh
pyk ai init
```

It writes three files:

| File | What it is | Read by |
|---|---|---|
| `AGENTS.md` | Instructions for the assistant: read `PYKING-LLM.md` first, run `pyk check` after every change, look libraries up with `pyk ai lib`. | opencode, Codex, Cursor, Zed, Aider and others ([agents.md](https://agents.md)) |
| `CLAUDE.md` | One line, `@AGENTS.md`, which makes Claude Code read `AGENTS.md`. | Claude Code |
| `PYKING-LLM.md` | The short guide to Pyking. | the assistant, told to by `AGENTS.md` |

Then start the assistant in the same directory. `AGENTS.md` and
`CLAUDE.md` are yours to change: add what your project needs, such as
how its programs are run. `pyk ai init` never overwrites them. Run it
again after updating Pyking: it brings `PYKING-LLM.md` up to date with
the new `pyk`, and leaves the other two as they are.

If the project already has an `AGENTS.md` or a `CLAUDE.md`, they are
kept, and `pyk ai init` says what line to add to them.

## What the assistant runs

| Command | What it prints |
|---|---|
| `pyk check prog.pyk` | The program's errors and warnings, from checking it and every module it imports. Nothing runs, so it also works for a tinyweb program, which would otherwise keep serving its page. It exits with 0 when there is no error. |
| `pyk ai guide` | The short guide, `PYKING-LLM.md`. |
| `pyk ai lib` | Every library and submodule, one line each. |
| `pyk ai lib text` | What a library exports: each signature with one line on what it does. A submodule is named in full, `pyk ai lib tinyweb.color`. |
| `pyk ai lib text --full` | The same, with every parameter and example. |
| `pyk ai lib text.split` | One export in full, with an example and what it prints. |
| `pyk ai lib circle` | An export found by its name alone, in whichever libraries have it. |
| `pyk ai ref` | Every section title of the language reference. |
| `pyk ai ref match` | The sections whose titles hold the words. |

Everything is printed from files that come with `pyk`, so it describes
the Pyking you have installed, and it works without a network.

## Libraries

The libraries are where an assistant guesses most, because their names
and the order of their parameters are not Python's: `text.split(s,
",")`, not `s.split(",")`, and `list.contains(x, xs)`, not `x in xs`.
`AGENTS.md` tells the assistant to look a library up before calling
it. For `tinyweb`, which has more than any other, it would run:

```sh
pyk ai lib tinyweb              # the page, canvases, drawing, events
pyk ai lib tinyweb.color        # colours and gradients
pyk ai lib tinyweb.circle       # one function in full
```

A library of your own is a `.pyk` file. What it exports is marked
`public`, and its `##` comments document each export, which is what an
assistant reads in it.

## Using a model on your own machine

Any harness that reads `AGENTS.md` or `CLAUDE.md` works, with any model
it can talk to. A few things matter more for a small model than for a
large one:

- **Give it enough context.** The guide is about 5,000 tokens, and the
  assistant needs room for the program and the compiler's answers as
  well: allow 16,000 tokens at least, 32,000 if you can. Some model
  servers give a model only a few thousand by default, and quietly cut
  off the start of the conversation, which is where the guide is.
- **Keep the guide in context.** In opencode, listing the guide under
  `instructions` in `opencode.json` puts it in every conversation,
  instead of relying on the model to read it:

  ```json
  {
    "$schema": "https://opencode.ai/config.json",
    "instructions": ["PYKING-LLM.md"]
  }
  ```

- **Ask for small steps.** A function, then its test, then the next
  one. Ask the assistant to run `pyk check` after each step and to fix
  what it reports before going on.
- **Point it at the error.** When it is stuck, tell it to read the
  compiler's message again: it usually says exactly what to write.

## On the web

The same files are on this site, for tools that read documentation
from a web address, following the [llms.txt](https://llmstxt.org)
convention:

| Address | What it is |
|---|---|
| [`/llms.txt`](/llms.txt) | An index: what Pyking is, and a link to everything below. |
| [`/llms-small.txt`](/llms-small.txt) | The short guide, `PYKING-LLM.md`. |
| [`/llms-full.txt`](/llms-full.txt) | The whole language reference, about 80,000 tokens. |
| [`/llms/AGENTS.md`](/llms/AGENTS.md) | The `AGENTS.md` that `pyk ai init` writes. |
| `/llms/lib/NAME.md`, `/llms/lib/NAME.full.md` | A library, short and in full, as `pyk ai lib` prints it. |

The [language reference](/documentation/language/) is the full story
of the language; the guide is a summary of it for someone who already
knows Python.
