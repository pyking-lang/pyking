(** The standard library's externals, implemented for the interpreter.
    A library under lib/ reaches the host through an external module,
    which has no Pyking body; a compiled program reaches the target's
    own file, and an interpreted one reaches this. See
    docs/libraries.md.

    Only the modules `implements` names are answered for. Any other
    external module is still refused before a program runs, in pyk.ml,
    which is what stops a folder named `fs` on a `-L` path from being
    answered by this file instead of by the file that resolved.

    This module is in the executable rather than the library because it
    reads files, the clock and the environment, and nothing in the
    library half may (see docs/build.md).

    Functions:
      implements name -- whether an external module is implemented here.
      externals program arguments -- the implementations, as the
        interpreter's own record. *)

(** Whether an external module is one this host can answer for.
    string -> bool *)
val implements : string -> bool

(** The implementations, as the interpreter's own record. `program` is
    the file `pyk` was asked to run, and `arguments` what followed `--`
    on the command line -- the program's own, never this compiler's.
    string -> [string] -> Interpreter.externals *)
val externals : string -> string list -> Interpreter.externals
