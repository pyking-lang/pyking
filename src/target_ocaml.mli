(** The OCaml code-generation backend. Unlike the other backends, its
    subset is exactly what typesystem.ml accepts: rather than inferring
    types, this module reads translated expressions' types out of the
    checker's tmap, which pyk.ml fills and hands it -- so a program that
    does not type-check is refused before translation begins. It is also
    the one target compiled from the program as *written*: OCaml
    eliminates tail calls itself, so pyk.ml skips optimization.ml here
    rather than have a rewrite this module would only undo.
    See docs/target_ocaml.md.

    The OCaml AST, the names plan, and the `let` inserted wherever two
    operands of one expression can both print are this module's own. A
    caller translates a module and prints it, twice for a module the
    program imports: once as an implementation and once as the `.mli`
    that is the whole of privacy on this target.

    Data structures:
      Unsupported -- a construct this backend cannot compile, with the
        source position.
      oprogram -- a translated module.

    Functions:
      translate_program stmts tmap context -- translates a whole module.
      pprint_ocaml_program program source -- the module as OCaml source.
      pprint_ocaml_interface program source -- the `.mli` a module the
        program imports is seen through.
      target -- the target this backend serves.
      extension / interface_extension -- what its two files are called. *)

(** Raised for a Pyking construct this backend cannot compile; carries
    the source position, like the other stages' errors. *)
exception Unsupported of Lexer.info * string

(** A translated module: made by `translate_program`, read by the two
    printers, and nothing to build or inspect from outside. *)
type oprogram

(** The one OCaml target; its name is src/targets.ml's. string *)
val target : string

(** What a translated module is called. string *)
val extension : string

(** What a module the program imports says it exports, beside its own
    implementation. string *)
val interface_extension : string

(** Translates one module of a program to an oprogram, reading the types
    the checker worked out rather than inferring any. pyk.ml runs the
    checker and hands the table here, so a program that does not check
    has been refused before this is called. `context` says what is true
    of the module only as part of a program.
    [stmt] -> typ IntMap.t -> Module.context -> oprogram *)
val translate_program :
  Syntax.stmt list ->
  Syntax.typ Syntax.IntMap.t ->
  Module.context ->
  oprogram

(** The whole module: a header, the prelude if needed, and the top-level
    items. `source` is the Pyking file it came from.
    oprogram -> string -> string *)
val pprint_ocaml_program : oprogram -> string -> string

(** The interface a module the program imports is seen through: one `val`
    per name it exports, and nothing else, which is what makes everything
    else in the file private. oprogram -> string -> string *)
val pprint_ocaml_interface : oprogram -> string -> string
