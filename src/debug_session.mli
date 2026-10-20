(** The debugger's core: a program run by the interpreter one step at a
    time, with breakpoints, stepping, the calls in progress and their
    variables, and expressions evaluated where the program stopped. It
    knows no protocol: `pyk dap` (dap.ml) and the playground's Debug tab
    are two transports over it. A session is a value; nothing here waits
    for anything. See docs/debugging.md.

    Data structures:
      program -- every module of a program, checked and made ready.
      command -- what a reader asks the debugger to do.
      reason -- why the program stopped.
      event -- what running produced.
      breakpoint -- a line to stop at, as set and as verified.
      frame -- one call in progress, as shown.
      variable -- one name or part of a value, as shown.
      t -- a session.

    Functions:
      prepare release units -- a program loaded by Module.load, checked.
      create program host -- a session about to run a program.
      set_breakpoints t file specs -- the breakpoints of one file.
      resume t command -- the session told to go on, or to pause.
      advance t steps -- runs up to `steps` steps; answers the events.
      push_call t machine -- a callback to run.
      stopped t / idle t / ended t -- where the session is.
      frames t -- the calls in progress where it stopped.
      scopes t frame -- a frame's scopes, each a reference.
      variables t reference -- what a reference holds.
      evaluate t frame text -- an expression's value, in a frame.
      set_variable t reference name text -- a `var` given a new value.
      stop_on_errors t on -- whether a runtime error stops the program.
      terminate t -- the session ended where it stands. *)

(** A program ready to debug. *)
type program

(** What a reader asks the debugger to do. *)
type command = Continue | Next | Step_in | Step_out | Pause

(** Why the program stopped: on entry, a step finished, breakpoints
    (their ids), a pause, or a runtime error (its message). *)
type reason = Entry | Step | Breakpoint of int list | Paused | Exception of string

(** What running produced: the program stopped; a logpoint's line, or a
    condition that could not be evaluated; the top level ended, in the
    machine it ended in; a callback ended, likewise. *)
type event =
  | Stopped of reason
  | Output of string
  | Program_done of Interpreter.state
  | Callback_done of Interpreter.state

(** A line to stop at: its id, the file and the line asked for, the line
    of the statement it stops at (None where there is none), a condition
    and a hit condition, a logpoint's message, and how often it was
    reached. *)
type breakpoint = {
  id : int;
  file : string;
  line : int;
  at : int option;
  condition : string option;
  hit : string option;
  log : string option;
  count : int;
}

(** One call in progress, as shown: an id, the function's name, where it
    is (file and span), the environment there, where its own names stop,
    the machine it is in, and whether its module is a library's. *)
type frame = {
  fid : int;
  name : string;
  file : string;
  span : Lexer.info;
  env : Interpreter.env;
  upto : Interpreter.env option;
  machine : Interpreter.state;
  library : bool;
}

(** One name, or one part of a value, as shown: its name, the value as
    a prompt shows it, its type, the reference its parts are under (0
    for none), and whether it may be given a new value. *)
type variable = {
  vname : string;
  value : string;
  vtype : string;
  reference : int;
  settable : bool;
}

(** A session. *)
type t

(** A program Module.load read, checked and made ready to run exactly as
    `pyk <file>` runs it, keeping beside what runs what the checker saw.
    `release` removes every call to `debug` first. Raises the front
    end's own errors. bool? -> [Module.t] -> program *)
val prepare : ?release:bool -> Module.t list -> program

(** A session about to run a program from its first statement, writing
    through host. `drive` is how a callback the host makes is run; by
    default it is stepped to its end. The session stops at the first
    statement where `stop_on_entry`, and library code -- a file
    `is_library` names -- is stepped over where `just_my_code`.
    bool? -> bool? -> (string -> bool)? -> (state -> state)? -> program
    -> Interpreter.host -> t *)
val create :
  ?stop_on_entry:bool ->
  ?just_my_code:bool ->
  ?is_library:(string -> bool) ->
  ?drive:(Interpreter.state -> Interpreter.state) ->
  program ->
  Interpreter.host ->
  t

(** The breakpoints of one file, replacing the ones it had: each a line,
    a condition, a hit condition and a logpoint message. A breakpoint
    stops at the first statement starting on its line or after it.
    t -> string -> [(int, string?, string?, string?)] -> (t, [breakpoint]) *)
val set_breakpoints :
  t -> string -> (int * string option * string option * string option) list -> t * breakpoint list

(** The session told to go on, or to pause where it is running. A step
    is measured from the frame the program stopped in.
    t -> command -> t *)
val resume : t -> command -> t

(** Runs up to `steps` steps, or until the program stops or a run ends.
    Answers the session and what happened. t -> int -> (t, [event]) *)
val advance : t -> int -> t * event list

(** A callback to run: a machine about to call it, from the host or the
    page. t -> Interpreter.state -> t *)
val push_call : t -> Interpreter.state -> t

(** The reason the session stopped, where it has. t -> reason option *)
val stopped : t -> reason option

(** Whether the session waits for a callback: the top level has ended,
    and nothing runs. t -> bool *)
val idle : t -> bool

(** Whether the session is over. t -> bool *)
val ended : t -> bool

(** The calls in progress where the session stopped, innermost first.
    t -> [frame] *)
val frames : t -> frame list

(** A frame's scopes, each a name and a reference.
    t -> int -> (t, [(string, int)]) *)
val scopes : t -> int -> t * (string * int) list

(** What a reference holds: a frame's names, or a value's parts.
    t -> int -> (t, [variable]) *)
val variables : t -> int -> t * variable list

(** An expression's value where the program stopped, in a frame (the
    innermost where none is named), as a variable with no name.
    t -> int? -> string -> (t, (variable, string) result) *)
val evaluate : t -> int option -> string -> t * (variable, string) result

(** A `var` in a frame's scope given the value of an expression.
    t -> int -> string -> string -> (t, (variable, string) result) *)
val set_variable : t -> int -> string -> string -> t * (variable, string) result

(** The session told whether to stop where a runtime error ends the
    program, before it ends. t -> bool -> t *)
val stop_on_errors : t -> bool -> t

(** The session ended where it stands. t -> t *)
val terminate : t -> t
