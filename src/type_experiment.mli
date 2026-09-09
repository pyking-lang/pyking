(** An alternative type checker, at its beginning: a program is a
    sequence of statements, and the fragment checked here is integer
    literals, variables and `+`. Everything else is refused with
    `Construct is not supported`, which is the floor typesystem.ml keeps
    for whatever it has not reasoned about yet. `pyk --type-experiment`
    is what runs this one instead of typesystem.ml, so it can be grown
    against real programs.

    The interface is typesystem.ml's, narrowed to what a fragment needs:
    one entry point, and the same table back. The shape inside is
    typesystem.ml's too, and the one to keep as this grows -- one
    function per AST datatype, an `env` used immutably, and one symbol
    -> type table returned as the pass's result. See
    docs/typesystem.md.

    Data structures:
      Type_error -- a type failure, with the source position.
      tmap -- symbol -> the type inferred for that node.

    Functions:
      type_check stmts -- checks a whole program; answers its tmap. *)

(** A type failure, with the source position. *)
exception Type_error of Lexer.info * string

(** Symbol -> the type worked out for that node: this pass's result. *)
type tmap = Syntax.typ Syntax.IntMap.t

(** Checks a whole program and answers the types it worked out. Raises
    Type_error for a construct this fragment does not reach, and
    Analyses.Analysis_error for a name that is not in scope -- the same
    words typesystem.ml uses for both. [stmt] -> tmap *)
val type_check : Syntax.stmt list -> tmap
