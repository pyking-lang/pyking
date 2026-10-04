(** The REPL: `pyk repl`. A session is a program written one entry at a
    time: each entry is checked against what the entries before it left
    behind, then run there. Includes a multi-line terminal line editor
    with history, indentation, and Pyking-aware line completion.
    See docs/repl.md.

    One function is public. Everything a session is made of -- the two
    environments it carries, how an entry is decided to be finished, the
    meta-commands, the editor and its buffer -- is this module's own,
    and `start` is reached from pyk.ml with the driver's own error
    formatting so a mistake at the prompt is reported in the words a
    file would get.

    `read` and `session` are `start`'s own parameters: a caller passes
    neither, and they exist so a test can drive a session without a
    terminal.

    Data structures:
      session -- a REPL session: statements seen, machine state, types,
        store, source text of each definition.
      reader -- how entries arrive: the terminal editor, or plain lines
        from a pipe.

    Functions:
      start format_error -- runs the REPL loop. *)

(** A REPL session: everything the entries so far left behind. *)
type session

(** How entries arrive: the terminal editor, or plain lines from a
    pipe. *)
type reader

(** Runs the REPL loop until end of input or `:quit`. `format_error` is
    the driver's (pyk.ml), and `libs` is where an imported module is
    looked for after the current directory. Answers the process's exit
    status.
    reader? -> session? -> [Module.lib_entry]? -> (exn -> string option)
    -> int *)
val start :
  ?read:reader ->
  ?session:session ->
  ?libs:Module.lib_entry list ->
  (exn -> string option) ->
  int
