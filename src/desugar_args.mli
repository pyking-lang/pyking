(** Default parameters and named arguments, removed before anything
    reasons about the program. A default becomes a generated
    zero-argument `def` in the block the definition is written in, and
    an omitted argument becomes a call to it; a named argument is put
    back in its parameter's position. What comes out is ordinary Pyking,
    so no later stage knows the sugar exists.
    See docs/desugar_args.md.

    Data structures:
      signatures -- what the pass knows about the modules desugared so
        far, threaded through a program in dependency order.

    Functions:
      no_signatures -- nothing known yet.
      desugar signatures name stmts -- rewrites one module.
      external_module signatures name -- records a module written in
        another language, which the sugar may not reach into.
      generated_name name -- whether the pass made this name up. *)

type signatures
(** What the pass knows about every module desugared so far: each
    module's functions, their parameters, and which of those carry a
    default. *)

val no_signatures : signatures
(** Nothing known yet. signatures *)

val desugar :
  signatures -> string -> Syntax.stmt list -> Syntax.stmt list * signatures
(** Rewrites one module's statements, removing every default parameter
    and every named argument, and answers with what the next module may
    then use. Raises Analyses.Analysis_error where the sugar is written
    somewhere it cannot be resolved.
    signatures -> String -> [stmt] -> ([stmt], signatures) *)

val generated_name : string -> bool
(** Whether this name is one the pass made up rather than one the
    program wrote, which is what keeps the prompt from listing it.
    String -> Bool *)

val external_module : signatures -> string -> signatures
(** Records that a module is written in another language, so a call into
    it refuses the sugar by name rather than by absence.
    signatures -> String -> signatures *)
