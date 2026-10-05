(** The registry a loaded plugin fills in: each name an external module
    declares, paired with its OCaml implementation as an untyped value.
    See docs/libraries.md, "How the interpreter reaches an OCaml
    implementation".

    Functions:
      register module_ name value -- records one implementation.
      find module_ name -- the implementation recorded, or None.
      after_program f -- asks for f to run once the top level has ended.
      run_after_program () -- runs, in order, everything asked for. *)

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
