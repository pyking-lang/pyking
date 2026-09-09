(** The driver: what `pyk` on the command line runs. Parses argv,
    sequences the front-end stages, and dispatches to one of three
    commands (`pyk <file>`, `repl`, `compile`).
    See docs/architecture.md ("Command line"), docs/modules.md and
    docs/source.md ("pyk.ml").

    This module exports nothing, and that is the interface: it is the
    executable's entry point, run by the `let () = exit (main ...)` at
    the bottom of the file rather than called from anywhere. Everything
    it does -- parsing argv, running the front end once per module,
    wording an error, naming an output file, dispatching a command --
    is reached through that one line.

    Nothing may depend on the driver, which is what keeps each stage
    usable from the REPL and from the browser build: the two other front
    ends (src/repl.ml and src/web/pyking_web.ml) call the same library
    modules this one does, and pyk.ml hands `format_error` to the REPL
    as an argument rather than the REPL importing it. *)
