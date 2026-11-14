---
title: Debugging
description: Find out what a Pyking program does, with debug statements and with the debugger in the playground and in your editor.
sidebar:
  order: 3
---

There are three ways to see what a program does, from the simplest to
the fullest: `debug` statements, the debugger in the playground, and
the debugger in your editor. Both debuggers are one debugger, so
stepping means the same in each.

## `debug` statements

`debug(...)` is `print` for diagnostics. It takes the same arguments
and formats them the same way, but writes the line to standard error,
so tracing a program does not change what it prints.

```pyking
def square(x: Int) -> Int:
    debug("square of", x)
    return x * x

print(square(7))
```

Run with `pyk prog.pyk`, this writes `square of 7` to standard error
and `49` to standard output. `pyk prog.pyk 2>/dev/null` shows the
output alone.

### Release mode

`pyk compile --release` compiles a program with every call to `debug`
removed, arguments and all, and every `print` kept. Since the
arguments are never worked out, anything they would have done does not
happen either:

```pyking
use mutation

var calls = 0

def next_call() -> Int:
    calls += 1
    return calls

debug("this is call", next_call())
print("calls made:", calls)
```

```sh
pyk counted.pyk                          # this is call 1 (on stderr), calls made: 1
pyk compile counted.pyk --release --run  # calls made: 0
```

`--release` applies only to `pyk compile`. Keep side effects out of
`debug`'s arguments, so the program means the same in both modes.
Because writing a diagnostic is not something a program is observed
to do, `debug` will be allowed in pure functions, where `print` will
not.

### Where `debug` output appears

- **In a terminal**, on standard error, beside the program's output.
- **In the playground**, in the same output pane as `print`, dimmed.
- **In a notebook**, under the cell, marked apart from its output.
- **In an editor's debugger**, in the debug console, as standard error.

## The debugger in the playground

The [playground](/playground/)'s **Debug** tab runs the program in the
editor with the interpreter, a step at a time.

- **Breakpoints.** Click in the editor's margin, left of the line
  numbers, to set one. The line the program stopped at is marked in
  yellow. Debug with no breakpoint stops at the first statement.
- **Controls.** Debug (Restart once started), Continue or Pause, step
  Over, step Into, step Out, and Stop. Each names its keys when the
  pointer rests on it.
- **Environment** shows every name the chosen call sees: its own names
  first, then the rest. A list, a tuple or a datatype value opens to
  show its parts.
- **Watch** holds expressions worked out each time the program stops.
- **Call stack** shows the calls in progress. Choosing one shows its
  names and marks its line.
- **Breakpoints** lists each breakpoint, with a switch and fields for a
  condition, a hit count and a log message.
- **Console** shows what the program writes. An expression typed there
  is worked out where the program stopped.

| key | does |
|---|---|
| Alt+D | starts, or restarts |
| F8 or Alt+C | continues, pauses, or starts when nothing is debugged |
| F10 or Alt+O | steps over |
| F11 or Alt+I | steps into |
| Shift+F11 or Alt+T | steps out |
| Alt+S | stops |
| Alt+B | sets or removes a breakpoint on the cursor's line |

Alt is Option on a Mac. The settings' Keys tab changes the keys, and
the Debugger tab says whether to stop at the first statement and
whether to step over the standard library's code.

### Expressions where the program stopped

A watch, an expression in the console, a breakpoint's condition and a
log message are all checked the same way: as an expression at the
place the program stopped, type-checked against the names in scope
there. Only a `var` can be given a new value, which in the playground
is done by double-clicking it in the Environment. An `=` binding never
changes, and the debugger says so.

### Breakpoint kinds

A breakpoint stops at the first statement starting on its line or
after it. It may also have:

- a **condition**, a Bool expression: it stops only when that is true;
- a **hit count**: `3` stops the third time only, `>= 3` from the third
  time on, `% 2` every second time;
- a **log message**, which is printed instead of stopping, with each
  `{expression}` in it replaced by its value. This makes it a
  logpoint.

A runtime error also stops the program where it happens, with its calls
still in progress.

### tinyweb callbacks

A [tinyweb](/libraries/tinyweb/) program does most of its work in
callbacks, after its last line has run. A breakpoint in a callback
stops when its event arrives, and the page's events wait while the
program is stopped. The page itself is on the Web output tab.

## The debugger in an editor

The Debug Adapter Protocol (DAP) is a standard way for an editor to
talk to a debugger. `pyk dap` is Pyking's debug adapter: an editor
starts it, and it speaks DAP on standard input and output. It shares
its core with the playground's Debug tab, so stepping, breakpoints and
expressions behave the same in both.

```sh
pyk dap [--stdio] [--log FILE] [-W...]
```

`pyk dap` always runs the program with the interpreter, as
`pyk prog.pyk` does; it never debugs a compiled target. `--stdio` is the
only transport and is accepted because some editors pass it. `--log
FILE` appends every message in and out to `FILE`, for finding out why
an editor's setup does not work. The `-W` flags say which warnings are
checked, as for `pyk`.

### Launch options

The editor's *launch* request says what to run. In VS Code these go in
a configuration in `.vscode/launch.json`; other editors have their own
place for them.

| argument | default | meaning |
|---|---|---|
| `program` | | the Pyking file to run |
| `args` | `[]` | the program's own arguments, what `sys.args()` answers |
| `stdin` | | a file the program reads as its standard input; without one it reads nothing |
| `cwd` | | the directory the program runs in |
| `stopOnEntry` | `false` | stop at the first statement |
| `justMyCode` | `true` | step over the code of the standard library and of `-L` libraries |
| `libPath` | `[]` | more library directories, searched after `-L` |
| `release` | `false` | debug the program as `--release` compiles it, every `debug()` removed |
| `warnings` | `[]` | `pyk`'s -W flags for the program's check, after those `pyk dap` was started with; its warnings are written to the debug console, and one made an error stops the launch |

### Breakpoints in an editor

The breakpoint kinds are those of the playground: a line breakpoint,
with an optional condition, hit count or log message. A runtime error
stops the program where it happens unless the editor turns off the
**Runtime errors** breakpoint, which it lists with the exception
breakpoints. An expression evaluated where the program stopped -- a
watch, the debug console, a hover -- is type-checked against the names
in scope there, and only a `var` can be given a new value. A tinyweb
program's callbacks are debugged too: a breakpoint in one stops when
its event arrives.

The program's standard output and its `debug` lines arrive in the
editor's debug console, as standard output and standard error.

### Setting it up

The [Editors](/documentation/editors/) page shows how to start `pyk
dap` in VS Code, Cursor, Neovim, Vim, Emacs, PyCharm and IntelliJ IDEA,
and Helix. In VS Code and Cursor, the Pyking extension sets it up:
with a `.pyk` file open, **Run > Start Debugging** debugs it.
