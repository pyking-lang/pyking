(** The registry a loaded plugin fills in: each name an external module
    declares, paired with its OCaml implementation as an untyped value.
    See docs/libraries.md, "How the interpreter reaches an OCaml
    implementation".

    Functions:
      register module_ name value -- records one implementation.
      find module_ name -- the implementation recorded, or None.
      after_program f -- asks for f to run once the top level has ended.
      run_after_program () -- runs, in order, everything asked for.
      set_directory module_ directory -- where a module's plugin is from.
      directory module_ -- that directory, or None.
      on_idle descriptors handle -- asks to be handed the REPL's idle time.
      idle_descriptors () -- every descriptor a plugin is waiting on.
      run_idle () -- lets every plugin answer what is waiting. *)

(** Records the implementation of `module_.name`, replacing any earlier
    one. Called by a plugin's generated registration code.
    string -> string -> Obj.t -> () *)
val register : string -> string -> Obj.t -> unit

(** The implementation recorded for `module_.name`, or None.
    string -> string -> Obj.t option *)
val find : string -> string -> Obj.t option

(** Asks for f to run once the program's top level has ended: how an
    implementation delivers events to the callbacks it was handed.
    (() -> ()) -> () *)
val after_program : (unit -> unit) -> unit

(** Runs everything after_program was asked for, in order, and forgets
    it. () -> () *)
val run_after_program : unit -> unit

(** Records the directory a module's implementation is in, before its
    plugin is loaded. string -> string -> () *)
val set_directory : string -> string -> unit

(** The directory a module's implementation is in, or None.
    string -> string option *)
val directory : string -> string option

(** Asks for the REPL's idle time: while it waits for a line it also
    waits on what `descriptors` answers, and calls `handle` when any of
    them is ready. (() -> [file_descr]) -> (() -> ()) -> () *)
val on_idle : (unit -> Unix.file_descr list) -> (unit -> unit) -> unit

(** Every descriptor a plugin is waiting on now. () -> [file_descr] *)
val idle_descriptors : unit -> Unix.file_descr list

(** Lets every plugin answer what is waiting, without blocking.
    () -> () *)
val run_idle : unit -> unit
