(** The Python code-generation backend: Pyking AST (syntax.ml) to a
    Python-shaped AST to Python source text. See docs/target_python.md
    for how each construct compiles and where the output is not
    optimal.

    Two functions and one abstract type: a caller translates a program
    and prints it. The Python AST itself, the scope that renames a
    binding Python would otherwise merge with another, and the
    generated helpers are this module's own, and a `pyprogram` is
    nothing to build or inspect from outside -- `translate_program` is
    the only thing that makes one and `pprint_py_program` the only
    thing that reads one.

    Data structures:
      Unsupported -- a construct this backend does not translate.
      pyprogram -- a translated program: the host boilerplate and the
        program itself.

    Functions:
      translate_program stmts tmap -- translates a whole program.
      pprint_py_program program -- pyprogram to Python source text. *)

(** A translated program: the host boilerplate and the program itself. *)
type pyprogram

(** A construct this backend does not translate, with the source
    position. *)
exception Unsupported of Lexer.info * string

(** Translates a whole program. `tmap` is the type checker's table,
    which is what says whether a `print` argument can hold a Bool and
    so needs formatting rather than printing as it stands, and what a
    datatype's fields are annotated with; `target` is the Python
    version, which decides whether a forward reference is quoted.
    [stmt] -> typ IntMap.t -> pyprogram *)
val translate_program :
  ?external_fields:(string * string list) list ->
  ?externals:string list ->
  ?own:string ->
  ?target:string ->
  Syntax.stmt list ->
  Syntax.typ Syntax.IntMap.t ->
  pyprogram

(** A translated program as Python source text. pyprogram -> string *)
val pprint_py_program : pyprogram -> string
