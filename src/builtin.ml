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
      crosses_host name -- whether calling name leaves the program.
      float_text x -- a Float as print and str write it. *)

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
    {
      name = "float";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc =
        "Answer an Int as a Float. Exact for a magnitude below 2^53; above \
         it, the nearest double. Pyking converts nothing on its own, so \
         this and `int` are the only way an Int and a Float meet.";
    };
    {
      name = "int";
      min_args = 1;
      max_args = Some 1;
      crosses_host = false;
      doc =
        "Answer a Float as an Int, truncating toward zero -- the rounding \
         `/` already does. A value with no Int to truncate to (a NaN, an \
         infinity, one past the Int range) is undefined, as an Int \
         overflow is.";
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

(* --- how a Float is written ---

   The shortest decimal that reads back as the same double, presented so
   that it is always visibly a Float. Every backend implements this same
   algorithm in its own host language, because no two hosts spell a
   double alike and one .out file is compared against all of them (see
   docs/builtin.md, "The formatting rules"). *)

(** The shortest `%.pe` for a positive, finite a that reads back as a.
    Seventeen significant digits always do, so the search ends.
    float -> string *)
let shortest_digits a =
  let rec search p =
    let s = Printf.sprintf "%.*e" p a in
    if p >= 16 || float_of_string s = a then s else search (p + 1)
  in
  search 0

(** A Float as `print` and `str` write it. float -> string *)
let float_text x =
  if x <> x then "nan"
  else if x = infinity then "inf"
  else if x = neg_infinity then "-inf"
  else
    (* 1.0 /. x separates the two zeros, which compare equal. *)
    let negative = x < 0.0 || (x = 0.0 && 1.0 /. x < 0.0) in
    let sign = if negative then "-" else "" in
    let a = abs_float x in
    if a = 0.0 then sign ^ "0.0"
    else
      let s = shortest_digits a in
      let at = String.index s 'e' in
      let digits = String.concat "" (String.split_on_char '.' (String.sub s 0 at)) in
      let rec trim n = if n > 1 && digits.[n - 1] = '0' then trim (n - 1) else n in
      let digits = String.sub digits 0 (trim (String.length digits)) in
      let len = String.length digits in
      (* Where the point falls: a = 0.digits x 10^decpt. The thresholds
         are the ones that keep 100.0 from printing as 1e2. *)
      let decpt =
        int_of_string (String.sub s (at + 1) (String.length s - at - 1)) + 1
      in
      let zeros n = String.make (max 0 n) '0' in
      if decpt <= -4 || decpt > 16 then
        let mantissa =
          if len = 1 then digits
          else String.sub digits 0 1 ^ "." ^ String.sub digits 1 (len - 1)
        in
        sign ^ mantissa ^ "e" ^ string_of_int (decpt - 1)
      else if decpt <= 0 then sign ^ "0." ^ zeros (-decpt) ^ digits
      else if decpt >= len then sign ^ digits ^ zeros (decpt - len) ^ ".0"
      else
        sign ^ String.sub digits 0 decpt ^ "."
        ^ String.sub digits decpt (len - decpt)
