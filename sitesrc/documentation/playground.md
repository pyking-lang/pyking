---
title: Playground
description: Write, run, compile, debug and share Pyking programs in the browser, with nothing to install.
sidebar:
  order: 2
  group: Tools
---

The [playground](/playground/) is an editor for Pyking in a web page.
You write a program on the left and run it, compile it for another
language, step through it in a debugger or try it out line by line in
a REPL, on the right.

The page holds the real Pyking compiler, compiled to JavaScript. It
checks, runs and compiles your program in the browser, the same way
`pyk` does on your computer. **Nothing runs on a server**, and your
program is never sent anywhere.

There are two copies of it:

- The website's, at [/playground/](/playground/).
- Your own, served by `pyk` from your computer, with no internet
  connection needed once Pyking is [installed](/install/):

```sh
pyk playground              # serves it and prints a link to open
pyk playground --port 9000  # on a port of your choice
```

## The layout

The editor is on the left. The right-hand side has six tabs:

| Tab | What it shows |
|---|---|
| **Run output** | what the program printed when you pressed ▶ Run |
| **Compiled code** | the program compiled for a target, and what running that printed |
| **Web output** | the page a `tinyweb` program draws |
| **REPL** | a Pyking REPL, an entry at a time |
| **Debug** | the program run a step at a time |
| **Help** | this documentation |

The page opens on Run output. Drag the bar between the two columns to
make one wider. The Compiled code, Web output and REPL tabs also have a
bar across them, between the upper and lower part, that you can drag.
A pane can be made small, but not dragged out of sight. **Reset pane
sizes**, under Settings, Appearance, puts them back.

The playground remembers where you were. Reload the page and you find
the program, the cursor, the target, the tab, the output, the last
input and the REPL's history as you left them. This lasts as long as the
browser tab: a new tab starts again with the first example. On the
website, going to another section and coming back leaves the playground
exactly as it was, even a program that is running or stopped in the
debugger.

The header shows the version of Pyking the page runs and a status pill:
`starting…` and `loading compiler…` while the compiler loads, then
`ready`. The first load takes a moment. After that a compile takes
about a millisecond.

## Writing code

