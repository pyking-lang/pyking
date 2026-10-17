(** Exhaustiveness and reachability of `match`: every `match` has to
    match every value of its subject's type, and every case has to be
    reachable. Run by the type checker once a module's types are worked
    out. See docs/exhaustive.md.

    Data structures:
      Refused -- a `match` missing a value, or a case no value reaches.

    Functions:
      check datatype tmap stmts -- refuses the first `match` in stmts
        that misses a value or has a case nothing reaches.
      covers datatype type_ patterns -- whether the patterns between them
        match every value of the type. *)

open Lexer
open Syntax

(** A `match` that misses a value, or a case no value reaches. *)
exception Refused of info * string

(** Refuses the first `match` in stmts that misses a value or has a case
    nothing reaches, given the datatype each canonical name denotes and
    the types the checker worked out.
    (string -> datatype?) -> typ IntMap.t -> [stmt] -> () *)
val check : (string -> datatype option) -> typ IntMap.t -> stmt list -> unit

(** Whether these patterns between them match every value of a type,
    where the type is known. (string -> datatype?) -> typ? -> [pattern]
    -> bool *)
val covers : (string -> datatype option) -> typ option -> pattern list -> bool
