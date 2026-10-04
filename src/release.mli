(** Release mode: every call to the builtin `debug` removed, arguments
    and all. Pyking AST in, Pyking AST out, run by `pyk compile
    --release` after the type checker and before the tail-call pass. See
    docs/release.md.

    Functions:
      program tmap stmts -- one module with its calls to `debug`
        removed. *)

(** One module with every call to the builtin `debug` removed: a call in
    value position becomes `()`, and a call written as a statement is
    dropped wherever that leaves its block's value as it was.
    typ IntMap.t -> [stmt] -> [stmt] *)
val program :
  Syntax.typ Syntax.IntMap.t -> Syntax.stmt list -> Syntax.stmt list
