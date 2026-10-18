(** A REPL session, without the terminal: what `pyk repl` (repl.ml) and
    the playground's REPL (src/web/pyking_web.ml) share. A session is a
    program written one entry at a time: each entry is checked against
    what the entries before it left behind, then run there. Everything
    it shows goes through its host, so it opens no file and reads no
    terminal. See docs/repl.md.

    Data structures:
      host -- where a session's lines go, how its machine prints, and
        how it reaches a module implemented in a target language.
      session -- a REPL session: statements seen, machine state, types,
        store, source text of each definition.
      binding -- one name the session has bound, as `:ls` shows it.
      outcome -- what a meta-command leaves behind.

    Functions:
      new_session host -- an empty session.
      complete / continuable / next_indent -- whether an entry is finished,
        and where its next line is indented.
      submit session stmts report source -- checks and runs one entry.
      accept session stmts report source -- submit, reporting a refusal.
      imported_modules session stmts -- what an entry's imports would load.
      bindings session -- what the session has bound.
      run_meta session line report -- runs a meta-command.
      completions session line col -- what may be typed at col.
      undefined_name error -- the name an "unbound name" error is about. *)

(** Where a session's lines go and how it reaches what it imports.
    write -- one line the session shows: a value, a meta-command's answer.
    machine -- the interpreter's host, given how to reach the modules
      imported so far that are implemented in a target language.
    connect -- how to reach those modules: the ones just imported, then
      all of them.
    from -- where an imported module's files are read, if not from disk. *)
type host = {
  write : string -> unit;
  machine : Interpreter.externals option -> Interpreter.host;
  connect : Module.t list -> Module.t list -> Interpreter.externals;
  from : Module.sources option;
}

(** A REPL session: everything the entries so far left behind. *)
type session

(** One name the session has bound, as `:ls` shows it. *)
type binding = { implicit : bool; name : string; value : string; type_ : string option }

(** What a meta-command leaves behind: the session, and text to put back
    in front of the user (only `:edit` sets that). *)
type outcome = { out_session : session; pending : string }

(** One level of indentation. string *)
val indent_width : string

(** An empty session: builtins in scope, nothing seen, and modules
    looked for in `libs` after the importing directory.
    [Module.lib_entry]? -> host -> session *)
val new_session : ?libs:Module.lib_entry list -> host -> session

(** source as a list of statements. Raises Lex_error/Parse_error.
    string? -> string -> [stmt] *)
val parse_source : ?name:string -> string -> Syntax.stmt list

(** Whether source is a whole entry, per the parser. string -> bool *)
val complete : string -> bool

(** Whether a line the parser accepts could still be continued by the
    line below it: an `if` with no `else` yet. string -> bool *)
val continuable : string -> bool

(** The indentation the line after source belongs at. string -> string *)
val next_indent : string -> string

(** Checks stmts as one entry, then runs it, reporting a runtime error
    via report; `source` is kept per name for `:edit`. Answers the
    session and the check-time error, if any.
    session -> [stmt] -> (exn -> ()) -> string -> (session, exn option) *)
val submit :
  session -> Syntax.stmt list -> (exn -> unit) -> string -> session * exn option

(** `submit`, with a refusal simply reported.
    session -> [stmt] -> (exn -> ()) -> string -> session *)
val accept : session -> Syntax.stmt list -> (exn -> unit) -> string -> session

(** The modules the imports in stmts would newly load. Raises
    Module_error. session -> [stmt] -> [Module.t] *)
val imported_modules : session -> Syntax.stmt list -> Module.t list

(** What the session has bound (builtins excluded), in binding order.
    session -> [binding] *)
val bindings : session -> binding list

(** Runs the meta-command in line, or reports "unknown command". `extra`
    is the commands only a terminal has.
    [(string, session -> string -> (exn -> ()) -> outcome)]? -> session
    -> string -> (exn -> ()) -> outcome *)
val run_meta :
  ?extra:(string * (session -> string -> (exn -> unit) -> outcome)) list ->
  session ->
  string ->
  (exn -> unit) ->
  outcome

(** What may be typed where the cursor is: where the word being typed
    starts, and every name that fits it with its type -- after `m.`, what
    the module the session imported as `m` exports; at the start of a
    line beginning `:`, the meta-commands; elsewhere what the session has
    bound, the modules it imported, the builtins and the keywords. Every
    command a terminal has is offered when `terminal` says so.
    bool? -> session -> string -> int -> (int, [(string, string?)]) *)
val completions : ?terminal:bool -> session -> string -> int -> int * (string * string option) list

(** The name an "unbound name" error is about, or None.
    exn -> string option *)
val undefined_name : exn -> string option

(** Whether stmts include a def. [stmt] -> bool *)
val defines_function : Syntax.stmt list -> bool
