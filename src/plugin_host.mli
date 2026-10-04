(** How the interpreter reaches a module implemented in a target
    language: through its OCaml implementation, compiled to a plugin and
    loaded into this executable with Dynlink. See docs/libraries.md,
    "How the interpreter reaches an OCaml implementation".

    Data structures:
      unit_ -- one external module: its name, its declared names and
        types, and where its declaration half is.

    Functions:
      digest unit_ -- what a module's plugin is built from, as a digest.
      built_from path digest -- whether a plugin was built from that.
      build_plugin unit_ output -- compiles a module's plugin to output.
      load units -- loads every module's plugin.
      externals units -- the interpreter's way into those modules.
      set_arguments program arguments -- what the program sees as its
        own argv. *)

(** One external module the interpreter has to reach: its name, every
    name its declaration half declares with its type, and that file's
    path, beside which its OCaml implementation is. *)
type unit_ = {
  name : string;
  declared : (string * Syntax.typ) list;
  declaration_path : string;
}

(** What a module's plugin is built from, as one digest: its OCaml
    implementation, its registration file, the OCaml and pyk versions and
    the interface the plugin is compiled against. A plugin whose digest
    is this is the plugin this executable would build now.
    unit_ -> string *)
val digest : unit_ -> string

(** Whether the plugin at path was built from what `digest` says, by the
    digest written beside it. string -> string -> bool *)
val built_from : string -> string -> bool

(** Compiles a module's OCaml implementation, with a registration file
    generated from its declarations, into a plugin at output, and writes
    its digest beside it. Raises
    Module_error where there is no OCaml compiler of the version this
    executable was built by, or the implementation does not compile.
    unit_ -> string -> () *)
val build_plugin : unit_ -> string -> unit

(** Loads the plugin of every module given, in order: the one beside its
    implementation where that is up to date, and otherwise one compiled
    into the cache on demand. Raises Module_error for the first module
    whose plugin cannot be had. [unit_] -> () *)
val load : unit_ list -> unit

(** The interpreter's way into every module given, whose plugins `load`
    has loaded: each value crosses by the type its declaration gives it.
    [unit_] -> Interpreter.externals *)
val externals : unit_ list -> Interpreter.externals

(** Makes `Sys.argv` what the program would have been started with --
    its own file, then its own arguments -- since an implementation such
    as sys_external.ml reads them from there. string -> [string] -> () *)
val set_arguments : string -> string list -> unit
