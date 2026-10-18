(** What `--run` runs: the commands each target's host uses to build and
    run what `pyk compile` wrote. One table, so the driver stays a
    sequencer and each target's toolchain is stated in one place.
    See docs/pyk.md ("Running what was compiled").

    The commands are the ones a user would type by hand, and each is
    printed before it runs -- to stderr, so a program's own output on
    stdout stays its own. The toolchain is taken from the environment
    where there is a choice about it: $CC, $JAVAC, $JAVA and $OCAMLOPT.

    The table and the plan it builds are private: building, running and
    the Makefile saying both are what the driver asks for, since a caller
    that could read a plan would be a second place deciding how a target
    is built.

    Functions:
      execute target path modules arguments -- builds and runs what was
        compiled, passing the program its own arguments; answers its
        status.
      build target path modules -- builds what was compiled.
      run target path modules arguments directory -- runs what was built.
      makefile target path modules -- the same commands as a Makefile.
      launcher target path here -- the shell line that runs a program
        no binary is built for.
      pyking_target -- the target that is run by this compiler itself. *)

(** The target whose "host" is this compiler: what runs a Pyking program
    is the interpreter. string *)
val pyking_target : string

(** Builds and runs what was compiled to path, printing each command
    before it runs. `modules` names the program's other files, in the
    order they must be built. Answers the program's exit status, or that
    of the build step that failed. `arguments` is what the program
    itself is passed -- after `--` where the host is this compiler,
    which would otherwise read them as its own.
    string -> string -> [string] -> [string] -> int *)
val execute : string -> string -> string list -> string list -> int

(** Runs what builds what was compiled to path, each command printed
    first, in the directory it was compiled into. Answers 0, or the
    status of the step that failed. string -> string -> [string] -> int *)
val build : string -> string -> string list -> int

(** Runs the program built from path, printed first, in `directory`,
    passing it `arguments`. Answers its status.
    string -> string -> [string] -> [string] -> string -> int *)
val run : string -> string -> string list -> string list -> string -> int

(** The shell line a launcher runs the program compiled to path with,
    where the target builds no binary and is no page: its host, named by
    the variable a shell may override, and the file it is handed, under
    `here`. None for the other targets.
    string -> string -> string -> string? *)
val launcher : string -> string -> string -> string option

(** A Makefile for the directory path was compiled into, saying with the
    commands `--run` uses how to build the program (`make`), run it
    (`make run`, with `ARGS`) and remove what `make` made (`make clean`).
    Each tool is a variable the command line may set.
    string -> string -> [string] -> string *)
val makefile : string -> string -> string list -> string
