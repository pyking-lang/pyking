(** The Java code-generation backend, serving java8, java17 and java21.
    It infers no types of its own: every type it writes is read out of
    the checker's tmap, so Pyking's polymorphism is Java's generics, a
    list a `java.util.List`, a tuple a class of the shared runtime, a
    datatype a class per constructor and a function value a
    `java.util.function` interface. java8, java17 and java21 are three
    shapes of output: plain classes and casts, records with `instanceof`
    patterns, and records with a pattern `switch` for every `match`.
    See docs/target_java.md.

    The Java AST, the scope and the javac rules are this module's own: a
    caller translates every module of a program, prints each, and writes
    the runtime they share beside them. `default_class_name` is here
    rather than in the driver because Java requires the file and its
    public class to agree, so naming the output is the backend's
    business.

    Data structures:
      Unsupported -- a construct this backend cannot compile, with the
        source position.
      jprogram -- a translated module.

    Functions:
      translate_program stmts tmap context version -- translates a whole
        module.
      default_class_name stem -- the Java class name for a source stem.
      pprint_java_program program version class_name source -- the
        compilation unit.
      runtime_file -- what the shared runtime's file is called.
      runtime_source programs version -- the shared runtime, for a
        program of these modules. *)

(** Raised for a Pyking construct this backend cannot compile; carries
    the source position, like the front end's errors do for their
    stages. *)
exception Unsupported of Lexer.info * string

(** A translated module: made by `translate_program`, read by
    `pprint_java_program` and `runtime_source`, and nothing to build or
    inspect from outside. *)
type jprogram

(** The Java class (and file) name picked when nothing else says one,
    e.g. foo_bar -> FooBar. The rule lives in module.ml, which owns what
    a module's file is called on each target. string -> string *)
val default_class_name : string -> string

(** One module of a program as a jprogram, for the Java target named
    version. `context` says what is true of it only as part of a program
    -- its name, whether it is the program's own module, and what the
    modules it imports export.
    [stmt] -> typ IntMap.t -> Module.context -> string -> jprogram *)
val translate_program :
  Syntax.stmt list -> Syntax.typ Syntax.IntMap.t -> Module.context -> string -> jprogram

(** The whole compilation unit: the class holding every function as a
    static method, and main. `version` is the Java version to print for,
    `class_name` the class to declare and `source` the Pyking file it
    came from.
    jprogram -> string -> string -> string -> string *)
val pprint_java_program : jprogram -> string -> string -> string -> string

(** The file the runtime every module of a Java program shares is
    written to, beside them. string *)
val runtime_file : string

(** That runtime, for a program of these modules on the Java target named
    version. [jprogram] -> string -> string *)
val runtime_source : jprogram list -> string -> string
