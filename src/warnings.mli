(** Warnings: what a program that checks may still have wrong -- a name
    bound and never used, and an `=` in a nested block that shadows an
    outer name and is never used, which is what writing `x = ...` for
    `x := ...` looks like. One walk over a module's statements, after
    the type checker. See docs/warnings.md, and PYKING.md ("Warnings").

    Which warnings are reported, and which are errors, is a `config`
    built from GCC-style flags, applied in order: `-W<name>`,
    `-Wno-<name>`, `-Wall`, `-w`, `-Werror`, `-Wno-error`,
    `-Werror=<name>` and `-Wno-error=<name>`.

    Data structures:
      kind -- one warning: its flag names it.
      config -- which warnings are on, and which are errors.
      warning -- one warning found: where, which, what it says, and
        whether it is an error.

    Functions:
      kinds -- every kind, in the order they are listed.
      name kind / of_name name -- a kind's flag name, and back.
      description kind -- what a kind reports, in a sentence.
      default_on kind -- whether a kind is on with no flag given.
      default -- the config with no flag given.
      enabled config kind / is_error config kind -- what a config says.
      flag config text -- one flag applied to a config.
      is_flag text -- whether a command-line word is a warning flag.
      of_flags flags -- the config a list of flags makes.
      to_flags config -- the shortest flags that make a config.
      check config tokens stmts -- every warning in a module.
      format w -- a warning as `'file' r:c-r:c Warning: ... [-Wname]`.
      has_error ws -- whether any of the warnings is an error.

    Exceptions:
      Refused ws -- the warnings a -Werror made errors. *)

(** One warning; `name` is what its flag calls it. *)
type kind =
  | Unused_binding
  | Unused_function
  | Unused_var
  | Shadowed_update
  | Unused_pattern_var
  | Unused_parameter
  | Unused_loop_var

(** Every kind, in the order help and the playground list them. [kind] *)
val kinds : kind list

(** A kind's flag name: `unused-binding` for `-Wunused-binding`.
    kind -> string *)
val name : kind -> string

(** The kind a flag name names. string -> kind? *)
val of_name : string -> kind option

(** What a kind reports, in a sentence or two. kind -> string *)
val description : kind -> string

(** Whether a kind is on when no flag says otherwise. kind -> bool *)
val default_on : kind -> bool

(** Which warnings are on, and which of them are errors. *)
type config

(** The config no flag has changed. config *)
val default : config

(** Whether a config reports a kind. config -> kind -> bool *)
val enabled : config -> kind -> bool

(** Whether a config makes a kind an error. config -> kind -> bool *)
val is_error : config -> kind -> bool

(** One flag applied to a config, or why it names no warning.
    config -> string -> (config, string) result *)
val flag : config -> string -> (config, string) result

(** Whether a command-line word is a warning flag: `-w`, or `-W`
    followed by something. string -> bool *)
val is_flag : string -> bool

(** The default config with each flag applied in turn.
    [string] -> (config, string) result *)
val of_flags : string list -> (config, string) result

(** The flags that turn the default config into this one.
    config -> [string] *)
val to_flags : config -> string list

(** One warning found: the span of the name, its kind, what it says,
    and whether the config made it an error. *)
type warning = { at : Lexer.info; kind : kind; message : string; error : bool }

(** Every warning `config` reports in a module, in source order.
    `qmap` is what the checker settled about overloaded calls and
    implicit arguments; `toplevel_used` says the module's top-level
    names may be used later (a REPL entry, a notebook block); `public`
    names the top-level names the module exports, which another module
    uses; `display` turns a compiled name back into the one written;
    `outer` is what is in scope around the statements, with where each
    is bound -- an earlier REPL entry's names -- which a binding may
    shadow and which is never reported.
    resolution IntMap.t? -> bool? -> [string]? -> (string -> string)? ->
    [(string, info)]? -> config -> [token] -> [stmt] -> [warning] *)
val check :
  ?qmap:Typesystem.resolution Syntax.IntMap.t ->
  ?toplevel_used:bool ->
  ?public:string list ->
  ?display:(string -> string) ->
  ?outer:(string * Lexer.info) list ->
  config ->
  Lexer.token list ->
  Syntax.stmt list ->
  warning list

(** A warning as `'file' r:c-r:c Warning: message [-Wname]`, or `Error:`
    and `[-Werror=name]` where it is one. warning -> string *)
val format : warning -> string

(** Whether any of the warnings is an error. [warning] -> bool *)
val has_error : warning list -> bool

(** What refuses a program, or a REPL entry, that a -Werror made a
    warning an error in: the warnings that are errors. *)
exception Refused of warning list
