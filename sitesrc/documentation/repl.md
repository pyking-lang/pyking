---
title: REPL
description: The Pyking REPL, pyk repl - entering code, what it shows, use and imports in a session, meta-commands, completion and history.
sidebar:
  order: 5
  group: Tools
---

The REPL reads a piece of Pyking, checks it, runs it, and shows the
result. It is the interpreter with a prompt in front of it, so a value
means the same as it does in a program run with `pyk prog.pyk`.

## Starting it

```sh
$ pyk repl
Pyking REPL.  :help for commands, :quit to leave.
>
```

`:quit` (or `:q`, or Ctrl-D on an empty prompt) leaves.

| Flag | What it does |
|---|---|
| `--use FEATURE` | Turn a feature on from the start, as a `use` line would: `mutation`, `pointers` or `objects`. Repeat it for several. |
| `-L DIR` | Another directory of libraries to import from; see [the library search path](/documentation/command-line/#the-library-search-path). |
| `-W...` | Which warnings to show; see [Warnings](/documentation/command-line/#warnings). |
| `--tinyweb-log` | Print what a tinyweb page is sent, and what it answers, on standard error. |

The [playground](/documentation/playground/) has the same REPL in its
REPL tab; see [below](#in-the-playground).

## Entering code

Each thing you type at the prompt is an **entry**: one line or several.
An entry that is a whole statement on one line runs when you press
Enter:

```sh
> x = 1 + 2
> x * 10
30 : Int
> def double(n): n * 2
> double(x)
6 : Int
```

A line that opens a block, such as a `def` header ending in `:`, does
not run yet. Enter opens the next line, indented one level, and the
prompt changes to `. `. A blank line ends the entry and runs it:

```sh
> def fact(n: Int) -> Int:
.     if n == 0:
.         return 1
.     return n * fact(n - 1)
.
> fact(5)
120 : Int
```

**Shift+Return** ends the entry at once, whatever it looks like,
without the blank line. Not every terminal reports Shift+Return as a
key of its own; where it does not, it is an ordinary Return, and the
blank line ends the entry.

An `if` written on one line, such as `if c: print(1)`, waits for a
possible `else` on the next line, so it too ends with a blank line.

## What it shows

| You enter | It shows |
|---|---|
| An expression | Its value and its type: `30 : Int`. |
| A binding (`x = ...`, `var`, `:=`) | Nothing. |
| A `def` | Nothing. |
| A call to `print` | What it prints. |
| A function | `<function>` and its type. |

```sh
> [1, 2, 3]
[1, 2, 3] : [Int]
> (1, "a")
(1, "a") : (Int, String)
> lam x. x + 1
<function> : (Int) -> Int
> print("hello")
hello
```

`:ls` lists everything the session has bound, with values and types:

```sh
> :ls
x      = 3 : Int
double = <function> : (Int) -> Int
```

## Each entry builds on the ones before

An entry sees what earlier entries bound, the way one top-level block
of a file sees the blocks above it. Writing a name again in a later
entry is ordinary shadowing, so you can redefine a function to fix it:

```sh
> def double(n): n * 2
> def double(n): n + n
```

A function keeps what it saw when it was entered. Redefining a name
later does not change a function that already uses it.

Inside one entry, every `def` can see every other, as inside one block
of a file. So two functions that call each other must be typed in the
**same** entry:

```sh
> def ping(n: Int) -> Int:
.     if n == 0:
.         return 0
.     return 1 + pong(n - 1)
. def pong(n: Int) -> Int:
.     if n == 0:
.         return 0
.     return 1 + ping(n - 1)
.
> ping(6)
6 : Int
```

## `use` in a session

A file needs a `use` line before it can use `var` and `:=`, and so does
a session. A `use` line typed at the prompt turns the feature on for the
rest of the session:

```sh
> var count = 0
'<repl>' 1:0-1:3 Parsing error: 'var' declares a mutable variable,
  which needs 'use mutation' at the top of this module
> use mutation
> var count = 0
> count := count + 1
> count
1 : Int
```

`pyk repl --use mutation` starts with it on.

## Imports

An entry may import a module, as a file does. The module is looked for
in the current directory, then on the
[library search path](/documentation/command-line/#the-library-search-path),
which includes the standard library:

```sh
> import math
> math.sqrt(2.0)
1.4142135623730951 : Float
```

A module is loaded once per session, by the first entry that imports
it. A program's standard input is the session's own, and `sys.exit`
ends the session with its status.

A tinyweb program works too: once an entry has called
`tinyweb.web_init()`, the REPL serves its page and keeps delivering the
page's events while the prompt waits.

## Errors

An entry is checked as a whole before any of it runs. If one statement
has an error, nothing in the entry runs, and the session is as it was
before the entry:

```sh
> x + "a"
'<repl>' 1:0-1:7 Type error: `+` cannot be applied to Int and String;
  it accepts Int + Int or Float + Float or String + String or two
  lists of one type. `+` joins two Strings and converts nothing: write
  string(n)
```

Errors read exactly as they do for a file, with `'<repl>'` as the file
name. A runtime error is reported when it happens, and the session goes
on.

An entry that defines a function, and is refused only because it uses a
name not defined yet, is not thrown away. The REPL asks:

```sh
Identifier 'pong' is not yet defined. Press <esc> to cancel or <space> to continue editing.
```

Escape drops the entry. Any other key puts it back at the prompt, so you
can add the missing function to the same entry.

Warnings are shown as for a file, with one difference: a name bound at
the top level of an entry is never reported as unused, since a later
entry may still use it.

## Meta-commands

A line starting with `:` is a command to the REPL, not Pyking.

| Command | What it does |
|---|---|
| `:help` | List the commands. |
| `:quit`, `:q` | Leave (Ctrl-D does too). |
| `:ls` | List every name the session has bound, with its value and type. |
| `:type EXPR` | Show the type of an expression, without running it. |
| `:edit NAME` | Put the text that defined `NAME` back at the prompt, to change and enter again. |
| `:ast STMT` | Show the parsed form of a statement. |
| `:tokens LINE` | Show the tokens of a line. |
| `:load FILE` | Read a file and enter it as one entry. |
| `:reset` | Forget everything and start a new session. |

```sh
> :type double
(Int) -> Int
> :edit double
> def double(n): n * 2
```

`:load` and `:quit` are the terminal's only; the playground has the
rest.

## Keys

| Key | What it does |
|---|---|
| Enter | Run the entry if it is complete; otherwise start a new, indented line. On a blank line, run the entry. |
| Shift+Return | Run the entry now. |
| Tab | At the start of a line, indent. Elsewhere, complete the word before the cursor. |
| Backspace | In the indentation, remove one level. |
| Up, Down | Move between the lines of the entry, then through earlier entries. |
| Left, Right, Home, End | Move the cursor. Ctrl-A and Ctrl-E are Home and End. |
| Ctrl-K | Delete to the end of the line. |
| Ctrl-L | Clear the screen. |
| Escape, Ctrl-C | Drop the entry being typed. |
| Ctrl-D | On an empty prompt, leave. |

### Completion

Tab completes the word before the cursor. If one name fits, it is
completed; if several fit, it completes as far as they agree, and then
lists them with their types. What it offers depends on where you are:

- after `m.`, what module `m` exports;
- after `import` or `from`, module names: the standard library's and
  those the session has imported;
- after a `:` at the start of a line, the meta-commands;
- elsewhere, the names the session has bound, the imported modules, the
  builtins and the keywords.

### History

Up and Down go through the entries typed earlier in the session. They
bring back a whole entry, so a function of several lines comes back as
one piece, ready to edit. In the terminal, history lasts for the
session.

## In the playground

The playground's REPL tab runs the same session in the browser: entries
are checked and run the same way, and errors read the same.

- Enter runs a complete entry or opens a new line, as in the terminal.
  **Shift+Enter** always opens a new line. A blank line ends a block.
  The Keys tab of the settings can change these keys.
- Tab, Backspace, Escape, Up and Down work as above. The REPL's history
  is kept between visits.
- An entry's value is shown in green, what it prints in the ordinary
  colour, and an error in red.
- The commands are `:help`, `:ls`, `:type`, `:edit`, `:ast`, `:tokens`
  and `:reset`.
- The **Environment** table below the prompt shows what `:ls` would
  list: name, value and type, after every entry.
- **Copy from editor** puts the text selected in the editor into the
  prompt. **Stop** ends an entry that runs too long, and starts a new
  session. **Reset** is `:reset`. **Clear** empties the transcript and
  keeps the session.
- An entry may import the standard library. `io.read_line` reads the
  end of input and `sys.args()` is empty. `tinyweb` is refused there:
  use Run for a program with a page.

See [Playground](/documentation/playground/).
