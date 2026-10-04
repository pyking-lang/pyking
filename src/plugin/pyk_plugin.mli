(** The registry a loaded plugin fills in: each name an external module
    declares, paired with its OCaml implementation as an untyped value.
    See docs/libraries.md, "How the interpreter reaches an OCaml
    implementation".

    Functions:
      register module_ name value -- records one implementation.
      find module_ name -- the implementation recorded, or None. *)

(** Records the implementation of `module_.name`, replacing any earlier
    one. Called by a plugin's generated registration code.
    string -> string -> Obj.t -> () *)
val register : string -> string -> Obj.t -> unit

(** The implementation recorded for `module_.name`, or None.
    string -> string -> Obj.t option *)
val find : string -> string -> Obj.t option
