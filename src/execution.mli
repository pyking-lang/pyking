(** What `--run` runs: the commands each target's host uses to build and
    run what `pyk compile` wrote. One table, so the driver stays a
    sequencer and each target's toolchain is stated in one place.
    See docs/pyk.md ("Running what was compiled").

    The commands are the ones a user would type by hand, and each is
    printed before it runs -- to stderr, so a program's own output on
    stdout stays its own. The toolchain is taken from the environment
    where there is a choice about it: $CC, $JAVAC, $JAVA and $OCAMLOPT.

    The table and the plan it builds are private: `execute` is the whole
    of what the driver asks for, since a caller that could read a plan
    without running it would be a second place deciding how a target is
    built.

    Functions:
      execute target path modules -- builds and runs what was compiled;
        answers the program's status.
      pyking_target -- the target that is run by this compiler itself. *)

(** The target whose "host" is this compiler: what runs a Pyking program
    is the interpreter. string *)
val pyking_target : string

(** Builds and runs what was compiled to path, printing each command
    before it runs. `modules` names the program's other files, in the
    order they must be built. Answers the program's exit status, or that
    of the build step that failed.
    string -> string -> [string] -> int *)
val execute : string -> string -> string list -> int
