(** The spelling rules for a qualified name: `int::leq`, the name an
    overloaded definition is given. A qualified name is one identifier
    that happens to hold a `::`, so this is the only place one is taken
    apart. See docs/overloading.md.

    Functions:
      separator -- the two characters a qualifier is joined with.
      is_qualified name -- whether a name carries a qualifier.
      qualifier name -- the part before the `::`, where there is one.
      base name -- the part after it, or the whole name.
      renamed name -- the plain name a qualified one compiles to.
      field name -- the part of a dotted name after the module. *)

val separator : string
(** The two characters that join a qualifier to a base name. String *)

val is_qualified : string -> bool
(** Whether this name carries a qualifier. String -> Bool *)

val qualifier : string -> string option
(** The qualifier, where there is one. String -> String? *)

val base : string -> string
(** The name without its qualifier, which is the whole of an unqualified
    one. String -> String *)

val renamed : string -> string
(** The plain name a qualified one compiles to, which `elaborate.ml`
    rewrites every definition and reference to. String -> String *)

val field : string -> string
(** The part of a dotted name after the module it is reached through.
    String -> String *)
