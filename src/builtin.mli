(** The builtins: the names a Pyking program may call without binding
    them, and what the rest of the compiler has to agree about for each
    one -- how many arguments it takes, whether calling it can be
    observed outside the program, and what it means. One table, read by
    the checker, the interpreter and every backend. See docs/builtin.md.

    A builtin that `crosses_host` is one whose call leaves the program:
    `print` is the only one today, and it is what a backend emits host
    output for. The other three compute, and are observed only through
    what they answer with.

    Two things are deliberately not here, because neither can be said
    without a type or a value: which argument types a builtin accepts is
    typesystem.ml's, since those are settled by unification against its
    own metavariables, and what a builtin computes is interpreter.ml's.

    The table itself is private: a caller asks for the names, for one
    builtin, or for the one property a backend branches on, rather than
    reading rows.

    Data structures:
      t -- one builtin: its name, its arity, whether it crosses the host
        boundary, and what it does.

    Functions:
      names -- every builtin's name, in the order the table lists them.
      pure_names -- the names that do not cross the host boundary.
      lookup name -- the builtin a name denotes, or None.
      crosses_host name -- whether calling name leaves the program. *)

(** One builtin. `max_args` is None for a variadic one, which is the
    whole of what makes `print` take any number of arguments. *)
type t = {
  name : string;
  min_args : int;
  max_args : int option;
  crosses_host : bool;
  doc : string;
}

(** Every builtin's name, in the order the table lists them. [string] *)
val names : string list

(** The names that do not cross the host boundary, which is what a
    backend with no translation for them has to refuse. [string] *)
val pure_names : string list

(** The builtin a name denotes, or None if it is an ordinary Pyking
    name. string -> t option *)
val lookup : string -> t option

(** Whether calling name leaves the program, so that a backend has to
    emit host output for it. False for a name that is not a builtin.
    string -> bool *)
val crosses_host : string -> bool
