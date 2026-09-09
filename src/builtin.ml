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

(* Every builtin. The order is the one the playground publishes as its
   word list, so it is the order a program's author sees.

   Extend when a program starts calling another one, and expect four
   edits rather than this one: an argument rule in typesystem.ml, a case
   in interpreter.ml, and in each backend either a translation or a
   refusal. *)
let all =
  [
    {
      name = "print";
      min_args = 0;
      max_args = None;
      crosses_host = true;
      doc =
        "Write the arguments, space-separated, as one line of output. \
         Produces no value: it yields unit, `()`, so it is meaningful as a \
         statement and not as something to bind or return. A function whose \
         tail is a `print` therefore returns unit -- `void` in the C and \
         Java backends, an implicit `None`/`undefined` in the Python and \
         JavaScript ones.";
    };
    {
      name = "range";
      min_args = 1;
      max_args = Some 3;
      crosses_host = false;
      doc =
        "Answer the Ints from start up to but not including stop, stepping \
         by step. One argument is the stop, with start 0 and step 1; two \
         are the start and the stop; three are all of them. A step of zero \
         is a runtime error. The answer is a *list*: Pyking has lists and \
         no lazy-sequence type.";
    };
    {
      name = "str";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc =
        "Answer the argument as a String, formatted the way `print` writes \
         it -- so a Bool is `true`/`false` and unit is `()`, in Pyking's own \
         spelling rather than the host's. Accepts an Int, a String, a Bool, \
         a list or a tuple.";
    };
    {
      name = "len";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc =
        "Answer how many items a list holds, or how many characters a \
         String holds.";
    };
  ]

(** Every builtin's name, in the order the table lists them. [string] *)
let names = List.map (fun builtin -> builtin.name) all

(** The builtin a name denotes, or None if it is an ordinary Pyking
    name. string -> t option *)
let lookup name = List.find_opt (fun builtin -> builtin.name = name) all

(** The names that do not cross the host boundary, which is what a
    backend with no translation for them has to refuse. [string] *)
let pure_names =
  List.filter_map
    (fun builtin -> if builtin.crosses_host then None else Some builtin.name)
    all

(** Whether calling name leaves the program, so that a backend has to
    emit host output for it. False for a name that is not a builtin.
    string -> bool *)
let crosses_host name =
  match lookup name with Some builtin -> builtin.crosses_host | None -> false
