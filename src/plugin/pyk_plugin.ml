(** The registry a loaded plugin fills in: each name an external module
    declares, paired with its OCaml implementation as an untyped value.
    A plugin's generated registration code calls `register` once per
    name when Dynlink loads it, and plugin_host.ml reads the values back
    with the types the declaration gives them. See docs/libraries.md,
    "How the interpreter reaches an OCaml implementation".

    The table is mutable because loading a plugin can answer nothing:
    its initialisation code runs for its effect, and this is where that
    effect lands.

    Data structures:
      table -- (module, name) -> implementation.
      pending -- what a plugin asked to run once the program's top
        level has ended, in the order asked.

    Functions:
      register module_ name value -- records one implementation.
      find module_ name -- the implementation recorded, or None.
      after_program f -- asks for f to run once the top level has ended.
      run_after_program () -- runs, in order, everything asked for. *)

let table : (string * string, Obj.t) Hashtbl.t = Hashtbl.create 64

(** Records the implementation of `module_.name`, replacing any earlier
    one. string -> string -> Obj.t -> () *)
let register module_ name value = Hashtbl.replace table (module_, name) value

(** The implementation recorded for `module_.name`, or None.
    string -> string -> Obj.t option *)
let find module_ name = Hashtbl.find_opt table (module_, name)

let pending : (unit -> unit) list ref = ref []

(** Asks for f to run once the program's top level has ended: how an
    implementation delivers events to the callbacks it was handed.
    (() -> ()) -> () *)
let after_program f = pending := !pending @ [ f ]

(** Runs everything after_program was asked for, in order, and forgets
    it. () -> () *)
let run_after_program () =
  let todo = !pending in
  pending := [];
  List.iter (fun f -> f ()) todo
