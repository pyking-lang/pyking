(** The Java code-generation backend, serving java8, java17 and java21
    -- structured like target_c.ml: one translation, and a printer whose
    shape never changes across versions, gated by a small per-version
    feature table. Like target_c.ml, Java is statically typed and this
    backend infers no polymorphism, so it works out a type (Int, String,
    or Bool) for every binding, parameter and function. Unlike C, javac
    requires every non-void method to provably return on every path and
    rejects unreachable code, so this backend checks both.
    See docs/target_java.md.

    The Java AST, the type inference over it, the scope and the two
    javac rules are this module's own: a caller translates a module and
    prints it. `default_class_name` is here rather than in the driver
    because Java requires the file and its public class to agree, so
    naming the output is the backend's business.

    Data structures:
      Unsupported -- a construct this backend cannot compile, with the
        source position.
      jprogram -- a translated module.

    Functions:
      translate_program stmts context -- translates a whole module.
      default_class_name stem -- the Java class name for a source stem.
      pprint_java_program program version class_name source -- the
        compilation unit. *)

(** Raised for a Pyking construct this backend cannot compile; carries
    the source position, like the front end's errors do for their
    stages. *)
exception Unsupported of Lexer.info * string

(** A translated module: made by `translate_program`, read by
    `pprint_java_program`, and nothing to build or inspect from
    outside. *)
type jprogram

(** The Java class (and file) name picked when nothing else says one,
    e.g. foo_bar -> FooBar. The rule lives in module.ml, which owns what
    a module's file is called on each target. string -> string *)
val default_class_name : string -> string

(** One module of a program as a jprogram. `context` says what is true of
    it only as part of a program -- its name, whether it is the program's
    own module, and what the modules it imports export.
    [stmt] -> Module.context -> jprogram *)
val translate_program : Syntax.stmt list -> Module.context -> jprogram

(** The whole compilation unit: the class holding every function as a
    private static method, and main. `version` is the Java version to
    print for, `class_name` the class to declare and `source` the Pyking
    file it came from.
    jprogram -> string -> string -> string -> string *)
val pprint_java_program : jprogram -> string -> string -> string -> string