The editor is [Monaco](https://microsoft.github.io/monaco-editor/), the
editor VS Code is built on. It highlights Pyking, and it talks to the
Pyking language server, which runs in the page. So you get what an
editor set up with `pyk lsp` gives (see [Editors](/documentation/editors/)):

- **Errors as you type.** A short moment after you stop typing, the
  first error is underlined where it is. Hover over it to read it.
  Warnings, such as a name that is never used, are underlined too.
- **Hover**: the type of what is under the pointer.
- **Completion**: keywords, builtins, the names in scope, and after
  `m.` what module `m` exports.
- **Signature help**: a function's parameters while you type a call.
- **Go to definition** (F12, or Ctrl+click, Cmd+click on a Mac), and
  **Peek Definition** (Alt+F12), which also shows a definition in the
  standard library.
- **Outline** (Ctrl+Shift+O, Cmd+Shift+O on a Mac): the `def`s,
  bindings and imports.
- **References** (Shift+F12), **highlights** of a name, and
  **rename** (F2).
- **Folding**, **semantic highlighting**, and **quick fixes**: the light
  bulb offers a fix for an error that says what was meant, such as a
  missing `use mutation` line.

## Examples

The **Examples** list above the editor holds the programs that
`pyk example` lists: hello world, a program that reads its arguments,
`tinyweb` graphics and sound, a drum pad, a sequencer, a piano, and
classes and interfaces. Rest the pointer on one to read what it does.
Choosing one replaces the program in the editor.

The same examples are on your computer:

```sh
pyk example                # list them
pyk example drum_pad.pyk   # save one in the current directory
```

## Running a program

**▶ Run**, above the editor, runs the program with the Pyking
interpreter, whatever target is chosen. Shift+Enter or Ctrl+Enter
(Cmd+Enter on a Mac) in the editor does the same. Before it runs, the
program is checked, exactly as `pyk` checks it. A program the checker
refuses is not run, and the error is written in the output and
underlined in the editor.

What the program prints appears on **Run output** line by line as it is
printed, so a program that prints and then hangs still shows what it
printed. A line written by `debug` is shown dimmed, and warnings are
shown first, in their own colour.

A program may import the standard library, `tinyweb` included. It is
one file: there is no way to add modules of your own.

### Standard input and arguments

When a program reads standard input (`io.read_line`, `io.read`,
`io.is_eof`) or its arguments (`sys.args()`), ▶ Run first opens a
dialog, **Before it runs**, with a **Standard input** box and an
**Arguments** line. Type the input, one line for each line the program
reads, and the arguments separated by spaces, with quotes to keep a
space inside one. Then press ▶ Run in the dialog. The dialog offers the
values you gave last time.

For example, this program asks for both:

```stdin
Ada
```

```pyking
import io
import sys

name = io.read_line()
print("Hello, " + name + "!")
print(sys.args())
```

A line the program reads is echoed in the output.

### Stop

While a program runs, ▶ Run becomes **■ Stop**, and the same keys stop
it. A program that never ends does not freeze the page. Try this one:

```pyking norun
use mutation

var i = 0
while i < 1:
    i := 0
```

Press ▶ Run, and then ■ Stop. The compiler restarts after a stop, which
takes a moment.

### Settings for running

Under Settings, **Running**:

- **Run while you type** (off by default): the program runs about half
  a second after you stop typing, as if you had pressed ▶ Run. A run
  like this does not ask for input; it uses the last values given.
- **Clear it each time you press Run** (on by default): the output is
  emptied before each run.
- **Scrollable** (on by default): the output scrolls and follows the
  newest line. Off, it is clipped instead.

## Compiled code

The **Compiled code** tab shows what the program becomes in another
language.

1. Choose a target in the **Target** list: Python, JavaScript for
   node or for a web page, C, Java, OCaml, or `pyking`. See
   [Compiler targets](/documentation/targets/) for what each one is.
2. Press **Compile**. The generated code appears in the upper pane, and
   what the compiler said in the lower one. An error is also underlined
   in the editor.

A program that imports modules compiles into several files. Their names
are listed above the code, the program's own file first; click one to
see it.

The `pyking` target shows your program as the checker read it, with
every type it inferred written in. It is a quick way to see the types
of a whole program at once.

The other buttons on the tab:

- **▶ Run** runs the code that is shown, edits included. It works for
  the node and web targets, the ones a browser can run. For Python, C,
  Java and OCaml it is greyed out, and its tooltip says why: there is no
  Python, C compiler, JVM or OCaml in a browser.
- **Copy** copies the generated code.
- **Download** saves the compiled program as a zip file,
  `playground-<target>.zip`. It holds every file the compiler wrote,
  the parts of the standard library the program needs, and a
  `Makefile`. Unpack it, and on a computer with the target's tools
  installed:

```sh
make          # build it
make run      # build it and run it (a web page is served with pyk serve)
make clean    # remove what make built
```

A generated C or Java file also starts with a comment that gives the
command to build it by hand.

## Web output

A program that imports `tinyweb` draws a page: canvases, buttons,
sliders, text, and sound. ▶ Run switches to the **Web output** tab and
shows the page in a frame drawn as a browser window, with the program's
printed output below it.

Such a program goes on running after its last line, because the page
calls back the functions it was given, for example when a button is
clicked. So ■ Stop stays shown until you press it. When nothing runs,
the frame is empty. **↻ Refresh**, in the frame's title bar, stops the
program and runs it again.

The window has the keyboard while its frame is outlined. Click in it
to give it the keyboard, and click outside it, in the editor say, to
take it away. ▶ Run gives the window the keyboard, so a game can be
played at once.

The **tinyweb log** switch above the output shows what the program
sends its page and what the page answers, one line each, as
`pyk --tinyweb-log` does. It is also under Settings, Running.

Try the `tinyweb1.pyk` or `drum_pad.pyk` example to see it.

## REPL

The **REPL** tab is the Pyking REPL, as `pyk repl` gives it in a
terminal (see [REPL](/documentation/repl/)). Each entry is checked
against the entries before it and run.

- **Enter** runs an entry that is complete, and otherwise opens the next
  line, indented after a `:`. A blank line ends a block.
- **Shift+Enter** always opens a new line.
- **Tab** indents at the start of a line, and completes the word before
  the cursor elsewhere, listing what fits, with types.
- **Up** and **Down** go through the entries you typed before.
- **Escape** empties the prompt.

A value is shown in green as `value : Type`, what an entry prints in
the ordinary colour, and an error in red. The commands `:help`, `:ls`,
`:type`, `:edit`, `:ast`, `:tokens` and `:reset` work as in the
terminal.

The **Environment** table below the prompt lists every name the session
has defined, with its value and type, and is updated after each entry.

The buttons above it:

- **Copy from editor** puts the text marked in the editor into the
  prompt, without the indentation its lines share.
- **■ Stop** shows while an entry runs. It ends the session, and a new
  one starts.
- **Reset** forgets every name, as `:reset` does.
- **Clear** empties the transcript and keeps the session.

An entry may import the standard library, but not `tinyweb`: a page
needs ▶ Run. `io.read_line` finds no input here, and `sys.args()` is
empty.

## Debug

The **Debug** tab runs the program in the editor a step at a time.
Click in the margin left of the line numbers to set a breakpoint, and
press **Debug** (Alt+D). The program stops at the breakpoint, or at the
first statement when there is none. From there you can continue, step
over, into and out of calls, look at every variable and change a
`var`'s value, watch expressions, see the calls in progress, set
conditions on breakpoints, and evaluate expressions in a console.

[Debugging](/getstarted/debugging/) shows how to use it. The keys are
in the table under "Keyboard shortcuts" below.

## Help

The **Help** tab holds this website's documentation: Getting started,
the Documentation and the Libraries. A menu above the page lists the
sections and the headings of the page you read. Every example on these
pages is a cell you can run right there, and its **Copy to editor**
button puts it in the editor.

The help comes with the playground, so it also works in a playground you
serve yourself with no internet connection. `pyk pykhelp` opens the same
help in a browser tab of its own.

## Sharing a program

**Copy code as link**, beside Examples, copies a link to the program in
the editor. Whoever opens the link gets the playground with that program
in the editor. It is not run until they press ▶ Run.

The program is in the link itself, after `#code=`. The part of an
address after `#` is never sent to a server, so the program does not
leave your computer until you send the link to someone. A long program
makes a long link.

The cells on this website have the same kind of link: a **Try in
playground** button opens the cell's code in the playground.

```pyking playground
def square(n: Int) -> Int:
    return n * n

print([square(n) for n in range(1, 6)])
```

## Copy for slides

**Copy for slides** copies the code in an editor, coloured, ready to be
pasted on a slide in Keynote, PowerPoint or Google Slides. It copies
the selection, or the whole program when nothing is selected, from
either editor: your program, or the compiled code. The code stays text
on the slide, so a reader can still copy it.

It is in each editor's right-click menu, and on Alt+Shift+C
(Option+Shift+C on a Mac). Settings, **Copy for slides** sets the
colours (light or dark), the font, the size in points, the background
and the kind of spaces, with a preview, and can put a Copy for slides
button above the editor.

[Code on slides](/documentation/slides/) has more, including
`pyk highlight`, which does the same from the command line.

## Settings

The **Settings** button in the header opens a dialog with six tabs. The
arrow keys move between the tabs, and Escape, the ✕ or a click outside
closes it. Every setting is remembered in your browser, so the
playground looks the same next time.

| Tab | What it sets |
|---|---|
| **Appearance** | the theme: the same as the system (the default), light or dark; the font size, 10 to 26 pixels, for both editors, the output and the REPL; Reset pane sizes |
| **Running** | Run while you type, clearing the output on each run, scrollable output, and the tinyweb log |
| **Warnings** | which warnings are reported, and which count as errors |
| **Debugger** | whether to stop at the first statement, and whether to step over the standard library's code |
| **Copy for slides** | the options above, with a preview |
| **Keys** | the keys of every command |

The ☀/☾ button in the header also switches between light and dark.

### Warnings

A warning reports a program that checks but may still be wrong: a name
bound and never used, for example. The program still runs. The Warnings
tab has one row for each warning: a box that turns it on, its flag as
`pyk` takes it (`-Wunused-binding`), whether it is on by default, and an
**as an error** box, which makes it stop the program instead.

Below them are **Every warning that is on is an error** (`-Werror`),
**Turn them all on** (`-Wall`), **Turn them all off** (`-w`) and **Back
to the defaults**. The tab also shows the `pyk` command line that has
the same effect. A change applies at once, to Run, Compile, the REPL,
the Debug tab and the underlines in the editor.

There is no setting to turn type checking off. Pyking is statically
typed, and every program is checked before it runs.

### Keys

The Keys tab lists every key the playground adds, by area: Editor,
Debugger and REPL. Each command's keys are shown as chips. **✕** removes
a key, **+** records the next key you press (Escape leaves it),
**reset** gives a command back its default keys, and **Reset all the
keys** does so for every command. Tooltips and the right-click menu
always name a command's current keys. Monaco's own editing keys are not
in the list.

## Keyboard shortcuts

These are the defaults. On a Mac, Ctrl is Cmd where the table says so,
and Alt is Option.

| Keys | Where | What it does |
|---|---|---|
| Shift+Enter, Ctrl+Enter (Mac: Cmd+Enter, Ctrl+Enter) | editor | run the program, or stop it while it runs |
| Shift+Enter, Ctrl+Enter (Mac: Cmd+Enter, Ctrl+Enter) | compiled code | run the compiled code |
| Alt+Shift+C | either editor | Copy for slides |
| F12, Ctrl+click (Mac: Cmd+click) | editor | go to definition |
| Alt+F12 | editor | peek definition |
| Shift+F12 | editor | find references |
| F2 | editor | rename |
| Ctrl+Shift+O (Mac: Cmd+Shift+O) | editor | outline |
| Alt+D | anywhere | start debugging, or start again |
| F8, Alt+C | anywhere | continue, or pause |
| F10, Alt+O | anywhere | step over |
| F11, Alt+I | anywhere | step into |
| Shift+F11, Alt+T | anywhere | step out |
| Alt+S | editor, Debug tab | stop debugging |
| Alt+B | editor, Debug tab | set or remove a breakpoint on the cursor's line |
| Enter | REPL | run the entry, or open the next line |
| Shift+Enter | REPL | open a new line |
| Tab | REPL | complete the word, or indent |
| Up, Down | REPL | the entry before, the entry after |
| Escape | REPL | empty the prompt |
| Escape | Settings | close the dialog |

All but the editor's own keys (go to definition and the rest) can be
changed under Settings, Keys.

## Embedding the playground in another page

The playground is one component, which a page of your own can mount, for
example in course material. A Pyking installation holds its files:
`tools/playground/assets/`, `tools/webrun/assets/` and
`tools/webrun/vendor/`, the compiler `share/pyking.js`, and the
libraries in `lib/`. Serve them side by side, as `pyk playground` does,
and point the options at them:

```html
<link rel="stylesheet" href="assets/playground.css">
<div id="host" style="height: 90vh"></div>
<script type="module">
  import { mountPlayground } from "./assets/playground.js";
  mountPlayground(document.getElementById("host"), {
    base: "./assets",             // playground.json, js-worker.js
    webrunURL: "./webrun/",       // tools/webrun/assets
    vendorURL: "./vendor/",       // tools/webrun/vendor (Monaco)
    pykingURL: "./pyking/",       // pyking.js
    examplesURL: "./examples/",   // the example programs
    initialTarget: "c23",
    initialExample: "hello.pyk",
    readLink: true,               // open a #code=... link's program
    keepState: true,              // keep the program and the rest for the tab
    theme: "light",               // omit to let the reader choose
  });
</script>
```

Every option has a default. `readLink: false` ignores a program in the
page's own address, and `keepState: false` starts afresh on every load.
With `theme` given, the page decides the theme and the playground hides
its own switch. The starting sizes of the panes can be set from CSS:

```css
#host { --pyk-col-split: 40%; --pyk-out-split: 25%; }
```

The page must be served over HTTP, by `pyk serve` or any web server
that handles several connections at once. Opened as a `file://` address
it does not load, since browsers block what it needs there.

## Limitations

- **Python, C, Java and OCaml do not run in the page.** Compile and look
  at them, then Download them and `make run` on your computer, or use
  `pyk compile` (see [Command line](/documentation/command-line/)).
- **One file.** A program can import the standard library, but not
  modules of its own.
- **No `iweb` target.** It packages a program with the interpreter so a
  browser can run it, which is what the playground already does.
- **The first load is about 11 MB**: the compiler and the editor. After
  that the browser keeps them.
- **Nothing is saved on a server.** A program lasts as long as the
  browser tab. To keep it, copy it into a file, or keep its link from
  Copy code as link.
- **The REPL has no input and no pages**: `io.read_line` finds no input,
  and `tinyweb` is refused there.
