(** The C code-generation backend, serving both the c89 and c23 targets
    -- one translation; the standard is a printer parameter for where
    the two differ (comments, declaration placement, booleans). C is
    statically typed and this backend infers no polymorphism, so it
    works out a type (Int, String, or Bool) for every binding, parameter
    and function; where inference is not enough it refuses with a source
    position. C also leaves the order of an operator's operands and a
    call's arguments unspecified, so operands that can print are pinned
    down with temporaries. See docs/target_c.md.

    The C AST, the type inference over it, the scope that renames a
    Pyking name C has taken, and the temporaries are all this module's
    own. A caller translates a module and prints it, twice for a module
    the program imports: once as a translation unit and once as the
    header it is included through.

    Data structures:
      Unsupported -- a construct this backend cannot compile, with the
        source position.
      cprogram -- a translated module.

    Functions:
      translate_program stmts context -- translates a whole module.
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

(** One module of a program as a cprogram. `context` says what is true of
    it only as part of a program -- its name, whether it is the program's
    own module, and what the modules it imports export.
    [stmt] -> Module.context -> cprogram *)
val translate_program : Syntax.stmt list -> Module.context -> cprogram

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
