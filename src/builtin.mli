(** The builtins: the names a Pyking program may call without binding
    them, and what the rest of the compiler has to agree about for each
    one -- how many arguments it takes, whether calling it can be
    observed outside the program, and what it means. One table, read by
    the checker, the interpreter and every backend. See docs/builtin.md.

    A builtin that `crosses_host` is one whose call leaves the program:
    `print` and `debug` are the two today, and they are what a backend
    emits host output for -- `print` to standard output, `debug` to
    standard error. The others compute, and are observed only through
    what they answer with. The conversions `string`, `int`, `float` and
    `bool` are four of those, and the rules for reading a String and
    truncating a Float are stated here, since every backend implements
    them the same way.

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
      is_debug name -- whether name is `debug`.
      parse_int / parse_float text -- a String as `int` / `float` reads it.
      truncate_float x -- a Float as `int` reads it.
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

(** The Int range a conversion answers within: signed 32 bits, the range
    the lexer bounds a literal by. int *)
val int_min : int

val int_max : int

(** A String as `int` reads it: an optional sign, then decimal digits,
    within the signed 32-bit range -- nothing else, not even a space.
    string -> int option *)
val parse_int : string -> int option

(** A String as `float` reads it: an optional sign, digits, an optional
    `.` and digits, an optional exponent -- or `inf`, `-inf` or `nan`,
    which is what `print` writes for those. string -> float option *)
val parse_float : string -> float option

(** A Float as `int` reads it: truncated toward zero, and 0 where that is
    no Int in the signed 32-bit range. float -> int *)
val truncate_float : float -> int

(** The names that do not cross the host boundary, which is what a
    backend with no translation for them has to refuse. [string] *)
val pure_names : string list

(** The builtin a name denotes, or None if it is an ordinary Pyking
    name. string -> t option *)
val lookup : string -> t option

(** Whether name is `debug`, the builtin whose output is diagnostic
    rather than the program's own. string -> bool *)
val is_debug : string -> bool

(** Whether calling name leaves the program, so that a backend has to
    emit host output for it. False for a name that is not a builtin.
    string -> bool *)
val crosses_host : string -> bool

(** A Float as `print` and `str` write it: the shortest decimal that
    reads back as the same double, always with a point or an exponent.
    float -> string *)
val float_text : float -> string

(** Whether an Int is a Unicode scalar value, which is what a Char
    holds: 0 to 0x10FFFF, surrogates left out. int -> bool *)
val is_code_point : int -> bool

(** A UTF-8 String's characters, as code points; a byte that starts no
    character is U+FFFD. string -> [int] *)
val code_points : string -> int list

(** One code point as UTF-8; U+FFFD for an Int that is none. int -> string *)
val utf8 : int -> string

(** How many characters a UTF-8 String holds: what `len` answers.
    string -> int *)
val utf8_length : string -> int

(** `char(n)`: the code point itself, or 0 where it is none. int -> int *)
val char_of_int : int -> int

(** `char(s)`: a String's first character, or 0 where it has none.
    string -> int *)
val char_of_string : string -> int

(** A Char as it is written inside a list or tuple: in single quotes,
    with a quote, a backslash, a newline, a tab and a carriage return
    escaped as a String's are. int -> string *)
val quote_char : int -> string

(** A String as it is written inside a list or tuple: in double quotes,
    with a quote, a backslash, a newline, a tab and a carriage return
    escaped. string -> string *)
val quote_string : string -> string

(** How many UTF-16 code units a UTF-8 String takes: its length in
    JavaScript and Java, which a string pattern's prefix and suffix are
    cut by there. string -> int *)
val utf16_length : string -> int
