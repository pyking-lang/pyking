(** The interface between pure Pyking code and the outside world: the
    operations a host must provide, and their semantics. No
    target-specific code. See docs/architecture.md, "The runtime
    interface".

    Data structures:
      operation -- one operation a host must provide (name, arity,
        semantics).

    Functions:
      print_operation -- the one operation there is today.
      names -- the name of every operation.
      lookup name -- the operation a name denotes, or None. *)

(** One operation a host must provide. *)
type operation = { name : string; variadic : bool; doc : string }

(** Write the arguments, space-separated, as one line of output. operation *)
val print_operation : operation

(** The name of every operation a host must provide. [string] *)
val names : string list

(** The operation a name denotes, or None if it is an ordinary Pyking
    name. string -> operation option *)
val lookup : string -> operation option
