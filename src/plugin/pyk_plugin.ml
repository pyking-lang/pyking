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
      directories -- module -> the directory its implementation is in.
      idle -- what a plugin serves while the REPL waits for a line.

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

let directories : (string, string) Hashtbl.t = Hashtbl.create 8

(** Records the directory a module's implementation is in, before its
    plugin is loaded. string -> string -> () *)
let set_directory module_ directory = Hashtbl.replace directories module_ directory

(** The directory a module's implementation is in, or None.
    string -> string option *)
let directory module_ = Hashtbl.find_opt directories module_

let idle : ((unit -> Unix.file_descr list) * (unit -> unit)) list ref = ref []

(** Asks for the REPL's idle time: while it waits for a line it also
    waits on what `descriptors` answers, and calls `handle` when any of
    them is ready. (() -> [file_descr]) -> (() -> ()) -> () *)
let on_idle descriptors handle = idle := !idle @ [ (descriptors, handle) ]

(** Every descriptor a plugin is waiting on now. () -> [file_descr] *)
let idle_descriptors () = List.concat_map (fun (descriptors, _) -> descriptors ()) !idle

(** Lets every plugin answer what is waiting, without blocking.
    () -> () *)
let run_idle () = List.iter (fun (_, handle) -> handle ()) !idle
