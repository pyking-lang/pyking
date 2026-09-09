(** The interface between pure Pyking code and the outside world: the
    operations a host must provide, and their semantics. No
    target-specific code. See
    docs/architecture.md, "The runtime interface".

    Data structures:
      operation -- one operation a host must provide (name, arity,
        semantics).

    Functions:
      lookup name -- the operation a name denotes, or None. *)

(** One operation a host must provide. *)
type operation = {
  name : string;
  variadic : bool;
  doc : string;
}

let print_operation =
  {
    name = "print";
    variadic = true;
    doc =
      "Write the arguments, space-separated, as one line of output. \
       Produces no value: it yields unit, `()`, so it is meaningful as a \
       statement and not as something to bind or return. A function whose \
       tail is a `print` therefore returns unit -- `void` in the C and \
       Java backends, an implicit `None`/`undefined` in the Python and \
       JavaScript ones.";
  }

let operations = [ print_operation ]

(** The operation a name denotes, or None if it is an ordinary Pyking
    name. string -> operation option *)
let lookup name = List.find_opt (fun operation -> operation.name = name) operations
