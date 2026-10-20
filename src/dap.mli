(** The Pyking debug adapter: a state and one function from a message an
    editor sent to the messages to send back, over the Debug Adapter
    Protocol, translating to and from a debug_session.ml session. The
    caller hands in how a launch starts a session and how a failed run
    is reported, and runs the program in slices with `advance`. See
    docs/debugging.md.

    Data structures:
      hooks -- what the transport does that this module cannot.
      state -- everything the adapter knows.

    Functions:
      create hooks -- an adapter that has seen nothing.
      handle state text output -- one message received, and what to send.
      running state -- whether the program should be given steps.
      advance state steps output -- the program run for a slice.
      push_call state machine -- a callback the host makes, to debug.
      take_call state -- the machine a callback ended in, once it has.
      top_level_ended state -- whether the top level ended without error.
      finish state code output -- the program over: exited, terminated.
      exit_code state -- the status to exit with, once disconnected. *)

(** What the transport does that this module cannot: start a session
    from a launch request's arguments (or say why not), and word the
    error a failed run ended in, as `pyk <file>` would print it. *)
type hooks = {
  start : Json.t -> (Debug_session.t, string) result;
  report : Interpreter.state -> string;
}

(** Everything the adapter knows. *)
type state

(** An adapter that has seen nothing. hooks -> state *)
val create : hooks -> state

(** One message received, and what to send back. `output` hands over
    what the program wrote meanwhile, each a category and text.
    state -> string -> (() -> [(string, string)]) -> (state, [string]) *)
val handle : state -> string -> (unit -> (string * string) list) -> state * string list

(** Whether the program should be given steps: launched, configured and
    running. state -> bool *)
val running : state -> bool

(** The program run for up to `steps` steps.
    state -> int -> (() -> [(string, string)]) -> (state, [string]) *)
val advance : state -> int -> (unit -> (string * string) list) -> state * string list

(** A callback the host makes, debugged in the session.
    state -> Interpreter.state -> state *)
val push_call : state -> Interpreter.state -> state

(** The machine a callback ended in, once it has, and the state without
    it. state -> (state, Interpreter.state?) *)
val take_call : state -> state * Interpreter.state option

(** Whether the top level ended without error and nothing has finished
    the program since. state -> bool *)
val top_level_ended : state -> bool

(** The program over with a status: exited, then terminated.
    state -> int -> (() -> [(string, string)]) -> (state, [string]) *)
val finish : state -> int -> (unit -> (string * string) list) -> state * string list

(** The status to exit with, once the editor disconnected.
    state -> int option *)
val exit_code : state -> int option
