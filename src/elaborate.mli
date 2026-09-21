(** Overloading and implicit arguments, removed after the type checker
    and before anything else reads the program. What comes out is
    ordinary Pyking, so no backend and not the interpreter knows either
    feature exists. See docs/implicits.md.

    Functions:
      program qmap tmap stmts -- rewrites one module.
      generated_name name -- whether the pass made this name up. *)

val program :
  Typesystem.resolution Syntax.IntMap.t ->
  Syntax.typ Syntax.IntMap.t ->
  Syntax.stmt list ->
  Syntax.stmt list * Syntax.typ Syntax.IntMap.t
(** One module with every qualified name renamed, every resolved call
    naming the definition it reaches, and every implicit parameter made
    an ordinary one. Answers the rewritten module and `tmap` extended
    with the nodes it built. Raises Analyses.Analysis_error where a
    qualified name and the plain name it compiles to are both bound.
    resolution IntMap.t -> typ IntMap.t -> [stmt] -> ([stmt], typ IntMap.t) *)

val generated_name : string -> bool
(** Whether this name is one the pass made up rather than one the
    program wrote. String -> Bool *)
