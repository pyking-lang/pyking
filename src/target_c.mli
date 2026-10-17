(** The C code-generation backend, serving c89, c99 and c23. It infers
    no types of its own: every type it writes is read out of the
    checker's tmap. C has no garbage collector, so it compiles what needs
    none -- a polymorphic function once per type, a tuple as a struct, a
    datatype that does not hold itself as a tagged union, a function
    value as a pointer and an environment on the stack -- and refuses a
    list and a function value that could outlive its environment. C also
    leaves the order of an operator's operands and a call's arguments
    unspecified, so operands that can print are pinned down with
    temporaries. See docs/target_c.md.

    The C AST, the scope that renames a Pyking name C has taken, and the
    temporaries are all this module's own. A caller translates a module and prints it, twice for a module
    the program imports: once as a translation unit and once as the
    header it is included through.

    Data structures:
      Unsupported -- a construct this backend cannot compile, with the
        source position.
      cprogram -- a translated module.

    Functions:
      translate_program stmts tmap context standard -- translates a whole
        module.
      translate_all units standard -- every module of a program, each
        compiling the instances the others ask of it.
      pprint_c_program program standard source -- the translation unit.
      pprint_c_header program standard source -- the header a module the
        program imports is included through.
      header_extension -- what that header file is called. *)

(** Raised for a Pyking construct this backend cannot compile; carries
    the source position, like the front end's errors do for their
    stages. *)
exception Unsupported of Lexer.info * string

(** A translated module: made by `translate_program`, read by the two
    printers, and nothing to build or inspect from outside. *)
type cprogram

(** What a module the program imports declares itself in, beside its own
    translation unit. string *)
val header_extension : string

(** One module of a program as a cprogram, for the C standard named
    standard. `context` says what is true of it only as part of a program
    -- its name, whether it is the program's own module, and what the
    modules it imports export.
    [stmt] -> typ IntMap.t -> Module.context -> string -> cprogram *)
val translate_program :
  ?requested:(string * (string * Syntax.typ) list) list ->
  Syntax.stmt list -> Syntax.typ Syntax.IntMap.t -> Module.context -> string -> cprogram

(** Every module of a program, each compiling the instances of its
    polymorphic functions that the others call, for the C standard named
    standard. [([stmt], typ IntMap.t, Module.context)] -> string
    -> [cprogram] *)
val translate_all :
  (Syntax.stmt list * Syntax.typ Syntax.IntMap.t * Module.context) list -> string -> cprogram list

(** The whole translation unit: headers, the string helper if used, the
    functions, and main -- or, for a module the program imports, the
    function that runs its top level. `standard` is the C standard to
    print for and `source` the Pyking file it came from.
    cprogram -> string -> string -> string *)
val pprint_c_program : cprogram -> string -> string -> string

(** The header a module the program imports is included through: what it
    exports, and the function that runs its top level.
    cprogram -> string -> string -> string *)
val pprint_c_header : cprogram -> string -> string -> string
