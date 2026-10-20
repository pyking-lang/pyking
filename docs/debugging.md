# Debugging

Pyking has one debugger, reached two ways: `pyk dap`, a Debug Adapter
Protocol server an editor starts, and the playground's Debug tab. Both
run the program with the interpreter, so what the debugger shows is what
the program means (docs/interpreter.md); no compiled target is debugged.
The website's Editors page says how to start `pyk dap` in each editor.

## One core, two transports

```
             src/debug_session.ml  (a session: a value)
                 │                        │
   src/dap.ml (DAP messages)     src/web/pyking_web.ml (pykDebug*)
                 │                        │
   pyk.ml command_dap (stdio)    pyking-worker.js (slices on the
                                 worker's event loop) ── debugger.js
```

`debug_session.ml` knows no protocol. A session is a value: a transport
hands it a command (`resume`), lets it run a number of steps
(`advance`), and reads what happened from the events that answers with
-- the program stopped, a logpoint wrote a line, the top level ended, a
callback ended. Nothing in it waits, which is what lets the browser
worker drive it a slice at a time and still answer a pause. Stepping is
written once, in the core, so "step over" means the same thing in an
editor and in the playground.

## What runs

`Debug_session.prepare` takes the modules `Module.load` read and checks
each as `pyk <file>` does -- the checker, the mutability rule,
overloading and implicits elaborated away, the tail-call pass -- and
keeps beside what the interpreter runs what the checker saw: each
module's statements, its `tmap`, and what its names mean
(`scopes.ml`). The program runs through `Interpreter.runner`, the same
sequence `run_modules` drives: each module's top level a statement at a
time, in dependency order.

Because the tail-call pass has run, a function that calls itself in
tail position steps as the loop it became, and its frames do not pile
up in the call stack.

## Where it stops

The machine is checked each time it is about to start a statement:

- **A breakpoint** stops at the first statement starting on its line or
  after it -- the verified line the protocol reports. A condition is a
  Bool expression evaluated where the statement is; a hit count is `N`
  (the Nth time only), `>= N`, `> N`, `== N`, `< N`, `<= N` or `% N`; a
  log message is printed instead of stopping, `{expression}` in it
  replaced by the value as `print` writes it.
- **Step into** stops at the next statement, in a call too.
- **Step over** stops at the next statement no deeper in calls than the
  one it started from, and **step out** at the next one shallower. Once
  the call being stepped over or out of has returned, the program stops
  in the caller at the call, before the rest of the caller's statement.
- **Pause** stops at the next statement.
- **A runtime error** stops the program where it happens, with its
  calls still in progress; going on ends the program and reports the
  error as `pyk <file>` does. The editor's **Runtime errors** breakpoint
  turns this off.

A statement that continues the line the one before it started -- the
`if` of `x = if ...`, a block written on its header's line -- is not a
new line: a breakpoint or a step does not stop there a second time.

With `justMyCode`, the default, library code -- the standard library
and every `-L` directory in a terminal, every file the page did not
write in the playground -- is stepped over, and its frames are left out
of the call stack, except where the program stopped in one.

## What is shown

The call stack is the calls in progress, innermost first, each with
where it is: the statement being run for the innermost, the call for
the others. A frame has one scope, its **Environment**: every name it
sees, each shown once as what it means there -- the names its call
bound (parameters and what its body bound so far) first, then
everything it sees from where its function was written. Builtins, imported modules' fields
and the names the compiler made up are left out, and an overloaded
definition is shown by the name it was written with (`int::abs`, not
`int__abs`). A list, a tuple and a datatype value open to show their
parts.

## Evaluating where it stopped

A watch, the debug console, a hover, a breakpoint's condition and a
logpoint's message are all one thing: an expression checked and run
where the program stopped. It is type-checked against the names in
scope at the frame's position (`Scopes.names_at`), each at the type the
checker worked out for it -- a definition's generalised, a value's taken
from the value itself where the recorded type still names a type
variable -- and then elaborated and run in the frame's environment for
at most a million steps. Named arguments and defaults are not available
there, since the pass that removes them has run on the program before.

Only a `var` can be given a new value: setting one runs `name :=
expression`, checked like any other, so the new value must have the
`var`'s type. An `=` binding never changes, and the debugger says so.

## Callbacks

A tinyweb program does most of its work in callbacks, after its top
level has ended. Both transports debug them.

- **`pyk dap`**: once the top level has ended, the transport waits on
  the page's sockets beside the protocol (`Pyk_plugin.on_idle`). A
  callback the plugin makes reaches the session through the
  interpreter's `drive` hook, which pushes it as a run of its own and
  answers the editor until it ends; the plugin waits meanwhile. A
  callback a host makes while a slice is running runs to its end
  unstopped, since the session is not to be re-entered.
- **The playground**: a callback the page makes raises `Debug_call` out
  of `pykCallback` with the machine about to run it, and the session
  takes it as a run. The JavaScript function that called it answers a
  promise of its end (`pykDebugAwait`), and tinyweb's event delivery
  waits for it before calling the next. Events that arrive while the
  program is stopped wait in the worker; frames are not queued twice.

## Testing

`tests/test_dap.py` runs session scripts against `pyk dap`
(`tests/dap/*.dap`, each compared with its `.out`), checks the
transport, and runs three programs through the browser bundle under
node, whose every stop must look as it does through `pyk dap`. The
playground's Debug tab is driven in Chromium by
`tests/lsp/playground.mjs`.
